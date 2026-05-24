import type {
  Bot,
  ChatPeer,
  ChatPeerType,
  Conversation,
  ConversationApiResponse,
  ConversationTarget,
  Group,
  Message,
  MessageApiResponse,
  MessageContent,
  MessageContent as ChatMessageContent,
  RealtimeMessagePayload,
  User,
} from './types'
import { createClientId } from './id'

type DirectRoute = {
  kind: 'direct'
  leftType: string
  leftId: string
  rightType: string
  rightId: string
}

type GroupRoute = {
  kind: 'group'
  groupId: string
}

type UnknownRoute = {
  kind: 'unknown'
}

export type ChatRoute = DirectRoute | GroupRoute | UnknownRoute

export function parseChatTopic(topic: string): ChatRoute {
  const parts = topic.split('/')
  if (parts.length === 3 && parts[0] === 'chat' && parts[1] === 'group') {
    return {
      kind: 'group',
      groupId: parts[2],
    }
  }
  if (parts.length === 6 && parts[0] === 'chat' && parts[1] === 'dm') {
    return {
      kind: 'direct',
      leftType: parts[2],
      leftId: parts[3],
      rightType: parts[4],
      rightId: parts[5],
    }
  }
  return { kind: 'unknown' }
}

export function normalizeApiMessage(raw: MessageApiResponse, conversationId?: string): Message {
  const topic = raw.mqtt_topic || raw.conversation_id
  const route = parseChatTopic(topic)
  const from = raw.from || {
    type: raw.sender_type || 'system',
    id: raw.sender_id || '',
  }
  const to =
    raw.to ||
    (route.kind === 'group'
      ? { type: 'group', id: route.groupId }
      : route.kind === 'direct'
        ? { type: route.rightType as 'bot' | 'user', id: route.rightId }
        : { type: 'system', id: '' })

  return {
    id: raw.id,
    db_id: raw.db_id,
    conversation_id: conversationId || topic,
    topic,
    sender_id: raw.sender_id || from.id,
    sender_type: (raw.sender_type || from.type) as Message['sender_type'],
    from,
    to,
    content: normalizeMessageContent(raw.content),
    seq: raw.seq,
    timestamp: raw.timestamp,
    created_at: raw.created_at || timestampToIso(raw.timestamp),
  }
}

export function normalizeRealtimeMessage(payload: RealtimeMessagePayload, fallbackTopic: string): Message {
  const topic = payload.topic || fallbackTopic
  const route = parseChatTopic(topic)
  const from: ChatPeer = payload.from
    ? { ...payload.from, type: payload.from.type as ChatPeerType }
    : {
        type: (route.kind === 'direct' ? route.leftType : 'system') as ChatPeerType,
        id: route.kind === 'direct' ? route.leftId : '',
      }
  const to: ChatPeer =
    payload.to
      ? { ...payload.to, type: payload.to.type as ChatPeerType }
      : route.kind === 'group'
        ? { type: 'group', id: route.groupId }
        : route.kind === 'direct'
          ? { type: route.rightType as ChatPeerType, id: route.rightId }
          : { type: 'system', id: '' }
  const conversationId = payload.conversation_id || topic
  return {
    id: payload.id || createClientId(),
    conversation_id: conversationId,
    topic,
    sender_id: from.id,
    sender_type: from.type as Message['sender_type'],
    from,
    to,
    content: normalizeMessageContent(payload.content),
    seq: payload.seq,
    timestamp: payload.timestamp,
    created_at: payload.created_at || timestampToIso(payload.timestamp),
  }
}

export function enrichMessagePeers(
  message: Message,
  options: {
    currentUser?: User | null
    bots?: Bot[]
    groups?: Group[]
  },
): Message {
  return {
    ...message,
    from: enrichPeer(message.from, options),
    to: enrichPeer(message.to, options),
  }
}

export function createBotDraftConversation(userId: string, bot: Bot): Conversation {
  const sendTopic = buildDirectTopic('user', userId, 'bot', bot.id)
  return {
    id: sendTopic,
    type: 'bot',
    name: bot.name,
    avatar: bot.avatar || bot.avatar_url || null,
    participants: [userId, bot.id],
    topics: [sendTopic],
    send_topic: sendTopic,
    target: { type: 'bot', id: bot.id },
  }
}

export function createGroupDraftConversation(group: Group): Conversation {
  const topic = buildGroupTopic(group.id)
  return {
    id: topic,
    type: 'group',
    name: group.name,
    avatar: group.avatar || group.avatar_url || null,
    participants: [group.id],
    topics: [topic],
    send_topic: topic,
    target: { type: 'group', id: group.id },
  }
}

