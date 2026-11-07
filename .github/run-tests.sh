#!/usr/bin/env bash
# run-tests.sh — runs mini's offline test suite and reports one line per script.
#
# The suite is plain bash with no framework: every member under `tests/` is a
# standalone script that builds its own mktemp sandbox and stubs what it must
# not touch (curl, w3m, systemctl, sudo, the GPU probes). Nothing here starts
# a model service, reads a credential or reaches the network.
#
# Usage:
#   bash .github/run-tests.sh                 # every tests/*.sh
#   bash .github/run-tests.sh tests/webfetch.sh [more.sh ...]
#
# Rules this runner exists to enforce:
#   * Each member runs as its own `bash "$t"` process. Members export things
#     (MINI_YES=1 and friends) and must not leak into each other.
#   * Every member runs even when an earlier one fails, so CI shows all the
#     reds at once instead of one per push.
#   * The verdict is the member's EXIT CODE and nothing else. A member that
#     prints SKIP and exits 0 is green by its own contract; a member that
#     prints FAIL but exits 0 is still green. Never grep the output.
#
# The runner lives outside `tests/` on purpose: the repo's own canonical
# command is `for t in tests/*.sh; do bash "$t" || exit 1; done`, and a runner
# inside `tests/` would be swept up by that glob.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Members given on the command line replace the default list entirely.
# A relative member path is resolved against the repo root, so the runner
# behaves the same however it is invoked; an absolute path is left alone.
if [ "$#" -gt 0 ]; then
  MEMBERS=()
  for member in "$@"; do
    case "$member" in
      /*) MEMBERS+=("$member") ;;
      *)  MEMBERS+=("${REPO_ROOT}/${member}") ;;
    esac
  done
else
  # Anchored to the repo root, not the caller's cwd, so the runner works from
  # anywhere. Sorted for a stable order in the CI log.
  MEMBERS=()
  while IFS= read -r member; do
    [ -n "$member" ] && MEMBERS+=("${REPO_ROOT}/${member}")
  done < <(cd "$REPO_ROOT" && find tests -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)
fi

if [ "${#MEMBERS[@]}" -eq 0 ]; then
  printf 'FAIL: no test scripts found (expected tests/*.sh)\n' >&2
  exit 1
fi

failed=()
summary=""

for member in "${MEMBERS[@]}"; do
  # Display the member repo-relative when it lives under the repo root, so the
  # log reads `tests/webfetch.sh` rather than an absolute path.
  label="${member#${REPO_ROOT}/}"

  if [ ! -f "$member" ]; then
    printf 'FAIL %s: no such file\n' "$label"
    failed+=("$label")
    summary="${summary}- \`${label}\`: FAIL (no such file)
"
    continue
  fi

  printf '==> %s\n' "$label"
  if bash "$member"; then
    status=0
  else
    status=$?
  fi

  if [ "$status" -eq 0 ]; then
    printf 'PASS %s\n' "$label"
    summary="${summary}- \`${label}\`: PASS
"
  else
    printf 'FAIL %s (exit %s)\n' "$label" "$status"
    failed+=("$label")
    summary="${summary}- \`${label}\`: FAIL (exit ${status})
"
  fi
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### mini offline test suite\n\n'
    printf '%s' "$summary"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "${#failed[@]}" -gt 0 ]; then
  printf '\n%s test(s) failed: %s\n' "${#failed[@]}" "${failed[*]}" >&2
  exit 1
fi

printf '\nAll %s test script(s) passed.\n' "${#MEMBERS[@]}"
exit 0
