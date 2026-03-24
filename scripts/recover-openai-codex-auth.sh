#!/usr/bin/env bash
set -euo pipefail

SERVICE=""
ENVIRONMENT=""
SKIP_REDEPLOY=0
SKIP_SMOKE_TEST=0
KEEP_CODEX_AUTH_B64=0
SMOKE_PROMPT="reply with OK only"

usage() {
  cat <<'EOF'
Recover OpenAI Codex auth for Hermes on Railway.

This script is useful when Hermes starts returning:
  invalid_workspace_selected
or any stale openai-codex OAuth session errors.

Usage:
  scripts/recover-openai-codex-auth.sh [options]

Options:
  --service <name>        Railway service name (auto-detected from `railway status` if omitted)
  --environment <name>    Railway environment name (auto-detected from `railway status` if omitted)
  --skip-redeploy         Do not redeploy after successful re-auth
  --skip-smoke-test       Skip `hermes chat -q` smoke test
  --keep-codex-auth-b64   Keep CODEX_AUTH_JSON_B64 variable (default: remove it)
  --help                  Show this help

Example:
  scripts/recover-openai-codex-auth.sh --service hermes-railway-template --environment production
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)
      SERVICE="${2:-}"
      shift 2
      ;;
    --environment)
      ENVIRONMENT="${2:-}"
      shift 2
      ;;
    --skip-redeploy)
      SKIP_REDEPLOY=1
      shift
      ;;
    --skip-smoke-test)
      SKIP_SMOKE_TEST=1
      shift
      ;;
    --keep-codex-auth-b64)
      KEEP_CODEX_AUTH_B64=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd railway
require_cmd python3

if [[ -z "$SERVICE" || -z "$ENVIRONMENT" ]]; then
  status_out="$(railway status 2>/dev/null || true)"
  if [[ -z "$SERVICE" ]]; then
    SERVICE="$(printf '%s\n' "$status_out" | awk -F': ' '/^Service:/ {print $2; exit}')"
  fi
  if [[ -z "$ENVIRONMENT" ]]; then
    ENVIRONMENT="$(printf '%s\n' "$status_out" | awk -F': ' '/^Environment:/ {print $2; exit}')"
  fi
fi

if [[ -z "$SERVICE" || -z "$ENVIRONMENT" ]]; then
  echo "ERROR: could not auto-detect service/environment. Pass --service and --environment." >&2
  exit 1
fi

log "Target: service=$SERVICE environment=$ENVIRONMENT"

if [[ "$KEEP_CODEX_AUTH_B64" -eq 0 ]]; then
  log "Removing CODEX_AUTH_JSON_B64 variable (prevents stale auth re-import on boot)"
  railway variable delete CODEX_AUTH_JSON_B64 \
    --service "$SERVICE" \
    --environment "$ENVIRONMENT" >/dev/null 2>&1 || true
fi

log "Logging out stale OpenAI Codex provider session (if present)"
railway ssh \
  --service "$SERVICE" \
  --environment "$ENVIRONMENT" \
  -- "HERMES_HOME=/data/.hermes HOME=/data hermes logout --provider openai-codex || true"

log "Starting OpenAI Codex device login flow"
echo "Complete the login in your browser when URL+code appear below."
railway ssh \
  --service "$SERVICE" \
  --environment "$ENVIRONMENT" \
  -- "python3 - <<'PY'
import argparse
from hermes_cli.auth import _login_openai_codex, PROVIDER_REGISTRY
_login_openai_codex(argparse.Namespace(), PROVIDER_REGISTRY['openai-codex'])
PY"

log "Verifying provider auth state"
railway ssh \
  --service "$SERVICE" \
  --environment "$ENVIRONMENT" \
  -- "python3 - <<'PY'
import json
j = json.load(open('/data/.hermes/auth.json', encoding='utf-8'))
prov = (j.get('providers') or {}).get('openai-codex') or {}
tokens = prov.get('tokens')
print('active_provider=', j.get('active_provider'))
print('auth_mode=', prov.get('auth_mode'))
print('token_keys=', sorted(tokens.keys()) if isinstance(tokens, dict) else None)
print('last_refresh=', prov.get('last_refresh'))
PY"

if [[ "$SKIP_SMOKE_TEST" -eq 0 ]]; then
  log "Running smoke test prompt"
  railway ssh \
    --service "$SERVICE" \
    --environment "$ENVIRONMENT" \
    -- "HERMES_HOME=/data/.hermes HOME=/data MESSAGING_CWD=/data/workspace hermes chat -q '$SMOKE_PROMPT'"
fi

if [[ "$SKIP_REDEPLOY" -eq 0 ]]; then
  log "Redeploying service so running gateway picks up fresh auth"
  railway redeploy --service "$SERVICE" --yes >/dev/null
  log "Redeploy triggered. Check with:"
  echo "  railway deployment list --service $SERVICE --environment $ENVIRONMENT | head -n 5"
fi

log "Done"
