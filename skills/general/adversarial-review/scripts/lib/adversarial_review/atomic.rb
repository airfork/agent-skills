require "json"
require "securerandom"
require "fiddle/import"
require "fcntl"

module AdversarialReview
  module Atomic
    module Native
      extend Fiddle::Importer

      begin
        dlload Fiddle.dlopen(nil)
        extern "int openat(int, const char*, int, int)"
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
        destination = File.join(parent, destination_name)
        created = false
        begin
          verify_directory_identity!(parent, directory)
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
          verify_directory_identity!(parent, directory)
          reject_relative_nonregular(directory, destination_name)
          rename_relative(directory, temporary_name, destination_name)
          created = false
          directory.fsync
          verify_directory_identity!(parent, directory)
        rescue Errno::EEXIST
          raise_state_error(
            "unsafe_temp", "atomic temporary path already exists",
            {"path" => File.join(parent, temporary_name)}
          )
        ensure
          unlink_relative(directory, temporary_name) if created
        end
        destination
      end
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error("unsafe_path", "atomic write path is unsafe", {"path" => path, "cause" => error.class.name})
    end

    def with_bound_directory(path, code: "unsafe_path")
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

    def unlink_relative(directory, name)
      validate_relative_name!(name)
      result = Native.unlinkat(directory.fileno, name, 0)
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

    def open_lock(path, exclusive:)
      name = File.basename(path)
      with_bound_directory(File.dirname(path), code: "unsafe_lock") do |parent, directory|
        flags = File::RDWR
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        file = open_relative(directory, name, flags)
        begin
          reject_nonregular_handle(file, File.join(parent, name))
          verify_directory_identity!(parent, directory, code: "unsafe_lock")
          acquired = file.flock(exclusive ? File::LOCK_EX : File::LOCK_SH)
          unless acquired
            raise_state_error("unsafe_lock", "state lock could not be acquired", {"path" => path})
          end
          verify_directory_identity!(parent, directory, code: "unsafe_lock")
          yield file
        ensure
          file.flock(File::LOCK_UN) if file && !file.closed?
          file.close if file && !file.closed?
        end
      end
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error("unsafe_lock", "state lock is unsafe", {"path" => path, "cause" => error.class.name})
    end

    def read_json(path)
      name = File.basename(path)
      with_bound_directory(File.dirname(path)) do |parent, directory|
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        file = open_relative(directory, name, flags)
        begin
          reject_nonregular_handle(file, File.join(parent, name))
          verify_directory_identity!(parent, directory)
          value = JSON.parse(file.read)
          verify_directory_identity!(parent, directory)
          value
        ensure
          file.close if file && !file.closed?
        end
      end
    rescue JSON::ParserError => error
      raise_state_error("invalid_json", "persisted JSON is invalid", {"path" => path, "cause" => error.message}, 3)
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

    def reject_nonregular_handle(file, path)
      return if file.stat.file?

      raise_state_error("unsafe_path", "opened path must be a regular file", {"path" => path})
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
