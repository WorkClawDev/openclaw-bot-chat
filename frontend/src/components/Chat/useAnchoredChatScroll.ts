'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import type { VirtuosoHandle } from 'react-virtuoso'
import type { Message } from '@/lib/types'

// Native scrolling is left alone. Only explicit jumps animate; streaming must
// not keep restarting an animation or pull a reader away from older messages.
export function useAnchoredChatScroll(messages: Message[]) {
  const listRef = useRef<VirtuosoHandle>(null)
  const following = useRef(true)
  const previous = useRef({ count: messages.length, last: messages.at(-1)?.id })
  const [isAtBottom, setIsAtBottom] = useState(true)
  const [unreadCount, setUnreadCount] = useState(0)
  const atBottomStateChange = useCallback((atBottom: boolean) => {
    following.current = atBottom
    setIsAtBottom(atBottom)
    if (atBottom) setUnreadCount(0)
  }, [])
  useEffect(() => {
    const last = messages.at(-1)?.id
    if (!following.current && previous.current.last && last !== previous.current.last) {
      setUnreadCount(count => count + Math.max(1, messages.length - previous.current.count))
    }
    previous.current = { count: messages.length, last }
  }, [messages])
  const scrollToBottom = useCallback(() => {
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    listRef.current?.scrollToIndex({ index: 'LAST', align: 'end', behavior: reducedMotion ? 'auto' : 'smooth' })
  }, [])
  const followOutput = useCallback((atBottom: boolean) => atBottom ? 'auto' as const : false, [])
  return { listRef, isAtBottom, unreadCount, atBottomStateChange, followOutput, scrollToBottom }
}
