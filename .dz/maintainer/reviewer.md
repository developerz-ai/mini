# Reviewer instructions — developerz-ai/mini

> Read by the developerz.ai reviewer at EVERY review of this repository, at the reviewed
> commit, as this repo's own layer of the reviewer's prompt. It refines the platform rules
> (a finding is cited or withheld) and never overrides them. `CLAUDE.md` is the source of
> truth; this file is its review-time distillation (`docs/standards/README.md` is the long
> form). Keep it under 12,000 characters — past that it is cut.

## Stack

Bash + `curl`/coreutils/`awk`/`sed`, opencode (agent runtime), ollama (model server), python3 optional (always with a fallback), ShellCheck. The gate is `bin/check`: `bash -n` over `bin/mini lib/*.sh platforms/*.sh install.sh` plus the five dev-workflow scripts, `bash .github/run-tests.sh`, `bin/check-public-tree`, a probe proving the runner can fail, `bash .github/run-tests_test.sh`, then ShellCheck (`-x --source-path=lib --source-path=platforms -e SC2015 -e SC2016`). Exit 0 = passed, 75 = `shellcheck` missing (refused to grade), 79 = scoped run passed, anything else = red. A change that does not pass it is not proven, whatever its description says.

## What to reject

**Runtime dependencies (`CLAUDE.md` § Non-negotiables)**
- Anything mini runs that needs more than bash + `curl`/coreutils/`awk`/`sed`: no `jq`, no hard python3 dependency. A python3 path without a bash fallback is a finding.
- An executable without `set -euo pipefail`, or an unquoted expansion.

**Safety on the user's box**
- A bare `sudo` in a path the agent can reach — it hangs forever with no tty. Only `sudo -n`; in a platform module, the module's own `_sudo` helper (`platforms/README.md`).
- Anything mini starts listening on a non-loopback interface. ollama is pinned to loopback; opencode's server modes are loopback + a generated password; `--lan` is the only way out and must print a warning.
- Reading or writing `~/.config/opencode/opencode.json`. mini points `OPENCODE_CONFIG` at its own file (`lib/opencode.sh`).
- A custom tool installed globally under a name that is not `mini_*` (`share/opencode-tools/`): shadowing an opencode built-in changes the user's unrelated projects.
- Overwriting a user-edited `AGENTS.md`: "unchanged" vs "edited" is decided against `.agents-md-generated` (`bin/mini`).
- A secret in `$MINI_HOME/config` (which `mini config` prints) instead of a `0600` file such as `$MINI_HOME/secret`.
- Program files written under `$MINI_HOME` (`~/.cache/mini/`) other than `$MINI_HOME/tools` (copied from `share/tools`), or state read or stored in the install root.
- A package-manager call that can prompt (`platforms/README.md`: never prompt).

**Layering**
- Distro logic in `lib/`: a `lib/` file mentioning `apt` is a bug. It belongs in `platforms/<id>.sh` behind the five-function interface in `platforms/README.md`.
- A doctor check in `lib/doctor.sh` that does not print the exact command that fixes it.
- A new product entry point besides `bin/mini`; `bin/setup`, `bin/dev`, `bin/check`, `bin/stop` are dev-workflow scripts, not product.
- Building something opencode already does: mini is a wrapper, not a framework (`CLAUDE.md` intro).

**Change recipes (`CLAUDE.md` § Change recipes)**
- A new tool without all four parts: the bash script in `share/tools/`, its TS wrapper in `share/opencode-tools/`, a row in the tool table in `share/prompts/base.md`, a check in `lib/doctor.sh`.
- A `share/models.tsv` row out of best-to-smallest order, without a re-dated header, for a reasoning model, or whose context column exceeds the model's real `context length`.
- Running a base model directly instead of the `mini-<base>:<n>k` variant with `num_ctx` baked in (`lib/models.sh`).
- A behaviour change without the matching page under `docs/` updated in the same change.

**Tests (`CLAUDE.md` § Testing)**
- A test that is not hermetic: no own `mktemp` sandbox, a live model service, a credential, network access, or a fetched URL. External commands are isolated with PATH stubs or shell-function stubs.
- A test whose verdict depends on grepping output for `FAIL`/`SKIP` instead of the exit code; a runner change that lets one member's env leak into another or stops running members after a failure.
- A test framework, or a test file outside `tests/` (the runner stays in `.github/` on purpose).

**CI (`.github/workflows/shell-checks.yml`)**
- A second job, or a second `run:` step for tests: the suite rides in the same step as the `bash -n` loop. A rename of `shell-checks` without the matching `pr.required_checks` change in `.dz/maintainer/maintainer.yml`.
- `continue-on-error`, a secret, a network dependency, or an ollama/opencode install in CI.
- A new ShellCheck exclusion beyond `SC2015` and `SC2016` on the command line: every other code is enforced, warnings included.
- A drift between CI's file lists and `bin/check`'s `SHELL_FILES`.

**Public tree (`bin/check-public-tree`)**
- A private hostname, a home-directory path, or a private repository named in any tracked file.

## Gates that matter

- `shell-checks` — the single job in `.github/workflows/shell-checks.yml` and the one entry in `pr.required_checks` (`.dz/maintainer/maintainer.yml`). Red blocks auto-merge.
- `bin/check` locally (exit 0); exit 79 from a scoped run is a pass that leaves the rest to CI, exit 75 is the environment, not the change.
- `share/tools/*` is never syntax- or lint-checked by any gate: review it by hand. A change to the runtime path also needs `mini doctor` clean, which CI cannot run.

## Never flag

- `SC2015` (`a && b || c` one-liners) and `SC2016` (single-quoted literal backticks): house idioms, excluded on purpose.
- `bin/setup`, `bin/dev`, `bin/check`, `bin/stop`, `.githooks/pre-commit` not being ShellChecked: by design, `bash -n` only.
- The hand-aligned, tab-separated `share/models.tsv` (`models_rows` squeezes repeated tabs).
- Dense, imperative, table-heavy prose in `share/prompts/`: it is written for a 7B model on purpose.
- `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_KEEP_ALIVE=30m`, `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0` and long provider timeouts: measured tuning (`CLAUDE.md` § What actually makes it work).
- Work directly in the checkout with no git worktrees: a deliberate rule.
- `tmp/dz/`, `.codegraph/`, `.mcp.json`, `.vscode/`, and the `.dz/` directory's own layout: platform or local tooling.
