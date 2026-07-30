require "minitest/autorun"

class MilestoneOrchestratorSkillContractTest < Minitest::Test
  REPO = File.expand_path("..", __dir__)
  SKILL_DIR = File.join(REPO, "skills", "general", "milestone-orchestrator")

  PACKAGE_FILES = %w[
    SKILL.md
    agents/openai.yaml
    references/intake.md
    references/task-contracts.md
    references/state-schema.md
    references/platform-adapters.md
    references/validation.md
    assets/spec-template.md
    assets/plan-template.md
    assets/state-template.md
    scripts/validate-state
    scripts/control-state
    scripts/run-verification
    scripts/preflight-lint
    scripts/lib/state_document.rb
    scripts/lib/lease_store.rb
  ].freeze

  def skill_text
    File.read(File.join(SKILL_DIR, "SKILL.md"))
  end

  def test_package_layout_complete
    PACKAGE_FILES.each do |relative|
      assert File.file?(File.join(SKILL_DIR, relative)), "missing #{relative}"
    end
  end

  def test_validate_state_is_executable
    assert File.executable?(File.join(SKILL_DIR, "scripts", "validate-state"))
    assert File.executable?(File.join(SKILL_DIR, "scripts", "control-state"))
  end

  def test_frontmatter_name_and_trigger
    text = skill_text
    assert_match(/\Aname: milestone-orchestrator$/, text.lines[1].strip + "")
    assert_includes text, "description: >-"
  end

  def test_mandatory_policy_text_present
    text = skill_text
    assert_includes text, "Manager-only coordinator"
    assert_includes text, "Merge and\n  deploy are always disabled"
    assert_includes text, "Lifecycle is not correctness"
    assert_includes text, "Codex workers use this\n  repository's `code-review` skill"
    assert_includes text, "Claude workers use Claude's own\n  `/code-review`"
    assert_includes text, "no AI attribution"
  end

  def test_templates_carry_canonical_markers
    plan_template = File.read(File.join(SKILL_DIR, "assets", "plan-template.md"))
    state_template = File.read(File.join(SKILL_DIR, "assets", "state-template.md"))
    assert_includes plan_template, "<!-- milestone-orchestrator-plan:v1 -->"
    assert_includes plan_template, "<!-- /milestone-orchestrator-plan -->"
    assert_includes state_template, "<!-- milestone-orchestrator-state:v1 -->"
    assert_includes state_template, "<!-- /milestone-orchestrator-state -->"
  end

  def test_registered_in_catalog_and_manifest
    catalog = File.read(File.join(REPO, "CATALOG.md"))
    manifest = File.read(File.join(REPO, "skills.yaml"))
    usage = File.read(File.join(REPO, "USAGE.md"))
    assert_includes catalog, "`milestone-orchestrator`"
    assert_includes catalog, "skills/general/milestone-orchestrator/"
    assert_includes manifest, "name: milestone-orchestrator"
    assert_includes manifest, "path: skills/general/milestone-orchestrator"
    assert_includes usage, "`milestone-orchestrator`"
  end
end
