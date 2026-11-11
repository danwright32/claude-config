import { expect, mock, type Engine } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { EngineInterface, On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { APPROVE, CHANGE, HEADER, MARKER_PREFILTER, MOST_READ, PATHSPEC_BYTES, REEXPORT_HOPS, SCAN_MS, SENDER_PREFILTER, wordingKey } from '../hooks/rules.ts'
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

const HOME = `${'/Users'}/dan`
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
  // gitSlow: the search answers, but only after the clock has moved past the scan's deadline; with
  // gitSlowWhen, only a git grep one of whose arguments holds it does (#2719).
  // readMs: each file the guard reads and checks moves the clock this far, standing in for reading
  // and checking a real file on a busy Mac (#2371); cwd: the folder the session is in.
  // regexMsPerKb: each git grep moves the clock this far for every kilobyte of regular expression it
  // is given, for every file it searches, as measured on a real repository (#2462: 0.09 predicts the
  // 25 to 37 ms of a one name search and the 5.5 to 7.7 s of a 150 name one over 1,430 files);
  // fixed strings (-F) cost nothing here, as they cost about what one short pattern does there.
  // gitTruncated: git's listing comes back cut short. stdoutCap: as $.process.run keeps only the first
  // 4194304 bytes of what git prints, a listing longer than this comes back as its first stdoutCap
  // bytes, marked cut short (a work repository's design pages, whose lines run to hundreds of kilobytes, met this
  // after #2481).
  const ctl = { storeGetFails: false, storeSetFails: false, unreadable: '', gitFails: '', gitThrows: false, gitSlow: 0, gitSlowWhen: '', readMs: 0, regexMsPerKb: 0, gitTruncated: false, stdoutCap: Infinity, cwd: '/w/app' }
  let reads = 0
  // Every git command the guard ran, with the timeout it gave it, so a pass can be told from a
  // guard that never searched.
  const gits: { argv: string[]; timeoutMs?: number }[] = []
  // How many lines each git grep listing lines (no -l) printed.
  const printed: number[] = []
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const asked: Asked[] = []
  const dialog: { answer?: string; afk?: boolean } = {}
  const cards: Record<string, unknown>[] = []
  const toasts: string[] = []
  const clock = mock.clock(on, { now: T0 })
  // The wall (#2719): once started, every call the guard makes to the world first moves the test
  // clock on by the real time spent since the last one, so the guard's own reading and tracing of a
  // file is charged against its deadline as it is in a session, where git and reads cost little and
  // the work between them is the time. Started just before the call it measures.
  let wallAt: number | undefined
  const wallStart = () => {
    wallAt = performance.now()
  }
  const wall = async () => {
    if (wallAt === undefined) return
    const spent = Math.floor(performance.now() - wallAt)
    if (spent < 1) return
    wallAt += spent
    await clock.advance(spent)
  }
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : undefined }) as never)
  on('session.cwd', () => ({ value: ctl.cwd }) as never)
  on('session.id', () => ({ value: 's1' }) as never)
  on('process.run', async ($, e) => {
    await wall()
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
      // git ls-files, listing the files a pathspec names (#2637): tracked or not, each ending in a NUL.
      if (argv[3] === 'ls-files') {
        if (ctl.gitSlow) await clock.advance(ctl.gitSlow)
        const named = argv.slice(argv.indexOf('--') + 1).filter(s => s.startsWith(':(glob,icase)')).map(s => s.slice(':(glob,icase)'.length))
        const asGlob = (g: string) =>
          new RegExp(`^${g.replace(/\\(.)|(\*\*\/)|(\*)|(\?)|([.+^${}()|[\]])/g, (m, esc, all, star, one, lit) => (esc ? `\\${esc}` : all ? '(.*/)?' : star ? '[^/]*' : one ? '[^/]' : `\\${lit}`))}$`, 'i')
        const res = named.map(asGlob)
        const listed = Object.keys(files).filter(p => p.startsWith(`${dir}/`) && res.some(re => re.test(p.slice(dir.length + 1))))
        return { value: { exitCode: 0, stdout: listed.map(p => `${p.slice(dir.length + 1)}\u0000`).join(''), stderr: '', isStdoutTruncated: ctl.gitTruncated, isStderrTruncated: false } } as never
      }
      if (argv[3] === 'grep') {
        if (ctl.gitSlow && argv.some(a => a.includes(ctl.gitSlowWhen))) await clock.advance(ctl.gitSlow)
        // -F: every pattern a fixed string, and a line matching any of them is listed.
        const fixed = argv.includes('-F')
        const given = argv.flatMap((a, i) => (argv[i - 1] === '-e' ? [a] : []))
        // -w: a match must not sit inside a longer word, as git grep -w reads one.
        const whole = argv.includes('-w')
        const patterns = given.map(a => {
          const p = fixed ? a.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') : a
          return new RegExp(whole ? `(^|[^A-Za-z0-9_])(${p})([^A-Za-z0-9_]|$)` : p, 'i')
        })
        // The pathspecs after --, as git reads them: '.' is every file, '*.ts' any file ending .ts,
        // ':(glob,icase)**/name.*' a path matched as a glob from the top, case ignored, and
        // ':(literal)path' that one path, exactly as written.
        const specs = argv.slice(argv.indexOf('--') + 1)
        const glob = (g: string) =>
          new RegExp(`^${g.replace(/\\(.)|(\*\*\/)|(\*)|(\?)|([.+^${}()|[\]])/g, (m, esc, all, star, one, lit) => (esc ? `\\${esc}` : all ? '(.*/)?' : star ? '[^/]*' : one ? '[^/]' : `\\${lit}`))}$`, 'i')
        const inSpec = (p: string) =>
          specs.some(
            s =>
              s === '.' ||
              (s.startsWith('*.') && p.endsWith(s.slice(1))) ||
              (s.startsWith(':(glob,icase)') && glob(s.slice(':(glob,icase)'.length)).test(p.slice(dir.length + 1))) ||
              (s.startsWith(':(literal)') && s.slice(':(literal)'.length) === p.slice(dir.length + 1)),
          )
        const searched = Object.keys(files).filter(p => p.startsWith(`${dir}/`) && inSpec(p))
        if (ctl.regexMsPerKb && !fixed) await clock.advance(Math.ceil((given.join('').length / 1000) * searched.length * ctl.regexMsPerKb))
        // What git printed, as $.process.run hands it back: no more than its first stdoutCap bytes.
        const listing = (stdout: string) => {
          const bytes = new TextEncoder().encode(stdout)
          const cut = bytes.length > ctl.stdoutCap
          const kept = cut ? new TextDecoder().decode(bytes.subarray(0, ctl.stdoutCap)) : stdout
          return { value: { exitCode: 0, stdout: kept, stderr: '', isStdoutTruncated: ctl.gitTruncated || cut, isStderrTruncated: false } } as never
        }
        if (!argv.includes('-l')) {
          // Each line holding a fixed string, after its path and a NUL, as git grep -z prints it.
          const lines = searched.flatMap(p => (files[p] ?? '').split('\n').filter(l => (fixed ? patterns.some(re => re.test(l)) : patterns.every(re => re.test(l)))).map(l => `${p.slice(dir.length + 1)}\u0000${l}\n`))
          printed.push(lines.length)
          if (!lines.length) return { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
          return listing(lines.join(''))
        }
        // git grep reads line by line, so a pattern must match within one line of the file; a file is
        // listed when any of the patterns does, or every one with --and.
        const holds = (p: string) => (re: RegExp) => (files[p] ?? '').split('\n').some(l => re.test(l))
        const hits = searched.filter(p => (argv.includes('--and') ? patterns.every(holds(p)) : patterns.some(holds(p))))
        if (!hits.length) return { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
        return listing(hits.map(p => `${p.slice(dir.length + 1)}\u0000`).join(''))
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
  on('fs.exists', async ($, e) => {
    await wall()
    return { value: files[e.path] !== undefined || Object.keys(files).some(p => p.startsWith(`${e.path}/`)) } as never
  })
  on('fs.read', async ($, e) => {
    await wall()
    if (ctl.unreadable === e.path) throw new Error(`EACCES: ${e.path}`)
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    reads++
    if (ctl.readMs) await clock.advance(ctl.readMs)
    return { value: t } as never
  })
  on('store.get', async ($, e) => {
    await wall()
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
  return { files, store, ctl, ran, asked, dialog, cards, toasts, gits, printed, reads: () => reads, wallStart }
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

// #2401, the real shape: a GitLab pipeline whose script list curls a Slack webhook.
const GITLAB = '/w/app/.gitlab-ci.yml'
const GITLAB_TEXT = [
  'deploy:',
  '  stage: deploy',
  '  script:',
  '    - npm ci',
  '    - echo "Deploying the site now"',
  "    - curl -X POST --data '{\"text\":\"Deploy failed on main\"}' \"$SLACK_WEBHOOK_URL\"",
  '  after_script:',
  "    - 'curl -X POST --data ''{\"text\":\"Cleanup ran on main\"}'' \"$SLACK_WEBHOOK_URL\"'",
  'test:',
  '  script:',
  '    - echo "Running the unit tests"',
  'page:',
  '  script: |',
  '    curl -X POST --data \'{"text":"Backup of orders is late"}\' "$SLACK_WEBHOOK_URL"',
  '',
].join('\n')

test("a GitLab script list that curls Slack is held with its message shown, every item of that shell read together; a job that posts nothing passes (#2401, #2416)", withKit, async ($, on) => {
  const w = world($, on, { files: { [GITLAB]: GITLAB_TEXT } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: GITLAB, old_string: 'Deploy failed on main', new_string: 'Deploy failed on main again' }))).toContain('Deploy failed on main again')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: GITLAB, old_string: 'Cleanup ran on main', new_string: 'Cleanup ran on main twice' }))).toContain('Cleanup ran on main twice')
  // An item in the same shell as the curl can set what it posts, as a GitHub run block's line can.
  expect(refusalOf(await call($, { tool: 'Edit', file_path: GITLAB, old_string: 'Deploying the site now', new_string: 'Deploying the whole site now' }))).toContain('Deploying the whole site now')
  // A script block in a GitLab file is shell, so a curl's JSON message is shown.
  expect(refusalOf(await call($, { tool: 'Edit', file_path: GITLAB, old_string: 'Backup of orders is late', new_string: 'Backup of orders is very late' }))).toContain('Backup of orders is very late')
  expect(w.ran).toEqual([])
  expect(refusalOf(await call($, { tool: 'Edit', file_path: GITLAB, old_string: 'Running the unit tests', new_string: 'Running every unit test' }))).toBe('')
  expect(w.ran.length).toBe(1)
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

test('a node test script importing a copy builder and its Slack send helper is not a sender, so it is never named as one; a route that does the same is (#2509, #2720)', withKit, async ($, on) => {
  const NODE_TEST = '/w/app/scripts/test-outage-copy.ts'
  const w = world($, on, {
    files: {
      [COPY]: COPY_TEXT,
      [POST]: POST_TEXT,
      [NODE_TEST]: "import { lateBooking } from '../src/lib/notify/outage-copy'\nimport { postAlert } from '../src/lib/notify/post'\nassert.equal(lateBooking('1'), 'Booking 1 is late')\nvoid postAlert\n",
    },
  })
  const edit = { tool: 'Edit', file_path: COPY, old_string: 'is late`', new_string: 'is late again`' }
  // Imported by nothing but a test, the copy module's new wording is held as copy no file uses yet
  // (#2720), naming no sender: the test script is not one.
  const unwired = refusalOf(await call($, edit))
  expect(unwired).toContain('Booking ${id} is late again')
  expect(unwired).not.toContain('sends to Slack')
  expect(unwired).not.toContain(NODE_TEST)
  expect(w.ran).toEqual([])
  // The same imports in a route make it the sender, so the guard is still deciding.
  w.files[ROUTE] = ROUTE_TEXT
  const why = refusalOf(await call($, edit))
  expect(why).toContain(`which ${ROUTE} sends to Slack`)
  expect(why).not.toContain(NODE_TEST)
})

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
  // Each names the template as an import does, and names a Slack webhook only in a comment, which git
  // cannot tell from code, so each must be read (#2371).
  for (let i = 0; i <= MOST_READ; i++) many[`/w/app/lib/jobs/job${i}.ts`] = `// deploy news went to hooks.slack.com\nimport { deployFailed } from '../templates/deploy'\nexport const n${i} = deployFailed\n`
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
  // Reading and checking 120 files takes the whole search budget.
  w.ctl.readMs = Math.ceil(SCAN_MS / 120)
  for (const file of [ET, MEMORY]) {
    const before = w.reads()
    expect(refusalOf(await call($, relabel(file)))).toBe('')
    // Only the files that name it were read, never the crowd.
    expect(w.reads() - before).toBeLessThan(10)
  }
  expect(w.ran.length).toBe(2)
  // A file that does send it to Slack is still found, in the same crowd, and the edit is held naming it.
  const DIGEST = '/w/app/src/jobs/digest.ts'
  w.files[DIGEST] = "import { nowEt, label } from '../lib/et'\nexport const send = () => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: `${nowEt()} ${label}` })\n"
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
        'export const note = (db: string, late: boolean, hours: number) => `Backup of ${db} ${late ? `is ${hours} hours late` : "finished"}`\nexport const post = (t: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: "POST", body: t })\nexport const run = () => post(note("orders", true, 3))\n',
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

// claude-config#2475: a file that posts to Slack imports a module that holds an editor model's own
// instructions beside the title it posts. The instructions are text only the model reads, so adding a
// sentence to them was held as Slack wording, and the picker had to show the whole prompt.
const EDITOR = '/w/app/src/lib/ai/editor.ts'
const EDITOR_TEXT = [
  "import Anthropic from '@anthropic-ai/sdk'",
  'const client = new Anthropic()',
  'export const EDITOR_PROMPT = `You are the editor for the nightly digest.',
  '',
  'Keep every sentence short and plain.`',
  'const STYLE = `Never use a dash as punctuation.`',
  'const SYSTEM = [EDITOR_PROMPT, STYLE].join("\\n")',
  'export const digestTitle = (n: number) => `Nightly digest: ${n} stories ready`',
  'export const editDigest = async (draft: string) => {',
  "  const res = await client.messages.create({ model: 'claude-x', max_tokens: 900, system: SYSTEM, messages: [{ role: 'user', content: draft }] })",
  '  return String(res.content)',
  '}',
  '',
].join('\n')
const DIGEST_JOB = '/w/app/src/jobs/digest.ts'
const DIGEST_JOB_TEXT = [
  "import { WebClient } from '@slack/web-api'",
  "import { editDigest, digestTitle } from '../lib/ai/editor'",
  'const slack = new WebClient(process.env.SLACK_BOT_TOKEN)',
  "export const run = async (draft: string) => slack.chat.postMessage({ channel: 'C1', text: `${digestTitle(3)}\\n${await editDigest(draft)}` })",
  '',
].join('\n')
const editorWorld = { files: { [EDITOR]: EDITOR_TEXT, [DIGEST_JOB]: DIGEST_JOB_TEXT } }
const PROMPT_EDIT = { tool: 'Edit', file_path: EDITOR, old_string: 'Keep every sentence short and plain.', new_string: 'Keep every sentence short and plain. Lead with the biggest story.' }

test("an edit to a model's own instructions, in a module a Slack sender imports, passes: only the model reads them (#2475)", withKit, async ($, on) => {
  const w = world($, on, editorWorld)
  expect(refusalOf(await call($, PROMPT_EDIT))).toBe('')
  // A part the prompt is built from is read only by the model too.
  expect(refusalOf(await call($, { tool: 'Edit', file_path: EDITOR, old_string: 'Never use a dash as punctuation.', new_string: 'Never use a dash or a semicolon as punctuation.' }))).toBe('')
  expect(w.ran.length).toBe(2)
  expect(w.asked).toEqual([])
})

test('the title the same module hands the Slack sender is still held, and so is a prompt edit made in the same call as one (#2475)', withKit, async ($, on) => {
  const w = world($, on, editorWorld)
  const title = { tool: 'Edit', file_path: EDITOR, old_string: 'Nightly digest: ${n} stories ready', new_string: 'Nightly digest: ${n} stories are ready' }
  const why = refusalOf(await call($, title))
  expect(why).toContain(`which ${DIGEST_JOB} sends to Slack`)
  expect(why).toContain('Nightly digest: ${n} stories are ready')
  // A call changing the prompt and the title shows Dan the title alone, never the prompt.
  const both = refusalOf(await call($, { tool: 'MultiEdit', file_path: EDITOR, edits: [{ old_string: PROMPT_EDIT.old_string, new_string: PROMPT_EDIT.new_string }, { old_string: title.old_string, new_string: title.new_string }] }))
  expect(both).toContain('Nightly digest: ${n} stories are ready')
  expect(both).not.toContain('Lead with the biggest story')
  expect(w.ran).toEqual([])
})

test('a prompt constant some file also posts, or uses any way but as a model input, is still held as Slack wording (#2475)', withKit, async ($, on) => {
  // The sender posts the instructions themselves.
  const POSTS_PROMPT = "import { WebClient } from '@slack/web-api'\nimport { EDITOR_PROMPT } from '../lib/ai/editor'\nconst slack = new WebClient(process.env.SLACK_BOT_TOKEN)\nexport const run = () => slack.chat.postMessage({ channel: 'C1', text: EDITOR_PROMPT })\n"
  const w = world($, on, { files: { ...editorWorld.files, [DIGEST_JOB]: POSTS_PROMPT } })
  const why = refusalOf(await call($, PROMPT_EDIT))
  expect(why).toContain('Lead with the biggest story')
  expect(why).toContain(`which ${DIGEST_JOB} sends to Slack`)
  expect(w.ran).toEqual([])
})

test('a prompt constant another file hands to something other than a model is still held: the guard cannot see where that goes (#2475)', withKit, async ($, on) => {
  const OTHER = '/w/app/src/lib/ai/log.ts'
  const w = world($, on, { files: { ...editorWorld.files, [OTHER]: "import { EDITOR_PROMPT } from './editor'\nexport const note = () => record(EDITOR_PROMPT)\n" } })
  expect(refusalOf(await call($, PROMPT_EDIT))).toContain('Lead with the biggest story')
  // So is one renamed on its way out, which a search by its name could not follow.
  const ALIAS = "export { EDITOR_PROMPT as PROMPT }\n"
  w.files[EDITOR] = EDITOR_TEXT + ALIAS
  delete w.files[OTHER]
  expect(refusalOf(await call($, { ...PROMPT_EDIT, new_string: 'Keep every sentence short and plain. Name each story once.' }))).toContain('Name each story once')
  expect(w.ran).toEqual([])
})

// The prompt reaches a model runner elsewhere through a barrel, which a search by its name still finds.
const BARREL_AI = { '/w/app/src/lib/ai/index.ts': "export * from './editor'\n" }
const REVIEW = '/w/app/src/lib/review/run.ts'
const REVIEW_TEXT = "import { EDITOR_PROMPT } from '../ai'\nexport const review = (d: string) => client.messages.create({ system: EDITOR_PROMPT, messages: [{ role: 'user', content: d }] })\n"

test('a prompt another file imports through a barrel and hands only to a model passes; one whose other uses cannot be read is held (#2475)', withKit, async ($, on) => {
  const w = world($, on, { files: { ...editorWorld.files, ...BARREL_AI, [REVIEW]: REVIEW_TEXT } })
  expect(refusalOf(await call($, PROMPT_EDIT))).toBe('')
  expect(w.ran.length).toBe(1)
  // The guard cannot tell what the runner does with it, so the prompt counts as wording: held, never let through.
  w.ctl.unreadable = REVIEW
  const why = refusalOf(await call($, { ...PROMPT_EDIT, new_string: 'Keep every sentence short and plain. Name each story once.' }))
  expect(why).toContain('Name each story once')
  expect(why).toContain(`which ${DIGEST_JOB} sends to Slack`)
  expect(w.ran.length).toBe(1)
})

test('in a file that posts to Slack itself, its model prompt passes and its alert wording is still held (#2475)', withKit, async ($, on) => {
  const JOB = '/w/app/src/jobs/summary.ts'
  const JOB_TEXT = [
    "import { WebClient } from '@slack/web-api'",
    "import Anthropic from '@anthropic-ai/sdk'",
    'const slack = new WebClient(process.env.SLACK_BOT_TOKEN)',
    'const SUMMARY_PROMPT = `Summarise the day in three plain sentences.`',
    'export const run = async (log: string) => {',
    "  const res = await new Anthropic().messages.create({ model: 'claude-x', max_tokens: 400, system: SUMMARY_PROMPT, messages: [{ role: 'user', content: log }] })",
    "  await slack.chat.postMessage({ channel: 'C1', text: `Daily summary is ready: ${String(res.content)}` })",
    '}',
    '',
  ].join('\n')
  const w = world($, on, { files: { [JOB]: JOB_TEXT } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: JOB, old_string: 'three plain sentences.', new_string: 'three plain sentences, the worst news first.' }))).toBe('')
  const why = refusalOf(await call($, { tool: 'Edit', file_path: JOB, old_string: 'Daily summary is ready', new_string: 'Daily summary is ready to read' }))
  expect(why).toContain('Daily summary is ready to read')
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
  // Two greps, once for the search, for the files holding a Slack word and which of those could post,
  // and one for the files naming the template, senders and files handing it on alike (#2286, #2462);
  // with none naming it, no lines are listed.
  expect(grepped(w)).toBe(3)
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

// claude-config#2519, Dan 2026-11-09: a rule, not a deeper search. A file imported only by UI
// components (React files in a components, screens or views folder) is not on a path that posts to
// Slack, so it settles there; a file with any other importer is judged as before, and a UI file that
// itself sends is still found by the sender check.
const CARD = '/w/app/components/DeployCard.tsx'
const CARD_TEXT = "import { deployFailed } from '../lib/templates/deploy'\nexport const DeployCard = ({ id }: { id: string }) => <p>{deployFailed(id)}</p>\n"
const uiImports = (name: string, from: string, used: string) => `import { ${used} } from '${from}'\nexport const ${name} = () => <${used} id="1" />\n`
// Four components deep, one past what the guard follows, as the 14 components behind a work
// repository's logic-card.ts were.
const UI_CHAIN = {
  [CARD]: CARD_TEXT,
  '/w/app/components/DeployPanel.tsx': uiImports('DeployPanel', './DeployCard', 'DeployCard'),
  '/w/app/components/DeployList.tsx': uiImports('DeployList', './DeployPanel', 'DeployPanel'),
  '/w/app/screens/Deploys.tsx': uiImports('Deploys', '../components/DeployList', 'DeployList'),
}

test('a template imported only by UI components settles there, never followed past them', withKit, async ($, on) => {
  const w = world($, on, { files: { [TEMPLATE]: TEMPLATE_TEXT, ...UI_CHAIN } })
  const before = grepped(w)
  expect(refusalOf(await call($, RETEMPLATE))).toBe('')
  expect(w.ran.length).toBe(1)
  // The template's importers were searched for, and no search was made for the component's own: no
  // git grep looked for its name (a word after -e), though one listed the component's lines.
  expect(grepped(w)).toBeGreaterThan(before)
  const patterns = w.gits.flatMap(g => g.argv.filter((_, i) => g.argv[i - 1] === '-e'))
  expect(patterns.length).toBeGreaterThan(0)
  expect(patterns.some(p => /deploycard/i.test(p))).toBe(false)
})

test('a template imported by a UI component and by any other file is judged as before', withKit, async ($, on) => {
  // The other importer leads past what the guard follows: held as could not check, as without the component.
  const deep = {
    '/w/app/lib/emails/alpha.tsx': "import { deployFailed } from '../templates/deploy'\nexport const Alpha = () => <p>{deployFailed('1')}</p>\n",
    '/w/app/lib/emails/bravo.tsx': "export { Alpha } from './alpha'\n",
    '/w/app/lib/emails/charlie.tsx': "export { Alpha } from './bravo'\n",
    '/w/app/lib/emails/delta.tsx': "export { Alpha } from './charlie'\n",
  }
  const w = world($, on, { files: { [TEMPLATE]: TEMPLATE_TEXT, ...UI_CHAIN, ...deep } })
  const why = refusalOf(await call($, RETEMPLATE))
  expect(why).toContain('could not check')
  expect(why).toContain(`more than ${REEXPORT_HOPS} files`)
  expect(w.ran).toEqual([])
  // The other importer sends nothing, and the component is imported by a file that posts it to
  // Slack: the component is followed as before, and that file is named as the sender.
  for (const r of Object.keys(deep)) delete w.files[r]
  const CARD_POST = '/w/app/lib/card-post.ts'
  w.files['/w/app/lib/format.ts'] = "import { deployFailed } from './templates/deploy'\nexport const formatted = (id: string) => deployFailed(id).trim()\n"
  w.files[CARD_POST] = "import { DeployCard } from '../components/DeployCard'\nexport const post = () => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: String(DeployCard({ id: '1' })) }) })\n"
  expect(refusalOf(await call($, RETEMPLATE))).toContain(`which ${CARD_POST} sends to Slack`)
  expect(w.ran).toEqual([])
})

test('a UI component that sends the template to Slack itself, or through a send helper, is still held', withKit, async ($, on) => {
  const w = world($, on, {
    files: {
      [TEMPLATE]: TEMPLATE_TEXT,
      ...UI_CHAIN,
      [CARD]: "import { deployFailed } from '../lib/templates/deploy'\nexport const DeployCard = ({ id }: { id: string }) => <button onClick={() => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: deployFailed(id) }) })} />\n",
    },
  })
  expect(refusalOf(await call($, RETEMPLATE))).toContain(`which ${CARD} sends to Slack`)
  w.files[POST] = POST_TEXT
  w.files[CARD] = "import { deployFailed } from '../lib/templates/deploy'\nimport { postAlert } from '../src/lib/notify/post'\nexport const DeployCard = ({ id }: { id: string }) => <button onClick={() => postAlert(deployFailed(id))} />\n"
  expect(refusalOf(await call($, RETEMPLATE))).toContain(`which ${CARD} sends to Slack`)
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
  // One grep for the files that could post for the whole search, then each level is one grep listing
  // the files naming it, one listing their lines (and at most one for send helpers), and the loop
  // back to alpha.ts adds no level.
  expect(grepped(w) - before).toBeGreaterThan(2)
  expect(grepped(w) - before).toBeLessThanOrEqual(1 + 3 * (REEXPORT_HOPS + 1))
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

// claude-config#2462: a module imported by many files, in a repository of many more. Handlers import
// it, area barrels and routes import the handlers, and one file posting to Slack imports a route, so
// the module reaches Slack two files away. The cost of git grep is the world's measured one.
const HTTP = '/w/app/src/lib/http.ts'
const HTTP_TEXT = 'export const jsonError = (msg: string) => new Response(JSON.stringify({ error: `Request failed: ${msg}` }))\n'
const REHTTP = { tool: 'Edit', file_path: HTTP, old_string: 'Request failed: ${msg}', new_string: 'Request failed for ${msg}' }
const POSTER = '/w/app/src/alerts/notify.ts'
const AREAS = ['billing', 'accounts', 'orders', 'search', 'media', 'auth', 'reports', 'teams', 'webhooks', 'settings']
const widelyImported = (importers: number, others = 1200): Record<string, string> => {
  const files: Record<string, string> = { [HTTP]: HTTP_TEXT }
  const handlers: { area: string; name: string }[] = []
  for (let i = 0; i < importers; i++) {
    const area = AREAS[i % AREAS.length] as string
    const name = `${area}Handler${i}`
    handlers.push({ area, name })
    files[`/w/app/src/handlers/${area}/${name}.ts`] =
      `import { jsonError } from '../../lib/http'\nimport { query } from '../../lib/db'\n\nexport const handle${i} = async (id: string) => (id ? query(id) : jsonError('missing id'))\n`
  }
  for (const area of AREAS)
    files[`/w/app/src/handlers/${area}/index.ts`] = handlers.filter(h => h.area === area).map(h => `export * from './${h.name}'`).join('\n') + '\n'
  for (let r = 0; r < 60; r++) {
    const h = handlers[r % handlers.length] as { area: string; name: string }
    files[`/w/app/src/routes/route${r}.ts`] = `import * as area from '../handlers/${h.area}'\nimport { handle${r % handlers.length} } from '../handlers/${h.area}/${h.name}'\n\nexport const route${r} = { path: '/${h.area}/${r}', area, h: handle${r % handlers.length} }\n`
  }
  files[POSTER] =
    "import { route7 } from '../routes/route7'\nexport const notify = () => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: `Route ${route7.path} is failing` }) })\n"
  for (let f = 0; f < others; f++) files[`/w/app/src/other/pkg${f % 40}/mod${f}.ts`] = `import { query } from '../../lib/db'\n\nexport const thing${f} = () => query('select ${f}')\n`
  return files
}

test('a module imported by many files is searched within the limit, and the file two away that sends it is named', withKit, async ($, on) => {
  const w = world($, on, { files: widelyImported(60) })
  w.ctl.regexMsPerKb = 0.09
  const why = refusalOf(await call($, REHTTP))
  expect(why).not.toContain('could not check')
  expect(why).toContain(`which ${POSTER} sends to Slack`)
  expect(w.ran).toEqual([])
  // No regular expression git is asked to test grows with the files being traced: the names go to git
  // as fixed strings, and the only regular expressions are the two fixed Slack searches.
  const regexes = w.gits.filter(g => g.argv[3] === 'grep' && !g.argv.includes('-F')).flatMap(g => g.argv.filter((_, i) => g.argv[i - 1] === '-e'))
  expect(regexes.length).toBeGreaterThan(0)
  for (const r of regexes) expect([SENDER_PREFILTER, MARKER_PREFILTER]).toContain(r)
})

// Sized from real searches (#2510): on this Mac the largest repository the search walks (NurseDex,
// 1,061 JavaScript, TypeScript and python files) needed 213 reads for its widely imported utils.ts,
// taking 1.65 to 1.70 s at load 27 (about 8 ms a file, git included); a work repository's two copy
// files needed 185 reads in 1.8 to 2.1 s at load 33, and ran past the 3 s budget then in force even
// at load 6.4. widelyImported(n) reads n importers, 10 barrels and 60 routes.
test('a module whose search reads as many files as the largest real one gets a verdict naming its sender, at the cost measured per file (#2510)', withKit, async ($, on) => {
  const w = world($, on, { files: widelyImported(150) })
  w.ctl.regexMsPerKb = 0.09
  w.ctl.readMs = 8
  const why = refusalOf(await call($, REHTTP))
  expect(w.reads()).toBeGreaterThan(213)
  expect(why).not.toContain('could not check')
  expect(why).toContain(`which ${POSTER} sends to Slack`)
})

test("the work repository's 185 reads, at the per file cost that ran past the old budget on a quiet Mac, still get a verdict (#2510)", withKit, async ($, on) => {
  const w = world($, on, { files: widelyImported(115) })
  w.ctl.regexMsPerKb = 0.09
  // 20 ms a file: 185 files come to 3.7 s, past the 3 s budget the work repository ran out of.
  w.ctl.readMs = 20
  const why = refusalOf(await call($, REHTTP))
  expect(w.reads()).toBeGreaterThanOrEqual(185)
  expect(why).not.toContain('could not check')
  expect(why).toContain(`which ${POSTER} sends to Slack`)
})

test('the search leaves the hook time to refuse: its budget sits well inside the 10 s Claude Code gives a hook (#2510)', () => {
  // HookBudget.ms in the pinned Claude Code types: a hook running past it is killed.
  const HOOK_MS = 10_000
  expect(SCAN_MS).toBeGreaterThan(3000)
  expect(SCAN_MS).toBeLessThanOrEqual(HOOK_MS - 2500)
})

test('a module imported by more files than the guard reads is held for Dan, never let through, and never as could not check', withKit, async ($, on) => {
  // 70 more reads than importers (10 barrels and 60 routes), so this reads MOST_READ + 10.
  const w = world($, on, { files: widelyImported(MOST_READ - 60) })
  w.ctl.regexMsPerKb = 0.09
  const why = refusalOf(await call($, REHTTP))
  expect(why).not.toContain('could not check')
  expect(why).toContain('Request failed for ${msg}')
  expect(w.ran).toEqual([])
})

test('a short common name met only inside longer words lists no lines to test', withKit, async ($, on) => {
  const DB = '/w/app/src/lib/db.ts'
  const others: Record<string, string> = {}
  for (let f = 0; f < 50; f++) others[`/w/app/src/feedback/form${f}.ts`] = `export const feedbackDb${f} = 'feedback ${f}'\n`
  const w = world($, on, { files: { [DB]: 'export const label = `Database is down`\n', ...others } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: DB, old_string: 'Database is down', new_string: 'Database is unreachable' }))).toBe('')
  // The fifty files holding db only inside feedbackDb are not listed, so no line is printed to test.
  expect(w.printed).toEqual([])
  expect(w.gits.filter(g => g.argv.includes('-F') && g.argv.includes('-l')).length).toBe(1)
})

test('a search over a widely imported module that runs late, or whose listing is cut short, still holds the edit', withKit, async ($, on) => {
  const w = world($, on, { files: widelyImported(60, 0) })
  w.ctl.gitSlow = SCAN_MS / 2
  const late = refusalOf(await call($, REHTTP))
  expect(late).toContain('could not check')
  expect(late).toContain(`${SCAN_MS / 1000} seconds`)
  w.ctl.gitSlow = 0
  w.ctl.gitTruncated = true
  const cut = refusalOf(await call($, REHTTP))
  expect(cut).toContain('could not check')
  expect(cut).toContain('git grep listing the names of the files that')
  expect(w.ran).toEqual([])
})

// After #2481, 2026-11-08: an edit to a widely imported copy file in a work repository was held as could not check. The
// lines naming its importers, as git listed them, came to 9.9 MB, past what $.process.run keeps (4
// MiB), almost all of it that repository's design pages: HTML that mentions Slack, with lines of up to 730 KB.
// Here the cap is scaled down with the pages.
const designPages = (count: number, bytes: number): Record<string, string> => {
  const pages: Record<string, string> = {}
  for (let i = 0; i < count; i++)
    pages[`/w/app/docs/design/page${i}.html`] = `<h1>Slack alert preview</h1>\n<p>The http route for billing, as Slack shows it ${'x'.repeat(bytes)}</p>\n`
  return pages
}

test('a module named on lines too long for one listing, in pages that cannot send it, still gets a verdict', withKit, async ($, on) => {
  const w = world($, on, { files: { ...widelyImported(60, 0), ...designPages(10, 20_000) } })
  w.ctl.stdoutCap = 50_000
  const why = refusalOf(await call($, REHTTP))
  expect(why).not.toContain('could not check')
  expect(why).toContain(`which ${POSTER} sends to Slack`)
})

// A file that can send or hand on the template, one of whose lines alone runs past the cap, as a
// bundled or generated file's can.
const LONG = '/w/app/src/alerts/bundled.ts'
const LONG_TEXT = `import { jsonError } from '../lib/http'\nconst pad = 'http ${'x'.repeat(60_000)}'\nexport const notify = () => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: jsonError(pad) }) })\n`

test('a file whose one line is longer than a whole listing is read and judged, never passed over', withKit, async ($, on) => {
  const w = world($, on, { files: { ...widelyImported(60, 0), [LONG]: LONG_TEXT } })
  w.ctl.stdoutCap = 50_000
  expect(refusalOf(await call($, REHTTP))).toContain(`which ${LONG} sends to Slack`)
})

test('a file too long for a listing that then cannot be read holds the edit as could not check', withKit, async ($, on) => {
  const w = world($, on, { files: { ...widelyImported(60, 0), [LONG]: LONG_TEXT } })
  w.ctl.stdoutCap = 50_000
  w.ctl.unreadable = LONG
  const why = refusalOf(await call($, REHTTP))
  expect(why).toContain('could not check')
  expect(why).toContain(LONG)
  expect(w.ran).toEqual([])
})

test('a list of the files naming the template that is cut short holds the edit, never reads as none', withKit, async ($, on) => {
  const w = world($, on, { files: widelyImported(60, 0) })
  // Room for the Slack listing, too little for the sixty handlers naming http.
  w.ctl.stdoutCap = 500
  const why = refusalOf(await call($, REHTTP))
  expect(why).toContain('could not check')
  expect(why).toContain('git grep listing the names of the files that')
  expect(w.ran).toEqual([])
})

// 2026-11-09: a session held an edit to a widely imported copy file in a work repository as "git grep
// for the files that name it or hand it on failed (exit 0: no message)". git had not failed: what it
// printed was cut short. The words were the same before and after #2508 changed which listing runs,
// so the hold could not show that the session was still running the copy from before #2508.
test('a listing cut short is held as cut short, naming the listing, never as git failing with exit 0', withKit, async ($, on) => {
  const w = world($, on, { files: widelyImported(60, 0) })
  // Room for the Slack listing, too little for the names of the sixty handlers naming http.
  w.ctl.stdoutCap = 500
  const names = refusalOf(await call($, REHTTP))
  expect(names).toContain('could not check')
  expect(names).toContain('git grep listing the names of the files that name')
  expect(names).toContain('more than the 4 MiB')
  expect(names).not.toContain('exit 0')
  w.ctl.stdoutCap = Infinity
  w.ctl.gitTruncated = true
  const first = refusalOf(await call($, REHTTP))
  expect(first).toContain('git grep listing the names of the files that mention Slack')
  expect(first).toContain('more than the 4 MiB')
  expect(first).not.toContain('exit 0')
  expect(w.ran).toEqual([])
})

test('the files whose lines are listed are named to git in groups small enough for one command line', withKit, async ($, on) => {
  const files = widelyImported(60, 0)
  // Two thousand files with long paths naming http, each of which could hand it on.
  for (let i = 0; i < 2000; i++) files[`/w/app/src/generated/a-rather-long-folder-name-for-generated-code/${'segment/'.repeat(4)}client${i}.ts`] = `// generated from the http schema\nexport const c${i} = ${i}\n`
  const w = world($, on, { files })
  expect(refusalOf(await call($, REHTTP))).toContain(`which ${POSTER} sends to Slack`)
  const longest = Math.max(...w.gits.map(g => g.argv.reduce((n, a) => n + new TextEncoder().encode(a).length + 1, 0)))
  expect(longest).toBeLessThanOrEqual(PATHSPEC_BYTES + 10_000)
  expect(w.gits.filter(g => g.argv.some(a => a.startsWith(':(literal)'))).length).toBeGreaterThan(1)
})

test('the calls waiting on Dan are dropped at session end', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, REWORD))
  await ($ as unknown as { session: { end: (e: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  expect(refusalOf(await ask($, w, why, APPROVE))).toContain('No Slack alert edit is waiting')
})

// Only text a Slack send carries is held (#2570). Dan, 2026-11-09: "these aren't alerts that are going
// to fire into Slack, right? If not, I don't need you to ask me for approval." A route that posts to
// Slack also answers its caller, logs, and throws; none of that is Slack wording.
const BOOK = '/w/app/src/app/api/book/route.ts'
const BOOK_TEXT = [
  'export async function POST(req: Request) {',
  '  const body = await req.json()',
  "  if (body.taken) return Response.json({ error: 'That slot is already booked' }, { status: 409 })",
  "  await fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: `Booking ${body.id} was made` }) })",
  '  return Response.json({ ok: true })',
  '}',
  '',
].join('\n')
const bookEdit = (old_string: string, new_string: string) => ({ tool: 'Edit', file_path: BOOK, old_string, new_string })

test('in a route that posts to Slack, a new 409 answer, a log line and a thrown error pass; a changed or new Slack message is still held (#2570)', withKit, async ($, on) => {
  const w = world($, on, { files: { [BOOK]: BOOK_TEXT } })
  const answer = bookEdit('  if (body.taken)', "  if (body.past) return Response.json({ error: 'That slot is in the past' }, { status: 409 })\n  if (body.taken)")
  expect(refusalOf(await call($, answer))).toBe('')
  expect(refusalOf(await call($, bookEdit('  const body = await req.json()', "  console.log('Booking request received')\n  const body = await req.json()")))).toBe('')
  expect(refusalOf(await call($, bookEdit('  return Response.json({ ok: true })', "  if (!body.id) throw new Error('A booking came back with no id')\n  return Response.json({ ok: true })")))).toBe('')
  expect(w.ran.length).toBe(3)
  // The Slack message, changed and new, is held in the same file.
  expect(refusalOf(await call($, bookEdit('was made', 'was made by a client')))).toContain('Booking ${body.id} was made by a client')
  const fresh = bookEdit(
    '  return Response.json({ ok: true })',
    "  await fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: 'The booking queue is backing up' }) })\n  return Response.json({ ok: true })",
  )
  expect(refusalOf(await call($, fresh))).toContain('The booking queue is backing up')
  expect(w.ran.length).toBe(3)
})

test('a sentence moved out of a Slack posting file unchanged passes, as one moved within it does; the Slack message moved within it is no change either (#2570)', withKit, async ($, on) => {
  const w = world($, on, { files: { [BOOK]: BOOK_TEXT, '/w/app/src/lib/errors.ts': "export const TAKEN = 'That slot is already booked'\n" } })
  expect(refusalOf(await call($, bookEdit("{ error: 'That slot is already booked' }", '{ error: TAKEN }')))).toBe('')
  const within = BOOK_TEXT.replace('  const body = await req.json()', '  const body = await req.json()\n  const text = `Booking ${body.id} was made`').replace('{ text: `Booking ${body.id} was made` }', '{ text }')
  expect(refusalOf(await call($, { tool: 'Write', file_path: BOOK, content: within }))).toBe('')
  expect(w.ran.length).toBe(2)
})

const BOOKING_COPY = '/w/app/src/lib/notify/booking-copy.ts'
const BOOKING_COPY_TEXT = "export const lateBooking = (id: string) => `Booking ${id} is late`\nexport const NOT_FOUND = 'No booking has that id'\n"
const LATE = '/w/app/src/lib/notify/late.ts'
const LATE_TEXT = "import { lateBooking, NOT_FOUND } from './booking-copy'\nexport const run = (id: string) => sendSlackAlert(lateBooking(id))\nexport const miss = () => new Response(NOT_FOUND, { status: 404 })\n"

test('in a module a Slack sender imports, the text the sender sends is held naming it, and text it uses some other way passes (#2570)', withKit, async ($, on) => {
  const w = world($, on, { files: { [BOOKING_COPY]: BOOKING_COPY_TEXT, [LATE]: LATE_TEXT } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: BOOKING_COPY, old_string: 'No booking has that id', new_string: 'No booking has that id yet' }))).toBe('')
  expect(w.ran.length).toBe(1)
  const held = refusalOf(await call($, { tool: 'Edit', file_path: BOOKING_COPY, old_string: 'is late', new_string: 'is running late' }))
  expect(held).toContain('Booking ${id} is running late')
  expect(held).toContain(LATE)
})

test('a file that posts to Slack in a way the guard cannot trace is held as before', withKit, async ($, on) => {
  const CONFIG = '/w/app/src/lib/digest-config.ts'
  world($, on, { files: { [CONFIG]: "const CHANNEL = process.env.SLACK_ALERT_CHANNEL\nexport const config = { channel: CHANNEL, intro: 'Morning digest' }\n" } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: CONFIG, old_string: 'Morning digest', new_string: 'Morning digest for the team' }))).toContain('Morning digest for the team')
})

