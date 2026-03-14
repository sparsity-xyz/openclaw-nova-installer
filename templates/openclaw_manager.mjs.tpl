#!/usr/bin/env node

import { spawn } from "node:child_process";
import crypto from "node:crypto";
import { createWriteStream, existsSync } from "node:fs";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const MANAGER_PORT = Number(process.env.OPENCLAW_MANAGER_PORT || "__MANAGER_PORT__");
const OPENCLAW_PORT = Number(process.env.OPENCLAW_GATEWAY_PORT || "__OPENCLAW_PORT__");
const DATA_ROOT = process.env.OPENCLAW_DATA_ROOT || "__MOUNT_PATH__";
const OPENCLAW_VERSION = process.env.OPENCLAW_VERSION || "__OPENCLAW_VERSION__";
const OPENCLAW_PREFIX = process.env.OPENCLAW_CLI_ROOT || "/opt/openclaw-cli";

const MANAGER_DIR = path.join(DATA_ROOT, "manager");
const LOG_DIR = path.join(MANAGER_DIR, "logs");
const STATE_PATH = path.join(MANAGER_DIR, "state.json");
const CONFIG_PATH = path.join(DATA_ROOT, "openclaw.json");
const CONFIG_BAK_PATH = path.join(DATA_ROOT, "openclaw.json.bak");
const WORKSPACE_DIR = path.join(DATA_ROOT, "workspace");
const OPENCLAW_BIN = path.join(OPENCLAW_PREFIX, "bin", "openclaw");

const SESSION_COOKIE = "openclaw_manager_session";
const TRUSTED_PROXY_USER_HEADER = "x-openclaw-user";
const TRUSTED_PROXY_REQUIRED_HEADER = "x-openclaw-authenticated";
const TRUSTED_PROXY_REQUIRED_VALUE = "true";

const recentManagerLogs = [];
const recentOpenClawLogs = [];

let managerLogStream;
let openClawLogStream;
let state = defaultState();
let openClawChild = null;
let openClawStartPromise = null;
let openClawStopPromise = null;
let saveQueue = Promise.resolve();
let autoRestartTimer = null;
let manualStopInFlight = false;
let shuttingDown = false;

function defaultState() {
  return {
    version: 1,
    auth: null,
    openclaw: {
      initializedAt: null,
      desiredRunning: false,
      cliVersion: null,
      lastStartAt: null,
      lastStopAt: null,
      lastExitCode: null,
      lastExitSignal: null,
      lastError: null,
      lastHealthAt: null,
      models: {
        mode: "merge",
        providers: {},
      },
    },
  };
}

function normalizeModels(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return {
      mode: "merge",
      providers: {},
    };
  }

  return {
    ...raw,
    mode: typeof raw.mode === "string" && raw.mode.trim() ? raw.mode.trim() : "merge",
    providers:
      raw.providers && typeof raw.providers === "object" && !Array.isArray(raw.providers)
        ? raw.providers
        : {},
  };
}

function normalizeState(raw) {
  const next = defaultState();

  if (raw && typeof raw === "object") {
    if (raw.auth && typeof raw.auth === "object") {
      next.auth = {
        username: typeof raw.auth.username === "string" ? raw.auth.username : "",
        passwordHash: typeof raw.auth.passwordHash === "string" ? raw.auth.passwordHash : "",
        passwordSalt: typeof raw.auth.passwordSalt === "string" ? raw.auth.passwordSalt : "",
        sessionSecret:
          typeof raw.auth.sessionSecret === "string" ? raw.auth.sessionSecret : randomHex(32),
        createdAt: typeof raw.auth.createdAt === "string" ? raw.auth.createdAt : new Date().toISOString(),
      };
    }

    if (raw.openclaw && typeof raw.openclaw === "object") {
      next.openclaw = {
        ...next.openclaw,
        ...raw.openclaw,
        models: normalizeModels(raw.openclaw.models),
      };
    }
  }

  return next;
}

function randomHex(bytes) {
  return crypto.randomBytes(bytes).toString("hex");
}

function timestamp() {
  return new Date().toISOString();
}

function pushLog(buffer, line) {
  buffer.push(line);
  while (buffer.length > 160) {
    buffer.shift();
  }
}

function logManager(message) {
  const line = `[${timestamp()}] ${message}`;
  pushLog(recentManagerLogs, line);
  console.log(line);
  if (managerLogStream) {
    managerLogStream.write(`${line}\n`);
  }
}

function logOpenClaw(rawChunk) {
  const text = String(rawChunk ?? "").replace(/\r/g, "");
  for (const line of text.split("\n")) {
    if (!line) {
      continue;
    }
    const stamped = `[${timestamp()}] ${line}`;
    pushLog(recentOpenClawLogs, stamped);
    if (openClawLogStream) {
      openClawLogStream.write(`${stamped}\n`);
    }
  }
}

