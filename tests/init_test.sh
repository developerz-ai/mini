#!/usr/bin/env bash
# init_test.sh — pins the init-system detection and doctor's Init step.
#
# The rule: PID 1 is the ground truth. systemd is the init system only when
# /proc/1/comm reads "systemd". /run/systemd/system is a fallback for the one
# case where PID 1 cannot be read at all — systemd's tmpfiles.d creates that
# directory at package-install time, so a stock Debian container image ships
# it while PID 1 is still the image's own init. A systemctl binary on PATH
# proves nothing at all.
#
# The two probes detect_init reads are absolute paths, so the test points them
# at temporary files. Every branch is then reachable on any host, including
# one where systemd really is running.
#
#   bash tests/init_test.sh

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mini-init-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------- fixtures ----

MARKER="${TMP}/systemd-marker"          # stands in for /run/systemd/system
ABSENT="${TMP}/no-such-dir"             # a path that does not exist
COMM_SYSTEMD="${TMP}/comm-systemd"
COMM_BASH="${TMP}/comm-bash"
COMM_MISSING="${TMP}/no-such-comm"      # PID 1 unreadable
FAKEBIN="${TMP}/fakebin"

mkdir -p "$MARKER" "$FAKEBIN"
printf 'systemd\n' > "$COMM_SYSTEMD"
printf 'bash\n'    > "$COMM_BASH"
printf '#!/bin/sh\nexit 0\n' > "${FAKEBIN}/systemctl"
chmod +x "${FAKEBIN}/systemctl"

# A PATH that holds every command this host has, except systemctl. doctor's
# "systemctl missing" line only runs on a host without the binary, so without
# this the branch would never be reached on a systemctl-equipped host.
# Symlinks keep everything else identical: the only thing the case changes is
# whether `has systemctl` finds anything.
NOBIN="${TMP}/nobin"
mkdir -p "$NOBIN"
IFS=':' read -r -a path_dirs <<< "$PATH"
for path_dir in "${path_dirs[@]}"; do
  if [ -z "$path_dir" ] || [ ! -d "$path_dir" ]; then continue; fi
  for path_file in "$path_dir"/*; do
    if [ ! -f "$path_file" ] || [ ! -x "$path_file" ]; then continue; fi
    path_base="${path_file##*/}"
    if [ "$path_base" = 'systemctl' ]; then continue; fi
    if [ -e "${NOBIN}/${path_base}" ]; then continue; fi
    ln -s "$path_file" "${NOBIN}/${path_base}" 2>/dev/null || true
  done
done

# The fixture has to be what it claims, or the case below proves nothing.
if PATH="$NOBIN" command -v systemctl >/dev/null 2>&1; then
  bad "the no-systemctl PATH still has a systemctl binary"
else
  ok "the no-systemctl PATH has no systemctl binary"
fi
if PATH="$NOBIN" command -v awk >/dev/null 2>&1; then
  ok "the no-systemctl PATH still has the other tools"
else
  bad "the no-systemctl PATH lost the other tools"
fi

# ------------------------------------------------------------ detection ----

# detect_init with both probe locations pointed at temporary files.
detect_case() { # <runtime-marker> <pid1-comm-file>
  (
    export MINI_SYSTEMD_RUNTIME_DIR="$1"
    export MINI_PID1_COMM="$2"
    # shellcheck disable=SC1090
    . "${REPO_ROOT}/lib/common.sh"
    # shellcheck disable=SC1090
    . "${REPO_ROOT}/lib/detect.sh"
    detect_init
    printf '%s|%s\n' "$INIT_SYSTEM" "$INIT_PID1"
  )
}

printf 'detect_init\n'

expect "PID 1 is systemd -> systemd" \
  "systemd|systemd" "$(detect_case "$ABSENT" "$COMM_SYSTEMD")"

expect "PID 1 is bash -> not systemd" \
  "not systemd|bash" "$(detect_case "$ABSENT" "$COMM_BASH")"

