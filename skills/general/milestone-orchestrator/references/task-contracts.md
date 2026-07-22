# Task Contracts, Routing, and Acceptance Gates

Contracts for dispatching, supervising, and adjudicating RUN work.

## Stable tasks versus attempts

A **plan task** (`TASK-###` in `PLAN.md`) is stable for the whole run. A
**dispatch attempt** is one host lifecycle attempt against it; under Orca it
carries `orcaTaskId`, `dispatchId`, attempt number, worker identity, and base
commit. Ledger dimensions never collapse into each other:

```text
Attempt:    created -> dispatched -> completed | failed | blocked | abandoned
Task stage: pending -> implemented -> reviewed -> verified -> integrated -> closed
Condition:  active | blocked | failed | circuit-open | cleanup-pending | retained
```

Review, verification, integration, and cleanup task types have their own legal
stage subsets; do not force them through implementation-only stages. All
semantic failures count against the stable plan-task budget, never merely the
host task ID. Once an attempt terminally completes, a retry is a fresh linked
attempt, not a mutation of the old one.

## Task packet schema

Every dispatch includes:

- Run ID, stable plan task ID, host task/dispatch IDs when allocated, attempt
  number, task type, goal, and dependency IDs
- Relevant approved-spec sections and acceptance rows
- Owned paths/components and forbidden overlap
- Starting branch, immutable requested base SHA, observed worker HEAD, and
  integration target
- Required logical route, agent family, capability, reasoning level, exact
  host launcher, allowed substitutions, and identity-verification method
- The PREPARE grounding digest, embedded verbatim (workers implement from the
  digest; they do not re-survey the repository)
- Applicable repo instructions and skills
- Required implementation discipline (e.g. TDD when applicable)
- Exact task-local verification commands (by registered PLAN command ID)
- Required commit/handoff format (human author, no AI attribution)
- Expected completion evidence (commits, command output, structured summary)
- Remediation owner and cleanup policy

## Worker routing

The coordinator is not tied to its own model family. Record the reason for
each choice; never ask the user for routine routing approval.

Routes are described as capability tiers, not model names — concrete models
change faster than this document. The preflight checklist records the exact
launcher behind each tier for this run, and any substitution is recorded
before dispatch.

| Task shape | Capability tier |
|------------|-----------------|
| UI implementation, interaction, visual polish | Strongest available UI-capable implementation model |
| Architecture, integration, difficult debugging, thorough review | Frontier judgment model at high reasoning effort |
| Read-heavy exploration and repository mapping | Fast economical agent |
| Mechanical bounded implementation and test execution | Economical worker model |
| Security, migration, broad correctness review | Frontier review model at high/xhigh effort; cross-family review when valuable |

Start with the cheapest model likely to succeed. Escalate when a task is
ambiguous, high-risk, integration-heavy, or a cheaper worker fails on a
capability limit. Never downgrade judges or reviewers below their own review
workflow's requirements, and never silently substitute an unavailable route —
record the substitution before dispatch.

## Waves and isolation

- Under the `full` profile, independent implementation slices get separate
  worktrees created from an immutable per-wave base ref at the approved
  integration SHA; verify the new worktree's observed HEAD before dispatch.
  Under `lite`, all tasks run serialized in the single integration worktree
  and worktree-per-task overhead is skipped.
- One writer per owned path/component. Shared-file, shared-state, or tightly
  coupled tasks are serialized.
- Choose concurrency from actual independence, repository setup cost, runtime
  capacity, and integration risk — not the host's configured maximum.
- Prefer shallow DAGs of roughly three or four waves over long chains.

## Acceptance gates

Host completion (`worker_done`, subagent return, process exit) is
attempt-level only, and can fire even when the payload reports failure. Every
semantic readiness edge passes through a coordinator-adjudicated acceptance
gate:

1. Validate the attempt's structured outcome against the packet's expected
   evidence.
2. Confirm claimed commits exist and are reachable from the worker branch.
3. Confirm task-local verification against the registered commands at the
   claimed SHA: under `full`, re-run them independently (coordinator-run or a
   verification worker); under `lite`, validate the worker's captured output
   (registered command ID, SHA, passing result) and re-run only at these
   checkpoints: the first completed implementation task of the run
   (trust-but-verify — a systematically false-reporting worker must be caught
   before dependents build on it), whenever evidence is suspicious, at
   shared-path integration boundaries, immediately before the first push, and
   at the final repository gate.
