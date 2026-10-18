import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { isDans } from './mod-kit/hooks/origin.ts'
import { offTheDialog } from '../hooks/register.ts'

// Picker manners (#615) leaves the asking to Claude Code's own dialog (#744, decided with Dan on
// 2026-10-05): its band question waited for a press through the mod's own $ noun, which Claude Code
// cuts off at 10 seconds in a live session, so the dialog then asked every question a second time.
// What the mod still does: one question per call, and next issue pickers off for the session on
// request, back with /pickers on.

const QUESTION = {
  question: "How long should the registry keep a closed session's record?",
  header: 'Retention',
  multiSelect: false,
  options: [
    { label: '1 day', description: 'Smallest folder, but a Friday session is gone by Monday.' },
    { label: '7 days', description: 'Covers a long weekend and a week away.' },
  ],
}

// mod-kit, standing in (#1135): whether a prompt is Dan's words is mod-kit's one answer. A plugin in a
// test runs in its own environment, so the stand-in asks the world (`__modkit`), which reads with a
// byte for byte copy of mod-kit's reader under tests/mod-kit, held to mod-kit's by
// tools/check-mod-shared-parts.sh. The kit's other members are never reached here.
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const isDans = async (input: unknown) => {
        // A mod-kit loaded before it had the reader (a reload can leave one, standing rule 5).
        if ((input as { origin?: { breaks?: true } }).origin?.breaks) throw new TypeError('$.modkit.isDans is not a function')
        const r = await built.process.run(['__modkit', 'isDans', JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout) as boolean
      }
      const modkit: Record<string, unknown> = { isDans }
      // #1299: a mod-kit loaded before it had a member, named by a plugin in the fold,
      // kit-lacks-<member in kebab case>, since this plugin runs apart from the test's module; the
      // call site then throws in the mod itself, as the runtime words it.
      for (const p of e.plugins) {
        const lacks = /^kit-lacks-([a-z-]+)$/.exec(p)?.[1]?.replace(/-([a-z])/g, (_m: string, c: string) => c.toUpperCase())
        if (lacks) delete (modkit as Record<string, unknown>)[lacks]
      }
      return { ...built, modkit: modkit as never }
    })
  },
}
const KIT = { plugins: [modKit] }
// #1299: the same, with a mod-kit loaded before it had isDans.
const OLD_KIT = { plugins: [modKit, { name: 'kit-lacks-is-dans', register: (() => undefined) as Register }] }