expect "marker present but PID 1 is bash -> not systemd (PID 1 is the ground truth)" \
  "not systemd|bash" "$(detect_case "$MARKER" "$COMM_BASH")"

expect "PID 1 unreadable, no marker -> not systemd" \
  "not systemd|unknown" "$(detect_case "$ABSENT" "$COMM_MISSING")"

expect "PID 1 unreadable, marker present -> systemd (marker is the fallback)" \
  "systemd|unknown" "$(detect_case "$MARKER" "$COMM_MISSING")"

# A systemctl binary on PATH proves nothing: Debian images ship one without
# ever booting systemd.
fake_seen="$(PATH="$FAKEBIN:$PATH" bash -c 'command -v systemctl')"
contains "the systemctl fake really is on PATH" "${FAKEBIN}/systemctl" "$fake_seen"
expect "systemctl on PATH, PID 1 is bash -> not systemd" \
  "not systemd|bash" "$(PATH="$FAKEBIN:$PATH" detect_case "$ABSENT" "$COMM_BASH")"
expect "systemctl on PATH, marker present, PID 1 is bash -> not systemd" \
  "not systemd|bash" "$(PATH="$FAKEBIN:$PATH" detect_case "$MARKER" "$COMM_BASH")"

# The old shape OR-ed the marker with the PID 1 probe. That is the bug.
if grep 'runtime_dir' "${REPO_ROOT}/lib/detect.sh" | grep -q '||'; then
  bad "the runtime marker must not be OR-ed with the PID 1 probe"
else
  ok "the runtime marker is not OR-ed with the PID 1 probe"
fi
if grep -v '^[[:space:]]*#' "${REPO_ROOT}/lib/detect.sh" | grep -q 'systemctl'; then
  bad "detect_init must never consult systemctl — a binary on PATH proves nothing"
else
  ok "detect_init never consults systemctl"
fi

# With no override the production paths are used.
real_init="$( ( # shellcheck disable=SC1090
  . "${REPO_ROOT}/lib/common.sh"
  # shellcheck disable=SC1090
  . "${REPO_ROOT}/lib/detect.sh"
  detect_init
  printf '%s\n' "$INIT_SYSTEM" ) )"
real_comm="$( { tr -d '[:space:]' < /proc/1/comm; } 2>/dev/null || true)"
if [ -n "$real_comm" ]; then
  want_init='not systemd'
  [ "$real_comm" = 'systemd' ] && want_init='systemd'
elif [ -d /run/systemd/system ]; then
  want_init='systemd'
else
  want_init='not systemd'
fi
expect "no override -> this host's real init system" "$want_init" "$real_init"

# --------------------------------------------------------------- doctor ----

# Run doctor with the probe locations pointed at temporary files.
doctor_case() { # <runtime-marker> <pid1-comm-file> <local|remote> [path]
  local home="${TMP}/home-$3"
  local path="${4:-$PATH}"
  if [ -n "${4:-}" ]; then home="${home}-$(basename "$path")"; fi
  mkdir -p "$home/memories"
  if [ "$3" = 'remote' ]; then
    printf 'MINI_PROVIDER=remote\nMINI_REMOTE_URL=http://127.0.0.1:1/v1\nMINI_REMOTE_MODEL=test/model\n' \
      > "$home/config"
  fi
  (
    export MINI_HOME="$home"
    export MINI_SYSTEMD_RUNTIME_DIR="$1"
    export MINI_PID1_COMM="$2"
    export NO_COLOR=1
    export PATH="$path"
    # shellcheck disable=SC1090
    . "${MINI_BIN}"
    doctor_run
  ) 2>&1
}

# The lines of doctor's Init step, up to the next step title.
init_section() { # <doctor output>
  printf '%s\n' "$1" | awk '/^Init$/{f=1; next} f{ if ($0 ~ /^[A-Za-z]/) exit; print }'
}

# The lines of doctor's Host tools step, up to the next step title.
tools_section() { # <doctor output>
  printf '%s\n' "$1" | awk '/^Host tools$/{f=1; next} f{ if ($0 ~ /^[A-Za-z]/) exit; print }'
}

