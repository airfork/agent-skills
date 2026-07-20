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

  private

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
