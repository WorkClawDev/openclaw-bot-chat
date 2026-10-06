import { randomBytes } from 'node:crypto';
import { access, appendFile, copyFile, mkdir, readFile, writeFile, chmod } from 'node:fs/promises';
import { join } from 'node:path';
import { envFile, state, root, settings, reportFailure } from './lib.mjs';

try {
  await mkdir(state, { recursive: true, mode: 0o700 });
  try {
    await access(envFile);
  } catch {
    const secret = () => randomBytes(24).toString('hex');
    const port = process.env.TEST_WEB_PORT || '3000';
    const origin = new URL(process.env.TEST_PUBLIC_URL || `http://127.0.0.1:${port}`).origin;
    const mqtt = new URL('/mqtt', origin);
    mqtt.protocol = mqtt.protocol === 'https:' ? 'wss:' : 'ws:';
    const username = `test_${randomBytes(4).toString('hex')}`;
    const values = {
      COMPOSE_PROJECT_NAME: 'openclaw-bot-chat-test',
      TEST_PUBLIC_URL: origin,
      TEST_WEB_PORT: port,
      TEST_API_PORT: process.env.TEST_API_PORT || '8080',
      TEST_DATABASE_PORT: process.env.TEST_DATABASE_PORT || '15432',
      TEST_REDIS_PORT: process.env.TEST_REDIS_PORT || '16379',
      TEST_MQTT_PORT: process.env.TEST_MQTT_PORT || '1883',
      TEST_MQTT_WS_PORT: process.env.TEST_MQTT_WS_PORT || '8083',
      TEST_FRONTEND_UID: String(process.getuid?.() ?? 1000),
      TEST_FRONTEND_GID: String(process.getgid?.() ?? 1000),
      MQTTS_AUTHZ_IMAGE: process.env.MQTTS_AUTHZ_IMAGE || 'mqtts-authz:local',
      MQTTS_IMAGE: process.env.MQTTS_IMAGE || 'mqtts:local',
      TEST_NODE_IMAGE: 'mirror.gcr.io/library/node:22-bookworm-slim',
      TEST_POSTGRES_IMAGE: 'mirror.gcr.io/library/postgres:15-alpine',
      TEST_REDIS_IMAGE: 'mirror.gcr.io/library/redis:7-alpine',
      TEST_USERNAME: username,
      TEST_EMAIL: `${username}@example.test`,
      TEST_PASSWORD: secret(),
      DATABASE_USER: 'postgres',
      DATABASE_PASSWORD: secret(),
      DATABASE_DBNAME: 'openclaw_bot_chat',
      DATABASE_SSLMODE: 'disable',
      JWT_SECRET: secret(),
      APP_HOST: '0.0.0.0',
      APP_PORT: '8080',
      APP_MODE: 'debug',
      LOG_LEVEL: 'info',
      MQTT_USERNAME: `mqtt_${randomBytes(4).toString('hex')}`,
      MQTT_PASSWORD: secret(),
      INGEST_MQTT_PASSWORD: secret(),
      MQTT_QOS: '1',
      MQTT_CLIENT_ID: 'openclaw-test-backend',
      MQTT_TCP_PUBLIC_URL: `mqtt://127.0.0.1:${process.env.TEST_MQTT_PORT || '1883'}`,
      MQTT_WS_PUBLIC_URL: mqtt.toString(),
      MQTTS_AUTHZ_QUERY_TOKEN: secret(),
      BROKER_SECURITY_ADMIN_TOKEN: secret(),
      BROKER_SECURITY_ADDRESS: 'mqtts-authz:50051',
      BROKER_SECURITY_INSECURE: 'true',
      BROKER_SECURITY_SESSION_TTL_SECONDS: '300',
      STORAGE_PROVIDER: 's3',
      STORAGE_S3_ENDPOINT: 'storage:9000',
      STORAGE_S3_PUBLIC_ENDPOINT: origin,
      STORAGE_S3_REGION: 'us-east-1',
      STORAGE_S3_BUCKET: 'openclaw-assets',
      STORAGE_S3_ACCESS_KEY: randomBytes(12).toString('hex'),
      STORAGE_S3_SECRET_KEY: secret(),
      STORAGE_S3_SSL: 'false',
      STORAGE_PRIVATE_READ: 'true',
      NEXT_TELEMETRY_DISABLED: '1',
    };
    await writeFile(envFile, Object.entries(values).map(([key, value]) => `${key}=${JSON.stringify(value)}`).join('\n') + '\n', { mode: 0o600, flag: 'wx' });
  }
  let config = await settings();
  for (const name of ['MQTTS_AUTHZ_QUERY_TOKEN', 'BROKER_SECURITY_ADMIN_TOKEN', 'INGEST_MQTT_PASSWORD']) {
    if (!config[name]) await appendFile(envFile, `\n${name}=${JSON.stringify(randomBytes(24).toString('hex'))}\n`);
  }
  config = await settings();
  if (!config.TEST_FRONTEND_UID || !config.TEST_FRONTEND_GID) {
    await appendFile(envFile, `\nTEST_FRONTEND_UID=${JSON.stringify(String(process.getuid?.() ?? 1000))}\nTEST_FRONTEND_GID=${JSON.stringify(String(process.getgid?.() ?? 1000))}\n`);
    config = await settings();
  }
  for (const name of ['MQTTS_AUTHZ_QUERY_TOKEN', 'BROKER_SECURITY_ADMIN_TOKEN', 'INGEST_MQTT_PASSWORD']) {
    if (!/^[a-zA-Z0-9_-]{32,}$/.test(config[name])) throw new Error(`${name} must contain at least 32 letters, digits, underscores or hyphens`);
  }
  if (config.MQTTS_AUTHZ_QUERY_TOKEN === config.BROKER_SECURITY_ADMIN_TOKEN) throw new Error('Query and management tokens must differ');
  const origin = new URL(config.TEST_PUBLIC_URL);
  if (!['http:', 'https:'].includes(origin.protocol) || origin.pathname !== '/') {
    throw new Error('TEST_PUBLIC_URL must be an HTTP(S) origin without a path');
  }
  await writeFile(join(state, 'storage-auth.json'), JSON.stringify({ identities: [{
    name: 'test-storage',
    credentials: [{ accessKey: config.STORAGE_S3_ACCESS_KEY, secretKey: config.STORAGE_S3_SECRET_KEY }],
    actions: ['Admin', 'Read', 'Write', 'List', 'Tagging'],
  }] }) + '\n', { mode: 0o600 });
  // The frontend development server still needs the managed proxy CA.
  const cert = process.env.CODEX_PROXY_CERT || '/etc/ssl/certs/ca-certificates.crt';
  await copyFile(cert, join(state, 'proxy-ca.pem'));
  await chmod(join(state, 'proxy-ca.pem'), 0o644);
  // The database entrypoint runs as a separate container user.
  await chmod(join(root, 'backend/migrations/init.sql'), 0o644);
  await chmod(join(root, 'broker/mqtts/mqtts.yaml'), 0o644);
  console.log(`Test configuration ready: ${envFile}`);
} catch (error) {
  reportFailure(error);
}
