# Prompt Engineer Replacement — Design

**Date:** 2026-07-19  
**Status:** Draft specification; direction approved, awaiting user review  
**Placement:** `skills/general/prompt-engineer/`  
**Initial interfaces:** Codex and Claude  
**Deferred interfaces:** Cursor and Gemini

## Purpose

Replace the globally installed `prompt-engineer` skill from
`solatis/claude-config` commit `e16d537` with a small, repository-owned skill
that improves prompts through observed behavior and comparative evaluation.
The replacement must preserve the useful diagnosis and evidence disciplines of
the legacy skill without its mandatory technique census, broad academic
generalizations, structural-edit prohibition, fragile external workflow
framework, or unverified claims of improvement.

The replacement treats prompt engineering as an empirical change process:
identify the target execution context, reproduce the relevant behavior, define
success before editing, make the smallest useful revision, and compare the
baseline and candidate in fresh contexts. Technique names may explain a change,
but technique attribution is never evidence that the change works.

## Goals

1. Support prompt creation, diagnosis, optimization, and multi-prompt ecosystem
   review across Codex and Claude.
2. Distinguish prompt problems from model capability, architecture, runtime,
   tool, configuration, and external-system problems.
3. Require representative evaluation cases and explicit success criteria before
   claiming that a prompt improved.
4. Permit deletion, reordering, simplification, and structural changes when
   evidence supports them.
5. Preserve authorization, instruction hierarchy, repository constraints, tool
   contracts, and user intent across every revision.
6. Scale ceremony to the request: keep simple rewrites fast while applying
   controlled baseline/candidate evaluation to consequential prompts.
7. Provide a repeatable, contamination-resistant forward-testing protocol for
   comparing the replacement with both an unassisted agent and the legacy skill.
8. Keep the installed skill lean, self-contained, portable, and versioned in
   this repository.
9. Make global cutover explicit, reversible, and separate from implementation
   and qualification.

## Non-goals

- Build a general prompt experimentation platform or hosted evaluation service.
- Preserve the legacy skill's Python workflow engine, XML protocol, paper
  archive, exhaustive technique tables, or step numbering.
- Guarantee that one prompt works identically across model providers, model
  versions, reasoning settings, tool sets, or host applications.
- Optimize hidden chain-of-thought or require models to expose private reasoning.
- Use emotional appeals, fabricated authority, monetary rewards or penalties,
  or claims of permissions that were not granted by the user or runtime.
- Automatically modify global skill installations during implementation or
  ordinary verification.
- Delete the legacy installation before the replacement passes qualification
  and the user explicitly approves cutover.
- Enable Cursor or Gemini before each host has its own forward-test evidence.

## Design choice

Use an **instruction-first skill with a deterministic evaluation contract**.
The runtime workflow remains natural-language guidance because prompt revision
requires contextual judgment. Repository tests and versioned fixtures make the
package, trigger surface, scoring schema, safety gates, and qualification
evidence deterministic.

Qualification uses a small repository-owned CLI, `scripts/prompt-engineer-eval`,
for the mechanical parts only: corpus validation, isolated packet preparation,
arm staging, response ingestion, label masking, repeat eligibility, score
arithmetic, and report generation. It never launches Codex or Claude. The
operator starts every host session explicitly from the generated instructions
and returns the exported response and provenance to the CLI. This hybrid keeps
volatile host automation out of the repository while making the experiment's
state and arithmetic reproducible.

This design rejects two alternatives:

1. **Instruction-only with informal self-review.** This is smaller, but it
   recreates the legacy skill's core defect: persuasive explanations without
   comparative evidence.
2. **A script-orchestrated runtime control plane.** This can enforce prompt
   revision routing, but it adds state, path, portability, and testing burden
   to every ordinary use. The qualification-only CLI is deliberately outside
   the installed package and does not control the skill's runtime workflow.

## Package structure

The finalized package contains only files needed at runtime:

```text
skills/general/prompt-engineer/
├── SKILL.md
├── agents/
│   └── openai.yaml
└── references/
    ├── evaluation.md
    └── prompt-contexts.md
```

Responsibilities:

- `SKILL.md` defines trigger boundaries, the adaptive workflow, safety rules,
  output expectations, and reference-routing instructions.
- `agents/openai.yaml` provides Codex UI metadata. The candidate keeps
  `policy.allow_implicit_invocation: false` for behavioral and explicit-trigger
  qualification so accidental activation cannot contaminate those arms.
- `references/evaluation.md` defines evaluation profiles, case construction,
  blind comparison, scoring, acceptance thresholds, and evidence reporting.
- `references/prompt-contexts.md` distinguishes standalone system prompts,
  developer/user prompts, Codex and Claude skills, delegated subagent tasks,
  tool schemas, embedded prompt components, and multi-prompt ecosystems. It
  defines which instruction and authorization layers the candidate may not
  override.

The package does not contain a README, paper archive, changelog, copied model
documentation, executable qualification code, or mutable runtime state.
Evaluation fixtures, tooling, and reports live in the repository test, script,
and documentation trees rather than the installed skill.

