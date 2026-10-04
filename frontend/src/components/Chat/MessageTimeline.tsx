'use client'

import { forwardRef, memo, useCallback, useImperativeHandle } from 'react'
import { Virtuoso } from 'react-virtuoso'
import type { Message } from '@/lib/types'
import { MessageBubble } from './MessageBubble'
import { useAnchoredChatScroll } from './useAnchoredChatScroll'

export interface MessageTimelineHandle { scrollToLatest: () => void }
interface Props {
  messages: Message[]
  userId?: string
  mentions: string[]
  agent?: boolean
  testId: string
}
const itemKey = (_: number, message: Message) => message.id

export const MessageTimeline = memo(forwardRef<MessageTimelineHandle, Props>(function MessageTimeline(
  { messages, userId, mentions, agent = false, testId }, ref,
) {
  const scroll = useAnchoredChatScroll(messages)
  useImperativeHandle(ref, () => ({ scrollToLatest: scroll.scrollToBottom }), [scroll.scrollToBottom])
  const renderMessage = useCallback((_: number, message: Message) => (
    <div className="chat-reading-column">
      <MessageBubble message={message} isOwn={message.sender_id === userId} mentions={mentions}
        showSenderName={!agent} agent={agent} />
    </div>
  ), [userId, mentions, agent])
  return (
    <div className="relative min-h-0 flex-1" data-testid="message-timeline">
      <Virtuoso ref={scroll.listRef} data-testid={testId} aria-label="Conversation messages" tabIndex={0}
        className="chat-message-scroll scrollbar-thin" style={{ height: '100%', overflowAnchor: 'none' }}
        data={messages} computeItemKey={itemKey} itemContent={renderMessage}
        initialTopMostItemIndex={{ index: messages.length - 1, align: 'end' }} alignToBottom
        atBottomThreshold={64} atBottomStateChange={scroll.atBottomStateChange} followOutput={scroll.followOutput}
        increaseViewportBy={{ top: 400, bottom: 250 }} />
      {!scroll.isAtBottom && <button type="button" onClick={scroll.scrollToBottom} className="chat-jump-latest">
        <svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><path d="M12 4v16m-6-6 6 6 6-6" /></svg>
        {scroll.unreadCount > 0 ? `${scroll.unreadCount} new · Latest messages` : 'Back to latest'}
      </button>}
    </div>
  )
}))
