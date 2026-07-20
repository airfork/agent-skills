# Prompt Engineer Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, qualify, and prepare a safe cutover for a lean repository-owned `prompt-engineer` skill without changing the currently installed global skill before a separately approved cutover.

**Architecture:** A four-file runtime skill teaches an adaptive, evidence-backed prompt-improvement workflow. Repository-owned Ruby 2.6-compatible tools separately prepare and ingest host runs, enforce qualification contracts, launch isolated host sessions, score masked evidence, and perform journaled cutover operations. Candidate metadata remains disabled until qualification and explicit user approval.

**Tech Stack:** Markdown and YAML skill assets, Ruby 2.6-compatible standard library, Minitest, Psych/YAML, canonical JSON, POSIX descriptor-relative filesystem operations through `Fiddle`, Codex and Claude native event exports, macOS Seatbelt capability probes, and existing repository verification scripts.

---

## Source Documents And Authority

Implement against these documents in descending order:

1. `docs/plans/2026-07-19-prompt-engineer-replacement-design.md`
2. `docs/plans/2026-07-19-prompt-engineer-replacement-design-verification.md`
3. This implementation plan after its adversarial review is resolved.
4. Repository instructions in `AGENTS.md`, `docs/repo-guidelines.md`, and `COMMANDS.md`.

The implementation plan refines three internal placements without changing the
approved behavior:

- Production canonicalization, validation, scoring, journal, and filesystem
  code lives under `scripts/lib/prompt_engineer/`. `test/support/` contains only
  fixture builders and test utilities.
- Provider normalizers also live under
  `scripts/lib/prompt_engineer/normalizers/`; the legacy companion module is a
  pinned evaluation input and backup target, never replacement production code.
- The approved `.yml` executor and judge contracts remain YAML. A small closed
  validator accepts only the declared vocabulary, parses through a duplicate-key
  and alias-rejecting Psych AST pass, and rejects unknown properties.
- The first live sandbox and cutover implementation supports macOS/POSIX only.
  Unsupported platforms fail closed; portability is a later design decision.

## Implementation Constraints

- Create an isolated worktree under `.worktrees/prompt-engineer-replacement`
  before implementation. Do not edit or clean unrelated work in the main
  checkout.
- Use `rtk` for every agent-run shell command.
- Follow RED/GREEN/REFACTOR at behavior granularity. Add one failing assertion,
  run it and record the expected failure, add the smallest implementation, then
  rerun the focused test before broadening the change.
- Before creating `skills/general/prompt-engineer/SKILL.md`, run the baseline
  pressure scenarios in fresh sessions without the replacement and record the
  exact observed failure patterns. Do not write the skill from intuition alone.
- Run the installed `skill-creator` scaffolder for the new skill. Generate
  `agents/openai.yaml` deterministically, then add and test the required policy
  field that the generator does not emit.
- Do not copy the legacy skill, its academic technique census, or its workflow
  framework into the replacement. The locked legacy tree is an evaluation arm,
  not source material for the runtime package.
- Keep the runtime package to the four approved files. Evaluation, sandbox, and
  cutover code stays at repository root and is not installed with the skill.
- Keep Ruby compatible with 2.6.10. Avoid pattern matching, numbered block
  parameters, `filter_map`, and later-only standard-library APIs.
- Unit and integration tests use fake host executables, sanitized native-export
  fixtures, temporary homes, and temporary repositories. They must not call real
  model providers or mutate live installed skills.
- Treat corpus files, host exports, model output, paths, and cutover state as
  untrusted. Use argv arrays, fixed environments, bounded reads, closed records,
  canonical bytes, no-follow descriptor-relative operations, locks, and durable
  parent-directory syncs.
- Help text establishes candidate syntax only. A live host is qualification-
  capable only after machine-readable probes demonstrate fresh-session evidence,
  package/invocation provenance, sandbox boundaries, provider-only transport,
  parent-only authentication, and a non-inherited result sink.
- Require an operator-supplied `PROMPT_ENGINEER_MAX_USD` before any live model
  run. Enforce both the eight-hour operator ceiling and the monetary ceiling.
- Never run `scripts/sync-skills --apply`, use `--force`, mutate `~/.agents`,
  mutate `~/.codex`, or invoke live cutover during repository implementation or
  qualification.
- Commit with the configured human author and no AI attribution.

## Release Gates

The work has four separate terminal states:

1. **Core ready:** package, corpus, host-neutral evaluator, fixtures, and fake-
   adapter contracts pass. Live host evidence may still be unavailable.
2. **Repository complete:** both real native normalizers, both sandbox adapters,
   the cutover primitive, all tests, and static verification pass. An unavailable
   live host blocks this state even when the core is ready.
3. **Qualification complete:** the immutable evaluation report says
   `QUALIFIED_EXPLICIT`, `QUALIFIED_IMPLICIT`, `NOT_QUALIFIED`, or
   `INCONCLUSIVE` and reproduces all scores and budgets.
4. **Cutover complete:** only after a new explicit user approval, the dedicated
   cutover transaction replaces the live legacy paths and verifies fresh-host
   discovery. This plan stops before that state.

Capability gates are component-specific. A failed host-export or authentication
probe still permits the baseline record, lean runtime skill, corpus, canonical
core, and host-neutral evaluation state machine, but blocks that host's native
normalizer, live sandbox adapter, and qualification. A failed descriptor-relative
filesystem probe blocks the cutover engine. Record every blocked component and
do not substitute synthetic fixtures for native evidence or weaken a boundary to
obtain a passing run.

## File Map

Create the runtime package:

- `skills/general/prompt-engineer/SKILL.md`
- `skills/general/prompt-engineer/agents/openai.yaml`
- `skills/general/prompt-engineer/references/evaluation.md`
- `skills/general/prompt-engineer/references/prompt-contexts.md`

Create repository tooling:

- `scripts/prompt-engineer-eval`
- `scripts/prompt-engineer-sandbox`
- `scripts/prompt-engineer-cutover`
- `scripts/lib/prompt_engineer.rb`
- `scripts/lib/prompt_engineer/canonical.rb`
- `scripts/lib/prompt_engineer/contracts.rb`
- `scripts/lib/prompt_engineer/corpus.rb`
- `scripts/lib/prompt_engineer/budget.rb`
- `scripts/lib/prompt_engineer/run_store.rb`
- `scripts/lib/prompt_engineer/provenance.rb`
- `scripts/lib/prompt_engineer/policy.rb`
- `scripts/lib/prompt_engineer/normalizers/codex.rb`
- `scripts/lib/prompt_engineer/normalizers/claude.rb`
- `scripts/lib/prompt_engineer/scoring.rb`
- `scripts/lib/prompt_engineer/reporting.rb`
- `scripts/lib/prompt_engineer/sandbox.rb`
- `scripts/lib/prompt_engineer/sandbox/darwin.rb`
- `scripts/lib/prompt_engineer/secure_fs.rb`
- `scripts/lib/prompt_engineer/journal.rb`
- `scripts/lib/prompt_engineer/cutover.rb`
- `scripts/lib/prompt_engineer/cli.rb`

Create tests and fixtures:

- `test/prompt_engineer_skill_contract_test.rb`
- `test/prompt_engineer_evaluation_contract_test.rb`
- `test/prompt_engineer_sandbox_test.rb`
- `test/prompt_engineer_cutover_test.rb`
- `test/support/prompt_engineer_helper.rb`
- `test/fixtures/prompt-engineer/v1/triggers.yml`
- `test/fixtures/prompt-engineer/v1/manifest.yml`
- `test/fixtures/prompt-engineer/v1/cases/PE-001/public.yml`
- `test/fixtures/prompt-engineer/v1/cases/PE-001/private.yml`
- `test/fixtures/prompt-engineer/v1/cases/PE-001/artifacts/**`
- `test/fixtures/prompt-engineer/v1/cases/PE-002..PE-012/**` with the same shape
- `test/fixtures/prompt-engineer/legacy.lock.yml`
- `test/fixtures/prompt-engineer/qualification-policy.example.yml`
- `test/fixtures/prompt-engineer/schemas/executor-result-v1.yml`
- `test/fixtures/prompt-engineer/schemas/judge-result-v1.yml`
- `test/fixtures/prompt-engineer/schemas/qualification-policy-v1.yml`
- `test/fixtures/prompt-engineer/schemas/discovery-inventory-v1.yml`
- `test/fixtures/prompt-engineer/schemas/operator-choices-v1.yml`
- `test/fixtures/prompt-engineer/schemas/discovery-roots-v1.yml`
- `test/fixtures/prompt-engineer/v1/exports/codex/*.jsonl`
- `test/fixtures/prompt-engineer/v1/exports/claude/*.jsonl`

Use the committed plan-verification record and create run evidence during execution:

- `docs/plans/2026-07-19-prompt-engineer-replacement-capability-probe.md`
- `docs/plans/2026-07-19-prompt-engineer-replacement-baseline.md`
- `docs/plans/2026-07-19-prompt-engineer-replacement-evaluation.md`
- Existing: `docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan-verification.md`

Modify:

- `skills.yaml`
- `CATALOG.md`
- `USAGE.md`
- `COMMANDS.md`
- `scripts/verify`

## Dependency Order

| Phase | Depends on | May proceed when live isolation is unavailable |
|---|---|---|
| Capability and provenance probe | approved design | yes; it records component gates |
| Baseline pressure tests | capability record and locked legacy source | yes, for locally supportable arms |
| Runtime skill and static contracts | observed baseline failures | yes |
| Corpus and deterministic core | approved design | yes |
| Host normalization and evaluation CLI | deterministic core and proven native exports | host-neutral CLI yes; blocked host normalizer no |
| Sandbox wrapper | proven native export, auth, and isolation probes | contract code yes; blocked host adapter no |
| Cutover transaction engine | deterministic core and passed secure filesystem probe | no when primitive fails |
| Forward tests | runtime skill and fake adapters | yes |
| Live qualification | every earlier repository gate and explicit budget | no |
| Live cutover | qualified report and separate user approval | no |

## Task 1: Create The Isolated Worktree And Freeze Capability Evidence

**Files:**

- Create: `.worktrees/prompt-engineer-replacement/`
- Create: `docs/plans/2026-07-19-prompt-engineer-replacement-capability-probe.md`
- Create outside the repository: `task0/{environment,legacy-snapshot,filesystem-capabilities,decision}.json`
- Create outside the repository: `task0/{codex,claude}/{raw-unassisted,raw-explicit}.jsonl`
- Create outside the repository: `task0/{codex,claude}/{export-capabilities,sandbox-probes}.json`

- [ ] **Step 1: Confirm the source checkout and create isolation**

Run from the main checkout:

```bash
rtk git status --short
rtk git diff --quiet HEAD -- docs/plans/2026-07-19-prompt-engineer-replacement-design.md docs/plans/2026-07-19-prompt-engineer-replacement-design-verification.md docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan.md docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan-review.md docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan-verification.md
rtk git diff --cached --quiet HEAD -- docs/plans/2026-07-19-prompt-engineer-replacement-design.md docs/plans/2026-07-19-prompt-engineer-replacement-design-verification.md docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan.md docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan-review.md docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan-verification.md
rtk sha256sum docs/plans/2026-07-19-prompt-engineer-replacement-design.md docs/plans/2026-07-19-prompt-engineer-replacement-design-verification.md docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan.md docs/plans/2026-07-19-prompt-engineer-replacement-implementation-plan-review.md
rtk git check-ignore -q .worktrees
rtk git worktree add .worktrees/prompt-engineer-replacement -b feature/prompt-engineer-replacement HEAD
```

Expected: status is empty; both diff checks succeed; the four printed digests
equal the committed implementation-plan verification record; the ignore check
succeeds; and the new branch starts at that reviewed-plan commit. Any mismatch
stops before worktree creation. Run all later implementation commands there.

- [ ] **Step 2: Validate the pinned legacy source instead of trusting the installed copy**

Require the operator to set `PROMPT_ENGINEER_LEGACY_ROOT` to a local checkout of
`solatis/claude-config`. Resolve its Git root and verify remote identity and full
commit `e16d537c594b0f29a368726aa11bb4e5d704938f`. Read exact blobs from the Git
object, not a dirty worktree. Freeze blob mode, Git object ID, and SHA-256 for the
complete legacy skill, `skills/scripts/skills/prompt_engineer`, and the transitive
imports it uses beneath `skills/scripts/skills/lib`. Run the locked Python
workflow from an extracted temporary tree and prove its working-directory
instruction works in both staged host layouts without changing snapshot bytes.
Inventory every live discovery path, including distinct `.agents` and `.claude`
variants. If closure, execution, or discovery is incomplete, block the legacy arm
and do not substitute an unpinned installed tree.

- [ ] **Step 3: Probe host-native evidence surfaces**

Record sanitized versions and machine-readable help probes for:

```bash
rtk codex exec --help
rtk claude --help
rtk /usr/bin/sandbox-exec -h
rtk ruby -v
```

Help proves syntax only. Create a temporary sentinel skill whose explicit action
is returning a nonce. With a positive `PROMPT_ENGINEER_MAX_USD`, run one fresh
unassisted and one fresh explicit session per host using the exact intended
qualification flags. Before launching Claude, prove an authentication route
compatible with `--bare`; never silently fall back to keychain-backed non-bare
mode. If a live probe is not authorized or authentication is unavailable, mark
native evidence unproven and block that host-specific implementation.

For each host, `export-capabilities.json` binds CLI version, executable digest,
raw-export digest, and exact event pointers for session ID, new-session marker,
absence of resume parent, model, effort, tool inventory, activation event,
activation path, visible-message completeness, and usage. A missing freshness or
activation/path pointer fails the host gate; prose in the final answer is not
activation evidence.

- [ ] **Step 4: Run fail-fast boundary spikes**

Using a fake host process, prove the proposed Darwin profile can:

- read only staged runtime roots and declared immutable inputs;
- write only the case worktree, output, and scratch roots;
- deny source-repository, private-rubric, credential, keychain, and result-sink
  reads;
- deny undeclared and non-provider network access;
- keep parent authentication and result descriptors out of a spawned tool
  subprocess; and
- rehash frozen files after exit.

The provider-only transport and parent-only authentication probes may be
`UNPROVEN` without a live authorized run. An unproven item sets that host's
`qualification_capable=false`; it is not converted to pass by documentation.
Also prove cross-directory `renameat`, `symlinkat` creation, `readlinkat`
verification, `unlinkat` rollback, same-device enforcement, explicit `EXDEV`
refusal, parent identity anchoring, and file/directory `fsync` on temporary same-
volume roots. Interruption reconciliation and repeated rollback are Task 11
deliverables. If Ruby 2.6 plus libc cannot support a required primitive, block
the cutover engine pending a separately designed audited helper or manual
procedure.

- [ ] **Step 5: Write the sanitized capability record**

The record includes exact command lines, tool versions, supported flags,
pass/fail/unproven results, platform scope, external evidence digests, and one
component decision for legacy snapshot, Codex native export, Claude native
export, each sandbox/auth boundary, and filesystem primitives. Its terminal
decision is `PROCEED`, `PARTIAL`, `REVISE_DESIGN`, or `BLOCKED`, with exact
artifact and JSON-pointer evidence. Include no credentials, home-session data,
or raw private output.

Move the complete sanitized Task 1 tree into an immutable external evidence root
whose parent is not a disposable temporary directory. Write a canonical manifest
with every file digest, mode, size, origin, fixture-derivation link, and retention
deadline through cutover plus the five-use observation window. Mark files read-
only. Every later component gate reopens and rehashes required bytes; an absent
file blocks the dependent component even when its digest remains in Markdown.

