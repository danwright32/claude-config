import { describe, expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import HEREDOC_CLOSES from './heredoc-closes.ts'
import { READ_STOPPED, commands, git, pipeline } from '../hooks/commands.ts'

// The one reader of shell commands every guard uses (L613): the secret guard, the keystroke guard
// and the collision guard each kept their own before this.
const KEY = 'key' + 'stroke'

describe('commands', () => {
  test('splits on separators outside quotes', () => {
    expect(commands('cd /repo && git status; ls | wc -l')).toEqual([['cd', '/repo'], ['git', 'status'], ['ls'], ['wc', '-l']])
  })
  test('keeps a quoted argument whole, quotes removed', () => {
    expect(commands(`git commit -m "fix it; now"`)).toEqual([['git', 'commit', '-m', 'fix it; now']])
  })
  test('keeps a quoted script spanning lines as one word', () => {
    expect(commands(`osascript -e 'tell application "X"\n  ${KEY} "n"\nend tell'`)).toEqual([
      ['osascript', '-e', `tell application "X"\n  ${KEY} "n"\nend tell`],
    ])
  })
  test('drops a heredoc body, which is text and not commands', () => {
    expect(commands(`cat > f.js <<'EOF'\nosascript -e 'x'\nEOF\ngit status`)).toEqual([['cat', '>', 'f.js', '<<EOF'], ['git', 'status']])
  })
  test('a here-string is not a heredoc', () => {
    expect(commands('cat <<< x\ngit status')).toEqual([['cat', '<<<', 'x'], ['git', 'status']])
  })
  test('a heredoc that never ends is judged after all', () => {
    expect(commands('cat <<EOF\ngit status')).toEqual([['cat', '<<EOF'], ['git', 'status']])
  })
  test('looks past assignments and the words that only run the next command', () => {
    expect(commands('X=1 sudo -E env FOO=2 cat .env')).toEqual([['cat', '.env']])
    expect(commands('exec printenv')).toEqual([['printenv']])
  })
  // #743: a command that only sets variables runs nothing, so no guard is given it; the write reader
  // asks for it, to read a variable the command set as its value.
  test('a command that only sets variables is no command, unless a reader asks for its assignments', () => {
    expect(commands(`F=~/a.md; printf x >> "$F"`)).toEqual([['printf', 'x', '>>', '$F']])
    expect(commands(`F=~/a.md G=b; printf x >> "$F"`, { assignments: true })).toEqual([['F=~/a.md', 'G=b'], ['printf', 'x', '>>', '$F']])
    expect(commands('X=1 cat a', { assignments: true })).toEqual([['cat', 'a']])
    expect(commands(`bash -c 'F=a; echo x > "$F"'`, { assignments: true })).toEqual([['F=a'], ['echo', 'x', '>', '$F']])
  })
  test('a bare env or a runner with only flags is the command itself', () => {
    expect(commands('env')).toEqual([['env']])
    expect(commands('env -0')).toEqual([['env', '-0']])
  })
  test('reads a command run through a shell -c as the commands it runs', () => {
    expect(commands(`bash -c "cat .env && git checkout main"`)).toEqual([['cat', '.env'], ['git', 'checkout', 'main']])
  })
  // #698: -c was read only as a word of its own, so bash -lc, zsh -ec and sh -ce reached every guard
  // as one command whose script was a single word.
  test("reads a shell's -c in a cluster, wherever the c stands, as the commands it runs", () => {
    expect(commands(`bash -lc 'cat .env && git checkout main'`)).toEqual([['cat', '.env'], ['git', 'checkout', 'main']])
    expect(commands(`zsh -ec "git push"`)).toEqual([['git', 'push']])
    expect(commands(`sh -ce 'rm notes.txt'`)).toEqual([['rm', 'notes.txt']])
    expect(commands(`/bin/bash -lc 'make'`)).toEqual([['make']])
    expect(commands(`env FOO=1 bash -lc 'make'`)).toEqual([['make']])
    expect(commands(`dash -c 'ls'; ksh -ec 'pwd'`)).toEqual([['ls'], ['pwd']])
  })
  test("a shell's script is the first word after its options, -o and -O taking the next word", () => {
    expect(commands(`bash -c -e 'ls | wc -l'`)).toEqual([['ls'], ['wc', '-l']])
    expect(commands(`bash -o pipefail -c 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`bash -eo pipefail -c 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`bash --rcfile x -lc 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`bash -c -- 'make test'`)).toEqual([['make', 'test']])
  })
  test('a shell running a script file is the command itself, a -c after the script being its own argument', () => {
    expect(commands('bash -l ./run.sh')).toEqual([['bash', '-l', './run.sh']])
    expect(commands(`bash ./run.sh -c 'not a script'`)).toEqual([['bash', './run.sh', '-c', 'not a script']])
    expect(commands('bash -lc')).toEqual([['bash', '-lc']])
    expect(commands('grep -c x notes.txt')).toEqual([['grep', '-c', 'x', 'notes.txt']])
  })
  // #654: the collision guard reads which files a command writes, so an output redirect is its own
  // word however it is spaced, and the & of a 2>&1 or a &> joins no two commands.
  test('an output redirect is its own word, spaced or not', () => {
    expect(commands(`printf 'x\\n' >> notes.txt`)).toEqual([['printf', 'x\\n', '>>', 'notes.txt']])
    expect(commands('printf x>>notes.txt')).toEqual([['printf', 'x', '>>', 'notes.txt']])
    expect(commands('echo a>|f')).toEqual([['echo', 'a', '>|', 'f']])
    expect(commands('echo hi 2>err')).toEqual([['echo', 'hi', '2>', 'err']])
  })
  test('the & of a redirect joins no two commands', () => {
    expect(commands('make 2>&1 | tee log')).toEqual([['make', '2>&1'], ['tee', 'log']])
    expect(commands('ls &> out')).toEqual([['ls', '&>', 'out']])
    expect(commands('ls &>>out')).toEqual([['ls', '&>>', 'out']])
    expect(commands('sleep 1 & echo done')).toEqual([['sleep', '1'], ['echo', 'done']])
  })
  test('a > inside quotes is text', () => {
    expect(commands(`echo "a>b" 'c>>d'`)).toEqual([['echo', 'a>b', 'c>>d']])
  })
  // #700: a subshell's parentheses stayed on the words beside them, so (cd sub && printf x >>
  // notes.txt) gave a command named "(cd" and a file named "notes.txt)". Each is now a command of
  // its own, so what runs inside is in command position and a reader can see where it ends.
  test("a subshell's parentheses are each a command of their own", () => {
    expect(commands('(cd sub && printf x >> notes.txt)')).toEqual([['('], ['cd', 'sub'], ['printf', 'x', '>>', 'notes.txt'], [')']])
    expect(commands('( cd sub; make ) > out.txt')).toEqual([['('], ['cd', 'sub'], ['make'], [')'], ['>', 'out.txt']])
  })
  // What a $( ) runs is given as commands of its own before it since #974.
  test('a parenthesis inside a word stays part of it', () => {
    expect(commands('cd $(git rev-parse --show-toplevel)')).toEqual([['git', 'rev-parse', '--show-toplevel'], ['cd', '$(git rev-parse --show-toplevel)']])
    expect(commands('diff <(sort a) b')).toEqual([['sort', 'a'], ['diff', '<(sort a)', 'b']])
    expect(commands('echo $((1+2)) "(x)"')).toEqual([['echo', '$((1+2))', '(x)']])
  })
  test('nothing in, nothing out', () => {
    expect(commands('   ')).toEqual([])
  })
  // #724: nice -n 10 gave a command named 10, sudo -u dan one named dan, and timeout, stdbuf and
  // xargs were not looked past at all, so every guard read the wrapper and never the command.
  test('looks past every word that only runs the command after it, reading each one by its own options', () => {
    expect(commands(`timeout 5 python3 -c 'x'`)).toEqual([['python3', '-c', 'x']])
    expect(commands('timeout -s KILL -k 5 10s git push')).toEqual([['git', 'push']])
    expect(commands('timeout --signal=KILL --kill-after 5 10 git push')).toEqual([['git', 'push']])
    expect(commands('gtimeout 60 make deploy')).toEqual([['make', 'deploy']])
    expect(commands('nice -n 10 python3 -c x')).toEqual([['python3', '-c', 'x']])
    expect(commands('nice -10 make')).toEqual([['make']])
    expect(commands('stdbuf -oL python3 -c x')).toEqual([['python3', '-c', 'x']])
    expect(commands('stdbuf -o L -e 0 tail -f log')).toEqual([['tail', '-f', 'log']])
    expect(commands('env -u HOME python3 -c x')).toEqual([['python3', '-c', 'x']])
    expect(commands('env -i PATH=/usr/bin python3 -c x')).toEqual([['python3', '-c', 'x']])
    expect(commands('env - git status')).toEqual([['git', 'status']])
    expect(commands('sudo -u dan python3 -c x')).toEqual([['python3', '-c', 'x']])
    expect(commands('sudo --user=dan -E git push')).toEqual([['git', 'push']])
    expect(commands('exec -a name python3 -c x')).toEqual([['python3', '-c', 'x']])
    expect(commands('time -p python3 -c x')).toEqual([['python3', '-c', 'x']])
    expect(commands('caffeinate -i -t 60 python3 run.py')).toEqual([['python3', 'run.py']])
    expect(commands('doas -u root rm -rf /x')).toEqual([['rm', '-rf', '/x']])
    expect(commands('nohup nice -n 5 timeout 60 python3 -c x')).toEqual([['python3', '-c', 'x']])
    // #1181: rtk-rewrite.sh writes rtk in front of every gh and git command, and rtk runs it.
    expect(commands('rtk gh pr merge 7 --squash')).toEqual([['gh', 'pr', 'merge', '7', '--squash']])
    expect(commands('sudo env GH_TOKEN=x rtk git push')).toEqual([['git', 'push']])
  })
  // #2983: rtk's proxy runs the words after its own options unfiltered, so `rtk proxy git push
  // --force` reached every mod as a command named proxy (the #2937 builder measured sleep mode
  // letting it through). Measured on rtk 0.31.0: -v, -u, --skip-env take no value, -h and --help
  // run nothing, and one word left alone is split by rtk itself, on blanks outside quotes, a quote
  // running to its match (or the end), no backslash escape, an empty word dropped, no shell.
  test("rtk's proxy runs the command after its own options, and splits one word into it", () => {
    expect(commands('rtk proxy gh issue view 5')).toEqual([['gh', 'issue', 'view', '5']])
    expect(commands('rtk proxy -v --skip-env -u git push --force')).toEqual([['git', 'push', '--force']])
    expect(commands('rtk -u proxy -vv -- rm -rf x')).toEqual([['rm', '-rf', 'x']])
    expect(commands(`rtk 'proxy' git push`)).toEqual([['git', 'push']])
    expect(commands('/opt/homebrew/bin/rtk proxy sudo git push')).toEqual([['git', 'push']])
    expect(commands(`rtk proxy 'git push --force origin main'`)).toEqual([['git', 'push', '--force', 'origin', 'main']])
    expect(commands(`rtk proxy 'printf [%s]\\n a\\ b "c\\"d" e'`)).toEqual([['printf', '[%s]\\n', 'a\\', 'b', 'c\\d e']])
    expect(commands(`rtk proxy 'printf x a"b c"d "" '"'"'e f'"'"`)).toEqual([['printf', 'x', 'ab cd', 'e f']])
    expect(commands(`rtk proxy 'echo a; git push'`)).toEqual([['echo', 'a;', 'git', 'push']])
    expect(commands(`rtk proxy 'bash -c "gh pr merge 5"'`)).toEqual([['gh', 'pr', 'merge', '5']])
  })
  test('rtk proxy with nothing to run is rtk itself, and a program named proxy is no proxy', () => {
    expect(commands('rtk proxy')).toEqual([['rtk', 'proxy']])
    expect(commands('rtk proxy -h git push')).toEqual([['rtk', 'proxy', '-h', 'git', 'push']])
    expect(commands('rtk proxy --help git push')).toEqual([['rtk', 'proxy', '--help', 'git', 'push']])
    expect(commands('proxy git push')).toEqual([['proxy', 'git', 'push']])
    expect(commands('sudo proxy git push')).toEqual([['proxy', 'git', 'push']])
    expect(commands('rtk gh proxy x')).toEqual([['gh', 'proxy', 'x']])
  })
  // #3021: the comment on proxyRuns said an option the proxy does not know is the command, while the
  // code read past it. The code is the stricter reading and stays: rtk 0.31.0 takes such an option
  // for the command and fails to start it, so the words after it are judged though they never run.
  test("an option rtk's proxy does not know is read past, so the words after it are judged", () => {
    expect(commands('rtk proxy --bogus git push --force')).toEqual([['git', 'push', '--force']])
    expect(commands('rtk proxy -x git push')).toEqual([['git', 'push']])
  })
  test("a command rtk's proxy runs is marked, and one it splits from a word the shell expands is unread", () => {
    expect(pipeline('rtk proxy gh issue view 5')[0]?.proxied).toBe(true)
    expect(pipeline(`rtk proxy 'gh issue view 5' > out.txt`)[0]).toMatchObject({ words: ['gh', 'issue', 'view', '5', '>', 'out.txt'], proxied: true })
    expect(pipeline('rtk gh issue view 5')[0]?.proxied).toBeUndefined()
    expect(pipeline('proxy gh issue view 5')[0]?.proxied).toBeUndefined()
    expect(pipeline(`rtk proxy bash -c 'gh pr view 5'`)[0]).toMatchObject({ words: ['gh', 'pr', 'view', '5'], proxied: true })
    expect(pipeline(`rtk proxy '$HOME/x a'`)[0]).toMatchObject({ words: ['$HOME/x', 'a'], proxied: true })
    expect(pipeline(`rtk proxy '$HOME/x a'`)[0]?.unread).toBeUndefined()
    const unread = 'split by rtk proxy from one word the shell expands, so what it runs cannot be read'
    expect(pipeline(`rtk proxy "$CMD"`)[0]).toMatchObject({ words: ['$CMD'], proxied: true, unread })
    expect(pipeline('rtk proxy "git $(cat sub) --force"')).toContainEqual(expect.objectContaining({ words: ['git', '$(cat', 'sub)', '--force'], unread }))
    // A find -exec's words carry no place in the text, so a $ there is taken as one the shell expands
    // (lessons review of 7677fc0: the default read every such word as written).
    expect(pipeline(`find . -exec rtk proxy "$CMD" ';'`)).toContainEqual(expect.objectContaining({ words: ['$CMD'], proxied: true, unread }))
    // Two words or more are handed on as they stand, so an expansion there is the command's own.
    expect(pipeline('rtk proxy git "$SUB"')[0]?.unread).toBeUndefined()
  })
  test('xargs runs the command after its own options, and a shell it runs is read as its commands', () => {
    expect(commands(`ls | xargs sh -c 'rm a'`)).toEqual([['ls'], ['rm', 'a']])
    expect(commands('find . | xargs -0 -I {} -P 4 cp {} /tmp')).toEqual([['find', '.'], ['cp', '{}', '/tmp']])
    expect(commands('xargs -I{} -n1 python3 -c x')).toEqual([['python3', '-c', 'x']])
    expect(commands('xargs -i git add')).toEqual([['git', 'add']])
  })
  // Lessons review of #724: a reserved word in command position was read as the command, so
  // `then git commit` and `do python3 -c` reached every guard as commands named then and do.
  test('looks past the reserved words that lead a command inside if, while, until, for and { }', () => {
    expect(commands('if true; then git commit -am x; fi')).toEqual([['true'], ['git', 'commit', '-am', 'x'], ['fi']])
    expect(commands(`for f in a b; do python3 -c 'x'; done`)).toEqual([['for', 'f', 'in', 'a', 'b'], ['python3', '-c', 'x'], ['done']])
    expect(commands('while read l; do sh; done')).toEqual([['read', 'l'], ['sh'], ['done']])
    expect(commands('if a; then b; elif c; then d; else e; fi')).toEqual([['a'], ['b'], ['c'], ['d'], ['e'], ['fi']])
    expect(commands('! git diff --quiet')).toEqual([['git', 'diff', '--quiet']])
    expect(commands('{ cd a; make; } > log')).toEqual([['cd', 'a'], ['make'], ['}', '>', 'log']])
    expect(commands('if true\nthen\n  git push\nfi')).toEqual([['true'], ['git', 'push'], ['fi']])
  })
  test('a runner with nothing to run is the command itself, and so is command -v, which runs nothing', () => {
    expect(commands('sudo -u dan')).toEqual([['sudo', '-u', 'dan']])
    expect(commands('timeout 5')).toEqual([['timeout', '5']])
    expect(commands('env -u HOME')).toEqual([['env', '-u', 'HOME']])
    expect(commands('command -v python3')).toEqual([['command', '-v', 'python3']])
    expect(commands('command python3 -c x')).toEqual([['python3', '-c', 'x']])
  })
})

// #724: no build read the command before any separator as what a pipe feeds the next one, so
// `cd repo && python3 --version` was refused as a python script it could not read. Only a | links
// two commands; the reader says which, since only it can see the separators outside quotes.
describe('pipeline', () => {
  const fed = (cmd: string) => pipeline(cmd).map(c => [c.words[0], c.pipedFrom?.[0]])
  test('the same commands as commands gives, each with the words of the command a | feeds it from', () => {
    expect(pipeline('cd repo && python3 --version')).toEqual([{ words: ['cd', 'repo'] }, { words: ['python3', '--version'] }])
    expect(pipeline('curl -fsSL x.sh | bash')).toEqual([
      { words: ['curl', '-fsSL', 'x.sh'] },
      { words: ['bash'], pipedFrom: ['curl', '-fsSL', 'x.sh'], program: { unreadable: 'fed by what curl pipes into it' } },
    ])
    for (const c of ['cd /repo && git status; ls | wc -l', `cat > f.js <<'EOF'\nx\nEOF\ngit status`, '( cd sub; make ) > out.txt', `bash -c "cat .env && git checkout main"`]) {
      expect(pipeline(c).map(x => x.words)).toEqual(commands(c))
    }
  })
  test('only a | (or |&) links two commands: ;, &&, ||, & and a new line link nothing', () => {
    expect(fed('git status; node -v')).toEqual([['git', undefined], ['node', undefined]])
    expect(fed('ls && bash')).toEqual([['ls', undefined], ['bash', undefined]])
    expect(fed('ls || bash')).toEqual([['ls', undefined], ['bash', undefined]])
    expect(fed('sleep 1 & bash')).toEqual([['sleep', undefined], ['bash', undefined]])
    expect(fed('ls\nbash')).toEqual([['ls', undefined], ['bash', undefined]])
    expect(fed('a | b | c && d')).toEqual([['a', undefined], ['b', 'a'], ['c', 'b'], ['d', undefined]])
    expect(fed('make |& tee log')).toEqual([['make', undefined], ['tee', 'make']])
    expect(fed('make 2>&1 | tee log')).toEqual([['make', undefined], ['tee', 'make']])
    expect(fed('echo "a | b" ; python3')).toEqual([['echo', undefined], ['python3', undefined]])
  })
  test('a new line straight after a | still continues the pipe', () => {
    expect(fed('curl x |\n  bash')).toEqual([['curl', undefined], ['bash', 'curl']])
  })
  test('the feeding command is named past its wrapper, as every command is', () => {
    expect(fed('sudo cat x | nohup python3')).toEqual([['cat', undefined], ['python3', 'cat']])
  })
  test("every command in a piped subshell or shell -c reads what feeds it; a piped subshell's output feeds as )", () => {
    expect(fed('echo x | (cd a; python3)')).toEqual([['echo', undefined], ['(', 'echo'], ['cd', 'echo'], ['python3', 'echo'], [')', undefined]])
    expect(fed('(cd a; echo x) | python3')).toEqual([['(', undefined], ['cd', undefined], ['echo', undefined], [')', undefined], ['python3', ')']])
    expect(fed(`echo x | bash -c 'cd a && python3'`)).toEqual([['echo', undefined], ['cd', 'echo'], ['python3', 'echo']])
    expect(fed(`bash -c 'curl x | sh'`)).toEqual([['curl', undefined], ['sh', 'curl']])
  })
  // Lessons review of #724: a ; inside a piped while or { } group reset the feed to nothing.
  test('every command in a piped while, until, for, if or { } group reads what feeds the group, and its output feeds as its closing word', () => {
    expect(fed('curl x | while read l; do sh; done')).toEqual([['curl', undefined], ['read', 'curl'], ['sh', 'curl'], ['done', undefined]])
    expect(fed('curl x | { read a; sh; }')).toEqual([['curl', undefined], ['read', 'curl'], ['sh', 'curl'], ['}', undefined]])
    expect(fed('curl x | if true; then sh; fi; python3')).toEqual([['curl', undefined], ['true', 'curl'], ['sh', 'curl'], ['fi', undefined], ['python3', undefined]])
    expect(fed('{ echo a; echo b; } | sh')).toEqual([['echo', undefined], ['echo', undefined], ['}', undefined], ['sh', '}']])
    expect(fed('while read l; do python3; done')).toEqual([['read', undefined], ['python3', undefined], ['done', undefined]])
  })
  // Second lessons review of #724: a group opened after a leading reserved word (do if, then {)
  // opened nothing, while its closer still closed one, so the outer group's feed was lost.
  test('a group opened after another reserved word (do if, then {) is matched by its own closer', () => {
    expect(fed('curl x | while read l; do if a; then b; fi; sh; done')).toEqual([
      ['curl', undefined],
      ['read', 'curl'],
      ['a', 'curl'],
      ['b', 'curl'],
      ['fi', undefined],
      ['sh', 'curl'],
      ['done', undefined],
    ])
    expect(fed('curl x | if a; then { b; }; sh; fi; python3')).toEqual([
      ['curl', undefined],
      ['a', 'curl'],
      ['b', 'curl'],
      ['}', undefined],
      ['sh', 'curl'],
      ['fi', undefined],
      ['python3', undefined],
    ])
  })
})

// #698: a heredoc's body was dropped with no way to ask for it, so no guard could judge what
// python3 - <<EOF or bash <<EOF runs. `commands` still drops it (it is text, not commands); a reader
// that needs it reads `heredocs` on each command `pipeline` gives, the body of every heredoc feeding it.
describe('pipeline: heredocs', () => {
  test("gives each command the body of the heredoc that feeds it, by its << word's place, and none where none does", () => {
    expect(pipeline(`python3 - <<'EOF'\nimport os\nopen('x', 'w')\nEOF\ngit status`)).toEqual([
      {
        words: ['python3', '-', '<<EOF'],
        heredocs: [{ word: 2, body: "import os\nopen('x', 'w')", quoted: true }],
        language: 'python',
        program: { text: "import os\nopen('x', 'w')", stdin: true },
        verdict: { does: 'write files', seen: 'open in mode w' },
        asWritten: true,
      },
      { words: ['git', 'status'] },
    ])
  })
  test('a spaced <<, a file descriptor before it, a quoted or escaped delimiter, and the words looked past', () => {
    expect(pipeline('cat << EOF\nls\nEOF')).toEqual([{ words: ['cat', '<<', 'EOF'], heredocs: [{ word: 1, body: 'ls', quoted: false }] }])
    expect(pipeline('cat 0<<"END"\nx\nEND')).toEqual([{ words: ['cat', '0<<END'], heredocs: [{ word: 1, body: 'x', quoted: true }] }])
    expect(pipeline('sudo -E python3 - <<\\EOF\nprint(1)\nEOF')).toEqual([
      { words: ['python3', '-', '<<EOF'], heredocs: [{ word: 2, body: 'print(1)', quoted: true }], behind: ['sudo'], language: 'python', program: { text: 'print(1)', stdin: true }, asWritten: true },
    ])
  })
  test('<<- takes the leading tabs off its body', () => {
    expect(pipeline('cat <<-EOF\n\tone\n\t\ttwo\n\tEOF')).toEqual([{ words: ['cat', '<<-EOF'], heredocs: [{ word: 1, body: 'one\ntwo', quoted: false }] }])
  })
  test('each of several heredocs feeds its own command, read one after another', () => {
    expect(pipeline('cat <<A; python3 - <<B\na\nA\nb\nB\nls')).toEqual([
      { words: ['cat', '<<A'], heredocs: [{ word: 1, body: 'a', quoted: false }] },
      { words: ['python3', '-', '<<B'], heredocs: [{ word: 2, body: 'b', quoted: false }], language: 'python', program: { text: 'b', stdin: true }, asWritten: true },
      { words: ['ls'] },
    ])
  })
  // A shell fed one this way is read as the commands in the body (#712, program.test.ts).
  test('a heredoc piped on keeps its body on the command it feeds, and the command after the pipe is fed by that one', () => {
    expect(pipeline("cat <<'EOF' | wc -l\nrm -rf build\nEOF")).toEqual([
      { words: ['cat', '<<EOF'], heredocs: [{ word: 1, body: 'rm -rf build', quoted: true }] },
      { words: ['wc', '-l'], pipedFrom: ['cat', '<<EOF'] },
    ])
  })
  test("a heredoc inside a shell's -c script feeds the command there", () => {
    expect(pipeline(`bash -lc 'python3 - <<EOF\nprint(1)\nEOF'`)).toEqual([
      { words: ['python3', '-', '<<EOF'], heredocs: [{ word: 2, body: 'print(1)', quoted: false }], behind: ['bash'], language: 'python', program: { text: 'print(1)', stdin: true }, asWritten: true },
    ])
  })
  // The cat the substitution runs is a command of its own since #974, and since #2141 it is fed the
  // body, which the word it sits in gives as its derived text; the word as typed still drops it.
  test('a heredoc inside a word feeds the cat there, and one that never ends has no body', () => {
    const cat = { words: ['cat', '<<EOF'], heredocs: [{ word: 1, body: "it's done", quoted: true }], substitution: true as const }
    expect(pipeline(`git commit -m "$(cat <<'EOF'\nit's done\nEOF\n)"`)).toEqual([cat, { words: ['git', 'commit', '-m', "$(cat <<'EOF'\n)"], derived: [null, null, null, { text: "it's done", commands: [cat] }] }])
    // Its lines are read as commands, as they always were, and since #3491 the cat says the reader
    // could not tell where its body stops.
    expect(pipeline('cat <<EOF\ngit status')).toEqual([{ words: ['cat', '<<EOF'], unread: 'fed a heredoc that never ends, so where its body stops cannot be read' }, { words: ['git', 'status'] }])
  })
  test('the commands are the ones commands gives, word for word', () => {
    const cmd = `X=1 cat > f.js <<'EOF'\nosascript -e 'x'\nEOF\n(cd sub && printf x >> notes.txt) 2>&1 | tee log`
    expect(pipeline(cmd).map(c => c.words)).toEqual(commands(cmd))
  })
})

// #730: the routes left from #724, each a misreading in the one reader every guard uses.
describe('the reader after #730', () => {
  const fed = (cmd: string) => pipeline(cmd).map(c => [c.words[0], c.pipedFrom?.[0]])
  // An output redirect was split out of a word however it was spaced (#654), an input one was not,
  // so `cat<<EOF` was a command named cat<<EOF and gave no body.
  test('an input redirect, a heredoc or a here-string begins a word of its own however it is spaced', () => {
    expect(pipeline('cat<<EOF\nx\nEOF\ngit status')).toEqual([{ words: ['cat', '<<EOF'], heredocs: [{ word: 1, body: 'x', quoted: false }] }, { words: ['git', 'status'] }])
    expect(pipeline("python3 -<<'EOF'\nprint(1)\nEOF")[0]).toMatchObject({ words: ['python3', '-', '<<EOF'], heredocs: [{ word: 2, body: 'print(1)' }] })
    expect(commands('wc -l<notes.txt')).toEqual([['wc', '-l', '<notes.txt']])
    expect(commands('cat<<<x')).toEqual([['cat', '<<<x']])
    // A descriptor number stays with its redirect, and a < inside a $( ) word stays in the word.
    expect(commands('cat 0<<EOF\nx\nEOF')).toEqual([['cat', '0<<EOF']])
    expect(commands('echo $(wc -l<f)')).toEqual([['wc', '-l', '<f'], ['echo', '$(wc -l<f)']])
    expect(commands('diff <(sort a) b')).toEqual([['sort', 'a'], ['diff', '<(sort a)', 'b']])
  })
  // A case pattern's ) was read as a subshell's close, so it popped the group feeding the commands
  // around it, and `sh` in a piped while loop was fed nothing.
  test("a case pattern's ) closes no group: the commands in each clause read what feeds the case", () => {
    expect(fed('curl x | while read l; do case $l in a) sh;; esac; done')).toEqual([
      ['curl', undefined],
      ['read', 'curl'],
      ['case', 'curl'],
      ['sh', 'curl'],
      ['esac', undefined],
      ['done', undefined],
    ])
    expect(commands('case $x in a|b) rm a;; (c) rm c ;& *) ls;;\nesac; echo done')).toEqual([['case', '$x', 'in'], ['rm', 'a'], ['rm', 'c'], ['ls'], ['esac'], ['echo', 'done']])
    expect(commands('case $x in\n  a) make ;;\n  "b c") make b\nesac')).toEqual([['case', '$x', 'in'], ['make'], ['make', 'b'], ['esac']])
    expect(commands('case a in x) case b in y) sh;; esac;; esac')).toEqual([['case', 'a', 'in'], ['case', 'b', 'in'], ['sh'], ['esac'], ['esac']])
    // A subshell around a case still closes where it ends.
    expect(commands('(case $x in a) cd sub;; esac; make) > out')).toEqual([['('], ['case', '$x', 'in'], ['cd', 'sub'], ['esac'], ['make'], [')'], ['>', 'out']])
  })
  test('env -S splits its string into the command it runs', () => {
    expect(commands(`env -S 'python3 -c "open(1)"'`)).toEqual([['python3', '-c', 'open(1)']])
    expect(commands(`env -iS 'FOO=1 git push' --force`)).toEqual([['git', 'push', '--force']])
    expect(commands(`env --split-string='timeout 5 make deploy'`)).toEqual([['make', 'deploy']])
    expect(commands(`env --split-string 'bash -c "git push"'`)).toEqual([['git', 'push']])
  })
  // #730: xargs gives the command after it its files from its own input, so no reader can name them.
  test('a command xargs runs is marked as given its operands by xargs', () => {
    expect(pipeline('ls | xargs rm')).toEqual([{ words: ['ls'] }, { words: ['rm'], pipedFrom: ['ls'], xargs: true, behind: ['xargs'] }])
    expect(pipeline('rm a')).toEqual([{ words: ['rm', 'a'] }])
  })
})

describe('git', () => {
  test('reads the subcommand after global options, and the folder -C names', () => {
    expect(git(['git', '-C', '/repo', '-c', 'x=y', 'checkout', 'main'])).toEqual({ sub: 'checkout', args: ['main'], dir: '/repo' })
    expect(git(['git', '--no-pager', 'log', '--grep=commit'])).toEqual({ sub: 'log', args: ['--grep=commit'], dir: undefined })
  })
  test('a git at a full path is git', () => {
    expect(git(['/usr/bin/git', 'status'])?.sub).toBe('status')
  })
  test('anything else is not git', () => {
    expect(git(['gh', 'pr', 'list'])).toBeUndefined()
    expect(git(['git'])).toEqual({ sub: undefined, args: [], dir: undefined })
  })
  // #3337: a command can name its repository and its working folder apart from the folder it runs
  // in, four ways. Until then each value was skipped and only -C's folder handed on, so a guard read
  // the command as one about the folder it ran in. git reads the two variables exactly as the two
  // options (measured with git 2.51.1): an option wins over the variable, and the last of each wins.
  test('hands on the repository --git-dir or GIT_DIR names and the working folder --work-tree or GIT_WORK_TREE names (#3337)', () => {
    expect(git(['git', '--git-dir=/other/.git', '--work-tree=/w/x', 'merge', 'y'])).toEqual({ sub: 'merge', args: ['y'], dir: undefined, gitDir: '/other/.git', workTree: '/w/x' })
    expect(git(['git', '--git-dir', '/other/.git', '--work-tree', '/w/x', 'merge', 'y'])).toEqual({ sub: 'merge', args: ['y'], dir: undefined, gitDir: '/other/.git', workTree: '/w/x' })
    expect(git(['git', 'merge', 'y'], ['GIT_DIR=/other/.git', 'GIT_WORK_TREE=/w/x'])).toEqual({ sub: 'merge', args: ['y'], dir: undefined, gitDir: '/other/.git', workTree: '/w/x' })
    // One alone is handed on alone, beside -C's folder, which a relative value is read from.
    expect(git(['git', '-C', '/w/a', '--git-dir=../other/.git', 'cherry-pick', 'abc'])).toEqual({ sub: 'cherry-pick', args: ['abc'], dir: '/w/a', gitDir: '../other/.git' })
    expect(git(['git', '--work-tree=/w/x', 'restore', 'app.css'])).toEqual({ sub: 'restore', args: ['app.css'], dir: undefined, workTree: '/w/x' })
    expect(git(['git', 'restore', 'app.css'], ['TMPDIR=/t', 'GIT_WORK_TREE=/w/x'])).toEqual({ sub: 'restore', args: ['app.css'], dir: undefined, workTree: '/w/x' })
    // An option wins over the variable, and the last of each wins.
    expect(git(['git', '--git-dir=/b/.git', 'merge', 'y'], ['GIT_DIR=/a/.git'])?.gitDir).toBe('/b/.git')
    expect(git(['git', '--git-dir=/a/.git', '--git-dir', '/b/.git', 'merge', 'y'])?.gitDir).toBe('/b/.git')
    expect(git(['git', 'merge', 'y'], ['GIT_WORK_TREE=/a', 'GIT_WORK_TREE=/b'])?.workTree).toBe('/b')
    // A value written empty is handed on empty, never dropped: git reads it, and refuses it.
    expect(git(['git', '--git-dir=', 'merge', 'y'])?.gitDir).toBe('')
    // An option of the subcommand spelled the same is the subcommand's own, and names nothing.
    expect(git(['git', 'merge', '--work-tree=/w/x', 'y'])).toEqual({ sub: 'merge', args: ['--work-tree=/w/x', 'y'], dir: undefined })
  })
  test('a command naming neither hands on neither, whatever else it is run with (#3337)', () => {
    expect(git(['git', '-C', '/repo', 'merge', 'y'], ['GIT_AUTHOR_NAME=x', 'TMPDIR=/t'])).toEqual({ sub: 'merge', args: ['y'], dir: '/repo' })
    expect(git(['git', '--namespace', 'ns', 'merge', 'y'])).toEqual({ sub: 'merge', args: ['y'], dir: undefined })
  })
  test('the settings the command reader gives a git command carry the two variables to it (#3337)', () => {
    const read = (command: string) => pipeline(command).map(c => git(c.words, c.env))
    expect(read('GIT_DIR=/other/.git git merge y')).toEqual([{ sub: 'merge', args: ['y'], dir: undefined, gitDir: '/other/.git' }])
    expect(read('env GIT_WORK_TREE=/w/x git restore app.css')).toEqual([{ sub: 'restore', args: ['app.css'], dir: undefined, workTree: '/w/x' }])
    expect(read('GIT_DIR=/other/.git GIT_WORK_TREE=/w/x git cherry-pick abc')).toEqual([{ sub: 'cherry-pick', args: ['abc'], dir: undefined, gitDir: '/other/.git', workTree: '/w/x' }])
  })
  // #3398: git reads each -C from the one before it. Measured with git 2.51.1 on macOS on
  // 2026-11-22, in throwaway repositories m/a, m/a/b, m/b and m/c, run from m, asking `rev-parse
  // --show-toplevel`: `-C <m>/a -C b` and `-C a -C b` answer m/a/b; `-C a -C <m>/c` answers m/c;
  // `-C a -C ""` answers m/a and `-C "" -C b` m/b; `-C a -C "" -C b` answers m/a/b; `-C a -C ../c`
  // answers m/c; `-C a -C b/`, `-C a/ -C b` and `-C a -C ./b` answer m/a/b; `-C a -c core.x=y -C b`
  // and `-C a --no-pager -C b` answer m/a/b; `-C nothere -C <m>/c` and `-C a -C nothere` exit 128
  // (cannot change to 'nothere') and run nothing. Until #3398 the reader kept only the last -C, so
  // every mod placed `git -C /a -C b merge y` in <the folder it runs in>/b.
  // `chained` is the folder git runs in, given only where it is not what `dir` says; `dir` stays the
  // last -C as written, the reading every mod placed a git command by until then.
  const chain = (...opts: string[]) => {
    const g = git(['git', ...opts, 'merge', 'y'])
    return g && 'chained' in g ? g.chained : 'none'
  }
  test('more than one -C is chained as git chains them, each read from the one before it (#3398)', () => {
    expect(git(['git', '-C', '/a', '-C', 'b', 'merge', 'y'])).toEqual({ sub: 'merge', args: ['y'], dir: 'b', chained: '/a/b' })
    expect(chain('-C', 'a', '-C', 'b')).toBe('a/b')
    expect(chain('-C', 'a', '-C', 'b', '-C', 'c')).toBe('a/b/c')
    // Past git's other global options, with a value and without.
    expect(chain('-C', 'a', '-c', 'core.x=y', '-C', 'b')).toBe('a/b')
    expect(chain('-C', 'a', '--no-pager', '-C', 'b')).toBe('a/b')
    expect(chain('-C', '/a', '--git-dir=.git', '-C', 'b')).toBe('/a/b')
    // An empty one leaves the folder as it is.
    expect(chain('-C', 'a', '-C', '')).toBe('a')
    expect(chain('-C', 'a', '-C', '', '-C', 'b')).toBe('a/b')
    expect(chain('-C', '', '-C', 'a', '-C', 'b')).toBe('a/b')
    // Dots and a closing slash are kept as written, for the reader's caller to resolve as it does `dir`.
    expect(chain('-C', 'a', '-C', '../c')).toBe('a/../c')
    expect(chain('-C', 'a/', '-C', 'b/')).toBe('a/b/')
    expect(chain('-C', 'a', '-C', './b')).toBe('a/./b')
    expect(chain('-C', '~/a', '-C', 'b')).toBe('~/a/b')
    expect(chain('-C', '$HOME/a', '-C', 'b')).toBe('$HOME/a/b')
    // The repository and the working folder a command names are handed on beside it.
    expect(git(['git', '-C', '/a', '-C', 'b', '--work-tree=..', 'checkout', 'main'], ['GIT_DIR=.git'])).toEqual({ sub: 'checkout', args: ['main'], dir: 'b', chained: '/a/b', gitDir: '.git', workTree: '..' })
  })
  test('an absolute -C starts again from itself, so a chain ending in one is what the last -C says (#3398)', () => {
    // Nothing is added: `dir` is already the folder git runs in.
    expect(git(['git', '-C', 'a', '-C', '/c', 'merge', 'y'])).toEqual({ sub: 'merge', args: ['y'], dir: '/c' })
    expect(chain('-C', '/a', '-C', '/c')).toBe('none')
    expect(chain('-C', 'a', '-C', '~/c')).toBe('none')
    expect(chain('-C', 'a', '-C', '$HOME/c')).toBe('none')
    expect(chain('-C', '$X', '-C', '/c')).toBe('none')
    // An absolute one in the middle: what comes after it is read from it.
    expect(chain('-C', 'a', '-C', '/c', '-C', 'd')).toBe('/c/d')
    expect(chain('-C', '$X', '-C', '/c', '-C', 'd')).toBe('/c/d')
  })
  test('a chain the reader cannot work out is null, never a guess (#3398)', () => {
    // A value the shell fills in after another -C may be absolute or relative: no one folder.
    expect(git(['git', '-C', '/a', '-C', '$B', 'merge', 'y'])).toEqual({ sub: 'merge', args: ['y'], dir: '$B', chained: null })
    expect(chain('-C', 'a', '-C', '${B}')).toBeNull()
    expect(chain('-C', 'a', '-C', '$(pwd)')).toBeNull()
    expect(chain('-C', 'a', '-C', '`pwd`')).toBeNull()
    // A folder read from one the shell fills in: empty, that one changes nothing, and split it is more words.
    expect(chain('-C', '$A', '-C', 'b')).toBeNull()
    expect(chain('-C', '$(pwd)', '-C', 'b')).toBeNull()
    expect(chain('-C', '$A', '-C', '')).toBeNull()
    // A pattern, a brace list and another user's home are the shell's to fill in too.
    expect(chain('-C', 'a', '-C', 'b*')).toBeNull()
    expect(chain('-C', 'a', '-C', '{b,c}')).toBeNull()
    expect(chain('-C', 'a', '-C', '~dan/c')).toBeNull()
    // Once it cannot be worked out, only an absolute -C makes it known again.
    expect(chain('-C', '/a', '-C', '$B', '-C', 'c')).toBeNull()
    expect(chain('-C', '/a', '-C', '$B', '-C', '')).toBeNull()
  })
  test('one -C, or none, is read exactly as before (#3398)', () => {
    expect(git(['git', 'status'])).toEqual({ sub: 'status', args: [], dir: undefined })
    expect(git(['git', '-C', '/repo', 'log'])).toEqual({ sub: 'log', args: [], dir: '/repo' })
    expect(git(['git', '-C', 'sub', 'log'])).toEqual({ sub: 'log', args: [], dir: 'sub' })
    // One the shell fills in, and an empty one, are handed on as written, as they always were.
    expect(git(['git', '-C', '$X', 'log'])).toEqual({ sub: 'log', args: [], dir: '$X' })
    expect(git(['git', '-C', '', 'log'])).toEqual({ sub: 'log', args: [], dir: '' })
    expect(git(['git', '-C', '', '-C', '', 'log'])).toEqual({ sub: 'log', args: [], dir: '' })
    expect(git(['git', '-C', '', '-C', '$X', 'log'])).toEqual({ sub: 'log', args: [], dir: '$X' })
    // A -C of the subcommand's own is the subcommand's, and chains nothing.
    expect(git(['git', '-C', '/repo', 'apply', '-C', '2', 'x.patch'])).toEqual({ sub: 'apply', args: ['-C', '2', 'x.patch'], dir: '/repo' })
    // -C as git's last word names no folder and no subcommand.
    expect(git(['git', '-C'])).toEqual({ sub: undefined, args: [], dir: undefined })
  })
  test('the command reader carries each -C of a line to it (#3398)', () => {
    const read = (command: string) => pipeline(command).map(c => git(c.words, c.env))
    expect(read('git -C /a -C b merge y')).toEqual([{ sub: 'merge', args: ['y'], dir: 'b', chained: '/a/b' }])
    expect(read('git -C /a -C "$B" checkout main && git -C /repo log')).toEqual([
      { sub: 'checkout', args: ['main'], dir: '$B', chained: null },
      { sub: 'log', args: [], dir: '/repo' },
    ])
  })
})

describe('heredocs name the descriptor they feed (#760)', () => {
  test('standard input carries no fd; another descriptor says which', () => {
    expect(pipeline("psql db <<'SQL'\nSELECT 1;\nSQL")[0]?.heredocs).toEqual([{ word: 2, body: 'SELECT 1;', quoted: true }])
    expect(pipeline("psql db 0<<'SQL'\nSELECT 1;\nSQL")[0]?.heredocs).toEqual([{ word: 2, body: 'SELECT 1;', quoted: true }])
    expect(pipeline("psql db 3<<'SQL'\nSELECT 1;\nSQL")[0]?.heredocs).toEqual([{ word: 2, body: 'SELECT 1;', quoted: true, fd: 3 }])
  })
  test('a heredoc a later input redirect replaces as standard input says so', () => {
    expect(pipeline("psql db <<'SQL' < evil.sql\nSELECT 1;\nSQL")[0]?.heredocs).toEqual([{ word: 2, body: 'SELECT 1;', quoted: true, replaced: true }])
    expect(pipeline("psql db <<'SQL' <<< 'DROP TABLE t'\nSELECT 1;\nSQL")[0]?.heredocs).toEqual([{ word: 2, body: 'SELECT 1;', quoted: true, replaced: true }])
    // A later redirect on another descriptor replaces nothing on standard input.
    expect(pipeline("psql db <<'SQL' 3< other.txt\nSELECT 1;\nSQL")[0]?.heredocs).toEqual([{ word: 2, body: 'SELECT 1;', quoted: true }])
    // A process substitution is an argument, not a redirect onto standard input.
    expect(pipeline("diff - <<'X' <(sort b)\na\nX").find(c => c.words[0] === 'diff')?.heredocs).toEqual([{ word: 2, body: 'a', quoted: true }])
    // 00 is descriptor 0 too.
    expect(pipeline("psql db 00<<'SQL'\nSELECT 1;\nSQL")[0]?.heredocs).toEqual([{ word: 2, body: 'SELECT 1;', quoted: true }])
  })
  // #831: a quoted delimiter stops the shell expanding the body, so a $ or a backtick in it is text.
  test('each heredoc says whether its delimiter was quoted, however it was quoted', () => {
    const quoted = (cmd: string) => pipeline(cmd)[0]?.heredocs?.map(h => h.quoted)
    expect(quoted("psql db <<'SQL'\nSELECT $1;\nSQL")).toEqual([true])
    expect(quoted('psql db <<"SQL"\nSELECT $1;\nSQL')).toEqual([true])
    expect(quoted('psql db <<\\SQL\nSELECT $1;\nSQL')).toEqual([true])
    expect(quoted("psql db << 'SQL'\nSELECT $1;\nSQL")).toEqual([true])
    expect(quoted("psql db <<-'SQL'\n\tSELECT 1;\n\tSQL")).toEqual([true])
    expect(quoted('psql db <<SQL\nSELECT $1;\nSQL')).toEqual([false])
    expect(quoted('psql db << SQL\nSELECT 1;\nSQL')).toEqual([false])
    expect(quoted('psql db <<-SQL\n\tSELECT 1;\n\tSQL')).toEqual([false])
    expect(quoted("cat <<A 3<<'B'\na\nA\nb\nB")).toEqual([false, true])
  })
  // #2073: the end marker is the whole word after <<, quotes taken out, as bash reads it (and as
  // lib/shell-words.py's heredoc_opener does since #2060). Read as the quoted part or the leading
  // letters alone, <<'E'OF and <<E"OF" ended at a line E and <<END-OF at a line END, so the body ran
  // on past the line bash ends it at and hid every command after it.
  test('a marker quoted in part, or holding a hyphen, is the whole word', () => {
    expect(commands("cat <<'E'OF\nx\nEOF\ngit push\nE")).toEqual([['cat', '<<EOF'], ['git', 'push'], ['E']])
    expect(commands('cat <<E"OF"\nx\nEOF\ngit push\nE')).toEqual([['cat', '<<EOF'], ['git', 'push'], ['E']])
    expect(commands('cat <<END-OF\nx\nEND-OF\ngit push\nEND')).toEqual([['cat', '<<END-OF'], ['git', 'push'], ['END']])
    expect(commands('cat <<E\\OF\nx\nEOF\ngit push\nE')).toEqual([['cat', '<<EOF'], ['git', 'push'], ['E']])
    // How the word itself is spelled after <<$'EOF' is the word reader's; the body ends at EOF.
    expect(commands("cat <<$'EOF'\nx\nEOF\ngit push").slice(1)).toEqual([['git', 'push']])
  })
  test('a line that is only part of such a marker stays in the body', () => {
    expect(commands("cat <<'E'OF\nE\ngit push\nEOF")).toEqual([['cat', '<<EOF']])
    expect(commands('cat <<E"OF"\nE\ngit push\nEOF')).toEqual([['cat', '<<EOF']])
    expect(commands('cat <<END-OF\nEND\ngit push\nEND-OF')).toEqual([['cat', '<<END-OF']])
  })
  test('any quoted part of the marker makes the body text, and its body is kept', () => {
    const docs = (cmd: string) => pipeline(cmd)[0]?.heredocs
    expect(docs("cat <<'E'OF\n$1\nEOF")).toEqual([{ word: 1, body: '$1', quoted: true }])
    expect(docs('cat <<E"OF"\n$1\nEOF')).toEqual([{ word: 1, body: '$1', quoted: true }])
    expect(docs('cat <<E\\OF\n$1\nEOF')).toEqual([{ word: 1, body: '$1', quoted: true }])
    expect(docs('cat <<END-OF\n$1\nEND-OF')).toEqual([{ word: 1, body: '$1', quoted: false }])
    expect(docs('cat <<-E"OF"\n\t$1\n\tEOF')).toEqual([{ word: 1, body: '$1', quoted: true }])
  })
  test('a shift in arithmetic, or a << in a pattern, opens no heredoc, so a real one after it is still read', () => {
    expect(commands("x=$((1<<2))\ncat > f <<'EOF'\nit's text\nEOF\ngit push")).toEqual([['cat', '>', 'f', '<<EOF'], ['git', 'push']])
    expect(commands("grep -E '1<<[ ]' f\ncat <<'EOF'\nit's text\nEOF\ngit push")).toEqual([['grep', '-E', '1<<[ ]', 'f'], ['cat', '<<EOF'], ['git', 'push']])
  })
})

// #974: the shell runs the commands inside a $(...) or backticks before the command they sit in, and
// in an unquoted heredoc's body before the program fed it starts, yet the reader kept them inside
// the word they sat in, so no guard judging the commands a line runs saw one: no build's git
// commit, git push and npm publish, the style check's commit, the secret guard's reads. Each is now
// a command of its own, placed before the command it sits in and marked `substitution`. A quoted
// heredoc body, single quotes, $'...' and a comment stay data, and $((...)) is arithmetic.
describe('the commands a substitution runs (#974)', () => {
  const subs = (cmd: string) => pipeline(cmd).filter(c => c.substitution).map(c => c.words)
  test('$(...) and backticks, bare or in double quotes, each give their commands, marked, before the command they sit in', () => {
    expect(pipeline('echo $(git commit -m x)').map(({ derived: _, ...c }) => c)).toEqual([{ words: ['git', 'commit', '-m', 'x'], substitution: true }, { words: ['echo', '$(git commit -m x)'] }])
    expect(commands('echo `git push`')).toEqual([['git', 'push'], ['echo', '`git push`']])
    expect(subs('echo "published: $(npm publish)"')).toEqual([['npm', 'publish']])
    expect(subs('echo "pushed: `git push origin main`"')).toEqual([['git', 'push', 'origin', 'main']])
    expect(commands('cd /a; echo $(git push); ls')).toEqual([['cd', '/a'], ['git', 'push'], ['echo', '$(git push)'], ['ls']])
  })
  test('a substitution that only sets a variable still runs its commands, and so does one inside a word', () => {
    expect(subs('x=$(git push)')).toEqual([['git', 'push']])
    expect(subs('x=$(git push); y=`npm publish`')).toEqual([['git', 'push'], ['npm', 'publish']])
    expect(subs('cd $(git rev-parse --show-toplevel)')).toEqual([['git', 'rev-parse', '--show-toplevel']])
    expect(subs('echo $(wc -l<f)')).toEqual([['wc', '-l', '<f']])
  })
  test('nested substitutions, one spanning lines, and backticks inside $(...) are each read', () => {
    expect(subs('echo $(echo $(git push))')).toEqual([['git', 'push'], ['echo', '$(git push)']])
    expect(subs('echo $(echo `npm publish`)')).toEqual([['npm', 'publish'], ['echo', '`npm publish`']])
    expect(subs('echo "$(git add .\ngit commit -m x)"')).toEqual([['git', 'add', '.'], ['git', 'commit', '-m', 'x']])
  })
  test("in an unquoted heredoc's body they run, in a quoted one they are data", () => {
    expect(subs('cat <<EOF\nnote $(git push)\nEOF')).toEqual([['git', 'push']])
    expect(subs('python3 - <<EOF\nprint("`npm publish`")\nEOF')).toEqual([['npm', 'publish']])
    for (const open of ["cat <<'EOF'", 'cat <<"EOF"', 'cat <<\\EOF', "python3 - <<-'EOF'"]) expect(subs(`${open}\nnote $(git push) \`npm publish\`\nEOF`)).toEqual([])
    // The commit message idiom: the substitution runs cat, whose quoted body is the message.
    expect(subs(`git commit -m "$(cat <<'EOF'\nit's done, $(git push) is text\nEOF\n)"`)).toEqual([['cat', '<<EOF']])
  })
  test("single quotes, $'...', an escaped $ or backtick, a comment and arithmetic run nothing", () => {
    expect(subs("echo '$(git push)' '`npm publish`'")).toEqual([])
    expect(subs("echo $'$(git push)'")).toEqual([])
    expect(subs('echo \\$(git push) \\`npm publish\\`')).toEqual([])
    expect(subs('echo hi # $(git push)')).toEqual([])
    expect(subs('echo $((1 + 2))')).toEqual([])
  })
  test("inside a shell's own script, read as the commands that shell runs", () => {
    expect(subs("bash -c 'echo $(git push)'")).toEqual([['git', 'push']])
    expect(subs("sh <<'EOF'\nx=`npm publish`\nEOF")).toEqual([['npm', 'publish']])
  })
  // The style check's, the secret guard's and the keystroke guard's tests (their READ_974) judge these
  // readings as given, since a mod cannot import another mod's files: this holds each to the reader,
  // so a reader change that moves one fails here. Change both together.
  test("the readings other guards' tests take as given", () => {
    const DASH = String.fromCharCode(0x2014)
    const FIX = `Fix ${DASH} again`
    const TYPED = 'tell application "System Events" to key' + 'stroke "n"'
    const given: [string, string[][]][] = [
      // The style check.
      [`x=$(git commit -m "${FIX}")`, [['git', 'commit', '-m', FIX]]],
      ['echo "made `git commit -F /tmp/msg.txt`"', [['git', 'commit', '-F', '/tmp/msg.txt'], ['echo', 'made `git commit -F /tmp/msg.txt`']]],
      [`cat <<EOF\n$(git commit -m "${FIX}")\nEOF`, [['git', 'commit', '-m', FIX], ['cat', '<<EOF']]],
      [`echo '$(git commit -m "${FIX}")'`, [['echo', `$(git commit -m "${FIX}")`]]],
      [`cat <<'EOF'\n\`git commit -m "${FIX}"\`\nEOF`, [['cat', '<<EOF']]],
      // The secret guard.
      ['echo "$(cat .env)"', [['cat', '.env'], ['echo', '$(cat .env)']]],
      ['echo `printenv`', [['printenv'], ['echo', '`printenv`']]],
      ['cat <<EOF\n$(echo $GITHUB_TOKEN)\nEOF', [['echo', '$GITHUB_TOKEN'], ['cat', '<<EOF']]],
      ["echo '$(cat .env)' '`printenv`'", [['echo', '$(cat .env)', '`printenv`']]],
      ["cat <<'EOF'\n$(cat .env)\nEOF", [['cat', '<<EOF']]],
      // The keystroke guard.
      [`x=$(osascript -e '${TYPED}')`, [['osascript', '-e', TYPED]]],
      ['echo "`cliclick c:100,200`"', [['cliclick', 'c:100,200'], ['echo', '`cliclick c:100,200`']]],
      ["cat <<EOF\n$(open -a 'Google Chrome' report.html)\nEOF", [['open', '-a', 'Google Chrome', 'report.html'], ['cat', '<<EOF']]],
      ["echo '$(cliclick c:100,200)'", [['echo', '$(cliclick c:100,200)']]],
      ["cat <<'EOF'\n`cliclick c:100,200`\nEOF", [['cat', '<<EOF']]],
    ]
    for (const [command, words] of given) expect(`${command} => ${JSON.stringify(commands(command))}`).toBe(`${command} => ${JSON.stringify(words)}`)
  })
  // #975: a process substitution runs its commands too, as the command it sits in starts.
  test('a process substitution, <(...) or >(...), gives its commands; in double quotes or a heredoc body it is text', () => {
    expect(pipeline('diff <(git push) b').map(({ derived: _, ...c }) => c)).toEqual([{ words: ['git', 'push'], substitution: true }, { words: ['diff', '<(git push)', 'b'] }])
    expect(subs('tee >(npm publish) < x')).toEqual([['npm', 'publish']])
    expect(subs('diff <(sort <(git push)) b')).toEqual([['git', 'push'], ['sort', '<(git push)']])
    expect(subs('echo "<(git push)" \'>(npm publish)\'')).toEqual([])
    expect(subs('cat <<EOF\n<(git push)\nEOF')).toEqual([])
  })
  // A substitution's spaces, quotes and redirects split the word it sits in, so `x=$(npm publish)`
  // also gave a command named `publish)` and `> a.md)` a file named `a.md)`. It is one word now.
  test('a substitution is part of the one word it sits in, its spaces, quotes and redirects included', () => {
    expect(commands('x=$(npm publish)')).toEqual([['npm', 'publish']])
    expect(commands('echo "$(echo "a b")" c')).toEqual([['echo', 'a b'], ['echo', '$(echo "a b")', 'c']])
    expect(commands('rm $(cat list) `ls -d old`')).toEqual([['cat', 'list'], ['ls', '-d', 'old'], ['rm', '$(cat list)', '`ls -d old`']])
    expect(commands('x=$(echo a > f.md); echo b')).toEqual([['echo', 'a', '>', 'f.md'], ['echo', 'b']])
    // One never closed runs to the end, as the shell reads it.
    expect(commands('echo $(git push')).toEqual([['git', 'push'], ['echo', '$(git push']])
  })
  // #975: the shell expands an unquoted heredoc's body before the program it feeds reads it, taking
  // the backslash off an escaped $, backtick or backslash and joining an escaped line end, so a shell
  // fed `\$(git push)` runs it. The program is read as it receives the body; a quoted body is as written.
  test("a program fed an unquoted heredoc reads the body as the shell expanded it, escapes taken off", () => {
    const program = (cmd: string) => pipeline(cmd).find(c => c.program)?.program
    expect(program("python3 - <<EOF\nprint('\\$HOME \\` \\\\ \\x')\nEOF")).toEqual({ text: "print('$HOME ` \\ \\x')", stdin: true })
    expect(program("python3 - <<EOF\nprint(1 + \\\n2)\nEOF")).toEqual({ text: 'print(1 + 2)', stdin: true })
    expect(program("python3 - <<'EOF'\nprint('\\$HOME')\nEOF")).toEqual({ text: "print('\\$HOME')", stdin: true })
    expect(subs('bash <<EOF\necho \\$(git push) \\`npm publish\\`\nEOF')).toEqual([['git', 'push'], ['npm', 'publish']])
    expect(subs("bash <<'EOF'\necho \\$(git push)\nEOF")).toEqual([])
  })
})

// #1171: whether the shell left a program's text as written was worked out twice, by mod-kit's
// write reader (for targets and code) and by ask before saving (for its #940 reading). The reader
// now says it on each command it gives, `asWritten`, so there is one answer.
describe('pipeline: asWritten (#1171)', () => {
  const asWritten = (command: string) => pipeline(command).filter(c => c.program).map(c => c.asWritten === true)
  test('a program on standard input from a quoted heredoc, or holding no $ or backtick, is as written', () => {
    expect(asWritten("python3 - <<'EOF'\nprint(`${x}` + $y)\nEOF")).toEqual([true])
    expect(asWritten('python3 - <<"EOF"\nprint($y)\nEOF')).toEqual([true])
    expect(asWritten("python3 - <<\\EOF\nprint($y)\nEOF")).toEqual([true])
    expect(asWritten(`python3 -c "print('a')"`)).toEqual([true])
    expect(asWritten("python3 - <<EOF\nprint('a')\nEOF")).toEqual([true])
  })
  test('the shell may have changed one that is unquoted and holds a $ or backtick, and one in a substitution', () => {
    expect(asWritten("python3 - <<EOF\nprint($y)\nEOF")).toEqual([false])
    expect(asWritten('python3 - <<EOF\nprint(`y`)\nEOF')).toEqual([false])
    expect(asWritten(`python3 -c "print('$y')"`)).toEqual([false])
    expect(asWritten(`echo "$(python3 -c "print('a')")"`)).toEqual([false])
  })
  test('a command running no program carries no asWritten', () => {
    expect(pipeline('ls -la').map(c => 'asWritten' in c)).toEqual([false])
  })
})

// #1834: a shell that splits an unquoted expansion's value into words (bash, sh, dash, ksh) runs the
// script it is given, so each command of that script carries where its unquoted $s are, quotes
// removed, for the write reader to split. zsh splits none, and a top level line names no shell.
describe("pipeline: where a word's expansions outside quotes are, under a shell that splits them (#1834)", () => {
  test('bash and sh scripts carry each unquoted $ by its place in the word; quoted, escaped and zsh ones do not', () => {
    expect(pipeline(`bash -c 'cp $A "$B" x\${C}"$D"$E \\$F'`).map(c => c.splits)).toEqual([[[], [0], [], [1, 7], []]])
    expect(pipeline(`sh -c 'echo $A'`).map(c => c.splits)).toEqual([[[], [0]]])
    expect(pipeline(`bash -c 'echo "$A" \\$B'`).map(c => c.splits)).toEqual([undefined])
    expect(pipeline(`bash -c "echo \\$'x'"`).map(c => c.splits)).toEqual([undefined])
    expect(pipeline(`zsh -c 'echo $A'`).map(c => c.splits)).toEqual([undefined])
    expect(pipeline('echo $A').map(c => c.splits)).toEqual([undefined])
  })
})

// #1951: a word whose every pattern character is quoted or escaped is handed on as written, matched
// against no file, so each command says which of its words are; a pattern character left bare, or
// any expansion in the word, leaves it one the shell may expand.
describe('pipeline: which words the shell hands on as written, every pattern character quoted (#1951)', () => {
  test('a pattern quoted, double quoted, escaped or quoted in part is literal; one left bare or holding an expansion is not', () => {
    expect(pipeline(`python3 s.py '*push*' "app/*.css" app/\\*x app/'*'.tsx`).map(c => c.literal)).toEqual([[false, false, true, true, true, true]])
    expect(pipeline(`python3 s.py *push* ''*x'' "app/"*x '$P*' "$(ls)*" x\\(1\\)y(2)`).map(c => c.literal)).toEqual([undefined, undefined])
    // A word holding no pattern character, quoted or not, is no literal pattern.
    expect(pipeline(`python3 s.py 'a push' plain`).map(c => c.literal)).toEqual([undefined])
    // A shell's script is read by its own quotes.
    expect(pipeline(`bash -c "python3 s.py '*x*' *y*"`).map(c => c.literal)).toEqual([[false, false, true, false]])
  })
})

// #2320: a $ the shell leaves as written, before a closing double quote or before nothing a name, a
// brace, a bracket or a quote can start, is text as a single quoted one is (#1953), so a double quoted
// regex ending in $ is handed on as its characters. A $ any shell expands stays expanded.
describe('pipeline: a $ the shell leaves as written is unexpanded, wherever it is quoted (#2320)', () => {
  test('a $ before a closing double quote, a space, a slash or the end of the command is text', () => {
    expect(pipeline(`python3 s.py "^foo.*bar$" "a$ b" "costs $5" foo$ "x$/y"`).map(c => c.unexpanded)).toEqual([[false, false, true, true, false, true, true]])
    expect(pipeline(`grep -n "bar$" a.txt | wc -l`).map(c => c.unexpanded)).toEqual([[false, false, true, false], undefined])
    // Text before a separator is still text.
    expect(pipeline(`python3 s.py foo$; ls`).map(c => c.unexpanded)).toEqual([[false, false, true], undefined])
  })
  test('a $ starting a name, a brace, a bracket, a quote or a substitution, in any shell, stays expanded', () => {
    expect(pipeline(`python3 s.py "$OUT/big.ts" x$'y' x$"y" "\${X}" "$[1]" "$=x" "$~x" "$#" "$_" '$P'$Q`).map(c => c.unexpanded)).toEqual([undefined])
    // One word holding a $ left as text and one expanded is expanded.
    expect(pipeline(`python3 s.py "a$"$B`).map(c => c.unexpanded)).toEqual([undefined])
    expect(pipeline(`python3 s.py "$(`).map(c => c.unexpanded)).toEqual([undefined])
  })
  test('a $ left as text is no expansion for `literal`, exactly as a single quoted one is not', () => {
    expect(pipeline(`python3 s.py "^foo.*bar$" '^foo.*bar$'`).map(c => c.literal)).toEqual([undefined])
  })
})

// #2141: a word built from a command substitution gives, beside the word as typed, what the
// substitution runs and, where that is a plain cat of a heredoc or a here string, the text it puts
// in the word, so a guard reading a pull request's description reads that description. Anything
// else is unresolved, with why, never empty and never typed.
describe('pipeline: the text a command substitution puts in a word (#2141)', () => {
  const last = (cmd: string) => pipeline(cmd).filter(c => !c.substitution).pop()
  test("a cat of a quoted heredoc gives its body as the word's derived text, beside the word as typed", () => {
    const cmd = `gh pr create --title "Area check: t.ts: proceed" --body "$(cat <<'EOF'\nCloses #1\n\nit's done\nEOF\n)"`
    const gh = last(cmd)
    expect(gh?.words[6]).toBe("$(cat <<'EOF'\n)")
    expect(gh?.derived?.[6]).toEqual({ text: "Closes #1\n\nit's done", commands: [{ words: ['cat', '<<EOF'], heredocs: [{ word: 1, body: "Closes #1\n\nit's done", quoted: true }], substitution: true }] })
    // The title holds no substitution, so it has no derived text: a guard reads it as typed.
    expect(gh?.derived?.[4]).toBe(null)
    expect(gh?.derived?.length).toBe(gh?.words.length)
    // The cat the substitution runs is fed its body too.
    expect(pipeline(cmd)[0]).toEqual({ words: ['cat', '<<EOF'], heredocs: [{ word: 1, body: "Closes #1\n\nit's done", quoted: true }], substitution: true })
  })
  test('a here string, an unquoted heredoc holding no expansion, text around it and backticks are read too', () => {
    expect(last(`gh pr create --body "$(cat <<< 'one two')"`)?.derived?.[4]).toMatchObject({ text: 'one two' })
    expect(last(`gh pr create --body "$(cat <<EOF\ncosts \\$5\nEOF\n)"`)?.derived?.[4]).toMatchObject({ text: 'costs $5' })
    expect(last(`echo "Body: $(cat <<<x)!"`)?.derived?.[1]).toMatchObject({ text: 'Body: x!' })
    expect(last("echo \"`cat <<'EOF'\nb\nEOF\n`\"")?.derived?.[1]).toMatchObject({ text: 'b' })
    // Unquoted, a single word the shell neither splits nor matches against files.
    expect(last('echo $(cat <<<ab)')?.derived?.[1]).toMatchObject({ text: 'ab' })
  })
  test('a nested substitution is resolved through the one inside it, and its commands are given', () => {
    const d = last(`gh pr create --body "$(cat <<< "$(cat <<'EOF'\ninner\nEOF\n)")"`)?.derived?.[4]
    expect(d).toMatchObject({ text: 'inner' })
    expect(d?.commands.map(c => c.words)).toEqual([['cat', '<<EOF'], ['cat', '<<<', "$(cat <<'EOF'\n)"]])
    const bad = last(`gh pr create --body "$(cat <<< "$(git log -1)")"`)?.derived?.[4]
    expect(bad && 'unresolved' in bad).toBe(true)
    expect(bad?.commands.map(c => c.words)).toEqual([['git', 'log', '-1'], ['cat', '<<<', '$(git log -1)']])
  })
  test('what the reader cannot know is unresolved, with why, and never given as text', () => {
    const unresolved = (cmd: string, at: number) => {
      const d = last(cmd)?.derived?.[at]
      return d && 'unresolved' in d && typeof d.unresolved === 'string' && d.unresolved.length > 0 && !('text' in d) ? 'unresolved' : JSON.stringify(d)
    }
    const cases: [string, number][] = [
      ['gh pr create --body "$(git log -1 --format=%B)"', 4],
      ['gh pr create --body "$(cat notes.md)"', 4],
      ['gh pr create --body "$(cat -n <<<x)"', 4],
      ['gh pr create --body "$(cat <<EOF\nhi $USER\nEOF\n)"', 4],
      ['gh pr create --body "$(cat <<< "$X")"', 4],
      ['gh pr create --body "$(cat <<<x)$(date)"', 4],
      ['gh pr create --body "$(cat <<<x; echo y)"', 4],
      ['gh pr create --body "$(cat <<<x | tr a b)"', 4],
      ['diff <(cat <<<x) b', 1],
      // Arithmetic of a variable; a sum of whole numbers is worked out since #3088.
      ['echo $((N + 2))', 1],
      ["echo $(cat <<<'a b')", 1],
    ]
    for (const [cmd, at] of cases) expect(`${cmd} => ${unresolved(cmd, at)}`).toBe(`${cmd} => unresolved`)
    expect(last('gh pr create --body "$(git log -1)"')?.derived?.[4]).toMatchObject({ commands: [{ words: ['git', 'log', '-1'], substitution: true }] })
  })
  test('a command with no substitution in any word carries no derived text', () => {
    expect(last(`gh pr create --title t --body 'plain $(x)'`)?.derived).toBeUndefined()
  })
  test("an unquoted heredoc's substitutions inside a substitution are read once", () => {
    expect(pipeline('x="$(cat <<EOF\n$(git push)\nEOF\n)"').filter(c => c.substitution).map(c => c.words)).toEqual([['git', 'push'], ['cat', '<<EOF']])
  })
  // Lessons review of #2165: a substitution that never closes was read to the end of the text left
  // once the heredoc lines were dropped, which stops before them, so a body read nowhere else lost
  // every command it runs. Where the reader cannot place the body it keeps its commands, and the
  // word stays unresolved.
  const ran = (cmd: string) => pipeline(cmd).map(c => c.words.join(' '))
  test('a heredoc inside a substitution that never closes still gives what its body runs', () => {
    expect(ran('echo $(cat <<EOF\n$(git push)\nEOF')).toContain('git push')
    expect(ran('echo "$(cat <<EOF\n$(git push)\nEOF')).toContain('git push')
    const d = last('echo $(cat <<EOF\n$(git push)\nEOF')?.derived?.[1]
    expect(d && 'unresolved' in d).toBe(true)
    expect(d?.commands.map(c => c.words.join(' '))).toContain('git push')
  })
  test('a substitution nested in that body, or one never closed inside it, is read too', () => {
    expect(ran('echo $(cat <<EOF\n$(echo $(git push))\nEOF')).toContain('git push')
    expect(ran('echo $(echo $(cat <<EOF\n$(git push)\nEOF')).toContain('git push')
    expect(ran('echo $(cat <<EOF\n$(cat <<END\n$(git push)\nEND\n)\nEOF')).toContain('git push')
  })
  test('a heredoc whose body stands past the end of the substitution it opens in still gives what the body runs', () => {
    // The removed lines stand after the ) that closes the substitution, so they are at a place past
    // its end and were put back nowhere.
    expect(ran('echo $(cat <<EOF)\n$(git push)\nEOF')).toContain('git push')
    expect(ran('echo "$(cat <<EOF)" ok\n`git push`\nEOF')).toContain('git push')
    // bash 3.2 ends that heredoc at the ) and runs the lines after it as commands, so they are read
    // as commands as well as a body, whichever the delimiter.
    expect(ran('echo $(cat <<EOF)\ngit push\nEOF')).toContain('git push')
    expect(ran("echo $(cat <<'EOF')\ngit push\nEOF")).toContain('git push')
    const d = last('echo $(cat <<EOF)\n$(git push)\nEOF')?.derived?.[1]
    expect(d && 'unresolved' in d).toBe(true)
  })
  test('a quoted heredoc in an unclosed substitution keeps its body as text, so nothing in it runs', () => {
    expect(ran("echo $(cat <<'EOF'\n$(git push)\nEOF")).not.toContain('git push')
  })
})

// #2407: a # where a word would begin starts a comment to the end of the line, as the shell reads it,
// so a script's comment lines are no commands and an apostrophe in one opens no quote. A # inside a
// word or quotes (a#b, ${#x}, $#, "c#d") stays text.
describe('comments (#2407)', () => {
  test('a comment line, or the rest of a line after a #, is no command, and its apostrophe opens no quote', () => {
    expect(commands("# it's a comment\necho x")).toEqual([['echo', 'x']])
    expect(commands("echo x # it's a comment\nls")).toEqual([['echo', 'x'], ['ls']])
    expect(commands('echo a;# c\nls')).toEqual([['echo', 'a'], ['ls']])
    expect(commands('(# c\nls)')).toEqual([['('], ['ls'], [')']])
  })
  test('a # inside a word or quotes stays text', () => {
    expect(commands("echo a#b ${#x} $# \"c#d\" 'e#f' \\#g")).toEqual([['echo', 'a#b', '${#x}', '$#', 'c#d', 'e#f', '#g']])
  })
  test("a shell's script, from a heredoc or -c, is read without its comments and its #! line", () => {
    expect(commands("bash <<'D'\n#!/bin/bash\n# it's read only\ngrep -n x \"$1\" # don't write\nD")).toEqual([['grep', '-n', 'x', '$1']])
    expect(commands("bash -c '# c\necho y'")).toEqual([['echo', 'y']])
  })
  test('a heredoc opener in a comment opens no heredoc, so the lines after it are still read as commands', () => {
    expect(commands('# cat <<EOF is how\necho a\nEOF\nls')).toEqual([['echo', 'a'], ['EOF'], ['ls']])
    // One outside the comment on the same line still opens its heredoc.
    expect(commands("cat <<'EOF' # it's text\nbody\nEOF\nls")).toEqual([['cat', '<<EOF'], ['ls']])
  })
})

// #2619: a function whose first command is on the line that names it (`w(){ sed ...; }`,
// `w() { ...`, `w()( ... )`, `function w { ...`) was read as one command named for the function with
// the body's words as its own, so what the body ran was no command and a write in it was no write.
// The words naming a function are now a command of their own, and its body the commands it holds, as
// a body starting on the next line always was.
describe('a function defined on one line (#2619)', () => {
  const fed = (cmd: string) => pipeline(cmd).map(c => [c.words[0], c.pipedFrom?.[0]])
  test('the words naming a function are a command of their own, and its body is the commands it holds', () => {
    expect(commands("w(){ sed -i '' s/a/b/ f.ts; }; w")).toEqual([['w()'], ['sed', '-i', '', 's/a/b/', 'f.ts'], ['}'], ['w']])
    expect(commands('w() { git push; }')).toEqual([['w()'], ['git', 'push'], ['}']])
    expect(commands('w()( git push )')).toEqual([['w()'], ['('], ['git', 'push'], [')']])
    expect(commands('fix-all(){ git push; }; fix-all')).toEqual([['fix-all()'], ['git', 'push'], ['}'], ['fix-all']])
    expect(commands('function w { git push; }')).toEqual([['function', 'w'], ['git', 'push'], ['}']])
    expect(commands('function w() { git push; }')).toEqual([['function', 'w()'], ['git', 'push'], ['}']])
    expect(commands('function w(){ git push; }')).toEqual([['function', 'w()'], ['git', 'push'], ['}']])
  })
  test('one defined after a reserved word, a separator or a new line is read the same way', () => {
    expect(commands('if true; then w(){ git push; }; fi')).toEqual([['true'], ['w()'], ['git', 'push'], ['}'], ['fi']])
    expect(commands('true && w() { git push; }')).toEqual([['true'], ['w()'], ['git', 'push'], ['}']])
    expect(commands('echo a\nfunction w { git push; }\nw')).toEqual([['echo', 'a'], ['function', 'w'], ['git', 'push'], ['}'], ['w']])
  })
  test('a body starting on the next line is the commands it holds too, and a name spaced from its parentheses reads as before', () => {
    expect(commands('w() {\n  git push\n}\nw')).toEqual([['w()'], ['git', 'push'], ['}'], ['w']])
    expect(commands('w()\n{\n  git push\n}')).toEqual([['w()'], ['git', 'push'], ['}']])
    expect(commands('function w {\n  git push\n}')).toEqual([['function', 'w'], ['git', 'push'], ['}']])
    expect(commands('w () { git push; }')).toEqual([['w'], ['('], [')'], ['git', 'push'], ['}']])
    expect(commands('function w () { git push; }')).toEqual([['function', 'w'], ['('], [')'], ['git', 'push'], ['}']])
  })
  test('a word holding () that names no function, or the word function as an argument, is left as it was', () => {
    expect(commands('echo w() x')).toEqual([['echo', 'w()', 'x']])
    expect(commands('grep function w.sh')).toEqual([['grep', 'function', 'w.sh']])
    expect(commands('x=()')).toEqual([])
    expect(commands('echo $(w) "w()" w\\(\\)')).toEqual([['w'], ['echo', '$(w)', 'w()', 'w()']])
  })
  test("the body's braces are a group of their own, so its closing brace takes no feed from the group around it", () => {
    expect(fed('curl x | while read l; do w() { cat; }; sh; done')).toEqual([['curl', undefined], ['read', 'curl'], ['w()', 'curl'], ['cat', 'curl'], ['}', undefined], ['sh', 'curl'], ['done', undefined]])
  })
})

// #3021: what the reader gave no word for. setsid, flock, ionice and arch only run the command after
// them and were read as the command (the lessons review of PR #3008: `setsid cp a "$like"` wrote
// nothing); a `[[ ]]` test was split at its && and ||, so `[[ -z "$repo" || "$repo" == --* ]]` gave
// a command named `$repo`, which the design round guard rewrote the text to avoid (#2924); a trap's
// text was a word, never the commands it runs; and eval, an alias, ssh and a command a value names
// were given as their words with nothing saying that what they run cannot be read.
describe('commands: runners, tests, traps and what cannot be read (#3021)', () => {
  const EVAL = 'run as text by eval, so what it runs cannot be read'
  const NAMED = 'named by a value the shell expands, so what it runs cannot be read'
  const ALIAS = 'setting an alias, which changes what a later word runs, so that cannot be read'
  const TRAP = 'setting a trap whose text the shell expands, so what it runs later cannot be read'
  const SSH = 'run by ssh on another machine, so what it does cannot be read'
  const unreads = (cmd: string) => pipeline(cmd).map(c => c.unread)

  test('setsid, flock, ionice and arch run the command after them, each read by its own options', () => {
    expect(commands('setsid cp a b')).toEqual([['cp', 'a', 'b']])
    expect(commands('setsid -f --wait git push')).toEqual([['git', 'push']])
    expect(commands('flock /tmp/x.lock git push')).toEqual([['git', 'push']])
    expect(commands('flock -n -w 5 /tmp/x.lock rm -rf x')).toEqual([['rm', '-rf', 'x']])
    expect(commands('flock --timeout 5 -E 3 /tmp/x.lock rm x')).toEqual([['rm', 'x']])
    expect(commands(`flock /tmp/x.lock -c 'git push && rm x'`)).toEqual([['git', 'push'], ['rm', 'x']])
    expect(commands(`flock -x /tmp/x.lock --command 'git push'`)).toEqual([['git', 'push']])
    expect(commands('ionice -c 3 -n 7 cp a b')).toEqual([['cp', 'a', 'b']])
    expect(commands('ionice -c3 --classdata 7 cp a b')).toEqual([['cp', 'a', 'b']])
    expect(commands('arch -x86_64 git push')).toEqual([['git', 'push']])
    expect(commands('arch -arch arm64e -e FOO=1 -d BAR git push')).toEqual([['git', 'push']])
    expect(commands('sudo setsid nice flock /tmp/l arch -arm64 rm x')).toEqual([['rm', 'x']])
  })
  test('one of them with no command to run is the command itself', () => {
    expect(commands('setsid')).toEqual([['setsid']])
    expect(commands('flock -n 9')).toEqual([['flock', '-n', '9']])
    expect(commands('ionice -p 89 91')).toEqual([['ionice', '-p', '89', '91']])
    expect(commands('arch')).toEqual([['arch']])
    expect(commands('arch -arch')).toEqual([['arch', '-arch']])
  })

  test('a [[ ]] test is one command, its && and || and parentheses words of it', () => {
    expect(commands('[[ -z "$repo" || "$repo" == --* ]] && exit 1')).toEqual([['[[', '-z', '$repo', '||', '$repo', '==', '--*', ']]'], ['exit', '1']])
    expect(commands('if [[ -n "$a" && ( "$b" == x || "$c" == y ) ]]; then git push; fi')).toEqual([['[[', '-n', '$a', '&&', '(', '$b', '==', 'x', '||', '$c', '==', 'y', ')', ']]'], ['git', 'push'], ['fi']])
    expect(commands('true && ! [[ a||b ]]; x')).toEqual([['true'], ['[[', 'a', '||', 'b', ']]'], ['x']])
    expect(commands('[[ $x =~ ^(a|b)&$ ]] || y')).toEqual([['[[', '$x', '=~', '^(a|b)&$', ']]'], ['y']])
    expect(unreads('[[ -z "$repo" || "$repo" == --* ]]')).toEqual([undefined])
  })
  test('a ]] in quotes or in a substitution ends no test, and what a substitution in one runs is still read', () => {
    expect(commands('[[ "$(x || y)" == "]]" || -z $a ]] || z')).toEqual([['x'], ['y'], ['[[', '$(x || y)', '==', ']]', '||', '-z', '$a', ']]'], ['z']])
  })
  test('a [[ that is no test, or one not followed to its ]] on the line, is read as before', () => {
    expect(commands('echo [[ a || b ]]')).toEqual([['echo', '[[', 'a'], ['b', ']]']])
    expect(commands('[[a || b ]]')).toEqual([['[[a'], ['b', ']]']])
    expect(commands('[[ a || b\nc ]]')).toEqual([['[[', 'a'], ['b'], ['c', ']]']])
    expect(commands('[[ a ; b || c ]]')).toEqual([['[[', 'a'], ['b'], ['c', ']]']])
    expect(commands('[[ a || b')).toEqual([['[[', 'a'], ['b']])
  })

  test("a trap's text is read as the commands it runs, after the rest of what its shell runs", () => {
    expect(commands(`trap 'rm -f "$tmp"' EXIT; make`)).toEqual([['trap', 'rm -f "$tmp"', 'EXIT'], ['make'], ['rm', '-f', '$tmp']])
    expect(unreads(`trap 'rm -f "$tmp"' EXIT; make`)).toEqual([undefined, undefined, undefined])
    expect(commands(`trap 'git push; rm x' INT TERM`)).toEqual([['trap', 'git push; rm x', 'INT', 'TERM'], ['git', 'push'], ['rm', 'x']])
    expect(commands(`bash -c "trap 'git push' EXIT; make"; ls`)).toEqual([['trap', 'git push', 'EXIT'], ['make'], ['git', 'push'], ['ls']])
    expect(commands(`(cd sub; trap 'rm x' EXIT; make); ls`)).toEqual([['('], ['cd', 'sub'], ['trap', 'rm x', 'EXIT'], ['make'], ['rm', 'x'], [')'], ['ls']])
    expect(commands(`trap 'trap "git push" EXIT' INT`)).toEqual([['trap', 'trap "git push" EXIT', 'INT'], ['trap', 'git push', 'EXIT'], ['git', 'push']])
  })
  test('trap -- text is the text after the --, never the -- itself', () => {
    expect(commands(`trap -- 'git push' EXIT`)).toEqual([['trap', '--', 'git push', 'EXIT'], ['git', 'push']])
    expect(commands('trap -- - EXIT')).toEqual([['trap', '--', '-', 'EXIT']])
  })
  test('a trap that lists, resets or ignores runs nothing', () => {
    for (const cmd of ['trap', 'trap -p', 'trap -l', 'trap - EXIT', `trap '' HUP`, 'trap EXIT', 'trap 2 INT', `trap ' ' INT`]) expect(pipeline(cmd)).toHaveLength(1)
    expect(unreads('trap - EXIT')).toEqual([undefined])
  })
  test('a trap whose text the shell expands is read as written, and is unread', () => {
    expect(pipeline(`trap "rm -f $tmp" EXIT`).map(c => [c.words, c.unread])).toEqual([[['trap', 'rm -f $tmp', 'EXIT'], TRAP], [['rm', '-f', '$tmp'], undefined]])
    expect(unreads('trap "$cleanup" EXIT')[0]).toBe(TRAP)
    expect(unreads('trap "$(mk)" EXIT')).toContain(TRAP)
    expect(unreads(`find . -exec trap "$X" EXIT ';'`)).toContain(TRAP)
  })

  test('eval is unread, whatever its text, and so is one behind builtin or command', () => {
    expect(pipeline('eval "$x"')[0]).toMatchObject({ words: ['eval', '$x'], unread: EVAL })
    expect(unreads(`eval 'git push'`)).toEqual([EVAL])
    expect(pipeline('builtin eval "$x"')[0]).toMatchObject({ words: ['builtin', 'eval', '$x'], unread: EVAL })
    expect(unreads('command eval "$x"')).toEqual([EVAL])
    expect(unreads(`bash -c 'eval "$x"'`)).toEqual([EVAL])
    expect(unreads('eval')).toEqual([undefined])
    expect(unreads('echo eval x')).toEqual([undefined])
  })
  test('a command named by a value the shell expands is unread', () => {
    expect(pipeline('"$@"')[0]).toMatchObject({ words: ['$@'], unread: NAMED })
    expect(unreads('$cmd --write x')).toEqual([NAMED])
    expect(unreads('sudo "$TOOL" x')).toEqual([NAMED])
    expect(unreads('"${TOOL:-/usr/bin/rm}" x')).toEqual([NAMED])
    expect(unreads('"$DIR/$tool" x')).toEqual([NAMED])
    expect(pipeline('$(command -v fixer) x').map(c => c.unread)).toEqual([undefined, NAMED])
    expect(unreads('`which fixer` x')).toContain(NAMED)
    expect(unreads('<(echo x)')).toContain(NAMED)
    // A shell's -c text the outer shell expands is the command `$FIX`, and one it leaves is too.
    expect(unreads('bash -c "$FIX"')).toEqual([NAMED])
    expect(unreads(`bash -c '$FIX'`)).toEqual([NAMED])
    expect(unreads(`xargs "$CMD"`)).toEqual([NAMED])
    expect(pipeline(`find . -exec "$CMD" {} ';'`).map(c => c.unread)).toEqual([undefined, NAMED])
  })
  test('one whose name is spelled after the value, or whose $ is text, is named as any path names one', () => {
    expect(unreads('"$HOME/bin/tool" x')).toEqual([undefined])
    expect(unreads('"$(brew --prefix)/bin/git" push')).toEqual([undefined, undefined])
    expect(unreads(`'$x' a`)).toEqual([undefined])
    expect(unreads('\\$x a')).toEqual([undefined])
    expect(unreads('X=$(date) make')).toEqual([undefined, undefined])
    expect(unreads('arr[$i]=x')).toEqual([undefined])
    expect(unreads('n+=$i')).toEqual([undefined])
  })
  test('a bare value before the name is unread where the shell splits it into words, as bash does', () => {
    expect(unreads(`bash -c '$PREFIX/bin/tool x'`)).toEqual([NAMED])
    expect(unreads(`zsh -c '$PREFIX/bin/tool x'`)).toEqual([undefined])
    expect(unreads(`bash -c '"$PREFIX/bin/tool" x'`)).toEqual([undefined])
  })
  test('a value inside arithmetic names no command', () => {
    expect(pipeline('(( $# < 2 )) && exit 1').some(c => c.unread)).toBe(false)
    expect(pipeline('for ((i=0; $i<3; i++)); do echo x; done').some(c => c.unread)).toBe(false)
    // Two subshells are not arithmetic.
    expect(unreads('( ( $cmd ) )')).toContain(NAMED)
  })
  test('setting an alias is unread, listing one is not', () => {
    expect(pipeline(`alias gp='git push'`)[0]).toMatchObject({ words: ['alias', 'gp=git push'], unread: ALIAS })
    expect(unreads('builtin alias ll="ls -l"')).toEqual([ALIAS])
    expect(unreads('alias')).toEqual([undefined])
    expect(unreads('alias -p')).toEqual([undefined])
    expect(unreads('alias gp')).toEqual([undefined])
  })
  test('ssh runs its command on another machine, so it is unread and never read as run here', () => {
    expect(pipeline('ssh host rm -rf x')[0]).toMatchObject({ words: ['ssh', 'host', 'rm', '-rf', 'x'], unread: SSH })
    expect(unreads('/usr/bin/ssh -p 22 host')).toEqual([SSH])
    expect(unreads('sudo ssh host ls')).toEqual([SSH])
    expect(unreads('echo ssh host')).toEqual([undefined])
  })
  test("a mark rtk's proxy gave stands, and every other command of the line carries none", () => {
    const proxy = 'split by rtk proxy from one word the shell expands, so what it runs cannot be read'
    expect(unreads('rtk proxy "$CMD"')).toEqual([proxy])
    expect(unreads('ls; eval "$x"; git status')).toEqual([undefined, EVAL, undefined])
  })
})

// #3070: `$[...]` is the old arithmetic expansion of bash and zsh (measured 2026-11-16 on bash 3.2,
// zsh and sh: `"x\\$[0-9]"` is handed on as `x\-9`). The reader knew `$((...))` and not this, so a
// search pattern holding one was read as holding a variable's value. A word whose only expansions
// are such sums of whole numbers is given as those shells hand it on (`worked`), beside the word as
// typed, which is what dash and ksh hand on (measured: to them `$[` is text).
describe('pipeline: old arithmetic, $[...] (#3070)', () => {
  const last = (cmd: string) => pipeline(cmd).filter(c => !c.substitution).pop()
  const worked = (cmd: string) => last(cmd)?.worked
  test('a word whose only expansions are sums of whole numbers is given as bash and zsh hand it on', () => {
    expect(worked(String.raw`python3 s.py "x\\$[0-9]" "a$[1 + 2]b" x$[3]y "$[2 * 3 - 10]" "$[-4*2]" "\$5 $[1+1]"`)).toEqual([null, null, String.raw`x\-9`, 'a3b', 'x3y', '-4', '-8', '$5 2'])
    // The words stay as typed.
    expect(last(String.raw`python3 s.py "x\\$[0-9]"`)?.words).toEqual(['python3', 's.py', String.raw`x\$[0-9]`])
  })
  test('a word the reader does not work out, or holding any other expansion, is given none', () => {
    // A name, a number bash reads as octal and zsh as ten, a division, a bracket inside, a
    // substitution, another expansion beside it, one never closed, an empty one, two signs, a sum
    // past what a shell counts to, and one in single quotes or escaped.
    for (const word of ['"$[N + 1]"', '"$[010 + 1]"', '"$[7 / 2]"', '"$[1 + [2]]"', '"$[ $(echo 4) + 1 ]"', '"$N$[1]"', '"$[1]$(x)"', '"$[1"', '"$[]"', '"$[1 - -2]"', '"$[9223372036854775807 + 1]"', `'$[1]'`, '"\\$[1]"'])
      expect({ word, worked: worked(`python3 s.py ${word}`) }).toEqual({ word, worked: undefined })
  })
  test('it is never left as written, and its text is derived as arithmetic is', () => {
    expect(last(`python3 s.py "x$[1+1]" '$[1]'`)?.unexpanded).toEqual([false, false, false, true])
    expect(last('python3 s.py "\\$5 $[1+1]"')?.unexpanded).toBeUndefined()
    expect(last('echo "x$[1+1]"')?.derived).toEqual([null, { text: 'x2', commands: [] }])
    expect(last('echo "$[N+1]"')?.derived?.[1]).toEqual({ unresolved: 'it is arithmetic, which this reader does not work out', commands: [] })
  })
  test('a substitution inside it is still read as run', () => {
    const all = pipeline('echo "$[ $(git push) + 1 ]"')
    expect(all[0]).toMatchObject({ words: ['git', 'push'], substitution: true })
    expect(all[1]?.derived?.[1]).toMatchObject({ unresolved: 'it is arithmetic, which this reader does not work out', commands: [{ words: ['git', 'push'] }] })
  })
  test('outside quotes one holding a blank or a redirect is read word by word, as dash and ksh run it', () => {
    expect(commands('echo $[1 > 2]')).toEqual([['echo', '$[1', '>', '2]']])
    expect(worked('echo $[1 + 2]')).toBeUndefined()
  })
})

// #3088: `$((...))` is arithmetic in every shell (measured 2026-11-16 on bash 3.2, zsh 5.9 and macOS
// sh: `"a|\\$((0-9))"` is handed on as `a|\-9`), so a sum of whole numbers in one is worked out as
// a `$[...]` one is (#3070). Unlike `$[`, no shell hands it on as typed.
describe('pipeline: arithmetic, $((...)) (#3088)', () => {
  const last = (cmd: string) => pipeline(cmd).filter(c => !c.substitution).pop()
  const worked = (cmd: string) => last(cmd)?.worked
  test('a word whose only expansions are sums of whole numbers is given as the shell hands it on', () => {
    expect(worked(String.raw`python3 s.py "a|\\$((0-9)),[0-9]{3}|b" "x$(( 1 + 2 ))y" $((2*3)) "$[1]$((1))"`)).toEqual([null, null, String.raw`a|\-9,[0-9]{3}|b`, 'x3y', '6', '11'])
    expect(last(String.raw`python3 s.py "a|\\$((0-9))"`)?.words).toEqual(['python3', 's.py', String.raw`a|\$((0-9))`])
    expect(last('echo "x$((1+1))"')?.derived).toEqual([null, { text: 'x2', commands: [] }])
  })
  test('one the reader does not work out, or holding any other expansion, is given none, and read as before', () => {
    for (const word of ['"$((N + 1))"', '"$((010 + 1))"', '"$((7 / 2))"', '"$(( (1) + 2 ))"', '"$(( $(echo 4) + 1 ))"', '"$N$((1))"', '"$((1"', '"$(())"', `'$((1))'`, '"\\$((1))"', '$((1 << 2))'])
      expect({ word, worked: worked(`python3 s.py ${word}`) }).toEqual({ word, worked: undefined })
    expect(last('echo "$((N+1))"')?.derived?.[1]).toEqual({ unresolved: 'it is arithmetic, which this reader does not work out', commands: [] })
    const all = pipeline('echo "$(( $(git push) + 1 ))"')
    expect(all[0]).toMatchObject({ words: ['git', 'push'], substitution: true })
    // A command substitution opening a subshell is still one: what it runs is read.
    expect(commands('echo $( (git push) )')).toContainEqual(['git', 'push'])
  })
})

// #3093: a setting written in front of a command (`TMPDIR=x bash s.sh`, `env TMPDIR=x bash s.sh`)
// was dropped, so no guard could see the environment a command gives a script it runs. Each command
// carries them as `env`, in the order written, and a shell's script inherits its shell's.
describe('pipeline: the settings written in front of a command (#3093)', () => {
  const envs = (cmd: string) => pipeline(cmd).map(c => [c.words[0], c.env])
  test('an assignment before the command, or given to env, sudo or another runner, is carried', () => {
    expect(envs('TMPDIR=payload/mods bash tools/check-mods.sh payload/mods')).toEqual([['bash', ['TMPDIR=payload/mods']]])
    expect(envs('env TMPDIR=x bash tools/check-mods.sh payload/mods')).toEqual([['bash', ['TMPDIR=x']]])
    expect(envs('A=1 env -i B=2 C=3 bash s.sh')).toEqual([['bash', ['A=1', 'B=2', 'C=3']]])
    expect(envs('sudo -u dan FOO=1 make')).toEqual([['make', ['FOO=1']]])
    expect(envs(`env -S 'FOO=1 git push'`)).toEqual([['git', ['FOO=1']]])
    expect(envs('X=1 nohup timeout 5 make')).toEqual([['make', ['X=1']]])
  })
  test("a shell's script, and what xargs or a find -exec runs, inherit it", () => {
    expect(envs(`X=1 bash -c 'Y=2 make; ls'`)).toEqual([['make', ['X=1', 'Y=2']], ['ls', ['X=1']]])
    expect(envs('FOO=1 xargs rm < list')).toEqual([['rm', ['FOO=1']]])
    expect(envs('FOO=1 find . -exec rm {} \\;')).toEqual([['find', ['FOO=1']], ['rm', ['FOO=1']]])
  })
  test('a command given none carries none: an argument, another command of the line, a substitution', () => {
    expect(envs('bash s.sh x=1')).toEqual([['bash', undefined]])
    expect(envs('git log --format=%s')).toEqual([['git', undefined]])
    expect(envs('F=x; bash s.sh')).toEqual([['bash', undefined]])
    expect(envs('FOO=1 ls | wc -l; make')).toEqual([['ls', ['FOO=1']], ['wc', undefined], ['make', undefined]])
    expect(envs('FOO=1 echo $(git status)')).toEqual([['git', undefined], ['echo', ['FOO=1']]])
    // A double quoted script's substitution is run by the shell reading the line, before bash starts;
    // the reader also reads it as bash's script holds it, so it is given both ways.
    expect(envs('FOO=1 bash -c "echo $(git status)"')).toEqual([['git', undefined], ['git', ['FOO=1']], ['echo', ['FOO=1']]])
    // In a shell's own script the substitution is run by that shell, so it has the shell's settings.
    expect(envs(`FOO=1 bash -c 'echo $(git status)'`)).toEqual([['git', ['FOO=1']], ['echo', ['FOO=1']]])
  })
  test('the commands only setting variables are given as before, carrying none', () => {
    expect(pipeline('F=x; bash s.sh', { assignments: true }).map(c => [c.words, c.env])).toEqual([[['F=x'], undefined], [['bash', 's.sh'], undefined]])
  })
})

// #3093: the reader looks past the words that only run a command (`env -C copy bash s.sh` is read
// as `bash s.sh`), and past a shell to the script it is given. Each can change the folder or the
// environment the command runs in with no setting written (`env -C`, `env -i`, `env -u`, `sudo`,
// a login shell), so a guard that knows a script by its plain run could not tell it from one behind
// a runner. Each command says what it is run behind, in order, and a shell's script inherits it.
describe('pipeline: what a command is run behind (#3093)', () => {
  const behind = (cmd: string) => pipeline(cmd).map(c => [c.words[0], c.behind])
  test('each runner looked past is named, in the order written, by its name alone', () => {
    expect(behind('env -C copy bash s.sh d')).toEqual([['bash', ['env']]])
    expect(behind('env -i bash s.sh d')).toEqual([['bash', ['env']]])
    expect(behind('env -u TMPDIR bash s.sh d')).toEqual([['bash', ['env']]])
    expect(behind('env --chdir=copy bash s.sh d')).toEqual([['bash', ['env']]])
    expect(behind('/usr/bin/env -P /x bash s.sh d')).toEqual([['bash', ['env']]])
    expect(behind(`env -S 'bash s.sh d'`)).toEqual([['bash', ['env']]])
    expect(behind('sudo -u dan nohup nice -n 5 timeout 5 bash s.sh d')).toEqual([['bash', ['sudo', 'nohup', 'nice', 'timeout']]])
    expect(behind('exec bash s.sh d')).toEqual([['bash', ['exec']]])
    expect(behind('command bash s.sh d')).toEqual([['bash', ['command']]])
    expect(behind('time bash s.sh d')).toEqual([['bash', ['time']]])
    expect(behind('ls | xargs bash s.sh')).toEqual([['ls', undefined], ['bash', ['xargs']]])
    expect(behind('rtk git status')).toEqual([['git', ['rtk']]])
    expect(behind('rtk proxy git status')).toEqual([['git', ['rtk']]])
    expect(behind('flock /tmp/l bash s.sh d')).toEqual([['bash', ['flock']]])
  })
  test("a shell's script is run behind that shell, after what the shell itself is behind, and so is what find runs", () => {
    expect(behind(`bash -c 'bash s.sh d'`)).toEqual([['bash', ['bash']]])
    expect(behind(`bash -lc 'make; ls'`)).toEqual([['make', ['bash']], ['ls', ['bash']]])
    expect(behind(`sudo zsh -c 'env make'`)).toEqual([['make', ['sudo', 'zsh', 'env']]])
    expect(behind("bash <<'EOF'\nmake\nEOF")).toEqual([['make', ['bash']]])
    expect(behind(`flock /tmp/l -c 'make'`)).toEqual([['make', ['flock', 'sh']]])
    expect(behind(`bash -c 'echo $(git status)'`)).toEqual([['git', ['bash']], ['echo', ['bash']]])
    expect(behind('find . -exec rm {} \\;')).toEqual([['find', undefined], ['rm', ['find']]])
  })
  test('a command typed as it runs is behind nothing: a reserved word, a cd, a pipe, a setting, a runner that is the command', () => {
    expect(behind('bash s.sh d')).toEqual([['bash', undefined]])
    expect(behind('! bash s.sh d')).toEqual([['bash', undefined]])
    expect(behind('cd copy && bash s.sh d | tail -n 40')).toEqual([['cd', undefined], ['bash', undefined], ['tail', undefined]])
    expect(behind('TMPDIR=x bash s.sh d')).toEqual([['bash', undefined]])
    expect(behind('sudo ls; bash s.sh d')).toEqual([['ls', ['sudo']], ['bash', undefined]])
    expect(behind('env')).toEqual([['env', undefined]])
    expect(behind('command -v bash')).toEqual([['command', undefined]])
    expect(behind('echo $(env true)')).toEqual([['true', ['env']], ['echo', undefined]])
  })
})

// #3022: a backslash before a new line joins the two lines, as every shell reads it (measured
// 2026-11-16 on bash, zsh and dash). The reader took the pair for a word holding a new line, so the
// copy step of tools/check-mods.sh was read as removing a file of that name.
describe('a backslash before a new line joins the two lines (#3022)', () => {
  test('outside quotes it is no word, and ends none', () => {
    expect(commands('cp -R a \\\n  b')).toEqual([['cp', '-R', 'a', 'b']])
    expect(commands('rm -rf "$c/types" \\\n  && mkdir -p "$c/types" \\\n  && cp -R a "$c/types/"')).toEqual([['rm', '-rf', '$c/types'], ['mkdir', '-p', '$c/types'], ['cp', '-R', 'a', '$c/types/']])
    expect(commands('git pu\\\nsh')).toEqual([['git', 'push']])
    expect(commands('ls | \\\n wc -l')).toEqual([['ls'], ['wc', '-l']])
    expect(commands('echo $(git \\\n push)')[0]).toEqual(['git', 'push'])
  })
  test('inside double quotes it is taken out of the word, and inside single quotes it is kept', () => {
    expect(commands('echo "in do\\\nuble"')).toEqual([['echo', 'in double']])
    expect(commands("echo 'in sin\\\ngle'")).toEqual([['echo', 'in sin\\\ngle']])
  })
  test('a backslash that is itself escaped, or one ending a comment, joins nothing', () => {
    expect(commands('echo one \\\\\necho two')).toEqual([['echo', 'one', '\\'], ['echo', 'two']])
    expect(commands('echo a \\\n  # note \\\ngit push')).toEqual([['echo', 'a'], ['git', 'push']])
  })
  test('a heredoc opened on a continued line starts its body after the whole line', () => {
    const cmd = 'cat <<EOF \\\n  > out.txt\nbody\nEOF\ngit status'
    expect(commands(cmd)).toEqual([['cat', '<<EOF', '>', 'out.txt'], ['git', 'status']])
    expect(pipeline(cmd)[0]?.heredocs).toEqual([{ word: 1, body: 'body', quoted: false }])
    // A comment ending in a backslash continues nothing, so the body starts on the next line.
    expect(commands('cat <<EOF # \\\nbody\nEOF\ngit status')).toEqual([['cat', '<<EOF'], ['git', 'status']])
  })
})

// #3272: on 2026-11-19 at 1:02 AM ET sleep mode held a loop over /bin/bash and /bin/zsh that ran
// `$sh -c '<a function definition>'` eleven ways, as a command that may run the merge helper: the
// program was a variable, so no reader could say what ran. A loop whose words are written out names
// each program it runs, so the command is read once for each of them, as if typed with that name.
// Everything else a value names stays unread, and so does a loop variable anything else in the line
// could have changed.
describe('commands: a loop over programs written out names each one (#3272)', () => {
  const NAMED = 'named by a value the shell expands, so what it runs cannot be read'
  const read = (cmd: string) => pipeline(cmd).map(c => ({ words: c.words, ...(c.unread ? { unread: c.unread } : {}) }))
  const unreads = (cmd: string) => pipeline(cmd).filter(c => c.unread).map(c => [c.words[0], c.unread])
  test('the command of 2026-11-19, cut to two of its eleven: each shell runs each string', () => {
    const cmd = `for sh in /bin/bash /bin/zsh; do echo "== $sh"; $sh -c 'f() ( echo A-sub ); f' 2>&1; $sh -c 'f() echo B-plain; f' 2>&1 | head -2; done`
    expect(unreads(cmd)).toEqual([])
    // What each -c string runs, once for each shell, as a shell written by name is read.
    expect(pipeline(cmd).filter(c => c.words[0] === 'echo').map(c => [c.words.join(' '), c.behind])).toEqual([
      ['echo == $sh', undefined],
      ['echo A-sub', ['bash']],
      ['echo A-sub', ['zsh']],
      ['echo B-plain', ['bash']],
      ['echo B-plain', ['zsh']],
    ])
  })
  test('a program that is no shell is read by its name too, with the words written after it', () => {
    expect(read('for tool in gh /opt/homebrew/bin/gh; do $tool pr merge 12 --squash; done').filter(c => c.words.includes('merge'))).toEqual([
      { words: ['gh', 'pr', 'merge', '12', '--squash'] },
      { words: ['/opt/homebrew/bin/gh', 'pr', 'merge', '12', '--squash'] },
    ])
    expect(read('for sh in bash; do "${sh}" ~/.claude/hooks/lib/merge-when-ready.sh 12; done')[1]).toEqual({ words: ['bash', '~/.claude/hooks/lib/merge-when-ready.sh', '12'] })
    // Behind a runner, and in a nested loop, where the inner loop's variable names the program.
    expect(unreads('for sh in bash zsh; do nohup $sh -c "make"; done')).toEqual([])
    expect(unreads('for n in 1 2; do for sh in bash zsh; do $sh -c "make"; done; done')).toEqual([])
    // The name inside a longer word names no variable: a script ending .sh beside a variable named
    // sh, a shell at /bin/sh, the option a one letter variable shares its letter with.
    expect(read('for sh in /bin/sh /bin/bash; do $sh tests/run.sh --squash; done').slice(1, 3)).toEqual([{ words: ['/bin/sh', 'tests/run.sh', '--squash'] }, { words: ['/bin/bash', 'tests/run.sh', '--squash'] }])
    expect(unreads(`for c in bash zsh; do $c -c 'make'; done`)).toEqual([])
    // Controls for the cases below: the same lines with nothing that could change the variable.
    const plain = [
      `for sh in /bin/bash; do read line < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do printf '%s\\n' "$sh"; $sh -c 'make'; done`,
      `for sh in /bin/bash; do if [ -x "$sh" ]; then $sh -c 'make'; fi; done`,
      `for sh in /bin/bash; do [[ -x $sh ]] && $sh -c 'make'; done`,
      `for sh in /bin/bash; do ls -lt; $sh --version | head -1; done`,
      `cd /tmp/work && for sh in /bin/bash /bin/zsh; do $sh ./check.sh > "out/$sh.txt" 2>&1; done`,
      // Pattern characters the shell matches against no file: quoted whole, or after a backslash.
      `for sh in /bin/bash; do echo "== $sh (x)"; $sh -c 'f() { echo "$1" *.txt; }; f x'; done`,
      `for sh in /bin/bash; do $sh -c "ls *.txt" app/\\*x; done`,
    ]
    expect(plain.filter(cmd => unreads(cmd).length > 0)).toEqual([])
  })
  test('a value from anywhere but a loop over words written out is still unread', () => {
    const held = [
      // No loop at all, and a plain assignment, which this reading does not follow.
      `$sh -c 'make'`,
      `sh=/bin/bash; $sh -c 'make'`,
      // A list the shell fills in: a variable, a substitution, a pattern, braces, a tilde, its arguments.
      `for sh in $SHELLS; do $sh -c 'make'; done`,
      `for sh in /bin/bash $OTHER; do $sh -c 'make'; done`,
      `for sh in $(cat shells.txt); do $sh -c 'make'; done`,
      `for sh in /bin/*sh; do $sh -c 'make'; done`,
      `for sh in /bin/{bash,zsh}; do $sh -c 'make'; done`,
      `for sh in ~/bin/bash; do $sh -c 'make'; done`,
      `for sh in "$@"; do $sh -c 'make'; done`,
      `for sh; do $sh -c 'make'; done`,
      // A quoted word, whose value this reading does not work out.
      `for sh in "/bin/bash" '/bin/zsh'; do $sh -c 'make'; done`,
      // Another variable, and the loop's own outside its body.
      `for sh in /bin/bash; do $other -c 'make'; done`,
      `for sh in /bin/bash; do :; done; $sh -c 'make'`,
      `$sh -c 'make'; for sh in /bin/bash; do :; done`,
      // More than the variable alone.
      `for sh in bash; do /bin/$sh -c 'make'; done`,
      `for sh in bash; do $sh$x -c 'make'; done`,
      `for sh in bash; do \${sh:-zsh} -c 'make'; done`,
      // Another variable's value with characters quoted beside it, which reads as the loop's own
      // once the quotes are gone: the shell runs whatever `$s` holds with an h after it.
      `for sh in /bin/bash; do $s"h" -c 'make'; done`,
      `for sh in /bin/bash; do $s'h' -c 'make'; done`,
      `for sh in /bin/bash; do "$s"h -c 'make'; done`,
      `for sh in /bin/bash; do $s\\h -c 'make'; done`,
      // zsh's short loops, which close with no done.
      `for sh in /bin/bash /bin/zsh; $sh -c 'make'`,
      `for sh (/bin/bash /bin/zsh) $sh -c 'make'`,
    ]
    expect(held.filter(cmd => unreads(cmd).map(u => u[1]).join('|') !== NAMED)).toEqual([])
  })
  test('a loop variable anything else in the line could have changed is still unread', () => {
    const held = [
      // Set again by name, in the body or anywhere else in the line.
      `for sh in /bin/bash; do sh=$EVIL; $sh -c 'make'; done`,
      `for sh in /bin/bash; do sh=/tmp/x; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read sh < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read "sh" < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read s\\h < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do export sh=x; $sh -c 'make'; done`,
      `for sh in /bin/bash; do printf -v sh x; $sh -c 'make'; done`,
      `for sh in /bin/bash; do unset sh; $sh -c 'make'; done`,
      `for sh in /bin/bash; do : \${sh:=x}; $sh -c 'make'; done`,
      `swap() { sh=/tmp/x; }; for sh in /bin/bash; do swap; $sh -c 'make'; done`,
      `for sh in /bin/bash; do printf -vsh x; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read -ash < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read 'sh?name: '; $sh -c 'make'; done`,
      `for sh in /bin/bash; do exec {sh}>/dev/null; $sh -c 'make'; done`,
      `for sh in /bin/bash; do for sh in $OTHERS; do $sh -c 'make'; done; done`,
      // A value that is the variable's own name, which the variable then hands to a builtin.
      `for sh in sh bash; do read $sh < list; $sh -c 'make'; done`,
      `for name in sh; do for sh in /bin/bash; do read $name < list; $sh -c 'make'; done; done`,
      // Text run as commands by this shell, which may set anything.
      `for sh in /bin/bash; do eval "$(cat x)"; $sh -c 'make'; done`,
      `for sh in /bin/bash; do source ./env.sh; $sh -c 'make'; done`,
      `for sh in /bin/bash; do . ./env.sh; $sh -c 'make'; done`,
      `trap 'x=1' DEBUG; for sh in /bin/bash; do $sh -c 'make'; done`,
      `for sh in /bin/bash; do let x=1; $sh -c 'make'; done`,
      `for sh in /bin/bash; do (( x = 1 )); $sh -c 'make'; done`,
      `for sh in /bin/bash; do [[ x -eq 1 ]]; $sh -c 'make'; done`,
      `for sh in /bin/bash; do declare -i n=x; $sh -c 'make'; done`,
      // IFS set, which decides where bash cuts the value into words.
      `IFS=a; for sh in /bin/bash; do $sh -c 'make'; done`,
      // Any other value the shell fills in, which may be the variable's name, and a heredoc.
      `for sh in /bin/bash; do read $name < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read $a$b < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do echo $(date); $sh -c 'make'; done`,
      `for sh in /bin/bash; do echo "$HOME"; $sh -c 'make'; done`,
      `for sh in /bin/bash; do cat <<X\nhi\nX\n$sh -c 'make'; done`,
      `for sh in /bin/bash; do echo $'s\\x68'; $sh -c 'make'; done`,
      // A name put together from a loop's value and what is written beside it.
      `for p in s; do for sh in /bin/bash; do read \${p}h < list; $sh -c 'make'; done; done`,
      `for sh in /bin/bash; do echo $sh:t; $sh -c 'make'; done`,
      `for sh in /bin/bash; do echo $sh[8,9]; $sh -c 'make'; done`,
      `for p in s; do for ph in x; do for sh in /bin/bash; do read $p"h" < list; $sh -c 'make'; done; done; done`,
      // A name the shell makes from braces or by matching a file, with no value filled in.
      `for sh in /bin/bash; do read {sh,x} < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read s{h,} < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read s? < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read [s]h < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read "s"* < list; $sh -c 'make'; done`,
      // A sum that sets it, in a subscript or in a number a builtin is handed.
      `for sh in /bin/bash; do arr[sh=5]=x; $sh -c 'make'; done`,
      `for sh in /bin/bash; do read 'arr[sh=5]' < list; $sh -c 'make'; done`,
      `for sh in /bin/bash; do unset 'arr[sh++]'; $sh -c 'make'; done`,
      `for sh in /bin/bash; do printf '%d' 'x+(sh = 5)'; $sh -c 'make'; done`,
      `for sh in /bin/bash; do printf '%d' '1+(--sh)'; $sh -c 'make'; done`,
      // A value that is itself a word the shell or this reader treats as more than a program.
      `for run in eval; do $run "$x"; done`,
      `for run in env sudo; do $run make; done`,
      `for run in source; do $run ./env.sh; done`,
      `for run in if; do $run true; done`,
    ]
    expect(held.filter(cmd => !unreads(cmd).some(u => u[1] === NAMED))).toEqual([])
  })
  test('the loop, and every other command in it, is read as before', () => {
    expect(commands('for sh in /bin/bash /bin/zsh; do echo hi; done')).toEqual([['for', 'sh', 'in', '/bin/bash', '/bin/zsh'], ['echo', 'hi'], ['done']])
    // A variable that names an operand, never a program, is left as written.
    expect(commands('for f in a.txt b.txt; do cat $f; done')).toEqual([['for', 'f', 'in', 'a.txt', 'b.txt'], ['cat', '$f'], ['done']])
  })
})

// #3398 (Dan, 2026-11-22: "Follow the variable first"): a folder the call names with a variable it
// sets itself just before. Counted on both Macs, a watched git command whose folder the collision
// guard could not tell was nearly always this one form (12 of 13 past commands on one, 11 of 12 on
// the other), and each was stopped while another session was open. The reader says what such a
// word holds only where the call's own text makes it certain, and only when asked (`follow`).
describe('pipeline: a variable the call itself sets, read as its value (#3398)', () => {
  // What the folder word of the last git command in the call is read as.
  const NOT = 'not followed'
  const folder = (cmd: string): string => {
    const c = pipeline(cmd, { follow: true }).filter(x => x.words.includes('-C')).pop()
    const n = c ? c.words.indexOf('-C') + 1 : 0
    return (n > 0 ? c?.followed?.[n] : undefined) ?? NOT
  }
  // Every negative below is the same line as this one with one thing changed.
  const PLAIN = 'W=/other; git -C "$W" checkout main'
  const followedAsWritten = () => expect(folder(PLAIN)).toBe('/other')

  test('the form of the count: set once at the start of the call, used as the whole -C word', () => {
    followedAsWritten()
    expect(pipeline(PLAIN, { follow: true })).toEqual([{ words: ['git', '-C', '$W', 'checkout', 'main'], followed: [null, null, '/other', null, null] }])
    // Bare, in braces, on a line of its own, the value in quotes, and a folder under the one it runs in.
    expect(folder('W=/other; git -C $W checkout main')).toBe('/other')
    expect(folder('W=/other; git -C ${W} checkout main')).toBe('/other')
    expect(folder('W=/other; git -C "${W}" checkout main')).toBe('/other')
    expect(folder('W=/other\ngit -C "$W" checkout main')).toBe('/other')
    expect(folder('W="/other"; git -C "$W" checkout main')).toBe('/other')
    expect(folder("W='/other/wt-1.2'; git -C \"$W\" checkout main")).toBe('/other/wt-1.2')
    expect(folder('W=sub; git -C "$W" checkout main')).toBe('sub')
    // A name mixing capitals and small letters is no name a shell keeps.
    expect(folder('wtDir=/other; git -C "$wtDir" checkout main')).toBe('/other')
  })

  test('it is given only when asked for, and no word of the command is changed', () => {
    followedAsWritten()
    expect(pipeline(PLAIN)).toEqual([{ words: ['git', '-C', '$W', 'checkout', 'main'] }])
    expect(pipeline(PLAIN, { assignments: true })).toEqual([{ words: ['W=/other'], certain: true }, { words: ['git', '-C', '$W', 'checkout', 'main'] }])
    expect(pipeline(PLAIN, { follow: true }).map(c => c.words)).toEqual(pipeline(PLAIN).map(c => c.words))
    // A command with no such word carries none.
    expect(pipeline('W=/other; git status; git -C "$W" checkout main', { follow: true }).map(c => 'followed' in c)).toEqual([false, true])
  })

  test('the shapes of the past commands: other variables, a loop, a group, pipes, a substitution, xargs', () => {
    followedAsWritten()
    const past = [
      // Two set at the start, a substitution handed to git, and a pipe.
      'N=/tmp/notes\nR=/other\ngit -C $R branch -D $(cat $N/merged.txt) 2>&1 | grep -c "^Deleted"',
      // A loop over words written out between the setting and the use.
      'R=/other; for w in a b; do git -C $R worktree remove $R/wt/$w 2>/dev/null; git -C $R worktree prune && echo "removed $w"; done; git -C $R branch -D a b',
      // A second variable built from the first, which is not itself followed.
      'R=/other; W=$R/wt/x; git -C $W status --porcelain | wc -l; git -C $R worktree remove $W && echo gone; git -C $R branch -D x',
      'R=/other; git -C $R fetch -q origin main 2>/dev/null; git -C $R merge-base --is-ancestor a b && echo yes; git -C $R branch -D a',
      // A group, a script in single quotes, redirects, and the command behind xargs.
      "S=/tmp/s; R=/other; { cat $S/a.txt; awk '$2 {print $1}' $S/b.txt; } | grep -v '^$' > $S/all.txt; wc -l < $S/all.txt; xargs git -C $R branch -D < $S/all.txt | grep -c \"^Deleted branch\"",
      'R=/other; cd $R; for w in a b; do git -C $R worktree remove $R/wt-$w 2>&1 | head -2; done; git -C $R branch -D a b 2>&1 | grep -c Deleted',
    ]
    expect(past.filter(cmd => folder(cmd) !== '/other')).toEqual([])
    // The variable built from another is left as written: its value is not typed out.
    expect(folder('R=/other; W=$R/wt/x; git -C $W checkout main')).toBe(NOT)
  })

  test('set twice, or anywhere but the start of the call, it is not followed', () => {
    followedAsWritten()
    const not = [
      'W=/a; W=/other; git -C "$W" checkout main',
      'W=/a W=/other; git -C "$W" checkout main',
      'W=/other; git status; W=/b; git -C "$W" checkout main',
      'W=/other; git -C "$W" checkout main; W=/b',
      // After the use, and after another command.
      'git -C "$W" checkout main; W=/other',
      'git status; W=/other; git -C "$W" checkout main',
      // In a subshell, a function, a loop, a branch, a group.
      '(W=/other); git -C "$W" checkout main',
      '(W=/other; git -C "$W" checkout main)',
      'f() { W=/other; }; f; git -C "$W" checkout main',
      'W=/other; f() { W=/b; }; f; git -C "$W" checkout main',
      'for x in 1; do W=/other; done; git -C "$W" checkout main',
      'if true; then W=/other; fi; git -C "$W" checkout main',
      '{ W=/other; }; git -C "$W" checkout main',
      // Where what stands before or after it may skip it, or runs it in a shell of its own.
      'true && W=/other; git -C "$W" checkout main',
      'false || W=/other; git -C "$W" checkout main',
      'W=/other && git -C "$W" checkout main',
      'W=/other || true; git -C "$W" checkout main',
      'W=/other & git -C "$W" checkout main',
      'W=/other | cat; git -C "$W" checkout main',
      'W=/other # the folder\ngit -C "$W" checkout main',
      // A setting written in front of the command reaches the program, never the word.
      'W=/other git -C "$W" checkout main',
      // Set in an earlier call, or nowhere.
      'git -C "$W" checkout main',
      'V=/other; git -C "$W" checkout main',
    ]
    expect(not.filter(cmd => folder(cmd) !== NOT)).toEqual([])
  })

  test('a value that is not typed out in plain characters is not followed', () => {
    followedAsWritten()
    const not = [
      'W=$(pwd); git -C "$W" checkout main',
      'W=`pwd`; git -C "$W" checkout main',
      'W=$HOME/x; git -C "$W" checkout main',
      'W=$V; git -C "$W" checkout main',
      'W=~/x; git -C "$W" checkout main',
      'W="~/x"; git -C "$W" checkout main',
      'W="/a b"; git -C "$W" checkout main',
      'W=/a\\ b; git -C "$W" checkout main',
      'W=/a*; git -C "$W" checkout main',
      'W=/a{b,c}; git -C "$W" checkout main',
      'W=; git -C "$W" checkout main',
      'W=""; git -C "$W" checkout main',
      "W=$'/other'; git -C \"$W\" checkout main",
      'W=/oth"er"; git -C "$W" checkout main',
      'W+=/other; git -C "$W" checkout main',
      'W=(/other); git -C "$W" checkout main',
    ]
    expect(not.filter(cmd => folder(cmd) !== NOT)).toEqual([])
  })

  test('a use that is not the variable alone is not followed', () => {
    followedAsWritten()
    const not = [
      'W=/other; git -C "$W/sub" checkout main',
      'W=/other; git -C "$W"x checkout main',
      'W=/other; git -C x"$W" checkout main',
      // The shell hands these on as typed: a folder named $W.
      "W=/other; git -C '$W' checkout main",
      'W=/other; git -C \\$W checkout main',
      "W=/other; git -C $'W' checkout main",
      'W=/other; git -C "${W:-/x}" checkout main',
      'W=/other; git -C "${W%/*}" checkout main',
      'W=/other; git -C $W[1] checkout main',
      'W=/other; git -C "$W$W" checkout main',
    ]
    expect(not.filter(cmd => folder(cmd) !== NOT)).toEqual([])
  })

  test('anything else in the call that may give it another value leaves it as written', () => {
    followedAsWritten()
    const not = [
      // A builtin handed the name.
      'W=/other; read W; git -C "$W" checkout main',
      'W=/other; read -r W < list; git -C "$W" checkout main',
      'W=/other; unset W; git -C "$W" checkout main',
      'W=/other; export -n W; git -C "$W" checkout main',
      'W=/other; export W; git -C "$W" checkout main',
      'W=/other; local W; git -C "$W" checkout main',
      'W=/other; declare W; git -C "$W" checkout main',
      'W=/other; typeset -i W; git -C "$W" checkout main',
      'W=/other; printf -v W %s /x; git -C "$W" checkout main',
      'W=/other; printf -vW %s /x; git -C "$W" checkout main',
      'W=/other; for W in a b; do :; done; git -C "$W" checkout main',
      'W=/other; getopts ab W; git -C "$W" checkout main',
      'W=/other; exec {W}>out.txt; git -C "$W" checkout main',
      'W=/other; W=/b true; git -C "$W" checkout main',
      // The name inside text another command may run.
      `W=/other; sh -c 'read W'; git -C "$W" checkout main`,
      `W=/other; emulate sh -c 'W=/b'; git -C "$W" checkout main`,
      // Text run as commands of this shell, which may set anything.
      'W=/other; eval "$x"; git -C "$W" checkout main',
      'W=/other; source ./env.sh; git -C "$W" checkout main',
      'W=/other; . ./env.sh; git -C "$W" checkout main',
      `W=/other; trap 'true' EXIT; git -C "$W" checkout main`,
      `W=/other; alias g=git; git -C "$W" checkout main`,
      'W=/other; f() { true; }; git -C "$W" checkout main',
      'W=/other; function f { true; }; git -C "$W" checkout main',
      // A sum, which sets what it names, or an expansion that may assign.
      'W=/other; let W=1; git -C "$W" checkout main',
      'W=/other; ((W=1)); git -C "$W" checkout main',
      'W=/other; echo $((W=1)); git -C "$W" checkout main',
      'W=/other; git log -n $((n+1)); git -C "$W" checkout main',
      'W=/other; git log -n $[n+1]; git -C "$W" checkout main',
      'W=/other; : ${W:=/x}; git -C "$W" checkout main',
      'W=/other; git log ${x:-main}; git -C "$W" checkout main',
      'W=/other; git log $x[2]; git -C "$W" checkout main',
      'W=/other; [[ $n -gt 3 ]] && true; git -C "$W" checkout main',
      // A name another program is handed that only the shell running it knows.
      'W=/other; read $x; git -C "$W" checkout main',
      'W=/other; unset "$x"; git -C "$W" checkout main',
      'W=/other; export $(cat env.txt); git -C "$W" checkout main',
      'W=/other; read W*; git -C "$W" checkout main',
      'W=/other; read {W,x}; git -C "$W" checkout main',
      'W=/other; ls *.md; git -C "$W" checkout main',
      'W=/other; x=W; read $x; git -C "$W" checkout main',
      'W=/other; $x W; git -C "$W" checkout main',
      'W=/other; "$@"; git -C "$W" checkout main',
      // IFS decides where a bare value is cut into words, and a heredoc holds text nobody reads here.
      'IFS=/; W=/other; git -C $W checkout main',
      'W=/other; cat <<EOF\nx\nEOF\ngit -C "$W" checkout main',
    ]
    expect(not.filter(cmd => folder(cmd) !== NOT)).toEqual([])
    // The controls: the same lines where nothing can reach the variable.
    const still = [
      'W=/other; read line < list; git -C "$W" checkout main',
      'W=/other; unset V; git -C "$W" checkout main',
      'W=/other; x=$(date +%s); git -C "$W" checkout main',
      'W=/other; git log -n 3 "$x" $(cat list) *.md; git -C "$W" checkout main',
      'W=/other; echo "in $W"; git -C "$W" checkout main',
      'W=/other; [ -d /other ] && echo yes; git -C "$W" checkout main',
      'W=/other; git -C "$W" fetch -q && git -C "$W" checkout main',
      'W=/other; git -C "$W" checkout main | cat',
      'W=/other; (git -C "$W" checkout main)',
      'W=/other; if true; then git -C "$W" checkout main; fi',
    ]
    expect(still.filter(cmd => folder(cmd) !== '/other')).toEqual([])
  })

  test('a name a shell may keep for itself is not followed: all capitals or all small letters, two or more', () => {
    followedAsWritten()
    // The shell sets these itself, or reads them its own way: cd writes PWD, RANDOM is a new number.
    const not = ['PWD=/other; cd /tmp; git -C "$PWD" checkout main', 'RANDOM=/other; git -C "$RANDOM" checkout main', 'status=/other; git -C "$status" checkout main', 'REPO=/other; git -C "$REPO" checkout main', 'wt=/other; git -C "$wt" checkout main', 'W2=/other; git -C "$W2" checkout main', '_=/other; git -C "$_" checkout main']
    expect(not.filter(cmd => folder(cmd) !== NOT)).toEqual([])
  })

  test("a shell of its own, or a substitution, is not the call's own text", () => {
    followedAsWritten()
    const not = [`W=/other; bash -c 'git -C "$W" checkout main'`, `bash -c 'W=/other; git -C "$W" checkout main'`, 'echo "$(W=/other; git -C "$W" checkout main)"']
    expect(not.filter(cmd => folder(cmd) !== NOT)).toEqual([])
  })

  test('the past command behind a cd that cannot be followed carries nothing to follow', () => {
    followedAsWritten()
    const cmd = 'd=$(mktemp -d) && cd "$d" && git init -q && git checkout -q main; git -C "$d" rev-parse --verify --quiet HEAD'
    expect(pipeline(cmd, { follow: true }).filter(c => 'followed' in c)).toEqual([])
  })
})

// #3491: `$'...'` was read as a plain single quoted string, where a backslash escapes nothing, so
// `x=$'it\'s'` closed at the escaped quote and its last quote opened a string that never closed: the
// rest of the script became one word of a command that only sets a variable, which is no command,
// and every guard judged nothing after it. Measured 2026-11-23 on bash 3.2, zsh 5.9, macOS sh and
// ksh: the string is `it's` and the next line runs. And a script the reader cannot read to its end
// gave no sign of it: now the command it stops in is marked `unread`, which every guard holds.
describe("$'...' and a script not read to its end (#3491)", () => {
  const BS = '\\'
  const NEXT = 'prettier --write app/page.tsx'
  const next = ['prettier', '--write', 'app/page.tsx']
  const QUOTE = 'holding a quote that never closes, so what the shell runs from there on cannot be read'
  const HEREDOC = 'fed a heredoc that never ends, so where its body stops cannot be read'
  const TORN = 'fed a heredoc opened on a line that ends inside a quote, so where its body starts cannot be read'

  test("an escaped quote inside $'...' does not close it, so the commands after it are read", () => {
    expect(commands(`x=$'it${BS}'s'\n${NEXT}`)).toEqual([next])
    expect(commands(`echo $'it${BS}'s' done; ${NEXT}`)).toEqual([['echo', `$it${BS}'s`, 'done'], next])
    expect(commands(`echo $'a${BS}${BS}${BS}'b' done; ${NEXT}`)).toEqual([['echo', `$a${BS}${BS}${BS}'b`, 'done'], next])
    // The word is given as it always was, the $ kept and the text between the quotes as typed, so a
    // string holding no escaped quote reads exactly as before.
    expect(commands(`echo $'a${BS}${BS}' $'a${BS}"b' $'a${BS}nb'; ${NEXT}`)).toEqual([['echo', `$a${BS}${BS}`, `$a${BS}"b`, `$a${BS}nb`], next])
  })

  test("a quote after an escaped $ is a plain one, and in double quotes $' is text", () => {
    expect(commands(`echo ${BS}$'a${BS}' b; ${NEXT}`)).toEqual([['echo', `$a${BS}`, 'b'], next])
    expect(commands(`echo ${BS}${BS}$'a${BS}'b' c; ${NEXT}`)).toEqual([['echo', `${BS}$a${BS}'b`, 'c'], next])
    expect(commands(`echo "$'a" b; ${NEXT}`)).toEqual([['echo', `$'a`, 'b'], next])
  })

  test("the readers of a substitution's end, a test's end and a line's comment read $'...' the same way", () => {
    expect(commands(`echo $(printf $'it${BS}'s (') done; ${NEXT}`)).toEqual([['printf', `$it${BS}'s (`], ['echo', `$(printf $'it${BS}'s (')`, 'done'], next])
    expect(commands(`[[ $'it${BS}'s' == x || -n y ]] && ${NEXT}`)).toEqual([['[[', `$it${BS}'s`, '==', 'x', '||', '-n', 'y', ']]'], next])
    expect(commands(`echo $'it${BS}'s' # see <<EOF\n${NEXT}`)).toEqual([['echo', `$it${BS}'s`], next])
    expect(commands(`cat <<$'E${BS}'OF'\nbody\nE'OF\n${NEXT}`)).toEqual([['cat', `<<$E${BS}'OF`], next])
  })

  test('a quote that never closes marks the command it stands in unread', () => {
    const read = (cmd: string) => pipeline(cmd).map(c => [c.words, c.unread])
    expect(read(`echo 'abc\n${NEXT}`)).toEqual([[['echo', `abc\n${NEXT}`], QUOTE]])
    expect(read(`echo "abc\n${NEXT}`)).toEqual([[['echo', `abc\n${NEXT}`], QUOTE]])
    expect(read(`echo $'it${BS}'s\n${NEXT}`)).toEqual([[['echo', `$it${BS}'s\n${NEXT}`], QUOTE]])
    // A command that only sets a variable is no command, but one the reader stops in is given.
    expect(read(`git status; x='abc\n${NEXT}`)).toEqual([[['git', 'status'], undefined], [[`x=abc\n${NEXT}`], QUOTE]])
    // The commands of a shell's script that stops in a quote are each unread.
    expect(read(`bash -c 'echo "abc' ; ${NEXT}`)).toEqual([[['echo', 'abc'], QUOTE], [next, undefined]])
    // What already said why it cannot be read keeps its own reason.
    expect(read(`eval 'abc\n${NEXT}`).map(r => r[1])).toEqual(['run as text by eval, so what it runs cannot be read'])
  })

  test('a heredoc that never ends marks the command it feeds unread, its lines still read as commands', () => {
    const read = (cmd: string) => pipeline(cmd).map(c => [c.words.join(' '), c.unread])
    expect(read(`cat <<EOF\n${NEXT}`)).toEqual([['cat <<EOF', HEREDOC], [NEXT, undefined]])
    expect(read(`git status; cat > f.txt <<'EOF'\nbody`)).toEqual([['git status', undefined], ['cat > f.txt <<EOF', HEREDOC], ['body', undefined]])
    // One a substitution inside double quotes opens is a heredoc, and never ending it is said too.
    expect(pipeline(`git commit -m "$(cat <<'EOF'\nmsg`).filter(c => c.words[0] === 'git').map(c => c.unread)).toEqual([HEREDOC])
  })

  test('a heredoc opened on a line that ends inside a quote marks the command it feeds unread', () => {
    // Measured 2026-11-23 on bash 3.2, zsh 5.9, macOS sh, dash and ksh: the body starts after the line
    // the quote closes on. This reader takes it from the next line, so it says it cannot read it.
    const read = (cmd: string) => pipeline(cmd).filter(c => c.unread !== undefined).map(c => [c.words.join(' '), c.unread])
    expect(read(`cat <<EOF; x="a\nb"\nbody\nEOF\n${NEXT}`)[0]).toEqual(['cat <<EOF', TORN])
    expect(read(`cat <<EOF; echo "a\nb"\nbody\nEOF\necho "c"; ${NEXT}`)[0]).toEqual(['cat <<EOF', TORN])
  })

  // The fix round on pull request #3493. A Bash call here runs in zsh, and bash and zsh do not read
  // every quote alike. Measured 2026-11-23 on bash 3.2 and zsh 5.9, with texts that only echo:
  // after an even run of $ (`$$'`, `$$$$'`, `X$$'`, `\\$$'`) bash reads its own number and a plain
  // quote where a command stands, and zsh a `$'...'` string, so `p1 $$'a\'b' ; p2 # it's` runs p2 in
  // zsh alone and `p1 $$'a\' b; p2` runs both in bash and neither in zsh. Inside `(( ))` and
  // `$(( ))` bash reads a quote and zsh reads none, so `(( 1 'a ))` then a line `p2 # b'` runs p2 in
  // zsh alone. Inside `"${...}"` bash pairs single quotes and zsh reads them as text, so
  // `p1 "${u:-'"'}" ; p2 # it's` runs p2 in bash alone. The reader read each as one of the two and
  // gave the other's commands no sign. It picks neither now: the command read past such a quote, and
  // every command after it, is unread.
  const SHELLS = 'read past a quote bash and zsh do not read alike, so what the shell runs from that quote on cannot be read'
  const readAll = (cmd: string) => pipeline(cmd).map(c => [c.words, c.unread])
  const marksIn = (cmd: string) => ({ cmd, marks: [...new Set(pipeline(cmd).map(c => c.unread))] })

  test('a quote after $$ that bash and zsh close at different places marks its command unread, and each one after it', () => {
    // The reviewer's texts: zsh runs the command after the string, read here into the string's word.
    expect(readAll(`x=$$'a${BS}'b'\n${NEXT} # it's`)).toEqual([[[`x=$$a${BS}b\n${NEXT} # its`], SHELLS]])
    expect(readAll(`p1 $$'a${BS}'b' ; ${NEXT} # it's`)).toEqual([[['p1', `$$a${BS}b ; ${NEXT} # its`], SHELLS]])
    for (const pre of ['$$$$', 'X$$', `${BS}${BS}$$`, `${BS}$$$`, '${x}$$']) {
      const cmd = `p1 ${pre}'a${BS}'b' ; ${NEXT} # it's`
      expect(marksIn(cmd)).toEqual({ cmd, marks: [SHELLS] })
    }
    // bash runs both of these and zsh neither.
    expect(readAll(`echo $$'a${BS}' b; ${NEXT}`)).toEqual([[['echo', `$$a${BS}`, 'b'], SHELLS], [next, SHELLS]])
    // It is one of the reasons the reader stopped, so the write reader still lists the command's run.
    expect(READ_STOPPED.has(SHELLS)).toBe(true)
  })

  test('what is read after such a quote is unread wherever it stands, and what stands before it is read as ever', () => {
    // In a substitution (both shells run the command after it): the commands inside and the one holding it.
    const inSub = `p3 $(p1 $$'a${BS}'b') ; ${NEXT} # it's`
    expect(marksIn(inSub)).toEqual({ cmd: inSub, marks: [SHELLS] })
    // The commands of a substitution in a command after it.
    expect(pipeline(`echo $$'a${BS}' b; echo "$(${NEXT})"`).filter(c => c.words[0] === 'prettier').map(c => c.unread)).toEqual([SHELLS])
    // A heredoc opened after it: zsh reads `# it's <<EOF` as a comment and runs the line below it, so
    // the lines taken as its body are read as commands too, never as neither.
    expect(pipeline(`p1 $$'a${BS}'b' # it's <<EOF\n${NEXT}\nEOF\necho done`).filter(c => c.words[0] === 'prettier').map(c => c.unread)).toEqual([SHELLS])
    expect(readAll(`git status; p1 $$'a${BS}'b' ; ${NEXT} # it's`)[0]).toEqual([['git', 'status'], undefined])
  })

  test('a quote inside (( )) that bash reads and zsh does not marks what is read from there on unread', () => {
    for (const cmd of [`(( 1 'a ))\n${NEXT} # b'`, `(( 1 $'a ))\n${NEXT} # b'`, `(( 1 "a ))\n${NEXT} # b"`]) expect(marksIn(cmd)).toEqual({ cmd, marks: [SHELLS] })
    // In a `$(( ))`: from the command holding it on, the subshell's own parenthesis before it left alone.
    const inWord = readAll(`( echo $(( 1 'a )) )\n${NEXT} # b'`)
    expect(inWord[0]).toEqual([['('], undefined])
    expect([...new Set(inWord.slice(1).map(r => r[1]))]).toEqual([SHELLS])
  })

  test('a single quote inside "${...}" that bash pairs and zsh reads as text marks what is read from there on unread', () => {
    for (const cmd of [`p1 "\${u:-'"'}" ; ${NEXT} # it's`, `p1 "\${u:-"'"}" ; ${NEXT} # it's`, `p1 "\${u//'/x}" ; ${NEXT} # it's`]) expect(marksIn(cmd)).toEqual({ cmd, marks: [SHELLS] })
    // A backslash right before a quote there: zsh runs both commands, bash neither (measured 2026-11-23).
    for (const cmd of [`p1 "\${u:-$'a${BS}'b'}" ; ${NEXT} # it's`, `p1 "\${u:-$'a${BS}${BS}'}" ; ${NEXT} # it's`, `p1 "\${u:-'a${BS}'b'}" ; ${NEXT} # it's`]) expect(marksIn(cmd)).toEqual({ cmd, marks: [SHELLS] })
    // Inside a substitution: bash runs the command after it and zsh nothing (measured 2026-11-23), and
    // where the substitution ends cannot be read, so the command holding it is unread too.
    const inSub = `p3 $(p1 "\${u:-'"'}") ; ${NEXT} # it's`
    expect(marksIn(inSub)).toEqual({ cmd: inSub, marks: [SHELLS] })
  })

  test('a "${ held in single quotes, as a pattern handed to grep, is text to both shells and marks nothing', () => {
    // The first build of this round searched the text as written for the "${...}" shape and marked 12
    // recorded calls of this shape. bash and zsh both read the single quotes first and run each command.
    for (const cmd of [`grep -n '"\${HOME' f; ${NEXT} # it's`, `grep -c '"\${u:-' a.txt b.txt; ${NEXT}`]) expect(marksIn(cmd)).toEqual({ cmd, marks: [undefined] })
  })

  // The second fix round on pull request #3493. A count over a second Mac's recorded commands
  // (201,766 distinct, 2026-11-23) found the marks above on ordinary commands: nine with two opening
  // parentheses in quoted text handed to a program (a perl substitution, a pattern for grep, a
  // program for node) and two with a << in quoted text. To both shells text inside quotes is text.
  // Every text in the four tests below was run on bash 3.2 and zsh 5.9 with programs that only
  // print: the two ran the same commands for each one that marks nothing here, and each one that
  // keeps its mark either ran differently in the two or is one the reader cannot follow as surely
  // as a shell. The reader searched the text as written for `((`, and read each line's quotes
  // alone, so a quote opened on an earlier line, or a backtick a backslash escapes, hid that a <<
  // stood in text.
  test('two opening parentheses inside quoted text are text to both shells and mark nothing', () => {
    const texts = [
      `perl -pe 's/${BS}(([^${BS})]*)${BS})/[$1]/' f; ${NEXT}`,
      `perl -pe 's/(("|x)y)/z/g' f; ${NEXT}`,
      `grep -E "((it's|x) y)" f; ${NEXT}`,
      `grep -E "f${BS}((${BS})|,)" f; ${NEXT}`,
      `node -e 'q((s || ")").length)'; ${NEXT}`,
      `node -e "q((s || ')').length)"; ${NEXT}`,
      `node -e '\nq((s || ")").length)\n'; ${NEXT}`,
      // After a substitution the reader follows to its end, in double quotes and in backticks, and
      // in the text of the double quotes that hold one.
      `p3 "$(p1 "$x")"; perl -pe 's/${BS}(([^${BS})]*)${BS})/[$1]/' f; ${NEXT}`,
      `grep -E "$x $(p3 a) f${BS}((${BS})|,)" f; ${NEXT}`,
      `p3 \`p1 a\`; grep -E "\${x} f${BS}((${BS})|,)" f; ${NEXT}`,
      // After arithmetic and a `\${ }` that hold no quote, and after a comment with an apostrophe.
      `p3 $((1+2)) $(( (1+2)*3 )) \${x:-a b}; (( x = (1+2)*3 )); perl -pe 's/${BS}(([^${BS})]*)${BS})/[$1]/' f; ${NEXT}`,
      `p3 a # it's\n[[ a == a # it's\n]]; grep -E "f${BS}((${BS})|,)" f; ${NEXT}`,
    ]
    for (const cmd of texts) expect(marksIn(cmd)).toEqual({ cmd, marks: [undefined] })
    // The words are the ones given before.
    expect(readAll(texts[0] as string)).toEqual([[['perl', '-pe', `s/${BS}(([^${BS})]*)${BS})/[$1]/`, 'f'], undefined], [next, undefined]])
    // A shell's script in quotes is read as that shell reads it: its own commands keep the mark, and
    // the command after it, which bash and zsh both run, has none.
    expect(readAll(`bash -c '(( 1 "a ))\necho p2 # b"'; ${NEXT}`)).toEqual([[['('], SHELLS], [['('], SHELLS], [['1', 'a ))\necho p2 # b'], SHELLS], [next, undefined]])
  })

  test('the same parentheses where a shell reads them keep the mark', () => {
    const kept: [string, (string | undefined)[]][] = [
      // Outside quotes, after quoted words: zsh alone runs the line after it.
      [`p1 'a' "$x"; (( 1 'a ))\n${NEXT} # b'`, [undefined, SHELLS]],
      // In a substitution, or arithmetic, that double quotes leave live: zsh alone runs the commands.
      [`p1 "$( (( 1 'a )) ; p3 )"\n${NEXT} # b'`, [SHELLS, QUOTE]],
      [`p1 "a $(p3 $(( 1 'a )) ) b"\n${NEXT} # b'`, [SHELLS, QUOTE]],
      [`p1 "a $(( 1 ')' )) b"; ${NEXT}`, [SHELLS]],
      // In quotes that stand inside (( )), where zsh reads no quote: bash alone runs the next line
      // after the first, and both run it after the second only because its parentheses happen to
      // balance, which the reader does not ask.
      [`(( 1 + '((${BS})' ))\n${NEXT}`, [SHELLS]],
      [`(( 1 + '(( ${BS}) x)' ))\n${NEXT}`, [undefined, SHELLS]],
      // After what the reader cannot follow as surely as a shell (zsh alone runs the next line of
      // each): a case inside a substitution in double quotes, whose pattern's ) bash 3.2 ends the
      // substitution at; a comment inside a substitution, which bash 3.2 reads as text; and the body
      // of a heredoc the reader does not open.
      [`p1 "$(case $x in a) p3 '"' ;; esac)"; (( 1 'a ))\n${NEXT} # b'`, [undefined, SHELLS]],
      [`p3 $(p1 # it's\n); (( 1 'a ))\n${NEXT} # b'`, [undefined, SHELLS]],
      [`cat <<1\nit's\n1\n(( 1 'a ))\n${NEXT} # b'`, [undefined, SHELLS]],
      // A comment holding a parenthesis and no quote inside a substitution in double quotes: zsh ends
      // the substitution on the next line, and the reader with it, but bash 3.2 ran neither line of
      // either text, so the `((` after it is not called quoted text.
      [`p1 "$(p3 # a ( b\n) c (( 1 'a ))" \n${NEXT} # '`, [undefined, SHELLS]],
      [`p1 "$(p3 # a) $(p2 (\n) b (( 1 'a ))\n) c" ; ${NEXT} # '`, [undefined, SHELLS]],
      // After a # inside a word, which starts no comment, so its apostrophe opens a quote and the
      // `$((` on the next line stands outside quotes: after a substitution, on a line a backslash
      // joins to a word, and after a parenthesis.
      [`p3 $(p1 a)#it's\np1 '$(( 1 '"a ))\n${NEXT} # b"'`, [undefined, SHELLS]],
      [`p3 a${BS}\n#it's\np1 '$(( 1 '"a ))\n${NEXT} # b"'`, [SHELLS]],
      [`p3 x(#it's)\np1 '$(( 1 '"a ))\n${NEXT} # b"'`, [SHELLS]],
      // After a heredoc the line reader closed inside quoted text: the lines it took out as a body
      // hold a quote and a command, p3, that both shells run and the reader no longer gives.
      [`p1 '\nx << n\ny' ; p3 '\nn\n(( 1 '"a ))\n${NEXT} # b"`, [SHELLS]],
      // In quoted text inside a substitution: both shells run it alike, and the mark is left.
      [`p3 "$(p1 'q((s || ")").length)')"; ${NEXT}`, [SHELLS]],
      // The pull request's own case: a quote the two shells close at different places.
      [`p1 'a' "b"; p1 $$'a${BS}'b' ; ${NEXT} # it's`, [undefined, SHELLS]],
    ]
    for (const [cmd, marks] of kept) expect(marksIn(cmd)).toEqual({ cmd, marks })
  })

  test('a << in quoted text that spans lines, or beside a backtick or $( a backslash escapes, marks nothing', () => {
    for (const cmd of [
      `node -e '\nx = 1 << n\nq(x)\n'; ${NEXT}`,
      `p1 -m "a note\nthat quotes cat <<EOF in text\ndone"; ${NEXT}`,
      `p1 -m "it's\nshift 1 << n here"; ${NEXT}`,
      `p1 -m "see ${BS}\`cat <<EOF${BS}\` here"; ${NEXT}`,
      `p1 -m "see ${BS}$(cat <<EOF) here"; ${NEXT}`,
      `p3 "$(p1 "$x")"; p1 'x\ny << z\n'; ${NEXT}`,
    ]) expect(marksIn(cmd)).toEqual({ cmd, marks: [undefined] })
    expect(readAll(`node -e '\nx = 1 << n\nq(x)\n'; ${NEXT}`)).toEqual([[['node', '-e', '\nx = 1 << n\nq(x)\n'], undefined], [next, undefined]])
    // A shell's script in quotes: the command its heredoc feeds keeps the mark, and the command after
    // the script, which bash and zsh both run, has none.
    expect(readAll(`bash -c '\ncat <<NEVER\nbody\n'; ${NEXT}`)).toEqual([[['cat', '<<NEVER'], HEREDOC], [['body'], undefined], [next, undefined]])
  })

  test('a << where a shell opens a heredoc that never ends keeps the mark', () => {
    const marked = (cmd: string) => pipeline(cmd).filter(c => c.unread !== undefined).map(c => [c.words[0], c.unread])
    // Outside quotes, after a quoted word.
    expect(marked(`p1 'a'; cat <<NEVER\n${NEXT} 'b'`)).toEqual([['cat', HEREDOC]])
    // In a substitution that double quotes leave live, on the quote's first line or a later one.
    expect(marked(`p1 "$(cat <<NEVER\nbody)"; ${NEXT}`)).toEqual([['cat', HEREDOC], ['p1', HEREDOC]])
    expect(marked(`p1 "a\n$(cat <<NEVER\nc\n)"; ${NEXT}`)).toEqual([['cat', HEREDOC], ['p1', HEREDOC]])
    expect(marked(`p1 "a \`cat <<NEVER\`\nb"; ${NEXT}`)).toEqual([['cat', HEREDOC], ['p1', HEREDOC]])
    // After what the reader cannot follow as surely as a shell: the body of a heredoc it does not
    // open, one it ends too soon, and a comment inside a substitution. An apostrophe in each would
    // put the << inside a quote that no shell reads.
    expect(marked(`cat <<1\nit's\n1\ncat <<NEVER\n${NEXT} # it's`).map(r => r[1])).toEqual([HEREDOC])
    // The one it ends too soon is marked for that as well (#3592); the mark this test holds stays.
    expect(marked(`cat <<EOF\n  EOF\nit's body\nEOF\ncat <<NEVER\nx # '`).map(r => r[1])).toEqual(['fed a heredoc the shells do not end where it is read to end, so where its body stops cannot be read', HEREDOC])
    expect(marked(`p3 $(p1 # it's\n); cat <<NEVER\n${NEXT} # '`)).toEqual([['cat', HEREDOC]])
    // A # inside a word starts no comment: after a substitution, and on a line a backslash joins to
    // a word. The apostrophe after it opens a quote that the next line's quote closes, so the << two
    // lines on stands outside quotes (bash ran the heredoc's line as its body, zsh did not).
    expect(marked(`p3 $(p1 a)#it's\np1 '\ncat <<NEVER\n${NEXT} # '`)).toEqual([['cat', HEREDOC]])
    expect(marked(`p3 a${BS}\n#it's\np1 '\ncat <<NEVER\n${NEXT} # '`)).toEqual([['cat', HEREDOC]])
    // A # inside `\${ }`, `$[ ]` and `(( ))` starts no comment to a shell that reads a quote there:
    // both shells stop at the first two, and after the third zsh runs p1 and bash nothing. The
    // reader reads each # as a comment, so it cannot say the << stands in text.
    expect(marked(`p3 \${x:- # it's}\np1 '\ncat <<NEVER\n${NEXT} # '`)).toEqual([['p1', HEREDOC]])
    expect(marked(`p3 $[ 1 # it's ]\np1 '\ncat <<NEVER\n${NEXT} # '`)).toEqual([['p1', HEREDOC]])
    // Since #3496 the third says so as well: a # and then a quote inside `(( ))` is read by zsh as
    // a comment and by bash as a quote, so every command from the `((` on is marked for that, and
    // the one fed the heredoc keeps the mark it had.
    expect(marked(`(( 1 +\n # it's\n 2 ))\np1 '\ncat <<NEVER\n${NEXT} # '`)).toEqual([['(', SHELLS], ['(', SHELLS], ['1', SHELLS], ['2', SHELLS], [')', SHELLS], [')', SHELLS], ['p1', HEREDOC]])
    // After a heredoc the line reader closed inside quoted text, taking out a line that holds a quote
    // and a command both shells run: where the second << stands in the whole text is not known.
    expect(marked(`p1 '\nx << n\ny' ; p3 '\nn\n      cat <<NEVER\n${NEXT} # '`)).toEqual([['p1', HEREDOC]])
    // In quoted text inside a substitution: both shells run it alike, and the mark is left.
    expect(marked(`p3 "$(p1 '\nx << n\n')"; ${NEXT}`)).toEqual([['p1', HEREDOC], ['p3', HEREDOC]])
  })

  // The third review of pull request #3493 found two kinds of text the scan of quoted text
  // (quotedText) called quoted where a shell reads a command, so a mark went from texts bash and
  // zsh run differently. Each text of the two tests below was run on bash 3.2 and zsh 5.9 on
  // 2026-11-23 with programs that only print.
  test('a # after a character only JavaScript calls a space starts no comment, so what a shell reads after it keeps the mark', () => {
    const marked = (cmd: string) => pipeline(cmd).filter(c => c.unread !== undefined).map(c => [c.words[0], c.unread])
    // Every character JavaScript's \s holds but space, tab and new line: a vertical tab, a carriage
    // return, a form feed, a no-break space and eighteen rarer ones. bash and zsh blank none of
    // them, so `a`, the character and `#it` are one word, and the apostrophe opens a quote that the
    // next line's apostrophe closes.
    const spaces = [11, 13, 12, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff]
    expect(spaces.every(n => /\s/.test(String.fromCharCode(n)))).toBe(true)
    for (const c of spaces.map(n => String.fromCharCode(n))) {
      // The `((` stands outside quotes: zsh ran the last line and bash nothing.
      const cmd = `p1 a${c}#it's\np1 b'; (( 1 + 'a ))\n${NEXT} # b'`
      expect(marksIn(cmd)).toEqual({ cmd, marks: [undefined, SHELLS] })
      // The << stands outside quotes: both shells opened the heredoc.
      expect(marked(`p3 a${c}#it's\np1 '\ncat <<NEVER\n${NEXT} # '`)).toEqual([['cat', HEREDOC]])
      // The scan stops at such a # rather than read on, so quoted text after it keeps the mark it
      // had, though both shells ran this one alike: the harmless side (L648).
      const alike = `p1 a${c}#it's\np1 b' ; p3 '((' "x)" # '`
      expect(marksIn(alike)).toEqual({ cmd: alike, marks: [undefined, SHELLS] })
    }
    // After a tab, as after a space, the # does start a comment, and the quoted text after it is
    // still passed over.
    const tab = String.fromCharCode(9)
    const cmd = `p3 a${tab}# it's\ngrep -E "f${BS}((${BS})|,)" f; ${NEXT}`
    expect(marksIn(cmd)).toEqual({ cmd, marks: [undefined] })
  })

  test('a backslash before a new line ends what the scan of quoted text answers for, so what a shell joins there keeps the mark', () => {
    const marked = (cmd: string) => pipeline(cmd).filter(c => c.unread !== undefined).map(c => [c.words[0], c.unread])
    const kept: [string, (string | undefined)[]][] = [
      // In double quotes bash joins the $ and the ( either side of the pair into a substitution and
      // ran p3, or stopped at its arithmetic; zsh handed the text on and ran the rest.
      [`p1 "$${BS}\n(p3 '(( x')" ; ${NEXT}`, [SHELLS]],
      [`p1 "$${BS}\n(p3 '((' x)" ; ${NEXT}`, [SHELLS]],
      [`p1 "$${BS}\n( (( 1 'a ))\n ${NEXT} # b' )" ; p3`, [SHELLS]],
      [`p1 "$${BS}\n(( 1 + ')' ))" ; ${NEXT}`, [SHELLS]],
      // Outside quotes both shells join the $ and the ' into a $'...' string that ends at its third
      // apostrophe, so the `((` stands outside quotes: zsh ran the last line and bash nothing.
      [`p1 $${BS}\n'a${BS}'b' ; (( 1 + 'a ))\n${NEXT} # b'`, [SHELLS]],
      // A < either side of the pair: bash opened a heredoc and zsh ran nothing. Since #3496 the
      // command holding the pair says so itself, where it had no mark.
      [`cat <${BS}\n<EOF\nit's\nEOF\n(( 1 + 'a ))\n${NEXT} # b'`, ['holding a backslash and a new line inside what bash joins into one mark and zsh does not, so what the shell runs there cannot be read', SHELLS]],
    ]
    for (const [cmd, marks] of kept) expect(marksIn(cmd)).toEqual({ cmd, marks })
    // The same for a << that never ends: after the joined $'...' string both shells opened the
    // heredoc, and inside the substitution bash joins, bash did.
    expect(marked(`p1 $${BS}\n'a${BS}' '\ncat <<NEVER\n${NEXT} # '`)).toEqual([['p1', HEREDOC]])
    expect(marked(`p1 "$${BS}\n(cat <<NEVER\n)" ; ${NEXT}`)).toEqual([['p1', HEREDOC]])
    // What joins nothing still marks nothing: two backslashes before a new line, the pair inside
    // single quotes and inside $'...', where it is text, and the pair after the quoted text.
    for (const cmd of [
      `p1 a ${BS}${BS}\np3 '((' "x)" ; ${NEXT}`,
      `p1 "a ${BS}${BS}\n" ; p3 '((' "x)" ; ${NEXT}`,
      `p1 'a ${BS}\nb' ; p3 '((' "x)" ; ${NEXT}`,
      `p1 $'a${BS}\n' '((' "x)" ; ${NEXT}`,
      `p3 '((' "x)" ${BS}\n b ; ${NEXT}`,
    ]) expect(marksIn(cmd)).toEqual({ cmd, marks: [undefined] })
    // Past the pair the scan answers for nothing, so quoted text there has its mark again though
    // both shells ran these alike: the harmless side (L648).
    const past: [string, (string | undefined)[]][] = [
      [`p1 -n ${BS}\n  '((' "x)" ; ${NEXT}`, [SHELLS]],
      [`p1 "a ${BS}\n b" ; p3 '((' "x)" ; ${NEXT}`, [undefined, SHELLS]],
    ]
    for (const [cmd, marks] of past) expect(marksIn(cmd)).toEqual({ cmd, marks })
  })

  // The fourth fix round on pull request #3493. A count over a second Mac's 202,875 recorded
  // commands found 5 ordinary ones still marked unread for nothing, all one shape: a program in
  // single quotes that runs over several lines and closes on the line where a later command opens
  // a heredoc. dropHeredocs read each line's quotes on that line alone, so on such a line it took
  // the closing quote for an opening one and every quote after it the wrong way round, and found a
  // quote opened after the << that the line ends inside. Each text of the four tests below was run
  // on bash 3.2.57 and zsh 5.9 on 2026-11-24 with programs that only print. Both shells ran the same
  // commands and fed them the same lines for every text the reader now gives no mark, and where
  // they did not for a text that keeps one, the test says what each did.
  // Each command's program, the body of each heredoc feeding it, and its mark.
  const shape = (cmd: string) => pipeline(cmd).map(c => [c.words[0], ...(c.heredocs ? [c.heredocs.map(h => h.body)] : []), ...(c.unread ? [c.unread] : [])])
  const inWords = (cmd: string) => pipeline(cmd).map(c => [c.words.join(' '), ...(c.heredocs ? [c.heredocs.map(h => h.body)] : []), ...(c.unread ? [c.unread] : [])])

  test('a heredoc opened on the line where a quote from an earlier line closes is read, with no mark', () => {
    // The three shapes of the 5 recorded commands, each with a command after the heredoc's body,
    // which a reader that lost the body's end would not give. A program fed the heredoc:
    expect(inWords(`p1 -c '\nimport a\nprint(a)\n' && cat - <<'PY'\nprint(1)\nPY\n${NEXT}`)).toEqual([['p1 -c \nimport a\nprint(a)\n'], ['cat - <<PY', ['print(1)']], [NEXT]])
    // the same after an earlier heredoc that is whole:
    expect(inWords(`cat > /dev/null <<'E1'\nfirst\nE1\np1 -c '\nimport a\n' && cat - <<'PY'\nprint(1)\nPY\n${NEXT}`)).toEqual([['cat > /dev/null <<E1', ['first']], ['p1 -c \nimport a\n'], ['cat - <<PY', ['print(1)']], [NEXT]])
    // and one fed the heredoc and piped on to a program with a one line program in quotes.
    expect(inWords(`p1 '\nselect a\n' ; cat <<EOF | p2 -c 'import json; print(1)'\nbody\nEOF\n${NEXT}`)).toEqual([['p1 \nselect a\n'], ['cat <<EOF', ['body']], ['p2 -c import json; print(1)'], [NEXT]])
    expect(inWords(`p1 '\nselect a\n' ; cat <<'EOF' | p2 -c 'import json; print(1)'\nbody\nEOF\n${NEXT}`)).toEqual([['p1 \nselect a\n'], ['cat <<EOF', ['body']], ['p2 -c import json; print(1)'], [NEXT]])
  })

  test('the shapes beside it that both shells run alike are read the same way', () => {
    const read: [string, unknown[][]][] = [
      // A dollar quote string over the lines, and a pair of quotes after the one that closes.
      [`p1 $'\na${BS}'b\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['cat', ['body']], ['prettier']]],
      [`p1 '\na\n' 'b' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['cat', ['body']], ['prettier']]],
      // A body holding an apostrophe, and a backslash before a new line inside the single quotes,
      // where it joins nothing.
      [`p1 '\na\n' ; cat <<'EOF'\nit's a body\nEOF\n${NEXT}`, [['p1'], ['cat', ["it's a body"]], ['prettier']]],
      [`p1 'a ${BS}\nb' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['cat', ['body']], ['prettier']]],
      // Two heredocs on that line, each feeding its own command, and one whose body and marker lose
      // their leading tabs.
      [`p1 '\na\n' ; cat <<A ; cat <<'B'\nbody a\nA\nbody b\nB\n${NEXT}`, [['p1'], ['cat', ['body a']], ['cat', ['body b']], ['prettier']]],
      [`p1 '\na\n' ; cat <<-'EOF'\n\tbody\n\tEOF\n${NEXT}`, [['p1'], ['cat', ['body']], ['prettier']]],
      // After a comment holding an apostrophe, and inside a subshell opened on an earlier line.
      [`# it's\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['cat', ['body']], ['prettier']]],
      [`( p1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n)\n${NEXT}`, [['('], ['p1'], ['cat', ['body']], [')'], ['prettier']]],
      // The heredoc's command after more of the line: a pipe that ends at a separator before it, a
      // command sent to the background, one that only runs if the one before fails, a variable set
      // for it, its name given as a path, and words that are substitutions.
      [`p1 '\na\n' ; p2 | p3 $(p4) ; cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['p2'], ['p4'], ['p3'], ['cat', ['body']], ['prettier']]],
      [`p1 '\na\n' ; p2 x & cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['p2'], ['cat', ['body']], ['prettier']]],
      [`p1 '\na\n' ; false || cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['false'], ['cat', ['body']], ['prettier']]],
      [`p1 '\na\n' ; Y=1 cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['cat', ['body']], ['prettier']]],
      [`p1 '\na\n' ; /bin/echo x <<'EOF' >&9\nbody\nEOF\n${NEXT}`, [['p1'], ['/bin/echo', ['body']], ['prettier']]],
      [`p1 '\na\n' ; cat $(p3) \${x} <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['p3'], ['cat', ['body']], ['prettier']]],
      // The quote in a flag that holds an equals sign, which is no variable's setting, also after a
      // pipe, and in the word of a command a variable is set for.
      [`p1 --opt='\na\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['cat', ['body']], ['prettier']]],
      [`p2 | p1 --opt='\na\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p2'], ['p1'], ['cat', ['body']], ['prettier']]],
      [`p2 | Y=1 p1 '\na\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p2'], ['p1'], ['cat', ['body']], ['prettier']]],
      // A subshell or a group opened on that line, one of them after a pipe, with the heredoc on a
      // command inside it: the pipe feeds the group, and the heredoc alone feeds that command.
      [`p1 '\na\n' ; (p3; cat <<'EOF'\nbody\nEOF\n)\n${NEXT}`, [['p1'], ['('], ['p3'], ['cat', ['body']], [')'], ['prettier']]],
      [`p1 '\na\n' ; p2 | (p3; cat <<'EOF'\nbody\nEOF\n)\n${NEXT}`, [['p1'], ['p2'], ['('], ['p3'], ['cat', ['body']], [')'], ['prettier']]],
      [`p1 '\na\n' ; p2 | { p3; cat <<'EOF'\nbody\nEOF\n}\n${NEXT}`, [['p1'], ['p2'], ['p3'], ['cat', ['body']], ['}'], ['prettier']]],
      // After earlier heredocs that are whole: one with tabs, one whose line holds quoted words and
      // a comment, and the shape itself twice in a row.
      [`cat <<-E1\n\tfirst\n\tE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['cat', ['first']], ['p1'], ['cat', ['body']], ['prettier']]],
      [`cat <<E1 | p2 'a b' "c" # it's\nfirst\nE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['cat', ['first']], ['p2'], ['p1'], ['cat', ['body']], ['prettier']]],
      [`p1 '\na\n' ; cat <<'EOF'\nbody\nEOF\np2 '\nb\n' ; cat <<'E2'\nsecond\nE2\n${NEXT}`, [['p1'], ['cat', ['body']], ['p2'], ['cat', ['second']], ['prettier']]],
      // These were read with no mark before and still are: the quote is a double one, or the marker
      // is bare, in double quotes or after a backslash.
      [`p1 "\na\n" ; cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['cat', ['body']], ['prettier']]],
      [`p1 '\na\n' ; cat <<EOF\nbody $x\nEOF\n${NEXT}`, [['p1'], ['cat', ['body $x']], ['prettier']]],
      [`p1 '\na\n' ; cat <<"EOF"\nbody $x\nEOF\n${NEXT}`, [['p1'], ['cat', ['body $x']], ['prettier']]],
      [`p1 '\na\n' ; cat <<${BS}EOF\nbody $x\nEOF\n${NEXT}`, [['p1'], ['cat', ['body $x']], ['prettier']]],
      // A line continuation inside double quotes before they close: read with no mark, as before.
      [`p1 "a ${BS}\nb" ; cat <<'EOF'\nbody\nEOF\n${NEXT}`, [['p1'], ['cat', ['body']], ['prettier']]],
    ]
    for (const [cmd, commands] of read) expect({ cmd, commands: shape(cmd) }).toEqual({ cmd, commands })
  })

  test('the shapes beside it the reader cannot read to the end keep a mark, or gain one', () => {
    const marked = (cmd: string) => pipeline(cmd).filter(c => c.unread !== undefined).map(c => [c.words[0], c.unread])
    // The line closes the quote it starts in and ends inside another, still open: the body starts
    // after the line that one closes on, in both shells. Such a line is not one read from where
    // the carried quote closes, so it is read alone, as it always was: the last quote's words and
    // the commands after the body are lost into a quote that never closes, which is the mark.
    expect(marked(`p1 '\na\n' ; cat <<EOF; p2 "c\nd"\nbody\nEOF\n${NEXT}`)).toEqual([['p2', QUOTE]])
    expect(marked(`p1 '\na\n' ; cat <<'EOF'; p2 'c\nd'\nbody\nEOF\n${NEXT}`)).toEqual([['p2', QUOTE]])
    // A quote that never closes: the one the program opens, and one after the marker.
    expect(marked(`p1 '\na\n ; cat <<EOF\nbody\nEOF\n${NEXT}`)).toEqual([['p1', QUOTE]])
    expect(marked(`p1 '\na\n' ; cat <<'EOF' 'b\nbody\nEOF\n${NEXT}`)).toEqual([['cat', QUOTE]])
    // A heredoc that never ends. Read on that line alone its << stood inside a quote, where the
    // shell opens none, so it was not said.
    expect(marked(`p1 '\na\n' ; cat <<'EOF'\nbody\n${NEXT}`)).toEqual([['cat', HEREDOC]])
    expect(marked(`p1 '\na\n' ; cat <<EOF\nbody\n${NEXT}`)).toEqual([['cat', HEREDOC]])
    // The same inside a shell's script, where the heredoc's lines stand in quoted text of the
    // call and were taken out of the script before it is read: its heredoc has no body to give.
    expect(marked(`bash -c 'p1 "\na\n" ; cat <<EOF\nbody\nEOF\np2 in'\n${NEXT}`)).toEqual([['cat', HEREDOC]])
    // A quote bash and zsh close at different places keeps its own mark on all that follows.
    expect(marked(`p1 $$'\na${BS}'b\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`).map(m => m[1])).toContain(SHELLS)
    const keeps = (cmds: string[]) => {
      for (const cmd of cmds) expect({ cmd, torn: marked(cmd).map(m => m[1]).includes(TORN) }).toEqual({ cmd, torn: true })
    }
    // What the scan of quoted text cannot follow to the heredoc's line leaves the line read alone,
    // with the mark it had: a line continuation before the quote opens, a heredoc inside the
    // program's text, a << this reader opens inside quoted text on the heredoc's own line or on
    // a line before, and a program inside a substitution.
    keeps([
      `p1 ${BS}\n'a\nb' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\ncat <<EOF\nx\nEOF\n' ; cat <<'E2'\nbody\nE2\n${NEXT}`,
      `p1 '\na\nb <<X ' ; cat <<'EOF'\nbody\nEOF\nX\n${NEXT}`,
      `p1 'a <<X b'\np2 '\nX\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 "$(p2 '\na\n' ; cat <<'EOF'\nbody\nEOF\n)"\n${NEXT}`,
    ])
    // After an earlier heredoc this reader may not place as a shell does, every later line is read
    // alone as before. One it ends where a shell reads on (#3496): at a marker indented by spaces,
    // followed by a blank, or joined to the line before by a backslash. One whose own line ends
    // inside a quote. And one whose marker is not a plain name (both shells ran this one alike:
    // the harmless side, L648).
    keeps([
      `cat <<'E1'\nfirst\n  E1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `cat <<E1\nfirst\nE1 \np2 hidden\nE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `cat <<E1\nfirst ${BS}\nE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `cat <<E1 ; p2 "a\nb"\nfirst\nE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `cat <<E'1'\nfirst\nE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
    ])
    // The same after an earlier heredoc that is not surely the one input of a plain command: one
    // a pipe feeds besides, on its own line or the line before, and one beside a here string (zsh
    // fed each of those commands more lines than bash did), and one fed to a loop (both shells
    // ran this one alike: the harmless side).
    keeps([
      `p2 | cat <<E1\nfirst\nE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p2 |\ncat <<E1\nfirst\nE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `cat - <<E1 <<<"s"\nfirst\nE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `while read l; do p2 "$l"; done <<E1\nfirst\nE1\np1 '\na\n' ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
    ])
    // The heredoc itself not placed as a shell surely places it: its marker is quoted in part
    // (both shells ran it alike: the harmless side), or it ends at a line a shell reads on past,
    // one indented by spaces or followed by a carriage return.
    keeps([
      `p1 '\na\n' ; cat <<E'O'F\nbody $x\nEOF\n${NEXT}`,
      `p1 '\na\n' ; cat <<'EOF'\nbody\n  EOF\np3 hidden\nEOF\n${NEXT}`,
      `p1 '\na\n' ; cat <<'EOF'\nbody\nEOF\r\np3 hidden\nEOF\n${NEXT}`,
    ])
    // The heredoc's line joined to the next by a backslash: the next line is more of the command
    // and the body starts after it, in both shells. Such a line is read alone, as it always was:
    // the backslash stands inside a quote, the pipe's second program is lost into the body, and
    // the mark says so.
    const joined = `p1 '\na\n' ; cat <<'EOF' ${BS}\n| p2\nbody\nEOF\n${NEXT}`
    expect(marked(joined)).toEqual([['cat', TORN]])
    // A command given two inputs: zsh feeds it both, one after the other, and bash the last alone,
    // so what the heredoc's command is fed differs. A pipe into it, a here string or a file beside
    // the heredoc, and two heredocs on one command. With a pipe before the program in quotes the
    // command may be fed twice too, so one that holds both the quotes and the heredoc keeps the
    // mark though both shells ran this one alike.
    keeps([
      `p1 '\na\n' | cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 | cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; cat <<'EOF' <<<"s"\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; cat <<'EOF' < /dev/null\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; cat <<A <<'EOF'\nbody a\nA\nbody\nEOF\n${NEXT}`,
      `cat '\na\n' - <<'EOF'\nbody\nEOF\n${NEXT}`,
    ])
    // The same two inputs where the heredoc is given to more than a plain command: a loop, a group
    // or a subshell a pipe feeds, closed on that line or opened on an earlier one; a command a pipe
    // feeds whose word holds a semicolon, in a substitution, in backticks, in a variable's default or in
    // quotes inside a substitution; a function given the heredoc where it is made and called after
    // a pipe; and the receiver of the heredoc command's own pipe given a second heredoc. zsh fed
    // each of these more lines than bash did.
    keeps([
      `p1 '\na\n' ; p2 | while read l; do p3 "$l"; done <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 | { cat; } <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 | (p3; cat) <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p2 | while read l; do\np1 '\na\n' ; p3 "$l"; done <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p2 | {\np1 '\na\n' ; cat; } <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 | cat $(p3; p4) <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 | cat \`p3; p4\` <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 | cat \${y:-a;b} <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 | cat "$(p3 "a ; b")" <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; f() { cat; } <<'EOF'\nbody\nEOF\np2 | f\n${NEXT}`,
      `p1 '\na\n' ; p2 <<'EOF' | cat <<'B'\nbody\nEOF\nbody b\nB\n${NEXT}`,
      `p1 '\na\n' ; p2 |& cat <<'EOF'\nbody\nEOF\n${NEXT}`,
    ])
    // A command that runs in one shell alone: after a pipe into a variable's setting zsh gives the
    // status of what wrote into the pipe and bash gives success, so the command after && ran in
    // bash and not in zsh. The setting holding the quote, and one on the heredoc's line. So a
    // quote in any setting, and any && or || after a pipe, keep the mark, though both shells ran
    // the last two alike.
    keeps([
      `p2 | x='\na\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 | y=1 && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `x='\na\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 | p3 && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
    ])
    // The setting is found however the quote's word is written: after another quote, after an
    // escaped blank, adding to the variable, and as the second setting of two (cat ran in bash
    // alone in each). After a substitution, inside a group, and in a command's word that only
    // looks like a setting, both shells ran these alike and the mark stays.
    keeps([
      `p2 | x='a b''\nc\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p2 | x=a${BS} b'\nc\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p2 | x+='\nc\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p2 | y=1 x='\na\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p2 | x=$(p3)'\nc\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p2 | { x='\na\n'; } && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p2 | p1 a=b'\nc\n' && cat <<'EOF'\nbody\nEOF\n${NEXT}`,
    ])
    // A heredoc with no command to feed: zsh runs a command of its own on it and bash runs none.
    // Alone after the separator, beside an output redirect alone, after the word then, and on a
    // descriptor's number.
    keeps([
      `p1 '\na\n' ; <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; > /dev/null <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; if true; then <<'EOF'\nbody\nEOF\nfi\n${NEXT}`,
      `p1 '\na\n' ; 3<<'EOF'\nbody\nEOF\n${NEXT}`,
    ])
    // What is not surely a plain command fed the heredoc alone keeps the mark too, though both
    // shells ran each of these alike (the harmless side, L648): a loop, a condition, a group or a
    // subshell given the heredoc with no pipe, a command in a case arm, a loop's or a condition's
    // own command, a variable setting alone, the heredoc before its command's name, a negated or
    // timed command, exec (the heredoc then feeds the shell, and a later command reads it), a
    // test in double brackets, a line holding another < anywhere, and a heredoc on a descriptor's
    // number, which feeds another input than the command's own.
    keeps([
      `p1 '\na\n' ; cat 3<<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; while read l; do p2 "$l"; done <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; if true; then cat; fi <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; { cat; } <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; (cat) <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; case a in a) cat <<'EOF'\nbody\nEOF\n;; esac\n${NEXT}`,
      `p1 '\na\n' ; p2 | while read l; do cat <<'EOF'\nbody\nEOF\ndone\n${NEXT}`,
      `p1 '\na\n' ; p2 | if true; then cat <<'EOF'\nbody\nEOF\nfi\n${NEXT}`,
      `p1 '\na\n' ; y=1 <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; <<'EOF' cat\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; ! cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; time cat <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; exec <<'EOF'\nbody\nEOF\ncat\n${NEXT}`,
      `p1 '\na\n' ; p2 | [[ a && b ]] <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; cat <(p3) <<'EOF'\nbody\nEOF\n${NEXT}`,
      `p1 '\na\n' ; p2 <<<s ; cat <<'EOF'\nbody\nEOF\n${NEXT}`,
    ])
  })

  test('a command after the body of such a heredoc is given, so no guard is handed a short list', () => {
    const programs = (cmd: string) => pipeline(cmd).map(c => c.words[0])
    // On the heredoc's own line after the marker, on the line after the body, and inside the body
    // of an unquoted heredoc, where the shell runs it.
    expect(programs(`p1 '\na\n' && cat <<'EOF' ; p2 hidden\nbody\nEOF\np3 hidden ; ${NEXT}`)).toEqual(['p1', 'cat', 'p2', 'p3', 'prettier'])
    expect(programs(`p1 '\na\n' && cat <<EOF\nbody $(p2 hidden)\nEOF\n${NEXT}`)).toEqual(['p1', 'p2', 'cat', 'prettier'])
    // After a marker line indented by spaces the shells read on to the true marker, and the reader
    // ends the body early (#3496), as it does on a line that starts outside quotes: the lines
    // after are read as commands, more than the shells run and never fewer.
    expect(programs(`p1 '\na\n' ; cat <<'EOF'\nbody\n  EOF\np3 hidden\nEOF\n${NEXT}`)).toEqual(['p1', 'cat', 'p3', 'EOF', 'prettier'])
  })

  test('a script read to its end marks nothing unread', () => {
    const whole = [
      // Quotes bash and zsh read alike (the fix round on #3493): after $$ where both readings close
      // at one place, after an odd run of $, inside (( )) where the quote moves nothing, inside a
      // substitution that stands in arithmetic, in a program's text, and paired inside "${...}".
      `echo $$'ab' $$'a${BS}nb' $$'a${BS}${BS}'; ${NEXT}`,
      `echo $$$'a${BS}'b' ${BS}$$'c${BS}'d'; ${NEXT}`,
      `(( 'a' + "b" ))\n${NEXT}`,
      `if (( $(grep -c ')' f) > 0 )); then ${NEXT}; fi`,
      `echo $(( $(wc -l < "f") + 1 )); ${NEXT}`,
      `python3 -c 'print((1, "a"))'; ${NEXT}`,
      `echo "\${u:-'a b'}" "\${u:-x}'s" "\${u:-\${v:-'a'}}"; ${NEXT}`,
      // A backslash inside "${...}" that stands before no quote: the value differs between the two
      // shells, the commands they run do not (measured 2026-11-23). The first is the shape of three
      // recorded calls the count found marked.
      `x="\${R%$'${BS}n'*}"; echo "\${u:-$'a${BS}tb'x}" "\${u//$'${BS}t'/ }" "\${u:-'a${BS}b'}"; ${NEXT}`,
      `echo 'a' "b" $'c${BS}'d'; ${NEXT}`,
      `cat <<EOF\nbody 'with a quote\nEOF\n${NEXT}`,
      `git commit -m "$(cat <<'EOF'\nit's a message\nEOF\n)"`,
      `x="a\nb"; cat <<EOF\nbody\nEOF\n${NEXT}`,
      `cat <<EOF # it's a comment\nbody\nEOF\n${NEXT}`,
      `echo "a 'b" 'c "d'; ${NEXT}`,
      // A << where the shell opens no heredoc: in quoted text, and inside (( )), where it shifts.
      `bash -lc 'python3 - <<EOF\nprint(1)\nEOF'`,
      `git commit -m "see <<EOF\nmore"; ${NEXT}`,
      `python3 -c "print(1 << n)"\n${NEXT}`,
      `echo $((1 << n))\n${NEXT}`,
      `(( x = 1 << n ))\n${NEXT}`,
    ]
    expect(whole.filter(cmd => pipeline(cmd).some(c => c.unread !== undefined))).toEqual([])
  })
})

// #3592: the reader ended a heredoc at any line that is its marker once the blanks beside it are
// taken off, and at a marker a backslash joins to the line before. No shell ends one at either: a
// marker with a space or a tab beside it is a line of the body (only a <<- lets go of tabs, and
// only before it), and a line of an unquoted body that ends in a backslash is joined to the next
// before anything is compared, so the marker is the tail of a longer line. The shells read on, the
// lines after are the body, and a `$( )` in them runs, in single quotes or not, where the reader
// took them for commands and read such a substitution as a word that runs nothing. The reverse
// too: a marker split over two lines by a backslash ends the heredoc in bash and zsh, and the
// reader read on, taking the commands after it for the body.
//
// The reading stays as it was. The command fed such a heredoc is marked unread, as one fed a
// heredoc that never ends is (#3491), so every guard holds or asks. The shapes are
// hooks/lib/heredoc-closes.json, each measured 2026-11-25 in bash 3.2, bash --posix, sh, dash, zsh,
// zsh emulating sh and ksh, the one list this suite and the script scanner's suite both run
// (test-shell-code-lines.sh, which also runs every row through the shells). A mod's tests import
// only the mod's own files, so the list is read from its copy, heredoc-closes.ts, which that
// suite holds to the list's text.
describe('a heredoc the shells do not end where the reader ends it (#3592)', () => {
  type Answer = string | Record<string, string[]>
  type Row = { name: string; text: string; lines: Record<string, Answer>; named: { scanner: boolean; mods: boolean } }
  const rows = (HEREDOC_CLOSES as unknown as { rows: Row[] }).rows
  const ENDS = 'fed a heredoc the shells do not end where it is read to end, so where its body stops cannot be read'
  const BS = '\\'
  // Each probe line the reader lists as a command, and each reason it stopped for.
  const read = (text: string) => {
    const cmds = pipeline(text)
    const listed = new Set(cmds.filter(c => c.words[0] === 'echo' && /^P\d\d/.test(c.words[1] ?? '')).map(c => (c.words[1] as string).slice(0, 3)))
    const stopped = [...new Set(cmds.map(c => c.unread).filter((u): u is string => u !== undefined && READ_STOPPED.has(u)))]
    return { listed, stopped }
  }
  const tag = (n: string) => `P${n.padStart(2, '0')}`

  test('the list is read, its controls among it', () => {
    expect(rows.length).toBeGreaterThanOrEqual(38)
    expect(rows.filter(r => !r.named.mods).length).toBeGreaterThanOrEqual(7)
  })

  test('the command fed a heredoc the reader is not sure of is marked unread, and no control is', () => {
    expect(rows.filter(r => read(r.text).stopped.length > 0 !== r.named.mods).map(r => r.name)).toEqual([])
  })

  test('where nothing is marked, a line is a command exactly where every shell runs it', () => {
    const wrong: string[] = []
    for (const r of rows) {
      const { listed, stopped } = read(r.text)
      if (stopped.length) continue
      for (const [n, answer] of Object.entries(r.lines)) if (listed.has(tag(n)) !== (answer === 'code')) wrong.push(`${r.name}, line ${n}`)
    }
    expect(wrong).toEqual([])
  })

  test('the mark is on the command the heredoc feeds, with its own reason, and the words are read as before', () => {
    const marks = (cmd: string) => pipeline(cmd).map(c => [c.words, c.unread])
    expect(READ_STOPPED.has(ENDS)).toBe(true)
    // A marker joined to the line before: every shell reads on to the end.
    expect(marks(`cat <<E\na${BS}\nE\ngit status`)).toEqual([[['cat', '<<E'], ENDS], [['git', 'status'], undefined]])
    // A marker after spaces: every shell reads on to the marker itself.
    expect(marks(`cat <<E\nbody\n  E\ngit status\nE\ngit log`)).toEqual([[['cat', '<<E'], ENDS], [['git', 'status'], undefined], [['E'], undefined], [['git', 'log'], undefined]])
    // A marker split over two lines: bash and zsh end the heredoc there and run the next line.
    expect(pipeline(`cat <<EOF\nbody\nE${BS}\nOF\ngit status\nEOF\ngit log`).map(c => c.unread)).toContain(ENDS)
    // An opener joined to the next line before its marker: the marker is not the word on that line.
    expect(pipeline(`cat <<${BS}\nE\nbody\nE\ngit log`).some(c => c.unread === ENDS)).toBe(true)
    expect(pipeline(`cat <<E${BS}\nx\nbody\nEx\ngit status\nE${BS}\ngit log`).some(c => c.unread !== undefined && READ_STOPPED.has(c.unread))).toBe(true)
    // Inside a substitution the mark is on the command the heredoc feeds there.
    expect(pipeline(`echo "$(cat <<E\nbody\n E\nmore\nE\n)"\ngit log`).some(c => c.unread === ENDS)).toBe(true)
  })

  test('the controls: a backslash that joins nothing at the marker, and tabs a <<- lets go of, mark nothing', () => {
    const quiet = [
      `cat <<E\na${BS}\nb\nE\ngit status`,
      `cat <<E\na${BS}${BS}\nE\ngit status`,
      `cat <<'E'\na${BS}\nE\ngit status`,
      `cat <<-E\n\tbody\n\t\tE\ngit status`,
      `cat <<E | sort ${BS}\n  -u\nbody\nE\ngit status`,
    ]
    expect(quiet.filter(cmd => pipeline(cmd).some(c => c.unread !== undefined))).toEqual([])
  })
})

// #3496: commands a shell runs that the reader did not give, or gave with the wrong program, each
// with no mark. Every text here was run on 2026-11-25 on the personal MacBook in bash 3.2.57 and
// zsh 5.9, once each as a -c text, with stand in programs that only log their own words (p1 to
// p5), in an empty folder: what each shell ran is in the comment above its test. Where the reader
// can read the shape as the only shell that runs it does, it does. Where the two shells part, or
// the reader cannot follow, the command keeps its words and is marked unread with a reason of its
// own that joins READ_STOPPED, the direction every guard reads as hold or ask.
describe('the commands the reader missed (#3496)', () => {
  const BS = '\\'
  const VT = String.fromCharCode(11)
  const CR = String.fromCharCode(13)
  const ZSH = 'holding a pattern whose qualifier zsh may run as code, so what the shell runs there cannot be read'
  const WORD = 'holding a word bash and zsh do not hand on alike, so what it names cannot be read'
  const JOINED = 'holding a backslash and a new line inside what bash joins into one mark and zsh does not, so what the shell runs there cannot be read'
  const INPUTS = 'given more than one input, which zsh feeds it one after another and bash only the last of, so what it reads cannot be read'
  const UNPLACED = 'beside a heredoc that no word of a command opens as read, so what is fed its body cannot be read'
  const SOURCE = 'run as text by source from its standard input, which cannot be read, so what it runs cannot be read'
  const SHELLS = 'read past a quote bash and zsh do not read alike, so what the shell runs from that quote on cannot be read'
  const marks = (cmd: string) => pipeline(cmd).map(c => [c.words, c.unread])
  const programs = (cmd: string) => pipeline(cmd).map(c => c.words[0])

  test('every new reason is one the reader gives beside the words, never in their place', () => {
    for (const why of [ZSH, WORD, JOINED, INPUTS, UNPLACED, SOURCE]) expect(READ_STOPPED.has(why)).toBe(true)
  })

  // zsh ran p2 once for each of the three files the pattern matched, then p1. bash refused the line.
  test('a pattern whose qualifier zsh runs as code marks its command', () => {
    expect(marks(`p1 /usr/bin/tru*(e:'p2 q':)`)).toEqual([[['p1', '/usr/bin/tru*(e:p2 q:)'], ZSH]])
    expect(marks(`p1 *(+p2)`)).toEqual([[['p1', '*(+p2)'], ZSH]])
    expect(marks(`p1 *(e{'p2 q'}) ; p3`)).toEqual([[['p1', '*(e{p2 q})'], ZSH], [['p3'], undefined]])
  })
  // zsh ran p1 with the one newest file and nothing else: a qualifier that sorts runs no code.
  test('the controls: a qualifier that only sorts or picks, an array, and a function mark nothing', () => {
    const quiet = [`p1 /usr/bin/tru*(om[1])`, `p1 *(.N)`, `x=(one +two) ; p1 a`, `x+=(e)`, `f() { p1 a; }`, `p1 "*(e:p2:)"`, `[[ $x == *(e) ]] && p1`, `p1 a(e)b`]
    expect(quiet.filter(cmd => pipeline(cmd).some(c => c.unread !== undefined))).toEqual([])
  })

  // zsh ran p2 with b, then p1 with a, a file's name and c. bash refused the line.
  test('zsh =( ) where a word begins: the commands inside are read, beside the words as they were', () => {
    const cmds = pipeline(`p1 a =(p2 b) c`)
    // The command it stands in keeps the words the reader always gave it, so a guard that read a
    // file's name from one of them still does: the commands inside are added and nothing is taken.
    expect(cmds.map(c => c.words)).toEqual([['p2', 'b'], ['p1', 'a', '=(p2', 'b)', 'c']])
    expect(cmds[0]?.substitution).toBe(true)
    expect(marks(`=(p2) a`)).toEqual([[['p2'], undefined], [['=(p2)', 'a'], undefined]])
    expect(commands(`p1 =(p2; p3 x) c`)).toEqual([['p2'], ['p3', 'x'], ['p1', '=(p2'], ['p3', 'x)', 'c']])
    // An array is still set, and inside double quotes it is text.
    expect(commands(`x=(a) ; p1 "=(p2)"`)).toEqual([['p1', '=(p2)']])
  })

  // Two zsh shapes the first commit of #3496 read as zsh does, put back as they were, because that
  // reading could give a guard less (measured 2026-11-25, bash 3.2.57 and zsh 5.9, once each).
  // `{ p1 a } always { p2 b; }`: zsh ran p1 with a and then p2 with b, and bash ran p1 with the
  // words a, }, always, {, p2 and b. Read as zsh does, the words bash hands p1 were gone, so
  // `{ rm a } always { FILE; }` no longer removed FILE to the write reader. The reading is main's
  // again until Dan chooses between a mark and both readings side by side.
  test('zsh always on one line is left as it was read: bash hands the first command every word', () => {
    expect(commands(`{ p1 a } always { p2 b; }`)).toEqual([['p1', 'a', '}', 'always', '{', 'p2', 'b'], ['}']])
    expect(commands(`p1 a } always b`)).toEqual([['p1', 'a', '}', 'always', 'b']])
    expect(marks(`{ p1 } always { p2 }`)).toEqual([[['p1', '}', 'always', '{', 'p2', '}'], undefined]])
  })
  // `noglob p1 a`, `nocorrect p1 a` and `repeat 2 p1 a`: zsh ran p1 with a (twice for repeat), and
  // bash found no command of that name. Looked past, `noglob cat FILE` stopped being a program
  // the mods do not know handed FILE, which several guards ask about, and became a plain read:
  // right for both shells, and still a verdict that moves from ask to pass. Left as it was.
  test('zsh words that only run the command after them are left as the program they were read as', () => {
    expect(commands(`noglob p1 a`)).toEqual([['noglob', 'p1', 'a']])
    expect(commands(`nocorrect p1 a`)).toEqual([['nocorrect', 'p1', 'a']])
    expect(commands(`p4\n- p1 a`)).toEqual([['p4'], ['-', 'p1', 'a']])
    expect(commands(`repeat 2 p1 a`)).toEqual([['repeat', '2', 'p1', 'a']])
    expect(pipeline(`noglob rm x`)[0]?.behind).toBe(undefined)
  })

  // Both shells ran p2 and then p3 with the word a, the character and #x.
  test('a # after a character only JavaScript calls a space starts no comment', () => {
    expect(programs(`p3 a${VT}#x $(p2)`)).toEqual(['p2', 'p3'])
    expect(programs(`p3 a${CR}#x $(p2)`)).toEqual(['p2', 'p3'])
    // Both shells fed p3 the body and ran p2 and p1. The reader read the body's lines as commands,
    // where the apostrophe opened a quote that took p2 and p1 for its text. The heredoc opens now,
    // so p2 and p1 are given, and its lines are still read as commands beside it, as they were.
    const cmds = pipeline(`p3 a${VT}#x <<EOF\nit's\nEOF\np2 ; p1 'y' # z'`)
    expect(cmds.map(c => c.words)).toEqual([['its\nEOF'], ['p3', `a${VT}#x`, '<<EOF'], ['p2'], ['p1', 'y']])
    expect(cmds[1]?.heredocs?.[0]?.body).toBe("it's")
    expect(commands(`p3 a${VT}#x <<EOF\nit's\nEOF\np2 ; p1 'y' # z'`.replace(VT, CR)).slice(2)).toEqual([['p2'], ['p1', 'y']])
  })
  // Both shells ran p2 with `a #b` and printed the body, then ran p4.
  test('a # after an escaped blank starts no comment, so the heredoc after it opens', () => {
    // The heredoc's lines were read as commands before, and still are, beside the heredoc.
    const cmds = pipeline(`p2 a${BS} #b ; cat <<EOF\np3 x\nEOF\np4 y`)
    expect(cmds.map(c => c.words)).toEqual([['p2', 'a #b'], ['p3', 'x'], ['EOF'], ['cat', '<<EOF'], ['p4', 'y']])
    expect(cmds[3]?.heredocs?.[0]?.body).toBe('p3 x')
    // A heredoc after a real comment sign opens none, and one that always opened is read as it was.
    expect(commands(`p2 a #b ; cat <<EOF\np3 x\nEOF\np4 y`)).toEqual([['p2', 'a'], ['p3', 'x'], ['EOF'], ['p4', 'y']])
    expect(commands(`p2 a ; cat <<EOF\np3 x\nEOF\np4 y`)).toEqual([['p2', 'a'], ['cat', '<<EOF'], ['p4', 'y']])
    // Both shells ran p3 inside the substitution: the ; is escaped, so the # is in the word.
    expect(programs(`p2 a${BS};#b $(p3 x)`)).toEqual(['p3', 'p2'])
    // A joined line: after a blank the # is a comment (both ran p2 and p4 alone), after a letter
    // it is part of the word (both ran p3, p2 and p4).
    expect(programs(`p2 a ${BS}\n#b $(p3 x)\np4`)).toEqual(['p2', 'p4'])
    expect(programs(`p2 a${BS}\n#b $(p3 x)\np4`)).toEqual(['p3', 'p2', 'p4'])
    // An ordinary comment is one still.
    expect(commands(`p1 a # b $(p3 x)\np4 ;# c $(p3)`)).toEqual([['p1', 'a'], ['p4']])
  })

  // bash ran p3 with x, zsh with $x.
  test('a $"..." word marks its command', () => {
    expect(marks(`p3 $"x" ; p2`)).toEqual([[['p3', '$x'], WORD], [['p2'], undefined]])
    expect(marks(`p3 "a$" "b" ${BS}$"c"`).map(m => m[1])).toEqual([undefined])
  })

  // bash ran p1 and p2, zsh nothing.
  test('a quote after a ${ } inside another ${ } in double quotes is one the shells read differently', () => {
    expect(pipeline(`p1 "\${u:-\${v}'"'}" ; p2 # it's`).map(c => c.unread)).toEqual([SHELLS])
    // Both ran p1 and p2.
    expect(marks(`p1 "\${u:-\${v:-'a'}}" ; p2 # it's`)).toEqual([[['p1', "${u:-${v:-'a'}}"], undefined], [['p2'], undefined]])
  })

  // bash ran p3 inside a substitution and zsh handed the text on; bash opened a heredoc and zsh
  // refused the line; both read a $'...' string.
  test('a backslash and a new line right after a $ or between two < marks its command', () => {
    expect(marks(`p1 "$${BS}\n(p3 a)"`)).toEqual([[['p1', '$(p3 a)'], JOINED]])
    expect(pipeline(`cat <${BS}\n<EOF\np2 x\nEOF\np3 y`).map(c => c.unread)).toEqual([JOINED, undefined, undefined, undefined])
    expect(pipeline(`p1 $${BS}\n'a' ; p2`).map(c => c.unread)).toEqual([JOINED, undefined])
    // An ordinary continuation between words marks nothing.
    expect(marks(`p1 a ${BS}\n  b`)).toEqual([[['p1', 'a', 'b'], undefined]])
  })

  // zsh fed p2 the piped line and then the body; bash fed it the body alone.
  test('a command given more than one input is marked', () => {
    expect(pipeline(`echo piped | p2 <<EOF\nbody\nEOF`).map(c => c.unread)).toEqual([undefined, INPUTS])
    expect(pipeline(`p2 <<A <<B\none\nA\ntwo\nB`).map(c => c.unread)).toEqual([INPUTS])
    expect(pipeline(`p2 <<A </dev/null\none\nA`).map(c => c.unread)).toEqual([INPUTS])
    expect(pipeline(`p2 <<A <<<x\none\nA`).map(c => c.unread)).toEqual([INPUTS])
    // zsh ran `p3 one` from the pipe as sh's script; bash ran `p2 two` from the body alone.
    expect(marks(`echo p3 one | sh <<EOF\np2 two\nEOF`)).toEqual([[['echo', 'p3', 'one'], undefined], [['p2', 'two'], INPUTS]])
    // A group fed by a pipe and given a heredoc: zsh fed p2 both, bash the body alone.
    expect(marks(`echo piped | { p2; } <<EOF\nbody\nEOF`)).toEqual([[['echo', 'piped'], undefined], [['p2'], undefined], [['}', '<<EOF'], INPUTS]])
  })
  test('the controls: one input each, a loop fed by a pipe, a quoted < and a test mark nothing', () => {
    const quiet = [
      `cat <<EOF | p2\nbody\nEOF`,
      `echo a | while read l; do p2 <<<"$l"; done`,
      `p1 < a.txt | p2 > b.txt`,
      `echo a | grep '<' a.txt`,
      `echo a | p2 "<b" '<<c'`,
      `while read l; do p2; done < a.txt`,
      `[[ a < b ]] && p1 < c.txt`,
    ]
    expect(quiet.filter(cmd => pipeline(cmd).some(c => c.unread !== undefined))).toEqual([])
  })

  // Both shells ran p2 with x from the body, then p3.
  test('a heredoc no word of a command opens marks the command beside it, and its lines are read as commands', () => {
    expect(marks(`bash -s '<'<<'EOF'\np2 x\nEOF\np3 y`)).toEqual([[['p2', 'x'], undefined], [['EOF'], undefined], [['EOF'], UNPLACED], [['p3', 'y'], undefined]])
    expect(pipeline(`cat '<'<<'EOF'\np2 x\nEOF\np3 y`).find(c => c.words[0] === 'cat')?.unread).toBe(UNPLACED)
    // A heredoc a word opens marks nothing.
    expect(marks(`cat <<'EOF'\np2 x\nEOF\np3 y`)).toEqual([[['cat', '<<EOF'], undefined], [['p3', 'y'], undefined]])
  })

  // Both shells ran p2 with x.
  test('source and . reading standard input: the text there is read as commands', () => {
    expect(commands(`source /dev/stdin <<'EOF'\np2 x\nEOF`)).toEqual([['source', '/dev/stdin', '<<EOF'], ['p2', 'x']])
    expect(commands(`. /dev/stdin <<'EOF'\np2 x\np3\nEOF`)).toEqual([['.', '/dev/stdin', '<<EOF'], ['p2', 'x'], ['p3']])
    expect(commands(`echo p2 x | source /dev/stdin`)).toEqual([['echo', 'p2', 'x'], ['source', '/dev/stdin'], ['p2', 'x']])
    // What cannot be read is said, and a file is a file.
    expect(marks(`p1 | source /dev/stdin`)).toEqual([[['p1'], undefined], [['source', '/dev/stdin'], SOURCE]])
    expect(marks(`source ./env.sh`)).toEqual([[['source', './env.sh'], undefined]])
  })

  // zsh piped p1 into p2 in each. bash refused each line.
  test('a ; right after a pipe: zsh pipes into the command after it', () => {
    for (const cmd of [`p1 x |; p2`, `p1 x | ; p2`, `p1 x |& ; p2`, `p1 x |\n; p2`]) {
      const cmds = pipeline(cmd)
      expect(cmds.map(c => c.words)).toEqual([['p1', 'x'], ['p2']])
      expect(cmds[1]?.pipedFrom).toEqual(['p1', 'x'])
    }
    // A ; with no pipe before it pipes nothing.
    expect(pipeline(`p1 ; p2`)[1]?.pipedFrom).toBe(undefined)
    // A case clause's ;; after a pipe is no such thing: both shells refuse the line, and the ;;
    // still ends the clause, so the next pattern is a pattern and never a command. Taken for a
    // single ; it left `b` and `)` read as two commands.
    for (const cmd of [`case x in a) p1 | ;; b) p2 ;; esac`, `case x in a) p1 |;; b) p2 ;; esac`]) {
      expect(commands(cmd)).toEqual([['case', 'x', 'in'], ['p1'], ['p2'], ['esac']])
      expect(pipeline(cmd).some(c => c.pipedFrom !== undefined)).toBe(false)
    }
  })

  // After `(( 1 +`, `2 # it's` and `))`, zsh ran the two lines below and bash nothing; with `$((`
  // bash ran them and zsh nothing.
  test('a # and then a quote inside (( )) is read by one shell as a comment and by the other as a quote', () => {
    expect(new Set(pipeline(`(( 1 +\n2 # it's\n))\np2 x\np3 ' y'`).map(c => c.unread))).toEqual(new Set([SHELLS]))
    expect(new Set(pipeline(`p1 $(( 1 +\n2 # it's\n))\np2 x\np3 ' y'`).map(c => c.unread))).toEqual(new Set([SHELLS]))
    // A comment with no quote, and a # that starts none, mark nothing.
    expect(pipeline(`(( 1 +\n2 # two\n))\np2 x`).some(c => c.unread !== undefined)).toBe(false)
    expect(pipeline(`p1 $(( \${#a} + 1 )) "b"`).some(c => c.unread !== undefined)).toBe(false)
  })
})

// claude-config#3442: four shapes the reader misread, each measured 2026-11-26 on the personal
// MacBook (bash 3.2.57, zsh 5.9, macOS sh, dash and ksh93), one run of each form in an empty folder
// with programs that only make a file, the folder listed afterwards. The third, a shell told only to
// check its script, is in program.test.ts.
describe('four shapes the reader misread (#3442)', () => {
  const NAMED = 'named by a value the shell expands, so what it runs cannot be read'
  const marked = (cmd: string) => pipeline(cmd).map(c => [c.words.join(' '), c.unread])
  const tests = (cmd: string) => pipeline(cmd).map(c => [c.words.join(' '), c.compares?.flatMap((is, n) => (is ? [n] : [])), c.behind])

  // 1. dash reads `((` as two subshells, so `dash -c '(( $x > 3 ))'` runs the program `$x` names
  // (measured: with x holding a program that makes a file, the file is there, and so is one named
  // 3). The reader dropped the command's unread mark as if every shell worked the text out as
  // arithmetic. sh is read as dash is, as it is everywhere else (#3415, worksTests).
  test('a command named by a value inside (( )) is unread where the shell reads (( as two subshells', () => {
    for (const shell of ['dash', 'sh']) {
      expect(marked(`${shell} -c '(( $x > 3 ))'`)).toEqual([['(', undefined], ['(', undefined], ['$x > 3', NAMED], [')', undefined], [')', undefined]])
      expect(marked(`${shell} -c '(( $# < 2 )) && exit 1'`).filter(c => c[1] !== undefined)).toEqual([['$# < 2', NAMED]])
    }
  })
  test('where the shell works (( )) out as arithmetic, a value in it still names no command', () => {
    // Measured: bash, zsh and ksh make no file for it.
    for (const cmd of ['(( $x > 3 ))', `bash -c '(( $x > 3 ))'`, `zsh -c '(( $x > 3 ))'`, `ksh -c '(( $x > 3 ))'`, '(( $# < 2 )) && exit 1']) {
      expect([cmd, pipeline(cmd).some(c => c.unread !== undefined)]).toEqual([cmd, false])
    }
  })

  // 2. `echo $'\' x' | (cat; echo ran) #'`: the reader took the `\'` to end the string, so the pipe
  // and the group stood inside a quote and one echo was read. Fixed by pull request #3493 (the
  // $'...' reading, opensAnsi); kept here as a pin on the exact shape the issue names.
  test("an escaped quote inside $'...' does not hide the pipe and the group after it", () => {
    const BS = '\\'
    expect(commands(`echo $'${BS}' x' | (cat; echo ran) #'`)).toEqual([['echo', `$${BS}' x`], ['('], ['cat'], ['echo', 'ran'], [')']])
    expect(pipeline(`echo $'${BS}' x' | (cat; echo ran) #'`).some(c => c.unread !== undefined)).toBe(false)
  })

  // 4. `time` before a test and a redirect written right after its `]]`. Measured: bash, zsh and ksh
  // make no file b for `time [[ a > b ]]`, and only out for `[[ a > b ]]>out`. Neither was read as a
  // test, so its `>` was a redirect and its `||` ended the command.
  test('time before a test leaves it a test', () => {
    expect(tests('time [[ a > b ]]')).toEqual([['[[ a > b ]]', [2], ['time']]])
    expect(tests('true && time [[ a > b ]]; ( time [[ a < b ]] )').filter(c => c[1])).toEqual([['[[ a > b ]]', [2], ['time']], ['[[ a < b ]]', [2], ['time']]])
    expect(tests('time [[ a > b ]] > out')).toEqual([['[[ a > b ]] > out', [2], ['time']]])
    // Its || and && are words of the test, so a value in it names no command.
    expect(commands('time [[ -z "$r" || "$r" == x ]]')).toEqual([['[[', '-z', '$r', '||', '$r', '==', 'x', ']]']])
    expect(pipeline('time [[ -z "$r" || "$r" == x ]]').some(c => c.unread !== undefined)).toBe(false)
  })
  test('time is no reserved word of the shell in these places, so what follows is read as it was', () => {
    // Each measured as making the file b in bash 3.2: after a pipe, an `if`, a `!` or a case's
    // pattern `time` is the program, and so is one quoted, escaped, named by its path, run through
    // `command`, set a value in front of, given `--`, or written twice. `time -p [[ a > b ]]` makes
    // b in ksh.
    for (const cmd of [
      'true | time [[ a > b ]]',
      'if time [[ a > b ]]; then p1; fi',
      '! time [[ a > b ]]',
      'case x in x) time [[ a > b ]];; esac',
      '"time" [[ a > b ]]',
      '\\time [[ a > b ]]',
      '/usr/bin/time [[ a > b ]]',
      'command time [[ a > b ]]',
      'X=1 time [[ a > b ]]',
      'time -p [[ a > b ]]',
      'time -- [[ a > b ]]',
      'time time [[ a > b ]]',
    ])
      expect([cmd, pipeline(cmd).some(c => c.compares !== undefined)]).toEqual([cmd, false])
  })
  test('a redirect written right after ]] leaves the test a test', () => {
    expect(tests('[[ a > b ]]>out')).toEqual([['[[ a > b ]] > out', [2], undefined]])
    expect(tests('[[ a > b ]]>>out')).toEqual([['[[ a > b ]] >> out', [2], undefined]])
    // An input redirect is given with its file in the one word, as it is anywhere else.
    expect(tests('[[ a < b ]]<in')).toEqual([['[[ a < b ]] <in', [2], undefined]])
    expect(tests('if [[ a > b ]]>out; then p1; fi').slice(0, 1)).toEqual([['[[ a > b ]] > out', [2], undefined]])
    expect(tests('time [[ a > b ]]>out')).toEqual([['[[ a > b ]] > out', [2], ['time']]])
    expect(commands('[[ -z "$r" || "$r" == x ]]>out')).toEqual([['[[', '-z', '$r', '||', '$r', '==', 'x', ']]', '>', 'out']])
  })
  test('a ]] with a word joined to it closes no test', () => {
    // Measured: bash, zsh and ksh refuse `[[ a > b ]]2>err` and `[[ a > b]]>out` and make no file.
    for (const cmd of ['[[ a > b ]]2>err', '[[ a > b]]>out', '[[ a > b ]]x']) expect([cmd, pipeline(cmd).some(c => c.compares !== undefined)]).toEqual([cmd, false])
  })
  test('sh and dash, where [[ is a program, read both forms as they did', () => {
    // Measured: dash makes b for each, and it runs what follows a || there, so nothing is joined.
    for (const shell of ['dash', 'sh']) {
      for (const text of ['time [[ a > b ]]', '[[ a > b ]]>out']) expect([shell, text, pipeline(`${shell} -c '${text}'`).some(c => c.compares !== undefined)]).toEqual([shell, text, false])
      expect(commands(`${shell} -c 'time [[ -z a || p1 b ]]'`)).toEqual([['[[', '-z', 'a'], ['p1', 'b', ']]']])
      expect(commands(`${shell} -c '[[ -z a || p1 b ]]>out'`)).toEqual([['[[', '-z', 'a'], ['p1', 'b', ']]', '>', 'out']])
    }
  })
})

// #3468: a command that only sets variables says whether it is sure to have run (`certain`), by the
// one reading of that the reader has (sureSettings): a statement of the line itself, after a `;` or
// a new line, inside nothing that may not run. The run of settings a line opens with (openingRun),
// which the following of a variable alone (fixedWords, #3398) is built on, is the start of it.
describe('a setting that is sure to have run (#3468)', () => {
  const sure = (cmd: string) => pipeline(cmd, { assignments: true }).filter(c => c.words.every(w => /^[A-Za-z_][A-Za-z0-9_]*=/.test(w))).map(c => [c.words.join(' '), c.certain === true])
  test('the run of settings a line opens with, each ended by a ; or a new line', () => {
    expect(sure('F=/a; G=/b\nH=/c; echo x')).toEqual([['F=/a', true], ['G=/b', true], ['H=/c', true]])
    expect(sure('  A=1 B=2 ; echo x')).toEqual([['A=1 B=2', true]])
    // Whatever the value: quoted, under home, a command's output.
    expect(sure(`F=~/a; G="$HOME/b c"; H='x;y'; T=$(mktemp -d); K=/k; echo x`)).toEqual([['F=~/a', true], ['G=$HOME/b c', true], ['H=x;y', true], ['T=$(mktemp -d)', true], ['K=/k', true]])
    // Settings and nothing after them.
    expect(sure('F=/a')).toEqual([['F=/a', true]])
    expect(sure('F=/a; G=/b')).toEqual([['F=/a', true], ['G=/b', true]])
  })
  test('a later statement of the line itself, after a ; or a new line, whatever ran before it', () => {
    expect(sure('make; F=/a; echo x')).toEqual([['F=/a', true]])
    expect(sure('make\nF=/a\necho x')).toEqual([['F=/a', true]])
    expect(sure('make && lint; F=/a; echo x')).toEqual([['F=/a', true]])
    expect(sure("cat > /tmp/x <<'EOF'\nbody\nEOF\nP=/a\necho x")).toEqual([['P=/a', true]])
    // After a branch, a loop, a case or a subshell that has closed, the line is its own again.
    expect(sure('if true; then echo a; fi; F=/a; echo x')).toEqual([['F=/a', true]])
    expect(sure('for x in a b; do echo a; done; F=/a; echo x')).toEqual([['F=/a', true]])
    expect(sure('case x in x) echo a; G=/b;; esac; F=/a; echo x')).toEqual([['G=/b', false], ['F=/a', true]])
    expect(sure('(cd /x; make); F=/a; echo x')).toEqual([['F=/a', true]])
    // The one before an && or || ran in this shell, whatever the joiner then skips.
    expect(sure('F=/a && echo x')).toEqual([['F=/a', true]])
    expect(sure('make; F=/a && echo x')).toEqual([['F=/a', true]])
    expect(sure('F=/a; G=/b && echo x')).toEqual([['F=/a', true], ['G=/b', true]])
    expect(sure('F=/a || G=/b; echo x')).toEqual([['F=/a', true], ['G=/b', false]])
  })
  test('none behind a joiner that may skip it, inside anything that may not run, or in a shell of its own', () => {
    expect(sure('false && F=/a; echo x')).toEqual([['F=/a', false]])
    expect(sure('true || F=/a; echo x')).toEqual([['F=/a', false]])
    expect(sure('make; false && F=/a; echo x')).toEqual([['F=/a', false]])
    expect(sure('make | F=/a; echo x')).toEqual([['F=/a', false]])
    expect(sure('make & F=/a; echo x')).toEqual([['F=/a', false]])
    expect(sure('make; F=/a | cat; echo x')).toEqual([['F=/a', false]])
    expect(sure('make; F=/a &\necho x')).toEqual([['F=/a', false]])
    expect(sure('if false; then F=/a; fi')).toEqual([['F=/a', false]])
    expect(sure('if false; then echo a; F=/a; fi; echo x')).toEqual([['F=/a', false]])
    expect(sure('if true; then echo a; else echo b; F=/a; fi; G=/b; echo x')).toEqual([['F=/a', false], ['G=/b', true]])
    expect(sure('while false; do echo a; F=/a; done; echo x')).toEqual([['F=/a', false]])
    expect(sure('for x in a b; do echo a; F=/a; done; echo x')).toEqual([['F=/a', false]])
    expect(sure('repeat 3; do echo a; F=/a; done; G=/b; echo x')).toEqual([['F=/a', false], ['G=/b', true]])
    // A word that belongs inside a compound command, standing where none is open, loses the place.
    expect(sure('make; do echo a; F=/a; done; G=/b; echo x')).toEqual([['F=/a', false], ['G=/b', false]])
    expect(sure('make; }; F=/a; echo x')).toEqual([['F=/a', false]])
    expect(sure('f() { F=/a; }')).toEqual([['F=/a', false]])
    expect(sure('(F=/a; echo x)')).toEqual([['F=/a', false]])
    expect(sure('make; (echo a; F=/a; echo x)')).toEqual([['F=/a', false]])
    expect(sure('{ F=/a; echo x; }')).toEqual([['F=/a', false]])
    expect(sure('make && { echo a; F=/a; echo x; }')).toEqual([['F=/a', false]])
    expect(sure('make && { case x in x) echo a;; esac; F=/a; echo x; }')).toEqual([['F=/a', false]])
    // Once a function is defined the reading stops: zsh takes the command after `name()` as its body.
    expect(sure('f() { echo a; }; F=/a; echo x')).toEqual([['F=/a', false]])
    expect(sure('f() echo a; F=/a; echo x')).toEqual([['F=/a', false]])
    expect(sure('function f { echo a; }; F=/a; echo x')).toEqual([['F=/a', false]])
    // A comment between the statement before and the setting is not read.
    expect(sure('make # note\nF=/a; echo x')).toEqual([['F=/a', false]])
    // Before a | or a & it ran in a shell of its own.
    expect(sure('F=/a | cat; echo x')).toEqual([['F=/a', false]])
    expect(sure('F=/a & echo x')).toEqual([['F=/a', false]])
    expect(sure('F=/a; G=/b &\necho x')).toEqual([['F=/a', true], ['G=/b', false]])
    // A comment between the setting and its end, and two lines joined by a backslash, are not read.
    expect(sure('F=/a \\\nG=/b; echo x')).toEqual([['F=/a G=/b', false]])
  })
  test('never in text a line holds and runs among its own commands: a script, a trap', () => {
    expect(sure(`bash -c 'F=/a; echo x'`)).toEqual([['F=/a', false]])
    expect(sure(`trap 'F=/a' EXIT; echo x`)).toEqual([['F=/a', false]])
    // A substitution's text is a line of its own, with a run of its own.
    expect(sure('echo "$(F=/a; echo x)"')).toEqual([['F=/a', true]])
  })
  test('a heredoc or a (( )) after the run takes nothing from it: the setting still ran', () => {
    // fixedWords follows no variable in such a line, for what else may change one, which is another
    // question than whether the setting ran.
    expect(sure("F=/a; cat > \"$F\" <<'EOF'\nx\nEOF")).toEqual([['F=/a', true]])
    expect(sure('F=/a; (( n > 3 ))')).toEqual([['F=/a', true]])
    expect(pipeline("W=/other; git -C \"$W\" status <<'EOF'\nx\nEOF", { follow: true }).some(c => c.followed !== undefined)).toBe(false)
  })
  test('it is given only to a reader that asks for the settings', () => {
    expect(pipeline('F=/a; echo x')).toEqual([{ words: ['echo', 'x'] }])
    expect(pipeline('F=/a; echo x', { assignments: true })).toEqual([{ words: ['F=/a'], certain: true }, { words: ['echo', 'x'] }])
  })
})
