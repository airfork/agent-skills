# Orca Orchestration Run Cleanup Hardening Plan Review

PASSED

## Findings

| ID | Category | Severity | Location | Summary | Resolution |
| --- | --- | --- | --- | --- | --- |
| AR-001 | Inconsistency | MEDIUM | Executable command blocks | Agent-run commands omitted the repository-required RTK wrapper. | Resolved: every executable plan command now uses `rtk`; plain `orca` commands remain only inside the literal skill example. |
| AR-002 | Ambiguity | MEDIUM | Task 1 baseline | The extra-tabs baseline could already pass, but the plan required a RED label. | Resolved: record `BASELINE PASS` when appropriate and use deterministic missing-text checks as the RED gate. |
| AR-003 | Inconsistency | CRITICAL | Resource ownership | A before/after handle delta in a shared worktree could claim an unrelated tab. | Resolved: temporal deltas are forbidden; pre-existing worktrees ledger only coordinator creation responses, while an entirely run-created worktree owns all of its tabs. |
| AR-004 | Omission | HIGH | Ledger identity | Mutable handles could not safely identify a reminted pane. | Resolved: ledger entries record pane key, worktree ID, origin, and dispatch `assignee_pane_key`. |
| AR-005 | Incorrect fact | HIGH | Agent-backed worktree creation | The plan retained `startupTerminal.handle` as the current worker field. | Resolved: use `result.agentTerminalHandle`, with the documented legacy and scoped-list fallbacks. |
| AR-006 | Omission | HIGH | Delegated resource creation | A custom `resourcesCreated` status/payload protocol was not reliably consumed and left a crash window. | Resolved: workers may not create Orca resources; they ask the coordinator, which creates and ledgers them before replying. |
| AR-007 | Omission | HIGH | Forward tests | Failure/cancellation and dirty-worktree preservation regressions were absent. | Resolved: both scenarios are explicit forward gates. |
| AR-008 | Omission | MEDIUM | Diff inspection | Expected non-empty `git diff --no-index` returns status 1. | Resolved: wrappers accept exactly status 1 and return success for the inspection step. |
| AR-009 | Omission | HIGH | Review evidence | The final fresh reviewer had no stable path to RED/GREEN evidence. | Resolved: a run-unique evidence file is created, populated with exact IDs and outputs, and passed explicitly to the reviewer. |
| AR-010 | Inconsistency | MEDIUM | Final reporting | Requiring an empty ledger contradicted safely retained resources. | Resolved: entries end as `removed` or `retained`; retained entries permit terminal reporting but require an incomplete-cleanup disclosure. |
| AR-011 | Omission | MEDIUM | Repository verification | `scripts/verify` could ignore the untracked planning artifact. | Resolved: both planning documents are staged and checked with `git diff --cached --check` before the repository gate. |
| AR-012 | Omission | HIGH | Absence verification | An unscoped or truncated list could falsely prove that a resource was absent. | Resolved: finalization uses scoped, non-truncated lists and per-resource `terminal show`/`worktree show` checks. |
| AR-013 | Inconsistency | MEDIUM | Scope | A test-proven frontmatter/fallback change was allowed but forbidden by the final diff gate. | Resolved: out-of-scope evidence now stops the implementation and becomes a follow-up. |
| AR-014 | Omission | HIGH | Baseline snapshot | A fixed `/tmp` path could overwrite the true pre-edit baseline on retry. | Resolved: `mktemp` creates unique snapshot and evidence paths that are recorded and never overwritten. |

## Metrics

- Review tier: default adversarial pipeline, all roles at xhigh reasoning.
- Target role: plan-only feasibility and safety review.
- Attack angles: tester, operator, assumptions, pre-mortem, consistency/smells, feasibility.
- Initial document: 379 lines, 2,595 words, 0 TBD/TODO markers.
- Revised document: 406 lines, 2,798 words, 0 TBD/TODO markers.
- Growth: 27 lines and 203 words, explained by stable identity, safe ownership, evidence, pagination, and regression gates.
- Promoted findings: 14 total — 1 CRITICAL, 7 HIGH, 6 MEDIUM.
- Resolution verification: 14 resolved, 0 rejected, 0 stuck, 0 new findings.

## Changelog

- Replaced temporal handle-delta ownership with explicit coordinator creation provenance.
- Added pane-key identity and current `agentTerminalHandle` selection.
- Replaced the unsupported custom worker resource payload with coordinator-only creation through `ask`/reply.
- Added scoped, truncation-aware and per-resource cleanup verification.
- Restored failure, cancellation, dirty-worktree, handoff, and uncertain-identity forward gates.
- Added unique baseline/evidence files, RTK-compliant commands, accepted diff status handling, and cached whitespace verification.
- Clarified safe retained-resource reporting and bounded the handoff deduplication scope.

## Rejected Findings

- The singular close command in the original example was a repeatable placeholder because accompanying prose required closing every entry. The revised example nevertheless shows multiple closes to remove imitation ambiguity.
- Word count and anchor searches were inspection aids, not uniqueness gates. The revised plan makes this informational explicitly.
- The global finalization rule already covered the final reviewer terminal. The revised plan nevertheless adds an explicit review-run finalization step.
- The required execution skills already stop on failed validation and loop on review findings. The revised plan nevertheless states the remediation and resolution-check branch directly.
- The unchanged frontmatter preserved the external-browser Computer Use boundary. The revised table now repeats it for local clarity.
- `wait for results` already preserved return-results supervision. The revised table now says `wait for or return results` explicitly.
- Destructive operational fault injection was outside the Markdown-skill validation goal. The plan retains uncontaminated reasoning pressure tests and uses the real review run itself to verify resource cleanup.

## Open Questions

None.