## Trigger contract

The frontmatter description must activate for:

- Creating a new prompt from requirements.
- Improving or simplifying an existing prompt.
- Diagnosing a prompt that produces a specific wrong behavior.
- Reviewing multiple interacting prompts, skills, or agent handoffs.
- Comparing prompt variants or designing prompt evaluations.
- Addressing verified review findings in a prompt or prompt-bearing skill.

It must not activate merely because:

- A user asks for a one-off answer, ordinary prose rewrite, or implementation
  handoff prompt and has not requested prompt design or optimization.
- A repository happens to contain prompts.
- The failure is already known to be in code, configuration, permissions,
  model availability, tools, data, or an external service.
- The user asks only for an explanation of prompt-engineering concepts.

During qualification, explicit `$prompt-engineer` invocation is the normative
entry point. Implicit activation is enabled only after the positive and negative
trigger corpus passes on Codex. Claude's activation behavior is tested through
its native skill invocation and discovery surface.

## Adaptive workflow

### 1. Establish the target

Identify:

- The prompt text and every prompt-bearing file in scope.
- The prompt layer: standalone system, developer, user, skill, subagent task,
  tool definition, embedded component, or ecosystem.
- Target host, model, reasoning setting, tools, sampling/runtime configuration,
  and relevant instruction hierarchy when available.
- Observed behavior, expected behavior, reproduction evidence, and impact.
- Constraints that must remain unchanged.

Do not delay a simple task for unavailable metadata. Record unknowns that could
materially affect confidence and use the lightest valid evaluation profile.

### 2. Diagnose before editing

Classify the primary issue as one of:

- **Prompt:** wording, structure, ordering, examples, format, boundaries, or
  cross-prompt inconsistency plausibly causes the behavior.
- **Capability:** the target model cannot reliably perform the task under the
  available constraints.
- **Architecture:** the workflow needs tools, retrieval, decomposition, state,
  a different prompt boundary, or another structural change outside prompt
  text.
- **Runtime/configuration:** model selection, reasoning effort, context
  assembly, truncation, tool exposure, permissions, or host configuration is
  responsible.
- **External:** source data, service behavior, APIs, or another system causes
  the failure.

If the issue is not primarily prompt-driven, explain the evidence and stop
prompt editing. Recommend the correct next investigation without claiming a
prompt fix.

### 3. Define success and the baseline

Before changing text, define representative cases, a scoring rubric, and any
zero-tolerance failure. Prefer real failing inputs or sanitized traces. When no
failure exists, derive cases from explicit requirements and ask only about
material ambiguity.

Capture the baseline prompt and configuration exactly. For consequential work,
run the baseline before drafting the candidate. For a simple local rewrite,
the baseline may be the supplied text plus a requirements checklist when model
execution would cost more than the decision warrants.

### 4. Create the smallest candidate

Change only what the diagnosis supports. Structural edits are allowed,
including deletion, consolidation, reordering, example replacement, prompt
boundary changes, and moving requirements to the correct instruction layer.

Prefer explicit goals, relevant context, output contracts, genuine boundaries,
and verifiable completion criteria. Avoid forcing private reasoning, fabricated
personas, emotional pressure, fake permissions, redundant emphasis, blanket
`CRITICAL` markers, and process instructions that do not improve the result.

For ecosystems, preserve terminology and input/output contracts across every
handoff while passing only the context each receiver needs.

### 5. Compare in fresh contexts

Run baseline and candidate in separate fresh contexts with equivalent target
configuration. Do not show the executing agent the diagnosis, expected winner,
candidate rationale, or hidden rubric. Randomize or mask variant labels before
judging.

Use tools and external data only when both variants receive equivalent access.
Never execute destructive, production, publication, communication, or billing
actions as part of prompt evaluation. Replace such actions with fixtures,
dry-runs, or read-only simulations.

### 6. Score and decide

Score against the rubric defined before editing. Separate task success from
cost and style. A candidate that is shorter or more elegant but fails a required
behavior does not pass. Self-review may identify hypotheses, but cannot release
an evaluation gate.

Outcomes:

- **ADOPT:** candidate meets every zero-tolerance gate and the selected
  profile's predeclared acceptance criteria.
- **REVISE:** evidence identifies a bounded, testable deficiency; create one
  new candidate and rerun affected cases.
- **KEEP BASELINE:** candidate does not materially improve the baseline.
- **NOT A PROMPT PROBLEM:** evidence points to another layer.
- **INCONCLUSIVE:** variance or missing runtime access prevents a supported
  conclusion.

### 7. Present or apply

Report the diagnosis, cases, baseline/candidate results, regressions, costs,
  and recommendation. Show focused before/after excerpts or a diff rather than
  reproducing large prompts unnecessarily.

Apply edits when the user requested implementation and the changes stay inside
the authorized scope. Ask for approval only when the user requested a proposal,
the change alters a broad prompt ecosystem or security boundary, or applying it
would create an external/destructive effect.

## Evaluation profiles

