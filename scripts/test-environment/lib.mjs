import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { parseEnv } from 'node:util';

export const root = fileURLToPath(new URL('../../', import.meta.url));
export const state = resolve(process.env.TEST_STATE_DIR || join(root, 'run/test-env'));
export const envFile = resolve(process.env.OPENCLAW_TEST_ENV_FILE || join(root, '.env.test'));
export const accountFile = join(state, 'account.json');
export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function settings() {
  return parseEnv(await readFile(envFile, 'utf8'));
}

export async function readAccount() {
  return JSON.parse(await readFile(accountFile, 'utf8'));
}

export async function saveAccount(account) {
  await mkdir(state, { recursive: true, mode: 0o700 });
  await writeFile(accountFile, `${JSON.stringify(account, null, 2)}\n`, { mode: 0o600 });
}

export async function api(base, method, path, { token, botKey, body } = {}) {
  const response = await fetch(`${base.replace(/\/$/, '')}${path}`, {
    method,
    signal: AbortSignal.timeout(15000),
    headers: {
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(botKey ? { 'X-Bot-Key': botKey } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    const error = new Error(`${method} ${path}: HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  const payload = await response.json();
  return payload.data ?? payload;
}

export function assert(condition, message) {
  if (!condition) throw new Error(message);
}

export function reportFailure(error) {
  console.error(error.message);
  process.exitCode = 1;
}
