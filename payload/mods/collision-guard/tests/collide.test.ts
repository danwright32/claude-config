import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { editedUnder, followedFolders, insideRoot, isScratch, judgedWrites, latestRequest, namedFolder, othersEditing, othersInRepo, parseVerdict, quoteNames, wantedFiles, watchedGit, whereGit } from '../hooks/collide.ts'

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
    // A file write that reaches a folder's tree (what find -exec writes where {} stood) is judged
    // against everything under it (lessons review of #798).
    expect(judgedWrites({ files: [{ path: '/repo/src', tree: true }], changes: [] })).toEqual([{ path: '/repo/src', tree: true }])
  })
  // #1136: what git itself changes is judged too (Dan, 2026-10-13): a checkout of a path and a
  // restore write what they name, git rm and a git mv's source remove it. Each may be a folder, so
  // each is judged on everything under it, as mod-kit's reader marks it.
  test('what git changes is judged: a checkout or restore as an edit, git rm and a moved source as a removal', () => {
    const byGit = [
      { word: 'app/globals.css', path: '/repo/app/globals.css', does: 'write' as const, tree: true as const },
      { word: 'docs/old.txt', path: '/repo/docs/old.txt', does: 'write' as const },
      { word: 'notes.txt', path: '/repo/notes.txt', does: 'remove' as const },
      { word: 'src', path: '/repo/src', does: 'remove' as const, tree: true as const },
    ]
    expect(judgedWrites({ files: [], changes: [], byGit })).toEqual([
      { path: '/repo/app/globals.css', tree: true },
      { path: '/repo/docs/old.txt' },
      { path: '/repo/notes.txt', removes: true },
      { path: '/repo/src', removes: true, tree: true },
    ])
  })
  test('a git pathspec git matches across folders names no path, and is not guessed at', () => {
    expect(judgedWrites({ files: [], changes: [], byGit: [{ word: ':/app', does: 'write' } as never, { word: '*.css', does: 'remove' } as never] })).toEqual([])
  })
  test('what the words cannot name is not guessed at (#654)', () => {
    expect(judgedWrites({ files: [{ word: '$OUT' } as never], changes: [{ word: '*.txt', does: 'remove' } as never] })).toEqual([])
  })
  // #1592: a script file handed a file as its argument (mod-kit's `runs`, #1586) may write it, which
  // cannot be read before it runs, so each argument with a path is judged as an edit of it; one the
  // reader could not place (a pattern) is not guessed at, as above.
  test('a file handed to a script as its argument is an edit of it, once however often it is named', () => {
    const runs = [
      { args: [{ word: 'notes.txt', path: '/repo/notes.txt' }, { word: '*.md', folder: '/repo' } as never] },
      { args: [{ word: '/repo/notes.txt', path: '/repo/notes.txt' }, { word: 'b.txt', path: '/repo/b.txt' }] },
    ]
    expect(judgedWrites({ files: [], changes: [{ path: '/repo/b.txt', does: 'remove' }], runs })).toEqual([{ path: '/repo/b.txt', removes: true }, { path: '/repo/notes.txt' }])
  })
  // #3323: a program mod-kit's reader does not know, handed a word that spells a path, is given as
  // a run marked unknown. Each such path is judged, and marked with the program so the guard can
  // say which and leave it out of this session's edits. A path a script, or a write the words name,
  // also reaches is an edit as before, whichever came first.
  test('a file handed to a program the write reader does not know is judged and marked with the program; one a script or a write also names is an edit', () => {
    const what = 'a program the write reader does not know'
    const by = { program: 'prettier', what }
    const prettier = { unknown: true as const, script: 'prettier', what, args: [{ path: '/repo/notes.txt' }, { path: '/repo/pr' }, { path: '/repo/b.txt' }] }
    const script = { args: [{ path: '/repo/b.txt' }] }
    expect(judgedWrites({ files: [], changes: [], runs: [prettier, script] })).toEqual([{ path: '/repo/notes.txt', unknown: by }, { path: '/repo/pr', unknown: by }, { path: '/repo/b.txt' }])
    expect(judgedWrites({ files: [], changes: [], runs: [script, prettier] })).toEqual([{ path: '/repo/b.txt' }, { path: '/repo/notes.txt', unknown: by }, { path: '/repo/pr', unknown: by }])
    expect(judgedWrites({ files: [{ path: '/repo/notes.txt' }], changes: [{ path: '/repo/pr', does: 'remove' }], runs: [prettier] })).toEqual([{ path: '/repo/notes.txt' }, { path: '/repo/pr', removes: true }, { path: '/repo/b.txt', unknown: by }])
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
    expect(isScratch(`${'/Users'}/dan/Apps/other/a.ts`, '/var/folders/ab/T/')).toBe(false)
    expect(isScratch('/tmpfiles/a.ts', undefined)).toBe(false)
    expect(isScratch('/repo/tmp/a.ts', 'relative/tmp')).toBe(false)
  })
})

