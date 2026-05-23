"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function createLocalToolRuntime(options) {
  const {
    enabled,
    readRoots,
    writeRoots,
    maxReadBytes,
    maxWriteBytes,
    allowHidden,
    rgMaxMatches,
    rgMaxBytes,
    bashEnabled,
    bashAllowedRoots,
    bashTimeoutMs,
    bashMaxOutputChars,
    maxToolsPerRequest,
    totalBudgetMs,
    toolTimeoutMs,
    toolResultMaxChars,
    maxParallelTools,
    serializeError,
    truncateText,
    debugLog,
  } = options;

  let runtimePromise;

  async function getRuntime() {
    if (runtimePromise) {
      return runtimePromise;
    }
    runtimePromise = Promise.resolve(enabled ? buildRuntime() : null)
      .catch((error) => {
        runtimePromise = undefined;
        throw error;
      });
    return runtimePromise;
  }

  function buildRuntime() {
    const runtime = {
      tools: [],
      invokers: new Map(),
    };

    const defs = [
      {
        name: "local__fs_read_text",
        description: "Read a UTF-8/other encoded text file from allowed filesystem roots.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Target file path." },
            encoding: { type: "string", default: "utf8" },
            max_bytes: { type: "integer", minimum: 1 },
          },
          required: ["path"],
        },
        invoke: (args) => fsReadText(args, { roots: readRoots, maxBytes: maxReadBytes, allowHidden }),
      },
      {
        name: "local__fs_read_base64",
        description: "Read a binary file and return base64 content.",
        parameters: {
          type: "object",
          properties: { path: { type: "string" }, max_bytes: { type: "integer", minimum: 1 } },
          required: ["path"],
        },
        invoke: (args) => fsReadBase64(args, { roots: readRoots, maxBytes: maxReadBytes, allowHidden }),
      },
      {
        name: "local__fs_write_text",
        description: "Write text to a file in allowed write roots.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string" },
            content: { type: "string" },
            encoding: { type: "string", default: "utf8" },
            append: { type: "boolean", default: false },
          },
          required: ["path", "content"],
        },
        invoke: (args) => fsWriteText(args, { roots: writeRoots, maxBytes: maxWriteBytes, allowHidden }),
      },
      {
        name: "local__fs_write_base64",
        description: "Decode base64 and write binary content to file in allowed write roots.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string" },
            content_base64: { type: "string" },
            append: { type: "boolean", default: false },
          },
          required: ["path", "content_base64"],
        },
        invoke: (args) => fsWriteBase64(args, { roots: writeRoots, maxBytes: maxWriteBytes, allowHidden }),
      },
      {
        name: "local__fs_list_dir",
        description: "List files/directories under an allowed read root.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", default: "." },
            recursive: { type: "boolean", default: false },
            max_entries: { type: "integer", minimum: 1, default: 200 },
          },
        },
        invoke: (args) => fsListDir(args, { roots: readRoots, allowHidden }),
      },
      {
        name: "local__code_search_rg",
        description: "Use ripgrep (rg) to locate files/content in allowed read roots for code editing workflows.",
        parameters: {
          type: "object",
          properties: {
            pattern: { type: "string" },
            path: { type: "string", default: "." },
            glob: { type: "string" },
            case_sensitive: { type: "boolean", default: false },
            max_matches: { type: "integer", minimum: 1 },
            context_lines: { type: "integer", minimum: 0, default: 0 },
          },
          required: ["pattern"],
        },
        invoke: (args) => codeSearchRg(args, { roots: readRoots, allowHidden, maxMatches: rgMaxMatches, maxBytes: rgMaxBytes }),
      },
      {
        name: "local__fs_replace_text",
        description: "Edit file by replacing target text, useful after locating code via rg.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string" },
            old_text: { type: "string" },
            new_text: { type: "string" },
            replace_all: { type: "boolean", default: false },
            expected_replacements: { type: "integer", minimum: 1 },
          },
          required: ["path", "old_text", "new_text"],
        },
        invoke: (args) => fsReplaceText(args, { roots: writeRoots, allowHidden, maxWriteBytes }),
      },
      {
        name: "local__bash_exec",
        description: "Execute a bash command for coding workflows with cwd restricted to allowed roots.",
        parameters: {
          type: "object",
          properties: {
            command: { type: "string" },
            cwd: { type: "string", default: "." },
            timeout_ms: { type: "integer", minimum: 100 },
          },
          required: ["command"],
        },
        invoke: (args) => runBash(args, {
          enabled: bashEnabled,
          allowedRoots: bashAllowedRoots,
          allowHidden,
          defaultTimeoutMs: bashTimeoutMs,
          maxOutputChars: bashMaxOutputChars,
        }),
      },
      {
        name: "local__text_encode",
        description: "Encode text to base64/hex/url/uriComponent string.",
        parameters: {
          type: "object",
          properties: {
            text: { type: "string" },
            encoding: { type: "string", enum: ["base64", "hex", "url", "uriComponent"], default: "base64" },
          },
          required: ["text"],
        },
        invoke: encodeText,
      },
      {
        name: "local__text_decode",
        description: "Decode text from base64/hex/url/uriComponent encoding.",
        parameters: {
          type: "object",
          properties: {
            data: { type: "string" },
            encoding: { type: "string", enum: ["base64", "hex", "url", "uriComponent"], default: "base64" },
          },
          required: ["data"],
        },
        invoke: decodeText,
      },
    ];

    for (const tool of defs) {
      runtime.tools.push({ type: "function", function: { name: tool.name, description: tool.description, parameters: tool.parameters } });
      runtime.invokers.set(tool.name, tool.invoke);
    }

    debugLog("handler.local_tools.initialized", {
      tool_names: runtime.tools.map((item) => item.function.name),
      count: runtime.tools.length,
    });

    return runtime;
  }

  function createToolBudget() {
    return {
      startedAt: Date.now(),
      totalCalls: 0,
      totalCallLimit: maxToolsPerRequest,
    };
  }

  async function callTool(runtime, toolCall, toolBudget) {
    if (!runtime) {
      throw new Error("Local runtime is not enabled");
    }
    if (Date.now() - toolBudget.startedAt > totalBudgetMs) {
      throw new Error(`Local tool budget exceeded total duration ${totalBudgetMs}ms`);
    }
    if (toolBudget.totalCalls >= toolBudget.totalCallLimit) {
      throw new Error(`Local tool budget exceeded max calls ${toolBudget.totalCallLimit}`);
    }
    toolBudget.totalCalls += 1;

    const functionName = toolCall.function && toolCall.function.name;
    const invoke = functionName ? runtime.invokers.get(functionName) : undefined;
    if (!invoke) {
      throw new Error(`Unknown local tool: ${functionName || "<empty>"}`);
    }

    let args = {};
    const rawArgs = toolCall.function && toolCall.function.arguments;
    if (typeof rawArgs === "string" && rawArgs.trim()) {
      args = JSON.parse(rawArgs);
    }

    const result = await Promise.race([
      Promise.resolve().then(() => invoke(args)),
      new Promise((_, reject) => setTimeout(() => reject(new Error(`Local tool timeout after ${toolTimeoutMs}ms: ${functionName}`)), toolTimeoutMs)),
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
        outputs.push(item.status === "fulfilled"
          ? { tool_call_id: toolCall.id, content: item.value }
          : { tool_call_id: toolCall.id, content: `Tool execution failed: ${serializeError(item.reason).message || "unknown error"}` });
      }
    }
    return outputs;
  }

  function hasTool(runtime, toolName) {
    return Boolean(runtime && runtime.invokers instanceof Map && runtime.invokers.has(String(toolName || "")));
  }

  function summarizeCapabilities(runtime) {
    if (!runtime || runtime.tools.length === 0) {
      return JSON.stringify({ local_tools_enabled: false });
    }
    return JSON.stringify({
      local_tools_enabled: true,
      tool_count: runtime.tools.length,
      tool_names: runtime.tools.map((item) => item.function.name),
    });
  }

  return {
    getRuntime,
    createToolBudget,
    callToolsRound,
    hasTool,
    summarizeCapabilities,
  };
}

