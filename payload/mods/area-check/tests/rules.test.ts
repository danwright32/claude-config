import { expect, test } from 'claude-code/testing'
import {
  DEADLINE_MS,
  BUDGET_MS,
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
} from '../hooks/rules.ts'

// The area check (#1506, phase 1 #1508): the facts about a file at the moment a session first edits
// it, computed purely here so each rule is tested on its own. Phase 1 only observes: these facts
// decide what is LOGGED (would_hold or quiet), never what is refused.

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
  // A shell write is not judged, so restructuring itself (git mv, a script) is never obstructed.
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
  expect(rankingKey('o/r', 'abc', Date.UTC(2026, 9, 22, 23, 0))).toBe('o/r abc 2026-10-22 v1')
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
