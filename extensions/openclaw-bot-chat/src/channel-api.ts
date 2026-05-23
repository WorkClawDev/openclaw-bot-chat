export const BOT_CHAT_CHANNEL_ID = "bot-chat" as const;
export const BOT_CHAT_DEFAULT_ACCOUNT_ID = "default" as const;
export const BOT_CHAT_SLASH_COMMAND_TOPIC = "control/bot-chat/slash-commands" as const;
export const BOT_CHAT_PAIRING_APPROVED_MESSAGE =
  "BotChat pairing approved. You can send messages to OpenClaw now." as const;

export type BotChatChannelConfig = {
  enabled?: boolean;
  name?: string;
  backendUrl?: string;
  botKey?: string;
  botId?: string;
  mqttTcpUrl?: string;
  mqttWsUrl?: string;
  stateDir?: string;
  historyCatchupLimit?: number;
  defaultTo?: string;
  allowFrom?: string[];
  permissionApprovalEnabled?: boolean;
  permissionApprovalHandler?: string;
  permissionApprovalUrl?: string;
  permissionApprovalTimeoutMs?: number;
  permissionDeniedReply?: string;
};

export type BotChatTarget =
  | { kind: "direct"; id: string; raw: string }
  | { kind: "channel"; id: string; raw: string };

export type BotChatConfigIssue = {
  severity: "error" | "warning";
  code: string;
  message: string;
  path: string;
};

export type BotChatCredentialStatus = "available" | "configured_unavailable" | "missing";

export type InspectedBotChatAccount = {
  accountId: string;
  enabled: boolean;
  name?: string;
  botKey: string;
  botKeySource: "env" | "config" | "none";
  botKeyStatus: BotChatCredentialStatus;
  configured: boolean;
  config: BotChatChannelConfig;
};

export type ResolvedBotChatAccount = {
  accountId: string;
  name: string;
  enabled: boolean;
  configured: boolean;
  backendUrl?: string;
  botId: string;
  mqttTcpUrl?: string;
  mqttWsUrl?: string;
  config: BotChatChannelConfig;
};

export type ChannelMeta = {
  id: string;
  label: string;
  selectionLabel: string;
  detailLabel?: string;
  docsPath: string;
  docsLabel: string;
  blurb: string;
  markdownCapable?: boolean;
};

export type ChannelCapabilities = {
  chatTypes: Array<"direct" | "channel" | "thread" | "group">;
  media?: boolean;
  polls?: boolean;
  reactions?: boolean;
  threads?: boolean;
  nativeCommands?: boolean;
};

export type ChannelCommandAdapter = {
  nativeCommandsAutoEnabled?: boolean;
  nativeSkillsAutoEnabled?: boolean;
};

export type ChannelConfigAdapter<ResolvedAccount> = {
  listAccountIds: (cfg: Record<string, unknown>) => string[];
  resolveAccount: (cfg: Record<string, unknown>, accountId?: string) => ResolvedAccount;
  inspectAccount?: (cfg: Record<string, unknown>, accountId?: string | null) => unknown;
  defaultAccountId: (cfg: Record<string, unknown>) => string;
  isConfigured: (account: ResolvedAccount) => boolean;
  describeAccount?: (account: ResolvedAccount) => Record<string, unknown>;
  hasConfiguredState?: (params: {
    cfg?: Record<string, unknown>;
    env?: Record<string, string | undefined>;
  }) => boolean;
  resolveAllowFrom?: (params: {
    cfg: Record<string, unknown>;
    accountId?: string;
  }) => string[] | undefined;
  resolveDefaultTo?: (params: {
    cfg: Record<string, unknown>;
    accountId?: string;
  }) => string | undefined;
};

export type ChannelSetupAdapter = {
  applyAccountConfig: (params: {
    cfg: Record<string, unknown>;
    accountId?: string;
    input: Record<string, unknown>;
  }) => Record<string, unknown>;
  validateConfig?: (input: Record<string, unknown>) => {
    ok: boolean;
    errors: string[];
  };
};

