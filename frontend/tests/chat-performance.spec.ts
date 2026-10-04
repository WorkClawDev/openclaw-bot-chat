import { test, expect, type Page, type CDPSession } from '@playwright/test'
import { writeFile } from 'node:fs/promises'
import { fixture, message, groupTopic } from './fixtures/agent-chat'

// These tests load synthetic histories into the production UI through isolated
// HTTP/MQTT fixtures. They measure rendering, not backend pagination throughput.
const scenarios = [
  { name: 'desktop-1000', count: 1000, cpu: 1, mobile: false, group: false },
  { name: 'desktop-5000', count: 5000, cpu: 1, mobile: false, group: false },
  { name: 'desktop-10000', count: 10000, cpu: 1, mobile: false, group: false },
  { name: 'mobile-10000-cpu4', count: 10000, cpu: 4, mobile: true, group: false },
  { name: 'group-10000', count: 10000, cpu: 1, mobile: false, group: true },
]

function mixedMessage(index: number) {
  const row = message(index)
  switch (index % 10) {
    case 1:
      row.content.body = `## Analysis ${index}\n\n` + 'Review the source, explain the tradeoffs, and verify the result before continuing. '.repeat(16)
      break
    case 3:
      row.content.body = 'Here is the implementation:\n\n```typescript\n' + Array.from({ length: 36 }, (_, n) => `const task${n} = { id: ${n}, state: "complete", result: await runStep(${n}) };`).join('\n') + '\n```'
      break
    case 5:
      row.content.body = '| Step | Result | Evidence |\n| --- | --- | --- |\n' + Array.from({ length: 12 }, (_, n) => `| Step ${n + 1} | Verified | Source ${n + 1} |`).join('\n')
      break
    case 6:
      row.content = { type: 'image', url: 'http://ui-fixture.invalid/stress-image.svg', name: 'Performance fixture', meta: { asset: { width: 640, height: 360 } } }
      break
    case 7:
      row.content.body = `### 任务分析 ${index}\n\n` + '这是较长的多语言回复。我们会说明目标、比较方案，再逐步验证结果。'.repeat(26) + '\n\n- Review sources\n- Check assumptions\n- Save the deliverable'
      break
  }
  return row
}

interface Sample {
  frames: number[]
  longTasks: number[]
  maxRendered: number
  emptyFrames: number
  sampledFrames: number
  maxUncoveredPx: number
  distancePx: number
}
declare global {
  interface Window { finishChatSample?: () => Sample }
}

async function startSample(page: Page, testId: string) {
  await page.getByTestId(testId).evaluate(element => {
    const sample: Sample = { frames: [], longTasks: [], maxRendered: 0, emptyFrames: 0, sampledFrames: 0, maxUncoveredPx: 0, distancePx: 0 }
    let active = true, previousTime = 0, previousTop = element.scrollTop, frame = 0
    const start = performance.now()
    const observer = new PerformanceObserver(list => {
      for (const entry of list.getEntries()) if (entry.startTime >= start) sample.longTasks.push(entry.duration)
    })
    observer.observe({ type: 'longtask' })
    const tick = (time: number) => {
      if (!active) return
      if (previousTime) sample.frames.push(time - previousTime)
      previousTime = time
      sample.distancePx += Math.abs(element.scrollTop - previousTop)
      previousTop = element.scrollTop
      const viewport = element.getBoundingClientRect()
      const rows = [...element.querySelectorAll<HTMLElement>('[data-message-id]')]
      const visible = rows.map(row => row.getBoundingClientRect()).filter(rect => rect.bottom > viewport.top && rect.top < viewport.bottom)
      const covered = visible.reduce((sum, rect) => sum + Math.max(0, Math.min(rect.bottom, viewport.bottom) - Math.max(rect.top, viewport.top)), 0)
      sample.sampledFrames++
      sample.maxRendered = Math.max(sample.maxRendered, rows.length)
      if (!visible.length) sample.emptyFrames++
      sample.maxUncoveredPx = Math.max(sample.maxUncoveredPx, viewport.height - covered)
      frame = requestAnimationFrame(tick)
    }
    frame = requestAnimationFrame(tick)
    window.finishChatSample = () => {
      active = false; cancelAnimationFrame(frame)
      for (const entry of observer.takeRecords()) if (entry.startTime >= start) sample.longTasks.push(entry.duration)
      observer.disconnect()
      return sample
    }
  })
}

