#!/usr/bin/env bash
# test_provider.sh — pin the provider/model a launch names.
#
# mini launches opencode with one provider/model string. opencode resolves
# that string against $MINI_HOME/opencode.json, so the config and the launch
# have to agree: when they do not, opencode says "model not found" and the
# cause reads as a broken model instead of a stale config.
#
# The --model run-only override pins the same agreement for one invocation:
# the launch names ollama/<variant> built from MINI_FORCE_MODEL and points
# OPENCODE_CONFIG at a run-scoped config of that launch's own, while the
# stored selection and the live config stay untouched.
#
# Run: bash tests/test_provider.sh
#
# errexit is off on purpose — several cases run commands that must fail.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MINI_PLATFORMS="${ROOT}/platforms"
# The override cases read the real model registry; lib/models.sh pins MODELS_TSV
# from MINI_SHARE at source time, so it must be findable before the libs load.
MINI_SHARE="${ROOT}/share"
export MINI_SHARE

# mini's state lives in one directory. It has to exist before the libs are
# sourced: lib/ollama.sh reads MINI_HOME at source time.
MINI_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mini-provider-test.XXXXXX")"
HOMES=("${MINI_HOME}")

# The run-scoped config of a --model launch is a per-invocation temp file.
# TMPDIR is pinned to a directory of this test's own, so a case can see
# exactly what mini leaves there — and one case's leftovers can never be
# mistaken for another's.
export TMPDIR="${MINI_HOME}/tmp"
mkdir -p "$TMPDIR"

# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/models.sh
. "$ROOT/lib/models.sh"
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

check_lacks() { # <name> <needle> <haystack>
  case "$3" in
    *"$2"*)
      printf '  FAIL  %s\n         expected NOT to contain: %s\n' "$1" "$2"
      return 1 ;;
  esac
  printf '  ok    %s\n' "$1"
  return 0
}

check_fail() { # <name> <status>
  if [ "$2" -ne 0 ]; then
    printf '  ok    %s\n' "$1"
    return 0
  fi
  printf '  FAIL  %s\n         expected a non-zero exit, got %s\n' "$1" "$2"
  return 1
}

