# mini

Bash wrapper that turns **opencode + ollama** into a local Linux sysadmin agent.
No cloud provider, no API key. A wrapper, not a framework: opencode is the agent
runtime, ollama runs the model. mini picks a model that fits the hardware, gives
it a working context window, a good system prompt and a few tools. Before
building anything, check whether opencode already does it.

**Stack:** bash + `curl`/coreutils/`awk`/`sed` · opencode (agent runtime) ·
ollama (model server) · python3 optional (HTML parsing, always with a fallback) ·
shellcheck (lint).

## Non-negotiables

| Rule | Detail |
|---|---|
| Bash only | Anything mini runs is bash + `curl`/coreutils/`awk`/`sed`. No jq, no python dependency. |
| `set -euo pipefail` | In every executable. Quote everything. |
| `sudo -n` only | A bare `sudo` in a path the agent can reach hangs forever (no tty). |
| Loopback by default | Nothing mini starts listens on a public interface. ollama is pinned to loopback; opencode's server modes are loopback + generated password. `--lan` is the only way out and prints a warning. |
| Never touch `~/.config/opencode/opencode.json` | The user's own setup is off limits. mini points `OPENCODE_CONFIG` at its own file. |
| Tools are `mini_*` | Globally installed custom tools are namespaced `mini_*`; shadowing an opencode built-in changes the user's unrelated projects. |
| Never clobber a user-edited `AGENTS.md` | Compare against `.agents-md-generated` to tell "unchanged" from "edited". |
| Secrets in `0600` files | `$MINI_HOME/secret`, never in `config` (which `mini config` prints). |
| Distro logic in `platforms/` | Never in `lib/`; a `lib/` file mentioning `apt` is a bug. |
| A doctor check prints its fix | The exact command that fixes it. No fix, not a check. |
| State vs program files | State lives in `~/.cache/mini/` (`$MINI_HOME`); never write program files there (sole exception: `$MINI_HOME/tools`, copied from `share/tools`); never read or store state in the install root. |
| No git worktrees | Work directly in this checkout. Subagents, if any, share it and split work into disjoint files. |

## Commands

| Command | What |
|---|---|
| `bin/setup` | Idempotent setup. Runs `mise install` if mise exists, best-effort: a mise failure warns and setup continues (pinned by `tests/setup_test.sh`). Installs only what `command -v` shows missing among `shellcheck curl python3 ss ps` (apt: `shellcheck curl ca-certificates python3 iproute2 procps`) — `apt-get` as root, `sudo -n apt-get` otherwise. Nothing missing → never calls apt-get or sudo. No usable installer → names the missing tools, exits non-zero. |
| `bin/dev` | Runs `bin/mini models`. |
| `bin/check` | **The gate** (below). |
| `bin/stop` | Runs `bin/mini stop \|\| true`. |
| `bash .github/run-tests.sh` | The whole offline suite, every `tests/*.sh`. |
| `mini doctor` | Every runtime check, each prints its fix command. Must be clean. |

### `bin/check` — the gate

| Mode | Runs, in order |
|---|---|
| Full | `bash -n` over `bin/mini lib/*.sh platforms/*.sh install.sh` (the same list CI checks) PLUS `bin/setup bin/dev bin/check bin/stop .githooks/pre-commit` (the five dev-workflow scripts — syntax only; CI's bash -n list is unchanged) → `bash .github/run-tests.sh` → a probe driving the runner with a deliberately failing member → `bash .github/run-tests_test.sh` → ShellCheck over `bin/mini lib/*.sh platforms/*.sh install.sh` (unchanged — CI's exact list) |
| Scoped: `bin/check <files…>` | `bash -n` + ShellCheck on those files only; suite skipped |

| `bin/check` exit | Meaning |
|---|---|
| `0` | Full gate passed — commit. |
| `75` | `shellcheck` missing — refused to grade; blame the environment, fix with `bin/setup`. |
| `79` | Scoped run passed — commit; CI grades the rest. |
| other | The gate ran and the change is red. |

`.githooks/pre-commit` execs `bin/check`. Activate once per clone: `git config
core.hooksPath .githooks`.

Gate scope:

