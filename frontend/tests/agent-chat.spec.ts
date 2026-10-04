import { test, expect, type Page, type WebSocketRoute } from '@playwright/test'
import type { Message } from '../src/lib/types'
import type { AgentRun, AgentRunEvent, AgentApproval } from '../src/lib/api'

// Browser contracts use an isolated HTTP/MQTT fixture. Live persistence and
// broker checks remain in scripts/test-environment/browser-smoke.mjs.
const mqttPacket = require('mqtt-packet')
const topic = 'chat/dm/user/ui-user/bot/research-agent'
const groupTopic = 'chat/group/ui-team'
const content = 'Here is the next step. Keep the scope small, make the result reviewable, and validate the outcome.\n\n- Gather the source material\n- Compare the options\n- Share the final brief'

function message(index: number, conversation = topic): Message {
  const own = index % 2 === 0
  return {
    id: `message-${index}`, conversation_id: conversation, topic: conversation, sender_id: own ? 'ui-user' : 'research-agent',
    sender_type: own ? 'user' : 'bot', from: { type: own ? 'user' : 'bot', id: own ? 'ui-user' : 'research-agent', name: own ? 'Alex' : 'Research partner' },
    to: conversation === groupTopic ? { type: 'group', id: 'ui-team' } : { type: own ? 'bot' : 'user', id: own ? 'research-agent' : 'ui-user' },
    content: { type: 'text', body: own ? `Help me review option ${index + 1}.` : `### Research note ${index + 1}\n\n${content}` },
    seq: index + 1, created_at: new Date(Date.UTC(2026, 9, 4, 8, 0, index * 10)).toISOString(),
  }
}

