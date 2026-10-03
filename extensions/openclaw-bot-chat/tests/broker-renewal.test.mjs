import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import mqttPacket from 'mqtt-packet';
import { getBotChatRuntime } from '../src/runtime.ts';

// Exercise actual MQTT CONNECT packets, not just option construction. No EMQX acceptance is implied.
test('extension renews MQTT identity and scopes, then aborts pending renewal on stop', { timeout: 45000 }, async (t) => {
  const sockets = new Set();
  const connections = [];
  const subscriptions = [];
  let resolveRotated;
  const rotated = new Promise((resolve) => { resolveRotated = resolve; });
  let resolvePending;
  const pending = new Promise((resolve) => { resolvePending = resolve; });
  let resolveAborted;
  const aborted = new Promise((resolve) => { resolveAborted = resolve; });
  const broker = net.createServer((socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    const parser = mqttPacket.parser();
    parser.on('error', () => socket.destroy());
    socket.on('data', (chunk) => parser.parse(chunk));
    parser.on('packet', (packet) => {
      if (packet.cmd === 'connect') {
        connections.push({ clientId: packet.clientId, username: packet.username, password: packet.password.toString() });
        socket.write(mqttPacket.generate({ cmd: 'connack', returnCode: 0, sessionPresent: false }));
      } else if (packet.cmd === 'subscribe') {
        subscriptions.push(packet.subscriptions.map((item) => item.topic));
        socket.write(mqttPacket.generate({ cmd: 'suback', messageId: packet.messageId, granted: packet.subscriptions.map((item) => item.qos) }));
        if (subscriptions.some((topics) => topics.includes('chat/new-scope'))) resolveRotated();
      } else if (packet.cmd === 'pingreq') {
        socket.write(mqttPacket.generate({ cmd: 'pingresp' }));
      } else if (packet.cmd === 'disconnect') socket.end();
    });
  });
  await new Promise((resolve) => broker.listen(0, '127.0.0.1', resolve));
  let calls = 0;
  const backend = http.createServer((req, res) => {
    assert.equal(req.url, '/api/v1/bot-runtime/bootstrap');
    assert.equal(req.headers['x-bot-key'], 'disposable-fixture-key');
    calls++;
    if (calls === 3) {
      res.on('close', resolveAborted);
      resolvePending();
      return;
    }
    const number = calls;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ data: {
      bot: { id: 'fixture-bot' }, client_id: `fixture-client-${number}`,
      broker: { tcp_url: `mqtt://127.0.0.1:${broker.address().port}`, username: `fixture-user-${number}`, password: `fixture-password-${number}`, qos: 1, expires_at: Math.floor(Date.now() / 1000) + 30 },
      subscriptions: [{ topic: number === 1 ? 'chat/old-scope' : 'chat/new-scope' }],
      publish_topics: [number === 1 ? 'chat/old-scope' : 'chat/new-scope'],
    } }));
  });
  await new Promise((resolve) => backend.listen(0, '127.0.0.1', resolve));
  const runtime = getBotChatRuntime();
  t.after(async () => {
    await runtime.stop();
    for (const socket of sockets) socket.destroy();
    backend.closeAllConnections();
    await Promise.all([new Promise((resolve) => broker.close(resolve)), new Promise((resolve) => backend.close(resolve))]);
  });
  const logger = { info() {}, warn() {}, error() {} };
  await runtime.start({ backendUrl: `http://127.0.0.1:${backend.address().port}`, botKey: 'disposable-fixture-key' }, logger);
  await rotated;
  assert.deepEqual(connections.slice(0, 2), [
    { clientId: 'fixture-client-1', username: 'fixture-user-1', password: 'fixture-password-1' },
    { clientId: 'fixture-client-2', username: 'fixture-user-2', password: 'fixture-password-2' },
  ]);
  assert.deepEqual(subscriptions, [['chat/old-scope'], ['chat/new-scope']]);
  await pending;
  await runtime.stop();
  await aborted;
  assert.equal(runtime.brokerRenewTimer, undefined);
  assert.equal(runtime.brokerRenewController, undefined);
  assert.equal(connections.length, 2, 'stopped runtime cannot connect with late renewal credentials');
});
