#!/usr/bin/env bash
# opencode.sh — generate mini's own opencode config and launch the agent.
#
# mini never edits ~/.config/opencode/opencode.json. It writes its own config
# and points OPENCODE_CONFIG at it, so your personal opencode setup — including
# any cloud providers you use for other work — stays exactly as it was.

OPENCODE_BIN_DIR="${HOME}/.opencode/bin"

opencode_bin() {
  if has opencode; then command -v opencode
  elif [ -x "${OPENCODE_BIN_DIR}/opencode" ]; then printf '%s\n' "${OPENCODE_BIN_DIR}/opencode"
  else return 1
  fi
}

# Writes $MINI_HOME/opencode.json.
#   $1 = variant model id (e.g. mini-qwen2.5-coder-7b:64k)
#   $2 = context window
opencode_write_config() {
  local model="$1" ctx="$2" out="${MINI_HOME}/opencode.json"
  local label="mini · ${model}"
  local out_tokens=$(( ctx / 8 ))
  [ "$out_tokens" -gt 16384 ] && out_tokens=16384

  ensure_dir "$MINI_HOME"
  cat > "$out" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (mini)",
      "options": { "baseURL": "${OLLAMA_URL}/v1" },
      "models": {
        "${model}": {
          "name": "$(json_escape "$label")",
          "tools": true,
          "limit": { "context": ${ctx}, "output": ${out_tokens} }
        }
      }
    }
  },
  "model": "ollama/${model}",
  "small_model": "ollama/${model}",
  "instructions": [
    "${MINI_HOME}/AGENTS.md",
    "${MINI_HOME}/memories/*.md"
  ],
  "autoupdate": false,
  "share": "disabled",
  "command": {
    "diag": {
      "description": "Diagnose what is wrong with this machine right now",
      "template": "Diagnose this host. Start with failed services, then the last hour of errors, then disk and memory pressure. Report findings worst-first with the exact command that produced each one. Fix nothing yet.\n\$ARGUMENTS"
    },
    "harden": {
      "description": "Baseline security hardening for a fresh VPS",
      "template": "Harden this box: SSH (no root login, no password auth if a key is present), a firewall that keeps my current SSH session alive, fail2ban, and unattended security upgrades. Show me the plan and the exact commands before touching anything. Never lock me out.\n\$ARGUMENTS"
    },
    "devbox": {
      "description": "Set this machine up as a development box",
      "template": "Set this machine up for development: \$ARGUMENTS. Use official apt repositories or the vendor's documented installer, never a random curl-to-shell you found. Verify each tool afterwards by running its --version."
    },
    "ports": {
      "description": "What is listening, and should it be?",
      "template": "Show every listening socket with the owning process and unit, then flag anything bound to 0.0.0.0 that has no business being public."
    },
    "space": {
      "description": "Find and reclaim disk space",
      "template": "Find what is eating disk on this box — largest directories, journal size, apt cache, docker leftovers, old kernels. Rank by reclaimable bytes. Propose the safe reclaims first and ask before deleting anything."
    },
    "svc": {
      "description": "Debug a systemd service",
      "template": "Debug the systemd service '\$ARGUMENTS'. Get its status, the last 200 journal lines, its unit file, and its dependencies. Tell me the root cause and the smallest fix."
    },
    "remember": {
      "description": "Save a durable fact about this machine",
      "template": "Append this fact to my machine memory by running: mini remember \"\$ARGUMENTS\". Then confirm what was saved."
    }
  }
}
JSON
  ok "wrote ${out}"
}

# Launch opencode against mini's config, in the caller's current directory.
#
# Yolo (--auto) is the default: this is a local model on your own box and
# approving every `ls` kills the point. `mini --safe` restores the prompts.
opencode_launch() {
  local bin model
  bin=$(opencode_bin) || die "opencode is not installed — run: mini setup"
  model=$(cfg_get MINI_MODEL)
  [ -n "$model" ] || die "no model configured — run: mini setup"

  local -a flags=(-m "ollama/${model}")
  [ "${MINI_SAFE:-0}" = '1' ] || flags+=(--auto)

  OPENCODE_CONFIG="${MINI_HOME}/opencode.json" \
  OLLAMA_HOST="$OLLAMA_HOST_ADDR" \
  PATH="${MINI_HOME}/tools:${PATH}" \
    exec "$bin" "${flags[@]}" "$@"
}

# Browser UI, or a headless server to attach to from elsewhere.
#
# Bound to loopback with a generated password by default. `--lan` opens it to
# the network — the password is what makes that survivable, since this endpoint
# can run commands on the box.
opencode_web() {
  local mode="$1"; shift
  local bin model host='127.0.0.1' pw
  bin=$(opencode_bin) || die "opencode is not installed — run: mini setup"
  model=$(cfg_get MINI_MODEL)
  [ -n "$model" ] || die "no model configured — run: mini setup"

  if [ "${1:-}" = '--lan' ]; then
    host='0.0.0.0'
    shift
  fi

  pw=$(mini_secret)

  step "opencode ${mode}"
  printf '  %-10s %s\n' 'bind' "${host}$( [ "$host" = '0.0.0.0' ] && printf ' (reachable from your network)' || printf ' (this machine only)' )"
  printf '  %-10s %s\n' 'user' 'opencode'
  printf '  %-10s %s\n' 'password' "$pw"
  dim "  stored in ${MINI_HOME}/secret"
  [ "$host" = '0.0.0.0' ] && warn "anyone who reaches this port and knows the password gets a shell on this box"
  say ''

  OPENCODE_CONFIG="${MINI_HOME}/opencode.json" \
  OLLAMA_HOST="$OLLAMA_HOST_ADDR" \
  OPENCODE_SERVER_PASSWORD="$pw" \
  PATH="${MINI_HOME}/tools:${PATH}" \
    exec "$bin" "$mode" --hostname "$host" -m "ollama/${model}" "$@"
}

# One-shot: `mini "why is nginx down"`.
opencode_run() {
  local bin model
  bin=$(opencode_bin) || die "opencode is not installed — run: mini setup"
  model=$(cfg_get MINI_MODEL)
  [ -n "$model" ] || die "no model configured — run: mini setup"

  local -a flags=(run -m "ollama/${model}")
  [ "${MINI_SAFE:-0}" = '1' ] || flags+=(--auto)

  OPENCODE_CONFIG="${MINI_HOME}/opencode.json" \
  OLLAMA_HOST="$OLLAMA_HOST_ADDR" \
  PATH="${MINI_HOME}/tools:${PATH}" \
    exec "$bin" "${flags[@]}" "$@"
}
