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
| `adversarial-review` | `general` | Codex, Claude, Cursor, Gemini, Copilot | `deep` | Script-backed fresh-context critique and optional revise/reject resolution of repository planning documents. |
| `prompt-engineer` | `general` | Candidate: Codex and Claude disabled; Cursor and Gemini disabled | `standard` (heavy `deep`) | Explicit prompt diagnosis and revision after qualification; no ordinary managed install or implicit activation. |
| `code-review` | `codex-cursor` | Codex, Gemini, Copilot | `deep` | Thorough review of diffs, PRs, staged changes, dirty worktrees, and verified review-finding remediation. |
| `milestone-orchestrator` | `general` | Codex, Claude | `deep` | Planning and unattended multi-agent implementation of large repository milestones, ending in a reviewed draft PR. |
| `ui-drill` | `claude` | Claude | `standard` | Adaptive tutoring sessions that train UI/UX critique vocabulary and flaw perception with generated mockups. |

## `prompt-engineer`

Use `$prompt-engineer` explicitly when you want prompt diagnosis or a proposed
revision. The candidate does not activate implicitly, and its managed install is
disabled for Codex, Claude, Cursor, and Gemini until qualification and a
separate explicit cutover approval are complete.

### Profiles and qualification

Choose the lightest profile that can support the claim:

- **Quick**: bounded diagnosis or a small wording change; label conclusions as
  unmeasured when comparative evidence is not available.
- **Standard**: one prompt or prompt-bearing skill with controlled evaluation,
  fixed inputs, and a reproducible report.
- **Ecosystem**: multiple related prompts whose triggers, handoffs, or shared
  instructions must be evaluated together.

`UNMEASURED` and `BLOCKED` are measurement statuses, not final decisions. When
required evidence is missing, the final decision label remains `INCONCLUSIVE`.

The checked-in qualification surface is provided by
`scripts/prompt-engineer-eval`, with host-boundary checks through
`scripts/prompt-engineer-sandbox`. Qualification requires an explicit positive
`PROMPT_ENGINEER_MAX_USD` ceiling, an operator-selected model and effort for
each host, and a maximum operator budget of eight hours. The fixed run budgets
are 96 behavioral executor runs, 40 trigger runs, and at most 64 judge runs;
there is no implicit monetary or time expansion.

### Cutover, rollback, and retention

Qualification produces a report and stops. Cutover evaluation is currently fail-closed:
the checked-in gate only evaluates scorer decisions, exact Codex and Claude capability records, Ruby
compatibility, and sandbox evidence; it returns fail-closed results and exposes
no mutation or rollback command. Live cutover, backup retention, and deletion
remain unavailable until a separately reviewed implementation and explicit
operator approval exist.

## `adversarial-review`

Use `adversarial-review` before implementing non-trivial, high-impact,
ambiguous, security-sensitive, architecture-shaping, or expensive-to-rework
plans and specs.

Inputs must be repository files: a spec, a plan, or both. The portable Ruby
control plane owns task contracts, validation, state, IDs, and reports; host
agents execute its read-only task bundles.

### Invocation

`$adversarial-review`, `/adversarial-review`, Cursor/Gemini skill activation,
and equivalent natural language map to the checked-in executable:

```bash
AR_SKILL_DIR="/absolute/path/to/installed/adversarial-review"
REVIEW_REPO="/absolute/path/to/reviewed/repository"
"$AR_SKILL_DIR/scripts/adversarial-review" start \
  --repository "$REVIEW_REPO" --spec docs/spec.md --plan docs/plan.md \
  --tier default --mode revise --output both \
  --executor auto --model MODEL --effort EFFORT
```

Resolve `AR_SKILL_DIR` from the skill loaded by the host, not from the reviewed
checkout. Ruby 2.6 or newer is required. A POSIX host exposing `openat`,
`linkat`, `renameat`, and `unlinkat` gets the hardened filesystem backend; every
other host, including native Windows, runs the portable backend, which keeps the
full workflow and discloses the guarantees it cannot enforce. Use the manual
fallback only when Ruby itself is unavailable.

On Windows, invoke the executable through the interpreter — it is an
extensionless `#!/usr/bin/env ruby` script, which Windows cannot execute
directly:

```text
ruby "<AR_SKILL_DIR>/scripts/adversarial-review" start --repository "<REVIEW_REPO>" ...
```

Run any subcommand with `--help` for parser-level syntax. Host agents map `--high` to `--tier high`, `--ultra` to
`--tier ultra`, `--report-only` to `--mode critique --output both`, and
`--chat-only` to `--output chat`.

### Options

The parser choices are `--executor auto|codex|claude|cursor|gemini|generic` and
`--output chat|file|both`.

