# OpenClaw Nova Installer 设计

## 目标

用一个脚本自动生成可部署到 Nova Platform 的 OpenClaw 应用包，并默认启用 Web UI。

## 生成内容

installer 生成一个标准 nova-app 目录，包含：

- `Dockerfile`：基于 `ghcr.io/openclaw/openclaw:latest`
- `entrypoint.sh`：注入 token，前台启动 gateway
- `openclaw.json`：最小配置（gateway.mode/local + controlUi）
- `enclaver.yaml`：Nova enclaver 清单（ingress/egress/资源）
- `Makefile`：`build-docker`、`build-enclave`、`run-local`
- `.dockerignore`
- `.gitignore`
- `NOVA_SUBMISSION_CHECKLIST.md`

## 关键设计点

1. **单端口多路复用**
   - OpenClaw Gateway 同时承载 WS + HTTP（Control UI）。
   - `enclaver.yaml` 仅暴露一个 `ingress.listen_port`（默认 18789）。

2. **Enclave 兼容默认值**
   - 默认禁用高风险模块：
     - `OPENCLAW_SKIP_CHANNELS=1`
     - `OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1`
     - `OPENCLAW_SKIP_CANVAS_HOST=1`
   - 避免 systemd/daemon，直接以前台进程运行。

3. **安全默认值**
   - 启动时若未提供 `OPENCLAW_GATEWAY_TOKEN`，自动生成 32-byte hex token。
   - 强制以 token 模式访问 UI/WS。

4. **资源默认值**
   - `cpu_count=2`
   - `memory_mb=4096`
   - 可通过 installer 参数覆盖。

## 脚本参数

`install_openclaw_nova_app.sh` 支持：

- `--output-dir`
- `--app-name`
- `--app-image`
- `--target-image`
- `--gateway-port`
- `--cpu-count`
- `--memory-mb`

## 部署流程（目标态）

1. 在 `openclaw-installer` 运行 installer，生成 app 包
2. 使用 Nova 构建流程执行 `make build-docker` 和 `make build-enclave`
3. 发布到 Nova 平台并部署
4. 用户通过应用 URL 打开 Control UI，使用 token 登录

## 后续增强建议

- 增加 `--enable-channels` 开关，按需恢复渠道连接器
- 增加 S3 快照辅助脚本（状态备份/恢复）
- 增加 health check 与 smoke test 脚本
