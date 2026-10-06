import { randomUUID } from 'node:crypto';
import { writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import mqtt from 'mqtt';
import http from 'node:http';
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
async function replyContent(incoming) {
  const content = incoming.content || { type: 'text', body: '' };
  const body = `Echo: ${content.body || content.type}`;
  const meta = { reply_to_message_id: incoming.id };
  if (!['image', 'audio', 'file'].includes(content.type)) return { ...content, body, meta: { ...content.meta, ...meta } };
  // Files have no bot import endpoint. Acknowledge receipt without impersonating
  // ownership of the user's asset, which the persistence service rightly rejects.
  if (content.type === 'file') return { type: 'text', body, meta };
  const source = new URL(content.meta?.asset?.download_url || content.url);
  if (source.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(source.hostname) || !source.searchParams.has('X-Amz-Signature')) {
    throw new Error('Echo media requires a signed local test-storage URL');
  }
  // Reach the Compose storage service while retaining the Host covered by the signature.
  const bytes = await new Promise((resolve, reject) => {
    const request = http.get({ hostname: 'storage', port: 9000, path: source.pathname + source.search,
      headers: { Host: source.host }, timeout: 15000 }, response => {
      if (response.statusCode !== 200) { response.resume(); reject(new Error('Echo media download failed')); return; }
      const chunks = [];
      let size = 0;
      response.on('data', chunk => {
        size += chunk.length;
        if (size > 8 * 1024 * 1024) response.destroy(new Error('Echo media exceeds the test limit'));
        else chunks.push(chunk);
      });
      response.on('end', () => resolve(Buffer.concat(chunks)));
      response.on('error', reject);
    });
    request.on('timeout', () => request.destroy(new Error('Echo media download timed out')));
    request.on('error', reject);
  });
  const mime = content.meta?.asset?.mime_type || (content.type === 'image' ? 'image/png' : 'audio/wav');
  const imported = await api(base, 'POST', `/api/v1/bot-runtime/assets/${content.type}/import`, { botKey: account.bot_key,
    body: { file_name: content.name, content_type: mime, data_url: `data:${mime};base64,${bytes.toString('base64')}` } });
  const asset = imported.asset || imported;
  return { type: content.type, body, name: asset.file_name, size: asset.size, url: asset.download_url,
    meta: { ...meta, asset, ...(asset.width ? { width: asset.width, height: asset.height } : {}) } };
}
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
    const content = await replyContent(incoming);
    const reply = {
      id: randomUUID(), topic, conversation_id: topic, timestamp: Math.floor(Date.now() / 1000),
      from: { type: 'bot', id: account.bot.id, name: account.bot.name },
      to: { type: group ? 'group' : 'user', id: group ? account.group.id : account.user.id },
      content,
      metadata: { test_echo: true, reply_to_message_id: incoming.id },
    };
    await client.publishAsync(topic, JSON.stringify(reply), { qos: 1 });
  })().catch(() => console.error('Echo Bot could not publish a reply'));
}
async function connect(data) {
  const connection = await mqtt.connectAsync('mqtt://emqx:1883', {
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
