'use client'

import React, { useState } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { useAuth } from '@/contexts/AuthContext'
import { Button } from '@/components/Button'
import { Input } from '@/components/Input'
import { BrandLogo } from '@/components/BrandLogo'

export default function RegisterPage() {
  const router = useRouter()
  const { register, isAuthenticated } = useAuth()
  const [username, setUsername] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [errors, setErrors] = useState<{
    username?: string
    email?: string
    password?: string
    confirmPassword?: string
    general?: string
  }>({})
  const [isLoading, setIsLoading] = useState(false)

  // Redirect if already authenticated
  React.useEffect(() => {
    if (isAuthenticated) {
      router.replace('/bots')
    }
  }, [isAuthenticated, router])

  const validate = () => {
    const newErrors: typeof errors = {}

    if (!username) {
      newErrors.username = 'Username is required'
    } else if (username.length < 3) {
      newErrors.username = 'Username must be at least 3 characters'
    } else if (!/^[a-zA-Z0-9_]+$/.test(username)) {
      newErrors.username = 'Username can only contain letters, numbers, and underscores'
    }

    if (!email) {
      newErrors.email = 'Email is required'
    } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      newErrors.email = 'Invalid email format'
    }

    if (!password) {
      newErrors.password = 'Password is required'
    } else if (password.length < 8) {
      newErrors.password = 'Password must be at least 8 characters'
    }

    if (!confirmPassword) {
      newErrors.confirmPassword = 'Please confirm your password'
    } else if (password !== confirmPassword) {
      newErrors.confirmPassword = 'Passwords do not match'
    }

    setErrors(newErrors)
    return Object.keys(newErrors).length === 0
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!validate()) return

    setIsLoading(true)
    setErrors({})

    try {
      await register(username, email, password)
      router.replace('/bots')
    } catch (error) {
      setErrors({ general: error instanceof Error ? error.message : 'Registration failed' })
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-slate-100 p-4 sm:p-6">
      <section className="w-full max-w-[440px] rounded-2xl border border-slate-200 bg-white/90 p-6 shadow-xl shadow-slate-200/60 backdrop-blur sm:p-8">
        <div className="mb-7 space-y-4 text-center">
          <BrandLogo size="lg" className="justify-center" />
          <div className="space-y-1">
            <h1 className="text-2xl font-black tracking-normal text-slate-900">Create account</h1>
            <p className="text-sm text-slate-500">Set up direct bot chat, groups, images, and realtime history.</p>
          </div>
        </div>

          <form onSubmit={handleSubmit} className="space-y-4">
            {errors.general && (
              <div className="min-h-[44px] rounded-xl border border-red-200 bg-red-50 p-3 text-sm font-medium text-red-700">
                {errors.general}
              </div>
            )}

            <Input
              type="text"
              label="Username"
              placeholder="johndoe"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              error={errors.username}
              autoComplete="username"
            />

            <Input
              type="email"
              label="Email"
              placeholder="you@example.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              error={errors.email}
              autoComplete="email"
            />

            <Input
              type="password"
              label="Password"
              placeholder="••••••••"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              error={errors.password}
              helperText="Use at least 8 characters."
              autoComplete="new-password"
            />

            <Input
              type="password"
              label="Confirm Password"
              placeholder="••••••••"
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
              error={errors.confirmPassword}
              autoComplete="new-password"
            />

            <Button type="submit" className="w-full rounded-xl" isLoading={isLoading}>
              Create account
            </Button>
          </form>

          <div className="mt-5 grid grid-cols-2 gap-2 text-xs font-bold text-slate-500">
            <span className="rounded-lg bg-slate-50 px-3 py-2">Bot direct chat</span>
            <span className="rounded-lg bg-slate-50 px-3 py-2">Group rooms</span>
            <span className="rounded-lg bg-slate-50 px-3 py-2">Image sharing</span>
            <span className="rounded-lg bg-slate-50 px-3 py-2">Realtime history</span>
          </div>

          <p className="mt-6 text-center text-sm text-slate-600">
            Already have an account?{' '}
            <Link href="/login" className="font-bold text-sky-600 hover:underline">
              Sign in
            </Link>
          </p>
      </section>
    </div>
  )
}
