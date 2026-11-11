---
description: Shipping a new agent tool end to end. Use for share/tools, share/opencode-tools, mini_ prefix, doctor check.
---

> House skill — established by dz-runner setup mode from this repo's own evidence, then owned by its maintainers. Correct it in place; setup never overwrites a skill that exists.

1. Write the bash script in `share/tools/<name>` with `set -euo pipefail`: curl, coreutils, awk, sed only — no `jq`, and `python3` only opportunistically with a fallback.
2. Write the TS wrapper in `share/opencode-tools/<name>.ts` that exposes the script to opencode.
3. Add the row to the tool table in `share/prompts/base.md` — every enabled tool ships its schema on every request, so keep the description terse.
4. Add the check to `lib/doctor.sh` with the exact command that fixes it; a check with no fix line is not a check.
5. Name the globally installed tool `mini_<name>` so it cannot shadow an opencode built-in.
6. Install it by copying the shipped script into `$MINI_HOME/tools` — that directory is the only program file mini writes under `$MINI_HOME`.
7. Add a test under `tests/` that stubs curl/w3m with a PATH stub and never fetches a literal URL; the suite decides by exit code alone, never by grepping output.
8. Run `bash .github/run-tests.sh` → must exit 0. fail -> fix the tool before continuing.
9. Update `docs/tools.md` in the same change.
