# PREPARE Intake, Approval, and Preflight

Contracts for the interactive phase. The output of PREPARE is an approved,
frozen `SPEC.md` + `PLAN.md`, an initialized `STATE.md`, and a recorded
authority envelope that makes the unattended RUN possible.

## Repository grounding

Read applicable `AGENTS.md`, `CLAUDE.md`, workflow guides, milestone manifests,
architecture documents, existing plans, recent commits, current branch and
dirty state, and the relevant implementation. For broad repositories, dispatch
parallel read-only survey agents with non-overlapping questions. Preserve all
unrelated user changes.

Follow the owning repository's established milestone/document conventions when
they exist; otherwise create `docs/milestones/<milestone-slug>/` for `SPEC.md`,
`PLAN.md`, and `STATE.md`.

Distill the grounding into a **grounding digest** — a compact section of
`PLAN.md` (or `DIGEST.md` beside it when large) covering repo conventions and
instructions that bind workers, the milestone-relevant architecture and key
paths, build/test/verification commands, and known pitfalls. Every task packet
embeds this digest verbatim so workers start implementing instead of
re-exploring the repository; grounding is paid for once, in PREPARE.

## Decision inventory

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

## Consolidated decision packets

Ask related questions together after grounding. Every material question
includes:

1. Why the decision matters
2. The recommended answer
3. The default the orchestrator will adopt if unanswered
4. The materially different alternatives

No arbitrary limit on rounds, but each later packet contains only unresolved
decisions that can materially alter architecture, behavior, scope, validation,
or authority. Minor implementation choices go into the authority envelope as
recorded defaults instead of questions.

## Specification and plan requirements

`SPEC.md` (from `assets/spec-template.md`) must include goals, non-goals,
architecture, components, data/control flow, invariants, negative behavior,
failure handling, acceptance criteria, external actions, authority envelope,
and escalation policy. No unresolved `TBD`, `TODO`, or decision placeholders at
approval.

`PLAN.md` (from `assets/plan-template.md`) must include deliverable-sized task
nodes with shallow dependencies, explicit path/component ownership, role and
model needs, registered verification commands, review points, integration
order, closeout steps, and the immutable requirement-to-task side of the
acceptance matrix as a canonical JSON block (see
[state-schema.md](state-schema.md)).

**Milestone sizing.** The run's output contract is one reviewable draft PR.
When the draft plan exceeds roughly twelve implementation tasks, spans
unrelated subsystems, or would produce a PR too large to review honestly,
propose splitting it into sequential milestones during PREPARE — each with its
own SPEC, PLAN, run, and PR, ordered by dependency — and get the split
approved rather than running one oversized milestone. Longer unattended runs
also compound coordinator-recovery and drift risk; splitting is the cheaper
failure containment.

**Ownership must cover the SPEC's blast radius.** Walk each task's SPEC
sections and list every file the change can plausibly touch or break —
including the test files that adjudicate it — before freezing `owned_paths`
and per-task verification filters. A field run spent both its replans and
five coordinator packet-scope errors on the same root cause: "the approved
PLAN's path-ownership map does not cover the blast radius of its own SPEC."
The plan review (either depth) must check this mapping explicitly.

**Calibrate every gating quantity before freezing it.** An acceptance witness
naming a numeric threshold, an aggregation rule, or a population/exclusion
rule is a measurement contract; freezing one that real behavior cannot satisfy
costs a mid-RUN SPEC amendment and an owner interrupt. Dry-run each against
real baseline data before approval, record the observed distribution and the
command that produced it (`MEASUREMENT.md` beside SPEC, or a SPEC section when
small), and pin each bound outside the observed range rather than tight
against one sample. State explicitly which population the witness ranges over,
and how early termination, structurally unrecoverable outliers, and absent
samples are treated. A field run spent four owner-authorized SPEC amendments
on exactly that list — an unsatisfiable floor, an unrecoverable outlier, a
per-run mean that under-credited a real effect fivefold against the pooled
figure, and a cap the feature was designed to exceed — with the feature
working and the gate computation exact in every case; only the frozen contract
was wrong. The plan review (either depth) must check that every gating
quantity carries provenance.

Three extensions field runs paid for:

- **Power, not just provenance.** A pass/fail threshold over a stochastic
  metric records its false-fail probability at the planned sample size
  (exact binomial or equivalent) in the measurement record. A
  park-triggering gate needs a sample size that makes false-fail acceptably
  rare — a field run parked an entire milestone on a 100-seed band gate
  whose false-fail rate was ~11% band-centred and ~46% at the band edge; the
  successor proved the config was dead-centre and the park was noise.
