'use client'

import { useEffect, useMemo, useRef, useState } from 'react'
import { Avatar } from '@/components/Avatar'
import type { Bot, ComposerMessageInput, Conversation, Message, RealtimeConnectionState } from '@/lib/types'
import { AgentIcon } from './AgentIcon'
import { AgentActivity } from './AgentActivity'
import { ChatInput } from './ChatInput'
import { MessageTimeline, type MessageTimelineHandle } from './MessageTimeline'
import { runLabels, useAgentActivity } from './useAgentActivity'

interface Props {
  bot: Bot
  conversation: Conversation
  messages: Message[]
  userId?: string
  mentions: string[]
  loading: boolean
  connectionState: RealtimeConnectionState
  onBack: () => void
  onConfigure: () => void
  onSend: (input: ComposerMessageInput) => Promise<void>
}
const starters = [
  { mark: 'spark' as const, title: 'Research & synthesize', detail: 'Turn a question into a clear brief', prompt: 'Help me research a topic and prepare a concise brief with sources. First, ask me what I want to explore.' },
  { mark: 'file' as const, title: 'Work with files', detail: 'Analyze, organize, or create a document', prompt: 'Help me work with a file. Ask me what result I need, then help me analyze it or create a deliverable.' },
  { mark: 'check' as const, title: 'Plan the next step', detail: 'Break a goal into practical actions', prompt: 'Help me turn a goal into an actionable plan. Ask me about the goal, constraints, and deadline first.' },
]

export function AgentConversation({ bot, conversation, messages, userId, mentions, loading, connectionState, onBack, onConfigure, onSend }: Props) {
  const activity = useAgentActivity(bot.id, conversation.id)
  const timeline = useRef<MessageTimelineHandle>(null)
  const [desktopActivity, setDesktopActivity] = useState(true)
  const [mobileActivity, setMobileActivity] = useState(false)
  const [wide, setWide] = useState(false)
  const [draft, setDraft] = useState<{ text: string; id: number }>()
  useEffect(() => {
    const query = window.matchMedia('(min-width: 1280px)')
    const changed = () => setWide(query.matches)
    changed(); query.addEventListener('change', changed)
    return () => query.removeEventListener('change', changed)
  }, [])
  const activityOpen = wide ? desktopActivity : mobileActivity
  const toggleActivity = () => wide ? setDesktopActivity(value => !value) : setMobileActivity(value => !value)
  const working = activity.run && ['queued', 'running'].includes(activity.run.status) && !activity.run.cancel_requested
  const delta = activity.events.filter(event => event.type === 'assistant_delta').at(-1)?.data.text
  const displayedMessages = useMemo(() => {
    if (!working || !activity.run) return messages
    const stream: Message = {
      id: `agent-stream:${activity.run.id}`, conversation_id: conversation.id, topic: conversation.send_topic,
      sender_id: bot.id, sender_type: 'bot', from: { type: 'bot', id: bot.id, name: bot.name, avatar: bot.avatar || bot.avatar_url },
      to: { type: 'user', id: userId || '' }, content: { type: 'text', body: typeof delta === 'string' ? delta : '' },
      metadata: { agent_stream: true },
    }
    return [...messages, stream]
  }, [messages, working, activity.run?.id, delta, conversation.id, conversation.send_topic, bot.id, bot.name, bot.avatar, bot.avatar_url, userId])
  const send = async (input: ComposerMessageInput) => { await onSend(input); timeline.current?.scrollToLatest() }

  return <div className="agent-conversation">
    <header className="agent-chat-header">
      <div className="flex min-w-0 items-center gap-3">
        <button onClick={onBack} className="agent-icon-action md:hidden" aria-label="Back to bots"><AgentIcon name="back" /></button>
        <Avatar name={bot.name} src={bot.avatar || bot.avatar_url} size="sm" />
        <div className="min-w-0"><h1 className="truncate text-[15px] font-semibold">{bot.name}</h1><div data-testid="chat-connection-status" className="mt-1 flex items-center gap-1.5 text-[11px] text-slate-500"><span className={`agent-status-dot ${connectionState === 'connected' ? '' : 'is-offline'}`} />{connectionState === 'connected' ? 'Connected' : connectionState === 'idle' ? 'Connecting…' : connectionState}</div></div>
      </div>
      <div className="flex shrink-0 items-center gap-2">
        <button className={`agent-activity-toggle ${activityOpen ? 'is-selected' : ''}`} aria-expanded={activityOpen} aria-controls="agent-activity" onClick={toggleActivity}>
          <svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><rect x="3" y="4" width="18" height="16" rx="3" /><path d="M15 4v16" /></svg>
          Activity{activity.approvals.length > 0 && <span className="agent-attention-count">{activity.approvals.length}</span>}
        </button>
        <button onClick={onConfigure} className="agent-icon-action" aria-label="Configure bot" title="Agent settings"><svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M4 7h16M4 17h16" /><circle cx="9" cy="7" r="3" fill="var(--agent-surface)" /><circle cx="16" cy="17" r="3" fill="var(--agent-surface)" /></svg></button>
      </div>
    </header>
    <div className={`agent-work-area ${desktopActivity ? 'has-sidebar' : ''} ${mobileActivity ? 'show-activity' : ''}`}>
      <div className="agent-chat-main">
        <div className="agent-context-bar"><span className="flex items-center gap-2"><AgentIcon name="spark" size={16} /> Conversation</span>{activity.run && <button onClick={() => { setDesktopActivity(true); setMobileActivity(true) }} className="truncate text-xs">{runLabels[activity.run.status] || activity.run.status} <AgentIcon name="arrow" size={12} style={{ display: 'inline', marginLeft: 6 }} /></button>}</div>
        {displayedMessages.length ? <MessageTimeline key={conversation.id} ref={timeline} messages={displayedMessages} userId={userId} mentions={mentions} agent testId="bot-message-scroll" /> : <div className="agent-welcome scrollbar-thin">
          <div className="agent-welcome-mark"><AgentIcon name="spark" size={30} /></div><p className="agent-eyebrow mt-6">YOUR AGENT, READY TO COLLABORATE</p>
          <h2>{loading ? 'Opening your conversation…' : 'What are we working on?'}</h2>
          <p className="agent-welcome-description">{bot.description || 'Bring an idea, a question, or a file. Work through it together, one step at a time.'}</p>
          {!loading && <div className="agent-starters">{starters.map(starter => <button key={starter.title} onClick={() => setDraft({ text: starter.prompt, id: Date.now() })}><span aria-hidden="true" className="agent-starter-mark"><AgentIcon name={starter.mark} size={20} /></span><strong>{starter.title}</strong><span>{starter.detail}</span><span className="agent-starter-arrow"><AgentIcon name="arrow" size={12} /></span></button>)}</div>}
        </div>}
        <ChatInput onSendMessage={send} placeholder={`Message ${bot.name}...`} agent suggestedPrompt={draft} />
      </div>
      <AgentActivity key={activity.run?.id || 'empty'} activity={activity} onClose={() => { setDesktopActivity(false); setMobileActivity(false) }} />
    </div>
  </div>
}
