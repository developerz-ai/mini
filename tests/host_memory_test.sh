#!/usr/bin/env bash
# host_memory_test.sh — pins write_host_memory, the writer of
# $MINI_HOME/memories/00-host.md.
#
# What it pins:
#   A) the writer creates $MINI_HOME/memories when only $MINI_HOME exists, and
#      writes 00-host.md into it, carrying the host facts it was handed;
#   B) a pre-existing 10-learned.md is byte-identical afterwards — the writer
#      only ever touches 00-host.md — and 00-host.md is replaced, not
#      truncated and rewritten in place;
#   B2) the writer stands on its own: with no host fact detected at all,
#      every unset variable falls back to a placeholder instead of aborting
#      the write with "unbound variable";
#   B3) a GPU with no name leaves the GPU line as "none" — a VRAM figure on
#      its own is not a GPU;
#   C) a genuine write failure ($MINI_HOME/memories exists as a regular file)
#      exits non-zero, names that path and prints no success line;
#   D) a write that fails leaves the previous 00-host.md intact — the file is
#      replaced atomically, never truncated in place — and the failure comes
#      out through mini's error channel, not as a raw shell error;
#   D1) a write that fails and whose cleanup fails with it still reports
#      through mini's error channel: cleaning up must not swallow the report;
#   D2) a replace that fails and whose cleanup fails with it still reports
#      through mini's error channel: cleaning up must not swallow the report;
#   E) `mini sudo` on a box where setup never ran exits 0 and writes
#      00-host.md — util-linux script provides the tty the prompt needs, and
#      stubbed sudo/visudo keep the real /etc/sudoers.d untouched;
#   F) `mini sudo` on a box where sudo is already passwordless exits 0 and
#      refreshes 00-host.md — the nopasswd early return must not skip the
#      writer.
#
# Offline by construction: no network, no ollama, no opencode, no framework.
# Everything happens inside a throwaway MINI_HOME and TMPDIR. The `mini sudo`
# cases are skipped as root: there the sudo mode is "root", so the stubbed
# sudo is never called and the case would prove nothing.
#
# The helpers are fail()/pass(), not fail()/ok(): sourcing bin/mini brings in
# lib/common.sh, whose ok() is the writer's own success line.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MINI_BIN="${REPO_ROOT}/bin/mini"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

# mini's own error line, stripped of the shell's raw error output around it.
# A failure has to be reported by mini and name the path in mini's message: a
# path that only shows up in mv's "Permission denied" is not a report.
mini_error_line() {
  printf '%s\n' "$1" | grep '✗' | head -n1 || true
}

[ -f "$MINI_BIN" ] || fail "no ${MINI_BIN}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- writer ----
# MINI_HOME is exported before bin/mini is sourced: the file reads it at load
# time, and the writer must write where the caller says.
export MINI_HOME="${TMP}/mini"
mkdir -p "$MINI_HOME"

# shellcheck source=bin/mini
source "$MINI_BIN"

# Deterministic host facts. The writer reads detect.sh's variables, and every
# one of them has a default — but pin them anyway so the file content does
# not depend on the machine the test runs on.
OS_NAME='TestOS'; OS_ID='testos'; OS_VERSION='1.0'
CPU_CORES=4; RAM_MB=8192; DISK_FREE_GB=100
export OS_NAME OS_ID OS_VERSION CPU_CORES RAM_MB DISK_FREE_GB

# A) the writer creates its own directory and writes 00-host.md into it.
rm -rf "${MINI_HOME}/memories"
rc=0
out=$( write_host_memory 2>&1 ) || rc=$?

if [ "$rc" -ne 0 ]; then
  fail "the writer exited ${rc} with only ${MINI_HOME} present: ${out}"
fi
if [ ! -d "${MINI_HOME}/memories" ]; then
  fail "the writer did not create ${MINI_HOME}/memories"
fi
if [ ! -f "${MINI_HOME}/memories/00-host.md" ]; then
  fail "the writer did not write ${MINI_HOME}/memories/00-host.md"
fi
if ! grep -q '^# This machine' "${MINI_HOME}/memories/00-host.md"; then
  fail "00-host.md does not carry the host facts"
fi
# The facts the writer was handed must land in the file: a writer that wrote
# the title and nothing else would pass the check above.
for fact in 'TestOS' '4 cores' '8192 MB'; do
  if ! grep -qF -- "$fact" "${MINI_HOME}/memories/00-host.md"; then
    fail "00-host.md does not carry the host fact: ${fact}"
  fi