- [ ] **Step 6: Commit the probe separately**

```bash
rtk git add docs/plans/2026-07-19-prompt-engineer-replacement-capability-probe.md
rtk git commit -m "docs: record prompt engineer capability probe"
```

## Task 2: Establish The RED Baseline Before Writing The Skill

**Files:**

- Create: `docs/plans/2026-07-19-prompt-engineer-replacement-baseline.md`
- Create: temporary external pressure-test packets; do not commit raw sessions

- [ ] **Step 1: Freeze three pressure scenarios**

Create synthetic scenarios for:

1. a single prompt whose apparent wording problem is actually missing runtime
   context;
2. a prompt-bearing skill where trigger scope and workflow behavior both need
   diagnosis; and
3. a multi-prompt handoff where local edits improve one stage but break the
   ecosystem contract.

Each scenario defines input, permitted context, observable success criteria,
safety boundaries, and a private failure checklist. Do not state the desired
workflow in the executor-visible prompt.

- [ ] **Step 2: Run fresh unassisted baselines**

Run each scenario in a fresh Codex and Claude context without the candidate and
without exposing private checklists. If live provider execution is blocked by
Task 1, record that host baseline as unmeasured and do not substitute a local
subagent: a context without host-native discovery and isolated-home attestation
cannot prove the installed legacy skill was absent.

Expected RED signals include at least one of: rewriting before diagnosis,
claiming improvement without comparison, optimizing wording when code/config is
causal, leaking a local change across ecosystem boundaries, or applying a
technique taxonomy without behavioral evidence.

- [ ] **Step 3: Run the locked legacy arm where available**

Expose only the pinned legacy package in a disposable home. Record whether it
avoids the unassisted failure and whether it exhibits the design-identified
costs: mandatory census, broad generalization, structural-edit prohibition,
external workflow dependence, or unsupported improvement claims.

- [ ] **Step 4: Write a sanitized evidence record**

Record scenario digests, fresh-session identifiers, package provenance,
observed failures, useful legacy behaviors, and exact requirements the
replacement must teach. Store only excerpts needed to identify behavior; raw
sessions remain outside the repository with digests.

- [ ] **Step 5: Commit the baseline before adding `SKILL.md`**

```bash
rtk test ! -e skills/general/prompt-engineer/SKILL.md
rtk git add docs/plans/2026-07-19-prompt-engineer-replacement-baseline.md
rtk git commit -m "test: capture prompt engineering baseline failures"
```

Expected: the file absence check passes and the baseline commit precedes any
candidate skill bytes in history.

## Task 3: Scaffold The Lean Runtime Skill Through Contract Tests

**Files:**

- Create: `test/prompt_engineer_skill_contract_test.rb`
- Create: the four runtime-package files listed in the file map

- [ ] **Step 1: Write the package contract and observe RED**

Assert:

- the package contains exactly the four approved files;
- frontmatter has only `name` and a precise `description`;
- the description covers creating, improving, simplifying, diagnosing, and
  comparing prompts plus prompt-bearing skills, handoffs, ecosystems, and
  evaluations;
- the description excludes ordinary prose edits and failures already traced to
  code, runtime, configuration, tools, data, permissions, or external systems;
- `SKILL.md` routes to each reference and has at most 250 nonblank lines; each
  reference has at most 300 nonblank lines;
- no mandatory named-technique census, false authority, unverifiable percentage,
  structural-edit ban, or external workflow dependency appears;
- `agents/openai.yaml` has quoted interface strings, the exact explicit default
  prompt containing `$prompt-engineer`, and
  `policy.allow_implicit_invocation: false`; and
- no evaluation or mutable state is stored inside the runtime package.

Run:

```bash
rtk ruby -Itest test/prompt_engineer_skill_contract_test.rb
```

Expected: RED because the package does not exist.

- [ ] **Step 2: Scaffold with the installed skill creator**

```bash
rtk python3 /Users/tunji/.codex/skills/.system/skill-creator/scripts/init_skill.py prompt-engineer \
  --path skills/general \
  --resources references \
  --interface 'display_name=Prompt Engineer' \
  --interface 'short_description=Diagnose and improve prompts with evidence' \
  --interface 'default_prompt=Use $prompt-engineer to diagnose and improve this prompt with the lightest evidence-backed evaluation that can support the requested claim.'
```

Delete only scaffolder-created example resources that are outside the approved
four-file layout. Preserve the generated directory and metadata as the starting
point.

- [ ] **Step 3: Add the smallest workflow that addresses baseline failures**

`SKILL.md` must route the agent through: establish target and authority,
diagnose prompt versus non-prompt cause, define observable success and baseline,
select Quick/Standard/Ecosystem evidence, create the smallest candidate, compare
in fresh contexts, score, and present or apply only within authority.

`references/evaluation.md` defines profiles, fresh-context comparison, scoring,
claim strength, regression handling, and when `INCONCLUSIVE` is required.
`references/prompt-contexts.md` defines single prompts, prompt-bearing skills,
subagent handoffs, and multi-prompt ecosystems plus non-prompt exit routing.

- [ ] **Step 4: Generate and close the OpenAI metadata**

Run the deterministic generator:

```bash
rtk python3 /Users/tunji/.codex/skills/.system/skill-creator/scripts/generate_openai_yaml.py \
  skills/general/prompt-engineer \
  --interface 'display_name=Prompt Engineer' \
  --interface 'short_description=Diagnose and improve prompts with evidence' \
  --interface 'default_prompt=Use $prompt-engineer to diagnose and improve this prompt with the lightest evidence-backed evaluation that can support the requested claim.'
```

Then add:

```yaml
policy:
  allow_implicit_invocation: false
```

Rerun the package contract. Expected: GREEN.

- [ ] **Step 5: Run the installed package validator**

```bash
rtk uv run --with pyyaml python /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/general/prompt-engineer
```

Expected: `Skill is valid!`

- [ ] **Step 6: Forward-test and refactor without expanding scope**

Repeat the three Task 2 scenarios in fresh contexts with the candidate explicitly
available. Compare against the baseline record. If a failure persists, add one
failing contract or pressure test for that observed loophole before changing the
skill. Rerun all three scenarios after each behavioral edit.

- [ ] **Step 7: Commit the runtime package**

```bash
rtk git add skills/general/prompt-engineer test/prompt_engineer_skill_contract_test.rb
rtk git commit -m "feat: add candidate prompt engineer skill"
```

## Task 4: Register A Disabled Candidate And Document The Operator Surface

**Files:**

- Modify: `skills.yaml`
- Modify: `CATALOG.md`
- Modify: `USAGE.md`
- Modify: `COMMANDS.md`
- Modify: `test/prompt_engineer_skill_contract_test.rb`

- [ ] **Step 1: Add failing cross-document assertions**

Assert the manifest entry has category `general`, status `candidate`, interfaces
`codex` and `claude`, model tiers `standard` and `deep`, and explicit disabled
flags for Codex, Claude, Cursor, and Gemini. Assert Catalog and Usage agree and
that ordinary sync cannot select the candidate. Run the focused test and observe
RED.

- [ ] **Step 2: Add candidate metadata and documentation**

Document explicit `$prompt-engineer` use, Quick/Standard/Ecosystem profiles,
qualification commands, monetary/operator budgets, disabled-install policy,
separate cutover approval, stable-checkout requirement, activation-commit order,
rollback command, post-cutover use-record fields, five-use-per-host retention
gate, and the fact that backup deletion requires a later explicit cleanup
request. `COMMANDS.md` documents the three checked-in CLIs as they become
available; it never tells operators to add `rtk`.

- [ ] **Step 3: Prove disabled flags are the real safety gate**

```bash
rtk scripts/sync-skills --target codex --dry-run
rtk scripts/sync-skills --target claude --dry-run
```

