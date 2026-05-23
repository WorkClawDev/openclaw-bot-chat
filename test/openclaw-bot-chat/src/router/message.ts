import { randomUUID } from "node:crypto";

import type { BotConfig } from "../config";
import type { ChannelContext } from "../types/channel";
import {
  checkPermission,
  type ActionPermissions,
  type PermissionCheck,
} from "../types/permissions";
import type {
  OpenClawAttachment,
  BotChatMessage,
  BotChatOutgoingMessage,
  OpenClawRequest,
  OpenClawResponse,
} from "../types";

type JsonRecord = Record<string, unknown>;

interface RouteInfo {
  fromType?: string;
  fromId?: string;
  toType?: string;
  toId?: string;
  groupId?: string;
  channelId?: string;
  guildId?: string;
}

export interface IncomingMessageRoute {
  action: keyof ActionPermissions;
  channel: ChannelContext;
  permission: PermissionCheck;
}

export function normalizeBotChatMessage(
  raw: unknown,
  fallbackTopic?: string,
): BotChatMessage | null {
  if (!isRecord(raw)) {
    return null;
  }

  const from = readRecord(raw["from"]);
  const content = readRecord(raw["content"]);
  const dialogId =
    readString(raw["dialog_id"]) ??
    readString(raw["conversation_id"]) ??
    readString(raw["mqtt_topic"]) ??
    fallbackTopic ??
    deriveDialogId(from, readRecord(raw["to"]));

  if (!dialogId) {
    return null;
  }

  const route = parseRoute(dialogId);
  const fromType = normalizeSenderType(
    readString(raw["from_type"]) ??
      readString(raw["sender_type"]) ??
      readString(from?.["type"]),
  );

  const fromId =
    readString(raw["from_id"]) ??
    readString(raw["sender_id"]) ??
    readString(from?.["id"]) ??
    readString(raw["bot_id"]);

  if (!fromId) {
    return null;
  }

  const to = readRecord(raw["to"]);
  const toType = normalizeRecipientType(
    readString(raw["to_type"]) ?? readString(to?.["type"]),
  );
  let toId = readString(raw["to_id"]) ?? readString(to?.["id"]);
  let normalizedToType = toType;

  if (
    (!normalizedToType || !toId) &&
    route.fromType &&
    route.fromId &&
    route.toType &&
    route.toId
  ) {
    if (route.fromType === fromType && route.fromId === fromId) {
      normalizedToType =
        normalizedToType ?? normalizeRecipientType(route.toType);
      toId = toId ?? route.toId;
    } else if (route.toType === fromType && route.toId === fromId) {
      normalizedToType =
        normalizedToType ?? normalizeRecipientType(route.fromType);
      toId = toId ?? route.fromId;
    }
  }

  const contentType = normalizeContentType(
    readString(raw["content_type"]) ??
      readString(raw["msg_type"]) ??
      readString(content?.["type"]),
  );
  const body =
    readString(raw["body"]) ??
    readString(content?.["body"]) ??
    readString(raw["content"]);

  if (!body) {
    return null;
  }

  const timestamp =
    readTimestamp(raw["timestamp"]) ??
    readTimestamp(raw["created_at"]) ??
    Math.floor(Date.now() / 1000);

  const seq = readNumber(raw["seq"]);
  const meta = mergeMeta(
    readRecord(raw["meta"]),
    readRecord(raw["metadata"]),
    readRecord(content?.["meta"]),
    fallbackTopic ? { topic: fallbackTopic } : undefined,
    buildReplyTopic(dialogId)
      ? { reply_topic: buildReplyTopic(dialogId) }
      : undefined,
    readString(raw["channel_id"])
      ? { channel_id: readString(raw["channel_id"]) }
      : undefined,
    readString(raw["channel_name"])
      ? { channel_name: readString(raw["channel_name"]) }
      : undefined,
    readString(raw["guild_id"])
      ? { guild_id: readString(raw["guild_id"]) }
      : undefined,
    readString(raw["group_id"])
      ? { group_id: readString(raw["group_id"]) }
      : undefined,
    readString(raw["group_name"])
      ? { group_name: readString(raw["group_name"]) }
      : undefined,
    readString(raw["user_id"])
      ? { user_id: readString(raw["user_id"]) }
      : undefined,
    readString(raw["user_name"])
      ? { user_name: readString(raw["user_name"]) }
      : undefined,
    readString(raw["from_name"])
      ? { from_name: readString(raw["from_name"]) }
      : undefined,
  );

  const message: BotChatMessage = {
    message_id:
      readString(raw["message_id"]) ?? readString(raw["id"]) ?? randomUUID(),
    dialog_id: dialogId,
    from_type: fromType,
    from_id: fromId,
    content_type: contentType,
    body,
    timestamp,
    ...(meta ? { meta } : {}),
    ...(seq !== undefined ? { seq } : {}),
    ...(normalizedToType ? { to_type: normalizedToType } : {}),
    ...(toId ? { to_id: toId } : {}),
  };

  return message;
}

