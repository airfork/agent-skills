# Adversarial Review Control Plane Evaluation

## Provenance

This evaluation used two fixed, already-reviewed historical fixtures and ran the
new control plane in critique/report-only mode. The reviewed Markdown files were
not edited. The run directories, result bundles, and reports are outside the
repository under
`/var/folders/x6/ry5zcqrj5b96fjtzpkjhtcvr0000gn/T/adversarial-review-task13.6uJ9ri/`.

| Item | Milestone fixture | Cleanup fixture |
|---|---|---|
| Run ID | `ar-20260718T084537516245Z-73b2301e` | `ar-20260718T084552813817Z-23a346f1` |
| Recorded repository HEAD | `5f32f6836665c3dcaf7639cec8412d9124b6a227` | `5f32f6836665c3dcaf7639cec8412d9124b6a227` |
| Recorded dirty state | clean; empty-status digest `4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945` | same |
| Executor | requested `generic`; observed `generic` | requested `generic`; observed `generic` |
| CLI | worktree candidate `skills/general/adversarial-review/scripts/adversarial-review` (`portable-1`) | same |
| Requested model / effort | `gpt-5.6-sol` / `xhigh` | `gpt-5.6-sol` / `xhigh` |
| Observed model / effort | unavailable / unavailable | unavailable / unavailable |
| Tier / mode | `high` / `critique` | `default` / `critique` |
| Output | `both` | `both` |
| Manifest created | `2026-07-18T04:45:37-04:00` | `2026-07-18T04:45:52-04:00` |
| Report written | `2026-07-18T06:09:06-04:00` | `2026-07-18T06:09:06-04:00` |
| End-to-end interval | `01:23:29` | `01:23:14` |
| Reported control-plane start/end | both `2026-07-18T10:09:06Z` (reported duration `0s`) | both `2026-07-18T10:09:06Z` (reported duration `0s`) |
| Report SHA-256 | `104870c92d6df102dd6a60467522223fb6d84ad50e815dc0d62fe99705a7fb90` | `62e70e007d2e0eaac8322c289928ab3fac7127b9db2aa5d7a639e4dfc2b227df` |

The end-to-end intervals above are the exact difference between each manifest's
filesystem creation time and its report write time. They include manual generic
dispatch and cannot be treated as model runtime. The control plane's own
`Started`/`Ended` values cover only final execution completion in these imported
generic runs, so their zero-second value is disclosed rather than substituted
with an inferred model duration.

There is one explicit worktree-candidate provenance exception. Both manifests
were prepared at `5f32f6836665c3dcaf7639cec8412d9124b6a227`, using the CLI by its
absolute path in the active feature worktree rather than an installed global
copy. Live evaluation then exposed that report-only runs with promoted findings
could not complete: the completion invariant incorrectly required author actions
and resolution checks in critique mode. Commit
`d0506df766ba392e3aa2a5b4bb5a0780d4731144` (`Complete report-only reviews
without author actions`, committed `2026-07-18T06:08:11-04:00`) added a public
CLI regression test and restricted those terminal-pair requirements to revise
mode. The same fixed candidate completed both reports at `06:09:06-04:00`.
The reviewed target digests did not change, but the manifest does not carry the
executing CLI's content digest, so exact binary provenance requires the stated
`5f32f68` plus `d0506df` sequence.

## Baseline Fixtures

### Milestone orchestrator

Fixed targets:

- Design: `docs/plans/2026-07-13-milestone-orchestrator-design.md`, SHA-256
  `163da53532dbb9263d99e072f693d62499feafa55b799fac7c21af889aa8ce1d`.
- Implementation plan:
  `docs/plans/2026-07-13-milestone-orchestrator-implementation-plan.md`, SHA-256
  `415d68ed4f5e1be0cda41f587e09d088cda2db8dca1b66f8f6ff8dabc62aa96a`.

Baseline reports:

- Design review SHA-256
  `caa5503c704fe73287a756d13fef3c443f54f2982c8fc8cdd337d24bbef9afc5`.
