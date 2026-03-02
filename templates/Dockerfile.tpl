FROM ghcr.io/openclaw/openclaw:latest

USER root

COPY entrypoint.sh /usr/local/bin/openclaw-nova-entrypoint
COPY openclaw.json /opt/openclaw/openclaw.json

RUN chmod +x /usr/local/bin/openclaw-nova-entrypoint \
    && mkdir -p /opt/openclaw/state /opt/openclaw/workspace \
    && chown -R node:node /opt/openclaw

USER node

WORKDIR /app

ENV OPENCLAW_STATE_DIR=/opt/openclaw/state \
    OPENCLAW_WORKSPACE_DIR=/opt/openclaw/workspace \
    OPENCLAW_CONFIG_PATH=/opt/openclaw/openclaw.json \
    OPENCLAW_GATEWAY_PORT=__GATEWAY_PORT__ \
    OPENCLAW_GATEWAY_BIND=lan \
    OPENCLAW_SKIP_CHANNELS=1 \
    OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1 \
    OPENCLAW_SKIP_CANVAS_HOST=1 \
    OPENCLAW_SKIP_GMAIL_WATCHER=1 \
    OPENCLAW_SKIP_CRON=1

EXPOSE __GATEWAY_PORT__

ENTRYPOINT ["/usr/local/bin/openclaw-nova-entrypoint"]