Expected: neither output contains an install, replace, or remove operation for
`prompt-engineer`.

- [ ] **Step 4: Commit candidate registration**

```bash
rtk git add skills.yaml CATALOG.md USAGE.md COMMANDS.md test/prompt_engineer_skill_contract_test.rb
rtk git commit -m "docs: register disabled prompt engineer candidate"
```

## Task 5: Freeze The Qualification Corpus And Closed Contracts

**Files:**

- Create: `test/fixtures/prompt-engineer/v1/**`
- Create: `test/prompt_engineer_evaluation_contract_test.rb`
- Create: `test/support/prompt_engineer_helper.rb`
- Create: `scripts/lib/prompt_engineer.rb`
- Create: `scripts/lib/prompt_engineer/{canonical,contracts,corpus,budget}.rb`

- [ ] **Step 1: Add load and closed-YAML RED tests**

Test public library loading, safe YAML parsing, duplicate key rejection, alias
rejection, unknown property rejection, required fields, enum and numeric bounds,
UTF-8 canonical JSON, sorted keys, and exactly one trailing LF. Run:

```bash
rtk ruby -Itest test/prompt_engineer_evaluation_contract_test.rb
```

Expected: RED with `LoadError` before the library entry point exists; after the
entry point, each added contract behavior fails for its own reason before its
implementation is written.

- [ ] **Step 2: Implement the dependency-free contract subset**

Parse YAML through Psych nodes first to reject aliases, merges, duplicate scalar
keys, non-string mapping keys, and unsupported tags. Validate only the fixed
keywords required by the two committed contracts: object, array, string,
integer, number, boolean, null, required fields, closed properties, enum, const,
pattern, minimum/maximum, and min/max lengths/items. Refuse an unknown schema
keyword rather than ignoring it.

- [ ] **Step 3: Freeze the twelve-case corpus in the approved tree**

Encode the approved case matrix with stable IDs, public packet, private rubric,
profile, primary dimension, host coverage, declared worktree inputs, and safety
classification. Use `v1/manifest.yml` plus one
`cases/PE-NNN/{public.yml,private.yml,artifacts/}` tree for each case. Validate
exactly `PE-001` through `PE-012`, the frozen efficiency IDs, the exact public
and private field contracts, relative artifact containment, and the approved
bytewise tree-digest algorithm. Store private rubrics outside every executor-
export allowlist. Do not invent a category-count requirement absent from the
design.

- [ ] **Step 4: Freeze the trigger suite and activation pair**

Encode eight positive and eight negative triggers. The explicit and implicit
activation candidates must differ in exactly the single approved metadata field.
Test 16 explicit, 16 Codex implicit, and 8 Claude negative trigger trials for a
total trigger budget of 40.

- [ ] **Step 5: Freeze the pinned legacy lock**

`test/fixtures/prompt-engineer/legacy.lock.yml` records repository, full commit,
Git object IDs, modes, exact Git-root-relative legacy/companion paths, transitive
dependency closure, sorted file digests, and aggregate digest. It is outside
`v1/` so it does not alter the corpus tree digest. Test missing files, extra
files, digest mismatch, path escape, incomplete imports, and use of an installed-
but-unpinned tree.

- [ ] **Step 6: Encode budget arithmetic**

Test the fixed budgets:

- behavioral executor runs: 96 = 72 initial + 18 stability + 6 targeted;
- trigger runs: 40 = 16 explicit + 16 Codex implicit + 8 Claude negative;
- judge runs: at most 64 = up to 32 initial judges plus up to 32 conditional
  second judges;
- operator time: at most eight hours; and
- money: positive operator-supplied ceiling with no default.

Freeze a positive user-supplied price table for each exact model, provider token
caps, session timeout, and the monetary ceiling. Reject unknown prices. A single
locked run ledger reserves one session, the full timeout, and pessimistic maximum
cost before a launch packet is emitted, then settles native usage at ingest.
Concurrent claims cannot borrow or oversubscribe. Crashed or expired leases stay
charged until closed with evidence. Test reservation, settlement, retries,
concurrent claims, missing usage, expiry, crash recovery, and refusal before any
ceiling can be exceeded.

The closed `qualification-policy-v1.yml` schema requires source capability-
evidence digests, executable realpath/hash, host argv template, model/effort,
tool/runtime/write/environment allowlists, endpoint policy, timeout and token
caps, and a complete pricing-authority record. That record includes provider,
source artifact digest, currency, effective interval, every input/output/cache/
reasoning billing dimension, minimum and failed-request charges, and provider-
side project spending-cap evidence. Allocated provider caps must sum to no more
than `PROMPT_ENGINEER_MAX_USD`; without provider-enforced cap evidence, live
qualification is blocked rather than described as a hard monetary ceiling.

The closed `operator-choices-v1.yml` schema contains only the choices that
cannot be inferred from evidence: exact Codex and Claude model/effort, per-host
timeout, user monetary ceiling, and provider-cap partition. The deterministic
`prompt-engineer-eval choices` command is its sole producer and canonicalizes
values supplied through explicit flags; it refuses overwrite, unknown currency,
nonpositive caps, or partitions whose sum exceeds the user ceiling.

The closed `discovery-inventory-v1.yml` schema requires scan time, host and root
IDs, every discovery root and legacy variant, dedicated versus shared path
classification, type/owner/mode/device/inode/hash, companion dependency map,
source capability-evidence digest, and aggregate digest. Test omitted variants,
duplicate aliases, shared-path mutation, stale parent identity, path escape,
symlink substitution, and post-preview drift.

The closed `discovery-roots-v1.yml` schema lists an ordered, nonempty set of
`host`, absolute `path`, expected owner, and expected directory device/inode
records. A deterministic roots builder accepts repeatable explicit
`--host-root HOST=PATH` flags, opens each root without following symlinks, records
identity, and refuses overwrite. Preview accepts only this canonical roots file;
it never infers scope from ambient homes or host configuration.

- [ ] **Step 7: Commit corpus and contracts**

```bash
rtk ruby -Itest test/prompt_engineer_evaluation_contract_test.rb
rtk git add test/fixtures/prompt-engineer test/support/prompt_engineer_helper.rb \
  test/prompt_engineer_evaluation_contract_test.rb scripts/lib/prompt_engineer.rb \
  scripts/lib/prompt_engineer
rtk git commit -m "test: freeze prompt engineer qualification contracts"
```

## Task 6: Build Immutable Run Preparation And Provenance Ingestion

**Files:**

- Create: `scripts/lib/prompt_engineer/{run_store,provenance}.rb`
- Modify: `scripts/lib/prompt_engineer.rb`
- Modify: `test/prompt_engineer_evaluation_contract_test.rb`

- [ ] **Step 1: Test immutable preparation one behavior at a time**

Add failing tests for run ID generation, frozen manifest creation, corpus and
package digests, opaque arm labels, isolated home paths, public/private export
separation, output/scratch roots, legacy-lock verification, environment
allowlist, file modes, exclusive creation, and rerun refusal.

- [ ] **Step 2: Implement the run store**

Prepare a new external run root with immutable `manifest.json`, the authenticated
qualification-policy digest, public executor packets, private judge inputs, per-
arm isolated homes, output/scratch paths, a deterministic base DAG, and frozen
content-addressed expansion rules. The base DAG contains initial, mandatory-
stability, and trigger work but not outcome-dependent targeted repeats or second
judges. One locked append-only run ledger is the authority for deterministic
derived-node creation, queue claims, reservations, settlements, ingestion, close
reasons, and terminal state; derived status files are caches only. A rule appends
one stable node ID from the rule ID plus bound evidence digests, is idempotent on
replay, and records unused reserve as closed when its predicate is false. Use
complete temporary files, file `fsync`, atomic rename, and parent-directory
`fsync`.

- [ ] **Step 3: Test executor record binding**

