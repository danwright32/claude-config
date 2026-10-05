import { describe, expect, test } from 'claude-code/testing'
import { editedUnder, insideRoot, isScratch, judgedWrites, latestRequest, othersEditing, othersInRepo, parseVerdict, quoteNames, wantedFiles, watchedGit } from '../hooks/collide.ts'

const rec = (id: string, over: Partial<{ repoRoot: string | null; edits: string[] }> = {}) => ({
  v: 1 as const,
  sessionId: id,
  cwd: '/repo',
  repoRoot: '/repo',
  startedAt: 0,
  lastSeen: 0,
  closedAt: null,
  transcriptPath: null,
  edits: [],
  extra: {},
  ...over,
})

describe('which git commands are checkout wide (the spec list)', () => {
  const watched: [string, { sub: string; args: string[] }, string][] = [
    ['checkout', { sub: 'checkout', args: ['main'] }, 'git checkout main'],
    ['switch', { sub: 'switch', args: ['-c', 'x'] }, 'git switch -c x'],
    ['branch -D', { sub: 'branch', args: ['-D', 'feat'] }, 'git branch -D feat'],
    ['branch --delete --force', { sub: 'branch', args: ['--delete', '--force', 'feat'] }, 'git branch --delete --force feat'],
    ['reset --hard', { sub: 'reset', args: ['--hard', 'origin/main'] }, 'git reset --hard origin/main'],
    ['stash pop', { sub: 'stash', args: ['pop'] }, 'git stash pop'],
    ['add -A', { sub: 'add', args: ['-A'] }, 'git add -A'],
    ['add .', { sub: 'add', args: ['.'] }, 'git add .'],
    ['add --all', { sub: 'add', args: ['--all'] }, 'git add --all'],
    // Discards every change in the checkout, though it carries -- (lessons review of #632).
    ['checkout -- .', { sub: 'checkout', args: ['--', '.'] }, 'git checkout -- .'],
    ['checkout HEAD -- a folder', { sub: 'checkout', args: ['HEAD', '--', 'src/'] }, 'git checkout HEAD -- src/'],
    ['branch -df', { sub: 'branch', args: ['-df', 'feat'] }, 'git branch -df feat'],
    ['branch -d -f', { sub: 'branch', args: ['-d', '-f', 'feat'] }, 'git branch -d -f feat'],
    ['branch --delete -f', { sub: 'branch', args: ['--delete', '-f', 'feat'] }, 'git branch --delete -f feat'],
  ]
  for (const [name, g, label] of watched) test(`${name} is watched`, () => expect(watchedGit(g)).toBe(label))

  const fine: [string, { sub: string | undefined; args: string[] }][] = [
    ['status', { sub: 'status', args: [] }],
    ['add of named paths', { sub: 'add', args: ['src/a.ts'] }],
    ['branch -d of a merged branch', { sub: 'branch', args: ['-d', 'old'] }],
    ['reset of the index only', { sub: 'reset', args: ['HEAD', 'a.ts'] }],
    ['stash push', { sub: 'stash', args: ['push', '-m', 'x'] }],
    ['a checkout of one file back', { sub: 'checkout', args: ['HEAD', '--', 'a.ts'] }],
  ]
  for (const [name, g] of fine) test(`${name} is not watched`, () => expect(watchedGit(g)).toBeUndefined())
})

describe('who else is there', () => {
  const open = [rec('me', { edits: ['/repo/a.ts'] }), rec('them', { edits: ['/repo/a.ts', '/repo/b.ts'] }), rec('elsewhere', { repoRoot: '/other', edits: ['/other/a.ts'] })]
  test('other open sessions that edited the file, never this one', () => {
    expect(othersEditing(open, 'me', '/repo/a.ts').map(r => r.sessionId)).toEqual(['them'])
    expect(othersEditing(open, 'me', '/repo/c.ts')).toEqual([])
  })
  test('a subagent of this same session is this session, so never a collision', () => {
    expect(othersEditing([rec('me', { edits: ['/repo/a.ts'] })], 'me', '/repo/a.ts')).toEqual([])
  })
  test('a session whose repository could not be read still counts when its folder is inside the checkout (lessons check)', () => {
    const unknown = [rec('me'), { ...rec('lost', { repoRoot: null }), cwd: '/repo/app' }, { ...rec('away', { repoRoot: null }), cwd: '/repository-else' }]
    expect(othersInRepo(unknown, 'me', '/repo').map(r => r.sessionId)).toEqual(['lost'])
  })
  test('other open sessions in the same checkout', () => {
    expect(othersInRepo(open, 'me', '/repo').map(r => r.sessionId)).toEqual(['them'])
    expect(othersInRepo(open, 'me', null)).toEqual([])
  })
})

