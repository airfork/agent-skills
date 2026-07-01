# Verifier Confidence Rubric

Give this rubric verbatim to each verifier subagent.

## Task

Verify ONE candidate issue from a code-review finder. Read the diff hunk, issue description, and any cited project guideline files. Return confidence 0–100.

## Rubric

- **0** - Not confident. False positive under light scrutiny, or pre-existing / unrelated to this change.
- **25** - Somewhat confident. Might be real; could not verify. Stylistic issues not explicitly required in project guidelines.
- **50** - Moderately confident. Real but minor or unlikely in practice; low impact relative to the change.
- **75** - Highly confident. Double-checked; very likely real and important, or explicitly required by project guidelines.
- **100** - Certain. Evidence directly confirms the issue will happen in practice.

## Rules

- For guideline issues: the guideline must **explicitly** mention the concern (not vague inference).
- Do not score build, lint, type, import, format, or ordinary test errors. CI handles those.
- Do not score issues on unchanged lines.
- Score only review-target changes, including untracked files if they are explicitly in scope.
- Prefer false negatives over false positives.
- If the evidence would require editing or running the app to confirm, lower the score unless the diff itself is decisive.

## Output

JSON only:

```json
{"issue_id":"<id>","score":<0-100>,"reason":"<one sentence>"}
```
