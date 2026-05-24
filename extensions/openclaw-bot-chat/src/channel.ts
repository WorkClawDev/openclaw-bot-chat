import {
  BOT_CHAT_CHANNEL_ID,
  BOT_CHAT_SLASH_AUTOCOMPLETE_REQUEST_TOPIC,
  BOT_CHAT_SLASH_COMMAND_TOPIC,
  type ChannelPlugin,
  type ChannelOutboundAdapter,
  type ResolvedBotChatAccount,
} from "./channel-api.js";
import { createRequire } from "node:module";
import { promises as fs } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { createBotChatPluginBase } from "./shared.js";
import { botChatStatus } from "./status.js";
import { botChatSetupAdapter } from "./channel.setup.js";
import { botChatDoctor } from "./doctor.js";
import { botChatSecrets } from "./secret-config-contract.js";
import {
  buildBotChatOutboundMessageTarget,
  getBotChatRuntime,
  resolveBotChatAccount,
} from "./runtime.js";

type BotChatAttachment = {
  type: string;
  kind: string;
  url: string;
  name?: string;
  fileName?: string;
  mimeType?: string;
  contentType?: string;
  size?: number;
  asset?: Record<string, unknown>;
};

type BotChatSlashCommand = {
  name: string;
  description?: string;
  acceptsArgs?: boolean;
  args?: Array<Record<string, unknown>>;
};

type BotChatSlashCommandChoice = {
  label: string;
  value: string;
  description?: string;
};

type BotChatSlashAutocompleteRequest = {
  requestId: string;
  responseTopic: string;
  commandName: string;
  argName?: string;
  argIndex: number;
  partial: string;
};

type BotChatSlashCommandResolvers = {
  listSkillCommandsForAgents?: (params: { cfg: Record<string, unknown> }) => Array<Record<string, unknown>>;
  listNativeCommandSpecsForConfig?: (
    cfg: Record<string, unknown>,
    params?: { provider?: string; skillCommands?: Array<Record<string, unknown>> },
  ) => Array<Record<string, unknown>>;
  getPluginCommandSpecs?: (
    provider?: string,
    options?: { config?: Record<string, unknown> },
  ) => Array<Record<string, unknown>>;
  resolveNativeCommandAutocomplete?: (
    params: {
      cfg: Record<string, unknown>;
      provider: string;
      commandName: string;
      argName?: string;
      argIndex: number;
      partial: string;
    },
  ) => unknown[] | Promise<unknown[]>;
};

type BotChatNativeCommandRegistryModule = {
  listNativeCommandSpecsForConfig?: BotChatSlashCommandResolvers["listNativeCommandSpecsForConfig"];
};

type BotChatSkillCommandRuntimeModule = {
  listSkillCommandsForAgents?: BotChatSlashCommandResolvers["listSkillCommandsForAgents"];
};

type BotChatPluginRuntimeModule = {
  getPluginCommandSpecs?: BotChatSlashCommandResolvers["getPluginCommandSpecs"];
};

type BotChatCommandAutocompleteModule = {
  resolveNativeCommandAutocomplete?: BotChatSlashCommandResolvers["resolveNativeCommandAutocomplete"];
  listNativeCommandAutocompleteChoices?: BotChatSlashCommandResolvers["resolveNativeCommandAutocomplete"];
};

let botChatSlashCommandResolversForTest: BotChatSlashCommandResolvers | undefined;

export function setBotChatSlashCommandResolversForTest(
  resolvers: BotChatSlashCommandResolvers | undefined,
): void {
  botChatSlashCommandResolversForTest = resolvers;
}

