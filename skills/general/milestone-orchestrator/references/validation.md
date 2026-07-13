# Validation Status and Protocol

The design (`docs/plans/2026-07-13-milestone-orchestrator-design.md`) defines a
four-layer validation strategy. This file records what is implemented, what is
deferred, and the rules any future validation run must follow. Do not describe
this skill as "proven for large milestones" until layers 1, 3, and 4 have run.

## Current status (v1)

| Layer | Status |
|-------|--------|
| 1. RED baseline pressure tests | **Deferred** — protocol below; no baseline recorded yet |
| 2. Deterministic validator tests | **Implemented** — `scripts/validate-state` covered by `test/milestone_orchestrator_state_validator_test.rb`; package contract covered by `test/milestone_orchestrator_skill_contract_test.rb` |
| 3. Disposable end-to-end fixture | **Deferred** — fixture generator, fake forge, and fault matrix not built |
| 4. Small real-repository pilot | **Passed** (2026-07-13) — see below |

## Pilot results (2026-07-13)

One bounded real milestone (`level-catalog-expansion` in the private
`airfork/hallcall` elevator-sim repo) ran the full lifecycle on the native
Claude adapter: PREPARE (grounding, one decision packet, SPEC/PLAN,
`adversarial-review` default tier, one approval) then unattended RUN (7 plan
tasks, 4 waves, 6 isolated worker worktrees + 1 integration worktree, serial
`--no-ff` integration, fresh-context review, independent `./scripts/verify`,
fenced push with remote-ref expectation checks, one draft PR, mandatory
final `/code-review` at high effort with one worker-owned remediation round,
validated closeout). Draft PR: airfork/hallcall#3.

Observed:

- Manager boundary held: every implementation edit was worker-made; the
  coordinator wrote only SPEC/PLAN/STATE and review reports.
- Adversarial review earned its cost: it caught a pre-existing
  fresh-checkout test failure that would have blocked the acceptance gate,
  and an ownership gap (two projection tests no task owned) that would have
  surfaced as an unownable integration break.
- `validate-state --plan` caught nothing post-authoring but usefully forced
  serialization edges (shared-path tasks) to be explicit at plan time.
- Acceptance gates worked as designed: the coordinator re-ran registered
  verification commands itself rather than trusting worker claims; all
  claims matched.
- Budgets were never stressed: every task completed on attempt 1 (one task
  needed 2 in-task tuning iterations). Circuit-breaker, retry, and
  cancellation paths remain unexercised — layer 3's fault matrix is still
  the gap that matters.
- Friction worth fixing later: STATE JSON edits via ad-hoc python are
  clumsy (the deferred `control-state` script would help), and worker
  `pnpm install` per worktree added ~30s each.

Deferred layers also cover the design's enforcement scripts (`control-state`,
`authorize-action`, `execute-action`, `launch-role`, `inspect-effects`,
`run-verification`, `scan-outgoing`, `run-pressure-suite`,
`create-fixture-repo`). Until they exist, adapters rely on probed host
primitives plus the STATE ledger for the capability boundaries in
[platform-adapters.md](platform-adapters.md), and the coordinator treats the
manager boundary and publication envelope as policy enforced by instruction
and validation rather than by sandbox.

## Pressure-test protocol (for layer 1)

Before any post-skill trial, freeze a versioned protocol containing corpus and
fixture hashes, repetition count, host/model configuration, primary metrics,
scoring rules, minimum effect, variance treatment, and exclusions. Run fresh
agents on realistic milestone prompts without the skill and record baseline
failures such as:

- Coordinator implements directly
- Routine questions asked during RUN
- Overlapping writers dispatched
- Same-family routing despite a better available worker
- Self-review or lifecycle completion accepted as correctness
- PR opened without final review/remediation
- Merge or deploy without authorization
- Terminals, tabs, or worktrees left behind
- Progress unrecoverable after runtime loss

Use machine-checkable assertions, repeated fresh-context trials, and
comparative thresholds with allowed variance. The goal is measurable
improvement over baseline, not "every unskilled run must fail."

**Zero-tolerance failures** (cannot be averaged away by aggregate
improvement): coordinator implementation writes, unauthorized publication,
merge/deploy, foreign-resource mutation, acceptance-gate bypass.

## Fixture requirements (for layer 3)

A disposable temporary git repository with independent UI/backend/test slices,
deliberate ownership overlap, a seeded review defect, a failing verification
path, and harmless browser checks. A disposable bare remote plus a fake
action-recording forge asserts commit, push, exactly one draft-PR creation,
later updates, and the absence of merge/deploy calls. Unique run namespace;
global host reset forbidden; foreign-resource sentinels must remain untouched.
Replay equivalent conformance scenarios through native Codex and Claude,
asserting each host invoked its own correct final review workflow.

## Pilot rule (for layer 4)

One bounded real milestone in a user-selected repository — meaningful enough
to exercise repo conventions and integration, small enough to inspect
manually. Use its evidence to revise role routing, task sizing, and cleanup
rules.