- Implementation-plan review SHA-256
  `461bcb4630c64f16c40450dc42335c7e3f5c6476617d6c6df0ead1e623e66eeb`.

The blocker-recall denominator is the implementation-plan review's 28 promoted
`CRITICAL`/`HIGH` roots: 8 critical and 20 high. That baseline reports 33
distinct promoted findings overall (28 blocker-class plus 5 medium), three
rejected candidates, three duplicates merged, two revise rounds, and one
permitted retry of the coverage angle. Thus 39 candidate dispositions are
accounted for, although the old report does not expose a machine-readable raw
candidate counter or prompt/token telemetry.

### Orca orchestration cleanup

Fixed targets:

- Design: `docs/plans/2026-07-14-orchestration-run-cleanup-design.md`, SHA-256
  `324b0d8a788490e3fd67b77ab3a97a938714cefb2f8482bd441f9c3e7f67af2b`.
- Hardening implementation plan:
  `docs/plans/2026-07-14-orchestration-run-cleanup-hardening-implementation.md`,
  SHA-256
  `e6ba1dbef8f7177ea124a1b5da91514e674bdd18598527fb3c5b3f98ae27908e`.

Baseline report:

- Hardening-plan review SHA-256
  `1ea9e88995b7cfff73abf309285c09a37ca564fec7be5ee2e168a62bc582f17d`.

The blocker-recall denominator is 8 promoted roots: 1 critical and 7 high. The
baseline reports 14 total promoted findings (the other 6 medium), zero open
findings after resolution, and no exact raw-candidate, prompt-byte, token, or
retry counter.

## Scripted Runs

| Metric | Milestone | Cleanup |
|---|---:|---:|
| Attack tasks | 11 | 7 |
| Dedupe tasks | 1 | 1 |
| Judge tasks | 1 | 1 |
| Total emitted / ingested | `13 / 13` | `9 / 9` |
| Raw candidates | 39 | 36 |
| Deduplicated semantic groups | 28 | 28 |
| Candidate votes: promote / refute / unproven | `35 / 3 / 1` | `29 / 6 / 1` |
| Promoted semantic findings | 24 | 22 |
| Reported severity | `3 CRITICAL / 16 HIGH / 5 MEDIUM / 0 LOW` | `0 CRITICAL / 17 HIGH / 5 MEDIUM / 0 LOW` |
| Overflow | 0 | 0 |
| Evidence gaps | 1 (`DG-012`) | 1 (`G-018`) |
| Retries | 0 | 0 |
| Result repairs | 0 | 0 |
| Verdict | `REPORT ONLY - 24 findings` | `REPORT ONLY - 22 findings` |
| Prompt bytes | 331,359 | 194,361 |

For both runs, state is `complete`; emitted task IDs equal ingested result task
IDs; every accepted result is recorded with task and result SHA-256; schema
version is 1 throughout; `result_repairs` is empty; target-digest history has
one immutable entry matching the manifest; summary run ID and finding count
match state; and summary overflow matches state overflow. No schema-invalid or
task-authentication-invalid result was accepted. A read-only replay of
`AdversarialReview::Schema.validate` against the schema recorded for each
ingested result returned `13 accepted results schema-valid` and `9 accepted
results schema-valid`.

The milestone report's one open question (`DG-012`) concerns whether the
existing action union needs a separate checkpoint tag. The cleanup report's one
open question (`G-018`) concerns discovery of an unknown worker-created resource
after both a rule violation and a crash. Both remain explicitly `unproven`; they
were not silently promoted, rejected, or dropped.

## Token And Retry Comparison

| Fixture | Historical baseline | Scripted control plane | Supported comparison |
|---|---|---|---|
| Milestone | Two revise rounds; one coverage retry; 33 distinct promoted findings; 39 accounted candidate dispositions | One critique round; 0 retries; 39 raw candidates, 28 groups, 24 promoted semantic findings; 331,359 prompt bytes | Retry count improved from 1 to 0. The runs reviewed different artifact states and modes, so finding counts are not an efficiency score. |
| Cleanup | 14 promoted findings; exact retry and raw-candidate counts unreported | One critique round; 0 retries; 36 raw candidates, 28 groups, 22 promoted semantic findings; 194,361 prompt bytes | Current retry count is exact, but no numeric baseline retry or prompt-byte comparison is available. |

