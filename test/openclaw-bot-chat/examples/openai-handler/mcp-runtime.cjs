"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { executeTool } = require("./tool-policy.cjs");

function createMcpRuntimeManager(options) {
  const {
    readString,
    isRecord,
    tryParseJson,
    delayReject,
    truncateText,
    serializeError,
    debugLog,
    toolTimeoutMs,
    toolResultMaxChars,
    maxParallelTools,
    includeServerPrefix,
    allowedToolsRegex,
    blockedToolsRegex,
    maxToolsPerRequest,
    totalBudgetMs,
    fileEditEnabled,
    fileEditAllowedRoots,
  } = options;

  let runtimePromise;

  function isToolEnabled(toolName) {
    if (allowedToolsRegex && !allowedToolsRegex.test(toolName)) {
      return false;
    }
    if (blockedToolsRegex && blockedToolsRegex.test(toolName)) {
      return false;
    }
    return true;
  }

  function sanitizeToolPrefix(value) {
    return String(value).replace(/[^a-zA-Z0-9_-]+/g, "_");
  }

  function resolveMcpEnv(rawEnv) {
    const baseEnv = { PATH: process.env.PATH, LANG: "C.UTF-8" };
    if (!isRecord(rawEnv)) {
      return baseEnv;
    }

    for (const [key, value] of Object.entries(rawEnv)) {
      const text = String(value);
      if (process.env[text]) {
        baseEnv[key] = process.env[text];
        continue;
      }
      baseEnv[key] = text;
    }

    return baseEnv;
  }

  function normalizeMcpConfig(config) {
    if (isRecord(config.mcpServers)) {
      return config;
    }
    return { mcpServers: config };
  }

  function resolveConfigPath(rawPath) {
    if (path.isAbsolute(rawPath)) {
      return rawPath;
    }

    const candidates = [
      path.resolve(process.cwd(), rawPath),
      path.resolve(process.cwd(), "..", rawPath),
      path.resolve(process.cwd(), "..", "..", rawPath),
      path.resolve(process.cwd(), "..", "..", "..", rawPath),
    ];

    for (const candidate of candidates) {
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }

    return candidates[0];
  }

  function loadMcpConfig() {
    const rawJson = readString(process.env.OPENAI_COMPAT_MCP_SERVERS_JSON);
    if (rawJson) {
      const parsed = tryParseJson(rawJson);
      if (!isRecord(parsed)) {
        throw new Error("OPENAI_COMPAT_MCP_SERVERS_JSON must be a JSON object");
      }
      return normalizeMcpConfig(parsed);
    }

    const configPath = readString(process.env.OPENAI_COMPAT_MCP_CONFIG);
    if (!configPath) {
      return null;
    }

    const resolvedPath = resolveConfigPath(configPath);
    const raw = fs.readFileSync(resolvedPath, "utf8");
    const parsed = tryParseJson(raw);
    if (!isRecord(parsed)) {
      throw new Error(`OPENAI_COMPAT_MCP_CONFIG must point to a JSON object: ${resolvedPath}`);
    }
    return normalizeMcpConfig(parsed);
  }

  async function createRuntime() {
    const config = loadMcpConfig();
    if (!config || !isRecord(config.mcpServers)) {
      return null;
    }

    const sdk = await import("@modelcontextprotocol/sdk/client/index.js");
    const stdio = await import("@modelcontextprotocol/sdk/client/stdio.js");
    const runtime = {
      servers: new Map(),
      tools: [],
      connections: [],
      health: {},
    };

    for (const [serverName, serverConfig] of Object.entries(config.mcpServers)) {
      if (!isRecord(serverConfig)) {
        continue;
      }
      const command = readString(serverConfig.command);
      if (!command) {
        continue;
      }

      const args = Array.isArray(serverConfig.args)
        ? serverConfig.args.map((item) => String(item))
        : [];
      const env = resolveMcpEnv(serverConfig.env);
      const cwd = readString(serverConfig.cwd)
        ? path.resolve(readString(serverConfig.cwd))
        : process.cwd();

      const transport = new stdio.StdioClientTransport({ command, args, env, cwd });
      const client = new sdk.Client(
        { name: "openclaw-bot-chat-openai-handler", version: "1.0.0" },
        { capabilities: {} },
      );

      let listed;
      try {
        await client.connect(transport);
        listed = await client.listTools();
        runtime.connections.push(client);
        runtime.health[serverName] = { state: "ready" };
      } catch (error) {
        runtime.health[serverName] = { state: "unavailable", error: String(error.message || error) };
        await client.close().catch(() => {});
        continue;
      }
      for (const tool of listed.tools || []) {
        const exposedName = includeServerPrefix
          ? `${sanitizeToolPrefix(serverName)}__${tool.name}`
          : String(tool.name);
        const policy = serverConfig.tools && serverConfig.tools[tool.name];
        if (!policy || !Array.isArray(policy.capabilities) || !isToolEnabled(exposedName)) {
          continue;
        }
        runtime.servers.set(exposedName, {
          client,
          originalName: tool.name,
          definition: { name: exposedName, parameters: tool.inputSchema || { type: "object", additionalProperties: true }, policy: {
            capabilities: policy.capabilities,
            approvalRequired: policy.approvalRequired !== false,
            paths: Array.isArray(policy.paths) ? policy.paths : [],
          } },
        });
        runtime.tools.push({
          type: "function",
          function: {
            name: exposedName,
            description: tool.description || `MCP tool ${tool.name} from ${serverName}`,
            parameters: tool.inputSchema || { type: "object", additionalProperties: true },
          },
        });
      }
    }



    debugLog("handler.mcp.initialized", {
      servers: runtime.tools.map((tool) => tool.function.name),
    });

    return runtime;
  }

  async function getRuntime() {
    if (runtimePromise) {
      return runtimePromise;
    }
    runtimePromise = createRuntime().catch((error) => {
      runtimePromise = undefined;
      throw error;
    });
    return runtimePromise;
  }

  function createToolBudget() {
    return {
      startedAt: Date.now(),
      totalCalls: 0,
      totalCallLimit: maxToolsPerRequest,
    };
  }

  async function callTool(runtime, toolCall, toolBudget, context = {}) {
    if (Date.now() - toolBudget.startedAt > totalBudgetMs) {
      throw new Error(`MCP tool budget exceeded total duration ${totalBudgetMs}ms`);
    }
    if (toolBudget.totalCalls >= toolBudget.totalCallLimit) {
      throw new Error(`MCP tool budget exceeded max calls ${toolBudget.totalCallLimit}`);
    }
    toolBudget.totalCalls += 1;

    const functionName = toolCall.function && toolCall.function.name;
    const target = functionName ? runtime.servers.get(functionName) : undefined;
    if (!target) {
      throw new Error(`Unknown MCP tool: ${functionName || "<empty>"}`);
    }

    let args = {};
    const rawArgs = toolCall.function && toolCall.function.arguments;
    if (typeof rawArgs === "string" && rawArgs.trim()) {
      args = JSON.parse(rawArgs);
    }
    const timeout = AbortSignal.timeout(toolTimeoutMs);
    const signal = context.signal ? AbortSignal.any([context.signal, timeout]) : timeout;
    let result;
    try {
      result = await executeTool(target.definition, args, { ...context, signal }, () => target.client.callTool({ name: target.originalName, arguments: args }, undefined, { signal, timeout: toolTimeoutMs }));
    } catch (error) {
      if (signal.aborted) throw new Error("MCP call interrupted; external result is uncertain and must be reconciled before retry");
      throw error;
    }
    if (result.isError) throw new Error(stringifyToolResult(result));

    return truncateText(stringifyToolResult(result), toolResultMaxChars);
  }

  async function callToolsRound(runtime, toolCalls, toolBudget, context = {}) {
    const outputs = [];
    for (let index = 0; index < toolCalls.length; index += maxParallelTools) {
      const batch = toolCalls.slice(index, index + maxParallelTools);
      const settled = await Promise.allSettled(batch.map((toolCall) => callTool(runtime, toolCall, toolBudget, context)));
      for (let i = 0; i < settled.length; i += 1) {
        const item = settled[i];
        const toolCall = batch[i];
        if (item.status === "rejected" && (item.reason.code === "APPROVAL_PENDING" || context.signal?.aborted)) throw item.reason;
        if (item.status === "fulfilled") {
          outputs.push({ tool_call_id: toolCall.id, content: item.value });
        } else {
          outputs.push({
            tool_call_id: toolCall.id,
            content: `Tool execution failed: ${serializeError(item.reason).message || "unknown error"}`,
          });
        }
      }
    }
    return outputs;
  }

  function summarizeCapabilities(runtime) {
    const hasMcp = Boolean(runtime && Array.isArray(runtime.tools) && runtime.tools.length > 0);
    if (!hasMcp) {
      return JSON.stringify({ mcp_tools_enabled: false });
    }
    return JSON.stringify({
      mcp_tools_enabled: true,
      tool_count: runtime.tools.length,
      tool_names: runtime.tools.map((item) => item.function.name),
    });
  }

  function hasTool(runtime, toolName) {
    return Boolean(runtime && runtime.servers instanceof Map && runtime.servers.has(String(toolName || "")));
  }

  return {
    getRuntime,
    close: async () => { const runtime = await runtimePromise; await Promise.allSettled((runtime?.connections || []).map(client => client.close())); runtimePromise = undefined; },
    createToolBudget,
    callToolsRound,
    summarizeCapabilities,
    hasTool,
  };
}

function stringifyToolResult(result) {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return typeof result === "string" ? result : JSON.stringify(result);
  }

  if (Array.isArray(result.content)) {
    const text = result.content
      .map((item) => {
        if (item && typeof item === "object" && typeof item.text === "string") {
          return item.text;
        }
        return JSON.stringify(item);
      })
      .filter(Boolean)
      .join("\n");
    if (text) {
      return text;
    }
  }

  if (result.structuredContent && typeof result.structuredContent === "object") {
    return JSON.stringify(result.structuredContent);
  }

  return JSON.stringify(result);
}

module.exports = { createMcpRuntimeManager };
