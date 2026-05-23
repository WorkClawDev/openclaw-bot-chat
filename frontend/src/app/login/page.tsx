'use client'

import React, { useState } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { useAuth } from '@/contexts/AuthContext'
import { Button } from '@/components/Button'
import { Input } from '@/components/Input'
import { BrandLogo } from '@/components/BrandLogo'

export default function LoginPage() {
  const router = useRouter()
  const { login, isAuthenticated } = useAuth()
  const [identifier, setIdentifier] = useState('')
  const [password, setPassword] = useState('')
  const [errors, setErrors] = useState<{ identifier?: string; password?: string; general?: string }>({})
  const [isLoading, setIsLoading] = useState(false)

  // Redirect if already authenticated
  React.useEffect(() => {
    if (isAuthenticated) {
      router.replace('/bots')
    }
  }, [isAuthenticated, router])

  const validate = () => {
    const newErrors: typeof errors = {}
    if (!identifier.trim()) {
      newErrors.identifier = 'Email or username is required'
    }
    if (!password) {
      newErrors.password = 'Password is required'
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
      await login(identifier, password)
      router.replace('/bots')
    } catch (error) {
      setErrors({ general: error instanceof Error ? error.message : 'Login failed' })
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-slate-100 p-4 sm:p-6">
      <section className="w-full max-w-[420px] rounded-2xl border border-slate-200 bg-white/90 p-6 shadow-xl shadow-slate-200/60 backdrop-blur sm:p-8">
        <div className="mb-8 space-y-4 text-center">
          <BrandLogo size="lg" className="justify-center" />
          <div className="space-y-1">
            <h1 className="text-2xl font-black tracking-normal text-slate-900">Sign in</h1>
            <p className="text-sm text-slate-500">Return to realtime human and bot chat.</p>
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
              label="Email or Username"
              placeholder="you@example.com or johndoe"
              value={identifier}
              onChange={(e) => setIdentifier(e.target.value)}
              error={errors.identifier}
              autoComplete="username"
            />

            <Input
              type="password"
              label="Password"
              placeholder="••••••••"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              error={errors.password}
              autoComplete="current-password"
            />

            <Button type="submit" className="w-full rounded-xl" isLoading={isLoading}>
              Sign in
            </Button>
          </form>

          <p className="mt-6 text-center text-sm text-slate-600">
            Don&apos;t have an account?{' '}
            <Link href="/register" className="font-bold text-sky-600 hover:underline">
              Register
            </Link>
          </p>
      </section>
    </div>
  )
}
