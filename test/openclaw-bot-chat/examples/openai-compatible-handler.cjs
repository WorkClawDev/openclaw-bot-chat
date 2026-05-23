"use strict";

const {
  readString,
  readInt,
  readBooleanEnv,
  parseRegexEnv,
  requiredEnv,
  isRecord,
  safeJsonStringify,
  truncateText,
  serializeError,
} = require("./openai-handler/utils.cjs");
const { createSessionState } = require("./openai-handler/session-state.cjs");
const { createModelClient } = require("./openai-handler/model-client.cjs");
const { createMcpRuntimeManager } = require("./openai-handler/mcp-runtime.cjs");
const { createLocalToolRuntime } = require("./openai-handler/local-runtime.cjs");

const DEFAULT_SYSTEM_PROMPT = [
  "You are OpenClaw Agent, a coding-focused assistant running inside OpenClaw Bot Chat.",
  "Work in a Claude Code / OpenCode style: structure your thinking, ask clarifying questions when requirements are ambiguous, then execute decisively.",
  "Prefer practical, production-ready answers with explicit assumptions, tradeoffs, and next steps.",
  "When tools are available, use them purposefully and cite concrete evidence from tool outputs; do not invent results.",
  "For coding tasks, provide implementation-oriented guidance (files, functions, data flow, risk points).",
  "Keep response concise but complete; default to Chinese if the user writes Chinese.",
  "If the user asks what system you are in, explain that you are an OpenClaw test agent connected through Bot Chat.",
].join(" ");

const DEBUG_ENABLED = readBooleanEnv("BOT_CHAT_RUNTIME_DEBUG", true);
const BODY_MAX_LENGTH = readInt("BOT_CHAT_LOG_BODY_MAX_LEN", 600);
const HISTORY_TURNS = readInt("OPENAI_COMPAT_HISTORY_TURNS", 8);
const MAX_TOOL_ROUNDS = readInt("OPENAI_COMPAT_MCP_MAX_TOOL_ROUNDS", 6);
const MCP_TOOL_TIMEOUT_MS = readInt("OPENAI_COMPAT_MCP_TOOL_TIMEOUT_MS", 20000);
const MCP_TOOL_RESULT_MAX_CHARS = readInt("OPENAI_COMPAT_MCP_TOOL_RESULT_MAX_CHARS", 8000);
const MCP_MAX_PARALLEL_TOOLS = Math.max(1, readInt("OPENAI_COMPAT_MCP_MAX_PARALLEL", 4));
const MCP_MAX_TOOLS_PER_REQUEST = Math.max(1, readInt("OPENAI_COMPAT_MCP_MAX_TOOLS_PER_REQUEST", 12));
const MCP_TOTAL_BUDGET_MS = Math.max(1000, readInt("OPENAI_COMPAT_MCP_TOTAL_BUDGET_MS", 45000));
const OPENAI_MAX_RETRIES = Math.max(0, readInt("OPENAI_COMPAT_MAX_RETRIES", 2));
const OPENAI_RETRY_BACKOFF_MS = Math.max(100, readInt("OPENAI_COMPAT_RETRY_BACKOFF_MS", 1200));
const MEMORY_MAX_NOTES = Math.max(1, readInt("OPENAI_COMPAT_MEMORY_MAX_NOTES", 24));
const CONTEXT_COMPRESSION_ENABLED = readBooleanEnv("OPENAI_COMPAT_CONTEXT_COMPRESSION_ENABLED", true);
const CONTEXT_COMPRESSION_MAX_ATTEMPTS = Math.max(1, readInt("OPENAI_COMPAT_CONTEXT_COMPRESSION_MAX_ATTEMPTS", 3));
const CONTEXT_COMPRESSION_TARGET_CHARS = Math.max(2000, readInt("OPENAI_COMPAT_CONTEXT_COMPRESSION_TARGET_CHARS", 22000));
const CONTEXT_COMPRESSION_RECENT_RATIO = Math.min(
  0.9,
  Math.max(0.2, readInt("OPENAI_COMPAT_CONTEXT_COMPRESSION_RECENT_RATIO_PERCENT", 60) / 100),
);
const CONTEXT_COMPRESSION_SUMMARY_CHARS = Math.max(300, readInt("OPENAI_COMPAT_CONTEXT_COMPRESSION_SUMMARY_CHARS", 1800));
const CONTEXT_COMPRESSION_TOOL_CHARS = Math.max(200, readInt("OPENAI_COMPAT_CONTEXT_COMPRESSION_TOOL_CHARS", 2200));
const CONTEXT_WINDOW_CHARS = Math.max(
  CONTEXT_COMPRESSION_TARGET_CHARS,
  readInt("OPENAI_COMPAT_CONTEXT_WINDOW_CHARS", 32000),
);
const CONTEXT_COMPRESSION_TRIGGER_RATIO = Math.min(
  0.99,
  Math.max(0.5, readInt("OPENAI_COMPAT_CONTEXT_COMPRESSION_TRIGGER_RATIO_PERCENT", 90) / 100),
);
const TOOL_EDIT_ENABLED = readBooleanEnv("OPENAI_COMPAT_TOOL_EDIT_ENABLED", false);
const TOOL_EDIT_ALLOWED_ROOTS = parseCsvEnv("OPENAI_COMPAT_TOOL_EDIT_ALLOWED_ROOTS")
  .map((item) => item.trim())
  .filter(Boolean);
