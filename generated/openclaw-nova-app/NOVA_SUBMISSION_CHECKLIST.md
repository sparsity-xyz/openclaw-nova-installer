# Nova Submission Checklist

- Build the Docker image with `make build-docker`
- Build the EIF with `make build-enclave`
- Confirm `enclaver.yaml` exposes only port `8000`
- Confirm `storage.mounts[0]` points at `/mnt/openclaw`
- Deploy with the host-backed mount named `openclaw`
- After deployment, open `/setup` once to register the manager account
- Log in and run the "Initialize OpenClaw" action before visiting `/openclaw/`
