import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { commandWrites, pipelineIn } from './mod-kit/hooks/writes.ts'
import { CHECK_MODS, NAMED, SHARED_PARTS, namedReaders, unchangedArgs, type NamedFacts } from '../hooks/named.ts'
import { APP, HOME, KIT, NAMED_TEXTS, SCAN_TEXTS, bash, refusal, world } from './world.ts'

// #3022, Dan's decision (2026-11-16, "Name check-mods.sh in the guard"): `bash tools/check-mods.sh
// <mods folder>`, run from a checkout of this repository, is known by name to read the folder it is
// handed and write no file git tracks there. Its own text cannot be read to say so (values named by
// variables, the claude command from the environment, libraries that keep logs and install the
// compiler), so it was held on every run. Only that script, at that path, in that repository, handed
// one folder, in a command that gives it no setting and runs the script once, with nothing but a
// change of folder before it and readers its output is piped into after it,
// with the text its checkout left the default branch with; everything else is judged as before. tests/test-area-check-check-mods-read-only.sh runs the real script and the real reader.
// Since #3093 an equals sign holds the run only where it may set a value for the script: anywhere
// but in a reader its output is piped into, or a comment.

const REPO = 'danwright32/claude-config'
// A script the reader cannot place the writes of, as the real one's are not: a copy named by a
// command's output, and an inline perl program.
const UNREADABLE = '#!/bin/bash\nscratch="$(mktemp -d)"\nfor d in "$1"/*/; do\n  checked="$scratch/$(basename "$d")"\n  cp -RH "$d" "$checked"\n  perl -MFile::Copy -e \'copy($ARGV[0], $ARGV[1])\' "$d/x" "$checked/x"\ndone\n'
const HELD = 'The area check held this Bash command, which writes src/big.ts.'
const named = (w: ReturnType<typeof world>) => w.records().filter(x => x.kind === 'named-reader')

const ours = ($: unknown, on: Parameters<typeof world>[1]) => {
  const w = world($, on)
  w.ctl.github = REPO
  w.files[`${APP}/tools/check-mods.sh`] = UNREADABLE
  return w
}

test('the list of texts the world answers git about is the one the code hands git (#3022)', async () => {
  expect(unchangedArgs(CHECK_MODS, 'main').join(' ')).toBe(`diff --quiet --merge-base origin/main -- ${NAMED_TEXTS}`)
  expect([CHECK_MODS.repo, CHECK_MODS.script]).toEqual([REPO, 'tools/check-mods.sh'])
})

// #3082, Dan's decision (2026-11-16, "Name it in the guard"): `bash tools/check-mod-shared-parts.sh
// <mods folder>` is the second script known by name, under the same conditions as the first. It
// runs a python program named by a variable, which writes comment free copies into a folder the
// script makes under the temporary folder, and no reader can place a write whose path python builds
// from its arguments. tests/test-area-check-shared-parts-read-only.sh runs the real script.
const SCAN = 'tools/check-mod-shared-parts.sh'
// A script held for what the real one is held for: a python program named by a variable, handed the
// folder and a folder of its own.
const SCAN_UNREADABLE = '#!/bin/bash\ndir="${1%/}"\nTS_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ts_source.py"\nstripped="$(mktemp -d "${TMPDIR:-/tmp}/check-mod-shared-parts.XXXXXX")" || exit 1\ntrap \'rm -rf "$stripped"\' EXIT\npython3 -I "$TS_SOURCE" strip-hooks "$dir" "$stripped"\n'
const both = ($: unknown, on: Parameters<typeof world>[1]) => {
  const w = ours($, on)
  w.files[`${APP}/${SCAN}`] = SCAN_UNREADABLE
  return w
}

test('exactly two scripts are known by name, each with the texts the world answers git about (#3082)', async () => {
  // A third name is a third exemption, which is Dan's to sign off: adding one turns this red.
  expect(NAMED.map(n => [n.repo, n.script])).toEqual([[REPO, 'tools/check-mods.sh'], [REPO, SCAN]])
  expect(NAMED).toEqual([CHECK_MODS, SHARED_PARTS])
  expect(unchangedArgs(SHARED_PARTS, 'main').join(' ')).toBe(`diff --quiet --merge-base origin/main -- ${SCAN_TEXTS}`)
})

test("this repository's own tools/check-mod-shared-parts.sh handed a folder holding held files runs, judging no file, on record (#3082)", KIT, async ($, on) => {
  const w = both($, on)
  expect((await bash($ as never, w, `bash ${SCAN} src/`)).result).toBe('done')
  expect((await bash($ as never, w, `./${SCAN} src/`, {}, 'b2')).result).toBe('done')
  expect((await bash($ as never, w, `cd ./src && bash ../${SCAN} lib 2>&1 | tail -n 40`, {}, 'b3')).result).toBe('done')
  expect(w.judged().length).toBe(0)
  expect(named(w)).toMatchObject([
    { word: 'src/', script: `${APP}/${SCAN}`, decision: 'passed' },
    { word: 'src/', script: `${APP}/${SCAN}`, decision: 'passed' },
    { word: 'lib', script: `${APP}/${SCAN}`, decision: 'passed' },
  ])
  // Its own texts are the ones git was asked about, never the other script's.
  expect(w.ran.filter(l => l.includes(' diff ')).every(l => l.endsWith(SCAN_TEXTS))).toBe(true)
  expect(w.ran.filter(l => l.includes(' diff ')).length).toBe(3)
})