| Option | Values/default | Behavior |
|--------|----------------|----------|
| `--spec`, `--plan` | one or both required | Repository-relative review targets. |
| `--repository` | current directory | Canonical repository root. |
| `--tier` | `default|high|ultra`; `default` | `high` adds divergence/arbitration; direct `ultra` is Claude-only. Non-Claude auto selection uses generic, never a silent `high` downgrade. |
| `--mode` | `critique|revise`; `revise` | Critique reports only; revise accepts parent fixes/rejections and verifies resolution. |
| `--output` | `chat|file|both`; `both` | Select rendered destinations. File output defaults beside the first target as `<stem>-review.md`. |
| `--executor` | `auto|codex|claude|cursor|gemini|generic`; `auto` | Only qualifying public auto selection may convert an ineligible pre-content adapter result to generic bundles; explicit direct stops. |
| `--model`, `--effort` | `inherit` | Direct execution requires explicit exact values. Generic mode records requested values and host evidence. |
| `--jobs` | positive integer; `1` | Direct execution rejects values above 1; generic emits independent bundles for host-native parallelism. |
| `--context` | repeatable path | Add bounded repository context. |
| `--run-dir` | generated beneath Git common state | Override durable run state location. |
| `--report` | generated sibling report | Override the report path outside the run directory and protected inputs. |
| `--report-only` | alias | Exactly `--mode critique --output both`. |
| `--chat-only` | alias | Exactly `--output chat`. |
| `--ultra` | alias | Exactly `--tier ultra`. |

Alias normalization is order-independent. Contradictory explicit values are
rejected; in particular, `--report-only` never permits `--mode revise` and
cannot be combined with `--chat-only`.

There is no quick/low tier and no silent model, effort, tier, or vendor
downgrade. The public CLI declares `parallel_dispatch` unavailable, so its
required gate makes direct adapter results ineligible before reviewed content. Direct adapter classes
are fixture-conformant for embedding orchestrators that supply real dispatch
evidence; the public CLI does not claim direct execution. Generic bundles are
intended for host-native parallelism.

Only `--executor auto`, at the pre-content boundary with zero prior external
attempts, converts an ineligible result to emitted Generic bundles. Explicit direct
selection stops with exit `4` or `5`, stays pinned/resumable, and never converts
the result to Generic bundles. No post-content failure changes vendor.

### Lifecycle

1. Run `start`; retain `run_dir`. `pending_task_handoffs` is the normative dispatch surface;
   `pending_tasks` is path inventory for compatibility, not dispatch authority.
   Read each task's bytes exactly once and verify `task_sha256` before parsing JSON
   or using task-controlled fields. Then match cwd/schema metadata to the trusted
   handoff and set the worker cwd. Keep the schema under the installed skill root;
   read it once, verify `schema_sha256`, and parse/use those same in-memory bytes.
   Never reopen task/schema paths for dispatch. A task mismatch fails as
   `task_digest_mismatch`.
2. For each generic reviewer task, return its closed-schema result and capability
   declaration with `ingest --run-dir RUN --task ID --result RESULT.json
   --capabilities CAPABILITIES.json`. Return exactly the assigned
   `checks_completed`; one missing-check repair is permitted and recorded.
3. Run `continue --run-dir RUN` until more results or parent actions are needed.
   Submit parent-only `FIXED|REJECTED` actions with `continue --actions
   ACTIONS.json`; reviewers never edit targets.
4. Repeat `continue` through per-ID resolution and the round-two fresh sweep.
   The two-round cap ends as passed or `DID NOT CONVERGE`.
5. Inspect resumable state with `status --run-dir RUN --json`.
6. Render the finished run's verdict with `report --run-dir RUN`, adding
   `--report PATH` to write the file. The report is the run's own output: an
   unfinished run is refused as `run_not_terminal` and names what it still owes,
   so never hand-write a verdict the control plane did not emit.

Reports contain immutable candidate/finding IDs, `PROMOTE|REFUTE|UNPROVEN`
dispositions, source angles, current target digests, complete capability and
executor/CLI/model/effort provenance, retries, timing, and usage metrics when
exposed. `DEGRADED CAPABILITIES` replaces only an ordinary `PASSED` when a
required capability is unavailable or a safety boundary is behavioral.
`REPORT ONLY`, `PASSED WITH OPEN QUESTIONS`, and `DID NOT CONVERGE` keep their
verdict. Retained verdicts disclose degraded capabilities separately.
Running a review never installs global links or agent configuration.

If Ruby is unavailable, use the bounded manual fallback in the skill: follow
its attack/judge references and schemas, preserve IDs and parent authority,
disclose degraded scripting capabilities, and do not invent durable state.

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
