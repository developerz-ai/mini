#!/usr/bin/env bash
# mini installer.
#
#   curl -fsSL https://raw.githubusercontent.com/developerz-ai/mini/main/install.sh | bash
#
# or from a checkout:
#
#   ./install.sh
#
# Installs mini to ~/.local/share/mini, links ~/.local/bin/mini, then runs
# `mini setup` — which installs ollama + opencode, recommends a model for your
# hardware, and builds ~/.cache/mini.
set -euo pipefail

MINI_REPO="${MINI_REPO:-developerz-ai/mini}"
MINI_BRANCH="${MINI_BRANCH:-main}"
MINI_PREFIX="${MINI_PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/mini}"
MINI_BIN_DIR="${MINI_BIN_DIR:-$HOME/.local/bin}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[0m'; B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; RED=$'\033[31m'; D=$'\033[2m'
else
  R=''; B=''; G=''; Y=''; RED=''; D=''
fi
info() { printf '%s\n' ":: $*"; }
ok()   { printf '%s\n' "${G}✓${R}  $*"; }
warn() { printf '%s\n' "${Y}!${R}  $*" >&2; }
die()  { printf '%s\n' "${RED}✗${R}  $*" >&2; exit 1; }

printf '\n%s\n' "${B}mini${R} — a local AI agent for your Linux box"
printf '%s\n\n' "${D}no cloud account, no API key, no subscription${R}"

# ---- sanity ---------------------------------------------------------------

[ "$(uname -s)" = 'Linux' ] || die "mini is Linux-only (this is $(uname -s))"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) ok "${PRETTY_NAME:-Linux} — supported" ;;
    *) die "mini targets the debian family (Debian, Ubuntu, Zorin, Mint, Pop!_OS). Found: ${PRETTY_NAME:-unknown}" ;;
  esac
fi

command -v curl >/dev/null 2>&1 || die "curl is required: sudo apt install -y curl"

# ---- fetch ----------------------------------------------------------------

src_dir=''
self_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)

if [ -n "$self_dir" ] && [ -f "${self_dir}/bin/mini" ]; then
  src_dir="$self_dir"
  info "installing from checkout: ${src_dir}"
else
  info "downloading mini (${MINI_REPO}@${MINI_BRANCH})"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/mini-install.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  url="https://codeload.github.com/${MINI_REPO}/tar.gz/refs/heads/${MINI_BRANCH}"
  if command -v tar >/dev/null 2>&1; then
    curl -fsSL "$url" | tar -xz -C "$tmp" || die "download failed: $url"
  else
    die "tar is required: sudo apt install -y tar"
  fi
  src_dir=$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -n1)
  [ -f "${src_dir}/bin/mini" ] || die "unexpected archive layout"
fi

# ---- install --------------------------------------------------------------

info "installing to ${MINI_PREFIX}"
mkdir -p "$MINI_PREFIX" "$MINI_BIN_DIR"

# Replace the program files; ~/.cache/mini (your state) is never touched.
rm -rf "${MINI_PREFIX}/bin" "${MINI_PREFIX}/lib" "${MINI_PREFIX}/share" "${MINI_PREFIX}/platforms"
cp -R "${src_dir}/bin" "${src_dir}/lib" "${src_dir}/share" "${src_dir}/platforms" "$MINI_PREFIX/"
[ -f "${src_dir}/README.md" ] && cp "${src_dir}/README.md" "$MINI_PREFIX/" || true
chmod +x "${MINI_PREFIX}/bin/mini" "${MINI_PREFIX}/share/tools/"* 2>/dev/null || true

ln -sf "${MINI_PREFIX}/bin/mini" "${MINI_BIN_DIR}/mini"
ok "linked ${MINI_BIN_DIR}/mini"

# ---- PATH -----------------------------------------------------------------

case ":${PATH}:" in
  *":${MINI_BIN_DIR}:"*) ;;
  *)
    warn "${MINI_BIN_DIR} is not on your PATH"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [ -f "$rc" ] || continue
      if ! grep -q "${MINI_BIN_DIR}" "$rc" 2>/dev/null; then
        printf '\n# added by mini\nexport PATH="%s:$PATH"\n' "$MINI_BIN_DIR" >> "$rc"
        ok "added it to $(basename "$rc")"
      fi
    done
    export PATH="${MINI_BIN_DIR}:${PATH}"
    warn "run 'exec \$SHELL' or open a new terminal for this to stick"
    ;;
esac

# ---- setup ----------------------------------------------------------------

printf '\n'
if [ "${MINI_NO_SETUP:-0}" = '1' ]; then
  ok "installed. run: ${B}mini setup${R}"
  exit 0
fi

# Piped installs have no stdin for prompts; reconnect to the terminal so the
# model question is actually answerable.
if [ ! -t 0 ] && [ -r /dev/tty ]; then
  exec < /dev/tty
fi

"${MINI_PREFIX}/bin/mini" setup

printf '\n%s\n' "${B}Try it:${R}"
printf '  %s\n' "${D}mini${R}                          open the agent here"
printf '  %s\n' "${D}mini \"what is wrong with this machine\"${R}"
printf '  %s\n' "${D}mini doctor${R}                   check the install"
