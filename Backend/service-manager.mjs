// 功能：为开发者提供 Friday 本地 Realtime 凭证服务的统一管理命令。
// 职责：编排钥匙串配置与读取、模型元数据诊断、普通或代理模式启动、分层状态查询和凭证删除。
// 边界：默认不接受 Shell 中的长期 Key 覆盖；诊断只检查模型元数据，不签发短期凭证或触发模型回复。

import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { userInfo } from "node:os";

const execFileAsync = promisify(execFile);
const currentDirectory = dirname(fileURLToPath(import.meta.url));
const serverPath = resolve(currentDirectory, "server.mjs");
const keychainConfigurePath = resolve(currentDirectory, "keychain-configure.swift");
const keychainService = process.env.FRIDAY_KEYCHAIN_SERVICE
  || "com.example.Friday.OpenAIAPIKey";
const keychainAccount = process.env.FRIDAY_KEYCHAIN_ACCOUNT
  || userInfo().username;
const servicePort = Number.parseInt(process.env.FRIDAY_SESSION_PORT || "8787", 10);
const healthURL = `http://127.0.0.1:${servicePort}/health`;
const readinessURL = `http://127.0.0.1:${servicePort}/ready`;
const command = process.argv[2] || "start";

class OpenAIResponseError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.statusCode = statusCode;
  }
}

try {
  switch (command) {
  case "configure":
    await configureKeychain(false);
    break;
  case "configure-gui":
    await configureKeychain(true);
    break;
  case "start":
    await startService(process.argv.includes("--proxy"));
    break;
  case "doctor":
    await runDoctor(process.argv.includes("--env"));
    break;
  case "status":
    await printStatus();
    break;
  case "forget-key":
    await forgetKey();
    break;
  default:
    throw new Error(`Unknown command: ${command}`);
  }
} catch (error) {
  console.error(publicMessage(error));
  process.exitCode = 1;
}

async function configureKeychain(useGUI) {
  console.log("Store the Friday development API key in macOS Keychain.");
  console.log("The input is hidden and is not written to shell history or this repository.");
  const child = spawn(
    "/usr/bin/xcrun",
    [
      "swift",
      keychainConfigurePath,
      useGUI ? "store-gui" : "store",
      keychainAccount,
      keychainService
    ],
    { stdio: "inherit" }
  );
  const code = await waitForChild(child);
  if (code !== 0) {
    throw new Error("Keychain configuration was cancelled or failed.");
  }
  const apiKey = await readAPIKey();
  console.log("Validating the saved key without creating a Realtime session.");
  try {
    const models = await validateOpenAIModels(apiKey);
    console.log(
      `Friday API key validated and saved (Dictate: ${models.realtimeModel}; `
        + `Talk: ${models.talkModel}).`
    );
  } catch (error) {
    throw new Error(
      `Friday API key was saved in Keychain, but the zero-cost OpenAI check failed. `
        + `The saved value was retained: ${publicMessage(error)}`
    );
  }
}

async function startService(useProxy) {
  const existing = await fetchHealth().catch(() => null);
  if (existing?.status === "ok") {
    console.log(`Friday session service is already listening on ${healthURL}.`);
    console.log("Run npm run status to check OpenAI model readiness separately.");
    return;
  }

  const apiKey = await readAPIKey();
  const args = useProxy ? ["--use-env-proxy", serverPath] : [serverPath];
  const child = spawn(process.execPath, args, {
    cwd: currentDirectory,
    env: {
      ...process.env,
      OPENAI_API_KEY: apiKey
    },
    stdio: "inherit"
  });

  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, () => child.kill(signal));
  }
  const code = await waitForChild(child);
  process.exitCode = code ?? 1;
}

async function runDoctor(useEnvironmentKey) {
  const keySource = useEnvironmentKey ? "explicit --env" : "macOS Keychain";
  const apiKey = useEnvironmentKey ? readEnvironmentAPIKey() : await readAPIKey();
  console.log(`Node: ${process.version}`);
  console.log(`Key source: ${keySource}`);
  console.log(`Health endpoint: ${healthURL}`);
  console.log(`Readiness endpoint: ${readinessURL}`);

  const localHealth = await fetchHealth().catch(() => null);
  if (localHealth?.status === "ok") {
    console.log("Local service: listening");
    const readiness = await fetchReadiness().catch((error) => {
      throw new Error(
        `Local service is listening, but OpenAI models are not ready: ${publicMessage(error)}`
      );
    });
    console.log(
      `OpenAI: ready (Dictate: ${readiness.model}; `
        + `Talk: ${readiness.talk_model || "not reported"})`
    );
    console.log(`Local sessions issued: ${readiness.sessions_issued ?? "not reported"}`);
    console.log(
      `Account balance: ${readiness.account_balance_readable
        ? "reported by provider"
        : "not readable with the configured Project API key"}`
    );
    return;
  }

  console.log("Local service: not running; checking OpenAI without creating a Realtime session.");
  const { realtimeModel, talkModel } = await validateOpenAIModels(apiKey);
  console.log(`OpenAI: ready (Dictate: ${realtimeModel}; Talk: ${talkModel})`);
  console.log("Next: run npm start and keep that terminal open while testing Friday.");
}