const FILESYSTEM_TOOLS_ENABLED = readBooleanEnv("OPENAI_COMPAT_FILESYSTEM_ENABLED", true);
const FILESYSTEM_READ_ROOTS = parseCsvEnv("OPENAI_COMPAT_FS_ALLOWED_READ_ROOTS")
  .map((item) => item.trim())
  .filter(Boolean);
const FILESYSTEM_WRITE_ROOTS = parseCsvEnv("OPENAI_COMPAT_FS_ALLOWED_WRITE_ROOTS")
  .map((item) => item.trim())
  .filter(Boolean);
const FILESYSTEM_MAX_READ_BYTES = Math.max(1024, readInt("OPENAI_COMPAT_FS_MAX_READ_BYTES", 262144));
const FILESYSTEM_MAX_WRITE_BYTES = Math.max(1024, readInt("OPENAI_COMPAT_FS_MAX_WRITE_BYTES", 262144));
const FILESYSTEM_ALLOW_HIDDEN = readBooleanEnv("OPENAI_COMPAT_FS_ALLOW_HIDDEN", false);
const FILESYSTEM_RG_MAX_MATCHES = Math.max(1, readInt("OPENAI_COMPAT_FS_RG_MAX_MATCHES", 300));
const FILESYSTEM_RG_MAX_BYTES = Math.max(4096, readInt("OPENAI_COMPAT_FS_RG_MAX_BYTES", 262144));
const BASH_ENABLED = readBooleanEnv("OPENAI_COMPAT_BASH_ENABLED", false);
const BASH_ALLOWED_ROOTS = parseCsvEnv("OPENAI_COMPAT_BASH_ALLOWED_ROOTS")
  .map((item) => item.trim())
  .filter(Boolean);
const BASH_TIMEOUT_MS = Math.max(100, readInt("OPENAI_COMPAT_BASH_TIMEOUT_MS", 20000));
const BASH_MAX_OUTPUT_CHARS = Math.max(512, readInt("OPENAI_COMPAT_BASH_MAX_OUTPUT_CHARS", 12000));

