# Orca Orchestration Run Cleanup Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make supervised Orca teardown exhaustive without treating unrelated tabs as run-owned, even when workspace creation opens configured tabs or a terminal handle changes.

**Architecture:** Keep the installed orchestration skill as the only runtime artifact. Give the coordinator sole authority to create Orca terminals and worktrees; record stable pane identity for terminals created in pre-existing worktrees, and treat every terminal inside a run-created worktree as run-owned. Reconcile each ledger entry with scoped, non-truncated reads before reporting cleanup, then reduce duplicated handoff classification and make the canonical example demonstrate complete teardown.

**Tech Stack:** Markdown agent skill, Orca terminal/worktree/orchestration CLI, skill frontmatter validation, fresh-context Orca pressure scenarios, repository verification scripts.

---

## Scope and invariants

**Runtime file:**

- Modify: `/Users/tunji/.agents/skills/orchestration/SKILL.md`

**Repository artifacts:**

- Track: `docs/plans/2026-07-14-orchestration-run-cleanup-hardening-implementation.md`
- Track: `docs/plans/2026-07-14-orchestration-run-cleanup-hardening-implementation-review.md`

**Grounding:**

- Read: `docs/plans/2026-07-14-orchestration-run-cleanup-design.md`
- Read: `docs/plans/2026-07-14-orchestration-run-cleanup-implementation.md`
- Read: `AGENTS.md`
- Read: `COMMANDS.md`

Do not add scripts, references, `agents/openai.yaml`, catalog entries, install metadata, or global symlink changes. Do not change frontmatter, Orca-first fallback behavior, lifecycle authority, or the Computer Use boundary. If a forward test proves that any out-of-scope surface must change, stop and report a follow-up rather than broadening this implementation.

Preserve these invariants:

1. When orchestration is active and Orca is available, workers are created and supervised through Orca.
2. If Orca is unavailable, stop and ask before using native subagent tools.
3. Full ownership handoffs use `orca-cli` behavior and are not monitored or finalized as supervised runs.
4. The coordinator never closes its own terminal, a pre-existing terminal/workspace, or a resource whose run ownership cannot be proven.
5. Dirty, unmerged, or otherwise unpreserved worktrees are retained and reported, never force-removed.
6. Cleanup runs after success, failure, cancellation, and unresolved blockers, after results and diagnostics are captured.

### Task 1: Preserve evidence and prove the current text gaps

**Files:**

- Read: `/Users/tunji/.agents/skills/orchestration/SKILL.md`
- Create: unique temporary snapshot and evidence files under `${TMPDIR:-/tmp}`

- [ ] **Step 1: Create a non-destructive pre-edit snapshot and evidence packet**

  Run once and record both printed paths in the implementation thread:

  ```bash
  rtk zsh -lc 'set -euo pipefail; before="$(mktemp "${TMPDIR:-/tmp}/orchestration-cleanup-hardening.XXXXXX.before.md")"; evidence="$(mktemp "${TMPDIR:-/tmp}/orchestration-cleanup-hardening.XXXXXX.evidence.md")"; cp /Users/tunji/.agents/skills/orchestration/SKILL.md "$before"; printf "# Orchestration cleanup hardening evidence\n\n## Baseline\n\n" > "$evidence"; print -r -- "BEFORE=$before"; print -r -- "EVIDENCE=$evidence"'
  ```

  Expected: two new unique paths are printed. Never overwrite either file on retry; reuse the recorded `BEFORE` path for all diffs and the recorded `EVIDENCE` path for all scenario outputs.

- [ ] **Step 2: Verify the snapshot before editing**

  Substitute the printed snapshot path and run:

  ```bash
  rtk shasum -a 256 /Users/tunji/.agents/skills/orchestration/SKILL.md <before-path>
  ```

  Expected: both digests match.

