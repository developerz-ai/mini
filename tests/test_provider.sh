#!/usr/bin/env bash
# test_provider.sh — pin the provider/model a launch names.
#
# mini launches opencode with one provider/model string. opencode resolves
# that string against $MINI_HOME/opencode.json, so the config and the launch
# have to agree: when they do not, opencode says "model not found" and the
# cause reads as a broken model instead of a stale config.
#
# Run: bash tests/test_provider.sh
#
# errexit is off on purpose — several cases run commands that must fail.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MINI_PLATFORMS="${ROOT}/platforms"

# mini's state lives in one directory. It has to exist before the libs are
# sourced: lib/ollama.sh reads MINI_HOME at source time.
MINI_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mini-provider-test.XXXXXX")"
HOMES=("${MINI_HOME}")

# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/ollama.sh
. "$ROOT/lib/ollama.sh"
# shellcheck source=../lib/opencode.sh
. "$ROOT/lib/opencode.sh"
# shellcheck source=../lib/doctor.sh
. "$ROOT/lib/doctor.sh"

# doctor_run is exercised for its provider checks only. Host detection and
# the outbound probes are stubbed, so the test is hermetic and never touches
# the network.
detect_all() {
  OS_ID='debian'; OS_LIKE=''; OS_NAME='Debian'; OS_VERSION='12'; OS_PLATFORM='debian'
  CPU_CORES=4; RAM_MB=8192; DISK_FREE_GB=50
  GPU_VENDOR='none'; GPU_NAME=''; VRAM_MB=0
  BUDGET_MB=4096; ACCEL='cpu'; SUDO_MODE='nopasswd'
}
detect_summary() { printf '  %-10s %s\n' 'OS' 'Debian (stub)'; }
curl() { return 1; }

PASSED=0
FAILED=0

# An empty $MINI_HOME per case: mini's state is a directory, so the cases
# must not share one.
new_home() {
  local h
  h="$(mktemp -d "${TMPDIR:-/tmp}/mini-provider-test.XXXXXX")" || return 1
  HOMES+=("$h")
  printf '%s' "$h"
}

cleanup() {
  local h
  for h in "${HOMES[@]}"; do rm -rf "$h"; done
}
trap cleanup EXIT

check_eq() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  ok    %s\n' "$1"
    return 0
  fi
  printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
  return 1
}

check_has() { # <name> <needle> <haystack>
  case "$3" in
    *"$2"*)
      printf '  ok    %s\n' "$1"
      return 0 ;;
  esac
  printf '  FAIL  %s\n         expected to contain: %s\n         actual: %s\n' "$1" "$2" "$3"
  return 1
}

check_fail() { # <name> <status>
  if [ "$2" -ne 0 ]; then
    printf '  ok    %s\n' "$1"
    return 0
  fi
  printf '  FAIL  %s\n         expected a non-zero exit, got %s\n' "$1" "$2"
  return 1
}

check_file_has() { # <name> <needle> <file>
  if grep -Fq "$2" "$3"; then
    printf '  ok    %s\n' "$1"
    return 0
  fi
  printf '  FAIL  %s\n         %s does not contain: %s\n' "$1" "$3" "$2"
  return 1
}

# (1) remote + URL + model -> the ref names the remote provider.
case_remote_ref() {
  local rc=0 out status
  MINI_HOME="$(new_home)"
  cfg_set MINI_PROVIDER remote
  cfg_set MINI_REMOTE_URL 'https://api.example.test/v1'
  cfg_set MINI_REMOTE_MODEL 'test-model-x'

  out="$(opencode_model_ref 2>/dev/null)"; status=$?
  check_eq "remote: ref is mini-remote/<model>" 'mini-remote/test-model-x' "$out" || rc=1
  check_eq "remote: ref exits 0" '0' "$status" || rc=1
  return $rc
}

# (2) remote without a URL -> refuse, and name the command that fixes it.
case_remote_no_url() {
  local rc=0 out status
  MINI_HOME="$(new_home)"
  cfg_set MINI_PROVIDER remote
  cfg_set MINI_REMOTE_URL ''
  cfg_set MINI_REMOTE_MODEL 'test-model-x'

  out="$(opencode_model_ref 2>&1)"; status=$?
  check_fail "remote without a URL exits non-zero" "$status" || rc=1
  check_has "remote without a URL names the fix" 'mini remote <url> <model> [key]' "$out" || rc=1
  return $rc
}

# (3) remote without a model -> same.
case_remote_no_model() {
  local rc=0 out status
  MINI_HOME="$(new_home)"
  cfg_set MINI_PROVIDER remote
  cfg_set MINI_REMOTE_URL 'https://api.example.test/v1'
  cfg_set MINI_REMOTE_MODEL ''

  out="$(opencode_model_ref 2>&1)"; status=$?
  check_fail "remote without a model exits non-zero" "$status" || rc=1
  check_has "remote without a model names the fix" 'mini remote <url> <model> [key]' "$out" || rc=1
  return $rc
}

# (4) local -> the ref names the local provider, with or without the
# provider key set (absent means local).
case_local_ref() {
  local rc=0 out
  MINI_HOME="$(new_home)"
  cfg_set MINI_PROVIDER local
  cfg_set MINI_MODEL 'mini-qwen2.5-coder-3b:16k'

  out="$(opencode_model_ref 2>/dev/null)"
  check_eq "local: ref is ollama/<model>" 'ollama/mini-qwen2.5-coder-3b:16k' "$out" || rc=1
  return $rc
}