const mcpManager = createMcpRuntimeManager({
  readString,
  isRecord,
  tryParseJson: (value) => {
    try {
      return JSON.parse(value);
    } catch {
      return value;
    }
  },
  delayReject: (timeoutMs, message) => new Promise((_, reject) => setTimeout(() => reject(new Error(message)), timeoutMs)),
  truncateText,
  serializeError,
  debugLog,
  toolTimeoutMs: MCP_TOOL_TIMEOUT_MS,
  toolResultMaxChars: MCP_TOOL_RESULT_MAX_CHARS,
  maxParallelTools: MCP_MAX_PARALLEL_TOOLS,
  includeServerPrefix: readBooleanEnv("OPENAI_COMPAT_MCP_INCLUDE_SERVER_PREFIX", true),
  allowedToolsRegex: parseRegexEnv("OPENAI_COMPAT_MCP_ALLOWED_TOOLS"),
  blockedToolsRegex: parseRegexEnv("OPENAI_COMPAT_MCP_BLOCKED_TOOLS"),
  maxToolsPerRequest: MCP_MAX_TOOLS_PER_REQUEST,
  totalBudgetMs: MCP_TOTAL_BUDGET_MS,
  fileEditEnabled: TOOL_EDIT_ENABLED,
  fileEditAllowedRoots: TOOL_EDIT_ALLOWED_ROOTS,
});
const localToolRuntime = createLocalToolRuntime({
  enabled: FILESYSTEM_TOOLS_ENABLED,
  readRoots: FILESYSTEM_READ_ROOTS,
  writeRoots: FILESYSTEM_WRITE_ROOTS,
  maxReadBytes: FILESYSTEM_MAX_READ_BYTES,
  maxWriteBytes: FILESYSTEM_MAX_WRITE_BYTES,
  allowHidden: FILESYSTEM_ALLOW_HIDDEN,
  rgMaxMatches: FILESYSTEM_RG_MAX_MATCHES,
  rgMaxBytes: FILESYSTEM_RG_MAX_BYTES,
  bashEnabled: BASH_ENABLED,
  bashAllowedRoots: BASH_ALLOWED_ROOTS,
  bashTimeoutMs: BASH_TIMEOUT_MS,
  bashMaxOutputChars: BASH_MAX_OUTPUT_CHARS,
  maxToolsPerRequest: MCP_MAX_TOOLS_PER_REQUEST,
  totalBudgetMs: MCP_TOTAL_BUDGET_MS,
  toolTimeoutMs: MCP_TOOL_TIMEOUT_MS,
  toolResultMaxChars: MCP_TOOL_RESULT_MAX_CHARS,
  maxParallelTools: MCP_MAX_PARALLEL_TOOLS,
  serializeError,
  truncateText,
  debugLog,
});

const sessionState = createSessionState({
  historyTurns: HISTORY_TURNS,
  memoryMaxNotes: MEMORY_MAX_NOTES,
  previewText,
  readContentText,
  readString,
  truncateText,
});

const modelClient = createModelClient({
  tryParseJson: (value) => {
    try {
      return JSON.parse(value);
    } catch {
      return value;
    }
  },
  isRecord,
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  readFloat: (name) => {
    const raw = process.env[name];
    if (raw === undefined || raw === "") {
      return undefined;
    }
    const value = Number.parseFloat(raw);
    if (!Number.isFinite(value)) {
      throw new Error(`${name} must be a number`);
    }
    return value;
  },
  readInt,
  readContentText,
  sanitizeAssistantText,
  summarizeValue,
  debugLog,
});

