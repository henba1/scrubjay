// SPDX-License-Identifier: FSL-1.1-ALv2
// Copyright (c) 2026 Hendrik Baacke. See LICENSE.

import { describe, expect, test } from 'claude-code/testing'

import { argsLine, parseRun, reportOf, scriptOf, summarize } from '../hooks/parse'

const RECALL = 'mcp__sjmcp__sj_recall'

describe('parseRun', () => {
  test('last state wins, and a step still running at #end is skipped', async () => {
    const tsv = [
      '100\t#begin\tpublish\tabc12345',
      '100\tmemory\trun\t',
      '100\tdata\trun\t',
      '101\tdata\tok\tin sync with origin',
      '102\t#end\tdone\t',
    ].join('\n')
    const run = parseRun(tsv, 0)
    expect(run?.op).toBe('publish')
    expect(run?.endedAt).toBe(102_000)
    expect(run?.steps).toEqual([
      { name: 'memory', state: 'skip', detail: 'did not report' },
      { name: 'data', state: 'ok', detail: 'in sync with origin' },
    ])
  })

  test('a file with no #begin is no run', async () => {
    expect(parseRun('', 0)).toBe(null)
  })
})

describe('scriptOf', () => {
  test('names the publish and carries its authored topic', async () => {
    const s = scriptOf('SCRUBJAY_TOPIC="Fixed the relay" bash ~/.claude/hooks/publish-now.sh 2>&1')
    expect(s).toEqual({ verb: 'Publish', op: 'publish', detail: 'Fixed the relay' })
  })

  test('leaves other shell commands alone', async () => {
    expect(scriptOf('git status')).toBe(null)
  })
})

describe('sjmcp results', () => {
  test('a recall reads as a count of candidates and hosts', async () => {
    const output = [
      {
        type: 'text',
        text: JSON.stringify({
          count: 2,
          results: [
            { date: '2026-10-02', host: 'laptop', topic: 'retry backoff' },
            { date: '2026-09-30', host: 'scrubjay-rx', topic: 'relay keys' },
          ],
        }),
      },
    ]
    const s = summarize(RECALL, output)
    expect(s.line).toBe('2 candidates from 2 hosts')
    expect(s.rows[0]).toBe('2026-10-02 · laptop · retry backoff')
  })

  test('an error names the host that has it', async () => {
    const s = summarize('mcp__sjmcp__sj_get', JSON.stringify({ error: 'no transcript in this archive', host: 'laptop' }))
    expect(s).toEqual({ line: 'no transcript in this archive — look on laptop', tone: 'error', rows: [] })
  })

  test('the query leads, filters follow', async () => {
    expect(argsLine(RECALL, { query: 'retry', host: 'laptop', since: '2026-09-01' })).toBe(
      '"retry" · host laptop · since 2026-09-01',
    )
  })
})

describe('reportOf', () => {
  test('splits the step block from warnings and the exit line', async () => {
    const rep = reportOf(
      'scrubjay: relay FAILED\nscrubjay sync · 1s\n  ✓ data       up to date\n  ✗ memory     pull failed\nexit: 0\n',
    )
    expect(rep?.header).toBe('scrubjay sync · 1s')
    expect(rep?.steps.map(s => s.state)).toEqual(['ok', 'fail'])
    expect(rep?.rest).toEqual(['scrubjay: relay FAILED'])
  })
})

test('an sjmcp call draws as a named row on every surface', async $ => {
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({
      plugin: 'scrubjay-ui',
      surface,
      component: 'ToolUse',
      props: {
        tool_use_id: 't1',
        tool: RECALL,
        input: { query: 'retry backoff' },
        isRunning: false,
        isErrored: false,
        isInterrupted: false,
      },
    })
    expect(await ui.find({ type: 'Text', text: 'Recall' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /"retry backoff"/ })).toBeDefined()
    await ui.unmount()
  }
})

