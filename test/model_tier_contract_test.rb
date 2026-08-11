require "minitest/autorun"
require "open3"
require "tmpdir"
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
      "fast" => "| `fast` | GPT-5.6 Luna | Sonnet medium | Gemini low-effort/default | Copilot default fast model | Small edits, simple transforms, quick checks. |",
      "standard" => "| `standard` | GPT-5.6 Terra | Sonnet high | Gemini default | Copilot default model | Normal skill execution and repo-aware work. |",
      "deep" => "| `deep` | GPT-5.6 Sol | Opus 5 high | Gemini highest available reasoning model | Copilot highest available reasoning model | Broad reviews, ambiguous planning, architecture, high-risk work. |",
    },
    "CATALOG.md" => {
      "fast" => "| `fast` | GPT-5.6 Luna, Claude Sonnet medium, Gemini low-effort/default, or Copilot's default fast model. |",
      "standard" => "| `standard` | GPT-5.6 Terra, Claude Sonnet high, Gemini default, or Copilot's default model. |",
      "deep" => "| `deep` | GPT-5.6 Sol, Claude Opus 5 high, Gemini's highest available reasoning model, or Copilot's highest available reasoning model. |",
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

    refute_includes code_skill, 'never a downgraded or "fast" model'
    refute_includes code_readme, "Verifiers are never downgraded to a faster model at any tier"
    refute_includes code_adapter, 'Never substitute a downgraded or "fast" model for verifiers at any tier'

    codex_policy = "On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier"
    assert_includes code_skill, codex_policy
    assert_includes code_readme, codex_policy
    assert_includes code_adapter, codex_policy

    fallback_policy = "use the host's maximum available effort and disclose that the requested tier was not fully enforceable"
    assert_includes code_skill, fallback_policy
    assert_includes code_adapter, fallback_policy
    refute_includes code_skill, "continue with inherited settings and disclose that limitation"
    refute_includes code_adapter, "continue with inherited settings and disclose that in the final report"

    catalog = read("CATALOG.md")
    assert_includes catalog, "| Skill | Path | Category | Status | Install | Recommended model tier | Description |"
    assert_match(/^\| `code-review` .* \| GPT-5\.6 Sol \(`deep` repository model tier\) recommended; GPT-5\.6 Luna and Terra remain supported at every review intensity when selected in the parent \|/, catalog)
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
      assert_includes text, "## Parent disposition"
      assert_includes text, "- Unresolved concrete blockers: 0"
    end
  end

  def test_model_review_runner_supports_the_system_ruby
    runner = read("scripts/run-codex-5.6-skill-review")
    assert_includes runner, '"status", "--porcelain", "--", *packet_scope'
    assert_includes runner, "Review packet scope is dirty; report was not replaced"
    assert_operator runner.index("packet_status_output"), :<, runner.index("packet = packet_paths.uniq.map")

    return if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.7")

    refute_includes runner, ".filter_map"
  end

  def test_codex_fallback_and_report_only_modes_are_executable
    code_skill = read("skills/codex-cursor/code-review/SKILL.md")
    code_adapter = read("skills/codex-cursor/code-review/platform-adapters.md")

    fallback_sentences = [
      "If the named agent definitions are unavailable, spawn generic subtasks with the read-only wrapper below instead of requiring installation.",
      "If the host cannot prove a read-only sandbox, enforce the wrapper's behavioral read-only rules and disclose that sandbox enforcement was unavailable.",
    ]
    fallback_sentences.each do |sentence|
      assert_includes code_skill, sentence
      assert_includes code_adapter, sentence
    end
  end

  def test_limited_capacity_and_terminal_verdicts_are_deterministic
    code_skill = read("skills/codex-cursor/code-review/SKILL.md")
    code_adapter = read("skills/codex-cursor/code-review/platform-adapters.md")

    bounded_waves = "Run parallel finder and verifier dispatch in bounded waves that respect the host's current concurrency limit; do not assume the full roster can start at once."
    assert_includes code_skill, bounded_waves
    assert_includes code_adapter, bounded_waves
  end

  def test_named_agent_install_and_github_fallback_are_explicit
    code_skill = read("skills/codex-cursor/code-review/SKILL.md")
    code_readme = read("skills/codex-cursor/code-review/README.md")
    code_adapter = read("skills/codex-cursor/code-review/platform-adapters.md")

    install_policy = "Named-agent installation is optional setup, never part of review execution; do not copy TOMLs into `~/.codex/agents/` or `.agent.md` files into `~/.copilot/agents/` unless the user explicitly asks."
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
    assert_includes code_adapter, 'codex exec --sandbox read-only --model <selected-gpt-5.6-slug> -c model_reasoning_effort="<host-maximum-effort>" -'
    assert_includes code_adapter, "For Codex fallback role processes, require a proven read-only sandbox; if Codex cannot confirm it, stop the role rather than relying only on behavioral instructions."
    assert_includes code_adapter, "codex --model <selected-gpt-5.6-slug> --profile review"
    refute_includes code_adapter, "e.g. `codex -c model_reasoning_effort=high`"
  end

  def test_review_intensity_parser_separates_model_tiers
    skill = read("skills/codex-cursor/code-review/SKILL.md")
    readme = read("skills/codex-cursor/code-review/README.md")
    section = skill[/## Tier Parsing And Help\n(?<body>.*?)(?=\nFor a tierless explicit)/m, :body]
    refute_nil section
    aliases = section.scan(/^\| `([^`]+)` \| `([^`]+)` \|$/)
      .flat_map { |names, tier| names.split(", ").map { |name| [name, tier] } }
      .to_h

    refute aliases.key?("fast")
    refute aliases.key?("xhigh")
    refute aliases.key?("max")
    assert_includes skill, "| `standard` model tier with `deep` review intensity | GPT-5.6 Terra expected in the parent; do not switch models | `deep` review intensity |"
    assert_includes skill, "| `quick` and `deep` review intensity | unchanged | stop and ask which review intensity to use |"
    assert_includes skill, "Model-tier phrases describe the user's parent-model choice; they never change the active Codex model or select review intensity."
    assert_includes skill, "If a model-tier phrase conflicts with the active parent model, disclose the mismatch and stop so the user can restart with the requested model."
    assert_includes skill, "For a tierless explicit `$code-review` invocation or command-style request, print the help text and stop."
    assert_includes skill, "For a tierless ordinary natural-language review request, ask the user conversationally to choose an intensity."
    assert_includes readme, "For a tierless explicit `$code-review` invocation or command-style request, print the help text and stop."
    assert_includes readme, "For a tierless ordinary natural-language review request, ask the user conversationally to choose an intensity."
  end

  def test_quick_parent_effort_remains_low_cost
    skill = read("skills/codex-cursor/code-review/SKILL.md")
    adapter = read("skills/codex-cursor/code-review/platform-adapters.md")

    assert_includes skill, "For `quick`, prep stays inline with the parent; do not spawn a prep subagent."
    assert_includes adapter, "For `quick`, keep the current parent reasoning effort; quick is the low-cost inline tier."
    assert_includes adapter, "For `standard`, `high`, and `deep`, run the parent session at high reasoning effort"
    refute_includes adapter, "Run review sessions at high parent reasoning effort too."
  end

  def test_base_branch_fallback_executes_without_origin_head
    skill = read("skills/codex-cursor/code-review/SKILL.md")
    script = skill[/# BEGIN BASE_BRANCH_RESOLUTION\n(?<body>.*?)# END BASE_BRANCH_RESOLUTION/m, :body]
    refute_nil script

    Dir.mktmpdir("model-tier-base") do |dir|
      _out, err, status = Open3.capture3("git", "init", "-q", chdir: dir)
      assert status.success?, err

      out, err, status = Open3.capture3("sh", "-c", "#{script}\nprintf '%s\\n' \"$BASE_BRANCH\"", chdir: dir)
      assert status.success?, err
      assert_equal "main", out.strip

      _out, err, status = Open3.capture3(
        "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk", chdir: dir
      )
      assert status.success?, err
      out, err, status = Open3.capture3("sh", "-c", "#{script}\nprintf '%s\\n' \"$BASE_BRANCH\"", chdir: dir)
      assert status.success?, err
      assert_equal "trunk", out.strip
    end
  end

  def test_codex_model_inheritance_is_structurally_guarded
    agent_paths = Dir.glob(File.join(REPO_UNDER_TEST, "skills", "*", "*", "agents", "codex", "*.toml"))
    refute_empty agent_paths
    agent_paths.each do |path|
      refute_match(/^model\s*=/, File.read(path), path)
    end

    paths = ACTIVE_METADATA.map { |path| File.join(REPO_UNDER_TEST, path) } + active_codex_skill_files
    versions = paths.flat_map { |path| File.read(path).scan(/\bGPT-\d+(?:\.\d+)?\b/i) }
      .map(&:upcase).uniq.sort
    assert_equal ["GPT-5.6"], versions

    runner = read("scripts/run-codex-5.6-skill-review")
    assert_match(/"--model", slug/, runner)
    assert_includes runner, "stdin.write(review_prompt)"
    assert_includes runner, "stdin.close"
    assert_operator runner.index("mismatches = expected.reject"), :<, runner.index("File.write(report_path, report)")
  end

  def test_catalog_disambiguates_model_tier_from_review_intensity
    catalog = read("CATALOG.md")
    assert_match(/^\| `code-review` .* \| GPT-5\.6 Sol \(`deep` repository model tier\) recommended; GPT-5\.6 Luna and Terra remain supported at every review intensity when selected in the parent \|/, catalog)
  end
end
