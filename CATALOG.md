# Skill Catalog

This catalog is the human-readable inventory. Keep it in sync with `skills.yaml`.
For invocation syntax, flags, tiers, targets, and action permissions, see
`USAGE.md`.

## Model Tier Key

| Tier | Recommended execution |
|------|-----------------------|
| `fast` | GPT-5.6 Luna, Claude Sonnet medium, Gemini low-effort/default, or Copilot's default fast model. |
| `standard` | GPT-5.6 Terra, Claude Sonnet high, Gemini default, or Copilot's default model. |
| `deep` | GPT-5.6 Sol, Claude Opus 5 high, Gemini's highest available reasoning model, or Copilot's highest available reasoning model. |
| `ultracode` | Claude Opus 5 high with UltraCode. |

## Skills

| Skill | Path | Category | Status | Install | Recommended model tier | Description |
|-------|------|----------|--------|---------|------------------|-------------|
| `adversarial-review` | `skills/general/adversarial-review/` | `general` | Active | Codex, Claude, Cursor, Gemini, and Copilot enabled | `standard`; the skill tiers internally, running attackers at Sonnet medium and one synthesis pass at Opus high | Single-round read-only critique of a spec or plan. Four fresh-context attackers run in one parallel batch, `scripts/check-quotes` drops any finding whose quote is not verbatim in the file it cites, and one synthesis pass rejects aggressively and ships at most three findings. Roughly ten minutes, chat only, never edits the reviewed documents. Zero findings is a valid outcome. |
| `prompt-engineer` | `skills/general/prompt-engineer/` | `general` | Candidate | Codex and Claude disabled; Cursor and Gemini disabled | `standard`; heavy mode `deep` | Evidence-driven prompt diagnosis and revision workflow. Explicit `$prompt-engineer` use is documented for qualification, while all managed installs and implicit activation remain disabled pending separate cutover approval. |
| `code-review` | `skills/codex-cursor/code-review/` | `codex-cursor` | Active | Codex, Gemini, and Copilot enabled; Cursor disabled | GPT-5.6 Sol (`deep` repository model tier) recommended; GPT-5.6 Luna and Terra remain supported at every review intensity when selected in the parent | Codex-first multi-angle review workflow mirroring the built-in Claude Code /code-review (method-based finder angles, verdict-ladder verification, gap sweep at deep), plus verified-finding remediation and opt-in fix/commit/push/PR flags. |
| `milestone-orchestrator` | `skills/general/milestone-orchestrator/` | `general` | Active | Codex and Claude enabled; Cursor and Gemini disabled | `deep`; heavy mode `ultracode` for Claude-only UltraCode runs | Two-phase milestone workflow: interactive PREPARE (grounding, decision packets, adversarially reviewed SPEC/PLAN, one final approval) followed by an unattended multi-agent RUN through implementation, review remediation, serial integration, verification, commit/push/draft-PR, mandatory final code review, and safe resource cleanup, stopping before merge or deploy. |
| `ui-drill` | `skills/claude/ui-drill/` | `claude` | Active | Claude enabled; Codex, Cursor, and Gemini disabled | `standard` | Personal UI/UX critique tutoring course: generates deliberately flawed mockups, grades perception and articulation separately, and adapts a nine-module curriculum via a persistent student model in the skill's git-ignored `state/` folder. |

## Category Backlog

| Category | Path | Notes |
|----------|------|-------|
| General | `skills/general/` | Portable skills that should work across agent environments. |
| Codex/Cursor | `skills/codex-cursor/` | Skills optimized for Codex, Cursor, or both. |
| Claude | `skills/claude/` | Claude-only skills and command workflows. |
| Claude plus UltraCode | `skills/claude-ultracode/` | Claude workflows that explicitly depend on or strongly benefit from UltraCode. |
