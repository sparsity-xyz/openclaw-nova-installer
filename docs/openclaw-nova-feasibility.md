# OpenClaw on Nova Platform Feasibility Study

## 1) Can it be fully automated and provide a Web UI?

Conclusion: **High automation (80~90%) is achievable**.

- OpenClaw officially supports Dockerized runs, and the Control UI is provided by the Gateway on the same port by default.
- The Nova app form factor matches the OpenClaw single-process Gateway well: only revealing one ingress port is needed.
- A few manual steps remain:
  - Setting up the model provider keys (like OpenAI/Anthropic)
  - Replacing the gateway token for production
  - Optional channel credentials configuration (Telegram/Discord, etc.)

## 2) Can the OpenClaw tech stack run within Nova?

Conclusion: **The core can run, but some modules need to be disabled**.

Runnable parts:
- Node.js 22 + OpenClaw Gateway main process
- Control UI / WebChat (multiplexed via Gateway on the same port)
- Basic agent/runtime and tool orchestration

Needs to be disabled or restricted:
- Modules dependent on host desktop capabilities (e.g., macOS/iOS/Android node, local GUI)
- Browser control and Canvas host should be disabled by default (to reduce dependencies and resource consumption)
- Running via systemd/daemon installation path is not recommended inside the enclave, switch to foreground execution.

## 3) Storage and Memory Recommendations

### Memory (for smooth running)

Suggested tiers:
- Measured Nitro minimum for the current `ghcr.io/openclaw/openclaw:latest` EIF: `10640 MiB`
- Installer default / recommended baseline: `12288 MiB`
- Heavy load (multi-session/multi-plugin): `14336 MiB`+

Reasoning:
- On `app-node` testing dated 2026-03-14, `nitro-cli run-enclave` rejected `4096 MiB` with `E26` and reported that at least `10640 MiB` was required for the generated EIF.
- Enabling multiple features (channels, tools, retrieval) will further increase runtime heap pressure beyond that Nitro minimum.
- EIF packaging is a separate host-memory concern: smaller Nitro nodes may need a lower `allocator.yaml` reservation during `enclaver build` so the host can finish `build-eif`.

### Storage

Suggested tiers:
- Images and base runtime: `8~12 GB`
- Stable running with sessions/logs/cache: `20 GB`+

Explanation:
- OpenClaw writes state to `$OPENCLAW_STATE_DIR` by default (usually `~/.openclaw`).
- Production environments require reserved space for logs, sessions, credentials, and plugin caching.

## 4) Difficulty of changing local disk storage to S3

Conclusion: **Medium-High Difficulty (about 7/10)**.

Reasoning:
- OpenClaw codebase heavily relies on local file semantics (directory structures, atomic writes, locking, session and cache files).
- S3 is an object store and does not provide POSIX directories or atomic rename semantics.
- Directly "replacing the filesystem with S3" would affect consistency, latency, and concurrency behavior.

Feasible Roadmaps:
- Short-term: Use Enclaver/Nova host-backed directory mounts so OpenClaw keeps normal file semantics under `/mnt/openclaw`, with optional snapshots/backups to S3.
- Medium-term: State tiering (hot data stored locally, cold data archived to S3).
- Long-term: Refactor the state backend (abstracting a storage adapter).

## 5) Which modules might fail to run in AWS Nitro Enclaves?

High Risk / Suggested to drop:
- Modules relying on host OS GUI or mobile device bridging (macOS/iOS/Android node)
- Daemonized processes requiring extra privileges or system service managers (systemd/launchd)
- Capabilities depending on the local browser/graphics stack (browser control, certain canvas scenarios)

Medium Risk:
- Certain third-party channel connectors (depending on external binaries, long-lived connections, and complex credential refreshes)

Low Risk:
- Gateway Core + Web UI + basic chat/session capabilities

---

This research combines:
- `enclaver/docs` description of the enclaver runtime model (ingress/egress, vsock, single-app process)
- `app-template` build and deployment patterns for nova-app
- OpenClaw official Docker / Gateway / Web documentation and repository configuration conventions