// A docstring documents code and is sent nowhere (#2574): on 2026-11-09 one added to a Slack gate's
// helper was held as Slack message text.
const DIGEST = '/w/app/jobs/digest.py'
const DIGEST_TEXT = [
  'import os',
  'from slack_sdk import WebClient',
  'client = WebClient(token=os.environ["SLACK_BOT_TOKEN"])',
  '',
  'def post_digest(rows):',
  '    client.chat_postMessage(channel="C1", text=f"{len(rows)} bookings are late")',
  '',
].join('\n')

test('a python docstring in a file that posts to Slack passes; the message the file posts is still held (#2574)', withKit, async ($, on) => {
  const w = world($, on, { files: { [DIGEST]: DIGEST_TEXT } })
  const helper = '\ndef count_late(rows):\n    """Count the bookings that are past their start time."""\n    return len([r for r in rows if r.late])\n'
  expect(refusalOf(await call($, { tool: 'Edit', file_path: DIGEST, old_string: 'bookings are late")\n', new_string: `bookings are late")\n${helper}` }))).toBe('')
  expect(w.ran.length).toBe(1)
  expect(refusalOf(await call($, { tool: 'Edit', file_path: DIGEST, old_string: 'bookings are late', new_string: 'bookings are running late' }))).toContain('{len(rows)} bookings are running late')
})

