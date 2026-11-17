// Scripts the area check knows by name to write no file git tracks in the folder they are handed,
// where their own text cannot be read to say so. Each one is an exemption Dan signed off, for that
// script alone, held to the script by a suite that runs it.

import type { EngineInterface } from 'claude-code'
import type {} from '../types/index.d.ts'
import type { ModKitWrites } from '../.claude-plugin/types/mod-kit/index.d.ts'

// How long each of the two git reads may take. They come before the judging, which has a deadline of
// its own inside the hook's budget, so they are bounded well inside it; one that runs out lets
// nothing through, and the run is judged as before.
const GIT_MS = 2_000

type Run = NonNullable<ModKitWrites['runs']>[number]

/**
 * `bash tools/check-mods.sh <mods folder>` in a checkout of this repository (#3022, signed off by Dan,
 * 2026-11-16). It reads every mod in the folder, copies each to a folder it makes under the temporary
 * folder, and runs the type check and `claude plugin validate` and `test` on it. Its text holds what
 * the reader cannot place (values named by variables, the claude command taken from the environment,
 * libraries that keep failure logs under ~/.cache and link the pinned compiler into the ignored
 * tools/typescript/node_modules), so it was held on every run for the held files under the folder.
 *
 * `texts` is the script and every file it sources, each from the root of the checkout. A run is let
 * through only while none of them has changed since the checkout left the default branch, where
 * tests/test-area-check-check-mods-read-only.sh runs them before every merge: over a throwaway
 * checkout, it is red when a run changes a file git tracks there or adds one git does not ignore,
 * and red when a text sources a file this list lacks.
 *
 * `byValue` is every variable a program the texts run is named by, which only the environment sets
 * (#3154): the compiler (TSC_BIN), claude three times (CLAUDE_BIN), the load average's command
 * (LOAD_AVERAGE_CMD) and the pinned compiler's two test hooks. No list of texts can hold what those
 * programs are, so a command naming one before the script is held for it by name (byValueNamed). The
 * same suite names each of the seven commands by file, line and variable, and is red when one changes
 * or its variable is missing here.
 */
export const CHECK_MODS = {
  repo: 'danwright32/claude-config',
  script: 'tools/check-mods.sh',
  texts: ['tools/check-mods.sh', 'tools/lib/pinned-compiler.sh', 'payload/hooks/lib/kept-output.sh', 'payload/hooks/lib/load-average.sh', 'payload/hooks/lib/whole-number.sh'],
  byValue: ['TSC_BIN', 'CLAUDE_BIN', 'LOAD_AVERAGE_CMD', 'PINNED_TS_TEST_BEFORE_REMOVE', 'PINNED_TS_TEST_BEFORE_LINK'],
} as const

/**
 * `bash tools/check-mod-shared-parts.sh <mods folder>` in a checkout of this repository (#3082, signed
 * off by Dan, 2026-11-16). It reads every mod in the folder for a hand rolled copy of what mod-kit
 * shares. Its own commands are read as writing nothing; what kept the hold is the python program it
 * runs through a variable (`python3 -I "$TS_SOURCE" strip-hooks "$dir" "$stripped"`), which writes each
 * mod's hooks with the comments taken out into a folder the script makes under the temporary folder
 * and removes as it ends. That write is real, and its path is built inside python from the
 * program's arguments, which no reader places, so the script was held on every run for the held
 * files under the folder.
 *
 * `texts` is the script and the program it runs, which loads nothing but python's own library: it
 * imports os, re and sys, and the script runs it isolated (-I), so a file beside it named for one of
 * them is never loaded in its place. A run
 * is let through only while neither has changed since the checkout left the default branch, where
 * tests/test-area-check-shared-parts-read-only.sh runs them before every merge: over a throwaway
 * checkout holding this repository's own mods, it is red when a run changes any path in the checkout
 * or adds one, an ignored one included, and red when the script sources a file, or runs a program,
 * this list lacks.
 */
