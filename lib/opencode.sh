#!/usr/bin/env bash
# opencode.sh — generate mini's own opencode config and launch the agent.
#
# mini never edits ~/.config/opencode/opencode.json. It writes its own config
# and points OPENCODE_CONFIG at it, so your personal opencode setup — including
# any cloud providers you use for other work — stays exactly as it was.

OPENCODE_BIN_DIR="${HOME}/.opencode/bin"

# The one command that configures remote inference. Every "remote is not set
# up" failure names it, so the fix is never a guess.
MINI_REMOTE_FIX='mini remote <url> <model> [key]'

opencode_bin() {
  if has opencode; then command -v opencode
  elif [ -x "${OPENCODE_BIN_DIR}/opencode" ]; then printf '%s\n' "${OPENCODE_BIN_DIR}/opencode"
  else return 1
  fi
}

# The slash commands, shared by the local and remote config writers so the two
# can never drift apart.
opencode_command_block() {
  cat <<'CMDS'
  "command": {
    "diag": {
      "description": "Diagnose what is wrong with this machine right now",
      "template": "Diagnose this host. Start with failed services, then the last hour of errors, then disk and memory pressure. Report findings worst-first with the exact command that produced each one. Fix nothing yet.\n$ARGUMENTS"
    },
    "harden": {
      "description": "Baseline security hardening for a fresh VPS",
      "template": "Harden this box: SSH (no root login, no password auth if a key is present), a firewall that keeps my current SSH session alive, fail2ban, and unattended security upgrades. Show me the plan and the exact commands before touching anything. Never lock me out.\n$ARGUMENTS"
    },
    "devbox": {
      "description": "Set this machine up as a development box",
      "template": "Set this machine up for development: $ARGUMENTS. Use official apt repositories or the vendor's documented installer, never a random curl-to-shell you found. Verify each tool afterwards by running its --version."
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
      "template": "Debug the systemd service '$ARGUMENTS'. Get its status, the last 200 journal lines, its unit file, and its dependencies. Tell me the root cause and the smallest fix."
    },
    "remember": {
      "description": "Save a durable fact about this machine",
      "template": "Append this fact to my machine memory by running: mini remember \"$ARGUMENTS\". Then confirm what was saved."
    }
  }
CMDS
}

# Writes $MINI_HOME/opencode.json.
#   $1 = variant model id (e.g. mini-qwen2.5-coder-7b:32k)
#   $2 = context window
#
# Note the "tools" block — it is a latency setting, not a preference.
#
# Every enabled tool ships its JSON schema in the prompt on EVERY request.
# Measured on a stock setup, opencode's built-ins accounted for roughly 7k of a
# 9.3k-token prompt. On a GPU that is free. On CPU, prefill runs at ~30 tokens
# per second, so those schemas alone cost about four minutes before the model
# emits its first token — and the default HTTP timeout kills the request first.
#
# So mini keeps only what a sysadmin agent actually needs: bash, read, write,
# edit. glob/grep/list are redundant when the model has a shell (find, grep, ls
# are more natural to it anyway), webfetch is replaced by mini_fetch, and
# task/todo* are planning scaffolding a small local model uses badly.
opencode_write_config() {
  local model="$1" ctx="$2" out="${MINI_HOME}/opencode.json"
  local label="mini · ${model}"
  local out_tokens=$(( ctx / 8 ))
  [ "$out_tokens" -gt 16384 ] && out_tokens=16384

  # Request timeouts, in ms. These are not paranoia padding — they are the
  # difference between working and not.
  #
  # A cold turn must process the whole prompt (system + tools + AGENTS.md +
  # memories, several thousand tokens) before it emits a single token. A GPU
  # does that in seconds; a CPU runs prefill at tens of tokens per second, so
  # the same turn takes minutes and the default timeout kills the request
  # mid-prefill. The symptom is an agent that returns nothing, with no error.
  #
  # chunkTimeout is the gap allowed *between* streamed tokens: on CPU,
  # generation at ~2 tok/s must not be mistaken for a stalled stream.
  local req_timeout chunk_timeout
  if [ "${ACCEL:-cpu}" = 'gpu' ]; then
    req_timeout=600000     # 10 min
    chunk_timeout=120000   # 2 min
  else
    req_timeout=2700000    # 45 min — a cold CPU turn on a big prompt is slow
    chunk_timeout=600000   # 10 min
  fi

  ensure_dir "$MINI_HOME"

  # Remote inference takes a different provider block entirely.
  if [ "$(cfg_get MINI_PROVIDER)" = 'remote' ]; then
    opencode_write_remote_config
    return $?
  fi

  cat > "$out" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (mini)",
      "options": {
        "baseURL": "${OLLAMA_URL}/v1",
        "timeout": ${req_timeout},
        "chunkTimeout": ${chunk_timeout}
      },
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
  "tools": {
    "task": false,
    "todowrite": false,
    "todoread": false,
    "glob": false,
    "grep": false,
    "list": false,
    "patch": false,
    "webfetch": false
  },
$(opencode_command_block)
}
JSON
  opencode_validate_config "$out"
  ok "wrote ${out}"
}

