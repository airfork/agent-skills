# Milestone Orchestrator Implementation Plan Adversarial Review

**Date:** 2026-07-13  
**Targets:** `2026-07-13-milestone-orchestrator-design.md` and
`2026-07-13-milestone-orchestrator-implementation-plan.md`  
**Tier:** `adversarial-review --high`  
**Review model:** GPT-5.6 Sol with xhigh reasoning and fresh, read-only contexts

Reviewed artifact digests:

- Design SHA-256: `163da53532dbb9263d99e072f693d62499feafa55b799fac7c21af889aa8ce1d`
- Plan SHA-256: `415d68ed4f5e1be0cda41f587e09d088cda2db8dca1b66f8f6ff8dabc62aa96a`

## Verdict

**PASSED**

Two revise rounds completed. All 33 distinct promoted findings were resolved,
three candidates were rejected with rationale, three duplicate candidates were
merged into stronger findings, and the final fresh-context resolution check
returned `OPEN_COUNT=0`.

## Findings

| ID | Source | Category | Severity | Location | Summary | Resolution |
|---|---|---|---|---|---|---|
| AR-001 | P1 | Omission | Critical | External actions | Publication and cleanup had policy but no narrow executor boundary. | Added typed grants, a protected executor service, fixed operations, and postcondition audit. |
| AR-002 | P2 | Ambiguity | High | STATE control | Compare-and-swap, canonical paths, and transition serialization were underspecified. | Added locked canonical-path CAS and validator-backed atomic transition steps. |
| AR-003 | P3 | Omission | Critical | Coordinator lease | Lease takeover and stale-owner fencing were incomplete. | Added liveness-bound lease acquire/renew/takeover/release, epoch advance, and stale-token tests. |
| AR-004 | P4 | Omission | High | Task 0 | Capability probes could mutate resources without sufficiently safe ownership proof. | Added unique probe namespaces, before/after inventories, stable IDs, and fail-closed cleanup. |
| AR-005 | P5 | Ambiguity | High | Evidence freshness | Verification was not tied to a stable implementation subject. | Added object-format-aware implementation subjects and exact-subject freshness rules. |
| AR-006 | P6 | Omission | High | No-commit mode | A commit opt-out conflicted with isolated worktree execution. | Added an explicit restricted mode with serialized writer, immutable snapshot, and publication disabled. |
| AR-007 | P7 | Omission | High | Schema evolution | Unknown STATE versions failed closed without a future migration contract. | Added fenced, atomic, idempotent migration requirements for every supported prior version. |
| AR-008 | P9 | Omission | High | Replanning | Replan authority, evidence, and task carry-forward were incomplete. | Added digested plan-only replan records, drift review, budgets, and reapproval boundaries. |
| AR-009 | P10 | Ambiguity | Medium | Escalation | Budget exhaustion did not have a durable terminal disposition. | Added `escalated` phase and structured exhaustion evidence. |
| AR-010 | P11 | Omission | High | Host support | Adapter claims were not gated by non-skipped actual-host evidence. | Added required Orca/Codex/Claude conformance runs and support-claim blocking. |
| AR-011 | P12 | Omission | High | Pressure testing | The baseline and comparison protocol could drift after observing outcomes. | Moved baseline before implementation and froze hashes, repetitions, metrics, and zero-tolerance rules. |
| AR-012 | P13 | Omission | High | Fault validation | The fault inventory was prose rather than executable coverage. | Added a versioned, table-driven fault matrix with forbidden-effect assertions. |
| AR-013 | P14 | Omission | Critical | Verification | Implementers could effectively self-attest command results. | Added an independent exact-subject verifier and immutable evidence contract. |
| AR-014 | P15 | Omission | Critical | Outgoing data | Final-tree checks could miss deleted secrets, LFS content, captures, and metadata. | Added fail-closed outgoing object-range, metadata, LFS, artifact, and capture scanning. |
| AR-015 | P17 | Omission | Critical | Derived effects | Direct action approval did not prove all triggered automation was approved. | Added action/target effect inspection and effect-scoped authorization. |
| AR-016 | P18 | Inconsistency | High | Publication and CI | Publication, final review, remediation, and CI ordering could certify different heads. | Added draft-first exact-head review, rescan/republish loops, and final-head CI reconciliation. |
| AR-017 | P19 | Incorrect fact | Medium | Native adapters | `/goal` availability was assumed. | Made `/goal` capability-gated with an explicit coordinator-loop fallback or block. |
| AR-018 | P20 | Inconsistency | High | Repository registration | Skill creation and catalog/manifest updates were split across changes. | Moved initial registration into the same change as the skill entrypoint. |
| AR-019 | P21 | Inconsistency | Medium | Package layout | Design and plan listed different package contents. | Synchronized agents, references, scripts, libraries, and assets across both documents. |
| AR-020 | P22 | Ambiguity | Medium | Model metadata | Recommended execution cost was not frozen. | Set recommended tier `deep` and heavy tier `ultracode`. |
| AR-021 | P23 | Omission | High | Final staging | Final publication could omit generated review, pressure, or capability artifacts. | Added an explicit complete staging inventory and author/diff checks. |
| AR-022 | P24 | Omission | Critical | Fixture safety | The disposable fixture could reuse or escape a caller path. | Required a nonexistent output, marker, realpath containment, local bare remote, and no force/reuse. |
| AR-023 | P25 | Omission | High | Hermetic Git | Fixture commits could inherit user hooks, signing, identity, or configuration. | Added sanitized Git environment, fixed identity/dates, disabled hooks/signing, and explicit object format. |
| AR-024 | Q1 | Incorrect fact | Critical | Role isolation | Same-user mode-0600 files and tokens were not a real security boundary. | Added OS-enforced sandbox/container/distinct-principal profiles, protected service topology, active bypass tests, and adapter blocking. |
| AR-025 | Q2 | Ambiguity | High | Action grants | A generic grant could be interpreted differently by executors. | Added a closed, versioned discriminated union for all eight actions with exact fields, pre/postconditions, and idempotency. |
| AR-026 | Q3 | Omission | High | First push | A nullable remote OID could not distinguish absent branch from unknown state. | Added tagged `absent`/`present` expectations and base-to-head initial scanning. |
| AR-027 | Q4/Q5 | Inconsistency | High | PLAN verification | The verifier accepted caller argv before the canonical PLAN grammar existed. | Defined the PLAN registry before Task 0, made Task 2 its sole parser, and changed verification to command IDs. |
| AR-028 | Q6 | Inconsistency | High | Evidence finalization | Committing evidence about each push could create an endless scan/push/audit loop. | Added a protected digest-chained external ledger and one finite pre-publication control anchor per implementation cycle. |
| AR-029 | Q7 | Incorrect fact | Critical | Effect authority | Caller-provided effects were not authoritative. | Added `inspect-effects` using repository plus forge/Orca state and mandatory immediate freshness checks. |
| AR-030 | Q9 | Omission | Medium | Fake adapter | The fault matrix depended on an undefined fake lifecycle. | Added a deterministic virtual-clock adapter with typed stores, faults, snapshots, and mutation ledger. |
| AR-031 | Q10 | Inconsistency | High | Plan self-publication | The new executor could not authorize publication of its own implementation without initialized run artifacts. | Restricted executor dogfood to the fixture and used separately authorized existing publication workflow for this branch. |
| AR-032 | Q11 | Omission | High | Conformance parity | Actual-host tests covered fewer cases than the design promised. | Required one non-omittable shared matrix for every claimed adapter. |
| AR-033 | Q12/Q13 | Omission | High | Integration safety | A nonempty fixture path did not prove a safe, fresh, unused test target. | Added marker/schema/seed/containment/remote/commit/freshness checks and atomic run-namespace reservation before mutation. |

