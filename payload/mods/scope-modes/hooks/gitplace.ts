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
// (`gitRead`); no rule here places a command by an option it read itself. The one word test kept,
// `gitSpellsNaming`, only ever closes a rule that closed on those words before #3398, beside the
// reading and never in place of it. A relative folder is resolved by the resolver the rule
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

/** git's own words before its subcommand, by the split mod-kit's reading made. */
export const gitGlobals = (words: readonly string[], g: { sub?: string; args: readonly string[] }): string[] =>
  g.sub === undefined ? words.slice(1) : words.slice(1, words.length - g.args.length - 1)

// --git-dir or --work-tree as a word of its own before the subcommand, with a value joined to it or
// none, whatever the reader took the word for.
const SPELLS_NAMING = /^--(?:git-dir|work-tree)(?:=|$)/
/**
 * Whether a word before the subcommand spells --git-dir or --work-tree. The reader hands on the
 * two options where git reads them as options; where the word is the value of the option in front
 * of it (`--namespace --git-dir=/o/.git`, `-c --work-tree=/o`, `-C --git-dir`), or has no value
 * after it, the reader names nothing, as git does. The merge and deploy rule read these words
 * itself until #3398 and closed on every one, so it asks this beside the reading and closes still
 * (the review of #3532): a rule that refuses lets nothing through on the new reading alone.
 */
export const gitSpellsNaming = (words: readonly string[], g: { sub?: string; args: readonly string[] }): boolean => gitGlobals(words, g).some(w => SPELLS_NAMING.test(w))

// GIT_DIR, GIT_WORK_TREE or GIT_COMMON_DIR given a value, and one of them as a whole word.
const GIT_ENV_SET = /(?<![\w$])GIT_(?:DIR|WORK_TREE|COMMON_DIR)=/g
const GIT_ENV_NAME = /^GIT_(?:DIR|WORK_TREE|COMMON_DIR)$/
/** How many times a text gives one of them a value. */
const spelled = (text: string): number => text.match(GIT_ENV_SET)?.length ?? 0
/**
 * Whether a call's text gives one of them a value anywhere at all, plain data included: the reading
 * the overnight rule has kept since #1124 for a folder that says nothing about where git acts. Its
 * temp folder allowances ask it beside `gitEnvNamed`, so text that took them away before #3398
 * takes them away still.
 */
export const gitEnvSpelled = (raw: string): boolean => spelled(raw) > 0

/** A command as mod-kit's reader gives it, as far as `gitEnvNamed` reads one. */
export type ReadCmd = {
  words: readonly string[]
  env?: readonly string[]
  substitution?: true
  xargs?: true
  unread?: string
  behind?: readonly string[]
  pipedFrom?: readonly string[]
  git?: { sub?: string; args: readonly string[] }
}