const botChatOutboundAdapter: ChannelOutboundAdapter = {
  deliveryMode: "direct",
  textChunkLimit: 4000,
  sendText: async ({ cfg, to, text, accountId, metadata }) => {
    const account = resolveBotChatAccount(cfg, accountId ?? undefined);
    const target = buildBotChatOutboundMessageTarget({ raw: to, account, metadata });
    const mediaDirective = extractBotChatMediaDirective(text);
    const body = mediaDirective?.body ?? text;
    const result = await getBotChatRuntime().sendToChannel({
      channelId: target.channelId,
      userId: target.userId,
      text: body,
      metadata: {
        ...(metadata ?? {}),
        target: target.normalizedTarget,
        chatType: target.chatType,
        botId: account.botId,
        toType: target.recipientType,
        publishTopic: target.publishTopic,
      },
    });
    return {
      channel: BOT_CHAT_CHANNEL_ID,
      messageId: result.messageId,
      channelId: target.channelId,
      conversationId: target.channelId,
      timestamp: Date.now(),
      meta: {
        target: target.normalizedTarget,
        chatType: target.chatType,
        recipientType: target.recipientType,
        publishTopic: target.publishTopic,
      },
    };
  },
  sendMedia: async ({ cfg, to, text, mediaUrl, mediaAccess, accountId, metadata }) => {
    const account = resolveBotChatAccount(cfg, accountId ?? undefined);
    const target = buildBotChatOutboundMessageTarget({ raw: to, account, metadata });
    const fallbackBody = text?.trim() || readFileNameFromMediaPath(mediaUrl) || "Image";
    let asset: Record<string, unknown> | undefined;
    try {
      asset = await prepareBotChatOutboundMediaAsset(account, mediaUrl);
    } catch {
      asset = undefined;
    }
    const body = text?.trim() || readString(asset?.file_name) || fallbackBody;
    const result = await getBotChatRuntime().sendToChannel({
      channelId: target.channelId,
      userId: target.userId,
      text: body,
      metadata: {
        ...(metadata ?? {}),
        ...(asset
          ? {
              content_type: "image",
              asset: {
                ...asset,
                ...(mediaAccess ? { access: mediaAccess } : {}),
              },
            }
          : {}),
        target: target.normalizedTarget,
        chatType: target.chatType,
        botId: account.botId,
        toType: target.recipientType,
        publishTopic: target.publishTopic,
      },
    });
    return {
      channel: BOT_CHAT_CHANNEL_ID,
      messageId: result.messageId,
      channelId: target.channelId,
      conversationId: target.channelId,
      timestamp: Date.now(),
      meta: {
        target: target.normalizedTarget,
        chatType: target.chatType,
        recipientType: target.recipientType,
        publishTopic: target.publishTopic,
      },
    };
  },
};

export const botChatPlugin: ChannelPlugin<ResolvedBotChatAccount> = {
  ...createBotChatPluginBase({ setup: botChatSetupAdapter }),
  doctor: botChatDoctor,
  secrets: botChatSecrets,
  status: botChatStatus,
  gateway: {
    startAccount: async (ctx) => {
      const logger = {
        info: (message: string, fields?: Record<string, unknown>) => ctx.log?.info?.(message, fields),
        warn: (message: string, fields?: Record<string, unknown>) => ctx.log?.warn?.(message, fields),
        error: (message: string, fields?: Record<string, unknown>) => ctx.log?.error?.(message, fields),
        debug: (message: string, fields?: Record<string, unknown>) => ctx.log?.debug?.(message, fields),
      };
      await getBotChatRuntime().start(ctx.account.config as Record<string, unknown>, logger, {
        emitMessage: async (message) => {
          if (message.metadata?.senderType === "bot") {
            return;
          }
          if (await handleBotChatSlashAutocompleteRequest({
            cfg: ctx.cfg,
            account: ctx.account,
            log: ctx.log,
            message,
          })) {
            return;
          }
          await dispatchBotChatReply({
            cfg: ctx.cfg,
            account: ctx.account,
            channelRuntime: ctx.channelRuntime,
            log: ctx.log,
            message,
          });
        },
      });
      await publishBotChatSlashCommands({
        cfg: ctx.cfg,
        account: ctx.account,
        log: ctx.log,
      });
      ctx.setStatus?.({
        connected: true,
        accountId: ctx.account.accountId,
        botId: ctx.account.botId,
      });
      const stop = async () => {
        await getBotChatRuntime().stop();
        ctx.setStatus?.({ connected: false, accountId: ctx.account.accountId });
      };
      if (ctx.abortSignal) {
        await waitForAbort(ctx.abortSignal);
        await stop();
        return;
      }
      return { stop };
    },
  },
  outbound: botChatOutboundAdapter,
  approvalCapability: {
    mode: "pairing",
    description: "BotChat uses allowFrom/pairing as the primary gate and optional custom approval as a secondary blocked-message gate.",
    secondaryGate: "custom-approval",
  },
};

