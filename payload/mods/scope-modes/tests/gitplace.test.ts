import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { branchFolder, checkoutFolder, gitEnvNamed, gitFolder, gitGlobals, gitPlace, gitRead, type GitRead } from '../hooks/gitplace.ts'
import { resolveDir } from '../hooks/overnight.ts'
import { readCommands } from './read.ts'

// #3398: where a git command acts, read once for every rule in this mod that places one. Each
// command is read by mod-kit's own reader (its byte for byte copy under tests/mod-kit), with the
// settings written in front of it, as register.ts reads it in a session.
const HOME = `${'/Users'}/x`
const CWD = `${'/Users'}/x/repo`
const gitOf = (command: string): GitRead => {
  const g = readCommands(command).find(c => c.git)?.git
  if (!g) throw new Error(`no git command read in: ${command}`)
  return g
}
const place = (command: string, from: string | null = CWD) => gitPlace(gitOf(command), from, (w, f) => resolveDir(w, f, HOME), gitEnvNamed(command, readCommands(command)))

// The type check is the judge of this one (tools/check-mods.sh checks a mod's tests too): a rule
// placing a git command says, every time, whether the call names a git variable. While that had a
// default, a rule leaving it out compiled and read a variable exported earlier in the call as no
// naming at all, with nothing to say so. The call below must not compile (#3398 lessons review).
// @ts-expect-error the fourth argument, whether the call names a git variable, is required
void (() => gitPlace({ args: [] }, CWD, w => w))

describe('the reading a command carries', () => {
  test('every naming mod-kit hands on is carried, and none where the command gives none', () => {
    expect(gitOf('git status')).toEqual({ sub: 'status', args: [] })
    expect(gitOf('git -C /a log')).toEqual({ sub: 'log', args: [], dir: '/a' })
    expect(gitOf('git -C /a -C b merge y')).toEqual({ sub: 'merge', args: ['y'], dir: 'b', chained: '/a/b' })
    expect(gitOf('git -C "$A" -C b merge y')).toEqual({ sub: 'merge', args: ['y'], dir: 'b', chained: null })
    expect(gitOf('git --git-dir=/o/.git --work-tree /o checkout main')).toEqual({ sub: 'checkout', args: ['main'], gitDir: '/o/.git', workTree: '/o' })
    // The settings written in front of the command reach the reader: until #3398 none was handed to it.
    expect(gitOf('GIT_DIR=/o/.git GIT_WORK_TREE=/o git checkout main')).toEqual({ sub: 'checkout', args: ['main'], gitDir: '/o/.git', workTree: '/o' })
    expect(gitRead({ sub: undefined, args: [], dir: undefined })).toEqual({ sub: undefined, args: [] })
  })
  test("git's own words before its subcommand, by the reader's split", () => {
    const c = readCommands('git -C /a -c x=y --no-pager push -C origin')[0]
    expect(gitGlobals(c?.words ?? [], c?.git ?? { args: [] })).toEqual(['-C', '/a', '-c', 'x=y', '--no-pager'])
    const bare = readCommands('git --version')[0]
    expect(gitGlobals(bare?.words ?? [], bare?.git ?? { args: [] })).toEqual(['--version'])
  })
})

