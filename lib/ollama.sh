#!/usr/bin/env bash
# ollama.sh — lifecycle of the local model server.
#
# Three ways ollama ends up running on a box: the systemd unit its installer
# drops in, a user-launched `ollama serve`, or nothing at all. mini handles all
# three and only ever manages the process it started itself.

OLLAMA_HOST_ADDR="${OLLAMA_HOST:-127.0.0.1:11434}"
OLLAMA_URL="http://${OLLAMA_HOST_ADDR}"
OLLAMA_PIDFILE="${MINI_HOME}/ollama.pid"
OLLAMA_LOG="${MINI_HOME}/logs/ollama.log"

ollama_up() {
  curl -sf --max-time 2 "${OLLAMA_URL}/api/version" >/dev/null 2>&1
}

ollama_version() {
  curl -sf --max-time 2 "${OLLAMA_URL}/api/version" 2>/dev/null |
    sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
}

# Is mini talking to a server on this machine?
ollama_is_loopback() {
  case "${OLLAMA_HOST_ADDR%%:*}" in
    127.0.0.1|localhost|::1|'') return 0 ;;
    *) return 1 ;;
  esac
}

# Is anything answering on the ollama port from outside this machine?
# Returns the offending bind address, or nothing.
ollama_public_bind() {
  local port="${OLLAMA_HOST_ADDR##*:}"
  [ -n "$port" ] || port=11434
  has ss || return 0
  ss -tlnH 2>/dev/null \
    | awk -v p=":${port}" '$4 ~ p"$" {print $4}' \
    | grep -E '^(0\.0\.0\.0|\*|\[::\])' || true
}

# Is the server the one systemd owns?
ollama_systemd_managed() {
  has systemctl && systemctl list-unit-files ollama.service >/dev/null 2>&1
}

# Apply the agent-friendly tuning wherever the server happens to live.
# Called from setup, so an ollama that was already running when mini arrived
# still gets fixed — the common case, since ollama's installer starts it.
ollama_tune() {
  if ollama_systemd_managed; then
    ollama_write_systemd_dropin || true
  elif [ -f "$OLLAMA_PIDFILE" ]; then
    dim "ollama runs as a mini-managed process — tuning applies on next start"
  else
    warn "ollama is running but mini does not manage it; for best results set"
    dim "  OLLAMA_NUM_PARALLEL=1  OLLAMA_MAX_LOADED_MODELS=1  OLLAMA_KEEP_ALIVE=30m"
  fi
}

# Force the server back onto loopback. For when doctor found it public.
ollama_bind_local() {
  if ! ollama_is_loopback; then
    die "OLLAMA_HOST is set to ${OLLAMA_HOST_ADDR} — unset it first, or this would break your remote setup"
  fi

  if ollama_systemd_managed; then
    # Gate first: a missing passwordless sudo dies with its fix command here,
    # not as a generic write failure inside the writer below.
    _mini_sudo mkdir -p /etc/systemd/system/ollama.service.d 2>/dev/null \
      || die "need sudo to rebind the systemd service — run: mini sudo"
    ollama_write_systemd_dropin \
      || die "could not apply tuning while rebinding"
    # A matching drop-in early-returns from the writer without a restart;
    # a stopped unit would stay stopped and the wait below would time out.
    ollama_up || _mini_sudo systemctl restart ollama \
      || die "could not restart ollama while rebinding"
    ollama_wait 30 || die "ollama did not come back up"
    ok "ollama rebound to ${OLLAMA_HOST_ADDR}"
  else
    ollama_stop
    ollama_start
    ok "ollama restarted on ${OLLAMA_HOST_ADDR}"
  fi

  local still
  still=$(ollama_public_bind)
  [ -n "$still" ] && warn "still listening on ${still} — something else may own this port"
  return 0
}

ollama_start() {
  ollama_up && return 0
  has ollama || die "ollama is not installed — run: mini setup"

  if ollama_systemd_managed; then
    info "starting ollama (systemd)"
    ollama_write_systemd_dropin || true
    sudo systemctl start ollama >/dev/null 2>&1 || true
    ollama_wait 30 && return 0
    warn "systemd unit did not come up — falling back to a user process"
  fi

  info "starting ollama"
  ensure_dir "$(dirname "$OLLAMA_LOG")"
  # NUM_PARALLEL=1: opencode fires a second request to title the session while
  # the main one is still running. Two parallel slots double the KV cache and,
  # on a CPU box, make both requests crawl. Serialise them instead.
  # KEEP_ALIVE=30m: the default 5m unloads the model between turns, and
  # reloading several GB from disk on every tool call is the whole session.
  # FLASH_ATTENTION + q8_0 KV halves the memory a context window costs, which
  # is what makes 64k-128k affordable on an ordinary box instead of 32k.
  OLLAMA_HOST="$OLLAMA_HOST_ADDR" \
  OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}" \
  OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}" \
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}" \
  OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}" \
  OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}" \
    nohup ollama serve >>"$OLLAMA_LOG" 2>&1 &
  printf '%s\n' "$!" > "$OLLAMA_PIDFILE"
  ollama_wait 30 || die "ollama did not start — check ${OLLAMA_LOG}"
}

