# Set up with an AI assistant

Give the prompt below to your AI coding assistant (Claude Code, Cursor, Copilot Chat, or similar) from inside a checkout of this repository. It verifies the toolkit offline with a mock runner first, then helps you connect a real backend.

## Copy-paste prompt

```text
You are installing the project in the current directory (Multi-LLM Orchestrator, a zsh toolkit).

Rules:
- Read README.md and AI_SETUP.md first.
- Never invent API keys or endpoints. Ask me which backend I want and for its key. Put keys only
  in .env (git-ignored) and never print them or commit them.
- Do not edit backends.conf, routes.conf or limits.conf unless I ask; the mock test runs on a
  temporary copy.
- Show me the output of every command and stop if a step fails.

Do this:
1. Run the prerequisite checks (step 1 in AI_SETUP.md).
2. Run ./scripts/setup.sh and confirm it ends with "Setup complete".
3. Ask me which backend(s) I will use (OpenAI-compatible API, Anthropic-compatible API, the agy CLI).
   Help me fill .env, and for extra APIs run ./orchestrate.sh add-api as described in step 4.
4. Run the verification steps (step 5) and report PASS or FAIL for each.
5. Summarize what is configured and which limits and model names I should edit for my accounts.
```

## Checklist

### 1. Prerequisites

| Need | Check | Expected |
|---|---|---|
| zsh 5.x | `zsh --version` | `zsh 5.x` |
| python3 | `python3 --version` | any 3.x (used for JSON and time zone handling) |
| curl | `curl --version` | any recent version |
| git | `git --version` | any recent version |

Install missing tools: macOS ships zsh and curl (`brew install python` for Python); Debian/Ubuntu: `sudo apt-get install zsh python3 curl`. Windows is not supported; use WSL.

### 2. Install and self-test

```sh
./scripts/setup.sh
```

The script is idempotent. It makes the scripts executable, creates `.env` from `.env.example` if missing, creates `work/`, runs `zsh -n` on every script, and then runs a full mock run on a temporary copy (so `backends.conf`, usage counters and your keys are untouched). Expected output ends with:

```text
syntax check passed
...
end-to-end mock run passed

Setup complete. Next: ...
```

### 3. Values to ask the user for

| Variable | Needed for | Notes |
|---|---|---|
| `DEEPSEEK_API_KEY` | The `deepseek` backend (bundled OpenAI-compatible runner) | Not needed with `LLM_MOCK=1` |
| `LLM_BASE_URL`, `LLM_MODEL` | Using another OpenAI-compatible provider with the bundled runner | Default base URL `https://api.deepseek.com/v1`; `LLM_MODEL` overrides the model name sent |
| `ORCH_<NAME>_API_KEY` | Each extra `anthropic` or `openai` backend added with `add-api` | `<NAME>` is the backend name in upper case |
| `AGY_BIN` | The `antigravity` backend if the `agy` CLI is not on `PATH` | The CLI must be installed and logged in |
| `PEAK_TZ` | Peak-hour handling | Default `UTC`; set to your provider's time zone |
| `ORCH_WORK_ROOT` | Where agent work directories live | Default `$HOME/orch-work` |

Edit `.env`, then load it into the current shell:

```sh
set -a; . ./.env; set +a
```

### 4. Connect a backend

- **OpenAI-compatible API through the bundled runner**: set `DEEPSEEK_API_KEY` (and optionally `LLM_BASE_URL`, `LLM_MODEL`). The `deepseek` backend in `backends.conf` is already enabled.
- **Extra API backend**:

  ```sh
  ./orchestrate.sh add-api myapi anthropic https://api.example.com/anthropic model-small model-large
  # or: ./orchestrate.sh add-api myopenai openai https://api.example.com/v1 model-small model-large
  export ORCH_MYAPI_API_KEY=...   # ask the user; put it in .env instead of typing it in the shell
  ```

- **No `agy` CLI**: run `./orchestrate.sh disable antigravity` (undo with `enable antigravity`). Tasks that pin that backend, such as `test-tasks/t3.txt`, will then be reported as failed.
- Model names in `backends.conf`, `routes.conf` and `limits.conf` are placeholders: replace them with models and quotas of your accounts.

### 5. Verify

| Check | Command | Expected |
|---|---|---|
| Backends listed | `./orchestrate.sh list` | a table with `deepseek` and `antigravity`, `ENABLED` column |
| Routing plan | `ORCH_USAGE_DIR=/tmp/orch-usage ./orchestrate.sh route-plan test-tasks` | one `OK` line per task with the chosen model |
| Dry run | `mkdir -p work && ./orchestrate.sh --dry-run run test-tasks out --mode route --tier light --workdir work` | the commands that would run; nothing executed |
| Mock end-to-end | `./scripts/setup.sh` | `end-to-end mock run passed` |
| Real run (needs a key) | `./orchestrate.sh run test-tasks out --mode route --tier light --workdir work` | summary table, `out/report.md` written, exit code 0 |
| Usage | `./orchestrate.sh usage` | today's counters against limits |

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `zsh: command not found` | zsh missing | Install zsh (step 1) |
| `Permission denied` on `./orchestrate.sh` | Lost executable bit | `chmod +x orchestrate.sh lane.sh scripts/*.sh examples/*.sh` |
| `(runner: DEEPSEEK_API_KEY is not set)` in an output file | `.env` not loaded | `set -a; . ./.env; set +a` in the same shell |
| `backend antigravity is disabled` | Intentional, or `agy` not available | `./orchestrate.sh enable antigravity` after installing the CLI, or ignore for tasks that pin it |
| HTTP 401 or 403 in an output file | Wrong or expired key | Replace the key in `.env` |
| HTTP 429 or `RESOURCE_EXHAUSTED` | Provider quota | The router escalates to the next model in the chain; lower the limits in `limits.conf` |
| A model is skipped as exhausted | Daily limit in `limits.conf` reached | `./orchestrate.sh usage`; raise the limit or wait for the next day |
| Peak-hour behavior is wrong | `PEAK_TZ` not set to your provider's zone | Set `PEAK_TZ`, for example `PEAK_TZ=America/New_York` |

### Uninstall and cleanup

```sh
rm -rf .env work out usage logs deepseek-logs
```

These are all local, git-ignored files. Delete the checkout folder to remove the toolkit. Revoke any API keys you created for it. If you changed `backends.conf` with `enable` or `disable`, restore it with `git checkout backends.conf`.
