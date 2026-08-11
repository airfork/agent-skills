require "json"
require "minitest/autorun"
require "yaml"

class AdversarialReviewSkillContractTest < Minitest::Test
  REPO_UNDER_TEST = File.expand_path("..", __dir__)
  SKILL_DIR = "skills/general/adversarial-review".freeze
  ANGLES = %w[implementer tester feasibility pre-mortem].freeze
  # v1 ran these and they produced the bulk of the unadjudicated findings. Their
  # absence is a contract, not an accident.
  RETIRED_ANGLES = %w[
    consistency-smells assumptions-checker traceability divergence-probe
  ].freeze

  def read(path)
    File.read(File.join(REPO_UNDER_TEST, path))
  end

  def skill
    read("#{SKILL_DIR}/SKILL.md")
  end

  def schema(name)
    JSON.parse(read("#{SKILL_DIR}/assets/schemas/#{name}.json"))
  end

  def skill_files
    Dir.glob(File.join(REPO_UNDER_TEST, SKILL_DIR, "**", "*")).select { |path| File.file?(path) }
  end

  def test_the_skill_is_read_only_and_says_so
    assert_includes skill, "never edits the reviewed documents"
    assert_includes skill, "**Read-only.**"
    refute_match(/--mode revise/, skill)
  end

  def test_the_four_angles_are_declared_and_the_retired_ones_are_gone
    angles = read("#{SKILL_DIR}/attack-angles.md")

    ANGLES.each do |angle|
      assert_includes angles, "## #{angle}", "#{angle} has no section"
      assert_includes skill, "`#{angle}`", "#{angle} is missing from the SKILL.md roster"
    end

    RETIRED_ANGLES.each do |retired|
      skill_files.each do |path|
        refute_match(/#{Regexp.escape(retired)}/, File.read(path),
                     "#{path} still references the retired #{retired} angle")
      end
    end
  end

  def test_caps_are_stated_in_both_prose_and_schema
    assert_includes skill, "at most two findings"
    assert_includes skill, "**at most three**"
    assert_equal 2, schema("attack").dig("properties", "findings", "maxItems")
    assert_equal 3, schema("synthesis").dig("properties", "findings", "maxItems")
  end

  def test_zero_findings_is_an_explicitly_valid_outcome
    assert_includes skill, "Returning zero findings is a valid and good outcome"
    assert_includes read("#{SKILL_DIR}/synthesis-rubric.md"),
                    "**Zero findings is a correct, valuable outcome.**"
  end

  # Attackers are breadth-finders and the synthesizer is the filter; inverting
  # this is what made v1 cost hours per run.
  def test_roles_are_tiered_cheap_finders_and_one_expensive_filter
    assert_includes skill, "**`sonnet`, effort `medium`**"
    assert_includes skill, "**`opus`, effort `high`**"

    attacker = read("#{SKILL_DIR}/agents/codex/spec-attacker.toml")
    synthesizer = read("#{SKILL_DIR}/agents/codex/spec-synthesizer.toml")
    assert_includes attacker, 'model_reasoning_effort = "medium"'
    assert_includes synthesizer, 'model_reasoning_effort = "high"'
    [attacker, synthesizer].each do |toml|
      assert_includes toml, 'sandbox_mode = "read-only"'
    end
  end

  def test_attackers_dispatch_in_one_parallel_batch
    assert_includes skill, "in a single parallel batch"
    assert_includes skill, "never sequentially"
  end

  def test_quote_verification_is_delegated_to_the_script
    assert_includes skill, "scripts/check-quotes"
    assert_includes skill, "Do not substitute your own reading of the files for this check."
    assert_includes skill, "**No finding without a verified verbatim quote.**"

    script = File.join(REPO_UNDER_TEST, SKILL_DIR, "scripts", "check-quotes")
    assert File.executable?(script), "check-quotes must be executable"
  end

  def test_the_synthesizer_defaults_to_rejecting
    rubric = read("#{SKILL_DIR}/synthesis-rubric.md")

    assert_includes rubric, "**Your job is to reject.**"
    assert_includes rubric, "## Reject"
    # No LOW severity: a finding that would be LOW is one that should have been
    # dropped, and offering the label invites padding.
    refute_includes schema("synthesis")
      .dig("properties", "findings", "items", "properties", "severity", "enum"), "LOW"
    refute_includes schema("attack")
      .dig("properties", "findings", "items", "properties", "severity", "enum"), "LOW"
  end

  # The v1 control plane is gone; nothing may still describe it as present.
  def test_no_v1_control_plane_vocabulary_survives
    dead = [
      "DID NOT CONVERGE", "PASSED WITH OPEN QUESTIONS", "DEGRADED CAPABILITIES",
      "--tier", "--executor", "--run-dir", "platform-adapters.md",
      "judge-rubric.md", "control plane", "fresh sweep", "arbiter"
    ]
    skill_files.each do |path|
      contents = File.read(path)
      dead.each do |phrase|
        refute_match(/#{Regexp.escape(phrase)}/i, contents, "#{path} still references #{phrase}")
      end
    end
  end

  def test_retired_v1_files_are_absent
    %w[
      platform-adapters.md judge-rubric.md scripts/adversarial-review scripts/lib
    ].each do |relative|
      path = File.join(REPO_UNDER_TEST, SKILL_DIR, relative)
      refute File.exist?(path), "#{relative} should have been removed with the control plane"
    end
    refute File.exist?(File.join(REPO_UNDER_TEST, "scripts", "verify-adversarial-review"))
  end

  def test_schemas_are_closed
    %w[attack synthesis].each do |name|
      document = schema(name)
      assert_equal false, document.fetch("additionalProperties"), "#{name} is not closed"
      assert_equal(
        false,
        document.dig("properties", "findings", "items", "additionalProperties"),
        "#{name} findings are not closed"
      )
    end
  end

  def test_published_metadata_matches_the_cheap_single_round_shape
    manifest = YAML.load_file(File.join(REPO_UNDER_TEST, "skills.yaml"))
    metadata = manifest.fetch("skills").find { |entry| entry.fetch("name") == "adversarial-review" }
    refute_nil metadata

    assert_equal "standard", metadata.fetch("recommended_model_tier")
    refute metadata.key?("heavy_model_tier"),
           "a heavy tier contradicts a review that caps itself at five model calls"

    catalog = read("CATALOG.md")
    refute_match(/script-backed portable control plane/i, catalog)

    [read("USAGE.md"), read("COMMANDS.md")].each do |document|
      refute_match(%r{adversarial-review/scripts/adversarial-review}, document)
    end
  end
end
