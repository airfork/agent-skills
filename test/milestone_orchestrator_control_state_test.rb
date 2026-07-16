require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "rbconfig"
require_relative "support/milestone_orchestrator_state_helper"

class MilestoneOrchestratorControlStateTest < Minitest::Test
  include MilestoneOrchestratorStateHelper

  CONTROL = File.join(MilestoneOrchestratorStateHelper::SKILL_SCRIPTS, "control-state")

  def setup
    @dir = Dir.mktmpdir
    @lease_dir = File.join(@dir, "lease")
    @state_path = write_state(@dir, base_state)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_control(*args)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, CONTROL, @state_path, *args, "--lease-dir", @lease_dir
    )
    [stdout, stderr, status.exitstatus]
  end

  def acquire(owner = "coordinator", ttl: 300)
    stdout, _stderr, exit_code = run_control("acquire-lease", "--owner", owner, "--ttl", ttl.to_s)
    raise "acquire failed: #{stdout}" unless exit_code.zero?
    JSON.parse(stdout)
  end

  def fenced(owner, lease)
    ["--owner", owner, "--token", lease.fetch("fencing_token").to_s]
  end

  # --- lease behavior ---

  def test_acquire_returns_lease_with_fencing_token
    lease = acquire
    assert_equal "coordinator", lease["owner"]
    assert_equal 1, lease["fencing_token"]
    assert lease["expires_at"]
  end

  def test_second_acquire_by_other_owner_rejected_while_live
    acquire("coordinator")
    _stdout, stderr, exit_code = run_control("acquire-lease", "--owner", "intruder", "--ttl", "300")
    assert_equal 3, exit_code
    assert_match(/lease/i, stderr)
  end

  def test_reacquire_by_same_owner_is_renewal
    first = acquire("coordinator")
    second = acquire("coordinator")
    assert_equal first["fencing_token"], second["fencing_token"]
    assert_equal first["epoch"], second["epoch"]
  end

  def test_takeover_after_expiry_advances_epoch_and_token
    stale = acquire("coordinator", ttl: 0)
    takeover = acquire("successor", ttl: 300)
    assert_operator takeover["fencing_token"], :>, stale["fencing_token"]
    assert_operator takeover["epoch"], :>, stale["epoch"]
  end

  def test_release_then_acquire_by_new_owner
    lease = acquire("coordinator")
    _out, _err, exit_code = run_control("release-lease", *fenced("coordinator", lease))
    assert_equal 0, exit_code
    fresh = acquire("next-owner")
    assert_equal "next-owner", fresh["owner"]
  end

  # --- fenced mutations ---

  def test_mutation_without_lease_rejected
    _out, stderr, exit_code = run_control("set-phase", "publishing", "--owner", "coordinator", "--token", "1")
    assert_equal 3, exit_code
    assert_match(/lease/i, stderr)
    assert_equal "running", read_state(@state_path)["run"]["phase"]
  end

  def test_stale_fencing_token_rejected_and_file_untouched
    acquire("coordinator", ttl: 0)
    acquire("successor")
    before = File.read(@state_path)
    _out, _err, exit_code = run_control("set-phase", "publishing", "--owner", "coordinator", "--token", "1")
    assert_equal 3, exit_code
    assert_equal before, File.read(@state_path)
  end

  def test_set_phase_updates_state
    lease = acquire
    _out, _err, exit_code = run_control("set-phase", "publishing", *fenced("coordinator", lease))
    assert_equal 0, exit_code
    assert_equal "publishing", read_state(@state_path)["run"]["phase"]
  end

  def test_set_phase_closed_without_closeout_rejected
    lease = acquire
    before = File.read(@state_path)
    _out, _err, exit_code = run_control("set-phase", "closed", *fenced("coordinator", lease))
    assert_equal 1, exit_code
    assert_equal before, File.read(@state_path)
  end

  def test_record_attempt_appends
    lease = acquire
    attempt = {"attempt" => 1, "status" => "completed", "route" => "sonnet", "base_sha" => "c" * 40,
               "result_commits" => ["e" * 40], "evidence" => "verified"}.to_json
    _out, _err, exit_code = run_control("record-attempt", "TASK-001", "--attempt-json", attempt,
                                        *fenced("coordinator", lease))
    assert_equal 0, exit_code
    task = read_state(@state_path)["tasks"]["TASK-001"]
    assert_equal 1, task["attempts"].length
    assert_equal "completed", task["attempts"][0]["status"]
  end

  def test_failed_attempt_increments_failure_count_and_opens_circuit_at_budget
    lease = acquire
    3.times do |i|
      attempt = {"attempt" => i + 1, "status" => "failed", "route" => "sonnet", "base_sha" => "c" * 40}.to_json
      _out, _err, exit_code = run_control("record-attempt", "TASK-001", "--attempt-json", attempt,
                                          *fenced("coordinator", lease))
      assert_equal 0, exit_code
    end
    task = read_state(@state_path)["tasks"]["TASK-001"]
    assert_equal 3, task["failure_count"]
    assert_equal "circuit-open", task["condition"]
  end

  def test_record_attempt_rejected_when_dispatch_budget_exhausted
    state = base_state
    state["budgets"]["worker_dispatches"] = 1
    @state_path = write_state(@dir, state)
    lease = acquire
    attempt = {"attempt" => 1, "status" => "completed", "route" => "sonnet", "base_sha" => "c" * 40}.to_json
    _out, _err, exit_code = run_control("record-attempt", "TASK-001", "--attempt-json", attempt,
                                        *fenced("coordinator", lease))
    assert_equal 0, exit_code
    before = File.read(@state_path)
    second = {"attempt" => 2, "status" => "created", "route" => "sonnet", "base_sha" => "c" * 40}.to_json
    _out, stderr, exit_code = run_control("record-attempt", "TASK-001", "--attempt-json", second,
                                          *fenced("coordinator", lease))
    assert_equal 1, exit_code
    assert_match(/dispatch budget exhausted/i, stderr)
    assert_equal before, File.read(@state_path)
  end

  def test_set_closeout_rejected_when_review_rounds_exceed_budget
    lease = acquire
    closeout = {
      "branch" => "milestone/example", "head_sha" => "e" * 40, "pr" => nil,
      "verification" => [], "ci" => [], "review_rounds" => 4, "open_findings" => [],
      "publication_actions" => [], "resources" => {}, "open_risks" => [],
      "next_action" => "hand off"
    }.to_json
    before = File.read(@state_path)
    _out, stderr, exit_code = run_control("set-closeout", "--closeout-json", closeout,
                                          *fenced("coordinator", lease))
    assert_equal 1, exit_code
    assert_match(/review_remediation_rounds/i, stderr)
    assert_equal before, File.read(@state_path)
  end

  def test_advance_stage_requires_completed_attempt
    lease = acquire
    before = File.read(@state_path)
    _out, _err, exit_code = run_control("advance-stage", "TASK-001", "implemented", *fenced("coordinator", lease))
    assert_equal 1, exit_code
    assert_equal before, File.read(@state_path)
  end

  def test_advance_stage_forward_only
    lease = acquire
    attempt = {"attempt" => 1, "status" => "completed", "route" => "sonnet", "base_sha" => "c" * 40}.to_json
    run_control("record-attempt", "TASK-001", "--attempt-json", attempt, *fenced("coordinator", lease))
    _out, _err, exit_code = run_control("advance-stage", "TASK-001", "verified", *fenced("coordinator", lease))
    assert_equal 0, exit_code
    _out, _err, exit_code = run_control("advance-stage", "TASK-001", "implemented", *fenced("coordinator", lease))
    assert_equal 1, exit_code
    assert_equal "verified", read_state(@state_path)["tasks"]["TASK-001"]["stage"]
  end

  def test_advance_stage_blocked_while_circuit_open
    lease = acquire
    completed = {"attempt" => 1, "status" => "completed", "route" => "sonnet", "base_sha" => "c" * 40}.to_json
    run_control("record-attempt", "TASK-001", "--attempt-json", completed, *fenced("coordinator", lease))
    run_control("set-condition", "TASK-001", "circuit-open", *fenced("coordinator", lease))
    _out, _err, exit_code = run_control("advance-stage", "TASK-001", "implemented", *fenced("coordinator", lease))
    assert_equal 1, exit_code
  end

  def test_resource_lifecycle
    lease = acquire
    _out, _err, exit_code = run_control("record-resource", "wt-1", "--kind", "worktree",
                                        "--host-id", ".worktrees/t1", "--task", "TASK-001",
                                        *fenced("coordinator", lease))
    assert_equal 0, exit_code
    _out, _err, exit_code = run_control("set-resource-status", "wt-1", "cleaned", *fenced("coordinator", lease))
    assert_equal 0, exit_code
    assert_equal "cleaned", read_state(@state_path)["resources"]["wt-1"]["status"]
  end

  def test_cleanup_of_unrecorded_resource_rejected
    lease = acquire
    _out, stderr, exit_code = run_control("set-resource-status", "wt-ghost", "cleaned", *fenced("coordinator", lease))
    assert_equal 1, exit_code
    assert_match(/unknown resource/i, stderr)
  end

  def test_malformed_attempt_json_rejected_atomically
    lease = acquire
    before = File.read(@state_path)
    _out, _err, exit_code = run_control("record-attempt", "TASK-001", "--attempt-json", "{nope",
                                        *fenced("coordinator", lease))
    assert_equal 2, exit_code
    assert_equal before, File.read(@state_path)
  end

  def test_unknown_plan_task_rejected
    lease = acquire
    attempt = {"attempt" => 1, "status" => "completed", "route" => "sonnet", "base_sha" => "c" * 40}.to_json
    _out, stderr, exit_code = run_control("record-attempt", "TASK-999", "--attempt-json", attempt,
                                          *fenced("coordinator", lease))
    assert_equal 1, exit_code
    assert_match(/unknown plan task/i, stderr)
  end

  def test_plan_task_not_gated_by_host_allowlist
    state = base_state
    state["run"]["task_allowlist"] = ["ctx_hostid_abc123"]
    @state_path = write_state(@dir, state)
    lease = acquire
    attempt = {"attempt" => 1, "status" => "completed", "route" => "sonnet", "base_sha" => "c" * 40}.to_json
    _out, _err, exit_code = run_control("record-attempt", "TASK-001", "--attempt-json", attempt,
                                        *fenced("coordinator", lease))
    assert_equal 0, exit_code
  end

  def test_append_journal
    lease = acquire
    _out, _err, exit_code = run_control("append-journal", "wave 1 integrated", *fenced("coordinator", lease))
    assert_equal 0, exit_code
    assert_includes File.read(@state_path), "wave 1 integrated"
  end

  # --- publication expectation check (read-only) ---

  def test_check_remote_matches_absent_expectation
    _out, _err, exit_code = run_control("check-remote", "--observed", "absent")
    assert_equal 0, exit_code
  end

  def test_check_remote_mismatch_fails_closed
    _out, stderr, exit_code = run_control("check-remote", "--observed", "f" * 40)
    assert_equal 4, exit_code
    assert_match(/expectation/i, stderr)
  end
end
