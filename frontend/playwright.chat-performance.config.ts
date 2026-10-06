import { defineConfig } from '@playwright/test'
import chat from './playwright.chat.config'

export default defineConfig({
  ...chat,
  testMatch: 'chat-performance.spec.ts',
  timeout: 120000,
  outputDir: '../run/agent-chat-performance/playwright',
  reporter: [['list'], ['json', { outputFile: '../run/agent-chat-performance/results.json' }]],
  // DOM snapshots and screenshots in Playwright tracing distort frame timing.
  use: { ...chat.use, trace: 'off' },
})