async function finishSample(page: Page) {
  const sample = await page.evaluate(() => window.finishChatSample!())
  const frames = [...sample.frames].sort((a, b) => a - b)
  const percentile = (p: number) => Math.round((frames[Math.floor((frames.length - 1) * p)] || 0) * 10) / 10
  return {
    frame_p50_ms: percentile(.5), frame_p95_ms: percentile(.95), frame_p99_ms: percentile(.99),
    frame_max_ms: Math.round(Math.max(0, ...frames) * 10) / 10,
    frames_over_33ms: frames.filter(ms => ms > 33.5).length,
    frames_over_50ms: frames.filter(ms => ms > 50.5).length,
    long_tasks: sample.longTasks.length, longest_task_ms: Math.max(0, ...sample.longTasks),
    max_rendered_messages: sample.maxRendered, empty_frames: sample.emptyFrames,
    sampled_frames: sample.sampledFrames, max_uncovered_px: Math.round(sample.maxUncoveredPx),
    distance_px: Math.round(sample.distancePx),
  }
}

async function gesture(page: Page, cdp: CDPSession, testId: string, distance: number, mobile: boolean, speed = 1800) {
  const rect = (await page.getByTestId(testId).boundingBox())!
  if (mobile) {
    // Headless Chromium can acknowledge synthesizeScrollGesture(touch) without
    // dispatching touchmove. Send real touch sequences inside the viewport.
    const direction = Math.sign(distance)
    let remaining = Math.abs(distance)
    while (remaining > 0) {
      const length = Math.min(remaining, rect.height - 100)
      const start = direction > 0 ? rect.y + 50 : rect.y + rect.height - 50
      const x = rect.x + rect.width / 2
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y: start }] })
      const steps = Math.max(4, Math.ceil(length / speed * 60))
      for (let step = 1; step <= steps; step++) {
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y: start + direction * length * step / steps }] })
        await page.waitForTimeout(16)
      }
      await page.waitForTimeout(80)
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
      remaining -= length
    }
    return
  }
  await cdp.send('Input.synthesizeScrollGesture', {
    x: rect.x + rect.width / 2, y: rect.y + rect.height / 2,
    yDistance: distance, speed, gestureSourceType: 'mouse', preventFling: true,
  })
}

async function readingAnchor(page: Page, testId: string) {
  return page.getByTestId(testId).evaluate(element => {
    const viewport = element.getBoundingClientRect()
    const row = [...element.querySelectorAll<HTMLElement>('[data-message-id]')].find(row => {
      const rect = row.getBoundingClientRect(); return rect.bottom > viewport.top + 5 && rect.top < viewport.bottom
    })!
    return { id: row.dataset.messageId!, y: row.getBoundingClientRect().top }
  })
}