exports.respond = async function respond(request) {
  const startedAt = Date.now();
  const content = String(request && request.content ? request.content : "").trim();
  const metadata = isRecord(request && request.metadata) ? request.metadata : {};
  const sessionId = readString(request && request.session_id) || readString(metadata.dialog_id) || "default";
  const logBase = {
    session_id: sessionId,
    dialog_id: readString(metadata.dialog_id),
    message_id: readString(metadata.message_id),
  };

  debugLog("handler.request.start", {
    ...logBase,
    content_preview: previewText(content),
    metadata: summarizeValue(metadata),
  });

  if (shouldSkipReply(metadata)) {
    return { content: "", metadata: { content_type: "text", skip_reply: true } };
  }

  if (!content) {
    return { content: "收到空消息。", metadata: { content_type: "text" } };
  }

  if (content === "/ping") {
    return { content: "pong", metadata: { content_type: "text" } };
  }

  if (content === "/meta") {
    return { content: JSON.stringify(metadata, null, 2), metadata: { content_type: "text" } };
  }

  if (content === "/reset") {
    sessionState.clearSession(sessionId);
    return { content: "上下文已清空。", metadata: { content_type: "text" } };
  }

  if (content === "/help") {
    return {
      content: [
        "可用调试指令：",
        "- /ping：连通性检查",
        "- /meta：查看当前 metadata",
        "- /reset：清空会话记忆",
        "- /memory：查看记忆便签",
        "- /memory + 文本：添加记忆便签",
        "- /memory clear：清空记忆便签",
        "- /tools：查看当前可用工具（MCP + 本地文件系统/rg/编辑工具）",
      ].join("\n"),
      metadata: { content_type: "text" },
    };
  }

  if (content === "/memory") {
    const notes = sessionState.getMemoryNotes(sessionId);
    return {
      content: notes.length > 0 ? `当前记忆便签：\n${notes.map((item, index) => `${index + 1}. ${item}`).join("\n")}` : "当前没有记忆便签。",
      metadata: { content_type: "text" },
    };
  }

  if (content === "/memory clear") {
    sessionState.clearMemory(sessionId);
    return { content: "记忆便签已清空。", metadata: { content_type: "text" } };
  }

  if (content.startsWith("/memory ")) {
    const note = content.slice("/memory ".length).trim();
    if (!note || note === "clear") {
      return { content: "请在 /memory 后提供要保存的便签文本。", metadata: { content_type: "text" } };
    }
    sessionState.appendMemoryNote(sessionId, note);
    return { content: "记忆便签已保存。", metadata: { content_type: "text" } };
  }

  const endpoint = resolveChatCompletionsUrl(requiredEnv("OPENAI_COMPAT_BASE_URL"));
  const apiKey = requiredEnv("OPENAI_COMPAT_API_KEY");
  const model = process.env.OPENAI_COMPAT_MODEL || "gpt-4o-mini";
  const mcpRuntime = await mcpManager.getRuntime();
  const localRuntime = await localToolRuntime.getRuntime();
  const combinedRuntime = combineRuntime(localRuntime, mcpRuntime);

  if (content === "/tools") {
    const toolNames = combinedRuntime.tools.length > 0
      ? combinedRuntime.tools.map((item) => `- ${item.function.name}`).join("\n")
      : "- (none)";
    return { content: `当前可用工具：\n${toolNames}`, metadata: { content_type: "text" } };
  }

  const requestState = buildRequestState({
    systemPrompt: process.env.OPENAI_COMPAT_SYSTEM_PROMPT || DEFAULT_SYSTEM_PROMPT,
    sessionId,
    content,
    metadata,
    mcpRuntime,
    localRuntime,
  });

  const text = await runModelLoop({
    endpoint,
    apiKey,
    model,
    requestState,
    mcpRuntime,
    localRuntime,
    timeoutMs: readInt("OPENAI_COMPAT_TIMEOUT_MS", 60000),
    logBase,
    startedAt,
  });

  sessionState.appendConversationTurn(sessionId, "user", content);
  sessionState.appendConversationTurn(sessionId, "assistant", text);
  return { content: text, metadata: { content_type: "text" } };
};