- [ ] **Step 3: Capture current Orca field and pagination contracts**

  Run and append the relevant output to the evidence packet:

  ```bash
  rtk orca worktree create --help
  rtk orca terminal list --help
  rtk orca terminal show --help
  rtk orca worktree list --help
  rtk orca worktree show --help
  rtk orca orchestration dispatch-show --help
  ```

  Expected evidence:

  - Current agent-backed worktree creation returns `result.agentTerminalHandle`; legacy runtimes may expose only `result.startupTerminal.handle`.
  - Terminal and worktree list commands support bounded output and report whether results are truncated.
  - Dispatch state exposes the assigned pane identity, and terminal rows expose `tabId` and `leafId` from which the pane key is formed as `<tabId>:<leafId>`.

- [ ] **Step 4: Run deterministic missing-contract checks**

  Run each command independently:

  ```bash
  rtk rg -F 'agentTerminalHandle' /Users/tunji/.agents/skills/orchestration/SKILL.md
  rtk rg -F 'assignee_pane_key' /Users/tunji/.agents/skills/orchestration/SKILL.md
  rtk rg -F 'Workers must not create additional Orca terminals or worktrees' /Users/tunji/.agents/skills/orchestration/SKILL.md
  ```

  Expected RED: each command exits 1 before the edit. Record the actual exit status in the evidence packet.

- [ ] **Step 5: Run three neutral baseline pressure scenarios**

  Use fresh Orca workers with only the current skill and one scenario each:

  ```text
  A supervised run creates a temporary worktree whose configuration materializes an agent tab and two additional tabs. All results are captured. State the exact ownership ledger and finalization actions.
  ```

  ```text
  A supervised run recorded a terminal handle. Orca reminted that pane, so the handle is stale while a replacement for the dispatched pane exists. Finalize safely.
  ```

  ```text
  A supervised worker needs another Orca terminal and temporary worktree to finish its task. State who creates them, how ownership is recorded, and how they are finalized.
  ```

  Record each exact `taskId`, `dispatchId`, message ID, prompt, and response in the evidence packet. Label the observed result `RED` only when it demonstrates the named gap; otherwise record `BASELINE PASS` and rely on the deterministic missing-contract checks for the textual RED gate.

### Task 2: Define safe resource identity and current agent selection

**Files:**

- Modify: `/Users/tunji/.agents/skills/orchestration/SKILL.md`

- [ ] **Step 1: Correct the agent-terminal selection contract**

  In `## Worker Terminals`, replace `startupTerminal.handle`-primary guidance with:

  ```markdown
  For agent-backed worktree creation, use `result.agentTerminalHandle` as the worker handle. On older runtimes that omit it, fall back to `result.startupTerminal.handle`; if both are absent, resolve the agent terminal from a scoped `terminal list` before dispatching. Do not infer the agent from tab order or title.
  ```

- [ ] **Step 2: Add the ledger identity model before the `Agent-first` paragraph**

  Insert:

  ```markdown
  Maintain an exhaustive run-owned resource ledger. Each terminal entry records its current handle, stable pane key (`paneKey`, or `<tabId>:<leafId>` from `terminal list`), full worktree ID, and creation origin. Each temporary-worktree entry records its full worktree ID.

  In a pre-existing worktree, ledger only terminals returned by coordinator-issued `terminal create` or `terminal split`; never treat a before/after handle delta as proof of ownership. For a run-created worktree, the whole worktree is run-owned: list it after creation and ledger every terminal materialized by its configuration, including default tabs or splits. Record later coordinator-created resources immediately.
  ```

- [ ] **Step 3: Connect dispatch provenance to the ledger**

  Add:

  ```markdown
  After dispatch, record `dispatch-show.assignee_pane_key` on the worker terminal entry and require it to match the entry's pane key. A terminal handle may change; the pane key is the stable identity used to resolve a replacement.
  ```

- [ ] **Step 4: Inspect the focused diff with an accepted non-empty status**

  Substitute the recorded snapshot path:

  ```bash
  rtk zsh -lc 'set +e; git --no-pager diff --no-index --unified=6 <before-path> /Users/tunji/.agents/skills/orchestration/SKILL.md; rc=$?; [[ $rc -eq 1 ]]'
  ```

  Expected: the diff is non-empty and the wrapper exits 0. Only agent-handle selection and resource identity wording has changed so far.

