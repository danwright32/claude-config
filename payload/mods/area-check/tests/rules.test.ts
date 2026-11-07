import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import {
  DEADLINE_MS,
  BUDGET_MS,
  BARS,
  DEFAULT_BAR,
  barFor,
  type Bar,
  FOLDER_MAX,
  GROWTH_MIN,
  ISSUE_LIMIT,
  parseLineCounts,
  sizeCandidates,
  toCached,
  TOP_N,
  editedPath,
  fileKind,
  goalIssues,
  issuesNaming,
  issuesRead,
  judge,
  labelFacts,
  parseNumstat,
  rank,
  rankingKey,
  replay,
  type CachedIssue,
  type ReplayInput,
  ANSWER_MS,
  ANSWERS,
  ASK_SOURCE,
  DECIDE_TOOL,
  SWEEP_MS,
  answerStands,
  decideProblem,
  holdCard,
  holdRefusal,
  legacyQuestionKey,
  questionKey,
  reasonProblem,
  restructureQuestion,
  sleepNotes,
  sweepKeys,
  type Held,
  couldHold,
  heldUnder,
  shellKey,
  shellTargets,
  scriptProgram,
  scriptWrite,
  unreadPart,
  type ShellTarget,
} from '../hooks/rules.ts'

// The area check (#1506, facts #1508, hold #1509): the facts about a file at the moment a session
// first edits it, computed purely here so each rule is tested on its own. These facts decide a verdict
// (would_hold or quiet); a would_hold verdict is a held edit, refused until the session decides.

const issue = (n: number, refs: string[], labels: Partial<CachedIssue> = {}): CachedIssue => ({ n, refs, structural: ['tech-debt'], priority: 'p2', ...labels })

test('the whole read is held under 75% of the 10 second budget (L743)', () => {
  expect(BUDGET_MS).toBe(10_000)
  expect(DEADLINE_MS).toBeLessThan(BUDGET_MS * 0.75)
})

test('only the edit tools name a judged file: Edit, Write, MultiEdit by file_path, NotebookEdit by notebook_path', () => {
  expect(editedPath('Edit', { file_path: '/r/a.ts' })).toBe('/r/a.ts')
  expect(editedPath('Write', { file_path: '/r/a.ts', content: 'x' })).toBe('/r/a.ts')
  expect(editedPath('MultiEdit', { file_path: '/r/a.ts', edits: [] })).toBe('/r/a.ts')
  expect(editedPath('NotebookEdit', { notebook_path: '/r/n.ipynb' })).toBe('/r/n.ipynb')
  // editedPath names only the edit tools' file; a shell write is read by shellTargets instead (#2142).
  expect(editedPath('Bash', { command: 'echo x > /r/a.ts' })).toBe(null)
  expect(editedPath('Read', { file_path: '/r/a.ts' })).toBe(null)
  expect(editedPath('Edit', {})).toBe(null)
  expect(editedPath('Edit', { file_path: 'relative.ts' })).toBe(null)
})

test('source and test files are judged (decision 3), each told apart by the shared test rule', () => {
  for (const p of ['src/lib/slack.ts', 'app/page.tsx', 'hooks/x.sh', 'Sources/App/Model.swift', 'tools/a.py', 'app/globals.css']) expect(fileKind(p)).toBe('source')
  for (const p of ['src/lib/slack.test.ts', 'tests/test-x.sh', 'AppTests/ModelTests.swift', '__tests__/a.tsx']) expect(fileKind(p)).toBe('test')
})

test('docs, config, lockfiles, migrations and generated files are not judged (decision 3)', () => {
  for (const p of [
    'README.md', 'docs/x.md', 'package.json', 'tsconfig.json', '.github/workflows/ci.yml', 'Cargo.lock', 'yarn.lock',
    'tailwind.config.ts', 'next.config.mjs', 'vite.config.js', 'eslint.config.js', '.eslintrc.js', 'jest.config.cjs',
    'supabase/migrations/20260101_x.sql', 'db/migrations/0001_init.ts', 'prisma/migrations/x/migration.ts',
    'types/index.d.ts', 'src/gen/api.generated.ts', 'src/__generated__/schema.ts', 'dist/app.js', 'build/x.js', 'node_modules/a/b.js', 'public/vendor.min.js',
    'notes.txt', 'data.csv', 'image.png',
  ]) expect(fileKind(p)).toBe(null)
})

test('labels: structural only by a whole known spelling (L1023), and the priority label read as p0 to p4', () => {
  expect(labelFacts(['tech-debt', 'priority-p1', 'mods'])).toEqual({ structural: ['tech-debt'], priority: 'p1' })
  expect(labelFacts(['Refactor', 'test-refactor'])).toEqual({ structural: ['refactor', 'test-refactor'], priority: null })
  expect(labelFacts(['tech-debt-ish', 'refactoring-ideas', 'priority-p9'])).toEqual({ structural: [], priority: null })
})

test('an issue names the file by its full path, a line range after it stripped by the extractor', () => {
  const tracked = ['src/lib/slack.ts', 'src/app/page.tsx']
  expect(issuesNaming('src/lib/slack.ts', [issue(4, ['src/lib/slack.ts'])], tracked)).toEqual([{ n: 4, how: 'path', structural: ['tech-debt'], priority: 'p2' }])
})

test('a partial suffix names the file on path segment boundaries only when it is unique among tracked files', () => {
  const tracked = ['src/lib/foo.ts', 'src/otherlib/foo.ts', 'src/lib/foo.tsx', 'web/app/x.ts', 'api/app/x.ts']
  expect(issuesNaming('src/lib/foo.ts', [issue(1, ['lib/foo.ts'])], tracked).map(m => m.how)).toEqual(['suffix'])
  // otherlib/foo.ts is its own file; lib/foo.tsx another; neither names lib/foo.ts. (lib/foo.tsx sits
  // in the same folder, so it still counts there, by the folder fallback and said so.)
  expect(issuesNaming('src/lib/foo.ts', [issue(2, ['otherlib/foo.ts']), issue(3, ['lib/foo.tsx'])], tracked).map(m => `${m.n}:${m.how}`)).toEqual(['3:folder'])
  // app/x.ts could be either checkout's, so it names neither.
  expect(issuesNaming('web/app/x.ts', [issue(5, ['app/x.ts'])], tracked)).toEqual([])
})

