import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const OVERTURE = '/Applications/Overture.app/Contents/MacOS/Overture'
const DEBUG = '/Users/x/Build/Debug/Overture.app/Contents/MacOS/Overture'

type World = { front: number; running: Record<number, string>; answer: string | 'dismiss' }

const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
const none = { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }

// The Mac beneath the mod: which processes run at which path, which is frontmost, and what Dan
// answers. Each tool call that gets past the mod is recorded, and so is each question asked.
const world = (on: On, w: World) => {
  const reached: string[] = []
  const asked: string[] = []
  on('process.run', ($, e) => {
    const [cmd, ...args] = e.argv
    if (cmd === 'pgrep' && args[0] === '-f') {
      const pids = Object.entries(w.running).filter(([, p]) => p.includes(args[1] ?? '')).map(([pid]) => pid)
      return pids.length ? ok(pids.join('\n') + '\n') : none
    }
    if (cmd === 'pgrep' && args[0] === '-x') {
      const pids = Object.entries(w.running).filter(([, p]) => p.endsWith('/' + (args[1] ?? ''))).map(([pid]) => pid)
      return pids.length ? ok(pids.join('\n') + '\n') : none
    }
    if (cmd === 'ps') return ok((w.running[Number(args[args.length - 1])] ?? '') + '\n')
    if (cmd === 'osascript') return ok(`${w.front}\n`)
    return none
  })
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e) => {
    asked.push(JSON.stringify(e))
    if (w.answer === 'dismiss') return { deny: 'dismissed' } as never
    // The tool's own result: answers keyed by each question's text, as the dialog records them.
    const qs = (e as unknown as { questions: { question: string }[] }).questions
    const q = qs[0]?.question ?? ''
    return { result: { questions: qs, answers: { [q]: w.answer } }, text: `"${q}"="${w.answer}"` } as never
  })
  on('tool.call', ($, e) => {
    reached.push(e.tool)
    return { result: 'ran', text: 'ran' } as never
  })
  on('ui.toast', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  return { reached, asked }
}

const KEY = `TARGET_APP=${OVERTURE} osascript -e 'tell application "System Events" to keystroke "n" using command down'`
const bash = (command: string) => ({ tool: 'Bash', command }) as never

test('an undeclared target is refused before anyone is asked', async ($, on) => {
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'Ready' })
  await $.tool.call(bash(`osascript -e 'tell application "System Events" to keystroke "n"'`))
  expect(w.reached).not.toContain('Bash')
  expect(w.asked.length).toBe(0)
})

test('the right app, frontmost and alone, gets one heads up and then runs', async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'Ready' })
  await $.tool.call(bash(KEY))
  expect(w.asked.length).toBe(1)
  expect(w.asked[0]).toContain('Overture')
  expect(w.reached).toContain('Bash')
})

test('a wrong frontmost app is refused', async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 77, running: { 10: OVERTURE, 77: '/Applications/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic' }, answer: 'Ready' })
  await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
})

test('two running copies of the app are refused', async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE, 11: DEBUG }, answer: 'Ready' })
  await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
})

test('a declined heads up refuses the action', async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'Not now' })
  await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
})

test('a dismissed heads up refuses the action', async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'dismiss' })
  await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
})

test('a yes holds while input keeps coming, and lapses after 10 quiet minutes', async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'Ready' })
  await $.tool.call(bash(KEY))
  await clock.advance(9 * 60_000)
  await $.tool.call(bash(KEY))
  await clock.advance(9 * 60_000)
  await $.tool.call(bash(KEY))
  expect(w.asked.length).toBe(1)
  await clock.advance(10 * 60_000 + 1)
  await $.tool.call(bash(KEY))
  expect(w.asked.length).toBe(2)
})

test('a focus stealer gets the heads up but no process check', async ($, on) => {
  mock.clock(on, { now: 0 })
  // Two copies running and the wrong app frontmost: a full check would refuse this.
  const w = world(on, { front: 77, running: { 10: OVERTURE, 11: DEBUG }, answer: 'Ready' })
  await $.tool.call(bash(`osascript -e 'tell application "Overture" to activate'`))
  expect(w.asked.length).toBe(1)
  expect(w.reached).toContain('Bash')
})

test('an ordinary command is not asked about', async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: {}, answer: 'Ready' })
  await $.tool.call(bash('git status'))
  expect(w.asked.length).toBe(0)
  expect(w.reached).toContain('Bash')
})

test('Chrome extension tools are left alone', async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: {}, answer: 'Ready' })
  await $.tool.call({ tool: 'mcp__claude-in-chrome__computer', action: 'left_click' } as never)
  expect(w.asked.length).toBe(0)
  expect(w.reached).toContain('mcp__claude-in-chrome__computer')
})
