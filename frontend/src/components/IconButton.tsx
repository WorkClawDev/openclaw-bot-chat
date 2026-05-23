'use client'

import React from 'react'

interface IconButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  label: string
  variant?: 'default' | 'primary' | 'danger' | 'ghost'
  size?: 'sm' | 'md' | 'lg'
  active?: boolean
}

export function IconButton({
  label,
  variant = 'default',
  size = 'md',
  active = false,
  className = '',
  children,
  ...props
}: IconButtonProps) {
  const sizes = {
    sm: 'h-8 w-8',
    md: 'h-10 w-10',
    lg: 'h-12 w-12',
  }

  const variants = {
    default: active
      ? 'bg-sky-50 text-sky-600 ring-sky-100'
      : 'bg-white text-slate-500 ring-slate-200 hover:bg-slate-50 hover:text-slate-800',
    primary: active
      ? 'bg-sky-600 text-white ring-sky-200'
      : 'bg-sky-500 text-white ring-sky-200 hover:bg-sky-600',
    danger: active
      ? 'bg-red-600 text-white ring-red-200'
      : 'bg-white text-red-500 ring-red-100 hover:bg-red-50',
    ghost: active
      ? 'bg-sky-50 text-sky-600 ring-sky-100'
      : 'bg-transparent text-slate-500 ring-transparent hover:bg-slate-100 hover:text-slate-800',
  }

  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      className={`${sizes[size]} inline-flex shrink-0 items-center justify-center rounded-xl ring-1 transition-all focus:outline-none focus-visible:ring-2 focus-visible:ring-sky-500 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 ${variants[variant]} ${className}`}
      {...props}
    >
      {children}
    </button>
  )
}
