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
| 3. Disposable end-to-end fixture | **Partially implemented** — deterministic control-plane fault matrix in `test/milestone_orchestrator_fault_matrix_test.rb` (false completion, failure-budget circuit, stale epoch/fencing, foreign-resource cleanup, remote-expectation mismatch, closeout-with-open-findings, cancellation, recovery epoch) exercised through `scripts/control-state`; live-agent faults (worker silence, real runtime loss) and the fake-forge fixture repo remain deferred |
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

`scripts/control-state` is now implemented: a lease-fenced STATE transition
writer (exclusive coordinator lease with fencing tokens and epoch takeover,
transition rules, atomic validation-gated writes). The remaining enforcement
scripts from the design (`authorize-action`, `execute-action`, `launch-role`,
`inspect-effects`, `run-verification`, `scan-outgoing`, `run-pressure-suite`,
`create-fixture-repo`) stay deferred. Until they exist, adapters rely on probed host
primitives plus the STATE ledger for the capability boundaries in
[platform-adapters.md](platform-adapters.md), and the coordinator treats the
manager boundary and publication envelope as policy enforced by instruction
and validation rather than by sandbox.

## Post-pilot cost revisions (2026-07-15, untested)

The pilot and a subsequent real run showed the v1 process was
token-inefficient on small milestones (full ceremony applied unconditionally;
per-finding remediation dispatches; duplicated verification re-runs;
per-worker repository re-grounding). v1.1 added execution profiles
(`full`/`lite`), batched merge-blocking-only remediation, the grounding
digest, and the `worker_dispatches` budget (validator-enforced).

v1.2 extended this: lite-profile PREPARE (one combined spec+plan review), the
`attempt_stall_checks` budget (liveness is not progress), milestone-split
sizing guidance, lite trust-but-verify re-run checkpoints, capability-tier
worker routing, the coordinator diff self-audit, and mechanical enforcement
in `control-state` (attempt recording fenced by `worker_dispatches`, closeout
fenced by `review_remediation_rounds`) plus phase-gated validator checks
(`checkpoint_commit` and a computed dispatch budget required once past
`preparing`).

v1.3 replaced the mandatory adversarial reviews with coordinator-recommended
review depth: `standard` (one fresh-context spec+plan reviewer at high
effort) is the default, the `adversarial-review` pipeline is reserved for
genuinely risky milestones, and the mandatory final whole-branch review
defaults to high effort. Note the pilot's adversarial review did catch two
real defects — the `standard` depth trades that assurance for cost on
low-risk work, and the escalate-on-surprise rule in intake.md is the hedge.

v1.4 (2026-07-15) was driven by a five-run field audit (ai-civ m74, exodus
m30/m31/m32, kards-sim m53 — see each repo's `docs/milestones/<slug>/STATE.md`
journal): reviews found ~zero shipped-correctness bugs across the two fully
reviewed runs; the dominant friction was implementation workers dying on
backgrounded 13–25 minute gates; STATE bloated to 50KB+ from per-attempt
evidence prose. It added `scripts/run-verification` (registered-command-only
runner, SHA-anchored, digest-only evidence), `scripts/preflight-lint`
(unresolved markers, fresh-checkout executability, long-gate policy, unowned
contract files), the long-gate execution policy in task-contracts.md, and the
1000-char `oversized_evidence` cap on STATE evidence/notes. One field caveat:
mid-run validator schema changes forced a live run (m32) to backfill budget
keys post-closeout — prefer additive, phase-gated validation rules for
anything a live run might hold.

v1.4 also added coordinator-tier guidance (platform-adapters.md): strongest
frontier model for PREPARE, Opus-class for RUN coordination, floor at the
frontier-judgment class. This is reasoned from the field audit (coordinator
errors were discipline gaps now script-fenced, not capability gaps) but has
not itself been A/B validated — the next runs should use an Opus-class RUN
coordinator and the re-audit should check for wrong stall kills, sloppy
adjudication, or missed escalations.

The script/validator changes are covered by deterministic tests; the
instruction-level behavior of these revisions has not been pressure-tested
and inherits layer 1's deferred status.

## Second field audit (2026-07-16)

Three more runs: exodus m33 (first true new-format run), ai-civ m75 and
kards-sim m54 (started pre-revision, schema force-migrated mid-run — their
pain confirms the old format, not the new one). m33 exercised profiles
(`full`, with reasoned selection), the grounding digest, `standard` review
depth (worked as designed — findings fixed inline, no report file), and ran
every long gate coordinator-side via `run-verification` with zero
backgrounded-gate worker deaths. Defects found and fixed in v1.5:
`control-state record-attempt` wrongly gated plan task ids on the host
`task_allowlist` (tool unusable in m33; attempts hand-recorded); runs could
close with blocked tasks or in-flight attempts (m54, and m75's premature
Tasks-1–3 closeout) — now `non_terminal_task_at_close`; worktrees removed
mid-gate orphaned PPID-1 process trees (m75) — cleanup now checks for live
processes first. Still open: STATE total size (m54 hit 102KB with every
string under the 1000-char cap; the cap bounds strings, not attempt count ×
journal growth); `preflight-lint` unadopted so far (m33's PREPARE predated or
missed it); m33 repeated the wrongful live-worker kill before the
snapshot-delta liveness rules landed — those rules remain unvalidated.

v1.5 also added the spec-attribution checkpoint (task-contracts.md): after a
task's second troubled cycle, a recorded implementation-shaped vs
contract-shaped verdict is mandatory before further dispatch, and
contract-shaped trouble escalates under trigger 3 immediately — aimed at
m75's TASK-003 (29 attempts / 4 replans over a spec ambiguity) and m54's
TASK-102 grind. Instruction-level and unvalidated; the next audit should
check whether the verdict is actually recorded and whether it fires early.

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