async function fixture(page: Page, count = 500) {
  const state = {
    messages: Array.from({ length: count }, (_, index) => message(index)),
    run: { id: 'workspace-run', bot_id: 'research-agent', conversation: topic, status: 'succeeded', cancel_requested: false, steps: 3, max_steps: 80, event_seq: 3 } as AgentRun,
    events: [
      { id: 'event-1', seq: 1, type: 'queued', data: {}, created_at: '2026-10-04T09:00:00Z' },
      { id: 'event-2', seq: 2, type: 'tool_result', data: { tool: 'local__file_extract' }, created_at: '2026-10-04T09:00:01Z' },
      { id: 'event-3', seq: 3, type: 'succeeded', data: {}, created_at: '2026-10-04T09:00:02Z' },
    ] as AgentRunEvent[],
    approvals: [] as AgentApproval[], requests: [] as { path: string; body: any }[], published: 0,
  }
  let socket: WebSocketRoute | undefined
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  await page.addInitScript(() => { localStorage.setItem('access_token', 'isolated-ui-fixture'); localStorage.setItem('refresh_token', 'isolated-ui-fixture') })
  await page.routeWebSocket('**/fixture-mqtt', ws => {
    socket = ws
    const parser = mqttPacket.parser()
    parser.on('packet', (packet: any) => {
      if (packet.cmd === 'connect') ws.send(mqttPacket.generate({ cmd: 'connack', sessionPresent: false, returnCode: 0 }))
      if (packet.cmd === 'subscribe') ws.send(mqttPacket.generate({ cmd: 'suback', messageId: packet.messageId, granted: packet.subscriptions.map(() => 0) }))
      if (packet.cmd === 'unsubscribe') ws.send(mqttPacket.generate({ cmd: 'unsuback', messageId: packet.messageId }))
      if (packet.cmd === 'pingreq') ws.send(mqttPacket.generate({ cmd: 'pingresp' }))
      if (packet.cmd === 'publish') { state.published++; if (packet.qos === 1) ws.send(mqttPacket.generate({ cmd: 'puback', messageId: packet.messageId })) }
    })
    ws.onMessage(data => parser.parse(Buffer.isBuffer(data) ? data : Buffer.from(data)))
  })
  await page.route('**/api/v1/**', async route => {
    const url = new URL(route.request().url()), path = decodeURIComponent(url.pathname)
    let data: unknown = []
    if (route.request().method() === 'POST') {
      const body = route.request().postDataJSON(); state.requests.push({ path, body })
      if (path.endsWith('/decision')) state.approvals = []
      if (path.endsWith('/resume')) state.run = { ...state.run, status: 'queued' }
      if (path.endsWith('/cancel')) state.run = { ...state.run, status: 'cancelled' }
    } else if (path.endsWith('/auth/me')) data = { id: 'ui-user', username: 'Alex', email: 'ui@example.invalid' }
    else if (path === '/api/v1/bots') data = [
      { id: 'research-agent', name: 'Research partner', description: 'Explore ideas. Find the useful details.', status: 'enabled', avatar: '/bot-avatars/green-signal.svg' },
      { id: 'writing-agent', name: 'Writing partner', description: 'From first draft to final version.', status: 'enabled', avatar: '/bot-avatars/coral-circuit.svg' },
      { id: 'operations-agent', name: 'Operations', description: 'Keep the everyday work moving.', status: 'enabled', avatar: '/bot-avatars/indigo-core.svg' },
    ]
    else if (path === '/api/v1/groups') data = [{ id: 'ui-team', name: 'Launch team', description: 'Planning our next release', owner_id: 'ui-user', member_count: 3 }]
    else if (path.endsWith('/members')) data = { users: [], bots: [] }
    else if (path === '/api/v1/conversations') data = [{ conversation_id: topic, last_message: state.messages.at(-1) }, { conversation_id: groupTopic, last_message: state.messages.at(-1) }]
    else if (path.endsWith('/realtime/bootstrap')) data = {
      broker: { ws_url: 'ws://127.0.0.1:3000/fixture-mqtt', tcp_url: '', qos: 0 }, client_id: 'isolated-chat-browser', principal_type: 'user', principal_id: 'ui-user',
      subscriptions: [topic, groupTopic, 'chat/dm/user/ui-user/bot/writing-agent'].map(topic => ({ topic, qos: 0 })), publish_topics: [topic, groupTopic, 'chat/dm/user/ui-user/bot/writing-agent'],
    }
    else if (path.startsWith('/api/v1/messages/')) data = path.includes('writing-agent') ? [] : state.messages.map(row => path.includes(groupTopic) ? { ...row, topic: groupTopic, conversation_id: groupTopic } : row)
    else if (path === '/api/v1/agent/runs') data = [state.run]
    else if (path.endsWith('/events')) data = state.events.filter(event => event.seq > Number(url.searchParams.get('after_seq') || 0))
    else if (path === '/api/v1/agent/approvals') data = state.approvals
    else if (path.endsWith('/artifacts')) data = [{ id: 'brief-file', run_id: 'workspace-run', file_name: 'launch-brief.md', version: 1, size: 2400, mime_type: 'text/markdown', sha256: 'fixture' }]
    else if (path.endsWith('/download')) data = { download_url: 'http://ui-fixture.invalid/result.md', file_name: 'launch-brief.md' }
    await route.fulfill({ json: { code: 0, data, message: 'ok' } })
  })
  await page.route('http://ui-fixture.invalid/result.md', route => route.fulfill({ contentType: 'text/markdown', headers: { 'Content-Disposition': 'attachment; filename="launch-brief.md"' }, body: '# Launch brief\n\nReviewed browser fixture.\n' }))
  const publish = (row: Message) => {
    socket!.send(mqttPacket.generate({ cmd: 'publish', topic: row.topic, qos: 0, retain: false, payload: JSON.stringify(row) }))
  }
  const update = async () => { await page.evaluate(() => window.dispatchEvent(new Event('agent-update'))) }
  const open = async () => {
    await page.goto('/bots')
    await page.getByRole('button', { name: /Research partner Explore ideas/ }).click()
    await expect(page.getByTestId('chat-connection-status')).toContainText('Connected')
    await expect(page.getByRole('heading', { name: 'Activity', exact: true })).toBeVisible()
    if (count) await expect(page.locator(`[data-message-id="message-${count - 1}"]`)).toBeVisible()
  }
  return { state, errors, publish, update, open }
}

async function anchor(page: Page, testId = 'bot-message-scroll') {
  return page.getByTestId(testId).evaluate(element => {
    const top = element.getBoundingClientRect().top
    const row = [...element.querySelectorAll<HTMLElement>('[data-message-id]')].find(row => row.getBoundingClientRect().top >= top)
    if (!row) throw new Error('No visible message anchor')
    return { id: row.dataset.messageId!, y: row.getBoundingClientRect().top }
  })
}
const atBottom = (page: Page, testId = 'bot-message-scroll') => page.getByTestId(testId).evaluate(element => element.scrollHeight - element.clientHeight - element.scrollTop)

