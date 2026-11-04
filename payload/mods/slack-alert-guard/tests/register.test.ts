import { expect, mock, type Engine } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { EngineInterface, On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { APPROVE, CHANGE, HEADER, wordingKey } from '../hooks/rules.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { pythonText } from './mod-kit/hooks/code.ts'
import { type TypedAnswer, typedAnswerText, typedToast } from './mod-kit/hooks/typed.ts'
import { reasonOf, standInCore } from './mod-kit/tests/core.ts'

// The Slack alert guard (claude-config#2242) in a session. Dan, 2026-11-04: "anytime a slack alert
// is created, we need to have a design-rounds esque check on wording so I can approve the wording
// before it's created". An edit that changes the words a Slack posting file sends waits until Dan has
// seen the message as Slack will post it and answered Approve wording in Claude Code's own dialog.

// mod-kit, standing in: a mod cannot import another mod's files, so the write reader, the python text
// reader and the typed answer wording are byte for byte copies under tests/mod-kit, asked through the
// world (`__modkit`).
type Kit = EngineInterface['modkit']
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ask = async (method: string, input: unknown) => {
        const r = await built.process.run(['__modkit', method, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout)
      }
      // Only the members the guard calls are stood in; any other it ever reached would be undefined
      // and throw, which every test here would show as a refusal it did not expect.
      const modkit: Pick<Kit, 'writes' | 'pythonText' | 'blocked' | 'typedAnswer'> = {
        writes: async (input: { command: string; cwd: string; home: string }) => ask('writes', input),
        pythonText: async (input: { code: string }) => ask('pythonText', input),
        blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
        typedAnswer: async (input: TypedAnswer) => {
          const said = (await ask('typedAnswer', input)) as { toast: string; text: string }
          await built.ui.toast(said.toast)
          return said.text
        },
      }
      return { ...built, modkit: modkit as Kit }
    })
  },
}
// Claude Code's built-in security default, standing in, so no test passes on a hook that never runs.
const secDefault: { name: string; tier: 'prepend'; register: Register } = {
  name: 'sec-default-stand-in',
  tier: 'prepend',
  register: on => {
    on('classic.*', ($, e, next) => next.to(e, 'append'))
  },
}
const withKit = { plugins: [secDefault, modKit] }

const HOME = '/Users/dan'
const T0 = Date.UTC(2026, 10, 4, 15, 0, 0)
const STORE = `${HOME}/.claude/plugins/store/slack-alert-guard_inline-ab12cd34ef56.json`
// A file that posts to Slack, and one that does not.
const ALERT = '/w/app/lib/alert.ts'
const ALERT_TEXT = 'export const alert = (id: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: "POST", body: JSON.stringify({ text: `Deploy ${id} failed` }) })\n'
const PLAIN = '/w/app/lib/date.ts'

type Asked = { questions: { question: string; header: string; options: { label: string; description?: string }[]; multiSelect: boolean }[]; metadata?: Record<string, unknown> }
const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never

