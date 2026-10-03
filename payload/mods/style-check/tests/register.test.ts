import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// The mod never judges a character itself: it hands the text to the push hook's own scanner,
// hooks/lib/style-scan.py, and relays its verdict, so the two cannot disagree (claude-config#609).
// The scanner is stood in for here (a test has no processes); its own rule, and the proof that the
// push hook and this --plain mode agree on one fixture set, live in test-check-style-guide.sh.
const SCRIPT = '/Users/x/.claude/hooks/lib/style-scan.py'
const DASH = '\u2014'
const BAD = `const label = "Loading ${DASH} please wait"`

type Run = { argv: readonly string[]; stdin: string }

const world = (on: On, opts: { scanner?: 'ok' | 'missing'; files?: Record<string, string> } = {}) => {
  const runs: Run[] = []
  const reached: string[] = []
  const toasts: string[] = []
  const logs: string[] = []
  mock.env(on, { HOME: '/Users/x' })
  mock.store(on)
  on('process.run', ($, e) => {
    const stdin = e.init?.stdin ?? ''
    runs.push({ argv: e.argv, stdin })
    if (opts.scanner === 'missing') {
      return { value: { exitCode: 2, stdout: '', stderr: "can't open file", isStdoutTruncated: false, isStderrTruncated: false } }
    }
    const lines = stdin.split('\n')
    const hits = lines.map((l, i) => (l.includes(DASH) ? `line ${i + 1}: ${l}` : '')).filter(Boolean)
    return { value: { exitCode: hits.length ? 1 : 0, stdout: hits.join('\n'), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.read', ($, e) => {
    const f = opts.files?.[e.path]
    if (f === undefined) throw new Error(`no file ${e.path}`)
    return { value: f }
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('tool.call', ($, e) => {
    reached.push(e.tool)
    return { result: 'ran', text: 'ran' } as never
  })
  return { runs, reached, toasts, logs }
}

const refused = (r: unknown): string => {
  const x = r as { deny?: string; text?: string; isError?: boolean }
  return x.deny ?? (x.isError ? (x.text ?? '') : '')
}

test('a Write carrying a dash is refused, naming the line', async ($, on) => {
  const w = world(on)
  const r = await $.tool.call({ tool: 'Write', file_path: '/repo/a.ts', content: `ok\n${BAD}\n` } as never)
  expect(w.reached).not.toContain('Write')
  expect(refused(r)).toContain('line 2')
  expect(w.runs[0]?.argv).toEqual(['python3', SCRIPT, '--plain', '--path', '/repo/a.ts'])
  expect(w.runs[0]?.stdin).toContain(BAD)
})

test('a clean Write goes through', async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Write', file_path: '/repo/a.ts', content: 'all fine\n' } as never)
  expect(w.reached).toContain('Write')
})

test('an Edit is judged on its new text, not the old', async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Edit', file_path: '/repo/a.ts', old_string: BAD, new_string: 'fixed' } as never)
  expect(w.reached).toContain('Edit')
  await $.tool.call({ tool: 'Edit', file_path: '/repo/a.ts', old_string: 'x', new_string: BAD } as never)
  expect(w.reached.filter(t => t === 'Edit').length).toBe(1)
})

test('a MultiEdit is judged on every new text', async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'MultiEdit', file_path: '/repo/a.ts', edits: [{ old_string: 'a', new_string: 'b' }, { old_string: 'c', new_string: BAD }] } as never)
  expect(w.reached).not.toContain('MultiEdit')
})

test('a NotebookEdit is judged on its new source', async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'NotebookEdit', notebook_path: '/repo/n.ipynb', new_source: BAD } as never)
  expect(w.reached).not.toContain('NotebookEdit')
})

test('a commit message carrying a dash is refused', async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Bash', command: `git commit -m "Fix ${DASH} again"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a commit message read from a file is judged too', async ($, on) => {
  const w = world(on, { files: { '/tmp/msg.txt': `Subject ${DASH} body\n` } })
  await $.tool.call({ tool: 'Bash', command: 'git commit -F /tmp/msg.txt' } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a gh pr body carrying a dash is refused', async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Bash', command: `gh pr create --title t --body "x ${DASH} y"` } as never)
  expect(w.reached).not.toContain('Bash')
})

test('a gh issue comment read from a body file is judged', async ($, on) => {
  const w = world(on, { files: { '/tmp/b.md': `note ${DASH}\n` } })
  await $.tool.call({ tool: 'Bash', command: 'gh issue comment 12 --body-file /tmp/b.md' } as never)
  expect(w.reached).not.toContain('Bash')
})

test('an ordinary command is not scanned at all', async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Bash', command: `grep -n "${DASH}" file.txt` } as never)
  expect(w.reached).toContain('Bash')
  expect(w.runs.length).toBe(0)
})

for (const tool of ['mcp__claude_ai_Slack__slack_send_message', 'mcp__claude_ai_Slack__slack_send_message_draft', 'mcp__claude_ai_Slack__slack_schedule_message']) {
  test(`a Slack message through ${tool.split('__').pop()} is judged`, async ($, on) => {
    const w = world(on)
    await $.tool.call({ tool, channel_id: 'C1', message: `hi ${DASH} there` } as never)
    expect(w.reached).not.toContain(tool)
  })
}

test('when the scanner cannot run, the write goes through and says it was not checked', async ($, on) => {
  const w = world(on, { scanner: 'missing' })
  await $.tool.call({ tool: 'Write', file_path: '/repo/a.ts', content: BAD } as never)
  expect(w.reached).toContain('Write')
  expect([...w.logs, ...w.toasts].join('\n')).toMatch(/could not check/)
})

test('a chat reply carrying a dash gets a toast and is counted', async ($, on) => {
  const w = world(on)
  const row = (text: string) => ({
    door: 'response',
    origin: { kind: 'model', model: 'm' },
    uuid: 'r' + text.length,
    message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text }] },
  })
  on('session.append', ($, e, next) => next(e))
  const append = async (text: string) => {
    try {
      await $.session.append(row(text) as never)
    } catch (err) {
      if (!/no implementation for session.append/.test(String(err))) throw err
    }
  }
  await append(`a reply ${DASH} with a dash`)
  await append('a clean reply')
  await append(`another ${DASH} one`)
  expect(w.toasts.filter(t => /chat reply/.test(t)).length).toBe(2)
  // The count is kept in the mod's store across sessions; the second toast reads it back.
  expect(w.toasts.filter(t => /chat reply/.test(t))[1]).toContain('2 so far')
})
