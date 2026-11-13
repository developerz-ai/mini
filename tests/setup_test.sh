#!/usr/bin/env bash
# setup_test.sh — pins the contract of bin/setup.
#
# Offline by construction: every run gets a PATH holding ONLY a stub dir, so the
# real host's package state (apt-get, sudo, shellcheck, mise…) is never seen or
# touched. The verdict is on exit codes and on the call log the stubs write.
#
# What it pins:
#   A) every tool present        -> exit 0, apt-get and sudo never called
#   B) tool missing, root        -> apt-get called directly (no sudo) with the
#                                   missing package, exit 0
#   C) tool missing, non-root    -> `sudo -n apt-get`, exit 0
#   D) tool missing, no installer (no apt-get / no sudo / sudo -n refused)
#                                -> non-zero, message names the missing tool
#   E) mise absent does not abort; mise present runs `mise install`
#   F) installer "succeeds" but the tool stays missing -> non-zero
#   G) `mise install` fails        -> warning naming mise, the five tools are
#                                    still probed and installed, exit 0
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="${REPO_ROOT}/bin/setup"
BASH_BIN=$(command -v bash)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok   %s\n' "$*"; }

[ -f "$SETUP" ] || fail "no ${SETUP}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ALL_TOOLS=(shellcheck curl python3 ss ps)

# mkbox <name> <tool…> — sandbox $TMP/<name>/bin holding stubs for the tools
# named, plus dirname (bin/setup needs it) and `id`. $TMP/<name>/calls.log
# collects every apt-get/sudo/mise call.
mkbox() {
  local name="$1"; shift
  local dir="${TMP}/${name}/bin" t
  mkdir -p "$dir"
  : > "${TMP}/${name}/calls.log"
  ln -s "$(PATH=/usr/bin:/bin command -v dirname)" "${dir}/dirname"
  printf '#!/bin/sh\nexit 0\n' > "${dir}/.ok"
  chmod +x "${dir}/.ok"
  for t in "$@"; do cp "${dir}/.ok" "${dir}/${t}"; done
  # id -u answers $STUB_UID (default 1000).
  printf '#!/bin/sh\necho "${STUB_UID:-1000}"\n' > "${dir}/id"
  chmod +x "${dir}/id"
}

# stub_apt <name> [noop] — apt-get stub. Logs its args; on `install` it makes
# the commands the packages provide appear (copy of .ok), unless `noop`.
stub_apt() {
  local name="$1" mode="${2:-}" dir="${TMP}/${1}/bin"
  cat > "${dir}/apt-get" <<EOF
#!/bin/sh
PATH=/usr/bin:/bin
d="\${0%/*}"
echo "apt-get \$*" >> "\${d}/../calls.log"
[ "$mode" = noop ] && exit 0
if [ "\$1" = install ]; then
  for a in "\$@"; do
    case "\$a" in
      shellcheck|curl|python3) cp "\${d}/.ok" "\${d}/\$a" ;;
      iproute2) cp "\${d}/.ok" "\${d}/ss" ;;
      procps)   cp "\${d}/.ok" "\${d}/ps" ;;
    esac
  done
fi
exit 0
EOF
  chmod +x "${dir}/apt-get"
}

# stub_sudo <name> — logs, answers the `sudo -n true` probe unless
# STUB_SUDO_FAIL=1, otherwise runs the rest of the command from PATH.
stub_sudo() {
  local name="$1" dir="${TMP}/${1}/bin"
  cat > "${dir}/sudo" <<'EOF'
#!/bin/sh
d="${0%/*}"
echo "sudo $*" >> "${d}/../calls.log"
[ "$1" = -n ] && shift
if [ "$1" = true ]; then
  [ "${STUB_SUDO_FAIL:-0}" = 1 ] && exit 1
  exit 0
fi
exec "$@"
EOF
  chmod +x "${dir}/sudo"
}

# run_setup <name> [VAR=value…] — run bin/setup with PATH = the sandbox only.
# rc, out and err land in $rc, $TMP/<name>/out, $TMP/<name>/err.
run_setup() {
  local name="$1"; shift
  rc=0
  env -i HOME="${TMP}/${name}" PATH="${TMP}/${name}/bin" "$@" \
    "$BASH_BIN" "$SETUP" > "${TMP}/${name}/out" 2> "${TMP}/${name}/err" || rc=$?
}

calls() { cat "${TMP}/${1}/calls.log"; }
errs()  { cat "${TMP}/${1}/err"; }

# A) everything present -> nothing installed, no apt-get / sudo call.
mkbox all "${ALL_TOOLS[@]}"; stub_apt all; stub_sudo all
run_setup all
[ "$rc" -eq 0 ] || fail "all present: exit $rc — stderr: '$(errs all)'"
[ -z "$(calls all)" ] || fail "all present: apt-get/sudo was called: '$(calls all)'"
ok 'all tools present: exit 0, apt-get and sudo never called'

# A2) same as non-root with sudo refusing: still green, still no calls.
run_setup all STUB_SUDO_FAIL=1
[ "$rc" -eq 0 ] || fail "all present, no sudo: exit $rc — stderr: '$(errs all)'"
[ -z "$(calls all)" ] || fail "all present, no sudo: something was called: '$(calls all)'"
ok 'all tools present without sudo: still exit 0, nothing called'

