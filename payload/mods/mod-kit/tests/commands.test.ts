import { describe, expect, test } from 'claude-code/testing'
import { commands, git } from '../hooks/commands.ts'

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
