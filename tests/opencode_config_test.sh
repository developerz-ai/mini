#!/usr/bin/env bash
# tests/opencode_config_test.sh — the opencode.json regeneration contract.
#
# Regenerating $MINI_HOME/opencode.json must refresh everything mini owns
# (provider, model, small_model, limits, managed slash commands) but never
# destroy the user's own slash commands. When the merge cannot run — no
# python3, or a previous config that does not parse — the old file must be
# kept byte-for-byte in a unique opencode.json.bak.* with a warning, and the eager
# fallback must never overwrite an earlier recovery backup. The
# fresh config must still be written and valid. The remote writer must leave
# the file 0600 (it embeds the API key).
#
# PATH-stubbed contract test: inside every case PATH is a sandbox bin dir —
# the real python3 symlinked in, or pointedly absent — so nothing here can
# reach ollama, opencode or the network. lib/ollama.sh is sourced for its
# globals only (OLLAMA_URL feeds the generated baseURL); no server is started
# or probed. Every write lands in one mktemp sandbox; nothing in the repo is
# touched.
#
# No `set -e`: each case reports its own failures, so one broken assertion
# cannot hide the rest; the summary exits non-zero when anything failed.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

MINI_HOME="$SANDBOX/home"
export MINI_HOME
OLLAMA_HOST='127.0.0.1:11434'   # pin the baseURL the generated config embeds
# shellcheck source=lib/common.sh
. "$root/lib/common.sh"
# Globals only — sourcing this must not start or probe a server.
# shellcheck source=lib/ollama.sh
. "$root/lib/ollama.sh"
# shellcheck source=lib/opencode.sh
. "$root/lib/opencode.sh"

# The only binaries the config writers reach for; nothing else is on PATH
# inside a case, so a stray ollama/opencode/curl call fails loudly.
SANDBOX_BIN="$SANDBOX/bin"
mkdir -p "$SANDBOX_BIN"
for tool in cat sed tail grep touch mv cp chmod stat rm mktemp; do
  ln -s "$(command -v "$tool")" "$SANDBOX_BIN/$tool"
done

PY3="$(command -v python3 || true)"
if [ -z "$PY3" ]; then
  printf 'SKIP: python3 not available — the merge contract cannot be exercised here\n'
  exit 0
fi
ln -s "$PY3" "$SANDBOX_BIN/python3"

CFG="$MINI_HOME/opencode.json"
MYTOOL_TEMPLATE=$'Run my thing on $ARGUMENTS\ncarefully'
DEFAULT_CMDS="['devbox', 'diag', 'harden', 'ports', 'remember', 'space', 'svc']"
PASS=0 FAIL=0
RUN_LOG='' RUN_RC=0

ok_case()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad_case() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }
assert_eq() { # <desc> <want> <got>
  if [ "$2" = "$3" ]; then ok_case "$1"
  else bad_case "$1 — want [$2] got [$3]"; fi
}
assert_true() { # <desc> <command...>: ok when it exits 0
  local desc="$1"; shift
  if "$@"; then ok_case "$desc"; else bad_case "$desc"; fi
}
assert_false() { # <desc> <command...>: ok when it exits non-zero
  local desc="$1"; shift
  if "$@"; then bad_case "$desc"; else ok_case "$desc"; fi
}
assert_warned() { # <log> <desc>: the merge-impossible warning was printed
  case "$1" in
    *"could not carry your custom slash commands"*) ok_case "$2" ;;
    *) bad_case "$2 — warning about the .bak not printed" ;;
  esac
}
assert_not_warned() { # <log> <desc>: the merge-impossible warning was NOT printed
  case "$1" in
    *"could not carry your custom slash commands"*) bad_case "$2 — false merge-impossible warning printed" ;;
    *) ok_case "$2" ;;
  esac
}
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
bak_state() { compgen -G "$1.bak*" >/dev/null && printf present || printf absent; }

run_case() { # <fn> [args]: run a case body in a subshell; capture log and rc
  RUN_LOG="$("$@" 2>&1)"
  RUN_RC=$?
}

# json_get <file> <python expression over d>
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
print(eval(sys.argv[2], {"d": d}))
PY
}

json_ok() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }

default_cmds_ok() { # <file>: the command block is exactly mini's managed set
  [ "$(json_get "$1" "sorted(d['command'])")" = "$DEFAULT_CMDS" ]
}

