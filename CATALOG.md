# Skill Catalog

This catalog is the human-readable index. Keep it in sync with `skills.yaml`.

## Model Tier Key

| Tier | Recommended execution |
|------|-----------------------|
| `fast` | GPT-5.4 mini or Claude Sonnet medium. |
| `standard` | GPT-5.5 medium or Claude Sonnet high. |
| `deep` | GPT-5.5 high or Claude Opus 4.8 high. |
| `ultracode` | Claude Opus 4.8 high with UltraCode. |

## Skills

| Skill | Path | Category | Status | Install | Recommended tier | Description |
|-------|------|----------|--------|---------|------------------|-------------|
| `code-review` | `skills/codex-cursor/code-review/` | `codex-cursor` | Active | Codex enabled; Cursor disabled | `deep`; use `standard` only for lower-cost routine reviews | Codex-first multi-angle review workflow mirroring the built-in Claude Code /code-review (method-based finder angles, verdict-ladder verification, gap sweep at deep), plus verified-finding remediation. |

## Category Backlog

| Category | Path | Notes |
|----------|------|-------|
| General | `skills/general/` | Portable skills that should work across agent environments. |
| Codex/Cursor | `skills/codex-cursor/` | Skills optimized for Codex, Cursor, or both. |
| Claude | `skills/claude/` | Claude-only skills and command workflows. |
| Claude plus UltraCode | `skills/claude-ultracode/` | Claude workflows that explicitly depend on or strongly benefit from UltraCode. |
