#!/usr/bin/env bash
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
export HOME="${HOME:-/data}"
export MESSAGING_CWD="${MESSAGING_CWD:-/data/workspace}"
export CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
export CODEX_CONFIG_DIR="${CODEX_CONFIG_DIR:-${CODEX_HOME}}"

# Restrict permissions for generated runtime files by default.
umask 077

INIT_MARKER="${HERMES_HOME}/.initialized"
ENV_FILE="${HERMES_HOME}/.env"
CONFIG_FILE="${HERMES_HOME}/config.yaml"
CODEX_AUTH_FILE="${CODEX_HOME}/auth.json"

mkdir -p "${HERMES_HOME}" "${HERMES_HOME}/logs" "${HERMES_HOME}/sessions" "${HERMES_HOME}/cron" "${HERMES_HOME}/pairing" "${MESSAGING_CWD}" "${CODEX_HOME}"

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_platforms() {
  local count=0

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    count=$((count + 1))
  fi

  if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
    count=$((count + 1))
  fi

  if [[ -n "${SLACK_BOT_TOKEN:-}" || -n "${SLACK_APP_TOKEN:-}" ]]; then
    if [[ -z "${SLACK_BOT_TOKEN:-}" || -z "${SLACK_APP_TOKEN:-}" ]]; then
      echo "[bootstrap] ERROR: Slack requires both SLACK_BOT_TOKEN and SLACK_APP_TOKEN." >&2
      exit 1
    fi
    count=$((count + 1))
  fi

  if [[ "$count" -lt 1 ]]; then
    echo "[bootstrap] ERROR: Configure at least one platform: Telegram, Discord, or Slack." >&2
    exit 1
  fi
}

