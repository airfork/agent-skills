# Repository Instructions

This repository stores custom agent skills and related authoring guidance.

## Ground Rules

- Preserve existing skill drafts. Do not move or rewrite root-level draft skill directories unless the user explicitly asks.
- When adding, moving, renaming, or retiring a skill, update both `CATALOG.md` and `skills.yaml` in the same change.
- When changing global install behavior, update `skills.yaml`, update the catalog's install status, and run `scripts/sync-skills --target codex --dry-run`.
- Keep individual skill folders lean: `SKILL.md` plus required `agents/`, `scripts/`, `references/`, or `assets/` resources. Avoid extra docs inside a skill unless that skill requires them as references.
- Use the category folders under `skills/` for finalized placement:
  - `skills/general/`
  - `skills/codex-cursor/`
  - `skills/claude/`
  - `skills/claude-ultracode/`
- Treat root-level skill directories as unplaced drafts until the structure is finalized.
- Use `rtk` for agent-run shell commands.
- Use the configured human git author only. Do not add AI attribution trailers or bylines to commits.
- Before claiming completion, run the relevant verification and report the exact command.
- Use `scripts/sync-skills --apply` only when the user explicitly wants the global skill symlinks changed.

## Skill Updates

- Prefer the installed `skill-creator` guidance when creating or materially revising Codex skills.
- Keep trigger descriptions in `SKILL.md` frontmatter precise; they are the primary activation surface.
- Update recommended model tier metadata when the skill's expected execution cost changes.
- Validate YAML syntax after editing `skills.yaml`.
