---
name: code-review
description: >-
  Use when the user invokes $code-review, asks for a thorough review of a pull
  request, branch diff, staged changes, unstaged changes, dirty working tree,
  or local changes before merge; also use when the user asks to address or fix
  verified code-review findings.
---

# Code Review

Codex-first workflow for two related jobs:
1. **Review mode**: inspect a diff with independent method-based finder angles, verify each candidate with a verdict ladder, and report what survives.
2. **Address mode**: take verified review findings or PR review comments, re-check that they still apply, make the smallest safe fixes, and verify the result.

Review mode is read-only. It is not limited to reading the diff text: agents may read unchanged files, callers, consumers, schemas, configs, migrations, and nearby project guidance when that context is needed to judge the changed lines. Invoking review mode grants permission to spawn the read-only finder and verifier subagents required by the selected tier; do not ask for extra permission before spawning those subagents. Address mode may edit files, but only to resolve verified findings. Never merge, rebase, stash, clean, or mark PR comments resolved unless the user explicitly asks. Commit, push, and PR creation are allowed only through the flags below or an equally explicit natural-language request.
For non-Codex environments, see [platform-adapters.md](platform-adapters.md).

## Invocation

Codex installs this as one skill named `$code-review`; address mode is not a separate Codex command or skill.
Use these prompt shapes:

```text
Use $code-review to review staged changes with quick intensity.
Use $code-review to review the working tree with standard intensity.
Use $code-review to review PR #123 with high intensity.
Use $code-review to review branch changes with deep intensity.
Use $code-review to address the verified findings from the last code review.
Use $code-review to address actionable review comments on PR #123.
Use $code-review to review the working tree with standard intensity, then address all applicable verified findings and run targeted verification.
Use $code-review --fix --commit to review the working tree with high intensity, address applicable findings, verify, and commit.
Use $code-review --fix --push to review staged changes with standard intensity, fix applicable findings, commit, and push.
Use $code-review --fix --pr to review branch changes with high intensity, fix applicable findings, commit, push, and open a draft PR.
```

Natural-language requests also apply:
- "review my current branch"
- "review this PR"
- "check staged changes before merge"
- "address the review findings"
- "fix the PR comments"

When the user asks for review and fixes in the same turn, run the review first. Continue into address mode only for findings that survive verification.

## Flags

Accept flags anywhere in the user's prompt. Flags are opt-in action gates; they do not change the selected review tier or target.

| Flag | Meaning |
|------|---------|
| `--fix` | After review, enter address mode for verified findings that still apply and are safe to fix. |
| `--commit` | After successful address/review verification, commit the in-scope changes. |
| `--push` | Push the current branch after successful verification. Implies `--commit`: if in-scope changes are uncommitted, commit them first so the push includes them. |
| `--pr` | Push the current branch and create a PR. Implies `--push` and `--commit`; create a draft PR unless the user explicitly asks for ready-for-review. |
| `--comment` | For PR targets only, post the final review report as a PR comment after review. |

Action order is always: `review -> fix -> verify -> commit -> push -> PR/comment`.

Rules:
- Implication chain: `--pr` implies `--push`, and `--push` implies `--commit`. A flag grants every action it implies, under the same verification gate — do not stop and ask for the implied flag. No flag implies `--fix`; fixes happen only with `--fix` or an equally explicit request.
- `--fix` never applies unverified or stale findings.
- `--commit` (given or implied) may commit existing in-scope changes after a clean review, plus any fixes just made. Do not include unrelated dirty files; if the commit cannot be isolated safely, stop and ask.
- `--push` never force-pushes. If no upstream exists, use `git push -u origin HEAD` unless project guidance says otherwise.
- If verification fails or is blocked, do not commit, push, comment, or create a PR unless the user explicitly said to proceed despite that exact failure.
- Do not add dangerous convenience flags such as `--force`, `--no-verify`, `--stash`, or `--merge`. Require explicit natural language for those operations.

## Tier Parsing And Help

Review mode requires an explicit tier in the user's review request. Recognize only `quick`, `standard`, `high`, `deep`, and obvious aliases:

