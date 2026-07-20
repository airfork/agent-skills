# Commands

Run repository commands from the repository root; installed-skill commands below
use explicit absolute paths. User-facing commands are intentionally plain shell
commands.

| Command | Purpose | State affected |
|---------|---------|----------------|
| `scripts/test` | Run every Ruby contract test in `test/` sequentially. | Read-only, except test-created temporary directories outside the repo. |
| `scripts/test --list` | List the tests selected by the test wrapper. | Read-only. |
| `scripts/verify` | Check Ruby/YAML/TOML/shell syntax, the adversarial-review package, diff whitespace, then run `scripts/test`. | Read-only. |
| `scripts/verify-adversarial-review --root PATH` | Check Ruby syntax and JSON parsing for the portable adversarial-review package beneath the canonical repository root. | Read-only. |
| `scripts/clean --dry-run` | Preview removal of local caches, logs, screenshots, coverage, and planning scratch. | Read-only preview. |
| `scripts/clean` | Remove only the named local generated paths. | Removes only untracked generated paths listed by the script. |
| `scripts/archive-clean --dry-run` | Preview removal of build, distribution, release, and artifact output. | Read-only preview. |
| `scripts/archive-clean` | Remove only named release/archive output paths. | Removes only untracked generated paths listed by the script. |
| `scripts/sync-skills --target codex --dry-run` | Preview managed skill symlink changes. | Read-only. |
| `scripts/sync-skills --target codex --apply` | Apply managed Codex skill symlink changes when explicitly requested. | Changes the selected global skill directory. |
| `scripts/prompt-engineer-eval` | Planned/deferred until implementation commits land; the explicit prompt-engineer qualification CLI is absent from this checkout. | No state change until implementation lands. |
| `scripts/prompt-engineer-sandbox` | Planned/deferred until implementation commits land; the isolated Codex and Claude qualification launcher is absent from this checkout. | No state change until implementation lands. |
| `scripts/prompt-engineer-cutover` | Planned/deferred until implementation commits land; the explicit cutover and retention CLI is absent from this checkout. | No state change until implementation lands. |
| `scripts/run-codex-5.6-skill-review <luna\|terra\|sol>` | Run the existing model-bound compatibility review. | May update its report only after a successful review. |
| `scripts/prompt-engineer-eval <subcommand>` | Prepare, inspect, score, and report prompt-engineer evaluation artifacts without launching a host. | Depends on the subcommand; live host operations are fail-closed. |
| `/absolute/path/to/installed/adversarial-review/scripts/adversarial-review start --repository /absolute/path/to/reviewed/repository --spec docs/spec.md --plan docs/plan.md --executor generic --model MODEL --effort EFFORT` | Start a portable adversarial-review run from the installed skill, targeting an explicit repository. | Creates durable run state; defaults to chat and sibling report output. |
| `/absolute/path/to/installed/adversarial-review/scripts/adversarial-review ingest --run-dir RUN --task ID --result RESULT.json --capabilities CAPABILITIES.json` | Validate and ingest one generic reviewer result. | Advances only the named task in durable run state. |
| `/absolute/path/to/installed/adversarial-review/scripts/adversarial-review continue --run-dir RUN` | Advance the validated state machine or render a terminal report. | Updates durable run state and configured report output. |
| `/absolute/path/to/installed/adversarial-review/scripts/adversarial-review status --run-dir RUN --json` | Print deterministic resumable run status. | Read-only. |

There is no repository-wide application server, build system, or linter to wrap. Skill-specific checks belong with the skill or its contract test.

## Prompt-engineer evaluation CLI

All subcommands emit canonical JSON on stdout and JSON errors on stderr. The
CLI never launches Codex, Claude, a shell, or a network process. Native host
capabilities are reported by `status`; the current recorded boundary marks both
Codex and Claude live execution as unsupported.

Create immutable operator choices (the output path must not already exist):

```text
scripts/prompt-engineer-eval choices --codex-model ID --codex-effort LEVEL --claude-model ID --claude-effort LEVEL --codex-timeout SECONDS --claude-timeout SECONDS --max-usd DECIMAL --codex-cap-usd DECIMAL --claude-cap-usd DECIMAL --output PATH
```

Inspect the capability boundary, optionally alongside an external run root:

```text
scripts/prompt-engineer-eval status
scripts/prompt-engineer-eval status --run-dir RUN_DIR
```

The remaining deterministic artifact commands are available through explicit
dispatch: `policy`, `prepare`, `next`, `ingest`, `judge-packet`, `judge-ingest`,
`score`, `close`, and `report`. Host-dependent execution, native export
normalization, and judge-host ingestion fail closed until native evidence and
adapters are available. Run roots, corpus/package paths, evidence files, and
report destinations are explicit external paths; no ambient home or network
state is consulted.
