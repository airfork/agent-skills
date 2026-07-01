---
name: code-review
description: >-
  Use when the user runs /code-review, asks for a thorough review of a pull
  request, branch diff, staged changes, unstaged changes, dirty working tree,
  or local changes before merge; also use when the user asks to address or fix
  verified code-review findings.
---

# Code Review

Codex-first workflow for two related jobs:

1. **Review mode**: inspect a diff with independent finder agents, verify each candidate finding, and report only high-confidence issues.
2. **Address mode**: take verified review findings or PR review comments, re-check that they still apply, make the smallest safe fixes, and verify the result.

Review mode is read-only. Address mode may edit files, but only to resolve verified findings. Never commit, push, merge, rebase, stash, clean, or mark PR comments resolved unless the user explicitly asks.

For non-Codex environments, see [platform-adapters.md](platform-adapters.md).

## Invocation

Codex installs this as one skill named `$code-review`; address mode is not a separate Codex command or skill.

Use these prompt shapes:

```text
Use $code-review to run /code-review <quick|standard|high|deep> [target].
Use $code-review to address the verified findings from the last code review.
Use $code-review to address actionable review comments on PR #123.
Use $code-review to run /code-review standard working tree, then address all applicable verified findings and run targeted verification.
```

Natural-language requests also apply:

- "review my current branch"
- "review this PR"
- "check staged changes before merge"
- "address the review findings"
- "fix the PR comments"

When the user asks for review and fixes in the same turn, run the review first. Continue into address mode only for findings that pass verification; do not fix speculative or low-confidence candidates.

## Tier Parsing And Help

`/code-review` requires an explicit tier as the first meaningful argument. Recognize only `quick`, `standard`, `high`, `deep`, and obvious aliases:

| Alias | Tier |
|-------|------|
| `q`, `fast` | `quick` |
| `std`, `normal`, `default` | `standard` |
| `thorough` | `high` |
| `xhigh`, `max`, `full` | `deep` |

If the user runs `/code-review` with no tier, or if the first argument is a target or other text that is not a recognizable tier, print this help text and stop:

```text
Usage:
  /code-review <quick|standard|high|deep> [target]

Tiers:
  quick     Low-cost pass for small, low-risk diffs.
  standard  Normal local branch, staged, unstaged, or PR review.
  high      Pre-merge review with extra context coverage.
  deep      Highest-cost review for large, risky, security-sensitive, architecture-shaping, or release-blocking changes.

Targets:
  branch | committed | HEAD     Review committed branch diff only.
  working tree | dirty | local   Review staged, unstaged, and untracked files.
  staged                       Review staged changes only.
  unstaged                     Review unstaged changes only.
  pr #123 | <PR URL>            Review pull request diff and metadata via gh.

Examples:
  /code-review quick staged
  /code-review standard working tree
  /code-review high pr #123
  /code-review deep branch
```

Do not silently default to `standard` for explicit `/code-review` invocations. For natural-language review requests without a tier, ask the user to choose a tier unless the surrounding instructions clearly provide one.

## Intensity

The tier controls review cost, finder roster, and verifier threshold.

| Tier | Finders | Verifier threshold | Use when |
|------|---------|--------------------|----------|
| `quick` | 2 | 70 | Small, low-risk diffs or a fast pre-check |
| `standard` | 3 | 75 | Normal local branch, staged, unstaged, or PR review |
| `high` | 5 | 80 | Pre-merge review where extra coverage is worth the cost |
| `deep` | 6 | 85 | Large, risky, security-sensitive, architecture-shaping, or release-blocking changes |

Prefer false negatives over false positives. The goal is to catch important review issues, not to produce a long list.

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
- Address mode is narrow: edit only what is needed for verified findings or explicitly actionable review comments.
- Do not report pre-existing issues, unchanged-line issues, ordinary CI failures, style preferences, broad quality concerns, or missing tests/docs unless explicit project guidance requires them.
- Do not browse or scrape PRs in a browser when `gh` can provide the data.
- Do not rely on stale assumptions about tool names, model names, or host capabilities. Use the tools actually exposed by the current environment.

## Review Workflow

```text
prep -> review packet -> parallel finders -> dedupe -> parallel verifiers -> filter -> report
```