test('a bare basename names the file only when no other tracked file shares it (slack.ts twice names neither)', () => {
  const tracked = ['src/lib/slack.ts', 'scripts/slack.ts', 'src/lib/stripe.ts']
  expect(issuesNaming('src/lib/stripe.ts', [issue(6, ['stripe.ts'])], tracked).map(m => m.how)).toEqual(['basename'])
  expect(issuesNaming('src/lib/slack.ts', [issue(7, ['slack.ts'])], tracked)).toEqual([])
})

test('a file not yet on the default branch is still named by its full path', () => {
  expect(issuesNaming('src/new/thing.ts', [issue(8, ['src/new/thing.ts'])], ['src/a.ts']).map(m => m.how)).toEqual(['path'])
})

test(`issues naming files in the same folder count when that folder has at most ${FOLDER_MAX} matches (decision 4)`, () => {
  const tracked = ['src/pay/a.ts', 'src/pay/b.ts', 'src/pay/c.ts', 'src/other/d.ts']
  const few = [issue(10, ['src/pay/b.ts']), issue(11, ['src/pay/c.ts']), issue(12, ['src/other/d.ts'])]
  expect(issuesNaming('src/pay/a.ts', few, tracked)).toEqual([
    { n: 10, how: 'folder', structural: ['tech-debt'], priority: 'p2' },
    { n: 11, how: 'folder', structural: ['tech-debt'], priority: 'p2' },
  ])
  const many = [1, 2, 3, 4, 5, 6].map(n => issue(20 + n, ['src/pay/b.ts']))
  expect(issuesNaming('src/pay/a.ts', many, tracked)).toEqual([])
  // The file's own issue still counts when its folder is busy, and is counted in that folder's matches.
  const own = [issue(30, ['src/pay/a.ts']), ...[1, 2, 3, 4, 5].map(n => issue(30 + n, ['src/pay/b.ts']))]
  expect(issuesNaming('src/pay/a.ts', own, tracked).map(m => `${m.n}:${m.how}`)).toEqual(['30:path'])
})

test('unlabelled issues are matched too, and kept apart by their empty structural list', () => {
  const m = issuesNaming('src/a.ts', [issue(40, ['src/a.ts'], { structural: [], priority: null })], ['src/a.ts'])
  expect(m).toEqual([{ n: 40, how: 'path', structural: [], priority: null }])
})

test("the session's goal names its issues as #N", () => {
  expect(goalIssues('Ship #1508 and close #1509 (see danwright32/claude-config#1510)')).toEqual([1508, 1509, 1510])
  expect(goalIssues('make it faster')).toEqual([])
})

test('the issue list is UNREAD when it cannot be parsed and TRUNCATED when it fills the limit, each its own outcome', () => {
  expect(issuesRead('not json')).toEqual({ state: 'unread', why: 'gh answered with something that is not an issue list' })
  expect(issuesRead('{"a":1}')).toEqual({ state: 'unread', why: 'gh answered with something that is not an issue list' })
  const rows = [{ number: 1, title: 't', body: 'b', labels: [{ name: 'tech-debt' }] }]
  expect(issuesRead(JSON.stringify(rows))).toEqual({ state: 'read', rows: [{ number: 1, title: 't', body: 'b', labels: ['tech-debt'] }] })
  const full = Array.from({ length: ISSUE_LIMIT }, (_, i) => ({ number: i + 1, title: '', body: '', labels: [] }))
  expect(issuesRead(JSON.stringify(full)).state).toBe('truncated')
})

// git log --numstat -M --format=%x1e%s, newest commit first.
const LOG = [
  '\x1efix: stop the crash in slack (#9)',
  '30\t5\tsrc/lib/{old => new}/slack.ts',
  '4\t0\tREADME.md',
  '\x1eAdd the stripe client',
  '100\t0\tsrc/lib/stripe.ts',
  '-\t-\tpublic/logo.png',
  '\x1eGrow slack before the move',
  '50\t10\tsrc/lib/old/slack.ts',
  '\x1eRename the whole file',
  '7\t2\tlegacy.ts => src/lib/stripe.ts',
  '\x1eFixes a bug in legacy',
  '9\t1\tlegacy.ts',
].join('\n')

test('growth is net lines per file with renames followed to the current name, binary rows skipped', () => {
  const g = parseNumstat(LOG)
  expect(g['src/lib/new/slack.ts']).toEqual({ net: 65, fixes: 1 })
  expect(g['src/lib/stripe.ts']).toEqual({ net: 113, fixes: 1 })
  expect(g['src/lib/old/slack.ts']).toBe(undefined)
  expect(g['legacy.ts']).toBe(undefined)
  expect(g['public/logo.png']).toBe(undefined)
  expect(g['README.md']).toEqual({ net: 4, fixes: 1 })
})

test('a fix is counted by its title alone, as a word (L801)', () => {
  const g = parseNumstat(['\x1eprefix the fixture names', '1\t0\ta.ts', '\x1eFixed the totals', '1\t0\ta.ts'].join('\n'))
  expect(g['a.ts']).toEqual({ net: 2, fixes: 1 })
})

test(`the growth bar: large files that grew past the minimum, the ${TOP_N} fastest growing (decision 6)`, () => {
  const growth: Record<string, { net: number; fixes: number }> = {}
  const sizes: Record<string, number> = {}
  for (let i = 0; i < 14; i++) {
    growth[`f${i}.ts`] = { net: 400 + i * 10, fixes: 0 }
    sizes[`f${i}.ts`] = 2000
  }
  growth['small.ts'] = { net: 5000, fixes: 0 }
  sizes['small.ts'] = 900
  growth['slow.ts'] = { net: 100, fixes: 0 }
  sizes['slow.ts'] = 9000
  const r = rank(growth, sizes)
  expect(r.top).toEqual(['f13.ts', 'f12.ts', 'f11.ts', 'f10.ts', 'f9.ts', 'f8.ts', 'f7.ts', 'f6.ts', 'f5.ts', 'f4.ts'])
  expect(r.facts['f13.ts']).toEqual({ net: 530, size: 2000, fixes: 0, rank: 1 })
  expect(r.facts['f0.ts']?.rank).toBe(14)
  expect(r.facts['small.ts']?.rank).toBe(null)
})

