# Milestone Orchestrator Skill — Design

**Date:** 2026-07-13  
**Status:** Reviewed and validated (`adversarial-review --high`)  
**Placement:** `skills/general/milestone-orchestrator/`  
**Primary runtime:** Orca orchestration  
**Supported fallbacks:** Native Codex and native Claude Code

## Purpose

Create a reusable skill for large repository milestones that separates an
interactive planning phase from an unattended multi-agent implementation run.
The user should make product and architectural decisions up front, approve the
resulting specification once, and then be interrupted only for a genuine loss
of authority or an unrecoverable contradiction.

The top-level agent is a manager. It plans, routes, supervises, reconciles,
reviews evidence, and closes the run. It does not implement production code,
tests, configuration, migrations, or implementation documentation during the
unattended run.

Orca is the normative implementation because it is the user's normal
development environment and provides task/dispatch identity, dependency state,
decision gates, worker completion messages, worktree routing, and inspectable
runtime coordination. Native Codex and Claude Code remain first-class fallback
paths that preserve the same policy and quality gates as closely as their
available primitives allow.

## Goals

1. Front-load material decisions into an approved design specification and
   implementation plan.
2. Continue through implementation, review, remediation, integration,
   verification, commit, push, and pull-request creation without routine user
   check-ins.
3. Keep the coordinator out of implementation work.
4. Use mixed Claude and GPT workers according to task shape, capability, cost,
   and risk.
5. Isolate independent writers in Orca worktrees and serialize overlapping
   work.
6. Maintain a repo-local tracker that makes progress inspectable and allows a
   later coordinator to reconstruct the run from repository evidence.
7. Require a final whole-branch code review before presenting merge or deploy
   options.
8. Clean up lifecycle-owned Orca terminals, browser tabs, and worktrees after
   their outputs are safely integrated.
9. Provide strong non-Orca execution paths for native Codex and Claude Code.

## Non-goals

- Guarantee survival across application, machine, or runtime shutdowns.
- Build a general distributed job scheduler outside the agent hosts.
- Merge or deploy automatically.
- Replace repo-specific instructions, verification commands, or release
  policies.
- Force maximum-cost models or maximum review fan-out for every task.
- Parallelize tightly coupled or shared-file implementation.
- Treat an agent lifecycle signal as proof of correctness.

## Core terms

- **PREPARE:** Interactive phase that grounds in the repo, resolves decisions,
  produces the specification and plan, and obtains approval.
- **RUN:** Unattended implementation phase that consumes the approved artifacts.
- **Authority envelope:** Explicit defaults and boundaries the coordinator may
  apply without returning to the user.
- **Task packet:** Complete dispatch contract for one implementation, review,
  verification, integration, or cleanup task.
- **Acceptance matrix:** Traceable mapping from requirements to implementation
  tasks and verification evidence.
- **Lifecycle-owned resource:** An Orca worktree, terminal, or browser tab
  created by the current orchestration run and recorded in its tracker.
- **Run identity:** A durable run UUID, root task, repository identity, and exact
  allowlist of task, dispatch, worktree, terminal, and browser-resource records
  owned by one milestone execution.
- **Dispatch attempt:** One host lifecycle attempt identified separately from
  the stable plan task. Under Orca it includes `planTaskId`, `orcaTaskId`,
  `dispatchId`, attempt number, worker identity, and base commit.
- **Integration worktree:** The single worktree that owns the milestone branch,
  integrated result, PR updates, and full-repository gates.

## Architecture

The skill has one shared orchestration policy and three runtime adapters:

1. **Orca adapter — reference implementation.** Materializes the plan as Orca
   tasks and dependencies, dispatches workers with injected lifecycle
   preambles, waits for `worker_done`, `escalation`, and `decision_gate`
   messages, routes worktrees, and records cleanup.
2. **Native Codex adapter.** Uses a Sol-class coordinator, capability-probed
   long-running coordination (`/goal` when available or the explicit STATE
   loop), custom or built-in Codex agents, native subagent controls, and this
   repository's `code-review` skill.
3. **Native Claude adapter.** Uses a Fable-class coordinator,
   capability-probed long-running coordination, custom Claude subagents with
   worktree isolation, and Claude's own `/code-review` workflow. It must not
   invoke this repository's Codex-oriented `code-review` skill as a substitute.

Orca is not a secondary appendix. Its adapter defines the full lifecycle and is
implemented first. The native adapters describe how to preserve that lifecycle
without Orca rather than reducing the workflow to a generic prompt.

The shared policy uses four capability roles:

1. **Coordinator:** Read-only over implementation paths. It owns decisions,
   dispatch, evidence adjudication, and the logical STATE transition stream, but
   holds no merge/deploy or ordinary publication credential.
2. **Control writer:** A narrow fenced mechanism that can update only approved
   milestone control artifacts after validating the coordinator lease, schema,
   expected source SHA, and transition. It is the coordinator's physical writer,
   not a second logical STATE owner.
3. **Verification executor:** Independent of the implementer. It resolves only
   approved command IDs from canonical PLAN data, runs them at an exact
   clean-tree SHA, and emits immutable verifier records.