async function runModelLoop(options) {
  const { endpoint, apiKey, model, requestState, mcpRuntime, localRuntime, timeoutMs, logBase, startedAt } = options;
  const toolBudget = mcpManager.createToolBudget();
  const localToolBudget = localToolRuntime.createToolBudget();
  const combinedRuntime = combineRuntime(localRuntime, mcpRuntime);
  let compressionAttempts = 0;

  for (let round = 0; round <= MAX_TOOL_ROUNDS; round += 1) {
    if (CONTEXT_COMPRESSION_ENABLED) {
      const applied = tryCompressByWindowUsage({
        requestState,
        logBase,
        round,
        reason: "proactive_pre_request",
      });
      if (applied) {
        compressionAttempts += 1;
      }
    }

    const payload = modelClient.buildPayload(model, requestState.messages, combinedRuntime);
    const { response, parsed, rawText } = await modelClient.requestModelWithRetry({
      endpoint,
      apiKey,
      payload,
      timeoutMs,
      maxRetries: OPENAI_MAX_RETRIES,
      retryBackoffMs: OPENAI_RETRY_BACKOFF_MS,
      logBase: { ...logBase, round },
    });

    if (!response.ok) {
      if (
        CONTEXT_COMPRESSION_ENABLED &&
        compressionAttempts < CONTEXT_COMPRESSION_MAX_ATTEMPTS &&
        isContextOverflowError(response.status, parsed, rawText)
      ) {
        const beforeChars = estimateMessagesChars(requestState.messages);
        requestState.messages = compressMessagesForContextWindow(requestState.messages);
        const afterChars = estimateMessagesChars(requestState.messages);
        compressionAttempts += 1;
        debugLog("handler.context_compression.applied", {
          ...logBase,
          round,
          compression_attempt: compressionAttempts,
          status: response.status,
          before_chars: beforeChars,
          after_chars: afterChars,
          trigger_ratio: CONTEXT_COMPRESSION_TRIGGER_RATIO,
          response_preview: previewText(typeof rawText === "string" ? rawText : String(rawText || "")),
        });
        round -= 1;
        continue;
      }
      throw new Error(`OpenAI-compatible request failed with ${response.status}: ${rawText}`);
    }

    const assistantMessage = modelClient.extractAssistantMessage(parsed);
    if (!assistantMessage) {
      throw new Error("OpenAI-compatible response did not contain assistant message");
    }

    if (assistantMessage.tool_calls && assistantMessage.tool_calls.length > 0) {
      requestState.messages.push(assistantMessage.raw);
      const toolResults = await executeToolCalls({
        toolCalls: assistantMessage.tool_calls,
        mcpRuntime,
        mcpBudget: toolBudget,
        localRuntime,
        localBudget: localToolBudget,
      });
      for (const result of toolResults) {
        requestState.messages.push({ role: "tool", tool_call_id: result.tool_call_id, content: result.content });
      }
      if (CONTEXT_COMPRESSION_ENABLED) {
        const applied = tryCompressByWindowUsage({
          requestState,
          logBase,
          round,
          reason: "post_tool_calls",
        });
        if (applied) {
          compressionAttempts += 1;
        }
      }
      continue;
    }

    const text = modelClient.extractAssistantText(assistantMessage);
    if (!text) {
      throw new Error("OpenAI-compatible response did not contain assistant text");
    }

    debugLog("handler.model_request.success", {
      ...logBase,
      endpoint,
      model,
      duration_ms: Date.now() - startedAt,
      response_preview: previewText(text),
    });

    return text;
  }

  throw new Error(`MCP tool loop exceeded ${MAX_TOOL_ROUNDS} rounds`);
}

function isContextOverflowError(status, parsed, rawText) {
  if (status !== 400 && status !== 413 && status !== 422) {
    return false;
  }
  const raw = typeof rawText === "string" ? rawText : "";
  const parsedText = safeJsonStringify(parsed) || "";
  const combined = `${raw}\n${parsedText}`.toLowerCase();
  return [
    "maximum context length",
    "context_length_exceeded",
    "prompt is too long",
    "too many tokens",
    "token limit",
    "reduce the length",
    "max context",
  ].some((pattern) => combined.includes(pattern));
}

