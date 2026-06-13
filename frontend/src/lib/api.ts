import type {
  User,
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
  const { authRetry = true, ...fetchOptions } = options
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
      return request<T>(endpoint, { ...fetchOptions, authRetry: false })
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
    return (payload as ApiResponse<T>).data as T
  }

  return payload as T
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
