# Adversarial Review Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the validated cross-platform `adversarial-review` skill under `skills/general/` and wire it into the repo catalog and managed Codex install metadata.

**Architecture:** The new skill mirrors the sibling `skills/codex-cursor/code-review/` structure and tone while remaining portable across Codex and Claude Code. `SKILL.md` carries the core pipeline and invocation contract; three peer reference files hold attack-angle procedures, judge rubric, and platform adapters; Codex named-agent TOMLs live under `agents/codex/`.

**Tech Stack:** Markdown skill files, YAML manifest/catalog metadata, TOML Codex named-agent definitions, Ruby sync installer validation.

---

## Pre-Build Gates

- [ ] Run xhigh fresh-context adversarial review on this plan before creating the skill package.
- [ ] Cull review findings: accept only findings grounded in the design, repo guidance, or reference skill behavior.
- [ ] Apply accepted plan fixes or write rejections with rationale.
- [ ] Stop after at most two revise rounds.
- [ ] Commit the reviewed plan as its own checkpoint before package implementation.
- [ ] Preserve unrelated work: record `rtk git status --short` before edits and before commits; stop or use hunk staging if shared files contain pre-existing or unexpected edits.

## File Map

- Create: `skills/general/adversarial-review/SKILL.md`
  - Core workflow: invocation, flags, tier table, pipeline, loop semantics, report format, non-negotiables, resource routing.
- Create: `skills/general/adversarial-review/attack-angles.md`
  - One procedure per validated attack angle with input and output contract.
- Create: `skills/general/adversarial-review/judge-rubric.md`
  - Refute-or-promote rubric, confidence floor, severity gates, finding ID rules, resolution verification rules.
- Create: `skills/general/adversarial-review/platform-adapters.md`
  - Codex, Claude Code, UltraCode, and sequential fallback adapters; include install paths and the verified Codex dual-skill-root note.
- Create: `skills/general/adversarial-review/agents/codex/spec-attacker.toml`
  - Read-only xhigh attacker role with `nickname_candidates`; no `model` pin.
- Create: `skills/general/adversarial-review/agents/codex/spec-judge.toml`
  - Read-only xhigh judge role; no `model` pin.
- Create: `skills/general/adversarial-review/agents/codex/spec-arbiter.toml`
  - Read-only xhigh arbiter role; no `model` pin.
- Modify: `skills.yaml`
  - Add `adversarial-review` in category `general`, interfaces `claude` and `codex`, recommended tier `deep`, heavy tier `ultracode`, Codex install enabled by symlink.
- Modify: `CATALOG.md`
  - Add the active skill row with install and model-tier status.
- Review only unless findings require it: `scripts/sync-skills`, `test/sync_skills_test.rb`, `README.md`, `docs/repo-guidelines.md`.

## Verified Environment Facts

- [ ] Record in final notes: `codex-cli 0.142.5` was checked.
- [ ] Record in final notes: `codex debug prompt-input 'skill scan probe'` showed `arxiv-to-md` from `~/.agents/skills` and `code-review` from the repo-managed `~/.codex/skills` symlink, so current Codex scans both roots.
- [ ] Keep `scripts/sync-skills` default Codex target at `~/.codex/skills` unless further review finds a concrete reason to change it.
- [ ] Do not copy the new Codex agent TOMLs into `~/.codex/agents/`; only document the one-time copy step.

## Task 1: Plan Review Gate

**Files:**
- Read: `docs/plans/2026-07-03-adversarial-review-design.md`
- Read: `docs/plans/2026-07-03-adversarial-review-implementation-plan.md`
- Read: `AGENTS.md`
- Read: `skills/codex-cursor/code-review/SKILL.md`
- Read: `skills/codex-cursor/code-review/platform-adapters.md`

- [ ] **Step 1: Dispatch fresh-context xhigh reviewers**

  Spawn independent read-only reviewers with no forked conversation context:

  1. Spec/package conformance reviewer: check the plan against the validated design and required layout.
  2. Repo/conventions reviewer: check the plan against `AGENTS.md`, `skills.yaml`, `CATALOG.md`, `scripts/sync-skills`, and the code-review sibling.
  3. Deployment/verification reviewer: check install path assumptions, named-agent installation boundaries, validation commands, and commit checkpoints.

- [ ] **Step 2: Cull findings**

  Keep only findings with a concrete consequence and evidence in the design or repo. Drop style preferences, broader redesigns, or requests that contradict the user process.

- [ ] **Step 3: Revise or reject**

  Patch this plan for accepted findings. For rejected findings, record the reason in the working notes and final summary. Maximum two revise rounds.

- [ ] **Step 4: Commit plan checkpoint**

  Run:

  ```bash
  rtk git status --short
  rtk git add docs/plans/2026-07-03-adversarial-review-implementation-plan.md
  rtk git diff --cached --name-status
  rtk git commit -m "Plan adversarial-review skill implementation"
  ```

