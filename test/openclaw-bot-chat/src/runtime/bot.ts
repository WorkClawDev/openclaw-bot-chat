import path from "node:path";

import {
  getEnabledBots,
  type PluginConfig,
  type ResolvedBotConfig,
} from "../config";
import { BotChatHttpClient, BotChatHttpError } from "../client/http";
import { BotChatMqttClient, type BotChatMqttState } from "../client/mqtt";
import {
  createRuntimeLogger,
  isRuntimeDebugEnabled,
  previewText,
  summarizeValue,
} from "../logger";
import {
  normalizeBotChatMessage,
  resolveChannelContextFromDialog,
  routeIncomingMessage,
  shouldProcessMessage,
  toBotChatOutgoingMessage,
  toRealtimePublishPayload,
  toOpenClawRequest,
} from "../router/message";
import type {
  BootstrapResponse,
  BotChatMessage,
  Checkpoint,
  ConversationInfo,
  OpenClawAgent,
  PermissionApprover,
} from "../types";
import {
  buildChannelScopeKey,
  ChannelState,
  type ChannelContext,
} from "../types/channel";
import type { PermissionCheck } from "../types/permissions";
import { CheckpointStore } from "./checkpoint";
import { SessionManager } from "./session";

const RECENT_MESSAGE_CACHE_SIZE = 2_000;
const DEFAULT_HISTORY_LIMIT = 200;

type PermissionApprovalResult = {
  allowed: boolean;
  reason?: string;
  notifyMessage?: string;
};

export class OpenClawBotRuntime {
  private readonly runtimes: ManagedBotRuntime[];

  constructor(
    private readonly config: PluginConfig,
    private readonly agent: OpenClawAgent,
    private readonly permissionApprover?: PermissionApprover,
  ) {
    const enabledBots = getEnabledBots(config);
    if (enabledBots.length === 0) {
      throw new Error("At least one enabled bot is required");
    }

    this.runtimes = enabledBots.map(
      (botConfig) =>
        new ManagedBotRuntime(config, botConfig, agent, permissionApprover),
    );
  }

  async start(): Promise<void> {
    const started: ManagedBotRuntime[] = [];
    try {
      for (const runtime of this.runtimes) {
        await runtime.start();
        started.push(runtime);
      }
    } catch (error) {
      await Promise.allSettled(started.map((runtime) => runtime.stop()));
      throw error;
    }
  }

  async stop(): Promise<void> {
    await Promise.allSettled(this.runtimes.map((runtime) => runtime.stop()));
  }
}

class ManagedBotRuntime {
  private readonly checkpointStore: CheckpointStore;
  private readonly channelState = new ChannelState();
  private readonly httpClient: BotChatHttpClient;
  private readonly logger: ReturnType<typeof createRuntimeLogger>;
  private readonly sessionManager: SessionManager;

  private readonly processedMessages = new Map<string, number>();
  private readonly dialogQueues = new Map<string, Promise<void>>();

  private bootstrap?: BootstrapResponse;
  private botId?: string;
  private mqttClient?: BotChatMqttClient;
  private stopped = false;

  constructor(
    private readonly config: PluginConfig,
    private readonly botConfig: ResolvedBotConfig,
    private readonly agent: OpenClawAgent,
    private readonly permissionApprover?: PermissionApprover,
  ) {
    const botStateDir = path.join(
      config.stateDir,
      sanitizeStateKey(botConfig.key),
    );
    this.logger = createRuntimeLogger(this.logPrefix());

    this.httpClient = new BotChatHttpClient(
      config.botChatBaseUrl,
      botConfig.accessKey,
      config.httpTimeoutMs,
    );
    this.checkpointStore = new CheckpointStore(
      path.join(botStateDir, "checkpoints.json"),
    );
    this.sessionManager = new SessionManager(
      path.join(botStateDir, "sessions.json"),
    );
  }

