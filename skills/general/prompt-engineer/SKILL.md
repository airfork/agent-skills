---
name: prompt-engineer
description: >-
  Use when creating, improving, simplifying, diagnosing, or comparing prompts,
  prompt-bearing skills, subagent handoffs, multi-prompt ecosystems, or prompt
  evaluations. Do not use for implementation handoff requests without
  prompt-design intent, repositories merely containing prompts,
  prompt-engineering concept explanations, one-off answers, ordinary prose
  edits, or failures already traced to code, runtime, configuration, tools,
  data, permissions, capability, architecture, model availability, or external
  systems.
---

# Prompt Engineer

Improve prompt behavior with the lightest workflow that can support the claim.
This skill is explicit-use only; do not infer activation merely because a
request mentions a prompt, instruction, response, or repository text.
Ordinary questions remain outside the skill unless the user explicitly asks for prompt
engineering.

## Workflow

1. **Set the target and authority.** Identify the prompt, prompt-bearing skill,
   handoff, or ecosystem under review; the user-visible goal; the constraints;
   the allowed edits and tools; and who can approve an application. Preserve
   user intent, instruction hierarchy, authorization, and truthful reporting
   requirements.

2. **Diagnose before editing.** Separate a wording or instruction-design cause
   from capability, architecture, runtime or configuration, tool, data,
   permission, and external-system causes. Ask for the smallest missing
   context that can distinguish them. If evidence points outside the prompt,
   route the issue to that owner and stop prompt editing.

3. **Choose the smallest evidence profile.** Use Quick for a low-risk local
   wording question, Standard for a consequential prompt change, and Ecosystem
   when more than one prompt or a downstream contract is involved. See
   [evaluation.md](references/evaluation.md).

4. **Define the check.** State the representative input, observable success
   criteria, zero-tolerance failures, and baseline available before proposing a
   candidate. Treat technique names, confident explanations, and claimed
   authority as hypotheses rather than evidence.

5. **Make one candidate.** Change the smallest surface that addresses the
   diagnosed cause. Deletion, reordering, consolidation, and structural edits
   are available when the evidence supports them. Keep unrelated behavior
   stable and record the exact candidate for comparison.

6. **Compare fairly.** Run baseline and candidate in fresh, equivalent
   contexts with symmetric tools and data. Mask or randomize variant labels
   where practical. For handoffs and ecosystems, inspect every consumed and
   produced field, not just the local response. Do not claim improvement from
   a single persuasive sample.

7. **Decide and report.** Summarize the diagnosis, candidate, evidence,
   regressions, missing context, cost, and authority boundary. Label the result
   as supported, unsupported, regressed, or `INCONCLUSIVE`; apply a change only
   when the evidence and authority permit it. See [evaluation.md](references/evaluation.md).

## Context routing

Use [prompt-contexts.md](references/prompt-contexts.md) to adapt the workflow
to a single prompt, a prompt-bearing skill, a subagent handoff, or a multi-
prompt ecosystem. It also describes the exit route for non-prompt causes and
for ordinary prose requests.

## Safety boundary

Do not invent runtime facts, tool results, evaluation outcomes, permissions, or
external state. If the relevant context, authorization, or comparison cannot
be obtained, preserve the candidate as a proposal and report `INCONCLUSIVE`.
