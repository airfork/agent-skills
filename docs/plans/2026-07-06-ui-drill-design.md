# UI Drill Skill — Design

## Purpose

A tutoring skill (`/ui-drill`) that trains the user to critique UI/UX precisely — going from "this feels bad" to naming the issue in the field's shared vocabulary. It balances two distinct skills, graded separately:

- **Perception** — noticing that a flaw exists at all.
- **Articulation** — naming it precisely ("three different gap sizes with no consistent scale" vs "the spacing is weird").

It is a *course*, not random drills: a fixed curriculum governs sequencing, a persistent student model makes every session a continuation of the last, and difficulty adapts to demonstrated gaps. The curriculum is never exposed mid-exercise; it silently governs what comes next.

## Why build this (landscape)

Existing tools train perception (Can't Unsee) or supply vocabulary passively (Refactoring UI, Laws of UX, Nielsen's heuristics). None force *production* of the language, and retrieval only improves through production practice. The user's gap is retrieval/articulation, not taste — hence a model-in-the-loop tutor that reads free-text critiques and grades wording, which self-graded tools cannot do.

## Placement and layout

Lives in the user's skills repo at `skills/claude/ui-drill/` (Claude-only category):

```
skills/claude/ui-drill/
  SKILL.md                  # drill-master instructions: session loop, grading, adaptation
  references/curriculum.md  # the teaching plan (static, versioned)
  state/                    # mutable, git-ignored via new repo convention
    student.md              # distilled student model (bounded, rewritten each session)
    session-current.md      # append-only checkpoint log for the in-progress session
    exercises/              # generated mockups (flawed + fixed HTML), session summaries, student.md snapshots
```

**New repo convention** (this design introduces it): any skill may have a `state/` subfolder for mutable data. One root `.gitignore` rule (`skills/**/state/`) covers all skills; convention documented in both `AGENTS.md` (Ground Rules) and `docs/repo-guidelines.md` (Skill Folder Rules list gains an optional `state/` entry) so the two convention docs stay consistent.

**Durability**: `state/` is deliberately untracked, so it needs protection against three loss vectors. (1) *Bad or lossy rewrite*: before each end-of-session rewrite, the outgoing `student.md` is snapshotted into `state/exercises/` alongside that session's summary — an in-repo restorable history. (2) *`git clean -xdf` or re-clone on this machine*: in-repo snapshots don't survive these, so at session end the skill also mirrors `student.md` (plus the session summary) to `~/.local/state/ui-drill/`, outside the repo entirely; recovery is copying the mirror back. (3) *New machine*: not covered — the design explicitly scopes this as a single-machine tool with no state sync; SKILL.md states this and the recovery paths for (1) and (2).

`CATALOG.md`, `skills.yaml`, `USAGE.md`, `AGENTS.md`, and `docs/repo-guidelines.md` are all updated in the same change that adds the skill (per the repo Change Checklist).

## Curriculum

Nine modules, visual foundation first, interaction second, mirroring how the material is actually taught (Refactoring UI leads with hierarchy; art-school "form before color" puts color after form; modules 6–8 follow Norman's *Design of Everyday Things* then Nielsen's heuristics):

1. **Visual hierarchy + Gestalt principles** — proximity, similarity, common region, figure-ground; size/weight/position as hierarchy levers. Gestalt is folded in here as the perceptual bedrock and prime "why it feels bad" vocabulary.
2. **Spacing & layout** — spacing scale, vertical rhythm, grids, density, whitespace as grouping.
3. **Typography** — scale, line-height, line length, weight pairing, hierarchy through type.
4. **Color & contrast** — contrast ratios and accessibility, semantic color, restraint, grayscale-first thinking.
5. **Alignment & consistency** — optical vs mathematical alignment, consistent components, polish.
6. **Affordances & signifiers** — perceived affordances, discoverability, mental models (Norman).
7. **Feedback & system status** — visibility of status, response to input, loading/disabled/hover states (Nielsen).
8. **Flows, errors & edge states** — error prevention and recovery, empty states, edge cases, flow friction.
9. **Capstone** — realistic compound-flaw screens; the user writes paragraph-length critiques. Grading remains the standard per-flaw two-axis rubric underneath (the answer key still exists and results still feed the ledger), *plus* a holistic assessment of the critique as writing: prioritization (worst problems first), severity calibration, and coherence. Module 9 completes after two consecutive capstones with ≥80% of planted flaws caught, a majority articulated `precise`, and a holistic pass.

Each module lists ~8–12 target vocabulary terms and the flaw patterns used to exercise them. Within each module's list, `curriculum.md` marks a subset (typically 6–8) as **core** — these gate module completion — and the rest as **extension** (tracked and drilled, but not gating). Interactive concepts (modules 6–8) are exercised with interactive HTML mockups, not static screenshots.

**After the capstone**: once module 9 reaches mastery the course enters **maintenance mode** — `student.md` records position as `complete`, and subsequent `/ui-drill` sessions become pure mixed review across the full vocabulary (or a user-requested focus area). The skill states this transition to the user when it happens.

## Session loop

Invoked as `/ui-drill`. Sessions are short by design: 3–4 exercises, ~10–15 minutes (production practice is tiring; daily-short beats weekly-long).

Per session: read `curriculum.md` and `student.md`, pick targets — mostly current-module material plus one or two review items from earlier modules (spaced repetition the user never has to manage).

Per exercise:

