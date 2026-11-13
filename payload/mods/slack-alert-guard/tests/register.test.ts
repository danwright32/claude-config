import { expect, mock, type Engine } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { EngineInterface, On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { APPROVE, CHANGE, HEADER, SCAN_MS, wordingKey } from '../hooks/rules.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { pythonText } from './mod-kit/hooks/code.ts'
import { type TypedAnswer, typedAnswerText, typedToast } from './mod-kit/hooks/typed.ts'
import { reasonOf, standInCore } from './mod-kit/tests/core.ts'
import { readsAsSend } from './send-wording.ts'
import { pipeline } from './mod-kit/hooks/commands.ts'
import { ghArgs, mergeHelperArgs } from './mod-kit/hooks/gh.ts'
import { githubRepo, linkRepo, repoName } from './mod-kit/hooks/repo.ts'

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
      const modkit: Pick<Kit, 'writes' | 'pythonText' | 'blocked' | 'typedAnswer' | 'screen' | 'pipeline' | 'gh' | 'mergeHelper' | 'branch' | 'repo' | 'linkRepo'> = {
        screen: async () => null,
        // The gh and command readers are byte for byte copies of mod-kit's own (#2628).
        pipeline: async (input: { command: string; cwd?: string }) => ask('pipeline', input),
        gh: async (input: { words: string[] }) => ask('gh', input),
        mergeHelper: async c => ask('mergeHelper', c),
        branch: async (input: { path: string }) => ask('branch', input),
        // The repository readers are mod-kit's own, copied (#2833).
        repo: async (input: { root?: string | null; remote: string | null }) => ask('repo', input),
        linkRepo: async (input: { link: string }) => ask('linkRepo', input),
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
// Scope modes, standing in (#2628): whether sleep mode is on, and the notes it would take for the
// night's report. Absent from withKit, as a Mac without scope modes is awake.
const night: { asleep: boolean; notes: Record<string, unknown>[]; fails: boolean } = { asleep: false, notes: [], fails: false }
const sleepKit: { name: string; register: Register } = {
  name: 'scope-modes',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      // Asked through the world (`__scope`), as a plugin's engine cannot reach the test's own objects.
      const ask = async (what: string, input: unknown = null) => {
        const r = await built.process.run(['__scope', what, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout)
      }
      const scopeModes = {
        isAsleep: async () => ask('isAsleep'),
        sleepNote: async (note: Record<string, unknown>) => ask('sleepNote', note),
      }
      return { ...built, scopeModes }
    })
  },
}
const withNight = { plugins: [secDefault, modKit, sleepKit] }
const nightFresh = (asleep: boolean) => {
  night.asleep = asleep
  night.notes = []
  night.fails = false
}

const HOME = `${'/Users'}/dan`
const T0 = Date.UTC(2026, 10, 4, 15, 0, 0)
const STORE = `${HOME}/.claude/plugins/store/slack-alert-guard_inline-ab12cd34ef56.json`
// A file that posts to Slack, and one that does not.
const ALERT = '/w/app/lib/alert.ts'
const ALERT_TEXT = 'export const alert = (id: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: "POST", body: JSON.stringify({ text: `Deploy ${id} failed` }) })\n'
const PLAIN = '/w/app/lib/date.ts'
// The repository the files above are in, as git names it.
const REPO = '/w/app'
// #2833: a second repository, and each one's origin as git prints it.
const SITE = '/w/site'
const ORIGINS: Record<string, string> = { [REPO]: 'git@github.com:danwright32/app.git', [SITE]: 'https://github.com/danwright32/site.git' }

type Asked = { questions: { question: string; header: string; options: { label: string; description?: string }[]; multiSelect: boolean }[]; metadata?: Record<string, unknown> }
const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never

