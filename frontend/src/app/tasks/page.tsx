'use client'

import React, { useCallback, useEffect, useMemo, useState } from 'react'
import Link from 'next/link'
import { AppLayout } from '@/components/AppLayout'
import { useAuth } from '@/contexts/AuthContext'
import { botsApi, tasksApi } from '@/lib/api'
import type { Bot, Task, TaskPriority, TaskStatus } from '@/lib/types'

const WEEK_MS = 7 * 24 * 60 * 60 * 1000
const GROUP_HEIGHT = 36
const TASK_HEIGHT = 38
const VISIBLE_WEEKS = 14
const AVATAR_COLORS = ['#0875df', '#8b5cf6', '#10a878', '#f97316', '#ef5a74']

type IconName =
  | 'bell'
  | 'chevron'
  | 'clipboard'
  | 'filter'
  | 'plus'
  | 'refresh'
  | 'search'
  | 'settings'
  | 'target'
  | 'trend'
  | 'x'

type ZoomMode = 'day' | 'week' | 'month'
type TaskFilter = 'all' | 'active' | 'completed' | 'blocked'
type TaskView = 'board' | 'timeline' | 'list' | 'calendar'

interface ProjectGroup {
  id: 'planning' | 'design' | 'qa' | 'launch'
  label: string
  color: string
  soft: string
}

interface TimelineRow {
  key: string
  kind: 'group' | 'task'
  top: number
  height: number
  group: ProjectGroup
  task?: Task
  taskNumber?: number
}

const PROJECT_GROUPS: ProjectGroup[] = [
  { id: 'planning', label: 'Planning', color: '#1682f0', soft: '#dbeafe' },
  { id: 'design', label: 'Design & Dev', color: '#8b5cf6', soft: '#ede9fe' },
  { id: 'qa', label: 'Testing & QA', color: '#20ae83', soft: '#d1fae5' },
  { id: 'launch', label: 'Launch', color: '#f97316', soft: '#ffedd5' },
]

