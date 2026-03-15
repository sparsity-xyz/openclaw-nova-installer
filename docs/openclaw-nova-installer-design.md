# OpenClaw Manager Nova App Design

## Objective

This repository should be deployable on Nova as-is.

The repo root contains the Nova app:

- `Dockerfile`
- `enclaver.yaml`
- `entrypoint.sh`
- `openclaw_manager.mjs`

No secondary generated app directory is required.

## Runtime Components

### `openclaw-manager`

- listens on port `8000`
- serves `/setup`, `/login`, and the dashboard
- initializes OpenClaw on first use
- manages start, stop, and restart actions
- reverse-proxies `/openclaw` to the loopback gateway

### OpenClaw Gateway

- installed into `/opt/openclaw-cli` during image build
- started by the manager only after initialization
- bound to `127.0.0.1:18789`
- configured through `/mnt/openclaw/openclaw.json`

## Root-Level Files

- `Dockerfile`
  Builds the Ubuntu-based application image and installs Node plus the OpenClaw CLI.

- `entrypoint.sh`
  Prepares mount directories and launches the manager.

- `openclaw_manager.mjs`
  Implements the manager UI, login flow, config ownership, process supervision, and `/openclaw`
  reverse proxy.

- `enclaver.yaml`
  Declares ingress, egress, storage, and default resource hints for the Nova deployment.

- `Makefile`
  Provides local `build-docker`, `build-enclave`, and `run-local` helpers.

- `build_release_image.sh`
  Builds the EIF and packages the final release image for local release validation.

## Nova Workflow

Nova should use this repository root directly as the app source.

### Create App

At app creation time, configure:

- ingress port `8000`
- host-backed mount name `openclaw`
- host-backed mount path `/mnt/openclaw`
- host-backed mount size `10240 MiB` minimum

These settings define the persistent storage and public entrypoint for the app.

### Build Version

Build versions directly from this repository root.

Nova should consume the checked-in:

- `Dockerfile`
- `enclaver.yaml`

No generated sub-application directory is required.

### Deploy Version

At deploy time, choose the Nova `Performance` tier.

This app is not a good fit for the `Standard` tier because the OpenClaw gateway is the main
runtime memory consumer.

## Manager Flow

### First Boot

- `/setup` creates the first manager account
- credentials are stored in `/mnt/openclaw/manager/state.json`
- the manager redirects the operator to the dashboard

### Initialization

When the operator clicks `Initialize OpenClaw`, the manager:

1. verifies the bundled OpenClaw CLI
2. runs `openclaw setup --workspace /mnt/openclaw/workspace`
3. writes manager-owned gateway settings into `openclaw.json`
4. starts the OpenClaw gateway on loopback

### Normal Operation

After initialization, the dashboard can:

- open `/openclaw/` in a new tab
- restart or stop the gateway
- show manager and OpenClaw log tails
- edit the top-level `models` JSON and restart the gateway

## Auth Model

The manager owns the public authentication flow.

OpenClaw runs with trusted-proxy auth enabled and only accepts proxied requests from loopback.
The manager injects the required trusted-proxy headers after its own login succeeds, so the
browser never connects directly to a public OpenClaw socket.

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

## Storage Layout

All mutable state lives under `/mnt/openclaw`:

- `/mnt/openclaw/openclaw.json`
- `/mnt/openclaw/openclaw.json.bak`
- `/mnt/openclaw/workspace`
- `/mnt/openclaw/manager/state.json`
- `/mnt/openclaw/manager/logs/manager.log`
- `/mnt/openclaw/manager/logs/openclaw.log`

## Runtime Proxy Environment

Inside Nova, outbound HTTP/HTTPS from the enclave always flows through Enclaver/Odyn's egress
proxy. The app does not have direct internet access.

When `egress` is enabled, Odyn injects these variables before `entrypoint.sh` launches the
manager:

- `http_proxy`, `https_proxy`, `HTTP_PROXY`, `HTTPS_PROXY`
- `no_proxy`, `NO_PROXY`

Those values point to `http://127.0.0.1:<proxy_port>` and keep `localhost,127.0.0.1` off the
proxy path. This app assumes Odyn has already injected them before the manager starts.

Operators do not need to define custom proxy environment variables for the normal Nova deployment
path. The key requirement is that `egress` remains enabled and the manifest allows the external
destinations OpenClaw needs.

## Operational Notes

- the manager only autostarts OpenClaw on boot after a successful prior initialization
- the manager strips its own auth cookie before proxying to OpenClaw
- the manager handles both HTTP and WebSocket proxying for `/openclaw`
- on Nova's current deployment UI, tier selection happens at `Deploy Version`