## Metrics

- Attack coverage: implementer, tester, operator, coverage, assumption,
  pre-mortem, consistency, feasibility, drift, and high-tier divergence probes.
- Round 1: 23 distinct promoted findings after cull; 6 critical, 13 high,
  and 4 medium. Four fresh judges performed the refute-or-promote cull.
- Round 2: 10 distinct promoted findings after cull; 2 critical, 7 high,
  and 1 medium. The coverage angle was retried once because its first run was
  abnormally long, as permitted by the skill.
- Resolution: 33 resolved, 3 rejected candidates, 3 merged duplicates, 0 open.
- Coverage mapping: 100% of reviewed design requirement groups have an explicit
  implementation task and verification or qualification gate.
- Placeholder count: 0 unresolved placeholders. Two documents mention placeholder
  words only as validation rules or literal search patterns.
- Design size: 841 lines / 5,961 words before plan review; 892 lines / 6,299 words
  after synchronization.
- Plan size: approximately 1,796 lines / 9,308 words before review; 2,075 lines /
  11,217 words after two revise rounds. Growth is explained by executable
  security boundaries, canonical schemas, and conformance tests rather than
  duplicated prose.

## Changelog

- Added canonical PLAN and STATE contracts, including command-ID verification,
  tagged remote expectations, evidence anchors, and closed action schemas.
- Added CAS/fencing, protected executor, role launcher, authoritative effect
  inspection, independent verification, outgoing scanning, and external ledger
  protocols.
- Added capability spike, frozen pressure baseline, deterministic fake adapter,
  executable fault matrix, safe fixture generator, and equal actual-host
  conformance gates.
- Clarified finite publication anchoring, exact-head review/CI loops,
  self-publication authority, cleanup, model metadata, registration timing, and
  complete final staging.
- Synchronized the reviewed design package layout and lifecycle semantics with
  the implementation plan.

## Rejected Findings

- **P8 — approval before initialized STATE:** Rejected. PREPARE intentionally
  obtains approval for the reviewed SPEC, PLAN, acceptance mapping, and authority
  envelope before creating execution state; initialization is a deterministic
  preflight step, not a new product or authority decision.
- **P16 — production repository required for initial qualification:** Rejected.
  The disposable fixture and actual-host conformance suite are the safe initial
  gate; the documents explicitly reserve broad production-readiness claims for
  a later bounded real-repository pilot.
- **Q8 — cull-only candidate:** Rejected because the judges did not establish a
  distinct defect above the confidence floor after comparison with the revised
  design and plan; no document change was warranted.

## Merged Findings

- P26 merged into AR-016 because both challenged publication/final-review/CI
  head ordering.
- Q5 merged into AR-027 because parser ordering and the canonical command
  registry were one root issue.
- Q13 merged into AR-033 because both challenged safe integration-fixture and
  run-namespace qualification before host mutation.

## Resolution Verification

A final fresh, read-only GPT-5.6 Sol xhigh judge read both documents in full and
checked only Q1-Q7 and Q9-Q12 against executable steps and tests. It marked all
eleven checked IDs `RESOLVED` and returned:

```text
OPEN_COUNT=0
```

## Open Questions

None.
