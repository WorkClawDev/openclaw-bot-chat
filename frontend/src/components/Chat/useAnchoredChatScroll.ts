'use client'

import { useCallback, useEffect, useLayoutEffect, useRef } from 'react'
import type { Message } from '@/lib/types'

const BOTTOM_LOCK_THRESHOLD = 96

interface UseAnchoredChatScrollOptions {
  conversationId?: string
  messages: Message[]
}

export function useAnchoredChatScroll({ conversationId, messages }: UseAnchoredChatScrollOptions) {
  const scrollRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLDivElement>(null)
  const isNearBottomRef = useRef(true)
  const shouldStickToBottomRef = useRef(true)
  const userScrollIntentRef = useRef(false)
  const didInitialPositionRef = useRef(false)
  const lastConversationIdRef = useRef<string | undefined>(conversationId)

  const distanceFromBottom = useCallback(() => {
    const scroller = scrollRef.current
    if (!scroller) return 0
    return scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop
  }, [])

  const updateNearBottom = useCallback(() => {
    const nextIsNearBottom = distanceFromBottom() <= BOTTOM_LOCK_THRESHOLD
    isNearBottomRef.current = nextIsNearBottom

    if (nextIsNearBottom) {
      shouldStickToBottomRef.current = true
    } else if (userScrollIntentRef.current) {
      shouldStickToBottomRef.current = false
    }
  }, [distanceFromBottom])

  const scrollToBottom = useCallback((behavior: ScrollBehavior = 'auto') => {
    const scroller = scrollRef.current
    if (!scroller) return

    scroller.scrollTo({
      top: Math.max(0, scroller.scrollHeight - scroller.clientHeight),
      behavior,
    })
    shouldStickToBottomRef.current = true
    updateNearBottom()
  }, [updateNearBottom])

  useEffect(() => {
    if (lastConversationIdRef.current === conversationId) {
      return
    }

    lastConversationIdRef.current = conversationId
    didInitialPositionRef.current = false
    isNearBottomRef.current = true
    shouldStickToBottomRef.current = true
    userScrollIntentRef.current = false
  }, [conversationId])

  useLayoutEffect(() => {
    if (!conversationId || messages.length === 0) {
      return
    }

    if (!didInitialPositionRef.current) {
      didInitialPositionRef.current = true
      scrollToBottom('auto')
      requestAnimationFrame(() => scrollToBottom('auto'))
      return
    }

    if (shouldStickToBottomRef.current) {
      scrollToBottom('auto')
    }
  }, [conversationId, messages, scrollToBottom])

  useEffect(() => {
    const scroller = scrollRef.current
    if (!scroller) return

    updateNearBottom()
    const noteUserScrollIntent = () => {
      userScrollIntentRef.current = true
    }

    scroller.addEventListener('scroll', updateNearBottom, { passive: true })
    scroller.addEventListener('wheel', noteUserScrollIntent, { passive: true })
    scroller.addEventListener('touchstart', noteUserScrollIntent, { passive: true })
    scroller.addEventListener('pointerdown', noteUserScrollIntent, { passive: true })

    return () => {
      scroller.removeEventListener('scroll', updateNearBottom)
      scroller.removeEventListener('wheel', noteUserScrollIntent)
      scroller.removeEventListener('touchstart', noteUserScrollIntent)
      scroller.removeEventListener('pointerdown', noteUserScrollIntent)
    }
  }, [updateNearBottom])

  useEffect(() => {
    const scroller = scrollRef.current
    const content = contentRef.current
    if (!scroller || !content) return

    const resizeObserver = new ResizeObserver(() => {
      if (!didInitialPositionRef.current || shouldStickToBottomRef.current) {
        scrollToBottom('auto')
      } else {
        updateNearBottom()
      }
    })

    resizeObserver.observe(scroller)
    resizeObserver.observe(content)
    return () => resizeObserver.disconnect()
  }, [conversationId, messages.length, scrollToBottom, updateNearBottom])

  return {
    scrollRef,
    contentRef,
    scrollToBottom,
  }
}
