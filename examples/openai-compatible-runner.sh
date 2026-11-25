#!/bin/sh
# Example runner for the `deepseek`-kind backend: talks to any OpenAI-compatible /chat/completions API.
# Called by lane.sh as:  runner <prompt-file> <out-file> <model> <workdir>
#
# Environment:
#   DEEPSEEK_API_KEY   API key (required unless LLM_MOCK=1)
#   LLM_BASE_URL       default https://api.deepseek.com/v1
#   LLM_MODEL          overrides the model name sent to the API (the config model names are aliases)
#   DS_EFFORT          set by lane.sh from "model%effort"; sent as reasoning_effort when present
#   DEEPSEEK_LOG_DIR   where the token-usage .jsonl is written (default: <repo>/deepseek-logs)
#   LLM_MOCK=1         no network: writes a canned answer and fake token usage (for demos and CI)
set -u
prompt_file="${1:?prompt-file}"; out_file="${2:?out-file}"; model="${3:?model}"; workdir="${4:-.}"
here=$(cd "$(dirname "$0")/.." && pwd)
logdir="${DEEPSEEK_LOG_DIR:-$here/deepseek-logs}"
name=$(basename "$out_file"); name="${name%.*}"
mkdir -p "$logdir"
usage_log="$logdir/$(date +%Y%m%d-%H%M%S)_${name}_${model}.jsonl"

if [ "${LLM_MOCK:-0}" = "1" ]; then
  echo "(mock answer for task $name from model $model)" > "$out_file"
  echo '{"type":"result","usage":{"input_tokens":120,"cache_read_input_tokens":40,"output_tokens":60}}' > "$usage_log"
  exit 0
fi

[ -n "${DEEPSEEK_API_KEY:-}" ] || { echo "(runner: DEEPSEEK_API_KEY is not set)" > "$out_file"; exit 2; }
url="${LLM_BASE_URL:-https://api.deepseek.com/v1}"; url="${url%/}/chat/completions"
body=$(mktemp) || exit 2; resp=$(mktemp) || exit 2
trap 'rm -f "$body" "$resp"' EXIT

python3 - "$prompt_file" "${LLM_MODEL:-$model}" "${DS_EFFORT:-}" > "$body" <<'PY'
import json, sys
d = {"model": sys.argv[2], "messages": [{"role": "user", "content": open(sys.argv[1], encoding="utf-8").read()}]}
if sys.argv[3]:
    d["reasoning_effort"] = sys.argv[3]
print(json.dumps(d))
PY

# The key goes to curl through stdin config so it never shows in the process list.
http=$(printf 'header = "Authorization: Bearer %s"\n' "$DEEPSEEK_API_KEY" | \
  curl -sS --config - "$url" -H "Content-Type: application/json" -d @"$body" -o "$resp" -w '%{http_code}') \
  || { echo "(runner: curl failed)" > "$out_file"; exit 3; }

python3 - "$resp" "$http" "$out_file" "$usage_log" <<'PY'
import json, sys
resp, http, out, log = sys.argv[1:5]
raw = open(resp, encoding="utf-8", errors="replace").read()
try:
    d = json.loads(raw)
    text = d["choices"][0]["message"]["content"] or "(empty response)"
except Exception:
    open(out, "w").write("(runner: HTTP %s: %s)\n" % (http, raw[:300].replace("\n", " ")))
    raise SystemExit(1)
open(out, "w").write(text + "\n")
u = d.get("usage") or {}
open(log, "w").write(json.dumps({"type": "result", "usage": {
    "input_tokens": u.get("prompt_cache_miss_tokens", u.get("prompt_tokens", 0)),
    "cache_read_input_tokens": u.get("prompt_cache_hit_tokens", 0),
    "output_tokens": u.get("completion_tokens", 0)}}) + "\n")
PY