async function ensureLayout() {
  await fs.mkdir(LOG_DIR, { recursive: true });
  await fs.mkdir(WORKSPACE_DIR, { recursive: true });

  if (!managerLogStream) {
    managerLogStream = createWriteStream(path.join(LOG_DIR, "manager.log"), { flags: "a" });
  }
  if (!openClawLogStream) {
    openClawLogStream = createWriteStream(path.join(LOG_DIR, "openclaw.log"), { flags: "a" });
  }
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function copyFilePortable(sourcePath, destinationPath) {
  const contents = await fs.readFile(sourcePath);
  await fs.writeFile(destinationPath, contents);
}

async function loadState() {
  await ensureLayout();
  if (!(await fileExists(STATE_PATH))) {
    state = defaultState();
    return;
  }

  const raw = await fs.readFile(STATE_PATH, "utf8");
  state = normalizeState(JSON.parse(raw));

  const config = await readCurrentConfig();
  if (config?.models) {
    state.openclaw.models = normalizeModels(config.models);
  }
}

async function saveState() {
  saveQueue = saveQueue.then(async () => {
    const next = JSON.stringify(state, null, 2) + "\n";
    const tempPath = `${STATE_PATH}.tmp`;
    await fs.writeFile(tempPath, next, "utf8");
    await fs.rename(tempPath, STATE_PATH);
  });
  return saveQueue;
}

function htmlEscape(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function safeJson(value) {
  return JSON.stringify(value, null, 2);
}

function cleanObject(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => cleanObject(entry)).filter((entry) => entry !== undefined);
  }

  if (!value || typeof value !== "object") {
    return value;
  }

  const next = {};
  for (const [key, entry] of Object.entries(value)) {
    const cleaned = cleanObject(entry);
    if (cleaned !== undefined) {
      next[key] = cleaned;
    }
  }
  return next;
}

function parseCookies(header) {
  const cookies = {};
  for (const chunk of String(header ?? "").split(/;\s*/)) {
    if (!chunk) {
      continue;
    }
    const index = chunk.indexOf("=");
    if (index < 0) {
      continue;
    }
    const key = chunk.slice(0, index).trim();
    const value = chunk.slice(index + 1).trim();
    cookies[key] = decodeURIComponent(value);
  }
  return cookies;
}

function signValue(payload) {
  if (!state.auth?.sessionSecret) {
    return "";
  }
  return crypto.createHmac("sha256", state.auth.sessionSecret).update(payload).digest("base64url");
}

function createSessionValue(username) {
  const payload = Buffer.from(
    JSON.stringify({
      username,
      issuedAt: Date.now(),
    }),
    "utf8",
  ).toString("base64url");
  return `${payload}.${signValue(payload)}`;
}

function readSession(req) {
  if (!state.auth) {
    return null;
  }

  const raw = parseCookies(req.headers.cookie)[SESSION_COOKIE];
  if (!raw) {
    return null;
  }

  const [payload, signature] = raw.split(".");
  if (!payload || !signature) {
    return null;
  }

  const expected = signValue(payload);
  const actualBuffer = Buffer.from(signature);
  const expectedBuffer = Buffer.from(expected);
  if (
    actualBuffer.length !== expectedBuffer.length ||
    !crypto.timingSafeEqual(actualBuffer, expectedBuffer)
  ) {
    return null;
  }

  try {
    const decoded = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    if (decoded.username !== state.auth.username) {
      return null;
    }
    return decoded;
  } catch {
    return null;
  }
}

function setSessionCookie(res) {
  const value = createSessionValue(state.auth.username);
  res.setHeader(
    "Set-Cookie",
    `${SESSION_COOKIE}=${encodeURIComponent(value)}; HttpOnly; SameSite=Lax; Path=/`,
  );
}

function clearSessionCookie(res) {
  res.setHeader(
    "Set-Cookie",
    `${SESSION_COOKIE}=deleted; HttpOnly; SameSite=Lax; Path=/; Max-Age=0`,
  );
}

function redirect(res, location) {
  res.statusCode = 302;
  res.setHeader("Location", location);
  res.end();
}

function sendJson(res, statusCode, payload) {
  res.statusCode = statusCode;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.end(JSON.stringify(payload));
}

function sendHtml(res, statusCode, html) {
  res.statusCode = statusCode;
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.end(html);
}

function isValidUsername(value) {
  return /^[A-Za-z0-9._@-]{3,64}$/.test(value);
}

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString("hex");
}

function verifyPassword(password) {
  if (!state.auth) {
    return false;
  }

  const expected = Buffer.from(state.auth.passwordHash, "hex");
  const actual = Buffer.from(hashPassword(password, state.auth.passwordSalt), "hex");
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

async function readRequestBody(req, limit = 1024 * 1024) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) {
      throw new Error("Request body too large.");
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function readForm(req) {
  const body = await readRequestBody(req);
  return Object.fromEntries(new URLSearchParams(body).entries());
}

async function readCurrentConfig() {
  if (!(await fileExists(CONFIG_PATH))) {
    return null;
  }
  const raw = await fs.readFile(CONFIG_PATH, "utf8");
  return JSON.parse(raw);
}

function currentManagerUser() {
  return state.auth?.username ?? "";
}

function openClawEnv() {
  return {
    ...process.env,
    HOME: DATA_ROOT,
    PATH: `${OPENCLAW_PREFIX}/bin:/opt/node/bin:${process.env.PATH ?? ""}`,
    OPENCLAW_STATE_DIR: DATA_ROOT,
    OPENCLAW_CONFIG_PATH: CONFIG_PATH,
    OPENCLAW_WORKSPACE_DIR: WORKSPACE_DIR,
    SHARP_IGNORE_GLOBAL_LIBVIPS: "1",
    OPENCLAW_SKIP_CHANNELS: "1",
    OPENCLAW_SKIP_BROWSER_CONTROL_SERVER: "1",
    OPENCLAW_SKIP_CANVAS_HOST: "1",
    OPENCLAW_SKIP_GMAIL_WATCHER: "1",
    OPENCLAW_SKIP_CRON: "1",
  };
}

async function runCommand(command, args, options = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd ?? DATA_ROOT,
      env: options.env ?? process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    const captureLimit = options.captureLimit ?? 48 * 1024;

    child.on("error", (error) => {
      reject(error);
    });

    child.stdout.on("data", (chunk) => {
      const text = chunk.toString("utf8");
      stdout = (stdout + text).slice(-captureLimit);
      if (typeof options.onStdout === "function") {
        options.onStdout(text);
      }
    });

    child.stderr.on("data", (chunk) => {
      const text = chunk.toString("utf8");
      stderr = (stderr + text).slice(-captureLimit);
      if (typeof options.onStderr === "function") {
        options.onStderr(text);
      }
    });

    child.on("close", (code, signal) => {
      resolve({
        code,
        signal,
        stdout,
        stderr,
      });
    });
  });
}

