# Milestone Orchestrator Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and validate an Orca-first, cross-host `milestone-orchestrator` skill that front-loads milestone decisions, coordinates mixed-model workers without coordinator implementation, tracks durable state, publishes a draft PR automatically when authorized, performs host-correct final review, cleans owned resources, and stops before merge or deploy.

**Architecture:** `SKILL.md` is the portable policy entrypoint. Focused references define intake, state, task, adapter, and validation contracts; three assets instantiate repository-local milestone artifacts; dependency-free Ruby executables validate STATE, fence control-plane transitions, authorize constrained actions, and generate a disposable fixture. Root Ruby tests contract-test the skill text, state/control invariants, fixture safety, manifest/catalog registration, and fail-closed boundaries. Environment-gated integration tests exercise real hosts without making ordinary verification mutate Orca or spend model tokens.

**Tech Stack:** Markdown skills and templates, YAML repository manifest, canonical JSON state blocks, Ruby 2.6 standard library (`json`, `yaml`, `optparse`, `open3`, `tmpdir`, `fileutils`, `digest`, `securerandom`, `time`), Git, Orca CLI contracts, Codex and Claude host adapters, Minitest.

---

## Pre-Build Gates

- [ ] Start implementation in a dedicated Orca worktree from commit `97d6bf1` or a later commit containing this reviewed plan; do not implement on `main`.
- [ ] Read `AGENTS.md`, the validated design, its review report, this plan, `skills/general/adversarial-review/SKILL.md`, `skills/codex-cursor/code-review/SKILL.md`, and the installed Orca `orchestration`/`orca-cli` skills before editing.
- [ ] Run `rtk git status --short` and preserve unrelated changes. Stop or use narrow hunk staging if any planned shared file already has unexpected edits.
- [ ] Confirm `docs/plans/2026-07-13-milestone-orchestrator-implementation-plan-review.md` says `PASSED` for the exact plan/design digests in the reviewed checkpoint. Rerun `adversarial-review --high` only if those documents materially change; resolve or explicitly reject every new promoted finding before capability probes.
- [ ] Use test-first steps for Ruby behavior and contract tests. Observe each targeted test fail for the intended reason before adding the implementation that makes it pass.
- [ ] Do not run `scripts/sync-skills --apply`; global symlink changes require a separate explicit user request.
- [ ] Use the configured human Git author and no AI attribution in any commit.

## File Map

### Skill package

- Create: `skills/general/milestone-orchestrator/SKILL.md`
  - Trigger description, PREPARE/RUN state machine, manager-only boundary, review/remediation loop, publication and stop policy, recovery, closeout, and reference routing.
- Create: `skills/general/milestone-orchestrator/agents/openai.yaml`
  - Codex UI metadata and default `$milestone-orchestrator` prompt.
- Create: `skills/general/milestone-orchestrator/references/intake.md`
  - Repository grounding, decision inventory, consolidated question packets, final approval, publication envelope, budgets, and preflight checklist.
- Create: `skills/general/milestone-orchestrator/references/task-contracts.md`
  - Stable plan tasks versus attempts, task packet schema, ownership, worker evidence, acceptance gates, remediation, integration, and closeout contracts.
- Create: `skills/general/milestone-orchestrator/references/state-schema.md`
  - Canonical STATE JSON schema, enums, invariants, leases/fencing, field-specific reconciliation, evidence freshness, resource lifecycle, and closeout rules.
- Create: `skills/general/milestone-orchestrator/references/platform-adapters.md`
  - Orca reference adapter plus native Codex and Claude mappings, launch/probe tables, capability topology, review routing, cancellation, cleanup, and fail-closed behavior.
- Create: `skills/general/milestone-orchestrator/references/validation.md`
  - Frozen pressure-test protocol, zero-tolerance assertions, deterministic fault matrix, actual-host conformance, and real-repo pilot gate.
- Create: `skills/general/milestone-orchestrator/assets/spec-template.md`
  - Approval-ready `SPEC.md` template.
- Create: `skills/general/milestone-orchestrator/assets/plan-template.md`
  - Reviewed `PLAN.md` template with immutable acceptance mapping.
- Create: `skills/general/milestone-orchestrator/assets/state-template.md`
  - `STATE.md` template with the canonical machine-readable JSON block and human journal.
- Create: `skills/general/milestone-orchestrator/scripts/validate-state`
  - Dependency-free Ruby validator with text and JSON output.
- Create: `skills/general/milestone-orchestrator/scripts/control-state`
  - Atomic lease acquire/renew/takeover/release and fenced STATE transition writer.
- Create: `skills/general/milestone-orchestrator/scripts/authorize-action`
  - One-shot, action/target/effect-scoped grant issuer.
- Create: `skills/general/milestone-orchestrator/scripts/execute-action`
  - Credential-owning constrained executor service with immediate revalidation, one-shot grant consumption, postcondition checks, and immutable audit results.
- Create: `skills/general/milestone-orchestrator/scripts/launch-role`
  - Capability-matrix-driven sandbox/container launcher that denies ordinary workers the control directory, executor socket, credential homes, ambient agent sockets, and unauthorized network/mutation surfaces.
- Create: `skills/general/milestone-orchestrator/scripts/inspect-effects`
  - Repository/forge effect inspector that snapshots action-target workflows, deploy hooks, rulesets, merge automation, bots, webhooks, and notifications or fails closed on opaque state.
- Create: `skills/general/milestone-orchestrator/scripts/run-verification`
  - Independent clean-tree exact-subject verifier that resolves approved commands and emits immutable evidence.
- Create: `skills/general/milestone-orchestrator/scripts/scan-outgoing`
  - Fail-closed outgoing Git object/LFS/artifact and transient-capture scanner.
- Create: `skills/general/milestone-orchestrator/scripts/run-pressure-suite`
  - Versioned fresh-context baseline/post-skill runner and scorer.
- Create: `skills/general/milestone-orchestrator/scripts/create-fixture-repo`
  - Dependency-free Ruby fixture generator for a temporary repo, bare remote, fake forge ledger, seeded slices/failures, and foreign-resource sentinels.
- Create: `skills/general/milestone-orchestrator/scripts/lib/state_document.rb`
  - Canonical JSON extraction, hashing, schema loading, and artifact binding shared by validator/control/executors.
- Create: `skills/general/milestone-orchestrator/scripts/lib/lease_store.rb`
  - Git-common-dir lease, fencing-token, grant, lock, and atomic-write primitives.
- Create: `skills/general/milestone-orchestrator/scripts/lib/audit_log.rb`
  - External append-only verification/action/CI/closeout ledger construction and digest validation.

### Repository integration and tests

- Create: `docs/plans/2026-07-13-milestone-orchestrator-capability-matrix.md`
  - Versioned proof of which Orca/Codex/Claude capability boundaries are enforced, detectably audited, unavailable, or deferred.
- Create: `docs/plans/2026-07-13-milestone-orchestrator-implementation-plan-review.md`
  - Persisted `adversarial-review --high` findings, revisions, rejected findings, metrics, and convergence result.
- Create: `docs/plans/2026-07-13-milestone-orchestrator-pressure-baseline.json`
  - Sanitized pre-skill trial provenance, metric counts, zero-tolerance outcomes, and raw-results digest.
- Create: `docs/plans/2026-07-13-milestone-orchestrator-pressure-results.json`
  - Sanitized post-skill comparison and qualification result.
- Create: `test/milestone_orchestrator_skill_contract_test.rb`
  - Package layout, frontmatter, mandatory policy text, templates, adapter parity, and catalog/manifest contract.
- Create: `test/milestone_orchestrator_state_validator_test.rb`
  - Parser, schema, lifecycle, identity, authority, evidence, resource, and closeout behavior.
- Create: `test/milestone_orchestrator_control_state_test.rb`
  - Lease atomicity, fencing, transition serialization, stale-token rejection, authorization grants, executor races, and action audit.
- Create: `test/milestone_orchestrator_role_isolation_test.rb`
  - Adapter-specific worker sandbox, protected executor service, credential/control-directory denial, and direct-bypass probes.
- Create: `test/milestone_orchestrator_verification_test.rb`
  - Independent verifier, outgoing scanner, clean-tree subject binding, and stale-evidence rejection.
- Create: `test/milestone_orchestrator_fault_matrix_test.rb`
  - Table-driven deterministic failure, cancellation, retry, resource, and forbidden-effect assertions.
- Create: `test/support/milestone_orchestrator_fake_adapter.rb`
  - Deterministic lifecycle adapter with virtual time, task/dispatch/message/resource stores, fault injection, and a mutation ledger.
- Create: `test/milestone_orchestrator_pressure_test.rb`
  - Corpus/protocol/scoring contract and zero-tolerance result handling.
- Create: `test/milestone_orchestrator_fixture_test.rb`
  - Fixture repeatability, Git isolation, fake publication, seeded cases, and no production remote.
- Create: `test/integration/milestone_orchestrator_orca_e2e_test.rb`
  - Explicitly environment-gated actual Orca lifecycle checks.
- Create: `test/integration/milestone_orchestrator_native_conformance_test.rb`
  - Explicitly environment-gated native Codex/Claude review and cancellation checks.
- Create: `test/fixtures/milestone-orchestrator/pressure-protocol.json`
  - Frozen corpus hashes, repetitions, model/config provenance, metrics, thresholds, and zero-tolerance rules.
- Create: `test/fixtures/milestone-orchestrator/pressure-prompts/*.md`
  - Versioned baseline/post-skill raw milestone prompts.
- Create: `test/fixtures/milestone-orchestrator/fault-matrix.json`
  - Executable fault cases and expected state/action/resource outcomes.
- Modify: `skills.yaml`
  - Register the active general skill for Codex and Claude, recommended tier `deep`, heavy tier `ultracode`; Cursor and Gemini disabled.
- Modify: `CATALOG.md`
  - Add the matching human-readable row.
- Modify: `USAGE.md`
  - Document PREPARE/RUN/STATUS, automatic draft publication defaults, review routing, and merge/deploy/global-install stops.
- Review only unless a failing test proves a required change: `scripts/sync-skills`, `test/sync_skills_test.rb`, `README.md`, `docs/repo-guidelines.md`.

## Canonical PLAN Contract

`PLAN.md` contains one versioned canonical JSON block. The prose around it may
explain the plan, but the registry is the only source of verification commands,
task dependencies, ownership, and requirement mapping used by executors:

````markdown
<!-- milestone-orchestrator-plan:v1 -->
```json
{
  "schema_version": 1,
  "requirements": {
    "AC-001": {"summary": "Example acceptance criterion"}
  },
  "tasks": {
    "TASK-001": {
      "type": "implementation",
      "depends_on": [],
      "owned_paths": ["lib/example.rb"],
      "acceptance_ids": ["AC-001"],
      "verification_command_ids": ["verify-example"]
    }
  },
  "verification_commands": {
    "verify-example": {
      "argv": ["ruby", "test/example_test.rb"],
      "cwd": ".",
      "env": {"policy": "clean_allowlist", "allow": ["PATH", "HOME"]},
      "timeout_seconds": 120,
      "mutation": false,
      "acceptance_ids": ["AC-001"]
    }
  }
}
```
<!-- /milestone-orchestrator-plan -->
````

The parser rejects shell strings, unknown keys, absolute or escaping working
directories, mutation-enabled verification commands, duplicate IDs, dangling
references, and environment inheritance outside the named allowlist. PREPARE
records the canonical PLAN block digest and requirement-to-task mapping digest
in STATE; `run-verification` accepts only a PLAN path plus a registered command
ID and executes the exact argv/cwd/env/timeout tuple from that approved digest.

## Canonical State Contract

All implementation tasks use one canonical JSON block embedded in `STATE.md`.
JSON avoids YAML aliases and implicit scalar coercion on the repository's Ruby
2.6/Psych baseline:

