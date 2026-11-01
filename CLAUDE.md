# mini

A bash wrapper that configures **opencode + ollama** into a local Linux
sysadmin agent. No cloud provider, no API key.

**It is a wrapper, not a framework.** opencode is the agent runtime, ollama runs
the model. mini's job is picking a model that fits the hardware, giving it a
context window that works, and handing it a good system prompt and a few tools.
When tempted to build something here, check first whether opencode already does
it.

## Layout

| Path | What |
|---|---|
| `bin/mini` | CLI + dispatch. The only executable entry point. |
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
| `tests/` | Offline bash checks. No framework — run them by hand. |

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

There is no test framework — the checks are plain bash scripts you run by hand.

```bash
bash tests/remote_key_test.sh    # offline, no network, no framework
```

`tests/remote_key_test.sh` pins one thing: the API-key prompt of `mini remote`.
With `MINI_YES=1` the prompt is skipped, nothing is read from stdin, and an
empty `0600` key file is written. Without `MINI_YES` the prompt still reads the
key from stdin and that key lands in the `0600` key file. Nothing else is
covered. It stubs the host GPU probes, so the result does not depend on the
machine it runs on.

The wrapper itself is checked by hand:

```bash
bash -n bin/mini lib/*.sh platforms/*.sh install.sh   # syntax
shellcheck bin/mini lib/*.sh                          # if available
mini doctor                                           # must be clean
mini "what is wrong with this machine"                # end to end
mini model qwen2.5-coder:3b && mini "check disk"      # a second model
```

Test on a box with no GPU and on one with a GPU — the selection paths differ.

## Docs

`README.md` is for users. `docs/` covers usage, architecture, models, tools and
prompts. Update the relevant one in the same change; a stale doc about a wrapper
this small is worse than none.

## Note

Do not use git worktrees — work directly in this checkout. If a task is big
enough to need subagents, run them as a team in this same checkout: split the
work into disjoint pieces so no two agents touch the same files.
