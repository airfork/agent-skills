require "digest"
require "fileutils"
require "open3"
require "tmpdir"

module AdversarialReview
  module Runner
    DEFAULT_MAX_OUTPUT_BYTES = 1_048_576
    DEFAULT_TERMINATION_GRACE_SECONDS = 0.5
    FORBIDDEN_ENVIRONMENT = %w[
      PATH CDPATH ENV BASH_ENV ZDOTDIR SHELLOPTS RUBYOPT RUBYLIB
      GEM_HOME GEM_PATH BUNDLE_GEMFILE
    ].freeze

    Result = Struct.new(
      :stdout, :stderr, :exit_status, :duration_ms, :timed_out,
      :stdout_truncated, :stderr_truncated, :termsig,
      keyword_init: true
    )
    Executable = Struct.new(
      :path, :device, :inode, :mode, :mtime_ns, :size, :sha256,
      keyword_init: true
    )

    class Error < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    class SecurityError < Error; end

    module_function

    def resolve_executable(candidate, repository: nil, run_directory: nil,
                           config_root: nil, excluded_roots: [])
      path = executable_path(candidate)
      realpath = File.realpath(path)
      stat = File.stat(realpath)
      unless stat.file? && File.executable?(realpath)
        raise SecurityError.new("invalid_executable", "selected executable is not an executable file")
      end

      roots = [repository, run_directory, config_root, *excluded_roots].compact
      if roots.any? { |root| path_within?(realpath, canonical_root(root)) }
        raise SecurityError.new(
          "controlled_executable",
          "selected executable is inside a review-controlled directory"
        )
      end

      identity(realpath)
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
           Errno::ELOOP => error
      raise SecurityError.new("invalid_executable", "selected executable is unavailable: #{error.class}")
    end

    def verify_executable!(executable)
      unless executable.is_a?(Executable)
        raise SecurityError.new("invalid_executable", "executable identity is not pinned")
      end
      before = File.lstat(executable.path)
      unless executable_metadata_matches?(before, executable) && before.file? &&
             !before.symlink? && (before.mode & 0o111).positive?
        raise SecurityError.new("executable_changed", "selected executable changed after capability probing")
      end

      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      digest = nil
      File.open(executable.path, flags) do |file|
        opened = file.stat
        unless executable_metadata_matches?(opened, executable) && opened.file? &&
               (opened.mode & 0o111).positive?
          raise SecurityError.new(
            "executable_changed", "selected executable identity changed before hashing"
          )
        end
        digest = hash_descriptor(file)
        after_hash = file.stat
        unless executable_metadata_matches?(after_hash, executable)
          raise SecurityError.new(
            "executable_changed", "selected executable changed while hashing"
          )
        end
      end
      after_path = File.lstat(executable.path)
      unless executable_metadata_matches?(after_path, executable) && digest == executable.sha256
        raise SecurityError.new("executable_changed", "selected executable changed after capability probing")
      end
      true
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
           Errno::ELOOP
      raise SecurityError.new("executable_changed", "selected executable changed after capability probing")
    end

    def run(argv:, stdin_data:, timeout_seconds:, env: {}, chdir: Dir.pwd,
            max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
            termination_grace_seconds: DEFAULT_TERMINATION_GRACE_SECONDS,
            executable: nil, repository: nil, run_directory: nil,
            config_root: nil, excluded_roots: [])
      validate_run_arguments!(argv, stdin_data, timeout_seconds, env,
                              max_output_bytes, termination_grace_seconds)
      canonical_chdir = File.realpath(chdir)
      unless File.directory?(canonical_chdir)
        raise Error.new("invalid_working_directory", "working directory is not a directory")
      end
      if repository && !same_identity?(canonical_chdir, File.realpath(repository))
        raise SecurityError.new(
          "working_directory_mismatch",
          "child working directory does not match the canonical repository"
        )
      end

      pinned = if executable
                 executable
               else
                 resolve_executable(
                   argv.fetch(0), repository: repository, run_directory: run_directory,
                   config_root: config_root, excluded_roots: excluded_roots
                 )
               end
      if executable && argv.fetch(0) != pinned.path
        raise SecurityError.new("executable_mismatch", "argv executable does not match pinned executable")
      end
      controlled_roots = [repository, run_directory, config_root, *excluded_roots].compact
      if controlled_roots.any? { |root| path_within?(pinned.path, canonical_root(root)) }
        raise SecurityError.new(
          "controlled_executable",
          "selected executable is inside a review-controlled directory"
        )
      end
      verify_executable!(pinned)
      command = [pinned.path, *argv.drop(1)]
      started = monotonic_now
      timed_out = false
      process_status = nil
      stdout_text = stderr_text = ""
      stdout_truncated = stderr_truncated = false
      stdin = stdout = stderr = wait_thread = nil
      readers = []
      writer = nil

      begin
        stdin, stdout, stderr, wait_thread = Open3.popen3(
          env, [pinned.path, pinned.path], *command.drop(1),
          chdir: canonical_chdir,
          unsetenv_others: true,
          pgroup: true
        )
        readers = [stdout, stderr].map do |pipe|
          Thread.new { drain(pipe, max_output_bytes) }.tap do |thread|
            thread.report_on_exception = false
          end
        end
        writer = Thread.new do
          begin
            stdin.write(stdin_data)
            stdin.flush
          rescue Errno::EPIPE, IOError
            nil
          ensure
            close_quietly(stdin)
          end
        end

        deadline = started + timeout_seconds
        until wait_thread.join(0) && readers.all? { |thread| !thread.alive? } && !writer.alive?
          if monotonic_now >= deadline
            timed_out = true
            terminate_group(wait_thread.pid, "TERM")
            grace_deadline = monotonic_now + termination_grace_seconds
            while monotonic_now < grace_deadline &&
                  (wait_thread.alive? || readers.any?(&:alive?) || writer.alive?)
              sleep 0.005
            end
            close_quietly(stdin)
            close_quietly(stdout)
            close_quietly(stderr)
            terminate_group(wait_thread.pid, "KILL")
            break
          end
          sleep 0.005
        end

        close_quietly(stdin)
        close_quietly(stdout) if timed_out
        close_quietly(stderr) if timed_out
        cleanup_seconds = [termination_grace_seconds, 0.1].max
        writer_finished = finish_worker(writer, cleanup_seconds)
        reader_statuses = readers.map { |thread| finish_worker(thread, cleanup_seconds) }
        unless join_quietly(wait_thread, cleanup_seconds)
          terminate_group(wait_thread.pid, "KILL")
          unless join_quietly(wait_thread, cleanup_seconds)
            raise Error.new("process_cleanup_failed", "child could not be reaped after KILL")
          end
        end
        process_status = wait_thread.value
        unless writer_finished || timed_out
          raise Error.new("stdin_write_failed", "stdin writer did not finish")
        end
        unless reader_statuses.all?
          raise Error.new("output_read_failed", "output reader did not finish")
        end
        stdout_text, stdout_truncated = thread_capture(readers.fetch(0))
        stderr_text, stderr_truncated = thread_capture(readers.fetch(1))
      ensure
        close_quietly(stdin)
        close_quietly(stdout)
        close_quietly(stderr)
        finish_worker(writer, termination_grace_seconds) if writer
        readers.each { |thread| finish_worker(thread, termination_grace_seconds) }
        if wait_thread && wait_thread.alive?
          terminate_group(wait_thread.pid, "KILL")
          join_quietly(wait_thread, [termination_grace_seconds, 0.1].max)
        end
      end

      Result.new(
        stdout: stdout_text,
        stderr: stderr_text,
        exit_status: process_status && process_status.exitstatus,
        duration_ms: ((monotonic_now - started) * 1000).round,
        timed_out: timed_out,
        stdout_truncated: stdout_truncated,
        stderr_truncated: stderr_truncated,
        termsig: process_status && process_status.termsig
      )
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise Error.new("spawn_failed", "could not launch selected executable: #{error.class}")
    end

    def with_isolated_directory(parent: nil, prefix: "adversarial-review-config")
      directory = Dir.mktmpdir(prefix, parent)
      File.chmod(0o700, directory)
      begin
        yield directory
      ensure
        FileUtils.remove_entry_secure(directory) if File.exist?(directory)
      end
    end

    def write_private_file(path, contents)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(contents)
        file.flush
        file.fsync
      end
      path
    end

    def executable_path(candidate)
      unless candidate.is_a?(String) && !candidate.empty?
        raise SecurityError.new("invalid_executable", "executable name must be nonempty")
      end
      return File.expand_path(candidate) if candidate.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
        next if directory.empty?
        path = File.join(directory, candidate)
        return path if File.file?(path) && File.executable?(path)
      end
      raise SecurityError.new("invalid_executable", "selected executable was not found")
    end
    private_class_method :executable_path

    def identity(path)
      before = File.lstat(path)
      unless before.file? && !before.symlink? && File.executable?(path)
        raise SecurityError.new(
          "invalid_executable_metadata",
          "selected executable is not a regular executable file"
        )
      end
      digest = nil
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags) do |file|
        opened = file.stat
        unless opened.file? && (opened.mode & 0o111).positive? &&
               before.dev == opened.dev && before.ino == opened.ino
          raise SecurityError.new("executable_changed", "selected executable identity changed while reading")
        end
        digest = hash_descriptor(file)
      end
      after = File.lstat(path)
      unless before.dev == after.dev && before.ino == after.ino && before.size == after.size &&
             before.mtime == after.mtime && before.mode == after.mode
        raise SecurityError.new("executable_changed", "selected executable changed while reading")
      end
      Executable.new(
        path: File.realpath(path), device: after.dev, inode: after.ino,
        mode: after.mode, mtime_ns: time_nanoseconds(after.mtime),
        size: after.size, sha256: digest
      )
    end
    private_class_method :identity

    def executable_metadata_matches?(stat, executable)
      stat.dev == executable.device && stat.ino == executable.inode &&
        stat.mode == executable.mode && time_nanoseconds(stat.mtime) == executable.mtime_ns &&
        stat.size == executable.size
    end
    private_class_method :executable_metadata_matches?

    def hash_descriptor(file)
      file.rewind
      digest = Digest::SHA256.new
      loop do
        digest.update(file.readpartial(65_536))
      end
    rescue EOFError
      digest.hexdigest
    end
    private_class_method :hash_descriptor

    def time_nanoseconds(time)
      time.to_i * 1_000_000_000 + time.nsec
    end
    private_class_method :time_nanoseconds

    def canonical_root(root)
      File.exist?(root) ? File.realpath(root) : File.expand_path(root)
    end
    private_class_method :canonical_root

    def path_within?(path, root)
      return false unless File.exist?(root)

      root_stat = File.stat(root)
      cursor = File.realpath(path)
      loop do
        cursor_stat = File.stat(cursor)
        return true if cursor_stat.dev == root_stat.dev && cursor_stat.ino == root_stat.ino
        parent = File.dirname(cursor)
        return false if parent == cursor
        cursor = parent
      end
    end
    private_class_method :path_within?

    def same_identity?(left, right)
      left_stat = File.stat(left)
      right_stat = File.stat(right)
      left_stat.dev == right_stat.dev && left_stat.ino == right_stat.ino
    end
    private_class_method :same_identity?

    def drain(pipe, limit)
      captured = String.new.b
      truncated = false
      loop do
        chunk = pipe.readpartial(16_384)
        remaining = limit - captured.bytesize
        if remaining.positive?
          captured << chunk.byteslice(0, remaining)
        end
        truncated = true if chunk.bytesize > [remaining, 0].max
      end
    rescue EOFError, IOError
      [captured, truncated]
    end
    private_class_method :drain

    def thread_capture(thread)
      value = thread.value
      unless value.is_a?(Array) && value.length == 2 && value.fetch(0).is_a?(String) &&
             [true, false].include?(value.fetch(1))
        raise Error.new("output_read_failed", "output reader returned an invalid result")
      end
      value
    rescue Error
      raise
    rescue StandardError => error
      raise Error.new("output_read_failed", "output reader failed: #{error.class}")
    end
    private_class_method :thread_capture

    def terminate_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    private_class_method :terminate_group

    def close_quietly(io)
      io.close if io && !io.closed?
    rescue IOError
      nil
    end
    private_class_method :close_quietly

    def join_quietly(thread, timeout)
      thread.join(timeout)
      !thread.alive?
    rescue StandardError
      !thread.alive?
    end
    private_class_method :join_quietly

    def finish_worker(thread, timeout)
      return true if join_quietly(thread, timeout)

      thread.kill
      join_quietly(thread, 0.1)
      false
    end
    private_class_method :finish_worker

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic_now

    def validate_run_arguments!(argv, stdin_data, timeout_seconds, env,
                                max_output_bytes, termination_grace_seconds)
      unless argv.is_a?(Array) && !argv.empty? && argv.all? { |item| item.is_a?(String) }
        raise Error.new("invalid_argv", "argv must be a nonempty string array")
      end
      unless stdin_data.is_a?(String)
        raise Error.new("invalid_stdin", "stdin data must be a string")
      end
      unless finite_number?(timeout_seconds) && timeout_seconds.positive? &&
             finite_number?(termination_grace_seconds) && termination_grace_seconds >= 0
        raise Error.new("invalid_timeout", "timeout and termination grace must be bounded numbers")
      end
      unless max_output_bytes.is_a?(Integer) && max_output_bytes.positive?
        raise Error.new("invalid_output_limit", "output limit must be a positive integer")
      end
      unless env.is_a?(Hash) && env.all? do |key, value|
               valid_environment_entry?(key, value)
             end
        raise Error.new("invalid_environment", "child environment must be an explicit string map")
      end
      forbidden = env.keys & FORBIDDEN_ENVIRONMENT
      unless forbidden.empty?
        raise SecurityError.new(
          "forbidden_environment",
          "child environment contains forbidden startup variables: #{forbidden.join(", ")}"
        )
      end
    end
    private_class_method :validate_run_arguments!

    def finite_number?(value)
      value.is_a?(Numeric) && (!value.respond_to?(:finite?) || value.finite?)
    end
    private_class_method :finite_number?

    def valid_environment_entry?(key, value)
      key.is_a?(String) && !key.empty? && !key.include?("=") && !key.include?("\0") &&
        value.is_a?(String) && !value.include?("\0")
    end
    private_class_method :valid_environment_entry?
  end
end
