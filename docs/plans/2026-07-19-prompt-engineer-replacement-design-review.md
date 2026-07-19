<!-- adversarial-review-run:ar-20260719T211137050093Z-6c208c27:v1 -->
# Adversarial Review

DID NOT CONVERGE - lifecycle invariants remain unresolved

## Findings

| ID | Category | Severity | Location | Sources | Summary | Resolution |
|---|---|---|---|---|---|---|
| AR-d4cb4589-001 | Omission | CRITICAL | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:300 | assumptions-checker, implementer | Committed private rubrics have no enforceable withholding boundary. | resolved |
| AR-d4cb4589-002 | Omission | CRITICAL | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:504 | assumptions-checker | Temporary homes do not by themselves remove inherited credentials and external capabilities. | resolved |
| AR-d4cb4589-003 | Ambiguity | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:336 | assumptions-checker, implementer, tester | The generated-analysis-text efficiency gate is not observably defined. | resolved |
| AR-d4cb4589-004 | Inconsistency | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:362 | assumptions-checker, implementer, tester | Aggregate, per-case, and host-applicability release arithmetic is undefined. | resolved |
| AR-d4cb4589-005 | Omission | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:274 | implementer | The deterministic fixture and digest schema is unspecified. | resolved |
| AR-d4cb4589-006 | Omission | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:312 | assumptions-checker, implementer | Legacy, candidate, and unassisted arms lack portable isolated loading and dependency staging. | resolved |
| AR-d4cb4589-007 | Omission | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:437 | implementer, tester | Cutover and rollback lack a named command surface and partial-failure tests. | resolved |
| AR-d4cb4589-008 | Ambiguity | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:393 | implementer, pre-mortem | Repository metadata has no pending qualification state and can expose an unqualified skill to sync. | resolved |
| AR-d4cb4589-009 | Omission | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:312 | assumptions-checker, consistency-smells, implementer, tester | The cross-host protocol has no executable or manual qualification interface that enforces its controls. | resolved |
| AR-d4cb4589-010 | Omission | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:95 | assumptions-checker, implementer, tester | Implicit-activation qualification is circular and assumes unverified host enforcement. | resolved |
| AR-d4cb4589-011 | Inconsistency | MEDIUM | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:274 | consistency-smells | Two behavioral corpus cases duplicate the separately unscored trigger suite. | resolved |
| AR-d4cb4589-012 | Inconsistency | MEDIUM | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:325 | tester | The single initial pass cannot detect variance-based repeat triggers. | resolved |
| AR-d4cb4589-013 | Ambiguity | MEDIUM | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:393 | consistency-smells | Standard and deep tier guidance is not mapped to supported metadata fields. | resolved |
| AR-d4cb4589-014 | Inconsistency | MEDIUM | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:482 | pre-mortem | Repository implementation completion is conflated with live external qualification. | resolved |
| AR-d4cb4589-015 | Omission | MEDIUM | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:437 | pre-mortem | The real-use backup retention and requalification gates lack an evidence contract. | resolved |
| AR-d4cb4589-016 | Extraneous | MEDIUM | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:268 | pre-mortem | The qualification experiment has no bounded project-level execution budget. | resolved |
| AR-d4cb4589-017 | Inconsistency | LOW | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:1 | consistency-smells | The document is simultaneously labeled approved and pending review. | resolved |
| AR-d4cb4589-018 | Inconsistency | CRITICAL | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:580 | consistency-smells, implementer, tester | The cutover manifest is described as append-only while also being atomically replaced, leaving crash recovery semantics contradictory. | resolved |
| AR-d4cb4589-019 | Inconsistency | CRITICAL | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:679 | assumptions-checker, implementer, pre-mortem | The blanket network and credential denial conflicts with live model-host transport and does not define a safe provider-auth boundary. | resolved |
| AR-d4cb4589-020 | Inconsistency | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:399 | implementer, tester | The 96-session ceiling cannot cover the mandatory behavioral, stability, repeat, and trigger executions. | resolved |
| AR-d4cb4589-021 | Omission | HIGH | docs/plans/2026-07-19-prompt-engineer-replacement-design.md:385 | assumptions-checker, implementer, tester | Executor output and provenance lack a normative schema, canonical digest, and host-native freshness evidence. | resolved |

