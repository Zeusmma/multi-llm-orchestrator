#!/bin/zsh
# orchestrate.sh - multi-backend LLM agent orchestrator (macOS / Linux, zsh)
#   split: distributes tasks round-robin over the enabled backends (in parallel).
#   dual : sends every task to the first 2 enabled backends and builds <name>.compare.md.
#   tri  : sends every task to the first 3 enabled backends.
#   route: quota-aware routing through a tier -> model chain.
set -u
setopt TYPESET_SILENT   # macOS zsh 5.9 defaults to OFF: bare `local` in a loop would print values to stdout

ORCH_DIR="${0:A:h}"
CONF="$ORCH_DIR/backends.conf"
LANE="$ORCH_DIR/lane.sh"
DRY=0

# Routing library (routes.conf, limits.conf, usage counters)
source "$ORCH_DIR/router.sh"

die() { print -u2 "orchestrate.sh: $*"; exit 2; }

usage() {
  cat <<'EOF'
Usage:
  orchestrate.sh run <tasks-dir> <out-dir> [--mode split|dual|tri|route] [--tier light|medium|strong|critical]
                 [--pool free|any] [--workdir DIR] [--max N]
  orchestrate.sh --dry-run run <tasks-dir> <out-dir> [--mode ...]   # show the commands that would run, run nothing
  orchestrate.sh route-plan <tasks-dir> [--pool free|any]           # dry: which model each task would get, and why
  orchestrate.sh usage                                             # today's counters, limits, exhausted list
  orchestrate.sh add-api <name> <kind anthropic|openai> <base_url> <model_light> <model_strong>
  orchestrate.sh list
  orchestrate.sh enable <name> | disable <name>

Modes:
  split - tasks are distributed round-robin across enabled backends (max N parallel per backend).
  dual  - every task goes to the first 2 enabled backends (deepseek, antigravity) in parallel; <name>.compare.md is built.
  tri   - same, but with the first 3 enabled backends; errors out if fewer than 3 are enabled.
  route - quota-aware routing: routes.conf chain, limits.conf limits, @offpeak,
          escalation to the next model when quota runs out, 3 parallel lanes per backend. Writes <out-dir>/report.md at the end.

Task header (first lines, optional):
  #tier: light|medium|strong|critical   #backend: <ad>   #model: <model-id>   #pool: free|any
EOF
}

enabled_names() { awk -F'|' 'NF>=5 && $1 !~ /^#/ && $6 != "off" {print $1}' "$CONF"; }
backends_all()  { awk -F'|' 'NF>=5 && $1 !~ /^#/ {print}' "$CONF"; }
key_set()       { local v="ORCH_${${(U)1}//[^A-Z0-9]/_}_API_KEY"; [[ -n "${(P)v:-}" ]]; }

cmd_list() {
  [[ -f "$CONF" ]] || die "backends.conf not found: $CONF"
  printf '%-15s %-12s %-8s %s\n' "BACKEND" "KIND" "ENABLED" "KEY"
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    local -a f=("${(@s:|:)line}")
    local name="${f[1]}" kind="${f[2]}" en="${f[6]:-on}"
    local key=no
    case "$kind" in
      deepseek)            [[ -n "${DEEPSEEK_API_KEY:-}" ]] && key=yes ;;
      anthropic|openai)    key_set "$name" && key=yes ;;
      antigravity)         [[ -x ${AGY_BIN:-$HOME/.local/bin/agy} ]] && key=login ;;
    esac
    printf '%-15s %-12s %-8s %s\n' "$name" "$kind" "$en" "$key"
  done < "$CONF"
}