printf 'doctor Init step\n'

up_out="$(doctor_case "$ABSENT" "$COMM_SYSTEMD" local)"
up_section="$(init_section "$up_out")"
contains "PID 1 is systemd -> 'systemd is running'" \
  "systemd is running — the composed diagnosis playbook applies" "$up_section"
lacks "PID 1 is systemd -> no init warning" "systemd is not running" "$up_section"
lacks "PID 1 is systemd -> no fix lines" "fix:" "$up_section"

down_out="$(doctor_case "$ABSENT" "$COMM_BASH" local)"
down_section="$(init_section "$down_out")"
contains "no systemd -> names PID 1 and says the playbook does not apply" \
  "systemd is not running (PID 1: bash) — the composed diagnosis playbook does not apply" \
  "$down_section"
contains "no systemd -> fix: systemd must be PID 1" \
  "systemd must be the init system (PID 1)" "$down_section"
contains "no systemd -> fix: start the container with systemd as init" \
  "docker run --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw <image> /sbin/init" \
  "$down_section"
contains "no systemd -> fix: the image needs systemd installed first" \
  "the image needs systemd installed first" "$down_section"
contains "no systemd -> fix: edit AGENTS.md instead" \
  "replace the systemd steps with this host's init" "$down_section"
expect "no systemd -> exactly three fix lines" "3" \
  "$(printf '%s\n' "$down_section" | grep -c 'fix:')"

# The marker alone must not turn a non-systemd host into a systemd one.
marker_out="$(doctor_case "$MARKER" "$COMM_BASH" local)"
marker_section="$(init_section "$marker_out")"
contains "marker present, PID 1 is bash -> still warns and names PID 1" \
  "systemd is not running (PID 1: bash) — the composed diagnosis playbook does not apply" \
  "$marker_section"
contains "marker present, PID 1 is bash -> says installing systemctl changes nothing" \
  "installing the systemctl package alone changes nothing" "$marker_section"
expect "marker present, PID 1 is bash -> exactly three fix lines" "3" \
  "$(printf '%s\n' "$marker_section" | grep -c 'fix:')"

# No fix line may tell the user to install systemctl as the remedy.
lacks "no systemd -> no fix line installs the systemctl package" \
  "apt install -y systemd" "$marker_section"

# The Init finding is a warning, never a failure: a host without systemd must
# not make mini doctor exit non-zero.
init_line="$(printf '%s\n' "$marker_section" | grep -m1 'systemd is not running' || true)"
if printf '%s\n' "$init_line" | grep -qE '^[[:space:]]*!'; then
  ok "the Init finding is printed as a warning"
else
  bad "the Init finding must be a warning (!), got [$init_line]"
fi
if printf '%s\n' "$init_line" | grep -q '✗'; then
  bad "the Init finding must not be a failure (✗)"
else
  ok "the Init finding is not counted as a failure"
fi

init_block="$(awk '/step "Init"/{f=1} f{print} /step "Privileges"/{exit}' "${REPO_ROOT}/lib/doctor.sh")"
if printf '%s\n' "$init_block" | grep -q 'd_fail'; then
  bad "the Init step must not use d_fail — a non-systemd host must not fail doctor"
else
  ok "the Init step uses d_warn, never d_fail"
fi
if printf '%s\n' "$init_block" | grep -q 'dockerenv'; then
  bad "the Init step must not gate the container fix on /.dockerenv"
else
  ok "the container fix line is printed on every non-systemd host"
fi

# ------------------------------------------------- doctor counter oracle ----
#
# The checks above read the printed "!" and grep the source for d_fail. Both
# are shadows of the requirement: a check that prints "!" and still calls
# d_fail passes both. The requirement is about what doctor *counts* — a host
# without systemd is healthy, so nothing in the Init step may add a failure,
# and doctor must exit 0.
#
# So run doctor for real against a host that is healthy in every respect
# except systemd, with every unrelated check stubbed out, and read the
# counters doctor keeps itself. Each step title is followed by the counters
# as they stand before that step runs, so a single step's contribution can be
# measured instead of guessed.

