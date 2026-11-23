import { describe, expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { pipeline } from '../hooks/commands.ts'
import { callShell, commandWrites, pipelineIn, READ_ONLY, SETTLE_PLACES, settleOnDisk, type LinkFs } from '../hooks/writes.ts'

// The one reader of which files a Bash call writes (#705, L613): ask before saving kept its own and
// missed inline scripts, rsync, install, ln, dd, a patch, every file but the last of a sed -i, and a
// cd before a relative path, each of which another mod's copy caught.
const HOME = `${'/Users'}/dan`
const CWD = `${'/Users'}/dan/Apps/slate`
// Through the entry point $.modkit.writes calls, so these read exactly what the mods are given.
const read = (command: string, cwd = CWD) => commandWrites(command, cwd, HOME)
const paths = (command: string, cwd = CWD) => read(command, cwd).files.map(f => f.path ?? `(as written) ${f.word}`)

describe('writes: redirects and tee', () => {
  test('a redirect writes its target, resolved against the folder', () => {
    expect(paths('printf x >> CLAUDE.md')).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths('echo hi>notes.txt 2>err.log')).toEqual([`${CWD}/notes.txt`, `${CWD}/err.log`])
    expect(paths('ls &> out')).toEqual([`${CWD}/out`])
  })
  test('a descriptor copy and a device write no file', () => {
    expect(paths('make 2>&1 >/dev/null')).toEqual([])
    expect(paths('echo x > /dev/stderr')).toEqual([])
  })
  test('tee writes every file it names', () => {
    expect(paths('echo x | tee -a a.md ~/b.md')).toEqual([`${CWD}/a.md`, `${HOME}/b.md`])
  })
  test('home is spelled out, as ~ or $HOME', () => {
    expect(paths('cat x >> $HOME/.claude/CLAUDE.md')).toEqual([`${HOME}/.claude/CLAUDE.md`])
    expect(paths('cat x >> "${HOME}/.claude/CLAUDE.md"')).toEqual([`${HOME}/.claude/CLAUDE.md`])
  })
  test('a path built from another variable is given as written, so its name can still be read', () => {
    expect(read('echo x > $DIR/CLAUDE.md').files).toEqual([{ word: '$DIR/CLAUDE.md' }])
  })
})

// claude-config#1010: a write to a Next.js dynamic route (src/app/booking/[SO_ID]/page.tsx) was given
// as written, with no path, so the design round guard refused it as a write it could not follow,
// relative or absolute. A segment shaped like a route parameter is read as the folder or file it names:
// quoted the shell takes it literally, and unquoted bash leaves a pattern matching nothing as written
// (measured 2026-10-09; zsh refuses the command instead, so it writes nothing).
describe('writes: a bracketed route segment (#1010)', () => {
  test("a segment shaped like a route parameter names its folder or file, relative or absolute, however it is quoted", () => {
    expect(paths(`echo x > ${'/Users'}/dan/Apps/shop/src/app/booking/[SO_ID]/page.tsx`)).toEqual([`${'/Users'}/dan/Apps/shop/src/app/booking/[SO_ID]/page.tsx`])
    expect(paths("sed -i '' 's/a/b/' 'src/app/booking/[SO_ID]/page.tsx'")).toEqual([`${CWD}/src/app/booking/[SO_ID]/page.tsx`])
    expect(paths('cd src/app && cp /tmp/p "booking/[SO_ID]/page.tsx"')).toEqual([`${CWD}/src/app/booking/[SO_ID]/page.tsx`])
    // A catch all, an optional catch all, a matcher, a pages router file, and a route group beside them.
    expect(paths('cp a "src/app/(shop)/[...slug]/page.tsx" && cp a "src/app/[[...rest]]/layout.tsx" && cp a "src/routes/[id=int]/+page.svelte" && cp a "pages/posts/[id].tsx"')).toEqual([
      `${CWD}/src/app/(shop)/[...slug]/page.tsx`,
      `${CWD}/src/app/[[...rest]]/layout.tsx`,
      `${CWD}/src/routes/[id=int]/+page.svelte`,
      `${CWD}/pages/posts/[id].tsx`,
    ])
  })
  test('a bracket that is a pattern, anywhere else in the name, is still given as written, never guessed at', () => {
    expect(read('echo x > app/page.ts[x]').files).toEqual([{ word: 'app/page.ts[x]', folder: `${CWD}/app` }])
    expect(read('echo x > app/[t]okens.json').files).toEqual([{ word: 'app/[t]okens.json', folder: `${CWD}/app` }])
    expect(read('echo x > app/[a-z]*/page.tsx').files).toEqual([{ word: 'app/[a-z]*/page.tsx' }])
    expect(read('echo x > app/[!x]/page.tsx').files).toEqual([{ word: 'app/[!x]/page.tsx' }])
    // A range is a pattern too, even standing as a whole segment.
    expect(read('echo x > app/[a-z]/page.tsx').files).toEqual([{ word: 'app/[a-z]/page.tsx' }])
  })
})

// claude-config#1123: a name holding a pattern has no path, and the reader gave nothing of where it
// lands, so the design round guard could not place a RELATIVE pattern after a cd (#1015) and held
// it as a write it could not follow. Its folder is given where the folder part names one, a cd
// before it followed as for any path; the name is still given as written.
describe('writes: the folder a pattern lands in (#1123)', () => {
  test('a relative pattern after a cd is placed in the folder the cd moved to', () => {
    expect(read('cd src/app && echo x > [t]okens.json').files).toEqual([{ word: '[t]okens.json', folder: `${CWD}/src/app` }])
    expect(read('cd /w/slate && echo x > app/page.ts[x]').files).toEqual([{ word: 'app/page.ts[x]', folder: '/w/slate/app' }])
    expect(read('cd /tmp/scratch && rm -f *.css').changes).toEqual([{ word: '*.css', folder: '/tmp/scratch', does: 'remove' }])
    expect(read('rm -f styles/{a,b}.css').changes).toEqual([{ word: 'styles/{a,b}.css', folder: `${CWD}/styles`, does: 'remove' }])
  })
  test('a folder spelled from the top of the disk or from home is given too', () => {
    expect(read('rm -f ~/.claude/state/shown/*.json').changes).toEqual([{ word: '~/.claude/state/shown/*.json', folder: `${HOME}/.claude/state/shown`, does: 'remove' }])
    expect(read('rm -f $HOME/x/*').changes).toEqual([{ word: '$HOME/x/*', folder: `${HOME}/x`, does: 'remove' }])
    expect(read('echo x > /w/slate/[t]ailwind.config.ts').files).toEqual([{ word: '/w/slate/[t]ailwind.config.ts', folder: '/w/slate' }])
  })
  test('no folder where it cannot be named: a cd that cannot be followed, a variable, or a name that may reach below it', () => {
    expect(read('cd $X && rm -f *.css').changes).toEqual([{ word: '*.css', does: 'remove' }])
    expect(read('echo x > $D/*.css').files).toEqual([{ word: '$D/*.css' }])
    // A variable in the name may hold a slash, so the name may land in a folder below.
    expect(read('rm -f out/$N*.css').changes).toEqual([{ word: 'out/$N*.css', does: 'remove' }])
    // A whole ** reaches every folder below with globstar.
    expect(read('rm -f out/**').changes).toEqual([{ word: 'out/**', does: 'remove' }])
    // A pattern in the folder part names no one folder.
    expect(read('rm -f src/*/x.css').changes).toEqual([{ word: 'src/*/x.css', does: 'remove' }])
    // A name with no pattern but a variable is not a pattern's folder either.
    expect(read('echo x > out/$NAME').files).toEqual([{ word: 'out/$NAME' }])
  })
})

describe('writes: <> opens a file for reading and writing (#760)', () => {
  test('which creates it, so it is written', () => {
    expect(paths('exec 3<>notes.txt')).toEqual([`${CWD}/notes.txt`])
    expect(paths('cat <>notes.txt')).toEqual([`${CWD}/notes.txt`])
    expect(paths('cmd <> notes.txt')).toEqual([`${CWD}/notes.txt`])
  })
})

describe("writes: a shell's own output redirect (#760)", () => {
  test('is written when the shell is read as the commands its script runs', () => {
    expect(paths(`bash -c 'make' > build.log`)).toEqual([`${CWD}/build.log`])
    expect(paths(`bash <<'EOF' > out.txt\nls\nEOF`)).toEqual([`${CWD}/out.txt`])
    expect(paths(`bash -c 'echo a > a.txt' 2> err.log`)).toEqual([`${CWD}/a.txt`, `${CWD}/err.log`])
    expect(paths(`bash -c 'ls' 2>&1`)).toEqual([])
    // Attached to its target as well as spaced from it, since the reader makes the operator a word
    // of its own however it is written (#654).
    expect(paths(`bash -c 'make' >build.log`)).toEqual([`${CWD}/build.log`])
    expect(paths(`sh -c 'ls' 2>err.log`)).toEqual([`${CWD}/err.log`])
    expect(paths(`bash -c 'ls' &>all.log`)).toEqual([`${CWD}/all.log`])
  })
})

// #1976: the job watcher judged a background command quiet while it logged every minute to the file
// its standard output was redirected into. Only the redirect says where standard output goes, so the
// reader gives those files apart, in `stdout`, beside `files`, where a tee or a copy is no different.
describe('writes: where standard output is sent (#1976)', () => {
  const stdout = (command: string, cwd = CWD) => read(command, cwd).stdout
  test('a redirect of standard output, however it is spelled, gives its file', () => {
    expect(stdout('bash merge-when-ready.sh 1965 > merge.log 2>&1')).toEqual([{ word: 'merge.log', path: `${CWD}/merge.log` }])
    expect(stdout('make >> build.log')).toEqual([{ word: 'build.log', path: `${CWD}/build.log` }])
    expect(stdout('make 1>build.log')).toEqual([{ word: 'build.log', path: `${CWD}/build.log` }])
    expect(stdout('make >| build.log')).toEqual([{ word: 'build.log', path: `${CWD}/build.log` }])
    expect(stdout('make &> build.log')).toEqual([{ word: 'build.log', path: `${CWD}/build.log` }])
    expect(stdout('make &>> build.log')).toEqual([{ word: 'build.log', path: `${CWD}/build.log` }])
    expect(stdout('make >& build.log')).toEqual([{ word: 'build.log', path: `${CWD}/build.log` }])
  })
  test('a cd before it is followed, and each command of the line gives its own', () => {
    expect(stdout('cd /repo && npm test > /tmp/t.log; make > m.log')).toEqual([
      { word: '/tmp/t.log', path: '/tmp/t.log' },
      { word: 'm.log', path: '/repo/m.log' },
    ])
  })
  test('a tee, a copy, another descriptor alone, a descriptor copy and a device are none', () => {
    expect(stdout('make 2>&1 | tee build.log')).toBeUndefined()
    expect(stdout('cp a.log b.log')).toBeUndefined()
    expect(stdout('make 2> err.log')).toBeUndefined()
    expect(stdout('make >&2')).toBeUndefined()
    expect(stdout('make > /dev/null 2>&1')).toBeUndefined()
    expect(read('make 2>&1 | tee build.log').files).toEqual([{ word: 'build.log', path: `${CWD}/build.log` }])
  })
  test('a target that cannot be named is given as written, with no path', () => {
    expect(stdout('make > "$LOG"')).toEqual([{ word: '$LOG' }])
    expect(stdout('make > logs/*.log')).toEqual([{ word: 'logs/*.log', folder: `${CWD}/logs` }])
  })
  test('a variable the command set is read as its value', () => {
    expect(stdout('LOG=/tmp/m.log; make > "$LOG"')).toEqual([{ word: '$LOG', path: '/tmp/m.log' }])
  })
  test("a substitution's redirect is the job's too", () => {
    expect(stdout('echo "$(make > m.log)"')).toEqual([{ word: 'm.log', path: `${CWD}/m.log` }])
  })
})

describe('writes: a cd before the write', () => {
  test('a relative path after a cd is resolved in the folder it changed into', () => {
    expect(paths("cd ~/.claude/projects/p/memory && cat > note.md <<'EOF'\n- rule\nEOF")).toEqual([`${HOME}/.claude/projects/p/memory/note.md`])
    expect(paths('cd sub; echo x > a.txt; cd ..; echo y > b.txt')).toEqual([`${CWD}/sub/a.txt`, `${CWD}/b.txt`])
  })
  // #700 made the reader give a subshell's parentheses as commands of their own, as the collision
  // guard reads them: a cd made inside a subshell ends with it.
  test("a cd inside a subshell holds only inside it, and a write after it is in the folder outside", () => {
    expect(paths('(cd sub && printf x >> notes.txt)')).toEqual([`${CWD}/sub/notes.txt`])
    expect(paths('(cd ~/.claude/projects/p/memory && cat > a.md); echo y > b.md')).toEqual([`${HOME}/.claude/projects/p/memory/a.md`, `${CWD}/b.md`])
    expect(paths('( cd sub; make ) > out.txt')).toEqual([`${CWD}/out.txt`])
  })
  test('a bare cd goes home; cd - goes somewhere this cannot know, so a relative path after it is given as written', () => {
    expect(paths('cd && echo x > a.md')).toEqual([`${HOME}/a.md`])
    expect(paths('cd - && echo x > CLAUDE.md')).toEqual(['(as written) CLAUDE.md'])
  })
  // #2000: popd goes back to a folder pushd kept, which this does not keep, so the folder after it is
  // not known; it was read as the folder pushd moved to.
  test('a relative path after a popd is given as written', () => {
    expect(paths('pushd sub && popd && echo x > a.md')).toEqual(['(as written) a.md'])
  })
})

// #2000: is it live asked GitHub about a merge in the session's folder, so a command that changed
// folder first (`cd <other checkout> && merge-when-ready.sh 12`) was asked about the session folder's
// own #12 (L237). The folder each command runs in is read by the write reader's own following of a
// cd, never by a second follower in a mod.
describe('pipelineIn: the folder each command runs in', () => {
  const folders = (command: string) => pipelineIn(command, CWD, HOME).map(c => [c.words[0], c.folder])
  test('the commands are the ones pipeline gives, each with the folder it runs in', () => {
    for (const command of ['gh pr merge 12 --squash', 'X=/w/b; cd $X && gh pr merge 12', 'cd /w/b && echo "$(cd /w/c && pwd)" | tee f; gh pr merge 3', "bash <<'EOF'\ncd /w/b\ngh pr merge 4\nEOF", '(cd sub && make) > out'])
      expect(pipelineIn(command, CWD, HOME).map(({ folder: _f, ...c }) => c)).toEqual(pipeline(command))
  })
  test('the folder a cd leaves it in: absolute, relative, home, and through a variable the command set', () => {
    expect(folders('gh pr merge 12')).toEqual([['gh', CWD]])
    expect(folders('cd /w/booking && gh pr merge 12')).toEqual([['cd', CWD], ['gh', '/w/booking']])
    expect(folders('cd ../other; bash ~/.claude/hooks/lib/merge-when-ready.sh 12')).toEqual([['cd', CWD], ['bash', `${'/Users'}/dan/Apps/other`]])
    expect(folders('cd ~/Apps/other && gh pr merge 12')).toEqual([['cd', CWD], ['gh', `${HOME}/Apps/other`]])
    expect(folders('W=/w/other; cd "$W" && gh pr merge 12')).toEqual([['cd', CWD], ['gh', '/w/other']])
    expect(folders('pushd /w/other && gh pr merge 12')).toEqual([['pushd', CWD], ['gh', '/w/other']])
  })
  test('a cd inside a subshell or a substitution ends with it', () => {
    expect(folders('(cd /w/other && gh pr merge 12); gh pr merge 13')).toEqual([['(', CWD], ['cd', CWD], ['gh', '/w/other'], [')', '/w/other'], ['gh', CWD]])
    expect(folders('echo "$(cd /w/other && pwd)"; gh pr merge 13').at(-1)).toEqual(['gh', CWD])
  })
  test('null where the folder cannot be followed: a variable the command did not set, cd -, a popd', () => {
    expect(folders('cd "$WT" && gh pr merge 12')).toEqual([['cd', CWD], ['gh', null]])
    expect(folders('cd - && gh pr merge 12')).toEqual([['cd', CWD], ['gh', null]])
    expect(folders('pushd /w/other && popd && gh pr merge 12')).toEqual([['pushd', CWD], ['popd', '/w/other'], ['gh', null]])
  })
  // #3093: a command that only sets a value (`T=x;`) runs nothing, so it is left out, and a guard
  // that must know every value a line sets before a script could not see one. Asked for, it is
  // given as its assignments, in its place, with the folder it stands in.
  test('asked for, the commands that only set a value are given too, each in its place with its folder', () => {
    const asked = (command: string) => pipelineIn(command, CWD, HOME, { assignments: true }).map(c => [c.words, c.env, c.folder])
    expect(asked('T=x; cd /w/b && U=1 V=2; W=3 bash s.sh d')).toEqual([[['T=x'], undefined, CWD], [['cd', '/w/b'], undefined, CWD], [['U=1', 'V=2'], undefined, '/w/b'], [['bash', 's.sh', 'd'], ['W=3'], '/w/b']])
    expect(asked('{ PATH=/x; bash s.sh d; }').map(c => c[0])).toEqual([['PATH=/x'], ['bash', 's.sh', 'd'], ['}']])
    expect(asked(`bash -c 'T=x; make'`).map(c => c[0])).toEqual([['T=x'], ['make']])
  })
  test('not asked for, they are left out as before', () => {
    expect(pipelineIn('T=x; cd /w/b && U=1; bash s.sh d', CWD, HOME).map(c => c.words)).toEqual([['cd', '/w/b'], ['bash', 's.sh', 'd']])
    expect(pipelineIn('T=x; bash s.sh d', CWD, HOME, {}).map(c => c.words)).toEqual([['bash', 's.sh', 'd']])
  })
})

describe('writes: copying, moving and linking', () => {
  test("cp, mv, ln, install and ditto write their destination", () => {
    expect(paths('cp rules.md CLAUDE.md')).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths('mv -f draft.md ../AGENTS.md')).toEqual([`${'/Users'}/dan/Apps/AGENTS.md`])
    expect(paths('ln -sf ~/rules.md ~/.claude/CLAUDE.md')).toEqual([`${HOME}/.claude/CLAUDE.md`])
    expect(paths('install -m 644 rules.md ~/.claude/CLAUDE.md')).toEqual([`${HOME}/.claude/CLAUDE.md`])
    expect(paths('ditto rules.md CLAUDE.md')).toEqual([`${CWD}/CLAUDE.md`])
  })
  test('into a folder, each source lands under its own name: a trailing slash, several sources, or -t', () => {
    expect(paths('cp note.md ~/.claude/projects/p/memory/')).toEqual([`${HOME}/.claude/projects/p/memory/note.md`])
    expect(paths('cp a.md b.md ~/other/')).toEqual([`${HOME}/other/a.md`, `${HOME}/other/b.md`])
    expect(paths('cp -t ~/other a.md')).toEqual([`${HOME}/other/a.md`])
  })
  test('a copy names its sources, so a reader can tell what was put there', () => {
    expect(read('cp rules.md CLAUDE.md').files).toEqual([{ word: 'CLAUDE.md', path: `${CWD}/CLAUDE.md`, sources: [`${CWD}/rules.md`], mayBeFolder: true }])
    // Into a folder, each lands under its own name, so none may be a folder in its turn.
    expect(read('cp a.md b.md ~/other/').files.map(f => f.mayBeFolder)).toEqual([undefined, undefined])
  })
  // macOS cp (BSD) copies what a source ending in a slash holds into the destination, making the
  // destination as that copy where it does not exist, so either way the write reaches every file under
  // the destination, a tree (#2372). GNU cp takes the slash as nothing and writes the folder under its
  // own name; the words cannot say which cp runs, so that write is kept beside the tree.
  test('cp of a source ending in a slash writes its contents into the destination, a whole tree', () => {
    const tree = (dest: string, src: string) => ({ word: dest, path: `${CWD}/${dest}`, sources: [`${CWD}/${src}`], tree: true })
    for (const flag of ['-r', '-R', '-a', '-Rp'])
      expect(read(`cp ${flag} lib/ src/`).files).toEqual([{ word: 'src/lib', path: `${CWD}/src/lib`, sources: [`${CWD}/lib`] }, tree('src', 'lib')])
    // A destination with no slash, there or not: BSD cp puts the contents in it or makes it as the copy.
    expect(read('cp -R lib/ src').files).toEqual([{ ...tree('src', 'lib'), mayBeFolder: true }])
    // Through a cd, and a destination named from home.
    expect(read('cd app && cp -R lib/ ~/out/').files.find(f => f.tree)).toEqual({ word: '~/out', path: `${HOME}/out`, sources: [`${CWD}/app/lib`], tree: true })
  })
  test('with several sources only one ending in a slash adds the tree, and each keeps its own name', () => {
    expect(read('cp -R a/ b dest/').files).toEqual([
      { word: 'dest/a', path: `${CWD}/dest/a`, sources: [`${CWD}/a`] },
      { word: 'dest/b', path: `${CWD}/dest/b`, sources: [`${CWD}/b`] },
      { word: 'dest', path: `${CWD}/dest`, sources: [`${CWD}/a`], tree: true },
    ])
  })
  test('a source with no slash still lands as the folder itself, with no tree', () => {
    expect(read('cp -R lib src/').files).toEqual([{ word: 'src/lib', path: `${CWD}/src/lib`, sources: [`${CWD}/lib`] }])
    expect(read('cp -R lib src').files).toEqual([{ word: 'src', path: `${CWD}/src`, sources: [`${CWD}/lib`], mayBeFolder: true }])
  })
  test('the slash reading is cp\'s alone: mv, ln, install and a GNU only -t are read as before', () => {
    expect(read('mv lib/ src/').files.some(f => f.tree)).toBe(false)
    expect(read('ln -s lib/ src/').files.some(f => f.tree)).toBe(false)
    expect(read('cp -R -t src lib/').files.some(f => f.tree)).toBe(false)
  })
  // The trees a command writes, by path and the sources they come from.
  const trees = (command: string) => read(command).files.filter(f => f.tree).map(f => ({ path: f.path, sources: f.sources }))
  // A cp source whose last part is a dot (lib/., or . itself) copies what that folder holds into the
  // destination, on macOS and GNU cp alike, there or not (measured on macOS cp, #2396): a tree.
  test('cp of a source ending in slash dot writes its contents into the destination, a whole tree', () => {
    for (const command of ['cp -R lib/. src/', 'cp -R lib/. src', 'cp -a lib/./ src/', 'cp -R -t src lib/.'])
      expect(trees(command)).toEqual([{ path: `${CWD}/src`, sources: [`${CWD}/lib`] }])
    // The working folder itself, and through a cd.
    expect(trees('cp -R . ~/out')).toEqual([{ path: `${HOME}/out`, sources: [CWD] }])
    expect(trees('cd app && cp -R lib/. ../src/')).toEqual([{ path: `${CWD}/src`, sources: [`${CWD}/app/lib`] }])
  })
  test('a cp source that only starts with a dot is a name, with no tree', () => {
    expect(trees('cp -R lib/.git src/')).toEqual([])
    expect(trees('cp -R .config src/')).toEqual([])
  })
  // ditto merges what a source folder holds into the destination whatever the slash (man ditto; measured
  // on macOS, #2396), and the words cannot say whether a source is a folder, so the destination is a
  // tree beside the reading cp gets. -x unpacks an archive into the destination folder, also a tree;
  // -c makes the destination one archive file, so it is not.
  test('ditto writes its destination as a whole tree, whatever the slash', () => {
    expect(trees('ditto lib out')).toEqual([{ path: `${CWD}/out`, sources: [`${CWD}/lib`] }])
    expect(trees('ditto lib/ out/')).toEqual([{ path: `${CWD}/out`, sources: [`${CWD}/lib`] }])
    expect(trees('ditto a b out')).toEqual([{ path: `${CWD}/out`, sources: [`${CWD}/a`, `${CWD}/b`] }])
    expect(trees('ditto --arch arm64 -V lib ~/out')).toEqual([{ path: `${HOME}/out`, sources: [`${CWD}/lib`] }])
    expect(trees('ditto -xk arch.zip out')).toEqual([{ path: `${CWD}/out`, sources: [`${CWD}/arch.zip`] }])
    // -rsrc is ditto's old spelling of --rsrc, a copy, though it holds a c (measured on macOS).
    expect(trees('ditto -rsrc lib out')).toEqual([{ path: `${CWD}/out`, sources: [`${CWD}/lib`] }])
    // The reading cp gets is kept beside the tree: a file source lands under its own name in a folder.
    expect(paths('ditto lib/ out/')).toEqual([`${CWD}/out/lib`, `${CWD}/out`])
  })
  test('ditto -c writes one archive file, with no tree', () => {
    expect(trees('ditto -ck lib arch.zip')).toEqual([])
    expect(trees('ditto -c -k --keepParent lib arch.zip')).toEqual([])
    expect(paths('ditto -ck lib arch.zip')).toEqual([`${CWD}/arch.zip`])
  })
  test('rsync writes its local destination, and a remote one is no file here', () => {
    expect(paths('rsync -av --exclude .git notes.md ~/.claude/CLAUDE.md')).toEqual([`${HOME}/.claude/CLAUDE.md`])
    expect(paths('rsync -av CLAUDE.md host:backup/')).toEqual([])
  })
  // rsync copies what a source ending in a slash or slash dot holds into the destination, there or not
  // (measured on this Mac's rsync 3.4.1, #2396): a tree. A source with neither lands under its own name.
  test('rsync of a source ending in a slash or slash dot writes its contents into the destination, a whole tree', () => {
    for (const command of ['rsync -a lib/ src/', 'rsync -a lib/ src', 'rsync -a lib/. src/', 'rsync -a lib/. src', 'rsync -av --exclude .git lib/./ src'])
      expect(trees(command)).toEqual([{ path: `${CWD}/src`, sources: [`${CWD}/lib`] }])
    expect(trees('rsync -a lib/ host:src/')).toEqual([])
  })
  test('rsync of a source with no slash lands as the folder itself, with no tree', () => {
    expect(read('rsync -a lib src/').files).toEqual([{ word: 'src/lib', path: `${CWD}/src/lib`, sources: [`${CWD}/lib`] }])
    expect(trees('rsync -a lib/.git src/')).toEqual([])
  })
  test('dd writes what of= names', () => {
    expect(paths('dd if=rules.md of=CLAUDE.md bs=1k')).toEqual([`${CWD}/CLAUDE.md`])
  })
})

describe('writes: editing in place', () => {
  test('sed -i writes every file after its script, not only the last', () => {
    expect(paths("sed -i 's/a/b/' CLAUDE.md other.md")).toEqual([`${CWD}/CLAUDE.md`, `${CWD}/other.md`])
    expect(paths("sed -i '' -e 's/a/b/' CLAUDE.md")).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths("sed -i.bak 's/a/b/' AGENTS.md")).toEqual([`${CWD}/AGENTS.md`])
  })
  test('sed without -i only prints', () => {
    expect(paths("sed 's/a/b/' CLAUDE.md")).toEqual([])
  })
  test('perl -i writes its files, and -i in another letter cluster is not taken for it', () => {
    expect(paths("perl -pi -e 's/a/b/' CLAUDE.md")).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths("perl -Ilib -ne 'print' CLAUDE.md")).toEqual([])
  })
  // Review of #718: -0 and -l take only digits, so the letters after them are still options.
  test('perl -0pi, -lpi and -0777pi write their files: -0 and -l take digits, not the rest of the cluster', () => {
    expect(paths("perl -0pi -e 's/a/b/' CLAUDE.md")).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths("perl -lpi -e 's/a/b/' CLAUDE.md")).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths("perl -0777pi -e 's/a/b/' AGENTS.md")).toEqual([`${CWD}/AGENTS.md`])
    expect(paths("perl -0x1Fpi -e 's/a/b/' AGENTS.md")).toEqual([`${CWD}/AGENTS.md`])
    expect(paths("perl -0777 -ne 'print' CLAUDE.md")).toEqual([])
  })
  test('ruby -i and awk -i inplace write their files too', () => {
    expect(paths("ruby -pi -e 'sub(/a/, \"b\")' CLAUDE.md")).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths("awk -i inplace '{print}' CLAUDE.md AGENTS.md")).toEqual([`${CWD}/CLAUDE.md`, `${CWD}/AGENTS.md`])
    expect(paths("awk '{print}' CLAUDE.md")).toEqual([])
  })
})

