---
name: code-review
description: >-
  Use when the user runs /code-review or asks for a thorough review of a pull
  request, branch diff, staged changes, unstaged changes, dirty working tree,
  or local changes before merge.
---

# Code Review

Codex-first, review-only code review. Use independent finder subagents to surface candidate issues, then verify each candidate with an independent scorer before reporting anything.

This skill does not fix code, commit changes, push branches, or open pull requests. If the user asks for fixes in the same request, finish the review first and hand off the accepted findings to a separate remediation workflow.

For non-Codex environments, see [platform-adapters.md](platform-adapters.md).

## Invocation

```text
/code-review [quick|standard|high] [target]
```

Natural-language review requests also apply.

Intensity defaults to `standard`:

| Intensity | Finders | Threshold | Use when |
|-----------|---------|-----------|----------|
| `quick` | 2 | 70 | Small or low-risk diffs |
| `standard` | 3 | 75 | Normal local or PR review |
| `high` | 5 | 80 | Pre-merge review where Claude-style thoroughness is worth the cost |

Targets:

| User asks for | Review |
|---------------|--------|
| no target | branch changes plus staged, unstaged, and untracked worktree files |
| `branch`, `committed`, or `HEAD` | committed branch diff only |
| `working tree`, `dirty`, or `local changes` | staged, unstaged, and untracked files only |
| `staged` | staged changes only |
| `unstaged` | unstaged changes only |
| PR number, PR URL, or `pr` | pull request diff and metadata via `gh` |

If the resolved target has no changes, stop with `No diff to review.`

## Workflow

```text
prep -> review packet -> parallel finders -> dedupe -> parallel verifiers -> filter -> report
```

Create a task list at the start (`update_plan`, `TodoWrite`, or equivalent).

## Step 1: Prep

Run prep inline unless a cheap read-only subagent is clearly useful.

