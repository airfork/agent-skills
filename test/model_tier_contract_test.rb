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
    adversarial_skill = read("skills/general/adversarial-review/SKILL.md")

    fallback_sentences = [
      "If the named agent definitions are unavailable, spawn generic subtasks with the read-only wrapper below instead of requiring installation.",
      "If the host cannot prove a read-only sandbox, enforce the wrapper's behavioral read-only rules and disclose that sandbox enforcement was unavailable.",
    ]
    fallback_sentences.each do |sentence|
      assert_includes code_skill, sentence
      assert_includes code_adapter, sentence
    end
    assert_includes adversarial_skill, "`--report-only` maps to `--mode critique --output both`"
    assert_includes adversarial_skill, "`--chat-only` maps to `--output chat`"
    assert_includes adversarial_skill, "Critique mode never edits targets."
  end

  def test_adversarial_skill_uses_progressive_disclosure_and_documents_generic_handoff
    skill = read("skills/general/adversarial-review/SKILL.md")
    adapters = read("skills/general/adversarial-review/platform-adapters.md")
    angles = read("skills/general/adversarial-review/attack-angles.md")

    refute_includes skill,
                    "Load details from\n[attack-angles.md](attack-angles.md), [judge-rubric.md](judge-rubric.md), and\n[platform-adapters.md](platform-adapters.md)."
    assert_includes skill,
                    "Load `platform-adapters.md` only for executor selection or adapter troubleshooting."
    assert_includes skill,
                    "Load `attack-angles.md` and `judge-rubric.md` only for Ruby-unavailable manual fallback or role-contract debugging."
    assert_includes adapters, "repository_root"
    assert_includes adapters, "schema_path"
    assert_includes adapters, "schema_sha256"
    assert_includes adapters, "Start the worker with its working directory set to `repository_root`"
    assert_includes adapters, "verify `schema_sha256` before using `schema_path`"
    assert_includes angles, "The control plane emits the exact authoritative `required_checks` array"
    assert_includes angles, "Implementer is enabled only when a spec is present"
    assert_includes angles, "Feasibility is enabled only when a plan is present"
    assert_includes angles, "bounded scan of authoritative target prose"
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

    adversarial_adapter = read("skills/general/adversarial-review/platform-adapters.md")
    assert_includes adversarial_adapter, "Treat generic mode as the portable baseline and first-class fallback."
    assert_includes adversarial_adapter, "The control plane never silently downgrades model, effort, tier, or vendor."
    assert_includes adversarial_adapter, "requested and observed model"
    assert_includes adversarial_adapter, "A failed or missing observation returns an ineligible generic-shaped adapter result"

    adversarial_skill = read("skills/general/adversarial-review/SKILL.md")
    portable_effort_policy = "If the host cannot enforce required role effort, follow the selected platform adapter's explicit fallback or stop rule; do not invent a weaker generic fallback."
    assert_includes adversarial_skill, portable_effort_policy
    refute_includes adversarial_skill, "If the host cannot enforce xhigh effort, continue only with disclosure."
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

  def test_codex_adversarial_fallback_is_fail_closed
    adapter = read("skills/general/adversarial-review/platform-adapters.md")

    assert_includes adapter, "A direct adapter may run only when a pinned executable"
    assert_includes adapter, "Runtime events must\nconfirm all shared-gate claims."
    assert_includes adapter, "Codex `0.144.5` was observed during design"
    assert_includes adapter, "so its direct result is currently ineligible and generic-shaped"
    assert_includes adapter, "A future version can become direct-eligible only after machine attestation and caller dispatch evidence pass"
    refute_includes adapter, "downgrade to `--high`"
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

  def test_adversarial_natural_language_critique_is_chat_only
    skill = read("skills/general/adversarial-review/SKILL.md")
    policy = "For ordinary natural-language requests that ask only for critique or review, run the report-only stages and return findings in chat only; do not revise documents or create or append a report file."

    assert_includes skill, policy
    assert_includes skill, "`--report-only` never authorizes revision."
    refute_includes skill, "Repository writes require an explicit `--report-only`"
  end

  def test_adversarial_role_payload_contracts_are_normative
    attack_angles = read("skills/general/adversarial-review/attack-angles.md")
    judge_rubric = read("skills/general/adversarial-review/judge-rubric.md")

    assert_includes attack_angles, '"artifact_digests": {"docs/spec.md": "<64 lowercase hex SHA-256>"}'
    assert_includes attack_angles, '"checks_completed": ["named check actually performed"]'
    assert_includes attack_angles, '"location": {"path": "docs/spec.md", "line_start": 12, "line_end": 14, "heading": "Rollout"}'
    assert_includes attack_angles, "Every attacker and divergence probe must return the current artifact digests and the checks it actually completed."

    assert_includes judge_rubric, "Candidate IDs are immutable after ingestion and use `C-<angle-slug>-<attempt>-<sequence>`; every later role returns those IDs instead of batch-local indexes."
    assert_includes judge_rubric, '"disposition": "PROMOTE|REFUTE|UNPROVEN"'
    assert_includes judge_rubric, "`UNPROVEN` records an evidence gap; it is neither a promotion nor a refutation."
    assert_includes judge_rubric, "At `--ultra`, aggregate three independent votes only when at least two voters independently meet the evidence burden for the same `PROMOTE` or `REFUTE` disposition."
    assert_includes judge_rubric, "Any split involving `UNPROVEN` goes to arbitration and is never counted as a refutation."
    assert_includes judge_rubric, "- `author-is-right` -> `REJECTED`"
    assert_includes judge_rubric, "- `judge-is-right` -> `UNRESOLVED`"
    assert_includes judge_rubric, "- `needs-human` -> `UNRESOLVED`"
  end

  def test_adversarial_review_public_control_plane_is_portable_and_explicit
    skill = read("skills/general/adversarial-review/SKILL.md")
    angles = read("skills/general/adversarial-review/attack-angles.md")
    rubric = read("skills/general/adversarial-review/judge-rubric.md")
    adapters = read("skills/general/adversarial-review/platform-adapters.md")
    usage = read("USAGE.md")
    commands = read("COMMANDS.md")
    catalog = read("CATALOG.md")
    manifest = YAML.load_file(File.join(REPO_UNDER_TEST, "skills.yaml"))
    metadata = manifest.fetch("skills").find { |entry| entry.fetch("name") == "adversarial-review" }

    assert_includes skill, '"$AR_SKILL_DIR/scripts/adversarial-review" start'
    assert_includes skill, "--executor auto|codex|claude|cursor|gemini|generic"
    assert_includes skill, "--output chat|file|both"
    assert_includes skill, "`--report-only` maps to `--mode critique --output both`"
    assert_includes skill, "`--chat-only` maps to `--output chat`"
    assert_includes skill, "The default is `--mode revise --output both`"
    assert_includes skill, "DID NOT CONVERGE"
    assert_includes skill, "The parent alone applies `FIXED|REJECTED` actions"
    assert_includes skill, "does not install or change global skill links, agent definitions, or user configuration"

    assert_includes angles, "Candidate IDs remain immutable"
    assert_includes rubric, '"disposition": "PROMOTE|REFUTE|UNPROVEN"'
    assert_includes rubric, "Any split involving `UNPROVEN` goes to arbitration"
    assert_includes rubric, "In round 2 only"

    %w[Generic Codex Claude Cursor Gemini Copilot].each do |adapter|
      assert_includes adapters, "## #{adapter} Adapter"
    end
    assert_includes adapters, "never silently downgrades model, effort, tier, or vendor"
    assert_includes adapters, "machine-readable runtime attestation"
    assert_includes adapters, "requested and observed model and effort"
    assert_includes adapters, "Claude-only"
    assert_includes adapters, "The parser rejects direct `--jobs` greater than 1"
    assert_includes adapters, "malicious same-UID local administrator"

    assert_includes usage, "--executor auto|codex|claude|cursor|gemini|generic"
    assert_includes usage, "--output chat|file|both"
    assert_includes commands, "/absolute/path/to/installed/adversarial-review/scripts/adversarial-review start"
    refute_includes commands, "rtk skills/general/adversarial-review/scripts/adversarial-review"
    assert_match(/script-backed portable control plane/i, catalog)

    assert_equal %w[claude codex copilot cursor gemini], metadata.fetch("interfaces").sort
    assert metadata.dig("install", "cursor", "enabled")
    assert metadata.dig("install", "copilot", "enabled")
    assert_equal "deep", metadata.fetch("recommended_model_tier")
    assert_equal "ultracode", metadata.fetch("heavy_model_tier")
  end

  def test_adversarial_review_documents_installed_paths_and_fail_closed_boundaries
    skill = read("skills/general/adversarial-review/SKILL.md")
    usage = read("USAGE.md")
    commands = read("COMMANDS.md")
    adapters = read("skills/general/adversarial-review/platform-adapters.md")

    assert_includes skill, 'AR_SKILL_DIR="/absolute/path/to/directory-containing-this-SKILL.md"'
    assert_includes skill, 'REVIEW_REPO="/absolute/path/to/reviewed/repository"'
    assert_includes skill, '"$AR_SKILL_DIR/scripts/adversarial-review" start'
    assert_includes skill, '--repository "$REVIEW_REPO"'
    refute_includes skill, "skills/general/adversarial-review/scripts/adversarial-review start"

    assert_includes usage, 'AR_SKILL_DIR="/absolute/path/to/installed/adversarial-review"'
    assert_includes usage, '--repository "$REVIEW_REPO"'
    assert_includes commands, "/absolute/path/to/installed/adversarial-review/scripts/adversarial-review start --repository /absolute/path/to/reviewed/repository"
    refute_includes commands, "skills/general/adversarial-review/scripts/adversarial-review start"

    auto_boundary = /automatic generic fallback.*`--executor auto`.*before reviewed content.*before any external attempt/im
    assert_match auto_boundary, adapters
    assert_match(/explicit direct.*exit `4`.*resumable.*pinned/im, adapters)
    assert_match(/reviewed content.*exit `5`.*resumable.*pinned/im, adapters)

    assert_includes adapters, "`parallel_dispatch` as `unavailable`"
    assert_match(/default\/high direct Codex and Claude.*advisory.*all other safety/im, adapters)
    assert_includes adapters, "Ultra keeps parallel dispatch as a hard requirement."
    assert_match(/Cursor and\s+Gemini remain direct-ineligible/, adapters)
    assert_includes adapters, "Generic bundles are the portable path for host-native parallelism."
    assert_includes adapters, "`pending_task_handoffs` is the normative dispatch surface"
    assert_match(/verify `task_sha256`.*before parsing JSON.*before using.*cwd.*schema.*prompt/im, adapters)
    assert_match(/read the task bytes exactly once/i, adapters)
    assert_match(/schema.*installed skill root.*read.*once.*verify.*same.*bytes/im, adapters)
    assert_match(/use the returned in-memory task and schema/i, adapters)
    assert_match(/`pending_tasks`.*path inventory.*not.*dispatch/im, adapters)
    assert_includes usage, "`pending_task_handoffs` is the normative dispatch surface"
    assert_match(/verify `task_sha256`.*before parsing JSON/im, usage)
    assert_includes skill, "`pending_task_handoffs`"
    refute_match(/public CLI.*direct.*serial/i, adapters)
    refute_includes usage, "Direct adapters dispatch validated tasks serially."
  end

  def test_adversarial_review_documents_host_aliases_manual_fallback_and_degraded_verdict
    skill = read("skills/general/adversarial-review/SKILL.md")
    usage = read("USAGE.md")
    adapters = read("skills/general/adversarial-review/platform-adapters.md")

    assert_includes skill, "`--high` maps to `--tier high`"
    assert_includes skill, "`--ultra` maps to `--tier ultra`"
    assert_includes skill, "`--report-only` maps to `--mode critique --output both`"
    assert_includes skill, "`--chat-only` maps to `--output chat`"

    assert_includes skill, "Ruby 2.6 or newer"
    assert_includes skill, "When Ruby is unavailable"
    assert_match(/attack-angles\.md.*judge-rubric\.md.*assets\/schemas/m, skill)
    assert_match(/immutable IDs.*`UNPROVEN`.*parent-only decisions/m, skill)
    assert_includes skill, "Scripting unavailable; capabilities degraded."
    assert_includes skill, "do not invent durable state"
    assert_includes skill, "never switch to a weaker direct executor"

    [skill, usage, adapters].each do |text|
      assert_includes text, "DEGRADED CAPABILITIES"
    end
    assert_match(/required capability.*`unavailable`.*safety boundary.*`behavioral`/im, skill)
    assert_includes skill, "replaces only an ordinary `PASSED`"
    assert_match(/`REPORT ONLY`, `PASSED WITH OPEN QUESTIONS`, and `DID NOT CONVERGE` keep their verdict/im, skill)
    assert_includes skill, "Retained verdicts disclose degraded capabilities separately."
  end

  def test_adversarial_review_adapter_ineligibility_is_not_universal_cli_fallback
    adapters = read("skills/general/adversarial-review/platform-adapters.md")
    usage = read("USAGE.md")

    assert_includes adapters, "A failed or missing observation returns an ineligible generic-shaped adapter result"
    assert_match(/Only the public CLI with `--executor auto`.*pre-content.*zero prior external attempts.*converts.*emitted Generic bundles/im, adapters)
    assert_match(/Explicit direct.*exit `4` or `5`.*never converts.*Generic bundles/im, adapters)

    # Copilot is deliberately absent: it has no direct adapter to declare
    # ineligible, so it documents the generic bundle path instead.
    %w[Codex Claude Cursor Gemini].each do |vendor|
      section = adapters[/## #{vendor} Adapter\n(?<body>.*?)(?=\n## |\z)/m, :body]
      refute_nil section, vendor
      normalized = section.gsub(/\s+/, " ")
      assert_match(/ineligible.*generic-shaped|generic-shaped.*ineligible/i, normalized, vendor)
      assert_includes normalized, "The adapter does not emit Generic bundles; only the qualifying public auto boundary converts it."
      refute_match(/falls? back|selects? generic|execution falls/i, normalized, vendor)
    end

    assert_match(/Only `--executor auto`.*converts.*Generic bundles/im, usage)
    assert_match(/Explicit direct.*exit `4` or `5`.*never.*Generic bundles/im, usage)
  end

  def test_adversarial_review_degradation_only_replaces_an_ordinary_pass
    skill = read("skills/general/adversarial-review/SKILL.md")
    adapters = read("skills/general/adversarial-review/platform-adapters.md")
    usage = read("USAGE.md")

    [skill, adapters, usage].each do |text|
      normalized = text.gsub(/\s+/, " ")
      assert_includes normalized, "DEGRADED CAPABILITIES"
      assert_includes normalized, "replaces only an ordinary `PASSED`"
      assert_includes normalized, "`REPORT ONLY`, `PASSED WITH OPEN QUESTIONS`, and `DID NOT CONVERGE` keep their verdict"
      assert_includes normalized, "Retained verdicts disclose degraded capabilities separately."
      refute_match(/revise\/reject outcomes.*keep their verdict/i, normalized)
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
