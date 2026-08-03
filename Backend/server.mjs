// 功能：提供仅监听本机的 Realtime 会话入口，让 Friday 使用短期凭证连接 OpenAI。
// 职责：分离本地存活与模型就绪检查，暴露凭证、Work 与视觉确认动作工具，并管理会话配置、签发保护、账单状态和错误脱敏。
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
const talkPromptVersion = "2026-08-03.focused-write-v1";
const dictationReasoningEffort = choiceEnvironment(
  "FRIDAY_DICTATION_REASONING_EFFORT",
  "minimal",
  new Set(["minimal", "low", "medium", "high", "xhigh"])
);
const talkVoice = process.env.FRIDAY_TALK_VOICE || "marin";
const talkMaxOutputTokens = integerEnvironment("FRIDAY_TALK_MAX_OUTPUT_TOKENS", 640);
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
const upstreamReadinessTimeoutMilliseconds = integerEnvironment(
  "FRIDAY_UPSTREAM_READINESS_TIMEOUT_MS",
  3_000
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
  console.log(`Talk prompt version: ${talkPromptVersion}`);
  console.log(
    `Credential loop protection: ${credentialBurstLimit} attempts per `
      + `${credentialBurstWindowSeconds} seconds`
  );
  console.log(
    `OpenAI readiness timeout: ${upstreamReadinessTimeoutMilliseconds} ms`
  );
  console.log(
    `Input transcription: ${inputTranscriptionModel || "disabled (no additional transcription model)"}`
  );
  console.log(`Environment proxy configured: ${proxyConfigured ? "yes" : "no"}`);
  console.log(
    "Agent mode: confirmed local input write; background Work remains mock read-only"
  );
});

async function createClientCredential(mode = "dictation") {
  const isLegacy = realtimeApiStyle === "legacy";
  if (isLegacy && mode === "talk") {
    throw new RequestError("Talk mode requires the GA Realtime API style.");
  }
  const endpoint = isLegacy ? "/v1/realtime/sessions" : "/v1/realtime/client_secrets";
  const inputTranscription = inputTranscriptionModel
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
    max_output_tokens: talkMaxOutputTokens,
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
        turn_detection: {
          type: "semantic_vad",
          eagerness: talkVADEagerness,
          create_response: false,
          interrupt_response: false
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
    prompt_version: mode === "talk" ? talkPromptVersion : null,
    response_creation: mode === "talk" ? "client" : null,
    input_transcription_enabled: Boolean(inputTranscriptionModel),
    input_transcription_model: inputTranscriptionModel,
    agent_tools_enabled: mode === "talk",
    work_tools_enabled: mode === "talk" && Boolean(inputTranscriptionModel),
    visual_write_confirmation_enabled: mode === "talk"
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
    talk_vad_eagerness: talkVADEagerness,
    talk_reasoning_effort: supportsRealtimeReasoning(talkModel)
      ? talkReasoningEffort
      : null,
    talk_max_output_tokens: talkMaxOutputTokens,
    talk_prompt_version: talkPromptVersion,
    talk_response_creation: "client",
    upstream_status: upstreamStatus,
    api_style: realtimeApiStyle,
    proxy_configured: proxyConfigured,
    input_transcription_enabled: Boolean(inputTranscriptionModel),
    input_transcription_model: inputTranscriptionModel,
    agent_tools_enabled: true,
    work_tools_enabled: Boolean(inputTranscriptionModel),
    visual_write_confirmation_enabled: true,
    agent_mode: "confirmed_local_write",
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
    name: "wait_for_user",
    description: "仅当最新音频高置信度地只包含静音、极短的非语言噪声或明显的扬声器残留，且没有持续、可辨认的人声时调用。只要存在持续人声、可辨认词语或疑似对 Friday 的请求，就禁止调用；内容不清楚时应简短澄清。",
    parameters: {
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false
    }
  },
  {
    type: "function",
    name: "propose_focused_input_write",
    description: "当用户明确要求把一段确定文字写入、放入或填入当前输入框时调用。该工具只创建本地 ActionProposal 并展示完整预览，绝不会自行写入；用户必须在 Friday 界面点击‘写入’后，本地 ActionExecutor 才会复验启动对话时锁定的输入框并执行一次。不得用于发送消息、发送邮件、提交表单、密码输入、猜测目标或任何不可撤销操作。工具返回 succeeded 前不得声称已经写入；返回 unknown 时必须请用户查看原输入框。",
    parameters: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "将要展示给用户并写入输入框的完整最终文字。忠实保留用户原意，不补充未提供的事实；需要整理时先完成整理，再把完整结果放在这里。"
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
    description: "仅当 Friday 已复述待确认的任务草稿，并且用户随后清楚、完整地说出‘确认提交’时调用。模糊同意、背景人声、模型自行推断或首次提出任务都不能触发。运行时还会用该确认轮次的最终用户转写做本地校验。",
    parameters: {
      type: "object",
      properties: {
        draft_id: {
          type: "string",
          description: "submit_work 返回的 Friday WorkDraft ID；省略时使用本次 Talk 最近的待确认草稿。"
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
          description: "submit_work 返回的 Friday WorkDraft ID；省略时使用本次 Talk 最近的待确认草稿。"
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
          description: "运行时上下文中的 Friday Work ID；省略时使用本次 Talk 最近提交的任务。"
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
          description: "运行时上下文中的 Friday Work ID；省略时取消本次 Talk 最近提交且仍在运行的任务。"
        }
      },
      additionalProperties: false
    }
  }
];

