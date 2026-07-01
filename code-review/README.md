# code-review skill (draft)

Codex-first, review-only multi-agent code review: parallel finders plus confidence-scored verifiers.

Inspired by Anthropic's official Claude `code-review` plugin, with first-class support for local branch and dirty-worktree review. Cursor support lives in the adapter notes.

**Status:** Draft — not installed. Review `SKILL.md` before copying anywhere.

## Files

| File | Purpose |
|------|---------|
| [SKILL.md](SKILL.md) | Main Codex-first review workflow |
| [verifier-rubric.md](verifier-rubric.md) | Confidence scoring rubric for verifier subagents |
| [platform-adapters.md](platform-adapters.md) | Codex, Cursor, and Claude Code adapter notes |

## Quick test

After installing per `platform-adapters.md`:

```
/code-review high
/code-review standard working tree
/code-review high pr #123
```

## Review checklist

- [ ] Finder count / thresholds for `quick` | `standard` | `high` feel right
- [ ] Review-only boundary is strict enough
- [ ] Codex adapter matches the current multi-agent tool surface
- [ ] Cursor adapter is sufficient for your installed Cursor workflow
- [ ] Guideline file discovery matches your repos (AGENTS.md, CLAUDE.md, etc.)
- [ ] Review packet captures committed, staged, unstaged, and untracked changes correctly
- [ ] Token cost is acceptable for `high` on typical PR size
