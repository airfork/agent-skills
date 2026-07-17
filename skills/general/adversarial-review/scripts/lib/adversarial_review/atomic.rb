require "json"
require "securerandom"
require "fiddle/import"
require "fcntl"

module AdversarialReview
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

    module Native
      extend Fiddle::Importer

      begin
        dlload Fiddle.dlopen(nil)
        extern "int openat(int, const char*, int, int)"
        extern "int linkat(int, const char*, int, const char*, int)"
        extern "int renameat(int, const char*, int, const char*)"
        extern "int unlinkat(int, const char*, int)"
        AVAILABLE = true
      rescue Fiddle::DLError
        AVAILABLE = false
      end
    end

    module_function

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
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error("unsafe_path", "atomic write path is unsafe", {"path" => path, "cause" => error.class.name})
    end

    def write_json_relative(directory, destination_name, value, temporary_name: nil)
      validate_relative_name!(destination_name)
      temporary_name ||= ".#{destination_name}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
      validate_relative_name!(temporary_name)
      created = false
      begin
        reject_relative_nonregular(directory, destination_name)
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        file = open_relative(directory, temporary_name, flags, 0o600)
        created = true
        begin
          file.chmod(0o600)
          file.write(JSON.generate(value))
          file.write("\n")
          file.flush
          file.fsync
        ensure
          file.close unless file.closed?
        end
        yield if block_given?
        reject_relative_nonregular(directory, destination_name)
        rename_relative(directory, temporary_name, destination_name)
        created = false
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
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error(
        "unsafe_path", "atomic write path is unsafe",
        {"path" => destination_name, "cause" => error.class.name}
      )
    end

    def write_new_json(directory, destination_name, value)
      validate_relative_name!(destination_name)
      temporary_name = ".#{destination_name}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
      created = false
      begin
        if reject_relative_nonregular(directory, destination_name, "task_collision")
          raise_state_error(
            "task_collision", "task bundle already exists", {"path" => destination_name}
          )
        end
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        file = open_relative(directory, temporary_name, flags, 0o600)
        created = true
        begin
          file.chmod(0o600)
          file.write(JSON.generate(value))
          file.write("\n")
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
    rescue Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error(
        "unsafe_task_path", "task bundle path is unsafe",
        {"path" => destination_name, "cause" => error.class.name}
      )
    end

    def read_json_relative(directory, name, code: "invalid_json", unsafe_code: "unsafe_path",
                           unsafe_exit_status: 2)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      file = open_relative(directory, name, flags)
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
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error(
        unsafe_code, "persisted JSON is unavailable",
        {"path" => name, "cause" => error.class.name}, unsafe_exit_status
      )
    end

    def with_relative_directory(parent_directory, name, expected_identity: nil,
                                code: "unsafe_path")
      flags = File::RDONLY | O_DIRECTORY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      directory = open_relative(parent_directory, name, flags)
      begin
        stat = directory.stat
        unless stat.directory? && (!expected_identity || same_identity?(expected_identity, stat))
          raise_state_error(code, "relative directory identity is unsafe", {"path" => name})
        end
        yield directory
      ensure
        directory.close if directory && !directory.closed?
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error(code, "relative directory is unavailable", {"path" => name, "cause" => error.class.name})
    end

    def with_bound_directory(path, code: "unsafe_path", expected_identity: nil)
      unless Native::AVAILABLE
        raise_state_error(code, "descriptor-relative filesystem operations are unavailable", {"path" => path})
      end

      expanded = secure_directory(path)
      expected = File.lstat(expanded)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(expanded, flags) do |directory|
        unless directory.stat.directory? && same_identity?(expected, directory.stat)
          raise_state_error(code, "directory changed while it was opened", {"path" => expanded})
        end
        if expected_identity && !same_identity?(expected_identity, directory.stat)
          raise_state_error(code, "directory identity does not match authenticated state", {"path" => expanded})
        end
        verify_directory_identity!(expanded, directory, code: code)
        yield expanded, directory
      end
    end

    def verify_directory_identity!(path, directory, code: "unsafe_path")
      current = File.lstat(path)
      return true if current.directory? && !current.symlink? && same_identity?(current, directory.stat)

      raise_state_error(code, "directory identity changed during atomic operation", {"path" => path})
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
      raise_state_error(code, "directory identity changed during atomic operation", {"path" => path})
    end

    def same_identity?(left, right)
      left.dev == right.dev && left.ino == right.ino
    end

    def open_relative(directory, name, flags, mode = 0)
      validate_relative_name!(name)
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

    def reject_relative_nonregular(directory, name, code = "unsafe_path")
      flags = File::RDONLY
      flags |= Fcntl::O_NONBLOCK if Fcntl.const_defined?(:O_NONBLOCK)
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      file = open_relative(directory, name, flags)
      unless file.stat.file?
        raise_state_error(code, "path must be a regular file", {"path" => name})
      end
      true
    rescue Errno::ENOENT
      false
    ensure
      file.close if defined?(file) && file && !file.closed?
    end

    def rename_relative(directory, source, destination)
      validate_relative_name!(source)
      validate_relative_name!(destination)
      result = Native.renameat(directory.fileno, source, directory.fileno, destination)
      raise_native_error("renameat", "#{source} -> #{destination}") if result.negative?

      true
    end

    def link_relative(directory, source, destination)
      validate_relative_name!(source)
      validate_relative_name!(destination)
      result = Native.linkat(directory.fileno, source, directory.fileno, destination, 0)
      raise_native_error("linkat", "#{source} -> #{destination}") if result.negative?

      true
    end

    def unlink_relative(directory, name, flags = 0)
      validate_relative_name!(name)
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
        flags = File::RDWR
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        file = nil
        anchor = nil
        directory_locked = false
        begin
          acquired_directory = directory.flock(exclusive ? File::LOCK_EX : File::LOCK_SH)
          unless acquired_directory
            raise_state_error("unsafe_lock", "run directory lock could not be acquired", {"path" => parent})
          end
          directory_locked = true
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
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error("unsafe_lock", "state lock is unsafe", {"path" => path, "cause" => error.class.name})
    end

    def create_anchored_lock(path)
      name = File.basename(path)
      anchor_name = "#{name}.anchor"
      with_bound_directory(File.dirname(path), code: "unsafe_lock") do |parent, directory|
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
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
           Errno::EACCES, Errno::EPERM => error
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
      return true if stat.file? && (stat.mode & 0o777) == 0o600

      raise_state_error("unsafe_lock", "state lock must be a private regular file", {"path" => path})
    end

    def read_json(path)
      name = File.basename(path)
      with_bound_directory(File.dirname(path)) do |parent, directory|
        read_json_relative(directory, name) do
          verify_directory_identity!(parent, directory)
        end
      end
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
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
      File.open(directory, File::RDONLY) { |file| file.fsync }
    end

    def secure_directory(path)
      expanded = normalize_root_alias(File.expand_path(path))
      cursor = File::SEPARATOR
      expanded.split(File::SEPARATOR).reject(&:empty?).each do |segment|
        cursor = File.join(cursor, segment)
        stat = File.lstat(cursor)
        unless stat.directory? && !stat.symlink?
          raise_state_error("unsafe_path", "path component must be a real directory", {"path" => cursor})
        end
      end
      expanded
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES, Errno::EPERM => error
      raise_state_error("unsafe_path", "path component is unsafe", {"path" => cursor || path, "cause" => error.class.name})
    end

    def normalize_root_alias(path)
      segments = path.split(File::SEPARATOR).reject(&:empty?)
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
