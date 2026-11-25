#!/bin/zsh
# router.sh - routing library. Functions only; not run directly.
# orchestrate.sh sources it.
# Configuration: routes.conf (tier -> model chain), limits.conf (daily limits).
# Env for testing:
#   ORCH_NOW="2026-11-09 10:00"  - freezes the clock (interpreted in the PEAK_TZ time zone)
#   ORCH_USAGE_DIR=/tmp/...      - changes the usage dir (so the real counters are not touched)
set -u

ROUTER_DIR="${${(%):-%x}:A:h}"
ROUTER_PEAK_TZ="${PEAK_TZ:-UTC}"   # time zone of the provider's published peak window
ROUTER_BACKENDS="$ROUTER_DIR/backends.conf"
ROUTER_ROUTES="$ROUTER_DIR/routes.conf"
ROUTER_LIMITS="$ROUTER_DIR/limits.conf"
ROUTER_USAGE_DIR="${ORCH_USAGE_DIR:-$ROUTER_DIR/usage}"
(( ${+RTR_RUN} )) || typeset -gA RTR_RUN

# ---------- time / peak hours ----------

router_today() {
  if [[ -n "${ORCH_NOW:-}" ]]; then
    print -r -- "${ORCH_NOW%% *}"
  else
    date +%F
  fi
}

router_sh_dow() {
  if [[ -n "${ORCH_NOW:-}" ]]; then
    date -d "$ORCH_NOW" +%u 2>/dev/null && return 0   # GNU date
    date -j -f "%Y-%m-%d %H:%M" "$ORCH_NOW" +%u 2>/dev/null && return 0
    date -j -f "%Y-%m-%d" "${ORCH_NOW%% *}" +%u 2>/dev/null && return 0
    print -r -- 0
    return 1
  fi
  TZ="$ROUTER_PEAK_TZ" date +%u
}

router_sh_hour() {
  if [[ -n "${ORCH_NOW:-}" ]]; then
    date -d "$ORCH_NOW" +%H 2>/dev/null && return 0   # GNU date
    date -j -f "%Y-%m-%d %H:%M" "$ORCH_NOW" +%H 2>/dev/null && return 0
    print -r -- 00
    return 1
  fi
  TZ="$ROUTER_PEAK_TZ" date +%H
}

# Provider peak hours (PEAK_TZ, default UTC), Monday-Friday, 09:00-12:00 and 14:00-18:00
router_is_peak() {
  local dow hh
  dow=$(router_sh_dow) || return 1
  hh=$(router_sh_hour) || return 1
  [[ "$dow" =~ '^[0-9]+$' && "$hh" =~ '^[0-9]+$' ]] || return 1
  (( dow >= 1 && dow <= 5 )) || return 1
  hh=$(( 10#$hh ))
  (( (hh >= 9 && hh < 12) || (hh >= 14 && hh < 18) )) && return 0
  return 1
}

router_peak_label() {
  if router_is_peak; then print -r -- "peak"; else print -r -- "off-peak"; fi
}

# ---------- usage counters ----------

router_usage_file()   { print -r -- "$ROUTER_USAGE_DIR/$(router_today).tsv"; }
router_exhausted_file() { print -r -- "$ROUTER_USAGE_DIR/exhausted-$(router_today).txt"; }

router_count() {
  local m="${1%%\%*}" f
  f=$(router_usage_file)
  [[ -f "$f" ]] || { print -r -- 0; return 0; }
  awk -F'\t' -v m="$m" '$1==m { n+=$2 } END { print n+0 }' "$f"
}

router_inc() {
  local m="${1%%\%*}" f
  [[ -n "$m" ]] || return 1
  mkdir -p "$ROUTER_USAGE_DIR" 2>/dev/null || return 1
  f=$(router_usage_file)
  print -r -- "$m"$'\t'1 >> "$f" 2>/dev/null || return 1
  return 0
}

router_is_exhausted() {
  local f
  f=$(router_exhausted_file)
  [[ -f "$f" ]] && grep -Fxq -- "${1%%\%*}" "$f" 2>/dev/null
}

router_mark_exhausted() {
  local m="${1%%\%*}" f
  [[ -n "$m" ]] || return 1
  mkdir -p "$ROUTER_USAGE_DIR" 2>/dev/null
  f=$(router_exhausted_file)
  grep -Fxq -- "$m" "$f" 2>/dev/null || print -r -- "$m" >> "$f"
}

# model -> daily limit (pattern); returns empty if no line matches (= unlimited)
router_cap() {
  local m="$1" line pat cap
  [[ -f "$ROUTER_LIMITS" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line%$'\r'}"
    pat="${line%%|*}"; cap="${line#*|}"
    cap="${cap%%|*}"
    pat="${pat// /}"; cap="${cap// /}"
    [[ -z "$pat" || -z "$cap" ]] && continue
    if [[ "$m" == ${~pat} ]]; then
      print -r -- "$cap"
      return 0
    fi
  done < "$ROUTER_LIMITS"
  return 1
}

# ---------- model / backend ----------

router_alias() {   # ag|ds|gm|name -> backend name
  case "$1" in
    ag) print -r -- antigravity ;;
    ds) print -r -- deepseek ;;
    gm) print -r -- gemini ;;
    *)  print -r -- "$1" ;;
  esac
}

