// Run only against an isolated database. Creates disposable accounts and an
// administrator through the operator CLI, never through the public API.
import { randomBytes, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import mqtt from 'mqtt';
import { api, assert, sleep, root } from './lib.mjs';

const base = process.env.MQTTS_TEST_API_URL || 'http://127.0.0.1:18081';
const cli = process.env.MQTTS_TEST_ADMIN_CLI;
assert(cli, 'Set MQTTS_TEST_ADMIN_CLI to the admin-user binary for the isolated database');
const clients = [];
const results = [];
const pass = message => { results.push(message); console.log(`PASS ${message}`); };
const call = (actor, method, path, body) => api(base, method, `/api/v1${path}`, { token: actor?.tokens.access_token, body });
async function denied(operation, status) {
  try { await operation(); } catch (error) { assert(error.status === status, `Expected HTTP ${status}, got ${error.status}`); return; }
  throw new Error(`Expected HTTP ${status}, operation succeeded`);
}
async function account(label) {
  const username = `acl_${label}_${randomBytes(5).toString('hex')}`;
  const password = randomBytes(24).toString('hex');
  const result = await call(null, 'POST', '/auth/register', { username, email: `${username}@example.invalid`, password, role: 'admin' });
  assert(result.user.role === 'user', 'Registration accepted an administrator role');
  return { ...result, username, password };
}
async function connect(actor, botKey, websocket = true) {
  const bootstrap = botKey ? await api(base, 'GET', '/api/v1/bot-runtime/bootstrap', { botKey }) : await call(actor, 'GET', '/realtime/bootstrap');
  const client = await mqtt.connectAsync(websocket ? bootstrap.broker.ws_url : bootstrap.broker.tcp_url, {
    clientId: bootstrap.client_id, username: bootstrap.broker.username, password: bootstrap.broker.password,
    protocolVersion: 5, reconnectPeriod: 0, connectTimeout: 5000,
  });
  clients.push(client); client.on('error', () => {});
  const received = [];
  client.on('message', (_topic, bytes) => { try { received.push(JSON.parse(bytes.toString())); } catch {} });
  return { client, received };
}
async function subscribe(connection, topic) {
  const grants = await connection.client.subscribeAsync(topic, { qos: 1 });
  assert(grants.every(grant => grant.qos < 128), 'Expected subscription to be allowed');
}
function payload(actor, topic, text, bot) {
  const target = topic.startsWith('chat/group/') ? { type: 'group', id: topic.split('/').at(-1) } : { type: bot ? 'user' : 'bot', id: bot ? actor.user.id : topic.split('/').at(-1) };
  return { id: randomUUID(), topic, conversation_id: topic, timestamp: Math.floor(Date.now() / 1000),
    from: { type: bot ? 'bot' : 'user', id: bot?.id || actor.user.id }, to: target, content: { type: 'text', body: text } };
}
async function send(connection, message) {
  await Promise.race([connection.client.publishAsync(message.topic, JSON.stringify(message), { qos: 1 }), sleep(6000).then(() => { throw new Error('MQTT publish timed out'); })]);
}
async function eventually(check, message) {
  for (let attempt = 0; attempt < 100; attempt++) { if (await check()) return; await sleep(100); }
  throw new Error(message);
}
try {
  await eventually(async () => { try { return (await api(base, 'GET', '/health/ready')).status === 'ready'; } catch { return false; } }, 'Backend not ready');
  const [admin, owner, member, stranger, groupAdmin] = await Promise.all(['admin', 'owner', 'member', 'stranger', 'manager'].map(account));
  const promoted = spawnSync(cli, ['-username', admin.username], { cwd: join(root, 'backend'), env: process.env, encoding: 'utf8' });
  assert(promoted.status === 0, 'Operator administrator bootstrap failed');
  assert((await call(admin, 'GET', '/auth/me')).role === 'admin', 'Existing JWT did not pick up operator promotion');
  await denied(() => call(owner, 'GET', '/admin/users'), 403);
  await denied(() => call(owner, 'PUT', `/admin/users/${owner.user.id}/access`, { role: 'admin' }), 403);
  await denied(() => call(admin, 'PUT', `/admin/users/${admin.user.id}/access`, { role: 'user' }), 409);
  pass('registration cannot self-promote; administrator bootstrap, current roles, and self-lockout protection');

  const bot = await call(owner, 'POST', '/bots', { name: 'MQTTS acceptance Agent', bot_type: 'assistant', is_public: false });
  const key = await call(owner, 'POST', `/bots/${bot.id}/keys`, { name: 'isolated acceptance' });
  for (const actor of [stranger, admin]) {
    await denied(() => call(actor, 'GET', `/bots/${bot.id}`), 403);
    await denied(() => call(actor, 'GET', `/bots/${bot.id}/keys`), 404);
    await denied(() => call(actor, 'PUT', `/bots/${bot.id}`, { name: 'forged' }), 404);
  }
  const group = await call(owner, 'POST', '/groups', { name: 'MQTTS acceptance group' });
  const groupPath = `/groups/${group.id}`, topic = `chat/group/${group.id}`, dm = `chat/dm/user/${owner.user.id}/bot/${bot.id}`;
  for (const actor of [stranger, admin]) {
    for (const path of [groupPath, `${groupPath}/members`, `/messages/${topic}`]) await denied(() => call(actor, 'GET', path), 403);
  }
  await denied(() => call(owner, 'POST', `${groupPath}/members`, { user_id: member.user.id, role: 'owner' }), 400);
  await call(owner, 'POST', `${groupPath}/members`, { user_id: groupAdmin.user.id, role: 'admin' });
  await denied(() => call(groupAdmin, 'POST', `${groupPath}/members`, { user_id: stranger.user.id, role: 'admin' }), 403);
  await call(owner, 'POST', `${groupPath}/members`, { user_id: member.user.id });
  await call(owner, 'POST', `${groupPath}/members`, { bot_id: bot.id });
  await denied(() => call(member, 'DELETE', `${groupPath}/members/${owner.user.id}`), 403);
  await denied(() => call(member, 'POST', `${groupPath}/members`, { user_id: stranger.user.id }), 403);
  pass('private Agent and group isolation; owner and group-administrator role boundaries');

  const [userConnection, botConnection, memberConnection] = await Promise.all([connect(owner), connect(owner, key.key, false), connect(member)]);
  for (const connection of [userConnection, botConnection]) { await subscribe(connection, dm); await subscribe(connection, topic); }
  await subscribe(memberConnection, topic);
  let deniedWildcard = false;
  try { const grants = await memberConnection.client.subscribeAsync('chat/#'); deniedWildcard = grants.some(row => row.qos >= 128); } catch { deniedWildcard = true; }
  assert(deniedWildcard, 'Wildcard subscription allowed');
  for (const channel of [dm, topic]) {
    const request = payload(owner, channel, 'Acceptance request');
    await send(userConnection, request);
    await eventually(() => botConnection.received.some(row => row.id === request.id), 'Agent did not receive browser message');
    const reply = payload(owner, channel, 'Acceptance reply', bot);
    await send(botConnection, reply);
    await eventually(() => userConnection.received.some(row => row.id === reply.id), 'Browser did not receive Agent reply');
    await eventually(async () => { const history = await call(owner, 'GET', `/messages/${channel}`); return [request.id, reply.id].every(id => history.some(row => row.id === id)); }, 'Request and reply were not persisted');
  }
  // The generic broker forwards opaque bytes; the application inspects identity.
  // This exceeds the former 8 KiB metadata-only callback body limit.
  const largeBody = '独立 Broker / 应用权限\n'.repeat(1024).trim();
  const large = payload(owner, dm, largeBody);
  await send(userConnection, large);
  await eventually(() => botConnection.received.some(row => row.id === large.id && row.content.body === largeBody), 'Large UTF-8 payload changed in transit');
  await eventually(async () => (await call(owner, 'GET', `/messages/${dm}`)).some(row => row.id === large.id && row.content.body === largeBody), 'Large payload was not persisted intact');
  pass('generic opaque payload callback preserves large UTF-8 messages and application persistence');
  const spoof = payload(stranger, topic, 'Forged sender');
  await send(userConnection, spoof).catch(() => {});
  await sleep(350);
  assert(!botConnection.received.some(row => row.id === spoof.id), 'Forged sender reached Agent');
  assert(!(await call(owner, 'GET', `/messages/${topic}`)).some(row => row.id === spoof.id), 'Forged sender persisted');
  pass('real WebSocket ↔ TCP Agent messages, direct/group persistence, wildcard denial, sender forgery rejection');

  await call(owner, 'DELETE', `${groupPath}/members/${member.user.id}`);
  for (const path of [groupPath, `${groupPath}/members`, `/messages/${topic}`]) await denied(() => call(member, 'GET', path), 403);
  assert(!(await call(member, 'GET', '/conversations')).some(row => row.conversation_id === topic), 'Removed group leaked in conversation previews');
  const afterRemoval = payload(owner, topic, 'After removal', bot);
  await send(botConnection, afterRemoval);
  await sleep(350);
  assert(!memberConnection.received.some(row => row.id === afterRemoval.id), 'Removed member still receives messages');
  const removedPublish = payload(member, topic, 'Removed member publishing');
  await send(memberConnection, removedPublish).catch(() => {});
  await sleep(250);
  assert(!botConnection.received.some(row => row.id === removedPublish.id), 'Removed member still publishes messages');
  pass('membership removal blocks existing MQTT delivery/publication, HTTP history, metadata, and previews');

  const temporaryKey = await call(owner, 'POST', `/bots/${bot.id}/keys`, { name: 'revocation acceptance' });
  const revokedBot = await connect(owner, temporaryKey.key, false);
  await call(owner, 'DELETE', `/bots/${bot.id}/keys/${temporaryKey.id}`);
  await denied(() => api(base, 'GET', '/api/v1/bot-runtime/bootstrap', { botKey: temporaryKey.key }), 401);
  const revokedMessage = payload(owner, topic, 'Revoked key publishing', bot);
  await send(revokedBot, revokedMessage).catch(() => {});
  await sleep(250);
  assert(!userConnection.received.some(row => row.id === revokedMessage.id), 'Revoked Agent key still publishes');
  await call(owner, 'PUT', `/bots/${bot.id}`, { status: 0 });
  await denied(() => api(base, 'GET', '/api/v1/bot-runtime/bootstrap', { botKey: key.key }), 401);
  const disabledMessage = payload(owner, topic, 'Disabled Agent publishing', bot);
  await send(botConnection, disabledMessage).catch(() => {});
  await sleep(250);
  assert(!userConnection.received.some(row => row.id === disabledMessage.id), 'Disabled Agent still publishes');
  await call(owner, 'PUT', `/bots/${bot.id}`, { status: 1 });
  pass('Agent disable and key revocation invalidate bootstrap and existing MQTT publishing');

  await call(admin, 'PUT', `/admin/users/${owner.user.id}/access`, { status: 2 });
  await denied(() => call(owner, 'GET', '/auth/me'), 401);
  await denied(() => call(null, 'POST', '/auth/refresh', { refresh_token: owner.tokens.refresh_token }), 401);
  await denied(() => api(base, 'GET', '/api/v1/bot-runtime/bootstrap', { botKey: key.key }), 401);
  const bannedPublish = payload(owner, topic, 'Suspended Agent publishing', bot);
  await send(botConnection, bannedPublish).catch(() => {});
  await sleep(250);
  assert(!userConnection.received.some(row => row.id === bannedPublish.id), 'Suspended owner Agent still publishes');
  await call(admin, 'PUT', `/admin/users/${owner.user.id}/access`, { status: 1 });
  pass('account suspension revokes existing JWT, refresh token, Agent keys, and live MQTT publishing');

  // Concurrent administrators may not demote each other and leave no admin.
  await call(admin, 'PUT', `/admin/users/${stranger.user.id}/access`, { role: 'admin' });
  const updates = await Promise.allSettled([
    call(admin, 'PUT', `/admin/users/${stranger.user.id}/access`, { role: 'user' }),
    call(stranger, 'PUT', `/admin/users/${admin.user.id}/access`, { role: 'user' }),
  ]);
  assert(updates.filter(row => row.status === 'fulfilled').length === 1, 'Concurrent administrator demotion violated serialization');
  const finalAdmin = (await call(admin, 'GET', '/auth/me')).role === 'admin' ? admin : stranger;
  await call(finalAdmin, 'GET', '/admin/users');
  pass('PostgreSQL concurrent administrator changes preserve an active administrator');
  if (process.env.MQTTS_TEST_STATE_DIR) {
    const folder = process.env.MQTTS_TEST_STATE_DIR;
    await mkdir(folder, { recursive: true, mode: 0o700 });
    await writeFile(join(folder, 'acceptance-account.json'), JSON.stringify({ admin: finalAdmin, owner, bot, bot_key: key.key, group, topic: dm }), { mode: 0o600 });
    await writeFile(join(folder, 'acceptance-results.json'), JSON.stringify({ passed: results, at: new Date().toISOString() }, null, 2));
  }
} catch (error) { console.error(error.message); process.exitCode = 1; }
finally { await Promise.allSettled(clients.map(client => client.endAsync(true))); }
