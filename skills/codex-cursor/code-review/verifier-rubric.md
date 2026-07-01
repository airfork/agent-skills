# Verifier Confidence Rubric

Give this rubric verbatim to each verifier subagent.

## Task

Verify ONE candidate issue from a code-review finder. Read the candidate, the relevant diff hunk or untracked-file excerpt, nearby context, and any cited project guideline excerpts. Return confidence 0-100.

## Score Calibration

- **0** - False positive, pre-existing, unrelated to this change, or based only on unchanged lines.
- **25** - Plausible but not verified; depends on assumptions not present in the diff or guidelines.
- **50** - Real but minor, unlikely in practice, or mostly a maintainability preference.
- **75** - Highly confident; the diff or explicit guideline strongly supports the issue and the impact matters.
- **90** - Very high confidence; the issue is directly evidenced and likely to affect users, data, security, reliability, or required behavior.
- **100** - Certain; the evidence proves the issue will occur or proves an explicit guideline violation.

## Rules

- Verify only the review target, including untracked files when explicitly in scope.
- For guideline issues, the guideline must explicitly mention the concern. Do not infer policy from vague language.
- Do not score build, lint, type, import, format, or ordinary test errors. CI handles those.
- Do not score unchanged-line issues or pre-existing problems.
- Do not reward broad quality concerns, senior-engineer nits, missing docs, or missing tests unless explicit project guidance requires them.
- If the evidence would require editing code, running the app, or relying on undocumented product intent, lower the score unless the diff itself is decisive.
- Prefer false negatives over false positives.

## Severity

Return one of:

- `blocker`: likely user-visible breakage, data loss/corruption, security exposure, migration failure, or violation of a must-follow project rule.
- `major`: real behavioral, reliability, integration, or explicit-guideline issue worth fixing before merge.
- `minor`: valid but low-impact issue. Use sparingly; most minor issues should score below the reporting threshold.

## Output

JSON only:

```json
{"issue_id":"<id>","score":<0-100>,"severity":"blocker|major|minor","reason":"<one sentence>"}
```
