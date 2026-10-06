import path from "node:path";
import {
  BOT_CHAT_DEFAULT_ACCOUNT_ID,
  BOT_CHAT_SLASH_AUTOCOMPLETE_REQUEST_TOPIC,
  type BotChatChannelConfig,
  type BotChatConfigIssue,
  type BotChatMessage,
  type BotChatTarget,
  type ResolvedBotChatAccount,
} from "./channel-api.js";

export const BOT_CHAT_EMPTY_ALLOW_FROM_MESSAGE =
  'allowFrom is empty; inbound senders are denied until pairing adds an id or you set allowFrom: ["*"]';

export const BOT_CHAT_SYSTEM_TOPIC_PREFIX = "control/bot-chat/";

export function parseBotChatTarget(raw: string): BotChatTarget {
  const trimmed = raw.trim();
  if (!trimmed) {
    throw new Error("BotChat target is required");
  }

  const match = /^(dm|direct|user|channel|conversation|group):(.+)$/i.exec(trimmed);
  if (!match) {
    return { kind: "channel", id: trimmed, raw: trimmed };
  }

  const kind = match[1].toLowerCase();
  const id = match[2].trim();
  if (!id) {
    throw new Error("BotChat target id is required");
  }

  if (kind === "dm" || kind === "direct" || kind === "user") {
    return { kind: "direct", id, raw: trimmed };
  }
  if (kind === "group") {
    return { kind: "channel", id: buildBotChatGroupTopic(id), raw: trimmed };
  }
  return { kind: "channel", id, raw: trimmed };
}

export function normalizeBotChatTarget(raw: string): string {
  const parsed = parseBotChatTarget(raw);
  return `${parsed.kind === "direct" ? "dm" : "channel"}:${parsed.id}`;
}

export function inferBotChatTargetChatType(raw: string): "direct" | "channel" {
  return parseBotChatTarget(raw).kind === "direct" ? "direct" : "channel";
}

export function buildBotChatOutboundMessageTarget(params: {
  raw: string;
  account: ResolvedBotChatAccount;
  metadata?: Record<string, unknown>;
}): {
  channelId: string;
  userId: string;
  normalizedTarget: string;
  chatType: "direct" | "channel";
  publishTopic: string;
  recipientType: "user" | "group";
} {
  const parsed = parseBotChatTarget(params.raw);
  if (parsed.kind === "direct") {
    const channelId = buildBotChatDirectTopic(parsed.id, params.account.botId);
    return {
      channelId,
      userId: parsed.id,
      normalizedTarget: `dm:${parsed.id}`,
      chatType: "direct",
      publishTopic: channelId,
      recipientType: "user",
    };
  }

  const userId =
    inferBotChatGroupId(parsed.id) ??
    readString(params.metadata?.userId) ??
    inferBotChatDirectUserId(parsed.id, params.account.botId) ??
    params.account.botId;
  const recipientType = inferBotChatRecipientType(parsed.id);
  return {
    channelId: parsed.id,
    userId,
    normalizedTarget: `channel:${parsed.id}`,
    chatType: "channel",
    publishTopic: parsed.id,
    recipientType,
  };
}

export function buildBotChatDirectTopic(userId: string, botId: string): string {
  return buildCanonicalBotChatDirectTopic({ type: "user", id: userId }, { type: "bot", id: botId });
}

export function buildBotChatGroupTopic(groupId: string): string {
  const trimmed = groupId.trim().replace(/^\/+/, "");
  return trimmed.startsWith("chat/group/") ? trimmed : `chat/group/${trimmed}`;
}

export function buildBotChatHistoryMessagesUrl(params: {
  backendUrl: string;
  conversationId: string;
  afterSeq?: number;
  limit: number;
}): string {
  const query = new URLSearchParams();
  query.set("limit", String(params.limit));
  if (params.afterSeq !== undefined) {
    query.set("after_seq", String(params.afterSeq));
  }
  const base = params.backendUrl.replace(/\/+$/, "");
  return `${base}/api/v1/bot-runtime/messages/${encodeURIComponent(params.conversationId)}?${query.toString()}`;
}

export function buildBotChatBootstrapUrl(backendUrl: string): string {
  return `${backendUrl.replace(/\/+$/, "")}/api/v1/bot-runtime/bootstrap`;
}