done
case "$out" in
  *"wrote host memory"*) ;;
  *) fail "the writer did not report success: ${out}" ;;
esac
pass "the writer creates ${MINI_HOME}/memories and writes 00-host.md"

# B) the other memory files are never touched.
printf '# Learned about this machine\n\n- postgres runs on port 5433\n' \
  > "${MINI_HOME}/memories/10-learned.md"
cp "${MINI_HOME}/memories/10-learned.md" "${TMP}/10-learned.md.orig"

# Replaced, not rewritten in place. The inode is the witness: a file published
# with temp file + mv carries a new inode, while a file truncated and
# rewritten in place keeps the old one. That is the difference between a
# write that cannot lose the previous content and one that can.
have_stat=0
if command -v stat >/dev/null 2>&1; then
  have_stat=1
  before_inode=$(stat -c %i "${MINI_HOME}/memories/00-host.md")
fi

rc=0
out=$( write_host_memory 2>&1 ) || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "the writer exited ${rc} on a second run: ${out}"
fi
if [ "$have_stat" -eq 1 ]; then
  after_inode=$(stat -c %i "${MINI_HOME}/memories/00-host.md")
  if [ "$before_inode" = "$after_inode" ]; then
    fail "the writer rewrote 00-host.md in place instead of replacing it"
  fi
fi
if ! cmp -s "${MINI_HOME}/memories/10-learned.md" "${TMP}/10-learned.md.orig"; then
  fail "the writer changed 10-learned.md"
fi
leftovers=$(find "${MINI_HOME}/memories" -name '*.tmp.*' | wc -l)
if [ "$leftovers" -ne 0 ]; then
  fail "the writer left ${leftovers} temp file(s) in ${MINI_HOME}/memories"
fi
pass "10-learned.md is byte-identical after the writer runs"

# B2) the writer stands on its own: `mini sudo` calls it on a box where
# `mini setup` never ran, so detect.sh may not have set a single variable.
# An unset one must fall back to a placeholder, not abort the write.
unset OS_NAME OS_ID OS_VERSION CPU_CORES RAM_MB DISK_FREE_GB SUDO_MODE

rc=0
out=$( write_host_memory 2>&1 ) || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "the writer exited ${rc} with no host fact detected: ${out}"
fi
case "$out" in
  *"unbound variable"*) fail "the writer aborted on an unset detect variable: ${out}" ;;
esac
host_file="${MINI_HOME}/memories/00-host.md"
for fallback in 'OS: unknown' 'CPU: unknown cores' 'RAM: unknown MB'; do
  if ! grep -qF -- "$fallback" "$host_file"; then
    fail "00-host.md does not fall back to '${fallback}': $(cat "$host_file" 2>/dev/null || true)"
  fi
done
if ! grep -qx -- '- GPU: none' "$host_file"; then
  fail "00-host.md does not report 'GPU: none' without a detected GPU: $(grep -- '- GPU:' "$host_file" 2>/dev/null || true)"
fi
pass "the writer falls back to placeholders when no host fact was detected"

# Re-pin the facts for the cases below.
OS_NAME='TestOS'; OS_ID='testos'; OS_VERSION='1.0'
CPU_CORES=4; RAM_MB=8192; DISK_FREE_GB=100
export OS_NAME OS_ID OS_VERSION CPU_CORES RAM_MB DISK_FREE_GB

# B3) a GPU with no name must not produce a nameless GPU line: the name is
# what the line is built from, so without it the line stays "none" — a VRAM
# figure on its own is not a GPU.
GPU_NAME=''; VRAM_MB=8192
export GPU_NAME VRAM_MB

rc=0
out=$( write_host_memory 2>&1 ) || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "the writer exited ${rc} with an empty GPU name: ${out}"
fi
gpu_line=$(grep -- '- GPU:' "${MINI_HOME}/memories/00-host.md" 2>/dev/null || true)
if [ "$gpu_line" != '- GPU: none' ]; then
  fail "an empty GPU name produced the GPU line '${gpu_line}' instead of '- GPU: none'"
fi
pass "an empty GPU name leaves the GPU line as 'none'"

# Leave no GPU behind for the cases below.
unset GPU_NAME VRAM_MB

