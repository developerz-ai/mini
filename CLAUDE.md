# mini

A bash wrapper that configures **opencode + ollama** into a local Linux
sysadmin agent. No cloud provider, no API key.

**It is a wrapper, not a framework.** opencode is the agent runtime, ollama runs
the model. mini's job is picking a model that fits the hardware, giving it a
context window that works, and handing it a good system prompt and a few tools.
When tempted to build something here, check first whether opencode already does
it.

**Stack:** bash + `curl`/coreutils/`awk`/`sed` · opencode (agent runtime) ·
ollama (model server) · python3 optional (HTML parsing, always with a fallback) ·
shellcheck for lint.

## Commands

| Command | What |
|---|---|
| `bin/setup` | One-command setup. Idempotent. Runs `mise install` if mise exists — best-effort: a failing mise warns on stderr (naming mise and the manual fix) and setup goes on, because mise's exit code is not setup's verdict. Then installs only what `command -v` shows missing among `shellcheck curl python3 ss ps` (apt packages `shellcheck curl ca-certificates python3 iproute2 procps`) — `apt-get` directly as root, `sudo -n apt-get` otherwise. With nothing missing it never calls apt-get or sudo; with no usable installer it names the missing tools and exits non-zero. |
| `bin/dev` | One-command dev. Runs `bin/mini models`. |
| `bin/check` | **The gate.** `bash -n` over the 14 files `bin/check` lists — `bin/mini bin/setup bin/dev bin/check bin/stop .githooks/pre-commit lib/*.sh platforms/*.sh install.sh` — then `bash .github/run-tests.sh`, `bash .github/run-tests_test.sh`, then ShellCheck over the same 14 files. `bin/check <files…>` is a scoped run: `bash -n` + ShellCheck on those files only, suite skipped. Files not linted by ShellCheck (`share/tools/*`, `tests/*.sh`, `.github/*.sh`): test scripts are executed so syntax errors turn the suite red, but only `share/tools/*` code unreached by tests can hide a syntax error. |
| `bin/stop` | One-command stop. Runs `bin/mini stop \|\| true`. |
| `bash .github/run-tests.sh` | The whole offline suite, every `tests/*.sh`. |
| `mini doctor` | Every runtime check, each prints its fix command. Must be clean. |

`bin/check` exit codes:

| Code | Meaning |
|---|---|
| `0` | Full gate passed — commit. |
| `75` | A resource the gate needs is unreachable (no `shellcheck`) — refused to grade; blame the environment, fix with `bin/setup`. |
| `79` | Scoped run (`bin/check <files…>`) passed — commit; CI grades the rest. |
| other | The gate ran and the change is red. |

`.githooks/pre-commit` execs `bin/check`. Activate once per clone:
`git config core.hooksPath .githooks`.

## Layout

| Path | What |
|---|---|
| `bin/mini` | CLI + dispatch. The only entry point of the product. |
| `bin/setup` `bin/dev` `bin/check` `bin/stop` | Dev-workflow scripts (see Commands), not part of the product. |
| `lib/common.sh` | log/ask/config helpers. Sourced first, no dependencies. |
| `lib/detect.sh` | OS + hardware → `OS_PLATFORM`, `BUDGET_MB`, `ACCEL` |
| `lib/models.sh` | Registry, hardware fit, the `num_ctx` variant build |
| `lib/ollama.sh` | Server lifecycle |
| `lib/opencode.sh` | Generates `opencode.json`, launches opencode |
| `lib/doctor.sh` | Every check, each with the command that fixes it |
| `platforms/<id>.sh` | Distro-specific package handling |
| `share/prompts/base.md` | Platform-neutral system prompt |
| `share/prompts/<id>.md` | Distro-specific system prompt |
| `share/tools/*` | `websearch` `webfetch` `sysreport` — plain bash |
| `share/opencode-tools/*.ts` | TS definitions that expose those to opencode |
| `share/models.tsv` | The model registry. Dated. |
| `install.sh` | curl-to-bash entry point |
| `tests/` | Offline bash checks. No framework. |
| `.github/run-tests.sh` | The suite runner (lives outside `tests/` on purpose). `run-tests_test.sh` is its verdict self-test. |
| `.github/workflows/shell-checks.yml` | CI: the single `shell-checks` job. |
| `.githooks/` | `pre-commit` → `bin/check`. |
| `.dz/` | developerz.ai config: `maintainer/maintainer.yml` (`pr.required_checks`), `briefs/`, `onboarding/`. |

Runtime state is `~/.cache/mini/` (`$MINI_HOME`). The sole program-file exception
is `$MINI_HOME/tools`, where mini installs shipped scripts copied from
`share/tools`. Never write other program files in `$MINI_HOME`; never store or
read runtime state in the install root.

## Rules