describe('where a git command runs', () => {
  test('no -C and one -C: where it always was', () => {
    expect(place('git checkout main')).toEqual({ runs: CWD, asRead: CWD })
    expect(place('git -C /other checkout main')).toEqual({ runs: '/other', asRead: '/other' })
    expect(place('git -C sub checkout main')).toEqual({ runs: `${CWD}/sub`, asRead: `${CWD}/sub` })
    expect(place('git -C ~/w checkout main')).toEqual({ runs: `${HOME}/w`, asRead: `${HOME}/w` })
    expect(place('git -C "" checkout main')).toEqual({ runs: CWD, asRead: CWD })
  })
  test('more than one -C: each is read from the one before it, and the last one alone is kept as the old reading', () => {
    expect(place('git -C /a -C b checkout main')).toEqual({ runs: '/a/b', asRead: `${CWD}/b` })
    expect(place('git -C a -C b checkout main')).toEqual({ runs: `${CWD}/a/b`, asRead: `${CWD}/b` })
    expect(place('git -C /a -C ../c checkout main')).toEqual({ runs: '/c', asRead: `${'/Users'}/x/c` })
    expect(place('git -C /a -C "" checkout main')).toEqual({ runs: '/a', asRead: CWD })
    // A chain ending in an absolute folder starts again from it: one reading.
    expect(place('git -C a -C /c checkout main')).toEqual({ runs: '/c', asRead: '/c' })
  })
  test('a folder that cannot be followed is null, never the folder the command runs in', () => {
    expect(place('git -C "$W" checkout main')).toEqual({ runs: null, asRead: null })
    expect(place('git -C "$A" -C b checkout main')).toEqual({ runs: null, asRead: `${CWD}/b` })
    expect(place('git -C /a -C "$B" checkout main')).toEqual({ runs: null, asRead: null })
    // Behind a cd that cannot be followed: a relative folder is nowhere, an absolute one is itself.
    expect(place('git checkout main', null)).toEqual({ runs: null, asRead: null })
    expect(place('git -C sub checkout main', null)).toEqual({ runs: null, asRead: null })
    expect(place('git -C /other checkout main', null)).toEqual({ runs: '/other', asRead: '/other' })
  })
  test('a repository or a working folder named apart is said, by option or by a setting in front of the command', () => {
    const repository = { repository: true, said: 'it names its repository apart from the folder it runs in (--git-dir or GIT_DIR)' }
    expect(place('git --git-dir=/o/.git checkout main').apart).toEqual(repository)
    expect(place('git --git-dir /o/.git --work-tree=/o checkout main').apart).toEqual(repository)
    expect(place('GIT_DIR=/o/.git git checkout main').apart).toEqual(repository)
    expect(place('GIT_DIR=/o/.git GIT_WORK_TREE=/o git checkout main').apart).toEqual(repository)
    expect(place('env GIT_DIR=/o/.git git checkout main').apart).toEqual(repository)
    // The working folder alone: the repository is still the one found from the folder git runs in.
    expect(place('git --work-tree=/o checkout main').apart).toEqual({ repository: false, said: 'it names its working folder apart from the folder it runs in (--work-tree or GIT_WORK_TREE)' })
    // Written as a setting, the call's text names a variable too, so the repository is not taken as told.
    expect(place('GIT_WORK_TREE=/o git checkout main').apart?.repository).toBe(true)
    expect(place('git checkout main').apart).toBeUndefined()
    expect(place('git -C /a -C b checkout main').apart).toBeUndefined()
  })
  test('a variable the call names any other way reaches git only through the shell, so every git command in it is untold', () => {
    const elsewhere = { repository: true, said: 'the call names GIT_DIR, GIT_WORK_TREE or GIT_COMMON_DIR somewhere other than as a setting on the git command itself' }
    for (const c of [
      'export GIT_DIR=/o/.git; git checkout main',
      'GIT_DIR=/o/.git; export GIT_DIR; git checkout main',
      'GIT_WORK_TREE=/o; git checkout main',
      'export GIT_COMMON_DIR=/o/.git && git checkout main',
      'read GIT_DIR; export GIT_DIR; git checkout main',
      'for GIT_DIR in /o/.git; do export GIT_DIR; git checkout main; done',
      'printf -v GIT_DIR %s /o/.git; export GIT_DIR; git checkout main',
    ])
      expect({ c, apart: place(c).apart }).toEqual({ c, apart: elsewhere })
    // Prose that only mentions one, and a read of one, name no repository.
    expect(gitEnvNamed('git commit -m "read GIT_DIR as git does" && git checkout main', readCommands('git commit -m "read GIT_DIR as git does" && git checkout main'))).toBe(false)
    expect(gitEnvNamed('echo "$GIT_DIR"; git checkout main', readCommands('echo "$GIT_DIR"; git checkout main'))).toBe(false)
    expect(gitEnvNamed('GIT_DIR=/o/.git git log', [])).toBe(true)
    expect(gitEnvNamed('git log --format=%H', readCommands('git log --format=%H'))).toBe(false)
  })
  // The review of #3532: the test for a variable given a value matched the call's text, so a commit
  // message quoting `GIT_DIR=` closed the merge rule on the push behind it and dropped the notes.
  const named = (command: string) => gitEnvNamed(command, readCommands(command))
  test('text the reader hands on as plain data names no repository: a commit message, what echo or printf prints, a pattern searched for (#3532 review)', () => {
    for (const c of [
      'git commit -m "read GIT_DIR=/o as git does" && git push',
      'git commit --message "GIT_WORK_TREE=/o is read too" && git push',
      'git commit --message="GIT_COMMON_DIR=/o" && git push',
      'git -C /other commit -am "GIT_DIR=/o"; git -C /other push',
      'echo "GIT_DIR=/o"; git push',
      "printf '%s\\n' 'GIT_DIR=/o'; git push",
      'grep -rn "GIT_DIR=" payload/mods && git push',
      "rg -n 'GIT_WORK_TREE=' payload ; git push",
      // A pipe behind another command of the call carries nothing the data command printed.
      'git commit -m "GIT_DIR=/o" && git push 2>&1 | tail -5',
      // Twice, each a word of its own.
      'echo "GIT_DIR=/o" "GIT_DIR=/o"; git push',
    ])
      expect({ c, named: named(c) }).toEqual({ c, named: false })
  })
  test('every way of really setting one still names it, wherever in the call it stands (#3532 review)', () => {
    for (const c of [
      // In front of the git command, in front of another command, and through env.
      'GIT_DIR=/o git push',
      'GIT_DIR=/o git log; git push',
      'GIT_DIR=/o make; git push',
      'env GIT_DIR=/o git push',
      // Exported or declared, with a value.
      'export GIT_DIR=/o; git push',
      'declare -x GIT_DIR=/o; git push',
      'typeset -x GIT_WORK_TREE=/o; git push',
      'readonly GIT_DIR=/o; git push',
      // Set on a line or a command of its own, before the one that exports it or after.
      'GIT_DIR=/o; git push',
      'GIT_DIR=/o\ngit push',
      'set -a; GIT_DIR=/o; git push',
      // Inside a subshell, a function, a loop, a trap.
      '(export GIT_DIR=/o; git push)',
      'f() { export GIT_DIR=/o; }; f; git push',
      'for r in a b; do export GIT_DIR=/o/$r; git push; done',
      "trap 'export GIT_DIR=/o' EXIT; git push",
      // Through eval, a here document, a file read into the shell.
      'eval "export GIT_DIR=/o"; git push',
      "eval 'GIT_DIR=/o git push'",
      "bash <<'EOT'\nexport GIT_DIR=/o\ngit push\nEOT",
      'cat > /tmp/e <<EOT\nexport GIT_DIR=/o\nEOT\n. /tmp/e; git push',
      // From another variable.
      'D=/o; export GIT_DIR=$D; git push',
      'V="GIT_DIR=/o"; export "$V"; git push',
      // As a word of a command that is no plain data.
      'make GIT_DIR=/o push; git push',
      'git -c GIT_DIR=/o push',
      'git --namespace GIT_DIR=/o push',
      // Spelled so the text never holds it whole: the reader's word does.
      'export GIT_"DIR=/o"; git push',
    ])
      expect({ c, named: named(c) }).toEqual({ c, named: true })
  })
  test('plain data that could reach something setting a variable is no plain data, and where the reader cannot say, the text is believed (#3532 review)', () => {
    for (const c of [
      // Written to a file, sent down a pipe, or run inside a substitution.
      'echo "GIT_DIR=/o" > /tmp/e; . /tmp/e; git push',
      'echo "GIT_DIR=/o" >> notes.txt; git push',
      'echo GIT_DIR=/o | xargs -I{} env {} git push',
      'echo GIT_DIR=/o | tee /tmp/e; git push',
      '{ echo GIT_DIR=/o; } | xargs -I{} env {} git push',
      'export $(echo GIT_DIR=/o); git push',
      'export `echo GIT_DIR=/o`; git push',
      'source <(echo export GIT_DIR=/o); git push',
      'read -r L < <(echo GIT_DIR=/o); export "$L"; git push',
      // Piped into a shell, whose commands the reader gives in place of the pipe, or gives none.
      'echo "GIT_DIR=/o; git push" | sh',
      'echo GIT_DIR=/o | sh; git push',
      "{ echo 'export GIT_DIR=/o'; echo 'git push'; } | sh",
      // Run behind a shell or another runner, which may change what the command is run with.
      "bash -c 'git commit -m \"GIT_DIR=/o\"; git push'",
      'sudo echo GIT_DIR=/o; git push',
      'echo "GIT_DIR=/o"; command git push',
      // Anything the shell fills in, anywhere in the call: a value may carry the text to a setter.
      'git commit -m "GIT_DIR=/o" && git push origin "$B"',
      'git commit -m "GIT_DIR=/o"; eval "$(git log -1 --format=%B)"; git push',
      // A command that runs text, or one whose name the call itself changes.
      'echo "GIT_DIR=/o"; source /tmp/e; git push',
      'echo "GIT_DIR=/o"; builtin . /tmp/e; git push',
      'echo() { export "$1"; }; echo GIT_DIR=/o; git push',
      'function echo { export "$1"; }; echo GIT_DIR=/o; git push',
      'alias echo=export; echo GIT_DIR=/o; git push',
      // The same text as plain data and as a setting.
      'echo "GIT_DIR=/o"; export GIT_DIR=/o; git push',
      'git commit -m "GIT_DIR=/o"; GIT_DIR=/o; git push',
      // Text the reader hands on to no command: a comment, a here document's body.
      'git push # GIT_DIR=/o',
      'git commit -F - <<EOT\nnote GIT_DIR=/o\nEOT\ngit push',
      // A message spelled so the text does not hold it as the reader's word does.
      "git commit -m 'it'\\''s GIT_DIR=/o' && git push",
      // Another program's words, and a commit's other values.
      'cat "GIT_DIR=/o"; git push',
      'git commit --author "GIT_DIR=/o" -m x; git push',
      'git tag -m "GIT_DIR=/o" v1; git push',
    ])
      expect({ c, named: named(c) }).toEqual({ c, named: true })
  })
  test('the one folder a rule reads: where git runs, or none where the repository cannot be told from a folder', () => {
    expect(gitFolder(place('git -C /other push'))).toBe('/other')
    expect(gitFolder(place('git -C /a -C b push'))).toBe('/a/b')
    expect(gitFolder(place('git -C "$A" -C b push'))).toBeNull()
    expect(gitFolder(place('git --git-dir=/o/.git push'))).toBeNull()
    expect(gitFolder(place('git --work-tree=/o push'))).toBeNull()
    expect(gitFolder(place('GIT_DIR=/o/.git git push'))).toBeNull()
    expect(gitFolder(place('export GIT_DIR=/o/.git; git push'))).toBeNull()
  })
})

