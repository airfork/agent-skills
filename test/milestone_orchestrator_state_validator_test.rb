require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "rbconfig"

class MilestoneOrchestratorStateValidatorTest < Minitest::Test
  REPO = File.expand_path("..", __dir__)
  VALIDATOR = File.join(REPO, "skills", "general", "milestone-orchestrator", "scripts", "validate-state")

  def valid_state
    {
      "schema_version" => 1,
      "run" => {
        "id" => "run-20260713-example",
        "slug" => "example",
        "epoch" => 1,
        "phase" => "prepared",
        "adapter" => "orca",
        "repository" => "/tmp/example",
        "coordinator_id" => "coordinator",
        "root_task_id" => "root",
        "task_allowlist" => [],
        "spec_sha256" => "a" * 64,
        "plan_sha256" => "b" * 64,
        "checkpoint_commit" => "c" * 40,
        "base_branch" => "main",
        "base_sha" => "d" * 40,
        "integration_branch" => "milestone/example",
        "replans" => []
      },
      "authority" => {
        "local_checkpoint" => true,
        "implementation_commit" => true,
        "push" => true,
        "draft_pr" => true,
        "pr_ready" => false,
        "assign_reviewers" => false,
        "merge" => false,
        "deploy" => false,
        "remote" => "origin",
        "forge_repository" => "owner/repo",
        "base_ref" => "main",
        "head_ref" => "milestone/example",
        "remote_ref_expectation" => {"status" => "absent", "base_oid" => "d" * 40},
        "pr_identity" => nil
      },
      "budgets" => {
        "transient_retries" => 1,
        "task_failures" => 3,
        "review_remediation_rounds" => 3,
        "replans" => 2,
        "ci_wait_seconds" => 1800,
        "ci_infra_retries" => 2,
        "no_progress_cycles" => 2,
        "worker_dispatches" => 35
      },
      "tasks" => {},
      "acceptance" => {},
      "findings" => {},
      "resources" => {},
      "reconciliations" => [],
      "closeout" => nil
    }
  end

  def valid_plan
    {
      "schema_version" => 1,
      "requirements" => {"AC-001" => {"summary" => "example"}},
      "tasks" => {
        "TASK-001" => {
          "type" => "implementation",
          "depends_on" => [],
          "owned_paths" => ["lib/example.rb"],
          "acceptance_ids" => ["AC-001"],
          "verification_command_ids" => ["verify-example"]
        }
      },
      "verification_commands" => {
        "verify-example" => {
          "argv" => ["ruby", "test/example_test.rb"],
          "cwd" => ".",
          "timeout_seconds" => 120,
          "acceptance_ids" => ["AC-001"]
        }
      }
    }
  end

  def wrap_state(json)
    "# State\n\n<!-- milestone-orchestrator-state:v1 -->\n```json\n#{JSON.pretty_generate(json)}\n```\n<!-- /milestone-orchestrator-state -->\n"
  end

  def wrap_plan(json)
    "# Plan\n\n<!-- milestone-orchestrator-plan:v1 -->\n```json\n#{JSON.pretty_generate(json)}\n```\n<!-- /milestone-orchestrator-plan -->\n"
  end

  def run_validator(state_markdown, plan_markdown: nil, extra_args: [])
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "STATE.md")
      File.write(state_path, state_markdown)
      args = [state_path, "--json"]
      if plan_markdown
        plan_path = File.join(dir, "PLAN.md")
        File.write(plan_path, plan_markdown)
        args += ["--plan", plan_path]
      end
      args += extra_args
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, VALIDATOR, *args)
      [JSON.parse(stdout), stderr, status.exitstatus]
    end
  end

  def error_codes(report)
    report.fetch("errors").map { |e| e.fetch("code") }
  end

  def test_valid_state_passes
    report, _stderr, exit_code = run_validator(wrap_state(valid_state))
    assert_equal 0, exit_code
    assert_equal true, report.fetch("valid")
    assert_equal [], report.fetch("errors")
  end

  def test_valid_state_and_plan_pass_together
    report, _stderr, exit_code = run_validator(wrap_state(valid_state), plan_markdown: wrap_plan(valid_plan))
    assert_equal 0, exit_code
    assert_equal true, report.fetch("valid")
  end

  def test_missing_canonical_block_fails
    report, _stderr, exit_code = run_validator("# State\n\nno block here\n")
    assert_equal 1, exit_code
    assert_includes error_codes(report), "missing_state_block"
  end

  def test_malformed_json_fails
    markdown = "<!-- milestone-orchestrator-state:v1 -->\n```json\n{nope}\n```\n<!-- /milestone-orchestrator-state -->\n"
    report, _stderr, exit_code = run_validator(markdown)
    assert_equal 1, exit_code
    assert_includes error_codes(report), "invalid_json"
  end

  def test_unknown_schema_version_fails_closed
    state = valid_state
    state["schema_version"] = 2
    report, _stderr, exit_code = run_validator(wrap_state(state))
    assert_equal 1, exit_code
    assert_includes error_codes(report), "unsupported_schema_version"
  end

  def test_illegal_phase_rejected
    state = valid_state
    state["run"]["phase"] = "cruising"
    report, _stderr, _exit = run_validator(wrap_state(state))
    assert_includes error_codes(report), "invalid_enum"
  end

  def test_merge_authority_always_rejected
    state = valid_state
    state["authority"]["merge"] = true
    report, _stderr, _exit = run_validator(wrap_state(state))
    assert_includes error_codes(report), "forbidden_authority"
  end

  def test_deploy_authority_always_rejected
    state = valid_state
    state["authority"]["deploy"] = true
    report, _stderr, _exit = run_validator(wrap_state(state))
    assert_includes error_codes(report), "forbidden_authority"
  end

  def test_unresolved_template_tokens_rejected
    state = valid_state
    state["run"]["checkpoint_commit"] = "<git-oid>"
    report, _stderr, _exit = run_validator(wrap_state(state))
    assert_includes error_codes(report), "unresolved_template_token"
  end

  def test_missing_budget_rejected
    state = valid_state
    state["budgets"].delete("replans")
    report, _stderr, _exit = run_validator(wrap_state(state))
    assert_includes error_codes(report), "missing_budget"
  end

  def test_task_with_invalid_stage_rejected
    state = valid_state
    state["tasks"]["TASK-001"] = {
      "type" => "implementation", "stage" => "polished", "condition" => "active",
      "failure_count" => 0, "attempts" => []
    }
    report, _stderr, _exit = run_validator(wrap_state(state))
    assert_includes error_codes(report), "invalid_enum"
  end

  def test_advanced_stage_without_completed_attempt_rejected
    state = valid_state
    state["tasks"]["TASK-001"] = {
      "type" => "implementation", "stage" => "implemented", "condition" => "active",
      "failure_count" => 0, "attempts" => [
        {"attempt" => 1, "status" => "dispatched", "route" => "claude", "base_sha" => "d" * 40}
      ]
    }
    report, _stderr, _exit = run_validator(wrap_state(state))
    assert_includes error_codes(report), "stage_without_completed_attempt"
  end

  def test_closed_phase_requires_closeout
    state = valid_state
    state["run"]["phase"] = "closed"
    report, _stderr, _exit = run_validator(wrap_state(state))
    assert_includes error_codes(report), "incomplete_closeout"
  end

  def test_closed_phase_with_complete_closeout_passes
    state = valid_state
    state["run"]["phase"] = "closed"
    state["closeout"] = {
      "branch" => "milestone/example",
      "head_sha" => "e" * 40,
      "pr" => {"id" => 1, "url" => "https://example.test/pr/1"},
      "verification" => [{"command_id" => "verify-example", "result" => "pass"}],
      "ci" => [{"check" => "fixture-ci", "state" => "success"}],
      "review_rounds" => 1,
      "open_findings" => [],
      "publication_actions" => ["push", "draft_pr"],
      "resources" => {},
      "open_risks" => [],
      "next_action" => "user decides whether to mark the PR ready and merge"
    }
    report, _stderr, exit_code = run_validator(wrap_state(state))
    assert_equal [], error_codes(report)
    assert_equal 0, exit_code
  end

  def test_plan_shell_string_argv_rejected
    plan = valid_plan
    plan["verification_commands"]["verify-example"]["argv"] = "ruby test/example_test.rb"
    report, _stderr, _exit = run_validator(wrap_state(valid_state), plan_markdown: wrap_plan(plan))
    assert_includes error_codes(report), "invalid_argv"
  end

  def test_plan_escaping_cwd_rejected
    plan = valid_plan
    plan["verification_commands"]["verify-example"]["cwd"] = "../outside"
    report, _stderr, _exit = run_validator(wrap_state(valid_state), plan_markdown: wrap_plan(plan))
    assert_includes error_codes(report), "invalid_cwd"
  end

  def test_plan_dangling_reference_rejected
    plan = valid_plan
    plan["tasks"]["TASK-001"]["depends_on"] = ["TASK-404"]
    report, _stderr, _exit = run_validator(wrap_state(valid_state), plan_markdown: wrap_plan(plan))
    assert_includes error_codes(report), "dangling_reference"
  end

  def test_plan_concurrent_ownership_overlap_rejected
    plan = valid_plan
    plan["tasks"]["TASK-002"] = {
      "type" => "implementation",
      "depends_on" => [],
      "owned_paths" => ["lib/example.rb"],
      "acceptance_ids" => ["AC-001"],
      "verification_command_ids" => ["verify-example"]
    }
    report, _stderr, _exit = run_validator(wrap_state(valid_state), plan_markdown: wrap_plan(plan))
    assert_includes error_codes(report), "ownership_overlap"
  end

  def test_plan_serialized_ownership_overlap_allowed
    plan = valid_plan
    plan["tasks"]["TASK-002"] = {
      "type" => "implementation",
      "depends_on" => ["TASK-001"],
      "owned_paths" => ["lib/example.rb"],
      "acceptance_ids" => ["AC-001"],
      "verification_command_ids" => ["verify-example"]
    }
    report, _stderr, exit_code = run_validator(wrap_state(valid_state), plan_markdown: wrap_plan(plan))
    assert_equal [], error_codes(report)
    assert_equal 0, exit_code
  end
end
