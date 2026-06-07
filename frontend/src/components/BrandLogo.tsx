'use client'

interface BrandLogoProps {
  size?: 'sm' | 'md' | 'lg'
  showText?: boolean
  className?: string
}

const sizes = {
  sm: { box: 'w-9 h-9', text: 'text-lg' },
  md: { box: 'w-11 h-11', text: 'text-xl' },
  lg: { box: 'w-14 h-14', text: 'text-2xl' },
}

export function BrandLogo({ size = 'md', showText = true, className = '' }: BrandLogoProps) {
  const current = sizes[size]

  return (
    <div className={`inline-flex items-center gap-3 min-w-0 ${className}`}>
      <div className={`${current.box} flex shrink-0 items-center justify-center overflow-hidden rounded-xl bg-sky-500 shadow-sm ring-1 ring-slate-200`}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src="/lobster_icon.jpg"
          alt={showText ? '' : 'ClawChat'}
          aria-hidden={showText}
          width={1024}
          height={1024}
          className="h-full w-full scale-[1.42] object-cover"
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