4. **External-action executor:** A protected service or distinct principal and
   the only role with scoped publication and Orca cleanup credentials. It
   accepts typed, one-shot allowlisted actions, rechecks current authority,
   epoch, subject, effects, and postconditions immediately before submission,
   and exposes no merge or deploy operation.

An adapter must probe and record how it enforces these boundaries. Coordinator
write prevention may fall back to reliable attributable detection, but external
credentials, the control root, and the executor endpoint require OS-enforced
sandbox/container/distinct-principal isolation from ordinary workers. Same-user
file modes, hidden paths, and bearer tokens are not isolation boundaries. RUN is
blocked when the adapter cannot prevent workers from reading credentials/control
state, reaching privileged sockets/process state, or bypassing the constrained
executor.

## Repository artifacts

Follow an owning repository's established milestone/document conventions when
they exist. Otherwise create a directory such as
`docs/milestones/<milestone-slug>/` containing:

- `SPEC.md` — approved goals, non-goals, architecture, behavior, invariants,
  acceptance criteria, defaults, and authority boundaries.
- `PLAN.md` — task IDs, dependency DAG, ownership map, worker capabilities,
  verification commands, review points, integration order, closeout steps, and
  the immutable requirement-to-task side of the acceptance matrix.
- `STATE.md` — mutable execution ledger with a versioned canonical
  machine-readable block plus a human-readable journal. It records run identity,
  per-attempt host IDs, task stage and condition, model/agent, resources, commits,
  mutable acceptance evidence, review results, authority, assumptions, retained
  resources, and next-ready work.
- `<git-common-dir>/milestone-orchestrator/<run-id>/evidence.jsonl` — protected,
  append-only, digest-chained verifier, scan, effect, grant, action, CI, cleanup,
  and terminal closeout evidence. It is outside every worktree and writable only
  by capability services.

`SPEC.md` and `PLAN.md` are stable inputs during RUN. Changes to either create a
new version and digest through an explicit recorded replan. `STATE.md` is
updated after material pre-publication transitions. Before each publication
cycle, one finite control-anchor commit snapshots the protected evidence
ledger's current sequence/digest and exact implementation subject. Post-push
action, CI, final-review, cleanup, and closeout evidence remains in the external
ledger and PR/handoff surfaces rather than creating an infinite audit-commit
loop. A remediation that changes implementation starts one new anchor cycle.
Its schema defines stable IDs, enums, legal transitions, evidence freshness,
implementation subjects, dependency and ownership invariants, and closeout
requirements. Schema v1 fails closed on unknown versions; when a later schema
ships, it must include a fenced, atomic, idempotent migration from every still-
supported prior version rather than requiring manual STATE edits. One
coordinator owns the STATE transition stream;
workers return structured evidence for it to adjudicate, and the fenced control
writer performs the actual allowlisted file update. The coordinator may cause
edits only to these orchestration/control artifacts during RUN; those edits are
management, not implementation.

## Phase 1: PREPARE

### 1. Ground in the repository

Read applicable `AGENTS.md`, `CLAUDE.md`, workflow guides, milestone manifests,
architecture documents, existing plans, recent commits, current branch and
dirty state, and the relevant implementation. For broad repositories, dispatch
parallel read-only survey agents with non-overlapping questions. Preserve all
unrelated user changes.

### 2. Build a decision inventory

Identify unresolved decisions across:

- Desired behavior, user flows, and non-goals
- Architecture and module boundaries
- Compatibility and migration constraints
- State, data, privacy, and security
- Performance and operational limits
- Error handling and recovery behavior
- Testing and acceptance evidence
- Release, rollback, commit, push, PR, merge, and deploy authority
- Credentials, external systems, browsers, and other required capabilities
- Destructive or irreversible action boundaries
- Defaults the coordinator may choose without asking

### 3. Ask consolidated decision packets

Ask related questions together after repository grounding. Every material
question includes:

- Why the decision matters
- The recommended answer
- The default the orchestrator will adopt
- The materially different alternatives

Do not impose an arbitrary limit on follow-up rounds. Each later packet contains
only unresolved decisions that can materially alter architecture, behavior,
scope, validation, or authority. Minor implementation choices belong in the
authority envelope.

### 4. Write the design specification

The specification must include goals, non-goals, architecture, components,
data/control flow, invariants, negative behavior, failure handling, acceptance
criteria, external actions, authority envelope, and escalation policy. It must
contain no unresolved `TBD`, `TODO`, or decision placeholders before approval.

### 5. Select and run adversarial review

Use this repository's `adversarial-review` skill. The authoring agent selects
the tier and records the rationale:

- Default: bounded, well-understood work. All roles still use xhigh reasoning.
- Codex `--high`: architecture-shaping, security-sensitive, ambiguous,
  cross-cutting, migration-heavy, or expensive-to-rework work.
- Claude `--ultra`: the same risks at unusually large scale or with especially
  high uncertainty, where wider ultracode fan-out and stronger culling are
  justified.

