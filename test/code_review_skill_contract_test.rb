require "minitest/autorun"

class CodeReviewSkillContractTest < Minitest::Test
  REPO_UNDER_TEST = File.expand_path("..", __dir__)
  SKILL = File.join(REPO_UNDER_TEST, "skills", "codex-cursor", "code-review", "SKILL.md")

  def skill_text
    File.read(SKILL)
  end

  def test_address_mode_final_report_lists_each_applied_fix
    text = skill_text

    assert_includes text, "If any file was edited, the `Fixed` section is mandatory"
    assert_includes text, "one bullet per applied fix"
    assert_includes text, "Changed files:"
    assert_includes text, "finding or PR comment"
  end
end
