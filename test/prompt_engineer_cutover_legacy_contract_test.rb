require "minitest/autorun"
require_relative "../scripts/lib/prompt_engineer/cutover"

class PromptEngineerCutoverLegacyContractTest < Minitest::Test

  # PromptEngineer::Corpus requires descriptor-relative, no-follow reads and
  # raises without them. That is a hard requirement of the skill, not of these
  # tests, so on a host that lacks them there is nothing to assert.
  def setup
    return unless defined?(PromptEngineer::Corpus)

    unless PromptEngineer::Corpus::NOFOLLOW_FLAG && PromptEngineer::Corpus::OPENAT_FUNCTION
      skip "host lacks descriptor-relative no-follow reads"
    end
  end

  def test_legacy_shape_blocks_unsupported_evidence_without_mutation
    result = PromptEngineer::Cutover.evaluate(
      qualification_result: {"status" => "PASS", "decision" => "QUALIFIED_EXPLICIT", "report_digest" => "report"},
      capability_record: {"status" => "PARTIAL", "ruby_2_6" => "UNAVAILABLE", "libc" => "UNAVAILABLE", "native_qualification" => "BLOCKED", "sandbox" => "UNSUPPORTED"}
    )
    assert_equal "BLOCKED", result.fetch("status")
    assert_equal false, result.fetch("mutations_allowed")
    assert_equal false, result.fetch("live_actions").fetch("replace")
  end

  def test_legacy_shape_is_inconclusive_when_evidence_is_missing
    result = PromptEngineer::Cutover.evaluate(qualification_result: {"status" => "PASS"}, capability_record: {"status" => "PASS"})
    assert_equal "INCONCLUSIVE", result.fetch("status")
    assert_includes result.fetch("reason_codes"), "qualification_report_digest_missing"
    assert_includes result.fetch("reason_codes"), "ruby_2_6_evidence_missing"
  end

  def test_legacy_ready_shape_still_grants_no_mutation_authority
    result = PromptEngineer::Cutover.evaluate(
      qualification_result: {"status" => "PASS", "decision" => "QUALIFIED_EXPLICIT", "report_digest" => "report"},
      capability_record: {"status" => "PASS", "ruby_2_6" => "PASS", "libc" => "PASS", "native_qualification" => "PASS", "sandbox" => "PASS"}
    )
    assert_equal "READY", result.fetch("status")
    assert_equal false, result.fetch("mutations_allowed")
    assert result.fetch("live_actions").values.all? { |value| value == false }
  end
end
