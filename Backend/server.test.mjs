// 功能：验证本地 Realtime 凭证服务的 HTTP 契约、会话配置和安全保护是否符合预期。
// 职责：启动本地假 OpenAI 上游，覆盖凭证签发、Talk 参数、累计计数、异常重试循环、错误脱敏和 doctor 诊断。
// 边界：测试不读取真实 API Key，不访问真实 OpenAI，也不创建付费模型响应。

import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const backendDirectory = dirname(fileURLToPath(import.meta.url));
const serverPath = resolve(backendDirectory, "server.mjs");
const serviceManagerPath = resolve(backendDirectory, "service-manager.mjs");

test("session service issues credentials without a cumulative cap and tracks local usage", async (t) => {
  let credentialBody = null;
  const upstream = createServer(async (request, response) => {
    if (request.method === "GET"
        && new Set([
          "/v1/models/gpt-realtime",
          "/v1/models/gpt-realtime-2.1"
        ]).has(request.url)) {
      return sendJSON(response, 200, { id: request.url.split("/").at(-1) });
    }
    if (request.method === "POST" && request.url === "/v1/realtime/client_secrets") {
      credentialBody = JSON.parse(await readBody(request));
      return sendJSON(response, 200, {
        value: "ek_test_ephemeral",
        expires_at: 1_900_000_000,
        session: { model: "gpt-realtime-2.1" }
      });
    }
    sendJSON(response, 404, { error: { message: "not found" } });
  });
  const upstreamPort = await listenOnRandomPort(upstream);
  t.after(() => upstream.close());

  const servicePort = await unusedPort();
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "friday-backend-test-"));
  const budgetFile = join(temporaryDirectory, "budget.json");
  t.after(() => rm(temporaryDirectory, { recursive: true, force: true }));

  const service = spawn(process.execPath, [serverPath], {
    cwd: backendDirectory,
    env: {
      ...process.env,
      OPENAI_API_KEY: "sk-test-backend-key-000000000000",
      OPENAI_BASE_URL: `http://127.0.0.1:${upstreamPort}`,
      FRIDAY_SESSION_PORT: String(servicePort),
      FRIDAY_CREDENTIAL_BURST_LIMIT: "10",
      FRIDAY_BUDGET_FILE: budgetFile,
      FRIDAY_INPUT_TRANSCRIPTION_MODEL: "gpt-realtime-whisper",
      FRIDAY_INPUT_TRANSCRIPTION_LANGUAGE: "zh",
      FRIDAY_INPUT_TRANSCRIPTION_DELAY: "medium"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  t.after(() => service.kill("SIGTERM"));
  await waitForOutput(service, "Friday session service listening");

  const health = await fetchJSON(`http://127.0.0.1:${servicePort}/health`);
  assert.equal(health.status, 200);
  assert.equal(health.body.model, "gpt-realtime-2.1");
  assert.equal(health.body.dictation_reasoning_effort, "minimal");
  assert.equal(health.body.talk_model, "gpt-realtime-2.1");
  assert.equal(health.body.talk_reasoning_effort, "low");
  assert.equal(health.body.sessions_issued, 0);
  assert.equal(health.body.burst_protection_enabled, true);
  assert.equal(health.body.account_balance_readable, false);
  assert.equal(health.body.billing_status, "unknown");
  assert.equal(health.body.agent_mode, "mock_read_only");
  assert.equal(health.body.input_transcription_enabled, true);
  assert.equal(health.body.input_transcription_model, "gpt-realtime-whisper");
  assert.equal("daily_sessions_remaining" in health.body, false);

  const firstCredential = await fetchJSON(
    `http://127.0.0.1:${servicePort}/v1/realtime/client-secret`,
    { method: "POST" }
  );
  assert.equal(firstCredential.status, 200);
  assert.equal(firstCredential.body.value, "ek_test_ephemeral");
  assert.equal(firstCredential.body.input_transcription_enabled, true);
  assert.equal(firstCredential.body.model, "gpt-realtime-2.1");
  assert.equal(firstCredential.body.reasoning_effort, "minimal");
  assert.equal(credentialBody.session.model, "gpt-realtime-2.1");
  assert.deepEqual(credentialBody.session.output_modalities, ["text"]);
  assert.deepEqual(credentialBody.session.reasoning, { effort: "minimal" });
  assert.deepEqual(credentialBody.session.audio.input.transcription, {
    model: "gpt-realtime-whisper",
    language: "zh",
    delay: "medium"
  });

  const secondCredential = await fetchJSON(
    `http://127.0.0.1:${servicePort}/v1/realtime/client-secret`,
    { method: "POST" }
  );
  assert.equal(secondCredential.status, 200);

  const thirdCredential = await fetchJSON(
    `http://127.0.0.1:${servicePort}/v1/realtime/client-secret`,
    { method: "POST" }
  );
  assert.equal(thirdCredential.status, 200);

  const updatedHealth = await fetchJSON(`http://127.0.0.1:${servicePort}/health`);
  assert.equal(updatedHealth.body.sessions_issued, 3);

  const budget = JSON.parse(await readFile(budgetFile, "utf8"));
  assert.equal(budget.totalCount, 3);
});

test("credential burst protection stops an abnormal retry loop", async (t) => {
  const upstream = createServer((request, response) => {
    if (request.method === "GET" && request.url.startsWith("/v1/models/")) {
      return sendJSON(response, 200, { id: "gpt-realtime-2.1" });
    }
    if (request.method === "POST" && request.url === "/v1/realtime/client_secrets") {
      return sendJSON(response, 200, {
        value: "ek_test_loop_guard",
        session: { model: "gpt-realtime-2.1" }
      });
    }
    sendJSON(response, 404, { error: { message: "not found" } });
  });
  const upstreamPort = await listenOnRandomPort(upstream);
  t.after(() => upstream.close());

  const servicePort = await unusedPort();
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "friday-loop-test-"));
  t.after(() => rm(temporaryDirectory, { recursive: true, force: true }));

  const service = spawn(process.execPath, [serverPath], {
    cwd: backendDirectory,
    env: {
      ...process.env,
      OPENAI_API_KEY: "sk-test-loop-key-000000000000",
      OPENAI_BASE_URL: `http://127.0.0.1:${upstreamPort}`,
      FRIDAY_SESSION_PORT: String(servicePort),
      FRIDAY_BUDGET_FILE: join(temporaryDirectory, "budget.json"),
      FRIDAY_CREDENTIAL_BURST_LIMIT: "2",
      FRIDAY_CREDENTIAL_BURST_WINDOW_SECONDS: "60"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  t.after(() => service.kill("SIGTERM"));
  await waitForOutput(service, "Friday session service listening");

  const endpoint = `http://127.0.0.1:${servicePort}/v1/realtime/client-secret`;
  assert.equal((await fetchJSON(endpoint, { method: "POST" })).status, 200);
  assert.equal((await fetchJSON(endpoint, { method: "POST" })).status, 200);
  const blocked = await fetchJSON(endpoint, { method: "POST" });
  assert.equal(blocked.status, 429);
  assert.match(blocked.body.error, /abnormal retry loop/i);
});

test("health reports a billing block observed during credential creation", async (t) => {
  const upstream = createServer((request, response) => {
    if (request.method === "GET" && request.url.startsWith("/v1/models/")) {
      return sendJSON(response, 200, { id: "gpt-realtime-2.1" });
    }
    if (request.method === "POST" && request.url === "/v1/realtime/client_secrets") {
      return sendJSON(response, 429, {
        error: {
          code: "credit_balance_exhausted",
          message: "The project has no prepaid credits remaining."
        }
      });
    }
    sendJSON(response, 404, { error: { message: "not found" } });
  });
  const upstreamPort = await listenOnRandomPort(upstream);
  t.after(() => upstream.close());

  const servicePort = await unusedPort();
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "friday-billing-test-"));
  t.after(() => rm(temporaryDirectory, { recursive: true, force: true }));

  const service = spawn(process.execPath, [serverPath], {
    cwd: backendDirectory,
    env: {
      ...process.env,
      OPENAI_API_KEY: "sk-test-billing-key-000000000000",
      OPENAI_BASE_URL: `http://127.0.0.1:${upstreamPort}`,
      FRIDAY_SESSION_PORT: String(servicePort),
      FRIDAY_BUDGET_FILE: join(temporaryDirectory, "budget.json")
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  t.after(() => service.kill("SIGTERM"));
  await waitForOutput(service, "Friday session service listening");

  const endpoint = `http://127.0.0.1:${servicePort}`;
  const blocked = await fetchJSON(`${endpoint}/v1/realtime/client-secret`, {
    method: "POST"
  });
  assert.equal(blocked.status, 502);

  const health = await fetchJSON(`${endpoint}/health`);
  assert.equal(health.status, 200);
  assert.equal(health.body.billing_status, "blocked");
  assert.equal(health.body.billing_issue_code, "credit_balance_exhausted");
  assert.equal(health.body.account_balance_readable, false);
});

test("talk mode creates an interruptible audio session with bounded output", async (t) => {
  let credentialBody = null;
  const upstream = createServer(async (request, response) => {
    if (request.method === "GET"
        && new Set([
          "/v1/models/gpt-realtime",
          "/v1/models/gpt-realtime-2.1"
        ]).has(request.url)) {
      return sendJSON(response, 200, { id: request.url.split("/").at(-1) });
    }
    if (request.method === "POST" && request.url === "/v1/realtime/client_secrets") {
      credentialBody = JSON.parse(await readBody(request));
      return sendJSON(response, 200, {
        value: "ek_test_talk_ephemeral",
        expires_at: 1_900_000_000,
        session: { model: "gpt-realtime-2.1" }
      });
    }
    sendJSON(response, 404, { error: { message: "not found" } });
  });
  const upstreamPort = await listenOnRandomPort(upstream);
  t.after(() => upstream.close());

  const servicePort = await unusedPort();
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "friday-talk-test-"));
  t.after(() => rm(temporaryDirectory, { recursive: true, force: true }));

  const service = spawn(process.execPath, [serverPath], {
    cwd: backendDirectory,
    env: {
      ...process.env,
      OPENAI_API_KEY: "sk-test-talk-key-000000000000",
      OPENAI_BASE_URL: `http://127.0.0.1:${upstreamPort}`,
      FRIDAY_SESSION_PORT: String(servicePort),
      FRIDAY_BUDGET_FILE: join(temporaryDirectory, "budget.json"),
      FRIDAY_TALK_VOICE: "marin",
      FRIDAY_TALK_MAX_OUTPUT_TOKENS: "320",
      FRIDAY_TALK_VAD_EAGERNESS: "high"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  t.after(() => service.kill("SIGTERM"));
  await waitForOutput(service, "Friday session service listening");

  const credential = await fetchJSON(
    `http://127.0.0.1:${servicePort}/v1/realtime/client-secret`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mode: "talk" })
    }
  );

  assert.equal(credential.status, 200);
  assert.equal(credential.body.mode, "talk");
  assert.equal(credential.body.model, "gpt-realtime-2.1");
  assert.equal(credential.body.voice, "marin");
  assert.equal("maximum_turns" in credential.body, false);
  assert.equal("maximum_duration_seconds" in credential.body, false);
  assert.deepEqual(credentialBody.session.output_modalities, ["audio"]);
  assert.equal(credential.body.vad_eagerness, "high");
  assert.equal(credential.body.reasoning_effort, "low");
  assert.equal(credential.body.max_output_tokens, 320);
  assert.equal(credentialBody.session.model, "gpt-realtime-2.1");
  assert.deepEqual(credentialBody.session.reasoning, { effort: "low" });
  assert.equal(credentialBody.session.max_output_tokens, 320);
  assert.equal(credentialBody.session.audio.output.voice, "marin");
  assert.equal(credentialBody.session.audio.input.turn_detection.type, "semantic_vad");
  assert.equal(credentialBody.session.audio.input.turn_detection.eagerness, "high");
  assert.equal(credentialBody.session.audio.input.turn_detection.create_response, true);
  assert.equal(credentialBody.session.audio.input.turn_detection.interrupt_response, true);
  assert.equal(credentialBody.session.tool_choice, "auto");
  assert.deepEqual(
    credentialBody.session.tools.map(tool => tool.name),
    ["submit_work", "get_work_status", "cancel_work"]
  );
  assert.match(credentialBody.session.instructions, /Treat "Hey Friday" as the wake phrase/);
  assert.match(credentialBody.session.instructions, /answer immediately with minimal reasoning/);
  assert.match(credentialBody.session.instructions, /Use submit_work only/i);
  assert.match(credentialBody.session.instructions, /most recent selected image/i);
  assert.match(credentialBody.session.instructions, /read-only architecture preview/i);
});

test("work API deduplicates submissions, completes, reports, and cancels", async (t) => {
  const servicePort = await unusedPort();
  const service = spawn(process.execPath, [serverPath], {
    cwd: backendDirectory,
    env: {
      ...process.env,
      OPENAI_API_KEY: "sk-test-work-key-000000000000",
      FRIDAY_SESSION_PORT: String(servicePort),
      FRIDAY_MOCK_AGENT_DELAY_MS: "120"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  t.after(() => service.kill("SIGTERM"));
  await waitForOutput(service, "Friday session service listening");

  const endpoint = `http://127.0.0.1:${servicePort}/v1/work`;
  const submission = {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      objective: "验证后台任务不会阻塞语音对话",
      submission_key: "turn-1:call-1",
      objective_source: "model_derived"
    })
  };
  const first = await fetchJSON(endpoint, submission);
  const duplicate = await fetchJSON(endpoint, submission);
  assert.equal(first.status, 202);
  assert.equal(duplicate.status, 202);
  assert.equal(duplicate.body.work.id, first.body.work.id);
  assert.equal(first.body.work.executor, "mock_read_only");
  assert.equal(first.body.work.objective_source, "model_derived");

  const completed = await waitForWorkState(
    `${endpoint}/${first.body.work.id}`,
    "completed"
  );
  assert.match(completed.result.summary, /只读验证/);
  assert.match(completed.result.detail, /没有访问或修改任何外部内容/);

  const cancellable = await fetchJSON(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      objective: "取消这一项任务",
      submission_key: "turn-2:call-2"
    })
  });
  const cancelled = await fetchJSON(
    `${endpoint}/${cancellable.body.work.id}/cancel`,
    { method: "POST" }
  );
  assert.equal(cancelled.status, 200);
  assert.equal(cancelled.body.work.state, "cancelled");

  const invalid = await fetchJSON(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ objective: "", submission_key: "invalid" })
  });
  assert.equal(invalid.status, 400);
});

