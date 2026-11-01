# Platforms

mini ships with one platform module: `debian.sh`, covering Debian, Ubuntu,
Zorin, Mint, Pop!_OS and Raspberry Pi OS. Everything distro-specific lives
behind this interface so adding a distro never means touching the wrapper.

## What a platform is

Two files:

| File | What it holds |
|---|---|
| `platforms/<id>.sh` | How to install packages on this distro |
| `share/prompts/<id>.md` | What the agent needs to know about this distro |

`<id>` comes from `detect_os()` in `lib/detect.sh`, which maps `/etc/os-release`
onto a platform id. Both files are picked up by name — no registry to update.

## The interface

A module implements five functions:

```bash
platform_name()          # human label, e.g. "debian-family (Ubuntu 24.04)"
platform_supported()     # exit 0 if mini can run here
platform_install_pkgs()  # install packages by name, idempotently
platform_install_cmd_for()  # exact install command for the package that provides a command
platform_bootstrap()     # everything mini needs before setup can run
```

Rules that keep the modules interchangeable:

- `platform_install_pkgs` must be idempotent — skip what is already installed.
- Never prompt. Package managers hang forever on an unanswered question.
- Use `die` from `lib/common.sh` on unrecoverable failure; `warn` otherwise.
- Escalate with the module's own `_sudo` helper, not a bare `sudo`.

## Adding one

1. Add the distro to the `case` in `detect_os()` (`lib/detect.sh`) so it maps to
   your platform id.
2. Copy `platforms/debian.sh` to `platforms/<id>.sh` and reimplement the five
   functions.
3. Copy `share/prompts/debian.md` to `share/prompts/<id>.md` and rewrite it for
   the distro — package manager, init system, firewall, log locations, and the
   failure modes that are specific to it. This file matters as much as the
   shell module: it is what stops a small model from reaching for `apt` on a
   box that has never had it.
4. Run `mini doctor` on that distro, then `mini "what is wrong with this
   machine"` and watch which commands it reaches for.

Fedora/RHEL (`dnf`), Arch (`pacman`) and Alpine (`apk`) are the obvious next
three. The prompt file is the real work; the shell module is about forty lines.