test('a module, class or function docstring passes even where the guard cannot trace the send, and a string beside them is still held (#2574)', withKit, async ($, on) => {
  const GATE = '/w/app/hooks/gate.py'
  const w = world($, on, { files: { [GATE]: 'SLACK_ALERT_CHANNEL = "C1"\nNOTE = "Gate ready"\n' } })
  const docs = (body: string) => ({ tool: 'Edit', file_path: GATE, old_string: 'NOTE = "Gate ready"\n', new_string: `NOTE = "Gate ready"\n${body}` })
  expect(refusalOf(await call($, { tool: 'Write', file_path: GATE, content: '"""Refuse every send that is not a draft."""\nSLACK_ALERT_CHANNEL = "C1"\nNOTE = "Gate ready"\n' }))).toBe('')
  w.files[GATE] = 'SLACK_ALERT_CHANNEL = "C1"\nNOTE = "Gate ready"\n'
  expect(refusalOf(await call($, docs('class Rule:\n    """One pattern the gate refuses, compiled once."""\n    pass\n')))).toBe('')
  expect(refusalOf(await call($, docs('def compiled(\n    patterns,\n):\n    """Compile the patterns that name a posting endpoint."""\n    return patterns\n')))).toBe('')
  expect(w.ran.length).toBe(3)
  expect(refusalOf(await call($, docs('LATE = "The gate refused a send"\n')))).toContain('The gate refused a send')
})