seed_user_command() { # <file> <key>: add one user-owned command entry
  python3 - "$1" "$2" <<'PY'
import json, sys
path, key = sys.argv[1:3]
with open(path, encoding="utf-8") as f:
    d = json.load(f)
d.setdefault("command", {})[key] = {
    "description": "Mine: " + key,
    "template": "Run my thing on $ARGUMENTS\ncarefully",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

mangle_managed_command() { # <file>: edit a managed entry the way a user would
  python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
d["command"]["diag"]["description"] = "my own diag, thank you"
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

# --- case bodies: PATH is the sandbox bin dir inside every one --------------

case_first_run() {
  PATH="$SANDBOX_BIN"; hash -r
  opencode_write_config 'mini-test:7b' 32768
}
case_regen_with_user_entry() {
  seed_user_command "$CFG" mytool
  mangle_managed_command "$CFG"
  PATH="$SANDBOX_BIN"; hash -r
  opencode_write_config 'mini-test:3b' 16384
}
case_regen_again() {
  PATH="$SANDBOX_BIN"; hash -r
  opencode_write_config 'mini-test:7b' 32768
}
case_remote_regen() {
  local home="$SANDBOX/home-remote"
  mkdir -p "$home"
  printf 'MINI_PROVIDER=remote\nMINI_REMOTE_URL=http://10.1.2.3:8000/v1\nMINI_REMOTE_MODEL=remote-model:8b\n' > "$home/config"
  printf 'sk-sandbox-key\n' > "$home/api-key"
  MINI_HOME="$home"
  PATH="$SANDBOX_BIN"; hash -r
  opencode_write_config 'remote-model:8b' 65536   # first generation, no old file
  seed_user_command "$home/opencode.json" mytool
  # Regeneration the way `mini remote` does it: the new values land in the
  # config first, then the writers run — the remote writer reads its model
  # and context from there, not from its arguments.
  cfg_set MINI_REMOTE_MODEL 'remote-model:2b'
  cfg_set MINI_CTX 32768
  opencode_write_config 'remote-model:2b' 32768   # regenerate — merge must run
}
case_unparsable_old() {
  PATH="$SANDBOX_BIN"; hash -r
  opencode_write_config 'mini-test:7b' 32768
}
case_no_python3() {
  mkdir -p "$SANDBOX/bin-nopython"
  local tool
  for tool in cat sed tail grep touch mv cp chmod stat rm mktemp; do
    ln -sf "$SANDBOX_BIN/$tool" "$SANDBOX/bin-nopython/$tool"
  done
  PATH="$SANDBOX/bin-nopython"; hash -r   # python3 pointedly absent
  opencode_write_config 'mini-test:3b' 16384
}
case_no_command_block() {
  PATH="$SANDBOX_BIN"; hash -r
  opencode_write_config 'mini-test:3b' 16384
}
case_regen_gpu_timeouts() {
  ACCEL=gpu
  PATH="$SANDBOX_BIN"; hash -r
  opencode_write_config 'mini-test:7b' 32768
}

# --- 1: first run, no previous config ----------------------------------------

rm -rf "$MINI_HOME"
mkdir -p "$MINI_HOME"
printf 'MINI_PROVIDER=local\n' > "$MINI_HOME/config"

run_case case_first_run
assert_eq 'first run: exit 0' '0' "$RUN_RC"
assert_true 'first run: valid JSON' json_ok "$CFG"
assert_true 'first run: default command block only' default_cmds_ok "$CFG"
assert_eq 'first run: model' 'ollama/mini-test:7b' "$(json_get "$CFG" "d['model']")"
assert_eq 'first run: small_model' 'ollama/mini-test:7b' "$(json_get "$CFG" "d['small_model']")"
assert_eq 'first run: baseURL' 'http://127.0.0.1:11434/v1' \
  "$(json_get "$CFG" "d['provider']['ollama']['options']['baseURL']")"
assert_eq 'first run: context limit' '32768' \
  "$(json_get "$CFG" "d['provider']['ollama']['models']['mini-test:7b']['limit']['context']")"
assert_eq 'first run: output limit' '4096' \
  "$(json_get "$CFG" "d['provider']['ollama']['models']['mini-test:7b']['limit']['output']")"
assert_eq 'first run: no .bak' 'absent' "$(bak_state "$CFG")"
# Pins the early-exit branch (lib/opencode.sh: `[ -f "$old" ] || return 0`), not
# just its success: if it regressed to the failure path, the fallback's cp on
# the nonexistent live config no-ops under this shell (no set -e) and no .bak
# appears — but the merge-impossible warning would print. In production
# (bin/mini runs set -e) that same path aborts every first setup.
assert_not_warned "$RUN_LOG" 'first run: no merge-impossible warning'

# --- 2: a user entry in the old command block survives; managed refresh ------

run_case case_regen_with_user_entry
assert_eq 'user entry: exit 0' '0' "$RUN_RC"
assert_true 'user entry: valid JSON' json_ok "$CFG"
assert_eq 'user entry: carried verbatim (description)' 'Mine: mytool' \
  "$(json_get "$CFG" "d['command']['mytool']['description']")"
assert_eq 'user entry: carried verbatim (template)' "$MYTOOL_TEMPLATE" \
  "$(json_get "$CFG" "d['command']['mytool']['template']")"
assert_eq 'user entry: managed key refreshed to the current default' \
  'Diagnose what is wrong with this machine right now' \
  "$(json_get "$CFG" "d['command']['diag']['description']")"
assert_eq 'user entry: command block size' '8' "$(json_get "$CFG" "len(d['command'])")"
assert_eq 'user entry: model refreshed' 'ollama/mini-test:3b' "$(json_get "$CFG" "d['model']")"
assert_eq 'user entry: small_model refreshed' 'ollama/mini-test:3b' "$(json_get "$CFG" "d['small_model']")"
assert_false 'user entry: old model id gone' grep -qF 'mini-test:7b' "$CFG"
assert_eq 'user entry: context limit' '16384' \
  "$(json_get "$CFG" "d['provider']['ollama']['models']['mini-test:3b']['limit']['context']")"
assert_eq 'user entry: output limit' '2048' \
  "$(json_get "$CFG" "d['provider']['ollama']['models']['mini-test:3b']['limit']['output']")"
assert_eq 'user entry: baseURL kept' 'http://127.0.0.1:11434/v1' \
  "$(json_get "$CFG" "d['provider']['ollama']['options']['baseURL']")"
assert_eq 'user entry: no .bak when the merge succeeds' 'absent' "$(bak_state "$CFG")"

# --- 3: regenerate again — entry survives every time; remote path is 0600 ----

run_case case_regen_again
assert_eq 'second regen: exit 0' '0' "$RUN_RC"
assert_true 'second regen: valid JSON' json_ok "$CFG"
assert_eq 'second regen: user entry still there' 'Mine: mytool' \
  "$(json_get "$CFG" "d['command']['mytool']['description']")"
assert_eq 'second regen: model refreshed' 'ollama/mini-test:7b' "$(json_get "$CFG" "d['model']")"

RCFG="$SANDBOX/home-remote/opencode.json"
run_case case_remote_regen
assert_eq 'remote: exit 0' '0' "$RUN_RC"
assert_true 'remote: valid JSON' json_ok "$RCFG"
assert_eq 'remote: user entry carried' 'Mine: mytool' \
  "$(json_get "$RCFG" "d['command']['mytool']['description']")"
assert_eq 'remote: model refreshed' 'mini-remote/remote-model:2b' "$(json_get "$RCFG" "d['model']")"
assert_eq 'remote: small_model refreshed' 'mini-remote/remote-model:2b' "$(json_get "$RCFG" "d['small_model']")"
assert_false 'remote: old model id gone' grep -qF 'remote-model:8b' "$RCFG"
assert_eq 'remote: baseURL' 'http://10.1.2.3:8000/v1' \
  "$(json_get "$RCFG" "d['provider']['mini-remote']['options']['baseURL']")"
assert_eq 'remote: file stays 0600' '600' "$(file_mode "$RCFG")"
assert_eq 'remote: no .bak when the merge succeeds' 'absent' "$(bak_state "$RCFG")"

# --- 4: merge impossible — .bak + warning, fresh config still written --------

# An old config python3 cannot parse.
printf '{ this is not json at all\n' > "$CFG"
cp "$CFG" "$SANDBOX/old-unparsable.json"
run_case case_unparsable_old
assert_eq 'unparsable old: exit 0 (fallback, not failure)' '0' "$RUN_RC"
BACKUPS=("${CFG}".bak*)
UNPARSABLE_BACKUP="${BACKUPS[0]}"
assert_true 'unparsable old: kept byte-for-byte in recovery backup' \
  cmp -s "$SANDBOX/old-unparsable.json" "$UNPARSABLE_BACKUP"
assert_true 'unparsable old: warning names recovery path' \
  grep -qF "$UNPARSABLE_BACKUP" <<< "$RUN_LOG"
assert_warned "$RUN_LOG" 'unparsable old: warning printed'
assert_true 'unparsable old: fresh config valid' json_ok "$CFG"
assert_true 'unparsable old: fresh config carries the defaults' default_cmds_ok "$CFG"

# No python3 at all. The previous config this time is a valid one carrying a
# user entry — nothing can be merged, so the file itself must be preserved.
seed_user_command "$CFG" mytool
cp "$CFG" "$SANDBOX/old-valid.json"
run_case case_no_python3
assert_eq 'no python3: exit 0 (fallback, not failure)' '0' "$RUN_RC"
BACKUPS=("${CFG}".bak*)
assert_eq 'no python3: a second recovery backup exists' '2' "${#BACKUPS[@]}"
USER_BACKUP=''
for backup in "${BACKUPS[@]}"; do
  if cmp -s "$SANDBOX/old-valid.json" "$backup"; then USER_BACKUP="$backup"; fi
done
assert_true 'no python3: user config preserved byte-for-byte' test -n "$USER_BACKUP"
assert_true 'no python3: earlier recovery backup unchanged' \
  cmp -s "$SANDBOX/old-unparsable.json" "$UNPARSABLE_BACKUP"
assert_true 'no python3: warning names user recovery path' \
  grep -qF "${USER_BACKUP:-missing-backup}" <<< "$RUN_LOG"
assert_warned "$RUN_LOG" 'no python3: warning printed'
assert_true 'no python3: fresh config valid' json_ok "$CFG"
assert_eq 'no python3: fresh config written anyway' 'ollama/mini-test:3b' \
  "$(json_get "$CFG" "d['model']")"
assert_false 'no python3: nothing carried (merge skipped, file preserved)' \
  grep -qF 'mytool' "$CFG"

# Repeated fallback must not replace either recovery file with defaults-only JSON.
cp "$CFG" "$SANDBOX/old-defaults.json"
run_case case_no_python3
assert_eq 'repeated no python3: exit 0' '0' "$RUN_RC"
assert_warned "$RUN_LOG" 'repeated no python3: warning printed'
BACKUPS=("${CFG}".bak*)
assert_eq 'repeated no python3: a third recovery backup exists' '3' "${#BACKUPS[@]}"
assert_true 'repeated no python3: user recovery backup unchanged' \
  cmp -s "$SANDBOX/old-valid.json" "$USER_BACKUP"
assert_true 'repeated no python3: unparsable recovery backup unchanged' \
  cmp -s "$SANDBOX/old-unparsable.json" "$UNPARSABLE_BACKUP"
for backup in "${BACKUPS[@]}"; do
  if [ "$backup" != "$USER_BACKUP" ] && [ "$backup" != "$UNPARSABLE_BACKUP" ]; then
    assert_true 'repeated no python3: defaults saved separately' \
      cmp -s "$SANDBOX/old-defaults.json" "$backup"
    assert_true 'repeated no python3: warning names new recovery path' \
      grep -qF "$backup" <<< "$RUN_LOG"
  fi
done
assert_true 'repeated no python3: fresh config valid' json_ok "$CFG"

# --- 5: parseable old config with no command block — nothing to carry --------

# A valid old config whose command block is missing entirely is
# nothing-to-carry, not merge-impossible (opencode_merge_commands's
# contract): the regeneration succeeds with no .bak, no warning, and the
# fresh config carries the defaults and the new model.

rm -f "${CFG}".bak*   # drop the fallback files section 4 left behind
printf '{\n  "model": "ollama/old",\n  "small_model": "ollama/old"\n}\n' > "$CFG"
run_case case_no_command_block
assert_eq 'no command block: exit 0 (nothing to carry, not a fallback)' '0' "$RUN_RC"
assert_eq 'no command block: no .bak' 'absent' "$(bak_state "$CFG")"
assert_not_warned "$RUN_LOG" 'no command block: no merge-impossible warning'
assert_true 'no command block: fresh config valid' json_ok "$CFG"
assert_true 'no command block: fresh config carries the defaults' default_cmds_ok "$CFG"
assert_eq 'no command block: model refreshed' 'ollama/mini-test:3b' \
  "$(json_get "$CFG" "d['model']")"
assert_false 'no command block: old model id gone' grep -qF 'ollama/old' "$CFG"

# --- 6: GPU acceleration — request timeouts refresh to 600000/120000 --------

# Sections 1-5 regenerate with ACCEL unset, so every config above carries the
# cpu timeouts (2700000/600000). The timeouts are regenerated content like the
# model, not user state: a gpu regeneration must refresh both to the gpu
# values, and no cpu-only value may survive anywhere in the file.

run_case case_regen_gpu_timeouts
assert_eq 'gpu regen: exit 0' '0' "$RUN_RC"
assert_eq 'gpu regen: timeout' '600000' \
  "$(json_get "$CFG" "d['provider']['ollama']['options']['timeout']")"
assert_eq 'gpu regen: chunkTimeout' '120000' \
  "$(json_get "$CFG" "d['provider']['ollama']['options']['chunkTimeout']")"
assert_false 'gpu regen: cpu timeout value gone' grep -qF '2700000' "$CFG"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
