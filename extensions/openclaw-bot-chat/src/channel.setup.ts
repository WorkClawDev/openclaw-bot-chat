import { BOT_CHAT_CHANNEL_ID, type ChannelPlugin, type ChannelSetupAdapter, type ResolvedBotChatAccount } from "./channel-api.js";
import { createBotChatPluginBase, coerceBotChatSetupInput } from "./shared.js";
import { isBotChatSecretRef, readBoolean, readString } from "./config.js";
import { BOT_CHAT_SETUP_FIELDS, serializeBotChatSetupFields } from "./setup-fields.js";

function applyBotChatUseEnv(input: Record<string, unknown>, env: Record<string, string | undefined> = process.env): Record<string, unknown> {
  const useEnv = readBoolean(input.useEnv) === true;
  const next: Record<string, unknown> = { ...input };
  delete next.useEnv;
  if (!useEnv) {
    return next;
  }
  if (!readString(next.backendUrl) && env.BOT_CHAT_BACKEND_URL) {
    next.backendUrl = env.BOT_CHAT_BACKEND_URL;
  }
  if (!readString(next.botKey) && !isBotChatSecretRef(next.botKey) && env.BOT_CHAT_BOT_KEY) {
    next.botKey = {
      source: "env",
      provider: "default",
      id: "BOT_CHAT_BOT_KEY",
    };
  }
  if (!readString(next.botId) && env.BOT_CHAT_BOT_ID) {
    next.botId = env.BOT_CHAT_BOT_ID;
  }
  if (!readString(next.mqttTcpUrl) && env.BOT_CHAT_MQTT_TCP_URL) {
    next.mqttTcpUrl = env.BOT_CHAT_MQTT_TCP_URL;
  }
  if (!readString(next.mqttWsUrl) && env.BOT_CHAT_MQTT_WS_URL) {
    next.mqttWsUrl = env.BOT_CHAT_MQTT_WS_URL;
  }
  return next;
}

export const botChatSetupAdapter: ChannelSetupAdapter = {
  applyAccountConfig: ({ cfg, input }) => {
    const channels =
      cfg.channels && typeof cfg.channels === "object" && !Array.isArray(cfg.channels)
        ? { ...(cfg.channels as Record<string, unknown>) }
        : {};
    const patched = applyBotChatUseEnv(input);
    channels[BOT_CHAT_CHANNEL_ID] = {
      ...(typeof channels[BOT_CHAT_CHANNEL_ID] === "object" &&
      channels[BOT_CHAT_CHANNEL_ID] !== null &&
      !Array.isArray(channels[BOT_CHAT_CHANNEL_ID])
        ? (channels[BOT_CHAT_CHANNEL_ID] as Record<string, unknown>)
        : {}),
      ...patched,
    };
    return {
      ...cfg,
      channels,
    };
  },
  validateConfig: (input) => {
    const patched = applyBotChatUseEnv(input);
    const normalized = coerceBotChatSetupInput(patched);
    const errors: string[] = [];
    if (!normalized.backendUrl) {
      errors.push("backendUrl is required");
    }
    if (!normalized.botKey && !isBotChatSecretRef(patched.botKey) && !isBotChatSecretRef(input.botKey)) {
      errors.push("botKey is required");
    }
    return {
      ok: errors.length === 0,
      errors,
    };
  },
};

export const botChatSetupContract = {
  kind: "channel-owned" as const,
  metadata: {
    fields: serializeBotChatSetupFields(),
  },
  fields: BOT_CHAT_SETUP_FIELDS,
  applyAccountConfig: botChatSetupAdapter.applyAccountConfig,
  validateInput: ({ input }: { input: Record<string, unknown> }) => {
    const result = botChatSetupAdapter.validateConfig?.(input);
    if (!result || result.ok) {
      return null;
    }
    return result.errors.join("; ");
  },
  legacyAdapter: botChatSetupAdapter,
};

export const botChatSetupPlugin: Pick<
  ChannelPlugin<ResolvedBotChatAccount>,
  "id" | "meta" | "capabilities" | "reload" | "configSchema" | "config" | "setup" | "setupContract" | "messaging" | "security"
> = {
  ...createBotChatPluginBase({ setup: botChatSetupAdapter }),
  setupContract: botChatSetupContract,
};
