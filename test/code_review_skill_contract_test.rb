require "minitest/autorun"

class CodeReviewSkillContractTest < Minitest::Test
  REPO_UNDER_TEST = File.expand_path("..", __dir__)
  SKILL = File.join(REPO_UNDER_TEST, "skills", "codex-cursor", "code-review", "SKILL.md")

  def skill_text
    File.read(SKILL)
  end

  ADAPTERS = File.join(REPO_UNDER_TEST, "skills", "codex-cursor", "code-review", "platform-adapters.md")

  # The single POSIX snippet the workflow still carries is labeled a convenience
  # implementation of the numbered rule above it, and is executed by
  # ModelTierContractTest#test_base_branch_fallback_executes_without_origin_head.
  POSIX_REFERENCE_BLOCK = /# BEGIN BASE_BRANCH_RESOLUTION.*?HEAD_SHA=\$\(git rev-parse HEAD\)\n\s*```/m

  # Constructs with no native equivalent on a Windows host shell. Checked against
  # executable blocks only: prose is allowed to name what it forbids.
  POSIX_ONLY = {
    "mktemp" => /\bmktemp\b/,
    "/tmp path" => %r{/tmp\b},
    "output redirection" => />>?\s+"?\$/,
    "sort -u" => /\bsort -u\b/,
    "file --mime-type" => /\bfile -b\b/,
    "read loop" => /\bIFS=\s*read\b/,
    "stderr suppression" => %r{2>/dev/null},
  }.freeze

  def fenced_blocks(text)
    text.scan(/^\s*```[a-z]*\n(.*?)^\s*```/m).flatten
  end

  def test_address_mode_final_report_lists_each_applied_fix
    text = skill_text

    assert_includes text, "If any file was edited, the `Fixed` section is mandatory"
    assert_includes text, "one bullet per applied fix"
    assert_includes text, "Changed files:"
    assert_includes text, "finding or PR comment"
  end

  def test_workflow_carries_no_posix_only_shell_outside_the_labeled_reference
    blocks = fenced_blocks(skill_text)
    refute_empty blocks
    portable = blocks.reject { |block| block.include?("BASE_BRANCH_RESOLUTION") }
    assert_equal blocks.length - 1, portable.length, "expected exactly one labeled POSIX reference block"

    portable.each do |block|
      POSIX_ONLY.each do |label, pattern|
        refute_match pattern, block, "#{label} is not portable to a Windows host shell"
      end
    end
  end

  def test_review_packet_is_host_neutral
    text = skill_text

    assert_includes text, "Use the host's own temporary-directory and file-writing tools"
    assert_includes text, "do not assume a POSIX shell, `mktemp`, output redirection, or `/tmp`"
    assert_includes text, "The commands are identical on every platform; only the capture mechanism differs."
    assert_includes text, "Create every in-scope packet file even when a command produces no output"
    assert_includes text, "treat it as binary if the first 8000 bytes contain a NUL byte"
  end

  def test_base_branch_snippet_is_marked_non_normative
    text = skill_text

    assert_includes text, "This is a decision rule, not a script"
    assert_includes text, "It is a convenience implementation, not the normative form"
    assert_match POSIX_REFERENCE_BLOCK, text
  end

  def test_adapters_document_the_windows_contract
    adapters = File.read(ADAPTERS)

    assert_includes adapters, "## Windows"
    assert_includes adapters, "no Windows-specific copy of this skill exists"
    assert_includes adapters, "needs Developer Mode or an\nelevated shell on Windows"
  end
end
