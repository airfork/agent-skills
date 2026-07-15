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
- Liveness is not progress. An attempt that produces no new commit, evidence,
  or materially advanced output across consecutive supervision checks is
  stalled even if its terminal is busy: steer it once at the second such
  check, and at the stall budget (`attempt_stall_checks`, default 3) kill the
  attempt, record it `failed` with the stall evidence, and count it against
  the task's failure budget. A worker allowed to churn indefinitely because
  it "looks alive" is the single most expensive failure mode.
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
- Every dispatch of any type decrements the worker-dispatch budget recorded
  in STATE. Exhaustion is terminal `blocked`/`escalated` with the dispatch
  ledger as evidence — never silent continued dispatching.

## Failure quick reference

| Situation | Action |
|-----------|--------|
| Worker silent | Check liveness evidence first; steer before killing |
| Evidence contradicts tracker | Field-specific source-of-truth table in [state-schema.md](state-schema.md); record old/new/evidence |
| Worker claims done, no commits | Reject at the acceptance gate; retry or escalate route |
| Review finding verified | New remediation task, worker-owned |
| Integration conflict | Integration worker resolves; coordinator never patches |
| Relevant dirty user state | Must already have the PREPARE-approved checkpoint strategy; otherwise escalate |
| Budget exhausted | Terminal `blocked`/`escalated` with counter and evidence |