test('when the nearest sender sends none of the edited text, the search goes on and a sender further along that does is named (#2570)', withKit, async ($, on) => {
  const BARREL_COPY = '/w/app/src/lib/notify/index.ts'
  const NIGHTLY = '/w/app/src/jobs/nightly.ts'
  const w = world($, on, {
    files: {
      [BOOKING_COPY]: BOOKING_COPY_TEXT,
      [LATE]: "import { lateBooking } from './booking-copy'\nexport const run = (id: string) => sendSlackAlert(lateBooking(id))\n",
      [BARREL_COPY]: "export * from './booking-copy'\n",
      [NIGHTLY]: "import { NOT_FOUND } from '../lib/notify'\nexport const nightly = () => sendSlackAlert(NOT_FOUND)\n",
    },
  })
  const held = refusalOf(await call($, { tool: 'Edit', file_path: BOOKING_COPY, old_string: 'No booking has that id', new_string: 'No booking has that id yet' }))
  expect(held).toContain('No booking has that id yet')
  expect(held).toContain(NIGHTLY)
  expect(w.ran.length).toBe(0)
})

test('a sender that takes the module whole, where its names cannot be followed, holds the edit as before, naming it (#2570)', withKit, async ($, on) => {
  const BY_KEY = '/w/app/src/lib/notify/by-key.ts'
  const w = world($, on, { files: { [BOOKING_COPY]: BOOKING_COPY_TEXT, [BY_KEY]: "import * as copy from './booking-copy'\nexport const run = (key: string) => sendSlackAlert(copy[key])\n" } })
  const held = refusalOf(await call($, { tool: 'Edit', file_path: BOOKING_COPY, old_string: 'No booking has that id', new_string: 'No booking has that id yet' }))
  expect(held).toContain('No booking has that id yet')
  expect(held).toContain(BY_KEY)
  expect(w.ran.length).toBe(0)
})

