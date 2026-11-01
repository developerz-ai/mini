#!/usr/bin/env bash
# remote_key_test.sh — pins the API-key prompt of `mini remote`.
#
# Offline by construction: no network, no ollama, no opencode, no framework.
# Everything happens inside a throwaway HOME and MINI_HOME.
#
# What it pins:
#   A) MINI_YES=1  — the key prompt is skipped, nothing is read from stdin,
#                   and an empty 0600 key file is written.
#   B) no MINI_YES — the prompt still reads the key from stdin and that key
#                   lands in the 0600 key file.
#
# The result must not depend on the caller's environment. MINI_YES is
# exported here on purpose: it poisons the ambient environment, so case B
# has to remove it from the child explicitly instead of inheriting it by
# accident.
set -euo pipefail
export MINI_YES=1

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MINI_BIN="${REPO_ROOT}/bin/mini"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok   %s\n' "$*"; }

[ -f "$MINI_BIN" ] || fail "no ${MINI_BIN}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# mini probes the host for GPUs before it does anything else (lib/detect.sh).
# Those probes depend on the machine's PCI bus, so stub them: this test is
# about the key prompt, not about the hardware it happens to run on.
STUB_BIN="${TMP}/bin"
mkdir -p "$STUB_BIN"
stub() {
  local name="$1" body="$2"
  printf '%s\n' '#!/usr/bin/env bash' "$body" > "${STUB_BIN}/${name}"
  chmod 0755 "${STUB_BIN}/${name}"
}
stub nvidia-smi "printf '%s\\n' 'Stub GPU, 0'"
stub rocm-smi   "printf '%s\\n' ''"
stub lspci      "printf '%s\\n' '00:02.0 VGA compatible controller: Stub'"

REMOTE_URL='https://example.invalid/v1'
REMOTE_MODEL='test/model'
SENTINEL='SENTINEL'

# seed <home> <mini_home> — fresh state dirs with a remote endpoint configured.
seed() {
  local home="$1" mini_home="$2"
  rm -rf "$home" "$mini_home"
  mkdir -p "$home" "$mini_home"
  printf 'MINI_REMOTE_URL=%s\nMINI_REMOTE_MODEL=%s\n' \
    "$REMOTE_URL" "$REMOTE_MODEL" > "${mini_home}/config"
}

# run_mini <name> <yes|no> <home> <mini_home>
#
# Pipes a sentinel line into mini and then reads whatever is left of the pipe.
# What is left is exactly what mini did not read from stdin.
#
# Each child gets its own explicit environment: the yes-mode child sets
# MINI_YES=1, the no-mode child has MINI_YES removed with env -u, so neither
# one can pick the flag up from the caller.
run_mini() {
  local name="$1" mode="$2" home="$3" mini_home="$4"
  printf '%s\n' "$SENTINEL" | {
    rc=0
    if [ "$mode" = 'yes' ]; then
      HOME="$home" MINI_HOME="$mini_home" MINI_YES=1 PATH="${STUB_BIN}:${PATH}" \
        bash "$MINI_BIN" remote > "${TMP}/${name}.out" 2> "${TMP}/${name}.err" || rc=$?
    else
      env -u MINI_YES HOME="$home" MINI_HOME="$mini_home" PATH="${STUB_BIN}:${PATH}" \
        bash "$MINI_BIN" remote > "${TMP}/${name}.out" 2> "${TMP}/${name}.err" || rc=$?
    fi
    printf '%s\n' "$rc" > "${TMP}/${name}.rc"
    cat > "${TMP}/${name}.left"
  }
}

assert_mode_600() {
  local file="$1" mode
  [ -f "$file" ] || fail "${file} was not created"
  mode=$(stat -c '%a' "$file")
  [ "$mode" = '600' ] || fail "${file} has mode ${mode}, expected 600"
}

# A) MINI_YES=1 — unattended: no read on stdin, empty 0600 key file.
home_a="${TMP}/home-a"
mini_a="${TMP}/mini-a"
seed "$home_a" "$mini_a"
run_mini a yes "$home_a" "$mini_a"

rc=$(cat "${TMP}/a.rc")
[ "$rc" = '0' ] || fail "MINI_YES=1: mini remote exited ${rc} — $(cat "${TMP}/a.err")"

key_file="${mini_a}/api-key"
assert_mode_600 "$key_file"
[ -z "$(cat "$key_file")" ] || fail "MINI_YES=1: key file is not empty: '$(cat "$key_file")'"
[ -z "$(tr -d '[:space:]' < "$key_file")" ] || fail "MINI_YES=1: key file holds non-whitespace bytes"
[ "$(cat "${TMP}/a.left")" = "$SENTINEL" ] || fail "MINI_YES=1: stdin was consumed — left: '$(cat "${TMP}/a.left")'"
ok "MINI_YES=1: no stdin read, empty 0600 key file"

# B) No MINI_YES — the prompt still reads the key from stdin.
home_b="${TMP}/home-b"
mini_b="${TMP}/mini-b"
seed "$home_b" "$mini_b"
run_mini b no "$home_b" "$mini_b"

rc=$(cat "${TMP}/b.rc")
[ "$rc" = '0' ] || fail "no MINI_YES: mini remote exited ${rc} — $(cat "${TMP}/b.err")"

key_file="${mini_b}/api-key"
assert_mode_600 "$key_file"
[ "$(cat "$key_file")" = "$SENTINEL" ] || fail "no MINI_YES: key file holds '$(cat "$key_file")', expected '${SENTINEL}'"
[ -z "$(cat "${TMP}/b.left")" ] || fail "no MINI_YES: stdin was not consumed — left: '$(cat "${TMP}/b.left")'"
ok "no MINI_YES: key read from stdin into a 0600 key file"

printf 'PASS: mini remote key prompt\n'
