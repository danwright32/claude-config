import { expect, mock, type Engine } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { EngineInterface, On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { APPROVE, CHANGE, HEADER, REEXPORT_HOPS, SCAN_MS, wordingKey } from '../hooks/rules.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { pythonText } from './mod-kit/hooks/code.ts'
import { type TypedAnswer, typedAnswerText, typedToast } from './mod-kit/hooks/typed.ts'
import { reasonOf, standInCore } from './mod-kit/tests/core.ts'
import { readsAsSend } from './send-wording.ts'

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
  // readMs: each file the guard reads and checks moves the clock this far, standing in for reading
  // and checking a real file on a busy Mac (#2371); cwd: the folder the session is in.
  const ctl = { storeGetFails: false, storeSetFails: false, unreadable: '', gitFails: '', gitThrows: false, gitSlow: 0, readMs: 0, cwd: '/w/app' }
  let reads = 0
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
  on('session.cwd', () => ({ value: ctl.cwd }) as never)
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
        // The pathspecs after --, as git reads them: '.' is every file, '*.ts' any file ending .ts, and
        // ':(glob,icase)**/name.*' a path matched as a glob from the top, case ignored.
        const specs = argv.slice(argv.indexOf('--') + 1)
        const glob = (g: string) =>
          new RegExp(`^${g.replace(/\\(.)|(\*\*\/)|(\*)|(\?)|([.+^${}()|[\]])/g, (m, esc, all, star, one, lit) => (esc ? `\\${esc}` : all ? '(.*/)?' : star ? '[^/]*' : one ? '[^/]' : `\\${lit}`))}$`, 'i')
        const inSpec = (p: string) =>
          specs.some(s => s === '.' || (s.startsWith('*.') && p.endsWith(s.slice(1))) || (s.startsWith(':(glob,icase)') && glob(s.slice(':(glob,icase)'.length)).test(p.slice(dir.length + 1))))
        // git grep reads line by line, so each pattern must match within one line of the file.
        const hits = Object.keys(files).filter(p => p.startsWith(`${dir}/`) && inSpec(p) && patterns.every(re => (files[p] ?? '').split('\n').some(l => re.test(l))))
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
  on('fs.read', async ($, e) => {
    if (ctl.unreadable === e.path) throw new Error(`EACCES: ${e.path}`)
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    reads++
    if (ctl.readMs) await clock.advance(ctl.readMs)
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
  return { files, store, ctl, ran, asked, dialog, cards, toasts, gits, reads: () => reads }
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
  // Approving posts nothing (claude-config#2284), so nothing Dan reads in the dialog may ask to
  // post or send: not the question above the message, not either answer.
  const shown = w.asked[0]?.questions[0]
  expect(readsAsSend((shown?.question ?? '').split('\n\n')[0] ?? '')).toBe(false)
  for (const o of shown?.options ?? []) expect(readsAsSend(`${o.label} ${o.description ?? ''}`)).toBe(false)
  expect(contextOf(a)).toContain('again')
  expect(w.store[wordingKey('Deploy ${id} failed on production')]).toBeDefined()
  const again = await call($, REWORD)
  expect(refusalOf(again)).toBe('')
  expect(w.ran.length).toBe(1)
})

test('a test file sends nothing: its titles and fixtures pass, by an edit and by a shell write, while the same wording in the sender is held', withKit, async ($, on) => {
  const w = world($, on)
  const TEST = '/w/app/lib/alert.test.ts'
  const fresh = { tool: 'Write', file_path: TEST, content: 'import { sendSlackAlert } from "./alert"\ndescribe("the deploy alert", () => {\n  it("says the backup is late", () => expect(sent).toBe("Backup is late again"))\n})\n' }
  expect(refusalOf(await call($, fresh))).toBe('')
  const FOLDER = '/w/app/__tests__/route.ts'
  expect(refusalOf(await call($, { tool: 'Write', file_path: FOLDER, content: 'import { notifySlack } from "../lib/alert"\nconst reason = "Card was declined twice"\n' }))).toBe('')
  w.files[TEST] = fresh.content
  expect(refusalOf(await call($, { tool: 'Bash', command: `printf 'it("posts the late notice")\\n' >> ${TEST}` }))).toBe('')
  expect(w.ran.length).toBe(3)
  // The same wording in the file that sends it is still held.
  expect(refusalOf(await call($, { tool: 'Edit', file_path: ALERT, old_string: 'Deploy ${id} failed', new_string: 'Backup is late again' }))).toContain('Backup is late again')
})

test('a file a test only names is not held: a deploy test naming package.json leaves its npm scripts free to change', withKit, async ($, on) => {
  const PKG = '/w/app/package.json'
  const DEPLOY_TEST = '/w/app/scripts/deploy.test.ts'
  const w = world($, on, {
    files: {
      [PKG]: '{ "scripts": { "build": "next build" } }\n',
      [DEPLOY_TEST]: "import { sendSlackAlert } from '../lib/alert'\nit('reads the version from package.json', () => expect(version).toBe('1.2.0'))\n",
    },
  })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: PKG, old_string: '"next build"', new_string: '"next build && npm run lint"' }))).toBe('')
  expect(w.ran.length).toBe(1)
})

