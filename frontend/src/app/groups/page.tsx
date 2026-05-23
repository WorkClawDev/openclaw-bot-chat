'use client'

import React, { useState, useEffect, useRef } from 'react'
import { useAuth } from '@/contexts/AuthContext'
import { useChat } from '@/contexts/ChatContext'
import { groupsApi } from '@/lib/api'
import { AppLayout } from '@/components/AppLayout'
import { Button } from '@/components/Button'
import { Input } from '@/components/Input'
import { Avatar } from '@/components/Avatar'
import { IconButton } from '@/components/IconButton'
import { PaneHeader } from '@/components/PaneHeader'
import { StatusPill } from '@/components/StatusPill'
import { WorkspaceCollectionPane } from '@/components/WorkspaceCollectionPane'
import { LoadingPage } from '@/components/Loading'
import { ConversationItem } from '@/components/Chat/ConversationItem'
import { MessageBubble } from '@/components/Chat/MessageBubble'
import { ChatInput } from '@/components/Chat/ChatInput'
import type { Group, GroupMember } from '@/lib/types'

export default function GroupsPage() {
  const { isAuthenticated, isLoading: authLoading, user } = useAuth()
  const {
    groups,
    bots,
    isLoading: chatLoading,
    currentConversation,
    messages,
    openGroupConversation,
    sendMessage,
    refreshGroups,
    refreshMessages,
    connectionState,
  } = useChat()
  
  const [searchTerm, setSearchTerm] = useState('')
  const [view, setView] = useState<'chat' | 'create'>('chat')
  const [selectedGroup, setSelectedGroup] = useState<Group | null>(null)
  const [showDrawer, setShowDrawer] = useState(false)
  const [showMobileList, setShowMobileList] = useState(true)
  
  const messagesEndRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!authLoading && !isAuthenticated) {
      window.location.href = '/login'
    }
  }, [authLoading, isAuthenticated])

  useEffect(() => {
    if (isAuthenticated) {
      void refreshGroups()
    }
  }, [isAuthenticated, refreshGroups])

  useEffect(() => {
    if (currentConversation && currentConversation.type === 'group') {
      void refreshMessages(currentConversation.id)
      const group = groups.find(g => g.id === currentConversation.target.id)
      if (group) setSelectedGroup(group)
      setView('chat')
    }
  }, [currentConversation?.id, currentConversation?.target.id, currentConversation?.type, refreshMessages, groups])

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages, currentConversation])

  const filteredGroups = groups.filter(group => 
    group.name.toLowerCase().includes(searchTerm.toLowerCase())
  )

  const handleGroupClick = (group: Group) => {
    openGroupConversation(group)
    setSelectedGroup(group)
    setView('chat')
    setShowDrawer(false)
    setShowMobileList(false)
  }

  const currentMessages = currentConversation ? messages.get(currentConversation.id) || [] : []

  if (authLoading) return <LoadingPage />
  if (!isAuthenticated) return null

  return (
    <AppLayout>
      <WorkspaceCollectionPane
        title="Groups"
        createLabel="Create group"
        searchPlaceholder="Search groups..."
        searchTerm={searchTerm}
        onSearchChange={setSearchTerm}
        items={filteredGroups}
        isLoading={chatLoading}
        isVisible={showMobileList}
        emptyLabel="No groups found"
        emptyActionLabel="Create one"
        onCreate={() => { setView('create'); setShowMobileList(false); }}
        renderItem={(group) => (
          <ConversationItem
            key={group.id}
            name={group.name}
            avatar={group.avatar}
            isActive={selectedGroup?.id === group.id && view === 'chat'}
            onClick={() => handleGroupClick(group)}
            lastMessage={group.description || ''}
          />
        )}
      />

      {/* Column 3: Main Area */}
      <section className={`flex-1 h-full flex flex-col bg-white relative overflow-hidden ${!showMobileList ? 'flex' : 'hidden md:flex'}`}>
        {view === 'chat' && currentConversation ? (
          <>
            <PaneHeader
              leading={
                <>
                <IconButton
                  onClick={() => setShowMobileList(true)}
                  label="Back to groups"
                  variant="ghost"
                  className="md:hidden"
                >
                  <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M15 19l-7-7 7-7" /></svg>
                </IconButton>
                <Avatar name={currentConversation.name} src={currentConversation.avatar} size="md" />
                </>
              }
              title={currentConversation.name}
              subtitle={
                <>
                  <StatusPill tone="neutral">{selectedGroup?.member_count || 0} members</StatusPill>
                  <StatusPill tone={connectionState === 'connected' ? 'success' : 'warning'}>
                    {connectionState === 'connected' ? 'realtime on' : connectionState}
                  </StatusPill>
                </>
              }
              actions={
                <IconButton
                  onClick={() => setShowDrawer(!showDrawer)}
                  label="Group details"
                  active={showDrawer}
                >
                  <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z" />
                  </svg>
                </IconButton>
              }
            />

            {/* Messages */}
            <div className="flex-1 overflow-y-auto p-6 scroll-smooth">
              {currentMessages.length === 0 ? (
                <div className="flex flex-col items-center justify-center h-full text-slate-300 gap-4 opacity-60">
                   <div className="w-20 h-20 bg-slate-50 rounded-full flex items-center justify-center">
                    <svg className="w-10 h-10" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z" />
                    </svg>
                  </div>
                  <p className="text-sm font-medium italic">Start the conversation in {selectedGroup?.name}</p>
                </div>
              ) : (
                <>
                  {currentMessages.map((msg, index) => (
                    <MessageBubble
                      key={msg.id}
                      message={msg}
                      isOwn={msg.sender_id === user?.id}
                      showSenderName={true}
                      mentions={bots.map(b => b.name)}
                    />
                  ))}
                  <div ref={messagesEndRef} />
                </>
              )}
            </div>

            {/* Input */}
            <ChatInput onSendMessage={sendMessage} placeholder={`Message ${selectedGroup?.name}...`} />
          </>
        ) : view === 'create' ? (
          <div className="flex-1 overflow-y-auto p-5 md:p-10 lg:p-12 max-w-2xl mx-auto w-full">
            <header className="mb-6 md:mb-8 flex items-start gap-3">
              <IconButton onClick={() => { setView('chat'); setShowMobileList(true); }} label="Back to groups" variant="ghost" className="md:hidden -ml-2 mt-1">
                <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M15 19l-7-7 7-7" /></svg>
              </IconButton>
              <div>
                <h2 className="text-2xl md:text-3xl font-bold text-slate-800 tracking-tight">Create New Group</h2>
              <p className="text-slate-500 mt-1">Bring your bots together in one conversation.</p>
            </div>
            </header>
            
            <CreateGroupForm
              onCancel={() => { setView('chat'); setShowMobileList(true); }}
              onSuccess={(group) => {
                openGroupConversation(group)
                setSelectedGroup(group)
                void refreshGroups()
                setView('chat')
                setShowMobileList(false)
              }}
            />
          </div>
        ) : (
          <div className="flex-1 flex flex-col items-center justify-center text-slate-300 gap-6">
            <div className="w-32 h-32 bg-slate-50 rounded-3xl flex items-center justify-center shadow-inner">
               <svg className="w-16 h-16" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1} d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z" />
              </svg>
            </div>
            <div className="text-center">
              <h3 className="text-lg font-bold text-slate-400">Select a group to start chatting</h3>
              <p className="text-sm">Or create a new one using the button in the side list.</p>
            </div>
          </div>
        )}

        {/* Column 4: Right Drawer */}
        {selectedGroup && showDrawer && (
          <div 
            className="absolute right-0 top-0 z-20 h-full w-full bg-white shadow-2xl transition-transform duration-300 md:w-[320px] md:border-l border-slate-100"
          >
            <GroupDrawer
              group={selectedGroup}
              onClose={() => setShowDrawer(false)}
              onUpdate={() => {
                void refreshGroups()
              }}
              currentUserId={user?.id || ''}
            />
          </div>
        )}
      </section>
    </AppLayout>
  )
}