# A malformed config makes opencode fail in ways that look like model problems,
# so catch it here where the cause is obvious. python3 is optional everywhere
# else in mini, so this is a check when available rather than a hard dependency.
opencode_validate_config() {
  local file="$1"
  has python3 || return 0
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$file" 2>/dev/null && return 0
  err "generated an invalid ${file}"
  python3 -c "import json,sys
try: json.load(open(sys.argv[1]))
except Exception as e: print('   ', e)" "$file" 2>/dev/null
  die "this is a bug in mini — please report it"
}

# Does the generated config already describe this remote setup?
#
# `mini remote` writes the config keys before it writes opencode.json, so a
# write that dies half way leaves the two out of step: the launch names
# mini-remote/<model> while the config still defines the local ollama
# provider. opencode then answers "model not found" — a broken-model symptom
# for a broken-config cause.
opencode_remote_config_current() {
  local url="$1" model="$2" out="${MINI_HOME}/opencode.json"
  [ -f "$out" ] || return 1
  grep -Fq '"mini-remote": {' "$out" || return 1
  grep -Fq "\"model\": \"mini-remote/$(json_escape "$model")\"" "$out" || return 1
  grep -Fq "\"baseURL\": \"$(json_escape "$url")\"" "$out" || return 1
  return 0
}

# The provider/model opencode is launched with.
#
# The generated config decides which provider is live: `ollama` for local
# inference, `mini-remote` for an external OpenAI-compatible endpoint. The
# launch must name the SAME provider/model the config was written with —
# otherwise opencode looks for a model that does not exist and fails with
# something that reads like a broken model rather than a broken config.
#
# Remote mode needs no local model at all: MINI_MODEL is not consulted.
opencode_model_ref() {
  local url model
  if [ "$(cfg_get MINI_PROVIDER)" = 'remote' ]; then
    url=$(cfg_get MINI_REMOTE_URL)
    model=$(cfg_get MINI_REMOTE_MODEL)
    [ -n "$url" ]   || die "no remote URL configured — run: ${MINI_REMOTE_FIX}"
    [ -n "$model" ] || die "no remote model configured — run: ${MINI_REMOTE_FIX}"
    # The config has to declare the provider/model the launch names. If the
    # two are out of step, rewrite the config instead of letting opencode
    # fail on a model it was never told about.
    #
    # Its output goes to stderr: stdout here is the ref, and the caller
    # captures it.
    if ! opencode_remote_config_current "$url" "$model"; then
      opencode_write_remote_config >&2 \
        || die "could not write ${MINI_HOME}/opencode.json — run: ${MINI_REMOTE_FIX}"
    fi
    printf '%s\n' "mini-remote/${model}"
  else
    model=$(cfg_get MINI_MODEL)
    [ -n "$model" ] || die "no model configured — run: mini setup"
    printf '%s\n' "ollama/${model}"
  fi
}