function codeSearchRg(args, options) {
  const pattern = getRequiredString(args, "pattern");
  const rawPath = getOptionalString(args, "path", ".");
  const searchPath = resolveAndAuthorizePath(rawPath, options.roots, options.allowHidden);
  const maxMatches = readPositiveInt(args && args.max_matches, options.maxMatches);
  const contextLines = readNonNegativeInt(args && args.context_lines, 0);
  const commandArgs = ["--line-number", "--column", "--no-heading", "--color", "never", "--max-count", String(maxMatches), "--context", String(contextLines)];
  if (!Boolean(args && args.case_sensitive)) {
    commandArgs.push("--ignore-case");
  }
  if (typeof args?.glob === "string" && args.glob.trim()) {
    commandArgs.push("--glob", args.glob.trim());
  }
  commandArgs.push(pattern, searchPath);

  const result = spawnSync("rg", commandArgs, { encoding: "utf8", maxBuffer: options.maxBytes, cwd: process.cwd() });
  if (result.error) {
    throw new Error(`Failed to run rg: ${result.error.message}`);
  }
  const exitCode = typeof result.status === "number" ? result.status : -1;
  if (exitCode > 1) {
    throw new Error(`rg failed with exit code ${exitCode}: ${(result.stderr || "").trim()}`);
  }

  return {
    pattern,
    path: searchPath,
    matched: exitCode === 0,
    stdout: (result.stdout || "").trim(),
    stderr: (result.stderr || "").trim(),
    exit_code: exitCode,
  };
}

