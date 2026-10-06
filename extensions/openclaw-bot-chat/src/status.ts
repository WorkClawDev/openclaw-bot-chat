import type { ChannelStatusAdapter, ResolvedBotChatAccount } from "./channel-api.js";
import { probeBotChatAccount } from "./probe.js";
import {
  buildBotChatStatePath,
  collectBotChatConfigIssues,
  resolveBotChatAccount,
  resolveBotChatDmPolicyMode,
} from "./config.js";

function resolveBotChatApprovalMode(account: ResolvedBotChatAccount): "open" | "pairing" | "allowlist" | "custom-approval" {
  if (account.config.permissionApprovalEnabled === true) {
    return "custom-approval";
  }
  return resolveBotChatDmPolicyMode(account.config.allowFrom);
}

export const botChatStatus: ChannelStatusAdapter<ResolvedBotChatAccount> = {
  getSnapshot: ({ cfg, accountId, runtimeState }) => {
    const account = resolveBotChatAccount(cfg, accountId);
    return {
      accountId: account.accountId,
      configured: account.configured,
      connected: Boolean(runtimeState?.connected),
      botId: account.botId,
      backendUrl: account.backendUrl,
      mqttTcpUrl: account.mqttTcpUrl,
      mqttWsUrl: account.mqttWsUrl,
      lastError:
        typeof runtimeState?.lastError === "string" ? runtimeState.lastError : undefined,
      approvalMode: resolveBotChatApprovalMode(account),
      allowFromCount: account.config.allowFrom?.length ?? 0,
      hasDefaultTo: Boolean(account.config.defaultTo),
      historyCatchupLimit: account.config.historyCatchupLimit ?? 100,
      statePathConfigured: Boolean(buildBotChatStatePath(account.config as Record<string, unknown>)),
      issues: collectBotChatConfigIssues(account.config as Record<string, unknown>),
    };
  },
  describeAccount: (account) => ({
    accountId: account.accountId,
    name: account.name,
    enabled: account.enabled,
    configured: account.configured,
    backendUrl: account.backendUrl,
    mqttTcpUrl: account.mqttTcpUrl,
    mqttWsUrl: account.mqttWsUrl,
    approvalMode: resolveBotChatApprovalMode(account),
    allowFromCount: account.config.allowFrom?.length ?? 0,
  }),
  probeAccount: async ({ account, timeoutMs }) => probeBotChatAccount({ account, timeoutMs }),
};
