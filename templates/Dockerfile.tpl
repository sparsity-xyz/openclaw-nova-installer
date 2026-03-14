FROM ghcr.io/openclaw/openclaw:latest

USER root

COPY entrypoint.sh /usr/local/bin/openclaw-nova-entrypoint
COPY openclaw.json /etc/openclaw/default-openclaw.json

RUN chmod +x /usr/local/bin/openclaw-nova-entrypoint \
    && mkdir -p /etc/openclaw __MOUNT_PATH__

WORKDIR /app

ENV HOME=__MOUNT_PATH__ \
    OPENCLAW_ROOT_DIR=__MOUNT_PATH__ \
    OPENCLAW_STATE_DIR=__MOUNT_PATH__/state \
    OPENCLAW_WORKSPACE_DIR=__MOUNT_PATH__/workspace \
    OPENCLAW_CONFIG_PATH=__MOUNT_PATH__/openclaw.json \
    OPENCLAW_DEFAULT_CONFIG_PATH=/etc/openclaw/default-openclaw.json \
    OPENCLAW_GATEWAY_PORT=__GATEWAY_PORT__ \
    OPENCLAW_GATEWAY_BIND=lan \
    OPENCLAW_SKIP_CHANNELS=1 \
    OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1 \
    OPENCLAW_SKIP_CANVAS_HOST=1 \
    OPENCLAW_SKIP_GMAIL_WATCHER=1 \
    OPENCLAW_SKIP_CRON=1

EXPOSE __GATEWAY_PORT__

ENTRYPOINT ["/usr/local/bin/openclaw-nova-entrypoint"]
