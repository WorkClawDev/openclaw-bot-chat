'use client'

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import Link from 'next/link'
import { AppLayout } from '@/components/AppLayout'
import { useAuth } from '@/contexts/AuthContext'
import { botsApi, tasksApi } from '@/lib/api'
import type { Bot, Task, TaskEvent, TaskPriority, TaskStatus } from '@/lib/types'

const DAY_MS = 24 * 60 * 60 * 1000
const WEEK_MS = 7 * DAY_MS
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
type TaskFilter = 'all' | 'ready' | 'dispatched' | 'running' | 'review' | 'done' | 'failed'
type TaskView = 'board' | 'timeline' | 'list' | 'calendar'
type DragMode = 'move' | 'resize'

interface StatusLane {
  id: TaskFilter
  label: string
  shortLabel: string
  color: string
  soft: string
  statuses: TaskStatus[]
}

interface TimelineRow {
  key: string
  kind: 'group' | 'task'
  top: number
  height: number
  lane: StatusLane
  task?: Task
  taskNumber?: number
}

interface TimelineBar {
  task: Task
  lane: StatusLane
  left: number
  top: number
  width: number
  start: Date
  end: Date
}

interface DragState {
  taskId: string
  mode: DragMode
  originX: number
  originalStart: Date
  originalEnd: Date
  didMove: boolean
}

interface DragPreview {
  taskId: string
  start: Date
  end: Date
}

const STATUS_LANES: StatusLane[] = [
  { id: 'ready', label: 'Ready', shortLabel: 'Ready', color: '#1682f0', soft: '#dbeafe', statuses: ['pending', 'available'] },
  { id: 'dispatched', label: 'Dispatched', shortLabel: 'Dispatched', color: '#7c3aed', soft: '#ede9fe', statuses: ['claimed'] },
  { id: 'running', label: 'Running', shortLabel: 'Running', color: '#f59e0b', soft: '#fef3c7', statuses: ['in_progress'] },
  { id: 'review', label: 'Needs Review', shortLabel: 'Review', color: '#0f9f8f', soft: '#ccfbf1', statuses: ['awaiting_review'] },
  { id: 'done', label: 'Done', shortLabel: 'Done', color: '#10a878', soft: '#d1fae5', statuses: ['completed'] },
  { id: 'failed', label: 'Failed', shortLabel: 'Failed', color: '#ef5a74', soft: '#ffe4e6', statuses: ['failed', 'rejected', 'cancelled', 'blocked'] },
]

