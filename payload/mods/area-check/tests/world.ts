import { mock } from 'claude-code/testing'
import { reasonOf, standInCore } from './mod-kit/tests/core.ts'
import { pipeline, type Command } from './mod-kit/hooks/commands.ts'
import { ghArgs, mergeHelperArgs } from './mod-kit/hooks/gh.ts'
import { commandWrites, pipelineIn } from './mod-kit/hooks/writes.ts'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { DEADLINE_MS, DECIDE_TOOL } from '../hooks/rules.ts'
import { READ_SCRIPT, ROTATE_SCRIPT } from '../hooks/prline.ts'

// The world the area check's tests run in, shared by every test file: mod-kit, the session
// registry and scope modes standing in, and the commands the mod runs answered here.

// mod-kit and the session registry, standing in. A plugin in a test runs apart from this file, so
// each member asks the world through a process the world answers (`__modkit`, `__sessions`).
export const deps: { name: string; register: Register } = {
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
          screen: async () => null, blocked: async (input: unknown) => ask('blocked', input), card: nope('card'), commands: nope('commands'), git: nope('git'), gh: async (input: unknown) => ask('gh', input),
          writes: async (input: unknown) => ask('writes', input), pipeline: async (input: unknown) => ask('pipeline', input), workingTree: nope('workingTree'), ghRepo: nope('ghRepo'), linkRepo: nope('linkRepo'),
          mergeHelper: async (command: unknown) => ask('mergeHelper', command), bandRow: nope('bandRow'), clearBandRow: nope('clearBandRow'), pane: nope('pane'), clearPane: nope('clearPane'),
          press: async () => ({ isAnswered: false }), clickable: async () => true, isDans: nope('isDans'), typedAnswer: async (input: unknown) => ask('typedAnswer', input),
          pythonText: nope('pythonText'), login: nope('login'), account: nope('account'), hold: nope('hold'), release: nope('release'),
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
export const scope: { name: string; register: Register } = {
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
export const KIT = { plugins: [deps, scope] }

export const HOME = '/Users/dan'
export const DIR = `${HOME}/.claude-area-check`
export const LOG = `${DIR}/log.jsonl`
export const ERRORS = `${HOME}/.claude-area-check/errors.jsonl`
export const T0 = Date.UTC(2026, 9, 22, 15, 0, 0)
export const APP = '/w/app'
export const SHA = 'a1b2c3'

// 90 days of the app's default branch, newest first: big.ts grew fast; slack.ts barely.
export const NUMSTAT = ['\x1efix: stop the crash (#3)', '900\t100\tsrc/big.ts', '\x1eSmall change', '10\t2\tsrc/lib/slack.ts'].join('\n')
export const TRACKED = ['src/big.ts', 'src/lib/slack.ts', 'src/pay/stripe.ts', 'docs/x.md', 'README.md'].join('\n')
export type Issue = { number: number; title: string; body: string; labels: { name: string }[] }
export const ISSUES: Issue[] = [
  { number: 41, title: 'Split the slack client', body: 'src/lib/slack.ts:10-80 does three jobs', labels: [{ name: 'tech-debt' }, { name: 'priority-p2' }] },
  { number: 42, title: 'An idea', body: 'stripe.ts could be faster', labels: [{ name: 'enhancement' }] },
]

export type Run = { exitCode: number; stdout: string; stderr: string }
export type Init = { branch?: string; goal?: string; issues?: Issue[] }
export type Engine = Parameters<typeof standInCore>[0]
export const world = ($: unknown, on: On, init: Init = {}) => {
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
  const toolDescriptions: Record<string, string> = {}
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
    // mod-kit's shell reader failing (#2142), and the default branch's 90 days in place of NUMSTAT.
    writesThrows?: boolean
    // mod-kit's pipeline reader failing, and the session's folder failing to be read (#2173): the one
    // inside the pull request check, the other before it, so the hook itself fails.
    pipelineThrows?: boolean
    cwdThrows?: boolean
    numstat?: string
    sha: string
    goal: string | null
    // The log as the read finds it (#1510): missing, unreadable, or its lines beside those the mod wrote.
    log?: 'missing' | 'unreadable'
    // The engine cut the read of the log short (process.run's isStdoutTruncated).
    logTruncated?: boolean
    seeded: string[]
    // The rotated files (#2143), by their names in rotated/: <stamp>.decisions.jsonl and <stamp>.rotating.
    rotated: Record<string, string[]>
    // One of them the read cannot open, by its name.
    rotatedUnreadable?: string
    // The rotation failing, with these words on stderr.
    rotateFails?: string
    // The merge base each ref has with origin/main; a ref absent here cannot be read.
    bases: Record<string, string>
    // GitHub's answer to gh pr view, by its words after `gh pr view`.
    prView: (args: string[]) => Run
    unreadableFiles: string[]
    // The folders on the disk (#2321), which fs.exists finds and fs.stat calls `dir`; a path in
    // statFails exists but its stat is refused. `tracked` stands in for TRACKED, the default branch's files.
    folders: string[]
    statFails: string[]
    // A link on the disk and the path it leads to (#2407 lessons review): fs.stat answers what it leads
    // to, and with resolve its realPath there. A path in existsFails throws when asked whether it exists.
    links: Record<string, string>
    existsFails: string[]
    tracked?: string
  } = {
    folders: [APP, `${APP}/src`, `${APP}/src/lib`, `${APP}/src/pay`, `${APP}/docs`, `${APP}/lib`],
    statFails: [],
    links: {},
    existsFails: [],
    seeded: [],
    rotated: {},
    bases: { HEAD: 'mb123' },
    prView: () => ({ exitCode: 1, stdout: '', stderr: 'no pull requests found' }),
    unreadableFiles: [],
    issues: init.issues ?? ISSUES,
    gh: () => ({ exitCode: 0, stdout: JSON.stringify(ctl.issues), stderr: '' }),
    sha: SHA,
    goal: init.goal ?? null,
  }
  const clock = mock.clock(on, { now: T0 })
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : undefined }) as never)
  on('session.id', () => ({ value: 's1' }) as never)
  on('session.cwd', () => {
    if (ctl.cwdThrows) throw new Error('the session folder could not be read')
    return { value: APP } as never
  })
  on('session.repo', () => ({ value: { root: APP, remote: 'git@github.com:dan/app.git' } }) as never)
  on('fs.exists', ($, e) => {
    if (ctl.existsFails.includes(e.path)) return { deny: `EACCES: permission denied, access '${e.path}'` } as never
    return { value: files[e.path] !== undefined || ctl.folders.includes(e.path) || ctl.statFails.includes(e.path) || ctl.links[e.path] !== undefined } as never
  })
  // What a path leads to, as $.fs.stat answers: `dir` or `file`, rejecting ENOENT for a missing path;
  // with resolve, realPath, where it lands, a link's target or the path itself.
  on('fs.stat', ($, e) => {
    const { path: asked, resolve } = e as unknown as { path: string; resolve?: boolean }
    const p = ctl.links[asked] ?? asked
    const isLink = ctl.links[asked] !== undefined
    const real = resolve ? { realPath: p } : {}
    if (ctl.statFails.includes(p)) return { deny: `EACCES: permission denied, stat '${p}'` } as never
    if (ctl.folders.includes(p)) return { value: { kind: 'dir', size: 0, mtimeMs: 0, isLink, ...real } } as never
    if (files[p] !== undefined) return { value: { kind: 'file', size: 1, mtimeMs: 0, isLink, ...real } } as never
    return { deny: `ENOENT: no such file or directory, stat '${p}'` } as never
  })
  on('fs.read', ($, e) => {
    if (ctl.unreadableFiles.includes(e.path)) return { deny: `EACCES: permission denied, open '${e.path}'` } as never
    const t = files[e.path]
    if (t === undefined) return { deny: `ENOENT: no such file or directory, open '${e.path}'` } as never
    return { value: t } as never
  })
  // Claude Code refuses a store key over 256 characters on get, set and delete, and never on keys
  // (#2246, read from the 2.1.318 binary: `e.key.length>256` throws "the key is N characters, over
  // the 256 limit"), so the world refuses one too, or a key too long to keep passes every test here.
  const tooLong = (key: string) => (key.length > 256 ? ({ deny: `$.store: the key is ${key.length} characters, over the 256 limit` } as never) : undefined)
  on('store.get', ($, e) => tooLong(e.key) ?? ({ value: store[e.key] } as never))
  on('store.set', ($, e) => {
    const refused = tooLong(e.key)
    if (refused) return refused
    store[e.key] = e.value
    return { value: undefined } as never
  })
  on('ui.log', ($, e) => {
    logs.push(String((e as { text?: string }).text ?? ''))
    return { value: undefined } as never
  })
  on('store.keys', () => ({ value: Object.keys(store) }) as never)
  on('store.delete', ($, e) => {
    const refused = tooLong(e.key)
    if (refused) return refused
    delete store[e.key]
    return { value: undefined } as never
  })
  on('tool.register', ($, e) => {
    tools.push(e.name)
    toolDescriptions[e.name] = String((e as { description?: string }).description ?? '')
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
    const x = e as { file_path?: string; command?: string }
    passed.push(`${e.tool} ${String(x.file_path ?? x.command ?? '')}`)
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
      // mod-kit's command readers, standing in: their byte for byte copies, as is it live keeps.
      if (argv[1] === 'pipeline' && ctl.pipelineThrows) return answer({ exitCode: 1, stdout: '', stderr: 'the pipeline could not be read' })
      if (argv[1] === 'gh' || argv[1] === 'mergeHelper' || argv[1] === 'pipeline') {
        const read = argv[1] === 'gh' ? ghArgs(input.words) : argv[1] === 'mergeHelper' ? mergeHelperArgs(input as Command) : input.cwd !== undefined ? pipelineIn(input.command, input.cwd, input.home ?? '') : pipeline(input.command)
        return answer(ok(read === undefined ? 'null' : JSON.stringify(read)))
      }
      // What a Bash call writes (#2142), from the same copy of mod-kit's reader.
      if (argv[1] === 'writes') {
        if (ctl.writesThrows) return answer({ exitCode: 1, stdout: '', stderr: 'the command could not be read' })
        return answer(ok(JSON.stringify(commandWrites(input.command, input.cwd, input.home ?? ''))))
      }
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
    // The read of one branch's decisions (#2143): the decision files, any .rotating file, then the
    // log, filtered as READ_SCRIPT's awk filters them (the repo suite proves the real script).
    if (argv[0] === '/bin/sh' && argv[2] === READ_SCRIPT && argv[4] === DIR) {
      const [repo, branch, m1, m2] = [argv[5] as string, argv[6] as string, argv[7] as string, argv[8] as string]
      const names = Object.keys(ctl.rotated)
      const rotated = [...names.filter(n => n.endsWith('.decisions.jsonl')).sort(), ...names.filter(n => n.endsWith('.rotating')).sort()]
      if (ctl.log === 'missing' && !rotated.length) return answer({ exitCode: 2, stdout: '', stderr: `${DIR}/log.jsonl: No such file or directory` })
      if (ctl.rotatedUnreadable) return answer({ exitCode: 2, stdout: '', stderr: `${DIR}/rotated/${ctl.rotatedUnreadable}: Permission denied` })
      if (ctl.log === 'unreadable') return answer({ exitCode: 2, stdout: '', stderr: `${LOG}: Permission denied` })
      const lines = [...rotated.flatMap(n => ctl.rotated[n] as string[]), ...(ctl.log === 'missing' ? [] : [...(appended[LOG] ?? '').split('\n'), ...ctl.seeded])]
      const out: string[] = []
      let n = 0
      for (const l of lines) {
        if (!l || !(l.includes(m1) || l.includes(m2))) continue
        if (!l.endsWith('}')) {
          out.push(`cut ${l}`)
          continue
        }
        if (!l.toLowerCase().includes(repo)) continue
        n++
        if (branch !== '' && l.includes(branch)) out.push(`line ${l}`)
      }
      const text = [...out, `repo ${n}`].join('\n') + '\n'
      if (ctl.logTruncated) return { value: { exitCode: 0, stdout: text.slice(0, 100), stderr: '', isStdoutTruncated: true, isStderrTruncated: false } } as never
      return answer(ok(text))
    }
    // The rotation at session start (#2143): the log moved whole into rotated/<stamp>.rotating once
    // over argv[6] bytes. Settling is not faked; tests/test-area-check-log-rotation.sh proves it.
    if (argv[0] === '/bin/sh' && argv[2] === ROTATE_SCRIPT && argv[4] === DIR) {
      if (ctl.rotateFails) return answer({ exitCode: 1, stdout: '', stderr: ctl.rotateFails })
      const lines = [...(appended[LOG] ?? '').split('\n').filter(Boolean), ...ctl.seeded]
      const utf8 = new TextEncoder()
      const bytes = lines.reduce((s, l) => s + utf8.encode(l).length + 1, 0)
      if (bytes > Number(argv[6])) {
        ctl.rotated[`${argv[5]}.rotating`] = lines
        appended[LOG] = ''
        ctl.seeded.splice(0)
      }
      return answer(ok(''))
    }
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
      if (argv[3] === 'merge-base' && argv[5] === 'origin/main') {
        const base = ctl.bases[argv[4] as string]
        return answer(base ? ok(`${base}\n`) : { exitCode: 128, stdout: '', stderr: `fatal: Not a valid object name ${argv[4]}` })
      }
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
        return answer(ok(ctl.numstat ?? NUMSTAT))
      }
      if (sub === 'ls-tree -r --name-only origin/main') return answer(ok((ctl.tracked ?? TRACKED) + '\n'))
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
    if (argv[0] === 'gh' && argv[1] === 'pr' && argv[2] === 'view') return answer(ctl.prView(argv.slice(3)))
    throw new Error(`unexpected run: ${line}`)
  })
  const records = (file = LOG) => (appended[file] ?? '').split('\n').filter(Boolean).map(l => JSON.parse(l) as Record<string, unknown>)
  const judged = () => records().filter(r => r.kind === 'judged')
  return { clock, ctl, ran, logs, passed, timeouts, store, files, records, judged, cards, asked, notes, holds, tools, toolDescriptions }
}