## Task 2: Create Skill Package

**Files:**
- Create: `skills/general/adversarial-review/SKILL.md`
- Create: `skills/general/adversarial-review/attack-angles.md`
- Create: `skills/general/adversarial-review/judge-rubric.md`
- Create: `skills/general/adversarial-review/platform-adapters.md`
- Create: `skills/general/adversarial-review/agents/codex/spec-attacker.toml`
- Create: `skills/general/adversarial-review/agents/codex/spec-judge.toml`
- Create: `skills/general/adversarial-review/agents/codex/spec-arbiter.toml`

- [ ] **Step 1: Create directories**

  Create only the package directories required by the design:

  ```text
  skills/general/adversarial-review/
  skills/general/adversarial-review/agents/codex/
  ```

- [ ] **Step 2: Write `SKILL.md`**

  Include:

  - YAML frontmatter with only `name` and `description`.
  - Natural Codex and Claude invocation examples.
  - Tier table: default, `--high`, `--ultra`; no low/quick tier.
  - `--report-only` semantics.
  - Pipeline: packet build, attack wave, merge/dedupe, cull, revise, resolution check.
  - Loop cap: two revise rounds; terminal states resolved/rejected/stuck.
  - Full loop termination contract: terminate only when all findings are resolved-or-rejected and no new `CRITICAL`/`HIGH` findings remain; at cap, verdict line is `DID NOT CONVERGE - N findings remain open`; stuck `CRITICAL`/`HIGH` means the review did not pass.
  - Stuck-finding open-question format: include both positions, with the judge's evidence and consequence plus the author's rejection rationale or failed-fix summary.
  - Report format and report file placement: verdict line, findings table, metrics block, changelog of document edits, rejected-findings log, and open questions.
  - Report persistence: write `<doc-stem>-review.md` next to the reviewed docs by default; append a new round section on re-review instead of overwriting the existing metrics trail.
  - Metrics tracked across rounds: TBD count, coverage percentage when both spec and plan are present, findings by severity, and doc length.
  - Anti-gaming guards: track doc length growth, require evidence quotes per criterion, and retry one suspiciously empty attacker angle once.
  - Non-negotiables: fresh-context attackers, repo-grounded findings, rejection channel, no agent TOML install without user action, no downgraded judges.
  - References to the three peer markdown files and when to read each.

- [ ] **Step 3: Write `attack-angles.md`**

  Include every design angle:

  - Constructive reader: implementer
  - Constructive reader: tester
  - Constructive reader: user
  - Coverage mapper
  - Assumptions checker
  - Pre-mortem writer
  - Consistency + smells scanner
  - Feasibility checker
  - Spec-plan drift
  - Divergence probe (`--high` and `--ultra`)

  Each angle must define: when enabled, read scope, procedure, and JSON output shape.

- [ ] **Step 4: Write `judge-rubric.md`**

  Include:

  - Refute-or-promote burden.
  - Confidence floor `< 0.7 = do not report`.
  - Severity ladder `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`.
  - Taxonomy: Omission, Ambiguity, Inconsistency, Incorrect fact, Extraneous.
  - Stable IDs `AR-001` and cap of 50 reported findings.
  - Resolution-check contract by finding ID, not holistic rescoring.
  - Arbiter ruling contract for `--high` stuck findings.
  - Anti-gaming guard: a judge finding, resolution check, or refutation must quote evidence for each criterion it relies on.

- [ ] **Step 5: Write `platform-adapters.md`**

  Include:

  - Codex invocation through `$adversarial-review`.
  - Claude Code invocation through `/adversarial-review`.
  - Codex named-agent use from `agents/codex/`, bounded fan-out, `max_depth = 1`, fallback disclosure if named agents are not installed.
  - Codex version guard: recommend a current Codex CLI; document that Codex v0.137.0 silently ignored named-agent config and that Windows has an unresolved variant; disclose/fallback if named-agent config cannot be trusted.
  - Verified local fact: Codex 0.142.5 scans both `~/.agents/skills` and `~/.codex/skills`; `scripts/sync-skills` still targets `~/.codex/skills`.
  - One-time TOML copy example to `~/.codex/agents/`, clearly not performed by sync and not performed by this implementation.
  - Claude `--ultra` behavior and Codex downgrade to `--high` with disclosure.
  - Sequential fallback disclosure.

- [ ] **Step 6: Write Codex agent TOMLs**

  Required properties for each TOML:

  ```toml
  model_reasoning_effort = "xhigh"
  sandbox_mode = "read-only"
  ```

  Also include:

  - `name` matching the file role.
  - `description` matching the role.
  - `developer_instructions` with read-only rules and the structured output expectation.
  - `nickname_candidates` only in `spec-attacker.toml`.
  - No `model` key.

## Task 3: Update Repo Indexes

**Files:**
- Modify: `skills.yaml`
- Modify: `CATALOG.md`

