'use client'

import React, { createContext, useContext, useEffect, useRef, useState, useCallback } from 'react'
import { botsApi, conversationsApi, groupsApi, realtimeApi } from '@/lib/api'
import {
  buildConversationFromTopic,
  compareConversationsByLatest,
  compareMessagesByTime,
  createBotDraftConversation,
  createGroupDraftConversation,
  enrichMessagePeers,
  normalizeApiMessage,
  normalizeConversations,
  normalizeRealtimeMessage,
} from '@/lib/chat'
import { getMqttRealtimeClient } from '@/lib/mqtt'
import { createClientId } from '@/lib/id'
import type {
  Asset,
  Bot,
  ComposerMessageInput,
  Conversation,
  ConversationApiResponse,
  Group,
  Message,
  RealtimeBootstrapResponse,
  RealtimeConnectionState,
  RealtimeMessagePayload,
  SlashCommand,
} from '@/lib/types'
import { useAuth } from './AuthContext'

interface ChatContextType {
  conversations: Conversation[]
  currentConversation: Conversation | null
  messages: Map<string, Message[]>
  bots: Bot[]
  groups: Group[]
  slashCommands: SlashCommand[]
  isLoading: boolean
  connectionState: RealtimeConnectionState
  setCurrentConversation: (conv: Conversation | null) => void
  openBotConversation: (bot: Bot) => void
  openGroupConversation: (group: Group) => void
  sendMessage: (input: ComposerMessageInput) => Promise<void>
  refreshConversations: () => Promise<void>
  refreshMessages: (conversationId: string) => Promise<void>
  refreshBots: () => Promise<void>
  refreshGroups: () => Promise<void>
  reconnectRealtime: () => Promise<void>
}

const ChatContext = createContext<ChatContextType | undefined>(undefined)