export const SHARED_PARTS = {
  repo: 'danwright32/claude-config',
  script: 'tools/check-mod-shared-parts.sh',
  texts: ['tools/check-mod-shared-parts.sh', 'tools/lib/ts_source.py'],
} as const

/**
 * A script known by name: where it lives, every text a run of it is made of, and the variables naming
 * a program it runs that only the environment sets (#3154), where it has any.
 */
export type NamedScript = { readonly repo: string; readonly script: string; readonly texts: readonly string[]; readonly byValue?: readonly string[] }

/** Every script let through by name. Each one is an exemption, so a new one is Dan's to sign off. */
export const NAMED: readonly NamedScript[] = [CHECK_MODS, SHARED_PARTS]

/**
 * What git is asked, in the checkout, to learn whether a script's texts are the ones its suite
 * proved: the working tree against where the checkout left the default branch. It exits 0 when none
 * differs and 1 when one does, an edit not yet committed included.
 */
export const unchangedArgs = (named: NamedScript, defaultBranch: string): string[] => ['diff', '--quiet', '--merge-base', `origin/${defaultBranch}`, '--', ...named.texts]

/** What the rule asks of the machine, handed in so the rule itself is plain to test. */
export type NamedFacts = {
  /**
   * The commands a Bash call runs, in the order it runs them, as mod-kit reads them when asked for
   * the commands that only set a value too (`T=x;`, given as its assignments): each with the
   * settings it is run with (`env`, #3093), what it is run behind (`behind`, #3093: each runner
   * looked past and the shell whose script it stands in), the body of each heredoc fed to it, and
   * `folder`, the folder it runs in, a change of folder before it followed (#2000); null or absent
   * where the reader cannot place it.
   */
  commands: (command: string) => Promise<readonly { words: readonly string[]; pipedFrom?: readonly string[]; env?: readonly string[]; behind?: readonly string[]; heredocs?: readonly { body: string }[]; folder?: string | null }[]>
  /** The checkout a path is in, the GitHub repository it is a clone of, and its default branch. */
  checkout: (path: string) => Promise<{ root: string; github: string | null; defaultBranch: string | null } | { unread: string }>
  isFolder: (path: string) => Promise<boolean>
  /** What a git command exits with, run in a checkout. */
  git: (root: string, args: string[]) => Promise<number>
}

/** A run of a script of that name: let through, or judged as before with why. */
export type Named = { script: string; word: string; folder?: string } & ({ passed: true } | { why: string })

const SHELLS = ['a bash script file', 'a script file run directly']

type Read = Awaited<ReturnType<NamedFacts['commands']>>[number]

// A word the shell reads as setting a value where a command would begin, as mod-kit's reader takes one.
const SETS = /^[A-Za-z_][A-Za-z0-9_]*=/
// The names a list of `NAME=value` settings sets, each once. Only a name ever reaches a reason: the
// reason goes into the area check's log, and a value can be a credential.
const namesOf = (sets: readonly string[]): string => [...new Set(sets.map(s => s.slice(0, s.indexOf('='))))].join(', ')
const READS = 'and the script, the shell that runs it and the programs it runs take what they run and where they keep their files from the environment'

// A line the rule knows the reading of, asked of the reader before its word is taken about any
// command (L506). The three facts the rule rests on are new with #3093, and a copy of mod-kit loaded
// before it (a mod reloaded ahead of the mod it depends on keeps the older members, mod-kit's
// skew.ts) answers the same call with none of them and says nothing: no `env` on a command, no
// `behind`, and no command that only sets a value. A run given a setting, or standing behind a
// runner, would then read exactly as the plain run, so with such a reader nothing is let through.
const KNOWN = 'A=1; B=2 env true'
const saysHowRun = async (facts: NamedFacts): Promise<boolean> => {
  const [alone, ran, ...more] = await facts.commands(KNOWN)
  return more.length === 0 && alone?.words.join(' ') === 'A=1' && ran?.words.join(' ') === 'true' && (ran.env ?? []).join(' ') === 'B=2' && (ran.behind ?? []).join(' ') === 'env'
}

