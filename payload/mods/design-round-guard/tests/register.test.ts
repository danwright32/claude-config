import { expect, mock, test, type Engine } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { CONTRACT, HEADER, NOT_LOOK, callKey, callText, SETTLED_NO, SETTLED_QUESTION, SETTLED_SOURCE, SETTLED_YES, SKIP_NO, SKIP_QUESTION, SKIP_YES } from '../hooks/rules.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { pipeline } from './mod-kit/hooks/commands.ts'
import { readBranch, type Run } from './mod-kit/hooks/branch.ts'
import { githubRepo, repoName } from './mod-kit/hooks/repo.ts'
import { type TypedAnswer, typedAnswerText, typedToast } from './mod-kit/hooks/typed.ts'

// The design round guard (claude-config#978) in a session. Dan, 2026-10-08: "claude should never
// design something without my input. If we can make this something that can't be ignored rather than
// just a memory, that would be great". Every edit that changes how a screen looks waits until Dan has
// settled a design round for the issue (his Settled to "Is this design settled?") or answered Skip
// them to "Skip design rounds for this issue?". Only his own answer in Claude Code's dialog counts.

// mod-kit, standing in: a mod cannot import another mod's files. What a command writes is read by
// mod-kit's own reader, and where a checkout stands by its branch reader (#978) and the project's
// name by its repo reader (#951), each a byte for byte copy under tests/mod-kit that
// tools/check-mod-shared-parts.sh holds to mod-kit's, asked through the world (`__modkit`). The checkouts: /w/slate (the project's
// main working tree), /w/slate-wt (a linked worktree of it, where a subagent works), and /w/other.
// A folder under /w/locked is one the disk cannot answer for.
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
      const modkit = {
        writes: async (input: { command: string; cwd: string; home: string }) => ask('writes', input),
        pipeline: async (input: { command: string }) => ask('pipeline', input),
        workingTree: async ({ path }: { path: string }) => {
          if (path.startsWith('/w/locked/')) throw new Error('EACCES: /w/locked')
          for (const root of ['/w/slate-wt', '/w/slate', '/w/other', '/w/tests/shop']) if (path === root || path.startsWith(root + '/')) return root
          return null
        },
        branch: async (input: { path: string }) => ask('branch', input),
        repo: async (input: { root?: string | null; remote: string | null }) => ask('repo', input),
        blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
        // The kit's other members, which these tests never reach: each refuses by name if one ever is.
        card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
        commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
        git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
        gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
        ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
        linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
        bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
        clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
        pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
        clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
        screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
        press: async () => ({ isAnswered: false }),
        clickable: async () => true,
        isDans: async () => { throw new Error("mod-kit's isDans is not stood in by these tests") },
        // #1145: a typed answer, said with the copy. One typed as BREAKS stands for a mod-kit loaded
        // before it had the member (a reload can leave one, standing rule 5).
        typedAnswer: async (input: { guard: string; typed: string; still: string; again: string }) => {
          if (input.typed === 'BREAKS') throw new TypeError('$.modkit.typedAnswer is not a function')
          const said = (await ask('typedAnswer', input)) as { toast: string; text: string }
          await built.ui.toast(said.toast)
          return said.text
        },
      }
      return { ...built, modkit }
    })
  },
}
// A stand-in for Claude Code's built-in security default (#875), loaded in every test so none can
// pass on a hook that never runs: it sends every classic hook event past the tier mods load in.
const secDefault: { name: string; tier: 'prepend'; register: Register } = {
  name: 'sec-default-stand-in',
  tier: 'prepend',
  register: on => {
    on('classic.*', ($, e, next) => next.to(e, 'append'))
  },
}
const withKit = { plugins: [secDefault, modKit] }

const HOME = '/Users/dan'
// The moment every test's clock starts at.
const T0 = Date.UTC(2026, 9, 9, 15, 0, 0)
const STORE = `${HOME}/.claude/plugins/store/design-round-guard_inline-ab12cd34ef56.json`

type Dialog = { answer?: string; afk?: boolean }
type Asked = { questions: { question: string; header: string; options: { label: string; description?: string }[]; multiSelect: boolean }[]; metadata?: Record<string, unknown> }
type Init = { cwd?: string; files?: Record<string, string>; agents?: string[] }
const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never

// The Mac and Claude Code beneath the mod: each checkout's branch (a test may change it, or make it
// unreadable), git's answers, the disk, the mod's store, Claude Code's own question dialog (answered
// as `dialog` says), every call that ran, every card drawn and every git command asked.
const world = (engine: Engine, on: On, init: Init = {}) => {
  const files: Record<string, string> = { ...(init.files ?? {}) }
  const branches: Record<string, string> = { '/w/slate': '978-design-round-guard', '/w/slate-wt': '978-design-round-guard', '/w/other': '55-other', '/w/tests/shop': '77-shop' }
  const store: Record<string, unknown> = {}
  const ctl: { storeGetFails: boolean; storeSetFails: boolean; settingsRefuse: boolean; storeSetFailKey?: string; hold?: Promise<void>; reached?: () => void } = { storeGetFails: false, storeSetFails: false, settingsRefuse: false }
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const asked: Asked[] = []
  const dialog: Dialog = {}
  const cards: Record<string, unknown>[] = []
  const gitRuns: string[] = []
  const reads: string[] = []
  const storeGets: string[] = []
  const toasts: string[] = []
  const at ={ cwd: init.cwd ?? '/w/slate', session: 's1' }
  const clock = mock.clock(on, { now: T0 })
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : undefined }) as never)
  on('session.cwd', () => ({ value: at.cwd }) as never)
  on('session.id', () => ({ value: at.session }) as never)
  on('agent.list', () => ({ value: (init.agents ?? []).map(id => ({ id, description: 'a task', agentType: 'general-purpose' })) }) as never)
  // git, as mod-kit's branch reader asks it in a checkout.
  const git: Run = async argv => {
    if (argv[0] !== 'git' || argv[1] !== '-C') throw new Error(`unexpected command: ${argv.join(' ')}`)
    gitRuns.push(argv.join(' '))
    const tree = String(argv[2])
    const sub = argv.slice(3).join(' ')
    const branch = branches[tree]
    if (sub === 'branch --show-current') {
      if (branch === undefined || branch === 'UNREADABLE') return { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository' }
      return { exitCode: 0, stdout: `${branch}\n`, stderr: '' }
    }
    if (sub === 'worktree list --porcelain') return { exitCode: 0, stdout: `worktree ${tree === '/w/slate-wt' ? '/w/slate' : tree}\nHEAD abc\nbranch refs/heads/main\n\n`, stderr: '' }
    if (sub === 'symbolic-ref --short refs/remotes/origin/HEAD') return { exitCode: 0, stdout: 'origin/main\n', stderr: '' }
    throw new Error(`unexpected git: ${argv.join(' ')}`)
  }
  on('process.run', async ($, e) => {
    const [cmd, ...args] = e.argv.map(String)
    if (cmd === '__modkit' && args[0] === 'writes') {
      const input = JSON.parse(String(args[1])) as { command: string; cwd: string; home: string }
      return ok(JSON.stringify(commandWrites(input.command, input.cwd, input.home)))
    }
    if (cmd === '__modkit' && args[0] === 'pipeline') return ok(JSON.stringify(pipeline(JSON.parse(String(args[1])).command)))
    // mod-kit's typed answer wording (#1145), read here with its copy.
    if (cmd === '__modkit' && args[0] === 'typedAnswer') {
      const input = JSON.parse(String(args[1])) as TypedAnswer
      return ok(JSON.stringify({ toast: typedToast(input.guard), text: typedAnswerText(input) }))
    }
    // mod-kit's branch reader, read here with its copy, over the checkouts the stand-in's walk finds.
    if (cmd === '__modkit' && args[0] === 'branch') {
      const { path } = JSON.parse(String(args[1])) as { path: string }
      const root = ['/w/slate-wt', '/w/slate', '/w/other', '/w/tests/shop'].find(r => path === r || path.startsWith(r + '/'))
      return ok(JSON.stringify(root === undefined ? null : await readBranch(root, git)))
    }
    if (cmd === '__modkit' && args[0] === 'repo') {
      const input = JSON.parse(String(args[1])) as { root?: string | null; remote: string | null }
      return ok(JSON.stringify({ github: githubRepo(input.remote), name: repoName(input) }))
    }
    throw new Error(`unexpected command: ${e.argv.join(' ')}`)
  })
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }) as never)
  on('fs.read', ($, e) => {
    reads.push(e.path)
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    // A file that exists and cannot be read.
    if (t === 'UNREADABLE') throw new Error(`EACCES: ${e.path}`)
    return { value: t } as never
  })
  on('store.get', ($, e) => {
    storeGets.push(e.key)
    if (ctl.storeGetFails) throw new Error('the store could not be read')
    return { value: store[e.key] } as never
  })
  on('store.set', ($, e) => {
    if (ctl.storeSetFails || (ctl.storeSetFailKey !== undefined && e.key.includes(ctl.storeSetFailKey))) throw new Error('disk full')
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
  // Claude Code's settings hooks and permission check, beneath every mod's tool.check hook: they
  // allow every call, unless the test has them refuse one (the payload write gate, say).
  on('tool.check', () => (ctl.settingsRefuse ? { decision: 'deny', reason: 'Blocked by a settings hook.' } : { decision: 'allow' }) as never)
  // Core, standing in: the engine decides whether the call may run (the tool.check chain), then
  // runs it, or shows Dan the dialog and hands back his answer as the dialog does.
  on('tool.call', async ($, e) => {
    const { tool, tool_use_id: id, agentId: _a, consent: _c, ...input } = e as unknown as Record<string, unknown>
    const verdict = await engine.tool.check({ tool: String(tool), input, ...(id === undefined ? {} : { tool_use_id: String(id) }) } as never)
    if (verdict.decision === 'deny') return { isError: true, result: verdict.reason, text: verdict.reason ?? 'denied' } as never
    if (tool === 'AskUserQuestion') {
      const a = input as unknown as Asked
      asked.push(a)
      const q = a.questions[0]?.question ?? ''
      const result = { questions: a.questions, answers: dialog.answer === undefined ? {} : { [q]: dialog.answer }, ...(dialog.afk ? { afkTimeoutMs: 60_000 } : {}) }
      return { result, text: `User has answered: ${dialog.answer ?? ''}` } as never
    }
    // A call the test holds open mid run, so another can arrive while it is still under way.
    if (ctl.hold && String(input.file_path ?? '').includes('HOLD')) {
      ctl.reached?.()
      await ctl.hold
    }
    ran.push({ tool: String(tool), input })
    return { result: 'written', text: 'written' } as never
  })
  return { files, branches, store, ctl, ran, asked, dialog, cards, gitRuns, at, reads, clock, storeGets, toasts }
}
type W = ReturnType<typeof world>

type Caller = { tool: { call: (e: never) => Promise<unknown> } }
type Result = { deny?: string; text?: string; isError?: boolean; context?: readonly string[] }
let calls = 0
const call = async ($: Caller, input: Record<string, unknown>) => (await $.tool.call({ tool_use_id: `t${++calls}`, ...input } as never)) as Result
const refusalOf = (r: Result) => r.deny ?? (r.isError ? r.text : undefined) ?? ''
const contextOf = (r: Result) => (r.context ?? []).join('\n')
const idIn = (refusal: string) => /design-round-guard:(t\d+)/.exec(refusal)?.[1]
const PAGE = { tool: 'Write', file_path: '/w/slate/app/page.tsx', content: 'export default function Page() { return <main className="p-4" /> }\n' }
const STYLE = { tool: 'Edit', file_path: '/w/slate/app/globals.css', old_string: 'a{}', new_string: 'a{color:red}' }
const ROUTE = { tool: 'Write', file_path: '/w/slate/app/api/route.ts', content: 'export const GET = () => new Response("ok")\n' }
const BOTH_WAYS = (why: string) => {
  expect(why).toContain('/design-rounds')
  expect(why).toContain(SKIP_QUESTION)
}

// What the session says changes on screen (#1138), in the plain words the question leads with.
const SHOWS = 'The heading on the home page gets more space above it.'
// Claude asking Dan the skip question as the refusal told it to, and Dan answering in the dialog.
// `metadata` adds to (or, set undefined, removes from) what the question carries.
const askSkip = async ($: Caller, w: W, refusal: string, answer: string | undefined, extra: Record<string, unknown> = {}, metadata: Record<string, unknown> = {}) => {
  const id = idIn(refusal)
  if (!id) throw new Error(`no refused call named in: ${refusal}`)
  w.dialog.answer = answer
  const meta: Record<string, unknown> = { source: `design-round-guard:${id}`, onScreen: SHOWS, ...metadata }
  for (const k of Object.keys(meta)) if (meta[k] === undefined) delete meta[k]
  return call($, {
    tool: 'AskUserQuestion',
    questions: [{ question: 'Skip design rounds for this issue?', header: 'x', options: [{ label: 'Yes', description: 'y' }, { label: 'No', description: 'n' }], multiSelect: false }],
    metadata: meta,
    ...extra,
  })
}
// The design rounds skill's closing question, and Dan answering it.
const askSettled = async ($: Caller, w: W, answer: string | undefined, extra: Record<string, unknown> = {}, metadata: Record<string, unknown> = {}) => {
  w.dialog.answer = answer
  return call($, {
    tool: 'AskUserQuestion',
    questions: [{ question: 'Is this design settled?', header: 'x', options: [{ label: 'Yes', description: 'y' }, { label: 'No', description: 'n' }], multiSelect: false }],
    metadata: { source: SETTLED_SOURCE, ...metadata },
    ...extra,
  })
}

test('a file that does not change the look passes untouched, with nothing asked of git or the store', withKit, async ($, on) => {
  const w = world($, on)
  const r = await call($, ROUTE)
  expect(refusalOf(r)).toBe('')
  expect(w.ran.map(x => x.input.file_path)).toEqual(['/w/slate/app/api/route.ts'])
  expect(w.gitRuns).toEqual([])
  expect(w.cards).toEqual([])
  // A shell write to a logic file passes too.
  const b = await call($, { tool: 'Bash', command: "printf 'x\\n' >> /w/slate/lib/date.ts" })
  expect(refusalOf(b)).toBe('')
  expect(w.ran.length).toBe(2)
  // Lessons review of #1010: Dan's Not a look change is looked up only for a call that would be held.
  expect(w.storeGets).toEqual([])
})

// Dan, 2026-10-08: "On, but let tests through".
test('a test of a screen passes with no answer recorded, while the screen beside it is still held', withKit, async ($, on) => {
  const w = world($, on)
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/slate/app/page.test.tsx', content: 'test("renders", () => {})\n' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Bash', command: "echo 'x' > /w/slate/app/__tests__/Header.tsx" }))).toBe('')
  expect(refusalOf(await call($, PAGE))).toContain(SKIP_QUESTION)
  // A name only holding "test" is no test.
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/slate/app/latest.tsx', content: 'x' }))).toContain(SKIP_QUESTION)
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/slate/styles/contest.css', content: 'a{}' }))).toContain(SKIP_QUESTION)
  expect(w.ran.map(x => String(x.input.file_path ?? x.input.command))).toEqual(['/w/slate/app/page.test.tsx', "echo 'x' > /w/slate/app/__tests__/Header.tsx"])
  expect(Object.keys(w.store)).toEqual([])
})