case_local_ref_no_provider_key() {
  local rc=0 out
  MINI_HOME="$(new_home)"
  cfg_set MINI_MODEL 'mini-qwen2.5-coder-3b:16k'

  out="$(opencode_model_ref 2>/dev/null)"
  check_eq "local (no provider key): ref is ollama/<model>" 'ollama/mini-qwen2.5-coder-3b:16k' "$out" || rc=1
  return $rc
}

# (5) local without a model -> refuse.
case_local_no_model() {
  local rc=0 out status
  MINI_HOME="$(new_home)"
  cfg_set MINI_PROVIDER local

  out="$(opencode_model_ref 2>&1)"; status=$?
  check_fail "local without a model exits non-zero" "$status" || rc=1
  check_has "local without a model says so" 'no model configured' "$out" || rc=1
  return $rc
}

# (6) the ref never names a provider the generated config lacks: a config
# left behind by the local path is rewritten before the launch uses it.
case_stale_remote_config() {
  local rc=0 out
  MINI_HOME="$(new_home)"
  cfg_set MINI_PROVIDER remote
  cfg_set MINI_REMOTE_URL 'https://api.example.test/v1'
  cfg_set MINI_REMOTE_MODEL 'test-model-x'

  # What `mini remote` leaves behind when it dies before writing the config.
  cat > "${MINI_HOME}/opencode.json" <<'JSON'
{
  "provider": { "ollama": { "npm": "@ai-sdk/openai-compatible" } },
  "model": "ollama/local-model"
}
JSON

  out="$(opencode_model_ref 2>/dev/null)"
  check_eq "stale config: ref still names the remote model" 'mini-remote/test-model-x' "$out" || rc=1
  check_file_has "stale config: rewritten to declare mini-remote" '"mini-remote": {' "${MINI_HOME}/opencode.json" || rc=1
  check_file_has "stale config: rewritten to name the remote model" '"model": "mini-remote/test-model-x"' "${MINI_HOME}/opencode.json" || rc=1
  return $rc
}

# The launch itself: web and headless hand opencode the same ref, and the
# local mode still hands it the ollama one.
case_launch_flags() {
  local rc=0 out fake
  MINI_HOME="$(new_home)"

  # A fake opencode that prints its arguments instead of starting a server.
  fake="${MINI_HOME}/fake-opencode"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*"
SH
  chmod +x "$fake"
  opencode_bin() { printf '%s' "$fake"; }

  cfg_set MINI_PROVIDER remote
  cfg_set MINI_REMOTE_URL 'https://api.example.test/v1'
  cfg_set MINI_REMOTE_MODEL 'test-model-x'

  out="$(opencode_web web 2>/dev/null | grep -F -- '-m ')"
  check_has "mini web launches with the remote ref" '-m mini-remote/test-model-x' "$out" || rc=1
  check_has "mini web binds loopback by default" '--hostname 127.0.0.1' "$out" || rc=1

  out="$(opencode_web serve 2>/dev/null | grep -F -- '-m ')"
  check_has "mini headless launches with the remote ref" '-m mini-remote/test-model-x' "$out" || rc=1

  out="$(opencode_web web --lan 2>/dev/null | grep -F -- '-m ')"
  check_has "mini web --lan launches with the remote ref" '-m mini-remote/test-model-x' "$out" || rc=1
  check_has "mini web --lan binds every interface" '--hostname 0.0.0.0' "$out" || rc=1

  cfg_set MINI_PROVIDER local
  cfg_set MINI_MODEL 'mini-qwen2.5-coder-3b:16k'
  out="$(opencode_web web 2>/dev/null | grep -F -- '-m ')"
  check_has "local mode still launches with ollama/<model>" '-m ollama/mini-qwen2.5-coder-3b:16k' "$out" || rc=1
  return $rc
}

# (7) doctor names the same gap and the same fix.
case_doctor_remote_incomplete() {
  local rc=0 out status
  MINI_HOME="$(new_home)"
  cfg_set MINI_PROVIDER remote
  cfg_set MINI_REMOTE_URL ''
  cfg_set MINI_REMOTE_MODEL ''

  out="$(doctor_run 2>&1)"; status=$?
  check_fail "doctor: an incomplete remote setup fails" "$status" || rc=1
  check_has "doctor: reports the missing URL" 'no remote URL configured' "$out" || rc=1
  check_has "doctor: reports the missing model" 'no remote model configured' "$out" || rc=1
  check_has "doctor: prints the fix command" 'mini remote <url> <model> [key]' "$out" || rc=1
  return $rc
}

run_case() {
  local name="$1"; shift
  printf '\n%s\n' "$name"
  if "$@"; then
    PASSED=$((PASSED+1))
  else
    FAILED=$((FAILED+1))
  fi
}

run_case "remote: the ref names the remote provider"        case_remote_ref
run_case "remote: no URL"                                   case_remote_no_url
run_case "remote: no model"                                 case_remote_no_model
run_case "local: the ref names the local provider"           case_local_ref
run_case "local: provider key absent means local"            case_local_ref_no_provider_key
run_case "local: no model"                                  case_local_no_model
run_case "remote: a stale config is repaired"                case_stale_remote_config
run_case "the launch passes the ref to opencode"             case_launch_flags
run_case "doctor: an incomplete remote setup fails"          case_doctor_remote_incomplete

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
