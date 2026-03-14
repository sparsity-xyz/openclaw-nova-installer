#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${ROOT_DIR}/templates"

OUTPUT_DIR="${ROOT_DIR}/generated/openclaw-nova-app"
APP_NAME="openclaw-manager"
APP_IMAGE="openclaw-manager-app:latest"
TARGET_IMAGE="openclaw-manager:latest"
MANAGER_PORT="8000"
OPENCLAW_PORT="18789"
CPU_COUNT="2"
MEMORY_MB="12288"
OPENCLAW_VERSION="latest"
MOUNT_NAME="openclaw"
MOUNT_PATH="/mnt/openclaw"
MOUNT_SIZE_MB="10240"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/install_openclaw_nova_app.sh [options]

Options:
  --output-dir <dir>         Output directory for generated nova app project
  --app-name <name>          Nova app logical name (default: openclaw-manager)
  --app-image <image>        Docker image for sources.app (default: openclaw-manager-app:latest)
  --target-image <image>     Release image tag in enclaver.yaml (default: openclaw-manager:latest)
  --manager-port <port>      Public openclaw-manager HTTP port (default: 8000)
  --openclaw-port <port>     Internal OpenClaw loopback gateway port (default: 18789)
  --gateway-port <port>      Alias for --openclaw-port
  --cpu-count <n>            enclaver defaults.cpu_count (default: 2)
  --memory-mb <mb>           enclaver defaults.memory_mb (default: 12288)
  --openclaw-version <ver>   OpenClaw version installed by install-cli.sh (default: latest)
  --mount-name <name>        Host-backed mount name (default: openclaw)
  --mount-path <path>        Path mounted inside enclave (default: /mnt/openclaw)
  --mount-size-mb <mb>       Host-backed mount size in MiB (default: 10240)
  -h, --help                 Show this help
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
    --manager-port)
      MANAGER_PORT="$2"
      shift 2
      ;;
    --openclaw-port|--gateway-port)
      OPENCLAW_PORT="$2"
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
    --openclaw-version)
      OPENCLAW_VERSION="$2"
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

if ! is_positive_int "$MANAGER_PORT" || [[ "$MANAGER_PORT" -gt 65535 ]]; then
  echo "Invalid --manager-port: $MANAGER_PORT" >&2
  exit 1
fi

if ! is_positive_int "$OPENCLAW_PORT" || [[ "$OPENCLAW_PORT" -gt 65535 ]]; then
  echo "Invalid --openclaw-port: $OPENCLAW_PORT" >&2
  exit 1
fi

if [[ "$MANAGER_PORT" -eq "$OPENCLAW_PORT" ]]; then
  echo "Invalid port layout: manager-port and openclaw-port must differ" >&2
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

if [[ -z "$OPENCLAW_VERSION" ]]; then
  echo "Invalid --openclaw-version: value must not be empty" >&2
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
    -e "s#__MANAGER_PORT__#${MANAGER_PORT}#g" \
    -e "s#__OPENCLAW_PORT__#${OPENCLAW_PORT}#g" \
    -e "s#__CPU_COUNT__#${CPU_COUNT}#g" \
    -e "s#__MEMORY_MB__#${MEMORY_MB}#g" \
    -e "s#__APP_NAME__#${APP_NAME}#g" \
    -e "s#__APP_IMAGE__#${APP_IMAGE}#g" \
    -e "s#__TARGET_IMAGE__#${TARGET_IMAGE}#g" \
    -e "s#__OPENCLAW_VERSION__#${OPENCLAW_VERSION}#g" \
    -e "s#__MOUNT_NAME__#${MOUNT_NAME}#g" \
    -e "s#__MOUNT_PATH__#${MOUNT_PATH}#g" \
    -e "s#__MOUNT_SIZE_MB__#${MOUNT_SIZE_MB}#g" \
    "${src}" > "${dst}"
}

render_inline() {
  local dst="$1"

  sed \
    -e "s#__MANAGER_PORT__#${MANAGER_PORT}#g" \
    -e "s#__OPENCLAW_PORT__#${OPENCLAW_PORT}#g" \
    -e "s#__CPU_COUNT__#${CPU_COUNT}#g" \
    -e "s#__MEMORY_MB__#${MEMORY_MB}#g" \
    -e "s#__APP_NAME__#${APP_NAME}#g" \
    -e "s#__APP_IMAGE__#${APP_IMAGE}#g" \
    -e "s#__TARGET_IMAGE__#${TARGET_IMAGE}#g" \
    -e "s#__OPENCLAW_VERSION__#${OPENCLAW_VERSION}#g" \
    -e "s#__MOUNT_NAME__#${MOUNT_NAME}#g" \
    -e "s#__MOUNT_PATH__#${MOUNT_PATH}#g" \
    -e "s#__MOUNT_SIZE_MB__#${MOUNT_SIZE_MB}#g" \
    > "${dst}"
}

rm -f \
  "${OUTPUT_DIR}/tcp_proxy.mjs" \
  "${OUTPUT_DIR}/openclaw.json"

