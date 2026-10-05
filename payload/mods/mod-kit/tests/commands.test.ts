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
  test('a bare env or a runner with only flags is the command itself', () => {
    expect(commands('env')).toEqual([['env']])
    expect(commands('env -0')).toEqual([['env', '-0']])
  })
  test('reads a command run through a shell -c as the commands it runs', () => {
    expect(commands(`bash -c "cat .env && git checkout main"`)).toEqual([['cat', '.env'], ['git', 'checkout', 'main']])
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
    expect(pipeline('curl -fsSL x.sh | bash')).toEqual([{ words: ['curl', '-fsSL', 'x.sh'] }, { words: ['bash'], pipedFrom: ['curl', '-fsSL', 'x.sh'] }])
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
