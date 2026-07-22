require "minitest/autorun"
require_relative "../scripts/lib/prompt_engineer"
require_relative "../scripts/lib/prompt_engineer/cutover"

class PromptEngineerCutoverTest < Minitest::Test
  def test_capability_and_runtime_gates_block_cutover_without_mutation
    decision = PromptEngineer::Cutover.evaluate(
      qualification: "INCONCLUSIVE",
      capabilities: PromptEngineer::Capabilities.report,
      runtime: "ruby-4.0",
      sandbox: "unsupported"
    )
    assert_equal "BLOCKED", decision.fetch("decision")
    refute decision.fetch("mutations_permitted")
    assert_includes decision.fetch("reasons").join("; "), "qualification"
    assert_includes decision.fetch("reasons").join("; "), "sandbox"
    assert_raises(PromptEngineer::Cutover::Error) { PromptEngineer::Cutover.apply!(decision) }
  end

  def test_even_a_ready_shape_cannot_apply_without_explicit_mutating_implementation
    decision = PromptEngineer::Cutover.evaluate(
      qualification: "QUALIFIED_EXPLICIT",
      capabilities: supported_capabilities,
      runtime: "ruby-2.6",
      sandbox: "supported",
      evidence_manifest: evidence_manifest
    )
    assert_equal "BLOCKED", decision.fetch("decision")
    refute decision.fetch("mutations_permitted")
    assert_includes decision.fetch("reasons"), "capability evidence authenticity is unproven"
    assert_raises(PromptEngineer::Cutover::Error) { PromptEngineer::Cutover.apply!(decision) }
  end

  def test_cutover_requires_host_binding_and_manifest_bound_capability_digests
    mismatched_host = supported_capabilities
    mismatched_host.fetch("claude")["host"] = "codex"
    decision = PromptEngineer::Cutover.evaluate(
      qualification: "QUALIFIED_EXPLICIT",
      capabilities: mismatched_host,
      runtime: "ruby-2.6",
      sandbox: "supported",
      evidence_manifest: evidence_manifest
    )
    assert_includes decision.fetch("reasons"), "claude capability host does not match key"

    mismatched_digest = supported_capabilities
    manifest = evidence_manifest
    manifest.fetch("files").find { |file| file.fetch("path") == "codex/export-capabilities.json" }["sha256"] = "b" * 64
    decision = PromptEngineer::Cutover.evaluate(
      qualification: "QUALIFIED_EXPLICIT",
      capabilities: mismatched_digest,
      runtime: "ruby-2.6",
      sandbox: "supported",
      evidence_manifest: manifest
    )
    assert_includes decision.fetch("reasons"), "codex capability evidence is not bound to immutable manifest"
    refute decision.fetch("mutations_permitted")
  end

  private

  def supported_capabilities
    %w[codex claude].each_with_object({}) do |host, result|
      result[host] = {
        "host" => host,
        "status" => "supported",
        "normalizer" => "native",
        "reason" => "verified native evidence",
        "evidence" => {
          "root" => "/tmp/prompt-engineer-evidence",
          "artifact" => "#{host}/export-capabilities.json",
          "pointer" => "#/",
          "sha256" => "a" * 64
        }
      }
    end
  end

  def evidence_manifest
    {
      "schema" => "prompt-engineer-task0-evidence-manifest-v1",
      "root" => "/tmp/prompt-engineer-evidence",
      "captured_at" => "2026-07-19",
      "retention_deadline" => "cutover plus five-use observation window",
      "self_digest" => "excluded; this manifest is the immutable index root",
      "files" => %w[codex claude].map do |host|
        {
          "path" => "#{host}/export-capabilities.json",
          "mode" => "0444",
          "size" => 1,
          "sha256" => "a" * 64,
          "origin" => "test evidence",
          "fixture_derivation" => nil
        }
      end
    }
  end
end
