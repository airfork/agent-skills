# Canonical STATE and PLAN Contracts

`PLAN.md` and `STATE.md` each embed one versioned canonical JSON block between
HTML comment markers. Surrounding Markdown is human-readable context only; the
JSON blocks are the machine source of truth. `scripts/validate-state` checks
the STATE block (and cross-checks the PLAN block when given `--plan`); run it
after every material STATE update and before publication.

Templates may use angle-bracket instructional tokens (`<like-this>`); an
initialized RUN state may not contain unresolved tokens.

## PLAN canonical block

````markdown
<!-- milestone-orchestrator-plan:v1 -->
```json
{
  "schema_version": 1,
  "requirements": {
    "AC-001": {"summary": "Example acceptance criterion"}
  },
  "tasks": {
    "TASK-001": {
      "type": "implementation",
      "depends_on": [],
      "owned_paths": ["lib/example.rb"],
      "acceptance_ids": ["AC-001"],
      "verification_command_ids": ["verify-example"]
    }
  },
  "verification_commands": {
    "verify-example": {
      "argv": ["ruby", "test/example_test.rb"],
      "cwd": ".",
      "timeout_seconds": 120,
      "acceptance_ids": ["AC-001"]
    }
  }
}
```
<!-- /milestone-orchestrator-plan -->
````

Rules: argv arrays only (no shell strings); relative non-escaping `cwd`; no
duplicate IDs or dangling references; task `type` is one of `implementation`,
`review`, `verification`, `integration`, `cleanup`. Two implementation tasks
that can run concurrently must not share `owned_paths`. Verification workers
run only registered command IDs from the approved PLAN digest recorded in
STATE — never worker-supplied command lines.

## STATE canonical block

````markdown
<!-- milestone-orchestrator-state:v1 -->
```json
{
  "schema_version": 1,
  "run": {
    "id": "run-20260713-example",
    "slug": "example",
    "epoch": 1,
    "phase": "prepared",
    "adapter": "orca",
    "repository": "/absolute/repository/path",
    "coordinator_id": "coordinator-handle",
    "root_task_id": "root-task-id",
    "task_allowlist": [],
    "spec_sha256": "<64-hex>",
    "plan_sha256": "<64-hex>",
    "checkpoint_commit": "<git-oid>",
    "base_branch": "main",
    "base_sha": "<git-oid>",
    "integration_branch": "milestone/example",
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
    "forge_repository": "owner/repository",
    "base_ref": "main",
    "head_ref": "milestone/example",
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
    "no_progress_cycles": 2
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
````

### Enums

| Field | Legal values |
|-------|--------------|
| `run.phase` | `preparing`, `prepared`, `running`, `publishing`, `aborting`, `blocked`, `closed` |
| `run.adapter` | `orca`, `codex`, `claude` |
| task `stage` | `pending`, `implemented`, `reviewed`, `verified`, `integrated`, `closed` |
| task `condition` | `active`, `blocked`, `failed`, `circuit-open`, `cleanup-pending`, `retained` |
| attempt `status` | `created`, `dispatched`, `completed`, `failed`, `blocked`, `abandoned` |
| resource `kind` | `worktree`, `terminal`, `browser-tab` |

`merge` and `deploy` must be `false` in every state; a true value is a
validation failure, not a configuration option.

### Task entries

```json
"TASK-001": {
  "type": "implementation",
  "stage": "implemented",
  "condition": "active",
  "failure_count": 0,
  "attempts": [
    {
      "attempt": 1,
      "status": "completed",
      "host_task_id": "orca-task-id",
      "dispatch_id": "dispatch-id",
      "route": "claude-sonnet-high",
      "base_sha": "<git-oid>",
      "result_commits": ["<git-oid>"],
      "evidence": "structured worker summary or command result reference"
    }
  ]
}
```

Stages advance forward only (`pending -> implemented -> reviewed -> verified
-> integrated -> closed` for implementation tasks; review/verification/
integration/cleanup tasks may go `pending -> verified/integrated/closed` as
their type allows). A stage may advance only when the latest attempt is
`completed` and the coordinator recorded its adjudication evidence.

### Resource entries

```json
"wt-TASK-001": {
  "kind": "worktree",
  "host_id": "full-host-worktree-id",
  "created_by_run": "run-20260713-example",
  "created_at": "2026-07-13T12:00:00Z",
  "plan_task_id": "TASK-001",
  "status": "active"
}
```

`status`: `active`, `cleaned`, `retained`. A resource is lifecycle-owned only
when creation provenance and current host identity both match. Cleanup rules
live in [platform-adapters.md](platform-adapters.md).

### Closeout record

`run.phase = "closed"` is illegal unless `closeout` is an object containing:
`branch`, `head_sha`, `pr` (id/url or explicit `null` with recorded opt-out),
`verification` (commands and results), `ci` (checks and terminal states),
`review_rounds`, `open_findings` (must be empty of merge-blocking entries),
`publication_actions`, `resources` (each `cleaned` or `retained` with reason),
`open_risks`, and `next_action` (the exact step still requiring user
authority). Merge and deploy must remain unexecuted.

## Field-specific sources of truth

When STATE disagrees with the world, repair STATE from the authoritative
source and append a `reconciliations` entry with old value, new value,
evidence, actor, and timestamp:

| Fact | Owner |
|------|-------|
| Commit reachability, file state | Git |
| Test results | Fresh verification runs of registered commands |
| Review completion | Host review records |
| Runtime lifecycle identity | Active host `taskId` + `dispatchId` |
| Remote refs and PR state | The forge |
| Permissions | The approved authority envelope only |
| Resource identity | Creation provenance + current host listings jointly |

Never infer review completion, authority, dispatch identity, or safe cleanup
from Git. Cross-source contradictions resolve conservatively.

## Recovery after runtime loss

Exact runtime resurrection is not required. Reconstruct from Git, PLAN, STATE,
verification evidence, and any surviving host state:

1. Increment `run.epoch`.
2. Inventory worktrees, terminals, and tabs; re-resolve runtime-scoped
   handles.
3. Validate each active task/dispatch against current host listings; fence or
   abandon stale dispatches before resuming.
4. Deduplicate outputs by commit and evidence.
5. Never use runtime-global reset; reconcile only the recorded run allowlist
   and leave foreign tasks, messages, and resources untouched.
