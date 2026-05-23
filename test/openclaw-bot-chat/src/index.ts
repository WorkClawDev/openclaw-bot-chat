import path from "node:path";

import { loadConfig, type PluginConfig } from "./config";
import {
  createRuntimeLogger,
  maskSecret,
  previewText,
  summarizeValue,
} from "./logger";
import { OpenClawBotRuntime } from "./runtime/bot";
import type {
  OpenClawAgent,
  OpenClawRequest,
  OpenClawResponse,
  PermissionApprovalDecision,
  PermissionApprovalRequest,
  PermissionApprover,
} from "./types";

const logger = createRuntimeLogger("[openclaw-bot-chat:agent]");

interface AgentHttpError extends Error {
  status?: number;
  responseBody?: unknown;
}

export async function main(): Promise<void> {
  const config = await loadConfig();
  logger.info("runtime.config.loaded", {
    configPath: config.configPath,
    backendUrl: config.botChatBaseUrl,
    mqttTcpUrl: config.mqttTcpUrl,
    stateDir: config.stateDir,
    defaultBot: config.defaultBot,
    botKeys: Object.keys(config.bots),
    openClawAgentUrl: config.openClawAgentUrl,
    openClawAgentHandler: config.openClawAgentHandler,
    permissionApprovalEnabled: config.permissionApprovalEnabled,
    permissionApprovalUrl: config.permissionApprovalUrl,
    permissionApprovalHandler: config.permissionApprovalHandler,
    accessKeyPreview: config.accessKey ? maskSecret(config.accessKey) : undefined,
  });
  const agent = await createOpenClawAgent(config);
  const permissionApprover = await createPermissionApprover(config);
  const runtime = new OpenClawBotRuntime(config, agent, permissionApprover);

  const shutdown = async (signal: string): Promise<void> => {
    console.info(`[openclaw-bot-chat] shutting down on ${signal}`);
    await runtime.stop();
    process.exit(0);
  };

  process.once("SIGINT", () => {
    void shutdown("SIGINT");
  });
  process.once("SIGTERM", () => {
    void shutdown("SIGTERM");
  });

  await runtime.start();
  console.info("[openclaw-bot-chat] runtime started");
}

export async function createOpenClawAgent(
  config: PluginConfig,
): Promise<OpenClawAgent> {
  if (config.openClawAgentHandler) {
    return loadHandlerAgent(config.openClawAgentHandler);
  }
  if (config.openClawAgentUrl) {
    return createHttpAgent(config.openClawAgentUrl, config.openClawAgentTimeoutMs);
  }

  return {
    async respond(): Promise<OpenClawResponse> {
      return {
        content:
          "OpenClaw agent is not configured. Set OPENCLAW_AGENT_HANDLER or OPENCLAW_AGENT_URL.",
      };
    },
  };
}

export async function createPermissionApprover(
  config: PluginConfig,
): Promise<PermissionApprover | undefined> {
  if (!config.permissionApprovalEnabled) {
    return undefined;
  }
  if (config.permissionApprovalHandler) {
    return loadApprovalHandler(config.permissionApprovalHandler);
  }
  if (config.permissionApprovalUrl) {
    return createApprovalHttpClient(
      config.permissionApprovalUrl,
      config.permissionApprovalTimeoutMs,
    );
  }
  logger.warn("permission.approval.enabled_but_missing_handler", {
    permissionApprovalEnabled: config.permissionApprovalEnabled,
  });
  return undefined;
}

async function loadHandlerAgent(handlerPath: string): Promise<OpenClawAgent> {
  const resolvedPath = path.isAbsolute(handlerPath)
    ? handlerPath
    : path.resolve(process.cwd(), handlerPath);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const loaded = require(resolvedPath) as unknown;

  const candidate =
    readRespondFunction(loaded) ??
    (loaded &&
    typeof loaded === "object" &&
    "default" in loaded
      ? readRespondFunction((loaded as { default?: unknown }).default)
      : undefined);

  if (!candidate) {
    throw new Error(
      `agent handler module ${resolvedPath} must export respond(request)`,
    );
  }

  logger.info("agent.handler.loaded", {
    handlerPath: resolvedPath,
  });

  return createInstrumentedAgent(
    "handler",
    {
      handlerPath: resolvedPath,
    },
    async (request) => candidate(request),
  );
}