Input, cached-input, output, reasoning, and total-token telemetry are unavailable
for both scripted runs. The historical reports also omit token and prompt-byte
telemetry. Therefore this evaluation cannot quantify token savings and does not
convert prompt bytes to tokens. The only defensible efficiency observations are
the scripted runs' bounded task counts, zero retries/repairs, deterministic
dedupe/cull accounting, and exact current prompt-byte totals.

## Blocker-Class Recall

The tables below map all 36 historical blocker roots. `Rediscovered` means a
current promoted finding identifies the same root or a stricter remaining form.
`Resolved in artifact` means the current fixed target contains an explicit
contract/test for the historical root; exact line evidence is given. A newly
found adjacent defect does not erase a historical resolution, but is named where
it materially narrows the result.

### Milestone: 28 of 28 mapped

| Baseline root | Mapping | Exact current evidence |
|---|---|---|
| AR-001 CRITICAL — publication/cleanup lacked a narrow executor boundary | Resolved in artifact | Plan lines 1032-1066 define a closed, versioned action union with exact fields and pre/postconditions; lines 1081-1085 scope one-shot grants. Current `AR-894ffaa6-007` finds a content-source omission inside that boundary, not absence of the boundary. |
| AR-002 HIGH — STATE CAS, canonical paths, and serialization underspecified | Resolved in artifact | Plan lines 997-1015 specify lease commands, canonical STATE realpath, expected-SHA CAS, atomic fsync/rename, concurrent acquisition, and stale-token rejection. |
| AR-003 CRITICAL — lease takeover and stale-owner fencing incomplete | Resolved in artifact | Plan lines 997-1015 require acquire/renew/takeover/release, liveness-gated takeover, monotonic tokens, epoch advance, and stale-token failure after takeover. |
| AR-004 HIGH — capability probes could mutate without ownership proof | Resolved in artifact | Plan lines 333-365 require a temporary repository, unique namespace, complete before inventories, stable creation IDs, owned-only cleanup, unchanged foreign state, and skip-before-mutation when ownership is unproven. |
| AR-005 HIGH — verification freshness not bound to an exact subject | Rediscovered | `AR-894ffaa6-012` says the final gate cannot produce independent evidence for the exact final subject; `AR-894ffaa6-017` says `mutation:false` is not an enforced read-only boundary. The intended exact-subject contract remains at plan lines 884-915 and 1184-1191. |
| AR-006 HIGH — no-commit mode conflicted with isolated execution | Rediscovered | `AR-894ffaa6-018` finds that no component owns creation/authentication/restoration/retirement of the external snapshot required by the plan's restricted-mode contract at lines 887-889. |
| AR-007 HIGH — unknown STATE versions lacked migration contract | Resolved in artifact | Plan lines 804-814 make one parser authoritative and require fenced, atomic, idempotent migration from every supported prior version, with preservation and rollback tests. |
| AR-008 HIGH — replanning authority/evidence/carry-forward incomplete | Resolved in artifact | Plan lines 932-935 and 1351-1354 require old/new digests, mapping version, review evidence, drift, budgets, carry-forward rules, approval provenance, and reapproval for SPEC/authority changes. |
| AR-010 HIGH — support claims not gated by actual-host evidence | Rediscovered | `AR-894ffaa6-014` finds active Orca/Codex/Claude claims precede host gates; `AR-894ffaa6-019` finds the supposedly shared conformance matrix lacks a canonical executable row source. |
| AR-011 HIGH — pressure protocol could drift after results | Resolved in artifact | Plan lines 1588-1606 require recomputed committed hashes, a new protocol/baseline for any post-baseline change, pre-registered corpus/repetitions/config/metrics/thresholds, and zero-tolerance rules. |
| AR-012 HIGH — prose fault inventory was not executable | Resolved in artifact | Plan lines 1578-1586 require stable table-driven fault rows and a test that fails on undocumented, unexecuted, or extra actions; lines 1608-1613 enumerate the required fault cases. |
| AR-013 CRITICAL — implementers could self-attest verification | Rediscovered | `AR-894ffaa6-008` finds independence rests on a caller label; `AR-894ffaa6-012` finds the final gate bypasses independent exact-subject evidence; `AR-894ffaa6-017` finds no enforced verifier read-only boundary. |
| AR-014 CRITICAL — outgoing scan missed deleted/LFS/capture/metadata data | Rediscovered | `AR-894ffaa6-003` finds missing path/link-race tests; `AR-894ffaa6-011` finds no pre-Git containment test for browser secrets; `AR-894ffaa6-009` finds no owner/transition for a positive secret detection. The base scan set remains at plan lines 1202-1214. |
| AR-015 CRITICAL — derived automation effects were not proven authorized | Rediscovered | `AR-894ffaa6-016` finds `inspect-effects` needs privileged forge/Orca reads outside the credential-owning component. The intended authoritative effect rule is at plan lines 1073-1079. |
| AR-016 HIGH — publication/review/CI could certify different heads | Resolved in artifact | Plan lines 1987-1995 require re-review after remediation of the new exact remote head; lines 2009-2020 require rerun/rescan/republish and CI polling against the exact final published SHA. Current `AR-894ffaa6-013` separately finds the required-check baseline is missing for this implementation workflow. |
| AR-018 HIGH — skill registration and catalog updates were split | Resolved in artifact | Plan lines 1635-1659 make package metadata part of the contract test; lines 1705-1738 update and commit `CATALOG.md`, `skills.yaml`, and usage together. |
| AR-021 HIGH — final staging could omit generated review/pressure artifacts | Resolved in artifact | Plan lines 1997-2006 explicitly stage design, plan, review, capability, pressure, package, test, fixture, catalog, manifest, and usage artifacts. |
| AR-022 CRITICAL — disposable fixture could reuse/escape caller path | Resolved in artifact | Plan lines 1507-1520 require a nonexistent output and local-only hermetic layout; lines 1786-1788 require returned realpaths under the marked fixture; lines 1847-1856 reject unsafe, reused, stale, external, or unreserved fixtures before mutation. |
| AR-023 HIGH — fixture Git could inherit hooks/signing/identity/config | Resolved in artifact | Plan lines 1509-1514 require fixture-local author data, sanitized HOME/XDG/Git config, disabled signing/hooks, fixed dates, and recorded object format. |
| AR-024 CRITICAL — same-UID mode-0600 files/tokens were not isolation | Rediscovered | `AR-894ffaa6-010` finds the launch profile is not immutably bound to the launched process; `AR-894ffaa6-017` finds verifier mutation/control authority is not denied. Plan lines 344-365 explicitly reject same-user modes/tokens and demand active bypass probes. |
| AR-025 HIGH — action grants lacked a closed typed schema | Resolved in artifact | Plan lines 1032-1066 define the closed discriminated union, required/forbidden fields, normalization, pre/postconditions, and idempotency for all eight actions. |
| AR-026 HIGH — first push conflated absent remote with unknown state | Resolved in artifact | Plan lines 1068-1071 define tagged `absent` and `present` expectations and forbid nullable OIDs or empty ranges. |
| AR-027 HIGH — verifier accepted caller argv before canonical PLAN grammar | Resolved in artifact | Plan lines 804-807 make the PLAN parser the sole grammar; lines 1181-1191 require command-ID lookup, exact PLAN digest, and reject shell strings/unknown IDs. |
| AR-028 HIGH — evidence commits could create an endless scan/push loop | Rediscovered | `AR-894ffaa6-002` finds a remaining impossible pre-scan/commit ordering in the finite-anchor protocol at plan lines 1230-1237. This is the same root class: self-referential publication evidence. |
| AR-029 CRITICAL — caller-provided effects were not authoritative | Rediscovered | `AR-894ffaa6-016` exposes that authoritative effect inspection lacks a viable credential topology. Plan lines 1073-1079 correctly forbid callers from asserting their own effects, but execution ownership remains incomplete. |
| AR-031 HIGH — executor could not authorize its own implementation publication | Resolved in artifact | Plan lines 1970-1985 explicitly forbid manufacturing self-authority, limit dogfood to the fixture, and use the separately authorized existing workflow for this branch. |
| AR-032 HIGH — actual-host conformance covered fewer cases than promised | Rediscovered | `AR-894ffaa6-019` finds no canonical executable shared row source or fixed assertions despite plan lines 1858-1865 saying rows are non-omittable. |
| AR-033 HIGH — nonempty fixture path did not prove safe/fresh/unused target | Resolved in artifact | Plan lines 1847-1856 require root containment, marker/schema/seed, clean commit, local remote, no network remote, freshness, unused run prefix, and atomic namespace reservation before host mutation. Current `AR-894ffaa6-003` is a separate scanner artifact/capture path-confinement gap. |