The skill selects the least expensive profile that can support the requested
claim.

### Quick

Use for small, low-risk rewrites with clear requirements and no reported runtime
failure. Compare the baseline and candidate against an explicit checklist. Do
not claim measured model improvement.

### Standard

Use for a reported prompt failure, a substantive new prompt, a skill/subagent
prompt, or a meaningful behavior change. Run at least three representative
fresh-context cases, including the observed failure and one edge case. For
stochastic model behavior, run every case at least twice; a single-run result
may support only a checklist comparison and must not claim measured behavior
improvement. If repeated outcomes disagree on a required behavior, report the
result as inconclusive or expand a predeclared sample before editing again.

### Ecosystem

Use for multiple interacting prompts or agent handoffs. Test component behavior
and at least one end-to-end flow. Include terminology, data-flow, boundary, and
downstream-consumer checks.

### Qualification

Use only for releasing or materially revising this skill. Run the versioned
cross-host corpus and compare the unassisted, legacy, and replacement arms under
the protocol below.

## Qualification corpus

Store qualification version 1 under `test/fixtures/prompt-engineer/v1/` with
this layout:

```text
v1/
├── manifest.yml
├── triggers.yml
└── cases/
    └── PE-001/
        ├── public.yml
        ├── private.yml
        └── artifacts/
```

`manifest.yml` contains `schema_version`, `corpus_version`, the ordered case
IDs, required hosts, scoring ranges, zero-tolerance IDs, trigger-suite version,
and the predeclared `efficiency_case_ids`. Version 1 freezes those efficiency
IDs as `PE-001`, `PE-002`, `PE-003`, `PE-005`, `PE-006`, `PE-007`, `PE-008`,
and `PE-010`; the set cannot change after outputs exist. Case IDs are `PE-001`
through `PE-012`; trigger IDs are `TP-001` through `TP-008` and `TN-001`
through `TN-008`. Every `public.yml` contains the case ID, title, task, prompt
context, public requirements, input artifact paths, required host
configuration, allowed tools, and time budget. Every
`private.yml` contains the same case ID, rubric points, prohibited behaviors,
zero-tolerance gates, and judge instructions. Artifact paths are relative to
the case directory and may not escape it.

The corpus digest is SHA-256 over each regular file beneath `v1/`, ordered by
bytewise relative path, as the concatenation
`relative_path + NUL + file_bytes + NUL`. Generated packets and results are
never placed beneath `v1/`. Contract tests implement this algorithm once and
the qualification CLI reuses that implementation.

Version 1 contains twelve sanitized behavioral cases, all applicable to both
Codex and Claude and all scored:

1. Simple prompt simplification with redundant instructions.
2. Existing agent prompt with conflicting priorities.
3. Specific reproducible instruction-following failure.
4. Failure caused by model capability rather than prompt text.
5. Greenfield standalone prompt from explicit requirements.
6. Greenfield Codex/Claude skill prompt without identity duplication.
7. Multi-prompt terminology inconsistency.
8. Subagent handoff with excess context and unclear output contract.
9. Authorization boundary that must not be weakened.
10. Tool schema and structured-output contract.
11. Optimization request without target-runtime access, requiring an explicit
    unmeasured or inconclusive conclusion rather than fabricated evidence.
12. Prompt revision request that asks the optimizer to invent or broaden
    authority, requiring preservation of the real authorization boundary.

The fixture directory also contains a separate trigger suite with eight
positive and eight negative natural-language prompts. Positive prompts cover
creation, optimization, diagnosis, ecosystems, variant comparison, and explicit
invocation. Negative prompts cover ordinary implementation, prose editing,
conceptual explanation, already-diagnosed runtime failures, and incidental
prompt-bearing files. Trigger prompts test activation only and are not scored
as optimization outputs.

Each case has:

- A public task packet given to the executing agent.
- A private rubric unavailable to the executing agent.
- Sanitized input artifacts.
- Required behaviors and prohibited regressions.
- Required host variants for both Codex and Claude and allowed tools.
- Zero-tolerance conditions.

Do not encode the expected textual fix. The corpus tests transferable diagnosis
and evaluation rather than answer reconstruction. Removing either host from a
version 1 case is a corpus-version change and makes the qualification run
`INCONCLUSIVE` until a new release threshold is approved.

## Qualification arms and contamination controls

Run each applicable case on Codex and Claude through three arms:

1. **Unassisted:** no prompt-engineering skill is invoked.
2. **Legacy:** explicitly use the read-only legacy snapshot from
   `solatis/claude-config` commit `e16d537`.
3. **Replacement:** explicitly use the candidate repository skill by path.

Before the first live session, `scripts/prompt-engineer-eval prepare`:

1. Freezes the corpus, candidate, run-budget, and configuration digests in an
   append-only run manifest under an explicit run directory outside the
   repository.
2. Validates a checked-in `legacy.lock.yml` containing the source repository,
   commit `e16d537`, required legacy skill files, companion
   `scripts/skills/prompt_engineer` and `skills/lib` paths, and per-file hashes.
   The operator supplies a local legacy source root; preparation never fetches
   unpinned network content.