describe('writes: downloads', () => {
  test("curl's -o and --output, and wget's -O, write the file they name", () => {
    expect(paths('curl -sSo CLAUDE.md https://example.com/x')).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths('curl --output=AGENTS.md https://example.com/x')).toEqual([`${CWD}/AGENTS.md`])
    expect(paths('wget -q -O ~/.claude/CLAUDE.md https://example.com/x')).toEqual([`${HOME}/.claude/CLAUDE.md`])
    expect(paths('curl -s https://example.com/x')).toEqual([])
  })
  // #726: a file saved under the address's own name, into the current folder, was not reported, so
  // a download into lasting memory by its remote name was never seen. curl 8.7 takes the query and
  // the fragment off that name (measured 2026-10-04); wget keeps the query, as GNU wget documents.
  test("curl's -O and --remote-name save under the address's last part, query and fragment off", () => {
    expect(paths('curl -O https://example.com/docs/CLAUDE.md')).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths('curl -sSLO https://example.com/docs/CLAUDE.md')).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths('curl --remote-name "https://example.com/a/AGENTS.md?raw=1#top"')).toEqual([`${CWD}/AGENTS.md`])
    expect(paths("curl -H 'Accept: text/plain' -O https://example.com/a/CLAUDE.md")).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths('cd ~/.claude && curl -O https://example.com/CLAUDE.md')).toEqual([`${HOME}/.claude/CLAUDE.md`])
  })
  test('each -o or -O is for the next address in turn, and --remote-name-all names every one', () => {
    expect(paths('curl -O https://x.com/a.md -O https://x.com/b.md')).toEqual([`${CWD}/a.md`, `${CWD}/b.md`])
    expect(paths('curl -o out.txt https://x.com/a -O https://x.com/CLAUDE.md')).toEqual([`${CWD}/out.txt`, `${CWD}/CLAUDE.md`])
    expect(paths('curl https://x.com/a.md https://x.com/b.md -O -O')).toEqual([`${CWD}/a.md`, `${CWD}/b.md`])
    expect(paths('curl -O https://x.com/a.md https://x.com/b.md')).toEqual([`${CWD}/a.md`])
    expect(paths('curl --remote-name-all https://x.com/a.md --url https://x.com/b.md')).toEqual([`${CWD}/a.md`, `${CWD}/b.md`])
  })
  test('--output-dir is where a remote name lands', () => {
    expect(paths('curl --output-dir ~/.claude -O https://x.com/CLAUDE.md')).toEqual([`${HOME}/.claude/CLAUDE.md`])
  })
  test('an address with no file name in it saves nothing', () => {
    expect(paths('curl -O https://example.com/')).toEqual([])
    expect(paths('curl -O example.com')).toEqual([])
  })
  test('-J lets the server name the file, which the words cannot give, so it is a write they do not name', () => {
    expect(read('curl -J -O https://x.com/get?f=CLAUDE.md')).toEqual({
      files: [{ word: 'get', path: `${CWD}/get` }],
      changes: [],
      unnamed: [{ what: 'a curl download the server names', words: ['curl', '-J', '-O', 'https://x.com/get?f=CLAUDE.md'], inputs: [] }],
    })
    expect(read('curl -OJ https://x.com/get').unnamed.map(u => u.what)).toEqual(['a curl download the server names'])
  })
  test("curl's other files: a cookie jar, dumped headers, a trace", () => {
    expect(paths('curl -c jar.txt -D headers.txt --trace-ascii trace.log https://x.com/a')).toEqual([`${CWD}/jar.txt`, `${CWD}/headers.txt`, `${CWD}/trace.log`])
    expect(paths('curl -D - https://x.com/a')).toEqual([])
  })
  test('a plain wget saves under the address\'s last part, index.html for a folder, into the current folder or -P', () => {
    expect(paths('wget https://example.com/docs/CLAUDE.md')).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths('wget -q https://example.com/docs/')).toEqual([`${CWD}/index.html`])
    expect(paths('wget -P ~/.claude https://example.com/CLAUDE.md')).toEqual([`${HOME}/.claude/CLAUDE.md`])
    expect(paths('wget --directory-prefix=/tmp/x https://example.com/AGENTS.md')).toEqual(['/tmp/x/AGENTS.md'])
    expect(paths('wget https://example.com/CLAUDE.md?raw=1')).toEqual(['(as written) CLAUDE.md?raw=1'])
    expect(paths('wget --header "Accept: x" https://example.com/a/AGENTS.md')).toEqual([`${CWD}/AGENTS.md`])
  })
  test("wget's -O to standard output saves nothing, and its log is a file it writes", () => {
    expect(paths('wget -qO- https://example.com/CLAUDE.md')).toEqual([])
    expect(paths('wget -o fetch.log -O - https://example.com/x')).toEqual([`${CWD}/fetch.log`])
  })
  test('a wget whose files the words cannot name is a write they do not name', () => {
    expect(read('wget --content-disposition https://x.com/get').unnamed.map(u => u.what)).toEqual(['a wget download the server names'])
    expect(read('wget -r https://x.com/docs/').unnamed.map(u => u.what)).toEqual(['a wget download of many files'])
    expect(read('wget -i urls.txt')).toEqual({ files: [], changes: [], unnamed: [{ what: 'a wget download of the addresses in a file', words: ['wget', '-i', 'urls.txt'], inputs: [`${CWD}/urls.txt`] }] })
  })
})

// claude-config#1123: winding down (#1108) counts as a session's own unfinished work only the files
// it wrote, and git itself changes files no other route here names: git mv, git rm, a checkout of a
// path, git restore. The reader names them apart, in byGit, a cd and git -C followed, so the guards
// that judge files and changes are not changed by it.
describe('writes: what git itself changes (#1123)', () => {
  const byGit = (command: string, cwd = CWD) => read(command, cwd).byGit ?? []
  test('git mv writes the destination and removes each source, everything under it included', () => {
    // Onto one name that may be a folder: the name alone, never all under it, which may hold another
    // session's files (#1123 lessons review), and the source's own name inside it whole.
    expect(byGit('git mv old.ts new.ts')).toEqual([
      { word: 'new.ts', path: `${CWD}/new.ts`, does: 'write' },
      { word: 'new.ts/old.ts', path: `${CWD}/new.ts/old.ts`, does: 'write', tree: true },
      { word: 'old.ts', path: `${CWD}/old.ts`, does: 'remove', tree: true },
    ])
    expect(byGit('cd src && git mv -k a.ts b.ts lib/')).toEqual([
      { word: 'lib/a.ts', path: `${CWD}/src/lib/a.ts`, does: 'write', tree: true },
      { word: 'lib/b.ts', path: `${CWD}/src/lib/b.ts`, does: 'write', tree: true },
      { word: 'a.ts', path: `${CWD}/src/a.ts`, does: 'remove', tree: true },
      { word: 'b.ts', path: `${CWD}/src/b.ts`, does: 'remove', tree: true },
    ])
    expect(byGit('git mv -n a.ts b.ts')).toEqual([])
  })
  test('git rm removes what it names, from the index alone with --cached, and nothing in a dry run', () => {
    expect(byGit('git rm -r --cached build')).toEqual([{ word: 'build', path: `${CWD}/build`, does: 'remove', tree: true }])
    expect(byGit('git -C /repo rm notes.md')).toEqual([{ word: 'notes.md', path: '/repo/notes.md', does: 'remove' }])
    expect(byGit('git rm --dry-run notes.md')).toEqual([])
    // git's own pattern matches across folders (its * takes a slash), so it is given as written.
    expect(byGit("git rm 'logs/*.log'")).toEqual([{ word: 'logs/*.log', does: 'remove' }])
  })
  test('a checkout of a path, or a restore, writes what it names, a folder with everything under it', () => {
    expect(byGit('git checkout main -- app/page.tsx')).toEqual([{ word: 'app/page.tsx', path: `${CWD}/app/page.tsx`, does: 'write', tree: true, from: 'main' }])
    expect(byGit('git checkout -- .')).toEqual([{ word: '.', path: CWD, does: 'write', tree: true, from: '' }])
    expect(byGit('git checkout HEAD~1 a.ts b.ts')).toEqual([
      { word: 'a.ts', path: `${CWD}/a.ts`, does: 'write', tree: true, from: 'HEAD~1' },
      { word: 'b.ts', path: `${CWD}/b.ts`, does: 'write', tree: true, from: 'HEAD~1' },
    ])
    expect(byGit('git restore --source=HEAD~2 -W src')).toEqual([{ word: 'src', path: `${CWD}/src`, does: 'write', tree: true, from: 'HEAD~2' }])
    expect(byGit('git restore -s main app.ts')).toEqual([{ word: 'app.ts', path: `${CWD}/app.ts`, does: 'write', tree: true, from: 'main' }])
  })
  // claude-config#1158: the design round guard judges a restore by the lines it changes, so each
  // carries where git puts the file back from, in the spelling `git cat-file blob <from>:<path>`
  // reads: a ref, '' for the index, ':2' and ':3' for the two sides of a conflict.
  test('a checkout of a path, or a restore, says where git puts the file back from (#1158)', () => {
    const from = (command: string) => byGit(command).map(g => g.from)
    expect(from('git restore app.ts')).toEqual([''])
    expect(from('git restore -W app.ts')).toEqual([''])
    expect(from('git restore -SW app.ts')).toEqual(['HEAD'])
    expect(from('git restore --staged --worktree --source main app.ts')).toEqual(['main'])
    expect(from('git restore --source main -- app.ts')).toEqual(['main'])
    expect(from('git checkout HEAD -- app.ts')).toEqual(['HEAD'])
    expect(from('git checkout -- app.ts')).toEqual([''])
    expect(from('git checkout --theirs -- app.ts')).toEqual([':3'])
    expect(from('git restore --ours app.ts')).toEqual([':2'])
    // git mv and git rm put nothing back.
    expect(from('git rm app.ts')).toEqual([undefined])
  })
  test('the same file put back twice from two places is given once for each (#1158)', () => {
    expect(byGit('git checkout main -- app.ts && git checkout HEAD~3 -- app.ts').map(g => g.from)).toEqual(['main', 'HEAD~3'])
  })
  test('a branch switch, a checkout of one name git may take for a branch, and an unstage name no file', () => {
    expect(byGit('git checkout main')).toEqual([])
    expect(byGit('git checkout -b fix/1123 origin/main')).toEqual([])
    expect(byGit('git switch -c x')).toEqual([])
    expect(byGit('git restore --staged app.ts')).toEqual([])
  })
  test("a pathspec git reads from the top of the checkout is given as written, never placed in the folder", () => {
    expect(byGit('git checkout -- :/docs')).toEqual([{ word: ':/docs', does: 'write', from: '' }])
  })
  test('inside a command substitution too', () => {
    expect(byGit('out=$(git rm -q notes.md)')).toEqual([{ word: 'notes.md', path: `${CWD}/notes.md`, does: 'remove' }])
  })
  test('the guards see none of it in files or changes', () => {
    const r = read('git mv a.ts b.ts && git rm c.ts && git checkout -- d.ts')
    expect([r.files, r.changes, r.unnamed]).toEqual([[], [], []])
  })
})

describe('writes: what the words do not name', () => {
  test('a patch applied names the patch files to read, resolved in the folder git is pointed at', () => {
    expect(read('patch -p1 < fix.diff').unnamed).toEqual([{ what: 'a patch', words: ['patch', '-p1', '<', 'fix.diff'], inputs: [`${CWD}/fix.diff`] }])
    expect(read('git -C /repo apply fix.patch').unnamed).toEqual([{ what: 'a patch', words: ['git', '-C', '/repo', 'apply', 'fix.patch'], inputs: ['/repo/fix.patch'] }])
  })
  // Lessons review of #2402 at 4124d43: a folder git is pointed at that cannot be named leaves every
  // relative name under it unnamed, never resolved in the folder the command runs in.
  test('git pointed at a folder that cannot be named names no relative path under it', () => {
    expect(read('git -C "$D" apply fix.patch').unnamed.map(u => u.inputs)).toEqual([[]])
    expect(read('git -C "$D" checkout -- a.ts').byGit?.map(g => [g.word, g.path ?? null])).toEqual([['a.ts', null]])
    expect(read(`git -C "$D" checkout -- 'a$.ts'`).byGit?.map(g => [g.word, g.path ?? null])).toEqual([['a$.ts', null]])
    // Pointed at a folder it can name, a name whose every $ is left as written is resolved there.
    expect(read(`git -C /repo checkout -- 'a$.ts'`).byGit?.map(g => [g.word, g.path ?? null])).toEqual([['a$.ts', '/repo/a$.ts']])
  })
  // #3337: git told where its working folder is (--work-tree, GIT_WORK_TREE) reads a relative path
  // from the top of that folder when the command runs outside it, and from the folder the command
  // runs in when that is inside it (measured with git 2.51.1: run from the project, `git
  // --git-dir=<other>/.git --work-tree=<wt> restore app/globals.css` put back <wt>/app/globals.css
  // and left the project's file alone). Until then every such path was placed in the folder the
  // command ran in, so a guard judged a file git never touched and missed the one it wrote.
  const byGit = (command: string, cwd = CWD) => read(command, cwd).byGit ?? []
  test('a path git is handed is placed in the working folder the command names (#3337)', () => {
    const paths = (command: string, cwd = CWD) => byGit(command, cwd).map(g => [g.word, g.path ?? null])
    const HERE = [['app/globals.css', '/w/x/app/globals.css']]
    expect(paths('git --git-dir=/other/.git --work-tree=/w/x restore app/globals.css')).toEqual(HERE)
    expect(paths('git --work-tree /w/x checkout -- app/globals.css')).toEqual(HERE)
    expect(paths('GIT_WORK_TREE=/w/x git restore app/globals.css')).toEqual(HERE)
    expect(paths('GIT_DIR=/other/.git GIT_WORK_TREE=/w/x git checkout HEAD -- app/globals.css')).toEqual(HERE)
    expect(paths('env GIT_WORK_TREE=/w/x git rm app/globals.css')).toEqual(HERE)
    // A relative working folder is read from the folder -C names, or the one the command runs in.
    expect(paths('git -C /w/a --work-tree=../x restore app/globals.css')).toEqual(HERE)
    expect(paths('cd /w/a && git --work-tree=../x restore app/globals.css')).toEqual(HERE)
    // Run inside the working folder, a path is read from the folder the command runs in.
    expect(paths('git --work-tree=/w/x restore globals.css', '/w/x/app')).toEqual([['globals.css', '/w/x/app/globals.css']])
    expect(paths('git --work-tree=/w/x restore app/globals.css', '/w/x')).toEqual(HERE)
    // A folder whose name only starts the same is outside it.
    expect(paths('git --work-tree=/w/x restore app/globals.css', '/w/xy')).toEqual(HERE)
  })
  test('with only the repository named, the folder the command runs in is the working folder, as before (#3337)', () => {
    expect(byGit('git --git-dir=/other/.git restore app/globals.css').map(g => g.path)).toEqual([`${CWD}/app/globals.css`])
    expect(byGit('GIT_DIR=/other/.git git checkout -- app/globals.css').map(g => g.path)).toEqual([`${CWD}/app/globals.css`])
  })
  // Where the reader cannot know the working folder, it hands on the path it handed on before #3337,
  // in the folder the command runs in: a guess, kept so the guards that judge a file by this path
  // (the collision guard, winding down) judge every call they judged before, since each skips an
  // entry with no path. A guard that must not act on the guess holds for itself, as the design
  // round guard does from `git`'s reading of the command and the command's own text.
  test('a working folder the reader cannot know leaves a relative path where it was placed before (#3337)', () => {
    const paths = (command: string) => byGit(command).map(g => [g.word, g.path ?? null])
    const AS_BEFORE = [['app/globals.css', `${CWD}/app/globals.css`]]
    // A value the shell fills in.
    expect(paths('git --work-tree="$W" restore app/globals.css')).toEqual(AS_BEFORE)
    expect(paths('GIT_WORK_TREE="$W" git checkout -- app/globals.css')).toEqual(AS_BEFORE)
    // Set by an earlier command on the line, git reads it only if it was exported, there or before,
    // which the reader does not follow.
    expect(paths('export GIT_WORK_TREE=/w/x; git restore app/globals.css')).toEqual(AS_BEFORE)
    expect(paths('GIT_WORK_TREE=/w/x; git restore app/globals.css')).toEqual(AS_BEFORE)
    expect(paths('export GIT_DIR=/other/.git GIT_WORK_TREE=/w/x && git checkout -- app/globals.css')).toEqual(AS_BEFORE)
    expect(paths('export GIT_DIR=/other/.git && git checkout -- app/globals.css')).toEqual(AS_BEFORE)
    expect(paths('GIT_DIR=/other/.git; git restore app/globals.css')).toEqual(AS_BEFORE)
    expect(paths('export GIT_DIR=/other/.git; git --work-tree=/w/x rm app/globals.css')).toEqual(AS_BEFORE)
    // After a cd and with -C, as before too.
    expect(paths('export GIT_WORK_TREE=/w/x; cd /w/a && git restore app/globals.css')).toEqual([['app/globals.css', '/w/a/app/globals.css']])
    expect(paths('git -C /w/a --work-tree="$W" restore app/globals.css')).toEqual([['app/globals.css', '/w/a/app/globals.css']])
    // A path written whole names the file it spells wherever git's folders are.
    expect(paths('export GIT_WORK_TREE=/w/x; git restore /w/x/app/globals.css')).toEqual([['/w/x/app/globals.css', '/w/x/app/globals.css']])
  })
  // #1765: a device named as what a command reads (/dev/stdin, /dev/fd/0, /proc/self/fd/0) is never
  // an input, so no guard opens it: a read of one waits for ever on the mod worker's own standard
  // input, and the call it judges never runs. The write is still named, as one whose input is unknown.
  test('a device a command reads is never an input to read', () => {
    expect(read('git apply /dev/stdin').unnamed).toEqual([{ what: 'a patch', words: ['git', 'apply', '/dev/stdin'], inputs: [] }])
    expect(read('patch -p1 < /dev/fd/0').unnamed).toEqual([{ what: 'a patch', words: ['patch', '-p1', '<', '/dev/fd/0'], inputs: [] }])
    expect(read('bash < /dev/stdin').unnamed).toEqual([{ what: 'a bash script on standard input', words: ['bash', '<', '/dev/stdin'], inputs: [], script: true }])
    expect(read('git -C /repo apply /proc/self/fd/0').unnamed.map(u => u.inputs)).toEqual([[]])
    // A relative name is judged where it resolves.
    expect(read('cd /dev && git apply stdin').unnamed.map(u => u.inputs)).toEqual([[]])
    // An ordinary file beside one is still read.
    expect(read('git apply /dev/stdin fix.patch').unnamed.map(u => u.inputs)).toEqual([[`${CWD}/fix.patch`]])
  })
  test('a patch only checked writes nothing', () => {
    expect(read('git apply --check fix.patch').unnamed).toEqual([])
    expect(read('git apply --stat fix.patch').unnamed).toEqual([])
  })
  test('patch with a file to patch names that file as written', () => {
    expect(paths('patch CLAUDE.md fix.diff')).toEqual([`${CWD}/CLAUDE.md`])
  })
  test('an inline script that writes a file is a write the words do not name', () => {
    expect(read(`python3 -c "open('${'/Users'}/dan/.claude/CLAUDE.md', 'a').write('rule')"`).unnamed).toEqual([
      {
        what: 'an inline python3 script',
        words: ['python3', '-c', `open('${'/Users'}/dan/.claude/CLAUDE.md', 'a').write('rule')`],
        inputs: [],
        targets: [`${'/Users'}/dan/.claude/CLAUDE.md`],
        program: `open('${'/Users'}/dan/.claude/CLAUDE.md', 'a').write('rule')`,
        folder: CWD,
      },
    ])
    expect(read(`node -e "require('fs').appendFileSync('AGENTS.md', 'x')"`).unnamed.map(u => u.what)).toEqual(['an inline node script'])
  })
  // #1151: a program's text and the folder it runs in, a cd before it followed, so a guard reads the
  // names in the program it runs, never another command's heredoc data, and places a bare one there.
  test('a program the reader read carries its text and the folder it runs in, or no folder after a cd it cannot follow', () => {
    const fed = "cat > spec.json <<'EOF'\n{ \"styles\": \"screen.css\" }\nEOF\npython3 - <<'EOF'\nf = 'out.css'\nopen(f, 'w').write('x')\nEOF"
    expect(read(`cd /tmp/round && ${fed}`).unnamed).toEqual([
      { what: 'a python3 script on standard input', words: ['python3', '-', '<<EOF'], inputs: [], targets: ['/tmp/round/out.css'], program: "f = 'out.css'\nopen(f, 'w').write('x')", folder: '/tmp/round' },
    ])
    expect(read(`D=/tmp/round; cd $D && ${fed}`).unnamed[0]?.folder).toBe('/tmp/round')
    expect(read(fed).unnamed[0]?.folder).toBe(CWD)
    const lost = read(`cd $UNSET_ROUND && ${fed}`).unnamed[0]
    expect(lost?.program).toContain("f = 'out.css'")
    expect(lost && 'folder' in lost).toBe(false)
  })
  // #1165: and its code, what it holds only as data blanked, so the design round guard reads the
  // names it can open, never those its replacement text quotes as test data.
  test('a python program the shell cannot have changed carries its code, with what it holds as data blanked', () => {
    const data = "  expect(byGit('git checkout -- app/page.tsx')).toEqual([{ path: `${CWD}/app/page.tsx` }])\n"
    // Importing os leaves its files unnamed, so its code is what a guard reads. Without it, since
    // #1171 the file it writes is named, whatever $ or backtick its quoted heredoc holds, and a
    // program whose files are named carries no code.
    const named = `p='tests/x.test.ts'\ns=open(p).read()\nnew='''${data}'''\nopen(p,'w').write(s+new)`
    expect(read(`python3 - <<'EOF'\n${named}\nEOF`).unnamed.map(x => [x.targets, 'code' in x])).toEqual([[[`${CWD}/tests/x.test.ts`], false]])
    const program = `import os\n${named}`
    const u = read(`python3 - <<'EOF'\n${program}\nEOF`).unnamed[0]
    expect(u?.program).toBe(program)
    // All of its block but the last word, which is no name here.
    expect(u?.code).toBe(program.replace(data, `${data.slice(0, -4).replace(/[^\n]/g, ' ')}}])\n`))
    // A -c program holding no $ or backtick is one the shell left as written.
    expect(read(`python3 -c "open(p,'w').write('''app/page.tsx\nx\n''')"`).unnamed[0]?.code).toBe("open(p,'w').write('''            \nx\n''')")
    // Where the shell may have changed the text (an unquoted heredoc holding a $ or a backtick), the
    // program runs a process or the language is not python, data cannot be told apart: no code.
    const none = (command: string) => read(command).unnamed.map(x => 'code' in x)
    expect(none(`python3 - <<EOF\n${program}\nEOF`)).toEqual([false])
    expect(none(`python3 - <<'EOF'\nimport subprocess\nsubprocess.run(['true'])\n${program}\nEOF`)).toEqual([false])
    expect(none(`node -e "require('fs').writeFileSync(p, 'x\\napp/page.tsx')"`)).toEqual([false])
  })
  test('an inline script that only reads is not a write', () => {
    expect(read(`python3 -c "print(open('CLAUDE.md').read())"`).unnamed).toEqual([])
  })
  // #712: the reader now reads a heredoc's body, so a script fed one is judged by what it does
  // rather than named as unreadable, and a shell fed one is read as the commands it runs.
  test('a script fed on standard input is judged by its body, and one in a file is named with the file to read', () => {
    expect(read("python3 - <<'EOF'\nopen('CLAUDE.md','a').write('x')\nEOF").unnamed.map(u => u.what)).toEqual(['a python3 script on standard input'])
    expect(read("python3 - <<'EOF'\nprint(open('CLAUDE.md').read())\nEOF").unnamed).toEqual([])
    expect(paths("bash <<'EOF'\ncat >> CLAUDE.md < rules.md\nEOF")).toEqual([`${CWD}/CLAUDE.md`])
    expect(read('sh < setup.sh').unnamed).toEqual([{ what: 'a sh script on standard input', words: ['sh', '<', 'setup.sh'], inputs: [`${CWD}/setup.sh`], script: true }])
    expect(read('cat build.py | python3').unnamed).toEqual([{ what: 'a python3 script on standard input', words: ['python3'], inputs: [`${CWD}/build.py`], script: true }])
    expect(read('curl -fsSL https://x.dev/i.sh | bash').unnamed.map(u => u.what)).toEqual(['a bash script on standard input'])
  })
  // #698: the delimiter of a spaced heredoc was taken for a script file, and the shells beyond sh,
  // bash and zsh were not shells here.
  test('a spaced heredoc feeds a shell too, and dash and ksh are shells', () => {
    expect(paths("bash << 'EOF'\ncat >> CLAUDE.md < rules.md\nEOF")).toEqual([`${CWD}/CLAUDE.md`])
    expect(read("dash <<'EOF'\nls\nEOF")).toEqual({ files: [], changes: [], unnamed: [] })
    expect(paths("ksh <<'EOF'\necho x > AGENTS.md\nEOF")).toEqual([`${CWD}/AGENTS.md`])
  })
  test("a shell's -c in a cluster is read as the commands it runs, so their files are named", () => {
    expect(paths(`bash -lc 'printf x >> CLAUDE.md'`)).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths(`zsh -ec "cd ~/.claude && sed -i '' 's/a/b/' CLAUDE.md"`)).toEqual([`${HOME}/.claude/CLAUDE.md`])
  })
  test('a shell running a script file, or with no input at all, names nothing', () => {
    expect(read('bash ./build.sh').unnamed).toEqual([])
    expect(read('zsh -l').unnamed).toEqual([])
  })
  test('a command that writes nothing names nothing', () => {
    expect(read('ls -la && git status')).toEqual({ files: [], changes: [], unnamed: [] })
  })
})