export type BotChatStatusSnapshot = {
  accountId: string;
  configured: boolean;
  connected: boolean;
  botId: string;
  backendUrl?: string;
  mqttTcpUrl?: string;
  mqttWsUrl?: string;
  lastError?: string;
  approvalMode: "pairing" | "custom-approval";
  allowFromCount: number;
  hasDefaultTo: boolean;
  historyCatchupLimit: number;
  statePathConfigured: boolean;
  issues: BotChatConfigIssue[];
};

export type ChannelStatusAdapter<ResolvedAccount> = {
  getSnapshot: (params: {
    cfg: Record<string, unknown>;
    accountId?: string;
    runtimeState?: Record<string, unknown>;
  }) => BotChatStatusSnapshot;
  describeAccount: (account: ResolvedAccount) => Record<string, unknown>;
};

export type ChannelGatewayAdapter<ResolvedAccount> = {
  startAccount: (ctx: {
    cfg: Record<string, unknown>;
    account: ResolvedAccount;
    log?: {
      info?(message: string, fields?: Record<string, unknown>): void;
      warn?(message: string, fields?: Record<string, unknown>): void;
      error?(message: string, fields?: Record<string, unknown>): void;
      debug?(message: string, fields?: Record<string, unknown>): void;
    };
    abortSignal?: AbortSignal;
    runtimeState?: Record<string, unknown>;
    setStatus?: (patch: Record<string, unknown>) => void;
    channelRuntime?: {
      emitMessage?: (message: {
        channelId: string;
        userId: string;
        text: string;
        metadata?: Record<string, unknown>;
      }) => Promise<void>;
      reply?: {
        dispatchReplyWithBufferedBlockDispatcher?: (params: {
          ctx: Record<string, unknown>;
          cfg: Record<string, unknown>;
          dispatcherOptions: {
            deliver: (payload: { text?: string }, info?: { kind?: string }) => Promise<void>;
            onError?: (error: unknown, info?: { kind?: string }) => void;
            onSkip?: (payload: unknown, info?: { kind?: string; reason?: string }) => void;
          };
        }) => Promise<unknown>;
      };
    };
  }) => Promise<void | { stop?: () => Promise<void> }>;
};

export type ChannelOutboundDeliveryResult = {
  channel: string;
  messageId: string;
  channelId?: string;
  roomId?: string;
  conversationId?: string;
  timestamp?: number;
  meta?: Record<string, unknown>;
};

export type ChannelOutboundAdapter = {
  deliveryMode: "direct" | "gateway" | "hybrid";
  textChunkLimit?: number;
  sendText: (params: {
    cfg: Record<string, unknown>;
    to: string;
    text: string;
    accountId?: string | null;
    metadata?: Record<string, unknown>;
  }) => Promise<ChannelOutboundDeliveryResult>;
  sendMedia?: (params: {
    cfg: Record<string, unknown>;
    to: string;
    text?: string;
    mediaUrl: string;
    mediaAccess?: Record<string, unknown>;
    accountId?: string | null;
    metadata?: Record<string, unknown>;
  }) => Promise<ChannelOutboundDeliveryResult>;
};

export type ChannelPairingAdapter = {
  text: {
    idLabel: string;
    message: string;
    normalizeAllowEntry: (raw: string) => string;
    notify: (params: {
      cfg: Record<string, unknown>;
      id: string;
      message: string;
      accountId?: string;
    }) => Promise<void>;
  };
};

export type ChannelAllowlistAdapter = {
  normalizeEntry: (raw: string) => string;
  isAllowed: (params: {
    cfg: Record<string, unknown>;
    accountId?: string;
    userId: string;
  }) => boolean;
};

export type ChannelDoctorConfigMutation = {
  config: Record<string, unknown>;
  changes: string[];
  warnings?: string[];
};

export type ChannelDoctorSequenceResult = {
  changeNotes: string[];
  warningNotes: string[];
};

