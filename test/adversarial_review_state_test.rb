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
      original_write_json = AdversarialReview::Atomic.method(:write_json)
      writer = lambda do |path, value|
        File.open(File.join(run_dir, ".state.lock"), File::RDWR) do |lock|
          acquired = lock.flock(File::LOCK_EX | File::LOCK_NB)
          lock_observations << acquired
          lock.flock(File::LOCK_UN) if acquired
        end
        original_write_json.call(path, value)
      end

      AdversarialReview::Atomic.stub(:write_json, writer) do
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
      original_write_json = AdversarialReview::Atomic.method(:write_json)
      writes = 0
      writer = lambda do |path, value|
        writes += 1
        raise IOError, "injected state bootstrap failure" if writes == 2

        original_write_json.call(path, value)
      end

      error = AdversarialReview::Atomic.stub(:write_json, writer) do
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
      original_write_json = AdversarialReview::Atomic.method(:write_json)
      writes = 0
      writer = lambda do |path, value|
        writes += 1
        if writes == 2
          File.rename(run_dir, moved_run_dir)
          Dir.mkdir(run_dir, 0o700)
          File.binwrite(replacement_file, "unrelated replacement bytes")
          raise IOError, "injected failure after run substitution"
        end

        original_write_json.call(path, value)
      end

      error = AdversarialReview::Atomic.stub(:write_json, writer) do
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
    with_state("mode" => "critique") do |state, _run_dir|
      advance(state, %w[attacking deduplicating culling complete])

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
    with_promoted_state("mode" => "critique") do |state, finding_id, _run_dir|
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
      "deduplicating" => %w[culling],
      "culling" => %w[awaiting-author complete],
      "awaiting-author" => %w[resolving],
      "resolving" => %w[fresh-sweep arbitrating complete did-not-converge],
      "fresh-sweep" => %w[culling-new-findings],
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
