import type {
  User,
  AdminUser,
  Bot,
  BotKey,
  ConversationApiResponse,
  MessageApiResponse,
  Group,
  GroupMembersResponse,
  AuthTokens,
  AuthPayload,
  ApiResponse,
  Asset,
  PreparedUpload,
  RealtimeBootstrapResponse,
  Task,
  TaskPriority,
  TaskStatus,
  DocumentObject,
} from './types'

const RAW_API_BASE = (process.env.NEXT_PUBLIC_API_URL || '').replace(/\/+$/, '')
const AUTH_SESSION_EXPIRED_EVENT = 'openclaw-auth-session-expired'

type ApiRequestOptions = RequestInit & {
  authRetry?: boolean
  includePagination?: boolean
}

let refreshPromise: Promise<AuthTokens | null> | null = null

function getApiBase(): string {
  if (typeof window === 'undefined') {
    return RAW_API_BASE
  }

  if (!RAW_API_BASE) {
    return ''
  }

  if (RAW_API_BASE.startsWith('/')) {
    return RAW_API_BASE
  }

  try {
    const configuredUrl = new URL(RAW_API_BASE)

    if (configuredUrl.origin === window.location.origin) {
      return ''
    }

    // Avoid mixed-content failures when the app is served over HTTPS.
    if (window.location.protocol === 'https:' && configuredUrl.protocol === 'http:') {
      return ''
    }

    return configuredUrl.toString().replace(/\/+$/, '')
  } catch {
    return ''
  }
}

function getToken(): string | null {
  if (typeof window === 'undefined') return null
  return localStorage.getItem('access_token')
}

function getRefreshToken(): string | null {
  if (typeof window === 'undefined') return null
  return localStorage.getItem('refresh_token')
}

function storeTokens(tokens: AuthTokens) {
  if (typeof window === 'undefined') return
  localStorage.setItem('access_token', tokens.access_token)
  localStorage.setItem('refresh_token', tokens.refresh_token)
}

function clearStoredTokens() {
  if (typeof window === 'undefined') return
  localStorage.removeItem('access_token')
  localStorage.removeItem('refresh_token')
  window.dispatchEvent(new Event(AUTH_SESSION_EXPIRED_EVENT))
}

async function refreshStoredTokens(): Promise<AuthTokens | null> {
  const storedRefreshToken = getRefreshToken()
  if (!storedRefreshToken) {
    clearStoredTokens()
    return null
  }

  if (!refreshPromise) {
    refreshPromise = requestTokenRefresh(storedRefreshToken)
      .then((tokens) => {
        storeTokens(tokens)
        return tokens
      })
      .catch(() => {
        clearStoredTokens()
        return null
      })
      .finally(() => {
        refreshPromise = null
      })
  }

  return refreshPromise
}

async function requestTokenRefresh(refreshToken: string): Promise<AuthTokens> {
  const apiBase = getApiBase()
  const response = await fetch(`${apiBase}/api/v1/auth/refresh`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ refresh_token: refreshToken }),
  })

  const payload = await response.json().catch(async () => {
    const text = await response.text().catch(() => '')
    return text ? { message: text } : {}
  })

  if (!response.ok) {
    const error = payload as ApiResponse<unknown>
    throw new Error(error.message || error.error || `HTTP ${response.status}`)
  }

  if (payload && typeof payload === 'object' && 'code' in payload) {
    return (payload as ApiResponse<AuthTokens>).data as AuthTokens
  }

  return payload as AuthTokens
}

async function request<T>(
  endpoint: string,
  options: ApiRequestOptions = {}
): Promise<T> {
  const { authRetry = true, includePagination = false, ...fetchOptions } = options
  const token = getToken()
  const apiBase = getApiBase()
  const headers: HeadersInit = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...fetchOptions.headers,
  }

  const response = await fetch(`${apiBase}${endpoint}`, {
    ...fetchOptions,
    headers,
  })

  if (response.status === 401 && authRetry) {
    const refreshed = await refreshStoredTokens()
    if (refreshed?.access_token) {
      return request<T>(endpoint, { ...fetchOptions, authRetry: false, includePagination })
    }
  }

  if (response.status === 204) {
    return undefined as T
  }

  const payload = await response.json().catch(async () => {
    const text = await response.text().catch(() => '')
    return text ? { message: text } : {}
  })

  if (!response.ok) {
    const error = payload as ApiResponse<unknown>
    throw new Error(error.message || error.error || `HTTP ${response.status}`)
  }

  if (payload && typeof payload === 'object' && 'code' in payload) {
    if (includePagination) return payload as T
    return (payload as ApiResponse<T>).data as T
  }

  return payload as T
}

