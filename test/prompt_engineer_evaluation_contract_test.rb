require "json"
require "minitest/autorun"
require "digest"
require "open3"
require "psych"
require "tmpdir"

require_relative "support/prompt_engineer_helper"
require_relative "../scripts/lib/prompt_engineer"

class PromptEngineerEvaluationContractTest < Minitest::Test
  include PromptEngineerTestHelper

  def test_public_library_loads
    assert defined?(PromptEngineer::Canonical)
    assert defined?(PromptEngineer::Contracts)
    assert defined?(PromptEngineer::Corpus)
    assert defined?(PromptEngineer::Budget)
    assert defined?(PromptEngineer::Capabilities)
    assert defined?(PromptEngineer::Normalizers)
    assert defined?(PromptEngineer::Scoring)
    assert defined?(PromptEngineer::Reporting)
  end

  def test_task8_masking_is_deterministic_and_does_not_expose_arm_or_private_paths
    records = %w[legacy replacement unassisted].map do |arm|
      executor_output_for(arm, text: "neutral output", package_digest: arm == "legacy" ? "l" * 64 : "r" * 64)
    end
    packet = PromptEngineer::Scoring.build_judge_packet(
      run_id: "run-task8",
      case_id: "PE-001",
      host: "codex",
      repeat_index: 0,
      seed: "fixed-seed",
      public_case: task8_public_case,
      rubric: task8_rubric,
      executor_records: records
    )
    repeated = PromptEngineer::Scoring.build_judge_packet(
      run_id: "run-task8",
      case_id: "PE-001",
      host: "codex",
      repeat_index: 0,
      seed: "fixed-seed",
      public_case: task8_public_case,
      rubric: task8_rubric,
      executor_records: records.reverse
    )

    assert_equal packet.to_h, repeated.to_h
    assert_equal packet.packet_digest, repeated.packet_digest
    assert_equal packet.masked_label_map_digest, repeated.masked_label_map_digest
    assert_equal packet.document.fetch("output_labels").sort, packet.document.fetch("output_labels")
    refute packet.document.key?("label_map")
    refute packet.document.key?("arm")
    refute packet.document.to_s.include?("legacy")
    refute packet.document.to_s.include?("replacement")
    refute packet.document.to_s.include?("/private/source")
    assert_equal PromptEngineer::Canonical.digest(task8_rubric), packet.private_rubric_digest
    assert_match(/\A[0-9a-f]{64}\z/, packet.packet_digest)
  end

  def test_task8_judge_ingestion_requires_packet_binding_and_point_level_evidence
    packet = task8_packet
    result = judge_result_for(packet, statuses: {"success" => "fail"})

    assert PromptEngineer::Scoring.ingest_judge_result!(result, packet: packet)

    missing_citation = Marshal.load(Marshal.dump(result))
    point = missing_citation.fetch("rubric_dimensions").first.fetch("point_results").find { |item| item.fetch("point_id") == "success" }
    point["citation"] = nil
    assert_contract_error PromptEngineer::Scoring::Error, "citation" do
      PromptEngineer::Scoring.ingest_judge_result!(missing_citation, packet: packet)
    end

    duplicate_point = Marshal.load(Marshal.dump(result))
    duplicate_point.fetch("rubric_dimensions").first.fetch("point_results") << duplicate_point.fetch("rubric_dimensions").first.fetch("point_results").first
    assert_contract_error PromptEngineer::Scoring::Error, "point" do
      PromptEngineer::Scoring.ingest_judge_result!(duplicate_point, packet: packet)
    end

    wrong_packet = Marshal.load(Marshal.dump(result))
    wrong_packet["masked_packet_digest"] = "f" * 64
    assert_contract_error PromptEngineer::Scoring::Error, "packet" do
      PromptEngineer::Scoring.ingest_judge_result!(wrong_packet, packet: packet)
    end

    guessed_arm = Marshal.load(Marshal.dump(result))
    guessed_arm["arm"] = "replacement"
    assert_contract_error PromptEngineer::Scoring::Error, "arm" do
      PromptEngineer::Scoring.ingest_judge_result!(guessed_arm, packet: packet)
    end
  end

  def test_task8_repeat_reconciliation_uses_lower_score_and_marks_uncertainty_inconclusive
    packet = task8_packet
    first = judge_result_for(packet, statuses: {})
    second = judge_result_for(packet, statuses: {"success" => "fail"})

    reconciled = PromptEngineer::Scoring.reconcile_judges([first, second], packet: packet)
    assert_equal "scored", reconciled.fetch("status")
    assert_equal 0, reconciled.fetch("scores").fetch("task_success")
    assert_equal "second", reconciled.fetch("selected_judge")
    assert reconciled.fetch("judge_disagreement")

    uncertain = judge_result_for(packet, statuses: {}, overall_uncertainty: "material")
    uncertain_reconciliation = PromptEngineer::Scoring.reconcile_judges([uncertain], packet: packet)
    assert_equal "inconclusive", uncertain_reconciliation.fetch("status")
  end

  def test_task8_repeat_selection_is_frozen_and_caps_stability_and_targeted_runs
    rows = [
      {"host" => "codex", "case_id" => "PE-001", "replacement" => {"task_success" => 3, "requirement_preservation" => 3}, "legacy" => {"task_success" => 4, "requirement_preservation" => 3}},
      {"host" => "claude", "case_id" => "PE-002", "replacement" => {"task_success" => 4, "requirement_preservation" => 2}, "legacy" => {"task_success" => 4, "requirement_preservation" => 3}}
    ]
    selected = PromptEngineer::Scoring.select_repeats(rows, corpus_digest: "c" * 64, stability_case_ids: %w[PE-001 PE-002 PE-003])
    assert_equal rows, selected.fetch("targeted_candidates")
    assert_equal 18, selected.fetch("stability_session_cap")
    assert_equal 6, selected.fetch("targeted_session_cap")
    assert_equal 2, selected.fetch("selected").length
    assert_equal selected, PromptEngineer::Scoring.select_repeats(rows.reverse, corpus_digest: "c" * 64, stability_case_ids: %w[PE-001 PE-002 PE-003])
  end

  def test_task8_release_decision_is_fail_closed_for_zero_tolerance_and_missing_host_coverage
    qualified = task8_release_evidence
    assert_equal "QUALIFIED_EXPLICIT", PromptEngineer::Scoring.release_decision(qualified).fetch("decision")

    safety_failure = Marshal.load(Marshal.dump(qualified))
    safety_failure["zero_tolerance_failures"] = [{"host" => "codex", "case_id" => "PE-001", "id" => "authorization"}]
    assert_equal "NOT_QUALIFIED", PromptEngineer::Scoring.release_decision(safety_failure).fetch("decision")

    missing_host = Marshal.load(Marshal.dump(qualified))
    missing_host["comparisons"] = qualified.fetch("comparisons").reject { |comparison| comparison.fetch("host") == "claude" }
    assert_equal "INCONCLUSIVE", PromptEngineer::Scoring.release_decision(missing_host).fetch("decision")

    unsupported = Marshal.load(Marshal.dump(qualified))
    unsupported["host_status"] = {"codex" => "unsupported", "claude" => "unsupported"}
    assert_equal "INCONCLUSIVE", PromptEngineer::Scoring.release_decision(unsupported).fetch("decision")
  end

  def test_task8_report_is_reproducible_and_recomputes_decision_from_immutable_evidence
    evidence = task8_release_evidence.merge(
      "environment" => {"codex" => {"version" => "fixture-1"}, "claude" => {"version" => "fixture-1"}},
      "digests" => {"corpus" => "c" * 64, "package" => "p" * 64, "legacy_lock" => "l" * 64},
      "budgets" => {"behavioral" => {"used" => 72, "cap" => 96}, "judge" => {"used" => 1, "cap" => 64}},
      "exclusions" => ["live hosts were not launched"],
      "trigger_results" => {"positive" => {"passed" => 0, "total" => 0}, "negative" => {"passed" => 0, "total" => 0}}
    )
    first = PromptEngineer::Reporting.render(evidence)
    second = PromptEngineer::Reporting.render(Marshal.load(Marshal.dump(evidence)))

    assert_equal first, second
    assert_includes first, "# Prompt Engineer Qualification Report"
    assert_includes first, "QUALIFIED_EXPLICIT"
    assert_includes first, "live hosts were not launched"
    assert_includes first, "zero-tolerance"
    refute_includes first, "arm_label_map"
  end

  def test_native_capability_report_is_closed_and_marks_both_hosts_unsupported
    report = PromptEngineer::Capabilities.report

    assert_equal %w[claude codex], report.keys.sort
    report.each do |host, capability|
      assert_equal host, capability.fetch("host")
      assert_equal "unsupported", capability.fetch("status")
      assert_equal "absent", capability.fetch("normalizer")
      assert_equal "real native export evidence is unavailable", capability.fetch("reason")
      evidence = capability.fetch("evidence")
      assert_equal %w[artifact pointer root sha256], evidence.keys.sort
      assert_match(%r{\A/Users/tunji/\.codex/prompt-engineer-replacement-evidence/task0\z}, evidence.fetch("root"))
      assert_match(%r{\A(?:codex|claude)/export-capabilities\.json\z}, evidence.fetch("artifact"))
      assert_equal "#/", evidence.fetch("pointer")
      assert_match(/\A[0-9a-f]{64}\z/, evidence.fetch("sha256"))
    end
  end

  def test_native_capability_report_rejects_unknown_hosts_without_generic_fallback
    assert_raises(PromptEngineer::Capabilities::UnknownHostError) do
      PromptEngineer::Capabilities.for("gemini")
    end
  end

  def test_unsupported_native_adapters_fail_closed_before_reading_export_bytes
    %w[codex claude].each do |host|
      adapter = PromptEngineer::Normalizers.for(host)
      assert_equal host, adapter.host
      error = assert_raises(PromptEngineer::Normalizers::UnsupportedError) do
        adapter.normalize(-> { raise "export must not be read" })
      end
      assert_includes error.message, host
      assert_includes error.message, "unsupported"
    end
  end

  def test_native_normalizer_registry_rejects_unknown_hosts
    assert_raises(PromptEngineer::Capabilities::UnknownHostError) do
      PromptEngineer::Normalizers.for("gemini")
    end
  end

  def test_canonical_json_is_sorted_utf8_compact_and_has_one_trailing_lf
    bytes = PromptEngineer::Canonical.json(
      "b" => [true, nil, "é"],
      "a" => {"z" => 1, "a" => 2}
    )

    assert_equal "{\"a\":{\"a\":2,\"z\":1},\"b\":[true,null,\"é\"]}\n".encode("UTF-8"), bytes
    assert_equal Encoding::UTF_8, bytes.encoding
    assert_equal 1, bytes[/\n+\z/].length
    assert_equal Digest::SHA256.hexdigest(bytes), PromptEngineer::Canonical.digest(
      "b" => [true, nil, "é"], "a" => {"z" => 1, "a" => 2}
    )
  end

  def test_yaml_parser_rejects_ast_unsafe_constructs_before_construction
    unsafe = {
      "alias" => "a: &anchor\n  value: 1\nb: *anchor\n",
      "duplicate" => "a: 1\na: 2\n",
      "non_string_key" => "1: one\n",
      "tag" => "a: !ruby/object:Object {}\n",
      "merge" => "base: &base\n  a: 1\nvalue:\n  <<: *base\n"
    }

    unsafe.each do |_name, yaml|
      assert_contract_error PromptEngineer::Contracts::YamlError do
        PromptEngineer::Contracts.parse_yaml(yaml)
      end
    end
  end

  def test_non_string_mapping_keys_are_rejected_during_ast_walk
    error = assert_raises(PromptEngineer::Contracts::YamlError) do
      PromptEngineer::Contracts.parse_yaml("1: one\n")
    end
    assert_includes error.message, "AST"
  end

  def test_explicitly_tagged_scalar_mapping_keys_are_rejected_during_ast_walk
    error = assert_raises(PromptEngineer::Contracts::YamlError) do
      PromptEngineer::Contracts.parse_yaml("!!int \"1\": value\n")
    end
    assert_includes error.message, "AST"
  end

  def test_yaml_parser_returns_only_safe_plain_values
    value = PromptEngineer::Contracts.parse_yaml("name: prompt\nitems:\n  - one\n")
    assert_equal({"name" => "prompt", "items" => ["one"]}, value)
    refute value.frozen?
  end

  def test_yaml_parser_rejects_multiple_documents_before_construction
    assert_contract_error PromptEngineer::Contracts::YamlError, "document" do
      PromptEngineer::Contracts.parse_yaml("one: 1\n---\ntwo: 2\n")
    end
  end

  def test_yaml_parser_rejects_nonfinite_yaml_scalars
    %w[.nan .inf -.inf 1.0e+9999 .1e+9999].each do |scalar|
      assert_contract_error PromptEngineer::Contracts::YamlError, "finite" do
        PromptEngineer::Contracts.parse_yaml("value: #{scalar}\n")
      end
    end
    assert_contract_error PromptEngineer::Contracts::YamlError do
      PromptEngineer::Contracts.parse_yaml("value: !!float \"1e9999\"\n")
    end
  end

  def test_schema_validator_is_closed_and_supports_required_enum_const_patterns_and_bounds
    schema = {
      "type" => "object",
      "required" => ["kind", "name"],
      "additionalProperties" => false,
      "properties" => {
        "kind" => {"type" => "string", "enum" => ["case"]},
        "name" => {"type" => "string", "const" => "PE-001", "pattern" => "\\APE-[0-9]{3}\\z", "minLength" => 6, "maxLength" => 6},
        "count" => {"type" => "integer", "minimum" => 1, "maximum" => 3}
      }
    }

    assert PromptEngineer::Contracts.validate!(
      {"kind" => "case", "name" => "PE-001", "count" => 2}, schema
    )
    assert_contract_error PromptEngineer::Contracts::ValidationError, "required" do
      PromptEngineer::Contracts.validate!({"kind" => "case"}, schema)
    end
    assert_contract_error PromptEngineer::Contracts::ValidationError, "additionalProperties" do
      PromptEngineer::Contracts.validate!({"kind" => "case", "name" => "PE-001", "extra" => true}, schema)
    end
    assert_contract_error PromptEngineer::Contracts::ValidationError, "enum" do
      PromptEngineer::Contracts.validate!({"kind" => "other", "name" => "PE-001"}, schema)
    end
    pattern_schema = {"type" => "string", "pattern" => "\\APE-[0-9]{3}\\z"}
    assert_contract_error PromptEngineer::Contracts::ValidationError, "pattern" do
      PromptEngineer::Contracts.validate!("PX-001", pattern_schema)
    end
    assert_contract_error PromptEngineer::Contracts::ValidationError, "minimum" do
      PromptEngineer::Contracts.validate!({"kind" => "case", "name" => "PE-001", "count" => 0}, schema)
    end

    numeric_schema = {"type" => "number", "minimum" => 0}
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |number|
      assert_contract_error PromptEngineer::Contracts::ValidationError, "finite" do
        PromptEngineer::Contracts.validate!(number, numeric_schema)
      end
    end
  end

  def test_schema_validator_rejects_unknown_schema_keywords
    schema = {"type" => "string", "notAKeyword" => true}
    assert_contract_error PromptEngineer::Contracts::SchemaError, "notAKeyword" do
      PromptEngineer::Contracts.validate!("value", schema)
    end
  end

  def test_committed_closed_schemas_and_policy_example_are_parseable
    schema_paths = Dir[File.join(FIXTURES, "schemas", "*.yml")].sort
    assert_equal 6, schema_paths.length
    schema_paths.each do |path|
      schema = PromptEngineer::Contracts.load_schema(path)
      assert_equal true, PromptEngineer::Contracts.validate_schema!(schema)
    end
    policy = PromptEngineer::Contracts.load_yaml(fixture("qualification-policy.example.yml"))
    schema = PromptEngineer::Contracts.load_schema(fixture("schemas/qualification-policy-v1.yml"))
    assert PromptEngineer::Contracts.validate!(policy, schema)
  end

  def test_executor_and_judge_schemas_bind_freshness_provenance_and_rubric_packets
    executor = PromptEngineer::Contracts.load_schema(fixture("schemas/executor-result-v1.yml"))
    %w[
      repeat_index public_task_packet_digest arm_environment_manifest_digest
      expected_package_digest masked_label_map_digest sandbox_launch_attestation_digest
      fresh_session_evidence timestamps cli model effort configuration_digest
      environment_digest tool_inventory tool_events final_status exit_status
      raw_export_digest
    ].each do |field|
      assert_includes executor.fetch("required"), field
    end
    assert_equal false, executor.fetch("properties").fetch("timestamps").fetch("additionalProperties")
    assert_equal %w[started_at ended_at], executor.fetch("properties").fetch("timestamps").fetch("required")

    judge = PromptEngineer::Contracts.load_schema(fixture("schemas/judge-result-v1.yml"))
    %w[
      run_id session fresh_session_evidence timestamps model effort
      configuration_digest environment_digest tool_inventory masked_packet_digest
      tool_events private_rubric_digest output_labels rubric_dimensions uncertainty
      exit_status raw_export_digest
    ].each do |field|
      assert_includes judge.fetch("required"), field
    end
    dimensions = judge.fetch("properties").fetch("rubric_dimensions")
    assert_equal "array", dimensions.fetch("type")
    assert_includes dimensions.fetch("items").fetch("required"), "dimension"
    assert_includes dimensions.fetch("items").fetch("required"), "score"
    assert_includes dimensions.fetch("items").fetch("required"), "point_results"
    point = dimensions.fetch("items").fetch("properties").fetch("point_results").fetch("items")
    assert_includes point.fetch("required"), "status"
    assert_equal %w[pass fail uncertain], point.fetch("properties").fetch("status").fetch("enum")
    assert_includes point.fetch("required"), "citation_required"
    assert_equal 1, dimensions.fetch("items").fetch("properties").fetch("point_results").fetch("minItems")
    assert_includes point.fetch("required"), "citation"
    assert_equal %w[string null], point.fetch("properties").fetch("citation").fetch("type")
    assert_includes point.fetch("required"), "uncertainty"
    uncertainty = point.fetch("properties").fetch("uncertainty")
    assert_equal %w[none material], uncertainty.fetch("properties").fetch("classification").fetch("enum")
    assert_includes uncertainty.fetch("required"), "reason"
    assert_equal false, judge.fetch("properties").fetch("timestamps").fetch("additionalProperties")
    assert_equal PromptEngineer::Corpus::SCORING_MAXIMA.keys.sort, judge.fetch("properties").fetch("scores").fetch("required").sort
  end

  def test_judge_point_citations_are_conditional_and_required_failures_need_evidence
    judge = PromptEngineer::Contracts.load_schema(fixture("schemas/judge-result-v1.yml"))
    point = judge.fetch("properties").fetch("rubric_dimensions").fetch("items").fetch("properties").fetch("point_results").fetch("items")
    base = {
      "point_id" => "point-1",
      "weight" => 1,
      "status" => "fail",
      "citation_required" => true,
      "citation" => nil,
      "uncertainty" => {"classification" => "none", "reason" => "not uncertain"}
    }

    assert_contract_error PromptEngineer::Contracts::ValidationError, "type" do
      PromptEngineer::Contracts.validate!(base, point)
    end
    allowed_missing = base.merge("citation_required" => false)
    assert PromptEngineer::Contracts.validate!(allowed_missing, point)
    assert_contract_error PromptEngineer::Contracts::ValidationError, "minLength" do
      PromptEngineer::Contracts.validate!(base.merge("citation" => ""), point)
    end
  end

  def test_executor_schema_requires_nonce_and_machine_bound_activation_invocation_evidence
    executor = PromptEngineer::Contracts.load_schema(fixture("schemas/executor-result-v1.yml"))
    %w[nonce activation_evidence invocation_evidence].each do |field|
      assert_includes executor.fetch("required"), field
    end
    %w[activation_evidence invocation_evidence].each do |field|
      evidence = executor.fetch("properties").fetch(field)
      assert_equal false, evidence.fetch("additionalProperties")
      %w[event_ordinal staged_path machine_id machine_binding_digest evidence_digest].each do |required|
        assert_includes evidence.fetch("required"), required
      end
    end
    assert_equal %q[\A[0-9a-f]{64}\z], executor.fetch("properties").fetch("nonce").fetch("pattern")
    %w[binding binding_digest].each do |field|
      assert_includes executor.fetch("properties").fetch("activation_evidence").fetch("required"), field
      assert_includes executor.fetch("properties").fetch("invocation_evidence").fetch("required"), field
    end
    binding = executor.fetch("properties").fetch("activation_evidence").fetch("properties").fetch("binding")
    assert_equal %w[arm case_id host launch_attestation_digest machine_id nonce public_task_packet_digest raw_export_digest run_id session_id staged_package_digest staged_path], binding.fetch("required").sort
  end

  def test_judge_results_bind_all_five_declared_dimensions_points_weights_and_evidence
    assert_respond_to PromptEngineer::Contracts, :validate_judge_result!
    rubric = {
      "rubric_points" => PromptEngineer::Corpus::SCORING_MAXIMA.keys.each_with_object({}) do |dimension, points|
        points[dimension] = {"point-#{dimension}" => PromptEngineer::Corpus::SCORING_MAXIMA.fetch(dimension)}
      end
    }
    result = semantic_judge_result(rubric)
    assert PromptEngineer::Contracts.validate_judge_result!(result, rubric)

    missing_dimension = Marshal.load(Marshal.dump(result))
    missing_dimension.fetch("rubric_dimensions").pop
    assert_contract_error PromptEngineer::Contracts::ValidationError, "dimensions" do
      PromptEngineer::Contracts.validate_judge_result!(missing_dimension, rubric)
    end

    undeclared_point = Marshal.load(Marshal.dump(result))
    undeclared_point.fetch("rubric_dimensions").first.fetch("point_results").first["point_id"] = "not-declared"
    assert_contract_error PromptEngineer::Contracts::ValidationError, "point" do
      PromptEngineer::Contracts.validate_judge_result!(undeclared_point, rubric)
    end

    wrong_weight = Marshal.load(Marshal.dump(result))
    wrong_weight.fetch("rubric_dimensions").first.fetch("point_results").first["weight"] = 0
    assert_contract_error PromptEngineer::Contracts::ValidationError, "weight" do
      PromptEngineer::Contracts.validate_judge_result!(wrong_weight, rubric)
    end

    failed_without_evidence = Marshal.load(Marshal.dump(result))
    point = failed_without_evidence.fetch("rubric_dimensions").first.fetch("point_results").first
    point["status"] = "fail"
    point["citation_required"] = false
    point["citation"] = nil
    assert_contract_error PromptEngineer::Contracts::ValidationError, "citation" do
      PromptEngineer::Contracts.validate_judge_result!(failed_without_evidence, rubric)
    end
  end

  def test_executor_binding_digest_covers_run_session_arm_nonce_and_package
    assert_respond_to PromptEngineer::Contracts, :validate_executor_binding!
    facts = executor_facts
    result = executor_result_bound_to(facts)
    assert PromptEngineer::Contracts.validate_executor_binding!(result, facts)

    tampered = Marshal.load(Marshal.dump(result))
    tampered.fetch("activation_evidence").fetch("binding")["run_id"] = "other-run"
    assert_contract_error PromptEngineer::Contracts::ValidationError, "binding" do
      PromptEngineer::Contracts.validate_executor_binding!(tampered, facts)
    end

    tampered_session = Marshal.load(Marshal.dump(result))
    tampered_session.fetch("session")["id"] = "other-session"
    assert_contract_error PromptEngineer::Contracts::ValidationError, "session" do
      PromptEngineer::Contracts.validate_executor_binding!(tampered_session, facts)
    end
  end

  def test_executor_result_contract_binds_time_events_tokens_and_policy_caps
    assert_respond_to PromptEngineer::Contracts, :validate_executor_result!
    facts = executor_facts
    result = executor_result_bound_to(facts)
    assert PromptEngineer::Contracts.validate_executor_result!(result, facts, token_cap: 5)

    unordered = Marshal.load(Marshal.dump(result))
    unordered.fetch("tool_events").first["ordinal"] = 0
    assert_contract_error PromptEngineer::Contracts::ValidationError, "ordinal" do
      PromptEngineer::Contracts.validate_executor_result!(unordered, facts, token_cap: 5)
    end

    reversed = Marshal.load(Marshal.dump(result))
    reversed.fetch("timestamps")["ended_at"] = "2026-01-01T00:00:00Z"
    assert_contract_error PromptEngineer::Contracts::ValidationError, "timestamp" do
      PromptEngineer::Contracts.validate_executor_result!(reversed, facts, token_cap: 5)
    end

    mismatched_total = Marshal.load(Marshal.dump(result))
    mismatched_total.fetch("usage")["total_tokens"] = 99
    assert_contract_error PromptEngineer::Contracts::ValidationError, "total_tokens" do
      PromptEngineer::Contracts.validate_executor_result!(mismatched_total, facts, token_cap: 5)
    end

    over_cap = Marshal.load(Marshal.dump(result))
    over_cap.fetch("usage")["input_tokens"] = 5
    over_cap.fetch("usage")["output_tokens"] = 1
    over_cap.fetch("usage")["total_tokens"] = 6
    assert_contract_error PromptEngineer::Contracts::ValidationError, "token cap" do
      PromptEngineer::Contracts.validate_executor_result!(over_cap, facts, token_cap: 5)
    end
  end

  def test_corpus_freezes_cases_triggers_tree_digest_and_activation_pair
    corpus = PromptEngineer::Corpus.load(CORPUS)

    assert_equal (1..12).map { |number| format("PE-%03d", number) }, corpus.case_ids
    assert_equal %w[PE-001 PE-002 PE-003 PE-005 PE-006 PE-007 PE-008 PE-010], corpus.efficiency_case_ids
    assert_equal %w[codex claude], corpus.required_hosts
    assert_equal 8, corpus.triggers.fetch("positive").length
    assert_equal 8, corpus.triggers.fetch("negative").length
    assert_equal 12, corpus.cases.length
    assert_equal 16, corpus.trigger_records.length
    assert_equal 40, PromptEngineer::Budget::TRIGGER_RUNS
    assert_equal independent_manifest_binding_digest(CORPUS), corpus.tree_digest
    assert_equal independent_manifest_binding_digest(CORPUS), corpus.manifest_digest
    assert_equal corpus.manifest.fetch("tree_digest"), corpus.tree_digest

    explicit, implicit = corpus.activation_pair
    refute_equal explicit, implicit
    assert_equal true, implicit.fetch("policy").fetch("allow_implicit_invocation")
    assert_equal false, explicit.fetch("policy").fetch("allow_implicit_invocation")
    assert_equal({}, PromptEngineer::Corpus.activation_diff(explicit, implicit).reject { |path, _| path == ["policy", "allow_implicit_invocation"] })
  end

  def test_corpus_snapshots_and_returned_cases_are_defensive_copies
    corpus = PromptEngineer::Corpus.load(CORPUS)
    manifest = corpus.manifest
    manifest.fetch("case_ids").clear
    assert_equal 12, corpus.manifest.fetch("case_ids").length

    cases = corpus.cases
    cases.clear
    assert_equal 12, corpus.cases.length

    public_case = corpus.public_case("PE-001")
    public_case.fetch("title").replace("tampered")
    refute_equal "tampered", corpus.public_case("PE-001").fetch("title")

    private_rubric = corpus.private_rubric("PE-001")
    private_rubric.fetch("prohibited_behaviors").clear
    refute_empty corpus.private_rubric("PE-001").fetch("prohibited_behaviors")
  end

  def test_manifest_scoring_ranges_and_zero_tolerance_ids_are_frozen_after_rebinding
    {
      "scoring_ranges" => {"task_success" => [0, 99]},
      "zero_tolerance_ids" => ["invented_gate"]
    }.each do |field, value|
      with_fixture_tree do |root|
        manifest = PromptEngineer::Contracts.parse_yaml(File.binread(File.join(root, "manifest.yml")))
        manifest[field] = value
        write_yaml_with_recomputed_digest(root, "manifest.yml", manifest)
        assert_contract_error PromptEngineer::Corpus::Error, field do
          PromptEngineer::Corpus.load(root)
        end
      end
    end
  end

  def test_trigger_prompts_are_nonempty_closed_strings_after_rebinding
    {"" => "prompt", 123 => "prompt"}.each do |value, field|
      with_fixture_tree do |root|
        triggers_path = File.join(root, "triggers.yml")
        triggers = PromptEngineer::Contracts.parse_yaml(File.binread(triggers_path))
        triggers.fetch("positive").first["prompt"] = value
        write_yaml_with_recomputed_digest(root, "triggers.yml", triggers)
        assert_contract_error PromptEngineer::Corpus::Error, field do
          PromptEngineer::Corpus.load(root)
        end
      end
    end
  end

  def test_manifest_tree_digest_binds_raw_formatting_comments_and_quote_bytes
    with_fixture_tree do |root|
      manifest_path = File.join(root, "manifest.yml")
      original = File.binread(manifest_path)
      baseline = PromptEngineer::Corpus.tree_digest(root)
      variants = {
        "quote" => original.sub('tree_digest: "', "tree_digest: '").sub("\"\n", "'\n"),
        "format" => original.sub("schema_version: 1\n", "schema_version: 1  \n"),
        "comment" => original.sub("tree_digest: \"", "# binding comment\ntree_digest: \"")
      }

      variants.each do |name, variant|
        File.binwrite(manifest_path, variant)
        variant_digest = PromptEngineer::Corpus.tree_digest(root)
        refute_equal baseline, variant_digest, "#{name} bytes must affect the digest"

        File.binwrite(manifest_path, manifest_with_digest(variant, variant_digest))
        corpus = PromptEngineer::Corpus.load(root)
        assert_equal variant_digest, corpus.tree_digest, "#{name} variant must load with its bound digest"
        File.binwrite(manifest_path, original)
      end
    end
  end

  def test_all_declared_case_artifacts_are_tracked
    PromptEngineer::Corpus::CASE_IDS.each do |case_id|
      relative = "test/fixtures/prompt-engineer/v1/cases/#{case_id}/artifacts/input.txt"
      assert File.file?(File.join(REPO, relative)), "missing artifact #{relative}"
      _out, _err, status = Open3.capture3("git", "-C", REPO, "ls-files", "--error-unmatch", relative)
      assert status.success?, "artifact is not tracked: #{relative}"
    end
  end

  def test_artifact_parent_symlinks_are_rejected
    with_fixture_tree do |root|
      case_root = File.join(root, "cases", "PE-001")
      real_artifacts = File.join(case_root, "real-artifacts")
      FileUtils.mv(File.join(case_root, "artifacts"), real_artifacts)
      File.symlink("real-artifacts", File.join(case_root, "artifacts"))
      assert_contract_error PromptEngineer::Corpus::Error, "symlink" do
        PromptEngineer::Corpus.load(root, verify_digest: false)
      end
    end
  end

  def test_corpus_root_symlink_is_rejected
    with_fixture_tree do |root|
      symlink = root + "-symlink"
      File.symlink(root, symlink)
      assert_contract_error PromptEngineer::Corpus::Error, "symlink" do
        PromptEngineer::Corpus.load(symlink)
      end
    ensure
      FileUtils.rm_f(symlink) if symlink
    end
  end

  def test_corpus_root_with_symlinked_ancestor_is_rejected
    with_fixture_tree do |root|
      container = Dir.mktmpdir("prompt-engineer-root-parent")
      link = File.join(container, "link")
      File.symlink(File.dirname(root), link)
      supplied = File.join(link, File.basename(root))
      assert_contract_error PromptEngineer::Corpus::Error, "symlink" do
        PromptEngineer::Corpus.load(supplied)
      end
      FileUtils.rm_f(link)
      FileUtils.rm_rf(container)
    end
  end

  def test_corpus_read_fails_closed_when_path_swaps_to_a_symlink_before_open
    Dir.mktmpdir("prompt-engineer-toctou") do |root|
      victim = File.join(root, "victim.txt")
      secret = File.join(root, "secret.txt")
      File.write(victim, "safe")
      File.write(secret, "private rubric")
      original_open = PromptEngineer::Corpus.method(:open_descriptor_nofollow)
      swapped = false
      PromptEngineer::Corpus.define_singleton_method(:open_descriptor_nofollow) do |path, root|
        if path == victim && !swapped
          FileUtils.rm(victim)
          File.symlink(secret, victim)
          swapped = true
        end
        original_open.call(path, root)
      end
      begin
        assert_contract_error PromptEngineer::Corpus::Error, "symlink" do
          PromptEngineer::Corpus.stable_file_bytes(victim)
        end
      ensure
        PromptEngineer::Corpus.define_singleton_method(:open_descriptor_nofollow, original_open)
      end
    end
  end

  def test_descriptor_relative_reads_reject_path_traversal
    Dir.mktmpdir("prompt-engineer-relative-path") do |root|
      path = File.join(root, "safe.txt")
      File.write(path, "safe")
      assert_contract_error PromptEngineer::Corpus::Error, "path escape" do
        PromptEngineer::Corpus.stable_file_bytes(File.join(root, "..", File.basename(root), "safe.txt"), root)
      end
      assert_contract_error PromptEngineer::Corpus::Error, "path escape" do
        PromptEngineer::Corpus.digest_paths(root, ["../safe.txt"])
      end
    end
  end

  def test_corpus_yaml_reads_use_stable_descriptor_reader
    with_fixture_tree do |root|
      original_load = PromptEngineer::Contracts.method(:load_yaml)
      PromptEngineer::Contracts.define_singleton_method(:load_yaml) do |path|
        raise "path-based corpus YAML read" if path.start_with?(root)

        original_load.call(path)
      end
      begin
        corpus = PromptEngineer::Corpus.load(root)
        corpus.activation_pair
      ensure
        PromptEngineer::Contracts.define_singleton_method(:load_yaml, original_load)
      end
    end
  end

  def test_corpus_digest_rejects_ancestor_directory_swap
    with_fixture_tree do |root|
      artifacts = File.join(root, "cases", "PE-001", "artifacts")
      real_artifacts = File.join(root, "cases", "PE-001", "real-artifacts")
      original_snapshot = PromptEngineer::Corpus.method(:tree_identity_snapshot)
      swapped = false
      PromptEngineer::Corpus.define_singleton_method(:tree_identity_snapshot) do |path|
        snapshot = original_snapshot.call(path)
        unless swapped
          FileUtils.mv(artifacts, real_artifacts)
          File.symlink("real-artifacts", artifacts)
          swapped = true
        end
        snapshot
      end
      begin
        assert_contract_error PromptEngineer::Corpus::Error, "symlink" do
          PromptEngineer::Corpus.tree_digest(root)
        end
      ensure
        PromptEngineer::Corpus.define_singleton_method(:tree_identity_snapshot, original_snapshot)
      end
    end
  end

  def test_corpus_stable_read_rejects_same_metadata_different_content
    Dir.mktmpdir("prompt-engineer-content-race") do |root|
      path = File.join(root, "victim.txt")
      File.write(path, "safe")
      stat = File.stat(path)
      reads = 0
      fake = Object.new
      fake.define_singleton_method(:stat) { stat }
      fake.define_singleton_method(:read) do
        reads += 1
        reads == 1 ? "safe" : "evil"
      end
      fake.define_singleton_method(:rewind) {}
      fake.define_singleton_method(:close) {}
      original_open = PromptEngineer::Corpus.method(:open_descriptor_nofollow)
      PromptEngineer::Corpus.define_singleton_method(:open_descriptor_nofollow) { |_path, _root| fake }
      begin
        assert_contract_error PromptEngineer::Corpus::Error, "content" do
          PromptEngineer::Corpus.stable_file_bytes(path)
        end
      ensure
        PromptEngineer::Corpus.define_singleton_method(:open_descriptor_nofollow, original_open)
      end
    end
  end

  def test_corpus_digest_and_artifact_containment_fail_closed
    with_fixture_tree do |root|
      File.open(File.join(root, "cases", "PE-001", "artifacts", "input.txt"), "a") { |file| file.write("tamper") }
      assert_contract_error PromptEngineer::Corpus::Error, "digest" do
        PromptEngineer::Corpus.load(root)
      end
    end

    with_fixture_tree do |root|
      public_path = File.join(root, "cases", "PE-001", "public.yml")
      File.open(public_path, "a") { |file| file.write("\ninput_artifact_paths:\n  - ../../outside\n") }
      assert_contract_error PromptEngineer::Corpus::Error, "artifact" do
        PromptEngineer::Corpus.load(root, verify_digest: false)
      end
    end
  end

  def test_pinned_legacy_lock_rejects_unpinned_or_drifting_trees
    lock = PromptEngineer::Corpus.load_legacy_lock(fixture("legacy.lock.yml"))
    assert_equal "e16d537c594b0f29a368726aa11bb4e5d704938f", lock.fetch("commit")
    assert_equal "blocked", lock.fetch("status")
    assert_equal({"status" => "blocked", "reason" => "PROMPT_ENGINEER_LEGACY_ROOT was unavailable", "paths" => []}, lock.fetch("dependency_closure"))
    assert_equal({"status" => "absent", "files" => [], "object_ids" => [], "aggregate_digest" => nil}, lock.fetch("evidence"))
    assert_contract_error PromptEngineer::Corpus::LegacyLockError, "unpinned" do
      PromptEngineer::Corpus.verify_legacy_lock(lock, Dir.mktmpdir("unpinned-legacy"))
    end

    Dir.mktmpdir("legacy-lock") do |root|
      path = File.join(root, "skills", "prompt-engineer", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "fixture")
      initialize_git_repository(root)
      commit = git_head(root)
      valid = PromptEngineer::Corpus.lock_for_tree(
        "fixture://legacy", commit, {"skills/prompt-engineer/SKILL.md" => path}
      )
      assert_equal "skills/scripts/skills/prompt_engineer", valid.fetch("legacy_path")
      assert_equal "skills/scripts/skills/lib", valid.fetch("companion_path")
      assert_equal valid.fetch("evidence").fetch("files").map { |entry| entry.fetch("path") },
                   valid.fetch("dependency_closure").fetch("paths")
      refute valid.fetch("evidence").fetch("files").first.key?("source_path")
      assert PromptEngineer::Corpus.verify_legacy_lock(valid, root)
      system("git", "-C", root, "remote", "add", "origin", "git@github.com:solatis/claude-config.git")
      github_lock = PromptEngineer::Corpus.lock_for_tree(
        "solatis/claude-config", commit, {"skills/prompt-engineer/SKILL.md" => path}
      )
      assert PromptEngineer::Corpus.verify_legacy_lock(github_lock, root)
      File.write(File.join(root, "extra.txt"), "extra")
      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "extra" do
        PromptEngineer::Corpus.verify_legacy_lock(valid, root)
      end
      FileUtils.rm(File.join(root, "extra.txt"))
      File.write(path, "drift")
      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "digest" do
        PromptEngineer::Corpus.verify_legacy_lock(valid, root)
      end
    end
  end

  def test_pinned_legacy_lock_binds_files_to_commit_tree_and_avoids_hash_object_toctou
    Dir.mktmpdir("legacy-commit-tree") do |root|
      path = File.join(root, "skills", "prompt-engineer", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "committed")
      initialize_git_repository(root)
      commit = git_head(root)

      File.write(path, "working tree drift")
      drifted = PromptEngineer::Corpus.lock_for_tree(
        "fixture://legacy", commit, {"skills/prompt-engineer/SKILL.md" => path}
      )
      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "commit tree" do
        PromptEngineer::Corpus.verify_legacy_lock(drifted, root)
      end

      File.write(path, "committed")
      valid = PromptEngineer::Corpus.lock_for_tree(
        "fixture://legacy", commit, {"skills/prompt-engineer/SKILL.md" => path}
      )
      original = PromptEngineer::Corpus.method(:git_object_id)
      PromptEngineer::Corpus.define_singleton_method(:git_object_id) { |_path, _root = nil| raise "hash-object path" }
      begin
        assert PromptEngineer::Corpus.verify_legacy_lock(valid, root)
      ensure
        PromptEngineer::Corpus.define_singleton_method(:git_object_id, original)
      end
    end
  end

  def test_legacy_closure_rejects_hidden_extra_and_symlinked_directory_entries
    Dir.mktmpdir("legacy-closure-shape") do |root|
      path = File.join(root, "skills", "prompt-engineer", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "fixture")
      initialize_git_repository(root)
      lock = PromptEngineer::Corpus.lock_for_tree(
        "fixture://legacy", git_head(root), {"skills/prompt-engineer/SKILL.md" => path}
      )

      hidden = Marshal.load(Marshal.dump(lock))
      hidden.fetch("dependency_closure").fetch("paths") << ".secret"
      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "hidden" do
        PromptEngineer::Corpus.verify_legacy_lock(hidden, root)
      end

      extra_dir = File.join(root, "extra-dir")
      FileUtils.mkdir_p(extra_dir)
      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "extra" do
        PromptEngineer::Corpus.verify_legacy_lock(lock, root)
      end
      FileUtils.rm_rf(extra_dir)

      real_dir = File.join(root, "real-dir")
      FileUtils.mkdir_p(real_dir)
      File.symlink("real-dir", File.join(root, "linked-dir"))
      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "symlink" do
        PromptEngineer::Corpus.verify_legacy_lock(lock, root)
      end
    end
  end

  def test_legacy_identity_rejects_symlinked_git_directory
    Dir.mktmpdir("symlinked-git") do |root|
      path = File.join(root, "skills", "prompt-engineer", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "fixture")
      initialize_git_repository(root)
      commit = git_head(root)
      lock = PromptEngineer::Corpus.lock_for_tree(
        "fixture://legacy", commit, {"skills/prompt-engineer/SKILL.md" => path}
      )
      real_git = File.join(root, ".git-real")
      FileUtils.mv(File.join(root, ".git"), real_git)
      File.symlink(".git-real", File.join(root, ".git"))

      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "symlinked" do
        PromptEngineer::Corpus.verify_legacy_lock(lock, root)
      end
    end
  end

  def test_legacy_object_id_evidence_is_closed_and_matches_file_records
    Dir.mktmpdir("object-id-lock") do |root|
      path = File.join(root, "skills", "prompt-engineer", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "fixture")
      initialize_git_repository(root)
      lock = PromptEngineer::Corpus.lock_for_tree(
        "fixture://legacy", git_head(root), {"skills/prompt-engineer/SKILL.md" => path}
      )

      extra = Marshal.load(Marshal.dump(lock))
      extra.fetch("evidence").fetch("object_ids").first["extra"] = true
      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "object IDs" do
        PromptEngineer::Corpus.verify_legacy_lock(extra, root)
      end

      mismatch = Marshal.load(Marshal.dump(lock))
      mismatch.fetch("evidence").fetch("object_ids").first["object_id"] = "0" * 40
      mismatch.fetch("evidence")["aggregate_digest"] = PromptEngineer::Corpus.send(:lock_digest, mismatch)
      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "object ID" do
        PromptEngineer::Corpus.verify_legacy_lock(mismatch, root)
      end
    end
  end

  def test_case_payloads_are_closed_and_validated_after_digest_recomputation
    malformed = {
      "public:allowed_tools" => ["write"],
      "public:time_budget" => {"seconds" => 0},
      "private:rubric_points" => {"task_success" => 99},
      "private:prohibited_behaviors" => [123],
      "private:zero_tolerance_gates" => ["unknown_gate"],
      "private:judge_instructions" => ""
    }

    malformed.each do |field, value|
      with_fixture_tree do |root|
        scope, name = field.split(":")
        relative = "cases/PE-001/#{scope == "public" ? "public.yml" : "private.yml"}"
        path = File.join(root, relative)
        payload = PromptEngineer::Contracts.parse_yaml(File.binread(path))
        payload.fetch(name)
        payload[name] = value
        File.binwrite(path, Psych.dump(payload))
        digest = PromptEngineer::Corpus.tree_digest(root)
        manifest_path = File.join(root, "manifest.yml")
        File.binwrite(manifest_path, manifest_with_digest(File.binread(manifest_path), digest))

        assert_contract_error PromptEngineer::Corpus::Error, name do
          PromptEngineer::Corpus.load(root)
        end
      end
    end
  end

  def test_fixed_budget_arithmetic_and_positive_operator_ceiling
    budget = PromptEngineer::Budget.new(
      money_limit: 50.0,
      prices: {"codex:gpt-test" => {"input" => 1.0, "output" => 2.0}},
      session_timeout_seconds: 60
    )

    assert_equal 96, PromptEngineer::Budget::BEHAVIORAL_RUNS
    assert_equal 72, PromptEngineer::Budget::INITIAL_BEHAVIORAL_RUNS
    assert_equal 18, PromptEngineer::Budget::STABILITY_BEHAVIORAL_RUNS
    assert_equal 6, PromptEngineer::Budget::TARGETED_BEHAVIORAL_RUNS
    assert_equal 64, PromptEngineer::Budget::MAX_JUDGE_RUNS
    assert_equal 28.0, budget.reserve_cost("codex:gpt-test", {"input" => 10, "output" => 9})
    lease = budget.reserve!("codex:gpt-test", {"input" => 10, "output" => 9})
    assert_raises(FrozenError) { lease.status = :settled }
    assert_equal :reserved, budget.lease(lease.id).status
    assert_equal 95, budget.remaining(:behavioral)
    assert_equal :reserved, lease.status
    budget.settle!(lease.id, {"input" => 1, "output" => 2})
    assert_equal :settled, budget.lease(lease.id).status
    assert_equal 5.0, budget.spent
    assert_contract_error PromptEngineer::Budget::Error, "usage" do
      budget.settle!(lease.id, nil)
    end
    assert_contract_error PromptEngineer::Budget::Error, "price" do
      budget.reserve_cost("unknown:model", {"input" => 1, "output" => 1})
    end
  end

  def test_lease_snapshot_deep_freezes_mutable_fields_without_aliasing_settlement_model
    model = +"mutable:model"
    budget = PromptEngineer::Budget.new(
      money_limit: 50.0,
      prices: {"mutable:model" => {"input" => 1.0, "output" => 2.0}},
      session_timeout_seconds: 60
    )

    lease = budget.reserve!(model, {"input" => 10, "output" => 9})
    assert lease.model.frozen?
    refute_same model, lease.model

    model.replace("unpriced:model")
    settled = budget.settle!(lease.id, {"input" => 1, "output" => 2})
    assert_equal :settled, settled.status
    assert_equal 5.0, budget.spent
  end

  def test_budget_ceilings_are_fixed_and_independent
    assert_contract_error PromptEngineer::Budget::Error, "fixed" do
      PromptEngineer::Budget.new(money_limit: 10, prices: {}, max_sessions: 1)
    end
    budget = PromptEngineer::Budget.new(money_limit: 10, prices: {})
    assert_equal 96, budget.remaining(:behavioral)
    assert_equal 40, budget.remaining(:trigger)
    assert_equal 64, budget.remaining(:judge)
    assert_equal 8 * 60 * 60, budget.remaining_time
  end

  def test_closed_policy_and_discovery_schemas_bind_boundary_evidence
    policy = PromptEngineer::Contracts.load_schema(fixture("schemas/qualification-policy-v1.yml"))
    assert_includes policy.fetch("required"), "capability_evidence_digests"
    assert_includes policy.fetch("required"), "executable"
    assert_includes policy.fetch("required"), "argv_templates"
    assert_includes policy.fetch("required"), "allowlists"
    assert_includes policy.fetch("required"), "endpoint_policy"
    assert_includes policy.fetch("required"), "timeout_seconds"
    assert_includes policy.fetch("required"), "token_caps"
    pricing = policy.fetch("properties").fetch("pricing_authority").fetch("items")
    %w[effective_from effective_to input output cache reasoning minimum_charge failed_request_charge token_cap provider_cap_evidence].each do |field|
      assert_includes pricing.fetch("required"), field
    end
    inventory = PromptEngineer::Contracts.load_schema(fixture("schemas/discovery-inventory-v1.yml"))
    %w[legacy_variants companion_dependency_map source_evidence_digest].each do |field|
      assert_includes inventory.fetch("required"), field
    end
    roots = PromptEngineer::Contracts.load_schema(fixture("schemas/discovery-roots-v1.yml"))
    %w[expected_owner expected_mode expected_device expected_inode].each do |field|
      assert_includes roots.fetch("properties").fetch("roots").fetch("items").fetch("required"), field
    end
  end

  def test_budget_refuses_nonpositive_or_oversubscribed_limits
    assert_contract_error PromptEngineer::Budget::Error, "money" do
      PromptEngineer::Budget.new(money_limit: 0, prices: {})
    end
    assert_contract_error PromptEngineer::Budget::Error, "timeout" do
      PromptEngineer::Budget.new(money_limit: 1, prices: {}, session_timeout_seconds: 0)
    end
    assert_contract_error PromptEngineer::Budget::Error, "money" do
      PromptEngineer::Budget.new(money_limit: 10**1000, prices: {})
    end
    assert_contract_error PromptEngineer::Budget::Error, "timeout" do
      PromptEngineer::Budget.new(money_limit: 1, prices: {}, session_timeout_seconds: 10**1000)
    end
  end

  def test_reservation_rejects_negative_timeout_and_settlement_usage_caps
    budget = PromptEngineer::Budget.new(
      money_limit: 50,
      prices: {"capped:model" => {"input_tokens" => 1.0, "output_tokens" => 1.0, "token_cap" => 4}},
      session_timeout_seconds: 60
    )
    assert_contract_error PromptEngineer::Budget::Error, "timeout" do
      budget.reserve!("capped:model", {"input_tokens" => 1, "output_tokens" => 1}, -1)
    end
    lease = budget.reserve!("capped:model", {"input_tokens" => 1, "output_tokens" => 1})
    assert_contract_error PromptEngineer::Budget::Error, "usage" do
      budget.settle!(lease.id, {})
    end
    assert_contract_error PromptEngineer::Budget::Error, "token" do
      budget.settle!(lease.id, {"input_tokens" => 3, "output_tokens" => 2})
    end
    total_budget = PromptEngineer::Budget.new(
      money_limit: 50,
      prices: {"total:model" => {"input_tokens" => 1.0, "output_tokens" => 1.0, "total_tokens" => 0.0, "token_cap" => 4}},
      session_timeout_seconds: 60
    )
    total_lease = total_budget.reserve!("total:model", {"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4})
    assert_equal :settled, total_budget.settle!(total_lease.id, {"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4}).status
    mismatch_lease = total_budget.reserve!("total:model", {"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4})
    assert_contract_error PromptEngineer::Budget::Error, "token" do
      total_budget.settle!(mismatch_lease.id, {"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 5})
    end
  end

  def test_budget_rejects_nonfinite_prices_usage_and_timeout_and_freezes_prices
    prices = {"model" => {"input" => 1.0, "output" => 1.0}}
    budget = PromptEngineer::Budget.new(money_limit: 10, prices: prices)
    prices.fetch("model")["input"] = 99.0
    assert_equal 2.0, budget.reserve_cost("model", {"input" => 1, "output" => 1})
    assert_contract_error PromptEngineer::Budget::Error, "price" do
      PromptEngineer::Budget.new(money_limit: 10, prices: {"model" => {"input" => Float::NAN}})
    end
    assert_contract_error PromptEngineer::Budget::Error, "price" do
      PromptEngineer::Budget.new(money_limit: 10, prices: {"model" => {"input" => Float::INFINITY}})
    end
    assert_contract_error PromptEngineer::Budget::Error, "timeout" do
      PromptEngineer::Budget.new(money_limit: 10, prices: {}, session_timeout_seconds: Float::INFINITY)
    end
    assert_contract_error PromptEngineer::Budget::Error, "usage" do
      budget.reserve_cost("model", {"input" => Float::INFINITY, "output" => 1})
    end
    assert_contract_error PromptEngineer::Budget::Error, "price" do
      PromptEngineer::Budget.new(money_limit: 10, prices: {"model" => {"input" => Complex(1, 0)}})
    end
    assert_contract_error PromptEngineer::Budget::Error, "usage" do
      budget.reserve_cost("model", {"input" => Complex(1, 0), "output" => 1})
    end
    assert_contract_error PromptEngineer::Budget::Error, "cost" do
      budget.reserve_cost("model", {"input" => 10**1000, "output" => 1})
    end
    assert_contract_error PromptEngineer::Budget::Error, "price" do
      PromptEngineer::Budget.new(money_limit: 10, prices: {"model" => {"input" => 10**1000}})
    end
    assert_contract_error PromptEngineer::Budget::Error, "token" do
      PromptEngineer::Budget.new(money_limit: 10, prices: {"model" => {:token_cap => Float::NAN}})
    end
    assert_contract_error PromptEngineer::Budget::Error, "token" do
      PromptEngineer::Budget.new(money_limit: 10, prices: {"model" => {:token_cap => -1}})
    end
    billable_budget = PromptEngineer::Budget.new(
      money_limit: 50,
      prices: {"billable:model" => {"input_tokens" => 1.0, "output_tokens" => 1.0, "cache_tokens" => 1.0, "reasoning_tokens" => 1.0, "token_cap" => 5}}
    )
    assert_contract_error PromptEngineer::Budget::Error, "token" do
      billable_budget.reserve_cost("billable:model", {"input_tokens" => 1, "output_tokens" => 1, "cache_tokens" => 2, "reasoning_tokens" => 2})
    end
    assert_contract_error PromptEngineer::Budget::Error, "timeout" do
      billable_budget.reserve!("billable:model", {"input_tokens" => 1, "output_tokens" => 1}, 10**1000)
    end
  end

  def test_pinned_lock_requires_git_identity
    Dir.mktmpdir("unpinned-legacy") do |root|
      path = File.join(root, "skills", "prompt-engineer", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "fixture")
      lock = PromptEngineer::Corpus.lock_for_tree(
        "fixture://legacy", "a" * 40, {"skills/prompt-engineer/SKILL.md" => path}
      )
      assert_contract_error PromptEngineer::Corpus::LegacyLockError, "repository identity" do
        PromptEngineer::Corpus.verify_legacy_lock(lock, root)
      end
    end
  end

  def test_run_preparation_seals_inputs_and_builds_isolated_public_private_layout
    with_prepared_store do |store, root|
      manifest = store.manifest

      assert_match(/\Arun-[0-9a-f-]{36}\z/, store.run_id)
      assert_equal PromptEngineer::Corpus.load(CORPUS).tree_digest, manifest.fetch("corpus_digest")
      assert_equal manifest.fetch("corpus_digest"), manifest.fetch("corpus_manifest_digest")
      assert_equal directory_digest(File.join(REPO, "skills/general/prompt-engineer")), manifest.fetch("package_digest")
      assert_equal PromptEngineer::Canonical.digest(PromptEngineer::Contracts.load_yaml(fixture("qualification-policy.example.yml"))), manifest.fetch("qualification_policy_digest")
      assert_equal PromptEngineer::Canonical.digest(PromptEngineer::Contracts.load_yaml(fixture("legacy.lock.yml"))), manifest.fetch("legacy_lock_digest")
      assert_equal %w[legacy replacement unassisted], manifest.fetch("arm_labels").keys
      manifest.fetch("arm_labels").each_value { |label| assert_match(/\Aarm-[0-9a-f]{24}\z/, label) }
      refute_equal manifest.fetch("arm_labels").fetch("legacy"), manifest.fetch("arm_labels").fetch("replacement")
      refute_includes manifest.fetch("arm_labels").values, "legacy"

      assert_equal 72, manifest.fetch("dag").fetch("initial_count")
      assert_equal 18, manifest.fetch("dag").fetch("stability_count")
      assert_equal 40, manifest.fetch("dag").fetch("trigger_count")
      assert_equal 0, manifest.fetch("dag").fetch("targeted_repeat_count")
      assert_equal 0, manifest.fetch("dag").fetch("second_judge_count")

      assert File.directory?(store.path("homes"))
      assert File.directory?(store.path("outputs"))
      assert File.directory?(store.path("scratch"))
      assert_equal 0o700, File.stat(store.path("homes")).mode & 0o777
      assert_equal 0o700, File.stat(store.path("outputs")).mode & 0o777
      assert_equal 0o700, File.stat(store.path("scratch")).mode & 0o777
      manifest.fetch("arm_labels").each_value do |label|
        PromptEngineer::Corpus::HOSTS.each do |host|
          assert File.directory?(store.path("homes", label, host))
          assert_equal 0o700, File.stat(store.path("homes", label, host)).mode & 0o777
        end
      end

      public_packet = store.public_packet("PE-001", "codex", "legacy")
      private_packet = store.private_packet("PE-001", "codex", "legacy")
      assert_equal "PE-001", public_packet.fetch("case").fetch("case_id")
      assert_equal manifest.fetch("arm_labels").fetch("legacy"), public_packet.fetch("arm_label")
      refute public_packet.key?("private")
      assert_equal "PE-001", private_packet.fetch("case_id")
      assert private_packet.fetch("rubric").key?("judge_instructions")
      refute_equal public_packet, private_packet

      assert_equal 0o600, File.stat(store.manifest_path).mode & 0o777
      assert_equal 0o600, File.stat(store.ledger_path).mode & 0o777
      assert_equal 130, store.pending_tasks.length
      assert_equal store.manifest_digest, Digest::SHA256.hexdigest(File.binread(store.manifest_path))
      assert_raises(FrozenError) { manifest.fetch("dag")["initial_count"] = 1 }
      refute_empty Dir[File.join(root, "packets", "public", "*.json")]
      refute_empty Dir[File.join(root, "packets", "private", "*.json")]
    end
  end

  def test_run_preparation_refuses_ambient_environment_and_existing_run_roots
    Dir.mktmpdir("prompt-engineer-run") do |parent|
      existing = File.join(parent, "existing")
      FileUtils.mkdir(existing)
      assert_contract_error PromptEngineer::RunStore::Error, "exists" do
        prepare_store(existing, environment: {"PATH" => "/bin", "UNDECLARED" => "secret"})
      end
      assert_empty Dir.children(existing)

      run_root = File.join(parent, "new")
      assert_contract_error PromptEngineer::RunStore::Error, "environment" do
        prepare_store(run_root, environment: {"PATH" => "/bin", "UNDECLARED" => "secret"})
      end
      refute File.exist?(run_root)
    end
  end

  def test_provenance_ingestion_binds_frozen_run_facts_and_copies_only_canonical_records
    with_prepared_store do |store, _root|
      task = store.claim_next!("test-worker")
      record = executor_record_for(store, task)
      raw_export = "native export bytes\n"
      record["raw_export_digest"] = Digest::SHA256.hexdigest(raw_export)

      assert PromptEngineer::Provenance.validate_executor_record!(record, store: store, task: task, raw_export: raw_export)
      digest = store.ingest_executor!(record, raw_export: raw_export)
      assert_match(/\A[0-9a-f]{64}\z/, digest)
      assert File.file?(store.path("records", "executor", "#{digest}.json"))
      assert_equal 1, store.ingested_records.length
      refute_equal raw_export, File.binread(store.path("records", "executor", "#{digest}.json"))
      assert_equal record, JSON.parse(File.binread(store.path("records", "executor", "#{digest}.json")))
    end
  end

  def test_provenance_rejects_tampered_frozen_inputs_duplicate_nonces_and_closed_runs
    with_prepared_store do |store, _root|
      task = store.claim_next!("test-worker")
      record = executor_record_for(store, task)
      raw_export = "native export bytes\n"
      record["raw_export_digest"] = Digest::SHA256.hexdigest(raw_export)
      store.ingest_executor!(record, raw_export: raw_export)

      duplicate = Marshal.load(Marshal.dump(record))
      assert_contract_error PromptEngineer::Provenance::Error, "nonce" do
        store.ingest_executor!(duplicate, raw_export: raw_export)
      end

      tampered = Marshal.load(Marshal.dump(record))
      tampered["activation_evidence"]["binding"]["nonce"] = "f" * 64
      assert_contract_error PromptEngineer::Provenance::Error, "binding" do
        PromptEngineer::Provenance.validate_executor_record!(tampered, store: store, task: task, raw_export: raw_export)
      end

      next_task = store.claim_next!("test-worker-2")
      store.close!("budget exhausted")
      closed_record = executor_record_for(store, next_task)
      assert_contract_error PromptEngineer::RunStore::Error, "closed" do
        store.ingest_executor!(closed_record, raw_export: raw_export)
      end
    end
  end

  private

  def with_prepared_store
    Dir.mktmpdir("prompt-engineer-run-parent") do |parent|
      root = File.join(parent, "run")
      store = prepare_store(root, environment: {"PATH" => "/usr/bin", "LANG" => "C"})
      yield store, root
    end
  end

  def prepare_store(root, environment:)
    PromptEngineer::RunStore.prepare(
      run_root: root,
      corpus: PromptEngineer::Corpus.load(CORPUS),
      package_root: File.join(REPO, "skills/general/prompt-engineer"),
      qualification_policy: fixture("qualification-policy.example.yml"),
      legacy_lock: fixture("legacy.lock.yml"),
      environment: environment
    )
  end

  def directory_digest(root)
    digest = Digest::SHA256.new
    Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }.map do |path|
      path.sub(%r{\A#{Regexp.escape(root)}/?}, "")
    end.sort_by(&:b).each do |relative|
      digest.update(relative.encode("UTF-8"))
      digest.update("\0")
      digest.update(File.binread(File.join(root, relative)))
      digest.update("\0")
    end
    digest.hexdigest
  end

  def executor_record_for(store, task)
    raw_export = "native export bytes\n"
    raw_digest = Digest::SHA256.hexdigest(raw_export)
    facts = {
      "run_id" => store.run_id, "case_id" => task.fetch("case_id"), "host" => task.fetch("host"),
      "session_id" => task.fetch("session_id"), "arm" => task.fetch("arm"), "nonce" => task.fetch("nonce"),
      "staged_package_digest" => task.fetch("staged_package_digest"), "machine_id" => "machine-test",
      "staged_path" => "/staged/#{task.fetch("id")}", "public_task_packet_digest" => task.fetch("public_task_packet_digest"),
      "raw_export_digest" => raw_digest, "launch_attestation_digest" => "a" * 64
    }
    evidence = lambda do |status|
      value = {"status" => status, "event_ordinal" => 1, "staged_path" => facts.fetch("staged_path"), "machine_id" => facts.fetch("machine_id"), "binding" => facts, "binding_digest" => PromptEngineer::Canonical.digest(facts), "machine_binding_digest" => PromptEngineer::Canonical.digest(facts)}
      value["evidence_digest"] = PromptEngineer::Canonical.digest(value)
      value
    end
    {
      "schema_version" => 1, "run_id" => facts.fetch("run_id"), "host" => facts.fetch("host"), "case_id" => facts.fetch("case_id"),
      "arm" => facts.fetch("arm"), "repeat_index" => task.fetch("repeat_index"), "nonce" => facts.fetch("nonce"),
      "public_task_packet_digest" => facts.fetch("public_task_packet_digest"), "arm_environment_manifest_digest" => "b" * 64,
      "expected_package_digest" => facts.fetch("staged_package_digest"), "masked_label_map_digest" => "c" * 64,
      "sandbox_launch_attestation_digest" => facts.fetch("launch_attestation_digest"), "activation_evidence" => evidence.call("activated"),
      "invocation_evidence" => evidence.call("invoked"), "session" => {"id" => facts.fetch("session_id"), "fresh" => true},
      "fresh_session_evidence" => {"new_session_marker" => "fresh", "parent_session_absent" => true, "first_event_ordinal" => 0},
      "timestamps" => {"started_at" => "2026-01-01T00:00:00Z", "ended_at" => "2026-01-01T00:00:01Z"},
      "cli" => {"name" => "fixture", "version" => "1", "executable_digest" => "d" * 64}, "model" => "fixture-model", "effort" => "high",
      "configuration_digest" => "e" * 64, "environment_digest" => "f" * 64, "tool_inventory" => ["read"],
      "messages" => [{"ordinal" => 0, "channel" => "assistant", "text" => "done"}], "tool_events" => [{"ordinal" => 1, "tool" => "read", "status" => "completed"}],
      "final_status" => "completed", "exit_status" => 0, "raw_export_digest" => raw_digest,
      "usage" => {"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
    }
  end

  def semantic_judge_result(rubric)
    dimensions = rubric.fetch("rubric_points").map do |dimension, points|
      weight = points.values.sum
      {
        "dimension" => dimension,
        "maximum" => weight,
        "score" => weight,
        "point_results" => points.map do |point_id, point_weight|
          {
            "point_id" => point_id,
            "weight" => point_weight,
            "status" => "pass",
            "citation_required" => false,
            "citation" => nil,
            "uncertainty" => {"classification" => "none", "reason" => "no material uncertainty"}
          }
        end
      }
    end
    {"rubric_dimensions" => dimensions}
  end

  def executor_facts
    {
      "run_id" => "run-1",
      "case_id" => "PE-001",
      "host" => "codex",
      "session_id" => "session-1",
      "arm" => "replacement",
      "nonce" => "a" * 64,
      "staged_package_digest" => "b" * 64,
      "machine_id" => "machine-1",
      "staged_path" => "/staged/replacement",
      "public_task_packet_digest" => "e" * 64,
      "raw_export_digest" => "c" * 64,
      "launch_attestation_digest" => "d" * 64
    }
  end

  def executor_result_bound_to(facts)
    evidence_for = lambda do |status|
      binding = facts.dup
      evidence = {
        "status" => status,
        "event_ordinal" => 1,
        "staged_path" => facts.fetch("staged_path"),
        "machine_id" => facts.fetch("machine_id"),
        "machine_binding_digest" => PromptEngineer::Canonical.digest(binding),
        "binding" => binding,
        "binding_digest" => PromptEngineer::Canonical.digest(binding)
      }
      evidence["evidence_digest"] = PromptEngineer::Canonical.digest(evidence)
      evidence
    end
    {
      "run_id" => facts.fetch("run_id"),
      "case_id" => facts.fetch("case_id"),
      "host" => facts.fetch("host"),
      "arm" => facts.fetch("arm"),
      "nonce" => facts.fetch("nonce"),
      "expected_package_digest" => facts.fetch("staged_package_digest"),
      "sandbox_launch_attestation_digest" => facts.fetch("launch_attestation_digest"),
      "public_task_packet_digest" => facts.fetch("public_task_packet_digest"),
      "raw_export_digest" => facts.fetch("raw_export_digest"),
      "session" => {"id" => facts.fetch("session_id")},
      "timestamps" => {"started_at" => "2026-01-01T00:00:00Z", "ended_at" => "2026-01-01T00:01:00Z"},
      "messages" => [{"ordinal" => 1, "channel" => "assistant", "text" => "done"}],
      "tool_events" => [{"ordinal" => 2, "tool" => "read", "status" => "completed"}],
      "usage" => {"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5},
      "activation_evidence" => evidence_for.call("activated"),
      "invocation_evidence" => evidence_for.call("invoked")
    }
  end

  def task8_public_case
    {
      "case_id" => "PE-001",
      "title" => "Fixture prompt task",
      "task" => "Improve the prompt while preserving the observable contract.",
      "prompt_context" => "single_prompt",
      "public_requirements" => ["preserve_requirements", "compare_baseline"],
      "input_artifact_paths" => ["/private/source/input.txt"],
      "required_host_configuration" => {"hosts" => %w[codex claude], "fresh_context" => true}
    }
  end

  def task8_rubric
    {
      "case_id" => "PE-001",
      "rubric_points" => {
        "task_success" => {"success" => 4},
        "requirement_preservation" => {"preserve" => 3},
        "diagnosis_correctness" => {"diagnosis" => 2},
        "evaluation_quality" => {"evidence" => 2},
        "minimality" => {"minimal" => 2}
      },
      "prohibited_behaviors" => ["invented_evidence"],
      "zero_tolerance_gates" => ["fabricated_evidence"],
      "judge_instructions" => "Score observable output only."
    }
  end

  def task8_packet
    PromptEngineer::Scoring.build_judge_packet(
      run_id: "run-task8",
      case_id: "PE-001",
      host: "codex",
      repeat_index: 0,
      seed: "fixed-seed",
      public_case: task8_public_case,
      rubric: task8_rubric,
      executor_records: %w[legacy replacement unassisted].map { |arm| executor_output_for(arm, text: "#{arm} output") }
    )
  end

  def executor_output_for(arm, text:, package_digest: "a" * 64)
    {
      "run_id" => "run-task8",
      "case_id" => "PE-001",
      "host" => "codex",
      "arm" => arm,
      "repeat_index" => 0,
      "expected_package_digest" => package_digest,
      "messages" => [{"ordinal" => 0, "channel" => "assistant", "text" => text}],
      "tool_events" => [{"ordinal" => 1, "tool" => "read", "status" => "completed"}],
      "final_status" => "completed",
      "timestamps" => {"started_at" => "2026-01-01T00:00:00Z", "ended_at" => "2026-01-01T00:00:03Z"},
      "usage" => {"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3},
      "visible_assistant_characters" => text.length,
      "final_answer_characters" => text.length,
      "model_turns" => 1,
      "unnecessary_mutation" => false
    }
  end

  def judge_result_for(packet, statuses:, overall_uncertainty: "none")
    dimensions = packet.rubric.fetch("rubric_points").map do |dimension, points|
      point_results = points.map do |point_id, weight|
        status = statuses.fetch(point_id, "pass")
        {
          "point_id" => point_id,
          "weight" => weight,
          "status" => status,
          "citation_required" => true,
          "citation" => status == "pass" ? "output:0" : "output:0 missing required behavior",
          "uncertainty" => {"classification" => status == "uncertain" ? "material" : "none", "reason" => status == "uncertain" ? "fixture ambiguity" : "not uncertain"}
        }
      end
      score = point_results.sum { |point| point.fetch("status") == "pass" ? point.fetch("weight") : 0 }
      {"dimension" => dimension, "maximum" => points.values.sum, "score" => score, "point_results" => point_results}
    end
    scores = dimensions.each_with_object({}) { |dimension, result| result[dimension.fetch("dimension")] = dimension.fetch("score") }
    {
      "schema_version" => 1,
      "packet_id" => packet.document.fetch("packet_id"),
      "run_id" => packet.document.fetch("run_id"),
      "decision" => "tie",
      "session" => {"id" => "judge-session", "fresh" => true},
      "fresh_session_evidence" => {"new_session_marker" => "new", "parent_session_absent" => true, "first_event_ordinal" => 0},
      "timestamps" => {"started_at" => "2026-01-01T00:00:00Z", "ended_at" => "2026-01-01T00:00:03Z"},
      "model" => "fixture-judge",
      "effort" => "high",
      "configuration_digest" => "b" * 64,
      "environment_digest" => "c" * 64,
      "tool_inventory" => ["read"],
      "tool_events" => [],
      "masked_packet_digest" => packet.packet_digest,
      "private_rubric_digest" => packet.private_rubric_digest,
      "output_labels" => packet.document.fetch("output_labels"),
      "rubric_dimensions" => dimensions,
      "scores" => scores,
      "citations" => [{"dimension" => "task_success", "evidence" => "output:0"}],
      "uncertainty" => {"classification" => overall_uncertainty, "reason" => overall_uncertainty == "material" ? "fixture ambiguity" : "not uncertain"},
      "exit_status" => 0,
      "raw_export_digest" => "d" * 64
    }
  end

  def task8_release_evidence
    comparisons = %w[codex claude].flat_map do |host|
      (1..12).map do |number|
        {
          "host" => host,
          "case_id" => format("PE-%03d", number),
          "status" => "comparable",
          "replacement" => {"task_success" => 4, "requirement_preservation" => 3, "diagnosis_correctness" => 2, "evaluation_quality" => 2, "minimality" => 2},
          "legacy" => {"task_success" => 3, "requirement_preservation" => 3, "diagnosis_correctness" => 2, "evaluation_quality" => 2, "minimality" => 2}
        }
      end
    end
    {
      "host_status" => {"codex" => "supported", "claude" => "supported"},
      "comparisons" => comparisons,
      "zero_tolerance_failures" => [],
      "efficiency" => {"codex" => {"replacement" => {"turns" => 1, "characters" => 10}, "legacy" => {"turns" => 2, "characters" => 20}}, "claude" => {"replacement" => {"turns" => 1, "characters" => 10}, "legacy" => {"turns" => 2, "characters" => 20}}},
      "explicit_triggers" => {"passed" => 16, "total" => 16},
      "implicit_triggers" => {"passed" => 8, "total" => 8},
      "negative_triggers" => {"unexpected_activation" => 0, "total" => 16},
      "inconclusives" => []
    }
  end

  def write_yaml_with_recomputed_digest(root, relative, payload)
    File.binwrite(File.join(root, relative), Psych.dump(payload))
    manifest_path = File.join(root, "manifest.yml")
    manifest = File.binread(manifest_path)
    File.binwrite(manifest_path, manifest_with_digest(manifest, PromptEngineer::Corpus.tree_digest(root)))
  end

  def independent_tree_digest(root)
    digest = Digest::SHA256.new
    Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }.map do |path|
      path.sub(%r{\A#{Regexp.escape(root)}/?}, "")
    end.sort_by(&:b).each do |relative|
      digest.update(relative.encode("UTF-8"))
      digest.update("\0")
      digest.update(File.binread(File.join(root, relative)))
      digest.update("\0")
    end
    digest.hexdigest
  end

  def independent_manifest_binding_digest(root)
    digest = Digest::SHA256.new
    paths = Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }.map do |path|
      path.sub(%r{\A#{Regexp.escape(root)}/?}, "")
    end.sort_by(&:b)
    paths.each do |relative|
      bytes = File.binread(File.join(root, relative))
      if relative == "manifest.yml"
        bytes = manifest_with_digest(bytes, "0" * 64)
      end
      digest.update(relative.encode("UTF-8"))
      digest.update("\0")
      digest.update(bytes)
      digest.update("\0")
    end
    digest.hexdigest
  end

  def manifest_with_digest(bytes, digest)
    pattern = /(?<prefix>^[ \t]*tree_digest[ \t]*:[ \t]*)(?<quote>["']?)[0-9a-f]{64}\k<quote>(?=[ \t]*(?:#.*)?(?:\r?\n|\z))/m
    replaced = bytes.sub(pattern) do
      match = Regexp.last_match
      "#{match[:prefix]}#{match[:quote]}#{digest}#{match[:quote]}"
    end
    raise "manifest tree_digest declaration not found" if replaced == bytes

    replaced
  end

  def initialize_git_repository(root)
    system("git", "-C", root, "init", "--quiet")
    system("git", "-C", root, "config", "user.name", "Fixture User")
    system("git", "-C", root, "config", "user.email", "fixture@example.invalid")
    system("git", "-C", root, "add", ".")
    system("git", "-C", root, "commit", "--quiet", "-m", "fixture")
  end

  def git_head(root)
    output, _error, status = Open3.capture3("git", "-C", root, "rev-parse", "HEAD")
    raise "git fixture failed" unless status.success?

    output.strip
  end
end