test('a search that runs late after finding a sender that sends none of the change holds the rest, naming that sender, never passing it (#2570)', withKit, async ($, on) => {
  const BARREL_COPY = '/w/app/src/lib/notify/index.ts'
  const files = {
    [BOOKING_COPY]: BOOKING_COPY_TEXT,
    [LATE]: "import { lateBooking } from './booking-copy'\nexport const run = (id: string) => sendSlackAlert(lateBooking(id))\n",
    [BARREL_COPY]: "export * from './booking-copy'\n",
  }
  const edit = { tool: 'Edit', file_path: BOOKING_COPY, old_string: 'No booking has that id', new_string: 'No booking has that id yet' }
  // With time to follow the barrel and find nothing further sending it, the edit passes.
  const w = world($, on, { files })
  expect(refusalOf(await call($, edit))).toBe('')
  expect(w.ran.length).toBe(1)
  // Each read taking most of the deadline, the search stops at the barrel's importers with only the
  // nearest sender in hand, so the change is held as before rather than let through unsearched.
  // Sized from SCAN_MS (8/15 of it, which was 1600 ms at 3 s), so the two reads after the deadline is
  // set still overrun it whatever the deadline is: a fixed 1600 let the search finish once it was 7 s.
  w.ctl.readMs = Math.ceil(SCAN_MS * 8 / 15)
  const held = refusalOf(await call($, edit))
  expect(held).toContain('No booking has that id yet')
  expect(held).toContain(`which ${LATE} sends to Slack`)
  expect(w.ran.length).toBe(1)
})

// claude-config#2637: on 2026-11-10 a builder wrote a new copy module (two pages and two all clears
// for a "feed has gone quiet" alarm) that a monitor route imports and posts to Slack. Nothing sent the
// module when it was written, so the Write passed; the edits that made the route import and send it
// added no text of their own, so they passed too, and the wording reached a branch unapproved.
const QUIET = '/w/app/src/lib/monitor/quiet-feed-copy.ts'
const QUIET_TEXT = [
  'export const quietPage = (feed: string, minutes: number) => `The ${feed} feed has gone quiet: nothing has arrived for ${minutes} minutes`',
  'export const quietAgain = (feed: string) => `The ${feed} feed is still quiet, so somebody needs to look at it now`',
  'export const quietClear = (feed: string) => `The ${feed} feed is sending again`',
  "export const allClear = 'Every feed is sending again'",
  "export const CHECKED = 'Checked every feed for a quiet one'",
  '',
].join('\n')
const MONITOR = '/w/app/src/app/api/monitor/route.ts'
const MONITOR_TEXT = [
  "import { lateBooking } from '@/lib/notify/outage-copy'",
  "import { postAlert } from '@/lib/notify/post'",
  'export const GET = async () => {',
  "  await postAlert(lateBooking('1'))",
  '  return Response.json({ ok: true })',
  '}',
  '',
].join('\n')
const QUIET_IMPORT = "import { quietPage, quietClear, CHECKED } from '@/lib/monitor/quiet-feed-copy'\n"
const listedFiles = (w: W, from = 0) => w.gits.slice(from).filter(g => g.argv[3] === 'ls-files').length

// claude-config#2720: the same module, held as it is written. Nothing sends it yet, but it is a
// module of message copy by its name and by its shape, so its wording is asked about then, in the
// file that holds it, rather than later at an edit that carries no words of its own.
const QUIET_SHOWN = [
  'The orders feed has gone quiet: nothing has arrived for 45 minutes',
  'The orders feed is still quiet, so somebody needs to look at it now',
  'The orders feed is sending again',
  'Every feed is sending again',
  'Checked every feed for a quiet one',
].join('\n')

test('a new copy module is held as it is written, though nothing sends it yet, naming no sender; once Dan approves, the edits that make a route send it go through (#2720)', withKit, async ($, on) => {
  const w = world($, on, { files: { [COPY]: COPY_TEXT, [POST]: POST_TEXT, [MONITOR]: MONITOR_TEXT } })
  const write = { tool: 'Write', file_path: QUIET, content: QUIET_TEXT }
  const held = refusalOf(await call($, write))
  expect(held).toContain(QUIET)
  expect(held).toContain('The ${feed} feed has gone quiet: nothing has arrived for ${minutes} minutes')
  expect(held).toContain('Every feed is sending again')
  // Nothing sends it, so no sender is named.
  expect(held).not.toContain('sends to Slack')
  expect(held).not.toContain(MONITOR)
  expect(w.ran).toEqual([])
  expect(w.cards.length).toBe(1)
  await ask($, w, held, APPROVE, { rendered: QUIET_SHOWN })
  // The question names the file that holds the wording.
  expect(w.asked[0]?.questions[0]?.question).toContain(QUIET)
  // Approving posts nothing (#2284), so the question above the message never reads as a send.
  expect(readsAsSend((w.asked[0]?.questions[0]?.question ?? '').split('\n\n')[0] ?? '')).toBe(false)
  expect(refusalOf(await call($, write))).toBe('')
  // The wording is approved, so the import and the send that bring it to Slack are not asked again.
  expect(refusalOf(await call($, { tool: 'Write', file_path: MONITOR, content: QUIET_IMPORT + MONITOR_TEXT }))).toBe('')
  const send = { tool: 'Edit', file_path: MONITOR, old_string: "  await postAlert(lateBooking('1'))\n", new_string: "  await postAlert(lateBooking('1'))\n  await postAlert(quietPage('orders', 45))\n" }
  expect(refusalOf(await call($, send))).toBe('')
  expect(w.ran.length).toBe(3)
})

test('a copy module nothing sends is held by its shape under any name, and by its name with one message; an ordinary module beside it is not (#2720)', withKit, async ($, on) => {
  const w = world($, on)
  // By shape: functions building message text, in a file whose name says nothing.
  const SHAPED = '/w/app/src/lib/monitor/quiet.ts'
  const shaped = refusalOf(await call($, { tool: 'Write', file_path: SHAPED, content: QUIET_TEXT }))
  expect(shaped).toContain(SHAPED)
  expect(shaped).toContain('The ${feed} feed is sending again')
  // By name: one message in a file named as copy.
  const NAMED = '/w/app/src/lib/ops/late-copy.ts'
  const named = refusalOf(await call($, { tool: 'Write', file_path: NAMED, content: 'export const late = (id: string) => `Booking ${id} is running late`\n' }))
  expect(named).toContain(NAMED)
  expect(named).toContain('Booking ${id} is running late')
  // By an edit to one already there, too.
  w.files[NAMED] = 'export const late = (id: string) => `Booking ${id} is late`\n'
  expect(refusalOf(await call($, { tool: 'Edit', file_path: NAMED, old_string: 'is late', new_string: 'is very late' }))).toContain('Booking ${id} is very late')
  // An ordinary module with the same single message, and an edit to the copy module that adds no
  // wording, both pass.
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/app/src/lib/ops/late.ts', content: 'export const late = (id: string) => `Booking ${id} is running late`\n' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: NAMED, old_string: '(id: string)', new_string: '(id: number)' }))).toBe('')
  expect(w.ran.length).toBe(2)
})