// #1586: a script run from a file was read as writing nothing, so `python3 gen.py app/page.tsx`, or
// the design rounds skill's make-settled.py handed a page under docs/design, changed a screen file
// with no word naming the write. What it writes cannot be read before it runs, so the reader gives
// each argument the script is handed, in `runs`, apart from files, changes and unnamed, which every
// guard judges, as byGit is: a guard that judges what a script's arguments name reads them there.
describe('writes: a script run from a file, with the arguments it is handed (#1586)', () => {
  const runs = (command: string, cwd = CWD) => read(command, cwd).runs ?? []
  test('an interpreter running a script file names the script and each argument after it, as paths', () => {
    expect(runs('python3 scripts/gen.py app/page.tsx')).toEqual([
      { what: 'a python3 script file', script: 'scripts/gen.py', path: `${CWD}/scripts/gen.py`, args: [{ word: 'app/page.tsx', path: `${CWD}/app/page.tsx` }] },
    ])
    expect(runs('python3 ~/.claude/skills/design-rounds/make-settled.py settled.json docs/design/x.html').map(r => r.args)).toEqual([
      [
        { word: 'settled.json', path: `${CWD}/settled.json` },
        { word: 'docs/design/x.html', path: `${CWD}/docs/design/x.html` },
      ],
    ])
    expect(runs('bash ./tools/fix.sh src/app.css').map(r => [r.what, r.args.map(a => a.path)])).toEqual([['a bash script file', [`${CWD}/src/app.css`]]])
    expect(runs('node build.mjs --out=dist/site.css').map(r => r.args)).toEqual([[{ word: 'dist/site.css', path: `${CWD}/dist/site.css` }]])
  })
  test('a script file run directly, by a path or a script name, is one too', () => {
    expect(runs('./tools/fix app/page.tsx').map(r => [r.what, r.script, r.args.map(a => a.word)])).toEqual([['a script file run directly', './tools/fix', ['app/page.tsx']]])
    expect(runs('make-settled.py settled.json docs/design/x.html').map(r => r.args.map(a => a.word))).toEqual([['settled.json', 'docs/design/x.html']])
    expect(runs(`${'/Users'}/dan/bin/gen.sh app/page.tsx`).map(r => r.path)).toEqual([`${'/Users'}/dan/bin/gen.sh`])
  })
  test('a cd before it is followed, a variable the command set is read, and a pattern keeps its folder', () => {
    expect(runs('cd /w/shop && python3 gen.py app/page.tsx').map(r => r.args[0]?.path)).toEqual(['/w/shop/app/page.tsx'])
    expect(runs('P=/w/shop/app/page.tsx; python3 gen.py "$P"').map(r => r.args)).toEqual([[{ word: '$P', path: '/w/shop/app/page.tsx' }]])
    expect(runs("python3 gen.py 'app/*.tsx'").map(r => r.args)).toEqual([[{ word: 'app/*.tsx', folder: `${CWD}/app`, quoted: true }]])
    expect(runs('python3 gen.py app/*.tsx').map(r => r.args)).toEqual([[{ word: 'app/*.tsx', folder: `${CWD}/app` }]])
    // The script named through a variable the command set (lessons review at 856eb73): found by its value.
    expect(runs('S=scripts/gen.py; python3 "$S" app/page.tsx').map(r => [r.script, r.path, r.args.map(a => a.word)])).toEqual([['$S', `${CWD}/scripts/gen.py`, ['app/page.tsx']]])
  })
  test('options, standard input, output redirects, addresses and the interpreter options before the script are no argument', () => {
    expect(runs('python3 -W ignore gen.py -v -o app/page.tsx < in.txt > log.txt 2>&1').map(r => r.args.map(a => a.word))).toEqual([['app/page.tsx']])
    // Handed nothing that may name a file, it is given nowhere.
    expect(runs('python3 fetch.py https://x.dev/page.html host:site.css')).toEqual([])
    expect(runs('python3 fetch.py https://x.dev/page.html app/page.tsx').map(r => r.args.map(a => a.word))).toEqual([['app/page.tsx']])
    // The redirect is still a write the reader names, as it always was.
    expect(paths('python3 gen.py > out.html')).toEqual([`${CWD}/out.html`])
  })
  // #1951: a pattern whose every pattern character is quoted reaches the script as its characters,
  // matched against no file, and is marked so; one the shell expands, or spelled both ways in the
  // command, is not.
  test('a quoted pattern a script is handed is marked quoted, wherever the command spells it only so', () => {
    const quoted = (command: string) => runs(command).map(r => r.args.map(a => [a.word, a.quoted === true]))
    expect(quoted(`cd /w/hooks && python3 /tmp/sweep.py check.sh "a push" '*push*'`)).toEqual([[['check.sh', false], ['a push', false], ['*push*', true]]])
    expect(quoted('python3 s.py "app/*.css" app/\\*x')).toEqual([[['app/*.css', true], ['app/*x', true]]])
    expect(quoted(`python3 s.py '*x*' *x* ''*y'' "app/"*z`)).toEqual([[['*x*', false], ['*x*', false], ['*y', false], ['app/*z', false]]])
    expect(quoted(`P='app/*x'; python3 s.py $P`)).toEqual([[['$P', false]]])
    expect(quoted(`npx prettier --write 'app/*'`)).toEqual([[['app/*', true]]])
    // Only a pattern is marked: a quoted name holding none is a path, as ever.
    expect(runs(`python3 s.py 'a b.txt'`).map(r => r.args)).toEqual([[{ word: 'a b.txt', path: `${CWD}/a b.txt` }]])
  })
  test('a script run in a substitution is read too', () => {
    expect(runs('x=$(python3 gen.py app/page.tsx)').map(r => r.args.map(a => a.path))).toEqual([[`${CWD}/app/page.tsx`]])
  })
  // #1953: a for loop's variable was given as written, so a guard holding a name a variable fills
  // in held `for t in a.sh b.sh; do bash run.sh $t; done`, 199 of the 431 such arguments over this
  // Mac's commands. A loop over plain words gives the variable each of them, as an assignment gives
  // its value; one over a pattern, an expansion or a word holding a space is still given as written.
  test('a for loop over plain words hands a script each word; any other loop hands it the word as written', () => {
    const args = (command: string) => runs(command).map(r => r.args.map(a => [a.word, a.path ?? null]))
    expect(args('for t in a.sh b.sh; do python3 run.py tests/$t; done')).toEqual([[['tests/$t', `${CWD}/tests/a.sh`], ['tests/$t', `${CWD}/tests/b.sh`]]])
    expect(args('for f in page.tsx; do python3 gen.py "app/${f}"; done')).toEqual([[['app/${f}', `${CWD}/app/page.tsx`]]])
    for (const loop of ['for f in app/*.tsx', 'for f in $LIST', 'for f in $(ls)', 'for f'])
      expect({ loop, args: args(`${loop}; do python3 gen.py $f; done`) }).toEqual({ loop, args: [[['$f', null]]] })
    // A word holding a space (an issue's title) is read whole and as each piece a split would make,
    // with and without the text around it: more readings than any shell makes, never fewer.
    expect(args('for f in "a b" c; do python3 gen.py x/$f; done').map(r => r.map(([, p]) => (p as string).slice(CWD.length + 1)))).toEqual([['x/a b', 'x/a', 'a', 'x/b', 'b', 'x/c']])
    // Set some other way too, its value is unknown, as an assignment given two values is.
    expect(args('for f in a.md; do :; done; f=$(ls); python3 gen.py $f')).toEqual([[['$f', null]]])
    expect(args('f=$(ls); for f in a.md; do python3 gen.py $f; done')).toEqual([[['$f', null]]])
    // Text run by eval or source may set the loop's variable to anything, so its value is unknown
    // after it, as every other variable's is (lessons review of #1968 at a47a667).
    expect(args('for f in a.md; do eval "f=app/page.tsx"; python3 gen.py $f; done')).toEqual([[['$f', null]]])
    expect(args('for f in a.md; do . ./setf.sh; python3 gen.py $f; done')).toEqual([[['$f', null]]])
  })
  // #2527: a loop over quoted search terms (`for t in "*push*" gate; do bash probe.sh --like "$t";
  // done`) left its variable as written, since a pattern character is no plain word, so both guards
  // held a read only probe as writing "$t". A word the shell hands on as written (every pattern
  // character quoted, nothing expanded) is a loop word the reader follows too, and where its value
  // reaches a script as its characters it is marked quoted, named by those characters, as the same
  // word spelled out is (#1951). Only bash and sh match an unquoted value against files (#1834), so
  // there the value is a pattern again, and an expansion in the loop's words leaves it unknown.
  test('a loop over quoted patterns hands a script each as its characters, where the shell matches it against no file (#2527)', () => {
    const handed = (command: string, shell?: string) => commandWrites(command, CWD, HOME, shell).runs?.map(r => r.args)
    expect(handed(`for t in "*push*" 'gate'; do bash probe.sh --like "$t"; done`)).toEqual([[{ word: '*push*', folder: CWD, quoted: true }, { word: '$t', path: `${CWD}/gate` }]])
    // As the same word spelled out is.
    expect(handed(`bash probe.sh --like "*push*"`)).toEqual([[{ word: '*push*', folder: CWD, quoted: true }]])
    // Under zsh an unquoted value is matched against no file either.
    expect(handed(`for t in "*push*"; do bash probe.sh $t; done`, '/bin/zsh')).toEqual([[{ word: '*push*', folder: CWD, quoted: true }]])
    // Under bash it is: a pattern again, given by its folder, never marked.
    expect(handed(`for t in "*push*"; do bash probe.sh $t; done`, '/bin/bash')).toEqual([[{ word: '$t', folder: CWD }]])
    expect(handed(`for t in "*push*"; do bash probe.sh "$t"; done`, '/bin/bash')).toEqual([[{ word: '*push*', folder: CWD, quoted: true }]])
    // A pattern beside the value, or another variable's value in the word, may be matched: not marked.
    expect(handed(`for t in "a*"; do bash probe.sh $t*; done`)).toEqual([[{ word: '$t*', folder: CWD }]])
    expect(handed(`P=x; for t in "a*"; do bash probe.sh "$P$t"; done`)).toEqual([[{ word: '$P$t', folder: CWD }]])
    // A loop word the shell matches or expands still leaves the value unknown, given as written.
    for (const loop of [`for t in "*push*" *.md`, `for t in "*push*" "$X"`, `for t in "*push*" $(cat list)`])
      expect({ loop, handed: handed(`${loop}; do bash probe.sh "$t"; done`) }).toEqual({ loop, handed: [[{ word: '$t' }]] })
    // A write the loop's value names is still a write, given by its folder as a pattern is.
    expect(read(`for t in "a*b" c; do echo x > "$t"; done`).files).toEqual([{ word: '$t', folder: CWD }, { word: '$t', path: `${CWD}/c` }])
  })
  // #1953: a $ in single quotes or after a backslash is no variable, but the run's argument read the
  // same as one, its quotes taken off, so a script handed a regex ('x$') or prose ('costs $5') read as
  // handed a variable's value. Such a word is marked `unexpanded`, and is never read as a value.
  test('a word whose every $ is quoted or escaped is marked unexpanded, and is never read as a value', () => {
    const marked = (command: string) => runs(command).map(r => r.args.map(a => [a.word, a.unexpanded === true]))
    expect(marked(`python3 s.py 'x$' 'costs $5' \\$HOME "a\\$b"`)).toEqual([[['x$', true], ['costs $5', true], ['$HOME', true], ['a$b', true]]])
    expect(marked(`python3 s.py $P "$P" "a $P" '$P'$Q \`x\` "$(x)"`)).toEqual([[['$P', false], ['$P', false], ['a $P', false], ['$P$Q', false], ['`x`', false], ['$(x)', false]]])
    // Quoted where the command set the name, it is still the word as written, and names the file it
    // spells (#2402).
    expect(runs(`P=a.md; python3 s.py '$P'`).map(r => r.args)).toEqual([[{ word: '$P', path: `${CWD}/$P`, unexpanded: true }]])
  })
  // #2402: #2320 taught the area check to read such a word as text, but every $ made absolutePath
  // name no path, so a script handed "src/big.ts$" was never judged by the file it spells. A word
  // whose every $ and backtick the shell leaves as written (Command.unexpanded) names that file;
  // one with any $ the shell expands still names none.
  test('a word whose every $ the shell leaves as written names the file it spells; one with a $ the shell expands names none (#2402)', () => {
    const named = (command: string) => runs(command).map(r => r.args.map(a => [a.word, a.path ?? null, a.folder ?? null]))
    expect(named(`python3 probe.py "src/big.ts$" 'x$' 'costs $5' \\$HOME "a\\$b" foo$ "x$/y" 'q\`'`)).toEqual([
      [
        ['src/big.ts$', `${CWD}/src/big.ts$`, null],
        ['x$', `${CWD}/x$`, null],
        ['costs $5', `${CWD}/costs $5`, null],
        // A $HOME the shell leaves as written is no home folder.
        ['$HOME', `${CWD}/$HOME`, null],
        ['a$b', `${CWD}/a$b`, null],
        ['foo$', `${CWD}/foo$`, null],
        ['x$/y', `${CWD}/x$/y`, null],
        ['q`', `${CWD}/q\``, null],
      ],
    ])
    // A pattern beside a $ left as written still names no path and no folder: Command.literal reads
    // every $ as an expansion (#1951, #2320), so a quoted regex would read as a pattern matched
    // against files.
    expect(named(`python3 s.py 'a$'*.ts "^foo.*bar$"`)).toEqual([[['a$*.ts', null, null], ['^foo.*bar$', null, null]]])
    // Every other word holding a $ or a backtick names nothing: a real expansion, quoted or bare, a
    // word mixing one left as written with one expanded, and a word spelled both ways in one command.
    expect(named(`python3 s.py "$OUT/big.ts" $P '$P'$Q "a$"$B \`x\` "$(x)" x$'y' "\${X}"`)).toEqual([
      [
        ['$OUT/big.ts', null, null],
        ['$P', null, null],
        ['$P$Q', null, null],
        ['a$$B', null, null],
        ['`x`', null, null],
        ['$(x)', null, null],
        ['x$y', null, null],
        ['${X}', null, null],
      ],
    ])
    expect(named(`python3 s.py 'x$y' x$y`)).toEqual([[['x$y', null, null], ['x$y', null, null]]])
  })
  test('a redirect, an edit and a cd to a word whose every $ is left as written name the file it spells (#2402)', () => {
    expect(paths(`echo hi > 'out$.txt'`)).toEqual([`${CWD}/out$.txt`])
    expect(read(`echo hi > 'out$.txt'`).stdout).toEqual([{ word: 'out$.txt', path: `${CWD}/out$.txt` }])
    expect(paths(`sed -i '' 's/a/b/' 'src/a$.ts'`)).toEqual([`${CWD}/src/a$.ts`])
    expect(paths(`cd 'w$' && echo hi > a.txt`)).toEqual([`${CWD}/w$/a.txt`])
    expect(paths(`rm 'old$.txt'`)).toEqual([])
    expect(read(`rm 'old$.txt'`).changes).toEqual([{ word: 'old$.txt', path: `${CWD}/old$.txt`, does: 'remove' }])
    // A write to a word holding a $ the shell expands still names no file.
    expect(paths(`echo hi > "$OUT/big.ts"`)).toEqual(['(as written) $OUT/big.ts'])
    expect(paths(`cd "$D" && echo hi > a.txt`)).toEqual(['(as written) a.txt'])
  })
  test('what is no script file run names no run: inline code, standard input, awk -f, a plain command', () => {
    for (const command of [
      "python3 -c 'print(1)' app/page.tsx",
      'cat gen.py | python3 - app/page.tsx',
      'awk -f prog.awk app/site.css',
      'cat app/page.tsx',
      'grep -n x app/page.tsx',
      'bash ./build.sh',
      'ls -la && git status',
    ])
      expect({ command, runs: runs(command) }).toEqual({ command, runs: [] })
    // A script with no arguments is given nowhere, so every result without one keeps its shape.
    expect(read('bash ./build.sh')).toEqual({ files: [], changes: [], unnamed: [] })
  })
})

// #1682: a module run with python -m and a tool run through npx were read as writing nothing, so
// `npx prettier --write app/page.tsx` and `python3 -m json.tool in.json app/data.json` changed files
// no guard judged. Measured over this Mac's transcripts for the 14 days to 2026-10-24: of 33,918
// Bash calls, 469 ran a tool through npx (358 with a path among its words; prettier 100, eslint 19)
// and 24 ran a python module (17 with a path), where pnpm dlx, yarn dlx, npm exec, bunx, uv run and
// uvx ran none. What either writes cannot be read before it runs, so each is a run as a script file
// is, its arguments given in `runs`.
describe('writes: a module run with python -m and a tool run through npx (#1682)', () => {
  const runs = (command: string, cwd = CWD) => read(command, cwd).runs ?? []
  test('python -m names the module and each argument after it, as paths, its options before it read as python reads them', () => {
    expect(runs('python3 -m json.tool in.json out.json')).toEqual([
      {
        what: 'a python3 module run with -m',
        script: 'json.tool',
        tool: true,
        args: [
          { word: 'in.json', path: `${CWD}/in.json` },
          { word: 'out.json', path: `${CWD}/out.json` },
        ],
      },
    ])
    for (const command of ['python3 -I -m tool app/page.tsx', 'python3 -mtool app/page.tsx', 'python3 -W ignore -m tool app/page.tsx', 'python3 -Im tool app/page.tsx', 'python3.12 -m tool -v app/page.tsx', 'timeout 60 python3 -m tool app/page.tsx'])
      expect({ command, runs: runs(command).map(r => [r.script, r.args.map(a => a.path)]) }).toEqual({ command, runs: [['tool', [`${CWD}/app/page.tsx`]]] })
    expect(runs('cd /w/shop && python3 -m tool app/page.tsx').map(r => r.args[0]?.path)).toEqual(['/w/shop/app/page.tsx'])
  })
  test('python -m with nothing after the module, inline code before it, or no module names no run', () => {
    for (const command of ['python3 -m unittest', 'python3 -m', "python3 -c 'import sys' -m tool app/page.tsx", 'python3 -m tool -v --quiet'])
      expect({ command, runs: runs(command) }).toEqual({ command, runs: [] })
  })
  test('a tool run through npx names the tool and each argument after it, past npx options and their values', () => {
    expect(runs('npx prettier --write app/page.tsx')).toEqual([{ what: 'a tool run through npx', script: 'prettier', tool: true, args: [{ word: 'app/page.tsx', path: `${CWD}/app/page.tsx` }] }])
    for (const command of [
      'npx --yes prettier@3 --write app/page.tsx',
      'npx -y eslint --fix app/page.tsx',
      'npx -p @biomejs/biome biome format --write app/page.tsx',
      'npx --package=@biomejs/biome biome format --write app/page.tsx',
      'npx -- prettier --write app/page.tsx',
      'rtk npx prettier --write app/page.tsx',
    ])
      expect({ command, args: runs(command).map(r => r.args.map(a => a.word).filter(w => w !== 'format')) }).toEqual({ command, args: [['app/page.tsx']] })
    expect(runs('npx -p @biomejs/biome biome format --write app/page.tsx').map(r => r.script)).toEqual(['biome'])
    expect(runs('cd /w/shop && npx prettier --write app/page.tsx').map(r => r.args[0]?.path)).toEqual(['/w/shop/app/page.tsx'])
    expect(runs("npx prettier --write 'app/*.tsx'").map(r => r.args)).toEqual([[{ word: 'app/*.tsx', folder: `${CWD}/app`, quoted: true }]])
  })
  // #1815: a tool's operands are, by its own convention, the files it works on, where a script file's
  // arguments are its own (a commit, a test's name), so a guard can tell the two apart by `tool`.
  test('a tool or a module is marked as one; a script file, run by an interpreter or by its own name, is not', () => {
    for (const command of ['npx prettier --write $(git ls-files src)', 'python3 -m black $(git ls-files src)'])
      expect({ command, tool: runs(command).map(r => r.tool) }).toEqual({ command, tool: [true] })
    for (const command of ['python3 gen.py $(git ls-files src)', './tools/fix app/page.tsx', 'bash ~/.claude/hooks/lib/pr-review.sh start --sha $(git rev-parse HEAD)'])
      expect({ command, tool: runs(command).map(r => r.tool) }).toEqual({ command, tool: [undefined] })
  })
  test('npx with no tool, a tool handed nothing, or a command line given by -c names no run', () => {
    for (const command of ['npx', 'npx --yes', 'npx vitest', "npx -c 'prettier --write app/page.tsx'", 'npx --call=x'])
      expect({ command, runs: runs(command) }).toEqual({ command, runs: [] })
  })
})

// #1726: an option written with a space gave its value to `runs` as a file the run may write, so the
// collision guard and the design round guard could hold `python3 -m http.server --bind 127.0.0.1` over
// an address and `npx tsc -p tsconfig.json` over a config file it only reads. Measured over this
// Mac's 103,099 distinct Bash commands on 2026-10-25: 9,858 had a run, handing on 24,644 words, 3,761
// of them right after an option word. For a known tool the value of each option it reads a value for
// is no longer handed on (tsc -p 60 times, http.server --bind 17, vitest --config 3, prettier
// --stdin-filepath 4, pytest -n 3 and -p 2, ruff --config 1). A script file's own options are not
// known, and on this Mac they carry the files it writes (--out, --out-html, --out-tsv, --log,
// --results-dir), so a script's option values stay handed on, as the test above holds for -o.
describe('writes: the value of a known option a tool reads is no file it writes (#1726)', () => {
  const words = (command: string) => (read(command).runs ?? []).map(r => r.args.map(a => a.word))
  test('a module run with -m: http.server --bind and --directory, pytest -n and -p, unittest -s and -k, ruff --config', () => {
    expect(words('python3 -m http.server --bind 127.0.0.1')).toEqual([])
    expect(words('python3 -m http.server 8000 --bind 127.0.0.1 --directory site')).toEqual([['8000']])
    expect(words('python3 -m http.server -b 127.0.0.1 -d site 8000')).toEqual([['8000']])
    // With an update flag, so the run hands its files on (#2823) and only -n and -p's values are read.
    expect(words('python3 -m pytest --snapshot-update -n 4 -p no:cacheprovider tests/test_app.py')).toEqual([['tests/test_app.py']])
    expect(words('python3 -m unittest -s tests -k parse')).toEqual([])
    expect(words('python3 -m ruff check --config ruff.toml app')).toEqual([['check', 'app']])
  })
  test('a tool run through npx: tsc -p, vitest --config and --root, prettier --stdin-filepath, eslint -c', () => {
    expect(words('npx tsc -p tsconfig.json')).toEqual([])
    expect(words('npx tsc --project tools/tsconfig.json --noEmit')).toEqual([])
    // With -u, so the run hands its words on (#2823) and only --config and --root's values are read.
    expect(words('npx vitest run -u --config vitest.config.ts --root app')).toEqual([['run']])
    expect(words('npx prettier --stdin-filepath app/page.tsx')).toEqual([])
    expect(words('npx eslint -c eslint.config.js --fix app/page.tsx')).toEqual([['app/page.tsx']])
  })
  test('an option a tool writes a file through keeps its value, and a flag takes no value', () => {
    // tsc --outDir and eslint -o name what they write; prettier --write is a flag, so its next word
    // is the file it writes.
    expect(words('npx tsc -p tsconfig.json --outDir dist')).toEqual([['dist']])
    expect(words('npx eslint -o report.txt --fix app')).toEqual([['report.txt', 'app']])
    expect(words('npx prettier --write app/page.tsx')).toEqual([['app/page.tsx']])
  })
  test("a script file's own options are not known, so their values are still handed on", () => {
    expect(words('python3 gen.py --bind 127.0.0.1 --out report.html')).toEqual([['127.0.0.1', 'report.html']])
    expect(words('node build.mjs -p tsconfig.json')).toEqual([['tsconfig.json']])
  })
})

// #1827: a known tool that changes the files it is handed only when a flag tells it to handed them
// all on as files it may write, so `npx prettier --check src` was held like `--write`. In the #1815
// replay of this Mac's 104,832 distinct Bash commands, every new design round guard hold was a
// prettier --check. By each tool's own documentation, prettier rewrites files in place only with
// --write (-w), and otherwise prints them or, with --check, -c, --list-different or -l, names the ones
// that differ; eslint changes them only with --fix (--fix-dry-run fixes in memory). Without that flag
// the run hands on only the file an option of its own writes (eslint -o, --cache-location).
describe("writes: a known tool's mode that changes no file it is handed hands none on (#1827)", () => {
  const words = (command: string) => (read(command).runs ?? []).map(r => r.args.map(a => a.word))
  test('prettier hands on its files only with --write or -w', () => {
    for (const command of [
      'npx prettier --check src',
      'npx prettier -c src app/page.tsx',
      'npx prettier --list-different src',
      'npx prettier -l src',
      'npx prettier src/a.ts',
      'npx prettier --check $(git ls-files src)',
      'npx --yes prettier@3 --check src',
      'rtk npx prettier --check src',
    ])
      expect({ command, words: words(command) }).toEqual({ command, words: [] })
    expect(words('npx prettier --write src')).toEqual([['src']])
    expect(words('npx prettier -w src')).toEqual([['src']])
    expect(words('npx prettier --check --write src')).toEqual([['src']])
    expect(words('npx prettier -l --write src')).toEqual([['src']])
    // A cluster of short flags carrying -w writes, one without it does not.
    expect(words('npx prettier -uw src')).toEqual([['src']])
    expect(words('npx prettier -cu src')).toEqual([])
    expect(words('npx --yes prettier@3 --write src')).toEqual([['src']])
  })
  test('eslint hands on its files only with --fix; --fix-dry-run writes none, and -o still names its report', () => {
    expect(words('npx eslint src')).toEqual([])
    expect(words('npx eslint --fix-dry-run src')).toEqual([])
    expect(words('npx eslint -c eslint.config.js app/page.tsx')).toEqual([])
    expect(words('npx eslint --fix src')).toEqual([['src']])
    expect(words('npx eslint --fix-dry-run --fix src')).toEqual([['src']])
    expect(words('npx eslint -o report.txt app')).toEqual([['report.txt']])
    expect(words('npx eslint --output-file=report.txt app')).toEqual([['report.txt']])
    expect(words('npx eslint --cache --cache-location .cache/eslint app')).toEqual([['.cache/eslint']])
    expect(words('npx prettier --check --cache --cache-location .cache/prettier src')).toEqual([['.cache/prettier']])
  })
  test('a word that may hold a flag the reader cannot see keeps every file handed on', () => {
    // A variable it cannot read, or one whose value the shell splits into words, may be --write.
    expect(words('npx prettier $MODE src')).toEqual([['$MODE', 'src']])
    expect(words('npx prettier --check ${FLAGS} src')).toEqual([['${FLAGS}', 'src']])
    expect(words('for f in $LIST; do npx prettier $f; done')).toEqual([['$f']])
    // A loop over plain words gives its words (#1953): no flag among them, so nothing is written.
    expect(words('for f in src/a.ts; do npx prettier $f; done')).toEqual([])
    expect(words('F="src --write"; npx prettier --check $F')).toEqual([['$F']])
    expect(words('F=--write; npx prettier --check $F src')).toEqual([['src']])
    expect(words('npx eslint "$@"')).toEqual([['$@']])
    expect(words('npx eslint `echo --fix` src')).toEqual([['`echo --fix`', 'src']])
    // A command substitution in its operands gives the files it works on (#1815), so it is read as them.
    expect(words('npx prettier --check $(git ls-files src)')).toEqual([])
    expect(words('npx prettier --check "$(git diff --name-only HEAD)" src/$(cat name)')).toEqual([])
  })
  test('a tool with no such mode known, a module, or a script file, still hands on every file', () => {
    expect(words('npx biome check src')).toEqual([['check', 'src']])
    expect(words('python3 -m black --check src')).toEqual([['src']])
    expect(words('python3 prettier.py --check src')).toEqual([['src']])
  })
})

// #2823: `npx vitest run <three test paths> | grep -v ... | tail` handed every test path on as a file
// the run may write, so the area check held it for a source file under one of those folders. A test
// runner changes the files it is handed only when a flag says so: vitest -u or --update, jest -u or
// --updateSnapshot, a pytest snapshot plugin's update flag, bun test -u or --update-snapshots. Without
// one it hands on only the file an output option of its own writes. `bun test` is bun's runner,
// never a script file named test, and `node --test` runs each operand as a test file, none of them
// another's arguments; each is read as a tool run, by the same write forms.
describe('writes: a test runner hands on the files it is handed only when a flag updates them (#2823)', () => {
  const words = (command: string) => (read(command).runs ?? []).map(r => r.args.map(a => a.word))
  test('a test runner handed paths and no update flag hands none on', () => {
    for (const command of [
      'npx vitest run tests/a tests/b src/x.test.ts | grep -v ok | tail',
      'npx vitest tests/a.test.ts',
      'npx vitest run --config vitest.config.ts --root app tests/a',
      'npx --yes vitest@2 run tests/a',
      'npx jest tests/ src/lib',
      'python3 -m pytest tests/a tests/b -q',
      'python3 -m pytest -n 4 -p no:cacheprovider tests/test_app.py',
      'python3 -m unittest tests/a.py tests/b',
      'bun test tests/a tests/b',
      'bun test tests/a.test.ts',
      'node --test tests/a.test.mjs tests/b',
      'node --import tsx --test tests/a.test.ts tests/b.test.ts',
    ])
      expect({ command, words: words(command) }).toEqual({ command, words: [] })
  })
  test('an update flag hands every path on, and an output option hands on the file it writes', () => {
    expect(words('npx vitest run -u tests/a')).toEqual([['run', 'tests/a']])
    expect(words('npx vitest run --update tests/a')).toEqual([['run', 'tests/a']])
    expect(words('npx vitest run -u --config vitest.config.ts --root app')).toEqual([['run']])
    expect(words('npx jest -u tests/')).toEqual([['tests/']])
    expect(words('npx jest --updateSnapshot tests/')).toEqual([['tests/']])
    expect(words('python3 -m pytest --snapshot-update tests/a')).toEqual([['tests/a']])
    // An option written --name=value gives its value, as every run's does (#1586).
    expect(words('python3 -m pytest --inline-snapshot=fix tests/a')).toEqual([['fix', 'tests/a']])
    expect(words('bun test -u tests/a')).toEqual([['tests/a']])
    expect(words('bun test --update-snapshots tests/a')).toEqual([['tests/a']])
    expect(words('npx vitest run tests/a --outputFile=report.json')).toEqual([['report.json']])
    expect(words('npx vitest run tests/a --outputFile.junit junit.xml')).toEqual([['junit.xml']])
    // Written with =, the value is the file, never the word after it (lessons review of 2eb58e8).
    expect(words('npx vitest run --outputFile.junit=junit.xml tests/a')).toEqual([['junit.xml']])
    expect(words('npx vitest run --outputFile=report.json tests/a')).toEqual([['report.json']])
    expect(words('npx jest tests/ --outputFile out.json')).toEqual([['out.json']])
    expect(words('python3 -m pytest tests/a --junitxml=r.xml')).toEqual([['r.xml']])
    expect(words('python3 -m pytest tests/a --basetemp tmp/run')).toEqual([['tmp/run']])
    expect(words('python3 -m pytest tests/a --log-file=run.log')).toEqual([['run.log']])
    expect(words('python3 -m pytest tests/a --resultlog run.txt')).toEqual([['run.txt']])
    expect(words('bun test tests/a --reporter-outfile out.xml')).toEqual([['out.xml']])
    expect(words('node --test --test-reporter-destination=out.txt tests/a tests/b')).toEqual([['out.txt']])
  })
  test('a word that may hold a flag the reader cannot see keeps every path handed on', () => {
    expect(words('npx vitest run $FLAGS tests/a')).toEqual([['run', '$FLAGS', 'tests/a']])
    expect(words('bun test "$@"')).toEqual([['$@']])
  })
  test('a script file run by bun or node is still read as one, its words its own arguments', () => {
    expect(words('bun ./test tests/a')).toEqual([['tests/a']])
    expect(words('bun run.ts out.ts')).toEqual([['out.ts']])
    expect(words('node tests/a.test.mjs out.ts')).toEqual([['out.ts']])
    expect(words('node build.mjs --test out.ts')).toEqual([['out.ts']])
  })
})

