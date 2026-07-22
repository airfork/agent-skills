require "minitest/autorun"

$LOAD_PATH.unshift(File.expand_path("../scripts/lib", __dir__))
require "prompt_engineer/cutover"

class PromptEngineerCutoverTest < Minitest::Test
  def test_blocks_partial_and_unsupported_capability_evidence
    result = PromptEngineer::Cutover.evaluate(
      qualification_result: {
        "status" => "PASS",
        "decision" => "QUALIFIED_EXPLICIT",
        "report_digest" => "report-digest"
      },
      capability_record: {
        "status" => "PARTIAL",
        "ruby_2_6" => "UNAVAILABLE",
        "libc" => "UNAVAILABLE",
        "native_qualification" => "BLOCKED",
        "sandbox" => "UNSUPPORTED"
      }
    )

    assert_equal "BLOCKED", result.fetch("status")
    assert_equal [
      "capability_partial",
      "ruby_2_6_unavailable",
      "libc_unavailable",
      "native_qualification_not_pass",
      "sandbox_unsupported"
    ], result.fetch("reason_codes")
    assert_equal false, result.fetch("mutations_allowed")
    assert_equal false, result.fetch("live_actions").fetch("replace")
    assert_equal false, result.fetch("live_actions").fetch("install")
    assert_equal false, result.fetch("live_actions").fetch("symlink")
    assert_equal false, result.fetch("live_actions").fetch("delete")
  end

  def test_returns_inconclusive_when_required_evidence_is_absent
    result = PromptEngineer::Cutover.evaluate(
      qualification_result: {"status" => "PASS"},
      capability_record: {"status" => "PASS"}
    )

    assert_equal "INCONCLUSIVE", result.fetch("status")
    assert_includes result.fetch("reason_codes"), "qualification_report_digest_missing"
    assert_includes result.fetch("reason_codes"), "ruby_2_6_evidence_missing"
    assert_includes result.fetch("reason_codes"), "libc_evidence_missing"
    assert_equal false, result.fetch("mutations_allowed")
  end

  def test_complete_evidence_still_grants_no_live_mutation_authority
    result = PromptEngineer::Cutover.evaluate(
      qualification_result: {
        "status" => "PASS",
        "decision" => "QUALIFIED_EXPLICIT",
        "report_digest" => "report-digest"
      },
      capability_record: {
        "status" => "PASS",
        "ruby_2_6" => "PASS",
        "libc" => "PASS",
        "native_qualification" => "PASS",
        "sandbox" => "PASS"
      }
    )

    assert_equal "READY", result.fetch("status")
    assert_equal [], result.fetch("reason_codes")
    assert_equal false, result.fetch("mutations_allowed")
    assert result.fetch("live_actions").values.all? { |allowed| allowed == false }
  end
end
