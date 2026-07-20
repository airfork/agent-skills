require "json"
require "minitest/autorun"
require "open3"
require_relative "../scripts/lib/prompt_engineer"
require_relative "../scripts/lib/prompt_engineer/sandbox/darwin"

class PromptEngineerSandboxTest < Minitest::Test
  def packet
    base = {
      "kind" => "executor", "run_id" => "run-1", "case_id" => "PE-001", "nonce" => "n-1",
      "lease_id" => "lease-1", "reservation_id" => "res-1", "argv_template" => ["host", "--packet"],
      "executable_realpath" => "/usr/bin/host", "run_root_identity" => {"device" => 1, "inode" => 2},
      "environment_allowlist" => ["PATH"], "runtime_read_allowlist" => ["/bin"], "write_roots" => ["/tmp/run"],
      "endpoint_policy" => {"network" => "deny"}, "timeout_seconds" => 30, "expected_package_digest" => "a" * 64
    }
    base["packet_digest"] = PromptEngineer::Sandbox.packet_digest(base)
    base
  end

  def test_validates_closed_packet_and_digest
    assert_equal packet, PromptEngineer::Sandbox.validate_launch_packet!(packet)
    tampered = packet.merge("write_roots" => ["/tmp/other"])
    assert_raises(PromptEngineer::Sandbox::Error) { PromptEngineer::Sandbox.validate_launch_packet!(tampered) }
  end

  def test_live_launch_is_fail_closed
    assert_equal "unsupported", PromptEngineer::Sandbox.capability.fetch("status")
    assert_raises(PromptEngineer::Sandbox::UnsupportedError) { PromptEngineer::Sandbox.launch!(packet) }
  end

  def test_cli_reports_unsupported_without_starting_a_process
    stdout, stderr, status = Open3.capture3(File.join(__dir__, "../scripts/prompt-engineer-sandbox"), "launch")
    assert_equal "", stdout
    assert_equal 3, status.exitstatus
    assert_equal "unsupported", JSON.parse(stderr).fetch("error").fetch("code")
  end
end