4. Only then advance the durable task stage and release dependents.

No integration or publication dependency ever points directly at a dispatched
worker task. Failed, malformed, stale-dispatch, or wrong-pane results release
nothing.

## Verification execution and long gates

All registered-command runs — acceptance-gate re-runs, integration checks,
the final repository gate — execute through `scripts/run-verification`: it
refuses unregistered command IDs, anchors the run to the claimed SHA
(`--expected-sha`), streams full output to the milestone `evidence/`
directory, and prints a one-line JSON digest. The digest is the gate
evidence; the raw output never enters coordinator context.

Commands with registered timeouts over ~10 minutes are **long gates**, and
field runs are unambiguous about them: implementation workers repeatedly died
running long gates as backgrounded commands, costing multi-hour stalls and
manual rescue. Therefore:

- Long gates run coordinator-side (or in a dedicated verification worker),
  via `run-verification`, in the foreground. Never inside an implementation
  worker, and never backgrounded.
- Implementation workers run only registered fast targeted subsets; PLAN
  must register at least one fast command per implementation task alongside
  any long gate.
- A full long-gate run is required when the delta since the last green gate
  touches runtime code, and at integration and closeout. A delta that is
  provably docs/comments/test-annotations only (check `git diff --stat`
  against the last certified SHA) runs the fast subset instead — record the
  classification with the evidence. When unsure, run the gate.
- **Fast-subset substitution never certifies publication.** The gate that
  covers a push, PR, closeout, or any post-remediation re-verification of
  runtime code is the full registered gate at the exact candidate SHA — no
  substitution, whatever the delta classification says. A field run's
  closeout PASS was overturned post-publication as "invalid fast-gate
  substitution" and needed eight remediation commits before it could merge.
- **Timing-sensitive gates run alone.** Two field coordinators contaminated
  their own benchmark/wall-clock measurements by running concurrent agents or
  commands during the gate. When a gate's duration or timing is part of the
  evidence, nothing else runs during it; the `load_1m` field in the
  run-verification digest is the adjudication record — treat a high-load
  result as suspect rather than escalating on it.
- **Task-local verification filters must cover the task's owned paths.** A
  field run's adjudication filter excluded exactly the test files the change
  broke, certifying a red branch green. When registering per-task fast
  commands in PLAN, include every test project/module that covers the task's
  owned paths; when in doubt, widen the filter.

## Review and remediation loop

- Fresh-context reviewers for risky tasks and integration boundaries under
  the `full` profile; `lite` relies on the mandatory final whole-branch
  review. A review-only completion reports findings; it never authorizes
  coordinator edits.
- Verify findings before acting: do not fix weak or unverified review
  suggestions.
- Triage verified findings: merge-blocking findings are remediated in-run;
  non-merge-blocking findings are recorded in STATE `findings` and reported
  at closeout, never dispatched. Grinding a review round to zero total
  findings is churn, not quality.
- Batch a review round's merge-blocking findings into one remediation task
  per owned path/component, owned by an implementer (fresh or original,
  chosen by the coordinator), followed by re-verification and one re-review
  scoped to the remediated findings — not a fresh full review.
- Remediation is a new linked plan task and attempt, not a backward mutation
  erasing earlier evidence.

## Serial integration

A dedicated integration worker (never the coordinator) brings verified slices
into the milestone branch on the single integration worktree. (Under the
`lite` profile there is nothing to integrate — serialized workers commit
directly on the integration worktree, and the ref/staging rules below bind
those workers instead.)

- Fetch the remote and compare expected ref OIDs before every integration
  commit; force push is prohibited.
- Stage only paths allowed by task ownership plus approved control artifacts;
  inspect the staged diff. Unrelated dirty state never enters the integration
  worktree.
- Run integration checks and return commits plus structured acceptance
  evidence for the coordinator to adjudicate.
- Ordinary conflicts are the integration worker's job. An architectural
  mismatch triggers a replan; a genuine SPEC contradiction escalates to the
  user.

## Supervision

- Rolling waits on completion, escalation, and decision-gate messages.
- A timeout is a liveness checkpoint, not worker failure. Inspect task and
  terminal liveness before intervening; heartbeat or terminal activity proves
  liveness, not completion.
