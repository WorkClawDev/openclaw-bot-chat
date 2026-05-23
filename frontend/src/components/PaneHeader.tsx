'use client'

import React from 'react'

interface PaneHeaderProps {
  title: React.ReactNode
  subtitle?: React.ReactNode
  leading?: React.ReactNode
  actions?: React.ReactNode
  className?: string
}

export function PaneHeader({ title, subtitle, leading, actions, className = '' }: PaneHeaderProps) {
  return (
    <header className={`flex min-h-[60px] items-center justify-between gap-3 border-b border-slate-200/70 bg-white/85 px-4 py-3 backdrop-blur md:min-h-[72px] md:px-6 ${className}`}>
      <div className="flex min-w-0 items-center gap-3">
        {leading}
        <div className="min-w-0">
          <div className="truncate text-base font-black tracking-normal text-slate-900 md:text-lg">{title}</div>
          {subtitle && <div className="mt-1 flex min-w-0 flex-wrap items-center gap-2 text-xs text-slate-500">{subtitle}</div>}
        </div>
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </header>
  )
}
