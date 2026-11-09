#!/usr/bin/env bash
# ollama_bind_test.sh — doctor must judge the ollama bind from the OBSERVED
# listener, never from the configured OLLAMA_HOST.
#
# An ollama server has no authentication of any kind, so a bind on a routable
# address is as bad as a wildcard one: whoever can reach the port can run
# inference on the box. OLLAMA_HOST says what mini was told, not what is
# listening, so doctor has to read the listener table.
#
# Four cases, each with its own fake `ss` on PATH:
#   1. a routable bind (192.168.1.10:11434) -> a failure naming that address,
#      the fix command, and no "loopback only" line
#   2. a loopback bind (127.0.0.1:11434)    -> "bound to loopback only"
#   3. no ss at all                         -> no "loopback only" line, and
#                                              the bind reported as unverified
#   4. a table that shifts between reads    -> the verdict comes from ONE read,
#      (empty first, routable second)          so an empty first read never
#                                              prints "loopback only"
#
# Hermetic: own sandbox, no network, no host service, no real ss.
#
#   bash tests/ollama_bind_test.sh

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINI_BIN="${REPO_ROOT}/bin/mini"

PASS=0
FAIL=0

ok()  { printf '  ok    %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

expect() { # expect <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1 — expected [$2], got [$3]"
  fi
}

contains() { # contains <description> <needle> <haystack>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *)      bad "$1 — missing [$2]" ;;
  esac
}

lacks() { # lacks <description> <needle> <haystack>
  case "$3" in
    *"$2"*) bad "$1 — unexpectedly found [$2]" ;;
    *)      ok "$1" ;;
  esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mini-ollama-bind-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------- fixtures ----

# A fake `ss`: it prints the listener table it was built with, and nothing
# else. `ss -tlnH` prints one line per listening socket, local address in
# the fourth field.
make_ss() { # <dir> <listener line>...
  local dir="$1"; shift
  mkdir -p "$dir"
  {
    printf '#!/bin/sh\n'
    printf "cat <<'SS_TABLE'\n"
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
    printf 'SS_TABLE\n'
  } > "${dir}/ss"
  chmod +x "${dir}/ss"
}

# A fake `ss` whose answer changes between calls: the first call reports an
# empty listener table, every later call reports a routable bind. It counts
# its own invocations next to itself, so the test can see how many reads of
# the listener table doctor made.
#
# This is the case a second read breaks: doctor reads the table, gets nothing
# back, then reads it again, gets a routable bind — and if it judges the two
# reads separately, it calls a routable bind safe because the first read came
# back empty.
make_ss_shifting() { # <dir>
  local dir="$1"
  mkdir -p "$dir"
  cat > "${dir}/ss" <<'SS_EOF'
#!/bin/sh
dir=$(dirname "$0")
n=$(cat "$dir/count" 2>/dev/null || echo 0)
n=$(( n + 1 ))
printf '%s\n' "$n" > "$dir/count"
if [ "$n" -eq 1 ]; then exit 0; fi
cat "$dir/table"
SS_EOF
  chmod +x "${dir}/ss"
  cat > "${dir}/table" <<'TABLE_EOF'
LISTEN 0      4096   192.168.1.10:11434   0.0.0.0:*         users:(("ollama",pid=42,fd=7))
TABLE_EOF
}

# The routable bind: the server answers on the box's LAN address. The second
# line is a decoy on another port — the port filter has to ignore it.
ROUTABLE="${TMP}/ss-routable"
make_ss "$ROUTABLE" \
  'LISTEN 0      4096   192.168.1.10:11434   0.0.0.0:*         users:(("ollama",pid=42,fd=7))' \
  'LISTEN 0      4096   0.0.0.0:8080          0.0.0.0:*         users:(("nginx",pid=43,fd=6))'

# The loopback bind, with the same decoy beside it. Both loopback forms are
# here: 127.0.0.0/8 and ::1 must both read as loopback.
LOOPBACK="${TMP}/ss-loopback"
make_ss "$LOOPBACK" \
  'LISTEN 0      4096   127.0.0.1:11434       0.0.0.0:*         users:(("ollama",pid=42,fd=7))' \
  'LISTEN 0      4096   [::1]:11434            [::]:*            users:(("ollama",pid=42,fd=7))' \
  'LISTEN 0      4096   0.0.0.0:8080          0.0.0.0:*         users:(("nginx",pid=43,fd=6))'

# The wildcard binds — every interface, both families.
WILDCARD="${TMP}/ss-wildcard"
make_ss "$WILDCARD" \
  'LISTEN 0      4096   0.0.0.0:11434         0.0.0.0:*         users:(("ollama",pid=42,fd=7))' \
  'LISTEN 0      4096   [::]:11434             [::]:*            users:(("ollama",pid=42,fd=7))'

