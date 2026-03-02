# OpenClaw Installer for Nova Platform

这个目录提供一个可执行的 installer，用于生成可在 Nova Platform 上部署的 OpenClaw 应用包（含 Web UI）。

## 快速开始

```bash
cd openclaw-installer
chmod +x scripts/install_openclaw_nova_app.sh
./scripts/install_openclaw_nova_app.sh
```

默认会生成：

- `generated/openclaw-nova-app/Dockerfile`
- `generated/openclaw-nova-app/enclaver.yaml`
- `generated/openclaw-nova-app/openclaw.json`
- `generated/openclaw-nova-app/entrypoint.sh`
- `generated/openclaw-nova-app/Makefile`
- `generated/openclaw-nova-app/.gitignore`
- `generated/openclaw-nova-app/NOVA_SUBMISSION_CHECKLIST.md`

## 自定义资源与端口

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

## 生成后如何构建

```bash
cd generated/openclaw-nova-app
make build-docker
make build-enclave
```

`generated/openclaw-nova-app` 可以直接作为独立 Git 仓库根目录提交到 Nova Platform。

## 设计与调研文档

- `docs/openclaw-nova-feasibility.md`
- `docs/openclaw-nova-installer-design.md`
# openclaw-nova-installer
