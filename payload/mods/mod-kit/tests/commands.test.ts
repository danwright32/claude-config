import { describe, expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { commands, git, pipeline } from '../hooks/commands.ts'

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
    expect(pipeline('cat <<EOF\ngit status')).toEqual([{ words: ['cat', '<<EOF'] }, { words: ['git', 'status'] }])
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
