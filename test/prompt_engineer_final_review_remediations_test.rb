require "digest"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "../scripts/lib/prompt_engineer"

class PromptEngineerFinalReviewRemediationsTest < Minitest::Test

  # PromptEngineer::Corpus requires descriptor-relative, no-follow reads and
  # raises without them. That is a hard requirement of the skill, not of these
  # tests, so on a host that lacks them there is nothing to assert.
  def setup
    return unless defined?(PromptEngineer::Corpus)

    unless PromptEngineer::Corpus::NOFOLLOW_FLAG && PromptEngineer::Corpus::OPENAT_FUNCTION
      skip "host lacks descriptor-relative no-follow reads"
    end
  end

  REPO = File.expand_path("..", __dir__)
  CORPUS = File.join(REPO, "test/fixtures/prompt-engineer/v1")
  POLICY = File.join(REPO, "test/fixtures/prompt-engineer/qualification-policy.example.yml")
  LEGACY_LOCK = File.join(REPO, "test/fixtures/prompt-engineer/legacy.lock.yml")
  PACKAGE = File.join(REPO, "skills/general/prompt-engineer")

  def test_hash_policy_is_rejected_even_when_it_has_a_valid_shape
    with_store_inputs do |inputs|
      policy = PromptEngineer::Contracts.load_yaml(POLICY)

      error = assert_raises(PromptEngineer::RunStore::Error) do
        PromptEngineer::RunStore.prepare(**inputs.merge(qualification_policy: policy))
      end

      assert_includes error.message, "schema path"
    end
  end

  def test_executor_ingestion_requires_raw_bytes_and_the_committed_result_shape
    with_store do |store|
      task = store.claim_next!("review-test")
      record, raw_export = executor_result_for(store, task)

      assert_raises(PromptEngineer::RunStore::Error) do
        store.ingest_executor!(record)
      end

      reduced = record.reject { |key, _| key == "activation_evidence" }
      assert_raises(PromptEngineer::Provenance::Error) do
        store.ingest_executor!(reduced, raw_export: raw_export)
      end
    end
  end

  def test_open_rejects_manifest_ledger_and_record_drift
    with_store do |store|
      File.open(store.manifest_path, "ab") { |file| file.write(" ") }
      assert_raises(PromptEngineer::RunStore::Error) { PromptEngineer::RunStore.open(store.root) }
    end

    with_store do |store|
      File.open(store.ledger_path, "ab") { |file| file.write("{}\n") }
      assert_raises(PromptEngineer::RunStore::Error) { PromptEngineer::RunStore.open(store.root) }
    end

    with_store do |store|
      task = store.claim_next!("review-test")
      record, raw_export = executor_result_for(store, task)
      digest = store.ingest_executor!(record, raw_export: raw_export)
      record_path = store.path("records", "executor", "#{digest}.json")
      File.open(record_path, "ab") { |file| file.write(" ") }

      assert_raises(PromptEngineer::RunStore::Error) { PromptEngineer::RunStore.open(store.root) }
    end
  end

  def test_score_and_report_require_a_closed_digest_bound_run
    with_store do |store|
      evidence = File.join(store.root, "evidence.json")
      File.write(evidence, JSON.generate(release_evidence))
      digest = Digest::SHA256.file(evidence).hexdigest

      _stdout, stderr, status = invoke("score", "--run-dir", store.root, "--evidence", evidence, "--evidence-digest", digest)
      assert_equal 3, status
      assert_equal "run_not_closed", JSON.parse(stderr).fetch("error").fetch("code")

      store.close!("qualification complete", evidence_digest: digest)
      stdout, stderr, status = invoke("score", "--run-dir", store.root, "--evidence", evidence, "--evidence-digest", digest)
      assert_equal 3, status
      assert_equal "evaluation_incomplete", JSON.parse(stderr).fetch("error").fetch("code")

      output = File.join(store.root, "report.md")
      stdout, stderr, status = invoke("report", "--run-dir", store.root, "--evidence", evidence, "--evidence-digest", digest, "--output", output)
      assert_equal 3, status
      assert_equal "evaluation_incomplete", JSON.parse(stderr).fetch("error").fetch("code")
      refute File.exist?(output)
    end
  end

  def test_trigger_tasks_use_an_explicit_implicit_arm_without_changing_behavioral_arms
    with_store do |store|
      triggers = store.pending_tasks.select { |task| task.fetch("kind") == "trigger" }

      assert_equal 40, triggers.length
      assert_equal 16, triggers.count { |task| task.fetch("arm") == "implicit" }
      assert_equal 24, triggers.count { |task| task.fetch("arm") == "unassisted" }
      refute triggers.any? { |task| %w[legacy replacement].include?(task.fetch("arm")) }
      assert_equal %w[legacy replacement unassisted], PromptEngineer::RunStore::ARMS
    end
  end

  def test_evaluation_complete_requires_exact_nodes_unique_nonces_and_no_pending_leases
    with_store do |store|
      base_tasks = store.pending_tasks
      complete_events = base_tasks.flat_map.with_index do |task, index|
        nonce = format("%064x", index + 1)
        [
          {"event" => "lease_created", "id" => task.fetch("id"), "nonce" => nonce},
          {"event" => "executor_ingested", "node_id" => task.fetch("id"), "nonce" => nonce}
        ]
      end

      assert stub_events(store, complete_events) { store.evaluation_complete? }

      too_few = complete_events.reject do |event|
        event["event"] == "executor_ingested" && event["node_id"] == base_tasks.last.fetch("id")
      end
      assert_equal 129, too_few.count { |event| event["event"] == "executor_ingested" }
      refute stub_events(store, too_few) { store.evaluation_complete? }

      duplicate_nonce = complete_events.map(&:dup)
      ingestions = duplicate_nonce.select { |event| event["event"] == "executor_ingested" }
      ingestions.last["nonce"] = ingestions.first.fetch("nonce")
      refute stub_events(store, duplicate_nonce) { store.evaluation_complete? }

      missing_node = complete_events.map(&:dup)
      ingestions = missing_node.select { |event| event["event"] == "executor_ingested" }
      ingestions.last["node_id"] = "node-not-in-base-dag"
      refute stub_events(store, missing_node) { store.evaluation_complete? }

      pending_lease = complete_events + [{"event" => "lease_created", "id" => base_tasks.first.fetch("id"), "nonce" => "e" * 64}]
      refute stub_events(store, pending_lease) { store.evaluation_complete? }
    end
  end

  private

  def with_store_inputs
    Dir.mktmpdir("prompt-engineer-final-review") do |parent|
      yield(
        run_root: File.join(parent, "run"),
        corpus: PromptEngineer::Corpus.load(CORPUS),
        package_root: PACKAGE,
        qualification_policy: POLICY,
        legacy_lock: LEGACY_LOCK,
        environment: {"PATH" => "/usr/bin", "LANG" => "C"}
      )
    end
  end

  def with_store
    with_store_inputs { |inputs| yield PromptEngineer::RunStore.prepare(**inputs) }
  end

  def invoke(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    status = PromptEngineer::CLI.run(argv, stdout: stdout, stderr: stderr)
    [stdout.string, stderr.string, status]
  end

  def executor_result_for(store, task)
    raw_export = "native export bytes\n"
    digest = Digest::SHA256.hexdigest(raw_export)
    facts = {
      "run_id" => store.run_id,
      "case_id" => task.fetch("case_id"),
      "host" => task.fetch("host"),
      "session_id" => task.fetch("session_id"),
      "arm" => task.fetch("arm"),
      "nonce" => task.fetch("nonce"),
      "staged_package_digest" => task.fetch("staged_package_digest"),
      "machine_id" => "machine-review",
      "staged_path" => "/staged/#{task.fetch("id")}",
      "public_task_packet_digest" => task.fetch("public_task_packet_digest"),
      "raw_export_digest" => digest,
      "launch_attestation_digest" => "a" * 64
    }
    evidence = lambda do |status|
      value = {
        "status" => status,
        "event_ordinal" => 1,
        "staged_path" => facts.fetch("staged_path"),
        "machine_id" => facts.fetch("machine_id"),
        "binding" => facts,
        "binding_digest" => PromptEngineer::Canonical.digest(facts),
        "machine_binding_digest" => PromptEngineer::Canonical.digest(facts)
      }
      value["evidence_digest"] = PromptEngineer::Canonical.digest(value)
      value
    end
    [
      {
        "schema_version" => 1,
        "run_id" => facts.fetch("run_id"),
        "host" => facts.fetch("host"),
        "case_id" => facts.fetch("case_id"),
        "arm" => facts.fetch("arm"),
        "repeat_index" => task.fetch("repeat_index"),
        "nonce" => facts.fetch("nonce"),
        "public_task_packet_digest" => facts.fetch("public_task_packet_digest"),
        "arm_environment_manifest_digest" => "b" * 64,
        "expected_package_digest" => facts.fetch("staged_package_digest"),
        "masked_label_map_digest" => "c" * 64,
        "sandbox_launch_attestation_digest" => facts.fetch("launch_attestation_digest"),
        "activation_evidence" => evidence.call("activated"),
        "invocation_evidence" => evidence.call("invoked"),
        "session" => {"id" => facts.fetch("session_id"), "fresh" => true},
        "fresh_session_evidence" => {"new_session_marker" => "fresh", "parent_session_absent" => true, "first_event_ordinal" => 0},
        "timestamps" => {"started_at" => "2026-01-01T00:00:00Z", "ended_at" => "2026-01-01T00:00:01Z"},
        "cli" => {"name" => "fixture", "version" => "1", "executable_digest" => "d" * 64},
        "model" => "fixture-model",
        "effort" => "high",
        "configuration_digest" => "e" * 64,
        "environment_digest" => "f" * 64,
        "tool_inventory" => ["read"],
        "messages" => [{"ordinal" => 0, "channel" => "assistant", "text" => "done"}],
        "tool_events" => [{"ordinal" => 1, "tool" => "read", "status" => "completed"}],
        "final_status" => "completed",
        "exit_status" => 0,
        "raw_export_digest" => digest,
        "usage" => {"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
      },
      raw_export
    ]
  end

  def stub_events(store, events)
    store.define_singleton_method(:read_events) { events }
    yield
  end

  def release_evidence
    comparisons = %w[codex claude].flat_map do |host|
      (1..12).map do |number|
        {
          "host" => host,
          "case_id" => format("PE-%03d", number),
          "status" => "comparable",
          "replacement" => score(4, 3, 2, 2, 2),
          "legacy" => score(3, 3, 2, 2, 2)
        }
      end
    end
    {
      "host_status" => {"codex" => "supported", "claude" => "supported"},
      "comparisons" => comparisons,
      "zero_tolerance_failures" => [],
      "efficiency" => {
        "codex" => {"replacement" => {"turns" => 1, "characters" => 10}, "legacy" => {"turns" => 2, "characters" => 20}},
        "claude" => {"replacement" => {"turns" => 1, "characters" => 10}, "legacy" => {"turns" => 2, "characters" => 20}}
      },
      "explicit_triggers" => {"passed" => 16, "total" => 16},
      "negative_triggers" => {"unexpected_activation" => 0, "total" => 16},
      "inconclusives" => []
    }
  end

  def score(*values)
    %w[task_success requirement_preservation diagnosis_correctness evaluation_quality minimality].zip(values).to_h
  end
end
