// SPDX-License-Identifier: FSL-1.1-ALv2
// Copyright (c) 2026 Hendrik Baacke. See LICENSE.

// Pure helpers: reading scrubjay's progress files, its sjmcp results and its scripts' output.
// Nothing here touches `$`, so the tests exercise it directly.

import type { SjRun, SjStep, StepState } from '../types'

export const SJMCP = 'mcp__sjmcp__'

const VERBS: Record<string, string> = {
  sj_recall: 'Recall',
  sj_list: 'Browse',
  sj_get: 'Get',
  sj_search_within: 'Find',
  sj_status: 'Status',
}

export const isSjmcp = (tool: string): boolean => tool.startsWith(SJMCP)

export const verbOf = (tool: string): string => {
  const name = tool.slice(SJMCP.length)

  return VERBS[name] ?? name
}

// The scrubjay scripts a Bash call may run, named for what the person would call the action. `op`
// is the progress file the run writes, where it writes one.
const SCRIPTS: ReadonlyArray<{ re: RegExp; verb: string; op?: string }> = [
  { re: /publish-now\.sh\b/, verb: 'Publish', op: 'publish' },
  { re: /sync-session\.sh\b/, verb: 'Sync', op: 'sync' },
  { re: /sj-doctor\.sh\b/, verb: 'Doctor' },
  { re: /sj-note\.sh\b/, verb: 'Note' },
  { re: /sj-resume\.sh\b/, verb: 'Resume' },
  { re: /sj-table\.sh\b/, verb: 'Table' },
  { re: /sj-grep\.sh\b/, verb: 'Grep' },
  { re: /sj-paste\.sh\b/, verb: 'Paste' },
  { re: /onboard-memory\.sh\b/, verb: 'Memory setup' },
  { re: /memory-sync\.sh\b/, verb: 'Memory sync' },
]

export type Script = { verb: string; op?: string; detail: string }

// A segment *runs* a script when, past any VAR=value assignments, the script is the command itself
// or what bash/sh is handed (a quoted path may hold spaces: "$(cd -P …)/bin/sj-doctor.sh"). Naming
// it anywhere else (`sed -n 1p hooks/publish-now.sh`, `shellcheck …`) is not running it.
const RUNS = (re: RegExp) =>
  new RegExp(
    String.raw`^\s*(?:[A-Za-z_]\w*=(?:"[^"]*"|'[^']*'|\S*)\s+)*(?:(?:ba)?sh\s+(?:-\S+\s+)*)?(?:"[^"]*?|\S*?)` +
      re.source,
  )