export default function TasksPage() {
  const { isAuthenticated, isLoading: authLoading } = useAuth()
  const [tasks, setTasks] = useState<Task[]>([])
  const [bots, setBots] = useState<Bot[]>([])
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null)
  const [showCreate, setShowCreate] = useState(false)
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState('')
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<TaskFilter>('all')
  const [zoom, setZoom] = useState<ZoomMode>('week')
  const [view, setView] = useState<TaskView>('timeline')
  const [showNotifications, setShowNotifications] = useState(false)
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null)

  const refresh = useCallback(async (showLoading = true, includeBots = true) => {
    if (showLoading) setIsLoading(true)
    setError('')
    try {
      const [taskData, botData] = await Promise.all([
        tasksApi.list(),
        includeBots ? botsApi.list() : Promise.resolve(null),
      ])
      setTasks(taskData)
      if (botData) setBots(botData)
      setLastUpdated(new Date())
      setSelectedTaskId((current) =>
        current && taskData.some((task) => task.id === current) ? current : null
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load tasks')
    } finally {
      if (showLoading) setIsLoading(false)
    }
  }, [])

  useEffect(() => {
    if (!authLoading && !isAuthenticated) window.location.href = '/login'
  }, [authLoading, isAuthenticated])

  useEffect(() => {
    if (isAuthenticated) void refresh()
  }, [isAuthenticated, refresh])

  useEffect(() => {
    if (!isAuthenticated) return
    const interval = window.setInterval(() => void refresh(false, false), 5000)
    return () => window.clearInterval(interval)
  }, [isAuthenticated, refresh])

  const filteredTasks = useMemo(
    () =>
      tasks.filter((task) => {
        const matchesQuery = `${task.title} ${task.description || ''}`.toLowerCase().includes(query.toLowerCase())
        if (!matchesQuery) return false
        if (filter === 'completed') return task.status === 'completed'
        if (filter === 'blocked') return task.status === 'blocked' || task.status === 'failed'
        if (filter === 'active') return !['completed', 'failed'].includes(task.status)
        return true
      }),
    [filter, query, tasks]
  )
  const selectedTask = tasks.find((task) => task.id === selectedTaskId) || null
  const averageProgress = tasks.length
    ? Math.round(tasks.reduce((sum, task) => sum + task.progress, 0) / tasks.length)
    : 0
  const onTrack = tasks.filter((task) => !['blocked', 'failed'].includes(task.status)).length
  const blockedTasks = tasks.filter((task) => task.status === 'blocked' || task.status === 'failed')

  if (authLoading) return <LoadingState />
  if (!isAuthenticated) return null

  return (
    <AppLayout>
      <div className="tasks-workspace flex min-w-0 flex-1 flex-col overflow-hidden p-2.5 md:p-4">
        <section className="tasks-shell flex min-h-0 flex-1 flex-col overflow-hidden rounded-[22px] border border-slate-200/90 backdrop-blur-2xl">
          <header className="tasks-header border-b border-slate-200/80 px-4 pt-4 md:px-7 md:pt-5">
            <div className="flex flex-wrap items-center justify-between gap-4">
              <div className="text-sm font-medium text-slate-500">
                <span className="text-[#0875df]">Projects</span>
                <span className="px-3 text-slate-300">/</span>
                <span>Product Operations</span>
              </div>
              <div className="flex items-center gap-4">
                <MemberStack bots={bots} />
                <div className="relative">
                  <button
                    className="relative grid h-10 w-10 place-items-center rounded-xl border border-slate-200 bg-white/80 text-slate-600 shadow-sm transition hover:border-sky-200 hover:text-sky-600"
                    aria-expanded={showNotifications}
                    aria-label="Notifications"
                    onClick={() => setShowNotifications((current) => !current)}
                  >
                    <Icon name="bell" className="h-5 w-5" />
                    {blockedTasks.length ? <span className="absolute right-1.5 top-1.5 h-2 w-2 rounded-full border border-white bg-[#0e91e9]" /> : null}
                  </button>
                  {showNotifications ? (
                    <div className="absolute right-0 top-12 z-50 w-72 rounded-xl border border-slate-200 bg-white p-3 text-sm shadow-xl">
                      <p className="text-xs font-black uppercase tracking-[0.16em] text-slate-400">Task alerts</p>
                      {blockedTasks.length ? (
                        <div className="mt-3 space-y-2">
                          {blockedTasks.slice(0, 4).map((task) => (
                            <button
                              key={task.id}
                              className="w-full rounded-lg border border-slate-100 bg-slate-50 p-3 text-left transition hover:border-sky-200 hover:bg-sky-50"
                              onClick={() => {
                                setSelectedTaskId(task.id)
                                setShowNotifications(false)
                              }}
                            >
                              <span className="block font-semibold text-slate-700">{task.title}</span>
                              <span className="mt-1 block text-xs capitalize text-slate-500">{task.status.replace('_', ' ')}</span>
                            </button>
                          ))}
                        </div>
                      ) : (
                        <p className="mt-3 text-sm text-slate-500">No blocked or failed tasks.</p>
                      )}
                    </div>
                  ) : null}
                </div>
                <Link href="/settings" className="grid h-10 w-10 place-items-center rounded-xl border border-slate-200 bg-white/80 text-slate-600 shadow-sm transition hover:border-sky-200 hover:text-sky-600" aria-label="Settings">
                  <Icon name="settings" className="h-5 w-5" />
                </Link>
              </div>
            </div>

            <h1 className="mt-2 text-[25px] font-bold tracking-[-0.7px] text-slate-800 md:text-[28px]">
              Product Operations <span className="text-slate-400">—</span> Q3 2026
            </h1>

            <div className="mt-4 grid max-w-[920px] grid-cols-1 gap-3 sm:grid-cols-3">
              <StatCard icon="clipboard" value={tasks.length} label="Tasks" tone="blue" />
              <StatCard icon="target" value={`${averageProgress}%`} label="Complete" tone="violet" />
              <StatCard icon="trend" value={onTrack} label="On Track" tone="green" />
            </div>

            <nav className="mt-3 flex gap-6 text-sm font-medium text-slate-600">
              {(['board', 'timeline', 'list', 'calendar'] as TaskView[]).map((mode) => (
                <button
                  key={mode}
                  onClick={() => setView(mode)}
                  className={`relative px-1 py-3 transition ${
                    view === mode
                      ? 'text-[#0875df] after:absolute after:inset-x-0 after:bottom-0 after:h-[3px] after:rounded-t-full after:bg-[#0e91e9]'
                      : 'hover:text-slate-900'
                  }`}
                >
                  {viewLabel(mode)}
                </button>
              ))}
            </nav>
          </header>

          <Toolbar
            filter={filter}
            query={query}
            zoom={zoom}
            onCreate={() => setShowCreate(true)}
            onFilter={setFilter}
            onQuery={setQuery}
            onRefresh={() => void refresh(false)}
            onZoom={setZoom}
          />

          {error ? (
            <div className="mx-4 mt-3 rounded-xl border border-red-100 bg-red-50 px-4 py-3 text-sm font-medium text-red-600">
              {error}
            </div>
          ) : null}

          <div className="tasks-view-scroll min-h-0 flex-1 overflow-auto scrollbar-thin">
            {isLoading ? (
              <LoadingState />
            ) : (
              <TaskViewPanel
                tasks={filteredTasks}
                selectedTaskId={selectedTaskId}
                view={view}
                zoom={zoom}
                onSelect={setSelectedTaskId}
              />
            )}
          </div>

          <footer className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-200/80 bg-white/80 px-5 py-3 text-xs text-slate-500">
            <div className="flex flex-wrap items-center gap-4">
              {PROJECT_GROUPS.map((group) => (
                <span key={group.id} className="flex items-center gap-2">
                  <span className="h-2.5 w-2.5 rounded-full" style={{ backgroundColor: group.color }} />
                  {group.label}
                </span>
              ))}
              <span className="flex items-center gap-2">
                <span className="h-2.5 w-2.5 rotate-45 bg-rose-500" />
                Milestone
              </span>
            </div>
            <button onClick={() => void refresh(false)} className="flex items-center gap-2 transition hover:text-sky-600">
              <Icon name="refresh" className="h-4 w-4" />
              Last updated {formatRelative(lastUpdated)}
            </button>
          </footer>
        </section>
      </div>

      {showCreate ? (
        <CreateTaskModal
          bots={bots}
          tasks={tasks}
          onClose={() => setShowCreate(false)}
          onCreated={async () => {
            setShowCreate(false)
            await refresh(false)
          }}
        />
      ) : null}
      {selectedTask ? (
        <TaskInspector
          task={selectedTask}
          bots={bots}
          onClose={() => setSelectedTaskId(null)}
          onChanged={() => refresh(false)}
        />
      ) : null}
    </AppLayout>
  )
}

function TaskViewPanel({
  tasks,
  selectedTaskId,
  view,
  zoom,
  onSelect,
}: {
  tasks: Task[]
  selectedTaskId: string | null
  view: TaskView
  zoom: ZoomMode
  onSelect: (taskId: string) => void
}) {
  if (view === 'board') return <TaskBoard tasks={tasks} selectedTaskId={selectedTaskId} onSelect={onSelect} />
  if (view === 'list') return <TaskList tasks={tasks} selectedTaskId={selectedTaskId} onSelect={onSelect} />
  if (view === 'calendar') return <TaskCalendar tasks={tasks} selectedTaskId={selectedTaskId} onSelect={onSelect} />
  return <GanttBoard tasks={tasks} selectedTaskId={selectedTaskId} zoom={zoom} onSelect={onSelect} />
}

