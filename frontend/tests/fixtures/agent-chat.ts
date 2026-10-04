import { expect, type Page, type WebSocketRoute } from '@playwright/test'
import type { Message } from '../../src/lib/types'
import type { AgentRun, AgentRunEvent, AgentApproval } from '../../src/lib/api'

// Browser contracts use an isolated HTTP/MQTT fixture. Live persistence and
// broker checks remain in scripts/test-environment/browser-smoke.mjs.
const mqttPacket = require('mqtt-packet')
export const topic = 'chat/dm/user/ui-user/bot/research-agent'
export const groupTopic = 'chat/group/ui-team'
const content = 'Here is the next step. Keep the scope small, make the result reviewable, and validate the outcome.\n\n- Gather the source material\n- Compare the options\n- Share the final brief'

export function message(index: number, conversation = topic): Message {
  const own = index % 2 === 0
  return {
    id: `message-${index}`, conversation_id: conversation, topic: conversation, sender_id: own ? 'ui-user' : 'research-agent',
    sender_type: own ? 'user' : 'bot', from: { type: own ? 'user' : 'bot', id: own ? 'ui-user' : 'research-agent', name: own ? 'Alex' : 'Research partner' },
    to: conversation === groupTopic ? { type: 'group', id: 'ui-team' } : { type: own ? 'bot' : 'user', id: own ? 'research-agent' : 'ui-user' },
    content: { type: 'text', body: own ? `Help me review option ${index + 1}.` : `### Research note ${index + 1}\n\n${content}` },
    seq: index + 1, created_at: new Date(Date.UTC(2026, 9, 4, 8, 0, index * 10)).toISOString(),
  }
}

export async function fixture(page: Page, count = 500) {
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
  const open = async (mobile = false) => {
    await page.goto('/bots')
    await page.getByRole('button', { name: /Research partner Explore ideas/ }).click()
    await expect(page.getByTestId('chat-connection-status')).toContainText('Connected')
    if (!mobile) await expect(page.getByRole('heading', { name: 'Activity', exact: true })).toBeVisible()
    if (count) await expect(page.locator(`[data-message-id="message-${count - 1}"]`)).toBeVisible()
  }
  return { state, errors, publish, update, open }
}
