# Architecture

mini is a wrapper. opencode is the agent runtime, ollama serves the model, and
mini is the bash that configures both correctly. Nothing here reimplements what
either of those already does.

```
mini (bash)
 │
 ├─ lib/detect.sh ──── hardware → memory budget
 ├─ lib/models.sh ──── budget → model → num_ctx variant
 ├─ lib/ollama.sh ──── server lifecycle (systemd or a child process)
 └─ lib/opencode.sh ── writes ~/.cache/mini/opencode.json, execs opencode
                              │
                              └─ opencode runs in YOUR cwd, config from MINI_HOME
                                        │
                                        └─ the provider in opencode.json
                                             ├─ ollama → http://localhost:11434/v1
                                             └─ mini-remote → the remote endpoint
```

## Two directories

| | Install root | State |
|---|---|---|
| Where | `~/.local/share/mini` | `~/.cache/mini` (`$MINI_HOME`) |
| Holds | `bin/ lib/ share/ platforms/` | config, `AGENTS.md`, memories, tools, logs |
| Owned by | the installer, replaced on update | you |

The rule that keeps updates safe: program files are never read from state, and
state is never written to the install root.

`~/.cache/mini` is effectively an opencode project that follows you between
directories. opencode itself runs in your cwd — that is where the work happens.

## Boot sequence

`mini` with no arguments:

1. Resolve the install root by following the `~/.local/bin/mini` symlink.
2. Source `lib/*.sh`.
3. `ensure_ready` — config exists, ollama is up (start it if not).
4. `exec opencode -m <provider>/<model> --auto` with `OPENCODE_CONFIG` pointed
   at the live `$MINI_HOME/opencode.json` — or, under a run-only `--model <id>`
   override, at a run-scoped config of that launch's own (a per-invocation temp
   file, so two `mini --model` runs never share one), leaving the
   stored model and the live config untouched — and a `PATH` that starts with
   mini's own bin dir and `$MINI_HOME/tools`, followed by the `PATH` mini
   inherited. The provider follows the configured mode: `ollama/<model>`
   locally (the ctx variant mini built), `mini-remote/<model>` after
   `mini remote` — in which case the requests go to the remote endpoint and no
   local model is involved.

`exec` matters: mini replaces itself with opencode, so there is no wrapper
process sitting between you and the TUI eating signals.

## The agent's PATH

mini hands opencode one environment, and it is built in one place: the three
launch sites in `lib/opencode.sh` — `opencode_launch`, `opencode_run`,
`opencode_web`. The `PATH` in it is mini's own two directories in front of
yours:

- **`<install root>/bin`** — the directory holding the `mini` CLI that resolved
  the install root. The agent's shell therefore runs the *same* mini that
  generated the config, whatever `PATH` happened to launch mini from. An
  agent-run `mini remember` and an agent-run `mini sudo` act on the same
  install as the session itself.
- **`$MINI_HOME/tools`** — the shell tools (`websearch`, `webfetch`,
  `sysreport`).
- **The inherited `PATH`, unchanged** — mini only prepends. It never
  rewrites, reorders or drops an entry of yours.

The path comes from the install root, not from `~/.local/bin` (the installer's
`MINI_BIN_DIR`), which the runtime never reads: `bin/mini` follows its own
symlink to find the root and everything else follows from that. No shell rc
file is read or written to make this work — the installer's one-time `PATH`
line for the `mini` command is the only rc edit mini ever makes.

## Model selection

`lib/detect.sh` produces a memory budget:

- GPU with ≥4GB VRAM → `VRAM − 1GB`, `ACCEL=gpu`
- otherwise → `60% of RAM`, `ACCEL=cpu`

Unmeasurable VRAM never inflates the budget. If `nvidia-smi` and `rocm-smi` are
both absent, a card found via `lspci` is named in the report but counts as zero
— a driver-less GPU cannot run anything.

For auto-selection, `lib/models.sh` walks `share/models.tsv` best → smallest and
takes the first row that fits. On CPU it skips every registry row before the
`qwen3:4b-instruct` cap row and then starts judging from that cap row: a 7B
model generates about 2.5 tokens a second on CPU, which is not an interactive
agent. The cap row itself is eligible — `qwen3:4b-instruct` is picked whenever
the budget is at least its 4000 MB. Below that the walk continues down the
registry and lands on `llama3.2:3b` (3000 MB) or `llama3.2:1b` (2000 MB).
GPU selection is uncapped and takes the first fitting row from the full
registry. `mini model <id>` overrides this auto-selection.

## The context variant

The single most important thing mini does.

Ollama's default context is 4k. opencode's tool definitions and system prompt
nearly fill that on their own, so tool calls get truncated and the agent appears
to randomly stop working mid-task. There is no error — it just degrades.

So mini never runs a base model. It builds a derived one:

```
FROM qwen2.5-coder:7b
PARAMETER num_ctx 32768
```

registered as `mini-qwen2.5-coder-7b:32k`. The context is chosen from the memory
budget, then capped at the model's native context.

`models_pick_ctx` picks the window from the budget in MB:

| Budget | Context |
|---|---|
| ≥20000 MB | 131072 (128k) |
| ≥12000 MB | 65536 (64k) |
| ≥6000 MB | 32768 (32k) |
| ≥3000 MB | 16384 (16k) |
| below 3000 MB | 8192 (8k) |

