import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { DEADLINE_MS, ISSUE_LIMIT, ISSUES_TTL_MS, UNREAD_TTL_MS } from '../hooks/rules.ts'

// The area check in a session, phase 1 (#1508): it watches the first edit a session makes to each
// existing source or test file and logs what it would have done, outside ~/.claude, and never refuses
// anything. A week of this log decides how the hold is turned on (#1509).

// mod-kit and the session registry, standing in. A plugin in a test runs apart from this file, so
// each member asks the world through a process the world answers (`__modkit`, `__sessions`).
const deps: { name: string; register: Register } = {
  name: 'deps',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ask = async (what: string, input: unknown) => {
        const r = await built.process.run(['__modkit', what, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout)
      }
      const nope = (m: string) => async () => { throw new Error(`mod-kit's ${m} is not stood in by these tests`) }
      return {
        ...built,
        modkit: {
          branch: async (input: unknown) => ask('branch', input),
          repo: async (input: unknown) => ask('repo', input),
          goal: async (input: unknown) => ask('goal', input),
          screen: nope('screen'), blocked: nope('blocked'), card: nope('card'), commands: nope('commands'), git: nope('git'), gh: nope('gh'),
          writes: nope('writes'), pipeline: nope('pipeline'), workingTree: nope('workingTree'), ghRepo: nope('ghRepo'), linkRepo: nope('linkRepo'),
          mergeHelper: nope('mergeHelper'), bandRow: nope('bandRow'), clearBandRow: nope('clearBandRow'), pane: nope('pane'), clearPane: nope('clearPane'),
          press: async () => ({ isAnswered: false }), clickable: async () => true, isDans: nope('isDans'), typedAnswer: nope('typedAnswer'),
          pythonText: nope('pythonText'), login: nope('login'), account: nope('account'),
        },
        sessions: {
          list: async () => {
            const r = await built.process.run(['__sessions'])
            if (r.exitCode !== 0) throw new Error(r.stderr)
            return JSON.parse(r.stdout)
          },
          noteEdit: async () => undefined,
          setExtra: async () => undefined,
        },
      }
    })
  },
}
const KIT = { plugins: [deps] }

const HOME = '/Users/dan'
const LOG = `${HOME}/.claude-area-check/log.jsonl`
const ERRORS = `${HOME}/.claude-area-check/errors.jsonl`
const T0 = Date.UTC(2026, 9, 22, 15, 0, 0)
const APP = '/w/app'
const SHA = 'a1b2c3'

// 90 days of the app's default branch, newest first: big.ts grew fast; slack.ts barely.
const NUMSTAT = ['\x1efix: stop the crash (#3)', '900\t100\tsrc/big.ts', '\x1eSmall change', '10\t2\tsrc/lib/slack.ts'].join('\n')
const TRACKED = ['src/big.ts', 'src/lib/slack.ts', 'src/pay/stripe.ts', 'docs/x.md', 'README.md'].join('\n')
type Issue = { number: number; title: string; body: string; labels: { name: string }[] }
const ISSUES: Issue[] = [
  { number: 41, title: 'Split the slack client', body: 'src/lib/slack.ts:10-80 does three jobs', labels: [{ name: 'tech-debt' }, { name: 'priority-p2' }] },
  { number: 42, title: 'An idea', body: 'stripe.ts could be faster', labels: [{ name: 'enhancement' }] },
]

