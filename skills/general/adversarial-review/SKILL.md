---
name: adversarial-review
description: >-
  Use when the user invokes $adversarial-review or /adversarial-review, asks to
  adversarially review a spec, implementation plan, migration plan, architecture
  design, or planning document before implementation, or asks for xhigh
  fresh-context critique with revise/reject and resolution verification.
---

# Adversarial Review

Cross-platform workflow for attacking specs and implementation plans before implementation starts. The review uses fresh-context, read-only attackers, refute-or-promote judges, a revise-or-reject loop, and per-finding resolution checks.

For host-specific dispatch and install notes, read [platform-adapters.md](platform-adapters.md). Before dispatching attackers, read [attack-angles.md](attack-angles.md). Before culling or resolution checks, read [judge-rubric.md](judge-rubric.md).

## Invocation

Codex:

```text
Use $adversarial-review docs/spec.md docs/plan.md
Use $adversarial-review docs/spec.md --high
Use $adversarial-review docs/spec.md docs/plan.md --report-only
```

Claude Code:

```text
/adversarial-review docs/spec.md docs/plan.md
/adversarial-review docs/spec.md docs/plan.md --ultra
```

Gemini/Antigravity:

```text
Activate adversarial-review for docs/spec.md docs/plan.md
Run adversarial-review on docs/spec.md docs/plan.md --high
```

Natural-language equivalents apply, such as "run adversarial review on the payments spec and plan."

Inputs are repository files only: a spec, a plan, or both. Do not review pasted text, tickets, or external docs in v1. If both a spec and plan are present, enable the coverage mapper and spec-plan drift angles. If only a plan is present, enable feasibility checks. If only a spec is present, skip plan-only angles.

## Flags And Tiers

No quick or low tier exists. This skill is for maximum-rigor pre-implementation review.

| Tier | Flag | Behavior |
|------|------|----------|
| default | none | Parallel attack angles, refute-or-promote cull, revise/reject, per-finding resolution verification, two-revise-round cap. All roles use xhigh reasoning. |
| high | `--high` | Default pipeline plus arbiter pass for stuck findings and the divergence probe angle. |
| ultra | `--ultra` | Claude only; implies `--high`. Run as an ultracode Workflow with wider fan-out, 3-vote refutation per finding, and optional cross-model arbitration. In Codex, downgrade to `--high` and disclose it. |
| report only | `--report-only` | Attack, cull, and report findings only. Do not revise documents, run resolution checks, run the round-2 fresh sweep, or emit convergence verdicts tied to revision. |

## Non-Negotiables

- Attackers and judges are part of this workflow. Spawn the read-only subagents needed for the selected tier without asking for extra permission.
- Fresh context is required. Do not let the authoring conversation perform the attack wave. Start attackers with no inherited conversation context when the host allows it.
- Attackers are read-only but not doc-only. They must read repository files needed to check claims against reality.
- On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier: judges and arbiters use the same inherited model and xhigh effort as attackers, without a relative downgrade. On other hosts, retain the existing prohibition on fast or cheap judges and arbiters. If the host cannot enforce required role effort, follow the selected platform adapter's explicit fallback or stop rule; do not invent a weaker generic fallback.
- Do not install Codex agent TOMLs into `~/.codex/agents/` unless the user explicitly asks.
- The parent may edit only the reviewed spec/plan files during revise. Do not edit implementation files as part of review.
- The rejection channel is mandatory. Do not "fix" weak or hallucinated objections merely because a judge challenged the document.

## Workflow

```text
packet build -> attack wave -> merge/dedupe -> cull -> revise -> resolution check
                                                     ^_________________________|
                                                        max 2 revise rounds
```

Maintain a visible task list when the host supports one.

### 1. Packet Build

