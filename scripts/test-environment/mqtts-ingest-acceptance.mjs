// Owns its consumer process, and only pauses the explicitly identified isolated API.
// Requires psql and an isolated *_test or *_acceptance database. Never stops PostgreSQL.
import { randomUUID } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, readFile, writeFile, open } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import mqtt from 'mqtt';
import { api, assert, sleep, root } from './lib.mjs';

const env = process.env;
const state = resolve(env.MQTTS_TEST_STATE_DIR || 'run/mqtts-permissions');
const executable = env.MQTTS_TEST_INGEST_EXECUTABLE;
const backendPID = Number(env.MQTTS_TEST_BACKEND_PID);
const backendExecutable = env.MQTTS_TEST_BACKEND_EXECUTABLE;
assert(executable && executable.startsWith('/'), 'Supply an absolute ingest executable');
assert(/_(test|acceptance)$/.test(env.DATABASE_DBNAME || ''), 'Refusing to lock a non-test database');
assert(Number.isInteger(backendPID) && backendPID > 1 && backendExecutable, 'Supply isolated API PID and executable');
assert(execFileSync('ps', ['-o', 'uid=,args=', '-p', String(backendPID)], { encoding: 'utf8' }).trim() === `${process.getuid()} ${backendExecutable}`, 'Refusing to pause unrelated API');
assert((env.INGEST_MQTT_PASSWORD || '').length >= 32 && env.INGEST_MQTT_PASSWORD !== env.MQTT_PASSWORD, 'Use a separate consumer password');
await mkdir(state, { recursive: true, mode: 0o700 });
const log = await open(join(state, 'ingest-acceptance.log'), 'a', 0o600);
const pgEnv = { ...env, PGHOST: env.DATABASE_HOST, PGPORT: env.DATABASE_PORT, PGUSER: env.DATABASE_USER,
  PGPASSWORD: env.DATABASE_PASSWORD, PGDATABASE: env.DATABASE_DBNAME, PGAPPNAME: 'isolated-ingest-acceptance' };
const sql = query => {
  try { return execFileSync('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', query], { env: pgEnv, encoding: 'utf8', timeout: 10000 }).trim(); }
  catch (error) { throw new Error(`Isolated database check failed: ${error.code || error.status}`); }
};
const lockName = 'ingest-lock-' + randomUUID();
const consumerEnv = { ...env, MQTT_CLIENT_ID: 'acceptance-message-ingest', MQTT_USERNAME: 'acceptance-message-ingest', MQTT_PASSWORD: env.INGEST_MQTT_PASSWORD,
  PUSH_ENABLED: env.MQTTS_TEST_PUSH_OUTBOX === '1' ? 'true' : 'false',
  INGEST_LISTEN: '127.0.0.1:18082', INGEST_SPOOL_PATH: join(state, 'ingest-acceptance.db') };
