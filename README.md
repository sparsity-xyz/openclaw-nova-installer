# OpenClaw Installer for Nova Platform

This directory provides an executable installer to generate an OpenClaw application package (with Web UI) that can be deployed on the Nova Platform.

## Quick Start

```bash
cd openclaw-installer
chmod +x scripts/install_openclaw_nova_app.sh
./scripts/install_openclaw_nova_app.sh
```

By default, it will generate:

- `generated/openclaw-nova-app/Dockerfile`
- `generated/openclaw-nova-app/enclaver.yaml`
- `generated/openclaw-nova-app/openclaw.json`
- `generated/openclaw-nova-app/entrypoint.sh`
- `generated/openclaw-nova-app/Makefile`
- `generated/openclaw-nova-app/.gitignore`
- `generated/openclaw-nova-app/NOVA_SUBMISSION_CHECKLIST.md`

## Custom Resources and Ports

```bash
./scripts/install_openclaw_nova_app.sh \
  --output-dir ./generated/openclaw-nova-app \
  --app-name openclaw-nova \
  --app-image openclaw-nova-app:latest \
  --target-image openclaw-nova:latest \
  --gateway-port 18789 \
  --cpu-count 2 \
  --memory-mb 4096
```

## How to Build After Generation

```bash
cd generated/openclaw-nova-app
make build-docker
make build-enclave
```

`generated/openclaw-nova-app` can be submitted to the Nova Platform directly as the root directory of a standalone Git repository.

## Design and Research Documents

- `docs/openclaw-nova-feasibility.md`
- `docs/openclaw-nova-installer-design.md`
