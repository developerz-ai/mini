#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export MINI_HOME="$work"
source lib/common.sh
source lib/ollama.sh

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