# A PATH with every command this host has, except ss — the third case. The
# symlinks keep everything else identical: the only thing that changes is
# whether `has ss` finds anything.
NOSS="${TMP}/noss"
mkdir -p "$NOSS"
IFS=':' read -r -a path_dirs <<< "$PATH"
for path_dir in "${path_dirs[@]}"; do
  if [ -z "$path_dir" ] || [ ! -d "$path_dir" ]; then continue; fi
  for path_file in "$path_dir"/*; do
    if [ ! -f "$path_file" ] || [ ! -x "$path_file" ]; then continue; fi
    path_base="${path_file##*/}"
    if [ "$path_base" = 'ss' ]; then continue; fi
    if [ -e "${NOSS}/${path_base}" ]; then continue; fi
    ln -s "$path_file" "${NOSS}/${path_base}" 2>/dev/null || true
  done
done

# The fixtures have to be what they claim, or the cases below prove nothing.
if PATH="$NOSS" command -v ss >/dev/null 2>&1; then
  bad "the no-ss PATH still has an ss binary"
else
  ok "the no-ss PATH has no ss binary"
fi
if PATH="$NOSS" command -v awk >/dev/null 2>&1; then
  ok "the no-ss PATH still has the other tools"
else
  bad "the no-ss PATH lost the other tools"
fi
if PATH="$ROUTABLE" command -v ss >/dev/null 2>&1; then
  ok "the routable fake ss is on PATH"
else
  bad "the routable fake ss is not on PATH"
fi

# --------------------------------------------------------------- doctor ----

# Run doctor with a controlled PATH, against a host that is healthy in every
# respect except the bind under test. Every unrelated check is stubbed, so
# the only thing that can move doctor's counters is the listener table — and
# the listener table is the fake `ss`, never the host's real one.
doctor_case() { # <path> <name>
  local path="$1" name="$2"
  local home="${TMP}/home-${name}"
  mkdir -p "$home/memories"
  cat > "$home/config" <<'CFG'
MINI_PROVIDER=local
MINI_BASE_MODEL=stub-model:1b
MINI_MODEL=stub-model:1b
MINI_CTX=
CFG
  (
    export MINI_HOME="$home"
    export NO_COLOR=1
    export PATH="$path"
    # shellcheck disable=SC1090
    . "$MINI_BIN"
    # doctor's exit status is not what is under test here
    set +e

    # The host, minus the bind: healthy in every other respect.
    detect_all() {
      OS_ID='debian'; OS_LIKE='debian'; OS_NAME='Debian GNU/Linux 12'; OS_VERSION='12'
      OS_PLATFORM='debian'
      CPU_CORES=4; RAM_MB=16384; DISK_FREE_GB=100
      GPU_VENDOR='nvidia'; GPU_NAME='stub-gpu'; VRAM_MB=8192
      BUDGET_MB=8192; ACCEL='gpu'
      SUDO_MODE='nopasswd'
      INIT_SYSTEM='systemd'; INIT_PID1='systemd'
      export OS_ID OS_LIKE OS_NAME OS_VERSION OS_PLATFORM
      export CPU_CORES RAM_MB DISK_FREE_GB GPU_VENDOR GPU_NAME VRAM_MB
      export BUDGET_MB ACCEL SUDO_MODE INIT_SYSTEM INIT_PID1
    }
    ollama() { printf 'ollama version is 0.0.0\n'; }
    ollama_up() { return 0; }
    ollama_version() { printf '0.0.0\n'; }
    ollama_has_model() { return 0; }
    models_recommend() { printf 'stub-model:1b\n'; }
    doctor_opencode_section() { :; }
    doctor_tools_section() { :; }

    # The counters with every step title, so one step's contribution can be
    # measured instead of guessed.
    step() { printf '\n%s\n' "$*"; printf '  dz-counters %s %s\n' "$DOCTOR_FAILS" "$DOCTOR_WARNS"; }

    doctor_run
    printf '  dz-result %s %s %s\n' "$?" "$DOCTOR_FAILS" "$DOCTOR_WARNS"
  ) 2>&1
}

# The counters right after a step title — that is, before that step ran.
counters_at() { # <output> <step title> -> "fails warns"
  printf '%s\n' "$1" | awk -v t="$2" '
    $0 == t { f = 1; next }
    f && $1 == "dz-counters" { print $2, $3; exit }'
}

# The lines of doctor's Ollama step, up to the next step title.
ollama_section() { # <doctor output>
  printf '%s\n' "$1" | awk '/^Ollama$/{f=1; next} f{ if ($0 ~ /^[A-Za-z]/) exit; print }'
}

# What the Ollama step itself added to doctor's counters: the difference
# between the counters before it and the counters after it.
ollama_delta() { # <output> -> "fails warns"
  local before after
  before=$(counters_at "$1" 'Ollama')
  after=$(counters_at "$1" 'Model')
  if [ -z "$before" ] || [ -z "$after" ]; then printf 'missing missing\n'; return 1; fi
  printf '%s %s\n' \
    "$(( ${after%% *} - ${before%% *} ))" \
    "$(( ${after##* } - ${before##* } ))"
}

delta_fails() { ollama_delta "$1" | cut -d' ' -f1; }
delta_warns() { ollama_delta "$1" | cut -d' ' -f2; }

# ------------------------------------------------- a routable bind ----

printf 'a routable bind (192.168.1.10:11434)\n'

