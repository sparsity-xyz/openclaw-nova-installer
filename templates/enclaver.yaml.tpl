version: v1
name: "__APP_NAME__"
target: "__TARGET_IMAGE__"

sources:
  app: "__APP_IMAGE__"

api:
  listen_port: 18000

ingress:
  - listen_port: __GATEWAY_PORT__

egress:
  allow:
    - "**"
    - "0.0.0.0/0"
    - "::/0"

kms_integration:
  enabled: false

storage:
  mounts:
    - name: "__MOUNT_NAME__"
      mount_path: "__MOUNT_PATH__"
      required: true
      size_mb: __MOUNT_SIZE_MB__

defaults:
  cpu_count: __CPU_COUNT__
  memory_mb: __MEMORY_MB__
