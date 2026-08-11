# Adversarial Review v2 — Design

Date: 2026-08-11
Status: Approved for implementation
Supersedes: `2026-07-03-adversarial-review-design.md`, `2026-07-17-adversarial-review-portable-control-plane-design.md`

## Why v2

v1 was measured against its own run artifacts, not against intent.

**Wall clock.** The `think-centre` run of 2026-08-10 (tier `high`, `gpt-5.6-sol`,
effort `xhigh`) ran 17:09 → 20:30 — 3h21m across 32 model tasks — and terminated
`DID NOT CONVERGE`. Time split roughly 1h13m across 22 attacker invocations and
1h47m in the strictly serial spine (dedupe → judge → author-actions → resolution
→ arbiter, twice). The mandatory round-two fresh sweep re-ran all eleven attack
angles and cost 1h31m of the total. Attackers never actually fanned out:
`cli.rb` rejected `--jobs > 1` outright, so eleven angles ran in three waves.

**Rubber-stamped findings.** Across the fifteen runs on this machine that
produced findings: **320 `fixed`, 1 `rejected`.** `SKILL.md` declared
parent-applied `FIXED|REJECTED` adjudication a non-negotiable, but in practice
nothing was ever rejected. Every finding — including the document-hygiene
nitpicks — became an edit to a planning document. The cost of v1 was not only
three hours; it was 320 unadjudicated edits written into specs and plans.

**Redundancy.** Finding `DG-1` in that run was reported independently by five
angles. The eleven angles overlap heavily, which is why dedupe faced 66 findings
and why judge and resolution payloads reached 89KB and 110KB.

The conclusion: v1 has eleven finders and no working filter. It optimizes
process integrity — digests, immutable IDs, inode pinning, lock anchors — and
that machinery exists almost entirely to make *multi-round document mutation*
safe. v2 does not mutate documents, so it does not need it.

## Shape

One round. Report only. No revise loop, no fresh sweep, no arbiter, no
resolution verification, no durable state machine.

```
targets → 4 attackers (parallel, one wave) → ≤8 candidates
        → quote check (deterministic) → synthesis (1 call) → ≤3 findings → chat
```

**Attackers: `implementer`, `tester`, `feasibility`, `pre-mortem`.**
Dropped: `consistency-smells`, `assumptions-checker`, `traceability`, `user`,
and `divergence-probe-1..3`. Fix-rate cannot rank angles — it is uniformly 100%
and carries no signal — so angles are ranked by whether they name something that
breaks at runtime. The three kept executability angles are grounded in whether
the plan can be built and verified; pre-mortem is grounded in consequence.
`consistency-smells` and `traceability` alone produced 156 findings that were
never judged.

**Hard caps.** Two findings per attacker, so at most eight candidates rather
than sixty-six. Synthesis returns at most three, and zero is an explicitly
valid, good outcome.

**Model tiering** (per repository house rule): attackers run `sonnet` at
`medium`, synthesis runs `opus` at `high`. Breadth-finding does not need
`xhigh`; the 38-minute attacker in the measured run was `gpt-5.6-sol` at
`xhigh`. This is the single largest wall-clock lever.

**Evidence bar.** Every finding must carry a verbatim quote from the target
document, the location, the concrete failure it causes, and a severity. A
finding without a quote that appears byte-for-byte in the named file is dropped
before synthesis ever sees it.

**Synthesis posture is rejection.** Its job is to kill candidates, not to
catalogue them. It drops anything stylistic or document-hygiene, merges
duplicates, and ranks what survives.

Target: ~6 minutes of parallel attackers plus ~4 minutes of synthesis.
**10–12 minutes end to end, chat output only.**

## What stays scripted

Exactly one thing: `scripts/check-quotes`. It reads candidate findings and
verifies each quote appears verbatim in the file it names, exiting nonzero and
naming the offenders. A model asked to verify its own quotes is precisely the
check that fails, so this stays deterministic. It is roughly forty lines.

Dispatch itself is delegated to the host. The parent fans out four fresh-context
reviewers using whatever primitive the host provides, which is what makes v2
portable across Codex, Claude Code, Cursor, Gemini, and Copilot without a
bundle-and-ingest contract. v1's fresh-context guarantee was mechanically
enforced; v2's is conventional. That trade is deliberate — the enforced version
cost three hours and still rubber-stamped every finding.

## Removed

| Path | Action |
|---|---|
| `skills/general/adversarial-review/scripts/lib/` | delete (~12,000 lines) |
| `skills/general/adversarial-review/scripts/adversarial-review` | delete |
| `skills/general/adversarial-review/platform-adapters.md` | delete — no adapters remain |
| `skills/general/adversarial-review/assets/schemas/` | 7 schemas → 2 (`attack`, `synthesis`) |
| `skills/general/adversarial-review/agents/codex/` | 3 TOMLs → 2 (`attacker`, `synthesizer`) |
| `skills/general/adversarial-review/attack-angles.md` | 11 angles → 4 |
| `skills/general/adversarial-review/judge-rubric.md` | → `synthesis-rubric.md`, rejection-first |
| `skills/general/adversarial-review/SKILL.md` | rewrite |
| `test/adversarial_review_*.rb` (8 files), `test/support/`, `test/fixtures/adversarial-review/` | delete |
| `scripts/verify-adversarial-review` | delete; drop its call from `scripts/verify` |
| `.github/workflows/test.yml` | drop the portable-backend leg and the Windows-backend rationale |
| `AGENTS.md` line 37 | drop the two-backend testing rule |
| `CATALOG.md`, `skills.yaml`, `COMMANDS.md`, `USAGE.md` | rewrite the entries |
| `test/model_tier_contract_test.rb` | update the assertions that read v1 files |
| `milestone-orchestrator/references/{intake,validation}.md` | collapse `adversarial --high/--ultra` to one depth |

Tiers (`default`/`high`/`ultra`), executors, filesystem backends, and the
`--mode`/`--output` matrix all disappear. There is one shape.

Recovery is via git history; no legacy path is retained. A `--deep` option kept
for twice-a-year use would rot, and the evidence says its output was never worth
adjudicating.

## Size

12,201 lines → 559, a 22x reduction.

| File | Lines |
|---|---|
| `SKILL.md` | 87 |
| `attack-angles.md` | 81 |
| `synthesis-rubric.md` | 70 |
| `scripts/check-quotes` | 144 |
| `assets/schemas/{attack,synthesis}.json` | 114 |
| `agents/codex/{spec-attacker,spec-synthesizer}.toml` | 63 |

The pre-build estimate was ~250. The gap is entirely prose: the guidance files
carry the rejection criteria that v1 encoded in Ruby, and that is the right
place for them now that a model rather than a state machine applies them.

