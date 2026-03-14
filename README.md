# OpenClaw Installer for Nova Platform

This directory provides an executable installer to generate an OpenClaw application package (with Web UI) that can be deployed on the Nova Platform.

The generated app is aligned with the latest Enclaver/Nova host-backed directory mount flow: it declares `storage.mounts[]` in `enclaver.yaml` and runs OpenClaw against a mounted data root at `/mnt/openclaw`.

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
  --memory-mb 4096 \
  --mount-name openclaw \
  --mount-path /mnt/openclaw \
  --mount-size-mb 10240
```

## How to Build After Generation

```bash
cd generated/openclaw-nova-app
make build-docker
make build-enclave
```

`generated/openclaw-nova-app` can be submitted to the Nova Platform directly as the root directory of a standalone Git repository.

## Host-backed Mount Defaults

- The installer now generates `storage.mounts[]` with `name=openclaw`, `mount_path=/mnt/openclaw`, `required=true`, and `size_mb=10240`.
- OpenClaw state, workspace, and runtime config are bootstrapped under `/mnt/openclaw`.
- On Nova, the runtime should launch the enclave with a matching `--mount openclaw=<host_state_dir>` binding.
- For local Docker smoke tests, the generated `make run-local` target uses `./openclaw-data:/mnt/openclaw` to simulate the mounted directory.

## Design and Research Documents

- `docs/openclaw-nova-feasibility.md`
- `docs/openclaw-nova-installer-design.md`