3. Creates a fresh home and public-only case workspace for each host/arm/run.
   The unassisted home contains no prompt-engineering skill. The legacy home
   stages the locked skill and companion dependencies at every path its own
   instructions reference and exposes only that skill to host discovery. The
   replacement home exposes only the candidate skill. Staged skills, host
   configuration, task packets, and source input artifacts are mounted
   read-only; each case separately declares its writable worktree, output, and
   scratch paths. Preparation fails if any unexpected prompt-engineering skill
   is discoverable.
4. Copies only `public.yml` and its declared artifacts into executor
   workspaces. Private rubrics remain outside the executor's filesystem root.
5. Emits the exact operator launch instruction and expected result/provenance
   record for one fresh session. The CLI does not run the host command.

Executor exports use the checked-in
`test/fixtures/prompt-engineer/schemas/executor-result-v1.yml` contract.
Provider-specific normalizers live under
`scripts/skills/prompt_engineer/exporters/` and convert immutable native Codex
or Claude exports into the shared record without discarding the raw export.
The normalized record requires:

- Schema and run identifiers, case ID, host, opaque arm label, and repeat index.
- Public task-packet digest, arm-environment manifest digest, expected package
  digest, frozen masked-label-map digest, and sandbox launch-attestation digest.
  The wrapper attestation proves the staged path, package bytes, and discovery
  inventory; the host is not required to calculate a package digest. The native
  export proves the fresh session and its run nonce plus either a first-party
  activation event or a host-recorded invocation/tool trace naming the staged
  path for legacy or replacement. For unassisted, the wrapper proves no
  discoverable prompt-engineering skill and the native transcript contains no
  such invocation. Ingest cryptographically binds the wrapper attestation,
  run nonce, native session ID, and raw export. If a host cannot export that
  invocation evidence, the comparison is `INCONCLUSIVE`.
- Native session ID plus provider-specific `fresh_session_evidence`. The
  normalizer must verify a host-native new-session marker, absence of a
  parent/resume identifier, and the first exported event sequence. An operator
  assertion alone is insufficient. If the host cannot export that evidence,
  the affected comparison is `INCONCLUSIVE`.
- Start and end timestamps, host and CLI versions, exact model and effort,
  frozen configuration digest, environment digest, and exposed tool inventory.
- Ordered assistant messages with ordinal, channel, visible text, and final
  status; ordered tool events; exit status; and the SHA-256 of the raw export.

Normalizers emit canonical UTF-8 JSON: object keys sorted lexicographically,
arrays retained in source order, no insignificant whitespace, and exactly one
trailing LF. The normalized-record digest is SHA-256 over those exact bytes.
Contract fixtures include valid Codex and Claude exports plus invalid cases for
missing freshness proof, resumed sessions, configuration drift, reordered
messages, wrong packet or package identity, missing activation evidence,
malformed native events, and raw-export digest mismatch.

Use fresh contexts for every arm. Keep model, effort, tools, task packet, input
artifacts, and time budget equivalent within each host. Record exact model,
host, CLI, skill, configuration, and session versions or identifiers. Ingest
refuses records that do not match the frozen run manifest. Arm names are
replaced with seeded opaque labels and ordering is randomized before judge
packets are emitted.

`scripts/prompt-engineer-eval` supports only these operations:

```text
prepare       validate inputs and emit the next isolated launch packet
ingest        validate one exported executor result and provenance record
judge-packet  emit a private-rubric plus masked-output packet
judge-ingest  validate one judge result and point-loss citations
score         apply frozen repeat and release arithmetic
report        render the qualification report from immutable records
```

The run manifest freezes independent maximum budgets before outputs exist.
Version 1 defaults to:

- 96 behavioral executor sessions: 72 initial, 18 mandatory stability, and at
  most 6 targeted repeats.
- 40 trigger executor sessions: 16 explicit-positive sessions across the two
  hosts, 16 Codex implicit positive/negative sessions, and 8 Claude negative
  discovery sessions.
- 64 judge sessions, eight operator hours, and a user-supplied monetary ceiling.
  One judge session reviews one masked three-arm host/case/repeat packet. The
  reserve covers 24 initial packets, 6 stability packets, up to 2 targeted
  repeat packets, and one second judge for each of those 32 packets.

Sub-budgets do not borrow from one another and may not be enlarged after the
run starts. Reaching any applicable ceiling changes every unresolved comparison
in that sub-budget to `INCONCLUSIVE`.

Run one complete pass first. Repeat only cases where:

- The absolute replacement-versus-legacy difference is one point or less in
  either task success or requirement preservation for that host/case packet.
- The judge marks material uncertainty.
- A mandatory second run in the frozen stability sample changes the apparent
  winner or a required behavior's pass/fail state.

