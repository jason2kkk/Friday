// 功能：提供仅监听本机的 Realtime 会话入口，让 Olli 使用短期凭证连接 OpenAI。
// 职责：分离本地存活与模型就绪检查，签发 Dictate 客户端端点或 Talk Provider semantic VAD 凭证，拆分 Provider 自动取消与客户端受控插话能力，并暴露 Work 接口、保护和脱敏。
// 边界：长期 API Key 只存在于本进程；服务不接收音频或用户正文，存活与就绪检查都不创建 Realtime 会话。

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
const talkPromptVersion = "2026-08-06.desktop-app-actions-v2";
const dictationReasoningEffort = choiceEnvironment(
  "FRIDAY_DICTATION_REASONING_EFFORT",
  "minimal",
  new Set(["minimal", "low", "medium", "high", "xhigh"])
);
const talkVoice = process.env.FRIDAY_TALK_VOICE || "marin";
const talkMaxOutputTokens = optionalPositiveIntegerEnvironment("FRIDAY_TALK_MAX_OUTPUT_TOKENS");
const talkEndpointing = choiceEnvironment(
  "FRIDAY_TALK_ENDPOINTING",
  "provider_vad",
  new Set(["provider_vad", "client_gate"])
);
const talkVADEagerness = choiceEnvironment(
  "FRIDAY_TALK_VAD_EAGERNESS",
  "auto",
  new Set(["low", "medium", "high", "auto"])
);
const talkInterruptResponse = false;
const talkAllowsResponseInterruption = true;
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
const upstreamReadinessTimeoutMilliseconds = integerEnvironment(
  "FRIDAY_UPSTREAM_READINESS_TIMEOUT_MS",
  3_000
);
const inputTranscriptionModel = process.env.FRIDAY_INPUT_TRANSCRIPTION_MODEL === undefined
  ? "gpt-live-transcribe"
  : optionalEnvironment("FRIDAY_INPUT_TRANSCRIPTION_MODEL");
const inputTranscriptionLanguage = process.env.FRIDAY_INPUT_TRANSCRIPTION_LANGUAGE === undefined
  ? "zh"
  : optionalEnvironment("FRIDAY_INPUT_TRANSCRIPTION_LANGUAGE");
const inputTranscriptionDelay = process.env.FRIDAY_INPUT_TRANSCRIPTION_DELAY === undefined
  ? "minimal"
  : optionalEnvironment("FRIDAY_INPUT_TRANSCRIPTION_DELAY");
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
      const budget = await readBudget();
      sendJSON(response, 200, serviceStatusPayload({
        status: "ok",
        upstreamStatus: "unchecked",
        budget
      }));
      return;
    }

    if (request.method === "GET" && request.url === "/ready") {
      const [upstream, budget] = await Promise.all([
        checkUpstreamReadiness(),
        readBudget()
      ]);
      sendJSON(response, upstream.ok ? 200 : 503, serviceStatusPayload({
        status: upstream.ok ? "ok" : "unavailable",
        upstreamStatus: upstream.ok ? "ok" : "unavailable",
        budget,
        error: upstream.ok ? null : upstream.error
      }));
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
  console.log(`Olli session service listening on http://${serviceHost}:${servicePort}`);
  console.log(
    `Dictate model: ${realtimeModel}; API style: ${realtimeApiStyle}; `
      + `reasoning effort: ${supportsRealtimeReasoning(realtimeModel) ? dictationReasoningEffort : "not supported"}`
  );
  console.log(
    `Talk model: ${talkModel}; voice: ${talkVoice}; `
      + `endpointing: ${talkEndpointing}; `
      + `VAD eagerness: ${talkEndpointing === "provider_vad" ? talkVADEagerness : "disabled"}; `
      + `provider automatic interruption: ${talkInterruptResponse ? "enabled" : "disabled"}; `
      + `client-controlled barge-in: ${talkAllowsResponseInterruption ? "enabled" : "disabled"}; `
      + `reasoning effort: ${supportsRealtimeReasoning(talkModel) ? talkReasoningEffort : "not supported"}; `
      + `max output tokens: ${talkMaxOutputTokens ?? "unlimited"}; selected screen context: enabled`
  );
  console.log(`Talk prompt version: ${talkPromptVersion}`);
  console.log(
    `Credential loop protection: ${credentialBurstLimit} attempts per `
      + `${credentialBurstWindowSeconds} seconds`
  );
  console.log(
    `OpenAI readiness timeout: ${upstreamReadinessTimeoutMilliseconds} ms`
  );
  console.log("Dictate input transcription: disabled (Realtime result is authoritative)");
  console.log(
    `Talk input transcription: ${inputTranscriptionModel || "disabled (no additional transcription model)"}`
  );
  console.log(`Environment proxy configured: ${proxyConfigured ? "yes" : "no"}`);
  console.log("Local actions: application navigation and reversible input write; Work runtime: mock read-only");
});

