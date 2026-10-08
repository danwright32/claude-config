import { expect, mock, test, type Engine } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { HEADER, SETTLED_NO, SETTLED_QUESTION, SETTLED_SOURCE, SETTLED_YES, SKIP_NO, SKIP_QUESTION, SKIP_YES } from '../hooks/rules.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { pipeline } from './mod-kit/hooks/commands.ts'
import { readBranch, type Run } from './mod-kit/hooks/branch.ts'
import { githubRepo, repoName } from './mod-kit/hooks/repo.ts'

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
          for (const root of ['/w/slate-wt', '/w/slate', '/w/other']) if (path === root || path.startsWith(root + '/')) return root
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
  const branches: Record<string, string> = { '/w/slate': '978-design-round-guard', '/w/slate-wt': '978-design-round-guard', '/w/other': '55-other' }
  const store: Record<string, unknown> = {}
  const ctl: { storeGetFails: boolean; storeSetFails: boolean; settingsRefuse: boolean; storeSetFailKey?: string } = { storeGetFails: false, storeSetFails: false, settingsRefuse: false }
  const ran: { tool: string; input: Record<string, unknown> }[] = []
  const asked: Asked[] = []
  const dialog: Dialog = {}
  const cards: Record<string, unknown>[] = []
  const gitRuns: string[] = []
  const at = { cwd: init.cwd ?? '/w/slate' }
  mock.clock(on)
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : undefined }) as never)
  on('session.cwd', () => ({ value: at.cwd }) as never)
  on('session.id', () => ({ value: 's1' }) as never)
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
    if (sub === 'worktree list --porcelain') return { exitCode: 0, stdout: `worktree /w/${tree === '/w/other' ? 'other' : 'slate'}\nHEAD abc\nbranch refs/heads/main\n\n`, stderr: '' }
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
    // mod-kit's branch reader, read here with its copy, over the checkouts the stand-in's walk finds.
    if (cmd === '__modkit' && args[0] === 'branch') {
      const { path } = JSON.parse(String(args[1])) as { path: string }
      const root = ['/w/slate-wt', '/w/slate', '/w/other'].find(r => path === r || path.startsWith(r + '/'))
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
    const t = files[e.path]
    if (t === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: t } as never
  })
  on('store.get', ($, e) => {
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
  on('ui.toast', () => ({ value: undefined }) as never)
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
    ran.push({ tool: String(tool), input })
    return { result: 'written', text: 'written' } as never
  })
  return { files, branches, store, ctl, ran, asked, dialog, cards, gitRuns, at }
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

// Claude asking Dan the skip question as the refusal told it to, and Dan answering in the dialog.
const askSkip = async ($: Caller, w: W, refusal: string, answer: string | undefined, extra: Record<string, unknown> = {}) => {
  const id = idIn(refusal)
  if (!id) throw new Error(`no refused call named in: ${refusal}`)
  w.dialog.answer = answer
  return call($, {
    tool: 'AskUserQuestion',
    questions: [{ question: 'Skip design rounds for this issue?', header: 'x', options: [{ label: 'Yes', description: 'y' }, { label: 'No', description: 'n' }], multiSelect: false }],
    metadata: { source: `design-round-guard:${id}` },
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

test('a file that does not change the look passes untouched, with nothing asked of git', withKit, async ($, on) => {
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
  expect(q.question.startsWith(SKIP_QUESTION)).toBe(true)
  expect(q.question).toContain('app/page.tsx')
  expect(q.header).toBe(HEADER)
  expect(q.options.map(o => o.label)).toEqual([SKIP_YES, SKIP_NO])
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
  ]) {
    const r = refusalOf(await call($, forged))
    expect(r).toContain("design round guard's own record")
  }
  expect(w.ran).toEqual([])
  expect(Object.keys(w.store)).toEqual([])
  expect(refusalOf(await call($, PAGE))).toContain(SKIP_QUESTION)
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
  // Dan's answer that cannot be recorded is said, and records nothing.
  w.ctl.storeGetFails = false
  w.ctl.storeSetFails = true
  expect(contextOf(await askSettled($, w, SETTLED_YES))).toContain('could not be recorded')
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
  await askSettled($, w, SETTLED_YES, {}, { issue: 978 })
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
