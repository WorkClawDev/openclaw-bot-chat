'use client'

import React from 'react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useAuth } from '@/contexts/AuthContext'
import { BrandLogo } from './BrandLogo'

const navItems = [
  { href: '/bots', label: 'Agents', icon: 'bot' },
  { href: '/groups', label: 'Groups', icon: 'users' },
  { href: '/documents', label: 'Documents', icon: 'documents' },
  { href: '/assistant', label: 'Assistant', icon: 'tasks' },
  { href: '/tasks', label: 'Tasks', icon: 'tasks' },
  { href: '/settings', label: 'Settings', icon: 'settings' },
]

function NavIcon({ type }: { type: string }) {
  switch (type) {
    case 'bot':
      return (
        <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
        </svg>
      )
    case 'users':
      return (
        <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z" />
        </svg>
      )
    case 'settings':
      return (
        <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
        </svg>
      )
    case 'tasks':
      return (
        <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5h10M9 12h10M9 19h10M5 5h.01M5 12h.01M5 19h.01" />
        </svg>
      )
    case 'documents':
      return (
        <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 3h7l5 5v13a2 2 0 01-2 2H7a2 2 0 01-2-2V5a2 2 0 012-2z" />
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M14 3v6h5M8 13h8M8 17h6" />
        </svg>
      )
    default:
      return null
  }
}

export function PrimaryNav() {
  const pathname = usePathname()
  const { user, logout } = useAuth()

  return (
    <aside className="primary-nav w-full md:w-[72px] flex flex-row md:flex-col items-center md:py-5 border-t md:border-t-0 md:border-r border-slate-200/70 z-40 shrink-0">
      <Link href="/bots" className="hidden md:block rounded-xl focus:outline-none focus-visible:ring-2 focus-visible:ring-sky-500 focus-visible:ring-offset-2" aria-label="ClawChat home">
        <BrandLogo showText={false} size="sm" />
      </Link>

      {/* Navigation */}
      <nav aria-label="Workspace navigation" className="flex min-w-0 flex-1 flex-row md:flex-col items-center justify-around md:justify-start">
        {navItems.map((item) => {
          const isActive = pathname === item.href || pathname.startsWith(item.href + '/')
          return (
            <Link
              key={item.href}
              href={item.href}
              title={item.label}
              aria-label={item.label}
              aria-current={isActive ? 'page' : undefined}
              className={`primary-nav-link flex flex-col items-center justify-center rounded-xl transition-colors duration-150 focus:outline-none focus-visible:ring-2 focus-visible:ring-sky-500 ${
                isActive
                  ? 'is-active'
                  : 'text-slate-500 hover:bg-slate-100 hover:text-sky-600'
              }`}
            >
              <NavIcon type={item.icon} />
              <span className="mt-1 text-[9px] font-medium">{item.label}</span>
            </Link>
          )
        })}
      </nav>

      {/* User / Bottom */}
      <div className="hidden md:flex flex-col gap-4 items-center">
        <Link href="/settings" className="primary-nav-account" title={user?.username || 'Account'} aria-label={`Account settings for ${user?.username || 'your account'}`}>
          <span>Account</span>
          <strong>{user?.username || 'Settings'}</strong>
        </Link>
        <button
          onClick={logout}
          className="w-10 h-10 flex items-center justify-center rounded-xl text-slate-400 hover:bg-red-50 hover:text-red-500 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-red-500 focus-visible:ring-offset-2"
          title="Logout"
          aria-label="Logout"
        >
          <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1" />
          </svg>
        </button>
      </div>
    </aside>
  )
}

export function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex flex-col-reverse md:flex-row h-[100dvh] w-full overflow-hidden bg-slate-100">
      <PrimaryNav />
      <main className="flex min-h-0 min-w-0 flex-1 overflow-hidden relative">
        {children}
      </main>
    </div>
  )
}