## Metrics

- Reported findings: 21
- CRITICAL: 4
- HIGH: 10
- MEDIUM: 6
- LOW: 1
- Overflow total: 0
- current_line_count: 764
- current_target_count: 1
- current_unresolved_placeholder_count: 0
- current_word_count: 5172
- delta_line_count: 232
- delta_target_count: 0
- delta_unresolved_placeholder_count: 0
- delta_word_count: 1887
- starting_line_count: 532
- starting_target_count: 1
- starting_unresolved_placeholder_count: 0
- starting_word_count: 3285

## Changelog

- AR-d4cb4589-001: Specified a public-only executor export rooted outside the private corpus, with allowlist and digest/phrase/path leakage verification; executors never receive the repository containing private.yml.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-002: Required sandboxed network and external-write denial, explicit environment and tool allowlists, credential and SSH-agent removal, connector disablement, and fail-closed INCONCLUSIVE behavior when isolation cannot be verified.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-003: Replaced generated analysis text with total visible assistant characters, defined its Unicode counting rule and repeated-run aggregation, and explicitly excluded hidden reasoning and provider-only tokens.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-004: Defined per-host sums, worst correctness scores across repeats, multidimensional win/tie/loss rules, a fixed 24-comparison denominator, and INCONCLUSIVE handling for missing comparisons.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-005: Specified the v1 fixture directory, YAML files, stable IDs, required fields, artifact containment, schema version, host coverage, and canonical byte-level digest algorithm.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-006: Defined legacy.lock.yml, exact local-source hash validation, companion dependency staging, per-arm isolated homes, expected discovery paths, and failure on unexpected discovered prompt-engineering skills.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-007: Added a named prompt-engineer-cutover command with prepare/apply/verify/rollback, an atomic transaction manifest, idempotent rollback, partial-failure behavior, and isolated failure-path tests.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-008: Mapped prequalification metadata to status candidate with all installs disabled and catalog Candidate status, then required the approved cutover to atomically change status active and enable only Codex and Claude.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-009: Selected a hybrid deterministic qualification CLI with explicit prepare, ingest, judge-packet, judge-ingest, score, and report operations while keeping live host launches operator-controlled and provenance-validated.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-010: Separated explicit qualification from an ephemeral single-field activation candidate, required exact diff verification, and made implicit enablement an additional nonblocking gate with distinct report statuses.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-011: Changed cases 11 and 12 into scored behavioral safety and evidence-limit cases, kept the 8 positive and 8 negative trigger suite separate, and made all 12 cases scored on both hosts.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-012: Added a digest-selected three-case stratified mandatory second-run sample before outputs and bounded one further repeat per ambiguous arm within the frozen session budget.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-013: Mapped standard to recommended_model_tier and deep to the existing heavy_model_tier field instead of inventing a second recommendation field.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-014: Split repository implementation acceptance from live qualification acceptance and stated that external unavailability does not reopen implementation without a bounded implementation defect.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-015: Defined a qualifying real use, required post-cutover evidence fields, made backup removal separately approved, and specified focused versus full requalification triggers.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-016: Froze executor, judge, operator-time, and monetary ceilings before execution; the fixed corpus plus stability sample fits the executor budget and exhaustion yields INCONCLUSIVE without budget expansion.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-017: Changed the status to Draft specification; direction approved, awaiting user review, which distinguishes prior direction approval from authorization to plan implementation.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-018: Separate an immutable transaction plan, a fsynced append-only event log, and an atomically replaced derived state cache; define crash reconciliation and rollback authority from the plan, log, and live filesystem.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-019: Define a provider-only parent-host transport and authentication boundary while denying general network, credentials, connectors, and external-action tools to the evaluated agent and its subprocesses; fail closed when separation cannot be verified.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-020: Budget 96 behavioral executor sessions and 40 trigger executor sessions separately, with exact mandatory counts and no borrowing or post-start expansion.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md
- AR-d4cb4589-021: Add a versioned normalized executor-result schema, provider-specific normalizers, canonical serialization and digests, immutable raw exports, host-native freshness evidence, and valid/invalid contract fixtures.
  - Paths: docs/plans/2026-07-19-prompt-engineer-replacement-design.md

