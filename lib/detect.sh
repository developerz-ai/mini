#!/usr/bin/env bash
# detect.sh — figure out what machine we are on.
#
# Exports (after detect_all):
#   OS_ID OS_LIKE OS_NAME OS_VERSION OS_PLATFORM
#   CPU_CORES RAM_MB DISK_FREE_GB
#   GPU_VENDOR GPU_NAME VRAM_MB
#   BUDGET_MB   -- memory we can realistically give a model
#   ACCEL       -- "gpu" or "cpu"
#   INIT_SYSTEM -- "systemd" or "not systemd"
#   INIT_PID1   -- PID 1's comm, "unknown" if it cannot be read
#
# The two probes detect_init reads are overridable, so a test can drive them:
#   MINI_SYSTEMD_RUNTIME_DIR -- default /run/systemd/system
#   MINI_PID1_COMM           -- default /proc/1/comm

detect_os() {
  OS_ID='unknown'; OS_LIKE=''; OS_NAME='unknown'; OS_VERSION=''
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
    OS_VERSION="${VERSION_ID:-}"
  fi

  # Which platform module handles this distro.
  case " $OS_ID $OS_LIKE " in
    *" debian "*|*" ubuntu "*) OS_PLATFORM='debian' ;;
    *) OS_PLATFORM='unsupported' ;;
  esac
  export OS_ID OS_LIKE OS_NAME OS_VERSION OS_PLATFORM
}

# Is systemd the init system?
#
# PID 1 is the ground truth: systemd is the init system only when
# /proc/1/comm reads "systemd" — that is the process that actually is PID 1.
# Only when that file cannot be read at all does the runtime marker
# /run/systemd/system decide, and then only as a fallback.
#
# The marker alone proves nothing: systemd's tmpfiles.d creates that directory
# at package-install time, so a stock Debian container image ships it while
# PID 1 is still the container's own init. Never key this off
# `command -v systemctl` either — the same image ships that binary, and it
# answers every query with "System has not been booted with systemd as init
# system". Neither the OS family nor the distro is evidence.
#
# The composed prompt (base + platform module) is written for a systemd box,
# so on a host without one the diagnosis playbook does not apply.
detect_init() {
  # The probes are absolute paths, so a test could not reach them. Both are
  # overridable; the defaults are the real locations on a Linux host.
  local runtime_dir="${MINI_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}"
  local pid1_file="${MINI_PID1_COMM:-/proc/1/comm}"

  INIT_PID1='unknown'
  local comm=''
  if [ -r "$pid1_file" ]; then
    # `|| true`: under `set -e` a probe that fails would abort the caller
    # (mini doctor) before it ever reaches the Init step.
    comm=$(head -n1 "$pid1_file" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$comm" ]; then INIT_PID1="$comm"; fi
  fi

  if [ "$INIT_PID1" = 'unknown' ]; then
    # PID 1 could not be read at all — the marker is the only evidence left.
    if [ -d "$runtime_dir" ]; then
      INIT_SYSTEM='systemd'
    else
      INIT_SYSTEM='not systemd'
    fi
  elif [ "$INIT_PID1" = 'systemd' ]; then
    INIT_SYSTEM='systemd'
  else
    # PID 1 is something else. The marker does not get a vote here.
    INIT_SYSTEM='not systemd'
  fi
  export INIT_SYSTEM INIT_PID1
  return 0
}

detect_cpu_ram() {
  CPU_CORES=$(nproc 2>/dev/null || echo 1)
  RAM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  DISK_FREE_GB=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -n1 | tr -dc '0-9' || true)
  [ -n "$DISK_FREE_GB" ] || DISK_FREE_GB=0
  export CPU_CORES RAM_MB DISK_FREE_GB
}

