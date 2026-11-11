---
description: Prove a change in developerz-ai/mini before committing or opening a pull request — the repo's own install, run and check commands. Use before every commit.
---

# Verify a change in developerz-ai/mini

> House skill — established by dz-runner setup mode from this repo’s own
> detected commands. Correct it in place; setup never overwrites a skill that exists.

## The one gate

`bin/check` is the gate. CI runs the same commands, and the pre-commit hook runs it
once activated (`git config core.hooksPath .githooks`), so a change that passes it
locally passes everywhere.

| Step | Command | What it is |
|------|---------|------------|
| install | `bin/setup` | (dpkg -s shellcheck curl ca-certificates procps python3 iproute2 >/dev/null 2>&1 \|\| (sudo -n apt-get update && sudo -n apt-get install -y --no-install-recommends shellcheck curl ca-certificates procps python3 iproute2)) |
| run | `bin/dev` | bin/mini models — on developerz.ai runs, start it with code_bash_background when you need a running stack |
| prove | `bin/check` | guards shellcheck first (exit 75 when missing), then for f in bin/mini bin/setup bin/dev bin/check bin/stop .githooks/pre-commit lib/*.sh platforms/*.sh install.sh; do bash -n "$f" \|\| exit 1; done && bash .github/run-tests.sh && bash .github/run-tests_test.sh && shellcheck -x --source-path=lib --source-path=platforms -e SC2015 -e SC2016 over the same list — `bin/check <files…>` scopes to the named files and exits 79 |
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