render_template "${TEMPLATE_DIR}/Dockerfile.tpl" "${OUTPUT_DIR}/Dockerfile"
render_template "${TEMPLATE_DIR}/entrypoint.sh.tpl" "${OUTPUT_DIR}/entrypoint.sh"
render_template "${TEMPLATE_DIR}/openclaw_manager.mjs.tpl" "${OUTPUT_DIR}/openclaw_manager.mjs"
render_template "${TEMPLATE_DIR}/enclaver.yaml.tpl" "${OUTPUT_DIR}/enclaver.yaml"

chmod +x "${OUTPUT_DIR}/entrypoint.sh"

render_inline "${OUTPUT_DIR}/build_release_image.sh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

MANIFEST_FILE="${1:-enclaver.yaml}"
TARGET_IMAGE="${TARGET_IMAGE:-__TARGET_IMAGE__}"
SLEEVE_IMAGE="${SLEEVE_IMAGE:-public.ecr.aws/d4t4u8d2/sparsity-ai/sleeve:latest}"

build_dir="$(mktemp -d /tmp/openclaw-release-build.XXXXXX)"
cleanup() {
  rm -rf "${build_dir}"
}
trap cleanup EXIT

eif_path="${build_dir}/application.eif"
cp "${MANIFEST_FILE}" "${build_dir}/enclaver.yaml"

enclaver build -f "${MANIFEST_FILE}" --eif-only "${eif_path}"

cat > "${build_dir}/Dockerfile" <<DOCKERFILE
FROM ${SLEEVE_IMAGE}
COPY enclaver.yaml /enclave/enclaver.yaml
COPY application.eif /enclave/application.eif
DOCKERFILE

docker build -t "${TARGET_IMAGE}" "${build_dir}"
docker image inspect "${TARGET_IMAGE}" --format '{{.Id}} {{.Created}}'
EOF

chmod +x "${OUTPUT_DIR}/build_release_image.sh"

cat > "${OUTPUT_DIR}/Makefile" <<EOF
.PHONY: build-docker build-enclave prepare-local-data run-local
.RECIPEPREFIX := >

build-docker:
> docker build -t ${APP_IMAGE} .

build-enclave:
> ./build_release_image.sh

prepare-local-data:
> mkdir -p ./openclaw-data

run-local: prepare-local-data
> docker run --rm -p ${MANAGER_PORT}:${MANAGER_PORT} -v "\$(CURDIR)/openclaw-data:${MOUNT_PATH}" ${APP_IMAGE}
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
# OpenClaw Manager Nova App (Generated)

This generated app exposes a single public service on port `__MANAGER_PORT__`:

- `GET /setup` for first-run account registration
- `GET /login` for later logins
- `GET /openclaw/` for the OpenClaw Control UI after manager authentication

The image preinstalls OpenClaw with the official CLI installer:

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh | bash -s -- --prefix /opt/openclaw-cli --version __OPENCLAW_VERSION__ --no-onboard
```

At runtime, all writable state stays under `__MOUNT_PATH__`.

## 1) Build docker image

```bash
make build-docker
```

## 2) Build enclave release image

```bash
make build-enclave
```

This helper builds the EIF first, then packages the final `sleeve`-based release image
explicitly. That matches the artifact shape Enclaver expects while avoiding the
`packaging EIF into release image` broken-pipe failure we observed on `app-node`.

## 3) Local smoke test

```bash
make run-local
```

Then open `http://127.0.0.1:__MANAGER_PORT__/setup` to register the first manager account.

## Runtime Layout

- Manager HTTP port: `__MANAGER_PORT__`
- Internal OpenClaw gateway port: `127.0.0.1:__OPENCLAW_PORT__`
- Manager state: `__MOUNT_PATH__/manager/state.json`
- OpenClaw config: `__MOUNT_PATH__/openclaw.json`
- OpenClaw workspace: `__MOUNT_PATH__/workspace`
- OpenClaw CLI root: `/opt/openclaw-cli`

## Auth Model

The manager owns the internet-facing login flow. OpenClaw itself runs in `gateway.auth.mode=trusted-proxy`, restricted to loopback trusted proxies only.

That means:

- users authenticate with the manager username/password
- the manager reverse-proxies `/openclaw` to the internal gateway
- the browser never needs a long-lived OpenClaw token
- Control UI pairing is skipped because trusted-proxy operator auth is satisfied upstream

## Model Configuration

After login, the dashboard exposes a JSON editor for the top-level `models` section. Saving that form rewrites `openclaw.json`, preserves manager-owned gateway fields, and restarts the gateway.
EOF

render_inline "${OUTPUT_DIR}/NOVA_SUBMISSION_CHECKLIST.md" <<'EOF'
# Nova Submission Checklist

- Build the Docker image with `make build-docker`
- Build the EIF with `make build-enclave`
- Confirm `enclaver.yaml` exposes only port `__MANAGER_PORT__`
- Confirm `storage.mounts[0]` points at `__MOUNT_PATH__`
- Deploy with the host-backed mount named `__MOUNT_NAME__`
- After deployment, open `/setup` once to register the manager account
- Log in and run the "Initialize OpenClaw" action before visiting `/openclaw/`
EOF

echo "Generated OpenClaw manager nova app in: ${OUTPUT_DIR}"