test('the scan in another repository is held as before, and git is never asked about its text (#3082)', KIT, async ($, on) => {
  const other = world($, on)
  other.files[`${APP}/${SCAN}`] = SCAN_UNREADABLE
  expect(refusal(await bash($ as never, other, `bash ${SCAN} src/`))).toContain(HELD)
  expect(named(other)).toMatchObject([{ decision: 'judged', why: `it is in a checkout of dan/app, never ${REPO}` }])
  expect(other.ran.filter(l => l.includes(' diff '))).toEqual([])
})

test('a copy of the scan elsewhere in this repository is held as before (#3082)', KIT, async ($, on) => {
  const w = both($, on)
  w.files[`${APP}/copy/${SCAN}`] = SCAN_UNREADABLE
  expect(refusal(await bash($ as never, w, `bash copy/${SCAN} src/`))).toContain(HELD)
  expect(named(w)).toMatchObject([{ decision: 'judged', why: `it is not ${SCAN} at the root of its checkout` }])
  expect(w.ran.filter(l => l.includes(' diff '))).toEqual([])
})

test("each named script answers for its own texts: one's change holds it and never the other (#3082)", KIT, async ($, on) => {
  const w = both($, on)
  w.ctl.scanDiff = 1
  expect(refusal(await bash($ as never, w, `bash ${SCAN} src/`))).toContain(HELD)
  expect((await bash($ as never, w, 'bash tools/check-mods.sh src/', {}, 'b2')).result).toBe('done')
  w.ctl.scanDiff = 0
  w.ctl.namedDiff = 1
  expect((await bash($ as never, w, `bash ${SCAN} src/`, {}, 'b3')).result).toBe('done')
  expect(refusal(await bash($ as never, w, 'bash tools/check-mods.sh src/', {}, 'b4'))).toContain(HELD)
  const CHANGED = 'its text, or that of a file it sources or runs, has changed since this checkout left origin/main, so it is not the text the suite proved'
  expect(named(w).map(x => [x.script, x.decision, x.why])).toEqual([
    [`${APP}/${SCAN}`, 'judged', CHANGED],
    [`${APP}/tools/check-mods.sh`, 'passed', undefined],
    [`${APP}/${SCAN}`, 'passed', undefined],
    [`${APP}/tools/check-mods.sh`, 'judged', CHANGED],
  ])
})

// The scan in any other shape, and beside the other named script, judged as before.
const SCAN_SHAPES: [string, string][] = [
  ['handed a second folder', `bash ${SCAN} lib src/`],
  ['with the folder it keeps its copies in set for it', `TMPDIR=src bash ${SCAN} src/`],
  ['with the python it runs set for it', `PATH=src:$PATH bash ${SCAN} src/`],
  ['after a value read and exported with no equals sign', `read TMPDIR <<< src; export TMPDIR; bash ${SCAN} src/`],
  ['run by another shell', `sh ${SCAN} src/`],
  ['handed a file', `bash ${SCAN} src/big.ts`],
  ['with its output sent into a held file', `bash ${SCAN} src/ > src/big.ts`],
  ['chained with an edit of a held file', `bash ${SCAN} src/ && sed -i '' 's/a/b/' src/big.ts`],
  ['chained after the other named script', `bash tools/check-mods.sh src/ && bash ${SCAN} src/`],
  ['chained before the other named script', `bash ${SCAN} src/; bash tools/check-mods.sh src/`],
]

test('the scan in any other shape, and chained with the other named script, is held as before (#3082)', KIT, async ($, on) => {
  const w = both($, on)
  const held: string[] = []
  for (const [i, [what, command]] of SCAN_SHAPES.entries()) {
    const r = await bash($ as never, w, command, {}, `b${i + 1}`)
    const why = r.result === 'done' ? 'ran' : refusal(r)
    held.push(/which writes src\/big\.ts\./.test(why) ? `held: ${what}` : `${what}: ${why}`)
  }
  expect(held).toEqual(SCAN_SHAPES.map(([what]) => `held: ${what}`))
  // Chained, each of the two is judged for the other running beside it, and neither is let through.
  const chained = named(w).slice(-4)
  expect(chained.map(x => [x.decision, x.why])).toEqual(Array(4).fill(['judged', 'bash runs in the same command, and what that leaves in the environment cannot be read']))
})

test("this repository's own tools/check-mods.sh handed a folder holding held files runs, judging no file, on record (#3022)", KIT, async ($, on) => {
  const w = ours($, on)
  expect((await bash($ as never, w, 'bash tools/check-mods.sh src/')).result).toBe('done')
  expect((await bash($ as never, w, './tools/check-mods.sh src/', {}, 'b2')).result).toBe('done')
  expect((await bash($ as never, w, `bash ${APP}/tools/check-mods.sh ${APP}/src 2>&1 | tail -n 40`, {}, 'b3')).result).toBe('done')
  expect((await bash($ as never, w, 'cd ./src && bash ../tools/check-mods.sh lib 2>&1 | grep -v ok | tail -n 40', {}, 'b4')).result).toBe('done')
  expect(w.judged().length).toBe(0)
  // Each run let through is in the log, so a rule that lets everything through shows there (L551).
  expect(named(w)).toMatchObject([
    { word: 'src/', script: `${APP}/tools/check-mods.sh`, decision: 'passed' },
    { word: 'src/', script: `${APP}/tools/check-mods.sh`, decision: 'passed' },
    { word: `${APP}/src`, script: `${APP}/tools/check-mods.sh`, decision: 'passed' },
    { word: 'lib', script: `${APP}/tools/check-mods.sh`, decision: 'passed' },
  ])
})