### Cleanup: 8 of 8 mapped

| Baseline root | Mapping | Exact current evidence |
|---|---|---|
| AR-003 CRITICAL — temporal handle delta could claim unrelated tabs | Resolved in artifact | Plan lines 137-147 require creation-origin ledgering, forbid before/after deltas in pre-existing worktrees, and bind dispatch to the stable pane key. |
| AR-004 HIGH — mutable handles could not identify reminted panes | Resolved in artifact | Plan lines 137-147 record current handle, pane key, worktree ID, origin, and `assignee_pane_key`; lines 199-203 resolve stale handles only by one exact pane-key match on scoped non-truncated data. |
| AR-005 HIGH — wrong `startupTerminal.handle` field treated as current | Rediscovered | `AR-251512b7-012` finds the plan's help-only probes cannot establish `agentTerminalHandle` or pane behavior. Lines 84-86 and 124-130 state the intended current/legacy fallback, but the runtime fact is not adequately authenticated. |
| AR-006 HIGH — worker-created resources left a crash/ledger window | Resolved in artifact, with evidence gap | Plan lines 171-180 prohibit worker creation and make coordinator creation/ledger-before-reply authoritative. `G-018` correctly remains unproven for the compound out-of-contract case where a worker violates the rule, creates an unknown resource, and crashes before disclosure. |
| AR-007 HIGH — failure/cancellation/dirty preservation lacked forward tests | Rediscovered | `AR-251512b7-003` finds cancellation and unresolved-blocker scenarios absent from Task 7 despite the lifecycle requirement at lines 35-40. Task 7 lines 314-326 covers failure and dirty preservation only. |
| AR-009 HIGH — final reviewer lacked stable RED/GREEN evidence | Resolved in artifact | Plan lines 47-57 create unique snapshot/evidence paths; lines 342-344 require exact prompts, IDs, results, and verdicts; lines 387-393 pass the exact evidence path to a fresh reviewer and preserve its results before cleanup. |
| AR-012 HIGH — unscoped/truncated reads could falsely prove absence | Rediscovered | `AR-251512b7-007` finds the canonical example omits per-terminal probes; `AR-251512b7-009` finds no concrete not-found-vs-operational-failure oracle. The stronger normative contract is present at lines 199-207, so recall detects example/verification drift rather than losing the rule. |
| AR-014 HIGH — fixed `/tmp` path could overwrite the baseline | Rediscovered | `AR-251512b7-001` finds the replacement `mktemp` templates at line 54 are invalid on macOS because `XXXXXX` is not trailing. This is the same evidence-preservation root in a stricter executable form: unique paths are intended but cannot be created by the prescribed command. |