Resolve or explicitly reject all promoted findings according to the skill's
judge and convergence rules. A non-converged review blocks RUN unless the user
accepts the documented open question.

### 6. Produce and review the implementation plan

Create deliverable-sized task nodes with shallow dependencies, explicit path or
component ownership, role/model needs, verification, review, integration, and
cleanup steps. Run `adversarial-review` again at a tier selected from the plan's
risk. When both spec and plan exist, require coverage mapping and spec-plan drift
checks.

### 7. Obtain one final execution approval

Present the reviewed `SPEC.md`, reviewed `PLAN.md`, both review reports, the
acceptance mapping, and an explicit authority summary. The approval prompt says
that approval begins an unattended RUN and lists the default actions separately:
local commit, push, draft-PR create/update, PR-ready transition, reviewer
assignment, merge, and deploy. The default remains commit + push + draft PR
unless the user opts out; PR-ready and reviewer-notification actions require
their own recorded flags, while merge and deploy are always disabled.

Approval freezes the product, architecture, execution, and authority contract.
A plan-only replan inside the frozen SPEC and authority envelope may proceed
after drift and review checks. Any SPEC or authority change requires user
reapproval.

### 8. Initialize state, checkpoint, and preflight

Create `STATE.md`, record the approved spec and plan versions, and verify:

- Orca runtime and orchestration availability when using Orca
- A unique run UUID, root task identity, repository identity, and atomic local
  coordinator lease stored outside worker worktrees. The lease records owner,
  run ID, epoch, monotonically increasing fencing token, expiry, and renewal
  cadence. Acquisition is exclusive; takeover requires expiry plus an owner
  liveness check; loss of renewal blocks transitions and mutations. Do not adopt
  runtime-global Orca entities outside the recorded run allowlist
- A newly created, clean integration worktree, unique milestone branch, pinned
  starting commit, and immutable per-wave base refs
- Baseline repository verification
- Dirty paths classified as unrelated, relevant milestone inputs, or conflicts;
  relevant uncommitted input requires an approved checkpoint/snapshot strategy
- Permission mode, external credentials, and secret-handling boundaries
- Enforceable capability mappings for the read-only coordinator, fenced control
  writer, independent verifier, constrained external-action executor, and
  ordinary workers without publication/deployment/cleanup credentials
- Available Claude and GPT routes, exact launch commands, capability probes,
  observed runtime identities, and allowed substitutions
- Correct host and review-workflow discovery, version recording, and explicit
  compatibility probes for every selected adapter
- Chrome DevTools and/or Orca embedded-browser availability when relevant
- Worktree base and integration strategy
- Publication envelope: enabled actions, forge/repository, remote, base/head refs,
  tagged remote-ref expectation (`absent` plus base OID for first publication or
  `present` plus exact OID for updates), existing-PR identity or idempotent creation rule,
  force-push prohibition, and distinct ready/reviewer-notification flags
- Derived effects for each permitted Git/forge action: branch and PR workflows,
  preview/production deployments, privileged CI, auto-merge, merge queues, bots,
  webhooks, labels, reviewer notifications, and other triggered automation.
  Publication is blocked when an effect is unknown or outside the envelope

Checkpoint-commit the approved `SPEC.md`, `PLAN.md`, initialized `STATE.md`, and
acceptance mapping on the integration branch using the configured human author.
Record the checkpoint commit and use it as the first worker base so isolated
worktrees and recovery always see the exact approved contract.

This local contract checkpoint is a prerequisite for normal isolated RUN and is
presented separately from later implementation commits and publication. If the
user disables every local commit, PREPARE must either select and validate a
restricted no-commit mode using one serialized same-worktree writer plus an
immutable external artifact snapshot, with push and PR disabled, or stop before
RUN. The coordinator never silently overrides a local-commit opt-out.

RUN starts only after these checks pass or the approved plan explicitly records
a safe fallback.

## Phase 2: RUN

### 1. Reconcile before dispatch

Compare `SPEC.md`, `PLAN.md`, and `STATE.md` with Git, Orca task/dispatch state,
live terminals, worktrees, forge state, host review records, and verification
evidence. Repair the tracker before creating new work using field-specific
authority:

- Git owns commit reachability and file state.
- Fresh immutable verifier records own test results.
- Host review records own review completion.
- Active Orca `taskId` + `dispatchId` own runtime lifecycle identity.
- The forge owns remote refs and PR state.
- The approved authority envelope alone owns permissions.
- Creation provenance and current host listings jointly own resource identity.

Cross-source contradictions are recorded and resolved conservatively; Git must
never be used to infer review completion, authority, dispatch identity, or safe
resource cleanup. Immediately before each STATE transition, dispatch, cleanup,
push, or forge mutation, the responsible fenced mechanism revalidates the
current lease owner, epoch, fencing token, and authority. A stale token fails
closed and cannot be retried until reconciliation establishes a new epoch.

### 2. Materialize the Orca DAG

Create tracked Orca tasks under the run's unique root and exact allowlist. Every
dispatched worker must have a real Orca task and dispatch. Persist the stable
plan task separately from each `orcaTaskId`/`dispatchId` attempt and verify the
source pane before accepting lifecycle messages.