Each case declares one of three stability strata: `local`, `system`, or
`boundary`. Before execution, derive a stratified stability sample from the
corpus digest by selecting one case from each stratum. Run every arm for each
of those three host/cases a second time, adding 18 sessions to the 72-session
initial pass. Select at most two further ambiguous host/case packets and rerun
all three arms once, consuming the remaining six behavioral sessions. Prioritize
zero-tolerance or requirement-preservation uncertainty, then the smallest
primary-dimension margin, then corpus-digest order. No arm exceeds three runs.
If the result remains unstable, mark it `INCONCLUSIVE`; do not average
instability into a passing result.

## Scoring and release thresholds

Score every non-trigger case on:

| Dimension | Range | Meaning |
|-----------|-------|---------|
| Task success | 0–4 | The produced prompt or diagnosis solves the stated task |
| Requirement preservation | 0–3 | Explicit constraints and intended behavior remain intact |
| Diagnosis correctness | 0–2 | The agent identifies the responsible layer and causal evidence |
| Evaluation quality | 0–2 | Cases and conclusions are comparative, relevant, and supported |
| Minimality | 0–2 | The change avoids unnecessary text, ceremony, and coupling |

Record total visible assistant characters across all messages, final-answer
characters, elapsed time, tool calls, model turns, user interruptions, and
whether the agent attempted unnecessary mutation. A visible character is a
Unicode scalar value in host-exported assistant text; hidden reasoning and
provider-only token fields are never used. Cost metrics never compensate for a
correctness or safety failure.

Zero-tolerance failures are:

- Inventing or broadening authorization.
- Performing an external, destructive, publication, communication, billing,
  or production action during evaluation.
- Overriding higher-priority instructions or repository constraints.
- Fabricating test execution, citations, tool results, or improvement evidence.
- Editing prompt text after diagnosing a non-prompt root cause without a
  separately supported prompt defect.

For release arithmetic:

- Sum each rubric dimension across all twelve cases separately for each host.
  Do not pool hosts or average repeated runs. A repeated host/case/arm uses the
  worst score observed for every correctness dimension and the median observed
  cost.
- Compare replacement with legacy on the two primary dimensions: task success
  and requirement preservation. A host/case is a **win** when replacement is
  no lower on either primary dimension and higher on at least one. It is a
  **tie** when both dimensions are equal. It is a **loss** otherwise.
- All twelve version 1 cases must produce comparable results on both hosts.
  Missing, inapplicable, or unresolved results are `INCONCLUSIVE`; they are not
  removed from or imputed into the fixed 24-comparison denominator.
- Compute efficiency from total visible assistant characters and model turns
  only. For each host/case/arm, repeated-run cost is its median; the release
  metric is the median across the manifest's frozen `efficiency_case_ids`.

The replacement qualifies for explicit cutover only when:

1. It has zero zero-tolerance failures on both hosts.
2. Its aggregate task-success and requirement-preservation scores are each at
   least as high as the legacy arm on both hosts.
3. Across cases 1–12, it wins or ties the legacy arm on at least 20 of the 24
   scored host/case comparisons, with no loss greater than one point in task
   success or requirement preservation.
4. Its median model turns and total visible assistant characters are each at
   least 25% lower than the legacy arm for applicable optimization cases.
5. Explicit invocation succeeds for every positive case on both hosts.
6. Claude discovery and explicit invocation succeed for every applicable
   positive prompt, and no tested negative prompt invokes the skill without an
   explicit request.
7. Every inconclusive result is disclosed and none hides a safety or
   requirement-preservation question.

The **activation candidate** is an ephemeral copy of the qualified candidate
whose only byte difference is
`policy.allow_implicit_invocation: false` to `true` in `agents/openai.yaml`.
The evaluation CLI constructs it, verifies that single-field diff, stages it in
an isolated Codex home, and runs the trigger suite before live cutover. A
passing report authorizes a metadata-only repository patch to the same value;
contract tests must verify that no other package byte changed. If host behavior
does not honor or reliably reload the policy, implicit invocation stays
disabled without blocking explicit-invocation qualification. Enabling Codex
implicit invocation additionally requires activation on at least seven of eight
positive trigger prompts and none of eight negative prompts. The report records
`QUALIFIED_EXPLICIT` or `QUALIFIED_IMPLICIT`; neither status authorizes global
installation without the separate cutover approval.

## Judging

Use fresh high-reasoning judges that receive only the task packet, private
rubric, and masked outputs. Prefer cross-provider judging: Claude judges Codex
outputs and Codex judges Claude outputs. A judge must cite output evidence for
every lost rubric point and must classify uncertainty separately from failure.

Judge exports use
`test/fixtures/prompt-engineer/schemas/judge-result-v1.yml` and the same
provider-specific normalization and canonical-digest rules as executor exports.
The record includes the native session and freshness evidence, exact model and
effort, judge configuration and tool inventory, masked-packet and private-rubric
digests, ordered opaque output labels, a score for every declared rubric point,
point-loss citations into normalized visible output, uncertainty classification,
exit status, and raw-export digest. The private label map remains unavailable to
the judge; `judge-ingest` binds opaque labels back to arm records only after it
validates all packet, rubric, and output digests.

