require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "../scripts/lib/prompt_engineer"
require_relative "../scripts/lib/prompt_engineer/cli"

class PromptEngineerCliTest < Minitest::Test
  def test_choices_writes_canonical_record_and_returns_it_as_json
    Dir.mktmpdir("prompt-engineer-cli") do |directory|
      output_path = File.join(directory, "choices.json")
      stdout, stderr, status = invoke(
        "choices",
        "--codex-model", "gpt-test",
        "--codex-effort", "high",
        "--claude-model", "claude-test",
        "--claude-effort", "medium",
        "--codex-timeout", "300",
        "--claude-timeout", "301",
        "--max-usd", "25.00",
        "--codex-cap-usd", "12.50",
        "--claude-cap-usd", "12.50",
        "--output", output_path
      )

      assert_equal 0, status
      assert_equal "", stderr
      expected = {
        "schema_version" => 1,
        "codex" => {"model" => "gpt-test", "effort" => "high", "timeout_seconds" => 300},
        "claude" => {"model" => "claude-test", "effort" => "medium", "timeout_seconds" => 301},
        "money_limit_usd" => 25.0,
        "provider_cap_partition" => {"codex" => 12.5, "claude" => 12.5}
      }
      assert_equal expected, JSON.parse(stdout)
      assert_equal stdout, File.binread(output_path)
      assert_equal stdout, PromptEngineer::Canonical.json(JSON.parse(stdout))
    end
  end

  def test_choices_rejects_overwrite_and_budget_partition_overflow
    Dir.mktmpdir("prompt-engineer-cli") do |directory|
      output_path = File.join(directory, "choices.json")
      args = [
        "choices", "--codex-model", "gpt-test", "--codex-effort", "high",
        "--claude-model", "claude-test", "--claude-effort", "high",
        "--codex-timeout", "300", "--claude-timeout", "300",
        "--max-usd", "10", "--codex-cap-usd", "6", "--claude-cap-usd", "5",
        "--output", output_path
      ]

      _stdout, stderr, status = invoke(*args)
      assert_equal 2, status
      assert_equal "budget_partition_exceeds_limit", JSON.parse(stderr).fetch("error").fetch("code")
      refute File.exist?(output_path)

      valid_args = args.each_slice(2).flat_map { |pair| pair }
      valid_args[valid_args.index("--max-usd") + 1] = "12"
      _stdout, _stderr, status = invoke(*valid_args)
      assert_equal 0, status

      _stdout, stderr, status = invoke(*valid_args)
      assert_equal 2, status
      assert_equal "output_exists", JSON.parse(stderr).fetch("error").fetch("code")
    end
  end

  def test_status_is_read_only_and_reports_native_capability_boundary
    stdout, stderr, status = invoke("status")

    assert_equal 0, status
    assert_equal "", stderr
    payload = JSON.parse(stdout)
    assert_equal "unsupported", payload.fetch("live_operations").fetch("launch")
    assert_equal "unsupported", payload.fetch("live_operations").fetch("network")
    assert_equal %w[claude codex], payload.fetch("capabilities").keys.sort
    payload.fetch("capabilities").each_value do |capability|
      assert_equal "unsupported", capability.fetch("status")
      assert_equal "absent", capability.fetch("normalizer")
    end
  end

  def test_unsupported_live_subcommands_fail_closed_with_json_errors
    stdout, stderr, status = invoke("next", "--run-dir", "/nonexistent/run")

    assert_equal "", stdout
    assert_equal 3, status
    error = JSON.parse(stderr).fetch("error")
    assert_equal "unsupported", error.fetch("code")
    assert_includes error.fetch("message"), "live host execution"
  end

  private

  def invoke(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    status = PromptEngineer::CLI.run(argv, stdout: stdout, stderr: stderr)
    [stdout.string, stderr.string, status]
  end
end
