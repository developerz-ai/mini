# AI-first scorecard

> Written by the developerz.ai maintainer agent — established by dz-runner setup mode. Each onboarding run rewrites this file whole; the latest run wins, and the same card is stored on the platform.

- Run: `run_befc675f8dc8402e8fe98fb109fdffed`
- Computed: 2026-11-11T16:54:15.392Z
- Proof: **proved** — every command ran green at head.
- Score: 13 of 15 items ok

## `policy` — ok

- .dz/maintainer/maintainer.yml already present, left alone
- .dz/maintainer/reviewer.md established

## `brain` — ok

- CLAUDE.md already present, left alone

## `roster` — ok

- .claude/agents/model-selection.md established
- .claude/agents/doctor-checks.md established
- .claude/agents/ollama-server.md established
- .claude/agents/opencode-config.md established

## `skills` — ok

- .claude/skills/verify-change/SKILL.md established
- .claude/skills/model-registry/SKILL.md established
- .claude/skills/platform-module/SKILL.md established
- .claude/skills/new-tool/SKILL.md established

## `scripts` — ok

- bin/setup established
- bin/dev established
- bin/check established
- bin/stop established
- down: ./bin/stop (bin)
- ./bin/setup exited 0 at head (0.4s)

## `wiring` — ok

- .mcp.json established

## `commands` — ok

- .claude/commands already present, left alone

## `access` — gap

- landed 0 of 1 asked
- still missing: MINI_REMOTE_URL

## `layout` — gap

- partial house layout
- no apps/ or packages/ at the repository root

## `smoke_test` — ok

- tests/test_provider.sh in the repository
- run by ./bin/check exited 0 at head (86.3s)

## `env_example` — ok

- .env.example established

## `agents_md` — ok

- AGENTS.md already present, left alone

## `per_workspace_brains` — ok

- single-package repository: 0 workspaces
- CLAUDE.md already present, left alone

## `docs_readme` — ok

- docs/README.md already present, left alone

## `gate_proved` — ok

- ./bin/check exited 0 at head (86.3s)
