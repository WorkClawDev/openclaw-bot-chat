'use client'

import React, { useState, useEffect, useRef, useMemo } from 'react'
import { useAuth } from '@/contexts/AuthContext'
import { useChat } from '@/contexts/ChatContext'
import { botsApi } from '@/lib/api'
import { AppLayout } from '@/components/AppLayout'
import { Button } from '@/components/Button'
import { Input } from '@/components/Input'
import { Avatar } from '@/components/Avatar'
import { IconButton } from '@/components/IconButton'
import { Modal } from '@/components/Modal'
import { WorkspaceCollectionPane } from '@/components/WorkspaceCollectionPane'
import { LoadingPage } from '@/components/Loading'
import { ConversationItem } from '@/components/Chat/ConversationItem'
import { AgentIcon } from '@/components/Chat/AgentIcon'
import { AgentConversation } from '@/components/Chat/AgentConversation'
import { cropAndUploadAvatar } from '@/lib/imageUpload'
import type { Bot, BotKey } from '@/lib/types'

const BOT_AVATAR_PRESETS = [
  { id: 'coral-circuit', name: 'Coral', src: '/bot-avatars/coral-circuit.svg' },
  { id: 'green-signal', name: 'Signal', src: '/bot-avatars/green-signal.svg' },
  { id: 'indigo-core', name: 'Core', src: '/bot-avatars/indigo-core.svg' },
  { id: 'violet-orbit', name: 'Orbit', src: '/bot-avatars/violet-orbit.svg' },
]

