import { expect, mock } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { reasonOf, standInCore } from './mod-kit/tests/core.ts'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { ANSWER_MS, DEADLINE_MS, DECIDE_TOOL, ISSUE_LIMIT, ISSUES_TTL_MS, SWEEP_MS, UNREAD_TTL_MS, questionKey } from '../hooks/rules.ts'

// The area check in a session (#1506): the first edit a session makes to each existing source or
// test file is held when an open structural issue names the file or the file is growing fast (#1509),
// and the session decides, through the decide tool, before it is let through. Phase 1 (#1508) only
// logged what it would have done; that log, outside ~/.claude, is kept, with the hold's decisions.

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
          screen: async () => null, blocked: async (input: unknown) => ask('blocked', input), card: nope('card'), commands: nope('commands'), git: nope('git'), gh: nope('gh'),
          writes: nope('writes'), pipeline: nope('pipeline'), workingTree: nope('workingTree'), ghRepo: nope('ghRepo'), linkRepo: nope('linkRepo'),
          mergeHelper: nope('mergeHelper'), bandRow: nope('bandRow'), clearBandRow: nope('clearBandRow'), pane: nope('pane'), clearPane: nope('clearPane'),
          press: async () => ({ isAnswered: false }), clickable: async () => true, isDans: nope('isDans'), typedAnswer: async (input: unknown) => ask('typedAnswer', input),
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
// Scope modes, standing in: asleep and away are the world's to set (`__scope`).
const scope: { name: string; register: Register } = {
  name: 'scope-modes',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ask = async (what: string, input: unknown = null) => {
        const r = await built.process.run(['__scope', what, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout)
      }
      return {
        ...built,
        scopeModes: {
          isAsleep: async () => ask('isAsleep'),
          sleepNote: async (note: unknown) => ask('sleepNote', note),
          hold: async (h: unknown) => ask('hold', h),
        },
      }
    })
  },
}
const KIT = { plugins: [deps, scope] }

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
type Engine = Parameters<typeof standInCore>[0]
const world = ($: unknown, on: On, init: Init = {}) => {
  const files: Record<string, string> = { [`${APP}/src/lib/slack.ts`]: 'x', [`${APP}/src/big.ts`]: 'x', [`${APP}/src/pay/stripe.ts`]: 'x', [`${APP}/docs/x.md`]: 'x' }
  const store: Record<string, unknown> = {}
  const ran: string[] = []
  const logs: string[] = []
  const appended: Record<string, string> = {}
  const passed: string[] = []
  const timeouts: number[] = []
  const cards: Record<string, unknown>[] = []
  const asked: { question: string; options: { label: string }[] }[] = []
  const notes: Record<string, unknown>[] = []
  const holds: Record<string, unknown>[] = []
  const tools: string[] = []
  const ctl: {
    answer?: string | 'afk'
    asleep?: boolean
    away?: boolean
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
  on('store.keys', () => ({ value: Object.keys(store) }) as never)
  on('store.delete', ($, e) => {
    delete store[e.key]
    return { value: undefined } as never
  })
  on('tool.register', ($, e) => {
    tools.push(e.name)
    return { value: { tool: `mcp__area-check__${e.name}` } } as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('prompt.submit', ($, e) => ({ text: e.text, context: e.context ?? [] }) as never)
  // Core, standing in (mod-kit's tests/core.ts): the tool.check chain over every plugin decides
  // whether the call may run; beneath every plugin's hook a settings hook may refuse it.
  const core = standInCore($ as Engine, on, () => (ctl.refuse ? { decision: 'deny', reason: 'refused beneath' } : { decision: 'allow' }))
  on('tool.call', async ($, e) => {
    const c = await core(e)
    if ('refused' in c) return c.refused as never
    if (e.tool === 'AskUserQuestion') {
      const q = ((e as unknown as { questions: { question: string; options: { label: string }[] }[] }).questions ?? [])[0]
      if (q) asked.push(q)
      if (ctl.answer === 'afk') return { result: { questions: [q], answers: {}, afkTimeoutMs: 60_000 } } as never
      return { result: { questions: [q], answers: q && ctl.answer ? { [q.question]: ctl.answer } : {} } } as never
    }
    passed.push(`${e.tool} ${String((e as { file_path?: string }).file_path ?? '')}`)
    return { result: 'done' } as never
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
      if (argv[1] === 'blocked') {
        cards.push(input)
        return answer(ok('null'))
      }
      if (argv[1] === 'typedAnswer') return answer(ok(JSON.stringify(`Dan typed "${input.typed}" instead of choosing, so nothing is recorded.`)))
      if (argv[1] === 'goal') return answer(ok(JSON.stringify(ctl.goal ? { state: 'set', condition: ctl.goal } : { state: 'none' })))
    }
    if (argv[0] === '__scope') {
      const input = JSON.parse(argv[2] as string)
      if (argv[1] === 'isAsleep') return answer(ok(JSON.stringify(!!ctl.asleep)))
      if (argv[1] === 'sleepNote') {
        if (!ctl.asleep) return answer(ok(JSON.stringify({ isNoted: false })))
        notes.push(input)
        return answer(ok(JSON.stringify({ isNoted: true })))
      }
      if (argv[1] === 'hold') {
        holds.push(input)
        if (!ctl.away) return answer(ok(JSON.stringify({ isHeld: false })))
        return answer(ok(JSON.stringify({ isHeld: true, card: { guard: 'Away', reason: `Held for when you are back: ${input.label}.`, safeWay: 'later' }, deny: `Held: Dan is away, so "${input.label}" waits.` })))
      }
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
          // Killed at the timeout it was given, as $.process.run is (lessons review of adb5a9e):
          // the shared ranking then fails by a rejection, not by running out of time.
          const wait = DEADLINE_MS + 500
          if (timeoutMs !== undefined && timeoutMs < wait) {
            await clock.sleep(timeoutMs)
            return { deny: `git log was still running after ${timeoutMs} ms` } as never
          }
          await clock.sleep(wait)
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
  return { clock, ctl, ran, logs, passed, timeouts, store, files, records, judged, cards, asked, notes, holds, tools }
}

type T$ = { tool: { call: (e: never) => Promise<unknown> }; session: { start: (e: never) => Promise<unknown> }; prompt: { submit: (e: never) => Promise<unknown> } }
type R = { result?: unknown; deny?: string; isError?: boolean; text?: string; context?: string[] }
const edit = async ($: T$, w: ReturnType<typeof world>, path: string, extra: object = {}, id = 'c1') => {
  const r = await $.tool.call({ tool: 'Edit', tool_use_id: id, file_path: path, old_string: 'a', new_string: 'b', ...extra } as never)
  await w.clock.settle()
  return r as R
}
const ghLists = (w: ReturnType<typeof world>) => w.ran.filter(l => l.startsWith('gh issue list')).length
// The area check's own words, in whichever form Claude Code wraps a refusal (#1484).
const refusal = (r: unknown) => reasonOf(r, 'area-check')
const decide = async ($: T$, input: object, extra: object = {}) => (await $.tool.call({ tool: DECIDE_TOOL, tool_use_id: 'd1', ...input, ...extra } as never)) as R
const askDan = async ($: T$, call: string, extra: object = {}) =>
  (await $.tool.call({
    tool: 'AskUserQuestion',
    tool_use_id: 'q1',
    questions: [{ question: 'Restructure it?', header: 'Area', options: [{ label: 'Yes', description: '' }, { label: 'No', description: '' }], multiSelect: false }],
    metadata: { source: `area-check:${call}` },
    ...extra,
  } as never)) as R
const said = (r: R) => [...(r.context ?? []), typeof r.result === 'string' ? r.result : '', r.text ?? ''].join(' ')
const REASON = 'This only renames a local variable inside one function.'
const SLACK = `${APP}/src/lib/slack.ts`
const QKEY = questionKey('dan/app', 'src/lib/slack.ts')

test('a session start writes a loaded record outside ~/.claude, so a week with none reads as no load, never as no firings (L90)', KIT, async ($, on) => {
  const w = world($, on)
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
  const loaded = w.records().filter(r => r.kind === 'loaded')
  expect(loaded.length).toBe(1)
  expect(loaded[0]).toMatchObject({ v: 1, kind: 'loaded', session: 's1', rule: 2 })
})

test("a session start warms the session's repository, so its first edit within the hour reads no list of its own", KIT, async ($, on) => {
  const w = world($, on)
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
  expect(ghLists(w)).toBe(1)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(ghLists(w)).toBe(1)
  expect(w.judged()[0]?.issues).toMatchObject({ state: 'read', count: 2 })
})


test('the first edit to a file a structural issue names is held: refused with the facts and how to decide, a card drawn, nothing run, logged as held', KIT, async ($, on) => {
  const w = world($, on)
  const r = await edit($ as never, w, SLACK)
  const why = refusal(r)
  expect(why).toContain('The area check held this Edit to src/lib/slack.ts.')
  expect(why).toContain('#41 (p2, tech-debt)')
  expect(why).toContain(`${DECIDE_TOOL} with {"call": "c1", "decision": "proceed"`)
  expect(w.passed).toEqual([])
  expect(w.cards).toEqual([expect.objectContaining({ toolUseId: 'c1', guard: 'Area check' })])
  expect(String(w.cards[0]?.reason)).toContain('#41')
  const [j] = w.judged()
  expect(j).toMatchObject({
    v: 2, kind: 'judged', session: 's1', agent: null, repo: 'dan/app', path: 'src/lib/slack.ts', fileKind: 'source',
    branch: '12-feature', mergeBase: 'mb123', head: SHA, decision: 'held', why: ['issues'], shown: [41], excluded: [], own: [12],
    matches: [{ n: 41, how: 'path', structural: ['tech-debt'], priority: 'p2' }],
    growth: { net: 8, size: null, fixes: 0, rank: null, crosses: false },
  })
  expect(typeof j?.ms).toBe('number')
})

test('a held edit is not claimed, so sending it again before deciding is held again', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  const again = await edit($ as never, w, SLACK, {}, 'c2')
  expect(refusal(again)).toContain('"call": "c2"')
  expect(w.judged().map(j => j.decision)).toEqual(['held', 'held'])
  expect(w.passed).toEqual([])
})

test('deciding proceed with a reason claims the file: the edit sent again goes through, untouched, and is not judged again', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  const d = await decide($ as never, { call: 'c1', decision: 'proceed', reason: REASON })
  expect(d.deny).toBe(undefined)
  expect(said(d)).toContain('Send the Edit to src/lib/slack.ts again')
  const r = await edit($ as never, w, SLACK, {}, 'c2')
  expect(r.result).toBe('done')
  expect(w.passed).toEqual([`Edit ${SLACK}`])
  expect(w.judged().length).toBe(1)
  expect(w.records().find(x => x.kind === 'decided')).toMatchObject({ v: 2, session: 's1', agent: null, repo: 'dan/app', path: 'src/lib/slack.ts', call: 'c1', decision: 'proceed', reason: REASON })
})

test('a proceed reason that says nothing is refused, and the edit stays held', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'proceed', reason: 'n/a' }))).toContain('is a placeholder, not a reason')
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'proceed' }))).toContain('No reason was given')
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'maybe' }))).toContain('is not a decision')
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
  expect(w.records().filter(x => x.kind === 'decided')).toEqual([])
})