function CreateGroupForm({
  onCancel,
  onSuccess
}: {
  onCancel: () => void
  onSuccess: (group: Group) => void
}) {
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState('')

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!name.trim()) return setError('Name is required')
    
    setIsLoading(true)
    setError('')
    try {
      const created = await groupsApi.create({ name, description })
      onSuccess(created)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create group')
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      {error && (
        <div className="p-4 bg-red-50 text-red-600 rounded-xl text-sm border border-red-100">
          {error}
        </div>
      )}
      
      <div className="space-y-4">
        <Input
          label="Group Name"
          placeholder="e.g. AI Council"
          value={name}
          onChange={(e) => setName(e.target.value)}
          className="rounded-2xl border-slate-200"
        />
        
        <div className="space-y-1.5">
          <label className="text-sm font-bold text-slate-700 ml-1">Description</label>
          <textarea
            className="w-full px-4 py-3 bg-white border border-slate-200 rounded-2xl focus:outline-none focus:ring-2 focus:ring-sky-500/20 min-h-[100px] transition-all"
            placeholder="What's this group for?"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </div>
      </div>

      <div className="flex gap-3 pt-4 border-t border-slate-100">
        <Button type="submit" isLoading={isLoading} className="rounded-2xl px-8 shadow-lg shadow-sky-100">
          Create Group
        </Button>
        <Button type="button" variant="ghost" onClick={onCancel} className="rounded-2xl">
          Cancel
        </Button>
      </div>
    </form>
  )
}