type Run = { exitCode: number; stdout: string; stderr: string }
type Init = { branch?: string; goal?: string; issues?: Issue[] }
const world = (on: On, init: Init = {}) => {
  const files: Record<string, string> = { [`${APP}/src/lib/slack.ts`]: 'x', [`${APP}/src/big.ts`]: 'x', [`${APP}/src/pay/stripe.ts`]: 'x', [`${APP}/docs/x.md`]: 'x' }
  const store: Record<string, unknown> = {}
  const ran: string[] = []
  const logs: string[] = []
  const appended: Record<string, string> = {}
  const passed: string[] = []
  const timeouts: number[] = []
  const ctl: {
    issues: Issue[]
    gh: (env?: Record<string, string>) => Run | 'slow'
    branchThrows?: boolean
    logFails?: boolean
    pathsFails?: boolean
    refuse?: boolean
    slowLogOnce?: boolean
    sha: string
    goal: string | null
  } = {
    issues: init.issues ?? ISSUES,
    gh: () => ({ exitCode: 0, stdout: JSON.stringify(ctl.issues), stderr: '' }),
    sha: SHA,
    goal: init.goal ?? null,
  }
  const clock = mock.clock(on, { now: T0 })
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : undefined }) as never)
  on('session.id', () => ({ value: 's1' }) as never)
  on('session.cwd', () => ({ value: APP }) as never)
  on('session.repo', () => ({ value: { root: APP, remote: 'git@github.com:dan/app.git' } }) as never)
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }) as never)
  on('store.get', ($, e) => ({ value: store[e.key] }) as never)
  on('store.set', ($, e) => {
    store[e.key] = e.value
    return { value: undefined } as never
  })
  on('ui.log', ($, e) => {
    logs.push(String((e as { text?: string }).text ?? ''))
    return { value: undefined } as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', ($, e) => {
    passed.push(`${e.tool} ${String((e as { file_path?: string }).file_path ?? '')}`)
    return (ctl.refuse ? { deny: 'refused beneath' } : { result: 'done' }) as never
  })
  const ok = (stdout: string): Run => ({ exitCode: 0, stdout, stderr: '' })
  on('process.run', async ($, e) => {
    const argv = e.argv.map(String)
    const stdin = e.init?.stdin ?? ''
    const env = e.init?.env
    const timeoutMs = e.init?.timeoutMs
    const answer = (r: Run) => ({ value: { ...r, isStdoutTruncated: false, isStderrTruncated: false } }) as never
    const line = argv.join(' ')
    if (argv[0] === '__modkit') {
      const input = JSON.parse(argv[2] as string)
      if (argv[1] === 'branch') {
        if (ctl.branchThrows) return answer({ exitCode: 1, stdout: '', stderr: 'git could not be asked' })
        if (input.path !== APP && !String(input.path).startsWith(APP + '/')) return answer(ok('null'))
        const branch = init.branch ?? '12-feature'
        const issues = [...branch.matchAll(/(?:^|[/_.-])(\d+)(?=$|[/_.-])/g)].map(m => Number(m[1]))
        return answer(ok(JSON.stringify({ root: APP, main: APP, branch, defaultBranch: 'main', isDefault: false, issues })))
      }
      if (argv[1] === 'repo') return answer(ok(JSON.stringify({ github: String(input.remote).includes('github.com') ? 'dan/app' : null, name: 'app' })))
      if (argv[1] === 'goal') return answer(ok(JSON.stringify(ctl.goal ? { state: 'set', condition: ctl.goal } : { state: 'none' })))
    }
    if (argv[0] === '__sessions') return answer(ok(JSON.stringify({ open: [{ sessionId: 's1', transcriptPath: '/t/s1.jsonl' }], closed: [], unreadable: [], selfId: 's1' })))
    ran.push(line)
    if (typeof timeoutMs === 'number') timeouts.push(timeoutMs)
    if (argv[0] === '/bin/sh') {
      if (ctl.logFails && argv[argv.length - 1] === LOG) return answer({ exitCode: 1, stdout: '', stderr: 'No space left on device' })
      const file = argv[argv.length - 1] as string
      appended[file] = (appended[file] ?? '') + stdin
      return answer(ok(''))
    }
    if (argv[0] === 'git' && argv[1] === '-C' && argv[2] === APP) {
      const sub = argv.slice(3).join(' ')
      if (sub === 'remote get-url origin') return answer(ok('git@github.com:dan/app.git\n'))
      if (sub === 'rev-parse --verify origin/main^{commit}') return answer(ok(`${ctl.sha}\n`))
      if (sub === 'merge-base HEAD origin/main') return answer(ok('mb123\n'))
      if (sub === 'log origin/main --since=90.days --numstat -M --format=%x1e%s') {
        if (ctl.slowLogOnce) {
          ctl.slowLogOnce = false
          await clock.sleep(DEADLINE_MS + 500)
        }
        return answer(ok(NUMSTAT))
      }
      if (sub === 'ls-tree -r --name-only origin/main') return answer(ok(TRACKED + '\n'))
      if (sub.startsWith('grep -c  origin/main -- ')) return answer(ok('origin/main:src/big.ts:2400\n'))
    }
    if (argv[0] === 'gh' && argv[1] === 'issue' && argv[2] === 'list') {
      const r = ctl.gh(env)
      if (r === 'slow') {
        await clock.sleep(DEADLINE_MS + 1000)
        return answer({ exitCode: 1, stdout: '', stderr: 'unreachable' })
      }
      return answer(r)
    }
    if (line === 'gh auth status') return answer(ok('github.com\n  Logged in to github.com account dan-personal (keyring)\n  Logged in to github.com account dan-work (keyring)\n'))
    if (argv[0] === 'gh' && argv[1] === 'auth' && argv[2] === 'token') return answer(ok(`tok-${argv[4]}\n`))
    if (argv[0] === 'python3' && argv[argv.length - 1] === '--paths') {
      if (ctl.pathsFails) return answer({ exitCode: 2, stdout: '', stderr: 'match-open-issues --paths: stdin is not JSON' })
      const rows = JSON.parse(stdin) as { number: number; body: string }[]
      const out: Record<string, string[]> = {}
      for (const r of rows) out[String(r.number)] = [...r.body.matchAll(/[A-Za-z0-9_/.-]+\.ts\b/g)].map(m => m[0])
      return answer(ok(JSON.stringify(out)))
    }
    throw new Error(`unexpected run: ${line}`)
  })
  const records = (file = LOG) => (appended[file] ?? '').split('\n').filter(Boolean).map(l => JSON.parse(l) as Record<string, unknown>)
  const judged = () => records().filter(r => r.kind === 'judged')
  return { clock, ctl, ran, logs, passed, timeouts, store, files, records, judged }
}

