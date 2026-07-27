# Models

## How mini chooses

`mini models` prints the registry against your hardware. Selection is one rule:
**walk the registry best → smallest, take the first row that fits the memory
budget.**

The budget comes from `lib/detect.sh`:

| Situation | Budget | Mode |
|---|---|---|
| GPU with ≥4GB VRAM (nvidia-smi or rocm-smi) | `VRAM − 1GB` | `gpu` |
| Anything else | `60% of RAM` | `cpu` |

A GPU that `lspci` can see but no driver can query counts as **zero**. It gets
named in the report so you know mini saw it, but unmeasurable VRAM never
inflates the budget — a driver-less card cannot run anything.

The 60% on CPU leaves room for the OS, page cache, and the work you are actually
doing. An agent that OOM-kills your database while diagnosing your database is
not helpful.

## The CPU cap

On CPU, mini will not auto-select anything above `qwen3:4b-instruct`, however
much RAM you have. Measured on an ordinary CPU box: `qwen2.5-coder:7b` generates
about 2.5 tokens per second. It runs; it is not an interactive agent.

What actually decides whether a local agent feels usable on CPU is
time-to-first-token, and that is dominated by **prompt size, not parameter
count** — see the context section below. A 4B model that answers beats a 14B one
you gave up waiting for.

`qwen3:4b-instruct` is the default because it wins on every axis that matters
here: 2.5GB, 256k native context, tool calling trained in, and — being the
`-instruct` variant — no thinking tokens. Plain `qwen3:4b` emits a reasoning
block before every answer, which on CPU is latency you pay on every turn.

Override it if you disagree:

```bash
mini model devstral:24b       # your box, your call
```

## The registry

`share/models.tsv`, curated 2026-07:

| Model | Download | Needs | Native context | Why |
|---|---|---|---|---|
| `qwen3-coder:30b` | 19GB | 21GB | 256k | MoE, ~3B active. Strongest local agentic coder. 24GB GPU. |
| `devstral:24b` | 14GB | 16GB | 128k | Mistral's SWE-agent model. Excellent multi-step tool use. |
| `gpt-oss:20b` | 13GB | 14GB | 128k | OpenAI open-weights. Strong tool calling. |
| `qwen2.5-coder:14b` | 9GB | 11GB | 32k | Code-specialised mid-tier. 12GB-GPU sweet spot. |
| `qwen2.5-coder:7b` | 4.7GB | 6.5GB | 32k | Code-specialised baseline. 8GB GPU. |
| `qwen3:4b-instruct` | 2.5GB | 4GB | 256k | **The CPU default.** Best small all-rounder. |
| `llama3.2:3b` | 2.0GB | 3GB | 128k | Small generalist, dependable tool calling. |
| `qwen3:1.7b` | 1.4GB | 2.5GB | 40k | Tool calling still holds. Simple tasks. |
| `qwen3:0.6b` | 522MB | 1.5GB | 40k | Runs anywhere. Hand-hold every step. |

Sizes are approximate and include working KV cache, not just weights.
`mini models --refresh` re-checks each entry against the ollama library so a
model that disappears upstream shows as `gone` rather than failing at pull time.

**Native context is a hard ceiling.** The whole qwen2.5-coder family is a 32k
architecture. Setting `num_ctx 65536` on one does not produce a 64k model —
ollama honours the architecture limit and quietly runs it at 32768. Check any
model you add with:

```bash
ollama show <model> | grep 'context length'
```

and put that number in the registry. An inflated value there only makes mini
report a context it does not have. If you genuinely need more than 32k, that
means a long-context model — `devstral:24b` or `gpt-oss:20b` at 128k — which in
practice means a GPU.

## What actually matters in a model here

Not benchmark scores. In rough order:

1. **Tool calling that holds up over many turns.** The agent's job is a loop of
   run-command → read-output → decide. A model that emits malformed tool calls
   on turn six is worse than a smaller one that stays coherent.
2. **Context.** See below. Below 32k the agent forgets what it already checked.
3. **Instruction following.** The system prompt has hard safety rules. A model
   that drifts from them is a liability with a root shell.
4. **Speed.** Sysadmin work is many short turns. Latency per turn compounds.

Raw coding ability matters less than you would expect — the work is mostly
reading command output and deciding what to run next.

## The context variant

mini never runs a base model directly. It builds a derived one:

```
FROM qwen2.5-coder:7b
PARAMETER num_ctx 32768
```

registered as `mini-qwen2.5-coder-7b:32k` — the context is the smaller of what
your memory allows and what the model natively supports.

**Why this is not optional.** Ollama's default context is 4096 tokens. opencode's
system prompt and tool definitions nearly fill that before you type anything. The
result is not an error — it is an agent that truncates tool calls and appears to
randomly give up mid-task. It looks like the model is stupid. It is not; it has
no room to think.

Context is chosen from the budget, then capped at what the model supports:

| Budget | Context |
|---|---|
| ≥12GB | 65536 |
| ≥6GB | 32768 |
| ≥3GB | 16384 |
| below | 8192 |

KV cache is not free — 64k on a 3GB box would swap and be slower than a smaller
window. `mini doctor` warns when your context lands below 64k so you know the
agent is running with less room than opencode wants.

No `SYSTEM` line is baked into the variant. opencode sends its own system
prompt, which shadows it anyway; the brain belongs in `AGENTS.md` where you can
read and edit it.

## Switching

```bash
mini models                     # what fits, what is pulled, what is current
mini model qwen2.5-coder:14b    # switch
mini model auto                 # back to the hardware recommendation
```

Switching pulls the base model and builds the variant, so the first switch to a
model is slow and every switch back is instant — both variants stay registered
in ollama.

Disk cost is real: each base model is 1–20GB and each variant adds a small layer
on top. `ollama list` shows everything; `ollama rm <model>` reclaims it.

## Using a model that is not in the registry

```bash
mini model granite4:3b
mini model hf.co/unsloth/Qwen3-4B-Instruct-GGUF:Q4_K_M    # straight from HuggingFace
```

mini warns that it is unknown, then tries anyway: pulls it, picks a context from
your budget, builds the variant. The registry is a curated shortlist, not a
whitelist — anything `ollama pull` accepts works, including any GGUF on
HuggingFace via the `hf.co/<user>/<repo>:<quant>` form.

Before committing to one, check the two things that decide whether it can be an
agent at all:

```bash
ollama show <model> | grep -A5 Capabilities     # must list "tools"
ollama show <model> | grep 'context length'     # the real ceiling
```

No `tools` capability means no tool calling, which means it cannot run a single
command — it will only talk about them.

To make it permanent, add a row to `share/models.tsv` — keep the file ordered
best → smallest, since selection takes the first row that fits.

## Remote ollama

Point mini at a machine with a real GPU:

```bash
export OLLAMA_HOST=192.168.1.10:11434
mini doctor
```

mini will use the remote server for inference while still operating on the local
box. The remote needs the variant built on it — run `mini setup` there once, or
create it by hand with the same `FROM`/`PARAMETER` Modelfile.