async function printStatus() {
  const health = await fetchHealth();
  console.log("Local service: listening");
  try {
    const readiness = await fetchReadiness();
    console.log(
      `OpenAI models: ready (Dictate: ${readiness.model}; `
        + `Talk: ${readiness.talk_model || "not reported"})`
    );
    console.log(JSON.stringify({ local: health, readiness }, null, 2));
  } catch (error) {
    const message = publicMessage(error);
    console.log(`OpenAI models: unavailable (${message})`);
    console.log(JSON.stringify({
      local: health,
      readiness: { status: "unavailable", error: message }
    }, null, 2));
    process.exitCode = 1;
  }
}

async function forgetKey() {
  try {
    await deleteKeychainItem();
    console.log("Friday API key removed from macOS Keychain.");
  } catch (error) {
    if (error?.code === 44) {
      console.log("No Friday API key was stored in macOS Keychain.");
      return;
    }
    throw error;
  }
}

function readEnvironmentAPIKey() {
  const apiKey = process.env.OPENAI_API_KEY?.trim();
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is not set for the explicit --env command.");
  }
  validateAPIKey(apiKey);
  return apiKey;
}

async function readAPIKey() {
  try {
    const { stdout } = await execFileAsync(
      "/usr/bin/security",
      ["find-generic-password", "-a", keychainAccount, "-s", keychainService, "-w"],
      { encoding: "utf8", maxBuffer: 16_384 }
    );
    const apiKey = stdout.trim();
    validateAPIKey(apiKey);
    return apiKey;
  } catch (error) {
    if (error?.code === 44) {
      throw new Error("No Friday API key is configured. Run npm run configure first.");
    }
    throw error;
  }
}

function validateAPIKey(apiKey) {
  if (!apiKey.startsWith("sk-") || apiKey.length < 20 || /\s/.test(apiKey)) {
    throw new Error("The configured OpenAI API key has an invalid format. Run npm run configure again.");
  }
}

async function validateOpenAIModels(apiKey) {
  const realtimeModel = process.env.FRIDAY_REALTIME_MODEL || "gpt-realtime-2.1";
  const talkModel = process.env.FRIDAY_TALK_MODEL || "gpt-realtime-2.1";
  const baseURL = process.env.OPENAI_BASE_URL || "https://api.openai.com";
  for (const model of new Set([realtimeModel, talkModel])) {
    const response = await fetch(`${baseURL}/v1/models/${encodeURIComponent(model)}`, {
      headers: {
        Authorization: `Bearer ${apiKey}`,
        Accept: "application/json"
      },
      signal: AbortSignal.timeout(8_000)
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new OpenAIResponseError(
        response.status,
        payload?.error?.message
          || `OpenAI model check failed for ${model} with HTTP ${response.status}.`
      );
    }
  }
  return { realtimeModel, talkModel };
}

async function deleteKeychainItem() {
  await execFileAsync(
    "/usr/bin/security",
    ["delete-generic-password", "-a", keychainAccount, "-s", keychainService]
  );
}

async function fetchHealth() {
  return fetchServiceStatus(healthURL, 1_500);
}

async function fetchReadiness() {
  return fetchServiceStatus(readinessURL, 4_500);
}

async function fetchServiceStatus(url, timeoutMilliseconds) {
  const response = await fetch(url, {
    headers: { Accept: "application/json" },
    signal: AbortSignal.timeout(timeoutMilliseconds)
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || payload.status !== "ok") {
    throw new Error(payload.error || `Friday service returned HTTP ${response.status}.`);
  }
  return payload;
}

function waitForChild(child) {
  return new Promise((resolvePromise, rejectPromise) => {
    child.once("error", rejectPromise);
    child.once("exit", resolvePromise);
  });
}

function publicMessage(error) {
  const message = error instanceof Error ? error.message : String(error);
  return message
    .replace(/sk-[A-Za-z0-9_.*-]+/g, "[REDACTED_API_KEY]")
    .replace(/Bearer\s+[A-Za-z0-9._-]+/gi, "Bearer [REDACTED]");
}
