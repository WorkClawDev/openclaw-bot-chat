'use client'

import React from 'react'
import { StatusPill } from '@/components/StatusPill'

interface ConversationItemProps {
  name: string
  agent?: boolean
  lastMessage?: string
  timestamp?: string
  isActive?: boolean
  onClick: () => void
  status?: 'online' | 'offline' | 'none'
  unreadCount?: number
}

export function ConversationItem({
  name,
  agent = false,
  lastMessage,
  timestamp,
  isActive,
  onClick,
  status = 'none',
  unreadCount = 0,
}: ConversationItemProps) {
  return (
    <button
      onClick={onClick}
      aria-current={isActive ? 'true' : undefined}
      className={`conversation-item ${agent ? 'agent-list-item' : ''} group relative flex h-[76px] w-full items-center gap-3 px-4 text-left transition-colors duration-150 focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-sky-500 ${
        isActive
          ? 'is-active bg-sky-50'
          : 'hover:bg-white/70'
      }`}
    >
      {isActive && (
        <div className="absolute left-0 top-2 bottom-2 w-1 rounded-r-full bg-sky-500" />
      )}
      
      <div className="min-w-0 flex-1">
        <div className="flex justify-between items-baseline mb-0.5">
          <h4 className={`truncate text-sm font-bold ${isActive ? 'text-sky-700' : 'text-slate-900'}`}>
            {name}
          </h4>
          {agent && isActive && <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" className="shrink-0 text-[var(--agent-accent)]"><path d="M5 12h14m-6-6 6 6-6 6" /></svg>}
          {timestamp && (
            <span className="text-[10px] text-slate-400 font-medium">
              {timestamp}
            </span>
          )}
        </div>
        <div className="flex justify-between items-center">
          <p className={`${agent ? 'line-clamp-2' : 'truncate pr-4'} text-xs text-slate-500`}>
            {lastMessage || 'No messages yet'}
          </p>
          {unreadCount > 0 && (
            <span className="min-w-[18px] rounded-full bg-sky-500 px-1.5 py-0.5 text-center text-[10px] font-bold text-white">
              {unreadCount}
            </span>
          )}
          {unreadCount === 0 && status === 'online' && (
            <StatusPill tone="success" className="hidden sm:inline-flex">
              Online
            </StatusPill>
          )}
        </div>
      </div>
    </button>
  )
}
