require "json"
require "minitest/autorun"
require "digest"
require "open3"
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
    assert_equal false, judge.fetch("properties").fetch("timestamps").fetch("additionalProperties")
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

  def test_manifest_tree_digest_binding_ignores_yaml_quote_style
    with_fixture_tree do |root|
      manifest_path = File.join(root, "manifest.yml")
      bytes = File.binread(manifest_path)
      File.write(manifest_path, bytes.sub(/tree_digest: "([0-9a-f]{64})"/, "tree_digest: '\\1'"))
      corpus = PromptEngineer::Corpus.load(root)
      assert_equal corpus.manifest.fetch("tree_digest"), corpus.tree_digest
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
        manifest = PromptEngineer::Contracts.parse_yaml(bytes)
        manifest["tree_digest"] = "0" * 64
        bytes = PromptEngineer::Canonical.json(manifest)
      end
      digest.update(relative.encode("UTF-8"))
      digest.update("\0")
      digest.update(bytes)
      digest.update("\0")
    end
    digest.hexdigest
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
