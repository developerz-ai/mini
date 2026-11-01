#!/usr/bin/env bash
# model_flag_test.sh — pins the missing-argument refusal of `mini --model`.
#
# Offline by construction: no network, no ollama, no opencode, no framework.
# bin/mini parses flags before any command runs, so the refusal fires before a
# single probe — the GPU stubs other tests need are not needed here.
#
# What it pins (the `--model)` case in main()):
#   A) `mini --model` with no value refuses with the usage line and nothing
#      runs. Without that guard it would export MINI_FORCE_MODEL='' and carry
#      on — the silent ignore-on-typo this flag must never do.
#   B) `mini --model ''` — a present-but-empty value is the same refusal.
#   C) a present value gets PAST the flag parse: the run stops at the next
#      gate (a fresh MINI_HOME has no opencode.json), never at the flag — so
#      the guard cannot rot into refusing everything.
#
# Each child gets an explicit environment: MINI_FORCE_MODEL is removed with
# env -u, so the ambient environment can neither satisfy nor shadow the parse.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MINI_BIN="${REPO_ROOT}/bin/mini"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok   %s\n' "$*"; }

[ -f "$MINI_BIN" ] || fail "no ${MINI_BIN}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

USAGE='usage: mini --model <id>'

# run_mini <name> <args...> — run bin/mini with the given args in a fresh,
# empty MINI_HOME. rc and out/err land under $TMP/<name>.*.
run_mini() {
  local name="$1"; shift
  rc=0
  env -u MINI_FORCE_MODEL -u MINI_YES \
    HOME="${TMP}/home-${name}" MINI_HOME="${TMP}/mini-${name}" \
    bash "$MINI_BIN" "$@" > "${TMP}/${name}.out" 2> "${TMP}/${name}.err" || rc=$?
}

# A) no value -> the usage refusal, and nothing else happens.
run_mini no-value --model
[ "$rc" -ne 0 ] || fail "no value: mini --model exited 0 — stderr: '$(cat "${TMP}/no-value.err")'"
grep -Fq "$USAGE" "${TMP}/no-value.err" \
  || fail "no value: refusal does not name the usage: '$(cat "${TMP}/no-value.err")'"
grep -Fq 'mini is not set up yet' "${TMP}/no-value.err" \
  && fail 'no value: the guard was skipped — mini dispatched instead'
[ ! -e "${TMP}/mini-no-value/config" ] || fail 'no value: the refusal wrote a config'
[ ! -e "${TMP}/mini-no-value/opencode.json" ] || fail 'no value: the refusal wrote a live config'
ok 'no value: mini --model refuses with the usage line before any dispatch'

# B) a present-but-empty value is the same refusal.
run_mini empty-value --model ''
[ "$rc" -ne 0 ] || fail 'empty value: mini --model "" exited 0'
grep -Fq "$USAGE" "${TMP}/empty-value.err" \
  || fail "empty value: no usage refusal (exit $rc): '$(cat "${TMP}/empty-value.err")'"
ok "empty value: mini --model '' refuses the same way"

# C) control: a present value is accepted at the flag parse.
run_mini with-value --model qwen2.5-coder:7b 'what is eating my disk'
[ "$rc" -ne 0 ] || fail 'with value: expected the not-set-up gate, got exit 0'
grep -Fq 'mini is not set up yet' "${TMP}/with-value.err" \
  || fail "with value: never reached the not-set-up gate (exit $rc): '$(cat "${TMP}/with-value.err")'"
grep -Fq "$USAGE" "${TMP}/with-value.err" \
  && fail 'with value: the guard refused a present value'
ok 'with value: accepted at the flag parse, stops at the next gate'

printf 'PASS: mini --model missing-argument refusal\n'