const world = (engine: Engine, on: On, init: { files?: Record<string, string> } = {}) => {
  const files: Record<string, string> = { [ALERT]: ALERT_TEXT, [PLAIN]: 'export const x = 1\n', ...(init.files ?? {}) }
  const store: Record<string, unknown> = {}
  // gitFails: git is killed and exits nonzero with this on stderr (as at its timeoutMs); gitThrows:
  // git cannot be run at all, so the call rejects (a hook that throws is skipped, and nothing answers);
  // cwd: the folder the session is in.
  // gitTakes, ghTakes: the test clock time each git or gh command takes before it answers (#2792), so
  // a git killed at its timeout, as a heavily loaded Mac's is, is gitFails with gitTakes of SCAN_MS
  // or more, and a gh the same with ghFails.
  const ctl = { storeGetFails: false, storeSetFails: false, unreadable: '', gitFails: '', gitThrows: false, gitTakes: 0, ghTakes: 0, cwd: '/w/app' }
  // #2628: the session's id; each pull request's diff as gh pr diff prints it, by the selector gh is
  // given ('' for the current branch's), and whether gh fails; each file as origin's default branch holds it, by
  // its path from the top (absent: not there upstream), and whether git show fails another way.
  // #2833: originFails, git remote get-url exits nonzero; urls, the pull request each selector names
  // as gh pr view gives it (absent: danwright32/app's), and viewFails, gh pr view alone failing.
  const night2 = { session: 's1', diffs: {} as Record<string, string>, urls: {} as Record<string, string>, viewFails: false, originFails: false, ghFails: false, upstream: undefined as Record<string, string> | undefined, showFails: false, defaultBranch: 'main' as string | null, shownFrom: [] as string[] }
  const ghs: string[][] = []
  let reads = 0
  // Every git command the guard ran, with the timeout it gave it, so a pass can be told from a
  // guard that never searched.
  const gits: { argv: string[]; timeoutMs?: number }[] = []
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const asked: Asked[] = []
  const dialog: { answer?: string; afk?: boolean } = {}
  const cards: Record<string, unknown>[] = []
  const traced: number[] = []
  const toasts: string[] = []
  // Every read of the clock first charges the real time spent since the last charge (#2805), so
  // computing between calls to the world, such as tracing senders through a large module, counts
  // against a deadline checked inside that work, as it does in a session. The mock clock registers
  // the one clock.now handler, so it is registered through this wrapper, which puts the charge
  // ahead of it. wall is declared below; it is only called once a read happens.
  let readClock: () => Promise<number> = async () => NaN
  const clockOn = ((name: string, handler: (...a: never[]) => unknown) => {
    if (name !== 'clock.now') return on(name as never, handler as never)
    const charged = async (...a: never[]) => {
      await wall()
      return handler(...a)
    }
    readClock = async () => ((await charged()) as { value: number }).value
    return on(name as never, charged as never)
  }) as unknown as On
  const clock = mock.clock(clockOn, { now: T0 })
  // The wall (#2719): once started, every call the guard makes to the world first moves the test
  // clock on by the real time spent since the last one, so the guard's own reading and tracing of a
  // file is charged against its deadline as it is in a session, where git and reads cost little and
  // the work between them is the time. Started just before the call it measures.
  let wallAt: number | undefined
  const wallStart = (spentMs = 0) => {
    wallAt = performance.now() - spentMs
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
  on('session.id', () => ({ value: night2.session }) as never)
  on('process.run', async ($, e) => {
    await wall()
    const [cmd, method, raw] = e.argv.map(String)
    if (cmd === '__scope') {
      if (night.fails) return { value: { exitCode: 1, stdout: '', stderr: 'the sleep record could not be read', isStdoutTruncated: false, isStderrTruncated: false } } as never
      if (method === 'isAsleep') return ok(JSON.stringify(night.asleep))
      if (!night.asleep) return ok(JSON.stringify({ isNoted: false }))
      night.notes.push(JSON.parse(String(raw)))
      return ok(JSON.stringify({ isNoted: true }))
    }
    if (cmd === 'gh') {
      const argv = e.argv.map(String)
      ghs.push(argv)
      if (ctl.ghTakes) await clock.advance(ctl.ghTakes)
      if (night2.ghFails) return { value: { exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com\n', isStdoutTruncated: false, isStderrTruncated: false } } as never
      const sel = argv[3] !== undefined && !argv[3].startsWith('-') ? argv[3] : ''
      if (argv[1] === 'pr' && argv[2] === 'view' && argv.includes('url')) {
        if (night2.viewFails) return { value: { exitCode: 1, stdout: '', stderr: 'HTTP 502: Bad Gateway\n', isStdoutTruncated: false, isStderrTruncated: false } } as never
        return ok(`${night2.urls[sel] ?? `https://github.com/danwright32/app/pull/${sel || '12'}`}\n`)
      }
      if (argv[1] !== 'pr' || argv[2] !== 'diff') throw new Error(`unexpected gh command: ${argv.join(' ')}`)
      const d = night2.diffs[sel]
      if (d === undefined) return { value: { exitCode: 1, stdout: '', stderr: `no pull requests found for ${sel || 'the current branch'}\n`, isStdoutTruncated: false, isStderrTruncated: false } } as never
      return ok(d)
    }
    // git, standing in over the files above: one repository at /w/app, searched as git grep does.
    if (cmd === 'git') {
      const argv = e.argv.map(String)
      gits.push({ argv, timeoutMs: e.init?.timeoutMs })
      if (ctl.gitThrows) throw new Error('git could not be started')
      if (ctl.gitTakes) await clock.advance(ctl.gitTakes)
      if (ctl.gitFails) return { value: { exitCode: 143, stdout: '', stderr: `${ctl.gitFails}\n`, isStdoutTruncated: false, isStderrTruncated: false } } as never
      const dir = argv[2] ?? ''
      const top = Object.keys(ORIGINS).find(r => dir === r || dir.startsWith(`${r}/`))
      const notRepo = { value: { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository (or any of the parent directories): .git\n', isStdoutTruncated: false, isStderrTruncated: false } } as never
      if (argv[3] === 'rev-parse') {
        if (!top) return notRepo
        // As git prints it: the top folder, then the folder below it ending in a slash, empty at the top.
        return ok(`${top}\n${dir === top ? '' : `${dir.slice(top.length + 1)}/`}\n`)
      }
      // git remote get-url origin (#2833).
      if (argv[3] === 'remote' && argv[4] === 'get-url' && argv[5] === 'origin') {
        if (!top) return notRepo
        if (night2.originFails) return { value: { exitCode: 2, stdout: '', stderr: "error: No such remote 'origin'\n", isStdoutTruncated: false, isStderrTruncated: false } } as never
        return ok(`${ORIGINS[top]}\n`)
      }
      if (argv[3] === 'grep') {
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
        const listing = (stdout: string) => ok(stdout)
        if (!argv.includes('-l')) {
          // Each line holding a fixed string, after its path and a NUL, as git grep -z prints it.
          const lines = searched.flatMap(p => (files[p] ?? '').split('\n').filter(l => (fixed ? patterns.some(re => re.test(l)) : patterns.every(re => re.test(l)))).map(l => `${p.slice(dir.length + 1)}\u0000${l}\n`))
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
      // git show origin/<default branch>:<path from the top>, as git answers it (#2628).
      if (argv[3] === 'show') {
        const spec = argv[4] ?? ''
        night2.shownFrom.push(spec.slice(0, spec.indexOf(':')))
        const rel = spec.slice(spec.indexOf(':') + 1)
        if (night2.showFails) return { value: { exitCode: 128, stdout: '', stderr: "fatal: invalid object name 'origin/HEAD'.\n", isStdoutTruncated: false, isStderrTruncated: false } } as never
        const t = night2.upstream === undefined ? files[`${REPO}/${rel}`] : night2.upstream[rel]
        if (t === undefined) return { value: { exitCode: 128, stdout: '', stderr: `fatal: path '${rel}' exists on disk, but not in 'origin/HEAD'\n`, isStdoutTruncated: false, isStderrTruncated: false } } as never
        return ok(t)
      }
      throw new Error(`unexpected git command: ${argv.join(' ')}`)
    }
    if (cmd === '__modkit' && method === 'writes') {
      const input = JSON.parse(String(raw)) as { command: string; cwd: string; home: string }
      return ok(JSON.stringify(commandWrites(input.command, input.cwd, input.home)))
    }
    if (cmd === '__modkit' && method === 'pythonText') return ok(JSON.stringify(pythonText(JSON.parse(String(raw)).code)))
    if (cmd === '__modkit' && method === 'pipeline') {
      const input = JSON.parse(String(raw)) as { command: string; cwd?: string }
      return ok(JSON.stringify(pipeline(input.command).map(c => ({ ...c, folder: input.cwd ?? null }))))
    }
    // undefined (no gh, no helper) travels as null and is read back as none.
    if (cmd === '__modkit' && method === 'gh') return ok(JSON.stringify(ghArgs((JSON.parse(String(raw)) as { words: string[] }).words) ?? null))
    if (cmd === '__modkit' && method === 'mergeHelper') return ok(JSON.stringify(mergeHelperArgs(JSON.parse(String(raw))) ?? null))
    if (cmd === '__modkit' && method === 'repo') {
      const input = JSON.parse(String(raw)) as { root?: string | null; remote: string | null }
      return ok(JSON.stringify({ github: githubRepo(input.remote), name: repoName(input) }))
    }
    if (cmd === '__modkit' && method === 'linkRepo') return ok(JSON.stringify(linkRepo((JSON.parse(String(raw)) as { link: string }).link)))
    if (cmd === '__modkit' && method === 'branch') return ok(JSON.stringify({ root: REPO, main: REPO, branch: '2628-sleep', defaultBranch: night2.defaultBranch, isDefault: false, issues: [2628] }))
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
  // A file is one the world holds; a folder, as fs.exists reads one, any path a file is under.
  on('fs.stat', async ($, e) => {
    await wall()
    const path = (e as unknown as { path: string }).path
    if (files[path] !== undefined) return { value: { kind: 'file', size: files[path].length, mtimeMs: 0, isLink: false } } as never
    if (Object.keys(files).some(p => p.startsWith(`${path}/`))) return { value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: false } } as never
    throw new Error(`ENOENT: ${path}`)
  })
  on('fs.read', async ($, e) => {
    await wall()
    if (ctl.unreadable === e.path) throw new Error(`EACCES: ${e.path}`)
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    reads++
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
  on('store.keys', () => ({ value: Object.keys(store) }) as never)
  on('store.delete', ($, e) => {
    delete store[e.key]
    return { value: undefined } as never
  })
  on('tool.register', ($, e) => ({ value: { tool: `mcp__slack-alert-guard__${e.name}` } }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('prompt.submit', ($, e) => ({ text: e.text, context: e.context ?? [] }) as never)
  on('ui.log', ($, e) => {
    const text = String((e as { text?: string }).text ?? '')
    if (text.startsWith('CARD ')) cards.push(JSON.parse(text.slice(5)))
    // The searching each trace did (#2719), as the guard reports it.
    const t = /^slack-alert-guard: traced .*: searched (\d+)$/.exec(text)
    if (t) traced.push(Number(t[1]))
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
  return { files, store, ctl, ran, asked, dialog, cards, traced, toasts, gits, night: night2, ghs, clock, reads: () => reads, wallStart, readClock: () => readClock() }
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

// claude-config#2837, Dan 2026-11-12: "I'd much rather an alert get posted to slack that I didn't
// approve than deal with stopping every 2 seconds to approve wording that nobody will ever see." He
// chose: stop only for real senders. An edit is held only when the file it changes carries a Slack
// marker in its own code; what other files import, read, name or send of it is never a reason to stop.
const JOB = '/w/app/lib/deploy-job.ts'
const JOB_TEXT = "import { notify } from './notify'\nexport const run = (id: string) => notify(`Deploy ${id} started`)\n"
const NOTIFY_SENDER = '/w/app/lib/notify.ts'
const NOTIFY_SENDER_TEXT = 'export const notify = (text: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: "POST", body: JSON.stringify({ text }) })\n'
const DEPLOY_COPY = 'export const deployFailed = (id: string) => `Deploy ${id} failed`\n'
const DEPLOY_COPY_FILE = '/w/app/lib/templates/deploy.ts'
const SENDS_COPY = "import { deployFailed } from './templates/deploy'\nexport const page = (id: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: deployFailed(id) }) })\n"
const realSenders = { files: { [JOB]: JOB_TEXT, [NOTIFY_SENDER]: NOTIFY_SENDER_TEXT, [DEPLOY_COPY_FILE]: DEPLOY_COPY, '/w/app/lib/page.ts': SENDS_COPY, '/w/app/payload/hooks/gate.sh': '#!/bin/bash\nexit 0\n' } }
// The searches the guard used to make for other files' senders, by pattern or by import: none is made
// any more. Only the whole word search for a model prompt's other uses (#2475), which can only let a
// self sender's wording through, is left.
const searches = (w: W) => w.gits.filter(g => (g.argv[3] === 'grep' && !g.argv.includes('-F')) || g.argv[3] === 'ls-files').length

test('an edit adding wording to a file that imports a Slack sender, or that a sender imports, passes without searching the repository (#2837)', withKit, async ($, on) => {
  const w = world($, on, realSenders)
  expect(refusalOf(await call($, { tool: 'Edit', file_path: JOB, old_string: 'Deploy ${id} started', new_string: 'Deploy ${id} started on production' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: DEPLOY_COPY_FILE, old_string: 'Deploy ${id} failed', new_string: 'Deploy ${id} failed on production' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/app/lib/new-copy.ts', content: 'export const LATE = "The nightly backup is late again"\nexport const DOWN = "The booking site is down for everyone"\n' }))).toBe('')
  expect(w.ran.length).toBe(3)
  expect(searches(w)).toBe(0)
  expect(w.cards).toEqual([])
})

test('an edit adding wording to a file that itself posts to Slack is still held, and Dan approving it lets it through (#2837)', withKit, async ($, on) => {
  const w = world($, on, realSenders)
  const edit = { tool: 'Edit', file_path: NOTIFY_SENDER, old_string: 'JSON.stringify({ text })', new_string: 'JSON.stringify({ text: `Deploy alert: ${text}` })' }
  const why = refusalOf(await call($, edit))
  expect(why).toContain(NOTIFY_SENDER)
  expect(why).toContain('Deploy alert: ${text}')
  expect(why).not.toContain('sends to Slack,')
  expect(w.ran).toEqual([])
  await ask($, w, why, APPROVE, { rendered: 'Deploy alert: Deploy 4182 started' })
  expect(refusalOf(await call($, edit))).toBe('')
  expect(w.ran.length).toBe(1)
  expect(searches(w)).toBe(0)
})

test("a cp -R into a sender's folder passes: what lands there is not a reason to stop (#2837)", withKit, async ($, on) => {
  const w = world($, on, realSenders)
  expect(refusalOf(await call($, { tool: 'Bash', command: 'cp -R payload/hooks/ /w/app/lib' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Bash', command: 'cp -R payload/hooks/ /w/app/lib/templates' }))).toBe('')
  expect(w.ran.length).toBe(2)
  expect(searches(w)).toBe(0)
})

test('a shell write into a file that itself posts to Slack is held; one into a file a sender imports or reads passes (#2837)', withKit, async ($, on) => {
  const w = world($, on, realSenders)
  const into = (file: string) => ({ tool: 'Bash', command: `printf 'export const more = "Disk is full"\\n' >> ${file}` })
  const why = refusalOf(await call($, into(NOTIFY_SENDER)))
  expect(why).toContain(`shell command writes to ${NOTIFY_SENDER}, which posts to Slack`)
  expect(idIn(why)).toBeDefined()
  expect(refusalOf(await call($, into(DEPLOY_COPY_FILE)))).toBe('')
  expect(refusalOf(await call($, into(JOB)))).toBe('')
  // A heredoc making a new file that posts by itself is held as a write into one is.
  const made = refusalOf(await call($, { tool: 'Bash', command: "cat > /w/app/lib/pager.sh <<'EOF'\n#!/bin/bash\ncurl -s --data \"Disk is full\" \"$SLACK_WEBHOOK_URL\"\nEOF" }))
  expect(made).toContain('shell command writes to /w/app/lib/pager.sh, which posts to Slack')
  expect(w.ran.length).toBe(2)
  expect(searches(w)).toBe(0)
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

test('a copy builder used by a route that posts nothing passes', withKit, async ($, on) => {
  const w = world($, on, { files: { [COPY]: COPY_TEXT, [ROUTE]: "import { lateBooking } from '@/lib/notify/outage-copy'\nexport const GET = async () => console.log(lateBooking('1'))\n" } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: COPY, old_string: 'is late`', new_string: 'is late again`' }))).toBe('')
  expect(w.ran.length).toBe(1)
})

// claude-config#2770: a file posting through a send helper it imports, named for nothing Slack, was
// judged as a file that sends nothing, so rewording the message it hands the helper passed unheld.
// The helper is followed to whether it reaches a Slack send.
const NOTIFIER = '/w/app/src/jobs/stuck-orders.ts'
const notifier = (from: string, helper: string) =>
  `import { ${helper} } from '${from}'\nexport const run = async (count: number) => {\n  if (count > 5) await ${helper}(\`\${count} orders are stuck in the queue\`)\n}\n`
const REWORD_NOTIFIER = { tool: 'Edit', file_path: NOTIFIER, old_string: 'orders are stuck in the queue', new_string: 'orders have been stuck for an hour' }

test('rewording what a file hands a helper that reaches no Slack send passes, from a module that posts nowhere or from a Slack module whose other function posts elsewhere (#2770)', withKit, async ($, on) => {
  const METRICS = '/w/app/src/lib/metrics/emit.ts'
  const METRICS_TEXT = 'export const emitEvent = (text: string) => fetch(process.env.METRICS_URL, { method: "POST", body: JSON.stringify({ text }) })\n'
  const w = world($, on, { files: { [METRICS]: METRICS_TEXT, [NOTIFIER]: notifier('@/lib/metrics/emit', 'emitEvent') } })
  expect(refusalOf(await call($, REWORD_NOTIFIER))).toBe('')
  expect(w.ran.length).toBe(1)
  // The same module as the Slack send helper, through its function that posts somewhere else.
  const BOTH = `${POST_TEXT}export const postMetric = (text: string) => fetch(process.env.METRICS_URL, { method: "POST", body: JSON.stringify({ text }) })\n`
  w.files[POST] = BOTH
  w.files[NOTIFIER] = notifier('@/lib/notify/post', 'postMetric')
  expect(refusalOf(await call($, REWORD_NOTIFIER))).toBe('')
  expect(w.ran.length).toBe(2)
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

const MEMORY = '/w/app/src/lib/memory.ts'
const LABEL = 'export const nowEt = () => new Date()\nexport const label = "Eastern time"\n'
const relabel = (file: string) => ({ tool: 'Edit', file_path: file, old_string: '"Eastern time"', new_string: '"Eastern time, as Dan reads it"' })

test("a module's importers that also import common helpers (db, utils) do not make its write a hold (Dan item 3)", withKit, async ($, on) => {
  const many: Record<string, string> = {}
  for (let i = 0; i < 60; i++) many[`/w/app/src/app/api/r${i}/route.ts`] = `import { remember } from '@/lib/memory'\nimport { db } from '@/lib/db'\nimport { cn } from '@/lib/utils'\nexport const GET = () => remember(db, cn)\n`
  // Files that mention utils and slack, none of them the utils module.
  for (let i = 0; i < 250; i++) many[`/w/app/src/components/c${i}.tsx`] = `// utils for the slack digest card\nexport const c${i} = ${i}\n`
  const w = world($, on, { files: { ...many, [MEMORY]: LABEL, '/w/app/src/lib/db.ts': 'export const db = {}\n', '/w/app/src/lib/utils.ts': 'export const cn = () => ""\n' } })
  expect(refusalOf(await call($, relabel(MEMORY)))).toBe('')
  expect(w.ran.length).toBe(1)
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

// #2792: on 2026-11-11, at load average 60 to 200, the guard answered "could not check this call
// (... not searched within 7 seconds)", which read as a refusal and named no time to wait, and agents
// sent the same call up to six times. A check that runs out of time now says it is a timeout, not a
// refusal, and when to send the call again; git failing for any other reason is still could not check.
test('a check that runs out of time says it is a timeout, not a refusal, and when to send the call again; a git that fails in time is still could not check (#2792)', withKit, async ($, on) => {
  const w = world($, on)
  // git killed at its timeout: it took the whole of the time it was given, then failed.
  w.ctl.gitFails = 'killed'
  w.ctl.gitTakes = SCAN_MS
  const late = refusalOf(await call($, REWORD))
  expect(late).toContain('timeout, not a refusal')
  expect(late).toContain('again in about a minute')
  expect(late).toContain('three times')
  expect(late).not.toContain('could not check')
  expect(w.ran).toEqual([])
  expect(JSON.stringify(w.cards.at(-1))).toContain('ran out of time')
  // git failing at once, with time to spare, is no timeout.
  w.ctl.gitTakes = 0
  const failed = refusalOf(await call($, REWORD))
  expect(failed).toContain('could not check')
  expect(failed).not.toContain('timeout')
  // With git answering, the same edit is held for Dan's approval as ever.
  w.ctl.gitFails = ''
  expect(refusalOf(await call($, REWORD))).toContain('realistic example')
  expect(w.ran).toEqual([])
})

// #2792 part 1: on 2026-11-11 about a dozen approvals in one afternoon were for edits that changed
// only a comment, or only a string written to a log, in a file a Slack sender imports. Since #2850
// such a file is never held, and in the sender itself only text its own sends carry is held.
const MESSAGES = '/w/app/lib/messages.ts'
const MESSAGES_TEXT = 'export const failed = (id: string) => `Deploy ${id} failed`\n'
const IMPORTING_ALERT = "import { failed } from './messages'\nexport const alert = (id: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: failed(id) }) })\n"
test('a comment only edit, or a string only a log reads, in a file a Slack sender imports or in the sender itself, passes; new wording in the sender is still held (#2792)', withKit, async ($, on) => {
  const w = world($, on, { files: { [MESSAGES]: MESSAGES_TEXT, [ALERT]: IMPORTING_ALERT } })
  const passes = [
    { tool: 'Edit', file_path: MESSAGES, old_string: 'export const failed', new_string: '// The words Slack shows when a deploy fails.\nexport const failed' },
    { tool: 'Edit', file_path: MESSAGES, old_string: 'export const failed', new_string: "console.log('building the deploy failure text')\nexport const failed" },
    { tool: 'Edit', file_path: ALERT, old_string: 'export const alert', new_string: '// Posts a deploy failure to the alerts channel.\nexport const alert' },
    { tool: 'Edit', file_path: ALERT, old_string: 'export const alert', new_string: "console.log('the deploy alert module loaded')\nexport const alert" },
  ]
  for (const edit of passes) expect([edit.new_string, refusalOf(await call($, edit))]).toEqual([edit.new_string, ''])
  expect(w.ran.length).toBe(4)
  expect(w.cards).toEqual([])
  // New wording the sender's own send carries is still held, so the passes above were judged.
  const held = refusalOf(await call($, { tool: 'Edit', file_path: ALERT, old_string: 'text: failed(id)', new_string: 'text: `Deploy ${id} failed on production`' }))
  expect(held).toContain('Deploy ${id} failed on production')
  expect(w.ran.length).toBe(4)
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

// A template and the file that sends it to Slack (#2248). Since #2837 only the sender is ever held.
const TEMPLATE = '/w/app/lib/templates/deploy.ts'
const TEMPLATE_TEXT = 'export const deployFailed = (id: string) => `Deploy ${id} failed`\n'
const SENDER = '/w/app/lib/notify.ts'
const SENDER_TEXT =
  "import { deployFailed } from './templates/deploy'\nexport const notify = (id: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text: deployFailed(id) }) })\n"
const sent = { files: { [TEMPLATE]: TEMPLATE_TEXT, [SENDER]: SENDER_TEXT } }

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

const NOTIFY = '/w/app/lib/notify.ts'

// A React component (#2519), used below as a file that posts nothing.
const CARD = '/w/app/components/DeployCard.tsx'

// A widely imported module (#2462), used below as a file that posts nothing.
const HTTP = '/w/app/src/lib/http.ts'

test('the search leaves the hook time to refuse: its budget sits well inside the 10 s Claude Code gives a hook (#2510)', () => {
  // HookBudget.ms in the pinned Claude Code types: a hook running past it is killed.
  const HOOK_MS = 10_000
  expect(SCAN_MS).toBeGreaterThan(3000)
  expect(SCAN_MS).toBeLessThanOrEqual(HOOK_MS - 2500)
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

// A module of feed alert copy a monitor route imports and posts to Slack (#2637). Since #2837 only
// wording the route itself carries stops; the module's own wording passes.
const QUIET = '/w/app/src/lib/monitor/quiet-feed-copy.ts'
const QUIET_TEXT = [
  'export const quietPage = (feed: string, minutes: number) => `The ${feed} feed has gone quiet: nothing has arrived for ${minutes} minutes`',
  'export const quietAgain = (feed: string) => `The ${feed} feed is still quiet, so somebody needs to look at it now`',
  'export const quietClear = (feed: string) => `The ${feed} feed is sending again`',
  "export const allClear = 'Every feed is sending again'",
  "export const CHECKED = 'Checked every feed for a quiet one'",
  '',
].join('\n')
const QUIET_IMPORT = "import { quietPage, quietClear, CHECKED } from '@/lib/monitor/quiet-feed-copy'\n"

test('a shell command creating a new file is judged as a Write of it is: one posting to Slack by itself is held; a template a sender reads, an ordinary module, a test, a scratch file pass (#2773, #2837)', withKit, async ($, on) => {
  const PY = '/w/app/jobs/late.py'
  const w = world($, on, { files: { [PY]: 'from slack_sdk import WebClient\nbody = open("templates/late.txt").read()\n' } })
  // A new script that posts to Slack by itself.
  const NOTIFY = '/w/app/scripts/notify-late.ts'
  const posts = refusalOf(await call($, { tool: 'Bash', command: `cat > ${NOTIFY} <<'EOF'\n${ALERT_TEXT}EOF` }))
  expect(posts).toContain(`shell command writes to ${NOTIFY}, which posts to Slack`)
  expect(w.ran).toEqual([])
  // A new text template a sender already reads passes (#2837): only a file posting by itself stops.
  const TXT = '/w/app/templates/late.txt'
  expect(refusalOf(await call($, { tool: 'Bash', command: `printf 'Booking is late\\n' > ${TXT}` }))).toBe('')
  expect(w.ran.length).toBe(1)
  // An ordinary new module, a new test, and a copy module in no repository pass.
  expect(refusalOf(await call($, { tool: 'Bash', command: `cat > /w/app/src/lib/ops/late.ts <<'EOF'\nexport const late = (id: string) => \`Booking \${id} is running late\`\nEOF` }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Bash', command: `cat > /w/app/src/lib/monitor/quiet.test.ts <<'EOF'\n${QUIET_TEXT}EOF` }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Bash', command: `cat > /private/tmp/scratch/quiet-copy.ts <<'EOF'\n${QUIET_TEXT}EOF` }))).toBe('')
  expect(w.ran.length).toBe(4)
})

test('a copy the guard does not read, a video or a key, never has its source read, so an unreadable one passes rather than being held as could not check (#2773)', withKit, async ($, on) => {
  const KEY = '/w/app/certs/secret.pem'
  const w = world($, on, { files: { [KEY]: '-----BEGIN KEY-----\n', '/w/app/media/big.mov': 'x' } })
  w.ctl.unreadable = KEY
  expect(refusalOf(await call($, { tool: 'Bash', command: `cp ${KEY} /w/app/certs/dest.pem` }))).toBe('')
  w.ctl.unreadable = '/w/app/media/big.mov'
  expect(refusalOf(await call($, { tool: 'Bash', command: 'cp /w/app/media/big.mov /w/app/out/clip.mov' }))).toBe('')
  expect(w.ran.length).toBe(2)
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
})

// #2628: in sleep mode the session chooses held wording and keeps working; Dan is asked in the
// morning, and nothing carrying the wording merges until he approves it. Dan, 2026-11-09: "You
// should just choose the alert in sleep mode and put it to me in the morning to see if I want
// something else."
const CHOOSE = 'mcp__slack-alert-guard__choose'
const REWORDED = 'Deploy ${id} failed on production'
// The pull request carrying the reworded alert, as gh pr diff prints it.
const DIFF = [
  'diff --git a/lib/alert.ts b/lib/alert.ts',
  '--- a/lib/alert.ts',
  '+++ b/lib/alert.ts',
  '@@ -1 +1 @@',
  `-${ALERT_TEXT.trimEnd()}`,
  `+${ALERT_TEXT.trimEnd().replace('Deploy ${id} failed', REWORDED)}`,
  '',
].join('\n')
// The same pull request once the wording is changed again in the morning.
const DIFF_CHANGED = DIFF.replace(REWORDED, 'Deploy ${id} did not finish')
const said = (r: Result) => `${String((r as { result?: unknown }).result ?? '')}\n${r.text ?? ''}\n${contextOf(r)}`
const choose = ($: Caller, id: string, rendered: unknown = SHOWN, extra: Record<string, unknown> = {}) => call($, { tool: CHOOSE, call: id, rendered, ...extra })
const chosenIn = (w: W) => Object.keys(w.store).filter(k => k.startsWith('chosen:'))
const promptLines = async ($: unknown) =>
  (((await ($ as { prompt: { submit: (e: never) => Promise<{ context?: string[] }> } }).prompt.submit({ text: 'morning', origin: { kind: 'composer' }, wait: false } as never)).context ?? []) as string[]).join('\n')
const morning = async ($: Caller, w: W, id: string, answer: string | undefined, afk = false) => {
  w.dialog.answer = answer
  w.dialog.afk = afk
  return call($, {
    tool: 'AskUserQuestion',
    questions: [{ question: 'Keep this?', header: 'x', options: [{ label: 'Yes', description: 'y' }, { label: 'No', description: 'n' }], multiSelect: false }],
    metadata: { source: `slack-alert-guard:chosen:${id}` },
  })
}
const MERGE = { tool: 'Bash', command: 'gh pr merge 12 --squash' }
// Asleep, the held reword chosen and the edit sent again: the call's id.
const chooseReword = async ($: Caller, w: W, extra: Record<string, unknown> = {}) => {
  const why = refusalOf(await call($, { ...REWORD, ...extra }))
  const id = /"call": "(t\d+)"/.exec(why)?.[1]
  if (!id) throw new Error(`no choose instruction in: ${why}`)
  expect(refusalOf(await choose($, id, SHOWN, extra))).toBe('')
  expect(refusalOf(await call($, { ...REWORD, ...extra }))).toBe('')
  w.night.diffs['12'] = DIFF
  return id
}

test('asleep, held wording is chosen by the session and recorded as its choice, never as approved, and the edit goes ahead (#2628)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  const why = refusalOf(await call($, REWORD))
  expect(why).toContain(CHOOSE)
  expect(why).toContain('asleep')
  expect(why).not.toContain('"source"')
  expect(w.ran).toEqual([])
  const id = /"call": "(t\d+)"/.exec(why)?.[1] as string
  // The message chosen must be the message as Slack posts it: one leaving the new words out, or
  // still carrying a placeholder, records nothing.
  expect(refusalOf(await choose($, id, 'Deploy 4182 failed'))).toContain('leaves out')
  expect(refusalOf(await choose($, id, 'Deploy ${id} failed on production'))).toContain('${id}')
  expect(chosenIn(w)).toEqual([])
  const c = await choose($, id)
  expect(refusalOf(c)).toBe('')
  expect(said(c)).toContain('not approved')
  const k = wordingKey(REWORDED)
  expect(w.store[k]).toBeUndefined()
  expect(w.store[`chosen:${k}`]).toMatchObject({ id, file: ALERT, rendered: SHOWN, session: 's1', added: [REWORDED] })
  // The night's report shows it (a kind of its own, so no second picker that records nothing).
  expect(night.notes.map(n => n.kind)).toEqual(['wording'])
  expect(String(night.notes[0]?.text)).toContain(SHOWN)
  expect(refusalOf(await call($, REWORD))).toBe('')
  expect(w.ran.length).toBe(1)
  // Chosen once: the id waits on nothing now.
  expect(refusalOf(await choose($, id))).toContain('No Slack alert edit')
})

test("asleep, a subagent chooses its own held wording, and nobody else's (#2628)", withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  const why = refusalOf(await call($, { ...REWORD, agentId: 'a1' }))
  expect(why).toContain(CHOOSE)
  const id = /"call": "(t\d+)"/.exec(why)?.[1] as string
  expect(refusalOf(await choose($, id))).toContain('No Slack alert edit')
  expect(refusalOf(await choose($, id, SHOWN, { agentId: 'a1' }))).toBe('')
  expect(refusalOf(await call($, { ...REWORD, agentId: 'a1' }))).toBe('')
  expect(chosenIn(w).length).toBe(1)
})

test('in the morning the choice is put to Dan with the message filled in, and only his Approve wording releases it (#2628)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  const id = await chooseReword($, w)
  // Nothing carrying the chosen wording merges, asleep or not, and nothing is asked while asleep.
  const held = refusalOf(await call($, MERGE))
  expect(held).toContain('chosen overnight')
  expect(held).toContain(SHOWN)
  expect(w.ghs[0]?.slice(0, 4)).toEqual(['gh', 'pr', 'diff', '12'])
  expect(await promptLines($)).not.toContain('chosen:')
  night.asleep = false
  // Awake, a choice lets nothing through: the same wording is asked about as before.
  expect(refusalOf(await call($, REWORD))).toContain('"source": "slack-alert-guard:')
  const lines = await promptLines($)
  expect(lines).toContain(`slack-alert-guard:chosen:${id}`)
  expect(lines).toContain(ALERT)
  const r = await morning($, w, id, APPROVE)
  const q = w.asked.at(-1)?.questions[0]
  expect(q?.question).toContain(SHOWN)
  expect(q?.question).toContain('Overnight')
  expect(q?.header).toBe(HEADER)
  expect(q?.options.map(o => o.label)).toEqual([APPROVE, CHANGE])
  expect(readsAsSend((q?.question ?? '').split('\n\n')[0] ?? '')).toBe(false)
  for (const o of q?.options ?? []) expect(readsAsSend(`${o.label} ${o.description ?? ''}`)).toBe(false)
  expect(said(r)).toContain('approved')
  expect(w.store[wordingKey(REWORDED)]).toMatchObject({ file: ALERT, rendered: SHOWN })
  expect(chosenIn(w)).toEqual([])
  expect(refusalOf(await call($, MERGE))).toBe('')
  expect(await promptLines($)).not.toContain(`chosen:${id}`)
  expect(refusalOf(await morning($, w, id, APPROVE))).toContain('answered already')
})

test("Dan's Change wording, a dialog closed by itself, or no answer records nothing and leaves the choice held (#2628)", withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  const id = await chooseReword($, w)
  night.asleep = false
  for (const [answer, afk, words] of [[CHANGE, false, 'what it should say'], [APPROVE, true, 'closed by itself'], [undefined, false, 'no answer']] as const) {
    const r = await morning($, w, id, answer, afk)
    expect(said(r)).toContain(words)
    expect(w.store[wordingKey(REWORDED)]).toBeUndefined()
    expect(chosenIn(w).length).toBe(1)
    expect(refusalOf(await call($, MERGE))).toContain('chosen overnight')
    expect(await promptLines($)).toContain(`chosen:${id}`)
  }
  // Changed in the morning, the pull request no longer carries the chosen wording, so it may merge.
  w.night.diffs['12'] = DIFF_CHANGED
  expect(refusalOf(await call($, MERGE))).toBe('')
})

test('outside sleep mode nothing changes: no choosing, no records, and no merge is read (#2628)', withNight, async ($, on) => {
  nightFresh(false)
  const w = world($, on)
  const why = refusalOf(await call($, REWORD))
  expect(why).toContain('"source": "slack-alert-guard:')
  expect(why).not.toContain(CHOOSE)
  const id = idIn(why) as string
  expect(refusalOf(await choose($, id))).toContain('awake')
  // A sleep record that cannot be read is awake too.
  night.fails = true
  expect(refusalOf(await call($, REWORD))).not.toContain(CHOOSE)
  expect(refusalOf(await choose($, id))).toContain('awake')
  expect(chosenIn(w)).toEqual([])
  expect(night.notes).toEqual([])
  w.night.diffs['12'] = DIFF
  expect(refusalOf(await call($, MERGE))).toBe('')
  expect(w.ghs).toEqual([])
  expect(await promptLines($)).toBe('')
})

test('a merge the guard cannot read, or whose diff gh cannot give, is held while any choice waits; every way to merge is read (#2628)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  await chooseReword($, w)
  expect(refusalOf(await call($, { tool: 'Bash', command: '~/.claude/hooks/lib/merge-when-ready.sh 12 --repo danwright32/app' }))).toContain('chosen overnight')
  expect(refusalOf(await call($, { tool: 'Bash', command: 'gh api -X PUT repos/danwright32/app/pulls/12/merge' }))).toContain('chosen overnight')
  w.night.ghFails = true
  expect(refusalOf(await call($, MERGE))).toContain('could not check')
  w.night.ghFails = false
  expect(refusalOf(await call($, { tool: 'Bash', command: 'gh pr merge 12 -R "$REPO"' }))).toContain('could not check')
  // A command that merges nothing is never read for a diff.
  const before = w.ghs.length
  expect(refusalOf(await call($, { tool: 'Bash', command: 'gh pr view 12' }))).toBe('')
  expect(w.ghs.length).toBe(before)
})

test('a merge whose diff gh did not give within its time is told as a timeout, not a refusal; gh failing at once is still could not check (#2792)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  await chooseReword($, w)
  w.night.ghFails = true
  w.ctl.ghTakes = SCAN_MS
  const late = refusalOf(await call($, MERGE))
  expect(late).toContain('timeout, not a refusal')
  expect(late).toContain('again in about a minute')
  expect(late).not.toContain('could not check')
  w.ctl.ghTakes = 0
  expect(refusalOf(await call($, MERGE))).toContain('could not check')
})

// #2833: a choice holds merges in the repository it was made in, never in another. After sleep mode
// on 2026-11-12 a merge in one repository was refused over four choices made in another
// repository's worktree, none of whose files or wording its pull request carried.
const SITE_MERGE = { tool: 'Bash', command: 'gh pr merge 7 --squash -R danwright32/site' }
const placesIn = (w: W) => chosenIn(w).map(k => ((w.store[k] as { places?: { repo: string | null }[] }).places ?? []).map(p => p.repo))

test('a choice made overnight in one repository holds a merge there, never one in another (#2833)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  await chooseReword($, w)
  expect(placesIn(w)).toEqual(chosenIn(w).map(() => ['danwright32/app']))
  // Repository B's pull request even carries the same words, and is still not the one carrying the choice.
  w.night.diffs['7'] = DIFF
  expect(refusalOf(await call($, SITE_MERGE))).toBe('')
  // -R spelled with gh's host or as a whole address names the same repository.
  for (const r of ['github.com/danwright32/site', 'https://github.com/DanWright32/site.git'])
    expect(refusalOf(await call($, { tool: 'Bash', command: `gh pr merge 7 --squash -R ${r}` }))).toBe('')
  for (const r of ['github.com/danwright32/app', 'https://github.com/DanWright32/app.git'])
    expect(refusalOf(await call($, { tool: 'Bash', command: `gh pr merge 7 --squash -R ${r}` }))).toContain('chosen overnight')
  // Merged from its folder rather than with -R, gh says which repository the pull request is in.
  w.night.urls['7'] = 'https://github.com/danwright32/site/pull/7'
  w.ctl.cwd = SITE
  expect(refusalOf(await call($, { tool: 'Bash', command: 'gh pr merge 7 --squash' }))).toBe('')
  expect(w.ghs.some(g => g.slice(0, 4).join(' ') === 'gh pr view 7')).toBe(true)
  // In repository A the pull request carrying it is refused, by folder or by -R.
  w.ctl.cwd = REPO
  expect(refusalOf(await call($, MERGE))).toContain('chosen overnight')
  expect(refusalOf(await call($, { tool: 'Bash', command: 'gh pr merge 12 --squash -R danwright32/app' }))).toContain('chosen overnight')
  // One in A that no longer carries it passes, as before.
  w.night.diffs['12'] = DIFF_CHANGED
  expect(refusalOf(await call($, MERGE))).toBe('')
})

test('wording a choice lets through asleep in another repository holds merges there too (#2833)', withNight, async ($, on) => {
  nightFresh(true)
  const SITE_ALERT = `${SITE}/lib/alert.ts`
  const w = world($, on, { files: { [SITE_ALERT]: ALERT_TEXT } })
  await chooseReword($, w)
  // The same wording put in repository B while Dan is asleep goes through on the choice, which now
  // names B as well, so B's pull request carrying it is held.
  expect(refusalOf(await call($, { ...REWORD, file_path: SITE_ALERT }))).toBe('')
  expect(placesIn(w)).toEqual(chosenIn(w).map(() => ['danwright32/app', 'danwright32/site']))
  w.night.diffs['7'] = DIFF
  expect(refusalOf(await call($, SITE_MERGE))).toContain('chosen overnight')
})

test('a choice whose repository cannot be read, or a pull request whose repository cannot be, still holds the merge (#2833)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  // The choice's origin cannot be read when it is made, nor at the merge: it holds any pull request
  // carrying its wording, as before #2833, and says which repository could not be read.
  w.night.originFails = true
  await chooseReword($, w)
  expect(placesIn(w)).toEqual(chosenIn(w).map(() => [null]))
  w.night.diffs['7'] = DIFF
  const why = refusalOf(await call($, SITE_MERGE))
  expect(why).toContain('chosen overnight')
  expect(why).toContain(` As the repository ${ALERT} is in could not be read, the wording chosen there holds a pull request carrying it in any repository.`)
  // Readable at the merge, it is read then.
  w.night.originFails = false
  expect(refusalOf(await call($, SITE_MERGE))).toBe('')
  // A choice recorded before #2833 names no repository, so it is read from its file at the merge.
  for (const k of chosenIn(w)) {
    const { places: _p, ...before2833 } = w.store[k] as { places?: unknown }
    w.store[k] = before2833
  }
  expect(refusalOf(await call($, SITE_MERGE))).toBe('')
  w.night.originFails = true
  expect(refusalOf(await call($, SITE_MERGE))).toContain('chosen overnight')
  w.night.originFails = false
  // gh cannot say which repository the pull request is in: held as could not check.
  w.night.viewFails = true
  const unread = refusalOf(await call($, { tool: 'Bash', command: 'gh pr merge 7 --squash' }))
  expect(unread).toContain('could not check')
  expect(unread).toContain('pull request cannot be read')
  // A pull request carrying no chosen wording needs no repository, as before.
  w.night.diffs['7'] = DIFF_CHANGED
  expect(refusalOf(await call($, { tool: 'Bash', command: 'gh pr merge 7 --squash' }))).toBe('')
})

test('a choice unanswered for three days expires, said once, and stays held; it is never approval (#2628)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  const id = await chooseReword($, w)
  night.asleep = false
  await w.clock.advance(3 * 24 * 60 * 60_000)
  const lines = await promptLines($)
  expect(lines).toContain('expired unanswered')
  expect(lines).toContain(`chosen:${id}`)
  expect(w.store[`chosen:${wordingKey(REWORDED)}`]).toMatchObject({ expired: expect.any(Number) })
  expect(await promptLines($)).not.toContain(`chosen:${id}`)
  expect(w.store[wordingKey(REWORDED)]).toBeUndefined()
  expect(refusalOf(await call($, MERGE))).toContain('chosen overnight')
  // Asleep again, an expired choice lets nothing through: it is held to be chosen again.
  night.asleep = true
  expect(refusalOf(await call($, REWORD))).toContain(CHOOSE)
  night.asleep = false
  await morning($, w, id, APPROVE)
  expect(w.store[wordingKey(REWORDED)]).toBeDefined()
  expect(refusalOf(await call($, MERGE))).toBe('')
})

test('a choice whose session ended is put to Dan by the next session he writes in (#2628)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  const id = await chooseReword($, w)
  night.asleep = false
  w.night.session = 's2'
  expect(await promptLines($)).not.toContain(`chosen:${id}`)
  w.night.session = 's1'
  await ($ as unknown as { session: { end: (e: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  w.night.session = 's2'
  expect(await promptLines($)).toContain(`chosen:${id}`)
})

test('a choice is put to Dan in the session that made it or in its own repository, never in a session in another (#2833)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  const id = await chooseReword($, w)
  night.asleep = false
  // The session that made it asks, wherever it is working now.
  w.ctl.cwd = SITE
  expect(await promptLines($)).toContain(`chosen:${id}`)
  // Once it ends, a session in repository B is never told to ask; one in repository A is.
  await ($ as unknown as { session: { end: (e: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  w.night.session = 's2'
  expect(await promptLines($)).not.toContain(`chosen:${id}`)
  w.ctl.cwd = `${REPO}/lib`
  expect(await promptLines($)).toContain(`chosen:${id}`)
  // A's pull request merged from a session in B is still held, and B is told it is asked in A,
  // never to ask Dan itself; merged from A, the refusal says to ask, as before.
  w.ctl.cwd = SITE
  const away = refusalOf(await call($, { tool: 'Bash', command: 'gh pr merge 12 --squash -R danwright32/app' }))
  expect(away).toContain('chosen overnight')
  expect(away).toContain(' The wording chosen in danwright32/app is put to Dan in a session working in danwright32/app, never in this one: leave the pull request open until he approves it there.')
  expect(away).not.toContain(`chosen:${id}`)
  expect(away).not.toContain('AskUserQuestion')
  w.ctl.cwd = REPO
  expect(refusalOf(await call($, MERGE))).toContain(`Put it to him: call AskUserQuestion with one question and metadata {"source": "slack-alert-guard:chosen:${id}"}`)
  // Expired, it is said only in its own repository, and saying nothing in B does not use up A's telling.
  await w.clock.advance(3 * 24 * 60 * 60_000)
  w.ctl.cwd = SITE
  expect(await promptLines($)).not.toContain(`chosen:${id}`)
  w.ctl.cwd = REPO
  const expired = await promptLines($)
  expect(expired).toContain('expired unanswered')
  expect(expired).toContain(`chosen:${id}`)
})

test('a choice whose repository cannot be read is put to Dan in any session, as before (#2833)', withNight, async ($, on) => {
  nightFresh(true)
  const w = world($, on)
  w.night.originFails = true
  const id = await chooseReword($, w)
  night.asleep = false
  await ($ as unknown as { session: { end: (e: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  w.night.session = 's2'
  w.ctl.cwd = SITE
  expect(await promptLines($)).toContain(`chosen:${id}`)
})

test('taking away unapproved wording that is not on origin passes in any mode; wording origin holds is still held (#2628)', withNight, async ($, on) => {
  nightFresh(false)
  const w = world($, on)
  const DROP = { tool: 'Edit', file_path: ALERT, old_string: 'Deploy ${id} failed', new_string: '' }
  // The file as origin has it without the message: it exists only in a local commit.
  w.night.upstream = { 'lib/alert.ts': 'export const alert = (id: string) => fetch(process.env.SLACK_WEBHOOK_URL, { method: "POST", body: JSON.stringify({ text: `` }) })\n' }
  expect(refusalOf(await call($, DROP))).toBe('')
  // Read from origin's default branch, as mod-kit's branch reader names it.
  expect(w.night.shownFrom).toEqual(['origin/main'])
  // A file origin does not have at all.
  w.night.upstream = {}
  expect(refusalOf(await call($, DROP))).toBe('')
  // The live message, as origin has it, is still held when taken away.
  w.night.upstream = { 'lib/alert.ts': ALERT_TEXT }
  expect(refusalOf(await call($, DROP))).toContain('takes Slack message text away')
  // git failing to say, or no default branch to read, holds as before.
  w.night.showFails = true
  expect(refusalOf(await call($, DROP))).toContain('takes Slack message text away')
  w.night.showFails = false
  w.night.upstream = {}
  w.night.defaultBranch = null
  expect(refusalOf(await call($, DROP))).toContain('takes Slack message text away')
  expect(w.ran.length).toBe(2)
})

// claude-config#2719: on 2026-11-10, in a work repository, every Edit to a 5,488 line monitor route
// that posts through a Slack send helper was held as "was not searched within 7 seconds" or
// "$.process.run(git) aborted: still running after 12ms", a one line import among them, while every
// smaller file went through. git and the reads were not the time: tracing the file's sends was,
// and it grew with the square of the file, since each name's declarations were found by searching
// the whole file once per name. A route of checks, each with its own names as a real one has, judged
// by the searching its tracing does (sends.ts scanWork), never by the wall, which failed it on a Mac
// at load average 149 though the guard did no more work (L290; #2833). This route is lighter
// per line than the real one: at 5,500 lines the guard before the fix took 2.0 to 2.6 s an edit on
// the personal MacBook at load 15 to 41, and at 11,000 lines 8.3 s, held as "git could not name the
// repository", the third message the real file met. So it is judged at 11,000 lines, where the
// guard before the fix fails here as it failed there.
const BIG = '/w/app/src/app/api/monitor/feeds/route.ts'
const BIG_LINES = 11_000
// The most searching one call may do (scanWork), as a multiple of the route's length: the guard
// searched 0.24 times it on 2026-11-12, and the same guard made to search the whole route for each
// name's declarations, as before #2719, searched 22,163 times it and failed here.
const SEARCHED_PER_CHAR = 4
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
// One call judged, with the searching its tracing did as the guard reports it (sends.ts scanWork), in
// multiples of the route's length.
const BIG_CHARS = bigRoute(BIG_LINES).length
const searched: number[] = []
const measured = async ($: Caller, w: W, input: Record<string, unknown>) => {
  const from = w.traced.length
  const why = refusalOf(await call($, input))
  searched.push(w.traced.slice(from).reduce((a, b) => a + b, 0) / BIG_CHARS)
  return why
}
// The route's one line import of the quiet feed copy, judged; then, as the world writes only a
// Write, put in place as the Edit leaves it.
const LOGGER_IMPORT = "import { logger } from '@/lib/logger'\n"
const importBig = async ($: Caller, w: W, text: string) => {
  const held = await measured($, w, { tool: 'Edit', file_path: BIG, old_string: LOGGER_IMPORT, new_string: `${LOGGER_IMPORT}${QUIET_IMPORT}` })
  w.files[BIG] = text.replace(LOGGER_IMPORT, `${LOGGER_IMPORT}${QUIET_IMPORT}`)
  return held
}
// An edit sending the quiet feed page through the route's send helper.
const sendQuiet = (helper: string) => ({ tool: 'Edit', file_path: BIG, old_string: '  if (!rows7.length) return', new_string: `  if (!rows7.length) await ${helper}(quietPage('orders', 45))\n  if (!rows7.length) return` })

test('an 11,000 line route posting through a Slack send helper is judged with searching that grows with the file, not its square: an import and a send of another module\'s wording pass, and rewording its own message is still held (#2719, #2837)', withKit, async ($, on) => {
  const text = bigRoute(BIG_LINES)
  expect(text.split('\n').length).toBeGreaterThanOrEqual(BIG_LINES - 20)
  expect(text.length).toBe(BIG_CHARS)
  searched.length = 0
  const SLACK_POST = '/w/app/src/lib/notify/slack.ts'
  const w = world($, on, { files: { [SLACK_POST]: POST_TEXT.replace('postAlert', 'postSlackAlert'), [QUIET]: QUIET_TEXT, [BIG]: text } })
  // The one line import that was held 14 times: it sends nothing of the module yet.
  expect(await importBig($, w, text)).toBe('')
  expect(w.ran.length).toBe(1)
  // Sending the imported module's wording adds none of the route's own (#2837), so it passes.
  expect(await measured($, w, sendQuiet('postSlackAlert'))).toBe('')
  expect(w.ran.length).toBe(2)
  // Rewording a message the route sends itself is held for the new wording.
  const rewording = { tool: 'Edit', file_path: BIG, old_string: "Look at the queue before the next run.`)\n  }\n  return { name: 'check12'", new_string: "Somebody must clear the queue before the next run.`)\n  }\n  return { name: 'check12'" }
  const reworded = await measured($, w, rewording)
  expect(reworded).not.toContain('could not check')
  expect(reworded).toContain('Somebody must clear the queue before the next run')
  expect(w.ran.length).toBe(2)
  // The import and the send add none of the route's own wording, so neither traces it (#2837); the
  // reword traces the route as it was and as the edit leaves it, and so searched something, though a
  // small multiple of the file: one search of the whole file for each name is hundreds of times it.
  expect(searched.length).toBe(3)
  expect(searched[2]).toBeGreaterThan(0)
  for (const s of searched) expect(s).toBeLessThan(SEARCHED_PER_CHAR)
})

// claude-config#2796: on 2026-11-11, in a work repository, an edit adding names to an existing
// import in a 5,500 line module that sends the alerts ran out of the search time on every try, about
// 20 tries across four builders. Each file that sends the module is a sender of it, and for each one
// the module was traced again as it was and as the edit leaves it, every trace working out afresh
// which of the module's calls send (the same answer each time, since it does not depend on what the
// sender sends) and reading every followed stretch's names again. Measured on the personal MacBook
// at load 16: 40 senders of a 5,500 line module, 3.5 s an edit, half of it finding the same sends 82
// times over; at 11,000 lines, 7.0 s. #2850 removed that search, so the 80 senders are never read
// and nothing here is judged on the wall: a real time budget measured only the machine's load
// (L290), and failed at load 17. What still holds is that the edit passes and new wording is held;
// the cost of tracing an 11,000 line file of its own is judged by the #2719 test above, by its count.
const LIB = '/w/app/src/lib/monitor/alerts.ts'
const DB_FILE = '/w/app/src/lib/db.ts'
const dbModule = (helpers: number) =>
  [
    "import { Pool } from 'pg'\n",
    'export type Db = { query: (q: string, p?: unknown[]) => Promise<Row[]> }\n',
    'export type Row = Record<string, unknown>\n',
    ...Array.from({ length: helpers }, (_, i) => `export const helper${i} = async (db: Db, id: string) => {\n  const rows = await db.query('select * from t${i} where id = $1', [id])\n  if (!rows.length) throw new Error('row ${i} not found')\n  return rows[0]\n}\n`),
    'export const getDb = async (): Promise<Db> => new Pool() as never\nexport const withTx = async () => undefined\n',
  ].join('')
const DB_IMPORT = "import { getDb, type Db, type Row } from '@/lib/db'\n"
const jobSending = (i: number) =>
  `import { check${i} } from '@/lib/monitor/alerts'\nimport { postSlackAlert } from '@/lib/notify/slack'\nexport const run = async () => {\n  const r = await check${i}({} as never, new Date())\n  if (!r.ok) await postSlackAlert(\`Job ${i} failed: \${r.detail}\`)\n}\n`

test('names added to an existing import in an 11,000 line module that 80 files send pass, and wording it newly sends is still held (#2796, #2850)', withKit, async ($, on) => {
  const SLACK_POST = '/w/app/src/lib/notify/slack.ts'
  const files: Record<string, string> = {
    [SLACK_POST]: POST_TEXT.replace('postAlert', 'postSlackAlert'),
    [LIB]: bigRoute(BIG_LINES),
    [DB_FILE]: dbModule(60),
    '/w/app/src/lib/logger.ts': 'export const logger = { info: (m: string, x?: unknown) => console.log(m, x) }\n',
  }
  for (let i = 0; i < 80; i++) files[`/w/app/src/app/api/jobs/job${i}/route.ts`] = jobSending(i)
  const w = world($, on, { files })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: LIB, old_string: DB_IMPORT, new_string: "import { getDb, withTx, helper3, type Db, type Row } from '@/lib/db'\n" }))).toBe('')
  expect(w.ran.length).toBe(1)
  // Wording the module newly sends is still held, so the pass above was the module judged, never a
  // check that judged nothing.
  const reworded = refusalOf(await call($, { tool: 'Edit', file_path: LIB, old_string: "  if (!rows3.length) return { name: 'check3', ok: true }", new_string: "  if (!rows3.length) return { name: 'check3', ok: false, detail: 'Nothing has arrived for kind 3 today' }" }))
  expect(reworded).toContain('Nothing has arrived for kind 3 today')
  expect(reworded).not.toContain('could not check')
  expect(w.ran.length).toBe(1)
})

test('the test clock charges computing time to a clock read: work between calls to the world moves it once the wall is started (#2805)', withKit, async ($, on) => {
  const w = world($, on)
  const before = await w.readClock()
  // Not started: computing costs nothing, as in every test that does not judge the wall.
  const idle = performance.now()
  while (performance.now() - idle < 30) { /* busy */ }
  expect(await w.readClock()).toBe(before)
  // Started: the same computing is charged by the next read, with no call to the world between.
  w.wallStart()
  const busy = performance.now()
  while (performance.now() - busy < 30) { /* busy */ }
  expect((await w.readClock()) - before).toBeGreaterThanOrEqual(30)
  // A later read never goes back: charges only add.
  const at = await w.readClock()
  expect(await w.readClock()).toBeGreaterThanOrEqual(at)
})

test('a CPU bound trace is charged against the search deadline on the test clock: reading the clock after SCAN_MS of computing finds the deadline passed (#2805)', withKit, async ($, on) => {
  const w = world($, on)
  const deadline = (await w.readClock()) + SCAN_MS
  // Computing that began SCAN_MS ago, as a trace through a huge module would have, with no call to
  // the world in between (what #2808's check before each sender reads the clock for).
  w.wallStart(SCAN_MS)
  expect(await w.readClock()).toBeGreaterThanOrEqual(deadline)
})
