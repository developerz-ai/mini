#!/usr/bin/env bash
# mini_bin_dir_test.sh — the PATH the agent inherits, and the /remember command.
#
# mini launches opencode with a PATH of its own, and the agent's shell
# inherits it. Two things have to be true of that PATH:
#
#   1. `mini` resolves inside a session. The agent's shell inherits the PATH
#      of whatever started mini, and that PATH usually carries no mini bin
#      dir — so `mini remember` and the `mini sudo` the agent is told to use
#      would not resolve. The CLI has to come from the install root, which
#      is the only place the runtime knows about: MINI_BIN_DIR exists solely
#      in install.sh and is never exported or read at runtime.
#   2. The user's PATH is never rewritten. mini prepends its own directories
#      and keeps every entry the caller had.
#
# The /remember command names the CLI by absolute path for the same reason,
# and that pins it to the install the config was generated from.
#
# Every branch of that lookup is pinned here: the install root mini exports
# as MINI_ROOT, the fallback to the path lib/opencode.sh itself sits at, an
# empty PATH, and the bare `mini` the /remember command falls back to when
# the CLI cannot be located at all. The launches degrade with it too: when
# the lookup fails, the agent PATH is built without the bin dir instead of
# aborting the launch.
#
# Offline by construction: no network, no ollama, no opencode, no framework.
# A fake opencode prints the PATH it was handed.
#
# Run: bash tests/mini_bin_dir_test.sh
set -uo pipefail

# The physical root: mini resolves its own path physically (bin/mini follows
# symlinks, lib/opencode.sh uses cd -P), so the test compares like with like.
ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MINI_CLI="${ROOT}/bin/mini"
BASH_BIN="${BASH:-/bin/bash}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok   %s\n' "$*"; }

[ -x "$MINI_CLI" ] || fail "${MINI_CLI} is not executable"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic: a surrounding mini session exports MINI_ROOT, and that points at
# the INSTALLED mini, not at this checkout. mini_cli_path would take that
# branch, resolve the other install, and every assertion below would compare
# two different CLIs.
unset MINI_ROOT

# An empty HOME: there is no shell profile to be read, and none may appear.
HOME_DIR="${TMP}/home"
MINI_HOME_DIR="${TMP}/mini-home"
mkdir -p "$HOME_DIR" "$MINI_HOME_DIR"
export HOME="$HOME_DIR"
export MINI_HOME="$MINI_HOME_DIR"

# The caller's PATH: system directories only, so it cannot contain a mini.
# The whole point is that mini has to put one there itself.
CALLER_PATH='/usr/bin:/bin'
export PATH="$CALLER_PATH"
for tool in bash sed grep cat tr cut head mktemp dirname; do
  command -v "$tool" >/dev/null 2>&1 || fail "${tool} is not reachable under ${CALLER_PATH}"
done
DIRNAME_BIN="$(command -v dirname)"
for d in /usr/bin /bin; do
  [ -e "${d}/mini" ] && fail "${d}/mini exists — the caller's PATH must carry no mini"
done

# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/ollama.sh
. "$ROOT/lib/ollama.sh"
# shellcheck source=../lib/opencode.sh
. "$ROOT/lib/opencode.sh"

# A fake opencode that reports the PATH it was handed.
FAKE_OPENCODE="${TMP}/fake-opencode"
cat > "$FAKE_OPENCODE" <<'SH'
#!/usr/bin/env bash
printf 'FAKE_PATH=%s\n' "$PATH"
SH
chmod 0755 "$FAKE_OPENCODE"
opencode_bin() { printf '%s' "$FAKE_OPENCODE"; }

# A configured model, so the launches get as far as the exec.
cfg_set MINI_PROVIDER local
cfg_set MINI_MODEL 'mini-qwen2.5-coder-3b:16k'
cfg_set MINI_CTX 16384

# The PATH one of mini's launch paths handed to opencode.
launch_path() { # <launch function> [args...]
  local fn="$1"; shift
  "$fn" "$@" 2>/dev/null | sed -n 's/^FAKE_PATH=//p'
}