  async start(): Promise<void> {
    this.stopped = false;
    this.logger.info("runtime.starting", {
      serviceUrl: this.config.botChatBaseUrl,
      stateDir: this.config.stateDir,
      botId: this.botConfig.id,
    });

    await this.sessionManager.load();
    await this.checkpointStore.load();

    this.bootstrap = await this.httpClient.bootstrap();
    this.botId = this.botConfig.id ?? this.bootstrap.bot.id;
    if (!this.botId) {
      throw new Error(`${this.logPrefix()} bot id is required`);
    }
    await this.checkpointStore.merge(
      this.bootstrap.conversations.map((item) => toCheckpoint(item)),
    );
    this.hydrateChannelState();

    const resolvedClientId = this.resolveClientId(this.bootstrap);
    const mqttOptions = {
      brokerUrl: this.resolveBrokerUrl(this.bootstrap),
      clientId: resolvedClientId,
      reconnectBaseDelayMs: this.config.reconnectBaseDelayMs,
      reconnectMaxDelayMs: this.config.reconnectMaxDelayMs,
      onError: (error: Error) => {
        this.logger.error("mqtt.error", undefined, error);
      },
      onConnect: () => {
        this.logger.info("mqtt.connected", {
          clientId: resolvedClientId,
          subscriptions: this.bootstrap?.subscriptions.length ?? 0,
        });
      },
      onReconnect: async () => {
        this.logger.warn("mqtt.reconnected", {
          botId: this.botId,
        });
        await this.recoverPendingMessages();
      },
      onMessage: async (topic: string, payload: unknown) => {
        const message = normalizeBotChatMessage(payload, topic);
        if (message) {
          await this.handleIncomingMessage(message);
        }
      },
      onStateChange: (state: BotChatMqttState) => {
        this.logger.info("mqtt.state_changed", { state });
      },
      ...(this.bootstrap.broker.username
        ? { username: this.bootstrap.broker.username }
        : {}),
      ...(this.bootstrap.broker.password
        ? { password: this.bootstrap.broker.password }
        : {}),
    };
    const mqttClient = new BotChatMqttClient(mqttOptions);
    this.mqttClient = mqttClient;

    await mqttClient.connect();
    const subscriptions = this.resolveSubscriptions(this.bootstrap);
    for (const subscription of subscriptions) {
      await mqttClient.subscribe(subscription.topic, subscription.qos);
    }

    await this.recoverPendingMessages();
    this.logger.info("runtime.started", {
      resolvedBotId: this.botId,
      subscriptions: subscriptions.length,
      publishTopics: this.bootstrap.publish_topics.length,
    });
  }

  async stop(): Promise<void> {
    if (this.stopped) {
      return;
    }
    this.stopped = true;

    await this.checkpointStore.flush();
    await this.sessionManager.flush();
    await this.mqttClient?.close();
    this.logger.info("runtime.stopped", {
      resolvedBotId: this.botId,
    });
  }

  private resolveBrokerUrl(bootstrap: BootstrapResponse): string {
    if (this.config.mqttWsUrl) {
      return this.config.mqttWsUrl;
    }
    if (bootstrap.broker.ws_url) {
      return bootstrap.broker.ws_url;
    }
    if (this.config.mqttTcpUrl) {
      return this.config.mqttTcpUrl;
    }
    if (bootstrap.broker.tcp_url) {
      return bootstrap.broker.tcp_url;
    }
    throw new Error(`${this.logPrefix()} bootstrap broker.ws_url or tcp_url is required`);
  }

  private resolveClientId(bootstrap: BootstrapResponse): string {
    const template = bootstrap.client_id.trim();
    if (!template) {
      throw new Error(`${this.logPrefix()} bootstrap client_id is required`);
    }
    if (!this.botId) {
      return template;
    }

    return template
      .replaceAll("{bot_id}", this.botId)
      .replaceAll("${bot_id}", this.botId);
  }

  private resolveSubscriptions(
    bootstrap: BootstrapResponse,
  ): Array<{ topic: string; qos: number }> {
    const qos = bootstrap.broker.qos ?? 1;
    const topics = new Map<string, number>();

    for (const subscription of bootstrap.subscriptions) {
      if (!subscription.topic) {
        continue;
      }
      topics.set(subscription.topic, subscription.qos ?? qos);
    }

    const expectedTopics = new Set<string>();
    for (const group of bootstrap.groups) {
      if (group.topic) {
        expectedTopics.add(group.topic);
        continue;
      }
      if (group.id) {
        expectedTopics.add(`chat/group/${group.id}`);
      }
    }
    for (const conversation of bootstrap.conversations) {
      const topic = conversation.topic ?? conversation.conversation_id;
      if (topic) {
        expectedTopics.add(topic);
      }
    }

    const autoAdded: string[] = [];
    for (const topic of expectedTopics) {
      if (topics.has(topic)) {
        continue;
      }
      topics.set(topic, qos);
      autoAdded.push(topic);
    }

    if (autoAdded.length > 0) {
      this.logger.warn("mqtt.subscription.autofill", {
        autoAddedTopics: autoAdded,
      });
    }

    return [...topics.entries()].map(([topic, topicQos]) => ({
      topic,
      qos: topicQos,
    }));
  }

