#!/usr/bin/env bash
# doctor.sh — tell the user exactly what is broken and the command that fixes it.

DOCTOR_FAILS=0
DOCTOR_WARNS=0

d_ok()   { printf '  %s %s\n' "${C_GREEN}✓${C_RESET}" "$1"; }
d_warn() { printf '  %s %s\n' "${C_YELLOW}!${C_RESET}" "$1"; DOCTOR_WARNS=$(( DOCTOR_WARNS + 1 )); }
d_fail() { printf '  %s %s\n' "${C_RED}✗${C_RESET}" "$1"; DOCTOR_FAILS=$(( DOCTOR_FAILS + 1 )); }
d_fix()  { printf '      %s\n' "${C_DIM}fix: $1${C_RESET}"; }

# opencode install + generated config. Shared by the local and remote paths.
doctor_opencode_section() {
  step "opencode"
  if opencode_bin >/dev/null 2>&1; then
    d_ok "opencode installed ${C_DIM}($("$(opencode_bin)" --version 2>/dev/null))${C_RESET}"
  else
    d_fail "opencode not installed"; d_fix "mini setup"
  fi
  if [ -f "${MINI_HOME}/opencode.json" ]; then
    d_ok "config ${MINI_HOME}/opencode.json"
  else
    d_fail "mini's opencode config missing"; d_fix "mini setup"
  fi
  if [ -f "${MINI_HOME}/AGENTS.md" ]; then
    d_ok "brain ${MINI_HOME}/AGENTS.md"
  else
    d_fail "AGENTS.md missing"; d_fix "mini setup"
  fi
  local mem_count
  mem_count=$(find "${MINI_HOME}/memories" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
  d_ok "memories: ${mem_count} file(s) in ${MINI_HOME}/memories"

}

# The three tools, in both their shell and opencode forms.
doctor_tools_section() {
  step "Tools"
  for t in websearch webfetch sysreport; do
    if [ -x "${MINI_HOME}/tools/${t}" ]; then d_ok "$t ${C_DIM}(shell)${C_RESET}"; else d_warn "$t not installed"; d_fix "mini setup"; fi
  done
  local tools_dir="${HOME}/.config/opencode/tools" oc_missing=0
  for t in mini_search mini_fetch mini_sysreport; do
    [ -f "${tools_dir}/${t}.ts" ] || oc_missing=1
  done
  if [ "$oc_missing" -eq 0 ]; then
    d_ok "mini_search mini_fetch mini_sysreport ${C_DIM}(opencode tools)${C_RESET}"
  else
    d_warn "opencode tools not installed in ${tools_dir}"; d_fix "mini setup"
  fi
  if curl -sf --max-time 8 -o /dev/null 'https://lite.duckduckgo.com/lite/'; then
    d_ok "outbound https works ${C_DIM}(websearch will function)${C_RESET}"
  else
    d_warn "no outbound https — websearch/webfetch will fail"
  fi

}

doctor_run() {
  detect_all

  # bin/mini dispatches doctor without load_platform, so the platform module is
  # sourced here: the Host tools step needs platform_install_cmd_for to print
  # fix lines. Same fallback as load_platform, but with no die — the Platform
  # step below already reports unsupported distros, and doctor must still run
  # far enough to say so.
  local platform_mod="${MINI_PLATFORMS}/${OS_PLATFORM}.sh"
  if [ -f "$platform_mod" ]; then
    # shellcheck source=platforms/debian.sh
    . "$platform_mod"
  else
    # shellcheck source=platforms/debian.sh
    . "${MINI_PLATFORMS}/debian.sh"
  fi

  step "Host"
  detect_summary

  step "Platform"
  if [ "$OS_PLATFORM" = 'debian' ]; then
    d_ok "${OS_NAME} — supported (debian family)"
  else
    d_fail "${OS_NAME} — mini only supports the debian family today"
    d_fix "see platforms/README.md to add ${OS_ID}"
  fi

  step "Privileges"
  case "$SUDO_MODE" in
    root)     d_ok "running as root" ;;
    nopasswd) d_ok "passwordless sudo — the agent can install and configure" ;;
    password)
      d_fail "sudo requires a password"
      printf '      %s\n' "${C_DIM}opencode runs commands with no tty, so sudo cannot prompt.${C_RESET}"
      printf '      %s\n' "${C_DIM}The agent can read this machine but not change it.${C_RESET}"
      d_fix "mini sudo" ;;
    none)
      d_fail "no sudo on this box — the agent cannot change anything system-wide"
      d_fix "as root: apt-get install -y sudo && usermod -aG sudo $(id -un)" ;;
  esac

  step "Dependencies"
  for cmd in curl awk sed grep; do
    if has "$cmd"; then d_ok "$cmd"; else d_fail "$cmd missing"; d_fix "sudo apt install -y $cmd"; fi
  done
  if has python3; then d_ok "python3 ${C_DIM}(better html→text for webfetch)${C_RESET}"
  else d_warn "python3 missing — webfetch falls back to crude tag stripping"; d_fix "sudo apt install -y python3"; fi

  # Provider-independent checks: the same in local and remote mode, so they sit
  # above the remote early-return below.
  step "Secrets"
  local secret="${MINI_HOME}/secret" quoted_secret quoted_home
  printf -v quoted_secret '%q' "$secret"
  printf -v quoted_home '%q' "$HOME"
  if [ -f "$secret" ]; then
    local mode; mode=$(stat -c '%a' "$secret" 2>/dev/null)
    if [ "$mode" = '600' ]; then
      d_ok "server password stored 0600 ${C_DIM}(mini password)${C_RESET}"
    else
      d_fail "${secret} is mode ${mode} — other users on this box can read it"
      d_fix "chmod 600 -- ${quoted_secret}"
    fi
  else
    d_ok "no server password yet ${C_DIM}(generated on first: mini web)${C_RESET}"
  fi

  step "Capacity"
  if [ "${DISK_FREE_GB:-0}" -lt 10 ]; then
    d_warn "${DISK_FREE_GB}GB free in ${HOME} — host storage is low"
    d_fix "df -h -- ${quoted_home}; du -h --max-depth=1 -- ${quoted_home}"
  else
    d_ok "${DISK_FREE_GB}GB free in ${HOME}"
  fi
  if [ "${BUDGET_MB:-0}" -lt 2000 ]; then
    d_fail "only ${BUDGET_MB}MB hardware memory budget — below the 2000MB host threshold"
    d_fix "free -h; if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi; fi"
  fi

  step "Host tools"
  # Presence only: four independent lines, and none of them claims a service is
  # running or that anything was installed. A missing tool gets a fix line
  # printed by the platform module — doctor never executes an install.
  local cmd
  for cmd in ss systemctl ufw docker; do
    if has "$cmd"; then
      d_ok "$cmd"
    else
      case "$cmd" in
        ss)        d_warn "ss missing — the agent cannot inspect listening ports or connections" ;;
        systemctl) d_warn "systemctl missing — the agent cannot inspect or control services" ;;
        ufw)       d_warn "ufw missing — the agent cannot check or change the firewall" ;;
        docker)    d_warn "docker missing — the agent cannot inspect or manage containers" ;;
      esac
      d_fix "$(platform_install_cmd_for "$cmd")"
    fi
  done

  # Remote inference skips the whole local-server section.
  if [ "$(cfg_get MINI_PROVIDER)" = 'remote' ]; then
    step "Inference"
    local r_url r_model
    r_url=$(cfg_get MINI_REMOTE_URL); r_model=$(cfg_get MINI_REMOTE_MODEL)
    # A remote provider with no endpoint or no model is not a warning: every
    # launch path dies on it. Say so, and say the command that fixes it.
    local r_missing=0
    if [ -z "$r_url" ]; then
      d_fail "no remote URL configured"; r_missing=1
    fi
    if [ -z "$r_model" ]; then
      d_fail "no remote model configured"; r_missing=1
    fi
    if [ "$r_missing" -eq 0 ]; then
      d_ok "remote: ${r_model} via ${r_url}"
    else
      d_fix "mini remote <url> <model> [key]"
    fi
    if [ -n "$r_url" ]; then
      if curl -sf --max-time 10 -o /dev/null "$r_url" 2>/dev/null; then
        d_ok "endpoint reachable"
      else
        d_warn "could not reach ${r_url} (it may still work — some endpoints reject bare GETs)"
      fi
    fi
    if [ -f "${MINI_HOME}/api-key" ]; then
      local km; km=$(stat -c '%a' "${MINI_HOME}/api-key" 2>/dev/null)
      [ "$km" = '600' ] && d_ok "api key stored 0600" \
        || { d_fail "api key is mode ${km}"; d_fix "chmod 600 ${MINI_HOME}/api-key"; }
    fi
    doctor_opencode_section
    doctor_tools_section
    say ''
    [ "$DOCTOR_FAILS" -gt 0 ] && { err "${DOCTOR_FAILS} problem(s), ${DOCTOR_WARNS} warning(s)"; return 1; }
    if [ "$DOCTOR_WARNS" -gt 0 ]; then
      warn "healthy (remote inference), with ${DOCTOR_WARNS} warning(s)"
    else
      ok "healthy (remote inference)"
    fi
    return 0
  fi

  step "Ollama"
  if has ollama; then
    d_ok "ollama installed ${C_DIM}($(ollama --version 2>/dev/null | head -n1))${C_RESET}"
  else
    d_fail "ollama not installed"; d_fix "mini setup"
  fi
  if ollama_up; then
    d_ok "server up at ${OLLAMA_URL} ${C_DIM}(v$(ollama_version))${C_RESET}"
  else
    d_fail "server not responding at ${OLLAMA_URL}"; d_fix "mini serve"
  fi

  # An ollama on a public interface has no authentication of any kind. Anyone
  # who can reach it can load models and run inference on your hardware.
  local public_bind
  public_bind=$(ollama_public_bind)
  if [ -n "$public_bind" ]; then
    d_fail "ollama is listening on ${public_bind} — reachable from the network, with no auth"
    d_fix "mini serve --local   (or set OLLAMA_HOST=127.0.0.1:11434 in the unit and restart)"
  elif ollama_up && ollama_is_loopback; then
    d_ok "bound to loopback only ${C_DIM}(not reachable from the network)${C_RESET}"
  fi

  step "Model"
  local base model ctx
  base=$(cfg_get MINI_BASE_MODEL); model=$(cfg_get MINI_MODEL); ctx=$(cfg_get MINI_CTX)
  if [ -z "$model" ]; then
    d_fail "no model configured"; d_fix "mini setup"
  else
    d_ok "configured: ${model} ${C_DIM}(base ${base})${C_RESET}"
    if ollama_up && ! ollama_has_model "$model"; then
      d_fail "${model} not present in ollama"; d_fix "mini setup"
    elif ollama_up; then
      d_ok "present in ollama"
    fi
    if [ -n "$ctx" ] && [ "$ctx" -lt 65536 ] 2>/dev/null; then
      # Three very different causes, three very different fixes.
      local native; native=$(models_field "$base" 3)
      if [ -n "$native" ] && [ "$ctx" -ge "$native" ] 2>/dev/null; then
        d_warn "context ${ctx} — that is ${base}'s native maximum, and below the 64k opencode prefers"
        d_fix "for more, a long-context model: mini model devstral:24b (128k)"
      elif [ -n "$native" ]; then
        d_warn "context ${ctx}; ${base} supports ${native} but memory here does not allow it"
        d_fix "free memory, add a GPU, or drop a size: mini models"
      else
        d_warn "context ${ctx}; ${base} is not in the registry, so its native context is unknown — the context is chosen from the budget, capped at mini's 32768 fallback"
        d_fix "ollama show ${base} | grep 'context length'"
      fi
    elif [ -n "$ctx" ]; then
      d_ok "context ${ctx}"
    fi
    # A model that fits the budget on paper but was picked before a hardware
    # change is the classic silent-slowness bug.
    local want; want=$(models_recommend)
    if [ -n "$base" ] && [ "$base" != "$want" ]; then
      d_warn "hardware now suggests ${want} (you run ${base})"
      d_fix "mini model auto"
    fi
  fi

  doctor_opencode_section
  doctor_tools_section

  step "Local inference capacity"
  # No GPU is not a failure, but it is the single biggest thing shaping what
  # this feels like to use — so say it plainly instead of letting the user
  # discover it by waiting.
  if [ "${ACCEL:-cpu}" = 'cpu' ]; then
    d_warn "no usable GPU — inference runs on CPU"
    printf '      %s\n' "${C_DIM}Expect a few tokens/sec, and minutes for the first turn of a session${C_RESET}"
    printf '      %s\n' "${C_DIM}while the prompt is processed. Later turns in the same session are faster.${C_RESET}"
    d_fix "for real speed, point mini at an external endpoint: mini remote"
  else
    d_ok "GPU inference ${C_DIM}(${GPU_NAME})${C_RESET}"
  fi

  say ''
  if [ "$DOCTOR_FAILS" -gt 0 ]; then
    err "${DOCTOR_FAILS} problem(s), ${DOCTOR_WARNS} warning(s)"
    return 1
  elif [ "$DOCTOR_WARNS" -gt 0 ]; then
    warn "healthy, with ${DOCTOR_WARNS} warning(s)"
  else
    ok "everything checks out — run ${C_BOLD}mini${C_RESET} to start"
  fi
  return 0
}