# C) a genuine write failure: the memories path is a regular file.
rm -rf "${MINI_HOME}/memories"
: > "${MINI_HOME}/memories"

rc=0
out=$( write_host_memory 2>&1 ) || rc=$?
if [ "$rc" -eq 0 ]; then
  fail "the writer exited 0 although ${MINI_HOME}/memories is a regular file"
fi
case "$out" in
  *"wrote host memory"*) fail "the writer printed a success line on failure: ${out}" ;;
esac
# The failure is reported by mini (err/die), not left to a raw shell error,
# and mini's own message names the path.
err_line=$(mini_error_line "$out")
case "$err_line" in
  *"${MINI_HOME}/memories"*) ;;
  *) fail "mini's error does not name ${MINI_HOME}/memories: ${out}" ;;
esac
if [ -s "${MINI_HOME}/memories" ]; then
  fail "the writer wrote into the regular file at ${MINI_HOME}/memories"
fi
pass "a write failure exits non-zero, names the path and prints no success line"

# The file is replaced atomically, so a write that fails leaves the previous
# host memory exactly as it was.
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP: running as root — permissions do not stop the write, the truncation case was not run\n' >&2
else
  rm -rf "${MINI_HOME}/memories"
  mkdir -p "${MINI_HOME}/memories"
  printf 'OLD HOST MEMORY\n' > "${MINI_HOME}/memories/00-host.md"
  chmod 0500 "${MINI_HOME}/memories"

  rc=0
  out=$( write_host_memory 2>&1 ) || rc=$?
  chmod 0700 "${MINI_HOME}/memories"

  if [ "$rc" -eq 0 ]; then
    fail "the writer exited 0 although ${MINI_HOME}/memories is not writable"
  fi
  case "$out" in
    *"wrote host memory"*) fail "the writer printed a success line although the write failed: ${out}" ;;
  esac
  err_line=$(mini_error_line "$out")
  case "$err_line" in
    *"${MINI_HOME}/memories"*) ;;
    *) fail "mini's error does not name ${MINI_HOME}/memories: ${out}" ;;
  esac
  if ! grep -q 'OLD HOST MEMORY' "${MINI_HOME}/memories/00-host.md"; then
    fail "a failed write truncated the previous 00-host.md"
  fi
  leftovers=$(find "${MINI_HOME}/memories" -name '*.tmp.*' | wc -l)
  if [ "$leftovers" -ne 0 ]; then
    fail "a failed write left ${leftovers} temp file(s) behind"
  fi
  pass "a failed write leaves the previous 00-host.md intact"

  # D1) the write path, with a cleanup that fails as well: the temp file
  # cannot be opened for writing, and it cannot be unlinked from a directory
  # that is not writable either. The report still has to come through mini's
  # error channel — a failing cleanup must not swallow it.
  #
  # The writer is called the way `mini sudo` calls it: at statement level,
  # with errexit live. A command substitution inside an `||' list suspends
  # errexit inside it, and then a failing cleanup looks harmless — the very
  # thing this case is about. The parent's errexit is off for the call, so
  # that the failure does not take the test down with it.
  printf 'OLD HOST MEMORY\n' > "${MINI_HOME}/memories/00-host.md"
  : > "${MINI_HOME}/memories/00-host.md.tmp.$$"
  chmod 0400 "${MINI_HOME}/memories/00-host.md.tmp.$$"
  chmod 0500 "${MINI_HOME}/memories"

  rc=0
  set +e
  ( set -e; write_host_memory ) > "${TMP}/d1.out" 2>&1
  rc=$?
  set -e
  out=$(cat "${TMP}/d1.out" 2>/dev/null || true)
  chmod 0700 "${MINI_HOME}/memories"

  if [ "$rc" -eq 0 ]; then
    fail "the writer exited 0 although ${MINI_HOME}/memories is not writable"
  fi
  case "$out" in
    *"wrote host memory"*) fail "the writer printed a success line although the write failed: ${out}" ;;
  esac
  # The temp file cannot be unlinked from a directory that is not writable,
  # so it is still there: the cleanup really did fail.
  if [ ! -e "${MINI_HOME}/memories/00-host.md.tmp.$$" ]; then
    fail "the stale temp file is gone — the case did not exercise a failed cleanup"
  fi
  err_line=$(mini_error_line "$out")
  case "$err_line" in
    *"${MINI_HOME}/memories"*) ;;
    *) fail "mini's error does not name ${MINI_HOME}/memories: ${out}" ;;
  esac
  if ! grep -q 'OLD HOST MEMORY' "${MINI_HOME}/memories/00-host.md"; then
    fail "a failed write truncated the previous 00-host.md"
  fi
  rm -f "${MINI_HOME}/memories/00-host.md.tmp.$$"
  pass "a failed write that cannot clean up still reports through mini's error channel"

  # D2) the same failure, but the directory also holds a stale temp file from
  # an interrupted run and is not writable, so neither the replace nor the
  # cleanup can succeed. Cleaning up must not swallow the report: mini still
  # has to name the path and fail through its own error channel.
  printf 'OLD HOST MEMORY\n' > "${MINI_HOME}/memories/00-host.md"
  # The writer's temp name carries its PID, and $$ is the same PID inside a
  # subshell — so this is the very file the writer will try to replace and
  # then to clean up.
  : > "${MINI_HOME}/memories/00-host.md.tmp.$$"
  chmod 0500 "${MINI_HOME}/memories"

  rc=0
  set +e
  ( set -e; write_host_memory ) > "${TMP}/d2.out" 2>&1
  rc=$?
  set -e
  out=$(cat "${TMP}/d2.out" 2>/dev/null || true)
  chmod 0700 "${MINI_HOME}/memories"

  if [ "$rc" -eq 0 ]; then
    fail "the writer exited 0 although ${MINI_HOME}/memories is not writable"
  fi
  # The stale temp file cannot be unlinked from a directory that is not
  # writable, so it is still there: the cleanup really did fail, which is what
  # makes this case harsher than D.
  if [ ! -e "${MINI_HOME}/memories/00-host.md.tmp.$$" ]; then
    fail "the stale temp file is gone — the case did not exercise a failed cleanup"
  fi
  err_line=$(mini_error_line "$out")
  case "$err_line" in
    *"${MINI_HOME}/memories"*) ;;
    *) fail "mini's error does not name ${MINI_HOME}/memories: ${out}" ;;
  esac
  if ! grep -q 'OLD HOST MEMORY' "${MINI_HOME}/memories/00-host.md"; then
    fail "a failed replace overwrote the previous 00-host.md"
  fi
  pass "a failed replace that cannot clean up still reports through mini's error channel"
