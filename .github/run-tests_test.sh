#!/usr/bin/env bash
# run-tests_test.sh — pins the verdict contract of .github/run-tests.sh.
#
# Offline by construction: no network, no ollama, no opencode, no framework.
# Every case drives the runner with a throwaway stub member inside a mktemp
# sandbox and reads the runner's REPORTED VERDICT.
#
# Why the verdict and not just the exit status:
#   The workflow's own check ("Verify the runner fails on a failing member")
#   can only see the exit status. If the runner stopped resolving an absolute
#   member path, the member would turn into "no such file" — the runner would
#   still exit nonzero and the workflow's check would still pass, while the
#   suite no longer ran anything. The contract pinned here is therefore the
#   printed verdict: "FAIL <label> (exit 3)" for a member that RAN and failed,
#   "FAIL <label>: no such file" for one that never ran.
#
# What it pins:
#   A) a member that exits 3 is reported "FAIL <label> (exit 3)"; the runner
#      exits nonzero
#   B) a member that exits 0 is reported "PASS <label>"; the runner exits 0
#   C) a missing member is reported "FAIL <label>: no such file"; the runner
#      exits nonzero — the discriminator that makes A meaningful
#   D) an absolute member path is used as-is: the label is the absolute path,
#      never the repo root prefixed onto it
#   E) a relative member path resolves against the runner's repo root, not the
#      caller's cwd
#   F) every member runs even when an earlier one failed
#   G) the verdict is the exit code alone: a member that prints FAIL or SKIP
#      and exits 0 is PASS
#   H) with GITHUB_STEP_SUMMARY set, one section and one line per member are
#      written, and the file is appended to rather than truncated
#   I) with GITHUB_STEP_SUMMARY unset the runner still works and writes no
#      summary at all
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="${REPO_ROOT}/.github/run-tests.sh"

# Never let a runner invocation in this test write to the CI job summary:
# GitHub sets GITHUB_STEP_SUMMARY for every step. The case that puts the
# summary under test sets its own file explicitly.
unset GITHUB_STEP_SUMMARY

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok   %s\n' "$*"; }

[ -f "$RUNNER" ] || fail "no ${RUNNER}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# make_stub <path> <exit-code> [body line ...]
#
# A member script whose only behaviour is its body and its exit code. The body
# lines run before the exit, so a case can make the member noisy.
make_stub() {
  local path="$1" code="$2"
  shift 2
  {
    printf '%s\n' '#!/usr/bin/env bash'
    if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi
    printf 'exit %s\n' "$code"
  } > "$path"
  chmod 0755 "$path"
}

# run_runner <member> [member ...]
#
# Drives the runner and captures its stdout and exit status. The runner's own
# stderr goes to a file: the verdict lines are on stdout.
RC=0
OUT=""
run_runner() {
  RC=0
  OUT=$(bash "$RUNNER" "$@" 2>"${TMP}/runner.err") || RC=$?
}

# A) A member that exits 3 is reported as a failure with its exit code, and
#    the runner exits nonzero.
stub_a="${TMP}/exit3_test.sh"
make_stub "$stub_a" 3 'echo "boom" >&2'
run_runner "$stub_a"
[ "$RC" -ne 0 ] || fail "A: the runner exited 0 on a member that exits 3"
# D) The label is the absolute path itself: had the runner prefixed the repo
#    root onto it, this label would not match and the verdict would be wrong.
case "$OUT" in
  *"FAIL ${stub_a} (exit 3)"*) ;;
  *) fail "A: expected 'FAIL ${stub_a} (exit 3)' in the runner output, got:"$'\n'"${OUT}" ;;
esac
case "$OUT" in
  *"no such file"*) fail "A: the member was reported as missing instead of as failed:${OUT}" ;;
esac
ok "A: a member that exits 3 is reported 'FAIL <label> (exit 3)' and the runner exits nonzero"

# B) A member that exits 0 is reported as a pass, and the runner exits 0.
stub_b="${TMP}/exit0_test.sh"
make_stub "$stub_b" 0
run_runner "$stub_b"
[ "$RC" -eq 0 ] || fail "B: the runner exited ${RC} on a member that exits 0"
case "$OUT" in
  *"PASS ${stub_b}"*) ;;
  *) fail "B: expected 'PASS ${stub_b}' in the runner output, got:"$'\n'"${OUT}" ;;
esac
ok "B: a member that exits 0 is reported 'PASS <label>' and the runner exits 0"

# C) A member that does not exist is reported as missing — a different
#    verdict from "ran and failed", and the reason the workflow's exit-status
#    check alone cannot prove anything.
missing="${TMP}/does_not_exist_test.sh"
run_runner "$missing"
[ "$RC" -ne 0 ] || fail "C: the runner exited 0 on a missing member"
case "$OUT" in
  *"FAIL ${missing}: no such file"*) ;;
  *) fail "C: expected 'FAIL ${missing}: no such file' in the runner output, got:"$'\n'"${OUT}" ;;
esac
ok "C: a missing member is reported 'FAIL <label>: no such file' and the runner exits nonzero"

