// SPDX-License-Identifier: FSL-1.1-ALv2
// Copyright (c) 2026 Hendrik Baacke. See LICENSE.

// scrubjay in Claude Code's own interface. Three things, each drawn the way the engine draws its own:
//   - sjmcp calls and scrubjay's scripts get a row named for what they do (`⏺ Recall("…")`), and
//     a one-line result in place of raw JSON or a wall of shell output;
//   - while a publish or sync runs, a band above the prompt follows its steps live, read from the
//     progress file bin/lib.sh writes (~/.scrubjay/run/<op>.tsv);
//   - a failed step raises a toast, the SessionStart sync included, which otherwise fails unseen.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { SjActivity, SjRun } from '../types'
import { ICON, argsLine, isSjmcp, parseRun, reportOf, scriptOf, spinner, summarize, verbOf } from './parse'
import type { Tone } from './parse'

const runAtom = atom({ plugin: 'scrubjay-ui', key: 'run' } as const, null)
const activityAtom = atom({ plugin: 'scrubjay-ui', key: 'activity' } as const, null)

const OPS = ['publish', 'sync'] as const
const POLL_MS = 250
const LINGER_MS = 5000 // the finished run stays on the band this long
const GIVE_UP_MS = 90_000 // a watch that never sees its run begin stops

const TONE_COLOR = { ok: 'success', warn: 'warning', error: 'error', run: undefined } as const
const STEP_COLOR = { ok: 'success', fail: 'error', skip: 'inactive', run: 'warning' } as const

// A watch is module state on purpose: a reload drops its timer with the old environment, and the
// next trigger starts a fresh one. What the band draws lives in $.state and survives.
let runDir = ''
let timer: Timer | null = null
let watchFrom = 0
let isQuietWatch = false
let toasted = 0

async function dirOf($: EngineInterface): Promise<string> {
  if (runDir) return runDir
  const own = await $.env.get('SCRUBJAY_RUN_DIR')
  const home = await $.env.get('HOME')
  runDir = own || (home ? `${home}/.scrubjay/run` : '')

  return runDir
}

function stop(): void {
  timer?.cancel()
  timer = null
}

// Read every op's file and follow the newest run that began since the watch did.
async function poll($: EngineInterface): Promise<void> {
  const dir = await dirOf($)
  const now = await $.clock.now()
  if (!dir) {
    stop()

    return
  }
  let best: SjRun | null = null
  for (const op of OPS) {
    const text = await $.fs.read(`${dir}/${op}.tsv`).catch(() => '')
    const run = parseRun(text, now, isQuietWatch)
    if (run && run.startedAt >= watchFrom - 2000 && (!best || run.startedAt > best.startedAt)) best = run
  }
  if (!best) {
    if (now - watchFrom > GIVE_UP_MS) stop()

    return
  }
  const run = best
  await update($, runAtom, () => run)
  if (run.endedAt === undefined) return
  stop()
  const failed = run.steps.filter(s => s.state === 'fail')
  if (failed.length && toasted !== run.startedAt) {
    toasted = run.startedAt
    $.ui.toast(
      `scrubjay ${run.op}: ${failed.map(s => `${s.name} ${s.detail}`).join('; ')} — /sjdoctor ${failed.map(s => s.name).join(' ')}`,
    )
  }
  $.clock.after(LINGER_MS, () => {
    void update($, runAtom, cur => (cur?.startedAt === run.startedAt ? null : cur))
  })
}

async function watch($: EngineInterface, opts: { quiet?: boolean; backMs?: number } = {}): Promise<void> {
  watchFrom = (await $.clock.now()) - (opts.backMs ?? 0)
  isQuietWatch = opts.quiet ?? false
  if (!timer) timer = $.clock.every(POLL_MS, () => void poll($))
}

async function setActivity($: EngineInterface, a: Omit<SjActivity, 'at'>): Promise<void> {
  const at = await $.clock.now()
  await update($, activityAtom, () => ({ ...a, at }))
}