test('a quiet repo with tiny growth holds nothing by the bar (decision 6)', () => {
  expect(rank({ 'a.ts': { net: 12, fixes: 0 } }, { 'a.ts': 5000 }).top).toEqual([])
})

test('the ranking is keyed on the repository, origin head sha, the day and the rule version (L573)', () => {
  expect(rankingKey('o/r', 'abc', Date.UTC(2026, 9, 22, 23, 0))).toBe('o/r abc 2026-10-22 v2')
  expect(rankingKey('o/r', 'abc', Date.UTC(2026, 9, 23, 1, 0))).not.toBe(rankingKey('o/r', 'abc', Date.UTC(2026, 9, 22, 23, 0)))
})

test('judged: a structural issue naming the file would hold it; the issue the session works on is left out (decision 5)', () => {
  const m = [{ n: 4, how: 'path' as const, structural: ['tech-debt'], priority: 'p2' }]
  expect(judge({ matches: m, own: [], crosses: false })).toEqual({ decision: 'would_hold', why: ['issues'], shown: [4], excluded: [] })
  expect(judge({ matches: m, own: [4], crosses: false })).toEqual({ decision: 'quiet', why: [], shown: [], excluded: [4] })
})

test('judged: an unlabelled issue alone is quiet, the growth bar alone would hold', () => {
  const m = [{ n: 40, how: 'path' as const, structural: [], priority: null }]
  expect(judge({ matches: m, own: [], crosses: false })).toEqual({ decision: 'quiet', why: [], shown: [], excluded: [] })
  expect(judge({ matches: [], own: [], crosses: true })).toEqual({ decision: 'would_hold', why: ['growth'], shown: [], excluded: [] })
})

// The bar (#1509), set from the week's log on both Macs, 2026-10-23 to 11-02: the numbers and where
// each threshold lands are in docs/mods-design.md under the area check.
test('the bar is dated, and a repository without a bar of its own takes the default one', () => {
  expect(DEFAULT_BAR).toEqual({ set: '2026-11-02', sizeMin: 1500, growthMin: 300, topN: 10, folderMax: 2, holdPriorities: ['p0', 'p1', 'p2'] })
  expect(barFor('someone/anything')).toBe(DEFAULT_BAR)
  expect(BARS).toEqual({})
})

test('a bar of its own is found by repository name whatever the owner or case, and ranks by its own numbers', () => {
  const own: Bar = { ...DEFAULT_BAR, set: '2026-11-03', sizeMin: 100, growthMin: 10, topN: 1 }
  expect(barFor('Owner/Quiet', { quiet: own })).toBe(own)
  expect(barFor('other/quiet', { quiet: own })).toBe(own)
  const growth = { 'a.ts': { net: 50, fixes: 0 }, 'b.ts': { net: 40, fixes: 0 } }
  expect(rank(growth, { 'a.ts': 200, 'b.ts': 200 }, own).top).toEqual(['a.ts'])
  expect(rank(growth, { 'a.ts': 200, 'b.ts': 200 }).top).toEqual([])
  expect(sizeCandidates(growth, own)).toEqual(['a.ts', 'b.ts'])
  expect(sizeCandidates(growth)).toEqual([])
})

test('judged: only a p0 to p2 structural issue holds; a p3 or p4 one alone is quiet; one with no priority counts as p2', () => {
  const at = (n: number, priority: string | null) => ({ n, how: 'path' as const, structural: ['tech-debt'], priority })
  expect(judge({ matches: [at(1, 'p3'), at(2, 'p4')], own: [], crosses: false })).toEqual({ decision: 'quiet', why: [], shown: [], excluded: [] })
  expect(judge({ matches: [at(1, 'p3'), at(2, 'p1')], own: [], crosses: false })).toEqual({ decision: 'would_hold', why: ['issues'], shown: [2], excluded: [] })
  expect(judge({ matches: [at(3, null)], own: [], crosses: false })).toEqual({ decision: 'would_hold', why: ['issues'], shown: [3], excluded: [] })
  expect(judge({ matches: [at(1, 'p3')], own: [], crosses: true })).toEqual({ decision: 'would_hold', why: ['growth'], shown: [], excluded: [] })
  const lenient: Bar = { ...DEFAULT_BAR, holdPriorities: ['p0', 'p1', 'p2', 'p3'] }
  expect(judge({ matches: [at(1, 'p3')], own: [], crosses: false, bar: lenient }).shown).toEqual([1])
})

test('the folder fallback counts only when the folder has at most 2 issues naming its files', () => {
  expect(FOLDER_MAX).toBe(2)
  const tracked = ['src/pay/a.ts', 'src/pay/b.ts', 'src/pay/c.ts', 'src/pay/d.ts']
  const three = [issue(10, ['src/pay/b.ts']), issue(11, ['src/pay/c.ts']), issue(12, ['src/pay/d.ts'])]
  expect(issuesNaming('src/pay/a.ts', three, tracked)).toEqual([])
  expect(issuesNaming('src/pay/a.ts', three, tracked, 5).map(m => m.n)).toEqual([10, 11, 12])
})