test('a file a Slack sender only names, never imports or reads, is not held (Dan item 1)', withKit, async ($, on) => {
  const PKG = '/w/app/package.json'
  const DEPLOY = '/w/app/scripts/deploy.ts'
  const w = world($, on, {
    files: {
      [PKG]: '{ "scripts": { "build": "next build" } }\n',
      [DEPLOY]: "import { notifySlack } from '../lib/alert'\nawait run('git add package.json CHANGELOG.md')\nawait notifySlack(`Released ${version}`)\n",
    },
  })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: PKG, old_string: '"next build"', new_string: '"next build && npm run lint"' }))).toBe('')
  expect(w.ran.length).toBe(1)
  // The sender's own wording is still held.
  expect(refusalOf(await call($, { tool: 'Edit', file_path: DEPLOY, old_string: 'Released ${version}', new_string: 'Released ${version} to production' }))).toContain('Released ${version} to production')
})

// Dan item 1, the real shape: a workflow that posts to Slack. Only what a Slack step posts is held.
const WORKFLOW = '/w/app/.github/workflows/deploy.yml'
const WORKFLOW_TEXT = [
  'name: Deploy the site',
  'on:',
  '  workflow_dispatch:',
  '    inputs:',
  '      environment:',
  '        description: The environment to deploy to',
  'jobs:',
  '  build:',
  '    name: Build the site',
  '    steps:',
  '      - name: Install dependencies',
  '        run: npm ci && npm run build',
  '  notify:',
  '    needs: [ build, test ]',
  '    steps:',
  '      - name: Post to Slack',
  '        uses: slackapi/slack-github-action@v1',
  '        with:',
  '          payload: |',
  '            {"text": "Deploy of ${{ github.sha }} finished"}',
  '        env:',
  '          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}',
  "      - name: Page on failure",
  "        run: curl -X POST --data '{\"text\":\"Deploy failed on main\"}' \"$SLACK_WEBHOOK_URL\"",
  '',
].join('\n')

test("a Slack sending workflow's step names, job names, needs lists, input descriptions and run commands pass (Dan item 1)", withKit, async ($, on) => {
  const w = world($, on, { files: { [WORKFLOW]: WORKFLOW_TEXT } })
  const edits: [string, string][] = [
    ['Install dependencies', 'Install the dependencies'],
    ['Build the site', 'Build the whole site'],
    ['[ build, test ]', '[ build, test, lint ]'],
    ['The environment to deploy to', 'The environment this deploys to'],
    ['npm ci && npm run build', 'npm ci && npm run build && npm test'],
    ['Deploy the site', 'Deploy the site now'],
  ]
  for (const [from, to] of edits) expect(refusalOf(await call($, { tool: 'Edit', file_path: WORKFLOW, old_string: from, new_string: to }))).toBe('')
  expect(w.ran.length).toBe(edits.length)
})

test("what a workflow's Slack step posts is still held: its payload text and a Slack curl's message", withKit, async ($, on) => {
  const w = world($, on, { files: { [WORKFLOW]: WORKFLOW_TEXT } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: WORKFLOW, old_string: 'finished"}', new_string: 'finished cleanly"}' }))).toContain('Deploy of ${{ github.sha }} finished cleanly')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: WORKFLOW, old_string: 'Deploy failed on main', new_string: 'Deploy failed on main again' }))).toContain('Deploy failed on main again')
  expect(w.ran).toEqual([])
})

test('a SQL string in a Slack sender passes when it is not handed to a query builder call, and the alert beside it is still held (Dan item 2)', withKit, async ($, on) => {
  const JOB = '/w/app/lib/late.ts'
  const text = "import { notifySlack } from './alert'\nconst LATE = \"SELECT id, starts_at FROM bookings WHERE status = 'late'\"\nexport const run = async () => {\n  const rows = await pool.query(LATE)\n  await notifySlack(`${rows.length} bookings are late`)\n}\n"
  const w = world($, on, { files: { [JOB]: text } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: JOB, old_string: "WHERE status = 'late'\"", new_string: "WHERE status = 'late' AND paid IS FALSE\"" }))).toBe('')
  expect(w.ran.length).toBe(1)
  expect(refusalOf(await call($, { tool: 'Edit', file_path: JOB, old_string: 'bookings are late`', new_string: 'bookings are late today`' }))).toContain('${rows.length} bookings are late today')
})

test('database query strings in a Slack sender pass, and an alert sentence in the same file is still held', withKit, async ($, on) => {
  const ROUTE = '/w/app/lib/cron.ts'
  const text = 'import { notifySlack } from "./alert"\nexport const run = async () => {\n  const { data } = await db.from("bookings").select("id, starts_at").eq("status", "late")\n  await notifySlack(`Booking ${data[0].id} is late`)\n}\n'
  const w = world($, on, { files: { [ROUTE]: text } })
  const select = { tool: 'Edit', file_path: ROUTE, old_string: '"id, starts_at"', new_string: '"id, starts_at, buckets!bookings_bucket_id_fkey!inner(code)"' }
  expect(refusalOf(await call($, select))).toBe('')
  const eq = { tool: 'Edit', file_path: ROUTE, old_string: '.eq("status", "late")', new_string: '.eq("status", "late").order("starts_at", { ascending: true }).eq("reason", "Payment failed twice")' }
  expect(refusalOf(await call($, eq))).toBe('')
  expect(w.ran.length).toBe(2)
  expect(refusalOf(await call($, { tool: 'Edit', file_path: ROUTE, old_string: 'is late`', new_string: 'is late again`' }))).toContain('Booking ${data[0].id} is late again')
})