export function shouldProcessMessage(
  message: BotChatMessage,
  botId: string,
): boolean {
  if (message.from_type !== "user") {
    return false;
  }
  if (message.from_id === botId) {
    return false;
  }
  if (message.to_type === "bot" && message.to_id && message.to_id !== botId) {
    return false;
  }
  if (isGroupMessage(message)) {
    return isMessageMentionedForBot(message, botId);
  }
  return true;
}

export function toOpenClawRequest(
  message: BotChatMessage,
  sessionId: string,
  channel?: ChannelContext,
): OpenClawRequest {
  const normalizedContent = readNormalizedBody(message);
  const attachments = buildOpenClawAttachments(message);
  const mentionedCurrentBot = channel?.botId
    ? isMessageMentionedForBot(message, channel.botId)
    : undefined;

  return {
    session_id: sessionId,
    content: normalizedContent,
    ...(attachments.length > 0 ? { attachments } : {}),
    metadata: {
      dialog_id: message.dialog_id,
      message_id: message.message_id,
      original_content: message.body,
      ...(normalizedContent !== message.body
        ? { normalized_content: normalizedContent }
        : {}),
      from_type: message.from_type,
      from_id: message.from_id,
      ...(message.to_type ? { to_type: message.to_type } : {}),
      ...(message.to_id ? { to_id: message.to_id } : {}),
      content_type: message.content_type,
      timestamp: message.timestamp,
      ...(message.seq !== undefined ? { seq: message.seq } : {}),
      ...(message.meta ? { message_meta: message.meta } : {}),
      ...(attachments.length > 0 ? { attachments, media: attachments } : {}),
      ...(mentionedCurrentBot !== undefined
        ? { mentioned_current_bot: mentionedCurrentBot }
        : {}),
      ...(channel
        ? {
            channel_context: {
              id: channel.id,
              type: channel.type,
              botId: channel.botId,
              ...(channel.userId ? { userId: channel.userId } : {}),
              ...(channel.guildId ? { guildId: channel.guildId } : {}),
              ...(channel.groupId ? { groupId: channel.groupId } : {}),
            },
          }
        : {}),
    },
  };
}

export function toBotChatOutgoingMessage(
  response: OpenClawResponse,
  sourceMessage: BotChatMessage,
  botId: string,
): BotChatOutgoingMessage | null {
  const contentType = normalizeContentType(
    readString(response.metadata?.["content_type"]),
  );
  const body = normalizeOutgoingBody(response, contentType);
  if (!body) {
    return null;
  }
  const topic =
    readString(response.metadata?.["topic"]) ??
    readString(sourceMessage.meta?.["reply_topic"]) ??
    buildReplyTopic(sourceMessage.dialog_id, botId) ??
    sourceMessage.dialog_id;

  const meta = mergeMeta(response.metadata, sourceMessage.meta, normalizeOutgoingAssetMeta(response, contentType), {
    in_reply_to_message_id: sourceMessage.message_id,
    source_dialog_id: sourceMessage.dialog_id,
  });

  return {
    message_id: randomUUID(),
    topic,
    conversation_id: sourceMessage.dialog_id,
    from_type: "bot",
    from_id: botId,
    to_type: sourceMessage.from_type,
    to_id: sourceMessage.from_id,
    content_type: contentType,
    body,
    ...(meta ? { meta } : {}),
    timestamp: Math.floor(Date.now() / 1000),
  };
}