- **Inherited thresholds are never grandfathered into decision gates.** A
  holdover number promoted to park-or-promote authority is re-calibrated
  under this rule like a new one.
- **Calibrate on the arm the witness will judge.** A witness affected by the
  milestone's feature is dry-run on the feature-ON arm, not merely baseline
  — a field run spent four owner amendments on witnesses calibrated against
  feature-OFF data applied to a feature that changed exactly what they
  measured. Record which arm each quantity was calibrated against.

`PLAN.md` also records the **execution profile** (`full` or `lite`, per the
SKILL.md table) with its rationale, the grounding digest (or a pointer to
`DIGEST.md`), and the computed worker-dispatch budget. The profile is part of
the approved contract and is surfaced in the final approval prompt; moving
from `lite` to `full` mid-run is a plan-only replan, while relaxing `full` to
`lite` requires user reapproval.

## Review depth selection

Review depth is a coordinator recommendation made from risk after grounding,
surfaced with its rationale in the final approval prompt, and recorded in
`PLAN.md`. Default to the cheapest depth that fits the risk, and let the user
override in either direction.

| Depth | Default for | Mechanics |
|-------|-------------|-----------|
| `standard` | `lite`-profile milestones and well-understood `full` ones | One fresh-context reviewer at high reasoning effort reviews `SPEC.md` and `PLAN.md` together: acceptance coverage, spec-plan drift, path-ownership gaps and overlaps, gating-quantity provenance, verification-command sanity (do they run from a fresh checkout?), feasibility, and unstated assumptions. |
| `adversarial` | Architecture-shaping, security-sensitive, migration-heavy, ambiguous, cross-cutting, or expensive-to-rework milestones | This repository's `adversarial-review` skill — four parallel fresh-context attackers and one rejection-first synthesis pass, run on the spec and the plan together. It has one depth; there is no higher tier to escalate to. |

**Proof-bearing milestones cap how cheap review may go.** When the primary
deliverable is a causal proof, falsification result, or a park-or-promote
ruling — anything where the milestone's *conclusion* is the product — the
artifact carrying that conclusion is reviewed at high effort even under a
`lite` profile or `standard` depth. A field lite run's standard-tier review
passed a causal proof that a later high review overturned post-closeout; the
park decision survived by luck, not process.

At `adversarial` depth, the skill is read-only and returns at most three
findings; fix or explicitly reject each one before approval, and record the
rejection rationale in `PLAN.md`. Applying a finding is always the
coordinator's decision, never the review's. At `standard` depth,
material findings must be fixed or explicitly accepted by the user before
approval — the depth is cheaper, not softer about unresolved findings. If a
`standard` review surfaces architecture-level risk the grounding missed,
escalate the recommendation to `adversarial` rather than absorbing the risk.

## Final execution approval

Present together: reviewed `SPEC.md`, reviewed `PLAN.md`, both review reports,
the acceptance mapping, and an explicit authority summary. The approval prompt
must state that approval begins an unattended RUN and list each default action
separately:

| Action | Default |
|--------|---------|
| Local checkpoint/implementation commits | Enabled |
| Push to remote | Enabled |
| Draft-PR create/update | Enabled |
| PR ready-for-review transition | Disabled — own flag |
| Reviewer assignment / notifications | Disabled — own flag |
| Merge | Always disabled |
| Deploy | Always disabled |

Approval freezes the product, architecture, execution, and authority contract.
Record every enabled flag in `STATE.md` `authority`.

If the user disables every local commit, either select and validate the
restricted no-commit mode (one serialized same-worktree writer plus an
immutable external artifact snapshot, with push and PR disabled) or stop before
RUN. Never silently override a local-commit opt-out.

## Publication envelope

Record in STATE before RUN:

- Enabled actions, forge/repository, remote, base/head refs
- Tagged remote-ref expectation: `absent` plus base OID for first publication,
  or `present` plus exact OID for updates
- Existing-PR identity or an idempotent creation rule
- Force-push prohibition (always)
- Distinct ready / reviewer-notification flags
- Derived effects for each permitted git/forge action: workflows, deploy
  hooks, auto-merge, merge queues, bots, webhooks, labels, notifications.
  Publication is blocked while any effect is unknown or outside the envelope.

## Preflight checklist

RUN starts only after these pass or the approved plan records a safe fallback:

