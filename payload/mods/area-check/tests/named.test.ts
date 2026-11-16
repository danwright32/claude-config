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
// one folder, in a command that sets no value and runs the script once, with nothing but a change of
// folder before it and readers its output is piped into after it,
// with the text its checkout left the default branch with; everything else is judged as before. tests/test-area-check-check-mods-read-only.sh runs the real script and the real reader.

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
const SCAN_UNREADABLE = '#!/bin/bash\ndir="${1%/}"\nTS_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ts_source.py"\nstripped="$(mktemp -d "${TMPDIR:-/tmp}/check-mod-shared-parts.XXXXXX")" || exit 1\ntrap \'rm -rf "$stripped"\' EXIT\npython3 "$TS_SOURCE" strip-hooks "$dir" "$stripped"\n'
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
  expect((await bash($ as never, w, `cd src && bash ../${SCAN} lib 2>&1 | tail -n 40`, {}, 'b3')).result).toBe('done')
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
  expect((await bash($ as never, w, 'cd src && bash ../tools/check-mods.sh lib 2>&1 | grep -v ok | tail -n 40', {}, 'b4')).result).toBe('done')
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
    asked.push('commands')
    return pipelineIn(command, APP, HOME)
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

test('a run let through is taken out of what the command is read as writing, and nothing else is (#3022)', async () => {
  const asked: string[] = []
  const r = await read(`${RUN} > src/big.ts`, facts({}, asked))
  expect(r.writes.runs ?? []).toEqual([])
  expect(r.writes.files.map(f => f.path)).toEqual([`${APP}/src/big.ts`])
  expect(r.named).toEqual([{ script: `${APP}/tools/check-mods.sh`, word: 'src/', folder: `${APP}/src`, passed: true }])
  expect(asked).toEqual(['commands', `checkout ${APP}/tools/check-mods.sh`, `folder ${APP}/src`, `git ${APP} diff --quiet --merge-base origin/main -- ${NAMED_TEXTS}`])
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
  ['in a command the run cannot be found in', { commands: async () => [{ words: ['bash', 'other.sh', 'src/'] }] }, 'the run cannot be found among the commands, so what else runs with it cannot be read'],
  ['after a command that is no change of folder', { commands: async () => [{ words: ['export', 'TMPDIR'] }, { words: ['bash', 'tools/check-mods.sh', 'src/'] }] }, 'export runs in the same command, and what that leaves in the environment cannot be read'],
  // Written after it, a command still runs before it the second time round a loop, or once a function is called.
  ['before a command that is no reader of its output', { commands: async () => [{ words: ['bash', 'tools/check-mods.sh', 'src/'] }, { words: ['export', 'TMPDIR'] }] }, 'export runs in the same command, and what that leaves in the environment cannot be read'],
  // The reason is written to the area check's log, so it names only the program, never its arguments,
  // which can carry a credential.
  ['beside a command whose arguments carry a credential', { commands: async () => [{ words: ['curl', '-H', 'Authorization: Bearer not-a-real-token', 'x'] }, { words: ['bash', 'tools/check-mods.sh', 'src/'] }] }, 'curl runs in the same command, and what that leaves in the environment cannot be read'],
  ['run twice in the command', { commands: async () => [{ words: ['bash', 'tools/check-mods.sh', 'src/'] }, { words: ['bash', 'tools/check-mods.sh', 'src/'] }] }, 'the script is run more than once in the command, and what runs between cannot be read'],
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