- [ ] **Step 1: Update `skills.yaml`**

  Add:

  ```yaml
  - name: adversarial-review
    path: skills/general/adversarial-review
    category: general
    status: active
    interfaces:
      - claude
      - codex
    recommended_model_tier: deep
    heavy_model_tier: ultracode
    install:
      codex:
        enabled: true
        mode: symlink
      cursor:
        enabled: false
        mode: symlink
    description: Cross-platform adversarial review workflow for specs and implementation plans, using fresh-context attack angles, refute-or-promote culling, revise/reject loops, and resolution verification before implementation.
    notes: Place in general because the portable core targets Codex and Claude Code. Codex installs the skill folder through scripts/sync-skills; Claude install is manual/personal-skill only in this repo; Codex named-agent TOMLs require a separate, explicit copy to ~/.codex/agents/.
  ```

- [ ] **Step 2: Update `CATALOG.md`**

  Add an active row for `adversarial-review` with:

  - Path `skills/general/adversarial-review/`
  - Category `general`
  - Install `Codex enabled; Claude manual/personal-skill install; Cursor disabled`
  - Recommended tier `deep`; heavy tier `ultracode`
  - Description matching the manifest.

## Task 4: Verification

**Files:**
- Verify: `skills/general/adversarial-review/**`
- Verify: `skills.yaml`
- Verify: `scripts/sync-skills`
- Verify: `test/sync_skills_test.rb`

- [ ] **Step 1: Validate YAML syntax**

  Run:

  ```bash
  rtk ruby -e 'require "yaml"; YAML.load_file("skills.yaml"); puts "skills.yaml ok"'
  ```

- [ ] **Step 2: Validate the skill folder**

  Run whichever validator is available:

  ```bash
  rtk scripts/quick_validate.py skills/general/adversarial-review
  ```

  If the repo lacks `scripts/quick_validate.py`, use the installed validator:

  ```bash
  rtk python3 /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/general/adversarial-review
  ```

  If neither exists, state the blocker and compensate with frontmatter parsing plus file checks.

- [ ] **Step 3: Run sync dry-run**

  Run:

  ```bash
  rtk scripts/sync-skills --target codex --dry-run
  ```

  Expected: existing `code-review` link remains a no-op and `adversarial-review` is listed as a link/no-op depending on whether it is already linked. Do not run `--apply`.

- [ ] **Step 4: Run sync tests**

  Run:

  ```bash
  rtk ruby test/sync_skills_test.rb
  ```

- [ ] **Step 5: Parse and validate TOML content mechanically**

  Run:

  ```bash
  rtk python3 - <<'PY'
  import pathlib
  import tomllib

  root = pathlib.Path("skills/general/adversarial-review/agents/codex")
  files = sorted(root.glob("*.toml"))
  assert {path.name for path in files} == {
      "spec-attacker.toml",
      "spec-judge.toml",
      "spec-arbiter.toml",
  }, files

  for path in files:
      data = tomllib.loads(path.read_text())
      assert data.get("model_reasoning_effort") == "xhigh", path
      assert data.get("sandbox_mode") == "read-only", path
      assert "model" not in data, path
      has_nicknames = "nickname_candidates" in data
      assert has_nicknames == (path.name == "spec-attacker.toml"), path

  print("codex agent tomls ok")
  PY
  ```

  Expected: all three TOMLs parse, every file has `model_reasoning_effort = "xhigh"` and `sandbox_mode = "read-only"`, no file has `model`, and only `spec-attacker.toml` has `nickname_candidates`.

- [ ] **Step 6: Check whitespace**

  Run:

  ```bash
  rtk git diff --check
  ```

## Task 5: Review, Commit, and Final Status

**Files:**
- Review: all changed files

- [ ] **Step 1: Inspect diff**

  Run:

  ```bash
  rtk git diff -- docs/plans/2026-07-03-adversarial-review-implementation-plan.md skills/general/adversarial-review CATALOG.md skills.yaml
  rtk git diff --name-only
  rtk git status --short
  ```

- [ ] **Step 2: Final fresh-context review gate**

  Run a focused fresh-context read-only review against:

  - Validated design requirements.
  - User ground rules.
  - Reference `code-review` skill conventions.
  - Verification outputs.

  Self-review is allowed only as an additional local check, not as the final gate.

- [ ] **Step 3: Commit implementation checkpoint**

  Run:

  ```bash
  rtk git status --short
  rtk git add skills/general/adversarial-review CATALOG.md skills.yaml
  rtk git diff --cached --name-status
  rtk git diff --cached --check
  rtk git commit -m "Add adversarial-review skill"
  ```

- [ ] **Step 4: Final report**

  Include:

  - Commit hashes created.
  - Accepted/rejected adversarial plan findings.
  - Verification commands and outcomes.
  - Explicit note that `scripts/sync-skills --apply` was not run.
  - Explicit note that Codex agent TOMLs were not copied to `~/.codex/agents/`.
