'use client'

import React from 'react'

interface StatusPillProps {
  tone?: 'success' | 'warning' | 'danger' | 'neutral' | 'info'
  children: React.ReactNode
  className?: string
}

export function StatusPill({ tone = 'neutral', children, className = '' }: StatusPillProps) {
  const tones = {
    success: 'bg-emerald-50 text-emerald-700 ring-emerald-100',
    warning: 'bg-amber-50 text-amber-700 ring-amber-100',
    danger: 'bg-red-50 text-red-700 ring-red-100',
    neutral: 'bg-slate-100 text-slate-600 ring-slate-200',
    info: 'bg-sky-50 text-sky-700 ring-sky-100',
  }

  return (
    <span className={`inline-flex max-w-full items-center gap-1.5 rounded-full px-2 py-1 text-[11px] font-bold uppercase leading-none tracking-normal ring-1 ${tones[tone]} ${className}`}>
      {children}
    </span>
  )
}
