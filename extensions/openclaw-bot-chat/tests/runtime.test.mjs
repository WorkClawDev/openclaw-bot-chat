import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { promises as fs } from 'node:fs';
import {
  buildBotChatOutboundMessageTarget,
  buildBotChatOutboundPayload,
  buildBotChatStatePath,
  collectBotChatConfigIssues,
  evaluateBotChatAccess,
  getBotChatRuntime,
  hasBotChatConfiguredState,
  inferBotChatTargetChatType,
  isBotChatSenderAllowed,
  normalizeAllowFromEntries,
  normalizeBotChatConfig,
  normalizeBotChatInboundMessage,
  normalizeBotChatTarget,
  normalizeAllowFromEntry,
  parseBotChatTarget,
  resolveBotChatAccount,
  setBotChatRuntime,
  buildBotChatDirectTopic,
  buildBotChatGroupTopic,
  buildBotChatHistoryMessagesUrl,
} from '../src/runtime.ts';
import { inspectBotChatAccount } from '../src/account-inspect.ts';
import {
  botChatPlugin,
  setBotChatSlashCommandResolversForTest,
} from '../src/channel.ts';
import { botChatSetupPlugin } from '../src/channel.setup.ts';
import { botChatDoctor } from '../src/doctor.ts';
import { botChatSecrets } from '../src/secret-config-contract.ts';
import { botChatStatus } from '../src/status.ts';

test('normalizeBotChatConfig falls back to env and defaults', () => {
  const config = normalizeBotChatConfig({}, {
    BOT_CHAT_BACKEND_URL: 'http://localhost:8080',
    BOT_CHAT_BOT_KEY: 'secret-key',
    BOT_CHAT_BOT_ID: 'bot-1',
    BOT_CHAT_MQTT_TCP_URL: 'mqtt://localhost:1883',
    BOT_CHAT_MQTT_WS_URL: 'wss://localhost/mqtt',
  });

  assert.equal(config.backendUrl, 'http://localhost:8080');
  assert.equal(config.botKey, 'secret-key');
  assert.equal(config.botId, 'bot-1');
  assert.equal(config.mqttTcpUrl, 'mqtt://localhost:1883');
  assert.equal(config.mqttWsUrl, 'wss://localhost/mqtt');
  assert.equal(config.historyCatchupLimit, 100);
  assert.equal(config.enabled, true);
});

test('resolveBotChatAccount reads nested channel config', () => {
  const account = resolveBotChatAccount({
    channels: {
      'bot-chat': {
        backendUrl: 'http://backend',
        botKey: 'key',
        botId: 'bot-a',
        allowFrom: ['user-1'],
      },
    },
  });

  assert.equal(account.configured, true);
  assert.equal(account.botId, 'bot-a');
  assert.deepEqual(account.config.allowFrom, ['user-1']);
});

test('hasBotChatConfiguredState reports false when required config missing', () => {
  assert.equal(hasBotChatConfiguredState({ cfg: {} }), false);
  assert.equal(
    hasBotChatConfiguredState({
      cfg: { channels: { 'bot-chat': { backendUrl: 'http://backend', botKey: 'k' } } },
    }),
    true,
  );
});

test('target parser normalizes direct, channel, and raw targets', () => {
  assert.deepEqual(parseBotChatTarget('dm:alice'), {
    kind: 'direct',
    id: 'alice',
    raw: 'dm:alice',
  });
  assert.deepEqual(parseBotChatTarget('channel:conv-1'), {
    kind: 'channel',
    id: 'conv-1',
    raw: 'channel:conv-1',
  });
  assert.deepEqual(parseBotChatTarget('conv-1'), {
    kind: 'channel',
    id: 'conv-1',
    raw: 'conv-1',
  });
  assert.deepEqual(parseBotChatTarget('group:group-1'), {
    kind: 'channel',
    id: 'chat/group/group-1',
    raw: 'group:group-1',
  });
  assert.equal(normalizeBotChatTarget('alice-room'), 'channel:alice-room');
  assert.equal(normalizeBotChatTarget('user:alice'), 'dm:alice');
  assert.equal(inferBotChatTargetChatType('dm:alice'), 'direct');
  assert.equal(inferBotChatTargetChatType('conversation:conv-1'), 'channel');
  assert.throws(() => parseBotChatTarget('   '), /target is required/);
});

