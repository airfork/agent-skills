# Skill Usage

This is the top-level, operator-facing reference for how to invoke the skills in
this repository. Keep it in sync with `CATALOG.md`, `skills.yaml`, and each
skill's `SKILL.md`.

Use this file when you want to know:

- which skills exist
- how to invoke a skill
- which options, flags, tiers, or modes are supported
- what actions a skill is allowed to take

`SKILL.md` remains the runtime instruction source that agents read while
executing a skill. This file is the authoritative human-facing usage summary, so
important invocation options must not live only inside an individual skill
folder.

## Skills

| Skill | Category | Install | Recommended tier | Use for |
|-------|----------|---------|------------------|---------|
| `adversarial-review` | `general` | Codex, Claude, Gemini | `deep` | Fresh-context critique of specs, plans, migration plans, architecture designs, and other planning docs before implementation. |
| `code-review` | `codex-cursor` | Codex, Gemini | `deep` | Thorough review of diffs, PRs, staged changes, dirty worktrees, and verified review-finding remediation. |
| `milestone-orchestrator` | `general` | Codex, Claude | `deep` | Planning and unattended multi-agent implementation of large repository milestones, ending in a reviewed draft PR. |
| `ui-drill` | `claude` | Claude | `standard` | Adaptive tutoring sessions that train UI/UX critique vocabulary and flaw perception with generated mockups. |

## `adversarial-review`

Use `adversarial-review` before implementing non-trivial, high-impact,
ambiguous, security-sensitive, architecture-shaping, or expensive-to-rework
plans and specs.

Inputs must be repository files: a spec, a plan, or both. The v1 workflow does
not review pasted text, tickets, or external docs.

### Invocation

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

Natural-language equivalents also apply, such as:

```text
Run adversarial review on the payments spec and implementation plan.
```

### Options

| Option | Behavior |
|--------|----------|
| no flag | Default maximum-rigor pipeline: attack wave, refute-or-promote cull, revise/reject, resolution verification, two-revise-round cap. All roles use xhigh reasoning when available. |
| `--high` | Default pipeline plus arbiter pass for stuck findings and the divergence probe angle. |
| `--ultra` | Claude only. Implies `--high`; run as an UltraCode workflow with wider fan-out, 3-vote refutation per finding, and optional cross-model arbitration. In Codex, downgrade to `--high` and disclose it. |
| `--report-only` | Attack, cull, and report findings only. Do not revise documents, run resolution checks, run the round-2 fresh sweep, or emit convergence verdicts tied to revision. |

There is no quick or low tier for this skill.

### Action Rules

- Review may spawn read-only attacker, judge, and arbiter subagents without
  asking for extra permission.
- Attackers may read repository files needed to verify document claims.
- The parent may edit only the reviewed spec or plan files during revision.
- The workflow must preserve a rejection path for weak or incorrect findings.
- Reports are written next to the first reviewed document as
  `<doc-stem>-review.md` by default.

## `code-review`

Use `code-review` to inspect local changes, branches, or PRs, and optionally to
fix verified findings.

### Invocation

Codex and Gemini install this as one skill named `code-review`; address mode is
not a separate command or skill.

```text
Use $code-review to review staged changes with quick intensity.
Use $code-review to review the working tree with standard intensity.
Use $code-review to review PR #123 with high intensity.
Use $code-review to review branch changes with deep intensity.
Use $code-review to address the verified findings from the last code review.
Use $code-review to address actionable review comments on PR #123.
Use $code-review --fix --commit to review the working tree with high intensity, address applicable findings, verify, and commit.
Use $code-review --fix --push to review staged changes with standard intensity, fix applicable findings, commit, and push.
Use $code-review --fix --pr to review branch changes with high intensity, fix applicable findings, commit, push, and open a draft PR.
```

Natural-language equivalents also apply, such as:

```text
Review my current branch with deep intensity.
Address the PR review comments on PR #123.
```

### Review Tiers

Review mode requires an explicit tier. Do not silently default to `standard`.

| Tier | Aliases | Structure | Use for |
|------|---------|-----------|---------|
| `quick` | `q`, `fast` | One inline diff pass, no subagents, no verify. | Small, low-risk diffs. |
| `standard` | `std`, `normal`, `default` | 8 finder angles, 1-vote verify, precision-tuned. | Normal local or PR review. |
| `high` | `thorough` | 8 finder angles, recall-tuned. | Pre-merge review. |
| `deep` | `xhigh`, `max`, `full` | 10 finder angles plus gap sweep, recall-tuned. | Large, risky, security-sensitive, or release-blocking changes. |

### Targets