function compressMessagesForContextWindow(messages) {
  if (!Array.isArray(messages) || messages.length <= 2) {
    return Array.isArray(messages) ? messages : [];
  }

  const systemMessage = messages[0] && messages[0].role === "system" ? messages[0] : null;
  const body = systemMessage ? messages.slice(1) : messages.slice();

  const recentCharBudget = Math.max(
    800,
    Math.floor(CONTEXT_COMPRESSION_TARGET_CHARS * CONTEXT_COMPRESSION_RECENT_RATIO),
  );
  let usedChars = 0;
  const recent = [];
  const archived = [];

  for (let index = body.length - 1; index >= 0; index -= 1) {
    const message = truncateMessageForCompression(body[index]);
    const size = estimateSingleMessageChars(message);
    if (usedChars + size <= recentCharBudget || recent.length === 0) {
      recent.unshift(message);
      usedChars += size;
    } else {
      archived.unshift(message);
    }
  }

  const summary = summarizeArchivedMessages(archived);
  const compressed = [];
  if (systemMessage) {
    compressed.push(systemMessage);
  }
  if (summary) {
    compressed.push({
      role: "system",
      content: `Compressed earlier context:\n${summary}`,
    });
  }
  compressed.push(...recent);

  while (estimateMessagesChars(compressed) > CONTEXT_COMPRESSION_TARGET_CHARS && compressed.length > 2) {
    const removableIndex = summary ? 2 : 1;
    if (compressed.length <= removableIndex) {
      break;
    }
    compressed.splice(removableIndex, 1);
  }

  return compressed;
}

function tryCompressByWindowUsage(options) {
  const { requestState, logBase, round, reason } = options;
  const beforeChars = estimateMessagesChars(requestState.messages);
  const usageRatio = CONTEXT_WINDOW_CHARS > 0 ? beforeChars / CONTEXT_WINDOW_CHARS : 0;

  if (usageRatio < CONTEXT_COMPRESSION_TRIGGER_RATIO) {
    return false;
  }

  requestState.messages = compressMessagesForContextWindow(requestState.messages);
  const afterChars = estimateMessagesChars(requestState.messages);
  debugLog("handler.context_compression.proactive", {
    ...logBase,
    round,
    reason,
    before_chars: beforeChars,
    after_chars: afterChars,
    context_window_chars: CONTEXT_WINDOW_CHARS,
    trigger_ratio: CONTEXT_COMPRESSION_TRIGGER_RATIO,
    usage_ratio: Number(usageRatio.toFixed(4)),
  });
  return true;
}

function truncateMessageForCompression(message) {
  if (!isRecord(message)) {
    return message;
  }
  const role = readString(message.role);
  if (role !== "tool" && role !== "assistant") {
    return message;
  }
  const text = readContentText(message.content);
  if (!text || text.length <= CONTEXT_COMPRESSION_TOOL_CHARS) {
    return message;
  }
  return {
    ...message,
    content: truncateText(text, CONTEXT_COMPRESSION_TOOL_CHARS),
  };
}

function summarizeArchivedMessages(messages) {
  if (!Array.isArray(messages) || messages.length === 0) {
    return "";
  }
  const lines = messages
    .map((message) => {
      if (!isRecord(message)) {
        return "";
      }
      const role = readString(message.role) || "unknown";
      const text = previewText(readContentText(message.content)) || summarizeValue(message.content);
      if (!text) {
        return `${role}: (empty)`;
      }
      return `${role}: ${text}`;
    })
    .filter(Boolean);
  return truncateText(lines.join("\n"), CONTEXT_COMPRESSION_SUMMARY_CHARS);
}

function estimateMessagesChars(messages) {
  if (!Array.isArray(messages)) {
    return 0;
  }
  return messages.reduce((sum, item) => sum + estimateSingleMessageChars(item), 0);
}

function estimateSingleMessageChars(message) {
  if (!isRecord(message)) {
    return 0;
  }
  const role = readString(message.role) || "";
  const content = readContentText(message.content);
  const toolCalls = Array.isArray(message.tool_calls) ? safeJsonStringify(message.tool_calls) : "";
  return role.length + content.length + (toolCalls ? toolCalls.length : 0) + 32;
}

