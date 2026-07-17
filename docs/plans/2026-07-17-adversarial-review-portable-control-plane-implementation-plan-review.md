# Portable Adversarial Review Control Plane Plan Review

## Outcome

**PASS after revision.** Three fresh-context xhigh reviewers attacked the
implementation plan for design conformance, buildability/testability, and
safety/operational robustness. Every promoted issue was incorporated into the
plan. A fourth bounded xhigh reviewer then checked only those resolution
classes and reported no open item.

Reviewed artifacts:

- Design SHA-256: `e84f17a1e196df507b08e7cfae7f1ba6e31659b15395c4432f6186afd5f7b666`
- Revised plan SHA-256: `211edd07970d434b2b318cf98b36dd86f8203c8cce50be389251b715138f9874`
- Reviewer runtime: Codex CLI `0.144.5`, model `gpt-5.6-sol`, effort `xhigh`,
  ephemeral read-only sessions

## Review Runs

| Angle | Session | Result |
|---|---|---|
| Design conformance | `019f702e-565c-7e23-b73f-73c1d61ecea7` | Promoted missing persistence, convergence, generic lifecycle, effort fallback, retry, and provenance requirements |
| Buildability and testability | `019f702e-565c-7f30-a853-f5f084e40c41` | Promoted incomplete schema/TDD/loading/fixture/verifier commitments |
| Safety and operations | `019f702e-565c-79e2-a3a7-9fe183b15c48` | Promoted environment, tool-surface, attestation, locking, process, temporary-file, and executable-identity hardening |
| Focused resolution verification | `019f703b-3658-7843-8497-493a1676e528` | PASS; all 22 bounded issue classes resolved |

The first review command accidentally allowed each reviewer to invoke the
existing adversarial-review skill recursively. Those three runs were stopped
after they expanded into additional attack waves, at approximately 93,557,
121,789, and 99,101 tokens. The authoritative runs above used an explicit
single-reviewer, no-skill, no-subagent boundary. This failure mode directly
reinforces the design requirement for a bounded scripted control plane.

## Finding Dispositions

| ID | Severity | Root issue | Disposition | Plan resolution |
|---|---|---|---|---|
| AR-PLAN-001 | HIGH | Manifest omitted resolved model and effort | RESOLVED | Manifest API, persisted fields, and assertions now cover both |
| AR-PLAN-002 | HIGH | Completion transitions lacked convergence guards | RESOLVED | Named `can_complete?` invariant and negative transition tests are mandatory |
| AR-PLAN-003 | HIGH | Generic execution could claim unsupported capabilities or ordinary PASS | RESOLVED | Evidence-bearing capability schema and shared degraded-verdict gate added |
| AR-PLAN-004 | HIGH | Generic mode lacked a complete lifecycle test | RESOLVED | End-to-end start/ingest/author/resolution/report test added |
| AR-PLAN-005 | HIGH | Cursor and Gemini effort selection could silently degrade | RESOLVED | Exact selection and runtime attestation are required or generic is selected |
| AR-PLAN-006 | HIGH | Ultra behavior was not enforced across adapters | RESOLVED | Table-driven tier equality tests and explicit Claude/Gemini ultra cases added |
| AR-PLAN-007 | MEDIUM | Repair policy did not cover missing checks or low finding counts | RESOLVED | One repair for malformed/missing-check output; zero for valid low-count output |
| AR-PLAN-008 | MEDIUM | Report provenance was incomplete | RESOLVED | Full target, repository, time, executor, CLI, model, angle, retry, and usage block required |
| AR-PLAN-009 | HIGH | Six schema shapes were delegated to unspecified design detail | RESOLVED | Normative table and complete valid/invalid fixtures define all seven schemas |
| AR-PLAN-010 | HIGH | Initial schema work batched unrelated behaviors behind LoadError | RESOLVED | Entrypoint scaffold and per-schema/per-validator RED-GREEN cycles separated |
| AR-PLAN-011 | HIGH | New library files were not consistently loaded by the public entrypoint | RESOLVED | Each task explicitly updates deterministic `require_relative` entries |
| AR-PLAN-012 | HIGH | Prompt generation preceded the new role contract | RESOLVED | Role contracts are frozen and tested in Task 1 before prompt extraction |
| AR-PLAN-013 | MEDIUM | Digest test used a fabricated expected value | RESOLVED | Expected SHA-256 is computed from the real fixture file |
| AR-PLAN-014 | MEDIUM | Runner example used Hash access against a Struct | RESOLVED | Example now uses `result.exit_status` |
| AR-PLAN-015 | HIGH | Adapter argv and fake behavior were only partial | RESOLVED | Full ordered templates, version-labelled fixtures, help/run distinction, and output side effects required |
| AR-PLAN-016 | MEDIUM | Repository verification was asserted by source strings | RESOLVED | Independently executable package verifier gets malformed Ruby/JSON behavioral tests |
| AR-PLAN-017 | HIGH | Child processes inherited ambient environment and unspecified cwd | RESOLVED | Canonical cwd, `unsetenv_others`, and explicit minimal allowlist required |
| AR-PLAN-018 | HIGH | Claude safe-shell restriction was not enforceable | RESOLVED | General shell removed; only `Read,Grep,Glob` are exposed |
| AR-PLAN-019 | HIGH | Help parsing was treated as proof of security enforcement | RESOLVED | Machine-readable startup/runtime attestation is required before reviewed content is sent |
| AR-PLAN-020 | HIGH | Atomic state/report locking could race or follow symlinks | RESOLVED | Stable locks, full transaction scope, symlink rejection, file and parent-directory fsync required |
| AR-PLAN-021 | MEDIUM | Timeout and temporary resource cleanup was underspecified | RESOLVED | Process-group TERM/KILL/reap, pipe ensure blocks, modes, and block-scoped cleanup required |
| AR-PLAN-022 | HIGH | Executable could change between probe and execution | RESOLVED | Pinned realpath plus path exclusion, metadata/digest recording, and identity recheck required |

No promoted finding was rejected. Overlapping reviewer findings were merged
into the root issues above rather than counted repeatedly.

## Resolution Gate

The bounded resolution verifier checked only the 22 promoted issue classes,
cited plan-line evidence for each, and returned:

```text
Final gate: PASS - none of the bounded issue classes remain OPEN.
```

The implementation plan is ready for execution, subject to the repository
verification and planning-checkpoint commit required by its completion gate.
