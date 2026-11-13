#!/usr/bin/env bash
# check_test.sh — pins the reserved exit codes of bin/check.
#
# bin/check reserves exit codes that the platform reads:
#   75  shellcheck is unreachable -> the gate refuses to grade; the box is at fault
#   79  a scoped run (bin/check <files…>) passed -> the suite was skipped, CI grades the rest
#   1   a scoped run over a file that does not parse
# No suite member ran bin/check, so deleting either refusal (bin/check's 75
# guard, its scoped 79) left the suite green. Each code is pinned here
# instead.
#
# The FULL gate is never run from here: it runs this suite, so it would
# recurse. Every case below passes a file, so the scoped path is the only one
# reachable, and the guard at the top stops a nested invocation should a
# regression drop the scoped path entirely.
#
# Hermetic: own mktemp sandbox, a PATH holding only a stub dir, a stub
# shellcheck that decides what the lint step says. No network, no host
# toolchain, no credential.
#
#   bash tests/check_test.sh
set -euo pipefail

# Recursion guard: the full gate runs this suite, so a nested invocation of
# this script (bin/check -> run-tests.sh -> here) stops at once. The outer
# case then sees the wrong exit code and fails loudly instead of forking
# forever. MINI_CHECK_TEST=1 in the environment means "inside the gate".
if [ "${MINI_CHECK_TEST:-0}" = 1 ]; then
  exit 0
fi
MINI_CHECK_TEST=1
export MINI_CHECK_TEST

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${REPO_ROOT}/bin/check"
BASH_BIN=$(command -v bash)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok   %s\n' "$*"; }

[ -f "$CHECK" ] || fail "no ${CHECK}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# mkstub <name> [shellcheck] — a PATH dir holding bash and dirname (bin/check
# needs both: `dirname` to find the repo root, `bash -n` to parse a file) and,
# when asked, a shellcheck stub that logs its arguments and exits 0.
# $TMP/<name>/calls.log collects what the stub saw.
mkstub() {
  local name="$1" with_sc="${2:-}" dir="${TMP}/${1}/bin"
  mkdir -p "${dir}" "${TMP}/${name}/home"
  ln -s "$(PATH=/usr/bin:/bin command -v dirname)" "${dir}/dirname"
  ln -s "$BASH_BIN" "${dir}/bash"
  if [ "$with_sc" = shellcheck ]; then
    cat > "${dir}/shellcheck" <<EOF
#!/bin/sh
echo "shellcheck \$*" >> "\${0%/*}/../calls.log"
exit 0
EOF
    chmod +x "${dir}/shellcheck"
    : > "${TMP}/${name}/calls.log"
  fi
}

# run_check <name> <file…> — run bin/check with PATH = the stub dir only, so
# the host's shellcheck is never seen. rc, out and err land in $rc,
# $TMP/<name>/out and $TMP/<name>/err.
run_check() {
  local name="$1"; shift
  rc=0
  env -i HOME="${TMP}/${name}/home" PATH="${TMP}/${name}/bin" MINI_CHECK_TEST=1 \
    "$BASH_BIN" "$CHECK" "$@" > "${TMP}/${name}/out" 2> "${TMP}/${name}/err" || rc=$?
}

errs()  { cat "${TMP}/${1}/err"; }
calls() { cat "${TMP}/${1}/calls.log" 2>/dev/null || true; }

# The fixtures: one file that parses and one that does not.
CLEAN="${TMP}/clean.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo hello' > "$CLEAN"

BROKEN="${TMP}/broken.sh"
printf '%s\n' '#!/usr/bin/env bash' 'if true; then' '  echo hi' > "$BROKEN"

# ---------------------------------------------------------------- 75 ----
# No shellcheck on PATH -> the gate refuses to grade with 75 and says how to
# fix it. The file argument keeps the run scoped: without it, a regression
# that deletes the refusal would fall through to the full gate, which runs
# this suite again.
mkstub nosc
run_check nosc "$CLEAN"
[ "$rc" -eq 75 ] || fail "no shellcheck: expected exit 75, got ${rc} — stderr: '$(errs nosc)'"
errs nosc | grep -Fq 'bin/setup' \
  || fail "no shellcheck: the refusal does not name the fix (bin/setup): '$(errs nosc)'"
ok 'no shellcheck: exit 75, the refusal names bin/setup'

# ---------------------------------------------------------------- 79 ----
# A scoped run over a clean file -> 79 (the suite was skipped, CI grades the
# rest). The stub shellcheck is green, so 79 can only come from the scoped
# path finishing, and the log proves the named file was the one linted.
mkstub scoped shellcheck
run_check scoped "$CLEAN"
[ "$rc" -eq 79 ] || fail "scoped, clean file: expected exit 79, got ${rc} — stderr: '$(errs scoped)'"
calls scoped | grep -Fq "$CLEAN" \
  || fail "scoped, clean file: shellcheck was not run on the named file: '$(calls scoped)'"
ok 'scoped run over a clean file: exit 79, the named file was linted'

# ----------------------------------------------------------------- 1 ----
# A scoped run over a file that does not parse -> 1, never 79. The stub
# shellcheck is green here too, so the red cannot have come from the lint
# step: it is the syntax check refusing the file.
mkstub broken shellcheck
run_check broken "$BROKEN"
[ "$rc" -eq 1 ] || fail "scoped, syntax error: expected exit 1, got ${rc} — stderr: '$(errs broken)'"
[ "$rc" -ne 79 ] || fail 'scoped, syntax error: exit 79 would report a broken file as passed'
ok 'scoped run over a file with a syntax error: exit 1, never 79'

printf 'PASS: bin/check exit codes — 75 without shellcheck, 79 scoped, 1 on a syntax error\n'
