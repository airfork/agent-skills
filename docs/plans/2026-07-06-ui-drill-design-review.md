# Adversarial Review — ui-drill design (round 1–2, `--ultra`)

## Verdict

PASSED

All 11 promoted findings resolved (10 in round 1, AR-004 in round 2). No rejections, no stuck findings. Round-2 fresh regression sweep: 15 candidates raised, 0 survived 3-vote verification. No new CRITICAL or HIGH findings.

## Findings

| ID | Category | Severity | Location | Summary | Resolution |
|----|----------|----------|----------|---------|------------|
| AR-001 | Ambiguity | HIGH | Student model / mastery gate | "Produced unprompted" undefined against the Socratic Discussion phase that precedes every grading event | resolved — "unprompted" pinned to the initial step-2 critique; Discussion-phase wording is prompted and non-counting |
| AR-002 | Omission | HIGH | Student model schema / mastery gate | "Recent perception hit-rate" had no persisted field and no defined window | resolved — per-flaw-type last-5-exposure tally added to student.md schema; gate references that window (≥ ~80% = at most one recent miss) |
| AR-003 | Ambiguity | MEDIUM | Curriculum vs mastery gate | "Core term" never defined relative to the ~8–12 target terms | resolved — curriculum.md marks a core subset (6–8, gating) vs extension (tracked, non-gating) |
| AR-004 | Omission | MEDIUM | Placement and layout | Git-ignored `state/` was the sole unversioned copy of all progress | resolved (round 2) — in-repo snapshots for bad rewrites; session-end mirror to `~/.local/state/ui-drill/` for git clean/re-clone; new-machine sync explicitly out of scope. Round-1 fix was stuck (snapshots lived inside the folder the named loss vectors erase) |
| AR-005 | Omission | MEDIUM | Student model / session loop | End-of-session-only persistence silently lost interrupted sessions' diagnostics | resolved — `state/session-current.md` per-exercise checkpoint log, folded in at session end or next session start |
| AR-006 | Omission | MEDIUM | Session loop vs modules 6–8 | User never cued to interact with interactive mockups; interaction-only flaws mis-gradable as perception misses | resolved — use-before-critique cue required; interaction-only flaws planted only in cued exercises |
| AR-007 | Inconsistency | MEDIUM | Capstone vs grading rubric | Holistic capstone grading unreconciled with universal per-flaw rubric; no module-9 completion criterion | resolved — per-flaw rubric retained underneath + holistic writing assessment; explicit completion criterion |
| AR-008 | Omission | LOW | Placement and layout | USAGE.md missing from required-updates list despite repo Change Checklist | resolved — update list now: CATALOG.md, skills.yaml, USAGE.md, AGENTS.md, repo-guidelines.md |
| AR-009 | Inconsistency | LOW | Placement and layout | `state/` convention slated only for AGENTS.md, leaving repo-guidelines.md folder rules contradictory | resolved — convention documented in both |
| AR-010 | Omission | LOW | Curriculum / progression | No terminal state after capstone mastery | resolved — maintenance mode defined (mixed review / user-requested focus) |
| AR-011 | Omission | LOW | Environment notes | Out-of-project `state/` write path and permission prompts unaddressed | resolved — path documented in SKILL.md; setup adds global write-allowlist entry |

## Metrics

- Document length: 96 → 105 lines (+9, all attributable to finding fixes; no review-hacking growth signal)
- TBD/TODO count: 0 → 0
- Findings by severity: 2 HIGH, 5 MEDIUM, 4 LOW (0 CRITICAL)
- Attack wave: 12 angle attackers (6 angles × 2) + 3 divergence-probe outlines + 1 divergence diff → 110 candidates, merged to 38 groups
- Cull: 12 judges (4 buckets × 3 votes) → 11 promoted, 27 refuted
- Round-2 sweep: 2 fresh attackers → 15 candidates → 0 survived 3-vote verification

## Changelog

1. AR-001 — Defined "unprompted" in the Per-term status bullet (initial critique only; Discussion-phase wording earns discussion credit, not mastery count).
2. AR-002 — Added per-flaw-type perception record (last-5-exposure tally) to student.md schema; mastery gate rewritten to reference it.
3. AR-003 — Core/extension term marking added to Curriculum; mastery gate cross-references the marked subset.
4. AR-004 — Durability paragraph: three loss vectors enumerated with per-vector recovery (in-repo snapshots; out-of-repo mirror at `~/.local/state/ui-drill/`; new-machine honestly out of scope). Rewritten in round 2 after round-1 fix judged stuck.
5. AR-005 — Added `state/session-current.md` append-only checkpoint and "Interruption safety" paragraph.
6. AR-006 — Session loop step 2 now mandates use-before-critique cue for modules 6–8; interaction-only flaws restricted to cued exercises.
7. AR-007 — Module 9 grading reconciled (per-flaw rubric + holistic assessment) with explicit completion criterion.
8. AR-008 — Required-updates list expanded to include USAGE.md, AGENTS.md, docs/repo-guidelines.md.
9. AR-009 — `state/` convention to be documented in both AGENTS.md and repo-guidelines.md.
10. AR-010 — Post-capstone maintenance mode added.
11. AR-011 — Out-of-project write path + allowlist note added to Environment notes.

## Rejected findings

None — all 11 promoted findings were fixed.

## Open questions

None — no stuck findings remain.

## Notable refuted candidates (for the record)

27 of 38 merged groups were refuted at cull, including: session-length "10–15 min" treated as design rationale rather than testable criterion; "side-by-side reveal" judged feasible in a single self-contained HTML file; self-authored answer keys judged valid because the tutor grades the user against flaws it deliberately constructed; "never count-based" read as the standard mastery-vs-seat-time term of art; skills.yaml metadata judged derivable from the doc's stated decisions.
