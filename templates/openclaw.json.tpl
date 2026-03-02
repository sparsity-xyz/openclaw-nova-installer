{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": __GATEWAY_PORT__,
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "enabled": true,
      "basePath": "/"
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/opt/openclaw/workspace"
    }
  }
}