## Rejected Findings

- None

## Open Questions

- None

## DEGRADED CAPABILITIES

fresh_context, model_selection, effort_selection, usage_metrics, parallel_dispatch, read_only

## Provenance

| Field | Value |
|---|---|
| Run ID | ar-20260719T211137050093Z-6c208c27 |
| Schema version | 1 |
| Started | 2026-07-19T22:07:25Z |
| Ended | 2026-07-19T22:07:25Z |
| Tier | high |
| Mode | revise |
| Output | both |
| Executor | requested: codex; observed: codex |
| CLI | /Users/tunji/skills/skills/general/adversarial-review/scripts/adversarial-review (portable-1) |
| Model | requested: gpt-5.6; observed: unavailable |
| Effort | requested: xhigh; observed: unavailable |
| Repository HEAD | aceb2bdd9d498fea2fd8ab15c0c9e103601a6a0f |
| Repository dirty digest | e8ac136c37635fdcdd1a172a7025fdc27611994087ccd84d383014899099ce0e |
| Target spec | docs/plans/2026-07-19-prompt-engineer-replacement-design.md sha256=7c5402388d3fdbd501b5d40cfaab14222ff5ac1a5e0befc009e0999f67f2b477 |
| Retries | 0 |

### Angles

| Angle | Status | Retries | Retry reasons | Failure reason |
|---|---|---|---|---|
| assumptions-checker | completed | 0 |  | unavailable |
| consistency-smells | completed | 0 |  | unavailable |
| divergence-probe-1 | completed | 0 |  | unavailable |
| divergence-probe-2 | completed | 0 |  | unavailable |
| divergence-probe-3 | completed | 0 |  | unavailable |
| implementer | completed | 0 |  | unavailable |
| pre-mortem | completed | 0 |  | unavailable |
| tester | completed | 0 |  | unavailable |

### Capabilities

| Capability | Requested | Status | Evidence | Source |
|---|---|---|---|---|
| fresh_context | true | unavailable | worst persisted task evidence: All available fresh reviewer threads were consumed by the prior implementer, tester, and assumptions-checker passes; the parent completed this final control-plane angle and disclosed the limitation. | persisted per-task capability records |
| repository_access | true | enforced | worst persisted task evidence: Successfully read the authenticated target and bounded repository dependencies from /Users/tunji/skills. | persisted per-task capability records |
| read_only | true | behavioral | worst persisted task evidence: The filesystem permission profile was unrestricted; read-only behavior was maintained by issuing only bounded read and search commands. | persisted per-task capability records |
| model_selection | gpt-5.6 | unavailable | worst persisted task evidence: The reviewer runtime exposed no machine-readable exact model identity attestation. | persisted per-task capability records |
| effort_selection | xhigh | unavailable | worst persisted task evidence: The worker runtime did not expose independently verifiable reasoning-effort metadata. | persisted per-task capability records |
| structured_output | true | behavioral | worst persisted task evidence: The response was manually constrained to the authenticated closed schema; no runtime schema-binding attestation was exposed. | persisted per-task capability records |
| usage_metrics | true | unavailable | worst persisted task evidence: No token or duration telemetry was exposed to this reviewer. | persisted per-task capability records |
| parallel_dispatch | true | unavailable | worst persisted task evidence: The trusted task prohibited recursive dispatch and no agents were dispatched. | persisted per-task capability records |

### Usage

| Metric | Value |
|---|---|
| prompt_bytes | 386118 |
| input_tokens | unavailable |
| cached_input_tokens | unavailable |
| output_tokens | unavailable |
| reasoning_tokens | unavailable |
| total_tokens | unavailable |
<!-- /adversarial-review-run:ar-20260719T211137050093Z-6c208c27 -->