test('the replay counts holds per session, a commit standing in for a session and its own issues left out', () => {
  const input: ReplayInput = {
    issues: [issue(1, ['src/a.ts']), issue(2, ['src/b.ts'], { structural: [] })],
    tracked: ['src/a.ts', 'src/b.ts', 'lib/c.ts'],
    days: { '2026-10-01': { growth: { 'lib/c.ts': { net: 900, fixes: 2 } }, sizes: { 'lib/c.ts': 4000 } } },
    sessions: [
      { id: 's1', day: '2026-10-01', own: [], files: ['src/a.ts', 'lib/c.ts', 'README.md'] },
      { id: 's2', day: '2026-10-01', own: [1], files: ['src/a.ts', 'src/b.ts'] },
      { id: 's3', day: '2026-10-01', own: [], files: ['docs/x.md'] },
    ],
  }
  const r = replay(input)
  expect(r.sessions).toEqual([
    { id: 's1', judged: 2, held: 2, holds: [{ path: 'src/a.ts', why: ['issues'] }, { path: 'lib/c.ts', why: ['growth'] }] },
    { id: 's2', judged: 2, held: 0, holds: [] },
    { id: 's3', judged: 0, held: 0, holds: [] },
  ])
  expect(r.summary).toEqual({ sessions: 3, judgedSessions: 2, withHold: 1, holds: 2, byIssues: 1, byGrowth: 1, fourOrMore: 0, histogram: { '0': 2, '2': 1 } })
})

test("a file's size is read from git grep -c, by its path at the default head, a colon in the path kept", () => {
  expect(parseLineCounts('origin/main:src/a.ts:1800\norigin/main:odd:name.ts:12\nnoise\n', 'origin/main')).toEqual({ 'src/a.ts': 1800, 'odd:name.ts': 12 })
})

test('only files that grew enough are sized', () => {
  expect(sizeCandidates({ 'a.ts': { net: GROWTH_MIN, fixes: 0 }, 'b.ts': { net: GROWTH_MIN - 1, fixes: 0 } })).toEqual(['a.ts'])
})

test('the cache keeps each issue with its labels read and the paths the shared reader found, none when it found none', () => {
  expect(toCached([{ number: 3, title: '', body: '', labels: ['refactor', 'priority-p0'] }, { number: 4, title: '', body: '', labels: [] }], { '3': ['a.ts'] })).toEqual([
    { n: 3, structural: ['refactor'], priority: 'p0', refs: ['a.ts'] },
    { n: 4, structural: [], priority: null, refs: [] },
  ])
})

// ---- The hold (#1509): what a held edit shows, and what a decision must carry ----

const HELD: Held = {
  id: 'toolu_1', tool: 'Edit', repo: 'dan/app', main: '/w/app', rel: 'src/lib/slack.ts', agent: null, at: 0,
  why: ['issues'],
  shown: [{ n: 41, how: 'path', structural: ['tech-debt'], priority: 'p2' }, { n: 57, how: 'suffix', structural: ['refactor'], priority: null }],
  issues: { state: 'read' },
  growth: { net: 820, size: 2400, fixes: 3, rank: 2, crosses: true },
}
const GROWTH_ONLY: Held = { ...HELD, why: ['growth'], shown: [] }

test('a proceed reason must start with a word, so a bracket, a quote or a dash standing alone never reads as a reason (L675)', () => {
  for (const r of ['<why this change does not add to the problem>', '"', '-- adds nothing', '...', '  ', '(see above)', '123 lines only'])
    expect(reasonProblem(r)).toBeDefined()
})

test('a proceed reason that is a placeholder or too short to say anything is refused, by name', () => {
  for (const r of ['n/a', 'none', 'TBD', 'ok', 'fine', 'because', 'no reason', 'small change']) expect(reasonProblem(r)).toBeDefined()
  expect(reasonProblem(undefined)).toContain('reason')
  expect(reasonProblem(42)).toContain('reason')
  expect(reasonProblem('Only renames one local variable inside formatDate')).toBeUndefined()
})

test('a decision is one of three, and proceed is refused without a real reason', () => {
  expect(decideProblem({ decision: 'skip' }, HELD)).toContain('proceed')
  expect(decideProblem({ decision: 'proceed', reason: 'ok' }, HELD)).toBeDefined()
  expect(decideProblem({ decision: 'proceed', reason: 'Only renames one local variable inside formatDate' }, HELD)).toBeUndefined()
  expect(decideProblem({ decision: 'restructure' }, HELD)).toBeUndefined()
})

test('fold names an issue the hold showed, never another, and a file held for growth alone has none to fold', () => {
  expect(decideProblem({ decision: 'fold', issue: 41 }, HELD)).toBeUndefined()
  expect(decideProblem({ decision: 'fold', issue: 57 }, HELD)).toBeUndefined()
  expect(decideProblem({ decision: 'fold', issue: 99 }, HELD)).toContain('#41')
  expect(decideProblem({ decision: 'fold' }, HELD)).toContain('#41')
  expect(decideProblem({ decision: 'fold', issue: '41' }, HELD)).toContain('#41')
  expect(decideProblem({ decision: 'fold', issue: 41 }, GROWTH_ONLY)).toContain('growth')
})

test('the card names the file, each issue with its priority, a missing label read as p2, and growth as rough', () => {
  const c = holdCard(HELD)
  expect(c.reason).toContain('src/lib/slack.ts')
  expect(c.reason).toContain('#41 (p2, tech-debt)')
  expect(c.reason).toContain('#57 (p2, refactor)')
  expect(c.note).toMatch(/^Rough: grew 820 lines net in 90 days/)
  expect(holdCard(GROWTH_ONLY).reason).toContain('fastest growing')
})

test('the card says when the issues could not be read, with why, and that growth alone decided (decision 12)', () => {
  const c = holdCard({ ...GROWTH_ONLY, issues: { state: 'unread', why: 'not read within 7 seconds' } })
  expect(c.reason).toContain('not read within 7 seconds')
  expect(c.reason).toContain('growth')
})

test("the refusal names the call to decide under and every way out; a subagent's restructure goes to the main session", () => {
  const main = holdRefusal(HELD)
  expect(main).toContain(DECIDE_TOOL)
  expect(main).toContain('"call": "toolu_1"')
  for (const w of ['proceed', 'fold', 'restructure', '#41', '#57']) expect(main).toContain(w)
  const agent = holdRefusal({ ...HELD, agent: 'ag1' })
  expect(agent).toContain('main session')
  expect(holdRefusal(GROWTH_ONLY)).not.toContain('"fold"')
})