describe('the folders the notes kept for winding down read', () => {
  const branch = (command: string) => branchFolder(gitOf(command), CWD, gitEnvNamed(command, readCommands(command)))
  test('the branch a commit lands on: the folder git runs in when written in full, the session folder when none is named', () => {
    expect(branch('git commit -m x')).toEqual({ path: CWD })
    expect(branch('git -C /other commit -m x')).toEqual({ path: '/other' })
    // A relative folder was never followed, and still is not.
    expect(branch('git -C sub commit -m x')).toBe('none')
    expect(branch('git -C "$W" commit -m x')).toBe('none')
    // A chain written in full is where git runs: until #3398 its last -C alone was read, which named none.
    expect(branch('git -C /a -C b commit -m x')).toEqual({ path: '/a/b' })
    expect(branch('git -C /a -C "" commit -m x')).toEqual({ path: '/a' })
    expect(branch('git -C a -C b commit -m x')).toBe('none')
    expect(branch('git -C "$A" -C b commit -m x')).toBe('none')
  })
  // The review of #3532: the note reads the session folder only for a command naming no folder of
  // its own, and hands null for every other, so the answer for a command with a -C must never
  // depend on it.
  test('the session folder decides the answer only for a command that names no folder of its own', () => {
    const unread = (command: string) => branchFolder(gitOf(command), null, gitEnvNamed(command, readCommands(command)))
    for (const command of [
      'git -C /other commit -m x',
      'git -C sub commit -m x',
      'git -C "$W" commit -m x',
      'git -C /a -C b commit -m x',
      'git -C /a -C "" commit -m x',
      'git -C a -C b commit -m x',
      'git -C /other --git-dir=/o/.git commit -m x',
      'git -C /other --work-tree=/o commit -m x',
    ]) {
      expect(gitOf(command).dir).not.toBeUndefined()
      expect(unread(command)).toEqual(branch(command))
    }
    // With no folder named and none read there is none to name, never one made up.
    expect(gitOf('git commit -m x').dir).toBeUndefined()
    expect(unread('git commit -m x')).toBe('none')
  })
  test('a repository named apart has no folder that answers for its branch, and that is said', () => {
    const said = 'it names its repository apart from the folder it runs in (--git-dir or GIT_DIR)'
    expect(branch('git --git-dir=/o/.git commit -m x')).toEqual({ untold: said })
    expect(branch('GIT_DIR=/o/.git git commit -m x')).toEqual({ untold: said })
    expect(branch('git -C /other --git-dir=/o/.git commit -m x')).toEqual({ untold: said })
    expect(branch('export GIT_DIR=/o/.git; git commit -m x')).toEqual({ untold: 'the call names GIT_DIR, GIT_WORK_TREE or GIT_COMMON_DIR somewhere other than as a setting on the git command itself' })
    // The working folder alone leaves the repository the one found from the folder git runs in.
    expect(branch('git --work-tree=/o commit -m x')).toEqual({ path: CWD })
    expect(branch('git -C /other --work-tree=/o commit -m x')).toEqual({ path: '/other' })
  })
  const checkout = (command: string) => checkoutFolder(gitOf(command), CWD, gitEnvNamed(command, readCommands(command)))
  test('the checkout a stash or a patch belongs to: where git runs, a relative folder read from the session folder', () => {
    expect(checkout('git stash pop')).toBe(CWD)
    expect(checkout('git -C /other stash pop')).toBe('/other')
    expect(checkout('git -C sub stash pop')).toBe(`${CWD}/sub`)
    expect(checkout('git -C "$W" stash pop')).toBeNull()
    expect(checkout('git -C /a -C b stash pop')).toBe('/a/b')
    expect(checkout('git -C a -C b stash pop')).toBe(`${CWD}/a/b`)
    expect(checkout('git -C "$A" -C b stash pop')).toBeNull()
  })
  test('a repository or a working folder named apart names no checkout: its files land where only git can say', () => {
    for (const c of ['git --git-dir=/o/.git stash pop', 'git --work-tree=/o apply p.patch', 'GIT_DIR=/o/.git GIT_WORK_TREE=/o git stash pop', 'export GIT_WORK_TREE=/o; git apply p.patch'])
      expect({ c, at: checkout(c) }).toEqual({ c, at: null })
  })
})