const world = (engine: Engine, on: On, init: { files?: Record<string, string> } = {}) => {
  const files: Record<string, string> = { [ALERT]: ALERT_TEXT, [PLAIN]: 'export const x = 1\n', ...(init.files ?? {}) }
  const store: Record<string, unknown> = {}
  const ctl = { storeGetFails: false, storeSetFails: false, unreadable: '' }
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const asked: Asked[] = []
  const dialog: { answer?: string; afk?: boolean } = {}
  const cards: Record<string, unknown>[] = []
  const toasts: string[] = []
  mock.clock(on, { now: T0 })
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : undefined }) as never)
  on('session.cwd', () => ({ value: '/w/app' }) as never)
  on('session.id', () => ({ value: 's1' }) as never)
  on('process.run', async ($, e) => {
    const [cmd, method, raw] = e.argv.map(String)
    if (cmd === '__modkit' && method === 'writes') {
      const input = JSON.parse(String(raw)) as { command: string; cwd: string; home: string }
      return ok(JSON.stringify(commandWrites(input.command, input.cwd, input.home)))
    }
    if (cmd === '__modkit' && method === 'pythonText') return ok(JSON.stringify(pythonText(JSON.parse(String(raw)).code)))
    if (cmd === '__modkit' && method === 'typedAnswer') {
      const input = JSON.parse(String(raw)) as TypedAnswer
      return ok(JSON.stringify({ toast: typedToast(input.guard), text: typedAnswerText(input) }))
    }
    throw new Error(`unexpected command: ${e.argv.join(' ')}`)
  })
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }) as never)
  on('fs.read', ($, e) => {
    if (ctl.unreadable === e.path) throw new Error(`EACCES: ${e.path}`)
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: t } as never
  })
  on('store.get', ($, e) => {
    if (ctl.storeGetFails) throw new Error('the store could not be read')
    return { value: store[e.key] } as never
  })
  on('store.set', ($, e) => {
    if (ctl.storeSetFails) throw new Error('disk full')
    store[e.key] = e.value
    return { value: undefined } as never
  })
  on('ui.log', ($, e) => {
    const text = String((e as { text?: string }).text ?? '')
    if (text.startsWith('CARD ')) cards.push(JSON.parse(text.slice(5)))
    return { value: undefined } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text ?? ''))
    return { value: undefined } as never
  })
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  const core = standInCore(engine, on)
  on('tool.call', async ($, e) => {
    const c = await core(e)
    if ('refused' in c) return c.refused as never
    const { tool, input } = c.call
    if (tool === 'AskUserQuestion') {
      const a = input as unknown as Asked
      asked.push(a)
      const q = a.questions[0]?.question ?? ''
      const result = { questions: a.questions, answers: dialog.answer === undefined ? {} : { [q]: dialog.answer }, ...(dialog.afk ? { afkTimeoutMs: 60_000 } : {}) }
      return { result, text: `User has answered: ${dialog.answer ?? ''}` } as never
    }
    ran.push({ tool: String(tool), input })
    if (tool === 'Write') files[String(input.file_path)] = String(input.content)
    return { result: 'written', text: 'written' } as never
  })
  return { files, store, ctl, ran, asked, dialog, cards, toasts }
}
type W = ReturnType<typeof world>

type Caller = { tool: { call: (e: never) => Promise<unknown> } }
type Result = { deny?: string; text?: string; isError?: boolean; context?: readonly string[] }
let calls = 0
const call = async ($: Caller, input: Record<string, unknown>) => (await $.tool.call({ tool_use_id: `t${++calls}`, ...input } as never)) as Result
const refusalOf = (r: Result) => (r.deny !== undefined || r.isError ? reasonOf(r, 'slack-alert-guard') : '')
const contextOf = (r: Result) => (r.context ?? []).join('\n')
const idIn = (refusal: string) => /slack-alert-guard:(t\d+)/.exec(refusal)?.[1]

// An edit giving the alert new wording, and the message as Slack would post it.
const REWORD = { tool: 'Edit', file_path: ALERT, old_string: 'Deploy ${id} failed', new_string: 'Deploy ${id} failed on production' }
const SHOWN = 'Deploy 4182 failed on production'
const ask = async ($: Caller, w: W, refusal: string, answer: string | undefined, metadata: Record<string, unknown> = { rendered: SHOWN }, extra: Record<string, unknown> = {}) => {
  const id = idIn(refusal)
  if (!id) throw new Error(`no refused call named in: ${refusal}`)
  w.dialog.answer = answer
  return call($, {
    tool: 'AskUserQuestion',
    questions: [{ question: 'Approve this wording?', header: 'x', options: [{ label: 'Yes', description: 'y' }, { label: 'No', description: 'n' }], multiSelect: false }],
    metadata: { source: `slack-alert-guard:${id}`, ...metadata },
    ...extra,
  })
}