async function runCommandOrThrow(command, args, options = {}) {
  const result = await runCommand(command, args, options);
  if (result.code !== 0) {
    const errorText = [result.stderr.trim(), result.stdout.trim()].filter(Boolean).join("\n");
    throw new Error(errorText || `${command} exited with code ${result.code ?? "unknown"}`);
  }
  return result;
}

async function ensureOpenClawInstalled() {
  if (!existsSync(OPENCLAW_BIN)) {
    throw new Error(`OpenClaw CLI is missing from ${OPENCLAW_PREFIX}. Rebuild the image.`);
  }

  const version = await runCommandOrThrow(OPENCLAW_BIN, ["--version"], {
    env: openClawEnv(),
  });
  state.openclaw.cliVersion = version.stdout.trim().split(/\s+/)[0] ?? OPENCLAW_VERSION;
  await saveState();
}

async function ensureOpenClawSetup() {
  await runCommandOrThrow(
    OPENCLAW_BIN,
    ["setup", "--workspace", WORKSPACE_DIR],
    {
      env: openClawEnv(),
      onStdout: logOpenClaw,
      onStderr: logOpenClaw,
    },
  );
}

function buildManagedConfig(existingConfig, models) {
  const gateway = existingConfig.gateway ?? {};
  const trustedProxies = Array.isArray(gateway.trustedProxies) ? gateway.trustedProxies : [];
  const next = {
    ...existingConfig,
    agents: {
      ...(existingConfig.agents ?? {}),
      defaults: {
        ...((existingConfig.agents ?? {}).defaults ?? {}),
        workspace: WORKSPACE_DIR,
      },
    },
    gateway: {
      ...gateway,
      mode: "local",
      bind: "loopback",
      port: OPENCLAW_PORT,
      trustedProxies: Array.from(new Set([...trustedProxies, "127.0.0.1", "::1"])),
      auth: {
        ...((gateway.auth ?? {}) || {}),
        mode: "trusted-proxy",
        token: undefined,
        password: undefined,
        trustedProxy: {
          ...(((gateway.auth ?? {}).trustedProxy ?? {}) || {}),
          userHeader: TRUSTED_PROXY_USER_HEADER,
          requiredHeaders: [TRUSTED_PROXY_REQUIRED_HEADER],
          allowUsers: [currentManagerUser()],
        },
      },
      controlUi: {
        ...((gateway.controlUi ?? {}) || {}),
        enabled: true,
        basePath: "/openclaw",
        dangerouslyAllowHostHeaderOriginFallback: true,
      },
    },
    models: normalizeModels(models),
  };

  return cleanObject(next);
}

async function writeOpenClawConfig(models) {
  const existing = (await readCurrentConfig()) ?? {};
  const next = buildManagedConfig(existing, models);

  if (await fileExists(CONFIG_PATH)) {
    await copyFilePortable(CONFIG_PATH, CONFIG_BAK_PATH);
  }

  await fs.writeFile(CONFIG_PATH, `${safeJson(next)}\n`, "utf8");
}

async function waitForOpenClawHealth(timeoutMs = 20000) {
  const started = Date.now();
  let lastError = "OpenClaw health endpoint did not respond yet.";

  while (Date.now() - started < timeoutMs) {
    try {
      const payload = await new Promise((resolve, reject) => {
        const request = http.get(
          {
            host: "127.0.0.1",
            port: OPENCLAW_PORT,
            path: "/healthz",
            timeout: 3000,
          },
          (response) => {
            let body = "";
            response.setEncoding("utf8");
            response.on("data", (chunk) => {
              body += chunk;
            });
            response.on("end", () => {
              if (response.statusCode !== 200) {
                reject(new Error(`OpenClaw health returned HTTP ${response.statusCode}`));
                return;
              }
              resolve(body);
            });
          },
        );

        request.on("error", reject);
        request.on("timeout", () => {
          request.destroy(new Error("OpenClaw health request timed out"));
        });
      });

      state.openclaw.lastHealthAt = timestamp();
      await saveState();
      return payload;
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
      await new Promise((resolve) => setTimeout(resolve, 750));
    }
  }

  throw new Error(lastError);
}