- [ ] Runtime availability for the selected adapter (Orca orchestration, or
      probed native primitives — see
      [platform-adapters.md](platform-adapters.md))
- [ ] Unique run ID, root task identity, repository identity, and coordinator
      lease/epoch recorded in STATE; never adopt host entities outside the
      run's recorded allowlist
- [ ] Newly created clean integration worktree, unique milestone branch,
      pinned starting commit
- [ ] Baseline repository verification passes, executed via
      `scripts/run-verification` (record the digest)
- [ ] `scripts/preflight-lint <milestone-dir>` reports zero errors; warnings
      resolved or explicitly accepted in PLAN (long gates get the
      task-contracts.md execution policy; unowned repo contract files get an
      owner; an `uncalibrated_gate` warning means SPEC froze thresholds with no
      measurement record — see the calibration rule above). The lint errors on
      `concurrent_path_overlap`: two implementation tasks with no dependency
      edge either way that own intersecting paths
- [ ] Long gates (registered timeout > ~10 min) identified, and a fast
      targeted verification command registered for every implementation task
- [ ] Every gating quantity calibrated: each frozen threshold, aggregation
      rule, and population/exclusion rule carries a recorded measurement and
      the command that produced it, with bounds pinned outside the observed
      range rather than tight against a single sample
- [ ] Inherited instruments proven able to fail: every gate script, filter,
      or preflight check cloned from a predecessor milestone is re-targeted
      to this milestone's IDs/paths and demonstrated RED on a deliberate
      seeded failure before its first acceptance use — and demonstrated to
      RUN at all in a fresh worktree, bootstrap/restore included (a field
      run's chained predecessor gate died 40 minutes in for lack of a
      dependency restore). Field runs re-discover
      self-certifying cloned instruments (filters that exclude the new
      tests, preflights keyed to stale task IDs) at final review every
      cycle; anti-vacuity at clone time is cheaper
- [ ] Dirty paths classified: unrelated (preserve), relevant milestone input
      (approved checkpoint/snapshot strategy required), or conflict (resolve
      before RUN)
- [ ] Permission mode, credentials, and secret-handling boundaries confirmed
- [ ] Available Claude and GPT routes with exact launch commands, capability
      probes, and allowed substitutions recorded, each mapped to the routing
      capability tiers in task-contracts.md
- [ ] Review-workflow discovery: compatible Codex `code-review` and/or Claude
      `/code-review` recorded for the mandatory final review
- [ ] Browser capability (Chrome DevTools / Orca embedded browser) probed when
      the plan needs it
- [ ] Publication envelope complete, effects derived, secret scanner
      identified
- [ ] Budgets set in PLAN (defaults from SKILL.md if not overridden), the
      worker-dispatch budget computed from the plan task count and recorded
      in STATE
- [ ] Execution profile recorded in PLAN with rationale; grounding digest
      written and referenced by the packet template

Then checkpoint-commit the approved `SPEC.md`, `PLAN.md`, initialized
`STATE.md`, and acceptance mapping on the integration branch using the
configured human author, record the checkpoint commit in STATE, and use it as
the first worker base. Validate with `scripts/validate-state` before the first
dispatch.

## RUN handoff block

PREPARE typically runs on a stronger model than RUN needs (see the
coordinator-tier section in platform-adapters.md). So end PREPARE by printing
a copy-pasteable handoff block, then stop — even when the same session could
continue into RUN. Format:

```text
PREPARE complete — approved artifacts committed at <checkpoint-sha>.

To run on the recommended RUN tier, start a fresh session and invoke:

  Claude Code:  claude --model opus
                /milestone-orchestrator run docs/milestones/<slug>/

  Codex:        codex --model <recorded-route>
                Use $milestone-orchestrator run docs/milestones/<slug>/

  Orca:         spawn a coordinator terminal on the recorded RUN route,
                then: run docs/milestones/<slug>/

`run` resumes from the approved artifacts; nothing from this session is
needed. To continue here instead (this session's model: <model>), say
"continue into RUN" — fine when this model already matches the RUN tier.
```

The cheaper session must still be a milestone-orchestrator `run` operating
the STATE ledger — handing the approved packet to an ad hoc implementation
thread saves the same model cost but forfeits supervision, acceptance gates,
and the audit trail (a field run did this and its RUN is simply invisible).

Substitute the real slug, checkpoint SHA, session model, and the RUN routes
recorded at preflight; drop host lines that don't apply to this environment.
A bare invocation that was approved to continue in-session prints the block
first anyway, so the user can choose the cheaper path at the moment it
matters.
