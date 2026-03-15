FROM ubuntu:24.04

SHELL ["/bin/bash", "-lc"]

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_VERSION=22.22.0 \
    OPENCLAW_NODE_VERSION=22.22.0 \
    OPENCLAW_CLI_ROOT=/opt/openclaw-cli \
    OPENCLAW_MANAGER_PORT=8000 \
    OPENCLAW_GATEWAY_PORT=18789 \
    OPENCLAW_DATA_ROOT=/mnt/openclaw \
    OPENCLAW_VERSION=latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      openssl \
      python3 \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
      amd64) node_arch="x64" ;; \
      arm64) node_arch="arm64" ;; \
      *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz \
    && mkdir -p /opt/node \
    && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 \
    && rm -f /tmp/node.tar.xz

ENV PATH=/opt/node/bin:${PATH}

RUN curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh \
    | bash -s -- \
      --prefix "${OPENCLAW_CLI_ROOT}" \
      --version "${OPENCLAW_VERSION}" \
      --node-version "${OPENCLAW_NODE_VERSION}" \
      --no-onboard

COPY entrypoint.sh /usr/local/bin/openclaw-nova-entrypoint
COPY openclaw_manager.mjs /usr/local/bin/openclaw-manager.mjs

RUN chmod +x /usr/local/bin/openclaw-nova-entrypoint \
    && chmod +x /usr/local/bin/openclaw-manager.mjs \
    && mkdir -p /mnt/openclaw/manager /mnt/openclaw/workspace

WORKDIR /app

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/openclaw-nova-entrypoint"]
