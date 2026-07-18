require "minitest/autorun"
require "json"
require "fileutils"
require "securerandom"
require "tmpdir"
require_relative "support/adversarial_review_helper"

SKILL = File.expand_path("../skills/general/adversarial-review", __dir__) unless defined?(SKILL)
$LOAD_PATH.unshift(File.join(SKILL, "scripts", "lib"))
require "adversarial_review"

class AdversarialReviewStateTest < Minitest::Test
  include AdversarialReviewHelper

  def test_atomic_writer_rejects_oversized_prospective_json_without_changing_destination
    Dir.mktmpdir("adversarial-review-size") do |directory|
      destination = File.join(directory, "state.json")
      AdversarialReview::Atomic.write_json(destination, {"stable" => true})
      before = File.binread(destination)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::Atomic.write_json(
          destination, {"payload" => "x" * AdversarialReview::Atomic::MAX_JSON_BYTES}
        )
      end

      assert_equal "json_too_large", error.code
      assert_equal before, File.binread(destination)
    end
  end

  def test_execution_policy_and_task_attestations_are_locked_and_persisted
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      built["selected_executor"] = "generic"
      built["jobs"] = 3
      built["report_path"] = File.join(repository, "spec-review.md")
      run_dir = File.join(repository, ".git", "execution-metadata")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      task = AdversarialReview::Prompts.attack_task(built, "tester", 1)
      state.create_task_bundle(task.fetch("task_id")) { task }
      capabilities = AdversarialReview::Capabilities.normalize(
        {}, requested_model: built.fetch("requested_model"),
        requested_effort: built.fetch("requested_effort")
      )

      state.record_task_execution(
        task.fetch("task_id"), authority: "reviewer", capabilities: capabilities,
        usage: {"prompt_bytes" => 20}, attempts: 1,
        runtime_provenance: {"adapter" => "generic"}
      )

      execution = AdversarialReview::State.load(run_dir).to_h.fetch("execution")
      assert_equal "generic", execution.fetch("selected_executor")
      assert_equal true, execution.fetch("executor_pinned")
      assert_empty execution.fetch("dispatch_attempts")
      assert_equal 3, execution.fetch("jobs")
      assert_equal built.fetch("report_path"), execution.fetch("report_path")
      record = execution.fetch("tasks").fetch(task.fetch("task_id"))
      assert_equal "reviewer", record.fetch("authority")
      assert_equal capabilities, record.fetch("capabilities")
      assert_equal 1, record.fetch("attempts")
      assert_raises(AdversarialReview::State::Error) do
        state.pin_executor!("claude")
      end
    end
  end

  def test_auto_executor_pins_once_and_persists_dispatch_attempt_evidence
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = AdversarialReview::Manifest.build(
        repository: repository, spec: "docs/spec.md", tier: "default", mode: "critique",
        output: "chat", executor: "auto", model: "reviewer-model", effort: "high"
      )
      built["selected_executor"] = "codex"
      state = AdversarialReview::State.create(File.join(repository, ".git", "auto-pin"), built)
      assert_equal false, state.to_h.dig("execution", "executor_pinned")
      task = AdversarialReview::Prompts.attack_task(built, "tester", 1)
      error = assert_raises(AdversarialReview::State::Error) do
        state.create_task_bundle(task.fetch("task_id")) { task }
      end
      assert_equal "executor_not_pinned", error.code
      assert_empty state.to_h.fetch("emitted_tasks")

      state.begin_selection_intent!(
        task_id: task.fetch("task_id"), requested_executor: "auto",
        candidate_executor: "codex", vendor: "codex", model: "reviewer-model",
        effort: "high", stage: "prepared"
      )
      intent = state.to_h.dig("execution", "selection_intent")
      assert_equal "active", intent.fetch("status")
      assert_equal 0, intent.fetch("external_attempts")
      state.create_task_bundle(task.fetch("task_id")) { task }
      state.mark_selection_call_started!(task.fetch("task_id"))
      assert_equal 1, state.to_h.dig("execution", "selection_intent", "external_attempts")
      state.finalize_selection_intent!(
        task_id: "attack-tester-r1-a1", executor: "codex", status: "fallback",
        error_code: "runtime_attestation_missing", phase: "preflight",
        content_sent: false, prompt_bytes: 100, selected_executor: "generic"
      )

      execution = state.to_h.fetch("execution")
      assert_equal "generic", execution.fetch("selected_executor")
      assert_equal true, execution.fetch("executor_pinned")
      assert_equal "terminal", execution.dig("selection_intent", "status")
      assert_equal "generic", execution.dig("selection_intent", "outcome_executor")
      assert_equal 1, execution.fetch("dispatch_attempts").length
      assert_equal false, execution.fetch("dispatch_attempts").first.fetch("content_sent")
      assert_raises(AdversarialReview::State::Error) { state.pin_executor!("codex") }
    end
  end

  def test_critique_completion_requires_ingested_judge_roster
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      manifest = build_ingest_manifest(repository).merge("mode" => "critique")
      state = AdversarialReview::State.create(
        File.join(repository, ".git", "critique-missing-judge"), manifest
      )
      state.transition_to("attacking")
      state.transition_to("deduplicating")
      state.transition_to("culling")

      error = assert_raises(AdversarialReview::State::Error) do
        state.transition_to("complete")
      end

      assert_equal "completion_blocked", error.code
      assert_includes error.details.fetch("blockers"), "judge-roster-incomplete"
    end
  end

  def test_refresh_after_parent_actions_binds_declared_paths_and_live_target_digest
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "digest-refresh")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      candidate = state.ingest_candidate("tester", 1, result_finding("Missing rollback owner"))
      advance(state, %w[deduplicating culling])
      state.promote([promotion_group("G-001", candidate.fetch("id"), "HIGH", 0.9,
                                     "docs/spec.md", 2)])
      state.transition_to("awaiting-author")
      finding_id = state.findings.first.fetch("id")
      state.record_author_action(
        finding_id,
        {"status" => "fixed", "rationale" => "Add owner", "changed_paths" => ["docs/spec.md"]}
      )
      File.write(File.join(repository, "docs/spec.md"), "# Product spec\nOwner: release manager\n")

      refreshed = state.refresh_targets_after_actions!

      assert_equal ["docs/spec.md"], refreshed.fetch("changed_targets")
      snapshot = state.to_h
      assert_equal 2, snapshot.fetch("target_digest_history").length
      refute_equal snapshot.fetch("target_digest_history").first,
                   snapshot.fetch("current_target_digests")
      assert_equal true, snapshot.fetch("fresh_sweep_required")
      assert_raises(AdversarialReview::State::Error) { state.refresh_targets_after_actions! }
    end
  end

  def test_refresh_after_rejection_only_actions_accepts_unchanged_targets_without_fresh_sweep
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "rejection-only-refresh")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      candidate = state.ingest_candidate("tester", 1, result_finding("Incorrect ownership concern"))
      advance(state, %w[deduplicating culling])
      state.promote([promotion_group("G-001", candidate.fetch("id"), "HIGH", 0.9,
                                     "docs/spec.md", 1)])
      state.transition_to("awaiting-author")
      state.record_author_action(
        state.findings.first.fetch("id"),
        {"status" => "rejected", "rationale" => "The concern is factually incorrect.",
         "changed_paths" => []}
      )

      refreshed = state.refresh_targets_after_actions!

      assert_empty refreshed.fetch("changed_targets")
      snapshot = state.to_h
      assert_equal 1, snapshot.fetch("target_digest_history").length
      assert_equal false, snapshot.fetch("fresh_sweep_required")
      assert_equal snapshot.fetch("target_digest_history").first,
                   snapshot.fetch("current_target_digests")
    end
  end

  def test_ingest_validates_schema_before_mutating_state_or_results
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      payload = attack_payload(task)
      payload.delete("checks_completed")
      state_before = File.binread(File.join(run_dir, "state.json"))

      error = assert_raises(AdversarialReview::State::InvalidResult) do
        state.ingest(task.fetch("task_id"), payload)
      end

      assert_equal 3, error.exit_status
      assert_includes error.details.fetch("errors").map { |entry| entry.fetch("code") }, "required"
      assert_equal state_before, File.binread(File.join(run_dir, "state.json"))
      assert_empty Dir.children(File.join(run_dir, "results"))
    end
  end

  def test_ingest_attack_allocates_ids_and_collapses_exact_duplicates_with_sources
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      duplicate = result_finding("Missing rollback owner")
      payload = attack_payload(task, [duplicate, duplicate.dup, result_finding("Missing timeout")])

      summary = state.ingest(task.fetch("task_id"), payload)

      assert_equal %w[C-tester-1-1 C-tester-1-2], summary.fetch("candidate_ids")
      assert_equal 1, summary.fetch("duplicate_mappings").length
      assert_equal "C-tester-1-1", summary.dig("duplicate_mappings", 0, "candidate_id")
      assert_equal 2, state.candidates.length
      assert_equal 2, state.to_h.dig("exact_duplicate_sources", "C-tester-1-1").length
      assert_equal payload, JSON.parse(File.read(File.join(run_dir, "results", "#{task.fetch("task_id")}.json")))
      assert_equal 0o600, File.stat(File.join(run_dir, "results", "#{task.fetch("task_id")}.json")).mode & 0o777
    end
  end

  def test_ingest_dedupe_requires_exact_coverage_and_persists_group_traceability
    candidate_findings = [result_finding("Missing rollback owner"), result_finding("Missing timeout")]
    with_ingest_state(
      stage: "deduplicating", schema: "dedupe", candidate_findings: candidate_findings
    ) do |state, run_dir, task|
      payload = base_result_payload(task).merge(
        "groups" => [{
          "group_id" => "G-recovery",
          "candidate_ids" => %w[C-tester-1-1 C-tester-1-2],
          "summary" => "Recovery controls are incomplete",
          "location" => result_finding("x").fetch("location"),
          "source_angles" => ["tester"]
        }]
      )

      summary = state.ingest(task.fetch("task_id"), payload)

      assert_equal ["G-recovery"], summary.fetch("group_ids")
      assert_equal %w[C-tester-1-1 C-tester-1-2],
                   state.to_h.dig("semantic_groups", "G-recovery", "candidate_ids")
      assert_equal ["G-recovery"], state.candidates.map { |candidate| candidate.fetch("group_id") }.uniq
      assert File.file?(File.join(run_dir, "results", "#{task.fetch("task_id")}.json"))
    end
  end

  def test_ingest_judge_applies_confidence_floor_refute_and_unproven_distinctly
    candidates = %w[promote refute unproven low-confidence].map { |name| result_finding(name) }
    with_ingest_state(stage: "culling", schema: "judge", candidate_findings: candidates) do |state, _run_dir, task|
      payload = base_result_payload(task).merge(
        "verdicts" => [
          judge_verdict("C-tester-1-1", "PROMOTE", 0.9),
          judge_verdict("C-tester-1-2", "REFUTE", 0.9, evidence: "The owner is named on line 8."),
          judge_verdict("C-tester-1-3", "UNPROVEN", 0.9),
          judge_verdict("C-tester-1-4", "PROMOTE", 0.69)
        ],
        "metrics" => {}
      )

      summary = state.ingest(task.fetch("task_id"), payload)

      assert_equal 1, summary.fetch("promoted_ids").length
      assert_equal %w[promoted refuted unproven unproven],
                   state.candidates.map { |candidate| candidate.fetch("state") }
      assert_equal 2, state.to_h.fetch("evidence_gaps").length
      assert_equal "Omission", state.findings.first.fetch("category")
      assert_equal "HIGH", state.findings.first.fetch("severity")
      assert_equal "Recovery can stall.", state.findings.first.fetch("consequence")
    end
  end

  def test_ingest_author_actions_and_resolution_preserve_disposition_evidence
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "adversarial-review-actions")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      candidate = state.ingest_candidate("tester", 1, result_finding("Missing rollback owner"))
      advance(state, %w[deduplicating culling])
      state.promote([promotion_group("G-001", candidate.fetch("id"), "HIGH", 0.9, "docs/spec.md", 2)])
      state.transition_to("awaiting-author")
      finding_id = state.findings.first.fetch("id")
      action_task = emit_result_task(state, "author-actions")
      action_payload = base_result_payload(action_task).merge(
        "actions" => [{
          "finding_id" => finding_id,
          "action" => "REJECTED",
          "rationale" => "The owner is assigned by policy.",
          "changed_paths" => ["docs/spec.md"]
        }]
      )

      state.ingest(action_task.fetch("task_id"), action_payload)

      assert_equal "rejected", state.to_h.dig("author_actions", finding_id, "status")
      assert_equal "The owner is assigned by policy.",
                   state.to_h.dig("author_actions", finding_id, "rationale")
      assert_equal "pending", state.findings.first.fetch("state")

      state.transition_to("resolving")
      resolution_task = emit_result_task(state, "resolution")
      resolution_payload = base_result_payload(resolution_task).merge(
        "checks" => [{
          "finding_id" => finding_id,
          "status" => "RESOLVED",
          "evidence" => "The policy reference is authoritative."
        }],
        "new_findings" => [],
        "metrics" => {}
      )

      state.ingest(resolution_task.fetch("task_id"), resolution_payload)

      assert_equal "rejected", state.findings.first.fetch("state")
      assert_equal "rejected", state.to_h.dig("resolution_checks", finding_id)
    end
  end

  def test_ultra_judge_records_two_promote_ballots_without_finalizing
    with_ultra_vote_sequence(%w[PROMOTE PROMOTE], expected_voters: 3) do |state, summary|
      assert_empty summary.fetch("promoted_ids")
      assert_equal "candidate", state.candidate("C-tester-1-1").fetch("state")
      assert_equal 2, state.to_h.dig("judge_votes", "C-tester-1-1").length
      assert_empty state.to_h.fetch("pending_arbiter_subjects")
    end
  end

  def test_ultra_judge_promotes_only_after_three_unanimous_independent_votes
    with_ultra_vote_sequence(%w[PROMOTE PROMOTE PROMOTE]) do |state, summary|
      assert_equal 1, summary.fetch("promoted_ids").length
      assert_equal "promoted", state.candidate("C-tester-1-1").fetch("state")
      assert_equal 3, state.to_h.dig("judge_votes", "C-tester-1-1").length
      assert_empty state.to_h.fetch("pending_arbiter_subjects")
    end
  end

  def test_ultra_judge_refutes_only_after_three_unanimous_independent_votes
    with_ultra_vote_sequence(%w[REFUTE REFUTE REFUTE]) do |state, summary|
      assert_equal ["C-tester-1-1"], summary.fetch("refuted_candidate_ids")
      assert_equal "refuted", state.candidate("C-tester-1-1").fetch("state")
      assert_empty state.to_h.fetch("pending_arbiter_subjects")
    end
  end

  def test_ultra_judge_split_ballot_requires_arbitration_after_all_three_votes
    with_ultra_vote_sequence(%w[PROMOTE PROMOTE REFUTE]) do |state, summary|
      assert_empty summary.fetch("promoted_ids")
      assert_equal ["C-tester-1-1"], state.to_h.fetch("pending_arbiter_subjects")
      assert_equal "candidate", state.candidate("C-tester-1-1").fetch("state")
    end
  end

  def test_ultra_judge_unproven_ballot_requires_arbitration_after_all_three_votes
    with_ultra_vote_sequence(%w[PROMOTE UNPROVEN PROMOTE]) do |state, summary|
      assert_empty summary.fetch("promoted_ids")
      assert_equal ["C-tester-1-1"], state.to_h.fetch("pending_arbiter_subjects")
      assert_equal "candidate", state.candidate("C-tester-1-1").fetch("state")
      assert_equal 1, state.to_h.fetch("evidence_gaps").length
    end
  end

  def test_ultra_judge_rejects_a_duplicate_voter_without_mutation
    with_ultra_duplicate_voter do |state, error, before|
      assert_equal "duplicate_voter", error.code
      assert_equal before, state.to_h
      assert_equal "candidate", state.candidate("C-tester-1-1").fetch("state")
    end
  end

  def test_ingest_arbiter_maps_author_resolution_decisions_deterministically
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "adversarial-review-arbiter")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      candidate = state.ingest_candidate("tester", 1, result_finding("Missing rollback owner"))
      advance(state, %w[deduplicating culling])
      state.promote([promotion_group("G-001", candidate.fetch("id"), "HIGH", 0.9, "docs/spec.md", 2)])
      state.transition_to("awaiting-author")
      finding_id = state.findings.first.fetch("id")
      state.record_author_action(
        finding_id,
        {"status" => "rejected", "rationale" => "Policy covers this", "changed_paths" => []}
      )
      state.transition_to("resolving")
      state.record_resolution(finding_id, "contested")
      state.set_pending_arbiter_subjects([finding_id])
      state.transition_to("arbitrating")
      arbiter_task = emit_result_task(
        state,
        "arbiter",
        "dispute_kind" => "author-resolution",
        "subject_ids" => [finding_id],
        "subject_mappings" => {finding_id => [candidate.fetch("id")]}
      )
      payload = base_result_payload(arbiter_task).merge(
        "decisions" => [{
          "subject_id" => finding_id,
          "decision" => "RESOLVED",
          "confidence" => 0.9,
          "evidence" => "The policy controls the disputed requirement.",
          "mapped_candidate_ids" => [candidate.fetch("id")]
        }],
        "metrics" => {}
      )

      state.ingest(arbiter_task.fetch("task_id"), payload)

      assert_equal "rejected", state.findings.first.fetch("state")
      assert_empty state.to_h.fetch("pending_arbiter_subjects")
    end
  end

  def test_author_resolution_arbiter_resolved_maps_fixed_action_to_resolved
    with_author_resolution_dispute("fixed") do |state, task, finding_id, candidate_id, _run_dir|
      payload = arbiter_payload(task, finding_id, candidate_id, "RESOLVED")

      state.ingest(task.fetch("task_id"), payload)

      assert_equal "resolved", state.findings.first.fetch("state")
      assert_equal "resolved", state.to_h.dig("resolution_checks", finding_id)
      assert_empty state.to_h.fetch("pending_arbiter_subjects")
    end
  end

  def test_author_resolution_arbiter_rejects_candidate_only_decisions_without_mutation
    with_author_resolution_dispute("rejected") do |state, task, finding_id, candidate_id, run_dir|
      %w[UNPROVEN PROMOTE REFUTE].each do |decision|
        state_before = File.binread(File.join(run_dir, "state.json"))
        results_before = Dir.children(File.join(run_dir, "results")).sort

        error = assert_raises(AdversarialReview::State::InvalidResult, decision) do
          state.ingest(
            task.fetch("task_id"),
            arbiter_payload(task, finding_id, candidate_id, decision)
          )
        end

        assert_equal "invalid_arbiter_decision", error.code, decision
        assert_equal state_before, File.binread(File.join(run_dir, "state.json")), decision
        assert_equal results_before, Dir.children(File.join(run_dir, "results")).sort, decision
      end
    end
  end

  def test_judge_conflict_inside_a_semantic_group_requires_arbitration
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "adversarial-review-group-conflict")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      2.times { |index| state.ingest_candidate("tester", 1, result_finding("candidate-#{index}")) }
      state.transition_to("deduplicating")
      dedupe_task = emit_result_task(state, "dedupe")
      dedupe_payload = base_result_payload(dedupe_task).merge(
        "groups" => [{
          "group_id" => "G-shared",
          "candidate_ids" => %w[C-tester-1-1 C-tester-1-2],
          "summary" => "Shared concern",
          "location" => result_finding("x").fetch("location"),
          "source_angles" => ["tester"]
        }]
      )
      state.ingest(dedupe_task.fetch("task_id"), dedupe_payload)
      state.transition_to("culling")
      judge_task = emit_result_task(state, "judge")
      judge_payload = base_result_payload(judge_task).merge(
        "verdicts" => [
          judge_verdict("C-tester-1-1", "PROMOTE", 0.9),
          judge_verdict("C-tester-1-2", "REFUTE", 0.9, evidence: "The owner is named on line 8.")
        ],
        "metrics" => {}
      )

      summary = state.ingest(judge_task.fetch("task_id"), judge_payload)

      assert_empty summary.fetch("promoted_ids")
      assert_equal ["G-shared"], state.to_h.fetch("pending_arbiter_subjects")
      assert_equal %w[candidate candidate], state.candidates.map { |candidate| candidate.fetch("state") }
    end
  end

  def test_judge_enforces_fifty_reported_findings_with_stable_overflow_records
    candidates = 51.times.map { |index| result_finding("candidate-#{index}") }
    with_ingest_state(stage: "culling", schema: "judge", candidate_findings: candidates) do |state, _run_dir, task|
      payload = base_result_payload(task).merge(
        "verdicts" => 51.times.map do |index|
          judge_verdict("C-tester-1-#{index + 1}", "PROMOTE", 0.9)
        end,
        "metrics" => {}
      )

      summary = state.ingest(task.fetch("task_id"), payload)

      assert_equal 50, summary.fetch("promoted_ids").length
      assert_equal 51, state.findings.length
      assert_equal 50, state.findings.count { |finding| finding.fetch("reported") }
      assert_equal 1, state.to_h.dig("overflow", "total")
      assert_equal 1, state.to_h.dig("overflow", "by_category_severity", "Omission:HIGH")
      assert_equal 1, state.to_h.dig("overflow", "items").length
      assert_equal 51, state.findings.last.fetch("id").split("-").last.to_i
      blocker = assert_completion_blocked(state)
      overflow_id = state.to_h.dig("overflow", "items").first
      assert_includes blocker.details.fetch("blockers"), "overflow-blocker:#{overflow_id}"
      gap_error = assert_raises(AdversarialReview::State::Error) do
        state.record_nonblocking_evidence_gap(overflow_id, "Reviewed but omitted from the report cap.")
      end
      assert_equal "invalid_overflow_evidence_gap", gap_error.code
    end
  end

  def test_medium_or_low_overflow_requires_a_recorded_nonblocking_evidence_gap
    with_state do |state, run_dir|
      state.transition_to("attacking")
      51.times { |index| state.ingest_candidate("tester", 1, finding("low-#{index}")) }
      advance(state, %w[deduplicating culling])
      groups = 51.times.map do |index|
        promotion_group(
          format("G-low-%02d", index), "C-tester-1-#{index + 1}",
          "LOW", 0.8, "docs/spec.md", index + 1
        )
      end
      state.promote(groups)
      snapshot = state.to_h
      overflow_id = snapshot.dig("overflow", "items").first
      reported_id = snapshot.fetch("findings").find { |finding| finding.fetch("reported") }.fetch("id")
      before_invalid = File.binread(File.join(run_dir, "state.json"))

      [
        ["AR-deadbeef-999", "Known rationale"],
        [reported_id, "Known rationale"],
        [overflow_id, "  "]
      ].each do |finding_id, rationale|
        assert_raises(AdversarialReview::State::Error) do
          state.record_nonblocking_evidence_gap(finding_id, rationale)
        end
        assert_equal before_invalid, File.binread(File.join(run_dir, "state.json"))
      end

      state.transition_to("awaiting-author")
      state.findings.select { |finding| finding.fetch("reported") }.each do |finding|
        state.record_author_action(finding.fetch("id"), "fixed")
      end
      state.transition_to("resolving")
      state.findings.select { |finding| finding.fetch("reported") }.each do |finding|
        state.record_resolution(finding.fetch("id"), "resolved")
      end
      blocked = assert_completion_blocked(state)
      assert_includes blocked.details.fetch("blockers"), "overflow-evidence-gap:#{overflow_id}"

      state.record_nonblocking_evidence_gap(overflow_id, "Reviewed and nonblocking at the report cap.")
      state.transition_to("complete")

      assert_equal "complete", state.to_h.fetch("stage")
      assert_equal "Reviewed and nonblocking at the report cap.",
                   state.to_h.dig("overflow_evidence_gaps", overflow_id, "rationale")
    end
  end

  def test_global_cap_later_high_displaces_low_without_changing_stable_ids
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "adversarial-review-global-cap")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      50.times { |index| state.ingest_candidate("tester", 1, result_finding("low-#{index}")) }
      advance(state, %w[deduplicating culling])
      low_groups = 50.times.map do |index|
        promotion_group(
          format("G-low-%02d", index), "C-tester-1-#{index + 1}",
          "LOW", 0.8, "docs/spec.md", index + 1
        ).merge("category" => "Omission", "consequence" => "Low consequence")
      end
      state.promote(low_groups)
      original_ids = state.findings.map { |finding| finding.fetch("id") }
      assert_equal 50, state.findings.count { |finding| finding.fetch("reported") }

      advance(state, %w[awaiting-author resolving fresh-sweep])
      state.ingest_candidate("tester", 1, result_finding("round-two blocker"))
      state.transition_to("culling-new-findings")
      task = emit_result_task(state, "judge")
      payload = base_result_payload(task).merge(
        "verdicts" => [judge_verdict("C-tester-1-51", "PROMOTE", 0.99).merge("severity" => "HIGH")],
        "metrics" => {}
      )

      summary = state.ingest(task.fetch("task_id"), payload)

      assert_equal 51, state.findings.length
      assert_equal original_ids, state.findings.first(50).map { |finding| finding.fetch("id") }
      assert_equal 50, state.findings.count { |finding| finding.fetch("reported") }
      high = state.findings.find { |finding| finding.fetch("severity") == "HIGH" }
      assert_equal true, high.fetch("reported")
      assert_equal [high.fetch("id")], summary.fetch("promoted_ids")
      assert_equal 1, summary.fetch("evicted_ids").length
      assert_equal summary.fetch("evicted_ids"), state.to_h.dig("overflow", "items")
      assert_equal 1, state.to_h.dig("overflow", "total")
    end
  end

  def test_global_reported_semantic_set_is_independent_of_promotion_batch_order
    low_then_high = reported_groups_for_batch_order(%i[low high])
    high_then_low = reported_groups_for_batch_order(%i[high low])

    assert_equal low_then_high, high_then_low
    assert_equal 50, low_then_high.length
    assert_equal 30, low_then_high.count { |group_id| group_id.start_with?("G-high-") }
  end

  def test_ingest_adopts_exact_orphan_then_rejects_exactly_once_duplicate_without_mutation
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      payload = attack_payload(task, [result_finding("Missing rollback owner")])
      result_path = File.join(run_dir, "results", "#{task.fetch("task_id")}.json")
      File.binwrite(result_path, JSON.generate(payload) + "\n")
      File.chmod(0o600, result_path)

      state.ingest(task.fetch("task_id"), payload)
      state_before = File.binread(File.join(run_dir, "state.json"))
      result_before = File.binread(result_path)

      error = assert_raises(AdversarialReview::State::InvalidResult) do
        state.ingest(task.fetch("task_id"), payload)
      end

      assert_equal "duplicate_result", error.code
      assert_equal state_before, File.binread(File.join(run_dir, "state.json"))
      assert_equal result_before, File.binread(result_path)
    end
  end

  def test_atomic_accept_result_rejects_semantic_failure_without_execution_then_links_digests
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      capabilities = AdversarialReview::Capabilities.normalize(
        {}, requested_model: "reviewer-model", requested_effort: "high"
      )
      before = File.binread(File.join(run_dir, "state.json"))
      assert_raises(AdversarialReview::State::InvalidResult) do
        state.accept_result(
          task.fetch("task_id"), {}, authority: "reviewer", capabilities: capabilities,
          usage: {"prompt_bytes" => 10}, attempts: 1,
          runtime_provenance: {"session_id" => "invalid"}
        )
      end
      assert_equal before, File.binread(File.join(run_dir, "state.json"))
      refute state.to_h.dig("execution", "tasks").key?(task.fetch("task_id"))

      state.accept_result(
        task.fetch("task_id"), attack_payload(task), authority: "reviewer",
        capabilities: capabilities, usage: {"prompt_bytes" => 10}, attempts: 1,
        runtime_provenance: {"session_id" => "fresh"}
      )
      snapshot = state.to_h
      record = snapshot.dig("execution", "tasks", task.fetch("task_id"))
      ingestion = snapshot.dig("ingested_results", task.fetch("task_id"))
      assert_equal ingestion.fetch("sha256"), record.fetch("result_sha256")
      assert_equal ingestion.fetch("task_sha256"), record.fetch("task_sha256")
    end
  end

  def test_post_rename_state_fsync_failure_preserves_consistent_state_and_result
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      payload = attack_payload(task, [result_finding("Missing rollback owner")])
      original = AdversarialReview::Atomic.method(:write_json_relative)
      writer = lambda do |directory, name, value, **options, &operation|
        result = original.call(directory, name, value, **options, &operation)
        if name == "state.json" && value.fetch("ingested_results", {}).key?(task.fetch("task_id"))
          raise IOError, "injected directory fsync failure after state rename"
        end
        result
      end

      error = AdversarialReview::Atomic.stub(:write_json_relative, writer) do
        assert_raises(AdversarialReview::State::Error) do
          state.ingest(task.fetch("task_id"), payload)
        end
      end

      assert_equal "durability_uncertain", error.code
      assert File.file?(File.join(run_dir, "results", "#{task.fetch("task_id")}.json"))
      loaded = AdversarialReview::State.load(run_dir)
      assert loaded.to_h.fetch("ingested_results").key?(task.fetch("task_id"))
      duplicate = assert_raises(AdversarialReview::State::InvalidResult) do
        loaded.ingest(task.fetch("task_id"), payload)
      end
      assert_equal "duplicate_result", duplicate.code
    end
  end

  def test_load_rejects_changed_ingested_result_bytes
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      state.ingest(task.fetch("task_id"), attack_payload(task))
      result_path = File.join(run_dir, "results", "#{task.fetch("task_id")}.json")
      File.binwrite(result_path, "{}\n")

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
    end
  end

  def test_refresh_rejects_changed_ingested_task_bytes
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      state.ingest(task.fetch("task_id"), attack_payload(task))
      task_path = File.join(run_dir, "tasks", "#{task.fetch("task_id")}.json")
      File.binwrite(task_path, JSON.generate(task.merge("attempt" => 2)) + "\n")

      error = assert_raises(AdversarialReview::State::Error) { state.to_h }

      assert_equal "invalid_state", error.code
    end
  end

  def test_mutation_rejects_changed_ingested_task_authentication
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      state.ingest(task.fetch("task_id"), attack_payload(task))
      auth_path = File.join(run_dir, "tasks", "#{task.fetch("task_id")}.auth.json")
      auth = JSON.parse(File.read(auth_path))
      auth["sha256"] = "0" * 64
      File.binwrite(auth_path, JSON.generate(auth) + "\n")
      state_before = File.binread(File.join(run_dir, "state.json"))

      error = assert_raises(AdversarialReview::State::Error) do
        state.transition_to("deduplicating")
      end

      assert_equal "invalid_state", error.code
      assert_equal state_before, File.binread(File.join(run_dir, "state.json"))
    end
  end

  def test_load_rejects_corrupted_ingestion_cross_references
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      state.ingest(task.fetch("task_id"), attack_payload(task, [result_finding("Missing owner")]))
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted.fetch("exact_duplicate_sources").values.first.first["task_id"] = "unknown-task"
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_load_rejects_corrupted_semantic_group_core_fields_and_exact_mapping
    corruptions = {
      "blank summary" => lambda { |state| state.dig("semantic_groups", "G-shared")["summary"] = " " },
      "invalid location" => lambda do |state|
        state.dig("semantic_groups", "G-shared", "location")["line_start"] = 9
        state.dig("semantic_groups", "G-shared", "location")["line_end"] = 2
      end,
      "zero location lines" => lambda do |state|
        state.dig("semantic_groups", "G-shared", "location")["line_start"] = 0
        state.dig("semantic_groups", "G-shared", "location")["line_end"] = 0
      end,
      "duplicate source angles" => lambda do |state|
        state.dig("semantic_groups", "G-shared")["source_angles"] = %w[tester tester]
      end,
      "missing candidate mapping" => lambda do |state|
        state.fetch("candidates").first.delete("group_id")
      end,
      "unknown group field" => lambda do |state|
        state.dig("semantic_groups", "G-shared")["surprise"] = true
      end
    }

    corruptions.each do |name, corrupt|
      with_semantic_group_state do |run_dir|
        persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
        corrupt.call(persisted)
        File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

        error = assert_raises(AdversarialReview::State::Error, name) do
          AdversarialReview::State.load(run_dir)
        end

        assert_equal "invalid_state", error.code, name
      end
    end
  end

  def test_emission_rejects_a_task_kind_schema_mismatch_without_mutation
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "adversarial-review-kind-mismatch")
      state = AdversarialReview::State.create(run_dir, built)
      angle = built.fetch("enabled_tasks").first
      canonical = AdversarialReview::Prompts.attack_task(built, angle, 1)
      task = canonical.merge("kind" => "judge")
      state_before = File.binread(File.join(run_dir, "state.json"))

      error = assert_raises(AdversarialReview::State::InvalidResult) do
        state.create_task_bundle(task.fetch("task_id")) { task }
      end

      assert_equal "invalid_task", error.code
      assert_equal state_before, File.binread(File.join(run_dir, "state.json"))
      assert_empty Dir.children(File.join(run_dir, "tasks"))
    end
  end

  def test_ingest_authenticates_exact_emitted_task_bytes_before_validation
    corruptions = {
      "attempt" => ->(task) { task["attempt"] = 99 },
      "kind" => ->(task) { task["kind"] = "judge" },
      "metadata" => ->(task) { task["surprise"] = true }
    }
    corruptions.each do |name, corrupt|
      with_ingest_state(stage: "attacking") do |state, run_dir, task|
        task_path = File.join(run_dir, "tasks", "#{task.fetch("task_id")}.json")
        changed = JSON.parse(File.read(task_path))
        corrupt.call(changed)
        File.write(task_path, JSON.generate(changed) + "\n")
        state_before = File.binread(File.join(run_dir, "state.json"))

        error = assert_raises(AdversarialReview::State::InvalidResult, name) do
          state.ingest(task.fetch("task_id"), attack_payload(task))
        end

        assert_equal "invalid_task", error.code, name
        assert_equal state_before, File.binread(File.join(run_dir, "state.json")), name
        assert_empty Dir.children(File.join(run_dir, "results")), name
      end
    end
  end

  def test_ingest_rejects_a_replaced_task_and_recomputed_sidecar_against_locked_state
    with_ingest_state(stage: "attacking") do |state, run_dir, task|
      task_id = task.fetch("task_id")
      task_path = File.join(run_dir, "tasks", "#{task_id}.json")
      auth_path = File.join(run_dir, "tasks", "#{task_id}.auth.json")
      forged = task.merge("tool_restrictions" => ["forged restriction"])
      forged_bytes = JSON.generate(forged) + "\n"
      forged_auth = {
        "schema_version" => 1,
        "task_id" => task_id,
        "sha256" => Digest::SHA256.hexdigest(forged_bytes)
      }
      File.binwrite(task_path, forged_bytes)
      File.binwrite(auth_path, JSON.generate(forged_auth) + "\n")
      state_before = File.binread(File.join(run_dir, "state.json"))

      error = assert_raises(AdversarialReview::State::InvalidResult) do
        state.ingest(task_id, attack_payload(forged))
      end

      assert_equal "invalid_task", error.code
      assert_equal state_before, File.binread(File.join(run_dir, "state.json"))
      assert_empty Dir.children(File.join(run_dir, "results"))
    end
  end

  def test_create_task_bundle_rejects_noncanonical_task_identity_before_publish
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      angle = built.fetch("enabled_tasks").first
      canonical = AdversarialReview::Prompts.attack_task(built, angle, 1)
      cases = [
        [canonical.fetch("task_id"), canonical.merge("attempt" => 2)],
        [canonical.fetch("task_id"), canonical.merge("angle" => "forged-angle")],
        ["attack-#{angle}-r1-a2", canonical]
      ]

      cases.each_with_index do |(requested_id, task), index|
        run_dir = File.join(repository, ".git", "adversarial-review-canonical-task-#{index}")
        state = AdversarialReview::State.create(run_dir, built)
        state_before = File.binread(File.join(run_dir, "state.json"))

        error = assert_raises(AdversarialReview::State::InvalidResult) do
          state.create_task_bundle(requested_id) { task }
        end

        assert_equal "invalid_task", error.code
        assert_equal state_before, File.binread(File.join(run_dir, "state.json"))
        assert_empty Dir.children(File.join(run_dir, "tasks"))
      end
    end
  end

  def test_resolution_new_findings_require_a_fresh_sweep_and_block_completion_when_promoted_high
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "adversarial-review-resolution-new")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      original = state.ingest_candidate("tester", 1, result_finding("Original concern"))
      advance(state, %w[deduplicating culling])
      state.promote([promotion_group("G-original", original.fetch("id"), "HIGH", 0.9, "docs/spec.md", 2)])
      state.transition_to("awaiting-author")
      finding_id = state.findings.first.fetch("id")
      state.record_author_action(finding_id, "fixed")
      state.transition_to("resolving")
      task = emit_result_task(state, "resolution", "allow_new_findings" => true)
      payload = base_result_payload(task).merge(
        "checks" => [{
          "finding_id" => finding_id,
          "status" => "RESOLVED",
          "evidence" => "The original concern was fixed."
        }],
        "new_findings" => [result_finding("Regression introduced by the fix")],
        "metrics" => {}
      )

      summary = state.ingest(task.fetch("task_id"), payload)

      assert_equal ["C-resolution-1-1"], summary.fetch("candidate_ids")
      assert_equal true, state.to_h.fetch("fresh_sweep_required")
      assert_completion_blocked(state)

      state.transition_to("fresh-sweep")
      state.transition_to("culling-new-findings")
      judge_task = emit_result_task(state, "judge")
      judge_payload = base_result_payload(judge_task).merge(
        "verdicts" => [judge_verdict("C-resolution-1-1", "PROMOTE", 0.95)],
        "metrics" => {}
      )
      state.ingest(judge_task.fetch("task_id"), judge_payload)

      assert_equal "HIGH", state.findings.last.fetch("severity")
      assert_completion_blocked(state)
    end
  end

  def test_candidate_arbiter_promote_refute_and_unproven_decisions_are_distinct
    expected = {
      "PROMOTE" => "promoted",
      "REFUTE" => "refuted",
      "UNPROVEN" => "unproven"
    }
    expected.each do |decision, candidate_state|
      with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
        built = build_ingest_manifest(repository)
        run_dir = File.join(repository, ".git", "adversarial-review-candidate-#{decision.downcase}")
        state = AdversarialReview::State.create(run_dir, built)
        state.transition_to("attacking")
        candidate = state.ingest_candidate("tester", 1, result_finding("Disputed candidate"))
        advance(state, %w[deduplicating culling awaiting-author resolving])
        state.set_pending_arbiter_subjects([candidate.fetch("id")])
        state.transition_to("arbitrating")
        task = emit_result_task(
          state,
          "arbiter",
          "dispute_kind" => "candidate",
          "subject_ids" => [candidate.fetch("id")],
          "subject_mappings" => {candidate.fetch("id") => [candidate.fetch("id")]}
        )
        payload = base_result_payload(task).merge(
          "decisions" => [{
            "subject_id" => candidate.fetch("id"),
            "decision" => decision,
            "confidence" => 0.9,
            "evidence" => "Independent arbiter evidence.",
            "mapped_candidate_ids" => [candidate.fetch("id")]
          }],
          "metrics" => {}
        )

        state.ingest(task.fetch("task_id"), payload)

        assert_equal candidate_state, state.candidate(candidate.fetch("id")).fetch("state"), decision
        assert_equal decision, state.candidate(candidate.fetch("id")).fetch("arbiter_decision"), decision
        assert_empty state.to_h.fetch("pending_arbiter_subjects"), decision
      end
    end
  end

  def test_creates_a_prepared_state
    Dir.mktmpdir("adversarial-review-state") do |directory|
      run_dir = File.join(directory, "run")

      state = AdversarialReview::State.create(run_dir, manifest)

      assert_equal "prepared", state.to_h.fetch("stage")
      assert_equal 1, state.to_h.fetch("schema_version")
      assert_equal 1, state.to_h.fetch("revise_round")
      assert_equal({}, state.to_h.fetch("task_attempts"))
      assert_equal [], state.to_h.fetch("candidates")
      assert_equal [], state.to_h.fetch("findings")
      assert_equal [
        {"docs/spec.md" => "a" * 64}
      ], state.to_h.fetch("target_digest_history")
      assert_equal({"docs/spec.md" => "a" * 64}, state.to_h.fetch("current_target_digests"))
      assert_equal %w[events results tasks],
                   Dir.children(run_dir).select { |entry| File.directory?(File.join(run_dir, entry)) }.sort
      assert_equal 0o700, File.stat(run_dir).mode & 0o777
      %w[events results tasks].each do |entry|
        assert_equal 0o700, File.stat(File.join(run_dir, entry)).mode & 0o777
      end
      %w[manifest.json state.json .state.lock .state.lock.anchor].each do |entry|
        assert_equal 0o600, File.stat(File.join(run_dir, entry)).mode & 0o777
      end
      assert_equal File.stat(File.join(run_dir, ".state.lock")).ino,
                   File.stat(File.join(run_dir, ".state.lock.anchor")).ino
    end
  end

  def test_create_holds_the_stable_lock_while_publishing_initial_snapshots
    Dir.mktmpdir("adversarial-review-state") do |directory|
      run_dir = File.join(directory, "run")
      lock_observations = []
      original_write_json_relative = AdversarialReview::Atomic.method(:write_json_relative)
      writer = lambda do |run_directory, name, value, **options, &operation|
        File.open(File.join(run_dir, ".state.lock"), File::RDWR) do |lock|
          acquired = lock.flock(File::LOCK_EX | File::LOCK_NB)
          lock_observations << acquired
          lock.flock(File::LOCK_UN) if acquired
        end
        original_write_json_relative.call(
          run_directory, name, value, **options, &operation
        )
      end

      AdversarialReview::Atomic.stub(:write_json_relative, writer) do
        AdversarialReview::State.create(run_dir, manifest)
      end

      assert_equal [false, false], lock_observations
    end
  end

  def test_resolves_default_run_directory_through_git_path
    with_repository do |repository|
      run_dir = AdversarialReview::State.default_run_dir(
        repository: repository,
        run_id: manifest.fetch("run_id")
      )

      expected = File.join(
        File.realpath(File.join(repository, ".git")),
        "adversarial-review", "runs", manifest.fetch("run_id")
      )
      assert_equal expected, run_dir
    end
  end

  def test_rejects_traversal_run_ids
    with_repository do |repository|
      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.default_run_dir(repository: repository, run_id: "../escape")
      end

      assert_equal "invalid_run_id", error.code
      assert_equal 2, error.exit_status
    end
  end

  def test_refuses_to_overwrite_an_existing_run
    Dir.mktmpdir("adversarial-review-state") do |directory|
      run_dir = File.join(directory, "run")
      Dir.mkdir(run_dir)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.create(run_dir, manifest)
      end

      assert_equal "run_exists", error.code
      assert_equal 2, error.exit_status
    end
  end

  def test_invalid_manifest_creation_leaves_no_final_run_and_can_retry
    Dir.mktmpdir("adversarial-review-state") do |directory|
      run_dir = File.join(directory, "run")
      invalid = manifest("mode" => "unsupported", "schema_version" => 99)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.create(run_dir, invalid)
      end

      assert_equal "invalid_state", error.code
      refute File.exist?(run_dir), "failed creation left the final run directory behind"

      state = AdversarialReview::State.create(run_dir, manifest)
      assert_equal "prepared", state.to_h.fetch("stage")
    end
  end

  def test_bootstrap_write_failure_removes_the_new_run_and_can_retry
    Dir.mktmpdir("adversarial-review-state") do |directory|
      run_dir = File.join(directory, "run")
      original_write_json_relative = AdversarialReview::Atomic.method(:write_json_relative)
      writes = 0
      writer = lambda do |run_directory, name, value, **options, &operation|
        writes += 1
        raise IOError, "injected state bootstrap failure" if writes == 2

        original_write_json_relative.call(
          run_directory, name, value, **options, &operation
        )
      end

      error = AdversarialReview::Atomic.stub(:write_json_relative, writer) do
        assert_raises(IOError) { AdversarialReview::State.create(run_dir, manifest) }
      end

      assert_equal "injected state bootstrap failure", error.message
      refute File.exist?(run_dir), "bootstrap failure left the final run directory behind"

      state = AdversarialReview::State.create(run_dir, manifest)
      assert_equal "prepared", state.to_h.fetch("stage")
    end
  end

  def test_bootstrap_rollback_does_not_delete_a_substituted_run_directory
    Dir.mktmpdir("adversarial-review-state") do |directory|
      run_dir = File.join(directory, "run")
      moved_run_dir = File.join(directory, "run-created-and-moved")
      replacement_file = File.join(run_dir, "unrelated.txt")
      original_write_json_relative = AdversarialReview::Atomic.method(:write_json_relative)
      writes = 0
      writer = lambda do |run_directory, name, value, **options, &operation|
        writes += 1
        if writes == 2
          File.rename(run_dir, moved_run_dir)
          Dir.mkdir(run_dir, 0o700)
          File.binwrite(replacement_file, "unrelated replacement bytes")
          raise IOError, "injected failure after run substitution"
        end

        original_write_json_relative.call(
          run_directory, name, value, **options, &operation
        )
      end

      error = AdversarialReview::Atomic.stub(:write_json_relative, writer) do
        assert_raises(IOError) { AdversarialReview::State.create(run_dir, manifest) }
      end

      assert_equal "injected failure after run substitution", error.message
      assert File.directory?(run_dir), "rollback deleted the substituted directory"
      assert_equal "unrelated replacement bytes", File.binread(replacement_file)
      assert File.directory?(moved_run_dir), "rollback chased the moved created directory"
      assert File.exist?(File.join(moved_run_dir, "manifest.json"))
      assert File.exist?(File.join(moved_run_dir, ".state.lock.anchor"))
    end
  end

  def test_anchor_creation_failure_rolls_back_only_the_exact_created_run
    Dir.mktmpdir("adversarial-review-state") do |directory|
      run_dir = File.join(directory, "run")
      moved_run_dir = File.join(directory, "run-created-and-moved")
      replacement_file = File.join(run_dir, "unrelated.txt")
      original_create_lock = AdversarialReview::Atomic.method(:create_anchored_lock)
      creator = lambda do |path|
        original_create_lock.call(path)
        File.rename(run_dir, moved_run_dir)
        Dir.mkdir(run_dir, 0o700)
        File.binwrite(replacement_file, "replacement during anchor failure")
        raise IOError, "injected anchor publication failure"
      end

      error = AdversarialReview::Atomic.stub(:create_anchored_lock, creator) do
        assert_raises(IOError) { AdversarialReview::State.create(run_dir, manifest) }
      end

      assert_equal "injected anchor publication failure", error.message
      assert_equal "replacement during anchor failure", File.binread(replacement_file)
      assert File.directory?(moved_run_dir)
      assert_equal File.stat(File.join(moved_run_dir, ".state.lock")).ino,
                   File.stat(File.join(moved_run_dir, ".state.lock.anchor")).ino
    end
  end

  def test_load_resumes_the_last_complete_state
    with_state do |state, run_dir|
      loaded = AdversarialReview::State.load(run_dir)

      assert_equal state.to_h, loaded.to_h
    end
  end

  def test_manifest_snapshot_is_a_deep_frozen_copy_read_under_the_state_lock
    with_state do |state, _run_dir|
      snapshot = state.manifest_snapshot

      assert_equal manifest, snapshot
      assert_predicate snapshot, :frozen?
      assert_predicate snapshot.fetch("targets"), :frozen?
      assert_predicate snapshot.fetch("targets").first, :frozen?
      assert_raises(FrozenError) { snapshot.fetch("targets").first["path"] = "changed" }
      refute_same snapshot, state.manifest_snapshot
    end
  end

  def test_create_task_bundle_yields_frozen_snapshots_and_writes_under_the_state_lock
    with_state do |state, run_dir|
      state_before = File.binread(File.join(run_dir, "state.json"))
      lock_was_held = nil
      task = {"task_id" => "attack-test-r1-a1", "payload" => "canonical"}

      task_path = state.create_task_bundle(task.fetch("task_id")) do |manifest_snapshot, state_snapshot|
        File.open(File.join(run_dir, ".state.lock"), File::RDWR) do |lock|
          lock_was_held = !lock.flock(File::LOCK_EX | File::LOCK_NB)
        end
        assert_predicate manifest_snapshot, :frozen?
        assert_predicate state_snapshot, :frozen?
        task
      end

      assert_equal true, lock_was_held
      assert_equal File.join(File.realpath(run_dir), "tasks", "attack-test-r1-a1.json"), task_path
      assert_equal JSON.generate(task) + "\n", File.binread(task_path)
      assert_equal 0o600, File.stat(task_path).mode & 0o777
      auth_path = File.join(File.dirname(task_path), "attack-test-r1-a1.auth.json")
      auth = JSON.parse(File.read(auth_path))
      assert_equal 1, auth.fetch("schema_version")
      assert_equal task.fetch("task_id"), auth.fetch("task_id")
      assert_equal Digest::SHA256.hexdigest(File.binread(task_path)), auth.fetch("sha256")
      assert_equal 0o600, File.stat(auth_path).mode & 0o777
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      record = persisted.dig("emitted_tasks", task.fetch("task_id"))
      assert_equal task.fetch("task_id"), record.fetch("task_id")
      assert_equal "attack", record.fetch("kind")
      assert_nil record.fetch("angle")
      assert_equal 1, record.fetch("round")
      assert_equal 1, record.fetch("attempt")
      assert_equal Digest::SHA256.hexdigest(File.binread(task_path)), record.fetch("sha256")
      assert_equal 1, persisted.dig("task_attempts", task.fetch("task_id"))
      refute_equal state_before, File.binread(File.join(run_dir, "state.json"))
    end
  end

  def test_create_task_bundle_adopts_an_exact_preexisting_authenticated_pair
    with_state do |state, _run_dir|
      task = {"task_id" => "attack-test-r1-a1", "payload" => "canonical"}
      first_path = state.create_task_bundle(task.fetch("task_id")) { task }
      first_task_bytes = File.binread(first_path)
      auth_path = File.join(File.dirname(first_path), "attack-test-r1-a1.auth.json")
      first_auth_bytes = File.binread(auth_path)

      adopted_path = state.create_task_bundle(task.fetch("task_id")) { task }

      assert_equal first_path, adopted_path
      assert_equal first_task_bytes, File.binread(first_path)
      assert_equal first_auth_bytes, File.binread(auth_path)
    end
  end

  def test_create_task_bundle_rejects_a_mismatched_preexisting_authenticated_pair
    with_state do |state, _run_dir|
      task = {"task_id" => "attack-test-r1-a1", "payload" => "canonical"}
      task_path = state.create_task_bundle(task.fetch("task_id")) { task }
      File.binwrite(task_path, JSON.generate(task.merge("payload" => "substituted")) + "\n")

      error = assert_raises(AdversarialReview::State::InvalidResult) do
        state.create_task_bundle(task.fetch("task_id")) { task }
      end

      assert_equal "task_collision", error.code
    end
  end

  def test_create_task_bundle_rolls_back_a_new_task_when_authentication_publish_fails
    with_state do |state, run_dir|
      task = {"task_id" => "attack-test-r1-a1", "payload" => "canonical"}
      original_writer = AdversarialReview::Atomic.method(:write_new_json)
      writer = lambda do |directory, name, value|
        result = original_writer.call(directory, name, value)
        raise IOError, "auth write failed after publish" if name.end_with?(".auth.json")

        result
      end

      error = assert_raises(IOError) do
        AdversarialReview::Atomic.stub(:write_new_json, writer) do
          state.create_task_bundle(task.fetch("task_id")) { task }
        end
      end

      assert_equal "auth write failed after publish", error.message
      assert_empty Dir.children(File.join(run_dir, "tasks"))
    end
  end

  def test_create_task_bundle_rejects_a_substituted_run_directory_identity
    Dir.mktmpdir("adversarial-review-state-task-substitution") do |directory|
      run_dir = File.join(directory, "run")
      moved_run_dir = File.join(directory, "authenticated-run")
      state = AdversarialReview::State.create(run_dir, manifest)
      File.rename(run_dir, moved_run_dir)
      AdversarialReview::State.create(run_dir, manifest)

      error = assert_raises(AdversarialReview::State::Error) do
        state.create_task_bundle("attack-test-r1-a1") { manifest }
      end

      assert_equal "unsafe_run_dir", error.code
      assert_empty Dir.children(File.join(run_dir, "tasks"))
      assert_empty Dir.children(File.join(moved_run_dir, "tasks"))
    end
  end

  def test_create_task_bundle_rejects_a_substituted_tasks_directory_identity
    with_state do |state, run_dir|
      tasks_dir = File.join(run_dir, "tasks")
      moved_tasks_dir = File.join(run_dir, "authenticated-tasks")
      File.rename(tasks_dir, moved_tasks_dir)
      Dir.mkdir(tasks_dir, 0o700)

      error = assert_raises(AdversarialReview::State::Error) do
        state.create_task_bundle("attack-test-r1-a1") { manifest }
      end

      assert_equal "unsafe_task_path", error.code
      assert_empty Dir.children(tasks_dir)
      assert_empty Dir.children(moved_tasks_dir)
    end
  end

  def test_read_task_bundle_rejects_a_missing_emitted_task
    with_state do |state, _run_dir|
      error = assert_raises(AdversarialReview::State::Error) do
        state.read_task_bundle("attack-missing-r1-a1") do
          flunk "missing task unexpectedly yielded"
        end
      end

      assert_equal "invalid_task", error.code
    end
  end

  def test_load_ignores_an_interrupted_sibling_temporary_file
    with_state do |state, run_dir|
      File.write(File.join(run_dir, ".state.json.tmp-orphan"), "{\"stage\":")

      loaded = AdversarialReview::State.load(run_dir)

      assert_equal state.to_h, loaded.to_h
    end
  end

  def test_load_rejects_an_invalid_complete_state
    with_state do |_state, run_dir|
      File.write(File.join(run_dir, "state.json"), "{\"stage\":")

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_json", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_follows_the_declared_revise_transition_path
    with_state do |state, _run_dir|
      advance(state, %w[attacking deduplicating culling awaiting-author resolving fresh-sweep])
      assert_equal 2, state.to_h.fetch("revise_round")

      advance(state, %w[culling-new-findings complete])

      assert_equal "complete", state.to_h.fetch("stage")
    end
  end

  def test_refuses_an_invalid_transition_edge
    with_state do |state, _run_dir|
      error = assert_raises(AdversarialReview::State::Error) do
        state.transition_to("complete")
      end

      assert_equal "invalid_transition", error.code
      assert_equal 3, error.exit_status
      assert_equal "prepared", state.to_h.fetch("stage")
    end
  end

  def test_allows_critique_mode_to_complete_after_culling
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      manifest = build_ingest_manifest(repository).merge("mode" => "critique")
      state = AdversarialReview::State.create(
        File.join(repository, ".git", "critique-with-judge"), manifest
      )
      advance(state, %w[attacking deduplicating culling])
      task = AdversarialReview::Prompts.role_task(manifest, state.to_h, "judge")
      state.create_task_bundle(task.fetch("task_id")) { task }
      state.ingest(task.fetch("task_id"), base_result_payload(task).merge(
        "verdicts" => [], "metrics" => {}
      ))
      state.transition_to("complete")

      assert_equal "complete", state.to_h.fetch("stage")
    end
  end

  def test_enforces_the_two_round_cap
    with_state do |state, _run_dir|
      advance(state, %w[
        attacking deduplicating culling awaiting-author resolving fresh-sweep
        culling-new-findings awaiting-author resolving
      ])

      error = assert_raises(AdversarialReview::State::Error) do
        state.transition_to("fresh-sweep")
      end

      assert_equal "revise_round_cap", error.code
      assert_equal 2, state.to_h.fetch("revise_round")
    end
  end

  def test_ingests_immutable_candidate_ids_per_angle_and_attempt
    with_state do |state, _run_dir|
      state.transition_to("attacking")
      first = state.ingest_candidate("Assumptions Checker", 1, finding("first"))
      second = state.ingest_candidate("Assumptions Checker", 1, finding("second"))

      assert_equal "C-assumptions-checker-1-1", first.fetch("id")
      assert_equal "C-assumptions-checker-1-2", second.fetch("id")
      assert_raises(FrozenError) { first["title"] = "mutated" }
      assert_equal "first", state.candidate(first.fetch("id")).fetch("title")
    end
  end

  def test_round_two_candidates_use_the_same_ingestion_path
    with_state do |state, _run_dir|
      advance(state, %w[attacking deduplicating culling awaiting-author resolving fresh-sweep])

      candidate = state.ingest_candidate("pre-mortem", 2, finding("new in round two"))

      assert_equal "C-pre-mortem-2-1", candidate.fetch("id")
      assert_equal 2, state.to_h.fetch("revise_round")
    end
  end

  def test_promotion_is_deterministic_across_equivalent_group_ordering
    Dir.mktmpdir("adversarial-review-states") do |directory|
      left = AdversarialReview::State.create(File.join(directory, "left"), manifest)
      right = AdversarialReview::State.create(File.join(directory, "right"), manifest)
      [left, right].each do |state|
        state.transition_to("attacking")
        state.ingest_candidate("tester", 1, finding("low"))
        state.ingest_candidate("tester", 1, finding("high"))
        advance(state, %w[deduplicating culling])
      end
      low = promotion_group("G-low", "C-tester-1-1", "LOW", 0.99, "z.md", 4)
      high = promotion_group("G-high", "C-tester-1-2", "HIGH", 0.80, "a.md", 9)

      left.promote([low, high])
      right.promote([high, low])

      assert_equal %w[G-high G-low], left.findings.map { |item| item.fetch("group_id") }
      assert_equal left.findings, right.findings
      assert_match(/\AAR-[a-z0-9]{8}-001\z/, left.findings.first.fetch("id"))
      assert_equal "promoted", left.candidate("C-tester-1-2").fetch("state")
    end
  end

  def test_promotion_rejects_duplicate_semantic_group_ids
    with_state do |state, _run_dir|
      state.transition_to("attacking")
      state.ingest_candidate("tester", 1, finding("first"))
      state.ingest_candidate("tester", 1, finding("second"))
      advance(state, %w[deduplicating culling])
      groups = [
        promotion_group("G-duplicate", "C-tester-1-1", "HIGH", 0.9, "a.md", 1),
        promotion_group("G-duplicate", "C-tester-1-2", "HIGH", 0.9, "a.md", 1)
      ]

      error = assert_raises(AdversarialReview::State::Error) do
        state.promote(groups)
      end

      assert_equal "invalid_promotion", error.code
      assert_empty state.findings
      assert_equal %w[candidate candidate], state.candidates.map { |candidate| candidate.fetch("state") }
    end
  end

  def test_completion_requires_a_terminal_author_action
    with_promoted_state("mode" => "revise") do |state, finding_id, _run_dir|
      error = assert_completion_blocked(state)

      assert_includes error.details.fetch("blockers"), "author-action:#{finding_id}"
    end
  end

  def test_record_author_action_rejects_an_unknown_terminal_status
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, _run_dir|
      error = assert_raises(AdversarialReview::State::Error) do
        state.record_author_action(finding_id, "waived")
      end

      assert_equal "invalid_author_action", error.code
      assert_empty state.to_h.fetch("author_actions")
    end
  end

  def test_completion_requires_a_terminal_resolution
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, _run_dir|
      state.record_author_action(finding_id, "fixed")
      state.transition_to("resolving")

      error = assert_completion_blocked(state)

      assert_includes error.details.fetch("blockers"), "resolution:#{finding_id}"
    end
  end

  def test_completion_rejects_fixed_action_with_rejected_resolution
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, run_dir|
      state.record_author_action(finding_id, "fixed")
      state.transition_to("resolving")
      state.record_resolution(finding_id, "resolved")
      persisted = state.to_h
      persisted.fetch("resolution_checks")[finding_id] = "rejected"
      persisted.fetch("findings").first["state"] = "rejected"

      refute state.can_complete?(persisted, from_stage: "resolving")
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))
      error = assert_raises(AdversarialReview::State::Error) do
        state.transition_to("complete")
      end

      assert_equal "invalid_state", error.code
      assert_equal "resolving", JSON.parse(File.read(File.join(run_dir, "state.json"))).fetch("stage")
    end
  end

  def test_completion_rejects_rejected_action_with_resolved_resolution
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, run_dir|
      state.record_author_action(finding_id, "rejected")
      state.transition_to("resolving")
      state.record_resolution(finding_id, "rejected")
      persisted = state.to_h
      persisted.fetch("resolution_checks")[finding_id] = "resolved"
      persisted.fetch("findings").first["state"] = "resolved"

      refute state.can_complete?(persisted, from_stage: "resolving")
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))
      error = assert_raises(AdversarialReview::State::Error) do
        state.transition_to("complete")
      end

      assert_equal "invalid_state", error.code
      assert_equal "resolving", JSON.parse(File.read(File.join(run_dir, "state.json"))).fetch("stage")
    end
  end

  def test_record_resolution_rejects_incompatible_terminal_pairs_without_mutation
    [["fixed", "rejected"], ["rejected", "resolved"]].each do |action, resolution|
      with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, _run_dir|
        state.record_author_action(finding_id, action)
        state.transition_to("resolving")

        error = assert_raises(AdversarialReview::State::Error) do
          state.record_resolution(finding_id, resolution)
        end

        assert_equal "invalid_resolution", error.code
        assert_empty state.to_h.fetch("resolution_checks")
        assert_equal "pending", state.findings.first.fetch("state")
      end
    end
  end

  def test_record_author_action_rejects_an_incompatible_change_without_mutation
    [
      ["fixed", "resolved", "rejected"],
      ["rejected", "rejected", "fixed"]
    ].each do |initial_action, resolution, replacement_action|
      with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, _run_dir|
        state.record_author_action(finding_id, initial_action)
        state.transition_to("resolving")
        state.record_resolution(finding_id, resolution)
        advance(state, %w[arbitrating awaiting-author])

        error = assert_raises(AdversarialReview::State::Error) do
          state.record_author_action(finding_id, replacement_action)
        end

        assert_equal "invalid_author_action", error.code
        assert_equal initial_action, state.to_h.fetch("author_actions").fetch(finding_id)
        assert_equal resolution, state.to_h.fetch("resolution_checks").fetch(finding_id)
      end
    end
  end

  def test_valid_terminal_pairs_complete
    [["fixed", "resolved"], ["rejected", "rejected"]].each do |action, resolution|
      with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, _run_dir|
        state.record_author_action(finding_id, action)
        state.transition_to("resolving")
        state.record_resolution(finding_id, resolution)

        assert state.can_complete?
        state.transition_to("complete")
        assert_equal "complete", state.to_h.fetch("stage")
      end
    end
  end

  def test_record_resolution_refuses_stuck_before_the_round_cap
    with_promoted_state({}, stage: "resolving") do |state, finding_id, _run_dir|
      error = assert_raises(AdversarialReview::State::Error) do
        state.record_resolution(finding_id, "stuck")
      end

      assert_equal "invalid_resolution", error.code
      assert_empty state.to_h.fetch("resolution_checks")
      assert_equal "pending", state.findings.first.fetch("state")
    end
  end

  def test_stuck_at_the_round_cap_blocks_ordinary_completion
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, _run_dir|
      state.record_author_action(finding_id, "fixed")
      advance(state, %w[resolving fresh-sweep culling-new-findings arbitrating])
      state.apply_arbiter(finding_id, "judge-is-right")

      error = assert_completion_blocked(state)

      assert_includes error.details.fetch("blockers"), "resolution:#{finding_id}"
      assert_equal "arbitrating", state.to_h.fetch("stage")
    end
  end

  def test_completion_refuses_pending_arbitration
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, _run_dir|
      state.record_author_action(finding_id, "fixed")
      state.transition_to("resolving")
      state.record_resolution(finding_id, "resolved")
      state.set_pending_arbiter_subjects([finding_id])
      state.transition_to("arbitrating")

      error = assert_completion_blocked(state)

      assert_includes error.details.fetch("blockers"), "pending-arbiter"
    end
  end

  def test_completion_refuses_an_incomplete_required_fresh_sweep
    with_state do |state, _run_dir|
      advance(state, %w[
        attacking deduplicating culling awaiting-author resolving fresh-sweep culling-new-findings
      ])
      state.require_fresh_sweep!

      error = assert_completion_blocked(state)

      assert_includes error.details.fetch("blockers"), "fresh-sweep-incomplete"
    end
  end

  def test_completion_refuses_degraded_capabilities
    with_state do |state, _run_dir|
      advance(state, %w[attacking deduplicating culling])
      state.record_degraded_capability("read_only")

      error = assert_completion_blocked(state)

      assert_includes error.details.fetch("blockers"), "degraded-capabilities"
    end
  end

  def test_digest_mismatch_prevents_transition_mutation
    with_state do |state, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["current_target_digests"]["docs/spec.md"] = "b" * 64
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        state.transition_to("attacking")
      end

      assert_equal "target_digest_mismatch", error.code
      assert_equal "prepared", JSON.parse(File.read(File.join(run_dir, "state.json"))).fetch("stage")
    end
  end

  def test_completion_rehashes_live_target_bytes_under_the_state_lock
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository, tier: "high")
      built["mode"] = "critique"
      run_dir = File.join(repository, ".git", "adversarial-review-live-completion")
      state = AdversarialReview::State.create(run_dir, built)
      advance(state, %w[attacking deduplicating culling])
      state_before = File.binread(File.join(run_dir, "state.json"))
      File.binwrite(File.join(repository, "docs/spec.md"), "# Changed after review\n")

      error = assert_raises(AdversarialReview::State::InvalidResult) do
        state.transition_to("complete")
      end

      assert_equal "target_digest_mismatch", error.code
      assert_equal state_before, File.binread(File.join(run_dir, "state.json"))
    end
  end

  def test_target_digest_updates_append_without_rewriting_history
    with_state do |state, _run_dir|
      initial = state.to_h.fetch("target_digest_history").first.dup

      state.update_current_digests("docs/spec.md" => "b" * 64)

      history = state.to_h.fetch("target_digest_history")
      assert_equal initial, history.first
      assert_equal({"docs/spec.md" => "b" * 64}, history.last)
      assert state.check_current_digests!("docs/spec.md" => "b" * 64)
    end
  end

  def test_arbiter_author_is_right_maps_to_rejected
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, _run_dir|
      state.record_author_action(finding_id, "rejected")
      advance(state, %w[resolving arbitrating])
      state.apply_arbiter(finding_id, "author-is-right")

      assert_equal "rejected", state.findings.first.fetch("state")
      assert_equal "rejected", state.to_h.fetch("resolution_checks").fetch(finding_id)
    end
  end

  def test_arbiter_judge_is_right_becomes_stuck_at_the_round_cap
    with_promoted_state({}, stage: "round-two-arbitrating") do |state, finding_id, _run_dir|
      state.apply_arbiter(finding_id, "judge-is-right")

      assert_equal "stuck", state.findings.first.fetch("state")
      assert_equal "stuck", state.to_h.fetch("resolution_checks").fetch(finding_id)
    end
  end

  def test_arbiter_needs_human_remains_contested_and_blocks_completion
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, _run_dir|
      state.record_author_action(finding_id, "rejected")
      advance(state, %w[resolving arbitrating])
      state.apply_arbiter(finding_id, "needs-human")

      error = assert_completion_blocked(state)

      assert_equal "contested", state.findings.first.fetch("state")
      assert_includes error.details.fetch("blockers"), "pending-arbiter"
    end
  end

  def test_create_rejects_a_symlink_run_directory
    Dir.mktmpdir("adversarial-review-state") do |directory|
      outside = File.join(directory, "outside")
      run_dir = File.join(directory, "run")
      Dir.mkdir(outside)
      File.symlink(outside, run_dir)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.create(run_dir, manifest)
      end

      assert_equal "unsafe_run_dir", error.code
      assert_empty Dir.children(outside)
    end
  end

  def test_create_rejects_a_symlink_path_component
    Dir.mktmpdir("adversarial-review-state") do |directory|
      outside = File.join(directory, "outside")
      link = File.join(directory, "linked")
      Dir.mkdir(outside)
      File.symlink(outside, link)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.create(File.join(link, "run"), manifest)
      end

      assert_equal "unsafe_path", error.code
      assert_empty Dir.children(outside)
    end
  end

  def test_load_rejects_a_symlink_state_file
    with_state do |_state, run_dir|
      outside = File.join(File.dirname(run_dir), "outside-state.json")
      File.write(outside, JSON.generate({"stage" => "attacking"}))
      File.unlink(File.join(run_dir, "state.json"))
      File.symlink(outside, File.join(run_dir, "state.json"))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "unsafe_path", error.code
    end
  end

  def test_load_rejects_a_symlink_lock_file
    with_state do |_state, run_dir|
      outside = File.join(File.dirname(run_dir), "outside-lock")
      File.write(outside, "")
      File.unlink(File.join(run_dir, ".state.lock"))
      File.symlink(outside, File.join(run_dir, ".state.lock"))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "unsafe_lock", error.code
    end
  end

  def test_atomic_lock_rejects_replacement_while_original_inode_is_locked
    with_state do |_state, run_dir|
      lock_path = File.join(run_dir, ".state.lock")
      anchor_path = File.join(run_dir, ".state.lock.anchor")
      moved_lock_path = File.join(run_dir, ".state.lock.moved")

      File.open(lock_path, File::RDWR) do |original_lock|
        original_lock.flock(File::LOCK_EX)
        File.rename(lock_path, moved_lock_path)
        File.open(lock_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
        File.chmod(0o600, lock_path)

        error = assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::Atomic.open_lock(lock_path, exclusive: true) do
            flunk "replacement lock created a second lock domain"
          end
        end

        assert_equal "unsafe_lock", error.code
      ensure
        original_lock.flock(File::LOCK_UN)
      end
    end
  end

  def test_atomic_lock_has_no_overlap_after_both_lock_names_are_replaced
    skip "fork unavailable" unless Process.respond_to?(:fork)
    with_state do |_state, run_dir|
      lock_path = File.join(run_dir, ".state.lock")
      anchor_path = File.join(run_dir, ".state.lock.anchor")
      moved_lock_path = File.join(run_dir, ".state.lock.moved")
      moved_anchor_path = File.join(run_dir, ".state.lock.anchor.moved")
      result_reader, result_writer = IO.pipe
      pid = nil

      AdversarialReview::Atomic.open_lock(lock_path, exclusive: true) do
        File.rename(lock_path, moved_lock_path)
        File.rename(anchor_path, moved_anchor_path)
        File.open(lock_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
        File.chmod(0o600, lock_path)
        File.link(lock_path, anchor_path)

        pid = fork do
          result_reader.close
          result = begin
            AdversarialReview::Atomic.open_lock(lock_path, exclusive: true) { "entered" }
          rescue AdversarialReview::State::Error => error
            error.code
          end
          result_writer.write(result)
          result_writer.close
          exit! 0
        end
        result_writer.close

        assert_nil IO.select([result_reader], nil, nil, 0.25),
                   "replacement lock domain overlapped the original critical section"
      end

      refute_nil IO.select([result_reader], nil, nil, 2),
                 "second lock attempt did not finish after the original lock released"
      assert_includes %w[entered unsafe_lock], result_reader.read
      Process.wait(pid)
      assert_predicate $?, :success?
    ensure
      [result_reader, result_writer].compact.each do |io|
        io.close unless io.closed?
      end
      if pid
        begin
          Process.wait(pid) if Process.waitpid(pid, Process::WNOHANG).nil?
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end

  def test_load_rejects_a_missing_lock_anchor
    with_state do |_state, run_dir|
      lock_path = File.join(run_dir, ".state.lock")
      anchor_path = File.join(run_dir, ".state.lock.anchor")
      File.unlink(anchor_path)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "unsafe_lock", error.code
    end
  end

  def test_load_rejects_a_replaced_lock_anchor
    with_state do |_state, run_dir|
      lock_path = File.join(run_dir, ".state.lock")
      anchor_path = File.join(run_dir, ".state.lock.anchor")
      File.unlink(anchor_path)
      File.open(anchor_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
      File.chmod(0o600, anchor_path)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "unsafe_lock", error.code
    end
  end

  def test_load_rejects_a_lock_with_nonprivate_mode
    with_state do |_state, run_dir|
      lock_path = File.join(run_dir, ".state.lock")
      anchor_path = File.join(run_dir, ".state.lock.anchor")
      File.chmod(0o640, anchor_path)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "unsafe_lock", error.code
    end
  end

  def test_atomic_write_rejects_a_symlink_destination
    Dir.mktmpdir("adversarial-review-atomic") do |directory|
      outside = File.join(directory, "outside.json")
      destination = File.join(directory, "state.json")
      File.write(outside, "unchanged")
      File.symlink(outside, destination)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::Atomic.write_json(destination, {"changed" => true})
      end

      assert_equal "unsafe_path", error.code
      assert_equal "unchanged", File.read(outside)
    end
  end

  def test_atomic_write_rejects_parent_swap_before_temporary_creation
    Dir.mktmpdir("adversarial-review-atomic") do |directory|
      parent = File.join(directory, "parent")
      moved_parent = File.join(directory, "parent-moved")
      outside = File.join(directory, "outside")
      Dir.mkdir(parent)
      Dir.mkdir(outside)
      destination = File.join(parent, "state.json")

      swap_parent = lambda do |_length|
        File.rename(parent, moved_parent)
        File.symlink(outside, parent)
        "fixed"
      end
      error = SecureRandom.stub(:hex, swap_parent) do
        assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::Atomic.write_json(destination, {"changed" => true})
        end
      end

      assert_equal "unsafe_path", error.code
      refute File.exist?(File.join(outside, "state.json"))
      assert_empty Dir.children(moved_parent)
    end
  end

  def test_atomic_write_rejects_parent_swap_during_temporary_write
    Dir.mktmpdir("adversarial-review-atomic") do |directory|
      parent = File.join(directory, "parent")
      moved_parent = File.join(directory, "parent-moved")
      outside = File.join(directory, "outside")
      Dir.mkdir(parent)
      Dir.mkdir(outside)
      destination = File.join(parent, "state.json")
      temporary_name = ".state.json.tmp-#{Process.pid}-fixed"
      original_generate = JSON.method(:generate)
      swap_parent = lambda do |value|
        File.rename(parent, moved_parent)
        File.symlink(outside, parent)
        File.write(File.join(outside, temporary_name), "attacker-controlled")
        original_generate.call(value)
      end

      error = SecureRandom.stub(:hex, "fixed") do
        JSON.stub(:generate, swap_parent) do
          assert_raises(AdversarialReview::State::Error) do
            AdversarialReview::Atomic.write_json(destination, {"changed" => true})
          end
        end
      end

      assert_equal "unsafe_path", error.code
      refute File.exist?(File.join(outside, "state.json"))
      assert_equal "attacker-controlled", File.read(File.join(outside, temporary_name))
      assert_empty Dir.children(moved_parent)
    end
  end

  def test_atomic_read_rejects_parent_swap_before_file_open
    Dir.mktmpdir("adversarial-review-atomic") do |directory|
      parent = File.join(directory, "parent")
      moved_parent = File.join(directory, "parent-moved")
      outside = File.join(directory, "outside")
      Dir.mkdir(parent)
      Dir.mkdir(outside)
      source = File.join(parent, "state.json")
      File.write(source, JSON.generate({"origin" => "inside"}))
      File.write(File.join(outside, "state.json"), JSON.generate({"origin" => "outside"}))
      canonical_parent = File.realpath(parent)
      original_open = File.method(:open)
      swapped = false
      opener = lambda do |*arguments, &block|
        watched_paths = [parent, source, canonical_parent, File.join(canonical_parent, "state.json")]
        if !swapped && watched_paths.include?(arguments.first)
          swapped = true
          File.rename(parent, moved_parent)
          File.symlink(outside, parent)
        end
        original_open.call(*arguments, &block)
      end

      error = File.stub(:open, opener) do
        assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::Atomic.read_json(source)
        end
      end

      assert_equal "unsafe_path", error.code
    end
  end

  def test_atomic_read_rejects_parent_swap_before_returning_parsed_json
    Dir.mktmpdir("adversarial-review-atomic") do |directory|
      parent = File.join(directory, "parent")
      moved_parent = File.join(directory, "parent-moved")
      outside = File.join(directory, "outside")
      Dir.mkdir(parent)
      Dir.mkdir(outside)
      source = File.join(parent, "state.json")
      File.write(source, JSON.generate({"origin" => "inside"}))
      original_parse = JSON.method(:parse)
      swapped = false
      parser = lambda do |contents, *arguments, **options|
        unless swapped
          swapped = true
          File.rename(parent, moved_parent)
          File.symlink(outside, parent)
        end
        original_parse.call(contents, *arguments, **options)
      end

      error = JSON.stub(:parse, parser) do
        assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::Atomic.read_json(source)
        end
      end

      assert_equal "unsafe_path", error.code
    end
  end

  def test_atomic_read_missing_path_preserves_unsafe_path_exit_status
    Dir.mktmpdir("adversarial-review-atomic") do |directory|
      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::Atomic.read_json(File.join(directory, "missing.json"))
      end

      assert_equal "unsafe_path", error.code
      assert_equal 2, error.exit_status
    end
  end

  def test_atomic_lock_rejects_parent_swap_before_file_open
    Dir.mktmpdir("adversarial-review-atomic") do |directory|
      parent = File.join(directory, "parent")
      moved_parent = File.join(directory, "parent-moved")
      outside = File.join(directory, "outside")
      Dir.mkdir(parent)
      Dir.mkdir(outside)
      lock_path = File.join(parent, ".state.lock")
      File.write(lock_path, "")
      File.write(File.join(outside, ".state.lock"), "")
      canonical_parent = File.realpath(parent)
      original_open = File.method(:open)
      swapped = false
      opener = lambda do |*arguments, &block|
        watched_paths = [parent, lock_path, canonical_parent, File.join(canonical_parent, ".state.lock")]
        if !swapped && watched_paths.include?(arguments.first)
          swapped = true
          File.rename(parent, moved_parent)
          File.symlink(outside, parent)
        end
        original_open.call(*arguments, &block)
      end

      error = File.stub(:open, opener) do
        assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::Atomic.open_lock(lock_path, exclusive: true) { flunk "unsafe lock yielded" }
        end
      end

      assert_equal "unsafe_lock", error.code
    end
  end

  def test_state_reads_wait_for_the_stable_exclusive_lock
    skip "fork unavailable" unless Process.respond_to?(:fork)
    with_state do |_state, run_dir|
      ready_reader, ready_writer = IO.pipe
      result_reader, result_writer = IO.pipe
      pid = fork do
        ready_writer.close
        result_reader.close
        ready_reader.read(1)
        AdversarialReview::State.load(run_dir)
        result_writer.write("loaded")
        result_writer.close
        exit! 0
      end
      ready_reader.close
      result_writer.close
      File.open(File.join(run_dir, ".state.lock"), File::RDWR) do |lock|
        lock.flock(File::LOCK_EX)
        ready_writer.write("1")
        ready_writer.close
        assert_nil IO.select([result_reader], nil, nil, 0.2)
        lock.flock(File::LOCK_UN)
      end
      assert_equal "loaded", result_reader.read
      Process.wait(pid)
      assert_predicate $?, :success?
    ensure
      [ready_reader, ready_writer, result_reader, result_writer].compact.each do |io|
        io.close unless io.closed?
      end
      if pid
        begin
          Process.wait(pid) if Process.waitpid(pid, Process::WNOHANG).nil?
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end

  def test_concurrent_writers_do_not_lose_candidates
    skip "fork unavailable" unless Process.respond_to?(:fork)
    with_state do |_state, run_dir|
      AdversarialReview::State.load(run_dir).transition_to("attacking")
      pids = 4.times.map do |index|
        fork do
          state = AdversarialReview::State.load(run_dir)
          state.ingest_candidate("tester", 1, finding("concurrent-#{index}"))
          exit! 0
        end
      end
      pids.each do |pid|
        Process.wait(pid)
        assert_predicate $?, :success?
      end

      loaded = AdversarialReview::State.load(run_dir)
      assert_equal 4, loaded.candidates.length
      assert_equal %w[C-tester-1-1 C-tester-1-2 C-tester-1-3 C-tester-1-4],
                   loaded.candidates.map { |candidate| candidate.fetch("id") }.sort
    end
  end

  def test_manifest_and_lock_identity_remain_unchanged_across_mutation
    with_state do |state, run_dir|
      manifest_path = File.join(run_dir, "manifest.json")
      lock_path = File.join(run_dir, ".state.lock")
      original_manifest = File.binread(manifest_path)
      original_lock_inode = File.stat(lock_path).ino

      state.transition_to("attacking")

      assert_equal original_manifest, File.binread(manifest_path)
      assert_equal original_lock_inode, File.stat(lock_path).ino
    end
  end

  def test_every_complete_transition_invokes_the_named_guard
    paths = {
      "culling" => %w[attacking deduplicating culling],
      "resolving" => %w[attacking deduplicating culling awaiting-author resolving],
      "culling-new-findings" => %w[
        attacking deduplicating culling awaiting-author resolving fresh-sweep culling-new-findings
      ],
      "arbitrating" => %w[
        attacking deduplicating culling awaiting-author resolving arbitrating
      ]
    }

    paths.each do |source, stages|
      with_state do |state, _run_dir|
        advance(state, stages)

        state.stub(:can_complete?, false) do
          error = assert_raises(AdversarialReview::State::Error) do
            state.transition_to("complete")
          end
          assert_equal "completion_blocked", error.code
          assert_equal source, state.to_h.fetch("stage")
        end
      end
    end
  end

  def test_load_rejects_a_symlink_manifest_file
    with_state do |_state, run_dir|
      outside = File.join(File.dirname(run_dir), "outside-manifest.json")
      File.write(outside, JSON.generate(manifest))
      File.unlink(File.join(run_dir, "manifest.json"))
      File.symlink(outside, File.join(run_dir, "manifest.json"))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "unsafe_path", error.code
    end
  end

  def test_atomic_write_rejects_a_symlink_temporary_sibling
    Dir.mktmpdir("adversarial-review-atomic") do |directory|
      destination = File.join(directory, "state.json")
      outside = File.join(directory, "outside.json")
      temporary = File.join(directory, ".state.json.tmp-#{Process.pid}-fixed")
      File.write(outside, "unchanged")
      File.symlink(outside, temporary)

      error = SecureRandom.stub(:hex, "fixed") do
        assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::Atomic.write_json(destination, {"changed" => true})
        end
      end

      assert_equal "unsafe_temp", error.code
      assert_equal "unchanged", File.read(outside)
    end
  end

  def test_load_rejects_rewritten_initial_digest_history
    with_state do |_state, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["target_digest_history"][0]["docs/spec.md"] = "b" * 64
      persisted["current_target_digests"]["docs/spec.md"] = "b" * 64
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_default_run_directory_normalizes_a_failed_git_status
    status = Struct.new(:success?, :exitstatus).new(false, 128)

    with_repository do |repository|
      Open3.stub(:capture2e, ["fatal: unavailable\n", status]) do
        error = assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::State.default_run_dir(
            repository: repository,
            run_id: manifest.fetch("run_id")
          )
        end

        assert_equal "git_path_unresolved", error.code
        assert_equal 128, error.details.fetch("git_exit_status")
        assert_equal 2, error.exit_status
      end
    end
  end

  def test_promotion_uses_confidence_path_line_and_group_tie_breakers
    with_state do |state, _run_dir|
      state.transition_to("attacking")
      5.times { |index| state.ingest_candidate("tester", 1, finding("item-#{index}")) }
      advance(state, %w[deduplicating culling])
      groups = [
        promotion_group("G-z", "C-tester-1-1", "HIGH", 0.8, "a.md", 1),
        promotion_group("G-confidence", "C-tester-1-2", "HIGH", 0.9, "z.md", 1),
        promotion_group("G-line", "C-tester-1-3", "HIGH", 0.8, "a.md", 0),
        promotion_group("G-b", "C-tester-1-4", "HIGH", 0.8, "a.md", 1),
        promotion_group("G-a", "C-tester-1-5", "HIGH", 0.8, "a.md", 1)
      ]

      state.promote(groups.reverse)

      assert_equal %w[G-confidence G-line G-a G-b G-z],
                   state.findings.map { |finding_item| finding_item.fetch("group_id") }
    end
  end

  def test_transition_graph_is_exact_and_immutable
    expected = {
      "prepared" => %w[attacking],
      "attacking" => %w[deduplicating],
      "deduplicating" => %w[culling culling-new-findings],
      "culling" => %w[awaiting-author complete],
      "awaiting-author" => %w[resolving],
      "resolving" => %w[fresh-sweep arbitrating complete did-not-converge],
      "fresh-sweep" => %w[deduplicating culling-new-findings],
      "culling-new-findings" => %w[awaiting-author arbitrating complete did-not-converge],
      "arbitrating" => %w[awaiting-author complete did-not-converge]
    }

    assert_equal expected, AdversarialReview::State::TRANSITIONS
    AdversarialReview::State::TRANSITIONS.each_value do |destinations|
      assert_predicate destinations, :frozen?
    end
  end

  def test_structured_errors_serialize_the_exit_status
    with_state do |state, _run_dir|
      error = assert_raises(AdversarialReview::State::Error) { state.transition_to("complete") }

      assert_equal 3, error.to_h.fetch("exit_status")
    end
  end

  def test_terminal_states_reject_every_public_mutation_without_writing
    terminal_paths = {
      "complete" => %w[attacking deduplicating culling complete],
      "did-not-converge" => %w[
        attacking deduplicating culling awaiting-author resolving did-not-converge
      ]
    }
    mutations = {
      "ingest" => lambda do |state|
        state.ingest_candidate("tester", 1, finding("late"))
      end,
      "promote" => ->(state) { state.promote([]) },
      "author-action" => ->(state) { state.record_author_action("AR-deadbeef-001", "fixed") },
      "resolution" => ->(state) { state.record_resolution("AR-deadbeef-001", "resolved") },
      "arbiter-subjects" => ->(state) { state.set_pending_arbiter_subjects([]) },
      "require-sweep" => ->(state) { state.require_fresh_sweep! },
      "complete-sweep" => ->(state) { state.mark_fresh_sweep_completed! },
      "degraded" => ->(state) { state.record_degraded_capability("read_only") },
      "digests" => ->(state) { state.update_current_digests("docs/spec.md" => "b" * 64) },
      "arbiter" => ->(state) { state.apply_arbiter("AR-deadbeef-001", "author-is-right") }
    }

    terminal_paths.each do |terminal_stage, stages|
      mutations.each do |mutation_name, mutation|
        with_state do |state, run_dir|
          advance(state, stages)
          state_path = File.join(run_dir, "state.json")
          before = File.binread(state_path)

          error = assert_raises(AdversarialReview::State::Error, "#{terminal_stage}:#{mutation_name}") do
            mutation.call(state)
          end

          assert_equal "terminal_state", error.code, "#{terminal_stage}:#{mutation_name}"
          assert_equal before, File.binread(state_path), "#{terminal_stage}:#{mutation_name}"
        end
      end
    end
  end

  def test_public_mutations_reject_wrong_nonterminal_stages_without_writing
    mutations = {
      "ingest" => lambda do |state|
        state.ingest_candidate("tester", 1, finding("early"))
      end,
      "promote" => ->(state) { state.promote([]) },
      "author-action" => ->(state) { state.record_author_action("AR-deadbeef-001", "fixed") },
      "resolution" => ->(state) { state.record_resolution("AR-deadbeef-001", "resolved") },
      "arbiter-subjects" => ->(state) { state.set_pending_arbiter_subjects([]) },
      "require-sweep" => ->(state) { state.require_fresh_sweep! },
      "complete-sweep" => ->(state) { state.mark_fresh_sweep_completed! },
      "arbiter" => ->(state) { state.apply_arbiter("AR-deadbeef-001", "author-is-right") }
    }

    mutations.each do |mutation_name, mutation|
      with_state do |state, run_dir|
        state_path = File.join(run_dir, "state.json")
        before = File.binread(state_path)

        error = assert_raises(AdversarialReview::State::Error, mutation_name) do
          mutation.call(state)
        end

        assert_equal "invalid_stage", error.code, mutation_name
        assert_equal before, File.binread(state_path), mutation_name
      end
    end
  end

  def test_create_rejects_invalid_manifest_digests
    invalid = manifest("targets" => [
      {"role" => "spec", "path" => "docs/spec.md", "sha256" => "not-a-digest"}
    ])
    Dir.mktmpdir("adversarial-review-state") do |directory|
      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.create(File.join(directory, "run"), invalid)
      end

      assert_equal "invalid_digest", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_load_rejects_candidate_id_collisions
    with_state do |_state, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      duplicate = finding("duplicate").merge(
        "id" => "C-tester-1-1", "state" => "candidate", "angle" => "tester",
        "attempt" => 1, "sequence" => 1, "round" => 1
      )
      persisted["candidates"] = [duplicate, duplicate.dup]
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "candidate_collision", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_load_rejects_malformed_candidate_elements
    with_state do |_state, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["candidates"] = [{}]
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_load_rejects_malformed_finding_elements
    with_state do |_state, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["findings"] = [{"id" => "AR-deadbeef-001"}]
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_load_rejects_wrong_fingerprint_or_ordinal_in_promoted_ids
    fingerprint = Digest::SHA256.hexdigest(manifest.fetch("run_id"))[0, 8]
    wrong_fingerprint = fingerprint == "00000000" ? "11111111" : "00000000"
    invalid_ids = ["AR-#{wrong_fingerprint}-001", "AR-#{fingerprint}-002"]

    invalid_ids.each do |invalid_id|
      with_promoted_state do |_state, _finding_id, run_dir|
        persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
        persisted.fetch("findings").first["id"] = invalid_id
        File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

        error = assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::State.load(run_dir)
        end

        assert_equal "finding_collision", error.code
        assert_equal 3, error.exit_status
      end
    end
  end

  def test_load_rejects_an_invalid_persisted_author_action
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, run_dir|
      state.record_author_action(finding_id, "fixed")
      state.transition_to("resolving")
      state.record_resolution(finding_id, "resolved")
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["author_actions"][finding_id] = "waived"
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_load_rejects_disposition_maps_for_unknown_findings
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, run_dir|
      state.record_author_action(finding_id, "fixed")
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["resolution_checks"]["AR-deadbeef-999"] = "resolved"
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_load_rejects_an_invalid_persisted_resolution_status
    with_promoted_state({}, stage: "awaiting-author") do |state, finding_id, run_dir|
      state.record_author_action(finding_id, "fixed")
      state.transition_to("resolving")
      state.record_resolution(finding_id, "resolved")
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["resolution_checks"][finding_id] = "passed"
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_load_rejects_an_unknown_stage
    with_state do |_state, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["stage"] = "teleporting"
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
      assert_equal 3, error.exit_status
    end
  end

  def test_load_rejects_a_next_action_mismatch
    with_state do |_state, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["next_action"] = "complete"
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
    end
  end

  def test_load_rejects_invalid_task_attempt_entries
    [{"task-1" => -1}, {"task-1" => "1"}, {"" => 0}].each do |attempts|
      with_state do |_state, run_dir|
        persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
        persisted["task_attempts"] = attempts
        File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

        error = assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::State.load(run_dir)
        end

        assert_equal "invalid_state", error.code
      end
    end
  end

  def test_load_rejects_noncanonical_authoritative_task_identity
    corruptions = [
      lambda do |persisted, task_id|
        persisted.dig("emitted_tasks", task_id)["attempt"] = 2
        persisted.fetch("task_attempts")[task_id] = 2
      end,
      lambda do |persisted, task_id|
        persisted.dig("emitted_tasks", task_id)["angle"] = "forged-angle"
      end
    ]

    corruptions.each do |corrupt|
      with_ingest_state(stage: "attacking") do |_state, run_dir, task|
        persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
        corrupt.call(persisted, task.fetch("task_id"))
        File.binwrite(File.join(run_dir, "state.json"), JSON.generate(persisted) + "\n")

        error = assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::State.load(run_dir)
        end

        assert_equal "invalid_state", error.code
      end
    end
  end

  def test_load_rejects_malformed_events
    ["not-an-object", {}, {"type" => "transition", "from" => "prepared"}].each do |event|
      with_state do |_state, run_dir|
        persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
        persisted["events"] = [event]
        File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

        error = assert_raises(AdversarialReview::State::Error) do
          AdversarialReview::State.load(run_dir)
        end

        assert_equal "invalid_state", error.code
      end
    end
  end

  def test_load_rejects_a_sourced_candidate_reset_to_candidate
    with_promoted_state do |_state, _finding_id, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted.fetch("candidates").first["state"] = "candidate"
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
    end
  end

  def test_load_rejects_an_unreferenced_promoted_candidate
    with_promoted_state do |_state, _finding_id, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      duplicate = persisted.fetch("candidates").first.dup
      duplicate["id"] = "C-tester-1-2"
      duplicate["sequence"] = 2
      persisted.fetch("candidates") << duplicate
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
    end
  end

  def test_load_rejects_a_candidate_sourced_by_multiple_findings
    with_promoted_state do |_state, _finding_id, run_dir|
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      duplicate = JSON.parse(JSON.generate(persisted.fetch("findings").first))
      duplicate["id"] = duplicate.fetch("id").sub(/001\z/, "002")
      duplicate["group_id"] = "G-002"
      persisted.fetch("findings") << duplicate
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
    end
  end

  def test_load_revalidates_complete_state_invariants
    with_state do |state, run_dir|
      advance(state, %w[attacking deduplicating culling complete])
      persisted = JSON.parse(File.read(File.join(run_dir, "state.json")))
      persisted["degraded_capabilities"] = ["read_only"]
      File.write(File.join(run_dir, "state.json"), JSON.generate(persisted))

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::State.load(run_dir)
      end

      assert_equal "invalid_state", error.code
    end
  end

  private

  def with_ingest_state(stage:, tier: "high", schema: "attack", task_overrides: {},
                        candidate_findings: [])
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository, tier: tier)
      run_dir = File.join(repository, ".git", "adversarial-review-ingest")
      state = AdversarialReview::State.create(run_dir, built)
      path = transition_path_to(stage)
      if candidate_findings.empty?
        advance(state, path)
      else
        state.transition_to("attacking")
        candidate_findings.each { |finding| state.ingest_candidate("tester", 1, finding) }
        advance(state, path.drop(1))
      end
      task_id = "#{schema}-tester-r#{state.to_h.fetch("revise_round")}-a1"
      task = {
        "schema_version" => 1,
        "run_id" => built.fetch("run_id"),
        "task_id" => task_id,
        "role" => schema == "attack" ? "attacker" : schema,
        "kind" => schema,
        "schema" => "assets/schemas/#{schema}.json",
        "artifact_digests" => state.to_h.fetch("current_target_digests"),
        "round" => state.to_h.fetch("revise_round"),
        "attempt" => 1,
        "angle" => "tester"
      }.merge(task_overrides)
      state.create_task_bundle(task_id) { task }
      yield state, run_dir, task
    end
  end

  def build_ingest_manifest(repository, tier: "high")
    AdversarialReview::Manifest.build(
      repository: repository,
      spec: "docs/spec.md",
      tier: tier,
      mode: "revise",
      output: "chat",
      executor: "generic",
      model: "reviewer-model",
      effort: "high"
    )
  end

  def emit_result_task(state, schema, overrides = {})
    snapshot = state.to_h
    task_id = overrides.fetch("task_id", "#{schema}-batch-r#{snapshot.fetch("revise_round")}-a1")
    encoded_attempt = task_id[/-a(?<attempt>[1-9]\d*)\z/, :attempt]
    task = {
      "schema_version" => 1,
      "run_id" => snapshot.fetch("run_id"),
      "task_id" => task_id,
      "role" => schema,
      "kind" => schema,
      "schema_name" => schema,
      "artifact_digests" => snapshot.fetch("current_target_digests"),
      "round" => snapshot.fetch("revise_round"),
      "attempt" => encoded_attempt ? Integer(encoded_attempt) : 1
    }.merge(overrides)
    state.create_task_bundle(task_id) { task }
    task
  end

  def with_author_resolution_dispute(action_status)
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "adversarial-review-author-dispute")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      candidate = state.ingest_candidate("tester", 1, result_finding("Missing rollback owner"))
      advance(state, %w[deduplicating culling])
      state.promote([promotion_group("G-001", candidate.fetch("id"), "HIGH", 0.9, "docs/spec.md", 2)])
      state.transition_to("awaiting-author")
      finding_id = state.findings.first.fetch("id")
      state.record_author_action(finding_id, action_status)
      state.transition_to("resolving")
      state.record_resolution(finding_id, "contested")
      state.set_pending_arbiter_subjects([finding_id])
      state.transition_to("arbitrating")
      task = emit_result_task(
        state,
        "arbiter",
        "dispute_kind" => "author-resolution",
        "subject_ids" => [finding_id],
        "subject_mappings" => {finding_id => [candidate.fetch("id")]}
      )
      yield state, task, finding_id, candidate.fetch("id"), run_dir
    end
  end

  def with_semantic_group_state
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      built = build_ingest_manifest(repository)
      run_dir = File.join(repository, ".git", "adversarial-review-semantic-state")
      state = AdversarialReview::State.create(run_dir, built)
      state.transition_to("attacking")
      2.times { |index| state.ingest_candidate("tester", 1, result_finding("candidate-#{index}")) }
      state.transition_to("deduplicating")
      task = emit_result_task(state, "dedupe")
      payload = base_result_payload(task).merge(
        "groups" => [{
          "group_id" => "G-shared",
          "candidate_ids" => %w[C-tester-1-1 C-tester-1-2],
          "summary" => "Shared concern",
          "location" => result_finding("x").fetch("location"),
          "source_angles" => ["tester"]
        }]
      )
      state.ingest(task.fetch("task_id"), payload)
      yield run_dir
    end
  end

  def arbiter_payload(task, subject_id, candidate_id, decision)
    base_result_payload(task).merge(
      "decisions" => [{
        "subject_id" => subject_id,
        "decision" => decision,
        "confidence" => 0.9,
        "evidence" => "Independent arbiter evidence.",
        "mapped_candidate_ids" => [candidate_id]
      }],
      "metrics" => {}
    )
  end

  def with_ultra_duplicate_voter
    with_ingest_state(
      stage: "culling",
      schema: "judge",
      tier: "ultra",
      candidate_findings: [result_finding("Missing rollback owner")],
      task_overrides: {
        "vote_group_id" => "VG-cull-1", "voter_id" => "voter-1",
        "voter_ids" => %w[voter-1 voter-2 voter-3], "expected_voters" => 3
      }
    ) do |state, _run_dir, first_task|
      first_payload = base_result_payload(first_task).merge(
        "verdicts" => [ultra_verdict("C-tester-1-1", "PROMOTE")],
        "metrics" => {}
      )
      state.ingest(first_task.fetch("task_id"), first_payload)
      second_task = emit_result_task(
        state,
        "judge",
        "task_id" => "judge-batch-r1-a2",
        "vote_group_id" => "VG-cull-1",
        "voter_id" => "voter-1",
        "voter_ids" => %w[voter-1 voter-2 voter-3],
        "expected_voters" => 3
      )
      second_payload = base_result_payload(second_task).merge(
        "verdicts" => [ultra_verdict("C-tester-1-1", "PROMOTE")],
        "metrics" => {}
      )
      before = state.to_h
      error = assert_raises(AdversarialReview::State::InvalidResult) do
        state.ingest(second_task.fetch("task_id"), second_payload)
      end
      yield state, error, before
    end
  end

  def reported_groups_for_batch_order(order)
    result = nil
    with_state do |state, _run_dir|
      state.transition_to("attacking")
      60.times { |index| state.ingest_candidate("tester", 1, finding("candidate-#{index}")) }
      advance(state, %w[deduplicating culling])
      batches = {
        low: 30.times.map do |index|
          promotion_group(
            format("G-low-%02d", index), "C-tester-1-#{index + 1}",
            "LOW", 0.8, "docs/spec.md", index + 1
          )
        end,
        high: 30.times.map do |index|
          promotion_group(
            format("G-high-%02d", index), "C-tester-1-#{index + 31}",
            "HIGH", 0.9, "docs/spec.md", index + 31
          )
        end
      }
      order.each { |name| state.promote(batches.fetch(name)) }
      result = state.findings.select do |promoted|
        promoted.fetch("reported")
      end.map { |promoted| promoted.fetch("group_id") }.sort
    end
    result
  end

  def with_ultra_vote_sequence(dispositions, expected_voters: 3)
    with_ingest_state(
      stage: "culling",
      schema: "judge",
      tier: "ultra",
      candidate_findings: [result_finding("Missing rollback owner")],
      task_overrides: {
        "vote_group_id" => "VG-cull-1", "voter_id" => "voter-1",
        "voter_ids" => %w[voter-1 voter-2 voter-3], "expected_voters" => expected_voters
      }
    ) do |state, _run_dir, first_task|
      summary = nil
      dispositions.each_with_index do |disposition, index|
        task = if index.zero?
                 first_task
               else
                 emit_result_task(
                   state,
                   "judge",
                   "task_id" => "judge-batch-r1-a#{index + 1}",
                   "vote_group_id" => "VG-cull-1",
                   "voter_id" => "voter-#{index + 1}",
                   "voter_ids" => %w[voter-1 voter-2 voter-3],
                   "expected_voters" => expected_voters
                 )
               end
        payload = base_result_payload(task).merge(
          "verdicts" => [ultra_verdict("C-tester-1-1", disposition)],
          "metrics" => {}
        )
        summary = state.ingest(task.fetch("task_id"), payload)
      end
      yield state, summary
    end
  end

  def ultra_verdict(candidate_id, disposition)
    evidence = disposition == "REFUTE" ? "The owner is named on line 8." : "Independent supporting evidence."
    judge_verdict(candidate_id, disposition, 0.9, evidence: evidence)
  end

  def transition_path_to(stage)
    stages = %w[attacking deduplicating culling awaiting-author resolving fresh-sweep culling-new-findings]
    return [] if stage == "prepared"

    stages.take(stages.index(stage) + 1)
  end

  def attack_payload(task, findings = [])
    base_result_payload(task).merge(
      "angle" => task.fetch("angle"),
      "checks_completed" => ["assigned review checks"],
      "findings" => findings,
      "metrics" => {}
    )
  end

  def base_result_payload(task)
    {
      "schema_version" => 1,
      "run_id" => task.fetch("run_id"),
      "task_id" => task.fetch("task_id"),
      "artifact_digests" => task.fetch("artifact_digests"),
      "notes" => []
    }
  end

  def result_finding(summary)
    {
      "location" => {
        "path" => "docs/spec.md", "line_start" => 2, "line_end" => 2,
        "heading" => "Product spec"
      },
      "category" => "Omission",
      "summary" => summary,
      "evidence" => "The specification does not name one.",
      "consequence" => "Recovery can stall."
    }
  end

  def judge_verdict(candidate_id, disposition, confidence, evidence: "Independent supporting evidence.")
    {
      "candidate_id" => candidate_id,
      "disposition" => disposition,
      "confidence" => confidence,
      "category" => "Omission",
      "severity" => "HIGH",
      "evidence" => evidence,
      "consequence" => "Recovery can stall."
    }
  end

  def with_state(overrides = {})
    Dir.mktmpdir("adversarial-review-state") do |directory|
      run_dir = File.join(directory, "run")
      state = AdversarialReview::State.create(run_dir, manifest(overrides))
      yield state, run_dir
    end
  end

  def with_promoted_state(overrides = {}, stage: "culling")
    with_state(overrides) do |state, run_dir|
      state.transition_to("attacking")
      candidate = state.ingest_candidate("tester", 1, finding("promoted"))
      advance(state, %w[deduplicating culling])
      state.promote([
        promotion_group("G-001", candidate.fetch("id"), "HIGH", 0.9, "docs/spec.md", 3)
      ])
      stages = case stage
               when "culling"
                 []
               when "awaiting-author"
                 %w[awaiting-author]
               when "resolving"
                 %w[awaiting-author resolving]
               when "arbitrating"
                 %w[awaiting-author resolving arbitrating]
               when "culling-new-findings"
                 %w[awaiting-author resolving fresh-sweep culling-new-findings]
               when "round-two-arbitrating"
                 %w[awaiting-author resolving fresh-sweep culling-new-findings arbitrating]
               else
                 raise "unsupported promoted-state stage: #{stage}"
               end
      advance(state, stages)
      yield state, state.findings.first.fetch("id"), run_dir
    end
  end

  def advance(state, stages)
    stages.each { |stage| state.transition_to(stage) }
  end

  def assert_completion_blocked(state)
    error = assert_raises(AdversarialReview::State::Error) { state.transition_to("complete") }
    assert_equal "completion_blocked", error.code
    error
  end

  def finding(title)
    {"title" => title, "path" => "docs/spec.md", "line" => 3, "severity" => "HIGH"}
  end

  def promotion_group(group_id, candidate_id, severity, confidence, path, line)
    {
      "group_id" => group_id,
      "candidate_ids" => [candidate_id],
      "severity" => severity,
      "confidence" => confidence,
      "path" => path,
      "line" => line
    }
  end

  def manifest(overrides = {})
    {
      "schema_version" => 1,
      "run_id" => "ar-20260717T120000000000Z-deadbeef",
      "mode" => "revise",
      "tier" => "high",
      "targets" => [
        {"role" => "spec", "path" => "docs/spec.md", "sha256" => "a" * 64}
      ]
    }.merge(overrides)
  end
end
