// Run after mqtts-permissions.mjs, using only an explicitly identified isolated backend.
import mqtt from 'mqtt';
import { readFile, writeFile } from 'node:fs/promises';
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { api, assert, sleep } from './lib.mjs';
import { resolve, join } from 'node:path';

const folder = resolve(process.env.MQTTS_TEST_STATE_DIR || 'run/mqtts-permissions');
const pid = Number(process.env.MQTTS_TEST_BACKEND_PID);
const executable = process.env.MQTTS_TEST_BACKEND_EXECUTABLE;
assert(Number.isInteger(pid) && pid > 1 && executable, 'Set isolated backend PID and exact executable path');
const identity = execFileSync('ps', ['-o', 'uid=,args=', '-p', String(pid)], { encoding: 'utf8' }).trim();
assert(identity === `${process.getuid()} ${executable}`, 'Refusing to pause an unrelated process');
const account = JSON.parse(await readFile(join(folder, 'acceptance-account.json')));
const base = process.env.MQTTS_TEST_API_URL || 'http://127.0.0.1:18081';
const options = { token: account.owner.tokens.access_token };
const user = await api(base, 'GET', '/api/v1/realtime/bootstrap', options);
const bot = await api(base, 'GET', '/api/v1/bot-runtime/bootstrap', { botKey: account.bot_key });
const cold = await api(base, 'GET', '/api/v1/realtime/bootstrap', options);
const clients = [];
let stopped = false, watchdog;
function resume() { if (stopped) { process.kill(pid, 'SIGCONT'); stopped = false; } }
process.on('SIGTERM', () => { resume(); process.exit(1); });
process.on('SIGINT', () => { resume(); process.exit(1); });
const received = new WeakMap();
async function connect(bootstrap, websocket) {
  const client = await mqtt.connectAsync(websocket ? bootstrap.broker.ws_url : bootstrap.broker.tcp_url, {
    clientId: bootstrap.client_id, username: bootstrap.broker.username, password: bootstrap.broker.password,
    protocolVersion: 5, reconnectPeriod: 0, connectTimeout: 1500,
  });
  clients.push(client); client.on('error', () => {});
  received.set(client, new Map());
  client.on('message', (_topic, bytes) => { const value = JSON.parse(bytes.toString()); received.get(client).set(value.id, value); });
  await client.subscribeAsync(account.topic, { qos: 1 });
  return client;
}
const message = (text, isBot) => ({ id: randomUUID(), topic: account.topic, conversation_id: account.topic, timestamp: Math.floor(Date.now()/1000),
  from: { type: isBot ? 'bot' : 'user', id: isBot ? account.bot.id : account.owner.user.id },
  to: { type: isBot ? 'user' : 'bot', id: isBot ? account.owner.user.id : account.bot.id }, content: { type: 'text', body: text } });
async function transfer(client, text, isBot, target) {
  const inbox = received.get(target);
  const value = message(text, isBot), started = performance.now();
  await client.publishAsync(account.topic, JSON.stringify(value), { qos: 1 });
  while (!inbox.has(value.id) && performance.now()-started < 1500) await sleep(1);
  assert(inbox.get(value.id)?.content.body === text, 'Message lost or changed');
  return performance.now()-started;
}
try {
  const browser = await connect(user, true), agent = await connect(bot, false);
  await transfer(browser, 'warm browser grant', false, agent);
  await transfer(agent, 'warm Agent grant', true, browser);
  const healthy = [];
  for (let i = 0; i < 25; i++) {
    healthy.push(await transfer(browser, 'healthy browser '+i, false, agent));
    healthy.push(await transfer(agent, 'healthy Agent '+i, true, browser));
  }
  healthy.sort((a,b) => a-b);
  process.kill(pid, 'SIGSTOP'); stopped = true;
  watchdog = spawn('python3', ['-c', 'import os,sys,time,signal; time.sleep(45); os.kill(int(sys.argv[1]),signal.SIGCONT)', String(pid)], { stdio: 'ignore' });
  await sleep(11000); // Exceed the 10-second fresh interval; refresh now times out.
  let rejected = false;
  try { await connect(cold, true); } catch { rejected = true; }
  assert(rejected, 'New connection was accepted while policy service was paused');
  const samples = [];
  for (let i = 0; i < 100; i++) {
    samples.push(await transfer(browser, 'outage browser '+i, false, agent));
    samples.push(await transfer(agent, 'outage Agent '+i, true, browser));
  }
  assert(execFileSync('ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' }).trim().startsWith('T'), 'Backend resumed before outage measurement completed');
  resume();
  await sleep(1200);
  await transfer(browser, 'after recovery', false, agent);
  samples.sort((a,b) => a-b);
  const report = { transport: 'WebSocket to TCP and TCP to WebSocket, sequential QoS 1', passed: true, paused_backend: true, after_fresh_expiry: true, new_connection_rejected: true,
    browser_agent_messages: samples.length, healthy_p95_ms: Number(healthy[Math.floor(healthy.length*.95)].toFixed(3)), p95_ms: Number(samples[Math.floor(samples.length*.95)].toFixed(3)) };
  await writeFile(join(folder, 'cache-outage-results.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report));
} finally {
  resume(); watchdog?.kill();
  await Promise.allSettled(clients.map(c => c.endAsync(true)));
}
