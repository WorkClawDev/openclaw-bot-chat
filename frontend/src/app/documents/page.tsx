'use client'

import React, { useCallback, useEffect, useMemo, useState } from 'react'
import Link from 'next/link'
import { AppLayout } from '@/components/AppLayout'
import { LoadingPage } from '@/components/Loading'
import { Markdown } from '@/components/Markdown'
import { useAuth } from '@/contexts/AuthContext'
import { documentsApi } from '@/lib/api'
import type { DocumentObject } from '@/lib/types'
import {
  BASE_PREVIEW_ROWS,
  DocumentGlyph,
  EMPTY_DOCUMENT_TEMPLATE,
  SearchGlyph,
  StatusDot,
  documentDisplayBody,
  documentExcerpt,
  documentLead,
  documentSourceLabel,
  documentWordCount,
  formatDocumentDate,
  formatFullDocumentDate,
} from './document-ui'

export default function DocumentsPage() {
  const { isAuthenticated, isLoading: authLoading } = useAuth()
  const [documents, setDocuments] = useState<DocumentObject[]>([])
  const [selectedDocumentDetail, setSelectedDocumentDetail] = useState<DocumentObject | null>(null)
  const [selectedId, setSelectedId] = useState('')
  const [query, setQuery] = useState('')
  const [isLoading, setIsLoading] = useState(true)
  const [isLoadingDetail, setIsLoadingDetail] = useState(false)
  const [isCreating, setIsCreating] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [title, setTitle] = useState('')
  const [body, setBody] = useState(EMPTY_DOCUMENT_TEMPLATE)

  const refresh = useCallback(async () => {
    setIsLoading(true)
    setError('')
    try {
      const nextDocuments = await documentsApi.list()
      setDocuments(nextDocuments)
      setSelectedDocumentDetail(null)
      setSelectedId((current) => {
        if (current && nextDocuments.some((doc) => doc.id === current)) return current
        return nextDocuments[0]?.id || ''
      })
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load documents')
    } finally {
      setIsLoading(false)
    }
  }, [])

  useEffect(() => {
    if (!authLoading && !isAuthenticated) window.location.href = '/login'
  }, [authLoading, isAuthenticated])

  useEffect(() => {
    if (isAuthenticated) void refresh()
  }, [isAuthenticated, refresh])

  const filteredDocuments = useMemo(() => {
    const normalized = query.trim().toLowerCase()
    if (!normalized) return documents
    return documents.filter((doc) =>
      [doc.title, doc.summary, doc.body, doc.source].some((value) => value?.toLowerCase().includes(normalized))
    )
  }, [documents, query])

  const selectedDocument = useMemo(() => {
    if (isCreating) return null
    const listDocument = filteredDocuments.find((doc) => doc.id === selectedId) || filteredDocuments[0] || null
    if (selectedDocumentDetail?.id === listDocument?.id) return selectedDocumentDetail
    return listDocument
  }, [filteredDocuments, isCreating, selectedDocumentDetail, selectedId])

  const startCreate = () => {
    setIsCreating(true)
    setSelectedDocumentDetail(null)
    setSelectedId('')
    setNotice('')
    setError('')
    setTitle('')
    setBody(EMPTY_DOCUMENT_TEMPLATE)
  }

  useEffect(() => {
    if (isCreating || !selectedDocument?.id) {
      setSelectedDocumentDetail(null)
      return
    }
    if (selectedDocumentDetail?.id === selectedDocument.id && selectedDocumentDetail.body !== undefined) return

    let isMounted = true
    setIsLoadingDetail(true)
    documentsApi
      .get(selectedDocument.id)
      .then((detail) => {
        if (!isMounted) return
        setSelectedDocumentDetail(detail)
      })
      .catch((err) => {
        if (!isMounted) return
        setError(err instanceof Error ? err.message : 'Failed to load document detail')
      })
      .finally(() => {
        if (isMounted) setIsLoadingDetail(false)
      })

    return () => {
      isMounted = false
    }
  }, [isCreating, selectedDocument?.id, selectedDocumentDetail?.body, selectedDocumentDetail?.id])

  const createDocument = async (event: React.FormEvent) => {
    event.preventDefault()
    if (!title.trim()) return
    setIsSubmitting(true)
    setError('')
    setNotice('')
    try {
      const created = await documentsApi.create({ title: title.trim(), body })
      setDocuments((current) => [created, ...current.filter((doc) => doc.id !== created.id)])
      setSelectedId(created.id)
      setIsCreating(false)
      setTitle('')
      setBody(EMPTY_DOCUMENT_TEMPLATE)
      setNotice('Document created')
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create document')
    } finally {
      setIsSubmitting(false)
    }
  }

  if (authLoading) return <LoadingPage />
  if (!isAuthenticated) return null

  return (
    <AppLayout>
      <section className="flex h-full w-full flex-col bg-slate-50">
        <header className="flex shrink-0 flex-col gap-4 border-b border-slate-200 bg-white/95 px-5 py-4 backdrop-blur md:flex-row md:items-center md:justify-between">
          <div className="min-w-0">
            <div className="flex items-center gap-2 text-xs font-semibold uppercase text-sky-600">
              <DocumentGlyph className="h-4 w-4" />
              Documents
            </div>
            <h1 className="mt-1 text-2xl font-semibold text-slate-950">Document workspace</h1>
            <p className="mt-1 max-w-2xl text-sm text-slate-500">
              Persistent Markdown documents for long bot output, drafts, and follow-up editing.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            {notice ? <span className="rounded-md bg-emerald-50 px-2.5 py-1.5 text-sm font-medium text-emerald-700">{notice}</span> : null}
            <button
              onClick={() => void refresh()}
              className="h-10 rounded-md border border-slate-200 bg-white px-3 text-sm font-medium text-slate-700 hover:bg-slate-50"
            >
              Refresh
            </button>
            <button
              onClick={startCreate}
              className="h-10 rounded-md bg-sky-600 px-3.5 text-sm font-semibold text-white hover:bg-sky-700"
            >
              New document
            </button>
          </div>
        </header>

        <main className="grid min-h-0 flex-1 grid-cols-1 md:grid-cols-[392px_minmax(0,1fr)]">
          <aside className="flex min-h-0 flex-col border-r border-slate-200 bg-white/90">
            <div className="border-b border-slate-200 p-4">
              <label className="relative block">
                <SearchGlyph className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
                <input
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  placeholder="Search documents locally"
                  className="h-10 w-full rounded-md border border-slate-200 bg-slate-50 pl-9 pr-3 text-sm outline-none focus:border-sky-400 focus:bg-white"
                />
              </label>
            </div>

            <div className="min-h-0 flex-1 overflow-y-auto p-3 scrollbar-thin">
              {isLoading ? (
                <div className="space-y-2">
                  {[0, 1, 2].map((item) => (
                    <div key={item} className="h-28 animate-pulse rounded-md border border-slate-200 bg-slate-100" />
                  ))}
                </div>
              ) : error ? (
                <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
                  <div className="font-semibold">Could not load documents</div>
                  <div className="mt-1">{error}</div>
                  <button onClick={() => void refresh()} className="mt-3 text-sm font-semibold text-red-700 underline">
                    Retry
                  </button>
                </div>
              ) : filteredDocuments.length === 0 ? (
                <div className="rounded-md border border-dashed border-slate-300 bg-slate-50 p-5 text-center">
                  <DocumentGlyph className="mx-auto h-8 w-8 text-slate-400" />
                  <div className="mt-3 text-sm font-semibold text-slate-800">{query ? 'No local matches' : 'No documents yet'}</div>
                  <p className="mt-1 text-xs leading-5 text-slate-500">
                    {query ? 'Search currently filters the loaded list on this device.' : 'Create a document or ask a bot to generate one.'}
                  </p>
                </div>
              ) : (
                <div className="space-y-2">
                  {filteredDocuments.map((doc) => {
                    const isSelected = selectedDocument?.id === doc.id
                    return (
                      <button
                        key={doc.id}
                        type="button"
                        onClick={() => {
                          setIsCreating(false)
                          setSelectedId(doc.id)
                          setSelectedDocumentDetail(null)
                          setNotice('')
                        }}
                        className={`w-full rounded-md border p-3 text-left transition ${
                          isSelected
                            ? 'border-sky-300 bg-sky-50 shadow-sm ring-1 ring-sky-100'
                            : 'border-slate-200 bg-white hover:border-slate-300 hover:bg-slate-50'
                        }`}
                      >
                        <div className="flex items-start justify-between gap-3">
                          <div className="min-w-0">
                            <div className="line-clamp-2 text-sm font-semibold text-slate-950">{doc.title}</div>
                            <div className="mt-1 line-clamp-2 text-xs leading-5 text-slate-500">{documentExcerpt(doc)}</div>
                          </div>
                          <StatusDot tone={doc.source === 'bot' ? 'emerald' : 'sky'} />
                        </div>
                        <div className="mt-3 flex items-center justify-between gap-2 text-[11px] uppercase text-slate-400">
                          <span>{doc.source === 'bot' ? 'Bot' : 'User'}</span>
                          <span>{formatDocumentDate(doc.updated_at)}</span>
                        </div>
                      </button>
                    )
                  })}
                </div>
              )}
            </div>
          </aside>

          <section className="min-h-0 overflow-y-auto bg-slate-50 p-4 md:p-6 scrollbar-thin">
            {isCreating ? (
              <form onSubmit={createDocument} className="mx-auto flex max-w-5xl flex-col gap-4">
                <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
                  <div>
                    <div className="text-sm font-semibold text-sky-700">New Markdown document</div>
                    <h2 className="text-2xl font-semibold text-slate-950">Start with a clean page</h2>
                  </div>
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      onClick={() => {
                        setIsCreating(false)
                        setError('')
                      }}
                      className="h-10 rounded-md border border-slate-200 bg-white px-3 text-sm font-medium text-slate-700 hover:bg-slate-50"
                    >
                      Cancel
                    </button>
                    <button
                      type="submit"
                      disabled={isSubmitting || !title.trim()}
                      className="h-10 rounded-md bg-sky-600 px-4 text-sm font-semibold text-white hover:bg-sky-700 disabled:cursor-not-allowed disabled:bg-slate-300"
                    >
                      {isSubmitting ? 'Creating...' : 'Create'}
                    </button>
                  </div>
                </div>

                <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
                  <div className="min-h-[70vh] rounded-md border border-slate-200 bg-white shadow-sm">
                    <input
                      value={title}
                      onChange={(event) => setTitle(event.target.value)}
                      placeholder="Untitled document"
                      className="w-full border-0 bg-transparent px-8 pt-8 text-3xl font-semibold text-slate-950 outline-none placeholder:text-slate-300"
                    />
                    <textarea
                      value={body}
                      onChange={(event) => setBody(event.target.value)}
                      placeholder="Write Markdown..."
                      className="min-h-[58vh] w-full resize-none border-0 bg-transparent px-8 py-6 font-mono text-sm leading-7 text-slate-700 outline-none placeholder:text-slate-400"
                    />
                  </div>

                  <aside className="space-y-3">
                    <div className="rounded-md border border-slate-200 bg-white p-4 shadow-sm">
                      <div className="text-sm font-semibold text-slate-900">Live preview</div>
                      <div className="mt-3 max-h-[42vh] overflow-y-auto rounded-md border border-slate-100 bg-slate-50 p-4 scrollbar-thin">
                        <Markdown content={body || '_This document is empty._'} />
                      </div>
                    </div>
                    <div className="rounded-md border border-amber-200 bg-amber-50 p-4 text-sm text-amber-700">
                      <div className="font-semibold">MVP editor</div>
                      <p className="mt-1 leading-6">This editor saves the full Markdown body. Block editing and realtime collaboration are planned for a later version.</p>
                    </div>
                    {error ? <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</div> : null}
                  </aside>
                </div>
              </form>
            ) : selectedDocument ? (
              <div className="mx-auto grid max-w-6xl gap-4 lg:grid-cols-[minmax(0,1fr)_320px]">
                <article className="min-h-[72vh] rounded-md border border-slate-200 bg-white px-8 py-8 shadow-sm md:px-12">
                  <div className="mb-8 flex flex-wrap items-center gap-2 text-xs text-slate-500">
                    <span className="rounded-full bg-slate-100 px-2.5 py-1">{documentSourceLabel(selectedDocument)}</span>
                    <span className="rounded-full bg-sky-50 px-2.5 py-1 text-sky-700">{selectedDocument.document_type.toUpperCase()}</span>
                    <span>Updated {formatFullDocumentDate(selectedDocument.updated_at)}</span>
                    <Link href={selectedDocument.url} className="ml-auto font-semibold text-sky-700 hover:text-sky-800">
                      Open full document
                    </Link>
                  </div>
                  <h2 className="max-w-3xl text-4xl font-semibold leading-tight text-slate-950">{selectedDocument.title}</h2>
                  <p className="mt-4 max-w-3xl text-base leading-7 text-slate-500">{documentLead(selectedDocument) || 'No summary yet'}</p>
                  <div className="my-8 border-t border-slate-200" />
                  {isLoadingDetail ? (
                    <div className="space-y-3">
                      <div className="h-4 w-5/6 animate-pulse rounded bg-slate-100" />
                      <div className="h-4 w-3/4 animate-pulse rounded bg-slate-100" />
                      <div className="h-4 w-2/3 animate-pulse rounded bg-slate-100" />
                    </div>
                  ) : (
                    <Markdown content={documentDisplayBody(selectedDocument) || '_This document is empty. Open the document to add content._'} />
                  )}
                </article>

                <aside className="space-y-3">
                  <div className="rounded-md border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="text-sm font-semibold text-slate-900">Document info</div>
                    <dl className="mt-3 space-y-3 text-sm">
                      <div className="flex justify-between gap-4">
                        <dt className="text-slate-500">Words</dt>
                        <dd className="font-medium text-slate-900">{documentWordCount(selectedDocument.body)}</dd>
                      </div>
                      <div className="flex justify-between gap-4">
                        <dt className="text-slate-500">Source</dt>
                        <dd className="font-medium text-slate-900">{documentSourceLabel(selectedDocument)}</dd>
                      </div>
                      <div className="flex justify-between gap-4">
                        <dt className="text-slate-500">Updated</dt>
                        <dd className="font-medium text-slate-900">{formatDocumentDate(selectedDocument.updated_at)}</dd>
                      </div>
                    </dl>
                  </div>

                  <div className="rounded-md border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="flex items-center justify-between gap-3">
                      <div>
                        <div className="text-sm font-semibold text-slate-900">Base preview</div>
                        <p className="mt-1 text-xs leading-5 text-slate-500">Structured table, board, and calendar views are planned.</p>
                      </div>
                      <span className="rounded-full bg-amber-50 px-2 py-1 text-[11px] font-semibold text-amber-700">Soon</span>
                    </div>
                    <div className="mt-3 overflow-hidden rounded-md border border-slate-200">
                      {BASE_PREVIEW_ROWS.map((row) => (
                        <div key={row.task} className="grid grid-cols-[1fr_64px] border-b border-slate-100 px-3 py-2 text-xs last:border-b-0">
                          <span className="font-medium text-slate-700">{row.task}</span>
                          <span className="text-slate-500">{row.status}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                </aside>
              </div>
            ) : (
              <div className="mx-auto flex min-h-[70vh] max-w-3xl flex-col items-center justify-center text-center">
                <DocumentGlyph className="h-12 w-12 text-slate-400" />
                <h2 className="mt-4 text-2xl font-semibold text-slate-950">Build your document library</h2>
                <p className="mt-2 max-w-xl text-sm leading-6 text-slate-500">
                  Create a Markdown document here, or let a bot create one through the runtime API. Chat messages should share the document URL, while this workspace keeps the durable document object.
                </p>
                <button onClick={startCreate} className="mt-5 h-10 rounded-md bg-sky-600 px-4 text-sm font-semibold text-white hover:bg-sky-700">
                  New document
                </button>
              </div>
            )}
          </section>
        </main>
      </section>
    </AppLayout>
  )
}