- **Bash only** for anything mini itself runs. `curl`, coreutils, `awk`, `sed`.
  No jq, no python dependency — python3 is used opportunistically for better
  HTML parsing and always has a fallback.
- `set -euo pipefail` in every executable. Quote everything.
- Distro-specific logic goes in `platforms/`, never in `lib/`. If a `lib/` file
  mentions `apt`, that is a bug.
- Every doctor check prints the exact command that fixes it. A check with no fix
  is not a check.
- Never touch `~/.config/opencode/opencode.json` — the user's own opencode setup
  is off limits. mini uses `OPENCODE_CONFIG` to point at its own.
- Custom tools installed globally must be namespaced `mini_*`. Shadowing an
  opencode built-in would change behaviour in the user's unrelated projects.
- Never clobber a user-edited `AGENTS.md`. Compare against
  `.agents-md-generated` to tell "unchanged" from "edited".
- Nothing mini starts may listen on a public interface by default. ollama is
  pinned to loopback; opencode's server modes are loopback plus a generated
  password. `--lan` is the only way out, and it prints a warning.
- Secrets live in their own `0600` file (`$MINI_HOME/secret`), never in
  `config`, which `mini config` prints.
- Escalate with `sudo -n` everywhere. A bare `sudo` in a code path the agent can
  reach will hang forever with no tty.
- Do not use git worktrees — work directly in this checkout (see Note).

## The things that actually make it work

1. **Context window.** Ollama defaults to 4k. opencode's tool definitions nearly
   fill that, so tool calls truncate and the agent silently degrades. mini never
   runs a base model — it builds `mini-<base>:<n>k` with `num_ctx` baked in.
   If someone reports "it stops mid-task", this is the first suspect.
   `num_ctx` above a model's native context does nothing — ollama honours the
   architecture limit. Verify with `ollama show <m> | grep 'context length'`
   before putting a number in `models.tsv`.
2. **The prompt.** `share/prompts/` is where a 7B model gets its judgment. Keep
   it dense and imperative — short rules, exact commands, tables over prose.
   Small models follow terse instructions better than explanatory ones. It is
   also processed on every first turn, so length costs real seconds on CPU.
3. **Sudo.** opencode's bash tool has no tty, so a password-prompting `sudo`
   hangs. Without passwordless sudo the agent can read but not act — which is
   why `mini sudo` exists and why doctor treats it as a hard failure.
4. **ollama tuning.** `OLLAMA_NUM_PARALLEL=1` (opencode fires a title request
   alongside the main one; two slots double KV and thrash on CPU),
   `OLLAMA_KEEP_ALIVE=30m` (the 5m default unloads several GB between turns),
   and `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` (halves what a
   context window costs, which is what makes 128k affordable). Applied via a
   systemd drop-in, or env vars when mini owns the process.
5. **Request timeouts.** `timeout`/`chunkTimeout` in the provider options. The
   defaults kill a cold CPU request mid-prefill and the symptom is an empty
   response with nothing logged — it reads as a broken model. Measured: a
   5,839-token prompt took 185s to prefill at ~31 tok/s.
6. **Prompt size is the CPU latency budget.** Every enabled tool ships its
   schema on every request. Trimming opencode's built-ins to bash/read/write/
   edit plus tightening the prompts took a request from 9,300 to 5,838 tokens —
   about two minutes off every cold turn. Check the real number in the ollama
   journal: `task.n_tokens`.

## Changing things

- **New model**: a row in `share/models.tsv`. Keep it ordered best → smallest;
  selection takes the first row that fits. Re-date the header comment. Verify
  both facts before adding it — `ollama show <m>` must list `tools`, and the
  context column must be its real `context length`. **No reasoning models**:
  they spend the output budget on a `<think>` block, and on CPU that is minutes
  per turn (qwen3:0.6b returned empty content entirely). Prefer `-instruct`.
- The registry is tab-separated and hand-aligned; `models_rows` squeezes
  repeated tabs so a double tab cannot shift every field after it.
- **New platform**: see `platforms/README.md`. Two files, no registry to edit.
- **New tool**: bash script in `share/tools/`, TS wrapper in
  `share/opencode-tools/`, a row in the table in `share/prompts/base.md`, and a
  check in `lib/doctor.sh`.
- **New slash command**: the `command` block in `opencode_write_config`.

## Testing

Plain bash tests under `tests/`, no framework. One command runs them all:

```bash
bash .github/run-tests.sh    # the whole offline suite
```

With no arguments the runner's member list is every `tests/*.sh` — all twelve
today. Explicit script paths as arguments override that list. Each member runs
as its own process (`bash "$t"`), so one member's exported environment cannot
leak into the next. Every member runs even when an earlier one fails. The
verdict is the **exit code alone** — never grep the output for `FAIL`/`SKIP`. A
script that prints `SKIP` under its own contract (no python3, running as root)
still exits 0 and stays green.

