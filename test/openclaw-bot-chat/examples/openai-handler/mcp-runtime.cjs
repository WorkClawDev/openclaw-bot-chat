"use strict";

const fs = require("node:fs");
const path = require("node:path");

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
    const baseEnv = { ...process.env };
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

      await client.connect(transport);
      const listed = await client.listTools();
      for (const tool of listed.tools || []) {
        const exposedName = includeServerPrefix
          ? `${sanitizeToolPrefix(serverName)}__${tool.name}`
          : String(tool.name);
        if (!isToolEnabled(exposedName)) {
          continue;
        }
        runtime.servers.set(exposedName, {
          client,
          originalName: tool.name,
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

    if (runtime.tools.length === 0) {
      return null;
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

  async function callTool(runtime, toolCall, toolBudget) {
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
    enforceToolPermissions(functionName, args, {
      fileEditEnabled,
      fileEditAllowedRoots,
    });

    const result = await Promise.race([
      target.client.callTool({ name: target.originalName, arguments: args }),
      delayReject(toolTimeoutMs, `MCP tool timeout after ${toolTimeoutMs}ms: ${functionName}`),
    ]);
    return truncateText(stringifyToolResult(result), toolResultMaxChars);
  }

  async function callToolsRound(runtime, toolCalls, toolBudget) {
    const outputs = [];
    for (let index = 0; index < toolCalls.length; index += maxParallelTools) {
      const batch = toolCalls.slice(index, index + maxParallelTools);
      const settled = await Promise.allSettled(batch.map((toolCall) => callTool(runtime, toolCall, toolBudget)));
      for (let i = 0; i < settled.length; i += 1) {
        const item = settled[i];
        const toolCall = batch[i];
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
    createToolBudget,
    callToolsRound,
    summarizeCapabilities,
    hasTool,
  };
}

function enforceToolPermissions(functionName, args, options) {
  const { fileEditEnabled, fileEditAllowedRoots } = options;
  const toolName = String(functionName || "");

  if (!isPotentialWriteTool(toolName)) {
    return;
  }

  if (!fileEditEnabled) {
    throw new Error(`Tool '${toolName}' is blocked: file edit permission is disabled`);
  }

  if (!Array.isArray(fileEditAllowedRoots) || fileEditAllowedRoots.length === 0) {
    return;
  }

  const paths = extractPathLikeValues(args);
  for (const rawPath of paths) {
    const resolved = path.resolve(process.cwd(), rawPath);
    const allowed = fileEditAllowedRoots.some((root) => isWithinRoot(resolved, root));
    if (!allowed) {
      throw new Error(`Tool '${toolName}' attempted path outside allowed roots: ${rawPath}`);
    }
  }
}

function isPotentialWriteTool(toolName) {
  return /(write|edit|patch|create|delete|remove|move|rename|mkdir|exec|run|bash|shell)/i.test(toolName);
}

function extractPathLikeValues(value, keyPath = "") {
  const output = [];
  if (typeof value === "string") {
    if (looksLikePath(keyPath, value)) {
      output.push(value);
    }
    return output;
  }
  if (!value || typeof value !== "object") {
    return output;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      output.push(...extractPathLikeValues(item, keyPath));
    }
    return output;
  }
  for (const [key, nested] of Object.entries(value)) {
    const nextPath = keyPath ? `${keyPath}.${key}` : key;
    output.push(...extractPathLikeValues(nested, nextPath));
  }
  return output;
}

function looksLikePath(keyPath, value) {
  if (!value || value.length > 4096) {
    return false;
  }
  if (/^[a-z]+:\/\//i.test(value)) {
    return false;
  }

  if (looksLikePathKey(keyPath)) {
    return value.includes("/") || value.includes("\\") || value.startsWith(".") || value.startsWith("~");
  }

  return looksLikeFilesystemPath(value);
}

function looksLikePathKey(keyPath) {
  return /(^|\.)(path|paths|file|files|filepath|filename|target|destination|cwd|root|dir|directory|output|input)$/i.test(keyPath);
}

function looksLikeFilesystemPath(value) {
  return (
    value.startsWith(".") ||
    value.startsWith("~") ||
    value.startsWith("/") ||
    value.startsWith("\\") ||
    /^[a-z]:[\\/]/i.test(value) ||
    value.includes("/") ||
    value.includes("\\")
  );
}

function isWithinRoot(targetPath, rootPath) {
  const normalizedRoot = path.resolve(rootPath);
  const relative = path.relative(normalizedRoot, targetPath);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
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