function createHttpAgent(url: string, timeoutMs: number): OpenClawAgent {
  logger.info("agent.http.configured", {
    url,
    timeoutMs,
  });

  return createInstrumentedAgent(
    "http",
    {
      url,
      timeoutMs,
    },
    async (request: OpenClawRequest): Promise<OpenClawResponse> => {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(request),
        signal: AbortSignal.timeout(timeoutMs),
      });

      const rawText = await response.text();
      const parsed = rawText ? parseJson(rawText) : undefined;

      if (!response.ok) {
        const error = new Error(
          `OpenClaw agent request failed with ${response.status}: ${rawText}`,
        ) as AgentHttpError;
        error.status = response.status;
        error.responseBody = parsed ?? rawText;
        throw error;
      }

      if (
        parsed &&
        typeof parsed === "object" &&
        !Array.isArray(parsed) &&
        "data" in parsed
      ) {
        return parsed["data"] as OpenClawResponse;
      }
      return parsed as OpenClawResponse;
    },
  );
}

async function loadApprovalHandler(
  handlerPath: string,
): Promise<PermissionApprover> {
  const resolvedPath = path.isAbsolute(handlerPath)
    ? handlerPath
    : path.resolve(process.cwd(), handlerPath);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const loaded = require(resolvedPath) as unknown;
  const candidate =
    readApproveFunction(loaded) ??
    (loaded &&
    typeof loaded === "object" &&
    "default" in loaded
      ? readApproveFunction((loaded as { default?: unknown }).default)
      : undefined);
  if (!candidate) {
    throw new Error(
      `permission handler module ${resolvedPath} must export approve(request)`,
    );
  }

  logger.info("permission.handler.loaded", {
    handlerPath: resolvedPath,
  });

  return {
    async approve(
      request: PermissionApprovalRequest,
    ): Promise<PermissionApprovalDecision> {
      return await candidate(request);
    },
  };
}

function createApprovalHttpClient(
  url: string,
  timeoutMs: number,
): PermissionApprover {
  logger.info("permission.http.configured", { url, timeoutMs });
  return {
    async approve(
      request: PermissionApprovalRequest,
    ): Promise<PermissionApprovalDecision> {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(request),
        signal: AbortSignal.timeout(timeoutMs),
      });

      const rawText = await response.text();
      const parsed = rawText ? parseJson(rawText) : undefined;
      if (!response.ok) {
        const error = new Error(
          `permission approval request failed with ${response.status}: ${rawText}`,
        ) as AgentHttpError;
        error.status = response.status;
        error.responseBody = parsed ?? rawText;
        throw error;
      }
      if (parsed && typeof parsed === "object" && "data" in parsed) {
        return parsed["data"] as PermissionApprovalDecision;
      }
      return (parsed as PermissionApprovalDecision) ?? { approved: false };
    },
  };
}

function createInstrumentedAgent(
  kind: "handler" | "http",
  baseFields: Record<string, unknown>,
  responder: (request: OpenClawRequest) => Promise<OpenClawResponse>,
): OpenClawAgent {
  return {
    async respond(request: OpenClawRequest): Promise<OpenClawResponse> {
      const startedAt = Date.now();
      logger.debug("agent.request.start", {
        kind,
        ...baseFields,
        sessionId: request.session_id,
        contentPreview: previewText(request.content),
        metadata: summarizeValue(request.metadata),
      });

      try {
        const response = await responder(request);
        logger.debug("agent.request.success", {
          kind,
          ...baseFields,
          durationMs: Date.now() - startedAt,
          sessionId: request.session_id,
          responsePreview: previewText(response.content),
          responseMetadata: summarizeValue(response.metadata),
        });
        return response;
      } catch (error) {
        const httpError = error as AgentHttpError;
        logger.error(
          "agent.request.failed",
          {
            kind,
            ...baseFields,
            durationMs: Date.now() - startedAt,
            sessionId: request.session_id,
            contentPreview: previewText(request.content),
            metadata: summarizeValue(request.metadata),
            status: httpError.status,
            responseBody: summarizeValue(httpError.responseBody),
          },
          error,
        );
        throw error;
      }
    },
  };
}

function readRespondFunction(
  value: unknown,
): ((request: OpenClawRequest) => Promise<OpenClawResponse> | OpenClawResponse) | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }
  if ("respond" in value && typeof value["respond"] === "function") {
    return value["respond"] as (
      request: OpenClawRequest,
    ) => Promise<OpenClawResponse> | OpenClawResponse;
  }
  return undefined;
}

function readApproveFunction(
  value: unknown,
):
  | ((
      request: PermissionApprovalRequest,
    ) =>
      | Promise<PermissionApprovalDecision>
      | PermissionApprovalDecision)
  | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }
  if ("approve" in value && typeof value["approve"] === "function") {
    return value["approve"] as (
      request: PermissionApprovalRequest,
    ) => Promise<PermissionApprovalDecision> | PermissionApprovalDecision;
  }
  return undefined;
}

function parseJson(value: string): unknown {
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

if (require.main === module) {
  void main().catch((error) => {
    console.error("[openclaw-bot-chat] fatal error:", error);
    process.exit(1);
  });
}
