#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_ROOT_DIR="${OPENCLAW_ROOT_DIR:-/mnt/openclaw}"
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-${OPENCLAW_ROOT_DIR}/state}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-${OPENCLAW_ROOT_DIR}/workspace}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_ROOT_DIR}/openclaw.json}"
OPENCLAW_DEFAULT_CONFIG_PATH="${OPENCLAW_DEFAULT_CONFIG_PATH:-/etc/openclaw/default-openclaw.json}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"

TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
TOKEN_SOURCE="env"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(node -e 'const crypto=require("node:crypto"); process.stdout.write(crypto.randomBytes(32).toString("hex"));')"
  TOKEN_SOURCE="generated"
fi

mkdir -p "${OPENCLAW_ROOT_DIR}" "${OPENCLAW_STATE_DIR}" "${OPENCLAW_WORKSPACE_DIR}"

if [[ ! -f "${OPENCLAW_CONFIG_PATH}" ]]; then
  cp "${OPENCLAW_DEFAULT_CONFIG_PATH}" "${OPENCLAW_CONFIG_PATH}"
fi

echo "[openclaw-nova] control-ui: http://0.0.0.0:${GATEWAY_PORT}/" >&2
echo "[openclaw-nova] token-source: ${TOKEN_SOURCE}" >&2
echo "[openclaw-nova] token-prefix: ${TOKEN:0:8}..." >&2
echo "[openclaw-nova] data-root: ${OPENCLAW_ROOT_DIR}" >&2

exec node openclaw.mjs gateway \
  --bind "${GATEWAY_BIND}" \
  --port "${GATEWAY_PORT}" \
  --token "${TOKEN}" \
  --allow-unconfigured