// Lessons review of #991: the test markers were read over the whole path, so a project checked out
// under a folder named tests had every screen in it let through.
test('a test folder counts only inside the project: a project checked out under one is still held', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, { tool: 'Write', file_path: '/w/tests/shop/app/page.tsx', content: 'x' }))
  expect(why).toContain('issue #77 in shop')
  expect(refusalOf(await call($, { tool: 'Bash', command: "echo 'a{}' > /w/tests/shop/app/site.css" }))).toContain('issue #77 in shop')
  // Its own tests still pass.
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/tests/shop/app/__tests__/page.tsx', content: 'x' }))).toBe('')
  expect(w.ran.length).toBe(1)
})

// Lessons review of #991: only Write, Edit and Bash were judged, so MultiEdit, NotebookEdit or any
// tool added later wrote a screen unasked. Every tool carrying a file path is judged, a tool known
// only to read its path excepted, so a writing tool nobody listed is held by default.
test('every tool that carries a file path is judged: MultiEdit, NotebookEdit and an unknown tool are held, a reading tool is not', withKit, async ($, on) => {
  const w = world($, on, { agents: ['agent-a1'] })
  const multi = { tool: 'MultiEdit', file_path: '/w/slate/app/page.tsx', edits: [{ old_string: 'p-4', new_string: 'p-6' }] }
  expect(refusalOf(await call($, multi))).toContain(SKIP_QUESTION)
  expect(refusalOf(await call($, { ...multi, agentId: 'agent-a1' }))).toContain('Stop')
  expect(refusalOf(await call($, { tool: 'FutureWrite', path: '/w/slate/app/site.css', text: 'a{}' }))).toContain(SKIP_QUESTION)
  expect(refusalOf(await call($, { tool: 'BulkWrite', file_paths: ['/w/slate/README.md', '/w/slate/app/Header.tsx'] }))).toContain('app/Header.tsx')
  // A notebook is no screen, and a tool known only to read its path is not judged.
  expect(refusalOf(await call($, { tool: 'NotebookEdit', notebook_path: '/w/slate/analysis.ipynb', new_source: 'x' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Read', file_path: '/w/slate/app/page.tsx' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Artifact', file_path: '/w/slate/index.html' }))).toBe('')
  expect(w.ran.map(x => x.tool)).toEqual(['NotebookEdit', 'Read', 'Artifact'])
})

// Lessons review of #991: a subagent's call carrying an empty id was marked as judged under the empty id,
// so a main session call arriving with an empty id while it ran skipped the judgement.
test("a subagent's call with an empty id marks nothing, so a call arriving with an empty id meanwhile is still judged", withKit, async ($, on) => {
  const w = world($, on, { agents: ['agent-a1'] })
  let release = () => {}
  w.ctl.hold = new Promise<void>(r => (release = r))
  const reached = new Promise<void>(r => (w.ctl.reached = r))
  // The engine gives a call it is handed with no id one of its own, so an empty id is the shape that reaches the hook.
  const running = $.tool.call({ tool_use_id: '', tool: 'Write', file_path: '/w/slate/lib/HOLD.ts', content: 'x', agentId: 'agent-a1' } as never)
  // The held call has passed the guard and reached the tool before the next one arrives.
  await reached
  const meanwhile = (await $.tool.call({ tool_use_id: '', ...PAGE } as never)) as Result
  release()
  await running
  expect(refusalOf(meanwhile)).toContain('app/page.tsx')
  expect(w.ran.map(x => x.input.file_path)).toEqual(['/w/slate/lib/HOLD.ts'])
})

// Lessons review of #991: a Swift test file was read for SwiftUI before it was known to be a test,
// so one that could not be read was held, though tests pass.
test('a Swift test file passes without being read, even one the disk cannot read', withKit, async ($, on) => {
  const w = world($, on, { files: { '/w/slate/AppTests/RowTests.swift': 'UNREADABLE', '/w/slate/Sources/Row.swift': 'UNREADABLE' } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: '/w/slate/AppTests/RowTests.swift', old_string: 'a', new_string: 'b' }))).toBe('')
  expect(w.reads).toEqual([])
  // A Swift file that is no test and cannot be read is still held.
  expect(refusalOf(await call($, { tool: 'Edit', file_path: '/w/slate/Sources/Row.swift', old_string: 'a', new_string: 'b' }))).toContain(SKIP_QUESTION)
  expect(w.ran.length).toBe(1)
})

// Lessons review of #991: a refused call with an empty id was kept waiting under that empty id and
// told to report "design-round-guard:" with nothing after it.
test('a refused call with an empty id waits under no id and is told the two ways on without one', withKit, async ($, on) => {
  const w = world($, on, { agents: ['agent-a1'] })
  for (const extra of [{}, { agentId: 'agent-a1' }]) {
    const why = refusalOf((await $.tool.call({ tool_use_id: '', ...PAGE, ...extra } as never)) as Result)
    expect(why).toContain('app/page.tsx')
    expect(why).toContain(SKIP_QUESTION)
    expect(/design-round-guard:(?!\w)/.test(why)).toBe(false)
  }
  expect(refusalOf(await call($, { tool: 'AskUserQuestion', questions: [{ question: 'Skip design rounds for this issue?', header: 'x', options: [], multiSelect: false }], metadata: { source: 'design-round-guard:' } }))).toContain('No look changing edit is waiting')
  expect(w.asked).toEqual([])
  expect(w.cards).toEqual([])
})

test('a look changing Write is refused, naming the file and both ways on, with the grey card for Dan', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, PAGE))
  expect(w.ran).toEqual([])
  expect(why).toContain('app/page.tsx')
  expect(why).toContain('issue #978 in slate')
  BOTH_WAYS(why)
  expect(idIn(why)).toBe(`t${calls}`)
  expect(w.cards.length).toBe(1)
  expect(JSON.stringify(w.cards[0])).toContain('Design round guard')
  expect(JSON.stringify(w.cards[0])).toContain('app/page.tsx')
  // #1145: the card Dan sees leads in plain words, and names the file only after (Dan, 2026-10-13:
  // "I don't know what the file name means").
  const reason = String((w.cards[0] as { reason?: string }).reason)
  expect(reason.startsWith('Claude wants to make an edit that may change how something looks on screen')).toBe(true)
  expect(reason.indexOf('app/page.tsx')).toBeGreaterThan(reason.indexOf('issue #978 in slate'))
  expect(String((w.cards[0] as { safeWay?: string }).safeWay)).toContain('in plain words')
})

test('blocked, then let through once Dan answers Settled to the design rounds closing question; Not yet leaves it blocked', withKit, async ($, on) => {
  const w = world($, on)
  expect(refusalOf(await call($, PAGE))).toContain(SKIP_QUESTION)
  // Not yet: nothing recorded, still blocked.
  const notYet = await askSettled($, w, SETTLED_NO)
  expect(contextOf(notYet)).toContain('Not yet')
  expect(Object.keys(w.store)).toEqual([])
  expect(refusalOf(await call($, PAGE))).toContain(SKIP_QUESTION)
  // Settled: the guard set the question and answers Dan read, and his answer is recorded for the issue.
  const settled = await askSettled($, w, SETTLED_YES)
  const q = w.asked[1]?.questions[0]
  if (!q) throw new Error('Dan was asked no question')
  expect(q.question.startsWith(SETTLED_QUESTION)).toBe(true)
  expect(q.question).toContain('issue #978 in slate')
  expect(q.header).toBe(HEADER)
  expect(q.options.map(o => o.label)).toEqual([SETTLED_YES, SETTLED_NO])
  expect(contextOf(settled)).toContain('issue #978 in slate')
  expect(w.store['record:/w/slate|issue:978']).toMatchObject({ kind: 'settled', label: 'issue #978 in slate' })
  // The same edit goes through, and so does another look changing edit on the issue.
  expect(refusalOf(await call($, PAGE))).toBe('')
  expect(refusalOf(await call($, STYLE))).toBe('')
  expect(w.ran.map(x => x.input.file_path)).toEqual(['/w/slate/app/page.tsx', '/w/slate/app/globals.css'])
})