test('a copy module in no repository, in a test, or already used by a screen or a route that sends nothing passes; one only a test imports is held (#2720)', withKit, async ($, on) => {
  const w = world($, on, {
    files: {
      '/w/app/src/lib/ui/banner-copy.ts': 'export const BANNER = 1\n',
      '/w/app/src/components/Banner.tsx': "import { BANNER } from '../lib/ui/banner-copy'\nexport const Banner = () => <p>{BANNER}</p>\n",
      '/w/app/src/lib/api/miss-copy.ts': 'export const BANNER = 1\n',
      '/w/app/src/app/api/miss/route.ts': "import { BANNER } from '@/lib/api/miss-copy'\nexport const GET = () => new Response(String(BANNER))\n",
      '/w/app/src/lib/ops/late-copy.ts': 'export const BANNER = 1\n',
      '/w/app/src/lib/ops/late-copy.test.ts': "import { BANNER } from './late-copy'\nit('is one', () => expect(BANNER).toBe(1))\n",
    },
  })
  const add = (file: string) => ({ tool: 'Write', file_path: file, content: 'export const BANNER = 1\nexport const late = (id: string) => `Booking ${id} is running late`\n' })
  expect(refusalOf(await call($, add('/private/tmp/scratch/late-copy.ts')))).toBe('')
  expect(refusalOf(await call($, add('/w/app/src/lib/__tests__/late-copy.ts')))).toBe('')
  // Used already, by a screen (#2519) or a route answering with it: judged by what that use sends.
  expect(refusalOf(await call($, add('/w/app/src/lib/ui/banner-copy.ts')))).toBe('')
  expect(refusalOf(await call($, add('/w/app/src/lib/api/miss-copy.ts')))).toBe('')
  expect(w.ran.length).toBe(4)
  // A test using it is no use: what the module is for is still not wired.
  expect(refusalOf(await call($, add('/w/app/src/lib/ops/late-copy.ts')))).toContain('Booking ${id} is running late')
  expect(w.ran.length).toBe(4)
})

// The send edit judged for what it brings in (#2637), from a module that is not one of message copy:
// one message among other values, so only the send asks.
const FEEDS = '/w/app/src/lib/monitor/feeds.ts'
const FEEDS_TEXT = "export const quietPage = (feed: string, minutes: number) => `The ${feed} feed has gone quiet: nothing has arrived for ${minutes} minutes`\nexport const CHECKED = 'Checked every feed for a quiet one'\nexport const LIMIT = 45\n"
test('a new module that is no copy module passes while nothing sends it; the edit that makes a route send it is held for the wording it brings in, then goes through once Dan approves (#2637)', withKit, async ($, on) => {
  const w = world($, on, { files: { [COPY]: COPY_TEXT, [POST]: POST_TEXT, [MONITOR]: MONITOR_TEXT } })
  expect(refusalOf(await call($, { tool: 'Write', file_path: FEEDS, content: FEEDS_TEXT }))).toBe('')
  // The import alone sends nothing of the module yet, so it passes: what is held is the send.
  expect(refusalOf(await call($, { tool: 'Write', file_path: MONITOR, content: "import { quietPage, CHECKED } from '@/lib/monitor/feeds'\n" + MONITOR_TEXT }))).toBe('')
  expect(w.ran.length).toBe(2)
  const send = { tool: 'Edit', file_path: MONITOR, old_string: "  await postAlert(lateBooking('1'))\n", new_string: "  await postAlert(lateBooking('1'))\n  await postAlert(quietPage('orders', 45))\n  console.log(CHECKED)\n" }
  const held = refusalOf(await call($, send))
  expect(held).toContain('The ${feed} feed has gone quiet: nothing has arrived for ${minutes} minutes')
  expect(held).toContain(FEEDS)
  expect(held).toContain(MONITOR)
  // Only what the send carries: never the line it logs, or the wording the route already sent.
  expect(held).not.toContain('Checked every feed')
  expect(held).not.toContain('is late')
  expect(w.ran.length).toBe(2)
  expect(w.cards.length).toBe(1)
  await ask($, w, held, APPROVE, { rendered: 'The orders feed has gone quiet: nothing has arrived for 45 minutes' })
  expect(w.asked[0]?.questions[0]?.question).toContain(FEEDS)
  expect(refusalOf(await call($, send))).toBe('')
  expect(w.ran.length).toBe(3)
})

test('one change that writes a new sender over a new copy module is held for every message it sends, whether it posts by itself or through a send helper (#2637)', withKit, async ($, on) => {
  const w = world($, on, { files: { [POST]: POST_TEXT, [QUIET]: QUIET_TEXT } })
  const route = `${QUIET_IMPORT}import { quietAgain, allClear } from '@/lib/monitor/quiet-feed-copy'\nimport { postAlert } from '@/lib/notify/post'\nexport const GET = async (quiet: boolean) => {\n  console.log(CHECKED)\n  return postAlert(quiet ? quietPage('orders', 45) : allClear)\n}\n`
  const held = refusalOf(await call($, { tool: 'Write', file_path: MONITOR, content: route }))
  expect(held).toContain('feed has gone quiet')
  expect(held).toContain('Every feed is sending again')
  expect(held).toContain(QUIET)
  expect(held).not.toContain('Checked every feed')
  expect(held).not.toContain('still quiet')
  // A file that posts by itself, with no helper between.
  const PAGE = '/w/app/src/lib/monitor/page.ts'
  const page = "import { quietAgain } from './quiet-feed-copy'\nexport const page = (feed: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: quietAgain(feed) }) })\n"
  const direct = refusalOf(await call($, { tool: 'Write', file_path: PAGE, content: page }))
  expect(direct).toContain('feed is still quiet, so somebody needs to look at it now')
  expect(direct).toContain(QUIET)
  expect(direct).not.toContain('gone quiet')
  expect(w.ran).toEqual([])
})

test('wording a sender newly reaches through a barrel it already imports, or in a module it already imports, is held; the barrel gaining the module is not, while nothing sends it (#2637)', withKit, async ($, on) => {
  const BARREL_COPY = '/w/app/src/lib/monitor/index.ts'
  const NIGHTLY = '/w/app/src/jobs/nightly.ts'
  const NIGHTLY_TEXT = "import { quietClear } from '../lib/monitor'\nexport const nightly = (text: string) => sendSlackAlert(text)\n"
  const w = world($, on, { files: { [QUIET]: QUIET_TEXT, [BARREL_COPY]: 'export const VERSION = 1\n', [NIGHTLY]: NIGHTLY_TEXT, [BOOKING_COPY]: BOOKING_COPY_TEXT, [LATE]: LATE_TEXT } })
  expect(refusalOf(await call($, { tool: 'Write', file_path: BARREL_COPY, content: "export const VERSION = 1\nexport * from './quiet-feed-copy'\n" }))).toBe('')
  expect(w.ran.length).toBe(1)
  const through = refusalOf(await call($, { tool: 'Edit', file_path: NIGHTLY, old_string: 'sendSlackAlert(text)', new_string: "sendSlackAlert(text || quietClear('orders'))" }))
  expect(through).toContain('The ${feed} feed is sending again')
  expect(through).toContain(QUIET)
  expect(through).not.toContain('gone quiet')
  // No import changes at all: a name the sender already imported for a 404 answer is now sent.
  const already = refusalOf(await call($, { tool: 'Edit', file_path: LATE, old_string: 'sendSlackAlert(lateBooking(id))', new_string: 'sendSlackAlert(id ? lateBooking(id) : NOT_FOUND)' }))
  expect(already).toContain('No booking has that id')
  expect(already).toContain(BOOKING_COPY)
  expect(already).not.toContain('is late')
  expect(w.ran.length).toBe(1)
})

test('an edit that brings no new wording to a send passes: more use of what a sender already sent, a name used some other way, and any import in a file nothing sends (#2637)', withKit, async ($, on) => {
  const HELP = '/w/app/src/lib/help.ts'
  const w = world($, on, { files: { [BOOKING_COPY]: BOOKING_COPY_TEXT, [LATE]: LATE_TEXT, [QUIET]: QUIET_TEXT, [HELP]: 'export const help = () => 1\n' } })
  // The route already sent lateBooking, wording older than the guard: sending it once more is no new alert.
  expect(refusalOf(await call($, { tool: 'Edit', file_path: LATE, old_string: 'export const miss', new_string: 'export const again = (id: string) => sendSlackAlert(lateBooking(id))\nexport const miss' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: LATE, old_string: 'export const miss', new_string: 'export const gone = () => new Response(NOT_FOUND, { status: 410 })\nexport const miss' }))).toBe('')
  expect(w.ran.length).toBe(2)
  // A file on no path to Slack: the search for what sends it runs, and no imported module is listed or read.
  const before = w.gits.length
  expect(refusalOf(await call($, { tool: 'Write', file_path: HELP, content: "import { allClear } from './monitor/quiet-feed-copy'\nexport const help = () => allClear\n" }))).toBe('')
  expect(w.gits.length).toBeGreaterThan(before)
  expect(listedFiles(w, before)).toBe(0)
  expect(w.ran.length).toBe(3)
})

test('wording an edit may bring to a send is held, never let through, when the search runs late or the imported module cannot be read (#2637)', withKit, async ($, on) => {
  const w = world($, on, { files: { [COPY]: COPY_TEXT, [POST]: POST_TEXT, [MONITOR]: QUIET_IMPORT + MONITOR_TEXT, [QUIET]: QUIET_TEXT } })
  const send = { tool: 'Edit', file_path: MONITOR, old_string: "  await postAlert(lateBooking('1'))\n", new_string: "  await postAlert(quietPage('orders', 45))\n" }
  w.ctl.unreadable = QUIET
  const unread = refusalOf(await call($, send))
  expect(unread).toContain('could not check')
  expect(unread).toContain(QUIET)
  w.ctl.unreadable = ''
  w.ctl.gitSlow = SCAN_MS + 1
  expect(refusalOf(await call($, send))).toContain(`not searched within ${SCAN_MS / 1000} seconds`)
  w.ctl.gitSlow = 0
  w.ctl.gitFails = 'fatal: unable to read tree'
  expect(refusalOf(await call($, send))).toContain('could not check')
  expect(w.ran).toEqual([])
  // With the search able to finish, the same edit is held for the wording, so the three above were
  // the guard failing closed, never a guard with nothing to hold.
  w.ctl.gitFails = ''
  expect(refusalOf(await call($, send))).toContain('feed has gone quiet')
})

