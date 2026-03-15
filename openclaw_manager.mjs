#!/usr/bin/env node

import { spawn } from "node:child_process";
import crypto from "node:crypto";
import { createWriteStream, existsSync } from "node:fs";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const MANAGER_PORT = Number(process.env.OPENCLAW_MANAGER_PORT || "8000");
const OPENCLAW_PORT = Number(process.env.OPENCLAW_GATEWAY_PORT || "18789");
const DATA_ROOT = process.env.OPENCLAW_DATA_ROOT || "/mnt/openclaw";
const OPENCLAW_VERSION = process.env.OPENCLAW_VERSION || "latest";
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

const MODEL_WIZARD_TEMPLATES = [
  {
    id: "anthropic",
    label: "Anthropic API key",
    description: "Use the built-in Anthropic provider with an API key, similar to OpenClaw onboarding.",
    providerId: "anthropic",
    apiDefault: "",
    apiEditable: false,
    showApi: false,
    baseUrlDefault: "",
    showBaseUrl: false,
    baseUrlRequired: false,
    apiKeyDefault: "",
    apiKeyRequired: true,
    modelIdDefault: "claude-opus-4-6",
    modelNameDefault: "Claude Opus 4.6",
    includeModelDefault: false,
    modelRequired: false,
    providerIdEditable: false,
  },
  {
    id: "openai",
    label: "OpenAI API key",
    description: "Use the built-in OpenAI provider with a standard OpenAI API key.",
    providerId: "openai",
    apiDefault: "",
    apiEditable: false,
    showApi: false,
    baseUrlDefault: "",
    showBaseUrl: false,
    baseUrlRequired: false,
    apiKeyDefault: "",
    apiKeyRequired: true,
    modelIdDefault: "gpt-5.2",
    modelNameDefault: "GPT-5.2",
    includeModelDefault: false,
    modelRequired: false,
    providerIdEditable: false,
  },
  {
    id: "openrouter",
    label: "OpenRouter",
    description: "Configure the built-in OpenRouter provider with one API key for many hosted models.",
    providerId: "openrouter",
    apiDefault: "",
    apiEditable: false,
    showApi: false,
    baseUrlDefault: "",
    showBaseUrl: false,
    baseUrlRequired: false,
    apiKeyDefault: "",
    apiKeyRequired: true,
    modelIdDefault: "anthropic/claude-sonnet-4-5",
    modelNameDefault: "Claude Sonnet 4.5 via OpenRouter",
    includeModelDefault: false,
    modelRequired: false,
    providerIdEditable: false,
  },
  {
    id: "moonshot",
    label: "Moonshot / Kimi",
    description: "Create the OpenAI-compatible Moonshot provider entry that OpenClaw documents for Kimi.",
    providerId: "moonshot",
    apiDefault: "openai-completions",
    apiEditable: false,
    showApi: true,
    baseUrlDefault: "https://api.moonshot.ai/v1",
    showBaseUrl: true,
    baseUrlRequired: true,
    apiKeyDefault: "",
    apiKeyRequired: true,
    modelIdDefault: "kimi-k2.5",
    modelNameDefault: "Kimi K2.5",
    includeModelDefault: true,
    modelRequired: true,
    providerIdEditable: false,
  },
  {
    id: "ollama",
    label: "Ollama",
    description: "Configure a local or remote Ollama server with OpenClaw's native Ollama API mode.",
    providerId: "ollama",
    apiDefault: "ollama",
    apiEditable: false,
    showApi: true,
    baseUrlDefault: "http://127.0.0.1:11434",
    showBaseUrl: true,
    baseUrlRequired: true,
    apiKeyDefault: "ollama-local",
    apiKeyRequired: true,
    modelIdDefault: "glm-4.7-flash",
    modelNameDefault: "GLM 4.7 Flash",
    includeModelDefault: true,
    modelRequired: true,
    providerIdEditable: false,
  },
  {
    id: "custom-openai",
    label: "Custom OpenAI-compatible",
    description: "For proxies or gateways such as LiteLLM, vLLM, LM Studio, or other OpenAI-compatible services.",
    providerId: "custom-provider",
    apiDefault: "openai-completions",
    apiEditable: true,
    showApi: true,
    baseUrlDefault: "",
    showBaseUrl: true,
    baseUrlRequired: true,
    apiKeyDefault: "",
    apiKeyRequired: true,
    modelIdDefault: "your-model-id",
    modelNameDefault: "Your Model",
    includeModelDefault: true,
    modelRequired: true,
    providerIdEditable: true,
  },
  {
    id: "custom-anthropic",
    label: "Custom Anthropic-compatible",
    description: "For Anthropic-compatible proxies or managed gateways that need a custom base URL.",
    providerId: "custom-provider",
    apiDefault: "anthropic-messages",
    apiEditable: true,
    showApi: true,
    baseUrlDefault: "",
    showBaseUrl: true,
    baseUrlRequired: true,
    apiKeyDefault: "",
    apiKeyRequired: true,
    modelIdDefault: "your-model-id",
    modelNameDefault: "Your Model",
    includeModelDefault: true,
    modelRequired: true,
    providerIdEditable: true,
  },
];

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