export default function BotsPage() {
  const { isAuthenticated, isLoading: authLoading, user } = useAuth()
  const {
    bots,
    isLoading: chatLoading,
    currentConversation,
    messages,
    openBotConversation,
    sendMessage,
    refreshBots,
    refreshMessages,
    connectionState,
  } = useChat()
  
  const [searchTerm, setSearchTerm] = useState('')
  const [view, setView] = useState<'chat' | 'create' | 'edit' | 'keys'>('chat')
  const [selectedBot, setSelectedBot] = useState<Bot | null>(null)
  const [showKeyModalBot, setShowKeyModalBot] = useState<Bot | null>(null)
  const [showMobileList, setShowMobileList] = useState(true)
  const [isRefreshingMessages, setIsRefreshingMessages] = useState(false)

  useEffect(() => {
    if (!authLoading && !isAuthenticated) {
      window.location.href = '/login'
    }
  }, [authLoading, isAuthenticated])

  useEffect(() => {
    if (isAuthenticated) {
      void refreshBots()
    }
  }, [isAuthenticated, refreshBots])

  useEffect(() => {
    if (currentConversation && currentConversation.type === 'bot') {
      const bot = bots.find(b => b.id === currentConversation.target.id)
      if (bot) setSelectedBot(bot)
      setView('chat')
    }
  }, [currentConversation?.id, currentConversation?.target.id, currentConversation?.type, bots])

  useEffect(() => {
    if (!currentConversation || currentConversation.type !== 'bot') {
      setIsRefreshingMessages(false)
      return
    }

    let cancelled = false
    setIsRefreshingMessages(true)
    void refreshMessages(currentConversation.id)
      .catch((error) => {
        console.error('Failed to refresh bot messages:', error)
      })
      .finally(() => {
        if (!cancelled) {
          setIsRefreshingMessages(false)
        }
      })

    return () => {
      cancelled = true
    }
  }, [currentConversation?.id, currentConversation?.type, refreshMessages])

  const filteredBots = bots.filter(bot => 
    bot.name.toLowerCase().includes(searchTerm.toLowerCase())
  )

  const handleBotClick = (bot: Bot) => {
    openBotConversation(bot)
    setSelectedBot(bot)
    setView('chat')
    setShowMobileList(false)
  }

  const currentMessages = currentConversation ? messages.get(currentConversation.id) || [] : []
  const mentionNames = useMemo(() => bots.map(bot => bot.name), [bots])

  if (authLoading) return <LoadingPage />
  if (!isAuthenticated) return null

  return (
    <AppLayout>
      <WorkspaceCollectionPane
        title="Agents"
        description="A place to think, make, and get things done."
        createLabel="Create bot"
        searchPlaceholder="Find an agent…"
        searchTerm={searchTerm}
        onSearchChange={setSearchTerm}
        items={filteredBots}
        isLoading={chatLoading}
        isVisible={showMobileList}
        emptyLabel="No agents found"
        emptyActionLabel="Create one"
        onCreate={() => { setView('create'); setShowMobileList(false); }}
        renderItem={(bot) => (
          <ConversationItem
            key={bot.id}
            name={bot.name}
            avatar={bot.avatar || bot.avatar_url}
            isActive={selectedBot?.id === bot.id && view === 'chat'}
            onClick={() => handleBotClick(bot)}
            status="none"
            lastMessage={bot.description || 'Open workspace'}
          />
        )}
      />

      {/* Column 3: Main Area */}
      <section className={`flex-1 min-w-0 h-full flex flex-col bg-white relative overflow-hidden ${!showMobileList ? 'flex' : 'hidden md:flex'}`}>
        {view === 'chat' && currentConversation?.type === 'bot' && selectedBot ? (
          <AgentConversation key={currentConversation.id} bot={selectedBot} conversation={currentConversation}
            messages={currentMessages} mentions={mentionNames} userId={user?.id} loading={isRefreshingMessages}
            connectionState={connectionState} onBack={() => setShowMobileList(true)} onConfigure={() => setView('edit')} onSend={sendMessage} />
        ) : view === 'create' || view === 'edit' ? (
          <div className="flex-1 overflow-y-auto p-5 md:p-10 lg:p-12 max-w-2xl mx-auto w-full">
            <header className="mb-6 md:mb-8 flex items-start gap-3">
              <IconButton onClick={() => { setView('chat'); setShowMobileList(true); }} label="Back to bots" variant="ghost" className="md:hidden -ml-2 mt-1">
                <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M15 19l-7-7 7-7" /></svg>
              </IconButton>
              <div>
                <h2 className="text-2xl md:text-3xl font-bold text-slate-800 tracking-tight">
                {view === 'create' ? 'Create New Bot' : `Configure ${selectedBot?.name}`}
              </h2>
              <p className="text-slate-500 mt-1">
                {view === 'create' ? 'Give your AI bot a name and personality.' : 'Update your bot details and manage API keys.'}
              </p>
            </div>
            </header>
            
            <CreateEditBotForm
              bot={view === 'edit' ? selectedBot : null}
              onCancel={() => { setView('chat'); setShowMobileList(true); }}
              onSuccess={async (bot) => {
                await refreshBots()
                openBotConversation(bot)
                setSelectedBot(bot)
                setView('chat')
                setShowMobileList(false)
              }}
              onShowKeys={(bot) => setShowKeyModalBot(bot)}
            />
          </div>
        ) : (
          <div className="agent-home">
            <span className="agent-welcome-mark"><AgentIcon name="spark" size={30} /></span>
            <p className="agent-eyebrow mt-6">YOUR AGENT WORKSPACE</p>
            <h1>Good work starts with a conversation.</h1>
            <p>Choose an agent to explore an idea, work with your files, or move a task forward.</p>
            <button className="agent-primary-button mt-6" onClick={() => { setView('create'); setShowMobileList(false) }}>Create an agent <span aria-hidden="true">＋</span></button>
          </div>
        )}
      </section>

      {/* Keys Modal */}
      {showKeyModalBot && (
        <BotKeysModal
          isOpen={true}
          onClose={() => setShowKeyModalBot(null)}
          bot={showKeyModalBot}
        />
      )}
    </AppLayout>
  )
}

