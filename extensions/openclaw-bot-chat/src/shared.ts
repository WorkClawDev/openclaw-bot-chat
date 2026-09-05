import {
  BOT_CHAT_CHANNEL_ID,
  BOT_CHAT_PAIRING_APPROVED_MESSAGE,
  getChatChannelMeta,
  type BotChatChannelConfig,
  type ChannelAllowlistAdapter,
  type ChannelPairingAdapter,
  type ChannelPlugin,
  type ChannelSetupAdapter,
  type ResolvedBotChatAccount,
} from "./channel-api.js";
import { inspectBotChatAccount } from "./account-inspect.js";
import { BotChatChannelConfigSchema } from "./config-schema.js";
import { botChatSecurityAdapter } from "./security.js";
import {
  hasBotChatConfiguredState,
  inferBotChatTargetChatType,
  isBotChatSenderAllowed,
  listBotChatAccountIds,
  normalizeAllowFromEntry,
  normalizeBotChatConfig,
  normalizeBotChatTarget,
  resolveBotChatAccount,
  resolveDefaultBotChatAccountId,
} from "./config.js";

export const botChatAllowlistAdapter: ChannelAllowlistAdapter = {
  normalizeEntry: normalizeAllowFromEntry,
  isAllowed: ({ cfg, accountId, userId }) => {
    const account = resolveBotChatAccount(cfg, accountId);
    return isBotChatSenderAllowed({
      allowFrom: account.config.allowFrom,
      userId,
    });
  },
};

export const botChatPairingAdapter: ChannelPairingAdapter = {
  text: {
    idLabel: "botChatUserId",
    message: BOT_CHAT_PAIRING_APPROVED_MESSAGE,
    normalizeAllowEntry: normalizeAllowFromEntry,
    notify: async ({ cfg, message, id, accountId }) => {
      const [{ getBotChatRuntime }, { buildBotChatDirectTopic }] = await Promise.all([
        import("./runtime.js"),
        import("./config.js"),
      ]);
      const account = resolveBotChatAccount(cfg, accountId);
      const channelId = buildBotChatDirectTopic(id, account.botId);
      await getBotChatRuntime().sendToChannel({
        channelId,
        userId: id,
        text: message,
        metadata: {
          botId: account.botId,
          toType: "user",
          publishTopic: channelId,
        },
      });
    },
  },
};

export function createBotChatPluginBase(params: {
  setup: ChannelSetupAdapter;
}): Pick<
  ChannelPlugin<ResolvedBotChatAccount>,
  | "id"
  | "meta"
  | "capabilities"
  | "reload"
  | "configSchema"
  | "config"
  | "commands"
  | "setup"
  | "messaging"
  | "security"
  | "pairing"
  | "allowlist"
> {
  return {
    id: BOT_CHAT_CHANNEL_ID,
    meta: { ...getChatChannelMeta(BOT_CHAT_CHANNEL_ID) },
    capabilities: {
      chatTypes: ["direct", "channel"],
      media: true,
      polls: false,
      reactions: false,
      threads: false,
      nativeCommands: true,
    },
    commands: {
      nativeCommandsAutoEnabled: true,
      nativeSkillsAutoEnabled: true,
    },
    reload: { configPrefixes: ["channels.bot-chat"] },
    configSchema: BotChatChannelConfigSchema as unknown as Record<string, unknown>,
    config: {
      listAccountIds: (cfg) => listBotChatAccountIds(cfg),
      resolveAccount: (cfg, accountId) => resolveBotChatAccount(cfg, accountId),
      inspectAccount: (cfg, accountId) => inspectBotChatAccount({ cfg, accountId }),
      defaultAccountId: (cfg) => resolveDefaultBotChatAccountId(cfg),
      isConfigured: (account) => account.configured,
      describeAccount: (account) => ({
        accountId: account.accountId,
        name: account.name,
        enabled: account.enabled,
        configured: account.configured,
        backendUrl: account.backendUrl,
        botId: account.botId,
        mqttTcpUrl: account.mqttTcpUrl,
        mqttWsUrl: account.mqttWsUrl,
      }),
      hasConfiguredState: ({ cfg, env }) => hasBotChatConfiguredState({ cfg, env }),
      resolveAllowFrom: ({ cfg, accountId }) => resolveBotChatAccount(cfg, accountId).config.allowFrom,
      resolveDefaultTo: ({ cfg, accountId }) => resolveBotChatAccount(cfg, accountId).config.defaultTo,
    },
    setup: params.setup,
    pairing: botChatPairingAdapter,
    allowlist: botChatAllowlistAdapter,
    messaging: {
      normalizeTarget: normalizeBotChatTarget,
      inferTargetChatType: ({ to }) => inferBotChatTargetChatType(to),
    },
    security: botChatSecurityAdapter,
  };
}

export function coerceBotChatSetupInput(input: Record<string, unknown>): BotChatChannelConfig {
  return normalizeBotChatConfig(input, {});
}