function runBash(args, options) {
  if (!options.enabled) {
    throw new Error("local__bash_exec is disabled by OPENAI_COMPAT_BASH_ENABLED");
  }
  const command = getRequiredString(args, "command");
  const rawCwd = getOptionalString(args, "cwd", ".");
  const cwd = resolveAndAuthorizePath(rawCwd, options.allowedRoots, options.allowHidden);
  const timeout = readPositiveInt(args && args.timeout_ms, options.defaultTimeoutMs);

  const result = spawnSync("bash", ["-lc", command], {
    cwd,
    encoding: "utf8",
    timeout,
    maxBuffer: 1024 * 1024,
  });
  if (result.error) {
    throw new Error(`bash execution failed: ${result.error.message}`);
  }

  return {
    cwd,
    command,
    exit_code: typeof result.status === "number" ? result.status : -1,
    signal: result.signal || null,
    stdout: truncateString(String(result.stdout || ""), options.maxOutputChars),
    stderr: truncateString(String(result.stderr || ""), options.maxOutputChars),
  };
}

function fsReadText(args, options) {
  const rawPath = getRequiredString(args, "path");
  const filePath = resolveAndAuthorizePath(rawPath, options.roots, options.allowHidden);
  const stat = fs.statSync(filePath);
  ensureFile(stat, filePath);
  const maxBytes = readPositiveInt(args.max_bytes, options.maxBytes);
  if (stat.size > maxBytes) {
    throw new Error(`File too large (${stat.size} bytes), limit is ${maxBytes}`);
  }
  const encoding = getOptionalString(args, "encoding", "utf8");
  return { path: filePath, bytes: stat.size, encoding, content: fs.readFileSync(filePath, { encoding }) };
}

function fsReadBase64(args, options) {
  const rawPath = getRequiredString(args, "path");
  const filePath = resolveAndAuthorizePath(rawPath, options.roots, options.allowHidden);
  const stat = fs.statSync(filePath);
  ensureFile(stat, filePath);
  const maxBytes = readPositiveInt(args.max_bytes, options.maxBytes);
  if (stat.size > maxBytes) {
    throw new Error(`File too large (${stat.size} bytes), limit is ${maxBytes}`);
  }
  return { path: filePath, bytes: stat.size, content_base64: fs.readFileSync(filePath).toString("base64") };
}

