import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import {
  BOT_CHAT_DEFAULT_ACCOUNT_ID,
  type BotChatMessage,
} from "./channel-api.js";
import {
  buildBotChatHistoryMessagesUrl,
  buildBotChatStatePath,
  evaluateBotChatAccess,
  inferBotChatGroupId,
  isBotChatConversationTopic,
  isRecord,
  readNumber,
  readString,
  readStringArray,
} from "./config.js";

export type { BotChatMessage } from "./channel-api.js";
export {
  BOT_CHAT_EMPTY_ALLOW_FROM_MESSAGE,
  buildBotChatBootstrapUrl,
  buildBotChatDirectTopic,
  buildBotChatGroupTopic,
  buildBotChatHistoryMessagesUrl,
  buildBotChatOutboundMessageTarget,
  buildBotChatStatePath,
  collectBotChatConfigIssues,
  evaluateBotChatAccess,
  hasBotChatAllowFromEntries,
  hasBotChatConfiguredState,
  inferBotChatTargetChatType,
  isBotChatControlTopic,
  isBotChatOpenAllowFrom,
  isBotChatSenderAllowed,
  isBotChatSystemInbound,
  isBotChatValidatedControlInbound,
  listBotChatAccountIds,
  normalizeAllowFromEntries,
  normalizeAllowFromEntry,
  normalizeBotChatConfig,
  normalizeBotChatTarget,
  parseBotChatTarget,
  resolveBotChatAccount,
  resolveBotChatDmPolicyMode,
  resolveDefaultBotChatAccountId,
} from "./config.js";

export type BotChatSendResult = {
  messageId: string;
};

export type RuntimeLogger = {
  info(msg: string, fields?: Record<string, unknown>): void;
  warn(msg: string, fields?: Record<string, unknown>): void;
  error(msg: string, fields?: Record<string, unknown>): void;
  debug?(msg: string, fields?: Record<string, unknown>): void;
};

export type BotChatTask = {
  id: string;
  title: string;
  description?: string | null;
  priority?: string;
  status: string;
  assignee_bot_id?: string | null;
  progress?: number;
  latest_status_note?: string | null;
  [key: string]: unknown;
};

export type BotChatTaskCreatePayload = Record<string, unknown>;
export type BotChatDocumentCreatePayload = {
  title: string;
  body: string;
  summary?: string;
  conversation_id?: string;
  send_url?: boolean;
  metadata?: Record<string, unknown>;
};

export type BotChatDocumentUpdatePayload = {
  title?: string;
  body?: string;
  summary?: string;
  conversation_id?: string;
  send_url?: boolean;
};

export type BotChatDocument = {
  id: string;
  url: string;
  title: string;
  summary?: string;
  body?: string;
  document_type?: string;
  source?: string;
  updated_at?: string;
  [key: string]: unknown;
};

export type BotChatTaskExecutionResult =
  | string
  | ({
      summary?: string;
      note?: string;
      latestStatusNote?: string;
      latest_status_note?: string;
      output?: string;
      result?: string;
      text?: string;
      artifacts?: unknown;
      metadata?: Record<string, unknown>;
    } & Record<string, unknown>)
  | void;

export interface BotChatTaskExecutionContext {
	progress(progress: number, note?: string): Promise<BotChatTask | undefined>;
	progress(note: string, progress?: number): Promise<BotChatTask | undefined>;
	createTask(payload: BotChatTaskCreatePayload): Promise<BotChatTask>;
	createDocument(payload: BotChatDocumentCreatePayload): Promise<BotChatDocument>;
	updateDocument(documentId: string, payload: BotChatDocumentUpdatePayload): Promise<BotChatDocument>;
}

export type BotChatTaskClient = {
	createTask(payload: BotChatTaskCreatePayload): Promise<BotChatTask>;
};

