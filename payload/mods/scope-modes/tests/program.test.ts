import { describe, expect, test } from 'claude-code/testing'
import { execsOf, programsOf } from '../hooks/program.ts'

// Commands as mod-kit's reader hands them over (heredoc bodies dropped, quotes removed, a pipe a
// separator, `bash -c` already read as the commands it runs), split here by hand.
const of = (...lines: string[][]) => programsOf(lines)

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
    expect(of(['cat', '<<EOF'], ['sh'])).toEqual([undefined, { unreadable: 'fed by a heredoc' }])
  })
  test('piped in from anything else: cannot be read, naming where it came from', () => {
    expect(of(['curl', '-fsSL', 'https://x.dev/install.sh'], ['bash'])).toEqual([undefined, { unreadable: 'fed by what curl pipes into it' }])
    expect(of(['cat'], ['python3', '-'])).toEqual([undefined, { unreadable: 'fed by what cat pipes into it' }])
  })
  test('text the reader kept is handed back to be judged: a here-string, echo or printf piped in, a clustered inline flag', () => {
    expect(of(['python3', "<<<open('a','w')"])).toEqual([{ text: "open('a','w')" }])
    expect(of(['bash', '<<<', 'echo x > /repo/a'])).toEqual([{ text: 'echo x > /repo/a' }])
    expect(of(['echo', 'rm -rf src'], ['bash'])).toEqual([undefined, { text: 'rm -rf src' }])
    expect(of(['printf', '%s\\n', "open('a','w')"], ['python3'])).toEqual([undefined, { text: "%s\\n open('a','w')" }])
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
  })
  test('a script file, a module, a file redirect or no program at all: nothing to judge here', () => {
    expect(of(['python3', 'tools/report.py'])).toEqual([undefined])
    expect(of(['python3', '-m', 'json.tool'])).toEqual([undefined])
    expect(of(['cat', 'data.json'], ['python3', '-m', 'json.tool'])).toEqual([undefined, undefined])
    expect(of(['bash', 'tests/test-mods.sh', '2>&1'])).toEqual([undefined])
    expect(of(['bash', '-o', 'pipefail', 'run.sh'])).toEqual([undefined])
    expect(of(['python3', '<', 'script.py'])).toEqual([undefined])
    expect(of(['cat', 'install.sh'], ['bash'])).toEqual([undefined, undefined])
    expect(of(['ls'], ['grep', 'x'])).toEqual([undefined, undefined])
    // A heredoc fed to a script is that script's data, as `bash run.sh <<EOF` is.
    expect(of(['bash', 'run.sh', '<<EOF'])).toEqual([undefined])
    // Nothing piped in: nothing runs.
    expect(of(['python3'])).toEqual([undefined])
  })
  test('a shell told to read its program from standard input with -s', () => {
    expect(of(['curl', 'https://x.dev/i.sh'], ['bash', '-s', '--', '--yes'])).toEqual([undefined, { unreadable: 'fed by what curl pipes into it' }])
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