async function dispatchBotChatReply(params: {
  cfg: Record<string, unknown>;
  account: ResolvedBotChatAccount;
  channelRuntime?: {
    reply?: {
      dispatchReplyWithBufferedBlockDispatcher?: (params: {
        ctx: Record<string, unknown>;
        cfg: Record<string, unknown>;
        replyOptions?: {
          sourceReplyDeliveryMode?: "automatic" | "message_tool_only";
        };
        dispatcherOptions: {
          deliver: (payload: { text?: string }, info?: { kind?: string }) => Promise<void>;
          onError?: (error: unknown, info?: { kind?: string }) => void;
          onSkip?: (payload: unknown, info?: { kind?: string; reason?: string }) => void;
        };
      }) => Promise<unknown>;
    };
  };
  log?: {
    warn?(message: string, fields?: Record<string, unknown>): void;
    error?(message: string, fields?: Record<string, unknown>): void;
    debug?(message: string, fields?: Record<string, unknown>): void;
  };
  message: {
    channelId: string;
    userId: string;
    text: string;
    metadata?: Record<string, unknown>;
  };
}): Promise<void> {
  const dispatch = params.channelRuntime?.reply?.dispatchReplyWithBufferedBlockDispatcher;
  if (!dispatch) {
    params.log?.warn?.("botchat.inbound.no_channel_runtime", {
      channelId: params.message.channelId,
      userId: params.message.userId,
    });
    return;
  }

  params.log?.debug?.("botchat.reply.dispatch_start", {
    channelId: params.message.channelId,
    userId: params.message.userId,
  });
  const replyChunks: string[] = [];
  const botId = resolveBotChatRuntimeBotId(params.account);
  const replyTarget = buildBotChatReplyTarget(params.message);
  const attachments = buildBotChatAttachments(params.message);
  const gatewayBody = buildBotChatGatewayBody(params.message.text, attachments);
  const attachmentContext =
    attachments.length > 0
      ? {
          Attachments: attachments,
          attachments,
          Media: attachments,
          media: attachments,
          Files: attachments,
          files: attachments,
          MediaUrl: attachments[0]?.url,
          MediaUrls: attachments.map((attachment) => attachment.url),
          MediaType: attachments[0]?.mimeType ?? attachments[0]?.contentType,
          MediaTypes: attachments.map(
            (attachment) => attachment.mimeType ?? attachment.contentType ?? "application/octet-stream",
          ),
          HasAttachments: true,
          AttachmentCount: attachments.length,
        }
      : {};
  await dispatch({
    cfg: params.cfg,
    ctx: {
      Body: gatewayBody.body,
      BodyForAgent: gatewayBody.body,
      RawBody: gatewayBody.commandBody,
      CommandBody: gatewayBody.commandBody,
      BodyForCommands: gatewayBody.commandBody,
      ...attachmentContext,
      From: params.message.userId,
      To: botId,
      SenderId: params.message.userId,
      MessageSid: String(params.message.metadata?.message_id ?? ""),
      SessionKey: `bot-chat:${params.message.channelId}`,
      ChatType: replyTarget.chatType,
      Provider: "BotChat",
      Surface: "BotChat",
      OriginatingChannel: BOT_CHAT_CHANNEL_ID,
      OriginatingTo: params.message.channelId,
      ExplicitDeliverRoute: true,
      NativeChannelId: params.message.channelId,
      CommandSource: resolveBotChatCommandSource(params.message),
      CommandAuthorized: true,
      Timestamp: Date.now(),
    },
    ...(replyTarget.recipientType === "group"
      ? {
          replyOptions: {
            sourceReplyDeliveryMode: "automatic" as const,
          },
        }
      : {}),
    dispatcherOptions: {
      deliver: async (payload) => {
        const text = typeof payload.text === "string" ? payload.text.trim() : "";
        if (!text) {
          return;
        }
        replyChunks.push(text);
        params.log?.debug?.("botchat.reply.buffered", {
          channelId: params.message.channelId,
          userId: params.message.userId,
          chunks: replyChunks.length,
        });
      },
      onError: (error, info) => {
        params.log?.error?.("botchat.reply.dispatch_error", {
          error: error instanceof Error ? error.message : String(error),
          kind: info?.kind,
        });
      },
      onSkip: (_payload, info) => {
        params.log?.debug?.("botchat.reply.skipped", {
          kind: info?.kind,
          reason: info?.reason,
        });
      },
    },
  });
  const replyText = mergeBotChatReplyChunks(replyChunks);
  if (replyText) {
    const preparedReply = await prepareBotChatReplyDelivery(
      replyText,
      params.account,
      buildBotChatReplyMetadata(params.message.metadata),
      params.log,
    );
    params.log?.debug?.("botchat.reply.deliver", {
      channelId: params.message.channelId,
      userId: params.message.userId,
      chunks: replyChunks.length,
    });
    await getBotChatRuntime().sendToChannel({
      channelId: params.message.channelId,
      userId: replyTarget.recipientId,
      text: preparedReply.text,
      metadata: {
        ...preparedReply.metadata,
        botId,
        toType: replyTarget.recipientType,
        publishTopic: params.message.metadata?.topic ?? params.message.channelId,
      },
    });
  }
  params.log?.debug?.("botchat.reply.dispatch_done", {
    channelId: params.message.channelId,
    userId: params.message.userId,
  });
}

function resolveBotChatRuntimeBotId(account: ResolvedBotChatAccount): string {
  return readString(account.config.botId) ?? account.botId;
}

function buildBotChatReplyTarget(message: {
  channelId: string;
  userId: string;
}): { recipientId: string; recipientType: "user" | "group"; chatType: "direct" | "group" } {
  const groupId = readBotChatGroupId(message.channelId);
  if (groupId) {
    return {
      recipientId: groupId,
      recipientType: "group",
      chatType: "group",
    };
  }
  return {
    recipientId: message.userId,
    recipientType: "user",
    chatType: "direct",
  };
}

function readBotChatGroupId(channelId: string): string | undefined {
  const parts = channelId.split("/");
  if (parts.length === 3 && parts[0] === "chat" && parts[1] === "group") {
    return parts[2] || undefined;
  }
  return undefined;
}

