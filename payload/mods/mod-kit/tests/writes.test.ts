import { describe, expect, test } from 'claude-code/testing'
import { commandWrites } from '../hooks/writes.ts'

// The one reader of which files a Bash call writes (#705, L613): ask before saving kept its own and
// missed inline scripts, rsync, install, ln, dd, a patch, every file but the last of a sed -i, and a
// cd before a relative path, each of which another mod's copy caught.
const HOME = '/Users/dan'
const CWD = '/Users/dan/Apps/slate'
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
})

describe('writes: copying, moving and linking', () => {
  test("cp, mv, ln, install and ditto write their destination", () => {
    expect(paths('cp rules.md CLAUDE.md')).toEqual([`${CWD}/CLAUDE.md`])
    expect(paths('mv -f draft.md ../AGENTS.md')).toEqual([`/Users/dan/Apps/AGENTS.md`])
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
  test('rsync writes its local destination, and a remote one is no file here', () => {
    expect(paths('rsync -av --exclude .git notes.md ~/.claude/CLAUDE.md')).toEqual([`${HOME}/.claude/CLAUDE.md`])
    expect(paths('rsync -av CLAUDE.md host:backup/')).toEqual([])
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

describe('writes: what the words do not name', () => {
  test('a patch applied names the patch files to read, resolved in the folder git is pointed at', () => {
    expect(read('patch -p1 < fix.diff').unnamed).toEqual([{ what: 'a patch', words: ['patch', '-p1', '<', 'fix.diff'], inputs: [`${CWD}/fix.diff`] }])
    expect(read('git -C /repo apply fix.patch').unnamed).toEqual([{ what: 'a patch', words: ['git', '-C', '/repo', 'apply', 'fix.patch'], inputs: ['/repo/fix.patch'] }])
  })
  test('a patch only checked writes nothing', () => {
    expect(read('git apply --check fix.patch').unnamed).toEqual([])
    expect(read('git apply --stat fix.patch').unnamed).toEqual([])
  })
  test('patch with a file to patch names that file as written', () => {
    expect(paths('patch CLAUDE.md fix.diff')).toEqual([`${CWD}/CLAUDE.md`])
  })
  test('an inline script that writes a file is a write the words do not name', () => {
    expect(read(`python3 -c "open('/Users/dan/.claude/CLAUDE.md', 'a').write('rule')"`).unnamed).toEqual([
      { what: 'an inline python3 script', words: ['python3', '-c', "open('/Users/dan/.claude/CLAUDE.md', 'a').write('rule')"], inputs: [] },
    ])
    expect(read(`node -e "require('fs').appendFileSync('AGENTS.md', 'x')"`).unnamed.map(u => u.what)).toEqual(['an inline node script'])
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
      changes: [{ word: 'src', path: `${CWD}/src`, does: 'remove', tree: true }],
      unnamed: [],
    })
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
  test('find -delete removes what it finds under each folder it starts from, and -fprint writes a file', () => {
    expect(changes(`find build -name '*.o' -delete`)).toEqual([`remove ${CWD}/build tree`])
    expect(changes('find -delete')).toEqual([`remove ${CWD} tree`])
    expect(paths('find src -fprint list.txt')).toEqual([`${CWD}/list.txt`])
    // What -exec runs is read as a command of its own, the folder standing for {}.
    expect(changes(`find src -name '*.bak' -exec rm {} \\;`)).toEqual([`remove ${CWD}/src`])
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
    expect(read(`cat notes.txt | grep x; sed -n '1,5p' notes.txt; ls -la; git diff; perl -ne 'print' notes.txt; wc < notes.txt; perl -Ilib script.pl x.txt`)).toEqual({ files: [], changes: [], unnamed: [] })
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
  test('a variable the reader cannot be sure of is given as written', () => {
    // Set from a command's output, by a loop, by read, by eval, or unset.
    expect(paths('F=$(mktemp); echo x > "$F"')).toEqual(['(as written) $F'])
    expect(paths('for F in a.md b.md; do echo x >> "$F"; done')).toEqual(['(as written) $F'])
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
  test('a value set inside a subshell ends with it', () => {
    expect(paths('F=a.md; (G=b.md; echo x > "$G"); echo y > "$F"; echo z > "$G"')).toEqual([`${CWD}/b.md`, `${CWD}/a.md`, '(as written) $G'])
  })
})
