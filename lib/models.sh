#!/usr/bin/env bash
# models.sh — the model registry, hardware-fit selection, and the context-window
# variant that makes local models actually usable as agents.
#
# The single most common reason a local coding agent "just stops working" is
# Ollama's 4k default context: opencode's tool definitions alone eat most of it
# and tool calls start truncating. mini never runs a base model directly — it
# builds a derived model with num_ctx baked in.

MODELS_TSV="${MINI_SHARE}/models.tsv"

# Emit "id min_budget max_ctx class note" per registry row, comments stripped.
models_rows() {
  [ -f "$MODELS_TSV" ] || die "model registry missing: $MODELS_TSV"
  grep -v '^[[:space:]]*#' "$MODELS_TSV" | grep -v '^[[:space:]]*$'
}

models_field() {
  local id="$1" n="$2"
  models_rows | awk -F'\t' -v id="$id" -v n="$n" '$1==id{print $n; exit}'
}

models_known() { [ -n "$(models_field "$1" 1)" ]; }

# Pick the best model that fits BUDGET_MB.
#
# On CPU we deliberately stop at 7b even when RAM is plentiful: a 24B model on
# CPU produces a few tokens a second, which is unusable for an interactive
# agent. `mini model <id>` overrides this if you disagree.
models_recommend() {
  local budget="${BUDGET_MB:-0}" accel="${ACCEL:-cpu}" cpu_cap='qwen2.5-coder:7b'
  local capped=0 id min_mb

  while IFS=$'\t' read -r id min_mb _; do
    [ -n "$id" ] || continue
    if [ "$accel" = 'cpu' ] && [ "$capped" -eq 0 ]; then
      [ "$id" = "$cpu_cap" ] && capped=1
      [ "$capped" -eq 0 ] && continue
    fi
    if [ "$budget" -ge "$min_mb" ]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<EOF
$(models_rows)
EOF

  # Nothing fits — hand back the smallest and let doctor complain about it.
  models_rows | tail -n1 | cut -f1
}

# Context window for a given model on this box. opencode wants 64k+; we only
# go lower when the memory simply is not there, and doctor warns when we do.
models_pick_ctx() {
  local id="$1" budget="${BUDGET_MB:-0}" max_ctx want
  max_ctx=$(models_field "$id" 3)
  [ -n "$max_ctx" ] || max_ctx=65536

  if   [ "$budget" -ge 12000 ]; then want=65536
  elif [ "$budget" -ge 6000 ];  then want=32768
  elif [ "$budget" -ge 3000 ];  then want=16384
  else                                want=8192
  fi

  [ "$want" -gt "$max_ctx" ] && want="$max_ctx"
  printf '%s\n' "$want"
}

# Derived model name: mini-qwen2.5-coder-7b:64k
models_variant_name() {
  local id="$1" ctx="$2"
  printf 'mini-%s:%sk\n' "$(slugify_model "$id")" "$(( ctx / 1024 ))"
}

# Does the ollama library have this model? Cheap 200/404 probe, no auth.
models_exists_upstream() {
  local base="${1%%:*}" code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "https://ollama.com/library/${base}/tags" 2>/dev/null) || return 1
  [ "$code" = '200' ]
}

# Pull the base model, then build the context variant on top of it.
models_ensure() {
  local base="$1" ctx="$2" variant
  variant=$(models_variant_name "$base" "$ctx")

  if ollama_has_model "$variant"; then
    ok "model ready: ${C_BOLD}${variant}${C_RESET}"
    printf '%s\n' "$variant"
    return 0
  fi

  if ! ollama_has_model "$base"; then
    info "pulling ${base} — this is the one slow step, grab a coffee"
    ollama pull "$base" || die "could not pull ${base}"
  fi

  info "building ${variant} (context ${ctx})"
  local modelfile
  modelfile=$(mktemp "${TMPDIR:-/tmp}/mini-modelfile.XXXXXX")
  # Only num_ctx is baked in. The system prompt stays in AGENTS.md, which
  # opencode injects — baking one here would just be shadowed by opencode's.
  printf 'FROM %s\nPARAMETER num_ctx %s\n' "$base" "$ctx" > "$modelfile"
  ollama create "$variant" -f "$modelfile" >/dev/null || {
    rm -f "$modelfile"; die "ollama create failed for ${variant}"
  }
  rm -f "$modelfile"
  ok "model ready: ${C_BOLD}${variant}${C_RESET}"
  printf '%s\n' "$variant"
}

# `mini models` — registry, fit, and what is on disk.
models_list() {
  local refresh="${1:-}" current installed id min_mb max_ctx class note
  current=$(cfg_get MINI_BASE_MODEL)
  installed=$(ollama_up && ollama list 2>/dev/null | awk 'NR>1{print $1}' || true)

  step "Models for this machine ${C_DIM}(budget ${BUDGET_MB} MB, ${ACCEL})${C_RESET}"
  printf '  %-20s %-8s %-8s %-9s %s\n' 'MODEL' 'NEEDS' 'CTX' 'STATUS' 'NOTE'

  while IFS=$'\t' read -r id min_mb max_ctx class note; do
    [ -n "$id" ] || continue
    local status='' mark=' '
    [ "$id" = "$current" ] && mark='*'
    if printf '%s\n' "$installed" | grep -qx -- "$id"; then
      status="${C_GREEN}pulled${C_RESET}"
    elif [ "${BUDGET_MB:-0}" -ge "$min_mb" ]; then
      status="${C_DIM}fits${C_RESET}"
    else
      status="${C_RED}too big${C_RESET}"
    fi
    if [ "$refresh" = '--refresh' ]; then
      models_exists_upstream "$id" || status="${C_RED}gone${C_RESET}"
    fi
    printf ' %s%-20s %-8s %-8s %-19s %s\n' \
      "$mark" "$id" "${min_mb}MB" "$max_ctx" "$status" "${C_DIM}${note}${C_RESET}"
  done <<EOF
$(models_rows)
EOF

  say ''
  dim "  * = current    'fits' = would run here    'too big' = not enough memory"
  dim "  switch with:  mini model <id>     re-check availability:  mini models --refresh"
}
