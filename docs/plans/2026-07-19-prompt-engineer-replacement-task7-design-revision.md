# Prompt Engineer Replacement Task 7 Design Revision

**Date:** 2026-07-19  
**Status:** `PARTIAL — NATIVE ADAPTERS UNSUPPORTED`

## Entry-gate outcome

Task 7's entry gate is not satisfied for either required host. Task 1 did not
retain a real native export with the required freshness, session, discovery,
activation, invocation, and usage pointers. The retained records explicitly
mark both exports `UNPROVEN`, with `required_event_pointers: "absent"` and
`qualification_capable: false`.

Therefore this revision does **not** add
`scripts/lib/prompt_engineer/normalizers/codex.rb` or
`scripts/lib/prompt_engineer/normalizers/claude.rb`, native-export fixtures, or
live host launch code. Codex and Claude are not represented as supported, and
no live qualification or repository-complete claim is permitted.

## Host-neutral boundary

The implementation adds only a host-neutral boundary:

- `PromptEngineer::Capabilities.report` reports the closed Codex/Claude host
  set as `unsupported` and binds each status to the retained evidence artifact,
  JSON pointer, and SHA-256.
- `PromptEngineer::Capabilities.for(host)` rejects unknown hosts rather than
  selecting a generic or unproven adapter.
- `PromptEngineer::Normalizers.for(host)` returns an unsupported adapter whose
  `normalize` operation raises `UnsupportedError` before reading export input.

This preserves the host-neutral evaluation core and makes the missing native
evidence visible to later CLI/reporting work without creating a false support
surface. A future normalizer may be added only after a new capability record
provides the required native export and all of its integrity-bound pointers.

## Evidence references

The immutable evidence root is:

`/Users/tunji/.codex/prompt-engineer-replacement-evidence/task0`

These references were rehashed locally before this note was written:

| Claim | Exact artifact and JSON pointer | SHA-256 |
|---|---|---|
| Codex native-export gate | `codex/export-capabilities.json#/` | `2912ad89e4b33261e032f5f10380ea98b3f2e9f7378f2f68983897c4407efd98` |
| Claude native-export gate | `claude/export-capabilities.json#/` | `6ca71a57a6e5540e7dd3ef55081d46cbf8bf33f40091e7b694093f95765ed30b` |
| Combined Task 1 decision | `decision.json#/` | `98efbe4f384d0141324cf55565a53a28c00c5b8f8e4d94223f0995e95d764d35` |
| Probe command and output index | `probe-commands.json#/commands` | `a62946098d7da35a7005ac5a8e517182616eb1dfcd1c7a5f2b5712ea474d05ae` |

The Codex digest above is the digest of the retained file bytes. The earlier
capability-probe table contains a 61-character Codex value; it is not used by
the boundary or this qualification note.

## Qualification consequence

The permitted state remains limited to the baseline record, runtime package,
corpus, canonical contracts, host-neutral evaluation state machine, and fake
adapter tests. Native Codex and Claude execution, native-export normalization,
live qualification, global installation, and cutover remain blocked.
