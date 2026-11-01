# Using mini

## The two ways in

```bash
mini                      # interactive, in whatever directory you are in
mini "<task>"             # one shot: answers, does the work, exits
```

`mini` on its own opens opencode's TUI. `mini "…"` is for the things you would
otherwise search for — it runs, prints, and gets out of the way.

The agent works in **your current directory**. Its brain and memory come from
`~/.cache/mini/`, which follows you everywhere. So `cd /etc/nginx && mini "why
is this config rejected"` puts it exactly where you are.

## Things worth asking it

**Setting a box up**

```bash
mini "install docker, add me to the docker group, verify it works"
mini "set up a python 3.12 dev environment with uv and ruff"
mini "install postgres 16, create a user 'app' and a database 'app_dev'"
mini "configure this box for node development, use the official nodesource repo"
```

**Debugging**

```bash
mini "what is wrong with this machine"
mini "nginx returns 502, find out why"
mini "the box was slow at 3am, what happened"
mini "why did the last apt upgrade fail"
mini "something is filling the disk, find it"
```

**Answering questions about the host**

```bash
mini "what is listening on port 8080 and which unit owns it"
mini "is this box behind a firewall, and what is open"
mini "when was this machine last rebooted and why"
mini "which services start at boot that I do not need"
```

Ask in whatever words come out. It reads the machine before answering.

## Slash commands

Inside the interactive session:

| Command | Does |
|---|---|
| `/diag` | Full diagnosis, worst problem first, fixes nothing |
| `/harden` | Baseline VPS hardening — SSH, firewall, fail2ban, auto-updates |
| `/devbox <stack>` | Set the box up for development |
| `/ports` | Listening sockets with owning processes, flags what is public |
| `/space` | Rank what is eating disk by reclaimable bytes |
| `/svc <unit>` | Debug a systemd service end to end |
| `/remember <fact>` | Save a fact about this machine |

Add your own in the `command` block of `~/.cache/mini/opencode.json`.

## Approvals

mini auto-approves by default. A local model on your own box asking permission
to run `ls` is friction with no upside.

```bash
mini --safe "remove old kernels"     # ask before each action
```

Use `--safe` on production. The system prompt has hard rules against the truly
destructive things, but a 7B model is still a 7B model.

## Sudo

This is the setting that decides whether mini is useful or just informative.

opencode runs commands with no terminal attached. `sudo` therefore **cannot ask
you for a password** — it fails with "no tty present" or hangs. On a box where
sudo prompts, the agent can diagnose everything and fix nothing.

```bash
mini doctor      # reports which mode you are in
mini sudo        # grant passwordless sudo (explains the tradeoff, then asks)
```

Four modes:

| Mode | What the agent can do |
|---|---|
| running as root | Everything |
| passwordless sudo | Everything — what `mini sudo` sets up |
| sudo needs a password | Read only. Cannot install or configure. |
| no sudo | Read only, and it will say so |

`mini sudo` writes `/etc/sudoers.d/90-mini-<user>`, validated with `visudo -c`
before installing. Undo it with `sudo rm /etc/sudoers.d/90-mini-<user>`.

On a shared or production box, do not do this. Run `mini --safe`, let it tell
you the command, and run the privileged part yourself. The prompt tells the
agent to check `sudo -n true` and hand you the command rather than hang.

## Browser UI and remote access

```bash
mini web             # browser UI on localhost, prints a generated password
mini password        # show that password again
mini web --lan       # reachable from your network, still password-protected
mini headless        # a server to attach to from another machine
```

Both `mini web` and `mini headless` follow the configured provider:

| Mode | What opencode is launched with |
|---|---|
| default | the local ollama model, `ollama/<model>` |
| after `mini remote` | the remote endpoint, `mini-remote/<model>` |

A remote-only box needs no local model: nothing is pulled, and ollama does not
have to be running. If the remote setup is incomplete — no URL or no model —
the launch stops before opencode starts and names the command that fixes it:

```
no remote model configured — run: mini remote <url> <model> [key]
```

`mini doctor` reports the same gap as a failure and prints that fix command.

