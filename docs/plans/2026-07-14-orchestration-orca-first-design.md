# Orca-First Orchestration Design

## Goal

Make Orca the mandatory coordination backend whenever the `orchestration` skill is active. Never silently substitute native subagent tools.

## Behavior

At the start of an orchestration workflow, verify that the Orca CLI and a running Orca runtime with orchestration support are available. If they are available, perform all worker creation, dispatch, messaging, waiting, and completion tracking through Orca.

Generic agent-spawn APIs, native subagent tools, and chat-only parallel-worker features are not valid alternatives while Orca is available, even when the user did not explicitly say “use Orca.”

If an Orca prerequisite is unavailable, stop before creating workers. Report the failed prerequisite or command and ask the user whether to continue with the host's native subagent tools. Use native tools only after the user explicitly approves that fallback.

Full ownership handoffs remain routed through the `orca-cli` skill as currently documented; this change applies to workflows that activate the `orchestration` skill.

## Implementation

Update the installed skill at `/Users/tunji/.agents/skills/orchestration/SKILL.md`:

- Replace the conditional “if a task says to use Orca” boundary with an unconditional Orca-first rule.
- Add a startup availability check and explicit-consent fallback policy near the beginning of the skill.
- Keep the existing Orca orchestration commands, lifecycle rules, and full-handoff boundary intact.
- Avoid changing unrelated examples or command reference material.

## Validation

Use pressure scenarios to confirm that an agent reading the revised skill:

1. Chooses Orca for an ordinary supervised multi-agent task that does not name Orca.
2. Stops and asks permission when Orca is unavailable.
3. Does not use native subagent tools before permission is granted.

Run the repository's normal validation commands if the installed skill is brought into this repository; otherwise validate the skill frontmatter and inspect the focused diff directly.