test('a decision names a held call, and only the session or agent it was held for can take it, so no file is cleared ahead', KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await decide($ as never, { call: 'zz', decision: 'proceed', reason: REASON }))).toContain('No edit of yours is held under zz')
  await edit($ as never, w, SLACK)
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'proceed', reason: REASON }, { agentId: 'a1' }))).toContain('No edit of yours is held under c1')
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test('fold names one of the issues the hold showed, and a file held for growth alone has none to fold', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  expect(refusal(await decide($ as never, { call: 'c1', decision: 'fold', issue: 99 }))).toContain('is not an issue the hold showed')
  const d = await decide($ as never, { call: 'c1', decision: 'fold', issue: 41 })
  expect(said(d)).toContain('#41')
  expect(w.records().find(x => x.kind === 'decided')).toMatchObject({ decision: 'fold', issue: 41, call: 'c1' })
  expect((await edit($ as never, w, SLACK, {}, 'c2')).result).toBe('done')
  await edit($ as never, w, `${APP}/src/big.ts`, {}, 'c3')
  expect(refusal(await decide($ as never, { call: 'c3', decision: 'fold', issue: 41 }))).toContain('held for its growth alone')
})

test('restructure in the main session asks Dan in the dialog, worded by the hook, and Proceed anyway releases the file', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  const d = await decide($ as never, { call: 'c1', decision: 'restructure' })
  expect(said(d)).toContain('area-check:c1')
  expect(w.store[QKEY]).toMatchObject({ state: 'pending', issues: [41], session: 's1', call: 'c1', agent: null })
  w.ctl.answer = 'Proceed anyway'
  const q = await askDan($ as never, 'c1')
  expect(w.asked[0]?.question.startsWith('Restructure src/lib/slack.ts before this work?')).toBe(true)
  expect(w.asked[0]?.options.map(o => o.label)).toEqual(['Restructure first', 'Proceed anyway', 'Fold in'])
  expect(said(q)).toContain('Send the Edit to src/lib/slack.ts again')
  expect(w.store[QKEY]).toMatchObject({ state: 'answered', answer: 'Proceed anyway', issues: [41] })
  expect((await edit($ as never, w, SLACK, {}, 'c2')).result).toBe('done')
  expect(w.records().find(x => x.kind === 'decided')).toMatchObject({ decision: 'proceed', by: 'dan', call: 'c1' })
})