const toolsWithoutFinalASR = new Set([
  "wait_for_user",
  "propose_focused_input_write"
]);
const activeTalkTools = inputTranscriptionModel
  ? talkTools
  : talkTools.filter(tool => toolsWithoutFinalASR.has(tool.name));

const talkInstructions = `
# 角色与目标
你是 Friday，Mac 上温和、自然、简洁的中文语音助手。
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
3. 用户明确要求把一段确定文字写入、放入或填入当前输入框时，调用 propose_focused_input_write。把完整最终文字放入 text；该工具只展示视觉预览，必须等待用户点击界面确认和本地回执。
4. 写入请求同时包含“发送、提交、发布、购买”等外部副作用时，不调用输入框写入工具；说明当前只能准备文字，不能完成外部动作。
5. 只有用户明确要求“创建后台测试任务”或“验证后台任务机制”时，才调用 submit_work 创建草稿；首次请求绝不能直接说任务已经提交。
6. 用户要求操作文件、邮件、网页、消息或账号中的其他真实动作时，当前没有可用工具。诚实说明暂时不能实际执行，并提供最接近的可用帮助；不要提交 Mock Work 冒充执行。
7. submit_work 返回 awaiting_confirmation 后，忠实复述 objective，并要求用户明确说“确认提交”或“取消”。只有下一轮用户清楚说出“确认提交”时才调用 confirm_work；用户明确取消时调用 discard_work_draft。
8. 用户询问本次 Talk 中已提交测试任务的进度时调用 get_work_status；用户明确要求停止时调用 cancel_work。

# 对话方式
- 直接、自然地回应，不播报“收听、思考、处理、输出”等阶段。
- 先说核心结论。普通回复控制在一到三句简短口语；只有用户明确要求细节时才展开。
- 每次都要完整结束当前句子。内容可能超出本轮长度时，宁可缩短为一个完整答复，也不要在半句话中停止。
- 语音回复不使用 Markdown、标题、编号流程或系统阶段标签。
- 将“Hey Friday”视为唤醒词，不视为具体任务。用户只说唤醒词时，简短回应并等待请求。
- 用户可以随时打断。停止上一段内容，优先处理最新的清晰请求。
- 不连续重复相同的问候、开场白或填充语。

# 用户主动选择的屏幕内容
- Friday 可能收到用户明确框选的一张屏幕图片。
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

# 当前输入框写入
- propose_focused_input_write 只提出写入建议。不要口头索要“好的”或“确认”，也不要把语音同意当作权限；用户会在 Friday 展开的确认界面查看完整文字并点击。
- 工具返回 rejected_by_user 或 cancelled 时，简短确认未写入，不要再次调用。
- 工具返回 failed 时说明原目标没有被修改；返回 unknown 时说明事件已发送但无法复验，请用户查看输入框；只有 succeeded 才能明确说已经写入。
- 写入成功仍不代表消息、邮件或表单已经发送。不得声称已发送、已提交或已发布。

# 模糊音频
- 进入本会话的音频已经经过本地近场人声过滤；只要听到持续人声、可辨认词语或疑似请求，优先把它当作用户在对 Friday 说话。
- 持续或完整的人声绝不能因为意图不明确、称呼不明确、句子残缺、口音或识别不确定而静默结束。能理解就直接回答，不能理解就只问一个简短澄清问题。
- 只有高置信度确认最新音频不含持续人声，例如纯静音、极短的碰撞声或明显的扬声器残留时，才调用 wait_for_user。
- 调用 wait_for_user 后不要继续生成口头回复，不要说“我在”“没听清”“请继续”或类似内容。

# 例子
- 用户：“帮我翻译框选的英文。” -> 直接用中文给出译文，不提交 Work。
- 用户：“把‘明天下午三点开会’写到当前输入框。” -> 调用 propose_focused_input_write，等待界面确认和回执。
- 用户：“把这段话写好并直接发给张三。” -> 不调用写入工具；说明可以起草，但不能发送。
- 用户：“帮我给张三发一封邮件。” -> 说明目前不能实际发送，但可以先起草邮件，不提交 Work。
- 用户：“创建一个后台测试任务，验证对话不会被阻塞。” -> 调用 submit_work，复述返回的目标并询问是否确认提交。
- 用户在复述后：“确认提交。” -> 调用 confirm_work。
- 用户在复述后：“取消。” -> 调用 discard_work_draft。
- 用户：“刚才那个测试任务怎么样？” -> 调用 get_work_status。
- 用户：“停掉刚才那个测试任务。” -> 调用 cancel_work。

# 边界
- 只使用当前工具列表中真实存在的工具，不发明、模拟或重命名工具。
- 只有相关工具成功后才能说动作已完成。
- 在收到本地 ActionReceipt 之前，不得声称已写入输入框；当前没有任何工具可以修改文件、发送消息或控制其他 Mac 功能。
`.trim();
