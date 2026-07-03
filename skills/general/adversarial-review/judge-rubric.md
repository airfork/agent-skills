# Judge Rubric

Judges are read-only and must actively try to refute each candidate. A candidate survives only when the judge can explain why the issue is real, cite evidence, and name the consequence.

## Cull Task

Input: a group of candidate findings at one document location, the reviewed docs, and the relevant repo context.

Output JSON only:

```json
{
  "verdicts": [
    {
      "candidate_index": 0,
      "disposition": "PROMOTE|REFUTE",
      "confidence": 0.0,
      "category": "Omission|Ambiguity|Inconsistency|Incorrect fact|Extraneous",
      "severity": "CRITICAL|HIGH|MEDIUM|LOW",
      "evidence": "quote or cite the refuting/promoting evidence",
      "consequence": "what breaks if unfixed"
    }
  ]
}
```

Rules:

- Confidence below `0.7` means `REFUTE`; do not report it.
- Burden of proof is on refutation and promotion. A refutation must cite the document or repo fact that disproves the candidate.
- Promotion requires a concrete consequence. "Could be clearer" is not enough.
- Quote evidence for every criterion used: category, severity, refutation, consequence, and resolution.
- Do not suppress a real issue because a future implementer might notice it.
- Do not promote broad redesign requests that exceed the document's stated goal.

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
      "id": "AR-001",
      "status": "resolved|rejected|stuck",
      "evidence": "quote the resolving edit, accepted rejection, or remaining problem",
      "notes": "short rationale"
    }
  ],
  "new_findings": []
}
```

Status rules:

- `resolved`: quote the edit that removes the issue.
- `rejected`: quote or summarize the author's rejection and explain why it is acceptable.
- `stuck`: the issue remains, the rejection is not justified, or two fix attempts failed.

In round 2 only, include `new_findings` for regressions introduced by revision. New `CRITICAL` or `HIGH` findings prevent a passing verdict.

## Arbiter

At `--high` and `--ultra`, arbitrate stuck findings before sending them to the user.

Input: document section, finding, judge position, and author position. Do not include the full conversation.

Output JSON only:

```json
{
  "id": "AR-001",
  "ruling": "author-is-right|judge-is-right|needs-human",
  "evidence": "quote the decisive evidence",
  "consequence": "what follows from the ruling"
}
```

Rulings against the author remain open questions. `needs-human` remains an open question.
