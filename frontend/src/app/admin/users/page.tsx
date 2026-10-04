'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { AppLayout } from '@/components/AppLayout'
import { LoadingPage } from '@/components/Loading'
import { useAuth } from '@/contexts/AuthContext'
import { adminApi } from '@/lib/api'
import type { AdminUser } from '@/lib/types'

function AccountRow({ account, ownAccount, onSaved }: { account: AdminUser; ownAccount: boolean; onSaved: (user: AdminUser) => void }) {
  const [role, setRole] = useState(account.role)
  const [status, setStatus] = useState(account.status)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [saved, setSaved] = useState(false)
  const changed = role !== account.role || status !== account.status
  async function save() {
    setSaving(true); setError(''); setSaved(false)
    try { onSaved(await adminApi.updateAccess(account.id, { role, status })); setSaved(true) }
    catch (error) { setError(error instanceof Error ? error.message : 'Could not update access') }
    finally { setSaving(false) }
  }
  return <tr className="border-b border-slate-200 dark:border-slate-800">
    <th scope="row" className="px-5 py-5 text-left font-normal">
      <span className="block font-semibold">{account.nickname || account.username}{ownAccount ? ' · You' : ''}</span>
      <span className="block text-sm text-slate-500">{account.username}</span>
      <span className="block text-xs text-slate-500">{account.email}</span>
    </th>
    <td className="p-3"><select aria-label={`Role for ${account.username}`} className="rounded-lg border border-slate-300 bg-transparent p-2 dark:border-slate-700" disabled={ownAccount || saving} value={role} onChange={e => { setRole(e.target.value as AdminUser['role']); setSaved(false) }}>
      <option value="user">User</option><option value="admin">Administrator</option>
    </select></td>
    <td className="p-3"><select aria-label={`Status for ${account.username}`} className="rounded-lg border border-slate-300 bg-transparent p-2 dark:border-slate-700" disabled={ownAccount || saving} value={status} onChange={e => { setStatus(Number(e.target.value) as AdminUser['status']); setSaved(false) }}>
      <option value={1}>Active</option><option value={0}>Inactive</option><option value={2}>Suspended</option>
    </select></td>
    <td className="min-w-36 p-3"><button disabled={ownAccount || saving || !changed} onClick={save} className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-35 dark:bg-slate-200 dark:text-slate-900" aria-label={`Save access for ${account.username}`}>{saving ? 'Saving…' : 'Save'}</button>
      {saved && !changed && <p role="status" className="mt-2 text-xs text-emerald-700 dark:text-emerald-400">Access updated</p>}
      {error && <p role="alert" className="mt-2 max-w-56 text-xs text-red-600">{error}</p>}
    </td>
  </tr>
}

export default function UserAccessPage() {
  const { user, isLoading: authLoading } = useAuth()
  const [accounts, setAccounts] = useState<AdminUser[]>([])
  const [search, setSearch] = useState('')
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(1)
  const [total, setTotal] = useState(0)
  const [more, setMore] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [reload, setReload] = useState(0)
  useEffect(() => {
    if (user?.role !== 'admin') return
    const controller = new AbortController()
    setLoading(true); setError('')
    adminApi.users(page, query, controller.signal).then(result => {
      setAccounts(result.data); setTotal(result.total); setMore(result.has_more)
    }).catch(error => {
      if (!controller.signal.aborted) setError(error instanceof Error ? error.message : 'Could not load accounts')
    }).finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [user?.role, page, query, reload])
  if (authLoading) return <LoadingPage />
  if (user?.role !== 'admin') return <AppLayout><div className="m-auto max-w-md p-8"><h1 className="text-2xl font-semibold">Administrator access required</h1><p className="my-4 text-slate-500">Only administrators can manage account access.</p><Link href={user ? '/bots' : '/login'} className="text-sky-600">{user ? 'Return to Agents' : 'Sign in'}</Link></div></AppLayout>
  return <AppLayout><div className="min-w-0 flex-1 overflow-y-auto bg-white p-5 text-slate-900 dark:bg-slate-950 dark:text-slate-100 md:p-10">
    <div className="mx-auto max-w-5xl">
      <p className="text-xs font-semibold uppercase tracking-widest text-slate-500">Workspace administration</p>
      <h1 className="mt-2 text-3xl font-semibold">Account access</h1>
      <p className="mt-3 max-w-2xl text-sm leading-6 text-slate-500">Manage roles and account status. Agents and conversations remain accessible to their owners and members. Suspending an account also blocks its Agent connections.</p>
      <form className="my-7 flex gap-3" onSubmit={e => { e.preventDefault(); setPage(1); setQuery(search.trim()) }}>
        <input aria-label="Search accounts" placeholder="Search username or email" value={search} onChange={e => setSearch(e.target.value)} className="min-w-0 flex-1 rounded-xl border border-slate-300 bg-transparent px-4 py-3 dark:border-slate-700" />
        <button className="rounded-xl border border-slate-300 px-4 text-sm dark:border-slate-700">Search</button>
      </form>
      {error ? <div role="alert" className="rounded-xl border border-red-200 p-5"><p>{error}</p><button onClick={() => setReload(x => x + 1)} className="mt-3 underline">Try again</button></div> : loading ? <p role="status">Loading accounts…</p> : <>
        <p className="mb-3 text-sm text-slate-500">{total} accounts · Page {page}</p>
        <div className="overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-800"><table className="w-full text-sm"><thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500 dark:bg-slate-900"><tr><th className="p-5">Account</th><th className="p-3">Role</th><th className="p-3">Status</th><th className="p-3">Access</th></tr></thead><tbody>
          {accounts.map(account => <AccountRow key={account.id} account={account} ownAccount={account.id === user.id} onSaved={updated => setAccounts(rows => rows.map(row => row.id === updated.id ? updated : row))} />)}
          {!accounts.length && <tr><td colSpan={4} className="p-8 text-center text-slate-500">No accounts found.</td></tr>}
        </tbody></table></div>
        <div className="mt-5 flex items-center justify-between gap-4"><p className="max-w-md text-xs text-slate-500">Ask another administrator to change your own role or status. Access changes are recorded in the audit log.</p><div className="flex gap-3"><button disabled={page === 1} onClick={() => setPage(p => p - 1)} className="rounded-lg border px-3 py-2 text-sm disabled:opacity-35">Previous</button><button disabled={!more} onClick={() => setPage(p => p + 1)} className="rounded-lg border px-3 py-2 text-sm disabled:opacity-35">Next</button></div></div>
      </>}
    </div>
  </div></AppLayout>
}