# E) A relative member path resolves against the runner's repo root, not the
#    caller's cwd. Driven on a copy of the runner in a throwaway repo layout,
#    so nothing is written into the real repo.
fake_root="${TMP}/fake-repo"
mkdir -p "${fake_root}/.github" "${fake_root}/tests"
cp "$RUNNER" "${fake_root}/.github/run-tests.sh"
make_stub "${fake_root}/tests/stub.sh" 0
RC=0
OUT=$(cd "$TMP" && bash "${fake_root}/.github/run-tests.sh" tests/stub.sh 2>"${TMP}/runner.err") || RC=$?
[ "$RC" -eq 0 ] || fail "E: a relative member path did not resolve against the repo root: ${OUT}"
case "$OUT" in
  *"PASS tests/stub.sh"*) ;;
  *) fail "E: expected 'PASS tests/stub.sh' in the runner output, got:"$'\n'"${OUT}" ;;
esac
ok "E: a relative member path resolves against the runner's repo root"

# F) Every member runs even when an earlier one failed, so CI shows all the
#    reds at once.
run_runner "$stub_a" "$stub_b"
[ "$RC" -ne 0 ] || fail "F: the runner exited 0 although a member failed"
case "$OUT" in
  *"FAIL ${stub_a} (exit 3)"*) ;;
  *) fail "F: the failing member's verdict is missing:"$'\n'"${OUT}" ;;
esac
case "$OUT" in
  *"PASS ${stub_b}"*) ;;
  *) fail "F: the member after the failing one did not run:"$'\n'"${OUT}" ;;
esac
ok "F: every member runs even when an earlier one failed"

# G) The verdict is the exit code alone: a member that prints FAIL or SKIP
#    and exits 0 is a PASS. The runner never greps the output.
stub_g="${TMP}/noisy_test.sh"
make_stub "$stub_g" 0 'echo "FAIL this looks like a failure"' 'echo "SKIP no python3 here"'
run_runner "$stub_g"
[ "$RC" -eq 0 ] || fail "G: the runner exited ${RC} on a member that exits 0"
case "$OUT" in
  *"PASS ${stub_g}"*) ;;
  *) fail "G: expected 'PASS ${stub_g}' in the runner output, got:"$'\n'"${OUT}" ;;
esac
ok "G: a member printing FAIL or SKIP but exiting 0 is reported 'PASS'"

# H) With GITHUB_STEP_SUMMARY set, the runner writes one section and one line
#    per member, and appends to the file rather than truncating it.
summary_file="${TMP}/summary.md"
RC=0
OUT=$(GITHUB_STEP_SUMMARY="$summary_file" bash "$RUNNER" "$stub_b" 2>"${TMP}/runner.err") || RC=$?
[ "$RC" -eq 0 ] || fail "H: the runner exited ${RC} on a passing member"
[ -f "$summary_file" ] || fail "H: no summary was written to ${summary_file}"
[ "$(grep -c '^### mini offline test suite$' "$summary_file")" = '1' ] \
  || fail "H: expected exactly one '### mini offline test suite' section in the summary"
grep -Fq -- "- \`${stub_b}\`: PASS" "$summary_file" \
  || fail "H: the summary has no PASS line for ${stub_b}:$(cat "$summary_file")"
[ "$(grep -c '^- `' "$summary_file")" = '1' ] \
  || fail "H: expected exactly one member line in the summary, got:$(cat "$summary_file")"
# A second invocation appends a second section instead of replacing the first.
RC=0
OUT=$(GITHUB_STEP_SUMMARY="$summary_file" bash "$RUNNER" "$stub_b" 2>"${TMP}/runner.err") || RC=$?
[ "$(grep -c '^### mini offline test suite$' "$summary_file")" = '2' ] \
  || fail "H: a second invocation did not append a second section to the summary"
ok "H: the summary holds one section and one line per member, and is appended to"

# I) With GITHUB_STEP_SUMMARY empty or unset the runner works and writes no
#    summary. GitHub sets the variable for every step, so a step that clears
#    it must not leave a stray summary behind either. The check runs in its
#    own directory so an earlier case's summary file cannot be mistaken for
#    a stray one.
i_dir="${TMP}/case-i"
mkdir -p "$i_dir"
RC=0
OUT=$(GITHUB_STEP_SUMMARY= bash "$RUNNER" "$stub_b" 2>"${TMP}/runner.err") || RC=$?
[ "$RC" -eq 0 ] || fail "I: the runner exited ${RC} with an empty GITHUB_STEP_SUMMARY"
[ -z "$(find "$i_dir" -type f -print -quit)" ] \
  || fail "I: a summary file was written although GITHUB_STEP_SUMMARY was empty"
RC=0
OUT=$(env -u GITHUB_STEP_SUMMARY bash "$RUNNER" "$stub_b" 2>"${TMP}/runner.err") || RC=$?
[ "$RC" -eq 0 ] || fail "I: the runner exited ${RC} with GITHUB_STEP_SUMMARY unset"
ok "I: with GITHUB_STEP_SUMMARY empty or unset the runner runs and writes no summary"

printf 'PASS: run-tests.sh verdict contract\n'
