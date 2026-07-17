require "minitest/autorun"
require "fileutils"
require "tmpdir"

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
end
