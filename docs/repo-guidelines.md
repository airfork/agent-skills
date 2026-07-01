# Repository Guidelines

## Purpose

This repository is the source of truth for custom agent skills. It should make skills easy to find, version, review, and install into the right agent environment without mixing incompatible assumptions.

## Categories

Use one of these categories for finalized skills:

| Category | Path | Use when |
|----------|------|----------|
| `general` | `skills/general/<skill-name>/` | The skill is portable across Codex, Cursor, Claude, and other agents with minimal adaptation. |
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

Update both:

- `CATALOG.md` for human browsing
- `skills.yaml` for tooling and structured indexing

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
```

Only include folders that are actually needed. Keep `SKILL.md` focused and move bulky optional context into `references/`.

## Change Checklist

Before committing a skill change:

1. Confirm the skill path is intentional.
2. Update `CATALOG.md`.
3. Update `skills.yaml`.
4. Validate `skills.yaml` syntax.
5. Run any skill-specific validation or smoke test.
6. Check `git status --short` so unrelated work is not accidentally swept in.