test('outbound target builder maps direct and channel targets', () => {
  const account = resolveBotChatAccount({ backendUrl: 'http://b', botKey: 'k', botId: 'bot-a' });
  assert.deepEqual(buildBotChatOutboundMessageTarget({ raw: 'dm:alice', account }), {
    channelId: 'chat/dm/user/alice/bot/bot-a',
    userId: 'alice',
    normalizedTarget: 'dm:alice',
    chatType: 'direct',
    publishTopic: 'chat/dm/user/alice/bot/bot-a',
    recipientType: 'user',
  });
  assert.deepEqual(buildBotChatOutboundMessageTarget({ raw: 'conv-1', account }), {
    channelId: 'conv-1',
    userId: 'bot-a',
    normalizedTarget: 'channel:conv-1',
    chatType: 'channel',
    publishTopic: 'conv-1',
    recipientType: 'user',
  });
  assert.deepEqual(buildBotChatOutboundMessageTarget({ raw: 'group:group-1', account }), {
    channelId: 'chat/group/group-1',
    userId: 'group-1',
    normalizedTarget: 'channel:chat/group/group-1',
    chatType: 'channel',
    publishTopic: 'chat/group/group-1',
    recipientType: 'group',
  });
  assert.deepEqual(buildBotChatOutboundMessageTarget({
    raw: 'channel:chat/dm/user/alice/bot/bot-a',
    account,
  }), {
    channelId: 'chat/dm/user/alice/bot/bot-a',
    userId: 'alice',
    normalizedTarget: 'channel:chat/dm/user/alice/bot/bot-a',
    chatType: 'channel',
    publishTopic: 'chat/dm/user/alice/bot/bot-a',
    recipientType: 'user',
  });
  assert.deepEqual(
    buildBotChatOutboundMessageTarget({
      raw: 'channel:conv-1',
      account,
      metadata: { userId: 'user-a' },
    }),
    {
      channelId: 'conv-1',
      userId: 'user-a',
      normalizedTarget: 'channel:conv-1',
      chatType: 'channel',
      publishTopic: 'conv-1',
      recipientType: 'user',
    },
  );
  assert.equal(buildBotChatDirectTopic('bot-z', 'bot-a'), 'chat/dm/user/bot-z/bot/bot-a');
  assert.equal(buildBotChatGroupTopic('chat/group/existing'), 'chat/group/existing');
});

test('normalize allowFrom strips provider prefixes and empties', () => {
  assert.deepEqual(normalizeAllowFromEntries([' user:alice ', 'sender:bob', '*', '']), [
    'alice',
    'bob',
    '*',
  ]);
  assert.equal(normalizeAllowFromEntry('botchat:carol'), 'carol');
});

test('allowFrom matcher supports explicit ids and wildcard', () => {
  assert.equal(isBotChatSenderAllowed({ allowFrom: ['alice'], userId: 'user:alice' }), true);
  assert.equal(isBotChatSenderAllowed({ allowFrom: ['*'], userId: 'whoever' }), true);
  assert.equal(isBotChatSenderAllowed({ allowFrom: ['alice'], userId: 'bob' }), false);
});

test('access evaluation uses allowFrom as primary gate', () => {
  const denied = evaluateBotChatAccess({
    config: { allowFrom: ['alice'] },
    message: { channelId: 'c1', userId: 'bob', text: 'hello' },
  });
  assert.deepEqual(denied, {
    allowed: false,
    reason: 'sender not approved in allowFrom',
    requiresCustomApproval: false,
  });

  const blocked = evaluateBotChatAccess({
    config: { allowFrom: ['alice'], permissionApprovalEnabled: true },
    message: { channelId: 'c1', userId: 'alice', text: 'hello', metadata: { blocked: true } },
  });
  assert.deepEqual(blocked, {
    allowed: false,
    reason: 'message blocked by metadata',
    requiresCustomApproval: true,
  });
});

test('normalize inbound payload extracts message fields, metadata, and thread hints', () => {
  const message = normalizeBotChatInboundMessage(
    {
      id: 'm1',
      seq: 42,
      conversation_id: 'conv-1',
      thread_id: 'thread-1',
      reply_to_id: 'm0',
      from: { id: 'user-1' },
      content: { body: 'hello', meta: { blocked: false, source: 'test' } },
    },
    'topic/inbound',
  );

  assert.deepEqual(message, {
    channelId: 'conv-1',
    userId: 'user-1',
    text: 'hello',
    metadata: {
      topic: 'topic/inbound',
      message_id: 'm1',
      seq: 42,
      blocked: false,
      source: 'test',
      threadId: 'thread-1',
      replyToId: 'm0',
    },
  });
});

test('normalize inbound payload accepts thread hints from content metadata', () => {
  const message = normalizeBotChatInboundMessage(
    {
      conversation_id: 'conv-1',
      from: { id: 'user-1' },
      content: { body: 'hello', meta: { threadId: 'thread-meta', replyToId: 'm-meta' } },
    },
    'topic/inbound',
  );

  assert.equal(message.metadata.threadId, 'thread-meta');
  assert.equal(message.metadata.replyToId, 'm-meta');
});

test('normalize inbound payload accepts text aliases', () => {
  const contentTextMessage = normalizeBotChatInboundMessage(
    {
      conversation_id: 'conv-1',
      from: { id: 'user-1' },
      content: { text: 'hello from content text' },
    },
    'topic/inbound',
  );
  const topLevelTextMessage = normalizeBotChatInboundMessage(
    {
      conversation_id: 'conv-1',
      from: { id: 'user-1' },
      text: 'hello from top-level text',
    },
    'topic/inbound',
  );

  assert.equal(contentTextMessage.text, 'hello from content text');
  assert.equal(topLevelTextMessage.text, 'hello from top-level text');
});

test('normalize inbound image payload preserves asset metadata and fallback text for replay', () => {
  const message = normalizeBotChatInboundMessage(
    {
      id: 'img-1',
      conversation_id: 'conv-1',
      from: { id: 'user-1' },
      content: {
        type: 'image',
        url: 'https://assets.example/image.png',
        meta: {
          file_name: 'image.png',
          mime_type: 'image/png',
        },
      },
    },
    'topic/inbound',
  );

  assert.deepEqual(message, {
    channelId: 'conv-1',
    userId: 'user-1',
    text: 'image.png',
    metadata: {
      topic: 'topic/inbound',
      content_type: 'image',
      message_id: 'img-1',
      file_name: 'image.png',
      mime_type: 'image/png',
      asset: {
        kind: 'image',
        type: 'image',
        source_url: 'https://assets.example/image.png',
        file_name: 'image.png',
        mime_type: 'image/png',
        content_type: 'image/png',
      },
    },
  });
});