Reject records unless they bind run/case/host/arm IDs, nonce, fresh session ID,
native export digest, launch-attestation digest, exact package digest, discovery
evidence, invocation evidence, frozen-input rehashes, exit status, timing, and
declared output digests. Reject duplicate nonces and records after budget close.
Add state-machine tests for pending, leased, launched, ingested, expired,
settled, stopped, and unresolved-to-`INCONCLUSIVE` transitions, including
process contention and recovery after each durable event. Add deterministic
tests for conditional repeat/second-judge insertion, stable IDs, false-predicate
closure, duplicate evidence replay, and crash recovery before and after derived-
node append.

- [ ] **Step 4: Add canonical append-only ingestion**

Ingestion copies bounded validated records into the run store by digest. It does
not modify the source export and never accepts a pathname supplied inside a
record as an authority for reads.

- [ ] **Step 5: Commit the run store**

```bash
rtk ruby -Itest test/prompt_engineer_evaluation_contract_test.rb
rtk git add scripts/lib/prompt_engineer test/prompt_engineer_evaluation_contract_test.rb
rtk git commit -m "feat: add immutable prompt engineer run store"
```

## Task 7: Normalize Codex And Claude Native Exports

**Files:**

- Create: `scripts/lib/prompt_engineer/normalizers/{codex,claude}.rb`
- Create: sanitized export fixtures under `test/fixtures/prompt-engineer/v1/exports/`
- Modify: `scripts/lib/prompt_engineer.rb`
- Modify: `test/prompt_engineer_evaluation_contract_test.rb`

**Entry gate:** Implement a host normalizer only when Task 1 captured and hashed
a real native export with every required freshness and activation pointer. If a
host fails this gate, leave its adapter absent, make CLI capability reporting say
unsupported, and open a design revision before claiming repository completion.

- [ ] **Step 1: Add sanitized native-export fixtures**

Capture or synthesize version-labelled streams containing startup/configuration,
skill discovery, invocation, tool policy, session identity, final output, usage,
and exit events. Remove private content while preserving event shape. Include
negative fixtures for missing freshness, wrong package digest, absent invocation,
truncation, duplicated terminal events, and unknown event versions.

- [ ] **Step 2: Observe RED for each host normalizer**

Test that each normalizer produces the same closed executor record and refuses
every negative fixture. Unknown provider fields may be retained only beneath a
bounded diagnostic envelope excluded from scoring; unknown event versions fail
closed.

- [ ] **Step 3: Implement host-specific normalizers**

Normalizers consume bytes plus parent-supplied launch facts. They do not launch
hosts, read user homes, infer invocation from answer prose, or trust model claims
about loaded skills. Provenance requires host-native evidence bound to the
wrapper nonce and session.

- [ ] **Step 4: Test post-run drift and replay resistance**

Reject changed staged package bytes, changed immutable inputs, reused exports,
wrong nonces, mismatched sessions, stale timestamps, and copied discovery events
from another run.

- [ ] **Step 5: Commit normalization**

```bash
rtk ruby -Itest test/prompt_engineer_evaluation_contract_test.rb
rtk git add scripts/lib/prompt_engineer test/fixtures/prompt-engineer/v1/exports \
  test/prompt_engineer_evaluation_contract_test.rb
rtk git commit -m "feat: normalize prompt engineer host evidence"
```

## Task 8: Implement Masked Judging, Scoring, And Reporting

**Files:**

- Create: `scripts/lib/prompt_engineer/{scoring,reporting}.rb`
- Modify: `scripts/lib/prompt_engineer.rb`
- Modify: `test/prompt_engineer_evaluation_contract_test.rb`

- [ ] **Step 1: Test deterministic masking**

Given complete executor records, create judge packets with opaque arm labels,
normalized outputs, private rubric points, citations, and digests. Prove packets
contain no package name, arm path, source path, rubric leak into executor data,
or unstable map ordering.

- [ ] **Step 2: Test point-level judge ingestion**

Require every declared rubric point to receive pass/fail/uncertain, integer
weight, output citation where required, and evidence. Reject undeclared points,
duplicate losses, arithmetic mismatch, missing citations, arm guesses, and
records not bound to the masked packet digest.

- [ ] **Step 3: Implement score and repeat rules**

Each dimension score is maximum minus unique failed-point weights, bounded at
zero. Every packet receives one judge; only a packet within one point receives a
second, and then uses the lower reconciled score. Mark uncertainty or an
unreconcilable result `INCONCLUSIVE`. Implement the approved near-boundary
stability and targeted-repeat selection exactly and prove the 18- and 6-run
caps.

- [ ] **Step 4: Implement release decisions**

Apply every approved aggregate, per-dimension, safety, activation, host-coverage,
and zero-tolerance gate. Never average away a zero-tolerance failure or pool
incomparable host runs. Emit only the four approved decisions.

- [ ] **Step 5: Render a reproducible report**

The Markdown report includes environment, tool/model versions, corpus and
package digests, legacy lock, run locations, arm provenance, sandbox
attestations, all budgets, exclusions, point scores, judge disagreement,
repeats, trigger results, zero-tolerance results, and final decision. Recompute
every total from immutable records during render.

- [ ] **Step 6: Commit scoring and reporting**

```bash
rtk ruby -Itest test/prompt_engineer_evaluation_contract_test.rb
rtk git add scripts/lib/prompt_engineer test/prompt_engineer_evaluation_contract_test.rb
rtk git commit -m "feat: score prompt engineer qualification evidence"
```

## Task 9: Expose The Deterministic Evaluation CLI

**Files:**

- Create: `scripts/prompt-engineer-eval`
- Create: `scripts/lib/prompt_engineer/cli.rb`
- Modify: `scripts/lib/prompt_engineer.rb`
- Modify: `COMMANDS.md`
- Modify: `test/prompt_engineer_evaluation_contract_test.rb`

- [ ] **Step 1: Add CLI RED tests**

Use argv arrays and captured IO to test stable JSON stdout, JSON error stderr,
and exit statuses for:

```text
prompt-engineer-eval choices
prompt-engineer-eval policy
prompt-engineer-eval prepare
prompt-engineer-eval next
prompt-engineer-eval ingest
prompt-engineer-eval judge-packet
prompt-engineer-eval judge-ingest
prompt-engineer-eval score
prompt-engineer-eval status
prompt-engineer-eval close
prompt-engineer-eval report
```

Test missing options, unknown subcommands, invalid roots, closed runs, budget
exhaustion, schema failure, and an end-to-end fake run.

- [ ] **Step 2: Implement a thin executable and explicit dispatch**

`choices --codex-model ID --codex-effort LEVEL --claude-model ID
--claude-effort LEVEL --codex-timeout SECONDS --claude-timeout SECONDS
--max-usd DECIMAL --codex-cap-usd DECIMAL --claude-cap-usd DECIMAL --output
PATH` validates and writes the canonical closed operator-choices record and
refuses overwrite.

`policy --capability-evidence PATH --operator-choices PATH --output PATH` is the
only qualification-policy builder. It validates the closed schema, rehashes the
immutable evidence root, normalizes explicit choices, verifies executable and
provider-pricing/spending-cap provenance, emits canonical bytes, and refuses to
overwrite. Direct hand-authored policy files are rejected unless their digest
was produced and recorded by this command.

`prepare` requires corpus, candidate root, pinned legacy root, run directory,
budget ceiling, and a closed qualification-policy file containing executable
realpaths/hashes, argv templates, models/efforts, tool/runtime/write/environment
allowlists, endpoint policy, timeouts, provider token caps, complete billing
semantics, provider-side cap evidence, and capability-probe digests. It creates
the immutable base DAG and expansion rules but emits no launch.
`next --run-dir PATH --kind executor|judge` atomically reserves budget, leases,
and emits one sealed launch packet; it is the only queue-advance operation.
`status` is read-only and reports resumable work and charged reservations.
`close --reason REASON --evidence PATH` durably prohibits new claims and makes
unresolved work reportable as `INCONCLUSIVE`. `ingest` and `judge-ingest` accept
one wrapper-owned record path and settle the matching lease. `judge-packet`
creates masked work before its judge launch can be claimed. `score` seals a
closed or complete run. `report` writes the approved evaluation document. No
subcommand starts Codex, Claude, a shell, or a network process.

