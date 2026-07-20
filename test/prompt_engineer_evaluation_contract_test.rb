require "json"
require "minitest/autorun"
require "digest"
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

  def test_yaml_parser_returns_only_safe_plain_values
    value = PromptEngineer::Contracts.parse_yaml("name: prompt\nitems:\n  - one\n")
    assert_equal({"name" => "prompt", "items" => ["one"]}, value)
    refute value.frozen?
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
    assert_equal corpus.tree_digest, PromptEngineer::Corpus.tree_digest(CORPUS)

    explicit, implicit = corpus.activation_pair
    refute_equal explicit, implicit
    assert_equal true, implicit.fetch("policy").fetch("allow_implicit_invocation")
    assert_equal false, explicit.fetch("policy").fetch("allow_implicit_invocation")
    assert_equal({}, PromptEngineer::Corpus.activation_diff(explicit, implicit).reject { |path, _| path == ["policy", "allow_implicit_invocation"] })
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
    assert_contract_error PromptEngineer::Corpus::LegacyLockError, "unpinned" do
      PromptEngineer::Corpus.verify_legacy_lock(lock, Dir.mktmpdir("unpinned-legacy"))
    end

    Dir.mktmpdir("legacy-lock") do |root|
      path = File.join(root, "skill.md")
      File.write(path, "fixture")
      valid = PromptEngineer::Corpus.lock_for_tree(
        "fixture://legacy", "a" * 40, {"skills/prompt-engineer/SKILL.md" => path}
      )
      assert PromptEngineer::Corpus.verify_legacy_lock(valid, root)
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
      session_timeout_seconds: 60,
      max_sessions: 2
    )

    assert_equal 96, PromptEngineer::Budget::BEHAVIORAL_RUNS
    assert_equal 72, PromptEngineer::Budget::INITIAL_BEHAVIORAL_RUNS
    assert_equal 18, PromptEngineer::Budget::STABILITY_BEHAVIORAL_RUNS
    assert_equal 6, PromptEngineer::Budget::TARGETED_BEHAVIORAL_RUNS
    assert_equal 64, PromptEngineer::Budget::MAX_JUDGE_RUNS
    assert_equal 28.0, budget.reserve_cost("codex:gpt-test", {"input" => 10, "output" => 9})
    lease = budget.reserve!("codex:gpt-test", {"input" => 10, "output" => 9})
    assert_equal 1, budget.remaining_sessions
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

  def test_budget_refuses_nonpositive_or_oversubscribed_limits
    assert_contract_error PromptEngineer::Budget::Error, "money" do
      PromptEngineer::Budget.new(money_limit: 0, prices: {})
    end
    assert_contract_error PromptEngineer::Budget::Error, "timeout" do
      PromptEngineer::Budget.new(money_limit: 1, prices: {}, session_timeout_seconds: 0)
    end
  end
end
