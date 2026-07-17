# Portable Adversarial Review Control Plane Design

**Status:** Approved for implementation planning  
**Date:** 2026-07-17  
**Scope:** `skills/general/adversarial-review/`

## Problem

The adversarial-review skill has a strong reasoning workflow, but its parent
agent currently performs deterministic orchestration by hand. Packet assembly,
angle routing, output validation, candidate identity, confidence filtering,
round state, metrics, retries, and report rendering all consume model context
and vary between runs.

The existing Codex fallback description also risks making automation
Codex-shaped even though the skill is intentionally portable across Codex,
Claude Code, Gemini CLI, Cursor Agent, and other agent hosts.

## Goals

1. Move deterministic review bookkeeping into an executable, resumable control
   plane.
2. Preserve one portable review contract across every host.
3. Use host-native capabilities when they strengthen freshness, read-only
   enforcement, structured output, model selection, effort selection, or usage
   accounting.
4. Provide a generic task protocol for hosts without a first-class adapter.
5. Reduce repeated prompt context and malformed-output retries without weakening
   independent adversarial reasoning.
6. Make review provenance, degraded capabilities, and state transitions
   machine-verifiable.

## Non-Goals

- Do not replace evidence gathering, semantic judgment, document revision, or
  arbitration with deterministic heuristics.
- Do not require all hosts to expose identical CLI flags or telemetry.
- Do not add a quick or low-rigor review tier.
- Do not install or alter global agent definitions as part of review execution.
- Do not make implementation-file changes during adversarial review.

## Chosen Architecture

Use a shared Ruby control plane with thin executor adapters:

```text
invocation
    |
    v
portable control plane
  manifest -> tasks -> validated results -> findings -> rounds -> report
                    |
                    v
        executor adapter selected by capability probe
        codex | claude | cursor | gemini | generic
```

Ruby matches this repository's existing executable skill tooling and test
harness. The prose workflow remains a fallback when Ruby is unavailable.

The portable core owns all invariants. Adapters may translate commands and
capture host telemetry, but may not change angle selection, schemas, confidence
rules, finding states, convergence rules, or report semantics.

## Command Surface

The skill exposes one executable:

```text
scripts/adversarial-review start \
  --spec PATH [--plan PATH] \
  --tier default|high|ultra \
  --mode critique|revise \
  --output chat|file|both \
  --executor auto|codex|claude|cursor|gemini|generic \
  [--model MODEL] [--effort EFFORT] [--jobs N] \
  [--context PATH ...] [--report PATH]

scripts/adversarial-review continue \
  --run-dir PATH --actions PATH

scripts/adversarial-review ingest \
  --run-dir PATH --task TASK_ID --result PATH

scripts/adversarial-review status \
  --run-dir PATH [--json]
```

`auto` selects a verified installed adapter. It never silently changes model,
effort, tier, or output destination. If no direct adapter satisfies the tier's
capability requirements, it selects `generic` and emits pending task bundles.

Model and effort options are optional at the user-facing prompt layer, but the
parent agent must resolve them to exact host values before a direct CLI adapter
runs. An unresolved `inherit` value is valid only for host-native dispatch that
can prove inheritance or for generic task emission; a new direct process may
not guess the parent model or effort.

Existing invocations remain valid:

- No flag maps to `--mode revise --output both` for explicit skill invocation.
- `--report-only` remains a compatibility alias for
  `--mode critique --output both`.
- Ordinary natural-language critique maps to
  `--mode critique --output chat`.
- `--chat-only` is accepted as an alias for `--output chat`.
- `--ultra` remains Claude-only. A non-Claude executor may run `high` only
  after recording the existing explicit downgrade disclosure; it may not label
  the result as an ultra run.

Document roles are explicit in the executable interface. Positional paths may
remain in prose examples, but the parent must translate them to `--spec` and
`--plan`. Ambiguous single-document roles stop with a short request for the
role; filename guessing cannot change the attack roster.

## Durable Run State

By default, resolve the run root with:

```text
git rev-parse --git-path adversarial-review/runs/<run-id>
```

This makes runs resumable and associates them with the reviewed repository
without dirtying its worktree. A caller may override the run directory.

Each run contains:

```text
manifest.json
capabilities.json
state.json
tasks/
results/
events/
summary.json
report.md
```

