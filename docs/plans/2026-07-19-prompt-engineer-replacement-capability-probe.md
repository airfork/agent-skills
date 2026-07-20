# Prompt Engineer Replacement Capability Probe

**Date:** 2026-07-19  
**Status:** `PARTIAL`

Task 1 captured the local capability surface in the retained external evidence
root `/Users/tunji/.codex/prompt-engineer-replacement-evidence/task0`.

The four bound planning artifacts matched their committed SHA-256 digests before
the worktree was created. Codex and Claude help probes exited successfully and
showed the intended JSON/event and bare-auth syntax. The sandbox help probe
returned exit 64 because this macOS build accepts only `-f`, `-n`, or `-p`.

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
| Sandbox/auth boundaries | `UNPROVEN` | Fake-adapter contract tests only |
| Descriptor-relative filesystem | `BLOCKED_PENDING_PROBE` | Cutover must fail closed until focused probes pass |

This record permits the baseline, runtime package, corpus, closed contracts,
fake adapters, and host-neutral evaluation state machine. It does not authorize
live model execution, global installation, or cutover.
