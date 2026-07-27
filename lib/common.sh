#!/usr/bin/env bash
# common.sh — logging, prompts, tiny helpers. Sourced by every other lib.

# Colors, but only when attached to a terminal.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${C_BLUE}::${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET}  $*"; }
warn() { printf '%s\n' "${C_YELLOW}!${C_RESET}  $*" >&2; }
err()  { printf '%s\n' "${C_RED}✗${C_RESET}  $*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }
dim()  { printf '%s\n' "${C_DIM}$*${C_RESET}"; }

has() { command -v "$1" >/dev/null 2>&1; }

# ask "Question?" "default"  -> echoes the answer.
# Non-interactive (piped stdin, or MINI_YES=1) returns the default.
ask() {
  local prompt="$1" default="${2:-}" reply
  if [ "${MINI_YES:-0}" = "1" ] || [ ! -t 0 ]; then
    printf '%s\n' "$default"
    return 0
  fi
  printf '%s' "${C_CYAN}?${C_RESET} $prompt ${C_DIM}[$default]${C_RESET} " >&2
  read -r reply || reply=''
  printf '%s\n' "${reply:-$default}"
}

# confirm "Do the thing?" -> exit 0 on yes.
confirm() {
  local answer
  answer=$(ask "$1 (y/n)" "${2:-y}")
  case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# Ensure a directory exists, quietly.
ensure_dir() { [ -d "$1" ] || mkdir -p "$1"; }

# Escape a string for safe embedding in a JSON string literal.
json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Read KEY=value from the mini config file. Missing key -> empty.
cfg_get() {
  local key="$1" file="${MINI_HOME}/config"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n1
}

# Write/replace KEY=value in the mini config file.
cfg_set() {
  local key="$1" value="$2" file="${MINI_HOME}/config"
  ensure_dir "$MINI_HOME"
  touch "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# A random password, kept in a 0600 file of its own rather than in `config`,
# which mini prints. Generated once and reused so a bookmarked web session
# keeps working across restarts.
#
# Needed because `opencode serve` and `opencode web` expose an HTTP API that
# can run commands on this machine. Unauthenticated, that is a remote shell for
# anyone who can reach the port.
mini_secret() {
  local f="${MINI_HOME}/secret"
  if [ -s "$f" ]; then
    cat "$f"
    return 0
  fi
  ensure_dir "$MINI_HOME"
  local pw
  if [ -r /dev/urandom ]; then
    pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  else
    pw=$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 32)
  fi
  [ -n "$pw" ] || die "could not generate a password"
  # Create it empty and locked down before anything is written into it.
  ( umask 077; : > "$f" )
  printf '%s\n' "$pw" > "$f"
  chmod 600 "$f"
  printf '%s\n' "$pw"
}

# Turn "qwen2.5-coder:7b" into "qwen2.5-coder-7b" for use in derived names.
slugify_model() { printf '%s' "$1" | tr ':/' '--'; }