test('Restructure first releases the file for the structural fix', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  w.ctl.answer = 'Restructure first'
  expect(said(await askDan($ as never, 'c1'))).toContain('Restructure first')
  expect((await edit($ as never, w, SLACK, {}, 'c2')).result).toBe('done')
})

test('Fold in tells Claude to fold with the decide tool, and the edit stays held until it does', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  w.ctl.answer = 'Fold in'
  expect(said(await askDan($ as never, 'c1'))).toContain('"decision": "fold"')
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test('an answer Dan did not choose records nothing: the dialog closing while he was away, or an answer typed in', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  await decide($ as never, { call: 'c1', decision: 'restructure' })
  w.ctl.answer = 'afk'
  expect(said(await askDan($ as never, 'c1'))).toContain('did not answer')
  w.ctl.answer = 'maybe later'
  expect(said(await askDan($ as never, 'c1'))).toContain('Dan typed "maybe later"')
  expect(w.store[QKEY]).toMatchObject({ state: 'pending' })
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test('a question no edit is held under, or one a subagent tries to ask, is refused', KIT, async ($, on) => {
  const w = world($, on)
  expect(refusal(await askDan($ as never, 'zz'))).toContain('No edit is held under zz')
  await edit($ as never, w, SLACK)
  expect(refusal(await askDan($ as never, 'c1', { agentId: 'a1' }))).toContain('Only the main session asks Dan')
  expect(w.asked).toEqual([])
})

test("Dan's answer stands for a week for the same issues, so a later first edit applies it without asking", KIT, async ($, on) => {
  const w = world($, on)
  w.store[QKEY] = { state: 'answered', answer: 'Proceed anyway', at: T0 - 1000, issues: [41] }
  expect((await edit($ as never, w, SLACK)).result).toBe('done')
  expect(w.judged()[0]).toMatchObject({ decision: 'held', applied: 'Proceed anyway' })
  expect(w.cards).toEqual([])
})

test("Dan's answer past its week, or for another set of issues, asks again", KIT, async ($, on) => {
  const w = world($, on)
  w.store[QKEY] = { state: 'answered', answer: 'Proceed anyway', at: T0 - ANSWER_MS - 1, issues: [41] }
  expect(refusal(await edit($ as never, w, SLACK))).toContain('The area check held this Edit')
  w.store[QKEY] = { state: 'answered', answer: 'Proceed anyway', at: T0 - 1000, issues: [41, 50] }
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test("a subagent's edit is held for itself, and restructure hands the question to the main session, which is told at the next prompt", KIT, async ($, on) => {
  const w = world($, on)
  const r = await edit($ as never, w, SLACK, { agentId: 'a1' })
  expect(refusal(r)).toContain('hands the question to the main session')
  expect(w.judged()[0]).toMatchObject({ agent: 'a1', decision: 'held' })
  const d = await decide($ as never, { call: 'c1', decision: 'restructure' }, { agentId: 'a1' })
  expect(said(d)).toContain('Stop and report')
  expect(w.store[QKEY]).toMatchObject({ state: 'pending', agent: 'a1', call: 'c1' })
  const p = (await $.prompt.submit({ text: 'go on', origin: { kind: 'composer' }, wait: false } as never)) as R
  expect((p.context ?? []).join(' ')).toContain('src/lib/slack.ts')
  expect((p.context ?? []).join(' ')).toContain('area-check:c1')
  w.ctl.answer = 'Proceed anyway'
  await askDan($ as never, 'c1')
  expect((await edit($ as never, w, SLACK, { agentId: 'a1' }, 'c5')).result).toBe('done')
  const after = (await $.prompt.submit({ text: 'next', origin: { kind: 'composer' }, wait: false } as never)) as R
  expect((after.context ?? []).join(' ')).not.toContain('area-check:c1')
})

test('asleep, restructure notes the question for the morning, one note per issue shown, and asks nobody', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.asleep = true
  await edit($ as never, w, SLACK)
  const d = await decide($ as never, { call: 'c1', decision: 'restructure' })
  expect(said(d)).toContain('asleep')
  expect(w.notes).toEqual([expect.objectContaining({ kind: 'question', repo: 'dan/app', issue: 41 })])
  expect(w.asked).toEqual([])
  expect(w.store[QKEY]).toMatchObject({ state: 'pending' })
})

test('away, restructure is held by scope modes for when Dan is back', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.away = true
  await edit($ as never, w, SLACK)
  const d = await decide($ as never, { call: 'c1', decision: 'restructure' })
  expect(refusal(d)).toContain('Held: Dan is away')
  expect(String(w.holds[0]?.label)).toContain('src/lib/slack.ts')
  expect(w.asked).toEqual([])
})

test('an edit a settings hook refuses beneath is refused in its words, and never held, judged or claimed', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.refuse = true
  expect(refusal(await edit($ as never, w, SLACK))).toBe('refused beneath')
  expect(w.cards).toEqual([])
  expect(w.judged()).toEqual([])
  w.ctl.refuse = false
  expect(refusal(await edit($ as never, w, SLACK, {}, 'c2'))).toContain('The area check held this Edit')
})

test('a quiet file is claimed: a second edit to it in the session is not judged again', KIT, async ($, on) => {
  const w = world($, on)
  expect((await edit($ as never, w, `${APP}/src/pay/stripe.ts`)).result).toBe('done')
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`, {}, 'c2')
  expect(w.judged().length).toBe(1)
  expect(w.passed.length).toBe(2)
})

test('a new file, a docs file, a file in no checkout and a shell write are not judged (decisions 2 and 3)', KIT, async ($, on) => {
  const w = world($, on)
  await $.tool.call({ tool: 'Write', tool_use_id: 'c1', file_path: `${APP}/src/new.ts`, content: 'x' } as never)
  await edit($ as never, w, `${APP}/docs/x.md`)
  await edit($ as never, w, '/elsewhere/a.ts')
  await $.tool.call({ tool: 'Bash', tool_use_id: 'c2', command: `echo x >> ${APP}/src/lib/slack.ts` } as never)
  await w.clock.settle()
  expect(w.judged()).toEqual([])
  expect(w.passed.length).toBe(4)
})

test("an issue the session's branch names is left out, and was its only match, so the file is quiet (decision 5)", KIT, async ($, on) => {
  const w = world($, on, { branch: 'fix/41-slack' })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'quiet', why: [], shown: [], excluded: [41], own: [41] })
})

test("an issue the session's /goal names is left out too", KIT, async ($, on) => {
  const w = world($, on, { branch: 'feature', goal: 'Finish #41 today' })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'quiet', excluded: [41], own: [41], goal: 'set' })
})

test('an unlabelled issue naming the file is logged but does not hold it', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'quiet', matches: [{ n: 42, how: 'basename', structural: [], priority: null }] })
})


test('a file across the growth bar is held by growth, with its rough growth line', KIT, async ($, on) => {
  const w = world($, on)
  const r = await edit($ as never, w, `${APP}/src/big.ts`)
  expect(refusal(r)).toContain('Rough: grew 800 lines net in 90 days, about 2400 lines now, 1 commit titles saying fix.')
  expect(w.judged()[0]).toMatchObject({ decision: 'held', why: ['growth'], growth: { net: 800, size: 2400, fixes: 1, rank: 1, crosses: true } })
})

test('a subagent is judged for itself: a quiet file the main session judged is judged again under its id (decision 8)', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`, { agentId: 'a1' }, 'c2')
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`, { agentId: 'a1' }, 'c3')
  expect(w.judged().map(r => r.agent)).toEqual([null, 'a1'])
  expect(w.passed.length).toBe(3)
})

test('issues are cached per repository for an hour, then read again', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(ghLists(w)).toBe(1)
  await w.clock.advance(ISSUES_TTL_MS + 1)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(ghLists(w)).toBe(2)
})


test('a wrong account is retried as each other account gh is logged in to (decision 12)', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.gh = env => (env?.GH_TOKEN === 'tok-dan-work' ? { exitCode: 0, stdout: JSON.stringify(ISSUES), stderr: '' } : { exitCode: 1, stdout: '', stderr: 'GraphQL: Could not resolve to a Repository with the name dan/app.' })
  await edit($ as never, w, SLACK)
  expect(w.judged()[0]).toMatchObject({ decision: 'held', issues: { state: 'read' } })
})

test('issues no account can read are UNREAD with the reason: growth still holds, a quiet edit goes through unclaimed, and the failure is reused for ten minutes', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.gh = () => ({ exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com' })
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(w.judged()[0]).toMatchObject({ decision: 'held', why: ['growth'], issues: { state: 'unread', why: 'error connecting to api.github.com' } })
  const asked = ghLists(w)
  expect((await edit($ as never, w, SLACK, {}, 'c2')).result).toBe('done')
  expect(ghLists(w)).toBe(asked)
  expect(w.judged()[1]).toMatchObject({ decision: 'quiet', issues: { state: 'unread' } })
  // Not claimed, since its issues were never read (decision 12): its next edit is judged again.
  await edit($ as never, w, SLACK, {}, 'c3')
  expect(w.judged().length).toBe(3)
  await w.clock.advance(UNREAD_TTL_MS + 1)
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`, {}, 'c4')
  expect(ghLists(w)).toBeGreaterThan(asked)
})

