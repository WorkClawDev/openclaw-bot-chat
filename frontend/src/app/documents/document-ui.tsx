'use client'

import type { DocumentObject } from '@/lib/types'

export const EMPTY_DOCUMENT_TEMPLATE = `# New document

Start writing here. Use Markdown headings, lists, tables, and code blocks to shape a longer answer into a durable document.`

export const BASE_PREVIEW_ROWS = [
  { task: 'Outline', status: 'Done', owner: 'Bot', due: 'Today' },
  { task: 'Review', status: 'Next', owner: 'User', due: 'Tomorrow' },
  { task: 'Publish', status: 'Soon', owner: 'Team', due: 'Later' },
]

export function formatDocumentDate(value?: string | null) {
  if (!value) return 'Unknown time'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return 'Unknown time'
  return new Intl.DateTimeFormat(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date)
}

export function formatFullDocumentDate(value?: string | null) {
  if (!value) return 'Unknown time'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return 'Unknown time'
  return new Intl.DateTimeFormat(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date)
}

export function documentSourceLabel(doc?: Pick<DocumentObject, 'source'> | null) {
  return doc?.source === 'bot' ? 'Bot generated' : 'User document'
}

export function documentExcerpt(doc?: Pick<DocumentObject, 'summary' | 'body'> & Partial<Pick<DocumentObject, 'title'>> | null, fallback = 'No preview yet') {
  const value = doc?.summary || doc?.body || ''
  let normalized = value
    .replace(/[#*_`>|-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  const title = doc?.title?.trim()
  if (title && normalized.toLowerCase().startsWith(title.toLowerCase())) {
    normalized = normalized.slice(title.length).replace(/^[\s:.-]+/, '').trim()
  }
  return normalized || fallback
}

export function documentWordCount(body?: string | null) {
  const normalized = (body || '').trim()
  if (!normalized) return 0
  return normalized.split(/\s+/).filter(Boolean).length
}

export function buildDocumentMarkdown(doc: DocumentObject, bodyOverride?: string) {
  const body = bodyOverride ?? doc.body ?? ''
  const firstLine = body.split('\n')[0]?.trim() || ''
  const headingTitle = firstLine.replace(/^#\s+/, '').trim()
  if (firstLine.startsWith('# ') && headingTitle.toLowerCase() === doc.title.trim().toLowerCase()) {
    return body.trim()
  }
  return `# ${doc.title}\n\n${body}`.trim()
}

export function documentDisplayBody(doc: Pick<DocumentObject, 'title' | 'body'>) {
  const body = doc.body || ''
  const lines = body.split('\n')
  const firstLine = lines[0]?.trim() || ''
  const headingTitle = firstLine.replace(/^#\s+/, '').trim()
  if (firstLine.startsWith('# ') && headingTitle.toLowerCase() === doc.title.trim().toLowerCase()) {
    return lines.slice(1).join('\n').replace(/^\n+/, '')
  }
  return body
}

export function documentLead(doc: Pick<DocumentObject, 'title' | 'body' | 'summary'>) {
  const displayBody = documentDisplayBody(doc)
  const paragraphLines: string[] = []
  let inCode = false
  for (const rawLine of displayBody.split('\n')) {
    const line = rawLine.trim()
    if (line.startsWith('```')) {
      inCode = !inCode
      continue
    }
    if (inCode) continue
    if (!line) {
      if (paragraphLines.length > 0) break
      continue
    }
    if (/^#{1,6}\s/.test(line) || /^[-*]\s/.test(line) || /^\d+\.\s/.test(line) || line.startsWith('|')) {
      if (paragraphLines.length > 0) break
      continue
    }
    paragraphLines.push(line)
  }

  const lead = paragraphLines.join(' ').replace(/\s+/g, ' ').trim()
  if (lead) return lead
  return documentExcerpt(doc, '')
}

export function buildContinuePrompt(doc: DocumentObject) {
  return `Please continue editing this document: ${doc.title}\n${doc.url}\n\nRequested change: `
}

export function DocumentGlyph({ className = 'h-5 w-5' }: { className?: string }) {
  return (
    <svg className={className} fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.8} d="M7 3h7l5 5v13a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z" />
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.8} d="M14 3v6h5M8 13h8M8 17h6" />
    </svg>
  )
}

export function SearchGlyph({ className = 'h-4 w-4' }: { className?: string }) {
  return (
    <svg className={className} fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.8} d="m21 21-4.3-4.3M10.8 18a7.2 7.2 0 1 1 0-14.4 7.2 7.2 0 0 1 0 14.4Z" />
    </svg>
  )
}

export function StatusDot({ tone = 'sky' }: { tone?: 'sky' | 'emerald' | 'amber' | 'rose' | 'slate' }) {
  const colors = {
    sky: 'bg-sky-500',
    emerald: 'bg-emerald-500',
    amber: 'bg-amber-500',
    rose: 'bg-rose-500',
    slate: 'bg-slate-400',
  }
  return <span className={`h-2 w-2 rounded-full ${colors[tone]}`} aria-hidden="true" />
}