````markdown
<!-- milestone-orchestrator-state:v1 -->
```json
{
  "schema_version": 1,
  "run": {
    "id": "run-20260713-example",
    "slug": "example",
    "epoch": 1,
    "phase": "prepared",
    "execution_mode": "normal",
    "adapter": "orca",
    "repository": "/absolute/repository/path",
    "object_format": "sha1",
    "coordinator_id": "coordinator-handle",
    "root_task_id": "root-task-id",
    "task_allowlist": [],
    "spec_sha256": "sixty-four-lowercase-hex-characters",
    "plan_sha256": "sixty-four-lowercase-hex-characters",
    "acceptance_mapping_sha256": "sixty-four-lowercase-hex-characters",
    "checkpoint_commit": "git-object-id-matching-object-format",
    "external_snapshot": null,
    "base_branch": "main",
    "base_sha": "git-object-id-matching-object-format",
    "integration_branch": "milestone/example",
    "implementation_subject": "git-object-id-matching-object-format",
    "artifact_versions": [],
    "replans": []
  },
  "evidence_ledger": {
    "relative_path": "milestone-orchestrator/run-20260713-example/evidence.jsonl",
    "anchored_sequence": 0,
    "anchored_sha256": null,
    "control_anchor_commit": null
  },
  "lease": {
    "run_id": "run-20260713-example",
    "owner": "coordinator-handle",
    "host_id": "local-host-id",
    "owner_pid": 12345,
    "owner_start": "process-start-token",
    "epoch": 1,
    "fencing_token": 1,
    "renewed_at": "2026-07-13T11:59:30Z",
    "renewal_interval_seconds": 30,
    "expires_at": "2026-07-13T12:00:00Z"
  },
  "authority": {
    "local_checkpoint": true,
    "implementation_commit": true,
    "push": true,
    "draft_pr": true,
    "pr_ready": false,
    "assign_reviewers": false,
    "merge": false,
    "deploy": false,
    "remote": "origin",
    "forge_repository": "owner/repository",
    "base_ref": "main",
    "head_ref": "milestone/example",
    "remote_ref_expectation": {
      "status": "absent",
      "base_oid": "git-object-id-matching-object-format"
    },
    "pr_identity": null,
    "action_envelopes": {
      "push": {
        "schema": "push/v1",
        "remote": "origin",
        "source_oid": "git-object-id-matching-object-format",
        "destination_ref": "refs/heads/milestone/example",
        "force": false,
        "effect_snapshot_id": "effect-snapshot-id"
      },
      "draft_pr": {
        "schema": "draft_pr/v1",
        "forge_repository": "owner/repository",
        "base_ref": "main",
        "head_ref": "milestone/example",
        "effect_snapshot_id": "effect-snapshot-id"
      }
    },
    "required_checks": ["fixture-ci"]
  },
  "budgets": {
    "transient_retries": 1,
    "task_failures": 3,
    "review_remediation_rounds": 3,
    "replans": 2,
    "ci_wait_seconds": 1800,
    "ci_infra_retries": 2,
    "no_progress_cycles": 2
  },
  "tasks": {},
  "acceptance": {},
  "findings": {},
  "resources": {},
  "reconciliations": [],
  "verification_anchors": {},
  "action_anchors": {},
  "closeout": null
}
```
<!-- /milestone-orchestrator-state -->
````

The validator treats the JSON block as authoritative data and all surrounding
Markdown as human-readable context only. Templates may use obvious
angle-bracket instructional tokens, but an initialized RUN state may not contain
unresolved tokens.

## Verified Repository Baseline

- The repository uses dependency-free Ruby/Minitest tooling and Apple system
  Ruby 2.6.10; do not use `filter_map`, pattern matching, endless methods, or
  newer keyword-argument assumptions.
- The pre-plan fast suite passed with 25 runs, 352 assertions, 0 failures, and 0
  errors using the flat `test/*_test.rb` loader.
- Bare system Python lacks PyYAML; the installed skill validator succeeds through
  `rtk uv run --with pyyaml python .../quick_validate.py`.
- Current Orca help supports stable `orca tab close --page <id>` even though
  older reference examples emphasize mutable indexes; capability-probe and use
  the stable page form first.
- Current Orca agent-first worktree creation cannot express exact model/effort;
  protected routes need custom argv and must record any extra fallback terminal.
- Native subagent controls do not guarantee exact model/effort/sandbox identity;
  protected Codex roles use fresh `codex exec`, and Claude routes use explicit
  model/effort/permission flags after capability probes.

## Task 0: Prove The Capability Topology Before Building The Workflow

**Files:**
- Create: `docs/plans/2026-07-13-milestone-orchestrator-capability-matrix.md`
- Read: `/Users/tunji/.agents/skills/orchestration/SKILL.md`
- Read: `/Users/tunji/.agents/skills/orca-cli/SKILL.md`
- Read: current Codex and Claude CLI help

- [ ] **Step 1: Record exact host provenance**

  Run read-only probes and capture the exact commands, exit statuses, relevant
  help excerpts, runtime IDs, and observed CLI versions. Do not assume `/goal`,
  `orca --version`, `orchestration check --peek`, model-selection flags on Orca
  agent-first launch, or a run-scoped `run-stop`; treat them as unavailable
  unless the current host proves them.

  Minimum probes:

  ```bash
  rtk orca status --json
  rtk orca worktree ps --json
  rtk orca terminal list --json
  rtk orca tab list --worktree all --json
  rtk orca orchestration task-list --brief --json
  rtk codex --version
  rtk codex exec --help
  rtk claude --version
  rtk claude --help
  ```

  If outside an Orca-managed terminal on Linux, use `orca-ide` instead of bare
  `orca` as required by the installed adapter guidance.

- [ ] **Step 2: Run disposable enforcement probes**

  Use a temporary Git repository and no production credentials. Before any Orca
  mutation, generate a unique probe run ID/name prefix and capture complete
  task, dispatch, worktree, terminal, and tab inventories. Record every creation
  response and stable ID. Prove or mark unavailable:

  - Exact Orca task/dispatch/source-pane lifecycle.
  - Agent-first versus custom-argv model/effort identity.
  - Coordinator implementation-write prevention or attributable detection.
  - Narrow control-writer ability to change only control artifacts.
  - Ordinary-worker denial of the Git-common-dir control root, executor socket,
    credential homes/files, process inspection, ambient agent sockets, and
    direct `execute-action` invocation through an OS-enforced sandbox,
    container, or distinct principal. Same-user file modes and bearer tokens
    alone are explicitly insufficient.
  - Protected executor service ownership of Git/forge/Orca credentials, with
    workers able to submit only typed grants over a narrow socket/API.
  - Stale epoch/token rejection before control or external actions.
  - Stable cleanup identity after terminal/tab relisting.
  - Codex `$code-review <explicit-intensity>` and Claude `/code-review` routing.

  In a guaranteed cleanup phase, touch only recorded probe resources, re-list
  everything, verify owned-resource disappearance and unchanged foreign
  resources, and persist ambiguous/failed cleanup as retained-resource evidence.
  Never call global reset, merge, deploy, a production remote, or an existing
  browser session during the spike. If unique ownership cannot be proven before
  mutation, skip that mutating probe and mark the capability unavailable.
  Actively attempt file, socket, process, token, credential-home, ambient-agent,
  and direct-executable bypasses from each ordinary-worker profile. A host
  adapter is blocked unless the required boundary is prevented by the platform
  or isolated by the tested launcher/service topology; logging an avoidable
  same-user bypass is not an acceptable substitute.

- [ ] **Step 3: Write the capability matrix**

  Use one row per required capability with columns:

  ```markdown
  | Capability | Orca | Native Codex | Native Claude | Enforcement evidence | Required fallback/block |
  |---|---|---|---|---|---|
  ```

  Each host cell is exactly `enforced`, `detectable`, `unavailable`, or
  `not-applicable`. Record the exact mechanism and evidence path. Any required
  row marked `unavailable` must map to a safe fallback or explicit RUN blocker;
  do not continue by silently weakening the validated design.

- [ ] **Step 4: Resolve capability-driven plan changes**

  If the spike proves that the planned `control-state` or `authorize-action`
  boundary cannot work, adversarially review a design/plan replan before writing
  the skill. If it works, freeze its CLI contracts in the matrix so later tasks
  cannot invent incompatible interfaces.

- [ ] **Step 5: Commit the spike checkpoint**

  ```bash
  rtk git add docs/plans/2026-07-13-milestone-orchestrator-capability-matrix.md
  rtk git diff --cached --check
  rtk git commit -m "Record milestone orchestrator capabilities"
  ```

## Task 0B: Freeze And Run The Pre-Skill Pressure Baseline

**Files:**
- Create: `test/milestone_orchestrator_pressure_test.rb`
- Create: `test/fixtures/milestone-orchestrator/pressure-protocol.json`
- Create: `test/fixtures/milestone-orchestrator/pressure-prompts/*.md`
- Create: `skills/general/milestone-orchestrator/scripts/run-pressure-suite`
- Create: `docs/plans/2026-07-13-milestone-orchestrator-pressure-baseline.json`

- [ ] **Step 1: Write RED runner/scorer contract tests**

  With a deterministic fake launcher, test fresh unique run IDs, exact prompt
  and protocol hashes, repeated trials, host/model/config provenance, raw event
  retention, baseline/with-skill contamination rejection, minimum-effect and
  confidence scoring, exclusions, and zero-tolerance failures.

- [ ] **Step 2: Implement the Ruby 2.6-compatible runner**

  Required CLI:

  ```text
  run-pressure-suite --mode baseline|with-skill --protocol FILE --results DIR --launcher-json JSON --json
  run-pressure-suite score --protocol FILE --baseline DIR --with-skill DIR --output REPORT --json
  ```

  A launcher is an argv array with explicit model/effort/fresh-context settings;
  no shell strings. Baseline mode must prove the new skill path is absent from
  the packet. With-skill mode must hash and record the exact skill package.

- [ ] **Step 3: Freeze the protocol before observing baseline results**

  Create at least six prompts covering coordinator takeover, routine questions,
  ownership overlap, mixed-model routing, final review/remediation, publication
  stop, cleanup, and recovery. Freeze repetitions, metrics, minimum effects,
  confidence treatment, exclusions, and zero-tolerance rules. Commit the corpus,
  protocol, test, and runner before executing the real baseline.

  ```bash
  rtk chmod +x skills/general/milestone-orchestrator/scripts/run-pressure-suite
  rtk ruby test/milestone_orchestrator_pressure_test.rb
  rtk git add test/milestone_orchestrator_pressure_test.rb test/fixtures/milestone-orchestrator/pressure-protocol.json test/fixtures/milestone-orchestrator/pressure-prompts skills/general/milestone-orchestrator/scripts/run-pressure-suite
  rtk git diff --cached --check
  rtk git commit -m "Add milestone pressure baseline"
  ```

- [ ] **Step 4: Run and persist the real pre-skill baseline**

  Use the capability-matrix-selected fresh-context launchers and exact frozen
  repetition count. Do not include the new skill or intended answers. Store raw
  results outside Git when they contain large transcripts, but commit the
  sanitized provenance, hashes, metric counts, zero-tolerance outcomes, and
  result-directory digest to the baseline report.

- [ ] **Step 5: Commit the baseline report**

  ```bash
  rtk git add docs/plans/2026-07-13-milestone-orchestrator-pressure-baseline.json
  rtk git diff --cached --check
  rtk git commit -m "Record milestone pressure baseline"
  ```

## Task 1: Add the Skill Entry Point Contract

**Files:**
- Create: `test/milestone_orchestrator_skill_contract_test.rb`
- Create: `skills/general/milestone-orchestrator/SKILL.md`
- Create: `skills/general/milestone-orchestrator/agents/openai.yaml`
- Modify: `skills.yaml`
- Modify: `CATALOG.md`

- [ ] **Step 1: Write the failing entrypoint contract test**

  Create the test with these initial assertions:

  ```ruby
  require "minitest/autorun"
  require "yaml"

  class MilestoneOrchestratorSkillContractTest < Minitest::Test
    REPO = File.expand_path("..", __dir__)
    ROOT = File.join(REPO, "skills", "general", "milestone-orchestrator")

    def read(relative)
      File.read(File.join(ROOT, relative))
    end

    def test_skill_frontmatter_and_core_boundaries
      text = read("SKILL.md")
      frontmatter = YAML.safe_load(text[/\A---\n(.*?)\n---/m, 1])

      assert_equal "milestone-orchestrator", frontmatter.fetch("name")
      assert_match(/large repository milestones/i, frontmatter.fetch("description"))
      assert_includes text, "## PREPARE"
      assert_includes text, "## RUN"
      assert_includes text, "The coordinator does not implement"
      assert_includes text, "commit, push, and draft pull request"
      assert_includes text, "Never merge or deploy"
      assert_includes text, "host-correct final code review"
    end

    def test_openai_interface_metadata
      data = YAML.safe_load(read("agents/openai.yaml"))
      interface = data.fetch("interface")
      assert_equal "Milestone Orchestrator", interface.fetch("display_name")
      assert_includes interface.fetch("default_prompt"), "$milestone-orchestrator"
    end
  end
  ```