test('a script of the same name in another repository, or elsewhere in this one, is held as before, and git is never asked about its text (#3022)', KIT, async ($, on) => {
  const other = world($, on)
  other.files[`${APP}/tools/check-mods.sh`] = UNREADABLE
  expect(refusal(await bash($ as never, other, 'bash tools/check-mods.sh src/'))).toContain(HELD)
  expect(named(other)).toMatchObject([{ decision: 'judged', why: `it is in a checkout of dan/app, never ${REPO}` }])
  expect(other.ran.filter(l => l.includes(' diff '))).toEqual([])
})

test('a copy of the script elsewhere in this repository is held as before (#3022)', KIT, async ($, on) => {
  const w = ours($, on)
  w.files[`${APP}/copy/tools/check-mods.sh`] = UNREADABLE
  expect(refusal(await bash($ as never, w, 'bash copy/tools/check-mods.sh src/'))).toContain(HELD)
  expect(named(w)).toMatchObject([{ decision: 'judged', why: 'it is not tools/check-mods.sh at the root of its checkout' }])
  expect(w.ran.filter(l => l.includes(' diff '))).toEqual([])
})

test('a copy whose text changed since its checkout left the default branch, or that git cannot compare, is held as before (#3022)', KIT, async ($, on) => {
  const w = ours($, on)
  w.ctl.namedDiff = 1
  expect(refusal(await bash($ as never, w, 'bash tools/check-mods.sh src/'))).toContain(HELD)
  w.ctl.namedDiff = 129
  expect(refusal(await bash($ as never, w, 'bash tools/check-mods.sh src/', {}, 'b2'))).toContain(HELD)
  expect(named(w).map(x => [x.decision, x.why])).toEqual([
    ['judged', 'its text, or that of a file it sources or runs, has changed since this checkout left origin/main, so it is not the text the suite proved'],
    ['judged', 'git could not compare its text with origin/main (exit 129)'],
  ])
})

// Every other shape of the run, and everything beside it in the command, judged as before.
const SHAPES: [string, string][] = [
  ['handed a second folder', 'bash tools/check-mods.sh lib src/'],
  ['with a value set for it', 'TMPDIR=src bash tools/check-mods.sh src/'],
  ['after a value read and exported with no equals sign', 'read TMPDIR <<< src; export TMPDIR; bash tools/check-mods.sh src/'],
  ['after a file is sourced', '. ./env.sh; bash tools/check-mods.sh src/'],
  ['after any other command', 'git fetch origin && bash tools/check-mods.sh src/'],
  ['run twice, a value exported between the two', 'bash tools/check-mods.sh src/; export TMPDIR; bash tools/check-mods.sh src/'],
  ['in a loop that reads and exports a value after it', 'for i in 1 2; do bash tools/check-mods.sh src/; read TMPDIR <<< src; export TMPDIR; done'],
  ['in a function called after a value is read and exported', 'f() { bash tools/check-mods.sh src/; }; read TMPDIR <<< src; export TMPDIR; f'],
  ['run by another shell', 'sh tools/check-mods.sh src/'],
  ['handed a file', 'bash tools/check-mods.sh src/big.ts'],
  ['handed a name built as the command runs', 'bash tools/check-mods.sh "$MODS"'],
  ['with its output sent into a held file', 'bash tools/check-mods.sh src/ > src/big.ts'],
  ['chained with an edit of a held file', "bash tools/check-mods.sh src/ && sed -i '' 's/a/b/' src/big.ts"],
  ['beside another script handed the same folder', 'bash tools/check-mods.sh src/ && bash rewrite.sh src/'],
]

test('the named script in any other shape, and every command chained with it, is held as before (#3022)', KIT, async ($, on) => {
  const w = ours($, on)
  w.files[`${APP}/rewrite.sh`] = 'sed -i \'\' \'s/a/b/\' "$1"/*.ts\n'
  const held: string[] = []
  for (const [i, [what, command]] of SHAPES.entries()) {
    const r = await bash($ as never, w, command, {}, `b${i + 1}`)
    const why = r.result === 'done' ? 'ran' : refusal(r)
    held.push(/which writes (src\/big\.ts|\$MODS)\./.test(why) ? `held: ${what}` : `${what}: ${why}`)
  }
  expect(held).toEqual(SHAPES.map(([what]) => `held: ${what}`))
})

// The rule alone, with the facts handed in: what it asks, in what order, and that a fact it cannot
// have never lets a run through (fail closed).
const RUN = 'bash tools/check-mods.sh src/'
const facts = (over: Partial<NamedFacts> = {}, asked: string[] = []): NamedFacts => ({
  commands: async command => {
    asked.push(`commands ${command}`)
    return pipelineIn(command, APP, HOME, { assignments: true })
  },
  checkout: async path => {
    asked.push(`checkout ${path}`)
    return { root: APP, github: REPO, defaultBranch: 'main' }
  },
  isFolder: async path => {
    asked.push(`folder ${path}`)
    return true
  },
  git: async (root, args) => {
    asked.push(`git ${root} ${args.join(' ')}`)
    return 0
  },
  ...over,
})
const read = (command: string, f: NamedFacts) => namedReaders(command, commandWrites(command, APP, HOME), f)
// The line the rule asks the reader about before it takes its word for anything else (#3093).
const KNOWN = 'A=1; B=2 env true'
// A reader that answers the known line as mod-kit's does, and every other command with these commands.
const only = (commands: Awaited<ReturnType<NamedFacts['commands']>>): NamedFacts['commands'] => async command => (command === KNOWN ? pipelineIn(command, APP, HOME, { assignments: true }) : commands)