export const adminApi = {
  users: (page: number, search: string, signal?: AbortSignal) =>
    request<{ data: AdminUser[]; total: number; has_more: boolean }>(`/api/v1/admin/users?${new URLSearchParams({ page: String(page), page_size: '20', search })}`, { includePagination: true, signal }),
  updateAccess: (id: string, data: Partial<Pick<AdminUser, 'role' | 'status'>>) =>
    request<AdminUser>(`/api/v1/admin/users/${encodeURIComponent(id)}/access`, { method: 'PUT', body: JSON.stringify(data) }),
}

// Auth API
export const authApi = {
  register: (data: { username: string; email: string; password: string }) =>
    request<AuthPayload>('/api/v1/auth/register', {
      method: 'POST',
      authRetry: false,
      body: JSON.stringify(data),
    }).then((payload) => payload.tokens),

  login: (data: { identifier: string; password: string }) =>
    request<AuthPayload>('/api/v1/auth/login', {
      method: 'POST',
      authRetry: false,
      body: JSON.stringify(
        data.identifier.includes('@')
          ? { email: data.identifier, password: data.password }
          : { username: data.identifier, password: data.password }
      ),
    }).then((payload) => payload.tokens),

  refresh: (data: { refresh_token: string }) =>
    request<AuthTokens>('/api/v1/auth/refresh', {
      method: 'POST',
      authRetry: false,
      body: JSON.stringify(data),
    }),

  logout: () =>
    request<void>('/api/v1/auth/logout', { method: 'POST' }),

  getMe: () => request<User>('/api/v1/auth/me'),

  updateMe: (data: Partial<User>) =>
    request<User>('/api/v1/auth/me', {
      method: 'PUT',
      body: JSON.stringify(data),
    }),

  changePassword: (data: { old_password: string; new_password: string }) =>
    request<void>('/api/v1/auth/change-password', {
      method: 'POST',
      body: JSON.stringify(data),
    }),
}