test('a code template in a Slack sender passes, and so does a library file whose only Slack referrer is a test', withKit, async ($, on) => {
  const LIB = '/w/app/lib/sandbox.ts'
  const LIB_TEST = '/w/app/lib/sandbox.test.ts'
  const worker = 'export default {\\n  async fetch(request) {\\n    const body = await request.text();\\n    return new Response(body);\\n  }\\n}'
  const w = world($, on, {
    files: {
      [LIB]: "export const workerSource = 'export default {}'\nexport const label = 'Sandbox ready now'\n",
      [LIB_TEST]: "import { sendSlackAlert } from './alert'\nimport { workerSource } from './sandbox'\n",
    },
  })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: LIB, old_string: "'export default {}'", new_string: `'${worker}'` }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: LIB, old_string: 'Sandbox ready now', new_string: 'Sandbox is ready now' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: ALERT, old_string: 'method: "POST"', new_string: `method: "POST", worker: "${worker}"` }))).toBe('')
  expect(w.ran.length).toBe(3)
})

test('a doc is neither a template nor a sender: a runbook named in a code comment, and a digest a runbook names, both pass', withKit, async ($, on) => {
  const RUNBOOK = '/w/app/docs/runbook.md'
  const DIGEST = '/w/app/lib/digest.ts'
  const w = world($, on, {
    files: {
      [RUNBOOK]: '# Alerts\n\nThe digest in lib/digest.ts posts to hooks.slack.com every night.\n| Late booking | Page the on call |\n',
      [DIGEST]: 'export const digest = `Nightly digest ready`\n',
      '/w/app/lib/page.ts': '// rows come from docs/runbook.md\nexport const page = (t: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: "POST", body: t })\n',
    },
  })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: RUNBOOK, old_string: '| Late booking | Page the on call |', new_string: '| Late booking | Page the on call now |' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: DIGEST, old_string: 'Nightly digest ready', new_string: 'Nightly digest is ready' }))).toBe('')
  expect(w.ran.length).toBe(2)
})

test('a file outside any git repository passes even when it carries a Slack marker, as a scratchpad script does', withKit, async ($, on) => {
  const SCRATCH = '/private/tmp/claude-501/x/scratchpad/backfill.ts'
  const w = world($, on, { files: { [SCRATCH]: 'const url = process.env.SLACK_WEBHOOK_URL\nconst q = "x"\n' } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: SCRATCH, old_string: 'const q = "x"', new_string: 'const q = "where status is late and paid is false"' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Bash', command: `printf 'notify("Disk is full")\\n' >> ${SCRATCH}` }))).toBe('')
  expect(w.ran.length).toBe(2)
  // It was the repository that decided: the guard asked git.
  expect(w.gits.some(g => g.argv[3] === 'rev-parse' && g.argv[2]?.startsWith('/private/tmp'))).toBe(true)
})

// claude-config#2361: a copy builder module whose text a route hands to a Slack send helper.
const COPY = '/w/app/src/lib/notify/outage-copy.ts'
const COPY_TEXT = 'export const lateBooking = (id: string) => `Booking ${id} is late`\n'
const POST = '/w/app/src/lib/notify/post.ts'
const POST_TEXT = 'export const postAlert = (text: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: "POST", body: JSON.stringify({ text }) })\n'
const ROUTE = '/w/app/src/app/api/cron/route.ts'
const ROUTE_TEXT = "import { lateBooking } from '@/lib/notify/outage-copy'\nimport { postAlert } from '@/lib/notify/post'\nexport const GET = async () => postAlert(lateBooking('1'))\n"

test('a copy builder whose text a route posts through a Slack send helper is held, naming the route as its sender', withKit, async ($, on) => {
  const w = world($, on, { files: { [COPY]: COPY_TEXT, [POST]: POST_TEXT, [ROUTE]: ROUTE_TEXT } })
  const edit = { tool: 'Edit', file_path: COPY, old_string: 'is late`', new_string: 'is late again`' }
  const why = refusalOf(await call($, edit))
  expect(why).toContain(COPY)
  expect(why).toContain(`which ${ROUTE} sends to Slack`)
  expect(why).toContain('Booking ${id} is late again')
  expect(w.ran).toEqual([])
  await ask($, w, why, APPROVE, { rendered: 'Booking 4182 is late again' })
  expect(refusalOf(await call($, edit))).toBe('')
  expect(w.ran.length).toBe(1)
})

test("a copy builder whose send helper cannot be read is held for Dan to approve, naming no sender, never let through", withKit, async ($, on) => {
  const w = world($, on, { files: { [COPY]: COPY_TEXT, [POST]: POST_TEXT, [ROUTE]: ROUTE_TEXT } })
  w.ctl.unreadable = POST
  const edit = { tool: 'Edit', file_path: COPY, old_string: 'is late`', new_string: 'is late again`' }
  const why = refusalOf(await call($, edit))
  expect(why).toContain('Booking ${id} is late again')
  expect(why).not.toContain('sends to Slack')
  expect(why).not.toContain('could not check')
  expect(idIn(why)).toBeDefined()
  expect(w.ran).toEqual([])
})

test('a notice builder of any name, whose importer imports the Slack module, is held too: what decides is the send, not the name', withKit, async ($, on) => {
  const NOTICE = '/w/app/src/lib/notify/notice.ts'
  const RUN = "import { buildNotice } from './notice'\nimport type { Payload } from './post'\nexport const runChange = () => buildNotice('1')\n"
  const w = world($, on, { files: { [NOTICE]: COPY_TEXT, [POST]: POST_TEXT, '/w/app/src/lib/notify/run.ts': RUN } })
  const why = refusalOf(await call($, { tool: 'Edit', file_path: NOTICE, old_string: 'is late`', new_string: 'is late again`' }))
  expect(why).toContain('which /w/app/src/lib/notify/run.ts sends to Slack')
  expect(w.ran).toEqual([])
})

test('a copy builder used by a route that posts nothing passes', withKit, async ($, on) => {
  const w = world($, on, { files: { [COPY]: COPY_TEXT, [ROUTE]: "import { lateBooking } from '@/lib/notify/outage-copy'\nexport const GET = async () => console.log(lateBooking('1'))\n" } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: COPY, old_string: 'is late`', new_string: 'is late again`' }))).toBe('')
  expect(w.ran.length).toBe(1)
})

