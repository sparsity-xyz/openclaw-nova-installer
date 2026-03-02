#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${ROOT_DIR}/templates"

OUTPUT_DIR="${ROOT_DIR}/generated/openclaw-nova-app"
APP_NAME="openclaw-nova"
APP_IMAGE="openclaw-nova-app:latest"
TARGET_IMAGE="openclaw-nova:latest"
GATEWAY_PORT="18789"
CPU_COUNT="2"
MEMORY_MB="4096"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/install_openclaw_nova_app.sh [options]

Options:
  --output-dir <dir>     Output directory for generated nova app project
  --app-name <name>      Nova app logical name (default: openclaw-nova)
  --app-image <image>    Docker image for sources.app (default: openclaw-nova-app:latest)
  --target-image <image> Release image tag in enclaver.yaml (default: openclaw-nova:latest)
  --gateway-port <port>  OpenClaw gateway/control-ui port (default: 18789)
  --cpu-count <n>        enclaver defaults.cpu_count (default: 2)
  --memory-mb <mb>       enclaver defaults.memory_mb (default: 4096)
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --app-image)
      APP_IMAGE="$2"
      shift 2
      ;;
    --target-image)
      TARGET_IMAGE="$2"
      shift 2
      ;;
    --gateway-port)
      GATEWAY_PORT="$2"
      shift 2
      ;;
    --cpu-count)
      CPU_COUNT="$2"
      shift 2
      ;;
    --memory-mb)
      MEMORY_MB="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

is_positive_int() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -gt 0 ]]
}

if [[ ! "$APP_NAME" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]]; then
  echo "Invalid --app-name: $APP_NAME (use lowercase letters, digits, hyphens)" >&2
  exit 1
fi

if ! is_positive_int "$GATEWAY_PORT" || [[ "$GATEWAY_PORT" -gt 65535 ]]; then
  echo "Invalid --gateway-port: $GATEWAY_PORT" >&2
  exit 1
fi

if ! is_positive_int "$CPU_COUNT"; then
  echo "Invalid --cpu-count: $CPU_COUNT" >&2
  exit 1
fi

if ! is_positive_int "$MEMORY_MB"; then
  echo "Invalid --memory-mb: $MEMORY_MB" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

render_template() {
  local src="$1"
  local dst="$2"

  sed \
    -e "s#__GATEWAY_PORT__#${GATEWAY_PORT}#g" \
    -e "s#__CPU_COUNT__#${CPU_COUNT}#g" \
    -e "s#__MEMORY_MB__#${MEMORY_MB}#g" \
    -e "s#__APP_NAME__#${APP_NAME}#g" \
    -e "s#__APP_IMAGE__#${APP_IMAGE}#g" \
    -e "s#__TARGET_IMAGE__#${TARGET_IMAGE}#g" \
    "${src}" > "${dst}"
}

render_template "${TEMPLATE_DIR}/Dockerfile.tpl" "${OUTPUT_DIR}/Dockerfile"
render_template "${TEMPLATE_DIR}/entrypoint.sh.tpl" "${OUTPUT_DIR}/entrypoint.sh"
render_template "${TEMPLATE_DIR}/openclaw.json.tpl" "${OUTPUT_DIR}/openclaw.json"
render_template "${TEMPLATE_DIR}/enclaver.yaml.tpl" "${OUTPUT_DIR}/enclaver.yaml"

chmod +x "${OUTPUT_DIR}/entrypoint.sh"

cat > "${OUTPUT_DIR}/Makefile" <<EOF
.PHONY: build-docker build-enclave run-local
.RECIPEPREFIX := >

build-docker:
> docker build -t ${APP_IMAGE} .

build-enclave:
> enclaver build

run-local:
> docker run --rm -p ${GATEWAY_PORT}:${GATEWAY_PORT} -e OPENCLAW_GATEWAY_TOKEN=dev-token ${APP_IMAGE}
EOF

cat > "${OUTPUT_DIR}/.dockerignore" <<EOF
.git
.gitignore
node_modules
dist
coverage
*.log
state/
workspace/
.env
EOF

cat > "${OUTPUT_DIR}/.gitignore" <<EOF
state/
workspace/
.env
*.log
EOF

cat > "${OUTPUT_DIR}/README.md" <<'EOF'
# OpenClaw Nova App (Generated)

## 1) Build docker image

```bash
make build-docker
```

## 2) Build enclave release image

```bash
make build-enclave
```

## 3) Local smoke test

```bash
make run-local
```

Then open: http://127.0.0.1:${GATEWAY_PORT}/

Use token:
- If env `OPENCLAW_GATEWAY_TOKEN` was set, use that.
- Otherwise token is printed in container logs.

## Nova Platform Submission Steps

1. Submit the current directory as a standalone Git repository (including `Dockerfile`, `enclaver.yaml`, `Makefile`).
2. Create an App in the Nova Platform and provide the Git repository address.
3. Create a Build (the `main` branch is recommended), and the platform will execute the build and package the enclave.
4. Create a Deployment and publish it.
5. After the deployment is complete, access the application URL (corresponding to `ingress.listen_port=${GATEWAY_PORT}`).
EOF

sed -i "s#\${GATEWAY_PORT}#${GATEWAY_PORT}#g" "${OUTPUT_DIR}/README.md"

cat > "${OUTPUT_DIR}/NOVA_SUBMISSION_CHECKLIST.md" <<'EOF'
# Nova Submission Checklist

- [ ] Repository root contains `Dockerfile`, `enclaver.yaml`, `Makefile`
- [ ] `make build-docker` succeeds locally
- [ ] `make build-enclave` succeeds in CI/build env
- [ ] Docker tag in Makefile matches `enclaver.yaml -> sources.app` (${APP_IMAGE})
- [ ] Ingress port matches app port in Nova create-app form (${GATEWAY_PORT})
- [ ] Runtime secret configured:
  - OPENCLAW_GATEWAY_TOKEN (recommended explicit value)
  - provider API keys if needed

Expected running result:
- OpenClaw Gateway + Control UI reachable on deployed app URL.
EOF

sed -i "s#\${APP_IMAGE}#${APP_IMAGE}#g" "${OUTPUT_DIR}/NOVA_SUBMISSION_CHECKLIST.md"
sed -i "s#\${GATEWAY_PORT}#${GATEWAY_PORT}#g" "${OUTPUT_DIR}/NOVA_SUBMISSION_CHECKLIST.md"

echo "Generated OpenClaw nova-app project at: ${OUTPUT_DIR}"