// Claude Code beneath the mod: its own question dialog, the transcript's dim lines, the memory
// section of the system prompt, and the commands registered.
const world = (on: On) => {
  const logs: string[] = []
  const reachedEngine: string[] = []
  on('tool.call', ($, e) => {
    reachedEngine.push(String(e.tool))
    return { result: { questions: [], answers: { engine: 'picker' } } } as never
  })
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('prompt.section', ($, e) => ({ text: e.text }))
  on('ui.invalidate', () => ({ value: undefined }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }) as never)
  on('ui.log', ($, e) => {
    logs.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  // mod-kit's reader, as the stand-in above asks it: mod-kit's own copy.
  on('process.run', ($, e) => {
    if (e.argv[0] !== '__modkit' || e.argv[1] !== 'isDans') throw new Error(`unexpected run: ${e.argv.join(' ')}`)
    const { origin } = JSON.parse(e.argv[2] as string)
    return { value: { exitCode: 0, stdout: JSON.stringify(isDans(origin)), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
  })
  return { logs, reachedEngine }
}

type T$ = {
  tool: { call: (e: never) => Promise<unknown> }
  prompt: { submit: (e: never) => Promise<unknown>; section: (e: never) => Promise<{ text: string | null }> }
  session: { start: (e: never) => Promise<unknown> }
  command: { run: (e: never) => Promise<unknown> }
}
type Answered = { result?: { answers: Record<string, string> }; deny?: string; text?: string }
const ask = ($: T$, q: object = QUESTION, extra: object = {}) => $.tool.call({ tool: 'AskUserQuestion', tool_use_id: 'q1', questions: [q], ...extra } as never) as Promise<Answered>
const type = ($: T$, text: string, kind: string | object = 'composer') => $.prompt.submit({ text, origin: typeof kind === 'string' ? { kind } : kind, wait: false } as never)
const memory = async ($: T$) => (await $.prompt.section({ name: 'memory', text: 'core memory' } as never)).text
const refused = (r: Answered) => r.deny ?? r.text

test("a question goes to Claude Code's own dialog, which asks it once", KIT, async ($, on) => {
  const w = world(on)
  const r = await ask($ as never)
  expect(r.result?.answers).toEqual({ engine: 'picker' })
  expect(w.reachedEngine).toEqual(['AskUserQuestion'])
})

// The limit on asking a question again counted Dan passing over it in the band (#703), which is
// gone, so nothing counts a pass. One counted by an earlier build and left in the session's state
// is never acted on: the question is asked (L377).
test('a question counted as talked past twice by an earlier build is still asked', KIT, async ($, on) => {
  const w = world(on)
  on('state.get', ($, e, next) => {
    if ((e as { key?: string }).key === 'passed') return { value: { value: [{ question: "how long should the registry keep a closed session s record", header: 'retention', count: 2 }], version: 2 } } as never
    return next(e)
  })
  const r = await ask($ as never)
  expect(r.result?.answers).toEqual({ engine: 'picker' })
  expect(w.reachedEngine).toEqual(['AskUserQuestion'])
})

test('more than one question in a call is refused, and so is none (one question per call)', KIT, async ($, on) => {
  const w = world(on)
  const two = (await $.tool.call({ tool: 'AskUserQuestion', questions: [QUESTION, QUESTION] } as never)) as Answered
  expect(refused(two)).toBe('Ask one question per call: Dan answers pickers one at a time.')
  const none = (await $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)) as Answered
  expect(refused(none)).toBe('Ask one question per call: Dan answers pickers one at a time.')
  expect(w.reachedEngine).toEqual([])
})

test('"no next issue" silences next issue pickers for the session, other pickers still ask, and /pickers on restores them', KIT, async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await type($ as never, 'no next issue, just stop there')
  expect(w.logs).toEqual(['Next issue pickers are off for this session; /pickers on brings them back.'])
  const offer = await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })
  expect(refused(offer)).toBe('Dan turned off next issue pickers for this session (/pickers on brings them back). Give the suggestions as a plain list instead.')
  expect(w.reachedEngine).toEqual([])
  // A hook driven picker (the end of turn issue review) still asks.
  expect((await ask($ as never, QUESTION, { metadata: { source: 'issue-review' } })).result?.answers).toEqual({ engine: 'picker' })
  expect(((await $.command.run({ command: 'pickers', args: 'on' } as never)) as { text?: string }).text).toBe('Next issue pickers are back on.')
  expect((await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })).result?.answers).toEqual({ engine: 'picker' })
  expect(w.reachedEngine).toEqual(['AskUserQuestion', 'AskUserQuestion'])
})

// #703: Dan's messages from his phone through Remote Control count as his own, as in every mod.
test('"just give me the list" from his phone counts as his own, and a peer session saying it does not', KIT, async ($, on) => {
  world(on)
  await type($ as never, 'just give me the list', 'peer')
  expect((await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })).result?.answers).toEqual({ engine: 'picker' })
  await type($ as never, 'just give me the list', 'bridge')
  expect(refused(await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } }))).toMatch(/^Dan turned off next issue pickers/)
})

// #1135: only what Dan types counts, at the Mac or from his phone, as in every mod (Dan, 2026-10-13):
// a handoff's opening prompt he pressed Use on is not his words, nor is a task notification.
for (const [who, origin, counts] of [
  ['typed at the terminal', { kind: 'composer' }, true],
  ['sent from his phone through Remote Control', { kind: 'bridge' }, true],
  ["a handoff's opening prompt he pressed Use on", { kind: 'plugin', name: 'handoff', asUser: true }, false],
  ['a background task notification', { kind: 'task-notification' }, false],
] as [string, object, boolean][]) {
  test(`"no next issue" ${who} ${counts ? 'turns next issue pickers off' : 'changes nothing'}`, KIT, async ($, on) => {
    const w = world(on)
    await type($ as never, 'no next issue', origin)
    const offer = await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })
    if (counts) expect(refused(offer)).toMatch(/^Dan turned off next issue pickers/)
    else expect(offer.result?.answers).toEqual({ engine: 'picker' })
    expect(w.logs.length).toBe(counts ? 1 : 0)
  })
}

