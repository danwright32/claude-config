import type { ModKitGit } from '../.claude-plugin/types/mod-kit/index.d.ts'

// #3398: where a git command acts, read in one place for every rule in this mod that places one.
// git acts on the repository a command names, never on the folder the call was typed in: every -C
// is read from the one before it (`git -C /a -C b merge y` runs in /a/b), and --git-dir,
// --work-tree, GIT_DIR and GIT_WORK_TREE name a repository or a working folder apart from any
// folder. Until #3398 each rule here read the last -C alone, in its own words: the merge and deploy
// rule, the overnight rule, the three notes kept for winding down (the branch a commit lands on,
// the files a patch changes, the files a stash gives back) and winding down's agreed cleanup branch.
// A push named by GIT_DIR was judged by the branch of the folder it was typed in, and a checkout
// naming the primary checkout by --git-dir ran from a linked worktree.
//
// Every naming is read by mod-kit's one git reader ($.modkit.git) and carried on the command
// (`gitRead`); nothing here reads an option. A relative folder is resolved by the resolver the rule
// hands in, which is the one it reads a cd with (overnight.ts `resolveDir`), so a -C and a cd are
// never read two ways. The collision guard asks git itself about each folder (its `whereGit` and
// `namedFolder`, collision-guard/hooks/collide.ts). That reading is not copied here: a mod can
// share code only through mod-kit, so until those two move there this mod asks git nothing about a
// repository named apart and takes it for one that cannot be told.

/** A git command as a `Cmd` carries it: mod-kit's reading (`ModKitGit`), every way it names its repository included. */
export type GitRead = { sub?: string; args: string[]; dir?: string; chained?: string | null; gitDir?: string; workTree?: string }

/** mod-kit's reading of a git command as a `Cmd` carries it, each naming present only where the command gives it. */
export const gitRead = (g: ModKitGit): GitRead => ({
  sub: g.sub,
  args: g.args,
  ...(g.dir !== undefined ? { dir: g.dir } : {}),
  ...(g.chained !== undefined ? { chained: g.chained } : {}),
  ...(g.gitDir !== undefined ? { gitDir: g.gitDir } : {}),
  ...(g.workTree !== undefined ? { workTree: g.workTree } : {}),
})

/** Whether a git command names where it acts at all: a -C, or a repository or a working folder apart. */
export const gitNamesPlace = (g: GitRead): boolean => g.dir !== undefined || g.chained !== undefined || g.gitDir !== undefined || g.workTree !== undefined

/** git's own words before its subcommand, by the split mod-kit's reading made. */
export const gitGlobals = (words: readonly string[], g: { sub?: string; args: readonly string[] }): string[] =>
  g.sub === undefined ? words.slice(1) : words.slice(1, words.length - g.args.length - 1)

// GIT_DIR, GIT_WORK_TREE or GIT_COMMON_DIR given a value anywhere in a call's text (the reading the
// overnight rule has kept since #1124 for a folder that says nothing about where git acts), and one
// of them as a whole word of any command.
const GIT_ENV_SET = /(?:^|[^\w$])GIT_(?:DIR|WORK_TREE|COMMON_DIR)=/
const GIT_ENV_NAME = /^GIT_(?:DIR|WORK_TREE|COMMON_DIR)$/
/**
 * Whether a call names one of them at all: given a value in its text (`GIT_DIR=...` in front of a
 * command, exported, or on a line of its own), or handed whole to a command that can set or export
 * it with no `=` (`export GIT_DIR`, `read GIT_DIR`, `printf -v GIT_DIR`). mod-kit's reader hands on
 * only the setting written in front of the git command itself; any other naming reaches git only
 * through the shell, which no reader here follows, so the repository of every git command in such
 * a call is one that cannot be told. The one predicate every rule here asks, so no two of them
 * part on what names a repository (the overnight rule's temp folder allowances asked a narrower
 * one of their own until the lessons review of #3398).
 */
export const gitEnvNamed = (raw: string, commands: readonly { words: readonly string[] }[]): boolean =>
  GIT_ENV_SET.test(raw) || commands.some(c => c.words.some(w => GIT_ENV_NAME.test(w)))

