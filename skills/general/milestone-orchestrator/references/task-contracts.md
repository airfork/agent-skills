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
- Applicable repo instructions and skills
- Required implementation discipline (e.g. TDD when applicable)
- Exact task-local verification commands (by registered PLAN command ID)
- Required commit/handoff format (human author, no AI attribution)
- Expected completion evidence (commits, command output, structured summary)
- Remediation owner and cleanup policy

## Worker routing

The coordinator is not tied to its own model family. Record the reason for
each choice; never ask the user for routine routing approval.

| Task shape | Preferred route |
|------------|-----------------|
| UI implementation, interaction, visual polish | Claude |
| Architecture, integration, difficult debugging, thorough review | Sol/high or stronger judgment model |
| Read-heavy exploration and repository mapping | Terra, Luna, Spark, or equivalent fast agent |
| Mechanical bounded implementation and test execution | Luna, Spark, or equivalent economical worker |
| Security, migration, broad correctness review | High/xhigh capable model; cross-family review when valuable |

Start with the cheapest model likely to succeed. Escalate when a task is
ambiguous, high-risk, integration-heavy, or a cheaper worker fails on a
capability limit. Never downgrade judges or reviewers below their own review
workflow's requirements, and never silently substitute an unavailable route —
record the substitution before dispatch.

## Waves and isolation

- Independent implementation slices get separate worktrees created from an
  immutable per-wave base ref at the approved integration SHA; verify the new
  worktree's observed HEAD before dispatch.
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
3. Confirm task-local verification ran the registered commands at the claimed
   SHA with passing output.
4. Only then advance the durable task stage and release dependents.

No integration or publication dependency ever points directly at a dispatched
worker task. Failed, malformed, stale-dispatch, or wrong-pane results release
nothing.

## Review and remediation loop

- Fresh-context reviewers for risky tasks and integration boundaries. A
  review-only completion reports findings; it never authorizes coordinator
  edits.
- Verify findings before acting: do not fix weak or unverified review
  suggestions.
- Each verified finding becomes a remediation task owned by an implementer
  (fresh or original, chosen by the coordinator), followed by re-verification
  and re-review.
- Remediation is a new linked plan task and attempt, not a backward mutation
  erasing earlier evidence.

## Serial integration

A dedicated integration worker (never the coordinator) brings verified slices
into the milestone branch on the single integration worktree:

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