function fsWriteText(args, options) {
  const rawPath = getRequiredString(args, "path");
  const content = getRequiredString(args, "content");
  const filePath = resolveAndAuthorizePath(rawPath, options.roots, options.allowHidden);
  const mode = Boolean(args && args.append) ? "append" : "write";
  const encoding = getOptionalString(args, "encoding", "utf8");
  const byteLength = Buffer.byteLength(content, encoding);
  if (byteLength > options.maxBytes) {
    throw new Error(`Write content too large (${byteLength} bytes), limit is ${options.maxBytes}`);
  }
  ensureParentDirectory(filePath);
  if (mode === "append") {
    fs.appendFileSync(filePath, content, { encoding });
  } else {
    fs.writeFileSync(filePath, content, { encoding });
  }
  return { path: filePath, bytes_written: byteLength, mode, encoding };
}

function fsWriteBase64(args, options) {
  const rawPath = getRequiredString(args, "path");
  const encoded = getRequiredString(args, "content_base64");
  const filePath = resolveAndAuthorizePath(rawPath, options.roots, options.allowHidden);
  const data = Buffer.from(encoded, "base64");
  if (data.byteLength > options.maxBytes) {
    throw new Error(`Write content too large (${data.byteLength} bytes), limit is ${options.maxBytes}`);
  }
  ensureParentDirectory(filePath);
  if (Boolean(args && args.append)) {
    fs.appendFileSync(filePath, data);
  } else {
    fs.writeFileSync(filePath, data);
  }
  return { path: filePath, bytes_written: data.byteLength, mode: Boolean(args && args.append) ? "append" : "write" };
}

function fsListDir(args, options) {
  const rawPath = getOptionalString(args, "path", ".");
  const recursive = Boolean(args && args.recursive);
  const maxEntries = readPositiveInt(args && args.max_entries, 200);
  const target = resolveAndAuthorizePath(rawPath, options.roots, options.allowHidden);
  const stat = fs.statSync(target);
  if (!stat.isDirectory()) {
    throw new Error(`Path is not a directory: ${target}`);
  }
  const entries = [];
  collectDirEntries(target, target, recursive, maxEntries, entries, options.allowHidden);
  return { path: target, recursive, count: entries.length, entries };
}

function fsReplaceText(args, options) {
  const rawPath = getRequiredString(args, "path");
  const oldText = getRequiredString(args, "old_text");
  const newText = getRequiredString(args, "new_text");
  const replaceAll = Boolean(args && args.replace_all);
  const filePath = resolveAndAuthorizePath(rawPath, options.roots, options.allowHidden);
  const content = fs.readFileSync(filePath, "utf8");
  const occurrences = countOccurrences(content, oldText);
  if (occurrences === 0) {
    throw new Error(`Target text not found in ${filePath}`);
  }

  let replacedCount = 0;
  const updated = replaceAll
    ? content.replaceAll(oldText, () => {
      replacedCount += 1;
      return newText;
    })
    : content.replace(oldText, () => {
      replacedCount += 1;
      return newText;
    });

  const expected = args && args.expected_replacements;
  if (expected !== undefined && expected !== null && expected !== "") {
    const expectedCount = readPositiveInt(expected, 1);
    if (expectedCount !== replacedCount) {
      throw new Error(`Replacement count mismatch: expected ${expectedCount}, actual ${replacedCount}`);
    }
  }

  const byteLength = Buffer.byteLength(updated, "utf8");
  if (byteLength > options.maxWriteBytes) {
    throw new Error(`Edited file too large (${byteLength} bytes), limit is ${options.maxWriteBytes}`);
  }
  fs.writeFileSync(filePath, updated, "utf8");
  return { path: filePath, replacements: replacedCount, previous_occurrences: occurrences, bytes_written: byteLength };
}

function encodeText(args) {
  const text = getRequiredString(args, "text");
  const encoding = getOptionalString(args, "encoding", "base64");
  switch (encoding) {
    case "base64":
      return { encoding, data: Buffer.from(text, "utf8").toString("base64") };
    case "hex":
      return { encoding, data: Buffer.from(text, "utf8").toString("hex") };
    case "url":
      return { encoding, data: encodeURI(text) };
    case "uriComponent":
      return { encoding, data: encodeURIComponent(text) };
    default:
      throw new Error(`Unsupported encoding: ${encoding}`);
  }
}