test("blocked, then let through for the rest of the issue by Dan's Skip them, in this session and the next", withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, PAGE))
  const answered = await askSkip($, w, why, SKIP_YES)
  const q = w.asked[0]?.questions[0]
  if (!q) throw new Error('Dan was asked no question')
  expect(q.question.startsWith(SHOWS)).toBe(true)
  expect(q.question).toContain(SKIP_QUESTION)
  expect(q.question).toContain('app/page.tsx')
  expect(q.header).toBe(HEADER)
  expect(q.options.map(o => o.label)).toEqual([SKIP_YES, SKIP_NO, NOT_LOOK])
  expect(contextOf(answered)).toContain('Send the Write call to app/page.tsx again')
  expect(w.store['record:/w/slate|issue:978']).toMatchObject({ kind: 'skipped' })
  expect(refusalOf(await call($, PAGE))).toBe('')
  expect(refusalOf(await call($, STYLE))).toBe('')
  // A new session on the same issue: the answer stands, kept in the store, not in the session.
  await ($ as unknown as { session: { end: (e: never) => Promise<unknown> } }).session.end({ sessionId: 's1', reason: 'other' } as never)
  expect(refusalOf(await call($, { ...PAGE, content: 'x' }))).toBe('')
  expect(w.ran.length).toBe(3)
})

test('a new issue goes back to yes: the next branch is refused again', withKit, async ($, on) => {
  const w = world($, on)
  await askSkip($, w, refusalOf(await call($, PAGE)), SKIP_YES)
  expect(refusalOf(await call($, PAGE))).toBe('')
  w.branches['/w/slate'] = '979-next-thing'
  const why = refusalOf(await call($, PAGE))
  expect(why).toContain('issue #979 in slate')
  BOTH_WAYS(why)
  // Another project on its own issue is its own question too.
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/other/x.css', content: 'a{}' }))).toContain('issue #55 in other')
})

test("Run /design-rounds, an answer in Dan's own words, and a dialog that closed while he was away record nothing", withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, PAGE))
  expect(contextOf(await askSkip($, w, why, SKIP_NO))).toContain('/design-rounds')
  const why2 = refusalOf(await call($, PAGE))
  expect(contextOf(await askSkip($, w, why2, 'maybe later'))).toContain('maybe later')
  const why3 = refusalOf(await call($, PAGE))
  w.dialog.afk = true
  expect(contextOf(await askSkip($, w, why3, SKIP_YES))).toContain('did not answer')
  w.dialog.afk = false
  expect(contextOf(await askSettled($, w, 'it is fine I guess'))).toContain('it is fine I guess')
  expect(Object.keys(w.store)).toEqual([])
  expect(refusalOf(await call($, PAGE))).toContain(SKIP_QUESTION)
})

// Lessons review of #991: the refused call was taken off the waiting list before Dan's answer was
// acted on, so "ask him again" after a save that failed, or an answer in his own words, was refused.
test('when Skip them cannot be recorded, or Dan answers in his own words, he can be asked again about the same call', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, PAGE))
  expect(contextOf(await askSkip($, w, why, 'hmm, which page?'))).toContain('hmm, which page?')
  w.ctl.storeSetFails = true
  expect(contextOf(await askSkip($, w, why, SKIP_YES))).toContain('could not be recorded')
  w.ctl.storeSetFails = false
  const again = await askSkip($, w, why, SKIP_YES)
  expect(refusalOf(again)).toBe('')
  expect(contextOf(again)).toContain(`Dan answered ${SKIP_YES}`)
  expect(refusalOf(await call($, PAGE))).toBe('')
  // Once it is recorded, that call waits on nobody: asking about it again is refused.
  expect(refusalOf(await askSkip($, w, why, SKIP_YES))).toContain('No look changing edit is waiting')
})

// Lessons review of #991: a refused call left waiting after Dan settled its issue could still be asked
// about, and his Skip them would overwrite the settlement with a skip.
test('a refused call whose issue Dan has since settled is not asked about, and his settlement stands', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, PAGE))
  await askSettled($, w, SETTLED_YES)
  const asked = w.asked.length
  const late = await askSkip($, w, why, SKIP_YES)
  expect(refusalOf(late)).toContain('already has his answer')
  expect(w.asked.length).toBe(asked)
  expect(w.store['record:/w/slate|issue:978']).toMatchObject({ kind: 'settled' })
  expect(refusalOf(await call($, PAGE))).toBe('')
})

// Lessons review of #991: a branch naming two issues whose second record failed was told nothing was
// recorded, though the first was.
test('when only some of the issues can be recorded, Claude is told which were and which were not', withKit, async ($, on) => {
  const w = world($, on)
  w.branches['/w/slate'] = '41-52-both'
  const why = refusalOf(await call($, PAGE))
  w.ctl.storeSetFailKey = 'issue:52'
  const answered = contextOf(await askSkip($, w, why, SKIP_YES))
  expect(answered).toContain('recorded for issue #41 in slate')
  expect(answered).toContain('not for issue #52 in slate')
  expect(Object.keys(w.store)).toEqual(['record:/w/slate|issue:41'])
  const still = refusalOf(await call($, PAGE))
  expect(still).toContain('issue #52 in slate')
  expect(still).not.toContain('issue #41')
})

test('nothing Claude writes itself records a no or a settlement', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, PAGE))
  // An answer the call already carries is never read as Dan's.
  const filled = await askSkip($, w, why, SKIP_YES, { answers: { 'Skip design rounds for this issue?': SKIP_YES } })
  expect(refusalOf(filled)).toContain('only his choice in the dialog')
  const filledSettled = await askSettled($, w, SETTLED_YES, { answers: { 'Is this design settled?': SETTLED_YES } })
  expect(refusalOf(filledSettled)).toContain('only his choice in the dialog')
  // A question naming no refused call waiting.
  const stray = await call($, { tool: 'AskUserQuestion', questions: [{ question: 'Skip design rounds for this issue?', header: 'x', options: [], multiSelect: false }], metadata: { source: 'design-round-guard:t999' } })
  expect(refusalOf(stray)).toContain('No look changing edit is waiting')
  expect(w.asked).toEqual([])
  // Writing the guard's own record, by the edit tools or the shell, is refused.
  const record = JSON.stringify({ 'record:/w/slate|issue:978': { kind: 'skipped', at: 0, label: 'x' } })
  for (const forged of [
    { tool: 'Write', file_path: STORE, content: record },
    { tool: 'Edit', file_path: STORE, old_string: '{}', new_string: record },
    { tool: 'Bash', command: `printf '%s' '${record}' > ${STORE}` },
    { tool: 'Bash', command: `python3 -c "open('${HOME}/.claude/plugins/store/design-round-guard_inline-x.json','w').write('{}')"` },
    // A program whose words cannot name the file it writes, only mention the store.
    { tool: 'Bash', command: `node -e "require('fs').writeFileSync(process.env.HOME + '/.claude/plugins/store/' + process.argv[1], '{}')" design-round-guard_inline-x.json` },
    // Lessons review of #991: a destination the reader cannot follow (a folder from a command's
    // output), whose file is the guard's record by its name.
    { tool: 'Bash', command: `D=$(dirname "$(ls ~/.claude/plugins/store/*.json | head -1)"); echo '{}' > "$D/design-round-guard_inline-x.json"` },
    // And one whose file name is not the record's, while the command names the record's folder.
    { tool: 'Bash', command: `D=$(echo ~/.claude/plugins/store); F=$(ls "$D" | grep design); echo '{}' > "$D/$F"` },
  ]) {
    const r = refusalOf(await call($, forged))
    expect(r).toContain("design round guard's own record")
  }
  expect(w.ran).toEqual([])
  expect(Object.keys(w.store)).toEqual([])
  expect(refusalOf(await call($, PAGE))).toContain(SKIP_QUESTION)
})

// Lessons review of #991: a write to a destination the reader could not follow, spelled with no look
// changing name (`> "$OUT"`), passed unchecked. When the command names a look changing file anywhere,
// such a write may be it, so it is held, as ask before saving holds lasting memory; a command naming
// none still runs, so an ordinary write to a temporary file is not refused.
test('a write the reader cannot follow is held when the command names a look changing file, and runs when it names none', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, { tool: 'Bash', command: `OUT=$(ls /w/slate/app/*.tsx | head -1); echo x > "$OUT"` }))
  expect(why).toContain('could not tell which issue or branch')
  expect(why).toContain('/w/slate/app/*.tsx')
  expect(refusalOf(await call($, { tool: 'Bash', command: `T=$(mktemp); echo x > "$T"` }))).toBe('')
  expect(w.ran.length).toBe(1)
})

test('shell writes to a look changing file are caught: redirects, sed in place, copies, removals and inline scripts', withKit, async ($, on) => {
  const w = world($, on)
  for (const command of [
    "echo 'a{color:red}' >> /w/slate/app/globals.css",
    "cd /w/slate && sed -i '' 's/p-4/p-6/' app/page.tsx",
    'cp /tmp/Header.tsx /w/slate/components/Header.tsx',
    'rm /w/slate/app/old.css',
    "cd /w/slate && python3 - <<'EOF'\nopen('app/page.tsx','w').write('x')\nEOF",
    "cat > /w/slate/tailwind.config.ts <<'EOF'\nexport default {}\nEOF",
  ]) {
    const why = refusalOf(await call($, { tool: 'Bash', command }))
    expect(why).toContain('issue #978 in slate')
    BOTH_WAYS(why)
  }
  expect(w.ran).toEqual([])
})

// #1136: what git itself changes is judged too (Dan, 2026-10-13): a checkout of a path or a restore
// puts back a look changing file, git rm and git mv take one away, and none had a round asked.
test('git checkout of a path, git restore, git rm and git mv of a look changing file are held without a settled round', withKit, async ($, on) => {
  const w = world($, on)
  for (const [command, shown] of [
    ['git checkout main -- app/globals.css', 'app/globals.css'],
    ['git restore app/page.tsx', 'app/page.tsx'],
    ['git rm components/Header.tsx', 'components/Header.tsx'],
    ['git mv app/old.css app/new.css', 'app/old.css'],
    ['git -C /w/slate checkout HEAD~1 -- tailwind.config.ts', 'tailwind.config.ts'],
  ] as [string, string][]) {
    const why = refusalOf(await call($, { tool: 'Bash', command }))
    expect([command, why.includes('issue #978 in slate'), why.includes(shown)]).toEqual([command, true, true])
  }
  expect(w.ran).toEqual([])
})