test('a run let through is taken out of what the command is read as writing, and nothing else is (#3022)', async () => {
  const asked: string[] = []
  const r = await read(`${RUN} > src/big.ts`, facts({}, asked))
  expect(r.writes.runs ?? []).toEqual([])
  expect(r.writes.files.map(f => f.path)).toEqual([`${APP}/src/big.ts`])
  expect(r.named).toEqual([{ script: `${APP}/tools/check-mods.sh`, word: 'src/', folder: `${APP}/src`, passed: true }])
  expect(asked).toEqual([`commands ${KNOWN}`, `commands ${RUN} > src/big.ts`, `checkout ${APP}/tools/check-mods.sh`, `folder ${APP}/src`, `git ${APP} diff --quiet --merge-base origin/main -- ${NAMED_TEXTS}`])
})

test('a command naming no such script is read as it was, asking nothing (#3022)', async () => {
  const asked: string[] = []
  const w = commandWrites('bash scan.sh src/', APP, HOME)
  const r = await namedReaders('bash scan.sh src/', w, facts({}, asked))
  expect(r).toEqual({ writes: w, named: [] })
  expect(asked).toEqual([])
})

const REFUSED: [string, Partial<NamedFacts>, string][] = [
  ['in no checkout', { checkout: async () => ({ unread: 'it is in no checkout' }) }, 'its checkout cannot be read (it is in no checkout)'],
  ['in a checkout of no GitHub repository', { checkout: async () => ({ root: APP, github: null, defaultBranch: 'main' }) }, `it is in a checkout of no GitHub repository, never ${REPO}`],
  ['in a checkout whose origin names no default branch', { checkout: async () => ({ root: APP, github: REPO, defaultBranch: null }) }, 'origin names no default branch, so its text cannot be compared with the one the suite proved'],
  ['handed something that is no folder', { isFolder: async () => false }, 'src/ is no folder on the disk'],
  ['in a command whose commands cannot be read', { commands: async () => Promise.reject(new Error('the pipeline could not be read')) }, 'it could not be checked (the pipeline could not be read)'],
  ['in a command the run cannot be found in', { commands: only([{ words: ['bash', 'other.sh', 'src/'] }]) }, 'the run cannot be found among the commands, so what else runs with it cannot be read'],
  ['after a command that is no change of folder', { commands: only([{ words: ['export', 'TMPDIR'] }, { words: ['bash', 'tools/check-mods.sh', 'src/'] }]) }, 'export runs in the same command, and what that leaves in the environment cannot be read'],
  // Written after it, a command still runs before it the second time round a loop, or once a function is called.
  ['before a command that is no reader of its output', { commands: only([{ words: ['bash', 'tools/check-mods.sh', 'src/'] }, { words: ['export', 'TMPDIR'] }]) }, 'export runs in the same command, and what that leaves in the environment cannot be read'],
  // The reason is written to the area check's log, so it names only the program, never its arguments,
  // which can carry a credential.
  ['beside a command whose arguments carry a credential', { commands: only([{ words: ['curl', '-H', 'Authorization: Bearer not-a-real-token', 'x'] }, { words: ['bash', 'tools/check-mods.sh', 'src/'] }]) }, 'curl runs in the same command, and what that leaves in the environment cannot be read'],
  ['run twice in the command', { commands: only([{ words: ['bash', 'tools/check-mods.sh', 'src/'] }, { words: ['bash', 'tools/check-mods.sh', 'src/'] }]) }, 'the script is run more than once in the command, and what runs between cannot be read'],
  ['whose checkout cannot be asked about', { checkout: async () => Promise.reject(new Error('git could not be asked')) }, 'it could not be checked (git could not be asked)'],
  ['whose folder cannot be looked at', { isFolder: async () => Promise.reject(new Error('EACCES')) }, 'it could not be checked (EACCES)'],
  ['whose text git cannot be started to compare', { git: async () => Promise.reject(new Error('git timed out')) }, 'it could not be checked (git timed out)'],
]

test('a fact that cannot be had, or that is wrong, leaves the run to be judged as before, saying why (#3022)', async () => {
  const w = commandWrites(RUN, APP, HOME)
  for (const [what, over, why] of REFUSED) {
    const r = await namedReaders(RUN, w, facts(over))
    expect([what, r.writes, r.named]).toEqual([what, w, [{ script: `${APP}/tools/check-mods.sh`, word: 'src/', folder: `${APP}/src`, why }]])
  }
})

test('the repository is matched whatever case GitHub spells it in (#3022)', async () => {
  const r = await read(RUN, facts({ checkout: async () => ({ root: APP, github: 'DanWright32/Claude-Config', defaultBranch: 'main' }) }))
  expect(r.named).toMatchObject([{ passed: true }])
})

