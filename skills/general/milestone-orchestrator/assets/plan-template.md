# <Milestone Title> — Implementation Plan

**Milestone slug:** `<milestone-slug>`
**Spec:** `SPEC.md` (sha256 `<64-hex>` at approval)
**Status:** Draft | Reviewed | Approved
**Review depth:** <standard | adversarial tier used> — <report path and rationale>
**Execution profile:** <full|lite> — <rationale per SKILL.md profile table>
**Worker-dispatch budget:** <5 × plan task count, or override with justification>

## Grounding digest

<Repo conventions binding workers, milestone-relevant architecture and key
paths, build/test/verification commands, known pitfalls. Embedded verbatim in
every task packet; may point to `DIGEST.md` when large.>

## Task overview

<Prose narrative of the waves, ownership map, integration order, and closeout
steps. The canonical block below is the machine source of truth for tasks,
dependencies, ownership, acceptance mapping, and verification commands.>

## Wave plan

| Wave | Tasks | Rationale |
|------|-------|-----------|
| 1 | TASK-001, TASK-002 | <independent slices> |

## Worker routing notes

| Task | Route | Reason |
|------|-------|--------|
| TASK-001 | <family/model/effort> | <reason> |

## Budget overrides

<Only budgets that differ from the skill defaults, with justification. Unset
budgets use the defaults; none may be removed.>

## Canonical plan block

<!-- milestone-orchestrator-plan:v1 -->
```json
{
  "schema_version": 1,
  "requirements": {
    "AC-001": {"summary": "<criterion summary>"}
  },
  "tasks": {
    "TASK-001": {
      "type": "implementation",
      "depends_on": [],
      "owned_paths": ["<path>"],
      "acceptance_ids": ["AC-001"],
      "verification_command_ids": ["verify-example"]
    }
  },
  "verification_commands": {
    "verify-example": {
      "argv": ["<command>", "<arg>"],
      "cwd": ".",
      "timeout_seconds": 120,
      "acceptance_ids": ["AC-001"]
    }
  }
}
```
<!-- /milestone-orchestrator-plan -->
