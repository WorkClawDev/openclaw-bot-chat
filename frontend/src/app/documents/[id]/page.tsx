'use client'

import React, { useCallback, useEffect, useMemo, useState } from 'react'
import Link from 'next/link'
import { useParams } from 'next/navigation'
import { AppLayout } from '@/components/AppLayout'
import { LoadingPage } from '@/components/Loading'
import { Markdown } from '@/components/Markdown'
import { useAuth } from '@/contexts/AuthContext'
import { documentsApi } from '@/lib/api'
import type { DocumentObject } from '@/lib/types'
import {
  BASE_PREVIEW_ROWS,
  DocumentGlyph,
  StatusDot,
  buildContinuePrompt,
  buildDocumentMarkdown,
  documentDisplayBody,
  documentLead,
  documentSourceLabel,
  documentWordCount,
  formatDocumentDate,
  formatFullDocumentDate,
} from '../document-ui'

export default function DocumentDetailPage() {
  const params = useParams<{ id: string }>()
  const id = params.id
  const { isAuthenticated, isLoading: authLoading } = useAuth()
  const [doc, setDoc] = useState<DocumentObject | null>(null)
  const [title, setTitle] = useState('')
  const [body, setBody] = useState('')
  const [isEditing, setIsEditing] = useState(false)
  const [isLoading, setIsLoading] = useState(true)
  const [isSaving, setIsSaving] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  const load = useCallback(async () => {
    if (!id) return
    setIsLoading(true)
    setError('')
    try {
      const nextDoc = await documentsApi.get(id)
      setDoc(nextDoc)
      setTitle(nextDoc.title)
      setBody(nextDoc.body || '')
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load document')
    } finally {
      setIsLoading(false)
    }
  }, [id])

  useEffect(() => {
    if (!authLoading && !isAuthenticated) window.location.href = '/login'
  }, [authLoading, isAuthenticated])

  useEffect(() => {
    if (isAuthenticated) void load()
  }, [isAuthenticated, load])

  const hasUnsavedChanges = useMemo(() => {
    if (!doc) return false
    return title !== doc.title || body !== (doc.body || '')
  }, [body, doc, title])

  const save = async () => {
    if (!doc || !title.trim()) return
    setIsSaving(true)
    setError('')
    setNotice('')
    try {
      const updated = await documentsApi.update(doc.id, { title: title.trim(), body })
      setDoc(updated)
      setTitle(updated.title)
      setBody(updated.body || '')
      setIsEditing(false)
      setNotice('Saved')
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save document')
    } finally {
      setIsSaving(false)
    }
  }

  const cancelEdit = () => {
    if (!doc) return
    setTitle(doc.title)
    setBody(doc.body || '')
    setIsEditing(false)
    setError('')
    setNotice('Edits discarded')
  }

  const archive = async () => {
    if (!doc) return
    const confirmed = window.confirm(`Archive "${doc.title}"? It will be hidden from the default document list.`)
    if (!confirmed) return
    await documentsApi.archive(doc.id)
    window.location.href = '/documents'
  }

  const copyURL = async () => {
    if (!doc) return
    const absolute = new URL(doc.url, window.location.origin).toString()
    await navigator.clipboard.writeText(absolute)
    setNotice('URL copied')
  }

  const copyMarkdown = async () => {
    if (!doc) return
    await navigator.clipboard.writeText(buildDocumentMarkdown(doc, body))
    setNotice('Markdown copied')
  }

  const copyContinuePrompt = async () => {
    if (!doc) return
    const absolute = new URL(doc.url, window.location.origin).toString()
    await navigator.clipboard.writeText(buildContinuePrompt({ ...doc, url: absolute }))
    setNotice('Edit prompt copied')
  }

  if (authLoading) return <LoadingPage />
  if (!isAuthenticated) return null

  return (
    <AppLayout>
      <section className="flex h-full w-full flex-col bg-slate-50">
        <header className="shrink-0 border-b border-slate-200 bg-white/95 backdrop-blur">
          <div className="flex flex-col gap-3 px-5 py-3 lg:flex-row lg:items-center lg:justify-between">
            <div className="min-w-0">
              <Link href="/documents" className="inline-flex items-center gap-2 text-sm font-medium text-sky-700 hover:text-sky-800">
                <DocumentGlyph className="h-4 w-4" />
                Documents
              </Link>
              <div className="mt-1 flex min-w-0 flex-wrap items-center gap-2">
                <div className="truncate text-sm font-semibold text-slate-700">{doc?.title || 'Document'}</div>
                {doc ? <span className="rounded-full bg-slate-100 px-2 py-1 text-[11px] font-semibold uppercase text-slate-500">{doc.document_type}</span> : null}
                {hasUnsavedChanges ? (
                  <span className="inline-flex items-center gap-1 rounded-full bg-amber-50 px-2 py-1 text-[11px] font-semibold text-amber-700">
                    <StatusDot tone="amber" />
                    Unsaved
                  </span>
                ) : null}
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              {notice ? <span className="rounded-md bg-emerald-50 px-2.5 py-1.5 text-sm font-medium text-emerald-700">{notice}</span> : null}
              {isEditing ? (
                <>
                  <button onClick={cancelEdit} disabled={!doc || isSaving} className="h-10 rounded-md border border-slate-200 bg-white px-3 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:text-slate-300">
                    Cancel
                  </button>
                  <button onClick={() => void save()} disabled={!doc || isSaving || !title.trim() || !hasUnsavedChanges} className="h-10 rounded-md bg-sky-600 px-4 text-sm font-semibold text-white hover:bg-sky-700 disabled:cursor-not-allowed disabled:bg-slate-300">
                    {isSaving ? 'Saving...' : 'Save'}
                  </button>
                </>
              ) : (
                <>
                  <details className="relative">
                    <summary className="flex h-10 cursor-pointer list-none items-center rounded-md border border-slate-200 bg-white px-3 text-sm font-medium text-slate-700 hover:bg-slate-50">
                      More
                    </summary>
                    <div className="absolute right-0 z-20 mt-2 w-56 overflow-hidden rounded-md border border-slate-200 bg-white py-1 text-sm shadow-lg">
                      <button onClick={() => void copyURL()} disabled={!doc} className="block w-full px-3 py-2 text-left text-slate-700 hover:bg-slate-50 disabled:text-slate-300">
                        Copy URL
                      </button>
                      <button onClick={() => void copyMarkdown()} disabled={!doc} className="block w-full px-3 py-2 text-left text-slate-700 hover:bg-slate-50 disabled:text-slate-300">
                        Copy Markdown
                      </button>
                      <button onClick={() => void copyContinuePrompt()} disabled={!doc} className="block w-full px-3 py-2 text-left text-slate-700 hover:bg-slate-50 disabled:text-slate-300">
                        Copy edit prompt
                      </button>
                      <div className="my-1 border-t border-slate-100" />
                      <button disabled className="block w-full cursor-not-allowed px-3 py-2 text-left text-slate-400">
                        Share link soon
                      </button>
                      <button disabled className="block w-full cursor-not-allowed px-3 py-2 text-left text-slate-400">
                        Export PDF soon
                      </button>
                      <div className="my-1 border-t border-slate-100" />
                      <button onClick={() => void archive()} disabled={!doc} className="block w-full px-3 py-2 text-left text-red-600 hover:bg-red-50 disabled:text-slate-300">
                        Archive
                      </button>
                    </div>
                  </details>
                  <button onClick={() => setIsEditing(true)} disabled={!doc} className="h-10 rounded-md bg-sky-600 px-4 text-sm font-semibold text-white hover:bg-sky-700 disabled:bg-slate-300">
                    Edit
                  </button>
                </>
              )}
            </div>
          </div>
        </header>

        <main className="min-h-0 flex-1 overflow-y-auto p-4 md:p-5 scrollbar-thin">
          {isLoading ? (
            <div className="mx-auto max-w-5xl space-y-4">
              <div className="h-12 w-1/2 animate-pulse rounded-md bg-slate-200" />
              <div className="h-[70vh] animate-pulse rounded-md border border-slate-200 bg-white" />
            </div>
          ) : error && !doc ? (
            <div className="mx-auto max-w-3xl rounded-md border border-red-200 bg-red-50 p-5 text-sm text-red-700">
              <div className="font-semibold">Document unavailable</div>
              <p className="mt-1 leading-6">{error}</p>
              <div className="mt-4 flex gap-2">
                <button onClick={() => void load()} className="h-9 rounded-md bg-red-600 px-3 text-sm font-semibold text-white hover:bg-red-700">
                  Retry
                </button>
                <Link href="/documents" className="flex h-9 items-center rounded-md border border-red-200 px-3 text-sm font-medium text-red-700 hover:bg-red-100">
                  Back to documents
                </Link>
              </div>
            </div>
          ) : doc ? (
            <div className="mx-auto grid max-w-[1160px] gap-4 xl:grid-cols-[210px_minmax(0,760px)_240px]">
              <aside className="hidden xl:block">
                <div className="sticky top-0 space-y-3">
                  <div className="rounded-md border border-slate-100 bg-white/80 p-4 shadow-sm">
                    <div className="text-sm font-semibold text-slate-900">Outline</div>
                    <div className="mt-3 space-y-2 text-sm text-slate-500">
                      <div className="truncate rounded-md bg-slate-50 px-2 py-1.5 text-slate-700">{title || doc.title}</div>
                      <div className="truncate px-2 py-1.5">Body</div>
                      <div className="truncate px-2 py-1.5">Export</div>
                    </div>
                  </div>
                  <div className="rounded-md border border-slate-100 bg-white/80 p-4 shadow-sm">
                    <div className="text-sm font-semibold text-slate-900">Status</div>
                    <div className="mt-3 flex items-center gap-2 text-sm text-slate-600">
                      <StatusDot tone={hasUnsavedChanges ? 'amber' : 'emerald'} />
                      {hasUnsavedChanges ? 'Local edits' : 'Saved to backend'}
                    </div>
                  </div>
                </div>
              </aside>

              <section className="min-w-0">
                {isEditing ? (
                  <div className="space-y-4">
                    <div className="rounded-md border border-slate-100 bg-white shadow-sm">
                      <div className="flex flex-wrap items-center gap-1 border-b border-slate-200 px-4 py-2">
                        {['H1', 'H2', 'B', 'List', 'Code'].map((tool) => (
                          <button key={tool} type="button" disabled title={`${tool} formatting is coming later`} className="h-8 min-w-8 cursor-not-allowed rounded-md px-2 text-xs font-semibold text-slate-400">
                            {tool}
                          </button>
                        ))}
                        <span className="ml-auto text-xs text-slate-400">Markdown source editor</span>
                      </div>
                      <input
                        value={title}
                        onChange={(event) => setTitle(event.target.value)}
                        placeholder="Untitled document"
                        className="w-full border-0 bg-transparent px-8 pt-8 text-4xl font-semibold leading-tight text-slate-950 outline-none placeholder:text-slate-300"
                      />
                      <div className="grid min-h-[62vh] gap-0 lg:grid-cols-2">
                        <textarea
                          value={body}
                          onChange={(event) => setBody(event.target.value)}
                          placeholder="Write Markdown..."
                          className="min-h-[62vh] resize-none border-0 border-r-slate-200 bg-transparent px-8 py-6 font-mono text-sm leading-7 text-slate-700 outline-none placeholder:text-slate-400 lg:border-r"
                        />
                        <div className="max-h-[62vh] overflow-y-auto bg-slate-50 px-8 py-6 scrollbar-thin">
                          <div className="mb-3 text-xs font-semibold uppercase text-slate-400">Preview</div>
                          <Markdown content={body || '_This document is empty._'} />
                        </div>
                      </div>
                    </div>
                    {error ? <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</div> : null}
                  </div>
                ) : (
                  <article className="min-h-[76vh] rounded-md border border-slate-100 bg-white px-8 py-8 shadow-sm md:px-14 md:py-12">
                    <div className="mb-7 flex flex-wrap items-center gap-2 text-xs text-slate-500">
                      <span className="rounded-full bg-slate-100 px-2.5 py-1">{documentSourceLabel(doc)}</span>
                      <span className="rounded-full bg-sky-50 px-2.5 py-1 text-sky-700">{doc.document_type.toUpperCase()}</span>
                      <span>Updated {formatFullDocumentDate(doc.updated_at)}</span>
                    </div>
                    <h2 className="max-w-4xl text-4xl font-semibold leading-tight text-slate-950">{doc.title}</h2>
                    {documentLead(doc) ? <p className="mt-4 max-w-3xl text-base leading-7 text-slate-500">{documentLead(doc)}</p> : null}
                    <div className="my-8 border-t border-slate-200" />
                    <Markdown content={documentDisplayBody(doc) || '_This document is empty. Click Edit to add content._'} />
                  </article>
                )}
              </section>

              <aside className="space-y-3">
                <div className="rounded-md border border-slate-100 bg-white/80 p-4 shadow-sm">
                  <div className="text-sm font-semibold text-slate-900">Properties</div>
                  <dl className="mt-3 space-y-3 text-sm">
                    <div className="flex justify-between gap-4">
                      <dt className="text-slate-500">Words</dt>
                      <dd className="font-medium text-slate-900">{documentWordCount(body || doc.body)}</dd>
                    </div>
                    <div className="flex justify-between gap-4">
                      <dt className="text-slate-500">Source</dt>
                      <dd className="font-medium text-slate-900">{documentSourceLabel(doc)}</dd>
                    </div>
                    <div className="flex justify-between gap-4">
                      <dt className="text-slate-500">Updated</dt>
                      <dd className="font-medium text-slate-900">{formatDocumentDate(doc.updated_at)}</dd>
                    </div>
                  </dl>
                </div>

                <div className="rounded-md border border-slate-100 bg-white/80 p-4 shadow-sm">
                  <div className="flex items-center justify-between gap-3">
                    <div>
                      <div className="text-sm font-semibold text-slate-900">Base preview</div>
                      <p className="mt-1 text-xs leading-5 text-slate-500">Future structured-data document views.</p>
                    </div>
                    <span className="rounded-full bg-amber-50 px-2 py-1 text-[11px] font-semibold text-amber-700">Soon</span>
                  </div>
                  <div className="mt-3 overflow-hidden rounded-md border border-slate-200">
                    {BASE_PREVIEW_ROWS.map((row) => (
                      <div key={row.task} className="grid grid-cols-[1fr_56px] border-b border-slate-100 px-3 py-2 text-xs last:border-b-0">
                        <span className="font-medium text-slate-700">{row.task}</span>
                        <span className="text-slate-500">{row.status}</span>
                      </div>
                    ))}
                  </div>
                </div>
              </aside>
            </div>
          ) : null}
        </main>
      </section>
    </AppLayout>
  )
}