function mergeBotChatReplyChunks(chunks: string[]): string {
  const merged: string[] = [];
  for (const chunk of chunks) {
    const text = chunk.trim();
    if (!text || merged[merged.length - 1] === text) {
      continue;
    }
    merged.push(text);
  }
  return merged.join("\n\n").trim();
}

function buildBotChatAttachments(message: {
  text: string;
  metadata?: Record<string, unknown>;
}): BotChatAttachment[] {
  const metadata = message.metadata ?? {};
  const messageMeta = readRecord(metadata.message_meta);
  const asset =
    readRecord(metadata.asset) ??
    readRecord(messageMeta?.asset) ??
    readRecord(metadata.attachment);
  const attachment = buildBotChatAttachmentFromAsset(asset, metadata, message.text);
  return attachment ? [attachment] : [];
}

function buildBotChatGatewayBody(
  text: string,
  attachments: BotChatAttachment[],
): { body: string; commandBody: string } {
  if (attachments.length === 0) {
    return { body: text, commandBody: text };
  }

  const caption = normalizeBotChatMediaCaption(text, attachments[0]);
  const mediaKind = resolveOpenClawMediaKind(attachments);
  const marker = `<media:${mediaKind}>`;
  const visibleUrls = formatVisibleAttachmentUrls(attachments);
  const visibleText = [caption, visibleUrls].filter(Boolean).join("\n");
  return {
    body: visibleText ? `${marker} ${visibleText}` : marker,
    commandBody: caption,
  };
}

function formatVisibleAttachmentUrls(attachments: BotChatAttachment[]): string {
  const urls = attachments.map((attachment) => attachment.url).filter(Boolean);
  if (urls.length === 0) {
    return "";
  }
  if (urls.length === 1) {
    return `Attachment URL: ${urls[0]}`;
  }
  return ["Attachment URLs:", ...urls.map((url) => `- ${url}`)].join("\n");
}

function normalizeBotChatMediaCaption(
  text: string,
  attachment: BotChatAttachment | undefined,
): string {
  const trimmed = text.trim();
  if (!trimmed) {
    return "";
  }
  const fileName = attachment?.fileName ?? attachment?.name;
  if (fileName && trimmed === fileName.trim()) {
    return "";
  }
  if (trimmed === "Image" && attachment?.kind === "image") {
    return "";
  }
  return trimmed;
}

function resolveOpenClawMediaKind(attachments: BotChatAttachment[]): string {
  const kinds = new Set(
    attachments.map((attachment) => {
      const mimeKind = attachment.mimeType?.split("/", 1)[0]?.trim().toLowerCase();
      const rawKind = attachment.kind.trim().toLowerCase();
      if (mimeKind === "image" || mimeKind === "audio" || mimeKind === "video") {
        return mimeKind;
      }
      if (rawKind === "image" || rawKind === "audio" || rawKind === "video") {
        return rawKind;
      }
      return "file";
    }),
  );
  return kinds.size === 1 ? [...kinds][0] ?? "file" : "mixed";
}

function buildBotChatAttachmentFromAsset(
  asset: Record<string, unknown> | undefined,
  metadata: Record<string, unknown>,
  fallbackName: string,
): BotChatAttachment | undefined {
  const source = asset ?? metadata;
  const url =
    readString(source.download_url) ??
    readString(source.external_url) ??
    readString(source.source_url) ??
    readString(source.url) ??
    readString(metadata.download_url) ??
    readString(metadata.external_url) ??
    readString(metadata.source_url) ??
    readString(metadata.url);
  if (!url) {
    return undefined;
  }

  const kind = readString(source.kind) ?? readString(source.type) ?? readString(metadata.content_type) ?? "file";
  const name =
    readString(source.file_name) ??
    readString(source.name) ??
    readString(source.filename) ??
    readString(metadata.file_name) ??
    readString(metadata.name) ??
    fallbackName;
  const mimeType =
    readString(source.mime_type) ??
    readString(source.mimeType) ??
    readString(source.content_type) ??
    readString(metadata.mime_type) ??
    readString(metadata.mimeType);
  const size = readNumber(source.size) ?? readNumber(metadata.size);

  return {
    type: kind,
    kind,
    url,
    ...(name ? { name, fileName: name } : {}),
    ...(mimeType ? { mimeType, contentType: mimeType } : {}),
    ...(size !== undefined ? { size } : {}),
    ...(asset ? { asset } : {}),
  };
}

function buildBotChatReplyMetadata(
  metadata: Record<string, unknown> | undefined,
): Record<string, unknown> {
  const {
    message_id: inboundMessageId,
    messageId: _messageId,
    seq: _seq,
    senderType: _senderType,
    ...replyMetadata
  } = metadata ?? {};
  const existingReplyToId =
    typeof replyMetadata.replyToId === "string" ? replyMetadata.replyToId.trim() : "";
  const sourceMessageId = typeof inboundMessageId === "string" ? inboundMessageId.trim() : "";
  const replyToId = existingReplyToId || sourceMessageId;
  return {
    ...replyMetadata,
    ...(replyToId ? { replyToId } : {}),
  };
}

