# Prompt Engineer Replacement Design — Verification Record

**Date:** 2026-07-19  
**Design SHA-256:** `1aa65edd7c3fef5af95f620d5c1a9203b82a169aabdf71f2ed69e0c47d78af9b`  
**Status:** User-approved direction; planning verification complete; implementation not started

## Formal design review

Run `ar-20260719T211137050093Z-6c208c27` reviewed the design through two
revision rounds. It reported 21 findings and records every one as resolved. Its
generated lifecycle verdict remains `DID NOT CONVERGE` because the second-round
revisions exhausted the two-round cap before another fresh sweep could run.
Exact model, effort, usage, and later reviewer-freshness attestations were
unavailable, so the record retains `DEGRADED CAPABILITIES`; it is not represented
as a clean formal pass.

## Implementation-plan amendments

The later implementation-plan review exposed additional design-level gaps. The
design now also specifies:

- a closed operator-choices producer and qualification-policy builder;
- a single-writer ledger with authenticated lease events and bounded conditional
  work;
- one judge for every complete packet and a second only for near-boundary
  packets, with a maximum reserve of 64 judge sessions;
- the same fail-closed sandbox and native attestation path for executor and judge
  sessions;
- explicit discovery roots, a canonical composite preview, and exact qualified
  commit and package-byte binding;
- distinct pre-activation and post-activation rollback forms; and
- a durable activation-attempt event that supports authenticated rollback even
  when activation validation fails.

The frozen implementation-plan critique and the resolution evidence are recorded
in:

- `docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan-review.md`
- `docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan-verification.md`

## Budget reconciliation

- Behavioral: `72 initial + 18 stability + 6 targeted = 96` sessions maximum.
- Trigger: `16 explicit + 16 Codex implicit + 8 Claude negative = 40` sessions.
- Judge: up to `32` first judges plus up to `32` policy-triggered second judges,
  with unused conditional reserve left unspent.

## Final supplemental result

Three repository-aware read-only audits checked the amended design and
implementation plan. Their findings were resolved and rechecked; the final
passes reported no remaining CRITICAL or HIGH issue. The implementation-plan
verification record preserves the exact resolutions, capability limitations,
artifact digests, and repository gate results.

## Scope

This record verifies the approved planning direction and its documented review
history. It does not claim that the replacement has been implemented, qualified,
installed, or cut over. No install metadata, global skill links, or live legacy
installation is changed by these planning documents.