| Script | What it pins |
|---|---|
| `check_test.sh` | `bin/check` — its reserved exit codes: 75 (no shellcheck), 79 (scoped run), 1 (syntax error) |
| `host_memory_test.sh` | `write_host_memory` — the writer of `$MINI_HOME/memories/00-host.md` |
| `init_test.sh` | init-system detection + doctor's Init step |
| `mini_bin_dir_test.sh` | the PATH the agent inherits, and the `/remember` command |
| `model_flag_test.sh` | the missing-argument refusal of `mini --model` |
| `ollama_bind_test.sh` | doctor's ollama bind verdict, read from the observed listener |
| `ollama_systemd_failure_test.sh` | systemd rebind and stop refusals — a failure is reported, not swallowed |
| `opencode_config_test.sh` | the `opencode.json` regeneration contract (skips without python3) |
| `remote_key_test.sh` | the API-key prompt of `mini remote` |
| `setup_test.sh` | `bin/setup` — installs only what is missing, root vs `sudo -n`, clear failure with no installer, best-effort `mise install` |
| `test_provider.sh` | provider and launch selection |
| `webfetch.sh` | webfetch truncation + failure contract (PATH-stubbed, no network) |

Every test is hermetic: its own `mktemp` sandbox, no live model service, no
credential, no network. Scripts isolate external commands themselves — PATH
stubs for curl/w3m/systemctl/sudo/nvidia-smi/rocm-smi/lspci, fixed system-only
PATHs, or shell-function stubs — and literal URLs are never fetched. E.g.
`model_flag_test.sh` needs no stub because the flag guard fires before any
probe; `mini_bin_dir_test.sh` fixes PATH to `/usr/bin:/bin` and stubs opencode as
a shell function; `ollama_systemd_failure_test.sh` neutralises systemctl and
sudo with shell functions.

- `tests/test_provider.sh` — run it first when you touch provider code.
- `tests/webfetch.sh` — when changing capture or truncation, compare output byte
  for byte against the fixture with zero, one, and multiple trailing newlines,
  below and at the cap. Preserve newlines with a capture sentinel, keep
  converter failures non-zero, and test Python character slicing with multibyte
  input under `LC_ALL=C`.
- `tests/remote_key_test.sh` — pins only the API-key prompt of `mini remote`.
  With `MINI_YES=1` the prompt is skipped, nothing is read from stdin, and an
  empty `0600` key file is written. Without `MINI_YES` the prompt reads the key
  from stdin and that key lands in the `0600` key file. It stubs the host GPU
  probes, so the result does not depend on the machine.

Checked by hand (or `bin/check` for the first two):

```bash
bash -n bin/mini lib/*.sh platforms/*.sh install.sh   # syntax
shellcheck -x --source-path=lib --source-path=platforms \
  -e SC2015 -e SC2016 bin/mini lib/*.sh platforms/*.sh install.sh  # if available
mini doctor                                           # must be clean
mini "what is wrong with this machine"                # end to end
mini model qwen2.5-coder:3b && mini "check disk"      # a second model
```

Test on a box with no GPU and on one with a GPU — the selection paths differ.

## CI

`.github/workflows/shell-checks.yml` has exactly one job, `shell-checks`. It is
listed in `.dz/maintainer/maintainer.yml` under `pr.required_checks`, so a red
run blocks auto-merge.

- **Step constraint:** the offline suite rides in the SAME step as the `bash -n`
  loop — `Check Bash syntax and run the offline test suite`. The workflow must
  not grow a second job or a second `run:` step for tests; do not split it out.
  That step body runs, in order: the `bash -n` loop, `bash .github/run-tests.sh`,
  a probe driving the runner with a deliberately failing member (proves the
  runner can fail), and `bash .github/run-tests_test.sh` (the runner's
  verdict-contract self-test).
- A member exiting nonzero aborts the step (GitHub's `bash` runs with `-e`), so a
  red suite is a red job. No step sets `continue-on-error`. The step installs no
  ollama/opencode, references no secret, needs no network.
- A second step runs ShellCheck: `-x --source-path=lib --source-path=platforms
  -e SC2015 -e SC2016`. `-x` follows the files `bin/mini` sources at runtime;
  `--source-path` says where they live — so a moved or renamed lib file fails
  the build instead of quietly dropping out. `SC2015` and `SC2016` are off
  because both are house idioms: `a && b || c` one-liners, and single-quoted
  text carrying literal backticks. Every other code is enforced, warnings and
  errors included. CI installs ShellCheck itself when the runner lacks it.

## Docs

`README.md` is for users. `docs/` covers usage, architecture, models, tools and
prompts. Update the relevant one in the same change; a stale doc about a wrapper
this small is worse than none.

## Note

Do not use git worktrees — work directly in this checkout. If a task is big
enough to need subagents, run them as a team in this same checkout: split the
work into disjoint pieces so no two agents touch the same files.
