# code-review skill

Personal Codex-first skill for two related workflows, both invoked through `$code-review`:

1. **Review mode** - review a branch, PR, staged diff, unstaged diff, or dirty worktree using independent finder and verifier passes.
2. **Address mode** - address verified review findings or actionable PR review comments with narrow edits and targeted verification.

The review workflow is intentionally conservative: it reports only high-confidence issues introduced by the review target and avoids CI-catchable failures, broad quality commentary, and senior-engineer nits.

## Files

| File | Purpose |
|------|---------|
| [SKILL.md](SKILL.md) | Main review and address mode workflow |
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

## Codex Prompt Examples

```text
Use $code-review to review staged changes with quick intensity.
Use $code-review to review the working tree with standard intensity.
Use $code-review to review PR #123 with high intensity.
Use $code-review to review branch changes with deep intensity.
```

Review first, then fix every verified finding that is safe to address:

```text
Use $code-review to review the working tree with standard intensity, then address all applicable verified findings and run targeted verification.
```

Address findings from the review that just ran:

```text
Use $code-review to address the verified findings from the last code review. Re-check that each finding still applies, fix the applicable ones, leave stale or decision-needed items unchanged, and run targeted verification.
```

Address PR review comments:

```text
Use $code-review to address actionable review comments on PR #123. Re-check each comment against the current code, patch only applicable comments, and run targeted verification.
```

`/address-review` is not a separate Codex skill or command. Use `$code-review` with natural language when you want address mode.

## Run Options

In Codex, invoke the skill with `$code-review`. Review prompts must name an explicit tier: `quick`, `standard`, `high`, or `deep`. If the prompt asks for review but only names a target such as `staged`, `branch`, `working tree`, or `PR #123`, print the help text from `SKILL.md` and stop instead of running a default review.

Invoking review mode grants permission to spawn the read-only finder and verifier subagents required by the selected tier. The skill should not ask again before spawning those subagents; only ask before work outside the user-requested scope, such as unrequested edits, broad refactors, GitHub write actions, or explicit model/cost escalation beyond the chosen tier.

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
- The adapter spawns read-only finder/verifier subagents without asking for extra permission; sequential fallback is only for hosts where subagents are unavailable.
