# OpenClaw Manager for Nova Platform

OpenClaw Manager is a Nova app for hosting and operating OpenClaw behind a managed web control
plane.

It gives you a single public entrypoint for:

- first-run account setup at `/setup`
- manager login at `/login`
- OpenClaw initialization
- gateway start, stop, and restart
- managed updates to `openclaw.json`
- authenticated access to the OpenClaw Control UI at `/openclaw/`

Internally, the app keeps the OpenClaw CLI in the image at `/opt/openclaw-cli`, persists runtime
state on a host-backed mount at `/mnt/openclaw`, and runs the OpenClaw gateway only on
`127.0.0.1:18789`.

## Deploy on Nova Platform

### 1) Create App

Create the Nova app from this repository root.

At the `Create App` stage, configure:

- ingress port: `8000`
- host-backed mount name: `openclaw`
- host-backed mount path: `/mnt/openclaw`
- host-backed mount size: `10240 MiB` minimum

Those settings define the app's persistent storage and public network entrypoint.

### 2) Build Version

After the app exists, build a version from this repository.

Nova should build from the checked-in root files, including:

- `Dockerfile`
- `enclaver.yaml`

### 3) Deploy Version

When deploying a built version, select:

- compute tier: `Performance`

Do not use the `Standard` tier for this app.

Keep outbound egress enabled for this app. Inside a Nova enclave, OpenClaw Manager and the
OpenClaw CLI cannot reach the internet directly; outbound HTTP/HTTPS traffic must go through the
Enclaver/Odyn egress proxy.

When `egress` is enabled, Odyn automatically injects these standard proxy variables into the app
process before `entrypoint.sh` starts:

- `http_proxy`, `https_proxy`, `HTTP_PROXY`, `HTTPS_PROXY`
- `no_proxy`, `NO_PROXY`

For the normal Nova deployment path, you do not need to add custom proxy environment variables by
hand. The important requirement is that egress stays enabled and the destinations OpenClaw needs
are allowed by [enclaver.yaml](/Users/zfdang/workspaces/openclaw-nova-installer/enclaver.yaml).

### 4) Finish Setup

After the version is deployed:

- open `https://<your-app>/setup`
- create the first manager account
- sign in to the manager dashboard
- click `Initialize OpenClaw`
- review or edit the `models` JSON
- click `Open /openclaw` to open the Control UI in a new tab

If `/setup` loads but OpenClaw later fails to initialize, first double-check:

- the app was created with the required host-backed mount
- the deployed version is using the `Performance` tier
- outbound egress is enabled and the required destinations are allowed by [enclaver.yaml](/Users/zfdang/workspaces/openclaw-nova-installer/enclaver.yaml)

If OpenClaw itself reports network access problems and needs an explicit proxy configuration, use
the Enclaver egress proxy values directly:

- HTTP proxy: `http://127.0.0.1:10000`
- HTTPS proxy: `http://127.0.0.1:10000`
- `NO_PROXY`: `localhost,127.0.0.1`

This repo does not override `egress.proxy_port` in [enclaver.yaml](/Users/zfdang/workspaces/openclaw-nova-installer/enclaver.yaml), so it uses Enclaver's default proxy port `10000`.

## Local Development

For local validation from the repo root:

```bash
make build-docker
make run-local
```

`make run-local` runs this app in ordinary Docker, not inside Enclaver. If your local Docker
environment already needs an outbound proxy, export the usual proxy variables before starting the
container:

```bash
export http_proxy=http://proxy.example.com:7890
export https_proxy=http://proxy.example.com:7890
export no_proxy=127.0.0.1,localhost
make run-local
```

Then open `http://127.0.0.1:8000/setup`.

`make build-enclave` is available if you want to build the EIF and final release image locally.

## Runtime Layout

- public manager port: `8000`
- OpenClaw gateway: `127.0.0.1:18789`
- data root: `/mnt/openclaw`
- manager state: `/mnt/openclaw/manager/state.json`
- manager logs: `/mnt/openclaw/manager/logs/manager.log`
- OpenClaw logs: `/mnt/openclaw/manager/logs/openclaw.log`
- OpenClaw config: `/mnt/openclaw/openclaw.json`
- OpenClaw workspace: `/mnt/openclaw/workspace`
- OpenClaw CLI root: `/opt/openclaw-cli`

## Reference

- `docs/openclaw-nova-installer-design.md`