describe('the verdict', () => {
  test('each verdict is read with its reason', () => {
    expect(parseVerdict('{"verdict":"Proceed","reason":"They only read it."}')).toEqual({ verdict: 'Proceed', reason: 'They only read it.' })
    expect(parseVerdict('Here: {"verdict": "Worktree", "reason": "Both change the header."}')).toEqual({ verdict: 'Worktree', reason: 'Both change the header.' })
    expect(parseVerdict('{"verdict":"Stop","reason":"They are mid rebase."}')?.verdict).toBe('Stop')
  })
  test('anything else is no verdict, which the guard treats as Stop (L42)', () => {
    expect(parseVerdict('Proceed, it is fine')).toBeUndefined()
    expect(parseVerdict('{"verdict":"Maybe","reason":"x"}')).toBeUndefined()
    expect(parseVerdict('{"verdict":"Proceed"}')).toBeUndefined()
    expect(parseVerdict('')).toBeUndefined()
  })
})

describe("the other session's latest request, from its transcript", () => {
  const line = (o: unknown) => JSON.stringify(o)
  test('the last thing typed, past tool results and replies', () => {
    const tail = [
      line({ type: 'user', message: { role: 'user', content: 'first ask' } }),
      line({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'ok' }] } }),
      line({ type: 'user', message: { role: 'user', content: [{ type: 'text', text: 'tidy the invoice table' }] } }),
      line({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't', content: 'done' }] } }),
    ].join('\n')
    expect(latestRequest(tail)).toBe('tidy the invoice table')
  })
  test('a tail that starts mid line still reads', () => {
    expect(latestRequest('ial line\n' + line({ type: 'user', message: { role: 'user', content: 'x' } }))).toBe('x')
  })
  test('nothing typed reads as nothing', () => {
    expect(latestRequest('')).toBeUndefined()
  })
})

// #654: the files a shell command writes, read by mod-kit's write reader since #712, and judged
// here as this guard judges them. Which files each command names is the reader's, and every case
// this guard's own reader had moved to mod-kit's tests with it (tests/writes.test.ts: redirects
// and `>&`, tee, sed, perl and touch, cp and mv into a folder, a cd, a subshell, a file named twice,
// read only commands, what cannot be named, rm, rm -r in every spelling, mv's sources, a glob), so
// these pin only the judging: what is an edit, what a removal, what is left alone.
describe('the files a shell command writes, as this guard judges them', () => {
  const none = { files: [], changes: [] }
  test('a file content goes into is an edit, its sources kept only where the copy may land inside it', () => {
    expect(judgedWrites({ ...none, files: [{ path: '/repo/a.txt' }, { path: '/repo/b.txt', sources: ['/repo/a.txt'], mayBeFolder: true }, { path: '/repo/dir/c.txt', sources: ['/repo/c.txt'] }] })).toEqual([
      { path: '/repo/a.txt' },
      { path: '/repo/b.txt', sources: ['/repo/a.txt'] },
      { path: '/repo/dir/c.txt' },
    ])
  })
  test('a file stamped or emptied is an edit; a folder made or a mode changed is left alone', () => {
    const changes = [
      { path: '/repo/new.md', does: 'touch' },
      { path: '/repo/log.txt', does: 'truncate' },
      { path: '/repo/lib', does: 'folder' },
      { path: '/repo/run.sh', does: 'mode' },
    ]
    expect(judgedWrites({ files: [], changes })).toEqual([{ path: '/repo/new.md' }, { path: '/repo/log.txt' }])
  })
  test('a removal is judged as one, a folder with everything under it where the reader says so', () => {
    expect(judgedWrites({ files: [], changes: [{ path: '/repo/x.txt', does: 'remove' }, { path: '/repo/src', does: 'remove', tree: true }] })).toEqual([
      { path: '/repo/x.txt', removes: true },
      { path: '/repo/src', removes: true, tree: true },
    ])
  })
  test('a path written and then removed keeps the removal (lessons review of #691)', () => {
    expect(judgedWrites({ files: [{ path: '/repo/d' }], changes: [{ path: '/repo/d', does: 'remove', tree: true }] })).toEqual([{ path: '/repo/d', removes: true, tree: true }])
  })
  test('what the words cannot name is not guessed at (#654)', () => {
    expect(judgedWrites({ files: [{ word: '$OUT' } as never], changes: [{ word: '*.txt', does: 'remove' } as never] })).toEqual([])
  })
})

