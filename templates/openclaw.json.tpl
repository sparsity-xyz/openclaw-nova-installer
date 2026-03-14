{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": __GATEWAY_INTERNAL_PORT__,
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "enabled": true,
      "basePath": "/",
      "allowedOrigins": [
        "http://127.0.0.1:__GATEWAY_PORT__",
        "http://localhost:__GATEWAY_PORT__"
      ],
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  },
  "agents": {
    "defaults": {
      "workspace": "__MOUNT_PATH__/workspace"
    }
  }
}