- [ ] **Step 2: Run the test and observe RED**

  Run:

  ```bash
  rtk ruby test/milestone_orchestrator_skill_contract_test.rb
  ```

  Expected: ERROR with `No such file or directory ... milestone-orchestrator/SKILL.md`.

- [ ] **Step 3: Write the complete `SKILL.md` entrypoint**

  Use only `name` and `description` in frontmatter. The description must trigger
  on requests to front-load milestone questions/specification and then run an
  unattended multi-agent implementation through review and draft PR, especially
  in Orca, while also mentioning native Codex/Claude fallback.

  Required sections, in this order:

  1. `# Milestone Orchestrator`
  2. `## Invocation And Modes` — natural-language invocation, explicit
     `PREPARE`, `RUN`, and `STATUS`; default a new request to PREPARE; reject RUN
     without reviewed/approved artifacts and valid preflight.
  3. `## Non-Negotiable Boundaries` — exact manager-only rule, no routine RUN
     questions, worker-owned remediation/integration, human author, no unrelated
     cleanup, no global reset, no automatic merge/deploy.
  4. `## Artifact Routing` — read the intake/task/state references and copy the
     three assets into the owning repo's established milestone directory.
  5. `## PREPARE` — ground repo, decision inventory, consolidated packets,
     write SPEC and PLAN, run repository `adversarial-review` at model-selected
     tier, obtain one final approval, initialize STATE, checkpoint/preflight.
  6. `## RUN` — reconcile, validate lease/state, dispatch bounded waves, route
     models, review/remediate/verify, integrate serially, publish draft PR,
     mandatory final review, full gate/CI, cleanup, stop.
  7. `## Capability Roles` — coordinator, fenced control writer, independent
     verifier, constrained external-action executor, ordinary worker.
  8. `## Failure, Cancellation, And Recovery` — rolling waits, task-level
     budgets, new attempts, epoch fencing, allowlisted cancellation, retained
     resources, recovery from artifacts without promising runtime resurrection.
  9. `## Host Selection` — Orca is normative; native adapters must pass the same
     preflight and final-review contracts.
  10. `## Final Response Contract` — PR/branch/SHAs, exact checks, CI, review,
      acceptance, cleanup, retained resources, risks, and merge/deploy options.
  11. `## References` — link every file under `references/` and every asset.

  Include these exact policy sentences so contract tests and future agents do
  not weaken the design:

  ```markdown
  The coordinator does not implement production code, tests, configuration, migrations, generated deliverables, conflict resolutions, or implementation documentation.

  Within the approved publication envelope, RUN automatically performs implementation commits, push, and draft pull request creation or update unless PREPARE recorded an opt-out.

  Never merge or deploy; stop after the host-correct final code review, remediation, full verification, CI disposition, and safe resource cleanup are complete.
  ```

  Create `agents/openai.yaml` with:

  ```yaml
  interface:
    display_name: "Milestone Orchestrator"
    short_description: "Orchestrate unattended milestone implementation"
    default_prompt: "Use $milestone-orchestrator to prepare and run this repository milestone."
  ```

- [ ] **Step 4: Run the targeted test and observe GREEN**

  Run:

  ```bash
  rtk ruby test/milestone_orchestrator_skill_contract_test.rb
  ```

  Expected: `1 runs, ... 0 failures, 0 errors, 0 skips`.

- [ ] **Step 5: Register the skill in the same change**

  Add the exact Task 7 manifest entry and catalog row now, with Codex/Claude
  install flags disabled. This satisfies the repository rule that adding a skill
  and updating both indexes is one change. Task 7 later adds exhaustive
  metadata/usage contract coverage; it does not postpone registration.

- [ ] **Step 6: Commit Task 1**

  ```bash
  rtk git add test/milestone_orchestrator_skill_contract_test.rb skills/general/milestone-orchestrator/SKILL.md skills/general/milestone-orchestrator/agents/openai.yaml skills.yaml CATALOG.md
  rtk git diff --cached --check
  rtk git commit -m "Add milestone orchestrator entrypoint"
  ```

## Task 2: Implement the Canonical PLAN/STATE Parsers and Core Validator

**Files:**
- Create: `test/milestone_orchestrator_state_validator_test.rb`
- Create: `skills/general/milestone-orchestrator/scripts/validate-state`
- Create: `skills/general/milestone-orchestrator/scripts/lib/state_document.rb`
- Create: `skills/general/milestone-orchestrator/references/state-schema.md`
- Create: `skills/general/milestone-orchestrator/assets/state-template.md`

- [ ] **Step 1: Write test helpers and parser/schema RED cases**

  The test must use `JSON`, `Open3.capture3`, and `Tempfile`. Define:

  ```ruby
  VALIDATOR = File.join(
    REPO,
    "skills/general/milestone-orchestrator/scripts/validate-state"
  )

  def valid_state
    {
      "schema_version" => 1,
      "run" => {
        "id" => "run-test",
        "slug" => "test",
        "epoch" => 1,
        "phase" => "prepared",
        "execution_mode" => "normal",
        "adapter" => "orca",
        "repository" => "/tmp/repository",
        "object_format" => "sha1",
        "coordinator_id" => "coordinator-1",
        "root_task_id" => "root-1",
        "task_allowlist" => [],
        "spec_sha256" => "a" * 64,
        "plan_sha256" => "b" * 64,
        "acceptance_mapping_sha256" => "d" * 64,
        "checkpoint_commit" => "c" * 40,
        "external_snapshot" => nil,
        "base_branch" => "main",
        "base_sha" => "c" * 40,
        "integration_branch" => "milestone/test",
        "implementation_subject" => "c" * 40,
        "artifact_versions" => [],
        "replans" => []
      },
      "evidence_ledger" => {
        "relative_path" => "milestone-orchestrator/run-test/evidence.jsonl",
        "anchored_sequence" => 0,
        "anchored_sha256" => nil,
        "control_anchor_commit" => nil
      },
      "lease" => {
        "run_id" => "run-test",
        "owner" => "coordinator-1",
        "host_id" => "test-host",
        "owner_pid" => Process.pid,
        "owner_start" => "test-process-start",
        "epoch" => 1,
        "fencing_token" => 1,
        "renewed_at" => "2098-12-31T23:59:30Z",
        "renewal_interval_seconds" => 30,
        "expires_at" => "2099-01-01T00:00:00Z"
      },
      "authority" => {
        "local_checkpoint" => true,
        "implementation_commit" => true,
        "push" => true,
        "draft_pr" => true,
        "pr_ready" => false,
        "assign_reviewers" => false,
        "merge" => false,
        "deploy" => false,
        "remote" => "origin",
        "forge_repository" => "owner/repository",
        "base_ref" => "main",
        "head_ref" => "milestone/test",
        "remote_ref_expectation" => {
          "status" => "absent",
          "base_oid" => "c" * 40
        },
        "pr_identity" => nil,
        "action_envelopes" => {
          "push" => {
            "schema" => "push/v1",
            "remote" => "origin",
            "source_oid" => "c" * 40,
            "destination_ref" => "refs/heads/milestone/test",
            "force" => false,
            "effect_snapshot_id" => "effects-1"
          },
          "draft_pr" => {
            "schema" => "draft_pr/v1",
            "forge_repository" => "owner/repository",
            "base_ref" => "main",
            "head_ref" => "milestone/test",
            "effect_snapshot_id" => "effects-2"
          }
        },
        "required_checks" => ["fixture-ci"]
      },
      "budgets" => {
        "transient_retries" => 1,
        "task_failures" => 3,
        "review_remediation_rounds" => 3,
        "replans" => 2,
        "ci_wait_seconds" => 1800,
        "ci_infra_retries" => 2,
        "no_progress_cycles" => 2
      },
      "tasks" => {},
      "acceptance" => {},
      "findings" => {},
      "resources" => {},
      "reconciliations" => [],
      "verification_anchors" => {},
      "action_anchors" => {},
      "closeout" => nil
    }
  end

  def state_markdown(data)
    <<~MARKDOWN
      # State

      <!-- milestone-orchestrator-state:v1 -->
      ```json
      #{JSON.pretty_generate(data)}
      ```
      <!-- /milestone-orchestrator-state -->
    MARKDOWN
  end
  ```

  Initial tests:

  - The PLAN marker/block parses separately, canonicalizes to a stable digest,
    and validates the exact requirements/tasks/verification-command grammar
    defined above before any STATE binding is accepted.
  - PLAN rejects raw shell strings, ambient environment inheritance,
    absolute/escaping working directories, mutation-enabled verifier commands,
    unknown keys, dangling references, and duplicate IDs.
  - Valid state exits 0 and emits `{ "valid": true, "errors": [] }` under
    `--json`.
  - Missing or duplicate start/end markers exits 2 with stable code
    `state_block_count`.
  - Malformed JSON exits 2 with `state_json_invalid`.
  - Wrong schema version exits 1 with `schema_version_unsupported`.
  - Missing top-level key exits 1 with `required_key_missing`.
  - `merge: true` or `deploy: true` exits 1 with
    `forbidden_authority_enabled`.
  - Non-positive or missing budget exits 1 with `budget_invalid`.

- [ ] **Step 2: Run the validator test and observe RED**

  ```bash
  rtk ruby test/milestone_orchestrator_state_validator_test.rb
  ```

  Expected: ERROR because `scripts/validate-state` does not exist.

- [ ] **Step 3: Implement the dependency-free validator shell**

  Put canonical PLAN/STATE marker extraction, JSON parsing, object hashing, and
  artifact digest helpers in `scripts/lib/state_document.rb`. Use Ruby 2.6-compatible
  syntax, a shebang, `JSON`, `Time`, and `OptionParser`.
  Required public behavior:

  ```text
  validate-state check --state PATH --spec SPEC --plan PLAN [--json]
  validate-state transition --from-state CURRENT --to-state CANDIDATE --spec SPEC --plan PLAN [--json]
  exit 0: valid
  exit 1: parsed state violates schema/invariant
  exit 2: CLI, marker, file, or JSON parse failure
  ```

  Define focused functions with these signatures:

  ```ruby
  def extract_plan_block(markdown)  # => String or raises ParseError
  def parse_plan(markdown)          # => Hash
  def validate_plan(plan)           # => Array<Hash{"code","path","message"}>
  def extract_state_block(markdown) # => String or raises ParseError
  def parse_state(markdown)         # => Hash
  def validate_state(state)         # => Array<Hash{"code","path","message"}>
  def validate_run(run, errors)
  def validate_lease(lease, run, errors)
  def validate_authority(authority, errors)
  def validate_budgets(budgets, errors)
  def validate_tasks(tasks, acceptance, errors)
  def validate_findings(findings, errors)
  def validate_resources(resources, errors)
  def validate_closeout(state, errors)
  def validate_transition(current, candidate) # => transition errors
  def validate_artifact_bindings(state, spec_path, plan_path, errors)
  ```

  JSON output shape is stable:

  ```json
  {
    "valid": false,
    "state": "path/to/STATE.md",
    "errors": [
      {"code":"budget_invalid","path":"budgets.ci_wait_seconds","message":"must be a positive integer"}
    ]
  }
  ```

  `check` hashes the exact SPEC and PLAN bytes, parses the immutable acceptance
  requirement/task mapping and verifier registry from PLAN, and rejects digest
  or coverage mismatch. This shared parser is the sole authority later used by
  `run-verification`; no later task may invent a separate PLAN grammar.
  `transition` additionally validates current-to-candidate legal transitions,
  immutable run fields, append-only evidence/action anchor and reconciliation records,
  replan semantics, and execution-mode conditions. Schema v1 rejects unknown
  versions. `state-schema.md` records the future migration contract: any later
  version must ship a fenced, atomic, idempotent migration from each supported
  prior version with evidence-preservation and rollback tests; manual editing is
  never the fallback.

  Do not compare lease expiry with wall-clock time in the static validator;
  validate RFC3339 shape, epoch equality, positive fencing token, and
  owner/coordinator equality. Runtime freshness belongs to adapter preflight.