function extractCliVersion(output) {
  const text = String(output ?? "").trim();
  if (!text) {
    return "";
  }

  const versionMatch = text.match(/\bv?\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?\b/);
  if (versionMatch) {
    return versionMatch[0].replace(/^v/, "");
  }

  const firstLine = text.split("\n").map((line) => line.trim()).find(Boolean) ?? text;
  const cleaned = firstLine.replace(/^OpenClaw(?:\s+CLI)?(?:\s+version)?[:\s-]*/i, "").trim();
  return cleaned || firstLine;
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

function safeScriptJson(value) {
  return JSON.stringify(value).replaceAll("<", "\\u003c");
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

async function refreshOpenClawCliVersion({ failIfMissing = false } = {}) {
  if (!existsSync(OPENCLAW_BIN)) {
    if (failIfMissing) {
      throw new Error(`OpenClaw CLI is missing from ${OPENCLAW_PREFIX}. Rebuild the image.`);
    }

    if (state.openclaw.cliVersion !== null) {
      state.openclaw.cliVersion = null;
      await saveState();
    }
    return null;
  }

  const version = await runCommandOrThrow(OPENCLAW_BIN, ["--version"], {
    env: openClawEnv(),
  });
  const rawVersion = [version.stdout, version.stderr].map((part) => part.trim()).filter(Boolean).join("\n");
  const cliVersion = extractCliVersion(rawVersion) || OPENCLAW_VERSION;

  if (state.openclaw.cliVersion !== cliVersion) {
    state.openclaw.cliVersion = cliVersion;
    await saveState();
  }

  return cliVersion;
}

async function ensureOpenClawInstalled() {
  await refreshOpenClawCliVersion({ failIfMissing: true });
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

function renderModelWizard() {
  const templateOptions = MODEL_WIZARD_TEMPLATES.map(
    (template) => `<option value="${htmlEscape(template.id)}">${htmlEscape(template.label)}</option>`,
  ).join("");

  return `
    <div class="wizard-toolbar">
      <button type="button" class="secondary" data-model-wizard-open>Open model wizard</button>
      <p class="muted wizard-caption">
        Use a guided flow for common OpenClaw model providers, then review the generated JSON before saving.
      </p>
      <div class="wizard-status muted" data-model-wizard-status></div>
    </div>

    <dialog class="wizard-dialog" data-model-wizard>
      <form class="wizard-form" data-model-wizard-form>
        <div class="wizard-head">
          <div class="wizard-copy">
            <h3>Model setup wizard</h3>
            <p class="muted">
              This mirrors OpenClaw's usual model setup flow: choose a provider, enter auth and endpoint details,
              then insert the generated provider entry into the manager-owned <code>models</code> JSON. OAuth or
              setup-token flows still need to be completed inside OpenClaw itself.
            </p>
          </div>
          <button type="button" class="secondary" data-model-wizard-close>Close</button>
        </div>

        <div class="wizard-grid">
          <label>
            Provider template
            <select data-model-wizard-template>
              ${templateOptions}
            </select>
            <span class="field-help" data-model-wizard-template-help></span>
          </label>

          <label>
            models.mode
            <select data-model-wizard-mode>
              <option value="merge">merge</option>
              <option value="replace">replace</option>
            </select>
            <span class="field-help">Use <code>merge</code> unless you want this config to replace the whole generated catalog.</span>
          </label>

          <label>
            Provider ID
            <input data-model-wizard-provider placeholder="provider-id" />
            <span class="field-help" data-model-wizard-provider-help></span>
          </label>

          <label data-model-wizard-base-url-wrap>
            Base URL
            <input data-model-wizard-base-url placeholder="https://example.com/v1" spellcheck="false" />
            <span class="field-help" data-model-wizard-base-url-help></span>
          </label>

          <label data-model-wizard-api-wrap>
            API adapter
            <select data-model-wizard-api>
              <option value="openai-completions">openai-completions</option>
              <option value="openai-responses">openai-responses</option>
              <option value="anthropic-messages">anthropic-messages</option>
              <option value="google-generative-ai">google-generative-ai</option>
              <option value="ollama">ollama</option>
            </select>
            <span class="field-help" data-model-wizard-api-help></span>
          </label>

          <label>
            API key
            <input type="password" data-model-wizard-api-key autocomplete="off" spellcheck="false" />
            <span class="field-help">Use the plaintext key that should be written into the JSON.</span>
          </label>
        </div>

        <label class="toggle" data-model-wizard-model-toggle-wrap>
          <input type="checkbox" data-model-wizard-include-model />
          Add or update an explicit model entry
        </label>

        <div class="wizard-grid" data-model-wizard-model-fields>
          <label>
            Model ID
            <input data-model-wizard-model-id placeholder="provider/model-id" spellcheck="false" />
            <span class="field-help">The part after <code>provider/</code> in OpenClaw model references.</span>
          </label>

          <label>
            Model name
            <input data-model-wizard-model-name placeholder="Display name" />
            <span class="field-help">Optional label for the OpenClaw model picker.</span>
          </label>

          <label>
            Context length
            <input type="number" min="1" step="1" data-model-wizard-context-window placeholder="128000" />
            <span class="field-help">Recommended when you want a precise context limit instead of relying on the upstream catalog.</span>
          </label>

          <label>
            Max output tokens
            <input type="number" min="1" step="1" data-model-wizard-max-tokens placeholder="8192" />
            <span class="field-help">Optional output token cap for this explicit model entry.</span>
          </label>
        </div>

        <div class="wizard-options" data-model-wizard-model-options>
          <label class="checkbox">
            <input type="checkbox" data-model-wizard-reasoning />
            Mark as a reasoning model
          </label>
          <label class="checkbox">
            <input type="checkbox" data-model-wizard-image />
            Mark as image-capable
          </label>
        </div>

        <p class="muted wizard-note" data-model-wizard-model-note></p>
        <div class="banner error hidden" data-model-wizard-error></div>

        <div class="wizard-preview">
          <div class="kv-key">Generated preview</div>
          <pre data-model-wizard-preview>Choose a template to generate JSON.</pre>
        </div>

        <div class="actions">
          <button type="submit">Apply to JSON editor</button>
          <button type="button" class="secondary" data-model-wizard-reset>Reset wizard</button>
        </div>
      </form>
    </dialog>

    <script type="application/json" id="model-wizard-templates">${safeScriptJson(MODEL_WIZARD_TEMPLATES)}</script>
  `;
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
    select,
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

    .wizard-toolbar {
      display: grid;
      gap: 10px;
      margin-bottom: 16px;
    }

    .wizard-caption,
    .wizard-note {
      margin: 0;
      max-width: 780px;
    }

    .wizard-status {
      min-height: 1.4em;
      font-size: 14px;
    }

    .field-help {
      font-size: 12px;
      line-height: 1.45;
      color: var(--muted);
    }

    .hidden {
      display: none !important;
    }

    .wizard-dialog {
      width: min(860px, calc(100vw - 28px));
      max-width: 860px;
      border: none;
      padding: 0;
      background: transparent;
    }

    .wizard-dialog::backdrop {
      background: rgba(26, 23, 20, 0.48);
      backdrop-filter: blur(6px);
    }

    .wizard-form {
      display: grid;
      gap: 16px;
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 24px;
      box-shadow: var(--shadow);
      padding: 22px;
    }

    .wizard-head {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 18px;
    }

    .wizard-copy p {
      margin: 8px 0 0;
    }

    .wizard-grid {
      display: grid;
      gap: 12px;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    }

    .wizard-options {
      display: flex;
      flex-wrap: wrap;
      gap: 14px;
    }

    .toggle,
    .checkbox {
      display: flex;
      align-items: center;
      gap: 10px;
      font-size: 14px;
      color: var(--ink);
    }

    .toggle input,
    .checkbox input {
      width: auto;
      margin: 0;
      padding: 0;
    }

    .wizard-preview pre {
      min-height: 220px;
      max-height: 320px;
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

      .wizard-head {
        flex-direction: column;
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
  <script>
    (() => {
      const formatter = new Intl.DateTimeFormat(undefined, {
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hourCycle: "h23",
      });

      for (const node of document.querySelectorAll("[data-log-tail]")) {
        const next = node.textContent
          .split("\\n")
          .map((line) => {
            const match = line.match(/^\\[([^\\]]+)\\]\\s?(.*)$/);
            if (!match) {
              return line;
            }

            const date = new Date(match[1]);
            if (Number.isNaN(date.getTime())) {
              return line;
            }

            return \`[\${formatter.format(date)}] \${match[2]}\`;
          })
          .join("\\n");

        node.textContent = next;
      }

      const modelsTextarea = document.querySelector('textarea[name="models_json"]');
      const wizardDialog = document.querySelector("[data-model-wizard]");
      const wizardOpen = document.querySelector("[data-model-wizard-open]");
      const wizardClose = document.querySelector("[data-model-wizard-close]");
      const wizardReset = document.querySelector("[data-model-wizard-reset]");
      const wizardForm = document.querySelector("[data-model-wizard-form]");
      const wizardStatus = document.querySelector("[data-model-wizard-status]");
      const templatesNode = document.getElementById("model-wizard-templates");

      if (modelsTextarea && wizardDialog && wizardOpen && wizardForm && templatesNode) {
        const templates = JSON.parse(templatesNode.textContent);
        const templateMap = new Map(templates.map((template) => [template.id, template]));
        const fields = {
          template: wizardForm.querySelector("[data-model-wizard-template]"),
          templateHelp: wizardForm.querySelector("[data-model-wizard-template-help]"),
          mode: wizardForm.querySelector("[data-model-wizard-mode]"),
          provider: wizardForm.querySelector("[data-model-wizard-provider]"),
          providerHelp: wizardForm.querySelector("[data-model-wizard-provider-help]"),
          baseUrlWrap: wizardForm.querySelector("[data-model-wizard-base-url-wrap]"),
          baseUrl: wizardForm.querySelector("[data-model-wizard-base-url]"),
          baseUrlHelp: wizardForm.querySelector("[data-model-wizard-base-url-help]"),
          apiWrap: wizardForm.querySelector("[data-model-wizard-api-wrap]"),
          api: wizardForm.querySelector("[data-model-wizard-api]"),
          apiHelp: wizardForm.querySelector("[data-model-wizard-api-help]"),
          apiKey: wizardForm.querySelector("[data-model-wizard-api-key]"),
          modelToggleWrap: wizardForm.querySelector("[data-model-wizard-model-toggle-wrap]"),
          includeModel: wizardForm.querySelector("[data-model-wizard-include-model]"),
          modelFields: wizardForm.querySelector("[data-model-wizard-model-fields]"),
          modelOptions: wizardForm.querySelector("[data-model-wizard-model-options]"),
          modelId: wizardForm.querySelector("[data-model-wizard-model-id]"),
          modelName: wizardForm.querySelector("[data-model-wizard-model-name]"),
          contextWindow: wizardForm.querySelector("[data-model-wizard-context-window]"),
          maxTokens: wizardForm.querySelector("[data-model-wizard-max-tokens]"),
          reasoning: wizardForm.querySelector("[data-model-wizard-reasoning]"),
          image: wizardForm.querySelector("[data-model-wizard-image]"),
          modelNote: wizardForm.querySelector("[data-model-wizard-model-note]"),
          error: wizardForm.querySelector("[data-model-wizard-error]"),
          preview: wizardForm.querySelector("[data-model-wizard-preview]"),
        };

        const normalizeModels = (raw) => {
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
        };

        const parseModels = () => {
          let parsed;
          try {
            parsed = JSON.parse(modelsTextarea.value || "{}");
          } catch (error) {
            throw new Error("Current models JSON is invalid: " + error.message);
          }

          if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
            throw new Error("Current models JSON must be an object.");
          }

          return normalizeModels(parsed);
        };

        const currentTemplate = () => templateMap.get(fields.template.value) || templates[0];

        const firstModelEntry = (provider) => {
          if (!provider || typeof provider !== "object" || Array.isArray(provider) || !Array.isArray(provider.models)) {
            return null;
          }

          return provider.models.find((entry) => entry && typeof entry === "object" && !Array.isArray(entry)) || null;
        };

        const readExistingProvider = (models, providerId) => {
          if (!providerId) {
            return {};
          }

          const provider = models.providers && models.providers[providerId];
          if (!provider || typeof provider !== "object" || Array.isArray(provider)) {
            return {};
          }

          return provider;
        };

        const setStatus = (message, tone = "muted") => {
          wizardStatus.textContent = message;
          wizardStatus.classList.remove("muted", "status-ok", "status-bad");
          wizardStatus.classList.add(tone === "error" ? "status-bad" : tone === "success" ? "status-ok" : "muted");
        };

        const clearWizardError = () => {
          fields.error.textContent = "";
          fields.error.classList.add("hidden");
        };

        const showWizardError = (message) => {
          fields.error.textContent = message;
          fields.error.classList.remove("hidden");
        };

        const parsePositiveInteger = (value, label) => {
          const text = String(value || "").trim();
          if (!text) {
            return undefined;
          }

          const number = Number(text);
          if (!Number.isInteger(number) || number <= 0) {
            throw new Error(label + " must be a positive whole number.");
          }

          return number;
        };

        const hasModelOverrides = () =>
          Boolean(
            String(fields.modelId.value || "").trim() ||
              String(fields.modelName.value || "").trim() ||
              String(fields.contextWindow.value || "").trim() ||
              String(fields.maxTokens.value || "").trim() ||
              fields.reasoning.checked ||
              fields.image.checked,
          );

        const syncFieldVisibility = () => {
          const template = currentTemplate();
          const showModelOptions = Boolean(template.modelRequired || fields.includeModel.checked || hasModelOverrides());

          fields.provider.readOnly = !template.providerIdEditable;
          fields.baseUrlWrap.classList.toggle("hidden", !template.showBaseUrl);
          fields.apiWrap.classList.toggle("hidden", !template.showApi);
          fields.modelToggleWrap.classList.toggle("hidden", Boolean(template.modelRequired));
          fields.modelOptions.classList.toggle("hidden", !showModelOptions);

          fields.provider.required = true;
          fields.baseUrl.required = Boolean(template.showBaseUrl && template.baseUrlRequired);
          fields.apiKey.required = Boolean(template.apiKeyRequired);
          fields.api.disabled = !template.apiEditable;
          fields.modelId.required = Boolean(template.modelRequired || fields.includeModel.checked || hasModelOverrides());

          fields.providerHelp.textContent = template.providerIdEditable
            ? "This becomes the prefix in provider/model references."
            : "This template uses the standard OpenClaw provider id.";
          fields.baseUrlHelp.textContent = template.showBaseUrl
            ? template.id === "ollama"
              ? "Use the native Ollama URL without /v1 so tool calling stays reliable."
              : "Paste the upstream API base URL exactly as the provider documents it."
            : "This template uses OpenClaw's built-in default endpoint.";
          fields.apiHelp.textContent = template.showApi ? "This must match the upstream API compatibility mode." : "";
          fields.modelNote.textContent = template.modelRequired
            ? "This template needs an explicit model entry so the generated provider config is complete."
            : hasModelOverrides()
              ? "Because you filled model-specific fields such as context length, the wizard will write one explicit model entry."
              : "Model-specific fields are optional, but context length is often worth setting explicitly. Filling anything below will create or update one explicit model entry.";
        };

        const populateWizard = ({ forceReset = false } = {}) => {
          const template = currentTemplate();
          const currentModels = parseModels();
          const providerId =
            !template.providerIdEditable || forceReset || !String(fields.provider.value || "").trim()
              ? template.providerId
              : String(fields.provider.value || "").trim();
          const existingProvider = readExistingProvider(currentModels, providerId);
          const modelEntry = firstModelEntry(existingProvider);

          clearWizardError();
          fields.mode.value = currentModels.mode === "replace" ? "replace" : "merge";
          fields.templateHelp.textContent = template.description;
          fields.provider.value = providerId;
          fields.provider.placeholder = template.providerId;
          fields.baseUrl.value =
            typeof existingProvider.baseUrl === "string" ? existingProvider.baseUrl : template.baseUrlDefault;
          fields.baseUrl.placeholder = template.baseUrlDefault || "https://example.com/v1";
          fields.api.value =
            typeof existingProvider.api === "string" && existingProvider.api ? existingProvider.api : template.apiDefault;
          fields.apiKey.value =
            typeof existingProvider.apiKey === "string" ? existingProvider.apiKey : template.apiKeyDefault;
          fields.includeModel.checked = Boolean(template.modelRequired || modelEntry || template.includeModelDefault);
          fields.includeModel.disabled = Boolean(template.modelRequired);
          fields.modelId.value =
            typeof modelEntry?.id === "string" ? modelEntry.id : template.modelRequired ? template.modelIdDefault : "";
          fields.modelId.placeholder = template.modelIdDefault || "your-model-id";
          fields.modelName.value =
            typeof modelEntry?.name === "string" ? modelEntry.name : template.modelRequired ? template.modelNameDefault : "";
          fields.modelName.placeholder = template.modelNameDefault || "Display name";
          fields.contextWindow.value =
            Number.isInteger(modelEntry?.contextWindow) && modelEntry.contextWindow > 0 ? String(modelEntry.contextWindow) : "";
          fields.maxTokens.value =
            Number.isInteger(modelEntry?.maxTokens) && modelEntry.maxTokens > 0 ? String(modelEntry.maxTokens) : "";
          fields.reasoning.checked = Boolean(modelEntry?.reasoning);
          fields.image.checked = Array.isArray(modelEntry?.input) && modelEntry.input.includes("image");

          syncFieldVisibility();
        };

        const buildNextModels = () => {
          const template = currentTemplate();
          const currentModels = parseModels();
          const providerId = String(fields.provider.value || "").trim();
          if (!providerId) {
            throw new Error("Provider ID is required.");
          }

          const existingProvider = readExistingProvider(currentModels, providerId);
          const provider = { ...existingProvider };
          const apiKey = String(fields.apiKey.value || "").trim();
          const baseUrl = String(fields.baseUrl.value || "").trim();
          const api = String(fields.api.value || "").trim();
          const includeModel = Boolean(template.modelRequired || fields.includeModel.checked || hasModelOverrides());

          if (template.apiKeyRequired && !apiKey) {
            throw new Error("API key is required for this template.");
          }

          if (template.showBaseUrl && template.baseUrlRequired && !baseUrl) {
            throw new Error("Base URL is required for this template.");
          }

          if (apiKey) {
            provider.apiKey = apiKey;
          } else {
            delete provider.apiKey;
          }

          if (template.showBaseUrl) {
            if (baseUrl) {
              provider.baseUrl = baseUrl;
            } else {
              delete provider.baseUrl;
            }
          }

          if (template.showApi) {
            if (api) {
              provider.api = api;
            } else {
              delete provider.api;
            }
          }

          if (includeModel) {
            const modelId = String(fields.modelId.value || "").trim();
            if (!modelId) {
              throw new Error("Model ID is required when an explicit model entry is enabled.");
            }

            const nextModel = {
              id: modelId,
            };
            const modelName = String(fields.modelName.value || "").trim();
            if (modelName) {
              nextModel.name = modelName;
            }

            const contextWindow = parsePositiveInteger(fields.contextWindow.value, "Context length");
            if (contextWindow !== undefined) {
              nextModel.contextWindow = contextWindow;
            }

            const maxTokens = parsePositiveInteger(fields.maxTokens.value, "Max output tokens");
            if (maxTokens !== undefined) {
              nextModel.maxTokens = maxTokens;
            }

            if (fields.reasoning.checked) {
              nextModel.reasoning = true;
            }

            if (fields.image.checked) {
              nextModel.input = ["text", "image"];
            }

            provider.models = [nextModel];
          } else {
            delete provider.models;
          }

          return {
            ...currentModels,
            mode: fields.mode.value === "replace" ? "replace" : "merge",
            providers: {
              ...currentModels.providers,
              [providerId]: provider,
            },
          };
        };

        const updatePreview = () => {
          try {
            clearWizardError();
            const nextModels = buildNextModels();
            fields.preview.textContent = JSON.stringify(nextModels, null, 2);
          } catch (error) {
            fields.preview.textContent = "Choose a template to generate JSON.";
            showWizardError(error instanceof Error ? error.message : String(error));
          }
        };

        const openWizard = () => {
          try {
            populateWizard({ forceReset: true });
            updatePreview();
            clearWizardError();
            setStatus("", "muted");
            if (typeof wizardDialog.showModal === "function" && !wizardDialog.open) {
              wizardDialog.showModal();
            } else {
              wizardDialog.setAttribute("open", "");
            }
          } catch (error) {
            setStatus(error instanceof Error ? error.message : String(error), "error");
            modelsTextarea.focus();
          }
        };

        const closeWizard = () => {
          if (typeof wizardDialog.close === "function") {
            wizardDialog.close();
          } else {
            wizardDialog.removeAttribute("open");
          }
        };

        wizardOpen.addEventListener("click", openWizard);
        if (wizardClose) {
          wizardClose.addEventListener("click", () => {
            closeWizard();
          });
        }
        if (wizardReset) {
          wizardReset.addEventListener("click", () => {
            try {
              populateWizard({ forceReset: true });
              updatePreview();
            } catch (error) {
              showWizardError(error instanceof Error ? error.message : String(error));
            }
          });
        }

        fields.template.addEventListener("change", () => {
          try {
            populateWizard({ forceReset: true });
            updatePreview();
          } catch (error) {
            showWizardError(error instanceof Error ? error.message : String(error));
          }
        });

        fields.includeModel.addEventListener("change", () => {
          syncFieldVisibility();
          updatePreview();
        });

        const refreshWizard = () => {
          syncFieldVisibility();
          updatePreview();
        };

        fields.provider.addEventListener("input", refreshWizard);
        fields.mode.addEventListener("change", refreshWizard);
        for (const node of [
          fields.baseUrl,
          fields.api,
          fields.apiKey,
          fields.modelId,
          fields.modelName,
          fields.contextWindow,
          fields.maxTokens,
          fields.reasoning,
          fields.image,
        ]) {
          node.addEventListener("input", refreshWizard);
          node.addEventListener("change", refreshWizard);
        }

        wizardForm.addEventListener("submit", (event) => {
          event.preventDefault();

          try {
            const nextModels = buildNextModels();
            const providerId = String(fields.provider.value || "").trim();
            modelsTextarea.value = JSON.stringify(nextModels, null, 2);
            closeWizard();
            setStatus('Updated provider "' + providerId + '" in the JSON editor. Review it below, then save and restart.', "success");
            modelsTextarea.focus();
          } catch (error) {
            showWizardError(error instanceof Error ? error.message : String(error));
          }
        });
      }
    })();
  </script>
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
              <div>${htmlEscape(state.openclaw.cliVersion || (installed ? "Unknown" : "Not installed"))}</div>
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
            <a class="button" href="/openclaw/" target="_blank" rel="noopener noreferrer">Open /openclaw</a>
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
          ${renderModelWizard()}
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
            <pre data-log-tail="manager">${htmlEscape(lastManagerLogs || "No manager logs yet.")}</pre>
          </article>
          <article class="card">
            <h3>OpenClaw log tail</h3>
            <pre data-log-tail="openclaw">${htmlEscape(lastOpenClawLogs || "No OpenClaw logs yet.")}</pre>
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
  try {
    await refreshOpenClawCliVersion();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    logManager(`Failed to detect OpenClaw CLI version: ${message}`);
  }

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
