---
name: adversarial-review
description: >-
  Use when the user invokes $adversarial-review or /adversarial-review, asks to
  adversarially review a spec, implementation plan, migration plan, architecture
  design, or planning document before implementation, or asks for xhigh
  fresh-context critique with revise/reject and resolution verification.
---

# Adversarial Review

Require Ruby 2.6 or newer plus repository spec/plan files. A POSIX host with descriptor-relative filesystem calls gets the hardened backend; every other host, including native Windows, runs the portable backend, which keeps the full workflow but enforces fewer filesystem guarantees and says so in the report. Load `platform-adapters.md` only for executor selection, adapter troubleshooting, or backend detail.
Load `attack-angles.md` and `judge-rubric.md` only for Ruby-unavailable manual fallback or role-contract debugging.

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
Repository writes require an explicit request to revise or fix the documents,
or an explicit `$adversarial-review` invocation whose chosen mode is `revise`.
`--report-only` never authorizes revision. Contradictory aliases and explicit
mode/output values are rejected regardless of argument order.

## Non-Negotiables

- Never silently change vendor, tier, model, or effort. On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier.
  If the host cannot enforce required role effort, follow the selected platform adapter's explicit fallback or stop rule; do not invent a weaker generic fallback.
- Require fresh read-only tasks, digests, closed JSON, immutable IDs,
  and evidence-bearing capabilities.
- The parent alone applies `FIXED|REJECTED` actions. Reviewers never edit. Limit
  parent edits to reviewed files; preserve rejection.
- Running the control plane does not install or change global skill links, agent definitions, or user configuration.

## Run

1. Start and retain `run_dir`. Dispatch only `pending_task_handoffs`; legacy
   `pending_tasks` is path inventory. Read task bytes once, verify the trusted
   `task_sha256` before parsing or using task fields. Read the skill-contained
   schema once, verify its digest, and use the returned in-memory task/schema.
2. `ingest` each result/declaration. `continue` until results, actions, or
   terminal state; submit decisions only via `continue --actions ACTIONS.json`.
3. Complete per-ID resolution and the round-two fresh sweep. Any stuck promoted finding at the round cap yields `DID NOT CONVERGE`, regardless of severity.
   `PASSED WITH OPEN QUESTIONS` is reserved for non-blocking questions that are not tied to a promoted finding.
4. Use `status --run-dir RUN_DIR --json` to resume. Return generated output.

## Filesystem Backends

The control plane selects its backend by probing the host, never by platform
name. Report the selected backend; do not describe a portable run as equivalent
to a hardened one.

| Backend | Selected when | Enforces |
|---------|---------------|----------|
| `posix` | descriptor-relative calls and directory descriptors are both available | descriptor-relative paths, directory locking, durable directory metadata, POSIX mode bits, inode identity |
| `portable` | anything else, including native Windows | atomic publish, hard-linked lock anchors, and cross-process file locking only |

A portable run still produces immutable IDs, durable resumable state, digests,
and the same verdicts. It cannot close symlink-swap and rename-under-us races,
so its report carries a `DEGRADED FILESYSTEM HARDENING` section naming the
guarantees that were not enforced. That disclosure is separate from the
capability gate and never changes the verdict.

## Ruby-Unavailable Fallback

When Ruby is unavailable, do not invent durable state. Manually follow
[attack-angles.md](attack-angles.md), [judge-rubric.md](judge-rubric.md), and
`assets/schemas/`; preserve immutable IDs,
`UNPROVEN` evidence gaps, and parent-only decisions. State: `Scripting unavailable; capabilities degraded.`
Disclose missing automation, never switch to a weaker direct executor, and
never claim scripted crash recovery or resumability.

## Outcomes

`DEGRADED CAPABILITIES` replaces only an ordinary `PASSED` when a required capability is `unavailable` or a safety boundary is `behavioral`.
`REPORT ONLY`, `PASSED WITH OPEN QUESTIONS`, and `DID NOT CONVERGE` keep their verdict. Retained verdicts disclose degraded capabilities separately.
Return the script's stable IDs, provenance, and usage. Critique mode never edits targets.
