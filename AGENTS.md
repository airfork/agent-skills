# Repository Instructions

This repository stores custom agent skills and related authoring guidance.

## Ground Rules

- Preserve existing skill drafts. Do not move or rewrite root-level draft skill directories unless the user explicitly asks.
- When adding, moving, renaming, or retiring a skill, update both `CATALOG.md` and `skills.yaml` in the same change.
- When changing global install behavior, update `skills.yaml`, update the catalog's install status, and run `scripts/sync-skills --dry-run` for each affected target (`codex`, `claude`, or `cursor`).
- Keep individual skill folders lean: `SKILL.md` plus required `agents/`, `scripts/`, `references/`, or `assets/` resources. Avoid extra docs inside a skill unless that skill requires them as references.
- A skill may keep mutable runtime data in a `state/` subfolder inside its skill directory. All such folders are git-ignored by the root rule `skills/**/state/`; never commit state, and never store skill instructions or references there.
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
- Use the checked-in command surface in `COMMANDS.md`; route agent-run shell commands through `rtk` when available.
- Subagents are approved by default for broad reviews, independent implementation slices, and parallel repo exploration when they materially improve coverage. Do not ask for extra approval just to execute bounded subagent work.
- If isolated git worktrees are needed, keep them under `.worktrees/`; preserve unrelated work in the main checkout.

## Skill Updates

- Prefer the installed `skill-creator` guidance when creating or materially revising Codex skills.
- Keep trigger descriptions in `SKILL.md` frontmatter precise; they are the primary activation surface.
- Update recommended model tier metadata when the skill's expected execution cost changes.
- Validate YAML syntax after editing `skills.yaml`.

## Verification and cleanup

- Run `scripts/test` for the repository's normal test suite and `scripts/verify` for the full local contract, syntax, and test gate.
- On Ruby 4.0+ (minitest 6), the test suite needs the extracted `minitest-mock` gem: `gem install minitest-mock`.
- `.github/workflows/test.yml` runs the suite on ubuntu, macos, and windows. The matrix now exists for the remaining path and shell-out behavior, not for the retired adversarial-review filesystem backends.
- Preview generated-artifact cleanup with `scripts/clean --dry-run` or `scripts/archive-clean --dry-run` before applying it. Cleanup scripts are path-scoped and must never be used to remove tracked files or unrelated user work.
- Do not delete artifacts as part of routine agent work. If cleanup is explicitly requested, use the checked-in cleanup scripts and report the exact mode used.
- When changing install metadata, run `scripts/sync-skills --dry-run` for each affected target; do not apply global symlink changes without explicit user direction.
