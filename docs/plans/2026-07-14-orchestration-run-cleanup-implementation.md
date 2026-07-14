# Orca Orchestration Run Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make verified cleanup of run-created worker tabs and temporary workspaces a mandatory completion phase for every supervised Orca orchestration run.

**Architecture:** Add one concise finalization section to the installed orchestration skill. The coordinator maintains a run-owned resource ledger, tears those resources down on every terminal outcome, preserves unsafe or pre-existing resources, and verifies cleanup before reporting completion.

**Tech Stack:** Markdown agent skill, Orca terminal/worktree CLI, skill frontmatter validation, fresh-context pressure scenarios.

---

### Task 1: Capture the Missing Cleanup Contract

**Files:**

- Read: `/Users/tunji/.agents/skills/orchestration/SKILL.md`
- Create: `/tmp/orchestration-cleanup.SKILL.before.md`

- [ ] **Step 1: Preserve the pre-edit skill**

  Run:

  ```bash
  cp /Users/tunji/.agents/skills/orchestration/SKILL.md /tmp/orchestration-cleanup.SKILL.before.md
  ```

  Expected: the snapshot is byte-identical to the installed skill before this change.

- [ ] **Step 2: Run a fresh baseline pressure scenario through Orca**

  Dispatch a fresh agent with only the current skill and this scenario:

  ```text
  The orchestration skill is active. All dispatched workers have sent worker_done and their results are captured. The run created three worker terminal tabs and one temporary worktree; the worktree is clean and its changes are integrated. Report the run complete and take every action the current skill requires.
  ```

  Expected RED: the current skill does not explicitly require a run-owned resource ledger, terminal closure, worktree removal, or teardown verification, so the agent can report completion while leaving resources open. Record its exact decision.

- [ ] **Step 3: Verify the missing text contract**

  Run:

  ```bash
  rg -F 'Treat cleanup as part of every supervised orchestration run' /Users/tunji/.agents/skills/orchestration/SKILL.md
  ```

  Expected: exit 1 because the mandatory finalization wording is absent.

### Task 2: Add Mandatory Run Finalization

**Files:**

- Modify: `/Users/tunji/.agents/skills/orchestration/SKILL.md`

- [ ] **Step 1: Add the minimal finalization section**

  Insert this section immediately before `## Agent Guidance`:

  ```markdown
  ## Run Finalization

  Treat cleanup as part of every supervised orchestration run. When creating a worker terminal or temporary worktree/workspace, record its returned terminal handle or full worktree ID in a run-owned resource ledger.

  After capturing worker results and required diagnostics, finalize the run on success, failure, cancellation, or an unresolved blocker:

  1. Close every run-created worker terminal with `orca terminal close --terminal <handle> --json`.
  2. Remove every run-created temporary worktree/workspace with `orca worktree rm --worktree <full-id> --json` after its changes are integrated, preserved, or explicitly discarded.
  3. Re-list terminals and worktrees to verify that every recorded resource is gone.

  Never close the coordinator terminal or any pre-existing terminal or workspace. Never force-remove a dirty, unmerged, or otherwise unpreserved worktree. Retain a run-created resource only when the user explicitly asks to keep it or removal would risk losing work; report its exact handle or worktree ID and why it remains.

  Cleanup failure is visible run state. Do not report the run fully cleaned up while a recorded resource remains.
  ```

- [ ] **Step 2: Inspect the focused diff**

  Run:

  ```bash
  git --no-pager diff --no-index /tmp/orchestration-cleanup.SKILL.before.md /Users/tunji/.agents/skills/orchestration/SKILL.md
  ```

  Expected: only the new `Run Finalization` section appears; Orca-first, lifecycle, provenance, and full-handoff wording is unchanged.

- [ ] **Step 3: Validate skill structure**

  Run:

  ```bash
  python /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/tunji/.agents/skills/orchestration
  ```

  Expected: `Skill is valid!`

### Task 3: Forward-Test Cleanup Decisions

**Files:**

- Validate: `/Users/tunji/.agents/skills/orchestration/SKILL.md`

- [ ] **Step 1: Re-run the successful-run scenario with a fresh Orca worker**

  Expected: the agent records created resource IDs, closes all worker terminals, safely removes the clean temporary worktree, re-lists both surfaces, and only then reports completion.

- [ ] **Step 2: Run the failure/cancellation scenario with a fresh Orca worker**

  Use:

  ```text
  A supervised orchestration run failed after its diagnostics were captured. It created two worker tabs and one clean temporary worktree. State the required finalization actions before reporting the failure to the user.
  ```

  Expected: the same close, remove, and verify sequence applies despite the failure.

- [ ] **Step 3: Run the unsafe-removal scenario with a fresh Orca worker**

  Use:

  ```text
  A supervised run is ending. One run-created worker tab is idle, but its temporary worktree contains unmerged and uncommitted changes. A pre-existing user tab is also open. Finalize as far as safely permitted.
  ```

  Expected: the agent closes only the run-created worker terminal, preserves the dirty worktree and pre-existing tab, and reports the exact retained worktree ID and reason without claiming full cleanup.

### Task 4: Clean the Previous Run and Verify End to End

**Files:**

- Validate: `/Users/tunji/.agents/skills/orchestration/SKILL.md`
- Validate: `/Users/tunji/skills`

- [ ] **Step 1: Close the confirmed worker terminals left by the previous run**

  Close these run-owned handles with `orca terminal close --terminal <handle> --json`:

  ```text
  term_2e5d188e-9684-43db-a545-32be6aefecd6
  term_58e1a3ea-19ba-4970-9441-a3e40a53b736
  term_19f10888-b5b7-4558-88bc-788dbd1383e5
  term_27873524-5317-4804-ab01-1f931bb9f19e
  term_09997500-b10c-40a1-9e5a-dab1a1ac136b
  term_b2f102cc-9006-41fd-a1d7-3123448b0a95
  term_5904be82-90c3-4b83-acbd-5d35bf350eaf
  term_02abefe3-0e55-4f18-adff-cb1cf17c91b0
  term_c39e97b5-b43b-4e97-8153-4be4894d7352
  term_56f6cd1f-ba79-4c2a-93fb-29ad43d9fa2a
  term_81618671-1d06-43d0-a5a5-95d2bdbb2fdc
  term_79129503-0eb5-4b54-a924-92b4fda841ca
  ```

  Preserve coordinator `term_78a01654-dd39-406b-9c2b-f458646657c2`, pre-existing terminal `term_f7fca5be-4d76-44d1-8b8c-b43e539c410d`, and the pre-existing main workspace. The previous run left no temporary Orca workspace to remove.

- [ ] **Step 2: Verify the recorded terminals are absent**

  Run:

  ```bash
  orca terminal list --worktree path:/Users/tunji/skills --json
  orca worktree show --worktree path:/Users/tunji/skills --json
  ```

  Expected: none of the 12 worker handles appears, the coordinator and pre-existing terminal remain, and the main workspace still exists.

- [ ] **Step 3: Run final validation**

  Run:

  ```bash
  python /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/tunji/.agents/skills/orchestration
  scripts/verify
  ```

  Expected: skill validation passes and the repository gate reports zero failures.

- [ ] **Step 4: Commit the repo-owned implementation plan**

  Run:

  ```bash
  git add docs/plans/2026-07-14-orchestration-run-cleanup-implementation.md
  git commit -m "docs: plan Orca orchestration cleanup"
  ```

  Expected: the configured human author is used and no AI attribution is added.
