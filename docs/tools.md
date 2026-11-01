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
the other, and both work.

The TS files are namespaced `mini_*` on purpose. Custom tools install globally
to `~/.config/opencode/tools/`, and opencode lets a custom tool **override a
built-in of the same name**. A file called `webfetch.ts` would replace
opencode's own webfetch in every project you open, not just under mini.

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
No API key, no account, no rate-limit tier to sign up for. With Python 3, returns
numbered titles, URLs and snippets as plain text. Without Python 3, the fallback
returns numbered URLs only, retaining the page's URL spelling (no entity decoding
or relative-URL normalization). Its deliberately narrow, case-sensitive matcher
requires a quoted `href` before `result-link` in an anchor tag.

The fallback prints at most `-n COUNT` URLs (default 5, maximum 25), but consumes
the entire page so large responses cannot break an upstream pipe. A nonempty page
with no matching links, or `-n 0`, succeeds with a header and footer but no numbered
entries. An empty response or a failed parser remains an error.

Back-to-back queries occasionally return a page with no results; the script
retries up to three times with a short backoff, which turns that from a failure
into a hiccup.

This is what keeps the agent honest about versions and package names. A model's
training data has a cutoff; `apt` repository paths and installation docs move.
The system prompt tells it to search rather than guess at a version number.

### Offline fallback regression

Run this self-contained Bash recipe from the repository root. All fixtures and
mock commands live in a temporary directory; the isolated PATH contains no
`python3`. It checks exact output (including ordering and footer), a large page
whose extracted URLs exceed pipe capacity, short and zero-match pages, zero
limit, persistent curl failure, and an actual failing fallback parser command.
Only mocked curl runs; no network or installed agent is needed.

```bash
(
  set -euo pipefail
  script="$PWD/share/tools/websearch"
  tmp=$(mktemp -d /tmp/mini-websearch-test.XXXXXX)
  trap 'rm -rf "$tmp"' EXIT
  mkdir "$tmp/bin"
  export REAL_AWK
  REAL_AWK=$(command -v awk)
  for tool in bash cat; do
    ln -s "$(command -v "$tool")" "$tmp/bin/$tool"
  done
  cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ ${FAIL_CURL:-0} == 0 ]] || exit 22
cat "$FIXTURE"
MOCK
  cat > "$tmp/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
exit 0
MOCK
  cat > "$tmp/bin/awk" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${FAIL_PARSER:-0} == 1 ]]; then
  printf 'fixture parser failure\n' >&2
  exit 73
fi
exec "$REAL_AWK" "$@"
MOCK
  chmod +x "$tmp/bin/"{curl,sleep,awk}
  printf -v padding '%0256d' 0
  # Thousands of URLs, over 1 MiB extracted, with multiple anchors per line.
  for ((i=1; i<=6000; i++)); do
    printf '<a href="https://example.test/%s/%d" class=result-link>x</a>' \
      "$padding" "$i"
    if ((i % 3 == 0)); then printf '\n'; fi
  done > "$tmp/large"
  printf '<a href="https://example.test/first" class=result-link>x</a>\n' \
    > "$tmp/small"
  printf "<a href='https://example.test/second' class=result-link>x</a>\n" \
    >> "$tmp/small"
  printf '<html>No matching links</html>\n' > "$tmp/none"

  run_search() {
    local fixture=$1 count=$2 curl_fail=${3:-0} parser_fail=${4:-0}
    if PATH="$tmp/bin" FIXTURE="$tmp/$fixture" FAIL_CURL="$curl_fail" \
      FAIL_PARSER="$parser_fail" bash "$script" -n "$count" fixture \
      > "$tmp/out" 2> "$tmp/err"; then
      status=0
    else
      status=$?
    fi
  }
  expect_output() {
    local i=0 url
    {
      printf 'results for: fixture\n\n'
      for url in "$@"; do
        i=$((i + 1))
        printf '%d. %s\n' "$i" "$url"
      done
      printf '\nread one with:  webfetch <url>\n'
    } > "$tmp/expected"
    [[ $status == 0 && ! -s "$tmp/err" ]]
    cmp "$tmp/expected" "$tmp/out"
  }
  run_search large 5
  urls=()
  for ((i=1; i<=5; i++)); do
    urls+=("https://example.test/$padding/$i")
  done
  expect_output "${urls[@]}"
  run_search small 5
  expect_output https://example.test/first https://example.test/second
  run_search none 5
  expect_output
  run_search large 0
  expect_output
  run_search large 5 1
  [[ $status != 0 && $(<"$tmp/err") == *'websearch: no response (no network?)'* ]]
  run_search large 5 0 1
  [[ $status == 73 && $(<"$tmp/err") == *'fixture parser failure'* ]]
  printf 'offline fallback regression: PASS\n'
)
```

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
