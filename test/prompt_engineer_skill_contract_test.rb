require "minitest/autorun"
require "open3"
require "psych"
require "tmpdir"

class PromptEngineerSkillContractTest < Minitest::Test
  REPO = File.expand_path("..", __dir__)
  SKILL_DIR = File.join(REPO, "skills", "general", "prompt-engineer")
  PACKAGE_FILES = %w[
    SKILL.md
    agents/openai.yaml
    references/evaluation.md
    references/prompt-contexts.md
  ].freeze
  DEFAULT_PROMPT = "Use $prompt-engineer to diagnose and improve this prompt with the lightest evidence-backed evaluation that can support the requested claim."

  def test_runtime_package_contract
    assert File.directory?(SKILL_DIR), "missing runtime package: #{SKILL_DIR}"

    actual_files = Dir.glob(File.join(SKILL_DIR, "**", "*"))
      .select { |path| File.file?(path) }
      .map { |path| path.delete_prefix("#{SKILL_DIR}/") }
      .sort
    assert_equal PACKAGE_FILES.sort, actual_files

    skill = File.read(File.join(SKILL_DIR, "SKILL.md"))
    frontmatter, body = skill.split("\n---\n", 2)
    assert_equal "---", frontmatter.lines.first&.strip
    metadata = Psych.safe_load(frontmatter.sub("---\n", ""), aliases: false)
    assert_equal %w[description name], metadata.keys.sort
    assert_equal "prompt-engineer", metadata.fetch("name")
    description = metadata.fetch("description").downcase
    %w[
      creating improving simplifying diagnosing comparing prompts
      prompt-bearing skills handoffs ecosystems evaluations
    ].each { |term| assert_includes description, term }
    %w[
      ordinary prose edits code runtime configuration tools data permissions
      external systems
    ].each { |term| assert_includes description, term }

    assert_operator nonblank_lines(body).length, :<=, 250
    evaluation = File.read(File.join(SKILL_DIR, "references", "evaluation.md"))
    contexts = File.read(File.join(SKILL_DIR, "references", "prompt-contexts.md"))
    assert_operator nonblank_lines(evaluation).length, :<=, 300
    assert_operator nonblank_lines(contexts).length, :<=, 300
    %w[evaluation prompt-contexts].each do |reference|
      assert_includes body, "references/#{reference}.md"
    end

    package_text = [skill, evaluation, contexts].join("\n").downcase
    refute_match(/(?:always|must|required to)\s+(?:list|name|enumerate|catalog)\b.{0,100}\b(?:technique|framework|method)/, package_text)
    refute_match(/(?:never|must not|do not)\s+(?:delete|remove|reorder|restructure)\b.{0,100}\b(?:section|structure|instruction)/, package_text)
    refute_match(/\b\d+(?:\.\d+)?\s*%|\b\d+(?:\.\d+)?\s*percent(?:age)?\b/, package_text)
    refute_match(/(?:must|always)\s+(?:use|invoke|follow)\b.{0,100}\b(?:external|browser|provider|workflow|service)/, package_text)
    assert_includes package_text, "inconclusive"
    assert_includes package_text, "non-prompt"

    openai_path = File.join(SKILL_DIR, "agents", "openai.yaml")
    openai = File.read(openai_path)
    metadata = Psych.safe_load(openai, aliases: false)
    assert_equal false, metadata.dig("policy", "allow_implicit_invocation")
    assert_equal DEFAULT_PROMPT, metadata.dig("interface", "default_prompt")
    %w[display_name short_description default_prompt].each do |key|
      assert_match(/^\s+#{key}:\s+"(?:[^"\\]|\\.)*"\s*$/, openai)
    end
    assert_match(/^policy:\n\s+allow_implicit_invocation:\s+false\s*$/m, openai)
    assert_match(/\$prompt-engineer/, openai)
  end

  def test_description_excludes_capability_architecture_and_model_availability_failures
    description = skill_text_description

    %w[capability architecture].each do |layer|
      assert_includes description, layer
    end
    assert_includes description, "model availability"
  end

  def test_description_excludes_non_prompt_trigger_requests
    description = skill_text_description

    [
      "implementation handoff requests without prompt-design intent",
      "repositories merely containing prompts",
      "prompt-engineering concept explanations",
      "one-off answers"
    ].each { |exclusion| assert_includes description, exclusion }
  end

  def test_each_profile_requires_comparable_evidence_and_zero_tolerance_checks
    evaluation = File.read(File.join(SKILL_DIR, "references", "evaluation.md")).downcase

    profile_requirements = {
      "quick" => ["comparable evidence", "representative input", "zero-tolerance", "allowed only when"],
      "standard" => ["baseline and candidate", "fresh, equivalent", "zero-tolerance", "allowed only when"],
      "ecosystem" => ["baseline and candidate", "end-to-end", "producer-consumer", "zero-tolerance", "allowed only when"]
    }

    profile_requirements.each do |profile, requirements|
      section = evaluation.split("## #{profile}", 2).fetch(1).split(/^## /, 2).first
      requirements.each do |requirement|
        assert_includes section, requirement, "#{profile} profile missing #{requirement}"
      end
    end
    assert_includes evaluation, "missing required evidence"
    assert_includes evaluation, "inconclusive"
  end

  def test_standard_can_support_candidate_improvement_when_baseline_fails
    evaluation = File.read(File.join(SKILL_DIR, "references", "evaluation.md")).downcase
    standard = evaluation.split("## standard", 2).fetch(1).split(/^## /, 2).first

    assert_includes standard, "evaluate the same criteria for baseline and candidate"
    assert_match(/baseline failure is\s+comparison evidence/, standard)
    assert_includes standard, "candidate meets the success criteria"
    assert_includes standard, "supported"
    assert_includes standard, "zero-tolerance"
  end

  def test_contexts_route_instruction_layers_tool_schema_and_embedded_components
    contexts = File.read(File.join(SKILL_DIR, "references", "prompt-contexts.md")).downcase

    %w[system developer user].each { |layer| assert_includes contexts, layer }
    assert_includes contexts, "tool-schema"
    assert_includes contexts, "embedded-component"
    assert_match(/route.{0,120}(owner|responsible layer)/, contexts)
  end

  def test_candidate_manifest_contract
    manifest = Psych.safe_load(File.read(File.join(REPO, "skills.yaml")), aliases: false)
    candidate = manifest.fetch("skills").find { |skill| skill.fetch("name") == "prompt-engineer" }

    refute_nil candidate, "missing prompt-engineer candidate manifest entry"
    assert_equal "skills/general/prompt-engineer", candidate.fetch("path")
    assert_equal "general", candidate.fetch("category")
    assert_equal "candidate", candidate.fetch("status")
    assert_equal %w[codex claude], candidate.fetch("interfaces")
    assert_equal "standard", candidate.fetch("recommended_model_tier")
    assert_equal "deep", candidate.fetch("heavy_model_tier")

    install = candidate.fetch("install")
    %w[codex claude cursor gemini].each do |target|
      assert_equal false, install.fetch(target).fetch("enabled"), "#{target} install must be disabled"
    end
  end

  def test_candidate_catalog_and_usage_agree_with_manifest
    catalog = File.read(File.join(REPO, "CATALOG.md"))
    usage = File.read(File.join(REPO, "USAGE.md"))

    [catalog, usage].each do |document|
      assert_includes document, "`prompt-engineer`"
      assert_includes document, "Candidate"
      assert_includes document, "general"
      assert_includes document, "standard"
      assert_includes document, "deep"
      assert_match(/Codex and Claude[^\n]*disabled/i, document)
    end
  end

  def test_candidate_operator_surface_is_explicit_and_fail_closed
    usage = File.read(File.join(REPO, "USAGE.md"))
    commands = File.read(File.join(REPO, "COMMANDS.md"))

    [
      "$prompt-engineer",
      "Quick",
      "Standard",
      "Ecosystem",
      "scripts/prompt-engineer-eval",
      "scripts/prompt-engineer-sandbox",
      "scripts/prompt-engineer-cutover",
      "PROMPT_ENGINEER_MAX_USD",
      "eight hours",
      "separate explicit cutover approval",
      "activation commit",
      "scripts/prompt-engineer-cutover rollback",
      "post-cutover use record",
      "five qualifying uses on each host",
      "later explicit cleanup request"
    ].each { |term| assert_includes usage, term }
    assert_match(/clean\s+stable\s+checkout/, usage)

    %w[
      scripts/prompt-engineer-eval
      scripts/prompt-engineer-sandbox
      scripts/prompt-engineer-cutover
    ].each do |cli|
      assert_match(/#{Regexp.escape(cli)}[^\n]*available/i, commands)
    end
    refute_match(/\brtk\b/, commands)
  end

  def test_ordinary_sync_dry_runs_never_select_candidate
    Dir.mktmpdir("prompt-engineer-sync-contract") do |destination|
      %w[codex claude].each do |target|
        stdout, stderr, status = Open3.capture3(
          "ruby",
          File.join(REPO, "scripts", "sync-skills"),
          "--repo-root", REPO,
          "--dest", File.join(destination, target),
          "--target", target,
          "--dry-run"
        )
        assert status.success?, stderr
        refute_match(/(?:link|update|remove|prune)\s+prompt-engineer(?:[:\s]|$)/i, stdout)
      end
    end
  end

  private

  def skill_text_description
    skill = File.read(File.join(SKILL_DIR, "SKILL.md"))
    frontmatter = skill.split("\n---\n", 2).first.sub("---\n", "")
    Psych.safe_load(frontmatter, aliases: false).fetch("description").downcase
  end

  def nonblank_lines(text)
    text.lines.reject { |line| line.strip.empty? }
  end
end