test('an edit to a file that posts to Slack, touching no message text, passes; so does any edit to a file that posts nothing', withKit, async ($, on) => {
  const w = world($, on)
  expect(refusalOf(await call($, { tool: 'Edit', file_path: ALERT, old_string: 'method: "POST"', new_string: 'method: "PUT"' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Write', file_path: PLAIN, content: 'export const msg = "Deploy failed on production"\n' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/app/README.md', content: 'Posts "Deploy failed" to hooks.slack.com\n' }))).toBe('')
  expect(w.ran.length).toBe(3)
  expect(w.cards).toEqual([])
  // The same file with its wording changed is held, so the passes above are the guard deciding,
  // never a guard that judges nothing.
  expect(refusalOf(await call($, REWORD))).toContain(ALERT)
  expect(w.ran.length).toBe(3)
})

test('new wording in a Slack alert is held until Dan approves the message as Slack will post it, then goes through', withKit, async ($, on) => {
  const w = world($, on)
  const r = await call($, REWORD)
  const why = refusalOf(r)
  expect(why).toContain(ALERT)
  expect(why).toContain('Deploy ${id} failed on production')
  expect(why).toContain('"rendered"')
  expect(why).toContain('realistic example')
  expect(w.ran).toEqual([])
  expect(w.cards.length).toBe(1)
  const a = await ask($, w, why, APPROVE)
  // The guard words the question, with the message itself in it, and his choice decides.
  expect(w.asked[0]?.questions[0]?.question).toContain(SHOWN)
  expect(w.asked[0]?.questions[0]?.header).toBe(HEADER)
  expect(w.asked[0]?.questions[0]?.options.map(o => o.label)).toEqual([APPROVE, CHANGE])
  expect(contextOf(a)).toContain('again')
  expect(w.store[wordingKey('Deploy ${id} failed on production')]).toBeDefined()
  const again = await call($, REWORD)
  expect(refusalOf(again)).toBe('')
  expect(w.ran.length).toBe(1)
})

test('approval follows the wording, not the file: a test repeating approved wording passes, new wording in a test is held', withKit, async ($, on) => {
  const w = world($, on)
  w.store[wordingKey('Deploy ${id} failed on production')] = { at: T0, file: ALERT, text: ['Deploy ${id} failed on production'], rendered: SHOWN }
  const TEST = '/w/app/lib/alert.test.ts'
  const same = { tool: 'Write', file_path: TEST, content: 'import { sendSlackAlert } from "./alert"\nexpect(sent).toBe(`Deploy ${id} failed on production`)\n' }
  expect(refusalOf(await call($, same))).toBe('')
  const fresh = { tool: 'Write', file_path: TEST, content: 'import { sendSlackAlert } from "./alert"\nexpect(sent).toBe("Backup is late again")\n' }
  expect(refusalOf(await call($, fresh))).toContain('Backup is late again')
})

test('changing approved wording is held again, and taking message text away is held too', withKit, async ($, on) => {
  const w = world($, on)
  w.store[wordingKey('Deploy ${id} failed')] = { at: T0, file: ALERT, text: ['Deploy ${id} failed'], rendered: 'Deploy 1 failed' }
  expect(refusalOf(await call($, { ...REWORD, new_string: 'Deploy ${id} failed!' }))).toContain('Deploy ${id} failed!')
  const gone = refusalOf(await call($, { tool: 'Edit', file_path: ALERT, old_string: '`Deploy ${id} failed`', new_string: 'id' }))
  expect(gone).toContain('takes Slack message text away')
  expect(w.ran).toEqual([])
})

test('the question is refused unless it is the real message, asked of Dan with nothing filled in', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, REWORD))
  expect(refusalOf(await ask($, w, why, APPROVE, {}))).toContain('"rendered"')
  expect(refusalOf(await ask($, w, why, APPROVE, { rendered: 'Deploy ${id} failed on production' }))).toContain('${id}')
  expect(refusalOf(await ask($, w, why, APPROVE, { rendered: 'Deploy 4182 failed' }))).toContain('failed on production')
  expect(refusalOf(await ask($, w, why, APPROVE, { rendered: SHOWN }, { answers: { q: APPROVE } }))).toContain('without answers')
  expect(refusalOf(await ask($, w, why, APPROVE, { rendered: SHOWN }, { agentId: 'agent-a1' }))).toContain('main session')
  expect(refusalOf(await call($, { tool: 'AskUserQuestion', questions: [{ question: 'x', header: 'x', options: [], multiSelect: false }], metadata: { source: 'slack-alert-guard:t999', rendered: SHOWN } }))).toContain('No Slack alert edit is waiting')
  expect(w.asked).toEqual([])
  expect(Object.keys(w.store)).toEqual([])
})