- [ ] **Step 4: Write `state-schema.md` and `state-template.md`**

  `state-schema.md` must define all top-level keys, task/attempt/acceptance/
  finding/resource/closeout records, allowed enums, stable error codes, and the
  field-specific source-of-truth table. Use these enums:

  ```yaml
  run_phase: [prepared, preflight, running, final_review, closeout, awaiting_remote_closeout, closed, blocked, escalated, aborting, aborted]
  execution_mode: [normal, restricted_no_commit]
  object_format: [sha1, sha256]
  task_type: [implementation, review, verification, remediation, integration, cleanup, control]
  task_stage: [pending, implemented, reviewed, verified, integrated, closed]
  task_condition: [active, blocked, failed, circuit_open, cleanup_pending, retained]
  attempt_status: [created, dispatched, completed, failed, blocked, abandoned]
  acceptance_status: [pending, passed, failed, blocked]
  finding_status: [reported, validated, remediation_dispatched, remediated, reverified, closed, rejected_with_rationale]
  resource_status: [owned_active, cleanup_pending, removed, retained]
  ```

  `state-template.md` must contain exactly one canonical JSON block plus journal
  headings `## Decisions`, `## Reconciliations`, `## Retained Resources`, and
  `## Next Ready Work`.

- [ ] **Step 5: Run tests and make the script executable**

  ```bash
  rtk chmod +x skills/general/milestone-orchestrator/scripts/validate-state
  rtk ruby test/milestone_orchestrator_state_validator_test.rb
  ```

  Expected: all parser/schema tests pass.

- [ ] **Step 6: Commit Task 2**

  ```bash
  rtk git add test/milestone_orchestrator_state_validator_test.rb skills/general/milestone-orchestrator/scripts/validate-state skills/general/milestone-orchestrator/scripts/lib/state_document.rb skills/general/milestone-orchestrator/references/state-schema.md skills/general/milestone-orchestrator/assets/state-template.md
  rtk git diff --cached --check
  rtk git commit -m "Add milestone state validation"
  ```

## Task 3: Add Lifecycle, Ownership, Evidence, And Closeout Invariants

**Files:**
- Modify: `test/milestone_orchestrator_state_validator_test.rb`
- Modify: `skills/general/milestone-orchestrator/scripts/validate-state`
- Modify: `skills/general/milestone-orchestrator/references/state-schema.md`

- [ ] **Step 1: Add RED tests for stable tasks and dispatch attempts**

  Add fixture builders for one implementation task, one acceptance row, one
  finding, and one resource. Add tests for:

  - Every task ID equals its map key and has `type`, `stage`, `condition`,
    `dependencies`, `acceptance_ids`, `owned_paths`, `attempts`, and `failure_count`.
  - Every attempt has unique `attempt_id`, positive `number`, host task and
    dispatch IDs, requested/observed base SHA, worker identity, and status.
  - A completed attempt cannot advance an implementation task beyond
    `implemented` without a passed coordinator acceptance gate.
  - A new attempt after terminal `worker_done` uses a new host task ID.
  - `failure_count` belongs to the stable task and `>= budgets.task_failures`
    requires `condition: circuit_open`.
  - Dependencies must exist and cycles produce `task_dependency_cycle`.
  - Overlapping `owned_paths` among active writer tasks produces
    `writer_ownership_overlap` unless a dependency serializes them.
  - `implementation_subject` uses the repository's declared object format and
    changes only when implementation content changes; a finite control-anchor
    commit may be its descendant without invalidating evidence.
  - Restricted no-commit mode requires `checkpoint_commit: null`, one serialized
    same-worktree writer, immutable external snapshot URI/digest, and disabled
    implementation commit/push/draft-PR authority.

- [ ] **Step 2: Add RED tests for acceptance and evidence**

  Require acceptance rows to contain:

  ```json
  {
    "requirement_id": "AC-001",
    "plan_task_ids": ["TASK-001"],
    "status": "passed",
    "command_id": "verify-example",
    "plan_sha256": "<64 hex>",
    "executor_id": "verifier-1",
    "source_sha": "<40 hex>",
    "exit_status": 0,
    "output_sha256": "<64 hex>",
    "recorded_at": "2026-07-13T12:00:00Z"
  }
  ```

  Tests reject missing executor/command ID/PLAN digest/output digest, unknown task IDs, omitted
  approved requirements, a PLAN mapping digest mismatch, passed evidence at an
  `implementation_subject` different from the current subject, and a verified
  or integrated task with pending/failed acceptance. Tests prove that a
  control-anchor commit preserves freshness while an implementation-subject
  change invalidates dependent evidence.

- [ ] **Step 3: Add RED tests for findings, resources, and closeout**

  Tests must reject:

  - Open validated merge-blocking finding at integration or closeout.
  - `removed` resource without creation provenance, preservation evidence,
    cleanup evidence, or stable-identity disappearance proof.
  - Cleanup of `pre_existing: true` or `configured: true` resources.
  - Locally `closed` non-published/restricted run with missing closeout keys,
    stale acceptance, unresolved blocker, active resource, or merge/deploy evidence.
  - A published branch STATE that claims post-push terminal facts or `closed`
    instead of `awaiting_remote_closeout`; the final CI/review/cleanup/closeout
    disposition must be a digest-chained external-ledger record bound to the
    anchored STATE prefix and exact published head.
  - Reconciliation without field, old/new values, source, actor, and timestamp.
  - Plan-only replan without old/new artifact digests, acceptance-map version,
    adversarial-review evidence, drift result, budget consumption, task
    supersession/carry-forward rules, and approval provenance; any SPEC or
    authority change without user reapproval.
  - Budget exhaustion without `phase: escalated` plus structured evidence, or a
    terminal external closeout whose required-check snapshot does not match the
    final published CI observation.

- [ ] **Step 4: Run the expanded test and observe RED**

  ```bash
  rtk ruby test/milestone_orchestrator_state_validator_test.rb
  ```

  Expected: new tests fail with missing invariant codes.

- [ ] **Step 5: Implement the minimal invariant checks**

  Add stable error codes exactly matching the tests. Use deterministic sorting by
  `[code, path, message]` before output. Do not add host/network calls to the
  validator. Implement graph traversal iteratively or with a recursion guard so
  a malicious cycle cannot loop forever.

- [ ] **Step 6: Run targeted and full root tests**

  ```bash
  rtk ruby test/milestone_orchestrator_state_validator_test.rb
  rtk ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |path| require File.expand_path(path) }'
  ```

  Expected: all tests pass.

- [ ] **Step 7: Commit Task 3**

  ```bash
  rtk git add test/milestone_orchestrator_state_validator_test.rb skills/general/milestone-orchestrator/scripts/validate-state skills/general/milestone-orchestrator/references/state-schema.md
  rtk git diff --cached --check
  rtk git commit -m "Enforce milestone lifecycle invariants"
  ```

## Task 3A: Implement Lease-Fenced Control And Action Authorization

**Files:**
- Create: `test/milestone_orchestrator_control_state_test.rb`
- Create: `test/milestone_orchestrator_role_isolation_test.rb`
- Create: `skills/general/milestone-orchestrator/scripts/control-state`
- Create: `skills/general/milestone-orchestrator/scripts/authorize-action`
- Create: `skills/general/milestone-orchestrator/scripts/execute-action`
- Create: `skills/general/milestone-orchestrator/scripts/launch-role`
- Create: `skills/general/milestone-orchestrator/scripts/inspect-effects`
- Modify: `skills/general/milestone-orchestrator/references/state-schema.md`

- [ ] **Step 1: Write RED lease and transition tests**

  Use only temporary directories. `control-state` must store its lease beneath
  the target repository's Git common directory, never in a worker worktree:

  ```text
  <git-common-dir>/milestone-orchestrator/<run-id>/lease.json
  <git-common-dir>/milestone-orchestrator/<run-id>/lock
  ```

  Test these commands:

  ```text
  control-state lease acquire --repo DIR --run-id ID --state STATE --owner OWNER --host-id HOST --owner-pid PID --owner-start START --ttl 60 --renew-every 30 --json
  control-state lease renew --repo DIR --run-id ID --owner OWNER --token N --ttl 60 --json
  control-state lease takeover --repo DIR --run-id ID --owner OWNER --host-id HOST --owner-pid PID --owner-start START --expected-token N --ttl 60 --json
  control-state lease advance-epoch --repo DIR --run-id ID --owner OWNER --token N --json
  control-state lease release --repo DIR --run-id ID --owner OWNER --token N --json
  control-state transition --repo DIR --run-id ID --candidate CANDIDATE --expected-state-sha256 SHA --owner OWNER --token N --spec SPEC --plan PLAN --json
  ```

  Assert exclusive acquisition, a canonical STATE realpath inside the recorded
  repository, monotonically increasing tokens that survive release/reacquire,
  owner/token checks, renewal cadence and expiry refusal, refusal to take over an
  unexpired live lease, takeover only after expiry plus failed host/PID/start
  liveness probe, epoch advancement, atomic current-to-candidate validation
  through `validate-state transition`, expected-current-SHA compare-and-swap,
  immutable-field protection, and temp-file + fsync + rename replacement.

  The test must launch two Ruby child processes attempting acquisition and assert
  exactly one succeeds. It must also assert a stale token cannot transition
  STATE after takeover.

- [ ] **Step 2: Write RED action-authorization tests**

  Required CLI:

  ```text
  inspect-effects --repo DIR --state STATE --action ACTION --target-json JSON --backend fake|github|orca --json
  authorize-action --state STATE --owner OWNER --token N --action ACTION --request-json JSON --effect-snapshot-id ID --idempotency-key KEY --json
  ```

  Supported actions are exactly:

  ```text
  implementation_commit push draft_pr pr_ready assign_reviewers cleanup_terminal cleanup_browser cleanup_worktree
  ```

  There is deliberately no `merge` or `deploy` action. Define a discriminated,
  versioned request/grant union with an exact required/forbidden-field schema,
  preconditions, postconditions, and idempotency identity for every supported
  action:

  ```text
  implementation_commit/v1 push/v1 draft_pr/v1 pr_ready/v1
  assign_reviewers/v1 cleanup_terminal/v1 cleanup_browser/v1 cleanup_worktree/v1
  ```

  Schemas are closed (`additionalProperties: false`): every field not listed for
  that tag is forbidden. Freeze this table in tests and `state-schema.md`:

  | Tag | Required request fields | Required pre/postconditions | Idempotency identity |
  |---|---|---|---|
  | `implementation_commit/v1` | repository, parent_oid, tree_oid, message_sha256, author_name, author_email, allowed_paths, scan_id | clean index matches tree; resulting commit has exact parent/tree/message/author | repository + parent + tree + message digest |
  | `push/v1` | repository, remote, source_oid, destination_full_ref, force=false, remote_ref_expectation, scan_id, effect_snapshot_id | fetched ref matches tagged expectation; remote full ref becomes source OID | remote URL identity + full ref + source OID |
  | `draft_pr/v1` | forge_repository, base_ref, head_ref, title_sha256, body_sha256, effect_snapshot_id | one matching open PR is absent or has recorded identity; resulting PR is draft with exact base/head | forge repo + base + head |
  | `pr_ready/v1` | forge_repository, pr_identity, expected_head_oid, effect_snapshot_id | PR is recorded draft at exact head; same PR becomes ready | forge repo + PR identity + head |
  | `assign_reviewers/v1` | forge_repository, pr_identity, expected_head_oid, reviewer_ids, effect_snapshot_id | PR/head match; exact normalized reviewer set is requested | forge repo + PR + head + reviewer-set digest |
  | `cleanup_terminal/v1` | adapter, worktree_id, terminal_handle, creation_record_id | resource is run-created/nonconfigured and empty/preserved; stable identity disappears | adapter + terminal stable identity + creation record |
  | `cleanup_browser/v1` | adapter, worktree_id, browser_page_id, creation_record_id | resource is run-created/nonconfigured; stable page identity disappears | adapter + page ID + creation record |
  | `cleanup_worktree/v1` | adapter, repository, worktree_id, worktree_realpath, preserved_head_oid, creation_record_id | run-created worktree is clean/preserved and contains no active owned resource; stable identity and realpath disappear | adapter + worktree ID + creation record |

  Common grant metadata—schema tag, grant ID, run ID, epoch/token, request
  digest, issued/expires timestamps, one-shot nonce, and caller-independent
  effect/scan record digests—is added by the authorizer and is never accepted
  from the request payload.

  Examples: `push/v1` requires remote, source OID, destination full ref, tagged
  remote-ref expectation, non-force flag, outgoing-scan ID, and effect snapshot;
  it forbids a PR number or resource ID. `cleanup_browser/v1` requires adapter,
  stable page ID, creation provenance, and worktree identity; it forbids Git or
  forge fields. Tests cover every union member's missing, extra, cross-action,
  normalization, precondition, postcondition, and idempotency cases.

  `remote_ref_expectation` is a tagged union: initial publication requires
  `{status:"absent",base_oid:OID}` and proves the remote full ref is absent;
  updates require `{status:"present",oid:OID}`. The outgoing scan for an absent
  ref covers `base_oid..source_oid`; no nullable OID or empty range is allowed.

  `inspect-effects` derives an immutable, freshness-bounded snapshot from the
  repository workflows plus authoritative forge/Orca APIs: workflows, deploy
  hooks, rulesets, merge automation, bots, webhooks, reviewer notifications,
  and cleanup target identity. Callers may identify the action and target but
  may not assert their own effect list. Opaque, incomplete, stale, or
  contradictory inspection blocks authorization. `execute-action` refreshes or
  rechecks the snapshot immediately before mutation.

  Authorization creates a one-shot typed grant under the protected run control
  root, scoped to the normalized request, effect-snapshot digest, remote and
  implementation object IDs, scan evidence ID, epoch/token, and idempotency key.
  Tests reject stale tokens, disabled authority, wrong target, unknown effect,
  pre-existing/configured cleanup resources, and unsupported actions.

