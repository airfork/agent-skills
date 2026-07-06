# Repository Guidelines

## Purpose

This repository is the source of truth for custom agent skills. It should make skills easy to find, version, review, and install into the right agent environment without mixing incompatible assumptions.

## Categories

Use one of these categories for finalized skills:

| Category | Path | Use when |
|----------|------|----------|
| `general` | `skills/general/<skill-name>/` | The skill is portable across Codex, Cursor, Claude, Gemini/Antigravity, and other agents with minimal adaptation. |
| `codex-cursor` | `skills/codex-cursor/<skill-name>/` | The skill depends on Codex/Cursor behaviors, tool names, or workflows. |
| `claude` | `skills/claude/<skill-name>/` | The skill is Claude-only, such as Claude Code commands or Claude-specific tool assumptions. |
| `claude-ultracode` | `skills/claude-ultracode/<skill-name>/` | The skill is Claude-only and explicitly expects UltraCode, or is materially better with UltraCode. |

Root-level skill directories may exist as drafts while the structure is being finalized. Catalog them as unplaced drafts and move them only as an explicit cleanup step.

## Required Metadata

Every cataloged skill needs:

- `name`
- `path`
- `category`
- `status`
- supported agent interfaces
- recommended model tier
- one-sentence description
- install policy for each supported global target

Update both:

- `CATALOG.md` for human browsing
- `skills.yaml` for tooling and structured indexing

Update `USAGE.md` in the same change whenever a skill's invocation syntax,
flags, tiers, targets, accepted inputs, action permissions, or output files
change. Users should not need to inspect individual skill folders to discover a
skill's supported usage surface.

## Model Tiers

Use stable tier labels in metadata, with current model examples in the README:

| Tier | Use for |
|------|---------|
| `fast` | Cheap, bounded, low-risk tasks. |
| `standard` | Normal skill execution and repo-aware work. |
| `deep` | Broad review, ambiguous planning, architecture, security, or high-impact changes. |
| `ultracode` | Claude workflows that explicitly call for UltraCode. |

If a skill has multiple modes, record the default tier and mention heavier modes in `notes`.

## Skill Folder Rules

For Codex-style skills, prefer this shape:

```text
skill-name/
  SKILL.md
  agents/openai.yaml
  references/
  scripts/
  assets/
  state/      # optional: mutable runtime data, git-ignored
```

Only include folders that are actually needed. Keep `SKILL.md` focused and move bulky optional context into `references/`.

`state/` is for mutable data a skill accumulates at runtime (progress files, generated artifacts, logs). It is covered by the root `.gitignore` rule `skills/**/state/`, travels with symlink installs, and must never hold instructions or reference material the skill needs to function from a fresh clone.

## Global Skill Installs

Use managed per-skill symlinks for local global installs.

Do not symlink an entire category folder or this repository into `~/.codex/skills`, `~/.cursor/skills`, `~/.gemini/config/skills`, or another global skill directory. Global skill discovery expects individual skill folders, and whole-directory linking makes drafts too easy to activate accidentally.

The source of truth stays in this repository. Installed global skills should point back to the source skill folder:

```text
~/.codex/skills/<skill-name> -> /Users/tunji/skills/<source-path>
~/.gemini/config/skills/<skill-name> -> /Users/tunji/skills/<source-path>
```

Install policy is explicit in `skills.yaml`:

```yaml
install:
  codex:
    enabled: true
    mode: symlink
  cursor:
    enabled: false
    mode: symlink
  gemini:
    enabled: true
    mode: symlink
```

Rules:

- Keep draft and unplaced skills disabled by default.
- Enable a target only after the skill's path and runtime assumptions are intentional.
- Prefer `mode: symlink` for local development so repo edits are live immediately.
- Use copy/export workflows only for sharing, archiving, or installing on another machine.
- Never overwrite a non-symlink directory in a global skill path without an explicit `--force` operation.

Use `scripts/sync-skills` to manage links:

```bash
scripts/sync-skills --target codex --dry-run
scripts/sync-skills --target codex --apply
scripts/sync-skills --target claude --dry-run
scripts/sync-skills --target claude --apply
scripts/sync-skills --target cursor --dry-run
scripts/sync-skills --target gemini --dry-run
scripts/sync-skills --target gemini --apply
```

The sync script reads `skills.yaml`, validates each selected skill has a `SKILL.md`, and creates one symlink per selected skill. It supports `--prune` for removing repo-managed symlinks that are no longer selected.

## Change Checklist

Before committing a skill change:

1. Confirm the skill path is intentional.
2. Update `CATALOG.md`.
3. Update `skills.yaml`.
4. Update `USAGE.md` if the user-facing usage surface changed.
5. Confirm install targets are disabled for drafts and enabled only for intentional global installs.
6. Validate `skills.yaml` syntax.
7. Run any skill-specific validation or smoke test.
8. Run `scripts/sync-skills --dry-run` for each affected install target when install metadata changed.
9. Check `git status --short` so unrelated work is not accidentally swept in.