test("the restructure question is Dan's three answers, Fold in only where an issue was shown", () => {
  const q = restructureQuestion(HELD)
  expect(q.question).toContain('src/lib/slack.ts')
  expect(q.options.map(o => o.label)).toEqual([...ANSWERS])
  expect(restructureQuestion(GROWTH_ONLY).options.map(o => o.label)).toEqual(['Restructure first', 'Proceed anyway'])
  expect(ASK_SOURCE).toBe('area-check')
})

test("asleep, one note per issue shown, with the repo, the issue and the question, as bedtime reads them", () => {
  const notes = sleepNotes(HELD)
  expect(notes.length).toBe(2)
  expect(notes[0]).toMatchObject({ kind: 'question', repo: 'dan/app', issue: 41 })
  expect(notes[1]).toMatchObject({ kind: 'question', repo: 'dan/app', issue: 57 })
  expect(String(notes[0]?.text)).toContain('src/lib/slack.ts')
  expect(notes[0]?.options).toEqual([...ANSWERS])
  // Held for growth alone there is no issue to post into: one note for the morning report.
  const g = sleepNotes(GROWTH_ONLY)
  expect(g.length).toBe(1)
  expect(g[0]?.issue).toBeUndefined()
})

test("Dan's answer stands for a week and for the same issues, so he is not asked again; new issues ask again", () => {
  const q = { state: 'answered' as const, answer: 'Proceed anyway', at: 1_000, issues: [57, 41] }
  expect(answerStands(q, [41, 57], 1_000 + ANSWER_MS - 1)).toBe(true)
  expect(answerStands(q, [41, 57], 1_000 + ANSWER_MS)).toBe(false)
  expect(answerStands(q, [41, 57, 60], 2_000)).toBe(false)
  expect(answerStands({ state: 'pending', at: 1_000, issues: [41], session: 's', call: 'c', agent: null }, [41], 2_000)).toBe(false)
  expect(answerStands(undefined, [41], 2_000)).toBe(false)
})

test('a question is kept under a fixed length key, so a held command naming a long word can still be decided (#2246)', async () => {
  // The SHA-256 of "dan/app\nsrc/a.ts", measured with shasum rather than with the code under test.
  expect(await questionKey('dan/app', 'src/a.ts')).toBe('question:4a58b19b28d1b3e1b5d8ac84dac32deaf18e46cfa1e6d7b5772f0531fd6c788d')
  expect(await questionKey('dan/app', 'src/a.ts')).not.toBe(await questionKey('dan/app', 'src/b.ts'))
  expect(await questionKey('dan/app', 'src/a.ts')).not.toBe(await questionKey('dan/other', 'src/a.ts'))
  // A word of a thousand characters gives a key of the same 73, well under the store's 256.
  expect((await questionKey('dan/app', 'x'.repeat(1000))).length).toBe(73)
  // The key it was kept under before, read for an answer already given; none past the store's limit.
  expect(legacyQuestionKey('dan/app', 'src/a.ts')).toBe('question:dan/app\nsrc/a.ts')
  // "question:dan/app\n" is 17 characters, so a word of 239 makes a key of exactly 256 and 240 one too long.
  expect(legacyQuestionKey('dan/app', 'x'.repeat(239))).toBe(`question:dan/app\n${'x'.repeat(239)}`)
  expect(legacyQuestionKey('dan/app', 'x'.repeat(240))).toBeUndefined()
})

test('the sweep drops issue lists unread for a week and answers past their week, and keeps a pending question', () => {
  const now = 100 * SWEEP_MS
  const keys = sweepKeys([
    ['issues:dan/old', { at: now - SWEEP_MS }],
    ['issues:dan/new', { at: now - SWEEP_MS + 1 }],
    ['issues:dan/bad', 'not a record'],
    ['question:dan/app\na.ts', { state: 'answered', at: now - ANSWER_MS, issues: [] }],
    ['question:dan/app\nb.ts', { state: 'pending', at: 0, issues: [] }],
    ['other', { at: 0 }],
  ], now)
  expect(keys.sort()).toEqual(['issues:dan/bad', 'issues:dan/old', 'question:dan/app\na.ts'])
})

// #2142: a file written by a shell command, read through mod-kit's one reader ($.modkit.writes).
// Each fixture is that reader's own answer, measured on 2026-11-03 with cwd /w/app (L48).
const NONE = { files: [], changes: [], unnamed: [] }

test('a shell write is judged by every file it names: a redirect, an in place edit, an emptying, a git write, a script argument, an inline target', () => {
  // `sed -i '' 's/a/b/' src/lib/slack.ts` and `: > src/big.ts`
  expect(shellTargets({ ...NONE, files: [{ word: 'src/lib/slack.ts', path: '/w/app/src/lib/slack.ts', edits: true }] })).toEqual([{ word: 'src/lib/slack.ts', path: '/w/app/src/lib/slack.ts' }])
  // `truncate -s 0 src/big.ts`
  expect(shellTargets({ ...NONE, changes: [{ word: 'src/big.ts', path: '/w/app/src/big.ts', does: 'truncate' }] })).toEqual([{ word: 'src/big.ts', path: '/w/app/src/big.ts' }])
  // `git checkout -- src/big.ts`: git marks every pathspec as reaching a whole folder, as it may.
  expect(shellTargets({ ...NONE, byGit: [{ word: 'src/big.ts', path: '/w/app/src/big.ts', does: 'write', tree: true, from: '' }] })).toEqual([{ word: 'src/big.ts', path: '/w/app/src/big.ts', tree: true }])
  // `python3 gen.py src/big.ts`
  expect(shellTargets({ ...NONE, runs: [{ what: 'a python3 script', script: 'gen.py', path: '/w/app/gen.py', args: [{ word: 'src/big.ts', path: '/w/app/src/big.ts' }] }] })).toEqual([{ word: 'src/big.ts', path: '/w/app/src/big.ts', run: { what: 'a python3 script', path: '/w/app/gen.py' } }])
  // `python3 -c "open('src/lib/slack.ts','w').write('x')"`
  expect(shellTargets({ ...NONE, unnamed: [{ what: 'an inline python3 script', words: ['python3', '-c', '...'], inputs: [], targets: ['/w/app/src/lib/slack.ts'], folder: '/w/app' }] })).toEqual([{ word: '/w/app/src/lib/slack.ts', path: '/w/app/src/lib/slack.ts' }])
})

