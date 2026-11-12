# Reviewer instructions — developerz-ai/mini

> Read by the developerz.ai reviewer at EVERY review of this repository, at the reviewed
> commit, as this repo's own layer of the reviewer's prompt — established by dz-runner setup mode.
> It refines the platform rules (a finding is cited or withheld; the bot always discloses)
> and never overrides them. Edit freely; keep it under 12,000 characters — past that it is cut.

## Stack

Bash + ShellCheck. The gate is `bin/check` (`for f in bin/mini bin/setup bin/dev bin/check bin/stop .githooks/pre-commit lib/*.sh platforms/*.sh install.sh; do bash -n "$f" || exit 1; done && bash .github/run-tests.sh && the failing-member probe (an exit-3 stub must make run-tests.sh exit nonzero) && bash .github/run-tests_test.sh && shellcheck -x --source-path=lib --source-path=platforms -e SC2015 -e SC2016 over the same list`): a change that does not pass it is not proven, whatever its description says.

## Review conventions

- TODO(setup): the conventions a reviewer must hold this repo to (from CLAUDE.md / CONTRIBUTING), each as a rule.

## Gates that matter

- TODO(setup): which checks decide a change here, and what "proven" means for a pull request.

## Never flag

- TODO(setup): what never to flag — generated or vendored files, style a formatter owns, conventions this repo chose on purpose.