function buildRequestState(options) {
  const { systemPrompt, sessionId, content, metadata, mcpRuntime, localRuntime } = options;
  const metadataSummary = JSON.stringify(summarizeMetadata(metadata));
  const history = sessionState.buildHistoryWithSummary(sessionId);
  const memory = sessionState.getMemoryNotes(sessionId);
  const userContent = buildUserContent(content, metadata);
  const capabilitySummary = JSON.stringify({
    mcp: JSON.parse(mcpManager.summarizeCapabilities(mcpRuntime)),
    local: JSON.parse(localToolRuntime.summarizeCapabilities(localRuntime)),
  });

  return {
    messages: [
      {
        role: "system",
        content: [
          systemPrompt,
          `Session metadata: ${metadataSummary}`,
          `Runtime capabilities: ${capabilitySummary}`,
          `User intent hints: ${buildIntentHints(content)}`,
          `Session memory notes: ${memory.length > 0 ? memory.join(" | ") : "(none)"}`,
          "Behavior policy: always ground your answer in user input and tool outputs; never fabricate tool execution.",
        ].join("\n\n"),
      },
      ...history,
      { role: "user", content: userContent },
    ],
  };
}

function combineRuntime(localRuntime, mcpRuntime) {
  return {
    tools: [
      ...(localRuntime && Array.isArray(localRuntime.tools) ? localRuntime.tools : []),
      ...(mcpRuntime && Array.isArray(mcpRuntime.tools) ? mcpRuntime.tools : []),
    ],
  };
}

async function executeToolCalls(options) {
  const { toolCalls, mcpRuntime, mcpBudget, localRuntime, localBudget } = options;
  const outputs = [];
  for (const toolCall of toolCalls) {
    const toolName = toolCall && toolCall.function ? toolCall.function.name : undefined;
    if (localToolRuntime.hasTool(localRuntime, toolName)) {
      const result = await localToolRuntime.callToolsRound(localRuntime, [toolCall], localBudget);
      outputs.push(...result);
      continue;
    }
    if (mcpManager.hasTool(mcpRuntime, toolName)) {
      const result = await mcpManager.callToolsRound(mcpRuntime, [toolCall], mcpBudget);
      outputs.push(...result);
      continue;
    }
    outputs.push({
      tool_call_id: toolCall.id,
      content: `Tool execution failed: unknown tool '${toolName || "<empty>"}'`,
    });
  }
  return outputs;
}

function buildIntentHints(content) {
  const lowered = String(content || "").toLowerCase();
  const hints = [];
  if (/(设计|架构|architecture|refactor|重构|方案|plan)/i.test(content)) hints.push("architecture_or_planning");
  if (/(bug|报错|错误|exception|失败|panic)/i.test(content)) hints.push("debugging");
  if (/(代码|code|实现|开发|agent|mcp|tool)/i.test(lowered)) hints.push("implementation_heavy");
  return hints.length > 0 ? hints.join(",") : "general_dialog";
}

function shouldSkipReply(metadata) {
  if (!isRecord(metadata)) {
    return false;
  }
  const channelContext = isRecord(metadata.channel_context) ? metadata.channel_context : undefined;
  if (!channelContext) {
    return false;
  }
  const channelType = readString(channelContext.type);
  if (channelType !== "group" && channelType !== "channel") {
    return false;
  }
  if (metadata.mentioned_current_bot === false) {
    return true;
  }
  const botId = readString(channelContext.botId);
  if (!botId) {
    return false;
  }
  const messageMeta = isRecord(metadata.message_meta) ? metadata.message_meta : undefined;
  const mentionedBotIds = Array.isArray(messageMeta && messageMeta.mentioned_bot_ids)
    ? messageMeta.mentioned_bot_ids.filter((item) => typeof item === "string")
    : [];
  return mentionedBotIds.length > 0 && !mentionedBotIds.includes(botId);
}