function TaskBoard({ tasks, selectedTaskId, onSelect }: { tasks: Task[]; selectedTaskId: string | null; onSelect: (taskId: string) => void }) {
  const columns = [
    { id: 'available', label: 'Ready', statuses: ['pending', 'available'] },
    { id: 'active', label: 'Active', statuses: ['claimed', 'in_progress'] },
    { id: 'blocked', label: 'Blocked', statuses: ['blocked', 'failed'] },
    { id: 'completed', label: 'Done', statuses: ['completed'] },
  ]

  return (
    <div className="min-w-[980px] bg-white/55 p-5">
      <div className="grid grid-cols-4 gap-4">
        {columns.map((column) => {
          const columnTasks = tasks.filter((task) => column.statuses.includes(task.status))
          return (
            <section key={column.id} className="min-h-[360px] rounded-xl border border-slate-200 bg-white/80">
              <header className="flex items-center justify-between border-b border-slate-100 px-4 py-3">
                <h2 className="text-sm font-bold text-slate-700">{column.label}</h2>
                <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-bold text-slate-500">{columnTasks.length}</span>
              </header>
              <div className="space-y-3 p-3">
                {columnTasks.map((task) => (
                  <TaskCardButton key={task.id} task={task} selected={selectedTaskId === task.id} onSelect={onSelect} />
                ))}
                {!columnTasks.length ? <p className="rounded-lg border border-dashed border-slate-200 p-4 text-center text-sm text-slate-400">No tasks</p> : null}
              </div>
            </section>
          )
        })}
      </div>
    </div>
  )
}

function TaskList({ tasks, selectedTaskId, onSelect }: { tasks: Task[]; selectedTaskId: string | null; onSelect: (taskId: string) => void }) {
  return (
    <div className="min-w-[960px] bg-white/55 p-5">
      <div className="overflow-hidden rounded-xl border border-slate-200 bg-white/85">
        <div className="grid grid-cols-[1.5fr_120px_120px_120px_160px] border-b border-slate-200 bg-slate-50 px-4 py-3 text-xs font-black uppercase tracking-[0.12em] text-slate-400">
          <span>Task</span>
          <span>Status</span>
          <span>Priority</span>
          <span>Progress</span>
          <span>Schedule</span>
        </div>
        {tasks.map((task) => (
          <button
            key={task.id}
            onClick={() => onSelect(task.id)}
            className={`grid w-full grid-cols-[1.5fr_120px_120px_120px_160px] items-center border-b border-slate-100 px-4 py-3 text-left text-sm transition last:border-b-0 ${
              selectedTaskId === task.id ? 'bg-sky-50' : 'hover:bg-slate-50'
            }`}
          >
            <span className="min-w-0">
              <span className="block truncate font-semibold text-slate-700">{task.title}</span>
              <span className="mt-0.5 block truncate text-xs text-slate-400">{task.description || 'No description'}</span>
            </span>
            <span className="capitalize text-slate-600">{task.status.replace('_', ' ')}</span>
            <span className="capitalize text-slate-600">{task.priority}</span>
            <span className="font-semibold text-slate-700">{task.progress}%</span>
            <span className="text-xs text-slate-500">{formatRange(task)}</span>
          </button>
        ))}
        {!tasks.length ? <p className="p-8 text-center text-sm text-slate-400">No matching tasks</p> : null}
      </div>
    </div>
  )
}

function TaskCalendar({ tasks, selectedTaskId, onSelect }: { tasks: Task[]; selectedTaskId: string | null; onSelect: (taskId: string) => void }) {
  const groups = useMemo(() => {
    const grouped = new Map<string, Task[]>()
    tasks.forEach((task) => {
      const start = parseDate(task.estimated_start_at || task.created_at)
      const key = start ? start.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' }) : 'Unscheduled'
      grouped.set(key, [...(grouped.get(key) || []), task])
    })
    return [...grouped.entries()]
  }, [tasks])

  return (
    <div className="min-w-[960px] bg-white/55 p-5">
      <div className="grid grid-cols-4 gap-4">
        {groups.map(([label, groupTasks]) => (
          <section key={label} className="rounded-xl border border-slate-200 bg-white/85">
            <header className="border-b border-slate-100 px-4 py-3">
              <h2 className="text-sm font-bold text-slate-700">{label}</h2>
              <p className="mt-0.5 text-xs text-slate-400">{groupTasks.length} tasks</p>
            </header>
            <div className="space-y-3 p-3">
              {groupTasks.map((task) => <TaskCardButton key={task.id} task={task} selected={selectedTaskId === task.id} onSelect={onSelect} />)}
            </div>
          </section>
        ))}
        {!groups.length ? <p className="col-span-4 rounded-xl border border-dashed border-slate-300 bg-white/80 p-8 text-center text-sm text-slate-400">No matching tasks</p> : null}
      </div>
    </div>
  )
}

function TaskCardButton({ task, selected, onSelect }: { task: Task; selected: boolean; onSelect: (taskId: string) => void }) {
  return (
    <button
      onClick={() => onSelect(task.id)}
      className={`w-full rounded-lg border p-3 text-left transition ${
        selected ? 'border-sky-300 bg-sky-50 shadow-sm' : 'border-slate-100 bg-white hover:border-sky-200 hover:bg-slate-50'
      }`}
    >
      <span className="block truncate text-sm font-semibold text-slate-700">{task.title}</span>
      <span className="mt-2 flex items-center justify-between text-xs text-slate-500">
        <span className="capitalize">{task.status.replace('_', ' ')}</span>
        <span>{task.progress}%</span>
      </span>
      <span className="mt-2 block text-xs text-slate-400">{formatRange(task)}</span>
    </button>
  )
}

function viewLabel(view: TaskView) {
  return { board: 'Board', timeline: 'Timeline', list: 'List', calendar: 'Calendar' }[view]
}

