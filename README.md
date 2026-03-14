# OpenClaw Installer for Nova Platform

This repository now generates a Nova app centered on `openclaw-manager`, not a repackaged `ghcr.io/openclaw/openclaw:latest` image.

The generated runtime uses:

- `ubuntu:24.04` as the base image
- the official OpenClaw CLI installer with `--no-onboard`, executed at image build time
- a host-backed mount at `/mnt/openclaw`
- a manager service on port `8000`
- an internal OpenClaw gateway on `127.0.0.1:18789`
- `gateway.auth.mode=trusted-proxy` so the manager owns internet-facing auth

This matches the hosted product shape used by the public Northflank deployment pattern: bootstrap with `/setup`, then sign in and reach the Control UI through `/openclaw`.

## Quick Start

```bash
chmod +x scripts/install_openclaw_nova_app.sh
./scripts/install_openclaw_nova_app.sh
```

By default, it generates:

- `generated/openclaw-nova-app/Dockerfile`
- `generated/openclaw-nova-app/enclaver.yaml`
- `generated/openclaw-nova-app/openclaw_manager.mjs`
- `generated/openclaw-nova-app/entrypoint.sh`
- `generated/openclaw-nova-app/build_release_image.sh`
- `generated/openclaw-nova-app/Makefile`
- `generated/openclaw-nova-app/README.md`
- `generated/openclaw-nova-app/NOVA_SUBMISSION_CHECKLIST.md`

## Default Runtime Shape

- Public port: `8000`
- First-run registration: `/setup`
- Login: `/login`
- OpenClaw Control UI: `/openclaw/`
- Internal gateway port: `127.0.0.1:18789`
- Data root: `/mnt/openclaw`
- OpenClaw CLI root: `/opt/openclaw-cli`
- OpenClaw config: `/mnt/openclaw/openclaw.json`
- Manager state: `/mnt/openclaw/manager/state.json`

## Why The Architecture Changed

The old approach depended on the published OpenClaw Docker image and then wrapped it with a small proxy. That solved some runtime issues, but it still left three product gaps:

- external auth and first-run bootstrap were awkward
- token ownership was unclear for an open-source deployment
- the deployment shape did not match the hosted `/setup` plus `/openclaw` pattern already used upstream

The new design fixes that by introducing a dedicated manager service.

## Manager Responsibilities

`openclaw-manager` now owns:

- first-run username/password registration
- later username/password login
- verifying the image-bundled OpenClaw CLI and recording its version
- running `openclaw setup`
- writing the manager-owned parts of `openclaw.json`
- updating the top-level `models` section from a JSON editor
- starting, stopping, and restarting the OpenClaw gateway
- reverse-proxying `/openclaw` to `127.0.0.1:18789`

## Trusted-Proxy Auth

The manager no longer relies on handing a long-lived gateway token to the browser.

Instead, the generated config sets:

- `gateway.auth.mode=trusted-proxy`
- `gateway.auth.trustedProxy.userHeader=x-openclaw-user`
- `gateway.auth.trustedProxy.requiredHeaders=["x-openclaw-authenticated"]`
- `gateway.auth.trustedProxy.allowUsers=[<manager username>]`
- `gateway.trustedProxies=["127.0.0.1","::1"]`
- `gateway.controlUi.basePath="/openclaw"`

That lets the manager authenticate users once, then project the authenticated operator identity into the loopback-only OpenClaw gateway. In current upstream OpenClaw, trusted-proxy operator auth also skips the normal Control UI pairing requirement, which is exactly what we want for a hosted wrapper service.

## Customization

```bash
./scripts/install_openclaw_nova_app.sh \
  --output-dir ./generated/openclaw-nova-app \
  --app-name openclaw-manager \
  --app-image openclaw-manager-app:latest \
  --target-image openclaw-manager:latest \
  --manager-port 8000 \
  --openclaw-port 18789 \
  --cpu-count 2 \
  --memory-mb 12288 \
  --openclaw-version latest \
  --mount-name openclaw \
  --mount-path /mnt/openclaw \
  --mount-size-mb 10240
```

## Build Flow

```bash
cd generated/openclaw-nova-app
make build-docker
make build-enclave
make run-local
```

Then open `http://127.0.0.1:8000/setup`.

`make build-enclave` now wraps Enclaver's hidden `--eif-only` mode and then builds the final
`sleeve`-based release image explicitly. That matches what we validated on `app-node`, where the
plain `enclaver build` path hit a late `packaging EIF into release image` broken-pipe failure.

## Notes

- The generated OpenClaw config preserves the user-edited `models` section, but the manager always rewrites the gateway auth, trusted proxy, bind, port, and Control UI base path fields.
- OpenClaw binaries now live in the image at `/opt/openclaw-cli`, while all mutable deployment state stays under `/mnt/openclaw`.
- This change is intentional: Enclaver host-backed mounts do not reliably support the symlink and chmod behavior that a Node/npm-style CLI install expects, so keeping the CLI in the image is the stable Nitro-compatible shape.
- The installer still defaults to `memory_mb=12288`, which matched the earlier Nitro runtime findings better than the original smaller profile.

## Design Docs

- `docs/openclaw-nova-feasibility.md`
- `docs/openclaw-nova-installer-design.md`