test('outbound payload preserves text, target ids, and thread metadata', () => {
  const payload = JSON.parse(
    buildBotChatOutboundPayload({
      channelId: 'conv-2',
      userId: 'user-2',
      text: 'reply',
      metadata: {
        topic: 'topic/out',
        threadId: 'thread-2',
        replyToId: 'm1',
        message_id: '11111111-2222-4333-8444-555555555555',
        botId: 'bot-2',
        toType: 'group',
        publishTopic: 'internal-topic',
      },
    }),
  );

  assert.equal(payload.conversation_id, 'conv-2');
  assert.equal(payload.id, '11111111-2222-4333-8444-555555555555');
  assert.equal(payload.thread_id, 'thread-2');
  assert.equal(payload.reply_to_id, 'm1');
  assert.equal(payload.from.id, 'bot-2');
  assert.equal(payload.to.type, 'group');
  assert.equal(payload.to.id, 'user-2');
  assert.equal(payload.content.body, 'reply');
  assert.equal(payload.content.meta.topic, 'topic/out');
  assert.equal(payload.content.meta.message_id, '11111111-2222-4333-8444-555555555555');
  assert.equal('botId' in payload.content.meta, false);
  assert.equal('toType' in payload.content.meta, false);
  assert.equal('publishTopic' in payload.content.meta, false);
});

test('outbound group payload addresses the group id instead of the sender id', () => {
  const payload = JSON.parse(
    buildBotChatOutboundPayload({
      channelId: 'chat/group/group-1',
      userId: 'alice',
      text: 'reply',
      metadata: {
        message_id: '11111111-2222-4333-8444-555555555555',
        botId: 'bot-2',
        toType: 'group',
      },
    }),
  );

  assert.equal(payload.conversation_id, 'chat/group/group-1');
  assert.equal(payload.from.id, 'bot-2');
  assert.equal(payload.to.type, 'group');
  assert.equal(payload.to.id, 'group-1');
});

test('outbound image payload prefers hydrated asset urls over source_url', () => {
  const payload = JSON.parse(
    buildBotChatOutboundPayload({
      channelId: 'conv-2',
      userId: 'user-2',
      text: 'image caption',
      metadata: {
        content_type: 'image',
        asset: {
          id: 'asset-1',
          download_url: 'https://assets.example/image.png?sig=ok',
          source_url: '/tmp/local-image.png',
        },
      },
    }),
  );

  assert.equal(payload.content.type, 'image');
  assert.equal(payload.content.url, 'https://assets.example/image.png?sig=ok');
});

test('state path stays scoped by bot id', () => {
  assert.equal(
    buildBotChatStatePath({ stateDir: './data', botId: 'bot-z' }),
    'data/botchat-bot-z-state.json',
  );
});

test('diagnostics report errors and warnings without leaking secrets', () => {
  const issues = collectBotChatConfigIssues({
    botKey: 'super-secret',
    historyCatchupLimit: 0,
    permissionApprovalEnabled: true,
  });
  assert.deepEqual(
    issues.map((issue) => [issue.severity, issue.code, issue.path]),
    [
      ['error', 'missing_backend_url', 'backendUrl'],
      ['error', 'invalid_history_catchup_limit', 'historyCatchupLimit'],
      ['warning', 'approval_without_handler', 'permissionApprovalEnabled'],
      ['warning', 'empty_allow_from', 'allowFrom'],
    ],
  );
  assert.equal(JSON.stringify(issues).includes('super-secret'), false);
});

test('diagnostics accept configured botKey secret refs without leaking ref values', () => {
  const issues = collectBotChatConfigIssues({
    backendUrl: 'http://backend',
    botKey: { source: 'env', provider: 'default', id: 'BOT_CHAT_BOT_KEY' },
    allowFrom: ['alice'],
  });

  assert.equal(issues.some((issue) => issue.code === 'missing_bot_key'), false);
  assert.equal(JSON.stringify(issues).includes('BOT_CHAT_BOT_KEY'), false);
});

test('status snapshot exposes safe operational fields', () => {
  const snapshot = botChatStatus.getSnapshot({
    cfg: {
      backendUrl: 'http://backend',
      botKey: 'secret',
      botId: 'bot-a',
      stateDir: './data',
      defaultTo: 'channel:main',
      allowFrom: ['alice', 'bob'],
      historyCatchupLimit: 10,
    },
    runtimeState: { connected: true },
  });

  assert.equal(snapshot.connected, true);
  assert.equal(snapshot.approvalMode, 'pairing');
  assert.equal(snapshot.allowFromCount, 2);
  assert.equal(snapshot.hasDefaultTo, true);
  assert.equal(snapshot.historyCatchupLimit, 10);
  assert.equal(snapshot.statePathConfigured, true);
  assert.equal(JSON.stringify(snapshot).includes('secret'), false);
});

