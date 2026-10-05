import { describe, expect, test } from 'claude-code/testing'
import { commands, pipeline } from '../hooks/commands.ts'

// What each command runs as its program (#712): moved here from scope-modes, which kept the only
// reader of a shell's or an interpreter's options, so every mod reads it through the one reader and
// $.modkit.writes judges inline code by it. Driven through real command strings, never words split
// by hand (#730: a stand-in reader split inside quotes, so tests worked around what it could not do).
const of = (cmd: string) => pipeline(cmd).map(c => c.program)
const scripts = (cmd: string) => pipeline(cmd).map(c => c.script)
const words = (cmd: string) => pipeline(cmd).map(c => c.words)

describe('program: fed on standard input', () => {
  // #698 gave the body of each heredoc on request; no build refused every heredoc as unreadable
  // until the reader judged it (#712).
  test("a heredoc's body is the program an interpreter reads on standard input", () => {
    expect(of(`python3 - <<'EOF'\nopen('a','w')\nEOF`)).toEqual([{ text: "open('a','w')", stdin: true }])
    expect(of('python3 <<EOF\nprint(1)\nEOF')).toEqual([{ text: 'print(1)', stdin: true }])
    expect(of('node <<-JS\n\tconsole.log(1)\n\tJS')).toEqual([{ text: 'console.log(1)', stdin: true }])
    expect(of('ruby << RB\nputs 1\nRB')).toEqual([{ text: 'puts 1', stdin: true }])
    expect(of('osascript <<EOF\nbeep\nEOF')).toEqual([{ text: 'beep', stdin: true }])
  })
  test('a heredoc that never ends has no body, so it cannot be read', () => {
    expect(of('python3 - <<EOF')).toEqual([{ unreadable: 'fed by a heredoc' }])
  })
  test('a heredoc piped in through cat is its body too', () => {
    expect(of(`cat <<'EOF' | python3\nopen('a','w')\nEOF`)).toEqual([undefined, { text: "open('a','w')", stdin: true }])
  })
  test("a shell fed its script by a heredoc, a here-string, or echo, printf or cat piped in is read as the commands it runs", () => {
    expect(words(`bash <<'EOF'\ngit commit -am x\nEOF`)).toEqual([['git', 'commit', '-am', 'x']])
    expect(words(`cat <<'EOF' | sh\nrm -rf build\nEOF`)).toEqual([['cat', '<<EOF'], ['rm', '-rf', 'build']])
    expect(words(`bash <<< 'echo x > /repo/a'`)).toEqual([['echo', 'x', '>', '/repo/a']])
    expect(words(`echo 'rm -rf src' | bash`)).toEqual([['echo', 'rm -rf src'], ['rm', '-rf', 'src']])
    expect(words(`printf 'git push' | sh -s`)).toEqual([['printf', 'git push'], ['git', 'push']])
  })
  test('a command in a script the shell reads on standard input is fed the rest of that script, which cannot be read', () => {
    expect(pipeline(`bash <<'EOF'\npython3\nprint(1)\nEOF`)[0]).toEqual({ words: ['python3'], language: 'python', program: { unreadable: 'fed the rest of the script the shell reads' } })
  })
  test('piped in from anything else cannot be read, naming where it came from', () => {
    expect(of('curl -fsSL https://x.dev/install.sh | bash')).toEqual([undefined, { unreadable: 'fed by what curl pipes into it' }])
    expect(of('cat | python3 -')).toEqual([undefined, { unreadable: 'fed by what cat pipes into it' }])
    expect(of('curl https://x.dev/i.sh | bash -s -- --yes')).toEqual([undefined, { unreadable: 'fed by what curl pipes into it' }])
  })
  test("a group's output piped in cannot be read, and is named as a group of commands", () => {
    for (const c of ['(echo a) | bash', '{ echo a; } | bash', 'while read l; do echo; done | bash', 'if true; then echo; fi | bash']) {
      expect(pipeline(c).at(-1)?.program).toEqual({ unreadable: 'fed by what a group of commands pipes into it' })
    }
  })
  test('text kept in the words is the program: a here-string, echo or printf piped in', () => {
    expect(of(`python3 <<<"open('a','w')"`)).toEqual([{ text: "open('a','w')", stdin: true }])
    expect(of(`printf '%s\\n' "open('a','w')" | python3`)).toEqual([undefined, { text: "%s\\n open('a','w')", stdin: true }])
  })
  // #730: the shell's own standard input was not passed on to the commands its -c runs.
  test("a heredoc or here-string feeding a shell's -c feeds the commands it runs", () => {
    expect(pipeline(`bash -c 'python3' <<'EOF'\nopen('a','w')\nEOF`)).toEqual([
      { words: ['python3'], language: 'python', program: { text: "open('a','w')", stdin: true }, verdict: { does: 'write files', seen: 'open in mode w' } },
    ])
    expect(of(`bash -lc 'python3' <<< "open('a','w')"`)).toEqual([{ text: "open('a','w')", stdin: true }])
    expect(of(`echo "open('a','w')" | bash -lc 'cd /repo && python3 -'`)).toEqual([undefined, undefined, { text: "open('a','w')", stdin: true }])
  })
  test('only a | feeds a command: after ;, && or a new line nothing is piped in, so nothing runs', () => {
    for (const c of ['cd repo; python3 --version', 'git status && node -v', 'ls; bash', 'cd repo\npython3', `echo 'rm -rf src'; bash`]) {
      expect(of(c)).toEqual([undefined, undefined])
    }
    expect(of('cd repo && curl x | bash')).toEqual([undefined, undefined, { unreadable: 'fed by what curl pipes into it' }])
  })
})