Orca completion is only dispatch-attempt completion. Because `worker_done` can
complete an Orca task even when its payload reports failure, every semantic
readiness edge passes through a coordinator-adjudicated acceptance gate; no
integration or publication dependency points directly at a dispatched worker
task. Review and verification workers also feed acceptance gates rather than
releasing dependencies themselves.

A host failure may reuse an Orca task only when the host still considers it
retryable. Once `worker_done` terminally completes an attempt, any retry uses a
fresh linked Orca task and dispatch. All semantic failures and attempts count
against the stable plan-task budget, never merely the host task ID.

### 3. Build complete task packets

Each task packet contains:

- Run ID, stable plan task ID, host task/dispatch IDs when allocated, attempt
  number, task type, goal, and dependency IDs
- Relevant approved-spec sections and acceptance rows
- Owned paths/components and forbidden overlap
- Starting branch, immutable requested base SHA, observed worker HEAD, and
  integration target
- Required logical route, agent family, capability, reasoning level, exact host
  launcher, allowed substitutions, and identity-verification method
- Applicable repo instructions and skills
- Required implementation discipline such as TDD when applicable
- Exact task-local verification commands
- Required commit/handoff format
- Expected `worker_done` evidence
- Remediation owner and cleanup policy

### 4. Route mixed workers adaptively

The coordinator is not tied to its own model family. It records the reason for
each choice but does not ask for routine routing approval.

Default heuristics:

| Task shape | Preferred route |
|------------|-----------------|
| UI implementation, interaction, visual polish | Claude |
| Architecture, integration, difficult debugging, thorough review | Sol/high or stronger judgment model |
| Read-heavy exploration and repository mapping | Terra, Luna, Spark, or equivalent fast agent |
| Mechanical bounded implementation and test execution | Luna, Spark, or equivalent economical worker |
| Security, migration, broad correctness review | High/xhigh capable model; cross-family review when valuable |

Start with the cheapest model likely to succeed. Each adapter maps the logical
route to an exact launcher, model slug, effort flag, capability probe, and
observed runtime identity. Orca agent-first launch is used only when it can
express the route; custom-argv launch records any fallback shell or extra
terminal it creates. Protected review/judge routes cannot be silently
downgraded. Any substitution or unavailable route is recorded before dispatch.

Escalate when a task is
ambiguous, high-risk, integration-heavy, or a cheaper worker fails with a
reasoning/capability limitation. Do not downgrade judges or arbiters below their
own review workflow's requirements.

### 5. Dispatch bounded waves

Independent implementation slices use separate Orca worktrees. For each wave,
create an immutable ref at the approved integration SHA, pass it explicitly as
the Git base, and verify the new worktree's observed HEAD before dispatch. Orca
sidebar lineage and Git base are chosen explicitly rather than conflated.
Shared-file, shared-state, or tightly coupled tasks are serialized.

The integration worktree is newly created and clean. Before every integration
commit, fetch the remote, compare expected ref OIDs, prohibit force push, stage
only paths allowed by task ownership plus approved control artifacts, and
inspect the staged diff. Unrelated dirty state never enters the integration
worktree. Relevant uncommitted milestone input must already have the approved
checkpoint or same-worktree serialized fallback recorded during PREPARE.

Use one writer per owned path/component. Do not assume the host's configured
maximum thread count. Choose concurrency from actual independence, repository
setup cost, available runtime capacity, and integration risk. Prefer shallow DAGs
of roughly three or four waves over long dependency chains.

### 6. Supervise without implementing

The coordinator may inspect, dispatch, wait, steer, synthesize, answer gates,
update control artifacts, and select the next task. It may not edit source,
tests, configuration, migrations, generated deliverables, or implementation
documentation, and may not take over a failed task. Adapters enforce this with
read-only implementation paths plus writable control artifacts when possible;
otherwise they use the probed attribution-plus-validation control recorded in
STATE. The coordinator's implementation filesystem is read-only; control writes
flow only through the lease-fenced allowlist. RUN is blocked when the selected
adapter offers neither prevention nor reliable detection. A coordinator attempt
to edit implementation is denied or treated as a failed run in validation, not
merely discouraged.

Use rolling waits for `worker_done`, `escalation`, and `decision_gate` messages.
A timeout is a liveness checkpoint, not worker failure. Heartbeat or terminal
activity proves liveness, not completion.

### 7. Review, remediate, and verify

Use fresh-context reviewers for risky tasks or integration boundaries. A
review-only completion reports findings; it never authorizes coordinator edits.
Verified findings create remediation tasks owned by an implementer, followed by
re-verification and re-review. Do not fix weak or unverified review suggestions.

The durable ledger deliberately separates three dimensions:

```text
Orca attempt: created -> dispatched -> completed | failed | blocked | abandoned
Task stage:   pending -> implemented -> reviewed -> verified -> integrated -> closed
Condition:    active | blocked | failed | circuit-open | cleanup-pending | retained
```