function GroupDrawer({
  group,
  onClose,
  onUpdate,
  currentUserId
}: {
  group: Group
  onClose: () => void
  onUpdate: () => void
  currentUserId: string
}) {
  const [members, setMembers] = useState<GroupMember[]>([])
  const [isLoading, setIsLoading] = useState(true)
  const [showAdd, setShowAdd] = useState(false)
  const [newMemberId, setNewMemberId] = useState('')
  const [memberType, setMemberType] = useState<'user' | 'bot'>('user')
  const [isAdding, setIsAdding] = useState(false)

  useEffect(() => {
    void loadMembers()
  }, [group.id])

  const loadMembers = async () => {
    setIsLoading(true)
    try {
      const data = await groupsApi.getMembers(group.id)
      setMembers([
        ...(data.users || []).map(m => ({ ...m, type: 'user' as const })),
        ...(data.bots || []).map(m => ({ ...m, type: 'bot' as const }))
      ])
    } catch (e) {
      console.error(e)
    } finally {
      setIsLoading(false)
    }
  }

  const handleAddMember = async () => {
    if (!newMemberId.trim()) return
    setIsAdding(true)
    try {
      await groupsApi.addMember(group.id, memberType === 'user' ? { user_id: newMemberId } : { bot_id: newMemberId })
      setNewMemberId('')
      setShowAdd(false)
      void loadMembers()
      onUpdate()
    } catch (e) {
      alert('Failed to add member')
    } finally {
      setIsAdding(false)
    }
  }

  const isOwner = group.owner_id === currentUserId

  return (
    <div className="flex flex-col h-full">
      <header className="h-[72px] px-6 flex items-center justify-between border-b border-slate-100">
        <h3 className="font-bold text-slate-800">Group Details</h3>
        <IconButton onClick={onClose} label="Close group details" variant="ghost">
          <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
          </svg>
        </IconButton>
      </header>

      <div className="flex-1 overflow-y-auto p-6 space-y-8">
        <div className="space-y-4">
          <div className="flex flex-col items-center gap-3">
             <Avatar name={group.name} src={group.avatar} size="lg" className="w-20 h-20 shadow-xl shadow-slate-200" />
             <div className="text-center">
                <h4 className="text-lg font-bold text-slate-800">{group.name}</h4>
                <p className="text-xs text-slate-400 font-medium">{group.description || 'No description'}</p>
             </div>
          </div>
        </div>

        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <h4 className="text-xs font-black text-slate-400 uppercase tracking-widest">Members</h4>
            {isOwner && (
              <button 
                onClick={() => setShowAdd(!showAdd)}
                className="text-xs font-bold text-sky-500 hover:text-sky-600"
              >
                {showAdd ? 'Cancel' : '+ Add'}
              </button>
            )}
          </div>

          {showAdd && (
            <div className="p-4 bg-slate-50 rounded-2xl border border-slate-100 space-y-3">
               <div className="flex gap-2">
                 <button 
                  onClick={() => setMemberType('user')}
                  aria-pressed={memberType === 'user'}
                  className={`flex-1 py-1.5 text-[10px] font-bold uppercase tracking-tighter rounded-lg transition-all ${memberType === 'user' ? 'bg-sky-500 text-white shadow-md shadow-sky-100' : 'bg-white text-slate-400 border border-slate-200'}`}
                 >
                   User
                 </button>
                 <button 
                  onClick={() => setMemberType('bot')}
                  aria-pressed={memberType === 'bot'}
                  className={`flex-1 py-1.5 text-[10px] font-bold uppercase tracking-tighter rounded-lg transition-all ${memberType === 'bot' ? 'bg-sky-500 text-white shadow-md shadow-sky-100' : 'bg-white text-slate-400 border border-slate-200'}`}
                 >
                   Bot
                 </button>
               </div>
               <div className="flex gap-2">
                 <input 
                  type="text"
                  placeholder={`Enter ${memberType} ID`}
                  value={newMemberId}
                  onChange={e => setNewMemberId(e.target.value)}
                  className="flex-1 px-3 py-2 text-sm bg-white border border-slate-200 rounded-xl focus:outline-none focus:ring-2 focus:ring-sky-500/20"
                 />
                 <button 
                  onClick={handleAddMember}
                  disabled={!newMemberId || isAdding}
                  className="px-3 py-2 bg-sky-500 text-white rounded-xl disabled:bg-slate-200 shadow-sm"
                 >
                   {isAdding ? <div className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin" /> : 'Add'}
                 </button>
               </div>
            </div>
          )}

          <div className="space-y-3">
            {isLoading ? (
              <div className="text-center py-4 text-slate-300 italic text-sm">Loading members...</div>
            ) : members.map(m => (
              <div key={m.id} className="flex items-center justify-between group">
                <div className="flex items-center gap-3">
                  <Avatar name={m.user?.username || m.bot?.name || 'User'} size="sm" />
                  <div>
                    <p className="text-sm font-bold text-slate-700">{m.user?.username || m.bot?.name || 'Unknown'}</p>
                    <p className="text-[10px] text-slate-400 font-medium uppercase tracking-tighter">{m.role}{m.type === 'bot' && ' • BOT'}</p>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}
