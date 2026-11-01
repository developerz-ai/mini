#!/usr/bin/env bash
# tests/webfetch.sh — self-test for the share/tools/webfetch truncation and
# failure contract. Pure bash, no network: curl and w3m come from PATH stubs,
# every fixture is a local file. Run:  bash tests/webfetch.sh
#
# Pinned, per the fix that stopped an oversized fetch from reporting failure
# (a converter piped into head under pipefail used to die at SIGPIPE, exit 141):
#   converted, oversized      exit 0, '# URL', capped text, blank line,
#                             '… truncated at N chars of M. Re-run with -c to read more.'
#   converted, short          exit 0, exact bytes, no note
#   -r oversized              exit 0, exactly MAX_CHARS bytes
#   -c 010                    caps at ten (10#, never octal eight)
#   converter exits non-zero  exit 1, 'webfetch: conversion failed for …'
#   curl exits non-zero       exit 1, 'webfetch: request failed for …'
#   sed fallback, python3     same uniform cap + note
#   'set -euo pipefail'       still on line 10 of the script
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$ROOT/share/tools/webfetch
[ -f "$SCRIPT" ] || { printf 'tests/webfetch.sh: %s not found\n' "$SCRIPT" >&2; exit 1; }

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
TMP=$TMPROOT/t; mkdir "$TMP"
OUT=$TMP/out ERR=$TMP/err EXP=$TMP/exp

# Private bin dir: only the real coreutils the script touches. A converter
# exists for a case only when that case puts a stub (or a real python3) on
# the case PATH — this is how the sed fallback and python3 branch get selected.
BIN=$TMPROOT/bin; mkdir "$BIN"
for t in cat head sed tr; do ln -s "$(command -v "$t")" "$BIN/$t"; done

STUB=$TMPROOT/stub; mkdir "$STUB"
cat >"$STUB/curl" <<'EOF'
#!/bin/sh
# stub curl: serve $WEBFETCH_FIXTURE verbatim, or exit $WEBFETCH_CURL_FAIL.
if [ -n "${WEBFETCH_CURL_FAIL:-}" ]; then exit "$WEBFETCH_CURL_FAIL"; fi
cat "${WEBFETCH_FIXTURE:?WEBFETCH_FIXTURE not set}"
EOF
cat >"$STUB/w3m" <<'EOF'
#!/bin/sh
# stub w3m: identity converter (cat stdin), or exit $WEBFETCH_W3M_FAIL.
if [ -n "${WEBFETCH_W3M_FAIL:-}" ]; then exit "$WEBFETCH_W3M_FAIL"; fi
cat
EOF
chmod +x "$STUB/curl" "$STUB/w3m"

BASH_BIN=$(command -v bash)
ST=0
CASE_PATH=$PATH

run_wfetch() { # run_wfetch args... — stdout→$OUT, stderr→$ERR, status→$ST
  if env PATH="$CASE_PATH" \
      WEBFETCH_FIXTURE="${WEBFETCH_FIXTURE:-}" \
      WEBFETCH_CURL_FAIL="${WEBFETCH_CURL_FAIL:-}" \
      WEBFETCH_W3M_FAIL="${WEBFETCH_W3M_FAIL:-}" \
      "$BASH_BIN" "$SCRIPT" "$@" >"$OUT" 2>"$ERR"; then ST=0; else ST=$?; fi
}
case_path() { # case_path cmd... — a stub dir with exactly these commands on PATH
  local d t; d=$(mktemp -d "$TMPROOT/c.XXXXXX")
  for t in "$@"; do
    if [ -f "$STUB/$t" ]; then ln -s "$STUB/$t" "$d/$t"
    else ln -s "$(command -v "$t")" "$d/$t"; fi
  done
  CASE_PATH="$BIN:$d"
}
fixture() { # fixture <file> [curl_fail] [w3m_fail] — set the stub knobs
  WEBFETCH_FIXTURE=$1 WEBFETCH_CURL_FAIL=${2:-} WEBFETCH_W3M_FAIL=${3:-}
}
as_of_a() { # as_of_a <n> <file> — n 'a' bytes, no trailing newline
  head -c "$1" /dev/zero | tr '\0' 'a' >"$2"
}
html_of_a() { # html_of_a <n> <file> — '<p>' + n 'a' + '</p>'
  { printf '<p>'; head -c "$1" /dev/zero | tr '\0' 'a'; printf '</p>'; } >"$2"
}

