# OpenClaw 在 Nova Platform 的可行性调研

## 1) 是否能完全自动化安装并提供 Web UI

结论：**可以做到高自动化（80~90%）**。

- OpenClaw 官方支持 Docker 化运行，且 Control UI 默认由 Gateway 同端口提供。
- Nova app 形态与 OpenClaw 单进程 Gateway 很匹配：只需暴露一个 ingress 端口。
- 仍保留少量人工步骤：
  - 设置模型供应商密钥（如 OpenAI/Anthropic）
  - 生产环境下替换网关 token
  - 可选渠道（Telegram/Discord 等）凭据配置

## 2) OpenClaw 技术栈是否能在 Nova 里运行

结论：**核心可运行，部分模块需关闭**。

可运行部分：
- Node.js 22 + OpenClaw Gateway 主进程
- Control UI / WebChat（经 Gateway 同端口）
- 基础 agent/runtime 与工具编排

需要关闭或限制：
- 依赖宿主桌面能力的模块（如 macOS/iOS/Android node、本地 GUI）
- 默认关闭浏览器控制与 Canvas host（减少依赖和资源占用）
- 不建议在 enclave 内使用 systemd/daemon 安装路径，改前台进程运行

## 3) 存储与内存建议

### 内存（运行流畅）

建议分层：
- 最小可用：`2048 MB`
- 推荐：`4096 MB`
- 重负载（多会话/多插件）：`6144 MB`+

依据：
- OpenClaw Docker 文档对构建阶段提示至少 2GB（避免 Node/pnpm OOM）。
- 运行时若启用较多功能（频道、工具、检索）会明显增加堆内存需求。

### 存储

建议分层：
- 镜像与基础运行：`8~12 GB`
- 含会话/日志/缓存的稳定运行：`20 GB`+

说明：
- OpenClaw 默认将状态写入 `$OPENCLAW_STATE_DIR`（默认 `~/.openclaw`）。
- 生产环境需为日志、会话、凭据与插件缓存预留空间。

## 4) 将本地磁盘改写到 S3 的难度

结论：**中高难度（约 7/10）**。

原因：
- OpenClaw 代码大量使用本地文件语义（目录结构、原子写、锁、会话与缓存文件）。
- S3 是对象存储，不具备 POSIX 目录与原子 rename 语义。
- 直接“把文件系统替换为 S3”会影响一致性、时延和并发行为。

可行路线：
- 短期：本地临时盘 + 周期性快照/备份到 S3（低改造）
- 中期：状态分层（热数据本地，冷数据归档 S3）
- 长期：重构状态后端（抽象 storage adapter）

## 5) 哪些模块可能无法在 AWS Nitro Enclave 内运行

高风险/建议舍弃：
- 依赖宿主 OS GUI 或移动设备桥接的模块（macOS/iOS/Android node）
- 需要额外特权、系统服务管理器（systemd/launchd）的守护化流程
- 依赖本地浏览器/图形栈的能力（browser control、部分 canvas 场景）

中风险：
- 某些第三方渠道连接器（依赖外部二进制、长期连接与复杂凭据刷新）

低风险：
- Gateway 核心 + Web UI + 基础聊天/会话能力

---

本调研结合了：
- `enclaver/docs` 对 enclaver 运行模型（ingress/egress、vsock、单应用进程）的描述
- `app-template` 对 nova-app 的构建与部署模式
- OpenClaw 官方 Docker / Gateway / Web 文档与仓库配置惯例
