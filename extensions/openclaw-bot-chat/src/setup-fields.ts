export const BOT_CHAT_SETUP_ENV_VARS = [
  "BOT_CHAT_BACKEND_URL",
  "BOT_CHAT_BOT_KEY",
  "BOT_CHAT_BOT_ID",
  "BOT_CHAT_MQTT_TCP_URL",
  "BOT_CHAT_MQTT_WS_URL",
] as const;

export const BOT_CHAT_SETUP_FIELDS = {
  backendUrl: {
    kind: "string",
    cli: { flags: "--backend-url <url>", description: "BotChat backend URL" },
  },
  botKey: {
    kind: "string",
    sensitive: true,
    cli: { flags: "--bot-key <key>", description: "BotChat bot key" },
  },
  botId: {
    kind: "string",
    cli: { flags: "--bot-id <id>", description: "BotChat bot id" },
  },
  mqttTcpUrl: {
    kind: "string",
    cli: { flags: "--mqtt-tcp-url <url>", description: "MQTT TCP broker URL" },
  },
  mqttWsUrl: {
    kind: "string",
    cli: { flags: "--mqtt-ws-url <url>", description: "MQTT WebSocket broker URL" },
  },
  useEnv: {
    kind: "boolean",
    cli: { flags: "--use-env", description: "Use BOT_CHAT_* environment variables" },
    envVars: [...BOT_CHAT_SETUP_ENV_VARS],
  },
} as const;

export function serializeBotChatSetupFields(): Array<Record<string, unknown>> {
  return Object.entries(BOT_CHAT_SETUP_FIELDS).map(([key, field]) => ({
    key,
    ...field,
  }));
}