const base = env.MQTTS_TEST_API_URL || 'http://127.0.0.1:18081';
let consumer, lock, client, paused = false, watchdog;
const checks = [];
const recoveryTimeoutMs = Number(env.MQTTS_TEST_RECOVERY_TIMEOUT_MS || 20000);
assert(Number.isInteger(recoveryTimeoutMs) && recoveryTimeoutMs >= 20000 && recoveryTimeoutMs <= 120000, 'Invalid bounded recovery timeout');
function pass(message) { checks.push(message); console.log('PASS ' + message); }
async function eventually(check, message, ms = 20000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (await check()) return; await sleep(100); }
  throw new Error(message);
}
async function health() { try { return await (await fetch('http://127.0.0.1:18082/health/ready', { signal: AbortSignal.timeout(4000) })).json(); } catch { return {}; } }
async function startConsumer(ready = true) {
  consumer = spawn(executable, [], { cwd: join(root, 'backend'), env: consumerEnv, stdio: ['ignore', log.fd, log.fd] });
  consumer.on('error', () => {});
  await eventually(async () => {
    assert(consumer.exitCode === null && consumer.signalCode === null, 'Consumer exited; inspect ingest-acceptance.log');
    const h = await health(); return ready ? h.status === 'ready' : !!h.queue;
  }, 'Consumer health not available');
}
async function stopConsumer(signal = 'SIGTERM') {
  if (consumer && consumer.exitCode === null && consumer.signalCode === null) {
    const exited = once(consumer, 'exit'); consumer.kill(signal); await exited;
  }
}
async function restartIsolatedBroker() {
  if (env.MQTTS_TEST_BROKER_CONTAINER) {
    const name = env.MQTTS_TEST_BROKER_CONTAINER;
    const info = JSON.parse(execFileSync('docker', ['inspect', name], { encoding: 'utf8' }))[0];
    assert(info.Config.Labels?.['mqtts.isolated-acceptance'] === 'true', 'Refusing to restart an unlabelled broker');
    execFileSync('docker', ['kill', '--signal=KILL', name]);
    execFileSync('docker', ['start', name]);
  } else if (env.MQTTS_TEST_BROKER_PID) {
    const pid = Number(env.MQTTS_TEST_BROKER_PID);
    const binary = env.MQTTS_TEST_BROKER_EXECUTABLE;
    const config = env.MQTTS_TEST_BROKER_CONFIG;
    assert(Number.isInteger(pid) && pid > 1 && binary?.startsWith('/') && config?.startsWith(state + '/'), 'Supply isolated broker identity');
    const settings = JSON.parse(await readFile(config));
    assert(settings.server.bind_address === '127.0.0.1' && settings.persistence?.path?.startsWith(state + '/'), 'Refusing broker without isolated local storage');
    assert(execFileSync('ps', ['-o', 'uid=,args=', '-p', String(pid)], { encoding: 'utf8' }).trim() === `${process.getuid()} ${binary} -c ${config}`, 'Refusing unrelated broker process');
    process.kill(pid, 'SIGKILL');
    await eventually(() => {
      try { return execFileSync('ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' }).trim().startsWith('Z'); }
      catch { return true; }
    }, 'Owned broker did not exit');
    const restarted = spawn(binary, ['-c', config], { cwd: state, env, detached: true, stdio: ['ignore', log.fd, log.fd] });
    restarted.on('error', () => {}); restarted.unref();
    await writeFile(join(state, 'broker.pid'), String(restarted.pid), { mode: 0o600 });
  } else return false;
  return true;
}
function resume() { if (paused) { process.kill(backendPID, 'SIGCONT'); paused = false; } }
function releaseLock() {
  if (!lock) return;
  // Killing psql alone need not interrupt the server's pg_sleep immediately.
  // Terminate only the uniquely named connection that this test created.
  sql(`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='${lockName}' AND datname=current_database()`);
  lock.kill('SIGTERM'); lock = undefined;
}
process.on('SIGTERM', () => { resume(); releaseLock(); consumer?.kill(); process.exit(1); });
process.on('SIGINT', () => { resume(); releaseLock(); consumer?.kill(); process.exit(1); });

