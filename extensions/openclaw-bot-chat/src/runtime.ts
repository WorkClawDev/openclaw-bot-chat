import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import {
  BOT_CHAT_DEFAULT_ACCOUNT_ID,
  type BotChatChannelConfig,
  type BotChatConfigIssue,
  type BotChatTarget,
  type ResolvedBotChatAccount,
} from "./channel-api.js";

export type BotChatMessage = {
  channelId: string;
  userId: string;
  text: string;
  metadata?: Record<string, unknown>;
};

export type BotChatSendResult = {
  messageId: string;
};

type RuntimeLogger = {
  info(msg: string, fields?: Record<string, unknown>): void;
  warn(msg: string, fields?: Record<string, unknown>): void;
  error(msg: string, fields?: Record<string, unknown>): void;
  debug?(msg: string, fields?: Record<string, unknown>): void;
};

interface RuntimeHooks {
  emitMessage?: (message: BotChatMessage) => Promise<void>;
}

interface BootstrapResponse {
  bot?: {
    id?: string;
  };
  client_id?: string;
  broker?: {
    tcp_url?: string;
    ws_url?: string;
    username?: string;
    password?: string;
    qos?: number;
  };
  subscriptions?: Array<{ topic?: string; qos?: number }>;
  publish_topics?: string[];
  conversations?: Array<{
    conversation_id?: string;
    last_seq?: number;
    last_message_id?: string;
  }>;
}

interface CheckpointRecord {
  channelId: string;
  lastMessageId?: string;
  lastSeq?: number;
  updatedAt: number;
}

type MqttQos = 0 | 1 | 2;
const BOT_CHAT_MQTT_KEEPALIVE_SECONDS = 30;
const BOT_CHAT_MQTT_RECONNECT_MS = 1000;
const BOT_CHAT_MQTT_CONNECT_TIMEOUT_MS = 30000;

export interface BotChatRuntime {
  start(
    config: Record<string, unknown>,
    logger: RuntimeLogger,
    hooks?: RuntimeHooks,
  ): Promise<void>;
  stop(): Promise<void>;
  onInboundMessage(message: BotChatMessage): Promise<void>;
  sendToChannel(message: BotChatMessage): Promise<BotChatSendResult>;
}

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

function inferBotChatRecipientType(channelId: string): "user" | "group" {
  return channelId.startsWith("chat/group/") ? "group" : "user";
}

function inferBotChatGroupId(channelId: string): string | undefined {
  const parts = channelId.split("/");
  if (parts.length === 3 && parts[0] === "chat" && parts[1] === "group") {
    return parts[2] || undefined;
  }
  return undefined;
}

function isBotChatConversationTopic(value: string): boolean {
  return value.startsWith("chat/dm/") || value.startsWith("chat/group/");
}