// The words of a command that are plain data, each with its place among the command's words: every
// word of a program that only prints or searches, and the message of a git commit. Nothing else:
// a program left out here is read strictly, which is where every other program stays.
const DATA_PROGRAMS = new Set(['echo', 'printf', 'grep', 'rg'])
const dataWords = (c: ReadCmd): { at: number; text: string }[] => {
  if (DATA_PROGRAMS.has((c.words[0] ?? '').split('/').pop() ?? '')) return c.words.slice(1).map((text, i) => ({ at: i + 1, text }))
  const g = c.git
  if (g?.sub !== 'commit') return []
  const first = c.words.length - g.args.length
  const out: { at: number; text: string }[] = []
  g.args.forEach((a, i) => {
    const value = g.args[i + 1]
    if ((a === '-m' || a === '-am' || a === '--message') && value !== undefined) out.push({ at: first + i + 1, text: value })
    else if (a.startsWith('--message=')) out.push({ at: first + i, text: a.slice('--message='.length) })
  })
  return out
}
// A word that opens a redirect, as the reader hands one on (`>`, `>>`, `2>&1`, `&>`, `<`, `<<EOT`).
const REDIRECT = /^(?:\d*|&)[<>]/
// The word a pipe is fed from when a group or a loop feeds it, whose commands the reader gives apart.
const GROUP_END = new Set(['}', ')', 'done', 'fi', 'esac'])
// Whether anything in the call could carry plain data on to something that sets a variable, or
// change what a word runs: a value the shell fills in ($ or a backtick anywhere in the text, so a
// substitution, a variable, a function's argument), text run as commands (eval, source, `.`, by
// name or behind builtin or command), xargs, a function defined in the call, a command the reader
// could not read (an alias among them), a pipe fed by a group or by a command spelling a variable,
// and any command run behind another (a shell's script, which a pipe may have fed it; env, sudo):
// the reader's own word on those is that a reader needing the plain run takes none of them for it.
// Every pipe in the text must also be one the reader shows a command fed by: text piped into a
// shell is read as that shell's commands, and where it runs none (`echo GIT_DIR=/o | sh`) the
// reader shows no pipe at all.
const carries = (raw: string, commands: readonly ReadCmd[]): boolean =>
  /[$`]/.test(raw) ||
  (raw.replace(/\|\|/g, '').match(/\|/g)?.length ?? 0) !== commands.filter(c => c.pipedFrom !== undefined).length ||
  commands.some(
    c =>
      c.unread !== undefined ||
      c.xargs === true ||
      (c.behind?.length ?? 0) > 0 ||
      c.words[0] === 'function' ||
      (c.words[0] ?? '').endsWith('()') ||
      c.words.slice(0, 2).some(w => w === 'eval' || w === 'source' || w === '.') ||
      (c.pipedFrom !== undefined && (GROUP_END.has(c.pipedFrom[0] ?? '') || c.pipedFrom.some(w => spelled(w) > 0))),
  )
/**
 * Whether a call names one of them at all. mod-kit's reader hands on only the setting written in
 * front of the git command itself; any other naming reaches git only through the shell, which no
 * reader here follows, so the repository of every git command in such a call is one that cannot be
 * told. The one predicate every rule here asks, so no two of them part on what names a repository.
 *
 * A call names one when any of these holds:
 * - one is a whole word of any command (`export GIT_DIR`, `read GIT_DIR`, `printf -v GIT_DIR`);
 * - a setting in front of any command, or a word of any command that is not plain data, gives one a
 *   value, as the reader hands the word on (so `export GIT_"DIR=/o"` too, which the text never
 *   holds whole);
 * - the call's text gives one a value anywhere the reader's plain data does not account for: a
 *   line of its own, a here document's body, a comment, anything the reader hands on to no command.
 *
 * Until the review of #3532 the third was the whole test, over the text alone, so a commit message
 * quoting `GIT_DIR=` closed the merge rule on the push behind it and dropped every note. Plain data
 * is only what `dataWords` lists, only in a command that sends it nowhere (no redirect, not inside
 * a substitution), and only in a call where nothing could carry it on (`carries`). Each such word
 * must stand in the text exactly as the reader hands it on, as often as the reader found it, and
 * together they must account for every time the text gives a variable a value. Where any of that
 * cannot be said, the text is believed, as before.
 */
export const gitEnvNamed = (raw: string, commands: readonly ReadCmd[]): boolean => {
  if (commands.some(c => c.words.some(w => GIT_ENV_NAME.test(w)))) return true
  const carried = carries(raw, commands)
  const plain: string[] = []
  for (const c of commands) {
    if (c.env?.some(e => spelled(e) > 0)) return true
    const data = carried || c.substitution || c.words.some(w => REDIRECT.test(w)) ? [] : dataWords(c)
    const at = new Set(data.map(d => d.at))
    if (c.words.some((w, i) => !at.has(i) && spelled(w) > 0)) return true
    plain.push(...data.map(d => d.text).filter(t => spelled(t) > 0))
  }
  const inText = spelled(raw)
  if (inText === 0) return false
  let accounted = 0
  for (const text of new Set(plain)) {
    const words = plain.filter(p => p === text).length
    if (raw.split(text).length - 1 !== words) return true
    accounted += words * spelled(text)
  }
  return inText !== accounted
}

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
 * fills in, a chain mod-kit cannot work out), as a relative -C always was. Asked of the command
 * that commits or pushes itself, never of another git command in the call.
 */
export const branchFolder = (g: GitRead, cwd: string, envNamed: boolean): { path: string } | { untold: string } | 'none' => {
  // A command naming no folder runs in the session's.
  const p = gitPlace(g, cwd, w => (w.startsWith('/') ? w : null), envNamed)
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