  private hydrateChannelState(): void {
    const botId = this.botId;
    if (!botId) {
      return;
    }

    for (const conversation of this.bootstrap?.conversations ?? []) {
      this.trackDialog(toDialogInfo(conversation), botId);
    }

    for (const [dialogId, sessionId] of this.sessionManager.entries()) {
      const channel = resolveChannelContextFromDialog(dialogId, botId);
      this.channelState.setSession(channel, dialogId, sessionId);
    }

    for (const checkpoint of this.checkpointStore.values()) {
      const channel = resolveChannelContextFromDialog(
        checkpoint.dialog_id,
        botId,
      );
      this.channelState.setCheckpoint(channel, checkpoint);
    }
  }

  private async handleIncomingMessage(message: BotChatMessage): Promise<void> {
    if (!this.botId) {
      this.logger.warn("message.skipped.no_bot_id", {
        messageId: message.message_id,
        dialogId: message.dialog_id,
      });
      return;
    }
    if (!shouldProcessMessage(message, this.botId)) {
      if (isRuntimeDebugEnabled()) {
        this.logger.debug(
          "message.skipped.filtered",
          this.summarizeIncomingMessage(message),
        );
      }
      return;
    }
    if (this.isMessageProcessed(message.message_id)) {
      if (isRuntimeDebugEnabled()) {
        this.logger.debug(
          "message.skipped.duplicate",
          this.summarizeIncomingMessage(message),
        );
      }
      return;
    }

    const routed = routeIncomingMessage(message, this.botId, this.botConfig);
    const queueKey = `${buildChannelScopeKey(routed.channel)}::${message.dialog_id}`;

    this.logger.debug("message.received", {
      ...this.summarizeIncomingMessage(message),
      action: routed.action,
      queueKey,
      permissionAllowed: routed.permission.allowed,
    });

    await this.enqueueByDialog(queueKey, async () => {
      const startedAt = Date.now();
      try {
        const botId = this.botId;
        if (!botId || this.isMessageProcessed(message.message_id)) {
          return;
        }

        this.trackDialog(buildDialogInfo(message), botId, routed.channel);
        const checkpoint =
          this.channelState.getCheckpoint(routed.channel, message.dialog_id) ??
          this.checkpointStore.get(message.dialog_id);

        if (!routed.permission.allowed) {
          const approval = await this.resolvePermissionApproval(
            routed,
            message,
          );
          if (approval.allowed) {
            this.logger.info("message.permission_approved", {
              messageId: message.message_id,
              dialogId: message.dialog_id,
              botId: this.botId,
              approvalReason: approval.reason,
            });
          } else {
            this.logPermissionDenied(routed.permission, routed.channel, message);
            if (approval.notifyMessage && this.botId) {
              await this.publishPermissionDeniedNotice(
                message,
                this.botId,
                approval.notifyMessage,
              );
            }
          }
          if (!approval.allowed) {
            const existingSessionId =
              this.channelState.getSession(routed.channel, message.dialog_id) ??
              this.sessionManager.get(message.dialog_id) ??
              checkpoint?.session_id;
            await this.saveCheckpoint(
              message,
              existingSessionId,
              routed.channel,
            );
            this.markMessageProcessed(message.message_id);
            return;
          }
        }

        const sessionId =
          this.channelState.getSession(routed.channel, message.dialog_id) ??
          (await this.sessionManager.getOrCreate(
            message.dialog_id,
            checkpoint?.session_id,
          ));
        this.channelState.setSession(
          routed.channel,
          message.dialog_id,
          sessionId,
        );

        const request = toOpenClawRequest(message, sessionId, routed.channel);
        this.logger.debug("agent.request.prepared", {
          ...this.summarizeIncomingMessage(message),
          sessionId,
          requestMetadata: summarizeValue(request.metadata),
        });

        const response = await this.agent.respond(request);
        const outgoing = toBotChatOutgoingMessage(response, message, botId);

        this.logger.debug("agent.response.received", {
          messageId: message.message_id,
          dialogId: message.dialog_id,
          sessionId,
          responsePreview: previewText(response.content),
          responseMetadata: summarizeValue(response.metadata),
          hasOutgoingMessage: Boolean(outgoing),
        });

        if (outgoing) {
          await this.dispatchReply(outgoing, message, botId);
        } else {
          this.logger.warn("reply.skipped.empty", {
            messageId: message.message_id,
            dialogId: message.dialog_id,
            sessionId,
          });
        }

        await this.saveCheckpoint(message, sessionId, routed.channel);
        this.markMessageProcessed(message.message_id);
        this.logger.info("message.processed", {
          ...this.summarizeIncomingMessage(message),
          sessionId,
          durationMs: Date.now() - startedAt,
        });
      } catch (error) {
        this.logger.error(
          "message.processing_failed",
          {
            ...this.summarizeIncomingMessage(message),
            queueKey,
            durationMs: Date.now() - startedAt,
          },
          error,
        );
        throw error;
      }
    });
  }

