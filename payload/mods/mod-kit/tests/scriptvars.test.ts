import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { freshTemp, leadingVariable, madeTemp, ownFolderPath, ownFolderVar, tempWord, withoutOwnFolder } from '../hooks/scriptvars.ts'

// The one reader of what a shell script's own variables hold (#3022): a temporary file or folder it
// made with mktemp, and its own folder. The design round guard kept it, and the area check, which
// could place no write into such a folder, held every checker copying into one.

// #2171, Dan, 2026-11-04 (picker answer: trust bare mktemp the way git rev-parse is trusted): a write
// to a variable alone whose every value is `$(mktemp)` or `$(mktemp -d)` names a new file outside every
// screen path. Nothing else is trusted, and nothing at all where the command could make mktemp print
// another name or give the variable another value.
test('#2171: only a variable every assignment gives bare mktemp or mktemp -d names a fresh file', () => {
  for (const [word, values, command] of [
    ['$T', ['$(mktemp)'], 'T=$(mktemp); git show HEAD:app/page.tsx > "$T"; diff "$T" app/page.tsx'],
    ['${T}', ['$(mktemp)'], 'T=$(mktemp); wc -l $(ls app/page.tsx) > ${T}'],
    ['$D', ['$(mktemp -d)'], 'D=$(mktemp -d); cp app/page.tsx "$D"'],
    ['$T', ['$(mktemp)'], 'T="$(mktemp)"; git show HEAD:app/page.tsx > "$T"'],
    ['$T', ['$(mktemp)', '$(mktemp -d)'], 'T=$(mktemp); T=$(mktemp -d); cat app/page.tsx > "$T"'],
    ['$T', ['$(mktemp)'], 'export T=$(mktemp); cat app/page.tsx > "$T"'],
  ] as const)
    expect([command, freshTemp(word, [...values], command)]).toEqual([command, true])
  for (const [word, values, command] of [
    // Any other value, or a flag or template that chooses where the file goes.
    ['$T', ['$(head -1 list)'], 'ls app/*.tsx > list; T=$(head -1 list); echo x > "$T"'],
    ['$OUT', ['$(ls app/*.tsx|head -1)'], 'OUT=$(ls app/*.tsx|head -1); echo x > "$OUT"'],
    ['$T', ['$(mktemp -t x)'], 'T=$(mktemp -t x); cat app/page.tsx > "$T"'],
    ['$T', ['$(mktemp app/x.XXXX)'], 'T=$(mktemp app/x.XXXX); cat app/page.tsx > "$T"'],
    ['$T', ['$(mktemp -p app)'], 'T=$(mktemp -p app); cat app/page.tsx > "$T"'],
    ['$T', ['$(mktemp)', '$(head -1 list)'], 'T=$(mktemp); T=$(head -1 list); echo x > "$T"'],
    ['$T', ['`mktemp`'], 'T=`mktemp`; cat app/page.tsx > "$T"'],
    ['$T', ['$(mktemp; echo app/page.tsx)'], 'T=$(mktemp; echo app/page.tsx); echo x > "$T"'],
    // The command can make mktemp print a name in a screen folder.
    ['$T', ['$(mktemp)'], 'TMPDIR=app T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'export TMPDIR=/w/slate/app; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'PATH=./bin:$PATH; T=$(mktemp); cat app/page.tsx > "$T"'],
    ['$T', ['$(mktemp)'], 'mktemp(){ echo app/page.tsx; }; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'function mktemp { echo app/page.tsx; }; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], "alias mktemp='echo app/page.tsx'; T=$(mktemp); echo x > \"$T\""],
    ['$T', ['$(mktemp)'], 'hash -p ./bin/fake mktemp; T=$(mktemp); echo x > "$T"'],
    // zsh takes a quoted or escaped function name, and a function or a name set through its table.
    ['$T', ['$(mktemp)'], '"mktemp"(){ echo app/page.tsx; }; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'm\\ktemp(){ echo app/page.tsx; }; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], "functions[mktemp]='echo app/page.tsx'; T=$(mktemp); echo x > \"$T\""],
    ['$T', ['$(mktemp)'], 'path=(./bin $path); T=$(mktemp); echo x > "$T"'],
    // zsh's lowercase path array is PATH, so every way of setting it is held too.
    ['$T', ['$(mktemp)'], 'path+=(./bin); T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'path[1]=./bin; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'typeset path; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'typeset -a path=(./bin); T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'read -A path < list; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'set -A path ./bin; T=$(mktemp); echo x > "$T"'],
    // A quoted, escaped or run time name for TMPDIR or PATH.
    ['$T', ['$(mktemp)'], 'export TMP"DIR"=app; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], "export $'TMP\\x44IR'=app; T=$(mktemp); echo x > \"$T\""],
    ['$T', ['$(mktemp)'], 'V=TMP; export ${V}DIR=app; T=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'printf -v "$V" app; T=$(mktemp); echo x > "$T"'],
    // An assignment of the variable the reader did not give, a prefix one dropped before a command.
    ['$T', ['$(mktemp)'], 'T=$(mktemp); T=app/page.tsx : ; echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'T=$(mktemp); T+=.tsx; echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'T=$(mktemp); T+=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'T=$(mktemp); T[0]=$(mktemp); echo x > "$T"'],
    ['$T', ['$(mktemp)'], 'T=$(mktemp); T[0]=app/page.tsx; echo x > "$T"'],
    // A word that is more than the variable alone, or no values.
    ['$T/a', ['$(mktemp)'], 'T=$(mktemp); cat app/page.tsx > "$T/a"'],
    ['$T', [], 'cat app/page.tsx > "$T"'],
  ] as const)
    expect([command, freshTemp(word, [...values], command)]).toEqual([command, false])
})

test('#2991: a variable holds a temporary folder the script made only where every assignment is mktemp -d or a name inside one', () => {
  const T = 'T="$(mktemp -d)"\n'
  for (const [name, script] of [
    ['T', T],
    ['T', 'T=$(mktemp -d)\n'],
    ['CH', `${T}CH="$T/chain"\n`],
    ['CH', `${T}CH="\${T}/a/b"\nCH="$T/c"\n`],
    ['X', `${T}CH="$T/chain"\nX="$CH/app"\n`],
  ] as const)
    expect([script, madeTemp(name, script)]).toEqual([script, true])
  for (const [name, script] of [
    ['CH', 'CH="$(pwd)"\n'],
    ['CH', 'CH=.\n'],
    ['CH', `${T}CH="$T/chain"\nCH=/w/slate\n`],
    ['CH', `${T}CH="$T/../.."\n`],
    ['CH', `${T}CH="$T/$U"\n`],
    ['CH', `${T}CH="$T/chain"\nCH+=/x\n`],
    ['CH', `${T}CH="$T/chain"\nread CH\n`],
    ['CH', `${T}for CH in /w/slate; do :; done\n`],
    ['CH', `${T}CH="$T/chain"\n: "\${CH:=/w/slate}"\n`],
    ['CH', 'CH=\'$(mktemp -d)\'\n'],
    ['T', 'T="$(mktemp -d -t x)"\n'],
    ['T', `TMPDIR=/w/slate ${T}`],
    ['T', `mktemp() { echo /w/slate; }\n${T}`],
    ['T', `PATH=/w/bin:$PATH\n${T}`],
    ['T', 'T="$T"\n'],
    ['CH', ''],
  ] as const)
    expect([script, madeTemp(name, script)]).toEqual([script, false])
})

test('#2924: ownFolderVar reads the one usual idiom for a script\'s own folder, and nothing that may name another', () => {
  const idiom = 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
  expect(ownFolderVar('HERE', `set -u\n${idiom}\nsource "$HERE/x.sh"\n`)).toBe(true)
  expect(ownFolderVar('HERE', `  ${idiom.replace('${BASH_SOURCE[0]}', '$BASH_SOURCE').replace('&& pwd', '>/dev/null && pwd -P')}\n`)).toBe(true)
  for (const text of [
    `cd /tmp\n${idiom}\n`,
    `${idiom}\nHERE=/w/slate/app\n`,
    `${idiom}\nHERE+=/app\n`,
    `${idiom}\nread HERE\n`,
    `${idiom}\nfor HERE in a b; do :; done\n`,
    `${idiom}\n: "\${HERE:=/w}"\n`,
    idiom.replace('${BASH_SOURCE[0]}', '$0'),
    `x=1; ${idiom}\n`,
    'HERE="$(pwd)"\n',
  ])
    expect({ text, own: ownFolderVar('HERE', text) }).toEqual({ text, own: false })
  // A temporary file and an empty value count for a write's own variable, never for a joined folder.
  expect(madeTemp('f', 'f=""\nf="$(mktemp)"\nf=$(mktemp)\n', new Set(), true)).toBe(true)
  expect(madeTemp('f', 'f="$(mktemp)"\n')).toBe(false)
  expect(madeTemp('f', 'f=""\n', new Set(), true)).toBe(false)
  expect(madeTemp('f', 'f="$(mktemp)"\nf="$1"\n', new Set(), true)).toBe(false)
})

// #2960: a name starts from a variable only where the rest is a plain name inside it.
test('#3022: leadingVariable names the variable a path starts from, and none where the rest may climb out or holds another value', () => {
  expect(leadingVariable('$D')).toBe('$D')
  expect(leadingVariable('$D/sub')).toBe('$D')
  expect(leadingVariable('${D}/a/page.tsx')).toBe('$D')
  for (const word of ['$D/$x', '$D/../x', '$D/a/..', 'a/$D', '$D/`x`', '/tmp/x', '$(mktemp -d)/x', '$1/x', 'D/x'])
    expect([word, leadingVariable(word)]).toEqual([word, undefined])
})

// #3022: the two shapes a write into a temporary place takes, as the design round guard's closed
// script reading asked them (#2924), now asked by the area check of a script handed a folder too.
test('#3022: tempWord says a write lands in a temporary file or folder the script made, and nothing else does', () => {
  const made = 'T="$(mktemp -d)"\nF="$(mktemp)"\n'
  for (const word of ['$T/copy', '${T}/a/b.ts', '$T', '$F', '${F}']) expect([word, tempWord(word, made)]).toEqual([word, true])
  for (const [word, script] of [
    // A file is no folder to write under, and a name holding another value or a climb may land anywhere.
    ['$F/x', made],
    ['$T/$n', made],
    ['$T/$(basename "$d")', made],
    ['$T/../x', made],
    // What the script is handed, a variable set nowhere, and a plain path are not its own making.
    ['$1/x', made],
    ['$U/x', made],
    ['/w/slate/x', made],
    ['copy', made],
    // The variable also given what the script is handed, or a mktemp that chooses its own place.
    ['$T/copy', `${made}T="$1"\n`],
    ['$T/copy', 'T="$(mktemp -d "$1/x.XXXXXX")"\n'],
    ['$T/copy', 'T="$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")"\n'],
    ['$T/copy', `TMPDIR="$1" ${made}`],
  ] as const)
    expect([word, script, tempWord(word, script)]).toEqual([word, script, false])
})

test("#3022: ownFolderPath places a name under the variable holding the script's own folder beside the script", () => {
  const idiom = 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
  expect(ownFolderPath('$HERE/lib/x.sh', idiom, '/w/tools/check.sh')).toBe('/w/tools/lib/x.sh')
  expect(ownFolderPath('${HERE}/x.sh', idiom, '/check.sh')).toBe('/x.sh')
  expect(ownFolderPath('$HERE/../lib/x.sh', idiom, '/w/tools/check.sh')).toBe('/w/tools/../lib/x.sh')
  for (const [word, text] of [
    // The folder alone names no file; a name holding another value or a pattern names no one file.
    ['$HERE', idiom],
    ['$HERE/$x.sh', idiom],
    ['$HERE/*.sh', idiom],
    ['$HERE/`x`.sh', idiom],
    // A variable that is not the script's own folder, or may also hold another.
    ['$OTHER/x.sh', idiom],
    ['$HERE/x.sh', `${idiom}HERE="$1"\n`],
    ['$HERE/x.sh', `cd "$1"\n${idiom}`],
    ['$HERE/x.sh', 'HERE="$(pwd)"\n'],
    ['x.sh', idiom],
  ] as const)
    expect([word, text, ownFolderPath(word, text, '/w/tools/check.sh')]).toEqual([word, text, undefined])
})

// The idiom's cd runs inside a command substitution, a shell of its own, so the script's folder
// never moves. A reader asking whether a script moves folder reads the text with each whole idiom
// taken out; a cd that is not the whole idiom stays, and is read as the move it may be.
test('#3022: withoutOwnFolder takes out each whole own folder idiom and leaves every other cd', () => {
  const idiom = '$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)'
  expect(withoutOwnFolder(`HERE="${idiom}"\nlib="${idiom}/../lib/x.sh"\n`)).not.toContain('cd ')
  expect(withoutOwnFolder('HERE="$(cd -P "$(dirname "$BASH_SOURCE")" >/dev/null 2>&1 && pwd -P)"\n')).not.toContain('cd ')
  expect(withoutOwnFolder(`HERE="${idiom}"\n`)).toContain('HERE="')
  for (const text of [
    'cd "$(dirname "${BASH_SOURCE[0]}")"\n',
    'x="$(cd "$(dirname "${BASH_SOURCE[0]}")" && echo x > "$1/gen.ts")"\n',
    'x="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; echo x > "$1/gen.ts")"\n',
    'x="$(cd "$(dirname "$0")" && pwd)"\n',
    'x="$(cd "$1" && pwd)"\n',
    'x="$(cd lib && pwd)"\n',
  ])
    expect([text, withoutOwnFolder(text)]).toEqual([text, text])
})