doctor_stub_case() { # <pid1-comm-file> -> doctor output plus a dz-result line
  local comm="$1"
  local home="${TMP}/home-stub-$(basename "$comm")"
  mkdir -p "$home/memories"
  cat > "$home/config" <<'CFG'
MINI_PROVIDER=local
MINI_BASE_MODEL=stub-model:1b
MINI_MODEL=stub-model:1b-64k
MINI_CTX=65536
CFG
  (
    export MINI_HOME="$home"
    export MINI_SYSTEMD_RUNTIME_DIR="$ABSENT"
    export MINI_PID1_COMM="$comm"
    export NO_COLOR=1
    # shellcheck disable=SC1090
    . "$MINI_BIN"
    # doctor's exit status is what is under test here, not a reason to abort
    # the run before the counters are reported.
    set +e

    # The host, minus systemd: healthy in every other respect.
    detect_all() {
      OS_ID='debian'; OS_LIKE='debian'; OS_NAME='Debian GNU/Linux 12'; OS_VERSION='12'
      OS_PLATFORM='debian'
      CPU_CORES=4; RAM_MB=16384; DISK_FREE_GB=100
      GPU_VENDOR='nvidia'; GPU_NAME='stub-gpu'; VRAM_MB=8192
      BUDGET_MB=8192; ACCEL='gpu'
      SUDO_MODE='nopasswd'
      export OS_ID OS_LIKE OS_NAME OS_VERSION OS_PLATFORM
      export CPU_CORES RAM_MB DISK_FREE_GB GPU_VENDOR GPU_NAME VRAM_MB
      export BUDGET_MB ACCEL SUDO_MODE
      detect_init   # the real probe — the fact under test
    }

    # Every unrelated check is stubbed: opencode and the tools are installed,
    # ollama serves, the model is present, every dependency and host tool is
    # on PATH. What is left is the init fact and nothing else.
    has() { return 0; }
    ollama() { printf 'ollama version is 0.0.0\n'; }
    ollama_up() { return 0; }
    ollama_version() { printf '0.0.0\n'; }
    ollama_public_bind() { return 0; }
    ollama_is_loopback() { return 0; }
    ollama_has_model() { return 0; }
    models_recommend() { printf 'stub-model:1b\n'; }
    doctor_opencode_section() { :; }
    doctor_tools_section() { :; }

    # Report the counters with every step title, so the step's own
    # contribution can be read off the run.
    step() { printf '\n%s\n' "$*"; printf 'dz-counters %s %s\n' "$DOCTOR_FAILS" "$DOCTOR_WARNS"; }

    doctor_run
    printf 'dz-result %s %s %s\n' "$?" "$DOCTOR_FAILS" "$DOCTOR_WARNS"
  ) 2>&1
}

# The counters doctor kept, as the stubbed run reports them.
stub_result() { # <output> rc|fails|warns
  printf '%s\n' "$1" | awk -v f="$2" '
    $1 == "dz-result" {
      if (f == "rc") print $2; else if (f == "fails") print $3; else print $4
      exit
    }'
}

# The counters right after a step title — that is, before that step ran.
stub_counters_at() { # <output> <step title> -> "fails warns"
  printf '%s\n' "$1" | awk -v t="$2" '
    $0 == t { f = 1; next }
    f && $1 == "dz-counters" { print $2, $3; exit }'
}

printf 'doctor counters on a stubbed host\n'

stub_systemd="$(doctor_stub_case "$COMM_SYSTEMD")"
stub_nosystemd="$(doctor_stub_case "$COMM_BASH")"

# A stubbed host with systemd is healthy outright.
expect "a healthy systemd host fails no check" "0" "$(stub_result "$stub_systemd" fails)"
expect "a healthy systemd host warns about nothing" "0" "$(stub_result "$stub_systemd" warns)"
expect "a healthy systemd host exits 0" "0" "$(stub_result "$stub_systemd" rc)"