pass=0; fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }
expect_st() { [ "$ST" = "$2" ] && ok "$1" || bad "$1 (exit $ST, want $2)"; }
expect_out() { # expect_out <desc> — $EXP vs stdout, byte for byte
  if cmp -s "$EXP" "$OUT"; then ok "$1"
  else bad "$1"; { echo '  want:'; sed 's/^/    /' "$EXP"; echo '  got:'; sed 's/^/    /' "$OUT"; } >&2; fi
}
expect_err() { # expect_err <desc> — $EXP vs stderr, byte for byte
  if cmp -s "$EXP" "$ERR"; then ok "$1"
  else bad "$1"; { echo '  want stderr:'; sed 's/^/    /' "$EXP"; echo '  got:'; sed 's/^/    /' "$ERR"; } >&2; fi
}
expect_err_empty() {
  [ ! -s "$ERR" ] && ok "$1" || { bad "$1 (stderr not empty)"; sed 's/^/    /' "$ERR" >&2; }
}

FIX=$TMP/fixture

# 1. Converted, oversized (w3m stub = cat): exit 0, '# URL', capped text,
#    blank line, note. The fixture exceeds the 64 KiB pipe buffer, so this is
#    the exact shape that used to SIGPIPE a converter piped into head.
as_of_a 200000 "$FIX"
case_path curl w3m
fixture "$FIX"
run_wfetch -c 1000 https://example.test/big
expect_st 'oversized converted: exit 0' 0
{ printf '# %s\n\n' 'https://example.test/big'
  head -c 1000 /dev/zero | tr '\0' 'a'
  printf '\n\n… truncated at 1000 chars of 200000. Re-run with -c to read more.\n'
} >"$EXP"
expect_out 'oversized converted: header + cap + blank line + note'
expect_err_empty 'oversized converted: stderr clean'

# 2. Identity converter: preserve zero, one, and multiple trailing newlines,
# both below and exactly at the cap. Expectations come from the fixture itself.
case_path curl w3m
for ending in '' $'\n' $'\n\n\n'; do
  printf '<p>hello world</p>%s' "$ending" >"$FIX"
  fixture "$FIX"
  for cap in 20000 "$(wc -c <"$FIX")"; do
    run_wfetch -c "$cap" https://example.test/short
    expect_st "short converted (ending ${#ending}, cap $cap): exit 0" 0
    { printf '# %s\n\n' 'https://example.test/short'; cat "$FIX"; } >"$EXP"
    expect_out "short converted (ending ${#ending}, cap $cap): exact fixture bytes"
    expect_err_empty 'short converted: stderr clean'
  done
done

# A trailing newline is part of converter output and counts toward the cap.
printf 'abc\n' >"$FIX"
fixture "$FIX"
run_wfetch -c 3 https://example.test/boundary
expect_st 'newline over boundary: exit 0' 0
{ printf '# https://example.test/boundary\n\nabc'
  printf '\n\n… truncated at 3 chars of 4. Re-run with -c to read more.\n'
} >"$EXP"
expect_out 'newline over boundary: cap before presentation separators'

# 3. Raw oversized: exactly MAX_CHARS bytes, no header, no note. Fixture is
#    larger than both the cap and the 64 KiB pipe buffer.
as_of_a 200001 "$FIX"
case_path curl
fixture "$FIX"
run_wfetch -r -c 1000 https://example.test/raw
expect_st 'raw oversized: exit 0' 0
head -c 1000 /dev/zero | tr '\0' 'a' >"$EXP"
expect_out 'raw oversized: exactly 1000 bytes'
expect_err_empty 'raw oversized: stderr clean'

# 4. A converter exiting non-zero stays a failure (exit 1 + message).
printf '<p>x</p>' >"$FIX"
case_path curl w3m
fixture "$FIX" '' 3
run_wfetch https://example.test/broken
expect_st 'converter exit 3: webfetch exit 1' 1
printf '# %s\n\n' 'https://example.test/broken' >"$EXP"
expect_out 'converter failure: header only on stdout'
printf 'webfetch: conversion failed for %s\n' 'https://example.test/broken' >"$EXP"
expect_err 'converter failure: message on stderr'

# 5. curl exiting non-zero stays a failure (exit 1 + message).
case_path curl
fixture "$FIX" 7
run_wfetch https://example.test/unreachable
expect_st 'curl exit 7: webfetch exit 1' 1
: >"$EXP"
expect_out 'curl failure: no stdout'
printf 'webfetch: request failed for %s\n' 'https://example.test/unreachable' >"$EXP"
expect_err 'curl failure: message on stderr'

