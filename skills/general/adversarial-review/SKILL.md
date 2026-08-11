---
name: adversarial-review
description: >-
  Use when the user invokes $adversarial-review or /adversarial-review, or asks
  to adversarially review a spec, implementation plan, migration plan, or
  architecture design before implementation. Returns at most three
  evidence-backed findings in chat, in roughly ten minutes. Read-only: never
  edits the reviewed documents.
---

# Adversarial Review

Four fresh-context reviewers attack a planning document in parallel, one
synthesis pass kills everything that does not survive scrutiny, and you get at
most three findings in chat. Nothing is written to disk. The reviewed documents
are never edited.

Returning zero findings is a valid and good outcome. Say so plainly.

## Run

1. **Resolve targets.** Use the paths the user named. With none named, use the
   most recently modified spec or plan under `docs/plans/` or `docs/`, and say
   which file you picked. Read each target once and keep the text.

2. **Dispatch four attackers in a single parallel batch** — one message, four
   concurrent reviewers, never sequentially. Each gets a fresh context, the full
   target text, exactly one angle from [attack-angles.md](attack-angles.md), and
   the output contract in `assets/schemas/attack.json`.

   | Angle | Enabled when |
   |---|---|
   | `implementer` | always |
   | `tester` | always |
   | `feasibility` | a plan is present |
   | `pre-mortem` | always |

   Run attackers at **`sonnet`, effort `medium`**. They are breadth-finders;
   higher effort buys latency, not coverage. Attackers are read-only: they may
   read repository files to check a claim, and may not edit anything or run
   builds, tests, or package installs.

   Each attacker returns **at most two findings**. Fewer is better. An attacker
   that finds nothing returns an empty array.

3. **Check the quotes.** Every finding carries a verbatim `quote` from the file
   it cites. Verify them deterministically:

   ```bash
   "$AR_SKILL_DIR/scripts/check-quotes" --repository REPO CANDIDATES.json
   ```

   The script names every finding whose quote is not byte-present in the file it
   cites. Drop those before synthesis; never pass an unverified quote forward.
   Do not substitute your own reading of the files for this check.

4. **Synthesize once,** at **`opus`, effort `high`**, following
   [synthesis-rubric.md](synthesis-rubric.md) and
   `assets/schemas/synthesis.json`. The synthesizer's job is to reject, not to
   catalogue. It ships **at most three** findings.

5. **Report in chat.** For each surviving finding: severity, location, the
   quote, the concrete failure, and what would fix it. Then stop. Do not edit
   the documents, do not write a report file, and do not open a follow-up loop.

## Non-Negotiables

- **Read-only.** This skill never edits the reviewed documents. If the user
  wants the findings applied, that is a separate request they make after seeing
  them.
- **No finding without a verified verbatim quote.** A quote that fails
  `check-quotes` is dropped, not repaired and not paraphrased.
- **Caps are hard.** Two findings per attacker, three shipped. If more than
  three survive, the synthesizer ranks and cuts; it does not negotiate the cap.
- **One round.** There is no revise loop, no re-attack after fixes, and no
  convergence criterion. v1 had those; see
  `docs/plans/2026-08-11-adversarial-review-v2-design.md` for why they were cut.
- Report the angles that ran and any that were skipped, so a thin review is
  visible as thin rather than passing as clean.

## Degraded Hosts

Without host support for parallel subagent dispatch, run the four angles
sequentially and say the review took longer than it should have. Without Ruby,
`check-quotes` is unavailable: verify each quote by reading the cited file and
searching for the exact string, and state that quote verification was manual.
Never skip verification because the tooling is missing.
