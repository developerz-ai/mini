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
# The class column is not read by anything yet, so callers bind it to _class.
#
# Repeated tabs are squeezed: the registry is hand-edited and aligned by eye, so
# a row padded with two tabs would otherwise shift every field after it and
# silently hand out a memory figure where a context size belongs.
models_rows() {
  [ -f "$MODELS_TSV" ] || die "model registry missing: $MODELS_TSV"
  grep -v '^[[:space:]]*#' "$MODELS_TSV" | grep -v '^[[:space:]]*$' | tr -s '\t'
}

models_field() {
  local id="$1" n="$2"
  models_rows | awk -F'\t' -v id="$id" -v n="$n" '$1==id{print $n; exit}'
}

models_known() { [ -n "$(models_field "$1" 1)" ]; }

# Pick the best model that fits BUDGET_MB.
#
# On CPU we stop at qwen3:4b-instruct regardless of how much RAM there is.
# Measured on an
# ordinary CPU box: 7b generates ~2.5 tok/s, which is not an interactive agent
# no matter how much memory you have. What actually decides whether a local
# agent feels usable on CPU is time-to-first-token, and that is dominated by
# prompt size, not parameter count — so a smaller model that answers is worth
# more than a larger one you stop waiting for.
#
# With a GPU the cap does not apply and the big models are the right answer.
# `mini model <id>` overrides either way.
models_recommend() {
  local budget="${BUDGET_MB:-0}" accel="${ACCEL:-cpu}" cpu_cap='qwen3:4b-instruct'
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

# Context window for a given model on this box.
#
# opencode wants 64k+. The limit is KV cache, which grows linearly with the
# window and is charged upfront — mini runs ollama with flash attention and a
# q8_0 KV cache, which roughly halves that cost and is what makes these numbers
# affordable on an ordinary machine.
#
# A bigger window does not slow anything down on its own: prefill cost tracks
# the tokens actually in the prompt, not the size of the allocation. It only
# costs memory. So take as much as the box and the architecture allow.
models_pick_ctx() {
  local id="$1" budget="${BUDGET_MB:-0}" max_ctx want
  max_ctx=$(models_field "$id" 3)
  [ -n "$max_ctx" ] || max_ctx=32768

  if   [ "$budget" -ge 20000 ]; then want=131072
  elif [ "$budget" -ge 12000 ]; then want=65536
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
  # Only inference parameters are baked in. The system prompt stays in
  # AGENTS.md, which opencode injects — baking one here would just be shadowed.
  printf 'FROM %s\nPARAMETER num_ctx %s\n' "$base" "$ctx" > "$modelfile"

  # On CPU, llama.cpp grabs every core and the machine becomes unusable while
  # the agent thinks — which on a laptop is the whole machine, including the
  # terminal you are watching. Leave two cores for the user. The throughput
  # cost is small; CPU inference is memory-bandwidth bound well before it is
  # core bound.
  if [ "${ACCEL:-cpu}" = 'cpu' ] && [ "${CPU_CORES:-0}" -gt 3 ]; then
    printf 'PARAMETER num_thread %s\n' "$(( CPU_CORES - 2 ))" >> "$modelfile"
  fi
  ollama create "$variant" -f "$modelfile" >/dev/null || {
    rm -f "$modelfile"; die "ollama create failed for ${variant}"
  }
  rm -f "$modelfile"
  ok "model ready: ${C_BOLD}${variant}${C_RESET}"
  printf '%s\n' "$variant"
}

# Interactive pick list for setup. Shows what will actually run here, marks the
# recommendation, and takes a number or a name. Everything it prints is either
# measured from this machine or verified in the registry — no "should work".
#
# Echoes the chosen model id on stdout; everything else goes to stderr so the
# caller can capture the answer cleanly.
models_choose() {
  local recommended installed n=0 id min_mb max_ctx _class note
  recommended=$(models_recommend)
  installed=$(ollama list 2>/dev/null | awk 'NR>1{print $1}' || true)

  local -a ids=() slow_ids=() slow_lines=()

  {
    printf '\n%s\n' "${C_BOLD}Pick a model${C_RESET} ${C_DIM}(budget ${BUDGET_MB} MB, ${ACCEL})${C_RESET}"
    printf '\n%s\n' "${C_BOLD}Recommended for this machine${C_RESET}"
  } >&2

  # Fitting in memory is not the same as being a good idea. On CPU, everything
  # above the cap technically runs and is technically unusable, so it goes in a
  # second list with the reason attached rather than at the top where it looks
  # like the best option.
  local past_cap=0
  while IFS=$'\t' read -r id min_mb max_ctx _class note; do
    [ -n "$id" ] || continue
    [ "${BUDGET_MB:-0}" -ge "$min_mb" ] || continue

    # The recommendation is itself the cap, so flip the flag before judging this
    # row — otherwise the recommended model gets filed as "too big".
    [ "$id" = "$recommended" ] && past_cap=1

    local usable=1
    if [ "${ACCEL:-cpu}" = 'cpu' ] && [ "$past_cap" -eq 0 ]; then
      usable=0
    fi

    local tag='' ctx_here
    printf '%s\n' "$installed" | grep -qx -- "$id" && tag=" ${C_DIM}(pulled)${C_RESET}"
    ctx_here=$(models_pick_ctx "$id")

    if [ "$usable" -eq 1 ]; then
      n=$(( n + 1 ))
      ids+=("$id")
      local mark='  '
      [ "$id" = "$recommended" ] && { mark="${C_GREEN}▸${C_RESET} "; tag="${tag} ${C_GREEN}← best here${C_RESET}"; }
      printf '%s%s) %-20s %5s ctx%s\n' "$mark" "$n" "$id" "$(( ctx_here / 1024 ))k" "$tag" >&2
      printf '     %s\n' "${C_DIM}${note}${C_RESET}" >&2
    else
      slow_ids+=("$id")
      slow_lines+=("$(printf '%-20s %5s ctx%s' "$id" "$(( ctx_here / 1024 ))k" "$tag")")
    fi
  done <<EOF
$(models_rows)
EOF

  # Second list: fits the memory, too slow to enjoy without a GPU.
  if [ "${#slow_ids[@]}" -gt 0 ]; then
    printf '\n%s %s\n' "${C_BOLD}Bigger${C_RESET}" "${C_DIM}— fits your memory, but needs a GPU to feel interactive${C_RESET}" >&2
    local i
    for i in "${!slow_ids[@]}"; do
      n=$(( n + 1 ))
      ids+=("${slow_ids[$i]}")
      printf '  %s) %s\n' "$n" "${slow_lines[$i]}" >&2
    done
  fi

  if [ "$n" -eq 0 ]; then
    warn "nothing in the registry fits ${BUDGET_MB} MB — using the smallest anyway"
    models_rows | tail -n1 | cut -f1
    return 0
  fi

  printf '\n' >&2
  local answer
  answer=$(ask "number, or a model name" "$recommended")

  # A bare number selects from the list; anything else is taken as a model id,
  # including one not in the registry (hf.co/... pulls work fine).
  case "$answer" in
    ''|*[!0-9]*) printf '%s\n' "$answer" ;;
    *)
      if [ "$answer" -ge 1 ] && [ "$answer" -le "$n" ]; then
        printf '%s\n' "${ids[$(( answer - 1 ))]}"
      else
        warn "no option ${answer} — using ${recommended}"
        printf '%s\n' "$recommended"
      fi
      ;;
  esac
}

# `mini models` — registry, fit, and what is on disk.
models_list() {
  local refresh="${1:-}" current installed id min_mb max_ctx _class note
  current=$(cfg_get MINI_BASE_MODEL)
  installed=''
  if ollama_up; then
    installed=$(ollama list 2>/dev/null | awk 'NR>1{print $1}' || true)
  fi

  step "Models for this machine ${C_DIM}(budget ${BUDGET_MB} MB, ${ACCEL})${C_RESET}"
  printf '  %-20s %-8s %-8s %-9s %s\n' 'MODEL' 'NEEDS' 'CTX' 'STATUS' 'NOTE'

  while IFS=$'\t' read -r id min_mb max_ctx _class note; do
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
