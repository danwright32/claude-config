import { describe, expect, test } from 'claude-code/testing'
import { editedUnder, insideRoot, latestRequest, othersEditing, othersInRepo, parseVerdict, shellWrites, watchedGit } from '../hooks/collide.ts'

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

// #654: the files a shell command writes, read from the words mod-kit's command reader gives. A
// test cannot import another mod, so each case is written as the words the reader returns for it,
// which mod-kit's own tests pin (tests/commands.test.ts, "an output redirect is its own word").
describe('the files a shell command writes', () => {
  const writes = (cmds: string[][], cwd = '/repo') => shellWrites(cmds, cwd, '/Users/dan')
  const paths = (cmds: string[][], cwd = '/repo') => writes(cmds, cwd).map(w => w.path)

  test("the live check's printf append (#639): printf 'one more line\\n' >> notes.txt", () => {
    expect(paths([['printf', 'one more line\\n', '>>', 'notes.txt']])).toEqual(['/repo/notes.txt'])
  })
  test('every output redirect, and never a descriptor or /dev/null', () => {
    expect(paths([['echo', 'a', '>', 'a.txt'], ['make', '2>', 'err.log'], ['ls', '&>', 'all.log'], ['ls', '&>>', 'more.log'], ['echo', '>|', 'c.txt']])).toEqual([
      '/repo/a.txt',
      '/repo/err.log',
      '/repo/all.log',
      '/repo/more.log',
      '/repo/c.txt',
    ])
    expect(paths([['make', '2>&1', '>', '/dev/null']])).toEqual([])
  })
  test('tee, in place sed and perl, and touch', () => {
    expect(paths([['printf', 'x'], ['tee', '-a', 'log.txt', '/abs/two.txt']])).toEqual(['/repo/log.txt', '/abs/two.txt'])
    expect(paths([['sed', '-i', '', 's/a/b/', 'src/a.ts', 'src/b.ts']])).toEqual(['/repo/src/a.ts', '/repo/src/b.ts'])
    expect(paths([['sed', '-i.bak', '-e', 's/a/b/', '-e', 's/c/d/', 'x.txt']])).toEqual(['/repo/x.txt'])
    expect(paths([['sed', '--in-place', 's/a/b/', 'z.txt']])).toEqual(['/repo/z.txt'])
    expect(paths([['perl', '-pi', '-e', 's/a/b/', 'y.txt']])).toEqual(['/repo/y.txt'])
    expect(paths([['perl', '-i.bak', '-pe', 's/a/b/', 'w.txt']])).toEqual(['/repo/w.txt'])
    expect(paths([['touch', '-t', '202601010000', 'new.md', 'other.md']])).toEqual(['/repo/new.md', '/repo/other.md'])
  })
  test('cp writes its destination, mv its destination and its sources', () => {
    expect(writes([['cp', 'a.txt', 'b.txt']])).toEqual([{ path: '/repo/b.txt', sources: ['/repo/a.txt'] }])
    expect(paths([['cp', 'a.txt', 'b.txt', 'dir/']])).toEqual(['/repo/dir/a.txt', '/repo/dir/b.txt'])
    expect(paths([['cp', '-t', 'dest', 'a.txt']])).toEqual(['/repo/dest/a.txt'])
    expect(paths([['mv', 'old.txt', 'new/']])).toEqual(['/repo/new/old.txt', '/repo/old.txt'])
  })
  test('a cd earlier in the command moves where a relative path lands, and ~ is home', () => {
    expect(paths([['cd', 'sub'], ['echo', 'x', '>>', '../up.txt'], ['echo', 'y', '>', 'here.txt']])).toEqual(['/repo/up.txt', '/repo/sub/here.txt'])
    expect(paths([['echo', 'x', '>', '~/notes.txt']])).toEqual(['/Users/dan/notes.txt'])
    // cd - goes back to a folder nothing here knows, so a relative path after it is not named.
    expect(paths([['cd', '-'], ['echo', 'x', '>', 'rel.txt'], ['echo', 'y', '>', '/abs/a.txt']])).toEqual(['/abs/a.txt'])
  })
  test('one file written twice is named once', () => {
    expect(paths([['echo', 'a', '>', 'n.txt'], ['echo', 'b', '>>', 'n.txt']])).toEqual(['/repo/n.txt'])
  })
  test('a read only command writes nothing', () => {
    expect(paths([['cat', 'notes.txt'], ['grep', 'x'], ['sed', '-n', '1,5p', 'notes.txt'], ['ls', '-la'], ['git', 'diff'], ['perl', '-ne', 'print', 'notes.txt'], ['wc', '<', 'notes.txt']])).toEqual([])
    // The i in -Ilib is part of the include folder, not -i.
    expect(paths([['perl', '-Ilib', 'script.pl', 'x.txt']])).toEqual([])
  })
  // Decided (docs/mods-design.md, #654): what the reader cannot name is not guessed at.
  test('a path it cannot name, and a script, write nothing it can see', () => {
    expect(paths([['echo', 'x', '>', '$OUT'], ['echo', 'y', '>', '*.txt'], ['cd', '$DIR'], ['echo', 'z', '>', 'rel.txt']])).toEqual([])
    expect(paths([['python3', '-c', "open('notes.txt','a').write('x')"], ['bash', './update.sh']])).toEqual([])
    // A redirect with nothing after it names no file.
    expect(paths([['echo', 'x', '>']])).toEqual([])
  })
  // #674: rm takes a file away, the most destructive write, so it is named too.
  test('rm and unlink name each file they remove', () => {
    expect(writes([['rm', 'notes.txt', '/abs/b.txt']])).toEqual([
      { path: '/repo/notes.txt', removes: true },
      { path: '/abs/b.txt', removes: true },
    ])
    expect(writes([['rm', '-f', '--', '-odd.txt']])).toEqual([{ path: '/repo/-odd.txt', removes: true }])
    expect(writes([['unlink', 'x.txt']])).toEqual([{ path: '/repo/x.txt', removes: true }])
  })
  test('rm -r names a folder and everything under it, in any spelling', () => {
    for (const flag of ['-r', '-R', '-rf', '-fR', '--recursive']) {
      expect(writes([['rm', flag, 'src/']])).toEqual([{ path: '/repo/src', removes: true, tree: true }])
    }
    expect(writes([['cd', 'sub'], ['rm', '-rf', '..']])).toEqual([{ path: '/repo', removes: true, tree: true }])
  })
  test('a path written and then removed keeps the removal (lessons review of #691)', () => {
    expect(writes([['echo', 'x', '>', 'd'], ['rm', '-r', 'd']])).toEqual([{ path: '/repo/d', removes: true, tree: true }])
    expect(writes([['rm', 'f'], ['rm', '-r', 'f']])).toEqual([{ path: '/repo/f', removes: true, tree: true }])
  })
  test('mv takes its sources away whole, a folder with everything under it (lessons review of #691)', () => {
    expect(writes([['mv', 'src', '/elsewhere/']])).toEqual([
      { path: '/elsewhere/src' },
      { path: '/repo/src', removes: true, tree: true },
    ])
  })
  test('an rm of a glob or a variable is not guessed at (#654)', () => {
    expect(paths([['rm', '*.txt'], ['rm', '-rf', '$DIR']])).toEqual([])
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