# `mini` must resolve to the install root's CLI inside the session, and no
# entry of the caller's PATH may go missing.
check_agent_path() { # <name> <launch function> [args...]
  local name="$1" fn="$2"; shift 2
  local path resolved d
  path=$(launch_path "$fn" "$@")
  [ -n "$path" ] || fail "${name}: opencode was handed no PATH"

  resolved=$(PATH="$path" "$BASH_BIN" -c 'command -v mini')
  [ "$resolved" = "$MINI_CLI" ] \
    || fail "${name}: mini resolves to '${resolved}', expected '${MINI_CLI}'"

  for d in $(printf '%s' "$CALLER_PATH" | tr ':' ' '); do
    case ":${path}:" in
      *":${d}:"*) : ;;
      *) fail "${name}: the PATH lost the caller's entry '${d}' — got: ${path}" ;;
    esac
  done

  # The caller's PATH is kept verbatim; mini only prepends to it.
  case "$path" in
    *":${CALLER_PATH}") : ;;
    *) fail "${name}: the caller's PATH was rewritten — got: ${path}" ;;
  esac

  case ":${path}:" in
    *":${MINI_HOME_DIR}/tools:"*) : ;;
    *) fail "${name}: the PATH lost the tools dir ${MINI_HOME_DIR}/tools" ;;
  esac

  ok "${name}: mini resolves to ${MINI_CLI}, every caller PATH entry kept"
}

check_agent_path "opencode_launch" opencode_launch
check_agent_path "opencode_run"    opencode_run "why is nginx down"
check_agent_path "opencode_web"    opencode_web web

# mini exports the install root it resolved from its own path, and the CLI
# has to come from there. With MINI_ROOT set, the lookup takes that branch
# instead of falling back to the path of lib/opencode.sh.
export MINI_ROOT="$ROOT"
check_agent_path "opencode_launch (MINI_ROOT set)" opencode_launch
unset MINI_ROOT
ok "the MINI_ROOT branch resolves the CLI of that install"

# And that branch is the one that is taken: MINI_ROOT decides, even when it
# points somewhere else than the tree this file sits in.
OTHER_ROOT="${TMP}/other-install"
mkdir -p "${OTHER_ROOT}/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "${OTHER_ROOT}/bin/mini"
chmod 0755 "${OTHER_ROOT}/bin/mini"
other=$( export MINI_ROOT="$OTHER_ROOT"; mini_cli_path )
[ "$other" = "${OTHER_ROOT}/bin/mini" ] \
  || fail "with MINI_ROOT=${OTHER_ROOT} the CLI resolved to '${other}'"
ok "MINI_ROOT decides which install the CLI comes from"

# An empty PATH: the agent still gets a usable one — no empty entry, no
# trailing colon. The lookup needs `dirname`, which an empty PATH cannot
# find, so the one already resolved is provided as a function for this case.
dirname() { "$DIRNAME_BIN" "$@"; }
empty_path=$( PATH=''; opencode_agent_path )
unset -f dirname
[ -n "$empty_path" ] || fail "the empty-PATH branch produced no PATH at all"
case ":${empty_path}:" in
  *::*) fail "the empty-PATH branch produced an empty entry: '${empty_path}'" ;;
esac
case "$empty_path" in
  :*|*:) fail "the empty-PATH branch produced a leading or trailing colon: '${empty_path}'" ;;
esac
case ":${empty_path}:" in
  *":${ROOT}/bin:"*) : ;;
  *) fail "the empty-PATH branch lost the bin dir: '${empty_path}'" ;;
esac
case ":${empty_path}:" in
  *":${MINI_HOME_DIR}/tools:"*) : ;;
  *) fail "the empty-PATH branch lost the tools dir: '${empty_path}'" ;;
esac
ok "the empty-PATH branch yields a PATH with no empty entry"

# The generated config, and the /remember command inside it.
opencode_write_config 'mini-qwen2.5-coder-3b:16k' 16384 >/dev/null
CONFIG="${MINI_HOME_DIR}/opencode.json"
[ -f "$CONFIG" ] || fail "no config was written to ${CONFIG}"

remember_template() { # <config file> -> the raw template value
  local file="$1"
  awk '
    /"remember": *\{/ { inside = 1; next }
    inside && /^ *\}/ { inside = 0; next }
    inside && /"template":/ { sub(/^.*"template": "/, ""); sub(/",$/, ""); print; exit }
  ' "$file"
}

template=$(remember_template "$CONFIG") || fail "no /remember template in ${CONFIG}"
[ -n "$template" ] || fail "the /remember template is empty"