test('git putting back a file that changes no look, or a test, runs; a pathspec git matches across folders is held as one it cannot follow', withKit, async ($, on) => {
  const w = world($, on)
  expect(refusalOf(await call($, { tool: 'Bash', command: 'git checkout main -- lib/sync.ts' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Bash', command: 'git restore app/page.test.tsx' }))).toBe('')
  expect(w.ran.length).toBe(2)
  const why = refusalOf(await call($, { tool: 'Bash', command: "git checkout main -- '*.css'" }))
  expect(why).toContain('*.css')
  expect(w.ran.length).toBe(2)
})

test("a subagent is refused like the main session and told to stop and report; Dan's answer in the main session lets its retry through", withKit, async ($, on) => {
  const w = world($, on, { agents: ['agent-a1'] })
  const r = await call($, { tool: 'Edit', file_path: '/w/slate-wt/app/globals.css', old_string: 'a{}', new_string: 'a{color:red}', agentId: 'agent-a1' })
  const why = refusalOf(r)
  expect(why).toContain('app/globals.css')
  expect(why).toContain('Stop')
  expect(why).toContain('report')
  expect(w.ran).toEqual([])
  // A subagent asking Dan itself is refused.
  const own = await askSkip($, w, why, SKIP_YES, { agentId: 'agent-a1' })
  expect(refusalOf(own)).toContain('Only the main session asks Dan')
  const ownSettled = await askSettled($, w, SETTLED_YES, { agentId: 'agent-a1' })
  expect(refusalOf(ownSettled)).toContain('Only the main session asks Dan')
  expect(w.asked).toEqual([])
  // The main session asks about the agent's refused call, and is told to have the agent try again.
  const answered = await askSkip($, w, why, SKIP_YES)
  expect(contextOf(answered)).toContain('agent')
  expect(w.store['record:/w/slate|issue:978']).toMatchObject({ kind: 'skipped' })
  const again = await call($, { tool: 'Edit', file_path: '/w/slate-wt/app/globals.css', old_string: 'a{}', new_string: 'a{color:red}', agentId: 'agent-a1' })
  expect(refusalOf(again)).toBe('')
  expect(w.ran.length).toBe(1)
  // A subagent's shell write is caught too.
  w.branches['/w/slate-wt'] = '980-other'
  const sh = await call($, { tool: 'Bash', command: "echo 'x' > /w/slate-wt/app/a.css", agentId: 'agent-a1' })
  expect(refusalOf(sh)).toContain('Stop')
})

test('it fails closed, saying so, when the issue or branch cannot be told or the record cannot be read', withKit, async ($, on) => {
  const w = world($, on)
  w.branches['/w/slate'] = 'UNREADABLE'
  const a = refusalOf(await call($, PAGE))
  expect(a).toContain('could not tell which issue or branch')
  expect(a).toContain('app/page.tsx')
  // A detached head names no branch.
  w.branches['/w/slate'] = ''
  expect(refusalOf(await call($, PAGE))).toContain('could not tell which issue or branch')
  // A path the disk cannot place in a checkout.
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/locked/x.css', content: '' }))).toContain('could not tell which issue or branch')
  // The store cannot be read: refused, never read as no answer, nor as an answer.
  w.branches['/w/slate'] = '978-design-round-guard'
  w.ctl.storeGetFails = true
  expect(refusalOf(await call($, PAGE))).toContain('could not be read')
  expect(w.ran).toEqual([])
  // #1145: every card it drew led in plain words, the file after.
  const reasons = w.cards.map(c => String((c as { reason?: string }).reason))
  expect(reasons.length).toBe(4)
  for (const r of reasons) expect({ r, plain: r.startsWith('Claude wants to make an edit that may change how something looks on screen') }).toEqual({ r, plain: true })
  // Dan's answer that cannot be recorded is said, and records nothing.
  w.ctl.storeGetFails = false
  w.ctl.storeSetFails = true
  expect(contextOf(await askSettled($, w, SETTLED_YES, {}, { path: '/w/slate' }))).toContain('could not be recorded')
  expect(refusalOf(await call($, PAGE))).toContain(SKIP_QUESTION)
})

test('a file in no checkout passes (a design round switcher in the scratchpad), and so does a plain Swift file; a SwiftUI view is held', withKit, async ($, on) => {
  const w = world($, on, { files: { '/w/slate/Sources/Main.swift': 'import SwiftUI\nstruct Main: View { var body: some View { Text("x") } }\n', '/w/slate/Sources/Date.swift': 'import Foundation\n' } })
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/private/tmp/claude-501/x/scratchpad/round1/switcher.html', content: '<!doctype html>' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: '/w/slate/Sources/Date.swift', old_string: 'import Foundation', new_string: 'import Foundation\nlet x = 1' }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Edit', file_path: '/w/slate/Sources/Main.swift', old_string: 'Text("x")', new_string: 'Text("y")' }))).toContain(SKIP_QUESTION)
  // A new Swift file declaring a view is held as it is written.
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/slate/Sources/New.swift', content: 'import SwiftUI\n' }))).toContain(SKIP_QUESTION)
  expect(w.ran.length).toBe(2)
})

test('the default branch is held for this session only: a no there does not carry into the next session', withKit, async ($, on) => {
  const w = world($, on)
  w.branches['/w/slate'] = 'main'
  const why = refusalOf(await call($, PAGE))
  expect(why).toContain('main in slate, for this session')
  await askSkip($, w, why, SKIP_YES)
  expect(refusalOf(await call($, PAGE))).toBe('')
  expect(Object.keys(w.store)).toEqual(['record:/w/slate|branch:main|session:s1'])
})

test('the settled question may name the issue when the branch does not, and Dan reads that issue in it', withKit, async ($, on) => {
  const w = world($, on)
  w.branches['/w/slate'] = 'main'
  await askSettled($, w, SETTLED_YES, {}, { issue: 978, path: '/w/slate' })
  expect(w.asked[0]?.questions[0]?.question).toContain('issue #978 in slate')
  w.branches['/w/slate'] = '978-design-round-guard'
  expect(refusalOf(await call($, PAGE))).toBe('')
})

// Lessons review of #991: a check asked with no call id ($.tool.check, a preview of what a call would
// meet) was let through unjudged. It is judged like a call, refused when the call would be, and since
// it runs nothing, no card is drawn and nothing waits on Dan.
test('a check asked with no call id is judged like the call: refused for a look changing file, with no card and nothing waiting', withKit, async ($, on) => {
  const w = world($, on)
  const ask = async (input: Record<string, unknown>) => (await $.tool.check({ tool: String(input.tool), input: { ...input, tool: undefined } } as never)) as { decision: string; reason?: string }
  const held = await ask(PAGE)
  expect(held.decision).toBe('deny')
  expect(held.reason).toContain('app/page.tsx')
  expect(held.reason).toContain('issue #978 in slate')
  expect((await ask(ROUTE)).decision).toBe('allow')
  expect(w.cards).toEqual([])
  // Nothing waits under an id the check never had.
  expect(refusalOf(await call($, { tool: 'AskUserQuestion', questions: [{ question: 'Skip design rounds for this issue?', header: 'x', options: [], multiSelect: false }], metadata: { source: 'design-round-guard:' } }))).toContain('No look changing edit is waiting')
})

test('a call a settings hook refuses is refused by that hook, never turned into a question', withKit, async ($, on) => {
  const w = world($, on)
  w.ctl.settingsRefuse = true
  const why = refusalOf(await call($, PAGE))
  expect(why).toBe('Blocked by a settings hook.')
  expect(w.cards).toEqual([])
})

// claude-config#1010, trypennie PR #529: the edit was one prop on a page, `xbc={xbc}` to
// `xbc={leadXbc ?? ''}`, which booking code the page hands its calendar. Nothing on screen changed,
// and the guard held it for a design round because the file is a page.
const RESULT = '/w/slate/src/app/my-offers/result/page.tsx'
const RESULT_TEXT = [
  "import { BookingCalendar } from '@/components/BookingCalendar'",
  '',
  'export default function Result({ xbc, leadXbc, slots }: Props) {',
  '  return (',
  '    <main className="p-4">',
  '      <BookingCalendar slots={slots} xbc={xbc} variant={plain} />',
  '    </main>',
  '  )',
  '}',
  '',
].join('\n')

