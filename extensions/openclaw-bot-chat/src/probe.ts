import type { ResolvedBotChatAccount } from "./channel-api.js";
import { buildBotChatBootstrapUrl, isRecord, readString } from "./config.js";

export type BotChatProbe = {
  ok: boolean;
  botId?: string;
  backendUrl?: string;
  mqttTcpUrl?: string;
  mqttWsUrl?: string;
  error?: string;
  status?: number;
};

export async function probeBotChatAccount(params: {
  account: ResolvedBotChatAccount;
  timeoutMs?: number;
}): Promise<BotChatProbe> {
  const backendUrl = readString(params.account.backendUrl);
  const botKey = readString(params.account.config.botKey);
  if (!backendUrl || !botKey) {
    return {
      ok: false,
      backendUrl,
      error: "backendUrl and botKey are required to probe BotChat",
    };
  }

  const timeoutMs = Math.max(250, params.timeoutMs ?? 2500);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(buildBotChatBootstrapUrl(backendUrl), {
      method: "GET",
      headers: {
        Accept: "application/json",
        "X-Bot-Key": botKey,
      },
      signal: controller.signal,
    });
    if (!response.ok) {
      return {
        ok: false,
        backendUrl,
        status: response.status,
        error: `bootstrap failed: ${response.status}`,
      };
    }
    const json = (await response.json()) as unknown;
    const record = isRecord(json) ? json : {};
    const data = isRecord(record.data) ? record.data : record;
    const bot = isRecord(data.bot) ? data.bot : undefined;
    const broker = isRecord(data.broker) ? data.broker : undefined;
    return {
      ok: true,
      backendUrl,
      botId: readString(bot?.id) ?? params.account.botId,
      mqttTcpUrl: readString(broker?.tcp_url) ?? params.account.mqttTcpUrl,
      mqttWsUrl: readString(broker?.ws_url) ?? params.account.mqttWsUrl,
      status: response.status,
    };
  } catch (error) {
    return {
      ok: false,
      backendUrl,
      error: error instanceof Error ? error.message : String(error),
    };
  } finally {
    clearTimeout(timer);
  }
}