- [ ] **Step 3: Document exact operator commands**

Document commands without `rtk`, marking which act only on external run roots
and which require private judge access. Make the separation from the sandbox
launcher explicit.

- [ ] **Step 4: Commit the evaluation CLI**

```bash
rtk ruby -c scripts/prompt-engineer-eval
rtk ruby -Itest test/prompt_engineer_evaluation_contract_test.rb
rtk git add scripts/prompt-engineer-eval scripts/lib/prompt_engineer COMMANDS.md \
  test/prompt_engineer_evaluation_contract_test.rb
rtk git commit -m "feat: add prompt engineer evaluation CLI"
```

## Task 10: Build A Fail-Closed Sandbox Launcher

**Files:**

- Create: `scripts/prompt-engineer-sandbox`
- Create: `scripts/lib/prompt_engineer/sandbox.rb`
- Create: `scripts/lib/prompt_engineer/sandbox/darwin.rb`
- Create: `test/prompt_engineer_sandbox_test.rb`
- Modify: `scripts/lib/prompt_engineer.rb`
- Modify: `COMMANDS.md`

**Entry gate:** Task 1 must prove the host can authenticate and reach its provider
while evaluated tool subprocesses cannot reach credentials, raw exports, result
sinks, connectors, or undeclared network. Contract tests may be written before
this proof, but the live host adapter must not be represented as supported until
the proof passes.

- [ ] **Step 1: Define the closed launch and attestation records**

The launch packet has `kind: executor|judge` and contains run/case/host IDs,
opaque arm/repeat IDs when applicable, masked-packet/rubric digests for judges,
nonce, lease and reservation IDs, exact argv template, pinned executable
realpath, anchored run-root device/inode, ledger-relative path, and exact digest
of the packet's lease event, staged roots and identities, environment allowlist, runtime read
allowlist, write roots, provider endpoint policy, timeout, and expected package/
input digests. The attestation adds wrapper/profile digests, self-probe results,
child PID/exit, native-export digest, post-run rehashes, and descriptor audit.
Unknown fields fail. Judge packets exclude arm identities, label maps, executor
worktrees, and unrelated private corpus data.

- [ ] **Step 2: Add fake-host isolation tests and observe RED**

For each supported adapter, assert allowed reads/writes work and assert failures
for source checkout, undeclared private rubric, undeclared home, credential file,
Keychain, connector socket, result sink, output descriptor inheritance, frozen-
file write, and non-provider network. Run equivalent executor and judge packets.
Reject a wrong or swapped run-root inode, absolute or escaping ledger-relative
path, absent or forged lease-event digest, broken digest-chain prefix, settled or
closed lease, reservation mismatch, and packet from another run. Prove that a
valid active lease remains launchable after unrelated later lease events while a
later settlement or close is observed at the current chain head and refused.
Assert timeout, SIGINT, SIGTERM, abrupt host exit, wrapper exception, and wrapper
death cannot leave descendants or an ingestible partial record; recovery seals
diagnostic bytes and leaves the reservation charged until an explicit close.

- [ ] **Step 3: Implement `probe`**

```text
prompt-engineer-sandbox probe --host codex --json
prompt-engineer-sandbox probe --host claude --json
```

The probe runs local fake-host checks, validates required native flags, and emits
an eligibility record. Darwin uses an explicit generated Seatbelt profile.
Unsupported OS versions, missing enforcement, or unproven auth/network/result
separation return a nonzero status and `qualification_capable=false`.

- [ ] **Step 4: Implement authenticated `launch`**

```text
prompt-engineer-sandbox launch --run-dir PATH --packet PATH --result-dir PATH
```

Accept only a leased packet whose digest and reservation exist in the immutable
run ledger. Open `--run-dir` as a no-follow directory, verify its device/inode
against the packet, open the ledger by descriptor-relative path, validate the
complete digest chain contains the packet's exact lease-event digest, validate
that lease/reservation remains active and unsettled at the current chain head,
and keep the ledger read-only. Later unrelated lease events do not stale the
packet. Reject an ambient, relocated, swapped, stale, or packet-invented ledger.
The operator chooses the pending packet; the packet owns argv. Launch with a
minimal environment, disabled connectors, isolated home, closed descriptors,
process-group timeout, and OS sandbox. Write raw native export and attestation
through wrapper-owned handles, rehash frozen roots, then emit the ingestion path.
There is no unsandboxed fallback.

- [ ] **Step 5: Commit the sandbox boundary**

```bash
rtk ruby -c scripts/prompt-engineer-sandbox
rtk ruby -Itest test/prompt_engineer_sandbox_test.rb
rtk git add scripts/prompt-engineer-sandbox scripts/lib/prompt_engineer \
  test/prompt_engineer_sandbox_test.rb COMMANDS.md
rtk git commit -m "feat: add prompt engineer sandbox launcher"
```

## Task 11: Build The Journaled Cutover Engine Against Isolated Roots

**Files:**

- Create: `scripts/prompt-engineer-cutover`
- Create: `scripts/lib/prompt_engineer/{secure_fs,journal,cutover}.rb`
- Create: `test/prompt_engineer_cutover_test.rb`
- Modify: `scripts/lib/prompt_engineer.rb`
- Modify: `COMMANDS.md`

**Entry gate:** Task 1 must pass only the Ruby 2.6/libc primitives that this task
builds upon: descriptor-relative no-follow operations, cross-directory same-
device move, symlink creation/readback, unlink, file and directory durable sync,
device checks, and parent-FD identity anchoring. Interruption reconciliation and
idempotent rollback are deliverables tested inside this task, not entry gates.
If a required OS primitive fails, stop this task and revise the design for an
audited native helper or a clearly manual cutover.

- [ ] **Step 1: Add secure-filesystem RED tests**

Test descriptor-relative open, stat, link, rename, and unlink anchored to opened
parents; ownership/mode/type/device/inode/hash revalidation; no-follow behavior;
bounded reads; exclusive locks; same-filesystem constraints; and required file
and parent `fsync`. Inject symlink swaps, parent identity swaps, mount/device
mismatch, non-directory parents, and unavailable libc calls. Fail closed.

- [ ] **Step 2: Add journal RED tests**

Test immutable exclusive `plan.json`; canonical digest-chained `events.jsonl`;
monotonic sequences; paired intent/outcome events; one tolerated torn final line;
earlier corruption refusal; digest break refusal; derived atomic `state.json`;
and recovery authority from plan, complete event prefix, and live filesystem.
Start concurrent prepare/apply/verify/rollback processes against the same
transaction and overlapping destination inventories; exactly one mutation
owner may proceed and every contender must return a stable locked/conflict error
without appending an unauthorized intent.

- [ ] **Step 3: Add transaction state-machine tests**

Cover prepare, first move, companion move, link install, verification, rollback,
and completed states. Inject failure before and after each mutation and each
sync. Cover first-target success plus second-target failure, crash between intent
and outcome, exact pre-state, exact post-state, ambiguous third state, repeated
rollback, partial rollback, and preservation of unrelated siblings.

- [ ] **Step 4: Implement the cutover command surface**

