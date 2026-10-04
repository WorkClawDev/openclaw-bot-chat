import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { api, assert, readAccount, settings, state, sleep, reportFailure } from './lib.mjs';

const require = createRequire(new URL('../../frontend/package.json', import.meta.url));
const { chromium } = require('@playwright/test');
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
  || (existsSync('/usr/bin/chromium') ? '/usr/bin/chromium' : undefined);
let browser;
try {
  const config = await settings();
  const account = await readAccount();
  browser = await chromium.launch({ headless: true, executablePath });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  page.setDefaultTimeout(30000);
  const pageErrors = [];
  page.on('pageerror', error => pageErrors.push(error.message));
  await page.goto(`${config.TEST_PUBLIC_URL}/login`, { waitUntil: 'networkidle' });
  await page.locator('input[autocomplete="username"]').fill(account.username);
  await page.locator('input[autocomplete="current-password"]').fill(account.password);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL('**/bots');
  await page.getByText(account.bot.name, { exact: true }).first().click();
  await page.getByText('online · bot', { exact: true }).waitFor();

  // Create both conversations while a previous MQTT identity is connected.
  // No reload is allowed between creation and publishing the first message.
  const cases = [
    { route: 'bots', create: 'Create bot', submit: 'Create Bot', placeholder: 'e.g. JARVIS' },
    { route: 'groups', create: 'Create group', submit: 'Create Group', placeholder: 'e.g. AI Council' },
  ];
  for (const item of cases) {
    if (item.route === 'groups') {
      await page.locator('a[href="/groups"]').first().click();
      await page.waitForURL('**/groups');
    }
    const name = `Browser scope ${item.route} ${Date.now()}`;
    await page.getByRole('button', { name: item.create, exact: true }).click();
    await page.getByPlaceholder(item.placeholder, { exact: true }).fill(name);
    const created = page.waitForResponse(response => new URL(response.url()).pathname === `/api/v1/${item.route}`
      && response.request().method() === 'POST');
    await page.getByRole('button', { name: item.submit, exact: true }).click();
    const response = await created;
    assert(response.ok(), `Creating ${item.route} failed`);
    const entity = (await response.json()).data;
    const topic = item.route === 'bots'
      ? `chat/dm/user/${account.user.id}/bot/${entity.id}`
      : `chat/group/${entity.id}`;
    const text = `First message without reload ${Date.now()}`;
    await page.getByRole('textbox', { name: `Message ${name}...`, exact: true }).fill(text);
    await page.getByRole('button', { name: 'Send message', exact: true }).click();
    const token = await page.evaluate(() => localStorage.getItem('access_token'));
    let persisted = false;
    for (let attempt = 0; attempt < 40; attempt++) {
      const rows = await api(config.TEST_PUBLIC_URL, 'GET', `/api/v1/messages/${topic}`, { token });
      if (rows.some(row => row.content?.body === text)) { persisted = true; break; }
      await sleep(250);
    }
    assert(persisted, `First ${item.route} message was not persisted`);
  }
  await page.goto(`${config.TEST_PUBLIC_URL}/assistant`, { waitUntil: 'networkidle' });
  await page.getByRole('heading', { name: '个人助手', exact: true }).waitFor();
  assert(pageErrors.length === 0, `Browser errors: ${pageErrors.join('; ')}`);
  await page.screenshot({ path: join(state, 'browser-scoped-realtime.png'), fullPage: true });
  console.log('PASS browser login, new bot/group first message without reload, persistence, and assistant rendering');
} catch (error) {
  reportFailure(error);
} finally {
  await browser?.close();
}