export type BotChatDocumentClient = {
	createDocument(payload: BotChatDocumentCreatePayload): Promise<BotChatDocument>;
	updateDocument(documentId: string, payload: BotChatDocumentUpdatePayload): Promise<BotChatDocument>;
};

export interface RuntimeHooks {
  emitMessage?: (message: BotChatMessage) => Promise<void>;
  requestPairing?: (params: {
    userId: string;
    channelId: string;
    message: BotChatMessage;
  }) => Promise<{ code?: string; created?: boolean; reply?: string } | void>;
  runTask?: (
    task: BotChatTask,
    context: BotChatTaskExecutionContext,
  ) => Promise<BotChatTaskExecutionResult>;
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
const BOT_CHAT_TASK_POLL_INTERVAL_MS = 15000;
const BOT_CHAT_TASK_STARTED_PROGRESS = 1;

export interface BotChatRuntime {
  start(
    config: Record<string, unknown>,
    logger: RuntimeLogger,
    hooks?: RuntimeHooks,
  ): Promise<void>;
  stop(): Promise<void>;
  onInboundMessage(message: BotChatMessage): Promise<void>;
  sendToChannel(message: BotChatMessage): Promise<BotChatSendResult>;
  getBotId?(): string | undefined;
}

function omitBotChatInternalMetadata(metadata: Record<string, unknown>): Record<string, unknown> {
  const { botId: _botId, toType: _toType, publishTopic: _publishTopic, retain: _retain, ...rest } = metadata;
  return rest;
}

export function normalizeBotChatInboundMessage(raw: unknown, topic: string): BotChatMessage | null {
  return toInboundMessage(raw, topic);
}

export function shouldReplayBotChatHistoryMessage(
  config: Record<string, unknown>,
  message: BotChatMessage,
): { allowed: boolean; reason?: string } {
  const access = evaluateBotChatAccess({ config, message });
  return { allowed: access.allowed, reason: access.reason };
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
    contentType === "image" || contentType === "audio"
      ? { type: contentType, body: message.text, ...(assetUrl ? { url: assetUrl } : {}), meta: contentMeta }
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
  private taskPollTimer?: NodeJS.Timeout;
  private taskPollActive = false;
  private executingTaskIds = new Set<string>();
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

    this.startTaskPolling(config);
  }

  async stop(): Promise<void> {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.connected = false;
    this.stopTaskPolling();
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

  getBotId(): string | undefined {
    return this.botId;
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
      if (access.invalidControl) {
        logger.warn("botchat.inbound.invalid_control", {
          topic,
          reason: access.reason,
          userId: message.userId,
        });
        return;
      }
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
      } else if (access.pendingPairing) {
        await this.forwardPendingPairing(message, logger);
        return;
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

  private async forwardPendingPairing(message: BotChatMessage, logger: RuntimeLogger): Promise<void> {
    logger.warn("botchat.inbound.pairing_pending", {
      topic: readString(message.metadata?.topic) ?? message.channelId,
      reason: "sender pending pairing",
      userId: message.userId,
    });
    const pairing = await this.hooks?.requestPairing?.({
      userId: message.userId,
      channelId: message.channelId,
      message,
    });
    const reply =
      readString(pairing?.reply) ??
      (readString(pairing?.code) ? `BotChat pairing code: ${pairing?.code}` : undefined);
    if (reply) {
      await this.sendToChannel({
        channelId: message.channelId,
        userId: message.userId,
        text: reply,
        metadata: {
          topic: readString(message.metadata?.topic) ?? message.channelId,
          pairingPending: true,
          pairingCode: pairing?.code,
        },
      });
    }
    await this.onInboundMessage({
      ...message,
      metadata: {
        ...(message.metadata ?? {}),
        pairingPending: true,
        ...(pairing?.code ? { pairingCode: pairing.code } : {}),
      },
    });
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
        const replay = shouldReplayBotChatHistoryMessage(config, normalized);
        if (!replay.allowed) {
          this.logger?.debug?.("botchat.history.skipped", {
            channelId: checkpoint.channelId,
            userId: normalized.userId,
            reason: replay.reason,
          });
          continue;
        }
        await this.onInboundMessage(normalized);
      }
    }
  }

