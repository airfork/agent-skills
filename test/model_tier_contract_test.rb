require "minitest/autorun"
require "yaml"

class ModelTierContractTest < Minitest::Test
  REPO_UNDER_TEST = File.expand_path("..", __dir__)
  EXPECTED_CODEX_MODELS = {
    "fast" => "GPT-5.6 Luna",
    "standard" => "GPT-5.6 Terra",
    "deep" => "GPT-5.6 Sol",
  }.freeze
  EXPECTED_HUMAN_ROWS = {
    "README.md" => {
      "fast" => "| `fast` | GPT-5.6 Luna | Sonnet medium | Gemini low-effort/default | Small edits, simple transforms, quick checks. |",
      "standard" => "| `standard` | GPT-5.6 Terra | Sonnet high | Gemini default | Normal skill execution and repo-aware work. |",
      "deep" => "| `deep` | GPT-5.6 Sol | Opus 4.8 high | Gemini highest available reasoning model | Broad reviews, ambiguous planning, architecture, high-risk work. |",
    },
    "CATALOG.md" => {
      "fast" => "| `fast` | GPT-5.6 Luna, Claude Sonnet medium, or Gemini low-effort/default. |",
      "standard" => "| `standard` | GPT-5.6 Terra, Claude Sonnet high, or Gemini default. |",
      "deep" => "| `deep` | GPT-5.6 Sol, Claude Opus 4.8 high, or Gemini's highest available reasoning model. |",
    },
  }.freeze
  ACTIVE_METADATA = %w[README.md CATALOG.md skills.yaml].freeze

  def read(path)
    File.read(File.join(REPO_UNDER_TEST, path))
  end

  def test_manifest_uses_the_approved_codex_model_family
    manifest = YAML.load_file(File.join(REPO_UNDER_TEST, "skills.yaml"))
    actual = manifest.fetch("model_tiers").slice(*EXPECTED_CODEX_MODELS.keys)
      .transform_values { |tier| tier.fetch("codex") }

    assert_equal EXPECTED_CODEX_MODELS, actual
  end

  def test_human_guidance_matches_the_manifest_mapping
    EXPECTED_HUMAN_ROWS.each do |path, rows|
      text = read(path)

      rows.each do |tier, row|
        matches = text.lines.grep(/\A\| `#{Regexp.escape(tier)}` \|/).map(&:chomp)
        assert_equal [row], matches, "#{path} #{tier} row"
      end
    end
  end

  def active_codex_skill_files
    manifest = YAML.load_file(File.join(REPO_UNDER_TEST, "skills.yaml"))
    manifest.fetch("skills")
      .select { |skill| skill.dig("install", "codex", "enabled") }
      .flat_map do |skill|
        Dir.glob(File.join(REPO_UNDER_TEST, skill.fetch("path"), "**", "*"))
          .select { |path| File.file?(path) }
      end
  end

  def test_active_guidance_does_not_reference_retired_codex_models
    paths = ACTIVE_METADATA.map { |path| File.join(REPO_UNDER_TEST, path) }

    (paths + active_codex_skill_files).each do |path|
      refute_match(/GPT-5\.[45]/i, File.read(path), path)
    end
  end

  def test_quality_roles_accept_each_inherited_5_6_model
    code_skill = read("skills/codex-cursor/code-review/SKILL.md")
    code_readme = read("skills/codex-cursor/code-review/README.md")
    code_adapter = read("skills/codex-cursor/code-review/platform-adapters.md")
    adversarial_skill = read("skills/general/adversarial-review/SKILL.md")
    adversarial_adapter = read("skills/general/adversarial-review/platform-adapters.md")

    refute_includes code_skill, 'never a downgraded or "fast" model'
    refute_includes code_readme, "Verifiers are never downgraded to a faster model at any tier"
    refute_includes code_adapter, 'Never substitute a downgraded or "fast" model for verifiers at any tier'
    refute_includes adversarial_skill, "Judges and arbiters must never be downgraded to a fast or cheap model."
    refute_includes adversarial_adapter, "Never substitute a downgraded or fast model for judges or arbiters."

    codex_policy = "On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier"
    assert_includes code_skill, codex_policy
    assert_includes code_readme, codex_policy
    assert_includes code_adapter, codex_policy
    assert_includes adversarial_skill, codex_policy
    assert_includes adversarial_adapter, codex_policy

    fallback_policy = "use the host's maximum available effort and disclose that the requested tier was not fully enforceable"
    assert_includes code_skill, fallback_policy
    assert_includes code_adapter, fallback_policy
    refute_includes code_skill, "continue with inherited settings and disclose that limitation"
    refute_includes code_adapter, "continue with inherited settings and disclose that in the final report"

    catalog = read("CATALOG.md")
    assert_includes catalog, "| Skill | Path | Category | Status | Install | Recommended model tier | Description |"
    assert_match(/^\| `code-review` .* \| `deep` model tier; use the `standard` model tier only for lower-cost routine reviews \|/, catalog)
  end

  def test_model_review_reports_record_execution_provenance
    {
      "luna" => "gpt-5.6-luna",
      "terra" => "gpt-5.6-terra",
      "sol" => "gpt-5.6-sol",
    }.each do |name, slug|
      path = "docs/plans/2026-07-12-codex-5.6-#{name}-skill-review.md"
      assert File.file?(File.join(REPO_UNDER_TEST, path)), path
      text = read(path)
      assert_includes text, "- Model slug: `#{slug}`"
      assert_includes text, "- Codex CLI: `codex-cli 0.144.1`"
      assert_includes text, "- Reasoning effort: `high`"
      assert_includes text, "- Exit status: `0`"
      assert_match(/- Worktree: `\/Users\/tunji\/skills\/\.worktrees\/codex-5\.6-skill-compatibility`/, text)
      assert_match(/- Reviewed commit: `[0-9a-f]{7,40}`/, text)
      assert_match(/- Session ID: `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`/, text)
      assert_includes text, "- Runtime model: `#{slug}`"
      assert_includes text, "model: #{slug}"
      assert_includes text, "workdir: /Users/tunji/skills/.worktrees/codex-5.6-skill-compatibility"
      assert_includes text, "reasoning effort: high"
      assert_includes text, "- Invocation: `ruby scripts/run-codex-5.6-skill-review #{name}`"
      assert_includes text, "## Model verdict"
    end
  end

  def test_model_review_runner_supports_the_system_ruby
    return if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.7")

    refute_includes read("scripts/run-codex-5.6-skill-review"), ".filter_map"
  end

  def test_codex_fallback_and_report_only_modes_are_executable
    code_skill = read("skills/codex-cursor/code-review/SKILL.md")
    code_adapter = read("skills/codex-cursor/code-review/platform-adapters.md")
    adversarial_skill = read("skills/general/adversarial-review/SKILL.md")

    fallback_sentences = [
      "If the named agent definitions are unavailable, spawn generic subtasks with the read-only wrapper below instead of requiring installation.",
      "If the host cannot prove a read-only sandbox, enforce the wrapper's behavioral read-only rules and disclose that sandbox enforcement was unavailable.",
    ]
    fallback_sentences.each do |sentence|
      assert_includes code_skill, sentence
      assert_includes code_adapter, sentence
    end
    assert_includes adversarial_skill, "For `--report-only`, replace the convergence verdict with `REPORT ONLY - N findings` and emit only Findings and Metrics"
    assert_includes adversarial_skill, "use `ID | Category | Severity | Location | Summary` with no Resolution column"
    assert_includes adversarial_skill, "do not emit Changelog, Rejected Findings, or Open Questions because no revision or resolution occurred"
  end

  def test_limited_capacity_and_terminal_verdicts_are_deterministic
    code_skill = read("skills/codex-cursor/code-review/SKILL.md")
    code_adapter = read("skills/codex-cursor/code-review/platform-adapters.md")
    adversarial_skill = read("skills/general/adversarial-review/SKILL.md")

    bounded_waves = "Run parallel finder and verifier dispatch in bounded waves that respect the host's current concurrency limit; do not assume the full roster can start at once."
    assert_includes code_skill, bounded_waves
    assert_includes code_adapter, bounded_waves
    assert_includes adversarial_skill, "Any stuck promoted finding at the round cap yields `DID NOT CONVERGE`, regardless of severity."
    assert_includes adversarial_skill, "`PASSED WITH OPEN QUESTIONS` is reserved for non-blocking questions that are not tied to a promoted finding."
    refute_includes adversarial_skill, "Stuck `CRITICAL` or `HIGH` findings mean the review did not pass."
  end

  def test_named_agent_install_and_github_fallback_are_explicit
    code_skill = read("skills/codex-cursor/code-review/SKILL.md")
    code_readme = read("skills/codex-cursor/code-review/README.md")
    code_adapter = read("skills/codex-cursor/code-review/platform-adapters.md")

    install_policy = "Named-agent installation is optional setup, never part of review execution; do not copy TOMLs into `~/.codex/agents/` unless the user explicitly asks."
    assert_includes code_skill, install_policy
    assert_includes code_readme, install_policy
    assert_includes code_adapter, install_policy
    refute_includes code_readme, "install them into `~/.codex/agents/`"
    refute_includes code_adapter, "Install the named agent definitions from"

    github_fallback = "If `gh` is unavailable or unauthenticated for a PR target or requested GitHub action, stop before review or mutation and report: `GitHub CLI authentication is required for this PR workflow.`"
    assert_includes code_skill, github_fallback
    assert_includes code_adapter, github_fallback
  end

  def test_generic_fallback_preserves_the_selected_parent_model
    code_skill = read("skills/codex-cursor/code-review/SKILL.md")
    code_adapter = read("skills/codex-cursor/code-review/platform-adapters.md")
    core_policy = "When using generic fallback subtasks, explicitly preserve the parent session's selected model; if the host cannot prove model inheritance, run the role sequentially in the parent and disclose the limitation."
    codex_policy = "For Codex generic fallback subtasks, explicitly preserve the parent session's selected GPT-5.6 model; if Codex cannot prove model inheritance, run the role sequentially in the parent and disclose the limitation."

    assert_includes code_skill, core_policy
    assert_includes code_adapter, codex_policy
    assert_includes code_adapter, "codex --model <selected-gpt-5.6-slug> -c model_reasoning_effort=high"
    assert_includes code_adapter, "codex --model <selected-gpt-5.6-slug> --profile review"
    refute_includes code_adapter, "e.g. `codex -c model_reasoning_effort=high`"
  end
end