function Toolbar({
  filter,
  query,
  zoom,
  onCreate,
  onFilter,
  onQuery,
  onRefresh,
  onZoom,
}: {
  filter: TaskFilter
  query: string
  zoom: ZoomMode
  onCreate: () => void
  onFilter: (filter: TaskFilter) => void
  onQuery: (query: string) => void
  onRefresh: () => void
  onZoom: (zoom: ZoomMode) => void
}) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-200/80 bg-white/70 px-4 py-3 md:px-5">
      <div className="flex flex-wrap items-center gap-3">
        <button onClick={onCreate} className="flex h-10 items-center gap-2 rounded-lg bg-[#0875df] px-4 text-sm font-semibold text-white shadow-[0_5px_12px_rgba(14,145,233,0.24)] transition hover:bg-[#0768d9]">
          <Icon name="plus" className="h-4 w-4" />
          Add Task
        </button>
        <label className="flex h-10 items-center gap-2 rounded-lg border border-slate-200 bg-white/85 px-3 text-sm text-slate-600 shadow-sm">
          <Icon name="filter" className="h-4 w-4" />
          <select value={filter} onChange={(event) => onFilter(event.target.value as TaskFilter)} className="bg-transparent outline-none">
            <option value="all">All tasks</option>
            <option value="active">Active</option>
            <option value="completed">Completed</option>
            <option value="blocked">Blocked</option>
          </select>
        </label>
        <label className="flex h-10 min-w-[220px] items-center gap-2 rounded-lg border border-slate-200 bg-white/85 px-3 text-sm text-slate-500 shadow-sm md:min-w-[260px]">
          <Icon name="search" className="h-4 w-4" />
          <input value={query} onChange={(event) => onQuery(event.target.value)} placeholder="Search tasks..." className="min-w-0 flex-1 bg-transparent text-slate-700 outline-none placeholder:text-slate-400" />
        </label>
      </div>
      <div className="flex items-center gap-3">
        <div className="flex overflow-hidden rounded-lg border border-slate-200 bg-white/85 text-sm text-slate-600 shadow-sm">
          {(['day', 'week', 'month'] as ZoomMode[]).map((value) => (
            <button
              key={value}
              onClick={() => onZoom(value)}
              className={`px-4 py-2 capitalize transition ${zoom === value ? 'bg-[#0875df] font-semibold text-white' : 'hover:bg-slate-50'}`}
            >
              {value}
            </button>
          ))}
        </div>
        <button onClick={onRefresh} className="grid h-9 w-9 place-items-center rounded-lg border border-slate-200 bg-white/85 text-slate-600 shadow-sm transition hover:text-sky-600" aria-label="Refresh tasks">
          <Icon name="refresh" className="h-4 w-4" />
        </button>
      </div>
    </div>
  )
}

