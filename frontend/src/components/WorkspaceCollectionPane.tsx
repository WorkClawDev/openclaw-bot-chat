'use client'

import React from 'react'
import { Button } from './Button'
import { IconButton } from './IconButton'

interface WorkspaceCollectionPaneProps<T> {
  title: string
  createLabel: string
  searchPlaceholder: string
  searchTerm: string
  onSearchChange: (value: string) => void
  items: T[]
  isLoading?: boolean
  isVisible: boolean
  emptyLabel: string
  emptyActionLabel: string
  onCreate: () => void
  renderItem: (item: T) => React.ReactNode
}

export function WorkspaceCollectionPane<T>({
  title,
  createLabel,
  searchPlaceholder,
  searchTerm,
  onSearchChange,
  items,
  isLoading = false,
  isVisible,
  emptyLabel,
  emptyActionLabel,
  onCreate,
  renderItem,
}: WorkspaceCollectionPaneProps<T>) {
  return (
    <aside className={`h-full w-full flex-shrink-0 flex-col overflow-hidden border-r border-slate-200/70 bg-white/80 backdrop-blur-xl md:w-[320px] lg:w-[340px] ${isVisible ? 'flex' : 'hidden md:flex'}`}>
      <div className="space-y-4 border-b border-slate-200/70 p-4">
        <div className="flex items-center justify-between">
          <h2 className="text-xl font-bold tracking-normal text-slate-800">{title}</h2>
          <IconButton onClick={onCreate} label={createLabel} variant="primary" size="sm">
            <svg className="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M12 4v16m8-8H4" />
            </svg>
          </IconButton>
        </div>
        <div className="relative">
          <input
            type="text"
            placeholder={searchPlaceholder}
            aria-label={`Search ${title.toLowerCase()}`}
            value={searchTerm}
            onChange={(event) => onSearchChange(event.target.value)}
            className="w-full rounded-xl border border-slate-200 bg-white py-2 pl-9 pr-4 text-sm transition-all focus:outline-none focus:ring-2 focus:ring-sky-500/20"
          />
          <svg className="absolute left-3 top-2.5 h-4 w-4 text-slate-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
          </svg>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto py-2">
        {isLoading ? (
          <div className="space-y-2 px-4 py-3" aria-label={`${title} loading`}>
            {Array.from({ length: 5 }).map((_, index) => (
              <div key={index} className="flex h-[76px] animate-pulse items-center gap-3">
                <div className="h-10 w-10 rounded-full bg-slate-100" />
                <div className="min-w-0 flex-1 space-y-2">
                  <div className="h-3 w-2/3 rounded bg-slate-100" />
                  <div className="h-3 w-4/5 rounded bg-slate-100" />
                </div>
              </div>
            ))}
          </div>
        ) : items.length === 0 ? (
          <div className="space-y-2 p-8 text-center text-slate-400">
            <p className="text-sm font-medium">{emptyLabel}</p>
            <Button size="sm" variant="ghost" onClick={onCreate}>
              {emptyActionLabel}
            </Button>
          </div>
        ) : (
          items.map(renderItem)
        )}
      </div>
    </aside>
  )
}
