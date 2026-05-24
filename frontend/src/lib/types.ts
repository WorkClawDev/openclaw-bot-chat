'use client'

export type ChatPeerType = 'user' | 'bot' | 'group' | 'system'
export type ConversationType = 'bot' | 'group'
export type RealtimeConnectionState = 'idle' | 'connecting' | 'connected' | 'reconnecting' | 'disconnected'

export interface User {
  id: string
  username: string
  email: string
  nickname?: string
  avatar?: string | null
  avatar_url?: string | null
  created_at?: string
  updated_at?: string
}

export interface Bot {
  id: string
  owner_id?: string
  user_id?: string
  name: string
  description?: string | null
  avatar?: string | null
  avatar_url?: string | null
  bot_type?: string
  status?: string
  status_code?: number
  is_public?: boolean
  mqtt_topic?: string | null
  created_at?: string
  updated_at?: string
}

export interface BotKey {
  id: string
  bot_id: string
  botId?: string
  key?: string
  key_prefix?: string
  name?: string | null
  last_used_at?: string | null
  last_used_ip?: string | null
  expires_at?: string | number | null
  is_active?: boolean
  status?: string
  created_at?: string | number
}

export interface ChatPeer {
  type: ChatPeerType
  id: string
  name?: string | null
  avatar?: string | null
}

export interface MessageContent {
  type: 'text' | 'image' | 'file' | 'audio' | 'video'
  body?: string
  url?: string
  name?: string
  size?: number
  meta?: Record<string, unknown>
}

export interface Asset {
  id?: string
  kind?: 'image' | 'file' | 'audio' | 'video'
  status?: 'pending' | 'ready' | 'failed'
  storage_provider?: string
  bucket?: string
  object_key?: string
  mime_type?: string
  size?: number
  file_name?: string
  width?: number
  height?: number
  sha256?: string
  download_url?: string
  download_url_expires_at?: string
  external_url?: string
  source_url?: string
  metadata?: Record<string, unknown>
}

export interface PreparedUpload {
  asset: Asset
  upload: {
    method: string
    url: string
    headers?: Record<string, string>
    expires_at: string
  }
}

export interface ComposerMessageInput {
  type: 'text' | 'image'
  body?: string
  asset?: Asset
  meta?: Record<string, unknown>
}

export interface SlashCommandArg {
  name: string
  description?: string
  type?: string
  required?: boolean
  choices?: unknown[]
}

export interface SlashCommand {
  name: string
  description?: string
  acceptsArgs?: boolean
  args?: SlashCommandArg[]
}

export interface Message {
  id: string
  db_id?: number
  conversation_id: string
  topic: string
  sender_id: string
  sender_type: ChatPeerType
  from: ChatPeer
  to: ChatPeer
  content: MessageContent
  seq?: number
  timestamp?: number
  created_at?: string
  pending?: boolean
  failed?: boolean
}

export interface ConversationTarget {
  type: 'bot' | 'group' | 'user'
  id: string
}

export interface Conversation {
  id: string
  type: ConversationType
  name: string
  avatar?: string | null
  participants: string[]
  topics: string[]
  send_topic: string
  target: ConversationTarget
  last_message?: Message
  unread_count?: number
  created_at?: string
  updated_at?: string
}

export interface Group {
  id: string
  name: string
  description?: string | null
  avatar?: string | null
  avatar_url?: string | null
  owner_id: string
  ownerId?: string
  member_count?: number
  memberCount?: number
  is_active?: boolean
  max_members?: number
  created_at?: string
  updated_at?: string
}

export interface GroupMember {
  id: string
  type: 'user' | 'bot'
  group_id: string
  user_id?: string
  bot_id?: string
  role: 'owner' | 'admin' | 'member'
  nickname?: string | null
  is_active?: boolean
  joined_at?: string
  added_at?: string
  user?: User
  bot?: Bot
}

export interface GroupMembersResponse {
  users: GroupMember[]
  bots: GroupMember[]
}

export interface MessageApiResponse {
  id: string
  db_id?: number
  conversation_id: string
  mqtt_topic?: string
  from?: ChatPeer
  to?: ChatPeer
  content: MessageContent
  sender_type?: ChatPeerType
  sender_id?: string | null
  seq?: number
  created_at?: string
  timestamp?: number
}

export interface ConversationApiResponse {
  id: string
  type?: string
  name?: string
  avatar?: string | null
  targetId?: string
  sourceId?: string
  lastMessage?: {
    content?: string
    timestamp?: number
  }
  unreadCount?: number
  conversation_id: string
  last_message?: MessageApiResponse
  unread_count?: number
}

export interface RealtimeSubscription {
  topic: string
  qos?: number
}

export interface RealtimeBootstrapResponse {
  broker: {
    tcp_url: string
    ws_url: string
    username?: string
    password?: string
    qos?: number
  }
  client_id: string
  principal_type: 'user' | 'bot'
  principal_id: string
  subscriptions: RealtimeSubscription[]
  publish_topics: string[]
  slash_command_topic?: string
  history?: {
    max_catchup_batch?: number
  }
}

export interface RealtimeMessagePayload {
  id: string
  topic: string
  conversation_id: string
  timestamp: number
  seq?: number
  created_at?: string
  from: {
    type: 'user' | 'bot'
    id: string
  }
  to: {
    type: 'user' | 'bot' | 'group'
    id: string
  }
  content: MessageContent
}

export interface AuthTokens {
  access_token: string
  refresh_token: string
  expires_in: number
  token_type?: string
}

export interface ApiResponse<T> {
  code?: number
  data?: T
  error?: string
  message?: string
}

export interface AuthPayload {
  tokens: AuthTokens
  user?: User
}