| Files | Covered? |
|---|---|
| `bin/mini`, `lib/*.sh`, `platforms/*.sh`, `install.sh` | Yes — gate and CI (`bash -n` + ShellCheck). |
| `bin/setup`, `bin/dev`, `bin/check`, `bin/stop`, `.githooks/pre-commit` | Gate + pre-commit hook, `bash -n` only (syntax; the gate loop extends past CI's list). Not in CI's bash -n list, never ShellChecked. A broken `bin/setup` also fails the suite — `tests/setup_test.sh` executes it. |
| `tests/*.sh`, `.github/*.sh` | In neither `bash -n`/ShellCheck list, but the suite still executes `tests/*.sh` and `.github/run-tests*.sh`, so a broken test fails the run. |
| `share/tools/*` | Never syntax- or lint-checked anywhere — check by hand. |

## Layout

| Path | What |
|---|---|
| `bin/mini` | CLI + dispatch. The only product entry point. |
| `bin/setup` `bin/dev` `bin/check` `bin/stop` | Dev-workflow scripts, not product. |
| `lib/common.sh` | log/ask/config helpers. Sourced first, no dependencies. |
| `lib/detect.sh` | OS + hardware → `OS_PLATFORM`, `BUDGET_MB`, `ACCEL` |
| `lib/models.sh` | Registry, hardware fit, the `num_ctx` variant build |
| `lib/ollama.sh` | Server lifecycle |
| `lib/opencode.sh` | Generates `opencode.json`, launches opencode |
| `lib/doctor.sh` | Every check, each with its fix command |
| `platforms/<id>.sh` | Distro-specific package handling |
| `share/prompts/base.md` / `<id>.md` | Platform-neutral / distro-specific system prompt |
| `share/tools/*` | `websearch` `webfetch` `sysreport` — plain bash |
| `share/opencode-tools/*.ts` | TS definitions exposing those to opencode |
| `share/models.tsv` | Model registry. Dated header (`curated 2026-07`). |
| `install.sh` | curl-to-bash entry point |
| `tests/` | Offline bash checks. No framework. |
| `.github/run-tests.sh` | Suite runner (outside `tests/` on purpose). `run-tests_test.sh` is its verdict self-test. |
| `.github/workflows/shell-checks.yml` | CI: the single `shell-checks` job. |
| `.githooks/` | `pre-commit` → `bin/check`. |
| `.dz/` | developerz.ai config: `maintainer/maintainer.yml` (`pr.required_checks`), `briefs/`, `onboarding/`. |

## What actually makes it work

| # | Thing | Why / rule |
|---|---|---|
| 1 | **Context window** | Ollama defaults to 4k; opencode's tool definitions nearly fill it, tool calls truncate, the agent silently degrades. mini never runs a base model — it builds `mini-<base>:<n>k` with `num_ctx` baked in. "It stops mid-task" → suspect this first. `num_ctx` above the model's native context does nothing; verify with `ollama show <m> \| grep 'context length'` before editing `models.tsv`. |
| 2 | **The prompt** | `share/prompts/` is where a 7B model gets its judgment. Dense and imperative: short rules, exact commands, tables over prose. Processed on every first turn, so length costs CPU seconds. |
| 3 | **Sudo** | opencode's bash tool has no tty; a password-prompting `sudo` hangs. Without passwordless sudo the agent can read but not act — hence `mini sudo`, and doctor treats it as a hard failure. |
| 4 | **ollama tuning** | `OLLAMA_NUM_PARALLEL=1` (opencode fires a title request alongside the main one; two slots double KV and thrash on CPU), `OLLAMA_KEEP_ALIVE=30m` (5m default unloads GBs between turns), `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` (halves context cost; makes 128k affordable). Via a systemd drop-in, or env vars when mini owns the process. |
| 5 | **Request timeouts** | `timeout`/`chunkTimeout` in provider options. Defaults kill a cold CPU request mid-prefill; symptom is an empty response, nothing logged. Measured: 5,839-token prompt = 185s prefill at ~31 tok/s. |
| 6 | **Prompt size = CPU latency** | Every enabled tool ships its schema each request. Trimming opencode built-ins to bash/read/write/edit + tighter prompts cut a request from 9,300 to 5,838 tokens (~2 min off a cold turn). Real number: ollama journal `task.n_tokens`. |

## Change recipes

| Change | Do |
|---|---|
| New model | Row in `share/models.tsv`, ordered best → smallest (selection takes the first row that fits). Re-date the header comment. Verify first: `ollama show <m>` lists `tools`; context column = its real `context length`. **No reasoning models** (`<think>` eats the output budget; qwen3:0.6b returned empty content) — prefer `-instruct`. The registry is tab-separated, hand-aligned; `models_rows` squeezes repeated tabs. |
| New platform | See `platforms/README.md`. Two files, no registry to edit. |
| New tool | Bash script in `share/tools/`, TS wrapper in `share/opencode-tools/`, a row in the table in `share/prompts/base.md`, a check in `lib/doctor.sh`. |
| New slash command | The `command` block in `opencode_write_config`. |
| Docs | `README.md` is for users; `docs/` has seven pages — README, architecture, models, prompts, tools, troubleshooting, usage. Update the relevant one in the same change. |

## Testing

Plain bash under `tests/`, no framework: `bash .github/run-tests.sh`.

Runner contract:

- No arguments → every `tests/*.sh` (eleven today); explicit script paths override that list.
- Each member runs as its own process (`bash "$t"`) — exported env cannot leak between members.
- Every member runs even when an earlier one fails.
- Verdict = **exit code alone** — never grep output for `FAIL`/`SKIP`; a script printing `SKIP` under its own contract (no python3, running as root) exits 0 and stays green.

| Script | What it pins |
|---|---|
| `host_memory_test.sh` | `write_host_memory` — writer of `$MINI_HOME/memories/00-host.md` |
| `init_test.sh` | init-system detection + doctor's Init step |
| `mini_bin_dir_test.sh` | the PATH the agent inherits, and the `/remember` command |
| `model_flag_test.sh` | the missing-argument refusal of `mini --model` |
| `ollama_bind_test.sh` | doctor's ollama bind verdict, from the observed listener |
| `ollama_systemd_failure_test.sh` | systemd rebind/stop refusals — failure reported, not swallowed |
| `opencode_config_test.sh` | the `opencode.json` regeneration contract (skips without python3) |
| `remote_key_test.sh` | the API-key prompt of `mini remote` |
| `setup_test.sh` | `bin/setup` — installs only what is missing, root vs `sudo -n`, clear failure with no installer, best-effort mise (a failure warns, setup continues) |
| `test_provider.sh` | provider and launch selection |
| `webfetch.sh` | webfetch truncation + failure contract (PATH-stubbed, no network) |

Every test is hermetic: own `mktemp` sandbox, no live model service, no
credential, no network, literal URLs never fetched. Scripts isolate external
commands themselves:

| Isolation | Example |
|---|---|
| PATH stubs | curl/w3m/systemctl/sudo/nvidia-smi/rocm-smi/lspci |
| Fixed system-only PATH | `mini_bin_dir_test.sh` fixes PATH to `/usr/bin:/bin` and stubs opencode as a shell function |
| Shell-function stubs | `ollama_systemd_failure_test.sh` neutralises systemctl and sudo with functions |
| None needed | `model_flag_test.sh` — its flag guard fires before any probe |

| When you touch… | Do |
|---|---|
| provider code | Run `tests/test_provider.sh` first. |
| webfetch capture/truncation | Compare output byte for byte against the fixture with zero, one and multiple trailing newlines, below and at the cap. Preserve newlines with a capture sentinel, keep converter failures non-zero, test Python character slicing with multibyte input under `LC_ALL=C`. |
| `mini remote` key prompt | `tests/remote_key_test.sh` pins only that prompt. `MINI_YES=1`: prompt skipped, nothing read from stdin, empty `0600` key file written. Without it: key read from stdin, lands in the `0600` key file. Host GPU probes are stubbed, so the result is machine-independent. |

Checked by hand (`bin/check` covers the first two):

```bash
bash -n bin/mini lib/*.sh platforms/*.sh install.sh   # syntax
shellcheck -x --source-path=lib --source-path=platforms \
  -e SC2015 -e SC2016 bin/mini lib/*.sh platforms/*.sh install.sh
mini doctor                                           # must be clean
mini "what is wrong with this machine"                # end to end
mini model qwen2.5-coder:3b && mini "check disk"      # a second model
```

Test on a box with no GPU and one with a GPU — the selection paths differ.

## CI

`.github/workflows/shell-checks.yml`: exactly **one job**, `shell-checks`, named
in `.dz/maintainer/maintainer.yml` under `pr.required_checks` — red blocks
auto-merge. Steps: checkout → ensure ShellCheck installed (CI installs it when
the runner lacks it) → test step → ShellCheck step.

| Constraint | Detail |
|---|---|
| Single test step | The suite rides in the SAME step as the `bash -n` loop, `Check Bash syntax and run the offline test suite`. Never add a second job or a second `run:` step for tests. |
| Step body, in order | `bash -n` loop (`bin/mini lib/*.sh platforms/*.sh install.sh`) → `bash .github/run-tests.sh` → probe driving the runner with a deliberately failing member (proves it can fail) → `bash .github/run-tests_test.sh` (verdict self-test). |
| Red = red | A member exiting nonzero aborts the step (GitHub's `bash` runs with `-e`). No `continue-on-error`. |
| Offline | Installs no ollama/opencode, references no secret, needs no network. |
| ShellCheck step | `shellcheck -x --source-path=lib --source-path=platforms -e SC2015 -e SC2016 bin/mini lib/*.sh platforms/*.sh install.sh`. `-x` follows files `bin/mini` sources at runtime; `--source-path` says where they live, so a moved/renamed lib file fails the build. `SC2015` (`a && b \|\| c` one-liners) and `SC2016` (single-quoted text with literal backticks) are house idioms, off; every other code is enforced, warnings and errors included. |
