# OpenClaw Nova Installer Design

## Objective

Generate a Nova-ready application package that runs an image-bundled OpenClaw CLI while keeping all mutable state in a host-backed mount, and expose a safer hosted control plane for first-run setup and later management.

## High-Level Architecture

The generated app contains two logical layers:

1. `openclaw-manager`
   - Public HTTP service on port `8000`
   - Handles registration, login, initialization, config updates, and reverse proxying

2. OpenClaw gateway
   - Installed with `install-cli.sh --prefix /opt/openclaw-cli --no-onboard` during image build
   - Runs only on `127.0.0.1:18789`
   - Reads config from `/mnt/openclaw/openclaw.json`

The external browser never connects directly to a public OpenClaw socket. It connects to the manager, and the manager proxies `/openclaw` to the loopback gateway.

## Why This Replaces The Old Design

The previous installer wrapped the published OpenClaw Docker image and then added a lightweight proxy. That was enough to surface the Control UI, but it left deployment concerns unresolved:

- how to do first-run bootstrap cleanly
- how to avoid hard-coding or shipping a long-lived gateway token
- how to align with the hosted `/setup` plus `/openclaw` product pattern already used upstream

The new design moves these concerns into a dedicated manager service and uses the official CLI install path instead of the published Docker image.

## Generated Files

The installer now generates:

- `Dockerfile`
  - `ubuntu:24.04`
  - installs Node 22 at build time for the manager runtime
  - installs OpenClaw CLI into `/opt/openclaw-cli` during image build
- `entrypoint.sh`
  - prepares mount directories and launches the manager
- `openclaw_manager.mjs`
  - manager HTTP service
  - account auth
  - OpenClaw install/setup/start/stop/restart logic
  - `/openclaw` HTTP and WebSocket reverse proxy
- `enclaver.yaml`
  - exposes only the manager port
  - declares the host-backed storage mount
- `Makefile`
  - `build-docker`
  - `build-enclave`
  - `run-local`
- `build_release_image.sh`
  - builds the EIF with `enclaver build --eif-only`
  - packages the final release image on top of the `sleeve` base image

## Manager Flow

### First Run

- No manager account exists
- `GET /setup` shows the registration form
- Submitted credentials are stored in `/mnt/openclaw/manager/state.json`
- The manager sets an authenticated session cookie and redirects to the dashboard

### After Registration

- `GET /login` becomes the normal entry point
- After login, the dashboard allows:
  - initializing OpenClaw
  - restarting or stopping the gateway
  - editing the top-level `models` section
  - opening `/openclaw/`

### OpenClaw Initialization

When the user clicks Initialize:

1. Verify the image-bundled OpenClaw CLI is present and record its version
2. Run `openclaw setup --workspace /mnt/openclaw/workspace`
3. Rewrite `openclaw.json` with manager-owned gateway settings
4. Start `openclaw gateway run --bind loopback --port 18789 --allow-unconfigured`

## Auth Model

This design intentionally does not depend on shipping a public token.

Instead, the generated `openclaw.json` configures:

- `gateway.auth.mode = "trusted-proxy"`
- `gateway.auth.trustedProxy.userHeader = "x-openclaw-user"`
- `gateway.auth.trustedProxy.requiredHeaders = ["x-openclaw-authenticated"]`
- `gateway.auth.trustedProxy.allowUsers = [<manager username>]`
- `gateway.trustedProxies = ["127.0.0.1", "::1"]`
- `gateway.controlUi.basePath = "/openclaw"`
- `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true`

The manager injects those headers only after its own login succeeds. Because current OpenClaw trusted-proxy operator auth satisfies the Control UI's pairing rules, the browser can enter `/openclaw` directly after manager login without a separate token handoff.

## Config Ownership

The manager preserves user-edited `models`, but always re-applies these fields:

- `agents.defaults.workspace`
- `gateway.mode`
- `gateway.bind`
- `gateway.port`
- `gateway.auth.mode`
- `gateway.auth.trustedProxy.*`
- `gateway.trustedProxies`
- `gateway.controlUi.enabled`
- `gateway.controlUi.basePath`
- `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback`

This keeps the reverse-proxy topology stable even after later model updates.

## Storage Layout

All mutable runtime state lives under `/mnt/openclaw`:

- `/mnt/openclaw/openclaw.json`
- `/mnt/openclaw/openclaw.json.bak`
- `/mnt/openclaw/workspace`
- `/mnt/openclaw/manager/state.json`
- `/mnt/openclaw/manager/logs/manager.log`
- `/mnt/openclaw/manager/logs/openclaw.log`

The OpenClaw CLI itself stays in the immutable image at `/opt/openclaw-cli`. This avoids hostfs incompatibilities around symlinks and executable-bit updates, while keeping all user state persistent in the mount.

## Operational Notes

- The manager autostarts OpenClaw on container boot only when the gateway had previously been initialized and left in the desired-running state.
- The manager strips its own auth cookie before proxying to OpenClaw.
- The manager handles both HTTP and WebSocket proxying so the hosted Control UI works end-to-end.
- The generated image still defaults to `memory_mb=12288`, matching earlier Nitro runtime observations better than the earlier low baseline.
- On `app-node`, this image-bundled layout has been validated under both plain Docker and real Nitro runtime using Enclaver host-backed mounts.
- The generated `build-enclave` flow uses a helper script instead of raw `enclaver build`, because the larger manager-based image hit a reproducible late-stage `broken pipe` while Enclaver was packaging the release image.

## Future Extensions

- Replace the JSON textarea with a richer model/provider editor
- Add multiple operator accounts instead of the current single-account bootstrap flow
- Add controlled export or rotate actions for a support token if a future API-only use case requires one
- Add platform-specific smoke tests on `app-node` after the new Ubuntu-based image has been validated there
