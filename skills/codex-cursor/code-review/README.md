# code-review skill

Personal Codex-first skill for two related workflows:

1. `/code-review` - review a branch, PR, staged diff, unstaged diff, or dirty worktree using independent finder and verifier passes.
2. `/address-review` - address verified review findings or actionable PR review comments with narrow edits and targeted verification.

The review workflow is intentionally conservative: it reports only high-confidence issues introduced by the review target and avoids CI-catchable failures, broad quality commentary, and senior-engineer nits.

## Files

| File | Purpose |
|------|---------|
| [SKILL.md](SKILL.md) | Main review and address-review workflow |
| [verifier-rubric.md](verifier-rubric.md) | Confidence scoring rubric for verifier subagents |
| [platform-adapters.md](platform-adapters.md) | Codex, Cursor, Claude Code, and sequential fallback notes |
| [agents/openai.yaml](agents/openai.yaml) | Minimal OpenAI/Codex-facing manifest |

## Install

Install from the repository root with the managed symlink installer:

```bash
scripts/sync-skills --target codex --dry-run
scripts/sync-skills --target codex --apply
```

See `platform-adapters.md` for Cursor and Claude Code notes.

## Quick test prompts

```text
/code-review quick staged
/code-review standard working tree
/code-review high pr #123
/address-review the findings from the last review
/address-review pr #123 comments
```

## Design checks

- Review mode stays read-only.
- Address mode edits only verified/applicable findings.
- Dirty worktree and untracked files are included when in scope.
- Finder/verifier thresholds match your preferred cost-to-confidence tradeoff.
- The adapter you use has an acceptable sequential fallback when subagents are unavailable.