function CreateEditBotForm({
  bot,
  onCancel,
  onSuccess,
  onShowKeys
}: {
  bot: Bot | null
  onCancel: () => void
  onSuccess: (bot: Bot) => void | Promise<void>
  onShowKeys: (bot: Bot) => void
}) {
  const [name, setName] = useState(bot?.name || '')
  const [description, setDescription] = useState(bot?.description || '')
  const [avatarUrl, setAvatarUrl] = useState(bot?.avatar || bot?.avatar_url || '')
  const [isUploadingAvatar, setIsUploadingAvatar] = useState(false)
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState('')
  const avatarInputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    setName(bot?.name || '')
    setDescription(bot?.description || '')
    setAvatarUrl(bot?.avatar || bot?.avatar_url || '')
    setError('')
  }, [bot?.id, bot?.name, bot?.description, bot?.avatar, bot?.avatar_url])

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!name.trim()) return setError('Name is required')
    
    setIsLoading(true)
    setError('')
    try {
      const payload = {
        name,
        description,
        avatar_url: avatarUrl,
      }

      if (bot) {
        const updated = await botsApi.update(bot.id, payload)
        await onSuccess(updated)
      } else {
        const created = await botsApi.create(payload)
        await onSuccess(created)
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save bot')
    } finally {
      setIsLoading(false)
    }
  }

  const handleAvatarFileSelect = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0]
    if (!file || isUploadingAvatar) {
      event.target.value = ''
      return
    }

    setIsUploadingAvatar(true)
    setError('')
    try {
      const uploadedAvatarUrl = await cropAndUploadAvatar(file)
      setAvatarUrl(uploadedAvatarUrl)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to upload avatar')
    } finally {
      setIsUploadingAvatar(false)
      event.target.value = ''
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      {error && (
        <div className="p-4 bg-red-50 text-red-600 rounded-xl text-sm border border-red-100 animate-pulse">
          {error}
        </div>
      )}
      
      <div className="space-y-4">
        <section className="space-y-3">
          <div className="flex items-center gap-4">
            <Avatar
              name={name || 'Bot'}
              src={avatarUrl || undefined}
              size="xl"
              className="h-20 w-20 flex-none shadow-lg shadow-slate-100 ring-4 ring-slate-50"
            />
            <div className="min-w-0 flex-1">
              <p className="text-sm font-bold text-slate-700">Bot Avatar</p>
              <div className="mt-2 flex flex-wrap gap-2">
                <input
                  ref={avatarInputRef}
                  type="file"
                  accept="image/png,image/jpeg,image/webp"
                  className="hidden"
                  onChange={(event) => {
                    void handleAvatarFileSelect(event)
                  }}
                />
                <Button
                  type="button"
                  variant="secondary"
                  size="sm"
                  isLoading={isUploadingAvatar}
                  onClick={() => avatarInputRef.current?.click()}
                  className="rounded-xl"
                >
                  Upload image
                </Button>
                {avatarUrl && (
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    onClick={() => setAvatarUrl('')}
                    className="rounded-xl"
                  >
                    Remove
                  </Button>
                )}
              </div>
            </div>
          </div>

          <div className="grid grid-cols-4 gap-3">
            {BOT_AVATAR_PRESETS.map((preset) => {
              const selected = avatarUrl === preset.src
              return (
                <button
                  key={preset.id}
                  type="button"
                  onClick={() => setAvatarUrl(preset.src)}
                  className={`aspect-square rounded-2xl border p-1.5 transition-all focus:outline-none focus-visible:ring-2 focus-visible:ring-sky-500 ${
                    selected ? 'border-sky-400 bg-sky-50 shadow-sm' : 'border-slate-200 hover:border-slate-300 hover:bg-slate-50'
                  }`}
                  aria-label={`Use ${preset.name} avatar`}
                  title={preset.name}
                >
                  <img src={preset.src} alt="" className="h-full w-full rounded-xl object-cover" />
                </button>
              )
            })}
          </div>
        </section>

        <Input
          label="Display Name"
          placeholder="e.g. JARVIS"
          value={name}
          onChange={(e) => setName(e.target.value)}
          className="rounded-2xl border-slate-200"
        />
        
        <div className="space-y-1.5">
          <label className="text-sm font-bold text-slate-700 ml-1">Bot Personality / Description</label>
          <textarea
            className="w-full px-4 py-3 bg-white border border-slate-200 rounded-2xl focus:outline-none focus:ring-2 focus:ring-sky-500/20 min-h-[120px] transition-all"
            placeholder="Tell us about this bot's role..."
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </div>
      </div>

      <div className="flex items-center justify-between pt-4 border-t border-slate-100">
        <div className="flex gap-3">
          <Button type="submit" isLoading={isLoading} disabled={isUploadingAvatar} className="rounded-2xl px-8 shadow-lg shadow-sky-100">
            {bot ? 'Save Changes' : 'Create Bot'}
          </Button>
          <Button type="button" variant="ghost" onClick={onCancel} className="rounded-2xl">
            Cancel
          </Button>
        </div>
        
        {bot && (
          <Button
            type="button"
            variant="secondary"
            onClick={() => onShowKeys(bot)}
            className="rounded-2xl bg-white border-slate-200"
          >
            Manage API Keys
          </Button>
        )}
      </div>
    </form>
  )
}