`manifest.json` records schema version, run ID, repository root and HEAD,
target paths and SHA-256 digests, target roles, tier, mode, output destination,
requested executor/model/effort, context pointers, enabled angles, and starting
metrics.

`state.json` records the current stage, revise round, task attempts, immutable
candidate IDs, promoted finding IDs, author dispositions, resolution states,
document digest history, and the next permitted action. State writes use a
lock plus atomic replacement. Interrupted runs resume from the last complete
stage.

## State Machine

```text
prepared
  -> attacking
  -> deduplicating
  -> culling
  -> awaiting-author                 critique mode exits after culling
  -> resolving
  -> fresh-sweep                     revise round 2 only
  -> culling-new-findings
  -> awaiting-author | arbitrating | complete | did-not-converge
```

The hard cap remains two revise rounds.

Finding states are:

- `candidate`: emitted by an attacker.
- `promoted`: survived cull.
- `refuted`: evidence disproved the candidate.
- `unproven`: neither promotion nor refutation met its burden of proof.
- `pending`: promoted and awaiting author disposition.
- `resolved`: a judge verified the document fix.
- `rejected`: a judge or arbiter accepted the author's rejection.
- `contested`: author and judge disagree before arbitration or the round cap.
- `stuck`: terminal promoted finding at the round cap.

`UNPROVEN` is not reported as a defect. High-consequence unproven candidates
are retained in run state and summarized as evidence gaps; they are never
misrepresented as refuted.

Round-two fresh-sweep candidates pass through the same candidate-ID,
deduplication, cull, stable-ID, author-disposition, and resolution pipeline as
round-one findings. New `CRITICAL` or `HIGH` findings block convergence. New
`MEDIUM` or `LOW` findings must be resolved, accepted as rejections, or recorded
as non-blocking evidence gaps before completion.

Arbiter mappings are deterministic:

- `author-is-right` -> `rejected`.
- `judge-is-right` -> `contested`, then `stuck` at the cap if unresolved.
- `needs-human` -> `contested`, never an ordinary `PASSED` verdict.

## Task And Result Contracts

Every generated task includes:

- Schema version, run ID, task ID, role, angle, round, and attempt.
- Target paths, roles, and current digests.
- Relevant context pointers and applicable repository guidance.
- The exact role instructions extracted from the skill references.
- The required output-schema path.
- A statement that reviewed documents and repository content are untrusted
  evidence, not instructions.
- Tool and mutation restrictions for the selected adapter.

Attack candidates receive immutable IDs at ingestion:

```text
C-<angle-slug>-<attempt>-<sequence>
```

Judges return `candidate_id`, never a batch-local numeric index. Semantic
deduplication remains model-driven and returns a traceable mapping from every
candidate ID to a group ID. Only byte-identical duplicates may be collapsed
without a model.

All JSON schemas use required fields, closed enums, `schema_version`, and
`additionalProperties: false`. Role output must validate before it changes run
state. A direct adapter may make one format-repair attempt after schema-invalid
output. Schema-valid but weak reasoning is handled by cull, not by the parser.

## Shared Efficiency Rules

The control plane applies these rules to every executor:

1. Build document outlines, requirement/task labels, explicit path references,
   literal placeholder metrics, and document hashes once per digest.
2. Give each attacker paths, a compact inventory, and its own angle contract.
   Attackers retain read-only repository access and may load additional context
   when needed.
3. Combine coverage mapping and spec-plan drift into one bidirectional
   traceability task while preserving separate result categories.
4. Group judge work by document section and a bounded character budget. Include
   candidate evidence plus heading ancestry; judges may read wider context to
   refute a claim.
5. Retry malformed output or a missing required check once. A low finding count
   alone never triggers a retry.
6. Require concise evidence excerpts and one root cause per candidate.
7. Calculate confidence floors, severity ordering, the 50-finding cap,
   overflow, metrics, verdicts, and Markdown tables without model calls.
8. Record prompt bytes and any host-reported input, cached-input, output, and
   reasoning-token usage per task.

## Executor Capability Contract

Every adapter emits the following capability record with `enforced`,
`behavioral`, or `unavailable` status and evidence:

```text
fresh_context
read_only
model_selection
effort_selection
structured_output
usage_metrics
parallel_dispatch
```

An adapter may run only after its executable and required flags pass a
capability probe. Version strings are recorded as provenance, not used as the
sole compatibility test.