export function scriptOf(command: string): Script | null {
  const segments = command.split(/&&|\|\||;|\n/)
  const hit = SCRIPTS.find(s => segments.some(seg => RUNS(s.re).test(seg)))
  if (!hit) return null
  // The one argument worth showing: /sjlog's authored topic, /sjnote's topic.
  const topic = /SCRUBJAY_TOPIC="([^"]*)"/.exec(command) ?? /--topic "([^"]*)"/.exec(command)

  return { verb: hit.verb, op: hit.op, detail: topic?.[1] ?? '' }
}

const STATES: ReadonlySet<string> = new Set(['run', 'ok', 'fail', 'skip'])

/** A progress file (TSV <epoch> <step> <state> <detail>) as a run; null when it holds no #begin. */
export function parseRun(tsv: string, now: number, isQuiet = false): SjRun | null {
  let run: SjRun | null = null
  const steps = new Map<string, SjStep>()

  for (const line of tsv.split('\n')) {
    const [ts, name, state, detail = ''] = line.split('\t')
    if (ts === undefined || name === undefined || state === undefined) continue
    const at = Number(ts) * 1000
    if (name === '#begin') {
      run = { op: state, label: detail, startedAt: at, steps: [], isQuiet, now }
      steps.clear()
    } else if (name === '#end') {
      if (run) run.endedAt = at
    } else if (STATES.has(state)) {
      steps.set(name, { name, state: state as StepState, detail })
    }
  }
  if (!run) return null
  // A step still running at #end never reported back: skipped, never a success (sj_progress_render).
  run.steps = [...steps.values()].map(s =>
    run?.endedAt !== undefined && s.state === 'run'
      ? { ...s, state: 'skip', detail: s.detail || 'did not report' }
      : s,
  )

  return run
}

export const ICON: Record<StepState, string> = { run: '◌', ok: '✓', fail: '✗', skip: '–' }

const SPIN = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
export const spinner = (now: number): string => SPIN[Math.floor(now / 100) % SPIN.length] ?? '·'

const str = (v: unknown): string => (typeof v === 'string' ? v : typeof v === 'number' ? String(v) : '')

const shortRef = (ref: string): string => {
  const base = ref.split('/').pop() ?? ref

  return base.length > 40 ? `${base.slice(0, 37)}…` : base
}

/** The arguments of an sjmcp call, as the row shows them: the query first, filters after. */
export function argsLine(tool: string, input: unknown): string {
  const a = (input ?? {}) as Record<string, unknown>
  const filters = ['type', 'host', 'project', 'since', 'until']
    .filter(k => str(a[k]) !== '')
    .map(k => `${k} ${str(a[k])}`)
  const join = (head: string, rest: string[]) => [head, ...rest].filter(Boolean).join(' · ')

  switch (tool.slice(SJMCP.length)) {
    case 'sj_recall':
      return join(`"${str(a.query)}"`, filters)
    case 'sj_list':
      return join(str(a.type) || 'chats', filters.filter(f => !f.startsWith('type ')))
    case 'sj_get': {
      const slice = str(a.turns) ? `turns ${str(a.turns)}` : str(a.lines) ? `lines ${str(a.lines)}` : ''

      return join(shortRef(str(a.ref)), [slice, str(a.format)])
    }
    case 'sj_search_within':
      return `"${str(a.query)}" in ${shortRef(str(a.ref))}`
    default:
      return ''
  }
}

/** The text of a tool's output, whatever shape the transcript kept it in. */
export function textOf(output: unknown): string {
  if (typeof output === 'string') return output
  if (Array.isArray(output)) return output.map(textOf).join('\n')
  if (output && typeof output === 'object') {
    const o = output as Record<string, unknown>
    if (typeof o.text === 'string') return o.text
    if (Array.isArray(o.content)) return textOf(o.content)

    return JSON.stringify(output)
  }

  return ''
}

const parseJson = (text: string): Record<string, unknown> | null => {
  try {
    const v: unknown = JSON.parse(text)

    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null
  } catch {
    return null
  }
}

export type Tone = 'ok' | 'warn' | 'error'
export type Summary = { line: string; tone: Tone; rows: string[] }

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`

/** An sjmcp result in one line (and, for a recall, its top hits) in place of the raw JSON. */
export function summarize(tool: string, output: unknown): Summary {
  const text = textOf(output)
  const o = parseJson(text)
  if (!o) return { line: text.split('\n')[0]?.slice(0, 120) ?? '', tone: 'ok', rows: [] }
  if (typeof o.error === 'string') {
    const where = typeof o.host === 'string' ? ` — look on ${o.host}` : ''

    return { line: `${o.error}${where}`, tone: 'error', rows: [] }
  }

  switch (tool.slice(SJMCP.length)) {
    case 'sj_recall': {
      const results = Array.isArray(o.results) ? (o.results as Record<string, unknown>[]) : []
      const hosts = new Set(results.map(r => str(r.host)).filter(Boolean))
      const line =
        results.length === 0
          ? 'no candidates'
          : `${plural(results.length, 'candidate')}${hosts.size ? ` from ${plural(hosts.size, 'host')}` : ''}`
      const rows = results.slice(0, 3).map(r =>
        [str(r.date), str(r.host) || str(r.project), str(r.topic) || str(r.type)].filter(Boolean).join(' · '),
      )

      return { line, tone: results.length ? 'ok' : 'warn', rows }
    }
    case 'sj_list': {
      const shown = Number(o.shown ?? 0)
      const total = Number(o.total ?? shown)
      const line = total === 0 ? 'nothing listed' : shown < total ? `${shown} of ${total} listed` : `${plural(total, 'item')} listed`

      return { line, tone: total ? 'ok' : 'warn', rows: [] }
    }
    case 'sj_get': {
      const lines = str(o.content).split('\n').length
      const parts = [`pulled ${shortRef(str(o.path))}`, str(o.format), plural(lines, 'line')]
      if (o.truncated === true) parts.push('truncated')

      return { line: parts.filter(Boolean).join(' · '), tone: o.truncated === true ? 'warn' : 'ok', rows: [] }
    }
    case 'sj_search_within': {
      const n = Number(o.matches ?? 0)

      return { line: `${plural(n, 'match', 'matches')} in ${shortRef(str(o.path))}`, tone: n ? 'ok' : 'warn', rows: [] }
    }
    case 'sj_status': {
      const counts = (o.counts ?? {}) as Record<string, number>
      const line = Object.entries(counts)
        .filter(([, n]) => n > 0)
        .map(([k, n]) => `${n} ${k.replace('_', ' ')}`)
        .join(' · ')
      const missing = Array.isArray(o.unavailable) ? (o.unavailable as string[]) : []

      return {
        line: line || 'archive is empty',
        tone: missing.length ? 'warn' : 'ok',
        rows: missing.length ? [`not reachable here: ${missing.join(', ')}`] : [],
      }
    }
    default:
      return { line: text.split('\n')[0]?.slice(0, 120) ?? '', tone: 'ok', rows: [] }
  }
}

export type Report = { header: string; steps: SjStep[]; rest: string[] }

const STEP_LINE = /^ {2}([✓✗–…]) (\S+)\s+(.*)$/
const FROM_ICON: Record<string, StepState> = { '✓': 'ok', '✗': 'fail', '–': 'skip', '…': 'run' }

/** The step report sj_progress_render printed into a script's stdout, and the lines around it. */
export function reportOf(stdout: string): Report | null {
  const lines = stdout.replace(/\n$/, '').split('\n')
  const at = lines.findIndex(l => /^scrubjay \S+/.test(l))
  if (at < 0) return null
  const steps: SjStep[] = []
  let i = at + 1
  for (; i < lines.length; i++) {
    const m = STEP_LINE.exec(lines[i] ?? '')
    if (!m) break
    steps.push({ name: m[2] ?? '', state: FROM_ICON[m[1] ?? ''] ?? 'skip', detail: m[3] ?? '' })
  }
  const rest = [...lines.slice(0, at), ...lines.slice(i)].filter(l => l.trim() !== '' && !/^exit: \d+$/.test(l))

  return { header: lines[at] ?? '', steps, rest }
}