// #3093: mod-kit's reader dropped a setting written in front of a command, so the rule asked the
// command's text and held any run whose command held an equals sign, a reader's option included
// (`| tail --lines=40`). The reader carries the settings now, so an equals sign holds the run only
// where it may set a value for the script: on the run itself, on the change of folder before it, on
// its own before it, or in the words of either. A loosening, signed off by Dan (2026-11-16).
const READS = 'and the script, the shell that runs it and the programs it runs take what they run and where they keep their files from the environment'
const given = (names: string) => `it is run with ${names} set, ${READS}`
const setAlone = (names: string) => `the command sets ${names} on its own, ${READS}`
const BESIDE = 'runs in the same command, and what that leaves in the environment cannot be read'
const OWN_WORDS = 'holds an equals sign in its words or in a heredoc fed to it, which the shell may read as setting a value'
const OLD_READER = 'the reader of commands loaded in this session does not say what a command is run with or behind (#3093), so the run cannot be shown to be the plain one'
const behindIt = (names: string) => `it is run behind ${names}, which can change the folder or the environment it runs in`

const NO_SETTING: [string, string][] = [
  ['an option written with an equals sign on a reader of its output', 'bash tools/check-mods.sh src/ 2>&1 | tail --lines=40'],
  ['a pattern holding an equals sign on a reader of its output', 'bash tools/check-mods.sh src/ 2>&1 | grep -c "ok=1"'],
  ['two such readers after a change of folder', 'cd ./src && bash ../tools/check-mods.sh lib 2>&1 | grep -v "skip=" | tail --lines=40'],
  ['a setting given to a reader of its output', 'bash tools/check-mods.sh src/ | LC_ALL=C sort'],
  ['a comment holding an equals sign', 'bash tools/check-mods.sh src/ # compare with ok=1'],
]

test('an equals sign that gives the script no setting no longer holds the run (#3093)', KIT, async ($, on) => {
  const w = ours($, on)
  const ran: string[] = []
  for (const [i, [what, command]] of NO_SETTING.entries()) {
    const r = await bash($ as never, w, command, {}, `b${i + 1}`)
    ran.push(r.result === 'done' ? `ran: ${what}` : `${what}: ${refusal(r)}`)
  }
  expect(ran).toEqual(NO_SETTING.map(([what]) => `ran: ${what}`))
  expect(w.judged().length).toBe(0)
  expect(named(w).map(x => x.decision)).toEqual(NO_SETTING.map(() => 'passed'))
})

// Each is held as before, and the log says why by the name set, never by its value.
const SETTING: [string, string, string][] = [
  ['with a value set in front of it', 'TMPDIR=src bash tools/check-mods.sh src/', given('TMPDIR')],
  ['with a value given to it by env', 'env TMPDIR=src bash tools/check-mods.sh src/', given('TMPDIR')],
  ['with the programs it runs named in front of it', 'CLAUDE_BIN=/tmp/claude TSC_BIN=/tmp/tsc bash tools/check-mods.sh src/', given('CLAUDE_BIN, TSC_BIN')],
  ['with where it keeps its logs moved', 'CHECK_MODS_FAILURE_OUTPUT=src bash tools/check-mods.sh src/', given('CHECK_MODS_FAILURE_OUTPUT')],
  ["with the shell's own startup file named", 'BASH_ENV=./env.sh bash tools/check-mods.sh src/', given('BASH_ENV')],
  ['with the folders its programs are found in changed', 'PATH=/tmp/bin:$PATH bash tools/check-mods.sh src/', given('PATH')],
  ['with a name the script does not read itself, which the programs it runs may', 'NODE_OPTIONS=--require=/tmp/x.js bash tools/check-mods.sh src/', given('NODE_OPTIONS')],
  ['with a value that is a credential, which the log never holds', 'TOKEN=not-a-real-token bash tools/check-mods.sh src/', given('TOKEN')],
  ['with a value set for the shell whose script runs it', "TMPDIR=src bash -c 'bash tools/check-mods.sh src/'", given('TMPDIR')],
  ['with a value set in front of the change of folder before it', 'TMPDIR=src cd ./src && bash ../tools/check-mods.sh lib', 'the change of folder before it is run with TMPDIR set, and no value set before the script is let through'],
  ['after a value set on its own', 'TMPDIR=src; bash tools/check-mods.sh src/', setAlone('TMPDIR')],
  ['after two values set on their own', 'CLAUDE_BIN=/tmp/claude TOKEN=not-a-real-token; bash tools/check-mods.sh src/', setAlone('CLAUDE_BIN, TOKEN')],
  ['after a value set on its own inside braces', '{ PATH=/tmp/bin; bash tools/check-mods.sh src/; }', setAlone('PATH')],
  ['before a value set on its own, which a loop runs before it the second time round', 'while bash tools/check-mods.sh src/ | grep -q x; do PATH=/tmp/bin; done', setAlone('PATH')],
  ['after a value added to', 'PATH+=:/tmp/not-a-real-token; bash tools/check-mods.sh src/', `a word holding an equals sign ${BESIDE}`],
  ['after a value exported', 'export CLAUDE_BIN=/tmp/x; bash tools/check-mods.sh src/', `export ${BESIDE}`],
  ['chained after a command holding an equals sign', 'git log --format=%s && bash tools/check-mods.sh src/', `git ${BESIDE}`],
  ['handed its folder as the value of an option', 'bash tools/check-mods.sh --mods=src/', `it ${OWN_WORDS}`],
  ['fed a heredoc holding an equals sign', 'bash tools/check-mods.sh src/ <<EOF\nPATH=/tmp/bin\nEOF', `it ${OWN_WORDS}`],
  ['after a change of folder whose path holds an equals sign', 'cd ./a=b/.. && bash tools/check-mods.sh src/', `the change of folder before it ${OWN_WORDS}`],
]

