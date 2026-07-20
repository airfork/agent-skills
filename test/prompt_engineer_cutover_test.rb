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
      qualification: "PASS",
      capabilities: {"codex" => {"status" => "supported"}, "claude" => {"status" => "supported"}},
      runtime: "ruby-2.6",
      sandbox: "supported"
    )
    assert_equal "READY", decision.fetch("decision")
    assert_raises(PromptEngineer::Cutover::Error) { PromptEngineer::Cutover.apply!(decision) }
  end
end
