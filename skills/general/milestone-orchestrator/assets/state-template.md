# <Milestone Title> — Execution State

The canonical block below is the machine-readable ledger; the journal at the
bottom is for humans. Update the block through coordinator adjudication only
and validate with `scripts/validate-state` after every material change.

<!-- milestone-orchestrator-state:v1 -->
```json
{
  "schema_version": 1,
  "run": {
    "id": "run-<YYYYMMDD>-<milestone-slug>",
    "slug": "<milestone-slug>",
    "epoch": 1,
    "phase": "preparing",
    "adapter": "<orca|codex|claude>",
    "repository": "<absolute-repository-path>",
    "coordinator_id": "<coordinator-handle>",
    "root_task_id": "<root-task-id>",
    "task_allowlist": [],
    "spec_sha256": "<64-hex>",
    "plan_sha256": "<64-hex>",
    "checkpoint_commit": "<git-oid>",
    "base_branch": "<base-branch>",
    "base_sha": "<git-oid>",
    "integration_branch": "milestone/<milestone-slug>",
    "replans": []
  },
  "authority": {
    "local_checkpoint": true,
    "implementation_commit": true,
    "push": true,
    "draft_pr": true,
    "pr_ready": false,
    "assign_reviewers": false,
    "merge": false,
    "deploy": false,
    "remote": "origin",
    "forge_repository": "<owner/repository>",
    "base_ref": "<base-branch>",
    "head_ref": "milestone/<milestone-slug>",
    "remote_ref_expectation": {"status": "absent", "base_oid": "<git-oid>"},
    "pr_identity": null
  },
  "budgets": {
    "transient_retries": 1,
    "task_failures": 3,
    "review_remediation_rounds": 3,
    "replans": 2,
    "ci_wait_seconds": 1800,
    "ci_infra_retries": 2,
    "no_progress_cycles": 2,
    "worker_dispatches": 0
  },
  "tasks": {},
  "acceptance": {},
  "findings": {},
  "resources": {},
  "reconciliations": [],
  "closeout": null
}
```
<!-- /milestone-orchestrator-state -->

## Journal

- <YYYY-MM-DDTHH:MM:SSZ> — Run initialized from approved SPEC/PLAN.
