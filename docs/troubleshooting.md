# Troubleshooting

Start here:

```bash
mini doctor
```

Every failing check prints the exact command that fixes it. The rest of this
page is for problems doctor cannot see.

## It returns nothing at all, with no error

The request timed out during prompt processing.

Before a local model emits its first token it must read the entire prompt —
opencode's system prompt, every tool schema, your `AGENTS.md`, your memories.
That is several thousand tokens. A GPU chews through it in seconds. An older or
busy CPU runs prefill at 20–40 tokens per second, so the same turn needs
several minutes, and a default HTTP timeout kills the request part-way. Nothing
is logged as an error — you just get an empty response.

mini sets generous timeouts for exactly this, scaled to whether you are on GPU
or CPU:

```bash
grep -A3 '"options"' ~/.cache/mini/opencode.json
```

CPU boxes get a 45-minute request timeout and a 10-minute gap allowance between
streamed tokens. If you edited that file by hand and lost those values, restore
them with:

```bash
mini setup
```

To confirm the model itself is fine, bypass opencode entirely:

```bash
curl -s http://127.0.0.1:11434/api/generate \
  -d '{"model":"'"$(mini config | awk '/runtime model/{print $3}')"'","prompt":"say OK","stream":false}' \
  | head -c 200
```

If that answers and `mini` does not, it is the timeout, not the model.

## The agent stops mid-task, or ignores its tools

**Almost always the context window.** Check it:

```bash
mini config | grep context
```

Below 64k, opencode's own system prompt and tool definitions crowd out the
conversation and tool calls start truncating. There is no error message — the
agent just appears to get dumber and quit early.

If you are running a reduced context because the box is small, either free up
memory or move to a smaller model, which leaves more room for context:

```bash
mini model qwen2.5-coder:3b
```

If the context is already 64k and it still misbehaves, the model is the limit.
`qwen2.5-coder:1.5b` and below cannot reliably hold a multi-step tool loop —
that is a property of the model, not a bug in mini.

## It says it cannot install anything, or sudo commands fail

opencode runs bash with no terminal attached, so `sudo` cannot prompt for a
password. It fails with "no tty present" or hangs.

```bash
mini doctor      # look at the Privileges section
mini sudo        # grant passwordless sudo
```

If `mini sudo` writes the file but sudo still prompts, your `/etc/sudoers` is
missing the include line:

```bash
sudo grep -E '^@?include' /etc/sudoers      # want: @includedir /etc/sudoers.d
```

On a box where you do not want passwordless sudo, this is working as intended.
Use `mini --safe`, and run the privileged commands yourself when it hands them
to you.

## It is extremely slow

```bash
mini config      # which model
nvidia-smi       # is the GPU actually being used
```

On CPU, expect a few tokens per second for a 7B model. That is normal and it is
why mini caps CPU auto-selection at 7B.

Two things dominate the wait, and only one of them is the model:

- **Prompt processing.** The system prompt plus tool definitions is a few
  thousand tokens, and on CPU that is processed at tens of tokens per second.
  The first turn of a session pays for all of it. Later turns reuse ollama's
  cached prefix and are much cheaper.
- **Other load.** Inference wants every core. On a box already running a
  database or a build, a model will crawl regardless of its size — check
  `uptime` against `nproc` before blaming the model.

If the first turn takes minutes and later ones do not, that is prompt
processing, and it is expected. If every turn is slow, you are either on CPU or
competing for it.

A GPU that mini reports as "no usable driver" is not being used. Install the
vendor driver, then `mini setup` again to re-detect — the budget and the model
recommendation both change once VRAM is measurable.

To confirm ollama sees the GPU:

```bash
ollama ps        # shows CPU/GPU split for a loaded model
```

## It gives up saying it cannot do something

The model may not have realised it can act. Two things to try, in order:

```bash
mini "run sysreport and tell me what is failing"     # name the tool
mini --safe "..."                                     # watch what it proposes
```

If it consistently talks about commands instead of running them, the model is
too small for agentic work. Move up a tier.

## Tool calls fail with "command not found"

The shell tools live in `~/.cache/mini/tools/` and mini prepends that to `PATH`
when launching opencode. If you started opencode directly rather than through
`mini`, that PATH entry is missing.

```bash
ls -l ~/.cache/mini/tools/     # should show websearch webfetch sysreport
mini setup                     # reinstalls them
```

## websearch returns nothing

```bash
websearch "test query"
```

- `no results` on every attempt — DuckDuckGo may have changed its markup. The
  parser is in `share/tools/websearch`; it matches `class=result-link`.
- `no response` — no outbound HTTPS. Check a proxy or egress firewall.

Occasional empty results are rate limiting; the script already retries three
times with backoff.

## opencode cannot reach the model

```bash
mini status
curl -s localhost:11434/api/version
ollama list | grep mini-
```

If the server is up but the `mini-*` variant is missing, the derived model was
never built or was removed:

```bash
mini setup
```

For systemd startup, mini runs `systemctl start ollama` directly as root, or
with `sudo -n` as a non-root user. It never prompts for a password. If the
command fails, mini prints a warning on stderr and immediately falls back to a
user process, without waiting for the failed service start. If noninteractive
privileges are unavailable, `mini sudo` is an optional remedy to grant
passwordless sudo; it is not required for the user-process fallback.

A successful systemd start is still checked for readiness; if the service does
not become ready, mini warns and falls back to a user process too. If that
process also fails to become ready, the fatal error points to
`$MINI_HOME/logs/ollama.log` (normally `~/.cache/mini/logs/ollama.log`).

If mini cannot start the systemd service, inspect it manually:

```bash
sudo systemctl status ollama
journalctl -u ollama -n 50 --no-pager
```

mini deliberately does not stop a systemd-managed ollama — something else on the
box may be using it.

## It broke something

`mini --safe` from now on, and check what changed:

```bash
ls -lt /etc/**/*.bak.* 2>/dev/null | head        # the prompt tells it to back up
grep ' install ' /var/log/dpkg.log | tail -20    # what got installed
journalctl --since "1 hour ago" -p err --no-pager
```

The system prompt requires a backup before editing any config, so a `.bak.<ts>`
file next to the original is the usual way back.

If it locked you out of SSH, you need console access from your provider's panel.
This is the failure mode the prompt works hardest to prevent — and the reason to
use `--safe` on a box you cannot physically reach.

## Setup fails partway

Re-run it; setup is idempotent and skips what is already done:

```bash
mini setup
```

Specific failures:

- **apt errors** — `sudo apt-get update` by hand and read the output. A broken
  third-party repo blocks everything downstream.
- **ollama install fails** — install it yourself from ollama.com, then re-run.
- **pull fails partway** — re-run; ollama resumes from where it stopped.
- **no sudo** — mini cannot install packages. It still runs, but the agent will
  be unable to install anything either. `mini doctor` reports this.

## Starting completely over

```bash
rm -rf ~/.cache/mini            # state: config, brain, memories
mini setup
```

Full removal:

```bash
rm -rf ~/.cache/mini ~/.local/share/mini ~/.local/bin/mini
rm -f ~/.config/opencode/tools/mini_*.ts
ollama rm mini-qwen2.5-coder-7b:64k qwen2.5-coder:7b     # adjust to your model
```

Your own opencode config was never touched, so nothing else needs undoing.

## Reporting a bug

Include:

```bash
mini doctor      # the whole output
mini config
mini version
```

Plus the prompt you gave it and what it did instead. For agent-behaviour issues,
`~/.cache/mini/AGENTS.md` matters too — an edited brain explains a lot of
otherwise mysterious behaviour.