test('a removal, a stamp, a new folder or a mode change adds no lines, so it is not judged; nor is a command that writes nothing', () => {
  for (const does of ['remove', 'touch', 'folder', 'mode'] as const) expect(shellTargets({ ...NONE, changes: [{ word: 'src/big.ts', path: '/w/app/src/big.ts', does }] })).toEqual([])
  expect(shellTargets({ ...NONE, byGit: [{ word: 'src/big.ts', path: '/w/app/src/big.ts', does: 'remove' }] })).toEqual([])
  // `npm test`, `git commit -F /tmp/msg.txt`
  expect(shellTargets(NONE)).toEqual([])
})

test('a shell write whose file cannot be named is unread, with why; a name that can only be no source file is left out', () => {
  // `echo hi > "$OUT/big.ts"`
  const [built] = shellTargets({ ...NONE, files: [{ word: '$OUT/big.ts' }] })
  expect(built).toMatchObject({ word: '$OUT/big.ts' })
  expect((built as { unread: string }).unread).toContain('$OUT/big.ts')
  // `perl -pi -e 's/a/b/' src/*.ts`
  expect(shellTargets({ ...NONE, files: [{ word: 'src/*.ts', folder: '/w/app/src', edits: true }] })[0]).toHaveProperty('unread')
  // `git apply /tmp/p.patch`, and a node script handed its file name it builds itself
  expect((shellTargets({ ...NONE, unnamed: [{ what: 'a patch', words: ['git', 'apply', '/tmp/p.patch'], inputs: ['/tmp/p.patch'] }] })[0] as { unread: string }).unread).toContain('a patch')
  expect(shellTargets({ ...NONE, unnamed: [{ what: 'an inline node script', words: ['node', '-e', '...', 'src/big.ts'], inputs: [], folder: '/w/app' }] })[0]).toHaveProperty('unread')
  // A git pathspec matched across folders, and a script handed a pattern.
  expect(shellTargets({ ...NONE, byGit: [{ word: ':/big.ts', does: 'write' }] })[0]).toHaveProperty('unread')
  expect(shellTargets({ ...NONE, runs: [{ what: 'a python3 script', script: 'gen.py', args: [{ word: 'src/*.ts', folder: '/w/app/src' }] }] })[0]).toHaveProperty('unread')
  // `echo hi > "$OUT/log.txt"`: whatever $OUT is, a .txt file is never judged.
  expect(shellTargets({ ...NONE, files: [{ word: '$OUT/log.txt' }] })).toEqual([])
  expect(shellTargets({ ...NONE, files: [{ word: 'notes/*.md', folder: '/w/app/notes' }] })).toEqual([])
})

// #2254: `bash ~/.claude/hooks/lib/issue-spool.sh note . "<finding>" "<who>"`, as mod-kit's reader
// answers it with cwd /w/app and home /Users/dan (measured 2026-11-04): the finding, holding $PWD and
// *.ts, has no path, so it was judged a file built as the command runs.
const FINDING = { word: 'reads $PWD and every *.ts file it holds, so why?' }
const noteRun = (what: string, path: string, verb = 'note') => ({
  what,
  script: '~/.claude/hooks/lib/issue-spool.sh',
  path,
  args: [{ word: verb, path: `/w/app/${verb}` }, { word: '.', path: '/w/app' }, FINDING, { word: 'builder 2254', path: '/w/app/builder 2254' }],
})
const SPOOL = '/Users/dan/.claude/hooks/lib/issue-spool.sh'

test("a findings note to the installed spool helper writes no file of the repository, so its words are not judged (#2254)", () => {
  expect(shellTargets({ ...NONE, runs: [noteRun('a bash script file', SPOOL)] }, '/Users/dan')).toEqual([])
  // `~/.claude/hooks/lib/issue-spool.sh note ...`, run directly.
  expect(shellTargets({ ...NONE, runs: [noteRun('a script file run directly', SPOOL)] }, '/Users/dan')).toEqual([])
  // Anything else in the same command is still judged: `<note> && sed -i '' 's/a/b/' src/lib/slack.ts`.
  expect(shellTargets({ ...NONE, files: [{ word: 'src/lib/slack.ts', path: '/w/app/src/lib/slack.ts', edits: true }], runs: [noteRun('a bash script file', SPOOL)] }, '/Users/dan')).toEqual([{ word: 'src/lib/slack.ts', path: '/w/app/src/lib/slack.ts' }])
})

test('only the installed helper, only its note, and only with a home known: every other run is judged as before (#2254)', () => {
  const unread = (t: ShellTarget[]) => t.filter(x => 'unread' in x).map(x => x.word)
  // No home given: nothing is exempt.
  expect(unread(shellTargets({ ...NONE, runs: [noteRun('a bash script file', SPOOL)] }))).toEqual([FINDING.word])
  // A copy of the helper inside a checkout, which may be any script.
  expect(unread(shellTargets({ ...NONE, runs: [noteRun('a bash script file', '/w/app/payload/hooks/lib/issue-spool.sh')] }, '/Users/dan'))).toEqual([FINDING.word])
  // Another subcommand of the installed helper.
  expect(unread(shellTargets({ ...NONE, runs: [noteRun('a bash script file', SPOOL, 'append')] }, '/Users/dan'))).toEqual([FINDING.word])
  // The helper handed to another interpreter.
  expect(unread(shellTargets({ ...NONE, runs: [noteRun('a python3 script', SPOOL)] }, '/Users/dan'))).toEqual([FINDING.word])
})

