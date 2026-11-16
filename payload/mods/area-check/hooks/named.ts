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
 */
export const CHECK_MODS = {
  repo: 'danwright32/claude-config',
  script: 'tools/check-mods.sh',
  texts: ['tools/check-mods.sh', 'tools/lib/pinned-compiler.sh', 'payload/hooks/lib/kept-output.sh', 'payload/hooks/lib/load-average.sh', 'payload/hooks/lib/whole-number.sh'],
} as const

/**
 * What git is asked, in the checkout, to learn whether the texts are the ones the suite proved: the
 * working tree against where the checkout left the default branch. It exits 0 when none differs and 1
 * when one does, an edit not yet committed included.
 */
export const unchangedArgs = (defaultBranch: string): string[] => ['diff', '--quiet', '--merge-base', `origin/${defaultBranch}`, '--', ...CHECK_MODS.texts]

/** What the rule asks of the machine, handed in so the rule itself is plain to test. */
export type NamedFacts = {
  /** The commands a Bash call runs, in the order it runs them, as mod-kit reads them. */
  commands: (command: string) => Promise<readonly { words: readonly string[]; pipedFrom?: readonly string[] }[]>
  /** The checkout a path is in, the GitHub repository it is a clone of, and its default branch. */
  checkout: (path: string) => Promise<{ root: string; github: string | null; defaultBranch: string | null } | { unread: string }>
  isFolder: (path: string) => Promise<boolean>
  /** What a git command exits with, run in a checkout. */
  git: (root: string, args: string[]) => Promise<number>
}

/** A run of a script of that name: let through, or judged as before with why. */
export type Named = { script: string; word: string; folder?: string } & ({ passed: true } | { why: string })

const SHELLS = ['a bash script file', 'a script file run directly']

// Why a run shaped like the named one is not it, or null when it is.
const whyNot = async (command: string, r: Run, facts: NamedFacts): Promise<string | null> => {
  const [handed, ...more] = r.args
  if (!handed || more.length) return 'it is handed more than the one folder it reads'
  if (!handed.path) return `${handed.word} cannot be read as the one folder it is handed`
  // The script takes the programs it runs, and where it keeps its copies and logs, from the
  // environment (CLAUDE_BIN, TSC_BIN, TMPDIR, CHECK_MODS_FAILURE_OUTPUT), and mod-kit's reading of a
  // command does not carry a value set in front of it, so the text of the command is asked.
  if (command.includes('=')) return 'the command sets a value (it holds an equals sign), and the script takes the programs it runs and where it keeps its copies from the environment'
  // A value can be set with no equals sign too (`read TMPDIR <<< src; export TMPDIR`, `printf -v`, a
  // sourced file), by any command that runs before the script, and one written after it runs before
  // it too in a loop or a function. So the script is run once, and the only other commands are a
  // change of folder before it and readers its output is piped into (`2>&1 | tail -n 40`), which
  // are processes of their own. A loop's or a function's own words are commands here, and are neither.
  const run = await facts.commands(command)
  const mine = run.flatMap((c, i) => (c.words.includes(r.script) ? [i] : []))
  if (mine.length === 0) return 'the run cannot be found among the commands, so what else runs with it cannot be read'
  if (mine.length > 1) return 'the script is run more than once in the command, and what runs between cannot be read'
  const other = run.find((c, i) => i !== mine[0] && !(i < (mine[0] as number) ? c.words[0] === 'cd' : c.pipedFrom !== undefined))
  // Only the program is named: this reason goes into the area check's log, and an argument can carry a credential.
  if (other) return `${other.words[0] ?? 'another command'} runs in the same command, and what that leaves in the environment cannot be read`
  const at = await facts.checkout(r.path as string)
  if ('unread' in at) return `its checkout cannot be read (${at.unread})`
  if (r.path !== `${at.root}/${CHECK_MODS.script}`) return `it is not ${CHECK_MODS.script} at the root of its checkout`
  if (at.github?.toLowerCase() !== CHECK_MODS.repo) return `it is in a checkout of ${at.github ?? 'no GitHub repository'}, never ${CHECK_MODS.repo}`
  if (!(await facts.isFolder(handed.path))) return `${handed.word} is no folder on the disk`
  if (!at.defaultBranch) return 'origin names no default branch, so its text cannot be compared with the one the suite proved'
  const code = await facts.git(at.root, unchangedArgs(at.defaultBranch))
  if (code === 1) return `its text, or that of a library it sources, has changed since this checkout left origin/${at.defaultBranch}, so it is not the text the suite proved`
  if (code !== 0) return `git could not compare its text with origin/${at.defaultBranch} (exit ${code})`
  return null
}

/**
 * What a command writes, without the folder a named script only reads. A run is let through when it
 * is the named script itself: run by bash or directly, at its path from the root of a checkout of its
 * repository, handed one folder that is on the disk, in a command that sets no value and runs nothing
 * else but a change of folder before it and readers of its output after it, with its texts unchanged.
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
    if (r.tool || !SHELLS.includes(r.what) || !r.path?.endsWith(`/${CHECK_MODS.script}`)) {
      kept.push(r)
      continue
    }
    const about = { script: r.path, word: r.args[0]?.word ?? '', ...(r.args[0]?.path ? { folder: r.args[0].path } : {}) }
    let why: string | null
    try {
      why = await whyNot(command, r, facts)
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
 * The facts as the engine gives them. Each git read is bounded, and one that fails rejects. A
 * function declaration, which is the only kind the engine follows `$` into past an import.
 */
export function engineFacts($: EngineInterface): NamedFacts {
  return {
    commands: async command => $.modkit.pipeline({ command, cwd: await $.session.cwd(), home: (await $.env.get('HOME')) ?? '' }),
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