# The same tuning as the user-process path, for the systemd-managed server.
# Written as a drop-in so ollama's own packaging can still update the unit.
# Returns non-zero when writing or applying fails: best-effort callers `|| true` it,
# ollama_bind_local dies on it.
ollama_write_systemd_dropin() {
  local dir='/etc/systemd/system/ollama.service.d'
  local file="${dir}/10-mini.conf"
  local want='[Service]
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"'

  # Bind to loopback unless the user deliberately pointed mini elsewhere.
  # An ollama listening on 0.0.0.0 is an unauthenticated endpoint that will run
  # arbitrary models and burn your CPU for anyone who finds it.
  if ollama_is_loopback; then
    want="${want}
Environment=\"OLLAMA_HOST=${OLLAMA_HOST_ADDR}\""
  fi

  [ "${SUDO_MODE:-}" = 'password' ] && return 0
  [ "${SUDO_MODE:-}" = 'none' ] && return 0

  # A matching file is not proof it was applied: a previous reload/restart
  # may have failed while the old (possibly public) listener stayed healthy.
  if [ ! -e "${file}.pending" ] && [ -f "$file" ] && [ "$(cat "$file" 2>/dev/null)" = "$want" ]; then
    return 0
  fi

  # The drop-in directory does not exist until something creates it.
  _mini_sudo mkdir -p "$dir" 2>/dev/null || {
    warn "could not create ${dir} — ollama keeps its defaults"
    return 1
  }
  # Persist before writing, so failures (or interruption) cannot enable the
  # content-match shortcut on the next invocation. Keep the drop-in for retry.
  _mini_sudo touch "${file}.pending" 2>/dev/null || {
    warn "could not mark ${file} pending — check sudo access with: mini sudo"
    return 1
  }
  printf '%s\n' "$want" | _mini_sudo tee "$file" >/dev/null 2>&1 || {
    warn "could not write ${file} — ollama keeps its defaults"
    return 1
  }
  _mini_sudo systemctl daemon-reload >/dev/null 2>&1 || {
    warn "could not reload systemd — run: sudo -n systemctl daemon-reload"
    return 1
  }
  _mini_sudo systemctl restart ollama >/dev/null 2>&1 || {
    warn "could not restart ollama — run: sudo -n systemctl restart ollama"
    return 1
  }
  _mini_sudo rm -f "${file}.pending" 2>/dev/null || {
    warn "could not clear pending state — run: sudo -n rm -f ${file}.pending"
    return 1
  }
  ok "tuned ollama for agent use (serialised requests, 30m keep-alive)"
}

# sudo that never blocks on a password prompt.
_mini_sudo() {
  if [ "$(id -u)" -eq 0 ]; then "$@"
  else sudo -n "$@"
  fi
}

ollama_wait() {
  local tries="${1:-30}" i=0
  while [ "$i" -lt "$tries" ]; do
    ollama_up && return 0
    sleep 1
    i=$(( i + 1 ))
  done
  return 1
}

# Only stops what mini started; a systemd-managed server is left alone unless
# explicitly asked, because something else on the box may be using it.
ollama_stop() {
  if [ -f "$OLLAMA_PIDFILE" ]; then
    local pid
    pid=$(cat "$OLLAMA_PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null && ok "stopped ollama (pid ${pid})"
    fi
    rm -f "$OLLAMA_PIDFILE"
    return 0
  fi
  if ollama_systemd_managed && systemctl is-active --quiet ollama; then
    warn "ollama runs under systemd — stop it with: sudo systemctl stop ollama"
    return 0
  fi
  dim "nothing to stop"
}

# Exact match on the NAME column of `ollama list`.
ollama_has_model() {
  local want="$1"
  ollama list 2>/dev/null | awk -v w="$want" 'NR>1 && $1==w{found=1} END{exit !found}'
}

ollama_status() {
  if ollama_up; then
    ok "ollama up at ${OLLAMA_URL} ${C_DIM}(v$(ollama_version))${C_RESET}"
  else
    warn "ollama down at ${OLLAMA_URL}"
    return 1
  fi
}
