#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="${OPENCLAW_DATA_ROOT:-/mnt/openclaw}"
MANAGER_PORT="${OPENCLAW_MANAGER_PORT:-8000}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

mkdir -p \
  "${DATA_ROOT}" \
  "${DATA_ROOT}/manager" \
  "${DATA_ROOT}/manager/logs" \
  "${DATA_ROOT}/workspace"

echo "[openclaw-manager] data-root: ${DATA_ROOT}" >&2
echo "[openclaw-manager] manager-port: ${MANAGER_PORT}" >&2
echo "[openclaw-manager] openclaw-loopback-port: ${GATEWAY_PORT}" >&2
echo "[openclaw-manager] setup-url: http://0.0.0.0:${MANAGER_PORT}/setup" >&2

exec node /usr/local/bin/openclaw-manager.mjs