function scheduleAutoRestart() {
  if (autoRestartTimer || shuttingDown || !state.openclaw.desiredRunning) {
    return;
  }

  autoRestartTimer = setTimeout(async () => {
    autoRestartTimer = null;
    if (shuttingDown || !state.openclaw.desiredRunning || openClawChild || openClawStartPromise) {
      return;
    }

    try {
      logManager("OpenClaw exited unexpectedly; attempting automatic restart.");
      await startOpenClaw();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logManager(`Automatic restart failed: ${message}`);
    }
  }, 2000);
}

async function startOpenClaw() {
  if (openClawChild) {
    return;
  }
  if (openClawStartPromise) {
    return openClawStartPromise;
  }

  if (!existsSync(OPENCLAW_BIN)) {
    throw new Error("OpenClaw is not installed yet.");
  }
  if (!(await fileExists(CONFIG_PATH))) {
    throw new Error("OpenClaw is not initialized yet.");
  }

  if (autoRestartTimer) {
    clearTimeout(autoRestartTimer);
    autoRestartTimer = null;
  }

  state.openclaw.desiredRunning = true;
  state.openclaw.lastError = null;
  await saveState();

  openClawStartPromise = (async () => {
    logManager("Starting OpenClaw gateway.");
    const child = spawn(
      OPENCLAW_BIN,
      [
        "gateway",
        "run",
        "--bind",
        "loopback",
        "--port",
        String(OPENCLAW_PORT),
        "--allow-unconfigured",
      ],
      {
        cwd: DATA_ROOT,
        env: openClawEnv(),
        stdio: ["ignore", "pipe", "pipe"],
      },
    );

    child.stdout.on("data", logOpenClaw);
    child.stderr.on("data", logOpenClaw);

    child.on("error", async (error) => {
      state.openclaw.lastError = error instanceof Error ? error.message : String(error);
      await saveState();
    });

    child.on("exit", async (code, signal) => {
      openClawChild = null;
      state.openclaw.lastExitCode = code;
      state.openclaw.lastExitSignal = signal;
      state.openclaw.lastStopAt = timestamp();
      await saveState();

      if (!manualStopInFlight && !shuttingDown && state.openclaw.desiredRunning) {
        scheduleAutoRestart();
      }
    });

    openClawChild = child;
    state.openclaw.lastStartAt = timestamp();
    await saveState();

    await waitForOpenClawHealth();
  })();

  try {
    await openClawStartPromise;
  } finally {
    openClawStartPromise = null;
  }
}

async function stopOpenClaw({ preserveDesiredRunning = false } = {}) {
  if (!preserveDesiredRunning) {
    state.openclaw.desiredRunning = false;
    await saveState();
  }

  if (!openClawChild) {
    return;
  }
  if (openClawStopPromise) {
    return openClawStopPromise;
  }

  if (autoRestartTimer) {
    clearTimeout(autoRestartTimer);
    autoRestartTimer = null;
  }

  manualStopInFlight = true;
  openClawStopPromise = new Promise((resolve) => {
    const child = openClawChild;
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
    }, 10000);

    child.once("exit", () => {
      clearTimeout(timeout);
      resolve();
    });

    child.kill("SIGTERM");
  });

  try {
    await openClawStopPromise;
  } finally {
    openClawStopPromise = null;
    manualStopInFlight = false;
  }
}

async function restartOpenClaw() {
  state.openclaw.desiredRunning = true;
  await saveState();
  await stopOpenClaw({ preserveDesiredRunning: true });
  await startOpenClaw();
}

async function initializeOpenClaw() {
  await ensureOpenClawInstalled();
  await ensureOpenClawSetup();
  await writeOpenClawConfig(state.openclaw.models);

  state.openclaw.initializedAt = state.openclaw.initializedAt ?? timestamp();
  state.openclaw.desiredRunning = true;
  state.openclaw.lastError = null;
  await saveState();

  await restartOpenClaw();
}

async function currentOpenClawHealth() {
  if (!openClawChild) {
    return {
      ok: false,
      status: "stopped",
      detail: "OpenClaw is not running.",
    };
  }

  try {
    const body = await waitForOpenClawHealth(2500);
    return {
      ok: true,
      status: "live",
      detail: body,
    };
  } catch (error) {
    return {
      ok: false,
      status: "starting",
      detail: error instanceof Error ? error.message : String(error),
    };
  }
}

function noticeFromUrl(url, key) {
  return url.searchParams.get(key) ?? "";
}

