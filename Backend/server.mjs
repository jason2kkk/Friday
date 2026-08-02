// 功能：提供仅监听本机的 Realtime 会话入口，让 Friday 使用短期凭证连接 OpenAI。
// 职责：暴露健康检查和凭证接口，组装 Dictate/Talk 会话配置，并管理签发计数、异常重试保护、账单状态和错误脱敏。
// 边界：长期 API Key 只存在于本进程；服务不接收音频或用户正文，健康检查也不创建 Realtime 会话。

import { createServer } from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  MockReadOnlyAgentExecutor,
  WorkNotFoundError,
  WorkRuntime,
  WorkValidationError
} from "./work-runtime.mjs";

const serviceHost = "127.0.0.1";
const servicePort = integerEnvironment("FRIDAY_SESSION_PORT", 8787);
const realtimeModel = process.env.FRIDAY_REALTIME_MODEL || "gpt-realtime-2.1";
const talkModel = process.env.FRIDAY_TALK_MODEL || "gpt-realtime-2.1";
const dictationReasoningEffort = choiceEnvironment(
  "FRIDAY_DICTATION_REASONING_EFFORT",
  "minimal",
  new Set(["minimal", "low", "medium", "high", "xhigh"])
);
const talkVoice = process.env.FRIDAY_TALK_VOICE || "marin";
const talkMaxOutputTokens = integerEnvironment("FRIDAY_TALK_MAX_OUTPUT_TOKENS", 320);
const talkVADEagerness = choiceEnvironment(
  "FRIDAY_TALK_VAD_EAGERNESS",
  "high",
  new Set(["low", "medium", "high", "auto"])
);
const talkReasoningEffort = choiceEnvironment(
  "FRIDAY_TALK_REASONING_EFFORT",
  "low",
  new Set(["minimal", "low", "medium", "high", "xhigh"])
);
const realtimeApiStyle = process.env.FRIDAY_REALTIME_API_STYLE || "ga";
const credentialBurstLimit = integerEnvironment("FRIDAY_CREDENTIAL_BURST_LIMIT", 6);
const credentialBurstWindowSeconds = integerEnvironment(
  "FRIDAY_CREDENTIAL_BURST_WINDOW_SECONDS",
  60
);
const inputTranscriptionModel = optionalEnvironment("FRIDAY_INPUT_TRANSCRIPTION_MODEL");
const inputTranscriptionLanguage = optionalEnvironment("FRIDAY_INPUT_TRANSCRIPTION_LANGUAGE");
const inputTranscriptionDelay = optionalEnvironment("FRIDAY_INPUT_TRANSCRIPTION_DELAY");
const mockAgentDelayMilliseconds = integerEnvironment(
  "FRIDAY_MOCK_AGENT_DELAY_MS",
  900
);
const openAIAPIKey = process.env.OPENAI_API_KEY;
const openAIBaseURL = process.env.OPENAI_BASE_URL || "https://api.openai.com";
const defaultRealtimeURL = "wss://api.openai.com/v1/realtime";
const proxyConfigured = Boolean(
  process.env.HTTPS_PROXY ||
  process.env.https_proxy ||
  process.env.HTTP_PROXY ||
  process.env.http_proxy ||
  process.env.ALL_PROXY ||
  process.env.all_proxy
);
const currentDirectory = dirname(fileURLToPath(import.meta.url));
const budgetFile = process.env.FRIDAY_BUDGET_FILE
  ? resolve(process.env.FRIDAY_BUDGET_FILE)
  : resolve(currentDirectory, ".data", "session-budget.json");
const upstreamReadinessCache = {
  expiresAt: 0,
  result: null
};
const recentCredentialAttempts = [];
let lastBillingIssue = null;
const workRuntime = new WorkRuntime({
  executor: new MockReadOnlyAgentExecutor({
    delayMilliseconds: mockAgentDelayMilliseconds
  })
});

if (!openAIAPIKey) {
  console.error("OPENAI_API_KEY is not set. The service did not start.");
  process.exit(1);
}

