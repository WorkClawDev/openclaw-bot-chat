'use client'

import React from 'react'
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
              <div className={`prose prose-sm max-w-none ${isOwn ? 'prose-invert' : 'prose-slate'}`}>
                <Markdown content={processContent(message.content.body || '')} isOwn={isOwn} />
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
