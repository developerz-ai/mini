# The prompt

`~/.cache/mini/AGENTS.md` is where a 7B model gets its judgment. It is the
highest-leverage file in the project — more than the model choice, more than the
tools.

## How it is built

```
share/prompts/base.md          role, operating rules, hard rules, tools, style
        +
share/prompts/<platform>.md    apt, systemd, diagnosis order, firewall, logs
        ↓
~/.cache/mini/AGENTS.md        loaded into every session
```

Composed rather than shipped whole, so adding a distro means writing one prompt
file instead of forking a monolith. opencode loads it via the `instructions`
array in `~/.cache/mini/opencode.json`, together with `memories/*.md`.

## What goes where

**`base.md`** — anything true on every Linux box:

- The role: an operator with a shell, not a chatbot that suggests commands.
- Operating rules: look before you touch, one command at a time, smallest fix
  that works, verify after changing, say what you did.
- Hard rules: never lock the user out, never `rm -rf` an unlisted path, never
  pipe an unknown URL into a shell, never invent output, back up before editing,
  stop and ask before destroying data.
- The tool table, with *when to reach for each*.
- How to use memory.
- Output style.

**`<platform>.md`** — anything distro-specific:

- Package manager idioms, including the flags that avoid interactive hangs.
- Service management and where unit overrides belong.
- **The diagnosis order** — the checklist that finds a cause fastest.
- Firewall, with the rule that prevents lockout.
- Logs, disk pressure, users and permissions.
- The idioms that keep you out of trouble: validate before reload, back up
  before edit, how to check whether sudo will prompt.

If a rule mentions `apt`, it belongs in the platform file. If it would be true
on Alpine, it belongs in base.

## Writing for a small model

This is not the same as writing for a frontier model. What works:

**Imperative, not explanatory.** "Run `systemctl --failed` first" beats "it can
be helpful to check which services have failed." Every clause the model has to
interpret is a clause it can misinterpret.

**Exact commands, verbatim.** Give the whole invocation with its flags. A model
that has `journalctl -u <unit> -n 200 --no-pager` in front of it will not invent
`journalctl --last 200`. The `--no-pager` matters: without it the model hangs
waiting for a pager that will never be interactive.

**Tables over paragraphs.** They survive compression, scan cleanly, and make
each row an independent fact that cannot be blurred into its neighbour.

**Order things by what to do first.** The diagnosis list in the platform file is
sequenced deliberately: disk full → inodes → OOM → config typo → permissions →
DNS → firewall, roughly by how often each is the actual cause. A small model
follows a list far better than it prioritizes on its own.

**Say what not to do, explicitly.** "Never `apt upgrade` mid-debug" prevents a
whole class of confused sessions. Negative rules are cheap and they hold.

**Keep it short.** Every token here is spent on every request, and it competes
with the tool output the model actually needs to reason about. Roughly 150 lines
per file is the working budget. When you add something, look for something to
delete.

## Editing yours

`~/.cache/mini/AGENTS.md` is yours. Add your conventions, your paths, the way
this particular box differs.

mini keeps a copy of what it generated as `.agents-md-generated` and compares
against it on update:

- **Unchanged** → refreshed silently with the new default.
- **Edited** → yours is kept, the new default lands as `AGENTS.md.new`.

Back to stock: delete `AGENTS.md` and run `mini setup`.

Project-specific rules go in an `AGENTS.md` in that directory instead — opencode
picks up the local one on top of mini's. That is the right place for "this repo
deploys with `bin/deploy`", which has nothing to do with the machine.

## Memory vs prompt

Both end up in context; they answer different questions.

| | Prompt (`AGENTS.md`) | Memory (`memories/*.md`) |
|---|---|---|
| Answers | How should I work? | What is true about this box? |
| Example | "Validate with `nginx -t` before reloading" | "nginx serves api.example.com from /srv/api" |
| Changes | When you change your mind | When the machine changes |
| Written by | You, and mini's defaults | `mini remember` → `10-learned.md`; `mini setup` / `mini sudo` → `00-host.md` |

The memory writer creates `$MINI_HOME/memories` (`~/.cache/mini/memories` by
default) itself, so `00-host.md` is there even on a box where `mini setup`
never ran — `mini sudo` alone is enough.

Keep behaviour in the prompt and facts in memory. Facts in the prompt go stale
without anyone noticing; behaviour in memory gets buried under trivia.

## Testing a prompt change

There is no unit test for a system prompt. Run the same task before and after and
watch which commands it reaches for:

```bash
mini "what is wrong with this machine"
mini "install docker"
mini "why is <some service> failing"
```

Watch for: does it check before it claims, does it verify after it changes, does
it reach for `sysreport` first, does it search the web instead of guessing at a
version. Those four behaviours are what the prompt is buying, and they are what
degrades first when a prompt gets too long.
