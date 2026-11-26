import { describe, expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
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
    expect(pipeline(`bash <<'EOF'\npython3\nprint(1)\nEOF`)[0]).toEqual({ words: ['python3'], behind: ['bash'], language: 'python', program: { unreadable: 'fed the rest of the script the shell reads' } })
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
    expect(of(`printf '%s\\n' "open('a','w')" | python3`)).toEqual([undefined, { text: "open('a','w')\n", stdin: true }])
  })
  // Lessons review of #761: printf's arguments were joined with a space, its format and escapes
  // never applied, so `printf 'echo hi\nrm -rf src\n' | sh` was one command and every guard missed
  // the rm.
  test("printf's format and escapes, and echo's escapes, are applied, so each line piped to a shell is a command", () => {
    expect(words(`printf 'echo hi\\nrm -rf src\\n' | sh`)).toEqual([['printf', 'echo hi\\nrm -rf src\\n'], ['echo', 'hi'], ['rm', '-rf', 'src']])
    expect(words(`printf '%s\\n' 'echo a' 'git push' | sh`).slice(1)).toEqual([['echo', 'a'], ['git', 'push']])
    expect(words(`printf '%b' 'ls\\ngit push' | bash`).slice(1)).toEqual([['ls'], ['git', 'push']])
    expect(words(`echo -e 'ls\\ngit push' | sh`).slice(1)).toEqual([['ls'], ['git', 'push']])
    expect(of(`printf 'a%%b\\tc' | python3`)[1]).toEqual({ text: 'a%b\tc', stdin: true })
  })
  test('a printf format it cannot reproduce faithfully makes what it pipes in unreadable', () => {
    expect(of(`printf '%d\\n' 5 | sh`)).toEqual([undefined, { unreadable: 'fed by what printf pipes into it' }])
    expect(of(`printf '%-10s' x | python3`)).toEqual([undefined, { unreadable: 'fed by what printf pipes into it' }])
  })
  // #730: the shell's own standard input was not passed on to the commands its -c runs.
  test("a heredoc or here-string feeding a shell's -c feeds the commands it runs", () => {
    expect(pipeline(`bash -c 'python3' <<'EOF'\nopen('a','w')\nEOF`)).toEqual([
      { words: ['python3'], behind: ['bash'], language: 'python', program: { text: "open('a','w')", stdin: true }, verdict: { does: 'write files', seen: 'open in mode w' }, asWritten: true },
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

// #3621: zsh's --emulate takes the shell to emulate in the next word, and the reader took that word
// (`sh`) for a script file zsh runs. The text after -c was never read, and on 2026-11-24 a guard
// worded a hold about a zsh script file that did not exist. Each shell's options are that shell's
// own, measured and never read off a name. Measured 2026-11-26 on the personal MacBook, zsh 5.9,
// one run of each shape, by handing zsh the option and then two script files that each print
// their own name (the first prints when the option took nothing, the second when it took a word):
// - `--emulate` takes the next word whatever it is. It must stand before every other option:
//   after one (`zsh -f --emulate sh ...`) zsh refuses and runs nothing. `--emulate=sh` is refused.
// - `-o` and `+o` take a value, the rest of the word or the next word. No other letter takes one,
//   -O and +O included (they take a value in bash), and no other long option does.
// - emulating sh or ksh, zsh splits an unquoted value into words; emulating csh or zsh it does not.
describe("zsh's options that take a value are zsh's own (#3621)", () => {
  const TEXT = 'echo $(git rev-parse HEAD)'
  // What `sh -c` or `zsh -c` makes of a text, said as run by zsh: the reading the option must not change.
  const underZsh = (cmd: string, shell: string) => JSON.parse(JSON.stringify(pipeline(cmd)).split(`"behind":["${shell}"]`).join('"behind":["zsh"]'))
  test('--emulate takes the shell to emulate as its next word, so the text after -c is the commands', () => {
    expect(commands(`zsh --emulate sh -c 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`zsh -f --emulate sh -c 'make test'`)).toEqual([['make', 'test']])
    expect(scripts(`zsh --emulate sh -c 'make test'`)).toEqual([undefined])
    expect(scripts(`zsh -f --emulate sh -c 'make test'`)).toEqual([undefined])
  })
  test('the controls: the same command without the option, and with an option that takes nothing', () => {
    expect(commands(`zsh -c 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`zsh -f -c 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`zsh --no-rcs -c 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`zsh -f --no-rcs -c '${TEXT}'`)).toEqual([['git', 'rev-parse', 'HEAD'], ['echo', '$(git rev-parse HEAD)']])
  })
  test('a substitution in that text is read as the command it runs, and no script file is named', () => {
    for (const before of ['--emulate sh', '-f --emulate sh']) {
      expect(commands(`zsh ${before} -c '${TEXT}'`)).toEqual([['git', 'rev-parse', 'HEAD'], ['echo', '$(git rev-parse HEAD)']])
      expect(scripts(`zsh ${before} -c '${TEXT}'`)).toEqual([undefined, undefined])
      // Read as sh reads it, since zsh emulating sh splits words as sh does.
      expect(pipeline(`zsh ${before} -c '${TEXT}'`)).toEqual(underZsh(`sh -c '${TEXT}'`, 'sh'))
    }
    // Without the option the text is read as zsh reads it, as it was.
    expect(scripts(`zsh -c '${TEXT}'`)).toEqual([undefined, undefined])
    expect(scripts(`zsh -f -c '${TEXT}'`)).toEqual([undefined, undefined])
  })
  test('a script file after the option and its value is the script, the words after it its arguments', () => {
    expect(scripts('zsh --emulate sh run.sh a')).toEqual([{ files: ['run.sh'] }])
    expect(scripts('zsh --emulate ksh -x run.sh -c a')).toEqual([{ files: ['run.sh'] }])
    // The controls.
    expect(scripts('zsh run.sh a')).toEqual([{ files: ['run.sh'] }])
    expect(scripts('zsh -x run.sh -c a')).toEqual([{ files: ['run.sh'] }])
  })
  test('the text is read as the emulated shell splits words: sh and ksh split, csh and zsh do not', () => {
    const splits = (cmd: string) => pipeline(cmd).map(c => c.splits)
    expect(splits(`sh -c 'cp $A b'`)).toEqual([[[], [0], []]])
    expect(splits(`zsh --emulate sh -c 'cp $A b'`)).toEqual([[[], [0], []]])
    expect(splits(`zsh --emulate ksh -c 'cp $A b'`)).toEqual([[[], [0], []]])
    expect(splits(`zsh --emulate csh -c 'cp $A b'`)).toEqual([undefined])
    expect(splits(`zsh --emulate zsh -c 'cp $A b'`)).toEqual([undefined])
    expect(splits(`zsh -c 'cp $A b'`)).toEqual([undefined])
    // A word no run here measured is read the cautious way, as splitting.
    expect(splits(`zsh --emulate other -c 'cp $A b'`)).toEqual([[[], [0], []]])
  })
  test('fed its script on standard input after the option, zsh reads that script, split as the emulated shell splits', () => {
    const fed = (shell: string) => pipeline(`${shell} <<'EOF'\ncp $A b\nEOF`).map(c => [c.words, c.script, c.splits])
    expect(fed('zsh --emulate sh')).toEqual([[['cp', '$A', 'b'], undefined, [[], [0], []]]])
    // The controls: sh itself, and zsh without the option, which splits nothing.
    expect(fed('sh')).toEqual([[['cp', '$A', 'b'], undefined, [[], [0], []]]])
    expect(fed('zsh')).toEqual([[['cp', '$A', 'b'], undefined, undefined]])
    expect(fed('zsh -f')).toEqual([[['cp', '$A', 'b'], undefined, undefined]])
  })
  test('-O takes nothing in zsh, so the word after it is the script or the -c that gives the text', () => {
    expect(commands(`zsh -O -c 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`zsh +O -c 'make test'`)).toEqual([['make', 'test']])
    expect(scripts('zsh -O run.sh')).toEqual([{ files: ['run.sh'] }])
    expect(scripts('zsh -xO run.sh a')).toEqual([{ files: ['run.sh'] }])
  })
  test('the controls: -o still takes its value in zsh, and -O still takes one in bash', () => {
    expect(commands(`zsh -o shwordsplit -c 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`zsh -oshwordsplit -c 'make test'`)).toEqual([['make', 'test']])
    expect(scripts('zsh -o shwordsplit run.sh')).toEqual([{ files: ['run.sh'] }])
    expect(scripts('zsh +o shwordsplit run.sh')).toEqual([{ files: ['run.sh'] }])
    expect(commands(`bash -O extglob -c 'make test'`)).toEqual([['make', 'test']])
    expect(scripts('bash -O extglob run.sh')).toEqual([{ files: ['run.sh'] }])
    expect(scripts('bash +O extglob run.sh')).toEqual([{ files: ['run.sh'] }])
  })
  test('--emulate is no option of the other shells, which refuse it and run nothing: their reading is as it was', () => {
    // Measured 2026-11-26: bash 3.2 and ksh93 end with a usage error, dash with "Illegal option".
    for (const shell of ['bash', 'sh', 'dash', 'ksh']) expect(scripts(`${shell} --emulate sh -c 'make test'`)).toEqual([{ files: ['sh'] }])
  })
})

// claude-config#3442: `bash -n x.sh` checks the script's syntax and runs none of it, and was read as
// a run of it, so every reader of a script a command runs judged what the script's text does.
// Measured 2026-11-26 on the personal MacBook (bash 3.2.57, zsh 5.9, macOS sh, dash and ksh93), one
// run of each form in an empty folder with a script that only makes a file, the folder listed
// afterwards: all five make no file for every form in the first test, and the file for `+n`,
// `-n +n` and `-n +o noexec`; zsh and ksh make it for `-n -o exec` and `-n --exec` too.
describe('a shell told only to check its script runs none of it (#3442)', () => {
  const ALL = ['bash', 'sh', 'zsh', 'dash', 'ksh']
  test('-n or -o noexec before a script file names no script the command runs', () => {
    for (const shell of ALL)
      for (const options of ['-n', '-vn', '-n -x', '-n -l', '-n --', '-o noexec', '-n -o noexec']) expect([shell, options, scripts(`${shell} ${options} x.sh`)]).toEqual([shell, options, [undefined]])
    expect(scripts('bash -n x.sh a b')).toEqual([undefined])
    expect(scripts('/bin/bash -n ./tools/x.sh && bash ./tools/x.sh')).toEqual([undefined, { files: ['./tools/x.sh'] }])
    // The command is still given, with the words it was written with.
    expect(words('bash -n x.sh')).toEqual([['bash', '-n', 'x.sh']])
  })
  test('a check taken back, or one a shell may not keep, is read as a run', () => {
    // `-i` is read as a run: bash says an interactive shell ignores -n. The shells on this Mac ran
    // nothing for it with nothing to read on standard input, and no other build was measured.
    for (const shell of ALL)
      for (const options of ['+n', '-n +n', '-n +o noexec', '-o noexec +n', '-n -o exec', '-n +o exec', '-n -o NO_EXEC', '-n --exec', '-n --no-exec', '-n -i', '-i -n', '-in'])
        expect([shell, options, scripts(`${shell} ${options} x.sh`)]).toEqual([shell, options, [{ files: ['x.sh'] }]])
    // An -n after the script file is the script's own argument.
    expect(scripts('bash x.sh -n')).toEqual([{ files: ['x.sh'] }])
  })
  test('the long spelling --interactive keeps the check, as the shells that take it do', () => {
    // Raised at a push: `zsh -n --interactive x.sh` is read as a check that runs nothing while `-i`
    // is read as a run, so is the long spelling read wrongly? Measured 2026-11-26 on the personal
    // MacBook (zsh 5.9, ksh 93u+ 2012-08-01, bash 3.2.57, macOS sh, dash), two runs of each form with
    // a script and start up files that each only make a file, a clean environment, no terminal and
    // standard input from /dev/null. zsh and ksh, the two that take the option, make no file for any
    // form below, the start up files' included; zsh's manual says -n given at startup holds in an
    // interactive shell. bash, sh and dash refuse `--interactive` and run nothing. So the reading is
    // right for every shell measured, and this pins it. (Each of the five also made no file for
    // `-n -i`, which stays read as a run for the builds not measured.)
    for (const shell of ALL) expect([shell, scripts(`${shell} -n --interactive x.sh`)]).toEqual([shell, [undefined]])
    for (const shell of ['zsh', 'bash', 'ksh']) expect([shell, scripts(`${shell} --interactive -n x.sh`)]).toEqual([shell, [undefined]])
    for (const options of ['-n --interactive --', '-o noexec --interactive', '-n -f --interactive'])
      expect([options, scripts(`zsh ${options} x.sh`)]).toEqual([options, [undefined]])
    // The control: with the check taken back zsh and ksh made the script's file and the interactive
    // start up file's, so the option is taken and those forms are a run.
    for (const command of ['zsh -n --interactive +n x.sh', 'zsh -n --interactive --exec x.sh', 'ksh -n --interactive +n x.sh'])
      expect([command, scripts(command)]).toEqual([command, [{ files: ['x.sh'] }]])
  })
  test('text given inline or on standard input is read as it was', () => {
    // Every shell measured runs none of it. Reading it as run judges more than is there and misses
    // nothing, and the issue names only the script file.
    expect(commands(`bash -nc 'make test'`)).toEqual([['make', 'test']])
    expect(commands(`bash -n -c 'make test'`)).toEqual([['make', 'test']])
    expect(commands("bash -n <<'EOF'\nmake test\nEOF")).toEqual([['make', 'test']])
    expect(scripts('bash -n < x.sh')).toEqual([{ files: ['x.sh'], stdin: true }])
    expect(scripts('cat x.sh | bash -n')).toEqual([undefined, { files: ['x.sh'], stdin: true }])
  })
})
