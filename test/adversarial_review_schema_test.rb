require "minitest/autorun"

SKILL = File.expand_path("../skills/general/adversarial-review", __dir__)
$LOAD_PATH.unshift(File.join(SKILL, "scripts", "lib"))
require "adversarial_review"

class AdversarialReviewSchemaTest < Minitest::Test
  MAX_MODEL_STRING = 8192
  MAX_MODEL_ITEMS = 256

  def test_public_entrypoint_exposes_skill_root
    assert_equal SKILL, AdversarialReview.root
  end

  def test_attack_schema_accepts_complete_candidate
    assert_empty AdversarialReview::Schema.validate("attack", valid_attack)
  end

  def test_all_role_schemas_bound_every_model_controlled_string_and_array
    %w[attack divergence dedupe judge author-actions resolution arbiter].each do |name|
      schema = JSON.parse(File.read(File.join(SKILL, "assets", "schemas", "#{name}.json")))
      assert_schema_nodes_bounded(schema, name)
    end
  end

  def test_schema_string_and_collection_bounds_accept_limit_and_reject_limit_plus_one
    at_limit = valid_attack.merge(
      "notes" => Array.new(MAX_MODEL_ITEMS, "n"),
      "checks_completed" => ["x" * MAX_MODEL_STRING]
    )
    assert_empty AdversarialReview::Schema.validate("attack", at_limit)

    too_many = at_limit.merge("notes" => Array.new(MAX_MODEL_ITEMS + 1, "n"))
    errors = AdversarialReview::Schema.validate("attack", too_many)
    assert_includes errors.map { |error| error.fetch("code") }, "max_items"

    too_long = at_limit.merge("checks_completed" => ["x" * (MAX_MODEL_STRING + 1)])
    errors = AdversarialReview::Schema.validate("attack", too_long)
    assert_includes errors.map { |error| error.fetch("code") }, "max_length"
  end

  def test_attack_schema_accepts_optional_role_metrics
    value = valid_attack.merge("metrics" => role_metrics)

    assert_empty AdversarialReview::Schema.validate("attack", value)
  end

  def test_attack_schema_rejects_negative_role_count
    value = valid_attack.merge("metrics" => role_metrics.merge("requirements_total" => -1))
    errors = AdversarialReview::Schema.validate("attack", value)

    assert_includes errors.map { |error| error.fetch("code") }, "minimum"
    assert_includes errors.map { |error| error.fetch("path") }, "/metrics/requirements_total"
  end

  def test_attack_schema_rejects_negative_role_percentage
    value = valid_attack.merge("metrics" => role_metrics.merge("coverage_percent" => -0.1))
    errors = AdversarialReview::Schema.validate("attack", value)

    assert_includes errors.map { |error| error.fetch("code") }, "minimum"
    assert_includes errors.map { |error| error.fetch("path") }, "/metrics/coverage_percent"
  end

  def test_attack_schema_rejects_role_percentage_above_hundred
    value = valid_attack.merge("metrics" => role_metrics.merge("testable_criteria_percent" => 100.1))
    errors = AdversarialReview::Schema.validate("attack", value)

    assert_includes errors.map { |error| error.fetch("code") }, "maximum"
    assert_includes errors.map { |error| error.fetch("path") }, "/metrics/testable_criteria_percent"
  end

  def test_divergence_schema_accepts_complete_probe
    assert_empty AdversarialReview::Schema.validate("divergence", valid_divergence)
  end

  def test_divergence_schema_accepts_optional_attack_role_metrics
    value = valid_divergence.merge("metrics" => role_metrics)

    assert_empty AdversarialReview::Schema.validate("divergence", value)
  end

  def test_dedupe_schema_accepts_complete_groups
    assert_empty AdversarialReview::Schema.validate("dedupe", valid_dedupe)
  end

  def test_judge_schema_accepts_complete_verdicts
    assert_empty AdversarialReview::Schema.validate("judge", valid_judge)
  end

  def test_author_actions_schema_accepts_complete_actions
    assert_empty AdversarialReview::Schema.validate("author-actions", valid_author_actions)
  end

  def test_author_actions_schema_accepts_unambiguous_repo_relative_changed_paths
    value = author_actions_with_paths("docs/spec.md", "nested/file.rb", "nested\\file.rb", "src/v1.2/file[old].rb")

    assert_empty AdversarialReview::Schema.validate("author-actions", value)
  end

  def test_author_actions_schema_rejects_repository_escape_paths
    invalid_paths = [
      "../outside.md",
      "..\\outside.md",
      "/absolute",
      "\\absolute/UNC",
      "//server/share",
      "\\\\server\\share",
      "C:\\outside.md",
      "C:/outside.md",
      "C:foo",
      ".",
      "..",
      "docs/../outside.md",
      "docs\\..\\outside.md",
      "docs/./spec.md",
      "docs\\.\\spec.md",
      "docs//spec.md",
      "docs\\\\spec.md",
      "docs/spec.md/",
      "docs\\spec.md\\",
      "docs/\noutside.md",
      "docs/\routside.md",
      "docs/\toutside.md",
      "docs/\u0000outside.md",
      "docs/\u007foutside.md",
    ]

    invalid_paths.each do |path|
      errors = AdversarialReview::Schema.validate("author-actions", author_actions_with_paths(path))
      assert_includes errors.map { |error| error.fetch("code") }, "invalid_path", path.inspect
      assert_includes errors.map { |error| error.fetch("path") }, "/actions/0/changed_paths/0", path.inspect
    end

    empty_errors = AdversarialReview::Schema.validate("author-actions", author_actions_with_paths(""))
    assert_includes empty_errors.map { |error| error.fetch("code") }, "min_length"
  end

  def test_resolution_schema_accepts_complete_checks_and_new_findings
    assert_empty AdversarialReview::Schema.validate("resolution", valid_resolution)
  end

  def test_finding_locations_reject_reversed_line_ranges
    [
      ["attack", valid_attack, "findings"],
      ["divergence", valid_divergence, "findings"],
      ["resolution", valid_resolution, "new_findings"]
    ].each do |schema, payload, collection|
      finding = payload.fetch(collection).first
      location = finding.fetch("location").merge("line_start" => 9, "line_end" => 2)
      value = payload.merge(collection => [finding.merge("location" => location)])

      errors = AdversarialReview::Schema.validate(schema, value)

      assert_includes errors.map { |error| error.fetch("code") }, "line_order", schema
      assert_includes errors.map { |error| error.fetch("path") },
                      "/#{collection}/0/location/line_end", schema
    end
  end

  def test_arbiter_schema_accepts_complete_decisions
    assert_empty AdversarialReview::Schema.validate("arbiter", valid_arbiter)
  end

  def test_resolution_role_example_satisfies_its_schema
    payload = role_example("Resolution Check")

    assert_empty AdversarialReview::Schema.validate("resolution", payload)
  end

  def test_arbiter_role_example_satisfies_its_schema
    payload = role_example("Arbiter")

    assert_empty AdversarialReview::Schema.validate("arbiter", payload)
  end

  def test_attack_schema_rejects_unknown_property
    errors = AdversarialReview::Schema.validate("attack", invalid_attack)

    assert_includes errors.map { |error| error.fetch("code") }, "additional_property"
    assert_includes errors.map { |error| error.fetch("path") }, "/findings/0/location/surprise"
  end

  def test_divergence_schema_rejects_missing_required_field
    errors = AdversarialReview::Schema.validate("divergence", invalid_divergence)

    assert_includes errors.map { |error| error.fetch("code") }, "required"
    assert_includes errors.map { |error| error.fetch("path") }, "/hypothesis"
  end

  def test_dedupe_schema_rejects_invalid_constant
    errors = AdversarialReview::Schema.validate("dedupe", invalid_dedupe)

    assert_includes errors.map { |error| error.fetch("code") }, "const"
    assert_includes errors.map { |error| error.fetch("path") }, "/schema_version"
  end

  def test_author_actions_schema_rejects_invalid_enum
    errors = AdversarialReview::Schema.validate("author-actions", invalid_author_actions)

    assert_includes errors.map { |error| error.fetch("code") }, "enum"
    assert_includes errors.map { |error| error.fetch("path") }, "/actions/0/action"
  end

  def test_judge_schema_rejects_wrong_type
    errors = AdversarialReview::Schema.validate("judge", invalid_judge)

    assert_includes errors.map { |error| error.fetch("code") }, "type"
    assert_includes errors.map { |error| error.fetch("path") }, "/verdicts/0/confidence"
  end

  def test_resolution_schema_rejects_value_below_minimum
    errors = AdversarialReview::Schema.validate("resolution", invalid_resolution)

    assert_includes errors.map { |error| error.fetch("code") }, "minimum"
    assert_includes errors.map { |error| error.fetch("path") }, "/metrics/duration_ms"
  end

  def test_arbiter_schema_rejects_value_above_maximum
    errors = AdversarialReview::Schema.validate("arbiter", invalid_arbiter)

    assert_includes errors.map { |error| error.fetch("code") }, "maximum"
    assert_includes errors.map { |error| error.fetch("path") }, "/decisions/0/confidence"
  end

  def test_attack_schema_rejects_string_below_minimum_length
    errors = AdversarialReview::Schema.validate("attack", valid_attack.merge("run_id" => ""))

    assert_includes errors.map { |error| error.fetch("code") }, "min_length"
    assert_includes errors.map { |error| error.fetch("path") }, "/run_id"
  end

  def test_judge_schema_rejects_candidate_id_that_misses_pattern
    value = valid_judge
    verdict = value.fetch("verdicts").first.merge("candidate_id" => "AR-001")
    errors = AdversarialReview::Schema.validate("judge", value.merge("verdicts" => [verdict]))

    assert_includes errors.map { |error| error.fetch("code") }, "pattern"
    assert_includes errors.map { |error| error.fetch("path") }, "/verdicts/0/candidate_id"
  end

  def test_judge_schema_rejects_candidate_id_with_trailing_control_suffix
    ["\n", "\r", "\r\n"].each do |suffix|
      value = valid_judge
      verdict = value.fetch("verdicts").first.merge(
        "candidate_id" => "C-assumptions-checker-1-1#{suffix}"
      )
      errors = AdversarialReview::Schema.validate("judge", value.merge("verdicts" => [verdict]))

      assert_includes errors.map { |error| error.fetch("code") }, "pattern", suffix.inspect
      assert_includes errors.map { |error| error.fetch("path") }, "/verdicts/0/candidate_id", suffix.inspect
    end
  end

  def test_attack_schema_validates_dynamic_artifact_digest_values
    value = valid_attack.merge("artifact_digests" => {"docs/v1.2/spec[old].md" => "A" * 64})
    errors = AdversarialReview::Schema.validate("attack", value)

    assert_includes errors.map { |error| error.fetch("code") }, "pattern"
    assert_includes errors.map { |error| error.fetch("path") }, "/artifact_digests/docs~1v1.2~1spec[old].md"
  end

  def test_attack_schema_rejects_digest_with_trailing_control_suffix
    ["\n", "\r", "\r\n"].each do |suffix|
      digest = ("a" * 64) + suffix
      value = valid_attack.merge("artifact_digests" => {"docs/spec.md" => digest})
      errors = AdversarialReview::Schema.validate("attack", value)

      assert_includes errors.map { |error| error.fetch("code") }, "pattern", suffix.inspect
      assert_includes errors.map { |error| error.fetch("path") }, "/artifact_digests/docs~1spec.md", suffix.inspect
    end
  end

  def test_unanchored_schema_pattern_uses_search_semantics
    schema = {"type" => "string", "pattern" => "needle"}

    assert_empty AdversarialReview::Schema.new(schema, "inline").validate("hay needle stack")
  end

  def test_escaped_terminal_dollar_is_not_treated_as_end_anchor
    schema = {"type" => "string", "pattern" => "^price\\$"}

    assert_empty AdversarialReview::Schema.new(schema, "inline").validate("price$ plus tax")
  end

  def test_error_paths_escape_tilde_in_dynamic_keys
    value = valid_attack.merge("artifact_digests" => {"docs/v1~2/spec.md" => "A" * 64})
    errors = AdversarialReview::Schema.validate("attack", value)

    assert_includes errors.map { |error| error.fetch("path") }, "/artifact_digests/docs~1v1~02~1spec.md"
  end

  def test_dedupe_schema_rejects_candidate_in_multiple_groups
    first_group = valid_dedupe.fetch("groups").first
    second_group = first_group.merge(
      "group_id" => "G-002",
      "candidate_ids" => ["C-assumptions-checker-1-1"],
      "summary" => "A conflicting duplicate group."
    )
    value = valid_dedupe.merge("groups" => [first_group, second_group])
    errors = AdversarialReview::Schema.validate("dedupe", value)

    assert_includes errors.map { |error| error.fetch("code") }, "candidate_duplicate"
    assert_includes errors.map { |error| error.fetch("path") }, "/groups/1/candidate_ids/0"
  end

  def test_attack_schema_rejects_empty_artifact_path
    value = valid_attack.merge("artifact_digests" => {"" => "a" * 64})
    errors = AdversarialReview::Schema.validate("attack", value)

    assert_includes errors.map { |error| error.fetch("code") }, "min_length"
    assert_includes errors.map { |error| error.fetch("path") }, "/artifact_digests"
  end

  private

  def assert_schema_nodes_bounded(node, path)
    return unless node.is_a?(Hash)

    assert node.key?("maxLength"), "#{path} string lacks maxLength" if node["type"] == "string"
    assert node.key?("maxItems"), "#{path} array lacks maxItems" if node["type"] == "array"
    node.each do |key, value|
      if value.is_a?(Hash)
        assert_schema_nodes_bounded(value, "#{path}/#{key}")
      elsif value.is_a?(Array) && key != "required" && key != "enum"
        value.each_with_index do |child, index|
          assert_schema_nodes_bounded(child, "#{path}/#{key}/#{index}")
        end
      end
    end
  end

  def role_example(heading)
    text = File.read(File.join(SKILL, "judge-rubric.md"))
    match = text.match(/^## #{Regexp.escape(heading)}\n(?<body>.*?)(?=^## |\z)/m)
    raise "missing role section: #{heading}" unless match

    json = match[:body][/```json\n(?<json>.*?)\n```/m, :json]
    raise "missing JSON example: #{heading}" unless json

    JSON.parse(json)
  end

  def role_metrics
    {
      "testable_criteria_percent" => 87.5,
      "requirements_total" => 12,
      "requirements_covered" => 10,
      "coverage_percent" => 83.3,
      "unmapped_tasks" => 1,
    }
  end

  def author_actions_with_paths(*paths)
    value = valid_author_actions
    action = value.fetch("actions").first.merge("changed_paths" => paths)
    value.merge("actions" => [action])
  end

  def valid_attack
    {
      "schema_version" => 1,
      "run_id" => "ar-20260717-example",
      "task_id" => "attack-assumptions-1",
      "angle" => "assumptions-checker",
      "artifact_digests" => {"docs/spec.md" => "a" * 64},
      "checks_completed" => ["stated assumptions", "unstated assumptions"],
      "findings" => [{
        "location" => {
          "path" => "docs/spec.md",
          "line_start" => 12,
          "line_end" => 14,
          "heading" => "Rollout",
        },
        "category" => "Omission",
        "summary" => "Rollback owner is absent",
        "evidence" => "The rollout section names no owner.",
        "consequence" => "A failed rollout has no authorized recovery path.",
      }],
      "metrics" => {
        "input_tokens" => 120,
        "output_tokens" => 40,
        "cached_tokens" => 20,
        "duration_ms" => 250,
      },
      "notes" => ["Reviewed the complete rollout section."],
    }
  end

  def invalid_attack
    value = valid_attack
    finding = value.fetch("findings").first
    location = finding.fetch("location").merge("surprise" => true)
    value.merge("findings" => [finding.merge("location" => location)])
  end

  def valid_divergence
    valid_attack.merge(
      "task_id" => "divergence-1",
      "angle" => "divergence-probe",
      "probe_id" => "probe-1",
      "hypothesis" => "The rollout is implemented as an explicit state machine."
    )
  end

  def invalid_divergence
    valid_divergence.reject { |key, _value| key == "hypothesis" }
  end

  def valid_dedupe
    {
      "schema_version" => 1,
      "run_id" => "ar-20260717-example",
      "task_id" => "dedupe-1",
      "artifact_digests" => {"docs/spec.md" => "a" * 64},
      "groups" => [{
        "group_id" => "G-001",
        "candidate_ids" => ["C-assumptions-checker-1-1", "C-premortem-1-1"],
        "summary" => "The rollout lacks an accountable rollback owner.",
        "location" => {
          "path" => "docs/spec.md",
          "line_start" => 12,
          "line_end" => 14,
          "heading" => "Rollout",
        },
        "source_angles" => ["assumptions-checker", "premortem"],
      }],
      "notes" => ["No byte-identical candidates were collapsed."],
    }
  end

  def invalid_dedupe
    valid_dedupe.merge("schema_version" => 2)
  end

  def valid_judge
    {
      "schema_version" => 1,
      "run_id" => "ar-20260717-example",
      "task_id" => "judge-rollout-1",
      "artifact_digests" => {"docs/spec.md" => "a" * 64},
      "verdicts" => [{
        "candidate_id" => "C-assumptions-checker-1-1",
        "disposition" => "UNPROVEN",
        "confidence" => 0.65,
        "category" => "Omission",
        "severity" => "HIGH",
        "evidence" => "The packet contains no ownership record.",
        "consequence" => "The candidate remains an evidence gap.",
      }],
      "metrics" => {"input_tokens" => 80, "output_tokens" => 30},
      "notes" => ["The available repository evidence was inconclusive."],
    }
  end

  def invalid_judge
    value = valid_judge
    verdict = value.fetch("verdicts").first.merge("confidence" => "high")
    value.merge("verdicts" => [verdict])
  end

  def valid_author_actions
    {
      "schema_version" => 1,
      "run_id" => "ar-20260717-example",
      "task_id" => "author-actions-1",
      "artifact_digests" => {"docs/spec.md" => "b" * 64},
      "actions" => [{
        "finding_id" => "AR-001",
        "action" => "FIXED",
        "rationale" => "The rollout now names the release manager as rollback owner.",
        "changed_paths" => ["docs/spec.md"],
      }],
      "notes" => ["Only the reviewed spec changed."],
    }
  end

  def invalid_author_actions
    value = valid_author_actions
    action = value.fetch("actions").first.merge("action" => "DEFERRED")
    value.merge("actions" => [action])
  end

  def valid_resolution
    {
      "schema_version" => 1,
      "run_id" => "ar-20260717-example",
      "task_id" => "resolution-1",
      "artifact_digests" => {"docs/spec.md" => "b" * 64},
      "checks" => [{
        "finding_id" => "AR-001",
        "status" => "RESOLVED",
        "evidence" => "The rollout section now assigns rollback to the release manager.",
      }],
      "new_findings" => [valid_attack.fetch("findings").first],
      "metrics" => {"duration_ms" => 180},
      "notes" => ["Round-two regression sweep completed."],
    }
  end

  def invalid_resolution
    valid_resolution.merge("metrics" => {"duration_ms" => -1})
  end

  def valid_arbiter
    {
      "schema_version" => 1,
      "run_id" => "ar-20260717-example",
      "task_id" => "arbiter-1",
      "artifact_digests" => {"docs/spec.md" => "b" * 64},
      "decisions" => [{
        "subject_id" => "AR-001",
        "decision" => "UNRESOLVED",
        "confidence" => 0.9,
        "evidence" => "The author's rejection does not identify a rollback owner.",
        "mapped_candidate_ids" => ["C-assumptions-checker-1-1"],
      }],
      "metrics" => {"input_tokens" => 60, "output_tokens" => 20},
      "notes" => ["The finding remains contested."],
    }
  end

  def invalid_arbiter
    value = valid_arbiter
    decision = value.fetch("decisions").first.merge("confidence" => 1.1)
    value.merge("decisions" => [decision])
  end
end