test('500-message history stays bounded and never pulls an upward reader to new output', async ({ page }, testInfo) => {
  const f = await fixture(page); await f.open()
  expect(await page.locator('[data-message-id]').count()).toBeLessThan(50)
  await expect.poll(() => atBottom(page)).toBeLessThan(5)
  await page.getByTestId('bot-message-scroll').hover(); await page.mouse.wheel(0, -1100)
  await expect(page.getByRole('button', { name: 'Back to latest' })).toBeVisible()
  await page.waitForTimeout(250); const before = await anchor(page)
  f.publish(message(500)); f.publish(message(501))
  await expect(page.getByRole('button', { name: /new · Latest messages/ })).toBeVisible()
  const after = await page.locator(`[data-message-id="${before.id}"]`).boundingBox()
  expect(Math.abs(after!.y - before.y)).toBeLessThan(4)
  await page.getByRole('button', { name: /Latest messages/ }).click()
  await expect.poll(() => atBottom(page)).toBeLessThan(5)
  f.publish(message(502)); await expect(page.locator('[data-message-id="message-502"]')).toBeVisible()
  await expect.poll(() => atBottom(page)).toBeLessThan(5)
  await page.getByRole('textbox', { name: 'Message Research partner...' }).fill('An editable multiline task description.\n'.repeat(12))
  await expect.poll(() => atBottom(page)).toBeLessThan(5)
  const metrics = await page.getByTestId('bot-message-scroll').evaluate(async element => {
    const frames: number[] = []; let before = performance.now()
    for (let i = 0; i < 60; i++) { element.scrollTop -= 24; await new Promise(requestAnimationFrame); const now = performance.now(); frames.push(now - before); before = now }
    frames.sort((a, b) => a - b)
    return { rendered_messages: document.querySelectorAll('[data-message-id]').length, frame_p50_ms: frames[30], frame_p95_ms: frames[57] }
  })
  await testInfo.attach('scroll-metrics', { body: JSON.stringify(metrics), contentType: 'application/json' })
  expect(metrics.rendered_messages).toBeLessThan(50); expect(f.errors).toEqual([])
})

test('streamed agent text follows at the bottom and preserves the history anchor when reading', async ({ page }) => {
  const f = await fixture(page, 80); f.state.run.status = 'running'; await f.open()
  const stream = (text: string) => { const seq = f.state.events.length + 1; f.state.events.push({ id: `event-${seq}`, seq, type: 'assistant_delta', data: { text }, created_at: '2026-10-04T09:00:05Z' }); f.state.run.event_seq = seq }
  stream('I am comparing the options.\n'.repeat(16)); await f.update()
  await expect(page.getByLabel('Agent is responding')).toContainText('comparing the options')
  await expect.poll(() => atBottom(page)).toBeLessThan(5)
  await page.getByTestId('bot-message-scroll').hover(); await page.mouse.wheel(0, -1300)
  await expect(page.getByRole('button', { name: 'Back to latest' })).toBeVisible()
  await page.waitForTimeout(250); const before = await anchor(page)
  stream('I am comparing the options.\n'.repeat(35)); await f.update(); await page.waitForTimeout(700)
  expect(Math.abs((await page.locator(`[data-message-id="${before.id}"]`).boundingBox())!.y - before.y)).toBeLessThan(4)
  await page.getByRole('button', { name: 'Back to latest' }).click(); await expect.poll(() => atBottom(page)).toBeLessThan(5)
  expect(f.errors).toEqual([])
})

