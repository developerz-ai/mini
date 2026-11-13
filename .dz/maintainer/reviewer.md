# Reviewer instructions — developerz-ai/mini

> Read by the developerz.ai reviewer at EVERY review of this repository, at the reviewed
> commit, as this repo's own layer of the reviewer's prompt — established by dz-runner setup mode.
> It refines the platform rules (a finding is cited or withheld; the bot always discloses)
> and never overrides them. Edit freely; keep it under 12,000 characters — past that it is cut.

## Stack

Bash + ShellCheck. The gate is `bin/check` — it syntax-checks, suites and ShellChecks `bin/mini bin/setup bin/dev bin/check bin/stop .githooks/pre-commit lib/*.sh platforms/*.sh install.sh` (bin/check:14), proves the suite runner can fail (a deliberately failing member must make the runner exit nonzero) and runs `.github/run-tests_test.sh`. A change that does not pass `bin/check` is not proven, whatever its description says. CI (`.github/workflows/shell-checks.yml`) runs the same steps over a NARROWER list — `bin/mini lib/*.sh platforms/*.sh install.sh` — so CI never lints the five setup-mode scripts: `bin/check` is the wider gate, and grading only CI's list misses `bin/setup`, `bin/dev`, `bin/check`, `bin/stop` and `.githooks/pre-commit`.

## Review conventions

- TODO(setup): the conventions a reviewer must hold this repo to (from CLAUDE.md / CONTRIBUTING), each as a rule.

## Gates that matter

- TODO(setup): which checks decide a change here, and what "proven" means for a pull request.

## Never flag

- TODO(setup): what never to flag — generated or vendored files, style a formatter owns, conventions this repo chose on purpose.