# It is a JSON string: undo the escapes.
template=$(printf '%s' "$template" | sed 's/\\"/"/g; s/\\\\/\\/g')

# The command the agent is told to run.
command=$(printf '%s' "$template" | sed 's/^.*running: //; s/\. Then confirm.*$//')
[ -n "$command" ] || fail "the /remember template carries no command"

FACT='nginx listens on port 8080'
command=${command//\$ARGUMENTS/$FACT}

# The CLI it names has to be the executable of this install.
named=$(printf '%s' "$command" | sed 's/^"\([^"]*\)".*/\1/')
[ -x "$named" ] || fail "the /remember command names '${named}', which is not executable"
[ "$named" = "$MINI_CLI" ] \
  || fail "the /remember command names '${named}', expected the install's own '${MINI_CLI}'"
ok "the /remember command names the executable CLI of this install"

# And running it has to save the fact.
out=$(HOME="$HOME_DIR" MINI_HOME="$MINI_HOME_DIR" "$BASH_BIN" -c "$command" 2>&1) \
  || fail "the /remember command failed: ${out}"

MEM="${MINI_HOME_DIR}/memories/10-learned.md"
[ -f "$MEM" ] || fail "the /remember command wrote no ${MEM}"
grep -Fq "$FACT" "$MEM" || fail "${MEM} does not hold the fact: $(cat "$MEM")"
ok "the /remember command appended the fact to ${MEM}"

# The CLI the agent finds on its PATH is the one the config names.
resolved=$(PATH="$(launch_path opencode_launch)" "$BASH_BIN" -c 'command -v mini')
[ "$resolved" = "$named" ] \
  || fail "the agent's mini is '${resolved}', the config names '${named}'"
ok "the agent's mini is the same CLI the config names"

# No shell profile is written.
for rc in .bashrc .zshrc .profile .bash_profile; do
  [ -e "${HOME_DIR}/${rc}" ] && fail "a shell profile appeared at ${HOME_DIR}/${rc}"
done
ok "no shell profile was written"

# And none is read: a profile that would wreck the PATH if it were sourced
# must not change the resolution.
printf 'export PATH=/nonexistent-mini-poison\n' > "${HOME_DIR}/.bashrc"
printf 'export PATH=/nonexistent-mini-poison\n' > "${HOME_DIR}/.profile"
resolved=$(PATH="$(launch_path opencode_launch)" "$BASH_BIN" -c 'command -v mini')
[ "$resolved" = "$MINI_CLI" ] \
  || fail "a shell profile was read — mini resolves to '${resolved}'"
rm -f "${HOME_DIR}/.bashrc" "${HOME_DIR}/.profile"
ok "a shell profile in HOME is not read"

# Bash 5.2 treats unquoted & in a pattern replacement as the matched text.
# Generate and execute /remember from an ampersand-containing install root.
(
  shopt -s patsub_replacement 2>/dev/null || : # unavailable before Bash 5.2
  export MINI_ROOT="${TMP}/mini&test"
  mkdir -p "${MINI_ROOT}/bin"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "%%s\\n" "$@"\n' > "${MINI_ROOT}/bin/mini"
  chmod 0755 "${MINI_ROOT}/bin/mini"
  special_config="${TMP}/ampersand-config.json"
  { printf '{\n'; opencode_command_block; printf '}\n'; } > "$special_config"
  special_template=$(remember_template "$special_config")
  special_template=$(printf '%s' "$special_template" | sed 's/\\"/"/g; s/\\\\/\\/g')
  special_command=$(printf '%s' "$special_template" | sed 's/^.*running: //; s/\. Then confirm.*$//')
  special_command=${special_command//\$ARGUMENTS/ampersand-path-fact}
  out=$("$BASH_BIN" -c "$special_command" 2>&1) \
    || fail "ampersand install: /remember failed: ${out}"
  [ "$out" = $'remember\nampersand-path-fact' ] \
    || fail "ampersand install: wrong CLI arguments: ${out}"
) || fail "ampersand install regression"
ok "the /remember command executes the CLI in an ampersand-containing install root"

# The fallback: when the CLI cannot be located at all, the /remember command
# falls back to the bare `mini` — and the config it lands in stays valid.
FB_HOME="${TMP}/mini-home-fallback"
mkdir -p "$FB_HOME"
export MINI_HOME="$FB_HOME"
cfg_set MINI_PROVIDER local
cfg_set MINI_MODEL 'mini-qwen2.5-coder-3b:16k'
cfg_set MINI_CTX 16384

# The CLI cannot be found.
mini_cli_path() { return 1; }

opencode_write_config 'mini-qwen2.5-coder-3b:16k' 16384 >/dev/null
FB_CONFIG="${FB_HOME}/opencode.json"
[ -f "$FB_CONFIG" ] || fail "no config was written to ${FB_CONFIG}"

# Still a config opencode can read.
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FB_CONFIG" \
    || fail "the fallback config is not valid JSON"
fi

fb_template=$(remember_template "$FB_CONFIG")
[ -n "$fb_template" ] || fail "the fallback config has no /remember template"
fb_template=$(printf '%s' "$fb_template" | sed 's/\\"/"/g; s/\\\\/\\/g')
fb_command=$(printf '%s' "$fb_template" | sed 's/^.*running: //; s/\. Then confirm.*$//')
[ -n "$fb_command" ] || fail "the fallback /remember template carries no command"
case "$fb_command" in
  '"mini" remember'*) : ;;
  *) fail "the fallback names '${fb_command}', expected the bare mini command" ;;