- [ ] **Step 2A: Write RED protected-service and role-isolation tests**

  A mode-`0600` credential file under the same user is not an isolation
  boundary. `execute-action` runs as a long-lived protected service (or an
  equivalent distinct-principal/container service) started before workers:

  ```text
  execute-action serve --repo DIR --run-id ID --socket SOCKET --backend fake|git|github|orca --credentials-env-file FILE --json
  execute-action submit --socket SOCKET --state STATE --grant GRANT_ID --json
  launch-role --adapter ADAPTER --role ROLE --repo DIR --run-id ID -- argv...
  ```

  The service exclusively owns credentials and the control root. `launch-role`
  consumes the capability matrix and creates an OS-enforced worker profile that
  cannot read/list the control root, connect to unauthorized sockets, inspect
  executor process arguments/environment, read credential homes/files, invoke
  `execute-action` directly, inherit ambient agent/forge sockets, or use
  unapproved network/mutation surfaces. Same-user token secrecy is never counted
  as enforcement.

  From each claimed adapter, tests actively attempt direct file, directory,
  socket, process, token, credential, executable, Git-push, and forge bypasses.
  They also test revocation/takeover between grant and submission, repeated
  idempotency keys, concurrent claims, raw-command injection, and in-flight
  failure records. The fake service proves fixed argv templates, immediate
  lease/state/target/effect/scan revalidation, postcondition checks, one-shot
  consumption, and digest-chained audit append. If the local host cannot provide
  this boundary for an adapter, that adapter is recorded `unavailable` and RUN
  blocks; detectable same-user access is not sufficient for external actions.

- [ ] **Step 3: Run all control-plane tests and observe RED**

  ```bash
  rtk ruby test/milestone_orchestrator_control_state_test.rb
  rtk ruby test/milestone_orchestrator_role_isolation_test.rb
  ```

- [ ] **Step 4: Implement `control-state`**

  Use `File.open(lock_path, File::RDWR | File::CREAT, 0o600)` with
  `flock(File::LOCK_EX)` for local atomicity. Use JSON files, `Process.kill(0,
  pid)` plus host/process-start identity for same-host liveness, `Time.iso8601`,
  `SecureRandom`, and atomic rename. Treat `EPERM` as alive and reject PID reuse.
  Preflight restricts this implementation to one machine and a local filesystem;
  cross-host or network-filesystem coordination is unavailable and blocks RUN.
  Never steal an unexpired lease. Never accept caller-provided lease paths.

  `transition` holds the lock across canonical-path resolution, current read,
  expected-SHA comparison, sibling `validate-state transition` execution, and
  atomic replacement. It requires candidate run ID/epoch/token to match the live
  lease and rejects symlink, sibling, and wrong-repository paths.

- [ ] **Step 5: Implement effects, authorization, protected execution, and role launch**

  Put shared canonical-state, lease, grant, and audit helpers under `scripts/lib/`;
  do not duplicate security-critical parsing. Implement each tagged action as a
  separate schema/normalizer/postcondition object. `inspect-effects` obtains
  authoritative effect data; `authorize-action` issues but never executes a
  grant; the protected `execute-action` service consumes it and runs only fixed
  argv-form Git/GitHub/Orca/fake operations; `launch-role` enforces the proven
  adapter profile. Fail closed on missing isolation, target, required check,
  scan, credential, postcondition, or fresh effect evidence.

- [ ] **Step 6: Run focused and full fast tests**

  ```bash
  rtk chmod +x skills/general/milestone-orchestrator/scripts/control-state skills/general/milestone-orchestrator/scripts/authorize-action skills/general/milestone-orchestrator/scripts/execute-action skills/general/milestone-orchestrator/scripts/launch-role skills/general/milestone-orchestrator/scripts/inspect-effects
  rtk ruby test/milestone_orchestrator_control_state_test.rb
  rtk ruby test/milestone_orchestrator_role_isolation_test.rb
  rtk ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |path| require File.expand_path(path) }'
  ```

- [ ] **Step 7: Commit Task 3A**

  ```bash
  rtk git add test/milestone_orchestrator_control_state_test.rb test/milestone_orchestrator_role_isolation_test.rb skills/general/milestone-orchestrator/scripts/control-state skills/general/milestone-orchestrator/scripts/authorize-action skills/general/milestone-orchestrator/scripts/execute-action skills/general/milestone-orchestrator/scripts/launch-role skills/general/milestone-orchestrator/scripts/inspect-effects skills/general/milestone-orchestrator/scripts/lib skills/general/milestone-orchestrator/references/state-schema.md
  rtk git diff --cached --check
  rtk git commit -m "Add fenced milestone control plane"
  ```

## Task 3B: Implement Independent Verification And Outgoing Secret Scanning

**Files:**
- Create: `test/milestone_orchestrator_verification_test.rb`
- Create: `skills/general/milestone-orchestrator/scripts/run-verification`
- Create: `skills/general/milestone-orchestrator/scripts/scan-outgoing`
- Create: `skills/general/milestone-orchestrator/scripts/lib/audit_log.rb`
- Modify: `skills/general/milestone-orchestrator/references/state-schema.md`

- [ ] **Step 1: Write RED independent-verifier tests**

  Required CLI:

  ```text
  run-verification --repo DIR --state STATE --plan PLAN --owner OWNER --token N --expected-subject OID --command-id ID --executor-id ID --json
  ```

  Tests require a clean worktree, declared Git object format, exact current
  implementation subject, a verifier identity different from every implementer
  attempt, exact PLAN digest, command lookup through the canonical registry,
  exact argv/cwd/clean-environment/timeout execution, captured stdout/stderr
  digests, exit status, environment fingerprint, start/end timestamps, and an
  append-only evidence record. Reject dirty trees, stale subjects, unknown
  command IDs, PLAN digest drift, shell strings, missing allowlists,
  implementer/verifier identity overlap, stale tokens, and ledger overwrite.

- [ ] **Step 2: Write RED outgoing-scan tests**

  Required CLI:

  ```text
  scan-outgoing --repo DIR --state STATE --owner OWNER --token N --remote REMOTE --remote-ref-expectation-json JSON --head OID --artifacts-json JSON --captures-dir DIR --json
  scan-outgoing inspect --repo DIR --remote REMOTE --remote-ref-expectation-json JSON --head OID --artifacts-json JSON --captures-dir DIR --output FILE --json
  ```

  Build fixture commits containing a secret in the final tree, a secret added
  then deleted, secret-like commit metadata, a Git LFS pointer plus local LFS
  object, a generated artifact, an authenticated capture, and an explicit
  allowlisted false positive. Tests assert exact outgoing-range, object-format,
  blob, metadata, LFS, artifact, control-document, capture-retention/deletion,
  exclusion, source/head, scanner-version, and result evidence. Test both tagged
  remote expectations: `absent` proves the full ref is missing and scans
  `base_oid..head`; `present` requires the exact current OID and scans
  `oid..head`. Missing LFS content, an empty/ambiguous range, or uninspectable
  required data fails closed.
  The `inspect` form is read-only and emits a standalone signed/digested report
  for a separately authorized publication workflow; it cannot create a grant or
  mutate STATE, the evidence ledger, Git, or the forge.

- [ ] **Step 2A: Write RED external-ledger and finite-anchor tests**

  The authoritative evidence stream lives outside every worktree at:

  ```text
  <git-common-dir>/milestone-orchestrator/<run-id>/evidence.jsonl
  ```

  Every verification, scan, effect snapshot, grant, action, CI observation,
  cleanup result, and terminal closeout record includes a monotonic sequence,
  previous-record digest, record digest, run/epoch/token, actor, exact subject,
  and timestamp. Test truncation, reordering, replay, cross-run injection,
  malformed tails, and concurrent append. No worker can write this ledger.

  Prove a finite publication protocol: after implementation and local review,
  the control writer snapshots the ledger's current sequence/digest into
  `STATE.md` and makes exactly one pre-publication control-anchor commit. The
  outgoing scan binds that anchor head and scans the exact remote range; push
  publishes it. Post-push action/CI/final-review/cleanup/closeout records append
  only to the external ledger and PR/handoff surfaces and never cause another
  branch commit. A new implementation/remediation commit starts a new finite
  anchor cycle; it does not continually commit audit results about its own push.
  Tests reject publication without an anchored prefix and reject a branch STATE
  that claims terminal external evidence it could only learn after publication.

- [ ] **Step 3: Run tests and observe RED**

  ```bash
  rtk ruby test/milestone_orchestrator_verification_test.rb
  ```

- [ ] **Step 4: Implement both executables**

  Use Ruby 2.6 and argv-form Git subprocesses. `run-verification` resolves only a
  canonical PLAN command ID and appends evidence to the protected external
  ledger. `scan-outgoing` enumerates objects with Git plumbing, scans commit
  metadata and blob bytes with bounded-size rules, resolves referenced local LFS
  content, inspects declared artifacts, and proves authenticated capture deletion
  or approved retention. Implement the digest-chained ledger and finite
  control-anchor protocol in `scripts/lib/audit_log.rb`. Record an immutable scan
  ID consumed by `authorize-action`; commit and push grants are impossible
  without a fresh pass for the exact tagged remote expectation, anchored head,
  and implementation subject.

- [ ] **Step 5: Run focused and fast suites**

  ```bash
  rtk chmod +x skills/general/milestone-orchestrator/scripts/run-verification skills/general/milestone-orchestrator/scripts/scan-outgoing
  rtk ruby test/milestone_orchestrator_verification_test.rb
  rtk ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |path| require File.expand_path(path) }'
  ```

- [ ] **Step 6: Commit Task 3B**

  ```bash
  rtk git add test/milestone_orchestrator_verification_test.rb skills/general/milestone-orchestrator/scripts/run-verification skills/general/milestone-orchestrator/scripts/scan-outgoing skills/general/milestone-orchestrator/scripts/lib/audit_log.rb skills/general/milestone-orchestrator/references/state-schema.md
  rtk git diff --cached --check
  rtk git commit -m "Add milestone verification gates"
  ```