export const register: Register = on => {
  // The SessionStart sync ran (or is running) just before this: follow it quietly, so a failure
  // there reaches the person as a toast instead of a line only the model reads.
  on('session.start', async ($, e, next) => {
    await watch($, { quiet: true, backMs: 60_000 })

    return next(e)
  })

  // A typed /sjlog or /sjsync: start following before the command's own shell step runs.
  on('prompt.submit', async ($, e, next) => {
    const name = e.command?.name
    if (name === 'sjlog' || name === 'sjsync') await watch($)

    return next(e)
  }).catch(($, e, next) => next(e))

  on('skill.prompt', async ($, e, next) => {
    if (/^sj[a-z]+$/.test(e.skill)) {
      await setActivity($, { command: e.skill.slice(2), line: 'started', tone: 'run' })
      if (e.skill === 'sjlog' || e.skill === 'sjsync') await watch($)
    }

    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    if (isSjmcp(e.tool)) {
      const verb = verbOf(e.tool)
      await setActivity($, { command: verb.toLowerCase(), line: `${verb} ${argsLine(e.tool, e)}`, tone: 'run' })
      const ran = await next(e)
      const s = summarize(e.tool, ran.deny ?? ran.text ?? ran.result)
      await setActivity($, { command: verb.toLowerCase(), line: s.line, tone: ran.isError || ran.deny ? 'error' : s.tone })

      return ran
    }
    if (e.tool === 'Bash') {
      const script = scriptOf(e.command)
      if (script?.op) {
        await watch($)
        const ran = await next(e)
        await poll($) // the run has ended: take its last lines now, not a tick later

        return ran
      }
    }

    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    const done = await read($, activityAtom)
    if (done) {
      $.clock.after(LINGER_MS, () => {
        void update($, activityAtom, cur => (cur?.at === done.at ? null : cur))
      })
    }

    return next(e)
  })

  // ── the band ────────────────────────────────────────────────────────────────────────────────
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const run = await read($, runAtom)
    const activity = await read($, activityAtom)
    const { Box, Text } = $.ui.resolve(e)
    const showRun = run && !(run.isQuiet && run.endedAt !== undefined)

    if (showRun) {
      const secs = Math.max(0, Math.round(((run.endedAt ?? run.now) - run.startedAt) / 1000))
      const isLive = run.endedAt === undefined

      return (
        <Box flexDirection="row" flexWrap="wrap" columnGap={1}>
          <Text color="claude">◆</Text>
          <Text bold>scrubjay {run.op}</Text>
          {run.steps.map(s => (
            <Text key={s.name}>
              <Text color={STEP_COLOR[s.state]}>{s.state === 'run' ? spinner(run.now) : ICON[s.state]}</Text>
              <Text dimColor={s.state !== 'fail'}> {s.name}</Text>
            </Text>
          ))}
          <Text dimColor>· {isLive ? `${secs}s` : `done in ${secs}s`}</Text>
        </Box>
      )
    }
    if (activity) {
      const isLive = activity.tone === 'run'

      return (
        <Box flexDirection="row" columnGap={1}>
          <Text color="claude">◆</Text>
          <Text bold>scrubjay {activity.command}</Text>
          <Text color={TONE_COLOR[activity.tone]}>{isLive ? '→' : activity.tone === 'error' ? '✗' : '✓'}</Text>
          <Text dimColor wrap="truncate-end">
            {activity.line}
          </Text>
        </Box>
      )
    }

    return next(e)
  })

  // ── the transcript rows ─────────────────────────────────────────────────────────────────────
  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    const p = e.props
    if (p.isInterrupted) return next(e)
    let verb = ''
    let args = ''
    if (isSjmcp(p.tool)) {
      verb = verbOf(p.tool)
      args = argsLine(p.tool, p.input)
    } else if (p.tool === 'Bash') {
      const command = (p.input as { command?: unknown } | null)?.command
      const script = typeof command === 'string' ? scriptOf(command) : null
      if (!script) return next(e)
      verb = script.verb
      args = script.detail ? `"${script.detail}"` : ''
    } else {
      return next(e)
    }
    const { Box, Text } = $.ui.resolve(e)
    const dot = p.isRunning ? undefined : p.isErrored ? 'error' : 'success'

    return (
      <Box flexDirection="row">
        <Text color={dot} dimColor={p.isRunning}>
          ⏺{' '}
        </Text>
        <Text bold>{verb}</Text>
        {args !== '' && <Text wrap="truncate-end">({args})</Text>}
        <Text dimColor> · scrubjay</Text>
      </Box>
    )
  })

  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    const p = e.props
    if (p.isErrored) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const color = (t: Tone) => TONE_COLOR[t]

    if (isSjmcp(p.tool)) {
      const s = summarize(p.tool, p.output)

      return (
        <Box flexDirection="column">
          <Text>
            <Text dimColor>{'  ⎿  '}</Text>
            <Text color={color(s.tone)}>{s.line}</Text>
          </Text>
          {s.rows.map((r, i) => (
            <Text key={String(i)} dimColor wrap="truncate-end">
              {'     '}
              {r}
            </Text>
          ))}
        </Box>
      )
    }

    if (p.tool === 'Bash') {
      const out = p.output as { stdout?: unknown } | null
      const rep = typeof out?.stdout === 'string' ? reportOf(out.stdout) : null
      if (!rep || rep.steps.length === 0) return next(e)
      const width = Math.max(...rep.steps.map(s => s.name.length))

      return (
        <Box flexDirection="column">
          <Text>
            <Text dimColor>{'  ⎿  '}</Text>
            <Text>{rep.header}</Text>
          </Text>
          {rep.steps.map(s => (
            <Text key={s.name}>
              {'     '}
              <Text color={STEP_COLOR[s.state]}>{ICON[s.state]}</Text> <Text>{s.name.padEnd(width)}</Text>{' '}
              <Text dimColor={s.state !== 'fail'}>{s.detail}</Text>
            </Text>
          ))}
          {rep.rest.map((l, i) => (
            <Text key={`r${i}`} color={l.startsWith('scrubjay:') ? 'warning' : undefined} dimColor={!l.startsWith('scrubjay:')}>
              {'     '}
              {l}
            </Text>
          ))}
        </Box>
      )
    }

    return next(e)
  })
}