  private async dispatchReply(
    outgoing: NonNullable<ReturnType<typeof toBotChatOutgoingMessage>>,
    sourceMessage: BotChatMessage,
    botId: string,
  ): Promise<void> {
    const mqttClient = this.mqttClient;
    if (!mqttClient) {
      throw new Error("mqtt client is not initialized");
    }

    const startedAt = Date.now();
    const publishFrame = toRealtimePublishPayload(outgoing, sourceMessage, botId);
    await mqttClient.publish(
      publishFrame.topic,
      publishFrame.payload,
      this.bootstrap?.broker.qos ?? 1,
    );
    this.logger.info("reply.dispatch.mqtt_publish", {
      sourceMessageId: sourceMessage.message_id,
      dialogId: sourceMessage.dialog_id,
      replyMessageId: outgoing.message_id,
      topic: publishFrame.topic,
      durationMs: Date.now() - startedAt,
    });
  }

  private async recoverPendingMessages(): Promise<void> {
    const dialogIds = new Set<string>();

    for (const conversation of this.bootstrap?.conversations ?? []) {
      dialogIds.add(conversation.conversation_id);
    }
    for (const checkpoint of this.checkpointStore.values()) {
      dialogIds.add(checkpoint.dialog_id);
    }

    this.logger.info("recovery.start", {
      dialogs: dialogIds.size,
    });
    for (const dialogId of dialogIds) {
      await this.recoverDialog(dialogId);
    }
    this.logger.info("recovery.complete", {
      dialogs: dialogIds.size,
    });
  }

  private async recoverDialog(dialogId: string): Promise<void> {
    const checkpoint = this.checkpointStore.get(dialogId);
    const limit =
      this.bootstrap?.history?.max_catchup_batch ?? DEFAULT_HISTORY_LIMIT;
    let rawMessages: unknown[];
    try {
      rawMessages = await this.httpClient.getConversationMessages(dialogId, {
        ...(checkpoint?.last_seq !== undefined
          ? { afterSeq: checkpoint.last_seq }
          : {}),
        limit,
      });
    } catch (error) {
      if (error instanceof BotChatHttpError) {
        if (error.status === 404 || error.status === 400) {
          this.logger.warn("recovery.dialog_skipped", {
            dialogId,
            status: error.status,
          });
          return;
        }
      }
      throw error;
    }

    let messages = rawMessages
      .map((item) => normalizeBotChatMessage(item))
      .filter((item): item is BotChatMessage => item !== null)
      .filter((item) => item.dialog_id === dialogId)
      .sort((left, right) => {
        const leftSeq = left.seq ?? 0;
        const rightSeq = right.seq ?? 0;
        if (leftSeq !== rightSeq) {
          return leftSeq - rightSeq;
        }
        return left.timestamp - right.timestamp;
      });

    messages = this.filterRecoveredMessages(messages, checkpoint);

    if (messages.length > 0 || isRuntimeDebugEnabled()) {
      this.logger.debug("recovery.dialog_messages", {
        dialogId,
        fetched: rawMessages.length,
        replaying: messages.length,
        checkpointSeq: checkpoint?.last_seq,
        checkpointMessageId: checkpoint?.last_message_id,
      });
    }

    for (const message of messages) {
      await this.handleIncomingMessage(message);
    }
  }

