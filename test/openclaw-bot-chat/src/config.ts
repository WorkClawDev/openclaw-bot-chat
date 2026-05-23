import { access, readFile } from "node:fs/promises";
import path from "node:path";

import {
  normalizeAllowList,
  resolveActionPermissions,
  type ActionPermissions,
  type AllowList,
  type ChannelPolicy,
  type GroupPolicy,
} from "./types/permissions";

export interface BotConfig {
  id?: string;
  accessKey: string;
  enabled: boolean;
  channels?: AllowList;
  users?: AllowList;
  groupPolicy?: GroupPolicy;
  actions?: ActionPermissions;
}

export interface PluginConfig {
  botChatBaseUrl: string;
  mqttTcpUrl?: string;
  mqttWsUrl?: string;
  botId?: string;
  accessKey?: string;
  configPath: string;
  stateDir: string;
  httpTimeoutMs: number;
  reconnectBaseDelayMs: number;
  reconnectMaxDelayMs: number;
  openClawAgentUrl?: string;
  openClawAgentHandler?: string;
  openClawAgentTimeoutMs: number;
  permissionApprovalEnabled: boolean;
  permissionApprovalUrl?: string;
  permissionApprovalHandler?: string;
  permissionApprovalTimeoutMs: number;
  permissionDeniedReply?: string;
  bots: Record<string, BotConfig>;
  defaultBot?: string;
  defaultChannelPolicy: ChannelPolicy;
}

export interface ResolvedBotConfig extends BotConfig {
  key: string;
}

type JsonRecord = Record<string, unknown>;

const DEFAULT_CONFIG_FILE = "config.json";
const DEFAULT_STATE_DIR = "data";
const DEFAULT_BOT_KEY = "default";

