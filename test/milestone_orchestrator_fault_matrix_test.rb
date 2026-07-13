require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "rbconfig"
require_relative "support/milestone_orchestrator_state_helper"

# Deterministic control-plane fault matrix (validation layer 3, harness slice).
# Each case injects one fault and asserts the exact allowed action, forbidden
# action, ledger outcome, and file atomicity. Live-agent faults (worker
# silence, runtime loss with real agents) are exercised by the real-repo
# pilot, not here.
class MilestoneOrchestratorFaultMatrixTest < Minitest::Test
  include MilestoneOrchestratorStateHelper

  CONTROL = File.join(MilestoneOrchestratorStateHelper::SKILL_SCRIPTS, "control-state")
  VALIDATOR = File.join(MilestoneOrchestratorStateHelper::SKILL_SCRIPTS, "validate-state")

  def setup
    @dir = Dir.mktmpdir
    @lease_dir = File.join(@dir, "lease")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_control(state_path, *args)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, CONTROL, state_path, *args, "--lease-dir", @lease_dir
    )
    [stdout, stderr, status.exitstatus]
  end

  def run_validator(state_path)
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, VALIDATOR, state_path, "--json")
    [JSON.parse(stdout), status.exitstatus]
  end

  def with_lease(state_path, owner = "coordinator")
    stdout, _stderr, exit_code = run_control(state_path, "acquire-lease", "--owner", owner, "--ttl", "300")
    raise "acquire failed" unless exit_code.zero?
    lease = JSON.parse(stdout)
    ["--owner", owner, "--token", lease.fetch("fencing_token").to_s]
  end

  # FAULT: worker_done arrives but the payload reports failure.
  # Allowed: record the failed attempt. Forbidden: stage advance.
  def test_fault_false_completion_cannot_release_stage
    state_path = write_state(@dir, base_state)
    fence = with_lease(state_path)
    failed = {"attempt" => 1, "status" => "failed", "route" => "sonnet", "base_sha" => "c" * 40,
              "evidence" => "worker_done payload reported test failures"}.to_json
    _out, _err, exit_code = run_control(state_path, "record-attempt", "TASK-001", "--attempt-json", failed, *fence)
    assert_equal 0, exit_code, "recording the failed attempt is allowed"
    _out, _err, exit_code = run_control(state_path, "advance-stage", "TASK-001", "implemented", *fence)
    assert_equal 1, exit_code, "failed attempt must not advance the durable stage"
    state = read_state(state_path)
    assert_equal "pending", state["tasks"]["TASK-001"]["stage"]
    assert_equal 1, state["tasks"]["TASK-001"]["failure_count"]
  end

  # FAULT: three consecutive failures. Ledger: circuit-open; further work fenced.
  def test_fault_failure_budget_exhaustion_opens_circuit
    state_path = write_state(@dir, base_state)
    fence = with_lease(state_path)
    3.times do |i|
      failed = {"attempt" => i + 1, "status" => "failed", "route" => "sonnet", "base_sha" => "c" * 40}.to_json
      run_control(state_path, "record-attempt", "TASK-001", "--attempt-json", failed, *fence)
    end
    state = read_state(state_path)
    assert_equal "circuit-open", state["tasks"]["TASK-001"]["condition"]
    completed = {"attempt" => 4, "status" => "completed", "route" => "opus", "base_sha" => "c" * 40}.to_json
    _out, stderr, exit_code = run_control(state_path, "record-attempt", "TASK-001", "--attempt-json", completed, *fence)
    assert_equal 1, exit_code, "new attempts while circuit-open require an explicit condition reset"
    assert_match(/circuit/i, stderr)
  end

  # FAULT: coordinator restart / split brain — old epoch keeps writing.
  def test_fault_stale_epoch_cannot_mutate
    state_path = write_state(@dir, base_state)
    run_control(state_path, "acquire-lease", "--owner", "coordinator-a", "--ttl", "0")
    run_control(state_path, "acquire-lease", "--owner", "coordinator-b", "--ttl", "300")
    before = File.read(state_path)
    _out, _err, exit_code = run_control(state_path, "set-phase", "aborting",
                                        "--owner", "coordinator-a", "--token", "1")
    assert_equal 3, exit_code
    assert_equal before, File.read(state_path), "stale-epoch write must not touch the ledger"
  end

  # FAULT: cleanup requested for a resource the run never recorded.
  def test_fault_foreign_resource_cleanup_rejected
    state_path = write_state(@dir, base_state)
    fence = with_lease(state_path)
    _out, _err, exit_code = run_control(state_path, "set-resource-status", "wt-foreign", "cleaned", *fence)
    assert_equal 1, exit_code
  end

  # FAULT: publication attempted when the remote ref moved under us.
  def test_fault_remote_expectation_mismatch_blocks_publication
    state = base_state
    state["authority"]["remote_ref_expectation"] = {"status" => "present", "oid" => "1" * 40}
    state_path = write_state(@dir, state)
    _out, _err, exit_code = run_control(state_path, "check-remote", "--observed", "2" * 40)
    assert_equal 4, exit_code
    _out, _err, exit_code = run_control(state_path, "check-remote", "--observed", "1" * 40)
    assert_equal 0, exit_code
  end

  # FAULT: closeout attempted with an open merge-blocking finding.
  def test_fault_closeout_with_open_findings_rejected
    state_path = write_state(@dir, base_state)
    fence = with_lease(state_path)
    closeout = {
      "branch" => "milestone/example", "head_sha" => "e" * 40,
      "pr" => {"id" => 1, "url" => "https://example.test/1"},
      "verification" => [], "ci" => [], "review_rounds" => 1,
      "open_findings" => [{"id" => "F1", "severity" => "blocking"}],
      "publication_actions" => [], "resources" => {}, "open_risks" => [],
      "next_action" => "n/a"
    }.to_json
    run_control(state_path, "set-closeout", "--closeout-json", closeout, *fence)
    before = File.read(state_path)
    _out, _err, exit_code = run_control(state_path, "set-phase", "closed", *fence)
    assert_equal 1, exit_code, "closed with open findings must fail"
    assert_equal before, File.read(state_path)
  end

  # FAULT: authority escalation smuggled through a closeout/state edit.
  def test_fault_merge_authority_never_validates
    state = base_state
    state["authority"]["merge"] = true
    state_path = write_state(@dir, state)
    report, exit_code = run_validator(state_path)
    assert_equal 1, exit_code
    assert_includes report["errors"].map { |e| e["code"] }, "forbidden_authority"
  end

  # FAULT: abort during publication. Allowed: publishing -> aborting.
  # Ledger: journal records the abort; closed remains gated on closeout.
  def test_fault_cancellation_from_publishing
    state = base_state
    state["run"]["phase"] = "publishing"
    state_path = write_state(@dir, state)
    fence = with_lease(state_path)
    _out, _err, exit_code = run_control(state_path, "set-phase", "aborting", *fence)
    assert_equal 0, exit_code
    _out, _err, exit_code = run_control(state_path, "append-journal", "user cancellation: dispatch revoked", *fence)
    assert_equal 0, exit_code
    _out, _err, exit_code = run_control(state_path, "set-phase", "closed", *fence)
    assert_equal 1, exit_code, "abort cannot jump to closed without a complete closeout"
  end

  # FAULT: recovery after runtime loss must advance the epoch before resuming.
  def test_fault_recovery_requires_new_epoch
    state_path = write_state(@dir, base_state)
    run_control(state_path, "acquire-lease", "--owner", "coordinator-a", "--ttl", "0")
    stdout, _err, exit_code = run_control(state_path, "acquire-lease", "--owner", "coordinator-a2", "--ttl", "300")
    assert_equal 0, exit_code
    takeover = JSON.parse(stdout)
    assert_operator takeover["epoch"], :>, 1, "takeover must advance the run epoch"
    fence = ["--owner", "coordinator-a2", "--token", takeover["fencing_token"].to_s]
    _out, _err, exit_code = run_control(state_path, "set-epoch", takeover["epoch"].to_s, *fence)
    assert_equal 0, exit_code
    assert_equal takeover["epoch"], read_state(state_path)["run"]["epoch"]
  end
end