test('botChatPlugin exposes formal channel plugin surface', () => {
  assert.equal(botChatPlugin.id, 'bot-chat');
  assert.equal(botChatPlugin.meta.label, 'BotChat');
  assert.deepEqual(botChatPlugin.capabilities.chatTypes, ['direct', 'channel']);
  assert.equal(botChatPlugin.capabilities.threads, false);
  assert.equal(botChatPlugin.capabilities.nativeCommands, true);
  assert.equal(botChatPlugin.commands.nativeCommandsAutoEnabled, true);
  assert.equal(botChatPlugin.commands.nativeSkillsAutoEnabled, true);
  assert.ok(botChatPlugin.config);
  assert.ok(botChatPlugin.setup);
  assert.ok(botChatPlugin.status);
  assert.ok(botChatPlugin.gateway);
  assert.ok(botChatPlugin.outbound);
  assert.ok(botChatPlugin.doctor);
  assert.ok(botChatPlugin.secrets);
  assert.ok(botChatPlugin.allowlist);
  assert.ok(botChatPlugin.pairing);
  assert.equal(botChatPlugin.messaging.normalizeTarget('dm:alice'), 'dm:alice');
  assert.equal(botChatPlugin.messaging.normalizeTarget('conv-1'), 'channel:conv-1');
  assert.equal(botChatPlugin.messaging.inferTargetChatType({ to: 'dm:alice' }), 'direct');
  assert.equal(botChatPlugin.approvalCapability.mode, 'pairing');
  assert.equal(botChatPlugin.approvalCapability.secondaryGate, 'custom-approval');
  assert.equal(botChatPlugin.security.mode, 'allowFrom');
});

test('gateway publishes retained slash command catalog from OpenClaw registries', async () => {
  const originalRuntime = getBotChatRuntime();
  const sent = [];
  setBotChatRuntime({
    async start() {},
    async stop() {},
    async onInboundMessage() {},
    async sendToChannel(message) {
      sent.push(message);
      return { messageId: `catalog-${sent.length}` };
    },
  });
  setBotChatSlashCommandResolversForTest({
    listSkillCommandsForAgents() {
      return [
        {
          name: 'skill-run',
          description: 'Run a skill',
          args: [{ name: 'skill', required: true }],
        },
      ];
    },
    listNativeCommandSpecsForConfig(_cfg, params) {
      assert.equal(params.provider, 'bot-chat');
      assert.equal(params.skillCommands.length, 1);
      return [
        {
          name: '/help',
          summary: 'Show help',
          options: [{ name: 'topic', type: 'string' }],
        },
        {
          nativeName: 'skill-run',
          description: 'Duplicate skill command from native registry',
        },
      ];
    },
    getPluginCommandSpecs(provider, options) {
      assert.equal(provider, 'bot-chat');
      assert.equal(options.config.botId, 'bot-a');
      return [
        {
          command: '/plugin-do',
          description: 'Run plugin command',
        },
      ];
    },
  });

  try {
    await botChatPlugin.gateway.startAccount({
      cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
      account: resolveBotChatAccount({
        backendUrl: 'http://backend',
        botKey: 'key',
        botId: 'bot-a',
      }),
    });
  } finally {
    setBotChatRuntime(originalRuntime);
    setBotChatSlashCommandResolversForTest(undefined);
  }

  assert.equal(sent.length, 1);
  assert.equal(sent[0].channelId, 'control/bot-chat/slash-commands');
  assert.equal(sent[0].userId, '*');
  assert.equal(sent[0].text, 'slash_commands');
  assert.deepEqual(sent[0].metadata.slash_commands, [
    {
      name: 'help',
      description: 'Show help',
      acceptsArgs: true,
      args: [{ name: 'topic', type: 'string' }],
    },
    {
      name: 'skill-run',
      description: 'Duplicate skill command from native registry',
      acceptsArgs: false,
      args: undefined,
    },
    {
      name: 'plugin-do',
      description: 'Run plugin command',
      acceptsArgs: false,
      args: undefined,
    },
  ]);
  assert.equal(sent[0].metadata.content_type, 'slash_commands');
  assert.equal(sent[0].metadata.retain, true);
});

test('gateway publishes plugin slash commands when native registry is unavailable', async () => {
  const originalRuntime = getBotChatRuntime();
  const sent = [];
  setBotChatRuntime({
    async start() {},
    async stop() {},
    async onInboundMessage() {},
    async sendToChannel(message) {
      sent.push(message);
      return { messageId: `catalog-${sent.length}` };
    },
  });
  setBotChatSlashCommandResolversForTest({
    listNativeCommandSpecsForConfig() {
      throw new Error('native registry failed');
    },
    getPluginCommandSpecs() {
      return [
        {
          name: 'plugin-only',
          description: 'Available without native command registry',
        },
      ];
    },
  });

  try {
    await botChatPlugin.gateway.startAccount({
      cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
      account: resolveBotChatAccount({
        backendUrl: 'http://backend',
        botKey: 'key',
        botId: 'bot-a',
      }),
    });
  } finally {
    setBotChatRuntime(originalRuntime);
    setBotChatSlashCommandResolversForTest(undefined);
  }

  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0].metadata.slash_commands, [
    {
      name: 'plugin-only',
      description: 'Available without native command registry',
      acceptsArgs: false,
      args: undefined,
    },
  ]);
});