function buildCanonicalBotChatDirectTopic(
  left: { type: "user" | "bot"; id: string },
  right: { type: "user" | "bot"; id: string },
): string {
  const [first, second] = canonicalizeBotChatDirectPeers(left, right);
  return `chat/dm/${first.type}/${first.id}/${second.type}/${second.id}`;
}

function canonicalizeBotChatDirectPeers(
  left: { type: "user" | "bot"; id: string },
  right: { type: "user" | "bot"; id: string },
): [{ type: "user" | "bot"; id: string }, { type: "user" | "bot"; id: string }] {
  const leftRank = left.type === "user" ? 0 : 1;
  const rightRank = right.type === "user" ? 0 : 1;
  if (leftRank !== rightRank) {
    return leftRank < rightRank ? [left, right] : [right, left];
  }
  return left.id <= right.id ? [left, right] : [right, left];
}

export function inferBotChatRecipientType(channelId: string): "user" | "group" {
  return channelId.startsWith("chat/group/") ? "group" : "user";
}

export function inferBotChatGroupId(channelId: string): string | undefined {
  const parts = channelId.split("/");
  if (parts.length === 3 && parts[0] === "chat" && parts[1] === "group") {
    return parts[2] || undefined;
  }
  return undefined;
}

export function isBotChatConversationTopic(value: string): boolean {
  return value.startsWith("chat/dm/") || value.startsWith("chat/group/");
}

export function inferBotChatDirectUserId(value: string, botId: string): string | undefined {
  const parts = value.split("/");
  if (parts.length !== 6 || parts[0] !== "chat" || parts[1] !== "dm") {
    return undefined;
  }

  const left = { type: parts[2], id: parts[3] };
  const right = { type: parts[4], id: parts[5] };
  if (left.type === "user" && right.type === "bot" && right.id === botId) {
    return left.id;
  }
  if (right.type === "user" && left.type === "bot" && left.id === botId) {
    return right.id;
  }
  return undefined;
}

export function normalizeAllowFromEntry(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) {
    return "";
  }
  if (trimmed === "*") {
    return "*";
  }
  return trimmed.replace(/^(?:user|botchat|sender):/i, "").trim();
}

export function normalizeAllowFromEntries(raw: unknown): string[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.map((entry) => normalizeAllowFromEntry(String(entry))).filter(Boolean);
}

export function isBotChatOpenAllowFrom(allowFrom?: string[]): boolean {
  return (allowFrom ?? []).some((entry) => normalizeAllowFromEntry(entry) === "*");
}

export function hasBotChatAllowFromEntries(allowFrom?: string[]): boolean {
  return (allowFrom ?? []).some((entry) => Boolean(normalizeAllowFromEntry(entry)));
}

export function isBotChatSenderAllowed(params: {
  allowFrom?: string[];
  userId: string;
}): boolean {
  const normalizedUserId = normalizeAllowFromEntry(params.userId);
  if (!normalizedUserId) {
    return false;
  }
  const entries = (params.allowFrom ?? []).map((entry) => normalizeAllowFromEntry(entry));
  if (entries.includes("*")) {
    return true;
  }
  return entries.includes(normalizedUserId);
}

export function isBotChatControlTopic(topic: string): boolean {
  return topic.startsWith(BOT_CHAT_SYSTEM_TOPIC_PREFIX);
}

export function isBotChatValidatedControlInbound(message: BotChatMessage): boolean {
  const topic = readString(message.metadata?.topic) ?? message.channelId;
  const contentType = readString(message.metadata?.content_type);
  const isAutocompleteTopic =
    contentType === "slash_autocomplete_request" || topic === BOT_CHAT_SLASH_AUTOCOMPLETE_REQUEST_TOPIC;
  if (!isAutocompleteTopic) {
    return false;
  }
  return Boolean(
    readString(message.metadata?.request_id ?? message.metadata?.requestId) &&
      readString(message.metadata?.response_topic ?? message.metadata?.responseTopic) &&
      readString(message.metadata?.command_name ?? message.metadata?.commandName),
  );
}

export function isBotChatSystemInbound(message: BotChatMessage): boolean {
  if (readString(message.metadata?.senderType) === "bot") {
    return true;
  }
  return isBotChatValidatedControlInbound(message);
}

