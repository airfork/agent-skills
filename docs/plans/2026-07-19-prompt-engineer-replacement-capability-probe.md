# Prompt Engineer Replacement Capability Probe

**Date:** 2026-07-19  
**Status:** `PARTIAL`

Task 1 captured the local capability surface in the retained external evidence
root `/Users/tunji/.codex/prompt-engineer-replacement-evidence/task0`, indexed by
the read-only `MANIFEST.json`. The manifest is the immutable index root; its own
digest is supplied by the parent evidence-retention system.

The four bound planning artifacts matched their committed SHA-256 digests before
the worktree was created. Exact command argv, exit statuses, byte counts, and
stdout/stderr digests are recorded at `probe-commands.json#/commands`. Codex and
Claude help probes exited successfully and showed the intended JSON/event and
bare-auth syntax. The sandbox help probe returned exit 64 because this macOS
build accepts only `-f`, `-n`, or `-p`.

The legacy arm is blocked because `PROMPT_ENGINEER_LEGACY_ROOT` was absent, so no
unpinned installed copy was substituted. Live host probes were not run because
`PROMPT_ENGINEER_MAX_USD` was absent; Claude bare authentication was therefore
not tested. Native export pointers, provider-only transport, parent-only auth,
and isolated-home attestations are unproven for both hosts. Ruby 4.0.5 is
installed; the Ruby 2.6.10 compatibility gate remains unproven and the cutover
primitive gate is deferred to its focused tests.

## Component decisions

| Component | Decision | Consequence |
|---|---|---|
| Legacy snapshot | `BLOCKED` | No legacy evaluation arm or live baseline claim |
| Codex native export | `BLOCKED` | Host-neutral evaluator may proceed; no live Codex qualification |
| Claude native export | `BLOCKED` | Host-neutral evaluator may proceed; no live Claude qualification |
| Codex staged-root read/write | `UNPROVEN` | Fake-adapter contract tests only; `codex/sandbox-probes.json#/status` |
| Claude staged-root read/write | `UNPROVEN` | Fake-adapter contract tests only; `claude/sandbox-probes.json#/status` |
| Credential/keychain isolation | `UNPROVEN` | No live parent-auth run; `decision.json#/components/claude_native_export` |
| Provider-only network | `UNPROVEN` | No live transport attestation; `decision.json#/components/codex_native_export` |
| Result-sink/descriptor isolation | `UNPROVEN` | Boundary spike not run; sandbox adapter remains unsupported |
| Frozen-input rehash | `UNPROVEN` | No post-run host record; normalizers remain unsupported |
| Ruby 2.6.10 compatibility | `BLOCKED` | Host has Ruby 4.0.5; Ruby-dependent compatibility cannot be claimed |
| Descriptor-relative filesystem | `BLOCKED_PENDING_PROBE` | Cutover must fail closed until focused probes pass |

The exact local executable provenance is retained in `environment.json` and the
host export records. No raw model session or credential-bearing output is
retained.

This record permits the baseline, runtime package, corpus, closed contracts,
fake adapters, and host-neutral evaluation state machine. It does not authorize
live model execution, global installation, or cutover.

## Evidence pointers

The following pointers are integrity-bound by the retained `MANIFEST.json`; each
listed digest is rechecked before a dependent component uses the evidence.

| Claim | Artifact and JSON pointer | SHA-256 |
|---|---|---|
| Exact command argv, exits, and output digests | `probe-commands.json#/commands` | `a62946098d7da35a7005ac5a8e517182616eb1dfcd1c7a5f2b5712ea474d05ae` |
| Environment, Ruby, and missing operator inputs | `environment.json#/` | `20be697a5b2b5c591afde3a3dccf1a74d6bc04de6dbc5a1e231569184a99742c` |
| Legacy-arm gate | `legacy-snapshot.json#/` | `59c0f79534c0d06292bb2ff1649493b696620fdb0e4842660f9e06a00d0c5813` |
| Codex export gate | `codex/export-capabilities.json#/` | `2912ad89e4b33261e032f5f10380ea98b3f2e9f7378f2f68997c4407efd98` |
| Claude export gate | `claude/export-capabilities.json#/` | `6ca71a57a6e5540e7dd3ef55081d46cbf8bf33f40091e7b694093f95765ed30b` |
| Codex sandbox gate | `codex/sandbox-probes.json#/` | `1ca5a9ce458ae713a020aac8226435b31ebd5b42e044c028ae9de4d8d15bcade` |
| Claude sandbox gate | `claude/sandbox-probes.json#/` | `2873fbfd082ce77a225400fa6ce4855e42a3a165e48ad95d7dc5bcae504dd737` |
| Filesystem and cutover gate | `filesystem-capabilities.json#/` | `9f38a7dd42ff9164fbebcc90665410faaaf070c48b5507359f03119e3b3a6874` |
| Combined component decision | `decision.json#/` | `c7d33e6d8fda2634009d1efa18ad270b20ebb9cde5458f05d69f62598f37d3cb` |

The retained raw-unassisted and raw-explicit JSONL files are explicit blocked-run
markers, not provider transcripts. Their digests are listed in `MANIFEST.json`.
