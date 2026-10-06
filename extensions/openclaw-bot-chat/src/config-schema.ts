export const BotChatChannelConfigSchema: Record<string, unknown> = {
  type: 'object',
  additionalProperties: false,
  properties: {
    enabled: { type: 'boolean' },
    name: { type: 'string', minLength: 1 },
    backendUrl: { type: 'string', minLength: 1 },
    botKey: { type: 'string', minLength: 1 },
    botId: { type: 'string', minLength: 1 },
    mqttTcpUrl: { type: 'string', minLength: 1 },
    mqttWsUrl: { type: 'string', minLength: 1 },
    stateDir: { type: 'string', minLength: 1 },
    historyCatchupLimit: { type: 'number', minimum: 1, maximum: 1000 },
    defaultTo: { type: 'string', minLength: 1 },
    allowFrom: { type: 'array', items: { type: 'string', minLength: 1 } },
    permissionApprovalEnabled: { type: 'boolean' },
    permissionApprovalHandler: { type: 'string', minLength: 1 },
    permissionApprovalUrl: { type: 'string', minLength: 1 },
    permissionApprovalTimeoutMs: { type: 'number', minimum: 1 },
    permissionDeniedReply: { type: 'string', minLength: 1 },
    taskPollingIntervalMs: { type: 'number', minimum: 1000 },
  },
};

export function buildBotChatManifestConfigSchema(): Record<string, unknown> {
  return JSON.parse(JSON.stringify(BotChatChannelConfigSchema)) as Record<string, unknown>;
}
