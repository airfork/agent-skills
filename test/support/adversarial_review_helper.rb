require "fileutils"
require "open3"
require "json"
require "rbconfig"
require "tmpdir"

module AdversarialReviewHelper
  # The portable filesystem backend deliberately gives up guarantees the POSIX
  # backend enforces (see Atomic.guarantees). A test that exercises one of those
  # guarantees is skipped there with the guarantee named, so the suite documents
  # the difference instead of quietly asserting less.
  def skip_without_posix_backend(guarantee)
    return if AdversarialReview::Atomic.posix_backend?

    skip "portable filesystem backend declares #{guarantee} unavailable"
  end

  # POSIX permission bits are a host property, not a backend one: forcing the
  # portable backend on a POSIX host leaves chmod working, so gating on the
  # backend would silently drop coverage from that leg.
  def skip_without_posix_permissions
    return if AdversarialReview::Atomic::POSIX_PERMISSIONS

    skip "host does not carry POSIX permission bits"
  end

  # Substitution defenses compare a path stat against a handle stat. Where the
  # host cannot supply comparable inode numbers that comparison is skipped by
  # design and reported as `inode_identity` false, so there is no detection to
  # assert -- the operation still fails closed, just at a later check.
  def skip_without_inode_identity
    return if AdversarialReview::Atomic::INODE_IDENTITY

    skip "host cannot supply comparable inode identity"
  end

  # Killing a whole process tree on timeout needs process groups. Runner reports
  # the absence and signals only the direct child instead.
  def skip_without_process_groups
    return if AdversarialReview::Runner::PROCESS_GROUPS

    skip "host has no process groups"
  end

  # The direct adapters -- and Runner, which exists to spawn them -- are
  # ineligible on hosts that cannot mark a file executable, pin POSIX modes, or
  # exec a shebang script. Those runs take the generic bundle path instead, so
  # there is no direct-adapter behavior on such a host to assert.
  def skip_without_direct_adapter_host
    return if AdversarialReview::Atomic::POSIX_PERMISSIONS &&
              AdversarialReviewHelper.shebang_executables_supported?

    skip "host cannot run direct adapters; generic bundles are the path there"
  end

  # Both backends refuse unsafe paths; the portable backend often refuses them at
  # an earlier, coarser check because it has no descriptor to pin.
  def assert_unsafe_code(expected, actual, portable_alternatives: ["unsafe_path"])
    permitted = AdversarialReview::Atomic.posix_backend? ? [expected] : [expected, *portable_alternatives]

    assert_includes permitted, actual
  end

  def with_repository(files: {}, commit: true)
    repository = Dir.mktmpdir("adversarial-review-test")
    begin
      git(repository, "init", "--quiet")
      git(repository, "config", "user.name", "Test User")
      git(repository, "config", "user.email", "test@example.invalid")
      # Background maintenance writes lock files under .git that can disappear
      # while the fixture is being torn down, which surfaces as an ENOENT from
      # deep inside FileUtils rather than as a test failure.
      git(repository, "config", "gc.auto", "0")
      git(repository, "config", "maintenance.auto", "false")

      files.each do |path, contents|
        absolute = File.join(repository, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        # binwrite, not write: text mode rewrites \n to \r\n on some hosts, so
        # the fixture would not contain the bytes the test specified and every
        # content digest computed from it would differ.
        File.binwrite(absolute, contents)
      end

      if commit
        git(repository, "add", ".")
        git(repository, "commit", "--quiet", "--allow-empty", "-m", "fixture")
      end

      yield repository
    ensure
      remove_fixture_tree(repository)
    end
  end

  # Tolerates entries vanishing mid-walk: teardown races are not test results.
  def remove_fixture_tree(path)
    FileUtils.remove_entry(path)
  rescue Errno::ENOENT
    nil
  rescue StandardError
    FileUtils.rm_rf(path, secure: false)
  end

  # The direct adapters are exercised with shebang scripts marked executable via
  # chmod. Windows honors neither, so those tests describe a host the adapters
  # cannot run on at all -- every direct adapter is ineligible there. Skip rather
  # than assert something the platform cannot express.
  def self.shebang_executables_supported?
    return @shebang_executables_supported unless @shebang_executables_supported.nil?

    @shebang_executables_supported = begin
      Dir.mktmpdir("shebang-probe") do |directory|
        probe = File.join(directory, "probe")
        File.write(probe, "#!#{RbConfig.ruby}\nexit 0\n")
        File.chmod(0o700, probe)
        # [path, path] forces a direct exec: a single string would be handed to
        # a shell, which can succeed on hosts that cannot exec the file itself.
        # The exit status matters too -- a host can spawn something and still
        # fail to honor the shebang.
        pid = Process.spawn([probe, probe], out: File::NULL, err: File::NULL)
        _, status = Process.wait2(pid)
        status.success?
      end
    rescue StandardError
      false
    end
  end

  def write_fake_executable(directory, name: "fake-agent", body: nil)
    unless AdversarialReviewHelper.shebang_executables_supported?
      skip "host cannot execute shebang scripts marked executable with chmod"
    end
    path = File.join(directory, name)
    source = body || <<~RUBY
      \#!#{RbConfig.ruby}
      require "json"
      log = ENV.fetch("FAKE_CLI_LOG")
      File.open(log, "a", 0o600) do |file|
        file.puts(JSON.generate({"argv" => ARGV, "stdin" => STDIN.read,
                                "env" => ENV.to_h, "cwd" => Dir.pwd}))
      end
      STDOUT.write(ENV.fetch("FAKE_STDOUT", ""))
      STDERR.write(ENV.fetch("FAKE_STDERR", ""))
      exit(Integer(ENV.fetch("FAKE_EXIT", "0")))
    RUBY
    File.write(path, source)
    File.chmod(0o700, path)
    path
  end

  def fake_cli_records(path)
    return [] unless File.exist?(path)

    File.readlines(path).map { |line| JSON.parse(line) }
  end

  def ruby_script(source)
    [RbConfig.ruby, "-e", source]
  end

  private

  # Spawning a bare "git" without a shell does not find git.exe on every host, so
  # resolve it against PATH and PATHEXT once and invoke it by absolute path.
  def self.git_executable
    return @git_executable unless @git_executable.nil?

    # Where PATHEXT exists the extension-bearing form must win: an extensionless
    # `git` on such a host is typically a shell script, which cannot be spawned
    # directly and fails with ENOEXEC.
    extensions = ENV.fetch("PATHEXT", "").split(File::PATH_SEPARATOR)
    extensions = extensions.empty? ? [""] : extensions + [""]
    @git_executable = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map { |directory|
      next if directory.empty?

      extensions.filter_map { |extension|
        candidate = File.join(directory, "git#{extension}")
        candidate if File.file?(candidate) && File.executable?(candidate)
      }.first
    }.first || "git"
  end

  # Captures output rather than discarding it: a fixture failure on a platform
  # you cannot attach to is only debuggable if the message carries git's own.
  def git(repository, *arguments)
    output, status = Open3.capture2e(
      AdversarialReviewHelper.git_executable, "-C", repository, *arguments
    )
    return if status.success?

    raise "git fixture command failed: #{arguments.join(" ")}\n#{output}"
  end
end