test('a setting the script may read, wherever the command gives it, still holds the run, and the log names it without its value (#3093)', KIT, async ($, on) => {
  const w = ours($, on)
  const held: string[] = []
  for (const [i, [what, command]] of SETTING.entries()) {
    const r = await bash($ as never, w, command, {}, `b${i + 1}`)
    const why = r.result === 'done' ? 'ran' : refusal(r)
    held.push(/which writes src\/(big\.ts|lib\/slack\.ts)\./.test(why) ? `held: ${what}` : `${what}: ${why}`)
  }
  expect(held).toEqual(SETTING.map(([what]) => `held: ${what}`))
  expect(named(w).map(x => [x.decision, x.why])).toEqual(SETTING.map(([, , why]) => ['judged', why]))
  expect(JSON.stringify(w.records())).not.toContain('not-a-real-token')
})

test('a change of folder whose path sets a value as the shell reads it leaves the run unplaced, so it is held as any script is (#3093)', KIT, async ($, on) => {
  const w = ours($, on)
  expect(refusal(await bash($ as never, w, 'cd "./${TMPDIR:=src}/.." && bash tools/check-mods.sh src/'))).toContain('The area check held this Bash command')
  expect(named(w)).toEqual([])
})

// A copy of mod-kit loaded before #3093 answers the same calls with no setting, no command that only
// sets a value and no runner, and says nothing. With it a run given a setting, or standing behind a
// runner, reads exactly as the plain run, so nothing is let through until the reader shows it carries them.
test('a reader of commands loaded before #3093 says nothing of settings or runners, so no run is let through (#3093)', KIT, async ($, on) => {
  const w = ours($, on)
  w.ctl.oldReader = true
  const commands = ['TMPDIR=src bash tools/check-mods.sh src/', 'TMPDIR=src; bash tools/check-mods.sh src/', 'env -C copy bash tools/check-mods.sh src/', 'bash tools/check-mods.sh src/ 2>&1 | tail --lines=40', 'bash tools/check-mods.sh src/']
  for (const [i, command] of commands.entries()) expect([command, refusal(await bash($ as never, w, command, {}, `b${i + 1}`)).includes(HELD)]).toEqual([command, true])
  expect(named(w).map(x => [x.decision, x.why])).toEqual(commands.map(() => ['judged', OLD_READER]))
})

const LINES = `${RUN} 2>&1 | tail --lines=40`
// What a reader loaded before #3093 answers: the same commands, no setting or runner carried, none that only sets a value.
const before3093: NamedFacts['commands'] = async command => pipelineIn(command, APP, HOME).map(({ env: _env, behind: _behind, ...c }) => c)

test('the rule asks the reader a line it knows the answer for before it takes its word for any command (#3093)', async () => {
  const asked: string[] = []
  expect((await read(LINES, facts({}, asked))).named).toMatchObject([{ passed: true }])
  expect(asked).toEqual([`commands ${KNOWN}`, `commands ${LINES}`, `checkout ${APP}/tools/check-mods.sh`, `folder ${APP}/src`, `git ${APP} diff --quiet --merge-base origin/main -- ${NAMED_TEXTS}`])
  const old: string[] = []
  const r = await read(RUN, facts({ commands: async c => (old.push(c), before3093(c)) }))
  expect(r.named).toMatchObject([{ why: OLD_READER }])
  expect(old).toEqual([KNOWN])
})

// Each of the three facts the rule rests on is asked for by the known line, so a reader lacking any one is not trusted.
const PARTIAL: [string, NamedFacts['commands']][] = [
  ['the commands that only set a value', async command => pipelineIn(command, APP, HOME)],
  ['the settings a command is run with', async command => pipelineIn(command, APP, HOME, { assignments: true }).map(({ env: _env, ...c }) => c)],
  ['what a command is run behind', async command => pipelineIn(command, APP, HOME, { assignments: true }).map(({ behind: _behind, ...c }) => c)],
]

test('a reader that leaves out any one of the settings, the commands that only set a value and the runners is not trusted (#3093)', async () => {
  const got: [string, unknown][] = []
  for (const [what, commands] of PARTIAL) got.push([what, (await read(RUN, facts({ commands }))).named.map(n => ('why' in n ? n.why : 'passed'))])
  expect(got).toEqual(PARTIAL.map(([what]) => [what, [OLD_READER]]))
})