export function resolveBotChatDmPolicyMode(allowFrom?: string[]): "open" | "pairing" | "allowlist" {
  if (isBotChatOpenAllowFrom(allowFrom)) {
    return "open";
  }
  if (!hasBotChatAllowFromEntries(allowFrom)) {
    return "pairing";
  }
  return "allowlist";
}

export function evaluateBotChatAccess(params: {
  config: Record<string, unknown>;
  message: BotChatMessage;
}): {
  allowed: boolean;
  reason?: string;
  requiresCustomApproval: boolean;
  pendingPairing?: boolean;
  invalidControl?: boolean;
} {
  const topic = readString(params.message.metadata?.topic) ?? params.message.channelId;
  if (readString(params.message.metadata?.senderType) === "bot") {
    return {
      allowed: true,
      requiresCustomApproval: false,
    };
  }
  if (isBotChatControlTopic(topic) || readString(params.message.metadata?.content_type) === "slash_autocomplete_request") {
    if (isBotChatValidatedControlInbound(params.message)) {
      return {
        allowed: true,
        requiresCustomApproval: false,
      };
    }
    return {
      allowed: false,
      reason: "invalid control payload",
      requiresCustomApproval: false,
      invalidControl: true,
    };
  }

  const normalized = normalizeBotChatConfig(params.config);
  const allowFrom = normalized.allowFrom ?? [];
  if (!hasBotChatAllowFromEntries(allowFrom)) {
    return {
      allowed: false,
      reason: "sender pending pairing",
      requiresCustomApproval: false,
      pendingPairing: true,
    };
  }

  const senderAllowed = isBotChatSenderAllowed({ allowFrom, userId: params.message.userId });
  if (!senderAllowed) {
    return {
      allowed: false,
      reason: "sender not approved in allowFrom",
      requiresCustomApproval: false,
    };
  }

  const blocked = Boolean(params.message.metadata?.blocked);
  if (blocked) {
    return {
      allowed: false,
      reason: "message blocked by metadata",
      requiresCustomApproval: normalized.permissionApprovalEnabled === true,
    };
  }

  return {
    allowed: true,
    requiresCustomApproval: false,
  };
}

export function collectBotChatConfigIssues(config: Record<string, unknown>): BotChatConfigIssue[] {
  const normalized = normalizeBotChatConfig(config, {});
  const issues: BotChatConfigIssue[] = [];
  const hasConfiguredBotKey = Boolean(normalized.botKey) || isBotChatSecretRef(config.botKey);

  if (!normalized.backendUrl) {
    issues.push({
      severity: "error",
      code: "missing_backend_url",
      message: "backendUrl is required",
      path: "backendUrl",
    });
  }
  if (!hasConfiguredBotKey) {
    issues.push({
      severity: "error",
      code: "missing_bot_key",
      message: "botKey is required",
      path: "botKey",
    });
  }

  if (config.historyCatchupLimit !== undefined) {
    const rawLimit = readNumber(config.historyCatchupLimit);
    if (rawLimit === undefined || rawLimit <= 0) {
      issues.push({
        severity: "error",
        code: "invalid_history_catchup_limit",
        message: "historyCatchupLimit must be a positive number",
        path: "historyCatchupLimit",
      });
    }
  }

  if (
    normalized.permissionApprovalEnabled === true &&
    !normalized.permissionApprovalHandler &&
    !normalized.permissionApprovalUrl
  ) {
    issues.push({
      severity: "warning",
      code: "approval_without_handler",
      message: "permissionApprovalEnabled is true but no approval handler or URL is configured",
      path: "permissionApprovalEnabled",
    });
  }

  if (!isBotChatOpenAllowFrom(normalized.allowFrom) && !hasBotChatAllowFromEntries(normalized.allowFrom)) {
    issues.push({
      severity: "warning",
      code: "empty_allow_from",
      message: BOT_CHAT_EMPTY_ALLOW_FROM_MESSAGE,
      path: "allowFrom",
    });
  }

  return issues;
}

export function isBotChatSecretRef(value: unknown): boolean {
  return (
    isRecord(value) &&
    (value.source === "env" || value.source === "file" || value.source === "exec") &&
    typeof value.provider === "string" &&
    typeof value.id === "string"
  );
}