// Bots API
export const botsApi = {
  list: () => request<Bot[]>('/api/v1/bots'),

  get: (id: string) => request<Bot>(`/api/v1/bots/${id}`),

  create: (data: { name: string; description?: string; avatar?: string; avatar_url?: string | null }) =>
    request<Bot>('/api/v1/bots', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  update: (id: string, data: Partial<Bot>) =>
    request<Bot>(`/api/v1/bots/${id}`, {
      method: 'PUT',
      body: JSON.stringify(data),
    }),

  delete: (id: string) =>
    request<void>(`/api/v1/bots/${id}`, { method: 'DELETE' }),

  // Bot Keys
  listKeys: (botId: string) => request<BotKey[]>(`/api/v1/bots/${botId}/keys`),

  createKey: (botId: string, data: { name?: string; expires_at?: string }) =>
    request<BotKey>(`/api/v1/bots/${botId}/keys`, {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  deleteKey: (botId: string, keyId: string) =>
    request<void>(`/api/v1/bots/${botId}/keys/${keyId}`, { method: 'DELETE' }),
}

// Conversations API
export const conversationsApi = {
  list: () => request<ConversationApiResponse[]>('/api/v1/conversations'),

  getMessages: (conversationId: string, limit = 50, beforeSeq?: number, afterSeq?: number) => {
    const params = new URLSearchParams({ limit: String(limit) })
    if (typeof beforeSeq === 'number') params.set('before_seq', String(beforeSeq))
    if (typeof afterSeq === 'number') params.set('after_seq', String(afterSeq))
    return request<MessageApiResponse[]>(`/api/v1/messages/${conversationId}?${params}`)
  },
}

export const realtimeApi = {
  bootstrap: () => request<RealtimeBootstrapResponse>('/api/v1/realtime/bootstrap'),
}

export const assetsApi = {
  prepareFileUpload: (data: {file_name:string;content_type:string;size:number;conversation_id?:string}) => request<PreparedUpload>("/api/v1/assets/file/upload-prepare",{method:"POST",body:JSON.stringify(data)}),
  completeFileUpload: (data:{asset_id:string;object_key:string}) => request<Asset>("/api/v1/assets/file/complete",{method:"POST",body:JSON.stringify(data)}),
  file: (id:string) => request<Asset>(`/api/v1/assets/file/${encodeURIComponent(id)}`),

  prepareImageUpload: (data: { file_name: string; content_type: string; size: number; conversation_id?: string }) =>
    request<PreparedUpload>('/api/v1/assets/image/upload-prepare', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  completeImageUpload: (data: { asset_id: string; object_key: string }) =>
    request<Asset>('/api/v1/assets/image/complete', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  prepareAudioUpload: (data: { file_name: string; content_type: string; size: number; conversation_id?: string }) =>
    request<PreparedUpload>('/api/v1/assets/audio/upload-prepare', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  completeAudioUpload: (data: { asset_id: string; object_key: string }) =>
    request<Asset>('/api/v1/assets/audio/complete', {
      method: 'POST',
      body: JSON.stringify(data),
    }),
}

// Groups API
export const groupsApi = {
  list: () => request<Group[]>('/api/v1/groups'),

  get: (id: string) => request<Group>(`/api/v1/groups/${id}`),

  create: (data: { name: string; description?: string }) =>
    request<Group>('/api/v1/groups', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  update: (id: string, data: Partial<Group>) =>
    request<Group>(`/api/v1/groups/${id}`, {
      method: 'PUT',
      body: JSON.stringify(data),
    }),

  delete: (id: string) =>
    request<void>(`/api/v1/groups/${id}`, { method: 'DELETE' }),

  getMembers: (id: string) =>
    request<GroupMembersResponse>(`/api/v1/groups/${id}/members`),

  addMember: (id: string, data: { user_id?: string; bot_id?: string; nickname?: string }) =>
    request<void>(`/api/v1/groups/${id}/members`, {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  removeMember: (id: string, userId: string) =>
    request<void>(`/api/v1/groups/${id}/members/${userId}`, {
      method: 'DELETE',
    }),
}

export const tasksApi = {
  list: () => request<Task[]>('/api/v1/tasks'),

  get: (id: string) => request<Task>(`/api/v1/tasks/${id}`),

  create: (data: {
    title: string
    description?: string
    priority?: TaskPriority
    status?: TaskStatus
    parent_task_id?: string
    assignee_bot_id?: string
    estimated_start_at?: string
    estimated_end_at?: string
    dependency_ids?: string[]
    latest_status_note?: string
  }) =>
    request<Task>('/api/v1/tasks', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  update: (id: string, data: Partial<Task> & { dependency_ids?: string[] }) =>
    request<Task>(`/api/v1/tasks/${id}`, {
      method: 'PUT',
      body: JSON.stringify(data),
    }),

  dispatch: (id: string, data: { assignee_bot_id?: string | null; note?: string; payload?: unknown } = {}) =>
    request<Task>(`/api/v1/tasks/${id}/dispatch`, {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  accept: (id: string, data: { note?: string; payload?: unknown } = {}) =>
    request<Task>(`/api/v1/tasks/${id}/accept`, {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  reject: (id: string, data: { note?: string; reason?: string; payload?: unknown } = {}) =>
    request<Task>(`/api/v1/tasks/${id}/reject`, {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  cancel: (id: string, data: { note?: string; reason?: string; payload?: unknown } = {}) =>
    request<Task>(`/api/v1/tasks/${id}/cancel`, {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  retry: (id: string, data: { assignee_bot_id?: string | null; note?: string; payload?: unknown } = {}) =>
    request<Task>(`/api/v1/tasks/${id}/retry`, {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  reassign: (id: string, data: { assignee_bot_id?: string | null; latest_status_note?: string }) =>
    request<Task>(`/api/v1/tasks/${id}/reassign`, {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  delete: (id: string) =>
    request<void>(`/api/v1/tasks/${id}`, { method: 'DELETE' }),
}

export const documentsApi = {
  list: (limit = 100) => request<DocumentObject[]>(`/api/v1/documents?limit=${Math.max(1, Math.min(limit, 200))}`),

  get: (id: string) => request<DocumentObject>(`/api/v1/documents/${id}`),

  create: (data: { title: string; body: string; summary?: string }) =>
    request<DocumentObject>('/api/v1/documents', {
      method: 'POST',
      body: JSON.stringify({
        document_type: 'markdown',
        ...data,
      }),
    }),

  update: (id: string, data: { title?: string; body?: string; summary?: string }) =>
    request<DocumentObject>(`/api/v1/documents/${id}`, {
      method: 'PUT',
      body: JSON.stringify(data),
    }),

  archive: (id: string) => request<void>(`/api/v1/documents/${id}`, { method: 'DELETE' }),
}

// Health check
export const healthApi = {
  check: () => request<{ status: string }>('/health'),
}

export { AUTH_SESSION_EXPIRED_EVENT, getApiBase, getToken }

export interface AgentApproval {id:string;run_id:string;tool:string;parameter_hash:string;arguments:Record<string,unknown>;status:string;expires_at:string}
export const agentApi = {
  approvals: () => request<AgentApproval[]>("/api/v1/agent/approvals"),
  decide: (id:string, approved:boolean) => request<unknown>(`/api/v1/agent/approvals/${encodeURIComponent(id)}/decision`, {method:"POST",body:JSON.stringify({approved})}),
}

export interface AgentRun {id:string;bot_id?:string;task_id?:string;conversation:string;status:string;cancel_requested:boolean;steps:number;max_steps:number;error?:string;result?:{content?:string};event_seq:number;created_at?:string}
export interface AgentRunEvent {id:string;seq:number;type:string;data:Record<string,unknown>;created_at:string}
export const runsApi = {
 list:()=>request<AgentRun[]>("/api/v1/agent/runs"),
 events:(id:string,after=0)=>request<AgentRunEvent[]>(`/api/v1/agent/runs/${encodeURIComponent(id)}/events?after_seq=${after}`),
 action:(id:string,action:"cancel"|"resume",input="")=>request<unknown>(`/api/v1/agent/runs/${encodeURIComponent(id)}/${action}`,{method:"POST",body:JSON.stringify({input})}),
}

export interface AgentArtifact {id:string;run_id:string;file_name:string;mime_type:string;sha256:string;version:number;size:number;document_id?:string}
export const artifactsApi={list:(run:string)=>request<AgentArtifact[]>(`/api/v1/agent/runs/${run}/artifacts`),download:(id:string)=>request<Asset>(`/api/v1/agent/artifacts/${id}/download`)}
export interface AgentMemory {id:string;bot_id:string;scope:string;content:string;source:string;confirmed:boolean}
export interface AgentSchedule {id:string;bot_id:string;title:string;prompt:string;timezone:string;recurrence:string;missed_policy:string;status:string;next_at:string;last_task_id?:string;last_task_status?:string;last_task_note?:string}
export const memoryApi={list:()=>request<AgentMemory[]>('/api/v1/agent/memories'),save:(data:Omit<AgentMemory,'id'>,id?:string)=>request<AgentMemory>(`/api/v1/agent/memories${id?'/'+id:''}`,{method:id?'PUT':'POST',body:JSON.stringify(data)}),remove:(id:string)=>request(`/api/v1/agent/memories/${id}`,{method:'DELETE'}),export:()=>request<AgentMemory[]>('/api/v1/agent/memories/export')}
export const schedulesApi={list:()=>request<AgentSchedule[]>('/api/v1/agent/schedules'),create:(data:Record<string,unknown>)=>request<AgentSchedule>('/api/v1/agent/schedules',{method:'POST',body:JSON.stringify(data)}),action:(id:string,action:'pause'|'resume'|'cancel')=>request(`/api/v1/agent/schedules/${id}/${action}`,{method:'POST'})}

export const reconciliationApi = { list:()=>request<Array<{id:string;run_id:string;tool:string}>>('/api/v1/agent/tool-calls/uncertain'), resolve:(id:string,outcome:string,evidence:string)=>request(`/api/v1/agent/tool-calls/${id}/reconcile`,{method:'POST',body:JSON.stringify({outcome,evidence})}) }