router_backend_exists() {
  local b="$1" line
  [[ -f "$ROUTER_BACKENDS" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    local -a f=("${(@s:|:)line}")
    [[ "${f[1]}" == "$b" ]] && return 0
  done < "$ROUTER_BACKENDS"
  return 1
}

router_backend_enabled() {
  local b="$1" line
  [[ -f "$ROUTER_BACKENDS" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    local -a f=("${(@s:|:)line}")
    [[ "${f[1]}" == "$b" ]] || continue
    [[ "${f[6]:-on}" == "on" ]] && return 0
    return 1
  done < "$ROUTER_BACKENDS"
  return 1
}

# backend + tier -> model from backends.conf (medium/critical -> strong)
router_backend_model() {
  local b="$1" tier="$2" line
  [[ -f "$ROUTER_BACKENDS" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    local -a f=("${(@s:|:)line}")
    [[ "${f[1]}" == "$b" ]] || continue
    case "$tier" in
      light) print -r -- "${f[3]}" ;;
      *)     print -r -- "${f[4]}" ;;
    esac
    return 0
  done < "$ROUTER_BACKENDS"
  return 1
}

router_guess_backend() {   # guess the backend from the model name
  case "$1" in
    ds-*) print -r -- deepseek ;;
    ag-*) print -r -- antigravity ;;
    *) print -r -- "" ;;
  esac
}

# spec -> SP_BACKEND SP_MODEL SP_OFFPEAK
router_spec_parts() {
  local spec="$1" rest="$1"
  SP_OFFPEAK=0
  if [[ "$rest" == *@offpeak ]]; then SP_OFFPEAK=1; rest="${rest%@offpeak}"; fi
  if [[ "$rest" == *:* ]]; then
    SP_MODEL="${rest#*:}"
    SP_BACKEND="$(router_alias "${rest%%:*}")"
  else
    SP_MODEL=""
    SP_BACKEND="$(router_alias "$rest")"
  fi
}

# tier -> chain (one spec per line)
router_chain() {
  local t="$1" line i
  [[ -f "$ROUTER_ROUTES" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line%$'\r'}"
    [[ "${line%%|*}" == "$t" ]] || continue
    local -a f=("${(@s:|:)line}")
    for (( i = 2; i <= ${#f}; i++ )); do
      [[ -n "${f[i]}" ]] && print -r -- "${f[i]}"
    done
    return 0
  done < "$ROUTER_ROUTES"
  return 1
}

# ---------- eligibility check ----------
# router_eval_spec <spec> <pool any|free>
#   0 = usable
#   1 = skip (limit / exhausted / disabled)
#   2 = temporarily full (3 lanes already running on the backend)
router_eval_spec() {
  local spec="$1" pool="${2:-any}"
  REASON=""
  router_spec_parts "$spec"
  if [[ -z "$SP_MODEL" ]]; then REASON="bad spec ($spec)"; return 1; fi
  if ! router_backend_enabled "$SP_BACKEND"; then
    if router_backend_exists "$SP_BACKEND"; then
      REASON="backend $SP_BACKEND is disabled"
    else
      REASON="backend $SP_BACKEND missing/disabled (backends.conf)"
    fi
    return 1
  fi
  if [[ "$pool" == "free" && "$SP_BACKEND" != "antigravity" ]]; then
    REASON="pool=free - Antigravity only (no paid usage)"
    return 1
  fi
  if router_is_exhausted "$SP_MODEL"; then
    REASON="quota exhausted (marked exhausted today)"
    return 1
  fi
  local cap used
  if cap=$(router_cap "$SP_MODEL"); then
    used=$(router_count "$SP_MODEL")
    if (( used >= cap )); then
      REASON="daily limit reached ($used/$cap)"
      return 1
    fi
  fi
  if (( SP_OFFPEAK )) && router_is_peak; then
    REASON="DeepSeek peak hours (@offpeak only runs outside peak)"
    return 1
  fi
  local n=0
  (( ${+RTR_RUN} )) && n=${RTR_RUN[$SP_BACKEND]:-0}
  if (( n >= 3 )); then
    REASON="backend full ($n/3 parallel)"
    return 2
  fi
  return 0
}

# ---------- selection ----------
# router_pick <tier> <pool> <forced-backend> <forced-model> <skip-csv>
#   0 -> PICK_SPEC PICK_BACKEND PICK_MODEL PICK_NOTE (+PICK_FORCED=1)
#   1 -> REASON (all candidates unusable)
#   2 -> REASON (all candidates temporarily full)
router_pick() {
  local tier="$1" pool="${2:-any}" fbk="${3:-}" fmdl="${4:-}" skips="${5:-}"
  local -a chain cands notes
  local spec rc s found transient=0

  chain=("${(@f)$(router_chain "$tier")}")
  chain=("${(@)chain:#}")
  PICK_FORCED=0

  if [[ -n "$fmdl" ]]; then
    PICK_FORCED=1
    found=""
    for s in "${chain[@]}"; do
      router_spec_parts "$s"
      [[ "$SP_MODEL" == "$fmdl" ]] && { found="$s"; break }
    done
    if [[ -z "$found" ]]; then
      local gb; gb=$(router_guess_backend "$fmdl")
      [[ -n "$gb" ]] || { REASON="#model: $fmdl - could not determine the backend"; return 1; }
      found="$gb:$fmdl"
    fi
    cands=("$found")
  elif [[ -n "$fbk" ]]; then
    PICK_FORCED=1
    local fb; fb=$(router_alias "$fbk")
    found=""
    for s in "${chain[@]}"; do
      router_spec_parts "$s"
      [[ "$SP_BACKEND" == "$fb" ]] && { found="$s"; break }
    done
    if [[ -z "$found" ]]; then
      local bm; bm=$(router_backend_model "$fb" "$tier")
      [[ -n "$bm" ]] || { REASON="#backend: $fbk - no model found for this backend"; return 1; }
      found="$fb:$bm"
    fi
    cands=("$found")
  else
    cands=("${(@)chain}")
  fi

  if (( ${#cands[@]} == 0 )); then
    REASON="tier '$tier' not found in routes.conf"
    return 1
  fi

  notes=()
  for spec in "${cands[@]}"; do
    if [[ ",$skips," == *",$spec,"* ]]; then
      notes+=("$spec: already tried")
      continue
    fi
    router_eval_spec "$spec" "$pool"
    rc=$?
    if (( rc == 0 )); then
      PICK_SPEC="$spec"; PICK_BACKEND="$SP_BACKEND"; PICK_MODEL="$SP_MODEL"
      PICK_NOTE="${(j:; :)notes}"
      return 0
    fi
    (( rc == 2 )) && transient=1
    notes+=("$spec: $REASON")
  done

  PICK_NOTE="${(j:; :)notes}"
  if (( ${#notes[@]} == 0 )); then
    REASON="no model left in the chain"
    return 1
  fi
  REASON="$PICK_NOTE"
  (( transient )) && return 2
  return 1
}

# ---------- task header ----------
# first 5 lines of the file: #tier: / #backend: / #model: / #pool:
router_read_header() {
  local f="$1" line i=0
  RH_TIER="" RH_BACKEND="" RH_MODEL="" RH_POOL=""
  while IFS= read -r line; do
    i=$(( i + 1 ))
    (( i > 5 )) && break
    line="${line%$'\r'}"
    case "$line" in
      '#tier:'*)    RH_TIER="${${line#\#tier:}// /}" ;;
      '#backend:'*) RH_BACKEND="${${line#\#backend:}// /}" ;;
      '#model:'*)   RH_MODEL="${${line#\#model:}// /}" ;;
      '#pool:'*)    RH_POOL="${${line#\#pool:}// /}" ;;
    esac
  done < "$f"
}