// #1834: a variable the command set was read as its value but handed on as one word even unquoted,
// so under bash `F="--write src"; npx prettier --check $F` handed on nothing and `F="a.ts b.ts";
// python3 gen.py $F` one path no file has. bash, sh, dash and ksh split an unquoted expansion's value
// on whitespace; zsh does not (measured in this Mac's Bash tool on 2026-10-28: /bin/zsh 5.9 printed
// `[a b]` for `F="a b"; printf '[%s]\n' $F`). So the reader follows the shell the line runs in: the
// one Claude Code runs a Bash call in, and for a script a shell is given, that shell.
describe("writes: an unquoted variable's value is split into words as the shell running it does (#1834)", () => {
  const handed = (command: string, shell?: string) => (commandWrites(command, CWD, HOME, shell).runs ?? []).map(r => r.args.map(a => a.path ?? `(as written) ${a.word}`))
  test('under bash an unquoted value is split into words, and a split --write makes prettier a writing run', () => {
    expect(commandWrites('F="--write src"; npx prettier --check $F', CWD, HOME, '/bin/bash').runs).toEqual([
      { what: 'a tool run through npx', script: 'prettier', tool: true, args: [{ word: '$F', path: `${CWD}/src` }] },
    ])
    expect(commandWrites('F="a.ts b.ts"; python3 gen.py $F', CWD, HOME, '/bin/bash').runs?.[0]?.args).toEqual([
      { word: '$F', path: `${CWD}/a.ts` },
      { word: '$F', path: `${CWD}/b.ts` },
    ])
    expect(handed('F="src --write"; npx prettier --check $F', '/bin/bash')).toEqual([[`${CWD}/src`]])
    expect(handed('F="a.ts b.ts"; python3 gen.py $F', '/opt/homebrew/bin/bash')).toEqual([[`${CWD}/a.ts`, `${CWD}/b.ts`]])
  })
  test('a quoted value is kept whole', () => {
    expect(commandWrites('F="a.ts b.ts"; python3 gen.py "$F"', CWD, HOME, '/bin/bash').runs?.[0]?.args).toEqual([{ word: '$F', path: `${CWD}/a.ts b.ts` }])
    expect(handed(`F="a.ts b.ts"; python3 gen.py "\${F}" x.ts`, '/bin/bash')).toEqual([[`${CWD}/a.ts b.ts`, `${CWD}/x.ts`]])
    // A quoted part of a word stays whole while the unquoted part beside it splits.
    expect(handed(`F="a b"; G="c d"; python3 gen.py "$F"$G`, '/bin/bash')).toEqual([[`${CWD}/a bc`, `${CWD}/d`]])
  })
  test('the split joins the text around it, leading and trailing spaces end a word, and an empty value hands on nothing', () => {
    expect(handed('F="a b"; python3 gen.py x$F.ts', '/bin/bash')).toEqual([[`${CWD}/xa`, `${CWD}/b.ts`]])
    expect(handed('F=" a"; python3 gen.py x$F', '/bin/bash')).toEqual([[`${CWD}/x`, `${CWD}/a`]])
    expect(handed(`F="a  "; python3 gen.py \${F}y`, '/bin/bash')).toEqual([[`${CWD}/a`, `${CWD}/y`]])
    expect(handed('F=""; python3 gen.py $F out.ts', '/bin/bash')).toEqual([[`${CWD}/out.ts`]])
  })
  test("a redirect's target is kept whole, since bash refuses a split one as ambiguous and writes nothing", () => {
    expect(commandWrites('F="a b"; echo x > $F', CWD, HOME, '/bin/bash').files).toEqual([{ word: '$F', path: `${CWD}/a b` }])
  })
  test('under zsh, or a shell not known, an unquoted value is kept whole, as before', () => {
    for (const shell of ['/bin/zsh', undefined]) {
      expect(handed('F="a.ts b.ts"; python3 gen.py $F', shell)).toEqual([[`${CWD}/a.ts b.ts`]])
      expect(handed('F="--write src"; npx prettier --check $F', shell)).toEqual([])
    }
  })
  test('a script given to a shell is split as that shell splits, whatever runs the line', () => {
    expect(handed(`bash -c 'F="a.ts b.ts"; python3 gen.py $F'`, '/bin/zsh')).toEqual([[`${CWD}/a.ts`, `${CWD}/b.ts`]])
    expect(handed(`sh -c 'F="a.ts b.ts"; python3 gen.py $F'`)).toEqual([[`${CWD}/a.ts`, `${CWD}/b.ts`]])
    expect(handed(`bash <<'EOF'\nF="--write src"; npx prettier --check $F\nEOF`, '/bin/zsh')).toEqual([[`${CWD}/src`]])
    expect(handed(`zsh -c 'F="a.ts b.ts"; python3 gen.py $F'`, '/bin/bash')).toEqual([[`${CWD}/a.ts b.ts`]])
    // A command substitution runs in the shell of the line it sits in.
    expect(handed(`bash -c 'echo $(F="a.ts b.ts"; python3 gen.py $F)'`, '/bin/zsh')).toEqual([[`${CWD}/a.ts`, `${CWD}/b.ts`]])
  })
})

// The shell Claude Code runs a Bash call in: CLAUDE_CODE_SHELL where it names a bash or zsh, which
// Claude Code takes over everything (its own message: `CLAUDE_CODE_SHELL="..." is not a valid
// bash/zsh path, falling back to detection`), otherwise $SHELL where it names one. Otherwise Claude
// Code finds one itself, which cannot be known here.
describe('callShell: the shell a Bash call runs in (#1834)', () => {
  test('CLAUDE_CODE_SHELL naming bash or zsh, otherwise SHELL naming one, otherwise not known', () => {
    expect(callShell({ SHELL: '/bin/zsh' })).toBe('/bin/zsh')
    expect(callShell({ SHELL: '/opt/homebrew/bin/bash' })).toBe('/opt/homebrew/bin/bash')
    expect(callShell({ CLAUDE_CODE_SHELL: '/bin/bash', SHELL: '/bin/zsh' })).toBe('/bin/bash')
    expect(callShell({ CLAUDE_CODE_SHELL: '/usr/local/bin/fish', SHELL: '/bin/zsh' })).toBe('/bin/zsh')
    expect(callShell({ SHELL: '/usr/local/bin/fish' })).toBeUndefined()
    expect(callShell({})).toBeUndefined()
  })
})

// #712: the collision guard and no build read writes here now, so what each kept that this did
// not moved in: a file removed, stamped, emptied, made or changed in mode (`changes`, beside the
// files content is put into, which is all ask before saving reads), a folder removal with its tree,
// find's own deletes and files, and where the old copies disagreed, the answer each case decided.
const changes = (command: string, cwd = CWD) => read(command, cwd).changes.map(c => `${c.does} ${c.path ?? `(as written) ${c.word}`}${c.tree ? ' tree' : ''}`)

describe('writes: changes that put no content in, carried over from the collision guard and no build (#712)', () => {
  test('rm, unlink and rmdir remove each file they name', () => {
    expect(changes('rm notes.txt /abs/b.txt')).toEqual([`remove ${CWD}/notes.txt`, 'remove /abs/b.txt'])
    expect(changes('rm -f -- -odd.txt')).toEqual([`remove ${CWD}/-odd.txt`])
    expect(changes('unlink x.txt; rmdir old')).toEqual([`remove ${CWD}/x.txt`, `remove ${CWD}/old`])
  })
  test('rm -r removes a folder and everything under it, in any spelling', () => {
    for (const flag of ['-r', '-R', '-rf', '-fR', '--recursive']) expect(changes(`rm ${flag} src/`)).toEqual([`remove ${CWD}/src tree`])
    expect(changes('cd sub; rm -rf ..')).toEqual([`remove ${CWD} tree`])
  })
  test('mv takes its sources away whole, beside the destination it writes', () => {
    expect(read('mv src /elsewhere/')).toEqual({
      files: [{ word: '/elsewhere/src', path: '/elsewhere/src', sources: [`${CWD}/src`] }],
      changes: [{ word: 'src', path: `${CWD}/src`, does: 'remove', tree: true, to: { word: '/elsewhere', path: '/elsewhere', into: true } }],
      unnamed: [],
    })
  })
  // #3478: a source no path names (a pattern, a variable) is left out of the write's `sources`, so a
  // reader could not tell `mv notes/{a,b}.md archive/` from a deletion, and asked about it as one.
  // The removal itself says where its own mv puts it.
  test('a removal a mv makes says where that mv puts it, a pattern and a variable included (#3478)', () => {
    const to = (command: string) => read(command).changes.filter(c => c.does === 'remove').map(c => [c.word, c.to?.word ?? null, c.to?.path ?? null, c.to?.into ?? false])
    // Into a folder: a trailing slash, several sources, or -t.
    expect(to('mv a.md archive/')).toEqual([['a.md', 'archive', `${CWD}/archive`, true]])
    expect(to('mv {a,b}.md archive/')).toEqual([['{a,b}.md', 'archive', `${CWD}/archive`, true]])
    expect(to('mv *.md x.md archive')).toEqual([['*.md', 'archive', `${CWD}/archive`, true], ['x.md', 'archive', `${CWD}/archive`, true]])
    expect(to('mv -t archive {a,b}.md')).toEqual([['{a,b}.md', 'archive', `${CWD}/archive`, true]])
    expect(to('cd notes && mv *.md ../archive/')).toEqual([['*.md', '../archive', `${CWD}/archive`, true]])
    expect(to('mv "$F" ~/old/')).toEqual([['$F', '~/old', `${HOME}/old`, true]])
    // One source onto one name: inside it when it is an existing folder, as only the disk can say.
    expect(to('mv a.md archive')).toEqual([['a.md', 'archive', `${CWD}/archive`, false]])
    expect(to('mv {a,b}.md archive')).toEqual([['{a,b}.md', 'archive', `${CWD}/archive`, false]])
    // A folder the words cannot name is given as written.
    expect(to('mv *.md "$D/"')).toEqual([['*.md', '$D', null, true]])
  })
  test('a removal says where it goes only while every removal of it in the command is a move to that one place (#3478)', () => {
    const to = (command: string) => read(command).changes.filter(c => c.does === 'remove').map(c => [c.word, c.to?.word ?? null])
    for (const command of ['rm {a,b}.md', 'rm -r old', 'find . -name "*.md" -delete', 'gzip a.md']) expect([command, to(command).map(c => c[1])]).toEqual([command, [null]])
    // A copy another command then removes is no mv: the write's own `sources` say it where a path names it.
    expect(to('cp {a,b}.md archive/ && rm {a,b}.md')).toEqual([['{a,b}.md', null]])
    expect(to('cp other/*.md backup/ && rm *.md')).toEqual([['*.md', null]])
    // Removed outright as well, before the move or after it: what is left to move cannot be told.
    expect(to('rm {a,b}.md; mv {a,b}.md archive/')).toEqual([['{a,b}.md', null]])
    expect(to('mv {a,b}.md archive/; rm {a,b}.md')).toEqual([['{a,b}.md', null]])
    // Moved to two places is no one place; the same place twice is.
    expect(to('mv {a,b}.md one/; mv {a,b}.md two/')).toEqual([['{a,b}.md', null]])
    expect(to('mv {a,b}.md one/; mv {a,b}.md one')).toEqual([['{a,b}.md', null]])
    expect(to('mv {a,b}.md one/; mv {a,b}.md one/')).toEqual([['{a,b}.md', 'one']])
    // A substitution's removal of the same thing is a removal too.
    expect(to('mv {a,b}.md archive/; echo "$(rm {a,b}.md)"')).toEqual([['{a,b}.md', null]])
  })
  // The fix round of #3478: `to` is a claim that the file is at that place once the command has run,
  // so it holds only where the command, read whole, leaves it there. Measured at 3c7b756211, before
  // this: every form below but the controls still said where the mv put it, and ask before saving
  // then told Dan the notes "can be moved back" while the same command deleted them.
  const kept = (command: string) => read(command).changes.filter(c => c.does === 'remove' && c.to !== undefined).map(c => c.word)
  const MOVED = 'mv notes/{a,b}.md ~/archive/'
  test('a removal says where its mv puts it while nothing else in the command can take it from there (#3478)', () => {
    // The controls: the move alone, and beside commands that leave what it moved where it is.
    for (const command of [
      MOVED,
      `mkdir -p ~/archive && ${MOVED}`,
      `${MOVED} && ls ~/archive && echo done`,
      `cp notes/MEMORY.md notes/MEMORY.md.bak && ${MOVED}`,
      `${MOVED} && touch ~/archive/a.md && chmod 600 ~/archive/a.md`,
      `${MOVED} && rm ~/other/x.md && echo x > ~/other/y.md`,
      `D=~/archive; mv notes/{a,b}.md "$D"/ && rm -rf ~/elsewhere`,
    ])
      expect([command, kept(command)]).toEqual([command, ['notes/{a,b}.md']])
  })
  test('a removal does not say where its mv puts it once the command takes away, empties or writes over that place (#3478)', () => {
    for (const command of [
      // The folder itself, however it is spelled, a folder above it, and what is in it.
      `${MOVED} && rm -rf ~/archive`,
      `${MOVED} && rm -rf ~/./archive`,
      `${MOVED} && rm -rf ~//archive/`,
      `${MOVED} && rm -rf $HOME/archive`,
      `${MOVED} && rm -rf \${HOME}/x/../archive`,
      `${MOVED} && rm -rf ${HOME}/archive`,
      `${MOVED} && rm -rf ~`,
      `${MOVED} & rm -rf ~/archive`,
      `rm -rf ~/archive; ${MOVED}`,
      `${MOVED}; rm ~/archive/*.md`,
      `${MOVED} && rm -rf ~/arch*`,
      `${MOVED} && cd ~/archive && rm *.md`,
      `${MOVED} && shred -u ~/archive/*`,
      `${MOVED} && find ~/archive -delete`,
      `${MOVED} && find ~/archive -name '*.md' -exec rm {} +`,
      `${MOVED} && truncate -s0 ~/archive/a.md`,
      `${MOVED} && echo x > ~/archive/a.md`,
      `${MOVED} && : > ~/archive/a.md`,
      `${MOVED} && cp /dev/null ~/archive/a.md`,
      `${MOVED} && sed -i '' 's/a/b/' ~/archive/a.md`,
      `${MOVED} && rsync -a --delete empty/ ~/archive/`,
      // The folder moved on, and removed from where it went.
      `${MOVED} && mv ~/archive /tmp/x && rm -rf /tmp/x`,
      'D=~/archive; mv notes/{a,b}.md "$D"/ && rm -rf "$D"',
    ])
      expect([command, kept(command)]).toEqual([command, []])
    // A moved file moved again is no longer where the first mv put it; the second mv's own word holds.
    expect(kept(`${MOVED} && mv ~/archive/a.md ~/archive/c.md`)).toEqual(['~/archive/a.md'])
  })
  test('a removal does not say where its mv puts it when the same files are removed or emptied under another spelling (#3478)', () => {
    for (const command of [
      'mv ~/notes/*.md ~/nowhere/ ; rm $HOME/notes/*.md',
      `mv ~/notes/*.md ~/nowhere/ ; rm ${HOME}/notes/*.md`,
      'mv ~/notes/*.md ~/nowhere/ ; rm ~/notes/./*.md',
      'mv ~/notes/*.md ~/nowhere/ ; rm ~/notes/[ab].md',
      'mv ~/notes/*.md ~/nowhere/ ; rm ~/notes/a.md',
      'mv ~/notes/*.md ~/nowhere/ ; rm -rf ~/notes',
      'mv ~/notes/*.md ~/nowhere/ ; truncate -s0 ~/notes/a.md',
      `cd ~/notes && mv *.md ~/archive/ && rm ${HOME}/notes/*.md`,
      'mv notes/a.md ~/archive/ && truncate -s0 ./notes/a.md',
      'mv notes/a.md ~/archive/; rm notes/*.md',
    ])
      expect([command, kept(command)]).toEqual([command, []])
    // Shown to differ: another folder, or another file named outright beside one named outright.
    expect(kept('mv notes/a.md ~/archive/ && rm notes/b.md')).toEqual(['notes/a.md'])
    expect(kept('mv ~/notes/*.md ~/archive/ ; rm ~/other/*.md')).toEqual(['~/notes/*.md'])
  })
  test('a removal does not say where its mv puts it wherever the rest of the command cannot be read for sure (#3478)', () => {
    for (const command of [
      // A variable or a substitution names what a later command removes or writes.
      `${MOVED} && rm -rf "$X"`,
      `${MOVED} && rm -rf $(cat list.txt)`,
      `${MOVED} && echo x > "$OUT"`,
      // A loop, a function, text handed to a shell or to eval.
      `${MOVED} && for f in ~/archive/*.md; do rm "$f"; done`,
      `f() { rm -rf ~/archive; }; ${MOVED} && f`,
      `${MOVED} && sh -c 'rm -rf "$1"' _ ~/archive`,
      `${MOVED} && eval "rm -rf ~/archive"`,
      // A program the reader does not know handed anything, a script, a program run inline, git.
      `${MOVED} && mytool ~/archive`,
      `${MOVED} && ./tidy.sh`,
      `${MOVED} && bash tidy.sh`,
      `${MOVED} && python3 -c 'import shutil; shutil.rmtree("x")'`,
      `${MOVED} && xargs rm < list`,
      `${MOVED} && ls | xargs mytool`,
      `${MOVED} && git clean -fdx`,
      `${MOVED} && tar xf old.tar`,
      // A folder the words cannot name is no place to compare a later removal against.
      `mv notes/{a,b}.md "$D"/ && rm -rf ~/archive`,
    ])
      expect([command, kept(command)]).toEqual([command, []])
    // A folder the words cannot name is still said as written when nothing else changes a file.
    expect(kept('mv notes/{a,b}.md "$D"/')).toEqual(['notes/{a,b}.md'])
  })
  // The second fix round of #3478. Measured at 22e20b47fe: every form in the next three tests but
  // the controls still said where the mv put the notes, and each deletes them.
  test('/tmp, /var and /etc are /private/tmp, /private/var and /private/etc: one place under two names (#3478)', () => {
    for (const command of [
      'mv notes/{a,b}.md /tmp/zz/ && rm -rf /private/tmp/zz',
      'mv notes/{a,b}.md /private/tmp/zz/ && rm -rf /tmp/zz',
      'mv notes/{a,b}.md /tmp/zz/ && rm /private/tmp/zz/*.md',
      'mv notes/{a,b}.md /tmp/zz/ && echo x > /private/tmp/zz/a.md',
      'mv notes/{a,b}.md /var/tmp/zz/ && rm -rf /private/var/tmp/zz',
      'mv notes/{a,b}.md /private/var/folders/zz/ && rm -rf /var/folders',
      'mv notes/{a,b}.md /etc/zz/ && rm -rf /private/etc/zz',
      'mv notes/{a,b}.md /tmp/ && rm -rf /private/tmp',
      // The source under its other name.
      'mv /tmp/n/*.md ~/archive/ && rm /private/tmp/n/*.md',
    ])
      expect([command, kept(command)]).toEqual([command, []])
    // Shown to differ: another folder under either name, and a name that only starts the same.
    expect(kept('mv notes/{a,b}.md /tmp/zz/ && rm -rf /private/tmp/other')).toEqual(['notes/{a,b}.md'])
    expect(kept('mv notes/{a,b}.md /tmp/zz/ && rm -rf /tmpx /private/tmpzz /private/tmp/zzz')).toEqual(['notes/{a,b}.md'])
  })
  test('a removal does not say where its mv puts it beside a command that makes a link, or one that takes its own sources away unread (#3478)', () => {
    for (const command of [
      // A link the command makes is a second name for a place, or for a file, that no path shows.
      `ln -s ~/archive /tmp/x && ${MOVED} && rm -rf /tmp/x/`,
      `${MOVED} && ln ~/archive/a.md /tmp/h && : > /tmp/h`,
      `${MOVED} && ln -sf ~/archive ~/latest`,
      // rsync told to remove what it sent takes the notes out of where the mv put them.
      `${MOVED} && rsync -a --remove-source-files ~/archive/ /tmp/qq/ && rm -rf /tmp/qq`,
      `${MOVED} && rsync -a --remove-sent-files ~/archive/ /tmp/qq/`,
    ])
      expect([command, kept(command)]).toEqual([command, []])
    // An rsync that only copies leaves them there.
    expect(kept(`${MOVED} && rsync -a ~/archive/ /tmp/qq/`)).toEqual(['notes/{a,b}.md'])
  })
  // A disk standing in for $.fs: `links` are symbolic links by their own path, and `there` every file
  // and folder that exists, by where it really is. As the engine answers (read from Claude Code
  // 2.1.x's own stat): exists follows links, stat of a link that leads nowhere answers with no
  // realPath, and stat of nothing throws. Every question is counted.
  const disk = (links: Record<string, string>, there: string[], fail: { exists?: string } = {}) => {
    const asked: string[] = []
    const follow = (path: string): string => {
      let p = path
      for (let i = 0; i < 40; i++) {
        const hit = Object.keys(links).find(l => p === l || p.startsWith(`${l}/`))
        if (hit === undefined) return p
        p = `${links[hit]}${p.slice(hit.length)}`
      }
      throw new Error(`ELOOP: ${path}`)
    }
    const is = (p: string) => there.some(t => t === p || t.startsWith(`${p}/`))
    const fs: LinkFs = {
      exists: async path => {
        asked.push(`exists ${path}`)
        if (fail.exists === path) throw new Error(`EPERM: ${path}, exists`)
        return is(follow(path))
      },
      stat: async (path, options) => {
        asked.push(`stat ${path}`)
        const real = follow(path)
        if (!is(real)) {
          if (links[path] !== undefined) return { isLink: true }
          throw new Error(`ENOENT: ${path}`)
        }
        return { isLink: links[path] !== undefined, ...(options?.resolve ? { realPath: real } : {}) }
      },
    }
    return { fs, asked }
  }
  const keptOn = async (d: { fs: LinkFs }, command: string) => (await settleOnDisk(read(command), d.fs)).changes.filter(c => c.does === 'remove' && c.to !== undefined).map(c => c.word)
  const DESK = `${HOME}/Desktop`
  const LINKED = { [`${DESK}/link`]: `${DESK}/archive`, [`${HOME}/n2`]: `${HOME}/notes` }
  const THERE = [`${HOME}/notes/a.md`, `${DESK}/archive/old.md`, `${HOME}/elsewhere/x`, `${CWD}/notes/a.md`]
  test('a folder reached through a link is the folder it leads to, as the disk says (#3478)', async () => {
    for (const command of [
      // Moved through the link, removed by the folder's own name, and the other way round.
      'mv ~/notes/*.md ~/Desktop/link/ && rm -rf ~/Desktop/archive',
      'mv ~/notes/*.md ~/Desktop/archive/ && rm ~/Desktop/link/*.md',
      'mv ~/notes/*.md ~/Desktop/archive/ && rm -rf ~/Desktop/link/',
      'mv ~/notes/a.md ~/Desktop/link/ && rm ~/Desktop/archive/a.md',
      'mv ~/notes/a.md ~/Desktop/link && echo x > ~/Desktop/archive/a.md',
      // A folder not made yet, under the link: the part that exists is followed, the rest is the name.
      'mkdir -p ~/Desktop/link/new && mv ~/notes/*.md ~/Desktop/link/new/ && rm -rf ~/Desktop/archive/new',
      // The source under its other name.
      'mv ~/n2/*.md ~/elsewhere/ && rm ~/notes/*.md',
      'mv ~/notes/a.md ~/elsewhere/ && truncate -s0 ~/n2/a.md',
    ])
      expect([command, await keptOn(disk(LINKED, THERE), command)]).toEqual([command, []])
    // The controls, on the same disk: places the disk shows to differ, through a link or not.
    expect(await keptOn(disk(LINKED, THERE), 'mv ~/notes/*.md ~/Desktop/link/ && rm -rf ~/elsewhere')).toEqual(['~/notes/*.md'])
    expect(await keptOn(disk(LINKED, THERE), 'mv ~/n2/*.md ~/Desktop/archive/ && rm -rf ~/Desktop/other')).toEqual(['~/n2/*.md'])
    expect(await keptOn(disk(LINKED, THERE), `mkdir -p ~/Desktop/new && ${MOVED} && ls ~/archive`)).toEqual(['notes/{a,b}.md'])
    // On a disk with no link at all, every control of the reading by words alone still holds.
    expect(await keptOn(disk({}, THERE), `${MOVED} && rm ~/other/x.md && echo x > ~/other/y.md`)).toEqual(['notes/{a,b}.md'])
    // Home itself behind a link: both spellings lead to one place, and the rest still differs.
    const moved = { [HOME]: '/Volumes/x/dan' }
    const onVolume = ['/Volumes/x/dan/notes/a.md', '/Volumes/x/dan/archive/old.md']
    expect(await keptOn(disk(moved, onVolume), 'mv ~/notes/*.md ~/archive/ && rm -rf ~/elsewhere')).toEqual(['~/notes/*.md'])
    expect(await keptOn(disk(moved, onVolume), 'mv ~/notes/*.md ~/archive/ && rm -rf /Volumes/x/dan/archive')).toEqual([])
    // The two names macOS always has hold on a disk that has neither folder yet.
    expect(await keptOn(disk({}, THERE), 'mv ~/notes/*.md /tmp/zz/ && rm -rf /private/tmp/zz')).toEqual([])
  })
  test('where the disk cannot say where a place leads, nothing is said of the move beside another change (#3478)', async () => {
    // A link that leads nowhere yet: the command may make what it points at.
    const dangling = { [`${DESK}/link`]: `${DESK}/later` }
    expect(await keptOn(disk(dangling, THERE), 'mkdir ~/Desktop/later && mv ~/notes/*.md ~/Desktop/link/ && rm -rf ~/Desktop/later')).toEqual([])
    // A disk that fails the question, which is never thrown on to the caller.
    expect(await keptOn(disk({}, THERE, { exists: `${HOME}/notes` }), 'mv ~/notes/*.md ~/archive/ && rm -rf ~/elsewhere')).toEqual([])
    // With nothing else changing a file there is nothing to compare, and the move stands as read.
    expect(await keptOn(disk(dangling, THERE), 'mv ~/notes/*.md ~/Desktop/link/')).toEqual(['~/notes/*.md'])
  })
  test('the disk is asked only for a command with a move left to settle, each place once, and never past the bound (#3478)', async () => {
    // No move, or a move already unsaid by its words: no question at all.
    for (const command of ['rm -rf ~/Desktop/archive', 'echo x > ~/notes/a.md', `${MOVED} && rm -rf ~/archive`]) {
      const d = disk(LINKED, THERE)
      await keptOn(d, command)
      expect([command, d.asked]).toEqual([command, []])
    }
    // Places that share their folders ask about each folder once.
    const d = disk(LINKED, THERE)
    expect(await keptOn(d, 'mv ~/notes/*.md ~/Desktop/link/new/ && rm ~/elsewhere/a ~/elsewhere/b ~/elsewhere/c')).toEqual(['~/notes/*.md'])
    expect(d.asked.length).toBe(new Set(d.asked).size)
    expect(d.asked.length).toBeLessThan(20)
    // Past the bound on places nothing is asked, and nothing is said of the move.
    const many = Array.from({ length: SETTLE_PLACES + 1 }, (_, i) => `~/elsewhere/f${i}`).join(' ')
    const big = disk(LINKED, THERE)
    expect(await keptOn(big, `mv ~/notes/*.md ~/Desktop/archive/ && rm ${many}`)).toEqual([])
    expect(big.asked).toEqual([])
  })
  test('a mv says where it puts its sources only where no two of them can land on one name, and never for a device (#3478)', () => {
    // One folder holds no two files of a name; two folders may.
    expect(kept('mv notes/a.md notes/b.md ~/archive/')).toEqual(['notes/a.md', 'notes/b.md'])
    expect(kept('mv notes/*.md notes/x.txt ~/archive/')).toEqual(['notes/*.md', 'notes/x.txt'])
    expect(kept('mv one/a.md two/b.md ~/archive/')).toEqual(['one/a.md', 'two/b.md'])
    expect(kept('mv one/x.md two/x.md ~/archive/')).toEqual([])
    expect(kept('mv one/*.md two/*.md ~/archive/')).toEqual([])
    expect(kept('mv one/*.md two/x.md ~/archive/')).toEqual([])
    expect(kept('mv "$A" notes/b.md ~/archive/')).toEqual([])
    // mv cannot put a file on a device (measured on macOS: "Operation not permitted", the file kept).
    expect(kept('mv notes/a.md /dev/null')).toEqual([])
    expect(kept('mv notes/*.md /dev/null')).toEqual([])
  })
  // mv -n replaces nothing: a source whose name is taken where it goes is left where it was. At
  // 3c7b756211 the reader gave no word of it, and ask before saving said the file there was replaced.
  test('a mv told to replace nothing says so of where it puts each source (#3478)', () => {
    const keeps = (command: string) => read(command).changes.filter(c => c.does === 'remove').map(c => c.to?.keeps ?? false)
    for (const flag of ['-n', '-vn', '-nv', '--no-clobber']) expect([flag, keeps(`mv ${flag} notes/*.md ~/archive/`)]).toEqual([flag, [true]])
    for (const flag of ['', '-v', '-f', '--no-target-directory']) expect([flag, keeps(`mv ${flag} notes/*.md ~/archive`)]).toEqual([flag, [false]])
    // Of -n, -f and -i the last one given wins, so beside either of the others, in any order, it is
    // not said: `mv -n -f` replaces the file (found by the lessons review of the push that added this).
    for (const flag of ['-n -f', '-nf', '-fn', '-f -n', '--no-clobber --force', '-n -i', '-in', '--interactive -n']) expect([flag, keeps(`mv ${flag} notes/*.md ~/archive/`)]).toEqual([flag, [false]])
    // With it and without it are two ways of moving one thing, so neither is said.
    expect(kept('mv -n notes/*.md ~/archive/; mv notes/*.md ~/archive/')).toEqual([])
  })
  test('a path written and then removed is reported both ways, so a reader can keep the removal', () => {
    expect(paths('echo x > d; rm -r d')).toEqual([`${CWD}/d`])
    expect(changes('echo x > d; rm -r d')).toEqual([`remove ${CWD}/d tree`])
  })
  test('a removal of a glob or a variable is given as written, never guessed at', () => {
    expect(changes('rm *.txt; rm -rf $DIR')).toEqual(['remove (as written) *.txt', 'remove (as written) $DIR tree'])
  })
  test('touch stamps, truncate and shred empty, mkdir makes a folder, chmod, chown and chgrp change a mode', () => {
    expect(changes('touch -t 202601010000 new.md other.md')).toEqual([`touch ${CWD}/new.md`, `touch ${CWD}/other.md`])
    expect(changes('truncate -s 0 log.txt; shred -u secret.txt')).toEqual([`truncate ${CWD}/log.txt`, `truncate ${CWD}/secret.txt`, `remove ${CWD}/secret.txt`])
    expect(changes('mkdir -p a/b; mkdir -m 755 d')).toEqual([`folder ${CWD}/a/b`, `folder ${CWD}/d`])
    expect(changes('chmod +x run.sh; chmod -R 755 dir; chown dan:staff a b; chgrp -R staff g; chmod --reference=ref.txt c')).toEqual([
      `mode ${CWD}/run.sh`,
      `mode ${CWD}/dir tree`,
      `mode ${CWD}/a`,
      `mode ${CWD}/b`,
      `mode ${CWD}/g tree`,
      `mode ${CWD}/c`,
    ])
  })
  // The names a find -delete is limited to: a guard read `find tools tests -name "lr_history*.pyc"
  // -delete` as taking away every file under both folders, a page among them (seen 2026-11-13). Given
  // only where every test before -delete narrows the same entries (-name and -iname, -type, -mtime and
  // the like, joined by -a or nothing); an -o, a !, a bracket, -path, -regex or anything else leaves
  // it unlimited, and so does a name a variable or a command's output fills in.
  test('find -delete carries the -name and -iname patterns it is limited to, only where nothing else can widen it', () => {
    const only = (command: string) => read(command).changes.map(c => c.names)
    expect(only(`find tools tests -name "lr_history*.pyc" -delete`)).toEqual([['lr_history*.pyc'], ['lr_history*.pyc']])
    expect(only(`find . -type f -iname '*.PYC' -mtime +3 -a -name 'x*' -delete`)).toEqual([['*.PYC', 'x*']])
    for (const command of [
      `find build -delete`,
      `find build -type f -delete`,
      `find app -name x -o -name '*.pyc' -delete`,
      `find app ! -name '*.pyc' -delete`,
      `find app -not -name '*.pyc' -delete`,
      `find app \\( -name '*.pyc' \\) -delete`,
      `find app -path '*/cache/*' -name '*.pyc' -delete`,
      `find app -regex '.*pyc' -delete`,
      `find app -name "$P" -delete`,
      `find app -name "$(cat p)" -delete`,
      `find app -name '*.pyc' -delete -name x -delete`,
    ])
      expect([command, only(command)]).toEqual([command, [undefined]])
  })
  test('find -delete removes what it finds under each folder it starts from, and -fprint writes a file', () => {
    expect(changes(`find build -name '*.o' -delete`)).toEqual([`remove ${CWD}/build tree`])
    expect(changes('find -delete')).toEqual([`remove ${CWD} tree`])
    expect(paths('find src -fprint list.txt')).toEqual([`${CWD}/list.txt`])
    // What -exec runs is read as a command of its own, the folder standing for {}, and since {}
    // stands for everything under that folder, what it changes reaches the tree (#760: it was read
    // as removing src alone, so a guard compared it against files at src exactly).
    expect(changes(`find src -name '*.bak' -exec rm {} \\;`)).toEqual([`remove ${CWD}/src tree`])
    expect(changes(`find src -exec chmod 644 {} +`)).toEqual([`mode ${CWD}/src tree`])
    expect(changes('rm src/a.bak')).toEqual([`remove ${CWD}/src/a.bak`])
    // Only the operand {} stood for reaches the tree; one the command names itself is that path
    // alone (lessons review of #798).
    expect(changes('find src -exec rm other.txt \\;')).toEqual([`remove ${CWD}/other.txt`])
    expect(changes('find . -name x -exec mkdir out \\;')).toEqual([`folder ${CWD}/out`])
    expect(changes('find a b -exec rm {} \\;')).toEqual([`remove ${CWD}/a tree`, `remove ${CWD}/b tree`])
    // A file written where {} stood is every file under that folder too (lessons review of #798).
    expect(read('find src -exec sed -i s/a/b/ {} \\;').files).toEqual([{ word: 'src', path: `${CWD}/src`, edits: true, tree: true }])
    expect(read('find src -exec cp x.txt {} \\;').files).toEqual([{ word: 'src', path: `${CWD}/src`, sources: [`${CWD}/x.txt`], mayBeFolder: true, tree: true }])
    expect(read('find src -exec sed -i s/a/b/ notes.md \\;').files).toEqual([{ word: 'notes.md', path: `${CWD}/notes.md`, edits: true }])
    // A path written plainly and then where {} stood keeps the tree, as a change does.
    expect(read('echo x > src; find src -exec sed -i s/a/b/ {} \\;').files).toEqual([{ word: 'src', path: `${CWD}/src`, tree: true }])
  })
  test('a file edited in place is marked as edited, beside files written whole', () => {
    expect(read(`sed -i 's/a/b/' a.md; echo x > b.md`).files).toEqual([
      { word: 'a.md', path: `${CWD}/a.md`, edits: true },
      { word: 'b.md', path: `${CWD}/b.md` },
    ])
  })
})