Maintain a visible task list when the host environment supports one (`update_plan`, `TodoWrite`, or equivalent). Otherwise keep the same stages internally and summarize them in the final report.

### Step 1: Prep

Run prep inline unless a cheap read-only subagent is clearly useful.

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
5. Discover project guidance by path name and proximity, not by reading the whole repository:
   - `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `CONTRIBUTING.md`
   - `.cursor/rules/*`, `.github/copilot-instructions.md`
   - matching guidance files in directories touched by the review target
6. Summarize the change in 3-5 sentences: intent, touched areas, risk areas, and any notable generated/binary/dependency files.

For generated-only, formatting-only, or lockfile-only diffs, do not skip automatically. Downgrade effort when appropriate, but still check for real dependency, security, packaging, or generated-artifact inconsistencies.

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

# Staged changes, when in scope
git diff --cached --stat > "$REVIEW_DIR/staged.stat"
git diff --cached --name-status > "$REVIEW_DIR/staged.name-status"
git diff --cached > "$REVIEW_DIR/staged.diff"

# Unstaged changes, when in scope
git diff --stat > "$REVIEW_DIR/unstaged.stat"
git diff --name-status > "$REVIEW_DIR/unstaged.name-status"
git diff > "$REVIEW_DIR/unstaged.diff"

# Untracked files, when in scope
git ls-files --others --exclude-standard > "$REVIEW_DIR/untracked.files"
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

For PR targets, create explicit PR packet files instead of relying on local branch state:

```bash
gh pr view "$PR" --json number,title,state,isDraft,headRefName,baseRefName,url,reviewDecision,mergeStateStatus > "$REVIEW_DIR/pr.json"
gh pr diff "$PR" > "$REVIEW_DIR/pr.diff"
```

Adjust packet content by target:

| Target | Include |
|--------|---------|
| default | committed, staged, unstaged, and untracked files |
| branch | committed only |
| working tree | staged, unstaged, and untracked files |
| staged | staged only |
| unstaged | unstaged only |
| PR | `pr.diff`, `pr.json`, and local dirty changes only if the user asked to include them |

Record this metadata for every finder and verifier:

```text
REPO_ROOT
REVIEW_DIR
TARGET
BASE_SHA
HEAD_SHA
GUIDELINE_PATHS
CHANGE_SUMMARY
THRESHOLD
IN_SCOPE_PACKET_FILES
```

### Step 3: Parallel Finders

Dispatch all finders for the chosen intensity in parallel as read-only subagents. Use the host's current parallel-task or subagent tools. If no such tools exist, run the same roles sequentially and disclose that in the final report.

Shared finder wrapper:

```text
Your task is to perform a read-only code review subtask.

Do not edit files. Do not run builds, tests, typechecks, linters, formatters, compilers, package installs, migrations, or app commands. Inspect only the review target. Output only the requested JSON.
```

Shared finder prompt:

```text
You are one finder in a multi-agent code review.

Repository: {REPO_ROOT}
Target: {TARGET}
Base: {BASE_SHA}
Head: {HEAD_SHA}
Review packet: {REVIEW_DIR}
In-scope packet files: {IN_SCOPE_PACKET_FILES}
Guideline paths: {GUIDELINE_PATHS}
Change summary: {CHANGE_SUMMARY}

Use packet files first. For untracked files, read the snapshot under {REVIEW_DIR}/untracked when present; otherwise read the listed file directly only if it is in scope.

Read guideline files only when relevant to your assigned role.

Return ONLY a JSON array. Each issue must use this shape:
{"id":"F{finder_number}-{issue_number}","file":"path","line_start":N,"line_end":N,"severity":"blocker|major|minor","title":"short","detail":"specific explanation","category":"guideline|bug|history|prior-pr|comment|security|other","evidence":"why this is introduced by this change"}

No issues: []

Exclude pre-existing problems, unchanged-line issues, CI-catchable build/lint/type/format issues, broad quality concerns, missing tests/docs unless explicitly required by project guidance, and senior-engineer nits.
```

Finder roster:

| Tier | Finder | Focus |
|------|--------|-------|
| quick+ | Guideline auditor | Explicit project guidance on changed lines only |
| quick+ | Bug scanner | Serious behavior, data, security, concurrency, lifecycle, or reliability bugs |
| standard+ | History analyst | `git blame` and `git log -p -- <file>` around touched hunks to catch context regressions |
| high+ | Prior PR analyst | Related prior PRs, merge history, or unresolved review context for changed files |
| high+ | Comment auditor | `TODO`, `FIXME`, `NOTE`, warnings, and nearby comments that define local intent |
| deep | Integration/context analyst | Cross-file contracts, public APIs, configuration, dependency, data-shape, migration, and security boundary assumptions touched by the change |

If a finder returns invalid JSON, ask once for JSON repair without changing the substance. If it still fails, drop that finder output and note the gap internally.

Deduplicate candidates before verification by `file`, overlapping line range, substantially similar claim, and shared root cause. Preserve the clearest title/detail/evidence across duplicates.

### Step 4: Parallel Verifiers

For each deduplicated candidate, dispatch one read-only verifier subagent in parallel.

Give each verifier:

- the candidate issue JSON
- the relevant diff hunk or untracked-file excerpt
- nearby unchanged context only as needed
- relevant project guideline excerpts, if the candidate depends on a guideline
- [verifier-rubric.md](verifier-rubric.md) verbatim

Verifier output must be JSON only:

```json
{"issue_id":"F1-1","score":85,"severity":"major","reason":"one sentence"}
```

Drop candidates with `score < THRESHOLD`. Also drop candidates that the verifier marks as pre-existing, unchanged-line only, speculative, or CI-only even if the numeric score is high.

Zero survivors means report:

```text
Code review: no high-confidence issues found.
```

### Step 5: Report

Lead with findings, ordered by severity, then confidence. Do not bury blockers under a summary.

Use this shape:

```markdown
### Code review

Found N high-confidence issue(s):

| Score | Severity | Location | Category | Finding |
|-------|----------|----------|----------|---------|
| 85 | major | `src/foo.ts:42` | bug | Short finding with concrete impact. |

Verdict: Fix N issue(s) before merge.

Notes:
- Static review only; builds, tests, linters, and typechecks were not run.
- Sequential fallback was used because subagents were unavailable. [only include if true]
```

For each finding, include enough detail after the table for the user to act:

```markdown
1. `src/foo.ts:42` — Title.
   Evidence: why the change introduced the issue.
   Impact: concrete user, data, security, reliability, or guideline impact.
   Suggested direction: the minimal fix shape, not a full patch unless the user asked for address mode.
```

If there are no findings:

```markdown
### Code review

No high-confidence issues found.

Static review only; builds, tests, linters, and typechecks were not run.
```

For local reviews, report in chat only. For PR targets, comment on GitHub only if the user explicitly asked for a PR comment or the surrounding workflow requires it.

## Address Review Workflow

Use this workflow when the user asks to address, fix, resolve, or implement review feedback.

```text
collect findings -> re-check applicability -> plan edits -> patch narrowly -> verify -> summarize
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

### Step E: Address Report

Use this shape:

```markdown
### Addressed review findings

Changed:
- `src/foo.ts`: fixed the null path from finding 1.
- `src/bar.ts`: aligned request validation with project guidance.

Not changed:
- Finding 3: stale; referenced code no longer exists.
- Finding 4: needs product decision about retry behavior.

Verification:
- Ran `npm test -- foo.test.ts` successfully.
- Did not run full test suite.
```

Do not claim a comment is resolved unless the code change was made and verified. Do not mark GitHub review threads resolved unless the user explicitly asks.

## Never Report as Review Findings

- Pre-existing issues not introduced by the review target
- Issues only on unchanged lines
- Linter, typechecker, formatter, compiler, import, or ordinary test failures
- Pedantic style unless explicit project guidance requires it
- General code quality, missing docs, or missing tests unless explicit project guidance requires it
- Intentional behavior directly tied to the change
- Guideline violations explicitly silenced in code
- Speculation that cannot be tied to changed behavior or explicit guidance

## References

- Verifier rubric: [verifier-rubric.md](verifier-rubric.md)
- Platform adapters: [platform-adapters.md](platform-adapters.md)
- Upstream inspiration: Anthropic `claude-plugins-official` `/code-review`