// The gap was on main since #3022: the reader looks past a runner, so `env -C copy bash
// tools/check-mods.sh src/` was read as the plain run, though the script that runs is the one under
// copy/, and `env -i`, `env -u` and `sudo` change the environment the script reads with no equals
// sign. The reader says what a command is run behind now, and a run behind anything is held.
const BEHIND: [string, string, string][] = [
  ['behind env changing the folder', 'env -C copy bash tools/check-mods.sh src/', behindIt('env')],
  ['behind env changing the folder, spelled long', 'env --chdir=copy bash tools/check-mods.sh src/', behindIt('env')],
  ['behind env clearing the environment', 'env -i bash tools/check-mods.sh src/', behindIt('env')],
  ['behind env clearing the environment, spelled long', 'env --ignore-environment bash tools/check-mods.sh src/', behindIt('env')],
  ['behind env unsetting a name', 'env -u TMPDIR bash tools/check-mods.sh src/', behindIt('env')],
  ['behind env unsetting a name, spelled long', 'env --unset=TMPDIR bash tools/check-mods.sh src/', behindIt('env')],
  ['behind env splitting a string into the run', "env -S 'bash tools/check-mods.sh src/'", behindIt('env')],
  ['behind env searching other folders for bash', 'env -P /tmp/bin bash tools/check-mods.sh src/', behindIt('env')],
  ['behind env with any other option', 'env -0 bash tools/check-mods.sh src/', behindIt('env')],
  ['behind a bare env', 'env bash tools/check-mods.sh src/', behindIt('env')],
  ['behind sudo', 'sudo bash tools/check-mods.sh src/', behindIt('sudo')],
  ['behind nohup', 'nohup bash tools/check-mods.sh src/', behindIt('nohup')],
  ['behind nice and timeout', 'nice -n 5 timeout 600 bash tools/check-mods.sh src/', behindIt('nice, timeout')],
  ['behind exec', 'exec bash tools/check-mods.sh src/', behindIt('exec')],
  ['behind command', 'command bash tools/check-mods.sh src/', behindIt('command')],
  ['behind time', 'time bash tools/check-mods.sh src/', behindIt('time')],
  ['behind xargs', 'xargs bash tools/check-mods.sh src/ < /dev/null', behindIt('xargs')],
  ['behind rtk', 'rtk bash tools/check-mods.sh src/', behindIt('rtk')],
  ["in a shell's own script", "bash -c 'bash tools/check-mods.sh src/'", behindIt('bash')],
  ["in a login shell's script", "zsh -lc 'bash tools/check-mods.sh src/'", behindIt('zsh')],
  ['in a script a shell reads from a heredoc', "bash <<'EOF'\nbash tools/check-mods.sh src/\nEOF", behindIt('bash')],
  ['after a change of folder run behind sudo, which changes no folder', 'sudo cd ./src && bash ../tools/check-mods.sh lib', 'the change of folder before it is run behind sudo, which can change the folder or the environment it runs in'],
]
const NOT_PLAIN_CD = 'the change of folder before it is not a cd to one folder written from /, ./, ../ or ~, so the folder the script runs in cannot be shown'
const FOLDER: [string, string, string][] = [
  ['after a change of folder by a bare name, which is looked up along CDPATH', 'cd src && bash ../tools/check-mods.sh lib', NOT_PLAIN_CD],
  ['after a change of folder with an option', 'cd -P ./src && bash ../tools/check-mods.sh lib', NOT_PLAIN_CD],
  ['after a change of folder handed two words', 'cd ./src lib && bash ../tools/check-mods.sh lib', NOT_PLAIN_CD],
  ['after a pushd', 'pushd ./src && bash ../tools/check-mods.sh lib', `pushd ${BESIDE}`],
]

test('a run behind a runner, in a shell\'s script, or after a change of folder the reader cannot show, is held (#3093)', KIT, async ($, on) => {
  const w = ours($, on)
  const all = [...BEHIND, ...FOLDER]
  const held: string[] = []
  for (const [i, [what, command]] of all.entries()) {
    const r = await bash($ as never, w, command, {}, `b${i + 1}`)
    const why = r.result === 'done' ? 'ran' : refusal(r)
    held.push(/which writes src\/(big\.ts|lib\/slack\.ts)\./.test(why) ? `held: ${what}` : `${what}: ${why}`)
  }
  expect(held).toEqual(all.map(([what]) => `held: ${what}`))
  expect(named(w).map(x => [x.decision, x.why])).toEqual(all.map(([, , why]) => ['judged', why]))
})

test('a change of folder the reader cannot follow leaves the run unplaced, so it is held as any script is (#3093)', KIT, async ($, on) => {
  const w = ours($, on)
  for (const [i, command] of ['cd - && bash tools/check-mods.sh src/', 'cd "$WT" && bash tools/check-mods.sh src/', 'cd ./sr* && bash ../tools/check-mods.sh lib'].entries())
    expect([command, refusal(await bash($ as never, w, command, {}, `b${i + 1}`)).includes('The area check held this Bash command')]).toEqual([command, true])
  expect(named(w)).toEqual([])
})

const PLAIN: [string, string][] = [
  ['from the folder it is in', 'bash tools/check-mods.sh src/'],
  ['after a change of folder written from the current one', 'cd ./src && bash ../tools/check-mods.sh lib'],
  ['after a change of folder written from the root', `cd ${APP}/src && bash ../tools/check-mods.sh lib`],
  ['after a change of folder written from the one above', 'cd ../app/src && bash ../tools/check-mods.sh lib'],
  ['after two changes of folder', 'cd ./src && cd ./lib && bash ../../tools/check-mods.sh .'],
  ['with its outcome turned round', '! bash tools/check-mods.sh src/'],
]

test('the plain run, and one after a change of folder written from a place the shell does not look up, still runs unjudged (#3093)', KIT, async ($, on) => {
  const w = ours($, on)
  const ran: string[] = []
  for (const [i, [what, command]] of PLAIN.entries()) {
    const r = await bash($ as never, w, command, {}, `b${i + 1}`)
    ran.push(r.result === 'done' ? `ran: ${what}` : `${what}: ${refusal(r)}`)
  }
  expect(ran).toEqual(PLAIN.map(([what]) => `ran: ${what}`))
  expect(named(w).map(x => x.decision)).toEqual(PLAIN.map(() => 'passed'))
})