`worker_done` closes only the current dispatch attempt. The coordinator validates
its structured outcome, commit, review, and command evidence before advancing
the durable task stage. Remediation is a new linked plan task and dispatch, not a
backward mutation that erases earlier evidence. The state schema defines legal
transitions by task type so review, verification, integration, and cleanup tasks
are not forced through implementation-only stages.

### 8. Integrate serially

A dedicated integration worker brings verified slices into the milestone
branch, resolves ordinary conflicts, runs integration checks, and returns commits
plus immutable structured acceptance evidence. It never edits `STATE.md` or a
coordinator-owned mutable ledger. The coordinator adjudicates that evidence and
uses the fenced control writer for the STATE transition. Architectural
mismatches trigger a replan; an actual contradiction in the approved spec
triggers user escalation.

### 9. Commit, push, and open a pull request

Within the approved publication envelope, RUN automatically commits, pushes,
and opens or updates one draft pull request after a stable integrated result
exists unless PREPARE recorded an opt-out. Only the constrained external-action
executor can publish; ordinary workers and the coordinator receive no
publication, merge, deploy, cross-run cleanup, or credential-export capability.
Immediately before submission the executor validates the current lease token,
run epoch, typed action schema, scoped credential, target identity, anchored
subject/scan, and a fresh effect snapshot derived from repository configuration
and authoritative forge/Orca APIs, then emits an immutable audit record. Callers
cannot supply their own claimed effect list.

Before push, fetch and compare a tagged remote-ref expectation: an initial push
must prove the full ref is absent and scans base-to-head; an update must match
the recorded OID. Use an explicit non-force refspec and stop on mismatch.
Draft-PR creation is idempotent against
the recorded forge, base, head, and PR identity. Later remediation updates the
same PR. Commit messages use the configured human author and contain no AI
attribution.

Draft creation does not imply permission to mark ready, assign reviewers, or
trigger notification-producing actions. Those use their own authority flags.
Any push or PR action whose workflows, deploy hooks, merge automation, bots, or
notifications were not approved is refused even when the direct action itself
was enabled.

### 10. Run mandatory final code review

Before presenting merge or deploy options, run a whole-branch review against the
correct base:

- A Codex review worker invokes this repository's `code-review` skill.
- A Claude review worker invokes Claude's own `/code-review` workflow.
- Under Orca, the coordinator may run one or both and may add cross-family
  supplementary review when risk warrants it.

The coordinator selects intensity from milestone scope, risk, change shape,
prior failures, and review evidence. Verified findings are remediated by workers,
then full verification and final review repeat until no merge-blocking findings
remain or the recorded remediation ceiling is reached.

### 11. Close the run

Run the full repository gate and confirm the PREPARE-time required-check snapshot
with bounded polling. Infrastructure failures use the recorded retry budget;
pending or uncertain CI leaves the PR draft and produces a blocker rather than
an indefinite wait. Finalize the acceptance matrix and append terminal evidence
to the protected ledger, mark the PR
ready only when its separate flag and all required gates permit it, clean
lifecycle-owned Orca resources, and stop before merge or deployment.

The final handoff includes branch and PR identifiers, base/head commits, exact
verification commands and results, CI state, acceptance coverage, review rounds
and dispositions, cleanup inventory, retained resources, open risks, elapsed
budgets, and the exact next action that still requires user authority.

## Authority and escalation

The coordinator chooses the safest reversible option consistent with the
approved spec and records the decision. It contacts the user only for:

1. A destructive or irreversible action outside explicit preauthorization.
2. Missing credentials, permissions, external authority, or human-only action.
3. A genuine contradiction in the approved spec with materially different
   outcomes.
4. A non-converged required review whose open finding changes safety, behavior,
   architecture, or release confidence.
5. Repeated no-progress after the retry/replan budget.
6. External infrastructure failure for which no safe in-scope workaround exists.

Routine library choices, reversible implementation details, model routing,
review timing, retry worker choice, and task subdivision do not justify user
interruption when the authority envelope covers them.

Default budgets are explicit and configurable in `PLAN.md`: one retry for an
evidenced transient failure; three consecutive failed attempts before a task
circuit opens; three final-review remediation rounds; two plan-only replans; a
30-minute CI wait with at most two evidenced infrastructure retries; and two
consecutive supervision cycles with no new commit, evidence, or actionable
liveness change after steering before global no-progress escalation. PREPARE may
override these defaults when repo evidence justifies it, but it may not leave a
budget unset. Exhaustion creates a terminal `blocked` or `escalated` state with
the counter, freshest evidence, and disposition; it does not loop silently.

The canonical STATE block contains a `closeout` record with branch, forge and PR
IDs, base/head SHAs, requirement totals, exact verification commands and exit
results, evidence source SHA and freshness, CI checks and terminal states,
review rounds and open findings, publication actions, budget counters, resource
cleanup/retention, open risks, and next authorized action. `closed` is illegal
unless every required field is present, all required acceptance rows are fresh,
no merge-blocking finding is open, every resource is removed or explicitly
retained, and merge/deploy remain unexecuted.

