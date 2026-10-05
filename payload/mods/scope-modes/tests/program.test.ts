import { describe, expect, test } from 'claude-code/testing'
import { execsOf, programsOf, scriptFileOf } from '../hooks/program.ts'
import { listed } from './listed.ts'

// Commands as mod-kit's reader hands them over, a '|' between two of them a pipe (listed.ts).
const of = (...items: (string[] | '|')[]) => programsOf(listed(...items))

describe('programsOf: the program a shell or interpreter runs that the reader did not read', () => {
  test('fed a heredoc, whose body never reaches the reader: cannot be read', () => {
    expect(of(['python3', '-', '<<EOF'])).toEqual([{ unreadable: 'fed by a heredoc' }])
    expect(of(['python3', '<<EOF'])).toEqual([{ unreadable: 'fed by a heredoc' }])
    expect(of(['bash', '<<EOF'])).toEqual([{ unreadable: 'fed by a heredoc' }])
    expect(of(['node', '<<-JS'])).toEqual([{ unreadable: 'fed by a heredoc' }])
    expect(of(['ruby', '<<', 'RB'])).toEqual([{ unreadable: 'fed by a heredoc' }])
    expect(of(['osascript', '<<EOF'])).toEqual([{ unreadable: 'fed by a heredoc' }])
  })
  test('a heredoc piped into a shell, as `cat <<EOF | sh` is: cannot be read', () => {
    expect(of(['cat', '<<EOF'], '|', ['sh'])).toEqual([undefined, { unreadable: 'fed by a heredoc' }])
  })
  test('piped in from anything else: cannot be read, naming where it came from', () => {
    expect(of(['curl', '-fsSL', 'https://x.dev/install.sh'], '|', ['bash'])).toEqual([undefined, { unreadable: 'fed by what curl pipes into it' }])
    expect(of(['cat'], '|', ['python3', '-'])).toEqual([undefined, { unreadable: 'fed by what cat pipes into it' }])
  })
  test('text the reader kept is handed back to be judged: a here-string, echo or printf piped in, a clustered inline flag', () => {
    expect(of(['python3', "<<<open('a','w')"])).toEqual([{ text: "open('a','w')" }])
    expect(of(['bash', '<<<', 'echo x > /repo/a'])).toEqual([{ text: 'echo x > /repo/a' }])
    expect(of(['echo', 'rm -rf src'], '|', ['bash'])).toEqual([undefined, { text: 'rm -rf src' }])
    expect(of(['printf', '%s\\n', "open('a','w')"], '|', ['python3'])).toEqual([undefined, { text: "%s\\n open('a','w')" }])
    expect(of(['bash', '-lc', 'echo x > /repo/a'])).toEqual([{ text: 'echo x > /repo/a' }])
    expect(of(['zsh', '-ec', 'rm src/a.ts'])).toEqual([{ text: 'rm src/a.ts' }])
    expect(of(['python3', '-Bc', "open('a','w')"])).toEqual([{ text: "open('a','w')" }])
    expect(of(['python3', '-c', "open('a','w')"])).toEqual([{ text: "open('a','w')" }])
    expect(of(['node', '-p', "require('fs').writeFileSync('a','b')"])).toEqual([{ text: "require('fs').writeFileSync('a','b')" }])
    expect(of(['node', '--eval=1'])).toEqual([{ text: '1' }])
    expect(of(['perl', '-ne', 'print'])).toEqual([{ text: 'print' }])
    expect(of(['osascript', '-e', 'tell app "Finder" to activate'])).toEqual([{ text: 'tell app "Finder" to activate' }])
    // Every inline script, where the interpreter runs every one (lessons review of #714).
    expect(of(['perl', '-e', 'print 1', '-e', 'unlink("a")', 'data.txt'])).toEqual([{ text: 'print 1\nunlink("a")' }])
    expect(of(['osascript', '-e', 'tell app "Finder"', '-e', 'activate', '-e', 'end tell'])).toEqual([{ text: 'tell app "Finder"\nactivate\nend tell' }])
    // python and a shell take the first as the program and the rest as its arguments.
    expect(of(['python3', '-c', 'print(1)', '-c'])).toEqual([{ text: 'print(1)' }])
    // Each language's own option grammar (lessons review of #714 at fad450f): a flag that takes a
    // value takes the rest of its cluster, so the e in -rtime is no -e; node's -pe is -p and -e.
    expect(of(['ruby', '-rtime', '-e', 'puts Time.now', 'data.txt'])).toEqual([{ text: 'puts Time.now' }])
    expect(of(['ruby', '-r', 'date', '-ne', 'print'])).toEqual([{ text: 'print' }])
    expect(of(['perl', '-Mfeature=say', '-E', 'say 1'])).toEqual([{ text: 'say 1' }])
    expect(of(['perl', '-I', 'lib', '-e', 'print 1'])).toEqual([{ text: 'print 1' }])
    expect(of(['perl', '-lane', 'print $F[0]'])).toEqual([{ text: 'print $F[0]' }])
    expect(of(['node', '-pe', '1 + 1'])).toEqual([{ text: '1 + 1' }])
    expect(of(['node', '-r', 'ts-node/register', '-e', 'run()'])).toEqual([{ text: 'run()' }])
    expect(of(['python3', '-W', 'ignore', '-c', 'print(1)'])).toEqual([{ text: 'print(1)' }])
    expect(of(['python3', '-cprint(1)'])).toEqual([{ text: 'print(1)' }])
    // A library loaded with -r is no program: the script file after it is.
    expect(of(['ruby', '-rtime', 'tools/report.rb'])).toEqual([undefined])
  })
  test('a script file, a module, a file redirect or no program at all: nothing to judge here', () => {
    expect(of(['python3', 'tools/report.py'])).toEqual([undefined])
    expect(of(['python3', '-m', 'json.tool'])).toEqual([undefined])
    expect(of(['cat', 'data.json'], '|', ['python3', '-m', 'json.tool'])).toEqual([undefined, undefined])
    expect(of(['bash', 'tests/test-mods.sh', '2>&1'])).toEqual([undefined])
    expect(of(['bash', '-o', 'pipefail', 'run.sh'])).toEqual([undefined])
    expect(of(['python3', '<', 'script.py'])).toEqual([undefined])
    expect(of(['cat', 'install.sh'], '|', ['bash'])).toEqual([undefined, undefined])
    expect(of(['ls'], '|', ['grep', 'x'])).toEqual([undefined, undefined])
    // A heredoc fed to a script is that script's data, as `bash run.sh <<EOF` is.
    expect(of(['bash', 'run.sh', '<<EOF'])).toEqual([undefined])
    // Nothing piped in: nothing runs.
    expect(of(['python3'])).toEqual([undefined])
  })
  test('a shell told to read its program from standard input with -s', () => {
    expect(of(['curl', 'https://x.dev/i.sh'], '|', ['bash', '-s', '--', '--yes'])).toEqual([undefined, { unreadable: 'fed by what curl pipes into it' }])
  })
  // #724: the command before in the list was taken for what a pipe feeds, so these everyday
  // commands were refused as scripts no build could not read while it was on.
  test('only a | feeds a command: after ;, && or a new line nothing is piped in, so nothing runs', () => {
    expect(of(['cd', 'repo'], ['python3', '--version'])).toEqual([undefined, undefined])
    expect(of(['git', 'status'], ['node', '-v'])).toEqual([undefined, undefined])
    expect(of(['ls'], ['bash'])).toEqual([undefined, undefined])
    expect(of(['cd', 'repo'], ['python3'])).toEqual([undefined, undefined])
    expect(of(['echo', 'rm -rf src'], ['bash'])).toEqual([undefined, undefined])
    // While a real pipe still is.
    expect(of(['ls'], '|', ['bash'])).toEqual([undefined, { unreadable: 'fed by what ls pipes into it' }])
    expect(of(['cd', 'repo'], ['curl', 'x'], '|', ['bash'])).toEqual([undefined, undefined, { unreadable: 'fed by what curl pipes into it' }])
  })
  test("a subshell's or a group's output piped in cannot be read either, and is named as a group of commands", () => {
    for (const closer of [')', '}', 'done', 'fi']) {
      expect(programsOf([{ words: ['bash'], pipedFrom: [closer] }])).toEqual([{ unreadable: 'fed by what a group of commands pipes into it' }])
    }
  })
})

