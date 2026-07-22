# Prompt contexts

Identify the layer being changed before selecting an evaluation profile. A
prompt-like word in a request or repository is not enough to activate this
workflow.

## Instruction-layer routing

Classify the requested change as a system, developer, or user layer change
before editing. Preserve the higher-priority layer's authority and route a
request that lacks permission for that layer to the responsible owner. Do not
pretend a user-layer rewrite can change a system or developer instruction.

## Tool-schema routing

Inspect tool-schema names, arguments, return shapes, and validation rules as a
separate contract from prompt wording. Route a mismatch in a tool schema or
tool implementation to its responsible owner; do not use prompt text to claim
that an unavailable tool, argument, or result shape exists.

## Embedded-component routing

When a prompt is embedded in a skill, template, code/configuration component,
or generated artifact, identify the owning component and every consumer before
editing. Route each case to its responsible layer owner and evaluate the
embedded component in its containing workflow, not as an isolated paragraph.

## Single prompts

Inspect the prompt's user goal, input contract, available context, authority,
tool boundary, output requirements, and truthful reporting rule. Ask for only
the facts needed to distinguish a wording issue from a missing runtime or
capability. For a small low-risk request, a conditional proposal may be enough;
do not claim behavioral improvement without a relevant comparison.

## Prompt-bearing skills

Review two separate surfaces:

1. **Activation:** whether the description and trigger boundary select the
   skill for the intended prompt-engineering work without catching ordinary
   questions or repository text merely because it contains prompt language.
2. **Workflow:** whether the instructions diagnose before editing, scale effort
   to risk, preserve authority and user intent, and make evidence requirements
   clear without forcing ceremony for every request.

Keep trigger recommendations separate from post-activation behavior. A request
to explain a concept in two sentences remains a short explanation request,
even when the word "prompt" appears in it.

## Subagent handoffs

Trace the handoff from producer to consumer. Record the input fields, output
schema, status values, verification fields, authorization, and constraints that
each stage is allowed to use. Optimize verbosity only inside the contract:
compact values or repeated prose when safe, while retaining required fields and
the outer shape. A local prompt edit that removes a consumer-required field is
an ecosystem regression, not a successful simplification.

When the supplied contract uses them, trace the exact `status`,
`result.files`, and `result.verification` dependencies explicitly. Preserve the
outer packet shape and do not claim verification unless the recorded command
actually ran.

## Multi-prompt ecosystems

Map the stages and evaluate a representative path end to end. Check planner,
worker, reviewer, coordinator, and any other named stage in the supplied
context. Preserve instruction hierarchy, authorization, user intent, tool
contracts, and truthful verification requirements at every boundary. If a
schema or responsibility must change, identify all affected stages and treat
it as a coordinated change rather than a worker-only rewrite.

## Non-prompt exit routing

Stop prompt editing when the evidence points to capability, architecture,
runtime or configuration, tools, data, permissions, or an external system.
Name the responsible layer, record the missing or observed evidence, and route
the issue to the owner when the user has authorized that handoff. Do not invent
the missing diagnosis or turn a lack of tools into permission to act.

For ordinary prose editing, answer or route the prose request directly. Do not
add prompt-engineering ceremony merely because the text contains instructions,
AI terminology, or a mention of a prompt.
