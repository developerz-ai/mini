# mini docs

| Doc | What it covers |
|---|---|
| [usage.md](usage.md) | How to work with it day to day — commands, slash commands, memory, approvals |
| [architecture.md](architecture.md) | How the wrapper is put together and why |
| [models.md](models.md) | Selection, the memory budget, and the context variant that makes it work |
| [tools.md](tools.md) | `sysreport`, `websearch`, `webfetch` — and how to add your own |
| [prompts.md](prompts.md) | The system prompt: what goes in it, how to write for a small model |
| [troubleshooting.md](troubleshooting.md) | When it stops mid-task, runs slow, or breaks something |
| [../platforms/README.md](../platforms/README.md) | Adding a distro |

Working on mini itself? Start with [../CLAUDE.md](../CLAUDE.md).

## The short version

mini is a bash wrapper. opencode is the agent runtime, ollama runs the model.
mini picks a model that fits your hardware, gives it a context window that
actually works, hands it a distilled Linux system prompt and three tools, and
launches opencode in your current directory.

The two things that make the difference between a useful agent and a useless
one:

1. **Context** — ollama defaults to 4k, which silently breaks tool calling. See
   [models.md](models.md#the-context-variant).
2. **The prompt** — where a 7B model gets its judgment. See
   [prompts.md](prompts.md).