function BotKeysModal({
  isOpen,
  onClose,
  bot,
}: {
  isOpen: boolean
  onClose: () => void
  bot: Bot
}) {
  const [keys, setKeys] = useState<BotKey[]>([])
  const [isLoading, setIsLoading] = useState(false)
  const [newKeyName, setNewKeyName] = useState('')
  const [createdKey, setCreatedKey] = useState<string | null>(null)

  useEffect(() => {
    if (isOpen) {
      void loadKeys()
    }
  }, [isOpen])

  const loadKeys = async () => {
    try {
      const data = await botsApi.listKeys(bot.id)
      setKeys(data)
    } catch (error) {
      console.error('Failed to load keys')
    }
  }

  const handleCreateKey = async () => {
    setIsLoading(true)
    try {
      const key = await botsApi.createKey(bot.id, { name: newKeyName || undefined })
      setKeys(prev => [...prev, key])
      setCreatedKey(key.key || null)
      setNewKeyName('')
    } catch (error) {
      alert('Failed to create key')
    } finally {
      setIsLoading(false)
    }
  }

  const handleDeleteKey = async (keyId: string) => {
    if (!confirm('Revoke this key immediately?')) return
    try {
      await botsApi.deleteKey(bot.id, keyId)
      setKeys(prev => prev.filter(k => k.id !== keyId))
    } catch (error) {
      alert('Failed to delete key')
    }
  }

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={`API Keys: ${bot.name}`} size="lg">
      <div className="space-y-6 py-2">
        <div className="p-4 bg-sky-50 rounded-xl border border-sky-100 space-y-3">
          <div className="flex items-center gap-2">
            <span className="text-[10px] font-black text-sky-600 uppercase tracking-widest bg-white px-2 py-0.5 rounded-full shadow-sm">
              Runtime ID
            </span>
            <code className="text-sm font-mono text-sky-800 break-all">{bot.id}</code>
            <IconButton label="Copy runtime ID" size="sm" variant="ghost" onClick={() => void navigator.clipboard?.writeText(bot.id)}>
              <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" /></svg>
            </IconButton>
          </div>
          <p className="text-xs text-sky-700/70 leading-relaxed font-medium">
            Provide this ID to your bot plugin if bootstrap discovery is not configured.
          </p>
        </div>

        {createdKey && (
          <div className="p-5 bg-emerald-50 rounded-2xl border border-emerald-100 space-y-4 animate-in fade-in slide-in-from-top-4">
             <p className="text-sm font-bold text-emerald-800">New Key Created!</p>
             <div className="flex items-center gap-2 rounded-xl border border-emerald-100 bg-white p-3 shadow-sm">
              <code className="min-w-0 flex-1 break-all font-mono text-xs">{createdKey}</code>
              <IconButton label="Copy new key" size="sm" variant="ghost" onClick={() => void navigator.clipboard?.writeText(createdKey)}>
                <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" /></svg>
              </IconButton>
            </div>
            <p className="text-[10px] text-emerald-600 font-bold uppercase tracking-tight">
              Copy this now. You won&apos;t be able to see it again.
            </p>
          </div>
        )}

        <div className="space-y-3">
          <h4 className="text-sm font-bold text-slate-800 ml-1">Generate Key</h4>
          <div className="flex gap-2">
            <Input
              placeholder="e.g. Production Server"
              value={newKeyName}
              onChange={(e) => setNewKeyName(e.target.value)}
              className="flex-1 rounded-2xl border-slate-200"
            />
            <Button onClick={handleCreateKey} isLoading={isLoading} className="rounded-2xl px-6">
              Create
            </Button>
          </div>
        </div>

        <div className="space-y-3">
          <h4 className="text-sm font-bold text-slate-800 ml-1">Active Keys</h4>
          <div className="space-y-2">
            {keys.length === 0 ? (
              <p className="text-center py-8 text-slate-400 text-sm italic bg-slate-50 rounded-2xl">No active keys found.</p>
            ) : (
              keys.map(key => (
                <div key={key.id} className="flex items-center justify-between p-4 bg-slate-50 rounded-2xl border border-slate-100 group">
                  <div>
                    <p className="text-sm font-bold text-slate-700">{key.name || 'Unnamed Key'}</p>
                    <p className="text-[10px] font-mono text-slate-400 mt-1 uppercase">
                      {key.key_prefix}************************
                    </p>
                  </div>
                  <Button variant="danger" size="sm" onClick={() => handleDeleteKey(key.id)} className="rounded-xl opacity-0 group-hover:opacity-100 transition-opacity">
                    Revoke
                  </Button>
                </div>
              ))
            )}
          </div>
        </div>
      </div>
    </Modal>
  )
}