fi

# ------------------------------------------------------------- mini sudo ----
# `mini sudo` asks a question, so it needs a tty: util-linux script provides
# one. sudo and visudo are stubbed, so nothing is written to /etc/sudoers.d.
STUB_BIN="${TMP}/stub-bin"
STUB_STATE="${TMP}/stub-state"
mkdir -p "$STUB_BIN" "$STUB_STATE"

stub() {
  local name="$1" body="$2" dir="${3:-$STUB_BIN}"
  printf '%s\n' '#!/usr/bin/env bash' "$body" > "${dir}/${name}"
  chmod 0755 "${dir}/${name}"
}

# A sudo that needs a password until the sudoers file is "installed", and is
# passwordless afterwards. Every call is logged; nothing outside MINI_STUB_STATE
# is written.
stub sudo '
state="${MINI_STUB_STATE:?}"
printf "%s\n" "$*" >> "${state}/calls"
case "${1:-}" in
  -n)
    shift
    [ "${1:-}" = "true" ] || exit 1
    [ -f "${state}/installed" ] || exit 1
    exit 0
    ;;
  install)
    mkdir -p "$state"
    : > "${state}/installed"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'
stub visudo 'exit 0'

# mini probes the host for GPUs before it does anything else (lib/detect.sh).
# Those probes depend on the machine's PCI bus, so stub them: this test is
# about the host memory, not about the hardware it happens to run on.
stub nvidia-smi "printf '%s\\n' 'Stub GPU, 0'"
stub rocm-smi   "printf '%s\\n' ''"
stub lspci      "printf '%s\\n' '00:02.0 VGA compatible controller: Stub'"

# A second stub set whose sudo is passwordless from the start: `sudo -n true`
# succeeds, so mini takes cmd_sudo's nopasswd early return and never installs
# a sudoers file. Its own state dir, so the calls of the two cases stay apart.
NOPASSWD_BIN="${TMP}/stub-bin-nopasswd"
NOPASSWD_STATE="${TMP}/stub-state-nopasswd"
mkdir -p "$NOPASSWD_BIN" "$NOPASSWD_STATE"

