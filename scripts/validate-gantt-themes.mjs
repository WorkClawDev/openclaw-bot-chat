#!/usr/bin/env node

import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const storePath = resolve(root, 'frontend/src/lib/store.ts')
const globalsPath = resolve(root, 'frontend/src/app/globals.css')
const tasksPath = resolve(root, 'frontend/src/app/tasks/page.tsx')

const store = readFileSync(storePath, 'utf8')
const globals = readFileSync(globalsPath, 'utf8')
const tasks = readFileSync(tasksPath, 'utf8')

function fail(message) {
  console.error(`validate-gantt-themes: ${message}`)
  process.exit(1)
}

const backgroundMatch = store.match(/export type BackgroundType = ([^\n]+)/)
if (!backgroundMatch) fail('could not find BackgroundType in frontend/src/lib/store.ts')

const themes = [...backgroundMatch[1].matchAll(/'([^']+)'/g)].map((match) => match[1])
if (!themes.length) fail('BackgroundType did not contain any string literal themes')

for (const theme of themes) {
  if (!globals.includes(`body.bg-theme-${theme}`)) {
    fail(`missing body.bg-theme-${theme} selector in globals.css`)
  }
}

const requiredCssClasses = [
  '.tasks-workspace',
  '.tasks-shell',
  '.tasks-header',
  '.tasks-view-scroll',
  '.tasks-stat-card',
  '.tasks-stat-icon-blue',
  '.tasks-stat-icon-violet',
  '.tasks-stat-icon-green',
  '.gantt-board',
  '.gantt-header',
  '.gantt-sidebar',
  '.gantt-chart',
  '.gantt-grid-line',
  '.gantt-row',
  '.gantt-group-row',
  '.gantt-empty-state',
]

for (const className of requiredCssClasses) {
  if (!globals.includes(className)) {
    fail(`missing ${className} CSS contract in globals.css`)
  }
}

const darkBlock = globals.match(/body\.bg-theme-dark\s*\{[\s\S]*?\n\}/)?.[0] || ''
const requiredDarkVariables = [
  '--tasks-workspace-bg',
  '--tasks-shell-bg',
  '--tasks-shell-shadow',
  '--tasks-header-bg',
  '--tasks-scroll-bg',
  '--tasks-stat-card-bg',
  '--tasks-stat-card-border',
  '--tasks-stat-card-shadow',
  '--tasks-stat-icon-blue-bg',
  '--tasks-stat-icon-blue-fg',
  '--tasks-stat-icon-violet-bg',
  '--tasks-stat-icon-violet-fg',
  '--tasks-stat-icon-green-bg',
  '--tasks-stat-icon-green-fg',
  '--gantt-board-bg',
  '--gantt-header-bg',
  '--gantt-sidebar-bg',
  '--gantt-chart-bg',
  '--gantt-grid-line',
  '--gantt-row-border',
  '--gantt-group-row-bg',
  '--gantt-empty-bg',
  '--gantt-empty-border',
]

for (const variable of requiredDarkVariables) {
  if (!darkBlock.includes(variable)) {
    fail(`dark theme does not define ${variable}`)
  }
}

const requiredPageClasses = [
  'tasks-workspace',
  'tasks-shell',
  'tasks-header',
  'tasks-view-scroll',
  'tasks-stat-card',
  'tasks-stat-icon-blue',
  'tasks-stat-icon-violet',
  'tasks-stat-icon-green',
  'gantt-board',
  'gantt-header',
  'gantt-sidebar',
  'gantt-chart',
  'gantt-grid-line',
  'gantt-row',
  'gantt-group-row',
  'gantt-empty-state',
]

for (const className of requiredPageClasses) {
  if (!tasks.includes(className)) {
    fail(`tasks page does not use ${className}`)
  }
}

const ganttBoardMatch = tasks.match(/function GanttBoard\([\s\S]*?\nfunction TaskInspector/)
if (!ganttBoardMatch) fail('could not isolate GanttBoard implementation')

const ganttBoard = ganttBoardMatch[0]
for (const staleClass of ['bg-white/55', 'bg-slate-50/45', 'border-slate-200/90']) {
  if (ganttBoard.includes(staleClass)) {
    fail(`GanttBoard still contains light-only ${staleClass}`)
  }
}

if (tasks.includes('bg-[radial-gradient(circle_at_12%_5%')) {
  fail('tasks page still uses the hardcoded light workspace gradient')
}

if (tasks.includes('bg-gradient-to-r from-white/75 to-sky-50/40')) {
  fail('tasks page still uses a hardcoded light header gradient')
}

const statCardMatch = tasks.match(/function StatCard\([\s\S]*?\nfunction InspectorDetail/)
if (!statCardMatch) fail('could not isolate StatCard implementation')

const statCard = statCardMatch[0]
for (const staleClass of ['bg-white/75', 'bg-sky-100', 'bg-violet-100', 'bg-emerald-100', 'shadow-[0_4px_10px_rgba(80,105,135,0.08)]']) {
  if (statCard.includes(staleClass)) {
    fail(`StatCard still contains light-only ${staleClass}`)
  }
}

console.log(`validate-gantt-themes: checked ${themes.length} themes (${themes.join(', ')})`)
