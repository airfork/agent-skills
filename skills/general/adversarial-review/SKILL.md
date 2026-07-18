---
name: adversarial-review
description: >-
  Use when the user invokes $adversarial-review or /adversarial-review, asks to
  adversarially review a spec, implementation plan, migration plan, architecture
  design, or planning document before implementation, or asks for xhigh
  fresh-context critique with revise/reject and resolution verification.
---

# Adversarial Review

Require Ruby 2.6 or newer and repository spec/plan files. Load details from
[attack-angles.md](attack-angles.md), [judge-rubric.md](judge-rubric.md), and
[platform-adapters.md](platform-adapters.md).

## Invoke

Resolve the executable from the loaded skill, never from the reviewed checkout:

```bash
AR_SKILL_DIR="/absolute/path/to/directory-containing-this-SKILL.md"
REVIEW_REPO="/absolute/path/to/reviewed/repository"
"$AR_SKILL_DIR/scripts/adversarial-review" start \
  --repository "$REVIEW_REPO" --spec docs/spec.md --plan docs/plan.md \
  --tier default --mode revise --output both --executor auto \
  --model MODEL --effort EFFORT
```

Map host invocations: `--high` maps to `--tier high`; `--ultra` maps to `--tier ultra`; `--report-only` maps to `--mode critique --output both`;
`--chat-only` maps to `--output chat`. Choices are
`--executor auto|codex|claude|cursor|gemini|generic` and
`--output chat|file|both`. The default is `--mode revise --output both`. Run the
executable or subcommand with `--help` for other options.

For ordinary natural-language requests that ask only for critique or review, run the report-only stages and return findings in chat only; do not revise documents or create or append a report file.
Repository writes require an explicit `--report-only`, an explicit request to revise or fix the documents, or an explicit `$adversarial-review` invocation.

## Non-Negotiables

- Never silently change vendor, tier, model, or effort. On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier.
  If the host cannot enforce required role effort, follow the selected platform adapter's explicit fallback or stop rule; do not invent a weaker generic fallback.
- Require fresh read-only tasks, digests, closed JSON, immutable IDs,
  and evidence-bearing capabilities.
- The parent alone applies `FIXED|REJECTED` actions. Reviewers never edit. Limit
  parent edits to reviewed files; preserve rejection.
- Running the control plane does not install or change global skill links, agent definitions, or user configuration.

## Run

1. Start; retain `run_dir` and tasks. The public CLI uses Generic bundles for
   fresh read-only host-native parallel work.
2. `ingest` each result/declaration. `continue` until results, actions, or
   terminal state; submit decisions only via `continue --actions ACTIONS.json`.
3. Complete per-ID resolution and the round-two fresh sweep. Any stuck promoted finding at the round cap yields `DID NOT CONVERGE`, regardless of severity.
   `PASSED WITH OPEN QUESTIONS` is reserved for non-blocking questions that are not tied to a promoted finding.
4. Use `status --run-dir RUN_DIR --json` to resume. Return generated output.

## Ruby-Unavailable Fallback

When Ruby is unavailable, do not invent durable state. Manually follow
[attack-angles.md](attack-angles.md), [judge-rubric.md](judge-rubric.md), and
`assets/schemas/`; preserve immutable IDs, `UNPROVEN` evidence gaps,
and parent-only decisions. State: `Scripting unavailable; capabilities degraded.`
Disclose missing automation, never switch to a weaker direct executor, and
never claim scripted crash recovery or resumability.

## Outcomes

`DEGRADED CAPABILITIES` replaces only an ordinary `PASSED` when a required capability is `unavailable` or a safety boundary is `behavioral`.
`REPORT ONLY`, `PASSED WITH OPEN QUESTIONS`, and `DID NOT CONVERGE` keep their verdict. Retained verdicts disclose degraded capabilities separately.
Return the script's stable IDs, provenance, and usage. Critique mode never edits targets.
