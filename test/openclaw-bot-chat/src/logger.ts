type LogLevel = "debug" | "info" | "warn" | "error";

const DEBUG_ENABLED = readBooleanEnv("BOT_CHAT_RUNTIME_DEBUG", false);
const BODY_MAX_LENGTH = readIntegerEnv("BOT_CHAT_LOG_BODY_MAX_LEN", 600);
const SUMMARY_MAX_LENGTH = readIntegerEnv("BOT_CHAT_LOG_SUMMARY_MAX_LEN", 1_500);

export interface RuntimeLogger {
  debug(event: string, fields?: Record<string, unknown>): void;
  info(event: string, fields?: Record<string, unknown>): void;
  warn(event: string, fields?: Record<string, unknown>): void;
  error(event: string, fields?: Record<string, unknown>, error?: unknown): void;
}

export function createRuntimeLogger(prefix: string): RuntimeLogger {
  return {
    debug(event, fields) {
      log("debug", prefix, event, fields);
    },
    info(event, fields) {
      log("info", prefix, event, fields);
    },
    warn(event, fields) {
      log("warn", prefix, event, fields);
    },
    error(event, fields, error) {
      log("error", prefix, event, fields, error);
    },
  };
}

export function isRuntimeDebugEnabled(): boolean {
  return DEBUG_ENABLED;
}

export function previewText(value: unknown, maxLength = BODY_MAX_LENGTH): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }

  const normalized = value.replace(/\s+/g, " ").trim();
  if (!normalized) {
    return undefined;
  }
  if (normalized.length <= maxLength) {
    return normalized;
  }
  return `${normalized.slice(0, maxLength)}...<truncated>`;
}

export function summarizeValue(
  value: unknown,
  maxLength = SUMMARY_MAX_LENGTH,
): string | number | boolean | null | undefined {
  if (
    value === null ||
    value === undefined ||
    typeof value === "number" ||
    typeof value === "boolean"
  ) {
    return value;
  }
  if (typeof value === "string") {
    return previewText(value, maxLength);
  }

  const serialized = safeJsonStringify(value);
  if (!serialized) {
    return undefined;
  }
  if (serialized.length <= maxLength) {
    return serialized;
  }
  return `${serialized.slice(0, maxLength)}...<truncated>`;
}

export function maskSecret(value: string, visible = 6): string {
  const trimmed = value.trim();
  if (!trimmed) {
    return "<empty>";
  }
  if (trimmed.length <= visible) {
    return `${"*".repeat(Math.max(trimmed.length - 1, 0))}${trimmed.slice(-1)}`;
  }
  return `${trimmed.slice(0, visible)}...`;
}

function log(
  level: LogLevel,
  prefix: string,
  event: string,
  fields?: Record<string, unknown>,
  error?: unknown,
): void {
  if (level === "debug" && !DEBUG_ENABLED) {
    return;
  }

  const payload: Record<string, unknown> = {
    ts: new Date().toISOString(),
    level,
    event,
    ...(fields ?? {}),
  };
  if (error !== undefined) {
    payload.error = serializeError(error);
  }

  const line = `${prefix} ${safeJsonStringify(payload) ?? JSON.stringify(payload)}`;
  switch (level) {
    case "debug":
      console.debug(line);
      return;
    case "info":
      console.info(line);
      return;
    case "warn":
      console.warn(line);
      return;
    case "error":
      console.error(line);
      return;
  }
}

function serializeError(error: unknown): Record<string, unknown> {
  if (error instanceof Error) {
    return {
      name: error.name,
      message: error.message,
      ...(error.stack ? { stack: error.stack } : {}),
    };
  }

  return {
    message: typeof error === "string" ? error : safeJsonStringify(error) ?? String(error),
  };
}

function safeJsonStringify(value: unknown): string | undefined {
  try {
    return JSON.stringify(value);
  } catch {
    return undefined;
  }
}

function readBooleanEnv(name: string, fallback: boolean): boolean {
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

function readIntegerEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (typeof raw !== "string" || raw.trim() === "") {
    return fallback;
  }

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return parsed;
}
