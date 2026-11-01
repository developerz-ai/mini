# Tools

A shell gets the agent most of the way. These three cover what it cannot do on
its own: know anything current, read a web page, and take in the whole machine
at once.

| Tool | Shell command | What it does |
|---|---|---|
| `mini_sysreport` | `sysreport` | Read-only host health snapshot |
| `mini_search` | `websearch "<q>"` | Web search, no API key |
| `mini_fetch` | `webfetch <url>` | Fetch a page as readable text |

## Why each one exists twice

Every tool is a **bash script** in `~/.cache/mini/tools/` plus a **five-line TS
definition** in `~/.config/opencode/tools/`.

opencode only loads TypeScript or JavaScript tool definitions. But logic in TS
would be logic you cannot test without booting an agent, and could not use from
a script or a cron job. So all of it stays in bash and the TS file is a
`Bun.$` shell-out.

The practical benefit: the model can reach every capability two ways — as a tool
call, or as a plain command via `bash`. Small models sometimes prefer one over
the other, and both work. The command way only resolves *inside a session*:
mini puts the tools directory on `PATH` when it launches opencode. See
*Where the commands resolve* below for running them from your own shell.

The TS files are namespaced `mini_*` on purpose. Custom tools install globally
to `~/.config/opencode/tools/`, and opencode lets a custom tool **override a
built-in of the same name**. A file called `webfetch.ts` would replace
opencode's own webfetch in every project you open, not just under mini.

## Where the commands resolve

Bare `websearch`, `webfetch` and `sysreport` resolve inside a mini session and
not in an ordinary shell, and that gap is deliberate.

- **In a session** — every way mini launches opencode prepends
  `~/.cache/mini/tools` to `PATH`: interactive `mini`, one-shot `mini "<q>"`,
  and `mini web` / `mini headless` alike. The agent's `bash` calls resolve the
  bare names from that directory.
- **In your own shell** — that directory is not on `PATH`, and mini installs
  no global `PATH` entry for it (`install.sh` manages `PATH` only for the
  `mini` command itself). Run the script by full path, or put the directory on
  `PATH` for one command:

  ```bash
  ~/.cache/mini/tools/websearch "systemd 203 EXEC"
  PATH="$HOME/.cache/mini/tools:$PATH" sysreport
  ```

Do not add the directory to a shell rc; nothing outside a mini session should
depend on it. If you moved mini's state with `MINI_HOME`, the scripts live in
`$MINI_HOME/tools/` instead.

None of this applies to tool *calls*: the `mini_*` TypeScript definitions
shell out to the bash script by absolute path (`$MINI_HOME/tools/<name>`), so
they work wherever `PATH` points.

## sysreport

```bash
sysreport         # the usual suspects
sysreport -f      # adds network, DNS, firewall, mounts, recent installs
```

One snapshot: identity and uptime, failed units, disk and **inodes**, memory and
OOM kills this boot, top processes by CPU and RSS, listening sockets, recent
journal errors, kernel warnings.

It is the answer to "why is a small model bad at diagnosis". Asking a 7B model
to run twelve commands and correlate the output across twelve turns is asking it
to hold twelve outputs in working memory. One tool call, one coherent picture,
and it can reason about the whole thing at once. The system prompt tells it to
run this **first** on any diagnosis request.

Strictly read-only — it never changes anything, so it is safe under `--auto`.

## websearch

```bash
websearch "systemd service exited code 203 EXEC"
websearch -n 10 "nginx 502 upstream prematurely closed"
```

DuckDuckGo's lite endpoint, requested with a normal desktop browser's headers.
No API key, no account, no rate-limit tier to sign up for. Returns numbered
titles, URLs and snippets as plain text.

Back-to-back queries occasionally return a page with no results; the script
retries up to three times with a short backoff, which turns that from a failure
into a hiccup.

This is what keeps the agent honest about versions and package names. A model's
training data has a cutoff; `apt` repository paths and installation docs move.
The system prompt tells it to search rather than guess at a version number.

## webfetch

```bash
webfetch https://docs.docker.com/engine/install/debian/
webfetch -c 40000 <url>      # read more of a long page
webfetch -r <url>            # raw body, no text conversion
```

Follows redirects, sends the full set of headers a desktop browser sends —
`User-Agent`, `Accept`, `Accept-Language`, `Sec-Fetch-*`, `Upgrade-Insecure-
Requests` — so documentation sites that reject a bare `curl` render normally.

HTML becomes text through the best available converter: `w3m`, then `lynx`, then
a python3 extractor that preserves headings and list structure, then a plain
`sed` fallback. Output is truncated with a note telling the model how to read
more, so a huge page cannot silently blow the context window.

## Adding your own

Four steps:

1. **The script** — `share/tools/<name>`, plain bash, `set -euo pipefail`, a
   `usage()`, and output written for a model to read: plain text, no ANSI.
2. **The definition** — `share/opencode-tools/mini_<name>.ts`. Copy an existing
   one; it is a `Bun.$` call with a Zod arg schema. Write the `description` for
   the model: say *when* to reach for it, not just what it does.
3. **The prompt** — a row in the tool table in `share/prompts/base.md`. A tool
   the model does not know it has is a tool it will not use.
4. **The check** — a line in the Tools section of `lib/doctor.sh`, and add the
   name to `install_state_files` in `bin/mini`.

Keep tools read-only where you can. Under `--auto` the model runs them without
asking, so a read-only tool is one that cannot surprise you.

Anything expensive should be a tool rather than a chain of bash calls: the point
is to save the model turns, and every turn it does not spend is context it keeps
for reasoning.