// The collision guard's own reader's cases (its tests/collide.test.ts until #712), each still read.
describe("writes: the collision guard's cases, carried over (#712)", () => {
  test('every output redirect, and a file named twice once', () => {
    expect(paths('echo a > a.txt; make 2> err.log; ls &> all.log; ls &>> more.log; echo >| c.txt; echo b >> a.txt')).toEqual(
      ['a.txt', 'err.log', 'all.log', 'more.log', 'c.txt'].map(f => `${CWD}/${f}`),
    )
  })
  test('sed and perl in every in place spelling', () => {
    expect(paths(`sed -i.bak -e 's/a/b/' -e 's/c/d/' x.txt; sed --in-place 's/a/b/' z.txt; perl -i.bak -pe 's/a/b/' w.txt`)).toEqual([`${CWD}/x.txt`, `${CWD}/z.txt`, `${CWD}/w.txt`])
  })
  test('nested subshells each end their own cd', () => {
    expect(paths('(cd a; (cd b); echo > x); echo > y')).toEqual([`${CWD}/a/x`, `${CWD}/y`])
  })
  test('a read only command writes nothing', () => {
    const w = read(`cat notes.txt | grep x; sed -n '1,5p' notes.txt; ls -la; git diff; perl -ne 'print' notes.txt; wc < notes.txt; perl -Ilib script.pl x.txt`)
    expect({ files: w.files, changes: w.changes, unnamed: w.unnamed }).toEqual({ files: [], changes: [], unnamed: [] })
    // #1586: the script file it runs is given apart, with what it is handed, which no guard judging
    // files, changes or unnamed writes reads.
    expect(w.runs?.map(r => [r.script, r.args.map(a => a.word)])).toEqual([['script.pl', ['x.txt']]])
  })
})

describe('writes: where the old copies disagreed (#712)', () => {
  // The collision guard read `>& file` as a write; this reader stepped over it as a descriptor copy.
  test('>& with a file after it writes the file; with a number or - it copies a descriptor', () => {
    expect(paths('make >& build.log')).toEqual([`${CWD}/build.log`])
    expect(paths('make >&build.log')).toEqual([`${CWD}/build.log`])
    expect(paths('echo x >&2; make 2>& 1; ls >&-')).toEqual([])
  })
  // No build knew wget --spider downloads nothing; this reader named the file it would have saved.
  test('wget --spider only checks the address, and saves nothing', () => {
    expect(paths('wget --spider https://example.com/CLAUDE.md')).toEqual([])
    expect(paths('wget --spider -o check.log https://example.com/a')).toEqual([`${CWD}/check.log`])
  })
  // A download whose files the words cannot name says where it lands when the words do.
  test('a download the words cannot name says the folder it lands in, when they name one', () => {
    expect(read('curl -J -O --output-dir /tmp/x https://x.com/get').unnamed.map(u => u.into)).toEqual(['/tmp/x'])
    expect(read('wget -r -P /tmp/y https://x.com/docs/').unnamed.map(u => u.into)).toEqual(['/tmp/y'])
    expect(read('wget -r https://x.com/docs/').unnamed.map(u => u.into)).toEqual([undefined])
  })
  test("a case clause's commands are read like any other, and its pattern's ) is no subshell", () => {
    expect(paths('case $x in a) echo y > f;; esac; echo z > g')).toEqual([`${CWD}/f`, `${CWD}/g`])
    expect(paths('(cd sub; case $x in a) echo y > f;; esac); echo z > g')).toEqual([`${CWD}/sub/f`, `${CWD}/g`])
  })
})

describe('writes: what a program can do, judged by mod-kit\'s per language judge (#712)', () => {
  // INLINE_WRITE, a list of write idioms, and an exact list of interpreter names, gave way to the
  // judge no build built (code.ts): what writes, runs a process or cannot be read is a write the
  // words do not name, for every interpreter however it is versioned.
  test('inline code that writes, runs a process, or builds code at run time is a write the words do not name', () => {
    expect(read(`python3.12 -c "open('a','w').write('x')"`).unnamed.map(u => u.what)).toEqual(['an inline python3.12 script'])
    expect(read(`python3 -c "import subprocess; subprocess.run(['ls'])"`).unnamed.map(u => u.what)).toEqual(['an inline python3 script'])
    expect(read(`python3 -c "eval(input())"`).unnamed.map(u => u.what)).toEqual(['an inline python3 script'])
    expect(read(`awk '{ print > "out.txt" }' in.txt`).unnamed.map(u => u.what)).toEqual(['an inline awk script'])
    // #712 from #726: open of a path that is itself a call, json.dump to an opened file.
    expect(read(`python3 -c "open(os.path.expanduser('~/.claude/CLAUDE.md'), 'a').write('x')"`).unnamed.map(u => u.what)).toEqual(['an inline python3 script'])
    expect(read(`python3 -c "import json; json.dump({}, open('CLAUDE.md', 'w'))"`).unnamed.map(u => u.what)).toEqual(['an inline python3 script'])
    expect(read(`ruby -e 'File.open("CLAUDE.md", "w") { |f| f.puts 1 }'`).unnamed.map(u => u.what)).toEqual(['an inline ruby script'])
    expect(read(`ruby -e 'IO.write("CLAUDE.md", "x")'`).unnamed.map(u => u.what)).toEqual(['an inline ruby script'])
  })
  test('inline code that only reads writes nothing', () => {
    expect(read(`python3 -c "print(open('CLAUDE.md').read())"`).unnamed).toEqual([])
    expect(read(`node -e "console.log(require('fs').readFileSync('a','utf8'))"`).unnamed).toEqual([])
    expect(read(`awk '{print $1}' in.txt`).unnamed).toEqual([])
  })
  // #2727: an awk program printing a string that holds a > or a | (`print "88 -> " h`) was read as
  // printing to a file or a pipe, so a command only reading a component file was held as writing it.
  // What a string holds is text; a redirect or a pipe after the string still is one.
  test('a > or a | inside an awk string is text, never a redirect or a pipe', () => {
    for (const program of [
      `NR<=130 { if ($0 ~ /^(export )?(function|const) /) h=NR": "$0 } NR==88 { print "88 -> " h }`,
      `{ print "a | b", $1 }`,
      `{ printf "%s >> %s\\n", $1, "x \\" > y" }`,
      // A quote in a regex literal is the regex's, and the string after it is still a string.
      `/"/ { print "a -> b" }`,
      `$0 ~ /["]/ { n = n / 2; print "half -> " n }`,
    ])
      expect([program, read(`awk '${program}' app/Panel.tsx`).unnamed]).toEqual([program, []])
    // Lessons review of 68267d7: a quote in a regex literal paired with the next string's opening
    // quote blanked the code between them, a redirect or system() included. A regex, a comment and a
    // / after ++ (a division or a regex, which cannot be told) keep every redirect after them seen.
    for (const program of [
      `{ print "88 -> " h > "out.txt" }`,
      `{ print "x" | "sort" }`,
      `{ print h > out }`,
      `{ print "unclosed > x }`,
      `/"/ { print > "out.txt" }`,
      `$0 ~ /"/ { system("rm x") }`,
      `{ x++ / 2; s = "a/b"; print > "f" }`,
      `# say "hi\n{ print > "f" }`,
      `{ print /"/ > "f" }`,
      // Lessons review at a08a0f6: a newline ends a statement, so a regex starting the next line is
      // one, never a division after the name or number the line before ended in.
      `NR == 2\n/"/ { print > "out.txt"; if ($0 ~ /"/) n++ }`,
      `{ n = 1 } END\n/"/ { system("rm x"); if ($0 ~ /"/) n++ }`,
    ])
      expect([program, read(`awk '${program}' in.txt`).unnamed.map(u => u.what)]).toEqual([program, ['an inline awk script']])
  })
  // #730: a heredoc or here-string feeding a shell's -c feeds the commands it runs.
  test("a heredoc feeding a shell's -c is read as the program of the command there", () => {
    expect(read(`bash -c 'python3' <<'EOF'\nopen('a','w')\nEOF`).unnamed.map(u => u.what)).toEqual(['a python3 script on standard input'])
  })
})

describe('writes: a command xargs runs (#730)', () => {
  // xargs gives the command after it its files from its own input, so no word names them.
  test('a command that writes or changes files, given its files by xargs, is a write the words do not name', () => {
    expect(read('ls | xargs rm').unnamed).toEqual([{ what: 'rm given its files by xargs', words: ['rm'], inputs: [] }])
    expect(read(`find . -name '*.md' | xargs sed -i 's/a/b/'`).unnamed.map(u => u.what)).toEqual(['sed given its files by xargs'])
    expect(read('find . -print0 | xargs -0 -I {} cp {} /tmp/out/').unnamed.map(u => u.what)).toEqual(['cp given its files by xargs'])
    expect(read(`ls | xargs sh -c 'rm "$@"' _`).unnamed.map(u => u.what)).toEqual(['rm given its files by xargs'])
  })
  test('one that only reads is nothing', () => {
    expect(read('ls | xargs cat').unnamed).toEqual([])
    expect(read(`ls | xargs sed -n '1p'`).unnamed).toEqual([])
  })
})

// #743: `F=<memory folder>/MEMORY.md; printf ... >> "$F"` wrote to MEMORY.md unasked, because this
// reader gave the target as written ($F) with no path. A variable the same command set is read as
// its value, as the shell reads it, and the word is still given as written.
describe('writes: a path held in a variable', () => {
  test('a variable set earlier in the command names its file, by an assignment or by export', () => {
    expect(read(`F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`).files).toEqual([{ word: '$F', path: `${HOME}/.claude/projects/p/memory/MEMORY.md` }])
    expect(paths(`export F=~/.claude/projects/p/memory/MEMORY.md; printf 'x\\n' >> "$F"`)).toEqual([`${HOME}/.claude/projects/p/memory/MEMORY.md`])
    expect(paths('declare -x F=/opt/rules.md && cp a.md "$F"')).toEqual(['/opt/rules.md'])
  })
  test('a value built from home or from another variable the command set is followed', () => {
    expect(paths('P="$HOME/.claude/projects/p" && cat x > "${P}/memory/note.md"')).toEqual([`${HOME}/.claude/projects/p/memory/note.md`])
    expect(paths('D=~/.claude; F=$D/CLAUDE.md; tee -a "$F" < rules.md')).toEqual([`${HOME}/.claude/CLAUDE.md`])
  })
  test('a relative value is resolved where it is used, after any cd, and a cd into a held folder is followed', () => {
    expect(paths('F=CLAUDE.md; cd sub && echo x >> "$F"')).toEqual([`${CWD}/sub/CLAUDE.md`])
    expect(paths('D=~/.claude/projects/p/memory; cd "$D" && echo x > note.md')).toEqual([`${HOME}/.claude/projects/p/memory/note.md`])
  })
  // #1953: a for loop over plain words names each of them, as many writes.
  test('a for loop over plain words names a write of each', () => {
    expect(paths('for F in a.md b.md; do echo x >> "$F"; done')).toEqual([`${CWD}/a.md`, `${CWD}/b.md`])
  })
  test('a variable the reader cannot be sure of is given as written', () => {
    // Set from a command's output, by a loop, by read, by eval, or unset.
    expect(paths('F=$(mktemp); echo x > "$F"')).toEqual(['(as written) $F'])
    expect(paths('for F in *.md; do echo x >> "$F"; done')).toEqual(['(as written) $F'])
    expect(paths('F=a.md; while read -r F; do echo x >> "$F"; done < list')).toEqual(['(as written) $F'])
    expect(paths(`F=a.md; eval "F=b.md"; echo x > "$F"`)).toEqual(['(as written) $F'])
    expect(paths('F=a.md; unset F; echo x > "$F"')).toEqual(['(as written) $F'])
    expect(paths('F=a.md; F+=x; echo x > "$F"')).toEqual(['(as written) $F'])
    for (const setter of ['select F in a b; do break; done', 'mapfile -t F < list', 'getopts ab F', `printf -v F '%s' b.md`, 'source env.sh', '. ./env.sh', 'declare -n F=G'])
      expect(`${setter}: ${paths(`F=a.md; ${setter}; echo x > "$F"`)}`).toBe(`${setter}: (as written) $F`)
    // Given two values: the reader cannot tell a ; from an && or ||, so which one stands is unknown.
    expect(paths('F=a.md; [ -n "$X" ] && F=b.md; echo x > "$F"')).toEqual(['(as written) $F'])
    // Set only for the one command it leads, or only inside quotes: no variable the shell keeps.
    expect(paths('F=~/.claude/CLAUDE.md true; echo x > "$F"')).toEqual(['(as written) $F'])
    expect(paths('echo "F=~/.claude/CLAUDE.md"; echo x > "$F"')).toEqual(['(as written) $F'])
    // Never set at all, or a command's output, given whole as written.
    expect(read(`printf 'x\\n' >> "$OUT"`).files).toEqual([{ word: '$OUT' }])
    expect(read(`printf 'x\\n' >> "$(ls ~/.claude/projects/p/memory/MEMORY.md)"`).files).toEqual([{ word: '$(ls ~/.claude/projects/p/memory/MEMORY.md)' }])
  })
  // #752: a copy into a folder held in a variable composed its word from the folder's value, so the
  // $ that tells a reader the path came through a variable was lost.
  test('a copy into a folder held in a variable keeps the variable in its word', () => {
    expect(read('D=~/.claude/projects/p/memory; cp note.md "$D/"').files).toEqual([
      { word: '$D/note.md', path: `${HOME}/.claude/projects/p/memory/note.md`, sources: [`${CWD}/note.md`] },
    ])
    expect(read('D=~/.claude/projects/p/memory; cp -t "$D" a.md b.md').files.map(f => f.word)).toEqual(['$D/a.md', '$D/b.md'])
    // A folder no variable reached is spelled as written, as before.
    expect(read('cp note.md ~/.claude/projects/p/memory/').files.map(f => f.word)).toEqual(['~/.claude/projects/p/memory/note.md'])
  })
  // #752: "as written" was matched by string, so a literal word equal to a variable's value in the
  // same command was given as the variable. A redirect's target is now read by its own place.
  test('a redirect target written literally is given as written, even when a variable holds the same path', () => {
    expect(read('F=/opt/x.md; cat "$F" > /opt/x.md').files).toEqual([{ word: '/opt/x.md', path: '/opt/x.md' }])
    expect(read('F=/opt/x.md; cat /opt/x.md >> "$F"').files).toEqual([{ word: '$F', path: '/opt/x.md' }])
    // An operand is still matched by string, and where it is ambiguous it is given as the variable,
    // the side that makes a reader ask rather than pass (the same path either way).
    expect(read('F=/opt/x.md; cp "$F" /opt/x.md').files.map(f => f.word)).toEqual(['$F'])
  })
  test('a write its words do not name carries the command as written', () => {
    expect(read('P=fix.patch; git apply "$P"').unnamed.map(u => u.words)).toEqual([['git', 'apply', '$P']])
  })
  test('a value set inside a subshell ends with it', () => {
    expect(paths('F=a.md; (G=b.md; echo x > "$G"); echo y > "$F"; echo z > "$G"')).toEqual([`${CWD}/b.md`, `${CWD}/a.md`, '(as written) $G'])
  })
})

