import mqtt, { type IClientOptions, type MqttClient } from 'mqtt'
import type { RealtimeConnectionState, RealtimeMessagePayload } from './types'

type MessageHandler = (topic: string, payload: RealtimeMessagePayload) => void
type ConnectionHandler = (state: RealtimeConnectionState) => void
type QoSLevel = 0 | 1 | 2

interface ConnectOptions {
  wsUrl: string
  username?: string
  password?: string
  clientId: string
}

interface MqttRealtimeClient {
  connect: (options: ConnectOptions) => Promise<void>
  disconnect: () => Promise<void>
  publish: (topic: string, payload: RealtimeMessagePayload, qos?: number) => Promise<void>
  subscribe: (topic: string, handler: MessageHandler, qos?: number) => () => void
  onStateChange: (handler: ConnectionHandler) => () => void
  reconnectNow: () => Promise<void>
  getState: () => RealtimeConnectionState
}

type TopicHandlerSet = Set<MessageHandler>

export function createMqttRealtimeClient(): MqttRealtimeClient {
  let client: MqttClient | null = null
  let state: RealtimeConnectionState = 'idle'
  let connectPromise: Promise<void> | null = null
  let currentOptions: ConnectOptions | null = null

  const stateHandlers = new Set<ConnectionHandler>()
  const topicHandlers = new Map<string, TopicHandlerSet>()
  const subscriptions = new Map<string, QoSLevel>()

  function emitState(nextState: RealtimeConnectionState) {
    state = nextState
    stateHandlers.forEach((handler) => handler(nextState))
  }

  function parsePayload(payload: Uint8Array): RealtimeMessagePayload | null {
    try {
      const text = new TextDecoder().decode(payload)
      return JSON.parse(text) as RealtimeMessagePayload
    } catch (error) {
      console.error('Failed to parse MQTT payload:', error)
      return null
    }
  }

  function subscribeKnownTopics(nextClient: MqttClient) {
    for (const [topic, qos] of subscriptions.entries()) {
      nextClient.subscribe(topic, { qos }, (error) => {
        if (error) {
          console.error(`Failed to subscribe topic ${topic}:`, error)
        }
      })
    }
  }

  function attachClient(nextClient: MqttClient) {
    nextClient.on('connect', () => {
      emitState('connected')
      subscribeKnownTopics(nextClient)
    })

    nextClient.on('reconnect', () => {
      emitState('reconnecting')
    })

    nextClient.on('close', () => {
      if (state !== 'idle') {
        emitState('disconnected')
      }
    })

    nextClient.on('error', (error) => {
      console.error('MQTT connection error:', error)
    })

    nextClient.on('message', (topic, payload) => {
      if(topic.startsWith('agent/user/')){window.dispatchEvent(new CustomEvent('agent-update'));return}
      const parsed = parsePayload(payload)
      if (!parsed) {
        return
      }
      topicHandlers.get(topic)?.forEach((handler) => handler(topic, parsed))
      topicHandlers.get('*')?.forEach((handler) => handler(topic, parsed))
    })
  }

  async function connectClient(options: ConnectOptions): Promise<void> {
    if (client && (client.connected || client.reconnecting)) {
      return
    }

    currentOptions = options
    emitState(state === 'disconnected' ? 'reconnecting' : 'connecting')

    const connectOptions: IClientOptions = {
      clientId: options.clientId,
      username: options.username,
      password: options.password,
      reconnectPeriod: 2000,
      connectTimeout: 10_000,
      clean: true,
      protocolVersion: 4,
    }

    connectPromise = new Promise<void>((resolve, reject) => {
      const nextClient = mqtt.connect(options.wsUrl, connectOptions)
      client = nextClient
      attachClient(nextClient)

      const onConnect = () => {
        nextClient.off('error', onError)
        resolve()
      }

      const onError = (error: Error) => {
        nextClient.off('connect', onConnect)
        reject(error)
      }

      nextClient.once('connect', onConnect)
      nextClient.once('error', onError)
    }).finally(() => {
      connectPromise = null
    })

    return connectPromise
  }

  async function connect(options: ConnectOptions): Promise<void> {
    if (connectPromise) {
      return connectPromise
    }

    if (
      currentOptions &&
      currentOptions.wsUrl === options.wsUrl &&
      currentOptions.clientId === options.clientId &&
      currentOptions.username === options.username &&
      currentOptions.password === options.password &&
      client?.connected
    ) {
      return
    }

    if (client) {
      await disconnect()
    }

    return connectClient(options)
  }

  async function disconnect(): Promise<void> {
    if (!client) {
      emitState('idle')
      return
    }

    await new Promise<void>((resolve) => {
      client?.end(true, {}, () => resolve())
    })
    client = null
    currentOptions = null
    emitState('idle')
  }

  async function reconnectNow(): Promise<void> {
    if (!currentOptions) {
      throw new Error('MQTT client is not configured')
    }
    if (client) {
      client.end(true)
      client = null
    }
    emitState('reconnecting')
    await connectClient(currentOptions)
  }

  async function publish(topic: string, payload: RealtimeMessagePayload, qos = 0): Promise<void> {
    if (!client?.connected) {
      if (!currentOptions) {
        throw new Error('MQTT client is not configured')
      }
      await connect(currentOptions)
    }
    if (!client) {
      throw new Error('MQTT client is unavailable')
    }

    const body = JSON.stringify(payload)
    const normalizedQos = Math.max(0, Math.min(1, qos)) as QoSLevel
    await new Promise<void>((resolve, reject) => {
      client!.publish(topic, body, { qos: normalizedQos }, (error) => {
        if (error) {
          reject(error)
          return
        }
        resolve()
      })
    })
  }

  function subscribe(topic: string, handler: MessageHandler, qos = 0): () => void {
    if (!topicHandlers.has(topic)) {
      topicHandlers.set(topic, new Set<MessageHandler>())
    }
    topicHandlers.get(topic)!.add(handler)

    const normalizedQos = Math.max(0, Math.min(1, qos)) as QoSLevel
    const previousQos = subscriptions.get(topic)
    if (typeof previousQos !== 'number' || normalizedQos > previousQos) {
      subscriptions.set(topic, normalizedQos)
    }

    if (client?.connected) {
      client.subscribe(topic, { qos: subscriptions.get(topic) || 0 }, (error) => {
        if (error) {
          console.error(`Failed to subscribe topic ${topic}:`, error)
        }
      })
    }

    return () => {
      const handlers = topicHandlers.get(topic)
      if (!handlers) {
        return
      }
      handlers.delete(handler)
      if (handlers.size > 0) {
        return
      }

      topicHandlers.delete(topic)
      subscriptions.delete(topic)
      if (client?.connected) {
        client.unsubscribe(topic, (error) => {
          if (error) {
            console.error(`Failed to unsubscribe topic ${topic}:`, error)
          }
        })
      }
    }
  }

  function onStateChange(handler: ConnectionHandler) {
    stateHandlers.add(handler)
    handler(state)
    return () => {
      stateHandlers.delete(handler)
    }
  }

  function getState(): RealtimeConnectionState {
    return state
  }

  return {
    connect,
    disconnect,
    publish,
    subscribe,
    onStateChange,
    reconnectNow,
    getState,
  }
}

let mqttClient: ReturnType<typeof createMqttRealtimeClient> | null = null

export function getMqttRealtimeClient(): ReturnType<typeof createMqttRealtimeClient> {
  if (!mqttClient) {
    mqttClient = createMqttRealtimeClient()
  }
  return mqttClient
}