stub sudo '
state="${MINI_STUB_STATE:?}"
printf "%s\n" "$*" >> "${state}/calls"
case "${1:-}" in
  -n)
    shift
    [ "${1:-}" = "true" ] || exit 1
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
' "$NOPASSWD_BIN"
stub nvidia-smi "printf '%s\\n' 'Stub GPU, 0'" "$NOPASSWD_BIN"
stub rocm-smi   "printf '%s\\n' ''"           "$NOPASSWD_BIN"
stub lspci      "printf '%s\\n' '00:02.0 VGA compatible controller: Stub'" "$NOPASSWD_BIN"

if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP: running as root — the sudo mode is "root", the stubbed sudo is never called; the `mini sudo` case was not run\n' >&2
elif ! command -v script >/dev/null 2>&1 || ! script --version 2>/dev/null | grep -q 'util-linux'; then
  printf 'SKIP: util-linux script is not available — the `mini sudo` case was not run\n' >&2
else
  sudo_home="${TMP}/mini-sudo"
  mkdir -p "$sudo_home" "${TMP}/home" "${TMP}/tmpdir"
  if [ -e "${sudo_home}/memories" ]; then
    fail "${sudo_home}/memories exists before the run — the case proves nothing"
  fi

  rc=0
  out=$( printf 'y\n' | env -u MINI_YES \
          HOME="${TMP}/home" \
          MINI_HOME="$sudo_home" \
          MINI_STUB_STATE="$STUB_STATE" \
          TMPDIR="${TMP}/tmpdir" \
          PATH="${STUB_BIN}:${PATH}" \
          script -qec "bash '${MINI_BIN}' sudo" /dev/null 2>&1 ) || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "mini sudo exited ${rc}: ${out}"
  fi
  if ! grep -q '^install ' "${STUB_STATE}/calls" 2>/dev/null; then
    fail "the stubbed sudo was never asked to install the sudoers file: ${out}"
  fi
  if [ ! -f "${sudo_home}/memories/00-host.md" ]; then
    fail "mini sudo did not write ${sudo_home}/memories/00-host.md: ${out}"
  fi
  if ! grep -q 'passwordless sudo' "${sudo_home}/memories/00-host.md"; then
    fail "mini sudo did not refresh the host memory with the new sudo state"
  fi
  pass "mini sudo exits 0 and writes 00-host.md without setup having run"
fi

# F) the nopasswd early return refreshes the host memory too: mini sudo
# changes nothing on a box where sudo already works, but the agent still has
# to learn that it can act.
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP: running as root — the sudo mode is "root", not "nopasswd"; the early-return case was not run\n' >&2
else
  nopasswd_home="${TMP}/mini-sudo-nopasswd"
  mkdir -p "$nopasswd_home" "${TMP}/home-nopasswd" "${TMP}/tmpdir-nopasswd"
  if [ -e "${nopasswd_home}/memories" ]; then
    fail "${nopasswd_home}/memories exists before the run — the case proves nothing"
  fi

  rc=0
  out=$( env -u MINI_YES \
          HOME="${TMP}/home-nopasswd" \
          MINI_HOME="$nopasswd_home" \
          MINI_STUB_STATE="$NOPASSWD_STATE" \
          TMPDIR="${TMP}/tmpdir-nopasswd" \
          PATH="${NOPASSWD_BIN}:${PATH}" \
          bash "${MINI_BIN}" sudo 2>&1 ) || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "mini sudo exited ${rc} where sudo was already passwordless: ${out}"
  fi
  if [ ! -f "${nopasswd_home}/memories/00-host.md" ]; then
    fail "mini sudo did not write ${nopasswd_home}/memories/00-host.md: ${out}"
  fi
  if ! grep -q 'passwordless sudo' "${nopasswd_home}/memories/00-host.md"; then
    fail "mini sudo did not refresh the host memory with the sudo state: ${out}"
  fi
  if grep -q '^install ' "${NOPASSWD_STATE}/calls" 2>/dev/null; then
    fail "mini sudo installed a sudoers file although sudo was already passwordless"
  fi
  pass "mini sudo exits 0 and refreshes 00-host.md when sudo is already passwordless"
fi

printf 'PASS: mini host memory writer\n'