test('more files could send a template than the guard reads: the edit is held with an id Dan can approve, never refused unanswerably', withKit, async ($, on) => {
  const many: Record<string, string> = {}
  // Each names the template as an import does, and mentions Slack only in a comment, so each must be read (#2371).
  for (let i = 0; i < 201; i++) many[`/w/app/lib/jobs/job${i}.ts`] = `// slack channel for deploy news\nimport { deployFailed } from '../templates/deploy'\nexport const n${i} = deployFailed\n`
  const w = world($, on, { files: { ...sent.files, ...many } })
  const why = refusalOf(await call($, RETEMPLATE))
  expect(why).not.toContain('could not check')
  expect(why).toContain('Deploy ${id} failed on production')
  expect(idIn(why)).toBeDefined()
  // No sender is named, since the guard could not tell which file sends it.
  expect(why).not.toContain('sends to Slack')
  await ask($, w, why, APPROVE)
  expect(refusalOf(await call($, RETEMPLATE))).toBe('')
  expect(w.ran.length).toBe(1)
})

test('the real shapes that were over the limit: a page gaining a metadata title among 452 pages that mention Slack passes, since no file names it (#2371); a deploy doc gaining bullets is a doc and passes', withKit, async ($, on) => {
  const PAGE = '/w/app/src/app/login/page.tsx'
  const DOC = '/w/app/DEPLOY.md'
  const many: Record<string, string> = {}
  for (let i = 0; i < 452; i++) many[`/w/app/src/app/area${i}/page.tsx`] = `// slack page for area ${i}\nexport default function Page${i}() { return null }\n`
  // Markdown that names the page and Slack is never counted as a sender.
  for (let i = 0; i < 50; i++) many[`/w/app/docs/notes${i}.md`] = 'The login page posts to hooks.slack.com\n'
  const w = world($, on, { files: { ...many, [PAGE]: 'export default function Login() { return null }\n', [DOC]: '# Deploy\n\n- Set the region\n' } })
  const edit = { tool: 'Edit', file_path: PAGE, old_string: 'export default', new_string: 'export const metadata = { title: "Sign in" };\nexport default' }
  // Every other page holds the word page and the word slack, but none names this page, so none is read.
  expect(refusalOf(await call($, edit))).toBe('')
  expect(w.reads()).toBeLessThan(5)
  const bullets = '- Set the region\n- Set DATABASE_URL to the pooled address\n- Set SENTRY_DSN for errors\n- Set SLACK_WEBHOOK_URL for deploy notices\n'
  expect(refusalOf(await call($, { tool: 'Edit', file_path: DOC, old_string: '- Set the region\n', new_string: bullets }))).toBe('')
  expect(w.ran.length).toBe(2)
})

// claude-config#2371, Dan's item 3: a template with a common short name. The name is a piece of many
// words (et in let, get and settings; memory in "kept in memory"), so a search for the bare word
// listed a crowd of files, and reading every one ran past the deadline: the write was held as could
// not check, with nothing Dan could approve.
const crowd = (n: number) => {
  const many: Record<string, string> = {}
  for (let i = 0; i < n; i++)
    many[`/w/app/src/app/area${i}/page.tsx`] = `import { getSettings } from '@/lib/get-settings'\n// the digest is kept in memory, then posted to slack\nexport const let${i} = getSettings()\n`
  return many
}
const ET = '/w/app/src/lib/et.ts'
const MEMORY = '/w/app/src/lib/memory.ts'
const LABEL = 'export const nowEt = () => new Date()\nexport const label = "Eastern time"\n'
const relabel = (file: string) => ({ tool: 'Edit', file_path: file, old_string: '"Eastern time"', new_string: '"Eastern time, as Dan reads it"' })

