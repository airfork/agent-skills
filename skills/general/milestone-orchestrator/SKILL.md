---
name: milestone-orchestrator
description: >-
  Use when the user invokes $milestone-orchestrator or /milestone-orchestrator,
  asks to plan and then autonomously implement a large repository milestone,
  epic, or multi-task feature with multi-agent workers, or wants an interactive
  design/approval phase followed by an unattended implementation run that ends
  in a reviewed draft pull request.
---

# Milestone Orchestrator

Two-phase workflow for large repository milestones. **PREPARE** is interactive:
ground in the repository, resolve every material decision, produce a reviewed
`SPEC.md` and `PLAN.md`, and obtain one final approval. **RUN** is unattended:
dispatch mixed multi-agent workers through implementation, review, remediation,
integration, verification, commit, push, and draft-PR creation, interrupting
the user only for a genuine loss of authority or an unrecoverable
contradiction.

The top-level agent is a **manager**. It plans, routes, supervises, reconciles,
adjudicates evidence, and closes the run. It never implements production code,
tests, configuration, migrations, or implementation documentation during RUN.

Reference routing — read these before the corresponding stage:

| Stage | Read |
|-------|------|
| PREPARE grounding, decisions, approval, preflight | [references/intake.md](references/intake.md) |
| Task packets, routing, acceptance gates, remediation | [references/task-contracts.md](references/task-contracts.md) |
| STATE/PLAN canonical blocks, reconciliation, closeout | [references/state-schema.md](references/state-schema.md) |
| Orca / native Codex / native Claude mechanics, resource cleanup | [references/platform-adapters.md](references/platform-adapters.md) |
| Skill validation status and pressure-test protocol | [references/validation.md](references/validation.md) |

Templates for the milestone artifacts live in `assets/`. Four scripts replace
mechanical judgment: `scripts/validate-state` checks the `STATE.md` canonical
block (run after every material update and before publication);
`scripts/control-state` is the fenced STATE transition writer;
`scripts/preflight-lint` gates the end of PREPARE; `scripts/run-verification`
executes registered verification commands and emits digest-only evidence.

## Invocation

Codex:

```text
Use $milestone-orchestrator to plan and run the <milestone> milestone
Use $milestone-orchestrator prepare docs/milestones/<slug>/
Use $milestone-orchestrator run docs/milestones/<slug>/
Use $milestone-orchestrator status docs/milestones/<slug>/
```

Claude Code:

```text
/milestone-orchestrator <milestone description>
/milestone-orchestrator run docs/milestones/<slug>/
```

Natural-language equivalents apply, such as "plan this milestone with me, then
implement it autonomously and open a draft PR." `prepare` stops after the
approval checkpoint; `run` resumes from approved artifacts; `status` reconciles
and reports without dispatching new work. A bare invocation runs PREPARE and,
after explicit approval, prints the RUN handoff block (intake.md) so the user
can restart RUN on the cheaper recommended tier — continuing in-session is
their call after seeing it.

## Execution Profiles

Ceremony must scale with the milestone; the process below describes the `full`
profile, and small milestones run a cheaper `lite` variant. During PREPARE,
classify the milestone, record the profile and its rationale in `PLAN.md`, and
surface it at approval.

| Profile | Choose when | Adjustments |
|---------|-------------|-------------|
| `full` | Roughly six or more tasks, multiple independent writers, migration/security/data risk, or expensive integration | The process exactly as written |
| `lite` | Roughly five or fewer tasks, one or two writers, low blast radius, cheap verification | PREPARE defaults to `standard` review depth (one fresh-context spec+plan review at high effort — see intake.md); single shared worktree with serialized tasks; no dedicated integration worker (each verified task lands directly on the integration branch); acceptance gates validate worker-captured verification output, re-running only at the checkpoints defined in task-contracts.md; per-task fresh-context review is skipped — the mandatory final whole-branch review is the review |

Profile selection changes ceremony only. It never relaxes authority, the
publication envelope, the manager-only boundary, secret scanning, budgets, or
the mandatory final review. When in doubt, or when a `lite` run develops
overlapping writers or integration surprises, replan to `full`.

## Non-Negotiables

- **Manager-only coordinator.** During RUN the coordinator edits only the
  milestone control artifacts (`STATE.md` and recorded replan versions of
  `SPEC.md`/`PLAN.md`). A coordinator edit to implementation files is a policy
  failure: stop, record it in STATE, and dispatch a worker instead. Never take
  over a failed task.
- **One approval, then autonomy.** All material decisions are resolved in
  PREPARE. During RUN, contact the user only for the six escalation triggers
  listed below.
- **Approval freezes the contract.** SPEC, PLAN, and authority changes after
  approval require a recorded replan; SPEC or authority changes require user
  reapproval. Plan-only replans inside the frozen SPEC may proceed after drift
  and review checks.
