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
  })
  test('a command that writes nothing names nothing', () => {
    expect(read('ls -la && git status')).toEqual({ files: [], unnamed: [] })
  })
})
