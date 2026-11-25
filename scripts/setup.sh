#!/usr/bin/env bash
# One-command setup and self-test for the orchestrator. Idempotent: safe to run repeatedly.
# The end-to-end check runs on a temporary copy with the mock runner, so your config files,
# usage counters and API keys are never touched and no network is used.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for tool in zsh python3 curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is required but not installed" >&2; exit 1; }
done
echo "zsh $(zsh --version | cut -d' ' -f2), $(python3 -V), curl $(curl --version | head -n1 | cut -d' ' -f2) ok"

chmod +x orchestrate.sh lane.sh examples/openai-compatible-runner.sh scripts/*.sh

if [ ! -f .env ]; then
  cp .env.example .env
  echo "created .env from .env.example (add your keys there)"
fi
mkdir -p work

for f in orchestrate.sh lane.sh router.sh; do zsh -n "$f"; done
sh -n examples/openai-compatible-runner.sh
echo "syntax check passed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R orchestrate.sh lane.sh router.sh backends.conf routes.conf limits.conf examples test-tasks "$tmp/"
(
  cd "$tmp"
  export ORCH_USAGE_DIR="$tmp/usage" LLM_MOCK=1
  ./orchestrate.sh list
  ./orchestrate.sh route-plan test-tasks
  rm test-tasks/t3.txt             # t3 pins the antigravity backend, which may not be installed
  ./orchestrate.sh disable antigravity
  mkdir work
  ./orchestrate.sh run test-tasks out --mode route --tier light --workdir work
  grep -q 'Tasks: \*\*2\*\*, succeeded: \*\*2\*\*' out/report.md
)
echo "end-to-end mock run passed"

cat <<'MSG'

Setup complete. Next:
  1. Put your API key(s) in .env, then: set -a; . ./.env; set +a
  2. ./orchestrate.sh list
  3. ./orchestrate.sh route-plan test-tasks
See AI_SETUP.md for the full walkthrough.
MSG
