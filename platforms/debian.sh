#!/usr/bin/env bash
# platforms/debian.sh — Debian, Ubuntu, Zorin, Mint, Pop!_OS, Raspberry Pi OS.
#
# A platform module implements five functions. To support another distro, copy
# this file and reimplement them — see platforms/README.md.
#
#   platform_name             human label
#   platform_supported        0 if mini can run here
#   platform_install_pkgs     install packages by name
#   platform_install_cmd_for  print the install command for a command's package
#   platform_bootstrap        everything mini needs before setup can run

platform_name() { printf 'debian-family (%s)\n' "${OS_NAME:-unknown}"; }

platform_supported() { [ "${OS_PLATFORM:-}" = 'debian' ]; }

# sudo only when we are not already root, and only when we actually need it.
_sudo() {
  if [ "$(id -u)" -eq 0 ]; then "$@"
  elif has sudo; then sudo "$@"
  else die "need root for: $* — install sudo or run mini as root"
  fi
}

platform_install_pkgs() {
  [ "$#" -gt 0 ] || return 0
  local missing=()
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0

  info "installing: ${missing[*]}"
  _sudo apt-get update -qq || warn "apt update failed — continuing with the cache"
  DEBIAN_FRONTEND=noninteractive _sudo apt-get install -y -qq "${missing[@]}" \
    || die "apt could not install: ${missing[*]}"
}

# Print — never run — the exact command that installs the package providing
# <cmd> on this distro. doctor prints the result as the fix line for a missing
# tool; it is the reason lib/ can stay free of package-manager names.
platform_install_cmd_for() {
  local pkg
  case "$1" in
    ss)        pkg=iproute2 ;;
    systemctl) pkg=systemd ;;
    ufw)       pkg=ufw ;;
    docker)    pkg=docker.io ;;
    *)         pkg="$1" ;;
  esac
  printf 'sudo apt install -y %s' "$pkg"
}

platform_bootstrap() {
  platform_install_pkgs curl ca-certificates procps
  # Optional, but they make the agent noticeably better at its job.
  platform_install_pkgs python3 || true
}