## Task 4: Add PREPARE Artifacts And Task Contracts

**Files:**
- Create: `skills/general/milestone-orchestrator/references/intake.md`
- Create: `skills/general/milestone-orchestrator/references/task-contracts.md`
- Create: `skills/general/milestone-orchestrator/assets/spec-template.md`
- Create: `skills/general/milestone-orchestrator/assets/plan-template.md`
- Modify: `test/milestone_orchestrator_skill_contract_test.rb`

- [ ] **Step 1: Add RED contract assertions for PREPARE**

  Assert the package contains the four files and that:

  - Intake requires repo grounding before questions, consolidated packets with
    recommendation/default/alternatives, no arbitrary follow-up limit, and one
    final approval after both reviewed artifacts.
  - Intake separates mandatory local checkpoint authority from implementation
    commit, push, draft PR, PR-ready, reviewer assignment, merge, and deploy.
  - Intake inventories action-and-target-scoped derived automation, snapshots
    required CI checks, and classifies dirty paths.
  - Task contracts distinguish `plan_task_id`, `orca_task_id`, `dispatch_id`,
    attempt number, requested base, and observed head.
  - Plan template contains stable requirement IDs, dependencies, ownership,
    routing, verification, integration, cleanup, budgets, and immutable
    requirement-to-task acceptance mapping.
  - Plan template copies the canonical PLAN marker and JSON registry from this
    reviewed plan exactly, including argv/cwd/env/timeout/mutation fields and
    command-ID-to-acceptance mappings accepted by the Task 2 parser.
  - Spec template contains goals, non-goals, architecture, invariants, negative
    behavior, failure handling, external effects, authority, escalation, and
    acceptance criteria.

- [ ] **Step 2: Run the contract test and observe RED**

  ```bash
  rtk ruby test/milestone_orchestrator_skill_contract_test.rb
  ```

  Expected: failures for the missing files and clauses.

- [ ] **Step 3: Write `intake.md`**

  Include executable checklists for repository grounding, decision inventory,
  question packet format, spec/plan adversarial review tier selection, final
  approval language, artifact hashing, checkpoint, capability/version probes,
  publication envelope, typed action/target schemas, authoritative effect
  snapshot requirements, tagged remote-ref expectation, required-check snapshot,
  budgets, dirty-state classification, and no-commit restricted mode.

  Provide this exact approval summary table:

  ```markdown
  | Action | Default | Approved value |
  |---|---:|---:|
  | Contract checkpoint commit | required for isolated RUN | |
  | Implementation commits | enabled | |
  | Push | enabled | |
  | Draft PR create/update | enabled | |
  | Mark PR ready | disabled unless granted | |
  | Assign/request reviewers | disabled unless granted | |
  | Merge | always disabled | false |
  | Deploy | always disabled | false |
  ```

- [ ] **Step 4: Write `task-contracts.md`**

  Define complete YAML examples for implementation, review, verification,
  remediation, integration, cleanup, and control tasks. Every dispatch packet
  must contain run/epoch/token, stable and host IDs, role/model/launcher,
  dependencies, owned/forbidden paths, base/head, acceptance rows, exact checks,
  required skills, handoff evidence, remediation owner, and cleanup policy.

  Define that worker lifecycle messages are signals only; coordinator acceptance
  gates release semantic dependencies. Integration workers return immutable
  evidence and never edit STATE. The coordinator never resolves conflicts.
  Define a fenced plan-only replan record with old/new artifact and acceptance
  mapping digests, adversarial-review evidence, spec-plan drift result, budget
  consumption, task supersession/carry-forward, and approval provenance. Any
  SPEC or authority change requires user reapproval.

- [ ] **Step 5: Write the SPEC and PLAN assets**

  Templates must be copyable without changing skill files. Use instructional
  angle-bracket tokens and a `Template completion gate` section that forbids
  unresolved tokens before final approval. `PLAN.md` must include checkbox task
  tracking, task DAG table, ownership matrix, routing table, budgets, acceptance
  mapping, review points, integration order, cleanup plan, and closeout gate. It
  must also include the exact canonical PLAN JSON marker/registry contract
  defined before Task 0; do not translate it to a prose-only or YAML variant.

- [ ] **Step 6: Run the contract test and observe GREEN**

  ```bash
  rtk ruby test/milestone_orchestrator_skill_contract_test.rb
  ```

- [ ] **Step 7: Commit Task 4**

  ```bash
  rtk git add test/milestone_orchestrator_skill_contract_test.rb skills/general/milestone-orchestrator/references/intake.md skills/general/milestone-orchestrator/references/task-contracts.md skills/general/milestone-orchestrator/assets/spec-template.md skills/general/milestone-orchestrator/assets/plan-template.md
  rtk git diff --cached --check
  rtk git commit -m "Add milestone preparation contracts"
  ```

## Task 5: Implement Orca-First And Native Platform Adapters

**Files:**
- Create: `skills/general/milestone-orchestrator/references/platform-adapters.md`
- Modify: `skills/general/milestone-orchestrator/SKILL.md`
- Modify: `test/milestone_orchestrator_skill_contract_test.rb`

- [ ] **Step 1: Add RED adapter contract tests**

  Assert the adapter reference contains:

  - A capability table for Orca, native Codex, and native Claude.
  - Exact Orca probes: `orca status --json`, `orca orchestration task-list`,
    terminal/worktree/tab listings, and review/agent launcher probes.
  - Real `taskId` + `dispatchId` provenance and source-pane validation.
  - Manual Orca dispatch loop as the safe default; `run-stop` only after proven
    runtime exclusivity.
  - Immutable Git base creation/verification separate from Orca sidebar lineage.
  - Model route-to-launch mapping with observed runtime identity and fail-closed
    protected roles.
  - Browser page-ID scoping and direct `tab close --page`; only capability-probed
    older hosts may fall back to page-ID-to-current-index reconciliation.
  - Codex final review uses this repo's `code-review`; Claude uses Claude's own
    `/code-review` and never substitutes the Codex skill.
  - Native resource allowlisting, bounded cancellation, cleanup, retention,
    restart reconciliation, and foreign-resource protection.
  - Read-only coordinator, fenced control writer, independent verifier, and
    constrained external-action executor for every adapter, or a block.
  - `launch-role` maps every host role to a proved OS-enforced profile; ordinary
    workers cannot reach the protected control root, executor service,
    credentials, process state, ambient sockets, or direct publication paths.
  - `inspect-effects` maps each typed action to authoritative repository/forge/
    Orca inspection and blocks when any effect source is opaque or stale.

- [ ] **Step 2: Run the contract test and observe RED**

  ```bash
  rtk ruby test/milestone_orchestrator_skill_contract_test.rb
  ```

- [ ] **Step 3: Write the Orca reference adapter**

  Document concrete command families without inventing unsupported flags:

  ```bash
  orca status --json
  orca orchestration task-create --spec "<task contract>" --json
  orca orchestration dispatch --task <task_id> --to <terminal_handle> --inject --json
  orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 900000 --json
  orca orchestration task-list --json
  orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json
  orca tab list --json
  orca tab close --page <browser_page_id> --worktree id:<full_worktree_id> --json
  ```

  Before implementation, re-read the current installed Orca skill and copy only
  currently documented exact syntax. Put volatile command details in this
  adapter reference, not in `SKILL.md`.

  Define:

  - One run root and exact allowlist; no global reset.
  - One fresh Orca task/dispatch after terminal worker completion.
  - Separate acceptance gates for semantic readiness.
  - Agent-first versus custom-argv model launch and extra-terminal ownership.
  - Worktree creation from immutable wave refs plus observed HEAD check.
  - Rolling wait/liveness behavior.
  - Resource before/after inventories and safe cleanup.
  - Chrome DevTools versus Orca embedded-browser selection.

- [ ] **Step 4: Write native Codex and Claude adapters**

  Codex:

  - Sol-class root manager, depth one, read-only coordinator sandbox, isolated
    worker worktrees, repository ledger as durable truth. Use `/goal` only when
    the capability matrix proves it; otherwise use a tested explicit coordinator
    loop over STATE and native subagent/process primitives or mark the adapter
    blocked.
  - Probe active model/effort and subagent/worktree support.
  - Invoke this repository's `code-review` for final review.

  Claude:

  - Fable-class root manager, ordinary custom subagents with worktrees,
    permissions/hooks for manager boundary, repo ledger as durable truth. Use
    `/goal` only when proved; otherwise use a tested explicit coordinator loop or
    mark the adapter blocked.
  - Probe host and `/code-review` version/compatibility.
  - UI implementation defaults to Claude workers; never invoke the Codex
    `code-review` as Claude's final-review substitute.

  Both native adapters must define stable resource identity, cancellation,
  partial-work preservation, cleanup/retention, epoch recovery, capability
  isolation, and a block when mandatory review or manager enforcement is absent.

- [ ] **Step 5: Run contract and root tests**

  ```bash
  rtk ruby test/milestone_orchestrator_skill_contract_test.rb
  rtk ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |path| require File.expand_path(path) }'
  ```

- [ ] **Step 6: Commit Task 5**

  ```bash
  rtk git add test/milestone_orchestrator_skill_contract_test.rb skills/general/milestone-orchestrator/SKILL.md skills/general/milestone-orchestrator/references/platform-adapters.md
  rtk git diff --cached --check
  rtk git commit -m "Add milestone runtime adapters"
  ```

## Task 6: Build The Disposable Repository And Publication Fixture

**Files:**
- Create: `test/milestone_orchestrator_fixture_test.rb`
- Create: `test/milestone_orchestrator_fault_matrix_test.rb`
- Create: `test/support/milestone_orchestrator_fake_adapter.rb`
- Use: `test/milestone_orchestrator_pressure_test.rb`
- Create: `skills/general/milestone-orchestrator/scripts/create-fixture-repo`
- Use: `skills/general/milestone-orchestrator/scripts/run-pressure-suite`
- Create: `skills/general/milestone-orchestrator/references/validation.md`
- Use unchanged: `test/fixtures/milestone-orchestrator/pressure-protocol.json`
- Use unchanged: `test/fixtures/milestone-orchestrator/pressure-prompts/*.md`
- Create: `test/fixtures/milestone-orchestrator/fault-matrix.json`

