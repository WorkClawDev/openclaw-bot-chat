#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const file = process.env.PERSONAL_AGENT_STABILITY_LOG || '/tmp/personal-agent-stability.jsonl';

if (process.argv.includes('--analyze')) {
  const samples = fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) : [];
  const elapsed = samples.length ? Date.parse(samples.at(-1).at) - Date.parse(samples[0].at) : 0;
  const gaps = samples.slice(1).some((sample, i) => Date.parse(sample.at) - Date.parse(samples[i].at) > 90000);
  console.log(JSON.stringify({samples: samples.length, elapsed_hours: elapsed / 3600000, failures: samples.filter(sample => !sample.ok).length,
    status: elapsed >= 72 * 3600000 && !gaps && samples.every(sample => sample.ok) ? 'passed' : elapsed < 72 * 3600000 ? 'not_run' : 'failed',
    scope: 'service/worker availability only; functional and provider acceptance separate'}));
  process.exit(0);
}

const base = process.env.PERSONAL_AGENT_API_URL || 'http://127.0.0.1:18080';
const authFile = process.env.PERSONAL_AGENT_AUTH_FILE;
const account = authFile ? JSON.parse(fs.readFileSync(authFile, 'utf8')) : undefined;
let token = process.env.PERSONAL_AGENT_OWNER_TOKEN;
if (!token && !(account?.username && account?.password)) throw new Error('Owner token or PERSONAL_AGENT_AUTH_FILE containing username/password is required');
const dockerEnv = {...process.env};
for (const key of ['DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH']) delete dockerEnv[key];
let stopped = false;
let wake;
function stop() { stopped = true; wake?.(); }
process.on('SIGINT', stop);
process.on('SIGTERM', stop);

async function login() {
  const response = await fetch(base + '/api/v1/auth/login', {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({username: account.username, password: account.password}), signal: AbortSignal.timeout(5000)});
  if (!response.ok) throw new Error('Collector owner login failed');
  token = (await response.json()).data?.tokens?.access_token;
  if (!token) throw new Error('Collector owner login returned no token');
}
async function ownerHealth() {
  if (!token) await login();
  const request = () => fetch(base + '/api/v1/agent/health', {headers: {Authorization: 'Bearer ' + token}, signal: AbortSignal.timeout(5000)});
  let response = await request();
  if (response.status === 401 && account) { await login(); response = await request(); }
  return response;
}
(async () => {
  while (!stopped) {
    const sample = {at: new Date().toISOString(), ok: false};
    try {
      const ready = await fetch(base + '/health/ready', {signal: AbortSignal.timeout(5000)});
      const response = await ownerHealth();
      if (!ready.ok || !response.ok) throw new Error('Readiness/owner diagnostics failed');
      const data = (await response.json()).data;
      const worker = spawnSync('docker', ['--host=unix:///var/run/docker.sock', 'compose', '--env-file', 'deploy/personal-agent/.env', '-f', 'deploy/personal-agent/compose.yaml', '-p', 'personal-agent', 'exec', '-T', 'worker', 'node', '-e',
        'const h=require("/state/health.json");process.exit(h.ready&&Date.now()-h.at<90000?0:1)'], {cwd: root, env: dockerEnv, encoding: 'utf8', timeout: 10000});
      sample.ok = worker.status === 0;
      sample.metrics = data;
      sample.worker_healthy = sample.ok;
    } catch (error) { sample.error = error.message; }
    fs.appendFileSync(file, JSON.stringify(sample) + '\n', {mode: 0o600});
    if (!stopped) await new Promise(resolve => { const timer = setTimeout(resolve, 30000); wake = () => { clearTimeout(timer); resolve(); }; });
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
