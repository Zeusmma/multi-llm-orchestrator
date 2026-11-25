#!/bin/zsh
# lane.sh - runs one task on one backend.
# Usage: lane.sh <backend> <tier> <prompt-file> <out-file> <workdir> [model]
#   If a model is given, no tier-based selection happens (route mode works this way).
#   A <log>.meta file is written at the end (model, log path, DeepSeek token file) for the report.
# The result is written to <out-file> as plain text; the last line is always "exit <code>".
# Log: <orchestrator dir>/logs/<timestamp>_<backend>_<name>.log
# API keys are never printed or logged; they are read from environment variables at runtime.
set -u
setopt TYPESET_SILENT   # macOS zsh 5.9 defaults to OFF: bare `local` in a loop would print values to stdout

ORCH_DIR="${0:A:h}"
CONF="$ORCH_DIR/backends.conf"
DEEPSEEK_AGENT="${DEEPSEEK_AGENT:-$ORCH_DIR/examples/openai-compatible-runner.sh}"   # default: bundled example runner; set DEEPSEEK_AGENT to use your own
AGY="${AGY_BIN:-$HOME/.local/bin/agy}"
PREFIX_FILE="${ORCH_PREFIX_FILE:-$ORCH_DIR/prefix.txt}"   # optional text prepended to every prompt (e.g. a terse-output rule)
WORK_ROOT="${ORCH_WORK_ROOT:-$HOME/orch-work}"   # only here may the permission-skip retry run

backend="${1:?backend is required}"; tier="${2:?tier is required}"
prompt_file="${3:?prompt-file is required}"; out_file="${4:?out-file is required}"; workdir="${5:?workdir is required}"
model_override="${6:-}"   # route mode passes the model explicitly; if empty it is chosen by tier
prompt_file="${prompt_file:A}"; out_file="${out_file:A}"; workdir="${workdir:A}"

die() { print -u2 "lane.sh: $*"; exit 2; }
[[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"
[[ -d "$workdir" ]] || die "workdir not found: $workdir"
[[ -f "$CONF" ]] || die "backends.conf not found: $CONF"
mkdir -p "$ORCH_DIR/logs" "${out_file:h}" || die "could not create log/out directory"

# load the backend entry from backends.conf
NAME= KIND= MLIGHT= MSTRONG= EXTRA= ENABLED=
load_backend() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    local -a f=("${(@s:|:)line}")
    [[ "${f[1]}" == "$backend" ]] || continue
    NAME="${f[1]}"; KIND="${f[2]}"; MLIGHT="${f[3]}"; MSTRONG="${f[4]}"; EXTRA="${f[5]}"; ENABLED="${f[6]:-on}"
    return 0
  done < "$CONF"
  return 1
}
load_backend || die "backend not found: $backend (see: $CONF)"

if [[ -n "$model_override" ]]; then
  model="$model_override"
  # "model%effort" (DeepSeek): the effort is split off and passed as DS_EFFORT
  if [[ "$model" == *%* ]]; then export DS_EFFORT="${model#*%}"; model="${model%%\%*}"; fi
else
  case "$tier" in
    light)  model="$MLIGHT" ;;
    strong) model="$MSTRONG" ;;
    *) die "tier must be light|strong, got: $tier (no explicit model given)" ;;
  esac
fi

name="${out_file:t:r}"
stamp=$(date +%Y%m%d-%H%M%S)
START_EPOCH=$(date +%s)
LOG="$ORCH_DIR/logs/${stamp}_${backend}_${name}.log"
: > "$LOG"
DS_JSONL=""   # deepseek stream-json log (for the token report)

AGY_PIDFILE=""
cleanup() {
  [[ -n "$AGY_PIDFILE" && -f "$AGY_PIDFILE" ]] && kill -TERM "$(cat "$AGY_PIDFILE" 2>/dev/null)" 2>/dev/null
  pkill -P $$ 2>/dev/null
}
trap 'cleanup; exit 130' INT TERM HUP