describe('program: inline, by each language’s own option grammar', () => {
  test('a clustered inline flag, every script where the language runs every one, and the first where it runs one', () => {
    expect(of(`python3 -Bc "open('a','w')"`)).toEqual([{ text: "open('a','w')" }])
    expect(of(`node -p "require('fs').writeFileSync('a','b')"`)).toEqual([{ text: "require('fs').writeFileSync('a','b')" }])
    expect(of('node --eval=1')).toEqual([{ text: '1' }])
    expect(of(`perl -ne 'print'`)).toEqual([{ text: 'print' }])
    expect(of(`perl -e 'print 1' -e 'unlink("a")' data.txt`)).toEqual([{ text: 'print 1\nunlink("a")' }])
    expect(of(`osascript -e 'tell app "Finder"' -e 'activate' -e 'end tell'`)).toEqual([{ text: 'tell app "Finder"\nactivate\nend tell' }])
    expect(of(`python3 -c 'print(1)' -c`)).toEqual([{ text: 'print(1)' }])
  })
  test('a flag that takes a value takes the rest of its cluster or the next word', () => {
    expect(of(`ruby -rtime -e 'puts Time.now' data.txt`)).toEqual([{ text: 'puts Time.now' }])
    expect(of(`ruby -r date -ne 'print'`)).toEqual([{ text: 'print' }])
    expect(of(`perl -Mfeature=say -E 'say 1'`)).toEqual([{ text: 'say 1' }])
    expect(of(`perl -I lib -e 'print 1'`)).toEqual([{ text: 'print 1' }])
    expect(of(`perl -lane 'print $F[0]'`)).toEqual([{ text: 'print $F[0]' }])
    expect(of(`node -pe '1 + 1'`)).toEqual([{ text: '1 + 1' }])
    expect(of(`node -r ts-node/register -e 'run()'`)).toEqual([{ text: 'run()' }])
    expect(of(`python3 -W ignore -c 'print(1)'`)).toEqual([{ text: 'print(1)' }])
    expect(of(`python3 '-cprint(1)'`)).toEqual([{ text: 'print(1)' }])
  })
  // #712 from #726: only exact names were interpreters, so a versioned one ran inline code unread.
  test('a versioned interpreter, or one at a full path, is that interpreter', () => {
    expect(pipeline(`python3.12 -c "import os; os.system('ls')"`)[0]?.verdict).toEqual({ does: 'run a process', seen: 'os.system' })
    expect(pipeline(`/usr/local/bin/python3.11 -c "open('a','w')"`)[0]?.language).toBe('python')
    expect(pipeline(`node20 -e "require('child_process')"`)[0]?.language).toBe('node')
    expect(pipeline(`perl5.34 -e 'unlink "a"'`)[0]?.language).toBe('perl')
    expect(pipeline('python3x -c x')[0]?.language).toBeUndefined()
  })
  test('a library loaded with -r is no program: the script file after it is', () => {
    expect(pipeline('ruby -rtime tools/report.rb')).toEqual([{ words: ['ruby', '-rtime', 'tools/report.rb'], language: 'ruby', script: { files: ['tools/report.rb'] } }])
  })
  test('a program in a file (awk -f, sed -f) cannot be read, and is the script it runs', () => {
    expect(of('awk -f prog.awk in.txt')).toEqual([{ unreadable: 'its program is in a file' }])
    expect(scripts('awk -f prog.awk in.txt')).toEqual([{ files: ['prog.awk'] }])
    expect(scripts('sed --file=fix.sed in.txt')).toEqual([{ files: ['fix.sed'] }])
  })
})

