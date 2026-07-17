# Attack Angles

Each attacker gets the same packet, one angle, and a fresh read-only context. Attackers may read repository files needed to check claims. They must output JSON only.

## Normative Attack Result

Every attacker and divergence probe must return the current artifact digests and the checks it actually completed. Paths identify the reviewed artifact, digests are 64-character lowercase hexadecimal SHA-256 values, and locations are structured records rather than `path:line` strings.

Common output:

```json
{
  "schema_version": 1,
  "run_id": "ar-20260717-example",
  "task_id": "attack-assumptions-1",
  "angle": "angle name",
  "artifact_digests": {"docs/spec.md": "<64 lowercase hex SHA-256>"},
  "checks_completed": ["named check actually performed"],
  "findings": [
    {
      "location": {"path": "docs/spec.md", "line_start": 12, "line_end": 14, "heading": "Rollout"},
      "category": "Omission|Ambiguity|Inconsistency|Incorrect fact|Extraneous",
      "summary": "concrete defect",
      "evidence": "quote from doc or repo evidence",
      "consequence": "what breaks if unfixed"
    }
  ],
  "metrics": {},
  "notes": []
}
```

The `attack` schema in `assets/schemas/attack.json` is the closed, executable contract. Do not add metadata or substitute prose locations. Record only checks that were actually performed; a missing required check may be retried by the control plane.

Do not include weak preferences. A finding needs a concrete consequence for implementation, testing, user behavior, safety, security, schedule risk, or maintainability.

## Constructive Reader: Implementer

Enabled when a spec is present.

Procedure:

1. Build a file-by-file implementation sketch from the spec.
2. For each file or module the spec implies, identify inputs, outputs, state, and dependencies.
3. Log every point the spec cannot support without guessing.
4. Check named repo APIs, paths, schemas, commands, and existing patterns when the spec relies on them.

Findings are usually omissions, ambiguities, or incorrect facts.

## Constructive Reader: Tester

Enabled when a spec or plan is present.

Procedure:

1. Build a concrete test plan from the document.
2. Identify acceptance criteria that are untestable, subjective, or missing expected outputs.
3. Check whether proposed tests match existing test frameworks and commands.
4. Flag missing negative, boundary, rollback, migration, concurrency, or failure-path tests only when the document's goal depends on them.

Include a `metrics.testable_criteria_percent` value when measurable.

## Constructive Reader: User

Enabled when user-facing or operator-facing behavior is described.

Procedure:

1. Walk end-to-end scenarios from the target user's point of view.
2. Include setup, first use, normal path, error path, recovery, and repeated use.
3. Log gaps, dead ends, missing states, or copy/behavior contradictions.
4. Check repo UI/CLI/API affordances when the document names them.

Do not invent new product requirements. Only report gaps that affect stated goals.

## Coverage Mapper

Enabled only when both spec and plan are present.

Procedure:

1. Extract requirement IDs or create stable short labels from spec bullets.
2. Extract plan tasks and verification steps.
3. Map requirement to task and task to requirement.
4. Report missing, partial, duplicated, and extraneous coverage.

Add these metrics:

```json
{
  "requirements_total": 0,
  "requirements_covered": 0,
  "coverage_percent": 0,
  "unmapped_tasks": 0
}
```

Findings should cite exact requirement and task labels.

## Assumptions Checker

Enabled for every review.

Procedure:

1. Extract stated assumptions.
2. Infer unstated load-bearing assumptions from commands, APIs, owners, migrations, permissions, data shape, availability, and sequencing.
3. Define the failure condition for each assumption.
4. Check cheap repo evidence for whether the assumption is true, false, or unproven.

Report assumptions whose failure would invalidate the spec or plan.

## Pre-Mortem Writer

Enabled for every review.

Procedure:

1. Assume the project shipped and failed.
2. Write the likely failure narrative from the document's own commitments.
3. Trace that failure back to missing requirements, ambiguous sequencing, wrong facts, or extraneous work.
4. Convert only evidence-backed failure causes into findings.

Do not report generic risks that apply to any project.

## Consistency And Smells Scanner

Enabled for every review.

Procedure:

1. Scan for contradictions, terminology drift, impossible ordering, and mismatched flags, tiers, paths, or roles.
2. Flag Tier 1 smells freely: `TBD`, `TODO`, incomplete placeholders, escape clauses such as "as appropriate", and subjective success criteria without a measure.
3. Check context before flagging Tier 2 smells: comparatives, negatives, vague pronouns, optional language, and conditionals.
4. Verify whether each smell affects implementation or validation before reporting.

Findings must quote the conflicting or smelly text.

## Feasibility Checker

Enabled when a plan is present.

Procedure:

1. Verify plan steps against the actual repository.
2. Check that referenced files, scripts, tests, commands, APIs, schemas, package managers, and setup assumptions exist.
3. Check step sequencing: a later step must not depend on an artifact that is never created.
4. Check that verification commands can actually validate the claimed behavior.

Report buildability, sequencing, or verification defects.

## Spec-Plan Drift

Enabled only when both spec and plan are present.

Procedure:

1. Compare spec commitments to plan tasks.
2. Compare plan implementation details to spec intent.
3. Flag contradictions, missing work, extra work, changed scope, and mismatched acceptance criteria.
4. Prefer exact paired citations: one spec quote and one plan quote.

Findings should make the drift direction explicit: spec missing in plan, plan extra, or contradiction.

## Divergence Probe

Enabled only at `--high` and `--ultra` when a spec is present. For plan-only reviews, skip this angle and disclose that the divergence probe needs a spec.

Procedure:

1. Spawn three independent attackers from the spec alone.
2. Each attacker produces a concrete implementation outline, not critique.
3. The parent diffs the outlines for materially different architecture, state model, API, sequencing, validation, or rollout assumptions.
4. Treat divergence as empirical ambiguity evidence and send it through cull.

Each divergence task uses one immutable `probe_id` (`probe-1`, `probe-2`, or `probe-3`), states its concrete `hypothesis`, and otherwise uses the same envelope, findings, structured locations, artifact digests, checks, metrics, and notes as the common attack result.

Attacker output follows `assets/schemas/divergence.json`:

```json
{
  "schema_version": 1,
  "run_id": "ar-20260717-example",
  "task_id": "divergence-1",
  "angle": "divergence-probe",
  "probe_id": "probe-1",
  "hypothesis": "The rollout is implemented as an explicit state machine.",
  "artifact_digests": {"docs/spec.md": "<64 lowercase hex SHA-256>"},
  "checks_completed": ["implementation outline", "state model", "verification path"],
  "findings": [],
  "metrics": {},
  "notes": []
}
```

Only promote divergence that would lead to incompatible implementations.