export type ChannelDoctorAdapter = {
  dmAllowFromMode?: "topOnly" | "topOrNested" | "nestedOnly";
  groupModel?: "sender" | "route" | "hybrid";
  groupAllowFromFallbackToAllowFrom?: boolean;
  warnOnEmptyGroupSenderAllowlist?: boolean;
  collectPreviewWarnings?: (params: {
    cfg: Record<string, unknown>;
    doctorFixCommand: string;
  }) => string[] | Promise<string[]>;
  repairConfig?: (params: {
    cfg: Record<string, unknown>;
    doctorFixCommand: string;
  }) => ChannelDoctorConfigMutation | Promise<ChannelDoctorConfigMutation>;
  runConfigSequence?: (params: {
    cfg: Record<string, unknown>;
    env: Record<string, string | undefined>;
    shouldRepair: boolean;
  }) => ChannelDoctorSequenceResult | Promise<ChannelDoctorSequenceResult>;
};

export type SecretRef = {
  source: "env" | "file" | "exec";
  provider: string;
  id: string;
};

export type SecretTargetRegistryEntry = {
  id: string;
  targetType: string;
  configFile: "openclaw.json" | "auth-profiles.json";
  pathPattern: string;
  secretShape: "secret_input" | "sibling_ref";
  expectedResolvedValue: "string" | "string-or-object";
  includeInPlan: boolean;
  includeInConfigure: boolean;
  includeInAudit: boolean;
  accountIdPathSegmentIndex?: number;
};

export type SecretAssignment = {
  ref: SecretRef;
  path: string;
  expected: "string" | "string-or-object";
  apply: (value: unknown) => void;
};

export type SecretResolverContext = {
  assignments: SecretAssignment[];
  warnings?: Array<{ code: string; path: string; message: string }>;
};

export type ChannelSecretsAdapter = {
  secretTargetRegistryEntries?: readonly SecretTargetRegistryEntry[];
  collectRuntimeConfigAssignments?: (params: {
    config: Record<string, unknown>;
    defaults?: Record<string, string | undefined>;
    context: SecretResolverContext;
  }) => void;
};

export type ChannelPlugin<ResolvedAccount = unknown> = {
  id: string;
  meta: ChannelMeta;
  capabilities: ChannelCapabilities;
  reload?: { configPrefixes: string[]; noopPrefixes?: string[] };
  configSchema?: Record<string, unknown>;
  config: ChannelConfigAdapter<ResolvedAccount>;
  commands?: ChannelCommandAdapter;
  setup?: ChannelSetupAdapter;
  status?: ChannelStatusAdapter<ResolvedAccount>;
  gateway?: ChannelGatewayAdapter<ResolvedAccount>;
  outbound?: ChannelOutboundAdapter;
  doctor?: ChannelDoctorAdapter;
  secrets?: ChannelSecretsAdapter;
  pairing?: ChannelPairingAdapter;
  allowlist?: ChannelAllowlistAdapter;
  approvalCapability?: {
    mode: "custom-approval" | "pairing";
    description: string;
    secondaryGate?: "custom-approval";
  };
  messaging?: {
    normalizeTarget?: (target: string) => string;
    inferTargetChatType?: (params: { to: string }) => "direct" | "channel" | "thread";
  };
  security?: {
    defaultPolicy: "allow" | "approve" | "deny";
    mode?: "allowFrom" | "customApproval";
    approveHint?: string;
  };
};

export const BOT_CHAT_CHANNEL_META: ChannelMeta = {
  id: BOT_CHAT_CHANNEL_ID,
  label: "BotChat",
  selectionLabel: "BotChat (MQTT Bridge)",
  detailLabel: "BotChat Bridge",
  docsPath: "/channels/bot-chat",
  docsLabel: "bot-chat",
  blurb: "Bridge OpenClaw to BotChat backend and MQTT.",
  markdownCapable: true,
};

export function getChatChannelMeta(id: string): ChannelMeta {
  if (id !== BOT_CHAT_CHANNEL_ID) {
    throw new Error(`Unsupported BotChat channel meta lookup: ${id}`);
  }
  return { ...BOT_CHAT_CHANNEL_META };
}
