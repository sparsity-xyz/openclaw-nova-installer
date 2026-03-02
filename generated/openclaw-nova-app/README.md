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

## Nova Platform 提交步骤

1. 将当前目录作为独立 Git 仓库提交（包含 `Dockerfile`、`enclaver.yaml`、`Makefile`）。
2. 在 Nova Platform 中创建 App，填写该 Git 仓库地址。
3. 创建 Build（分支建议 `main`），平台将执行构建并封装 enclave。
4. 创建 Deployment 并发布。
5. 部署完成后访问应用 URL（对应 `ingress.listen_port=18789`）。
