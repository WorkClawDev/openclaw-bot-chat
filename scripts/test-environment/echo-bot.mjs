import { randomUUID } from 'node:crypto';
import { writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import mqtt from 'mqtt';
import { state, readAccount, api } from './lib.mjs';

const account = await readAccount();
const base = 'http://backend:8080';
const readyFile = join(state, 'echo.ready');
await rm(readyFile, { force: true });
const bootstrap = () => api(base, 'GET', '/api/v1/bot-runtime/bootstrap', { botKey: account.bot_key });
let session = await bootstrap();
let client;
let refreshing = false;
let stopping = false;
const seen = new Set();
async function subscribe(connection, data) {
  const topics = data.subscriptions.filter(item => item.topic.startsWith('chat/'));
  for (const item of topics) {
    const grants = await connection.subscribeAsync(item.topic, { qos: 1 });
    if (grants.some(grant => grant.qos === 128)) throw new Error('Echo Bot subscription denied');
  }
  await writeFile(readyFile, 'ready\n');
}
function handleMessage(topic, bytes) {
  void (async () => {
    let incoming;
    try { incoming = JSON.parse(bytes.toString()); } catch { return; }
    if (incoming.from?.type !== 'user' || incoming.from.id !== account.user.id || !incoming.id || seen.has(incoming.id)) return;
    if (topic !== account.topic && topic !== account.group_topic) return;
    seen.add(incoming.id);
    if (seen.size > 10000) seen.delete(seen.values().next().value);
    const group = topic === account.group_topic;
    const content = incoming.content || { type: 'text', body: '' };
    const reply = {
      id: randomUUID(), topic, conversation_id: topic, timestamp: Math.floor(Date.now() / 1000),
      from: { type: 'bot', id: account.bot.id, name: account.bot.name },
      to: { type: group ? 'group' : 'user', id: group ? account.group.id : account.user.id },
      content: { ...content, body: `Echo: ${content.body || content.type}` },
      metadata: { test_echo: true, reply_to_message_id: incoming.id },
    };
    await client.publishAsync(topic, JSON.stringify(reply), { qos: 1 });
  })().catch(() => console.error('Echo Bot could not publish a reply'));
}
async function connect(data) {
  const connection = await mqtt.connectAsync(process.env.TEST_BROKER_TCP_URL || 'mqtt://mqtts:1883', {
    username: data.broker.username, password: data.broker.password,
    clientId: data.client_id, reconnectPeriod: 2000, connectTimeout: 10000,
  });
  connection.on('message', handleMessage);
  connection.on('connect', () => { void subscribe(connection, data).catch(error => console.error(error.message)); });
  connection.on('offline', () => {
    if (connection === client) void rm(readyFile, { force: true });
  });
  connection.on('error', () => console.error('Echo Bot broker connection error'));
  await subscribe(connection, data);
  return connection;
}
client = await connect(session);
async function refreshSession() {
  if (refreshing || stopping) return;
  if (client.connected && session.broker.expires_at * 1000 - Date.now() > 30000) return;
  refreshing = true;
  try {
    const next = await bootstrap();
    if (stopping) return;
    await rm(readyFile, { force: true });
    await client.endAsync(true);
    session = next;
    client = await connect(session);
    console.log('Echo Bot scoped session renewed');
  } finally {
    refreshing = false;
  }
}
const refresh = setInterval(() => { void refreshSession().catch(error => console.error(error.message)); }, 10000);
console.log('Echo Test Bot ready for direct and group chat');
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, async () => {
    stopping = true;
    clearInterval(refresh);
    await rm(readyFile, { force: true });
    await client.endAsync();
    process.exit(0);
  });
}
