import { randomUUID } from 'node:crypto';
import mqtt from 'mqtt';
import { settings, readAccount, saveAccount, api, assert, sleep, reportFailure } from './lib.mjs';

let client;
try {
  const config = await settings();
  const base = config.TEST_PUBLIC_URL;
  const account = await readAccount();
  const auth = await api(base, 'POST', '/api/v1/auth/login', { body: { username: account.username, password: account.password } });
  Object.assign(account, auth);
  await saveAccount(account);
  const token = account.tokens.access_token;
  assert((await api(base, 'GET', '/health')).status === 'ok', 'Backend health is not ready');
  assert((await api(base, 'GET', '/health/ready')).status === 'ready', 'Backend dependencies are not ready');
  const loginPage = await fetch(`${base}/login`, { signal: AbortSignal.timeout(30000) });
  assert(loginPage.ok, `Web login: HTTP ${loginPage.status}`);
  const bootstrap = await api(base, 'GET', '/api/v1/realtime/bootstrap', { token });
  client = await mqtt.connectAsync(bootstrap.broker.ws_url, {
    username: bootstrap.broker.username, password: bootstrap.broker.password,
    clientId: bootstrap.client_id, reconnectPeriod: 0, connectTimeout: 10000,
  });
  await client.subscribeAsync([account.topic, account.group_topic], { qos: 1 });
  const waiters = new Map();
  client.on('message', (_topic, bytes) => {
    let message;
    try { message = JSON.parse(bytes.toString()); } catch { return; }
    if (message.from?.type !== 'bot' || message.from.id !== account.bot.id) return;
    waiters.get(message.metadata?.reply_to_message_id)?.(message);
  });
  async function exchange(topic, content) {
    const id = randomUUID();
    let timer;
    const received = new Promise((resolve, reject) => {
      waiters.set(id, resolve);
      timer = setTimeout(() => reject(new Error(`Echo reply timed out (${content.type})`)), 15000);
    });
    const group = topic === account.group_topic;
    try {
      await client.publishAsync(topic, JSON.stringify({
        id, topic, conversation_id: topic, timestamp: Math.floor(Date.now() / 1000),
        from: { type: 'user', id: account.user.id },
        to: { type: group ? 'group' : 'bot', id: group ? account.group.id : account.bot.id },
        content,
      }), { qos: 1 });
      const reply = await received;
      assert(reply.content.type === (content.type === 'file' ? 'text' : content.type), `Unexpected echo type for ${content.type}`);
      if (['image', 'audio'].includes(content.type)) {
        assert(reply.content.meta?.asset?.id && reply.content.meta.asset.id !== content.meta.asset.id, 'Bot must import its own media asset');
      }
      assert(reply.to.type === (group ? 'group' : 'user'), 'Echo reply target is incorrect');
      return { id, replyId: reply.id };
    } finally {
      clearTimeout(timer);
      waiters.delete(id);
    }
  }

  const text = await exchange(account.topic, { type: 'text', body: `test message ${Date.now()}` });
  const groupText = await exchange(account.group_topic, { type: 'text', body: `group message ${Date.now()}` });
  const expected = new Set([text.id, text.replyId]);
  const image = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=', 'base64');
  const audio = Buffer.alloc(44 + 1600);
  audio.write('RIFF', 0); audio.writeUInt32LE(audio.length - 8, 4); audio.write('WAVEfmt ', 8);
  audio.writeUInt32LE(16, 16); audio.writeUInt16LE(1, 20); audio.writeUInt16LE(1, 22);
  audio.writeUInt32LE(8000, 24); audio.writeUInt32LE(16000, 28); audio.writeUInt16LE(2, 32);
  audio.writeUInt16LE(16, 34); audio.write('data', 36); audio.writeUInt32LE(1600, 40);

  for (const [kind, bytes, contentType, fileName] of [['image', image, 'image/png', 'test.png'], ['audio', audio, 'audio/wav', 'test.wav'], ['file', Buffer.from('# Acceptance attachment\nA real signed file round trip.\n'), 'text/markdown', 'acceptance.md']]) {
    const prepared = await api(base, 'POST', `/api/v1/assets/${kind}/upload-prepare`, { token, body: {
      file_name: fileName, content_type: contentType, size: bytes.length, conversation_id: account.topic,
    } });
    const upload = await fetch(prepared.upload.url, { method: prepared.upload.method, headers: prepared.upload.headers, body: bytes, signal: AbortSignal.timeout(15000) });
    assert(upload.ok, `${kind} signed upload: HTTP ${upload.status}`);
    const asset = await api(base, 'POST', `/api/v1/assets/${kind}/complete`, { token, body: { asset_id: prepared.asset.id, object_key: prepared.asset.object_key } });
    const download = await fetch(asset.download_url, { signal: AbortSignal.timeout(15000) });
    assert(download.ok && Buffer.from(await download.arrayBuffer()).equals(bytes), `${kind} download differs from upload`);
    const invalidUrl = new URL(asset.download_url);
    invalidUrl.searchParams.set('X-Amz-Signature', '0'.repeat(64));
    const rejected = await fetch(invalidUrl, { signal: AbortSignal.timeout(15000) });
    assert(rejected.status === 403, 'Storage accepted an invalid signature');
    const media = await exchange(account.topic, { type: kind, body: fileName, url: asset.download_url, name: fileName, meta: { asset } });
    expected.add(media.id);
    expected.add(media.replyId);
  }
  const imported = await api(base, 'POST', '/api/v1/bot-runtime/assets/image/import', { botKey: account.bot_key, body: {
    file_name: 'bot-test.png', content_type: 'image/png', data_url: `data:image/png;base64,${image.toString('base64')}`,
  } });
  assert(imported.id || imported.asset?.id, 'Bot media import did not return an asset');

  let persisted = false;
  for (let attempt = 0; attempt < 40; attempt++) {
    const history = await api(base, 'GET', `/api/v1/messages/${account.topic}?limit=50`, { token });
    if ([...expected].every(id => history.some(message => message.id === id))) { persisted = true; break; }
    await sleep(100);
  }
  assert(persisted, 'A direct text/media message or its reply was not persisted');
  const groupHistory = await api(base, 'GET', `/api/v1/messages/${account.group_topic}?limit=50`, { token });
  assert([groupText.id, groupText.replyId].every(id => groupHistory.some(message => message.id === id)), 'Group messages were not persisted');
  assert((await api(base, 'GET', '/api/v1/documents', { token })).some(item => item.id === account.document_id), 'Document fixture is missing');
  assert((await api(base, 'GET', '/api/v1/tasks', { token })).some(item => item.id === account.task_id), 'Task fixture is missing');
  console.log('PASS web, login, MQTT WebSocket, direct/group echo, persistence, signed image/audio/file upload/download, invalid-signature rejection, bot image import, document/task fixtures');
} catch (error) {
  reportFailure(error);
} finally {
  await client?.endAsync();
}