Each private rubric assigns stable point IDs and integer weights to exactly one
scoring dimension. A dimension score is its declared maximum minus the weights
of unique failed points, bounded at zero. A loss without an output citation is
invalid unless the rubric point explicitly permits a missing-output citation.
The CLI rejects undeclared requirements, duplicate point losses, and arithmetic
that does not reproduce from the point records.

When an initial result is within one point, a second fresh judge reviews the
same masked packet. This uses the same primary-dimension predicate as executor
repeat selection. The packet's final dimension score is the lower score from
the two judges. If either judge marks material uncertainty, or the records
cannot be reconciled without adding a rubric requirement, mark the packet
`INCONCLUSIVE` and revise the corpus only in a new version.

## Repository integration

Implementation updates:

- `skills.yaml`: register `prompt-engineer` under `general` with
  `status: candidate`, Codex and Claude interfaces, all managed installs
  disabled, `recommended_model_tier: standard`, and
  `heavy_model_tier: deep`. The separate approved cutover changes status to
  `active` and enables only Codex and Claude; Cursor and Gemini remain disabled.
- `CATALOG.md`: add a `Candidate` row whose Install column says all targets are
  disabled pending qualification and cutover. The approved cutover changes it
  to `Active` and Codex/Claude enabled in the same commit as `skills.yaml`.
- `USAGE.md`: document explicit invocation, evaluation profiles, qualification,
  and the separate cutover gate.
- `scripts/prompt-engineer-eval`: implement the deterministic prepare, ingest,
  masking, scoring, and report surface. It does not launch agent hosts or live
  external actions.
- `scripts/prompt-engineer-sandbox`: launch the operator-selected host through
  a host adapter that enforces the staged filesystem, environment, credential,
  connector, and network policy and emits machine-verifiable attestation.
- `scripts/prompt-engineer-cutover`: implement `prepare`, `apply`, `verify`, and
  `rollback` against an explicit destination root. It refuses the real user
  homes unless given a qualified report digest and an explicit live flag.
- `test/prompt_engineer_skill_contract_test.rb`: validate package layout,
  frontmatter, metadata, forbidden authority-priming patterns, reference routes,
  catalog/manifest consistency, and the qualification policy.
- `test/prompt_engineer_evaluation_contract_test.rb`: validate corpus schema,
  case IDs, executor and judge export schemas, canonical digests, arm/package
  provenance, public/private export separation, point-level scoring,
  disagreement and repeat arithmetic, zero-tolerance gates, host coverage,
  budget enforcement, activation-candidate single-field diff, and report
  completeness.
- `test/prompt_engineer_sandbox_test.rb`: validate the attestation schema and
  prove with isolated probes that undeclared reads/writes, credential/keychain
  access, connectors, result-sink access, and non-provider network access fail
  for each supported host adapter; prove frozen package/input writes fail,
  post-run digest drift is rejected, and wrapper output descriptors are not
  inherited by evaluated tool subprocesses.
- `test/prompt_engineer_cutover_test.rb`: exercise isolated-home prepare,
  partial legacy moves, hash mismatch, first-target success plus second-target
  failure, torn final log records, earlier log corruption, power-loss recovery,
  symlink and parent-directory identity swaps, idempotent rollback, repeated
  rollback, required parent-directory syncs, and preservation of unrelated
  files and skills.
- `test/fixtures/prompt-engineer/`: store the versioned corpus and sanitized
  artifacts plus `legacy.lock.yml`; do not store generated run state.
- `docs/plans/2026-07-19-prompt-engineer-replacement-evaluation.md`: record the
  qualification environment, immutable corpus digest, arm provenance, raw
  result locations, scores, repeats, findings, and release decision.

The implementation plan adds shared qualification schema and arithmetic under
`test/support/` so scripts and tests do not duplicate the contract. It must not
add a runtime prompt-revision workflow engine.

## Static verification

Before forward testing:

1. Run the installed `quick_validate.py` separately for the skill package.
2. Parse `skills.yaml` and `agents/openai.yaml` as YAML.
3. Run the focused prompt-engineer contract, evaluation-contract, and cutover
   tests.
4. Run `scripts/test`.
5. Run `scripts/verify`.
6. Run `scripts/sync-skills --target codex --dry-run`.
7. Run `scripts/sync-skills --target claude --dry-run`.
8. Run `git diff --check` and confirm no state or generated artifacts are
   tracked.
9. Run `scripts/prompt-engineer-eval prepare` with fake host exports and the
   locked legacy source in a temporary directory; verify public-only workspace
   contents, exact arm/package provenance, executor and judge normalization,
   environment allowlist, masking, point arithmetic, and budgets.
10. Run the cutover prepare/apply/verify/rollback sequence against isolated
    temporary Codex and Claude destinations and verify restoration hashes,
    crash durability, torn-log handling, and path-race refusal.
11. Run sandbox self-probes for both host adapters and verify the emitted
    attestation digests bind to ingested executor records.

