import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

const OVERTURE = '/Applications/Overture.app/Contents/MacOS/Overture'
const DEBUG = '/Users/x/Build/Debug/Overture.app/Contents/MacOS/Overture'
const LIGHTROOM = '/Applications/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic'
const KEYWORD = 'key' + 'stroke'

type World = { front: number; running: Record<number, string>; answer: string | 'dismiss' }
type Card = { toolUseId: string; guard: string; reason: string; safeWay?: string }

const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
const none = { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }

// A stand-in for mod-kit: an inline plugin cannot reach this file's variables, so it reports each
// card as a transcript line the world collects.
const kit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return { ...built, modkit: { blocked: (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)) } }
    })
  },
}
const withKit = { plugins: [kit] }

// The Mac beneath the mod: which processes run at which path, which is frontmost, and what Dan
// answers. Each tool call that gets past the mod is recorded, and so is each question asked.
const world = (on: On, w: World) => {
  const reached: string[] = []
  const asked: { question: string; header: string; options: string[] }[] = []
  const toasts: string[] = []
  const cards: Card[] = []
  on('process.run', ($, e) => {
    const [cmd, ...args] = e.argv
    if (cmd === 'pgrep' && args[0] === '-f') {
      const pids = Object.entries(w.running).filter(([, p]) => p.includes(args[1] ?? '')).map(([pid]) => pid)
      return pids.length ? ok(pids.join('\n') + '\n') : none
    }
    if (cmd === 'pgrep' && args[0] === '-x') {
      // As macOS does: the process name it matches is cut to 16 characters (lessons review).
      const pids = Object.entries(w.running).filter(([, p]) => (p.split('/').pop() ?? '').slice(0, 16) === (args[1] ?? '')).map(([pid]) => pid)
      return pids.length ? ok(pids.join('\n') + '\n') : none
    }
    if (cmd === 'ps' && args.includes('-axo')) {
      return ok(Object.entries(w.running).map(([pid, p]) => `${pid} ${p}`).join('\n') + '\n')
    }
    if (cmd === 'ps') return ok((w.running[Number(args[args.length - 1])] ?? '') + '\n')
    if (cmd === 'osascript') return ok(`${w.front}\n`)
    return none
  })
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e) => {
    const qs = (e as unknown as { questions: { question: string; header: string; options: { label: string }[] }[] }).questions
    const q = qs[0]
    asked.push({ question: q?.question ?? '', header: q?.header ?? '', options: (q?.options ?? []).map(o => o.label) })
    if (w.answer === 'dismiss') return { deny: 'dismissed' } as never
    // The tool's own result: answers keyed by each question's text, as the dialog records them.
    return { result: { questions: qs, answers: { [q?.question ?? '']: w.answer } }, text: `"${q?.question}"="${w.answer}"` } as never
  })
  on('tool.call', ($, e) => {
    reached.push(e.tool)
    return { result: 'ran', text: 'ran' } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('CARD ')) cards.push(JSON.parse(e.text.slice(5)))
    return { value: undefined }
  })
  return { reached, asked, toasts, cards }
}

const KEY = `TARGET_APP=${OVERTURE} osascript -e 'tell application "System Events" to ${KEYWORD} "n" using command down'`
const bash = (command: string, id = 't1') => ({ tool: 'Bash', command, tool_use_id: id }) as never
const refusal = (r: unknown) => {
  const x = r as { deny?: string; text?: string }
  return x.deny ?? x.text ?? ''
}

test('an undeclared target is refused before anyone is asked', withKit, async ($, on) => {
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  const r = await $.tool.call(bash(`osascript -e 'tell application "System Events" to ${KEYWORD} "n"'`))
  expect(w.reached).not.toContain('Bash')
  expect(w.asked.length).toBe(0)
  expect(refusal(r)).toBe("Blocked: This doesn't say which app it types into. Add TARGET_APP=<the app's executable path> to the command.")
})

test('the right app, frontmost and alone, gets the agreed question once and then runs', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  await $.tool.call(bash(KEY))
  expect(w.asked).toEqual([{ question: "I'm about to type into Overture. Ready?", header: 'Taking over', options: ['Go ahead', 'Not now'] }])
  expect(w.reached).toContain('Bash')
})

test('a wrong frontmost app is refused, with the card and a toast', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 77, running: { 10: OVERTURE, 77: LIGHTROOM }, answer: 'Go ahead' })
  const r = await $.tool.call(bash(KEY, 'w1'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe("Blocked: Overture isn't the front app (Adobe Lightroom Classic is). Bring it forward first, then type.")
  expect(w.cards).toEqual([
    { toolUseId: 'w1', guard: 'Keystroke guard', reason: "Overture isn't the front app (Adobe Lightroom Classic is).", safeWay: 'Bring it forward first, then type.' },
  ])
  expect(w.toasts).toContain('Blocked typing into Overture.')
})

test('two copies of an app with a long name are refused too (lessons review)', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const OTHER_LR = '/Users/x/Beta/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic'
  const w = world(on, { front: 10, running: { 10: LIGHTROOM, 11: OTHER_LR }, answer: 'Go ahead' })
  await $.tool.call(bash(`TARGET_APP="${LIGHTROOM}" cliclick c:1,1`))
  expect(w.reached).not.toContain('Bash')
})

test('two running copies of the app are refused', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE, 11: DEBUG }, answer: 'Go ahead' })
  await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
})

test('a declined heads up refuses the action', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'Not now' })
  const r = await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe('Blocked: You said not now to typing into Overture.')
})

test('a dismissed heads up refuses the action', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'dismiss' })
  const r = await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe('Blocked: The question about Overture was dismissed.')
})

test('a yes holds while input keeps coming, and lapses after 10 quiet minutes', withKit, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
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

test('a focus stealer gets the agreed question but no process check', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  // Two copies running and the wrong app frontmost: a full check would refuse this.
  const w = world(on, { front: 77, running: { 10: OVERTURE, 11: DEBUG }, answer: 'Go ahead' })
  await $.tool.call(bash('open -a "Google Chrome" report.html'))
  expect(w.asked).toEqual([{ question: "I'm about to bring Google Chrome to the front. Ready?", header: 'Taking over', options: ['Go ahead', 'Not now'] }])
  expect(w.reached).toContain('Bash')
})

test('a declined focus stealer says so in its own words', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: {}, answer: 'Not now' })
  const r = await $.tool.call(bash('open -a "Google Chrome" report.html'))
  expect(refusal(r)).toBe('Blocked: You said not now to bringing Google Chrome to the front.')
  expect(w.toasts).toContain('Blocked bringing Google Chrome to the front.')
})

test('an ordinary command is not asked about', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: {}, answer: 'Go ahead' })
  await $.tool.call(bash('git status'))
  expect(w.asked.length).toBe(0)
  expect(w.reached).toContain('Bash')
})

test('a yes for an app it cannot name covers nothing else (lessons review)', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: {}, answer: 'Go ahead' })
  // An activate with no app named: the guard cannot say which app comes forward.
  await $.tool.call(bash(`osascript -e 'activate'`, 'u1'))
  await $.tool.call(bash(`osascript -e 'activate'`, 'u2'))
  expect(w.asked.length).toBe(2)
})

test('Chrome extension tools are left alone', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { front: 10, running: {}, answer: 'Go ahead' })
  await $.tool.call({ tool: 'mcp__claude-in-chrome__computer', action: 'left_click' } as never)
  expect(w.asked.length).toBe(0)
  expect(w.reached).toContain('mcp__claude-in-chrome__computer')
})
