# <Milestone Title> — Specification

**Milestone slug:** `<milestone-slug>`
**Date:** <YYYY-MM-DD>
**Status:** Draft | Reviewed | Approved
**Review depth:** <standard | adversarial tier used> — <report path>

## Goals

1. <goal>

## Non-goals

- <explicit exclusion>

## Architecture

<Components, module boundaries, data/control flow. Diagrams welcome.>

## Behavior

<Desired behavior and user flows, including negative behavior: what the system
must refuse or never do.>

## Invariants

- <invariant that must hold before, during, and after the milestone>

## Failure handling

<Error, recovery, and degradation behavior.>

## Acceptance criteria

| ID | Criterion | Evidence |
|----|-----------|----------|
| AC-001 | <criterion> | <command or observable proof> |

## External actions and capabilities

<Credentials, external systems, browsers, and services the run may touch.>

## Authority envelope

Defaults the coordinator may apply without asking:

- <default>

Boundaries requiring escalation:

- <boundary>

Publication authority (each action listed separately; merge and deploy are
always disabled):

| Action | Enabled |
|--------|---------|
| Local commits | yes/no |
| Push | yes/no |
| Draft PR | yes/no |
| PR ready | yes/no |
| Assign reviewers / notify | yes/no |
| Merge | no |
| Deploy | no |

## Escalation policy

<Anything beyond the skill's six standard triggers, or repo-specific contacts.>
