# Attack Angles

Four angles. Each attacker gets one of them, a fresh read-only context, and the
full text of the target documents. Attackers may read repository files to check
a claim. They may not edit anything or run builds, tests, linters, or package
installs. Output is JSON only, conforming to `assets/schemas/attack.json`.

## The Bar

**At most two findings. Zero is a fine answer.** You are not being graded on
volume, and a thin honest result beats a padded one.

A finding qualifies only if all four hold:

1. **It quotes the document verbatim.** The `quote` field must appear
   byte-for-byte in the file named in `path`. It is checked mechanically; an
   approximate quote is discarded along with the finding.
2. **It names a concrete failure.** What breaks, when, and for whom. "Ambiguous"
   is not a failure. "Two implementers reading this line will pick different
   storage backends, and the migration step assumes one of them" is.
3. **The failure follows from the document as written**, not from what someone
   might do if they ignored it.
4. **A competent implementer would not simply resolve it in passing.** If the
   answer is obvious from context, it is not a finding.

Do not report: style, terminology, formatting, section ordering, missing
cross-references, absent boilerplate, or generic risks that apply to any
project of this shape. Do not invent requirements the document never claimed.
Prefer one finding you are certain of to two you are hedging on.

## implementer

Always enabled.

1. Sketch the implementation file by file. For each module the document implies,
   name the inputs, outputs, state, and dependencies.
2. Log every point where you would have to guess to proceed.
3. Where the document names a repository API, path, schema, or command, check
   that it exists and behaves as claimed.

Report only the guesses that would produce materially different, incompatible
implementations. A guess about a variable name is not a finding; a guess about
whether state is shared across requests is.

## tester

Always enabled.

1. Write the test plan the document implies.
2. Find acceptance criteria that cannot be tested as written — no expected
   output, no observable signal, or a subjective standard.
3. Check that proposed test commands and frameworks match what the repository
   actually has.

Report missing negative, boundary, rollback, migration, or concurrency tests
only when a stated goal of the document depends on that case.

## feasibility

Enabled when a plan is present.

1. Verify plan steps against the real repository. Do referenced files, scripts,
   commands, APIs, and package managers exist?
2. Check sequencing: no step may depend on an artifact no earlier step creates.
3. Check that each verification step can actually observe the behavior it claims
   to verify.

This angle has the repository in front of it — prefer findings you confirmed
against real files over findings you reasoned about.

## pre-mortem

Always enabled.

1. Assume the work shipped and failed.
2. Write the failure narrative using only the document's own commitments.
3. Trace the failure back to a specific line.

Report a cause only when you can quote the line that causes it. A risk you
cannot anchor to a quote is not a finding — it is a worry, and worries are
exactly what this review exists to filter out.