1. Confirm the repository root with `git rev-parse --show-toplevel`.
2. Check `git status --short` before doing anything that could affect user work.
3. Resolve the target and base branch.
4. Skip trivial generated-only, lockfile-only, formatting-only, closed, draft, or already-reviewed PRs when that status can be determined cheaply.
5. Discover guideline paths by name only:
   - `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `CONTRIBUTING.md`
   - `.cursor/rules/*`, `.github/copilot-instructions.md`
   - Matching files in directories touched by the review target
6. Summarize the change in 3-5 sentences.

Default base resolution:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)
BASE_SHA=$(git merge-base HEAD "origin/${BASE_BRANCH}" 2>/dev/null || git merge-base HEAD "${BASE_BRANCH}")
HEAD_SHA=$(git rev-parse HEAD)
```

If `BASE_SHA` cannot be resolved, ask the user for a base branch or review only the explicit working-tree target. Do not guess a base for committed branch review.

For PR targets, use `gh pr view` and `gh pr diff` when `gh` is authenticated. Do not check out a different branch or stash user changes unless the user explicitly confirms.

## Step 2: Build a Review Packet

Create a temporary review packet so every finder reviews the same inputs, including dirty worktree state:

```bash
REVIEW_DIR=$(mktemp -d "${TMPDIR:-/tmp}/code-review.XXXXXX")
git diff --stat "$BASE_SHA"..HEAD > "$REVIEW_DIR/committed.stat"
git diff "$BASE_SHA"..HEAD > "$REVIEW_DIR/committed.diff"
git diff --cached --stat > "$REVIEW_DIR/staged.stat"
git diff --cached > "$REVIEW_DIR/staged.diff"
git diff --stat > "$REVIEW_DIR/unstaged.stat"
git diff > "$REVIEW_DIR/unstaged.diff"
git ls-files --others --exclude-standard > "$REVIEW_DIR/untracked.files"
```

For PR targets, create explicit PR packet files instead of relying on local branch state:

```bash
gh pr view "$PR" --json number,title,state,isDraft,headRefName,baseRefName,url > "$REVIEW_DIR/pr.json"
gh pr diff "$PR" > "$REVIEW_DIR/pr.diff"
```

Adjust the packet for explicit targets:

| Target | Include |
|--------|---------|
| default | committed, staged, unstaged, and untracked files |
| branch | committed only |
| working tree | staged, unstaged, and untracked files |
| staged | staged only |
| unstaged | unstaged only |
| PR | `gh pr diff`, PR metadata, and any local dirty changes only if the user asked to include them |

For untracked files in scope, include `untracked.files` in every finder prompt and instruct finders to read those files directly before reporting issues in them.

Record:

```text
REPO_ROOT
REVIEW_DIR
TARGET
BASE_SHA
HEAD_SHA
GUIDELINE_PATHS
CHANGE_SUMMARY
THRESHOLD
```

## Step 3: Parallel Finders

Dispatch all finders for the chosen intensity in parallel as read-only subagents. In Codex, use the available multi-agent tools from the current environment; usually this means `spawn_agent`, then `wait_agent`, then `close_agent`.

Model guidance:

| Role | Guidance |
|------|----------|
| Finder | Prefer inheriting the parent/default model. For `high`, use a stronger model only when the current tool schema exposes one and cost is acceptable. |
| Verifier | Use a fast/small model when available, because each verifier checks one bounded candidate. |
| Prep | Run inline or use a fast/small model. |

Shared finder prompt:

```text
You are one finder in a multi-agent code review.

Repository: {REPO_ROOT}
Target: {TARGET}
Base: {BASE_SHA}
Head: {HEAD_SHA}
Review packet: {REVIEW_DIR}
Guideline paths: {GUIDELINE_PATHS}
Change summary: {CHANGE_SUMMARY}

Inspect only the review target. Use the packet files first:
- committed.diff / committed.stat
- staged.diff / staged.stat
- unstaged.diff / unstaged.stat
- untracked.files, reading listed files directly if they are in scope

Read guideline files only when relevant to your assigned role.

Return ONLY a JSON array. Each issue must be:
{"id":"F{finder_number}-{issue_number}","file":"path","line_start":N,"line_end":N,"title":"short","detail":"specific explanation","category":"guideline|bug|history|prior-pr|comment|security|other","evidence":"why this is introduced by this change"}

No issues: []

Exclude pre-existing problems, CI-catchable build/lint/type/format issues, broad quality concerns, and senior-engineer nits.
```

Finder roster:

`quick`:

1. Guideline auditor: check explicit project guidance on changed lines only.
2. Bug scanner: shallow diff-only pass for serious behavior, data, security, or reliability bugs.

`standard` adds:

3. History analyst: inspect `git blame` and `git log -p -- <file>` for touched hunks to catch context regressions.

`high` adds:

4. Prior PR analyst: inspect prior PRs or merge history for changed files, especially previous review comments that still apply.
5. Comment auditor: inspect `TODO`, `FIXME`, `NOTE`, warnings, and nearby comments in modified files for violated local intent.

If a finder returns invalid JSON, ask once for JSON repair without changing the substance. If it still fails, drop that finder output and note the gap internally.

Deduplicate candidates before verification by `file`, overlapping line range, and substantially similar claim.

## Step 4: Parallel Verifiers

For each deduplicated candidate, dispatch one read-only verifier subagent in parallel.

Give each verifier:

- the candidate issue JSON
- the relevant diff hunk or untracked file excerpt
- `GUIDELINE_PATHS`
- [verifier-rubric.md](verifier-rubric.md) verbatim

Verifier output must be JSON only:

```json
{"issue_id":"F1-1","score":85,"reason":"one sentence"}
```

Drop candidates with `score < THRESHOLD`.

Zero survivors means report:

```text
Code review: no high-confidence issues found.
```

## Step 5: Report

Lead with findings, ordered by severity and confidence. Do not bury blockers under a summary.

Use this shape:

```markdown
### Code review

Found N high-confidence issue(s):

| Score | Location | Category | Finding |
|-------|----------|----------|---------|
| 85 | `src/foo.ts:42` | bug | Short finding with concrete impact. |

Verdict: Fix N issue(s) before merge.
```

If there are no findings:

```markdown
### Code review

No high-confidence issues found.
```

For local reviews, report in chat only. For PR targets, comment on GitHub only if the user explicitly asked for a PR comment or the surrounding workflow requires it. Use full SHA links in PR comments.

## Remediation Handoff

If the user asked for fixes, commits, or a PR in the same request, do not silently continue into edits. End the review with a compact handoff:

```markdown
Remediation handoff:
- Finding 1: ...
- Finding 2: ...
- Suggested next workflow: address verified review findings, then run project checks.
```

The next agent or next turn can use normal implementation, TDD, and verification workflows. This separation keeps review evidence read-only and prevents the reviewer from grading its own fixes.

## Never Report

- Pre-existing issues not introduced by the review target
- Issues only on unchanged lines
- Linter, typechecker, formatter, compiler, import, or ordinary test failures
- Pedantic style unless explicit project guidance requires it
- General code quality, missing docs, or missing tests unless explicit project guidance requires it
- Intentional behavior directly tied to the change
- Guideline violations explicitly silenced in code
- Speculation that cannot be tied to a changed behavior or explicit guideline

Do not run builds, typechecks, formatters, or test suites for review signal. Those belong to CI or remediation verification.

## References

- Verifier rubric: [verifier-rubric.md](verifier-rubric.md)
- Platform adapters: [platform-adapters.md](platform-adapters.md)
- Upstream inspiration: Anthropic `claude-plugins-official` `/code-review`