test('a write to a file with a common short name (et.ts, memory.ts) is judged by the files that name it, within the deadline (Dan item 3)', withKit, async ($, on) => {
  const CLOCK = '/w/app/src/app/clock/page.tsx'
  const w = world($, on, {
    files: {
      ...crowd(150),
      [ET]: LABEL,
      [MEMORY]: LABEL,
      // An importer that posts nothing.
      [CLOCK]: "import { nowEt } from '@/lib/et'\nimport { remember } from '@/lib/memory'\nimport { db } from '@/lib/db'\nexport default function Clock() { return nowEt() }\n",
    },
  })
  // Reading and checking 120 files takes the whole 3 seconds.
  w.ctl.readMs = 25
  for (const file of [ET, MEMORY]) {
    const before = w.reads()
    expect(refusalOf(await call($, relabel(file)))).toBe('')
    // Only the files that name it were read, never the crowd.
    expect(w.reads() - before).toBeLessThan(10)
  }
  expect(w.ran.length).toBe(2)
  // A file that does send it to Slack is still found, in the same crowd, and the edit is held naming it.
  const DIGEST = '/w/app/src/jobs/digest.ts'
  w.files[DIGEST] = "import { nowEt } from '../lib/et'\nexport const send = () => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: nowEt() })\n"
  const why = refusalOf(await call($, relabel(ET)))
  expect(why).toContain(`which ${DIGEST} sends to Slack`)
  expect(why).toContain('Eastern time, as Dan reads it')
  expect(w.ran.length).toBe(2)
})

test("a module's importers that also import common helpers (db, utils) do not make its write a hold (Dan item 3)", withKit, async ($, on) => {
  const many: Record<string, string> = {}
  for (let i = 0; i < 60; i++) many[`/w/app/src/app/api/r${i}/route.ts`] = `import { remember } from '@/lib/memory'\nimport { db } from '@/lib/db'\nimport { cn } from '@/lib/utils'\nexport const GET = () => remember(db, cn)\n`
  // Files that mention utils and slack, none of them the utils module.
  for (let i = 0; i < 250; i++) many[`/w/app/src/components/c${i}.tsx`] = `// utils for the slack digest card\nexport const c${i} = ${i}\n`
  const w = world($, on, { files: { ...many, [MEMORY]: LABEL, '/w/app/src/lib/db.ts': 'export const db = {}\n', '/w/app/src/lib/utils.ts': 'export const cn = () => ""\n' } })
  expect(refusalOf(await call($, relabel(MEMORY)))).toBe('')
  expect(w.ran.length).toBe(1)
})

test('a send helper whose text never names its own module is still found through the import, so the copy it sends is held (Dan item 3)', withKit, async ($, on) => {
  const ROUTE = '/w/app/src/app/api/digest/route.ts'
  const w = world($, on, {
    files: {
      [MEMORY]: LABEL,
      '/w/app/src/lib/messenger.ts': 'export const send = (text: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: "POST", body: JSON.stringify({ text }) })\n',
      [ROUTE]: "import { label } from '@/lib/memory'\nimport { send } from '@/lib/messenger'\nexport const GET = () => send(label)\n",
    },
  })
  const why = refusalOf(await call($, relabel(MEMORY)))
  expect(why).toContain(`which ${ROUTE} sends to Slack`)
  expect(w.ran).toEqual([])
})