test('where the names sent cannot be followed, every message of a newly imported module is held: a sender taking the edited module whole is named, and a search that stops short names none (#2637)', withKit, async ($, on) => {
  const BY_KEY = '/w/app/src/lib/notify/by-key.ts'
  const BARREL_COPY = '/w/app/src/lib/monitor/index.ts'
  const many: Record<string, string> = {}
  // Each names the barrel as an import does, and a Slack webhook only in a comment, which git cannot
  // tell from code, so each must be read: one more than the guard reads.
  for (let i = 0; i <= MOST_READ; i++) many[`/w/app/src/lib/jobs/job${i}.ts`] = `// news went to hooks.slack.com\nimport { VERSION } from '../monitor'\nexport const n${i} = VERSION\n`
  const w = world($, on, {
    files: { [QUIET]: QUIET_TEXT, [BOOKING_COPY]: BOOKING_COPY_TEXT, [BY_KEY]: "import * as copy from './booking-copy'\nexport const run = (key: string) => sendSlackAlert(copy[key])\n", [BARREL_COPY]: 'export const VERSION = 1\n', ...many },
  })
  const whole = refusalOf(await call($, { tool: 'Write', file_path: BOOKING_COPY, content: `export * from '../monitor/quiet-feed-copy'\n${BOOKING_COPY_TEXT}` }))
  for (const s of ['feed has gone quiet', 'still quiet', 'feed is sending again', 'Every feed is sending again']) expect(whole).toContain(s)
  expect(whole).toContain(`makes ${BY_KEY} send Slack message text from ${QUIET}`)
  // What the module already held is no part of this edit.
  expect(whole).not.toContain('is late')
  const short = refusalOf(await call($, { tool: 'Write', file_path: BARREL_COPY, content: "export const VERSION = 1\nexport * from './quiet-feed-copy'\n" }))
  expect(short).not.toContain('could not check')
  expect(short).toContain('feed has gone quiet')
  expect(short).toContain(`makes it send Slack message text from ${QUIET}`)
  expect(idIn(short)).toBeDefined()
  expect(w.ran).toEqual([])
})

test('once Dan approves what the nearest sender sends, the rest of the same edit is still held for the sender further along that sends it', withKit, async ($, on) => {
  const BARREL_COPY = '/w/app/src/lib/notify/index.ts'
  const NIGHTLY = '/w/app/src/jobs/nightly.ts'
  const w = world($, on, {
    files: {
      [BOOKING_COPY]: BOOKING_COPY_TEXT,
      [LATE]: "import { lateBooking } from './booking-copy'\nexport const run = (id: string) => sendSlackAlert(lateBooking(id))\n",
      [BARREL_COPY]: "export * from './booking-copy'\n",
      [NIGHTLY]: "import { NOT_FOUND } from '../lib/notify'\nexport const nightly = () => sendSlackAlert(NOT_FOUND)\n",
    },
  })
  const both = { tool: 'Write', file_path: BOOKING_COPY, content: BOOKING_COPY_TEXT.replace('is late', 'is running late').replace('has that id', 'has that id yet') }
  const first = refusalOf(await call($, both))
  expect(first).toContain('Booking ${id} is running late')
  expect(first).toContain(LATE)
  await ask($, w, first, APPROVE, { rendered: 'Booking 4182 is running late' })
  // The nearest sender's wording is approved now; the 404 text only the nightly job sends is not.
  const second = refusalOf(await call($, both))
  expect(second).toContain('No booking has that id yet')
  expect(second).toContain(NIGHTLY)
  expect(w.ran).toEqual([])
  await ask($, w, second, APPROVE, { rendered: 'No booking has that id yet' })
  expect(refusalOf(await call($, both))).toBe('')
  expect(w.ran.length).toBe(1)
})

// Code that names a Slack endpoint only to refuse or match it posts nothing (#2662; Dan, 2026-11-10:
// "Recognise refusal code"). The Slack drafts gate names chat.postMessage and hooks.slack.com in a
// pattern so it can refuse them, and the guard read it as a file that posts: on 2026-11-09 it held
// what the gate prints on stderr to a refused session as "Slack message text Dan has not approved"
// (Dan: "you see that that's not a slack alert right?"), and edits to lib/issue-spool.sh, which the
// gate's docstrings name. The lines below are the gate's own, as payload/hooks has them; that the
// whole real files read the same way is held by tests/test-slack-alert-guard-real-gate.sh.
const GATE_SH = '/w/app/payload/hooks/slack-drafts-only-gate.sh'
const GATE_SH_TEXT = String.raw`#!/bin/bash
#   * a Bash command that makes the request: curl, wget and the like aimed at chat.postMessage,
#     chat.scheduleMessage, chat.postEphemeral, chat.meMessage or hooks.slack.com; inline code or a
shopt -s nocasematch
MARKERS='chat[._](postmessage|schedulemessage|postephemeral|memessage)|hooks\.slack\.com|slack_webhook|slack_(send|schedule|post)_message|slack_reply_to_thread'
couldnt() {
  printf 'BLOCKED: slack-drafts-only-gate.sh could not judge this call (%s), so whether it sends a Slack message was not checked, and a send is the one thing this gate exists to stop (claude-config#2302). To put a message in Slack, call slack_send_message_draft with the same channel and thread, then tell Dan where the draft is. If this call does not touch Slack, the gate itself is broken: say so to Dan.\n' "$1" >&2
  exit 2
}
out="$(printf '%s' "$payload" | GATE_DIR="$HOOK_DIR" python3 "$HOOK_DIR/slack_drafts_only_gate.py" 2>&1)"
case "$verdict" in
  allow) exit 0 ;;
  refuse) printf '%s\n' "$detail" >&2; exit 2 ;;
  unreadable)
    if [ -n "$have_scope" ]; then
      ps_unparsed_refuse "$payload" slack-drafts-only-gate.sh - "a Slack send" \
        '*chat[._]postmessage*' '*chat[._]schedulemessage*' '*chat[._]postephemeral*' '*chat[._]memessage*' \
        '*hooks.slack.com*' '*slack_webhook*' '*slack_send_message*' '*slack_schedule_message*' \
        '*slack_post_message*' '*slack_reply_to_thread*'
    fi
    if payload_match "$payload" "$MARKERS"; then
      printf 'BLOCKED: slack-drafts-only-gate.sh could not read its hook payload as a call (%s), and the payload names a Slack send route, so whether this sends a Slack message could not be checked (claude-config#2302, #1922). Save a draft with slack_send_message_draft instead.\n' "$detail" >&2
      exit 2
    fi
    exit 0
    ;;
esac
`
// The edit the guard held on 2026-11-09 (#2576): the advice the gate prints, on stderr, to a session
// whose merge it could not judge in time. Nothing posts it anywhere.
const ADVICE =
  'This call runs merge-when-ready.sh, so do not retry it in a loop. If one more try is refused the same way, merge the pull request without the helper once every check on it is green: gh pr merge <number> --repo <owner>/<repo> --squash, with no --delete-branch (the helper deletes a branch only after moving the pull requests stacked on it), then confirm with gh pr view <number> --repo <owner>/<repo> --json state, and tell Dan the helper could not be started and the branch is still there.'
const MERGE_INSTEAD = String.raw`merge_instead() {
  case "$payload" in *merge-when-ready.sh*) ;; *) return 0 ;; esac
  printf '%s\n' '${ADVICE}' >&2
}
`
const ADVISE = (file: string) => ({ tool: 'Edit', file_path: file, old_string: 'case "$verdict" in', new_string: `${MERGE_INSTEAD}case "$verdict" in` })

test("what the Slack drafts gate prints to a refused session passes: the gate names Slack's endpoints only to refuse them (#2662)", withKit, async ($, on) => {
  const w = world($, on, { files: { [GATE_SH]: GATE_SH_TEXT } })
  expect(refusalOf(await call($, ADVISE(GATE_SH)))).toBe('')
  // By a shell write too, whose wording cannot be read before it runs.
  expect(refusalOf(await call($, { tool: 'Bash', command: `printf 'exit 0\\n' >> ${GATE_SH}` }))).toBe('')
  expect(w.ran.map(x => x.tool)).toEqual(['Edit', 'Bash'])
  expect(w.cards).toEqual([])
})

test('a script that refuses a Slack post and also makes one is still held: the half that posts is a sender (#2662)', withKit, async ($, on) => {
  const BOTH = '/w/app/payload/hooks/gate-and-tell.sh'
  const posting = `${GATE_SH_TEXT}tell_dan() {\n  curl -s -X POST -H 'Content-type: application/json' --data "{\\"text\\":\\"$1\\"}" "$SLACK_WEBHOOK_URL"\n}\n`
  const w = world($, on, { files: { [BOTH]: posting } })
  const why = refusalOf(await call($, ADVISE(BOTH)))
  expect(why).toContain(BOTH)
  expect(why).toContain('do not retry it in a loop')
  expect(refusalOf(await call($, { tool: 'Bash', command: `printf 'exit 0\\n' >> ${BOTH}` }))).toContain('shell command')
  expect(w.ran).toEqual([])
})

test('a file that matches a Slack endpoint and then calls it is still held, in a glob and in a pattern (#2662)', withKit, async ($, on) => {
  const RELAY = '/w/app/scripts/relay.sh'
  const GREP = '/w/app/scripts/relay-if-slack.sh'
  const w = world($, on, {
    files: {
      [RELAY]: '#!/bin/bash\ncase "$1" in\n  *hooks.slack.com*) curl -s -X POST --data "Relay is down" "$1" ;;\nesac\n',
      [GREP]: '#!/bin/bash\nif printf \'%s\' "$1" | grep -q -E \'hooks\\.slack\\.com|slack_webhook\'; then\n  wget -q --post-data "Relay is down" "$1"\nfi\n',
    },
  })
  for (const file of [RELAY, GREP]) {
    const why = refusalOf(await call($, { tool: 'Edit', file_path: file, old_string: 'Relay is down', new_string: 'Relay is down again' }))
    expect(why).toContain(file)
    expect(why).toContain('Relay is down again')
  }
  expect(w.ran).toEqual([])
})

test('a new chat.postMessage call and a new curl to a webhook, each with new wording, are still held (#2662)', withKit, async ($, on) => {
  const CALL = '/w/app/src/jobs/backup-alert.ts'
  const CURL = '/w/app/scripts/deploy-notice.sh'
  const w = world($, on)
  const posted = refusalOf(await call($, { tool: 'Write', file_path: CALL, content: "export const late = (client: Client) => client.chat.postMessage({ channel: 'C1', text: 'Backup is late' })\n" }))
  expect(posted).toContain(CALL)
  expect(posted).toContain('Backup is late')
  const curled = refusalOf(await call($, { tool: 'Write', file_path: CURL, content: '#!/bin/bash\ncurl -s -X POST --data "Deploy finished on production" https://hooks.slack.com/services/T000/B000/XXXX\n' }))
  expect(curled).toContain(CURL)
  expect(curled).toContain('Deploy finished on production')
  expect(w.ran).toEqual([])
})

