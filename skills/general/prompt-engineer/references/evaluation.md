# Evidence profiles

Choose the smallest profile that can support the requested decision. A profile
controls the amount of context and comparison, not the confidence of the
language used in the final report.

## Quick

Use for a low-risk local question where the user wants a proposal or diagnosis,
not a consequential behavior claim. Establish the target and constraint, check
for non-prompt causes, and inspect a representative input. A wording proposal
may be useful, but call it a proposal unless a comparison was actually run.

### Minimum acceptance

The Quick profile's comparable evidence is a check of the proposal against the
stated target, constraints, and one representative input. `Supported` is
allowed only when the target and constraint are explicit, the representative
input meets the observable success criteria, and every zero-tolerance failure
check passes. Quick cannot support a behavioral improvement claim without a
baseline/candidate comparison; if its required evidence is missing, use
`INCONCLUSIVE`.

## Standard

Use for a consequential change to one prompt or one prompt-bearing skill.

1. Record the baseline prompt, representative cases, tools and data, success
   criteria, and zero-tolerance failures.
2. Create one minimal candidate and record its exact text.
3. Run baseline and candidate in fresh, equivalent contexts with symmetric
   inputs and available tools. Mask or randomize variant labels where practical.
4. Evaluate the same criteria for baseline and candidate, record regressions
   and missing observations, and decide whether the claim is supported.

### Minimum acceptance

The Standard profile's comparable evidence is a baseline and candidate run in
fresh, equivalent contexts with symmetric inputs, tools, and data. Evaluate the
same criteria for baseline and candidate. `Supported` is allowed only when the
candidate meets the success criteria, every candidate zero-tolerance failure
check passes, and the candidate introduces no regression. Baseline failure is
comparison evidence, not an automatic rejection; a passing candidate can be
`Supported` even when the baseline fails under those conditions. If the paired
comparison or any required evidence is missing, use `INCONCLUSIVE`.

If the contexts, inputs, tools, or observations are not comparable, report
`INCONCLUSIVE` rather than filling the gap with confidence or authority.

## Ecosystem

Use when a prompt change affects a skill, handoff, planner/worker pair, or
multiple stages. Map each producer to the fields and invariants consumed by
the next stage. Evaluate representative end-to-end flows as well as the local
prompt. A shorter or more fluent local response is not an improvement if it
drops authorization, constraints, verification truth, required fields, or the
outer schema.

### Minimum acceptance

The Ecosystem profile's comparable evidence is a baseline and candidate
comparison over representative end-to-end flows plus each affected
producer-consumer contract. `Supported` is allowed only when every affected
boundary preserves its contract, the end-to-end success criteria pass, and all
zero-tolerance failure checks pass. If a stage, boundary, comparison, or other
required evidence is missing, use `INCONCLUSIVE`.

## Scoring and claims

Use a small, explicit scorecard:

- **Task success:** did the response satisfy the stated user goal?
- **Contract fidelity:** did it preserve required fields, boundaries, and
  downstream assumptions?
- **Truthfulness:** are actions, evidence, and limitations represented exactly?
- **Efficiency:** did it reduce unnecessary work without shifting risk or
  hidden cost to another stage?

Record observations, not impressions. A scorecard can be qualitative when the
request is small; it should still name the case and the observed outcome.

Use these decision labels:

- **Supported:** the candidate meets the success criteria and no
  zero-tolerance failure appeared in the comparable check.
- **Unsupported:** the proposed benefit was not demonstrated, even if the
  candidate is safe to keep as a proposal.
- **Regressed:** the candidate introduces a failure or breaks a contract that
  the baseline preserved.
- **INCONCLUSIVE:** required context, authorization, a fair comparison, or a
  decisive observation is missing.

Do not present a persuasive explanation, technique name, or claimed authority
as evidence. State the scope of the result, the cases observed, what was not
tested, and the next smallest useful check.

A profile may not receive the `Supported` label when its required evidence or
zero-tolerance check is missing; missing required evidence forces
`INCONCLUSIVE`.

## Regression handling

When a candidate fails, preserve the failure details and identify the earliest
stage where behavior diverged. Revert the candidate only when authorized; an
unauthorized rollback is still an external action. For an ecosystem failure,
keep the downstream contract visible and propose a coordinated schema change
instead of silently changing one worker prompt.

## Evidence boundary

Do not fabricate provider output, tool execution, repository state, costs, or
host discovery. If live or external evidence is unavailable, use local
artifacts only for the claims they can support and label the overall result
`INCONCLUSIVE` when the missing evidence is decisive.