test('gateway handles slash autocomplete requests without dispatching a chat reply', async () => {
  const originalRuntime = getBotChatRuntime();
  let capturedHooks;
  const sent = [];
  setBotChatRuntime({
    async start(_config, _logger, hooks) {
      capturedHooks = hooks;
    },
    async stop() {},
    async onInboundMessage() {},
    async sendToChannel(message) {
      sent.push(message);
      return { messageId: `autocomplete-${sent.length}` };
    },
  });
  setBotChatSlashCommandResolversForTest({
    listNativeCommandSpecsForConfig() {
      return [
        {
          name: 'models',
          args: [
            {
              name: 'model',
              choices: [
                { label: 'GPT-4o', value: 'gpt-4o', description: 'fast multimodal' },
                { label: 'Claude', value: 'claude' },
              ],
            },
          ],
        },
      ];
    },
    resolveNativeCommandAutocomplete(params) {
      assert.equal(params.provider, 'bot-chat');
      assert.equal(params.commandName, 'models');
      assert.equal(params.argName, 'model');
      assert.equal(params.argIndex, 0);
      assert.equal(params.partial, 'g');
      return [
        { label: 'GPT-4.1', value: 'gpt-4.1', description: 'larger model' },
        { label: 'GPT-4o', value: 'gpt-4o', description: 'duplicate from dynamic' },
      ];
    },
  });

  const dispatchCalls = [];
  try {
    await botChatPlugin.gateway.startAccount({
      cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
      account: resolveBotChatAccount({
        backendUrl: 'http://backend',
        botKey: 'key',
        botId: 'bot-a',
      }),
      channelRuntime: {
        reply: {
          async dispatchReplyWithBufferedBlockDispatcher(params) {
            dispatchCalls.push(params);
          },
        },
      },
    });
    sent.length = 0;
    await capturedHooks.emitMessage({
      channelId: 'control/bot-chat/slash-autocomplete/request',
      userId: 'alice',
      text: 'slash_autocomplete_request',
      metadata: {
        topic: 'control/bot-chat/slash-autocomplete/request',
        senderType: 'user',
        content_type: 'slash_autocomplete_request',
        request_id: 'req-1',
        response_topic: 'control/bot-chat/slash-autocomplete/response/user/alice',
        command_name: 'models',
        arg_name: 'model',
        arg_index: 0,
        partial: 'g',
      },
    });
  } finally {
    setBotChatRuntime(originalRuntime);
    setBotChatSlashCommandResolversForTest(undefined);
  }

  assert.equal(dispatchCalls.length, 0);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].channelId, 'control/bot-chat/slash-autocomplete/response/user/alice');
  assert.equal(sent[0].metadata.content_type, 'slash_autocomplete_response');
  assert.equal(sent[0].metadata.request_id, 'req-1');
  assert.deepEqual(sent[0].metadata.choices, [
    { label: 'GPT-4.1', value: 'gpt-4.1', description: 'larger model' },
    { label: 'GPT-4o', value: 'gpt-4o', description: 'duplicate from dynamic' },
  ]);
});

test('account inspector reports botKey source without leaking describe snapshots', () => {
  const fromConfig = inspectBotChatAccount({
    cfg: { backendUrl: 'http://backend', botKey: 'secret-key', name: 'Configured BotChat' },
  });
  assert.equal(fromConfig.accountId, 'default');
  assert.equal(fromConfig.botKeySource, 'config');
  assert.equal(fromConfig.botKeyStatus, 'available');
  assert.equal(fromConfig.configured, true);

  const fromEnv = inspectBotChatAccount({
    cfg: { backendUrl: 'http://backend' },
    envBotKey: 'env-secret',
  });
  assert.equal(fromEnv.botKeySource, 'env');
  assert.equal(fromEnv.botKeyStatus, 'available');
  assert.equal(fromEnv.configured, true);

  const fromSecretRef = inspectBotChatAccount({
    cfg: {
      backendUrl: 'http://backend',
      botKey: { source: 'env', provider: 'default', id: 'BOT_CHAT_BOT_KEY' },
    },
  });
  assert.equal(fromSecretRef.botKeySource, 'config');
  assert.equal(fromSecretRef.botKeyStatus, 'configured_unavailable');
  assert.equal(fromSecretRef.configured, true);
  assert.equal(
    JSON.stringify(botChatPlugin.config.describeAccount(resolveBotChatAccount(fromConfig.config))).includes('secret-key'),
    false,
  );
});

test('doctor adapter maps config issues into formal warnings', async () => {
  const warnings = await botChatDoctor.collectPreviewWarnings({
    cfg: { backendUrl: 'http://backend', botKey: 'secret-key', allowFrom: [] },
    doctorFixCommand: 'openclaw doctor --fix',
  });
  assert.deepEqual(warnings, [
    '- BotChat warning empty_allow_from at allowFrom: allowFrom is empty; BotChat currently allows all senders until pairing writes allowFrom entries',
  ]);

  const sequence = await botChatDoctor.runConfigSequence({
    cfg: { historyCatchupLimit: 0 },
    env: {},
    shouldRepair: false,
  });
  assert.ok(sequence.warningNotes.some((note) => note.includes('missing_backend_url')));
  assert.ok(sequence.warningNotes.some((note) => note.includes('missing_bot_key')));
});

test('botKey secrets contract registers and collects secret refs', () => {
  assert.deepEqual(botChatSecrets.secretTargetRegistryEntries.map((entry) => entry.id), [
    'channels.bot-chat.botKey',
  ]);

  const cfg = {
    channels: {
      'bot-chat': {
        backendUrl: 'http://backend',
        botKey: { source: 'env', provider: 'default', id: 'BOT_CHAT_BOT_KEY' },
      },
    },
  };
  const context = { assignments: [] };
  botChatSecrets.collectRuntimeConfigAssignments({ config: cfg, context });

  assert.equal(context.assignments.length, 1);
  assert.equal(context.assignments[0].path, 'channels.bot-chat.botKey');
  assert.equal(context.assignments[0].expected, 'string');
  context.assignments[0].apply('resolved-secret');
  assert.equal(cfg.channels['bot-chat'].botKey, 'resolved-secret');
});

