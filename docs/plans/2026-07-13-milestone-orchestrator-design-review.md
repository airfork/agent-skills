# Milestone Orchestrator Design — Adversarial Review

**Date:** 2026-07-13  
**Target:** `docs/plans/2026-07-13-milestone-orchestrator-design.md`  
**Tier:** `adversarial-review --high`  
**Verdict:** PASS  
**Open CRITICAL/HIGH findings:** 0

## Tier rationale

The design is architecture-shaping, cross-host, externally mutating, and intended
to supervise long unattended runs. `--high` was selected to add an arbiter-capable
cull and a divergence probe while keeping the review bounded to two rounds. All
reviewers ran in fresh read-only GPT-5.6 Sol contexts with xhigh reasoning.

## Review metrics

| Stage | Result |
|---|---|
| Round 1 attackers | 9: implementer, tester, operator, assumptions, pre-mortem, consistency, and 3 divergence outlines |
| Round 1 cull | 19 promoted: 6 CRITICAL, 10 HIGH, 2 MEDIUM, 1 LOW; 1 duplicate merged |
| Round 1 resolution | 17 resolved initially; 2 revised and then resolved |
| Round 2 fresh sweep | 14 candidates from 2 independent attackers |
| Round 2 cull | 12 promoted: 9 HIGH, 3 MEDIUM; 2 rejected |
| Final resolution | 12 of 12 promoted round-2 findings resolved |
| Final blocker count | 0 CRITICAL, 0 HIGH |

## Resolved findings

| ID | Severity | Finding | Resolution |
|---|---|---|---|
| AR-001 | CRITICAL | Runtime-global Orca identity was not fenced | Added run UUID/root allowlist, per-attempt task/dispatch identity, epochs, and foreign-state exclusion |
| AR-002 | CRITICAL | Git/worktree isolation was not executable | Added clean integration worktree, verified immutable bases, dirty-state classification, safe staging, and non-force CAS-style push |
| AR-003 | CRITICAL | No cancellation or authority-revocation lifecycle | Added abort states, epoch revocation, bounded worker shutdown, preservation, quarantine, and resumable reporting |
| AR-004 | CRITICAL | Fixture could mutate real runtime or forge state | Added run-owned fixture namespace, no global reset, foreign-state assertions, bare remote, and action-recording forge |
| AR-005 | CRITICAL | Authenticated browser evidence could leak secrets | Added minimization, redaction, git-ignored transient captures, retention/deletion, and outgoing-object scanning |
| AR-006 | CRITICAL | Publication was not bound to exact external identities | Added forge/remote/base/head/PR identity, expected OID, idempotence, force-push prohibition, and separate ready/notification flags |
| AR-007 | HIGH | Orca completion was conflated with semantic completion | Split dispatch attempts from durable stages and routed semantic readiness through coordinator gates |
| AR-008 | HIGH | Approval preceded the implementation plan and checkpoint | Moved final approval after reviewed SPEC and PLAN; added exact contract checkpoint before isolated dispatch |
| AR-009 | HIGH | STATE and acceptance evidence lacked a canonical schema | Added a versioned machine-readable block, invariants, freshness, stable IDs, sole transition ownership, and immutable/mutable acceptance split |
| AR-010 | HIGH | Cleanup used restart-scoped handles and mutable tab indexes | Added creation inventories, stable provenance, handle reconciliation, page-ID remapping, identity verification, and conservative retention |
| AR-011 | HIGH | CI/review/replan/no-progress and closeout were unbounded | Added concrete default budgets, exhaustion states, canonical closeout fields, and closure invariants |
| AR-012 | HIGH | Native adapters were not validated end to end | Added real Codex and Claude conformance scenarios with host-correct code-review evidence |
| AR-013 | HIGH | Manager-only behavior was not enforceable | Added read-only coordinator paths, fenced control writes, adapter probes, attribution fallback, and block-on-no-control |
| AR-014 | HIGH | Recovery promises lacked fault injection | Added a deterministic fault matrix covering lifecycle, identity, dirty state, conflicts, cleanup, CI, and cancellation |
| AR-015 | HIGH | Required host/review workflows lacked compatibility gates | Added host/workflow version probes, compatibility decisions, safe fallback, and publication blocking |
| AR-016 | HIGH | Blanket repository precedence was unsafe | Added field-specific sources of truth for Git, verification, review, runtime, forge, authority, and resources |
| AR-017 | MEDIUM | Logical model routes were not executable host contracts | Added exact launchers, model/effort identity, probes, substitutions, and protected-route downgrade rules |
| AR-018 | MEDIUM | Baseline pressure testing was stochastic and underspecified | Added versioned repeated trials, machine assertions, frozen metrics, confidence handling, and safety zero-tolerance cases |
| AR-019 | LOW | Support doc placement violated repository structure | Moved the proposed adapter document under `references/` |
| R2-01 | HIGH | Review/verification worker tasks could still release dependencies | Required all semantic edges to use coordinator-adjudicated gates and fresh host tasks after terminal attempts |
| R2-02 | HIGH | Coordinator lease had no atomic/fencing protocol | Added exclusive acquisition, owner/run/epoch/token, renewal, expiry, takeover, and pre-mutation validation |
| R2-03 | HIGH | Unscoped `run-stop` could halt foreign work | Forbade it without proven runtime exclusivity and defined allowlisted manual cancellation |
| R2-04 | MEDIUM | Enforcement topology was still abstract | Added four capability roles and adapter-specific prevention/detection probes with block-on-unavailable behavior |
| R2-05 | MEDIUM | Integration worker conflicted with sole STATE ownership | Limited it to immutable evidence; coordinator adjudicates and fenced writer records the transition |
| R2-06 | HIGH | Native cancellation/resource lifecycle lacked parity | Added native allowlisting, termination, preservation, cleanup, restart, retention, and fault-test contracts |
| R2-07 | HIGH | Ordinary workers could bypass external authority | Added a constrained external-action executor and removed publication/deploy/cleanup credentials from ordinary roles |
| R2-08 | HIGH | Push/PR actions could indirectly merge or deploy | Added derived workflow/deploy/merge-automation/bot/notification inventory and blocking |
| R2-09 | HIGH | Revocation lacked an atomic external-action fence | Added epoch checks immediately before submission, action-lease invalidation, in-flight inventory, and capability quarantine |
| R2-12 | HIGH | Secret scanning could miss removed-but-outgoing objects | Required exact outgoing history, blob, LFS, control-doc, and artifact coverage with fail-closed reporting |
| R2-13 | HIGH | Local-commit opt-out contradicted mandatory checkpointing | Added a restricted serialized no-commit/no-publication mode or clean RUN blocker |
| R2-14 | MEDIUM | Evaluation thresholds could be selected after results | Required a pre-registered versioned protocol and zero-tolerance safety assertions |