export async function loadConfig(cwd = process.cwd()): Promise<PluginConfig> {
  const configPath = path.resolve(
    cwd,
    process.env.BOT_CHAT_CONFIG ?? DEFAULT_CONFIG_FILE,
  );
  const fileConfig = await readConfigFile(configPath);

  const botChatBaseUrl = readString(
    process.env.BOT_CHAT_BACKEND_URL,
    readString(
      fileConfig["BOT_CHAT_BACKEND_URL"],
      readString(fileConfig["botChatBaseUrl"], readString(fileConfig["baseUrl"])),
    ),
  );
  const mqttTcpUrl = readString(
    process.env.BOT_CHAT_MQTT_TCP_URL,
    readString(fileConfig["BOT_CHAT_MQTT_TCP_URL"], readString(fileConfig["mqttTcpUrl"])),
  );
  const mqttWsUrl = readString(
    process.env.BOT_CHAT_MQTT_WS_URL,
    readString(fileConfig["BOT_CHAT_MQTT_WS_URL"], readString(fileConfig["mqttWsUrl"])),
  );
  const accessKey = readString(
    process.env.BOT_CHAT_BOT_KEY,
    readString(
      fileConfig["BOT_CHAT_BOT_KEY"],
      readString(fileConfig["accessKey"]),
    ),
  );
  const botId = readString(
    process.env.BOT_CHAT_BOT_ID,
    readString(fileConfig["BOT_CHAT_BOT_ID"], readString(fileConfig["botId"])),
  );
  const defaultChannelPolicy = readChannelPolicy(
    process.env.BOT_CHAT_DEFAULT_CHANNEL_POLICY,
    fileConfig["defaultChannelPolicy"],
    "open",
  );
  const stateDir = path.resolve(
    cwd,
    readString(
      process.env.OPENCLAW_STATE_DIR,
      readString(fileConfig["stateDir"], DEFAULT_STATE_DIR),
    ) ?? DEFAULT_STATE_DIR,
  );

  if (!botChatBaseUrl) {
    throw new Error("BOT_CHAT_BACKEND_URL is required");
  }

  const fileBots = readBots(fileConfig["bots"], defaultChannelPolicy);
  let defaultBot = readString(
    process.env.BOT_CHAT_DEFAULT_BOT,
    readString(fileConfig["defaultBot"]),
  );
  const bots =
    Object.keys(fileBots).length > 0
      ? applyLegacyOverrides(fileBots, defaultBot, accessKey, botId)
      : buildLegacyBots(fileConfig, accessKey, botId, defaultChannelPolicy, defaultBot);

  if (!defaultBot) {
    defaultBot = Object.keys(bots)[0];
  }
  if (!defaultBot || !bots[defaultBot]) {
    throw new Error("defaultBot must reference a configured bot");
  }
  const defaultBotConfig = bots[defaultBot];
  if (!defaultBotConfig) {
    throw new Error("defaultBot must reference a configured bot");
  }

  const config: PluginConfig = {
    botChatBaseUrl: normalizeBaseUrl(botChatBaseUrl),
    ...(mqttTcpUrl ? { mqttTcpUrl } : {}),
    ...(mqttWsUrl ? { mqttWsUrl } : {}),
    configPath,
    stateDir,
    httpTimeoutMs: readInteger(
      process.env.BOT_CHAT_HTTP_TIMEOUT_MS,
      readInteger(fileConfig["httpTimeoutMs"], 15_000),
    ),
    reconnectBaseDelayMs: readInteger(
      process.env.BOT_CHAT_RECONNECT_BASE_MS,
      readInteger(fileConfig["reconnectBaseDelayMs"], 1_000),
    ),
    reconnectMaxDelayMs: readInteger(
      process.env.BOT_CHAT_RECONNECT_MAX_MS,
      readInteger(fileConfig["reconnectMaxDelayMs"], 30_000),
    ),
    openClawAgentTimeoutMs: readInteger(
      process.env.OPENCLAW_AGENT_TIMEOUT_MS,
      readInteger(fileConfig["openClawAgentTimeoutMs"], 60_000),
    ),
    permissionApprovalEnabled: readBoolean(
      process.env.OPENCLAW_PERMISSION_APPROVAL_ENABLED,
      readBoolean(fileConfig["permissionApprovalEnabled"], false),
    ),
    permissionApprovalTimeoutMs: readInteger(
      process.env.OPENCLAW_PERMISSION_APPROVAL_TIMEOUT_MS,
      readInteger(fileConfig["permissionApprovalTimeoutMs"], 8_000),
    ),
    bots,
    defaultChannelPolicy,
    defaultBot,
  };
  config.accessKey = defaultBotConfig.accessKey;
  if (defaultBotConfig.id) {
    config.botId = defaultBotConfig.id;
  }

  const openClawAgentUrl = readString(
    process.env.OPENCLAW_AGENT_URL,
    readString(fileConfig["openClawAgentUrl"]),
  );
  if (openClawAgentUrl) {
    config.openClawAgentUrl = openClawAgentUrl;
  }

  const openClawAgentHandler = readString(
    process.env.OPENCLAW_AGENT_HANDLER,
    readString(fileConfig["openClawAgentHandler"]),
  );
  if (openClawAgentHandler) {
    config.openClawAgentHandler = openClawAgentHandler;
  }

  const permissionApprovalUrl = readString(
    process.env.OPENCLAW_PERMISSION_APPROVAL_URL,
    readString(fileConfig["permissionApprovalUrl"]),
  );
  if (permissionApprovalUrl) {
    config.permissionApprovalUrl = permissionApprovalUrl;
  }

  const permissionApprovalHandler = readString(
    process.env.OPENCLAW_PERMISSION_APPROVAL_HANDLER,
    readString(fileConfig["permissionApprovalHandler"]),
  );
  if (permissionApprovalHandler) {
    config.permissionApprovalHandler = permissionApprovalHandler;
  }

  const permissionDeniedReply = readString(
    process.env.OPENCLAW_PERMISSION_DENIED_REPLY,
    readString(fileConfig["permissionDeniedReply"]),
  );
  if (permissionDeniedReply) {
    config.permissionDeniedReply = permissionDeniedReply;
  }

  return config;
}

export function getEnabledBots(config: PluginConfig): ResolvedBotConfig[] {
  return Object.entries(config.bots)
    .filter(([, bot]) => bot.enabled)
    .map(([key, bot]) => ({
      ...bot,
      key,
      actions: resolveActionPermissions(bot.actions),
      groupPolicy:
        bot.groupPolicy ??
        (config.defaultChannelPolicy === "allowlist" ? "allowlist" : "open"),
    }));
}

async function readConfigFile(configPath: string): Promise<JsonRecord> {
  try {
    await access(configPath);
  } catch {
    return {};
  }

  const raw = await readFile(configPath, "utf8");
  const parsed = JSON.parse(raw) as unknown;
  return isRecord(parsed) ? parsed : {};
}

function normalizeBaseUrl(baseUrl: string): string {
  return baseUrl.trim().replace(/\/+$/, "");
}

function readBots(
  value: unknown,
  defaultChannelPolicy: ChannelPolicy,
): Record<string, BotConfig> {
  if (!isRecord(value)) {
    return {};
  }

  const bots: Record<string, BotConfig> = {};
  for (const [key, item] of Object.entries(value)) {
    const botConfig = readBotConfig(item, defaultChannelPolicy, `bots.${key}`);
    if (botConfig) {
      bots[key] = botConfig;
    }
  }
  return bots;
}

