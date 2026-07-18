---
name: adversarial-review
description: >-
  Use when the user invokes $adversarial-review or /adversarial-review, asks to
  adversarially review a spec, implementation plan, migration plan, architecture
  design, or planning document before implementation, or asks for xhigh
  fresh-context critique with revise/reject and resolution verification.
---

# Adversarial Review

Run the portable control plane; do not reconstruct its schemas, prompts, state,
IDs, or reports. Accept repository spec/plan files only.

Use [attack-angles.md](attack-angles.md) for coverage,
[judge-rubric.md](judge-rubric.md) for verdicts, and
[platform-adapters.md](platform-adapters.md) for executor gates. Run
`scripts/adversarial-review --help` or subcommand help for syntax.

## Invoke

Map host skill invocation and equivalent natural language to:

```bash
skills/general/adversarial-review/scripts/adversarial-review start \
  --repository . --spec docs/spec.md --plan docs/plan.md \
  --tier default --mode revise --output both \
  --executor auto --model MODEL --effort EFFORT
```

The exact choices are `--executor auto|codex|claude|cursor|gemini|generic` and
`--output chat|file|both`. The default is `--mode revise --output both`.
`--report-only` is `--mode critique --output both`; `--chat-only` is `--output chat`;
`--ultra` is `--tier ultra`. `--report PATH` overrides the sibling report.

For ordinary natural-language requests that ask only for critique or review, run the report-only stages and return findings in chat only; do not revise documents or create or append a report file.
Repository writes require an explicit `--report-only`, an explicit request to revise or fix the documents, or an explicit `$adversarial-review` invocation.

## Non-Negotiables

- Require fresh read-only reviewer tasks and closed JSON. Reject stale digests
  and unverifiable capabilities.
- Never silently change executor vendor, tier, model, or effort. On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier.
  If the host cannot enforce required role effort, follow the selected platform adapter's explicit fallback or stop rule; do not invent a weaker generic fallback.
- Treat `generic` as first-class. Disclose unavailable capabilities and metrics.
- The parent alone applies `FIXED|REJECTED` actions and may edit only reviewed
  files. Preserve justified rejection; reviewers never edit.
- Running the control plane does not install or change global skill links, agent definitions, or user configuration.

## Run

1. Start; retain `run_dir` and immutable task IDs/digests.
2. Execute generic bundles in fresh read-only contexts, then `ingest` each
   schema result and capability declaration. Verified direct adapters dispatch.
3. Call `continue --run-dir RUN_DIR` until results, parent actions, or terminal
   state. Submit decisions only with `continue --actions ACTIONS.json`.
4. In revise mode, complete resolution and the round-two fresh sweep. Stop after
   two revision rounds. Any stuck promoted finding at the round cap yields `DID NOT CONVERGE`, regardless of severity.
   `PASSED WITH OPEN QUESTIONS` is reserved for non-blocking questions that are not tied to a promoted finding.
5. Use `status --run-dir RUN_DIR --json` to resume. Return generated output.

## Outcomes

Report stable IDs, source angles, `UNPROVEN` gaps, capability verdicts, digests,
executor/CLI/model/effort provenance, retries, timing, and exposed usage.
Critique mode never edits targets. The parent owns every fix/rejection.