// #830: ask before saving asked about a python heredoc editing a test file, because the only thing it
// could judge was every lasting memory path the script's text quoted. A program whose every write is
// an open or a pathlib write of a file its text names gives those files as `targets`, absolute; one
// whose writes cannot all be named gives none, and a reader judges it by what its text mentions.
describe('writes: the files an inline python program names as its writes (#830)', () => {
  const targets = (command: string, cwd = CWD) => read(command, cwd).unnamed.map(u => u.targets)
  test('an open for writing, or a pathlib write, of a literal path or a name bound once to one names that file', () => {
    expect(targets("python3 - <<'EOF'\np='tests/a.test.ts'\ns=open(p).read()\nopen(p,'w').write(s.replace('x', '~/.claude/CLAUDE.md'))\nEOF")).toEqual([[`${CWD}/tests/a.test.ts`]])
    expect(targets(`python3 -c "open('/tmp/out.txt', 'a').write('x')"`)).toEqual([['/tmp/out.txt']])
    expect(targets("python3 - <<'EOF'\nfrom pathlib import Path\nPath('notes/a.md').write_text('x')\nq = Path('b.md')\nq.write_bytes(b'y')\nwith open('c.md', mode='w') as f:\n  f.write('z')\nEOF")).toEqual([
      [`${CWD}/notes/a.md`, `${CWD}/b.md`, `${CWD}/c.md`],
    ])
    // Plain top level imports of modules with no file writers of their own keep them named, os's
    // path among them when it is all that is taken from os.
    expect(targets("python3 - <<'EOF'\nimport json, re\nfrom os import path\nfrom os.path import exists as there  # a comment\nfrom pathlib import Path\nif path.exists('a.json') and there('b'):\n  json.dump(re.sub('a', 'b', 'x'), open('a.json','w'))\nEOF")).toEqual([[`${CWD}/a.json`]])
    // A string's replace, with two arguments, on a name not taken from Path, is no move.
    expect(targets("python3 - <<'EOF'\nfrom pathlib import Path\nq = Path('b.md')\ns = open('a.md').read()\nq.write_text(s.replace('x', 'y'))\nEOF")).toEqual([[`${CWD}/b.md`]])
    // A cd before it moves where a relative path lands.
    expect(targets(`cd sub && python3 -c "open('a.md','w')"`)).toEqual([[`${CWD}/sub/a.md`]])
  })
  // #2924: a program tidying a test file replaced one block of the test's code with another, and a
  // block it only held as text (`open(os.path.join(self.out, "img", name), "w")`) was read as the
  // program's own open of a path it could not name, so its files went unnamed and a guard read every
  // name its text quoted (`page.html`) as one it writes. A call inside a string or a comment is text.
  test("a write call a string or a comment only holds is text, and the program's own writes are still named", () => {
    const tidy = [
      "p = 'tests/test_gallery.py'",
      's = open(p).read()',
      `s = s.replace('''        page = open(os.path.join(self.out, "page.html")).read()\n''', '''        with open(os.path.join(self.out, "page.html")) as fh:\n            page = fh.read()\n''')`,
      `s = s.replace('''            open(os.path.join(self.out, "img", name), "w").write("old")\n''', '''            x\n''')`,
      '# open(q, "w") would write the other one',
      "open(p, 'w').write(s)",
    ].join('\n')
    expect(targets(`python3 - <<'EOF'\n${tidy}\nEOF`)).toEqual([[`${CWD}/tests/test_gallery.py`]])
    // The same open in the program's own code still leaves its files unnamed, as does a write in an
    // f-string's braces, which are code.
    expect(targets(`python3 - <<'EOF'\n${tidy}\nopen(os.path.join(d, "img", n), "w").write("old")\nEOF`)).toEqual([undefined])
    expect(targets(`python3 - <<'EOF'\n${tidy}\nx = f"{open(os.path.join(d, 'n'), 'w')}"\nEOF`)).toEqual([undefined])
    // A program whose text runs what a string holds is never named, however it quotes the write.
    expect(targets(`python3 - <<'EOF'\n${tidy}\nexec('open(q, "w")')\nEOF`)).toEqual([undefined])
  })
  // #1171: a $ or a backtick anywhere in the text left the files unnamed, even under a quoted
  // delimiter, where the shell expands nothing, so a heredoc editing a TypeScript test (template
  // literals, `${CWD}`) was judged by every name its text quoted. Whether the shell left the text as
  // written is the reader's one answer, the one the code a guard reads is given by (#1165).
  test('a program on standard input from a quoted heredoc names its files whatever $ or backtick its text holds', () => {
    const edit = "p='tests/a.test.ts'\ns=open(p).read()\nnew='''  expect(x(`${CWD}/app/page.tsx`)).toBe($y)\n'''\nopen(p,'w').write(s+new)"
    expect(targets(`python3 - <<'EOF'\n${edit}\nEOF`)).toEqual([[`${CWD}/tests/a.test.ts`]])
    expect(targets(`python3 - <<"EOF"\n${edit}\nEOF`)).toEqual([[`${CWD}/tests/a.test.ts`]])
    expect(targets(`python3 - <<\\EOF\n${edit}\nEOF`)).toEqual([[`${CWD}/tests/a.test.ts`]])
    // Unquoted, the shell may have made the text any code: unnamed, as before.
    expect(targets(`python3 - <<EOF\n${edit}\nEOF`)).toEqual([undefined])
    // A quoted heredoc a later redirect replaces is not what python reads.
    expect(targets(`python3 - <<'EOF' < other.py\n${edit}\nEOF`)).toEqual([undefined])
  })
  // The write reader never marked a command a substitution runs, so a program there was given its
  // files and its code as if the shell had left it alone (#974 says it may not have).
  test('a program a command substitution runs names no files and carries no code', () => {
    const u = read(`echo "$(python3 -c "open('a.md','w').write('''x\ny''')")"`).unnamed
    expect(u.map(x => [x.targets, 'code' in x])).toEqual([[undefined, false]])
    expect(read(`python3 -c "open('a.md','w').write('''x\ny''')"`).unnamed.map(x => x.targets)).toEqual([[`${CWD}/a.md`]])
  })
  test('a program with a write whose file its text cannot name gives no targets', () => {
    const none = [undefined]
    // A name computed at run time, bound twice, bound by a loop, or a formatted string.
    expect(targets(`python3 -c "import sys; open(sys.argv[1], 'w').write('x')" out.md`)).toEqual(none)
    expect(targets("python3 - <<'EOF'\np='a.md'\np='b.md'\nopen(p,'w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfor p in ['a.md']:\n  open(p,'w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nopen(f'{d}/a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nPath('a').joinpath('b.md').write_text('x')\nEOF")).toEqual(none)
    // Text the shell may expand before python reads it, anywhere in the program, not only in a path
    // (lessons review of #846 at fc410a7: `$CODE` in an unquoted heredoc can become any code).
    expect(targets("python3 - <<EOF\nopen('a.md','w')\n$CODE\nEOF")).toEqual(none)
    expect(targets("python3 - <<EOF\nopen('a.md','w')\nx = `cat more.py`\nEOF")).toEqual(none)
    expect(targets(`python3 -c "open('a.md','w'); $(cat more.py)"`)).toEqual(none)
    expect(targets(`D=~/.claude; python3 -c "open('$D/CLAUDE.md','a').write('x')"`)).toEqual(none)
    // Another way to write, a change of folder, or a process beside the open.
    expect(targets("python3 - <<'EOF'\nimport os\nopen('a.md','w')\nos.remove('b.md')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport os\nos.chdir('/x')\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport subprocess\nopen('a.md','w')\nsubprocess.run(['ls'])\nEOF")).toEqual(none)
    // The import rule (lessons reviews of #846, four rounds of import shapes): the files are named
    // only when every `import`, `__import__` and `importlib` in the text is a plain top level import
    // line read whole, and every module it binds has no file writers. Anything else cannot be read.
    // Round 1: a module the judge has no write rules for can write anywhere.
    expect(targets(`python3 - <<'EOF'\nimport zipfile\nopen('a.md','w')\nzipfile.ZipFile('${'/Users'}/dan/.claude/CLAUDE.md','w')\nEOF`)).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport sqlite3\nopen('a.md','w')\nsqlite3.connect('x.db')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom tempfile import mkstemp\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport os\nopen('a.md','w')\nos.makedirs('x')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nm = __import__('zip' + 'file')\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport importlib\nopen('a.md','w')\nEOF")).toEqual(none)
    // os itself is not quiet, however little of it is used.
    expect(targets("python3 - <<'EOF'\nimport os\nif os.path.exists('x'):\n  open('a.md','w')\nEOF")).toEqual(none)
    // Round 4: an import after a colon, indented, or inside an expression is not a plain line.
    expect(targets(`python3 - <<'EOF'\nif 1: import zipfile\nopen('a.md','w')\nzipfile.ZipFile('${'/Users'}/dan/.claude/CLAUDE.md','w')\nEOF`)).toEqual(none)
    expect(targets("python3 - <<'EOF'\ntry: import sqlite3\nexcept Exception: pass\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nif True:\n    import zipfile\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport json; import zipfile\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom json import (\n  dumps,\n)\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom . import x\nopen('a.md','w')\nEOF")).toEqual(none)
    // Round 4: a dotted import binds its parent, so `import os.path` binds os.
    expect(targets("python3 - <<'EOF'\nimport os.path\nopen('a.md','w')\nos.chflags('b', 0)\nEOF")).toEqual(none)
    // Any rename is a move, however many arguments it takes; a replace is one when it is called on a
    // Path or on a name assigned from one (Dan, 2026-10-06: str.replace stays allowed, since the text
    // alone cannot tell the two apart on any other receiver).
    expect(targets(`python3 - <<'EOF'\nopen('a.md','w')\nx.rename('${'/Users'}/dan/.claude/CLAUDE.md', 'b')\nEOF`)).toEqual(none)
    expect(targets(`python3 - <<'EOF'\nimport pathlib\np = pathlib.Path('x')\nopen('a.md','w')\np.replace('${'/Users'}/dan/.claude/CLAUDE.md', 'b')\nEOF`)).toEqual(none)
    expect(targets(`python3 - <<'EOF'\nfrom pathlib import Path\nopen('a.md','w')\nPath('x').replace('${'/Users'}/dan/.claude/CLAUDE.md', 'b')\nEOF`)).toEqual(none)
    // A move of a pathlib Path, by its one argument or by name.
    expect(targets(`python3 - <<'EOF'\nfrom pathlib import Path\nopen('a.md','w')\nPath('x').rename('${'/Users'}/dan/.claude/CLAUDE.md')\nEOF`)).toEqual(none)
    expect(targets(`python3 - <<'EOF'\nfrom pathlib import Path\nopen('a.md','w')\nPath('x').replace(target='${'/Users'}/dan/.claude/CLAUDE.md')\nEOF`)).toEqual(none)
    // pathlib's own writers the judge has no rule for.
    expect(targets(`python3 - <<'EOF'\nfrom pathlib import Path\nopen('a.md','w')\nPath('x').copy('${'/Users'}/dan/.claude/CLAUDE.md')\nEOF`)).toEqual(none)
    // Round 3: os taken apart by a from import is os too: only its path is quiet.
    expect(targets("python3 - <<'EOF'\nfrom os import chflags\nopen('a.md','w')\nchflags('b', 0)\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom os import remove\nopen('a.md','w')\nremove('b')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom os import *\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom os import path\nif path.exists('x'):\n  open('a.md','w')\nEOF")).toEqual([[`${CWD}/a.md`]])
    // sys holds every loaded module (sys.modules, os among them) and the import machinery itself, and
    // each review of #859 found another route to them. So sys is never quiet (follow up to #846, #830):
    // any import of sys, or of anything from it, leaves the program's files unnamed.
    expect(targets("python3 - <<'EOF'\nfrom sys import modules\nopen('a.md','w')\nmodules['os'].remove('b')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom sys import modules as m\nopen('a.md','w')\nm['os'].remove('b')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom sys import argv, modules\nopen('a.md','w')\nEOF")).toEqual(none)
    // A star import was already refused for every module (measured: `from json import *` names
    // nothing either); pinned here for sys.
    expect(targets("python3 - <<'EOF'\nfrom sys import *\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport sys as s\nopen('a.md','w')\ns.modules['os'].remove('b')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport sys\nopen('a.md','w')\nsys.__dict__['mod' + 'ules']['os'].remove('b')\nEOF")).toEqual(none)
    // The routes the lessons review of #859 at 954124a named: getattr with a built string, dir(sys),
    // and sys.meta_path.
    expect(targets("python3 - <<'EOF'\nimport sys\nopen('a.md','w')\ngetattr(sys, 'mod' + 'ules')['os'].remove('b')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport sys\nopen('a.md','w')\nfor n in dir(sys):\n  print(n)\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport sys\nopen('a.md','w')\nsys.meta_path[0].find_spec('os', None)\nEOF")).toEqual(none)
    // And sys used plainly is not quiet either: its files are not named, so ask before saving asks.
    expect(targets("python3 - <<'EOF'\nfrom sys import argv\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport sys\nopen('a.md','w')\nsys.stdout.write('done')\nEOF")).toEqual(none)
    // A quiet module that re-exports os or sys as an attribute is a route to them (lessons review of
    // #859 at 9971367), as is any module's namespace read whole. Each leaves the files unnamed.
    expect(targets("python3 - <<'EOF'\nimport pathlib\nopen('a.md','w')\npathlib.os.remove('b')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport glob\nopen('a.md','w')\nglob.os.chflags('b', 0)\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport typing\nopen('a.md','w')\ntyping.sys.stdout.write('x')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport json\nopen('a.md','w')\njson.__dict__['x']\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport json\nopen('a.md','w')\nvars(json)\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport json\nopen('a.md','w')\ngetattr(json, 'x')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nimport json\nopen('a.md','w')\n__import__('json')\nEOF")).toEqual(none)
    // A from import of os, sys or modules out of any module, quiet or not, aliased or not, binds the
    // real one (#862, lessons review of #859 at dbfb11c). Each leaves the files unnamed.
    expect(targets("python3 - <<'EOF'\nfrom glob import os\nopen('a.md','w')\nos.chflags('b', 0)\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom glob import os as o\nopen('a.md','w')\no.chflags('b', 0)\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom typing import sys\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom pathlib import os\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom json import dumps, os\nopen('a.md','w')\nEOF")).toEqual(none)
    expect(targets("python3 - <<'EOF'\nfrom posixpath import modules\nopen('a.md','w')\nEOF")).toEqual(none)
    // The control: a from import of an ordinary name out of a quiet module still names its file.
    expect(targets("python3 - <<'EOF'\nfrom json import dumps\nopen('a.md','w')\nEOF")).toEqual([[`${CWD}/a.md`]])
    // The control: the same program with a quiet module instead still names its file.
    expect(targets("python3 - <<'EOF'\nimport json\nopen('a.md','w')\nEOF")).toEqual([[`${CWD}/a.md`]])
    // Only python's writes are named so far.
    expect(targets(`node -e "require('fs').writeFileSync('a.md', 'x')"`)).toEqual(none)
  })
})

// #965: the shell runs a command substitution, $(...) or backticks, before the command it sits in,
// and in an unquoted heredoc's body before the program fed that body starts. No reader reported its
// writes, so every guard reading $.modkit.writes let a write to lasting memory, or to another
// session's file, through unseen. A quoted delimiter stops the shell expanding the body: it is data.
const MEM = `${HOME}/.claude/CLAUDE.md`
const changed = (command: string, cwd = CWD) => read(command, cwd).changes.map(c => `${c.does} ${c.path ?? `(as written) ${c.word}`}`)
describe('writes: what the shell runs inside a command substitution (#965)', () => {
  const sub = '$(cat rules.md >> ~/.claude/CLAUDE.md)'
  const tick = '`cat rules.md >> ~/.claude/CLAUDE.md`'
  test('in an unquoted heredoc body, $(...) and backticks are read as the commands they are, whatever the body feeds', () => {
    for (const s of [sub, tick]) {
      for (const open of ['python3 - <<EOF', 'python3 -<<EOF', 'cat <<EOF', 'cat > out.md <<EOF', 'node <<EOF']) {
        const command = `${open}\nprint("done ${s} now")\nEOF`
        expect(`${command} => ${paths(command).join(', ')}`).toContain(MEM)
      }
      // <<- takes the leading tabs off the body and the delimiter line.
      const tabbed = `python3 - <<-EOF\n\tprint("done ${s} now")\n\tEOF`
      expect(`${tabbed} => ${paths(tabbed).join(', ')}`).toContain(MEM)
    }
    // Every change it makes, not only content: a removal, an in place edit.
    expect(changed('cat <<EOF\nx $(rm old.txt) y\nEOF')).toEqual([`remove ${CWD}/old.txt`])
    expect(paths('cat <<EOF\n`sed -i "" s/a/b/ notes.md`\nEOF')).toEqual([`${CWD}/notes.md`])
  })
  test('under a quoted or escaped delimiter the body is data, and an escaped $ or backtick in an unquoted one is text', () => {
    for (const s of [sub, tick]) {
      for (const open of ["python3 - <<'EOF'", 'python3 - <<"EOF"', 'python3 - <<\\EOF', "cat <<'EOF'", "cat <<-'EOF'"]) {
        const command = `${open}\nprint("done ${s} now")\nEOF`
        expect(`${command} => ${paths(command).join(', ')}`).toBe(`${command} => `)
      }
    }
    expect(paths('cat <<EOF\n\\$(cat rules.md >> ~/.claude/CLAUDE.md) \\`cat rules.md >> ~/.claude/CLAUDE.md\\`\nEOF')).toEqual([])
    // A backslash escaping itself leaves the $ after it live.
    expect(paths('cat <<EOF\n\\\\$(cat rules.md >> ~/.claude/CLAUDE.md)\nEOF')).toEqual([MEM])
    // Arithmetic runs no command: $((2 > 1)) compares, it writes no file named 1.
    expect(paths('cat <<EOF\n$((2 > 1))\nEOF')).toEqual([])
  })
  test('nested substitutions, one spanning lines, and backticks inside $(...) are each read', () => {
    expect(paths('cat <<EOF\n$(echo "$(cat a >> b.md)")\nEOF')).toEqual([`${CWD}/b.md`])
    // Beside the word the reader already gave as written, with the backtick in it.
    expect(paths('cat <<EOF\n$(echo `cat a >> c.md`)\nEOF')).toContain(`${CWD}/c.md`)
    expect(paths('cat <<EOF\n`echo \\`cat a >> d.md\\``\nEOF')).toContain(`${CWD}/d.md`)
    expect(paths('cat <<EOF\nx $(echo one > a.md\necho two > b.md) y\nEOF')).toEqual([`${CWD}/a.md`, `${CWD}/b.md`])
    // A ) quoted inside the substitution does not end it.
    expect(paths('cat <<EOF\n$(echo ")" > e.md)\nEOF')).toEqual([`${CWD}/e.md`])
    // A substitution inside arithmetic runs, and one whose $(( is closed by no )) is a command.
    expect(paths('cat <<EOF\n$(( $(wc -l < a > f.md) + 1 ))\nEOF')).toEqual([`${CWD}/f.md`])
    expect(paths('cat <<EOF\n$((echo hi) > g.md)\nEOF')).toEqual([`${CWD}/g.md`])
  })
  test('a body that ends early: a substitution never closed is read to the end of the body, and a heredoc never ended is still read', () => {
    expect(changed('cat <<EOF\nx $(rm old.txt\nEOF')).toEqual([`remove ${CWD}/old.txt`])
    expect(paths('cat <<EOF\nx `cat a >> g.md\nEOF')).toEqual([`${CWD}/g.md`])
    expect(paths(`python3 - <<EOF\nprint("it's ${sub}")`)).toContain(MEM)
    expect(paths(`python3 - <<-EOF\n\tprint("it's ${tick}")`)).toContain(MEM)
  })
  test('at the top level too, inside double quotes or none, never inside single quotes or a comment', () => {
    expect(paths(`echo "${sub}"`)).toEqual([MEM])
    expect(paths(`echo "${tick}"`)).toEqual([MEM])
    expect(paths(`x=${sub}`)).toContain(MEM)
    expect(paths(`echo '${sub}' '${tick}'`)).toEqual([])
    expect(paths(`echo $'${sub}'`)).toEqual([])
    expect(paths(`echo "\\${sub}"`)).toEqual([])
    // A comment runs nothing (the words of one are still read as a command's, as they were).
    expect(changed('echo hi # "$(rm old.txt)"')).toEqual([])
  })
  test('a heredoc inside a substitution is read as the shell reads it: an unquoted body runs, a quoted one, such as a commit message, is text', () => {
    expect(changed('x=$(cat <<EOF\n$(rm old.txt)\nEOF\n)')).toEqual([`remove ${CWD}/old.txt`])
    expect(read("git commit -m \"$(cat <<'EOF'\nWrite > notes.txt and rm -rf src (#965)\n$(rm old.txt)\nEOF\n)\"")).toEqual({ files: [], changes: [], unnamed: [] })
    // A command after the heredoc, inside the same substitution, still runs.
    expect(paths("x=$(cat <<'EOF'\nbody\nEOF\necho done > h.md)")).toContain(`${CWD}/h.md`)
  })
  test('a cd in the command leaves a relative path in a substitution unnamed, and a cd inside one ends with it', () => {
    const r = read('cd /tmp/other && cat <<EOF\n$(cat a >> b.md) $(cat a >> ~/.claude/CLAUDE.md)\nEOF')
    expect(r.files).toContainEqual({ word: 'b.md' })
    expect(r.files).toContainEqual({ word: '~/.claude/CLAUDE.md', path: MEM })
    expect(paths('echo "$(cd /tmp && echo x > a.txt)"; echo y > b.txt')).toEqual([`${CWD}/b.txt`, '/tmp/a.txt'])
  })
  test('a write the substitution runs whose files no word names is reported as one', () => {
    const r = read("cat <<EOF\n$(python3 -c 'import os; os.remove(\"x.md\")')\nEOF")
    expect(r.unnamed.map(u => u.what)).toEqual(['an inline python3 script'])
    // Once, also where a heredoc never ended is read both as a body and as commands (lessons review of #972).
    expect(read("cat <<EOF\n$(python3 -c 'import os; os.remove(\"x.md\")')").unnamed.map(u => u.what)).toEqual(['an inline python3 script'])
  })
  // #974: the substitutions are now given by the command reader, which reads a shell's own script as
  // the commands that shell runs, so one there is read too; a quoted heredoc fed to anything but a
  // shell stays data.
  test("a substitution in a shell's own script, single quoted or fed as a quoted heredoc, is read; fed to another program it is data", () => {
    expect(changed("bash -c 'echo $(rm old.txt)'")).toEqual([`remove ${CWD}/old.txt`])
    expect(changed("sh <<'EOF'\nx=`touch new.md`\nEOF")).toEqual([`touch ${CWD}/new.md`])
    expect(paths("echo 'echo \"$(cat a >> b.md)\"' | zsh")).toEqual([`${CWD}/b.md`])
    expect(read("python3 - <<'EOF'\nprint('$(rm old.txt)')\nEOF").changes).toEqual([])
  })
  // #975: a process substitution, <(...) or >(...), runs its commands as the command it sits in starts.
  // In double quotes or a heredoc's body it is text.
  test('a process substitution is read as the commands it runs; quoted, or in a heredoc body, it is text', () => {
    expect(changed('diff <(rm old.txt) b.txt')).toEqual([`remove ${CWD}/old.txt`])
    expect(paths('cat <(echo x > a.md) >(tee b.md)')).toEqual([`${CWD}/a.md`, `${CWD}/b.md`])
    // An operand that is a process substitution is a pipe, never a file.
    expect(paths('echo x | tee >(cat > c.md)')).toEqual([`${CWD}/c.md`])
    expect(changed('diff <(sort <(rm old.txt)) b.txt')).toEqual([`remove ${CWD}/old.txt`])
    expect(changed("bash -c 'diff <(rm old.txt) b.txt'")).toEqual([`remove ${CWD}/old.txt`])
    expect(changed('echo "<(rm old.txt)"')).toEqual([])
    expect(changed('cat <<EOF\n<(rm old.txt)\nEOF')).toEqual([])
    expect(changed("echo '<(rm old.txt)'")).toEqual([])
  })
  // #975: a shell fed an unquoted heredoc runs the body as the outer shell expanded it, so an escaped
  // substitution there reaches it unescaped and runs; under a quoted delimiter it stays escaped.
  test('a shell fed an unquoted heredoc runs an escaped substitution in it; quoted, it is text', () => {
    expect(changed('bash <<EOF\necho \\$(rm old.txt)\nEOF')).toEqual([`remove ${CWD}/old.txt`])
    expect(paths('sh <<EOF\necho \\`cat a >> b.md\\`\nEOF')).toEqual([`${CWD}/b.md`])
    expect(changed("bash <<'EOF'\necho \\$(rm old.txt)\nEOF")).toEqual([])
    expect(changed('cat <<EOF\necho \\$(rm old.txt)\nEOF')).toEqual([])
  })
  test('a file the line names and a substitution also edits or copies onto keeps what the substitution says of it (lessons review of #972)', () => {
    expect(read("echo x > f.md; echo \"$(sed -i '' s/a/b/ f.md)\"").files).toEqual([{ word: 'f.md', path: `${CWD}/f.md`, edits: true }])
    expect(read('echo x > d; echo "$(cp /tmp/a.md d)"').files).toEqual([{ word: 'd', path: `${CWD}/d`, sources: ['/tmp/a.md'], mayBeFolder: true }])
  })
})

// #2171: a write to a variable alone whose value the reader cannot read (`T=$(mktemp); ... > "$T"`)
// is given with `values`, every value any assignment in the command gives it, as written, so a
// guard can judge what those values are. Absent wherever anything else may set it or it was not set
// before the write.
describe('writes: the values a variable alone is given (#2171)', () => {
  const values = (command: string) => read(command).files.map(f => f.values)
  test('a variable set only by plain assignments before the write is given every value, as written', () => {
    expect(values('T=$(mktemp); echo x > "$T"')).toEqual([['$(mktemp)']])
    expect(values('T="$(mktemp -d)"; git show HEAD:app/page.tsx > ${T}')).toEqual([['$(mktemp -d)']])
    expect(values('export T=$(mktemp); wc -l app/page.tsx | tee "$T"')).toEqual([['$(mktemp)']])
    // Two values, a ; or an && between them unknown: both are given.
    expect(values('T=$(mktemp); T=$(head -1 list); echo x > "$T"')).toEqual([['$(mktemp)', '$(head -1 list)']])
    // A value given anywhere in the command counts, after the write too (a loop or a function may run it first).
    expect(values('T=$(mktemp); echo x > "$T"; T=$(head -1 list)')).toEqual([['$(mktemp)', '$(head -1 list)']])
    // Inside a subshell too, though it ends there.
    expect(values('T=$(mktemp); (T=$(head -1 list)); echo x > "$T"')).toEqual([['$(mktemp)', '$(head -1 list)']])
  })
  test('a variable the reader can read is given its path, never values', () => {
    expect(read('T=out.txt; echo x > "$T"').files).toEqual([{ word: '$T', path: `${CWD}/out.txt` }])
  })
  test('no values where the variable was not set before the write, or ended with a subshell', () => {
    expect(values('echo x > "$T"')).toEqual([undefined])
    expect(values('echo x > "$T"; T=$(mktemp)')).toEqual([undefined])
    expect(values('echo x > "$T"; T=$(mktemp); echo y > "$T"')).toEqual([undefined])
    expect(values('(T=$(mktemp)); echo x > "$T"')).toEqual([undefined])
    // Set at the first write, not at the second, which is the same word.
    expect(values('(T=$(mktemp); echo x > "$T"); echo y > "$T"')).toEqual([undefined])
  })
  test('no values where anything but a plain assignment may set it, anywhere in the command', () => {
    const given = [

      'T=$(mktemp); read T < list; echo x > "$T"',
      'T=$(mktemp); echo x > "$T"; read T < list',
      'T=$(mktemp); mapfile T < list; echo x > "$T"',
      'T=$(mktemp); readarray T < list; echo x > "$T"',
      'T=$(mktemp); printf -v T %s app/page.tsx; echo x > "$T"',
      'T=$(mktemp); T+=.tsx; echo x > "$T"',
      'T=$(mktemp); declare -n T=OTHER; echo x > "$T"',
      'T=$(mktemp); for T in a b; do :; done; echo x > "$T"',
      'T=$(mktemp); while read -r T; do echo x > "$T"; done < list',
      'T=$(mktemp); eval "$X"; echo x > "$T"',
      'T=$(mktemp); echo x > "$T"; source ./env.sh',
      "T=$(mktemp); trap 'T=app/page.tsx' DEBUG; echo x > \"$T\"",
      "T=$(mktemp); alias echo='T=app/page.tsx; echo'; echo x > \"$T\"",
      'T=$(mktemp); : ${T:=app/page.tsx}; echo x > "$T"',
      'T=$(mktemp); : ${T=app/page.tsx}; echo x > "$T"',
    ].filter(c => values(c)[0] !== undefined)
    // Every command given values is named, so a looser reader shows each case it lets through.
    expect(given).toEqual([])
  })
  test('no values for a word that is more than the variable alone', () => {
    expect(values('T=$(mktemp); echo x > "$T/a"')).toEqual([undefined])
    expect(values('T=$(mktemp); echo x > "$T"x')).toEqual([undefined])
    expect(values('T=$(mktemp); echo x > "$T$U"')).toEqual([undefined])
  })
  test('no values where a substitution writes the same word, which no assignment of the line reaches', () => {
    expect(values('T=$(mktemp); echo x > "$T"; echo "$(echo y > "$T")"')).toEqual([undefined])
  })
})

// #2920: a script a folder is handed, fed as its text on standard input, that loads a module by a
// computed name (`await import(rulesPath)`) and otherwise only reads. Its judge reads it as code it
// cannot read, the same as eval, while a static import of a local module (whose code no reader follows
// either) reads as no write at all. `onlyLoads` says the computed loads are all that left it unread,
// so a guard asking only what the script's own text writes can tell the two apart.
describe('writes: a program whose only unread part is a module it loads by a computed name (#2920)', () => {
  const fed = (text: string) => read(`node <<'AREA_CHECK_SCRIPT'\n${text}\nAREA_CHECK_SCRIPT`).unnamed
  const READS = "import { readFileSync, readdirSync } from 'node:fs'\nfor (const r of process.argv.slice(3)) for (const n of readdirSync(r)) console.log(readFileSync(`${r}/${n}`, 'utf8').length)"
  test('a computed import or require, and nothing else unread, is marked', () => {
    expect(fed(`const rules = await import(process.argv[2])\n${READS}`).map(u => u.onlyLoads)).toEqual([true])
    expect(fed(`const rules = require(process.argv[2])\n${READS}`).map(u => u.onlyLoads)).toEqual([true])
    expect(read(`python3 - <<'EOF'\nimport importlib, sys\nm = importlib.import_module(sys.argv[1])\nprint(open(sys.argv[2]).read())\nEOF`).unnamed.map(u => u.onlyLoads)).toEqual([true])
  })
  test('one that also writes, runs a process or runs code it builds is not', () => {
    for (const also of ["writeFileSync(process.argv[3] + '/x.ts', 'x')", "require('node:child_process').execSync('git status')", 'eval(process.argv[4])', 'new Function(process.argv[4])()', "vm.runInThisContext(process.argv[4])"]) {
      expect([also, fed(`const rules = await import(process.argv[2])\n${READS}\n${also}`).map(u => u.onlyLoads)]).toEqual([also, [undefined]])
    }
  })
  test('one whose text the shell may have changed is not, and one that only reads is no write at all', () => {
    expect(read(`node <<EOF\nconst rules = await import(process.argv[2])\n${READS}\nEOF`).unnamed.map(u => u.onlyLoads)).toEqual([undefined])
    expect(fed(READS)).toEqual([])
  })
})