### Cancellation and authority revocation

A user stop or authority revocation takes precedence over unattended progress.
The coordinator enters `aborting`, revokes new dispatch and external-action
authority, invalidates outstanding action leases, and advances the fencing
epoch before signaling workers. `orca orchestration run-stop` is forbidden
unless both preflight and cancellation-time reconciliation prove the runtime is
exclusive to this run; otherwise cancellation blocks or abandons only allowlisted
tasks and signals or terminates only identity-proven run-owned terminals.

The external-action executor rejects stale epochs before submission and records
possibly in-flight remote requests that cannot be recalled. The coordinator
waits a bounded interval, inventories partial commits, remote/PR effects,
worktrees, terminals, and captures; preserves all recoverable Git state; and
cleans only proven-safe resources. Abort cannot finish until every retained
process is proven exited, quiescent, or capability-quarantined from credentials
and mutation tools. It writes a resumable or terminal abort report and never
merges or deploys. A restarted coordinator uses a new run epoch and must
explicitly fence or abandon stale dispatches before resuming.

## Failure and recovery rules

- **Worker silence:** Inspect task and terminal liveness before intervening.
- **Transient failure:** Retry once when evidence indicates a transient cause.
- **Repeated failure:** Reframe, split, or escalate the worker/model. Three
  consecutive failures on the same Orca task trigger the circuit breaker and a
  replan or escalation decision.
- **Review failure:** Send verified findings to a remediation owner and re-review.
- **Integration failure:** Use an integration worker; do not let the coordinator
  patch conflicts.
- **Dirty user state:** Preserve it and keep it out of milestone commits.
- **Runtime loss:** Reconstruct from Git, the plan, the tracker, verification
  evidence, and any surviving Orca state. Increment the run epoch, inventory
  full worktree IDs and terminals, re-resolve runtime-scoped handles, validate
  each active task/dispatch, reinject current lifecycle identity before resumed
  work, and deduplicate outputs by commit and evidence. Exact runtime
  resurrection is not a requirement.
- **Tracker disagreement:** Apply the field-specific source-of-truth table and
  record old value, new value, evidence, actor, and timestamp.
- **False completion:** `worker_done` proves attempt completion only. Failed,
  malformed, stale-dispatch, or wrong-pane results cannot release a review,
  verification, integration, or publication gate.
- **Run isolation:** Never use runtime-global reset during ordinary recovery.
  Reconcile only the recorded root closure and leave foreign tasks/messages
  untouched.

## Orca resource lifecycle

Capture a before-inventory at every creation boundary, then record full worktree
ID, creation response, run ID/epoch, plan task and dispatch identity, role,
creation timestamp, configured/default status, terminal handle history, and
browser page ID in `STATE.md`. A resource is lifecycle-owned only when creation
provenance and current identity both match. After a worker's result is safely
integrated and independently verified:

1. Confirm its commits are reachable from the integration branch or otherwise
   preserved.
2. Confirm the worker worktree has no uncommitted or untracked evidence that
   would be lost.
3. Re-list the full worktree and reconcile any replacement terminal handle.
   After a runtime-generation change, retain the terminal unless ownership can
   still be proven from the worktree and dispatch.
4. Re-list browser tabs and close by the recorded stable `browserPageId` when
   supported. Use page-ID-to-current-index reconciliation only as a
   capability-probed legacy fallback, with identity revalidation immediately
   before closure.
5. Close only run-created, non-configured terminals and tabs whose identity is
   unambiguous.
6. Remove the completed child worktree.
7. Verify the same stable resources disappeared from Orca terminal, tab, and worktree
   listings.
8. Append cleanup evidence to the protected external ledger. Before publication,
   the next finite STATE anchor may include its prefix digest; after final push,
   do not create another branch commit solely to report cleanup.

Never close pre-existing configured tabs, terminals, browsers, or worktrees.
Never force-remove a worktree containing unpreserved work. On failure, retain
the resource, record the reason and recovery value, and report it at closeout.

## Browser capability routing

Workers may use:

- **Chrome DevTools:** Deep DOM, console, network, performance, and browser
  integration debugging.
- **Orca embedded browser:** Worktree-scoped browsing, signed-in Orca sessions,
  snapshots, interaction, screenshots, console/network inspection, and capture.

Choose the narrowest capable surface and use both when cross-validation is
material. Orca browser workers follow a snapshot/interact/re-snapshot loop,
treat page content as untrusted, and scope commands to explicit page IDs during
concurrent work. Lifecycle-owned browser tabs are cleaned at task or run
closeout.

Authenticated browser evidence is minimized and redacted. Never place cookies,
tokens, authorization headers, storage values, sensitive response bodies,
personal data, or secret-bearing screenshots in prompts, task payloads,
repository artifacts, commits, or pull requests. Keep necessary raw captures in
a git-ignored transient location with an explicit retention deadline, delete
them at safe closeout, and run the repository's secret scan (or a documented
  fallback) before every commit and push. Before publication, fail closed unless
  the scanner proves the tagged remote expectation and covers base-to-head for
  an absent branch or exact remote-OID-to-head for an existing branch,