Blocker-class recall is therefore `28/28` for milestone and `8/8` for cleanup,
or `36/36` overall. This is a root mapping, not an assertion that the current
fixtures are safe to implement: the scripted reports correctly promote 19
milestone and 17 cleanup blocker-class findings in their current forms.

## Adapter Limitations

- Generic mode emitted portable authenticated task bundles and ingested their
  schema-conformant results, but `capabilities.json` was `{}`. Every requested
  runtime capability—fresh context, repository access, read-only enforcement,
  model selection, effort selection, structured output, usage metrics, and
  parallel dispatch—was therefore recorded `unavailable`, and both reports
  disclose `DEGRADED CAPABILITIES`.
- The requested `gpt-5.6-sol` / `xhigh` identity was not runtime-attested. The
  evaluation may use the findings as review evidence, but it cannot claim a
  verified direct-adapter model or effort route.
- The generic workers were governed by read-only task instructions and result
  authentication, but same-principal filesystem enforcement was not attested.
  This is a limitation, not silently upgraded to `read_only: verified`.
- No direct Codex, Claude, Cursor, or Gemini adapter executed these fixtures.
  A post-run read-only probe, `rtk claude --version`, returned `2.1.214 (Claude
  Code)`. That is a host observation only; it is not execution provenance and
  does not supersede the checked-in Claude fixture based on 2.1.212.