export function toRealtimePublishPayload(
  outgoing: BotChatOutgoingMessage,
  sourceMessage: BotChatMessage,
  botId: string,
): { topic: string; payload: Record<string, unknown> } {
  const topic =
    outgoing.topic ??
    readString(sourceMessage.meta?.["reply_topic"]) ??
    buildReplyTopic(sourceMessage.dialog_id, botId) ??
    sourceMessage.dialog_id;

  return {
    topic,
    payload: {
      id: outgoing.message_id,
      topic,
      conversation_id: outgoing.conversation_id,
      from: {
        type: outgoing.from_type ?? "bot",
        id: outgoing.from_id ?? botId,
      },
      to: {
        type: outgoing.to_type ?? sourceMessage.from_type,
        id: outgoing.to_id ?? sourceMessage.from_id,
      },
      content: {
        type: outgoing.content_type,
        body: outgoing.body,
        ...(outgoing.meta ? { meta: outgoing.meta } : {}),
      },
      timestamp: outgoing.timestamp,
    },
  };
}

export function routeIncomingMessage(
  message: BotChatMessage,
  botId: string,
  config: BotConfig,
): IncomingMessageRoute {
  const channel = resolveChannelContext(message, botId);
  const channelName =
    readString(message.meta?.["channel_name"]) ??
    readString(message.meta?.["group_name"]);
  const userName =
    readString(message.meta?.["user_name"]) ??
    readString(message.meta?.["from_name"]);
  const permission = checkPermission(
    "sendMessage",
    {
      botId,
      userId: message.from_id,
      channelId: channel.id,
      channelType: channel.type,
      ...(channelName ? { channelName } : {}),
      ...(userName ? { userName } : {}),
    },
    {
      ...config,
      ...(config.id ? {} : { id: botId }),
    },
  );

  return {
    action: "sendMessage",
    channel,
    permission,
  };
}

export function resolveChannelContext(
  message: BotChatMessage,
  botId: string,
): ChannelContext {
  return resolveChannelContextFromDialog(
    message.dialog_id,
    botId,
    message.meta,
    message.from_id,
  );
}

export function resolveChannelContextFromDialog(
  dialogId: string,
  botId: string,
  metadata?: Record<string, unknown>,
  fallbackUserId?: string,
): ChannelContext {
  const route = parseRoute(readString(metadata?.["topic"]) ?? dialogId);
  const groupId = readString(metadata?.["group_id"]) ?? route.groupId;
  if (groupId) {
    return {
      id: groupId,
      type: "group",
      botId,
      groupId,
    };
  }

  const guildId = readString(metadata?.["guild_id"]) ?? route.guildId;
  const channelId = readString(metadata?.["channel_id"]) ?? route.channelId;
  if (channelId || guildId) {
    const id = channelId ?? dialogId;
    return {
      id,
      type: "channel",
      botId,
      ...(guildId ? { guildId } : {}),
    };
  }

  const userId =
    readString(metadata?.["user_id"]) ??
    (route.fromType === "user" ? route.fromId : undefined) ??
    (route.toType === "user" ? route.toId : undefined) ??
    fallbackUserId;

  if (userId) {
    return {
      id: userId,
      type: "dm",
      botId,
      userId,
    };
  }

  return {
    id: dialogId,
    type: "channel",
    botId,
  };
}

export function buildReplyTopic(
  dialogId: string,
  botId?: string,
): string | undefined {
  const route = parseRoute(dialogId);
  if (route.groupId) {
    return `chat/group/${route.groupId}`;
  }

  if (route.fromType && route.fromId && route.toType && route.toId) {
    return canonicalDirectDialogId(
      route.fromType,
      route.fromId,
      route.toType,
      route.toId,
    );
  }

  return undefined;
}

function deriveDialogId(
  from?: JsonRecord,
  to?: JsonRecord,
): string | undefined {
  const fromType = readString(from?.["type"]);
  const fromId = readString(from?.["id"]);
  const toType = readString(to?.["type"]);
  const toId = readString(to?.["id"]);

  if (toType === "group" && toId) {
    return `chat/group/${toId}`;
  }

  if (fromType && fromId && toType && toId) {
    return canonicalDirectDialogId(fromType, fromId, toType, toId);
  }

  return undefined;
}

