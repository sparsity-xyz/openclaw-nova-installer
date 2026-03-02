# OpenClaw Nova App (Generated)

## 1) Build docker image

```bash
make build-docker
```

## 2) Build enclave release image

```bash
make build-enclave
```

## 3) Local smoke test

```bash
make run-local
```

Then open: http://127.0.0.1:18789/

Use token:
- If env `OPENCLAW_GATEWAY_TOKEN` was set, use that.
- Otherwise token is printed in container logs.

## Nova Platform Submission Steps

1. Submit the current directory as a standalone Git repository (including `Dockerfile`, `enclaver.yaml`, `Makefile`).
2. Create an App in the Nova Platform and provide the Git repository address.
3. Create a Build (the `main` branch is recommended), and the platform will execute the build and package the enclave.
4. Create a Deployment and publish it.
5. After the deployment is complete, access the application URL (corresponding to `ingress.listen_port=18789`).
