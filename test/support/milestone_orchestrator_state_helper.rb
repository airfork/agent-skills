# Shared builders for milestone-orchestrator STATE/PLAN test documents.
require "json"

module MilestoneOrchestratorStateHelper
  SKILL_SCRIPTS = File.expand_path(
    File.join("..", "..", "skills", "general", "milestone-orchestrator", "scripts"), __dir__
  )

  def base_state
    {
      "schema_version" => 1,
      "run" => {
        "id" => "run-20260713-example",
        "slug" => "example",
        "epoch" => 1,
        "phase" => "running",
        "adapter" => "claude",
        "repository" => "/tmp/example",
        "coordinator_id" => "coordinator",
        "root_task_id" => "root",
        "task_allowlist" => ["TASK-001"],
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
        "worker_dispatches" => 35,
        "attempt_stall_checks" => 3
      },
      "tasks" => {
        "TASK-001" => {
          "type" => "implementation", "stage" => "pending", "condition" => "active",
          "failure_count" => 0, "attempts" => []
        }
      },
      "acceptance" => {},
      "findings" => {},
      "resources" => {},
      "reconciliations" => [],
      "closeout" => nil
    }
  end

  def write_state(dir, state)
    path = File.join(dir, "STATE.md")
    body = "# State\n\n<!-- milestone-orchestrator-state:v1 -->\n```json\n" \
           "#{JSON.pretty_generate(state)}\n```\n<!-- /milestone-orchestrator-state -->\n\n## Journal\n\n- init\n"
    File.write(path, body)
    path
  end

  def read_state(path)
    body = File.read(path)
    json = body[/```json\s*\n(.*?)```/m, 1]
    JSON.parse(json)
  end
end