async function createClientCredential(mode = "dictation") {
  const isLegacy = realtimeApiStyle === "legacy";
  if (isLegacy && mode === "talk") {
    throw new RequestError("Talk mode requires the GA Realtime API style.");
  }
  const endpoint = isLegacy ? "/v1/realtime/sessions" : "/v1/realtime/client_secrets";
  // Dictate already receives its paste-ready result from the Realtime response. The extra
  // transcription channel is reserved for Talk subtitles and Agent turn correlation so a
  // delayed optional ASR event cannot hold the user's primary input path open.
  const inputTranscription = mode === "talk" && inputTranscriptionModel
    ? {
        model: inputTranscriptionModel,
        ...(inputTranscriptionLanguage ? { language: inputTranscriptionLanguage } : {}),
        ...(inputTranscriptionDelay ? { delay: inputTranscriptionDelay } : {})
      }
    : null;
  const inputAudio = {
    format: { type: "audio/pcm", rate: 24000 },
    turn_detection: null
  };
  if (inputTranscription) {
    inputAudio.transcription = inputTranscription;
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
    ...(talkMaxOutputTokens ? { max_output_tokens: talkMaxOutputTokens } : {}),
    instructions: talkInstructions,
    tools: activeTalkTools,
    tool_choice: "auto",
    ...(supportsRealtimeReasoning(talkModel)
      ? { reasoning: { effort: talkReasoningEffort } }
      : {}),
    audio: {
      input: {
        format: { type: "audio/pcm", rate: 24000 },
        noise_reduction: { type: "near_field" },
        ...(inputTranscription ? { transcription: inputTranscription } : {}),
        turn_detection: talkEndpointing === "provider_vad"
          ? {
              type: "semantic_vad",
              eagerness: talkVADEagerness,
              create_response: true,
              interrupt_response: talkInterruptResponse
            }
          : null
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
    endpointing: mode === "talk" ? talkEndpointing : null,
    vad_eagerness: mode === "talk" && talkEndpointing === "provider_vad"
      ? talkVADEagerness
      : null,
    interrupt_response: mode === "talk" ? talkInterruptResponse : null,
    allows_response_interruption: mode === "talk"
      ? talkAllowsResponseInterruption
      : null,
    reasoning_effort: mode === "talk"
      ? (supportsRealtimeReasoning(talkModel) ? talkReasoningEffort : null)
      : (supportsRealtimeReasoning(realtimeModel) ? dictationReasoningEffort : null),
    ...(mode === "talk" && talkMaxOutputTokens
      ? { max_output_tokens: talkMaxOutputTokens }
      : {}),
    prompt_version: mode === "talk" ? talkPromptVersion : null,
    response_creation: mode === "talk"
      ? (talkEndpointing === "provider_vad" ? "provider" : "client")
      : null,
    input_transcription_enabled: mode === "talk" && Boolean(inputTranscriptionModel),
    input_transcription_model: mode === "talk" ? inputTranscriptionModel : null,
    agent_tools_enabled: mode === "talk" && activeTalkTools.length > 1,
    automatic_focused_write_enabled: mode === "talk"
  };
}

async function checkUpstreamReadiness() {
  const now = Date.now();
  if (upstreamReadinessCache.result && upstreamReadinessCache.expiresAt > now) {
    return upstreamReadinessCache.result;
  }

  let result;
  try {
    for (const model of new Set(
      [realtimeModel, talkModel, inputTranscriptionModel].filter(Boolean)
    )) {
      const response = await fetch(
        `${openAIBaseURL}/v1/models/${encodeURIComponent(model)}`,
        {
          headers: {
            Authorization: `Bearer ${openAIAPIKey}`,
            Accept: "application/json"
          },
          signal: AbortSignal.timeout(upstreamReadinessTimeoutMilliseconds)
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

function serviceStatusPayload({ status, upstreamStatus, budget, error = null }) {
  const payload = {
    status,
    model: realtimeModel,
    dictation_reasoning_effort: supportsRealtimeReasoning(realtimeModel)
      ? dictationReasoningEffort
      : null,
    talk_model: talkModel,
    talk_voice: talkVoice,
    talk_endpointing: talkEndpointing,
    talk_vad_eagerness: talkEndpointing === "provider_vad"
      ? talkVADEagerness
      : null,
    talk_interrupt_response: talkInterruptResponse,
    talk_allows_response_interruption: talkAllowsResponseInterruption,
    talk_reasoning_effort: supportsRealtimeReasoning(talkModel)
      ? talkReasoningEffort
      : null,
    talk_max_output_tokens: talkMaxOutputTokens,
    talk_prompt_version: talkPromptVersion,
    talk_response_creation: talkEndpointing === "provider_vad" ? "provider" : "client",
    upstream_status: upstreamStatus,
    api_style: realtimeApiStyle,
    proxy_configured: proxyConfigured,
    dictation_input_transcription_enabled: false,
    talk_input_transcription_enabled: Boolean(inputTranscriptionModel),
    input_transcription_enabled: Boolean(inputTranscriptionModel),
    input_transcription_model: inputTranscriptionModel,
    agent_tools_enabled: true,
    automatic_focused_write_enabled: true,
    agent_mode: "desktop_app_actions_v2",
    work_runtime: "mock_read_only",
    sessions_issued: budget.totalCount,
    burst_protection_enabled: true,
    account_balance_readable: false,
    billing_status: lastBillingIssue ? "blocked" : "unknown",
    billing_issue_code: lastBillingIssue?.code || null
  };
  if (error) payload.error = error;
  return payload;
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
    return `Cannot reach OpenAI (${code}). Check the network or enable a proxy/TUN route for the Olli service.`;
  }
  if (error.name === "AbortError" || error.name === "TimeoutError") {
    return "The OpenAI credential request timed out. Check the network or proxy/TUN route.";
  }
  if (error.message === "fetch failed") {
    return "Cannot reach OpenAI. Check the network or enable a proxy/TUN route for the Olli service.";
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
      "Credential requests were paused because Olli detected an abnormal retry loop."
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

function optionalPositiveIntegerEnvironment(name) {
  const parsed = Number.parseInt(process.env[name] || "", 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
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
    name: "wait_for_user",
    description: "仅当最新音频高置信度地只包含静音、极短的非语言噪声或明显的扬声器残留，且没有持续、可辨认的人声时调用。只要存在持续人声、可辨认词语或疑似对 Olli 的请求，就禁止调用；内容不清楚时应简短澄清。",
    parameters: {
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "open_application",
    description: "仅当用户只要求打开、启动、切换到或显示某个 Mac 应用，且同一请求不包含文字写入时调用。应用名称由本机已安装 Bundle 与运行进程解析，工具会启动或激活唯一目标并复验前台状态；歧义或不存在时不会猜测。只要原请求还包含把文字写入输入框，就不要调用本工具，直接调用 write_focused_input。",
    parameters: {
      type: "object",
      properties: {
        application: {
          type: "string",
          description: "用户原话中的目标应用名称，例如 Codex、Xcode、Safari 或文本编辑。"
        }
      },
      required: ["application"],
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "write_focused_input",
    description: "仅当用户明确要求把确定文字写入、放入或填入某个应用或本次对话锁定的输入框时调用。用户指定应用时，本机会按需启动或激活该应用，再通过 Accessibility 查找唯一可验证目标；工具只执行可通过 Command-Z 撤销的文字写入，不发送、提交、发布、购买或删除。调用工具前不要口头复述、确认或介绍能力，等待工具回执后只给一句最短结果。",
    parameters: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "要写入输入框的完整最终文字。忠实保留用户原意，不补充用户没有提供的事实。"
        },
        application: {
          type: "string",
          description: "用户明确指定的目标应用名称，例如 Codex、Xcode 或 Safari。用户没有指定应用时省略，Olli 将使用开始对话时锁定的输入框。"
        }
      },
      required: ["text"],
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "submit_work",
    description: "仅用于内部 Alpha 创建等待用户确认的 WorkDraft。只有用户明确要求‘创建后台测试任务’或‘验证后台任务机制’时才调用。调用后不会创建正式 Work；必须忠实复述返回的 objective，并请用户明确说‘确认提交’或‘取消’。当前执行器是只读 Mock，不会查看或修改真实文件、应用、网页、消息或账号；不得用它代替真实操作，也不得用于闲聊、问答、翻译、解释、总结或屏幕选区理解。",
    parameters: {
      type: "object",
      properties: {
        objective: {
          type: "string",
          description: "简洁、忠实地保留用户明确提出的测试目标、约束和预期结果；不要补充缺失信息，也不要指定内部工具。"
        }
      },
      required: ["objective"],
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "confirm_work",
    description: "仅当 Olli 已复述待确认的任务草稿，并且用户随后清楚、完整地说出‘确认提交’时调用。模糊同意、背景人声、模型自行推断或首次提出任务都不能触发。运行时还会用该确认轮次的最终用户转写做本地校验。",
    parameters: {
      type: "object",
      properties: {
        draft_id: {
          type: "string",
          description: "submit_work 返回的 Olli WorkDraft ID；省略时使用本次 Talk 最近的待确认草稿。"
        }
      },
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "discard_work_draft",
    description: "当用户在任务草稿确认阶段明确说取消、不提交或放弃时调用。只丢弃尚未提交的草稿，不取消已经创建的正式 Work。",
    parameters: {
      type: "object",
      properties: {
        draft_id: {
          type: "string",
          description: "submit_work 返回的 Olli WorkDraft ID；省略时使用本次 Talk 最近的待确认草稿。"
        }
      },
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "get_work_status",
    description: "查询本次 Talk 中已经提交的后台测试任务状态或结果。仅在用户询问之前任务的进度时调用，不要重复提交任务。",
    parameters: {
      type: "object",
      properties: {
        work_id: {
          type: "string",
          description: "运行时上下文中的 Olli Work ID；省略时使用本次 Talk 最近提交的任务。"
        }
      },
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "cancel_work",
    description: "仅在用户明确要求停止或取消之前的后台测试任务时调用。",
    parameters: {
      type: "object",
      properties: {
        work_id: {
          type: "string",
          description: "运行时上下文中的 Olli Work ID；省略时取消本次 Talk 最近提交且仍在运行的任务。"
        }
      },
      additionalProperties: false
    }
  }
];

const toolsWithoutFinalASR = new Set([
  "wait_for_user",
  "open_application",
  "write_focused_input"
]);
const activeTalkTools = inputTranscriptionModel
  ? talkTools
  : talkTools.filter(tool => toolsWithoutFinalASR.has(tool.name));

const talkInstructions = `
# 角色与目标
你是 Olli，Mac 上温和、自然、简洁的中文语音助手。
优先理解用户最后一段清晰且完整的请求，在当前真实能力范围内直接回答或调用工具。

# 语言
- 简体中文是默认回复语言。
- 用户最新一段完整请求主要使用中文时，始终用简体中文回答。
- 不要因为口音、语气词、英文产品名、选区内的英文、工具名、JSON 字段或英文工具结果而切换到英文。
- 只有用户明确要求使用另一种语言，或最新一段完整请求主要使用另一种语言时，才切换回复语言。
- 翻译任务按用户指定的目标语言输出译文；必要说明仍使用当前对话语言。
- 工具确认、进度、澄清和最终结果必须保持当前对话语言。无法确定时使用简体中文。

# 意图路由
1. 闲聊、知识问答、解释、翻译、总结、改写，以及屏幕选区理解：直接回答，不调用工具。
2. 请求缺少必要信息或语音含糊：只问一个简短澄清问题，不猜测，不调用工具。
3. 只有用户仅要求打开、启动、切换或显示某个应用，且没有要求写入文字时，才调用 open_application。保留用户使用的应用名，本机会从已安装 Bundle 与运行进程中解析并复验。
4. 用户明确要求把文字写入、放入或填入输入框时直接调用 write_focused_input。用户说出 Codex、Xcode、Safari、微信等应用名时，将原名称放入 application；不要把“Codex”改写成“ChatGPT”。指定应用未运行或在后台时，本机工具会先启动或激活它，不需要先调用 open_application，也不需要让用户手动切换。
5. 同一请求同时包含“打开/切换应用”和“写入文字”时，只调用 write_focused_input，一次完成激活与写入。绝不能在 open_application 成功后结束请求。
6. 写入请求包含发送、提交、发布、购买、删除或权限变更时，不调用输入框写入工具；当前只能准备文字，不能完成外部副作用。
7. 只有用户明确要求“创建后台测试任务”或“验证后台任务机制”时，才调用 submit_work 创建草稿；首次请求绝不能直接说任务已经提交。
8. 除打开应用和可撤销输入框写入外，用户要求操作文件、邮件、网页、消息或账号中的其他真实动作时，当前没有可用工具。诚实说明最接近的可用帮助，不提交 Mock Work 冒充执行。
9. submit_work 返回 awaiting_confirmation 后，忠实复述 objective，并要求用户明确说“确认提交”或“取消”。只有下一轮用户清楚说出“确认提交”时才调用 confirm_work；用户明确取消时调用 discard_work_draft。
10. 用户询问本次 Talk 中已提交测试任务的进度时调用 get_work_status；用户明确要求停止时调用 cancel_work。

# 对话方式
- 直接、自然地回应，不播报“收听、思考、处理、输出”等阶段。
- 先说核心结论。普通回复通常只说一句，最多两句；只有用户明确要求细节时才展开。
- 每次都要完整结束当前句子。内容可能超出本轮长度时，宁可缩短为一个完整答复，也不要在半句话中停止。
- 语音回复不使用 Markdown、标题、编号流程或系统阶段标签。
- 将“Hey Olli”视为唤醒词，不视为具体任务。用户只说唤醒词时，简短回应并等待请求。
- 用户可以随时打断。停止上一段内容，优先处理最新的清晰请求。
- 不复述用户刚说的话，不介绍“我可以做什么”，不说“请告诉我你的需求”“你可以继续说”“我会帮助你”等无信息量话术。
- 不连续重复相同的问候、澄清、开场白或填充语；同一意图没有新增信息时，宁可只问一个具体问题。

# 应用与输入框动作
- open_application 只用于打开或切换应用，不替用户点击应用内按钮。成功后只说“打开了”；失败时只说一个可恢复原因。
- write_focused_input 只负责可撤销文字写入，不显示确认界面，也不要求用户再次说“好的”或“确认”。
- 用户指定应用时，application 必须保留用户使用的应用名；本机解析器会把 Codex 映射到实际运行的 com.openai.codex，即使系统显示名是 ChatGPT。
- 用户没有指定应用时省略 application，使用启动本次 Talk 时锁定的输入框。
- 工具调用前保持安静，不说“好的，我来写入”或复述正文。工具返回 succeeded 后只说“写好了”；失败时只说一个可恢复原因；unknown 时只请用户查看目标输入框。
- 只有 succeeded 才能明确说已经写入；写入不代表内容已经发送、提交或发布。

# 用户主动选择的屏幕内容
- Olli 可能收到用户明确框选的一张屏幕图片。
- “这个”“这句话”“选中的区域”“这里”等指代，默认指向最近一次选区图片。
- 用户要求翻译、解释、总结或识别选区时，检查图片并直接回答，不提交 Work。
- 看不清时只问一个简短问题；不要声称看到了不可辨认的文字或控件。

# 后台测试 Work
- submit_work 只创建内部草稿，不创建后台 Work。必须根据返回值复述目标并等待用户确认。
- confirm_work 返回 accepted 才表示测试任务已创建，但不能说任务已经完成。
- 最终用户转写缺失、失败或无法与当前 Turn 对应时，运行时会拒绝提交；如实说明没有创建任务，不要绕过或重复调用工具。
- 正式提交后只需简短确认正在处理；保持语音对话可用，不自动等待或轮询。
- 除非用户明确要求诊断，不透露 Work ID、Provider、队列、Session、工具名或内部路由。
- 当前执行器只是只读 Mock，不会访问或改变任何外部内容。严格按返回结果描述，不能暗示真实操作已经发生。

# 模糊音频
- 进入本会话的音频已经经过本地近场人声过滤；只要听到持续人声、可辨认词语或疑似请求，优先把它当作用户在对 Olli 说话。
- 持续或完整的人声绝不能因为意图不明确、称呼不明确、句子残缺、口音或识别不确定而静默结束。能理解就直接回答，不能理解就只问一个简短澄清问题。
- 只有高置信度确认最新音频不含持续人声，例如纯静音、极短的碰撞声或明显的扬声器残留时，才调用 wait_for_user。
- 调用 wait_for_user 后不要继续生成口头回复，不要说“我在”“没听清”“请继续”或类似内容。

# 例子
- 用户：“帮我翻译框选的英文。” -> 直接用中文给出译文，不提交 Work。
- 用户：“打开文本编辑。” -> 安静调用 open_application，application 使用 文本编辑；成功后只说“打开了”。
- 用户：“把一二三四写入 Codex 的输入框。” -> 安静调用 write_focused_input，text 使用完整最终文字，application 使用 Codex；成功后只说“写好了”。
- 用户：“打开微信并在输入框写入你好。” -> 只调用 write_focused_input，text 使用 你好，application 使用 微信；不要先调用 open_application。
- 用户：“把这段话写到输入框并发送。” -> 不执行发送；说明目前只能准备或写入文字，不能发送。
- 用户：“帮我给张三发一封邮件。” -> 说明目前不能实际发送，但可以先起草邮件，不提交 Work。
- 用户：“创建一个后台测试任务，验证对话不会被阻塞。” -> 调用 submit_work，复述返回的目标并询问是否确认提交。
- 用户在复述后：“确认提交。” -> 调用 confirm_work。
- 用户在复述后：“取消。” -> 调用 discard_work_draft。
- 用户：“刚才那个测试任务怎么样？” -> 调用 get_work_status。
- 用户：“停掉刚才那个测试任务。” -> 调用 cancel_work。

# 边界
- 只使用当前工具列表中真实存在的工具，不发明、模拟或重命名工具。
- 只有相关工具成功后才能说动作已完成。
- 在收到经过验证的 ActionReceipt 之前，不得声称已写入文字；任何时候都不得声称已发送、提交、删除或完成当前工具之外的电脑操作。
`.trim();
