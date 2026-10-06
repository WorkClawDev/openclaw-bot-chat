import {
  BOT_CHAT_DEFAULT_ACCOUNT_ID,
  type BotChatChannelConfig,
  type BotChatCredentialStatus,
  type InspectedBotChatAccount,
} from "./channel-api.js";
import { normalizeBotChatConfig, resolveDefaultBotChatAccountId } from "./config.js";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function isSecretRef(value: unknown): value is { source: string; provider: string; id: string } {
  return (
    isRecord(value) &&
    typeof value.source === "string" &&
    typeof value.provider === "string" &&
    typeof value.id === "string"
  );
}

function hasConfiguredSecretInput(value: unknown): boolean {
  return isSecretRef(value);
}

function getBotChatChannelConfig(cfg: Record<string, unknown>): Record<string, unknown> {
  const channels = isRecord(cfg.channels) ? cfg.channels : undefined;
  return isRecord(channels?.["bot-chat"]) ? (channels["bot-chat"] as Record<string, unknown>) : cfg;
}

function inspectBotKeyValue(value: unknown): {
  botKey: string;
  botKeySource: "config";
  botKeyStatus: Exclude<BotChatCredentialStatus, "missing">;
} | null {
  const normalized = readString(value);
  if (normalized) {
    return {
      botKey: normalized,
      botKeySource: "config",
      botKeyStatus: "available",
    };
  }
  if (hasConfiguredSecretInput(value)) {
    return {
      botKey: "",
      botKeySource: "config",
      botKeyStatus: "configured_unavailable",
    };
  }
  return null;
}

export function inspectBotChatAccount(params: {
  cfg: Record<string, unknown>;
  accountId?: string | null;
  envBotKey?: string | null;
}): InspectedBotChatAccount {
  const accountId = params.accountId ?? resolveDefaultBotChatAccountId(params.cfg);
  const channelConfig = getBotChatChannelConfig(params.cfg);
  const normalized = normalizeBotChatConfig(channelConfig, {});
  const enabled = normalized.enabled !== false;
  const configuredBotKey = inspectBotKeyValue(channelConfig.botKey);

  if (configuredBotKey) {
    return buildInspectedAccount({
      accountId,
      enabled,
      normalized,
      botKey: configuredBotKey.botKey,
      botKeySource: configuredBotKey.botKeySource,
      botKeyStatus: configuredBotKey.botKeyStatus,
    });
  }

  const allowEnv = accountId === BOT_CHAT_DEFAULT_ACCOUNT_ID;
  const envBotKey = allowEnv ? readString(params.envBotKey ?? process.env.BOT_CHAT_BOT_KEY) : undefined;
  if (envBotKey) {
    return buildInspectedAccount({
      accountId,
      enabled,
      normalized,
      botKey: envBotKey,
      botKeySource: "env",
      botKeyStatus: "available",
    });
  }

  return buildInspectedAccount({
    accountId,
    enabled,
    normalized,
    botKey: "",
    botKeySource: "none",
    botKeyStatus: "missing",
  });
}

function buildInspectedAccount(params: {
  accountId: string;
  enabled: boolean;
  normalized: BotChatChannelConfig;
  botKey: string;
  botKeySource: "env" | "config" | "none";
  botKeyStatus: BotChatCredentialStatus;
}): InspectedBotChatAccount {
  return {
    accountId: params.accountId,
    enabled: params.enabled,
    name: params.normalized.name,
    botKey: params.botKey,
    botKeySource: params.botKeySource,
    botKeyStatus: params.botKeyStatus,
    configured: Boolean(params.normalized.backendUrl && params.botKeyStatus !== "missing"),
    config: params.normalized,
  };
}

export function inspectBotChatReadOnlyAccount(
  cfg: Record<string, unknown>,
  accountId?: string | null,
): InspectedBotChatAccount {
  return inspectBotChatAccount({ cfg, accountId });
}
