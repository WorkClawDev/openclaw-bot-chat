import mqtt, { type IClientOptions, type MqttClient } from "mqtt";

type JsonRecord = Record<string, unknown>;
type QoSLevel = 0 | 1 | 2;

export type BotChatMqttState =
  | "idle"
  | "connecting"
  | "open"
  | "reconnecting"
  | "closed";

interface BotChatMqttHandlers {
  onError?: (error: Error) => void;
  onMessage?: (topic: string, payload: unknown) => Promise<void> | void;
  onConnect?: () => void;
  onReconnect?: () => Promise<void> | void;
  onStateChange?: (state: BotChatMqttState) => void;
}

export interface BotChatMqttClientOptions extends BotChatMqttHandlers {
  brokerUrl: string;
  clientId: string;
  username?: string;
  password?: string;
  reconnectBaseDelayMs: number;
  reconnectMaxDelayMs: number;
}

export class BotChatMqttClient {
  private client: MqttClient | undefined;
  private state: BotChatMqttState = "idle";
  private closedByUser = false;
  private connectedOnce = false;
  private readonly subscriptions = new Map<string, QoSLevel>();

  constructor(private readonly options: BotChatMqttClientOptions) {}

  getState(): BotChatMqttState {
    return this.state;
  }

  getSubscribedTopics(): string[] {
    return [...this.subscriptions.keys()];
  }

  async connect(): Promise<void> {
    if (this.client && this.state !== "closed") {
      return;
    }

    this.closedByUser = false;
    this.setState("connecting");
    const connectOptions: IClientOptions = {
      clientId: this.options.clientId,
      keepalive: 30,
      reconnectPeriod: this.options.reconnectBaseDelayMs,
      connectTimeout: this.options.reconnectMaxDelayMs,
      clean: true,
      ...(this.options.username ? { username: this.options.username } : {}),
      ...(this.options.password ? { password: this.options.password } : {}),
    };

    this.client = mqtt.connect(this.options.brokerUrl, connectOptions);

    await new Promise<void>((resolve, reject) => {
      const client = this.client;
      if (!client) {
        reject(new Error("mqtt client initialization failed"));
        return;
      }

      const onConnect = () => {
        const wasConnected = this.connectedOnce;
        this.connectedOnce = true;
        this.setState("open");
        this.resubscribeAll();
        if (wasConnected) {
          void this.options.onReconnect?.();
        } else {
          this.options.onConnect?.();
        }
        resolve();
      };

      const onReconnect = () => {
        if (!this.closedByUser) {
          this.setState("reconnecting");
        }
      };

      const onMessage = (topic: string, payload: Buffer) => {
        const decoded = parsePayload(payload);
        void this.options.onMessage?.(topic, decoded);
      };

      const onError = (error: Error) => {
        this.options.onError?.(error);
      };

      const onClose = () => {
        if (this.closedByUser) {
          this.setState("closed");
          return;
        }
        this.setState("reconnecting");
      };

      client.on("connect", onConnect);
      client.on("reconnect", onReconnect);
      client.on("message", onMessage);
      client.on("error", onError);
      client.on("close", onClose);

      client.once("error", (error) => {
        reject(error);
      });
    });
  }

  async close(): Promise<void> {
    this.closedByUser = true;
    const client = this.client;
    this.client = undefined;
    if (!client) {
      this.setState("closed");
      return;
    }

    await new Promise<void>((resolve, reject) => {
      client.end(true, {}, (error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
    this.setState("closed");
  }

  async subscribe(topic: string, qos: number = 1): Promise<void> {
    if (!topic) {
      return;
    }
    const normalizedQos = normalizeQos(qos);
    this.subscriptions.set(topic, normalizedQos);

    const client = this.client;
    if (!client || !client.connected) {
      return;
    }

    await new Promise<void>((resolve, reject) => {
      client.subscribe(topic, { qos: normalizedQos }, (error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  }

  async publish(topic: string, payload: unknown, qos: number = 1): Promise<void> {
    const client = this.client;
    if (!client || !client.connected) {
      throw new Error("mqtt client is not connected");
    }

    const normalizedQos = normalizeQos(qos);
    await new Promise<void>((resolve, reject) => {
      client.publish(topic, JSON.stringify(payload), { qos: normalizedQos }, (error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  }

  private resubscribeAll(): void {
    const client = this.client;
    if (!client || !client.connected) {
      return;
    }

    for (const [topic, qos] of this.subscriptions.entries()) {
      client.subscribe(topic, { qos });
    }
  }

  private setState(state: BotChatMqttState): void {
    if (state === this.state) {
      return;
    }
    this.state = state;
    this.options.onStateChange?.(state);
  }
}

function parsePayload(payload: Buffer): unknown {
  const text = payload.toString("utf8");
  if (!text) {
    return {};
  }

  try {
    return JSON.parse(text) as JsonRecord;
  } catch {
    return {
      content: {
        type: "text",
        body: text,
      },
    };
  }
}

function normalizeQos(value: number): QoSLevel {
  switch (value) {
    case 0:
    case 2:
      return value;
    default:
      return 1;
  }
}