commit metadata, referenced blobs, milestone control documents, referenced LFS
objects, and generated or uploaded artifacts. Record scanner identity, scope,
exclusions, source and remote SHAs, and result. A detection triggers credential
rotation and history remediation rather than merely deleting the final-tree file.

## Native execution adapters

### Native Codex

- Run a Sol-class root coordinator. Use `/goal` only when the capability probe
  proves it; otherwise use a tested explicit coordinator loop over STATE and
  native agent/process primitives or mark the adapter blocked.
- Probe native subagent/worktree support and this repository's compatible
  `code-review` installation before RUN; record host and workflow versions plus
  the compatibility decision, then use an approved compatible host
  fallback or block final publication when the mandatory review is unavailable.
- Use native custom/built-in agents and direct subagent instructions.
- Keep `agents.max_depth = 1` unless a separately reviewed need exists.
- Reproduce the task ledger and ownership map in repo artifacts because native
  agent threads are not the durable source of truth.
- Arrange explicit worktree/path isolation for write-heavy tasks.
- Map every native agent/thread/worktree to the run allowlist. Define bounded
  cancellation, identity-proven termination, partial-work preservation, cleanup,
  ambiguous-resource retention, restart reconciliation, and foreign-resource
  protection using Codex's actual primitives.
- Use this repository's `code-review` skill for final review.
- Enforce manager-only behavior through the skill, agent instructions, and any
  available tool restrictions or hooks.

### Native Claude Code

- Run a Fable-class custom coordinator. Use `/goal` only when the capability
  probe proves it; otherwise use a tested explicit coordinator loop over STATE
  and native agent/process primitives or mark the adapter blocked.
- Probe subagent/worktree support and Claude's compatible `/code-review`
  workflow before RUN; record host and workflow versions plus the compatibility
  decision. Use an approved compatible Claude or Orca review route, or block
  final publication when no correct Claude review is available; do not silently
  substitute the Codex skill.
- Prefer ordinary custom subagents with worktree isolation for implementation.
- Map every Claude subagent/session/worktree to the run allowlist. Define bounded
  cancellation, identity-proven termination, partial-work preservation, cleanup,
  ambiguous-resource retention, restart reconciliation, and foreign-resource
  protection using Claude's actual primitives.
- Do not make experimental agent teams the default implementation substrate;
  they are suitable for design councils, research, and adversarial review when
  peer communication is useful.
- Use Claude's own `/code-review` for final review.
- Use saved/dynamic workflows selectively for bounded homogeneous fan-out or
  repeated cross-check stages, not as the only milestone recovery record.

Both native adapters use the same PREPARE artifacts, authority envelope,
acceptance matrix, manager boundary, remediation loop, automatic commit/push/PR
default, and merge/deploy stopping point. Their conformance suites must include
cancellation, stale identity, ambiguous ownership, cleanup failure, retained
resources, authority revocation, and attempts to bypass the constrained
external-action executor.

## Package layout

```text
skills/general/milestone-orchestrator/
  SKILL.md
  agents/
    openai.yaml
  references/
    platform-adapters.md
    intake.md
    task-contracts.md
    state-schema.md
    validation.md
  assets/
    spec-template.md
    plan-template.md
    state-template.md
  scripts/
    lib/
      state_document.rb
      lease_store.rb
      audit_log.rb
    validate-state
    control-state
    authorize-action
    execute-action
    launch-role
    inspect-effects
    run-verification
    scan-outgoing
    run-pressure-suite
    create-fixture-repo
```

Keep `SKILL.md` focused on the shared lifecycle and selection rules. Put Orca,
Codex, and Claude mechanics in `references/platform-adapters.md`; detailed question,
packet, state, and validation contracts belong in references. Templates are
output assets. Scripts provide deterministic validation, fenced control and
external-action boundaries, independent evidence, pressure scoring, and
disposable test setup.

Adding the finalized skill requires synchronized entries in `CATALOG.md` and
`skills.yaml`. Installation behavior is not changed unless explicitly requested.
If install targets later change, run `scripts/sync-skills --dry-run` for every
affected target before applying global symlinks.

## Validation strategy

The user does not need to supply a production codebase for initial validation.
Use four layers:

### 1. RED baseline pressure tests

Before writing the skill, give fresh agents realistic milestone prompts without
the skill and record failures such as:

- The coordinator implements directly.
- It asks routine questions during RUN.
- It dispatches overlapping writers.
- It stays within its own model family despite a better available worker.
- It accepts self-review or lifecycle completion as correctness.
- It opens a PR but skips final review/remediation.
- It merges or deploys without authorization.
- It leaves Orca terminals, browser tabs, or worktrees behind.
- It cannot reconstruct progress after runtime state is absent.

Version the prompt corpus and fixture revision. Record host, model, effort,
configuration, skill commit, and event log for each trial. Replace subjective
pass/fail labels with machine-checkable assertions, run repeated fresh-context
trials, and set comparative thresholds with allowed variance. The goal is a
measurable improvement over baseline, not the brittle claim that every
unskilled run must fail.