const server = createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/health") {
      const upstream = await checkUpstreamReadiness();
      const budget = await readBudget();
      if (!upstream.ok) {
        sendJSON(response, 503, {
          status: "unavailable",
          error: upstream.error,
          model: realtimeModel,
          dictation_reasoning_effort: supportsRealtimeReasoning(realtimeModel)
            ? dictationReasoningEffort
            : null,
          talk_model: talkModel,
          talk_voice: talkVoice,
          talk_vad_eagerness: talkVADEagerness,
          talk_reasoning_effort: supportsRealtimeReasoning(talkModel)
            ? talkReasoningEffort
            : null,
          talk_max_output_tokens: talkMaxOutputTokens,
          input_transcription_enabled: Boolean(inputTranscriptionModel),
          input_transcription_model: inputTranscriptionModel,
          agent_mode: "mock_read_only",
          sessions_issued: budget.totalCount,
          burst_protection_enabled: true,
          account_balance_readable: false,
          billing_status: lastBillingIssue ? "blocked" : "unknown",
          billing_issue_code: lastBillingIssue?.code || null
        });
        return;
      }
      sendJSON(response, 200, {
        status: "ok",
        model: realtimeModel,
        dictation_reasoning_effort: supportsRealtimeReasoning(realtimeModel)
          ? dictationReasoningEffort
          : null,
        talk_model: talkModel,
        talk_voice: talkVoice,
        talk_vad_eagerness: talkVADEagerness,
        talk_reasoning_effort: supportsRealtimeReasoning(talkModel)
          ? talkReasoningEffort
          : null,
        talk_max_output_tokens: talkMaxOutputTokens,
        upstream_status: "ok",
        api_style: realtimeApiStyle,
        proxy_configured: proxyConfigured,
        input_transcription_enabled: Boolean(inputTranscriptionModel),
        input_transcription_model: inputTranscriptionModel,
        agent_mode: "mock_read_only",
        sessions_issued: budget.totalCount,
        burst_protection_enabled: true,
        account_balance_readable: false,
        billing_status: lastBillingIssue ? "blocked" : "unknown",
        billing_issue_code: lastBillingIssue?.code || null
      });
      return;
    }

    if (request.method === "POST" && request.url === "/v1/work") {
      const requestBody = await readRequestJSON(request);
      const work = workRuntime.submit({
        objective: requestBody.objective,
        submissionKey: requestBody.submission_key,
        source: requestBody.objective_source
      });
      sendJSON(response, 202, { work });
      return;
    }

    const workRoute = matchWorkRoute(request.url);
    if (request.method === "GET" && workRoute?.action === "status") {
      sendJSON(response, 200, { work: workRuntime.get(workRoute.workID) });
      return;
    }
    if (request.method === "POST" && workRoute?.action === "cancel") {
      sendJSON(response, 200, { work: workRuntime.cancel(workRoute.workID) });
      return;
    }

    if (request.method === "POST" && request.url === "/v1/realtime/client-secret") {
      const requestBody = await readRequestJSON(request);
      const mode = requestBody.mode || "dictation";
      if (mode !== "dictation" && mode !== "talk") {
        throw new RequestError("Unsupported Realtime session mode.");
      }
      await reserveSession();
      try {
        const credential = await createClientCredential(mode);
        sendJSON(response, 200, credential);
      } catch (error) {
        await releaseSession();
        throw error;
      }
      return;
    }

    sendJSON(response, 404, { error: "Not found." });
  } catch (error) {
    const statusCode = error instanceof SafetyError
      ? 429
      : error instanceof WorkNotFoundError
        ? 404
        : error instanceof WorkValidationError
          ? 400
      : error instanceof RequestError
        ? 400
        : 502;
    sendJSON(response, statusCode, {
      error: publicErrorMessage(error)
    });
  }
});

server.listen(servicePort, serviceHost, () => {
  console.log(`Friday session service listening on http://${serviceHost}:${servicePort}`);
  console.log(
    `Dictate model: ${realtimeModel}; API style: ${realtimeApiStyle}; `
      + `reasoning effort: ${supportsRealtimeReasoning(realtimeModel) ? dictationReasoningEffort : "not supported"}`
  );
  console.log(
    `Talk model: ${talkModel}; voice: ${talkVoice}; `
      + `VAD eagerness: ${talkVADEagerness}; `
      + `reasoning effort: ${supportsRealtimeReasoning(talkModel) ? talkReasoningEffort : "not supported"}; `
      + `max output tokens: ${talkMaxOutputTokens}; selected screen context: enabled`
  );
  console.log(
    `Credential loop protection: ${credentialBurstLimit} attempts per `
      + `${credentialBurstWindowSeconds} seconds`
  );
  console.log(
    `Input transcription: ${inputTranscriptionModel || "disabled (no additional transcription model)"}`
  );
  console.log(`Environment proxy configured: ${proxyConfigured ? "yes" : "no"}`);
  console.log("Agent mode: mock read-only (no external actions)");
});

