import type { CSSProperties } from 'react'

export function AgentIcon({ name, size = 18, style }: { name: 'spark' | 'arrow' | 'back' | 'file' | 'check' | 'close'; size?: number; style?: CSSProperties }) {
  return <svg aria-hidden="true" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" style={{ flexShrink: 0, ...style }}>
    {name === 'spark' && <path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z" />}
    {name === 'arrow' && <path d="M6 18 18 6M6 6h12v12" />}
    {name === 'back' && <path d="M19 12H5m6-6-6 6 6 6" />}
    {name === 'file' && <><path d="M14 3H6a1 1 0 0 0-1 1v16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8l-5-5Z" /><path d="M14 3v5h5M9 13h6M9 17h4" /></>}
    {name === 'check' && <path d="m5 12 4 4L19 6" />}
    {name === 'close' && <path d="m6 6 12 12M6 18 18 6" />}
  </svg>
}