  private filterRecoveredMessages(
    messages: BotChatMessage[],
    checkpoint: Checkpoint | undefined,
  ): BotChatMessage[] {
    if (messages.length === 0) {
      return messages;
    }

    if (checkpoint?.last_seq !== undefined) {
      const lastSeq = checkpoint.last_seq;
      return messages.filter((item) => {
        if (item.seq !== undefined) {
          return item.seq > lastSeq;
        }
        return !this.isMessageProcessed(item.message_id);
      });
    }

    if (checkpoint?.last_message_id) {
      const lastProcessedIndex = messages.findIndex(
        (item) => item.message_id === checkpoint.last_message_id,
      );
      if (lastProcessedIndex >= 0) {
        return messages.slice(lastProcessedIndex + 1);
      }
    }

    return messages.filter((item) => !this.isMessageProcessed(item.message_id));
  }

  private async saveCheckpoint(
    message: BotChatMessage,
    sessionId: string | undefined,
    channel: ChannelContext,
  ): Promise<void> {
    const nextCheckpoint: Checkpoint = {
      dialog_id: message.dialog_id,
      last_message_id: message.message_id,
      updated_at: Date.now(),
      ...(message.seq !== undefined ? { last_seq: message.seq } : {}),
      ...(sessionId ? { session_id: sessionId } : {}),
    };

    this.channelState.setCheckpoint(channel, nextCheckpoint);
    await this.checkpointStore.update(nextCheckpoint);
    if (sessionId) {
      this.channelState.setSession(channel, message.dialog_id, sessionId);
      await this.sessionManager.set(message.dialog_id, sessionId);
    }

    this.logger.debug("checkpoint.saved", {
      dialogId: message.dialog_id,
      messageId: message.message_id,
      sessionId,
      seq: message.seq,
      channelId: channel.id,
      channelType: channel.type,
    });
  }

  private isMessageProcessed(messageId: string): boolean {
    return this.processedMessages.has(messageId);
  }

  private markMessageProcessed(messageId: string): void {
    this.processedMessages.set(messageId, Date.now());
    if (this.processedMessages.size <= RECENT_MESSAGE_CACHE_SIZE) {
      return;
    }

    const entries = [...this.processedMessages.entries()].sort(
      (left, right) => left[1] - right[1],
    );
    for (const [id] of entries.slice(
      0,
      entries.length - RECENT_MESSAGE_CACHE_SIZE,
    )) {
      this.processedMessages.delete(id);
    }
  }

  private async enqueueByDialog(
    queueKey: string,
    task: () => Promise<void>,
  ): Promise<void> {
    const current = this.dialogQueues.get(queueKey) ?? Promise.resolve();
    const next = current
      .catch(() => undefined)
      .then(task)
      .finally(() => {
        if (this.dialogQueues.get(queueKey) === next) {
          this.dialogQueues.delete(queueKey);
        }
      });

    this.dialogQueues.set(queueKey, next);
    return next;
  }

  private trackDialog(
    dialog: {
      dialog_id: string;
      topic?: string;
      title?: string;
      last_seq?: number;
      last_message_id?: string;
      updated_at?: number;
    },
    botId: string,
    channel?: ChannelContext,
  ): void {
    const resolvedChannel =
      channel ??
      resolveChannelContextFromDialog(
        dialog.dialog_id,
        botId,
        dialog.topic ? { topic: dialog.topic } : undefined,
      );
    this.channelState.trackDialog(resolvedChannel, dialog);
  }

  private logPermissionDenied(
    permission: PermissionCheck,
    channel: ChannelContext,
    message: BotChatMessage,
  ): void {
    this.logger.warn("message.permission_denied", {
      code: permission.code ?? "PERMISSION_DENIED",
      reason: permission.reason ?? "permission denied",
      required: permission.required ?? [],
      botId: this.botId,
      dialogId: message.dialog_id,
      messageId: message.message_id,
      channelId: channel.id,
      channelType: channel.type,
      userId: message.from_id,
    });
  }