# A stubbed host without systemd is still healthy: warnings, never failures.
expect "a healthy non-systemd host fails no check" "0" "$(stub_result "$stub_nosystemd" fails)"
expect "a healthy non-systemd host exits 0" "0" "$(stub_result "$stub_nosystemd" rc)"

# The Init step's own contribution: its title to the next step's title.
init_before="$(stub_counters_at "$stub_nosystemd" 'Init')"
init_after="$(stub_counters_at "$stub_nosystemd" 'Privileges')"
expect "the Init step adds no failed check" "0" \
  "$(( ${init_after%% *} - ${init_before%% *} ))"
expect "the Init step adds exactly one warning" "1" \
  "$(( ${init_after##* } - ${init_before##* } ))"

# And the same difference seen from the outside, host against host.
expect "a non-systemd host adds no failed check over a systemd one" "0" \
  "$(( $(stub_result "$stub_nosystemd" fails) - $(stub_result "$stub_systemd" fails) ))"
expect "a non-systemd host adds exactly two warnings (Init, systemctl)" "2" \
  "$(( $(stub_result "$stub_nosystemd" warns) - $(stub_result "$stub_systemd" warns) ))"

printf 'doctor Host tools step\n'

# systemctl is listed, but on a host without systemd a binary is not a
# working tool — and no fix line may offer to install it.
marker_tools="$(tools_section "$marker_out")"
contains "no systemd -> the systemctl line says systemd is not PID 1" \
  "systemd is not PID 1" "$marker_tools"
contains "no systemd -> the systemctl fix points at this host's own init" \
  "use this host's own init instead" "$marker_tools"
lacks "no systemd -> no fix line installs the systemctl package" \
  "apt install -y systemd" "$marker_tools"

# "installed but useless" and "missing" are two different branches, and only
# the first one can fire on a host that has the binary. Run it on a PATH that
# is guaranteed to hold one, so the case does not depend on the host mini
# happens to run on.
installed_out="$(doctor_case "$MARKER" "$COMM_BASH" local "${FAKEBIN}:${PATH}")"
installed_tools="$(tools_section "$installed_out")"
contains "no systemd + systemctl installed -> says installed but not PID 1" \
  "systemctl is installed but systemd is not PID 1" "$installed_tools"

# The missing branch only runs where there is no systemctl binary at all, and
# its old fix was "apt install -y systemd" — the one remedy that changes
# nothing when systemd is not PID 1. Reach it with a PATH that has no
# systemctl and pin what it says now.
nosys_out="$(doctor_case "$MARKER" "$COMM_BASH" local "$NOBIN")"
nosys_tools="$(tools_section "$nosys_out")"
contains "no systemd + no systemctl -> the missing line names the systemd state" \
  "systemctl missing — and systemd is not PID 1" "$nosys_tools"
lacks "no systemd + no systemctl -> not the 'installed but' line" \
  "systemctl is installed but systemd is not PID 1" "$nosys_tools"
contains "no systemd + no systemctl -> the fix points at this host's own init" \
  "use this host's own init instead" "$nosys_tools"
lacks "no systemd + no systemctl -> no fix line installs the systemctl package" \
  "apt install -y systemd" "$nosys_tools"

up_tools="$(tools_section "$up_out")"
lacks "PID 1 is systemd -> no systemctl caveat" "systemd is not PID 1" "$up_tools"

# The same Init step is printed on the remote-provider run.
remote_out="$(doctor_case "$ABSENT" "$COMM_BASH" remote)"
remote_section="$(init_section "$remote_out")"
contains "remote run -> prints the Init step" \
  "systemd is not running (PID 1: bash)" "$remote_section"
contains "remote run -> prints the container fix too" \
  "docker run --privileged --cgroupns=host" "$remote_section"
init_line_no="$(printf '%s\n' "$remote_out" | grep -n '^Init$' | head -n1 | cut -d: -f1)"
infer_line="$(printf '%s\n' "$remote_out" | grep -n '^Inference$' | head -n1 | cut -d: -f1)"
if [ -n "$init_line_no" ] && [ -n "$infer_line" ] && [ "$init_line_no" -lt "$infer_line" ]; then
  ok "remote run -> Init is printed before the remote early return"