export type T$ = { tool: { call: (e: never) => Promise<unknown> }; session: { start: (e: never) => Promise<unknown> }; prompt: { submit: (e: never) => Promise<unknown> } }
export type R = { result?: unknown; deny?: string; isError?: boolean; text?: string; context?: string[] }
export const edit = async ($: T$, w: ReturnType<typeof world>, path: string, extra: object = {}, id = 'c1') => {
  const r = await $.tool.call({ tool: 'Edit', tool_use_id: id, file_path: path, old_string: 'a', new_string: 'b', ...extra } as never)
  await w.clock.settle()
  return r as R
}
export const ghLists = (w: ReturnType<typeof world>) => w.ran.filter(l => l.startsWith('gh issue list')).length
// The area check's own words, in whichever form Claude Code wraps a refusal (#1484).
export const refusal = (r: unknown) => reasonOf(r, 'area-check')
export const decide = async ($: T$, input: object, extra: object = {}) => (await $.tool.call({ tool: DECIDE_TOOL, tool_use_id: 'd1', ...input, ...extra } as never)) as R
export const askDan = async ($: T$, call: string, extra: object = {}) =>
  (await $.tool.call({
    tool: 'AskUserQuestion',
    tool_use_id: 'q1',
    questions: [{ question: 'Restructure it?', header: 'Area', options: [{ label: 'Yes', description: '' }, { label: 'No', description: '' }], multiSelect: false }],
    metadata: { source: `area-check:${call}` },
    ...extra,
  } as never)) as R