function isGroupMessage(message: BotChatMessage): boolean {
  if (message.to_type === "group") {
    return true;
  }
  if (readString(message.meta?.["group_id"])) {
    return true;
  }
  return Boolean(
    parseRoute(readString(message.meta?.["topic"]) ?? message.dialog_id)
      .groupId,
  );
}

function getMentionedBotIds(message: BotChatMessage): string[] {
  const mentioned = new Set<string>();
  const raw = message.meta?.["mentioned_bot_ids"];
  if (Array.isArray(raw)) {
    for (const item of raw) {
      if (typeof item === "string" && item.length > 0) {
        mentioned.add(item);
      }
    }
  }

  const normalizedBody = readString(message.meta?.["normalized_body"]);
  if (normalizedBody) {
    const matches = normalizedBody.matchAll(/<@bot:([^>]+)>/g);
    for (const match of matches) {
      if (match[1]) {
        mentioned.add(match[1]);
      }
    }
  }

  return [...mentioned];
}

function isMessageMentionedForBot(
  message: BotChatMessage,
  botId: string,
): boolean {
  return getMentionedBotIds(message).includes(botId);
}

function readNormalizedBody(message: BotChatMessage): string {
  const normalized = readString(message.meta?.["normalized_body"]);
  return normalized ?? message.body;
}

function buildOpenClawAttachments(message: BotChatMessage): OpenClawAttachment[] {
  const metadata = message.meta ?? {};
  const messageMeta = readRecord(metadata["message_meta"]);
  const asset =
    readRecord(metadata["asset"]) ??
    readRecord(messageMeta?.["asset"]) ??
    readRecord(metadata["attachment"]);
  const attachment = buildOpenClawAttachmentFromAsset(asset, metadata, message.body);
  return attachment ? [attachment] : [];
}

