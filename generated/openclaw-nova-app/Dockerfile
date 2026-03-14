FROM ghcr.io/openclaw/openclaw:latest

USER root

COPY entrypoint.sh /usr/local/bin/openclaw-nova-entrypoint
COPY openclaw.json /etc/openclaw/default-openclaw.json

RUN chmod +x /usr/local/bin/openclaw-nova-entrypoint \
    && mkdir -p /etc/openclaw /mnt/openclaw

WORKDIR /app

ENV HOME=/mnt/openclaw \
    OPENCLAW_ROOT_DIR=/mnt/openclaw \
    OPENCLAW_STATE_DIR=/mnt/openclaw/state \
    OPENCLAW_WORKSPACE_DIR=/mnt/openclaw/workspace \
    OPENCLAW_CONFIG_PATH=/mnt/openclaw/openclaw.json \
    OPENCLAW_DEFAULT_CONFIG_PATH=/etc/openclaw/default-openclaw.json \
    OPENCLAW_GATEWAY_PORT=18789 \
    OPENCLAW_GATEWAY_BIND=lan \
    OPENCLAW_SKIP_CHANNELS=1 \
    OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1 \
    OPENCLAW_SKIP_CANVAS_HOST=1 \
    OPENCLAW_SKIP_GMAIL_WATCHER=1 \
    OPENCLAW_SKIP_CRON=1

EXPOSE 18789

ENTRYPOINT ["/usr/local/bin/openclaw-nova-entrypoint"]
