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
                                        └─ http://localhost:11434/v1  (ollama)
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
4. `exec opencode -m ollama/<variant> --auto` with `OPENCODE_CONFIG` pointed at
   `$MINI_HOME/opencode.json` and `$MINI_HOME/tools` prepended to `PATH`.

`exec` matters: mini replaces itself with opencode, so there is no wrapper
process sitting between you and the TUI eating signals.

## Model selection

`lib/detect.sh` produces a memory budget:

- GPU with ≥4GB VRAM → `VRAM − 1GB`, `ACCEL=gpu`
- otherwise → `60% of RAM`, `ACCEL=cpu`

Unmeasurable VRAM never inflates the budget. If `nvidia-smi` and `rocm-smi` are
both absent, a card found via `lspci` is named in the report but counts as zero
— a driver-less GPU cannot run anything.

`lib/models.sh` walks `share/models.tsv` best → smallest and takes the first row
that fits. On CPU it skips everything above `qwen2.5-coder:7b`: a 24B model on
CPU produces a couple of tokens a second, which is not an interactive agent.
`mini model <id>` overrides this.

## The context variant

The single most important thing mini does.

Ollama's default context is 4k. opencode's tool definitions and system prompt
nearly fill that on their own, so tool calls get truncated and the agent appears
to randomly stop working mid-task. There is no error — it just degrades.

So mini never runs a base model. It builds a derived one:

```
FROM qwen2.5-coder:7b
PARAMETER num_ctx 65536
```

registered as `mini-qwen2.5-coder-7b:64k`. The context is chosen from the memory
budget (64k / 32k / 16k / 8k, capped at what the model supports) because KV
cache is not free — 64k on a 3GB box would swap.

No `SYSTEM` line is baked in. opencode sends its own system prompt, which would
shadow it; the brain belongs in `AGENTS.md` where it can be read and edited.

## Config generation

`opencode_write_config` writes `$MINI_HOME/opencode.json`:

- `provider.ollama` via `@ai-sdk/openai-compatible` at `localhost:11434/v1`
- `model` + `small_model` both pointed at the variant
- `instructions` → `$MINI_HOME/AGENTS.md` and `$MINI_HOME/memories/*.md`
- `command` → the slash commands
- `autoupdate: false`, `share: disabled`

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
pure-shell fallback. No `jq`: mini generates JSON with `printf` and never parses
any, which is why it survives on a minimal box.
