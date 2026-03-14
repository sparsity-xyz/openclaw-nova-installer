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
MOUNT_NAME="openclaw"
MOUNT_PATH="/mnt/openclaw"
MOUNT_SIZE_MB="10240"

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
  --mount-name <name>    Host-backed mount name (default: openclaw)
  --mount-path <path>    Path mounted inside enclave (default: /mnt/openclaw)
  --mount-size-mb <mb>   Host-backed mount size in MiB (default: 10240)
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
    --mount-name)
      MOUNT_NAME="$2"
      shift 2
      ;;
    --mount-path)
      MOUNT_PATH="$2"
      shift 2
      ;;
    --mount-size-mb)
      MOUNT_SIZE_MB="$2"
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

if [[ ! "$MOUNT_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid --mount-name: $MOUNT_NAME (use letters, digits, dot, underscore, hyphen)" >&2
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

if [[ "$MOUNT_PATH" != /mnt/* || "$MOUNT_PATH" == "/mnt" ]]; then
  echo "Invalid --mount-path: $MOUNT_PATH (must live under /mnt/...)" >&2
  exit 1
fi

if [[ "$MOUNT_PATH" == *"/./"* || "$MOUNT_PATH" == *"/../"* || "$MOUNT_PATH" == */. || "$MOUNT_PATH" == */.. ]]; then
  echo "Invalid --mount-path: $MOUNT_PATH (must not contain . or .. path components)" >&2
  exit 1
fi

if ! is_positive_int "$MOUNT_SIZE_MB"; then
  echo "Invalid --mount-size-mb: $MOUNT_SIZE_MB" >&2
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
    -e "s#__MOUNT_NAME__#${MOUNT_NAME}#g" \
    -e "s#__MOUNT_PATH__#${MOUNT_PATH}#g" \
    -e "s#__MOUNT_SIZE_MB__#${MOUNT_SIZE_MB}#g" \
    "${src}" > "${dst}"
}

render_inline() {
  local dst="$1"

  sed \
    -e "s#__GATEWAY_PORT__#${GATEWAY_PORT}#g" \
    -e "s#__CPU_COUNT__#${CPU_COUNT}#g" \
    -e "s#__MEMORY_MB__#${MEMORY_MB}#g" \
    -e "s#__APP_NAME__#${APP_NAME}#g" \
    -e "s#__APP_IMAGE__#${APP_IMAGE}#g" \
    -e "s#__TARGET_IMAGE__#${TARGET_IMAGE}#g" \
    -e "s#__MOUNT_NAME__#${MOUNT_NAME}#g" \
    -e "s#__MOUNT_PATH__#${MOUNT_PATH}#g" \
    -e "s#__MOUNT_SIZE_MB__#${MOUNT_SIZE_MB}#g" \
    > "${dst}"
}

render_template "${TEMPLATE_DIR}/Dockerfile.tpl" "${OUTPUT_DIR}/Dockerfile"
render_template "${TEMPLATE_DIR}/entrypoint.sh.tpl" "${OUTPUT_DIR}/entrypoint.sh"
render_template "${TEMPLATE_DIR}/openclaw.json.tpl" "${OUTPUT_DIR}/openclaw.json"
render_template "${TEMPLATE_DIR}/enclaver.yaml.tpl" "${OUTPUT_DIR}/enclaver.yaml"

chmod +x "${OUTPUT_DIR}/entrypoint.sh"

cat > "${OUTPUT_DIR}/Makefile" <<EOF
.PHONY: build-docker build-enclave prepare-local-data run-local
.RECIPEPREFIX := >

build-docker:
> docker build -t ${APP_IMAGE} .

build-enclave:
> enclaver build

prepare-local-data:
> mkdir -p ./openclaw-data

run-local: prepare-local-data
> docker run --rm -p ${GATEWAY_PORT}:${GATEWAY_PORT} -e OPENCLAW_GATEWAY_TOKEN=dev-token -v "\$(CURDIR)/openclaw-data:${MOUNT_PATH}" ${APP_IMAGE}
EOF

cat > "${OUTPUT_DIR}/.dockerignore" <<EOF
.git
.gitignore
node_modules
dist
coverage
*.log
openclaw-data/
.env
EOF

cat > "${OUTPUT_DIR}/.gitignore" <<EOF
openclaw-data/
.env
*.log
EOF

render_inline "${OUTPUT_DIR}/README.md" <<'EOF'
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

Then open: http://127.0.0.1:__GATEWAY_PORT__/

Use token:
- If env `OPENCLAW_GATEWAY_TOKEN` was set, use that.
- Otherwise token is printed in container logs.

## Host-backed mount layout

- OpenClaw state, workspace, and runtime config live under `__MOUNT_PATH__`
- On first boot the entrypoint copies the bundled default config to `__MOUNT_PATH__/openclaw.json`
- The generated local smoke test simulates Nova's host-backed mount with `./openclaw-data -> __MOUNT_PATH__`
- In Nova runtime, Enclaver/Nova will bind the host-backed directory through `storage.mounts[]` + `enclaver run --mount __MOUNT_NAME__=...`

## Nova Platform Submission Steps

1. Submit the current directory as a standalone Git repository (including `Dockerfile`, `enclaver.yaml`, `Makefile`).
2. Create an App in the Nova Platform and provide the Git repository address.
3. Create a Build (the `main` branch is recommended), and the platform will execute the build and package the enclave.
4. Create a Deployment and publish it.
5. After the deployment is complete, access the application URL (corresponding to `ingress.listen_port=__GATEWAY_PORT__`).
EOF

render_inline "${OUTPUT_DIR}/NOVA_SUBMISSION_CHECKLIST.md" <<'EOF'
# Nova Submission Checklist

- [ ] Repository root contains `Dockerfile`, `enclaver.yaml`, `Makefile`
- [ ] `make build-docker` succeeds locally
- [ ] `make build-enclave` succeeds in CI/build env
- [ ] Docker tag in Makefile matches `enclaver.yaml -> sources.app` (__APP_IMAGE__)
- [ ] Ingress port matches app port in Nova create-app form (__GATEWAY_PORT__)
- [ ] `enclaver.yaml -> storage.mounts[0]` is present with:
  - `name=__MOUNT_NAME__`
  - `mount_path=__MOUNT_PATH__`
  - `size_mb=__MOUNT_SIZE_MB__`
- [ ] Runtime secret configured:
  - OPENCLAW_GATEWAY_TOKEN (recommended explicit value)
  - provider API keys if needed

Expected running result:
- OpenClaw Gateway + Control UI reachable on deployed app URL.
- OpenClaw data persists inside the deployment's host-backed directory mounted at __MOUNT_PATH__.
EOF

echo "Generated OpenClaw nova-app project at: ${OUTPUT_DIR}"