test('approval details, owner decisions, input, cancellation and deliverables remain actionable in chat', async ({ page }) => {
  const f = await fixture(page, 6)
  f.state.run.status = 'waiting_approval'
  f.state.approvals = [{ id: 'approval-one', run_id: 'workspace-run', tool: 'local__fs_replace_text', arguments: { path: '/output/launch-brief.md', old_text: 'draft', new_text: 'reviewed' }, parameter_hash: 'fixture', status: 'pending', expires_at: '2099-01-01T00:00:00Z' }]
  await f.open(); await page.getByText('Operation details', { exact: true }).click()
  await expect(page.getByText('/output/launch-brief.md', { exact: false })).toBeVisible()
  expect(f.state.requests).toEqual([])
  await page.getByRole('button', { name: 'Approve once' }).click()
  await expect(page.getByRole('button', { name: 'Approve once' })).toHaveCount(0)
  expect(f.state.requests[0]).toEqual({ path: '/api/v1/agent/approvals/approval-one/decision', body: { approved: true } })
  f.state.run.status = 'waiting_input'; await f.update()
  await page.getByLabel('Your input is needed').fill('Prepare it for the weekly product review.')
  await page.getByRole('button', { name: 'Save and continue' }).click()
  await expect.poll(() => f.state.requests.some(request => request.path.endsWith('/workspace-run/resume') && request.body.input.includes('weekly product review'))).toBe(true)
  const download = page.waitForEvent('download'); await page.getByRole('button', { name: 'launch-brief.md', exact: true }).click()
  expect((await download).suggestedFilename()).toBe('launch-brief.md')
  await page.getByRole('button', { name: 'Stop this run' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Stopped' })).toBeVisible()
  expect(f.errors).toEqual([])
})

test('switching agents clears unrelated activity and starter prompts stay editable', async ({ page }, testInfo) => {
  const f = await fixture(page, 6); await f.open()
  await page.getByRole('button', { name: /Writing partner From first draft/ }).click()
  await expect(page.getByRole('heading', { name: 'What are we working on?' })).toBeVisible()
  await expect(page.getByText('Room for your next idea', { exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'launch-brief.md', exact: true })).toHaveCount(0)
  await page.screenshot({ path: testInfo.outputPath('agent-welcome.png') })
  await page.getByRole('button', { name: /Research & synthesize/ }).click()
  await expect(page.getByRole('textbox', { name: 'Message Writing partner...' })).toHaveValue(/research a topic/)
  expect(f.state.published).toBe(0)
  await page.getByRole('textbox', { name: 'Message Writing partner...' }).evaluate(element => element.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', isComposing: true, bubbles: true })))
  expect(f.state.published).toBe(0)
  expect(f.errors).toEqual([])
})

test('another bot cannot appear in activity by reusing the conversation string', async ({ page }) => {
  const f = await fixture(page, 6)
  f.state.run.bot_id = 'writing-agent'
  f.state.run.status = 'waiting_approval'
  await f.open()
  await expect(page.getByText('Room for your next idea', { exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Stop this run' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'launch-brief.md', exact: true })).toHaveCount(0)
  expect(f.errors).toEqual([])
})

test('mobile activity, dark mode, reduced motion and navigation fit without horizontal overflow', async ({ page }, testInfo) => {
  const f = await fixture(page, 12); await f.open()
  await page.setViewportSize({ width: 390, height: 844 })
  await expect(page.getByRole('heading', { name: 'Activity', exact: true })).toBeHidden()
  await expect(page.getByRole('button', { name: 'Send message', exact: true })).toBeVisible()
  for (const link of await page.getByRole('navigation', { name: 'Workspace navigation' }).getByRole('link').all()) await expect(link).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390)
  await page.screenshot({ path: testInfo.outputPath('mobile-chat.png') })
  await page.getByRole('button', { name: 'Activity', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Activity', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Close activity' }).click()
  await expect(page.getByRole('button', { name: 'Send message', exact: true })).toBeVisible()
  await page.evaluate(() => document.body.classList.add('bg-theme-dark'))
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.screenshot({ path: testInfo.outputPath('mobile-dark.png') })
  await page.getByTestId('bot-message-scroll').hover(); await page.mouse.wheel(0, -700)
  await page.getByRole('button', { name: 'Back to latest' }).click()
  await expect.poll(() => atBottom(page)).toBeLessThan(5)
  expect(f.errors).toEqual([])
})

test('group messages use the same stable virtual scrolling behavior', async ({ page }) => {
  const f = await fixture(page, 300); await f.open()
  await page.getByRole('link', { name: 'Groups', exact: true }).click()
  await page.getByRole('button', { name: /Launch team Planning our next release/ }).click()
  await expect(page.locator('[data-message-id="message-299"]')).toBeVisible()
  await page.getByTestId('group-message-scroll').hover(); await page.mouse.wheel(0, -1000)
  await expect(page.getByRole('button', { name: 'Back to latest' })).toBeVisible()
  await page.waitForTimeout(200); const before = await anchor(page, 'group-message-scroll')
  f.publish(message(300, groupTopic))
  await expect(page.getByRole('button', { name: /new · Latest messages/ })).toBeVisible()
  expect(Math.abs((await page.locator(`[data-message-id="${before.id}"]`).boundingBox())!.y - before.y)).toBeLessThan(4)
  expect(await page.locator('[data-message-id]').count()).toBeLessThan(50)
  expect(f.errors).toEqual([])
})

test('agent workspace presents a readable brief with results alongside the conversation', async ({ page }, testInfo) => {
  const f = await fixture(page, 4)
  f.state.messages[0].content.body = 'Help me compare three ways to launch our new workspace. Focus on learning quickly with a small team.'
  f.state.messages[1].content.body = 'I’ll compare the options, outline the tradeoffs, and put the recommendation into a brief you can share.'
  f.state.messages[2].content.body = 'A small private beta sounds right. What should we measure first?'
  f.state.messages[3].content.body = '## Start with a focused private beta\n\nInvite **20–30 teams** with a real weekly workflow. The goal is to learn where the agent saves time and where people need more control.\n\n| Signal | What to look for |\n| --- | --- |\n| First useful result | Can a team finish one real task? |\n| Repeat usage | Do they return with another task? |\n| Confidence | Are approvals and outcomes clear? |\n\n### A practical first week\n\n1. Onboard five teams and observe their first session.\n2. Review incomplete tasks and unclear handoffs.\n3. Share improvements with the cohort on Friday.\n\nThe launch brief is ready in **Deliverables**. We can refine the onboarding plan next.'
  await f.open(); await page.screenshot({ path: testInfo.outputPath('agent-workspace-desktop.png') })
  expect(f.errors).toEqual([])
})
