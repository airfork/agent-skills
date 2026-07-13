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

There is no repository-wide application server, build system, or linter to wrap. Skill-specific checks belong with the skill or its contract test.