/** Where a git command acts, as `gitPlace` reads it. */
export type GitPlace = {
  /**
   * The folder git runs in once every -C is followed (mod-kit's `chained`, else its `dir`), read
   * from the folder the command runs in; null where it cannot be followed (a chain mod-kit cannot
   * work out, a value the shell fills in, a cd before it that cannot be followed).
   */
  runs: string | null
  /**
   * Where this mod placed the command until #3398: the last -C alone, read from the folder the
   * command runs in. It is `runs` for every command with one -C or none. A rule that refuses goes
   * on judging it beside `runs`, so nothing refused under the old reading passes on the new one alone.
   */
  asRead: string | null
  /**
   * Set where the repository is not the one around `runs`: what names it apart, in words. With
   * `repository` the command names its repository (--git-dir, GIT_DIR, or a variable the call names
   * some other way), so its branch, index and stash are not that folder's; with it false only the
   * working folder is named apart (--work-tree, GIT_WORK_TREE), so the repository is still the one
   * found from `runs` and only its files land elsewhere.
   */
  apart?: { repository: boolean; said: string }
}

/**
 * Where a git command acts. `from` is the folder the command runs in (null where a cd before it
 * cannot be followed), `resolve` the rule's own resolver of a folder as written, and `envNamed`
 * whether the call names GIT_DIR, GIT_WORK_TREE or GIT_COMMON_DIR anywhere (`gitEnvNamed`), which
 * every caller says: left out, a variable exported earlier in the call would read as no naming.
 */
export const gitPlace = (g: GitRead, from: string | null, resolve: (word: string, from: string | null) => string | null, envNamed: boolean): GitPlace => {
  const asRead = g.dir === undefined ? from : resolve(g.dir, from)
  const runs = g.chained === undefined ? asRead : g.chained === null ? null : resolve(g.chained, from)
  const apart =
    g.gitDir !== undefined
      ? { repository: true, said: 'it names its repository apart from the folder it runs in (--git-dir or GIT_DIR)' }
      : envNamed && g.workTree === undefined
        ? { repository: true, said: 'the call names GIT_DIR, GIT_WORK_TREE or GIT_COMMON_DIR somewhere other than as a setting on the git command itself' }
        : g.workTree !== undefined
          ? { repository: envNamed, said: 'it names its working folder apart from the folder it runs in (--work-tree or GIT_WORK_TREE)' }
          : undefined
  return { runs, asRead, ...(apart ? { apart } : {}) }
}

/**
 * The folder a rule that reads one checkout for a git command reads: where git runs, or null where
 * the repository cannot be told from a folder (it is named apart, or the folder cannot be followed).
 * The strictest reading, for a rule whose null refuses.
 */
export const gitFolder = (p: GitPlace): string | null => (p.apart ? null : p.runs)

/**
 * The folder whose checked out branch a commit or a push naming none is of, for the note kept for
 * winding down (#1074): where git runs, when that is written out in full, and the repository is the
 * one found from it. `untold` where the command names its repository apart, which no folder
 * answers for; `none` where the folder is not written in full (a relative one, a value the shell
 * fills in, a chain mod-kit cannot work out), as a relative -C always was.
 */
export const branchFolder = (g: GitRead | undefined, cwd: string, envNamed: boolean): { path: string } | { untold: string } | 'none' => {
  // A call whose git commands name no folder runs in the session's.
  const p = gitPlace(g ?? { args: [] }, cwd, w => (w.startsWith('/') ? w : null), envNamed)
  if (p.apart?.repository) return { untold: p.apart.said }
  return p.runs === null ? 'none' : { path: p.runs }
}

/**
 * The folder whose checkout a stash or a patch's paths belong to, for the notes kept for winding
 * down (#1123): where git runs, a relative folder read from the session's (a cd earlier in the call
 * is not followed, knowingly loose, as before). Null where it names none: a folder spelled with a
 * value the shell fills in, a chain mod-kit cannot work out, and a repository or a working folder
 * named apart, whose files land where only git can say.
 */
export const checkoutFolder = (g: GitRead, cwd: string, envNamed: boolean): string | null => {
  const p = gitPlace(g, cwd, (w, from) => (/[$`]/.test(w) || from === null ? null : w.startsWith('/') ? w : `${from}/${w}`), envNamed)
  return gitFolder(p)
}
