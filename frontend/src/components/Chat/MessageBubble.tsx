'use client'

import React from 'react'
import Link from 'next/link'
import { Avatar } from '@/components/Avatar'
import { Markdown } from '@/components/Markdown'
import { StatusPill } from '@/components/StatusPill'
import type { Message, User } from '@/lib/types'

interface MessageBubbleProps {
  message: Message
  isOwn: boolean
  showSenderName?: boolean
  mentions?: string[]
}

export function MessageBubble({ message, isOwn, showSenderName, mentions = [] }: MessageBubbleProps) {
  const isBot = message.sender_type === 'bot'
  const isSystem = message.sender_type === 'system'
  const isImageMessage = message.content.type === 'image'
  const isAudioMessage = message.content.type === 'audio'
  const asset = readAsset(message.content.meta)
  const assetURL =
    message.content.url ||
    asset?.download_url ||
    asset?.external_url ||
    asset?.source_url ||
    readString(message.content.meta?.download_url) ||
    readString(message.content.meta?.external_url) ||
    readString(message.content.meta?.source_url) ||
    readString(message.content.meta?.url)
  const imageURL = assetURL
  const audioURL = assetURL
  const imageName = message.content.name || asset?.file_name || 'Image'
  const audioName = message.content.name || asset?.file_name || 'Voice message'
  const documentLink = message.content.type === 'text'
    ? findDocumentLink(message.content.body || '', message.metadata || message.content.meta)
    : undefined

  const processContent = (text: string) => {
    if (!mentions.length) {
      // Fallback: match basic @mentions or ＠mentions without spaces
      return text.replace(/(```[\s\S]*?```|`[^`]+`)|([@＠][a-zA-Z0-9_\-\u4e00-\u9fa5]+)/g, (match, code, mention) => {
        if (code) return code;
        return `[${mention}](mention://${encodeURIComponent(mention.slice(1))})`;
      });
    }

    // Match exact bot names or fallback to single words
    const escapedMentions = mentions
      .map(m => m.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
      .sort((a, b) => b.length - a.length)
      .join('|');
      
    const regex = new RegExp(`(\`\`\`[\\s\\S]*?\`\`\`|\`[^\`]+\`)|([@＠](?:${escapedMentions})|[@＠][a-zA-Z0-9_\\-\\u4e00-\\u9fa5]+)`, 'g');
    
    return text.replace(regex, (match, code, mention) => {
      if (code) return code;
      return `[${mention}](mention://${encodeURIComponent(mention.slice(1))})`;
    });
  }

  if (isSystem) {
    return (
      <div className="flex justify-center my-4">
        <div className="px-4 py-1 bg-slate-100 rounded-full text-xs text-slate-500 font-medium">
          {message.content.body}
        </div>
      </div>
    )
  }

  return (
    <div className={`flex w-full mb-6 ${isOwn ? 'justify-end' : 'justify-start'}`}>
      <div className={`flex max-w-[90%] md:max-w-[80%] ${isOwn ? 'flex-row-reverse' : 'flex-row'} items-end gap-2 md:gap-3`}>
        {!isOwn && (
          <Avatar
            name={message.from.name || 'Bot'}
            src={message.from.avatar}
            size="sm"
            className="flex-shrink-0 mb-1"
          />
        )}
        
        <div className={`flex flex-col ${isOwn ? 'items-end' : 'items-start'}`}>
          {showSenderName && !isOwn && (
            <span className="mb-1 ml-1 flex max-w-full items-center gap-2 text-xs font-medium text-slate-500">
              <span className="truncate">{message.from.name}</span>
              {isBot && <StatusPill tone="info">BOT</StatusPill>}
            </span>
          )}
          
          <div
            className={`shadow-sm transition-all ${
              message.failed
                ? 'bg-red-50 text-red-900 rounded-[16px_16px_4px_16px] border border-red-100 px-4 py-3'
                : isImageMessage && message.content.meta?.is_sticker
                ? 'bg-transparent shadow-none'
                : isOwn
                ? 'bg-[#0EA5E9] text-white rounded-[16px_16px_4px_16px] px-4 py-3'
                : isBot
                ? 'bg-sky-50 text-slate-800 rounded-[16px_16px_16px_4px] border border-sky-100 px-4 py-3'
                : 'bg-slate-100 text-slate-800 rounded-[16px_16px_16px_4px] border border-slate-200 px-4 py-3'
            }`}
          >
            {message.content.type === 'text' && (
              <div className="space-y-3">
                <div className={`prose prose-sm max-w-none ${isOwn ? 'prose-invert' : 'prose-slate'}`}>
                  <Markdown content={processContent(message.content.body || '')} isOwn={isOwn} />
                </div>
                {documentLink ? (
                  <DocumentMessageCard link={documentLink} isOwn={isOwn} />
                ) : null}
              </div>
            )}
            
            {isImageMessage && (
              <div className="space-y-2">
                {imageURL ? (
                  <div className={`rounded-lg overflow-hidden ${message.content.meta?.is_sticker ? 'max-w-[120px] md:max-w-[160px]' : 'max-w-xs'}`}>
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={imageURL} alt={imageName} className="w-full h-auto object-cover" />
                  </div>
                ) : (
                  <div className="rounded-xl border border-dashed border-slate-300 px-4 py-6 text-sm text-slate-400">
                    Image unavailable
                  </div>
                )}
                {message.content.body && message.content.body !== imageName && !message.content.meta?.is_sticker && (
                  <p className={`text-sm whitespace-pre-wrap break-words ${isOwn ? 'text-white/90' : 'text-slate-700'}`}>
                    {message.content.body}
                  </p>
                )}
              </div>
            )}

            {isAudioMessage && (
              <div className="w-[min(18rem,70vw)] space-y-2">
                {audioURL ? (
                  <div className={`rounded-xl border px-3 py-2 ${isOwn ? 'border-white/25 bg-white/10' : 'border-slate-200 bg-white'}`}>
                    <div className={`mb-2 flex items-center gap-2 text-xs font-semibold ${isOwn ? 'text-white/90' : 'text-slate-600'}`}>
                      <span className={`flex h-7 w-7 items-center justify-center rounded-full ${isOwn ? 'bg-white/20' : 'bg-sky-50 text-sky-600'}`}>
                        <svg className="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 19V6l12-2v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2Zm12-2c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2Z" />
                        </svg>
                      </span>
                      <span className="min-w-0 flex-1 truncate">{audioName}</span>
                    </div>
                    <audio controls preload="metadata" src={audioURL} className="h-9 w-full" />
                  </div>
                ) : (
                  <div className="rounded-xl border border-dashed border-slate-300 px-4 py-4 text-sm text-slate-400">
                    Voice message unavailable
                  </div>
                )}
                {message.content.body && message.content.body !== audioName && (
                  <p className={`text-sm whitespace-pre-wrap break-words ${isOwn ? 'text-white/90' : 'text-slate-700'}`}>
                    {message.content.body}
                  </p>
                )}
              </div>
            )}
          </div>
          
          <span className={`mx-1 mt-1 text-[10px] font-medium uppercase tracking-normal ${message.failed ? 'text-red-500' : message.pending ? 'text-amber-500' : 'text-slate-400'}`}>
            {message.created_at ? new Date(message.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : ''}
            {message.pending && ' · Sending'}
            {message.failed && ' · Failed'}
          </span>
        </div>
      </div>
    </div>
  )
}

function DocumentMessageCard({ link, isOwn }: { link: DocumentLinkPreview; isOwn: boolean }) {
  const handleContinue = () => {
    window.dispatchEvent(new CustomEvent('openclaw:document-edit-prompt', {
      detail: {
        prompt: `请继续修改这份文档：${link.title}\n${link.path}\n\n修改要求：`,
      },
    }))
  }

  const handleCopyMarkdown = async () => {
    await navigator.clipboard?.writeText(`请查看这份文档：${link.title}\n${link.path}`)
  }

  return (
    <div
      className={`w-[min(24rem,74vw)] overflow-hidden rounded-md border transition ${
        isOwn
          ? 'border-white/25 bg-white/10 text-white hover:bg-white/20'
          : 'border-slate-200 bg-white text-slate-900 hover:border-sky-200 hover:bg-sky-50'
      }`}
    >
      <Link href={link.path} className="block p-3 no-underline">
        <div className="flex items-start gap-3">
          <span className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-md ${isOwn ? 'bg-white/20' : 'bg-sky-50 text-sky-600'}`}>
            <svg className="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.8} d="M7 3h7l5 5v13a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z" />
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.8} d="M14 3v6h5M8 13h8M8 17h6" />
            </svg>
          </span>
          <span className="min-w-0 flex-1">
            <span className="mb-1 flex flex-wrap items-center gap-1.5">
              <span className={`rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-normal ${isOwn ? 'bg-white/15 text-white/90' : 'bg-slate-100 text-slate-500'}`}>
                {link.documentType}
              </span>
              <span className={`text-[11px] ${isOwn ? 'text-white/70' : 'text-slate-400'}`}>
                {link.updatedLabel}
              </span>
            </span>
            <span className={`block text-sm font-semibold ${isOwn ? 'text-white' : 'text-slate-950'}`}>
              {link.title}
            </span>
            <span className={`mt-1 block line-clamp-2 text-xs leading-5 ${isOwn ? 'text-white/78' : 'text-slate-500'}`}>
              {link.summary}
            </span>
            <span className={`mt-3 inline-flex text-xs font-semibold ${isOwn ? 'text-white' : 'text-sky-700'}`}>
              Open document
            </span>
          </span>
        </div>
      </Link>
      <div className={`grid grid-cols-3 border-t text-xs font-semibold ${isOwn ? 'border-white/20 text-white' : 'border-slate-100 text-slate-600'}`}>
        <button type="button" onClick={handleContinue} className={`px-2 py-2 transition ${isOwn ? 'hover:bg-white/15' : 'hover:bg-slate-50'}`}>
          Continue edit
        </button>
        <button type="button" onClick={handleCopyMarkdown} className={`border-x px-2 py-2 transition ${isOwn ? 'border-white/20 hover:bg-white/15' : 'border-slate-100 hover:bg-slate-50'}`}>
          Copy
        </button>
        <span className={`px-2 py-2 text-center ${isOwn ? 'text-white/55' : 'text-slate-400'}`}>
          Share soon
        </span>
      </div>
    </div>
  )
}

interface DocumentLinkPreview {
  id: string
  path: string
  title: string
  summary: string
  documentType: string
  updatedLabel: string
}

function findDocumentLink(text: string, metadata?: Record<string, unknown>): DocumentLinkPreview | undefined {
  const match = text.match(/(?:https?:\/\/[^\s)]+)?\/documents\/([0-9a-fA-F-]{36})(?=$|[\s).,，。!！?？])/)
  if (!match) return undefined
  const id = match[1]
  const title = readString(metadata?.document_title) || inferDocumentTitle(text) || 'Shared document'
  return {
    id,
    path: readString(metadata?.document_url) || `/documents/${id}`,
    title,
    summary: readString(metadata?.document_summary) || inferDocumentSummary(text, title) || 'Persistent document · Opens the saved document page',
    documentType: (readString(metadata?.document_type) || 'markdown').toUpperCase(),
    updatedLabel: formatDocumentTime(readString(metadata?.document_updated_at)),
  }
}

function inferDocumentTitle(text: string): string | undefined {
  const lines = text
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
  for (const line of lines) {
    if (line.includes('/documents/')) continue
    const normalized = line
      .replace(/^#+\s*/, '')
      .replace(/^[-*]\s*/, '')
      .replace(/^文档[:：]\s*/, '')
      .trim()
    if (normalized.length >= 2 && normalized.length <= 80) return normalized
  }
  return undefined
}

function inferDocumentSummary(text: string, title: string): string | undefined {
  const titleKey = title.trim().toLowerCase()
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !line.includes('/documents/'))
    .map((line) => line.replace(/^#+\s*/, '').replace(/^[-*]\s*/, '').trim())
    .find((line) => line.length >= 6 && line.toLowerCase() !== titleKey)
}

function formatDocumentTime(value?: string): string {
  if (!value) return 'Updated just now'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return 'Updated just now'
  return `Updated ${date.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}`
}

function readAsset(meta?: Record<string, unknown>) {
  if (!meta?.asset || typeof meta.asset !== 'object' || Array.isArray(meta.asset)) {
    return undefined
  }

  return meta.asset as {
    file_name?: string
    download_url?: string
    external_url?: string
    source_url?: string
  }
}

function readString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}