// The gate's python half, in its own lines: the pattern it matches a command against, the programs
// it knows make a request (names it reads, never runs), and a docstring naming the script whose
// heredocs it reads. The guard read the gate as a sender and that line as the gate reading
// issue-spool.sh, so every edit to issue-spool.sh was held as wording the gate sends to Slack.
const GATE_PY = '/w/app/payload/hooks/slack_drafts_only_gate.py'
const GATE_PY_TEXT = String.raw`import ast
import os
import re

MARKER = re.compile(r"chat[._](postMessage|scheduleMessage|postEphemeral|meMessage)|hooks\.slack\.com|slack_webhook",
                    re.I)
SEND_TOOLS = {"slack_send_message", "slack_schedule_message", "slack_post_message", "slack_reply_to_thread"}
SENDERS = {"curl", "wget", "http", "https", "xh", "httpie", "curlie"}


def sh_env_code(assigns, body, names):
    """{NAME: text} for each NAME="$VAR" in front of a command where VAR holds Python the script
    wrote. Inline code is read from lib/issue-spool.sh as one text."""
    return {}
`
const SPOOL = '/w/app/payload/hooks/lib/issue-spool.sh'
const SPOOL_TEXT = '#!/bin/bash\nnote() {\n  printf \'%s\\n\' "Recorded the finding" >&2\n}\n'
const RESPOOL = { tool: 'Edit', file_path: SPOOL, old_string: 'Recorded the finding', new_string: 'Recorded the finding for the next issue review' }

test('an edit to a script the Slack drafts gate names passes: a gate that only matches endpoints sends nothing (#2662)', withKit, async ($, on) => {
  const w = world($, on, { files: { [GATE_PY]: GATE_PY_TEXT, [SPOOL]: SPOOL_TEXT } })
  expect(refusalOf(await call($, RESPOOL))).toBe('')
  // The gate's own refusal wording passes too.
  expect(refusalOf(await call($, { tool: 'Edit', file_path: GATE_PY, old_string: '    return {}', new_string: '    raise SystemExit("REFUSED: this command posts to Slack. Save it as a draft instead.")' }))).toBe('')
  expect(w.ran.length).toBe(2)
  // The search ran, so the pass is the guard deciding (the gate is read, and is no sender).
  expect(w.gits.some(g => g.argv.includes('grep'))).toBe(true)
})

test('the same script is still held when a file that really posts to Slack reads it (#2662)', withKit, async ($, on) => {
  const POSTER = '/w/app/payload/hooks/spool-digest.py'
  const w = world($, on, {
    files: {
      [GATE_PY]: GATE_PY_TEXT,
      [SPOOL]: SPOOL_TEXT,
      [POSTER]: 'import os\nimport urllib.request\nbody = open("payload/hooks/lib/issue-spool.sh").read()\nurllib.request.urlopen(os.environ["SLACK_WEBHOOK_URL"], data=body.encode())\n',
    },
  })
  const why = refusalOf(await call($, RESPOOL))
  expect(why).toContain('Recorded the finding for the next issue review')
  expect(why).toContain(`which ${POSTER} sends to Slack`)
  expect(w.ran).toEqual([])
})

// claude-config#2719: on 2026-11-10, in a work repository, every Edit to a 5,488 line monitor route
// that posts through a Slack send helper was held as "was not searched within 7 seconds" or
// "$.process.run(git) aborted: still running after 12ms", a one line import among them, while every
// smaller file went through. git and the reads were not the time: tracing the file's sends was,
// and it grew with the square of the file, since each name's declarations were found by searching
// the whole file once per name. A route of checks, each with its own names as a real one has, judged
// on the wall (the test clock moved on by the real time the guard spends). This route is lighter
// per line than the real one: at 5,500 lines the guard before the fix took 2.0 to 2.6 s an edit on
// the personal MacBook at load 15 to 41, and at 11,000 lines 8.3 s, held as "git could not name the
// repository", the third message the real file met. So it is judged at 11,000 lines, where the
// guard before the fix fails here as it failed there.
const BIG = '/w/app/src/app/api/monitor/feeds/route.ts'
const BIG_LINES = 11_000
const bigCheck = (i: number, helper: string) => `
// Check ${i}: rows of kind ${i} that have not moved in a day.
export async function check${i}(db: Db, now: Date): Promise<CheckResult> {
  const since${i} = new Date(now.getTime() - 86_400_000).toISOString()
  const rows${i} = await db.query(
    \`select id, status, updated_at from items_${i} where status = 'pending' and updated_at < $1 order by updated_at limit 500\`,
    [since${i}],
  )
  if (!rows${i}.length) return { name: 'check${i}', ok: true }
  const ids${i} = rows${i}.map((r: Row) => r.id).slice(0, 10).join(', ')
  const label${i} = rows${i}.length === 1 ? 'item' : 'items'
  logger.info(\`check${i}: found \${rows${i}.length} \${label${i}}\`, { since: since${i} })
  const summary${i} = \`\${rows${i}.length} \${label${i}} of kind ${i} have been pending since \${since${i}}: \${ids${i}}\`
  const oldest${i} = rows${i}.reduce((a: Row, b: Row) => (a.updated_at < b.updated_at ? a : b))
  const ageHours${i} = Math.round((now.getTime() - new Date(oldest${i}.updated_at).getTime()) / 3_600_000)
  const owners${i} = new Set(rows${i}.map((r: Row) => r.owner_id))
  const ownerList${i} = [...owners${i}].slice(0, 5).join(', ')
  const severity${i} = ageHours${i} > 48 ? 'high' : ageHours${i} > 24 ? 'medium' : 'low'
  const detail${i} = \`\${summary${i}} (oldest \${ageHours${i}} hours, owners \${ownerList${i}}, \${severity${i}})\`
  if (rows${i}.length > ${(i % 7) + 3}) {
    await ${helper}(\`Monitor ${i}: \${detail${i}}. Look at the queue before the next run.\`)
  }
  return { name: 'check${i}', ok: false, detail: detail${i} }
}
`
const bigRoute = (lines: number, helper = 'postSlackAlert', from = '@/lib/notify/slack') => {
  const head = `import { ${helper} } from '${from}'\nimport { getDb, type Db, type Row } from '@/lib/db'\nimport { logger } from '@/lib/logger'\n\ntype CheckResult = { name: string; ok: boolean; detail?: string }\n`
  const body: string[] = []
  let n = head.split('\n').length
  let i = 0
  while (n < lines - 12) {
    const c = bigCheck(i++, helper)
    body.push(c)
    n += c.split('\n').length - 1
  }
  const calls = Array.from({ length: i }, (_, k) => `check${k}(db, now)`).join(', ')
  return `${head}${body.join('')}\nexport async function GET() {\n  const db = await getDb()\n  const now = new Date()\n  const results = await Promise.all([${calls}])\n  return Response.json({ ok: results.every(r => r.ok) })\n}\n`
}
// One call judged on the wall, from just before it starts.
const onWall = async ($: Caller, w: W, input: Record<string, unknown>) => {
  w.wallStart()
  return refusalOf(await call($, input))
}
// The route's one line import of the quiet feed copy, judged; then, as the world writes only a
// Write, put in place as the Edit leaves it.
const LOGGER_IMPORT = "import { logger } from '@/lib/logger'\n"
const importBig = async ($: Caller, w: W, text: string) => {
  const held = await onWall($, w, { tool: 'Edit', file_path: BIG, old_string: LOGGER_IMPORT, new_string: `${LOGGER_IMPORT}${QUIET_IMPORT}` })
  w.files[BIG] = text.replace(LOGGER_IMPORT, `${LOGGER_IMPORT}${QUIET_IMPORT}`)
  return held
}
// An edit sending the quiet feed page through the route's send helper.
const sendQuiet = (helper: string) => ({ tool: 'Edit', file_path: BIG, old_string: '  if (!rows7.length) return', new_string: `  if (!rows7.length) await ${helper}(quietPage('orders', 45))\n  if (!rows7.length) return` })

test('an 11,000 line route posting through a Slack send helper is judged inside the search time: an import passes, and an edit bringing new wording to its send, or rewording one, is still held (#2719)', withKit, async ($, on) => {
  const text = bigRoute(BIG_LINES)
  expect(text.split('\n').length).toBeGreaterThanOrEqual(BIG_LINES - 20)
  const SLACK_POST = '/w/app/src/lib/notify/slack.ts'
  const w = world($, on, { files: { [SLACK_POST]: POST_TEXT.replace('postAlert', 'postSlackAlert'), [QUIET]: QUIET_TEXT, [BIG]: text } })
  // The one line import that was held 14 times: it sends nothing of the module yet.
  expect(await importBig($, w, text)).toBe('')
  expect(w.ran.length).toBe(1)
  // Sending it brings the module's wording to the helper's send, so it is held for that wording.
  const held = await onWall($, w, sendQuiet('postSlackAlert'))
  expect(held).not.toContain('not searched within')
  expect(held).toContain('The ${feed} feed has gone quiet: nothing has arrived for ${minutes} minutes')
  expect(held).toContain(QUIET)
  // Rewording a message the route sends itself is held for the new wording.
  const rewording = { tool: 'Edit', file_path: BIG, old_string: "Look at the queue before the next run.`)\n  }\n  return { name: 'check12'", new_string: "Somebody must clear the queue before the next run.`)\n  }\n  return { name: 'check12'" }
  const reworded = await onWall($, w, rewording)
  expect(reworded).not.toContain('not searched within')
  expect(reworded).toContain('Somebody must clear the queue before the next run')
  expect(w.ran.length).toBe(1)
})

test('an 11,000 line route posting through a send helper named for nothing Slack is judged inside the search time: its import passes and the send it adds is held (#2719)', withKit, async ($, on) => {
  // The route posts through the helper's own sends, traced with them as the route's send functions.
  const text = bigRoute(BIG_LINES, 'postAlert', '@/lib/notify/post')
  const w = world($, on, { files: { [POST]: POST_TEXT, [QUIET]: QUIET_TEXT, [BIG]: text } })
  expect(await importBig($, w, text)).toBe('')
  const held = await onWall($, w, sendQuiet('postAlert'))
  expect(held).not.toContain('not searched within')
  expect(held).toContain('The ${feed} feed has gone quiet: nothing has arrived for ${minutes} minutes')
  expect(held).toContain(QUIET)
  expect(w.ran.length).toBe(1)
})

test('a search for what an edit brings to a send that runs out of time says so, never that git could not name the repository (#2719)', withKit, async ($, on) => {
  const w = world($, on, { files: { [COPY]: COPY_TEXT, [POST]: POST_TEXT, [MONITOR]: QUIET_IMPORT + MONITOR_TEXT, [QUIET]: QUIET_TEXT } })
  const send = { tool: 'Edit', file_path: MONITOR, old_string: "  await postAlert(lateBooking('1'))\n", new_string: "  await postAlert(quietPage('orders', 45))\n" }
  // Only the search for the route's own send helper, by its imports, runs past the deadline: the
  // place the 12 ms of git came from.
  w.ctl.gitSlow = SCAN_MS + 1
  w.ctl.gitSlowWhen = ':(glob,icase)'
  const late = refusalOf(await call($, send))
  expect(late).toContain(`what this edit to ${MONITOR} brings to a Slack send was not searched within ${SCAN_MS / 1000} seconds`)
  expect(late).not.toContain('could not name the repository')
  expect(w.ran).toEqual([])
})