test('a list that fills the limit is TRUNCATED, its own outcome', KIT, async ($, on) => {
  const many = Array.from({ length: ISSUE_LIMIT }, (_, i) => ({ number: i + 1000, title: '', body: '', labels: [] }))
  const w = world($, on, { issues: many })
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ issues: { state: 'truncated', count: ISSUE_LIMIT } })
})

test('the path reader failing makes the issues UNREAD, saying so', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.pathsFails = true
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  expect(w.judged()[0]).toMatchObject({ issues: { state: 'unread', why: 'the path reader failed: match-open-issues --paths: stdin is not JSON' } })
})


test('every read runs under one deadline below 75% of the budget, and a read past it is UNREAD as timed out, the edit going on', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.gh = () => 'slow'
  const p = $.tool.call({ tool: 'Edit', tool_use_id: 'c1', file_path: SLACK, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(DEADLINE_MS + 2000)
  expect(((await p) as R).result).toBe('done')
  expect(Math.max(...w.timeouts)).toBeLessThanOrEqual(DEADLINE_MS)
  expect(w.judged()[0]).toMatchObject({ issues: { state: 'unread', why: `not read within ${DEADLINE_MS / 1000} seconds` } })
})

test('the ranking is reused for the same origin head on the same day, and made again when the head moves', KIT, async ($, on) => {
  const w = world($, on)
  const numstats = () => w.ran.filter(l => l.includes(' log origin/main ')).length
  await edit($ as never, w, `${APP}/src/lib/slack.ts`)
  await edit($ as never, w, `${APP}/src/big.ts`)
  expect(numstats()).toBe(1)
  w.ctl.sha = 'ffff00'
  await edit($ as never, w, `${APP}/src/pay/stripe.ts`)
  expect(numstats()).toBe(2)
})

// Lessons reviews of 5a4148a and adb5a9e: a ranking another edit started runs under that edit's
// deadline, so it fails when that edit's time is spent (here its git log is killed at the timeout it
// was given), and a later edit sharing it, whose own time remains, makes the ranking again.
test("a later edit sharing a ranking that failed for lack of the first edit's time makes its own, within its own deadline", KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.slowLogOnce = true
  const a = $.tool.call({ tool: 'Edit', tool_use_id: 'c1', file_path: SLACK, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(3000)
  const b = $.tool.call({ tool: 'Edit', tool_use_id: 'c2', file_path: `${APP}/src/big.ts`, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(DEADLINE_MS + 3000)
  await Promise.all([a, b])
  const [first, second] = w.judged()
  expect(first).toMatchObject({ path: 'src/lib/slack.ts', growth: { unread: `area-check: $.process.run: git log was still running after ${DEADLINE_MS} ms` } })
  expect(second).toMatchObject({ path: 'src/big.ts', decision: 'held', growth: { net: 800, crosses: true } })
})

// Lessons review of 42547b6: the same for a shared issue read another edit started.
test("a later edit sharing an issue read that ran out of the first edit's time reads again, within its own deadline", KIT, async ($, on) => {
  const w = world($, on)
  let first = true
  w.ctl.gh = () => {
    if (!first) return { exitCode: 0, stdout: JSON.stringify(ISSUES), stderr: '' }
    first = false
    return 'slow'
  }
  const a = $.tool.call({ tool: 'Edit', tool_use_id: 'c1', file_path: `${APP}/src/big.ts`, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(3000)
  const b = $.tool.call({ tool: 'Edit', tool_use_id: 'c2', file_path: SLACK, old_string: 'a', new_string: 'b' } as never)
  await w.clock.advance(DEADLINE_MS + 3000)
  await Promise.all([a, b])
  const [x, y] = w.judged()
  expect(x).toMatchObject({ path: 'src/big.ts', issues: { state: 'unread', why: `not read within ${DEADLINE_MS / 1000} seconds` } })
  expect(y).toMatchObject({ path: 'src/lib/slack.ts', decision: 'held', issues: { state: 'read' } })
})

test('its own failure lets the edit through, is kept in a separate error file, and is said once a session in a dim line', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.branchThrows = true
  const r = await edit($ as never, w, SLACK)
  await edit($ as never, w, `${APP}/src/big.ts`, {}, 'c2')
  expect(r.result).toBe('done')
  expect(w.passed.length).toBe(2)
  expect(w.records(ERRORS).length).toBe(2)
  expect(w.records(ERRORS)[0]).toMatchObject({ kind: 'error', session: 's1', path: SLACK, error: 'git could not be asked' })
  expect(w.logs.filter(l => l.includes('area check')).length).toBe(1)
  expect(w.logs[0]).toBe('The area check could not look at src/lib/slack.ts (git could not be asked), so the edit went ahead unchecked; the error is kept in ~/.claude-area-check/errors.jsonl.')
})

test('a log that cannot be written is an error of its own, kept in the error file, and the hold still stands', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.logFails = true
  expect(refusal(await edit($ as never, w, SLACK))).toContain('The area check held this Edit')
  expect(w.records(ERRORS)[0]).toMatchObject({ kind: 'error', error: 'the log could not be written: No space left on device' })
})

test('a session start sweeps issue lists unread for a week and answers past their week, and keeps a question still waiting on Dan', KIT, async ($, on) => {
  const w = world($, on)
  w.store['issues:dan/old'] = { at: T0 - SWEEP_MS, state: 'read', count: 0, issues: [] }
  w.store['question:dan/app\nsrc/old.ts'] = { state: 'answered', answer: 'Proceed anyway', at: T0 - ANSWER_MS, issues: [1] }
  w.store['question:dan/app\nsrc/wait.ts'] = { state: 'pending', at: T0 - ANSWER_MS * 2, issues: [1], session: 's0', call: 'c0', agent: null }
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
  expect(Object.keys(w.store).sort()).toEqual(['issues:dan/app', 'question:dan/app\nsrc/wait.ts'])
})

test('the decide tool is offered at every session start, a headless one included, since subagents decide with it too', KIT, async ($, on) => {
  const w = world($, on)
  await $.session.start({ cwd: APP, surface: 'terminal', isInteractive: false } as never)
  await w.clock.settle()
  expect(w.tools).toEqual(['decide'])
})
