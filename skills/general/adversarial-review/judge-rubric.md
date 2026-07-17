# Judge Rubric

Judges are read-only and must actively try to refute each candidate. A candidate survives only when the judge can explain why the issue is real, cite evidence, and name the consequence.

## Cull Task

Input: a group of candidate findings at one document location, the reviewed docs, and the relevant repo context.

Candidate IDs are immutable after ingestion and use `C-<angle-slug>-<attempt>-<sequence>`; every later role returns those IDs instead of batch-local indexes. Dedupe must map every candidate ID to exactly one group and must not renumber or rewrite candidate IDs.

Output JSON only:

```json
{
  "schema_version": 1,
  "run_id": "ar-20260717-example",
  "task_id": "judge-rollout-1",
  "artifact_digests": {"docs/spec.md": "<64 lowercase hex SHA-256>"},
  "verdicts": [
    {
      "candidate_id": "C-assumptions-checker-1-1",
      "disposition": "PROMOTE|REFUTE|UNPROVEN",
      "confidence": 0.0,
      "category": "Omission|Ambiguity|Inconsistency|Incorrect fact|Extraneous",
      "severity": "CRITICAL|HIGH|MEDIUM|LOW",
      "evidence": "quote or cite the refuting/promoting evidence",
      "consequence": "what breaks if unfixed"
    }
  ],
  "metrics": {},
  "notes": []
}
```

Rules:

- Confidence below `0.7` cannot produce `PROMOTE`; return `REFUTE` only when evidence disproves the candidate, otherwise return `UNPROVEN`.
- Burden of proof is on refutation and promotion. A refutation must cite the document or repo fact that disproves the candidate. `UNPROVEN` records an evidence gap; it is neither a promotion nor a refutation.
- Promotion requires a concrete consequence. "Could be clearer" is not enough.
- Quote evidence for every criterion used: category, severity, refutation, consequence, and resolution.
- Do not suppress a real issue because a future implementer might notice it.
- Do not promote broad redesign requests that exceed the document's stated goal.

At `--ultra`, aggregate three independent votes only when at least two voters independently meet the evidence burden for the same `PROMOTE` or `REFUTE` disposition. Any split involving `UNPROVEN` goes to arbitration and is never counted as a refutation.

## Categories

| Category | Use when |
|----------|----------|
| Omission | Required information, step, decision, test, owner, dependency, or acceptance criterion is missing. |
| Ambiguity | Multiple reasonable implementations or validations could satisfy the text but differ materially. |
| Inconsistency | The document contradicts itself, the companion plan/spec, or applicable repo guidance. |
| Incorrect fact | The document names a file, API, command, schema, behavior, or platform fact that is wrong. |
| Extraneous | The document adds work that is not supported by the goal and creates cost or risk. |

## Severity Gates

| Severity | Gate |
|----------|------|
| CRITICAL | The spec/plan is not safely executable: impossible sequence, wrong security boundary, destructive operation without guard, missing migration/rollback for high-impact data, or contradiction that can ship a severe failure. |
| HIGH | Likely implementation failure, major scope drift, missing required validation, broken install/deploy path, or ambiguity that can produce incompatible implementations. |
| MEDIUM | Meaningful rework, test gap, maintainability trap, incomplete edge case, or local ambiguity with a bounded workaround. |
| LOW | Minor but real cleanup, wording, traceability, or polish issue with low implementation risk. |

Assign the highest severity whose gate is met. Do not inflate severity for volume.

## Stable IDs And Caps

The parent assigns stable IDs after cull:

```text
AR-001
AR-002
AR-003
```

Keep at most 50 reported findings. If more than 50 survive, report the top 50 by severity and confidence, then aggregate overflow by category and severity.

## Resolution Check

Resolution checks are per finding ID, never holistic re-scores.

Input: finding ID, original finding, current document section, and the author's fix or rejection.

Output JSON only:

```json
{
  "checks": [
    {
      "finding_id": "AR-001",
      "status": "RESOLVED|UNRESOLVED|REGRESSED",
      "evidence": "quote the resolving edit, accepted rejection, or remaining problem"
    }
  ],
  "new_findings": []
}
```

Status rules:

- `RESOLVED`: quote the edit that removes the issue or the evidence that accepts a justified author rejection.
- `UNRESOLVED`: quote the remaining issue or explain why the rejection is not justified.
- `REGRESSED`: quote a revision that made the original finding worse.

In round 2 only, include `new_findings` for regressions introduced by revision. New `CRITICAL` or `HIGH` findings prevent a passing verdict.

## Arbiter

At `--high` and `--ultra`, arbitrate stuck findings before sending them to the user.

Input: document section, finding, judge position, and author position. Do not include the full conversation.

Output JSON only. Candidate disputes use `PROMOTE|REFUTE|UNPROVEN`; author-resolution disputes use `RESOLVED|UNRESOLVED`. Each decision includes `subject_id`, `confidence`, `evidence`, and every related immutable candidate ID in `mapped_candidate_ids`.

```json
{
  "subject_id": "AR-001",
  "decision": "UNRESOLVED",
  "confidence": 0.9,
  "evidence": "quote the decisive evidence",
  "mapped_candidate_ids": ["C-assumptions-checker-1-1"]
}
```

Map the semantic ruling deterministically:

- `author-is-right` -> `REJECTED`
- `judge-is-right` -> `UNRESOLVED`
- `needs-human` -> `UNRESOLVED`

For the schema payload, encode `author-is-right` as `RESOLVED` and persist the resulting finding state as `rejected`. Encode both other rulings as `UNRESOLVED`; persist `judge-is-right` as `contested` and then `stuck` at the round cap, while `needs-human` remains `contested` and can never yield an ordinary `PASSED` verdict.