The result is then capped at the model's **native** context — the `max_ctx`
column of `share/models.tsv`. `qwen2.5-coder:7b` is a 32k architecture, so on
any budget the walk above gives it at most 32768: at 20000 MB the ladder asks
for 128k and the native ceiling cuts it back to 32768, and the same 32768 comes
out at 12000 MB and at 6000 MB. Below that it drops to 16384 at 3000 MB and
8192 under it. `qwen2.5-coder:7b` can therefore never yield a 64k or 128k
variant — asking for more than the architecture supports produces nothing,
because ollama honours the architecture limit.

A 128k window is reachable, but only on a model whose native context is at least
that wide: `devstral:24b`, `gpt-oss:20b`, `llama3.2:3b` and `llama3.2:1b`
(128k each), `qwen3-coder:30b` and `qwen3:4b-instruct` (256k). KV cache is not
free — 64k on a 3GB box would swap — which is why the ladder scales with the
budget.

One number in `models_pick_ctx` deserves care: `32768` is the **fallback
native context for a model that is not in the registry**, not a blanket cap on
the selected window. A registry model with a 256k or 128k native context still
gets 131072 at a 20000 MB budget.

No `SYSTEM` line is baked in. opencode sends its own system prompt, which would
shadow it; the brain belongs in `AGENTS.md` where it can be read and edited.

## Config generation

`opencode_write_config` writes `$MINI_HOME/opencode.json` by default. It takes
an optional destination and carry-from path: the run-only `--model` override
calls it with a run-scoped config of that launch's own — a per-invocation temp
file, so a second `mini --model` run cannot replace this run's config before
opencode reads it — as the destination, and the live config as the carry
source, so the override's variant is declared beside the live config, which is
never touched:

- `provider.ollama` via `@ai-sdk/openai-compatible` at `localhost:11434/v1`
- `model` + `small_model` both pointed at the variant
- `instructions` → `$MINI_HOME/AGENTS.md` and `$MINI_HOME/memories/*.md`
- `command` → the slash commands. `/remember` names the mini CLI by absolute
  path (`<install root>/bin/mini remember "…"`), so the command runs the CLI
  that wrote this config, not whichever `mini` happens to be on the agent's
  `PATH`.
- `autoupdate: false`, `share: disabled`

Regeneration never overwrites the live file. The fresh config is built in a
temp file of its own (`opencode.json.tmp.XXXXXX`) and renamed into place, so
two writers racing for the same destination never truncate each other's
half-written config; entries in the old config's `command` block whose keys are
not mini-managed — the user's own slash commands — are carried into it with
python3, the same opportunistic pattern as `opencode_validate_config`; the
result is validated, and only then does it replace the live file. Managed
commands always refresh to the current defaults. When merging is impossible —
no python3, or an old config that does not parse — the old file is kept as
`opencode.json.bak.XXXXXX` (a unique suffix for each fallback) and a warning
names that path before the fresh config takes over. Existing recovery backups
are never overwritten. Nothing the user added disappears silently.

mini never edits `~/.config/opencode/opencode.json`. It sets `OPENCODE_CONFIG`
instead, so a user who also runs opencode against a cloud provider keeps that
setup intact. The only global footprint is three tool files in
`~/.config/opencode/tools/`, namespaced `mini_*` so they cannot shadow a
built-in and change behaviour in unrelated projects.

## The prompt is composed, not shipped

`$MINI_HOME/AGENTS.md` = `share/prompts/base.md` + `share/prompts/<platform>.md`.

Base holds the role, the operating rules and the hard safety rules. The platform
file holds package manager, init system, firewall, log locations and the failure
modes specific to that distro. Adding a distro means adding one prompt file, not
forking a monolith.

A copy of the generated file is kept as `.agents-md-generated`. On update, mini
compares against it: identical means you never touched it and it can be
refreshed; different means it is yours, and the new version lands as
`AGENTS.md.new` instead.

## Tools

Each tool exists twice, deliberately:

| Layer | File | Why |
|---|---|---|
| Implementation | `share/tools/<name>` (bash) | Works from any shell, cron, or a script. No runtime. |
| Registration | `share/opencode-tools/mini_<name>.ts` | opencode only loads TS/JS tool definitions. |

The TS file is a five-line `Bun.$` shell-out. All logic stays in bash, so the
capability is testable without starting an agent, and the model can reach it
either as a tool call or a plain command on `PATH`.

## Platforms

`detect_os` maps `/etc/os-release` onto a platform id; `platforms/<id>.sh`
implements five functions. Doctor's Host tools step gets its missing-tool
fix lines from `platform_install_cmd_for`, which is why nothing in `lib/`
may mention a package manager — if it does, that is the bug. See
[platforms/README.md](../platforms/README.md).

## Dependencies

`curl`, coreutils, `awk`, `sed`, `grep`. That is the whole list.

`python3` is used opportunistically for better HTML parsing and every path has a
pure-shell fallback. No `jq`: mini generates JSON with `printf`. Apart from
`opencode_validate_config`'s check of the generated file and the merge's
read-back of the file it just generated, the only place mini parses JSON is the
old config's `command` block, to carry a user's custom slash commands across a
regeneration. Without python3 there is no merge: the old config is kept as
a unique `opencode.json.bak.XXXXXX` and the fresh one written beside it, so a minimal box loses
convenience, never data.