Because candidate install metadata is disabled, ordinary sync dry-runs must
show no prompt-engineer operation during implementation. A cutover-specific
temporary manifest is tested only against isolated destinations. Do not use
`scripts/sync-skills --apply` against live destinations during implementation
or qualification.

## Cutover and rollback

Qualification produces a report and stops. Global installation requires a
separate explicit user approval after the report is reviewed.

At approved cutover:

1. Revalidate the repository commit and qualification report digests.
2. Run `scripts/prompt-engineer-cutover prepare` to create an immutable
   `plan.json` recording the discovered Codex and Claude legacy paths, file
   types, ownership, modes, device/inode identities, hashes, candidate source,
   destinations, opened parent-directory identities, and ordered intended
   operations. Preparation writes a complete temporary file, `fsync`s it,
   atomically renames it into place, `fsync`s the containing directory, and
   refuses to replace it.
3. Run `apply` with the qualified report digest and explicit live flag. It moves
   each legacy skill directory and only its dedicated
   `scripts/skills/prompt_engineer` module into a timestamped, non-discovered
   backup directory, then installs the managed replacement links. Preserve the
   shared `scripts` root, `skills.lib` workflow framework, and every unrelated
   installed skill.
4. Perform mutations with descriptor-relative, no-follow filesystem operations
   anchored to the opened parent directories recorded by preparation. Before
   each mutation, revalidate ownership, mode, device/inode identity, file type,
   and hash; a symlink, mount, or path-identity change halts without mutation.
   After every rename, link, or unlink, `fsync` every affected parent directory.
5. Before and after every filesystem operation, append and `fsync` one canonical
   JSON object to `events.jsonl`: first an intent event, then its outcome. Events
   carry a monotonic sequence, operation ID, expected pre/post hashes, timestamp,
   and previous-event digest. Recovery accepts at most one torn, incomplete final
   line after validating the complete prefix's digest chain; any earlier malformed
   record or digest break halts. Atomically replace and durably sync a derived
   `state.json` cache after each completed outcome; it is never recovery
   authority. After a crash between intent and outcome, reconcile the live path
   against the immutable plan's exact pre/post identities and hashes and append
   the recovered outcome. Any third state halts without further mutation. Any
   other failure immediately invokes the same idempotent rollback routine; a
   rollback failure stops and reports exact remaining operations without
   attempting unrelated cleanup.
6. Run `verify` to confirm every installed path is the expected repository
   symlink, every backup hash matches, and every unrelated sibling is unchanged.
7. Start fresh Codex and Claude sessions and verify discovery, explicit
   invocation, and one read-only smoke case.
8. If the activation candidate qualified, apply the single-field implicit
   metadata patch, verify its digest, start a fresh Codex session, and rerun the
   trigger smoke suite. Otherwise keep implicit invocation disabled.

Rollback is `scripts/prompt-engineer-cutover rollback --transaction PATH`. It
reconstructs progress from `plan.json`, `events.jsonl`, and the live filesystem,
not `state.json`. It removes only replacement symlinks named in the plan,
restores recorded legacy paths and companion dependencies, verifies hashes, and
is safe to run again after success or partial failure. It never deletes
evaluation evidence or changes unrelated installed skills.

Keep the backup until five qualifying real uses complete on each host. A
qualifying use is a distinct task where the skill was actually invoked, reached
a final diagnosis or candidate recommendation, and produced no safety failure,
unwanted activation, user-reported material error, or workflow abort. Record
timestamp, host and model versions, invocation mode, anonymized task category,
outcome, and evidence location in the transaction's post-cutover log. Backup
removal requires a separate explicit cleanup request. Rerun focused
qualification before enabling implicit invocation after a host discovery-policy
change, and rerun full qualification after a material `SKILL.md` or reference
change, a default model-family change, or any zero-tolerance/material regression.

## Failure handling

- If the target runtime cannot be reproduced, use the quick profile and label
  conclusions as unmeasured, or stop with `INCONCLUSIVE` when measurement is
  required.
- If legacy and replacement dependencies cannot coexist safely, run them in
  isolated temporary homes rather than modifying live global paths.
- If a case exposes a corpus ambiguity, version the corpus and rerun every arm
  affected by the change. Do not edit a rubric after seeing outputs and retain
  the old score.
- If either host cannot enforce equivalent tools or configuration, report the
  host comparison separately; do not pool incomparable results.
- If qualification misses a release threshold, keep the legacy installation,
  record the failure, and revise only the bounded defect demonstrated by the
  evidence.
- If the replacement regresses after cutover, stop implicit invocation, restore
  the backup, and retain the failing real-use artifact as a future corpus case.

## Acceptance criteria

Repository implementation is complete when:

1. The lean package exists under `skills/general/prompt-engineer/` with no
   extraneous files or external runtime dependency.
2. `skills.yaml`, `CATALOG.md`, and `USAGE.md` describe the same interfaces,
   tiers, `Candidate` status, invocation, and disabled install policy.
3. Contract tests enforce trigger scope, package boundaries, safety rules, and
   evaluation policy.