for (const scenario of scenarios) test.describe(scenario.name, () => {
  test.use({ isMobile: scenario.mobile, hasTouch: scenario.mobile, viewport: scenario.mobile ? { width: 390, height: 844 } : { width: 1440, height: 1000 } })
  test('native scrolling, seeks and arriving messages', async ({ page }, testInfo) => {
  const cdp = await page.context().newCDPSession(page)
  if (scenario.mobile) {
    await page.setViewportSize({ width: 390, height: 844 })
    await cdp.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 1 })
  }
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: scenario.cpu })
  const f = await fixture(page, scenario.count)
  f.state.messages = Array.from({ length: scenario.count }, (_, index) => mixedMessage(index))
  await page.route('http://ui-fixture.invalid/stress-image.svg', async route => {
    await new Promise(resolve => setTimeout(resolve, 150))
    await route.fulfill({ contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect width="640" height="360" fill="#edf3ef"/><path d="M60 280L200 160L320 210L480 80L580 120" fill="none" stroke="#23745b" stroke-width="10"/></svg>' })
  })
  const started = Date.now()
  await f.open(scenario.mobile)
  let testId = 'bot-message-scroll'
  if (scenario.group) {
    await page.getByRole('link', { name: 'Groups', exact: true }).click()
    await page.getByRole('button', { name: /Launch team Planning our next release/ }).click()
    await expect(page.locator(`[data-message-id="message-${scenario.count - 1}"]`)).toBeVisible()
    testId = 'group-message-scroll'
  }
  const openMs = Date.now() - started
  await page.waitForTimeout(500)
  if (process.env.CHAT_PERF_PROFILE) {
    await cdp.send('Profiler.enable')
    await cdp.send('Profiler.start')
  }
  await startSample(page, testId)
  await gesture(page, cdp, testId, 9000, scenario.mobile)
  await gesture(page, cdp, testId, -4000, scenario.mobile)
  await gesture(page, cdp, testId, 6000, scenario.mobile, 6000)
  const scrolling = await finishSample(page)
  if (process.env.CHAT_PERF_PROFILE) {
    const { profile } = await cdp.send('Profiler.stop')
    await writeFile(testInfo.outputPath('scroll.cpuprofile'), JSON.stringify(profile))
  }
  await writeFile(testInfo.outputPath('scrolling.json'), JSON.stringify(scrolling, null, 2))

  // Large seeks exercise measurements outside the already visited viewport.
  const seeks = []
  for (const fraction of [.05, .5, .95]) {
    await page.getByTestId(testId).evaluate((element, fraction) => { element.scrollTop = (element.scrollHeight - element.clientHeight) * fraction }, fraction)
    await page.waitForTimeout(250)
    seeks.push(await page.getByTestId(testId).evaluate(element => ({ top: element.scrollTop, rendered: element.querySelectorAll('[data-message-id]').length })))
  }
  const before = await readingAnchor(page, testId)
  await startSample(page, testId)
  for (let index = 0; index < 100; index++) {
    const row = message(scenario.count + index, scenario.group ? groupTopic : undefined)
    f.publish(row)
    await page.waitForTimeout(50)
  }
  await expect(page.getByRole('button', { name: /new · Latest messages/ })).toBeVisible()
  const anchor = (await page.locator(`[data-message-id="${before.id}"]`).boundingBox())!
  const anchorShift = Math.abs(anchor.y - before.y)
  const incoming = await finishSample(page)
  await page.getByRole('button', { name: /Latest messages/ }).click()
  await expect.poll(() => page.getByTestId(testId).evaluate(element => element.scrollHeight - element.clientHeight - element.scrollTop), { timeout: 15000 }).toBeLessThan(5)
  await expect(page.locator(`[data-message-id="message-${scenario.count + 99}"]`)).toBeVisible()
  await page.screenshot({ path: testInfo.outputPath('large-history.png') })
  const result = { ...scenario, profiled: !!process.env.CHAT_PERF_PROFILE, open_ms: openMs, scrolling, incoming, anchor_shift_px: anchorShift, seeks, errors: f.errors }
  await writeFile(testInfo.outputPath('performance.json'), JSON.stringify(result, null, 2))
  await testInfo.attach('performance', { body: JSON.stringify(result), contentType: 'application/json' })
  for (const sample of [scrolling, incoming]) {
    expect(sample.max_rendered_messages).toBeLessThan(60)
    expect(sample.empty_frames).toBe(0)
    expect(sample.sampled_frames).toBeGreaterThan(60)
  }
  expect(anchorShift).toBeLessThan(4)
  expect(scrolling.distance_px).toBeGreaterThan(12000)
  expect(f.errors).toEqual([])
})
})

for (const cpu of [1, 4]) test(`streaming-10000-cpu${cpu}`, async ({ page }, testInfo) => {
  const cdp = await page.context().newCDPSession(page)
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: cpu })
  const f = await fixture(page, 10000)
  f.state.run.status = 'running'
  await f.open()
  const stream = async (index: number) => {
    const seq = f.state.events.length + 1
    f.state.events.push({ id: `stream-${seq}`, seq, type: 'assistant_delta', data: { text: `Current step ${index}.\n` + 'Evaluating the evidence and checking the result.\n'.repeat(index + 1) }, created_at: '2026-10-04T09:00:05Z' })
    f.state.run.event_seq = seq
    await f.update()
    await page.waitForTimeout(100)
  }
  await startSample(page, 'bot-message-scroll')
  for (let index = 0; index < 30; index++) await stream(index)
  await expect(page.getByLabel('Agent is responding')).toContainText('Current step 29.')
  await expect.poll(() => page.getByTestId('bot-message-scroll').evaluate(element => element.scrollHeight - element.clientHeight - element.scrollTop)).toBeLessThan(5)
  const following = await finishSample(page)

  await startSample(page, 'bot-message-scroll')
  await Promise.all([
    gesture(page, cdp, 'bot-message-scroll', 10000, false, 2200),
    (async () => { for (let index = 30; index < 60; index++) await stream(index) })(),
  ])
  const scrolling = await finishSample(page)
  await page.waitForTimeout(200)
  const before = await readingAnchor(page, 'bot-message-scroll')
  for (let index = 60; index < 70; index++) await stream(index)
  await page.waitForTimeout(500)
  const after = (await page.locator(`[data-message-id="${before.id}"]`).boundingBox())!
  const anchorShift = Math.abs(before.y - after.y)
  const result = { name: `streaming-10000-cpu${cpu}`, count: 10000, cpu, following, scrolling, anchor_shift_px: anchorShift, errors: f.errors }
  await writeFile(testInfo.outputPath('performance.json'), JSON.stringify(result, null, 2))
  await testInfo.attach('performance', { body: JSON.stringify(result), contentType: 'application/json' })
  expect(anchorShift).toBeLessThan(4)
  expect(following.empty_frames + scrolling.empty_frames).toBe(0)
  expect(f.errors).toEqual([])
})