// #2255: `python3 probe.py 'src/*.ts'`, as mod-kit's reader answers it with cwd /w/app (measured
// 2026-11-05): a pattern whose every pattern character is quoted, which the shell matched against no file.
const QUOTED = { word: 'src/*.ts', folder: '/w/app/src', quoted: true as const }
const probe = (args: object[], tool?: true) => ({ ...NONE, runs: [{ what: 'a python3 script file', script: 'probe.py', path: '/w/app/probe.py', ...(tool ? { tool } : {}), args }] }) as Parameters<typeof shellTargets>[0]

test('a quoted pattern handed to a script file is judged as the one file its characters name (#2255)', () => {
  expect(shellTargets(probe([QUOTED]))).toEqual([{ word: 'src/*.ts', path: '/w/app/src/*.ts' }])
  // Prose holding a wildcard and a question mark, matched in the folder the command runs in.
  expect(shellTargets(probe([{ word: 'every *.ts file, why?', folder: '/w/app', quoted: true }]))).toEqual([{ word: 'every *.ts file, why?', path: '/w/app/every *.ts file, why?' }])
  // Anything else the command writes is judged beside it: `python3 probe.py 'src/*.ts' > src/big.ts`.
  expect(shellTargets({ ...probe([QUOTED]), files: [{ word: 'src/big.ts', path: '/w/app/src/big.ts' }] })).toEqual([{ word: 'src/big.ts', path: '/w/app/src/big.ts' }, { word: 'src/*.ts', path: '/w/app/src/*.ts' }])
})

test('a pattern the shell or a tool may expand, a group, and one reaching across folders stay unread (#2255)', () => {
  const unread = (t: ShellTarget[]) => t.filter(x => 'unread' in x).map(x => x.word)
  // Unquoted: the shell matches it against the folder's files.
  expect(unread(shellTargets(probe([{ word: 'src/*.ts', folder: '/w/app/src' }])))).toEqual(['src/*.ts'])
  // Handed to a tool, which expands its own operands (#1815).
  expect(unread(shellTargets(probe([QUOTED], true)))).toEqual(['src/*.ts'])
  // A group, and a pattern in a folder part, whose one name the folder does not give.
  expect(unread(shellTargets(probe([{ word: '{a,b}.ts', folder: '/w/app', quoted: true }])))).toEqual(['{a,b}.ts'])
  expect(unread(shellTargets(probe([{ word: 'src/*/big.ts', folder: '/w/app/src', quoted: true }])))).toEqual(['src/*/big.ts'])
  // A value filled in as the command runs: `python3 probe.py "$OUT/*.ts"`.
  expect(unread(shellTargets(probe([{ word: '$OUT/*.ts' }])))).toEqual(['$OUT/*.ts'])
})

test('a repository could hold a file only when something there would: a fast growing file, or a structural issue at a held priority naming a file', () => {
  const issue = (n: number, priority: string | null, structural = ['tech-debt'], refs = ['src/a.ts']) => ({ n, structural, priority, refs })
  expect(couldHold({ issues: [], own: [], top: [] })).toBe(false)
  expect(couldHold({ issues: [], own: [], top: ['src/big.ts'] })).toBe(true)
  expect(couldHold({ issues: [issue(1, 'p1')], own: [], top: [] })).toBe(true)
  expect(couldHold({ issues: [issue(1, null)], own: [], top: [] })).toBe(true)
  // A p3 issue, an unlabelled one, the session's own, and one naming no file can hold nothing.
  expect(couldHold({ issues: [issue(1, 'p3'), issue(2, 'p1', []), issue(3, 'p1'), issue(4, 'p0', ['refactor'], [])], own: [3], top: [] })).toBe(false)
})

test("an unchanged resend is one key, and another command another, so a decided command is not held again", async () => {
  expect(await shellKey('python3 gen.py')).toBe(await shellKey('python3 gen.py'))
  expect(await shellKey('python3 gen.py')).not.toBe(await shellKey('python3 gen.py x'))
  expect((await shellKey('python3 gen.py')).startsWith('shell:')).toBe(true)
})

// The key the area check first used, a 32 bit FNV-1a hash of the command (#2142 lessons review).
const fnv32 = (s: string) => {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 0x01000193) >>> 0
  return h
}
// Two commands of one shape found to share that hash, by a search over the number in the name.
const TWIN_A = 'echo hi > "$OUT/a132789.ts"'
const TWIN_B = 'echo hi > "$OUT/a729192.ts"'

test('two different commands never share a key, even two a 32 bit hash of the command could not tell apart', async () => {
  expect(fnv32(TWIN_A)).toBe(fnv32(TWIN_B))
  expect(await shellKey(TWIN_A)).not.toBe(await shellKey(TWIN_B))
  // Keyed on the whole command: a full SHA-256 of its text, 64 hex digits.
  expect(await shellKey(TWIN_A)).toMatch(/^shell:[0-9a-f]{64}$/)
})

test('a tree write is judged by every tracked file under its folder that the area check could hold, and by nothing outside it', () => {
  const tracked = ['src/big.ts', 'src/lib/slack.ts', 'src/lib/util.ts', 'src/pay/stripe.ts', 'src/lib/notes.md', 'docs/x.md', 'lib/other.ts']
  const issues = [
    { n: 41, structural: ['tech-debt'], priority: 'p2', refs: ['lib/slack.ts'] },
    // An issue that is no structural one holds nothing, so it names no file here.
    { n: 7, structural: [], priority: 'p1', refs: ['src/pay/stripe.ts'] },
  ]
  // The file the issue names, the source file in its folder (the folder match), the fast growing file.
  expect(heldUnder('src', { tracked, top: ['src/big.ts'], issues })).toEqual(['src/big.ts', 'src/lib/slack.ts', 'src/lib/util.ts'])
  expect(heldUnder('src/lib', { tracked, top: ['src/big.ts'], issues })).toEqual(['src/lib/slack.ts', 'src/lib/util.ts'])
  // The whole checkout, and a folder whose name only begins like another's.
  expect(heldUnder('', { tracked, top: [], issues })).toEqual(['src/lib/slack.ts', 'src/lib/util.ts'])
  expect(heldUnder('src/li', { tracked, top: [], issues })).toEqual([])
  // A folder nothing could hold under, and a file (no tracked file sits below a file).
  expect(heldUnder('src/pay', { tracked, top: ['src/big.ts'], issues })).toEqual([])
  expect(heldUnder('src/lib/slack.ts', { tracked, top: [], issues })).toEqual([])
})