export function normalizeConversations(
  rawConversations: ConversationApiResponse[],
  currentUserId: string,
  bots: Bot[],
  groups: Group[],
): Conversation[] {
  const merged = new Map<string, Conversation>()

  for (const rawConversation of rawConversations) {
    const topic = rawConversation.conversation_id
    const route = parseChatTopic(topic)
    const conversation = buildConversationFromRoute(route, currentUserId, bots, groups)
    if (!conversation) {
      continue
    }

    const normalizedMessage: Message | undefined = rawConversation.last_message
      ? normalizeApiMessage(rawConversation.last_message, conversation.id)
      : rawConversation.lastMessage
        ? {
            id: `${conversation.id}:summary`,
            conversation_id: conversation.id,
            topic,
            sender_id: '',
            sender_type: 'system' as ChatPeerType,
            from: { type: 'system' as ChatPeerType, id: '' },
            to: {
              type: conversation.target.type,
              id: conversation.target.id,
            },
            content: normalizeMessageContent({
              type: 'text',
              body: rawConversation.lastMessage.content || '',
            }),
            created_at: timestampToIso(rawConversation.lastMessage.timestamp),
          }
        : undefined

    const existing = merged.get(conversation.id)
    const next: Conversation = existing
      ? {
          ...existing,
          topics: uniqueStrings([...existing.topics, ...conversation.topics]),
          last_message: pickLatestMessage(existing.last_message, normalizedMessage),
          unread_count:
            (existing.unread_count || 0) + (rawConversation.unreadCount ?? rawConversation.unread_count ?? 0),
        }
      : {
          ...conversation,
          last_message: normalizedMessage,
          unread_count: rawConversation.unreadCount ?? rawConversation.unread_count ?? 0,
        }

    merged.set(conversation.id, next)
  }

  return [...merged.values()].sort((left, right) => {
    return compareConversationsByLatest(left, right)
  })
}

export function conversationIdFromTopic(topic: string, currentUserId: string): string | null {
  const route = parseChatTopic(topic)
  if (route.kind === 'group') {
    return buildGroupTopic(route.groupId)
  }
  if (route.kind !== 'direct') {
    return null
  }
  return buildDirectTopic(route.leftType as 'user' | 'bot', route.leftId, route.rightType as 'user' | 'bot', route.rightId)
}

export function buildConversationFromTopic(
  topic: string,
  currentUserId: string,
  bots: Bot[],
  groups: Group[],
): Conversation | null {
  const route = parseChatTopic(topic)
  return buildConversationFromRoute(route, currentUserId, bots, groups)
}

function buildConversationFromRoute(
  route: ChatRoute,
  currentUserId: string,
  bots: Bot[],
  groups: Group[],
): Conversation | null {
  if (route.kind === 'group') {
    const group = groups.find((item) => item.id === route.groupId)
    const topic = buildGroupTopic(route.groupId)
    return {
      id: topic,
      type: 'group',
      name: group?.name || `Group ${route.groupId.slice(0, 8)}`,
      avatar: group?.avatar || group?.avatar_url || null,
      participants: [route.groupId],
      topics: [topic],
      send_topic: topic,
      target: { type: 'group', id: route.groupId },
      updated_at: group?.updated_at,
      created_at: group?.created_at,
    }
  }

  if (route.kind !== 'direct') {
    return null
  }

  const participants = [
    { type: route.leftType, id: route.leftId },
    { type: route.rightType, id: route.rightId },
  ]

  const botPeer = participants.find((peer) => peer.type === 'bot')
  const userPeer = participants.find((peer) => peer.type === 'user')
  if (!botPeer || !userPeer || userPeer.id !== currentUserId) {
    return null
  }

  const bot = bots.find((item) => item.id === botPeer.id)
  const topic = buildDirectTopic('user', currentUserId, 'bot', botPeer.id)

  return {
    id: topic,
    type: 'bot',
    name: bot?.name || `Bot ${botPeer.id.slice(0, 8)}`,
    avatar: bot?.avatar || bot?.avatar_url || null,
    participants: [currentUserId, botPeer.id],
    topics: [topic],
    send_topic: topic,
    target: { type: 'bot', id: botPeer.id },
    updated_at: bot?.updated_at,
    created_at: bot?.created_at,
  }
}

function enrichPeer(
  peer: ChatPeer,
  options: {
    currentUser?: User | null
    bots?: Bot[]
    groups?: Group[]
  },
): ChatPeer {
  const details = findPeerDetails(peer, options)
  if (!details) {
    return peer
  }

  return {
    ...peer,
    name: details.name || peer.name,
    avatar: details.avatar ?? peer.avatar,
  }
}

function findPeerDetails(
  peer: ChatPeer,
  options: {
    currentUser?: User | null
    bots?: Bot[]
    groups?: Group[]
  },
): { name?: string; avatar?: string | null } | null {
  if (peer.type === 'bot') {
    const bot = options.bots?.find((item) => item.id === peer.id)
    if (!bot) {
      return null
    }
    return { name: bot.name, avatar: bot.avatar || bot.avatar_url || null }
  }

  if (peer.type === 'group') {
    const group = options.groups?.find((item) => item.id === peer.id)
    if (!group) {
      return null
    }
    return { name: group.name, avatar: group.avatar || group.avatar_url || null }
  }

  if (peer.type === 'user' && options.currentUser?.id === peer.id) {
    return {
      name: options.currentUser.username,
      avatar: options.currentUser.avatar || options.currentUser.avatar_url || null,
    }
  }

  return null
}