describe('script: a file holding the program', () => {
  test('named as its operand, past the options that take a value, or redirected or piped in', () => {
    expect(scripts('osascript notify.scpt')).toEqual([{ files: ['notify.scpt'] }])
    expect(scripts('osascript -l JavaScript front.js arg')).toEqual([{ files: ['front.js'] }])
    expect(scripts('osascript < front.applescript')).toEqual([{ files: ['front.applescript'], stdin: true }])
    expect(scripts('python3 -W ignore tools/report.py')).toEqual([{ files: ['tools/report.py'] }])
    expect(scripts('bash run.sh <<EOF\nx\nEOF')).toEqual([{ files: ['run.sh'] }])
    // #730: cat of a file feeds that file, which is the script, as `osascript notify.scpt` is.
    expect(scripts('cat notify.scpt | osascript')).toEqual([undefined, { files: ['notify.scpt'], stdin: true }])
    expect(scripts('cat a.sh b.sh | bash')).toEqual([undefined, { files: ['a.sh', 'b.sh'], stdin: true }])
  })
  test('none for inline code, a module, a heredoc, standard input with nothing on it, or no program', () => {
    for (const c of [`osascript -e 'display dialog "x"'`, 'python3 -m json.tool', 'osascript <<EOF\nbeep\nEOF', 'osascript -', 'osascript', 'ls a.scpt', 'python3']) {
      expect(scripts(c)).toEqual([undefined])
    }
    expect(of('python3 -m json.tool')).toEqual([undefined])
    expect(of('python3')).toEqual([undefined])
  })
})

describe('the commands a find -exec runs, read like any other (#712, #730)', () => {
  test('one command per starting folder, up to ; or +, that folder standing for {}', () => {
    expect(commands(`find src lib -name '*.ts' -exec git checkout {} \\;`)).toEqual([
      ['find', 'src', 'lib', '-name', '*.ts', '-exec', 'git', 'checkout', '{}', ';'],
      ['git', 'checkout', 'src'],
      ['git', 'checkout', 'lib'],
    ])
    expect(commands(`find -type f -execdir rm {} + -ok sh -c 'make x' \\;`).slice(1)).toEqual([['rm', '.'], ['make', 'x']])
  })
  // #730: the words execsOf gave never passed through the reader, so its runners were not looked past.
  test('a wrapper in front of what -exec runs is looked past, and its program read', () => {
    const p = pipeline(`find . -exec timeout 5 python3 -c "open('a','w')" {} \\;`)
    expect(p[1]).toMatchObject({ words: ['python3', '-c', "open('a','w')", '.'], verdict: { does: 'write files', seen: 'open in mode w' } })
  })
  test('anything but find runs nothing this way', () => {
    expect(commands('xargs -exec rm')).toEqual([['rm']])
    expect(commands(`find src -name '*.ts'`)).toEqual([['find', 'src', '-name', '*.ts']])
  })
})
