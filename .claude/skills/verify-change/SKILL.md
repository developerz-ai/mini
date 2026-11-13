---
description: Prove a change in developerz-ai/mini before committing or opening a pull request — the repo's own install, run and check commands. Use before every commit.
---

# Verify a change in developerz-ai/mini

> House skill — established by dz-runner setup mode from this repo’s own
> detected commands. Correct it in place; setup never overwrites a skill that exists.

## The one gate

`bin/check` is the gate, and the pre-commit hook runs it once activated
(`git config core.hooksPath .githooks`). `bin/check` is a SUPERSET of CI: the same
steps — `bash -n`, the offline suite, the runner-can-fail probe, the runner's
verdict self-test, ShellCheck — over a WIDER file list. CI
(`.github/workflows/shell-checks.yml`) grades the narrower
`bin/mini lib/*.sh platforms/*.sh install.sh`, so the five setup-mode scripts
(`bin/setup`, `bin/dev`, `bin/check`, `bin/stop`, `.githooks/pre-commit`) are
linted ONLY by `bin/check`: a green CI run says nothing about them. A change that
passes `bin/check` locally passes CI too.

| Step | Command | What it is |
|------|---------|------------|
| install | `bin/setup` | idempotent: `mise install` if mise exists (best-effort — a failure only warns, and the exit code is still decided by the five tools below), then installs only what `command -v` shows missing among shellcheck, curl, python3, ss, ps — `apt-get` directly as root, `sudo -n apt-get` otherwise; nothing missing means no apt-get/sudo call, no usable installer means a message naming the missing tools and a non-zero exit |
| run | `bin/dev` | bin/mini models — on developerz.ai runs, start it with code_bash_background when you need a running stack |
| prove | `bin/check` | guards shellcheck first (exit 75 when missing), then for f in bin/mini lib/*.sh platforms/*.sh install.sh; do bash -n "$f" \|\| exit 1; done && bash .github/run-tests.sh && a runner-can-fail probe (drives `.github/run-tests.sh` with a deliberately failing stub member and fails the gate if the runner exits 0) && bash .github/run-tests_test.sh && shellcheck -x --source-path=lib --source-path=platforms -e SC2015 -e SC2016 over the same list — `bin/setup`, `bin/dev`, `bin/check`, `bin/stop` and `.githooks/pre-commit` are not covered (check them by hand with `bash -n`); `bin/check <files…>` scopes to the named files and exits 79 |
| stop | `bin/stop` | bin/mini stop \|\| true — on developerz.ai runs, the platform runs this when your session ends — do not stop the stack yourself |

## Rules

- Run every command from the repo root — the scripts `cd` there themselves.
- `bin/check` red is not a pull request. Fix the cause, never silence the gate.

## Exit codes `bin/check` must use

A coding box runs this gate before it commits, and it has to tell a FAILING change
from a gate it could not run — otherwise correct work is thrown away as if it were
red. Exit 1 cannot carry that difference, so two codes are reserved:

| Exit | Means | What the platform does |
|------|-------|------------------------|
| 0 | the change passes | commit it |
| 75 | a resource the gate NEEDS is unreachable (a database, a service, a credential) — it refused to grade | refuse the commit, and blame the environment, never the change |
| 79 | every check the gate ran PASSED, but it cannot grade the whole change here (a scoped gate meeting a change whose dependents are the whole suite) | commit it and open the pull request; CI grades the rest |
| any other non-zero | the gate ran and the change is red | refuse the commit, and blame the change |

- Guard preconditions FIRST and `exit 75` when one is unmet. `exit 1` there tells the
  platform your change is broken when it is your environment that is.
- `exit 79` only when every check you ran passed. Anything failed is `exit 1`;
  a deferral never hides a red. `bin/check <files…>` is the scoped form: it
  syntax-checks and lints only the named files and exits 79 when they pass.
- Changed a dependency? Re-run `bin/setup` before `bin/check`, or you are proving a stale tree.
- Add the test that fails first, then the fix — a green run that never went red proves nothing.
