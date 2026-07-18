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
`parallel_dispatch`. A failed or missing observation returns an ineligible generic-shaped adapter result; the adapter itself never emits Generic bundles.

Use `DEGRADED CAPABILITIES` when any required capability is `unavailable` or a
required safety boundary (`fresh_context`, `repository_access`, or `read_only`)
is only `behavioral`. It replaces only an ordinary `PASSED`. `REPORT ONLY`,
`PASSED WITH OPEN QUESTIONS`, and `DID NOT CONVERGE` keep their verdict.
Retained verdicts disclose degraded capabilities separately.

The public CLI records serial dispatch truthfully with `parallel_dispatch` as `unavailable`.
For default/high direct Codex and Claude runs, parallelism is
advisory rather than a hard eligibility field: all other safety and identity
capabilities must pass, and the final report still discloses degraded parallel
telemetry. Ultra keeps parallel dispatch as a hard requirement. Cursor and
Gemini remain direct-ineligible until their real runtime contracts are verified.
Generic bundles are the portable path for host-native parallelism.

The runner verifies and digests the selected executable outside the reviewed
repository, run directory, and isolated configuration roots immediately before
spawn. Portable Ruby cannot bind `exec` to that verified descriptor on every
supported POSIX host, so direct mode assumes the trusted CLI installation is
not concurrently replaced by another same-UID process during the final
verify-to-spawn window. Use Generic handoffs when that local trust boundary is
not acceptable.

Automatic generic fallback is available only for `--executor auto`, and only
before reviewed content. Its authorization is fixed before any external attempt,
while the durable selection intent records zero external attempts. A private eligibility probe may then be
the first external call; its pre-content failure completes that already-authorized
fallback. No second attempt may switch vendor. Explicit direct selection never falls back.
Capability or eligibility failure stops with exit `4`; execution or invalid
result failure stops with exit `5`. After reviewed content, either class stops
without fallback. The run remains resumable and the selected executor remains pinned.

Only the public CLI with `--executor auto`, at the pre-content boundary with
zero prior external attempts, converts an ineligible result to emitted Generic bundles.
Explicit direct selection stops with exit `4` or `5`, remains pinned and
resumable, and never converts the result to Generic bundles.

The parser rejects direct `--jobs` greater than 1. Generic execution emits
independent task bundles. `--ultra` is Claude-only for direct execution. On any non-Claude host,
the qualifying public `--executor auto --tier ultra` boundary emits Generic
bundles; explicit non-Claude ultra stops with exit `4` and never runs `high`.

## Generic Adapter

Treat generic mode as the portable baseline and first-class fallback. It emits
immutable JSON task bundles plus a capability-declaration template. Run each
bundle in a fresh read-only context, return the closed schema result, declare
capabilities with evidence, then use `ingest`. The control plane verifies task
identity, current target digests, capability evidence, and state transitions.
Generic mode can preserve full review semantics even when a host cannot expose
direct CLI telemetry; disclose missing runtime or token observations.

`pending_task_handoffs` is the normative dispatch surface. Its trusted
`task_sha256` is computed from the exact task bytes while State holds its lock.
`pending_tasks` is a compatibility path inventory, not a dispatch authorization.
Read the task bytes exactly once, verify `task_sha256` before parsing JSON and
before using task-controlled cwd, schema, or prompt fields. Reject a mismatch as
`task_digest_mismatch`; never take the expected digest from the task file.

After authentication, require the parsed `repository_root`, `schema_path`, and
`schema_sha256` to equal the trusted handoff metadata. The schema must stay under
the installed skill root: read it once, verify its digest, then parse and use
those same bytes. Use the returned in-memory task and schema; do not reopen their
paths for dispatch. Start the worker with its working directory set to `repository_root`.
Within that authenticated read, verify `schema_sha256` before using `schema_path`.
Do not resolve the schema relative to the reviewed repository.
Return every and only authoritative `required_checks` in `checks_completed`;
the control plane permits one durable repair, then fails closed.

## Codex Adapter

On Codex, the explicitly selected parent GPT-5.6 model is acceptable at every tier; direct execution still requires the exact requested model and effort to match runtime evidence.
Direct Codex requires `codex exec` support for ephemeral, ignored user config,
strict config, read-only sandbox, explicit model/effort, repository directory,
JSON events, output schema, and a bound final response. Runtime events must
confirm all shared-gate claims. Codex `0.144.5` was observed during design, but
its real runtime contract was not verified for this package, so its direct result is currently ineligible and generic-shaped. The adapter does not emit Generic bundles; only the qualifying public auto boundary converts it. A future version can become direct-eligible only after machine attestation and caller dispatch evidence pass; the version note is not a pin.

## Claude Adapter

Direct Claude requires print mode, plan permission, a read/search-only tool
allowlist, explicit model/effort, JSON schema output, fresh session identity,
usage, and independent-vote evidence. Claude `2.1.212` was observed without
attested effort, fresh context, or independent voting, so its direct result is ineligible and generic-shaped. The adapter does not emit Generic bundles; only the qualifying public auto boundary converts it. A future version can become direct-eligible only after machine attestation and caller dispatch evidence pass. Direct
Claude alone may run `ultra`, using three independent evidence-bearing votes;
split votes involving `UNPROVEN` require arbitration.

## Cursor Adapter

Direct Cursor requires print mode, ask/read-only mode, enabled sandbox, explicit
workspace/model/effort, stream JSON, fresh session identity, and matching
terminal attestation. Cursor `2026.07.16-899851b` was observed without usable
effort and runtime attestation, so its direct result is ineligible and generic-shaped. The adapter does not emit Generic bundles; only the qualifying public auto boundary converts it. A future version can become direct-eligible only after machine attestation and caller dispatch evidence pass.

## Gemini Adapter

Direct Gemini requires an isolated ephemeral agent configuration, sandbox,
read/search-only tools, explicit workspace/model/effort, JSON output, fresh
session binding, and usage telemetry. Gemini was absent from the design host, so
its direct result is ineligible and generic-shaped there. The adapter does not
emit Generic bundles; only the qualifying public auto boundary converts it. A
future version can become direct-eligible only after machine attestation and
caller dispatch evidence pass.

## Security Boundary

The control plane protects against untrusted documents and model output,
accidental or concurrent writers, symlink/path swaps, and crash recovery within
its scoped filesystem controls. It cannot defend against a malicious same-UID local administrator
replacing arbitrary run ancestors or the whole run tree.
Do not describe the reviewer as a security sandbox beyond the capabilities its
runtime attestation proves.

Direct children receive locale variables, explicit proxy variables, validated
external `SSL_CERT_FILE`/`SSL_CERT_DIR` paths, plus only the adapter credential
allowlist: Codex `OPENAI_API_KEY|CODEX_API_KEY`; Claude
`ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN`; Cursor
`CURSOR_API_KEY`; Gemini
`GEMINI_API_KEY|GOOGLE_API_KEY|GOOGLE_GENAI_USE_VERTEXAI|GOOGLE_CLOUD_PROJECT|GOOGLE_CLOUD_LOCATION`.
Gemini may additionally receive a validated external
`GOOGLE_APPLICATION_CREDENTIALS` path or an isolated copy of the current gcloud
ADC file.
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