- **Lifecycle is not correctness.** A worker completion signal (`worker_done`,
  process exit, subagent return) closes an attempt only. Advancement of the
  durable task stage requires the coordinator to validate the returned commits,
  evidence, and verification output.
- **Independent verification and review.** Verification uses only the exact
  commands registered in PLAN, executed through `scripts/run-verification`
  (digest evidence, full output to `evidence/`), and is adjudicated by the
  coordinator, never self-certified by the implementer: under `full` the
  coordinator (or a verification worker) re-runs the commands independently;
  under `lite` it validates the worker's captured output (registered command
  ID, SHA, passing result) and re-runs only at the checkpoints defined in
  task-contracts.md (first completed task, suspicion, shared-path
  integration, first push, final gate). Long gates never run inside
  implementation workers — see task-contracts.md.
  Review findings are remediated by workers, then re-verified and re-reviewed.
  Self-review never releases a gate.
- **Publication envelope.** Default authority is local commit + push + one
  draft PR, using the configured human git author with no AI attribution.
  PR-ready and reviewer notification need their own recorded flags. Merge and
  deploy are always disabled; stop and hand off instead.
- **Mandatory final review.** Before presenting merge options, run a
  whole-branch code review with the host's correct workflow: Codex workers use
  this repository's `code-review` skill; Claude workers use Claude's own
  `/code-review`; never substitute one for the other. Run it at high effort
  by default; raise the effort only for milestones whose risk earned an
  adversarial PREPARE review.
- **Isolated writers.** One writer per owned path/component. Independent
  slices run in separate worktrees; overlapping or tightly coupled work is
  serialized. Unrelated dirty user state is preserved and never enters
  milestone commits.
- **Safe cleanup.** Clean only lifecycle-owned resources (worktrees,
  terminals, browser tabs recorded in STATE with matching creation provenance)
  and only after their outputs are integrated and preserved. Never touch
  pre-existing or foreign resources; on doubt, retain and report.
- **Secrets stay out.** Run the repository's secret scan (or documented
  fallback) before every commit and push. Authenticated browser evidence is
  redacted; raw captures live in a git-ignored transient location and are
  deleted at closeout.

## Phase 1: PREPARE (interactive)

Read [references/intake.md](references/intake.md), then:

1. **Ground in the repository.** Read repo instructions, architecture docs,
   recent history, and the relevant implementation. Fan out read-only survey
   agents for broad repos. Distill the result into a grounding digest that
   every task packet will embed, so workers never repeat this exploration.
2. **Build the decision inventory** across behavior, architecture, migration,
   data/privacy, performance, error handling, testing, release authority,
   credentials, destructive-action boundaries, and defaults.
3. **Ask consolidated decision packets.** Each material question carries why it
   matters, a recommendation, the default, and the alternatives. As many
   rounds as material decisions require — minor choices go in the authority
   envelope instead.
4. **Write `SPEC.md`** from `assets/spec-template.md`. No unresolved TBDs at
   approval.
5. **Write `PLAN.md`** from `assets/plan-template.md`: deliverable-sized
   tasks, shallow dependency DAG, path ownership, role/model needs,
   registered verification commands, acceptance matrix.
6. **Review the spec and plan** at the coordinator-recommended depth from
   intake.md's review-depth table: by default one fresh-context reviewer at
   high effort over both artifacts together; this repository's
   `adversarial-review` skill only when risk genuinely warrants it (then
   spec-first, plan after, per intake.md). Record the depth rationale.
   Unresolved material findings or a non-converged review block RUN unless
   the user accepts them.
7. **Obtain one final approval** presenting spec, plan, review reports,
   acceptance mapping, and the explicit authority summary (each publication
   action listed separately; merge/deploy always off).
8. **Initialize `STATE.md`** from `assets/state-template.md`, run the
   preflight checklist in intake.md, checkpoint-commit the approved artifacts
   on the integration branch, and validate with `scripts/validate-state`.
9. **Print the RUN handoff block** (intake.md): the exact fresh-session
   command to start RUN on the recommended coordinator tier, since PREPARE
   usually runs on a stronger model than RUN needs. Continue in-session only
   if the user chooses that after seeing the block.

## Phase 2: RUN (unattended)

Read [references/task-contracts.md](references/task-contracts.md) and
[references/state-schema.md](references/state-schema.md), then loop:

```text
reconcile -> select ready tasks -> build packets -> dispatch wave
   -> supervise (rolling waits) -> adjudicate evidence -> review/remediate
   -> integrate serially -> verify -> update STATE -> next wave
```

1. **Reconcile before dispatch.** Compare SPEC/PLAN/STATE against git, host
   task state, worktrees, and forge state using the field-specific
   source-of-truth table in state-schema.md. Repair the tracker before
   creating work.
2. **Dispatch bounded waves** of isolated workers with complete task packets.
   Choose concurrency from actual independence and integration risk, not the
   host's maximum.
