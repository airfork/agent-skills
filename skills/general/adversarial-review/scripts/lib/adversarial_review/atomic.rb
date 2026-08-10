require "json"
require "securerandom"
require "fiddle/import"
require "fcntl"

module AdversarialReview
  # Durable state primitives with two backends.
  #
  # The POSIX backend binds every operation to an open directory descriptor
  # (openat/linkat/renameat/unlinkat) and locks the directory itself, which
  # closes the symlink-swap and rename-under-us races that a path-based
  # implementation cannot.
  #
  # The portable backend exists for hosts without those calls, native Windows in
  # particular. It keeps the state machine, atomic publish, and cross-process
  # file locking, and gives up the descriptor-relative guarantees. It never
  # pretends otherwise: `Atomic.guarantees` is recorded in run provenance and
  # surfaced in the report so a portable run reads as deliberately weaker rather
  # than equivalent.
  module Atomic
    AT_REMOVEDIR = RUBY_PLATFORM.include?("darwin") ? 0x0080 : 0x0200
    O_DIRECTORY = if Fcntl.const_defined?(:O_DIRECTORY)
                    Fcntl::O_DIRECTORY
                  elsif RUBY_PLATFORM.include?("darwin")
                    0x00100000
                  else
                    0o200000
                  end
    MAX_JSON_BYTES = 16 * 1024 * 1024
    NOFOLLOW_FLAG = File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0
    # Windows translates \n on write in text mode, which would corrupt every
    # persisted digest. Every portable open is explicitly binary.
    BINARY_FLAG = File.const_defined?(:BINARY) ? File::BINARY : 0

    module Native
      extend Fiddle::Importer

      begin
        dlload Fiddle.dlopen(nil)
        extern "int openat(int, const char*, int, int)"
        extern "int linkat(int, const char*, int, const char*, int)"
        extern "int renameat(int, const char*, int, const char*)"
        extern "int unlinkat(int, const char*, int)"
        AVAILABLE = true
      rescue Fiddle::DLError, NotImplementedError
        AVAILABLE = false
      end
    end

    # Probed, not inferred from RUBY_PLATFORM: a host either hands back a usable
    # directory descriptor or it does not.
    DIRECTORY_DESCRIPTORS = begin
      File.open(__dir__, File::RDONLY) { |directory| directory.stat.directory? }
    rescue StandardError
      false
    end

    # Every identity check here compares a path stat against a stat taken from an
    # open handle for the same file. Windows can report ino 0, or a different ino
    # for those two routes, either of which makes the comparison vacuously true
    # or uniformly false rather than meaningful. Probe the exact property the
    # code relies on, not just a non-zero inode.
    INODE_IDENTITY = begin
      by_path = File.stat(__FILE__)
      by_handle = File.open(__FILE__, File::RDONLY) { |file| file.stat }
      by_path.ino != 0 && by_path.ino == by_handle.ino && by_path.dev == by_handle.dev
    rescue StandardError
      false
    end

    # Whether a path stat and a handle stat agree on sub-second mtime. Some
    # hosts round the two routes differently, which would make an unchanged file
    # look modified between pinning it and re-verifying it. Where this is false,
    # callers compare whole seconds and lean on size, mode, and digest.
    STABLE_MTIME_NANOSECONDS = begin
      by_path = File.stat(__FILE__)
      by_handle = File.open(__FILE__, File::RDONLY) { |file| file.stat }
      by_path.mtime.nsec == by_handle.mtime.nsec
    rescue StandardError
      false
    end

    # Whether the host carries POSIX permission bits, which is a property of the
    # filesystem rather than of the selected backend: forcing the portable
    # backend on a POSIX host does not stop chmod from working there.
    POSIX_PERMISSIONS = begin
      require "tmpdir"
      Dir.mktmpdir("permission-probe") do |directory|
        probe = File.join(directory, "probe")
        File.write(probe, "")
        File.chmod(0o600, probe)
        (File.stat(probe).mode & 0o777) == 0o600
      end
    rescue StandardError
      false
    end

    # Only the weaker backend may be forced, and only for testing the portable
    # path on a POSIX host. Forcing the hardened backend onto a host that cannot
    # support it would fail at the first call anyway.
    BACKEND = if ENV["ADVERSARIAL_REVIEW_FS_BACKEND"] == "portable"
                :portable
              elsif Native::AVAILABLE && DIRECTORY_DESCRIPTORS
                :posix
              else
                :portable
              end

    module_function

    def posix_backend?
      BACKEND == :posix
    end

    # Machine-readable statement of what this host's backend actually enforces.
    # Recorded in provenance; never omitted when degraded.
    def guarantees
      {
        "backend" => BACKEND.to_s,
        "descriptor_relative_paths" => posix_backend?,
        "directory_locking" => posix_backend?,
        "durable_directory_metadata" => posix_backend?,
        "posix_permissions" => POSIX_PERMISSIONS,
        "inode_identity" => INODE_IDENTITY,
        "forced" => ENV["ADVERSARIAL_REVIEW_FS_BACKEND"] == "portable"
      }
    end

    def degraded?
      guarantees.any? { |key, value| key != "backend" && key != "forced" && value == false }
    end

    def degraded_guarantees
      guarantees.reject { |key, value| key == "backend" || key == "forced" || value != false }.keys
    end

    # Directory handle shared by both backends. The POSIX form wraps a real open
    # descriptor; the portable form carries only a validated path.
    class DirectoryHandle
      attr_reader :path

      def initialize(path)
        @path = path
        @closed = false
      end

      def stat
        File.stat(@path)
      end

      def closed?
        @closed
      end

      def close
        @closed = true
      end
    end

    class PosixDirectory < DirectoryHandle
      def initialize(path, file)
        super(path)
        @file = file
      end

      def fileno
        @file.fileno
      end

      def stat
        @file.stat
      end

      def fsync
        @file.fsync
      end

      def flock(operation)
        @file.flock(operation)
      end

      def supports_directory_lock?
        true
      end

      def closed?
        @file.closed?
      end

      def close
        @file.close unless @file.closed?
      end
    end

    class PortableDirectory < DirectoryHandle
      def fileno
        raise NotImplementedError, "portable backend has no directory descriptor"
      end

      # Directory metadata cannot be flushed without a directory descriptor. A
      # crash can therefore lose a rename that the POSIX backend would have
      # durably published; the run declares `durable_directory_metadata` false.
      def fsync
        0
      end

      # Deliberately raises instead of returning a truthy no-op, so an unguarded
      # caller fails loudly rather than believing it holds a directory lock.
      def flock(_operation)
        raise NotImplementedError, "portable backend cannot lock a directory"
      end

      def supports_directory_lock?
        false
      end
    end

    def write_json(path, value)
      destination_name = File.basename(path)
      temporary_name = ".#{destination_name}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
      with_bound_directory(File.dirname(path)) do |parent, directory|
        verify_directory_identity!(parent, directory)
        write_json_relative(
          directory, destination_name, value, temporary_name: temporary_name
        ) do
          verify_directory_identity!(parent, directory)
        end
        verify_directory_identity!(parent, directory)
        File.join(parent, destination_name)
      end
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
           Errno::EISDIR => error
      raise_state_error("unsafe_path", "atomic write path is unsafe", {"path" => path, "cause" => error.class.name})
    end

    def write_json_relative(directory, destination_name, value, temporary_name: nil,
                            on_publish: nil)
      validate_relative_name!(destination_name)
      serialized = bounded_json_bytes(value, destination_name)
      temporary_name ||= ".#{destination_name}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
      validate_relative_name!(temporary_name)
      created = false
      begin
        reject_relative_nonregular(directory, destination_name)
        flags = File::WRONLY | File::CREAT | File::EXCL | NOFOLLOW_FLAG
        file = open_relative(directory, temporary_name, flags, 0o600)
        created = true
        begin
          file.chmod(0o600)
          file.write(serialized)
          file.flush
          file.fsync
        ensure
          file.close unless file.closed?
        end
        yield if block_given?
        reject_relative_nonregular(directory, destination_name)
        rename_relative(directory, temporary_name, destination_name)
        created = false
        on_publish.call if on_publish
        directory.fsync
      rescue Errno::EEXIST
        raise_state_error(
          "unsafe_temp", "atomic temporary path already exists",
          {"path" => temporary_name}
        )
      ensure
        unlink_relative(directory, temporary_name) if created
      end
      destination_name
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
           Errno::EISDIR => error
      raise_state_error(
        "unsafe_path", "atomic write path is unsafe",
        {"path" => destination_name, "cause" => error.class.name}
      )
    end

    def write_new_json(directory, destination_name, value)
      validate_relative_name!(destination_name)
      serialized = bounded_json_bytes(value, destination_name)
      temporary_name = ".#{destination_name}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
      created = false
      begin
        if reject_relative_nonregular(directory, destination_name, "task_collision")
          raise_state_error(
            "task_collision", "task bundle already exists", {"path" => destination_name}
          )
        end
        flags = File::WRONLY | File::CREAT | File::EXCL | NOFOLLOW_FLAG
        file = open_relative(directory, temporary_name, flags, 0o600)
        created = true
        begin
          file.chmod(0o600)
          file.write(serialized)
          file.flush
          file.fsync
        ensure
          file.close unless file.closed?
        end
        link_relative(directory, temporary_name, destination_name)
        directory.fsync
      rescue Errno::EEXIST
        raise_state_error(
          "task_collision", "task bundle already exists", {"path" => destination_name}
        )
      ensure
        unlink_relative(directory, temporary_name) if created
      end
      destination_name
    rescue Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM, Errno::EISDIR => error
      raise_state_error(
        "unsafe_task_path", "task bundle path is unsafe",
        {"path" => destination_name, "cause" => error.class.name}
      )
    end

    def read_json_relative(directory, name, code: "invalid_json", unsafe_code: "unsafe_path",
                           unsafe_exit_status: 2)
      file = open_relative(directory, name, File::RDONLY | NOFOLLOW_FLAG)
      begin
        reject_nonregular_handle(file, name, unsafe_code)
        if file.stat.size > MAX_JSON_BYTES
          raise_state_error(code, "persisted JSON exceeds the size limit", {"path" => name}, 3)
        end
        contents = file.read(MAX_JSON_BYTES + 1)
        if contents.bytesize > MAX_JSON_BYTES
          raise_state_error(code, "persisted JSON exceeds the size limit", {"path" => name}, 3)
        end
        value = JSON.parse(contents)
        yield if block_given?
        value
      ensure
        file.close if file && !file.closed?
      end
    rescue JSON::ParserError => error
      raise_state_error(code, "persisted JSON is invalid", {"path" => name, "cause" => error.message}, 3)
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
           Errno::EISDIR => error
      raise_state_error(
        unsafe_code, "persisted JSON is unavailable",
        {"path" => name, "cause" => error.class.name}, unsafe_exit_status
      )
    end

    def bounded_json_bytes(value, path)
      bytes = JSON.generate(value) + "\n"
      return bytes if bytes.bytesize <= MAX_JSON_BYTES

      raise_state_error(
        "json_too_large", "prospective JSON exceeds the size limit",
        {"path" => path, "bytes" => bytes.bytesize, "limit" => MAX_JSON_BYTES}, 3
      )
    end

    def with_relative_directory(parent_directory, name, expected_identity: nil,
                                code: "unsafe_path")
      directory = open_relative_directory(parent_directory, name)
      begin
        stat = directory.stat
        unless stat.directory? && (!expected_identity || same_identity?(expected_identity, stat))
          raise_state_error(code, "relative directory identity is unsafe", {"path" => name})
        end
        yield directory
      ensure
        directory.close if directory && !directory.closed?
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
           Errno::EISDIR => error
      raise_state_error(code, "relative directory is unavailable", {"path" => name, "cause" => error.class.name})
    end

    def open_relative_directory(parent_directory, name)
      validate_relative_name!(name)
      unless posix_backend?
        path = File.join(parent_directory.path, name)
        stat = File.lstat(path)
        unless stat.directory? && !stat.symlink?
          raise_state_error("unsafe_path", "relative directory identity is unsafe", {"path" => name})
        end
        return PortableDirectory.new(path)
      end

      flags = File::RDONLY | O_DIRECTORY | NOFOLLOW_FLAG
      file = posix_open_relative(parent_directory, name, flags)
      PosixDirectory.new(File.join(parent_directory.path, name), file)
    end

    def with_bound_directory(path, code: "unsafe_path", expected_identity: nil)
      expanded = secure_directory(path)
      expected = File.lstat(expanded)
      directory = open_bound_directory(expanded, code: code)
      begin
        unless directory.stat.directory? && same_identity?(expected, directory.stat)
          raise_state_error(code, "directory changed while it was opened", {"path" => expanded})
        end
        if expected_identity && !same_identity?(expected_identity, directory.stat)
          raise_state_error(code, "directory identity does not match authenticated state", {"path" => expanded})
        end
        verify_directory_identity!(expanded, directory, code: code)
        yield expanded, directory
      ensure
        directory.close if directory && !directory.closed?
      end
    end

    def open_bound_directory(expanded, code: "unsafe_path")
      return PortableDirectory.new(expanded) unless posix_backend?

      file = File.open(expanded, File::RDONLY | NOFOLLOW_FLAG)
      PosixDirectory.new(expanded, file)
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
           Errno::EISDIR => error
      raise_state_error(code, "directory is unavailable", {"path" => expanded, "cause" => error.class.name})
    end

    def verify_directory_identity!(path, directory, code: "unsafe_path")
      current = File.lstat(path)
      return true if current.directory? && !current.symlink? && same_identity?(current, directory.stat)

      raise_state_error(code, "directory identity changed during atomic operation", {"path" => path})
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
      raise_state_error(code, "directory identity changed during atomic operation", {"path" => path})
    end

    # Returns true when inode identity is unavailable: the comparison cannot be
    # performed on this host, and `guarantees` already reports it as absent.
    def same_identity?(left, right)
      return true unless INODE_IDENTITY

      left.dev == right.dev && left.ino == right.ino
    end

    # `File.absolute_path(path) == path` is the canonical-absolute test used
    # throughout, but it rejects `C:\dir` because expand_path returns forward
    # slashes. Normalize separators only where the host actually treats the
    # backslash as one: on POSIX it is a legal filename character, and rewriting
    # it there would let a relative `\foo` masquerade as absolute.
    def canonical_absolute_path?(path)
      return false unless path.is_a?(String) && !path.empty?

      candidate = File::ALT_SEPARATOR ? path.tr(File::ALT_SEPARATOR, File::SEPARATOR) : path
      File.absolute_path(candidate) == candidate
    end

    def open_relative(directory, name, flags, mode = 0)
      validate_relative_name!(name)
      return posix_open_relative(directory, name, flags, mode) if posix_backend?

      portable_flags = (flags & ~NOFOLLOW_FLAG) | BINARY_FLAG
      path = File.join(directory.path, name)
      reject_symlink_component!(path)
      File.open(path, portable_flags, mode)
    end

    def posix_open_relative(directory, name, flags, mode = 0)
      descriptor = Native.openat(directory.fileno, name, flags, mode)
      raise_native_error("openat", name) if descriptor.negative?

      io_mode = if (flags & File::RDWR) != 0
                  "r+"
                elsif (flags & File::WRONLY) != 0
                  "w"
                else
                  "r"
                end
      File.new(descriptor, io_mode)
    end

    # The portable backend cannot open a path and prove atomically that the last
    # component was not a symlink. Checking first narrows the window; it does not
    # close it, which is exactly what `descriptor_relative_paths` false declares.
    def reject_symlink_component!(path)
      return true unless File.symlink?(path)

      raise_state_error("unsafe_path", "path component must not be a symlink", {"path" => path})
    end

    def reject_relative_nonregular(directory, name, code = "unsafe_path")
      flags = File::RDONLY | NOFOLLOW_FLAG
      flags |= Fcntl::O_NONBLOCK if Fcntl.const_defined?(:O_NONBLOCK)
      file = open_relative(directory, name, flags)
      unless file.stat.file?
        raise_state_error(code, "path must be a regular file", {"path" => name})
      end
      true
    rescue Errno::ENOENT
      false
    # POSIX opens a directory and reports stat.file? false; Windows refuses the
    # open outright. Both mean "present but not a regular file", so they must
    # reach the same rejection rather than escaping as an unhandled Errno.
    rescue Errno::EISDIR
      raise_state_error(code, "path must be a regular file", {"path" => name})
    ensure
      file.close if defined?(file) && file && !file.closed?
    end

    # POSIX lets a rename or unlink proceed while other handles are open on the
    # target; Windows denies it, including for the transient handles antivirus
    # and search indexers take. That denial is momentary, so retry briefly and
    # then surface the original error. Only the portable path needs this: the
    # POSIX backend never hits the condition.
    SHARING_RETRY_ATTEMPTS = 25
    SHARING_RETRY_INTERVAL = 0.01

    def with_sharing_retry
      attempts = 0
      begin
        yield
      rescue Errno::EACCES, Errno::EPERM
        attempts += 1
        raise if attempts >= SHARING_RETRY_ATTEMPTS

        sleep SHARING_RETRY_INTERVAL
        retry
      end
    end

    def rename_relative(directory, source, destination)
      validate_relative_name!(source)
      validate_relative_name!(destination)
      unless posix_backend?
        # File.rename replaces an existing destination on both POSIX and Win32.
        with_sharing_retry do
          File.rename(File.join(directory.path, source), File.join(directory.path, destination))
        end
        return true
      end

      result = Native.renameat(directory.fileno, source, directory.fileno, destination)
      raise_native_error("renameat", "#{source} -> #{destination}") if result.negative?

      true
    end

    def link_relative(directory, source, destination)
      validate_relative_name!(source)
      validate_relative_name!(destination)
      unless posix_backend?
        File.link(File.join(directory.path, source), File.join(directory.path, destination))
        return true
      end

      result = Native.linkat(directory.fileno, source, directory.fileno, destination, 0)
      raise_native_error("linkat", "#{source} -> #{destination}") if result.negative?

      true
    end

    def unlink_relative(directory, name, flags = 0)
      validate_relative_name!(name)
      unless posix_backend?
        path = File.join(directory.path, name)
        begin
          with_sharing_retry do
            flags == AT_REMOVEDIR ? Dir.rmdir(path) : File.unlink(path)
          end
        rescue Errno::ENOENT
          nil
        end
        return true
      end

      result = Native.unlinkat(directory.fileno, name, flags)
      raise_native_error("unlinkat", name) if result.negative? && Fiddle.last_error != Errno::ENOENT::Errno

      true
    end

    def validate_relative_name!(name)
      return if name.is_a?(String) && !name.empty? && File.basename(name) == name && !%w[. ..].include?(name)

      raise_state_error("unsafe_path", "descriptor-relative path name is unsafe", {"path" => name})
    end

    def raise_native_error(operation, path)
      error_number = Fiddle.last_error
      raise SystemCallError.new("#{operation} #{path}", error_number)
    end

    def open_lock(path, exclusive:, expected_directory_identity: nil,
                  identity_code: "unsafe_lock")
      name = File.basename(path)
      anchor_name = "#{name}.anchor"
      with_bound_directory(
        File.dirname(path),
        code: identity_code,
        expected_identity: expected_directory_identity
      ) do |parent, directory|
        flags = File::RDWR | NOFOLLOW_FLAG
        file = nil
        anchor = nil
        directory_locked = false
        begin
          if directory.supports_directory_lock?
            unless directory.flock(exclusive ? File::LOCK_EX : File::LOCK_SH)
              raise_state_error("unsafe_lock", "run directory lock could not be acquired", {"path" => parent})
            end
            directory_locked = true
          end
          verify_directory_identity!(parent, directory, code: "unsafe_lock")
          file = open_relative(directory, name, flags)
          anchor = open_relative(directory, anchor_name, flags)
          verify_lock_pair!(file, anchor, parent, name, anchor_name, path)
          verify_directory_identity!(parent, directory, code: "unsafe_lock")
          acquired = file.flock(exclusive ? File::LOCK_EX : File::LOCK_SH)
          unless acquired
            raise_state_error("unsafe_lock", "state lock could not be acquired", {"path" => path})
          end
          verify_lock_pair!(file, anchor, parent, name, anchor_name, path)
          verify_directory_identity!(parent, directory, code: "unsafe_lock")
          yield file, directory
        ensure
          file.flock(File::LOCK_UN) if file && !file.closed?
          file.close if file && !file.closed?
          anchor.close if anchor && !anchor.closed?
          directory.flock(File::LOCK_UN) if directory_locked && !directory.closed?
        end
      end
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
           Errno::EISDIR => error
      raise_state_error("unsafe_lock", "state lock is unsafe", {"path" => path, "cause" => error.class.name})
    end

    def create_anchored_lock(path)
      name = File.basename(path)
      anchor_name = "#{name}.anchor"
      with_bound_directory(File.dirname(path), code: "unsafe_lock") do |parent, directory|
        flags = File::WRONLY | File::CREAT | File::EXCL | NOFOLLOW_FLAG
        created_lock = false
        created_anchor = false
        published = false
        begin
          file = open_relative(directory, name, flags, 0o600)
          created_lock = true
          begin
            file.chmod(0o600)
            file.flush
            file.fsync
          ensure
            file.close unless file.closed?
          end
          verify_directory_identity!(parent, directory, code: "unsafe_lock")
          link_relative(directory, name, anchor_name)
          created_anchor = true
          directory.fsync
          verify_directory_identity!(parent, directory, code: "unsafe_lock")
          published = true
        ensure
          if !published && created_anchor
            unlink_relative(directory, anchor_name)
          end
          if !published && created_lock
            unlink_relative(directory, name)
          end
        end
      end
      path
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EEXIST,
           Errno::EACCES, Errno::EPERM, Errno::EISDIR => error
      raise_state_error("unsafe_lock", "state lock could not be created safely", {"path" => path, "cause" => error.class.name})
    end

    def verify_lock_identity!(file, anchor, path)
      return true if same_identity?(file.stat, anchor.stat)

      raise_state_error("unsafe_lock", "state lock identity does not match its anchor", {"path" => path})
    end

    def verify_lock_pair!(file, anchor, parent, name, anchor_name, path)
      reject_lock_handle(file, File.join(parent, name))
      reject_lock_handle(anchor, File.join(parent, anchor_name))
      verify_lock_identity!(file, anchor, path)
    end

    def reject_lock_handle(file, path)
      stat = file.stat
      # Hosts without POSIX permission bits cannot express 0600, so asserting it
      # there would reject every lock the backend just created. This is probed
      # per host, not inferred from the backend: `guarantees` reports
      # `posix_permissions` false rather than implying the check ran.
      return true if stat.file? && (!POSIX_PERMISSIONS || (stat.mode & 0o777) == 0o600)

      raise_state_error("unsafe_lock", "state lock must be a private regular file", {"path" => path})
    end

    def read_json(path)
      name = File.basename(path)
      with_bound_directory(File.dirname(path)) do |parent, directory|
        read_json_relative(directory, name) do
          verify_directory_identity!(parent, directory)
        end
      end
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
           Errno::EISDIR => error
      raise_state_error("unsafe_path", "persisted state path is unsafe", {"path" => path, "cause" => error.class.name})
    end

    def reject_symlink_or_nonregular(path, code = "unsafe_path")
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink?
        raise_state_error(code, "path must be a regular file", {"path" => path})
      end
      true
    rescue Errno::ENOENT
      raise
    end

    def reject_nonregular_handle(file, path, code = "unsafe_path")
      return if file.stat.file?

      raise_state_error(code, "opened path must be a regular file", {"path" => path})
    end

    def fsync_directory(directory)
      return 0 unless posix_backend?

      File.open(directory, File::RDONLY) { |file| file.fsync }
    end

    def secure_directory(path)
      expanded = normalize_root_alias(File.expand_path(path))
      cursor = path_root(expanded)
      relative_components(expanded).each do |segment|
        cursor = File.join(cursor, segment)
        stat = File.lstat(cursor)
        unless stat.directory? && !stat.symlink?
          raise_state_error("unsafe_path", "path component must be a real directory", {"path" => cursor})
        end
      end
      expanded
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES, Errno::EPERM,
           Errno::EISDIR => error
      raise_state_error("unsafe_path", "path component is unsafe", {"path" => cursor || path, "cause" => error.class.name})
    end

    # "/a/b" -> "/", "C:/a/b" -> "C:/", "//host/share/a" -> "//host/share/".
    def path_root(expanded)
      case expanded
      when %r{\A([A-Za-z]:)[/\\]} then "#{Regexp.last_match(1)}/"
      when %r{\A(//[^/]+/[^/]+)/} then "#{Regexp.last_match(1)}/"
      else File::SEPARATOR
      end
    end

    def relative_components(expanded)
      root = path_root(expanded)
      expanded[root.length..].to_s.split(File::SEPARATOR).reject(&:empty?)
    end

    def normalize_root_alias(path)
      return path unless path_root(path) == File::SEPARATOR

      segments = relative_components(path)
      return path if segments.empty?

      first = File.join(File::SEPARATOR, segments.first)
      return path unless File.lstat(first).symlink?

      File.join(File.realpath(first), *segments.drop(1))
    rescue Errno::ENOENT
      path
    end

    def raise_state_error(code, message, details, exit_status = 2)
      raise AdversarialReview::State::Error.new(code, message, details, exit_status)
    end
  end
end
