# Platform Adapters

This package is Codex-first but deliberately avoids hard dependencies on a specific host tool schema. Keep `SKILL.md` as the portable source of truth and adapt only the dispatch/install details here.

## Install

Personal install paths:

| Environment | Path |
|-------------|------|
| Codex | `~/.codex/skills/code-review/` |
| Cursor | `~/.cursor/skills/code-review/` |
| Gemini/Antigravity | `~/.gemini/config/skills/code-review/` |
| Claude Code | Prefer the built-in `/code-review` skill; otherwise expose this workflow through `.claude/commands/code-review.md` and, optionally, `.claude/commands/address-review.md` |

Preferred source-repo install:

```bash
scripts/sync-skills --target codex --dry-run
scripts/sync-skills --target codex --apply
scripts/sync-skills --target gemini --dry-run
scripts/sync-skills --target gemini --apply
```

For Cursor, enable `install.cursor.enabled` in `skills.yaml`, then run `scripts/sync-skills --target cursor --apply`.

If installing into multiple environments, keep environment-specific command/frontmatter files outside the portable source or generate them during install.

Gemini/Antigravity treats `~/.gemini/config/` as a global customization root and
loads skills from its `skills/` directory. Do not create a Gemini-specific
`code-review` copy; install this same source folder with the `gemini` target.

## Codex Adapter

Use the parallel task or subagent tools exposed by the current Codex environment. The exact names can vary, so inspect the available tool schema instead of hard-coding names.

Invoking `$code-review` in review mode authorizes the read-only finder and verifier subagents required by the selected tier. Do not ask the user for additional permission before spawning those subagents. Ask only before actions outside the user-requested scope or requested flags, such as unrequested edits, broad refactors, unflagged GitHub write actions, resolving review threads, or explicit model/cost escalation beyond the chosen tier.

Typical mapping:

| Need | Adapter behavior |
|------|------------------|
| Dispatch one finder/verifier | Spawn one read-only subtask with the prompt from `SKILL.md` |
| Wait for results | Collect all outputs before dedupe or filtering |
| Clean up | Close completed agents/tasks if the host exposes an explicit close operation |

Install the named agent definitions from `agents/codex/` into `~/.codex/agents/` (one-time step; `scripts/sync-skills` does not copy them):

```bash
cp <skill source>/agents/codex/*.toml ~/.codex/agents/
```

They pin `sandbox_mode = "read-only"` and per-role reasoning effort, and inherit the session model:

| Role | Named agent | Reasoning effort |
|------|-------------|------------------|
| Finder (`standard`, `high`) | `review-finder` | `high` |
| Finder (`deep`) | `review-finder-deep` | `xhigh` |
| Verifier (`standard`, `high`) | `review-verifier` | `high` |
| Verifier (`deep`) | `review-verifier-deep` | `xhigh` |

Spawn finders and verifiers as these named agents. On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier; verifiers must use the same inherited model as finders and must not receive lower reasoning effort. On other hosts, retain their existing verifier-model quality floors. If the host cannot set or prove per-subagent reasoning effort, use the host's maximum available effort and disclose that the requested tier was not fully enforceable.

The named agents cover only the finder and verifier roles; the parent session still does prep, candidate grouping, dedup, and synthesis. Run review sessions at high parent reasoning effort too — e.g. `codex -c model_reasoning_effort=high`, or a dedicated profile in `config.toml`:

```toml
[profiles.review]
model_reasoning_effort = "high"
```

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

Use Cursor's task/subagent mechanism when available. If Cursor exposes model or reasoning-effort selection, follow the same policy as the Codex adapter: parent/default models with high effort at `standard`/`high` and maximum effort at `deep`, for finders and verifiers alike — never a downgraded model for verifiers. Avoid hard-coding model slugs unless Cursor's current UI or tool schema lists them.

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

## Gemini/Antigravity Adapter

Invoke through the skill activation mechanism or natural language that clearly
names `code-review`.

Preserve the same stages as the portable workflow:

1. Build the review packet in the parent agent.
2. Launch finder angle tasks in parallel when the host provides independent
   agent/task dispatch.
3. Group candidates by location in the parent agent.
4. Launch one verifier task per location group when available.
5. Report only findings whose verdict is CONFIRMED or PLAUSIBLE.
6. For address mode, patch only verified/applicable findings and run narrow
   verification when safe.

If Gemini cannot launch independent subagents or pin model effort by role, use
the sequential fallback and disclose it in the final report. Never downgrade
verifier quality just because the adapter is running in Gemini.

## GitHub CLI

PR targets, PR review comments, prior PR context, optional PR comments, and `--pr` PR creation need `gh` authenticated:

```bash
gh auth status
```

Use `gh pr view`, `gh pr diff`, `gh pr comment`, `gh pr create`, and `gh api` as appropriate. `--pr` implies committing in-scope changes and a normal push before PR creation (it never implies `--fix`). Do not check out branches, stash changes, force-push, or mark threads resolved unless the user explicitly asks.

## Sequential Fallback

If an environment cannot launch subagents, run the same roles sequentially and say so in the final report:

```text
Note: subagents were unavailable, so finder and verifier roles were run sequentially.
```

Sequential fallback is acceptable for portability, but it is not equivalent to independent parallel review.