function buildDirectTopic(
  fromType: 'user' | 'bot',
  fromId: string,
  toType: 'user' | 'bot',
  toId: string,
): string {
  const [left, right] = canonicalizeDirectPeers(
    { type: fromType, id: fromId },
    { type: toType, id: toId },
  )
  return `chat/dm/${left.type}/${left.id}/${right.type}/${right.id}`
}

function buildGroupTopic(groupId: string): string {
  return `chat/group/${groupId}`
}

function uniqueStrings(values: string[]): string[] {
  return [...new Set(values.filter(Boolean))]
}

function canonicalizeDirectPeers(
  left: { type: 'user' | 'bot'; id: string },
  right: { type: 'user' | 'bot'; id: string },
): [{ type: 'user' | 'bot'; id: string }, { type: 'user' | 'bot'; id: string }] {
  const leftRank = getDirectPeerRank(left.type)
  const rightRank = getDirectPeerRank(right.type)

  if (leftRank !== rightRank) {
    return leftRank < rightRank ? [left, right] : [right, left]
  }

  return left.id <= right.id ? [left, right] : [right, left]
}

function getDirectPeerRank(type: 'user' | 'bot'): number {
  switch (type) {
    case 'user':
      return 0
    case 'bot':
      return 1
  }
}

function normalizeMessageContent(content: ChatMessageContent): MessageContent {
  const meta = content.meta || {}
  const asset = readAsset(meta)
  const type = normalizeMessageContentType(content.type, meta)
  const url =
    content.url ||
    asset?.download_url ||
    asset?.external_url ||
    asset?.source_url ||
    readString(meta.download_url) ||
    readString(meta.external_url) ||
    readString(meta.source_url) ||
    readString(meta.url)

  return {
    ...content,
    type,
    url,
    name: content.name || asset?.file_name || readString(meta.file_name) || readString(meta.name),
    size: content.size || asset?.size,
    meta,
  }
}

function normalizeMessageContentType(
  contentType: MessageContent['type'] | undefined,
  meta: Record<string, unknown>,
): MessageContent['type'] {
  const metaType = readString(meta.content_type)
  if (
    metaType === 'image' ||
    metaType === 'file' ||
    metaType === 'audio' ||
    metaType === 'video'
  ) {
    if (!contentType || contentType === 'text') {
      return metaType
    }
  }

  return contentType || 'text'
}

function readAsset(meta: Record<string, unknown> | undefined) {
  if (!meta) {
    return undefined
  }

  const raw = meta.asset
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return undefined
  }

  return raw as {
    file_name?: string
    size?: number
    download_url?: string
    external_url?: string
    source_url?: string
  }
}

function readString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}

function pickLatestMessage(left?: Message, right?: Message): Message | undefined {
  if (!left) return right
  if (!right) return left
  return compareMessagesByTime(left, right) <= 0 ? right : left
}

export function compareConversationsByLatest(left: Conversation, right: Conversation): number {
  if (left.last_message && right.last_message) {
    const latestDiff = compareMessagesByTime(right.last_message, left.last_message)
    if (latestDiff !== 0) {
      return latestDiff
    }
  } else {
    const latestDiff = getMessageSortTime(right.last_message) - getMessageSortTime(left.last_message)
    if (latestDiff !== 0) {
      return latestDiff
    }
  }

  return left.id.localeCompare(right.id)
}

export function compareMessagesByTime(left: Message, right: Message): number {
  if (left.db_id && right.db_id && left.db_id !== right.db_id) {
    return left.db_id - right.db_id
  }

  const timeDiff = getMessageSortTime(left) - getMessageSortTime(right)
  if (timeDiff !== 0) {
    return timeDiff
  }

  if (left.topic === right.topic && left.seq && right.seq && left.seq !== right.seq) {
    return left.seq - right.seq
  }

  return left.id.localeCompare(right.id)
}

function getMessageSortTime(message?: Pick<Message, 'created_at' | 'timestamp'>): number {
  if (!message) {
    return 0
  }

  const createdAt = message.created_at ? Date.parse(message.created_at) : NaN
  if (Number.isFinite(createdAt)) {
    return createdAt
  }

  if (!message.timestamp) {
    return 0
  }

  return message.timestamp > 1_000_000_000_000 ? message.timestamp : message.timestamp * 1000
}

function timestampToIso(timestamp?: number): string | undefined {
  if (!timestamp) {
    return undefined
  }
  return new Date(timestamp * 1000).toISOString()
}