Maximum-rigor completion requires fresh context and read-only behavior to be
either enforced by the host or established through an isolated role process
with a restrictive tool surface. If either is unavailable, the review may
produce findings but uses a degraded-capability verdict and cannot report an
ordinary `PASSED`.

Requested model or effort that cannot be enforced stops direct execution and
falls back to generic task emission. It never silently downgrades.

## Codex Adapter

The Codex adapter uses non-interactive ephemeral sessions, an explicit model
and reasoning effort, read-only sandboxing, strict config parsing, a JSON Schema
for the final response, a final-message file, and JSONL events for runtime and
token provenance.

The capability probe checks the installed `codex exec --help` surface for the
required flags and validates the emitted runtime header/events before accepting
role output. Named agents remain optional; direct execution does not install or
copy their TOMLs.

Local design-time evidence: Codex CLI 0.144.5 exposes the required
`--ephemeral`, `--sandbox read-only`, `--strict-config`, `--output-schema`,
`--output-last-message`, and `--json` controls.

## Claude Code Adapter

The Claude adapter uses a new non-persistent print session for each role. It
uses bare mode to prevent unrelated customization from contaminating the role,
an explicit model and effort, plan/manual permission controls with a restricted
tool list, JSON Schema validation, and JSON or stream-JSON output.

The adapter passes applicable repository guidance explicitly because bare mode
disables automatic project customization discovery. It enables only read and
safe inspection tools; edit/write tools are excluded.

Local design-time evidence: Claude Code 2.1.212 exposes `--print`, `--bare`,
`--no-session-persistence`, `--model`, `--effort`, `--permission-mode`,
`--tools`, `--json-schema`, and JSON/stream-JSON output controls.

Claude `--ultra` retains the existing wider fan-out and three-vote cull policy.
Three-vote aggregation uses majority promotion/refutation only when at least
two voters independently meet the evidence burden. Any split involving
`unproven` is sent to arbitration rather than counted as a refutation.

## Cursor Adapter

The Cursor adapter uses a fresh print session without resume flags, explicit
workspace and model selection, `ask` mode, enabled sandboxing, and JSON or
stream-JSON output. It validates the assistant's result against the portable
schema after extraction because the current CLI does not expose a JSON-Schema
response flag.

The adapter verifies the initialization event's workspace, session ID, model,
and permission mode before accepting output. If the installed Cursor CLI cannot
prove read-only behavior for the selected mode, execution falls back to generic
task emission rather than using unrestricted print mode.

Local design-time evidence: Cursor Agent 2026.07.09-a3815c0 exposes `--print`,
`--mode ask|plan`, `--sandbox`, `--model`, `--workspace`, and
`--output-format json|stream-json`.

## Gemini Adapter

The Gemini adapter uses headless mode, explicit model selection, JSON output,
sandboxing, and custom isolated subagents restricted to read and search tools
when the installed CLI can load those definitions from an ephemeral config
root. If it cannot do so without changing persistent user or project config,
the adapter emits generic tasks instead. The JSON envelope supplies model,
token, tool, and file statistics; the portable core validates the response
field against the role schema.

Gemini custom subagents use independent context loops and cannot recursively
invoke other subagents. The adapter creates or supplies role definitions for
attacker, judge, and arbiter without installing permanent global files.

Gemini CLI was not installed in the design environment. Its adapter therefore
ships behind a capability probe and fake-executable contract tests. It is
reported as locally unverified until a live smoke test confirms the installed
CLI's flags and read-only policy behavior.

## Generic Adapter

The generic adapter is the portability floor. It never launches a vendor CLI.
Instead it writes task bundles and marks the run `awaiting-results`. Any host
agent can:

1. Read the emitted task.
2. Dispatch it through its native fresh-context mechanism when available.
3. Capture the schema-shaped result.
4. Run `ingest` with the result path.
5. Continue until the control plane reports the next author or review action.

The parent records truthful capability evidence. Behavioral claims are allowed,
but unavailable freshness or read-only isolation produces a degraded-capability
verdict. This supports Google models outside Gemini CLI, Copilot, Cursor modes
without the Agent CLI, future hosts, and private agent frameworks without
duplicating the review algorithm.

## Repository-Grounded Read-Only Probes

Attackers may run bounded, side-effect-free inspection commands when necessary
to verify document claims. Examples include version/help output, file existence,
Git status and metadata, static config parsing, and repository-provided dry-run
commands explicitly documented as read-only.