// #700: a message between sessions carries text only, so the files it names are written so they
// read back whole: each a quoted string, which a comma, a space, a quote or Dan's curly apostrophe
// inside a name cannot break.
describe('the files a message to another session names', () => {
  const names = ['src/Notes, draft.md', `${'/Users'}/dan/Documents/Documents - Dan\u2019s MacBook Pro/app.ts`, 'say "hi".md', 'odd while you are working on it.md']
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

// #3398: git acts on the repository a command names, never on the folder the call was typed in.
describe('where a watched git command is put to git (#3398)', () => {
  const plain = { dir: undefined }
  test('a folder is handed to git as the shell leaves it, or not at all', () => {
    expect(namedFolder('/other', '/h/d')).toBe('/other')
    expect(namedFolder('sub/x', '/h/d')).toBe('sub/x')
    expect(namedFolder('~', '/h/d')).toBe('/h/d')
    expect(namedFolder('~/other', '/h/d/')).toBe('/h/d/other')
    expect(namedFolder('$HOME/other', '/h/d')).toBe('/h/d/other')
    expect(namedFolder('${HOME}/other', '/h/d')).toBe('/h/d/other')
    // The shell fills these in, so git asked about the characters would answer for another folder.
    for (const v of ['$X', '${X}/a', '$(pwd)', '`pwd`', 'a*', 'a?', '[ab]', '{a,b}', '~dan/x', '$HOMEX/a', '']) expect(namedFolder(v, '/h/d')).toBeUndefined()
    // Home is needed and not known.
    expect(namedFolder('~/other', '')).toBeUndefined()
  })
  test('the folder it runs in, exactly as the guard always asked (the controls)', () => {
    expect(whereGit(plain, '/repo', '/repo', '', 'git checkout main')).toEqual({ at: ['-C', '/repo'], apart: [], asToday: true })
    expect(whereGit({ dir: '/other' }, '/repo', '/repo', '', 'git -C /other checkout main')).toEqual({ at: ['-C', '/other'], apart: [], asToday: true })
    expect(whereGit({ dir: 'sub' }, '/repo', '/repo', '', 'git -C sub checkout main')).toEqual({ at: ['-C', '/repo', '-C', 'sub'], apart: [], asToday: true })
    // An absolute -C is where git runs whatever cd came before it.
    expect(whereGit({ dir: '/other' }, '/far', '/repo', '', 'cd /far && git -C /other checkout main')).toEqual({ at: ['-C', '/other'], apart: [], asToday: true })
    expect(whereGit({ dir: '/other' }, null, '/repo', '', 'cd "$X" && git -C /other checkout main')).toEqual({ at: ['-C', '/other'], apart: [], asToday: true })
    // An empty -C changes nothing, as git reads it.
    expect(whereGit({ dir: '' }, '/repo', '/repo', '', 'git -C "" checkout main')).toEqual({ at: ['-C', '/repo'], apart: [], asToday: true })
  })
  test('a cd before it, and a relative -C after one, are read from where the cd leaves the shell', () => {
    expect(whereGit(plain, '/other', '/repo', '', 'cd /other && git checkout main')).toEqual({ at: ['-C', '/other'], apart: [], asToday: false })
    expect(whereGit({ dir: 'sub' }, '/other', '/repo', '', 'cd /other && git -C sub checkout main')).toEqual({ at: ['-C', '/other', '-C', 'sub'], apart: [], asToday: false })
  })
  test('more than one -C is put as mod-kit chains them, never as the last one alone', () => {
    expect(whereGit({ dir: 'sub', chained: '/other/sub' }, '/repo', '/repo', '', 'git -C /other -C sub checkout main')).toEqual({ at: ['-C', '/other/sub'], apart: [], asToday: false })
    expect(whereGit({ dir: 'b', chained: 'a/b' }, '/repo', '/repo', '', 'git -C a -C b checkout main')).toEqual({ at: ['-C', '/repo', '-C', 'a/b'], apart: [], asToday: false })
  })
  test('a home folder is written out, which git does not do for itself', () => {
    expect(whereGit({ dir: '~/other' }, '/repo', '/repo', '/h/d', 'git -C ~/other checkout main')).toEqual({ at: ['-C', '/h/d/other'], apart: [], asToday: false })
  })
  test('the repository and the working folder it names apart are handed to git as written', () => {
    expect(whereGit({ dir: undefined, gitDir: '/other/.git', workTree: '/other' }, '/repo', '/repo', '', 'git --git-dir=/other/.git --work-tree=/other checkout main')).toEqual({
      at: ['-C', '/repo'],
      apart: ['--git-dir=/other/.git', '--work-tree=/other'],
      asToday: true,
    })
    // A relative one is git's to read, from the folder every -C leads to.
    expect(whereGit({ dir: '/w/a', gitDir: '../other/.git' }, '/repo', '/repo', '', 'git -C /w/a --git-dir=../other/.git checkout main')).toEqual({ at: ['-C', '/w/a'], apart: ['--git-dir=../other/.git'], asToday: true })
    expect(whereGit({ dir: undefined, workTree: '~/w' }, '/repo', '/repo', '/h/d', 'GIT_WORK_TREE=~/w git checkout main')).toEqual({ at: ['-C', '/repo'], apart: ['--work-tree=/h/d/w'], asToday: true })
  })
  test('what the guard cannot tell is said, never guessed', () => {
    const why = (w: ReturnType<typeof whereGit>) => ('unknown' in w ? w.unknown : 'known')
    expect(why(whereGit({ dir: '$X' }, '/repo', '/repo', '', 'git -C "$X" checkout main'))).toBe('the shell fills in the folder -C names ($X)')
    expect(why(whereGit({ dir: '$B', chained: null }, '/repo', '/repo', '', 'git -C /a -C "$B" checkout main'))).toBe('its -C options lead to a folder the shell fills in')
    expect(why(whereGit(plain, null, '/repo', '', 'cd "$X" && git checkout main'))).toBe('the cd before it cannot be followed')
    expect(why(whereGit({ dir: 'sub' }, null, '/repo', '', 'cd "$X" && git -C sub checkout main'))).toBe('the cd before it cannot be followed')
    expect(why(whereGit({ dir: undefined, gitDir: '$G' }, '/repo', '/repo', '', 'git --git-dir="$G" checkout main'))).toBe('it names its repository as $G, which the guard cannot follow to a folder')
    expect(why(whereGit({ dir: undefined, workTree: '' }, '/repo', '/repo', '', 'git --work-tree= checkout main'))).toBe('it names its working folder as nothing, which the guard cannot follow to a folder')
    expect(why(whereGit({ dir: '~/other' }, '/repo', '/repo', '', 'git -C ~/other checkout main'))).toBe('the shell fills in the folder -C names (~/other)')
    // Either variable named anywhere but on the git command itself: git reads it only if exported.
    expect(why(whereGit(plain, '/repo', '/repo', '', 'export GIT_DIR=/other/.git; git checkout main'))).toBe('the call names GIT_DIR somewhere other than as a setting on the git command itself')
    expect(why(whereGit(plain, '/repo', '/repo', '', 'GIT_WORK_TREE=/w; git checkout main'))).toBe('the call names GIT_WORK_TREE somewhere other than as a setting on the git command itself')
    // Named on the command itself, it is read and nothing is unknown.
    expect(why(whereGit({ dir: undefined, gitDir: '/other/.git' }, '/repo', '/repo', '', 'GIT_DIR=/other/.git git checkout main'))).toBe('known')
  })
})

// #3398 (Dan, 2026-11-22: "Follow the variable first"): the folder a -C names with a variable the
// call itself set is read as the value mod-kit's reader gives for that word, so the command is
// judged by the folder it really names. Only a -C of git's own is read so.
describe('a git command read with the folder its -C variable holds (#3398)', () => {
  const g = (sub: string | undefined, ...args: string[]) => ({ sub, args })
  test('the value mod-kit gives for the word after a -C stands in its place', () => {
    expect(followedFolders(['git', '-C', '$W', 'checkout', 'main'], [null, null, '/other', null, null], g('checkout', 'main'))).toEqual(['git', '-C', '/other', 'checkout', 'main'])
    // Each -C of a chain, and one after another of git's own options.
    expect(followedFolders(['git', '-C', '$A', '-C', '$B', 'reset', '--hard'], [null, null, '/a', null, 'b', null, null], g('reset', '--hard'))).toEqual(['git', '-C', '/a', '-C', 'b', 'reset', '--hard'])
    expect(followedFolders(['git', '-c', 'core.x=y', '-C', '$W', 'stash', 'pop'], [null, null, null, null, '/other', null, null], g('stash', 'pop'))).toEqual(['git', '-c', 'core.x=y', '-C', '/other', 'stash', 'pop'])
  })
  test('nothing mod-kit followed, or no value for the folder word, changes no word', () => {
    expect(followedFolders(['git', '-C', '$W', 'checkout', 'main'], undefined, g('checkout', 'main'))).toBeUndefined()
    expect(followedFolders(['git', '-C', '$W', 'checkout', 'main'], [null, null, null, null, null], g('checkout', 'main'))).toBeUndefined()
    expect(followedFolders(['git', '-C', '/other', 'checkout', 'main'], [null, null, null, null, null], g('checkout', 'main'))).toBeUndefined()
  })
  test("a value for any other word is not read: a subcommand's own -C names a branch, and a word no -C comes before names no folder", () => {
    // git switch -C makes or resets the branch named after it.
    expect(followedFolders(['git', 'switch', '-C', '$B'], [null, null, null, 'main'], g('switch', '-C', '$B'))).toBeUndefined()
    expect(followedFolders(['git', '-C', '/repo', 'checkout', '$B'], [null, null, null, null, 'main'], g('checkout', '$B'))).toBeUndefined()
    // Where -C is the value another option takes, the word after it is the subcommand.
    expect(followedFolders(['git', '-c', '-C', '$W', 'main'], [null, null, null, 'checkout', null], g('$W', 'main'))).toBeUndefined()
    expect(followedFolders(['git', '--git-dir', '$G', 'checkout', 'main'], [null, null, '/other/.git', null, null], g('checkout', 'main'))).toBeUndefined()
  })
})
