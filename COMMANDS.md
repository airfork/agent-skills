# Commands

Run these from the repository root. User-facing commands are intentionally plain shell commands; agents should follow `AGENTS.md` about using `rtk` for shell execution.

| Command | Purpose | State affected |
|---------|---------|----------------|
| `scripts/test` | Run every Ruby contract test in `test/` sequentially. | Read-only, except test-created temporary directories outside the repo. |
| `scripts/test --list` | List the tests selected by the test wrapper. | Read-only. |
| `scripts/verify` | Check Ruby/YAML/TOML/shell syntax, diff whitespace, then run `scripts/test`. | Read-only. |
| `scripts/clean --dry-run` | Preview removal of local caches, logs, screenshots, coverage, and planning scratch. | Read-only preview. |
| `scripts/clean` | Remove only the named local generated paths. | Removes only untracked generated paths listed by the script. |
| `scripts/archive-clean --dry-run` | Preview removal of build, distribution, release, and artifact output. | Read-only preview. |
| `scripts/archive-clean` | Remove only named release/archive output paths. | Removes only untracked generated paths listed by the script. |
| `scripts/sync-skills --target codex --dry-run` | Preview managed skill symlink changes. | Read-only. |
| `scripts/sync-skills --target codex --apply` | Apply managed Codex skill symlink changes when explicitly requested. | Changes the selected global skill directory. |
| `scripts/run-codex-5.6-skill-review <luna\|terra\|sol>` | Run the existing model-bound compatibility review. | May update its report only after a successful review. |
| `skills/general/adversarial-review/scripts/adversarial-review start --repository . --spec docs/spec.md --plan docs/plan.md --executor generic --model MODEL --effort EFFORT` | Start a portable adversarial-review run and emit validated task bundles. | Creates durable run state; defaults to chat and sibling report output. |
| `skills/general/adversarial-review/scripts/adversarial-review ingest --run-dir RUN --task ID --result RESULT.json --capabilities CAPABILITIES.json` | Validate and ingest one generic reviewer result. | Advances only the named task in durable run state. |
| `skills/general/adversarial-review/scripts/adversarial-review continue --run-dir RUN` | Advance the validated state machine or render a terminal report. | Updates durable run state and configured report output. |
| `skills/general/adversarial-review/scripts/adversarial-review status --run-dir RUN --json` | Print deterministic resumable run status. | Read-only. |

There is no repository-wide application server, build system, or linter to wrap. Skill-specific checks belong with the skill or its contract test.