type T$ = { tool: { call: (e: never) => Promise<unknown> }; session: { start: (e: never) => Promise<unknown> } }
const edit = async ($: T$, w: ReturnType<typeof world>, path: string, extra: object = {}) => {
  const r = await $.tool.call({ tool: 'Edit', tool_use_id: 'c1', file_path: path, old_string: 'a', new_string: 'b', ...extra } as never)
  await w.clock.settle()
  return r as { result?: unknown; deny?: string }
}
const ghLists = (w: ReturnType<typeof world>) => w.ran.filter(l => l.startsWith('gh issue list')).length

test('a session start writes a loaded record outside ~/.claude, so a week with none reads as no load, never as no firings (L90)', KIT, async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
  const loaded = w.records().filter(r => r.kind === 'loaded')
  expect(loaded.length).toBe(1)
  expect(loaded[0]).toMatchObject({ v: 1, kind: 'loaded', session: 's1', rule: 1 })
})

test("a session start warms the session's repository, so its first edit within the hour reads no list of its own", KIT, async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
  expect(ghLists(w)).toBe(1)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(ghLists(w)).toBe(1)
  expect(w.judged()[0]?.issues).toMatchObject({ state: 'read', count: 2 })
})

test('the first edit to a file a structural issue names is logged as would_hold, and the edit goes through untouched', KIT, async ($, on) => {
  const w = world(on)
  const r = await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(r.result).toBe('done')
  expect(r.deny).toBe(undefined)
  expect(w.passed).toEqual([`Edit ${APP}/src/lib/slack.ts`])
  const [j] = w.judged()
  expect(j).toMatchObject({
    kind: 'judged', session: 's1', agent: null, repo: 'dan/app', path: 'src/lib/slack.ts', fileKind: 'source',
    branch: '12-feature', mergeBase: 'mb123', head: SHA, decision: 'would_hold', why: ['issues'], shown: [41], excluded: [], own: [12],
    matches: [{ n: 41, how: 'path', structural: ['tech-debt'], priority: 'p2' }],
    growth: { net: 8, size: null, fixes: 0, rank: null, crosses: false },
  })
  expect(typeof j?.ms).toBe('number')
})