```text
prompt-engineer-cutover roots --host-root codex=PATH --host-root claude=PATH --output PATH
prompt-engineer-cutover preview --repo-root PATH --roots PATH --qualified-report PATH --preview-dir PATH
prompt-engineer-cutover prepare --repo-root PATH --preview PATH --qualified-report PATH --qualified-report-sha SHA256 --preview-sha SHA256 --transaction PATH --live
prompt-engineer-cutover apply --transaction PATH --qualified-report-sha SHA256 --live
prompt-engineer-cutover verify --transaction PATH
prompt-engineer-cutover verify --transaction PATH --activation-commit SHA
prompt-engineer-cutover verify --transaction PATH --record-use PATH
prompt-engineer-cutover verify --transaction PATH --retention-status
prompt-engineer-cutover rollback --transaction PATH
prompt-engineer-cutover rollback --transaction PATH --activation-revert SHA
```

All tests use temporary destinations. `roots` validates repeatable explicit host
roots, records no-follow identities under the closed roots schema, and refuses
overwrite. `preview` is read-only and opens no mutation handles. It accepts only
that roots record, validates the closed discovery-inventory schema, classifies
dedicated and shared paths, binds parent identities and capability-evidence
digests, and writes `inventory.yml`, `draft-plan.json`, and `preview.json` under
`--preview-dir`. Canonical `preview.json` binds the exact roots, inventory, draft
plan, qualified report, candidate commit, and package-tree digests; its SHA-256
is the only preview digest presented for approval.

After approval, `prepare` consumes `preview.json`, reopens its sibling artifacts,
rescans its embedded roots, requires each component to match its digest embedded
in `preview.json`, and requires the canonical `preview.json` digest to match
`--preview-sha`; any freshness, identity, path, or classification drift requires
a new preview and approval. The source must be a clean stable checkout
outside `.worktrees`; its HEAD must equal the report's exact qualified commit and
the symlink-target package tree digest must equal the report's candidate package
digest before and after apply. Reachability alone is insufficient. For live
roots, `prepare` freezes the verified report digest
and first explicit `--live`; `apply` repeats the same digest and `--live` and
cannot change authority. No command executed during implementation supplies that
live combination. Back up only inventory-named legacy directories and dedicated
companion modules into per-parent same-device backup roots. Preserve shared
frameworks and unrelated skills.

After filesystem verification and smoke tests, an operator creates one stable-
checkout activation commit changing `skills.yaml`, `CATALOG.md`, and `USAGE.md`
together to the same Active/Codex-and-Claude-enabled state and, only when
qualified, the single implicit-policy field. `verify --activation-commit`
durably appends an activation-attempt event containing the commit SHA, parent,
diff digest, and observed metadata-tree digest before it validates the exact diff;
only an accepted event makes the transaction complete. Before any activation
attempt, rollback accepts no `--activation-revert`; after an attempt, whether
accepted or rejected, failure or a later regression requires a normal Git revert
restoring the candidate state, followed by `rollback --activation-revert SHA`.
Rollback verifies the exact inverse of the recorded attempt and refuses
completion while active metadata remains. `--record-use` validates and appends one
anonymized post-cutover record; `--retention-status` reports the five-per-host
gate. Backup deletion remains unavailable and requires a separate explicit
cleanup request and reviewed change.

- [ ] **Step 5: Run the isolated transaction exercise**

Prepare two temporary installed homes with legacy fixtures and unrelated sibling
skills. Build explicit roots records and composite previews, then run
prepare/apply/verify/pre-activation rollback twice. Separately exercise an
activation fixture, invalid activation diff, crash immediately before and after
the durable activation-attempt event, accepted activation, exact inverse
activation-revert validation, and post-activation rollback. Compare full
pre/post trees, modes, links, and hashes. Expected: exact legacy restoration
after each first rollback and a no-op verified success after each repeated
rollback.

- [ ] **Step 6: Commit the cutover engine**

```bash
rtk ruby -c scripts/prompt-engineer-cutover
rtk ruby -Itest test/prompt_engineer_cutover_test.rb
rtk git add scripts/prompt-engineer-cutover scripts/lib/prompt_engineer \
  test/prompt_engineer_cutover_test.rb COMMANDS.md
rtk git commit -m "feat: add journaled prompt engineer cutover"
```

## Task 12: Integrate Static Verification And Fake End-To-End Runs

**Files:**

- Modify: `scripts/verify`
- Modify: all four prompt-engineer tests as needed
- Modify: `USAGE.md`

- [ ] **Step 1: Extend the repository verification gate**

Add Ruby syntax checks for all new executables and production modules, safe YAML
parsing for committed contracts/fixtures, executable-mode checks, runtime-package
allowlist checks, and detection of tracked run state. Do not make the installed
external `quick_validate.py` a hard dependency of `scripts/verify`.

- [ ] **Step 2: Run a complete fake qualification**

In a temporary run root, prepare all arms, feed sanitized Codex and Claude
exports through the sandbox attestation and normalizers, ingest two judges per
near-boundary masked packet and one judge for every other complete packet,
exercise repeat selection, score, and render a report. Verify maxima 96/40/64,
actual reserved/settled counts, unused conditional-judge reserve, package
provenance, public/private separation, and reproducible report bytes. Advance
the ledger with an unrelated lease before one valid launch and prove that launch
still succeeds; then settle or close another claimed lease and prove the same
packet is rejected without invoking the fake host.

- [ ] **Step 3: Run a complete isolated cutover**

Use temporary explicit discovery roots, a fake qualified-report digest, stable
non-worktree checkout fixture, activation-commit fixture, and legacy variants.
Exercise roots/composite-preview/approval-digest binding/prepare/apply/verify,
both pre-activation and post-activation rollback forms, activation verification,
use-record, retention-status, and all post-tree hash assertions, including
rejected activation diffs, activation-attempt crash recovery, concurrent
contenders, and post-preview drift. Confirm the stable-checkout HEAD
and candidate package tree exactly match the qualified report and that no path
under the actual user home was opened for mutation.

- [ ] **Step 4: Run focused and full gates**

```bash
rtk ruby -Itest test/prompt_engineer_skill_contract_test.rb
rtk ruby -Itest test/prompt_engineer_evaluation_contract_test.rb
rtk ruby -Itest test/prompt_engineer_sandbox_test.rb
rtk ruby -Itest test/prompt_engineer_cutover_test.rb
rtk scripts/test
rtk scripts/verify
rtk scripts/sync-skills --target codex --dry-run
rtk scripts/sync-skills --target claude --dry-run
rtk uv run --with pyyaml python /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/general/prompt-engineer
rtk git diff --check
```

Expected: all tests and validators pass; both sync dry-runs contain no candidate
operation; no generated run state or credential-bearing artifact is tracked.

- [ ] **Step 5: Commit integration**

```bash
rtk git add scripts/verify USAGE.md test
rtk git commit -m "test: verify prompt engineer replacement workflow"
```

## Task 13: Run Fresh Forward Tests And Close Demonstrated Skill Loopholes

**Files:**

- Modify only when a failing scenario requires it: runtime skill files and
  `test/prompt_engineer_skill_contract_test.rb`
- Append sanitized results: `docs/plans/2026-07-19-prompt-engineer-replacement-baseline.md`

- [ ] **Step 1: Run Quick-profile application tests**

Use fresh contexts for at least one single-prompt and one non-prompt-cause case.
Verify diagnosis precedes editing, success is observable, the candidate is
minimal, and the final claim does not exceed the evidence.

- [ ] **Step 2: Run Standard-profile comparative tests**

Use fresh executor contexts and blinded comparison for at least one
prompt-bearing skill and one subagent handoff. Verify package invocation,
baseline/candidate separation, regression checks, and bounded application.

- [ ] **Step 3: Run Ecosystem-profile tests**

Test a multi-prompt pipeline where changing one stage affects three downstream
consumers. Verify the skill maps the ecosystem, preserves interfaces, and tests
the system behavior rather than grading prose locally.

- [ ] **Step 4: Run trigger tests**