test('outbound adapter uses parsed BotChat target mapping', async () => {
  const originalRuntime = getBotChatRuntime();
  const sent = [];
  setBotChatRuntime({
    async start() {},
    async stop() {},
    async onInboundMessage() {},
    async sendToChannel(message) {
      sent.push(message);
      return { messageId: `msg-${sent.length}` };
    },
  });

  try {
    await botChatPlugin.outbound.sendText({
      cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
      to: 'dm:alice',
      text: 'hello direct',
    });
    await botChatPlugin.outbound.sendText({
      cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
      to: 'channel:conv-1',
      text: 'hello channel',
      metadata: { userId: 'user-a' },
    });
  } finally {
    setBotChatRuntime(originalRuntime);
  }

  assert.deepEqual(sent, [
    {
      channelId: 'chat/dm/user/alice/bot/bot-a',
      userId: 'alice',
      text: 'hello direct',
      metadata: {
        target: 'dm:alice',
        chatType: 'direct',
        botId: 'bot-a',
        toType: 'user',
        publishTopic: 'chat/dm/user/alice/bot/bot-a',
      },
    },
    {
      channelId: 'conv-1',
      userId: 'user-a',
      text: 'hello channel',
      metadata: {
        userId: 'user-a',
        target: 'channel:conv-1',
        chatType: 'channel',
        botId: 'bot-a',
        toType: 'user',
        publishTopic: 'conv-1',
      },
    },
  ]);
});

