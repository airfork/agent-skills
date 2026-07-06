# Skill Catalog

This catalog is the human-readable inventory. Keep it in sync with `skills.yaml`.
For invocation syntax, flags, tiers, targets, and action permissions, see
`USAGE.md`.

## Model Tier Key

| Tier | Recommended execution |
|------|-----------------------|
| `fast` | GPT-5.4 mini, Claude Sonnet medium, or Gemini low-effort/default. |
| `standard` | GPT-5.5 medium, Claude Sonnet high, or Gemini default. |
| `deep` | GPT-5.5 high, Claude Opus 4.8 high, or Gemini's highest available reasoning model. |
| `ultracode` | Claude Opus 4.8 high with UltraCode. |

## Skills

| Skill | Path | Category | Status | Install | Recommended tier | Description |
|-------|------|----------|--------|---------|------------------|-------------|
| `adversarial-review` | `skills/general/adversarial-review/` | `general` | Active | Codex, Claude, and Gemini enabled; Cursor disabled | `deep`; heavy mode `ultracode` for Claude-only UltraCode runs | Cross-platform adversarial review workflow for specs and implementation plans, using fresh-context attack angles, refute-or-promote culling, revise/reject loops, and resolution verification before implementation. |
| `code-review` | `skills/codex-cursor/code-review/` | `codex-cursor` | Active | Codex and Gemini enabled; Cursor disabled | `deep`; use `standard` only for lower-cost routine reviews | Codex-first multi-angle review workflow mirroring the built-in Claude Code /code-review (method-based finder angles, verdict-ladder verification, gap sweep at deep), plus verified-finding remediation and opt-in fix/commit/push/PR flags. |

## Category Backlog

| Category | Path | Notes |
|----------|------|-------|
| General | `skills/general/` | Portable skills that should work across agent environments. |
| Codex/Cursor | `skills/codex-cursor/` | Skills optimized for Codex, Cursor, or both. |
| Claude | `skills/claude/` | Claude-only skills and command workflows. |
| Claude plus UltraCode | `skills/claude-ultracode/` | Claude workflows that explicitly depend on or strongly benefit from UltraCode. |
