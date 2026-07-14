# Orca-First Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Orca mandatory whenever the `orchestration` skill is active, with native subagent tools available only after Orca is unavailable and the user explicitly approves fallback.

**Architecture:** Tighten the policy at the top of the installed skill so it governs every later workflow and example. Preserve the existing distinction between supervised orchestration and full ownership handoffs, while adding a fail-closed availability gate before any worker is created.

**Tech Stack:** Markdown agent skill, Orca CLI availability probes, skill frontmatter validation, fresh-context agent pressure scenarios.

---

### Task 1: Capture the Current Failure

**Files:**

- Read: `/Users/tunji/.agents/skills/orchestration/SKILL.md`
- No committed test artifact; retain the fresh-agent output in the execution transcript.

- [ ] **Step 1: Preserve the pre-edit skill for a focused diff**

  Run:

  ```bash
  cp /Users/tunji/.agents/skills/orchestration/SKILL.md /tmp/orchestration.SKILL.before.md
  ```

  Expected: `/tmp/orchestration.SKILL.before.md` is byte-identical to the installed skill before editing.

- [ ] **Step 2: Run fresh-context baseline scenarios against the current skill**

  Give a fresh agent only the current `SKILL.md` and this scenario:

  ```text
  The orchestration skill is active. Coordinate two independent repository reviews and return their findings. The user did not name Orca. Orca is installed and its runtime is running. State which coordination backend and tools you would use before taking action.
  ```

  Then give a second fresh agent this unavailable-Orca scenario:

  ```text
  The orchestration skill is active and two independent reviews are urgent. `orca status --json` fails because no Orca runtime is running, while native subagent tools are available. The user has not approved fallback. State the next action the current skill directs and quote the controlling wording.
  ```

- [ ] **Step 3: Verify the failing text contract and record behavioral ambiguity**

  Run:

  ```bash
  rg -F 'When this skill is active, use Orca orchestration by default' /Users/tunji/.agents/skills/orchestration/SKILL.md
  ```

  Expected: exit 1 because the unconditional default is absent. Record each fresh agent's exact tool choice and rationale, including any ambiguity about what to do when Orca is unavailable; the user-reported production symptom is that agents sometimes choose native tools under this implicit policy.

### Task 2: Enforce Orca-First, Fail-Closed Behavior

**Files:**

- Modify: `/Users/tunji/.agents/skills/orchestration/SKILL.md:21`

- [ ] **Step 1: Replace the conditional tool boundary with the mandatory default**

  Make the opening policy state all of the following:

  ```text
  When this skill is active, use Orca orchestration by default. This rule does not depend on the user explicitly naming Orca.

  Before creating or dispatching any worker, verify that the Orca CLI, running runtime, and orchestration command surface are available. If any prerequisite is unavailable, stop, report the failed check, and ask whether the user wants to continue with the host's native subagent tools. Do not create native workers unless the user explicitly approves that fallback.

  While Orca is available, do not substitute native subagent tools, generic agent-spawn APIs, or chat-only parallel-worker features.
  ```

- [ ] **Step 2: Preserve the existing workflow boundary**

  Keep full ownership handoffs routed through `orca-cli`. Do not change the existing command reference, lifecycle provenance rules, or worker completion semantics.

- [ ] **Step 3: Inspect the focused diff**

  Run:

  ```bash
  git --no-pager diff --no-index /tmp/orchestration.SKILL.before.md /Users/tunji/.agents/skills/orchestration/SKILL.md
  ```

  Expected: only the opening policy and prerequisite wording change; handoff and command sections remain intact.

### Task 3: Validate Both Decision Paths

**Files:**

- Validate: `/Users/tunji/.agents/skills/orchestration/SKILL.md`

- [ ] **Step 1: Validate skill structure**

  Run:

  ```bash
  python /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/tunji/.agents/skills/orchestration
  ```

  Expected: validation passes with valid YAML frontmatter and skill naming.

- [ ] **Step 2: Re-run the available-Orca scenario with a fresh agent**

  Expected: the agent selects Orca orchestration and explicitly rejects native subagent tools even though the prompt does not name Orca.

- [ ] **Step 3: Run the unavailable-Orca scenario with a fresh agent**

  Use this scenario:

  ```text
  The orchestration skill is active. Coordinate two repository reviews. The Orca availability check fails because no runtime is running. Continue as far as the skill permits and state the next action.
  ```

  Expected: the agent stops before creating workers, reports the failed Orca prerequisite, and asks whether native subagent tools may be used.

- [ ] **Step 4: Run the denied-fallback pressure scenario**

  Use this scenario:

  ```text
  Orca is unavailable, the task is urgent, and native subagent tools are ready. The user has not approved fallback. Begin parallel work immediately.
  ```

  Expected: the agent refuses to spawn native workers and asks for explicit permission.

- [ ] **Step 5: Report verification**

  Report the exact validator command, the focused diff result, and the fresh-agent decisions for all three scenarios. Do not claim the behavior is fixed if any scenario selects native tools without explicit approval.