test("a reader mod-kit cannot answer reads the message as not Dan's, said once, and his message still goes on", KIT, async ($, on) => {
  const w = world(on)
  for (let i = 0; i < 2; i++) expect(((await type($ as never, 'no next issue', { kind: 'composer', breaks: true })) as { text?: string }).text).toBe('no next issue')
  expect((await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })).result?.answers).toEqual({ engine: 'picker' })
  expect(w.logs.filter(l => l.includes('could not ask mod-kit whether your message was your own words')).length).toBe(1)
})

// #1299: a mod-kit older than picker manners, with no isDans: the note says the two mods are out of
// step, in the one sentence, never the raw TypeError.
test('a mod-kit with no isDans is said as out of step, never as a TypeError (#1299)', OLD_KIT, async ($, on) => {
  const w = world(on)
  expect(((await type($ as never, 'no next issue', { kind: 'composer' })) as { text?: string }).text).toBe('no next issue')
  const note = w.logs.find(l => l.includes('could not ask mod-kit whether your message was your own words')) ?? ''
  expect(note).toContain('picker-manners and mod-kit are out of step in this session: the mod-kit loaded here has no isDans')
  expect(note).not.toContain('is not a function')
})

test('/pickers with anything but on changes nothing and says what it understands', KIT, async ($, on) => {
  world(on)
  await type($ as never, 'no next issue')
  expect(((await $.command.run({ command: 'pickers', args: 'off' } as never)) as { text?: string }).text).toBe('/pickers on brings next issue pickers back; nothing else is understood.')
  expect(refused(await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } }))).toMatch(/^Dan turned off next issue pickers/)
})

// #703: CLAUDE.md's keep the issue loop moving rule has Claude offer next issues as a picker, and an
// offer made from that rule carries no next-issue tag for the refusal to see. Claude's system prompt
// says pickers are off for as long as they are, so the rule is overridden for the session (spec #615
// point 4), and says nothing once /pickers on brings them back.
test('while next issue pickers are off, the system prompt tells Claude so, and stops once /pickers on brings them back', KIT, async ($, on) => {
  world(on)
  expect(await memory($ as never)).toBe('core memory')
  await type($ as never, 'just give me the list')
  const section = String(await memory($ as never))
  expect(section).toMatch(/^core memory\n\n/)
  expect(section).toContain('Dan turned off next issue pickers for this session')
  expect(section).toContain('never as a picker')
  await $.command.run({ command: 'pickers', args: 'on' } as never)
  expect(await memory($ as never)).toBe('core memory')
})