export function ChatProvider({ children }: { children: React.ReactNode }) {
  const { user, isAuthenticated } = useAuth()
  const [rawConversations, setRawConversations] = useState<ConversationApiResponse[]>([])
  const [conversations, setConversations] = useState<Conversation[]>([])
  const [currentConversation, setCurrentConversation] = useState<Conversation | null>(null)
  const [messages, setMessages] = useState<Map<string, Message[]>>(new Map())
  const [bots, setBots] = useState<Bot[]>([])
  const [groups, setGroups] = useState<Group[]>([])
  const [slashCommands, setSlashCommands] = useState<SlashCommand[]>([])
  const [realtimeBootstrap, setRealtimeBootstrap] = useState<RealtimeBootstrapResponse | null>(null)
  const [hasLoadedInitialData, setHasLoadedInitialData] = useState(false)
  const [connectionState, setConnectionState] = useState<RealtimeConnectionState>('idle')
  const subscriptionsRef = useRef<Map<string, () => void>>(new Map())
  const conversationsRef = useRef<Conversation[]>([])
  const userRef = useRef(user)
  const botsRef = useRef<Bot[]>([])
  const groupsRef = useRef<Group[]>([])
  const realtimeBootstrapRef = useRef<RealtimeBootstrapResponse | null>(null)
  const lastSeqByConversationRef = useRef<Map<string, number>>(new Map())
  const hasConnectedOnceRef = useRef(false)

  useEffect(() => {
    userRef.current = user
    botsRef.current = bots
    groupsRef.current = groups
    realtimeBootstrapRef.current = realtimeBootstrap
  }, [bots, groups, realtimeBootstrap, user])

  const enrichMessage = useCallback(
    (message: Message) => enrichMessagePeers(message, { currentUser: user, bots, groups }),
    [bots, groups, user],
  )

  const mergeConversationMessages = useCallback((existing: Message[], incoming: Message[]) => {
    const merged = new Map<string, Message>()

    existing.forEach((message) => {
      merged.set(message.id, message)
    })

    incoming.forEach((message) => {
      const previous = merged.get(message.id)
      merged.set(message.id, {
        ...previous,
        ...message,
        pending: false,
        failed: false,
      })
    })

    return [...merged.values()].sort(compareMessagesByTime)
  }, [])

  const upsertConversation = useCallback((conversation: Conversation) => {
    setConversations((prev) => {
      const existing = prev.find((item) => item.id === conversation.id)
      const next = existing
        ? prev.map((item) =>
            item.id === conversation.id
              ? {
                  ...item,
                  ...conversation,
                  topics: [...new Set([...(item.topics || []), ...(conversation.topics || [])])],
                  last_message: conversation.last_message || item.last_message,
                }
              : item,
          )
        : [conversation, ...prev]

      return next.sort(compareConversationsByLatest)
    })
  }, [])

  const upsertMessage = useCallback((message: Message) => {
    const enrichedMessage = enrichMessagePeers(message, {
      currentUser: userRef.current,
      bots: botsRef.current,
      groups: groupsRef.current,
    })

    setMessages((prev) => {
      const current = prev.get(enrichedMessage.conversation_id) || []
      const existingIndex = current.findIndex((item) => item.id === enrichedMessage.id)
      const nextMessages = [...current]

      if (existingIndex >= 0) {
        nextMessages[existingIndex] = {
          ...nextMessages[existingIndex],
          ...enrichedMessage,
          pending: false,
          failed: false,
        }
      } else {
        nextMessages.push(enrichedMessage)
      }

      nextMessages.sort(compareMessagesByTime)

      return new Map(prev).set(enrichedMessage.conversation_id, nextMessages)
    })

    setConversations((prev) =>
      prev
        .map((conversation) =>
          conversation.id === enrichedMessage.conversation_id
            ? {
                ...conversation,
                last_message: {
                  ...enrichedMessage,
                  pending: false,
                  failed: false,
                },
              }
            : conversation,
        )
        .sort(compareConversationsByLatest),
    )

    if (typeof enrichedMessage.seq === 'number') {
      const known = lastSeqByConversationRef.current.get(enrichedMessage.conversation_id) || 0
      if (enrichedMessage.seq > known) {
        lastSeqByConversationRef.current.set(enrichedMessage.conversation_id, enrichedMessage.seq)
      }
    }
  }, [])

  const ensureTopicSubscription = useCallback((topic: string) => {
    if (!topic || subscriptionsRef.current.has(topic) || !user || !realtimeBootstrap) {
      return
    }

    const mqtt = getMqttRealtimeClient()
    const configuredQos = realtimeBootstrap.subscriptions.find((item) => item.topic === topic)?.qos
    const qos = typeof configuredQos === 'number' ? configuredQos : realtimeBootstrap.broker.qos || 0
    const unsubscribe = mqtt.subscribe(
      topic,
      (incomingTopic, payload) => {
        const activeBootstrap = realtimeBootstrapRef.current
        if (
          incomingTopic === activeBootstrap?.slash_command_topic ||
          isSlashCommandCatalogPayload(payload)
        ) {
          setSlashCommands(readSlashCommandsFromPayload(payload))
          return
        }

        const activeUser = userRef.current
        if (!activeUser) {
          return
        }

        const conversationId = payload.conversation_id || incomingTopic
        const existingConversation = conversationsRef.current.find((item) => item.id === conversationId)
        const conversation =
          existingConversation || buildConversationFromTopic(incomingTopic, activeUser.id, botsRef.current, groupsRef.current)

        if (!conversation) {
          return
        }

        if (!existingConversation) {
          upsertConversation(conversation)
        }

        const normalized = normalizeRealtimeMessage(payload, incomingTopic)
        upsertMessage({
          ...normalized,
          conversation_id: conversation.id,
          pending: false,
          failed: false,
        })
      },
      qos,
    )

    subscriptionsRef.current.set(topic, unsubscribe)
  }, [bots, groups, realtimeBootstrap, upsertConversation, upsertMessage, user])

  const refreshBots = useCallback(async () => {
    if (!isAuthenticated) return
    const data = await botsApi.list()
    setBots(data)
  }, [isAuthenticated])

  const refreshGroups = useCallback(async () => {
    if (!isAuthenticated) return
    const data = await groupsApi.list()
    setGroups(data)
  }, [isAuthenticated])

  const refreshConversations = useCallback(async () => {
    if (!isAuthenticated) return
    const data = await conversationsApi.list()
    setRawConversations(data)
  }, [isAuthenticated])

  const refreshMessages = useCallback(
    async (conversationId: string) => {
      const conversation = conversationsRef.current.find((item) => item.id === conversationId)
      if (!conversation) return

      const loadedMessages = await Promise.all(
        conversation.topics.map(async (topic) => {
          const items = await conversationsApi.getMessages(topic)
          return items.map((item) => enrichMessage(normalizeApiMessage(item, conversation.id)))
        }),
      )

      const merged = loadedMessages
        .flat()
        .reduce<Map<string, Message>>((acc, message) => {
          acc.set(message.id, message)
          return acc
        }, new Map())

      const sortedMessages = [...merged.values()].sort(compareMessagesByTime)

      setMessages((prev) => {
        const currentMessages = prev.get(conversationId) || []
        return new Map(prev).set(
          conversationId,
          mergeConversationMessages(currentMessages, sortedMessages),
        )
      })

      const highestSeq = sortedMessages.reduce<number>(
        (maxSeq, message) => (typeof message.seq === 'number' && message.seq > maxSeq ? message.seq : maxSeq),
        0,
      )
      if (highestSeq > 0) {
        lastSeqByConversationRef.current.set(conversationId, highestSeq)
      }
    },
    [enrichMessage, mergeConversationMessages],
  )

  const catchupConversation = useCallback(
    async (conversation: Conversation) => {
      if (!realtimeBootstrap) {
        return
      }

      const afterSeq = lastSeqByConversationRef.current.get(conversation.id)
      if (typeof afterSeq !== 'number' || afterSeq <= 0) {
        return
      }

      const maxBatch = realtimeBootstrap.history?.max_catchup_batch || 100
      const loadedMessages = await Promise.all(
        conversation.topics.map(async (topic) => {
          const items = await conversationsApi.getMessages(topic, maxBatch, undefined, afterSeq)
          return items.map((item) => enrichMessage(normalizeApiMessage(item, conversation.id)))
        }),
      )

      const merged = loadedMessages
        .flat()
        .reduce<Map<string, Message>>((acc, message) => {
          acc.set(message.id, message)
          return acc
        }, new Map())

      const sortedMessages = [...merged.values()].sort(compareMessagesByTime)
      if (sortedMessages.length === 0) {
        return
      }

      setMessages((prev) => {
        const currentMessages = prev.get(conversation.id) || []
        return new Map(prev).set(
          conversation.id,
          mergeConversationMessages(currentMessages, sortedMessages),
        )
      })

      const highestSeq = sortedMessages.reduce<number>(
        (maxSeq, message) => (typeof message.seq === 'number' && message.seq > maxSeq ? message.seq : maxSeq),
        afterSeq,
      )
      lastSeqByConversationRef.current.set(conversation.id, highestSeq)
    },
    [enrichMessage, mergeConversationMessages, realtimeBootstrap],
  )

  const catchupAllConversations = useCallback(async () => {
    const currentConversations = conversationsRef.current
    await Promise.all(currentConversations.map((conversation) => catchupConversation(conversation)))
  }, [catchupConversation])

  const reconnectRealtime = useCallback(async () => {
    const mqtt = getMqttRealtimeClient()
    await mqtt.reconnectNow()
    await catchupAllConversations()
  }, [catchupAllConversations])

  const openBotConversation = useCallback(
    (bot: Bot) => {
      if (!user) return
      const draftConversation = createBotDraftConversation(user.id, bot)
      upsertConversation(draftConversation)
      draftConversation.topics.forEach(ensureTopicSubscription)
      setCurrentConversation(draftConversation)
    },
    [ensureTopicSubscription, upsertConversation, user],
  )

  const openGroupConversation = useCallback(
    (group: Group) => {
      const draftConversation = createGroupDraftConversation(group)
      upsertConversation(draftConversation)
      draftConversation.topics.forEach(ensureTopicSubscription)
      setCurrentConversation(draftConversation)
    },
    [ensureTopicSubscription, upsertConversation],
  )

  const sendMessage = useCallback(
    async (input: ComposerMessageInput) => {
      if (!currentConversation || !user) return

      if (!realtimeBootstrap) {
        throw new Error('Realtime bootstrap is unavailable')
      }

      const mqtt = getMqttRealtimeClient()
      const messageId = createClientId()
      currentConversation.topics.forEach(ensureTopicSubscription)
      const content = buildOutgoingContent(input)
      const timestamp = Math.floor(Date.now() / 1000)
      const optimisticMessage: Message = {
        id: messageId,
        conversation_id: currentConversation.id,
        topic: currentConversation.send_topic,
        sender_id: user.id,
        sender_type: 'user',
        from: {
          type: 'user',
          id: user.id,
          name: user.username,
          avatar: user.avatar || user.avatar_url || null,
        },
        to: {
          type: currentConversation.target.type,
          id: currentConversation.target.id,
          name: currentConversation.name,
          avatar: currentConversation.avatar || null,
        },
        content,
        timestamp,
        created_at: new Date().toISOString(),
        pending: true,
      }

      upsertMessage(optimisticMessage)

      try {
        const payload: RealtimeMessagePayload = {
          id: messageId,
          topic: currentConversation.send_topic,
          conversation_id: currentConversation.send_topic,
          timestamp,
          from: { type: 'user', id: user.id },
          to: { type: currentConversation.target.type, id: currentConversation.target.id },
          content,
        }

        await mqtt.publish(currentConversation.send_topic, payload, realtimeBootstrap.broker.qos || 0)
      } catch (error) {
        setMessages((prev) => {
          const next = new Map(prev)
          const currentMessages = next.get(currentConversation.id) || []
          next.set(
            currentConversation.id,
            currentMessages.map((item) =>
              item.id === messageId
                ? {
                    ...item,
                    pending: false,
                    failed: true,
                  }
                : item,
            ),
          )
          return next
        })
        throw error
      }
    },
    [currentConversation, ensureTopicSubscription, realtimeBootstrap, upsertMessage, user],
  )

  useEffect(() => {
    if (!isAuthenticated || !user) {
      setRawConversations([])
      setConversations([])
      setCurrentConversation(null)
      setMessages(new Map())
      setBots([])
      setGroups([])
      setRealtimeBootstrap(null)
      setConnectionState('idle')
      setHasLoadedInitialData(false)
      hasConnectedOnceRef.current = false
      lastSeqByConversationRef.current.clear()
      for (const [, unsubscribe] of subscriptionsRef.current.entries()) {
        unsubscribe()
      }
      subscriptionsRef.current.clear()
      void getMqttRealtimeClient().disconnect()
      return
    }

    let cancelled = false
    setHasLoadedInitialData(false)

    Promise.all([
      refreshBots(),
      refreshGroups(),
      refreshConversations(),
      realtimeApi.bootstrap().then((bootstrap) => setRealtimeBootstrap(bootstrap)),
    ])
      .catch((error) => {
        console.error('Failed to load chat data:', error)
      })
      .finally(() => {
        if (!cancelled) {
          setHasLoadedInitialData(true)
        }
      })

    return () => {
      cancelled = true
    }
  }, [isAuthenticated, refreshBots, refreshConversations, refreshGroups, user])

  useEffect(() => {
    return () => {
      for (const [, unsubscribe] of subscriptionsRef.current.entries()) {
        unsubscribe()
      }
      subscriptionsRef.current.clear()
    }
  }, [])

  useEffect(() => {
    if (!user) return

    const normalized = normalizeConversations(rawConversations, user.id, bots, groups)
    setConversations((prev) => {
      const drafts = prev.filter((item) => item.last_message == null)
      const merged = new Map<string, Conversation>()

      normalized.forEach((item) => merged.set(item.id, item))
      drafts.forEach((item) => {
        if (!merged.has(item.id)) {
          merged.set(item.id, item)
        }
      })

      return [...merged.values()].sort(compareConversationsByLatest)
    })
  }, [bots, groups, rawConversations, user])

  useEffect(() => {
    conversationsRef.current = conversations
  }, [conversations])

  useEffect(() => {
    setMessages((prev) => {
      let changed = false
      const next = new Map<string, Message[]>()

      for (const [conversationId, conversationMessages] of prev.entries()) {
        const enrichedMessages = conversationMessages.map((message) => {
          const enriched = enrichMessage(message)
          if (
            enriched.from.name !== message.from.name ||
            enriched.from.avatar !== message.from.avatar ||
            enriched.to.name !== message.to.name ||
            enriched.to.avatar !== message.to.avatar
          ) {
            changed = true
          }
          return enriched
        })
        next.set(conversationId, enrichedMessages)
      }

      return changed ? next : prev
    })
  }, [enrichMessage])

  useEffect(() => {
    if (!currentConversation) return
    setCurrentConversation((prev) => {
      if (!prev) return prev
      return conversations.find((item) => item.id === prev.id) || prev
    })
  }, [conversations])

  useEffect(() => {
    if (!isAuthenticated || !realtimeBootstrap) return

    const mqtt = getMqttRealtimeClient()
    const unsubscribe = mqtt.onStateChange((nextState) => {
      setConnectionState(nextState)
      if (nextState !== 'connected') {
        return
      }
      if (!hasConnectedOnceRef.current) {
        hasConnectedOnceRef.current = true
        return
      }
      void catchupAllConversations()
    })

    void mqtt.connect({
      wsUrl: realtimeBootstrap.broker.ws_url,
      username: realtimeBootstrap.broker.username,
      password: realtimeBootstrap.broker.password,
      clientId: realtimeBootstrap.client_id,
    }).catch((error) => {
      console.error('Failed to connect MQTT broker:', error)
      setConnectionState('disconnected')
    })

    return () => {
      unsubscribe()
    }
  }, [catchupAllConversations, isAuthenticated, realtimeBootstrap])

  useEffect(() => {
    if (!user || !realtimeBootstrap) return

    const nextTopics = new Set<string>([
      ...realtimeBootstrap.subscriptions.map((item) => item.topic),
      ...conversations.flatMap((conversation) => conversation.topics),
    ])

    for (const [topic, unsubscribe] of subscriptionsRef.current.entries()) {
      if (!nextTopics.has(topic)) {
        unsubscribe()
        subscriptionsRef.current.delete(topic)
      }
    }

    nextTopics.forEach((topic) => {
      ensureTopicSubscription(topic)
    })
  }, [conversations, ensureTopicSubscription, realtimeBootstrap, user])

  const isLoading = isAuthenticated && !hasLoadedInitialData

  return (
    <ChatContext.Provider
      value={{
        conversations,
        currentConversation,
        messages,
        bots,
        groups,
        slashCommands,
        isLoading,
        connectionState,
        setCurrentConversation,
        openBotConversation,
        openGroupConversation,
        sendMessage,
        refreshConversations,
        refreshMessages,
        refreshBots,
        refreshGroups,
        reconnectRealtime,
      }}
    >
      {children}
    </ChatContext.Provider>
  )
}

