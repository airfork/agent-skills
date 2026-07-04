# Agent Skills

Private source repo for custom agent skills, drafts, and shared authoring conventions.

## Layout

| Path | Purpose |
|------|---------|
| `skills/general/` | Portable skills that can be used across agent environments with minimal adaptation. |
| `skills/codex-cursor/` | Skills designed for Codex and/or Cursor workflows. |
| `skills/claude/` | Claude-only skills, commands, or workflows. |
| `skills/claude-ultracode/` | Claude workflows that specifically assume UltraCode is available or useful. |
| `CATALOG.md` | Human-readable skill inventory, status, and model guidance. |
| `skills.yaml` | Machine-readable index for scripts, agents, or future tooling. |
| `docs/repo-guidelines.md` | Repository conventions and authoring rules. |
| `scripts/sync-skills` | Manifest-driven installer for per-skill symlinks into global skill directories. |
| `templates/` | Reusable metadata templates for adding new skills. |

Root-level skill folders are allowed temporarily for drafts. Move finalized skills into the matching `skills/<category>/` folder and install them through `skills.yaml`.

## Model Tiers

Use these labels in `CATALOG.md` and `skills.yaml`:

| Tier | Codex/OpenAI default | Claude default | Use for |
|------|---------------------|----------------|---------|
| `fast` | GPT-5.4 mini | Sonnet medium | Small edits, simple transforms, quick checks. |
| `standard` | GPT-5.5 medium | Sonnet high | Normal skill execution and repo-aware work. |
| `deep` | GPT-5.5 high | Opus 4.8 high | Broad reviews, ambiguous planning, architecture, high-risk work. |
| `ultracode` | N/A | Opus 4.8 high with UltraCode | Claude-only workflows that benefit from UltraCode explicitly. |

Model names are local operating labels. Update them when the available model menu changes.

## Current Inventory

See `CATALOG.md` for the current skill list. The `code-review` skill is finalized under `skills/codex-cursor/code-review/` and installed into Codex through a managed symlink.

## Installing Skills Locally

Use managed per-skill symlinks for local installs. A skill is installed only when `skills.yaml` explicitly enables the target under `install`.

Preview installs:

```bash
scripts/sync-skills --target codex --dry-run
scripts/sync-skills --target claude --dry-run
```

Apply installs:

```bash
scripts/sync-skills --target codex --apply
scripts/sync-skills --target claude --apply
```

The script refuses to overwrite unmanaged files or directories unless `--force` is passed. Use `--prune` to remove repo-managed symlinks that are no longer selected for a target.