  private async resolvePermissionApproval(
    routed: ReturnType<typeof routeIncomingMessage>,
    message: BotChatMessage,
  ): Promise<PermissionApprovalResult> {
    if (routed.permission.allowed) {
      return { allowed: true };
    }
    if (!this.permissionApprover || !this.botId) {
      return {
        allowed: false,
        ...(this.config.permissionDeniedReply
          ? { notifyMessage: this.config.permissionDeniedReply }
          : {}),
      };
    }

    try {
      const decision = await this.permissionApprover.approve({
        bot_id: this.botId,
        action: routed.action,
        permission: routed.permission,
        channel: {
          id: routed.channel.id,
          type: routed.channel.type,
          bot_id: routed.channel.botId,
          ...(routed.channel.userId ? { user_id: routed.channel.userId } : {}),
          ...(routed.channel.guildId
            ? { guild_id: routed.channel.guildId }
            : {}),
          ...(routed.channel.groupId
            ? { group_id: routed.channel.groupId }
            : {}),
        },
        message,
      });
      if (decision.approved) {
        return {
          allowed: true,
          ...(decision.reason ? { reason: decision.reason } : {}),
        };
      }
      const notifyMessage =
        decision.notify_message ??
        (decision.notify_user ? this.config.permissionDeniedReply : undefined);
      return {
        allowed: false,
        ...(decision.reason ? { reason: decision.reason } : {}),
        ...(notifyMessage ? { notifyMessage } : {}),
      };
    } catch (error) {
      this.logger.error(
        "permission.approval.failed",
        {
          messageId: message.message_id,
          dialogId: message.dialog_id,
          reason: routed.permission.reason,
        },
        error,
      );
      return {
        allowed: false,
        ...(this.config.permissionDeniedReply
          ? { notifyMessage: this.config.permissionDeniedReply }
          : {}),
      };
    }
  }

  private async publishPermissionDeniedNotice(
    sourceMessage: BotChatMessage,
    botId: string,
    content: string,
  ): Promise<void> {
    const outgoing = toBotChatOutgoingMessage(
      { content },
      sourceMessage,
      botId,
    );
    if (!outgoing) {
      return;
    }
    await this.dispatchReply(outgoing, sourceMessage, botId);
  }

  private logPrefix(): string {
    return `[openclaw-bot-chat:${this.botConfig.key}]`;
  }

  private summarizeIncomingMessage(
    message: BotChatMessage,
  ): Record<string, unknown> {
    return {
      messageId: message.message_id,
      dialogId: message.dialog_id,
      fromType: message.from_type,
      fromId: message.from_id,
      toType: message.to_type,
      toId: message.to_id,
      contentType: message.content_type,
      seq: message.seq,
      timestamp: message.timestamp,
      bodyPreview: previewText(message.body),
      metadata: summarizeValue(message.meta),
    };
  }
}

function buildDialogInfo(message: BotChatMessage): {
  dialog_id: string;
  topic?: string;
  last_seq?: number;
  last_message_id?: string;
  updated_at?: number;
} {
  const topic = readString(message.meta?.["topic"]);
  return {
    dialog_id: message.dialog_id,
    ...(topic ? { topic } : {}),
    ...(message.seq !== undefined ? { last_seq: message.seq } : {}),
    last_message_id: message.message_id,
    updated_at: message.timestamp,
  };
}

function toDialogInfo(conversation: ConversationInfo): {
  dialog_id: string;
  topic?: string;
  title?: string;
  last_seq?: number;
  last_message_id?: string;
  updated_at?: number;
} {
  return {
    dialog_id: conversation.conversation_id,
    ...(conversation.topic ? { topic: conversation.topic } : {}),
    ...(conversation.title ? { title: conversation.title } : {}),
    ...(conversation.last_seq !== undefined
      ? { last_seq: conversation.last_seq }
      : {}),
    ...(conversation.last_message_id
      ? { last_message_id: conversation.last_message_id }
      : {}),
    ...(conversation.updated_at !== undefined
      ? { updated_at: conversation.updated_at }
      : {}),
  };
}

function toCheckpoint(conversation: ConversationInfo): Checkpoint {
  return {
    dialog_id: conversation.conversation_id,
    ...(conversation.last_seq !== undefined
      ? { last_seq: conversation.last_seq }
      : {}),
    ...(conversation.last_message_id
      ? { last_message_id: conversation.last_message_id }
      : {}),
    ...(conversation.updated_at !== undefined
      ? { updated_at: conversation.updated_at }
      : {}),
  };
}

function sanitizeStateKey(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]+/g, "_");
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}
