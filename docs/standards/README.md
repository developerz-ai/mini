# mini standards

The coding, structure and testing rules for working on mini, each with the path it comes
from. [`../../CLAUDE.md`](../../CLAUDE.md) is the source of truth; this page is its
distillation for a contributor.

## Code

| Rule | Source |
|---|---|
| Bash + `curl`/coreutils/`awk`/`sed` only for anything mini runs. No `jq`; python3 is optional and always has a fallback. | `CLAUDE.md` § Non-negotiables |
| `set -euo pipefail` in every executable. Quote everything. | `CLAUDE.md` § Non-negotiables |
| `sudo -n` only — a bare `sudo` hangs with no tty. Platform modules escalate through their own `_sudo` helper. | `CLAUDE.md`, `platforms/debian.sh` |
| Nothing mini starts listens off loopback; `--lan` is the only way out and prints a warning. | `CLAUDE.md` § Non-negotiables |
| Never touch `~/.config/opencode/opencode.json`; mini sets `OPENCODE_CONFIG` to its own file. | `CLAUDE.md`, `lib/opencode.sh` |
| Globally installed custom tools are named `mini_*`. | `share/opencode-tools/` |
| Never clobber a user-edited `AGENTS.md`; compare against `.agents-md-generated`. | `CLAUDE.md`, `bin/mini` |
| Secrets go in `0600` files (`$MINI_HOME/secret`), never in `config`. | `CLAUDE.md` § Non-negotiables |
| State lives in `$MINI_HOME` (`~/.cache/mini/`); program files never do, except `$MINI_HOME/tools` copied from `share/tools`. | `CLAUDE.md` § Non-negotiables |
| Logging, prompts and `die`/`warn` come from `lib/common.sh`, sourced first. | `lib/common.sh` |

## Structure

| Rule | Source |
|---|---|
| `bin/mini` is the only product entry point; `bin/setup`, `bin/dev`, `bin/check`, `bin/stop` are dev workflow. | `CLAUDE.md` § Layout |
| One concern per `lib/` file: `detect`, `models`, `ollama`, `opencode`, `doctor`, `common`. | `lib/` |
| Distro logic lives in `platforms/<id>.sh` behind a five-function interface; a `lib/` file mentioning `apt` is a bug. | `platforms/README.md` |
| A doctor check prints the exact command that fixes it. | `lib/doctor.sh` |
| A new tool is four parts: `share/tools/` script, `share/opencode-tools/` wrapper, a row in `share/prompts/base.md`, a check in `lib/doctor.sh`. | `CLAUDE.md` § Change recipes |
| `share/models.tsv` rows run best to smallest, with a dated header; no reasoning models; the context column is the model's real context length. | `share/models.tsv`, `CLAUDE.md` § Change recipes |
| A behaviour change updates the matching page in `docs/` in the same change. | `CLAUDE.md` § Change recipes |

## Testing

| Rule | Source |
|---|---|
| Plain bash under `tests/`, no framework; `bash .github/run-tests.sh` runs every `tests/*.sh`. | `.github/run-tests.sh` |
| Each member runs in its own process, every member runs, and the verdict is the exit code alone. | `.github/run-tests_test.sh` |
| Hermetic: own `mktemp` sandbox, no live model, no credential, no network; stub external commands on `PATH` or as shell functions. | `CLAUDE.md` § Testing |
| The gate is `bin/check`: exit 0 passed, 75 refused to grade (`shellcheck` missing), 79 scoped run passed, anything else red. | `bin/check` |
| CI is one job, `shell-checks`; the suite rides in the same step as the `bash -n` loop. ShellCheck excludes only `SC2015` and `SC2016`. | `.github/workflows/shell-checks.yml` |
| `share/tools/*` is checked by no gate: review it by hand. | `CLAUDE.md` § Commands |
