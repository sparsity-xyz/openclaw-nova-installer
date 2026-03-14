# Nova Submission Checklist

- [ ] Repository root contains `Dockerfile`, `enclaver.yaml`, `Makefile`
- [ ] `make build-docker` succeeds locally
- [ ] `make build-enclave` succeeds in CI/build env
- [ ] Docker tag in Makefile matches `enclaver.yaml -> sources.app` (openclaw-nova-app:latest)
- [ ] Ingress port matches app port in Nova create-app form (18789)
- [ ] `enclaver.yaml -> storage.mounts[0]` is present with:
  - `name=openclaw`
  - `mount_path=/mnt/openclaw`
  - `size_mb=10240`
- [ ] Runtime secret configured:
  - OPENCLAW_GATEWAY_TOKEN (recommended explicit value)
  - provider API keys if needed

Expected running result:
- OpenClaw Gateway + Control UI reachable on deployed app URL.
- OpenClaw data persists inside the deployment's host-backed directory mounted at /mnt/openclaw.