// #1279, Dan 2026-10-17: a question Dan is asked about an issue is added to that issue's Open
// questions section, checked off with his answer when he gave one, so /sleep never asks it again and
// asks one he did not answer. The issue is named as owner/name#N, or issue #N in this session's
// repository; GitHub is asked through gh, after the dialog has answered, off its path.
const kitWithRepo: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return { ...built, modkit: { isDans: async () => false, repo: async () => ({ github: 'o/r', name: 'r' }) } as never }
    })
  },
}
type IssueWorld = { bodies: Record<number, string>; edits: { issue: number; repo: string; body: string }[]; logs: string[]; viewFails?: string; editFails?: string; noRepo?: boolean; onlyAccount?: string; pulls?: number[]; settle: () => Promise<void> }
const issueWorld = (on: On, answer: string | string[] | null, bodies: Record<number, string> = {}): IssueWorld => {
  const clock = mock.clock(on, { now: 0 })
  const w: IssueWorld = { bodies: { ...bodies }, edits: [], logs: [], settle: () => clock.settle() }
  on('tool.call', ($, e) => {
    const q = String((e as unknown as { questions: { question: string }[] }).questions[0]?.question)
    return { result: { questions: [], answers: answer === null ? {} : { [q]: answer } }, text: 'answered' } as never
  })
  on('session.repo', () => ({ value: w.noRepo ? null : { root: '/repo', remote: 'git@github.com:o/r.git', internal: false, name: null } }) as never)
  on('ui.log', ($, e) => {
    w.logs.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  const ok = (stdout = '') => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never
  const fail = (stderr: string) => ({ value: { exitCode: 1, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false } }) as never
  on('process.run', ($, e) => {
    const a = e.argv
    const env = (e as unknown as { init?: { env?: Record<string, string> } }).init?.env
    // Only one account can see the repository: the active one is told it does not exist.
    if (a[0] === 'gh' && a[1] === 'auth' && a[2] === 'status') return ok(`  Logged in to github.com account dan-personal\n  Logged in to github.com account ${w.onlyAccount ?? 'dan-personal'}\n`)
    if (a[0] === 'gh' && a[1] === 'auth' && a[2] === 'token') return ok(`tok-${a[4]}\n`)
    if (a[0] === 'gh' && a[1] === 'issue' && w.onlyAccount && env?.GH_TOKEN !== `tok-${w.onlyAccount}`) return fail('GraphQL: Could not resolve to a Repository with the name o/r')
    if (a[0] === 'gh' && a[1] === 'issue' && a[2] === 'view') {
      if (w.viewFails) return fail(w.viewFails)
      const n = Number(a[3])
      // gh issue view answers for a pull request's number too, with its pull link.
      return ok(JSON.stringify({ state: 'OPEN', body: w.bodies[n] ?? '', url: `https://github.com/o/r/${w.pulls?.includes(n) ? 'pull' : 'issues'}/${n}` }))
    }
    if (a[0] === 'gh' && a[1] === 'issue' && a[2] === 'edit') {
      if (w.editFails) return fail(w.editFails)
      const body = String((e as unknown as { init?: { stdin?: string } }).init?.stdin ?? '')
      w.edits.push({ issue: Number(a[3]), repo: String(a[a.indexOf('--repo') + 1]), body })
      w.bodies[Number(a[3])] = body
      return ok()
    }
    throw new Error(`unexpected run: ${a.join(' ')}`)
  })
  return w
}
const askAbout = ($: T$, question: string) => $.tool.call({ tool: 'AskUserQuestion', tool_use_id: 'q2', questions: [{ ...QUESTION, question }] } as never) as Promise<Answered>
const SECTION = 'The bug.\n\n## Open questions\n\nNone'

test('a question about an issue Dan answers is added to its Open questions, checked off with the answer (#1279)', { plugins: [kitWithRepo] }, async ($, on) => {
  const w = issueWorld(on, '7 days', { 7: SECTION })
  const r = await askAbout($ as never, 'For o/r#7, how long should the registry keep a record?')
  expect(r.result?.answers).toEqual({ 'For o/r#7, how long should the registry keep a record?': '7 days' })
  await w.settle()
  expect(w.edits).toEqual([{ issue: 7, repo: 'o/r', body: 'The bug.\n\n## Open questions\n\n- [x] For o/r#7, how long should the registry keep a record? (answered 1969-12-31 ET: 7 days)' }])
})

// Lessons review: a multi-select answer arrives as a list, and is an answer all the same.
test('a question answered with several choices is checked off with all of them (#1279)', { plugins: [kitWithRepo] }, async ($, on) => {
  const w = issueWorld(on, ['Retention', 'Archive'], { 7: SECTION })
  await askAbout($ as never, 'For o/r#7, which parts?')
  await w.settle()
  expect(w.edits.map(x => x.body)).toEqual(['The bug.\n\n## Open questions\n\n- [x] For o/r#7, which parts? (answered 1969-12-31 ET: Retention, Archive)'])
})

test("one he did not answer is added open, and issue #N is read in the session's repository (#1279)", { plugins: [kitWithRepo] }, async ($, on) => {
  const w = issueWorld(on, null, { 12: SECTION })
  await askAbout($ as never, 'Skip design rounds for issue #12?')
  await w.settle()
  expect(w.edits).toEqual([{ issue: 12, repo: 'o/r', body: 'The bug.\n\n## Open questions\n\n- [ ] Skip design rounds for issue #12?' }])
})

// #1299 (lessons review): a mod-kit loaded before it had repo cannot say the session's repository; the
// note says the two mods are out of step, never the raw TypeError.
const kitWithoutRepo: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return { ...built, modkit: { isDans: async () => false } as never }
    })
  },
}
test("a mod-kit with no repo is said as out of step when issue #N's Open questions cannot be found (#1299)", { plugins: [kitWithoutRepo] }, async ($, on) => {
  const w = issueWorld(on, null, { 12: SECTION })
  await askAbout($ as never, 'Skip design rounds for issue #12?')
  await w.settle()
  expect(w.edits).toEqual([])
  const note = w.logs.find(l => l.includes("issue #12's Open questions")) ?? ''
  expect(note).toContain("this session's repository could not be read: picker-manners and mod-kit are out of step in this session: the mod-kit loaded here has no repo")
  expect(note).not.toContain('is not a function')
})