function buildOpenClawAttachmentFromAsset(
  asset: JsonRecord | undefined,
  metadata: JsonRecord,
  fallbackName: string,
): OpenClawAttachment | undefined {
  const source = asset ?? metadata;
  const url =
    readString(source["download_url"]) ??
    readString(source["external_url"]) ??
    readString(source["source_url"]) ??
    readString(source["url"]) ??
    readString(metadata["download_url"]) ??
    readString(metadata["external_url"]) ??
    readString(metadata["source_url"]) ??
    readString(metadata["url"]);
  if (!url) {
    return undefined;
  }

  const kind =
    readString(source["kind"]) ??
    readString(source["type"]) ??
    messageContentKind(metadata) ??
    "file";
  const name =
    readString(source["file_name"]) ??
    readString(source["name"]) ??
    readString(source["filename"]) ??
    readString(metadata["file_name"]) ??
    readString(metadata["name"]) ??
    fallbackName;
  const mimeType =
    readString(source["mime_type"]) ??
    readString(source["mimeType"]) ??
    readString(source["content_type"]) ??
    readString(metadata["mime_type"]) ??
    readString(metadata["mimeType"]);
  const size = readNumber(source["size"]) ?? readNumber(metadata["size"]);

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

function messageContentKind(metadata: JsonRecord): string | undefined {
  const contentType = readString(metadata["content_type"]);
  if (!contentType) {
    return undefined;
  }
  return contentType === "text" ? undefined : contentType;
}

function normalizeOutgoingBody(
  response: OpenClawResponse,
  contentType: BotChatOutgoingMessage["content_type"],
): string {
  const direct = response.content.trim();
  if (direct) {
    return direct;
  }

  if (contentType !== "image") {
    return "";
  }

  const asset = readRecord(response.metadata?.["asset"]);
  return (
    readString(response.metadata?.["caption"]) ??
    readString(asset?.["file_name"]) ??
    "Image"
  );
}

function normalizeOutgoingAssetMeta(
  response: OpenClawResponse,
  contentType: BotChatOutgoingMessage["content_type"],
): Record<string, unknown> | undefined {
  if (contentType !== "image") {
    return undefined;
  }

  const existingAsset = readRecord(response.metadata?.["asset"]);
  if (existingAsset) {
    return { asset: existingAsset };
  }

  const sourceUrl =
    readString(response.metadata?.["asset_url"]) ??
    readString(response.metadata?.["source_url"]) ??
    readString(response.metadata?.["url"]);
  if (!sourceUrl) {
    return undefined;
  }

  return {
    asset: {
      source_url: sourceUrl,
      file_name: readString(response.metadata?.["file_name"]),
    },
  };
}

function parseRoute(dialogId?: string): RouteInfo {
  if (!dialogId) {
    return {};
  }

  const parts = dialogId.split("/");
  if (parts.length === 3 && parts[0] === "chat" && parts[1] === "group") {
    return parts[2] ? { groupId: parts[2] } : {};
  }
  if (parts.length === 3 && parts[0] === "chat" && parts[1] === "channel") {
    return parts[2] ? { channelId: parts[2] } : {};
  }
  if (
    parts.length === 5 &&
    parts[0] === "chat" &&
    parts[1] === "guild" &&
    parts[3] === "channel"
  ) {
    return {
      ...(parts[2] ? { guildId: parts[2] } : {}),
      ...(parts[4] ? { channelId: parts[4] } : {}),
    };
  }

  if (parts.length === 6 && parts[0] === "chat" && parts[1] === "dm") {
    const route: RouteInfo = {};
    if (parts[2]) {
      route.fromType = parts[2];
    }
    if (parts[3]) {
      route.fromId = parts[3];
    }
    if (parts[4]) {
      route.toType = parts[4];
    }
    if (parts[5]) {
      route.toId = parts[5];
    }
    if (route.fromType === "channel" && route.fromId) {
      route.channelId = route.fromId;
    }
    if (!route.channelId && route.toType === "channel" && route.toId) {
      route.channelId = route.toId;
    }
    return route;
  }

  return {};
}

function canonicalDirectDialogId(
  leftType: string,
  leftId: string,
  rightType: string,
  rightId: string,
): string {
  const [left, right] = canonicalizeDirectPeers(
    { type: leftType, id: leftId },
    { type: rightType, id: rightId },
  );
  return `chat/dm/${left.type}/${left.id}/${right.type}/${right.id}`;
}

function canonicalizeDirectPeers(
  left: { type: string; id: string },
  right: { type: string; id: string },
): [{ type: string; id: string }, { type: string; id: string }] {
  const leftRank = directPeerRank(left.type);
  const rightRank = directPeerRank(right.type);

  if (leftRank !== rightRank) {
    return leftRank < rightRank ? [left, right] : [right, left];
  }

  return left.id <= right.id ? [left, right] : [right, left];
}

function directPeerRank(kind: string): number {
  switch (kind) {
    case "user":
      return 0;
    case "bot":
      return 1;
    case "channel":
      return 2;
    case "system":
      return 3;
    default:
      return 4;
  }
}

function mergeMeta(
  ...values: Array<Record<string, unknown> | undefined>
): Record<string, unknown> | undefined {
  const merged: Record<string, unknown> = {};

  for (const value of values) {
    if (!value) {
      continue;
    }
    for (const [key, item] of Object.entries(value)) {
      merged[key] = item;
    }
  }

  return Object.keys(merged).length > 0 ? merged : undefined;
}

function readRecord(value: unknown): JsonRecord | undefined {
  return isRecord(value) ? value : undefined;
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function readNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

function readTimestamp(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    const normalized = Math.trunc(value);
    return normalized >= 1_000_000_000_000
      ? Math.trunc(normalized / 1000)
      : normalized;
  }
  if (typeof value === "string" && value.trim()) {
    const numeric = Number.parseInt(value, 10);
    if (Number.isFinite(numeric)) {
      return numeric >= 1_000_000_000_000
        ? Math.trunc(numeric / 1000)
        : numeric;
    }
    const date = Date.parse(value);
    if (Number.isFinite(date)) {
      return Math.trunc(date / 1000);
    }
  }
  return undefined;
}

function normalizeSenderType(value?: string): BotChatMessage["from_type"] {
  switch (value) {
    case "bot":
    case "system":
      return value;
    default:
      return "user";
  }
}

function normalizeRecipientType(
  value?: string,
): BotChatMessage["to_type"] | undefined {
  switch (value) {
    case "user":
    case "bot":
    case "system":
    case "group":
    case "channel":
      return value;
    default:
      return undefined;
  }
}

function normalizeContentType(value?: string): BotChatMessage["content_type"] {
  switch (value) {
    case "image":
    case "file":
      return value;
    default:
      return "text";
  }
}

function isRecord(value: unknown): value is JsonRecord {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
