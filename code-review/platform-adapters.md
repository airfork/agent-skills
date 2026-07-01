# Platform Adapters

This draft is Codex-first. Keep `SKILL.md` concrete for Codex, and use this file to adapt dispatch and install details for Cursor, Claude Code, and other environments.

## Install

Personal install paths:

| Environment | Path |
|-------------|------|
| Codex | `~/.codex/skills/code-review/` |
| Cursor | `~/.cursor/skills/code-review/` |
| Claude Code | Prefer the official plugin; otherwise expose this workflow through `.claude/commands/code-review.md` |

Draft copy example:

```bash
SKILL_SRC=/path/to/docs/drafts/code-review-skill
mkdir -p ~/.codex/skills/code-review ~/.cursor/skills/code-review
rsync -a --exclude README.md "$SKILL_SRC"/ ~/.codex/skills/code-review/
rsync -a --exclude README.md "$SKILL_SRC"/ ~/.cursor/skills/code-review/
```

For Codex package polish, keep or generate `agents/openai.yaml` when installing globally.

## Codex Adapter

Use the multi-agent tools exposed by the current Codex environment. In this session, the relevant tool names are:

| Need | Tool |
|------|------|
| Dispatch one subagent | `multi_agent_v1.spawn_agent` |
| Wait for results | `multi_agent_v1.wait_agent` |
| Close completed agents | `multi_agent_v1.close_agent` |

Prefer omitting explicit model overrides for finder agents so they inherit the parent/default model. Use explicit model overrides only when the current tool schema exposes them and the task justifies the cost tradeoff.

Current useful Codex model mapping, if available:

| Role | Suggested override |
|------|--------------------|
| High-intensity finder | omit model, or use a stronger listed model such as `gpt-5.4` / `gpt-5.5` when explicitly justified |
| Standard/quick finder | omit model |
| Verifier | `gpt-5.4-mini` or `gpt-5.3-codex-spark` |
| Prep | `gpt-5.4-mini` or inline |

Codex subagent prompt wrapper:

```text
Your task is to perform the following read-only code review subtask.

<agent-instructions>
...finder or verifier prompt...
</agent-instructions>

Do not edit files. Do not run build, test, typecheck, or formatting commands.
Execute now. Output ONLY the structured format requested above.
```

Close agents after collecting their final output so the session does not retain unnecessary agent slots.

## Cursor Adapter

Cursor support should preserve the same workflow:

1. Build the review packet in the parent agent.
2. Launch finder tasks in parallel with read-only instructions.
3. Dedupe in the parent agent.
4. Launch one verifier task per deduped candidate.
5. Report only verified findings.

Use Cursor's task/subagent mechanism when available. If Cursor exposes model selection, use a strong/default model for finders and a fast model for verifiers. Avoid hard-coding model slugs unless Cursor's current UI or tool schema lists them.

If Cursor supports explicit slash-command frontmatter and you want `/code-review` to only run on explicit invocation, add the Cursor-specific field in the installed Cursor copy rather than the portable source:

```yaml
disable-model-invocation: true
```

Do not add Cursor-only fields to the Codex install copy.

## Claude Code Adapter

Claude Code already has an official `code-review` plugin. Prefer that plugin when exact Claude behavior is desired.

To route Claude Code to this portable draft, create a command that says:

```markdown
---
description: Code review using the portable code-review skill
---

Follow the code-review skill at <installed path>/SKILL.md.
```

Do not claim exact parity with the official plugin unless the command has been compared against the upstream file for the current version.

## GitHub CLI

PR targets, prior-PR analysis, and optional PR comments need `gh` authenticated:

```bash
gh auth status
```

Use `gh` for GitHub PR data instead of browser scraping.

## Sequential Fallback

If an environment cannot launch subagents, run the same roles sequentially and say so in the final report:

```text
Note: subagents were unavailable, so finder and verifier roles were run sequentially.
```

Sequential fallback is acceptable for portability, but it is not equivalent to the intended independent parallel review.
