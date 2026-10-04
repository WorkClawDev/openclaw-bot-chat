'use client'

import { useCallback, useEffect, useState } from 'react'
import { agentApi, artifactsApi, runsApi, type AgentRun, type AgentRunEvent, type AgentApproval, type AgentArtifact } from '@/lib/api'

export const activeRunStatuses = new Set(['queued', 'running', 'waiting_input', 'waiting_approval', 'paused'])
export const runLabels: Record<string, string> = {
  queued: 'Queued', running: 'Working', waiting_input: 'Needs your input', waiting_approval: 'Approval needed',
  paused: 'Paused', succeeded: 'Completed', failed: 'Needs attention', cancelled: 'Stopped',
}
interface Activity { run?: AgentRun; events: AgentRunEvent[]; approvals: AgentApproval[]; files: AgentArtifact[]; loading: boolean; error: string }
const empty: Activity = { events: [], approvals: [], files: [], loading: true, error: '' }

export function useAgentActivity(botId: string, conversation: string) {
  const [activity, setActivity] = useState<Activity>(empty)
  const [revision, setRevision] = useState(0)
  const reload = useCallback(() => setRevision(value => value + 1), [])
  useEffect(() => {
    let disposed = false, busy = false, cursor = 0
    let runId: string | undefined
    let events: AgentRunEvent[] = []
    let files: AgentArtifact[] = []
    let signature = ''
    let timer: ReturnType<typeof setTimeout> | undefined
    const refresh = async () => {
      if (disposed || busy || document.hidden) return
      busy = true
      try {
        const [allRuns, allApprovals] = await Promise.all([runsApi.list(), agentApi.approvals()])
        if (disposed) return
        const runs = (allRuns || []).filter(run => run.bot_id ? run.bot_id === botId : run.conversation === conversation)
        const run = runs.find(item => activeRunStatuses.has(item.status)) || runs[0]
        const changedRun = run?.id !== runId
        if (changedRun) { runId = run?.id; cursor = 0; events = []; files = []; signature = '' }
        if (run && (changedRun || run.event_seq > cursor)) {
          let page: AgentRunEvent[]
          do {
            page = await runsApi.events(run.id, cursor)
            if (disposed) return
            if (page.length) { cursor = page.at(-1)!.seq; events = [...events, ...page] }
          } while (page.length === 200)
        }
        const nextSignature = run ? `${run.id}:${run.status}:${run.event_seq}` : ''
        if (run && nextSignature !== signature) { files = (await artifactsApi.list(run.id)) || []; signature = nextSignature }
        if (disposed) return
        const approvals = (allApprovals || []).filter(item => item.run_id === run?.id && item.status === 'pending')
        const next = { run, events, files, approvals, loading: false, error: '' }
        setActivity(previous => JSON.stringify(previous) === JSON.stringify(next) ? previous : next)
      } catch (error) {
        if (!disposed) setActivity(previous => ({ ...previous, loading: false, error: error instanceof Error ? error.message : 'Could not sync activity' }))
      } finally { busy = false }
    }
    // Coalesce bursts of streaming notifications into an incremental fetch.
    const notice = () => {
      if (timer) return
      timer = setTimeout(() => { timer = undefined; void refresh() }, 350)
    }
    void refresh()
    const poll = setInterval(() => void refresh(), 4000)
    window.addEventListener('agent-update', notice)
    document.addEventListener('visibilitychange', notice)
    return () => { disposed = true; clearInterval(poll); clearTimeout(timer); window.removeEventListener('agent-update', notice); document.removeEventListener('visibilitychange', notice) }
  }, [botId, conversation, revision])
  return { ...activity, reload }
}