### Task 3: Make resource creation coordinator-only

**Files:**

- Modify: `/Users/tunji/.agents/skills/orchestration/SKILL.md`

- [ ] **Step 1: Add the worker prohibition**

  Add under `## Agent Guidance`:

  ```markdown
  - Workers must not create additional Orca terminals or worktrees during a supervised run. Use `ask` to request the coordinator to create and ledger the resource, then wait for the reply before continuing. If a worker already created an unapproved resource, send `ask` immediately with its exact handle or full worktree ID and stop until the coordinator acknowledges ownership; repeat the IDs in the eventual `worker_done` body.
  ```

- [ ] **Step 2: Add the coordinator side of the ask/reply flow**

  Add to the coordinator messaging rules:

  ```markdown
  When a worker asks for another Orca terminal or worktree, the coordinator creates it, records its complete ledger entry before replying, and includes the exact handle or full worktree ID in the reply. Do not delegate resource creation back to the worker.
  ```

  Do not invent a new `resourcesCreated` payload field or change Orca's injected lifecycle schema.

### Task 4: Harden finalization and absence verification

**Files:**

- Modify: `/Users/tunji/.agents/skills/orchestration/SKILL.md`

- [ ] **Step 1: Replace `## Run Finalization` with the complete contract**

  Use:

  ```markdown
  ## Run Finalization

  Treat cleanup as part of every supervised orchestration run. After capturing worker results and required diagnostics, finalize on success, failure, cancellation, or an unresolved blocker.

  1. Re-list each run-created worktree with a scoped terminal query whose result is not truncated; add every current terminal in that owned worktree to the ledger.
  2. Close every ledgered terminal with `orca terminal close --terminal <handle> --json`.
  3. If a handle is stale, re-list only its full worktree with a sufficient `--limit`, require `truncated: false`, and match the ledgered pane key against `<tabId>:<leafId>`. Close the replacement only on one exact match. If ownership is uncertain or multiple rows match, retain and report the entry.
  4. Remove each run-created temporary worktree with `orca worktree rm --worktree <full-id> --json` only after its changes are integrated, preserved, or explicitly discarded.
  5. Verify each terminal and worktree individually with `terminal show` or `worktree show`, or with a scoped non-truncated list when resolving a reminted handle. Do not infer absence from an unscoped or truncated list.

  Never close the coordinator terminal or any pre-existing terminal or workspace. Never infer ownership from temporal proximity, tab order, title, or worktree co-location. Never force-remove a dirty, unmerged, or otherwise unpreserved worktree.

  Mark every ledger entry `removed` or `retained`. A retained entry must include its exact current handle or full worktree ID and reason. Cleanup failure is visible run state: do not claim full cleanup while a removable resource remains or any entry is unreconciled. A terminal outcome may still be reported when entries are safely retained, but it must state that cleanup is incomplete.
  ```

- [ ] **Step 2: Verify the safety terms are present**

  Run:

  ```bash
  rtk rg -n 'pane key|truncated: false|terminal show|worktree show|removed|retained|tempor.*proximity' /Users/tunji/.agents/skills/orchestration/SKILL.md
  ```

  Expected: every finalization safety concept appears in the installed skill.

### Task 5: Consolidate handoff classification without changing boundaries

**Files:**

- Modify: `/Users/tunji/.agents/skills/orchestration/SKILL.md`

- [ ] **Step 1: Replace `## When To Use` with one decision table**

  Use:

  ```markdown
  ## Coordination Mode

  | Intent | Required path | Coordinator behavior |
  | --- | --- | --- |
  | Supervise, monitor, wait for or return results, wait for `worker_done`, coordinate a DAG, or manage decision gates/ask-reply | Orca orchestration | Create task/dispatch provenance, wait for lifecycle messages, and finalize run-owned resources. |
  | Hand off ownership to another agent or worktree without explicit supervision | `orca-cli` handoff | Deliver the prompt, create no orchestration lifecycle, do not monitor, and do not apply supervised-run finalization. |
  | Ordinary terminal, worktree, or Orca embedded-browser control | `orca-cli` | Perform only the requested control operation. |
  | Browser windows, webviews, Orca app UI, or desktop UI outside Orca's embedded browser | Computer Use | Use the desktop UI workflow, not `orca-cli`. |

  A custom agent, model, or reasoning effort does not by itself turn a handoff into supervised orchestration.
  ```

