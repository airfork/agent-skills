# Verifier Verdict Rubric

Give the verdict ladder to every verifier subagent verbatim. At `high` and `deep`, also include the recall rules section verbatim.

## Task

Verify the candidate issue(s) at ONE location from a code-review finder. Read the candidates, the relevant diff hunks, the surrounding file(s), and any caller/consumer/schema/config/migration or guidance context the claims depend on. Judge each candidate independently on its own claim and return one verdict per candidate.

There is no numeric score. The burden of proof is on refuting: a verdict of REFUTED must be constructible from the code, not from doubt.

## Verdict Ladder

```text
- **CONFIRMED** — can name the inputs/state that trigger it and the wrong
  output or crash. Quote the line.
- **PLAUSIBLE** — mechanism is real, trigger is uncertain (timing, env,
  config). State what would confirm it.
- **REFUTED** — factually wrong (code doesn't say that) or guarded elsewhere.
  Quote the line that proves it.
```

## Recall Rules (`high` and `deep` only)

```text
**PLAUSIBLE by default** — do not refute a candidate for being "speculative" or
"depends on runtime state" when the state is realistic: concurrency races,
nil/undefined on a rare-but-reachable path (error handler, cold cache, missing
optional field), falsy-zero treated as missing, off-by-one on a boundary the
code does not exclude, retry storms / partial failures, regex/allowlist that
lost an anchor. These are PLAUSIBLE.
**REFUTED** only when constructible from the code: factually wrong (quote the
actual line); provably impossible (type/constant/invariant — show it); already
handled in this diff (cite the guard); or pure style with no observable effect.
```

## Rules

- Verify only the review target, including untracked files when explicitly in scope. Unchanged lines inside a function the diff touches are in scope; files the diff never touches are not.
- For conventions candidates, the guidance file must explicitly state the rule. Quote it. Do not infer policy from vague language.
- For cleanup/altitude/conventions candidates, the failure scenario is a concrete cost (duplication, wasted work, maintainability, quoted rule broken) rather than a crash; judge whether that cost is real, not whether it crashes.
- Evidence must quote or cite the relevant line(s). A REFUTED verdict without a quoted guard, type, or contradicting line is not a refutation — return PLAUSIBLE instead.
- Do not confirm a candidate whose only claim is that CI, lint, or typecheck would fail; synthesis drops those. Do confirm it when the diff and context prove a real runtime, integration, migration, security, or user-visible failure.

## Output

JSON only, one verdict per candidate index:

```json
{"verdicts":[{"index":0,"verdict":"CONFIRMED|PLAUSIBLE|REFUTED","evidence":"quote or cite the relevant line(s)"}]}
```
