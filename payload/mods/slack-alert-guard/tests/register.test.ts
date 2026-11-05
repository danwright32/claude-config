import { expect, mock, type Engine } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { EngineInterface, On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { APPROVE, CHANGE, HEADER, SCAN_MS, wordingKey } from '../hooks/rules.ts'
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
// The repository the files above are in, as git names it.
const REPO = '/w/app'

type Asked = { questions: { question: string; header: string; options: { label: string; description?: string }[]; multiSelect: boolean }[]; metadata?: Record<string, unknown> }
const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never

const world = (engine: Engine, on: On, init: { files?: Record<string, string> } = {}) => {
  const files: Record<string, string> = { [ALERT]: ALERT_TEXT, [PLAIN]: 'export const x = 1\n', ...(init.files ?? {}) }
  const store: Record<string, unknown> = {}
  // gitFails: git is killed and exits nonzero with this on stderr (as at its timeoutMs); gitThrows:
  // git cannot be run at all, so the call rejects (a hook that throws is skipped, and nothing answers);
  // gitSlow: the search answers, but only after the clock has moved past the scan's deadline.
  const ctl = { storeGetFails: false, storeSetFails: false, unreadable: '', gitFails: '', gitThrows: false, gitSlow: 0 }
  // Every git command the guard ran, with the timeout it gave it, so a pass can be told from a
  // guard that never searched.
  const gits: { argv: string[]; timeoutMs?: number }[] = []
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const asked: Asked[] = []
  const dialog: { answer?: string; afk?: boolean } = {}
  const cards: Record<string, unknown>[] = []
  const toasts: string[] = []
  const clock = mock.clock(on, { now: T0 })
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : undefined }) as never)
  on('session.cwd', () => ({ value: '/w/app' }) as never)
  on('session.id', () => ({ value: 's1' }) as never)
  on('process.run', async ($, e) => {
    const [cmd, method, raw] = e.argv.map(String)
    // git, standing in over the files above: one repository at /w/app, searched as git grep does.
    if (cmd === 'git') {
      const argv = e.argv.map(String)
      gits.push({ argv, timeoutMs: e.init?.timeoutMs })
      if (ctl.gitThrows) throw new Error('git could not be started')
      if (ctl.gitFails) return { value: { exitCode: 143, stdout: '', stderr: `${ctl.gitFails}\n`, isStdoutTruncated: false, isStderrTruncated: false } } as never
      const dir = argv[2] ?? ''
      const inRepo = dir === REPO || dir.startsWith(`${REPO}/`)
      if (argv[3] === 'rev-parse') {
        if (!inRepo) return { value: { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository (or any of the parent directories): .git\n', isStdoutTruncated: false, isStderrTruncated: false } } as never
        // As git prints it: the top folder, then the folder below it ending in a slash, empty at the top.
        return ok(`${REPO}\n${dir === REPO ? '' : `${dir.slice(REPO.length + 1)}/`}\n`)
      }
      if (argv[3] === 'grep') {
        if (ctl.gitSlow) await clock.advance(ctl.gitSlow)
        const patterns = argv.flatMap((a, i) => (argv[i - 1] === '-e' ? [new RegExp(a, 'i')] : []))
        const hits = Object.keys(files).filter(p => p.startsWith(`${dir}/`) && patterns.every(re => re.test(files[p] ?? '')))
        if (!hits.length) return { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
        return ok(hits.map(p => `${p.slice(dir.length + 1)}\u0000`).join(''))
      }
      throw new Error(`unexpected git command: ${argv.join(' ')}`)
    }
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
  // A folder exists while any file is in it.
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined || Object.keys(files).some(p => p.startsWith(`${e.path}/`)) }) as never)
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
  return { files, store, ctl, ran, asked, dialog, cards, toasts, gits }
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

test('python wording starting with a letter that can prefix a string is shown whole', withKit, async ($, on) => {
  world($, on, { files: { '/w/app/notify.py': 'from slack_sdk import WebClient\nmsg = "Backup done"\nnote = f"run {n} done"\n' } })
  const plain = refusalOf(await call($, { tool: 'Edit', file_path: '/w/app/notify.py', old_string: 'Backup done', new_string: 'Backup failed' }))
  expect(plain).toContain('Backup failed')
  expect(plain).not.toContain('"ackup failed"')
  const formatted = refusalOf(await call($, { tool: 'Edit', file_path: '/w/app/notify.py', old_string: 'run {n} done', new_string: 'run {n} failed' }))
  expect(formatted).toContain('run {n} failed')
  expect(formatted).not.toContain('"un {n} failed"')
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

// claude-config#2248: the wording lives in a template, and a different file sends it to Slack.
const TEMPLATE = '/w/app/lib/templates/deploy.ts'
const TEMPLATE_TEXT = 'export const deployFailed = (id: string) => `Deploy ${id} failed`\n'
const SENDER = '/w/app/lib/notify.ts'
const SENDER_TEXT =
  "import { deployFailed } from './templates/deploy'\nexport const notify = (id: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: deployFailed(id) }) })\n"
const RETEMPLATE = { tool: 'Edit', file_path: TEMPLATE, old_string: 'Deploy ${id} failed', new_string: 'Deploy ${id} failed on production' }
const sent = { files: { [TEMPLATE]: TEMPLATE_TEXT, [SENDER]: SENDER_TEXT } }
const grepped = (w: W) => w.gits.filter(g => g.argv[3] === 'grep').length

test('new wording in a template that another file sends to Slack is held, naming the sender, until Dan approves it', withKit, async ($, on) => {
  const w = world($, on, sent)
  const why = refusalOf(await call($, RETEMPLATE))
  expect(why).toContain(TEMPLATE)
  expect(why).toContain(`which ${SENDER} sends to Slack`)
  expect(why).toContain('Deploy ${id} failed on production')
  expect(w.ran).toEqual([])
  await ask($, w, why, APPROVE)
  expect(refusalOf(await call($, RETEMPLATE))).toBe('')
  expect(w.ran.length).toBe(1)
})

test('a text template a script reads and sends is held too, by a Write and by a shell write', withKit, async ($, on) => {
  const TXT = '/w/app/templates/backup.txt'
  const PY = '/w/app/jobs/backup.py'
  const w = world($, on, { files: { [TXT]: 'Backup is late\n', [PY]: 'from slack_sdk import WebClient\nbody = open("templates/backup.txt").read()\n' } })
  const why = refusalOf(await call($, { tool: 'Write', file_path: TXT, content: 'Backup is late on db-1\n' }))
  expect(why).toContain('Backup is late on db-1')
  expect(why).toContain(`which ${PY} sends to Slack`)
  const shell = refusalOf(await call($, { tool: 'Bash', command: `printf 'Backup failed\\n' > ${TXT}` }))
  expect(shell).toContain('shell command')
  expect(shell).toContain(`which ${PY} sends to Slack`)
  expect(w.ran).toEqual([])
})

test('a template no file sends passes, after a search that ran; so does a file outside any repository', withKit, async ($, on) => {
  const DIGEST = '/w/app/lib/templates/digest.ts'
  const w = world($, on, { files: { ...sent.files, [DIGEST]: 'export const digest = `Nightly digest ready`\n' } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: DIGEST, old_string: 'Nightly digest ready', new_string: 'Nightly digest is ready' }))).toBe('')
  expect(grepped(w)).toBe(1)
  // Every git call is bounded by the scan's deadline.
  expect(w.gits.every(g => typeof g.timeoutMs === 'number' && g.timeoutMs > 0 && g.timeoutMs <= SCAN_MS)).toBe(true)
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/elsewhere/messages.ts', content: 'export const m = "Disk is full"\n' }))).toBe('')
  // An edit touching no wording never searches at all.
  const before = w.gits.length
  expect(refusalOf(await call($, { tool: 'Edit', file_path: TEMPLATE, old_string: 'id: string', new_string: 'deployId: string' }))).toBe('')
  expect(w.gits.length).toBe(before)
  expect(w.ran.length).toBe(3)
})

test('a search that cannot finish, runs past its deadline, or meets an unreadable file holds the edit, saying why', withKit, async ($, on) => {
  const w = world($, on, sent)
  w.ctl.gitFails = 'timed out after 3000ms'
  const failed = refusalOf(await call($, RETEMPLATE))
  expect(failed).toContain('could not check')
  expect(failed).toContain('timed out after 3000ms')
  w.ctl.gitFails = ''
  w.ctl.gitThrows = true
  const unrun = refusalOf(await call($, RETEMPLATE))
  expect(unrun).toContain('could not check')
  expect(unrun).toContain('could not be searched')
  w.ctl.gitThrows = false
  w.ctl.gitSlow = SCAN_MS + 1
  const late = refusalOf(await call($, RETEMPLATE))
  expect(late).toContain('could not check')
  expect(late).toContain(`${SCAN_MS / 1000} seconds`)
  w.ctl.gitSlow = 0
  w.ctl.unreadable = SENDER
  const unread = refusalOf(await call($, RETEMPLATE))
  expect(unread).toContain('could not check')
  expect(unread).toContain(SENDER)
  expect(w.ran).toEqual([])
})

test('the calls waiting on Dan are dropped at session end', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, REWORD))
  await ($ as unknown as { session: { end: (e: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  expect(refusalOf(await ask($, w, why, APPROVE))).toContain('No Slack alert edit is waiting')
})