esac
case "$fb_command" in
  */*) fail "the fallback names a path, not the bare command: '${fb_command}'" ;;
esac
ok "the fallback names the bare mini command"

# And running it still saves the fact.
FB_FACT='the fallback still remembers'
fb_run=${fb_command//\$ARGUMENTS/$FB_FACT}
out=$( HOME="$HOME_DIR" MINI_HOME="$FB_HOME" PATH="${ROOT}/bin:${PATH}" "$BASH_BIN" -c "$fb_run" 2>&1 ) \
  || fail "the fallback /remember command failed: ${out}"
FB_MEM="${FB_HOME}/memories/10-learned.md"
[ -f "$FB_MEM" ] || fail "the fallback /remember command wrote no ${FB_MEM}"
grep -Fq "$FB_FACT" "$FB_MEM" || fail "${FB_MEM} does not hold the fact: $(cat "$FB_MEM")"
ok "the bare-mini fallback appended the fact to ${FB_MEM}"

# The launch sites must degrade the same way the config does. When the CLI
# cannot be located, opencode_agent_path builds the PATH without the bin dir
# (`dir=$(mini_bin_dir) || dir=''` in lib/opencode.sh) and the launch goes
# on. That guard is load-bearing under bin/mini's `set -euo pipefail`:
# without it the failed lookup kills the function, the PATH=... assignment
# fails errexit, and the launch aborts before opencode ever runs. So run
# each launch site under that same errexit discipline while mini_cli_path is
# still overridden to fail, and require the PATH anyway.
check_degraded_path() { # <name> <launch function> [args...]
  local name="$1" fn="$2"; shift 2
  local path rc
  path=$(
    set -euo pipefail
    "$fn" "$@" 2>/dev/null | sed -n 's/^FAKE_PATH=//p'
  )
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "${name}: the launch aborted instead of degrading (exit ${rc})"
  [ -n "$path" ] || fail "${name}: the degraded launch handed opencode no PATH"
  case ":${path}:" in
    *::*) fail "${name}: the degraded PATH has an empty entry: '${path}'" ;;
  esac
  case "$path" in
    :*|*:) fail "${name}: the degraded PATH has a leading or trailing colon: '${path}'" ;;
  esac
  case ":${path}:" in
    *":${MINI_HOME}/tools:"*) : ;;
    *) fail "${name}: the degraded PATH lost the tools dir: '${path}'" ;;
  esac
  case "$path" in
    *":${CALLER_PATH}") : ;;
    *) fail "${name}: the degraded PATH rewrote the caller's PATH — got: ${path}" ;;
  esac
  case ":${path}:" in
    *":${ROOT}/bin:"*) fail "${name}: the degraded PATH invented a bin dir: '${path}'" ;;
  esac
  ok "${name}: the launch degrades to a PATH without the bin dir"
}
check_degraded_path "opencode_launch (cli lookup fails)" opencode_launch
check_degraded_path "opencode_run    (cli lookup fails)" opencode_run "why is nginx down"
check_degraded_path "opencode_web    (cli lookup fails)" opencode_web web

printf 'PASS: the agent PATH and the /remember command\n'