| Alias | Tier |
|-------|------|
| `q`, `fast` | `quick` |
| `std`, `normal`, `default` | `standard` |
| `thorough` | `high` |
| `xhigh`, `max`, `full` | `deep` |

If the user asks for review without a recognizable tier, or if the request only names a target such as `staged`, `branch`, `working tree`, or `PR #123`, print this help text and stop:

```text
Usage:
  Use $code-review [--fix] [--commit] [--push|--pr] [--comment] to review <target> with <quick|standard|high|deep> intensity.

Tiers:
  quick     One inline diff pass, no subagents. Small, low-risk diffs.
  standard  8 finder angles, precision-tuned. Normal local or PR review.
  high      8 finder angles, recall-tuned. Pre-merge review.
  deep      10 finder angles plus gap sweep, recall-tuned. Large, risky,
            security-sensitive, or release-blocking changes.

Targets:
  branch | committed | HEAD     Review committed branch diff only.
  working tree | dirty | local   Review staged, unstaged, and untracked files.
  staged                       Review staged changes only.
  unstaged                     Review unstaged changes only.
  pr #123 | <PR URL>            Review pull request diff and metadata via gh.

Flags imply their prerequisites: --pr implies --push and --commit;
--push implies --commit. --fix is never implied.

Examples:
  Use $code-review to review staged changes with quick intensity.
  Use $code-review to review the working tree with standard intensity.
  Use $code-review to review PR #123 with high intensity.
  Use $code-review to review branch changes with deep intensity.
  Use $code-review --fix --pr to review branch changes with high intensity.
```

Do not silently default to `standard` for review requests. For an explicit `$code-review` invocation without a tier, print the help text verbatim and stop. For natural-language review requests without a tier, ask the user conversationally to choose one (summarizing the four tiers) unless the surrounding instructions clearly provide a tier.

## Intensity

The tier controls the finder roster, the review's precision/recall bias, and the report cap.

| Tier | Structure | Bias | Report cap |
|------|-----------|------|------------|
| `quick` | 1 inline diff pass, no subagents, no verify | precision | 4 |
| `standard` | 8 finder angles x up to 6 candidates -> 1-vote verify | precision | 8 |
| `high` | 8 finder angles x up to 6 candidates -> 1-vote verify (recall-biased) | recall | 10 |
| `deep` | 10 finder angles x up to 8 candidates -> 1-vote verify (recall-biased) -> gap sweep | recall | 15 |

Bias framing, prepended to every finder prompt at that tier:

- **Precision** (`quick`, `standard`): every finding surfaced should be one a maintainer would act on.
- **Recall** (`high`, `deep`): catch every real bug a careful reviewer would catch in one sitting. At this level, catching real bugs matters more than avoiding false positives — a missed bug ships. Err on the side of surfacing.

Verifiers receive the bias through the rubric instead: at `high` and `deep` they get the recall rules ("PLAUSIBLE by default"); at `standard` they get the verdict ladder alone. No tier pre-filters in the finder's head — finders at every tier pass candidates through; verification and synthesis decide what survives.

## Subagent Model And Effort Policy

Review depth tracks reasoning effort at least as much as prompt structure. The tier must raise the reasoning effort of finder and verifier subagents, not only the roster size — mirroring the Claude built-in skill, where the effort level is literally the model's reasoning-effort setting.