export function normalizeBotChatConfig(
  input: Record<string, unknown> = {},
  env: Record<string, string | undefined> = process.env,
): BotChatChannelConfig {
  const normalized: BotChatChannelConfig = {
    enabled: readBoolean(input.enabled) ?? true,
    name: readString(input.name) ?? "BotChat",
    backendUrl: readString(input.backendUrl) ?? env.BOT_CHAT_BACKEND_URL,
    botKey: readString(input.botKey) ?? env.BOT_CHAT_BOT_KEY,
    botId: readString(input.botId) ?? env.BOT_CHAT_BOT_ID ?? BOT_CHAT_DEFAULT_ACCOUNT_ID,
    mqttTcpUrl: readString(input.mqttTcpUrl) ?? env.BOT_CHAT_MQTT_TCP_URL,
    mqttWsUrl: readString(input.mqttWsUrl) ?? env.BOT_CHAT_MQTT_WS_URL,
    stateDir: readString(input.stateDir),
    historyCatchupLimit: readNumber(input.historyCatchupLimit) ?? 100,
    defaultTo: readString(input.defaultTo),
    allowFrom: normalizeAllowFromEntries(input.allowFrom),
    permissionApprovalEnabled: readBoolean(input.permissionApprovalEnabled) ?? false,
    permissionApprovalHandler: readString(input.permissionApprovalHandler),
    permissionApprovalUrl: readString(input.permissionApprovalUrl),
    permissionApprovalTimeoutMs: readNumber(input.permissionApprovalTimeoutMs),
    permissionDeniedReply: readString(input.permissionDeniedReply),
    taskPollingIntervalMs: readNumber(input.taskPollingIntervalMs),
  };

  return normalized;
}

export function resolveBotChatAccount(
  cfg: Record<string, unknown> = {},
  accountId: string = BOT_CHAT_DEFAULT_ACCOUNT_ID,
  env: Record<string, string | undefined> = process.env,
): ResolvedBotChatAccount {
  const channels = isRecord(cfg.channels) ? cfg.channels : undefined;
  const channelCfg = isRecord(channels?.["bot-chat"])
    ? (channels?.["bot-chat"] as Record<string, unknown>)
    : cfg;
  const normalized = normalizeBotChatConfig(channelCfg, env);
  const configured = Boolean(normalized.backendUrl && (normalized.botKey || isBotChatSecretRef(channelCfg.botKey)));
  return {
    accountId,
    name: normalized.name ?? "BotChat",
    enabled: normalized.enabled !== false,
    configured,
    backendUrl: normalized.backendUrl,
    botId: normalized.botId ?? BOT_CHAT_DEFAULT_ACCOUNT_ID,
    mqttTcpUrl: normalized.mqttTcpUrl,
    mqttWsUrl: normalized.mqttWsUrl,
    config: normalized,
  };
}

export function listBotChatAccountIds(_cfg: Record<string, unknown> = {}): string[] {
  return [BOT_CHAT_DEFAULT_ACCOUNT_ID];
}

export function resolveDefaultBotChatAccountId(_cfg: Record<string, unknown> = {}): string {
  return BOT_CHAT_DEFAULT_ACCOUNT_ID;
}

export function hasBotChatConfiguredState(params: {
  cfg?: Record<string, unknown>;
  env?: Record<string, string | undefined>;
} = {}): boolean {
  const account = resolveBotChatAccount(
    params.cfg ?? {},
    BOT_CHAT_DEFAULT_ACCOUNT_ID,
    params.env ?? process.env,
  );
  return account.configured;
}

export function buildBotChatStatePath(config: Record<string, unknown>): string | undefined {
  const stateDir = readString(config.stateDir);
  const botId = readString(config.botId) ?? BOT_CHAT_DEFAULT_ACCOUNT_ID;
  if (!stateDir) {
    return undefined;
  }
  return path.join(stateDir, `botchat-${botId}-state.json`);
}

export function getBotChatChannelConfig(cfg: Record<string, unknown>): Record<string, unknown> {
  const channels = isRecord(cfg.channels) ? cfg.channels : undefined;
  return isRecord(channels?.["bot-chat"]) ? (channels["bot-chat"] as Record<string, unknown>) : cfg;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

export function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

export function readStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((item) => readString(item)).filter((item): item is string => Boolean(item));
}

export function readNumber(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return undefined;
}

export function readBoolean(value: unknown): boolean | undefined {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["true", "1", "yes", "on"].includes(normalized)) {
      return true;
    }
    if (["false", "0", "no", "off"].includes(normalized)) {
      return false;
    }
  }
  return undefined;
}