test('#1010: a data only prop change on a page goes through unasked, judged from the edit; a look change on the same page is still held', withKit, async ($, on) => {
  const w = world($, on, { files: { [RESULT]: RESULT_TEXT } })
  expect(refusalOf(await call($, { tool: 'Edit', file_path: RESULT, old_string: 'xbc={xbc}', new_string: "xbc={leadXbc ?? ''}" }))).toBe('')
  expect(refusalOf(await call($, { tool: 'MultiEdit', file_path: RESULT, edits: [{ old_string: 'slots={slots}', new_string: 'slots={open(slots)}' }] }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Write', file_path: RESULT, content: RESULT_TEXT.replace('xbc={xbc}', 'xbc={lead.xbc}') }))).toBe('')
  expect(w.ran.length).toBe(3)
  // The same page, changed where it shows: held, each one.
  for (const [from, to] of [['className="p-4"', 'className="p-6"'], ['variant={plain}', 'variant={bold}'], ['xbc={xbc}', "xbc={'ABC'}"]] as const)
    expect(refusalOf(await call($, { tool: 'Edit', file_path: RESULT, old_string: from, new_string: to }))).toContain(SKIP_QUESTION)
  // A shell edit is never judged from its words, and a page the disk cannot read is held.
  expect(refusalOf(await call($, { tool: 'Bash', command: `sed -i '' 's/xbc={xbc}/xbc={lead}/' ${RESULT}` }))).toContain(SKIP_QUESTION)
  expect(refusalOf(await call($, { tool: 'Edit', file_path: '/w/slate/app/gone.tsx', old_string: 'xbc={xbc}', new_string: 'xbc={lead}' }))).toContain(SKIP_QUESTION)
  expect(w.ran.length).toBe(3)
  expect(Object.keys(w.store)).toEqual([])
  expect(w.asked).toEqual([])
})

test("#1010: Dan's Not a look change lets that one refused edit through unchanged, records why, and holds the next", withKit, async ($, on) => {
  const w = world($, on, { files: { [RESULT]: RESULT_TEXT }, agents: ['agent-a1'] })
  // A prop whose name can carry a look is never judged from the edit, so Dan is asked.
  const edit = { tool: 'Edit', file_path: RESULT, old_string: 'variant={plain}', new_string: 'variant={lead.variant}' }
  const why = refusalOf(await call($, edit))
  expect(why).toContain(NOT_LOOK)
  const answered = await askSkip($, w, why, NOT_LOOK)
  expect(w.asked[0]?.questions[0]?.options.map(o => o.label)).toEqual([SKIP_YES, SKIP_NO, NOT_LOOK])
  expect(contextOf(answered)).toContain('again now, unchanged')
  // His word is kept for that edit alone, with why; nothing is recorded for the issue.
  const passes = Object.entries(w.store).filter(([k]) => k.startsWith('pass:'))
  expect(passes.length).toBe(1)
  expect(passes[0]?.[1]).toMatchObject({ kind: 'not-look', tool: 'Edit', files: ['src/app/my-offers/result/page.tsx'], subjects: ['issue #978 in slate'] })
  expect(String((passes[0]?.[1] as { why?: string }).why)).toContain(NOT_LOOK)
  expect(w.store['record:/w/slate|issue:978']).toBeUndefined()
  expect(refusalOf(await call($, edit))).toBe('')
  // Any other edit to the same page is judged afresh, and the answered call waits on nobody.
  expect(refusalOf(await call($, { ...edit, new_string: 'variant={bold}' }))).toContain(SKIP_QUESTION)
  expect(refusalOf(await askSkip($, w, why, NOT_LOOK))).toContain('No look changing edit is waiting')
  // A shell edit and a subagent's edit are let through the same way, each once Dan answers.
  const sh = { tool: 'Bash', command: `sed -i '' 's/variant={plain}/variant={v}/' ${RESULT}` }
  await askSkip($, w, refusalOf(await call($, sh)), NOT_LOOK)
  expect(refusalOf(await call($, sh))).toBe('')
  const agents = { ...edit, new_string: 'variant={theirs}', agentId: 'agent-a1' }
  const agentWhy = refusalOf(await call($, agents))
  expect(agentWhy).toContain('Stop')
  expect(contextOf(await askSkip($, w, agentWhy, NOT_LOOK))).toContain('agent')
  expect(refusalOf(await call($, agents))).toBe('')
  expect(w.ran.length).toBe(3)
  expect(w.store['record:/w/slate|issue:978']).toBeUndefined()
})

// Lessons review of #1010: his word was kept under the call's tool and input alone, for ever, so the
// same shell command with a relative path, sent from another checkout or in a later session, would
// have gone through on an answer he gave about a different file.
test("#1010: Dan's Not a look change holds only in the session and the folder the call ran in", withKit, async ($, on) => {
  const w = world($, on)
  w.files['/w/other/app/page.tsx'] = 'x'
  const sh = { tool: 'Bash', command: "sed -i '' 's/a/b/' app/page.tsx" }
  w.at.cwd = '/w/slate'
  await askSkip($, w, refusalOf(await call($, sh)), NOT_LOOK)
  expect(refusalOf(await call($, sh))).toBe('')
  // The same words from another checkout write another file: asked about afresh.
  w.at.cwd = '/w/other'
  expect(refusalOf(await call($, sh))).toContain('issue #55 in other')
  // And the same call in a later session is asked about again.
  w.at.cwd = '/w/slate'
  w.at.session = 's2'
  expect(refusalOf(await call($, sh))).toContain(SKIP_QUESTION)
  expect(w.ran.length).toBe(1)
})

// Lessons review of #1010: a refused call left waiting by the guard before #1010, which kept no
// project, key or call text, survives a mod reload in the same session. It is no longer waiting: the
// edit is made again, never settled or let through on what it lacks.
test('#1010: a refused call left waiting by the earlier guard is asked about afresh, never settled or passed on what it lacks', withKit, async ($, on) => {
  const w = world($, on)
  const old = { id: 't900', tool: 'Write', files: ['app/page.tsx'], subjects: [{ key: 'record:/w/slate|issue:978', label: 'issue #978 in slate' }] }
  on('state.get', ($, e, next) => {
    if ((e as { key?: string }).key === 'pending') return { value: { value: [old], version: 1 } } as never
    return next(e)
  })
  expect(refusalOf(await askSkip($, w, 'design-round-guard:t900', NOT_LOOK))).toContain('No look changing edit is waiting under t900')
  expect(refusalOf(await askSettled($, w, SETTLED_YES, {}, { call: 't900', issue: 978 }))).toContain('No look changing edit is waiting under t900')
  expect(refusalOf(await askSettled($, w, SETTLED_YES))).toContain('"path"')
  expect(w.asked).toEqual([])
  expect(Object.keys(w.store)).toEqual([])
})

// Lessons review of #1010 (L567): his word authorises a call, so it is refused on its age when used,
// not trusted for as long as a session lasts. The call is resent within moments of his answer.
test("#1010: Dan's Not a look change lapses an hour after he gave it", withKit, async ($, on) => {
  const w = world($, on, { files: { [RESULT]: RESULT_TEXT } })
  const edit = { tool: 'Edit', file_path: RESULT, old_string: 'variant={plain}', new_string: 'variant={lead.variant}' }
  await askSkip($, w, refusalOf(await call($, edit)), NOT_LOOK)
  await w.clock.advance(60 * 60 * 1000 - 1)
  expect(refusalOf(await call($, edit))).toBe('')
  await w.clock.advance(1)
  expect(refusalOf(await call($, edit))).toContain(SKIP_QUESTION)
  expect(w.ran.length).toBe(1)
})

// Lessons review of #1010: the key is a hash, and the call's text is Claude's to write, so a record
// found under a call's key lets it through only when it holds that very call.
test("#1010: a Not a look change record found under a call's key lets it through only when it holds that very call", withKit, async ($, on) => {
  const w = world($, on)
  const edit = { tool: 'Edit', file_path: '/w/slate/app/page.tsx', old_string: 'p-4', new_string: 'p-6' }
  const { tool, ...input } = edit
  // A record under this call's key, as a colliding call would have left it, holding another call,
  // given just now so its age is not what refuses it.
  const at = { cwd: '/w/slate', session: 's1' }
  const record = { kind: 'not-look', at: T0, tool, files: ['app/page.tsx'], subjects: [], why: 'x' }
  w.store[`pass:${callKey(tool, input, at)}`] = { ...record, call: 'another call' }
  expect(refusalOf(await call($, edit))).toContain(SKIP_QUESTION)
  expect(w.ran).toEqual([])
  // The same record holding this very call lets it through, so the refusal above is the mismatch.
  w.store[`pass:${callKey(tool, input, at)}`] = { ...record, call: callText(tool, input, at) }
  expect(refusalOf(await call($, edit))).toBe('')
})

// claude-config#1010: Dan's Settled was recorded for Slate issue #2210, the session's folder, while
// the refused edit was on trypennie. Here the session sits in /w/other and the edit is in /w/slate.
test('#1010: Settled and Skip them record for the project and branch of the refused call, never the session folder', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/other' })
  expect(refusalOf(await call($, PAGE))).toContain('issue #978 in slate')
  const settled = await askSettled($, w, SETTLED_YES)
  expect(w.asked[0]?.questions[0]?.question).toContain('issue #978 in slate')
  expect(contextOf(settled)).toContain('issue #978 in slate')
  expect(Object.keys(w.store)).toEqual(['record:/w/slate|issue:978'])
  expect(refusalOf(await call($, PAGE))).toBe('')
  // The session's own project is untouched by it.
  const other = refusalOf(await call($, { tool: 'Write', file_path: '/w/other/x.css', content: 'a{}' }))
  expect(other).toContain('issue #55 in other')
  // And a skip about that call is for its project too.
  await askSkip($, w, other, SKIP_YES)
  expect(Object.keys(w.store).sort()).toEqual(['record:/w/other|issue:55', 'record:/w/slate|issue:978'])
})

test('#1010: with refused edits waiting in two projects, Settled is asked only about the one named', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/other' })
  const a = idIn(refusalOf(await call($, PAGE)))
  const b = idIn(refusalOf(await call($, { tool: 'Write', file_path: '/w/other/x.css', content: 'a{}' })))
  const unnamed = refusalOf(await askSettled($, w, SETTLED_YES))
  expect(unnamed).toContain(String(a))
  expect(unnamed).toContain(String(b))
  expect(w.asked).toEqual([])
  await askSettled($, w, SETTLED_YES, {}, { call: a })
  expect(w.asked[0]?.questions[0]?.question).toContain('issue #978 in slate')
  expect(Object.keys(w.store)).toEqual(['record:/w/slate|issue:978'])
  // A call that is not waiting is refused by name.
  expect(refusalOf(await askSettled($, w, SETTLED_YES, {}, { call: 't999' }))).toContain('No look changing edit is waiting under t999')
})

test('#1010: with no refused edit waiting, Settled needs the project named by a path, never read from the session folder', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/other' })
  expect(refusalOf(await askSettled($, w, SETTLED_YES))).toContain('"path"')
  expect(refusalOf(await askSettled($, w, SETTLED_YES, {}, { path: 'app' }))).toContain('"path"')
  expect(refusalOf(await askSettled($, w, SETTLED_YES, {}, { path: '/tmp/nowhere' }))).toContain('in no git checkout')
  expect(w.asked).toEqual([])
  await askSettled($, w, SETTLED_YES, {}, { path: '/w/slate/app' })
  expect(Object.keys(w.store)).toEqual(['record:/w/slate|issue:978'])
})

// claude-config#1010: a write to src/app/booking/[SO_ID]/page.tsx was refused as a write the guard
// could not follow, relative or absolute, so the proof it was making had to be done in memory.
test('#1010: a Next.js dynamic segment is followed as the folder it names, relative or absolute, by the shell and by inline code', withKit, async ($, on) => {
  const w = world($, on, { files: { '/w/slate/src/app/booking/[SO_ID]/page.tsx': 'export default function P() { return null }\n' } })
  for (const [command, shown] of [
    ['echo x > /w/slate/src/app/booking/[SO_ID]/page.tsx', 'src/app/booking/[SO_ID]/page.tsx'],
    ["cd /w/slate && sed -i '' 's/null/<p\\/>/' 'src/app/booking/[SO_ID]/page.tsx'", 'src/app/booking/[SO_ID]/page.tsx'],
    ['cd /w/slate/src/app && cp /tmp/page.tsx "booking/[SO_ID]/page.tsx"', 'src/app/booking/[SO_ID]/page.tsx'],
    [`cd /w/slate && python3 -c "open('src/app/(shop)/[...slug]/page.tsx','w').write('x')"`, 'src/app/(shop)/[...slug]/page.tsx'],
  ] as const) {
    const why = refusalOf(await call($, { tool: 'Bash', command }))
    expect([command, why.includes('issue #978 in slate') && why.includes(shown) && !why.includes('could not be followed')]).toEqual([command, true])
  }
  // The edit tools were never in doubt, and once Dan answers, the shell write goes through.
  expect(refusalOf(await call($, { tool: 'Write', file_path: '/w/slate/src/app/booking/[SO_ID]/page.tsx', content: 'x' }))).toContain('issue #978 in slate')
  await askSkip($, w, refusalOf(await call($, { tool: 'Bash', command: 'echo x > /w/slate/src/app/booking/[SO_ID]/page.tsx' })), SKIP_YES)
  expect(refusalOf(await call($, { tool: 'Bash', command: 'echo x > /w/slate/src/app/booking/[SO_ID]/page.tsx' }))).toBe('')
  // A bracket that is a pattern is no route segment: since #1015 its folder is followed, so it is held
  // as a look changing file of that checkout's issue, which Dan can answer for.
  w.branches['/w/slate'] = '979-next'
  const pattern = refusalOf(await call($, { tool: 'Bash', command: 'echo x > /w/slate/app/page.ts[x]' }))
  expect(pattern).toContain('app/page.ts[x]')
  expect(pattern).toContain('issue #979 in slate')
})

// claude-config#1015: a shell write whose file NAME is a pattern that may expand to a design tokens
// or Tailwind config file was let through: its extension is literal, and its literal name is no look
// changing file. Every name a pattern may expand to is now judged. And the other way, seen on
// 2026-10-12: `rm -f ~/.claude/state/ai-review/shown/timing-test-post.*`, a scratch file in Claude's
// own state folder in no project, was refused as "a pattern that may name a look changing file".
test('#1015: a pattern in a written name is held where it may expand to a tokens or Tailwind config file', withKit, async ($, on) => {
  const w = world($, on)
  // A folder held in a variable leaves only the folder unknown, never the name (lessons review of #1015).
  for (const command of ['cd "$D" && echo x > [t]ailwind.config.ts', 'echo x > $D/app/page.ts[x]', 'echo x > "$D/[t]ailwind.config.ts"']) {
    const why = refusalOf(await call($, { tool: 'Bash', command }))
    expect([command, why.includes('a pattern that may name a look changing file')]).toEqual([command, true])
  }
  // A relative one is placed in the session's folder, a checkout, so it waits on that issue (#1123).
  for (const command of ['echo x > [t]ailwind.config.ts', 'echo x > app/[t]okens.json', "printf '{}' > design-[t]okens.json", 'rm -f tailwind.config.*']) {
    const why = refusalOf(await call($, { tool: 'Bash', command }))
    expect([command, why.includes('issue #978 in slate'), why.includes('could not be followed')]).toEqual([command, true, false])
  }
  // Its folder followed into the checkout, it waits on that issue's answer like any look changing file.
  const why = refusalOf(await call($, { tool: 'Bash', command: 'echo x > /w/slate/[t]ailwind.config.ts' }))
  expect(why).toContain('[t]ailwind.config.ts')
  expect(why).toContain('issue #978 in slate')
  BOTH_WAYS(why)
  await askSkip($, w, why, SKIP_YES)
  expect(refusalOf(await call($, { tool: 'Bash', command: 'echo x > /w/slate/[t]ailwind.config.ts' }))).toBe('')
  expect(w.ran.length).toBe(1)
})