test('outbound adapter strips MEDIA lines from text and imports local media before sendMedia', async () => {
  const originalRuntime = getBotChatRuntime();
  const originalFetch = globalThis.fetch;
  const sent = [];
  const fetchCalls = [];
  const tempFile = path.join(os.tmpdir(), `botchat-media-${Date.now()}.png`);

  await fs.writeFile(tempFile, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  setBotChatRuntime({
    async start() {},
    async stop() {},
    async onInboundMessage() {},
    async sendToChannel(message) {
      sent.push(message);
      return { messageId: `msg-${sent.length}` };
    },
  });
  globalThis.fetch = async (url, init = {}) => {
    fetchCalls.push({ url, init });
    return {
      ok: true,
      async json() {
        return {
          data: {
            id: 'asset-1',
            kind: 'image',
            mime_type: 'image/png',
            content_type: 'image/png',
            file_name: 'reply.png',
            download_url: 'https://assets.example/reply.png?sig=ok',
          },
        };
      },
    };
  };

  try {
    await botChatPlugin.outbound.sendText({
      cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
      to: 'dm:alice',
      text: `caption\nMEDIA:${tempFile}`,
    });
    await botChatPlugin.outbound.sendMedia({
      cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
      to: 'dm:alice',
      text: '',
      mediaUrl: tempFile,
    });
  } finally {
    globalThis.fetch = originalFetch;
    setBotChatRuntime(originalRuntime);
    await fs.rm(tempFile, { force: true });
  }

  assert.equal(fetchCalls.length, 1);
  assert.equal(fetchCalls[0].url, 'http://backend/api/v1/bot-runtime/assets/image/import');
  const importPayload = JSON.parse(fetchCalls[0].init.body);
  assert.equal(importPayload.file_name.endsWith('.png'), true);
  assert.equal(importPayload.content_type, 'image/png');
  assert.equal(importPayload.data_url.startsWith('data:image/png;base64,'), true);

  assert.deepEqual(sent, [
    {
      channelId: 'chat/dm/user/alice/bot/bot-a',
      userId: 'alice',
      text: 'caption',
      metadata: {
        target: 'dm:alice',
        chatType: 'direct',
        botId: 'bot-a',
        toType: 'user',
        publishTopic: 'chat/dm/user/alice/bot/bot-a',
      },
    },
    {
      channelId: 'chat/dm/user/alice/bot/bot-a',
      userId: 'alice',
      text: 'reply.png',
      metadata: {
        content_type: 'image',
        asset: {
          id: 'asset-1',
          kind: 'image',
          mime_type: 'image/png',
          content_type: 'image/png',
          file_name: 'reply.png',
          download_url: 'https://assets.example/reply.png?sig=ok',
        },
        target: 'dm:alice',
        chatType: 'direct',
        botId: 'bot-a',
        toType: 'user',
        publishTopic: 'chat/dm/user/alice/bot/bot-a',
      },
    },
  ]);
});

test('gateway startAccount returns stop handle when host has no abort signal', async () => {
  const originalRuntime = getBotChatRuntime();
  let stopped = false;
  setBotChatRuntime({
    async start() {},
    async stop() {
      stopped = true;
    },
    async onInboundMessage() {},
    async sendToChannel() {
      return { messageId: 'reply-1' };
    },
  });

  try {
    const result = await botChatPlugin.gateway.startAccount({
      cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
      account: resolveBotChatAccount({
        backendUrl: 'http://backend',
        botKey: 'key',
        botId: 'bot-a',
      }),
    });
    assert.equal(typeof result?.stop, 'function');
    await result.stop();
    assert.equal(stopped, true);
  } finally {
    setBotChatRuntime(originalRuntime);
  }
});

test('gateway replies do not reuse inbound message ids', async () => {
  const originalRuntime = getBotChatRuntime();
  let capturedHooks;
  const sent = [];
  setBotChatRuntime({
    async start(_config, _logger, hooks) {
      capturedHooks = hooks;
    },
    async stop() {},
    async onInboundMessage() {},
    async sendToChannel(message) {
      sent.push(message);
      return { messageId: `reply-${sent.length}` };
    },
  });

  const abort = new AbortController();
  const dispatchCalls = [];
  const startPromise = botChatPlugin.gateway.startAccount({
    cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
    account: resolveBotChatAccount({
      backendUrl: 'http://backend',
      botKey: 'key',
      botId: 'bot-a',
    }),
    abortSignal: abort.signal,
    channelRuntime: {
      reply: {
        async dispatchReplyWithBufferedBlockDispatcher(params) {
          dispatchCalls.push(params);
          await params.dispatcherOptions.deliver(
            { text: 'agent reply' },
            { kind: 'final' },
          );
        },
      },
    },
  });

  try {
    await new Promise((resolve) => setImmediate(resolve));
    await capturedHooks.emitMessage({
      channelId: 'chat/dm/user/alice/bot/bot-a',
      userId: 'alice',
      text: 'hi',
      metadata: {
        topic: 'chat/dm/user/alice/bot/bot-a',
        message_id: 'user-message-1',
        seq: 7,
        senderType: 'user',
      },
    });
  } finally {
    abort.abort();
    await startPromise;
    setBotChatRuntime(originalRuntime);
  }

  assert.equal(dispatchCalls.length, 1);
  assert.equal(dispatchCalls[0].ctx.Body, 'hi');
  assert.equal(dispatchCalls[0].ctx.CommandSource, 'text');
  assert.deepEqual(sent, [
    {
      channelId: 'chat/dm/user/alice/bot/bot-a',
      userId: 'alice',
      text: 'agent reply',
      metadata: {
        topic: 'chat/dm/user/alice/bot/bot-a',
        replyToId: 'user-message-1',
        botId: 'bot-a',
        toType: 'user',
        publishTopic: 'chat/dm/user/alice/bot/bot-a',
      },
    },
  ]);
});

test('gateway replies to group messages as group-addressed messages', async () => {
  const originalRuntime = getBotChatRuntime();
  let capturedHooks;
  const sent = [];
  setBotChatRuntime({
    async start(_config, _logger, hooks) {
      capturedHooks = hooks;
    },
    async stop() {},
    async onInboundMessage() {},
    async sendToChannel(message) {
      sent.push(message);
      return { messageId: `reply-${sent.length}` };
    },
  });

  const abort = new AbortController();
  const dispatchCalls = [];
  const account = resolveBotChatAccount({
    backendUrl: 'http://backend',
    botKey: 'key',
    botId: 'bot-a',
  });
  const startPromise = botChatPlugin.gateway.startAccount({
    cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
    account,
    abortSignal: abort.signal,
    channelRuntime: {
      reply: {
        async dispatchReplyWithBufferedBlockDispatcher(params) {
          dispatchCalls.push(params);
          await params.dispatcherOptions.deliver(
            { text: 'group reply' },
            { kind: 'final' },
          );
        },
      },
    },
  });

  try {
    await new Promise((resolve) => setImmediate(resolve));
    await capturedHooks.emitMessage({
      channelId: 'chat/group/group-1',
      userId: 'alice',
      text: '@OpenClaw hi',
      metadata: {
        topic: 'chat/group/group-1',
        message_id: 'group-message-1',
        senderType: 'user',
        mentioned_bot_ids: ['bot-a'],
      },
    });
  } finally {
    abort.abort();
    await startPromise;
    setBotChatRuntime(originalRuntime);
  }

  assert.equal(dispatchCalls.length, 1);
  assert.equal(dispatchCalls[0].ctx.ChatType, 'group');
  assert.deepEqual(dispatchCalls[0].replyOptions, {
    sourceReplyDeliveryMode: 'automatic',
  });
  assert.deepEqual(sent, [
    {
      channelId: 'chat/group/group-1',
      userId: 'group-1',
      text: 'group reply',
      metadata: {
        topic: 'chat/group/group-1',
        mentioned_bot_ids: ['bot-a'],
        replyToId: 'group-message-1',
        botId: 'bot-a',
        toType: 'group',
        publishTopic: 'chat/group/group-1',
      },
    },
  ]);
});

test('gateway dispatch marks autocomplete slash commands as native commands', async () => {
  const originalRuntime = getBotChatRuntime();
  let capturedHooks;
  setBotChatRuntime({
    async start(_config, _logger, hooks) {
      capturedHooks = hooks;
    },
    async stop() {},
    async onInboundMessage() {},
    async sendToChannel() {
      return { messageId: 'unused-reply' };
    },
  });

  const abort = new AbortController();
  const dispatchCalls = [];
  const startPromise = botChatPlugin.gateway.startAccount({
    cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
    account: resolveBotChatAccount({
      backendUrl: 'http://backend',
      botKey: 'key',
      botId: 'bot-a',
    }),
    abortSignal: abort.signal,
    channelRuntime: {
      reply: {
        async dispatchReplyWithBufferedBlockDispatcher(params) {
          dispatchCalls.push(params);
        },
      },
    },
  });

  try {
    await new Promise((resolve) => setImmediate(resolve));
    await capturedHooks.emitMessage({
      channelId: 'chat/dm/user/alice/bot/bot-a',
      userId: 'alice',
      text: '/help',
      metadata: {
        message_id: 'command-message-1',
        senderType: 'user',
        command_source: 'native',
        native_command_name: 'help',
      },
    });
  } finally {
    abort.abort();
    await startPromise;
    setBotChatRuntime(originalRuntime);
  }

  assert.equal(dispatchCalls.length, 1);
  assert.equal(dispatchCalls[0].ctx.CommandBody, '/help');
  assert.equal(dispatchCalls[0].ctx.CommandSource, 'native');
  assert.equal(dispatchCalls[0].ctx.CommandAuthorized, true);
});

test('gateway dispatch includes BotChat image assets as attachments', async () => {
  const originalRuntime = getBotChatRuntime();
  let capturedHooks;
  setBotChatRuntime({
    async start(_config, _logger, hooks) {
      capturedHooks = hooks;
    },
    async stop() {},
    async onInboundMessage() {},
    async sendToChannel() {
      return { messageId: 'unused-reply' };
    },
  });

  const abort = new AbortController();
  const dispatchCalls = [];
  const startPromise = botChatPlugin.gateway.startAccount({
    cfg: { backendUrl: 'http://backend', botKey: 'key', botId: 'bot-a' },
    account: resolveBotChatAccount({
      backendUrl: 'http://backend',
      botKey: 'key',
      botId: 'bot-a',
    }),
    abortSignal: abort.signal,
    channelRuntime: {
      reply: {
        async dispatchReplyWithBufferedBlockDispatcher(params) {
          dispatchCalls.push(params);
        },
      },
    },
  });

  try {
    await new Promise((resolve) => setImmediate(resolve));
    await capturedHooks.emitMessage({
      channelId: 'chat/dm/user/alice/bot/bot-a',
      userId: 'alice',
      text: 'photo.png',
      metadata: {
        topic: 'chat/dm/user/alice/bot/bot-a',
        message_id: 'image-message-1',
        senderType: 'user',
        content_type: 'image',
        asset: {
          id: 'asset-1',
          kind: 'image',
          file_name: 'photo.png',
          mime_type: 'image/png',
          size: 1234,
          download_url: 'https://assets.example/openclaw-assets/photo.png?signature=ok',
        },
      },
    });
  } finally {
    abort.abort();
    await startPromise;
    setBotChatRuntime(originalRuntime);
  }

  assert.equal(dispatchCalls.length, 1);
  const ctx = dispatchCalls[0].ctx;
  assert.equal(
    ctx.Body,
    '<media:image> Attachment URL: https://assets.example/openclaw-assets/photo.png?signature=ok',
  );
  assert.equal(ctx.BodyForAgent, ctx.Body);
  assert.equal(ctx.RawBody, '');
  assert.equal(ctx.CommandBody, '');
  assert.equal(ctx.BodyForCommands, '');
  assert.equal(ctx.MediaUrl, 'https://assets.example/openclaw-assets/photo.png?signature=ok');
  assert.deepEqual(ctx.MediaUrls, ['https://assets.example/openclaw-assets/photo.png?signature=ok']);
  assert.equal(ctx.MediaType, 'image/png');
  assert.deepEqual(ctx.MediaTypes, ['image/png']);
  assert.equal(ctx.HasAttachments, true);
  assert.equal(ctx.AttachmentCount, 1);
  assert.deepEqual(ctx.Attachments, ctx.attachments);
  assert.deepEqual(ctx.Media, ctx.media);
  assert.deepEqual(ctx.Attachments, [
    {
      type: 'image',
      kind: 'image',
      url: 'https://assets.example/openclaw-assets/photo.png?signature=ok',
      name: 'photo.png',
      fileName: 'photo.png',
      mimeType: 'image/png',
      contentType: 'image/png',
      size: 1234,
      asset: {
        id: 'asset-1',
        kind: 'image',
        file_name: 'photo.png',
        mime_type: 'image/png',
        size: 1234,
        download_url: 'https://assets.example/openclaw-assets/photo.png?signature=ok',
      },
    },
  ]);
});

test('history catchup URL uses bot-runtime endpoint', () => {
  assert.equal(
    buildBotChatHistoryMessagesUrl({
      backendUrl: 'http://backend/',
      conversationId: 'chat/group/group-1',
      afterSeq: 7,
      limit: 10,
    }),
    'http://backend/api/v1/bot-runtime/messages/chat%2Fgroup%2Fgroup-1?limit=10&after_seq=7',
  );
});

test('pairing and allowlist adapters normalize sender ids consistently', async () => {
  assert.equal(botChatPlugin.pairing.text.normalizeAllowEntry('user:alice'), 'alice');
  assert.equal(
    botChatPlugin.allowlist.isAllowed({ cfg: { allowFrom: ['user:alice'] }, userId: 'alice' }),
    true,
  );
  await botChatPlugin.pairing.text.notify({ cfg: {}, id: 'alice', message: 'approved' });
});

test('botChatSetupPlugin keeps setup-capable base surface only', () => {
  assert.equal(botChatSetupPlugin.id, 'bot-chat');
  assert.ok(botChatSetupPlugin.setup);
  assert.ok(botChatSetupPlugin.config);
  assert.equal('gateway' in botChatSetupPlugin, false);
});
