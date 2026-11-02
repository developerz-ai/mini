#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export MINI_HOME="$work"
source lib/common.sh
source lib/ollama.sh

# Keep writer/rebind stubs isolated from the stop tests below.
(
# Exercise the real writer without touching the host's systemd configuration.
definition=$(declare -f ollama_write_systemd_dropin)
eval "${definition//\/etc\/systemd\/system\/ollama.service.d/$work/dropin}"
unset SUDO_MODE
export OLLAMA_HOST_ADDR=127.0.0.1:11434
has() { return 0; }
sudo() { _mini_sudo "$@"; }
ollama_systemd_managed() { return 0; }
ollama_up() { return 0; } # The old public listener remains healthy.
ollama_wait() { printf 'wait\n' >> "$work/events"; return 0; }
ollama_public_bind() { printf '0.0.0.0:11434\n'; }
_mini_sudo() {
  if [ "$1" = systemctl ]; then
    printf '%s\n' "$2" >> "$work/events"
    [ "$2" != "$failure" ]
  elif [ "$1" = mkdir ]; then
    mkdir -p "$work/dropin"
  else
    "$@"
  fi
}

for failure in daemon-reload restart; do
  rm -rf "$work/dropin"
  for attempt in 1 2; do
    : > "$work/events"
    if (ollama_bind_local) > "$work/output" 2>&1; then
      printf 'FAIL: local rebind accepted %s failure on attempt %s with a healthy old listener\n' "$failure" "$attempt" >&2
      exit 1
    fi
    if grep -Eq 'rebound|tuned ollama' "$work/output" || grep -q '^wait$' "$work/events"; then
      printf 'FAIL: local rebind reported success or waited after %s failure\n' "$failure" >&2
      exit 1
    fi
    grep -q '^daemon-reload$' "$work/events"
    if [ "$failure" = daemon-reload ] && grep -q '^restart$' "$work/events"; then
      printf 'FAIL: restarted after failed daemon-reload\n' >&2
      exit 1
    fi
    if [ "$failure" = restart ]; then
      grep -q '^restart$' "$work/events"
    fi
    test -f "$work/dropin/10-mini.conf"
  done

  # Recover without deleting the failed drop-in, then retain the applied shortcut.
  (
    failure=none
    : > "$work/events"
    ollama_bind_local > "$work/output" 2>&1
    grep -q '^daemon-reload$' "$work/events"
    grep -q '^restart$' "$work/events"
    grep -q 'ollama rebound' "$work/output"
    : > "$work/events"
    ollama_bind_local > "$work/output" 2>&1
    if grep -Eq '^(daemon-reload|restart)$' "$work/events"; then
      printf 'FAIL: reapplied an already successful drop-in\n' >&2
      exit 1
    fi
  )
  printf 'PASS: %s retries fail closed and recover without deleting the drop-in\n' "$failure"

  rm -rf "$work/dropin"
  ollama_tune > "$work/output" 2>&1
  rm -rf "$work/dropin"
  (ollama_up() { return 1; }; ollama_start) > "$work/output" 2>&1
  printf 'PASS: %s failure blocks local rebind; tune/start remain best-effort\n' "$failure"
done

failure=none
rm -rf "$work/dropin"
ollama_bind_local > "$work/output" 2>&1
grep -q 'ollama rebound' "$work/output"
printf 'PASS: successful reload/restart allows local rebind\n'
)

# Exercise both the library and the actual CLI dispatch. Exported functions
# shadow systemctl and Bash's kill builtin in the child too: no real service
# or process is ever stopped, even if the code takes an unexpected branch.
(
  export STOP_EVENTS="$work/stop-events" STOP_ACTIVE=1
  systemctl() {
    printf 'systemctl %s\n' "$*" >> "$STOP_EVENTS"
    case "$*" in
      'list-unit-files ollama.service') return 0 ;;
      'is-active --quiet ollama') [ "$STOP_ACTIVE" = 1 ] ;;
      *) printf 'unexpected systemctl call: %s\n' "$*" >&2; return 99 ;;
    esac
  }
  kill() {
    printf 'kill %s\n' "$*" >> "$STOP_EVENTS"
    case "$*" in
      '-0 424242'|'424242') return 0 ;;
      *) printf 'unexpected kill call: %s\n' "$*" >&2; return 99 ;;
    esac
  }
  export -f systemctl kill

  run_stop() {
    case "$entry" in
      library) ollama_stop ;;
      cli) bash bin/mini stop ;;
    esac
  }
  for entry in library cli; do
    rm -f "$OLLAMA_PIDFILE"
    STOP_ACTIVE=1
    : > "$STOP_EVENTS"
    status=0
    run_stop > "$work/stop-out" 2> "$work/stop-err" || status=$?
    if [ "$status" -ne 1 ]; then
      printf 'FAIL: %s systemd refusal returned %s, expected 1\n' "$entry" "$status" >&2
      exit 1
    fi
    grep -q 'stop it with: sudo systemctl stop ollama' "$work/stop-err"
    printf 'systemctl list-unit-files ollama.service\nsystemctl is-active --quiet ollama\n' > "$work/stop-expected"
    cmp "$work/stop-expected" "$STOP_EVENTS"
    printf 'PASS: %s systemd refusal returns 1 with actionable stderr\n' "$entry"

    # A mini-owned process takes priority, even with an active systemd unit.
    printf '424242\n' > "$OLLAMA_PIDFILE"
    : > "$STOP_EVENTS"
    run_stop > "$work/stop-out" 2> "$work/stop-err"
    test ! -e "$OLLAMA_PIDFILE"
    printf 'kill -0 424242\nkill 424242\n' > "$work/stop-expected"
    cmp "$work/stop-expected" "$STOP_EVENTS"
    printf 'PASS: %s mini-owned stop returns 0 and removes pidfile\n' "$entry"

    STOP_ACTIVE=0
    for attempt in 1 2; do
      : > "$STOP_EVENTS"
      run_stop > "$work/stop-out" 2> "$work/stop-err"
      test ! -e "$OLLAMA_PIDFILE"
      grep -q 'nothing to stop' "$work/stop-out"
      printf 'systemctl list-unit-files ollama.service\nsystemctl is-active --quiet ollama\n' > "$work/stop-expected"
      cmp "$work/stop-expected" "$STOP_EVENTS"
    done
    printf 'PASS: %s idle/repeated stop returns 0 without killing anything\n' "$entry"
  done
)
