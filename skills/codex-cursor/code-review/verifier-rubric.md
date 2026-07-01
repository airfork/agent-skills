# Verifier Confidence Rubric

Give this rubric verbatim to each verifier subagent.

## Task

Verify ONE candidate issue from a code-review finder. Read the candidate, the relevant diff hunk or untracked-file excerpt, nearby context, relevant caller/consumer/schema/config/migration context, and any cited project guideline excerpts. Return confidence 0-100.

Score confidence in whether the issue is real, introduced by the review target, and reportable. Do not encode impact in the score; use severity for impact.

## Score Calibration

- **0** - False positive, pre-existing, unrelated to this change, or based only on unchanged lines.
- **25** - Plausible but not verified; depends on assumptions not present in the diff, context, or guidelines.
- **50** - Some evidence supports the issue, but a key link still depends on an assumption or incomplete context.
- **75** - Highly confident; the diff plus context or an explicit guideline strongly supports a real introduced issue.
- **90** - Very high confidence; the issue is directly evidenced by the diff plus context and is reportable.
- **100** - Certain; the evidence proves the issue will occur or proves an explicit guideline violation.

## Rules

- Verify only the review target, including untracked files when explicitly in scope.
- For guideline issues, the guideline must explicitly mention the concern. Do not infer policy from vague language.
- Do not score ordinary build, lint, type, import, format, or test failures whose only evidence is "CI will fail." Do score them when the diff and context prove a real runtime, integration, migration, security, or user-visible failure.
- Do not score unchanged-line issues or pre-existing problems.
- Do not reward broad quality concerns, senior-engineer nits, missing docs, or missing tests unless explicit project guidance requires them.
- If the evidence would require editing code, running the app, or relying on undocumented product intent, lower the score unless the diff plus static context is decisive.
- Use open verification questions before scoring severe candidates: "What failure mode follows from this change?", "Which caller/consumer contract is broken?", or "Which explicit requirement is violated?"
- Keep false-positive control for minor/style/quality concerns. For blocker-class candidates, prefer a lower score with a clear reason over dismissing the candidate because the proof is cross-file.

## Severity

Return one of:

- `blocker`: likely user-visible breakage, data loss/corruption, security exposure, migration failure, or violation of a must-follow project rule.
- `major`: real behavioral, reliability, integration, or explicit-guideline issue worth fixing before merge.
- `minor`: valid but low-impact issue. Use sparingly; most minor issues should score below the reporting threshold.

## Output

JSON only:

```json
{"issue_id":"<id>","score":<0-100>,"severity":"blocker|major|minor","disposition":"valid|false-positive|pre-existing|unchanged-line|speculative|ordinary-ci","reason":"<one sentence>"}
```

Use `valid` only for real introduced reportable issues. Use the other dispositions to make drop reasons machine-readable.
