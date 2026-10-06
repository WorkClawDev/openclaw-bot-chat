import { randomUUID } from 'node:crypto';
import { settings, readAccount, api, assert, reportFailure } from './lib.mjs';

// Only disposable resources created here are mutated or removed.
const cleanup = [];
try {
  const config = await settings();
  const base = config.TEST_PUBLIC_URL;
  assert(['127.0.0.1', 'localhost'].includes(new URL(base).hostname), 'Management acceptance requires the isolated local environment');
  const account = await readAccount();
  const auth = await api(base, 'POST', '/api/v1/auth/login', { body: { username: account.username, password: account.password } });
  const token = auth.tokens.access_token;
  const request = (method, path, body) => api(base, method, path, { token, body });
  const suffix = randomUUID().slice(0, 8);
  const create = async (kind, body) => {
    const item = await request('POST', `/api/v1/${kind}`, body);
    cleanup.push(() => request('DELETE', `/api/v1/${kind}/${item.id}`));
    return item;
  };
  const bot = await create('bots', { name: `V5 acceptance ${suffix}`, description: 'Disposable acceptance bot', bot_type: 'assistant', is_public: false });
  await request('PUT', `/api/v1/bots/${bot.id}`, { name: `V5 renamed ${suffix}` });
  assert((await request('GET', `/api/v1/bots/${bot.id}`)).name === `V5 renamed ${suffix}`, 'Bot edit did not persist');
  const bootstrap = await request('GET', '/api/v1/realtime/bootstrap');
  assert(bootstrap.subscriptions.some(item => item.topic === `chat/dm/user/${auth.user.id}/bot/${bot.id}`), 'New bot first-chat scope missing');

  const group = await create('groups', { name: `V5 group ${suffix}`, description: 'Disposable acceptance group' });
  await request('PUT', `/api/v1/groups/${group.id}`, { name: `V5 group edited ${suffix}` });
  await request('POST', `/api/v1/groups/${group.id}/members`, { bot_id: bot.id });
  const members = await request('GET', `/api/v1/groups/${group.id}/members`);
  assert(members.bots.some(item => item.bot_id === bot.id || item.bot?.id === bot.id || item.id === bot.id), 'Group bot membership missing');

  const document = await create('documents', { title: `V5 document ${suffix}`, body: '# Original\n\nFirst revision.', source_conversation_id: account.topic });
  await request('PUT', `/api/v1/documents/${document.id}`, { title: `V5 edited ${suffix}`, body: '# Updated\n\nVerified persisted content.' });
  const saved = await request('GET', `/api/v1/documents/${document.id}`);
  assert(saved.title === `V5 edited ${suffix}` && saved.body.includes('Verified persisted content.'), 'Document edit did not persist');

  const task = await create('tasks', { title: `V5 task ${suffix}`, priority: 'normal', status: 'pending' });
  await request('PUT', `/api/v1/tasks/${task.id}`, { title: `V5 task edited ${suffix}`, description: 'Verified task details' });
  assert((await request('GET', `/api/v1/tasks/${task.id}`)).title === `V5 task edited ${suffix}`, 'Task edit did not persist');
  console.log('PASS real bot create/edit/first-chat scope, group create/edit/membership, document create/edit/read, task create/edit/read');
} catch (error) {
  reportFailure(error);
} finally {
  let failed = false;
  for (const remove of cleanup.reverse()) {
    try { await remove(); } catch (error) { reportFailure(error); failed = true; }
  }
  if (cleanup.length && !failed) console.log('PASS deletion/archive cleanup of acceptance resources');
}