async function createClientCredential(mode = "dictation") {
  const isLegacy = realtimeApiStyle === "legacy";
  if (isLegacy && mode === "talk") {
    throw new RequestError("Talk mode requires the GA Realtime API style.");
  }
  const endpoint = isLegacy ? "/v1/realtime/sessions" : "/v1/realtime/client_secrets";
  const inputAudio = {
    format: { type: "audio/pcm", rate: 24000 },
    turn_detection: null
  };
  if (inputTranscriptionModel) {
    inputAudio.transcription = {
      model: inputTranscriptionModel,
      ...(inputTranscriptionLanguage ? { language: inputTranscriptionLanguage } : {}),
      ...(inputTranscriptionDelay ? { delay: inputTranscriptionDelay } : {})
    };
  }
  const dictationSession = {
    type: "realtime",
    model: realtimeModel,
    output_modalities: ["text"],
    max_output_tokens: 256,
    ...(supportsRealtimeReasoning(realtimeModel)
      ? { reasoning: { effort: dictationReasoningEffort } }
      : {}),
    audio: {
      input: inputAudio
    }
  };
  const talkSession = {
    type: "realtime",
    model: talkModel,
    output_modalities: ["audio"],
    max_output_tokens: talkMaxOutputTokens,
    instructions: talkInstructions,
    tools: talkTools,
    tool_choice: "auto",
    ...(supportsRealtimeReasoning(talkModel)
      ? { reasoning: { effort: talkReasoningEffort } }
      : {}),
    audio: {
      input: {
        format: { type: "audio/pcm", rate: 24000 },
        noise_reduction: { type: "far_field" },
        turn_detection: {
          type: "semantic_vad",
          eagerness: talkVADEagerness,
          create_response: true,
          interrupt_response: true
        }
      },
      output: {
        format: { type: "audio/pcm", rate: 24000 },
        voice: talkVoice,
        speed: 1
      }
    }
  };
  const body = isLegacy
    ? {
        model: realtimeModel,
        modalities: ["text"],
        input_audio_format: "pcm16",
        turn_detection: null,
        max_response_output_tokens: 256
      }
    : {
        session: mode === "talk" ? talkSession : dictationSession
      };

  const upstreamResponse = await fetch(`${openAIBaseURL}${endpoint}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${openAIAPIKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15_000)
  });

  const payload = await upstreamResponse.json().catch(() => ({}));
  if (!upstreamResponse.ok) {
    const upstreamCode = typeof payload?.error?.code === "string"
      ? payload.error.code
      : null;
    if (upstreamCode && billingIssueCodes.has(upstreamCode)) {
      lastBillingIssue = { code: upstreamCode, detectedAt: Date.now() };
    }
    const upstreamMessage = redactSecrets(
      payload?.error?.message || `HTTP ${upstreamResponse.status}`
    );
    throw new Error(`OpenAI client credential request failed: ${upstreamMessage}`);
  }

  const value = payload.value || payload.client_secret?.value;
  const configuredModel = mode === "talk" ? talkModel : realtimeModel;
  const model = payload.session?.model || payload.model || configuredModel;
  if (!value) {
    throw new Error("OpenAI returned no client secret value.");
  }
  lastBillingIssue = null;

  return {
    value,
    model,
    expires_at: payload.expires_at || payload.client_secret?.expires_at || null,
    realtime_url: process.env.FRIDAY_REALTIME_URL || defaultRealtimeURL,
    mode,
    voice: mode === "talk" ? talkVoice : null,
    vad_eagerness: mode === "talk" ? talkVADEagerness : null,
    reasoning_effort: mode === "talk"
      ? (supportsRealtimeReasoning(talkModel) ? talkReasoningEffort : null)
      : (supportsRealtimeReasoning(realtimeModel) ? dictationReasoningEffort : null),
    max_output_tokens: mode === "talk" ? talkMaxOutputTokens : null,
    input_transcription_enabled: Boolean(inputTranscriptionModel),
    input_transcription_model: inputTranscriptionModel
  };
}

async function checkUpstreamReadiness() {
  const now = Date.now();
  if (upstreamReadinessCache.result && upstreamReadinessCache.expiresAt > now) {
    return upstreamReadinessCache.result;
  }

  let result;
  try {
    for (const model of new Set([realtimeModel, talkModel])) {
      const response = await fetch(
        `${openAIBaseURL}/v1/models/${encodeURIComponent(model)}`,
        {
          headers: {
            Authorization: `Bearer ${openAIAPIKey}`,
            Accept: "application/json"
          },
          signal: AbortSignal.timeout(5_000)
        }
      );

      if (!response.ok) {
        const payload = await response.json().catch(() => ({}));
        result = {
          ok: false,
          error: redactSecrets(
            payload?.error?.message
              || `OpenAI model check failed for ${model} with HTTP ${response.status}.`
          )
        };
        break;
      }
    }
    result ||= { ok: true };
  } catch (error) {
    result = { ok: false, error: publicErrorMessage(error) };
  }

  upstreamReadinessCache.result = result;
  upstreamReadinessCache.expiresAt = now + (result.ok ? 30_000 : 5_000);
  return result;
}

class SafetyError extends Error {}
class RequestError extends Error {}

const billingIssueCodes = new Set([
  "credit_balance_exhausted",
  "organization_spend_limit_exceeded",
  "project_spend_limit_exceeded",
  "organization_usage_limit_exceeded"
]);

function publicErrorMessage(error) {
  if (!(error instanceof Error)) {
    return "Unknown service error.";
  }

  const code = typeof error.cause?.code === "string" ? error.cause.code : null;
  const networkCodes = new Set([
    "ECONNREFUSED",
    "ECONNRESET",
    "ENETUNREACH",
    "EHOSTUNREACH",
    "ETIMEDOUT"
  ]);

  if (code && networkCodes.has(code)) {
    return `Cannot reach OpenAI (${code}). Check the network or enable a proxy/TUN route for the Friday service.`;
  }
  if (error.name === "AbortError" || error.name === "TimeoutError") {
    return "The OpenAI credential request timed out. Check the network or proxy/TUN route.";
  }
  if (error.message === "fetch failed") {
    return "Cannot reach OpenAI. Check the network or enable a proxy/TUN route for the Friday service.";
  }
  return redactSecrets(error.message);
}

function redactSecrets(message) {
  return String(message)
    .replace(/sk-[A-Za-z0-9_.*-]+/g, "[REDACTED_API_KEY]")
    .replace(/Bearer\s+[A-Za-z0-9._-]+/gi, "Bearer [REDACTED]");
}

async function reserveSession() {
  const now = Date.now();
  const cutoff = now - credentialBurstWindowSeconds * 1_000;
  while (recentCredentialAttempts.length > 0 && recentCredentialAttempts[0] < cutoff) {
    recentCredentialAttempts.shift();
  }
  if (recentCredentialAttempts.length >= credentialBurstLimit) {
    throw new SafetyError(
      "Credential requests were paused because Friday detected an abnormal retry loop."
    );
  }
  recentCredentialAttempts.push(now);

  const budget = await readBudget();
  budget.totalCount += 1;
  await writeBudget(budget);
}

async function releaseSession() {
  const budget = await readBudget();
  budget.totalCount = Math.max(0, budget.totalCount - 1);
  await writeBudget(budget);
}

async function readBudget() {
  try {
    const value = JSON.parse(await readFile(budgetFile, "utf8"));
    return {
      totalCount: Number(value.totalCount) || 0
    };
  } catch {
    return { totalCount: 0 };
  }
}

async function writeBudget(value) {
  await mkdir(dirname(budgetFile), { recursive: true });
  await writeFile(budgetFile, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

function integerEnvironment(name, fallback) {
  const parsed = Number.parseInt(process.env[name] || "", 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function choiceEnvironment(name, fallback, allowedValues) {
  const value = process.env[name]?.trim().toLowerCase();
  return value && allowedValues.has(value) ? value : fallback;
}

function optionalEnvironment(name) {
  const value = process.env[name]?.trim();
  return value || null;
}

function supportsRealtimeReasoning(model) {
  return model.startsWith("gpt-realtime-2");
}

async function readRequestJSON(request) {
  const chunks = [];
  let totalBytes = 0;
  for await (const chunk of request) {
    totalBytes += chunk.length;
    if (totalBytes > 16_384) {
      throw new RequestError("Request body is too large.");
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new RequestError("Request body must be valid JSON.");
  }
}

function sendJSON(response, statusCode, body) {
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  response.end(JSON.stringify(body));
}

function matchWorkRoute(rawURL) {
  const pathname = new URL(rawURL || "/", `http://${serviceHost}`).pathname;
  const match = pathname.match(/^\/v1\/work\/(work_[a-f0-9]{32})(?:\/(cancel))?$/i);
  if (!match) return null;
  return {
    workID: match[1],
    action: match[2] === "cancel" ? "cancel" : "status"
  };
}

const talkTools = [
  {
    type: "function",
    name: "submit_work",
    description: "Submit a new task that needs background execution, investigation, current information, tools, files, apps, or a substantial artifact. The current internal-alpha executor is a read-only architecture preview and never changes external state. Do not use this for greetings or questions you can answer directly from the conversation.",
    parameters: {
      type: "object",
      properties: {
        objective: {
          type: "string",
          description: "A concise objective that faithfully preserves the user's target, constraints, and expected result. Do not invent missing details or prescribe internal tools."
        }
      },
      required: ["objective"],
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "get_work_status",
    description: "Get the public status or result of a previously submitted background task. Use this when the user asks how the previous task is going instead of submitting a duplicate task.",
    parameters: {
      type: "object",
      properties: {
        work_id: {
          type: "string",
          description: "The Friday Work ID from runtime context. Omit it to use the most recently submitted Work in this Talk session."
        }
      },
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "cancel_work",
    description: "Cancel a previously submitted background task when the user explicitly asks to stop or cancel it.",
    parameters: {
      type: "object",
      properties: {
        work_id: {
          type: "string",
          description: "The Friday Work ID from runtime context. Omit it to cancel the most recently submitted active Work in this Talk session."
        }
      },
      additionalProperties: false
    }
  }
];

const talkInstructions = `
# Role
You are Friday, a calm, warm, concise voice companion on the user's Mac.

# Language
- Reply in the language the user is currently speaking.
- Use natural spoken language, not written-report formatting.

# Conversation
- Respond directly and naturally. Do not announce listening, thinking, processing, or output stages.
- Keep ordinary replies to one to three short spoken sentences unless the user explicitly asks for detail.
- Never use Markdown, headings, numbered workflows, or stage labels in speech.
- Treat "Hey Friday" as the wake phrase, not as a substantive request.
- If the user only says the wake phrase, acknowledge briefly and wait for the request.
- The user may interrupt at any time. Stop the previous thought and respond to the newest clear request.
- Do not repeat the same greeting, opener, or filler across consecutive turns.

# User-selected screen context
- Friday may receive an image explicitly selected by the user from their screen.
- Treat the most recent selected image as the visual referent for phrases such as "this", "this sentence", "the selected area", or "这里".
- When the user asks to translate, explain, summarize, or identify selected content, inspect the image and answer the request directly.
- Do not claim to see text or controls that are not legible in the selected image. Ask one concise clarification question when necessary.

# Reasoning and Preambles
- For greetings, direct questions, and simple requests, answer immediately with minimal reasoning.
- Use additional reasoning only when the request genuinely requires multiple steps.
- Do not announce internal reasoning or fill silence with progress updates.
- Use submit_work only when the request genuinely needs background execution, investigation, current information, tools, files, apps, or a substantial artifact.
- If the answer is already available in the conversation, answer directly instead of creating Work.

# Background Work
- submit_work returning accepted only means the task was created. Never say it is already complete.
- After submitting Work, briefly confirm what is being handled and keep the voice conversation available. Do not wait or poll automatically.
- When the user asks about previous progress, use get_work_status. When the user explicitly asks to stop, use cancel_work.
- Never reveal Work IDs, provider details, queues, sessions, tool names, or internal routing unless the user explicitly asks for diagnostics.
- The current executor is a read-only architecture preview. It does not inspect or change external files, apps, messages, or accounts. Describe its returned result exactly and never imply an external action occurred.

# Unclear Audio
- Only respond to clear human speech directed at Friday.
- For unclear, partial, silent, or background audio, ask one brief clarification question.

# Boundaries
- Friday can inspect user-selected images and submit bounded background Work, but must not claim it changed files, sent messages, or controlled the Mac without a verified future ActionReceipt.
`.trim();
