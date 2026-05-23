'use client'

interface BrandLogoProps {
  size?: 'sm' | 'md' | 'lg'
  showText?: boolean
  className?: string
}

const sizes = {
  sm: { box: 'w-9 h-9', image: 28, text: 'text-lg' },
  md: { box: 'w-11 h-11', image: 34, text: 'text-xl' },
  lg: { box: 'w-14 h-14', image: 44, text: 'text-2xl' },
}

export function BrandLogo({ size = 'md', showText = true, className = '' }: BrandLogoProps) {
  const current = sizes[size]

  return (
    <div className={`inline-flex items-center gap-3 min-w-0 ${className}`}>
      <div className={`${current.box} flex shrink-0 items-center justify-center rounded-xl bg-white shadow-sm ring-1 ring-slate-200`}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src="/lobster_icon.jpg"
          alt={showText ? '' : 'ClawChat'}
          aria-hidden={showText}
          width={current.image}
          height={current.image}
          className="h-auto w-auto"
        />
      </div>
      {showText && (
        <span className={`${current.text} min-w-0 truncate font-black tracking-normal text-slate-900`}>
          ClawChat
        </span>
      )}
    </div>
  )
}
