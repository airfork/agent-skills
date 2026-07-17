require "json"
require "securerandom"

module AdversarialReview
  module Atomic
    module_function

    def write_json(path, value)
      parent = secure_directory(File.dirname(path))
      destination = File.join(parent, File.basename(path))
      reject_symlink_or_nonregular(destination) if File.exist?(destination) || File.symlink?(destination)
      temporary = File.join(parent, ".#{File.basename(path)}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}")
      flags = File::WRONLY | File::CREAT | File::EXCL
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      created = false
      begin
        File.open(temporary, flags, 0o600) do |file|
          created = true
          file.write(JSON.generate(value))
          file.write("\n")
          file.flush
          file.fsync
        end
        File.chmod(0o600, temporary)
        reject_symlink_or_nonregular(destination) if File.exist?(destination) || File.symlink?(destination)
        File.rename(temporary, destination)
        created = false
        fsync_directory(parent)
      rescue Errno::EEXIST
        raise_state_error("unsafe_temp", "atomic temporary path already exists", {"path" => temporary})
      ensure
        File.unlink(temporary) if created && File.exist?(temporary) && !File.symlink?(temporary)
      end
      destination
    rescue Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error("unsafe_path", "atomic write path is unsafe", {"path" => path, "cause" => error.class.name})
    end

    def open_lock(path, exclusive:)
      reject_symlink_or_nonregular(path, "unsafe_lock")
      flags = File::RDWR
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags) do |file|
        reject_nonregular_handle(file, path)
        file.flock(exclusive ? File::LOCK_EX : File::LOCK_SH)
        yield file
      ensure
        file.flock(File::LOCK_UN) if file
      end
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise_state_error("unsafe_lock", "state lock is unsafe", {"path" => path, "cause" => error.class.name})
    end

    def read_json(path)
      reject_symlink_or_nonregular(path)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags) do |file|
        reject_nonregular_handle(file, path)
        JSON.parse(file.read)
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