Before any post-skill trial, freeze a versioned protocol containing corpus and
fixture hashes, repetition count, host/model configuration, primary metrics,
scoring rules, minimum effect, variance or confidence treatment, and exclusions.
Coordinator implementation writes, unauthorized publication, merge/deploy,
foreign-resource mutation, and acceptance-gate bypass are zero-tolerance
failures and cannot be averaged away by aggregate improvement.

### 2. Deterministic validator tests

Test schema migration, legal and illegal per-task transitions, attempt/task
separation, dependency gates, run/task/dispatch identity, ownership overlap,
evidence freshness and source SHA, missing acceptance coverage, unresolved
review findings, stale or foreign resource records, publication authority, and
incomplete closeout. Watch each behavioral test fail before adding the
corresponding validator behavior. Add a negative coordinator-write test that
must be blocked or produce attributable policy-failure evidence.

### 3. Disposable end-to-end fixture

Generate a small temporary Git repository with independent UI/backend/test
slices, deliberate overlap, a seeded review defect, a failing verification path,
and harmless browser checks. Exercise actual Orca tasks, mixed Claude/GPT
workers, worktrees, integration, review remediation, tracker reconciliation,
and lifecycle cleanup. Give the fixture a unique run namespace; forbid global
Orca reset and assert that pre-existing foreign tasks/resources are unchanged.
Use a disposable bare Git remote plus a fake or action-recording forge adapter
to assert commit, push, one draft-PR creation, later updates, and the absence of
merge/deploy calls without touching a production remote.

Run a deterministic fault matrix covering heartbeat with timeout, silent live
worker, exited terminal, stale or malformed `worker_done`, wrong dispatch/pane,
attempt counts one and three, tracker disagreement, relevant and unrelated dirty
state, integration conflict, runtime-generation change, configured resources,
ambiguous cleanup identity, CI timeout, cancellation, and authority revocation.
For each fault assert the exact allowed action, forbidden action, ledger change,
retry/replan result, resource retention, and escalation behavior.

Add adversarial capability tests in which ordinary workers and stale-epoch
processes attempt direct `git`, forge, browser, merge/deploy, credential-export,
and cross-run cleanup bypasses. Assert that only the constrained executor can
perform an approved action and that cancellation fences it before submission.

Replay equivalent conformance scenarios through native Codex and native Claude
using their real host primitives. Assert isolation, manager-only enforcement,
remediation, publication boundaries, recovery, and evidence that Codex invoked
this repository's `code-review` while Claude invoked its own `/code-review`.

### 4. Small real-repository pilot

Before describing the skill as proven for large milestones, run one bounded real
milestone in a user-selected repository. It should be meaningful enough to test
repo conventions and actual integration, but small enough to inspect manually.
Use the pilot evidence to revise role routing, task sizing, and cleanup rules.

Forward tests must pass the skill and raw task artifacts to fresh agents without
leaking the intended answer. Do not let previous test outputs contaminate later
runs. Raw authenticated browser captures never enter the fixture repository or
test transcripts.

## Acceptance criteria

The design is successfully implemented when:

1. One skill supports Orca-first, native Codex, and native Claude execution.
2. PREPARE produces reviewed `SPEC.md`, `PLAN.md`, and initialized `STATE.md`
   with a complete authority envelope and acceptance matrix, obtains one final
   approval over all three, and checkpoint-commits their exact versions before
   isolated dispatch; an explicit no-local-commit choice uses only the validated
   restricted mode or blocks RUN.
3. RUN does not require routine user input and the coordinator does not edit
   implementation files.
4. Mixed workers are selected adaptively and task/model rationale is recorded.
5. Independent writers are isolated; overlapping ownership is rejected or
   serialized.
6. Review findings produce worker-owned remediation and re-review.
7. Commit, push, and draft-PR creation happen automatically unless disabled.
8. Codex and Claude use their own correct final code-review workflows.
9. No merge or deploy occurs automatically.
10. Lifecycle-owned Orca terminals, tabs, and worktrees are safely cleaned or
    explicitly reported as retained.
11. The tracker separates stable plan tasks from host dispatch attempts and can
    be reconciled with field-specific evidence after a simulated runtime loss
    without touching foreign Orca state.
12. Versioned repeated pressure tests show the defined improvement over baseline.
13. Validator, fault-injection, publication-fixture, Orca E2E, and native-host
    conformance tests pass.
14. Coordinator implementation writes are denied or detectably fail validation.
15. Cancellation preserves partial work and stops new dispatch/publication.
16. Browser evidence is redacted, transient captures are excluded, and the
    full outgoing-object-range secret scan passes.
17. Ordinary workers cannot bypass the fenced control/publication/cleanup
    capabilities, and stale epochs cannot mutate external state.
18. `CATALOG.md` and `skills.yaml` remain synchronized and valid.

## Open implementation choice

The first real-repository pilot is intentionally not selected in this design.
Choose it after the disposable fixture passes so the pilot can focus on
repo-specific behavior rather than basic orchestration defects.
