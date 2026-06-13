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
  type: 'text' | 'image' | 'audio'
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
  metadata?: Record<string, unknown>
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

export type TaskStatus =
  | 'pending'
  | 'available'
  | 'claimed'
  | 'in_progress'
  | 'awaiting_review'
  | 'completed'
  | 'failed'
  | 'rejected'
  | 'cancelled'
  | 'blocked'
export type TaskPriority = 'low' | 'normal' | 'high' | 'critical'

export type TaskPayload = Record<string, unknown> | unknown[] | string | number | boolean | null

export interface TaskDependency {
  id: string
  depends_on_task_id: string
  depends_on_task?: {
    id: string
    title: string
    status: TaskStatus
    progress: number
  }
}

export interface TaskEvent {
  id: string
  actor_type: 'user' | 'bot' | 'system' | 'worker'
  actor_id?: string | null
  status: TaskStatus
  progress: number
  note?: string | null
  event_type?: string
  type?: string
  payload?: TaskPayload
  created_at: string
}

export interface TaskDispatchInfo {
  at?: string | null
  by_id?: string | null
  topic?: string | null
  payload?: TaskPayload
}

export interface TaskClaimInfo {
  at?: string | null
  bot_id?: string | null
  worker_id?: string | null
  bot?: Bot | null
}

export interface TaskReviewInfo {
  status?: 'pending' | 'accepted' | 'rejected'
  reviewer_id?: string | null
  note?: string | null
  payload?: TaskPayload
  created_at?: string | null
  updated_at?: string | null
}

export interface Task {
  id: string
  owner_id: string
  title: string
  description?: string | null
  priority: TaskPriority
  status: TaskStatus
  parent_task_id?: string | null
  assignee_bot_id?: string | null
  assignee_bot?: Bot | null
  estimated_start_at?: string | null
  estimated_end_at?: string | null
  actual_start_at?: string | null
  actual_end_at?: string | null
  dispatched_at?: string | null
  claimed_at?: string | null
  dispatched?: TaskDispatchInfo | null
  claimed?: TaskClaimInfo | null
  claimed_by_bot_id?: string | null
  claimed_by_bot?: Bot | null
  current_executor_bot_id?: string | null
  current_executor_bot?: Bot | null
  executor_bot_id?: string | null
  executor_bot?: Bot | null
  result?: TaskPayload
  error?: TaskPayload
  review?: TaskReviewInfo | TaskPayload
  progress: number
  latest_status_note?: string | null
  dependencies: TaskDependency[]
  events: TaskEvent[]
  created_at: string
  updated_at: string
}

export type DocumentSource = 'user' | 'bot'
export type DocumentStatus = 'active' | 'archived'

export interface DocumentObject {
  id: string
  owner_id: string
  url: string
  title: string
  summary: string
  body?: string
  document_type: 'markdown'
  source: DocumentSource
  status: DocumentStatus
  source_bot_id?: string | null
  source_conversation_id?: string | null
  source_message_id?: string | null
  metadata?: Record<string, unknown>
  created_at: string
  updated_at: string
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
  metadata?: Record<string, unknown>
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
  metadata?: Record<string, unknown>
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
