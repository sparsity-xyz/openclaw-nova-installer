# OpenClaw Manager Nova App (Generated)

This generated app exposes a single public service on port `8000`:

- `GET /setup` for first-run account registration
- `GET /login` for later logins
- `GET /openclaw/` for the OpenClaw Control UI after manager authentication

The image preinstalls OpenClaw with the official CLI installer:

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh | bash -s -- --prefix /opt/openclaw-cli --version latest --no-onboard
```

At runtime, all writable state stays under `/mnt/openclaw`.

## 1) Build docker image

```bash
make build-docker
```

## 2) Build enclave release image

```bash
make build-enclave
```

This helper builds the EIF first, then packages the final `sleeve`-based release image
explicitly. That matches the artifact shape Enclaver expects while avoiding the
`packaging EIF into release image` broken-pipe failure we observed on `app-node`.

## 3) Local smoke test

```bash
make run-local
```

Then open `http://127.0.0.1:8000/setup` to register the first manager account.

## Runtime Layout

- Manager HTTP port: `8000`
- Internal OpenClaw gateway port: `127.0.0.1:18789`
- Manager state: `/mnt/openclaw/manager/state.json`
- OpenClaw config: `/mnt/openclaw/openclaw.json`
- OpenClaw workspace: `/mnt/openclaw/workspace`
- OpenClaw CLI root: `/opt/openclaw-cli`

## Auth Model

The manager owns the internet-facing login flow. OpenClaw itself runs in `gateway.auth.mode=trusted-proxy`, restricted to loopback trusted proxies only.

That means:

- users authenticate with the manager username/password
- the manager reverse-proxies `/openclaw` to the internal gateway
- the browser never needs a long-lived OpenClaw token
- Control UI pairing is skipped because trusted-proxy operator auth is satisfied upstream

## Model Configuration

After login, the dashboard exposes a JSON editor for the top-level `models` section. Saving that form rewrites `openclaw.json`, preserves manager-owned gateway fields, and restarts the gateway.
