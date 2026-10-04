'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import type { VirtuosoHandle } from 'react-virtuoso'
import type { Message } from '@/lib/types'

// Native scrolling is left alone. Only explicit jumps animate; streaming must
// not keep restarting an animation or pull a reader away from older messages.
export function useAnchoredChatScroll(messages: Message[]) {
  const listRef = useRef<VirtuosoHandle>(null)
  const following = useRef(true)
  const followFrame = useRef<number>()
  const [scroller, setScroller] = useState<HTMLElement | null>(null)
  const previous = useRef({ count: messages.length, last: messages.at(-1)?.id })
  const [isAtBottom, setIsAtBottom] = useState(true)
  const [unreadCount, setUnreadCount] = useState(0)
  const atBottomStateChange = useCallback((atBottom: boolean) => {
    setIsAtBottom(atBottom)
    if (atBottom) setUnreadCount(0)
  }, [])
  const scrollerRef = useCallback((element: HTMLElement | Window | null) => {
    setScroller(element instanceof HTMLElement ? element : null)
  }, [])
  const followResize = useCallback(() => {
    if (!following.current) return
    cancelAnimationFrame(followFrame.current || 0)
    followFrame.current = requestAnimationFrame(() => {
      if (following.current) listRef.current?.scrollToIndex({ index: 'LAST', align: 'end', behavior: 'auto' })
    })
  }, [])
  useEffect(() => {
    if (!scroller) return
    let touchY = 0, lastTop = scroller.scrollTop, lastHeight = scroller.scrollHeight
    let scrollFrame: number | undefined
    const scroll = () => {
      if (scrollFrame !== undefined) return
      scrollFrame = requestAnimationFrame(() => {
        scrollFrame = undefined
        const { scrollTop, scrollHeight, clientHeight } = scroller
        if (scrollHeight - clientHeight - scrollTop < 4) following.current = true
        else if (scrollTop < lastTop && scrollHeight === lastHeight) following.current = false
        lastTop = scrollTop; lastHeight = scrollHeight
      })
    }
    const wheel = (event: WheelEvent) => { if (event.deltaY < 0) following.current = false }
    const touchStart = (event: TouchEvent) => { touchY = event.touches[0]?.clientY || 0 }
    const touchMove = (event: TouchEvent) => {
      const nextY = event.touches[0]?.clientY || touchY
      if (nextY > touchY) following.current = false
      touchY = nextY
    }
    const keyDown = (event: KeyboardEvent) => {
      if (['ArrowUp', 'PageUp', 'Home'].includes(event.key) || (event.key === ' ' && event.shiftKey)) following.current = false
    }
    scroller.addEventListener('scroll', scroll, { passive: true })
    scroller.addEventListener('wheel', wheel, { passive: true })
    scroller.addEventListener('touchstart', touchStart, { passive: true })
    scroller.addEventListener('touchmove', touchMove, { passive: true })
    scroller.addEventListener('keydown', keyDown)
    const resize = new ResizeObserver(followResize)
    resize.observe(scroller)
    return () => {
      resize.disconnect(); cancelAnimationFrame(followFrame.current || 0); cancelAnimationFrame(scrollFrame || 0)
      scroller.removeEventListener('scroll', scroll); scroller.removeEventListener('wheel', wheel)
      scroller.removeEventListener('touchstart', touchStart); scroller.removeEventListener('touchmove', touchMove)
      scroller.removeEventListener('keydown', keyDown)
    }
  }, [scroller, followResize])
  useEffect(() => {
    const last = messages.at(-1)?.id
    if (!following.current && previous.current.last && last !== previous.current.last) {
      setUnreadCount(count => count + Math.max(1, messages.length - previous.current.count))
    }
    previous.current = { count: messages.length, last }
  }, [messages])
  const scrollToBottom = useCallback(() => {
    following.current = true
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    listRef.current?.scrollToIndex({ index: 'LAST', align: 'end', behavior: reducedMotion ? 'auto' : 'smooth' })
  }, [])
  const followOutput = useCallback(() => following.current ? 'auto' as const : false, [])
  return { listRef, scrollerRef, followResize, isAtBottom, unreadCount, atBottomStateChange, followOutput, scrollToBottom }
}