The password is 32 random characters, generated on first use and stored `0600`
in `~/.cache/mini/secret`. It exists because this endpoint can run commands on
the machine — unauthenticated, it would be a remote shell for anyone who can
reach the port.

ollama itself is pinned to `127.0.0.1:11434` and never exposed. `mini doctor`
fails loudly if it finds it bound to `0.0.0.0`; `mini serve --local` fixes it.

## Memory

Facts you want it to keep:

```bash
mini remember "postgres runs in docker, host port 5433, data in /srv/pg"
mini remember "prefer nftables, ufw is not installed on purpose"
mini remember "this box serves api.example.com behind caddy, not nginx"
mini memories                        # show everything it knows
```

Memory lives in `~/.cache/mini/memories/*.md`. `00-host.md` is regenerated by
`mini setup` with hardware and OS facts; `10-learned.md` is yours. Edit either
by hand — they are plain markdown and get loaded into every session.

Save facts, not events. "nginx config lives in /etc/nginx/sites-enabled" earns
its place in the context window; "restarted nginx on Tuesday" does not.

## External inference

When the box cannot run a model fast enough, move only the inference:

```bash
mini remote https://openrouter.ai/api/v1 qwen/qwen3-coder sk-or-...
mini remote                  # interactive; the key prompt is hidden
mini local                   # back to the local model
```

Anything OpenAI-compatible: OpenRouter, Groq, Together, DeepInfra, a vLLM server
on your LAN, or another machine's ollama at `http://host:11434/v1` (no key).

Everything else is unchanged — same `AGENTS.md`, same tools, same memory, same
slash commands. `mini doctor` shows which mode you are in.

In remote mode there is no local model to set up — `mini web` and `mini headless`
use the remote endpoint as well (see [Browser UI](#browser-ui-and-remote-access)).

The key lands `0600` in `~/.cache/mini/api-key`, and `opencode.json` becomes
`0600` as well because it embeds the key.

## Changing the model

```bash
mini models                     # what fits, what is pulled, what is current
mini model qwen2.5-coder:14b    # switch (pulls it, rebuilds the ctx variant)
mini model auto                 # back to whatever suits this hardware
mini models --refresh           # re-check the registry against ollama upstream
```

Switching pulls the base model and rebuilds the derived `num_ctx` variant, so
the first switch to a new model is slow and every one after is instant.

## Keeping it healthy

```bash
mini doctor      # every check, with the exact fix for anything broken
mini status      # one line: is it ready
mini config      # what it is actually using right now
mini update      # opencode + ollama + the model
```

`mini doctor` is the first thing to run when something feels off. Every failing
check prints the command that fixes it.

## Tuning the brain

`~/.cache/mini/AGENTS.md` is the system prompt. Edit it — add your conventions,
your paths, the things this particular box does differently. mini detects that
you have changed it and will not overwrite your version on update; the new
default lands next to it as `AGENTS.md.new`.

To go back to stock: delete the file and run `mini setup`.

## Environment variables

| Variable | Does |
|---|---|
| `MINI_HOME` | Where state lives (default `~/.cache/mini`) |
| `MINI_SAFE=1` | Same as `--safe` |
| `MINI_YES=1` | Accept defaults, never prompt — for scripts and cloud-init |
| `OLLAMA_HOST` | Point at a remote ollama, e.g. `192.168.1.10:11434` |

`~/.cache` is for disposable data and some systems clear it. If you want your
memories backed up, set `MINI_HOME=~/.local/share/mini` in your shell rc.

## Running it on a fresh VPS

```bash
ssh you@new-box
curl -fsSL https://raw.githubusercontent.com/developerz-ai/mini/main/install.sh | bash
mini "harden this box, do not lock me out, I am on SSH right now"
mini "install docker and caddy, set caddy up to reverse proxy port 3000"
```

Unattended, in a cloud-init script:

```bash
export MINI_YES=1
curl -fsSL https://raw.githubusercontent.com/developerz-ai/mini/main/install.sh | bash
mini "install docker, ufw, fail2ban and unattended-upgrades"
```