else
  bad "remote run -> Init must be printed before Inference (init=${init_line_no:-none} inference=${infer_line:-none})"
fi

# ----------------------------------------------------------- host memory ----

printf 'host memory\n'

write_memory() { # <mini-home> <pid1-comm-file> -> writes the host memory
  local home="$1"
  mkdir -p "$home/memories"
  (
    export MINI_HOME="$home"
    export MINI_SYSTEMD_RUNTIME_DIR="$ABSENT"
    export MINI_PID1_COMM="$2"
    export NO_COLOR=1
    # shellcheck disable=SC1090
    . "${MINI_BIN}"
    detect_all
    write_host_memory
  ) >/dev/null 2>&1
}

mem_home="${TMP}/home-memory"
write_memory "$mem_home" "$COMM_BASH"
mem_file="${mem_home}/memories/00-host.md"
if [ -f "$mem_file" ]; then
  ok "write_host_memory wrote ${mem_file}"
else
  bad "write_host_memory wrote no host memory"
fi

mem_init_raw="$(sed -n 's/^- Init: //p' "$mem_file" | head -n1)"
mem_init="$(printf '%s\n' "$mem_init_raw" | sed 's/ — systemd is not PID 1.*$//; s/ (PID 1: /|/; s/)$//')"
expect "host memory reports the same init fact doctor reports" \
  "not systemd|bash" "$mem_init"
contains "host memory tells the agent systemctl does not work here" \
  "systemd is not PID 1, so systemctl and journalctl do not work here" "$mem_init_raw"

# doctor and the host memory must not drift apart.
doctor_init="$(printf '%s\n' "$marker_out" | grep -E '^[[:space:]]+Init[[:space:]]' | head -n1 | sed 's/^[[:space:]]*Init[[:space:]]*//')"
expect "doctor's Host section reports the same init fact" \
  "not systemd (PID 1: bash)" "$doctor_init"
expect "doctor's Host section and the host memory agree" \
  "$doctor_init" "$(printf '%s\n' "$mem_init_raw" | sed 's/ — systemd is not PID 1.*$//')"

mem_home_systemd="${TMP}/home-memory-systemd"
write_memory "$mem_home_systemd" "$COMM_SYSTEMD"
mem_file_systemd="${mem_home_systemd}/memories/00-host.md"
mem_init_systemd="$(sed -n 's/^- Init: //p' "$mem_file_systemd" | head -n1)"
expect "a systemd host carries no systemd caveat in the host memory" \
  "systemd (PID 1: systemd)" "$mem_init_systemd"

if grep -q '/run/systemd/system' "$MINI_BIN"; then
  bad "bin/mini must not probe /run/systemd/system itself"
else
  ok "bin/mini has no second inline /run/systemd/system test"
fi

# ------------------------------------------------------- dispatch guard ----

printf 'bin/mini dispatch guard\n'

# bin/mini runs its CLI only when it is executed, never when it is sourced, so
# a test can source it and call the functions against a temporary MINI_HOME.
# Both directions need a pin: executed must dispatch, sourced must not.
cli_out="$(bash "${MINI_BIN}" version 2>&1)"
cli_rc=$?
want_version="$(sed -n 's/^MINI_VERSION=//p' "${MINI_BIN}" | tr -d "'" | head -n1)"
expect "executing bin/mini dispatches to the CLI" "mini ${want_version}" "$cli_out"
if [ "$cli_rc" -eq 0 ]; then
  ok "executing bin/mini exits 0"
else
  bad "executing bin/mini exited ${cli_rc}"
fi

sourced_out="$( (
  # shellcheck disable=SC1090
  . "${MINI_BIN}"
) 2>&1 )"
expect "sourcing bin/mini runs no CLI command" "" "$sourced_out"

# ------------------------------------------------------------------ done ----

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
