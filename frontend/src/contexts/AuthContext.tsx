'use client'

import React, { createContext, useContext, useState, useEffect, useCallback } from 'react'
import { AUTH_SESSION_EXPIRED_EVENT, authApi } from '@/lib/api'
import type { User } from '@/lib/types'

interface AuthContextType {
  user: User | null
  isLoading: boolean
  isAuthenticated: boolean
  login: (identifier: string, password: string) => Promise<void>
  register: (username: string, email: string, password: string) => Promise<void>
  logout: () => Promise<void>
  updateUser: (data: Partial<User>) => Promise<void>
  changePassword: (oldPassword: string, newPassword: string) => Promise<void>
  refreshToken: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [isLoading, setIsLoading] = useState(true)

  const loadUser = useCallback(async () => {
    try {
      const token = localStorage.getItem('access_token')
      if (!token) {
        setIsLoading(false)
        return
      }
      const userData = await authApi.getMe()
      setUser(userData)
    } catch (error) {
      localStorage.removeItem('access_token')
      localStorage.removeItem('refresh_token')
    } finally {
      setIsLoading(false)
    }
  }, [])

  useEffect(() => {
    loadUser()
  }, [loadUser])

  useEffect(() => {
    const handleSessionExpired = () => {
      setUser(null)
      setIsLoading(false)
    }

    window.addEventListener(AUTH_SESSION_EXPIRED_EVENT, handleSessionExpired)
    return () => {
      window.removeEventListener(AUTH_SESSION_EXPIRED_EVENT, handleSessionExpired)
    }
  }, [])

  const login = async (identifier: string, password: string) => {
    const tokens = await authApi.login({ identifier, password })
    localStorage.setItem('access_token', tokens.access_token)
    localStorage.setItem('refresh_token', tokens.refresh_token)
    await loadUser()
  }

  const register = async (username: string, email: string, password: string) => {
    const tokens = await authApi.register({ username, email, password })
    localStorage.setItem('access_token', tokens.access_token)
    localStorage.setItem('refresh_token', tokens.refresh_token)
    await loadUser()
  }

  const logout = async () => {
    try {
      await authApi.logout()
    } catch (error) {
      console.error('Logout error:', error)
    } finally {
      localStorage.removeItem('access_token')
      localStorage.removeItem('refresh_token')
      setUser(null)
    }
  }

  const updateUser = async (data: Partial<User>) => {
    const updated = await authApi.updateMe(data)
    setUser(updated)
  }

  const changePassword = async (oldPassword: string, newPassword: string) => {
    await authApi.changePassword({ old_password: oldPassword, new_password: newPassword })
  }

  const refreshToken = async () => {
    const storedRefreshToken = localStorage.getItem('refresh_token')
    if (!storedRefreshToken) {
      await logout()
      return
    }
    try {
      const tokens = await authApi.refresh({ refresh_token: storedRefreshToken })
      localStorage.setItem('access_token', tokens.access_token)
      localStorage.setItem('refresh_token', tokens.refresh_token)
    } catch (error) {
      await logout()
    }
  }

  return (
    <AuthContext.Provider
      value={{
        user,
        isLoading,
        isAuthenticated: !!user,
        login,
        register,
        logout,
        updateUser,
        changePassword,
        refreshToken,
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider')
  }
  return context
}
