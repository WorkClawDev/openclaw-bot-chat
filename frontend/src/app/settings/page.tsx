'use client'

import React, { useState, useEffect } from 'react'
import { useAuth } from '@/contexts/AuthContext'
import { useChat } from '@/contexts/ChatContext'
import { AppLayout } from '@/components/AppLayout'
import { Button } from '@/components/Button'
import { Input } from '@/components/Input'
import { Avatar } from '@/components/Avatar'
import { LoadingPage } from '@/components/Loading'
import { StatusPill } from '@/components/StatusPill'
import { useAppearanceStore, BackgroundType, FontType } from '@/lib/store'

type SettingsTab = 'profile' | 'appearance' | 'notifications' | 'security' | 'system'

const settingsSections: Array<{ id: SettingsTab; label: string; group: string }> = [
  { id: 'profile', label: 'Account & Profile', group: 'Account' },
  { id: 'appearance', label: 'Appearance', group: 'Preferences' },
  { id: 'notifications', label: 'Notifications', group: 'Preferences' },
  { id: 'security', label: 'Security', group: 'Account' },
  { id: 'system', label: 'System', group: 'Diagnostics' },
]

export default function SettingsPage() {
  const { isAuthenticated, isLoading: authLoading, user, updateUser, changePassword, logout } = useAuth()
  const { connectionState } = useChat()
  const [activeTab, setActiveTab] = useState<SettingsTab>('profile')
  const { background, font, setBackground, setFont } = useAppearanceStore()
  
  const [username, setUsername] = useState('')
  const [email, setEmail] = useState('')
  const [isSavingProfile, setIsSavingProfile] = useState(false)
  const [profileMessage, setProfileMessage] = useState('')

  const [oldPassword, setOldPassword] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [isSavingPassword, setIsSavingPassword] = useState(false)
  const [passwordMessage, setPasswordMessage] = useState('')
  const [passwordError, setPasswordError] = useState('')

  useEffect(() => {
    if (!authLoading && !isAuthenticated) {
      window.location.href = '/login'
    }
  }, [authLoading, isAuthenticated])

  useEffect(() => {
    if (user) {
      setUsername(user.username)
      setEmail(user.email)
    }
  }, [user])

  const handleSaveProfile = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!username.trim()) {
      setProfileMessage('Username is required')
      return
    }

    setIsSavingProfile(true)
    setProfileMessage('')

    try {
      await updateUser({ username, email })
      setProfileMessage('Profile updated successfully!')
    } catch (error) {
      setProfileMessage(error instanceof Error ? error.message : 'Failed to update profile')
    } finally {
      setIsSavingProfile(false)
    }
  }

  const handleChangePassword = async (e: React.FormEvent) => {
    e.preventDefault()
    setPasswordError('')

    if (!oldPassword) {
      setPasswordError('Current password is required')
      return
    }
    if (!newPassword) {
      setPasswordError('New password is required')
      return
    }
    if (newPassword.length < 6) {
      setPasswordError('New password must be at least 6 characters')
      return
    }
    if (newPassword !== confirmPassword) {
      setPasswordError('Passwords do not match')
      return
    }

    setIsSavingPassword(true)
    setPasswordMessage('')

    try {
      await changePassword(oldPassword, newPassword)
      setPasswordMessage('Password changed successfully!')
      setOldPassword('')
      setNewPassword('')
      setConfirmPassword('')
    } catch (error) {
      setPasswordError(error instanceof Error ? error.message : 'Failed to change password')
    } finally {
      setIsSavingPassword(false)
    }
  }

  const handleLogout = async () => {
    if (confirm('Are you sure you want to logout?')) {
      await logout()
      window.location.href = '/login'
    }
  }

  if (authLoading) return <LoadingPage />
  if (!isAuthenticated || !user) return null

  return (
    <AppLayout>
      <aside className="hidden h-full w-[300px] flex-shrink-0 flex-col overflow-hidden border-r border-slate-200/70 bg-white/80 backdrop-blur-xl md:flex">
        <div className="p-4 border-b border-slate-200/70">
          <h2 className="text-xl font-bold text-slate-800 tracking-tight">Settings</h2>
        </div>
        <div className="p-2 space-y-5">
          {['Account', 'Preferences', 'Diagnostics'].map((group) => (
            <div key={group} className="space-y-1">
              <p className="px-4 pt-2 text-[10px] font-black uppercase tracking-normal text-slate-400">{group}</p>
              {settingsSections.filter((section) => section.group === group).map((section) => (
                <button
                  key={section.id}
                  onClick={() => setActiveTab(section.id)}
                  className={`w-full rounded-xl px-4 py-3 text-left text-sm font-bold transition-all focus:outline-none focus-visible:ring-2 focus-visible:ring-sky-500 ${activeTab === section.id ? 'bg-sky-50 text-sky-700 ring-1 ring-sky-100' : 'text-slate-500 hover:bg-white'}`}
                >
                  {section.label}
                </button>
              ))}
            </div>
          ))}
        </div>
      </aside>

      <section className="flex-1 h-full overflow-y-auto bg-white p-4 md:p-10 lg:p-12">
        <div className="md:hidden -mx-4 mb-5 overflow-x-auto border-b border-slate-200 px-4 pb-3">
          <div className="flex min-w-max gap-2">
            {settingsSections.map((section) => (
              <button
                key={section.id}
                onClick={() => setActiveTab(section.id)}
                className={`rounded-xl px-3 py-2 text-sm font-bold transition-all ${activeTab === section.id ? 'bg-sky-500 text-white' : 'bg-slate-100 text-slate-600'}`}
              >
                {section.label}
              </button>
            ))}
          </div>
        </div>
        <div className="mx-auto max-w-[760px] space-y-10 pb-20">
          {activeTab === 'profile' && (
            <>
              <header>
                <h1 className="text-3xl font-bold text-slate-800 tracking-tight">Account Settings</h1>
                <p className="text-slate-500 mt-1">Manage your profile and security preferences.</p>
              </header>

              {/* Profile Section */}
              <section className="space-y-6">
                <h2 className="text-sm font-black text-slate-400 uppercase tracking-widest ml-1">Profile Information</h2>
                <div className="bg-white rounded-xl p-5 md:p-8 border border-slate-100 shadow-sm space-y-8">
                  <div className="flex items-center gap-6">
                    <Avatar name={user.username} size="xl" className="w-20 h-20 shadow-lg shadow-slate-100 ring-4 ring-slate-50" />
                    <div>
                      <h3 className="text-xl font-bold text-slate-800">{user.username}</h3>
                      <p className="text-sm text-slate-400">{user.email}</p>
                      <Button size="sm" variant="ghost" className="mt-2 text-sky-500 font-bold px-0 hover:bg-transparent">Change Avatar</Button>
                    </div>
                  </div>

                  <form onSubmit={handleSaveProfile} className="space-y-6">
                    <Input
                      label="Username"
                      value={username}
                      onChange={(e) => setUsername(e.target.value)}
                      className="rounded-2xl"
                    />

                    <Input
                      type="email"
                      label="Email"
                      value={email}
                      onChange={(e) => setEmail(e.target.value)}
                      className="rounded-2xl"
                    />

                    {profileMessage && (
                      <div className={`p-4 rounded-2xl text-sm ${profileMessage.includes('success') ? 'bg-green-50 text-green-700 border border-green-100' : 'bg-red-50 text-red-700 border border-red-100'}`}>
                        {profileMessage}
                      </div>
                    )}

                    <Button type="submit" isLoading={isSavingProfile} className="rounded-2xl px-8 shadow-lg shadow-sky-50">
                      Save Profile Changes
                    </Button>
                  </form>
                </div>
              </section>
            </>
          )}

          {activeTab === 'appearance' && (
            <>
              <header>
                <h1 className="text-3xl font-bold text-slate-800 tracking-tight">Appearance</h1>
                <p className="text-slate-500 mt-1">Customize how the application looks and feels.</p>
              </header>

              <section className="space-y-8">
                <div>
                  <h2 className="text-sm font-black text-slate-400 uppercase tracking-widest ml-1 mb-4">Background Theme</h2>
                    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
                    {[
                      { id: 'default', name: 'Default', colors: 'bg-slate-100' },
                      { id: 'dark', name: 'Dark Night', colors: 'bg-slate-900' },
                      { id: 'nature', name: 'Nature', colors: 'bg-emerald-100' },
                      { id: 'sunset', name: 'Sunset', colors: 'bg-orange-100' },
                      { id: 'ocean', name: 'Ocean', colors: 'bg-sky-100' },
                      { id: 'minimal', name: 'Minimal', colors: 'bg-white border' },
                    ].map((theme) => (
                      <button
                        key={theme.id}
                        onClick={() => setBackground(theme.id as BackgroundType)}
                        className={`p-3 rounded-xl border-2 transition-all text-left space-y-2 ${background === theme.id ? 'border-sky-500 bg-sky-50/50' : 'border-transparent bg-slate-50 hover:bg-slate-100'}`}
                      >
                        <div className={`w-full h-12 rounded-lg ${theme.colors}`} />
                        <span className="block truncate text-center text-sm font-bold text-slate-700">{theme.name}</span>
                      </button>
                    ))}
                  </div>
                </div>

                <div>
                  <h2 className="text-sm font-black text-slate-400 uppercase tracking-widest ml-1 mb-4">Typography</h2>
                  <div className="space-y-2">
                    {[
                      { id: 'sans', name: 'Inter (Default)', class: 'font-sans' },
                      { id: 'roboto', name: 'Roboto', class: 'font-sans' },
                      { id: 'open-sans', name: 'Open Sans', class: 'font-sans' },
                      { id: 'serif', name: 'Playfair Display (Serif)', class: 'font-serif' },
                      { id: 'mono', name: 'Fira Code (Monospace)', class: 'font-mono' },
                    ].map((f) => (
                      <button
                        key={f.id}
                        onClick={() => setFont(f.id as FontType)}
                        className={`w-full flex items-center justify-between p-4 rounded-xl border-2 transition-all ${font === f.id ? 'border-sky-500 bg-sky-50/50' : 'border-transparent bg-slate-50 hover:bg-slate-100'}`}
                      >
                        <span className={`text-lg ${f.class} text-slate-700`}>{f.name}</span>
                        {font === f.id && <div className="w-2 h-2 rounded-full bg-sky-500" />}
                      </button>
                    ))}
                  </div>
                </div>
              </section>
            </>
          )}

          {activeTab === 'security' && (
            <>
              <header>
                <h1 className="text-3xl font-bold text-slate-800 tracking-tight">Security Settings</h1>
                <p className="text-slate-500 mt-1">Manage your password and account security.</p>
              </header>

              {/* Password Section */}
              <section className="space-y-6">
                <h2 className="text-sm font-black text-slate-400 uppercase tracking-widest ml-1">Change Password</h2>
                <div className="bg-white rounded-xl p-5 md:p-8 border border-slate-100 shadow-sm space-y-6">
                  <form onSubmit={handleChangePassword} className="space-y-6">
                    <Input
                      type="password"
                      label="Current Password"
                      value={oldPassword}
                      onChange={(e) => setOldPassword(e.target.value)}
                      autoComplete="current-password"
                      className="rounded-2xl"
                    />

                    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                      <Input
                        type="password"
                        label="New Password"
                        value={newPassword}
                        onChange={(e) => setNewPassword(e.target.value)}
                        autoComplete="new-password"
                        className="rounded-2xl"
                      />
                      <Input
                        type="password"
                        label="Confirm Password"
                        value={confirmPassword}
                        onChange={(e) => setConfirmPassword(e.target.value)}
                        autoComplete="new-password"
                        className="rounded-2xl"
                      />
                    </div>

                    {passwordError && (
                      <div className="p-4 bg-red-50 text-red-700 text-sm rounded-2xl border border-red-100">
                        {passwordError}
                      </div>
                    )}

                    {passwordMessage && (
                      <div className="p-4 bg-green-50 text-green-700 text-sm rounded-2xl border border-green-100">
                        {passwordMessage}
                      </div>
                    )}

                    <Button type="submit" isLoading={isSavingPassword} className="rounded-2xl px-8 shadow-lg shadow-sky-50">
                      Update Password
                    </Button>
                  </form>
                </div>
              </section>

              {/* Danger Zone */}
              <section className="space-y-6 pt-6">
                <h2 className="text-sm font-black text-red-400 uppercase tracking-widest ml-1">Danger Zone</h2>
                <div className="bg-red-50 rounded-xl p-5 md:p-8 border border-red-100 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <h4 className="font-bold text-red-900">Sign Out</h4>
                    <p className="text-sm text-red-600/70">Sign out of your account on this device.</p>
                  </div>
                  <Button variant="danger" onClick={handleLogout} className="rounded-2xl px-8 shadow-lg shadow-red-100">
                    Logout
                  </Button>
                </div>
              </section>
            </>
          )}

          {activeTab === 'notifications' && (
            <>
              <header>
                <h1 className="text-3xl font-bold text-slate-800 tracking-tight">Notifications</h1>
                <p className="text-slate-500 mt-1">Configure how you receive updates and messages.</p>
              </header>
              <div className="bg-white rounded-xl p-8 md:p-12 border border-slate-100 text-center space-y-4">
                <div className="w-16 h-16 bg-slate-50 rounded-full flex items-center justify-center mx-auto text-2xl">🔔</div>
                <h3 className="text-xl font-bold text-slate-800">Notification settings coming soon</h3>
                <p className="text-slate-400 max-w-sm mx-auto">We are working on bringing desktop and email notifications to the platform.</p>
              </div>
            </>
          )}

          {activeTab === 'system' && (
            <>
              <header>
                <h1 className="text-3xl font-bold text-slate-800 tracking-tight">System</h1>
                <p className="text-slate-500 mt-1">Connection and session state for this browser.</p>
              </header>

              <section className="space-y-4">
                <SystemRow
                  label="Realtime connection"
                  value={connectionState}
                  badge={<StatusPill tone={connectionState === 'connected' ? 'success' : connectionState === 'idle' ? 'neutral' : 'warning'}>{connectionState}</StatusPill>}
                />
                <SystemRow label="API base URL" value={process.env.NEXT_PUBLIC_API_URL || 'Same origin'} />
                <SystemRow label="MQTT WebSocket endpoint" value={process.env.NEXT_PUBLIC_MQTT_WS_URL || 'Provided by realtime bootstrap'} />
                <SystemRow label="User ID" value={user.id} />
                <SystemRow label="Username" value={user.username} />
                <SystemRow label="Email" value={user.email} />
              </section>
            </>
          )}
        </div>
      </section>
    </AppLayout>
  )
}

function SystemRow({ label, value, badge }: { label: string; value: string; badge?: React.ReactNode }) {
  return (
    <div className="rounded-xl border border-slate-100 bg-slate-50 p-4">
      <div className="mb-2 flex items-center justify-between gap-3">
        <p className="text-xs font-black uppercase tracking-normal text-slate-400">{label}</p>
        {badge}
      </div>
      <p className="break-all font-mono text-sm text-slate-700">{value}</p>
    </div>
  )
}
