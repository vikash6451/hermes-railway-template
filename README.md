# Hermes Agent Railway Template

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/hermes-railway-template?referralCode=uTN7AS&utm_medium=integration&utm_source=template&utm_campaign=generic)

Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) to Railway as a worker service with persistent state.

This template is worker-only: setup and configuration are done through Railway Variables, then the container bootstraps Hermes automatically on first run.

## What you get

- Hermes gateway running as a Railway worker
- First-boot bootstrap from environment variables
- Persistent Hermes state on a Railway volume at `/data`
- Telegram, Discord, or Slack support (at least one required)
- Codex CLI available in the container (enabled by default)

## How it works

1. You configure required variables in Railway.
2. On first boot, entrypoint initializes Hermes under `/data/.hermes`.
3. On future boots, the same persisted state is reused.
4. Container starts `hermes gateway`.

## Railway deploy instructions

In Railway Template Composer:

1. Add a volume mounted at `/data`.
2. Deploy as a worker service.
3. Configure variables listed below.

Template defaults (already included in `railway.toml`):

- `HERMES_HOME=/data/.hermes`
- `HOME=/data`
- `MESSAGING_CWD=/data/workspace`
- `CODEX_HOME=/data/.codex`
- `CODEX_CONFIG_DIR=/data/.codex`

## Default environment variables

This template defaults to Telegram + OpenRouter. These are the default variables to fill when deploying:

```env
OPENROUTER_API_KEY=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_ALLOWED_USERS=""
```

If you use OpenRouter and do not set `LLM_MODEL`, the template defaults Hermes to `qwen/qwen3-coder:free`.

You can add or change variables later in Railway service Variables.
For the latest supported variables and behavior, follow upstream Hermes documentation:

- https://github.com/NousResearch/hermes-agent
- https://github.com/NousResearch/hermes-agent/blob/main/README.md

## Required runtime variables

You must set:

- At least one inference provider config:
  - `OPENROUTER_API_KEY`, or
  - `OPENAI_BASE_URL` + `OPENAI_API_KEY`, or
  - `ANTHROPIC_API_KEY`
- At least one messaging platform:
  - Telegram: `TELEGRAM_BOT_TOKEN`
  - Discord: `DISCORD_BOT_TOKEN`
  - Slack: `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN`

Strongly recommended allowlists:

- `TELEGRAM_ALLOWED_USERS`
- `DISCORD_ALLOWED_USERS`
- `SLACK_ALLOWED_USERS`

Allowlist format examples (comma-separated, no brackets, no quotes):

- `TELEGRAM_ALLOWED_USERS=123456789,987654321`
- `DISCORD_ALLOWED_USERS=123456789012345678,234567890123456789`
- `SLACK_ALLOWED_USERS=U01234ABCDE,U09876WXYZ`

Use plain comma-separated values like `123,456,789`.
Do not use JSON or quoted arrays like `[123,456]` or `"123","456"`.

Optional global controls:

- `GATEWAY_ALLOW_ALL_USERS=true` (not recommended)

Provider selection tip:

- If you set multiple provider keys, set `HERMES_INFERENCE_PROVIDER` (for example: `openrouter`) to avoid auto-selection surprises.

## Codex auth on Railway

This image installs `@openai/codex` by default so `codex ...` commands can run inside the service.

For non-interactive auth through Railway Variables, set one of these:

- `CODEX_AUTH_JSON_B64` (recommended): base64 of your local `~/.codex/auth.json`
- `CODEX_OPENAI_API_KEY`: writes API-key auth to `${CODEX_HOME}/auth.json`

Optional control:

- `CODEX_RESET_STATE_ON_BOOT=true` to clear `${CODEX_HOME}/auth.json` before bootstrapping auth

Generate base64 locally:

```bash
base64 < ~/.codex/auth.json | tr -d '\n'
```

If OpenAI Codex starts failing with `invalid_workspace_selected` or related `403` errors, run:

```bash
bash scripts/recover-openai-codex-auth.sh --service hermes-railway-template --environment production
```

Detailed runbook: [CODEX_AUTH_RECOVERY.md](./CODEX_AUTH_RECOVERY.md)

## Environment variable reference

For the full and up-to-date list, check out the [Hermes repository](https://github.com/NousResearch/hermes-agent).

## Simple usage guide

After deploy:

1. Start a chat with your bot on Telegram/Discord/Slack.
2. If using allowlists, ensure your user ID is included.
3. Send a normal message (for example: `hello`).
4. Hermes should respond via the configured model provider.

Helpful first checks:

- Confirm gateway logs show platform connection success.
- Confirm volume mount exists at `/data`.
- Confirm your provider variables are set and valid.

## Running Hermes commands manually

If you want to run `hermes ...` commands manually inside the deployed service (for example `hermes config`, `hermes model`, or `hermes pairing list`), use [Railway SSH](https://docs.railway.com/cli/ssh) to connect to the running container.

Example commands after connecting:

```bash
hermes status
hermes config
hermes model
hermes pairing list
```

## Runtime behavior

Entrypoint (`scripts/entrypoint.sh`) does the following:

- Validates required provider and platform variables
- Bootstraps Codex auth from Railway variables when provided
- Writes runtime env to `${HERMES_HOME}/.env`
- Creates `${HERMES_HOME}/config.yaml` if missing
- Re-syncs persisted model provider settings from Railway env on boot
- Persists one-time marker `${HERMES_HOME}/.initialized`
- Starts `hermes gateway`

## Troubleshooting

- `401 Missing Authentication header`: provider/key mismatch (often wrong provider auto-selection or missing API key for selected provider).
- `HTTP 401: User not found.` with `OPENROUTER_API_KEY` set: persisted Hermes config is likely still pinned to another provider. Ensure `HERMES_INFERENCE_PROVIDER=openrouter` is set and restart on the latest template so boot sync updates `${HERMES_HOME}/config.yaml`.
- `HTTP 400: No models provided`: set `LLM_MODEL`, or restart on the latest template so OpenRouter defaults to `qwen/qwen3-coder:free`.
- Bot connected but no replies: check allowlist variables and user IDs.
- Data lost after redeploy: verify Railway volume is mounted at `/data`.

## Build pinning and reproducibility

Docker build arg:

- `HERMES_GIT_REF` (default: `main`; branch or tag)
- `HERMES_GIT_SHA` (optional commit SHA; applied after clone)

For reproducible builds, pin both `HERMES_GIT_REF` and `HERMES_GIT_SHA`.

## Local smoke test

```bash
docker build -t hermes-railway-template .

docker run --rm \
  -e OPENROUTER_API_KEY=sk-or-xxx \
  -e TELEGRAM_BOT_TOKEN=123456:ABC \
  -e TELEGRAM_ALLOWED_USERS=123456789 \
  -v "$(pwd)/.tmpdata:/data" \
  hermes-railway-template
```
