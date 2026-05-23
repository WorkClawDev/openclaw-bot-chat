"use strict";

function readString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return undefined;
}

function readInt(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") {
    return fallback;
  }
  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value)) {
    throw new Error(`${name} must be an integer`);
  }
  return value;
}

function readFloat(name) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") {
    return undefined;
  }
  const value = Number.parseFloat(raw);
  if (!Number.isFinite(value)) {
    throw new Error(`${name} must be a number`);
  }
  return value;
}

function readBooleanEnv(name, fallback) {
  const raw = process.env[name];
  if (typeof raw !== "string") {
    return fallback;
  }
  switch (raw.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
      return true;
    case "0":
    case "false":
    case "no":
    case "off":
      return false;
    default:
      return fallback;
  }
}

function parseRegexEnv(name) {
  const raw = readString(process.env[name]);
  if (!raw) {
    return null;
  }
  return new RegExp(raw);
}

function requiredEnv(name) {
  const value = process.env[name];
  if (!value || !value.trim()) {
    throw new Error(`${name} is required`);
  }
  return value.trim();
}

function tryParseJson(value) {
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

function isRecord(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function safeJsonStringify(value) {
  try {
    return JSON.stringify(value);
  } catch {
    return undefined;
  }
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function delayReject(timeoutMs, message) {
  return new Promise((_, reject) => {
    setTimeout(() => reject(new Error(message)), timeoutMs);
  });
}

function truncateText(value, maxChars) {
  if (typeof value !== "string") {
    return "";
  }
  if (!Number.isFinite(maxChars) || maxChars <= 0 || value.length <= maxChars) {
    return value;
  }
  return `${value.slice(0, maxChars)}\n...[truncated ${value.length - maxChars} chars]`;
}

function serializeError(error) {
  if (error instanceof Error) {
    return {
      name: error.name,
      message: error.message,
      stack: error.stack,
    };
  }
  return {
    message: typeof error === "string" ? error : safeJsonStringify(error) || String(error),
  };
}

module.exports = {
  readString,
  readInt,
  readFloat,
  readBooleanEnv,
  parseRegexEnv,
  requiredEnv,
  tryParseJson,
  isRecord,
  safeJsonStringify,
  sleep,
  delayReject,
  truncateText,
  serializeError,
};