1. **Mockup** — generate a self-contained HTML mockup with deliberately planted flaws, rendered in the side panel. Always a plausible product surface (settings page, checkout step, pricing card), never an abstract toy.
2. **Critique** — the user responds in plain prose, as they would to a coworker. For interactive exercises (modules 6–8), the tutor explicitly cues use-before-critique in the exercise prompt ("click through the flow, hover the controls, submit the form — then critique"); interaction-only flaws are only planted in exercises carrying that cue, so a miss is a genuine perception miss, not a failure to know the mockup was interactive.
3. **Discussion phase** — the tutor probes and challenges ("is that a spacing problem or a hierarchy problem?") so vague intuitions get sharpened into words *before* any answers are shown. Advances only when the user confirms they want the reveal.
4. **Reveal** — the fixed version rendered side-by-side; each planted flaw named with its canonical term plus one sentence on why it matters. Grading on both axes: perception (caught / missed per flaw) and articulation (precise / vague / gestured per caught flaw).
5. **Post-reveal chat** — open discussion of the reveal until the user calls for the next exercise. Nothing advances without explicit user confirmation.

Early in each module, some exercises are **taught examples**: the tutor walks through the critique itself, modeling the language before asking the user to produce it. The taught:tested ratio shifts test-heavy as the module progresses.

## Mockup generation and quality

The grading model assumes everything not deliberately broken is clean, so mockup quality is structural, not aspirational:

- **Fixed-version-first**: each exercise generates the *clean* mockup first, then derives the flawed version by applying the planted flaws as minimal, enumerated mutations. The answer key is exactly the mutation list; the flawed version is by construction "a good design with N specific things wrong," and the reveal diff is apples-to-apples.
- **Shared base kit**: `references/mockup-kit.css` defines a small design system (spacing scale, type scale, neutral palette + accent, button/input/card components with hover/focus/disabled states) that every mockup builds on. This keeps baseline quality consistent ("modern and designed") and mirrors the pedagogy: planting a flaw = deviating from the system, fixing it = returning to it.
- **Pre-send checklist** in SKILL.md: before sending, the tutor verifies the mockup renders without breakage, uses realistic content (no lorem-ipsum filler), and contains no kit violations outside the planted mutations.
- **Safety valve**: the false-positive rule already credits defensible unplanted catches; if a mockup turns out broken or ambiguous mid-exercise, the tutor says so and regenerates rather than defending it.

## Student model and personalization

`student.md` is a tutor's notebook, not a log. After each session the skill **rewrites** it (bounded, ~150 lines) rather than appending. It holds:

- Per-term status: taught? produced correctly unprompted? roughly how many times? ("**Unprompted**" means the term — or an accurate specific description of the flaw — appeared in the user's *initial critique*, step 2, before any tutor probing. Wording that only emerges during the Discussion phase counts as *prompted*: it earns discussion credit but not the unprompted-production count that mastery and review-queue exit require.)
- Per-flaw-type perception record: a compact tally of the last 5 exposures of each flaw type (e.g. `spacing-scale: ✓✓✗✓✓`), updated whenever that flaw type is planted. This is the persisted source for the mastery gate's hit-rate — "recent" means these last-5-exposure windows, across sessions.
- **Qualitative diagnoses** — the real payload: "describes hierarchy problems only in terms of size, never weight or position"; "over-attributes problems to spacing when the real issue is grouping"; "strongest on color, weakest on typography."
- Current module/position and active review queue.

Old detail is distilled away as it stops being diagnostic. Raw history (exact critique wording) is deliberately sacrificed; per-session summaries are archived in `state/exercises/` and consulted only when a diagnosis seems wrong. Within a session, personalization is full-context by nature; the file only carries the between-session distillate.

**Interruption safety**: after each exercise's reveal, the tutor appends that exercise's grading deltas (terms produced, perception marks, notable diagnoses) to `state/session-current.md`. The end-of-session rewrite consumes this log and deletes it. If a session dies mid-way (context limit, closed terminal, user walks away), the next `/ui-drill` finds the leftover log, folds it into `student.md` first, and then proceeds — so an interrupted session loses at most the in-flight exercise, never the whole session.

## Adaptation and progression

- **Mastery-based advancement**: a module completes when each core term (the marked subset in `curriculum.md`) has been produced unprompted ~2 times and perception hit-rate on its flaw types is ≥ ~80% over each flaw type's last-5-exposure window (i.e. at most one recent miss per flaw type). Advancement is gated on demonstrated mastery, not on a fixed number of exercises completed.
- **Perception gap** (flaw missed entirely) → remediation: re-seed that flaw type into upcoming exercises; drop back to taught examples on repeated misses.
- **Articulation gap** (seen but named vaguely) → the precise term enters the review queue and recurs until produced unprompted twice.
- **Review forever**: past-module flaw types keep appearing at low frequency; compound exercises mix current and old flaws so vocabulary doesn't silo.
- **Acceleration**: if a session shows breezing, skip ahead within the module. Difficulty is always driven by the student model, never a fixed script.

## Grading rubric

Per planted flaw, two independent verdicts:

- Perception: `caught` / `missed`.
- Articulation (only if caught): `precise` (canonical term or accurate specific description) / `vague` (right neighborhood, imprecise wording) / `gestured` ("something's off here").

False positives (user flags a non-planted issue) are discussed on merit — real UIs have unplanned flaws and a generated mockup may too; a defensible catch is credited, not penalized.

## Environment notes (decided during design)

- Model-in-the-loop via the user's Claude Code subscription — no API key, no standalone app.
- Mockups rendered as HTML files in the side panel (SendUserFile/Artifact); flawed and fixed versions both saved to `state/exercises/`.
- `state/` writes land under the symlink-installed skill directory (resolving to this repo), which is outside the active project's working directory — Claude Code will prompt for out-of-project writes. SKILL.md documents the state path explicitly, and the setup step adds a write allowlist entry for it to the user's global settings so drills aren't interrupted by permission prompts.
- Skill is Claude-only (`skills/claude/`), tier `standard` expected.