- [ ] **Step 1: Write fixture-generator RED tests**

  Invoke the generator with `--output DIR --seed 1 --json`. Assert:

  - It requires a nonexistent output path and refuses every existing path.
  - It creates `repo/` and `remote.git/`, configures only fixture-local Git
    author values, creates `main`, and pushes only to the local bare remote.
    Every Git subprocess uses sanitized `HOME`, `XDG_CONFIG_HOME`,
    `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, disabled signing and
    hooks, fixed author/committer dates, and an explicitly recorded object format.
  - It creates independent `ui/`, `backend/`, and `test/` slices plus a shared
    file that deliberately forces serialization.
  - It creates a seeded defect, a failing gate script, a harmless browser page,
    fake-forge state, empty action ledger, and synthetic foreign-resource
    sentinels.
  - JSON output contains absolute paths and the initial commit SHA.
  - No configured remote URL starts with `http`, `ssh`, `git@`, or points outside
    the fixture root.
  - It never accepts `--force`, deletes, empties, or reuses a caller-provided
    directory.

- [ ] **Step 2: Run the fixture test and observe RED**

  ```bash
  rtk ruby test/milestone_orchestrator_fixture_test.rb
  ```

  Expected: ERROR because the generator does not exist.

- [ ] **Step 3: Implement `create-fixture-repo`**

  Use `OptionParser`, `FileUtils`, `Open3.capture3`, `JSON`, and `Pathname`. Never
  interpolate a full shell command string; pass argv arrays to `Open3.capture3`.
  Required CLI:

  ```text
  create-fixture-repo --output DIR [--seed INTEGER] [--json]
  ```

  Create `.milestone-orchestrator-fixture` before any generated content. Use the
  seed, sanitized Git environment, explicit SHA-1 fixture object format, and
  fixed fixture-local Git timestamps when reproducible object IDs are required.
  Production STATE validation remains algorithm-aware for SHA-1 and SHA-256. The
  fake forge is repository-local JSON:

  ```json
  {
    "repository": "fixture/local",
    "pull_requests": [],
    "automation": {
      "push": ["fixture-ci"],
      "draft_pr": [],
      "ready": ["notify-reviewers"]
    }
  }
  ```

  `forge-actions.jsonl` begins empty and is the only allowed publication ledger
  for deterministic tests. The fixture must never call `gh`, a network client,
  or a non-local remote.

- [ ] **Step 4: Implement the deterministic fake lifecycle adapter**

  Build `MilestoneOrchestratorFakeAdapter` before the fault test. It provides a
  virtual monotonic/RFC3339 clock, task and dispatch stores, typed threaded
  messages, terminal/worktree/browser resource inventories, worker lifecycle,
  cancellation races, lease/epoch events, fake forge/effect inspection, CI
  observations, and a complete mutation ledger. Every create/dispatch/wait/
  complete/cancel/cleanup/publication method accepts fault-injection hooks and
  returns the same stable identities expected from real adapters. It must reject
  unknown operations, never call the network or Orca, and expose deterministic
  before/after snapshots so forbidden extra effects are detectable.

- [ ] **Step 5: Implement the executable fault matrix**

  Write `fault-matrix.json` with one stable case ID per design fault. Each row
  contains setup fixture, injected event, allowed actions, forbidden actions,
  expected STATE delta, retry/replan/escalation disposition, and resource result.
  `milestone_orchestrator_fault_matrix_test.rb` iterates every row against the
  fake adapter, control-state, authorizer/executor, verifier, and fixture. It
  fails when a row is undocumented, unexecuted, or emits an extra external
  action. Run it in the ordinary fast suite.

- [ ] **Step 6: Verify the frozen pressure corpus remains unchanged**

  Recompute the committed protocol and prompt hashes. Any corpus, repetition,
  metric, threshold, exclusion, or zero-tolerance change after baseline requires
  a new protocol version and a new baseline; it cannot be folded into this run.
  Actual post-skill trials and scoring run in Task 9.

- [ ] **Step 7: Write `validation.md`**

  Define five layers:

  1. Frozen baseline pressure protocol with pre-registered corpus hashes,
     repetitions, models/config, metrics, minimum effect/confidence, exclusions.
  2. Zero-tolerance rules: coordinator implementation write, unauthorized
     publication, merge/deploy, foreign-resource mutation, acceptance bypass.
  3. Static validator and fake-adapter fixture suite.
  4. Actual Orca, native Codex, and native Claude conformance with capability
     bypass and fault injection.
  5. One bounded real-repository pilot after all prior gates pass.

  The executable fault matrix must list setup, fault, allowed action, forbidden action,
  expected STATE transition, and retained-resource outcome for: timeout with
  heartbeat, silent live worker, terminal exit, stale/malformed/wrong-pane
  completion, retry counts one/three, dirty state, integration conflict, runtime
  generation change, configured resources, ambiguous cleanup, CI timeout,
  cancellation, revocation, stale epoch, and direct publication bypass.

- [ ] **Step 8: Run fixture, fault, pressure, and full tests**

  ```bash
  rtk chmod +x skills/general/milestone-orchestrator/scripts/create-fixture-repo
  rtk ruby test/milestone_orchestrator_fixture_test.rb
  rtk ruby test/milestone_orchestrator_fault_matrix_test.rb
  rtk ruby test/milestone_orchestrator_pressure_test.rb
  rtk ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |path| require File.expand_path(path) }'
  ```

- [ ] **Step 9: Commit Task 6**

  ```bash
  rtk git add test/milestone_orchestrator_fixture_test.rb test/milestone_orchestrator_fault_matrix_test.rb test/support/milestone_orchestrator_fake_adapter.rb test/fixtures/milestone-orchestrator/fault-matrix.json skills/general/milestone-orchestrator/scripts/create-fixture-repo skills/general/milestone-orchestrator/references/validation.md
  rtk git diff --cached --check
  rtk git commit -m "Add milestone orchestration fixture"
  ```

## Task 7: Complete Package Contracts And Register The Skill

**Files:**
- Modify: `test/milestone_orchestrator_skill_contract_test.rb`
- Modify: `skills.yaml`
- Modify: `CATALOG.md`
- Modify: `USAGE.md`

- [ ] **Step 1: Add final RED package/metadata tests**

  Extend the contract test to assert the exact file set, executable bits and
  direct `--help`/invalid-CLI behavior for every planned executable
  (`validate-state`, `control-state`, `authorize-action`, `execute-action`,
  `launch-role`, `inspect-effects`, `run-verification`, `scan-outgoing`,
  `run-pressure-suite`, and `create-fixture-repo`), absence of root-level support Markdown next to
  `SKILL.md`, valid
  frontmatter, all reference links, and these safety clauses:

  - `worker_done` is attempt completion only.
  - All semantic dependencies use coordinator acceptance gates.
  - No global Orca reset.
  - `run-stop` requires proven runtime exclusivity.
  - Every external mutation checks current epoch/token/authority.
  - Ordinary workers lack publication/merge/deploy/cross-run cleanup capability.
  - Outgoing-object-range secret scanning is fail closed.
  - No-commit mode is serialized and disables push/PR.
  - Final review is Codex `code-review` or Claude `/code-review` by host.
  - Orca resources are cleaned by stable identity or explicitly retained.

  Parse `skills.yaml` and assert a `milestone-orchestrator` entry exactly matches
  the catalog policy.

- [ ] **Step 2: Run the contract test and observe RED**

  ```bash
  rtk ruby test/milestone_orchestrator_skill_contract_test.rb
  ```

  Expected: new exhaustive package/usage assertions fail while the Task 1
  registration assertions remain green.

- [ ] **Step 3: Verify the existing `skills.yaml` entry**

  Add:

  ```yaml
  - name: milestone-orchestrator
    path: skills/general/milestone-orchestrator
    category: general
    status: active
    interfaces:
      - claude
      - codex
    recommended_model_tier: deep
    heavy_model_tier: ultracode
    install:
      codex:
        enabled: false
        mode: symlink
      claude:
        enabled: false
        mode: symlink
      cursor:
        enabled: false
        mode: symlink
      gemini:
        enabled: false
        mode: symlink
    description: Orca-first milestone workflow that front-loads reviewed specifications and plans, then coordinates mixed-model workers through implementation, remediation, verification, draft PR publication, host-correct final review, and safe cleanup while stopping before merge or deploy.
    notes: General because the shared policy supports Orca-hosted Codex and Claude plus native Codex/Claude fallbacks. Install targets remain disabled until the user explicitly requests global symlink changes; RUN keeps the coordinator out of implementation and uses repository-local SPEC, PLAN, and STATE artifacts.
  ```

- [ ] **Step 4: Verify the matching `CATALOG.md` row**

  Use:

  ```markdown
  | `milestone-orchestrator` | `skills/general/milestone-orchestrator/` | `general` | Active | Install disabled pending explicit user request | `deep`; heavy mode `ultracode` for Claude-only UltraCode runs | Orca-first milestone workflow that front-loads reviewed specifications and plans, then coordinates mixed-model workers through implementation, remediation, verification, draft PR publication, host-correct final review, and safe cleanup while stopping before merge or deploy. |
  ```

- [ ] **Step 5: Update `USAGE.md`**

  Add one concise section covering natural invocation, explicit PREPARE/RUN/STATUS
  phases, artifact paths, automatic commit/push/draft-PR default, distinct
  PR-ready/reviewer authority, host-correct review, no merge/deploy, and the fact
  that repository registration does not install the skill globally.

- [ ] **Step 6: Run targeted tests and validate YAML**

  ```bash
  rtk ruby test/milestone_orchestrator_skill_contract_test.rb
  rtk ruby -e 'require "yaml"; YAML.safe_load_file("skills.yaml", aliases: false); puts "skills.yaml ok"'
  ```

  If the system Ruby lacks `YAML.safe_load_file`, use:

  ```bash
  rtk ruby -e 'require "yaml"; YAML.safe_load(File.read("skills.yaml"), permitted_classes: [], aliases: false); puts "skills.yaml ok"'
  ```

- [ ] **Step 7: Commit Task 7**

  ```bash
  rtk git add test/milestone_orchestrator_skill_contract_test.rb skills.yaml CATALOG.md USAGE.md
  rtk git diff --cached --check
  rtk git commit -m "Register milestone orchestrator skill"
  ```

## Task 8: Run Static, Fixture, Sync, And Skill Validation

**Files:**
- Verify: `skills/general/milestone-orchestrator/**`
- Verify: `test/milestone_orchestrator_*_test.rb`
- Verify: `skills.yaml`
- Verify: `CATALOG.md`
- Verify: `scripts/sync-skills`

- [ ] **Step 1: Run all Ruby tests**

  ```bash
  rtk ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |path| require File.expand_path(path) }'
  ```

  Expected: zero failures and zero errors.

- [ ] **Step 2: Run the skill validator**

  ```bash
  rtk uv run --with pyyaml python /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/general/milestone-orchestrator
  ```

  Expected: validation passes. If that installed path has changed, locate the
  current `skill-creator` validator from the active skill before substituting a
  command; record the exact path used. Do not assume bare system Python has
  PyYAML.

- [ ] **Step 3: Exercise the STATE CLI directly**

  Copy the state asset to a temporary file, replace instructional tokens with a
  valid fixture state in the test helper, and run:

  ```bash
  rtk skills/general/milestone-orchestrator/scripts/validate-state check --state /tmp/milestone-orchestrator-valid-state.md --spec /tmp/milestone-orchestrator-SPEC.md --plan /tmp/milestone-orchestrator-PLAN.md --json
  ```

  Expected: JSON with `"valid": true` and exit 0.

- [ ] **Step 4: Exercise the fixture generator directly**

  ```bash
  rtk skills/general/milestone-orchestrator/scripts/create-fixture-repo --output "$(mktemp -d)/fixture" --seed 1 --json
  ```

  Expected: capture the exact caller-supplied output realpath and assert every
  returned path is its descendant and contains the fixture marker, plus a local
  initial commit. Remove the disposable parent after inspection.

- [ ] **Step 5: Run install dry-runs for every affected target**

  ```bash
  rtk scripts/sync-skills --target codex --dry-run
  rtk scripts/sync-skills --target claude --dry-run
  ```

  Expected: existing enabled skills remain stable and `milestone-orchestrator`
  is not selected because its install flags are intentionally disabled. Do not
  run `--apply`.

- [ ] **Step 6: Run whitespace, placeholder, and structure checks**

  ```bash
  rtk git diff --check
  rtk rg -n 'TBD|TODO|PLACEHOLDER|as appropriate|should probably|maybe' skills/general/milestone-orchestrator test/milestone_orchestrator_*_test.rb
  rtk find skills/general/milestone-orchestrator -type f -maxdepth 3 -print
  ```

  Expected: no unresolved placeholder or vague-instruction matches. Template
  instructional tokens are angle-bracketed and must not use these words.

- [ ] **Step 7: Record verification evidence in the implementation handoff**

  Record each exact command, exit status, test count, skill-validator path, sync
  dry-run outcome, and any environment-limited actual-host test that remains for
  the bounded pilot.

## Task 9: Dogfood The Skill Against Its Disposable Fixture

**Files:**
- Use: `skills/general/milestone-orchestrator/**`
- Use: generated disposable fixture only
- Create: `test/integration/milestone_orchestrator_orca_e2e_test.rb`
- Create: `test/integration/milestone_orchestrator_native_conformance_test.rb`
- Modify only if a verified defect is found: skill package/tests

- [ ] **Step 1: Add explicitly gated integration harnesses**

  Both files use Minitest but skip unless
  `RUN_MILESTONE_ORCHESTRATOR_INTEGRATION=1`. They must also require a freshly
  generated fixture path through `MILESTONE_ORCHESTRATOR_FIXTURE`; never create
  resources in the skills repository. A missing variable skips rather than
  guessing a target.

  ```ruby
  def require_integration!
    skip "set RUN_MILESTONE_ORCHESTRATOR_INTEGRATION=1" unless
      ENV["RUN_MILESTONE_ORCHESTRATOR_INTEGRATION"] == "1"
    fixture = ENV["MILESTONE_ORCHESTRATOR_FIXTURE"]
    flunk "set MILESTONE_ORCHESTRATOR_FIXTURE" if fixture.nil? || fixture.empty?
    run_id = ENV["MILESTONE_ORCHESTRATOR_RUN_ID"]
    flunk "set MILESTONE_ORCHESTRATOR_RUN_ID" if run_id.nil? || run_id.empty?
    validate_fresh_fixture!(fixture, run_id)
  end
  ```

  `validate_fresh_fixture!` performs all checks before the first host mutation:
  resolve realpaths and require every manifest path beneath the fixture root;
  verify `.milestone-orchestrator-fixture`, manifest schema/version/seed and
  generator timestamp, expected initial commit and clean repository, local bare
  remote identity, absence of every network-style remote, fake-forge schema and
  empty action ledger, foreign sentinels, and a freshness limit. It requires a
  safe run-ID pattern, proves `<git-common-dir>/milestone-orchestrator/<run-id>`
  and all host resource prefixes are unused, then atomically reserves that run
  namespace. Any missing, reused, stale, malformed, or externally addressed
  fixture calls `flunk`; enabled integration never skips an unsafe case.

  Every claimed adapter runs the same conformance matrix: implementation,
  remediation, integration, independent verifier, protected executor/worker
  isolation, direct file/socket/process/credential/publication bypass attempts,
  publication postconditions and idempotency, restart reconciliation, stale
  epoch, cancellation races, ambiguous cleanup, foreign-resource preservation,
  final-review routing, and retained-resource reporting. Host-specific tests may
  add assertions but may not omit a shared row. Tests fail before mutation if
  capability probes or fake publication isolation are missing.

- [ ] **Step 2: Confirm ordinary tests do not run integrations**

  ```bash
  rtk ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |path| require File.expand_path(path) }'
  ```

  Expected: integration files are not loaded.

- [ ] **Step 3: Run the frozen post-skill pressure suite and score it**

  Use the unchanged Task 0B protocol, corpus, launchers, and repetition count.
  Run with the exact built skill package, persist sanitized post-skill provenance
  and raw-result digest, then score against the recorded baseline. Zero-tolerance
  failure or a missed minimum effect blocks completion.

  ```bash
  rtk skills/general/milestone-orchestrator/scripts/run-pressure-suite --mode with-skill --protocol test/fixtures/milestone-orchestrator/pressure-protocol.json --results <post-skill-results-dir> --launcher-json '<capability-matrix-launcher-json>' --json
  rtk skills/general/milestone-orchestrator/scripts/run-pressure-suite score --protocol test/fixtures/milestone-orchestrator/pressure-protocol.json --baseline <baseline-results-dir> --with-skill <post-skill-results-dir> --output docs/plans/2026-07-13-milestone-orchestrator-pressure-results.json --json
  ```

- [ ] **Step 4: Freeze the dogfood protocol before the run**

  Copy the protocol from `references/validation.md` into a temporary run packet.
  Record package commit, Orca version/status, selected manager/worker models,
  repetition count, exact assertions, and zero-tolerance rules before observing
  results.

- [ ] **Step 5: Run one fake-adapter lifecycle**

  Exercise PREPARE artifacts, STATE validation, independent/overlapping task
  readiness, review defect, remediation, verification, integration, fake push,
  draft PR ledger action, final review record, cleanup, and merge/deploy stop.
  Assert the action ledger contains no `merge` or `deploy` event.

- [ ] **Step 6: Run the actual Orca conformance harness**

  Use only the disposable fixture. Execute every shared conformance-matrix row,
  including implementation/remediation/integration roles, verifier/executor
  isolation and direct bypass probes, fake publication postconditions, restart
  recovery, cancellation races, ambiguous cleanup, and foreign-resource
  preservation. Create run-owned tasks/worktrees/terminals and a harmless
  browser tab; do not use global reset. Confirm all run-owned resources are
  removed or deliberately retained and every foreign sentinel is unchanged.

  Generate a new fixture and run the exact enabled command:

  ```bash
  rtk env RUN_MILESTONE_ORCHESTRATOR_INTEGRATION=1 MILESTONE_ORCHESTRATOR_FIXTURE=<fixture-path> MILESTONE_ORCHESTRATOR_RUN_ID=<fresh-run-id> ruby test/integration/milestone_orchestrator_orca_e2e_test.rb
  ```

  Expected: nonzero assertions, zero failures, zero errors, zero skips. If no
  compatible Orca runtime is available, Orca remains explicitly unproven and the
  skill cannot be described or registered as Orca-supported until this passes.

- [ ] **Step 7: Run native adapter conformance harnesses**

  Generate a separate fresh fixture for each native host, then in its disposable
  worktrees run the same complete shared matrix used for Orca.
  Additionally verify native Codex selects this repository's `code-review` and
  native Claude selects Claude's `/code-review`. Run separately with fresh,
  previously unused run IDs:

  ```bash
  rtk env RUN_MILESTONE_ORCHESTRATOR_INTEGRATION=1 MILESTONE_ORCHESTRATOR_FIXTURE=<fixture-path> MILESTONE_ORCHESTRATOR_RUN_ID=<fresh-codex-run-id> MILESTONE_ORCHESTRATOR_NATIVE_HOST=codex ruby test/integration/milestone_orchestrator_native_conformance_test.rb
  rtk env RUN_MILESTONE_ORCHESTRATOR_INTEGRATION=1 MILESTONE_ORCHESTRATOR_FIXTURE=<fixture-path> MILESTONE_ORCHESTRATOR_RUN_ID=<fresh-claude-run-id> MILESTONE_ORCHESTRATOR_NATIVE_HOST=claude ruby test/integration/milestone_orchestrator_native_conformance_test.rb
  ```

  Each claimed adapter requires nonzero assertions and zero skips. A missing host
  blocks that support claim; it does not turn a skipped run into a pass.

- [ ] **Step 8: Fix only verified defects using RED/GREEN tests**

  For each defect, first add a focused failing root test, implement the minimum
  package correction, rerun the focused test, then rerun all tests. Commit each
  coherent remediation separately.

- [ ] **Step 9: Commit integration harnesses and durable results**

  ```bash
  rtk git add test/integration/milestone_orchestrator_orca_e2e_test.rb test/integration/milestone_orchestrator_native_conformance_test.rb skills/general/milestone-orchestrator/references/validation.md docs/plans/2026-07-13-milestone-orchestrator-pressure-results.json
  rtk git diff --cached --check
  rtk git commit -m "Add milestone host conformance harnesses"
  ```

## Task 10: Final Code Review, Publication, And Stop

**Files:**
- Review: all changes against the reviewed design and plan
- Modify only through verified remediation tasks

- [ ] **Step 1: Run the full local gate from a clean implementation subject**

  ```bash
  rtk ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |path| require File.expand_path(path) }'
  rtk ruby -e 'require "yaml"; YAML.safe_load(File.read("skills.yaml"), permitted_classes: [], aliases: false); puts "skills.yaml ok"'
  rtk uv run --with pyyaml python /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/general/milestone-orchestrator
  rtk scripts/sync-skills --target codex --dry-run
  rtk scripts/sync-skills --target claude --dry-run
  rtk git diff --check
  ```

- [ ] **Step 2: Scan and publish the stable integrated draft through the existing workflow**

  This skill implementation is not itself an initialized milestone-orchestrator
  run: it has no repository-specific approved `SPEC.md`, canonical `PLAN.md`,
  initialized `STATE.md`, lease, authority envelope, or protected executor
  service. Do not manufacture those artifacts after implementation or claim the
  new control plane authorizes its own publication. The new executor is
  dogfooded only against the disposable fixture in Task 9.

  For this branch, use the repository's separately authorized standard
  publication workflow established at execution kickoff. Run `scan-outgoing` in
  read-only/report mode against the exact tagged remote-ref expectation and
  branch head, inspect the proposed remote and draft-PR effects, fetch/recheck
  the full remote ref, then use a non-force explicit refspec and create/update a
  single draft PR idempotently. If separate push/draft-PR authority was not
  granted, stop with the verified local branch and report that blocker. Record
  the exact remote head and PR identity in the implementation handoff; do not
  write a fictitious orchestrator STATE record.

- [ ] **Step 3: Run mandatory host-correct final review against the published head**

  For Codex execution, invoke this repository's `code-review` skill against the
  full branch diff. For Claude execution, invoke Claude's own `/code-review`.
  Select intensity from final diff/risk; this architecture-shaping skill should
  normally receive a high pass. Verified findings become worker-owned
  remediation tasks followed by focused tests, the full gate, outgoing scan,
  standard-workflow push to the same draft PR under the same separate authority,
  and re-review of the new exact remote head.

- [ ] **Step 4: Commit and publish verified remediation without omitting artifacts**

  Stage only the complete verified planned file inventory, including changed
  design/plan/review/capability/pressure artifacts, package files, root tests,
  integration tests, fixtures, `skills.yaml`, `CATALOG.md`, and `USAGE.md`:

  ```bash
  rtk git add docs/plans/2026-07-13-milestone-orchestrator-* skills/general/milestone-orchestrator test/milestone_orchestrator_*_test.rb test/integration/milestone_orchestrator_*_test.rb test/fixtures/milestone-orchestrator skills.yaml CATALOG.md USAGE.md
  rtk git diff --cached --check
  rtk git commit -m "Finalize milestone orchestrator skill"
  ```

  Skip the commit when the index is empty. After any new commit, rerun the local
  gate, scan the new outgoing range, recheck effects and remote identity, and
  publish through the same separately authorized standard workflow.

- [ ] **Step 5: Reconcile required checks and CI for the exact final remote head**

  Compare the PREPARE-time required-check snapshot with the forge's current
  required checks and poll the exact published SHA using the recorded 30-minute
  and two-infrastructure-retry budgets. Pending, uncertain, changed, skipped, or
  failing required checks leave the PR draft and block closeout. Record check
  names, URLs, conclusions, attempts, and observed head in the implementation
  handoff rather than inventing an uninitialized run STATE.

- [ ] **Step 6: Confirm the final diff and author**

  ```bash
  rtk git status --short
  rtk git diff --stat origin/main...HEAD
  rtk git log --format='%h %an <%ae> %s' origin/main..HEAD
  ```

  Confirm only planned files changed and every commit uses the configured human
  author without AI trailers.

- [ ] **Step 7: Persist the final handoff and close resources through capability roles**

  The coordinator owns the final response and durable handoff summary. Because
  this implementation is outside a bootstrapped orchestrator run, close its
  implementation worktrees/tabs/terminals through the existing Orca workflow
  using stable recorded identities; do not route cleanup through fictional
  grants.
  Confirm implementation commits are reachable, preserve uncommitted evidence,
  close only stable-identity run resources, verify disappearance and unchanged
  foreign resources, and record retained resources.

  The handoff includes the draft PR URL, branch/base/final remote SHA, exact test,
  pressure, fault, conformance, scan, review, and CI evidence, supported versus
  unproven adapters, cleanup results, pilot qualification status, and explicit
  statements that merge, deploy, and `scripts/sync-skills --apply` were not run.
  Stop before those actions.

## Completion Criteria

The implementation is ready for user merge options only when:

1. The skill package passes quick validation and all Ruby tests.
2. SPEC/PLAN/STATE templates and references cover every reviewed design requirement.
3. STATE validation deterministically rejects lifecycle, authority, evidence,
   cleanup, and closeout violations.
4. The disposable fixture cannot target a production remote or arbitrary path.
5. Orca is the normative adapter and native Codex/Claude contracts retain the
   same manager, review, publication, cancellation, and cleanup boundaries; each
   adapter listed as supported has a non-skipped passing actual-host conformance
   result.
6. Catalog and manifest entries match and Codex/Claude sync dry-runs pass.
7. The frozen repeated pressure comparison meets its minimum effect and every
   zero-tolerance rule, and the executable fault matrix passes.
8. Independent verification and outgoing scan evidence match the exact final
   implementation subject and published remote head.
9. Final host-correct code review and required CI checks have no unresolved
   merge blocker at the exact final published SHA.
10. A draft PR is open or updated, while merge, deploy, and global `--apply`
   remain untouched.

This establishes the initial implementation, not proof for arbitrary large
milestones. That claim remains blocked until the separately selected bounded
real-repository pilot passes.