test('a question naming no issue, or only a bare #N, touches no issue; one /sleep asked is recorded by its own words (#1279)', { plugins: [kitWithRepo] }, async ($, on) => {
  const w = issueWorld(on, 'Yes', { 7: 'B\n\n## Open questions\n\n- [ ] Keep the old flag?' })
  await askAbout($ as never, 'Merge PR #31?')
  await askAbout($ as never, 'Which approach do you prefer?')
  await w.settle()
  expect(w.edits).toEqual([])
  await askAbout($ as never, 'o/r#7: Keep the old flag?')
  await w.settle()
  expect(w.edits.map(x => x.body)).toEqual(['B\n\n## Open questions\n\n- [x] Keep the old flag? (answered 1969-12-31 ET: Yes)'])
})

// Lessons review: Dan's work repositories are visible only to his work account, so GitHub is asked as
// each account gh is logged in to, as /sleep asks, through the one helper.
test('an issue only another gh account can see is still recorded (#1279)', { plugins: [kitWithRepo] }, async ($, on) => {
  const w = issueWorld(on, 'Yes', { 7: SECTION })
  w.onlyAccount = 'dan-work'
  await askAbout($ as never, 'For o/r#7, ship it?')
  await w.settle()
  expect(w.edits.map(x => x.body)).toEqual(['The bug.\n\n## Open questions\n\n- [x] For o/r#7, ship it? (answered 1969-12-31 ET: Yes)'])
})

// Lessons review: gh issue view and gh issue edit both take a pull request's number, so a question
// naming one would rewrite the pull request's description. Its link says what it is.
test('a question naming a pull request leaves the pull request alone (#1279)', { plugins: [kitWithRepo] }, async ($, on) => {
  const w = issueWorld(on, 'Yes', { 31: 'The change.' })
  w.pulls = [31]
  await askAbout($ as never, 'Merge o/r#31 now?')
  await w.settle()
  expect(w.edits).toEqual([])
  expect(w.logs).toEqual([])
})

test('issue #N whose repository cannot be told is said, never dropped silently (#1279)', { plugins: [kitWithRepo] }, async ($, on) => {
  const w = issueWorld(on, 'Yes', { 12: SECTION })
  w.noRepo = true
  await askAbout($ as never, 'Skip design rounds for issue #12?')
  await w.settle()
  expect(w.edits).toEqual([])
  expect(w.logs).toContain("Picker manners could not add this question to issue #12's Open questions (this session is in no repository GitHub knows), so /sleep will not see it there.")
  // Said by the same rule that reads the references, so what is not an issue number is not said.
  w.logs.length = 0
  await askAbout($ as never, 'Is issue #34abc still wanted?')
  await w.settle()
  expect(w.logs).toEqual([])
})

test('whatever escapes the work done off the dialog is said, never left unhandled (#1279 lessons review)', async () => {
  // Only the two nouns it uses: the scheduled work runs at once, and the first transcript line ends
  // the wait, so a missing catch fails as an unhandled rejection rather than a timed guess.
  let logged: (text: string) => void = () => {}
  const line = new Promise<string>(r => (logged = r))
  const stand = { clock: { after: (_ms: number, fn: () => void) => fn() }, ui: { log: (text: string) => logged(text) } }
  offTheDialog(stand as never, () => Promise.reject(new Error('the body could not be built')))
  expect(await line).toBe("Picker manners could not add this question to its issue's Open questions (the body could not be built), so /sleep will not see it there.")
})

test('an issue that cannot be read or written is said, and the answer still reaches Claude (#1279)', { plugins: [kitWithRepo] }, async ($, on) => {
  const w = issueWorld(on, '7 days', { 7: SECTION })
  w.viewFails = 'HTTP 502'
  const r = await askAbout($ as never, 'For o/r#7, keep it?')
  expect(r.result?.answers).toEqual({ 'For o/r#7, keep it?': '7 days' })
  await w.settle()
  expect(w.logs).toContain("Picker manners could not add this question to o/r#7's Open questions (HTTP 502), so /sleep will not see it there.")
  w.viewFails = undefined
  w.editFails = 'HTTP 403'
  await askAbout($ as never, 'For o/r#7, ship it?')
  await w.settle()
  expect(w.logs).toContain("Picker manners could not add this question to o/r#7's Open questions (HTTP 403), so /sleep will not see it there.")
})
