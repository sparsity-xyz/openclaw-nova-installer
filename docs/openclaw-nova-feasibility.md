# OpenClaw on Nova Platform Feasibility Study

## Conclusion

Yes, this is feasible, and the manager-based shape is stronger than the older "proxy the published Docker image" approach.

The recommended deployment shape is:

- public manager service on `8000`
- first-run bootstrap on `/setup`
- manager login after bootstrap
- loopback-only OpenClaw gateway on `127.0.0.1:18789`
- `/openclaw` reverse-proxied by the manager
- `gateway.auth.mode="trusted-proxy"` instead of shipping a browser-visible long-lived token

## Why The New Plan Is Better

The public Northflank OpenClaw deployment pattern already validates the general product flow:

- a hosted setup step
- a stable operator-facing path to the Control UI
- a wrapper layer around the internal OpenClaw runtime

The new installer design follows that direction closely, but adapts it to Nova's host-backed mount and Nitro runtime constraints.

## Technical Feasibility

### 1) Installing OpenClaw for Nitro-hosted runtime

Feasible.

The official OpenClaw CLI installer supports both:

- `--prefix <path>`
- `--no-onboard`

However, real Enclaver host-backed mounts on Nitro do not reliably support the symlink and chmod behavior used by Node/npm-style installs. The validated production shape is therefore:

- install the OpenClaw CLI into the image at `/opt/openclaw-cli`
- keep state, config, logs, sessions, and workspace under `/mnt/openclaw`

This preserves persistence where it matters while avoiding mount-level filesystem incompatibilities.

### 2) First-run account registration

Feasible.

This logic belongs in `openclaw-manager`, not in OpenClaw itself. A small wrapper service can safely persist:

- username
- password hash + salt
- manager session secret

inside `/mnt/openclaw/manager/state.json`.

### 3) Reverse-proxying `/openclaw`

Feasible.

The current OpenClaw gateway supports:

- `gateway.controlUi.basePath = "/openclaw"`
- hosted Control UI assets
- WebSocket traffic over the same gateway

So a single manager service can proxy both HTTP and WebSocket traffic to the internal loopback gateway.

### 4) Avoiding exposed gateway tokens

Feasible, and preferable.

Current upstream OpenClaw supports:

- `gateway.auth.mode = "trusted-proxy"`
- `gateway.auth.trustedProxy.userHeader`
- `gateway.auth.trustedProxy.requiredHeaders`
- `gateway.auth.trustedProxy.allowUsers`
- `gateway.trustedProxies`

This lets the manager authenticate the user once, then assert the user identity into OpenClaw over loopback.

An additional upstream benefit is that trusted-proxy operator auth satisfies the Control UI pairing gate, so the browser does not need an extra session approval dance when it comes through the manager.

### 5) Model configuration from the manager

Feasible.

The simplest implementation is to let the manager own a JSON editor for the top-level `models` section, then rewrite `openclaw.json` and restart the gateway. This is much easier than trying to remotely drive interactive CLI onboarding inside the enclave.

## Nitro / Nova Considerations

### Memory

Keep the current installer default at `12288 MiB` until the new Ubuntu-based image has been re-measured on Nitro.

Reason:

- the older OpenClaw-based image already needed roughly this class of runtime memory
- the new manager layer is light, but the OpenClaw gateway remains the dominant memory consumer

### Storage

Host-backed mount storage remains the right solution.

Recommended baseline:

- `size_mb = 10240` minimum
- increase if long-running sessions, logs, caches, or more model artifacts accumulate

### EIF Build vs Run

This concern remains separate from the app redesign:

- EIF build pressure is host-memory bound
- enclave runtime pressure is reserved-enclave-memory bound

So allocator tuning may still need different settings for `enclaver build` and `enclaver run`.

## Recommended Product Direction

Use the manager-based flow and drop the older token-first public gateway exposure model.

That gives us:

- a cleaner hosted UX
- a more defensible auth story for an open-source image
- a deployment shape closer to the public hosted OpenClaw examples
- better alignment with Nova host-backed storage