# 6. -c 010 caps at ten: 10# normalization, never octal eight.
printf '0123456789%.0s' 1 2 3 4 5 >"$FIX"
case_path curl w3m
fixture "$FIX"
run_wfetch -c 010 https://example.test/octal
expect_st '-c 010: exit 0' 0
{ printf '# %s\n\n' 'https://example.test/octal'
  printf '0123456789'
  printf '\n\n… truncated at 10 chars of 50. Re-run with -c to read more.\n'
} >"$EXP"
expect_out '-c 010: caps at ten, not octal eight'

# 7. sed fallback (no w3m/lynx/python3 on PATH): same uniform cap + note.
#    '<p>' + 199994 a + '</p>' converts to ' ' + 199994 a + ' ' = 199996 chars.
html_of_a 199994 "$FIX"
case_path curl
fixture "$FIX"
run_wfetch -c 1000 https://example.test/sed
expect_st 'sed fallback oversized: exit 0' 0
{ printf '# %s\n\n' 'https://example.test/sed'
  printf ' '
  head -c 999 /dev/zero | tr '\0' 'a'
  printf '\n\n… truncated at 1000 chars of 199996. Re-run with -c to read more.\n'
} >"$EXP"
expect_out 'sed fallback oversized: cap + note'

# 8. sed fallback, short: exact bytes (its branch reprints no trailing newline).
printf '<p>hello</p>' >"$FIX"
case_path curl
fixture "$FIX"
run_wfetch https://example.test/sedshort
expect_st 'sed fallback short: exit 0' 0
{ printf '# %s\n\n' 'https://example.test/sedshort'; printf ' hello '; } >"$EXP"
expect_out 'sed fallback short: exact bytes, no note'

# 9 + 10. python3 branch — same uniform cap + note, and its NUL stripping
# (skipped when the box has no python3; the sed fallback covers that path).
if command -v python3 >/dev/null 2>&1; then
  # strip() drops the two spaces the tags become: 199994 chars of 'a'.
  html_of_a 199994 "$FIX"
  case_path curl python3
  fixture "$FIX"
  run_wfetch -c 1000 https://example.test/py
  expect_st 'python3 oversized: exit 0' 0
  { printf '# %s\n\n' 'https://example.test/py'
    head -c 1000 /dev/zero | tr '\0' 'a'
    printf '\n\n… truncated at 1000 chars of 199994. Re-run with -c to read more.\n'
  } >"$EXP"
  expect_out 'python3 oversized: cap + note'

  # Python counts Unicode characters even when Bash runs in the C locale.
  printf '<p>éé</p>' >"$FIX"
  fixture "$FIX"
  LC_ALL=C run_wfetch -c 1 https://example.test/utf8
  expect_st 'python3 UTF-8 under C locale: exit 0' 0
  { printf '# https://example.test/utf8\n\né\n'
    printf '\n… truncated at 1 chars of 2. Re-run with -c to read more.\n'
  } >"$EXP"
  expect_out 'python3 UTF-8 under C locale: complete character + note'
  expect_err_empty 'python3 UTF-8 under C locale: stderr clean'

  printf 'abc\000def' >"$FIX"
  case_path curl python3
  fixture "$FIX"
  run_wfetch https://example.test/nul
  expect_st 'python3 NUL: exit 0' 0
  { printf '# %s\n\n' 'https://example.test/nul'; printf 'abcdef\n'; } >"$EXP"
  expect_out 'python3 NUL: stripped, exact bytes'
  # bash drops the NUL earlier, at the curl capture (line 54), with its
  # documented warning. Pin that this is the ONLY stderr noise: one line,
  # that warning (path prefix varies per checkout, so match its invariant).
  if [ "$(wc -l <"$ERR")" -eq 1 ] && grep -Fq 'warning: command substitution: ignored null byte in input' "$ERR"; then
    ok 'python3 NUL: only the known bash NUL warning on stderr'
  else
    bad 'python3 NUL: unexpected stderr'; sed 's/^/    /' "$ERR" >&2
  fi
else
  printf 'skip python3 branch (no python3 on this box)\n'
fi

# 11. The pipefail guard is still the first line of the contract.
if [ "$(sed -n '10p' "$SCRIPT")" = 'set -euo pipefail' ]; then
  ok 'line 10: set -euo pipefail'
else
  bad 'line 10: set -euo pipefail missing'
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf 'PASS: %d checks\n' "$pass"
else
  printf 'FAIL: %d of %d checks failed\n' "$fail" "$((pass + fail))"
  exit 1
fi