const PRIORITIES: TaskPriority[] = ['low', 'normal', 'high', 'critical']

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

  const saveTaskSchedule = useCallback(async (taskId: string, start: Date, end: Date) => {
    const estimated_start_at = start.toISOString()
    const estimated_end_at = end.toISOString()
    let previousTask: Task | null = null

    setTasks((current) =>
      current.map((task) => {
        if (task.id !== taskId) return task
        previousTask = task
        return { ...task, estimated_start_at, estimated_end_at }
      })
    )

    try {
      const updated = await tasksApi.update(taskId, { estimated_start_at, estimated_end_at })
      setTasks((current) => current.map((task) => (task.id === taskId ? updated : task)))
      setLastUpdated(new Date())
    } catch (err) {
      if (previousTask) {
        setTasks((current) => current.map((task) => (task.id === taskId ? previousTask as Task : task)))
      }
      setError(err instanceof Error ? err.message : 'Failed to save timeline change')
      throw err
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
        const haystack = `${task.title} ${task.description || ''} ${task.latest_status_note || ''}`.toLowerCase()
        const matchesQuery = haystack.includes(query.toLowerCase())
        if (!matchesQuery) return false
        if (filter === 'all') return true
        return laneForTask(task).id === filter
      }),
    [filter, query, tasks]
  )

  const selectedTask = tasks.find((task) => task.id === selectedTaskId) || null
  const readyCount = tasks.filter((task) => laneForTask(task).id === 'ready').length
  const runningCount = tasks.filter((task) => laneForTask(task).id === 'running').length
  const reviewCount = tasks.filter((task) => laneForTask(task).id === 'review').length
  const alertTasks = tasks.filter((task) => ['awaiting_review', 'failed', 'rejected', 'cancelled', 'blocked'].includes(task.status))

  if (authLoading) return <LoadingState />
  if (!isAuthenticated) return null

  return (
    <AppLayout>
      <div className="tasks-workspace flex min-w-0 flex-1 flex-col overflow-hidden p-2.5 md:p-4">
        <section className="tasks-shell flex min-h-0 flex-1 flex-col overflow-hidden rounded-[22px] border border-slate-200/90 backdrop-blur-2xl">
          <header className="tasks-header border-b border-slate-200/80 px-4 pt-4 md:px-7 md:pt-5">
            <div className="flex flex-wrap items-center justify-between gap-4">
              <div className="text-sm font-medium text-slate-500">
                <span className="text-[#0875df]">Claw</span>
                <span className="px-3 text-slate-300">/</span>
                <span>Dispatch Console</span>
              </div>
              <div className="flex items-center gap-4">
                <MemberStack bots={bots} />
                <div className="relative">
                  <button
                    className="relative grid h-10 w-10 place-items-center rounded-xl border border-slate-200 bg-white/80 text-slate-600 shadow-sm transition hover:border-sky-200 hover:text-sky-600"
                    aria-expanded={showNotifications}
                    aria-label="Execution alerts"
                    onClick={() => setShowNotifications((current) => !current)}
                  >
                    <Icon name="bell" className="h-5 w-5" />
                    {alertTasks.length ? <span className="absolute right-1.5 top-1.5 h-2 w-2 rounded-full border border-white bg-[#0e91e9]" /> : null}
                  </button>
                  {showNotifications ? (
                    <div className="absolute right-0 top-12 z-50 w-72 rounded-xl border border-slate-200 bg-white p-3 text-sm shadow-xl">
                      <p className="text-xs font-black uppercase tracking-[0.16em] text-slate-400">Execution alerts</p>
                      {alertTasks.length ? (
                        <div className="mt-3 space-y-2">
                          {alertTasks.slice(0, 4).map((task) => (
                            <button
                              key={task.id}
                              className="w-full rounded-lg border border-slate-100 bg-slate-50 p-3 text-left transition hover:border-sky-200 hover:bg-sky-50"
                              onClick={() => {
                                setSelectedTaskId(task.id)
                                setShowNotifications(false)
                              }}
                            >
                              <span className="block font-semibold text-slate-700">{task.title}</span>
                              <span className="mt-1 block text-xs text-slate-500">{executionStateLabel(task)}</span>
                            </button>
                          ))}
                        </div>
                      ) : (
                        <p className="mt-3 text-sm text-slate-500">No review or failure alerts.</p>
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
              Claw Dispatch Console
            </h1>

            <div className="mt-4 grid max-w-[920px] grid-cols-1 gap-3 sm:grid-cols-3">
              <StatCard icon="clipboard" value={readyCount} label="Ready" tone="blue" />
              <StatCard icon="trend" value={runningCount} label="Running" tone="violet" />
              <StatCard icon="target" value={reviewCount} label="Needs Review" tone="green" />
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
                onScheduleChange={saveTaskSchedule}
                onSelect={setSelectedTaskId}
              />
            )}
          </div>

          <footer className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-200/80 bg-white/80 px-5 py-3 text-xs text-slate-500">
            <div className="flex flex-wrap items-center gap-4">
              {STATUS_LANES.map((lane) => (
                <span key={lane.id} className="flex items-center gap-2">
                  <span className="h-2.5 w-2.5 rounded-full" style={{ backgroundColor: lane.color }} />
                  {lane.label}
                </span>
              ))}
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
          tasks={tasks}
          onClose={() => setSelectedTaskId(null)}
          onChanged={() => refresh(false)}
          onDeleted={async () => {
            setSelectedTaskId(null)
            await refresh(false)
          }}
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
  onScheduleChange,
  onSelect,
}: {
  tasks: Task[]
  selectedTaskId: string | null
  view: TaskView
  zoom: ZoomMode
  onScheduleChange: (taskId: string, start: Date, end: Date) => Promise<void>
  onSelect: (taskId: string) => void
}) {
  if (view === 'board') return <TaskBoard tasks={tasks} selectedTaskId={selectedTaskId} onSelect={onSelect} />
  if (view === 'list') return <TaskList tasks={tasks} selectedTaskId={selectedTaskId} onSelect={onSelect} />
  if (view === 'calendar') return <TaskCalendar tasks={tasks} selectedTaskId={selectedTaskId} onSelect={onSelect} />
  return <GanttBoard tasks={tasks} selectedTaskId={selectedTaskId} zoom={zoom} onScheduleChange={onScheduleChange} onSelect={onSelect} />
}

function TaskBoard({ tasks, selectedTaskId, onSelect }: { tasks: Task[]; selectedTaskId: string | null; onSelect: (taskId: string) => void }) {
  return (
    <div className="min-w-[1180px] bg-white/55 p-5">
      <div className="grid grid-cols-6 gap-4">
        {STATUS_LANES.map((lane) => {
          const laneTasks = tasks.filter((task) => lane.statuses.includes(task.status))
          return (
            <section key={lane.id} className="min-h-[360px] rounded-xl border border-slate-200 bg-white/80">
              <header className="flex items-center justify-between border-b border-slate-100 px-4 py-3">
                <h2 className="text-sm font-bold text-slate-700">{lane.shortLabel}</h2>
                <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-bold text-slate-500">{laneTasks.length}</span>
              </header>
              <div className="space-y-3 p-3">
                {laneTasks.map((task) => (
                  <TaskCardButton key={task.id} task={task} selected={selectedTaskId === task.id} onSelect={onSelect} />
                ))}
                {!laneTasks.length ? <p className="rounded-lg border border-dashed border-slate-200 p-4 text-center text-sm text-slate-400">No tasks</p> : null}
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
    <div className="min-w-[1080px] bg-white/55 p-5">
      <div className="overflow-hidden rounded-xl border border-slate-200 bg-white/85">
        <div className="grid grid-cols-[1.5fr_140px_140px_120px_150px_160px] border-b border-slate-200 bg-slate-50 px-4 py-3 text-xs font-black uppercase tracking-[0.12em] text-slate-400">
          <span>Task</span>
          <span>State</span>
          <span>Executor</span>
          <span>Priority</span>
          <span>Progress</span>
          <span>Schedule</span>
        </div>
        {tasks.map((task) => (
          <button
            key={task.id}
            onClick={() => onSelect(task.id)}
            className={`grid w-full grid-cols-[1.5fr_140px_140px_120px_150px_160px] items-center border-b border-slate-100 px-4 py-3 text-left text-sm transition last:border-b-0 ${
              selectedTaskId === task.id ? 'bg-sky-50' : 'hover:bg-slate-50'
            }`}
          >
            <span className="min-w-0">
              <span className="block truncate font-semibold text-slate-700">{task.title}</span>
              <span className="mt-0.5 block truncate text-xs text-slate-400">{task.description || 'No description'}</span>
            </span>
            <span className="text-slate-600">{laneForTask(task).label}</span>
            <span className="truncate text-slate-600">{executorLabel(task)}</span>
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
      const lane = laneForTask(task)
      const start = parseDate(task.estimated_start_at || task.dispatched_at || task.created_at)
      const dateLabel = start ? start.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' }) : 'Unscheduled'
      const key = `${lane.label} - ${dateLabel}`
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
  const lane = laneForTask(task)
  return (
    <button
      onClick={() => onSelect(task.id)}
      className={`w-full rounded-lg border p-3 text-left transition ${
        selected ? 'border-sky-300 bg-sky-50 shadow-sm' : 'border-slate-100 bg-white hover:border-sky-200 hover:bg-slate-50'
      }`}
    >
      <span className="block truncate text-sm font-semibold text-slate-700">{task.title}</span>
      <span className="mt-2 flex items-center justify-between gap-2 text-xs text-slate-500">
        <span className="flex items-center gap-1.5">
          <span className="h-2 w-2 rounded-full" style={{ backgroundColor: lane.color }} />
          {lane.label}
        </span>
        <span>{task.progress}%</span>
      </span>
      <span className="mt-2 block truncate text-xs text-slate-400">{executorLabel(task)}</span>
      <span className="mt-1 block text-xs text-slate-400">{formatRange(task)}</span>
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
          New Task
        </button>
        <label className="flex h-10 items-center gap-2 rounded-lg border border-slate-200 bg-white/85 px-3 text-sm text-slate-600 shadow-sm">
          <Icon name="filter" className="h-4 w-4" />
          <select value={filter} onChange={(event) => onFilter(event.target.value as TaskFilter)} className="bg-transparent outline-none">
            <option value="all">All states</option>
            <option value="ready">Ready</option>
            <option value="dispatched">Dispatched</option>
            <option value="running">Running</option>
            <option value="review">Needs Review</option>
            <option value="done">Done</option>
            <option value="failed">Failed</option>
          </select>
        </label>
        <label className="flex h-10 min-w-[220px] items-center gap-2 rounded-lg border border-slate-200 bg-white/85 px-3 text-sm text-slate-500 shadow-sm md:min-w-[260px]">
          <Icon name="search" className="h-4 w-4" />
          <input value={query} onChange={(event) => onQuery(event.target.value)} placeholder="Search dispatch tasks..." className="min-w-0 flex-1 bg-transparent text-slate-700 outline-none placeholder:text-slate-400" />
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
  onScheduleChange,
  onSelect,
}: {
  tasks: Task[]
  selectedTaskId: string | null
  zoom: ZoomMode
  onScheduleChange: (taskId: string, start: Date, end: Date) => Promise<void>
  onSelect: (taskId: string) => void
}) {
  const weekWidth = zoom === 'day' ? 118 : zoom === 'month' ? 58 : 76
  const [collapsedGroups, setCollapsedGroups] = useState<Set<TaskFilter>>(new Set())
  const [dragPreview, setDragPreview] = useState<DragPreview | null>(null)
  const dragRef = useRef<DragState | null>(null)
  const timeline = useMemo(() => buildTimeline(tasks, weekWidth, collapsedGroups, dragPreview), [collapsedGroups, dragPreview, tasks, weekWidth])

  const toggleGroup = (laneId: TaskFilter) => {
    setCollapsedGroups((current) => {
      const next = new Set(current)
      if (next.has(laneId)) next.delete(laneId)
      else next.add(laneId)
      return next
    })
  }

  useEffect(() => {
    const onPointerMove = (event: PointerEvent) => {
      const drag = dragRef.current
      if (!drag) return
      const dx = event.clientX - drag.originX
      const nextDates = draggedDates(drag, dx, weekWidth)
      dragRef.current = { ...drag, didMove: drag.didMove || Math.abs(dx) > 3 }
      setDragPreview({ taskId: drag.taskId, ...nextDates })
    }

    const onPointerUp = (event: PointerEvent) => {
      const drag = dragRef.current
      if (!drag) return
      dragRef.current = null
      setDragPreview(null)

      if (!drag.didMove && Math.abs(event.clientX - drag.originX) <= 3) {
        onSelect(drag.taskId)
        return
      }

      const nextDates = draggedDates(drag, event.clientX - drag.originX, weekWidth)
      void onScheduleChange(drag.taskId, nextDates.start, nextDates.end).catch(() => undefined)
    }

    window.addEventListener('pointermove', onPointerMove)
    window.addEventListener('pointerup', onPointerUp)
    window.addEventListener('pointercancel', onPointerUp)
    return () => {
      window.removeEventListener('pointermove', onPointerMove)
      window.removeEventListener('pointerup', onPointerUp)
      window.removeEventListener('pointercancel', onPointerUp)
    }
  }, [onScheduleChange, onSelect, weekWidth])

  const beginDrag = (event: React.PointerEvent, bar: TimelineBar, mode: DragMode) => {
    event.preventDefault()
    event.stopPropagation()
    dragRef.current = {
      taskId: bar.task.id,
      mode,
      originX: event.clientX,
      originalStart: bar.start,
      originalEnd: bar.end,
      didMove: false,
    }
    setDragPreview({ taskId: bar.task.id, start: bar.start, end: bar.end })
  }

  return (
    <div className="gantt-board min-w-[1180px]">
      <div className="gantt-header sticky top-0 z-30 flex border-b border-slate-200 backdrop-blur-xl">
        <div className="grid w-[430px] shrink-0 grid-cols-[1fr_92px_105px] items-end px-5 pb-3 pt-7 text-[11px] font-bold text-slate-600">
          <span>Task</span>
          <span>Executor</span>
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
              <button key={row.key} onClick={() => toggleGroup(row.lane.id)} className="grid w-full grid-cols-[1fr_92px_105px] items-center border-b border-slate-200 px-3 text-left text-xs font-bold text-slate-700 transition hover:bg-slate-100" style={{ height: row.height }} aria-expanded={!collapsedGroups.has(row.lane.id)}>
                <span className="flex items-center gap-2">
                  <Icon name="chevron" className={`h-3.5 w-3.5 transition ${collapsedGroups.has(row.lane.id) ? '' : 'rotate-90'}`} />
                  <span className="h-2.5 w-2.5 rounded-full" style={{ backgroundColor: row.lane.color }} />
                  {row.lane.label}
                </span>
                <span className="font-medium text-slate-500">{timeline.groupCounts.get(row.lane.id) || 0} tasks</span>
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
                <span><BotAvatar bot={executorBot(row.task!)} fallback="-" size="sm" /></span>
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
            <div
              key={bar.task.id}
              role="button"
              tabIndex={0}
              onKeyDown={(event) => {
                if (event.key === 'Enter' || event.key === ' ') onSelect(bar.task.id)
              }}
              onPointerDown={(event) => beginDrag(event, bar, 'move')}
              className={`gantt-task-bar absolute z-20 overflow-hidden rounded-md border px-2 text-left text-[10px] font-semibold shadow-sm transition hover:-translate-y-0.5 hover:shadow-md ${
                selectedTaskId === bar.task.id ? 'ring-2 ring-sky-400 ring-offset-1' : ''
              }`}
              style={{
                backgroundColor: bar.lane.soft,
                borderColor: bar.lane.color,
                color: bar.lane.color,
                height: 22,
                left: bar.left,
                top: bar.top,
                width: bar.width,
              }}
              title={`${bar.task.title}: drag to move, resize from the right edge`}
            >
              <span className="absolute inset-y-0 left-0 opacity-25" style={{ backgroundColor: bar.lane.color, width: `${bar.task.progress}%` }} />
              <span className="relative flex justify-between gap-2 pr-2">
                <span className="truncate">{bar.task.title}</span>
                <span>{bar.task.progress}%</span>
              </span>
              <span
                className="gantt-resize-handle absolute inset-y-0 right-0 w-3 cursor-ew-resize"
                onPointerDown={(event) => beginDrag(event, bar, 'resize')}
                aria-hidden="true"
              />
            </div>
          ))}

          {tasks.length === 0 ? (
            <div className="absolute inset-0 grid place-items-center">
              <div className="gantt-empty-state rounded-2xl border border-dashed px-6 py-5 text-center shadow-sm">
                <p className="text-sm font-semibold text-slate-700">No matching tasks</p>
                <p className="mt-1 text-xs text-slate-400">Create a task or change the active state filter.</p>
              </div>
            </div>
          ) : null}
        </div>
      </div>
    </div>
  )
}

function TaskInspector({
  task,
  bots,
  tasks,
  onClose,
  onChanged,
  onDeleted,
}: {
  task: Task
  bots: Bot[]
  tasks: Task[]
  onClose: () => void
  onChanged: () => Promise<void>
  onDeleted: () => Promise<void>
}) {
  const [title, setTitle] = useState(task.title)
  const [description, setDescription] = useState(task.description || '')
  const [priority, setPriority] = useState<TaskPriority>(task.priority)
  const [assignee, setAssignee] = useState(task.assignee_bot_id || task.claimed_by_bot_id || '')
  const [start, setStart] = useState(toDateTimeLocal(task.estimated_start_at))
  const [end, setEnd] = useState(toDateTimeLocal(task.estimated_end_at))
  const [dependencies, setDependencies] = useState<string[]>(dependencyIds(task))
  const [note, setNote] = useState('')
  const [isSaving, setIsSaving] = useState(false)
  const [actionName, setActionName] = useState<string | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    setTitle(task.title)
    setDescription(task.description || '')
    setPriority(task.priority)
    setAssignee(task.assignee_bot_id || task.claimed_by_bot_id || '')
    setStart(toDateTimeLocal(task.estimated_start_at))
    setEnd(toDateTimeLocal(task.estimated_end_at))
    setDependencies(dependencyIds(task))
    setNote('')
    setError('')
  }, [task])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [onClose])

  const saveTask = async () => {
    setIsSaving(true)
    setError('')
    try {
      await tasksApi.update(task.id, {
        title,
        description: description || null,
        priority,
        assignee_bot_id: assignee || null,
        estimated_start_at: toIsoOrNull(start),
        estimated_end_at: toIsoOrNull(end),
        dependency_ids: dependencies,
        latest_status_note: note || undefined,
      })
      await onChanged()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save task')
    } finally {
      setIsSaving(false)
    }
  }

  const runAction = async (name: 'dispatch' | 'cancel' | 'accept' | 'reject' | 'retry' | 'delete') => {
    if (name === 'delete' && !window.confirm('Delete this task?')) return
    if (name === 'cancel' && !window.confirm('Cancel this task?')) return

    setActionName(name)
    setError('')
    try {
      const payload = {
        assignee_bot_id: assignee || null,
        note: note || undefined,
      }
      if (name === 'dispatch') await tasksApi.dispatch(task.id, payload)
      if (name === 'cancel') await tasksApi.cancel(task.id, payload)
      if (name === 'accept') await tasksApi.accept(task.id, payload)
      if (name === 'reject') await tasksApi.reject(task.id, { ...payload, reason: note || undefined })
      if (name === 'retry') await tasksApi.retry(task.id, payload)
      if (name === 'delete') {
        await tasksApi.delete(task.id)
        await onDeleted()
        return
      }
      await onChanged()
    } catch (err) {
      setError(err instanceof Error ? err.message : `Failed to ${name} task`)
    } finally {
      setActionName(null)
    }
  }

  const childTasks = tasks.filter((candidate) => candidate.parent_task_id === task.id)

  return (
    <div className="fixed inset-0 z-[70] bg-slate-900/20 backdrop-blur-[2px]" onMouseDown={onClose}>
      <aside className="absolute inset-y-0 right-0 w-full max-w-[520px] overflow-y-auto border-l border-slate-200 bg-white p-6 shadow-2xl" onMouseDown={(event) => event.stopPropagation()}>
        <div className="flex items-start justify-between gap-4">
          <div>
            <span className="rounded-full bg-sky-50 px-2.5 py-1 text-[10px] font-bold uppercase tracking-wider text-sky-700">{laneForTask(task).label}</span>
            <h2 className="mt-3 text-xl font-bold text-slate-800">{task.title}</h2>
            <p className="mt-1 text-xs text-slate-400">{executionStateLabel(task)}</p>
          </div>
          <button onClick={onClose} className="grid h-9 w-9 place-items-center rounded-lg border border-slate-200 text-slate-400 transition hover:bg-slate-50 hover:text-slate-700" aria-label="Close inspector">
            <Icon name="x" className="h-4 w-4" />
          </button>
        </div>

        <section className="mt-5 grid gap-3">
          <label className="text-xs font-bold text-slate-500">Title
            <input value={title} onChange={(event) => setTitle(event.target.value)} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none transition focus:border-sky-400" />
          </label>
          <label className="text-xs font-bold text-slate-500">Description
            <textarea value={description} onChange={(event) => setDescription(event.target.value)} rows={4} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none transition focus:border-sky-400" />
          </label>
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="text-xs font-bold text-slate-500">Priority
              <select value={priority} onChange={(event) => setPriority(event.target.value as TaskPriority)} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none">
                {PRIORITIES.map((value) => <option key={value} value={value}>{titleCase(value)}</option>)}
              </select>
            </label>
            <label className="text-xs font-bold text-slate-500">Assignee
              <select value={assignee} onChange={(event) => setAssignee(event.target.value)} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none">
                <option value="">Shared pool</option>
                {bots.map((bot) => <option key={bot.id} value={bot.id}>{bot.name}</option>)}
              </select>
            </label>
          </div>
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="text-xs font-bold text-slate-500">Start
              <input type="datetime-local" value={start} onChange={(event) => setStart(event.target.value)} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none" />
            </label>
            <label className="text-xs font-bold text-slate-500">End
              <input type="datetime-local" value={end} onChange={(event) => setEnd(event.target.value)} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none" />
            </label>
          </div>
          <label className="text-xs font-bold text-slate-500">Dependencies
            <select multiple value={dependencies} onChange={(event) => setDependencies([...event.target.selectedOptions].map((option) => option.value))} className="mt-1 min-h-24 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none">
              {tasks.filter((candidate) => candidate.id !== task.id).map((candidate) => <option key={candidate.id} value={candidate.id}>{candidate.title}</option>)}
            </select>
          </label>
          <label className="text-xs font-bold text-slate-500">Action note
            <input value={note} onChange={(event) => setNote(event.target.value)} placeholder="Optional note for save or action" className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-normal outline-none transition focus:border-sky-400" />
          </label>
          <div className="flex flex-wrap gap-2">
            <button onClick={() => void saveTask()} disabled={isSaving} className="rounded-lg bg-[#0875df] px-3 py-2 text-xs font-bold text-white transition hover:bg-[#0768d9] disabled:opacity-60">
              {isSaving ? 'Saving...' : 'Save'}
            </button>
            <ActionButton label="Dispatch" active={actionName === 'dispatch'} onClick={() => void runAction('dispatch')} />
            <ActionButton label="Cancel" active={actionName === 'cancel'} onClick={() => void runAction('cancel')} />
            <ActionButton label="Accept" active={actionName === 'accept'} onClick={() => void runAction('accept')} />
            <ActionButton label="Reject" active={actionName === 'reject'} onClick={() => void runAction('reject')} />
            <ActionButton label="Retry" active={actionName === 'retry'} onClick={() => void runAction('retry')} />
            <button onClick={() => void runAction('delete')} disabled={Boolean(actionName)} className="rounded-lg border border-red-200 px-3 py-2 text-xs font-bold text-red-600 transition hover:bg-red-50 disabled:opacity-60">
              {actionName === 'delete' ? 'Deleting...' : 'Delete'}
            </button>
          </div>
          {error ? <p className="text-xs font-medium text-red-600">{error}</p> : null}
        </section>

        <section className="mt-6">
          <div className="flex justify-between text-xs font-bold text-slate-500"><span>Progress</span><span>{task.progress}%</span></div>
          <div className="mt-2 h-2 overflow-hidden rounded-full bg-slate-100"><div className="h-full rounded-full bg-[#0e91e9]" style={{ width: `${task.progress}%` }} /></div>
        </section>

        <section className="mt-6 rounded-xl border border-slate-100 bg-slate-50 p-4">
          <h3 className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-400">Current executor</h3>
          <div className="mt-3 flex items-center gap-3">
            <BotAvatar bot={executorBot(task)} fallback="-" />
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold text-slate-700">{executorLabel(task)}</p>
              <p className="mt-0.5 text-xs text-slate-400">Dispatched {formatDate(dispatchTime(task))} | Claimed {formatDate(claimTime(task))}</p>
            </div>
          </div>
        </section>

        <InspectorDetail label="Estimated schedule" value={`${formatDate(task.estimated_start_at)} - ${formatDate(task.estimated_end_at)}`} />
        <InspectorDetail label="Actual schedule" value={`${formatDate(task.actual_start_at)} - ${formatDate(task.actual_end_at)}`} />
        <InspectorDetail label="Latest note" value={task.latest_status_note || 'No status note.'} />

        <JsonSection label="Result" value={task.result} empty="No structured result posted yet." />
        <JsonSection label="Error" value={task.error} empty="No structured error posted." />
        <JsonSection label="Review" value={task.review} empty="No review payload posted yet." />

        <section className="mt-6">
          <h3 className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-400">Dependencies</h3>
          <div className="mt-2 space-y-2">
            {task.dependencies.length ? task.dependencies.map((dependency) => (
              <div key={dependency.id} className="rounded-xl border border-slate-100 bg-slate-50 p-3 text-xs text-slate-600">{dependency.depends_on_task?.title || dependency.depends_on_task_id}</div>
            )) : <p className="text-sm text-slate-400">None</p>}
          </div>
        </section>

        <section className="mt-6">
          <h3 className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-400">Bot spawned work</h3>
          <div className="mt-2 space-y-2">
            {childTasks.length ? childTasks.map((child) => (
              <div key={child.id} className="rounded-xl border border-slate-100 bg-slate-50 p-3">
                <p className="text-sm font-semibold text-slate-700">{child.title}</p>
                <p className="mt-1 text-xs text-slate-400">{statusLabel(child.status)} | {child.progress}%</p>
              </div>
            )) : <p className="text-sm text-slate-400">No child tasks created by the runtime.</p>}
          </div>
        </section>

        <section className="mt-6">
          <h3 className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-400">Event history</h3>
          <div className="mt-2 space-y-2">
            {task.events.length ? task.events.map((event) => (
              <EventBlock key={event.id} event={event} />
            )) : <p className="text-sm text-slate-400">No events yet.</p>}
          </div>
        </section>
      </aside>
    </div>
  )
}

function ActionButton({ label, active, onClick }: { label: string; active: boolean; onClick: () => void }) {
  return (
    <button onClick={onClick} disabled={active} className="rounded-lg border border-slate-200 px-3 py-2 text-xs font-bold text-slate-600 transition hover:bg-slate-50 disabled:opacity-60">
      {active ? `${label}...` : label}
    </button>
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
            <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#0875df]">Dispatch</p>
            <h2 className="mt-1 text-xl font-bold text-slate-800">Create task</h2>
          </div>
          <button type="button" onClick={onClose} className="grid h-9 w-9 place-items-center rounded-lg border border-slate-200 text-slate-400 transition hover:bg-slate-50 hover:text-slate-700" aria-label="Close create form">
            <Icon name="x" className="h-4 w-4" />
          </button>
        </div>
        <div className="mt-5 grid gap-3 md:grid-cols-2">
          <input required value={title} onChange={(event) => setTitle(event.target.value)} placeholder="Task title" className="rounded-xl border border-slate-200 px-3 py-2.5 text-sm outline-none transition focus:border-sky-400 md:col-span-2" />
          <textarea value={description} onChange={(event) => setDescription(event.target.value)} placeholder="Description" rows={3} className="rounded-xl border border-slate-200 px-3 py-2.5 text-sm outline-none transition focus:border-sky-400 md:col-span-2" />
          <select value={priority} onChange={(event) => setPriority(event.target.value as TaskPriority)} className="rounded-xl border border-slate-200 px-3 py-2.5 text-sm outline-none">
            {PRIORITIES.map((value) => <option key={value} value={value}>{titleCase(value)} priority</option>)}
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

function BotAvatar({ bot, fallback = 'SP', size = 'md' }: { bot?: Bot | null; fallback?: string; size?: 'sm' | 'md' }) {
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

function JsonSection({ label, value, empty }: { label: string; value: unknown; empty: string }) {
  return (
    <section className="mt-6">
      <h3 className="text-[10px] font-black uppercase tracking-[0.18em] text-slate-400">{label}</h3>
      {hasStructuredValue(value) ? (
        <pre className="mt-2 max-h-56 overflow-auto rounded-xl border border-slate-100 bg-slate-950 p-3 text-[11px] leading-5 text-slate-100">{stringifyPayload(value)}</pre>
      ) : (
        <p className="mt-2 text-sm text-slate-400">{empty}</p>
      )}
    </section>
  )
}

function EventBlock({ event }: { event: TaskEvent }) {
  return (
    <div className="rounded-xl border border-slate-100 p-3">
      <p className="text-xs font-bold capitalize text-slate-600">{statusLabel(event.status)} | {event.progress}%</p>
      <p className="mt-1 text-[11px] text-slate-400">{event.note || event.event_type || event.type || event.actor_type} | {formatDate(event.created_at)}</p>
      {hasStructuredValue(event.payload) ? (
        <pre className="mt-2 max-h-40 overflow-auto rounded-lg bg-slate-950 p-2 text-[10px] leading-4 text-slate-100">{stringifyPayload(event.payload)}</pre>
      ) : null}
    </div>
  )
}

function executionStateLabel(task: Task) {
  const labels: Record<TaskStatus, string> = {
    pending: 'Ready for dispatch',
    available: 'Ready for dispatch',
    claimed: 'Claimed by an executor',
    in_progress: 'Executor is running',
    awaiting_review: 'Waiting for human review',
    completed: 'Accepted and completed',
    failed: 'Execution failed',
    rejected: 'Review rejected',
    cancelled: 'Cancelled before completion',
    blocked: 'Blocked by dependencies',
  }
  return labels[task.status]
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

function buildTimeline(tasks: Task[], weekWidth: number, collapsedGroups: Set<TaskFilter> = new Set(), dragPreview: DragPreview | null = null) {
  const rangeStart = startOfWeek(new Date(Date.now() - 2 * WEEK_MS))
  const width = VISIBLE_WEEKS * weekWidth
  const weeks = Array.from({ length: VISIBLE_WEEKS }, (_, index) => {
    const date = new Date(rangeStart.getTime() + index * WEEK_MS)
    return { key: date.toISOString(), date }
  })
  const months = monthSegments(weeks, weekWidth)
  const grouped = new Map(STATUS_LANES.map((lane) => [lane.id, [] as Task[]]))
  tasks.forEach((task) => grouped.get(laneForTask(task).id)!.push(task))

  const rows: TimelineRow[] = []
  const groupCounts = new Map<TaskFilter, number>()
  let taskNumber = 0
  let top = 0
  STATUS_LANES.forEach((lane) => {
    const laneTasks = grouped.get(lane.id) || []
    groupCounts.set(lane.id, laneTasks.length)
    rows.push({ key: `group-${lane.id}`, kind: 'group', top, height: GROUP_HEIGHT, lane })
    top += GROUP_HEIGHT
    if (collapsedGroups.has(lane.id)) return
    laneTasks.forEach((task) => {
      taskNumber += 1
      rows.push({ key: task.id, kind: 'task', top, height: TASK_HEIGHT, lane, task, taskNumber })
      top += TASK_HEIGHT
    })
  })

  const taskRows = rows.filter((row): row is TimelineRow & { task: Task } => Boolean(row.task))
  const bars = taskRows.map((row, index): TimelineBar => {
    const preview = dragPreview?.taskId === row.task.id ? dragPreview : null
    const start = preview?.start || taskStart(row.task, index, rangeStart)
    const end = preview?.end || taskEnd(row.task, start)
    const rawLeft = ((start.getTime() - rangeStart.getTime()) / WEEK_MS) * weekWidth
    const rawRight = ((end.getTime() - rangeStart.getTime()) / WEEK_MS) * weekWidth
    const left = clamp(rawLeft, 4, width - 34)
    return { task: row.task, lane: row.lane, left, top: row.top + 8, width: clamp(rawRight - rawLeft, 52, width - left - 4), start, end }
  })
  const barsById = new Map(bars.map((bar) => [bar.task.id, bar]))
  const arrows = taskRows.flatMap((row) => row.task.dependencies.map((dependency) => {
    const source = barsById.get(dependency.depends_on_task_id)
    const target = barsById.get(row.task.id)
    if (!source || !target) return null
    return { id: dependency.id, x1: source.left + source.width, y1: source.top + 11, x2: target.left, y2: target.top + 11 }
  }).filter(Boolean)) as Array<{ id: string; x1: number; y1: number; x2: number; y2: number }>

  return {
    arrows,
    bars,
    groupCounts,
    height: top,
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

function laneForTask(task: Task) {
  return STATUS_LANES.find((lane) => lane.statuses.includes(task.status)) || STATUS_LANES[0]
}

function taskStart(task: Task, index: number, rangeStart: Date) {
  const parsed = parseDate(task.estimated_start_at || task.dispatched_at || task.created_at)
  if (parsed) return parsed
  return new Date(rangeStart.getTime() + (index % 6) * WEEK_MS)
}

function taskEnd(task: Task, start: Date) {
  const parsed = parseDate(task.estimated_end_at || task.actual_end_at)
  if (parsed && parsed.getTime() > start.getTime()) return parsed
  const duration = task.priority === 'critical' ? 3 : task.priority === 'high' ? 2.4 : task.priority === 'low' ? 1.2 : 1.8
  return new Date(start.getTime() + duration * WEEK_MS)
}

function draggedDates(drag: DragState, dx: number, weekWidth: number) {
  const deltaMs = Math.round(((dx / weekWidth) * WEEK_MS) / DAY_MS) * DAY_MS
  if (drag.mode === 'resize') {
    const end = new Date(Math.max(drag.originalStart.getTime() + DAY_MS, drag.originalEnd.getTime() + deltaMs))
    return { start: drag.originalStart, end }
  }
  const duration = drag.originalEnd.getTime() - drag.originalStart.getTime()
  const start = new Date(drag.originalStart.getTime() + deltaMs)
  return { start, end: new Date(start.getTime() + duration) }
}

function statusColor(status: TaskStatus) {
  return {
    pending: '#94a3b8',
    available: '#1682f0',
    claimed: '#f59e0b',
    in_progress: '#f59e0b',
    awaiting_review: '#0f9f8f',
    completed: '#20ae83',
    failed: '#ef5a74',
    rejected: '#ef5a74',
    cancelled: '#64748b',
    blocked: '#ef5a74',
  }[status]
}

function executorBot(task: Task) {
  return task.current_executor_bot || task.executor_bot || task.claimed?.bot || task.claimed_by_bot || task.assignee_bot || undefined
}

function executorLabel(task: Task) {
  const bot = executorBot(task)
  if (bot?.name) return bot.name
  return task.current_executor_bot_id || task.executor_bot_id || task.claimed?.bot_id || task.claimed_by_bot_id || task.assignee_bot_id || 'Shared pool'
}

function dispatchTime(task: Task) {
  return task.dispatched_at || task.dispatched?.at || null
}

function claimTime(task: Task) {
  return task.claimed_at || task.claimed?.at || null
}

function dependencyIds(task: Task) {
  return task.dependencies.map((dependency) => dependency.depends_on_task_id)
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

function toDateTimeLocal(value?: string | null) {
  const date = parseDate(value)
  if (!date) return ''
  const offsetDate = new Date(date.getTime() - date.getTimezoneOffset() * 60 * 1000)
  return offsetDate.toISOString().slice(0, 16)
}

function toIsoOrNull(value: string) {
  return value ? new Date(value).toISOString() : null
}

function formatDate(value?: string | null) {
  const date = parseDate(value)
  return date ? date.toLocaleString() : 'Not set'
}

function formatRange(task: Task) {
  const start = parseDate(task.estimated_start_at || task.dispatched_at || task.created_at)
  const end = parseDate(task.estimated_end_at || task.actual_end_at)
  if (!start) return 'Not set'
  const left = start.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
  const right = end?.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
  return right ? `${left} - ${right}` : left
}

function formatWeek(date: Date) {
  const end = new Date(date.getTime() + 6 * DAY_MS)
  return `${date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}-${end.getDate()}`
}

function formatRelative(value: Date | null) {
  if (!value) return 'never'
  const seconds = Math.floor((Date.now() - value.getTime()) / 1000)
  if (seconds < 10) return 'just now'
  if (seconds < 60) return `${seconds}s ago`
  return `${Math.floor(seconds / 60)}m ago`
}

function statusLabel(status: TaskStatus) {
  return status.replace(/_/g, ' ')
}

function titleCase(value: string) {
  return value.replace(/_/g, ' ').replace(/\b\w/g, (char) => char.toUpperCase())
}

function hasStructuredValue(value: unknown) {
  if (value === null || typeof value === 'undefined') return false
  if (typeof value === 'string') return value.trim().length > 0
  return true
}

function stringifyPayload(value: unknown) {
  if (typeof value === 'undefined' || value === null) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
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
