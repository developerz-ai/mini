---
description: Adding a distro module and its prompt. Use for platforms, share/prompts, detect_os, platform_install_pkgs.
---

> House skill — established by dz-runner setup mode from this repo's own evidence, then owned by its maintainers. Correct it in place; setup never overwrites a skill that exists.

1. Map the distro in the `case` in `detect_os()` (`lib/detect.sh`) so it resolves to a platform id.
2. Copy `platforms/debian.sh` to `platforms/<id>.sh` and reimplement the five functions: `platform_name`, `platform_supported`, `platform_install_pkgs`, `platform_install_cmd_for`, `platform_bootstrap`.
3. Copy `share/prompts/debian.md` to `share/prompts/<id>.md` and rewrite it for the distro: package manager, init system, firewall, log locations, and its own failure modes. This file is what stops a small model reaching for `apt` on a box that never had it.
4. Keep `platform_install_pkgs` idempotent — skip what is already installed — and never prompt; a package manager hangs forever on an unanswered question.
5. Escalate with the module's own `_sudo` helper, never a bare `sudo`.
6. Use `die` from `lib/common.sh` for an unrecoverable failure, `warn` otherwise.
7. No registry to update: the module and the prompt are picked up by name from `detect_os()`.
8. Run `bash .github/run-tests.sh` → must exit 0. fail -> fix the module before continuing.
9. Run `bin/mini doctor` on that distro and read every line: a check with no fix line is a bug, and the platform step must say the distro is supported.