Run the frozen 40-session matrix exactly: eight explicit-positive prompts on
Codex plus the same eight on Claude (16); eight Codex implicit-positive plus
eight Codex implicit-negative prompts using the ephemeral activation candidate
(16); and eight Claude negative-discovery prompts (8). Do not add explicit-
negative sessions to this qualification budget. `prepare` derives the ephemeral
Codex activation package byte-for-byte from the qualified candidate, changes
only `policy.allow_implicit_invocation`, records both digests and the single-
field diff, and stages it outside the corpus. Treat unwanted activation on a
negative case as a zero-tolerance failure.

- [ ] **Step 5: Close only evidenced loopholes**

For each failure, first add a contract or pressure assertion that reproduces the
agent's rationalization, then make the smallest skill edit, rerun the failed
scenario in a new context, and rerun all earlier scenarios. If no failure is
observed, make no stylistic expansion.

- [ ] **Step 6: Commit forward-test refinements**

```bash
rtk git add skills/general/prompt-engineer test/prompt_engineer_skill_contract_test.rb \
  docs/plans/2026-07-19-prompt-engineer-replacement-baseline.md
rtk git commit -m "test: harden prompt engineer behavior from forward tests"
```

## Task 14: Run Live Qualification Only When Every Boundary Is Proven

**Files:**

- Create or update: `docs/plans/2026-07-19-prompt-engineer-replacement-evaluation.md`
- Store immutable raw run state outside the repository

- [ ] **Step 1: Recheck eligibility and explicit budget**

Require all static gates GREEN, both host probes eligible, the pinned legacy
source available, a clean candidate commit, and a positive
`PROMPT_ENGINEER_MAX_USD`. Print the frozen 96 behavioral, 40 trigger, and 64
judge ceilings plus the eight-hour operator cap before launching anything.

If any prerequisite is absent, render an `INCONCLUSIVE` report naming the exact
gate and stop this task without host execution.

- [ ] **Step 2: Prepare immutable run packets**

Run `prompt-engineer-eval policy` from the retained capability evidence and
operator choices, then `prepare` once with that canonical policy. Independently
verify manifest, corpus, candidate, legacy, activation-pair, sandbox-profile,
policy, executable, provider pricing/cap, and evidence-root digests. Seal the
base DAG and deterministic expansion rules before any output is observed;
outcome-dependent nodes are appended only by those rules.

- [ ] **Step 3: Launch executor sessions through the wrapper**

For each pending packet, the operator runs `prompt-engineer-eval next --kind
executor`; the locked ledger reserves budget and emits one lease. The operator
then invokes `prompt-engineer-sandbox launch`. Use fresh sessions and isolated
homes. Ingest only accepted native exports and attestations, settling the lease
from native usage. On a sandbox regression, input drift, budget refusal, missing
provenance, zero-tolerance event, or operator stop, run `prompt-engineer-eval
close` with the frozen reason/evidence; do not strand an open run.

- [ ] **Step 4: Launch masked judges separately**

Generate private judge packets only after executor evidence is sealed. Claim
each judge through `prompt-engineer-eval next --kind judge` and launch it through
the same sandbox wrapper with `kind: judge`. Use one fresh judge for every
complete packet and a second only for packets meeting the approved one-point
predicate. Bind every reservation, attestation, native export, and result to the
masked packet digest. Judges never receive arm identities or the label map.

- [ ] **Step 5: Seal scores and render the report**

Run score and report, then independently recompute digests, counts, point losses,
repeat selection, host coverage, trigger outcomes, and release decision. The
report records immutable external result locations by digest, not private raw
content.

- [ ] **Step 6: Commit only the sanitized report**

```bash
rtk git add docs/plans/2026-07-19-prompt-engineer-replacement-evaluation.md
rtk git commit -m "docs: record prompt engineer qualification"
```

## Task 15: Final Repository Verification And Cutover Decision Handoff

**Files:**

- Modify only if verification reveals a bounded defect
- Do not modify live installed skill paths

- [ ] **Step 1: Rerun the complete verification surface from a clean checkout**

```bash
rtk git status --short
rtk scripts/test
rtk scripts/verify
rtk scripts/sync-skills --target codex --dry-run
rtk scripts/sync-skills --target claude --dry-run
rtk uv run --with pyyaml python /Users/tunji/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/general/prompt-engineer
rtk git diff --check
```

Expected: clean checkout, all tests pass, candidate remains absent from sync
operations, skill validation passes, and no whitespace errors exist.

- [ ] **Step 2: Audit acceptance criteria against evidence**

Cross-reference each repository and qualification criterion in the approved
design to a test, command output, report section, or explicit blocked gate.
Repository completion may be GREEN while live qualification is `INCONCLUSIVE`;
state those separately.

- [ ] **Step 3: Stop before live cutover**

If the decision is `NOT_QUALIFIED` or `INCONCLUSIVE`, keep the legacy installation
and identify the bounded evidence-backed next change. If qualified, present the
report digest, candidate commit, stable non-worktree checkout path, authenticated
discovery-roots record, composite transaction preview, affected live paths,
per-parent backup policy, proposed same-commit
`skills.yaml`/`CATALOG.md`/`USAGE.md` activation diff, implicit-policy diff when
qualified, post-cutover use-record format, and the exact pre-activation rollback
and post-activation activation-revert-plus-filesystem-rollback commands. Generate
the roots record and preview with the read-only Task 11 commands and ask for
approval of the composite preview digest; do not run live prepare first. The
subsequent approved run uses the exact preview-bound prepare/apply signatures
from Task 11 and rejects any stable-checkout HEAD or candidate package-tree bytes
that differ from the qualified report; no unnamed approval flag or late-bound
report is permitted.

Do not run `scripts/sync-skills --apply` or
`prompt-engineer-cutover apply --live` as part of this plan.

## Final Verification Checklist

- [ ] Baseline evidence predates candidate skill bytes.
- [ ] Runtime package contains exactly four approved files.
- [ ] Candidate metadata is disabled for every install target.
- [ ] YAML contracts reject duplicate keys, aliases, unknown fields, and unknown
  schema keywords.
- [ ] Corpus, trigger suite, legacy lock, and budgets are immutable and hashed.
- [ ] Qualification policy and discovery inventory are deterministically built,
  closed-schema validated, provenance-bound, and covered by adversarial fixtures.
- [ ] Capability raw evidence remains available and hash-valid in its retained
  external evidence root.
- [ ] Evaluator never launches a host; sandbox wrapper never scores; cutover
  engine never participates in qualification.
- [ ] Codex and Claude records require native freshness, discovery, invocation,
  package, nonce, session, and sandbox evidence.
- [ ] Judging is masked, point-level, and reproducible; every packet receives
  one judge, and only near-boundary packets receive the policy-defined second
  judge within the reserved cap.
- [ ] Sandbox capability failures produce `INCONCLUSIVE`, never an unsafe
  fallback.
- [ ] Cutover tests cover races, crash points, torn journals, recovery,
  idempotent rollback, and unrelated-file preservation.
- [ ] Full test, verify, validator, dry-run, and diff gates pass.
- [ ] Live installed paths remain unchanged pending separate explicit approval.
- [ ] A qualified handoff rejects `.worktrees` as the live symlink source and
  includes read-only preview, three-file activation/inverse commits, rollback,
  use-record, and retention-status sequence.

## Execution Handoff

Recommended execution uses `superpowers:subagent-driven-development` in the
isolated worktree, with one implementation worker per task and a fresh
requirements/code-quality review before each task is accepted. Tasks 1 and 2
are mandatory sequential gates; Tasks 5 through 8 should remain sequential
because they share the qualification contract; sandbox and cutover work can use
independent workers after Task 5; the primary agent owns integration, live-run
authority, final verification, and every commit.

An inline alternative may use `superpowers:executing-plans` with review
checkpoints after Tasks 2, 4, 9, 12, and 15. In either mode, do not re-plan the
approved design during execution; stop only for a genuine authority expansion,
an unsafe boundary, or evidence that invalidates a design invariant.