- [ ] **Step 2: Remove only duplicated classification prose**

  Keep lifecycle authority, coordinated-subtask behavior, review-only ownership, named-next-owner behavior, inherited-state inspection, and every procedural handoff example. Replace repeated handoff classification at the start of `## Full Handoffs` with:

  ```markdown
  For requests classified as full ownership handoffs by `## Coordination Mode`, use non-lifecycle terminal/worktree commands and stop monitoring after prompt delivery unless the user later asks for supervision.
  ```

- [ ] **Step 3: Measure rather than gate concision**

  Run:

  ```bash
  rtk wc -w <before-path> /Users/tunji/.agents/skills/orchestration/SKILL.md
  rtk rg -n 'Orca-First Default|Coordination Mode|Ownership|Full Handoffs|Run Finalization' /Users/tunji/.agents/skills/orchestration/SKILL.md
  ```

  Expected: report the before/after counts and inspect canonical section placement. Word count is informational; never delete a safety rule merely to reduce it.

### Task 6: Make the canonical example teach complete teardown

**Files:**

- Modify: `/Users/tunji/.agents/skills/orchestration/SKILL.md`

- [ ] **Step 1: Replace `## Example` with a full temporary-worktree lifecycle**

  Use this structure, preserving valid Markdown fences:

  ```bash
  orca worktree create --name login-css-worker --agent claude --json
  # Record the full worktree ID and result.agentTerminalHandle.
  orca terminal list --worktree id:<full-worktree-id> --limit <sufficient-limit> --json
  # Require truncated:false and ledger every returned handle plus tabId:leafId pane key.
  orca terminal wait --terminal <agent-terminal-handle> --for tui-idle --timeout-ms 60000 --json
  orca orchestration task-create --spec "Fix the login button CSS" --json
  orca orchestration dispatch --task <task_id> --to <agent-terminal-handle> --inject --json
  orca orchestration dispatch-show --task <task_id> --json
  orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 900000 --json
  # After capturing results and diagnostics, repeat close for every ledgered terminal.
  orca terminal close --terminal <ledgered-handle-1> --json
  orca terminal close --terminal <ledgered-handle-2> --json
  orca worktree rm --worktree <full-worktree-id> --json
  orca worktree show --worktree <full-worktree-id> --json
  ```

  Explain that the final `worktree show` must report absence and that the close command is repeated for every ledgered terminal, however many were created.

- [ ] **Step 2: Extend `## Next Action` through reconciliation**

  Replace the coordinator sentence with:

  ```markdown
  Coordinator: confirm Orca readiness, inspect inherited task/dispatch state, establish the run-owned resource ledger, then run the manual or automatic orchestration loop. After capturing results and diagnostics, finalize every ledger entry. Report full cleanup only when every entry is `removed`; if an entry is safely `retained`, report the terminal outcome, exact retained resource, reason, and incomplete-cleanup state.
  ```

### Task 7: Forward-test behavior and preserved regressions

**Files:**

- Validate: `/Users/tunji/.agents/skills/orchestration/SKILL.md`
- Update: the recorded temporary evidence packet

- [ ] **Step 1: Re-run the three Task 1 scenarios with fresh Orca workers**

  Expected GREEN:

  - Extra tabs: every terminal inside the run-created worktree is owned and ledgered; no temporal delta is used in a pre-existing worktree.
  - Stale handle: the replacement is resolved only by exact pane-key match on a scoped, non-truncated list.
  - Additional resource: the worker uses `ask`; the coordinator creates and ledgers the resource before replying.

