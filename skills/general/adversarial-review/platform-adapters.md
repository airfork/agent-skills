# Platform Adapters

Keep [SKILL.md](SKILL.md) as the portable source of truth. This file only adapts dispatch, install, and host-specific capability details.

## Install

Personal install paths:

| Environment | Skill path |
|-------------|------------|
| Codex | `~/.codex/skills/adversarial-review/` |
| Codex alternate scanned root | `~/.agents/skills/adversarial-review/` |
| Claude Code | `~/.claude/skills/adversarial-review/` |
| Gemini/Antigravity | `~/.gemini/config/skills/adversarial-review/` |

Preferred repo-managed installs:

```bash
scripts/sync-skills --target codex --dry-run
scripts/sync-skills --target codex --apply
scripts/sync-skills --target claude --dry-run
scripts/sync-skills --target claude --apply
scripts/sync-skills --target gemini --dry-run
scripts/sync-skills --target gemini --apply
```

Gemini/Antigravity treats `~/.gemini/config/` as a global customization root and
loads skills from its `skills/` directory. Do not create Gemini-specific copies
of general skills; install the same source skill folder with the `gemini` target.

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

For Codex fallback roles, require fresh context, the parent session's selected GPT-5.6 model, and xhigh (or the host's maximum) effort; if Codex cannot prove all three, stop and report that the adversarial-review tier was not enforceable.

```text
Blocked: Codex could not prove fresh context, selected GPT-5.6 model inheritance, and maximum role effort, so the requested adversarial-review tier was not enforceable.
```

When named agents are unavailable, a programmatic launcher may start each role
with the current Codex CLI shape:

```bash
codex exec --ephemeral --ignore-user-config --ignore-rules --sandbox read-only \
  --model <selected-gpt-5.6-slug> \
  -c model_reasoning_effort="<host-maximum-effort>" -
```

The launcher must write the complete role prompt and review packet to stdin, close stdin, and capture the combined startup transcript. Validate the runtime model and reasoning-effort fields before accepting the role output. The Codex fail-closed rule above takes precedence over the portable sequential fallback below.

On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier: judges and arbiters use the same inherited model and xhigh effort as attackers. This Codex exception does not weaken other hosts' prohibitions on fast or cheap judges and arbiters. If `--ultra` is requested in Codex, run `--high` and disclose:

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

## Gemini/Antigravity

Invoke through the skill activation mechanism or natural language that clearly
names `adversarial-review`.

Run the same workflow and role boundaries as the portable core. If Gemini cannot
spawn independent subagents or cannot pin xhigh effort per role, use the
sequential fallback and disclose the limitation in the report. Never treat
Gemini support as a reason to add a separate Gemini-only skill package.

## Sequential Fallback

If the selected platform adapter permits sequential fallback and the environment cannot spawn subagents, run the same roles sequentially and disclose it:

```text
Note: subagents were unavailable, so adversarial-review roles were run sequentially.
```

Sequential fallback is portable but not equivalent to independent fresh-context parallel review. Keep the same role boundaries, output contracts, cull rules, and two-round cap.