function summarizeMetadata(metadata) {
  const summary = {
    session_id: readString(metadata.session_id),
    dialog_id: readString(metadata.dialog_id),
    message_id: readString(metadata.message_id),
    from_id: readString(metadata.from_id),
    content_type: readString(metadata.content_type),
  };
  const channelContext = isRecord(metadata.channel_context) ? metadata.channel_context : undefined;
  if (channelContext) {
    summary.channel_context = {
      id: readString(channelContext.id),
      type: readString(channelContext.type),
      userId: readString(channelContext.userId),
      guildId: readString(channelContext.guildId),
      groupId: readString(channelContext.groupId),
    };
  }
  return summary;
}

function buildUserContent(content, metadata) {
  const imageUrl = readImageUrlFromMetadata(metadata);
  if (!imageUrl) {
    return content;
  }
  const blocks = [];
  const trimmedContent = typeof content === "string" ? content.trim() : "";
  blocks.push({ type: "text", text: trimmedContent || "Please analyze the attached image and reply briefly." });
  blocks.push({ type: "image_url", image_url: { url: imageUrl } });
  return blocks;
}

function readImageUrlFromMetadata(metadata) {
  if (!isRecord(metadata)) {
    return undefined;
  }
  const contentType = readString(
    metadata.content_type,
    isRecord(metadata.message_meta) ? metadata.message_meta.content_type : undefined,
  );
  if (contentType !== "image") {
    return undefined;
  }
  const messageMeta = isRecord(metadata.message_meta) ? metadata.message_meta : undefined;
  const asset = messageMeta && isRecord(messageMeta.asset) ? messageMeta.asset : undefined;
  return readString(
    asset && asset.download_url,
    asset && asset.external_url,
    asset && asset.source_url,
    messageMeta && messageMeta.image_url,
    messageMeta && messageMeta.url,
  );
}

function resolveChatCompletionsUrl(baseUrl) {
  const url = new URL(baseUrl);
  const pathname = url.pathname.replace(/\/+$/, "");
  if (pathname.endsWith("/chat/completions")) return url.toString();
  if (pathname.endsWith("/v1")) {
    url.pathname = `${pathname}/chat/completions`;
    return url.toString();
  }
  url.pathname = `${pathname}/v1/chat/completions`;
  return url.toString();
}

function sanitizeAssistantText(text) {
  if (typeof text !== "string") return "";
  return text.replace(/^<think>[\s\S]*?<\/think>\s*/i, "").trim();
}

function readContentText(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    return value
      .map((item) => {
        if (typeof item === "string") return item;
        if (isRecord(item)) return readString(item.text, item.content);
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  if (isRecord(value)) {
    if (typeof value.text === "string") return value.text;
    if (Array.isArray(value.content)) return readContentText(value.content);
  }
  return "";
}

function debugLog(event, fields) {
  if (!DEBUG_ENABLED) {
    return;
  }
  emitLog("debug", event, fields);
}

function emitLog(level, event, fields, error) {
  const payload = {
    ts: new Date().toISOString(),
    level,
    event,
    ...(fields || {}),
    ...(error ? { error: serializeError(error) } : {}),
  };
  const line = `[openclaw-bot-chat:handler] ${safeJsonStringify(payload) || JSON.stringify(payload)}`;
  if (level === "error") {
    console.error(line);
    return;
  }
  console.debug(line);
}

function previewText(value) {
  if (typeof value !== "string") return undefined;
  const normalized = value.replace(/\s+/g, " ").trim();
  if (!normalized) return undefined;
  if (normalized.length <= BODY_MAX_LENGTH) return normalized;
  return `${normalized.slice(0, BODY_MAX_LENGTH)}...<truncated>`;
}

function summarizeValue(value) {
  if (value === null || value === undefined || typeof value === "number" || typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") return previewText(value);
  const serialized = safeJsonStringify(value);
  if (!serialized) return undefined;
  if (serialized.length <= BODY_MAX_LENGTH * 2) return serialized;
  return `${serialized.slice(0, BODY_MAX_LENGTH * 2)}...<truncated>`;
}

function parseCsvEnv(name) {
  const raw = process.env[name];
  if (!raw) {
    return [];
  }
  return raw.split(",");
}