- **Liveness is judged on snapshot deltas, never on "new lines printed."**
  Workers in subagent fan-out, long thinking, or long tool rounds legitimately
  print nothing for many minutes while their status renders in place — a
  spinner, elapsed time, growing token/tool-use counters, a subagent progress
  tree. Compare successive full terminal snapshots (or host task state):
  changed screen content, advancing counters, or a changed subagent tree all
  prove the worker is alive and computing. A field run killed a live worker
  and dispatched a redundant replacement off a "transcript quiet 60+ min"
  read — quiet is not dead. Before declaring an attempt dead, require two
  consecutive *identical* snapshots plus a failed steer (send it a status
  prompt and wait one check); on hosts where the worker cannot be snapshotted
  (native subagents), a missing completion notification is never death
  evidence by itself — verify against host task listings.
- **Launch-window cautions expire at first sign of work.** "Fresh terminals
  sometimes exit silently before the first heartbeat" is a real launch-window
  failure and justifies a quick early liveness check — but it applies *only*
  between spawn and the worker's first acknowledgment or output. Once a
  worker has acknowledged its packet, produced output, or committed, the
  silent-early-exit prior is dead: judge it exclusively by the snapshot-delta
  rules above. A field coordinator killed a live, working agent because a
  launch caution primed it to see death mid-task. Task packets and charters
  must scope any such caution to the pre-acknowledgment window explicitly.
- Liveness is not progress. An attempt that produces no new commit or
  evidence across consecutive supervision checks is stalled even if its
  snapshots keep changing: steer it once at the second such check, and at the
  stall budget (`attempt_stall_checks`, default 3) kill the attempt, record
  it `failed` with the stall evidence, and count it against the task's
  failure budget. Deep context-gathering early in an attempt is normal —
  judge stall from the attempt's expected shape, not impatience — but a
  worker allowed to churn indefinitely because it "looks alive" is the single
  most expensive failure mode.
- Transient failure with evidence: one retry. Repeated failure: reframe,
  split, or escalate the worker/model; three consecutive failures on a task
  open its circuit (`condition: circuit-open`) and force a replan-or-escalate
  decision. Choose a plan-only replan when the replan budget has headroom and
  the evidence points to task framing, sizing, or routing — something a
  restructured task can plausibly fix inside the frozen SPEC. Escalate to the
  user (SKILL.md trigger 5) when the replan budget is exhausted, or when the
  failures point at the SPEC itself, missing authority, or external
  infrastructure.
- Two consecutive supervision cycles with no new commit, evidence, or
  actionable liveness change after steering trigger global no-progress
  escalation.
- **Spec-attribution checkpoint.** Repeated trouble on one task is often a
  contract problem wearing an implementation costume — a field run spent 29
  attempts and 4 replans on a single task whose failures only a user SPEC
  amendment could resolve. After a task's **second** troubled cycle (a second
  failed/blocked attempt, a second remediation round in the same area, or a
  replan that targets it again), the coordinator must record an explicit
  attribution verdict in STATE before dispatching any further work on it:
  *implementation-shaped* (the SPEC is clear; the work or its framing is the
  problem) or *contract-shaped*. Contract-shaped signals: findings that cite
  SPEC sections, invariants, or acceptance text rather than code; fixing one
  finding violating another approved requirement; reviewers disagreeing about
  what correct behavior *is* rather than how to build it; a replan that
  restructured the task without changing the outcome. A contract-shaped
  verdict escalates under SKILL.md trigger 3 **now**, with the contradiction
  and options stated — further attempts, remediation rounds, or plan-only
  replans on that task are forbidden until the user rules. An
  implementation-shaped verdict must say what the next attempt changes.
- Every dispatch of any type decrements the worker-dispatch budget recorded
  in STATE. Exhaustion is terminal `blocked`/`escalated` with the dispatch
  ledger as evidence — never silent continued dispatching.

## Failure quick reference

| Situation | Action |
|-----------|--------|
| Worker silent | Check liveness evidence first; steer before killing |
| Evidence contradicts tracker | Field-specific source-of-truth table in [state-schema.md](state-schema.md); record old/new/evidence |
| Worker claims done, no commits | Reject at the acceptance gate; retry or escalate route |
| Findings cite SPEC text, or fixes contradict approved requirements | Spec-attribution checkpoint; contract-shaped → escalate trigger 3, no further dispatch on that task |
| Review finding verified | New remediation task, worker-owned |
| Integration conflict | Integration worker resolves; coordinator never patches |
| Relevant dirty user state | Must already have the PREPARE-approved checkpoint strategy; otherwise escalate |
| Budget exhausted | Terminal `blocked`/`escalated` with counter and evidence |