function renderShell({ title, subtitle = "", body, notice = "", error = "" }) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${htmlEscape(title)}</title>
  <style>
    :root {
      --bg: #f6efe5;
      --ink: #1a1714;
      --muted: #6d6357;
      --card: rgba(255, 250, 244, 0.92);
      --line: rgba(39, 31, 24, 0.14);
      --accent: #c94f31;
      --accent-dark: #9f3f28;
      --good: #1f7a5b;
      --warn: #ab5d00;
      --bad: #a12d2d;
      --shadow: 0 18px 42px rgba(39, 31, 24, 0.12);
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      font-family: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, rgba(201, 79, 49, 0.18), transparent 30%),
        radial-gradient(circle at top right, rgba(31, 122, 91, 0.12), transparent 28%),
        linear-gradient(180deg, #fbf7f1 0%, var(--bg) 100%);
      min-height: 100vh;
    }

    .page {
      max-width: 1120px;
      margin: 0 auto;
      padding: 32px 20px 48px;
    }

    .hero {
      padding: 24px 0 18px;
    }

    .eyebrow {
      font-size: 12px;
      letter-spacing: 0.16em;
      text-transform: uppercase;
      color: var(--muted);
    }

    h1 {
      margin: 8px 0 8px;
      font-size: clamp(34px, 5vw, 58px);
      line-height: 0.96;
    }

    .subtitle {
      max-width: 760px;
      margin: 0;
      color: var(--muted);
      font-size: 18px;
      line-height: 1.55;
    }

    .stack {
      display: grid;
      gap: 18px;
    }

    .grid {
      display: grid;
      gap: 18px;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    }

    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 24px;
      box-shadow: var(--shadow);
      padding: 22px;
      backdrop-filter: blur(16px);
    }

    .card h2,
    .card h3 {
      margin: 0 0 12px;
      font-size: 24px;
    }

    .muted {
      color: var(--muted);
    }

    .pill {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 12px;
      border-radius: 999px;
      background: rgba(39, 31, 24, 0.06);
      color: var(--muted);
      font-size: 13px;
    }

    .status-ok {
      color: var(--good);
    }

    .status-warn {
      color: var(--warn);
    }

    .status-bad {
      color: var(--bad);
    }

    form {
      display: grid;
      gap: 12px;
    }

    label {
      display: grid;
      gap: 6px;
      font-size: 14px;
      color: var(--muted);
    }

    input,
    textarea {
      width: 100%;
      border: 1px solid rgba(39, 31, 24, 0.16);
      border-radius: 14px;
      padding: 12px 14px;
      font: inherit;
      color: var(--ink);
      background: rgba(255, 255, 255, 0.84);
    }

    textarea {
      min-height: 280px;
      resize: vertical;
      font-family: "SFMono-Regular", "Menlo", monospace;
      font-size: 13px;
      line-height: 1.5;
    }

    button,
    .button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      border: none;
      border-radius: 999px;
      padding: 12px 18px;
      font: inherit;
      cursor: pointer;
      background: var(--accent);
      color: #fff;
      text-decoration: none;
    }

    button.secondary,
    .button.secondary {
      background: rgba(39, 31, 24, 0.08);
      color: var(--ink);
    }

    button:hover,
    .button:hover {
      background: var(--accent-dark);
    }

    button.secondary:hover,
    .button.secondary:hover {
      background: rgba(39, 31, 24, 0.14);
    }

    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
    }

    pre {
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
      background: #14110f;
      color: #f7ead8;
      border-radius: 18px;
      padding: 16px;
      font: 12px/1.6 "SFMono-Regular", "Menlo", monospace;
      min-height: 160px;
      max-height: 360px;
      overflow: auto;
    }

    .banner {
      border-radius: 18px;
      padding: 14px 16px;
      margin-bottom: 16px;
      border: 1px solid rgba(39, 31, 24, 0.1);
    }

    .banner.notice {
      background: rgba(31, 122, 91, 0.12);
      color: var(--good);
    }

    .banner.error {
      background: rgba(161, 45, 45, 0.1);
      color: var(--bad);
    }

    .kv {
      display: grid;
      gap: 12px;
    }

    .kv-row {
      display: grid;
      gap: 4px;
      padding: 12px 0;
      border-top: 1px solid rgba(39, 31, 24, 0.1);
    }

    .kv-row:first-child {
      border-top: none;
      padding-top: 0;
    }

    .kv-key {
      font-size: 12px;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      color: var(--muted);
    }

    .inline-form {
      display: inline;
    }

    @media (max-width: 720px) {
      .page {
        padding: 22px 14px 32px;
      }

      .card {
        padding: 18px;
        border-radius: 20px;
      }
    }
  </style>
</head>
<body>
  <main class="page">
    <section class="hero">
      <div class="eyebrow">OpenClaw Manager</div>
      <h1>${htmlEscape(title)}</h1>
      <p class="subtitle">${htmlEscape(subtitle)}</p>
    </section>
    ${notice ? `<div class="banner notice">${htmlEscape(notice)}</div>` : ""}
    ${error ? `<div class="banner error">${htmlEscape(error)}</div>` : ""}
    ${body}
  </main>