  private startTaskPolling(config: Record<string, unknown>): void {
    if (!this.hooks?.runTask) {
      this.logger?.debug?.("botchat.tasks.polling_skipped", {
        reason: "missing_run_task_hook",
      });
      return;
    }
    const intervalMs = Math.max(
      1000,
      readNumber(config.taskPollingIntervalMs) ?? BOT_CHAT_TASK_POLL_INTERVAL_MS,
    );
    void this.pollTaskQueue();
    this.taskPollTimer = setInterval(() => {
      void this.pollTaskQueue();
    }, intervalMs);
    this.taskPollTimer.unref?.();
  }

  private stopTaskPolling(): void {
    if (this.taskPollTimer) {
      clearInterval(this.taskPollTimer);
      this.taskPollTimer = undefined;
    }
    this.taskPollActive = false;
    this.executingTaskIds.clear();
  }

  private async pollTaskQueue(): Promise<void> {
    if (this.taskPollActive || !this.backendUrl || !this.botKey || !this.botId || !this.hooks?.runTask) {
      return;
    }
    this.taskPollActive = true;
    try {
      await pollBotChatTasksOnce({
        backendUrl: this.backendUrl,
        botKey: this.botKey,
        botId: this.botId,
        hooks: this.hooks,
        logger: this.logger,
        executingTaskIds: this.executingTaskIds,
      });
    } catch (error) {
      this.logger?.warn("botchat.tasks.poll_failed", {
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      this.taskPollActive = false;
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

export async function runBotChatTaskPollOnceForTest(params: {
  backendUrl: string;
  botKey: string;
  botId: string;
  hooks: RuntimeHooks;
  logger?: RuntimeLogger;
}): Promise<void> {
  await pollBotChatTasksOnce({
    ...params,
    executingTaskIds: new Set<string>(),
  });
}

export function createBotChatTaskClient(params: {
	backendUrl: string;
	botKey: string;
}): BotChatTaskClient {
  return {
    createTask(payload) {
      return createBotChatTask(params.backendUrl, params.botKey, payload);
    },
	};
}

export function createBotChatDocumentClient(params: {
	backendUrl: string;
	botKey: string;
}): BotChatDocumentClient {
	return {
		createDocument(payload) {
			return createBotChatDocument(params.backendUrl, params.botKey, payload);
		},
		updateDocument(documentId, payload) {
			return updateBotChatDocument(params.backendUrl, params.botKey, documentId, payload);
		},
	};
}

async function pollBotChatTasksOnce(params: {
  backendUrl: string;
  botKey: string;
  botId: string;
  hooks: RuntimeHooks;
  logger?: RuntimeLogger;
  executingTaskIds: Set<string>;
}): Promise<void> {
  const runTask = params.hooks.runTask;
  if (!runTask) {
    params.logger?.debug?.("botchat.tasks.polling_skipped", {
      reason: "missing_run_task_hook",
    });
    return;
  }

  const task = selectRunnableBotChatTask(
    await fetchBotChatTasks(params.backendUrl, params.botKey),
    params.botId,
    params.executingTaskIds,
  );
  if (!task) {
    return;
  }

  params.executingTaskIds.add(task.id);
  let activeTask = task;
  try {
    if (task.status === "available") {
      const claimed = await postBotChatTaskTransition(params.backendUrl, params.botKey, task.id, "claim", {
        latest_status_note: "Robot claimed task",
      });
      if (!claimed) {
        return;
      }
      activeTask = claimed;
    }

    if (activeTask.status === "claimed") {
      const progressed = await postBotChatTaskTransition(params.backendUrl, params.botKey, activeTask.id, "progress", {
        progress: Math.max(activeTask.progress ?? 0, BOT_CHAT_TASK_STARTED_PROGRESS),
        latest_status_note: "Robot started task",
      });
      if (progressed) {
        activeTask = progressed;
      }
    }

    const context = createBotChatTaskExecutionContext({
      backendUrl: params.backendUrl,
      botKey: params.botKey,
      getActiveTask: () => activeTask,
      updateActiveTask(task) {
        if (task) {
          activeTask = task;
        }
      },
    });
    const result = await runTask(activeTask, context);
    await postBotChatTaskResult(params.backendUrl, params.botKey, activeTask.id, result);
  } catch (error) {
    await postBotChatTaskTransition(params.backendUrl, params.botKey, activeTask.id, "fail", {
      latest_status_note: error instanceof Error ? error.message : String(error),
      error: serializeTaskError(error),
    });
  } finally {
    params.executingTaskIds.delete(task.id);
  }
}

function selectRunnableBotChatTask(
  tasks: BotChatTask[],
  botId: string,
  executingTaskIds: Set<string>,
): BotChatTask | undefined {
  return tasks.find((task) => {
    if (!task.id || executingTaskIds.has(task.id)) {
      return false;
    }
    if (task.status === "available" && !task.assignee_bot_id) {
      return true;
    }
    if ((task.status === "claimed" || task.status === "in_progress") && task.assignee_bot_id === botId) {
      return true;
    }
    return false;
  });
}

async function fetchBotChatTasks(backendUrl: string, botKey: string): Promise<BotChatTask[]> {
  const queueResponse = await fetch(buildBotChatRuntimeTaskQueueUrl(backendUrl), {
    method: "GET",
    headers: {
      Accept: "application/json",
      "X-Bot-Key": botKey,
    },
  });

  if (queueResponse.ok) {
    return parseBotChatTaskList(await queueResponse.json());
  }

  if (queueResponse.status !== 404 && queueResponse.status !== 405) {
    throw new Error(`task queue failed: ${queueResponse.status}`);
  }

  const response = await fetch(buildBotChatRuntimeTaskUrl(backendUrl), {
    method: "GET",
    headers: {
      Accept: "application/json",
      "X-Bot-Key": botKey,
    },
  });
  if (!response.ok) {
    throw new Error(`task list failed: ${response.status}`);
  }
  return parseBotChatTaskList(await response.json());
}

function parseBotChatTaskList(json: unknown): BotChatTask[] {
  const data = isRecord(json) ? json.data : undefined;
  return Array.isArray(data) ? data.map(toBotChatTask).filter((task): task is BotChatTask => Boolean(task)) : [];
}

async function postBotChatTaskTransition(
  backendUrl: string,
  botKey: string,
  taskId: string,
  action: "claim" | "progress" | "complete" | "fail" | "result",
  body: Record<string, unknown>,
): Promise<BotChatTask | undefined> {
  const response = await fetch(buildBotChatRuntimeTaskUrl(backendUrl, taskId, action), {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-Bot-Key": botKey,
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    if (response.status === 409 || response.status === 404) {
      return undefined;
    }
    throw new Error(`task ${action} failed: ${response.status}`);
  }
  const json = (await response.json()) as { data?: unknown };
  return toBotChatTask(json.data);
}

async function postBotChatTaskResult(
  backendUrl: string,
  botKey: string,
  taskId: string,
  result: BotChatTaskExecutionResult,
): Promise<BotChatTask | undefined> {
  const body = buildBotChatTaskResultBody(result);
  const response = await fetch(buildBotChatRuntimeTaskUrl(backendUrl, taskId, "result"), {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-Bot-Key": botKey,
    },
    body: JSON.stringify(body),
  });
  if (response.status === 404 || response.status === 405) {
    return postBotChatTaskTransition(backendUrl, botKey, taskId, "complete", body);
  }
  if (!response.ok) {
    if (response.status === 409) {
      return undefined;
    }
    throw new Error(`task result failed: ${response.status}`);
  }
  const json = (await response.json()) as { data?: unknown };
  return toBotChatTask(json.data);
}

async function createBotChatTask(
  backendUrl: string,
  botKey: string,
  payload: BotChatTaskCreatePayload,
): Promise<BotChatTask> {
  const response = await fetch(buildBotChatRuntimeTaskUrl(backendUrl), {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-Bot-Key": botKey,
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw new Error(`task create failed: ${response.status}`);
  }
  const json = (await response.json()) as { data?: unknown };
  const task = toBotChatTask(json.data);
  if (!task) {
    throw new Error("task create returned an invalid task");
  }
  return task;
}

function buildBotChatRuntimeTaskUrl(
  backendUrl: string,
  taskId?: string,
  action?: "claim" | "progress" | "complete" | "fail" | "result",
): string {
  const base = `${backendUrl.replace(/\/+$/, "")}/api/v1/bot-runtime/tasks`;
  if (!taskId) {
    return base;
  }
  return `${base}/${encodeURIComponent(taskId)}/${action}`;
}

function buildBotChatRuntimeTaskQueueUrl(backendUrl: string): string {
  return `${backendUrl.replace(/\/+$/, "")}/api/v1/bot-runtime/tasks/queue`;
}

function createBotChatTaskExecutionContext(params: {
  backendUrl: string;
  botKey: string;
  getActiveTask: () => BotChatTask;
  updateActiveTask: (task: BotChatTask | undefined) => void;
}): BotChatTaskExecutionContext {
	return {
    async progress(first: number | string, second?: number | string) {
      const body = normalizeTaskProgressBody(first, second);
      const task = await postBotChatTaskTransition(
        params.backendUrl,
        params.botKey,
        params.getActiveTask().id,
        "progress",
        body,
      );
      params.updateActiveTask(task);
      return task;
    },
		createTask(payload) {
			return createBotChatTask(params.backendUrl, params.botKey, {
				parent_task_id: params.getActiveTask().id,
				...payload,
			});
		},
		createDocument(payload) {
			return createBotChatDocument(params.backendUrl, params.botKey, payload);
		},
		updateDocument(documentId, payload) {
			return updateBotChatDocument(params.backendUrl, params.botKey, documentId, payload);
		},
	};
}

async function createBotChatDocument(
	backendUrl: string,
	botKey: string,
	payload: BotChatDocumentCreatePayload,
): Promise<BotChatDocument> {
	const response = await fetch(buildBotChatRuntimeDocumentUrl(backendUrl), {
		method: "POST",
		headers: {
			Accept: "application/json",
			"Content-Type": "application/json",
			"X-Bot-Key": botKey,
		},
		body: JSON.stringify({
			document_type: "markdown",
			...payload,
		}),
	});
	if (!response.ok) {
		throw new Error(`document create failed: ${response.status}`);
	}
	const json = (await response.json()) as { data?: { document?: unknown } };
	const document = toBotChatDocument(json.data?.document);
	if (!document) {
		throw new Error("document create returned an invalid document");
	}
	return document;
}

async function updateBotChatDocument(
	backendUrl: string,
	botKey: string,
	documentId: string,
	payload: BotChatDocumentUpdatePayload,
): Promise<BotChatDocument> {
	const response = await fetch(buildBotChatRuntimeDocumentUrl(backendUrl, documentId), {
		method: "PUT",
		headers: {
			Accept: "application/json",
			"Content-Type": "application/json",
			"X-Bot-Key": botKey,
		},
		body: JSON.stringify(payload),
	});
	if (!response.ok) {
		throw new Error(`document update failed: ${response.status}`);
	}
	const json = (await response.json()) as { data?: { document?: unknown } };
	const document = toBotChatDocument(json.data?.document);
	if (!document) {
		throw new Error("document update returned an invalid document");
	}
	return document;
}

function buildBotChatRuntimeDocumentUrl(backendUrl: string, documentId?: string): string {
	const base = `${backendUrl.replace(/\/+$/, "")}/api/v1/bot-runtime/documents`;
	if (!documentId) {
		return base;
	}
	return `${base}/${encodeURIComponent(documentId)}`;
}

function normalizeTaskProgressBody(
  first: number | string,
  second?: number | string,
): Record<string, unknown> {
  let progress: number | undefined;
  let note: string | undefined;

  if (typeof first === "number") {
    progress = first;
    note = readString(second);
  } else {
    note = readString(first);
    progress = typeof second === "number" ? second : undefined;
  }

  const body: Record<string, unknown> = {};
  if (progress !== undefined && Number.isFinite(progress)) {
    body.progress = progress;
  }
  if (note) {
    body.latest_status_note = note;
  }
  if (!("progress" in body) && !("latest_status_note" in body)) {
    throw new Error("task progress requires a progress number or status note");
  }
  return body;
}

function buildBotChatTaskResultBody(result: BotChatTaskExecutionResult): Record<string, unknown> {
  const latestStatusNote = summarizeTaskExecutionResult(result) ?? "Robot completed task";
  return {
    result: normalizeTaskExecutionResult(result, latestStatusNote),
    latest_status_note: latestStatusNote,
  };
}

function normalizeTaskExecutionResult(
  result: BotChatTaskExecutionResult,
  fallbackSummary: string,
): Record<string, unknown> {
  if (typeof result === "string") {
    return {
      summary: result,
      output: result,
    };
  }
  if (isRecord(result)) {
    return { ...result };
  }
  return {
    summary: fallbackSummary,
  };
}

function toBotChatTask(value: unknown): BotChatTask | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const id = readString(value.id);
  const title = readString(value.title);
  const status = readString(value.status);
  if (!id || !title || !status) {
    return undefined;
  }
  return {
    ...value,
    id,
    title,
    status,
    description: readString(value.description) ?? null,
    assignee_bot_id: readString(value.assignee_bot_id) ?? null,
    latest_status_note: readString(value.latest_status_note) ?? null,
    progress: readNumber(value.progress),
  };
}

function toBotChatDocument(value: unknown): BotChatDocument | undefined {
	if (!isRecord(value)) {
		return undefined;
	}
	const id = readString(value.id);
	const url = readString(value.url);
	const title = readString(value.title);
	if (!id || !url || !title) {
		return undefined;
	}
	return {
		...value,
		id,
		url,
		title,
		summary: readString(value.summary),
		body: readString(value.body),
		document_type: readString(value.document_type),
		source: readString(value.source),
		updated_at: readString(value.updated_at),
	};
}

function summarizeTaskExecutionResult(result: BotChatTaskExecutionResult): string | undefined {
  if (typeof result === "string") {
    return result.trim() || undefined;
  }
  if (!isRecord(result)) {
    return undefined;
  }
  return (
    readString(result.summary) ??
    readString(result.latestStatusNote) ??
    readString(result.latest_status_note) ??
    readString(result.note) ??
    readString(result.output) ??
    readString(result.result) ??
    readString(result.text)
  );
}

function serializeTaskError(error: unknown): Record<string, unknown> {
  if (error instanceof Error) {
    const serialized: Record<string, unknown> = {
      name: error.name,
      message: error.message,
    };
    if (error.stack) {
      serialized.stack = error.stack;
    }
    const maybeCode = isRecord(error) ? error.code : undefined;
    const code = readString(maybeCode);
    if (code) {
      serialized.code = code;
    }
    return serialized;
  }
  return {
    name: "Error",
    message: String(error),
  };
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

function normalizeQos(value: unknown): MqttQos {
  const parsed = readNumber(value);
  if (parsed === 0 || parsed === 2) {
    return parsed;
  }
  return 1;
}
