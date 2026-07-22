# Prompt Engineer Cutover Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pure, fail-closed `PromptEngineer::Cutover.evaluate` gate that blocks prompt-engineer cutover when qualification or capability evidence is incomplete or unsupported.

**Architecture:** The gate accepts two in-memory records, validates their closed shape and required evidence, and returns a plain result hash. It performs no filesystem access, subprocess execution, host invocation, installation, symlink, deletion, or other mutation; every result keeps mutation authorization false.

**Tech Stack:** Ruby 2.6-compatible standard library and Minitest.

---

### Task 1: Add the failing cutover-gate contract test

**Files:**

- Create: `scripts/lib/prompt_engineer/cutover.rb`
- Create: `test/prompt_engineer_cutover_test.rb`

- [ ] **Step 1: Write the failing test**

  Add a focused Minitest that supplies a qualification result with `INCONCLUSIVE`, partial capability evidence, absent Ruby 2.6/libc evidence, non-PASS native qualification, and unsupported sandbox evidence. Assert that `PromptEngineer::Cutover.evaluate` returns `BLOCKED`, exposes explicit reason codes, and reports every mutation capability as false. Add a second assertion that malformed or missing required evidence returns `INCONCLUSIVE` and remains non-mutating.

- [ ] **Step 2: Run the focused test and confirm the expected failure**

  Run:

  ```bash
  ruby -Itest test/prompt_engineer_cutover_test.rb
  ```

  Expected: the test fails because `prompt_engineer/cutover` and `PromptEngineer::Cutover.evaluate` do not yet exist.

### Task 2: Implement the minimal read-only evaluator

- [ ] **Step 1: Implement closed-record validation and gate decisions**

  Define `PromptEngineer::Cutover.evaluate(qualification_result:, capability_record:)`. Validate top-level hashes, required qualification decision, and required capability fields without reading paths or invoking commands. Return `INCONCLUSIVE` for malformed or missing evidence. Return `BLOCKED` for partial/unsupported capability status, absent Ruby 2.6/libc evidence, native qualification other than `PASS`, or unsupported sandbox. Return `READY` only for complete `PASS` evidence, while still returning false for all mutation permissions because this task has no live cutover authority. Include stable reason codes and `live_actions` set to false for replacement, install, symlink, and deletion.

- [ ] **Step 2: Run the focused test and confirm it passes**

  Run:

  ```bash
  ruby -Itest test/prompt_engineer_cutover_test.rb
  ```

  Expected: all focused tests pass with zero failures or errors.

### Task 3: Verify and commit the bounded change

- [ ] **Step 1: Run syntax and repository checks**

  Run:

  ```bash
  ruby -c scripts/lib/prompt_engineer/cutover.rb
  ruby -Itest test/prompt_engineer_cutover_test.rb
  scripts/test
  scripts/verify
  git diff --check
  ```

  Expected: every command exits successfully; the pre-existing untracked sandbox test remains untouched.

- [ ] **Step 2: Review scope and commit only the new gate/test/plan**

  Run:

  ```bash
  git status --short
  git diff -- scripts/lib/prompt_engineer/cutover.rb test/prompt_engineer_cutover_test.rb docs/superpowers/plans/2026-07-20-prompt-engineer-cutover-gate.md
  git add scripts/lib/prompt_engineer/cutover.rb test/prompt_engineer_cutover_test.rb docs/superpowers/plans/2026-07-20-prompt-engineer-cutover-gate.md
  git commit -m "feat: add fail-closed prompt engineer cutover gate"
  ```

  Expected: only the three newly added files are staged and committed; existing unrelated work remains untracked and unchanged.