</body>
</html>`;
}

function renderSetupPage({ notice = "", error = "" }) {
  return renderShell({
    title: "First-run account setup",
    subtitle:
      "Create the single manager operator account. After this, the app will only allow username/password login and will use that identity to authorize access to /openclaw.",
    notice,
    error,
    body: `
      <section class="card">
        <h2>Register manager account</h2>
        <form method="post" action="/setup">
          <label>
            Username
            <input name="username" autocomplete="username" placeholder="operator" required />
          </label>
          <label>
            Password
            <input type="password" name="password" autocomplete="new-password" minlength="8" required />
          </label>
          <label>
            Confirm password
            <input type="password" name="confirm_password" autocomplete="new-password" minlength="8" required />
          </label>
          <div class="actions">
            <button type="submit">Create account</button>
          </div>
        </form>
      </section>
    `,
  });
}

function renderLoginPage({ notice = "", error = "" }) {
  return renderShell({
    title: "Sign in to the manager",
    subtitle:
      "The manager owns external authentication. Once signed in, it reverse-proxies /openclaw to the internal OpenClaw gateway with trusted-proxy operator auth.",
    notice,
    error,
    body: `
      <section class="card">
        <h2>Login</h2>
        <form method="post" action="/login">
          <label>
            Username
            <input name="username" autocomplete="username" required />
          </label>
          <label>
            Password
            <input type="password" name="password" autocomplete="current-password" minlength="8" required />
          </label>
          <div class="actions">
            <button type="submit">Login</button>
          </div>
        </form>
      </section>
    `,
  });
}

async function renderDashboardPage(url) {
  const health = await currentOpenClawHealth();
  const modelsJson = safeJson(state.openclaw.models);
  const installed = existsSync(OPENCLAW_BIN);
  const initialized = Boolean(state.openclaw.initializedAt) && (await fileExists(CONFIG_PATH));
  const running = Boolean(openClawChild);
  const lastManagerLogs = recentManagerLogs.slice(-20).join("\n");
  const lastOpenClawLogs = recentOpenClawLogs.slice(-40).join("\n");

  return renderShell({
    title: "Control the Nova deployment",
    subtitle:
      "This manager handles bootstrap, login, OpenClaw installation, config rewrites, and the authenticated reverse proxy to /openclaw.",
    notice: noticeFromUrl(url, "notice"),
    error: noticeFromUrl(url, "error"),
    body: `
      <section class="grid">
        <article class="card">
          <div class="pill">Manager account: ${htmlEscape(currentManagerUser())}</div>
          <h2>Runtime</h2>
          <div class="kv">
            <div class="kv-row">
              <div class="kv-key">OpenClaw installed</div>
              <div class="${installed ? "status-ok" : "status-warn"}">${installed ? "Yes" : "No"}</div>
            </div>
            <div class="kv-row">
              <div class="kv-key">Initialized</div>
              <div class="${initialized ? "status-ok" : "status-warn"}">${initialized ? "Yes" : "No"}</div>
            </div>
            <div class="kv-row">
              <div class="kv-key">Gateway process</div>
              <div class="${running ? "status-ok" : "status-warn"}">${running ? `Running (PID ${openClawChild.pid})` : "Stopped"}</div>
            </div>
            <div class="kv-row">
              <div class="kv-key">Health</div>
              <div class="${health.ok ? "status-ok" : "status-warn"}">${htmlEscape(health.status)}</div>
            </div>
            <div class="kv-row">
              <div class="kv-key">CLI version</div>
              <div>${htmlEscape(state.openclaw.cliVersion || OPENCLAW_VERSION)}</div>
            </div>
            <div class="kv-row">
              <div class="kv-key">Manager port</div>
              <div>${MANAGER_PORT}</div>
            </div>
            <div class="kv-row">
              <div class="kv-key">Internal gateway port</div>
              <div>127.0.0.1:${OPENCLAW_PORT}</div>
            </div>
            <div class="kv-row">
              <div class="kv-key">Last start</div>
              <div>${htmlEscape(state.openclaw.lastStartAt || "Never")}</div>
            </div>
            <div class="kv-row">
              <div class="kv-key">Last error</div>
              <div class="${state.openclaw.lastError ? "status-bad" : "muted"}">${htmlEscape(
                state.openclaw.lastError || "None",
              )}</div>
            </div>
          </div>
        </article>

        <article class="card">
          <h2>Actions</h2>
          <p class="muted">
            Initialize installs OpenClaw with the official CLI installer, runs <code>openclaw setup</code>,
            writes a manager-owned trusted-proxy config, and starts the gateway.
          </p>
          <div class="actions">
            <form class="inline-form" method="post" action="/actions/initialize">
              <button type="submit">Initialize OpenClaw</button>
            </form>
            <form class="inline-form" method="post" action="/actions/restart">
              <button type="submit" class="secondary">Restart gateway</button>
            </form>
            <form class="inline-form" method="post" action="/actions/stop">
              <button type="submit" class="secondary">Stop gateway</button>
            </form>
            <a class="button" href="/openclaw/">Open /openclaw</a>
            <form class="inline-form" method="post" action="/logout">
              <button type="submit" class="secondary">Logout</button>
            </form>
          </div>
        </article>
      </section>

      <section class="stack" style="margin-top: 18px;">
        <article class="card">
          <h2>Model configuration</h2>
          <p class="muted">
            Edit the top-level <code>models</code> section only. The manager preserves and re-applies its
            own gateway fields on every save so the reverse proxy and trusted-proxy auth remain intact.
          </p>
          <form method="post" action="/actions/models">
            <label>
              models JSON
              <textarea name="models_json" spellcheck="false">${htmlEscape(modelsJson)}</textarea>
            </label>
            <div class="actions">
              <button type="submit">Save models and restart</button>
            </div>
          </form>
        </article>

        <section class="grid">
          <article class="card">
            <h3>Manager log tail</h3>
            <pre>${htmlEscape(lastManagerLogs || "No manager logs yet.")}</pre>
          </article>
          <article class="card">
            <h3>OpenClaw log tail</h3>
            <pre>${htmlEscape(lastOpenClawLogs || "No OpenClaw logs yet.")}</pre>
          </article>
        </section>
      </section>
    `,
  });
}

async function handleSetup(req, res) {
  if (state.auth) {
    redirect(res, "/login");
    return;
  }

  if (req.method === "GET") {
    sendHtml(res, 200, renderSetupPage({}));
    return;
  }

  if (req.method !== "POST") {
    sendHtml(res, 405, renderSetupPage({ error: "Method not allowed." }));
    return;
  }

  const form = await readForm(req);
  const username = String(form.username ?? "").trim();
  const password = String(form.password ?? "");
  const confirmPassword = String(form.confirm_password ?? "");

  if (!isValidUsername(username)) {
    sendHtml(
      res,
      400,
      renderSetupPage({
        error: "Username must be 3-64 characters and use letters, digits, dot, underscore, @, or hyphen.",
      }),
    );
    return;
  }

  if (password.length < 8) {
    sendHtml(res, 400, renderSetupPage({ error: "Password must be at least 8 characters." }));
    return;
  }

  if (password !== confirmPassword) {
    sendHtml(res, 400, renderSetupPage({ error: "Passwords do not match." }));
    return;
  }

  const salt = randomHex(16);
  state.auth = {
    username,
    passwordSalt: salt,
    passwordHash: hashPassword(password, salt),
    sessionSecret: randomHex(32),
    createdAt: timestamp(),
  };
  await saveState();

  setSessionCookie(res);
  redirect(res, "/?notice=Manager%20account%20created.%20Initialize%20OpenClaw%20when%20ready.");
}

async function handleLogin(req, res) {
  if (!state.auth) {
    redirect(res, "/setup");
    return;
  }

  if (req.method === "GET") {
    sendHtml(res, 200, renderLoginPage({}));
    return;
  }

  if (req.method !== "POST") {
    sendHtml(res, 405, renderLoginPage({ error: "Method not allowed." }));
    return;
  }

  const form = await readForm(req);
  const username = String(form.username ?? "").trim();
  const password = String(form.password ?? "");

  if (username !== state.auth.username || !verifyPassword(password)) {
    sendHtml(res, 401, renderLoginPage({ error: "Invalid username or password." }));
    return;
  }

  setSessionCookie(res);
  redirect(res, "/?notice=Signed%20in.");
}

async function handleLogout(_req, res) {
  clearSessionCookie(res);
  redirect(res, "/login?notice=Signed%20out.");
}

function requireSession(req, res) {
  if (!readSession(req)) {
    redirect(res, "/login?error=Please%20sign%20in%20first.");
    return false;
  }
  return true;
}

async function handleAction(req, res, pathname) {
  if (!requireSession(req, res)) {
    return;
  }

  try {
    if (pathname === "/actions/initialize") {
      await initializeOpenClaw();
      redirect(res, "/?notice=OpenClaw%20installed,%20configured,%20and%20started.");
      return;
    }

    if (pathname === "/actions/restart") {
      await restartOpenClaw();
      redirect(res, "/?notice=OpenClaw%20restarted.");
      return;
    }

    if (pathname === "/actions/stop") {
      await stopOpenClaw();
      redirect(res, "/?notice=OpenClaw%20stopped.");
      return;
    }

    if (pathname === "/actions/models") {
      const form = await readForm(req);
      let parsed;
      try {
        parsed = JSON.parse(String(form.models_json ?? "{}"));
      } catch (error) {
        redirect(res, `/?error=${encodeURIComponent(`models JSON is invalid: ${error.message}`)}`);
        return;
      }

      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        redirect(res, "/?error=models%20JSON%20must%20be%20an%20object.");
        return;
      }

      if (!(await fileExists(CONFIG_PATH))) {
        redirect(res, "/?error=Initialize%20OpenClaw%20before%20saving%20models.");
        return;
      }

      state.openclaw.models = normalizeModels(parsed);
      await saveState();
      await writeOpenClawConfig(state.openclaw.models);
      await restartOpenClaw();
      redirect(res, "/?notice=Model%20configuration%20saved%20and%20gateway%20restarted.");
      return;
    }

    sendJson(res, 404, { error: "Unknown action." });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    state.openclaw.lastError = message;
    await saveState();
    logManager(`Action ${pathname} failed: ${message}`);
    redirect(res, `/?error=${encodeURIComponent(message)}`);
  }
}

function forwardHeaders(req, username) {
  const headers = {
    ...req.headers,
    host: req.headers.host || `127.0.0.1:${OPENCLAW_PORT}`,
    [TRUSTED_PROXY_USER_HEADER]: username,
    [TRUSTED_PROXY_REQUIRED_HEADER]: TRUSTED_PROXY_REQUIRED_VALUE,
    "x-forwarded-user": username,
    "x-forwarded-host": req.headers.host || "",
    "x-forwarded-proto": String(req.headers["x-forwarded-proto"] || "http"),
  };

  delete headers["content-length"];
  delete headers.cookie;
  delete headers.authorization;
  return headers;
}

async function handleHttpProxy(req, res) {
  const session = readSession(req);
  if (!session) {
    redirect(res, "/login?error=Please%20sign%20in%20to%20open%20OpenClaw.");
    return;
  }

  if (!openClawChild) {
    redirect(res, "/?error=OpenClaw%20is%20not%20running.");
    return;
  }

  const upstream = http.request(
    {
      host: "127.0.0.1",
      port: OPENCLAW_PORT,
      method: req.method,
      path: req.url,
      headers: forwardHeaders(req, session.username),
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.headers);
      upstreamRes.pipe(res);
    },
  );

  upstream.on("error", (error) => {
    logManager(`HTTP proxy error: ${error.message}`);
    if (!res.headersSent) {
      sendJson(res, 502, { error: "Failed to reach the internal OpenClaw gateway." });
    } else {
      res.end();
    }
  });

  req.pipe(upstream);
}

function serializeUpgradeHeaders(req, username) {
  const headers = [];
  const seen = new Set();

  for (let index = 0; index < req.rawHeaders.length; index += 2) {
    const name = req.rawHeaders[index];
    const value = req.rawHeaders[index + 1];
    if (!name || !value) {
      continue;
    }
    const lowered = name.toLowerCase();
    if (
      lowered === TRUSTED_PROXY_USER_HEADER ||
      lowered === TRUSTED_PROXY_REQUIRED_HEADER ||
      lowered === "x-forwarded-user" ||
      lowered === "cookie" ||
      lowered === "authorization"
    ) {
      continue;
    }
    seen.add(lowered);
    headers.push([name, value]);
  }

  if (!seen.has("host")) {
    headers.push(["Host", req.headers.host || `127.0.0.1:${OPENCLAW_PORT}`]);
  }
  headers.push([TRUSTED_PROXY_USER_HEADER, username]);
  headers.push([TRUSTED_PROXY_REQUIRED_HEADER, TRUSTED_PROXY_REQUIRED_VALUE]);
  headers.push(["X-Forwarded-User", username]);
  headers.push(["X-Forwarded-Host", req.headers.host || ""]);
  headers.push(["X-Forwarded-Proto", String(req.headers["x-forwarded-proto"] || "http")]);

  return headers.map(([name, value]) => `${name}: ${value}`).join("\r\n");
}

function handleUpgrade(req, socket, head) {
  if (!(req.url || "").startsWith("/openclaw")) {
    socket.destroy();
    return;
  }

  const session = readSession(req);
  if (!session) {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  if (!openClawChild) {
    socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  const upstream = net.connect(OPENCLAW_PORT, "127.0.0.1");
  upstream.on("connect", () => {
    const requestLine = `GET ${req.url} HTTP/${req.httpVersion}`;
    const headers = serializeUpgradeHeaders(req, session.username);
    upstream.write(`${requestLine}\r\n${headers}\r\n\r\n`);
    if (head.length > 0) {
      upstream.write(head);
    }
    socket.pipe(upstream).pipe(socket);
  });

  upstream.on("error", () => {
    socket.destroy();
  });
}

async function handleRoot(req, res, url) {
  if (!state.auth) {
    redirect(res, "/setup");
    return;
  }

  if (!readSession(req)) {
    redirect(res, "/login");
    return;
  }

  sendHtml(res, 200, await renderDashboardPage(url));
}

async function routeRequest(req, res) {
  const url = new URL(req.url || "/", `http://127.0.0.1:${MANAGER_PORT}`);
  const pathname = url.pathname;

  if (pathname.startsWith("/openclaw")) {
    await handleHttpProxy(req, res);
    return;
  }

  if (pathname === "/healthz") {
    const health = await currentOpenClawHealth();
    sendJson(res, 200, {
      ok: true,
      manager: "live",
      openclaw: health,
      initialized: Boolean(state.openclaw.initializedAt),
      setupComplete: Boolean(state.auth),
    });
    return;
  }

  if (pathname === "/" && req.method === "GET") {
    await handleRoot(req, res, url);
    return;
  }

  if (pathname === "/setup") {
    await handleSetup(req, res);
    return;
  }

  if (pathname === "/login") {
    await handleLogin(req, res);
    return;
  }

  if (pathname === "/logout" && req.method === "POST") {
    await handleLogout(req, res);
    return;
  }

  if (pathname.startsWith("/actions/") && req.method === "POST") {
    await handleAction(req, res, pathname);
    return;
  }

  sendJson(res, 404, { error: "Not found." });
}