1. Inspect `git status --short` so unrelated work is visible before edits.
2. Confirm the repository root and that each target file exists.
3. Identify the target document roles: spec, plan, or both.
4. Gather repo context pointers referenced by the docs: paths, APIs, schemas, configs, commands, tests, and nearby guidance files. Do not read the whole repo by default.
5. Record starting metrics: document length, TBD count, and coverage baseline when both spec and plan are present.
6. Build a compact review packet containing target docs, relevant context pointers, invocation flags, and enabled attack angles.

### 2. Attack Wave

Read [attack-angles.md](attack-angles.md), then spawn one fresh-context read-only attacker per enabled angle. Run in bounded waves; do not assume the host's maximum thread count. Attackers do not debate each other.

If an enabled attacker returns suspiciously few findings, such as an empty result with weak evidence or a rushed-pass explanation, retry that angle once with the same packet and a fresh context.

### 3. Merge And Dedupe

The parent groups candidate findings by document location and claim. Do not cull at this stage. Preserve the strongest evidence from each duplicate group and keep source angle names for traceability.

### 4. Cull

Read [judge-rubric.md](judge-rubric.md), then send grouped candidates to read-only judge subagents. Judges must actively try to refute each candidate, quote evidence, state concrete consequence, assign category and severity, and apply the confidence floor. Do not report findings below 0.7 confidence.

Assign stable IDs to promoted findings in order: `AR-001`, `AR-002`, and so on. Report at most 50 findings; aggregate overflow by category and severity.

When `--report-only` is set, stop after cull and write the report. Do not revise, reject, run resolution checks, run the round-2 fresh sweep, or mark unresolved findings as stuck.

### 5. Revise Or Reject

For each promoted finding:

1. Fix the reviewed spec/plan file in place, or
2. Reject the finding with written justification.

Every rejection must explain why the author's interpretation is safer or more accurate than the judge's. Record document edits in a changelog.

### 6. Resolution Check

Judges verify each finding by ID. They must quote the edit that resolves it, accept the rejection with evidence, or reaffirm that it is stuck. Never ask for a holistic re-score.

In round 2 only, run one additional fresh sweep to catch regressions introduced by revision. New `CRITICAL` or `HIGH` findings prevent a passing verdict.

## Loop Semantics

Hard cap: two revise rounds.

Terminal states per finding:

| State | Meaning |
|-------|---------|
| `resolved` | A judge quoted the edit that fixes the finding. |
| `rejected` | The author's written rejection was accepted. |
| `stuck` | The author rejected and a judge reaffirmed, or two fix attempts failed. |

Terminate only when all findings are resolved or rejected and no new `CRITICAL` or `HIGH` findings remain.

At the cap, use this verdict line:

```text
DID NOT CONVERGE - N findings remain open
```

Any stuck promoted finding at the round cap yields `DID NOT CONVERGE`, regardless of severity. `PASSED WITH OPEN QUESTIONS` is reserved for non-blocking questions that are not tied to a promoted finding.

Open questions must include both positions: the judge's evidence and consequence, plus the author's rationale or failed-fix summary.

## Report

Write a chat summary and a report file. By default, place the report next to the first reviewed document as `<doc-stem>-review.md`. On re-review, append a new round section to the existing report instead of overwriting it.

For `--report-only`, replace the convergence verdict with `REPORT ONLY - N findings` and emit only Findings and Metrics; use `ID | Category | Severity | Location | Summary` with no Resolution column. In this mode, do not emit Changelog, Rejected Findings, or Open Questions because no revision or resolution occurred.

For all other modes, use these convergence report sections:

Report sections:

1. Verdict line: `PASSED`, `PASSED WITH OPEN QUESTIONS`, or `DID NOT CONVERGE - N findings remain open`.
2. Findings table: `ID | Category | Severity | Location | Summary | Resolution`.
3. Metrics block: TBD count, coverage percentage when both spec and plan are present, findings by severity, and document length.
4. Changelog of document edits.
5. Rejected-findings log with justifications.
6. Open questions for stuck findings, with both positions.

Track document length growth across rounds. Treat large unexplained growth as a review-hacking signal and call it out in metrics or open questions.
