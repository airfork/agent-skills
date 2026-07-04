# Platform Adapters

Keep [SKILL.md](SKILL.md) as the portable source of truth. This file only adapts dispatch, install, and host-specific capability details.

## Install

Personal install paths:

| Environment | Skill path |
|-------------|------------|
| Codex | `~/.codex/skills/adversarial-review/` |
| Codex alternate scanned root | `~/.agents/skills/adversarial-review/` |
| Claude Code | `~/.claude/skills/adversarial-review/` |

Preferred repo-managed installs:

```bash
scripts/sync-skills --target codex --dry-run
scripts/sync-skills --target codex --apply
scripts/sync-skills --target claude --dry-run
scripts/sync-skills --target claude --apply
```

During implementation on 2026-07-03, `codex-cli 0.142.5` prompt-input output showed Codex scanning both `~/.agents/skills` and the repo-managed `~/.codex/skills` symlink for `code-review`. This repo's `scripts/sync-skills` still targets `~/.codex/skills` for Codex installs.

The Codex named-agent TOMLs are not installed by `scripts/sync-skills`. Copy them only when the user explicitly asks:

```bash
mkdir -p ~/.codex/agents
cp <skill source>/agents/codex/*.toml ~/.codex/agents/
```

## Codex

Invoke through `$adversarial-review` or natural language.

Use named agents from `agents/codex/` when installed:

| Role | Named agent | Reasoning effort |
|------|-------------|------------------|
| Attacker | `spec-attacker` | `xhigh` |
| Judge | `spec-judge` | `xhigh` |
| Arbiter | `spec-arbiter` | `xhigh` |

Spawn one `spec-attacker` per enabled attack angle in bounded waves. Do not assume the configured `agents.max_threads`; use conservative fan-out when the host is busy. Keep orchestration in the parent; this workflow does not require grandchildren and assumes `agents.max_depth = 1`.

Version guard:

- Recommend a current Codex CLI.
- Codex v0.137.0 silently ignored named-agent config; do not rely on named-agent effort or sandbox behavior there.
- A Windows variant remains unresolved in the design notes. On Windows, disclose if named-agent config cannot be trusted.

If named agents are not installed, or the host cannot prove named-agent config is honored, continue with inherited settings only when the user still wants the review. Disclose the limitation in the report:

```text
Note: Codex named agents were unavailable or untrusted, so attacker/judge roles inherited the parent settings.
```

Never substitute a downgraded or fast model for judges or arbiters. If `--ultra` is requested in Codex, run `--high` and disclose:

```text
Note: --ultra is Claude-only; Codex ran the --high pipeline instead.
```

Codex subagent wrapper:

```text
Your task is to perform the following read-only adversarial-review subtask.

<agent-instructions>
...attacker, judge, or arbiter prompt...
</agent-instructions>

Do not edit files. Do not run builds, tests, typechecks, linters, formatters,
compilers, package installs, migrations, or app commands. You may read repository
files needed to verify document claims. Output ONLY the requested JSON.
```

Close or release subagents after collecting final output when the host supports it.

## Claude Code

Invoke through `/adversarial-review` or natural language once installed as a personal skill/command.

At default and `--high`, use Claude Code Agent calls with maximum available reasoning effort per spawn. Attackers, judges, and arbiters should be separate fresh-context agents.

For `--ultra`, run the pipeline as an ultracode Workflow:

- Wider attacker fan-out.
- Structured output schemas for attackers, judges, and arbiters.
- Three-vote refutation per finding during cull.
- Optional cross-model arbitration when available.

Do not claim Codex parity for `--ultra`.

## Sequential Fallback

If an environment cannot spawn subagents, run the same roles sequentially and disclose it:

```text
Note: subagents were unavailable, so adversarial-review roles were run sequentially.
```

Sequential fallback is portable but not equivalent to independent fresh-context parallel review. Keep the same role boundaries, output contracts, cull rules, and two-round cap.