async function boot() {
  await ensureLayout();
  await loadState();

  if (
    state.auth &&
    state.openclaw.desiredRunning &&
    state.openclaw.initializedAt &&
    existsSync(OPENCLAW_BIN) &&
    (await fileExists(CONFIG_PATH))
  ) {
    try {
      await startOpenClaw();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      state.openclaw.lastError = message;
      await saveState();
      logManager(`Startup autostart failed: ${message}`);
    }
  }

  const server = http.createServer((req, res) => {
    routeRequest(req, res).catch(async (error) => {
      const message = error instanceof Error ? error.message : String(error);
      logManager(`Unhandled request error: ${message}`);
      if (!res.headersSent) {
        sendJson(res, 500, { error: "Internal server error." });
      } else {
        res.end();
      }
    });
  });

  server.on("upgrade", handleUpgrade);

  const shutdown = async (signal) => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    logManager(`Received ${signal}; shutting down.`);
    server.close();
    await stopOpenClaw();
    managerLogStream?.end();
    openClawLogStream?.end();
    process.exit(0);
  };

  process.on("SIGINT", () => {
    shutdown("SIGINT").catch(() => process.exit(1));
  });
  process.on("SIGTERM", () => {
    shutdown("SIGTERM").catch(() => process.exit(1));
  });

  server.listen(MANAGER_PORT, "0.0.0.0", () => {
    logManager(`Manager listening on http://0.0.0.0:${MANAGER_PORT}`);
    logManager(`Data root: ${DATA_ROOT}`);
    logManager(`OpenClaw loopback: http://127.0.0.1:${OPENCLAW_PORT}`);
    logManager(`Node temp dir: ${os.tmpdir()}`);
  });
}

boot().catch(async (error) => {
  const message = error instanceof Error ? error.stack || error.message : String(error);
  await ensureLayout();
  logManager(`Fatal startup error: ${message}`);
  process.exit(1);
});