test('an edit a guard beneath refused is still judged, the attempt being what the hold would meet, and says it was refused', KIT, async ($, on) => {
  const w = world(on)
  w.ctl.refuse = true
  const r = await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(r.deny).toBe('refused beneath')
  expect(w.judged()[0]).toMatchObject({ decision: 'would_hold', refusedBeneath: true })
})

test('a second edit to the same file in the session is not judged again', KIT, async ($, on) => {
  const w = world(on)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged().length).toBe(1)
})

test('a new file, a docs file, a file in no checkout and a shell write are not judged (decisions 2 and 3)', KIT, async ($, on) => {
  const w = world(on)
  await $.tool.call({ tool: 'Write', tool_use_id: 'c1', file_path: `${APP}/src/new.ts`, content: 'x' } as never)
  await edit($ as never, w, `${APP}/docs/x.md`)
  await edit($ as never, w, '/elsewhere/a.ts')
  await $.tool.call({ tool: 'Bash', tool_use_id: 'c2', command: `echo x >> ${APP}/src/lib/slack.ts` } as never)
  await w.clock.settle()
  expect(w.judged()).toEqual([])
  expect(w.passed.length).toBe(4)
})

test("an issue the session's branch names is left out, and was its only match, so the file is quiet (decision 5)", KIT, async ($, on) => {
  const w = world(on, { branch: 'fix/41-slack' })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'quiet', why: [], shown: [], excluded: [41], own: [41] })
})

test("an issue the session's /goal names is left out too", KIT, async ($, on) => {
  const w = world(on, { branch: 'feature', goal: 'Finish #41 today' })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'quiet', excluded: [41], own: [41], goal: 'set' })
})

test('an unlabelled issue naming the file is logged but does not make it would_hold', KIT, async ($, on) => {
  const w = world(on)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'quiet', matches: [{ n: 42, how: 'basename', structural: [], priority: null }] })
})

test('a file across the growth bar is would_hold by growth, with its rough growth line', KIT, async ($, on) => {
  const w = world(on)
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'would_hold', why: ['growth'], growth: { net: 800, size: 2400, fixes: 1, rank: 1, crosses: true } })
})

test('a subagent is judged for itself: the same file the main session judged is judged again under its id (decision 8)', KIT, async ($, on) => {
  const w = world(on)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`, { agentId: 'a1' })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`, { agentId: 'a1' })
  expect(w.judged().map(r => r.agent)).toEqual([null, 'a1'])
})

test('issues are cached per repository for an hour, then read again', KIT, async ($, on) => {
  const w = world(on)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(ghLists(w)).toBe(1)
  await w.clock.advance(ISSUES_TTL_MS + 1)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(ghLists(w)).toBe(2)
})

test('a wrong account is retried as each other account gh is logged in to (decision 12)', KIT, async ($, on) => {
  const w = world(on)
  w.ctl.gh = env => (env?.GH_TOKEN === 'tok-dan-work' ? { exitCode: 0, stdout: JSON.stringify(ISSUES), stderr: '' } : { exitCode: 1, stdout: '', stderr: 'GraphQL: Could not resolve to a Repository with the name dan/app.' })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'would_hold', issues: { state: 'read' } })
})

test('issues no account can read are UNREAD with the reason, the growth bar still applies, and the failure is reused for ten minutes', KIT, async ($, on) => {
  const w = world(on)
  w.ctl.gh = () => ({ exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com' })
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'would_hold', why: ['growth'], issues: { state: 'unread', why: 'error connecting to api.github.com' } })
  const asked = ghLists(w)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(ghLists(w)).toBe(asked)
  expect(w.judged()[1]).toMatchObject({ decision: 'quiet', issues: { state: 'unread' } })
  await w.clock.advance(UNREAD_TTL_MS + 1)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(ghLists(w)).toBeGreaterThan(asked)
})

