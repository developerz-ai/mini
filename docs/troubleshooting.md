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

## doctor: "systemd is not running — the composed diagnosis playbook does not apply"

The `Init` step of `mini doctor` prints:

```bash
! systemd is not running (PID 1: <comm>) — the composed diagnosis playbook does not apply
```

mini builds its brain as `share/prompts/base.md` plus the module for your
platform, and installs the result as `~/.cache/mini/AGENTS.md`. On a
Debian-family host that module is `share/prompts/debian.md`, and it is written
for a systemd box: `systemctl --failed`, `journalctl -u <unit>`,
`systemctl cat`, `systemctl edit`. With no systemd running, every one of those
returns an error instead of a diagnosis — so the agent reports a broken machine
when the machine is fine.

It is a warning, not a failure: the Init finding counts as a warning only, so
a non-systemd host alone does not make `mini doctor` exit non-zero — another
failing check still does. mini still runs, and the non-systemd half of the
playbook (apt, disk, memory, processes) still applies. What does not apply is
the systemd half. The step sits between
`Platform` and `Privileges`, so it is printed on the local and the
remote-inference runs alike, and the same fact is written to the `Init:` line
of `~/.cache/mini/memories/00-host.md`, so the agent knows before it starts:

```bash
- Init: not systemd (PID 1: <comm>) — systemd is not PID 1, so systemctl and journalctl do not work here
```

The `Host` section of doctor prints the same fact as an `Init` summary line,
so `mini setup` and `mini doctor` never disagree about it.

**How the Init check decides.** For the `Init` step, PID 1 is the ground
truth: systemd is the init system only when `/proc/1/comm` reads `systemd` —
that is the process that actually is PID 1.

`/run/systemd/system` is only a fallback, used when `/proc/1/comm` cannot be
read at all. It is not proof: systemd's tmpfiles.d creates that directory at
package-install time, so a stock Debian container image ships it while PID 1
is still the image's own init. A `/run/systemd/system` directory next to a
non-systemd PID 1 means systemd was *installed*, not that it is running.

A `systemctl` binary on `PATH` proves nothing either — the same image ships
that binary, and it answers every query with "System has not been booted with
systemd as init system". The OS family and the distro are not evidence either.

That rule governs the `Init` check and what the agent is told about it. It is
not mini's rule everywhere: the ollama lifecycle (`lib/ollama.sh`) asks
systemd itself whether systemd owns `ollama.service` — it looks for a
`systemctl` binary and then runs `systemctl list-unit-files ollama.service`.
There the question is "is this server run by a systemd unit on this box",
not "is systemd PID 1", and on a host without systemd the query fails, so
ollama is not treated as systemd-managed.

**Fixes.** doctor prints all three fix lines on every host without systemd —
not only when it can see that you are in a container, because only you know
which one applies. Pick the one that matches your host.

- **Boot systemd as PID 1.**

  ```bash
  systemd must be the init system (PID 1) — on a VM or bare metal, install and boot systemd; installing the systemctl package alone changes nothing
  ```

- **Start the container with systemd as init.** The image needs systemd
  installed first: a stock Debian image ships no `/sbin/init`, so the command
  below fails with "no such file or directory" until you add it.

  ```bash
  in a container, start systemd as init — the image needs systemd installed first (a stock Debian image has no /sbin/init): docker run --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw <image> /sbin/init
  ```

- **Keep mini on this host.** Edit `~/.cache/mini/AGENTS.md` and replace the
  systemd steps with this host's init (OpenRC, SysVinit, runit, …). mini keeps
  an edited brain: `mini setup` writes the new version to `AGENTS.md.new` and
  leaves your file alone.

  ```bash
  to keep mini on this host, edit ~/.cache/mini/AGENTS.md (default ~/.cache/mini/AGENTS.md) and replace the systemd steps with this host's init
  ```

  (the path is `$MINI_HOME`, which defaults to `~/.cache/mini`.)

**The `Host tools` step agrees.** `systemctl` is listed there, and on a host
without systemd doctor says what that binary is worth instead of ticking the
box:

```bash
  ! systemctl is installed but systemd is not PID 1 — systemctl and journalctl do not work here
      fix: use this host's own init instead (see the Init step); installing the systemctl package alone changes nothing
```

When `systemctl` is not installed at all on such a host, the fix line is the
same one — never "install systemd", because the package is not the problem. On
a host where systemd really is PID 1, the line is a plain `✓ systemctl`.

## It is extremely slow

```bash
mini config      # which model
nvidia-smi       # is the GPU actually being used
```

On CPU, expect a few tokens per second. That is normal and it is why mini caps
CPU auto-selection at `qwen3:4b-instruct`.

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

Run `ollama list` to identify installed model names. The removal command below
is a 32k example: substitute your installed mini variant and base model names,
and remove only models you no longer need.

```bash
ollama list
rm -rf ~/.cache/mini ~/.local/share/mini ~/.local/bin/mini
rm -f ~/.config/opencode/tools/mini_*.ts
ollama rm mini-qwen2.5-coder-7b:32k qwen2.5-coder:7b     # example; substitute installed names
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
