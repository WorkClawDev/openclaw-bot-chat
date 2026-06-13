import test from 'node:test';
import assert from 'node:assert/strict';

import { buildBindingUrl } from '../src/bin/setup.ts';

test('setup QR prefers one-time binding token over legacy bot id', () => {
  const url = buildBindingUrl({
    BOT_CHAT_BACKEND_URL: 'https://api.example.test',
    BOT_CHAT_BIND_TOKEN: 'ocbb_abcdefghijklmnopqrstuvwxyz123456_12345678',
    BOT_CHAT_BOT_ID: '11111111-1111-1111-1111-111111111111',
    BOT_CHAT_BOT_KEY: 'ocbk_secret_should_not_leak',
  });

  assert.equal(url, 'https://api.example.test/openclaw/bind?package=%40workclawdev%2Fextension-bot-chat&channel=bot-chat&token=ocbb_abcdefghijklmnopqrstuvwxyz123456_12345678&botId=11111111-1111-1111-1111-111111111111');
  assert.doesNotMatch(url, /ocbk_/);
});

test('setup QR supports explicit binding URL and legacy bot id fallback', () => {
  assert.equal(
    buildBindingUrl({
      OPENCLAW_BOTCHAT_BIND_URL: 'https://mobile.example.test/openclaw/bind?token=ocbb_custom',
      BOT_CHAT_BACKEND_URL: 'https://api.example.test',
      BOT_CHAT_BIND_TOKEN: 'ocbb_ignored',
    }),
    'https://mobile.example.test/openclaw/bind?token=ocbb_custom',
  );

  assert.equal(
    buildBindingUrl({
      BOT_CHAT_BACKEND_URL: 'https://api.example.test/base',
      BOT_CHAT_BOT_ID: '22222222-2222-2222-2222-222222222222',
    }),
    'https://api.example.test/openclaw/bind?package=%40workclawdev%2Fextension-bot-chat&channel=bot-chat&botId=22222222-2222-2222-2222-222222222222',
  );
});