has_valid_provider_config() {
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${OPENAI_BASE_URL:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    return 0
  fi

  return 1
}

append_if_set() {
  local key="$1"
  local val="${!key:-}"
  if [[ -n "$val" ]]; then
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

infer_provider_from_env() {
  if [[ -n "${HERMES_INFERENCE_PROVIDER:-}" ]]; then
    printf '%s\n' "${HERMES_INFERENCE_PROVIDER}"
    return 0
  fi

  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    printf '%s\n' "openrouter"
    return 0
  fi

  if [[ -n "${OPENAI_BASE_URL:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
    printf '%s\n' "openai"
    return 0
  fi

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    printf '%s\n' "anthropic"
    return 0
  fi

  return 1
}

sync_model_config_from_env() {
  local desired_provider desired_model desired_base_url
  desired_provider="$(infer_provider_from_env || true)"
  desired_model="${LLM_MODEL:-}"
  desired_base_url=""

  if [[ -z "${desired_provider}" || ! -f "${CONFIG_FILE}" ]]; then
    return 0
  fi

  case "${desired_provider}" in
    openrouter)
      desired_base_url="https://openrouter.ai/api/v1"
      if [[ -z "${desired_model}" ]]; then
        desired_model="qwen/qwen3-coder:free"
      fi
      ;;
    openai)
      desired_base_url="${OPENAI_BASE_URL:-}"
      ;;
    openai-codex)
      desired_base_url="https://chatgpt.com/backend-api/codex"
      ;;
  esac

  CONFIG_FILE_PATH="${CONFIG_FILE}" \
  DESIRED_PROVIDER="${desired_provider}" \
  DESIRED_MODEL="${desired_model}" \
  DESIRED_BASE_URL="${desired_base_url}" \
  python3 - <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    print("[bootstrap] WARNING: PyYAML not available; skipping persisted model config sync.", file=sys.stderr)
    raise SystemExit(0)

config_path = os.environ["CONFIG_FILE_PATH"]
desired_provider = os.environ["DESIRED_PROVIDER"]
desired_model = os.environ.get("DESIRED_MODEL", "")
desired_base_url = os.environ.get("DESIRED_BASE_URL", "")

with open(config_path, encoding="utf-8") as fh:
    config = yaml.safe_load(fh) or {}

model = config.get("model")
if not isinstance(model, dict):
    model = {}

changed = False
previous_provider = model.get("provider")

if previous_provider != desired_provider:
    model["provider"] = desired_provider
    changed = True

if desired_model and model.get("default") != desired_model:
    model["default"] = desired_model
    changed = True
elif not desired_model and previous_provider != desired_provider and "default" in model:
    model.pop("default", None)
    changed = True

if desired_base_url:
    if model.get("base_url") != desired_base_url:
      model["base_url"] = desired_base_url
      changed = True
elif "base_url" in model:
    model.pop("base_url", None)
    changed = True

if not changed:
    raise SystemExit(0)

config["model"] = model

with open(config_path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(config, fh, sort_keys=False)

print(f"[bootstrap] Synced persisted model config to provider={desired_provider}.")
PY
}

bootstrap_codex_auth() {
  if is_true "${CODEX_RESET_STATE_ON_BOOT:-}"; then
    rm -f "${CODEX_AUTH_FILE}"
    echo "[bootstrap] CODEX_RESET_STATE_ON_BOOT=true; cleared Codex auth state."
  fi

  if [[ -n "${CODEX_AUTH_JSON_B64:-}" ]]; then
    local tmp_auth
    tmp_auth="$(mktemp)"

    if ! printf '%s' "${CODEX_AUTH_JSON_B64}" | base64 -d > "${tmp_auth}" 2>/dev/null; then
      if ! printf '%s' "${CODEX_AUTH_JSON_B64}" | base64 --decode > "${tmp_auth}" 2>/dev/null; then
        rm -f "${tmp_auth}"
        echo "[bootstrap] ERROR: CODEX_AUTH_JSON_B64 is not valid base64." >&2
        exit 1
      fi
    fi

    if ! python3 -m json.tool "${tmp_auth}" >/dev/null 2>&1; then
      rm -f "${tmp_auth}"
      echo "[bootstrap] ERROR: CODEX_AUTH_JSON_B64 did not decode to valid JSON." >&2
      exit 1
    fi

    mv "${tmp_auth}" "${CODEX_AUTH_FILE}"
    chmod 600 "${CODEX_AUTH_FILE}"
    unset CODEX_AUTH_JSON_B64
    echo "[bootstrap] Installed Codex auth at ${CODEX_AUTH_FILE}."
    return
  fi

  if [[ -n "${CODEX_OPENAI_API_KEY:-}" ]]; then
    CODEX_AUTH_FILE_PATH="${CODEX_AUTH_FILE}" python3 - <<'PY'
import json
import os
from pathlib import Path

auth_file = Path(os.environ["CODEX_AUTH_FILE_PATH"])
payload = {
    "OPENAI_API_KEY": os.environ["CODEX_OPENAI_API_KEY"],
    "auth_mode": "apikey",
    "last_refresh": None,
    "tokens": None,
}
auth_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
    chmod 600 "${CODEX_AUTH_FILE}"
    unset CODEX_OPENAI_API_KEY
    echo "[bootstrap] Wrote Codex API key auth at ${CODEX_AUTH_FILE}."
  fi
}

if ! has_valid_provider_config; then
  echo "[bootstrap] ERROR: Configure a provider: OPENROUTER_API_KEY, or OPENAI_BASE_URL+OPENAI_API_KEY, or ANTHROPIC_API_KEY." >&2
  exit 1
fi

validate_platforms
bootstrap_codex_auth

echo "[bootstrap] Writing runtime env to ${ENV_FILE}"
{
  echo "# Managed by entrypoint.sh"
  echo "HERMES_HOME=${HERMES_HOME}"
  echo "MESSAGING_CWD=${MESSAGING_CWD}"
  echo "CODEX_HOME=${CODEX_HOME}"
  echo "CODEX_CONFIG_DIR=${CODEX_CONFIG_DIR}"
} > "$ENV_FILE"

for key in \
  OPENROUTER_API_KEY OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_API_KEY LLM_MODEL HERMES_INFERENCE_PROVIDER HERMES_PORTAL_BASE_URL NOUS_INFERENCE_BASE_URL HERMES_NOUS_MIN_KEY_TTL_SECONDS HERMES_DUMP_REQUESTS \
  TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS TELEGRAM_ALLOW_ALL_USERS TELEGRAM_HOME_CHANNEL TELEGRAM_HOME_CHANNEL_NAME \
  DISCORD_BOT_TOKEN DISCORD_ALLOWED_USERS DISCORD_ALLOW_ALL_USERS DISCORD_HOME_CHANNEL DISCORD_HOME_CHANNEL_NAME DISCORD_REQUIRE_MENTION DISCORD_FREE_RESPONSE_CHANNELS \
  SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS SLACK_ALLOW_ALL_USERS SLACK_HOME_CHANNEL SLACK_HOME_CHANNEL_NAME WHATSAPP_ENABLED WHATSAPP_ALLOWED_USERS \
  GATEWAY_ALLOW_ALL_USERS \
  FIRECRAWL_API_KEY NOUS_API_KEY BROWSERBASE_API_KEY BROWSERBASE_PROJECT_ID BROWSERBASE_PROXIES BROWSERBASE_ADVANCED_STEALTH BROWSER_SESSION_TIMEOUT BROWSER_INACTIVITY_TIMEOUT FAL_KEY ELEVENLABS_API_KEY VOICE_TOOLS_OPENAI_KEY \
  TINKER_API_KEY WANDB_API_KEY RL_API_URL GITHUB_TOKEN \
  TERMINAL_ENV TERMINAL_BACKEND TERMINAL_DOCKER_IMAGE TERMINAL_SINGULARITY_IMAGE TERMINAL_MODAL_IMAGE TERMINAL_CWD TERMINAL_TIMEOUT TERMINAL_LIFETIME_SECONDS TERMINAL_CONTAINER_CPU TERMINAL_CONTAINER_MEMORY TERMINAL_CONTAINER_DISK TERMINAL_CONTAINER_PERSISTENT TERMINAL_SANDBOX_DIR TERMINAL_SSH_HOST TERMINAL_SSH_USER TERMINAL_SSH_PORT TERMINAL_SSH_KEY SUDO_PASSWORD \
  WEB_TOOLS_DEBUG VISION_TOOLS_DEBUG MOA_TOOLS_DEBUG IMAGE_TOOLS_DEBUG CONTEXT_COMPRESSION_ENABLED CONTEXT_COMPRESSION_THRESHOLD CONTEXT_COMPRESSION_MODEL HERMES_MAX_ITERATIONS HERMES_TOOL_PROGRESS HERMES_TOOL_PROGRESS_MODE
do
  append_if_set "$key"
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[bootstrap] Creating ${CONFIG_FILE}"
  cat > "$CONFIG_FILE" <<EOF
terminal:
  backend: ${TERMINAL_ENV:-${TERMINAL_BACKEND:-local}}
  cwd: ${TERMINAL_CWD:-/data/workspace}
  timeout: ${TERMINAL_TIMEOUT:-180}
compression:
  enabled: true
  threshold: 0.85
EOF
fi

sync_model_config_from_env

if [[ ! -f "$INIT_MARKER" ]]; then
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$INIT_MARKER"
  echo "[bootstrap] First-time initialization completed."
else
  echo "[bootstrap] Existing Hermes data found. Skipping one-time init."
fi

if [[ -z "${TELEGRAM_ALLOWED_USERS:-}${DISCORD_ALLOWED_USERS:-}${SLACK_ALLOWED_USERS:-}" ]]; then
  if ! is_true "${GATEWAY_ALLOW_ALL_USERS:-}" && ! is_true "${TELEGRAM_ALLOW_ALL_USERS:-}" && ! is_true "${DISCORD_ALLOW_ALL_USERS:-}" && ! is_true "${SLACK_ALLOW_ALL_USERS:-}"; then
    echo "[bootstrap] WARNING: No allowlists configured. Gateway defaults to deny-all; use DM pairing or set *_ALLOWED_USERS." >&2
  fi
fi

echo "[bootstrap] Starting Hermes gateway..."
exec hermes gateway