- [ ] **Step 2: Re-run failure and unsafe-removal regressions**

  Use fresh workers:

  ```text
  A supervised run failed after diagnostics were captured. It created two worker terminals and one clean temporary worktree. State the mandatory finalization before reporting failure.
  ```

  ```text
  A supervised run is ending. A run-created worktree has dirty uncommitted and unmerged changes; a pre-existing user tab is open. Finalize safely.
  ```

  Expected: failure still runs complete teardown; the dirty worktree and pre-existing tab are retained, identified exactly, and cleanup is reported incomplete without force removal.

- [ ] **Step 3: Run full-handoff and uncertain-identity regressions**

  ```text
  Hand this task to another Codex agent in a new worktree using xhigh and return the results to me.
  ```

  Expected: `return the results` makes this supervised orchestration despite the handoff wording.

  ```text
  During finalization, a stale handle cannot be mapped uniquely by pane key and unrelated tabs are present. Finalize safely.
  ```

  Expected: close no uncertain terminal; retain and report the unreconciled entry.

- [ ] **Step 4: Preserve uncontaminated evidence**

  Each worker sees only the updated skill and its scenario. Append each prompt, task/dispatch/message IDs, exact result, and RED/GREEN verdict to the evidence packet. Capture results before closing each test worker, then close all test workers and verify their handles are absent.

### Task 8: Validate, review, clean up, and commit

**Files:**

- Validate: `/Users/tunji/.agents/skills/orchestration/SKILL.md`
- Stage/commit: `docs/plans/2026-07-14-orchestration-run-cleanup-hardening-implementation.md`
- Stage/commit: `docs/plans/2026-07-14-orchestration-run-cleanup-hardening-implementation-review.md`

- [ ] **Step 1: Validate the installed skill**

  ```bash
  rtk python /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/tunji/.agents/skills/orchestration
  ```

  Expected: `Skill is valid!`

- [ ] **Step 2: Inspect the complete external diff**

  ```bash
  rtk zsh -lc 'set +e; git --no-pager diff --no-index --unified=8 <before-path> /Users/tunji/.agents/skills/orchestration/SKILL.md; rc=$?; [[ $rc -eq 1 ]]'
  ```

  Expected: the wrapper exits 0 and the diff is limited to current agent-handle selection, stable ledger identity, coordinator-only resource creation, robust finalization, the lifecycle example, and behavior-preserving handoff deduplication.

- [ ] **Step 3: Stage the repository artifact before whitespace verification**

  ```bash
  rtk git add docs/plans/2026-07-14-orchestration-run-cleanup-hardening-implementation.md docs/plans/2026-07-14-orchestration-run-cleanup-hardening-implementation-review.md
  rtk git diff --cached --check
  ```

  Expected: the exact plan and its adversarial-review record are staged and cached whitespace validation exits 0. Preserve any unrelated staged or unstaged user work.

- [ ] **Step 4: Run the repository gate**

  ```bash
  rtk scripts/verify
  ```

  Expected: syntax, whitespace, and all repository tests pass with zero failures.

- [ ] **Step 5: Run a fresh-context final review with an explicit evidence packet**

  Dispatch a read-only Orca reviewer with the installed diff, this plan, the original cleanup design, and the exact recorded `EVIDENCE` path. Require findings ordered by severity or explicit approval. If it reports a finding, fix or reject it with evidence, rerun affected validation, and send the specific finding to a fresh resolution checker before proceeding.

- [ ] **Step 6: Finalize the review run itself**

  Capture the final reviewer and any resolution-check results, then close those run-created terminals. Re-list the implementation run's ledger and verify every removable entry is absent. Report every safely retained entry by exact ID and reason; do not close the coordinator or any pre-existing terminal/workspace.

- [ ] **Step 7: Commit only repository-owned artifacts**

  ```bash
  rtk git diff --cached --name-only
  rtk git commit -m "docs: plan orchestration cleanup hardening"
  ```

  Expected: only the intended plan and review record are committed with the configured human author and no AI attribution. The installed skill remains an intentional external runtime edit.

- [ ] **Step 8: Report final state**

  Report skill validation, repository verification counts, every forward-test outcome, final review verdict, exact resources removed or retained, commit SHA, and whether anything was pushed.
