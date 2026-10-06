import type { ChannelDoctorAdapter } from "./channel-api.js";
import {
  collectBotChatConfigIssues,
  getBotChatChannelConfig,
  isRecord,
  normalizeAllowFromEntries,
} from "./config.js";

function formatIssue(issue: ReturnType<typeof collectBotChatConfigIssues>[number]): string {
  const prefix = issue.severity === "error" ? "error" : "warning";
  return `- BotChat ${prefix} ${issue.code} at ${issue.path}: ${issue.message}`;
}

function repairBotChatAllowFrom(cfg: Record<string, unknown>): { config: Record<string, unknown>; changes: string[] } {
  const next = structuredClone(cfg) as Record<string, unknown>;
  const channel = getBotChatChannelConfig(next);
  const changes: string[] = [];
  if (!isRecord(channel) || !Array.isArray(channel.allowFrom)) {
    return { config: next, changes };
  }
  const normalized = normalizeAllowFromEntries(channel.allowFrom);
  const original = channel.allowFrom.map((entry) => String(entry));
  if (JSON.stringify(normalized) !== JSON.stringify(original)) {
    channel.allowFrom = normalized;
    if (channel !== next) {
      const channels = isRecord(next.channels) ? next.channels : {};
      channels["bot-chat"] = channel;
      next.channels = channels;
    }
    changes.push("- BotChat allowFrom: normalized sender ids");
  }
  return { config: next, changes };
}

export const botChatDoctor: ChannelDoctorAdapter = {
  dmAllowFromMode: "topOnly",
  groupModel: "sender",
  groupAllowFromFallbackToAllowFrom: true,
  warnOnEmptyGroupSenderAllowlist: false,
  collectPreviewWarnings: ({ cfg }) =>
    collectBotChatConfigIssues(getBotChatChannelConfig(cfg))
      .filter((issue) => issue.severity === "warning")
      .map(formatIssue),
  repairConfig: ({ cfg }) => {
    const repaired = repairBotChatAllowFrom(cfg);
    return {
      config: repaired.config,
      changes: repaired.changes,
      warnings: collectBotChatConfigIssues(getBotChatChannelConfig(repaired.config)).map(formatIssue),
    };
  },
  runConfigSequence: ({ cfg, shouldRepair }) => {
    const repaired = shouldRepair ? repairBotChatAllowFrom(cfg) : { config: cfg, changes: [] };
    return {
      changeNotes: repaired.changes,
      warningNotes: collectBotChatConfigIssues(getBotChatChannelConfig(repaired.config)).map(formatIssue),
    };
  },
  migrateState: ({ cfg }) => ({
    config: cfg,
    changes: [],
  }),
};
