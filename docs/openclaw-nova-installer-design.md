# OpenClaw Nova Installer Design

## Objective

Provide a script to automatically generate an OpenClaw application package that can be deployed to the Nova Platform, with the Web UI enabled by default.

## Generated Content

The installer generates a standard nova-app directory, containing:

- `Dockerfile`: Based on `ghcr.io/openclaw/openclaw:latest`
- `entrypoint.sh`: Injects a token, bootstraps `/mnt/openclaw`, and starts the gateway in the foreground
- `tcp_proxy.mjs`: Exposes the public ingress port while proxying HTTP and WebSocket traffic to the loopback-only gateway process
- `openclaw.json`: Minimal configuration (`gateway.mode/local` + `controlUi`) with workspace rooted in `/mnt/openclaw`
- `enclaver.yaml`: Nova enclaver manifest (ingress/egress/resources + `storage.mounts[]`)
- `Makefile`: `build-docker`, `build-enclave`, `run-local`
- `.dockerignore`
- `.gitignore`
- `NOVA_SUBMISSION_CHECKLIST.md`

## Key Design Points

1. **Single Port Multiplexing**
   - A lightweight HTTP/WS reverse proxy owns the public ingress port (default `18789`) and forwards both HTTP and WS traffic to the internal OpenClaw Gateway loopback port.
   - `enclaver.yaml` only exposes one `ingress.listen_port` (default is 18789).

2. **Enclave Compatible Defaults**
   - Disables high-risk modules by default:
     - `OPENCLAW_SKIP_CHANNELS=1`
     - `OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1`
     - `OPENCLAW_SKIP_CANVAS_HOST=1`
   - Avoids systemd/daemon, runs directly as a foreground process.
   - Uses the host-backed mount path `/mnt/openclaw` for state, workspace, and runtime config.
   - Keeps the real OpenClaw gateway on loopback so the process sees a local client path even when Nova/Enclaver forwards traffic in from outside.

3. **Host-Backed Mount Integration**
   - `enclaver.yaml` declares:
     - `storage.mounts[0].name=openclaw`
     - `storage.mounts[0].mount_path=/mnt/openclaw`
     - `storage.mounts[0].required=true`
     - `storage.mounts[0].size_mb=10240` by default
   - The generated image bundles a default config at `/etc/openclaw/default-openclaw.json`.
   - On first boot, `entrypoint.sh` copies that config to `/mnt/openclaw/openclaw.json` if it does not already exist.
   - On the host, Enclaver persists the mount as `.enclaver-hostfs/disk.img`; while the enclave is live, the mounted filesystem is visible under `.enclaver-hostfs/mnt-*/data`.

4. **Secure Defaults**
   - Automatically generates a 32-byte hex token on startup if `OPENCLAW_GATEWAY_TOKEN` is not provided.
   - Forces UI/WS access in token mode.
   - Enables `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback=true` because Nova deployment hostnames are not known at install time.

5. **Resource Defaults**
   - `cpu_count=2`
   - `memory_mb=12288`
   - Can be overridden via installer parameters.

Operational note:
- The current `ghcr.io/openclaw/openclaw:latest` EIF measured on `app-node` required at least `10640 MiB` of enclave memory at runtime, so the installer now defaults higher than the earlier `4096 MiB` baseline.
- On small Nitro hosts, EIF packaging and enclave runtime may need different `allocator.yaml` settings: keep more RAM on the host for `enclaver build`, then reserve more RAM for `enclaver run`.
- On `app-node`, direct external traffic to the OpenClaw gateway process produced unusable HTTP behavior, but the same process worked reliably when traffic was forwarded to a loopback-only gateway socket. The installer now bakes that proxy pattern in.

## Script Parameters

`install_openclaw_nova_app.sh` supports:

- `--output-dir`
- `--app-name`
- `--app-image`
- `--target-image`
- `--gateway-port`
- `--cpu-count`
- `--memory-mb`
- `--mount-name`
- `--mount-path`
- `--mount-size-mb`

## Deployment Flow (Target State)

1. Run the installer in `openclaw-installer` to generate the app package.
2. Use the Nova build process to execute `make build-docker` and `make build-enclave`.
3. During deployment, Nova runtime binds the host-backed directory with `enclaver run --mount openclaw=<host_state_dir>`.
4. OpenClaw starts with `/mnt/openclaw` as its writable data root.
5. Users open the Control UI via the app URL and log in using the token.

## Future Enhancements Proposals

- Add an `--enable-channels` flag to restore channel connectors on demand.
- Add S3 snapshot helper scripts (state backup/restore).
- Add health check and smoke test scripts.