routable_out="$(doctor_case "${ROUTABLE}:${PATH}" routable)"
routable_section="$(ollama_section "$routable_out")"

contains "a routable bind is reported as a failure" \
  "ollama is listening on 192.168.1.10:11434 — reachable from the network, with no auth" \
  "$routable_section"
contains "a routable bind prints the command that fixes it" \
  "fix: mini serve --local" "$routable_section"
lacks "a routable bind is not called loopback-only" \
  "bound to loopback only" "$routable_section"
expect "a routable bind adds exactly one failure" "1" "$(delta_fails "$routable_out")"
expect "a routable bind adds no warning" "0" "$(delta_warns "$routable_out")"

# ------------------------------------------------- a wildcard bind ----

printf 'a wildcard bind (0.0.0.0 and [::])\n'

wildcard_out="$(doctor_case "${WILDCARD}:${PATH}" wildcard)"
wildcard_section="$(ollama_section "$wildcard_out")"

contains "a wildcard bind is reported as a failure" \
  "ollama is listening on 0.0.0.0:11434, [::]:11434 — reachable from the network, with no auth" \
  "$wildcard_section"
contains "a wildcard bind prints the command that fixes it" \
  "fix: mini serve --local" "$wildcard_section"
lacks "a wildcard bind is not called loopback-only" \
  "bound to loopback only" "$wildcard_section"
expect "a wildcard bind adds exactly one failure" "1" "$(delta_fails "$wildcard_out")"
expect "a wildcard bind adds no warning" "0" "$(delta_warns "$wildcard_out")"

# ------------------------------------------------- a loopback bind ----

printf 'a loopback bind (127.0.0.1:11434)\n'

loopback_out="$(doctor_case "${LOOPBACK}:${PATH}" loopback)"
loopback_section="$(ollama_section "$loopback_out")"

contains "a loopback bind is reported as loopback-only" \
  "bound to loopback only" "$loopback_section"
lacks "a loopback bind is not a failure" \
  "reachable from the network, with no auth" "$loopback_section"
expect "a loopback bind adds no failure" "0" "$(delta_fails "$loopback_out")"
expect "a loopback bind adds no warning" "0" "$(delta_warns "$loopback_out")"

# ------------------------------------------------------- no ss at all ----

printf 'no ss on PATH\n'

noss_out="$(doctor_case "$NOSS" noss)"
noss_section="$(ollama_section "$noss_out")"

lacks "no ss -> no loopback-only claim" "bound to loopback only" "$noss_section"
contains "no ss -> the bind is reported as unverified" "unverified" "$noss_section"
contains "no ss -> the fix line installs ss" \
  "fix: sudo apt install -y iproute2" "$noss_section"
expect "no ss -> no failure" "0" "$(delta_fails "$noss_out")"
expect "no ss -> exactly one warning" "1" "$(delta_warns "$noss_out")"

# ------------------------------------------- a table that shifts ----

printf 'a listener table that shifts between reads (empty first, routable second)\n'

SHIFTING="${TMP}/ss-shifting"
make_ss_shifting "$SHIFTING"

shifting_out="$(doctor_case "${SHIFTING}:${PATH}" shifting)"
shifting_section="$(ollama_section "$shifting_out")"

# The empty first read is the only read doctor is entitled to judge. A verdict
# built from a second read would call the routable bind safe, because the
# first read happened to come back empty.
lacks "a shifting listener table is not called loopback-only" \
  "bound to loopback only" "$shifting_section"
lacks "a shifting listener table reports no bind it never read" \
  "reachable from the network, with no auth" "$shifting_section"

shift_reads="$(cat "${SHIFTING}/count" 2>/dev/null || echo 0)"
expect "the listener table is read once" "1" "$shift_reads"

# --------------------------------------------------- ollama_public_bind ----

# ollama_bind_local's "still listening" warning calls ollama_public_bind
# directly -- doctor's own bind check above goes through ollama_listen_binds
# and ollama_addr_is_loopback instead, and init_test stubs ollama_public_bind
# out entirely. Nothing else would catch a regression where this function
# goes back to matching only wildcard addresses (0.0.0.0, [::]) and misses a
# routable one (192.168.1.10:11434), so exercise it on its own here.

printf 'ollama_public_bind: routable, loopback, and wildcard binds\n'

public_bind_case() { # <path> -> ollama_public_bind's stdout
  local path="$1"
  (
    export MINI_HOME="${TMP}/home-public-bind"
    export PATH="$path"
    export OLLAMA_HOST_ADDR='127.0.0.1:11434'
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/lib/common.sh"
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/lib/ollama.sh"
    ollama_public_bind
  )
}

contains "a routable bind is reported by ollama_public_bind" \
  "192.168.1.10:11434" "$(public_bind_case "${ROUTABLE}:${PATH}")"
contains "a wildcard bind is reported by ollama_public_bind" \
  "0.0.0.0:11434" "$(public_bind_case "${WILDCARD}:${PATH}")"
expect "a loopback bind reports nothing public" \
  "" "$(public_bind_case "${LOOPBACK}:${PATH}")"

# ------------------------------------------------------------- summary ----

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