## Material design changes

- Final approval now covers both reviewed design and plan plus the full authority
  envelope, rather than approving the design before the plan exists.
- Orca runtime completion, durable task progress, and orthogonal failure/resource
  conditions are separate state dimensions.
- A lease-fenced capability architecture now separates coordination, control
  writes, independent verification, and external mutations.
- Automatic commit, push, and draft PR remain the default, but are bound to an
  exact publication envelope and derived automation effects. Merge and deploy
  remain unavailable.
- Cleanup now relies on creation provenance and stable identity, not stale
  terminal handles or tab indexes.
- Initial testing remains production-repo independent: deterministic validators,
  a disposable repository/remote/forge fixture, Orca E2E, and native conformance
  precede one bounded real-repository pilot.

## Rejected or narrowed findings

| Candidate | Disposition | Rationale |
|---|---|---|
| Reverse automatic publication to opt-in | Rejected | The user explicitly chose automatic commit/push/draft PR unless disabled; the design instead made that opt-out authority exact and auditable |
| Require final whole-branch review before the first draft PR push | Rejected | The fixed requirement is review before merge options; draft publication may precede it and later remediation updates the same PR |
| R2-10 require a disposable isolated Orca home for all lifecycle tests | Rejected | No supported isolation primitive was established; the design uses run allowlists, exact identity, no global reset, and foreign-resource invariance while allowing read-only shared-runtime observation |
| R2-11 require an additional cryptographic attestation system | Rejected as duplicate/overreach | Independent clean-SHA verification and immutable verifier records already prevent implementer reports from releasing acceptance gates; implementation may strengthen this without changing the design |

## Open questions

No review blocker remains. The only intentionally deferred choice is the first
bounded real-repository pilot, selected after the disposable fixture passes.
