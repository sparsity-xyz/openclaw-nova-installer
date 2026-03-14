#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_ROOT_DIR="${OPENCLAW_ROOT_DIR:-/mnt/openclaw}"
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-${OPENCLAW_ROOT_DIR}/state}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-${OPENCLAW_ROOT_DIR}/workspace}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_ROOT_DIR}/openclaw.json}"
OPENCLAW_DEFAULT_CONFIG_PATH="${OPENCLAW_DEFAULT_CONFIG_PATH:-/etc/openclaw/default-openclaw.json}"
PUBLIC_PORT="${OPENCLAW_PUBLIC_PORT:-18789}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18790}"
GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-loopback}"
PROXY_BIND_HOST="${OPENCLAW_PROXY_BIND_HOST:-0.0.0.0}"

gateway_pid=""
proxy_pid=""

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

shutdown_children() {
  local signal="${1:-TERM}"

  if [[ -n "${proxy_pid}" ]] && kill -0 "${proxy_pid}" 2>/dev/null; then
    kill "-${signal}" "${proxy_pid}" 2>/dev/null || true
  fi

  if [[ -n "${gateway_pid}" ]] && kill -0 "${gateway_pid}" 2>/dev/null; then
    kill "-${signal}" "${gateway_pid}" 2>/dev/null || true
  fi
}

trap 'shutdown_children TERM' TERM
trap 'shutdown_children INT' INT

echo "[openclaw-nova] control-ui: http://0.0.0.0:${PUBLIC_PORT}/" >&2
echo "[openclaw-nova] token-source: ${TOKEN_SOURCE}" >&2
echo "[openclaw-nova] token-prefix: ${TOKEN:0:8}..." >&2
echo "[openclaw-nova] data-root: ${OPENCLAW_ROOT_DIR}" >&2
echo "[openclaw-nova] gateway-loopback: ${GATEWAY_BIND}@127.0.0.1:${GATEWAY_PORT}" >&2
echo "[openclaw-nova] public-proxy: http://${PROXY_BIND_HOST}:${PUBLIC_PORT} -> 127.0.0.1:${GATEWAY_PORT}" >&2

node openclaw.mjs gateway \
  --bind "${GATEWAY_BIND}" \
  --port "${GATEWAY_PORT}" \
  --token "${TOKEN}" \
  --allow-unconfigured &
gateway_pid="$!"

node /usr/local/bin/openclaw-nova-tcp-proxy.mjs "${PUBLIC_PORT}" "${GATEWAY_PORT}" "${PROXY_BIND_HOST}" &
proxy_pid="$!"

wait -n "${gateway_pid}" "${proxy_pid}"
exit_code="$?"

shutdown_children TERM
wait "${gateway_pid}" 2>/dev/null || true
wait "${proxy_pid}" 2>/dev/null || true

exit "${exit_code}"