# api_key <backend>: prints the value of env var ORCH_<BACKEND>_API_KEY; fails if it is empty
api_key() { local v="ORCH_${${(U)1}//[^A-Z0-9]/_}_API_KEY"; [[ -n "${(P)v:-}" ]] && print -r -- "${(P)v}"; }

run_deepseek() {
  # For the token report: the DeepSeek runner writes its own stream-json log under a log dir.
  # We drop a marker before the run and afterwards pick only the newly created .jsonl file.
  local dsdir="${DEEPSEEK_LOG_DIR:-$ORCH_DIR/deepseek-logs}"
  local marker="$ORCH_DIR/logs/.dsmark-${stamp}-$$"
  : > "$marker" 2>/dev/null || marker=""
  "$DEEPSEEK_AGENT" "$prompt_file" "$out_file" "$model" "$workdir" >> "$LOG" 2>&1
  local script_rc
  script_rc=$?
  if [[ -n "$marker" && -d "$dsdir" ]]; then
    local -a cands
    cands=("${(@f)$(find "$dsdir" -type f -name "*_${name}_${model}.jsonl" -newer "$marker" -print 2>/dev/null)}")
    cands=("${(@)cands:#}")
    (( ${#cands[@]} > 0 )) && DS_JSONL="${cands[-1]}"
    rm -f "$marker"
  fi
  local code=$script_rc
  if [[ -s "$out_file" ]] && tail -1 "$out_file" | grep -qE '^exit [0-9]+$'; then
    code=$(tail -1 "$out_file" | sed -E 's/^exit ([0-9]+)$/\1/')
    [[ "$code" =~ '^[0-9]+$' ]] || code=$script_rc
    sed -i.bak -e '$d' "$out_file" && rm -f "$out_file.bak"   # the runner's own "exit" line (macOS + GNU sed)
  fi
  return $code
}

AGY_EXTRA_ARGS=()   # after a permission error: --dangerously-skip-permissions

run_antigravity() {
  local timeout="${EXTRA:-600}"
  [[ "$timeout" =~ '^[0-9]+$' ]] || timeout=600
  local poll_to=$(( timeout + 300 ))
  local wrapper="$ORCH_DIR/logs/${stamp}_${backend}_${name}.sh"
  AGY_PIDFILE="$ORCH_DIR/logs/${stamp}_${backend}_${name}.pid"
  local extra=""
  (( ${#AGY_EXTRA_ARGS[@]} )) && extra="${(j: :)AGY_EXTRA_ARGS}"
  # wrapper: runs agy in a visible terminal window, tees to the log, writes a DONE marker at the end.
  cat > "$wrapper" <<EOF
#!/bin/zsh
set -u
echo \$\$ > "$AGY_PIDFILE"
trap 'pkill -P \$\$ 2>/dev/null; exit 130' INT TERM HUP
PROMPT="\$(cat "$PREFIX_FILE" 2>/dev/null; echo; cat "$prompt_file")"
"$AGY" -p "\$PROMPT" --model "$model" --mode accept-edits $extra --add-dir "$workdir" --print-timeout ${timeout}s 2>&1 | tee -a "$LOG"
code=\${pipestatus[1]}
echo "== DONE exit \$code ==" >> "$LOG"
EOF
  local esc
  esc=$(printf '%s' "$wrapper" | sed 's/\\/\\\\/g; s/"/\\"/g')
  if [[ "$OSTYPE" == linux* ]]; then
    # Linux: no Terminal.app. Use a visible xfce4-terminal on an open desktop session if there is one,
    # otherwise run in the background (the DONE marker below works the same).
    local disp=""
    for x in /tmp/.X11-unix/X*(N); do n=${x##*/X}
      pgrep -u "$USER" -f "Xorg :$n " >/dev/null && { disp=":$n"; break; }; done
    if [[ -n "$disp" ]] && command -v xfce4-terminal >/dev/null; then
      DISPLAY=$disp setsid xfce4-terminal --title "orch: $name" -e "zsh $wrapper" >/dev/null 2>&1 &
      for _w in {1..10}; do [[ -s "$AGY_PIDFILE" ]] && break; sleep 1; done
      [[ -s "$AGY_PIDFILE" ]] || setsid zsh "$wrapper" >/dev/null 2>&1 < /dev/null &   # terminal did not open: run in the background
    else
      setsid zsh "$wrapper" >/dev/null 2>&1 < /dev/null &
    fi
  elif ! osascript -e "tell application \"Terminal\" to do script \"zsh $esc\"" >/dev/null 2>&1; then
    print "(antigravity: could not open a Terminal window)" > "$out_file"
    return 2
  fi
  # Check for the DONE marker every 3 seconds (until the deadline).
  local deadline=$(( $(date +%s) + poll_to ))
  while (( $(date +%s) < deadline )); do
    grep -qE '^== DONE exit [0-9]+ ==$' "$LOG" 2>/dev/null && break
    sleep 3
  done
  if grep -qE '^== DONE exit [0-9]+ ==$' "$LOG" 2>/dev/null; then
    local code
    code=$(grep -m1 -E '^== DONE exit [0-9]+ ==$' "$LOG" | sed -E 's/^== DONE exit ([0-9]+) ==$/\1/')
    [[ "$code" =~ '^[0-9]+$' ]] || code=1
    awk '/^== DONE exit /{exit} {print}' "$LOG" > "$out_file"
    return $code
  else
    print "(antigravity: DONE marker did not appear within ${poll_to}s; log: $LOG)" > "$out_file"
    return 124
  fi
}

# Antigravity: "permission that headless mode cannot prompt for" -> retry ONCE with --dangerously-skip-permissions,
# only if workdir is under $WORK_ROOT; otherwise a clear error.
run_antigravity_checked() {
  run_antigravity
  local rc=$?
  grep -qiE 'permission that headless mode cannot prompt' "$LOG" "$out_file" 2>/dev/null || return $rc
  case "$workdir" in
    "$WORK_ROOT"|"$WORK_ROOT/"*)
      print "== retry: --dangerously-skip-permissions (allowed workdir) ==" >> "$LOG"
      mv "$LOG" "${LOG}.try1" 2>/dev/null
      : > "$LOG"
      AGY_EXTRA_ARGS=(--dangerously-skip-permissions)
      run_antigravity
      return $?
      ;;
    *)
      print "(antigravity: a tool permission is required but headless mode cannot prompt for it. --dangerously-skip-permissions is only used under $WORK_ROOT; workdir: $workdir)" > "$out_file"
      return 3
      ;;
  esac
}

run_anthropic() {
  local base_url="${EXTRA:-}"
  [[ -n "$base_url" ]] || { print "(anthropic: base_url (extra) is empty - check backends.conf)" > "$out_file"; return 2; }
  local k
  k=$(api_key "$backend") || { print "(anthropic: API key env var is not set - ORCH_<NAME>_API_KEY for backend $backend)" > "$out_file"; return 2; }
  ANTHROPIC_BASE_URL="$base_url" \
  ANTHROPIC_AUTH_TOKEN="$k" ANTHROPIC_API_KEY= \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$MSTRONG" ANTHROPIC_DEFAULT_SONNET_MODEL="$MSTRONG" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$MLIGHT" CLAUDE_CODE_SUBAGENT_MODEL="$model" \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS="${LANE_MAX_OUT:-64000}" MAX_THINKING_TOKENS="${LANE_THINK:-16000}" \
  claude -p "$(cat "$prompt_file")" --model "$model" \
    --append-system-prompt "$(cat "$PREFIX_FILE" 2>/dev/null)" \
    --output-format stream-json --verbose \
    --allowedTools "${LANE_TOOLS:-Bash Read Grep Glob Write}" \
    --disallowedTools "Bash(rm:*)" "Bash(rmdir:*)" "Bash(git clean:*)" "Bash(git checkout:*)" "Bash(find:*-delete*)" \
    --add-dir /tmp --add-dir "$workdir" >> "$LOG" 2>&1
  local rc
  rc=$?
  python3 - "$LOG" > "$out_file" <<'PY'
import json, sys
res = None
for l in open(sys.argv[1], errors="replace"):
    try: j = json.loads(l)
    except Exception: continue
    if j.get("type") == "result": res = j.get("result")
print(res if res else "(no final result; see log " + sys.argv[1] + ")")
PY
  return $rc
}

run_openai() {
  local base_url="${EXTRA:-}"
  [[ -n "$base_url" ]] || { print "(openai: base_url (extra) is empty - check backends.conf)" > "$out_file"; return 2; }
  local url
  if [[ "$base_url" == */chat/completions ]]; then url="$base_url"; else url="${base_url%/}/chat/completions"; fi
  local k
  k=$(api_key "$backend") || { print "(openai: API key env var is not set - ORCH_<NAME>_API_KEY for backend $backend)" > "$out_file"; return 2; }
  local body resp
  body=$(mktemp "${TMPDIR:-/tmp}/orch-req.XXXXXX") || { print "(openai: could not create temp file)" > "$out_file"; return 2; }
  resp=$(mktemp "${TMPDIR:-/tmp}/orch-resp.XXXXXX") || { rm -f "$body"; print "(openai: could not create temp file)" > "$out_file"; return 2; }
  python3 - "$prompt_file" "$model" "$PREFIX_FILE" > "$body" <<'PY'
import json, sys, os
prompt = open(sys.argv[1], encoding="utf-8").read()
cav = open(sys.argv[3], encoding="utf-8").read() if os.path.exists(sys.argv[3]) else ""
msgs = ([{"role": "system", "content": cav}] if cav else []) + [{"role": "user", "content": prompt}]
print(json.dumps({"model": sys.argv[2], "messages": msgs}))
PY
  local rc
  # The key must not reach the command line or the log: the Authorization header is passed to curl as stdin config.
  local kq
  kq=$(printf '%s' "$k" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf 'header = "Authorization: Bearer %s"\n' "$kq" | \
    curl -sS --config - "$url" -H "Content-Type: application/json" -d @"$body" -o "$resp" >> "$LOG" 2>&1
  rc=$?
  rm -f "$body"
  if [[ $rc -eq 0 ]]; then
    python3 - "$resp" > "$out_file" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("(openai: could not parse response JSON: %s)" % e); raise SystemExit(3)
if "error" in d and isinstance(d.get("error"), dict):
    print("(openai error: %s)" % d["error"].get("message", json.dumps(d["error"]))); raise SystemExit(1)
c = d.get("choices") or []
if c and isinstance(c[0].get("message"), dict):
    print(c[0]["message"].get("content") or "(empty response)")
else:
    print("(openai: unexpected response structure)")
PY
    rc=$?
  else
    print "(openai: curl error - see: $LOG)" > "$out_file"
  fi
  rm -f "$resp"
  return $rc
}

rc=0
case "$KIND" in
  deepseek)    run_deepseek;    rc=$? ;;
  antigravity) run_antigravity_checked; rc=$? ;;
  anthropic)   run_anthropic;   rc=$? ;;
  openai)      run_openai;      rc=$? ;;
  *) die "unknown kind: $KIND (backend: $backend)" ;;
esac

[[ -s "$out_file" ]] || print "(empty result; log: $LOG)" > "$out_file"
printf 'exit %s\n' "$rc" >> "$out_file"

# Meta: model, log path and DeepSeek token file for the dispatcher (orchestrate.sh route / report).
META="${ORCH_META:-${LOG%.log}.meta}"
mkdir -p "${META:h}" 2>/dev/null
{
  print -r -- "backend=$backend"
  print -r -- "model=$model"
  print -r -- "tier=$tier"
  print -r -- "started=$START_EPOCH"
  print -r -- "ended=$(date +%s)"
  print -r -- "usage_jsonl=${DS_JSONL:-}"
  print -r -- "log=$LOG"
  print -r -- "out=$out_file"
  print -r -- "exit=$rc"
} > "$META" 2>/dev/null || true

exit $rc