// A change of folder the reader's reading of can be shown to be where the shell goes: `cd` and one
// folder, written from the root, the current folder, the one above or the home folder, holding
// nothing the shell expands or matches against files. A bare name (`cd src`) is looked up along
// CDPATH first by bash, so it can land in another tree; an option (`-P`) or a second word changes
// what the folder is in ways the reader does not follow (zsh reads `cd old new` as a replacement).
const FROM_A_FIXED_PLACE = /^(?:\/|\.{1,2}(?:\/|$)|~(?:\/|$))[^$`*?[\]{}()]*$/
const plainCd = (c: Read): boolean => c.words.length === 2 && FROM_A_FIXED_PLACE.test(c.words[1] as string)

// A path that backs out of a folder it names: a `..` after a named part (`./a/../b`, `../a/../b`,
// `~/a/..`, `/a/..`). The reader works out where such a change of folder ends from the text alone,
// so `cd ./nowhere/../src` is placed in src, while bash and zsh refuse it when `nowhere` is not
// there (measured 2026-11-17) and stay where they were. Where the named part is a link, where the
// shell lands also depends on whether it is set to follow links, which the reader cannot know.
// Nobody needs one to run a named script, so any holds the run, whatever is on the disk. A
// path that only starts with `..` (`../`, `../../x`) names nothing before it backs out, and is
// followed as before. The home folder counts as named.
const backsOut = (path: string): boolean => {
  let named = false
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part !== '..') named = true
    else if (named) return true
  }
  return false
}

// Why an equals sign in a command holding one may set a value the script reads, or null when none
// does (#3093). `run` is the command's commands and `at` the script's own among them, with nothing
// before it but changes of folder and nothing after it but readers of its output. A null here lets
// nothing through by itself: whyNot goes on to hold a run or a change of folder standing behind a
// runner, and a change of folder that is no plain cd (plainCd).
//
// The script reads CLAUDE_BIN, TSC_BIN, TMPDIR, CHECK_MODS_FAILURE_OUTPUT, XDG_CACHE_HOME, HOME and
// PATH itself, the shell that runs it reads its own (BASH_ENV, ENV, IFS, PS4, SHELLOPTS), and the
// programs it runs (claude, the compiler under node, npm, each mod's own tests) are handed the whole
// environment and read names nobody can list (NODE_OPTIONS, a loader's DYLD_ and LD_ names). So no
// name is known to be unread, and every setting given to the run holds it, whatever its name.
// One set in front of a change of folder does not outlast it (measured 2026-11-16 on bash 3.2, bash
// in POSIX mode, zsh 5.9, macOS sh, dash and ksh), and is held all the same: nobody writes one
// meaning nothing by it. An equals sign in the words of either command, or in a heredoc fed to one,
// is held too, because the shell sets a value as it reads `${NAME:=value}` or `$((NAME=1))` there,
// and one already exported reaches the script (measured the same day on bash and zsh).
// What is left is an equals sign in a reader the output is piped into, its own settings included,
// or in a comment. A reader is a process of its own, started after the script's, so nothing it sets
// or expands reaches the script (measured the same day on bash, zsh, sh and dash: the script on the
// left of `| cat x$((ZZ=5))` still saw the ZZ it was started with).
const whySet = (run: readonly Read[], at: number, r: Run): string | null => {
  const mine = namesOf([...(run[at]?.env ?? []), ...(r.env ?? [])])
  if (mine) return `it is run with ${mine} set, ${READS}`
  const upTo = run.slice(0, at + 1)
  const before = namesOf(upTo.flatMap(c => c.env ?? []))
  if (before) return `the change of folder before it is run with ${before} set, and no value set before the script is let through`
  const holds = upTo.findIndex(c => c.words.some(w => w.includes('=')) || (c.heredocs ?? []).some(h => h.body.includes('=')))
  if (holds >= 0) return `${holds === at ? 'it' : 'the change of folder before it'} holds an equals sign in its words or in a heredoc fed to it, which the shell may read as setting a value`
  return null
}

// Why a command naming a variable a program the script runs is named by (NamedScript.byValue, #3154)
// is not the plain run, or null when it names none before the script. It reads the command's own
// text, up to the last place the script's path is written, and never the reader of commands, so a
// reader that leaves a setting out cannot let one written by name (`X=`, `export X`, `read X`,
// `unset X`, `${X:=}`) through. A name built as the command runs (`export ${p}_BIN=x`) is not seen
// here, and is held by the rules below as any setting or other command is. A name written after the script stands only in
// a reader of its output, which whyNot lets nothing else be, and that sets nothing the script sees
// (#3093), so it is left to that loosening.
const byValueNamed = (command: string, n: NamedScript): string | null => {
  const at = command.lastIndexOf(n.script)
  const before = at < 0 ? command : command.slice(0, at)
  const names = (n.byValue ?? []).filter(v => new RegExp(`(?<![A-Za-z0-9_])${v}(?![A-Za-z0-9_])`).test(before))
  if (!names.length) return null
  return `the command names ${names.join(', ')} before it, and the script runs the program ${names.length === 1 ? 'that variable names' : 'each of those variables names'}`
}

// Why a run shaped like the named one is not it, or null when it is.
const whyNot = async (command: string, r: Run, n: NamedScript, facts: NamedFacts): Promise<string | null> => {
  const [handed, ...more] = r.args
  if (!handed || more.length) return 'it is handed more than the one folder it reads'
  if (!handed.path) return `${handed.word} cannot be read as the one folder it is handed`
  const program = byValueNamed(command, n)
  if (program) return program
  // Each named script takes the programs it runs, and where it keeps its copies and logs, from the
  // environment (check-mods.sh: CLAUDE_BIN, TSC_BIN, TMPDIR, CHECK_MODS_FAILURE_OUTPUT; the shared
  // parts scan: python3 by PATH, and TMPDIR, which set to the folder puts its copies there). Dan
  // signed off on 2026-11-16 (#3093) that, for tools/check-mods.sh alone, an equals sign that gives
  // the script no setting (a reader's own option, `| tail --lines=40`) no longer holds the run. Every
  // other named script is held on any equals sign in the command, as when it was signed off (#3082),
  // until its own sign off says otherwise.
  if (n.script !== CHECK_MODS.script && command.includes('=')) return 'the command sets a value (it holds an equals sign), and the script takes the programs it runs and where it keeps its copies from the environment'
  // Until #3093 any equals sign held the run, a reader's own option included (`| tail --lines=40`),
  // because the reader carried no setting, and a run behind a runner was let through, because the
  // reader looked past it and said nothing. It says both now, so it is asked, once it has shown that
  // it does.
  if (!(await saysHowRun(facts))) return 'the reader of commands loaded in this session does not say what a command is run with or behind (#3093), so the run cannot be shown to be the plain one'
  // A value can be set with no equals sign too (`read TMPDIR <<< src; export TMPDIR`, `printf -v`, a
  // sourced file), by any command that runs before the script, and one written after it runs before
  // it too in a loop or a function. So the script is run once, and the only other commands are a
  // change of folder before it and readers its output is piped into (`2>&1 | tail -n 40`), which
  // are processes of their own. A loop's or a function's own words are commands here, and are
  // neither, and so is a command that only sets a value (`TMPDIR=x;`), wherever it stands.
  const run = await facts.commands(command)
  const mine = run.flatMap((c, i) => (c.words.includes(r.script) ? [i] : []))
  if (mine.length === 0) return 'the run cannot be found among the commands, so what else runs with it cannot be read'
  if (mine.length > 1) return 'the script is run more than once in the command, and what runs between cannot be read'
  const own = mine[0] as number
  const other = run.find((c, i) => i !== own && !(i < own ? c.words[0] === 'cd' : c.pipedFrom !== undefined))
  if (other?.words.length && other.words.every(w => SETS.test(w))) return `the command sets ${namesOf(other.words)} on its own, ${READS}`
  // Only the program is named: this reason goes into the area check's log, and an argument can carry
  // a credential. So can a first word that sets a value in a way the reader gives as a word (`A+=b`).
  if (other) return `${other.words[0]?.includes('=') ? 'a word holding an equals sign' : (other.words[0] ?? 'another command')} runs in the same command, and what that leaves in the environment cannot be read`
  // A setting is said first, so the log names it (`env TMPDIR=x bash ...` is held for TMPDIR, the
  // more exact reason, though it stands behind env too).
  const set = command.includes('=') ? whySet(run, own, r) : null
  if (set) return set
  // #3093: a runner the reader looked past, or a shell whose script the run stands in, can change
  // the folder or the environment with no setting written (env -C, env -i, env -u, sudo, a login
  // shell). The gap was on main since #3022. Only its name is known, so any holds the run.
  const behind = run.slice(0, own + 1).findIndex(c => c.behind?.length)
  if (behind >= 0) return `${behind === own ? 'it is' : 'the change of folder before it is'} run behind ${(run[behind]?.behind ?? []).join(', ')}, which can change the folder or the environment it runs in`
  if (!run.slice(0, own).every(plainCd)) return 'the change of folder before it is not a cd to one folder written from /, ./, ../ or ~, so the folder the script runs in cannot be shown'
  if (run.slice(0, own).some(c => backsOut(c.words[1] as string))) return 'the change of folder before it backs out of a folder it names (a .. after a named part), which the shell refuses when that folder is not there while the reader follows it, so the folder the script runs in cannot be shown'
  // A change of folder that fails leaves the shell where it was, and joined by `;`, `||` or a new
  // line the script still runs, from there: `cd ./nowhere; bash ../tools/check-mods.sh /w/app/src`
  // was read as the script at the root of the checkout, and what runs is the file one folder above
  // it, which nobody compared (let through since #3022; the lessons review of #3131 at 2a15886).
  // The reader does not say what joins two commands, so every change of folder, an `&&` one too,
  // must lead to a folder on the disk: the folder the reader places the next command in, which is
  // where the shell goes once no path backs out of a folder it names (backsOut, above; the lessons
  // review at 90dfc12). What this cannot show is a cd that fails on a folder that is there (one
  // the shell may not enter, or one removed between this check and the run).
  for (let i = 0; i < own; i++) {
    const to = run[i + 1]?.folder
    if (!to || !(await facts.isFolder(to))) return `the change of folder before it leads to ${to ? 'no folder on the disk' : 'a folder the reader cannot place'}, so the script may run from another folder than the one it was read in`
  }
  const at = await facts.checkout(r.path as string)
  if ('unread' in at) return `its checkout cannot be read (${at.unread})`
  if (r.path !== `${at.root}/${n.script}`) return `it is not ${n.script} at the root of its checkout`
  if (at.github?.toLowerCase() !== n.repo) return `it is in a checkout of ${at.github ?? 'no GitHub repository'}, never ${n.repo}`
  if (!(await facts.isFolder(handed.path))) return `${handed.word} is no folder on the disk`
  if (!at.defaultBranch) return 'origin names no default branch, so its text cannot be compared with the one the suite proved'
  const code = await facts.git(at.root, unchangedArgs(n, at.defaultBranch))
  if (code === 1) return `its text, or that of a file it sources or runs, has changed since this checkout left origin/${at.defaultBranch}, so it is not the text the suite proved`
  if (code !== 0) return `git could not compare its text with origin/${at.defaultBranch} (exit ${code})`
  return null
}

/**
 * What a command writes, without the folder a named script only reads. A run is let through when it
 * is the named script itself: run by bash or directly, at its path from the root of a checkout of its
 * repository, handed one folder that is on the disk, in a command that names none of the variables
 * its programs are named by before it (byValue, #3154) and gives it no setting (#3093,
 * whySet: for tools/check-mods.sh an equals sign may stand only in a reader of its output, or a
 * comment; for every other named script the command holds no equals sign at all), runs it behind no
 * runner (`env`, `sudo`, `timeout`, a shell's `-c` script, anything the reader gives as `behind`)
 * and runs nothing else but a change of folder before it (plainCd: `cd` and one folder written from
 * /, ./, ../ or ~, behind no runner, with no `..` after a named part, leading to a folder on the
 * disk, since one that fails leaves the script running from where the shell was) and readers of its
 * output after it, with its texts unchanged.
 * Then the run is taken out of `runs`, so the folder is no write of that run's. Every other write in
 * the command (a redirect of its output) stays as mod-kit read it, and a run that is not let through,
 * as one chained with any other command is not, is judged as before.
 * A fact that cannot be had lets nothing through (fail closed). `named` is every run of a script of
 * that name with what was decided, for the log.
 */
export const namedReaders = async (command: string, w: ModKitWrites, facts: NamedFacts): Promise<{ writes: ModKitWrites; named: Named[] }> => {
  const named: Named[] = []
  const kept: Run[] = []
  for (const r of w.runs ?? []) {
    const path = r.path
    const n = !r.tool && SHELLS.includes(r.what) && path ? NAMED.find(s => path.endsWith(`/${s.script}`)) : undefined
    if (!n || !path) {
      kept.push(r)
      continue
    }
    const about = { script: path, word: r.args[0]?.word ?? '', ...(r.args[0]?.path ? { folder: r.args[0].path } : {}) }
    let why: string | null
    try {
      why = await whyNot(command, r, n, facts)
    } catch (err) {
      why = `it could not be checked (${err instanceof Error ? err.message : String(err)})`
    }
    if (why === null) named.push({ ...about, passed: true })
    else {
      named.push({ ...about, why })
      kept.push(r)
    }
  }
  if (!named.some(n => 'passed' in n)) return { writes: w, named }
  return { writes: { ...w, runs: kept }, named }
}

/**
 * What a hold says of the runs of named scripts among `scripts` (each a run's path) that were not let
 * through (#3162): each script as NAMED spells it, with the reason it was judged as before, so the
 * session can tell what to change. Undefined where none was declined. The reason names programs and
 * variables, never a value, as it does in the log.
 */
export const declinedNote = (named: readonly Named[], scripts: readonly (string | null | undefined)[]): string | undefined => {
  const lines = named.flatMap(n =>
    'why' in n && scripts.includes(n.script) ? [`${NAMED.find(s => n.script.endsWith(`/${s.script}`))?.script ?? n.script} was not let through by name: ${n.why}.`] : [],
  )
  return lines.length ? [...new Set(lines)].join(' ') : undefined
}

/**
 * The facts as the engine gives them. Each git read is bounded, and one that fails rejects. A
 * function declaration, which is the only kind the engine follows `$` into past an import.
 */
export function engineFacts($: EngineInterface): NamedFacts {
  return {
    commands: async command => $.modkit.pipeline({ command, cwd: await $.session.cwd(), home: (await $.env.get('HOME')) ?? '', assignments: true }),
    checkout: async path => {
      const b = await $.modkit.branch({ path })
      if (!b) return { unread: 'it is in no checkout' }
      if ('unreadable' in b) return { unread: b.unreadable }
      const got = await $.process.run(['git', '-C', b.root, 'remote', 'get-url', 'origin'], { timeoutMs: GIT_MS })
      const remote = got.exitCode === 0 ? got.stdout.trim() || null : null
      return { root: b.root, github: (await $.modkit.repo({ root: b.main, remote })).github, defaultBranch: b.defaultBranch }
    },
    isFolder: async path => (await $.fs.exists(path)) && (await $.fs.stat(path, { resolve: true })).kind === 'dir',
    git: async (root, args) => (await $.process.run(['git', '-C', root, ...args], { timeoutMs: GIT_MS })).exitCode,
  }
}
