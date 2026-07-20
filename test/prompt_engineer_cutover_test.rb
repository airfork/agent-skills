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
      sandbox: "supported"
    )
    assert_equal "READY", decision.fetch("decision")
    assert_raises(PromptEngineer::Cutover::Error) { PromptEngineer::Cutover.apply!(decision) }
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
end