// Dan's #3093 sign off (2026-11-16) loosened the hold on an equals sign for tools/check-mods.sh
// alone. The scan was signed off (#3082) with "the command holds no equals sign", so every command
// the loosening lets through for the first script still holds the scan, and what #3093 tightened (a
// runner, a change of folder by a bare name) holds the scan as it holds the first.
const ANY_EQUALS = 'the command sets a value (it holds an equals sign), and the script takes the programs it runs and where it keeps its copies from the environment'
const SCAN_HELD: [string, string, string][] = [
  ...NO_SETTING.map(([what, command]): [string, string, string] => [what, command.replace('tools/check-mods.sh', SCAN), ANY_EQUALS]),
  ['behind env clearing the environment', `env -i bash ${SCAN} src/`, behindIt('env')],
  ['after a change of folder by a bare name', `cd src && bash ../${SCAN} lib`, NOT_PLAIN_CD],
]

test('an equals sign anywhere in the command still holds the scan, which the loosening for check-mods does not reach, and a runner or a bare change of folder holds it too (#3082, #3093)', KIT, async ($, on) => {
  const w = both($, on)
  const held: string[] = []
  for (const [i, [what, command]] of SCAN_HELD.entries()) {
    const r = await bash($ as never, w, command, {}, `b${i + 1}`)
    const why = r.result === 'done' ? 'ran' : refusal(r)
    held.push(/which writes src\/(big\.ts|lib\/slack\.ts)\./.test(why) ? `held: ${what}` : `${what}: ${why}`)
  }
  expect(held).toEqual(SCAN_HELD.map(([what]) => `held: ${what}`))
  expect(named(w).map(x => [x.script, x.decision, x.why])).toEqual(SCAN_HELD.map(([, , why]) => [`${APP}/${SCAN}`, 'judged', why]))
})

// Lessons review of #3131 at 2a15886: a change of folder that fails leaves the shell where it was,
// and joined by `;` or `||` the script still runs, from there. `cd ./nowhere; bash
// ../tools/check-mods.sh /w/app/src/` was read as the script at the root of the checkout, and what
// runs is the file one folder above it, which nobody compared. The reader does not say what joins
// two commands, so every change of folder before the run must lead to a folder on the disk.
const LEADS = (where: string) => `the change of folder before it leads to ${where}, so the script may run from another folder than the one it was read in`
const FAILED_CD: [string, string][] = [
  ['joined by a semicolon', `cd ./nowhere; bash ../tools/check-mods.sh ${APP}/src/`],
  ['run only if the change of folder fails', `cd ./nowhere || bash ../tools/check-mods.sh ${APP}/src/`],
  ['joined so the shell would not run it, which the reader cannot tell from the two above', `cd ./nowhere && bash ../tools/check-mods.sh ${APP}/src/`],
  ['after two changes of folder, the first to a folder that is there', `cd ./src && cd ./nowhere; bash ../../tools/check-mods.sh ${APP}/src/`],
  ['the scan, joined by a semicolon', `cd ./nowhere; bash ../${SCAN} ${APP}/src/`],
  ['the scan, run only if the change of folder fails', `cd ./nowhere || bash ../${SCAN} ${APP}/src/`],
]

test('a run after a change of folder to no folder on the disk is held, since the script may run from where the shell was (#3131 lessons review)', KIT, async ($, on) => {
  const w = both($, on)
  const held: string[] = []
  for (const [i, [what, command]] of FAILED_CD.entries()) {
    const r = await bash($ as never, w, command, {}, `b${i + 1}`)
    const why = r.result === 'done' ? 'ran' : refusal(r)
    held.push(/which writes src\/(big\.ts|lib\/slack\.ts)\./.test(why) ? `held: ${what}` : `${what}: ${why}`)
  }
  expect(held).toEqual(FAILED_CD.map(([what]) => `held: ${what}`))
  expect(named(w).map(x => [x.decision, x.why])).toEqual(FAILED_CD.map(() => ['judged', LEADS('no folder on the disk')]))
})

test('a change of folder the reader gives no folder for holds the run, and one to a folder on the disk does not (#3131 lessons review)', async () => {
  const command = 'cd ./src && bash ../tools/check-mods.sh lib'
  const unplaced = only([{ words: ['cd', './src'] }, { words: ['bash', '../tools/check-mods.sh', 'lib'] }])
  expect((await read(command, facts({ commands: unplaced }))).named).toMatchObject([{ why: LEADS('a folder the reader cannot place') }])
  const asked: string[] = []
  expect((await read(command, facts({}, asked))).named).toMatchObject([{ passed: true }])
  expect(asked).toContain(`folder ${APP}/src`)
})

test('a setting the write reader carries on the run holds it though the commands show none (#3093)', async () => {
  const command = `TMPDIR=src ${RUN}`
  const bare: NamedFacts['commands'] = async c => (c === command ? [{ words: ['bash', 'tools/check-mods.sh', 'src/'] }] : pipelineIn(c, APP, HOME, { assignments: true }))
  expect((await read(command, facts({ commands: bare }))).named).toMatchObject([{ why: given('TMPDIR') }])
})