check_true() { # <name> <command...>: ok when the command exits 0
  local name="$1"; shift
  if "$@"; then
    printf '  ok    %s\n' "$name"
    return 0
  fi
  printf '  FAIL  %s\n         %s failed\n' "$name" "$*"
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

# A fake opencode that prints its OPENCODE_CONFIG and its arguments, so the
# override cases can assert both halves of the launch contract: the ref (-m)
# and the config the launch points at. It also reports the model declared in
# the config it was handed — the launch and its config must agree, whatever
# else happens to the file in between.
new_fake_opencode() {
  FAKE_OPENCODE="${MINI_HOME}/fake-opencode"
  cat > "$FAKE_OPENCODE" <<'SH'
#!/usr/bin/env bash
printf 'cfg=%s\n' "${OPENCODE_CONFIG:-}"
printf 'declared=%s\n' "$(sed -n 's/^[[:space:]]*"model":[[:space:]]*"\([^"]*\)".*/\1/p' "${OPENCODE_CONFIG:-/dev/null}" 2>/dev/null | head -n1)"
printf '%s\n' "$*"
SH
  chmod +x "$FAKE_OPENCODE"
  opencode_bin() { printf '%s' "$FAKE_OPENCODE"; }
}

# Seed one stored local selection and a placeholder live config, then keep
# the case hermetic: ollama_has_model stubbed so models_ensure never talks to
# ollama (a real call would try to pull). run_case bodies run in the main
# shell, so MINI_FORCE_MODEL and the stub are unset/restored before the case
# returns — env leaking between cases flips later-case behavior.
new_override_home() {
  MINI_HOME="$(new_home)"
  export MINI_FORCE_MODEL='qwen2.5-coder:7b'

  cfg_set MINI_PROVIDER local
  cfg_set MINI_MODEL 'mini-qwen2.5-coder-3b:16k'
  cfg_set MINI_BASE_MODEL 'qwen2.5-coder:3b'
  cfg_set MINI_CTX 16384

  printf '{ "model": "ollama/mini-qwen2.5-coder-3b:16k" }\n' > "${MINI_HOME}/opencode.json"
  cp "${MINI_HOME}/opencode.json" "${MINI_HOME}/live-before.json"

  ollama_has_model() { return 0; }
  new_fake_opencode
}

override_hygiene() {
  unset MINI_FORCE_MODEL
  unset -f ollama_has_model
  # case_override_failure also stubs `ollama` itself so the pull fails; the
  # libs never define it, so unsetting is always safe.
  unset -f ollama
  # shellcheck source=../lib/ollama.sh
  . "$ROOT/lib/ollama.sh"
}

# (8) --model override, run path: the launch names the override variant and
# points at the run-scoped config; the stored selection and the live config
# are untouched. Stubbed budget 4096 + registry max_ctx 32768 give ctx 16384,
# variant mini-qwen2.5-coder-7b:16k.
case_run_override() {
  local rc=0 out run_cfg
  new_override_home

  out="$(opencode_run 2>/dev/null)"
  check_has 'override run: launches with the override variant' \
    '-m ollama/mini-qwen2.5-coder-7b:16k' "$out" || rc=1
  run_cfg=$(printf '%s\n' "$out" | sed -n 's/^cfg=//p' | head -n1)
  check_eq 'override run: the launch points at a config of its own' \
    'not the live config' \
    "$([ "$run_cfg" != "${MINI_HOME}/opencode.json" ] && printf 'not the live config' || printf 'the live config')" || rc=1
  check_true 'override run: the run-scoped config exists' test -f "$run_cfg" || rc=1
  check_has 'override run: the config it was handed declares that variant' \
    'declared=ollama/mini-qwen2.5-coder-7b:16k' "$out" || rc=1
  check_file_has 'override run: config declares the override variant' \
    '"model": "ollama/mini-qwen2.5-coder-7b:16k"' "$run_cfg" || rc=1
  check_file_has 'override run: config carries the 16k limit' \
    '"limit": { "context": 16384, "output": 2048 }' "$run_cfg" || rc=1
  check_eq 'override run: stored MINI_MODEL kept' \
    'mini-qwen2.5-coder-3b:16k' "$(cfg_get MINI_MODEL)" || rc=1
  check_eq 'override run: stored MINI_BASE_MODEL kept' \
    'qwen2.5-coder:3b' "$(cfg_get MINI_BASE_MODEL)" || rc=1
  check_eq 'override run: stored MINI_CTX kept' \
    '16384' "$(cfg_get MINI_CTX)" || rc=1
  check_eq 'override run: live config byte-identical' 'same' "$(cmp -s \
    "${MINI_HOME}/live-before.json" "${MINI_HOME}/opencode.json" && printf same || printf changed)" || rc=1

  override_hygiene
  return $rc
}

# (9) --model override, continuation path: `mini -c` resolves the same way.
case_continue_override() {
  local rc=0 out run_cfg
  new_override_home

  out="$(opencode_launch -c 2>/dev/null)"
  check_has 'override -c: launches with the override variant' \
    '-m ollama/mini-qwen2.5-coder-7b:16k' "$out" || rc=1
  check_has 'override -c: passes -c through to opencode' ' --auto -c' "$out" || rc=1
  run_cfg=$(printf '%s\n' "$out" | sed -n 's/^cfg=//p' | head -n1)
  check_eq 'override -c: the launch points at a config of its own' \
    'not the live config' \
    "$([ "$run_cfg" != "${MINI_HOME}/opencode.json" ] && printf 'not the live config' || printf 'the live config')" || rc=1
  check_true 'override -c: the run-scoped config exists' test -f "$run_cfg" || rc=1
  check_has 'override -c: the config it was handed declares that variant' \
    'declared=ollama/mini-qwen2.5-coder-7b:16k' "$out" || rc=1
  check_eq 'override -c: live config byte-identical' 'same' "$(cmp -s \
    "${MINI_HOME}/live-before.json" "${MINI_HOME}/opencode.json" && printf same || printf changed)" || rc=1

  override_hygiene
  return $rc
}

# (10) --model under remote inference: the override warns and is ignored —
# `mini remote` owns the model, so the launch keeps the remote ref and the
# live config.
case_run_override_remote_ignored() {
  local rc=0 out
  MINI_HOME="$(new_home)"
  export MINI_FORCE_MODEL='qwen2.5-coder:7b'

  cfg_set MINI_PROVIDER remote
  cfg_set MINI_REMOTE_URL 'https://api.example.test/v1'
  cfg_set MINI_REMOTE_MODEL 'test-model-x'

  new_fake_opencode
  out="$(opencode_run 2>&1)"

  check_has 'remote override: the configured remote model stays' \
    '-m mini-remote/test-model-x' "$out" || rc=1
  check_has 'remote override: still the live config' \
    "cfg=${MINI_HOME}/opencode.json" "$out" || rc=1
  check_has 'remote override: says the override was ignored' \
    'is a local-model override' "$out" || rc=1

  unset MINI_FORCE_MODEL
  return $rc
}

# (11) No --model: opencode_resolve_launch's default branch — the stored
# selection and the live config. case_launch_flags drives this branch too
# (opencode_web calls opencode_resolve_launch), but its fake prints only the
# arguments, so it pins only the -m ref; this case uniquely pins the config
# half: cfg=$MINI_HOME/opencode.json for both opencode_run and
# opencode_launch -c. Deleting the default
# MINI_LAUNCH_CONFIG="${MINI_HOME}/opencode.json" in lib/opencode.sh cannot
# leave this file green: set -u makes the unset variable fatal at the
# OPENCODE_CONFIG expansion, so this case fails and the file goes red.
case_launch_default() {
  local rc=0 out
  MINI_HOME="$(new_home)"
  # This case pins the no-override branch; say so instead of trusting the
  # cases before it to have cleaned up (run_case bodies share this shell).
  unset MINI_FORCE_MODEL
  cfg_set MINI_PROVIDER local
  cfg_set MINI_MODEL 'mini-qwen2.5-coder-3b:16k'
  new_fake_opencode

  out="$(opencode_run 2>/dev/null)"
  check_has 'no override: the run keeps the stored model' \
    '-m ollama/mini-qwen2.5-coder-3b:16k' "$out" || rc=1
  check_has 'no override: the run keeps the live config' \
    "cfg=${MINI_HOME}/opencode.json" "$out" || rc=1

  out="$(opencode_launch -c 2>/dev/null)"
  check_has 'no override: -c keeps the stored model' \
    '-m ollama/mini-qwen2.5-coder-3b:16k' "$out" || rc=1
  check_has 'no override: -c keeps the live config' \
    "cfg=${MINI_HOME}/opencode.json" "$out" || rc=1
  return $rc
}

# (12) A failed override refuses to launch — a failed resolution is not the
# same as there being nothing to override, and half a resolution would launch
# a ref its config never declares. models_ensure is made to fail
# deterministically (variant missing, base missing, `ollama` itself failing),
# so the pull inside it dies without network or daemon.
case_override_failure() {
  local rc=0 out status case_tmp
  new_override_home

  # A temp dir of this case's own: "nothing was left behind" has to be a
  # statement about this case, not about the ones before it.
  case_tmp="${TMPDIR}/case-failure"
  mkdir -p "$case_tmp"

  # Control: with the model present the run-scoped config lands in this
  # case's temp dir — so the assertion below is not vacuous, about a
  # directory mini never writes to.
  out="$(TMPDIR="$case_tmp" opencode_run 2>&1)"; status=$?
  check_eq 'failed override: the control run puts its config here' '1' \
    "$(ls -1 "$case_tmp" 2>/dev/null | grep -c 'mini-opencode-run' || true)" || rc=1
  rm -f "$case_tmp"/mini-opencode-run*

  ollama_has_model() { return 1; }  # the variant and the base are both "missing"
  ollama() { return 1; }            # so `ollama pull` fails and models_ensure dies

  out="$(TMPDIR="$case_tmp" opencode_run 2>&1)"; status=$?
  check_fail 'failed override: exits non-zero' "$status" || rc=1
  check_has 'failed override: says why' 'could not pull' "$out" || rc=1
  check_lacks 'failed override: opencode never launched' 'cfg=' "$out" || rc=1
  check_lacks 'failed override: never falls back to the stored model' \
    'mini-qwen2.5-coder-3b:16k' "$out" || rc=1
  check_eq 'failed override: no run-scoped config left behind' '0' \
    "$(ls -1 "$case_tmp" 2>/dev/null | grep -c 'mini-opencode-run' || true)" || rc=1

  override_hygiene
  return $rc
}

# (13) Two overlapping --model runs must not share a config.
#
# The bug this pins: both runs wrote the same opencode-run.json, so the
# second replaced the first's config before the first's opencode read it —
# the first then launched a model its config no longer declared.
#
# The fake opencode here reports the model declared in the config it was
# handed, and waits for a go-file before reading it. So the first run is held
# open inside its fake while the second run writes and launches: exactly the
# interleaving that breaks a shared path.
case_override_concurrent() {
  local rc=0 out_a out_b cfg_a cfg_b gate_a gate_b pid_a i=0
  new_override_home

  gate_a="${TMPDIR}/gate-a"; gate_b="${TMPDIR}/gate-b"
  rm -rf "$gate_a" "$gate_b"
  mkdir -p "$gate_a" "$gate_b"
  : > "$gate_b/go"          # the second run waits for nobody

  FAKE_OPENCODE="${MINI_HOME}/fake-opencode-wait"
  cat > "$FAKE_OPENCODE" <<'SH'
#!/usr/bin/env bash
cfg="${OPENCODE_CONFIG:-}"
printf 'cfg=%s\n' "$cfg"
: > "${MINI_TEST_GATE}/ready"
i=0
while [ ! -e "${MINI_TEST_GATE}/go" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
printf 'declared=%s\n' "$(sed -n 's/^[[:space:]]*"model":[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -n1)"
printf '%s\n' "$*"
SH
  chmod +x "$FAKE_OPENCODE"
  opencode_bin() { printf '%s' "$FAKE_OPENCODE"; }

  # The first run, held open inside its fake opencode.
  ( export MINI_TEST_GATE="$gate_a"
    opencode_run > "${TMPDIR}/run-a.out" 2>&1 ) &
  pid_a=$!

  while [ ! -e "$gate_a/ready" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  check_true 'concurrent overrides: the first run reached opencode' \
    test -e "$gate_a/ready" || rc=1

  # The second run, on a different model, all the way through.
  ( export MINI_FORCE_MODEL='llama3.2:3b'
    opencode_run > "${TMPDIR}/run-b.out" 2>&1 ) || rc=1

  # Now let the first run read the config it was handed.
  : > "$gate_a/go"
  wait "$pid_a"

  out_a="$(cat "${TMPDIR}/run-a.out")"; out_b="$(cat "${TMPDIR}/run-b.out")"
  cfg_a=$(printf '%s\n' "$out_a" | sed -n 's/^cfg=//p' | head -n1)
  cfg_b=$(printf '%s\n' "$out_b" | sed -n 's/^cfg=//p' | head -n1)

  check_eq 'concurrent overrides: the two runs got different configs' \
    'different' \
    "$([ -n "$cfg_a" ] && [ -n "$cfg_b" ] && [ "$cfg_a" != "$cfg_b" ] && printf different || printf same)" || rc=1
  check_has 'concurrent overrides: the first run still declares its own model' \
    'declared=ollama/mini-qwen2.5-coder-7b:16k' "$out_a" || rc=1
  check_has 'concurrent overrides: the second run declares its own model' \
    'declared=ollama/mini-llama3.2-3b:16k' "$out_b" || rc=1
  check_has 'concurrent overrides: the first run launches its own variant' \
    '-m ollama/mini-qwen2.5-coder-7b:16k' "$out_a" || rc=1
  check_has 'concurrent overrides: the second run launches its own variant' \
    '-m ollama/mini-llama3.2-3b:16k' "$out_b" || rc=1
  check_eq 'concurrent overrides: the live config is untouched' 'same' \
    "$(cmp -s "${MINI_HOME}/live-before.json" "${MINI_HOME}/opencode.json" && printf same || printf changed)" || rc=1

  override_hygiene
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
run_case "--model override: the run path uses the variant + run config" case_run_override
run_case "--model override: -c uses the variant + run config"          case_continue_override
run_case "--model override: remote ignores it"                          case_run_override_remote_ignored
run_case "no --model: stored model + live config"                       case_launch_default
run_case "--model override: a failed resolution refuses to launch"       case_override_failure
run_case "--model override: two overlapping runs keep their own config"   case_override_concurrent

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