| Target phrase | Review scope |
|---------------|--------------|
| no target | Committed branch diff plus staged, unstaged, and untracked files. |
| `branch`, `committed`, `HEAD` | Committed branch diff only. |
| `working tree`, `dirty`, `local changes` | Staged, unstaged, and untracked files only. |
| `staged` | Staged changes only. |
| `unstaged` | Unstaged changes only. |
| `PR #123`, PR URL, `pr` | Pull request diff and metadata via `gh`. |

### Flags

Flags are opt-in action gates. They may appear anywhere in the prompt.

| Flag | Behavior |
|------|----------|
| `--fix` | After review, enter address mode for verified findings that still apply and are safe to fix. |
| `--commit` | After successful address/review verification, commit in-scope changes. |
| `--push` | Push the current branch after successful verification. Implies `--commit` when in-scope changes are uncommitted. |
| `--pr` | Push the current branch and open a draft PR. Implies `--push` and `--commit`; does not imply `--fix`. |
| `--comment` | For PR targets only, post the final review report as a PR comment. |

Action order is always:

```text
review -> fix -> verify -> commit -> push -> PR/comment
```

The skill does not support convenience flags such as `--force`, `--no-verify`,
`--stash`, or `--merge`. Those operations require explicit natural language.

## `milestone-orchestrator`

Use `milestone-orchestrator` for large milestones that deserve an interactive
design/approval phase (PREPARE) followed by an unattended multi-agent
implementation run (RUN) that ends in a reviewed draft pull request.

### Invocation

Codex:

```text
Use $milestone-orchestrator to plan and run the <milestone> milestone
Use $milestone-orchestrator prepare docs/milestones/<slug>/
Use $milestone-orchestrator run docs/milestones/<slug>/
Use $milestone-orchestrator status docs/milestones/<slug>/
```

Claude Code:

```text
/milestone-orchestrator <milestone description>
/milestone-orchestrator run docs/milestones/<slug>/
```

Natural-language equivalents also apply, such as:

```text
Plan this milestone with me, then implement it autonomously and open a draft PR.
```

### Modes

| Mode | Behavior |
|------|----------|
| bare invocation | PREPARE, then after explicit approval continue into RUN. |
| `prepare` | Stop after the reviewed SPEC/PLAN, approval, and STATE initialization. |
| `run` | Resume RUN from approved milestone artifacts. |
| `status` | Reconcile STATE against git/host/forge evidence and report; dispatch nothing. |

### Action Rules

- PREPARE is interactive; RUN interrupts the user only for loss of authority,
  a genuine spec contradiction, exhausted budgets, or infrastructure failure.
- The coordinator is a manager: during RUN it edits only milestone control
  artifacts, never implementation files.
- Default publication authority is local commits + push + one draft PR with
  the configured human git author. PR-ready and reviewer notification require
  their own recorded flags. Merge and deploy are never automated.
- Final whole-branch review is mandatory before handoff: Codex workers use
  this repository's `code-review` skill, Claude workers use Claude's own
  `/code-review`.
- Cleans only run-created worktrees, terminals, and browser tabs recorded in
  the run's STATE ledger; foreign or ambiguous resources are retained and
  reported.
- v1 validation status and deferred layers are recorded in the skill's
  `references/validation.md`.

## `ui-drill`

Use `ui-drill` (Claude Code only) to run a tutoring session in your ongoing
UI/UX critique course. It is a personal learning tool, not a review tool — for
critiquing your own projects use design-review skills instead.

### Invocation

```text
/ui-drill
```

Natural-language equivalents also apply, such as:

```text
Let's do a UI drill session.
Continue my UI critique course.
```

No flags or tiers. Each session picks up from the persistent student model; the
curriculum and difficulty are managed by the skill, not by invocation options.

### Session Shape

Each session runs 3–4 exercises. Per exercise: a generated flawed mockup is
rendered in the side panel → you critique it in prose → Socratic discussion
(nothing revealed) → on your go, the reveal with the fixed version, canonical
terms, and grading → open chat until you call for the next exercise.

### Action Rules

- Reads and writes only inside the skill's `state/` folder (git-ignored) plus a
  session-end mirror to `~/.local/state/ui-drill/`.
- Output files: exercise HTML mockups, session summaries, and student-model
  snapshots under `state/exercises/`; the evolving `state/student.md`.
- Sends mockups to the side panel via file rendering; no network, git, or
  GitHub actions.
- Single-machine tool: state does not sync across machines.

## Updating This File

When adding or materially changing a skill, update this file in the same change
if any of these changed:

- invocation syntax
- flags or options
- tiers or model guidance
- targets or accepted inputs
- action permissions, side effects, or output files

Do not require users to inspect individual skill folders just to discover the
supported usage surface.