cmd_enable() {
  local onoff="$1"; local name="${2:?backend name is required}"
  [[ -f "$CONF" ]] || die "backends.conf not found: $CONF"
  local found=0 tmp="$CONF.tmp.$$"
  : > "$tmp"
  local line
  while IFS= read -r line; do
    if [[ -z "$line" || "$line" == \#* ]]; then
      print -r -- "$line" >> "$tmp"; continue
    fi
    local -a f=("${(@s:|:)line}")
    if [[ "${f[1]}" == "$name" ]]; then
      found=1
      f[6]="$onoff"
      print -r -- "${f[1]}|${f[2]}|${f[3]}|${f[4]}|${f[5]}|${f[6]}" >> "$tmp"
    else
      print -r -- "$line" >> "$tmp"
    fi
  done < "$CONF"
  [[ $found -eq 1 ]] || { rm -f "$tmp"; die "backend not found: $name"; }
  mv "$tmp" "$CONF" || { rm -f "$tmp"; die "could not write backends.conf"; }
  print "OK: $name → ${onoff}"
}

cmd_addapi() {
  [[ $# -eq 5 ]] || { usage >&2; die "add-api <name> <kind anthropic|openai> <base_url> <model_light> <model_strong>"; }
  local name="$1" kind="$2" base="$3" ml="$4" ms="$5"
  [[ -f "$CONF" ]] || die "backends.conf not found: $CONF"
  [[ "$kind" == anthropic || "$kind" == openai ]] || die "kind must be anthropic|openai (got: $kind)"
  [[ -n "$name" && "$name" != *'|'* && "$name" != *[[:space:]]* ]] || die "name must not be empty and must not contain whitespace or '|'"
  if backends_all | awk -F'|' -v n="$name" '$1==n{f=1} END{exit f?0:1}'; then
    die "this name already exists: $name"
  fi
  printf '%s|%s|%s|%s|%s|on\n' "$name" "$kind" "$ml" "$ms" "$base" >> "$CONF" \
    || die "could not append to backends.conf"
  local envname="ORCH_${${(U)name}//[^A-Z0-9]/_}_API_KEY"
  print "OK: $name added (kind=$kind). Export the API key as env var: $envname"
}

build_compare() {
  # $tasks, $use, $out_dir come from cmd_run's local variables (zsh dynamic scope).
  local f name cmp bk o code lines all0 allsame ref
  for f in $tasks; do
    name="${f:t:r}"
    cmp="$out_dir/${name}.compare.md"
    {
      print "# ${name} - comparison"
      print ""
      for bk in $use; do
        o="$out_dir/${name}.${bk}.out"
        code="-"; lines=0
        if [[ -f "$o" ]]; then
          lines=$(wc -l < "$o" | tr -d ' ')
          if tail -1 "$o" | grep -qE '^exit [0-9]+$'; then
            code=$(tail -1 "$o" | sed -E 's/^exit ([0-9]+)$/\1/')
          fi
        fi
        print "## ${bk} (exit ${code}, ${lines} lines)"
        print ""
        if [[ -f "$o" ]]; then
          if tail -1 "$o" | grep -qE '^exit [0-9]+$'; then sed -e '$d' "$o"; else cat "$o"; fi
        else
          print "(result file missing: $o)"
        fi
        print ""
      done
      print "## Automatic summary"
      print ""
      all0=yes; allsame=yes; ref=""
      for bk in $use; do
        o="$out_dir/${name}.${bk}.out"
        code="-"; lines=0
        if [[ -f "$o" ]]; then
          lines=$(wc -l < "$o" | tr -d ' ')
          if tail -1 "$o" | grep -qE '^exit [0-9]+$'; then
            code=$(tail -1 "$o" | sed -E 's/^exit ([0-9]+)$/\1/')
          fi
        else
          allsame=no
        fi
        [[ "$code" == "0" ]] || all0=no
        print -r -- "- ${bk}: ${lines} lines, exit ${code}"
        if [[ -z "$ref" ]]; then
          ref="$o"
        elif [[ -f "$ref" && -f "$o" ]]; then
          diff -q <(sed -e '$d' "$ref" 2>/dev/null) <(sed -e '$d' "$o" 2>/dev/null) >/dev/null 2>&1 || allsame=no
        else
          allsame=no
        fi
      done
      print -r -- "- All exit 0: ${all0}"
      print -r -- "- Answers identical: ${allsame}"
    } > "$cmp"
  done
}

# ==================== route mode (quota-aware routing) ====================

lane_has_quota_marker() {
  local out="$1" log="$2"
  local -a files=()
  [[ -n "$out" && -f "$out" ]] && files+=("$out")
  [[ -n "$log" && -f "$log" ]] && files+=("$log")
  (( ${#files[@]} > 0 )) || return 1
  grep -qiE '(^|[^0-9])429([^0-9]|$)|RESOURCE_EXHAUSTED|quota (exceeded|exhausted|reached)|exceeded your (current )?quota|rate.?limit|Insufficient Balance' "${files[@]}" 2>/dev/null
}

run_route() {
  local tasks_dir="$1" out_dir="$2" tier="$3" workdir="$4" max="$5" pool="$6"
  (( max > 3 )) && max=3   # at most 3 parallel lanes per backend

  local -a tasks=()
  local f
  for f in "$tasks_dir"/*.txt(N) "$tasks_dir"/*.md(N); do tasks+=("$f"); done
  [[ ${#tasks[@]} -gt 0 ]] || die "no *.txt / *.md found in tasks-dir: $tasks_dir"

  if [[ $DRY -eq 1 ]]; then
    print "# ORCH route dry-run — default tier=$tier pool=$pool max/backend=$max"
    print "# time: $(router_peak_label) ($ROUTER_PEAK_TZ) | usage: $(router_usage_file)"
    print "# workdir: $workdir"
    print "# out-dir: $out_dir"
    local tf pb prc
    for f in "${tasks[@]}"; do
      router_read_header "$f"
      tf="$tier"; [[ -n "$RH_TIER" ]] && tf="$RH_TIER"
      pb="$pool"; [[ -n "$RH_POOL" ]] && pb="$RH_POOL"
      router_pick "$tf" "$pb" "$RH_BACKEND" "$RH_MODEL" ""
      prc=$?
      if (( prc == 0 )); then
        print -r -- "# ${f:t:r}  tier=$tf  ->  ${PICK_BACKEND}/${PICK_MODEL}  (${PICK_SPEC})"
        [[ -n "$PICK_NOTE" ]] && print -r -- "#   skipped: $PICK_NOTE"
        print -r -- "  $LANE ${(q)PICK_BACKEND} ${(q)tf} ${(q)f} ${(q)out_dir/${f:t:r}.route1.out} ${(q)workdir} ${(q)PICK_MODEL}"
      else
        print -r -- "# ${f:t:r}  tier=$tf  ->  NOT PICKED (code $prc): $REASON"
      fi
    done
    print "ORCH DRY-RUN DONE"
    return 0
  fi

  local statusdir="$out_dir/.orch"
  mkdir -p "$out_dir" "$statusdir" || die "could not create out-dir: $out_dir"
  local att="$statusdir/attempts.tsv"
  : > "$att"

  typeset -A RTR_RUN JOB_PID JOB_TASK JOB_SPEC JOB_BK JOB_MDL JOB_TIER JOB_ATT JOB_START JOB_OUT JOB_META SKIPS
  local -a queue
  for f in "${tasks[@]}"; do queue+=("$f|1"); done

  print "ORCH route: tier=$tier pool=$pool max/backend=$max tasks=${#tasks[@]} time=$(router_peak_label)"

  local jobn=0
  while (( ${#queue[@]} > 0 || ${#JOB_PID[@]} > 0 )); do
    # ---- 1) collect finished lanes ----
    local -a keys=("${(@k)JOB_PID}")
    local jk pid stf rc sec tk spec mdl bk meta out jsonl logf started exh cur prev_att forced note item qt qa tf pb prc
    for jk in "${keys[@]}"; do
      [[ -z "$jk" ]] && continue
      pid=${JOB_PID[$jk]:-}
      [[ -n "$pid" ]] || continue
      stf="$statusdir/${jk}.status"
      # Completion is detected via the status file (kill -0 reported "dead" too early in zsh)
      [[ -f "$stf" ]] || continue
      wait "$pid" 2>/dev/null
      rc=1; sec=0
      [[ -f "$stf" ]] && read -r rc sec < "$stf"
      [[ "$rc" =~ '^[0-9]+$' ]] || rc=1
      tk=${JOB_TASK[$jk]}; spec=${JOB_SPEC[$jk]}; mdl=${JOB_MDL[$jk]}; bk=${JOB_BK[$jk]}
      meta=${JOB_META[$jk]}; out=${JOB_OUT[$jk]}; started=${JOB_START[$jk]}
      jsonl=""; logf=""
      if [[ -f "$meta" ]]; then
        jsonl=$(sed -n 's/^usage_jsonl=//p' "$meta" | head -1)
        logf=$(sed -n 's/^log=//p' "$meta" | head -1)
      fi
      exh=0
      if (( rc != 0 )) && lane_has_quota_marker "$out" "$logf"; then
        exh=1
        router_mark_exhausted "$mdl"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${tk:t:r}" "${JOB_TIER[$jk]}" "$spec" "$bk" "$mdl" "${JOB_ATT[$jk]}" "$rc" "$sec" "$jsonl" "$meta" "$started" "$exh" >> "$att"
      note=""
      (( exh )) && note=" (quota exhausted -> $mdl marked exhausted today)"
      print -r -- "  [done] ${tk:t} -> $bk/$mdl exit=$rc ${sec}s$note"

      cur=${RTR_RUN[$bk]:-0}
      (( cur > 0 )) && RTR_RUN[$bk]=$(( cur - 1 ))
      unset "JOB_PID[$jk]"

      SKIPS[$tk]="${SKIPS[$tk]:-}${SKIPS[$tk]:+,}$spec"
      router_read_header "$tk"
      forced=0
      [[ -n "$RH_BACKEND" || -n "$RH_MODEL" ]] && forced=1
      prev_att=${JOB_ATT[$jk]}
      if (( rc != 0 && !forced && prev_att < 6 )); then
        queue+=("$tk|$(( prev_att + 1 ))")
        print -r -- "  [escalation] ${tk:t}: $spec failed -> next model"
      fi
    done

    # ---- 2) give new work to free backends ----
    local tries=0 progress=1
    local maxtries=${#queue[@]}
    while (( ${#queue[@]} > 0 && progress && tries <= maxtries )); do
      progress=0
      item="${queue[1]}"
      qt="${item%%|*}"; qa="${item##*|}"
      router_read_header "$qt"
      tf="$tier"; [[ -n "$RH_TIER" ]] && tf="$RH_TIER"
      pb="$pool"; [[ -n "$RH_POOL" ]] && pb="$RH_POOL"
      router_pick "$tf" "$pb" "$RH_BACKEND" "$RH_MODEL" "${SKIPS[$qt]:-}"
      prc=$?
      if (( prc == 0 )); then
        shift queue
        jobn=$(( jobn + 1 ))
        jk="j${jobn}"
        out="$out_dir/${qt:t:r}.route${qa}.out"
        meta="$statusdir/${jk}.meta"
        RTR_RUN[$PICK_BACKEND]=$(( ${RTR_RUN[$PICK_BACKEND]:-0} + 1 ))
        router_inc "$PICK_MODEL"
        JOB_TASK[$jk]="$qt"; JOB_SPEC[$jk]="$PICK_SPEC"; JOB_BK[$jk]="$PICK_BACKEND"
        JOB_MDL[$jk]="$PICK_MODEL"; JOB_TIER[$jk]="$tf"; JOB_ATT[$jk]="$qa"
        JOB_START[$jk]="$(date +%s)"; JOB_OUT[$jk]="$out"; JOB_META[$jk]="$meta"
        print -r -- "  [started] ${qt:t} -> $PICK_BACKEND/$PICK_MODEL (attempt $qa)"
        local p_bk="$PICK_BACKEND" p_mdl="$PICK_MODEL" p_tf="$tf" p_qt="$qt" p_out="$out" p_meta="$meta" p_jk="$jk"
        (
          local start end rcx
          trap 'exit 130' INT TERM HUP
          start=$(date +%s)
          ORCH_META="$p_meta" "$LANE" "$p_bk" "$p_tf" "$p_qt" "$p_out" "$workdir" "$p_mdl" &
          local LPID=$!
          wait "$LPID"; rcx=$?
          end=$(date +%s)
          printf '%s %s\n' "$rcx" "$(( end - start ))" > "$statusdir/$p_jk.status.tmp" && mv "$statusdir/$p_jk.status.tmp" "$statusdir/$p_jk.status"
          exit 0
        ) &
        JOB_PID[$jk]=$!
        progress=1
        tries=0
      elif (( prc == 2 )); then
        # backends full: move the task to the end of the queue and try another
        queue+=("$item")
        shift queue
        tries=$(( tries + 1 ))
      else
        shift queue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "${qt:t:r}" "$tf" "-" "-" "-" "$qa" "1" "0" "" "" "$(date +%s)" "0" >> "$att"
        print -r -- "  [failed] ${qt:t} (attempt $qa): $REASON"
      fi
    done

    if (( ${#JOB_PID[@]} > 0 )); then
      sleep 1
    elif (( ${#queue[@]} > 0 )); then
      print -u2 "orchestrate.sh: no route could be picked, queue is waiting - stopping"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${queue[1]%%|*}" "-" "-" "-" "-" "-" "1" "0" "" "" "$(date +%s)" "0" >> "$att"
      break
    fi
  done
  wait 2>/dev/null

  # ---- 3) final table ----
  print ""
  print "TASK                      TRY   MODEL                         BACKEND       EXIT  SEC"
  print -r -- "----                      ---   -----                         -------       ----  ---"
  local -A last
  local -a order
  local a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12
  while IFS=$'\t' read -r a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12; do
    [[ -z "${a1:-}" ]] && continue
    [[ -z "${last[$a1]:-}" ]] && order+=("$a1")
    last[$a1]="$a6|$a5|$a4|$a7|$a8"
  done < "$att"
  local o oval
  for o in "${order[@]}"; do
    oval="${last[$o]}"
    local -a p=("${(@s:|:)oval}")
    printf '%-25s %-5s %-29s %-13s %-5s %s\n' "$o" "${p[1]}" "${p[2]}" "${p[3]}" "${p[4]}" "${p[5]}"
  done

  write_report "$out_dir" "route"
  print ""
  print "ORCH DONE - report: $out_dir/report.md"
}

write_report() {
  local out_dir="$1" mode="$2"
  local att="$out_dir/.orch/attempts.tsv"
  [[ -f "$att" ]] || return 0
  python3 - "$att" "$(router_usage_file)" "$ROUTER_LIMITS" "$(router_exhausted_file)" \
           "$out_dir/report.md" "$(router_today)" "$mode" <<'PY'
import sys, os, json, fnmatch, datetime
from zoneinfo import ZoneInfo

att, usagef, limitsf, exhf, outp, day, mode = sys.argv[1:8]

rows = []
with open(att, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        p = line.rstrip("\n").split("\t")
        if len(p) < 12:
            continue
        rows.append(dict(task=p[0], tier=p[1], spec=p[2], backend=p[3], model=p[4],
                         attempt=p[5], rc=p[6], sec=p[7], jsonl=p[8], meta=p[9],
                         started=p[10], exh=p[11]))

caps = []
if os.path.exists(limitsf):
    for line in open(limitsf, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#") or "|" not in line:
            continue
        pat, cap = line.split("|", 1)
        try:
            caps.append((pat.strip(), int(cap.strip())))
        except ValueError:
            pass

def cap_of(m):
    for pat, c in caps:
        if fnmatch.fnmatchcase(m, pat):
            return c
    return None

usage = {}
if os.path.exists(usagef):
    for line in open(usagef, encoding="utf-8", errors="replace"):
        p = line.rstrip("\n").split("\t")
        if not p or not p[0]:
            continue
        try:
            n = int(p[1])
        except (IndexError, ValueError):
            n = 1
        usage[p[0]] = usage.get(p[0], 0) + n

exhausted = []
if os.path.exists(exhf):
    exhausted = [l.strip() for l in open(exhf, encoding="utf-8", errors="replace") if l.strip()]

# Example prices per 1M tokens, off-peak: (cache hit, cache miss, output). Doubled during peak. Edit to match your provider.
PRICES = {"ds-model-fast": (0.1, 1.0, 2.0), "ds-model-pro": (0.5, 5.0, 10.0)}

def tokens(path):
    if not path or not os.path.exists(path):
        return None
    total = None
    acc = [0, 0, 0]
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return None
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                j = json.loads(line)
            except Exception:
                continue
            u = j.get("usage")
            if not isinstance(u, dict):
                continue
            got = (int(u.get("input_tokens") or 0),
                   int(u.get("cache_read_input_tokens") or 0),
                   int(u.get("output_tokens") or 0))
            if j.get("type") == "result":
                total = got
            else:
                acc[0] += got[0]; acc[1] += got[1]; acc[2] += got[2]
    return total if total else tuple(acc)

def is_peak(epoch):
    try:
        ep = float(epoch)
    except (TypeError, ValueError):
        return False
    dt = datetime.datetime.fromtimestamp(ep, ZoneInfo(os.environ.get("PEAK_TZ", "UTC")))
    return dt.weekday() <= 4 and ((9 <= dt.hour < 12) or (14 <= dt.hour < 18))

order, groups = [], {}
for r in rows:
    t = r["task"]
    if t not in groups:
        groups[t] = []
        order.append(t)
    groups[t].append(r)

ok = sum(1 for t in order if groups[t][-1]["rc"] == "0")

L = []
A = L.append
A("# Orchestrator report - %s" % day)
A("")
A("- Mode: **%s**" % mode)
A("- Tasks: **%d**, succeeded: **%d**" % (len(order), ok))
A("- Peak hours are computed in the PEAK_TZ time zone (Mon-Fri 09-12, 14-18).")
A("")
A("## Tasks")
A("")
A("| Task | Tier | Final model | Attempts (chain) | Escalations | Seconds | Exit |")
A("|---|---|---|---|---|---|---|")
for t in order:
    g = groups[t]
    last = g[-1]
    chain = " → ".join(x["model"] if x["model"] != "-" else "—" for x in g)
    A("| %s | %s | %s | %s | %d | %s | %s |" % (t, last["tier"], last["model"], chain, max(0, len(g) - 1), last["sec"], last["rc"]))
A("")

A("## DeepSeek tokens and estimated cost")
A("")
A("| Task | Model | input | cache_read | output | Peak | Cost |")
A("|---|---|---|---|---|---|---|")
total_cost = 0.0
antigrav = 0
for t in order:
    for r in groups[t]:
        if r["backend"] == "antigravity":
            antigrav += 1
        if r["backend"] != "deepseek":
            continue
        m = r["model"]
        pk = "peak" if is_peak(r["started"]) else "off-peak"
        tk = tokens(r["jsonl"])
        if tk is None:
            A("| %s | %s | — | — | — | %s | — |" % (t, m, pk))
            continue
        inp, cr, out = tk
        base = PRICES.get(m.split('%')[0])
        if not base:
            A("| %s | %s | %d | %d | %d | %s | ? |" % (t, m, inp, cr, out, pk))
            continue
        hit, miss, orate = base
        mult = 2.0 if (r["started"] and is_peak(r["started"])) else 1.0
        cost = (cr * hit + inp * miss + out * orate) / 1000000.0 * mult
        total_cost += cost
        A("| %s | %s | %d | %d | %d | %s | %.4f |" % (t, m, inp, cr, out, pk, cost))
A("")
A("Total estimated DeepSeek cost: **%.4f**" % total_cost)
A("")
A("Antigravity attempts: %d (run on a daily quota, no per-token cost)." % antigrav)
A("")

A("## Today's usage (against limits)")
A("")
A("| Model | Usage | Limit | Status |")
A("|---|---|---|---|")
models = set(usage.keys())
for pat, c in caps:
    if "*" not in pat and "?" not in pat:
        models.add(pat)
    else:
        for m in usage:
            if fnmatch.fnmatchcase(m, pat):
                models.add(m)
for m in sorted(models):
    u = usage.get(m, 0)
    c = cap_of(m)
    if m in exhausted:
        st = "EXHAUSTED (today)"
    elif c is not None and u >= c:
        st = "limit reached"
    else:
        st = "available"
    A("| %s | %d | %s | %s |" % (m, u, c if c is not None else "—", st))
A("")
if exhausted:
    A("Exhausted models: %s" % ", ".join(exhausted))
else:
    A("No exhausted models.")
A("")

with open(outp, "w", encoding="utf-8") as fh:
    fh.write("\n".join(L))
PY
}

cmd_route_plan() {
  local tasks_dir="" pool="any" deftier="medium"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pool) [[ $# -ge 2 ]] || die "--pool requires a value"; pool="$2"; shift 2 ;;
      --tier) [[ $# -ge 2 ]] || die "--tier requires a value"; deftier="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      -*) die "unknown flag: $1" ;;
      *) tasks_dir="$1"; shift ;;
    esac
  done
  [[ -n "$tasks_dir" ]] || { usage >&2; die "route-plan <tasks-dir> is required"; }
  [[ -d "$tasks_dir" ]] || die "tasks-dir not found: $tasks_dir"
  case "$pool" in free|any) ;; *) die "--pool must be free|any (got: $pool)" ;; esac
  case "$deftier" in light|medium|strong|critical) ;; *) die "--tier must be light|medium|strong|critical" ;; esac
  tasks_dir="${tasks_dir:A}"

  local -a tasks=()
  local f
  for f in "$tasks_dir"/*.txt(N) "$tasks_dir"/*.md(N); do tasks+=("$f"); done
  [[ ${#tasks[@]} -gt 0 ]] || die "no *.txt / *.md found in tasks-dir: $tasks_dir"

  print "ROUTE PLAN — $(router_today) ($(router_peak_label), $ROUTER_PEAK_TZ) | pool=$pool | default tier=$deftier"
  print "Usage file: $(router_usage_file)"
  print ""
  local tf pb prc
  for f in "${tasks[@]}"; do
    router_read_header "$f"
    tf="$deftier"; [[ -n "$RH_TIER" ]] && tf="$RH_TIER"
    pb="$pool"; [[ -n "$RH_POOL" ]] && pb="$RH_POOL"
    router_pick "$tf" "$pb" "$RH_BACKEND" "$RH_MODEL" ""
    prc=$?
    if (( prc == 0 )); then
      print -r -- "OK   ${f:t:r}  tier=$tf${RH_BACKEND:+  backend=$RH_BACKEND}${RH_MODEL:+  model=$RH_MODEL}  ->  ${PICK_BACKEND} / ${PICK_MODEL}"
      [[ -n "$PICK_NOTE" ]] && print -r -- "     skipped: $PICK_NOTE"
    else
      print -r -- "FAIL ${f:t:r}  tier=$tf  ->  no model picked (code $prc)"
      print -r -- "     reason: $REASON"
    fi
  done
  print ""
  print "Note: the plan is read-only - it does not change the usage counters."
}

cmd_usage() {
  local day f
  day=$(router_today)
  f=$(router_usage_file)
  print "USAGE - $day ($ROUTER_PEAK_TZ day) | time: $(router_peak_label)"
  print "File: $f"
  print ""
  printf '%-28s %8s %8s  %s\n' "MODEL" "USAGE" "LIMIT" "STATUS"
  printf '%-28s %8s %8s  %s\n' "-----" "--------" "-----" "---------"

  local -A seen
  local -a models
  local m n
  if [[ -f "$f" ]]; then
    while IFS=$'\t' read -r m n; do
      [[ -z "$m" ]] && continue
      seen[$m]=1
    done < "$f"
  fi
  local line pat cap
  if [[ -f "$ROUTER_LIMITS" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      pat="${line%%|*}"
      [[ "$pat" == *'*'* || "$pat" == *'?'* ]] && continue
      seen[$pat]=1
    done < "$ROUTER_LIMITS"
  fi
  models=("${(@ok)seen}")
  for m in "${models[@]}"; do
    n=$(router_count "$m")
    cap="—"
    if cap=$(router_cap "$m"); then :; else cap="—"; fi
    local st="available"
    if router_is_exhausted "$m"; then
      st="EXHAUSTED"
    elif [[ "$cap" != "—" ]] && (( n >= cap )); then
      st="limit reached"
    fi
    printf '%-28s %8s %8s  %s\n' "$m" "$n" "$cap" "$st"
  done
  print ""
  local ef
  ef=$(router_exhausted_file)
  if [[ -f "$ef" ]] && [[ -s "$ef" ]]; then
    local ex
    ex=$(tr '\n' '|' < "$ef" | sed 's/|$//; s/|/, /g')
    print "Exhausted (today): $ex"
  else
    print "Exhausted (today): none"
  fi
}

cmd_run() {
  [[ $# -ge 2 ]] || { usage >&2; die "tasks-dir and out-dir are required"; }
  local tasks_dir="$1" out_dir="$2"; shift 2
  local mode=split tier=light workdir="${ORCH_WORK_ROOT:-$HOME/orch-work}" max=3 pool=any
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)    [[ $# -ge 2 ]] || die "--mode requires a value"; mode="$2"; shift 2 ;;
      --tier)    [[ $# -ge 2 ]] || die "--tier requires a value"; tier="$2"; shift 2 ;;
      --pool)    [[ $# -ge 2 ]] || die "--pool requires a value"; pool="$2"; shift 2 ;;
      --workdir) [[ $# -ge 2 ]] || die "--workdir requires a value"; workdir="$2"; shift 2 ;;
      --max)     [[ $# -ge 2 ]] || die "--max requires a value"; max="$2"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  case "$mode" in split|dual|tri|route) ;; *) die "--mode must be split|dual|tri|route (got: $mode)" ;; esac
  if [[ "$mode" == route ]]; then
    case "$tier" in light|medium|strong|critical) ;; *) die "--tier must be light|medium|strong|critical (got: $tier)" ;; esac
  else
    case "$tier" in light|strong) ;; *) die "--tier must be light|strong (got: $tier)" ;; esac
  fi
  case "$pool" in free|any) ;; *) die "--pool must be free|any (got: $pool)" ;; esac
  [[ "$max" =~ '^[0-9]+$' && "$max" -ge 1 ]] || die "--max must be a positive integer (got: $max)"
  [[ -f "$CONF" ]] || die "backends.conf not found: $CONF"
  [[ -d "$tasks_dir" ]] || die "tasks-dir not found: $tasks_dir"
  [[ -d "$workdir" ]] || die "workdir not found: $workdir"
  tasks_dir="${tasks_dir:A}"; out_dir="${out_dir:A}"; workdir="${workdir:A}"

  if [[ "$mode" == route ]]; then
    run_route "$tasks_dir" "$out_dir" "$tier" "$workdir" "$max" "$pool"
    return $?
  fi

  local -a tasks=()
  local f
  for f in "$tasks_dir"/*.txt(N) "$tasks_dir"/*.md(N); do tasks+=("$f"); done
  [[ ${#tasks[@]} -gt 0 ]] || die "no *.txt / *.md found in tasks-dir: $tasks_dir"

  local -a names
  names=($(enabled_names))
  [[ ${#names[@]} -gt 0 ]] || die "no enabled backend (see: $CONF; enable one with orchestrate.sh enable)"

  local -a use=()
  if [[ "$mode" == dual || "$mode" == tri ]]; then
    local need=2; [[ "$mode" == tri ]] && need=3
    if (( ${#names[@]} < need )); then
      if [[ "$mode" == tri ]]; then
        die "tri mode needs 3 enabled backends; only ${#names[@]} enabled: ${names[*]}. Add a third API: orchestrate.sh add-api <name> <kind anthropic|openai> <base_url> <model_light> <model_strong>"
      else
        die "dual mode needs 2 enabled backends; only ${#names[@]} enabled: ${names[*]}."
      fi
    fi
    use=("${names[@]:0:$need}")
  fi

  local -a JOBS=()
  local i=0
  for f in $tasks; do
    local name="${f:t:r}"
    if [[ "$mode" == split ]]; then
      local l1 l2
      l1="$(head -1 "$f" 2>/dev/null)"
      l2="$(sed -n '2p' "$f" 2>/dev/null)"
      local bk="" tf="$tier" L
      for L in "$l1" "$l2"; do
        if [[ "$L" == \#backend:* ]]; then read -r bk <<< "${L#\#backend:}"; fi
        if [[ "$L" == \#tier:* ]];    then read -r tf <<< "${L#\#tier:}";    fi
      done
      [[ "$tf" == light || "$tf" == strong ]] || tf="$tier"
      if [[ -z "$bk" ]]; then
        bk="${names[$(( i % ${#names[@]} + 1 ))]}"
        i=$((i+1))
      else
        local ok=0 b
        for b in $names; do [[ "$b" == "$bk" ]] && ok=1; done
        (( ok )) || die "task \"$name\" requests a backend that is not enabled: $bk (enabled: ${names[*]})"
      fi
      JOBS+=("$f|$bk|$tf|$out_dir/${name}.out|${name}__${bk}")
    else
      local bk
      for bk in $use; do
        JOBS+=("$f|$bk|$tier|$out_dir/${name}.${bk}.out|${name}__${bk}")
      done
    fi
  done

  if [[ $DRY -eq 1 ]]; then
    print "# ORCH dry-run — mode=$mode tier=$tier max=$max"
    print "# workdir: $workdir"
    print "# out-dir: $out_dir"
    print "# ${#JOBS[@]} lanes (nothing is executed):"
    local j
    for j in $JOBS; do
      local -a p=("${(@s:|:)j}")
      print "$LANE ${(q)p[2]} ${(q)p[3]} ${(q)p[1]} ${(q)p[4]} ${(q)workdir}"
    done
    print "ORCH DRY-RUN DONE"
    return 0
  fi

  local statusdir="$out_dir/.orch"
  mkdir -p "$out_dir" "$statusdir" || die "could not create out-dir: $out_dir"

  print "ORCH: mode=$mode tier=$tier max=$max tasks=${#tasks[@]} backends=${names[*]}"

  launch_job() {
    local j="$1"
    local -a p=("${(@s:|:)j}")
    local task="$p[1]" bk="$p[2]" tf="$p[3]" out="$p[4]" key="$p[5]"
    print "  [started] ${bk} <- ${task:t}"
    (
      local LPID="" start end rc
      trap '[[ -n "$LPID" ]] && kill -TERM "$LPID" 2>/dev/null; exit 130' INT TERM HUP
      start=$(date +%s)
      "$LANE" "$bk" "$tf" "$task" "$out" "$workdir" &
      LPID=$!
      wait "$LPID"
      rc=$?
      end=$(date +%s)
      printf '%s %s\n' "$rc" "$((end-start))" > "$statusdir/${key}.status"
      exit 0
    ) &
  }

  local -a running=()
  for j in $JOBS; do
    while (( ${#running[@]} >= max )); do
      local -a still=()
      local k
      for k in $running; do
        [[ -f "$statusdir/${k}.status" ]] || still+=("$k")
      done
      running=("${still[@]}")
      (( ${#running[@]} >= max )) && sleep 1
    done
    launch_job "$j"
    running+=("${j##*|}")
  done
  wait 2>/dev/null

  if [[ "$mode" == dual || "$mode" == tri ]]; then
    build_compare
  fi

  print ""
  print "TASK          BACKEND       EXIT  SEC   OUT"
  print -r -- "----          -------       ----  ---   ---"
  for j in $JOBS; do
    local -a p=("${(@s:|:)j}")
    local name="${p[1]:t:r}" bk="$p[2]" out="$p[4]" key="$p[5]"
    local rc="-" sec="-"
    if [[ -f "$statusdir/${key}.status" ]]; then
      read -r rc sec < "$statusdir/${key}.status"
    fi
    printf '%-13s %-13s %-5s %-5s %s\n' "$name" "$bk" "$rc" "$sec" "$out"
  done
  print ""
  print "ORCH DONE"
}

trap 'pkill -P $$ 2>/dev/null; exit 130' INT TERM HUP

if [[ "${1:-}" == "--dry-run" ]]; then DRY=1; shift; fi
cmd="${1:-}"; [[ -n "$cmd" ]] && shift
case "$cmd" in
  run)        cmd_run "$@" ;;
  route-plan) cmd_route_plan "$@" ;;
  usage)      cmd_usage ;;
  add-api)    cmd_addapi "$@" ;;
  list)       cmd_list ;;
  enable)     cmd_enable on "$@" ;;
  disable)    cmd_enable off "$@" ;;
  ""|-h|--help|help) usage; exit 0 ;;
  *) print -u2 "orchestrate.sh: unknown command: $cmd"; usage >&2; exit 2 ;;
esac