test('#1015: a pattern in a folder outside every checkout, or whose literal parts rule out every look changing file, runs', withKit, async ($, on) => {
  const w = world($, on)
  for (const command of [
    'rm -f ~/.claude/state/ai-review/shown/timing-test-post.*',
    'rm -f $HOME/.claude/state/ai-review/shown/*',
    'echo x > /tmp/scratch/[t]ailwind.config.ts',
    'rm -f logs/run-*.log',
    'rm -f /w/slate/logs/*.l?g',
    'echo x > notes-[0-9].md',
    'rm -f /w/slate/tests/*.tsx',
  ]) {
    expect([command, refusalOf(await call($, { tool: 'Bash', command }))]).toEqual([command, ''])
  }
  expect(w.ran.length).toBe(7)
})

// claude-config#1123: the guard could not place a RELATIVE pattern (a cd before it moves its folder,
// and only mod-kit's write reader follows a cd), so it held one as a write it could not follow. The
// reader now gives the folder a pattern lands in, the cd followed, and the guard places it there.
test('#1123: a relative pattern after a cd is placed in its folder: in a checkout it waits on that issue, outside every checkout it runs', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/other' })
  for (const [command, shown] of [
    ['cd /w/slate && echo x > app/[t]okens.json', 'app/[t]okens.json'],
    ['cd /w/slate/src && rm -f *.css', 'src/*.css'],
  ] as [string, string][]) {
    const why = refusalOf(await call($, { tool: 'Bash', command }))
    expect([command, why.includes('issue #978 in slate'), why.includes(shown), why.includes('could not be followed')]).toEqual([command, true, true, false])
  }
  // A relative pattern in the session's own folder is placed there too.
  const here = refusalOf(await call($, { tool: 'Bash', command: 'echo x > [t]ailwind.config.ts' }))
  expect(here).toContain('issue #55 in other')
  // Outside every checkout, it is in no project and runs.
  expect(refusalOf(await call($, { tool: 'Bash', command: 'cd /tmp/scratch && rm -f *.css' }))).toBe('')
  // Once Dan answers for the issue, the placed pattern goes through.
  await askSkip($, w, refusalOf(await call($, { tool: 'Bash', command: 'cd /w/slate && echo x > app/[t]okens.json' })), SKIP_YES)
  expect(refusalOf(await call($, { tool: 'Bash', command: 'cd /w/slate && echo x > app/[t]okens.json' }))).toBe('')
})

test('#1015: a pattern the guard cannot read is held, saying so, and in a known checkout waits on its issue', withKit, async ($, on) => {
  world($, on)
  const why = refusalOf(await call($, { tool: 'Bash', command: `cd "$D" && echo x > 'x.@(css|md)'` }))
  expect(why).toContain('a pattern the design round guard cannot read')
  // The folder followed (mod-kit reads the group as a name, a cd included), it is that issue's to answer.
  const known = refusalOf(await call($, { tool: 'Bash', command: "echo x > 'app/x.@(css|md)'" }))
  expect(known).toContain('app/x.@(css|md)')
  expect(known).toContain('issue #978 in slate')
})

// claude-config#1046, from a pet session: the session in the project's main checkout, the edit in a
// worktree whose branch names the issue. Dan answered Settled with metadata "call" naming the refused
// edit, and the same edit sent again (with a new id) was refused again, naming the same issue.
const WT_PAGE = { tool: 'Edit', file_path: '/w/slate-wt/app/page.tsx', old_string: 'p-4', new_string: 'p-6' }
const WT_STYLE = { tool: 'Edit', file_path: '/w/slate-wt/app/globals.css', old_string: 'a{}', new_string: 'a{color:red}' }
for (const [form, metadataOf] of [
  ['"call" naming the refused edit', (id: string) => ({ call: id })],
  ['"path" naming the worktree and "issue"', () => ({ path: '/w/slate-wt', issue: 1548 })],
  ['"path" naming a file in the worktree', () => ({ path: '/w/slate-wt/app/page.tsx' })],
  ['nothing but the source', () => ({})],
] as const)
  test(`#1046: Settled with ${form} lets the resent edit and every later look changing edit on the issue through`, withKit, async ($, on) => {
    const w = world($, on, { cwd: '/w/slate' })
    w.branches['/w/slate'] = 'main'
    w.branches['/w/slate-wt'] = '1548-enrollment-chart'
    const why = refusalOf(await call($, WT_PAGE))
    expect(why).toContain('issue #1548 in slate')
    const id = idIn(why)
    if (!id) throw new Error(`no refused call named in: ${why}`)
    const settled = await askSettled($, w, SETTLED_YES, {}, metadataOf(id))
    expect(refusalOf(settled)).toBe('')
    expect(w.asked[0]?.questions[0]?.question).toContain('issue #1548 in slate')
    expect(contextOf(settled)).toContain('recorded as settled for issue #1548 in slate')
    // The edit sent again arrives with a new id, and goes through; so does another look change there.
    expect(refusalOf(await call($, WT_PAGE))).toBe('')
    expect(refusalOf(await call($, WT_STYLE))).toBe('')
    expect(w.ran.map(x => x.input.file_path)).toEqual(['/w/slate-wt/app/page.tsx', '/w/slate-wt/app/globals.css'])
  })

// claude-config#1046: "issue" given beside "call" recorded only the issue named, never what the refused
// edit waits on, so when the two differed the edit sent again was refused again, and every answer
// after that looped. Naming a call now always records what that call waits on, as Skip them does.
test('#1046: Settled naming a refused call records what that call waits on, whatever "issue" also names', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate' })
  w.branches['/w/slate'] = 'main'
  w.branches['/w/slate-wt'] = '1548-enrollment-chart'
  const id = idIn(refusalOf(await call($, WT_PAGE)))
  if (!id) throw new Error('no refused call named')
  const r = await askSettled($, w, SETTLED_YES, {}, { call: id, issue: 1549 })
  expect(w.asked[0]?.questions[0]?.question).toContain('issue #1548 in slate and issue #1549 in slate')
  expect(contextOf(r)).toContain('Send the Edit call to app/page.tsx again now')
  expect(Object.keys(w.store).sort()).toEqual(['record:/w/slate|issue:1548', 'record:/w/slate|issue:1549'])
  expect(refusalOf(await call($, WT_PAGE))).toBe('')
})

// claude-config#1046: a refused edit on the default branch waits on that branch for this session, and
// the skill says to add the issue there, so Settled naming both recorded only the issue and the edit
// was held again.
test('#1046: on the default branch, Settled naming the refused call and its issue lets the edit through now and on the issue branch later', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate' })
  w.branches['/w/slate'] = 'main'
  const id = idIn(refusalOf(await call($, PAGE)))
  if (!id) throw new Error('no refused call named')
  const r = await askSettled($, w, SETTLED_YES, {}, { call: id, issue: 978 })
  expect(w.asked[0]?.questions[0]?.question).toContain('main in slate, for this session and issue #978 in slate')
  expect(contextOf(r)).toContain('Send the Write call to app/page.tsx again now')
  expect(refusalOf(await call($, PAGE))).toBe('')
  w.branches['/w/slate'] = '978-design-round-guard'
  expect(refusalOf(await call($, STYLE))).toBe('')
  expect(w.ran.length).toBe(2)
})

// claude-config#1046: a path that is not absolute was refused with "No refused edit is waiting",
// whether one was or not, which read as the path being ignored in favour of "call".
test('#1046: a path that is not absolute is refused by name, naming the refused edits that are waiting', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate' })
  w.branches['/w/slate-wt'] = '1548-enrollment-chart'
  const id = idIn(refusalOf(await call($, WT_PAGE)))
  const why = refusalOf(await askSettled($, w, SETTLED_YES, {}, { path: 'slate-wt', issue: 1548 }))
  expect(why).toContain('"slate-wt" is not an absolute path')
  expect(why).toContain(`${id}: issue #1548 in slate`)
  expect(why).not.toContain('No refused edit is waiting')
  expect(w.asked).toEqual([])
})

test('#1046: with no refused edit waiting, a path that is not absolute is still refused by name, asking only for an absolute path', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate' })
  const why = refusalOf(await askSettled($, w, SETTLED_YES, {}, { path: 42 }))
  expect(why).toContain('"42" is not an absolute path')
  expect(why).toContain('"path" as the absolute path')
  expect(why).not.toContain('"call"')
  expect(w.asked).toEqual([])
})

// claude-config#1057: the design rounds skill is read fresh each time it is used, while a session keeps
// the guard it loaded at its start. On 2026-10-09 a session followed the new skill (Settled naming
// the refused call) against the guard from before it, which ignored the call, recorded Settled for
// the wrong subject, and refused the edit again, so the answer looped (#1046). The two are stamped
// with one contract version: the skill's `<!-- design-round-guard contract: N -->` and the guard's
// CONTRACT, and the skill has every question carry its version as metadata "contract".
const SKILL_MD = `${HOME}/.claude/skills/design-rounds/SKILL.md`
const stamped = (n: number) => `---\nname: design-rounds\n---\n<!-- design-round-guard contract: ${n} -->\n# Design rounds\n`

test('#1057: an answer in a form newer than this guard knows is refused, naming the remedy, with nothing asked or recorded', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate', files: { [SKILL_MD]: stamped(CONTRACT) } })
  const id = idIn(refusalOf(await call($, PAGE)))
  if (!id) throw new Error('no refused call')
  const newer = [
    () => askSettled($, w, SETTLED_YES, {}, { call: id, contract: CONTRACT + 1 }),
    () => askSkip($, w, `design-round-guard:${id}`, SKIP_YES, { metadata: { source: `design-round-guard:${id}`, contract: CONTRACT + 1 } }),
  ]
  for (const ask of newer) {
    const why = refusalOf(await ask())
    expect(why).toContain("this session's design round guard predates the design rounds steps you read")
    expect(why).toContain('start a new session')
  }
  expect(w.asked).toEqual([])
  expect(Object.keys(w.store)).toEqual([])
  // Asked again the same way, it says the same, rather than looping through a record and a refusal.
  expect(refusalOf(await askSettled($, w, SETTLED_YES, {}, { call: id, contract: CONTRACT + 1 }))).toContain('start a new session')
  expect(refusalOf(await call($, PAGE))).toContain(SKIP_QUESTION)
})

// Lessons review of #1057: a contract that is not a whole number ("2", 2.5) read as no claim, so the
// question was answered as current. It is refused by name, before Dan is asked.
test('#1057: a contract that is not a whole number is refused by name, with nothing asked or recorded', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate' })
  const id = idIn(refusalOf(await call($, PAGE)))
  if (!id) throw new Error('no refused call')
  for (const contract of ['2', 2.5, 0, null]) {
    const why = refusalOf(await askSettled($, w, SETTLED_YES, {}, { call: id, contract }))
    expect([contract, why.includes('is not a contract version')]).toEqual([contract, true])
  }
  expect(w.asked).toEqual([])
  expect(Object.keys(w.store)).toEqual([])
})

test('#1057: the design rounds skill on disk stamped newer than this guard is refused the same way, even with no contract given', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate', files: { [SKILL_MD]: stamped(CONTRACT + 1) } })
  const id = idIn(refusalOf(await call($, PAGE)))
  if (!id) throw new Error('no refused call')
  const why = refusalOf(await askSettled($, w, SETTLED_YES, {}, { call: id }))
  expect(why).toContain("this session's design round guard predates the design rounds steps you read")
  expect(w.asked).toEqual([])
})

test('#1057: the same contract on both sides, or a skill not on disk, is answered as before', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate', files: { [SKILL_MD]: stamped(CONTRACT) } })
  const id = idIn(refusalOf(await call($, PAGE)))
  if (!id) throw new Error('no refused call')
  const r = await askSettled($, w, SETTLED_YES, {}, { call: id, contract: CONTRACT })
  expect(refusalOf(r)).toBe('')
  expect(contextOf(r)).toContain('recorded as settled for issue #978 in slate')
  expect(refusalOf(await call($, PAGE))).toBe('')
  // No skill on disk at all: nothing to compare against, so nothing is refused for it.
  delete w.files[SKILL_MD]
  w.branches['/w/slate'] = '979-next'
  const id2 = idIn(refusalOf(await call($, STYLE)))
  expect(refusalOf(await askSettled($, w, SETTLED_YES, {}, { call: id2 }))).toBe('')
})

