require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "timeout"

SKILL = File.expand_path("../skills/general/adversarial-review", __dir__) unless defined?(SKILL)
$LOAD_PATH.unshift(File.join(SKILL, "scripts", "lib"))
require "adversarial_review"
require_relative "support/adversarial_review_helper"

class AdversarialReviewSecurityTest < Minitest::Test
  include AdversarialReviewHelper

  def test_child_gets_only_explicit_environment_and_canonical_repository
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-bin") do |bin|
        log = File.join(bin, "log.jsonl")
        fake = write_fake_executable(bin)
        previous_secret = ENV["ADVERSARIAL_REVIEW_SECRET"]
        previous_rubyopt = ENV["RUBYOPT"]
        ENV["ADVERSARIAL_REVIEW_SECRET"] = "do-not-forward"
        ENV["RUBYOPT"] = "-W0"
        result = AdversarialReview::Runner.run(
          argv: [fake], stdin_data: "", timeout_seconds: 2,
          chdir: File.join(repository, "."),
          env: {"FAKE_CLI_LOG" => log, "LANG" => "C"}
        )

        assert_equal 0, result.exit_status
        record = fake_cli_records(log).fetch(0)
        assert_equal File.realpath(repository), record.fetch("cwd")
        child_env = record.fetch("env")
        # macOS injects this locale bootstrap variable after Process.spawn has
        # applied unsetenv_others; it is not inherited from the parent.
        child_env.delete("__CF_USER_TEXT_ENCODING")
        assert_equal({"FAKE_CLI_LOG" => log, "LANG" => "C"}, child_env)
        refute child_env.key?("PATH")
        refute child_env.key?("RUBYOPT")
        refute child_env.key?("ADVERSARIAL_REVIEW_SECRET")
      ensure
        previous_secret ? ENV["ADVERSARIAL_REVIEW_SECRET"] = previous_secret :
          ENV.delete("ADVERSARIAL_REVIEW_SECRET")
        previous_rubyopt ? ENV["RUBYOPT"] = previous_rubyopt : ENV.delete("RUBYOPT")
      end
    end
  end

  def test_rejects_executables_under_controlled_roots_but_allows_explicit_user_bin
    Dir.mktmpdir("adversarial-review-controlled") do |controlled|
      fake = write_fake_executable(controlled)
      error = assert_raises(AdversarialReview::Runner::SecurityError) do
        AdversarialReview::Runner.resolve_executable(fake, excluded_roots: [controlled])
      end
      assert_equal "controlled_executable", error.code

      Dir.mktmpdir("adversarial-review-user-bin") do |user_bin|
        selected = write_fake_executable(user_bin)
        pinned = AdversarialReview::Runner.resolve_executable(
          selected, excluded_roots: [controlled]
        )
        assert_equal File.realpath(selected), pinned.path
      end
    end
  end

  def test_controlled_root_detection_uses_identity_for_case_variant_spelling
    Dir.mktmpdir("AdversarialReviewCaseRoot") do |controlled|
      parent = File.dirname(controlled)
      variant = File.join(parent, File.basename(controlled).swapcase)
      begin
        actual = File.stat(controlled)
        variant_stat = File.stat(variant)
      rescue Errno::ENOENT
        skip "filesystem is case-sensitive"
      end
      unless [actual.dev, actual.ino] == [variant_stat.dev, variant_stat.ino]
        skip "case variant does not resolve to the same directory"
      end
      fake = write_fake_executable(controlled)

      error = assert_raises(AdversarialReview::Runner::SecurityError) do
        AdversarialReview::Runner.resolve_executable(fake, excluded_roots: [variant])
      end
      assert_equal "controlled_executable", error.code
    end
  end

  def test_controlled_root_detection_follows_a_symlink_alias_by_identity
    Dir.mktmpdir("adversarial-review-root") do |parent|
      controlled = File.join(parent, "controlled")
      Dir.mkdir(controlled)
      alias_path = File.join(parent, "alias")
      File.symlink(controlled, alias_path)
      fake = write_fake_executable(controlled)

      error = assert_raises(AdversarialReview::Runner::SecurityError) do
        AdversarialReview::Runner.resolve_executable(fake, excluded_roots: [alias_path])
      end
      assert_equal "controlled_executable", error.code
    end
  end

  def test_rejects_repo_run_and_config_executables
    Dir.mktmpdir("adversarial-review-roots") do |root|
      %w[repository run config].each do |name|
        directory = File.join(root, name)
        FileUtils.mkdir_p(directory)
        fake = write_fake_executable(directory, name: "agent")
        assert_raises(AdversarialReview::Runner::SecurityError, name) do
          AdversarialReview::Runner.resolve_executable(
            fake,
            repository: File.join(root, "repository"),
            run_directory: File.join(root, "run"),
            config_root: File.join(root, "config")
          )
        end
      end
    end
  end

  def test_pinned_executable_detects_an_identity_or_content_swap
    Dir.mktmpdir("adversarial-review-bin") do |bin|
      fake = write_fake_executable(bin)
      pinned = AdversarialReview::Runner.resolve_executable(fake)
      replacement = File.join(bin, "replacement")
      File.write(replacement, "#!/bin/sh\nexit 0\n")
      File.chmod(0o700, replacement)
      File.rename(replacement, fake)

      error = assert_raises(AdversarialReview::Runner::SecurityError) do
        AdversarialReview::Runner.run(
          argv: [pinned.path], stdin_data: "", timeout_seconds: 1,
          executable: pinned
        )
      end
      assert_equal "executable_changed", error.code
    end
  end

  def test_metadata_mismatch_is_rejected_before_descriptor_hashing
    Dir.mktmpdir("adversarial-review-bin") do |bin|
      fake = write_fake_executable(bin)
      pinned = AdversarialReview::Runner.resolve_executable(fake)
      File.chmod(0o755, fake)
      digest_called = false
      open_called = false

      error = AdversarialReview::Runner.stub(
        :hash_descriptor,
        proc { |_file| digest_called = true; raise "digest must not run" }
      ) do
        File.stub(:open, proc { |*_arguments| open_called = true; raise "open must not run" }) do
          assert_raises(AdversarialReview::Runner::SecurityError) do
            AdversarialReview::Runner.verify_executable!(pinned)
          end
        end
      end

      assert_equal "executable_changed", error.code
      assert_equal false, open_called
      assert_equal false, digest_called
    end
  end

  def test_descriptor_identity_is_rechecked_before_hashing_after_open_race
    Dir.mktmpdir("adversarial-review-bin") do |bin|
      fake = write_fake_executable(bin)
      pinned = AdversarialReview::Runner.resolve_executable(fake)
      replacement = File.join(bin, "replacement")
      File.write(replacement, File.binread(fake))
      File.chmod(0o700, replacement)
      original_open = File.method(:open)
      swapped = false
      digest_called = false
      open_with_swap = proc do |*arguments, &block|
        if arguments.fetch(0) == pinned.path && !swapped
          File.rename(replacement, pinned.path)
          swapped = true
        end
        original_open.call(*arguments, &block)
      end

      error = AdversarialReview::Runner.stub(
        :hash_descriptor,
        proc { |_file| digest_called = true; raise "digest must not run" }
      ) do
        File.stub(:open, open_with_swap) do
          assert_raises(AdversarialReview::Runner::SecurityError) do
            AdversarialReview::Runner.verify_executable!(pinned)
          end
        end
      end

      assert_equal "executable_changed", error.code
      assert_equal true, swapped
      assert_equal false, digest_called
    end
  end

  def test_matching_metadata_with_changed_content_is_rejected_by_descriptor_hash
    Dir.mktmpdir("adversarial-review-bin") do |bin|
      fake = write_fake_executable(bin)
      stable_time = Time.at(Time.now.to_i - 10)
      File.utime(stable_time, stable_time, fake)
      pinned = AdversarialReview::Runner.resolve_executable(fake)
      changed = File.binread(fake).tr("a", "b")
      refute_equal File.binread(fake), changed
      File.binwrite(fake, changed)
      File.chmod(pinned.mode & 0o777, fake)
      File.utime(stable_time, stable_time, fake)
      assert_equal pinned.size, File.stat(fake).size
      assert_equal pinned.mtime_ns,
                   File.stat(fake).mtime.to_i * 1_000_000_000 + File.stat(fake).mtime.nsec

      error = assert_raises(AdversarialReview::Runner::SecurityError) do
        AdversarialReview::Runner.verify_executable!(pinned)
      end

      assert_equal "executable_changed", error.code
    end
  end

  def test_executable_metadata_is_rejected_before_a_fifo_can_block_hashing
    Dir.mktmpdir("adversarial-review-bin") do |bin|
      fake = write_fake_executable(bin)
      pinned = AdversarialReview::Runner.resolve_executable(fake)
      File.unlink(fake)
      success = system("/usr/bin/mkfifo", fake)
      raise "mkfifo fixture failed" unless success

      error = Timeout.timeout(0.5) do
        assert_raises(AdversarialReview::Runner::SecurityError) do
          AdversarialReview::Runner.verify_executable!(pinned)
        end
      end
      assert_kind_of AdversarialReview::Runner::SecurityError, error
    end
  end

  def test_run_rechecks_controlled_roots_even_for_an_already_pinned_executable
    Dir.mktmpdir("adversarial-review-controlled") do |controlled|
      fake = write_fake_executable(controlled)
      pinned = AdversarialReview::Runner.resolve_executable(fake)

      error = assert_raises(AdversarialReview::Runner::SecurityError) do
        AdversarialReview::Runner.run(
          argv: [pinned.path], stdin_data: "", timeout_seconds: 1,
          executable: pinned, repository: controlled, chdir: controlled
        )
      end
      assert_equal "controlled_executable", error.code
    end
  end

  def test_repository_argument_binds_the_working_directory
    Dir.mktmpdir("adversarial-review-repository") do |repository|
      Dir.mktmpdir("adversarial-review-other") do |other|
        error = assert_raises(AdversarialReview::Runner::SecurityError) do
          AdversarialReview::Runner.run(
            argv: ruby_script("exit 0"), stdin_data: "", timeout_seconds: 1,
            repository: repository, chdir: other
          )
        end
        assert_equal "working_directory_mismatch", error.code
      end
    end
  end

  def test_runner_rejects_shell_and_ruby_startup_environment
    %w[PATH RUBYOPT RUBYLIB BASH_ENV ENV ZDOTDIR].each do |name|
      error = assert_raises(AdversarialReview::Runner::SecurityError, name) do
        AdversarialReview::Runner.run(
          argv: ruby_script("exit 0"), stdin_data: "", timeout_seconds: 1,
          env: {name => "unsafe"}
        )
      end
      assert_equal "forbidden_environment", error.code, name
    end
  end

  def test_runner_rejects_nan_and_infinite_time_bounds
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |value|
      assert_raises(AdversarialReview::Runner::Error) do
        AdversarialReview::Runner.run(
          argv: ruby_script("exit 0"), stdin_data: "", timeout_seconds: value
        )
      end
      assert_raises(AdversarialReview::Runner::Error) do
        AdversarialReview::Runner.run(
          argv: ruby_script("exit 0"), stdin_data: "", timeout_seconds: 1,
          termination_grace_seconds: value
        )
      end
    end
  end

  def test_no_argument_executable_with_shell_metacharacters_never_uses_a_shell
    Dir.mktmpdir("adversarial-review-metachar") do |directory|
      log = File.join(directory, "log.jsonl")
      fake = write_fake_executable(directory, name: "selected;touch injected")
      result = AdversarialReview::Runner.run(
        argv: [fake], stdin_data: "", timeout_seconds: 2,
        chdir: directory, env: {"FAKE_CLI_LOG" => log}
      )

      assert_equal 0, result.exit_status
      assert_equal 1, fake_cli_records(log).length
      refute File.exist?(File.join(directory, "injected"))
    end
  end

  def test_timeout_terminates_the_process_group_and_descendant
    Dir.mktmpdir("adversarial-review-process") do |directory|
      child_pid_file = File.join(directory, "child.pid")
      script = <<~'RUBY'
        child_pid_file = ARGV.fetch(0)
        child = fork do
          trap("TERM") { }
          loop { sleep 0.05 }
        end
        File.write(child_pid_file, child.to_s)
        trap("TERM") { }
        loop { sleep 0.05 }
      RUBY
      result = AdversarialReview::Runner.run(
        argv: ruby_script(script) + [child_pid_file], stdin_data: "",
        timeout_seconds: 0.15, termination_grace_seconds: 0.1
      )

      assert_equal true, result.timed_out
      child_pid = Integer(File.read(child_pid_file))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      alive = true
      while alive && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        begin
          Process.kill(0, child_pid)
          sleep 0.01
        rescue Errno::ESRCH
          alive = false
        end
      end
      assert_equal false, alive, "descendant remained alive after process-group timeout"
    end
  end

  def test_timeout_kills_resistant_descendant_after_leader_and_readers_exit
    Dir.mktmpdir("adversarial-review-process") do |directory|
      child_pid_file = File.join(directory, "resistant.pid")
      script = <<~'RUBY'
        child_pid_file = ARGV.fetch(0)
        child = fork do
          STDOUT.close
          STDERR.close
          trap("TERM") { }
          loop { sleep 0.05 }
        end
        File.write(child_pid_file, child.to_s)
        STDOUT.close
        STDERR.close
        trap("TERM") { exit! 0 }
        loop { sleep 0.05 }
      RUBY
      before_threads = Thread.list.length
      child_pid = nil
      begin
        result = AdversarialReview::Runner.run(
          argv: ruby_script(script) + [child_pid_file], stdin_data: "x" * 2_000_000,
          timeout_seconds: 0.15, termination_grace_seconds: 0.1
        )
        assert_equal true, result.timed_out
        child_pid = Integer(File.read(child_pid_file))
        assert_process_exits(child_pid)
        assert_operator Thread.list.length, :<=, before_threads
      ensure
        begin
          Process.kill("KILL", child_pid) if child_pid
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end

  def test_output_reader_failure_is_explicit_after_child_cleanup
    failure = proc { |_pipe, _limit| raise "reader exploded" }
    error = AdversarialReview::Runner.stub(:drain, failure) do
      assert_raises(AdversarialReview::Runner::Error) do
        AdversarialReview::Runner.run(
          argv: ruby_script("exit 0"), stdin_data: "", timeout_seconds: 1
        )
      end
    end

    assert_equal "output_read_failed", error.code
  end

  def test_isolated_directory_and_private_file_modes_and_cleanup
    path = nil
    file_path = nil
    AdversarialReview::Runner.with_isolated_directory do |directory|
      path = directory
      file_path = File.join(directory, "config.json")
      AdversarialReview::Runner.write_private_file(file_path, "{}")
      assert_equal 0o700, File.stat(directory).mode & 0o777
      assert_equal 0o600, File.stat(file_path).mode & 0o777
    end
    refute File.exist?(path)
    refute File.exist?(file_path)
  end
  private

  def assert_process_exits(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return
      end
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    flunk "descendant remained alive after process-group cleanup"
  end
end
