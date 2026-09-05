import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(testDir, '..');

function read(file) {
  return fs.readFileSync(path.join(root, file), 'utf8');
}

function readJson(file) {
  return JSON.parse(read(file));
}

test('entry source uses bundled channel entry contract', () => {
  const source = read('index.ts');
  assert.match(source, /defineBundledChannelEntry/);
  assert.match(source, /channel-plugin-api\.js/);
  assert.match(source, /runtime-api\.js/);
  assert.match(source, /accountInspect/);
  assert.match(source, /secret-config-contract-api\.js/);
});

test('setup entry source uses bundled channel setup entry contract without MQTT runtime', () => {
  const source = read('setup-entry.ts');
  assert.match(source, /defineBundledChannelSetupEntry/);
  assert.doesNotMatch(source, /defineBundledSetupEntry/);
  assert.match(source, /setup-plugin-api\.js/);
  assert.match(source, /secret-config-contract-api\.js/);
  assert.doesNotMatch(source, /runtime-api\.js/);
  assert.doesNotMatch(source, /from ["']mqtt["']/);
});

test('setup plugin barrel does not statically import MQTT runtime', () => {
  const setupPlugin = read('src/channel.setup.ts');
  const shared = read('src/shared.ts');
  const configured = read('configured-state.ts');
  assert.doesNotMatch(setupPlugin, /from ["']\.\/runtime\.js["']/);
  assert.doesNotMatch(shared, /from ["']\.\/runtime\.js["']/);
  assert.doesNotMatch(configured, /from ["'].*runtime\.js["']/);
  assert.match(shared, /import\("\.\/runtime\.js"\)/);
});

test('manifest matches top-level bundled channel shape', () => {
  const manifest = readJson('openclaw.plugin.json');
  assert.equal(manifest.id, 'bot-chat');
  assert.equal(manifest.name, 'BotChat');
  assert.match(manifest.description, /BotChat/);
  assert.deepEqual(manifest.channels, ['bot-chat']);
  assert.ok(manifest.channelEnvVars['bot-chat'].includes('BOT_CHAT_BOT_KEY'));
  assert.deepEqual(manifest.channelEnvVars['bot-chat'], [
    'BOT_CHAT_BACKEND_URL',
    'BOT_CHAT_BOT_KEY',
    'BOT_CHAT_BOT_ID',
    'BOT_CHAT_MQTT_TCP_URL',
    'BOT_CHAT_MQTT_WS_URL',
  ]);
  assert.ok(manifest.configSchema.properties.mqttWsUrl);
  assert.ok(manifest.configSchema.properties.taskPollingIntervalMs);
  assert.equal(manifest.configSchema.type, 'object');
  assert.equal(manifest.configSchema.additionalProperties, false);
  assert.equal(manifest.channelConfigs, undefined);
  assert.deepEqual(manifest.doctorContract, {
    configRepair: true,
    stateMigrations: true,
  });
});

test('package metadata advertises setup fields and configured state', () => {
  const pkg = readJson('package.json');
  assert.equal(pkg.name, '@workclawdev/extension-bot-chat');
  assert.equal(pkg.private, undefined);
  assert.equal(pkg.openclaw.extensions[0], './dist/index.js');
  assert.equal(pkg.openclaw.setupEntry, './dist/setup-entry.js');
  assert.equal(pkg.openclaw.channel.id, 'bot-chat');
  assert.equal(pkg.openclaw.channel.configuredState.specifier, './dist/configured-state.js');
  assert.equal(pkg.openclaw.compat.pluginApi, '>=2026.5.26');
  assert.equal(pkg.openclaw.install.minHostVersion, '>=2026.5.26');
  assert.equal(pkg.openclaw.install.npmSpec, '@workclawdev/extension-bot-chat');
  assert.equal(pkg.openclaw.bundle, undefined);
  assert.equal(pkg.publishConfig.access, 'public');
  assert.equal(pkg.bin['openclaw-bot-chat'], 'dist/src/bin/setup.js');

  const fields = pkg.openclaw.channel.setup.fields;
  assert.deepEqual(fields.map((field) => field.key), [
    'backendUrl',
    'botKey',
    'botId',
    'mqttTcpUrl',
    'mqttWsUrl',
    'useEnv',
  ]);
  const botKey = fields.find((field) => field.key === 'botKey');
  assert.equal(botKey.sensitive, true);
  const useEnv = fields.find((field) => field.key === 'useEnv');
  assert.deepEqual(useEnv.envVars, [
    'BOT_CHAT_BACKEND_URL',
    'BOT_CHAT_BOT_KEY',
    'BOT_CHAT_BOT_ID',
    'BOT_CHAT_MQTT_TCP_URL',
    'BOT_CHAT_MQTT_WS_URL',
  ]);
});
