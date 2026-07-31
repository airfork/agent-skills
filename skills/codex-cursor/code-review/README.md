# code-review skill

Personal Codex-first skill for two related workflows, both invoked through `$code-review`:

1. **Review mode** - review a branch, PR, staged diff, unstaged diff, or dirty worktree with independent method-based finder angles, then verify each candidate with a verdict ladder.
2. **Address mode** - address verified review findings or actionable PR review comments with narrow edits and targeted verification.

The workflow mirrors the built-in Claude Code `/code-review` skill: finders are bug-hunting *methods* (line-by-line scan, removed-behavior audit, cross-file tracing, plus cleanup/altitude/conventions lenses), not context-source roles. The precision/recall dial lives in verification and synthesis, not in the finders — finders pass every candidate with a nameable failure scenario through, and a verifier keeps everything it cannot refute from the code.

## Files

| File | Purpose |
|------|---------|
| [SKILL.md](SKILL.md) | Main review and address mode workflow |
| [verifier-rubric.md](verifier-rubric.md) | Verdict ladder (CONFIRMED / PLAUSIBLE / REFUTED) and recall rules for verifier subagents |
| [platform-adapters.md](platform-adapters.md) | Codex, Copilot, Cursor, Claude Code, and sequential fallback notes |
| [agents/openai.yaml](agents/openai.yaml) | Minimal OpenAI/Codex-facing manifest |
| [agents/codex/](agents/codex/) | Optional Codex named-agent definitions for the finder and verifier roles |
| [agents/copilot/](agents/copilot/) | Optional Copilot custom-agent definitions for the same four roles |

## Install

Install from the repository root with the managed symlink installer:

```bash
scripts/sync-skills --target codex --dry-run
scripts/sync-skills --target codex --apply
scripts/sync-skills --target copilot --dry-run
scripts/sync-skills --target copilot --apply
```

See `platform-adapters.md` for Copilot, Cursor, and Claude Code notes. The
workflow uses no POSIX-only shell, so it runs on Windows hosts as well; only
`scripts/sync-skills --apply` needs Developer Mode there to create the symlink.

## Codex Prompt Examples

```text
Use $code-review to review staged changes with quick intensity.
Use $code-review to review the working tree with standard intensity.
Use $code-review to review PR #123 with high intensity.
Use $code-review to review branch changes with deep intensity.
Use $code-review --fix --commit to review the working tree with high intensity, address applicable findings, verify, and commit.
Use $code-review --fix --push to review staged changes with standard intensity, fix applicable findings, commit, and push.
Use $code-review --fix --pr to review branch changes with high intensity, fix applicable findings, commit, push, and open a draft PR.
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

In Codex, invoke the skill with `$code-review`. Review prompts must name an explicit tier: `quick`, `standard`, `high`, or `deep`. For a tierless explicit `$code-review` invocation or command-style request, print the help text and stop. For a tierless ordinary natural-language review request, ask the user conversationally to choose an intensity.

Invoking review mode grants permission to spawn the read-only finder and verifier subagents required by the selected tier. The skill should not ask again before spawning those subagents; only ask before work outside the user-requested scope or requested flags, such as unrequested edits, broad refactors, unflagged GitHub write actions, or explicit model/cost escalation beyond the chosen tier.

| Tier | Cost | Structure | Report cap |
|------|------|-----------|------------|
| `quick` | Low | One inline diff pass, no subagents, no verify. | 4 |
| `standard` | Medium | 8 finder angles x up to 6 candidates, 1-vote verify, precision-tuned. | 8 |
| `high` | High | Same 8 angles, recall-tuned finders and recall-biased verify. | 10 |
| `deep` | Highest | 10 angles (adds language-pitfall and wrapper/proxy correctness) x up to 8 candidates, recall-biased verify, plus a gap-sweep pass. | 15 |

Targets may be omitted from a tiered review request. With no target, review committed branch diff plus staged, unstaged, and untracked files.

Flags may appear anywhere in the prompt:

| Flag | Behavior |
|------|----------|
| `--fix` | Fix verified findings that still apply and are safe to address. |
| `--commit` | Commit in-scope changes after successful verification. |
| `--push` | Push the current branch after successful verification; implies `--commit` for in-scope changes. |
| `--pr` | Push and open a draft PR; implies `--push` and `--commit`, never `--fix`. |
| `--comment` | For PR targets, post the final report as a PR comment. |

The action chain is always `review -> fix -> verify -> commit -> push -> PR/comment`. The skill does not support convenience flags for force-push, no-verify, stash, merge, or thread resolution; those require explicit natural-language requests.

## Model And Effort Policy

Finder and verifier subagents inherit the parent/default model but must run at elevated reasoning effort: `high` for `standard`/`high` tiers, `xhigh` (or the host maximum) for `deep`. In Codex, use the named agents from `agents/codex/` when the user has already installed that optional setup; otherwise use the generic read-only fallback. On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier; verifiers must use the same inherited model as finders. On other hosts, verifiers must not use a downgraded or fast model. Verifier quality directly controls what survives.

Copilot exposes no per-agent reasoning-effort control, so its roles run at the host's maximum available reasoning and the report must disclose that the tier's effort was not enforceable.

Named-agent installation is optional setup, never part of review execution; do not copy TOMLs into `~/.codex/agents/` or `.agent.md` files into `~/.copilot/agents/` unless the user explicitly asks.

## Design checks

- Review mode stays read-only.
- Address mode edits only verified/applicable findings.
- `--fix`, `--commit`, `--push`, `--pr`, and `--comment` are explicit action gates with an implication chain: `--pr` implies `--push`, `--push` implies `--commit`; no flag implies `--fix`.
- Final reports use stable bullet sections for `Review`, `Fixed`, `Reported, not code-fixed`, `Verification`, and `Git` instead of ad hoc tables; address-mode reports must list every applied fix with the finding or PR comment, changed files, and concrete change.
- Dirty worktree and untracked files are included when in scope.
- Finders never see the never-report list; filtering happens at verify and synthesis so half-believed candidates reach an independent verifier.
- Verification is a 3-state verdict ladder with the burden of proof on refuting; at `high`/`deep` the recall rules make PLAUSIBLE the default for realistic runtime states.
- Unchanged lines inside a touched function are in scope; files the diff never touches are not.
- The adapter spawns read-only finder/verifier subagents without asking for extra permission; sequential fallback is only for hosts where subagents are unavailable.
