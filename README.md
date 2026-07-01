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
| `templates/` | Reusable metadata templates for adding new skills. |

Root-level skill folders are allowed temporarily for existing drafts. Do not move them into `skills/` until the target category and install behavior are finalized.

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

See `CATALOG.md` for the current skill list. The existing `code-review/` draft is intentionally left at the repository root until the category structure is finalized.