test("health errors redact upstream API key fragments", async (t) => {
  const upstream = createServer((_request, response) => {
    sendJSON(response, 401, {
      error: { message: "Incorrect API key provided: sk-secret-upstream-value" }
    });
  });
  const upstreamPort = await listenOnRandomPort(upstream);
  t.after(() => upstream.close());

  const servicePort = await unusedPort();
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "friday-redaction-test-"));
  t.after(() => rm(temporaryDirectory, { recursive: true, force: true }));

  const service = spawn(process.execPath, [serverPath], {
    cwd: backendDirectory,
    env: {
      ...process.env,
      OPENAI_API_KEY: "sk-test-backend-key-000000000000",
      OPENAI_BASE_URL: `http://127.0.0.1:${upstreamPort}`,
      FRIDAY_SESSION_PORT: String(servicePort),
      FRIDAY_BUDGET_FILE: join(temporaryDirectory, "budget.json")
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  t.after(() => service.kill("SIGTERM"));
  await waitForOutput(service, "Friday session service listening");

  const health = await fetchJSON(`http://127.0.0.1:${servicePort}/health`);
  assert.equal(health.status, 503);
  assert.equal(health.body.error.includes("sk-secret"), false);
  assert.match(health.body.error, /\[REDACTED_API_KEY\]/);
});

test("doctor validates the configured model without creating a Realtime session", async (t) => {
  let credentialRequestCount = 0;
  const upstream = createServer((request, response) => {
    if (request.method === "GET"
        && new Set([
          "/v1/models/gpt-realtime",
          "/v1/models/gpt-realtime-2.1"
        ]).has(request.url)) {
      return sendJSON(response, 200, { id: request.url.split("/").at(-1) });
    }
    if (request.url === "/v1/realtime/client_secrets") {
      credentialRequestCount += 1;
    }
    sendJSON(response, 404, { error: { message: "not found" } });
  });
  const upstreamPort = await listenOnRandomPort(upstream);
  t.after(() => upstream.close());

  const result = await runProcess(process.execPath, [serviceManagerPath, "doctor", "--env"], {
    ...process.env,
    OPENAI_API_KEY: "sk-test-doctor-key-000000000000",
    OPENAI_BASE_URL: `http://127.0.0.1:${upstreamPort}`,
    FRIDAY_SESSION_PORT: String(await unusedPort()),
    FRIDAY_REALTIME_MODEL: "gpt-realtime-2.1",
    FRIDAY_TALK_MODEL: "gpt-realtime-2.1"
  });

  assert.equal(result.code, 0, result.stderr);
  assert.match(
    result.stdout,
    /OpenAI: ready \(Dictate: gpt-realtime-2\.1; Talk: gpt-realtime-2\.1\)/
  );
  assert.equal(result.stdout.includes("sk-test-doctor"), false);
  assert.equal(result.stderr.includes("sk-test-doctor"), false);
  assert.equal(credentialRequestCount, 0);
});

test("doctor reports an upstream rejection without an initialization failure", async (t) => {
  const upstream = createServer((_request, response) => {
    sendJSON(response, 401, { error: { message: "Rejected test credentials" } });
  });
  const upstreamPort = await listenOnRandomPort(upstream);
  t.after(() => upstream.close());

  const result = await runProcess(
    process.execPath,
    [serviceManagerPath, "doctor", "--env"],
    {
      ...process.env,
      OPENAI_API_KEY: "sk-test-rejected-key-000000000000",
      OPENAI_BASE_URL: `http://127.0.0.1:${upstreamPort}`,
      FRIDAY_SESSION_PORT: String(await unusedPort()),
      FRIDAY_REALTIME_MODEL: "gpt-realtime-2.1",
      FRIDAY_TALK_MODEL: "gpt-realtime-2.1"
    }
  );

  assert.equal(result.code, 1);
  assert.match(result.stderr, /Rejected test credentials/);
  assert.equal(result.stderr.includes("before initialization"), false);
});

function listenOnRandomPort(server) {
  return new Promise((resolvePromise, rejectPromise) => {
    server.once("error", rejectPromise);
    server.listen(0, "127.0.0.1", () => {
      resolvePromise(server.address().port);
    });
  });
}

async function unusedPort() {
  const server = createServer();
  const port = await listenOnRandomPort(server);
  await new Promise((resolvePromise) => server.close(resolvePromise));
  return port;
}

function waitForOutput(child, expected) {
  return new Promise((resolvePromise, rejectPromise) => {
    let output = "";
    const timeout = setTimeout(() => {
      rejectPromise(new Error(`Timed out waiting for child output: ${output}`));
    }, 5_000);
    const onData = (data) => {
      output += data.toString();
      if (!output.includes(expected)) return;
      clearTimeout(timeout);
      child.stdout.off("data", onData);
      child.stderr.off("data", onData);
      resolvePromise();
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.once("exit", (code) => {
      clearTimeout(timeout);
      rejectPromise(new Error(`Child exited early with code ${code}: ${output}`));
    });
  });
}

function runProcess(executable, args, environment) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(executable, args, {
      cwd: backendDirectory,
      env: environment,
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => { stdout += data.toString(); });
    child.stderr.on("data", (data) => { stderr += data.toString(); });
    child.once("error", rejectPromise);
    child.once("exit", (code) => {
      resolvePromise({ code, stdout, stderr });
    });
  });
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function fetchJSON(url, options) {
  const response = await fetch(url, options);
  return {
    status: response.status,
    body: await response.json()
  };
}

async function waitForWorkState(url, expectedState) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const response = await fetchJSON(url);
    if (response.body.work?.state === expectedState) return response.body.work;
    await new Promise(resolvePromise => setTimeout(resolvePromise, 20));
  }
  throw new Error(`Timed out waiting for Work state ${expectedState}.`);
}

function sendJSON(response, statusCode, body) {
  response.writeHead(statusCode, { "Content-Type": "application/json" });
  response.end(JSON.stringify(body));
}