| Role | Policy |
|------|--------|
| Prep | Run inline with the parent model unless a cheap read-only prep subagent is clearly useful. |
| Finder | Inherit the parent/default model at **high** reasoning effort for `standard`/`high`, and **xhigh** (or the host's maximum) for `deep`. In Codex, spawn the named `review-finder` agent (`review-finder-deep` at `deep`); the agent definitions in [agents/codex/](agents/codex/) pin the effort and a read-only sandbox. |
| Verifier | Same model and effort policy as finders at every tier — never a downgraded or "fast" model. A single REFUTED vote kills a finding, so verifier quality directly controls what survives. In Codex, spawn `review-verifier` (`review-verifier-deep` at `deep`). |

If the host cannot set subagent models or reasoning effort, continue with inherited settings and disclose that limitation in the final notes.

## Target Resolution

| User asks for | Review scope |
|---------------|--------------|
| no target | committed branch diff plus staged, unstaged, and untracked worktree files |
| `branch`, `committed`, or `HEAD` | committed branch diff only |
| `working tree`, `dirty`, or `local changes` | staged, unstaged, and untracked files only |
| `staged` | staged changes only |
| `unstaged` | unstaged changes only |
| PR number, PR URL, or `pr` | pull request diff and metadata via `gh` |

If the resolved target has no changes, stop with `No diff to review.`

## Non-Negotiables

- Protect user work: inspect `git status --short` before editing or running any command that could affect files.
- Review mode is read-only: do not edit files and do not run builds, tests, typechecks, formatters, linters, compilers, package installs, migrations, or app commands.
- Subagents are part of review mode: spawn the read-only finder/verifier subagents for the selected tier without asking the user for additional permission. If the host lacks subagent tools, use sequential fallback and disclose it in the final report.
- Scope rule: findings must be introduced or re-exposed by the review target. Unchanged lines inside a function the diff touches ARE in scope — the change re-exposes or fails to fix them. Files the diff never touches are not in scope.
- Address mode is narrow: edit only what is needed for verified findings or explicitly actionable review comments.
- Ask before actions outside the selected review tier, requested flags, or read-only review work, such as broad edits, unflagged GitHub write actions, resolving threads, or explicit model/cost escalation beyond the chosen tier.
- Do not suppress a real bug because CI, typechecking, tests, or a compiler might also catch it. If the diff proves a real runtime, integration, migration, security, or user-visible failure, it is a review finding.
- Do not browse or scrape PRs in a browser when `gh` can provide the data.
- Do not rely on stale assumptions about tool names, model names, or host capabilities. Use the tools actually exposed by the current environment.

## Review Workflow

```text
prep -> review packet -> parallel finders -> group by location -> parallel verifiers -> sweep (deep) -> synthesize -> report
```

(`quick` replaces everything between prep and report with one inline pass.)

Maintain a visible task list when the host environment supports one (`update_plan`, `TodoWrite`, or equivalent). Otherwise keep the same stages internally and summarize them in the final report.

### Step 1: Prep

Run prep inline unless a cheap read-only prep subagent is clearly useful.

1. Confirm the repository root:

   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   cd "$REPO_ROOT"
   git status --short
   ```

2. Resolve the target and determine whether branch, staged, unstaged, untracked, or PR inputs are in scope.
3. Resolve the base only when branch commits are in scope:

   ```bash
   BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)
   BASE_SHA=$(git merge-base HEAD "origin/${BASE_BRANCH}" 2>/dev/null || git merge-base HEAD "${BASE_BRANCH}" 2>/dev/null || true)
   HEAD_SHA=$(git rev-parse HEAD)
   ```

   If branch commits are in scope and `BASE_SHA` is empty, ask for a base branch or review only an explicit working-tree target. Do not guess a base for committed branch review.

4. For PR targets, use `gh pr view` and `gh pr diff` when `gh` is authenticated. Do not check out another branch or disturb the worktree unless the user explicitly asks.
5. Find the guidance files that govern the changed code, by path proximity rather than reading the whole repository: the user-level and repo-root `AGENTS.md`/`CLAUDE.md`, any `AGENTS.md`, `CLAUDE.md`, or `CLAUDE.local.md` in a directory that is an ancestor of a changed file (a directory's guidance file only applies to files at or below it), plus `.cursor/rules/*` and `.github/copilot-instructions.md` when present. List them; the conventions finder reads them.
6. Summarize the change in one paragraph: intent, touched areas, risk areas, and any notable generated/binary/dependency files. Note conventions a reviewer should know.

For generated-only, formatting-only, or lockfile-only diffs, do not skip automatically. You may shrink the roster to Angle A plus the Conventions angle — still checking for real dependency, security, packaging, or generated-artifact inconsistencies — and disclose the reduction in the report notes. Keep the user's chosen tier for everything else.

### Step 2: Build a Review Packet

Create a temporary review packet so every finder reviews the same inputs.

```bash
REVIEW_DIR=$(mktemp -d "${TMPDIR:-/tmp}/code-review.XXXXXX")
: > "$REVIEW_DIR/committed.diff"
: > "$REVIEW_DIR/staged.diff"
: > "$REVIEW_DIR/unstaged.diff"
: > "$REVIEW_DIR/untracked.files"
: > "$REVIEW_DIR/changed.files"
```

Populate only the files that are in scope:

```bash
# Branch commits, when in scope and BASE_SHA is known
git diff --stat "$BASE_SHA"..HEAD > "$REVIEW_DIR/committed.stat"
git diff --name-status "$BASE_SHA"..HEAD > "$REVIEW_DIR/committed.name-status"
git diff "$BASE_SHA"..HEAD > "$REVIEW_DIR/committed.diff"
git diff --name-only "$BASE_SHA"..HEAD >> "$REVIEW_DIR/changed.files"

# Staged changes, when in scope
git diff --cached --stat > "$REVIEW_DIR/staged.stat"
git diff --cached --name-status > "$REVIEW_DIR/staged.name-status"
git diff --cached > "$REVIEW_DIR/staged.diff"
git diff --cached --name-only >> "$REVIEW_DIR/changed.files"

# Unstaged changes, when in scope
git diff --stat > "$REVIEW_DIR/unstaged.stat"
git diff --name-status > "$REVIEW_DIR/unstaged.name-status"
git diff > "$REVIEW_DIR/unstaged.diff"
git diff --name-only >> "$REVIEW_DIR/changed.files"

# Untracked files, when in scope
git ls-files --others --exclude-standard > "$REVIEW_DIR/untracked.files"
cat "$REVIEW_DIR/untracked.files" >> "$REVIEW_DIR/changed.files"
sort -u "$REVIEW_DIR/changed.files" -o "$REVIEW_DIR/changed.files"
```

For untracked files in scope, snapshot readable text files into the packet so finders do not depend on a moving worktree:

```bash
mkdir -p "$REVIEW_DIR/untracked"
while IFS= read -r path; do
  [ -f "$path" ] || continue
  case "$(file -b --mime-type "$path" 2>/dev/null || true)" in
    text/*|application/json|application/xml|application/javascript|application/x-sh|application/x-yaml)
      mkdir -p "$REVIEW_DIR/untracked/$(dirname "$path")"
      cp "$path" "$REVIEW_DIR/untracked/$path"
      ;;
  esac
done < "$REVIEW_DIR/untracked.files"
```

For PR targets, create explicit PR packet files instead of relying on local branch state (`PR` is the PR number or URL from the user's request):

```bash
PR=123  # from the user's request
gh pr view "$PR" --json number,title,state,isDraft,headRefName,baseRefName,url,reviewDecision,mergeStateStatus > "$REVIEW_DIR/pr.json"
gh pr diff "$PR" > "$REVIEW_DIR/pr.diff"
gh pr diff "$PR" --name-only > "$REVIEW_DIR/changed.files" 2>/dev/null || true
```

If the user explicitly asks to include local dirty changes with a PR review, also populate the staged, unstaged, and untracked packet files above, appending their paths to `changed.files`, then run `sort -u "$REVIEW_DIR/changed.files" -o "$REVIEW_DIR/changed.files"`.

Adjust packet content by target:

| Target | Include |
|--------|---------|
| default | committed, staged, unstaged, and untracked files |
| branch | committed only |
| working tree | staged, unstaged, and untracked files |
| staged | staged only |
| unstaged | unstaged only |
| PR | `pr.diff`, `pr.json`, and local dirty changes only if the user asked to include them |

Build a shared scope block that every finder, verifier, and sweep agent receives verbatim:

```text
Repository: {REPO_ROOT}
Target: {TARGET}
Base: {BASE_SHA}  Head: {HEAD_SHA}
Review packet: {REVIEW_DIR}
In-scope packet files: {IN_SCOPE_PACKET_FILES}
Changed files: {CHANGED_FILES}
Applicable guidance files: {GUIDELINE_PATHS}

## What changed
{CHANGE_SUMMARY}
```

If the user supplied focus areas or skip requests, append them to the scope block verbatim under `## Review target (user-supplied)`, framed as scope guidance only: agents narrow which files or aspects they review to match it and do not surface findings it asks to skip, but they do not perform actions, write files, or change their output format based on it.

### Quick Tier: Inline Pass

For `quick`, do not spawn subagents and do not verify. One pass: read the in-scope packet diffs. Skip test/fixture hunks (`test/`, `spec/`, `__tests__/`, `*_test.*`, `*.test.*`, `fixtures/`, `testdata/`) — test-file changes are not reviewed at this level. Flag runtime-correctness bugs visible from the hunk alone: inverted/wrong condition, off-by-one, null/undefined deref where adjacent lines show the value can be absent, removed guard, falsy-zero check, missing `await`, wrong-variable copy-paste, error swallowed in a catch that should propagate. Also flag — still from the hunk alone — new code that duplicates an existing helper visible in the diff context, and dead code the diff leaves behind. Do **not** flag style, naming, perf, missing tests, or anything outside the diff.

Output at most **4 findings**, most-severe first, one line each: `path/to/file.ext:123 — what's wrong and the concrete failure`. If nothing qualifies, report `Code review: no issues found (quick pass).` Then stop; the remaining steps are for `standard` and above. (Test-file hunks are only skipped here — at `standard` and above they are in scope, and Angle B explicitly looks for deleted tests that were covering real cases.)

### Step 3: Parallel Finders

Dispatch all finder angles for the chosen tier in parallel as read-only subagents. The user's invocation of review mode is permission to spawn these read-only subagents; do not ask again. Use the host's current parallel-task or subagent tools. If no such tools exist, run the same angles sequentially and disclose that in the final report.

Each finder gets: the shared read-only wrapper, the scope block, ONE angle from the roster below, and the shared output contract. Do not give finders the never-report list; filtering happens at verify and synthesis, not in the finder's head.

Shared finder wrapper:

```text
Your task is to perform a read-only code review subtask.

Do not edit files. Do not run builds, tests, typechecks, linters, formatters, compilers, package installs, migrations, or app commands. Inspect the review packet and any repository context needed to judge the change. Output only the requested JSON.
```

Shared finder prompt:

```text
## Code-review finder — {ANGLE_LABEL}

{SCOPE_BLOCK}

Read the in-scope packet diffs, then review ONLY through the lens of your
assigned angle:

{ANGLE_TEXT}

Surface up to {CAP} candidate findings. Return ONLY a JSON array:
[{"file":"repo/relative/path","line":123,"summary":"one-sentence statement of the defect","failure_scenario":"concrete inputs/state -> wrong output/crash"}]

failure_scenario must state the user-visible consequence (error, wrong output,
data loss), not an intermediate state (value stale, set grows).

Pass every candidate with a nameable failure scenario through — do not
silently drop half-believed candidates; an independent verifier judges them
next. If nothing qualifies, return [].
```

`{CAP}` is 6 for `standard`/`high` and 8 for `deep`. Prepend the tier's bias framing from the Intensity section to every finder prompt.

Cleanup, altitude, and conventions finders additionally get this precedence note:

```text
Cleanup, altitude, and conventions candidates use the same file/line/summary
shape; in failure_scenario, state the concrete cost (what is duplicated,
wasted, harder to maintain, or which guidance rule is broken) instead of a
crash. Correctness bugs always outrank cleanup, altitude, and conventions
findings when the output cap forces a cut.
```

#### Finder Roster

Correctness angles (A-C at `standard`/`high`; A-E at `deep`):

```text
### Angle A — line-by-line diff scan
Read every hunk in the diff, line by line. Then read the enclosing function for
each hunk — bugs in unchanged lines of a touched function are in scope (the
change re-exposes or fails to fix them). For every line ask: what input, state,
timing, or platform makes this line wrong? Look for inverted/wrong conditions,
off-by-one, null/undefined deref, missing `await`, falsy-zero checks,
wrong-variable copy-paste, error swallowed in catch, unescaped regex metachars.
```

```text
### Angle B — removed-behavior auditor
For every line the diff DELETES or replaces, name the invariant or behavior it
enforced, then search the new code for where that invariant is re-established.
If you can't find it, that's a candidate: a removed guard, a dropped error
path, a narrowed validation, a deleted test that was covering a real case.
```

```text
### Angle C — cross-file tracer
For each function the diff changes, find its callers (grep for the symbol) and
check whether the change breaks any call site: a new precondition, a changed
return shape, a new exception, a timing/ordering dependency. Also check callees:
does a parallel change in the same diff make a call unsafe?
```

```text
### Angle D — language-pitfall specialist
Scan for the classic pitfalls of the diff's language/framework — for example:
JS falsy-zero, `==` coercion, closure-captured loop var; Python mutable default
args, late-binding closures; Go nil-map write, range-var capture; SQL injection;
timezone/DST drift; float equality. Flag any instance the diff introduces.
```

```text
### Angle E — wrapper/proxy correctness
When the diff adds or modifies a type that wraps another (cache, proxy,
decorator, adapter): check that every method routes to the wrapped instance and
not back through a registry/session/global — e.g. a caching provider holding a
`delegate` field that resolves IDs via `session.get(...)` instead of
`delegate.get(...)` will re-enter the cache or recurse. Also check that the
wrapper forwards all the methods the callers actually use.
```

Cleanup lenses (all tiers `standard`+, one finder each):

```text
### Reuse
Flag new code that re-implements something the codebase already has — grep
shared/utility modules and files adjacent to the change, and name the existing
helper to call instead.
```

```text
### Simplification
Flag unnecessary complexity the diff adds: redundant or derivable state,
copy-paste with slight variation, deep nesting, dead code left behind. Name
the simpler form that does the same job.
```

```text
### Efficiency
Flag wasted work the diff introduces: redundant computation or repeated I/O,
independent operations run sequentially, blocking work added to startup or
hot paths. Also flag long-lived objects built from closures or captured
environments — they keep the entire enclosing scope alive for the object's
lifetime (a memory leak when that scope holds large values); prefer a
class/struct that copies only the fields it needs. Name the cheaper
alternative.
```

Altitude angle (all tiers `standard`+):

```text
### Altitude
Check that each change is implemented at the right depth, not as a fragile
bandaid. Special cases layered on shared infrastructure are a sign the fix
isn't deep enough — prefer generalizing the underlying mechanism over adding
special cases.
```

Conventions angle (all tiers `standard`+):

```text
### Conventions (project guidance)
Read each applicable guidance file listed in the scope block (AGENTS.md,
CLAUDE.md, CLAUDE.local.md, .cursor/rules/*, .github/copilot-instructions.md —
a directory-level file only applies to files at or below it), then check the
diff for clear violations of the rules they state. Only flag a violation when
you can quote the exact rule and the exact line that breaks it — no style
preferences, no vague "spirit of the doc" inferences. In the finding, name the
guidance file path and quote the rule so the report can cite it. If no
guidance file applies, return nothing for this angle.
```

Roster by tier:

| Tier | Angles | Finders |
|------|--------|---------|
| `standard`, `high` | A, B, C + Reuse, Simplification, Efficiency + Altitude + Conventions | 8 |
| `deep` | A, B, C, D, E + Reuse, Simplification, Efficiency + Altitude + Conventions | 10 |

Do NOT let one angle's conclusions suppress another's — if two angles flag the same line for different reasons, keep both candidates; the verifier judges each independently.

If a finder returns invalid JSON, ask once for JSON repair without changing the substance. If it still fails, manually normalize any clearly stated candidate into the required JSON shape rather than dropping it.

### Step 4: Parallel Verifiers

Normalize candidate file paths against `changed.files` (finders may return absolute or repo-relative paths for the same file). Group candidates by location (`file:line`); dispatch **one read-only verifier subagent per location group** in parallel, judging every candidate at that location. Near-duplicates (same defect, same location, same reason) collapse to one candidate first, keeping the most concrete failure scenario. The selected review tier already authorizes these read-only verifier subagents; do not ask again.

Verifier prompt:

```text
## Code-review verifier

{SCOPE_BLOCK}

## Candidate findings at {file:line}
[0] Summary: {summary}
    Failure scenario: {failure_scenario}
[1] ...

Read the relevant diff hunks and file(s), and return one verdict per
candidate. Judge EACH candidate independently on its own claim — candidates at
the same location may describe distinct issues, the same issue, or a mix.
Reference each by its [i] index.

{VERDICT_LADDER from verifier-rubric.md — include the recall rules section at
high and deep}

Return ONLY JSON:
{"verdicts":[{"index":0,"verdict":"CONFIRMED|PLAUSIBLE|REFUTED","evidence":"quote or cite the relevant line(s)"}]}
```

Give every verifier the verdict ladder from [verifier-rubric.md](verifier-rubric.md). At `high` and `deep`, also include the rubric's recall rules ("PLAUSIBLE by default") verbatim.

Keep candidates whose verdict is **CONFIRMED or PLAUSIBLE**. Drop REFUTED. There is no numeric threshold: a verifier that cannot construct a refutation from the code keeps the candidate.

### Step 5: Gap Sweep (deep only)

Run **one more finder** as a fresh reviewer who has the verified list. It gets the wrapper, the scope block, the list of surviving findings, and this instruction:

```text
Re-read the diff and the enclosing functions looking ONLY for defects not
already listed. Do not re-derive or re-confirm anything already there — the
job is gaps. Focus on what a first pass tends to miss: moved/extracted code
that dropped a guard or anchor; second-tier footguns (dataclass default
evaluated once, `hash()` non-determinism, lock-scope shrink, predicate methods
with side effects); setup/teardown asymmetry in tests; config defaults
flipped.

Surface up to 8 additional candidates, each naming a defect not already on the
list. If nothing new, return [] — do not pad.
```

Sweep candidates go through Step 4 verification like any other candidate.

### Step 6: Synthesize and Report

Merge findings that describe the same root cause into one entry. Rank most-severe first (user-visible breakage, data loss/corruption, and security exposure outrank everything; correctness outranks cleanup/altitude/conventions). Apply the tier's report cap; if more survive, keep the most severe and say how many were cut.

Drop at synthesis time (not earlier):
- pre-existing issues in code the diff never touches
- intentional behavior directly tied to the change's purpose
- pure style preferences not backed by quoted project guidance
- missing tests/docs unless explicit project guidance requires them
- findings whose only claim is that CI/lint/typecheck would fail, with no independently reviewable behavioral impact
- guideline violations explicitly silenced in code

Cleanup, altitude, and conventions candidates are NOT in that drop list. They go through verification and into the report like correctness candidates — ranked below correctness, cut first at the cap. Do not drop a cleanup candidate for "lacking behavioral impact" or being "cleanup-only": its failure scenario is a concrete cost (duplication, wasted work, quoted rule broken), not a crash, and that is exactly what the verifier judges.

Lead with findings. Do not bury them under a summary. Use bullets for end-state accounting; do not switch to a table.

```markdown
### Code review

Found N issue(s) (M confirmed, K plausible):

1. `src/foo.ts:42` — CONFIRMED — one-sentence summary.
   Failure scenario: concrete inputs/state -> wrong output/crash.
   Evidence: the verifier's quoted line(s).
   Suggested direction: the minimal fix shape, not a full patch unless the user asked for address mode.
2. `src/bar.ts:7` — PLAUSIBLE — ...

Notes:
- Static review only; builds, tests, linters, and typechecks were not run.
- Sequential fallback was used because subagents were unavailable. [only include if true]
- Verifier agents inherited the parent model because this host did not expose subagent model overrides. [only include if true]
```

If nothing survives verification:

```markdown
### Code review

No issues survived verification.

Static review only; builds, tests, linters, and typechecks were not run.
```

For local reviews, report in chat only. For PR targets, comment on GitHub only if the user explicitly asked for a PR comment, used `--comment`, or the surrounding workflow requires it.

When `--fix`, `--commit`, `--push`, `--pr`, or `--comment` is present, continue to the relevant action workflow after reporting the review findings. Do not end after review unless there are no safe next actions under the requested flags.

## Address Review Workflow

Use this workflow when the user asks to address, fix, resolve, or implement review feedback.

```text
collect findings -> re-check applicability -> plan edits -> patch narrowly -> verify -> optional commit/push/PR/comment -> summarize
```

### Step A: Collect Findings

Use the most specific available source:

1. Verified findings from the current review.
2. Findings pasted by the user.
3. PR review comments fetched with `gh`, if the user identified a PR and `gh` is authenticated.
4. Existing local TODO list only when the user explicitly says it represents review findings.

For PR comments, prefer structured GitHub data over text scraping. Capture comment path, line, side, body, author, state, and URL when available.

Ignore or separate:

- praise, questions, and non-actionable comments
- stale comments whose referenced code no longer exists
- suggestions outside the user-requested scope
- style preferences not backed by project guidance
- changes that would require product decisions

### Step B: Re-Check Applicability

Before editing, re-open the current file and confirm each finding still applies. Mark each item as:

| Status | Meaning |
|--------|---------|
| `apply` | still valid and safe to fix now |
| `stale` | no longer applies to current code |
| `needs-decision` | requires product/API/design choice |
| `out-of-scope` | unrelated to requested review scope |
| `unsafe` | fix would risk unrelated user work or broad rewrite |

Only `apply` items become edit tasks.

### Step C: Patch Narrowly

Make the smallest coherent change for each applicable finding.

- Preserve user style and existing patterns.
- Avoid drive-by refactors.
- Avoid formatting unrelated lines.
- Do not add dependencies unless the finding cannot be fixed safely without them.
- Do not rewrite tests or snapshots unless the review finding specifically requires that.
- Keep unrelated user changes intact.

If multiple fixes touch the same code, combine them only when it reduces risk or avoids conflicting edits.

### Step D: Verify

Address mode may run targeted verification commands when they are safe, existing, and relevant. Prefer the narrowest command that checks the touched area. Do not run expensive, destructive, or environment-mutating commands unless the user explicitly asked.

Examples of acceptable targeted verification when available:

- existing unit test for the touched file
- existing typecheck for a small package
- existing formatter check, not formatter write, for touched files
- static command documented in project guidance

If no safe targeted verification is available, inspect the patched diff manually and say that no automated check was run.

### Step E: Optional Git And PR Actions

Only run these steps when requested by flags or equally explicit natural language.

1. Re-run `git status --short` and identify files changed before this workflow versus files changed by address mode.
2. Use verification from Step D as the gate. If verification failed or was blocked, stop before GitHub or git write actions unless the user explicitly accepts that failure.
3. For `--commit` — given directly or implied by `--push`/`--pr` — stage only in-scope files and create a concise human-authored commit message. Do not include AI attribution trailers or bylines.
4. For `--push` — given directly or implied by `--pr` — commit any uncommitted in-scope changes first (step 3), then run a normal push for the current branch. If there is no upstream, use `git push -u origin HEAD` unless project guidance says otherwise.
5. For `--pr`, create a draft PR after push unless the user explicitly asked for a ready PR. Search for and use the repository's PR template if present.
6. For `--comment`, post the final review or address report to the PR only after local reporting is complete.

### Step F: Final Report

Use this shape:

```markdown
Review: 8 finder angles -> 8 verified candidates -> 6 CONFIRMED, 1 PLAUSIBLE, 1 REFUTED (dropped).

Fixed (2 findings):
- `src/foo.ts`: fixed the null path from finding 1.
- `src/bar.ts`: aligned request validation with project guidance.

Reported, not code-fixed (2 findings):
- Finding 3: stale; referenced code no longer exists.
- Finding 4: needs product decision about retry behavior.

Verification:
- Ran `npm test -- foo.test.ts` successfully.
- Did not run full test suite.

Git:
- Commit: `abc1234` Fix reviewed null handling. [only include if committed]
- Push: `origin/my-branch`. [only include if pushed]
- PR: https://github.com/org/repo/pull/123 [only include if created]
```

Always include the headings that apply, in this order: `Review`, `Fixed`, `Reported, not code-fixed`, `Verification`, `Git`. Omit a heading only when it has no content. Keep this shape even when the run found nothing to fix:

```markdown
Review: no issues survived verification.

Verification:
- Static review only; builds, tests, linters, and typechecks were not run.
```

Do not claim a comment is resolved unless the code change was made and verified. Do not mark GitHub review threads resolved unless the user explicitly asks.

## References

- Verifier rubric: [verifier-rubric.md](verifier-rubric.md)
- Platform adapters: [platform-adapters.md](platform-adapters.md)
- Upstream inspiration: the built-in Claude Code `/code-review` skill (effort cells: low = 1 inline pass; medium/high = 8 angles + 1-vote verify; xhigh/max = 10 angles + verify + sweep)