async function prepareBotChatReplyDelivery(
  text: string,
  account: ResolvedBotChatAccount,
  metadata: Record<string, unknown>,
  log?: {
    warn?(message: string, fields?: Record<string, unknown>): void;
  },
): Promise<{ text: string; metadata: Record<string, unknown> }> {
  const directive = extractBotChatMediaDirective(text);
  if (!directive) {
    return { text, metadata };
  }

  try {
    const mediaAsset = await prepareBotChatOutboundMediaAsset(account, directive.mediaPath);
    const body = directive.body || readString(mediaAsset.file_name) || "Image";
    return {
      text: body,
      metadata: {
        ...metadata,
        content_type: "image",
        asset: mediaAsset,
      },
    };
  } catch (error) {
    log?.warn?.("botchat.reply.media_directive_failed", {
      mediaPath: directive.mediaPath,
      error: error instanceof Error ? error.message : String(error),
    });
    return { text, metadata };
  }
}

async function publishBotChatSlashCommands(params: {
  cfg: Record<string, unknown>;
  account: ResolvedBotChatAccount;
  log?: {
    info?(message: string, fields?: Record<string, unknown>): void;
    warn?(message: string, fields?: Record<string, unknown>): void;
    debug?(message: string, fields?: Record<string, unknown>): void;
  };
}): Promise<void> {
  const commands = await resolveOpenClawNativeCommands(params.cfg, params.log);
  if (!commands) {
    params.log?.warn?.("botchat.slash_commands.unavailable");
    return;
  }
  params.log?.info?.("botchat.slash_commands.resolved", {
    count: commands.length,
  });

  try {
    await getBotChatRuntime().sendToChannel({
      channelId: BOT_CHAT_SLASH_COMMAND_TOPIC,
      userId: "*",
      text: "slash_commands",
      metadata: {
        topic: BOT_CHAT_SLASH_COMMAND_TOPIC,
        botId: params.account.botId,
        toType: "user",
        content_type: "slash_commands",
        slash_commands: commands,
        retain: true,
      },
    });
    params.log?.info?.("botchat.slash_commands.published", {
      count: commands.length,
      topic: BOT_CHAT_SLASH_COMMAND_TOPIC,
    });
  } catch (error) {
    params.log?.warn?.("botchat.slash_commands.publish_error", {
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

async function handleBotChatSlashAutocompleteRequest(params: {
  cfg: Record<string, unknown>;
  account: ResolvedBotChatAccount;
  message: {
    channelId: string;
    userId: string;
    text: string;
    metadata?: Record<string, unknown>;
  };
  log?: {
    warn?(message: string, fields?: Record<string, unknown>): void;
    debug?(message: string, fields?: Record<string, unknown>): void;
  };
}): Promise<boolean> {
  const request = parseBotChatSlashAutocompleteRequest(params.message);
  if (!request) {
    return false;
  }

  const choices = await resolveBotChatSlashAutocompleteChoices({
    cfg: params.cfg,
    request,
    log: params.log,
  });
  try {
    await getBotChatRuntime().sendToChannel({
      channelId: request.responseTopic,
      userId: params.message.userId,
      text: "slash_autocomplete_response",
      metadata: {
        topic: request.responseTopic,
        botId: params.account.botId,
        toType: "user",
        content_type: "slash_autocomplete_response",
        request_id: request.requestId,
        command_name: request.commandName,
        ...(request.argName ? { arg_name: request.argName } : {}),
        arg_index: request.argIndex,
        partial: request.partial,
        choices,
      },
    });
  } catch (error) {
    params.log?.warn?.("botchat.slash_autocomplete.publish_error", {
      error: error instanceof Error ? error.message : String(error),
    });
  }
  return true;
}

function parseBotChatSlashAutocompleteRequest(message: {
  channelId: string;
  metadata?: Record<string, unknown>;
}): BotChatSlashAutocompleteRequest | null {
  const metadata = message.metadata ?? {};
  const contentType = readString(metadata.content_type);
  const topic = readString(metadata.topic) ?? message.channelId;
  if (contentType !== "slash_autocomplete_request" && topic !== BOT_CHAT_SLASH_AUTOCOMPLETE_REQUEST_TOPIC) {
    return null;
  }

  const requestId = readString(metadata.request_id ?? metadata.requestId);
  const responseTopic = readString(metadata.response_topic ?? metadata.responseTopic);
  const commandName = readString(metadata.command_name ?? metadata.commandName)?.replace(/^\/+/, "");
  if (!requestId || !responseTopic || !commandName) {
    return null;
  }

  return {
    requestId,
    responseTopic,
    commandName,
    argName: readString(metadata.arg_name ?? metadata.argName),
    argIndex: readNumber(metadata.arg_index ?? metadata.argIndex) ?? 0,
    partial: readString(metadata.partial) ?? "",
  };
}

async function resolveBotChatSlashAutocompleteChoices(params: {
  cfg: Record<string, unknown>;
  request: BotChatSlashAutocompleteRequest;
  log?: { debug?(message: string, fields?: Record<string, unknown>): void };
}): Promise<BotChatSlashCommandChoice[]> {
  const resolvers = botChatSlashCommandResolversForTest ?? (await loadBotChatSlashCommandResolvers(params.log));
  const dynamicChoices = await callBotChatAutocompleteResolver({
    cfg: params.cfg,
    resolvers,
    request: params.request,
    log: params.log,
  });
  const fallbackChoices = await resolveBotChatSlashAutocompleteFromCatalog({
    cfg: params.cfg,
    request: params.request,
    log: params.log,
  });
  return uniqueBotChatSlashCommandChoices(
    [...dynamicChoices, ...fallbackChoices],
    params.request.partial,
  ).slice(0, 12);
}

async function callBotChatAutocompleteResolver(params: {
  cfg: Record<string, unknown>;
  resolvers: BotChatSlashCommandResolvers | null;
  request: BotChatSlashAutocompleteRequest;
  log?: { debug?(message: string, fields?: Record<string, unknown>): void };
}): Promise<BotChatSlashCommandChoice[]> {
  const resolver = params.resolvers?.resolveNativeCommandAutocomplete;
  if (!resolver) {
    return [];
  }

  try {
    const result = await resolver({
      cfg: params.cfg,
      provider: "bot-chat",
      commandName: params.request.commandName,
      argName: params.request.argName,
      argIndex: params.request.argIndex,
      partial: params.request.partial,
    });
    return normalizeBotChatSlashCommandChoices(result);
  } catch (error) {
    params.log?.debug?.("botchat.slash_autocomplete.resolver_failed", {
      error: error instanceof Error ? error.message : String(error),
    });
    return [];
  }
}

async function resolveBotChatSlashAutocompleteFromCatalog(params: {
  cfg: Record<string, unknown>;
  request: BotChatSlashAutocompleteRequest;
  log?: { debug?(message: string, fields?: Record<string, unknown>): void };
}): Promise<BotChatSlashCommandChoice[]> {
  const commands = await resolveOpenClawNativeCommands(params.cfg, params.log);
  const command = commands?.find(
    (item) => item.name.toLowerCase() === params.request.commandName.toLowerCase(),
  );
  const arg = command?.args?.[params.request.argIndex];
  if (!arg) {
    return [];
  }
  return normalizeBotChatSlashCommandChoices((arg as Record<string, unknown>).choices);
}

function normalizeBotChatSlashCommandChoices(raw: unknown): BotChatSlashCommandChoice[] {
  if (!Array.isArray(raw)) {
    return [];
  }

  return raw.flatMap((item): BotChatSlashCommandChoice[] => {
    if (isRecord(item)) {
      const value = readString(item.value ?? item.id ?? item.name ?? item.label);
      const label = readString(item.label ?? item.name ?? item.title) ?? value;
      if (!value) {
        return [];
      }
      return [{
        label: label ?? value,
        value,
        ...(readString(item.description ?? item.summary) ? { description: readString(item.description ?? item.summary) } : {}),
      }];
    }

    const value = readString(item);
    return value ? [{ label: value, value }] : [];
  });
}

function uniqueBotChatSlashCommandChoices(
  choices: BotChatSlashCommandChoice[],
  partial: string,
): BotChatSlashCommandChoice[] {
  const normalizedPartial = partial.trim().toLowerCase();
  const seen = new Set<string>();
  const filtered: BotChatSlashCommandChoice[] = [];
  for (const choice of choices) {
    if (
      normalizedPartial &&
      !choice.label.toLowerCase().includes(normalizedPartial) &&
      !choice.value.toLowerCase().includes(normalizedPartial)
    ) {
      continue;
    }
    const key = choice.value.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    filtered.push(choice);
  }
  return filtered;
}

async function resolveOpenClawNativeCommands(
  cfg: Record<string, unknown>,
  log?: { debug?(message: string, fields?: Record<string, unknown>): void },
): Promise<BotChatSlashCommand[] | null> {
  const resolvers = botChatSlashCommandResolversForTest ?? (await loadBotChatSlashCommandResolvers(log));
  if (!resolvers) {
    return null;
  }

  const commands: BotChatSlashCommand[] = [];
  const seen = new Set<string>();
  const callResolver = <T>(name: string, resolve: () => T): T | undefined => {
    try {
      return resolve();
    } catch (error) {
      log?.debug?.(`botchat.slash_commands.${name}_failed`, {
        error: error instanceof Error ? error.message : String(error),
      });
      return undefined;
    }
  };
  const addCommandSpecs = (specs: unknown) => {
    if (!Array.isArray(specs)) {
      return;
    }

    for (const spec of specs) {
      if (!isRecord(spec)) {
        continue;
      }
      const normalized = normalizeBotChatSlashCommand(spec);
      if (!normalized || seen.has(normalized.name.toLowerCase())) {
        continue;
      }
      seen.add(normalized.name.toLowerCase());
      commands.push(normalized);
    }
  };

  const skillCommands =
    callResolver("skill_registry", () => resolvers.listSkillCommandsForAgents?.({ cfg })) ?? [];
  addCommandSpecs(
    callResolver("native_registry", () =>
      resolvers.listNativeCommandSpecsForConfig?.(cfg, {
        skillCommands,
        provider: "bot-chat",
      }),
    ),
  );
  addCommandSpecs(skillCommands);
  addCommandSpecs(
    callResolver("plugin_registry", () =>
      resolvers.getPluginCommandSpecs?.("bot-chat", { config: cfg }),
    ),
  );

  return commands;
}

async function loadBotChatSlashCommandResolvers(
  log?: { debug?(message: string, fields?: Record<string, unknown>): void },
): Promise<BotChatSlashCommandResolvers | null> {
  const resolvers: BotChatSlashCommandResolvers = {};

  try {
    const nativeRegistry = await importOpenClawSdkModule<BotChatNativeCommandRegistryModule>(
      "openclaw/plugin-sdk/native-command-registry",
    );
    resolvers.listNativeCommandSpecsForConfig = nativeRegistry.listNativeCommandSpecsForConfig;
  } catch (error) {
    log?.debug?.("botchat.slash_commands.native_registry_unavailable", {
      error: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const skillCommands = await importOpenClawSdkModule<BotChatSkillCommandRuntimeModule>(
      "openclaw/plugin-sdk/skill-commands-runtime",
    );
    resolvers.listSkillCommandsForAgents = skillCommands.listSkillCommandsForAgents;
  } catch (error) {
    log?.debug?.("botchat.slash_commands.skill_commands_unavailable", {
      error: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const commandAuth = await importOpenClawSdkModule<BotChatNativeCommandRegistryModule>(
      "openclaw/plugin-sdk/command-auth-native",
    );
    resolvers.listNativeCommandSpecsForConfig ??= commandAuth.listNativeCommandSpecsForConfig;
  } catch (error) {
    log?.debug?.("botchat.slash_commands.command_auth_unavailable", {
      error: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const autocomplete = await importOpenClawSdkModule<BotChatCommandAutocompleteModule>(
      "openclaw/plugin-sdk/command-autocomplete-native",
    );
    resolvers.resolveNativeCommandAutocomplete =
      autocomplete.resolveNativeCommandAutocomplete ?? autocomplete.listNativeCommandAutocompleteChoices;
  } catch (error) {
    log?.debug?.("botchat.slash_commands.command_autocomplete_unavailable", {
      error: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const pluginRuntime = await importOpenClawSdkModule<BotChatPluginRuntimeModule>(
      "openclaw/plugin-sdk/plugin-runtime",
    );
    resolvers.getPluginCommandSpecs = pluginRuntime.getPluginCommandSpecs;
  } catch (error) {
    log?.debug?.("botchat.slash_commands.plugin_runtime_unavailable", {
      error: error instanceof Error ? error.message : String(error),
    });
  }

  return Object.values(resolvers).some((resolver) => typeof resolver === "function") ? resolvers : null;
}

async function importOpenClawSdkModule<T extends Record<string, unknown>>(specifier: string): Promise<T> {
  try {
    return (await import(specifier)) as T;
  } catch (primaryError) {
    const resolved = resolveOpenClawSdkSpecifierFromHost(specifier);
    if (!resolved) {
      throw primaryError;
    }
    return (await import(pathToFileURL(resolved).href)) as T;
  }
}

function resolveOpenClawSdkSpecifierFromHost(specifier: string): string | undefined {
  const candidates = [
    typeof process.argv[1] === "string" ? process.argv[1] : undefined,
    process.env.OPENCLAW_CLI_ENTRYPOINT,
  ].filter((item): item is string => typeof item === "string" && path.isAbsolute(item));

  for (const candidate of candidates) {
    try {
      return createRequire(candidate).resolve(specifier);
    } catch {
      continue;
    }
  }
  return undefined;
}

function normalizeBotChatSlashCommand(spec: Record<string, unknown>): BotChatSlashCommand | null {
  const name = readString(spec.name ?? spec.nativeName ?? spec.command);
  if (!name) {
    return null;
  }

  return {
    name: name.replace(/^\/+/, ""),
    description: readString(spec.description ?? spec.summary) ?? "",
    acceptsArgs: spec.acceptsArgs === true || Array.isArray(spec.args) || Array.isArray(spec.options),
    args: Array.isArray(spec.args)
      ? spec.args.filter(isRecord)
      : Array.isArray(spec.options)
        ? spec.options.filter(isRecord)
        : undefined,
  };
}

function resolveBotChatCommandSource(message: {
  text: string;
  metadata?: Record<string, unknown>;
}): "native" | "text" {
  const metadata = message.metadata ?? {};
  const source = readString(metadata.command_source ?? metadata.commandSource);
  if (source === "native" || metadata.native_command === true || metadata.nativeCommand === true) {
    return "native";
  }
  return "text";
}

function extractBotChatMediaDirective(text: string): { mediaPath: string; body: string } | undefined {
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trimEnd());
  const directiveIndex = lines.findIndex((line) => line.trimStart().startsWith("MEDIA:"));
  if (directiveIndex < 0) {
    return undefined;
  }

  const directiveLine = lines[directiveIndex]?.trim();
  const mediaPath = directiveLine?.slice("MEDIA:".length).trim();
  if (!mediaPath) {
    return undefined;
  }

  const body = lines
    .filter((_line, index) => index !== directiveIndex)
    .join("\n")
    .trim();
  return { mediaPath, body };
}

async function buildBotChatMediaAsset(mediaPath: string): Promise<Record<string, unknown>> {
  const fileName = readFileNameFromMediaPath(mediaPath);
  const mimeType = resolveBotChatMediaMimeType(mediaPath);
  const sourceUrl = isWebResolvableUrl(mediaPath)
    ? mediaPath
    : await buildDataUrlFromFile(mediaPath, mimeType);

  return {
    kind: "image",
    type: "image",
    source_url: sourceUrl,
    ...(fileName ? { file_name: fileName } : {}),
    ...(mimeType ? { content_type: mimeType, mime_type: mimeType } : {}),
  };
}

async function prepareBotChatOutboundMediaAsset(
  account: ResolvedBotChatAccount,
  mediaPath: string,
): Promise<Record<string, unknown>> {
  if (isWebResolvableUrl(mediaPath)) {
    return buildBotChatMediaAsset(mediaPath);
  }

  return importBotChatMediaAsset(account, mediaPath);
}

async function importBotChatMediaAsset(
  account: ResolvedBotChatAccount,
  mediaPath: string,
): Promise<Record<string, unknown>> {
  const backendUrl = readString(account.backendUrl);
  const botKey = readString(account.config?.botKey);
  if (!backendUrl || !botKey) {
    throw new Error("BotChat backendUrl and botKey are required to import local media");
  }

  const mimeType = resolveBotChatMediaMimeType(mediaPath);
  const dataUrl = await buildDataUrlFromFile(mediaPath, mimeType);
  const fileName = readFileNameFromMediaPath(mediaPath);
  const response = await fetch(`${backendUrl.replace(/\/+$/, "")}/api/v1/bot-runtime/assets/image/import`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-Bot-Key": botKey,
    },
    body: JSON.stringify({
      data_url: dataUrl,
      file_name: fileName,
      content_type: mimeType,
    }),
  });

  if (!response.ok) {
    throw new Error(`bot media import failed: ${response.status}`);
  }

  const json = (await response.json()) as { data?: Record<string, unknown> };
  const imported = readRecord(json.data);
  if (!imported) {
    throw new Error("bot media import returned no asset payload");
  }
  return imported;
}

function isWebResolvableUrl(value: string): boolean {
  return /^(https?:|data:)/i.test(value);
}

async function buildDataUrlFromFile(filePath: string, mimeType: string): Promise<string> {
  const contents = await fs.readFile(filePath);
  return `data:${mimeType};base64,${contents.toString("base64")}`;
}

function readFileNameFromMediaPath(mediaPath: string): string | undefined {
  if (!mediaPath) {
    return undefined;
  }

  if (isWebResolvableUrl(mediaPath)) {
    try {
      const url = new URL(mediaPath);
      const baseName = path.basename(url.pathname);
      return baseName || undefined;
    } catch {
      return undefined;
    }
  }

  const baseName = path.basename(mediaPath);
  return baseName || undefined;
}

function resolveBotChatMediaMimeType(mediaPath: string): string {
  const extension = path.extname(mediaPath).trim().toLowerCase();
  switch (extension) {
    case ".apng":
      return "image/apng";
    case ".avif":
      return "image/avif";
    case ".gif":
      return "image/gif";
    case ".jpeg":
    case ".jpg":
      return "image/jpeg";
    case ".png":
      return "image/png";
    case ".svg":
      return "image/svg+xml";
    case ".webp":
      return "image/webp";
    default:
      return "application/octet-stream";
  }
}

async function waitForAbort(signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) {
    return;
  }
  if (!signal) {
    return;
  }
  await new Promise<void>((resolve) => {
    signal.addEventListener("abort", () => resolve(), { once: true });
  });
}

function readRecord(value: unknown): Record<string, unknown> | undefined {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
