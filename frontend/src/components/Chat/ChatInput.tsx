'use client'

import React, { useState, useRef, useEffect } from 'react'
import dynamic from 'next/dynamic'
import { Theme } from 'emoji-picker-react'
import { Avatar } from '@/components/Avatar'
import { useChat } from '@/contexts/ChatContext'
import { assetsApi, groupsApi } from '@/lib/api'
import { Bot, ComposerMessageInput, GroupMember, SlashCommand } from '@/lib/types'
import { STICKERS, Sticker } from '@/lib/stickers'

const EmojiPicker = dynamic(() => import('emoji-picker-react'), { ssr: false })

interface ChatInputProps {
  onSendMessage: (input: ComposerMessageInput) => Promise<void>
  disabled?: boolean
  placeholder?: string
}

interface MentionBot {
  id: string
  name: string
  avatar?: string | null
  aliases: string[]
}

type MentionCandidate = {
  id: string
  name: string
  aliases?: string[]
}

export function ChatInput({ onSendMessage, disabled, placeholder = 'Type a message...' }: ChatInputProps) {
  const [content, setContent] = useState('')
  const [isSending, setIsSending] = useState(false)
  const [isUploading, setIsUploading] = useState(false)
  const [showEmojiPicker, setShowEmojiPicker] = useState(false)
  const [showStickerPicker, setShowStickerPicker] = useState(false)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const pickerRef = useRef<HTMLDivElement>(null)

  const { bots, currentConversation, slashCommands } = useChat()
  const [mentionActive, setMentionActive] = useState(false)
  const [mentionQuery, setMentionQuery] = useState('')
  const [mentionStartIndex, setMentionStartIndex] = useState(-1)
  const [selectedIndex, setSelectedIndex] = useState(0)
  const [groupBots, setGroupBots] = useState<MentionBot[]>([])
  const [slashActive, setSlashActive] = useState(false)
  const [slashQuery, setSlashQuery] = useState('')
  const [slashStartIndex, setSlashStartIndex] = useState(-1)
  const [selectedSlashIndex, setSelectedSlashIndex] = useState(0)

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (pickerRef.current && !pickerRef.current.contains(event.target as Node)) {
        setShowEmojiPicker(false)
        setShowStickerPicker(false)
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [])

  const handleEmojiClick = (emojiData: any) => {
    const emoji = emojiData.emoji
    const cursorPosition = textareaRef.current?.selectionStart || content.length
    const newContent = content.slice(0, cursorPosition) + emoji + content.slice(cursorPosition)
    setContent(newContent)

    // Set focus back to textarea and move cursor
    setTimeout(() => {
      if (textareaRef.current) {
        textareaRef.current.focus()
        const newPos = cursorPosition + emoji.length
        textareaRef.current.setSelectionRange(newPos, newPos)
      }
    }, 0)
  }

  const handleStickerClick = async (sticker: Sticker) => {
    if (disabled || isSending || isUploading || !currentConversation) return

    setIsSending(true)
    try {
      await onSendMessage({
        type: 'image',
        body: sticker.name,
        asset: {
          external_url: sticker.url,
          file_name: sticker.name,
          kind: 'image',
        },
        meta: {
          is_sticker: true,
          sticker_id: sticker.id,
        },
      })
      setShowStickerPicker(false)
    } catch (error) {
      console.error('Failed to send sticker:', error)
    } finally {
      setIsSending(false)
    }
  }

  const mentionBots = currentConversation?.target.type === 'group' ? groupBots : bots

  const filteredBots = mentionBots.filter((bot) =>
    bot.name.toLowerCase().includes(mentionQuery.toLowerCase())
  )

  const filteredSlashCommands = slashCommands
    .filter((command) => command.name.toLowerCase().includes(slashQuery.toLowerCase()))
    .slice(0, 8)

  const overlayRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (textareaRef.current) {
      textareaRef.current.style.height = 'auto'
      textareaRef.current.style.height = `${Math.min(textareaRef.current.scrollHeight, 200)}px`
    }
  }, [content])

  const handleScroll = () => {
    if (textareaRef.current && overlayRef.current) {
      overlayRef.current.scrollTop = textareaRef.current.scrollTop
      overlayRef.current.scrollLeft = textareaRef.current.scrollLeft
    }
  }

  // Reset selected index if filtered results change
  useEffect(() => {
    setSelectedIndex(0)
  }, [mentionQuery])

  useEffect(() => {
    setSelectedSlashIndex(0)
  }, [slashQuery])

  useEffect(() => {
    if (currentConversation?.target.type !== 'group') {
      setGroupBots([])
      return
    }

    let cancelled = false

    const loadGroupBots = async () => {
      try {
        const data = await groupsApi.getMembers(currentConversation.target.id)
        if (cancelled) return
        setGroupBots(
          (data.bots || [])
            .map(toMentionBot)
            .filter((bot): bot is MentionBot => bot !== null),
        )
      } catch (error) {
        if (!cancelled) {
          console.error('Failed to load group bots:', error)
          setGroupBots([])
        }
      }
    }

    void loadGroupBots()

    return () => {
      cancelled = true
    }
  }, [currentConversation])

  const handleSend = async () => {
    if (!content.trim() || isSending || isUploading || disabled) return

    setIsSending(true)
    try {
      await onSendMessage({
        type: 'text',
        body: content.trim(),
        meta: {
          ...buildMentionMeta(content, mentionBots),
          ...buildSlashCommandMeta(content, slashCommands),
        },
      })
      setContent('')
      setMentionActive(false)
      setSlashActive(false)
    } catch (error) {
      console.error('Failed to send message:', error)
    } finally {
      setIsSending(false)
    }
  }

  const handleImageSelect = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file || !currentConversation || disabled || isSending || isUploading) {
      e.target.value = ''
      return
    }

    setIsUploading(true)
    try {
      const prepared = await assetsApi.prepareImageUpload({
        file_name: file.name,
        content_type: file.type,
        size: file.size,
        conversation_id: currentConversation.send_topic,
      })

      const uploadResponse = await fetch(prepared.upload.url, {
        method: prepared.upload.method || 'PUT',
        headers: prepared.upload.headers,
        body: file,
      })

      if (!uploadResponse.ok) {
        throw new Error(`Upload failed with status ${uploadResponse.status}`)
      }

      const asset = await assetsApi.completeImageUpload({
        asset_id: prepared.asset.id || '',
        object_key: prepared.asset.object_key || '',
      })

      await onSendMessage({
        type: 'image',
        body: content.trim() || file.name,
        asset,
        meta: buildMentionMeta(content, mentionBots),
      })
      setContent('')
      setMentionActive(false)
      setSlashActive(false)
    } catch (error) {
      console.error('Failed to upload image:', error)
    } finally {
      setIsUploading(false)
      e.target.value = ''
    }
  }

  const insertMention = (bot: Bot) => {
    const beforeMention = content.slice(0, mentionStartIndex)
    const mentionText = `@${bot.name} `
    const cursorPosition = textareaRef.current?.selectionStart || content.length
    const afterMention = content.slice(cursorPosition)

    const newContent = beforeMention + mentionText + afterMention
    setContent(newContent)
    setMentionActive(false)
    setMentionQuery('')

    setTimeout(() => {
      if (textareaRef.current) {
        textareaRef.current.focus()
        const newCursorPos = beforeMention.length + mentionText.length
        textareaRef.current.setSelectionRange(newCursorPos, newCursorPos)
      }
    }, 0)
  }

  const insertSlashCommand = (command: SlashCommand) => {
    const beforeSlash = content.slice(0, slashStartIndex)
    const commandText = `/${command.name} `
    const cursorPosition = textareaRef.current?.selectionStart || content.length
    const afterSlash = content.slice(cursorPosition)

    const newContent = beforeSlash + commandText + afterSlash
    setContent(newContent)
    setSlashActive(false)
    setSlashQuery('')

    setTimeout(() => {
      if (textareaRef.current) {
        textareaRef.current.focus()
        const newCursorPos = beforeSlash.length + commandText.length
        textareaRef.current.setSelectionRange(newCursorPos, newCursorPos)
      }
    }, 0)
  }

  const checkComposerState = (target: HTMLTextAreaElement) => {
    const value = target.value
    const cursorPosition = target.selectionStart || 0
    const textBeforeCursor = value.slice(0, cursorPosition)

    const slashMatch = textBeforeCursor.match(/(?:^|\n)\/([a-zA-Z0-9_-]*)$/)
    if (slashMatch) {
      const fullMatch = slashMatch[0]
      setSlashActive(true)
      setSlashQuery(slashMatch[1] || '')
      setSlashStartIndex(cursorPosition - fullMatch.trimStart().length)
      setMentionActive(false)
      return
    }
    setSlashActive(false)
    
    // Match @name or ＠name at the end of textBeforeCursor
    // We allow mentions to start after: start of line, space, newline, punctuation, or Chinese characters (anything not a word char)
    const mentionMatch = textBeforeCursor.match(/(?:^|[^a-zA-Z0-9_])([@＠][^\s\n]*)$/)
    
    if (mentionMatch) {
      const fullMatch = mentionMatch[1]
      setMentionActive(true)
      setMentionQuery(fullMatch.slice(1))
      const wordStartIndex = cursorPosition - fullMatch.length
      setMentionStartIndex(wordStartIndex)
    } else {
      setMentionActive(false)
    }
  }

  const handleChange = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    setContent(e.target.value)
    checkComposerState(e.target)
  }

  const handleSelect = (e: React.SyntheticEvent<HTMLTextAreaElement>) => {
    checkComposerState(e.target as HTMLTextAreaElement)
  }

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (slashActive && filteredSlashCommands.length > 0) {
      if (e.key === 'ArrowUp') {
        e.preventDefault()
        setSelectedSlashIndex((prev) => (prev > 0 ? prev - 1 : filteredSlashCommands.length - 1))
        return
      }
      if (e.key === 'ArrowDown') {
        e.preventDefault()
        setSelectedSlashIndex((prev) => (prev < filteredSlashCommands.length - 1 ? prev + 1 : 0))
        return
      }
      if (e.key === 'Enter' || e.key === 'Tab') {
        e.preventDefault()
        insertSlashCommand(filteredSlashCommands[selectedSlashIndex])
        return
      }
      if (e.key === 'Escape') {
        e.preventDefault()
        setSlashActive(false)
        return
      }
    }

    if (mentionActive && filteredBots.length > 0) {
      if (e.key === 'ArrowUp') {
        e.preventDefault()
        setSelectedIndex((prev) => (prev > 0 ? prev - 1 : filteredBots.length - 1))
        return
      }
      if (e.key === 'ArrowDown') {
        e.preventDefault()
        setSelectedIndex((prev) => (prev < filteredBots.length - 1 ? prev + 1 : 0))
        return
      }
      if (e.key === 'Enter' || e.key === 'Tab') {
        e.preventDefault()
        insertMention(filteredBots[selectedIndex])
        return
      }
      if (e.key === 'Escape') {
        e.preventDefault()
        setMentionActive(false)
        return
      }
    }

    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      void handleSend()
    }
  }

  const renderHighlights = (text: string) => {
    if (!text) {
      return <span className="text-slate-400">{placeholder}</span>;
    }
    
    const escapedMentions = mentionBots
      .map(m => m.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
      .sort((a, b) => b.length - a.length)
      .join('|');
      
    // Basic match for mentioning known bots
    const regex = escapedMentions ? new RegExp(`([@＠](?:${escapedMentions}))`, 'g') : /([@＠][a-zA-Z0-9_\-\u4e00-\u9fa5]+)/g;
    
    const parts = text.split(regex);
    return parts.map((part, i) => {
      // Re-evaluate regex on the part to check if it's a match
      const isMatch = escapedMentions ? new RegExp(`^([@＠](?:${escapedMentions}))$`).test(part) : /^([@＠][a-zA-Z0-9_\-\u4e00-\u9fa5]+)$/.test(part);
      if (isMatch) {
        return (
          <span key={i} className="bg-indigo-100 text-indigo-700 rounded">
            {part}
          </span>
        );
      }
      return <span key={i} className="text-slate-700">{part}</span>;
    });
  }

  return (
    <div className="relative border-t border-slate-200/70 bg-white/80 px-3 py-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))] backdrop-blur-sm md:px-6 md:py-4 md:pb-[calc(1rem+env(safe-area-inset-bottom))]" ref={pickerRef}>
      {/* Pickers */}
      {(showEmojiPicker || showStickerPicker) && (
        <div className="absolute bottom-full left-3 md:left-6 mb-2 z-50 animate-in slide-in-from-bottom-2">
          {showEmojiPicker && (
            <div className="shadow-2xl rounded-2xl overflow-hidden border border-slate-100">
              <EmojiPicker
                onEmojiClick={handleEmojiClick}
                autoFocusSearch={false}
                theme={Theme.LIGHT}
                width={320}
                height={400}
                searchPlaceHolder="Search emoji..."
              />
            </div>
          )}
          {showStickerPicker && (
            <div className="bg-white shadow-2xl rounded-2xl border border-slate-100 p-3 w-72 md:w-80 overflow-hidden">
              <div className="px-1 py-2 mb-2 text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-50">
                Stickers
              </div>
              <div className="grid grid-cols-4 gap-2 max-h-64 overflow-y-auto scrollbar-thin p-1">
                {STICKERS.map((sticker) => (
                  <button
                    key={sticker.id}
                    onClick={() => void handleStickerClick(sticker)}
                    className="aspect-square p-2 rounded-xl hover:bg-slate-50 transition-all group"
                  >
                    <img
                      src={sticker.url}
                      alt={sticker.name}
                      className="w-full h-full object-contain group-hover:scale-110 transition-transform"
                    />
                  </button>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {/* Auto-complete Popup */}
      {slashActive && (
        <div
          className="absolute bottom-full left-3 md:left-6 mb-2 w-[calc(100%-24px)] md:w-80 bg-white rounded-2xl shadow-xl border border-slate-100 overflow-hidden z-50 animate-in slide-in-from-bottom-2"
          onPointerDown={(e) => e.preventDefault()}
        >
          <div className="px-3 py-2 bg-slate-50 border-b border-slate-100 text-[10px] font-black text-slate-400 uppercase tracking-widest">
            Commands
          </div>
          <div className="max-h-56 overflow-y-auto scrollbar-thin">
            {filteredSlashCommands.length > 0 ? (
              filteredSlashCommands.map((command, index) => (
                <button
                  key={command.name}
                  onPointerDown={(e) => {
                    e.preventDefault();
                    insertSlashCommand(command);
                  }}
                  onMouseEnter={() => setSelectedSlashIndex(index)}
                  className={`w-full flex items-start gap-3 px-3 py-2 text-left transition-colors ${
                    index === selectedSlashIndex ? 'bg-sky-50' : 'hover:bg-slate-50'
                  }`}
                >
                  <span className={`mt-0.5 flex h-7 w-7 items-center justify-center rounded-lg text-sm font-black ${
                    index === selectedSlashIndex ? 'bg-sky-100 text-sky-600' : 'bg-slate-100 text-slate-500'
                  }`}>
                    /
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className={`block truncate text-sm font-bold ${index === selectedSlashIndex ? 'text-sky-600' : 'text-slate-700'}`}>
                      /{command.name}
                    </span>
                    {command.description ? (
                      <span className="block truncate text-xs text-slate-400">
                        {command.description}
                      </span>
                    ) : null}
                  </span>
                </button>
              ))
            ) : (
              <div className="px-3 py-4 text-center text-sm text-slate-400 font-medium italic">
                No commands found
              </div>
            )}
          </div>
        </div>
      )}

      {mentionActive && (
        <div
          className="absolute bottom-full left-3 md:left-6 mb-2 w-[calc(100%-24px)] md:w-64 bg-white rounded-2xl shadow-xl border border-slate-100 overflow-hidden z-50 animate-in slide-in-from-bottom-2"
          onPointerDown={(e) => e.preventDefault()} // Prevent blur when clicking container or scrollbar
        >
          <div className="px-3 py-2 bg-slate-50 border-b border-slate-100 text-[10px] font-black text-slate-400 uppercase tracking-widest">
            Mention Bot
          </div>
          <div className="max-h-48 overflow-y-auto scrollbar-thin">
            {filteredBots.length > 0 ? (
              filteredBots.map((bot, index) => (
                <button
                  key={bot.id}
                  onPointerDown={(e) => {
                    e.preventDefault();
                    insertMention(bot as Bot);
                  }}
                  onMouseEnter={() => setSelectedIndex(index)}
                  className={`w-full flex items-center gap-3 px-3 py-2 text-left transition-colors ${
                    index === selectedIndex ? 'bg-sky-50' : 'hover:bg-slate-50'
                  }`}
                >
                  <Avatar name={bot.name} src={bot.avatar || undefined} size="sm" />
                  <div className="flex-1 min-w-0">
                    <p className={`text-sm font-bold truncate ${index === selectedIndex ? 'text-sky-600' : 'text-slate-700'}`}>
                      {bot.name}
                    </p>
                  </div>
                </button>
              ))
            ) : (
              <div className="px-3 py-4 text-center text-sm text-slate-400 font-medium italic">
                No bots found
              </div>
            )}
          </div>
        </div>
      )}

      <div className="flex items-end gap-2 md:gap-3 bg-white p-2 pr-2.5 rounded-2xl shadow-sm border border-slate-200/50 focus-within:ring-2 focus-within:ring-[#0EA5E9]/20 transition-all">
        <input
          ref={fileInputRef}
          type="file"
          accept="image/png,image/jpeg,image/webp,image/gif"
          className="hidden"
          onChange={(e) => {
            void handleImageSelect(e)
          }}
        />
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={() => {
              setShowEmojiPicker(!showEmojiPicker)
              setShowStickerPicker(false)
            }}
            disabled={disabled || isSending || isUploading || !currentConversation}
            className={`w-9 h-9 flex items-center justify-center rounded-lg transition-all flex-shrink-0 ${
              showEmojiPicker
                ? 'bg-sky-100 text-sky-600'
                : 'text-slate-400 hover:bg-slate-50 hover:text-slate-600'
            }`}
            title="Emoji"
            aria-label="Open emoji picker"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M14.828 14.828a4 4 0 01-5.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
          </button>
          <button
            type="button"
            onClick={() => {
              setShowStickerPicker(!showStickerPicker)
              setShowEmojiPicker(false)
            }}
            disabled={disabled || isSending || isUploading || !currentConversation}
            className={`w-9 h-9 flex items-center justify-center rounded-lg transition-all flex-shrink-0 ${
              showStickerPicker
                ? 'bg-sky-100 text-sky-600'
                : 'text-slate-400 hover:bg-slate-50 hover:text-slate-600'
            }`}
            title="Stickers"
            aria-label="Open sticker picker"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
            </svg>
          </button>
          <button
            type="button"
            onClick={() => fileInputRef.current?.click()}
            disabled={disabled || isSending || isUploading || !currentConversation}
            className={`w-9 h-9 flex items-center justify-center rounded-lg transition-all flex-shrink-0 ${
              !disabled && !isSending && !isUploading && currentConversation
                ? 'text-slate-400 hover:bg-slate-50 hover:text-slate-600'
                : 'text-slate-300'
            }`}
            title="Upload image"
            aria-label="Upload image"
          >
            {isUploading ? (
              <div className="w-4 h-4 border-2 border-slate-300 border-t-slate-500 rounded-full animate-spin" />
            ) : (
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2 1.586-1.586a2 2 0 012.828 0L20 14m-6-10h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z" />
              </svg>
            )}
          </button>
        </div>
        <div className="relative flex-1">
          {/* Highlights Overlay */}
          <div 
            ref={overlayRef}
            className="absolute inset-0 pointer-events-none whitespace-pre-wrap break-words overflow-hidden py-2 px-3 m-0 border-none font-inherit"
            style={{ 
              fontFamily: 'inherit',
              fontSize: 'inherit',
              lineHeight: 'inherit'
            }}
            aria-hidden="true"
          >
            {renderHighlights(content)}
            {/* Add a trailing space if content ends with newline to keep scrolling in sync */}
            {content.endsWith('\n') ? <br /> : null}
          </div>
          
          <textarea
            ref={textareaRef}
            value={content}
            onChange={handleChange}
            onSelect={handleSelect}
            onKeyDown={handleKeyDown}
            onScroll={handleScroll}
            onBlur={() => {
              setMentionActive(false)
              setSlashActive(false)
            }}
            disabled={disabled || isSending || isUploading}
            rows={1}
            className="w-full bg-transparent border-none focus:ring-0 resize-none py-2 px-3 placeholder:text-transparent max-h-[200px] relative z-10 m-0"
            style={{ color: 'transparent', caretColor: '#334155' }}
            aria-label={placeholder}
          />
        </div>
        <button
          type="button"
          onClick={() => void handleSend()}
          disabled={!content.trim() || isSending || isUploading || disabled}
          className={`w-10 h-10 flex items-center justify-center rounded-xl transition-all flex-shrink-0 ${
            content.trim() && !isSending && !isUploading && !disabled
              ? 'bg-[#0EA5E9] text-white shadow-lg shadow-sky-200 hover:scale-105 active:scale-95'
              : 'bg-slate-100 text-slate-400'
          }`}
          title="Send message"
          aria-label="Send message"
        >
          {isSending ? (
            <div className="w-5 h-5 border-2 border-white/30 border-t-white rounded-full animate-spin" />
          ) : (
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M5 12h14M12 5l7 7-7 7" />
            </svg>
          )}
        </button>
      </div>
    </div>
  )
}

function toMentionBot(member: GroupMember): MentionBot | null {
  const id = member.bot_id || member.bot?.id
  const name = member.nickname?.trim() || member.bot?.name
  if (!id || !name) {
    return null
  }

  const aliases = [...new Set([member.nickname, member.bot?.name].map((item) => item?.trim()).filter(Boolean) as string[])]
  return {
    id,
    name,
    avatar: member.bot?.avatar || member.bot?.avatar_url || null,
    aliases,
  }
}

function buildMentionMeta(
  body: string,
  bots: MentionCandidate[],
): Record<string, unknown> {
  const encoded = encodeMentionedBots(body, bots)
  if (encoded.mentionedBotIds.length === 0) {
    return {}
  }

  return {
    mentioned_bot_ids: encoded.mentionedBotIds,
    ...(encoded.normalizedBody ? { normalized_body: encoded.normalizedBody } : {}),
  }
}

function buildSlashCommandMeta(
  body: string,
  commands: SlashCommand[],
): Record<string, unknown> {
  const text = body.trim()
  if (!text.startsWith('/')) {
    return {}
  }

  const commandName = text.slice(1).split(/\s+/, 1)[0]?.trim()
  if (!commandName) {
    return {}
  }

  const matched = commands.find((command) => command.name.toLowerCase() === commandName.toLowerCase())
  if (!matched) {
    return {}
  }

  return {
    command_source: 'native',
    native_command: true,
    native_command_name: matched.name,
  }
}

function encodeMentionedBots(
  body: string,
  bots: MentionCandidate[],
): { mentionedBotIds: string[]; normalizedBody?: string } {
  const text = body.trim()
  if (!text || bots.length === 0) {
    return { mentionedBotIds: [] }
  }

  const candidates = bots
    .flatMap((bot) => {
      const aliases = [...new Set([bot.name, ...(bot.aliases || [])].map((item) => item.trim()).filter(Boolean))]
      return aliases.map((alias) => ({ id: bot.id, alias }))
    })
    .sort((left, right) => right.alias.length - left.alias.length)

  const mentioned = new Set<string>()
  const normalizedParts: string[] = []
  let lastIndex = 0

  for (let index = 0; index < text.length; ) {
    const char = text[index]
    if (char !== '@' && char !== '＠') {
      index += 1
      continue
    }

    const remaining = text.slice(index + 1)
    let matched = false

    for (const bot of candidates) {
      if (!remaining.startsWith(bot.alias)) {
        continue
      }
      if (!hasMentionBoundary(remaining.slice(bot.alias.length))) {
        continue
      }

      mentioned.add(bot.id)
      normalizedParts.push(text.slice(lastIndex, index))
      normalizedParts.push(`<@bot:${bot.id}>`)
      index += 1 + bot.alias.length
      lastIndex = index
      matched = true
      break
    }

    if (!matched) {
      index += 1
    }
  }

  normalizedParts.push(text.slice(lastIndex))

  const normalizedBody = normalizedParts.join('')
  return {
    mentionedBotIds: [...mentioned],
    ...(normalizedBody !== text ? { normalizedBody } : {}),
  }
}

function hasMentionBoundary(remaining: string): boolean {
  if (!remaining) {
    return true
  }

  return /[\s\p{P}\p{S}]/u.test(remaining[0] || '')
}