try {
  await startConsumer();
  const acceptance = spawn(process.execPath, ['scripts/test-environment/mqtts-permissions.mjs'], { cwd: root, env, stdio: 'inherit' });
  assert((await once(acceptance, 'exit'))[0] === 0, 'Permission regression failed');
  const account = JSON.parse(await readFile(join(state, 'acceptance-account.json')));
  const bootstrap = await api(base, 'GET', '/api/v1/realtime/bootstrap', { token: account.owner.tokens.access_token });
  const connectPublisher = async () => {
    // A restart can close the socket before CONNACK. Bound that attempt and
    // dispose it, so the readiness retry cannot leave an unsettled promise.
    return new Promise((resolveConnection, rejectConnection) => {
      const connection = mqtt.connect(bootstrap.broker.tcp_url, { clientId: bootstrap.client_id, username: bootstrap.broker.username,
        password: bootstrap.broker.password, protocolVersion: 5, reconnectPeriod: 0, connectTimeout: 5000 });
      const timer = setTimeout(() => fail(new Error('Publisher connection timeout')), 5000);
      const cleanup = () => { clearTimeout(timer); connection.removeListener('connect', connected); connection.removeListener('error', fail); connection.removeListener('close', closed); };
      const fail = error => { cleanup(); connection.on('error', () => {}); connection.end(true); rejectConnection(error); };
      const closed = () => fail(new Error('Publisher closed before CONNACK'));
      const connected = () => { cleanup(); connection.on('error', () => {}); resolveConnection(connection); };
      connection.once('connect', connected); connection.once('error', fail); connection.once('close', closed);
    });
  };
  client = await connectPublisher();
  const message = body => ({ id: randomUUID(), topic: account.topic, conversation_id: account.topic, timestamp: Math.floor(Date.now()/1000),
    from: { type: 'user', id: account.owner.user.id }, to: { type: 'bot', id: account.bot.id }, content: { type: 'text', body } });
  const send = m => client.publishAsync(account.topic, JSON.stringify(m), { qos: 1 });
  // IDs are generated here, never supplied as SQL fragments by an external actor.
  const ids = batch => batch.map(m => `'${m.id}'`).join(',');
  const count = batch => Number(sql(`SELECT count(*) FROM messages WHERE message_id IN (${ids(batch)})`));
  let pushReply;
  if (env.MQTTS_TEST_PUSH_OUTBOX === '1') {
    // Exercise actual MQTTS -> independent consumer -> PostgreSQL outbox with
    // the API provider disabled. No APNs traffic or real device token is used.
    assert((await api(base, 'GET', '/api/v1/push/status', { token: account.owner.tokens.access_token })).available === false, 'Fixture must not enable an APNs sender');
    const installation = randomUUID(), revision = randomUUID();
    sql(`INSERT INTO push_devices (id,user_id,token,environment,revision,language,enabled,expires_at,created_at,updated_at) VALUES ('${installation}','${account.owner.user.id}','abcdef','sandbox','${revision}','en',true,now()+interval '1 day',now(),now())`);
    const botBootstrap = await api(base, 'GET', '/api/v1/bot-runtime/bootstrap', { botKey: account.bot_key });
    const readerBootstrap = await api(base, 'GET', '/api/v1/realtime/bootstrap', { token: account.owner.tokens.access_token });
    pushReply = async label => {
      const publisher = await mqtt.connectAsync(botBootstrap.broker.tcp_url, { clientId: botBootstrap.client_id, username: botBootstrap.broker.username, password: botBootstrap.broker.password, protocolVersion: 5, reconnectPeriod: 0, connectTimeout: 5000 });
      publisher.on('error', () => {});
      // CocoaMQTT uses MQTT 3.1.1 over WebSocket; verify this transport alongside
      // the MQTT 5 backend fixtures without changing the iOS protocol.
      const reader = await mqtt.connectAsync(readerBootstrap.broker.ws_url, { clientId: readerBootstrap.client_id, username: readerBootstrap.broker.username, password: readerBootstrap.broker.password, protocolVersion: 4, reconnectPeriod: 0, connectTimeout: 5000 });
      reader.on('error', () => {});
      const reply = { ...message(label), from: { type: 'bot', id: account.bot.id }, to: { type: 'user', id: account.owner.user.id } };
      let received = false;
      reader.on('message', (_topic, bytes) => { try { const row = JSON.parse(bytes); if (row.id === reply.id && row.content.body === label) received = true; } catch {} });
      try {
        await reader.subscribeAsync(account.topic, { qos: 1 });
        for (let i=0; i<2; i++) await publisher.publishAsync(account.topic, JSON.stringify(reply), { qos: 1 });
        await eventually(() => received && count([reply]) === 1 && Number(sql(`SELECT count(*) FROM push_deliveries p JOIN messages m ON p.message_row_id=m.id WHERE m.message_id='${reply.id}' AND p.device_id='${installation}' AND p.state='pending'`)) === 1, 'MQTT reply or exactly-once transactional push row missing');
      } finally { await Promise.allSettled([publisher.endAsync(true),reader.endAsync(true)]); }
    };
    await pushReply('MQTTS push outbox replay');
    pass('MQTT 3.1.1 WebSocket receives bot reply; duplicate broker delivery creates one message and one pending push');
  }
  await eventually(async () => (await health()).queue?.pending === 0, 'Pre-existing backlog did not drain');
  const baselineDead = (await health()).queue.dead;

  await stopConsumer('SIGKILL');
  await sleep(200);
  const offline = Array.from({ length: 200 }, (_, i) => message(`consumer offline ${i}`));
  for (const m of offline) await send(m);
  assert(count(offline) === 0, 'Offline check unexpectedly had another consumer');
  await client.endAsync(true); client = undefined;
  const brokerRestarted = await restartIsolatedBroker();
  await eventually(async () => { try { client = await connectPublisher(); return true; } catch { return false; } }, 'Publisher did not reconnect after broker restart');
  await startConsumer();
  await eventually(() => count(offline) === 200, 'Broker offline publications did not finish recovery within the timeout', recoveryTimeoutMs);
  assert(sql(`SELECT string_agg(message_id::text, ',' ORDER BY seq) FROM messages WHERE message_id IN (${ids(offline)})`) === offline.map(m => m.id).join(','), 'Offline recovery changed conversation order');
  await eventually(async () => (await health()).queue?.pending === 0, 'Recovered offline backlog did not drain');
  pass(`200 publications persisted in order after consumer SIGKILL${brokerRestarted ? ' and broker SIGKILL/restart' : ''}`);

  process.kill(backendPID, 'SIGSTOP'); paused = true;
  // A separate watchdog resumes the API even if this test process crashes.
  watchdog = spawn(process.execPath, ['-e', `setTimeout(()=>{try{process.kill(${backendPID},'SIGCONT')}catch{}},45000)`], { stdio: 'ignore' });
  const independent = Array.from({ length: 100 }, (_, i) => message(`API paused ${i}`));
  for (const m of independent) await send(m);
  await eventually(() => count(independent) === 100, 'API pause blocked database persistence');
  await sleep(11000); // Include a subscriber policy renewal without the API.
  const renewed = message('consumer independently renews'); await send(renewed);
  await eventually(() => count([renewed]) === 1, 'Consumer stopped after its independent renewal interval');
  assert(execFileSync('ps', ['-o', 'stat=', '-p', String(backendPID)], { encoding: 'utf8' }).trim().startsWith('T'), 'API resumed before persistence check');
  if (pushReply) { await pushReply('push with API paused'); pass('Independent consumer enqueues bot push while API process is paused'); }
  resume(); watchdog.kill();
  pass('101 messages persisted with the API paused, including a consumer policy renewal interval');

  lock = spawn('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', "BEGIN; LOCK TABLE messages IN ACCESS EXCLUSIVE MODE", '-c', "SELECT 'locked'", '-c', 'SELECT pg_sleep(45); ROLLBACK'], { env: { ...pgEnv, PGAPPNAME: lockName }, stdio: ['ignore', 'pipe', 'pipe'] });
  let locked = false; lock.stdout.on('data', data => { if (data.toString().includes('locked')) locked = true; });
  await eventually(() => locked, 'Unable to lock isolated messages table');
  const backlog = Array.from({ length: 200 }, (_, i) => message(`database retry ${i}`));
  for (const m of backlog) await send(m);
  await eventually(async () => (await health()).queue?.pending === 200, 'MQTT receipts were not durably buffered during database stall');
  await eventually(async () => (await health()).retries > 0, 'Database timeout did not enter retry path');
  await stopConsumer('SIGKILL');
  await startConsumer(false);
  assert((await health()).queue.pending === 200, 'Crash lost acknowledged spool records');
  releaseLock();
  await eventually(() => count(backlog) === 200, 'Spool did not replay after crash and database recovery', recoveryTimeoutMs);
  await eventually(async () => (await health()).queue?.pending === 0, 'Committed messages not removed from queue');
  assert(sql(`SELECT string_agg(message_id::text, ',' ORDER BY seq) FROM messages WHERE message_id IN (${ids(backlog)})`) === backlog.map(m => m.id).join(','), 'Conversation order changed during replay');
  pass('200 acknowledged messages survived SIGKILL and database timeout, then replayed in order');

  sql(`UPDATE messages SET is_deleted=true WHERE message_id='${backlog[0].id}'`);
  for (const m of backlog) await send(m);
  const sentinel = message('after duplicate batch'); await send(sentinel);
  await eventually(() => count([sentinel]) === 1, 'Duplicate batch did not drain');
  assert(count(backlog) === 200, 'Duplicate delivery inserted additional rows');
  assert(sql(`SELECT bool_and(is_deleted) FROM messages WHERE message_id='${backlog[0].id}'`) === 't', 'Deleted message resurrected');
  pass('200 duplicate deliveries produced no extra rows and did not resurrect deleted history');

  await send(message('')); // Structurally authorized, but invalid business message.
  const valid = message('after poison message'); await send(valid);
  await eventually(async () => (await health()).queue?.dead === baselineDead + 1 && count([valid]) === 1, 'Poison message blocked following valid message');
  pass('Malformed business message retained in dead-letter queue without blocking valid messages');
  if (env.MQTTS_TEST_AUTHZ_CONTAINER || env.MQTTS_TEST_AUTHZ_PID) {
    for (const target of ['backend', 'authz']) {
      const check = spawn(process.execPath, ['scripts/test-environment/mqtts-cache-outage.mjs'], { cwd: root, env: { ...env, MQTTS_TEST_PAUSE_TARGET: target }, stdio: 'inherit' });
      assert((await once(check, 'exit'))[0] === 0, `${target} cache outage regression failed`);
    }
  }
  // The HTTP API must remain ready when the consumer is stopped.
  await stopConsumer();
  assert((await api(base, 'GET', '/health/ready')).status === 'ready', 'API readiness depends on consumer');
  pass('API readiness remains healthy with the consumer stopped');
  await writeFile(join(state, 'ingest-results.json'), JSON.stringify({ passed: checks, at: new Date().toISOString() }, null, 2));
} finally {
  resume(); watchdog?.kill(); releaseLock();
  await client?.endAsync(true);
  await stopConsumer();
  // Release this fixture's persistent broker session so later local tests do
  // not accumulate a second offline chat/# backlog under the fixture identity.
  try {
    const reset = await mqtt.connectAsync(env.MQTT_BROKER.replace(/^tcp:/, 'mqtt:'), {
      clientId: consumerEnv.MQTT_CLIENT_ID, username: consumerEnv.MQTT_USERNAME,
      password: consumerEnv.MQTT_PASSWORD, protocolVersion: 4, clean: true,
      reconnectPeriod: 0, connectTimeout: 5000,
    });
    reset.on('error', () => {}); await reset.endAsync();
  } catch { console.warn('Fixture session cleanup could not connect; broker expiry remains in effect'); }
  await log.close();
}
