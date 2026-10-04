'use client'

import ReactMarkdown from 'react-markdown'
import { memo } from 'react'
import remarkGfm from 'remark-gfm'
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter'
import { vscDarkPlus } from 'react-syntax-highlighter/dist/cjs/styles/prism'

interface MarkdownProps {
  content: string
  className?: string
  isOwn?: boolean
}

export const Markdown = memo(function Markdown({ content, className = '', isOwn = false }: MarkdownProps) {
  return (
    <div className={`markdown-body ${className}`}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          code({ node, inline, className, children, ...props }: any) {
            const match = /language-(\w+)/.exec(className || '')
            return !inline && match ? (
              <SyntaxHighlighter
                {...props}
                style={vscDarkPlus}
                language={match[1]}
                PreTag="div"
              >
                {String(children).replace(/\n$/, '')}
              </SyntaxHighlighter>
            ) : (
              <code className={className} {...props}>
                {children}
              </code>
            )
          },
          // Customizing other elements to match the design
          table({ children }) {
            return (
              <div className="overflow-x-auto my-4">
                <table className="min-w-full divide-y divide-slate-200 border border-slate-200">
                  {children}
                </table>
              </div>
            )
          },
          thead({ children }) {
            return <thead className="bg-slate-50">{children}</thead>
          },
          th({ children }) {
            return (
              <th className="px-3 py-2 text-left text-xs font-semibold text-slate-700 uppercase tracking-wider border-b border-r border-slate-200 last:border-r-0">
                {children}
              </th>
            )
          },
          td({ children }) {
            return (
              <td className="px-3 py-2 text-sm text-slate-600 border-b border-r border-slate-200 last:border-r-0">
                {children}
              </td>
            )
          },
          blockquote({ children }) {
            return (
              <blockquote className={`border-l-4 pl-4 py-1 my-4 italic ${isOwn ? 'border-white/50 text-white/90' : 'border-slate-300 text-slate-600'}`}>
                {children}
              </blockquote>
            )
          },
          ul({ children }) {
            return <ul className="list-disc list-inside my-4 space-y-1">{children}</ul>
          },
          ol({ children }) {
            return <ol className="list-decimal list-inside my-4 space-y-1">{children}</ol>
          },
          a({ children, href }) {
            if (href?.startsWith('mention://')) {
              if (isOwn) {
                return (
                  <span className="inline-block px-1.5 py-0.5 mx-0.5 bg-white/20 text-white font-bold rounded-md shadow-sm border border-white/30 no-underline">
                    {children}
                  </span>
                )
              }
              return (
                <span className="inline-block px-1.5 py-0.5 mx-0.5 bg-indigo-100 text-indigo-700 font-bold rounded-md shadow-sm border border-indigo-200 no-underline">
                  {children}
                </span>
              )
            }
            return (
              <a href={href} className={`${isOwn ? 'text-white underline hover:text-white/80' : 'text-primary-600 hover:underline'}`} target="_blank" rel="noopener noreferrer">
                {children}
              </a>
            )
          },
          h1({ children }) {
            return <h1 className="text-2xl font-bold my-4">{children}</h1>
          },
          h2({ children }) {
            return <h2 className="text-xl font-bold my-4">{children}</h2>
          },
          h3({ children }) {
            return <h3 className="text-lg font-bold my-4">{children}</h3>
          },
          p({ children }) {
            return <p className="mb-4 last:mb-0 text-[15px] leading-relaxed break-words">{children}</p>
          },
          li({ children }) {
            return <li className="mb-1 last:mb-0">{children}</li>
          },
        }}
      >
        {content}
      </ReactMarkdown>
    </div>
  )
})
