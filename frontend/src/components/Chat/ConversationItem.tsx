'use client'

import React from 'react'
import { Avatar } from '@/components/Avatar'
import { StatusPill } from '@/components/StatusPill'

interface ConversationItemProps {
  name: string
  avatar?: string | null
  lastMessage?: string
  timestamp?: string
  isActive?: boolean
  onClick: () => void
  status?: 'online' | 'offline' | 'none'
  unreadCount?: number
}

export function ConversationItem({
  name,
  avatar,
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
      className={`group relative flex h-[76px] w-full items-center gap-3 px-4 text-left transition-all duration-200 focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-sky-500 ${
        isActive
          ? 'bg-sky-50'
          : 'hover:bg-white/70'
      }`}
    >
      {isActive && (
        <div className="absolute left-0 top-2 bottom-2 w-1 rounded-r-full bg-sky-500" />
      )}
      
      <div className="relative flex-shrink-0">
        <Avatar name={name} src={avatar} size="md" className="w-10 h-10" />
        {status !== 'none' && (
          <div className={`absolute -bottom-0.5 -right-0.5 w-3 h-3 rounded-full border-2 border-white ${
            status === 'online' ? 'bg-[#10B981]' : 'bg-[#94A3B8]'
          }`} />
        )}
      </div>

      <div className="min-w-0 flex-1">
        <div className="flex justify-between items-baseline mb-0.5">
          <h4 className={`truncate text-sm font-bold ${isActive ? 'text-sky-700' : 'text-slate-900'}`}>
            {name}
          </h4>
          {timestamp && (
            <span className="text-[10px] text-slate-400 font-medium">
              {timestamp}
            </span>
          )}
        </div>
        <div className="flex justify-between items-center">
          <p className="truncate pr-4 text-xs text-slate-500">
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
