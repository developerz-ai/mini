# mini

**A local AI agent that sets up and debugs your Linux box. No cloud account, no API key, no subscription.**

```bash
curl -fsSL https://raw.githubusercontent.com/developerz-ai/mini/main/install.sh | bash
```

That one command installs [ollama](https://ollama.com) and
[opencode](https://opencode.ai), looks at your hardware, recommends a model that
will actually run on it, pulls it, and wires the whole thing together. Then:

```bash
mini                                    # open the agent in the current directory
mini "install docker and add me to the docker group"
mini "nginx returns 502, find out why"
mini "what is eating my disk"
```

Everything runs on your machine. Nothing leaves it.

---

## Why

You just installed Linux on a laptop. Or spun up a fresh VPS. Either way you
want docker, your toolchain, a firewall that will not lock you out, a couple of
services — and normally that is an hour of tabbing between a terminal and six
documentation pages.

Or something breaks at 2am and you start the same ritual — `systemctl status`,
`journalctl`, `df -h`, guess, repeat.

Same tool for both: a new laptop, a dev machine, a VPS, a dedicated box. If it
runs Debian or Ubuntu, mini works there.

`mini` is a small agent that does that for you, on the box, with a model running
locally. It is deliberately **a thin wrapper**: opencode is the agent runtime,
ollama runs the model, and mini is the ~600 lines of bash that configures both
correctly so you do not have to.

The configuration is the product. Getting a local model to behave as a competent
sysadmin takes a specific context window, a specific system prompt, and a few
tools it does not ship with — and getting any of those wrong gives you an agent
that hallucinates commands and truncates halfway through a task.

## What you get

- **Hardware-aware model choice.** Reads VRAM (or falls back to RAM), picks the
  best model that fits, refuses to put a 24B model on a CPU where it would
  produce two tokens a second.
- **A context window that works.** Ollama defaults to 4k. opencode's tool
  definitions alone nearly fill that, so tool calls truncate and the agent
  "stops working" for no visible reason. mini builds a derived model with
  `num_ctx` baked in — as much as the model and your memory allow.
- **A distilled Linux brain.** An `AGENTS.md` composed from a platform-neutral
  base plus a Debian-specific module: apt patterns, systemd, the order to check
  things in when a box misbehaves, and the rules that stop it locking you out.
- **Tools a shell does not have.** Web search and page fetching (no API key),
  plus a one-shot host health snapshot.
- **Memory.** Facts about the machine persist across sessions.
- **Yolo by default.** Auto-approves its own actions, because approving every
  `ls` defeats the point. `mini --safe` restores the prompts.

## Install

Requires a Debian-family distro — Debian, Ubuntu, Zorin, Mint, Pop!_OS,
Raspberry Pi OS. Other distros: see [platforms/README.md](platforms/README.md).

```bash
# one-liner
curl -fsSL https://raw.githubusercontent.com/developerz-ai/mini/main/install.sh | bash

# or from a checkout
git clone https://github.com/developerz-ai/mini && cd mini && ./install.sh
```

The installer asks one question — which model — and defaults to the right answer
for your hardware. `MINI_YES=1` accepts it non-interactively.

## Use

```bash
mini                          # interactive, in whatever directory you are in
mini "<task>"                 # one shot
mini -c                       # continue the last session
mini --safe "<task>"          # ask before each action
```

Built-in commands inside a session:

| Command | Does |
|---|---|
| `/diag` | Full diagnosis, worst problem first |
| `/harden` | Baseline VPS hardening without locking you out |
| `/devbox <stack>` | Set the box up for development |
| `/ports` | What is listening, and should it be |
| `/space` | Find and reclaim disk |
| `/svc <unit>` | Debug a systemd service |

Management:

| Command | Does |
|---|---|
| `mini doctor` | Check everything, print the fix for whatever is broken |
| `mini models` | What fits this box, what is pulled, what is current |
| `mini model <id>` | Switch model — pulls it and rebuilds the context variant |
| `mini remember "<fact>"` | Save a durable fact about this machine |
| `mini memories` | Show what it remembers |
| `mini web` | Browser UI — loopback, with a generated password |
| `mini password` | Show that password |
| `mini sudo` | Enable passwordless sudo so the agent can actually act |
| `mini status` / `serve` / `stop` | The ollama server |
| `mini update` | Update opencode, ollama and the model |
| `mini config` | Print the active configuration |

## How it works

```
mini (bash)
 ├── detects hardware ──── picks a model that fits
 ├── ollama ────────────── runs the model, localhost:11434
 └── opencode ─────────── the agent runtime, launched in YOUR cwd
        └── reads its config from ~/.cache/mini/
```

`~/.cache/mini/` is effectively an opencode project that follows you around:

```
~/.cache/mini/
├── config              # chosen model, context size
├── opencode.json       # provider, model, instructions, slash commands
├── AGENTS.md           # the brain: base prompt + platform prompt
├── memories/
│   ├── 00-host.md      # OS, CPU, RAM, GPU, sudo — refreshed on setup
│   └── 10-learned.md   # what you told it to remember
├── tools/              # websearch, webfetch, sysreport (bash)
└── logs/
```

mini **never edits `~/.config/opencode/opencode.json`**. It writes its own config
and points `OPENCODE_CONFIG` at it, so if you also use opencode with a cloud
provider, that setup is untouched. The one thing it does add globally is three
custom tools in `~/.config/opencode/tools/`, all namespaced `mini_*` so they
cannot shadow an opencode built-in.

Change the brain by editing `~/.cache/mini/AGENTS.md` — mini will not overwrite
a file you have edited.

## Models

`mini models` shows the registry against your hardware. Selection is by memory
budget: VRAM minus 1GB on a GPU, 60% of RAM on CPU. On CPU it caps at `qwen3:4b-instruct`, since
anything larger is too slow to be interactive — override with `mini model <id>`
if you disagree.

| Model | Size | Context | For |
|---|---|---|---|
| `qwen3-coder:30b` | 19GB | 256k | Best local agentic coder. 24GB GPU. |
| `devstral:24b` | 14GB | 128k | SWE-agent tuned, excellent multi-step tool use. |
| `gpt-oss:20b` | 13GB | 128k | Strong tool calling, good generalist. |
| `qwen2.5-coder:14b` | 9GB | 32k | Code-specialised. The 12GB-GPU sweet spot. |
| `qwen2.5-coder:7b` | 4.7GB | 32k | Code-specialised baseline. 8GB GPU. |
| `qwen3:4b-instruct` | 2.5GB | 256k | **The CPU default.** Best small all-rounder. |
| `llama3.2:3b` | 2.0GB | 128k | Small generalist, dependable tool calling. |
| `llama3.2:1b` | 1.3GB | 128k | Non-thinking, still calls tools. Simple tasks only. |

Curated 2026-07, every context figure verified with `ollama show`.
`mini models --refresh` re-checks availability upstream.

Two things decide whether a model can do this job, and neither is a benchmark
score:

- **Tool calling.** The work is run-command → read-output → decide. A model that
  drops tool calls on turn six is worse than a smaller one that stays coherent.
- **No thinking.** Reasoning models spend their output budget on a `<think>`
  block before saying anything. Measured here, `qwen3:0.6b` used the *entire*
  budget thinking and returned empty content. Every registry entry answers
  directly; that is why the default is `qwen3:4b-instruct` and not plain
  `qwen3:4b`.

Check a candidate before trusting it:

```bash
ollama show <model> | grep -A5 Capabilities   # needs "tools"
ollama show <model> | grep 'context length'   # the real ceiling
```

Anything ollama can pull works, including GGUFs straight from HuggingFace:

```bash
mini model hf.co/unsloth/Qwen3-4B-Instruct-GGUF:Q4_K_M
```

## No GPU? Move only the inference

Local models on CPU are slow — a few tokens per second, and minutes on the first
turn of a session while the prompt is processed. If that is not workable, point
mini at any OpenAI-compatible endpoint. The brain, tools, memory and slash
commands stay exactly the same; only where the tokens come from changes.

```bash
mini remote https://openrouter.ai/api/v1 qwen/qwen3-coder sk-or-...
mini remote                       # interactive, hidden key prompt
mini local                        # back to the local model
```

Works with OpenRouter, Groq, Together, DeepInfra, a vLLM box on your LAN, or
another machine's ollama (`http://192.168.1.10:11434/v1`, no key needed).

The key is stored `0600` in `~/.cache/mini/api-key`, and the generated config is
`0600` too since it embeds the key.

## Sudo — the thing that decides whether it works at all

opencode runs commands **without a terminal**. A `sudo` that wants a password
cannot prompt: it fails with "no tty present", or hangs. So on a box where sudo
asks for a password, the agent can read everything and change nothing.

```bash
mini doctor      # tells you which mode you are in
mini sudo        # grants passwordless sudo, after showing you what that means
```

`mini sudo` writes `/etc/sudoers.d/90-mini-<user>`, validated with `visudo -c`
before install. Undo with `sudo rm /etc/sudoers.d/90-mini-<user>`.

Right for a dev box, a VPS you own, or a VM you can rebuild. Wrong for a shared
or production machine — there, use `mini --safe` and run privileged commands
yourself. The agent is told to check `sudo -n true` first and to hand you the
command rather than hang.

## Network exposure

Two things could listen, and mini locks down both:

- **ollama** is pinned to `127.0.0.1:11434`. An ollama on a public interface has
  no authentication of any kind — anyone who finds it can run inference on your
  hardware. `mini doctor` fails loudly if it sees a `0.0.0.0` bind, and
  `mini serve --local` puts it back.
- **opencode's server** (`mini web`, `mini headless`) binds to loopback and gets
  a 32-character password generated on first use, stored `0600` in
  `~/.cache/mini/secret`. `--lan` opens it to your network; the password is what
  makes that survivable, because that endpoint can run commands on the box.

```bash
mini web             # browser UI on localhost, prints the password
mini password        # show it again
mini web --lan       # reachable from your LAN, still authenticated
```

## Safety

mini runs opencode with auto-approval on. That is the intended mode: a local
model on your own box, doing work you asked for. Two things follow from it —

- The system prompt carries hard rules the model is told never to break: never
  lock you out of SSH, never `rm -rf` a path it has not listed, never pipe an
  unknown URL into a shell, back up configs before editing, stop and ask before
  destroying data.
- A small local model is still a small local model. On a production box, use
  `mini --safe` and read what it proposes.

## Requirements

- Debian-family Linux
- `curl`, and `sudo` if you want it to install packages
- ~6GB free disk for a 7B model
- 8GB RAM minimum, a GPU if you want it to feel fast

## License

MIT
