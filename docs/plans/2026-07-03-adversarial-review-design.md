# Adversarial Review Skill — Design

**Date:** 2026-07-03
**Status:** Validated design, not yet implemented
**Target platforms:** Claude Code and Codex CLI (portable core + platform adapters)
**Placement:** `skills/general/adversarial-review/`

## Purpose

Replace the hand-typed ritual "make sure the spec and the implementation plan go
through adversarial review on xhigh" with a skill that attacks a spec and/or
implementation plan from independent adversarial angles, culls weak findings,
revises the documents, and verifies each finding to explicit resolution — before
implementation starts.

Two structural upgrades over the typed-out version:

1. **Fresh-context review.** The authoring agent never reviews its own spec in
   the conversation that produced it. Attackers are fresh subagents that see only
   the documents and the repository, and must ground findings in external
   evidence (do the named APIs/files exist? is step 3 buildable?).
2. **Decorrelated attack procedures.** Distinct per-angle procedures instead of
   one monolithic "be adversarial" pass, with a separate adversarial cull so one
   pass is never asked for both breadth and precision.

## Invocation and inputs

- Codex: `$adversarial-review <spec path> [plan path] [flags]`
- Claude Code: `/adversarial-review <spec path> [plan path] [flags]`
- Natural-language equivalents apply ("run adversarial review on the payments
  spec and plan").

Inputs are repo files: a spec, a plan, or both. When both are present, the
spec↔plan drift angle is enabled. Out of scope for v1: tickets, pasted text,
external docs.

The revise step edits the reviewed files in place. `--report-only` disables
revision (attack + cull + report only).

## Tiers and flags

No quick/low tier by design: this skill exists to run at maximum rigor before
implementation. A cheap tier would be an attractive nuisance.

| Tier | Flag | Adds |
|------|------|------|
| default | (none) | Full pipeline: parallel attack angles, refute-or-promote cull, revise with rejection channel, per-finding resolution verification, 2-revise-round cap. All roles xhigh. |
| high | `--high` | Arbiter pass for stuck findings + the divergence probe angle (see below). |
| ultra | `--ultra` | Claude only; implies `--high`. Runs the pipeline as an ultracode Workflow: wider fan-out, 3-vote refutation per finding in the cull, optional cross-model arbitration. On Codex, downgrades to `--high` with a one-line disclosure. |

Other flags:

- `--report-only` — no document edits; findings and open questions only.

## Pipeline

```
packet build → attack wave → merge/dedupe → cull → revise → resolution check
                                                     ↑______________|
                                              (max 2 revise rounds)
```

1. **Packet build (parent).** Identify target docs, gather repo context
   pointers (key directories, APIs, schemas the spec references).
2. **Attack wave (fresh-context subagents, parallel, independent).** One
   subagent per angle (roster below). No inter-attacker debate: independent
   parallel critics + merge. Attackers are read-only but not doc-only — they
   read the repo to check the spec's claims against reality.
3. **Merge + dedupe (parent).** Group by doc location. No culling here.
4. **Cull (judge subagents).** Refute-or-promote per finding: the judge must
   actively attempt refutation, cite evidence, and state the concrete
   consequence if unfixed. Hard confidence floor: below 0.7, do not report.
   Severity assigned from the gate ladder (CRITICAL/HIGH/MEDIUM/LOW). Findings
   get stable IDs (`AR-001`…). Cap of 50 reported findings with overflow
   aggregation.
5. **Revise (parent, has authoring context).** For each surviving finding, the
   parent either fixes the doc or **rejects with written justification**. The
   rejection channel is load-bearing: challenge alone flips LLM answers ~46% of
   the time, so a revise phase without rejection "fixes" hallucinated
   objections and degrades the doc.
6. **Resolution check.** A judge verifies each finding *by ID*, quoting the
   specific edit that resolves it (or accepting/re-affirming the rejection).
   Never a holistic re-score — "loop until a judge passes" is a Goodhart setup
   with documented inverted-U quality. In round 2 only, one additional fresh
   sweep runs to catch regressions introduced by revision.

**Loop semantics.** Hard cap: 2 revise rounds. Terminal states per finding:
**resolved** (fix quoted and confirmed), **rejected** (justification accepted),
**stuck** (author rejected + judge re-affirmed, or two failed fix attempts).
Termination: all findings resolved-or-rejected, no new CRITICAL/HIGH. At the
cap, stuck findings are reported as open questions with both positions (judge's
evidence + consequence; author's rationale) and the verdict line reads
`DID NOT CONVERGE — N findings remain open`. Stuck CRITICAL/HIGH means the
review did not pass. Framing: "the questions your spec can't answer" is the
most valuable output, not a failure of the tool.

**Arbiter (`--high`).** Before punting stuck findings to the user: one fresh
arbiter per stuck finding, seeing only the doc section, the finding, and both
positions, ruling author-is-right / judge-is-right / needs-human. Arbiter
rulings against the author still land in open questions. Under `--ultra`,
arbitration may be cross-model (error overlap between model families is ~10%).

**Anti-gaming guards:** track doc length growth across rounds as a hacking
tell; judges must quote evidence per criterion; suspiciously few findings from
any attacker triggers one retry of that angle rather than a clean bill
(Fagan's rushed-pass heuristic).

## Attack angle roster

Distinct *procedures*, not personas — identical-role critics measurably
underperform a single critic; the value is decorrelated attention.

| Angle | Procedure | Notes |
|-------|-----------|-------|
| Constructive reader: implementer | Build a file-by-file design sketch from the spec; log every point the spec can't support | Perspective-Based Reading mechanism; perspectives find non-overlapping defects |
| Constructive reader: tester | Build a test plan; log untestable/unmeasurable criteria | |
| Constructive reader: user | Walk end-to-end user scenarios; log gaps and dead ends | |
| Coverage mapper | Requirement→task and task→requirement mapping with % metrics | Only meaningful when both spec and plan present; makes loop progress measurable |
| Assumptions checker | Key Assumptions Check: externalize stated and unstated load-bearing premises; define failure conditions per assumption | |
| Pre-mortem writer | Assume the project shipped and failed; write the postmortem | Assumed-certain-failure framing is the active ingredient |
| Consistency + smells scanner | Contradictions, terminology drift, tiered lexical smells | Tier 1 (flag freely, ~0.96 precision): TBDs, escape clauses ("as appropriate"), subjective language. Tier 2 (check context first, ~0.25 precision): comparatives, negatives, vague pronouns — verify not inside a legitimate conditional |
| Feasibility checker | Repo-grounded: verify plan steps against actual code, APIs, schemas; check sequencing and dependencies | Plan present only |
| Spec↔plan drift | Contradictions and gaps between spec and plan | Both present only |
| Divergence probe (`--high`+) | 3 independent attackers each produce a concrete implementation outline from the spec alone; parent diffs the outlines; divergence = empirical ambiguity evidence | Read-only adaptation of "implement the spec N times and diff"; most token-hungry angle |

Excluded deliberately: ACH matrices (RCT-falsified), pure assigned
devil's-advocate personas (produce rebuttal-shaped critique), generic
checklists (replicated null result vs ad-hoc reading).

## Finding taxonomy and report format

Findings tagged with the standard inspection taxonomy: **Omission /
Ambiguity / Inconsistency / Incorrect fact / Extraneous**.

Report structure (chat + file):

1. Verdict line: `PASSED` / `PASSED WITH OPEN QUESTIONS` / `DID NOT CONVERGE`.
2. Findings table: `ID | Category | Severity | Location | Summary | Resolution`.
3. Metrics block, tracked across rounds: TBD count, coverage %, findings by
   severity, doc length. Cross-round metric tracking shows measurable
   improvement instead of a pass/fail vibe.
4. Changelog of document edits.
5. Rejected-findings log with justifications.
6. Open questions (stuck findings, both positions).

**Report file:** written by default next to the reviewed docs
(`<doc-stem>-review.md`, e.g. `docs/plans/2026-07-03-payments-spec-review.md`).
A re-review of the same doc appends a new round section to the existing report
file, preserving the metrics trail. The review is otherwise read-only except
the revise step, which touches only the reviewed spec/plan files.

## Package layout

```
skills/general/adversarial-review/
  SKILL.md               # portable pipeline: stages, loop semantics, report format, flags
  attack-angles.md       # one procedure per angle, with output contract
  judge-rubric.md        # refute-or-promote ladder, confidence floor, severity gates
  platform-adapters.md   # Codex + Claude dispatch, --ultra mapping, sequential fallback
  agents/codex/
    spec-attacker.toml   # model_reasoning_effort = "xhigh", sandbox_mode = "read-only",
                         # nickname_candidates for parallel instances
    spec-judge.toml      # xhigh, read-only
    spec-arbiter.toml    # xhigh, read-only
```

`skills.yaml`: category `general`, `interfaces: [claude, codex]`,
`recommended_model_tier: deep`, `heavy_model_tier: ultracode`, Codex install via
`scripts/sync-skills` symlink. Update `CATALOG.md` in the same change.

## Platform adapters

**Codex.** Spawn attackers/judges/arbiters as the named agents above — named
agents are the only reliable per-role model/effort mechanism (per-spawn
`reasoning_effort` overrides exist on `spawn_agent` but are hidden from the
tool schema, openai/codex#26948). TOMLs install to `~/.codex/agents/` (one-time
copy step, documented like code-review's). Do not pin `model`; inherit the
session model — effort is the thing to pin. Constraints and caveats:

- Fan out in bounded waves; do not assume the local `agents.max_threads`
  (default 6). All orchestration in the parent (`max_depth = 1`).
- Version guard: Codex v0.137.0 silently ignored named-agent config
  (openai/codex#26363, fixed June 2026); recommend a current CLI. Windows has
  an unresolved variant (#19399).
- If named agents are not installed, continue with inherited settings and
  disclose in the report (same fallback as code-review).
- Never substitute a downgraded/fast model for judges or arbiters.

**Claude Code.** No named agents needed — `Agent` calls set effort per spawn at
default/`--high`; `--ultra` runs the pipeline as an ultracode Workflow
(attackers as workflow agents with structured-output schemas, 3-vote refutation
in the cull). Installed as a personal skill so `/adversarial-review` is
available everywhere.

**Sequential fallback.** If an environment cannot spawn subagents, run the same
roles sequentially and disclose it. Acceptable for portability, not equivalent
to independent parallel review.

## Research grounding (abridged)

Design decisions trace to a 2026-07-03 research pass (prior art + LLM-critique
literature). Load-bearing findings:

- Same-context self-correction degrades output; critique must be fresh-context
  and grounded in external evidence (Huang et al. ICLR 2024; Kamoi survey;
  CRITIC). Fresh session does not remove self-preference bias — different model
  family does; cross-model error overlap ~10% (Panickssery et al.).
- Identical-role multi-agent critics underperform a single critic; distinct
  procedures win (ChatEval ablation). Meetings/debate add ~4% of defects beyond
  independent review (Votta FSE'93) — no debate rounds for discovery.
- LLM doc reviewers over-flag by default (precision 0.13–0.32, Lubos RE 2024);
  breadth and precision cannot come from one pass (CriticGPT frontier).
  Refute-or-promote gates killed ~79% of candidates with validated outcomes;
  confidence floor from anthropics/claude-code-security-review (<0.7 = don't
  report).
- Loop-until-judge-passes exhibits inverted-U quality (reward-hacking results);
  gains concentrate in round 1, degradation documented by round 4. Per-finding
  ID tracking with quoted-fix verification replaces holistic re-scoring.
- Challenge alone flips LLM answers ~46% (FlipFlop) — the author rejection
  channel is mandatory.
- Perspective-Based Reading: constructive reading finds non-overlapping defect
  sets; generic checklists do not beat ad-hoc reading (replicated null).
- Requirements smells have per-smell precision 0.96 down to 0.25 — hence the
  two-tier smell policy (Femmer et al.).
- Run-to-run recall instability (0.04–0.46) is recovered by unioning parallel
  angles — the fan-out doubles as a recall fix.
- Prior art: github/spec-kit `/speckit.analyze` (findings table, severity
  gates, 50-finding cap, coverage metrics), obra/superpowers reviewer prompts
  ("approve unless serious gaps"), Claude Code best practices ("flag only gaps
  that affect correctness or stated requirements"). Nobody ships the full
  attack+cull+revise-loop combination on specs/plans.

## Environment notes (decided during design)

- `~/.codex/config.toml` `agents.max_threads` raised (18 → 24 during this
  session, later raised further by the user). `agents.max_depth` stays at 1:
  nothing in this design needs grandchildren, and raising depth is global.
- Codex now scans `~/.agents/skills` for skills; whether legacy
  `~/.codex/skills` is still scanned is unconfirmed — verify `sync-skills`
  target paths during implementation (affects code-review too).
