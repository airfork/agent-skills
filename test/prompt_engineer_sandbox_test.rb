require "minitest/autorun"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../scripts/lib", __dir__))
begin
  require "prompt_engineer/sandbox"
  require "prompt_engineer/sandbox/darwin"
rescue LoadError
  module PromptEngineer
    module Sandbox
    end
  end
end

class PromptEngineerSandboxTest < Minitest::Test
  SANDBOX = PromptEngineer::Sandbox
  CLI = File.expand_path("../scripts/prompt-engineer-sandbox", __dir__)

  def test_accepts_a_closed_executor_launch_packet
    packet = valid_packet

    assert_equal packet, SANDBOX.validate_launch_packet!(packet)
  end

  def test_rejects_unknown_launch_packet_fields
    packet = valid_packet.merge("unexpected" => true)

    error = assert_raises(SANDBOX::ValidationError) do
      SANDBOX.validate_launch_packet!(packet)
    end

    assert_equal "unknown_field", error.code
  end

  def test_rejects_relative_and_escaping_paths
    ["relative/run", "/tmp/run/../outside", "/tmp/run/./output"].each do |path|
      packet = valid_packet.merge("run_root" => path)

      error = assert_raises(SANDBOX::ValidationError) do
        SANDBOX.validate_launch_packet!(packet)
      end

      assert_equal "invalid_path", error.code, path
    end
  end

  def test_write_roots_must_be_narrow_unique_descendants_of_run_root
    packet = valid_packet.merge(
      "write_roots" => ["/tmp/prompt-engineer-run/output", "/tmp/prompt-engineer-run"]
    )

    error = assert_raises(SANDBOX::ValidationError) do
      SANDBOX.validate_launch_packet!(packet)
    end

    assert_equal "invalid_write_root", error.code
  end

  def test_rejects_credential_and_network_environment_variables
    ["OPENAI_API_KEY", "SSH_AUTH_SOCK", "HTTPS_PROXY", "SERVICE_TOKEN"].each do |name|
      packet = valid_packet.merge("environment_allowlist" => ["LANG", name].sort)

      error = assert_raises(SANDBOX::ValidationError) do
        SANDBOX.validate_launch_packet!(packet)
      end

      assert_equal "forbidden_environment", error.code, name
    end
  end

  def test_rejects_unsorted_duplicate_allowlists_and_invalid_timeout
    packet = valid_packet.merge(
      "environment_allowlist" => ["PATH", "LANG"],
      "runtime_read_allowlist" => [
        "/tmp/prompt-engineer-run/staged",
        "/tmp/prompt-engineer-run/staged"
      ],
      "timeout_seconds" => 0
    )

    error = assert_raises(SANDBOX::ValidationError) do
      SANDBOX.validate_launch_packet!(packet)
    end

    assert_equal "invalid_allowlist", error.code

    packet = valid_packet.merge("timeout_seconds" => 0)
    error = assert_raises(SANDBOX::ValidationError) do
      SANDBOX.validate_launch_packet!(packet)
    end
    assert_equal "invalid_timeout", error.code
  end

  def test_rejects_a_result_directory_outside_declared_write_roots
    error = assert_raises(SANDBOX::ValidationError) do
      SANDBOX.validate_launch_request!(
        valid_packet,
        run_dir: "/tmp/prompt-engineer-run",
        result_dir: "/tmp/not-allowed"
      )
    end

    assert_equal "result_root_not_allowed", error.code
  end

  def test_attestation_requires_packet_digest_and_nonce_binding
    packet = valid_packet
    attestation = valid_attestation(packet)

    assert_equal attestation, SANDBOX.validate_attestation!(attestation, packet: packet)

    error = assert_raises(SANDBOX::ValidationError) do
      SANDBOX.validate_attestation!(
        attestation.merge("nonce" => "different-nonce"), packet: packet
      )
    end
    assert_equal "nonce_mismatch", error.code

    error = assert_raises(SANDBOX::ValidationError) do
      SANDBOX.validate_attestation!(
        attestation.merge("packet_digest" => digest("different")), packet: packet
      )
    end
    assert_equal "packet_digest_mismatch", error.code
  end

  def test_darwin_probe_is_explicitly_not_launch_capable_without_native_evidence
    result = PromptEngineer::Sandbox.probe(host: "codex", platform: "x86_64-darwin")

    assert_equal false, result.fetch("launch_supported")
    assert_equal false, result.fetch("qualification_capable")
    assert_includes result.fetch("reasons"), "host_auth_unproven"
    assert_includes result.fetch("reasons"), "provider_reachability_unproven"
    assert_includes result.fetch("reasons"), "tool_isolation_unproven"
  end

  def test_cli_rejects_a_valid_packet_with_json_safe_unsupported_launch_error
    Dir.mktmpdir("prompt-engineer-sandbox") do |root|
      packet = valid_packet(root: root)
      packet_path = File.join(root, "packet.json")
      File.write(packet_path, JSON.generate(packet))
      result_dir = File.join(root, "output")
      Dir.mkdir(result_dir)

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, CLI, "launch", "--run-dir", root, "--packet", packet_path,
        "--result-dir", result_dir
      )

      assert_equal 3, status.exitstatus
      assert_empty stdout
      error = JSON.parse(stderr).fetch("error")
      assert_equal "live_launch_unsupported", error.fetch("code")
      refute_includes stderr, "backtrace"
    end
  end

  def test_cli_probe_reports_unsupported_without_running_a_host
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, CLI, "probe", "--host", "claude", "--json"
    )

    assert_equal 3, status.exitstatus
    assert_empty stderr
    result = JSON.parse(stdout)
    assert_equal false, result.fetch("launch_supported")
    assert_equal false, result.fetch("qualification_capable")
  end

  private

  def valid_packet(root: "/tmp/prompt-engineer-run")
    {
      "schema_version" => 1,
      "kind" => "executor",
      "run_id" => "run-123",
      "case_id" => "PE-001",
      "host" => "codex",
      "arm_id" => "arm-opaque",
      "repeat_index" => 0,
      "nonce" => "nonce-12345678",
      "lease_id" => "lease-123",
      "reservation_id" => "reservation-123",
      "argv" => ["/usr/bin/codex", "exec", "--json"],
      "executable_path" => "/usr/bin/codex",
      "run_root" => root,
      "run_root_identity" => {"device" => 1, "inode" => 2},
      "ledger_path" => "ledger/events.jsonl",
      "lease_event_digest" => digest("lease-event"),
      "staged_roots" => [
        {
          "path" => File.join(root, "staged"),
          "device" => 1,
          "inode" => 3,
          "digest" => digest("staged")
        }
      ],
      "environment_allowlist" => ["LANG", "PATH"],
      "runtime_read_allowlist" => [File.join(root, "staged")],
      "write_roots" => [
        File.join(root, "output"),
        File.join(root, "scratch")
      ],
      "provider_endpoint_policy" => {
        "mode" => "provider_only",
        "allowed_hosts" => ["api.example.test"]
      },
      "timeout_seconds" => 120,
      "expected_package_digest" => digest("package"),
      "expected_input_digest" => digest("input")
    }
  end

  def valid_attestation(packet)
    {
      "schema_version" => 1,
      "status" => "completed",
      "kind" => packet.fetch("kind"),
      "run_id" => packet.fetch("run_id"),
      "case_id" => packet.fetch("case_id"),
      "host" => packet.fetch("host"),
      "nonce" => packet.fetch("nonce"),
      "packet_digest" => SANDBOX.digest(packet),
      "wrapper_digest" => digest("wrapper"),
      "profile_digest" => digest("profile"),
      "self_probe" => {
        "filesystem" => "pass",
        "environment" => "pass",
        "network" => "pass",
        "credentials" => "pass",
        "descriptors" => "pass"
      },
      "child" => {"pid" => 123, "exit_status" => 0},
      "native_export_digest" => digest("native-export"),
      "post_run_rehashes" => [
        {"path" => packet.fetch("staged_roots").fetch(0).fetch("path"), "digest" => digest("after")}
      ],
      "descriptor_audit" => {"inherited_result_descriptors" => false}
    }
  end

  def digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end
end