// #3021: the write reader gave nothing for a command whose effect cannot be read (eval, a command a
// value names, an alias, ssh, a trap whose text the shell expands, a word rtk's proxy splits), so a
// guard reading only the writes read it as writing nothing. Each is given in `unread`, with why; and
// a trap's text, now read as the commands it runs, writes what those commands write.
describe('writes: commands whose effect cannot be read (#3021)', () => {
  const EVAL = 'run as text by eval, so what it runs cannot be read'
  const NAMED = 'named by a value the shell expands, so what it runs cannot be read'
  test('each is given as unread, with its words, why and the folder it runs in, once', () => {
    expect(read('eval "$x"').unread).toEqual([{ words: ['eval', '$x'], why: EVAL, folder: CWD }])
    expect(read('"$@"').unread).toEqual([{ words: ['$@'], why: NAMED, folder: CWD }])
    expect(read('ls; $cmd a > out.txt; eval "$x"; eval "$x"').unread).toEqual([
      { words: ['$cmd', 'a', '>', 'out.txt'], why: NAMED, folder: CWD },
      { words: ['eval', '$x'], why: EVAL, folder: CWD },
    ])
    expect(read('rtk proxy "$CMD"').unread).toEqual([{ words: ['$CMD'], why: 'split by rtk proxy from one word the shell expands, so what it runs cannot be read', folder: CWD }])
    expect(read('ssh host rm x').unread?.map(u => u.why)).toEqual(['run by ssh on another machine, so what it does cannot be read'])
    expect(read(`alias gp='git push'`).unread?.map(u => u.why)).toEqual(['setting an alias, which changes what a later word runs, so that cannot be read'])
  })
  // The folder is where a cd before it leaves the shell, as an inline program's is (#1151), so a
  // guard places the names in its words there; left out where that cd cannot be followed, and the
  // same words in another folder are another command.
  test('the folder follows a cd before it, and is left out where the cd cannot be followed', () => {
    expect(read('cd build && eval "$x"').unread).toEqual([{ words: ['eval', '$x'], why: EVAL, folder: `${CWD}/build` }])
    expect(read('cd "$D" && eval "$x"').unread).toEqual([{ words: ['eval', '$x'], why: EVAL }])
    expect(read('eval "$x"; cd build; eval "$x"').unread).toEqual([
      { words: ['eval', '$x'], why: EVAL, folder: CWD },
      { words: ['eval', '$x'], why: EVAL, folder: `${CWD}/build` },
    ])
    expect(read('cd build; echo "$(eval "$x")"').unread).toEqual([{ words: ['eval', '$x'], why: EVAL }])
  })
  test('one inside a substitution or a script a shell is given is given too', () => {
    expect(read('echo "$(eval "$x")"').unread).toEqual([{ words: ['eval', '$x'], why: EVAL, folder: CWD }])
    expect(read(`bash -c '"$@"' -- rm x`).unread).toEqual([{ words: ['$@'], why: NAMED, folder: CWD }])
    expect(read(`bash <<'EOF'\neval "$1"\nEOF`).unread).toEqual([{ words: ['eval', '$1'], why: EVAL, folder: CWD }])
  })
  test('a command that can be read gives none, and what an unread one names is still read', () => {
    expect(read('ls > out.txt').unread).toBeUndefined()
    expect(read('"$HOME/bin/tool" x').unread).toBeUndefined()
    expect(read('[[ -z "$r" || "$r" == --* ]] && echo x > out.txt').unread).toBeUndefined()
    expect(paths('$cmd a > out.txt')).toEqual([`${CWD}/out.txt`])
  })
  test("a trap's text writes what its commands write, in the folder the shell that set it ends in", () => {
    expect(read(`trap 'rm -f out.txt' EXIT; make`).changes).toEqual([{ word: 'out.txt', path: `${CWD}/out.txt`, does: 'remove' }])
    expect(paths(`trap 'echo done > log.txt' EXIT; cd build; make`)).toEqual([`${CWD}/build/log.txt`])
    expect(paths(`(cd sub; trap 'echo x > a.txt' EXIT); echo y > b.txt`)).toEqual([`${CWD}/sub/a.txt`, `${CWD}/b.txt`])
    expect(paths(`trap -- 'echo x > a.txt' EXIT`)).toEqual([`${CWD}/a.txt`])
    expect(read(`trap 'rm -f out.txt' EXIT`).unread).toBeUndefined()
    expect(read(`trap "rm -f $tmp" EXIT`).unread?.map(u => u.why)).toEqual(['setting a trap whose text the shell expands, so what it runs later cannot be read'])
  })
})

// #3022: the copy step of tools/check-mods.sh runs over three lines joined by a backslash. Each
// backslash and its new line was read as a word, so its rm was given a file named by a new line,
// placed in the folder the script runs from, whatever the step names.
describe('writes: a command continued over lines by a backslash (#3022)', () => {
  test('is read as the same command written on one line', () => {
    const step = (join: string) => `rm -rf /w/copy/types ${join}&& mkdir -p /w/copy/types ${join}&& cp -R a b /w/copy/types/`
    expect(read(step('\\\n      '))).toEqual(read(step('')))
    expect(changes(step('\\\n      '))).toEqual(['remove /w/copy/types tree', 'folder /w/copy/types'])
    expect(read(`echo x > \\\n  out.txt`).files).toEqual([{ word: 'out.txt', path: `${CWD}/out.txt` }])
  })
  test('a redirect on the line after a heredoc opens is a write, never a line of its body', () => {
    expect(paths('cat <<EOF \\\n  > out.txt\nbody\nEOF')).toEqual([`${CWD}/out.txt`])
  })
})

// #3070: a script handed a word holding bash's old arithmetic (`"x\\$[0-9]"`) was given it as a word
// the shell fills in, which every guard reads as a variable's value. Where the reader works the sum
// out, the script is handed one of two known texts: the sum worked out (bash, zsh) or the word as
// typed (dash, ksh), so both are given, each as text.
describe('writes: a script handed a word holding old arithmetic (#3070)', () => {
  const runs = (command: string, cwd = CWD) => read(command, cwd).runs ?? []
  const marked = (command: string) => runs(command).map(r => r.args.map(a => [a.word, a.unexpanded === true]))
  test('each text a shell may hand on is given, as text', () => {
    expect(marked(String.raw`python3 s.py "wall|\\$[0-9],[0-9]{3}|tilt"`)).toEqual([[[String.raw`wall|\$[0-9],[0-9]{3}|tilt`, true], [String.raw`wall|\-9,[0-9]{3}|tilt`, true]]])
    expect(runs('python3 s.py "app/page$[1+1].tsx"').map(r => r.args.filter(a => a.path).map(a => [a.path, a.unexpanded === true]))).toEqual([[[`${CWD}/app/page2.tsx`, true]]])
    expect(marked('npx prettier --write "src/a$[1+1].ts"')).toEqual([[['src/a$[1+1].ts', true], ['src/a2.ts', true]]])
  })
  test('one the reader does not work out, or beside another expansion, is still a word the shell fills in', () => {
    expect(marked('python3 s.py "$[N]" "$P$[1]" "$[010]"')).toEqual([[['$[N]', false], ['$P$[1]', false], ['$[010]', false]]])
  })
  test('only a word handed to a run is given both ways: a write the command itself makes is read as before', () => {
    expect(read('echo x > "out$[1+1].txt"').files).toEqual([{ word: 'out$[1+1].txt' }])
    expect(read('cp a.txt "out$[1+1].txt"').files.map(f => f.word)).toEqual(['out$[1+1].txt'])
  })
  // #3088: every shell works out `$((...))` (bash, zsh, sh, dash and ksh measured 2026-11-16), so a
  // word holding only such sums is handed on as the one text they make, never as typed.
  test('a word holding only $((...)) sums is given as the one text every shell hands on', () => {
    expect(marked(String.raw`python3 s.py "a|\\$((0-9)),[0-9]{3}|b"`)).toEqual([[[String.raw`a|\-9,[0-9]{3}|b`, true]]])
    expect(marked('python3 s.py "$[1]$((1))"')).toEqual([[['$[1]$((1))', true], ['11', true]]])
    expect(marked('python3 s.py "$((N+1))"')).toEqual([[['$((N+1))', false]]])
  })
})

// #3093: a setting written in front of a run (`TMPDIR=x bash tools/check-mods.sh`) is carried on the
// run as `env`, so a guard judging a script by what it is handed sees what it reads from its
// environment too.
describe('writes: the settings a script is run with (#3093)', () => {
  const envs = (command: string) => (read(command).runs ?? []).map(r => [r.script, r.env])
  test('an assignment before the script, or given to env, is carried on its run', () => {
    expect(envs('TMPDIR=payload/mods bash tools/check-mods.sh payload/mods')).toEqual([['tools/check-mods.sh', ['TMPDIR=payload/mods']]])
    expect(envs('env TMPDIR=x bash tools/check-mods.sh payload/mods')).toEqual([['tools/check-mods.sh', ['TMPDIR=x']]])
    expect(envs('A=1 npx prettier --write src/a.ts')).toEqual([['prettier', ['A=1']]])
  })
  test('a run given none carries none, whatever else the line sets', () => {
    expect(envs('bash tools/check-mods.sh payload/mods')).toEqual([['tools/check-mods.sh', undefined]])
    expect(envs('T=x; bash tools/check-mods.sh payload/mods && git log --format=%s')).toEqual([['tools/check-mods.sh', undefined]])
  })
})

// claude-config#3279: with no answer from Dan recorded, a file that changes a project's look could
// still be rewritten by a program this reader did not know writes: ed, ex or vim given a script,
// and a pipe into sponge, each read as writing nothing (measured 2026-11-19, 23 of 72 routes tried
// against the design round guard). The reader knows a writer by its name, so every other program
// that writes the file its words name passed the same way: sort -o, uniq's second file, xxd,
// base64 -o, openssl -out, plutil, gzip and its kin. Each one installed on this Mac was run first
// and seen to change the file it names.
describe('writes: an editor run on files, and the other programs that write a file they name (#3279)', () => {
  const F = `${CWD}/app/globals.css`
  const edited = (command: string) => read(command).files.filter(f => f.edits).map(f => f.path)
  const scripts = (command: string) => read(command).unnamed.map(u => ({ what: u.what, program: u.program?.trim(), folder: u.folder, inputs: u.inputs }))
  const removed = (command: string) => read(command).changes.filter(c => c.does === 'remove').map(c => c.path)
  test('ed, ex, vi and their kin edit in place every file they are opened on', () => {
    for (const command of [
      `ed -s app/globals.css <<'EOF'\n1s/a/b/\nw\nq\nEOF`,
      `printf '1s/a/b/\\nw\\nq\\n' | ed -s app/globals.css`,
      'ed -s app/globals.css < /tmp/fix.ed',
      `red -p '*' app/globals.css <<'EOF'\nw\nq\nEOF`,
      `ex -sc '%s/a/b/|x' app/globals.css`,
      `ex -s app/globals.css <<'EOF'\n%s/a/b/\nwq\nEOF`,
      `ex -s +'%s/a/b/' +wq app/globals.css`,
      `vim -es -c '%s/a/b/' -c wq app/globals.css`,
      `vim -Es -c '%s/a/b/' -c wq app/globals.css`,
      `vim -c '%s/a/b/' -c wq app/globals.css`,
      `vi -es -c '%s/a/b/' -c wq app/globals.css`,
      // neovim's switch for running with no screen, written in two halves: the scan that keeps
      // every Chrome launch going through its helper reads that switch, whole, as a Chrome launch.
      `nvim ${'--head' + 'less'} -c '%s/a/b/' -c wq app/globals.css`,
      // Read only mode stops nothing: `w!` writes (measured with view on macOS, 2026-11-19).
      `view -es -c 'w!' -c q app/globals.css`,
      'vim -u NONE -i NONE -es -S /tmp/fix.vim app/globals.css',
      `emacs --batch app/globals.css --eval '(replace-string "a" "b")' -f save-buffer`,
      'env vim -es -c wq app/globals.css',
    ])
      expect([command, edited(command)]).toEqual([command, [F]])
  })
  test('the value an editor option takes is no file it is opened on, and a file an option writes is one it writes', () => {
    expect(paths(`vim -es -c 'e notes.md' -c wq a.md b.md`)).toEqual([`${CWD}/a.md`, `${CWD}/b.md`])
    // Outside ex mode -s names a file of keystrokes; in it, -s only silences.
    expect(paths('vim -s keys.txt a.md')).toEqual([`${CWD}/a.md`])
    expect(paths('vim -es a.md')).toEqual([`${CWD}/a.md`])
    expect(paths('ex +3 a.md')).toEqual([`${CWD}/a.md`])
    expect(paths('vim -w typed.log a.md')).toEqual([`${CWD}/a.md`, `${CWD}/typed.log`])
    expect(paths('vim -- -odd.md')).toEqual([`${CWD}/-odd.md`])
    expect(paths(`ed -p '> ' a.md`)).toEqual([`${CWD}/a.md`])
  })
  // An editor's script can name any other file (`w other.css`, `e other.css`) and run a shell, so a
  // run given one is also a write the words do not name. Where the command holds the whole script
  // it is given as `program`, with the folder it runs in, for a guard to read the names in.
  test("an editor's script is a write the words do not name, given as its program where the command holds all of it", () => {
    expect(scripts(`ed -s <<'EOF'\ne app/globals.css\nw\nq\nEOF`)).toEqual([{ what: 'a script ed runs', program: 'e app/globals.css\nw\nq', folder: CWD, inputs: [] }])
    expect(scripts(`vim -es -c 'w app/globals.css' -c q notes.md`)).toEqual([{ what: 'a script vim runs', program: 'w app/globals.css\nq', folder: CWD, inputs: [] }])
    expect(scripts(`ex -s +'%s/a/b/' +wq a.md`)).toEqual([{ what: 'a script ex runs', program: '%s/a/b/\nwq', folder: CWD, inputs: [] }])
    expect(scripts(`cd "$D" && vim -es -c wq a.md`)).toEqual([{ what: 'a script vim runs', program: 'wq', folder: undefined, inputs: [] }])
    // A script handed as a here-string is in the command's own words as a heredoc's is. It was read
    // as no script at all, so the file it names ran unasked (the review of #3324).
    for (const fed of [`<<< 'e app/globals.css'`, `<<<'e app/globals.css'`, `<<< "e app/globals.css"`, `0<<< 'e app/globals.css'`]) {
      for (const editor of ['ed -s', 'ex -s', 'vim -es']) {
        const got = scripts(`${editor} ${fed}`)
        expect(got.map(g => g.what)).toEqual([`a script ${editor.split(' ')[0]} runs`])
        expect(got[0]?.program).toContain('e app/globals.css')
        expect(got[0]?.folder).toBe(CWD)
      }
    }
    expect(scripts(`ed -s <<< $'e app/globals.css\\n1s/a/b/\\nw\\nq'`)[0]?.program).toContain('e app/globals.css\n1s/a/b/')
    // A here-string on another descriptor is not the editor's script, and one given to a program
    // that is no editor is read as before.
    expect(scripts(`ed -s 3<<< 'e app/globals.css'`)).toEqual([])
    expect(scripts(`cat <<< 'e app/globals.css'`)).toEqual([])
    // A script piped in or read from a file is not in the command's own words.
    expect(scripts(`printf 'w\\nq\\n' | ed -s a.md`)).toEqual([{ what: 'a script ed runs', program: undefined, folder: undefined, inputs: [] }])
    expect(scripts('ed -s a.md < /tmp/fix.ed')).toEqual([{ what: 'a script ed runs', program: undefined, folder: undefined, inputs: ['/tmp/fix.ed'] }])
    expect(scripts('vim -es -S /tmp/fix.vim a.md')).toEqual([{ what: 'a script vim runs', program: undefined, folder: undefined, inputs: ['/tmp/fix.vim'] }])
    expect(scripts('vim -s keys.txt a.md')).toEqual([{ what: 'a script vim runs', program: undefined, folder: undefined, inputs: [`${CWD}/keys.txt`] }])
  })
  test('an editor given no script, opened on nothing or only asked about itself names no script and no file', () => {
    expect(scripts('vim a.md')).toEqual([])
    expect(paths('vim a.md')).toEqual([`${CWD}/a.md`])
    expect(read('vim --version')).toEqual({ files: [], changes: [], unnamed: [] })
    expect(read('which ed ex vim sponge')).toEqual({ files: [], changes: [], unnamed: [] })
    expect(read('grep -n ed app/globals.css')).toEqual({ files: [], changes: [], unnamed: [] })
  })
  test('sponge writes the file it is given, and only that one', () => {
    expect(paths(`sed 's/a/b/' app/globals.css | sponge app/globals.css`)).toEqual([F])
    expect(paths(`echo 'a{}' | sponge -a app/globals.css`)).toEqual([F])
    expect(edited(`echo 'a{}' | sponge app/globals.css`)).toEqual([])
    expect(paths('sort app/globals.css | sponge /tmp/sorted.txt')).toEqual(['/tmp/sorted.txt'])
  })
  test('a program given its output file by an option writes that file, and reads every other', () => {
    for (const command of [
      'sort -o app/globals.css app/globals.css',
      'sort --output=app/globals.css /tmp/new.css',
      'sort --output app/globals.css /tmp/new.css',
      'sort -uo app/globals.css /tmp/new.css',
      'sort -oapp/globals.css /tmp/new.css',
      'sort -k 2 -t , -o app/globals.css /tmp/new.css',
      'shuf -n 3 -o app/globals.css /tmp/new.css',
      'iconv -f latin1 -t utf-8 -o app/globals.css /tmp/new.css',
      'base64 -d -i /tmp/new.b64 -o app/globals.css',
      'openssl enc -d -aes-256-cbc -in /tmp/new.enc -out app/globals.css',
    ])
      expect([command, paths(command)]).toEqual([command, [F]])
    for (const command of ['sort app/globals.css', 'sort -k2,2 -t, app/globals.css', 'sort -u app/globals.css', 'shuf -n 3 app/globals.css', 'iconv -f latin1 -t utf-8 app/globals.css', 'base64 -i app/globals.css', 'openssl base64 -in app/globals.css'])
      expect([command, paths(command)]).toEqual([command, []])
  })
  test('a program whose second file is its output writes that file, and one given a single file only reads it', () => {
    expect(paths('uniq /tmp/new.css app/globals.css')).toEqual([F])
    expect(paths('uniq -f 1 /tmp/new.css app/globals.css')).toEqual([F])
    expect(paths('xxd -r /tmp/new.hex app/globals.css')).toEqual([F])
    expect(paths('xxd -l 16 /tmp/new.css app/globals.css')).toEqual([F])
    expect(paths('link /tmp/new.css app/globals.css')).toEqual([F])
    for (const command of ['uniq app/globals.css', 'uniq -c app/globals.css', 'uniq -f 1 app/globals.css', 'xxd app/globals.css', 'xxd -l 16 app/globals.css'])
      expect([command, paths(command)]).toEqual([command, []])
  })
  test('a converter rewrites in place each file it is given, and one only printing or checking writes none', () => {
    expect(edited('dos2unix app/globals.css')).toEqual([F])
    expect(edited('unix2dos -c mac app/globals.css app/page.tsx')).toEqual([F, `${CWD}/app/page.tsx`])
    expect(edited(`yq -i '.color = "red"' design-tokens.json`)).toEqual([`${CWD}/design-tokens.json`])
    expect(paths(`yq '.color' design-tokens.json`)).toEqual([])
    expect(edited('sd a b app/globals.css')).toEqual([F])
    expect(paths('sd -p a b app/globals.css')).toEqual([])
    expect(edited('plutil -convert xml1 design-tokens.json other.json')).toEqual([`${CWD}/design-tokens.json`, `${CWD}/other.json`])
    expect(edited('plutil -replace color -string red design-tokens.json')).toEqual([`${CWD}/design-tokens.json`])
    expect(paths('plutil -convert json -o design-tokens.json /tmp/in.plist')).toEqual([`${CWD}/design-tokens.json`])
    expect(paths('plutil -convert json -o - design-tokens.json')).toEqual([])
    expect(paths('plutil -lint design-tokens.json')).toEqual([])
    expect(paths('plutil -p design-tokens.json')).toEqual([])
    // -extract puts the value in place of the whole file, except in the raw form, which prints it.
    expect(edited('plutil -extract color json design-tokens.json')).toEqual([`${CWD}/design-tokens.json`])
    expect(paths('plutil -extract color raw design-tokens.json')).toEqual([])
    expect(paths('plutil -extract color raw -o - design-tokens.json')).toEqual([])
  })
  test('gzip and its kin put a packed or unpacked twin beside each file and take the file away, unless told to keep it or to print', () => {
    expect([paths('gzip app/globals.css'), removed('gzip app/globals.css')]).toEqual([[`${F}.gz`], [F]])
    expect([paths('gzip -9k app/globals.css'), removed('gzip -9k app/globals.css')]).toEqual([[`${F}.gz`], []])
    expect([paths('bzip2 app/globals.css'), removed('bzip2 app/globals.css')]).toEqual([[`${F}.bz2`], [F]])
    expect([paths('xz app/globals.css'), removed('xz app/globals.css')]).toEqual([[`${F}.xz`], [F]])
    // zstd keeps what it packs unless told to take it away, and -o names its output.
    expect([paths('zstd app/globals.css'), removed('zstd app/globals.css')]).toEqual([[`${F}.zst`], []])
    expect(removed('zstd --rm app/globals.css')).toEqual([F])
    expect(paths('zstd -d /tmp/new.zst -o app/globals.css')).toEqual([F])
    // Unpacking writes the name without its ending, which no word spells.
    expect([paths('gunzip app/globals.css.gz'), removed('gunzip app/globals.css.gz')]).toEqual([[F], [`${F}.gz`]])
    expect([paths('gzip -dk app/globals.css.gz'), removed('gzip -dk app/globals.css.gz')]).toEqual([[F], []])
    expect(paths('bunzip2 app/globals.css.bz2')).toEqual([F])
    expect(paths('unxz app/globals.css.xz')).toEqual([F])
    expect(paths('xz --decompress app/globals.css.xz')).toEqual([F])
    // Printing, testing and listing change no file.
    expect(read('gzip -c app/globals.css > /tmp/a.gz')).toEqual({ files: [{ word: '/tmp/a.gz', path: '/tmp/a.gz' }], changes: [], unnamed: [], stdout: [{ word: '/tmp/a.gz', path: '/tmp/a.gz' }] })
    for (const command of ['gzip -t app/globals.css.gz', 'gzip -l app/globals.css.gz', 'gunzip -c app/globals.css.gz', 'xz --stdout app/globals.css', 'zstd -t app/globals.css.zst'])
      expect([command, paths(command), removed(command)]).toEqual([command, [], []])
  })
  test('given its files by xargs, each is a write the words do not name', () => {
    for (const [command, what] of [
      [`find . -name '*.css' | xargs gzip`, 'gzip given its files by xargs'],
      [`find . -name '*.css' | xargs dos2unix`, 'dos2unix given its files by xargs'],
      [`find . -name '*.css' | xargs ex -sc '%s/a/b/|x'`, 'ex given its files by xargs'],
      [`find . -name '*.json' | xargs yq -i '.a = 1'`, 'yq given its files by xargs'],
    ] as [string, string][])
      expect([command, read(command).unnamed.map(u => u.what).includes(what)]).toEqual([command, true])
    expect(read(`find . -name '*.css' | xargs sort`).unnamed).toEqual([])
    expect(read(`find . -name '*.json' | xargs yq '.a'`).unnamed).toEqual([])
  })
})

// claude-config#3323, the three points the lessons review of #3324 left in the reader. Each was
// measured first on macOS 26.6.2 (2026-11-21), dos2unix 7.5.7 from its Homebrew bottle unpacked in
// a scratch folder and plutil as the system ships it.
// A run of a program on none of the reader's lists (#3323, below), but for what it is handed: what
// it is called, and the two sentences every guard says of it.
const notKnown = (program: string) => ({
  what: 'a program the write reader does not know',
  script: program,
  tool: true,
  unknown: true,
  why: `${program} is a program the mods do not know, so what it does with a file it is handed cannot be read before it runs`,
  remedy: `To only read a file, use a program the mods know only reads (cat, grep, head, tail, wc, diff and the others listed under "The programs that only read" in claude-config's docs/mods-design.md). If ${program} only reads too, ask Dan to add it to that list: only he may.`,
})
describe('writes: three writes the reader did not see (#3323)', () => {
  const F = `${CWD}/app/globals.css`
  const edited = (command: string) => read(command).files.filter(f => f.edits).map(f => f.path)
  const unnamed = (command: string) => read(command).unnamed.map(u => u.what)
  test("dos2unix -e is a flag (--add-eol), so the word after it is a file it rewrites, for each of its kin", () => {
    // Measured: `-e f` rewrote f, and `-e g f` rewrote both. The reader took the word after -e for
    // the option's value, so the one file was read as nothing written.
    for (const program of ['dos2unix', 'unix2dos', 'mac2unix', 'unix2mac']) {
      expect([program, edited(`${program} -e app/globals.css`)]).toEqual([program, [F]])
      expect([program, edited(`${program} -e app/page.tsx app/globals.css`)]).toEqual([program, [`${CWD}/app/page.tsx`, F]])
      expect([program, edited(`${program} --add-eol app/globals.css`)]).toEqual([program, [F]])
      expect([program, edited(`${program} -k -e -c mac app/globals.css`)]).toEqual([program, [F]])
    }
    // -c and --convmode do take a value (measured), so the mode is never read as a file.
    expect(edited('dos2unix -c mac app/globals.css')).toEqual([F])
    expect(edited('unix2dos --convmode mac app/globals.css')).toEqual([F])
    // 7.5.7 has no -C and no --codepage, in its manual or its help; it refuses both and writes
    // nothing. Neither hides the word after it from the reader.
    expect(edited('dos2unix -C app/globals.css')).toEqual([F])
    expect(edited('dos2unix --codepage app/globals.css')).toEqual([F])
  })
  test('plutil given its files by xargs is a write the words do not name, for each form that changes them', () => {
    // Measured through xargs: every one of these rewrote each file it was handed, or, with -e, put
    // a new file beside each.
    for (const form of [
      'plutil -convert xml1',
      'plutil -convert binary1',
      'plutil -convert xml1 -e plist',
      'plutil -create xml1',
      'plutil -replace color -string red',
      'plutil -insert shade -string red',
      'plutil -remove color',
      'plutil -extract color xml1',
    ])
      expect([form, unnamed(`find . -name '*.json' | xargs ${form}`).includes('plutil given its files by xargs')]).toEqual([form, true])
    expect(unnamed(`find . -name '*.json' -print0 | xargs -0 -n 1 plutil -remove color`)).toEqual(['plutil given its files by xargs'])
    expect(unnamed(`find . -name '*.json' | xargs -I {} plutil -convert xml1 {}`)).toEqual(['plutil given its files by xargs'])
  })
  test('plutil given its files by xargs writes none of them when it only prints, checks, or writes the file -o names', () => {
    // Measured through xargs: each of these left every file it was handed as it was.
    for (const form of ['plutil -lint', 'plutil -p', 'plutil -type color', 'plutil -extract color raw', 'plutil -convert xml1 -o -'])
      expect([form, read(`find . -name '*.json' | xargs ${form}`)]).toEqual([form, { files: [], changes: [], unnamed: [] }])
    // -o names the one file written, which the words do name.
    const out = read(`find . -name '*.json' | xargs plutil -convert xml1 -o /tmp/out.plist`)
    expect([out.files.map(f => f.path), out.unnamed]).toEqual([['/tmp/out.plist'], []])
  })
  test('a command named after something every object carries is on no list, and stops no other command being read', () => {
    // `constructor a b` was read as cp is (b written), and with any option the reader threw, so
    // nothing on the line was read at all, the sed after it included.
    const NAMES = ['constructor', 'toString', 'valueOf', 'hasOwnProperty', 'isPrototypeOf', 'propertyIsEnumerable', 'toLocaleString', '__proto__', '__defineGetter__', '__lookupSetter__']
    // Since the rule was turned round (Dan, 2026-11-21, below), a name on no list is a program the
    // reader does not know, so what it is handed is a run: never the copy onto b it was read as.
    const as = (name: string) => ({ files: [], changes: [], unnamed: [], runs: [{ ...notKnown(name), args: [{ word: 'a', path: `${CWD}/a` }, { word: 'b', path: `${CWD}/b` }] }] })
    for (const name of NAMES) {
      expect([name, read(`${name} a b`)]).toEqual([name, as(name)])
      expect([name, read(`${name} -n -x a b`)]).toEqual([name, as(name)])
      expect([name, read(`ls | xargs ${name} -n`)]).toEqual([name, { files: [], changes: [], unnamed: [] }])
      expect([name, edited(`${name} -n x; sed -i '' s/a/b/ app/globals.css`)]).toEqual([name, [F]])
      expect([name, paths(`/usr/local/bin/${name} -r a > app/globals.css`)]).toEqual([name, [F]])
    }
    // The real ones beside them are read as before.
    expect(paths('cp -R a b')).toEqual([`${CWD}/b`])
    expect(read('rm -f a').changes.map(c => [c.does, c.path])).toEqual([['remove', `${CWD}/a`]])
  })
})