function inferBotChatDirectUserId(value: string, botId: string): string | undefined {
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

function omitBotChatInternalMetadata(metadata: Record<string, unknown>): Record<string, unknown> {
  const { botId: _botId, toType: _toType, publishTopic: _publishTopic, retain: _retain, ...rest } = metadata;
  return rest;
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

export function evaluateBotChatAccess(params: {
  config: Record<string, unknown>;
  message: BotChatMessage;
}): { allowed: boolean; reason?: string; requiresCustomApproval: boolean } {
  const normalized = normalizeBotChatConfig(params.config);
  const allowFrom = normalized.allowFrom ?? [];
  const allowlistEnabled = allowFrom.length > 0;
  const senderAllowed = allowlistEnabled
    ? isBotChatSenderAllowed({ allowFrom, userId: params.message.userId })
    : true;

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

  if ((normalized.allowFrom ?? []).length === 0) {
    issues.push({
      severity: "warning",
      code: "empty_allow_from",
      message: "allowFrom is empty; BotChat currently allows all senders until pairing writes allowFrom entries",
      path: "allowFrom",
    });
  }

  return issues;
}

function isBotChatSecretRef(value: unknown): boolean {
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
  const configured = Boolean(normalized.backendUrl && normalized.botKey);
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

export function normalizeBotChatInboundMessage(raw: unknown, topic: string): BotChatMessage | null {
  return toInboundMessage(raw, topic);
}

export function buildBotChatStatePath(config: Record<string, unknown>): string | undefined {
  const stateDir = readString(config.stateDir);
  const botId = readString(config.botId) ?? BOT_CHAT_DEFAULT_ACCOUNT_ID;
  if (!stateDir) {
    return undefined;
  }
  return path.join(stateDir, `botchat-${botId}-state.json`);
}

export function buildBotChatOutboundPayload(message: BotChatMessage): string {
  const threadId = readString(message.metadata?.threadId);
  const replyToId = readString(message.metadata?.replyToId);
  const messageId =
    readString(message.metadata?.message_id) ??
    readString(message.metadata?.messageId) ??
    randomUUID();
  const botId = readString(message.metadata?.botId) ?? BOT_CHAT_DEFAULT_ACCOUNT_ID;
  const toType = readString(message.metadata?.toType) ?? "user";
  const toId =
    toType === "group"
      ? inferBotChatGroupId(message.userId) ?? inferBotChatGroupId(message.channelId) ?? message.userId
      : message.userId;
  const contentType = readString(message.metadata?.content_type);
  const asset = isRecord(message.metadata?.asset) ? message.metadata.asset : undefined;
  const assetUrl =
    readString(asset?.download_url) ??
    readString(asset?.external_url) ??
    readString(asset?.source_url);
  const contentMeta = {
    ...omitBotChatInternalMetadata(message.metadata ?? {}),
    message_id: messageId,
  };
  const content =
    contentType === "image"
      ? { type: "image", body: message.text, ...(assetUrl ? { url: assetUrl } : {}), meta: contentMeta }
      : { type: "text", body: message.text, meta: contentMeta };
  return JSON.stringify({
    id: messageId,
    conversation_id: message.channelId,
    ...(threadId ? { thread_id: threadId } : {}),
    ...(replyToId ? { reply_to_id: replyToId } : {}),
    from: { type: "bot", id: botId },
    to: { type: toType, id: toId },
    content,
    timestamp: Math.floor(Date.now() / 1000),
  });
}

class DefaultBotChatRuntime implements BotChatRuntime {
  private started = false;
  private connected = false;
  private mqttClient?: import("mqtt").MqttClient;
  private logger?: RuntimeLogger;
  private hooks?: RuntimeHooks;
  private publishTopic?: string;
  private publishTopics = new Set<string>();
  private botId?: string;
  private permissionDeniedReply?: string;
  private approver?: PermissionApprover;
  private statePath?: string;
  private checkpoints = new Map<string, CheckpointRecord>();
  private qos: MqttQos = 1;
  private backendUrl?: string;
  private botKey?: string;
  private connectWaiters: Array<{
    resolve: () => void;
    reject: (error: Error) => void;
  }> = [];

  async start(
    config: Record<string, unknown>,
    logger: RuntimeLogger,
    hooks?: RuntimeHooks,
  ): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    this.connected = false;
    this.logger = logger;
    this.hooks = hooks;
    this.approver = await createApprover(config);
    this.permissionDeniedReply = readString(config.permissionDeniedReply);

    const backendUrl = readString(config.backendUrl);
    const botKey = readString(config.botKey);
    if (!backendUrl || !botKey) {
      throw new Error("backendUrl and botKey are required");
    }

    logger.info("botchat.runtime.started", {
      backendUrl,
      botId: readString(config.botId),
    });

    const bootstrap = await bootstrapBotWithRetry(backendUrl, botKey, logger);
    const bootstrapBotId = readString(bootstrap.bot?.id);
    if (bootstrapBotId) {
      config.botId = bootstrapBotId;
    }
    this.botId = bootstrapBotId ?? readString(config.botId);
    this.qos = normalizeQos(bootstrap.broker?.qos);
    this.backendUrl = backendUrl;
    this.botKey = botKey;
    const brokerUrl =
      readString(config.mqttWsUrl) ??
      readString(config.mqttTcpUrl) ??
      readString(bootstrap.broker?.ws_url) ??
      readString(bootstrap.broker?.tcp_url);
    if (!brokerUrl) {
      throw new Error("mqtt broker url is required");
    }

    this.publishTopics = new Set(readStringArray(bootstrap.publish_topics));
    this.publishTopic = readString(bootstrap.publish_topics?.[0]);
    const subscriptions = readStringArray(bootstrap.subscriptions?.map((item) => item.topic));

    this.statePath = buildBotChatStatePath(config);
    await this.loadState();
    this.syncCheckpointsFromBootstrap(bootstrap);

    const mqtt = await import("mqtt");
    this.mqttClient = mqtt.connect(brokerUrl, {
      clientId: readString(bootstrap.client_id),
      keepalive: BOT_CHAT_MQTT_KEEPALIVE_SECONDS,
      reconnectPeriod: BOT_CHAT_MQTT_RECONNECT_MS,
      connectTimeout: BOT_CHAT_MQTT_CONNECT_TIMEOUT_MS,
      clean: true,
      username: readString(bootstrap.broker?.username),
      password: readString(bootstrap.broker?.password),
    });

    this.mqttClient.on("connect", () => {
      this.connected = true;
      this.resolveConnectWaiters();
      logger.info("botchat.mqtt.connected", {
        brokerUrl,
        subscriptions: subscriptions.length,
        qos: this.qos,
      });
      for (const topic of subscriptions) {
        this.mqttClient?.subscribe(topic, { qos: this.qos }, (error) => {
          if (error) {
            logger.error("botchat.mqtt.subscribe_error", { topic, error: error.message });
            return;
          }
          logger.info("botchat.mqtt.subscribed", { topic, qos: this.qos });
        });
      }
      void this.recoverHistory(config);
    });

    this.mqttClient.on("reconnect", () => {
      logger.warn("botchat.mqtt.reconnecting", {
        brokerUrl,
      });
    });

    this.mqttClient.on("close", () => {
      this.connected = false;
      logger.warn("botchat.mqtt.closed", {
        brokerUrl,
      });
    });

    this.mqttClient.on("message", (topic, payload) => {
      void this.handleInbound(topic, payload.toString("utf8"), config);
    });

    this.mqttClient.on("error", (error) => {
      logger.error("botchat.mqtt.error", {
        error: error.message,
      });
    });
  }

  async stop(): Promise<void> {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.connected = false;
    this.rejectConnectWaiters(new Error("mqtt client stopped"));

    await new Promise<void>((resolve) => {
      if (!this.mqttClient) {
        resolve();
        return;
      }
      this.mqttClient.end(false, {}, () => resolve());
    });

    this.mqttClient = undefined;
    await this.flushState();
    this.logger?.info("botchat.runtime.stopped");
  }

  async onInboundMessage(message: BotChatMessage): Promise<void> {
    await this.hooks?.emitMessage?.(message);
  }

  async sendToChannel(message: BotChatMessage): Promise<BotChatSendResult> {
    const client = this.mqttClient;
    if (!client) {
      throw new Error("mqtt client is not ready");
    }

    const topic = this.resolvePublishTopic(message);
    if (!topic) {
      throw new Error("publish topic is not configured");
    }
    await this.waitForMqttConnected();

    const messageId =
      readString(message.metadata?.messageId) ??
      readString(message.metadata?.message_id) ??
      randomUUID();

    const outboundBotId = this.resolveOutboundBotId(message.metadata);
    const payload = buildBotChatOutboundPayload({
      ...message,
      channelId: topic,
      metadata: {
        ...(message.metadata ?? {}),
        ...(outboundBotId ? { botId: outboundBotId } : {}),
        message_id: messageId,
        topic,
      },
    });

    const retain = message.metadata?.retain === true;
    await new Promise<void>((resolve, reject) => {
      client.publish(topic, payload, { qos: this.qos, retain }, (error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
    this.logger?.debug?.("botchat.runtime.outbound", {
      topic,
      channelId: message.channelId,
      messageId,
    });
    return { messageId };
  }

  private async waitForMqttConnected(): Promise<void> {
    const client = this.mqttClient;
    if (!client) {
      throw new Error("mqtt client is not ready");
    }
    if (this.connected || client.connected) {
      return;
    }

    await new Promise<void>((resolve, reject) => {
      let timer: NodeJS.Timeout;
      const waiter = {
        resolve: () => {
          clearTimeout(timer);
          resolve();
        },
        reject: (error: Error) => {
          clearTimeout(timer);
          reject(error);
        },
      };
      timer = setTimeout(() => {
        this.connectWaiters = this.connectWaiters.filter((item) => item !== waiter);
        reject(new Error("mqtt client did not connect before publish timeout"));
      }, BOT_CHAT_MQTT_CONNECT_TIMEOUT_MS);
      this.connectWaiters.push(waiter);
    });
  }

  private resolveConnectWaiters(): void {
    const waiters = this.connectWaiters.splice(0);
    for (const waiter of waiters) {
      waiter.resolve();
    }
  }

  private rejectConnectWaiters(error: Error): void {
    const waiters = this.connectWaiters.splice(0);
    for (const waiter of waiters) {
      waiter.reject(error);
    }
  }

  private resolvePublishTopic(message: BotChatMessage): string | undefined {
    const explicitTopic = readString(message.metadata?.topic) ?? readString(message.metadata?.publishTopic);
    if (explicitTopic) {
      return explicitTopic;
    }
    if (isBotChatConversationTopic(message.channelId) || this.publishTopics.has(message.channelId)) {
      return message.channelId;
    }
    return this.publishTopic;
  }

  private resolveOutboundBotId(metadata: Record<string, unknown> | undefined): string | undefined {
    const metadataBotId = readString(metadata?.botId);
    return this.botId ?? metadataBotId;
  }

  private async handleInbound(
    topic: string,
    payload: string,
    config: Record<string, unknown>,
  ): Promise<void> {
    const logger = this.logger;
    if (!logger) {
      return;
    }

    const parsed = tryParseJson(payload);
    const message = toInboundMessage(parsed, topic);
    if (!message) {
      logger.warn("botchat.inbound.invalid_payload", { topic });
      return;
    }
    logger.info("botchat.inbound.received", {
      topic,
      channelId: message.channelId,
      userId: message.userId,
      senderType: message.metadata?.senderType,
    });

    const access = evaluateBotChatAccess({ config, message });
    if (!access.allowed) {
      if (access.requiresCustomApproval) {
        const approved = await this.approver?.approve({
          topic,
          message,
          permission: { allowed: false, reason: access.reason },
        });
        if (approved?.approved) {
          await this.acceptInboundMessage(message);
          return;
        }
        logger.warn("botchat.inbound.permission_denied", {
          topic,
          reason: access.reason,
          approvalReason: approved?.reason,
        });
      } else {
        logger.warn("botchat.inbound.allowlist_denied", {
          topic,
          reason: access.reason,
          userId: message.userId,
        });
      }

      if (this.permissionDeniedReply) {
        await this.sendToChannel({
          channelId: message.channelId,
          userId: message.userId,
          text: this.permissionDeniedReply,
          metadata: {
            topic,
            reason: access.reason,
          },
        });
      }
      return;
    }

    await this.acceptInboundMessage(message);
  }

  private async acceptInboundMessage(message: BotChatMessage): Promise<void> {
    this.logger?.info("botchat.inbound.accepted", {
      channelId: message.channelId,
      userId: message.userId,
    });
    await this.onInboundMessage(message);
    const messageId = readString(message.metadata?.message_id);
    this.checkpoints.set(message.channelId, {
      channelId: message.channelId,
      lastMessageId: messageId,
      lastSeq: readNumber(message.metadata?.seq),
      updatedAt: Date.now(),
    });
    await this.flushState();
  }

  private async recoverHistory(config: Record<string, unknown>): Promise<void> {
    if (!this.backendUrl || !this.botKey || this.checkpoints.size === 0) {
      return;
    }
    const limit = readNumber(config.historyCatchupLimit) ?? 100;
    for (const checkpoint of this.checkpoints.values()) {
      const messages = await fetchConversationMessages(
        this.backendUrl,
        this.botKey,
        checkpoint.channelId,
        checkpoint.lastSeq,
        limit,
      );
      for (const message of messages) {
        const normalized = toInboundMessage(message, checkpoint.channelId);
        if (!normalized) {
          continue;
        }
        await this.onInboundMessage(normalized);
      }
    }
  }

  private syncCheckpointsFromBootstrap(bootstrap: BootstrapResponse): void {
    for (const conversation of bootstrap.conversations ?? []) {
      const channelId = readString(conversation.conversation_id);
      if (!channelId) {
        continue;
      }

      const existing = this.checkpoints.get(channelId);
      const lastSeq = readNumber(conversation.last_seq);
      const lastMessageId = readString(conversation.last_message_id);
      if (existing?.lastSeq !== undefined) {
        continue;
      }

      this.checkpoints.set(channelId, {
        channelId,
        lastSeq: lastSeq ?? existing?.lastSeq,
        lastMessageId: lastMessageId ?? existing?.lastMessageId,
        updatedAt: existing?.updatedAt ?? Date.now(),
      });
    }
  }

  private async loadState(): Promise<void> {
    if (!this.statePath) {
      return;
    }
    try {
      const raw = await readFile(this.statePath, "utf8");
      const parsed = JSON.parse(raw) as {
        checkpoints?: CheckpointRecord[];
      };
      for (const item of parsed.checkpoints ?? []) {
        if (!item.channelId) {
          continue;
        }
        this.checkpoints.set(item.channelId, item);
      }
    } catch {
      return;
    }
  }

  private async flushState(): Promise<void> {
    if (!this.statePath) {
      return;
    }
    await mkdir(path.dirname(this.statePath), { recursive: true });
    const payload = JSON.stringify(
      {
        checkpoints: [...this.checkpoints.values()],
      },
      null,
      2,
    );
    await writeFile(this.statePath, payload, "utf8");
  }
}

let runtimeInstance: BotChatRuntime = new DefaultBotChatRuntime();

export function setBotChatRuntime(runtime: unknown): void {
  if (isBotChatRuntime(runtime)) {
    runtimeInstance = runtime;
  }
}

export function getBotChatRuntime(): BotChatRuntime {
  return runtimeInstance;
}

function isBotChatRuntime(value: unknown): value is BotChatRuntime {
  return (
    isRecord(value) &&
    typeof value.start === "function" &&
    typeof value.stop === "function" &&
    typeof value.onInboundMessage === "function" &&
    typeof value.sendToChannel === "function"
  );
}

interface PermissionApprover {
  approve(request: {
    topic: string;
    message: BotChatMessage;
    permission: { allowed: boolean; reason?: string };
  }): Promise<{ approved: boolean; reason?: string }>;
}

async function createApprover(
  config: Record<string, unknown>,
): Promise<PermissionApprover | undefined> {
  const enabled = Boolean(config.permissionApprovalEnabled);
  if (!enabled) {
    return undefined;
  }

  const handlerPath = readString(config.permissionApprovalHandler);
  if (handlerPath) {
    const loaded = await import(handlerPath);
    const approve = loaded.approve ?? loaded.default?.approve;
    if (typeof approve === "function") {
      return { approve };
    }
  }

  const approvalUrl = readString(config.permissionApprovalUrl);
  if (approvalUrl) {
    return {
      async approve(request) {
        const response = await fetch(approvalUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(request),
        });
        const json = await response.json();
        return (json?.data ?? json) as { approved: boolean; reason?: string };
      },
    };
  }

  return undefined;
}

async function bootstrapBot(
  backendUrl: string,
  botKey: string,
): Promise<BootstrapResponse> {
  const url = `${backendUrl.replace(/\/+$/, "")}/api/v1/bot-runtime/bootstrap`;
  const response = await fetch(url, {
    method: "GET",
    headers: {
      Accept: "application/json",
      "X-Bot-Key": botKey,
    },
  });

  if (!response.ok) {
    throw new Error(`bootstrap failed: ${response.status}`);
  }

  const json = (await response.json()) as { data?: BootstrapResponse };
  return json.data ?? {};
}

async function bootstrapBotWithRetry(
  backendUrl: string,
  botKey: string,
  logger: RuntimeLogger,
): Promise<BootstrapResponse> {
  const attempts = 3;
  let lastError: unknown;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await bootstrapBot(backendUrl, botKey);
    } catch (error) {
      lastError = error;
      if (attempt >= attempts) {
        break;
      }
      logger.warn("botchat.bootstrap.retry", {
        attempt,
        attempts,
        error: error instanceof Error ? error.message : String(error),
      });
      await delay(1500 * attempt);
    }
  }

  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function toInboundMessage(raw: unknown, topic: string): BotChatMessage | null {
  if (!isRecord(raw)) {
    return null;
  }

  const channelId = readString(raw.conversation_id) ?? readString(raw.dialog_id) ?? topic;
  const from = isRecord(raw.from) ? raw.from : undefined;
  const fromType = readString(from?.type) ?? readString(raw.sender_type);
  const content = isRecord(raw.content) ? raw.content : undefined;
  const contentType =
    readString(content?.type) ?? readString(raw.content_type) ?? readString(raw.msg_type);
  const contentMeta = isRecord(content?.meta) ? content.meta : undefined;
  const contentAsset = buildInboundContentAsset(raw, content, contentMeta, contentType);
  const messageId = readString(raw.id) ?? readString(raw.message_id);
  const seq = readNumber(raw.seq);
  const userId = readString(from?.id) ?? readString(raw.from_id);
  const text =
    readString(content?.body) ??
    readString(content?.text) ??
    readString(raw.body) ??
    readString(raw.text) ??
    inferInboundMessageText(contentType, contentAsset);
  const threadId =
    readString(raw.thread_id) ?? readString(contentMeta?.threadId) ?? readString(contentMeta?.thread_id);
  const replyToId =
    readString(raw.reply_to_id) ??
    readString(contentMeta?.replyToId) ??
    readString(contentMeta?.reply_to_id);

  if (!userId || !text) {
    return null;
  }

  return {
    channelId,
    userId,
    text,
    metadata: {
      topic,
      ...(fromType ? { senderType: fromType } : {}),
      ...(contentType ? { content_type: contentType } : {}),
      ...(messageId ? { message_id: messageId } : {}),
      ...(seq !== undefined ? { seq } : {}),
      ...(contentMeta ?? {}),
      ...(contentAsset ? { asset: contentAsset } : {}),
      ...(threadId ? { threadId } : {}),
      ...(replyToId ? { replyToId } : {}),
    },
  };
}

function buildInboundContentAsset(
  raw: Record<string, unknown>,
  content: Record<string, unknown> | undefined,
  contentMeta: Record<string, unknown> | undefined,
  contentType: string | undefined,
): Record<string, unknown> | undefined {
  const metaAsset = isRecord(contentMeta?.asset) ? contentMeta.asset : undefined;
  if (metaAsset) {
    return metaAsset;
  }

  const sourceUrl =
    readString(content?.url) ??
    readString(content?.source_url) ??
    readString(raw.url) ??
    readString(raw.source_url);
  if (!sourceUrl) {
    return undefined;
  }

  const fileName =
    readString(contentMeta?.file_name) ??
    readString(contentMeta?.filename) ??
    readString(contentMeta?.name) ??
    readString(raw.file_name) ??
    readString(raw.filename) ??
    readString(raw.name);
  const mimeType =
    readString(contentMeta?.mime_type) ??
    readString(contentMeta?.mimeType) ??
    readString(contentMeta?.content_type) ??
    readString(raw.mime_type) ??
    readString(raw.mimeType);
  const kind = contentType === "image" ? "image" : readString(contentType) ?? "file";

  return {
    kind,
    type: kind,
    source_url: sourceUrl,
    ...(fileName ? { file_name: fileName } : {}),
    ...(mimeType ? { mime_type: mimeType, content_type: mimeType } : {}),
  };
}

function inferInboundMessageText(
  contentType: string | undefined,
  asset: Record<string, unknown> | undefined,
): string | undefined {
  if (contentType !== "image" || !asset) {
    return undefined;
  }
  return readString(asset.file_name) ?? "Image";
}

async function fetchConversationMessages(
  backendUrl: string,
  botKey: string,
  conversationId: string,
  afterSeq: number | undefined,
  limit: number,
): Promise<unknown[]> {
  const url = buildBotChatHistoryMessagesUrl({ backendUrl, conversationId, afterSeq, limit });
  const response = await fetch(url, {
    method: "GET",
    headers: {
      Accept: "application/json",
      "X-Bot-Key": botKey,
    },
  });
  if (!response.ok) {
    return [];
  }
  const json = (await response.json()) as { data?: unknown[] };
  return Array.isArray(json.data) ? json.data : [];
}

function tryParseJson(value: string): unknown {
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function readStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((item) => readString(item)).filter((item): item is string => Boolean(item));
}

function readNumber(value: unknown): number | undefined {
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

function readBoolean(value: unknown): boolean | undefined {
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

function normalizeQos(value: unknown): MqttQos {
  const parsed = readNumber(value);
  if (parsed === 0 || parsed === 2) {
    return parsed;
  }
  return 1;
}