test('a publish result draws its steps', async $ => {
  const ui = await $.ui.mount({
    plugin: 'scrubjay-ui',
    surface: 'terminal',
    component: 'ToolResult',
    props: {
      tool_use_id: 't2',
      tool: 'Bash',
      output: { stdout: 'scrubjay publish · abc12345 · 2s\n  ✓ catalogue  row for abc12345\n  ✗ relay      local failed (rc=1)\n', stderr: '' },
      isErrored: false,
    },
  })
  expect(await ui.find({ type: 'Text', text: 'scrubjay publish · abc12345 · 2s' })).toBeDefined()
  const failed = await ui.find({ type: 'Text', text: /^✗$/ })
  expect(failed?.props.color).toBe('error')
  await ui.unmount()
})

// Shapes as this session's transcript stored them: /sjlog's Bash result and /sjrecall's MCP result
// (a list of text blocks holding the JSON). Values are placeholders; structure is verbatim.
const recalled = (hosts: string[]) => [
  {
    type: 'text',
    text: JSON.stringify(
      {
        query: 'verbose progress mod',
        engine: 'grep prefilter …',
        count: hosts.length,
        results: hosts.map((host, i) => ({
          type: 'transcript',
          host,
          project: 'scrubjay',
          date: `2026-10-${String(16 - i).padStart(2, '0')}`,
          topic: `topic ${i}`,
          sid: `0000000${i}`,
          path: `2026-10-16_topic-${i}__0000000${i}.md`,
          size: '312 KB',
          score: 50 - i,
          why: '3/3 terms',
          snippets: [{ line: 7, text: 'snippet' }],
        })),
      },
      null,
      2,
    ),
  },
]

describe('as this session recorded them', () => {
  test('the /sjrecall result', async () => {
    const hosts = ['laptop', 'laptop', 'laptop', 'laptop', 'laptop', 'scrubjay-rx', 'laptop', 'desktop']
    const s = summarize(RECALL, recalled(hosts))
    expect(s.line).toBe('8 candidates from 3 hosts')
    expect(s.rows).toEqual(['2026-10-16 · laptop · topic 0', '2026-10-15 · laptop · topic 1', '2026-10-14 · laptop · topic 2'])
  })

  test('the /sjlog result', async () => {
    const rep = reportOf(
      'scrubjay publish · 5cf29556 · 3s\n  – memory     nothing to publish\n  ✓ relay      shipped via local\n  ✓ catalogue  row for 5cf29556\n  ✓ data       in sync with origin\nexit: 0',
    )
    expect(rep?.steps.map(s => `${s.state} ${s.name}`)).toEqual(['skip memory', 'ok relay', 'ok catalogue', 'ok data'])
    expect(rep?.rest).toEqual([])
  })
})

describe('only a command that runs a script is drawn as one', () => {
  test('the invocations the commands use', async () => {
    expect(scriptOf('SCRUBJAY_TOPIC="Verbose sj commands" bash ~/.claude/hooks/publish-now.sh 2>&1; echo "exit: $?"')?.verb).toBe('Publish')
    expect(scriptOf('cd /x && bash hooks/sync-session.sh --report </dev/null 2>&1')?.verb).toBe('Sync')
    expect(scriptOf('bash "$(cd "$(dirname "$(readlink -f ~/.claude/hooks)")" && pwd)/bin/sj-resume.sh" 1a2b3c4d')?.verb).toBe('Resume')
    expect(scriptOf('bash ~/.claude/hooks/../bin/sj-note.sh --topic "fsl impact" <<\'EOF\'')?.detail).toBe('fsl impact')
  })

  test('commands that merely name one', async () => {
    for (const cmd of [
      'sed -n 1,40p hooks/publish-now.sh',
      'shellcheck -S warning hooks/sync-session.sh hooks/log-session.sh',
      'grep -n "echo" hooks/sync-session.sh | head',
      'git diff hooks/publish-now.sh',
    ]) {
      expect(scriptOf(cmd)).toBe(null)
    }
  })
})