test('an approval can carry a placeholder the code writes as text', withKit, async ($, on) => {
  const w = world($, on)
  const edit = { tool: 'Edit', file_path: ALERT, old_string: 'method: "POST"', new_string: "method: \"POST\", hint: 'Set ${SLACK_CHANNEL} before you deploy'" }
  const why = refusalOf(await call($, edit))
  expect(why).toContain('Set ${SLACK_CHANNEL} before you deploy')
  const a = await ask($, w, why, APPROVE, { rendered: 'Set ${SLACK_CHANNEL} before you deploy' })
  expect(refusalOf(a)).toBe('')
  expect(contextOf(a)).toContain(APPROVE)
  expect(refusalOf(await call($, edit))).toBe('')
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

test('a shell write Dan approved keeps its approval when a resumed agent, or the session from another folder, runs the same command again (Dan item 4)', withKit, async ($, on) => {
  const w = world($, on)
  const cmd = { tool: 'Bash', command: `printf 'notify("Disk is full")\\n' >> ${ALERT}` }
  // A subagent's write is held; the main session asks Dan, and he approves.
  const held = refusalOf(await call($, { ...cmd, agentId: 'agent-a1' }))
  const id = /call (t\d+) waits on Dan/.exec(held)?.[1]
  expect(id).toBeDefined()
  await ask($, w, `slack-alert-guard:${id}`, APPROVE, { rendered: 'Disk is full on db-1' })
  // The agent, resumed while the session is in another folder, runs the same command: it goes through.
  w.ctl.cwd = '/w/app/lib'
  expect(refusalOf(await call($, { ...cmd, agentId: 'agent-a1' }))).toBe('')
  // So does the main session, from a third folder.
  w.ctl.cwd = '/w'
  expect(refusalOf(await call($, cmd))).toBe('')
  expect(w.ran.length).toBe(2)
})

test('a shell write approved in one folder is held again when, run from another, the same words write a different Slack file (Dan item 4)', withKit, async ($, on) => {
  const WEB = '/w/app/web/lib/alert.ts'
  const w = world($, on, { files: { [WEB]: ALERT_TEXT } })
  const cmd = { tool: 'Bash', command: `printf 'notify("Disk is full")\\n' >> lib/alert.ts` }
  const why = refusalOf(await call($, cmd))
  expect(why).toContain(ALERT)
  await ask($, w, why, APPROVE, { rendered: 'Disk is full on db-1' })
  expect(refusalOf(await call($, cmd))).toBe('')
  // From the web folder the same words write the web app's alert, which Dan has not approved.
  // (Dan item 4's control: a different file is a different approval.)
  w.ctl.cwd = '/w/app/web'
  const again = refusalOf(await call($, cmd))
  expect(again).toContain(WEB)
  expect(idIn(again)).toBeDefined()
  expect(w.ran.length).toBe(1)
})

// claude-config#2371, Dan's item 5: a script step that builds its Slack text by concatenation, in a
// reusable alert workflow and in a composite action, and a nested template literal in a sender.
const scriptSteps = (indent: string) =>
  [
    `${indent}- name: Tell the team the backup failed`,
    `${indent}  uses: actions/github-script@v7`,
    `${indent}  env:`,
    `${indent}    SLACK_WEBHOOK_URL: \${{ secrets.SLACK_WEBHOOK_URL }}`,
    `${indent}  with:`,
    `${indent}    script: |`,
    `${indent}      const text = 'Nightly backup of ' + process.env.DB + ' failed on ' + context.ref`,
    `${indent}      await fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text }) })`,
    '',
  ].join('\n')
// Each file gains its own wording, since an approval is kept by the wording and would let the second through.
const reworded = (words: string) => ({ old_string: "' failed on '", new_string: `' ${words} on '` })

test("a workflow's script step that posts to Slack is held for its new wording, and Dan approves the message, never the code that builds it (Dan item 5)", withKit, async ($, on) => {
  const WORKFLOW = '/w/app/.github/workflows/backup-alert.yml'
  const ACTION = '/w/app/.github/actions/notify/action.yml'
  const w = world($, on, {
    files: {
      [WORKFLOW]: `on: workflow_call\njobs:\n  alert:\n    runs-on: ubuntu-latest\n    steps:\n${scriptSteps('      ')}`,
      [ACTION]: `name: Notify\nruns:\n  using: composite\n  steps:\n${scriptSteps('    ')}`,
    },
  })
  for (const [file, words] of [
    [WORKFLOW, 'failed again'],
    [ACTION, 'failed once more'],
  ] as const) {
    const edit = { tool: 'Edit', file_path: file, ...reworded(words) }
    const why = refusalOf(await call($, edit))
    expect(why).toContain(`${words} on`)
    // The code around the pieces is not wording, so Dan is never asked to read it.
    expect(why).not.toContain('const text')
    const a = await ask($, w, why, APPROVE, { rendered: `Nightly backup of orders ${words} on refs/heads/main` })
    expect(refusalOf(a)).toBe('')
    expect(contextOf(a)).toContain(APPROVE)
    expect(refusalOf(await call($, edit))).toBe('')
  }
  expect(w.ran.length).toBe(2)
})

test('a nested template literal in a Slack sender is held when its inner wording changes, and Dan approves the message as posted (Dan item 5)', withKit, async ($, on) => {
  const BACKUP = '/w/app/lib/backup.ts'
  const w = world($, on, {
    files: {
      [BACKUP]:
        'export const note = (db: string, late: boolean, hours: number) => `Backup of ${db} ${late ? `is ${hours} hours late` : "finished"}`\nexport const post = (t: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: "POST", body: t })\n',
    },
  })
  const edit = { tool: 'Edit', file_path: BACKUP, old_string: 'hours late', new_string: 'hours behind' }
  const why = refusalOf(await call($, edit))
  expect(why).toContain('is ${hours} hours behind')
  const a = await ask($, w, why, APPROVE, { rendered: 'Backup of orders is 3 hours behind' })
  expect(refusalOf(a)).toBe('')
  expect(refusalOf(await call($, edit))).toBe('')
  expect(w.ran.length).toBe(1)
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
  // One grep for files sending it, one for files handing it on (#2286).
  expect(grepped(w)).toBe(2)
  // Every git call is bounded by the scan's deadline.
  expect(w.gits.every(g => typeof g.timeoutMs === 'number' && g.timeoutMs > 0 && g.timeoutMs <= SCAN_MS)).toBe(true)
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/elsewhere/messages.ts', content: 'export const m = "Disk is full"\n' }))).toBe('')
  // An edit touching no wording never searches at all.
  const before = w.gits.length
  expect(refusalOf(await call($, { tool: 'Edit', file_path: TEMPLATE, old_string: 'id: string', new_string: 'deployId: string' }))).toBe('')
  expect(w.gits.length).toBe(before)
  expect(w.ran.length).toBe(3)
})

// Pivot, 2026-11-06: a project's CLAUDE.md named an engine file and a Slack webhook secret, and a
// workflow's comment named a test file, so ordinary code edits to both were held as alert wording.
test('a prose file, or a comment, that names a template and mentions Slack does not make a sender', withKit, async ($, on) => {
  const USAGE = '/w/app/src/turn-usage.ts'
  const USAGE_TEXT = 'export const insertUsage = "insert into turn_usage (turn) values (?)"\n'
  const NOTES = '/w/app/CLAUDE.md'
  const YML = '/w/app/.github/workflows/deploy.yml'
  const COMMENTED = '# turn-usage.ts keeps the cost; failures post with SLACK_ALERTS_WEBHOOK\nsteps:\n  - run: curl -X POST "$SLACK_ALERTS_WEBHOOK" -d "{}"\n'
  const w = world($, on, {
    files: {
      [USAGE]: USAGE_TEXT,
      [NOTES]: 'Usage lives in `src/turn-usage.ts`. Alerts post through `SLACK_ALERTS_WEBHOOK` to Slack.\n',
      [YML]: COMMENTED,
    },
  })
  const edit = { tool: 'Edit', file_path: USAGE, old_string: 'insert into turn_usage (turn) values (?)', new_string: 'insert into turn_usage (turn, run) values (?, ?)' }
  expect(refusalOf(await call($, edit))).toBe('')
  expect(w.ran.length).toBe(1)
})

test('a sender in a language the guard does not list as code still sends', withKit, async ($, on) => {
  const VUE = '/w/app/lib/notify.vue'
  const w = world($, on, { files: { [TEMPLATE]: TEMPLATE_TEXT, [VUE]: SENDER_TEXT } })
  const why = refusalOf(await call($, RETEMPLATE))
  expect(why).toContain(`which ${VUE} sends to Slack`)
  expect(w.ran).toEqual([])
})

test('a workflow that names a template in a step, not a comment, still sends it', withKit, async ($, on) => {
  const MSG = '/w/app/alerts/late.txt'
  const YML = '/w/app/.github/workflows/late.yml'
  const w = world($, on, {
    files: {
      [MSG]: 'Backup is late\n',
      [YML]: '# posts the late notice\nsteps:\n  - run: curl -X POST "$SLACK_ALERTS_WEBHOOK" --data-binary @alerts/late.txt\n',
    },
  })
  const why = refusalOf(await call($, { tool: 'Write', file_path: MSG, content: 'Backup is late on db-1\n' }))
  expect(why).toContain(`which ${YML} sends to Slack`)
  expect(w.ran).toEqual([])
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

// claude-config#2286: the template reaches its sender through files that import and re-export it.
const BARREL = '/w/app/lib/templates/index.ts'
const BARREL_TEXT = "export * from './deploy'\n"
const NOTIFY = '/w/app/lib/notify.ts'
const notifies = (from: string) =>
  `import { deployFailed } from '${from}'\nexport const notify = (id: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: deployFailed(id) }) })\n`
const reexports = (from: string) => `export { deployFailed } from '${from}'\n`

test('a template re-exported once, then sent to Slack, is held naming the file that sends it', withKit, async ($, on) => {
  const w = world($, on, { files: { [TEMPLATE]: TEMPLATE_TEXT, [BARREL]: BARREL_TEXT, [NOTIFY]: notifies('./templates') } })
  const why = refusalOf(await call($, RETEMPLATE))
  expect(why).toContain(TEMPLATE)
  expect(why).toContain(`which ${NOTIFY} sends to Slack`)
  expect(w.ran).toEqual([])
  await ask($, w, why, APPROVE)
  expect(refusalOf(await call($, RETEMPLATE))).toBe('')
})

test('a template re-exported twice, then sent to Slack, is held naming the file that sends it', withKit, async ($, on) => {
  const MESSAGES = '/w/app/lib/messages.ts'
  const w = world($, on, { files: { [TEMPLATE]: TEMPLATE_TEXT, [BARREL]: BARREL_TEXT, [MESSAGES]: reexports('./templates'), [NOTIFY]: notifies('./messages') } })
  const why = refusalOf(await call($, RETEMPLATE))
  expect(why).toContain(`which ${NOTIFY} sends to Slack`)
  expect(w.ran).toEqual([])
})

test(`a template handed on through ${REEXPORT_HOPS} files is followed; through more, the edit is held as could not check`, withKit, async ($, on) => {
  const ALPHA = '/w/app/lib/alpha.ts'
  const BRAVO = '/w/app/lib/bravo.ts'
  const CHARLIE = '/w/app/lib/charlie.ts'
  const chain = { [TEMPLATE]: TEMPLATE_TEXT, [BARREL]: BARREL_TEXT, [ALPHA]: reexports('./templates'), [BRAVO]: reexports('./alpha') }
  const w = world($, on, { files: { ...chain, [NOTIFY]: notifies('./bravo') } })
  expect(refusalOf(await call($, RETEMPLATE))).toContain(`which ${NOTIFY} sends to Slack`)
  // One file more than the guard follows: it cannot say whether that file is sent, so it holds.
  w.files[CHARLIE] = reexports('./bravo')
  w.files[NOTIFY] = notifies('./charlie')
  const why = refusalOf(await call($, RETEMPLATE))
  expect(why).toContain('could not check')
  expect(why).toContain(`more than ${REEXPORT_HOPS} files`)
  expect(why).toContain(CHARLIE)
  expect(w.ran).toEqual([])
})

test('a re-export cycle ends: with a sender beside it the edit is held, with none it passes', withKit, async ($, on) => {
  const ALPHA = '/w/app/lib/alpha.ts'
  const BRAVO = '/w/app/lib/bravo.ts'
  const loop = { [TEMPLATE]: TEMPLATE_TEXT, [ALPHA]: "export * from './templates/deploy'\nexport * from './bravo'\n", [BRAVO]: "export * from './alpha'\n" }
  const w = world($, on, { files: { ...loop, [NOTIFY]: notifies('./bravo') } })
  expect(refusalOf(await call($, RETEMPLATE))).toContain(`which ${NOTIFY} sends to Slack`)
  expect(w.ran).toEqual([])
  delete w.files[NOTIFY]
  const before = grepped(w)
  expect(refusalOf(await call($, RETEMPLATE))).toBe('')
  // Each level of the search is one grep for senders and one for files handing it on, and the
  // loop back to alpha.ts adds no level.
  expect(grepped(w) - before).toBeGreaterThan(2)
  expect(grepped(w) - before).toBeLessThanOrEqual(2 * (REEXPORT_HOPS + 1))
  expect(w.ran.length).toBe(1)
})

test('a template re-exported but sent to Slack by nothing passes, after the chain was followed', withKit, async ($, on) => {
  const MESSAGES = '/w/app/lib/messages.ts'
  const USES = '/w/app/lib/report.ts'
  const w = world($, on, {
    files: { [TEMPLATE]: TEMPLATE_TEXT, [BARREL]: BARREL_TEXT, [MESSAGES]: reexports('./templates'), [USES]: "import { deployFailed } from './messages'\nconsole.log(deployFailed('1'))\n" },
  })
  expect(refusalOf(await call($, RETEMPLATE))).toBe('')
  // Past the first grep: the barrel and messages.ts were each searched for.
  expect(grepped(w)).toBeGreaterThan(2)
  expect(w.ran.length).toBe(1)
})

// #2368 met #2286: past the template's own level, a prose file or a comment still sends nothing.
test('a prose file, or a comment, naming a file that hands the template on does not make a sender', withKit, async ($, on) => {
  const NOTES = '/w/app/docs/alerts.md'
  const YML = '/w/app/.github/workflows/deploy.yml'
  const w = world($, on, {
    files: {
      [TEMPLATE]: TEMPLATE_TEXT,
      [BARREL]: BARREL_TEXT,
      [NOTES]: 'Deploy notices come from `lib/templates/index.ts` and post through SLACK_WEBHOOK_URL.\n',
      [YML]: '# lib/templates/index.ts holds the wording; it posts with SLACK_WEBHOOK_URL\nsteps:\n  - run: curl -X POST "$SLACK_WEBHOOK_URL" -d "{}"\n',
    },
  })
  expect(refusalOf(await call($, RETEMPLATE))).toBe('')
  // The barrel's level was searched too, so the prose file and the comment were met and passed over.
  expect(grepped(w)).toBeGreaterThan(2)
})

test('a commented import does not hand a template on, and a Slack marker in a comment does not stop a file that does', withKit, async ($, on) => {
  const MESSAGES = '/w/app/lib/messages.ts'
  const w = world($, on, {
    files: {
      [TEMPLATE]: TEMPLATE_TEXT,
      [MESSAGES]: "// was: export { deployFailed } from './templates/deploy'\nexport const other = 1\n",
      [NOTIFY]: notifies('./messages'),
    },
  })
  expect(refusalOf(await call($, RETEMPLATE))).toBe('')
  // A comment naming the Slack webhook makes messages.ts neither the sender nor a dead end: it is
  // followed to the file that really sends the template.
  w.files[MESSAGES] = "// posts nothing itself, never SLACK_WEBHOOK_URL; notify.ts does\nexport { deployFailed } from './templates/deploy'\n"
  const why = refusalOf(await call($, RETEMPLATE))
  expect(why).toContain(`which ${NOTIFY} sends to Slack`)
  expect(why).not.toContain(`which ${MESSAGES}`)
})

test('the calls waiting on Dan are dropped at session end', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, REWORD))
  await ($ as unknown as { session: { end: (e: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  expect(refusalOf(await ask($, w, why, APPROVE))).toContain('No Slack alert edit is waiting')
})