function buildOutgoingContent(input: ComposerMessageInput): Message['content'] {
  if (input.type === 'image' || input.type === 'audio') {
    const asset = input.asset
    const url = asset?.download_url || asset?.external_url || asset?.source_url
    const body = input.body?.trim() || asset?.file_name || (input.type === 'audio' ? 'Voice message' : 'Image')
    return {
      type: input.type,
      body,
      url,
      name: asset?.file_name,
      size: asset?.size,
      meta: {
        ...(asset ? { asset } : {}),
        ...(input.meta || {}),
      },
    }
  }

  return {
    type: 'text',
    body: input.body?.trim() || '',
    meta: input.meta || {},
  }
}

function isSlashCommandCatalogPayload(payload: RealtimeMessagePayload): boolean {
  return payload.content?.meta?.content_type === 'slash_commands'
}

function readSlashCommandsFromPayload(payload: RealtimeMessagePayload): SlashCommand[] {
  const raw = payload.content?.meta?.slash_commands
  if (!Array.isArray(raw)) {
    return []
  }

  const commands: SlashCommand[] = []
  raw.forEach((item) => {
    if (!isRecord(item)) {
      return
    }
    const name = typeof item.name === 'string' ? item.name.trim().replace(/^\/+/, '') : ''
    if (!name) {
      return
    }
    commands.push({
      name,
      description: typeof item.description === 'string' ? item.description : undefined,
      acceptsArgs: item.acceptsArgs === true,
      args: readSlashCommandArgs(item.args),
    })
  })
  return commands
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function readSlashCommandArgs(value: unknown): SlashCommand['args'] {
  if (!Array.isArray(value)) {
    return undefined
  }

  const args: NonNullable<SlashCommand['args']> = []
  value.forEach((item) => {
    if (!isRecord(item)) {
      return
    }
    const name = typeof item.name === 'string' ? item.name.trim() : ''
    if (!name) {
      return
    }
    args.push({
      name,
      description: typeof item.description === 'string' ? item.description : undefined,
      type: typeof item.type === 'string' ? item.type : undefined,
      required: item.required === true,
      choices: Array.isArray(item.choices) ? item.choices : undefined,
    })
  })
  return args.length > 0 ? args : undefined
}

export function useChat() {
  const context = useContext(ChatContext)
  if (context === undefined) {
    throw new Error('useChat must be used within a ChatProvider')
  }
  return context
}