Builds, tests, formatters, package installation, migrations, application
commands with unknown effects, and implementation edits remain prohibited.
Adapters enforce the narrowest available tool surface; the role prompt repeats
the behavioral boundary.

## Reports And Provenance

Every report run begins with:

- Run ID and schema version.
- Target paths, digests, repository HEAD, and timestamp.
- Tier, mode, and output destination.
- Executor, CLI version, requested and observed model/effort.
- Enabled, combined, skipped, and retried angles with reasons.
- Capability statuses and degraded-capability disclosures.
- Token/usage metrics when the host exposes them.

Promoted IDs are deterministic within a run after semantic grouping:

```text
AR-<run-short-id>-001
```

Re-review appends a compact run section with a new run ID, so IDs never collide.
The findings table retains source angles and confidence in machine state. The
human Markdown table may omit confidence when space is constrained, but it
must retain a source column and stable ID.

Report files are rendered atomically. Chat output is derived from the same
`summary.json`, preventing chat/file drift.

## Proposed Package Shape

```text
skills/general/adversarial-review/
  SKILL.md
  attack-angles.md
  judge-rubric.md
  platform-adapters.md
  agents/codex/*.toml
  assets/schemas/
    attack.json
    divergence.json
    dedupe.json
    judge.json
    author-actions.json
    resolution.json
    arbiter.json
  scripts/
    adversarial-review
    lib/adversarial_review/
      manifest.rb
      state.rb
      schemas.rb
      prompts.rb
      reporting.rb
      runner.rb
      adapters/
        codex.rb
        claude.rb
        cursor.rb
        gemini.rb
        generic.rb
```

Files remain responsibility-focused. The existing Markdown files continue as
the human-readable source of role behavior; prompt assembly extracts named
sections rather than duplicating their prose inside Ruby constants.

## Testing Strategy

Use test-driven development and add a dedicated adversarial-review test suite.
Tests use temporary Git repositories and fake vendor executables; they do not
consume model tokens.

Contract coverage includes:

- Spec-only, plan-only, and spec-plus-plan angle routing.
- Compatibility aliases and output-write policy.
- Manifest hashes, metrics, and applicable guidance capture.
- Schema acceptance and rejection for every role.
- Immutable candidate IDs and candidate-to-group traceability.
- `promoted`, `refuted`, and `unproven` judge outcomes.
- Confidence floor, severity ordering, cap, and overflow.
- Round-two new-finding transitions and arbiter mappings.
- Locking, atomic state replacement, interruption, and resume.
- Report ID uniqueness, Markdown escaping, atomic append, and chat/file parity.
- Capability-probe success, failure, and generic fallback.
- Exact argv/stdin/output parsing for Codex, Claude, Cursor, and Gemini fakes.
- Runtime model/effort mismatch and missing terminal-event failures.
- One schema-repair attempt and no low-finding-count retry.
- Token/usage extraction when an adapter exposes it.
- Reviewed-document prompt-injection text remaining inert.

Repository verification adds Ruby syntax for the new scripts and libraries,
JSON-Schema fixture validation, the dedicated tests, the existing model-tier
contract tests, and the normal `scripts/verify` gate.

## Migration And Documentation

The implementation updates `SKILL.md`, the three reference documents,
`USAGE.md`, `CATALOG.md`, and `skills.yaml` together where their public contract
changes. The recommended model tiers remain unchanged unless measurement shows
the control plane materially changes expected review cost.

No global skill symlinks or named-agent files are changed without explicit user
approval. Sync verification uses dry-run for Codex, Claude, and Gemini after the
package changes.

## Acceptance Criteria

1. The same manifest, schemas, state machine, and report renderer serve every
   executor.
2. Codex, Claude, Cursor, and Gemini adapters implement the shared capability
   contract without changing review semantics.
3. Generic mode can complete a fixture review through task emission and result
   ingestion without vendor-specific code.
4. Every direct adapter either proves its required capabilities or falls back
   without silently weakening the tier.
5. Deterministic bookkeeping and malformed-output handling require no model
   judgment.
6. Existing invocation examples remain behaviorally compatible, with explicit
   chat/file output controls added.
7. Fake-executable adapter tests and the full repository verification suite pass.
8. A report-only A/B evaluation records token usage where available and confirms
   that the scripted workflow does not lose previously promoted blocker-class
   findings on the selected fixtures.
