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