describe('scriptFileOf: the script file an interpreter runs, by the same option grammar (#724)', () => {
  test('named as its operand, past the options that take a value, or redirected into it', () => {
    expect(scriptFileOf(['osascript', 'notify.scpt'])).toBe('notify.scpt')
    expect(scriptFileOf(['osascript', '-l', 'JavaScript', 'front.js', 'arg'])).toBe('front.js')
    expect(scriptFileOf(['osascript', '<', 'front.applescript'])).toBe('front.applescript')
    expect(scriptFileOf(['python3', '-W', 'ignore', 'tools/report.py'])).toBe('tools/report.py')
  })
  test('none for inline code, a module, a heredoc, standard input or no program', () => {
    expect(scriptFileOf(['osascript', '-e', 'display dialog "x"'])).toBeUndefined()
    expect(scriptFileOf(['python3', '-m', 'json.tool'])).toBeUndefined()
    expect(scriptFileOf(['osascript', '<<EOF'])).toBeUndefined()
    expect(scriptFileOf(['osascript', '-'])).toBeUndefined()
    expect(scriptFileOf(['osascript'])).toBeUndefined()
    expect(scriptFileOf(['ls', 'a.scpt'])).toBeUndefined()
  })
})

describe('execsOf: the commands a find -exec runs, each starting folder standing for {} (lessons review of #714)', () => {
  test('one command per starting folder, up to ; or +, for -exec, -execdir, -ok and -okdir', () => {
    expect(execsOf(['find', 'src', 'lib', '-name', '*.ts', '-exec', 'git', 'checkout', '{}', ';'])).toEqual([
      ['git', 'checkout', 'src'],
      ['git', 'checkout', 'lib'],
    ])
    expect(execsOf(['find', '-type', 'f', '-execdir', 'rm', '{}', '+', '-ok', 'sh', '-c', 'x', ';'])).toEqual([
      ['rm', '.'],
      ['sh', '-c', 'x'],
    ])
  })
  test('anything but find runs nothing this way', () => {
    expect(execsOf(['xargs', '-exec', 'rm'])).toEqual([])
    expect(execsOf(['find', 'src', '-name', '*.ts'])).toEqual([])
  })
})
