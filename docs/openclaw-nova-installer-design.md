# OpenClaw Nova Installer Design

## Objective

Provide a script to automatically generate an OpenClaw application package that can be deployed to the Nova Platform, with the Web UI enabled by default.

## Generated Content

The installer generates a standard nova-app directory, containing:

- `Dockerfile`: Based on `ghcr.io/openclaw/openclaw:latest`
- `entrypoint.sh`: Injects a token and starts the gateway in the foreground
- `openclaw.json`: Minimal configuration (`gateway.mode/local` + `controlUi`)
- `enclaver.yaml`: Nova enclaver manifest (ingress/egress/resources)
- `Makefile`: `build-docker`, `build-enclave`, `run-local`
- `.dockerignore`
- `.gitignore`
- `NOVA_SUBMISSION_CHECKLIST.md`

## Key Design Points

1. **Single Port Multiplexing**
   - The OpenClaw Gateway hosts both WS and HTTP (Control UI) simultaneously.
   - `enclaver.yaml` only exposes one `ingress.listen_port` (default is 18789).

2. **Enclave Compatible Defaults**
   - Disables high-risk modules by default:
     - `OPENCLAW_SKIP_CHANNELS=1`
     - `OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1`
     - `OPENCLAW_SKIP_CANVAS_HOST=1`
   - Avoids systemd/daemon, runs directly as a foreground process.

3. **Secure Defaults**
   - Automatically generates a 32-byte hex token on startup if `OPENCLAW_GATEWAY_TOKEN` is not provided.
   - Forces UI/WS access in token mode.

4. **Resource Defaults**
   - `cpu_count=2`
   - `memory_mb=4096`
   - Can be overridden via installer parameters.

## Script Parameters

`install_openclaw_nova_app.sh` supports:

- `--output-dir`
- `--app-name`
- `--app-image`
- `--target-image`
- `--gateway-port`
- `--cpu-count`
- `--memory-mb`

## Deployment Flow (Target State)

1. Run the installer in `openclaw-installer` to generate the app package.
2. Use the Nova build process to execute `make build-docker` and `make build-enclave`.
3. Publish and deploy on the Nova platform.
4. Users open the Control UI via the app URL and log in using the token.

## Future Enhancements Proposals

- Add an `--enable-channels` flag to restore channel connectors on demand.
- Add S3 snapshot helper scripts (state backup/restore).
- Add health check and smoke test scripts.