- Prompt-byte telemetry is complete, but all token fields are unavailable. No
  token estimate or savings percentage is inferred.
- The report provenance records the reviewed repository HEAD and CLI path, not
  an executable content digest. Because the live `d0506df` repair occurred
  after manifest preparation, reproduction requires the explicit candidate
  commit sequence disclosed above.
- Reported start/end timestamps do not include manual generic dispatch. The
  end-to-end filesystem interval is disclosed separately and must not be read as
  model latency.

## Post-evaluation implementation review

A fresh deep review of the full branch subsequently found lifecycle and
direct-adapter defects. Remediation added authenticated parent-task authority,
candidate and author-resolution arbitration routing, round-two rediscovery,
terminal-stage verdict binding, direct schema authentication, stdin prompt
transport, controlled interpreter and network credential environments,
cross-task session reuse detection, and truthful serial direct eligibility for
default/high Codex and Claude. Focused regressions cover each repaired root.
The release gate was then satisfied by `rtk scripts/verify`, skill-creator
validation, `git diff --check`, and isolated `scripts/sync-skills --dry-run`
checks for Codex, Claude, Cursor, and Gemini.

One direct-mode limitation is disclosed rather than overstated: portable Ruby
cannot bind process creation to the already-verified executable descriptor on
every supported POSIX host. The runner rechecks immediately before spawn, but a
trusted CLI installation must not be concurrently replaced by another same-UID
process during that final window. Generic authenticated handoffs avoid relying
on the direct executable boundary. This implementation review does not change
the evidence-backed decision below about the two completed report-only runs.

## Decision

**PASS WITH DISCLOSED ADAPTER AND PROVENANCE LIMITATIONS.**

The evaluation satisfies its decision gate:

1. All 36 historical `CRITICAL`/`HIGH` roots are mapped to a current promoted
   finding, an exact current-artifact resolution, or—in the cleanup
   coordinator-only case—an exact resolution plus a separately preserved
   out-of-contract evidence gap.
2. All 22 emitted tasks were ingested exactly once (`13 + 9`), accepted result
   sets match emitted task IDs, task/result digests are recorded, schema version
   is consistent, and result repair counts are zero. No invalid result was
   accepted.
3. Both runs reached `complete`; immutable target digests match manifests and
   history; summary run IDs, findings, verdicts, severity totals, prompt bytes,
   and overflow agree with state; reports carry matching run markers and stable
   SHA-256 digests.
4. The live report-only completion defect was not waived. It was reproduced,
   fixed with a public lifecycle regression test in `d0506df`, and the fixed
   candidate then completed both report-only runs without author actions or
   resolution tasks.

This pass validates blocker recall, deterministic lifecycle/accounting, and
portable generic handoffs. It does **not** validate token reduction, direct
adapter capability claims, exact model/effort identity, OS-enforced read-only
workers, or a clean single-commit executable provenance record. Those claims
remain outside the evidence produced here.