3. **Supervise without implementing.** Rolling waits on completion,
   escalation, and gate messages. A timeout is a liveness checkpoint, not
   failure; heartbeat proves liveness, not completion.
4. **Review, remediate, verify.** Fresh-context reviewers on risky tasks and
   integration boundaries (`full` profile; `lite` defers to the final review).
   Batch a review round's verified merge-blocking findings into one
   worker-owned remediation task per owned path/component, followed by
   re-verification and re-review. Non-merge-blocking findings are recorded in
   STATE and reported at closeout, not remediated in-run.
5. **Integrate serially** through a dedicated integration worker on the single
   integration worktree. Architectural mismatch triggers a replan; a true SPEC
   contradiction escalates to the user.
6. **Publish within the envelope.** Commit, push (non-force, expected-OID
   checked), and create or update one draft PR, after the pre-publication
   secret scan passes.
7. **Run the mandatory final whole-branch review**, remediate, and repeat
   until no merge-blocking finding remains or the remediation ceiling is
   reached.
8. **Close the run**: full repository gate, bounded CI polling, final
   acceptance matrix, lifecycle cleanup per platform-adapters.md, closeout
   record in STATE, and a handoff report ending at the exact next action that
   requires user authority.

## Escalation Triggers (the only reasons to interrupt RUN)

1. Destructive or irreversible action outside explicit preauthorization.
2. Missing credentials, permissions, or a human-only action.
3. Genuine contradiction in the approved spec with materially different
   outcomes. Do not wait for certainty or budget exhaustion: the
   spec-attribution checkpoint in task-contracts.md forces this question
   after two troubled cycles on one task, and a contract-shaped verdict
   escalates immediately — field runs burned dozens of attempts becoming
   "sure" about ambiguities only the user could resolve.
4. Non-converged required review whose open finding changes safety, behavior,
   architecture, or release confidence.
5. Repeated no-progress after the retry/replan budget.
6. External infrastructure failure with no safe in-scope workaround.

Routine library choices, reversible implementation details, model routing,
review timing, retry worker selection, and task subdivision never justify
interruption when the authority envelope covers them.

## Default Budgets

Explicit and overrideable in `PLAN.md`; never left unset:

| Budget | Default |
|--------|---------|
| Transient-failure retry | 1 |
| Consecutive task failures before circuit opens | 3 |
| Final-review remediation rounds | 3 |
| Plan-only replans | 2 |
| CI wait | 30 min, 2 evidenced infrastructure retries |
| No-progress supervision cycles before escalation | 2 |
| Worker dispatches per run | 5 × plan task count, computed and recorded at preflight |
| Stalled-attempt supervision checks | 3 — steer the worker after 2 checks with no new evidence; kill the attempt and count a task failure at 3 |

Every dispatch of any type (implementation, review, verification, integration,
remediation, cleanup) counts against the worker-dispatch budget. It is a churn
backstop, not a target: a healthy run uses well under it.

Exhaustion produces a terminal `blocked`/`escalated` state with the counter and
freshest evidence; it never loops silently.

## Cancellation

A user stop overrides unattended progress: enter `aborting`, revoke new
dispatch and publication authority, advance the fencing epoch, signal workers,
inventory partial work, preserve all recoverable git state, clean only
proven-safe resources, and write a resumable abort report. Never merge or
deploy during abort. A restarted coordinator uses a new run epoch and fences or
abandons stale dispatches before resuming (see state-schema.md recovery rules).

## Red Flags — stop and correct

- "I'll just fix this file myself, it's faster than a worker" — manager
  boundary violation.
- "The worker said done, so the task is done" — lifecycle is not correctness.
- "This review finding is small, I'll patch it inline" — remediation is
  worker-owned.
- "I'll ask the user a quick routing question" — covered by the authority
  envelope.
- "Force push will fix the diverged ref" — prohibited; stop and reconcile.
- "This stray worktree is probably ours" — clean only provenance-matched
  resources.
- "Each finding gets its own remediation worker" — batch the round's verified
  merge-blocking findings per owned area; record the rest.
- "One more full verification re-run can't hurt" — duplicated verification is
  the main cost driver; re-run only where the profile requires it.
- "Small milestone, but full ceremony is safer" — ceremony that the profile
  says to skip is waste, not safety; risk controls live in the
  non-negotiables, not in extra dispatches.
- "The worker can just run the full gate in the background" — backgrounded
  long gates killed workers in every field run that tried; long gates are
  coordinator-side via run-verification.
- "I'll paste the test output into STATE as evidence" — evidence is a digest
  plus a log path; prose bloats the ledger every later turn re-reads.
- "No new output lines, so the worker is dead" — workers in subagent fan-out
  or long tool rounds update in place; diff full terminal snapshots and
  counters, and steer before any kill.
- "One more attempt/replan will crack this task" — a task in repeated trouble
  gets a recorded spec-attribution verdict before any further dispatch;
  contract-shaped trouble goes to the user, not to attempt five.