function readBotConfig(
  value: unknown,
  defaultChannelPolicy: ChannelPolicy,
  configPath: string,
): BotConfig | undefined {
  if (!isRecord(value)) {
    return undefined;
  }

  const accessKey = readString(value["accessKey"], value["BOT_CHAT_BOT_KEY"]);
  if (!accessKey) {
    throw new Error(`${configPath}.accessKey is required`);
  }

  const botConfig: BotConfig = {
    accessKey,
    enabled: readBoolean(value["enabled"], true),
    groupPolicy: readGroupPolicy(value["groupPolicy"], defaultChannelPolicy),
    actions: resolveActionPermissions(readActions(value["actions"])),
  };

  const id = readString(value["id"], value["BOT_CHAT_BOT_ID"], value["botId"]);
  if (id) {
    botConfig.id = id;
  }

  const channels = normalizeAllowList(value["channels"] as AllowList | string[] | undefined);
  if (channels) {
    botConfig.channels = channels;
  }

  const users = normalizeAllowList(value["users"] as AllowList | string[] | undefined);
  if (users) {
    botConfig.users = users;
  }

  return botConfig;
}

function buildLegacyBots(
  fileConfig: JsonRecord,
  accessKey: string | undefined,
  botId: string | undefined,
  defaultChannelPolicy: ChannelPolicy,
  defaultBot: string | undefined,
): Record<string, BotConfig> {
  if (!accessKey) {
    throw new Error("BOT_CHAT_BOT_KEY is required");
  }

  const key = defaultBot ?? DEFAULT_BOT_KEY;
  const botConfig: BotConfig = {
    accessKey,
    enabled: readBoolean(fileConfig["enabled"], true),
    groupPolicy: readGroupPolicy(fileConfig["groupPolicy"], defaultChannelPolicy),
    actions: resolveActionPermissions(readActions(fileConfig["actions"])),
  };

  if (botId) {
    botConfig.id = botId;
  }

  const channels = normalizeAllowList(
    fileConfig["channels"] as AllowList | string[] | undefined,
  );
  if (channels) {
    botConfig.channels = channels;
  }

  const users = normalizeAllowList(
    fileConfig["users"] as AllowList | string[] | undefined,
  );
  if (users) {
    botConfig.users = users;
  }

  return {
    [key]: botConfig,
  };
}

function applyLegacyOverrides(
  bots: Record<string, BotConfig>,
  defaultBot: string | undefined,
  accessKey: string | undefined,
  botId: string | undefined,
): Record<string, BotConfig> {
  if (!accessKey && !botId) {
    return bots;
  }

  const selectedKey = defaultBot ?? Object.keys(bots)[0];
  if (!selectedKey) {
    return bots;
  }

  const current = bots[selectedKey];
  if (!current) {
    throw new Error(`defaultBot "${selectedKey}" is not configured`);
  }

  const next: BotConfig = {
    ...current,
    accessKey: accessKey ?? current.accessKey,
  };
  const nextBotId = botId ?? current.id;
  if (nextBotId) {
    next.id = nextBotId;
  }

  return {
    ...bots,
    [selectedKey]: next,
  };
}

function readString(...values: Array<unknown>): string | undefined {
  for (const value of values) {
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed) {
        return trimmed;
      }
    }
  }
  return undefined;
}

function readInteger(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number.parseInt(value, 10);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return fallback;
}

function readBoolean(value: unknown, fallback: boolean): boolean {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    const normalized = value.trim().toLocaleLowerCase();
    if (normalized === "true") {
      return true;
    }
    if (normalized === "false") {
      return false;
    }
  }
  return fallback;
}

function readActions(value: unknown): Partial<ActionPermissions> | undefined {
  if (!isRecord(value)) {
    return undefined;
  }

  const actions: Partial<ActionPermissions> = {};
  for (const key of [
    "sendMessage",
    "sendImage",
    "typing",
    "reactions",
    "threads",
  ] as const) {
    if (typeof value[key] === "boolean") {
      actions[key] = value[key] as boolean;
    }
  }

  return Object.keys(actions).length > 0 ? actions : undefined;
}

function readChannelPolicy(
  ...values: Array<unknown>
): ChannelPolicy {
  for (const value of values) {
    if (value === "open" || value === "allowlist") {
      return value;
    }
  }
  return "open";
}

function readGroupPolicy(
  value: unknown,
  defaultChannelPolicy: ChannelPolicy,
): GroupPolicy {
  if (value === "open" || value === "allowlist" || value === "disabled") {
    return value;
  }
  return defaultChannelPolicy === "allowlist" ? "allowlist" : "open";
}

function isRecord(value: unknown): value is JsonRecord {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