test('Change wording, a typed answer, or no answer records nothing, and the edit stays held', withKit, async ($, on) => {
  const w = world($, on)
  let why = refusalOf(await call($, REWORD))
  expect(contextOf(await ask($, w, why, CHANGE))).toContain(CHANGE)
  why = refusalOf(await call($, REWORD))
  expect(contextOf(await ask($, w, why, 'make it shorter'))).toContain('make it shorter')
  expect(w.toasts.length).toBe(1)
  why = refusalOf(await call($, REWORD))
  w.dialog.afk = true
  expect(contextOf(await ask($, w, why, APPROVE))).toContain('did not answer')
  expect(Object.keys(w.store)).toEqual([])
  expect(refusalOf(await call($, REWORD))).toContain('Blocked')
})

test("a subagent's edit is refused and told to stop and report, never to ask Dan", withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, { ...REWORD, agentId: 'agent-a1' }))
  expect(why).toContain('Stop and report to the main session')
  expect(w.ran).toEqual([])
})

test('a guard that cannot read its record or the file refuses, saying why; one that cannot record says so', withKit, async ($, on) => {
  const w = world($, on)
  w.ctl.storeGetFails = true
  expect(refusalOf(await call($, REWORD))).toContain('could not check')
  w.ctl.storeGetFails = false
  w.ctl.unreadable = ALERT
  expect(refusalOf(await call($, REWORD))).toContain('could not check')
  w.ctl.unreadable = ''
  const why = refusalOf(await call($, REWORD))
  w.ctl.storeSetFails = true
  expect(contextOf(await ask($, w, why, APPROVE))).toContain('could not be recorded')
  expect(w.ran).toEqual([])
})

test("python alerts are read through mod-kit's reader, and the guard's own record is never written by a call", withKit, async ($, on) => {
  const w = world($, on, { files: { '/w/app/notify.py': 'from slack_sdk import WebClient\nmsg = "Nightly sync finished"\n' } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: '/w/app/notify.py', old_string: 'Nightly sync finished', new_string: 'Nightly sync finished late' }))).toContain('Nightly sync finished late')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: '/w/app/notify.py', old_string: 'msg =', new_string: 'message =' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Write', file_path: STORE, content: '{}' }))).toContain('own record')
  expect(refusalOf(await call($, { tool: 'Bash', command: `printf '{}' > ${STORE}` }))).toContain('own record')
  expect(w.ran.length).toBe(1)
})

test('a shell write into a Slack posting file is held until Dan approves it, then the same command runs', withKit, async ($, on) => {
  const w = world($, on)
  const cmd = { tool: 'Bash', command: `printf 'notify("Disk is full")\\n' >> ${ALERT}` }
  const why = refusalOf(await call($, cmd))
  expect(why).toContain(ALERT)
  // A shell write's wording cannot be read before it runs, so it is named as that, never as an
  // empty list of message text taken away.
  expect(why).toContain('shell command')
  expect(why).not.toContain('takes Slack message text away')
  expect(w.cards.at(-1)?.reason).toContain('shell command')
  expect(refusalOf(await call($, { tool: 'Bash', command: `printf 'x\\n' >> ${PLAIN}` }))).toBe('')
  await ask($, w, why, APPROVE, { rendered: 'Disk is full on db-1' })
  expect(refusalOf(await call($, cmd))).toBe('')
  expect(w.ran.map(x => x.tool)).toEqual(['Bash', 'Bash'])
})

test('the calls waiting on Dan are dropped at session end', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, REWORD))
  await ($ as unknown as { session: { end: (e: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  expect(refusalOf(await ask($, w, why, APPROVE))).toContain('No Slack alert edit is waiting')
})
