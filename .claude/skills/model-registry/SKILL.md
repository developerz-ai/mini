---
description: Adding or verifying a row in the model registry. Use for models.tsv, num_ctx, context length, ollama show.
---

> House skill — established by dz-runner setup mode from this repo's own evidence, then owned by its maintainers. Correct it in place; setup never overwrites a skill that exists.

1. Add one row to `share/models.tsv` as `id<TAB>min_budget_mb<TAB>max_ctx<TAB>class<TAB>note`. Keep it tab-separated and hand-aligned.
2. Verify both facts before you keep the row:
   - `ollama show <model> | grep -A5 Capabilities` must list `tools`; if it lists `thinking`, drop the model — a reasoning model burns the output budget and can return empty content.
   - `ollama show <model> | grep 'context length'` is the real `max_ctx`. Never inflate it; ollama honours the architecture limit and mini would report a context it does not have.
3. Put the row in registry order (best → smallest) — `lib/models.sh` selects the first row that fits `BUDGET_MB`.
4. Re-date the header comment `# mini model registry — curated YYYY-MM`.
5. Run `bash .github/run-tests.sh` → must exit 0. fail -> fix the row before continuing.
6. Run `bin/mini models` → the new row must print `fits` or `too big` against this box. fail -> correct `min_budget_mb` before continuing.
7. If the model needs a context variant, confirm mini builds `mini-<base>:<n>k` with `num_ctx` baked in — a base model is never launched directly.