detect_gpu() {
  GPU_VENDOR='none'; GPU_NAME=''; VRAM_MB=0

  # NVIDIA — the only one with a reliable, scriptable VRAM query.
  if has nvidia-smi; then
    local line
    line=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)
    if [ -n "$line" ]; then
      GPU_VENDOR='nvidia'
      GPU_NAME=$(printf '%s' "$line" | cut -d, -f1 | sed 's/^ *//;s/ *$//')
      VRAM_MB=$(printf '%s' "$line" | cut -d, -f2 | tr -dc '0-9')
      [ -n "$VRAM_MB" ] || VRAM_MB=0
    fi
  fi

  # AMD via ROCm.
  if [ "$GPU_VENDOR" = 'none' ] && has rocm-smi; then
    local vram
    vram=$(rocm-smi --showmeminfo vram --csv 2>/dev/null | awk -F, 'NR==2{print $2}' | tr -dc '0-9' || true)
    if [ -n "$vram" ] && [ "$vram" -gt 0 ] 2>/dev/null; then
      GPU_VENDOR='amd'
      GPU_NAME=$(lspci 2>/dev/null | grep -iE 'vga|display' | grep -i amd | head -n1 | cut -d: -f3- | sed 's/^ *//' || true)
      VRAM_MB=$(( vram / 1024 / 1024 ))
    fi
  fi

  # Last resort: name the card so the user knows we saw it, but claim no VRAM
  # we cannot measure. Unmeasured VRAM must not inflate the model budget.
  if [ "$GPU_VENDOR" = 'none' ] && has lspci; then
    local vga
    # grep finding no card is a normal answer, not a failure: under
      # `set -euo pipefail` a non-zero grep aborts the whole run.
      vga=$(lspci 2>/dev/null | grep -iE 'vga compatible|3d controller' | head -n1 | cut -d: -f3- | sed 's/^ *//' || true)
    if [ -n "$vga" ]; then
      GPU_NAME="$vga"
      case "$vga" in
        *NVIDIA*|*nVidia*) GPU_VENDOR='nvidia-nodriver' ;;
        *AMD*|*ATI*|*Radeon*) GPU_VENDOR='amd-nodriver' ;;
        *Intel*) GPU_VENDOR='intel' ;;
        *) GPU_VENDOR='other' ;;
      esac
    fi
  fi
  export GPU_VENDOR GPU_NAME VRAM_MB
}

# How much memory a model may actually use.
#   GPU path: VRAM minus ~1GB for the desktop/compositor and KV overhead.
#   CPU path: 60% of RAM — the OS, page cache and your actual work need the rest.
detect_budget() {
  if [ "${VRAM_MB:-0}" -ge 4096 ]; then
    ACCEL='gpu'
    BUDGET_MB=$(( VRAM_MB - 1024 ))
  else
    ACCEL='cpu'
    BUDGET_MB=$(( RAM_MB * 60 / 100 ))
  fi
  [ "$BUDGET_MB" -lt 0 ] && BUDGET_MB=0
  export ACCEL BUDGET_MB
}

# How the agent can escalate.
#
# This decides whether mini is useful at all: opencode runs bash commands
# non-interactively, so a `sudo` that wants a password does not prompt — it
# hangs or fails with "no tty present". An agent that cannot install a package
# is a chatbot.
#
#   root      running as uid 0, nothing needed
#   nopasswd  sudo works without a prompt — the mode mini wants
#   password  sudo exists but will prompt, so the agent cannot use it
#   none      no sudo at all
detect_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_MODE='root'
  elif ! has sudo; then
    SUDO_MODE='none'
  elif sudo -n true 2>/dev/null; then
    SUDO_MODE='nopasswd'
  else
    SUDO_MODE='password'
  fi
  export SUDO_MODE
}

detect_all() {
  detect_os
  detect_init
  detect_cpu_ram
  detect_gpu
  detect_budget
  detect_sudo
}

# Human-readable summary of the host.
detect_summary() {
  local gpu_line
  if [ "${VRAM_MB:-0}" -gt 0 ]; then
    gpu_line="${GPU_NAME} (${VRAM_MB} MB VRAM)"
  elif [ -n "${GPU_NAME:-}" ]; then
    gpu_line="${GPU_NAME} — no usable driver, running on CPU"
  else
    gpu_line="none detected"
  fi
  printf '  %-10s %s\n' 'OS'     "$OS_NAME (${OS_ID}, platform: ${OS_PLATFORM})"
  printf '  %-10s %s\n' 'Init'   "${INIT_SYSTEM:-unknown} (PID 1: ${INIT_PID1:-unknown})"
  printf '  %-10s %s cores\n' 'CPU' "$CPU_CORES"
  printf '  %-10s %s MB\n' 'RAM'   "$RAM_MB"
  printf '  %-10s %s\n' 'GPU'     "$gpu_line"
  printf '  %-10s %s GB free in %s\n' 'Disk' "$DISK_FREE_GB" "$HOME"
  printf '  %-10s %s MB (%s)\n' 'Budget' "$BUDGET_MB" "$ACCEL"
  local sudo_desc
  case "${SUDO_MODE:-}" in
    root)     sudo_desc='running as root' ;;
    nopasswd) sudo_desc='passwordless — the agent can install things' ;;
    password) sudo_desc='needs a password — the agent CANNOT use it (see: mini sudo)' ;;
    none)     sudo_desc='not available — the agent cannot install anything' ;;
    *)        sudo_desc='unknown' ;;
  esac
  printf '  %-10s %s\n' 'Sudo' "$sudo_desc"
}
