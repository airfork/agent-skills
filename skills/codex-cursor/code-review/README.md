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
/code-review deep branch
/address-review the findings from the last review
/address-review pr #123 comments
```

## Run Options

`/code-review` requires an explicit review tier as its first argument. If the command has no tier, or the first argument is a target such as `staged`, `branch`, `working tree`, or `pr #123`, print the help text from `SKILL.md` and stop instead of running a default review.

| Tier | Cost | Use when | Coverage |
|------|------|----------|----------|
| `quick` | Low | Small, low-risk diffs or a fast pre-check. | Guideline auditor and bug scanner only. |
| `standard` | Medium | Normal local branch, staged, unstaged, or PR review. | Adds history analysis around touched hunks. |
| `high` | High | Pre-merge review where extra coverage is worth the cost. | Adds prior PR/merge context and local comment intent checks. |
| `deep` | Highest | Large, risky, security-sensitive, architecture-shaping, or release-blocking changes. | Adds integration/context analysis and uses the strictest verifier threshold. |

Targets are optional after the tier. With no target, review committed branch diff plus staged, unstaged, and untracked files.

## Design checks

- Review mode stays read-only.
- Address mode edits only verified/applicable findings.
- Dirty worktree and untracked files are included when in scope.
- Finder/verifier thresholds match your preferred cost-to-confidence tradeoff.
- The adapter you use has an acceptable sequential fallback when subagents are unavailable.