export const said = (r: R) => [...(r.context ?? []), typeof r.result === 'string' ? r.result : '', r.text ?? ''].join(' ')
export const REASON = 'This only renames a local variable inside one function.'
export const SLACK = `${APP}/src/lib/slack.ts`
// The question about that file under its fixed length key (#2246): the SHA-256 of "dan/app\nsrc/lib/slack.ts",
// measured with shasum rather than with the code under test, and the key it was kept under before.
export const QKEY = 'question:41ea88a6f2f85188ac883b6c67f9c59a2728aeddb0cdeb7020eeb21976ac7aee'
export const OLD_QKEY = 'question:dan/app\nsrc/lib/slack.ts'

// A Bash call as Claude sends it, its result settled.
export const bash = async ($: T$, w: ReturnType<typeof world>, command: string, extra: object = {}, id = 'b1') => {
  const r = await $.tool.call({ tool: 'Bash', tool_use_id: id, command, ...extra } as never)
  await w.clock.settle()
  return r as R
}
// A decision as the log keeps it (#1510): version 3, with the branch and merge base it was taken on
// (version 2 records carry neither, and the pull request line leaves them out).
export const decidedLine = (d: { path: string; decision: string; reason?: string; issue?: number; by?: 'dan'; branch?: string; mergeBase?: string | null; repo?: string }) =>
  JSON.stringify({
    v: 3, kind: 'decided', at: '2026-10-22T15:00:00.000Z', session: 's0', agent: null,
    repo: d.repo ?? 'dan/app', branch: d.branch ?? '12-feature', mergeBase: d.mergeBase === undefined ? 'mb123' : d.mergeBase,
    path: d.path, call: 'c0', decision: d.decision,
    ...(d.reason !== undefined ? { reason: d.reason } : {}), ...(d.issue !== undefined ? { issue: d.issue } : {}), ...(d.by ? { by: d.by } : {}),
  })
