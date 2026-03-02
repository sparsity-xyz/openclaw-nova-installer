#!/usr/bin/env bash
set -euo pipefail

GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"

TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
TOKEN_SOURCE="env"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(node -e 'const crypto=require("node:crypto"); process.stdout.write(crypto.randomBytes(32).toString("hex"));')"
  TOKEN_SOURCE="generated"
fi

echo "[openclaw-nova] control-ui: http://0.0.0.0:${GATEWAY_PORT}/" >&2
echo "[openclaw-nova] token-source: ${TOKEN_SOURCE}" >&2
echo "[openclaw-nova] token-prefix: ${TOKEN:0:8}..." >&2

exec node openclaw.mjs gateway \
  --bind "${GATEWAY_BIND}" \
  --port "${GATEWAY_PORT}" \
  --token "${TOKEN}" \
  --allow-unconfigured
