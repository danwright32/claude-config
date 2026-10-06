import { describe, expect, test } from 'claude-code/testing'
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
  test('a parenthesis inside a word stays part of it', () => {
    expect(commands('cd $(git rev-parse --show-toplevel)')).toEqual([['cd', '$(git', 'rev-parse', '--show-toplevel)']])
    expect(commands('diff <(sort a) b')).toEqual([['diff', '<(sort', 'a)', 'b']])
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
      },
      { words: ['git', 'status'] },
    ])
  })
  test('a spaced <<, a file descriptor before it, a quoted or escaped delimiter, and the words looked past', () => {
    expect(pipeline('cat << EOF\nls\nEOF')).toEqual([{ words: ['cat', '<<', 'EOF'], heredocs: [{ word: 1, body: 'ls', quoted: false }] }])
    expect(pipeline('cat 0<<"END"\nx\nEND')).toEqual([{ words: ['cat', '0<<END'], heredocs: [{ word: 1, body: 'x', quoted: true }] }])
    expect(pipeline('sudo -E python3 - <<\\EOF\nprint(1)\nEOF')).toEqual([
      { words: ['python3', '-', '<<EOF'], heredocs: [{ word: 2, body: 'print(1)', quoted: true }], language: 'python', program: { text: 'print(1)', stdin: true } },
    ])
  })
  test('<<- takes the leading tabs off its body', () => {
    expect(pipeline('cat <<-EOF\n\tone\n\t\ttwo\n\tEOF')).toEqual([{ words: ['cat', '<<-EOF'], heredocs: [{ word: 1, body: 'one\ntwo', quoted: false }] }])
  })
  test('each of several heredocs feeds its own command, read one after another', () => {
    expect(pipeline('cat <<A; python3 - <<B\na\nA\nb\nB\nls')).toEqual([
      { words: ['cat', '<<A'], heredocs: [{ word: 1, body: 'a', quoted: false }] },
      { words: ['python3', '-', '<<B'], heredocs: [{ word: 2, body: 'b', quoted: false }], language: 'python', program: { text: 'b', stdin: true } },
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
      { words: ['python3', '-', '<<EOF'], heredocs: [{ word: 2, body: 'print(1)', quoted: false }], language: 'python', program: { text: 'print(1)', stdin: true } },
    ])
  })
  test('a heredoc inside a word feeds no command here, and one that never ends has no body', () => {
    expect(pipeline(`git commit -m "$(cat <<'EOF'\nit's done\nEOF\n)"`)).toEqual([{ words: ['git', 'commit', '-m', "$(cat <<'EOF'\n)"] }])
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
    expect(commands('echo $(wc -l<f)')).toEqual([['echo', '$(wc', '-l<f)']])
    expect(commands('diff <(sort a) b')).toEqual([['diff', '<(sort', 'a)', 'b']])
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
    expect(pipeline('ls | xargs rm')).toEqual([{ words: ['ls'] }, { words: ['rm'], pipedFrom: ['ls'], xargs: true }])
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
    expect(pipeline("diff - <<'X' <(sort b)\na\nX")[0]?.heredocs).toEqual([{ word: 2, body: 'a', quoted: true }])
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
})
