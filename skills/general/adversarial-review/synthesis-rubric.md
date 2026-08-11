# Synthesis Rubric

One pass, `opus` at effort `high`. Input is at most eight candidate findings
whose quotes already passed mechanical verification, plus the full target text.
Output conforms to `assets/schemas/synthesis.json`.

**Your job is to reject.** Four independent reviewers each produced their best
two findings; that process is tuned for recall, and most of what reaches you is
noise. Default to dropping. Ship at most three findings, and ship fewer when
fewer deserve it.

**Zero findings is a correct, valuable outcome.** A review that returns nothing
tells the author their plan survived four hostile readings. Never pad toward
three to look thorough. Never promote the least-bad candidate for want of a
better one.

## Reject

Drop a candidate for any of these, without appeal:

- **No concrete failure.** The finding describes a property of the document
  ("underspecified", "could be clearer") rather than something that breaks.
- **Document hygiene.** Style, terminology drift, formatting, section ordering,
  missing cross-references, `TODO`/`TBD` markers, absent boilerplate.
- **Resolvable in passing.** A competent implementer hitting this would answer
  it from surrounding context in under a minute.
- **Invented requirement.** The finding faults the document for not doing
  something it never set out to do.
- **Generic risk.** It would apply verbatim to any project of this shape. If you
  could paste the finding into an unrelated plan and it would still read as
  true, drop it.
- **Quote does not indict.** The quote is present in the file but does not
  actually support the claim made about it.
- **Speculative chain.** The failure requires two or more unstated things also
  to go wrong.

## Merge

Independent angles converge on the same defect often. Merge candidates that name
the same underlying defect even when they quote different lines, keep the
sharpest quote and the most concrete failure statement, and record every
contributing angle in `source_angles`. Convergence is evidence of severity, not
a reason to ship the finding two or three times.

## Rank

Order survivors by the cost of discovering the problem later — how far into
implementation the author gets before it bites, and how much work unwinds when
it does. A defect that invalidates the architecture outranks one that costs an
afternoon, even when the afternoon is more certain.

Assign severity honestly:

- `CRITICAL` — the plan cannot be implemented as written, or implementing it
  causes data loss, a security hole, or an unrecoverable migration.
- `HIGH` — a substantial rewrite becomes necessary once discovered.
- `MEDIUM` — real cost, contained; a day or so of rework.

There is no `LOW`. A finding that would be `LOW` is a finding you should have
dropped.

## Output

For each survivor: severity, path and location, the verbatim quote, the concrete
failure, the contributing angles, and a one-sentence description of what would
resolve it. The resolution is a suggestion for the author, who decides — this
skill does not edit documents.

State how many candidates you received and how many you dropped. That ratio is
how the author calibrates trust in the review.
