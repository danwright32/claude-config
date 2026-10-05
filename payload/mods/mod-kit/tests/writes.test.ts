import { describe, expect, test } from 'claude-code/testing'
import { commands } from '../hooks/commands.ts'
import { writes } from '../hooks/writes.ts'

// The one reader of which files a Bash call writes (#705, L613): ask before saving kept its own and
// missed inline scripts, rsync, install, ln, dd, a patch, every file but the last of a sed -i, and a
// cd before a relative path, each of which another mod's copy caught.
const HOME = '/Users/dan'
const CWD = '/Users/dan/Apps/slate'
const read = (command: string, cwd = CWD) => writes(commands(command), cwd, HOME)
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
    expect(read('cp rules.md CLAUDE.md').files).toEqual([{ word: 'CLAUDE.md', path: `${CWD}/CLAUDE.md`, sources: [`${CWD}/rules.md`] }])
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
    expect(read('wget -i urls.txt')).toEqual({ files: [], unnamed: [{ what: 'a wget download of the addresses in a file', words: ['wget', '-i', 'urls.txt'], inputs: [`${CWD}/urls.txt`] }] })
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
  test('a script fed on standard input cannot be read from its words, so it is named as such', () => {
    expect(read("python3 - <<'EOF'\nopen('CLAUDE.md','a').write('x')\nEOF").unnamed.map(u => u.what)).toEqual(['a python3 script on standard input'])
    expect(read("bash <<'EOF'\ncat >> CLAUDE.md < rules.md\nEOF").unnamed.map(u => u.what)).toEqual(['a bash script on standard input'])
    expect(read('sh < setup.sh').unnamed).toEqual([{ what: 'a sh script on standard input', words: ['sh', '<', 'setup.sh'], inputs: [`${CWD}/setup.sh`] }])
  })
  // #698: the delimiter of a spaced heredoc was taken for a script file, and the shells beyond sh,
  // bash and zsh were not shells here.
  test('a spaced heredoc feeds a shell too, and dash and ksh are shells', () => {
    expect(read("bash << 'EOF'\ncat >> CLAUDE.md < rules.md\nEOF").unnamed.map(u => u.what)).toEqual(['a bash script on standard input'])
    expect(read("dash <<'EOF'\nls\nEOF").unnamed.map(u => u.what)).toEqual(['a dash script on standard input'])
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
    expect(read('ls -la && git status')).toEqual({ files: [], unnamed: [] })
  })
})