// claude-config#3323, Dan's decisions of 2026-11-21, each from a picker. 1: "Turn it round, with the
// list (Recommended)". 2: "Add them now". The list is the 32 programs he signed off by name and no
// other, so a name added here without his sign off is a test that must not be made to pass.
const SIGNED_OFF = [
  'grep', 'cat', 'wc', 'cmp', 'rg', 'diff', 'tail', 'ls', 'head', 'cksum', '[', 'stat', 'echo',
  'cut', 'df', 'du', 'shasum', 'jq', 'pgrep', 'file', 'strings', 'tr', 'comm', 'paste', 'test', 'lsof', 'mdls', 'which', 'readlink', 'mdfind', 'pdfinfo', 'ps',
]
describe('writes: a program the reader does not know is read as writing what it is handed (#3323)', () => {
  const F = `${CWD}/app/globals.css`
  const NOT_KNOWN = 'a program the write reader does not know'
  // Each unknown program a command runs, with the paths it is handed.
  const unknown = (command: string, cwd = CWD) => (read(command, cwd).runs ?? []).filter(r => r.unknown).map(r => [r.script, r.args.map(a => a.path)])
  test('a program on none of the lists, handed a word that names a path, is a run marked unknown', () => {
    expect(read('prettier --write app/globals.css')).toEqual({
      files: [],
      changes: [],
      unnamed: [],
      runs: [{ ...notKnown('prettier'), args: [{ word: 'app/globals.css', path: F }] }],
    })
    expect(notKnown('prettier').what).toBe(NOT_KNOWN)
    // Named by its whole path, quoted, behind a runner, in a pipe, in a substitution and in a shell's script.
    expect(unknown('/opt/homebrew/bin/swiftformat app/globals.css')).toEqual([['/opt/homebrew/bin/swiftformat', [F]]])
    expect(unknown('"/Applications/Some App.app/Contents/MacOS/tool" app/globals.css')).toEqual([['/Applications/Some App.app/Contents/MacOS/tool', [F]]])
    expect(unknown('time sudo prettier --write app/globals.css')).toEqual([['prettier', [F]]])
    expect(unknown('cat list.txt | prettier --write app/globals.css | head -3')).toEqual([['prettier', [F]]])
    expect(unknown('x=$(prettier app/globals.css)')).toEqual([['prettier', [F]]])
    expect(unknown("bash -c 'prettier --write app/globals.css'")).toEqual([['prettier', [F]]])
    // Every word that spells a path is handed, an option's value written with = too; an option, an
    // address and standard input are none.
    expect(unknown('swiftc -o build/out --module-cache=build/cache app/main.swift')).toEqual([['swiftc', [`${CWD}/build/out`, `${CWD}/build/cache`, `${CWD}/app/main.swift`]]])
    expect(unknown('gh pr create --body-file notes/pr.md')).toEqual([['gh', [`${CWD}/pr`, `${CWD}/create`, `${CWD}/notes/pr.md`]]])
    expect(unknown('open https://example.com/page.html')).toEqual([])
    // A cd before it and a variable the command set are followed, as for every other write.
    expect(unknown('cd app && prettier --write globals.css')).toEqual([['prettier', [F]]])
    expect(unknown('F=app/globals.css; prettier --write "$F"')).toEqual([['prettier', [F]]])
    // The settings it is given in front of it are kept, as a script run's are (#3093).
    expect((read('NODE_ENV=x prettier --write app/globals.css').runs ?? []).map(r => r.env)).toEqual([['NODE_ENV=x']])
  })
  test('the shell words the reader takes for a program are read the same way, since none is on the list', () => {
    // `[[` is the shell's own test, as `[` is, but Dan signed off `[` and `test` only.
    expect(unknown('[[ -f app/globals.css ]] && echo yes')).toEqual([['[[', [F]]])
    expect(unknown('set -euo pipefail')).toEqual([['set', [`${CWD}/pipefail`]]])
    expect(unknown('basename app/globals.css .css')).toEqual([['basename', [F, `${CWD}/.css`]]])
    expect(unknown('exit 1')).toEqual([['exit', [`${CWD}/1`]]])
  })
  test('handed no word that spells a path, it is read as writing nothing, as before', () => {
    for (const command of [
      'prettier --check',
      'true',
      'wait',
      'set -e',
      // A path held in a variable the command never sets, a pattern, a command's output, standard
      // input and files handed over by xargs are not read (not measured before Dan decided).
      'prettier --write "$TARGET"',
      'prettier --write app/*.css',
      'prettier --write $(git ls-files app)',
      'prettier < app/globals.css',
      'ls app | xargs prettier --write',
    ])
      expect([command, unknown(command)]).toEqual([command, []])
  })
  test('each of the 32 programs Dan signed off as only reading writes nothing it is handed', () => {
    for (const name of SIGNED_OFF) {
      const close = name === '[' ? ' ]' : ''
      expect([name, read(`${name} app/globals.css${close}`)]).toEqual([name, { files: [], changes: [], unnamed: [] }])
      expect([name, read(`/usr/bin/${name} -n app/globals.css app/page.tsx${close}`)]).toEqual([name, { files: [], changes: [], unnamed: [] }])
    }
    // A redirect beside one is still the write it always was.
    expect(paths('grep -n color app/page.tsx > app/globals.css')).toEqual([F])
  })
  test('the list is exactly the 32 names, each with its reason', () => {
    expect(Object.keys(READ_ONLY).sort()).toEqual([...SIGNED_OFF].sort())
    expect(SIGNED_OFF.length).toBe(32)
    for (const [name, entry] of Object.entries(READ_ONLY)) expect([name, entry.why.trim().length >= 10]).toEqual([name, true])
  })
  test('the forms of a listed program that write a file or run a program are read as a writer', () => {
    const writer = (command: string) => (read(command).runs ?? []).filter(r => r.unknown).map(r => [r.what, r.args.map(a => a.path)])
    // Dan was told of these two.
    expect(writer('rg --pre ./pre.sh color app/globals.css')).toEqual([['rg with --pre, which runs a program on each file', [`${CWD}/pre.sh`, `${CWD}/color`, F]]])
    expect(writer('rg --pre=./pre.sh color app/globals.css').length).toBe(1)
    expect(writer('file -C -m app/globals.css')).toEqual([['file with -C, which compiles a magic file', [F]]])
    expect(writer('file --compile -m app/globals.css').length).toBe(1)
    expect(writer('file -bCm app/globals.css').length).toBe(1)
    // Found on this Mac on 2026-11-21 and not in what Dan was shown, so each is read the stricter way.
    expect(writer('rg --hostname-bin ./host.sh color app/globals.css')).toEqual([['rg with --hostname-bin, which runs a program', [`${CWD}/host.sh`, `${CWD}/color`, F]]])
    expect(writer('rg --hostname-bin=./host.sh color app/globals.css').length).toBe(1)
    expect(writer('mdls -plist app/globals.css app/page.tsx')).toEqual([['mdls with -plist, which writes the file it names', [F, `${CWD}/app/page.tsx`]]])
    expect(writer('mdls -p app/globals.css app/page.tsx').length).toBe(1)
    expect(writer('lsof -D u/app/globals.css app/page.tsx').length).toBe(1)
    expect(writer('lsof -D b app/globals.css')).toEqual([['lsof with -D, which builds or updates its device cache file', [`${CWD}/b`, F]]])
    // What a guard says of such a form: why, and that the plain form only reads.
    expect((read('rg --pre ./pre.sh color app/globals.css').runs ?? []).map(r => [r.script, r.why, r.remedy])).toEqual([['rg', 'rg with --pre runs a program on each file', 'Without --pre, rg only reads.']])
    // The plain forms beside them stay read as only reading.
    for (const command of ['rg --pretty color app/globals.css', 'rg -p color app/globals.css', 'file -b app/globals.css', 'mdls -name kMDItemKind app/globals.css', 'lsof +D app'])
      expect([command, read(command).runs]).toEqual([command, undefined])
  })
  // Each program below takes more spellings of its form than the one its row names. Measured on this
  // Mac on 2026-11-22 (file 5.41, mdls of macOS 26.6.2, lsof 4.91, ripgrep 14.1.1): what the program
  // itself takes as the form is read as the form, and so is a spelling it refuses (the side that holds).
  test('file: every start of --compile that file takes compiles a magic file, so each is read as the form', () => {
    const writer = (command: string) => (read(command).runs ?? []).filter(r => r.unknown).map(r => [r.what, r.args.map(a => a.path)])
    const whole = writer('file --compile -m app/page.tsx')
    expect(whole).toEqual([['file with -C, which compiles a magic file', [`${CWD}/app/page.tsx`]]])
    // --co and every longer start compile one. --c is refused by file as ambiguous (--checking-printout
    // starts the same) and compiles nothing; it is read as the form too.
    for (const start of ['--c', '--co', '--com', '--comp', '--compi', '--compil', '--compile'])
      expect([start, writer(`file ${start} -m app/page.tsx`)]).toEqual([start, whole])
    expect(writer('/usr/bin/file --comp --magic-file app/page.tsx').length).toBe(1)
    // The forms that compile nothing stay read as only reading: a long option starting with another
    // letter, --checking-printout and its starts, a magic file that is used and not compiled, and the
    // two dashes that end the options.
    for (const command of [
      'file notes.txt',
      'file -b notes.txt',
      'file --mime-type notes.txt',
      'file --brief notes.txt',
      'file -m magic notes.txt',
      'file --magic-file magic notes.txt',
      'file --checking-printout -m magic notes.txt',
      'file --ch -m magic notes.txt',
      'file -- notes.txt',
    ])
      expect([command, read(command).runs]).toEqual([command, undefined])
  })
  test('mdls: -plist in every spelling mdls takes writes the file it names, so each is read as the form', () => {
    const writer = (command: string) => (read(command).runs ?? []).filter(r => r.unknown).map(r => [r.what, r.args.map(a => a.path)])
    const whole = writer('mdls -plist app/globals.css app/page.tsx')
    expect(whole).toEqual([['mdls with -plist, which writes the file it names', [F, `${CWD}/app/page.tsx`]]])
    // mdls takes any start of plist, after one dash or two.
    for (const form of ['-p', '-pl', '-pli', '-plis', '-plist', '--p', '--pl', '--pli', '--plis', '--plist'])
      expect([form, writer(`mdls ${form} app/globals.css app/page.tsx`)]).toEqual([form, whole])
    // And the file joined to it with =, which is then the file written.
    for (const form of ['-plist', '-p', '-pl', '--plist', '--p'])
      expect([form, writer(`mdls ${form}=app/globals.css app/page.tsx`)]).toEqual([form, whole])
    for (const command of [
      'mdls app/globals.css',
      'mdls -name kMDItemKind app/globals.css',
      'mdls -n kMDItemKind app/globals.css',
      'mdls -raw -name kMDItemKind app/globals.css',
      'mdls -r -nullMarker none -name kMDItemKind app/globals.css',
      'mdls -name=kMDItemKind app/globals.css',
    ])
      expect([command, read(command).runs]).toEqual([command, undefined])
  })
  test('lsof: -D inside a cluster of short options is -D, so it is read as the form', () => {
    const writer = (command: string) => (read(command).runs ?? []).filter(r => r.unknown).map(r => [r.what, r.args.map(a => a.path)])
    const D = 'lsof with -D, which builds or updates its device cache file'
    // lsof 4.91 answers each of these four with "unsupported option: -D" (it is built without the
    // device cache here), so it reads the D of a cluster as the option.
    expect(writer('lsof -D b app/globals.css')).toEqual([[D, [`${CWD}/b`, F]]])
    expect(writer('lsof -Db app/globals.css')).toEqual([[D, [F]]])
    expect(writer('lsof -nD b app/globals.css')).toEqual([[D, [`${CWD}/b`, F]]])
    expect(writer('lsof -nDb app/globals.css')).toEqual([[D, [F]]])
    // A D inside the value of an option written against its letter (-cDock, the command Dock) is read
    // as the form too, the side that holds, as file -mC is.
    expect(writer('lsof -cDock app/globals.css')).toEqual([[D, [F]]])
    for (const command of ['lsof app/globals.css', 'lsof -n -P app/globals.css', 'lsof -nP -p 1 app/globals.css', 'lsof -c Dock app/globals.css', 'lsof -a +D app -c Dock', 'lsof +D app'])
      expect([command, read(command).runs]).toEqual([command, undefined])
  })
  test('rg: its two forms are read as rg takes them, whole or joined with =, and no shorter', () => {
    const writer = (command: string) => (read(command).runs ?? []).filter(r => r.unknown).map(r => r.what)
    // ripgrep 14.1.1 refuses a shortened long option (--pr, --hostname-b: "unrecognized flag") and
    // runs nothing, so only the whole name is the form. --pre-glob is another option and runs nothing.
    expect(writer('rg --pre ./pre.sh color app/globals.css')).toEqual(['rg with --pre, which runs a program on each file'])
    expect(writer('rg --pre=./pre.sh color app/globals.css')).toEqual(['rg with --pre, which runs a program on each file'])
    expect(writer('rg --hostname-bin=./host.sh color app/globals.css')).toEqual(['rg with --hostname-bin, which runs a program'])
    for (const command of ["rg --pre-glob '*.css' color app/globals.css", 'rg --pretty color app/globals.css'])
      expect([command, read(command).runs]).toEqual([command, undefined])
  })
  test('a program the reader reads by a rule of its own is not unknown', () => {
    for (const command of [
      "sed -n '1,5p' app/globals.css",
      'sort app/globals.css',
      'git diff -- app/globals.css',
      'gzip -c app/globals.css',
      "printf '%s\\n' app/globals.css",
      'find app -name globals.css',
      'cd app',
      'export F=app/globals.css',
      "python3 -c 'print(1)' app/globals.css",
      'source app/globals.css',
      // npx's own command line is not read, as before (#1682).
      "npx -c 'prettier --write app/page.tsx'",
    ])
      expect([command, unknown(command)]).toEqual([command, []])
    // A script file, a module and a tool run through npx stay the runs they were, never marked unknown.
    expect((read('./tool.sh app/globals.css').runs ?? []).map(r => [r.what, r.unknown])).toEqual([['a script file run directly', undefined]])
    expect((read('python3 gen.py app/globals.css').runs ?? []).map(r => [r.what, r.unknown])).toEqual([['a python3 script file', undefined]])
    expect((read('npx prettier --write app/globals.css').runs ?? []).map(r => [r.what, r.unknown])).toEqual([['a tool run through npx', undefined]])
    // A command whose effect cannot be read is already given as unread, which every guard holds.
    expect(unknown('"$TOOL" app/globals.css')).toEqual([])
    expect((read('"$TOOL" app/globals.css').unread ?? []).length).toBe(1)
  })
})

// claude-config#3323, Dan's third decision of 2026-11-21: "Yes, in the same change (Recommended)".
describe('writes: unpacking an archive is a write into the folder it unpacks into (#3323)', () => {
  const APP = `${CWD}/app`
  const unpack = (command: string, cwd = CWD) => read(command, cwd).unnamed.map(u => [u.what, u.inputs, u.into, u.folder])
  test('tar -x in each of its spellings is a write the words do not name, into the folder it unpacks into', () => {
    for (const command of [
      'tar -xzf a.tgz -C app',
      'tar -x -z -f a.tgz -C app',
      'tar xzf a.tgz -C app',
      'tar xzfC a.tgz app',
      'tar -xzC app -f a.tgz',
      'tar -xzfa.tgz -C app',
      'tar --extract --file a.tgz --directory app',
      'tar --extract --file=a.tgz --directory=app',
      'tar --get -f a.tgz --cd app',
      'bsdtar -xf a.tgz -C app',
      'gtar -xf a.tgz -C app',
      'cd app && tar -xzf ../a.tgz',
    ])
      expect([command, unpack(command)]).toEqual([command, [['an archive tar unpacks', [], APP, APP]]])
    // With no folder named it unpacks where it runs.
    expect(unpack('tar -xzf a.tgz')).toEqual([['an archive tar unpacks', [], CWD, CWD]])
    // The archive is never a file to read to find out: it is not text. On standard input too.
    expect(unpack('curl -sL https://example.com/a.tgz | tar -xz -C app')).toEqual([['an archive tar unpacks', [], APP, APP]])
    expect(unpack('tar -xzf - -C app < a.tgz')).toEqual([['an archive tar unpacks', [], APP, APP]])
  })
  test('a folder the reader cannot work out takes the cautious reading: no folder is given', () => {
    expect(unpack('tar -xzf a.tgz -C "$DEST"')).toEqual([['an archive tar unpacks', [], undefined, undefined]])
    expect(unpack('cd "$DEST" && tar -xzf /tmp/a.tgz')).toEqual([['an archive tar unpacks', [], undefined, undefined]])
    // Two folders, each read from the one before, are followed.
    expect(unpack('tar -xzf a.tgz -C app -C sub')).toEqual([['an archive tar unpacks', [], `${APP}/sub`, `${APP}/sub`]])
  })
  test('a member named on the command line is a write of that file, where it lands', () => {
    expect(paths('tar -xzf a.tgz -C app globals.css sub/page.tsx')).toEqual([`${APP}/globals.css`, `${APP}/sub/page.tsx`])
    expect(paths('tar xzf a.tgz app/globals.css')).toEqual([`${APP}/globals.css`])
    expect(paths('unzip -o a.zip app/globals.css -d /tmp/out')).toEqual(['/tmp/out/app/globals.css'])
    expect(paths('cpio -id app/globals.css < a.cpio')).toEqual([`${APP}/globals.css`])
    // A member matched by a pattern is a write the reader places in its folder, as any pattern is.
    expect(read("tar -xzf a.tgz -C app '*.css'").files.map(f => [f.path, f.folder])).toEqual([[undefined, APP]])
    // Under a folder that cannot be worked out it is named as written, with no path.
    expect(read('tar -xzf a.tgz -C "$DEST" app/globals.css').files.map(f => [f.word, f.path])).toEqual([['$DEST/app/globals.css', undefined]])
    // A value an option takes is no member.
    expect(paths('tar -xzf a.tgz --strip-components 1 --exclude node_modules -C app')).toEqual([])
  })
  test('unzip is a write into the folder -d names, or where it runs', () => {
    expect(unpack('unzip a.zip -d app')).toEqual([['an archive unzip unpacks', [], APP, APP]])
    expect(unpack('unzip -oq a.zip -dapp')).toEqual([['an archive unzip unpacks', [], APP, APP]])
    expect(unpack('unzip -o a.zip')).toEqual([['an archive unzip unpacks', [], CWD, CWD]])
    expect(unpack('unzip a.zip -d "$DEST"')).toEqual([['an archive unzip unpacks', [], undefined, undefined]])
    // A name after -x is left out of what it unpacks, so it is no write.
    expect(paths('unzip a.zip app/globals.css -x app/page.tsx -d /tmp/out')).toEqual(['/tmp/out/app/globals.css'])
  })
  test('cpio -i is a write into the folder it runs in', () => {
    expect(unpack('cpio -idmv < a.cpio')).toEqual([['an archive cpio unpacks', [], CWD, CWD]])
    expect(unpack('cpio -i -I a.cpio')).toEqual([['an archive cpio unpacks', [], CWD, CWD]])
    expect(unpack('cpio --extract -F a.cpio')).toEqual([['an archive cpio unpacks', [], CWD, CWD]])
    expect(unpack('cd app && cpio -id < ../a.cpio')).toEqual([['an archive cpio unpacks', [], APP, APP]])
  })
  test('a form that unpacks nothing is no unpack, and is read as any program not on the list is', () => {
    for (const command of ['tar -tzf a.tgz', 'tar -czf a.tgz app', 'unzip -l a.zip', 'unzip -t a.zip', 'unzip -p a.zip app/globals.css', 'unzip -Z a.zip', 'cpio -o', 'cpio -it < a.cpio', 'find app | cpio -pdm out']) {
      const out = read(command)
      expect([command, out.unnamed, out.files]).toEqual([command, [], []])
    }
    // Each is a program on no list, so what it is handed is read as a write of it.
    expect((read('tar -czf a.tgz app').runs ?? []).map(r => [r.script, r.unknown, r.args.map(a => a.path)])).toEqual([['tar', true, [`${CWD}/a.tgz`, APP]]])
    expect((read('find app | cpio -pdm out').runs ?? []).map(r => [r.script, r.unknown, r.args.map(a => a.path)])).toEqual([['cpio', true, [`${CWD}/out`]]])
  })
})

// claude-config#3415: the `>` of an arithmetic test was read as a redirect, so `(( n > 3 ))` was a
// write of a file named 3, every guard built on this reader judged a write that never happens, and
// winding down could list `3` as the session's work. What stands inside `(( ))` was read as a
// command too, so since #3323 `(( n >= 3 ))` ran a program named n that was handed the file 3. The
// `>` of a `[[ ]]` test, which compares two strings, was read the same way. Measured 2026-11-21 on
// this Mac's bash 3.2, zsh 5.9 and ksh, each case run in an empty folder and the folder listed:
// none writes a file for any form below, and each writes the one a redirect after the test names.
// dash does write the file (there `((` opens two subshells and `[[` is a program's name), and sh
// is dash on other machines, so what a `sh -c` or a `dash -c` runs is read as it was before.
describe('writes: an arithmetic test and a [[ ]] comparison redirect nothing (#3415)', () => {
  // What a command is read as doing, kept small so a failure names the command and the misreading.
  const done = (command: string) => {
    const out = read(command)
    return [
      command,
      out.files.map(f => f.path ?? `(as written) ${f.word}`),
      out.unnamed.map(u => u.what),
      (out.runs ?? []).map(r => `${r.script} ${r.args.map(a => a.word).join(' ')}`),
      (out.unread ?? []).map(u => u.why),
    ]
  }
  const nothing = (command: string) => [command, [], [], [], []]
  // Each command that is read as doing anything at all.
  const misread = (commands: string[]) => commands.map(done).filter(d => JSON.stringify(d) !== JSON.stringify(nothing(d[0] as string)))
  test('an arithmetic test writes no file', () => {
    expect(misread(['(( n > 3 ))', '((n>3))', '(( n >> 3 ))', 'if (( n > 3 )); then echo big; fi', 'bash -c "(( n > 3 ))"', 'zsh -c "(( n > 3 ))"', 'ksh -c "(( n > 3 ))"'])).toEqual([])
  })
  test('what stands inside it runs no program and reads no file', () => {
    // `sh` is a variable's name here, as any word inside `(( ))` is.
    expect(misread(['(( a < b ))', '(( sh < b ))', '(( n >= 3 ))', '(( a <= b ))', '(( x = n > 3 ))', '(( n > 3 ? a : b ))', 'while (( i < 3 )); do (( i++ )); done'])).toEqual([])
  })
  test('the three parts of an arithmetic for are no commands', () => {
    expect(misread(['for (( i = 0; i < 3; i++ )); do echo $i; done', 'for ((i=0; i<3; i++)); do echo $i; done'])).toEqual([])
  })
  test('arithmetic holding parentheses of its own is arithmetic, where its two ) close it together', () => {
    expect(misread(['(( (n + 1) > 3 ))', '(( n > (3) ))', '(( (a > b) && c ))', 'if (( (n + 1) * 2 > 3 )); then echo big; fi'])).toEqual([])
  })
  test('an arithmetic expansion in a word writes nothing', () => {
    expect(misread(['echo $(( x > 1 ))', 'n=$(( x > 1 ))', 'echo "$(( x > 1 ? 2 : 3 ))"'])).toEqual([])
  })
  test('a real redirect beside an arithmetic test is still a write, and a substitution inside one still runs', () => {
    expect(paths('(( n > 3 )) > out.txt')).toEqual([`${CWD}/out.txt`])
    expect(paths('(( n > 3 )) && echo x > y.txt')).toEqual([`${CWD}/y.txt`])
    expect(paths('(( a > b )) 2> err.txt')).toEqual([`${CWD}/err.txt`])
    expect(paths('if (( n > 3 )); then echo x > big.txt; fi')).toEqual([`${CWD}/big.txt`])
    expect(paths('for (( i = 0; i < 3; i++ )); do echo x >> log.txt; done')).toEqual([`${CWD}/log.txt`])
    expect(paths('(( n > $(echo 3 > side.txt; echo 3) ))')).toEqual([`${CWD}/side.txt`])
  })
  test('two subshells are no arithmetic, and neither is anything sh or dash runs', () => {
    // Each measured as writing the file, in every shell for the first four.
    expect(paths('((echo a) > f.txt)')).toEqual([`${CWD}/f.txt`])
    expect(paths('( (echo a) > f.txt )')).toEqual([`${CWD}/f.txt`])
    expect(paths('((echo a); (echo b) > g.txt)')).toEqual([`${CWD}/g.txt`])
    expect(paths('let n>3')).toEqual([`${CWD}/3`])
    expect(paths('dash -c "(( n > 3 ))"')).toEqual([`${CWD}/3`])
    expect(paths('sh -c "(( n > 3 ))"')).toEqual([`${CWD}/3`])
    expect(paths('dash -c "((echo a > f.txt))"')).toEqual([`${CWD}/f.txt`])
  })
  test('a name arithmetic gives a value is no longer read as its old one', () => {
    // Measured: out3, then out2, out2 and out5 where the reader gave out1 for the last three. The
    // two ( and the two ) open and close no subshell, so the value stands after them.
    expect(paths('((F=3)); echo x > out$F')).toEqual([`${CWD}/out3`])
    expect(paths('F=1; ((F=F+1)); echo x > out$F')).toEqual(['(as written) out$F'])
    expect(paths('for ((i=0; i<3; i++)); do echo x > f$i; done')).toEqual(['(as written) f$i'])
    expect(paths('F=1; (( F = 2 )); echo x > out$F')).toEqual(['(as written) out$F'])
    expect(paths('F=1; (( F++ )); echo x > out$F')).toEqual(['(as written) out$F'])
    expect(paths('F=1; (( F += 4 )); echo x > out$F')).toEqual(['(as written) out$F'])
    expect(paths('F=1; (( ++F )); echo x > out$F')).toEqual(['(as written) out$F'])
    // One it only reads keeps its value.
    expect(paths('F=1; (( F >= 0 )) && echo x > out$F')).toEqual([`${CWD}/out1`])
    expect(paths('F=1; (( n == F )) && echo x > out$F')).toEqual([`${CWD}/out1`])
  })
  // The issue's first open question: `[[ a > b ]]` had the same misreading, as a write of b.
  test('a < or > inside [[ ]] compares two strings and names no file', () => {
    for (const command of ['[[ a > b ]]', '[[ a>b ]]', '[[ $x > 3 ]] && echo y', '! [[ a > b ]]', 'if [[ a > b ]]; then echo x; fi', '[[ a > b && c > d ]]', '[[ ( a > b ) ]]', '[[ a < b ]]', 'bash -c "[[ a > b ]]"']) {
      expect([command, paths(command)]).toEqual([command, []])
    }
  })
  test('a real redirect after the test is still a write, and a substitution inside one still runs', () => {
    expect(paths('[[ a > b ]] > out.txt')).toEqual([`${CWD}/out.txt`])
    expect(paths('[[ a > b ]]>out2')).toContain(`${CWD}/out2`)
    expect(paths('[[ a > b ]] 2> err.txt')).toEqual([`${CWD}/err.txt`])
    expect(paths('[[ a > "]]" ]] > c')).toEqual([`${CWD}/c`])
    expect(paths('if [[ a > b ]]; then echo x > out.txt; fi')).toEqual([`${CWD}/out.txt`])
    expect(paths('[[ a > $(echo z > side.txt; echo z) ]]')).toEqual([`${CWD}/side.txt`])
  })
  test('where [[ is no test of the shell, its > is the redirect it always was', () => {
    // Each measured as writing b in bash: a quoted `[[`, one after a setting, a test never closed
    // (read as before, #3021), `[` and `test`, which are programs, and what sh or dash runs.
    for (const command of ["'[[' a > b ]]", '\\[[ a > b ]]', 'X=1 [[ a > b ]]', '[[ a > b', '[ a > b ]', 'test a > b', 'dash -c "[[ a > b ]]"', 'sh -c "[[ a > b ]]"']) {
      expect([command, paths(command)]).toEqual([command, [`${CWD}/b`]])
    }
  })
  test('[[ is still a program the reader does not know, handed each word of its test (#3323)', () => {
    const handed = (command: string) => (read(command).runs ?? []).filter(r => r.unknown).map(r => [r.script, r.args.map(a => a.word)])
    expect(handed('[[ a == b ]]')).toEqual([['[[', ['a', '==', 'b']]])
    expect(handed('[[ a > b ]]')).toEqual([['[[', ['a', '>', 'b']]])
    expect(handed('[[ a < b ]]')).toEqual([['[[', ['a', '<', 'b']]])
    expect(handed('[[ a<b ]]')).toEqual([['[[', ['a', '<', 'b']]])
    expect(handed('[[ app/globals.css > CLAUDE.md ]]')).toEqual([['[[', ['app/globals.css', '>', 'CLAUDE.md']]])
  })
  test('the reader marks what it took for arithmetic and for a comparison', () => {
    // The four parentheses too, which open and close no subshell.
    expect(pipeline('(( n > 3 )) && echo x').map(c => [c.words.join(' '), c.arithmetic])).toEqual([['(', true], ['(', true], ['n > 3', true], [')', true], [')', true], ['echo x', undefined]])
    expect(pipeline('((echo a) > f.txt)').map(c => c.arithmetic)).toEqual([undefined, undefined, undefined, undefined, undefined, undefined])
    expect(pipeline('dash -c "(( n > 3 ))"').map(c => c.arithmetic)).toEqual([undefined, undefined, undefined, undefined, undefined])
    expect(pipeline('[[ a > b ]] > out.txt').map(c => c.compares)).toEqual([[false, false, true, false, false, false, false]])
    expect(pipeline('[[ a == b ]] > out.txt').map(c => c.compares)).toEqual([undefined])
    expect(pipeline('dash -c "[[ a > b ]]"').map(c => c.compares)).toEqual([undefined])
  })
})