# B) root, one tool missing -> apt-get direct, only the missing package.
mkbox root shellcheck curl python3 ps; stub_apt root; stub_sudo root
run_setup root STUB_UID=0
[ "$rc" -eq 0 ] || fail "root: exit $rc — stderr: '$(errs root)'"
calls root | grep -Fq 'apt-get install -y --no-install-recommends iproute2' \
  || fail "root: no install of iproute2: '$(calls root)'"
calls root | grep -Eq '^apt-get install .*(shellcheck|curl|python3|procps)' \
  && fail "root: installed a package that was already present: '$(calls root)'"
calls root | grep -q '^sudo' && fail "root: used sudo: '$(calls root)'"
ok 'root: apt-get called directly with just the missing package, no sudo'

# C) non-root with passwordless sudo -> sudo -n apt-get.
mkbox sudo shellcheck curl ss ps; stub_apt sudo; stub_sudo sudo
run_setup sudo STUB_UID=1000
[ "$rc" -eq 0 ] || fail "sudo: exit $rc — stderr: '$(errs sudo)'"
calls sudo | grep -Fq 'sudo -n apt-get install -y --no-install-recommends python3' \
  || fail "sudo: no 'sudo -n apt-get install … python3': '$(calls sudo)'"
calls sudo | grep -Ev '^(sudo -n (true|apt-get)|apt-get)' | grep -q . \
  && fail "sudo: a bare/unexpected call was made: '$(calls sudo)'"
ok 'non-root: installs through sudo -n apt-get'

# D1) tool missing, no apt-get at all.
mkbox noapt shellcheck curl python3 ps
run_setup noapt STUB_UID=0
[ "$rc" -ne 0 ] || fail 'no apt-get: expected non-zero'
errs noapt | grep -Eq 'missing: ss([^[:alnum:]_]|$)' || fail "no apt-get: message does not name ss: '$(errs noapt)'"
ok 'no installer: non-zero, names the missing tool'

# D2) non-root, apt-get present, no sudo binary.
mkbox nosudo curl python3 ss ps; stub_apt nosudo
run_setup nosudo STUB_UID=1000
[ "$rc" -ne 0 ] || fail 'no sudo: expected non-zero'
errs nosudo | grep -Fq shellcheck || fail "no sudo: message does not name shellcheck: '$(errs nosudo)'"
[ -z "$(calls nosudo)" ] || fail "no sudo: apt-get ran without privileges: '$(calls nosudo)'"
ok 'non-root without sudo: non-zero, names the missing tool, apt-get not run'

# D3) non-root, sudo present but `sudo -n` refuses (would need a password).
mkbox nopw curl python3 ss ps; stub_apt nopw; stub_sudo nopw
run_setup nopw STUB_UID=1000 STUB_SUDO_FAIL=1
[ "$rc" -ne 0 ] || fail 'sudo -n refused: expected non-zero'
errs nopw | grep -Fq shellcheck || fail "sudo -n refused: message does not name shellcheck: '$(errs nopw)'"
calls nopw | grep -q '^apt-get' && fail "sudo -n refused: apt-get ran anyway: '$(calls nopw)'"
ok 'sudo -n refused: non-zero, names the missing tool, apt-get not run'

# E) mise absent never aborted (every case above ran without it); present -> runs.
mkbox mise "${ALL_TOOLS[@]}"
cat > "${TMP}/mise/bin/mise" <<'EOF'
#!/bin/sh
echo "mise $*" >> "${0%/*}/../calls.log"
EOF
chmod +x "${TMP}/mise/bin/mise"
run_setup mise
[ "$rc" -eq 0 ] || fail "mise: exit $rc — stderr: '$(errs mise)'"
calls mise | grep -Fxq 'mise install' || fail "mise: not run: '$(calls mise)'"
ok 'mise absent is fine; mise present runs mise install'

# F) installer reports success but the tool never appears -> not green.
mkbox noop shellcheck curl python3 ps; stub_apt noop noop
run_setup noop STUB_UID=0
[ "$rc" -ne 0 ] || fail 'noop installer: expected non-zero'
errs noop | grep -Eq 'still missing after install: ss([^[:alnum:]_]|$)' || fail "noop installer: message does not name ss: '$(errs noop)'"
ok 'installer that installs nothing: non-zero, names what is still missing'

# G) `mise install` fails -> warn, and the five tools this script owns are
# still probed and installed. mise is not one of them, so its failure must not
# decide the exit code.
mkbox misefail shellcheck curl python3 ps
stub_apt misefail; stub_sudo misefail
cat > "${TMP}/misefail/bin/mise" <<'EOF'
#!/bin/sh
echo "mise $*" >> "${0%/*}/../calls.log"
echo "mise: install failed" >&2
exit 1
EOF
chmod +x "${TMP}/misefail/bin/mise"
run_setup misefail STUB_UID=0
[ "$rc" -eq 0 ] || fail "mise failure: exit $rc — stderr: '$(errs misefail)'"
calls misefail | grep -Fxq 'mise install' \
  || fail "mise failure: mise was not run: '$(calls misefail)'"
calls misefail | grep -Fq 'apt-get install -y --no-install-recommends iproute2' \
  || fail "mise failure: the missing tool was not installed: '$(calls misefail)'"
errs misefail | grep -Fq 'mise install' \
  || fail "mise failure: no warning naming mise: '$(errs misefail)'"
ok 'mise failure: warns, still installs the five tools, exit 0'

printf 'PASS: bin/setup idempotence, installer selection, failure messages, best-effort mise\n'
