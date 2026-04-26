# Codex Auth / Workspace Recovery (Railway)

Use this when Telegram/Hermes starts failing with errors like:

- `invalid_workspace_selected`
- `Error code: 403` from provider `openai-codex`
- `Codex token refresh failed with status 401`

## One-command recovery

```bash
bash scripts/recover-openai-codex-auth.sh \
  --service hermes-railway-template \
  --environment production
```

What it does:

1. Removes `CODEX_AUTH_JSON_B64` (so stale auth JSON does not overwrite runtime state on restart)
2. Logs out stale Hermes OpenAI Codex auth
3. Starts fresh OpenAI Codex device login flow
4. Verifies auth state in `/data/.hermes/auth.json`
5. Runs a smoke prompt (`reply with OK only`)
6. Triggers a redeploy so the running gateway uses fresh auth

Note: Hermes provider auth lives in `/data/.hermes/auth.json`. That is the file `hermes status` checks for `openai-codex` login health. `/data/.codex/auth.json` may also exist for the Codex CLI, but it is not enough by itself to fix stale Hermes provider auth.

## During device login

The script prints:

- Login URL (usually `https://auth.openai.com/codex/device`)
- One-time code

Complete those in your browser and return to the terminal.

## Useful flags

- `--skip-redeploy`: skip deployment restart
- `--skip-smoke-test`: skip `hermes chat -q` test
- `--keep-codex-auth-b64`: keep `CODEX_AUTH_JSON_B64` variable
- `--service ... --environment ...`: target explicit Railway service/env

## Quick validation commands

```bash
railway logs --service hermes-railway-template --environment production --since 10m --lines 300 \
  | rg "invalid_workspace_selected|Error code: 403"
```

```bash
railway ssh --service hermes-railway-template --environment production -- \
  "HERMES_HOME=/data/.hermes HOME=/data MESSAGING_CWD=/data/workspace hermes chat -q 'reply with OK only'"
```
