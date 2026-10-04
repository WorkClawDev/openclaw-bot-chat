'use client'

import Link from 'next/link'
import { AgentIcon } from './AgentIcon'
import { useState } from 'react'
import { agentApi, artifactsApi, runsApi } from '@/lib/api'
import { activeRunStatuses, runLabels, useAgentActivity } from './useAgentActivity'

export type AgentActivityState = ReturnType<typeof useAgentActivity>
const eventLabels: Record<string, string> = {
  queued: 'Task received', claimed: 'Started working', running: 'Working', model_request: 'Thinking',
  model_response: 'Response prepared', tool_intent: 'Using a tool', tool_result: 'Tool completed',
  waiting_approval: 'Waiting for approval', waiting_input: 'Waiting for your input',
  succeeded: 'Work completed', cancelled: 'Work stopped', failed: 'Execution failed', resumed: 'Work resumed',
}
function toolLabel(tool: string) { return tool.replace(/^local__|^filesystem__/, '').replaceAll('_', ' ') }

export function AgentActivity({ activity, onClose }: { activity: AgentActivityState; onClose: () => void }) {
  const { run, events, files, approvals, error, loading, reload } = activity
  const [busy, setBusy] = useState(''), [actionError, setActionError] = useState(''), [input, setInput] = useState('')
  const perform = async (id: string, action: () => Promise<unknown>) => {
    setBusy(id); setActionError('')
    try { await action(); reload() } catch (e) { setActionError(e instanceof Error ? e.message : 'Please try again') }
    finally { setBusy('') }
  }
  const steps = events.filter(event => event.type !== 'assistant_delta')
  const download = (id: string) => perform(id, async () => {
    const file = await artifactsApi.download(id)
    if (!file.download_url) throw new Error('Download unavailable. Please try again.')
    const link = document.createElement('a'); link.href = file.download_url; link.download = file.file_name || 'download'; link.click()
  })
  return <aside id="agent-activity" aria-label="Agent activity" className="agent-activity scrollbar-thin">
    <div className="flex items-center justify-between gap-2">
      <div><p className="agent-eyebrow">IN THIS WORKSPACE</p><h2 className="mt-1 text-base font-semibold">Activity</h2></div>
      <button onClick={onClose} className="agent-icon-action" aria-label="Close activity"><AgentIcon name="close" size={16} /></button>
    </div>
    {(error || actionError) && <div role="alert" className="agent-error">{actionError || error}<button onClick={reload} className="ml-2 underline">Retry</button></div>}
    {loading ? <p role="status" className="py-6 text-sm text-slate-500">Loading activity…</p> : !run ? <div className="agent-activity-empty"><span className="agent-empty-orbit"><AgentIcon name="spark" size={28} /></span><h3>Room for your next idea</h3><p>As your agent works, its steps, requests and files appear here.</p></div> : <>
      <section className="agent-run-summary">
        <p className="agent-eyebrow">{run.task_id ? 'LATEST TASK' : 'CURRENT CONVERSATION'}</p>
        <div className="mt-3 flex items-center gap-2"><span className={`agent-status-dot status-${run.status} ${run.status === 'running' ? 'is-working' : ''}`} /><h3 className="text-sm font-semibold" role="status">{run.cancel_requested ? 'Stopping…' : runLabels[run.status] || run.status}</h3></div>
        <p className="mt-2 text-xs text-slate-500">{run.steps} execution steps recorded</p>
        {run.error && <p role="alert" className="mt-3 break-words text-xs text-red-700">{run.error}</p>}
        {activeRunStatuses.has(run.status) && <button disabled={!!busy || run.cancel_requested} onClick={() => void perform('cancel', () => runsApi.action(run.id, 'cancel'))} className="agent-stop-button">{busy === 'cancel' ? 'Stopping…' : 'Stop this run'}</button>}
        {run.task_id && <Link href="/tasks" className="mt-3 block text-xs font-medium text-primary-600">Review task →</Link>}
      </section>
      {approvals.map(approval => <section key={approval.id} className="agent-approval">
        <p className="agent-eyebrow">YOUR DECISION</p><h3 className="mt-2 text-sm font-semibold">Allow {toolLabel(approval.tool)}?</h3>
        <p className="mt-2 text-xs text-slate-600">Review the exact operation before continuing.</p>
        <details className="mt-3"><summary className="cursor-pointer text-xs font-medium">Operation details</summary><pre className="mt-2 max-h-52 overflow-auto whitespace-pre-wrap break-all text-xs">{JSON.stringify(approval.arguments, null, 2)}</pre></details>
        <p className="mt-3 text-xs text-slate-500">Valid until {new Date(approval.expires_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</p>
        <div className="mt-3 flex gap-2"><button className="agent-primary-button" disabled={!!busy || Date.parse(approval.expires_at) <= Date.now()} onClick={() => void perform(approval.id, () => agentApi.decide(approval.id, true))}>Approve once</button><button className="agent-secondary-button" disabled={!!busy} onClick={() => void perform(approval.id, () => agentApi.decide(approval.id, false))}>Decline</button></div>
      </section>)}
      {['waiting_input', 'paused', 'failed'].includes(run.status) && <form className="agent-input-request" onSubmit={event => { event.preventDefault(); void perform('resume', async () => { await runsApi.action(run.id, 'resume', input); setInput('') }) }}>
        <label htmlFor="agent-follow-up" className="text-sm font-semibold">{run.status === 'waiting_input' ? 'Your input is needed' : 'Continue this work'}</label>
        <textarea id="agent-follow-up" value={input} onChange={event => setInput(event.target.value)} placeholder="Add context or clarify the next step…" rows={3} className="mt-3 w-full resize-y rounded-lg border border-slate-200 bg-white p-3 text-sm" />
        <button className="agent-primary-button mt-2" disabled={!!busy || (run.status === 'waiting_input' && !input.trim())}>Save and continue</button>
      </form>}
      <section><div className="flex items-center justify-between"><h3 className="agent-section-label">Execution</h3><span className="text-xs text-slate-400">{steps.length} events</span></div>
        <ol className="agent-steps">{steps.slice(-8).map(event => <li key={event.id || event.seq}><span className="agent-step-marker" /><div className="min-w-0"><p className="text-xs font-medium">{eventLabels[event.type] || event.type.replaceAll('_', ' ')}</p>{typeof event.data.tool === 'string' && <p className="mt-1 break-words text-xs text-slate-500">{toolLabel(event.data.tool)}</p>}{typeof event.data.note === 'string' && <p className="mt-1 break-words text-xs text-slate-500">{event.data.note}</p>}</div></li>)}</ol>
        {steps.length > 8 && <Link href="/assistant" className="text-xs text-primary-600">View full history →</Link>}
      </section>
      <section><div className="flex items-center justify-between"><h3 className="agent-section-label">Deliverables</h3><span className="text-xs text-slate-400">{files.length}</span></div>
        {files.length === 0 ? <p className="mt-3 text-xs leading-relaxed text-slate-500">Files created by this run will appear here.</p> : <div className="mt-3 space-y-2">{files.map(file => <div key={file.id} className="agent-deliverable"><span className="agent-file-icon"><AgentIcon name="file" size={18} /></span><div className="min-w-0 flex-1"><button className="block w-full truncate text-left text-xs font-medium" disabled={!!busy} onClick={() => void download(file.id)} title={file.file_name}>{file.file_name}</button><p className="mt-1 text-[11px] text-slate-500">{Math.max(1, Math.round(file.size / 1024))} KB · v{file.version}</p>{file.document_id && <Link href={`/documents/${file.document_id}`} className="text-xs text-primary-600">Open document</Link>}</div></div>)}</div>}
      </section>
    </>}
    <Link href="/assistant" className="agent-all-activity">All work, memory & schedules <AgentIcon name="arrow" size={12} /></Link>
  </aside>
}
