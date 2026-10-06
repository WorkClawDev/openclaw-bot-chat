import { defineConfig } from '@playwright/test'
import { existsSync } from 'node:fs'

const baseURL = process.env.CHAT_UI_URL || (process.env.CHAT_UI_START ? 'http://127.0.0.1:13002' : 'http://127.0.0.1:3000')
export default defineConfig({
  testDir: './tests', testMatch: ['agent-chat.spec.ts', 'access-management.spec.ts'], workers: 1, timeout: 45000,
  outputDir: '../run/agent-chat-ui/playwright',
  reporter: [['list'], ['json', { outputFile: '../run/agent-chat-ui/browser-results.json' }]],
  webServer: process.env.CHAT_UI_START ? { command: 'npm run start -- -H 127.0.0.1 -p 13002', url: baseURL, reuseExistingServer: false } : undefined,
  use: {
    baseURL,
    viewport: { width: 1440, height: 1000 },
    launchOptions: { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || (existsSync('/usr/bin/chromium') ? '/usr/bin/chromium' : undefined) },
    trace: 'retain-on-failure', screenshot: 'only-on-failure',
  },
})
