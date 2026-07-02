# Platform Adapters

This package is Codex-first but deliberately avoids hard dependencies on a specific host tool schema. Keep `SKILL.md` as the portable source of truth and adapt only the dispatch/install details here.

## Install

Personal install paths:

| Environment | Path |
|-------------|------|
| Codex | `~/.codex/skills/code-review/` |
| Cursor | `~/.cursor/skills/code-review/` |
| Claude Code | Prefer the built-in `/code-review` skill; otherwise expose this workflow through `.claude/commands/code-review.md` and, optionally, `.claude/commands/address-review.md` |

Preferred source-repo install:

```bash
scripts/sync-skills --target codex --dry-run
scripts/sync-skills --target codex --apply
```

For Cursor, enable `install.cursor.enabled` in `skills.yaml`, then run `scripts/sync-skills --target cursor --apply`.

If installing into multiple environments, keep environment-specific command/frontmatter files outside the portable source or generate them during install.

## Codex Adapter

Use the parallel task or subagent tools exposed by the current Codex environment. The exact names can vary, so inspect the available tool schema instead of hard-coding names.

Invoking `$code-review` in review mode authorizes the read-only finder and verifier subagents required by the selected tier. Do not ask the user for additional permission before spawning those subagents. Ask only before actions outside the user-requested scope, such as unrequested edits, broad refactors, GitHub write actions, resolving review threads, or explicit model/cost escalation beyond the chosen tier.

Typical mapping:

| Need | Adapter behavior |
|------|------------------|
| Dispatch one finder/verifier | Spawn one read-only subtask with the prompt from `SKILL.md` |
| Wait for results | Collect all outputs before dedupe or filtering |
| Clean up | Close completed agents/tasks if the host exposes an explicit close operation |

Use different model policies for finder and verifier subtasks:

| Role | Codex model policy |
|------|--------------------|
| Finder | Inherit the parent/default model. For `deep`, use an explicit stronger finder model when the current schema exposes one. |
| Verifier | Use the parent/default model at `high` and `deep` — verifier quality directly controls what survives. At `standard`, an explicit lower-cost fast model is acceptable for candidates whose evidence is bounded to one or two files; use the parent model when the proof depends on cross-file contracts, security, data loss, or migrations. |

If the host cannot set per-subagent models, continue with inherited models and disclose that in the final report.

Codex subagent wrapper:

```text
Your task is to perform the following read-only code review subtask.

<agent-instructions>
...finder or verifier prompt...
</agent-instructions>

Do not edit files. Do not run builds, tests, typechecks, linters, formatters, compilers, package installs, migrations, or app commands.
Execute now. Output ONLY the structured format requested above.
```

Close or release subagents after collecting their final output when the host supports it.

## Cursor Adapter

Cursor support should preserve the same stages:

1. Build the review packet in the parent agent.
2. Launch finder angle tasks in parallel with read-only instructions.
3. Group candidates by location in the parent agent.
4. Launch one verifier task per location group with the verdict ladder.
5. Report only findings whose verdict is CONFIRMED or PLAUSIBLE.
6. For address mode, patch only verified/applicable findings and run narrow verification when safe.

Use Cursor's task/subagent mechanism when available. If Cursor exposes model selection, follow the same policy as the Codex adapter: parent/default models throughout, a fast model only for bounded `standard`-tier verifiers. Avoid hard-coding model slugs unless Cursor's current UI or tool schema lists them.

If Cursor supports slash-command frontmatter and you want `/code-review` or `/address-review` to run only on explicit invocation, add Cursor-specific frontmatter in the installed Cursor copy rather than the portable source.

## Claude Code Adapter

Claude Code has a built-in `/code-review` skill with effort levels (`low` through `max`); this skill's tiers mirror its structure (`quick` ≈ low, `standard`/`high` ≈ medium/high, `deep` ≈ xhigh/max). Prefer the built-in skill in Claude Code when exact Claude behavior is desired.

To route Claude Code to this portable workflow, create commands like:

```markdown
---
description: Code review using the portable code-review skill
---

Follow the code-review skill at <installed path>/SKILL.md in review mode.
```

```markdown
---
description: Address verified review findings using the portable code-review skill
---

Follow the code-review skill at <installed path>/SKILL.md in address mode.
```

Do not claim exact parity with the built-in skill unless this workflow has been compared against the built-in prompt text for the current Claude Code version.

## GitHub CLI

PR targets, PR review comments, prior PR context, and optional PR comments need `gh` authenticated:

```bash
gh auth status
```

Use `gh pr view`, `gh pr diff`, `gh pr comment`, and `gh api` as appropriate. Do not check out branches, stash changes, or mark threads resolved unless the user explicitly asks.

## Sequential Fallback

If an environment cannot launch subagents, run the same roles sequentially and say so in the final report:

```text
Note: subagents were unavailable, so finder and verifier roles were run sequentially.
```

Sequential fallback is acceptable for portability, but it is not equivalent to independent parallel review.
