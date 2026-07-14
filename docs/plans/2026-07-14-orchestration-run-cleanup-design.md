# Orca Orchestration Run Cleanup Design

## Goal

Make teardown part of every supervised Orca orchestration run so completed, failed, cancelled, or blocked runs do not leave worker tabs or temporary workspaces behind.

## Resource Ownership

The coordinator records every worker terminal handle and temporary Orca worktree/workspace ID created during the run. This run-owned resource ledger is the authority for cleanup: never close the coordinator terminal, a pre-existing terminal, or a pre-existing workspace.

## Finalization Behavior

After collecting worker results and any required diagnostics, the coordinator must finalize the run before reporting completion:

1. Close every run-created worker terminal with `orca terminal close --terminal <handle> --json`.
2. Remove every run-created temporary worktree/workspace with `orca worktree rm --worktree <full-id> --json` after its changes are integrated, preserved, or explicitly discarded.
3. Re-list terminals and worktrees to verify that the recorded resources are gone.

Apply the same finalization path on success, failure, cancellation, or an unresolved blocker. Retain a run-created resource only when the user explicitly asks to keep it or removing it would risk losing dirty, unmerged, or otherwise unpreserved work. Report every retained resource by exact handle or worktree ID and explain why it remains.

Cleanup failure is visible run state. Do not claim that teardown is complete while a recorded resource remains.

## Scope

Update the installed skill at `/Users/tunji/.agents/skills/orchestration/SKILL.md`. Keep the existing Orca-first, lifecycle, provenance, and full-handoff rules unchanged.

The current main workspace is pre-existing and remains open. The worker terminals created by the preceding orchestration run should be closed after their results are confirmed captured; that run did not leave a temporary Orca worktree/workspace to remove.

## Validation

Use focused pressure scenarios to confirm that an agent reading the revised skill:

1. Tracks run-created terminal and worktree identifiers at creation time.
2. Closes worker tabs and removes safe temporary worktrees before reporting a successful run complete.
3. Performs the same teardown after failure or cancellation.
4. Preserves pre-existing resources and reports any unsafe-to-remove resource instead of force-removing it.

Validate the installed skill structure, inspect the focused diff, and verify the current run's worker terminals no longer appear in Orca's terminal list.
