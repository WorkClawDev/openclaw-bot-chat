import { access } from 'node:fs/promises';
import { accountFile, api, readAccount, saveAccount, settings, reportFailure } from './lib.mjs';

try {
  const config = await settings();
  const base = config.TEST_PUBLIC_URL;
  let account;
  try {
    await access(accountFile);
    account = await readAccount();
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    account = { username: config.TEST_USERNAME, email: config.TEST_EMAIL, password: config.TEST_PASSWORD };
  }
  let auth;
  try {
    auth = await api(base, 'POST', '/api/v1/auth/login', { body: { username: account.username, password: account.password } });
  } catch (error) {
    if (error.status !== 401 && error.status !== 400) throw error;
    auth = await api(base, 'POST', '/api/v1/auth/register', { body: { username: account.username, email: account.email, password: account.password, nickname: 'Test User' } });
  }
  Object.assign(account, auth);
  const token = account.tokens.access_token;
  const bots = await api(base, 'GET', '/api/v1/bots', { token });
  account.bot = bots.find(bot => bot.id === account.bot?.id) || bots.find(bot => bot.name === 'Echo Test Bot');
  if (!account.bot) {
    account.bot = await api(base, 'POST', '/api/v1/bots', { token, body: { name: 'Echo Test Bot', description: 'Repeats text, images and audio for local integration testing.', bot_type: 'assistant', is_public: false } });
    account.bot_key = undefined;
  }
  if (account.bot_key) {
    try {
      await api(base, 'GET', '/api/v1/bot-runtime/bootstrap', { botKey: account.bot_key });
    } catch (error) {
      if (error.status !== 401 && error.status !== 403) throw error;
      account.bot_key = undefined;
    }
  }
  if (!account.bot_key) {
    const key = await api(base, 'POST', `/api/v1/bots/${account.bot.id}/keys`, { token, body: { name: 'test environment' } });
    account.bot_key = key.key;
  }
  const groups = await api(base, 'GET', '/api/v1/groups', { token });
  account.group = groups.find(group => group.id === account.group?.id) || groups.find(group => group.name === 'Test Chat');
  if (!account.group) {
    account.group = await api(base, 'POST', '/api/v1/groups', { token, body: { name: 'Test Chat', description: 'Group chat integration fixture.' } });
  }
  const members = await api(base, 'GET', `/api/v1/groups/${account.group.id}/members`, { token });
  if (!(members.bots || []).some(member => member.bot_id === account.bot.id || member.bot?.id === account.bot.id || member.id === account.bot.id)) {
    try {
      await api(base, 'POST', `/api/v1/groups/${account.group.id}/members`, { token, body: { bot_id: account.bot.id } });
    } catch (error) {
      if (error.status !== 409) throw error;
    }
  }
  account.topic = `chat/dm/user/${account.user.id}/bot/${account.bot.id}`;
  account.group_topic = `chat/group/${account.group.id}`;
  const documents = await api(base, 'GET', '/api/v1/documents', { token });
  if (!documents.some(document => document.id === account.document_id)) {
    const document = await api(base, 'POST', '/api/v1/documents', { token, body: { title: 'Test environment notes', body: '# Test environment\n\nSend text, images or audio to **Echo Test Bot**. Use **Test Chat** to exercise group messaging.', summary: 'Local chat test fixtures.' } });
    account.document_id = document.id;
  }
  const tasks = await api(base, 'GET', '/api/v1/tasks', { token });
  if (!tasks.some(task => task.id === account.task_id)) {
    const task = await api(base, 'POST', '/api/v1/tasks', { token, body: { title: 'Try the test Bot', description: 'Send a message and verify the echo reply.', priority: 'normal', status: 'pending' } });
    account.task_id = task.id;
  }
  await saveAccount(account);
  console.log(`Test account and fixtures ready. Credentials: ${accountFile}`);
} catch (error) {
  reportFailure(error);
}