function GanttBoard({
  tasks,
  selectedTaskId,
  zoom,
  onSelect,
}: {
  tasks: Task[]
  selectedTaskId: string | null
  zoom: ZoomMode
  onSelect: (taskId: string) => void
}) {
  const weekWidth = zoom === 'day' ? 118 : zoom === 'month' ? 58 : 76
  const [collapsedGroups, setCollapsedGroups] = useState<Set<ProjectGroup['id']>>(new Set())
  const timeline = useMemo(() => buildTimeline(tasks, weekWidth, collapsedGroups), [collapsedGroups, tasks, weekWidth])
  const toggleGroup = (groupId: ProjectGroup['id']) => {
    setCollapsedGroups((current) => {
      const next = new Set(current)
      if (next.has(groupId)) next.delete(groupId)
      else next.add(groupId)
      return next
    })
  }

  return (
    <div className="gantt-board min-w-[1180px]">
      <div className="gantt-header sticky top-0 z-30 flex border-b border-slate-200 backdrop-blur-xl">
        <div className="grid w-[430px] shrink-0 grid-cols-[1fr_92px_105px] items-end px-5 pb-3 pt-7 text-[11px] font-bold text-slate-600">
          <span>Task</span>
          <span>Assignee</span>
          <span>Dates</span>
        </div>
        <div className="relative border-l border-slate-200" style={{ width: timeline.width }}>
          <div className="flex h-8 border-b border-slate-200">
            {timeline.months.map((month) => (
              <div key={month.key} className="border-r border-slate-200 py-2 text-center text-xs font-bold text-slate-700" style={{ width: month.width }}>
                {month.label}
              </div>
            ))}
          </div>
          <div className="flex h-9">
            {timeline.weeks.map((week) => (
              <div key={week.key} className="border-r border-slate-200 px-2 py-2 text-[10px] font-medium text-slate-500" style={{ width: weekWidth }}>
                {formatWeek(week.date)}
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="flex">
        <div className="gantt-sidebar w-[430px] shrink-0 border-r border-slate-200">
          {timeline.rows.map((row) =>
            row.kind === 'group' ? (
              <button key={row.key} onClick={() => toggleGroup(row.group.id)} className="grid w-full grid-cols-[1fr_92px_105px] items-center border-b border-slate-200 px-3 text-left text-xs font-bold text-slate-700 transition hover:bg-slate-100" style={{ height: row.height }} aria-expanded={!collapsedGroups.has(row.group.id)}>
                <span className="flex items-center gap-2">
                  <Icon name="chevron" className={`h-3.5 w-3.5 transition ${collapsedGroups.has(row.group.id) ? '' : 'rotate-90'}`} />
                  <span className="h-2.5 w-2.5 rounded-full" style={{ backgroundColor: row.group.color }} />
                  {row.group.label}
                </span>
                <span className="font-medium text-slate-500">{timeline.groupCounts.get(row.group.id) || 0} tasks</span>
                <span />
              </button>
            ) : (
              <button
                key={row.key}
                onClick={() => row.task && onSelect(row.task.id)}
                className={`grid w-full grid-cols-[1fr_92px_105px] items-center border-b border-slate-100 px-4 text-left text-xs transition ${
                  selectedTaskId === row.task?.id ? 'bg-sky-50' : 'hover:bg-slate-50'
                }`}
                style={{ height: row.height }}
              >
                <span className="flex min-w-0 items-center gap-2">
                  <span className="w-4 text-right text-[10px] text-slate-400">{row.taskNumber}</span>
                  <span className="h-1.5 w-1.5 shrink-0 rounded-full" style={{ backgroundColor: statusColor(row.task!.status) }} />
                  <span className="truncate font-medium text-slate-700">{row.task!.title}</span>
                </span>
                <span><BotAvatar bot={row.task!.assignee_bot || undefined} fallback="—" size="sm" /></span>
                <span className="text-[10px] text-slate-500">{formatRange(row.task!)}</span>
              </button>
            )
          )}
        </div>

        <div className="gantt-chart relative overflow-hidden" style={{ width: timeline.width, height: timeline.height }}>
          {timeline.weeks.map((week, index) => (
            <div key={week.key} className="gantt-grid-line absolute inset-y-0 border-r border-dashed" style={{ left: index * weekWidth, width: weekWidth }} />
          ))}
          {timeline.rows.map((row) => (
            <div key={row.key} className={`gantt-row absolute inset-x-0 border-b ${row.kind === 'group' ? 'gantt-group-row' : ''}`} style={{ top: row.top, height: row.height }} />
          ))}

          {timeline.todayLeft >= 0 && timeline.todayLeft <= timeline.width ? (
            <div className="absolute inset-y-0 z-20 w-px bg-[#0875df]" style={{ left: timeline.todayLeft }}>
              <span className="absolute left-1/2 top-1 -translate-x-1/2 rounded-md bg-[#0875df] px-2 py-1 text-[9px] font-black tracking-wide text-white shadow-sm">TODAY</span>
            </div>
          ) : null}

          <svg className="pointer-events-none absolute inset-0 z-10 overflow-visible" width={timeline.width} height={timeline.height}>
            <defs>
              <marker id="gantt-arrow" markerHeight="7" markerWidth="7" orient="auto" refX="6" refY="3.5">
                <path d="M0,0 L7,3.5 L0,7 z" fill="#7890a9" />
              </marker>
            </defs>
            {timeline.arrows.map((arrow) => (
              <path key={arrow.id} d={`M ${arrow.x1} ${arrow.y1} C ${arrow.x1 + 16} ${arrow.y1}, ${arrow.x2 - 16} ${arrow.y2}, ${arrow.x2} ${arrow.y2}`} fill="none" markerEnd="url(#gantt-arrow)" stroke="#7890a9" strokeWidth="1.25" />
            ))}
          </svg>

          {timeline.bars.map((bar) => (
            <button
              key={bar.task.id}
              onClick={() => onSelect(bar.task.id)}
              className={`absolute z-20 overflow-hidden rounded-md border px-2 text-left text-[10px] font-semibold shadow-sm transition hover:-translate-y-0.5 hover:shadow-md ${
                selectedTaskId === bar.task.id ? 'ring-2 ring-sky-400 ring-offset-1' : ''
              }`}
              style={{
                backgroundColor: bar.group.soft,
                borderColor: bar.group.color,
                color: bar.group.color,
                height: 22,
                left: bar.left,
                top: bar.top,
                width: bar.width,
              }}
              title={`${bar.task.title}: ${bar.task.progress}%`}
            >
              <span className="absolute inset-y-0 left-0 opacity-25" style={{ backgroundColor: bar.group.color, width: `${bar.task.progress}%` }} />
              <span className="relative flex justify-between gap-2">
                <span className="truncate">{bar.task.title}</span>
                <span>{bar.task.progress}%</span>
              </span>
            </button>
          ))}

          {timeline.milestones.map((milestone) => (
            <div key={milestone.id} className="absolute z-20 h-3 w-3 rotate-45 border border-white shadow-sm" style={{ backgroundColor: milestone.color, left: milestone.left, top: milestone.top }} title={milestone.label} />
          ))}

          {tasks.length === 0 ? (
            <div className="absolute inset-0 grid place-items-center">
              <div className="gantt-empty-state rounded-2xl border border-dashed px-6 py-5 text-center shadow-sm">
                <p className="text-sm font-semibold text-slate-700">No matching tasks</p>
                <p className="mt-1 text-xs text-slate-400">Add a task or change the active filter.</p>
              </div>
            </div>
          ) : null}
        </div>
      </div>
    </div>
  )
}

function TaskInspector({ task, bots, onClose, onChanged }: { task: Task; bots: Bot[]; onClose: () => void; onChanged: () => Promise<void> }) {
  const [assignee, setAssignee] = useState(task.assignee_bot_id || '')
  const [isSaving, setIsSaving] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => setAssignee(task.assignee_bot_id || ''), [task.assignee_bot_id])
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [onClose])

  const saveAssignee = async () => {
    setIsSaving(true)
    setError('')
    try {
      await tasksApi.reassign(task.id, {
        assignee_bot_id: assignee || null,
        latest_status_note: assignee ? 'Assigned from timeline' : 'Returned to shared pool',
      })
      await onChanged()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save assignment')
    } finally {
      setIsSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[70] bg-slate-900/20 backdrop-blur-[2px]" onMouseDown={onClose}>
      <aside className="absolute inset-y-0 right-0 w-full max-w-[390px] overflow-y-auto border-l border-slate-200 bg-white p-6 shadow-2xl" onMouseDown={(event) => event.stopPropagation()}>
        <div className="flex items-start justify-between gap-4">
          <div>
            <span className="rounded-full bg-sky-50 px-2.5 py-1 text-[10px] font-bold uppercase tracking-wider text-sky-700">{task.status.replace('_', ' ')}</span>
            <h2 className="mt-3 text-xl font-bold text-slate-800">{task.title}</h2>
          </div>
          <button onClick={onClose} className="grid h-9 w-9 place-items-center rounded-lg border border-slate-200 text-slate-400 transition hover:bg-slate-50 hover:text-slate-700" aria-label="Close inspector">
            <Icon name="x" className="h-4 w-4" />
          </button>
        </div>
        <p className="mt-3 text-sm leading-6 text-slate-500">{task.description || 'No description provided.'}</p>

        <section className="mt-6">
          <div className="flex justify-between text-xs font-bold text-slate-500"><span>Progress</span><span>{task.progress}%</span></div>
          <div className="mt-2 h-2 overflow-hidden rounded-full bg-slate-100"><div className="h-full rounded-full bg-[#0e91e9]" style={{ width: `${task.progress}%` }} /></div>
        </section>

        <section className="mt-6 space-y-2">
          <label className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-400">Assignee</label>
          <select value={assignee} onChange={(event) => setAssignee(event.target.value)} className="w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm outline-none transition focus:border-sky-400">
            <option value="">Shared pool</option>
            {bots.map((bot) => <option key={bot.id} value={bot.id}>{bot.name}</option>)}
          </select>
          <button onClick={() => void saveAssignee()} disabled={isSaving} className="rounded-lg bg-[#0875df] px-3 py-2 text-xs font-bold text-white transition hover:bg-[#0768d9] disabled:opacity-60">
            {isSaving ? 'Saving...' : 'Save assignment'}
          </button>
          {error ? <p className="text-xs font-medium text-red-600">{error}</p> : null}
        </section>

        <InspectorDetail label="Priority" value={task.priority} />
        <InspectorDetail label="Estimated schedule" value={`${formatDate(task.estimated_start_at)} - ${formatDate(task.estimated_end_at)}`} />
        <InspectorDetail label="Execution state" value={executionStateLabel(task)} />
        <InspectorDetail label="Execution result" value={executionResultLabel(task)} />
        <InspectorDetail label="Latest note" value={task.latest_status_note || 'No status note.'} />

        <section className="mt-6">
          <h3 className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-400">Dependencies</h3>
          <div className="mt-2 space-y-2">
            {task.dependencies.length ? task.dependencies.map((dependency) => (
              <div key={dependency.id} className="rounded-xl border border-slate-100 bg-slate-50 p-3 text-xs text-slate-600">{dependency.depends_on_task?.title || dependency.depends_on_task_id}</div>
            )) : <p className="text-sm text-slate-400">None</p>}
          </div>
        </section>

        <section className="mt-6">
          <h3 className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-400">History</h3>
          <div className="mt-2 space-y-2">
            {task.events.map((event) => (
              <div key={event.id} className="rounded-xl border border-slate-100 p-3">
                <p className="text-xs font-bold capitalize text-slate-600">{event.status.replace('_', ' ')} · {event.progress}%</p>
                <p className="mt-1 text-[11px] text-slate-400">{event.note || event.actor_type} · {formatDate(event.created_at)}</p>
              </div>
            ))}
          </div>
        </section>
      </aside>
    </div>
  )
}

function CreateTaskModal({ bots, tasks, onClose, onCreated }: { bots: Bot[]; tasks: Task[]; onClose: () => void; onCreated: () => Promise<void> }) {
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [priority, setPriority] = useState<TaskPriority>('normal')
  const [assignee, setAssignee] = useState('')
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  const [dependencies, setDependencies] = useState<string[]>([])
  const [isSaving, setIsSaving] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [onClose])

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setIsSaving(true)
    setError('')
    try {
      await tasksApi.create({
        title,
        description,
        priority,
        ...(assignee ? { assignee_bot_id: assignee } : {}),
        ...(start ? { estimated_start_at: new Date(start).toISOString() } : {}),
        ...(end ? { estimated_end_at: new Date(end).toISOString() } : {}),
        dependency_ids: dependencies,
      })
      await onCreated()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create task')
    } finally {
      setIsSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-900/30 p-4 backdrop-blur-sm" onMouseDown={onClose}>
      <form onSubmit={submit} onMouseDown={(event) => event.stopPropagation()} className="w-full max-w-[650px] rounded-3xl border border-white/70 bg-white p-6 shadow-2xl">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#0875df]">Timeline</p>
            <h2 className="mt-1 text-xl font-bold text-slate-800">Add task</h2>
          </div>
          <button type="button" onClick={onClose} className="grid h-9 w-9 place-items-center rounded-lg border border-slate-200 text-slate-400 transition hover:bg-slate-50 hover:text-slate-700" aria-label="Close create form">
            <Icon name="x" className="h-4 w-4" />
          </button>
        </div>
        <div className="mt-5 grid gap-3 md:grid-cols-2">
          <input required value={title} onChange={(event) => setTitle(event.target.value)} placeholder="Task title" className="rounded-xl border border-slate-200 px-3 py-2.5 text-sm outline-none transition focus:border-sky-400 md:col-span-2" />
          <textarea value={description} onChange={(event) => setDescription(event.target.value)} placeholder="Description" rows={3} className="rounded-xl border border-slate-200 px-3 py-2.5 text-sm outline-none transition focus:border-sky-400 md:col-span-2" />
          <select value={priority} onChange={(event) => setPriority(event.target.value as TaskPriority)} className="rounded-xl border border-slate-200 px-3 py-2.5 text-sm outline-none">
            <option value="low">Low priority</option><option value="normal">Normal priority</option><option value="high">High priority</option><option value="critical">Critical priority</option>
          </select>
          <select value={assignee} onChange={(event) => setAssignee(event.target.value)} className="rounded-xl border border-slate-200 px-3 py-2.5 text-sm outline-none">
            <option value="">Shared pool</option>{bots.map((bot) => <option key={bot.id} value={bot.id}>{bot.name}</option>)}
          </select>
          <label className="text-xs font-bold text-slate-500">Starts<input type="datetime-local" value={start} onChange={(event) => setStart(event.target.value)} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none" /></label>
          <label className="text-xs font-bold text-slate-500">Ends<input type="datetime-local" value={end} onChange={(event) => setEnd(event.target.value)} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none" /></label>
          <label className="text-xs font-bold text-slate-500 md:col-span-2">Dependencies
            <select multiple value={dependencies} onChange={(event) => setDependencies([...event.target.selectedOptions].map((option) => option.value))} className="mt-1 min-h-20 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none">
              {tasks.map((task) => <option key={task.id} value={task.id}>{task.title}</option>)}
            </select>
          </label>
        </div>
        {error ? <p className="mt-3 text-sm font-medium text-red-600">{error}</p> : null}
        <div className="mt-5 flex justify-end gap-3">
          <button type="button" onClick={onClose} className="rounded-lg border border-slate-200 px-4 py-2.5 text-sm font-semibold text-slate-600 transition hover:bg-slate-50">Cancel</button>
          <button type="submit" disabled={isSaving} className="rounded-lg bg-[#0875df] px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-[#0768d9] disabled:opacity-60">{isSaving ? 'Creating...' : 'Create task'}</button>
        </div>
      </form>
    </div>
  )
}

function MemberStack({ bots }: { bots: Bot[] }) {
  const visible = bots.slice(0, 4)
  return (
    <div className="flex items-center pl-2">
      {visible.map((bot) => <BotAvatar key={bot.id} bot={bot} />)}
      {bots.length > 4 ? <span className="-ml-2 grid h-9 w-9 place-items-center rounded-full border-2 border-white bg-slate-700 text-[11px] font-bold text-white shadow-sm">+{bots.length - 4}</span> : null}
    </div>
  )
}

function BotAvatar({ bot, fallback = 'SP', size = 'md' }: { bot?: Bot; fallback?: string; size?: 'sm' | 'md' }) {
  const label = bot ? initials(bot.name) : fallback
  return <span title={bot?.name || 'Shared pool'} className={`grid place-items-center rounded-full border-2 border-white font-bold text-white shadow-sm ${size === 'sm' ? 'h-7 w-7 text-[9px]' : '-ml-2 h-9 w-9 text-[11px]'}`} style={{ backgroundColor: bot ? colorFor(bot.id) : '#94a3b8' }}>{label}</span>
}

function StatCard({ icon, value, label, tone }: { icon: IconName; value: React.ReactNode; label: string; tone: 'blue' | 'violet' | 'green' }) {
  const tones = {
    blue: 'tasks-stat-icon-blue',
    violet: 'tasks-stat-icon-violet',
    green: 'tasks-stat-icon-green',
  }
  return (
    <div className="tasks-stat-card flex h-[72px] items-center gap-4 rounded-xl border px-4">
      <span className={`grid h-11 w-11 place-items-center rounded-full ${tones[tone]}`}><Icon name={icon} className="h-6 w-6" /></span>
      <span><strong className="block text-[24px] leading-none text-slate-800">{value}</strong><span className="mt-1 block text-xs font-medium text-slate-500">{label}</span></span>
    </div>
  )
}

function InspectorDetail({ label, value }: { label: string; value: string }) {
  return <section className="mt-6"><h3 className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-400">{label}</h3><p className="mt-2 text-sm text-slate-600">{value}</p></section>
}

function executionStateLabel(task: Task) {
  const labels: Record<TaskStatus, string> = {
    pending: 'Pending release',
    available: 'Available to claim',
    claimed: 'Assigned; waiting for runtime progress',
    in_progress: 'In progress',
    completed: 'Completed',
    failed: 'Failed',
    blocked: 'Blocked by dependencies',
  }
  return labels[task.status]
}

function executionResultLabel(task: Task) {
  const terminalEvent = [...task.events]
    .sort((left, right) => new Date(right.created_at).getTime() - new Date(left.created_at).getTime())
    .find((event) => event.status === 'completed' || event.status === 'failed')
  const resultNote = task.latest_status_note || terminalEvent?.note

  if (task.status === 'completed') return resultNote || 'Completed without a result note.'
  if (task.status === 'failed') return resultNote || 'Failed without a result note.'
  return resultNote || 'No result posted yet.'
}

function LoadingState() {
  return <div className="grid min-h-[320px] flex-1 place-items-center"><span className="h-9 w-9 animate-spin rounded-full border-4 border-sky-100 border-t-[#0875df]" /></div>
}

function Icon({ name, className = '' }: { name: IconName; className?: string }) {
  const paths: Record<IconName, React.ReactNode> = {
    bell: <path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9m-8 13h4" />,
    chevron: <path d="m9 18 6-6-6-6" />,
    clipboard: <path d="M9 5h6m-7 0a2 2 0 0 0-2 2v13h12V7a2 2 0 0 0-2-2m-8 8h8m-8 4h5M9 3h6v4H9z" />,
    filter: <path d="M3 4h18l-7 8v6l-4 2v-8Z" />,
    plus: <path d="M12 5v14m-7-7h14" />,
    refresh: <path d="M20 11a8.1 8.1 0 0 0-15.5-2M4 4v5h5m-5 4a8.1 8.1 0 0 0 15.5 2m.5 5v-5h-5" />,
    search: <path d="m21 21-4.4-4.4m2.4-5.1a7.5 7.5 0 1 1-15 0 7.5 7.5 0 0 1 15 0Z" />,
    settings: <path d="M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Zm7.4-2.1 1.2 1.8-2 3.4-2.2-.2a8 8 0 0 1-2.4 1.4L13 22h-4l-1-2.2a8 8 0 0 1-2.4-1.4l-2.2.2-2-3.4 1.2-1.8a8 8 0 0 1 0-2.8L1.4 8.8l2-3.4 2.2.2A8 8 0 0 1 8 4.2L9 2h4l1 2.2a8 8 0 0 1 2.4 1.4l2.2-.2 2 3.4-1.2 1.8a8 8 0 0 1 0 2.8Z" />,
    target: <path d="M21 12a9 9 0 1 1-9-9m9 2-9 9m4-9h5v5" />,
    trend: <path d="m4 16 5-5 4 4 7-8m-5 0h5v5" />,
    x: <path d="M18 6 6 18M6 6l12 12" />,
  }
  return <svg className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" viewBox="0 0 24 24">{paths[name]}</svg>
}

function buildTimeline(tasks: Task[], weekWidth: number, collapsedGroups: Set<ProjectGroup['id']> = new Set()) {
  const rangeStart = startOfWeek(new Date(Date.now() - 2 * WEEK_MS))
  const width = VISIBLE_WEEKS * weekWidth
  const weeks = Array.from({ length: VISIBLE_WEEKS }, (_, index) => {
    const date = new Date(rangeStart.getTime() + index * WEEK_MS)
    return { key: date.toISOString(), date }
  })
  const months = monthSegments(weeks, weekWidth)
  const grouped = new Map(PROJECT_GROUPS.map((group) => [group.id, [] as Task[]]))
  tasks.forEach((task) => grouped.get(groupForTask(task).id)!.push(task))

  const rows: TimelineRow[] = []
  const groupCounts = new Map<ProjectGroup['id'], number>()
  let taskNumber = 0
  let top = 0
  PROJECT_GROUPS.forEach((group) => {
    const groupTasks = grouped.get(group.id) || []
    groupCounts.set(group.id, groupTasks.length)
    rows.push({ key: `group-${group.id}`, kind: 'group', top, height: GROUP_HEIGHT, group })
    top += GROUP_HEIGHT
    if (collapsedGroups.has(group.id)) return
    groupTasks.forEach((task) => {
      taskNumber += 1
      rows.push({ key: task.id, kind: 'task', top, height: TASK_HEIGHT, group, task, taskNumber })
      top += TASK_HEIGHT
    })
  })

  const taskRows = rows.filter((row): row is TimelineRow & { task: Task } => Boolean(row.task))
  const bars = taskRows.map((row, index) => {
    const start = taskStart(row.task, index, rangeStart)
    const end = taskEnd(row.task, start)
    const rawLeft = ((start.getTime() - rangeStart.getTime()) / WEEK_MS) * weekWidth
    const rawRight = ((end.getTime() - rangeStart.getTime()) / WEEK_MS) * weekWidth
    const left = clamp(rawLeft, 4, width - 34)
    return { task: row.task, group: row.group, left, top: row.top + 8, width: clamp(rawRight - rawLeft, 52, width - left - 4) }
  })
  const barsById = new Map(bars.map((bar) => [bar.task.id, bar]))
  const arrows = taskRows.flatMap((row) => row.task.dependencies.map((dependency) => {
    const source = barsById.get(dependency.depends_on_task_id)
    const target = barsById.get(row.task.id)
    if (!source || !target) return null
    return { id: dependency.id, x1: source.left + source.width, y1: source.top + 11, x2: target.left, y2: target.top + 11 }
  }).filter(Boolean)) as Array<{ id: string; x1: number; y1: number; x2: number; y2: number }>
  const milestones = PROJECT_GROUPS.flatMap((group) => {
    const groupBars = bars.filter((bar) => bar.group.id === group.id)
    if (!groupBars.length) return []
    const last = groupBars.reduce((current, candidate) => candidate.left + candidate.width > current.left + current.width ? candidate : current)
    return [{ id: `milestone-${group.id}`, label: `${group.label} milestone`, color: group.id === 'launch' ? '#ef5a74' : group.color, left: Math.min(width - 16, last.left + last.width + 8), top: last.top + 5 }]
  })

  return {
    arrows,
    bars,
    groupCounts,
    height: top,
    milestones,
    months,
    rows,
    todayLeft: ((Date.now() - rangeStart.getTime()) / WEEK_MS) * weekWidth,
    weeks,
    width,
  }
}

function monthSegments(weeks: Array<{ key: string; date: Date }>, weekWidth: number) {
  const segments: Array<{ key: string; label: string; width: number }> = []
  weeks.forEach((week) => {
    const label = week.date.toLocaleDateString(undefined, { month: 'long' })
    const previous = segments[segments.length - 1]
    if (previous?.label === label) previous.width += weekWidth
    else segments.push({ key: week.key, label, width: weekWidth })
  })
  return segments
}

function groupForTask(task: Task) {
  const content = `${task.title} ${task.description || ''}`.toLowerCase()
  if (/launch|release|deploy|go-live|rollout|monitor/.test(content)) return PROJECT_GROUPS[3]
  if (/test|qa|bug|regression|acceptance|verify|validation/.test(content)) return PROJECT_GROUPS[2]
  if (/design|develop|build|implement|frontend|backend|api|ux|ui/.test(content)) return PROJECT_GROUPS[1]
  if (task.status === 'in_progress' || task.status === 'claimed') return PROJECT_GROUPS[1]
  if (task.status === 'completed') return PROJECT_GROUPS[2]
  return PROJECT_GROUPS[0]
}

function taskStart(task: Task, index: number, rangeStart: Date) {
  const parsed = parseDate(task.estimated_start_at || task.created_at)
  if (parsed) return parsed
  return new Date(rangeStart.getTime() + (index % 6) * WEEK_MS)
}

function taskEnd(task: Task, start: Date) {
  const parsed = parseDate(task.estimated_end_at)
  if (parsed && parsed.getTime() > start.getTime()) return parsed
  const duration = task.priority === 'critical' ? 3 : task.priority === 'high' ? 2.4 : task.priority === 'low' ? 1.2 : 1.8
  return new Date(start.getTime() + duration * WEEK_MS)
}

function statusColor(status: TaskStatus) {
  return { pending: '#94a3b8', available: '#1682f0', claimed: '#8b5cf6', in_progress: '#f59e0b', completed: '#20ae83', failed: '#ef5a74', blocked: '#ef5a74' }[status]
}

function startOfWeek(value: Date) {
  const date = new Date(value)
  date.setHours(0, 0, 0, 0)
  const day = date.getDay()
  date.setDate(date.getDate() - (day === 0 ? 6 : day - 1))
  return date
}

function parseDate(value?: string | null) {
  if (!value) return null
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? null : date
}

function formatDate(value?: string | null) {
  const date = parseDate(value)
  return date ? date.toLocaleString() : 'Not set'
}

function formatRange(task: Task) {
  const start = parseDate(task.estimated_start_at || task.created_at)
  const end = parseDate(task.estimated_end_at)
  if (!start) return 'Not set'
  const left = start.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
  const right = end?.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
  return right ? `${left} - ${right}` : left
}

function formatWeek(date: Date) {
  const end = new Date(date.getTime() + 6 * 24 * 60 * 60 * 1000)
  return `${date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}–${end.getDate()}`
}

function formatRelative(value: Date | null) {
  if (!value) return 'never'
  const seconds = Math.floor((Date.now() - value.getTime()) / 1000)
  if (seconds < 10) return 'just now'
  if (seconds < 60) return `${seconds}s ago`
  return `${Math.floor(seconds / 60)}m ago`
}

function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join('').toUpperCase() || 'B'
}

function colorFor(value: string) {
  const sum = [...value].reduce((total, char) => total + char.charCodeAt(0), 0)
  return AVATAR_COLORS[sum % AVATAR_COLORS.length]
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(value, max))
}