# Launch opencode against mini's config, in the caller's current directory.
#
# Yolo (--auto) is the default: this is a local model on your own box and
# approving every `ls` kills the point. `mini --safe` restores the prompts.
opencode_launch() {
  local bin ref
  bin=$(opencode_bin) || die "opencode is not installed — run: mini setup"
  # `die` inside the substitution only ends the subshell, so carry the
  # failure out explicitly instead of relying on errexit.
  ref=$(opencode_model_ref) || exit 1

  local -a flags=(-m "$ref")
  [ "${MINI_SAFE:-0}" = '1' ] || flags+=(--auto)

  OPENCODE_CONFIG="${MINI_HOME}/opencode.json" \
  OLLAMA_HOST="$OLLAMA_HOST_ADDR" \
  PATH="${MINI_HOME}/tools:${PATH}" \
    exec "$bin" "${flags[@]}" "$@"
}

# Same agent, someone else's GPU.
#
# Any OpenAI-compatible endpoint works: OpenRouter, Groq, Together, a vLLM box
# on your LAN, or a colleague's ollama. The brain, tools, memory and slash
# commands are identical — only where the tokens come from changes. This is the
# honest answer for a machine too slow to run a model locally.
opencode_write_remote_config() {
  local out="${MINI_HOME}/opencode.json"
  local url model ctx key out_tokens
  url=$(cfg_get MINI_REMOTE_URL)
  model=$(cfg_get MINI_REMOTE_MODEL)
  ctx=$(cfg_get MINI_CTX); [ -n "$ctx" ] || ctx=131072
  key=$(cat "${MINI_HOME}/api-key" 2>/dev/null || printf '')

  [ -n "$url" ] || die "no remote URL configured — run: ${MINI_REMOTE_FIX}"
  [ -n "$model" ] || die "no remote model configured — run: ${MINI_REMOTE_FIX}"

  out_tokens=$(( ctx / 8 ))
  [ "$out_tokens" -gt 16384 ] && out_tokens=16384

  # The file carries an API key, so it is created 0600 before anything lands in
  # it — never world-readable for even an instant.
  ( umask 077; : > "$out" )
  cat > "$out" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "mini-remote": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "mini (remote)",
      "options": {
        "baseURL": "$(json_escape "$url")",
        "apiKey": "$(json_escape "$key")",
        "timeout": 600000,
        "chunkTimeout": 120000
      },
      "models": {
        "$(json_escape "$model")": {
          "name": "$(json_escape "mini · ${model}")",
          "tools": true,
          "limit": { "context": ${ctx}, "output": ${out_tokens} }
        }
      }
    }
  },
  "model": "mini-remote/$(json_escape "$model")",
  "small_model": "mini-remote/$(json_escape "$model")",
  "instructions": [
    "${MINI_HOME}/AGENTS.md",
    "${MINI_HOME}/memories/*.md"
  ],
  "autoupdate": false,
  "share": "disabled",
  "tools": {
    "task": false,
    "todowrite": false,
    "todoread": false,
    "glob": false,
    "grep": false,
    "list": false,
    "patch": false,
    "webfetch": false
  },
$(opencode_command_block)
}
JSON
  chmod 600 "$out"
  opencode_validate_config "$out"
  ok "wrote ${out} ${C_DIM}(remote: ${url})${C_RESET}"
}

# Browser UI, or a headless server to attach to from elsewhere.
#
# Bound to loopback with a generated password by default. `--lan` opens it to
# the network — the password is what makes that survivable, since this endpoint
# can run commands on the box.
opencode_web() {
  local mode="$1"; shift
  local bin ref host='127.0.0.1' pw
  bin=$(opencode_bin) || die "opencode is not installed — run: mini setup"
  ref=$(opencode_model_ref) || exit 1

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
    exec "$bin" "$mode" --hostname "$host" -m "$ref" "$@"
}

# One-shot: `mini "why is nginx down"`.
opencode_run() {
  local bin ref
  bin=$(opencode_bin) || die "opencode is not installed — run: mini setup"
  ref=$(opencode_model_ref) || exit 1

  local -a flags=(run -m "$ref")
  [ "${MINI_SAFE:-0}" = '1' ] || flags+=(--auto)

  OPENCODE_CONFIG="${MINI_HOME}/opencode.json" \
  OLLAMA_HOST="$OLLAMA_HOST_ADDR" \
  PATH="${MINI_HOME}/tools:${PATH}" \
    exec "$bin" "${flags[@]}" "$@"
}