// #1138. Dan, 2026-10-13, on "Skip design rounds for this issue? Claude wants to change how
// hooks/register.tsx looks, on issue #1135 ...": "I don't know what the file name means or what this
// change will do. Can we have the question presented in plain terms so I actually know what is going
// to change? So like 'this will change the look of x button on y page' or something."
const questionOf = (w: W) => w.asked[w.asked.length - 1]?.questions[0]?.question ?? ''

test('#1138: a real look change: the question leads with what changes on screen, and names the file second', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, PAGE))
  // The refusal tells Claude what the question needs.
  expect(why).toContain('"onScreen"')
  const shows = 'The Save button on the invoice screen turns from grey to blue.'
  await askSkip($, w, why, SKIP_YES, {}, { onScreen: shows })
  const q = questionOf(w)
  expect(q.startsWith(shows)).toBe(true)
  expect(q.indexOf(SKIP_QUESTION)).toBeGreaterThan(q.indexOf(shows))
  expect(q.indexOf('app/page.tsx')).toBeGreaterThan(q.indexOf(SKIP_QUESTION))
  expect(q).toContain('issue #978 in slate')
  expect(q).not.toContain('Claude wants to change how')
  // A sentence with no full stop of its own is given one, so the question does not run on.
  w.branches['/w/slate'] = '979-next'
  const why2 = refusalOf(await call($, { ...STYLE, new_string: 'a{color:blue}' }))
  await askSkip($, w, why2, SKIP_NO, {}, { onScreen: 'Links on every page turn blue' })
  expect(questionOf(w).startsWith(`Links on every page turn blue. ${SKIP_QUESTION}`)).toBe(true)
})

test('#1138: a no visible change edit: the question leads with that, and Not a look change keeps the sentence with his word', withKit, async ($, on) => {
  const w = world($, on, { files: { [RESULT]: RESULT_TEXT } })
  const edit = { tool: 'Edit', file_path: RESULT, old_string: 'variant={plain}', new_string: 'variant={lead.variant}' }
  const why = refusalOf(await call($, edit))
  const shows = 'Nothing on screen changes: the offer page reads its variant from the lead instead of a constant with the same value.'
  await askSkip($, w, why, NOT_LOOK, {}, { onScreen: shows })
  const q = questionOf(w)
  expect(q.startsWith(shows)).toBe(true)
  expect(q.indexOf('src/app/my-offers/result/page.tsx')).toBeGreaterThan(q.indexOf(SKIP_QUESTION))
  const pass = Object.entries(w.store).find(([k]) => k.startsWith('pass:'))?.[1] as { onScreen?: string } | undefined
  expect(pass?.onScreen).toBe(shows)
  expect(refusalOf(await call($, edit))).toBe('')
})

test('#1138: with no plain sentence, or one that only names the file, nothing is asked and the call stays waiting', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, PAGE))
  for (const onScreen of [undefined, '', '   ', 7]) {
    const r = await askSkip($, w, why, SKIP_YES, {}, { onScreen })
    expect(refusalOf(r)).toContain('"onScreen"')
    expect(refusalOf(r)).toContain('which control or area')
  }
  for (const onScreen of ['Changes app/page.tsx.', 'This edits page.tsx so it looks different.', 'Edits the file globals.css']) expect(refusalOf(await askSkip($, w, why, SKIP_YES, {}, { onScreen }))).toContain('names a file')
  expect(refusalOf(await askSkip($, w, why, SKIP_YES, {}, { onScreen: 'x'.repeat(301) }))).toContain('one sentence')
  expect(w.asked.length).toBe(0)
  expect(Object.keys(w.store)).toEqual([])
  // Asked with one, the same refused call is asked about and answered.
  expect(contextOf(await askSkip($, w, why, SKIP_YES))).toContain(`Dan answered ${SKIP_YES}`)
  expect(refusalOf(await call($, PAGE))).toBe('')
})

test("#1138: a subagent is told to report what on screen its change alters, for the main session's question", withKit, async ($, on) => {
  const w = world($, on, { agents: ['agent-a1'] })
  const why = refusalOf(await call($, { ...PAGE, agentId: 'agent-a1' }))
  expect(why).toContain('what on screen')
  expect(w.ran).toEqual([])
})

test('#1138: a typed answer is not recorded, Dan is told so, and Claude is told to say so and ask again', withKit, async ($, on) => {
  const w = world($, on)
  const why = refusalOf(await call($, PAGE))
  const typed = contextOf(await askSkip($, w, why, 'which page is this?'))
  expect(typed).toContain('which page is this?')
  expect(typed).toContain('not recorded')
  expect(typed).toContain('ask him the same question again')
  expect(w.toasts.some(t => t.includes('not recorded'))).toBe(true)
  expect(Object.keys(w.store)).toEqual([])
  expect(refusalOf(await call($, PAGE))).toContain(SKIP_QUESTION)
  // The settled question the same way.
  const typedSettled = contextOf(await askSettled($, w, 'looks fine to me'))
  expect(typedSettled).toContain('not recorded')
  expect(typedSettled).toContain(`ask him "${SETTLED_QUESTION}" again`)
  expect(w.toasts.length).toBe(2)
  expect(Object.keys(w.store)).toEqual([])
  // A mod-kit that cannot say it (loaded before it had the member): Claude is still told, and told
  // that Dan was not.
  const unsaid = contextOf(await askSkip($, w, why, 'BREAKS'))
  expect(unsaid).toContain('nothing is recorded')
  expect(unsaid).toContain('could not tell him')
  expect(unsaid).toContain('the same question again')
  expect(w.toasts.length).toBe(2)
  // Asked again and answered by choosing, it is recorded.
  await askSkip($, w, why, SKIP_YES)
  expect(refusalOf(await call($, PAGE))).toBe('')
})

// #1138: a mod's own hook files draw Claude Code's panels through JSX (Box, Text, Button) and through
// mod-kit's frames, so they count as screen files; an edit to one is judged by what it touches. The
// fixture is shaped after the real mods (simpler's reply button, manual steps' band frame);
// tests/test-mod-hook-render-reader.sh reads every real mod hook file with the same reader.
const MOD_HOOK = '/w/slate/payload/mods/demo/hooks/register.tsx'
const MOD_TEXT = `import type { EngineInterface, Register } from 'claude-code'
import { AMBER } from './rules.ts'

// Whether the reply is the one offered.
const sameReply = (a: string, b: string): boolean => a.trim() === b.trim()

const publishBand = async ($: EngineInterface): Promise<string | undefined> => {
  await $.modkit.bandRow({ mod: 'demo', id: 'steps', frame: { kind: 'left-rule', color: AMBER }, lines: [] as never })
  return undefined
}

export const register: Register = on => {
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (!sameReply(e.props.text, 'x')) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const button = e.props.isFirstOfReply ? (
      <Button key="simpler" label="Simpler" onPress={() => publishBand($)} />
    ) : (
      <Text key="simpler-typed">
        <Text dimColor>type: </Text>/simpler
      </Text>
    )
    return (
      <Box flexDirection="column">
        {button}
        {await next(e)}
      </Box>
    )
  })
}
`

test("#1138: a mod hook file: a logic edit outside its JSX passes unasked; its JSX, its colours and frames, and the same edit in an app's page are asked", withKit, async ($, on) => {
  const w = world($, on, { files: { [MOD_HOOK]: MOD_TEXT, '/w/slate/payload/mods/demo/.claude-plugin/plugin.json': '{ "name": "demo" }', '/w/slate/app/page.tsx': MOD_TEXT, '/w/slate/src/mods/shop/hooks/useCart.tsx': MOD_TEXT } })
  const edit = (old_string: string, new_string: string, file_path = MOD_HOOK) => ({ tool: 'Edit', file_path, old_string, new_string })
  // Logic: what a function decides, a comment, a value a condition compares.
  expect(refusalOf(await call($, edit('a.trim() === b.trim()', 'a.trim().toLowerCase() === b.trim().toLowerCase()')))).toBe('')
  expect(refusalOf(await call($, edit('// Whether the reply is the one offered.', '// Whether the reply is the one offered, read in any case or colour.')))).toBe('')
  expect(refusalOf(await call($, edit("if (!sameReply(e.props.text, 'x')) return next(e)", "if (!sameReply(e.props.text, 'y')) return next(e)")))).toBe('')
  expect(w.ran.length).toBe(3)
  // What it draws: a prop, a tag's child text on its own line, a new element, the band's colour and frame.
  const drawn: [string, string][] = [
    ['<Box flexDirection="column">\n        {button}', '<Box flexDirection="row">\n        {button}'],
    ['</Text>/simpler', '</Text>/simpler now'],
    ['        {button}\n        {await', '        {button}\n        <Text>more</Text>\n        {await'],
    ['color: AMBER', 'color: RED'],
    ["kind: 'left-rule'", "kind: 'box'"],
  ]
  for (const [from, to] of drawn) expect(refusalOf(await call($, edit(from, to)))).toContain(SKIP_QUESTION)
  // The same logic edit in an app's screen file is still asked: only a mod's hook file is read so.
  expect(refusalOf(await call($, edit('a.trim() === b.trim()', 'a === b', '/w/slate/app/page.tsx')))).toContain(SKIP_QUESTION)
  // So is an app's own hooks folder under a folder named mods, which no plugin.json beside it makes a
  // Claude Code mod (lessons review).
  expect(refusalOf(await call($, edit('a.trim() === b.trim()', 'a === b', '/w/slate/src/mods/shop/hooks/useCart.tsx')))).toContain(SKIP_QUESTION)
  // A mod hook file whose text the reader cannot follow is asked about, never passed.
  w.files[MOD_HOOK] = MOD_TEXT.replace('// Whether the reply is the one offered.', 'const unclosed = <Box>')
  expect(refusalOf(await call($, edit('a.trim() === b.trim()', 'a === b')))).toContain(SKIP_QUESTION)
  expect(w.ran.length).toBe(3)
})