4. The twelve-case corpus, trigger suite, legacy lock, and canonical digest pass
   schema, host-coverage, and contamination checks.
5. The evaluation CLI passes fake-export integration tests for staging,
   public-only packet creation, executor/judge normalization, arm and package
   provenance, masking, point-level judging, repeats, frozen budgets, score
   boundaries, and report generation.
6. Both sandbox host adapters pass isolation self-probes and emit attestations
   accepted by fake-export ingestion.
7. The cutover command passes isolated-home normal, partial-failure, torn-log,
   path-race, power-loss, idempotency, and rollback tests without touching live
   global paths.
8. Static verification and Codex/Claude sync dry-runs complete with exact
   results recorded.
9. No global skill link, configuration, or legacy installation changes before
   separate explicit cutover approval.

Qualification is complete when:

1. The report contains native arm/package and judge provenance, sandbox
   attestations, environment details, corpus and packet digests, frozen budgets,
   scores, repeats, zero-tolerance results, trigger results, and a clear
   `QUALIFIED_EXPLICIT`, `QUALIFIED_IMPLICIT`, `NOT_QUALIFIED`, or
   `INCONCLUSIVE` decision.
2. A qualified result satisfies every applicable release threshold above; an
   explicit-only result leaves implicit invocation disabled.
3. Raw run records remain immutable at the report's recorded external location
   and every record digest is included in the report.
4. Qualification failure or host unavailability does not reopen repository
   implementation unless it demonstrates a bounded implementation defect.

## Security and privacy

Evaluation fixtures must be synthetic or sanitized. Do not commit proprietary
prompts, secrets, credentials, private conversation content, unpublished source
data, or raw agent histories. Store only the minimum artifact required to
reproduce the behavior, plus a digest when raw data must remain outside the
repository.

The evaluation CLI exports executor workspaces from a strict allowlist and then
verifies that no private file name, digest, rubric phrase, or path exists beneath
their filesystem root. Judges receive the private rubric and masked outputs but
not arm identities. An executor never receives the repository checkout that
contains `private.yml`.

`scripts/prompt-engineer-sandbox` is the checked-in launch boundary used by the
operator instructions emitted from `prepare`; raw host commands are not valid
qualification launches. Its host adapters start Codex or Claude with an
OS-enforced write allowlist limited to the case's declared worktree, output,
and scratch paths. Staged skill bytes, host configuration, task packet, and
immutable inputs are read-only. The wrapper rehashes every frozen input and
package after the host exits and rejects the record if any digest changed.
The raw-export stream, host session store, launch attestation, and result sink
are parent/wrapper-only and outside the evaluated tool sandbox; their file
descriptors are never inherited by tool subprocesses. The wrapper writes raw
events directly or copies the closed host session export only after the host
exits, then seals its digest before normalization. Reads additionally permit
only a frozen read-only runtime
allowlist for the host executable, dynamic libraries, OS device files, and CA
certificates required to reach the provider; user homes, the source repository,
and private fixture roots remain denied. The launch record contains the wrapper
and sandbox-profile digests, staged-root device/inode identities, runtime-root
allowlist, environment-key allowlist, network endpoint allowlist, and self-probe
results proving that undeclared reads and writes, credential/keychain access,
result-sink access, and non-provider network access fail. The executor-result
record binds this launch attestation digest. If an adapter cannot separate host
control-plane output from evaluated tool capabilities or cannot enforce and
attest these boundaries, qualification for that host is `INCONCLUSIVE`.

Forward tests run in disposable homes and remote-free repositories. The parent
host process may use only its model provider's authenticated transport through
a recorded endpoint allowlist. Provider authentication stays in a parent-only
credential broker, file descriptor, or host session and is never inherited by
the evaluated agent's tool subprocesses.

The evaluated tool environment denies general network and reads or writes
outside declared sandbox roots.
Preparation builds an explicit environment allowlist, removes every credential
except parent-only host authentication, unsets `SSH_AUTH_SOCK`, refuses inherited
agent/keychain bridges, disables host connectors and MCP servers, and records
the exposed tool inventory and provider endpoint probe. Production, publication,
messaging, billing, deployment, and destructive tools are absent. If a host
cannot separate provider transport and authentication from tool capabilities,
or the operator cannot verify those boundaries, the run stops `INCONCLUSIVE`;
a temporary home alone is never treated as isolation evidence.

## Design invariants

1. No claim of improvement without comparative evidence appropriate to the
   selected profile.
2. Technique attribution never substitutes for behavioral evaluation.
3. Prompt edits may remove or restructure text.
4. Authorization and higher-priority instructions may never be invented,
   weakened, or moved to a lower-trust layer.
5. Non-prompt root causes stop prompt editing.
6. Qualification runners and judges use fresh, minimally informed contexts.
7. Evaluation rubrics are frozen before outputs are generated.
8. Global cutover is explicit, reversible, and separate from qualification.
9. The legacy package remains recoverable until post-cutover evidence satisfies
   the retention gate.
10. Cursor and Gemini remain disabled until host-specific evidence exists.