function decodeText(args) {
  const data = getRequiredString(args, "data");
  const encoding = getOptionalString(args, "encoding", "base64");
  switch (encoding) {
    case "base64":
      return { encoding, text: Buffer.from(data, "base64").toString("utf8") };
    case "hex":
      return { encoding, text: Buffer.from(data, "hex").toString("utf8") };
    case "url":
      return { encoding, text: decodeURI(data) };
    case "uriComponent":
      return { encoding, text: decodeURIComponent(data) };
    default:
      throw new Error(`Unsupported encoding: ${encoding}`);
  }
}

function collectDirEntries(basePath, currentPath, recursive, maxEntries, output, allowHidden) {
  if (output.length >= maxEntries) {
    return;
  }
  const names = fs.readdirSync(currentPath);
  for (const name of names) {
    if (!allowHidden && name.startsWith(".")) {
      continue;
    }
    const fullPath = path.join(currentPath, name);
    const stat = fs.statSync(fullPath);
    output.push({
      path: fullPath,
      relative_path: path.relative(basePath, fullPath) || ".",
      type: stat.isDirectory() ? "directory" : stat.isFile() ? "file" : "other",
      size: stat.size,
      mtime_ms: stat.mtimeMs,
    });
    if (output.length >= maxEntries) {
      return;
    }
    if (recursive && stat.isDirectory()) {
      collectDirEntries(basePath, fullPath, recursive, maxEntries, output, allowHidden);
      if (output.length >= maxEntries) {
        return;
      }
    }
  }
}

function resolveAndAuthorizePath(rawPath, roots, allowHidden) {
  const resolved = path.resolve(process.cwd(), String(rawPath));
  if (!allowHidden && containsHiddenSegment(resolved)) {
    throw new Error(`Path is blocked by hidden file policy: ${rawPath}`);
  }
  if (!Array.isArray(roots) || roots.length === 0) {
    return resolved;
  }
  const allowed = roots.some((root) => isWithinRoot(resolved, root));
  if (!allowed) {
    throw new Error(`Path is outside allowed roots: ${rawPath}`);
  }
  return resolved;
}

function containsHiddenSegment(targetPath) {
  const normalized = path.resolve(targetPath);
  const segments = normalized.split(path.sep).filter(Boolean);
  return segments.some((segment) => segment.startsWith("."));
}

function ensureParentDirectory(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function ensureFile(stat, filePath) {
  if (!stat.isFile()) {
    throw new Error(`Path is not a file: ${filePath}`);
  }
}

function isWithinRoot(targetPath, rootPath) {
  const normalizedRoot = path.resolve(rootPath);
  const relative = path.relative(normalizedRoot, targetPath);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function truncateString(text, maxChars) {
  if (!Number.isFinite(maxChars) || maxChars <= 0 || text.length <= maxChars) {
    return text;
  }
  return `${text.slice(0, maxChars)}\n...[truncated ${text.length - maxChars} chars]`;
}

function stringifyToolResult(result) {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return typeof result === "string" ? result : JSON.stringify(result);
  }
  return JSON.stringify(result);
}

function getRequiredString(args, key) {
  const value = getOptionalString(args, key, "");
  if (!value) {
    throw new Error(`Missing required argument: ${key}`);
  }
  return value;
}

function getOptionalString(args, key, fallback) {
  const value = args && args[key];
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function readPositiveInt(rawValue, fallback) {
  if (rawValue === undefined || rawValue === null || rawValue === "") {
    return fallback;
  }
  const value = Number.parseInt(rawValue, 10);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`Expected positive integer, got: ${rawValue}`);
  }
  return value;
}

function readNonNegativeInt(rawValue, fallback) {
  if (rawValue === undefined || rawValue === null || rawValue === "") {
    return fallback;
  }
  const value = Number.parseInt(rawValue, 10);
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`Expected non-negative integer, got: ${rawValue}`);
  }
  return value;
}

function countOccurrences(content, target) {
  if (!target) {
    return 0;
  }
  let count = 0;
  let fromIndex = 0;
  while (fromIndex < content.length) {
    const found = content.indexOf(target, fromIndex);
    if (found < 0) {
      break;
    }
    count += 1;
    fromIndex = found + target.length;
  }
  return count;
}

module.exports = { createLocalToolRuntime };