const SHELL: Held = { ...HELD, tool: 'Bash' }
const UNREAD: Held = { ...GROWTH_ONLY, tool: 'Bash', rel: '$OUT/big.ts', why: [], growth: { unread: 'not judged' }, unread: { why: 'its file is built from $OUT, which cannot be read', key: 'shell:1' } }

test("a held Bash command is named as a command that writes the file, and is sent again as a command", () => {
  const r = holdRefusal(SHELL)
  expect(r).toContain('Bash command')
  expect(r).toContain('src/lib/slack.ts')
  expect(r).toContain('Then send the Bash command again, unchanged.')
  expect(r).not.toContain('Before editing it')
})

test('a command whose file cannot be read is held saying so, and can only proceed: there is no file to fold into or restructure', () => {
  const card = holdCard(UNREAD)
  expect(card.reason).toContain('cannot be read')
  expect(card.reason).toContain('$OUT')
  expect(card.safeWay).toContain('Edit or Write')
  const r = holdRefusal(UNREAD)
  expect(r).toContain('"decision": "proceed"')
  expect(r).not.toContain('"decision": "restructure"')
  expect(r).not.toContain('"decision": "fold"')
  expect(r).toContain('Edit or Write')
  expect(decideProblem({ decision: 'restructure' }, UNREAD)).toContain('Edit or Write')
  expect(decideProblem({ decision: 'fold', issue: 41 }, UNREAD)).toContain('cannot be read')
  expect(decideProblem({ decision: 'proceed', reason: 'This command only regenerates the build log, which no issue names.' }, UNREAD)).toBeUndefined()
})

// #2407: a folder handed to a script is judged only when the script's own text can write there.
test('a script is fed to the interpreter its run names, or its #! line names, without that line, under a delimiter its text does not hold', () => {
  expect(scriptProgram({ what: 'a bash script file', path: '/w/app/s.sh' }, '#!/bin/sh\ngrep x "$1"\n')).toEqual({ command: "bash <<'AREA_CHECK_SCRIPT'\ngrep x \"$1\"\n\nAREA_CHECK_SCRIPT", name: 'bash', delimiter: 'AREA_CHECK_SCRIPT' })
  expect(scriptProgram({ what: 'a script file run directly', path: '/w/app/s.py' }, '#!/usr/bin/env -S python3 -u\nprint(1)\n')).toMatchObject({ name: 'python3' })
  expect(scriptProgram({ what: 'a script file run directly', path: '/w/app/s.sh' }, '#!/bin/zsh\nls\n')).toMatchObject({ name: 'zsh' })
  expect(scriptProgram({ what: 'a bash script file', path: '/w/app/s.sh' }, 'echo AREA_CHECK_SCRIPT\n')).toMatchObject({ delimiter: 'AREA_CHECK_SCRIPT_1' })
  // A run with nothing naming its interpreter, a module or tool, and a name that is no plain word, are unread.
  expect(scriptProgram({ what: 'a script file run directly', path: '/w/app/s.sh' }, 'ls\n')).toHaveProperty('unread')
  expect(scriptProgram({ what: 'a python3 module run with -m', tool: true }, '')).toHaveProperty('unread')
  expect(scriptProgram({ what: 'a script file run directly', path: '/w/app/s' }, '#!\nls\n')).toHaveProperty('unread')
})

test('a program mod-kit did not read, a script run in turn, or one sourced, leaves what the script writes unread', () => {
  expect(unreadPart([{ words: ['grep', 'x', '$1'] }], 'D')).toBeNull()
  expect(unreadPart([{ words: ['python3', '<<D'], program: { text: 'print(1)', stdin: true } }], 'D')).toBeNull()
  expect(unreadPart([{ words: ['frob', '<<D'] }], 'D')).toContain('frob is no interpreter')
  expect(unreadPart([{ words: ['python3', 'fix.py'], script: { files: ['fix.py'] } }], 'D')).toContain('fix.py')
  expect(unreadPart([{ words: ['./tools/fix'] }], 'D')).toContain('./tools/fix')
  expect(unreadPart([{ words: ['source', 'lib.sh'] }], 'D')).toContain('lib.sh')
})

test('a script writes there when its text writes any file the area check could judge or runs another script; none is null', () => {
  expect(scriptWrite(NONE)).toBeNull()
  // A built name that can only be no source file is none; a file it names, whatever it is, is a write.
  expect(scriptWrite({ ...NONE, files: [{ word: '$tmp/scan.log' }] })).toBeNull()
  expect(scriptWrite({ ...NONE, files: [{ word: '/tmp/scan.log', path: '/tmp/scan.log' }] })).toContain('/tmp/scan.log')
  expect(scriptWrite({ ...NONE, files: [{ word: '$1/*.ts', edits: true }] })).toContain('$1/*.ts')
  expect(scriptWrite({ ...NONE, files: [{ word: '/tmp/out.ts', path: '/tmp/out.ts' }] })).toContain('/tmp/out.ts')
  expect(scriptWrite({ ...NONE, runs: [{ what: 'a python3 script file', script: 'fix.py', args: [{ word: '$1' }] }] })).toContain('fix.py')
})

test('a path a command writes itself is that write, though a script is handed it too, in either order (#2407)', () => {
  const run = { what: 'a bash script file', script: 's.sh', path: '/w/app/s.sh', args: [{ word: 'src', path: '/w/app/src' }] }
  expect(shellTargets({ ...NONE, files: [{ word: 'src', path: '/w/app/src' }], runs: [run] })).toEqual([{ word: 'src', path: '/w/app/src' }])
  expect(shellTargets({ ...NONE, runs: [run], unnamed: [{ what: 'an inline python3 script', words: [], inputs: [], targets: ['/w/app/src'] }] })).toEqual([{ word: 'src', path: '/w/app/src' }])
})
