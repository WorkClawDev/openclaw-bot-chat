import type { ResolvedBotChatAccount } from "./channel-api.js";
import {
  isBotChatSenderAllowed,
  resolveBotChatAccount,
  resolveBotChatDmPolicyMode,
} from "./config.js";

export type BotChatDmPolicy = "open" | "pairing" | "allowlist" | "disabled";

export function resolveBotChatDmPolicy(params: {
  cfg: Record<string, unknown>;
  accountId?: string;
}): BotChatDmPolicy {
  const account = resolveBotChatAccount(params.cfg, params.accountId);
  if (account.enabled === false) {
    return "disabled";
  }
  return resolveBotChatDmPolicyMode(account.config.allowFrom);
}

export function collectBotChatSecurityWarnings(params: {
  cfg: Record<string, unknown>;
  accountId?: string;
}): string[] {
  const policy = resolveBotChatDmPolicy(params);
  if (policy === "open") {
    return [
      "- BotChat allowFrom includes *; inbound senders are open. Prefer explicit ids or pairing.",
    ];
  }
  if (policy === "pairing") {
    return [
      "- BotChat allowFrom is empty; inbound senders stay pending pairing until an id is approved or allowFrom includes *.",
    ];
  }
  return [];
}

export function isBotChatCommandAuthorized(params: {
  account: ResolvedBotChatAccount;
  userId: string;
}): boolean {
  return isBotChatSenderAllowed({
    allowFrom: params.account.config.allowFrom,
    userId: params.userId,
  });
}

export const botChatSecurityAdapter = {
  defaultPolicy: "approve" as const,
  mode: "allowFrom" as const,
  approveHint: "Add the sender id to allowFrom or approve the pairing request.",
  resolveDmPolicy: resolveBotChatDmPolicy,
  collectWarnings: collectBotChatSecurityWarnings,
};