// #1151: the two commands a design round in a NurseDex session was refused on, 2026-10-13, word for
// word with the home folder renamed: its own files in the scratchpad, named through a cd to a
// variable, by a python script on standard input, and inside a JSON spec written by heredoc.
const NURSEDEX_ROUND1 = "D=/private/tmp/claude-501/-Users-dan-Non-icloudDocuments-Apps-NurseDex/ac526795-9960-4d45-83e5-9aecae814348/scratchpad/consent/design; cd $D && python3 - <<'EOF'\nd=\"/private/tmp/claude-501/-Users-dan-Non-icloudDocuments-Apps-NurseDex/ac526795-9960-4d45-83e5-9aecae814348/scratchpad/consent/design\"\nc=open(f\"{d}/screen.css\").read()\nc=c.replace(\".nd-slim { left: 0; right: 0; bottom: 0; background: #2d3436; color: #fbf9f7; padding: 8px 24px; font-size: 13px; }\",\n \".nd-slim { left: 0; right: 0; bottom: 0; background: #fbf9f7; border-top: 1px solid rgba(196,217,207,.5); box-shadow: 0 -6px 18px rgba(0,0,0,.08); padding: 8px 24px; font-size: 13px; }\")\nc=c.replace(\".nd-slim a { color: #c4d9cf; }\\n\",\"\")\nc=c.replace(\".nd-slim .nd-btn { height: 28px; padding: 0 10px; font-size: 13px; background: transparent; color: #fbf9f7; border-color: #636e72; }\",\n \".nd-slim .nd-btn { height: 28px; padding: 0 10px; font-size: 13px; }\")\nopen(f\"{d}/screen.css\",\"w\").write(c)\nEOF\ngrep -c \"2d3436; color: #fbf9f7\" screen.css\ncat > builder.js <<'EOF'\nvar COPY = \"We'd like to run analytics and session recording in your browser to see where NurseDex is confusing and fix it. None of it runs unless you accept.\";\n\nfunction el(tag, cls, text) {\n  var n = document.createElement(tag);\n  if (cls) n.className = cls;\n  if (text) n.textContent = text;\n  return n;\n}\n\nfunction bar(shape) {\n  var b = el(\"div\", \"nd-bar nd-\" + shape);\n  var inner = el(\"div\", \"nd-in\");\n  var p = el(\"p\", null, COPY + \" \");\n  p.style.margin = \"0\";\n  var a = el(\"a\", null, \"Privacy policy\");\n  a.href = \"#\";\n  p.append(a);\n  var btns = el(\"div\", \"nd-btns\");\n  btns.append(el(\"button\", \"nd-btn\", \"Decline\"), el(\"button\", \"nd-btn\", \"Accept\"));\n  inner.append(p, btns);\n  b.append(inner);\n  return b;\n}\n\nfunction frame(kind, scale, caption, shape) {\n  var col = el(\"div\", \"nd-col\");\n  var w = kind === \"desktop\" ? 1280 : 390;\n  var h = kind === \"desktop\" ? 800 : 844;\n  var clip = el(\"div\", \"nd-clip\");\n  clip.style.width = Math.round(w * scale) + \"px\";\n  clip.style.height = Math.round(h * scale) + \"px\";\n  var shot = el(\"div\", \"nd-shot nd-\" + kind);\n  shot.style.transform = \"scale(\" + scale + \")\";\n  shot.append(bar(shape));\n  clip.append(shot);\n  col.append(el(\"div\", \"nd-cap\", caption), clip);\n  return col;\n}\n\nfunction buildScreen(variant) {\n  var pair = el(\"div\", \"nd-pair\");\n  pair.append(\n    frame(\"desktop\", 0.66, \"Desktop, home page, 1280 wide, drawn at 66%\", variant.shape),\n    frame(\"phone\", 0.75, \"Phone, Find a Nurse, 390 wide, drawn at 75%\", variant.shape)\n  );\n  return pair;\n}\nEOF\ncat > spec.json <<'EOF'\n{\n  \"title\": \"NurseDex, cookie consent banner\",\n  \"round\": \"What shape should the banner take\",\n  \"asks\": \"It must be impossible to miss, keep the page usable behind it, and give Decline and Accept equal weight.\",\n  \"measurement\": \"Copy, buttons and colours are identical in all three; only the banner's shape changes. Pages are real NurseDex screenshots.\",\n  \"builder\": \"builder.js\",\n  \"styles\": \"screen.css\",\n  \"variants\": [\n    {\"key\": \"1\", \"name\": \"Full width bar\", \"why\": \"Edge to edge along the bottom, like a site notice. Most noticeable; takes the most height on a phone.\", \"measured\": \"About 70px tall on desktop, 180px on a phone.\", \"shape\": \"full\"},\n    {\"key\": \"2\", \"name\": \"Floating card\", \"why\": \"A card in the bottom corner, leaving most of the page visible. Feels lighter, but sits over content in that corner.\", \"measured\": \"420px wide on desktop; full width less margins on a phone.\", \"shape\": \"card\"},\n    {\"key\": \"3\", \"name\": \"Slim strip\", \"why\": \"The full width bar with less padding and smaller buttons, so it takes the least room. Easiest to ignore.\", \"measured\": \"About 44px tall on desktop.\", \"shape\": \"slim\"}\n  ]\n}\nEOF\npython3 ~/.claude/skills/design-rounds/make-switcher.py spec.json round1.html"
const NURSEDEX_ROUND2 = "D=/private/tmp/claude-501/-Users-dan-Non-icloudDocuments-Apps-NurseDex/ac526795-9960-4d45-83e5-9aecae814348/scratchpad/consent/design; cat >> /private/tmp/claude-501/-Users-dan-Non-icloudDocuments-Apps-NurseDex/ac526795-9960-4d45-83e5-9aecae814348/scratchpad/consent/design/screen.css <<'EOF'\n.nd-btn.teal { background: #2a7b6f; border-color: #2a7b6f; color: #fff; }\n.nd-btn.dark { background: #2d3436; border-color: #2d3436; color: #fff; }\nEOF\npython3 - <<'EOF'\nd=\"/private/tmp/claude-501/-Users-dan-Non-icloudDocuments-Apps-NurseDex/ac526795-9960-4d45-83e5-9aecae814348/scratchpad/consent/design\"\nb=open(d+\"/builder.js\").read()\nb=b.replace('function bar(shape) {','function bar(shape, btn) {')\nb=b.replace('btns.append(el(\"button\", \"nd-btn\", \"Decline\"), el(\"button\", \"nd-btn\", \"Accept\"));','var bc = \"nd-btn\" + (btn ? \" \" + btn : \"\");\\n  btns.append(el(\"button\", bc, \"Decline\"), el(\"button\", bc, \"Accept\"));')\nb=b.replace('function frame(kind, scale, caption, shape) {','function frame(kind, scale, caption, variant) {')\nb=b.replace('shot.append(bar(shape));','shot.append(bar(variant.shape || \"full\", variant.btn));')\nb=b.replace('variant.shape),\\n','variant),\\n').replace('variant.shape)\\n','variant)\\n')\nopen(d+\"/builder.js\",\"w\").write(b)\nEOF\ngrep -n \"variant\\|btn\" $D/builder.js | head; cat > /private/tmp/claude-501/-Users-dan-Non-icloudDocuments-Apps-NurseDex/ac526795-9960-4d45-83e5-9aecae814348/scratchpad/consent/design/spec2.json <<'EOF'\n{\n  \"title\": \"NurseDex, cookie consent banner\",\n  \"round\": \"How should Decline and Accept look\",\n  \"asks\": \"Both buttons must carry the same weight, so neither answer is nudged; the question is which equal treatment reads best on NurseDex.\",\n  \"measurement\": \"Full width bar from round 1 in all three; copy identical; only the two buttons' treatment changes, and they always match each other.\",\n  \"builder\": \"builder.js\",\n  \"styles\": \"screen.css\",\n  \"variants\": [\n    {\"key\": \"1\", \"name\": \"Both outlined\", \"why\": \"White buttons with a light border, quiet against the page. The bar's text leads; the buttons do not shout.\", \"measured\": \"Same as round 1.\", \"shape\": \"full\", \"btn\": \"\"},\n    {\"key\": \"2\", \"name\": \"Both teal\", \"why\": \"Both filled in NurseDex's own teal, matching Sign up and Browse nurses. Clearly buttons, clearly NurseDex.\", \"measured\": \"White on teal, the site's existing button pairing.\", \"shape\": \"full\", \"btn\": \"teal\"},\n    {\"key\": \"3\", \"name\": \"Both dark\", \"why\": \"Both filled in the dark grey of Join NurseDex free. Strong and neutral, without reusing the site's call to action colour.\", \"measured\": \"White on dark grey.\", \"shape\": \"full\", \"btn\": \"dark\"}\n  ]\n}\nEOF\npython3 /Users/dan/.claude/skills/design-rounds/make-switcher.py /private/tmp/claude-501/-Users-dan-Non-icloudDocuments-Apps-NurseDex/ac526795-9960-4d45-83e5-9aecae814348/scratchpad/consent/design/spec2.json /private/tmp/claude-501/-Users-dan-Non-icloudDocuments-Apps-NurseDex/ac526795-9960-4d45-83e5-9aecae814348/scratchpad/consent/design/round2.html"

test("#1151: a design round's own files in the scratchpad pass, however the command names them, with the session in a project", withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate' })
  const SCRATCH = '/private/tmp/claude-501/-Users-dan-Non-icloudDocuments-Apps-NurseDex/ac526795-9960-4d45-83e5-9aecae814348/scratchpad/consent/design'
  // The two commands refused in the NurseDex session, word for word.
  expect(refusalOf(await call($, { tool: 'Bash', command: NURSEDEX_ROUND1 }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Bash', command: NURSEDEX_ROUND2 }))).toBe('')
  // The issue's own shapes: a cd to a variable before the switcher, and a stylesheet named in a spec.
  expect(refusalOf(await call($, { tool: 'Bash', command: `D=${SCRATCH}; cd $D && python3 make-switcher.py spec.json round1.html` }))).toBe('')
  expect(refusalOf(await call($, { tool: 'Bash', command: `D=${SCRATCH}; cat > $D/spec.json <<'EOF'\n{ "builder": "builder.js", "styles": "screen.css" }\nEOF` }))).toBe('')
  // A spec's own name is no look file wherever its folder is, so one written into a folder the
  // reader cannot follow passes too, whatever its data names.
  expect(refusalOf(await call($, { tool: 'Bash', command: `cat > $D/spec.json <<'EOF'\n{ "styles": "screen.css" }\nEOF` }))).toBe('')
  // A program run in the scratchpad that writes a stylesheet by a bare name writes it there.
  expect(refusalOf(await call($, { tool: 'Bash', command: `cd ${SCRATCH} && python3 - <<'EOF'\nf = "screen.css"\nopen(f, "w").write("a{}")\nEOF` }))).toBe('')
  expect(w.ran.length).toBe(6)
})

test('#1151: a look edit in the project is still held, however the command names it', withKit, async ($, on) => {
  const w = world($, on, { cwd: '/w/slate' })
  // A stylesheet handed to a program as an argument, which it writes through sys.argv (lessons review).
  expect(refusalOf(await call($, { tool: 'Bash', command: `cd /w/slate && python3 - app/site.css <<'EOF'\nimport sys\nopen(sys.argv[1], 'w').write('a{}')\nEOF` }))).toContain(SKIP_QUESTION)
  // A program on standard input writing a stylesheet the session's project holds, by a bare name.
  const sh = (command: string) => call($, { tool: 'Bash', command })
  expect(refusalOf(await sh(`cd /w/slate && python3 - <<'EOF'\nf = "app/site.css"\nopen(f, "w").write("a{}")\nEOF`))).toContain(SKIP_QUESTION)
  expect(refusalOf(await sh(`python3 - <<'EOF'\nf = "app/site.css"\nopen(f, "w").write("a{}")\nEOF`))).toContain(SKIP_QUESTION)
  // The same program after a cd the reader cannot follow: where it writes cannot be told, so it is held.
  expect(refusalOf(await sh(`cd $D && python3 - <<'EOF'\nf = "site.css"\nopen(f, "w").write("a{}")\nEOF`))).toContain('could not')
  // A copy or move of a stylesheet into a folder the reader cannot follow lands under the source's own
  // name, a look file wherever that folder is, so it is held (lessons review of #1151).
  for (const command of ['cp app/site.css $D/', 'mv app/site.css "$D"/', 'cp app/site.css $D', 'cp app/site.css "$(dirname x)"/'])
    expect({ command, held: refusalOf(await sh(command)).includes('could not') }).toEqual({ command, held: true })
  // A write whose own name is a variable may be a look file, so its data still counts.
  expect(refusalOf(await sh(`cat > $F <<'EOF'\napp/site.css\nEOF`))).toContain('could not')
  // And a stylesheet written into the project by a heredoc is a look edit, as ever.
  expect(refusalOf(await sh(`cat > /w/slate/app/site.css <<'EOF'\na{}\nEOF`))).toContain(SKIP_QUESTION)
  expect(w.ran).toEqual([])
})