test('a list that fills the limit is TRUNCATED, its own outcome', KIT, async ($, on) => {
  const many = Array.from({ length: ISSUE_LIMIT }, (_, i) => ({ number: i + 1000, title: '', body: '', labels: [] }))
  const w = world(on, { issues: many })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ issues: { state: 'truncated', count: ISSUE_LIMIT } })
})

test('the path reader failing makes the issues UNREAD, saying so', KIT, async ($, on) => {
  const w = world(on)
  w.ctl.pathsFails = true
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ issues: { state: 'unread', why: 'the path reader failed: match-open-issues --paths: stdin is not JSON' } })
})

test('every read runs under one deadline below 75% of the budget, and a read past it is UNREAD as timed out', KIT, async ($, on) => {
  const w = world(on)
  w.ctl.gh = () => 'slow'
  const r = await $.tool.call({ tool: 'Edit', tool_use_id: 'c1', file_path: `${APP}/src/lib/slack.ts`, old_string: 'a', new_string: 'b' } as never)
  expect((r as { result?: unknown }).result).toBe('done')
  await w.clock.advance(DEADLINE_MS + 2000)
  expect(Math.max(...w.timeouts)).toBeLessThanOrEqual(DEADLINE_MS)
  expect(w.judged()[0]).toMatchObject({ issues: { state: 'unread', why: `not read within ${DEADLINE_MS / 1000} seconds` } })
})

test('the ranking is reused for the same origin head on the same day, and made again when the head moves', KIT, async ($, on) => {
  const w = world(on)
  const numstats = () => w.ran.filter(l => l.includes(' log origin/main ')).length
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(numstats()).toBe(1)
  w.ctl.sha = 'ffff00'
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(numstats()).toBe(2)
})

// Lessons review of 5a4148a: a ranking another edit started runs under that edit's deadline, so a
// later edit sharing it must not be told it ran out of time while its own time remains.
test("a later edit sharing a ranking that ran out of the first edit's time makes its own, within its own deadline", KIT, async ($, on) => {
  const w = world(on)
  w.ctl.slowLogOnce = true
  await $.tool.call({ tool: 'Edit', tool_use_id: 'c1', file_path: `${APP}/src/lib/slack.ts`, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(3000)
  await $.tool.call({ tool: 'Edit', tool_use_id: 'c2', file_path: `${APP}/src/big.ts`, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(DEADLINE_MS + 3000)
  const [first, second] = w.judged()
  expect(first).toMatchObject({ path: 'src/lib/slack.ts', growth: { unread: `not read within ${DEADLINE_MS / 1000} seconds` } })
  expect(second).toMatchObject({ path: 'src/big.ts', decision: 'would_hold', growth: { net: 800, crosses: true } })
})

test('its own failure lets the edit through, is kept in a separate error file, and is said once a session in a dim line', KIT, async ($, on) => {
  const w = world(on)
  w.ctl.branchThrows = true
  const r = await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(r.result).toBe('done')
  expect(w.records(ERRORS).length).toBe(2)
  expect(w.records(ERRORS)[0]).toMatchObject({ kind: 'error', session: 's1', path: `${APP}/src/lib/slack.ts`, error: 'git could not be asked' })
  expect(w.logs.filter(l => l.includes('area check')).length).toBe(1)
  expect(w.logs[0]).toBe('The area check could not look at src/lib/slack.ts (git could not be asked). It only observes for now, so nothing was held; the error is kept in ~/.claude-area-check/errors.jsonl.')
})

test('a log that cannot be written is an error of its own, kept in the error file', KIT, async ($, on) => {
  const w = world(on)
  w.ctl.logFails = true
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.records(ERRORS)[0]).toMatchObject({ kind: 'error', error: 'the log could not be written: No space left on device' })
})
