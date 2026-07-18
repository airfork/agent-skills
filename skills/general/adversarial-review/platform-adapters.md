# Platform Adapters

Use one portable task/result contract on every host. Adapter eligibility is a
runtime fact, not a claim based on a CLI name or help text. The control plane never silently downgrades model, effort, tier, or vendor.

## Shared Gate

A direct adapter may run only when a pinned executable and machine-readable runtime attestation
prove the requested tier, exact requested and observed model and effort,
fresh context, canonical repository, read-only policy, structured
output, session binding, and required vote independence. Record all eight
capabilities: `fresh_context`, `repository_access`, `read_only`,
`model_selection`, `effort_selection`, `structured_output`, `usage_metrics`, and
`parallel_dispatch`. A failed or missing observation selects Generic Adapter
with a degraded capability record; it never becomes an ordinary direct result.

Direct execution currently rejects `--jobs` greater than 1. Generic execution
emits independent task bundles so the parent host can schedule safe parallel
work. `--ultra` is Claude-only for direct execution. On any non-Claude host,
`--executor auto --tier ultra` selects generic; it never silently runs `high`.

## Generic Adapter

Treat generic mode as the portable baseline and first-class fallback. It emits
immutable JSON task bundles plus a capability-declaration template. Run each
bundle in a fresh read-only context, return the closed schema result, declare
capabilities with evidence, then use `ingest`. The control plane verifies task
identity, current target digests, capability evidence, and state transitions.
Generic mode can preserve full review semantics even when a host cannot expose
direct CLI telemetry; disclose missing runtime or token observations.

## Codex Adapter

On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier; direct execution still requires the exact requested model and effort to match runtime evidence.
Direct Codex requires `codex exec` support for ephemeral, ignored user config,
strict config, read-only sandbox, explicit model/effort, repository directory,
JSON events, output schema, and a bound final response. Runtime events must
confirm all shared-gate claims. Codex `0.144.5` was observed during design, but
its real runtime contract was not verified for this package, so it currently
falls back to generic. A future version may run direct only after machine
attestation passes; the version note is not a pin or allowlist.

## Claude Adapter

Direct Claude requires print mode, plan permission, a read/search-only tool
allowlist, explicit model/effort, JSON schema output, fresh session identity,
usage, and independent-vote evidence. Claude `2.1.212` was observed without
attested effort, fresh context, or independent voting, so it currently falls
back to generic. A future compatible version may pass the runtime gate. Direct
Claude alone may run `ultra`, using three independent evidence-bearing votes;
split votes involving `UNPROVEN` require arbitration.

## Cursor Adapter

Direct Cursor requires print mode, ask/read-only mode, enabled sandbox, explicit
workspace/model/effort, stream JSON, fresh session identity, and matching
terminal attestation. Cursor `2026.07.16-899851b` was observed without usable
effort and runtime attestation, so it currently falls back to generic. Future
versions may run direct only when their events satisfy the shared gate.

## Gemini Adapter

Direct Gemini requires an isolated ephemeral agent configuration, sandbox,
read/search-only tools, explicit workspace/model/effort, JSON output, fresh
session binding, and usage telemetry. Gemini was absent from the design host, so
no installed version is eligible there and execution falls back to generic.
Future versions may run direct only after machine attestation passes.

## Security Boundary

The control plane protects against untrusted documents and model output,
accidental or concurrent writers, symlink/path swaps, and crash recovery within
its scoped filesystem controls. It cannot defend against a malicious same-UID local administrator
replacing arbitrary run ancestors or the whole run tree.
Do not describe the reviewer as a security sandbox beyond the capabilities its
runtime attestation proves.

Direct children receive locale variables plus only the adapter credential
allowlist: Codex `OPENAI_API_KEY|CODEX_API_KEY`; Claude
`ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN`; Cursor
`CURSOR_API_KEY`; Gemini
`GEMINI_API_KEY|GOOGLE_API_KEY|GOOGLE_GENAI_USE_VERTEXAI|GOOGLE_CLOUD_PROJECT|GOOGLE_CLOUD_LOCATION`.
A permitted credential remains visible to that child and descendants it starts;
the allowlist limits forwarding but is not credential isolation.

## Install

The same skill folder installs to Codex, Claude, Cursor, and Gemini. Installation
is separate from review execution and never occurs as a side effect:

```bash
scripts/sync-skills --target codex --dry-run
scripts/sync-skills --target claude --dry-run
scripts/sync-skills --target cursor --dry-run
scripts/sync-skills --target gemini --dry-run
```

Use `--apply` only when the user explicitly requests global symlink changes.
Codex named-agent TOMLs are optional setup and are never copied by the control
plane or sync script.