describe('what a removed folder holds of the other sessions', () => {
  test('every file another session edited under the folder, once, and never this session', () => {
    const open = [rec('me', { edits: ['/repo/src/mine.ts'] }), rec('a', { edits: ['/repo/src/a.ts', '/repo/srcx/no.ts'] }), rec('b', { edits: ['/repo/src/a.ts', '/repo/src/deep/b.ts'] })]
    expect(editedUnder(open, 'me', '/repo/src')).toEqual(['/repo/src/a.ts', '/repo/src/deep/b.ts'])
    expect(editedUnder(open, 'me', '/repo/other')).toEqual([])
  })
  test('the folder itself, when another session recorded it, counts', () => {
    expect(editedUnder([rec('a', { edits: ['/repo/src'] })], 'me', '/repo/src')).toEqual(['/repo/src'])
  })
  test('the root folder holds everything', () => {
    expect(editedUnder([rec('a', { edits: ['/repo/x.ts'] })], 'me', '/')).toEqual(['/repo/x.ts'])
  })
})

// #674: scratch (/tmp, the scratchpad) is not a session's edit, so it cannot push real edits out of
// the twenty the judge reads.
describe('which paths are recorded as a session edit', () => {
  test('inside the repository root only', () => {
    expect(insideRoot('/repo/src/a.ts', '/repo')).toBe(true)
    expect(insideRoot('/repo', '/repo')).toBe(true)
    expect(insideRoot('/repository/a.ts', '/repo')).toBe(false)
    expect(insideRoot('/tmp/x.txt', '/repo')).toBe(false)
    expect(insideRoot('/private/tmp/claude-501/scratchpad/n.md', '/repo')).toBe(false)
  })
})

// #700: a file edited in another checkout is recorded again, so a session working there is judged
// against it, while scratch stays out as #674 decided.
describe('scratch, which is never recorded outside the session root', () => {
  test('the temporary folders, the scratchpad under them, and TMPDIR wherever it points', () => {
    expect(isScratch('/tmp/x.txt', undefined)).toBe(true)
    expect(isScratch('/private/tmp/claude-501/s/scratchpad/700/n.md', undefined)).toBe(true)
    expect(isScratch('/var/folders/ab/T/x', undefined)).toBe(true)
    expect(isScratch('/private/var/folders/ab/T/x', undefined)).toBe(true)
    expect(isScratch('/Volumes/fast/tmp/x', '/Volumes/fast/tmp/')).toBe(true)
  })
  test('nothing else, a folder merely named like one included', () => {
    expect(isScratch('/Users/dan/Apps/other/a.ts', '/var/folders/ab/T/')).toBe(false)
    expect(isScratch('/tmpfiles/a.ts', undefined)).toBe(false)
    expect(isScratch('/repo/tmp/a.ts', 'relative/tmp')).toBe(false)
  })
})

// #700: a message between sessions carries text only, so the files it names are written so they
// read back whole: each a quoted string, which a comma, a space, a quote or Dan's curly apostrophe
// inside a name cannot break.
describe('the files a message to another session names', () => {
  const names = ['src/Notes, draft.md', '/Users/dan/Documents/Documents - Dan\u2019s MacBook Pro/app.ts', 'say "hi".md', 'odd while you are working on it.md']
  const message = (verb: string, list: string) => `Another session wanted to ${verb} ${list} while you are working on it, so it was stopped. Nothing here was touched.`
  test('are written quoted, comma separated', () => {
    expect(quoteNames(['src/a.ts', 'src/b.ts'])).toBe('"src/a.ts", "src/b.ts"')
  })
  test('and read back exactly, with the verb, whatever the names hold', () => {
    expect(wantedFiles(message('remove', quoteNames(names)))).toEqual({ verb: 'remove', names })
    expect(wantedFiles(message('edit', quoteNames(['src/app.ts'])))).toEqual({ verb: 'edit', names: ['src/app.ts'] })
  })
  test('a message from a guard before #700, its names unquoted, is still read', () => {
    expect(wantedFiles(message('edit', 'src/app.ts'))).toEqual({ verb: 'edit', names: ['src/app.ts'] })
    expect(wantedFiles(message('edit', 'src/a.ts, src/b.ts'))).toEqual({ verb: 'edit', names: ['src/a.ts', 'src/b.ts'] })
  })
  test('a message naming no file is none', () => {
    expect(wantedFiles('Another session wanted to run git checkout main in this checkout while you are working in it, so it was stopped.')).toBeUndefined()
  })
})
