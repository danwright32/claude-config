// The area check (claude-config#1506; facts #1508, hold #1509): the facts about a file at the
// moment a session first edits it. Pure, so each rule is tested on its own, and so the replay of a
// real repository's history (tools/area-check-replay.ts) judges with exactly these rules (L107).
// The facts decide a verdict, `would_hold` or `quiet` (Judged.decision). Phase 1 only logged it; #1509
// set the bar below from that week's log on both Macs, and a `would_hold` verdict is now a HELD edit
// (the Held record below) that is refused until the session decides.
import type { ModKitWrites } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { isTestPath } from './mod-kit/testfile.ts'

/** Bumped whenever a rule here changes what a file's facts are, so a cached ranking is never reused across it (L573). */
export const RULE_VERSION = 2
/** Claude Code's budget for a hook, measured at 10 s (docs/mods-design.md, standing rule 4). */
export const BUDGET_MS = 10_000
/** One deadline for the whole read of a file's facts, under 75% of the budget (L743). */
export const DEADLINE_MS = 7_000
/**
 * The most files a folder a command writes may hold that the area check could hold, for each to be
 * judged one by one: a write marked as reaching the whole folder (find with exec, git putting a folder
 * back, #2373) or a folder named only by its path (a folder handed to a script, or a copy's folder
 * destination, #2321). Past it the command is held whole, as a write whose files cannot be named. Each file judged runs two git
 * processes (about 10 ms each, measured 2026-11-06), and a whole checkout here holds 1075 source files,
 * so an unbounded walk would outrun the hook's 10 s budget: 25 keeps the walk near a second under load.
 */
export const FOLDER_JUDGE_MAX = 25
/** How long a repository's open issues are reused before they are read again. */
export const ISSUES_TTL_MS = 60 * 60_000
/** How long a failed read is reused, so each edit does not pay for it again. */
export const UNREAD_TTL_MS = 10 * 60_000
/** The most open issues read in one list: a list this long may have been cut, so it is TRUNCATED. */
export const ISSUE_LIMIT = 1000
/** The growth window, in days. */
export const GROWTH_DAYS = 90
/**
 * The bar (decisions 4 and 6), set on 2026-11-02 from the week of phase 1 logs on both Macs (#1509;
 * the numbers, and where each threshold lands in what the week judged, are in docs/mods-design.md
 * under the area check, L172). Growth: files of at least SIZE_MIN lines that grew by at least
 * GROWTH_MIN net lines in 90 days, the TOP_N fastest of them, source and tests ranked together
 * (decision 6 asks for about the 10 fastest growing large files per repository). Issues: those
 * naming files in the same folder count only when the folder has at most FOLDER_MAX, down from the
 * provisional 5, since folder matches were 612 of the 982 issue holds on the work MacBook; and only
 * an issue at one of HOLD_PRIORITIES holds, since p3 and p4 issues were 59% of the issues shown
 * on the work MacBook and 91% on the personal one.
 */
export const SIZE_MIN = 1500
export const GROWTH_MIN = 300
export const TOP_N = 10
export const FOLDER_MAX = 2
export const HOLD_PRIORITIES: readonly string[] = ['p0', 'p1', 'p2']
/** A repository's bar, with the day it was set, so a record can say which bar judged it. */
export type Bar = { set: string; sizeMin: number; growthMin: number; topN: number; folderMax: number; holdPriorities: readonly string[] }
export const DEFAULT_BAR: Bar = { set: '2026-11-02', sizeMin: SIZE_MIN, growthMin: GROWTH_MIN, topN: TOP_N, folderMax: FOLDER_MAX, holdPriorities: HOLD_PRIORITIES }
/**
 * A bar of its own for a repository the week measured as needing one, keyed by the repository's name
 * alone, lower case, since a work repository's owner does not belong in this public one. None today:
 * the four repositories the week judged most (three on the work MacBook, this one on the personal)
 * each held at most 3 files a session by the default growth bar, so none needed a different one.
 */
export const BARS: Readonly<Record<string, Bar>> = {}
/** The bar a repository (owner/name) is judged by: its own, else the default. */
export const barFor = (repo: string, bars: Readonly<Record<string, Bar>> = BARS): Bar =>
  bars[(repo.split('/').pop() ?? repo).toLowerCase()] ?? DEFAULT_BAR

/**
 * The structural label spellings, matched whole (L1023), measured 2026-10-22 across the 12 repo-digest
 * repositories and this one (L564): tech-debt in all 13, refactor in four, test-refactor in one.
 * Near spellings seen and deliberately left out, since Dan's decision 4 names tech-debt and refactor:
 * cleanup, consolidation, architecture, maintainability, hygiene, structure.
 */
export const STRUCTURAL_LABELS: readonly string[] = ['tech-debt', 'refactor', 'test-refactor']

/**
 * What counts as source (decision 3). test-match-open-issues-paths.sh holds every one of these to the
 * shared path reader's list, so an issue can always name such a file.
 */
export const SOURCE_EXTENSIONS: readonly string[] = ['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'py', 'sh', 'swift', 'rb', 'go', 'rs', 'java', 'kt', 'kts', 'vue', 'svelte', 'php', 'cs', 'cpp', 'c', 'h', 'm', 'css', 'scss']

/** The edit tools, each by the input key carrying its file (decision 2); a shell write is read by shellTargets below (#2142). */
const PATH_KEY: Readonly<Record<string, string>> = { Edit: 'file_path', Write: 'file_path', MultiEdit: 'file_path', NotebookEdit: 'notebook_path' }

/** The absolute path an edit tool's call writes, or null for any other tool or a path that is not absolute. */
export const editedPath = (tool: string, input: Record<string, unknown>): string | null => {
  const key = PATH_KEY[tool]
  const p = key ? input[key] : undefined
  return typeof p === 'string' && p.startsWith('/') ? p : null
}

/**
 * A file a Bash command writes (#2142), read from mod-kit's one reader of a command ($.modkit.writes):
 * a path, judged as that file's first edit would be (`tree` where the write may reach every file
 * under it, so each one there that could be held is judged too, `heldUnder` choosing them; a path
 * without `tree` that the disk says is a folder is judged the same way, #2321; either way at most
 * FOLDER_JUDGE_MAX files one by one, #2373), or a write whose file cannot be named, with why, which
 * is held unless nothing in the repository could hold it.
 * `folder` is where such a write lands when the reader knows it, so its checkout is the one judged.
 * `runs` is every script a path was handed to, present only when that is the command's one way of
 * reaching it (#2407): a folder handed to scripts is judged for the files under it unless every one
 * of them is read as writing nothing there (scriptProgram, scriptWrite; #2426 lessons review).
 */
export type ShellTarget = { word: string; path: string; tree?: true; runs?: ShellRun[] } | { word: string; unread: string; folder?: string }

const literalExt = (word: string): string | undefined => /\.([A-Za-z0-9]+)$/.exec(word.slice(word.lastIndexOf('/') + 1))?.[1]?.toLowerCase()
// A name whose extension is written out and is no source one is never judged, whatever its folder is.
const mayBeSource = (word: string) => {
  const ext = literalExt(word)
  return ext === undefined || SOURCE_EXTENSIONS.includes(ext)
}

type ModKitRun = NonNullable<ModKitWrites['runs']>[number]

/** The script a path was handed to, as mod-kit named the run (#2407). */
export type ShellRun = { what: string; path?: string; tool?: true }

const PLAIN_NAME = /^[A-Za-z0-9._+-]+$/

/**
 * The command that feeds a script file's text to its interpreter on standard input (#2407), so
 * mod-kit's one reader of what a command writes reads the script as the program it runs: a shell's
 * script as the commands it runs, another language's as code its judge reads. The interpreter is the
 * one mod-kit named the run by (`a bash script file`), or, for a script run directly, its first
 * line's `#!`, through env where it names env; the `#!` line is a comment to every interpreter that
 * runs the file, and is not fed. A module or tool, a script run directly with no `#!`, or an
 * interpreter that is not one plain name is `unread`, with why. The delimiter is one the text does
 * not hold. Whether mod-kit could read the program at all is readAsProgram's question.
 */
export const scriptProgram = (run: ShellRun, text: string): { command: string; name: string; delimiter: string } | { unread: string } => {
  if (run.tool) return { unread: `${run.what} is no file that can be read` }
  const first = text.startsWith('#!') ? (text.split('\n', 1)[0] as string) : undefined
  let name = /^a (\S+) script file$/.exec(run.what)?.[1]
  if (name === undefined && run.what === 'a script file run directly') {
    if (first === undefined) return { unread: 'it is run directly with no #! line naming what runs it' }
    const words = first.slice(2).trim().split(/\s+/)
    const base = (w: string | undefined) => (w ?? '').slice((w ?? '').lastIndexOf('/') + 1)
    name = base(words[0])
    if (name === 'env') name = base(words.slice(1).find(w => !w.startsWith('-') && !w.includes('=')))
  }
  if (!name || !PLAIN_NAME.test(name)) return { unread: `what runs it (${name || run.what}) cannot be told` }
  const body = first === undefined ? text : text.slice(first.length + 1)
  let delimiter = 'AREA_CHECK_SCRIPT'
  for (let n = 1; body.includes(delimiter); n++) delimiter = `AREA_CHECK_SCRIPT_${n}`
  return { command: `${name} <<'${delimiter}'\n${body}\n${delimiter}`, name, delimiter }
}

const SOURCES = new Set(['source', '.'])
// A word that only sets a variable, though the reader gives it as a command: an array's element
// (`seen[$f]=1`) or an append (`list+=("$f")`), which its own test for an assignment does not match.
const SETS = /^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/

type ReadCommand = { words: readonly string[]; program?: unknown; script?: { files: readonly string[]; stdin?: true } }

/**
 * The commands that are the words of an arithmetic command (#2619), by their place: mod-kit's reader
 * gives `(( $# < 1 ))` as two `(` commands, the expression's words as commands (`$#` `<` `1`, split
 * at any `&&` or `||`), and two `)` commands, so a value there reads as a command named by a value
 * though it names none. Only that exact shape counts: two `(` in a row, no parenthesis between, and
 * two `)` in a row closing them, in a text that holds `((` at all. Two subshells with nothing else
 * inside the outer one (`( ( "$TOOL" x ) )`) give the same commands, so in a script that also holds
 * a `((` somewhere they read as arithmetic too, as they read as no write before #2619; any other
 * nesting, and every script holding no `((`, is read as the commands it runs.
 */
const inArithmetic = (commands: readonly ReadCommand[], text: string): Set<number> => {
  const is = (i: number, paren: string) => commands[i]?.words.length === 1 && commands[i]?.words[0] === paren
  const found = new Set<number>()
  if (!text.includes('((')) return found
  for (let i = 0; i + 1 < commands.length; i++) {
    if (!is(i, '(') || !is(i + 1, '(')) continue
    let j = i + 2
    while (j < commands.length && !is(j, '(') && !is(j, ')')) j++
    if (is(j, ')') && is(j + 1, ')')) for (let k = i + 2; k < j; k++) found.add(k)
  }
  return found
}

/**
 * Why the commands mod-kit's pipeline gives for the command scriptProgram built leave what the script
 * writes unread (#2407), or null. A shell's script comes back as the commands it runs, another
 * language's as the command carrying its program's text; a command still holding the heredoc's word
 * with no program text is an interpreter mod-kit does not read. And a script it runs in turn, by an
 * interpreter, by its path or through source, writes what no word names, which mod-kit's writes give
 * only for one handed arguments, so each is named here. A program run by its bare name (make, npm) is
 * read as the area check reads the same command typed on its own.
 *
 * And text the reader does not read as commands (#2619; each measured on 2026-11-10 to give no
 * write, so a script writing through one was read as writing nothing and the folder it was handed
 * went unjudged): what eval runs; what an alias makes a later word run; and a command named by a
 * value (`"$TOOL" --write "$1"`, `$(command -v fixer) "$1"`, `"$@"`, and `bash -c "$FIX"`, which the
 * reader gives as the command `$FIX`). A word that only sets a variable names no command, nor does
 * a value inside arithmetic (inArithmetic, told from `source`, the text the commands were read
 * from; with none given nothing is arithmetic). A trap's text is the caller's to read (trapTexts).
 */
export const unreadPart = (commands: readonly ReadCommand[], delimiter: string, source = ''): string | null => {
  const arithmetic = inArithmetic(commands, source)
  for (const [i, c] of commands.entries()) {
    // `builtin eval "$FIX"` runs eval: the reader does not look past `builtin`, so it is looked past here.
    const words = c.words[0] === 'builtin' ? c.words.slice(1) : c.words
    const head = words[0] ?? ''
    const text = typeof c.program === 'object' && c.program !== null && 'text' in c.program
    if (c.words.some(w => w.includes(delimiter)) && !text) return `${head} is no interpreter whose program mod-kit reads`
    if (c.script && !c.script.stdin) return `it runs the script ${c.script.files[0] ?? head}, whose writes are not read`
    if (head.includes('/') || (SOURCES.has(head) && words.length > 1)) return `it runs ${SOURCES.has(head) ? words[1] : head}, whose writes are not read`
    if (head === 'eval') return 'it runs text through eval, whose writes are not read'
    if (head === 'alias' && words.some(w => w.includes('='))) return `it sets an alias (${words.find(w => w.includes('='))}), so what a later word runs is not read`
    if (/[$`]/.test(head) && !SETS.test(head) && !arithmetic.has(i)) return `it runs ${head}, which cannot be named before it runs`
  }
  return null
}

/**
 * The text each trap a script sets would run (#2619), once each: `trap 'echo x > "$1/big.ts"' EXIT`
 * reaches the reader as a trap command whose first word is that text, which it reads as no command,
 * so a write in it was no write. The caller reads each text as the commands it is, with the same
 * reader and the same rules as the script's own. A trap that lists (`trap`, `-p`, `-l`), resets
 * (`trap - EXIT`) or ignores (`trap '' HUP`) runs nothing.
 */
export const trapTexts = (commands: readonly { words: readonly string[] }[]): string[] => {
  const texts = new Set<string>()
  for (const c of commands) {
    if (c.words[0] !== 'trap') continue
    const text = c.words[c.words[1] === '--' ? 2 : 1]
    if (text !== undefined && text.trim() !== '' && !text.startsWith('-')) texts.add(text)
  }
  return [...texts]
}

/**
 * Why a script, its writes read by mod-kit from its own text (#2407), may write into a folder it is
 * handed, or null when it writes nothing the area check could judge. Any file it writes, named or
 * not, wherever it lands, and any script it runs in turn, whose writes are not read, counts: only a
 * script whose text writes no such file at all lets the folder it is handed go unjudged, so a script
 * whose writes cannot be placed is held, never passed.
 */
export const scriptWrite = (w: ModKitWrites, home?: string): string | null => {
  const run = w.runs?.[0]
  if (run) return `it runs ${run.what} (${run.script}), whose writes are not read`
  const t = shellTargets(w, home)[0]
  if (!t) return null
  return 'path' in t ? `it writes ${t.word}` : `it writes ${t.word}: ${t.unread}`
}

/**
 * Whether a run is a findings note to the installed spool helper (#2254):
 * `bash ~/.claude/hooks/lib/issue-spool.sh note . "<finding>" "<who>"`, or the helper run directly.
 * Its note writes one record under ~/.claude-issue-spool and nothing in any repository, so its words,
 * a finding that often holds $ or *, are no files it writes. Only that path under the home given and
 * only its note subcommand: a copy of the helper elsewhere may be any script, and without a home
 * nothing is let off. Any substitution inside the note, and every other part of the command, is read
 * by mod-kit as its own write and judged as before.
 */
const installedSpool = (r: ModKitRun, home: string | undefined): boolean =>
  home !== undefined &&
  (r.what === 'a bash script file' || r.what === 'a script file run directly') &&
  r.path === `${home}/.claude/hooks/lib/issue-spool.sh`

const spoolNote = (r: ModKitRun, home: string | undefined): boolean => installedSpool(r, home) && r.args[0]?.word === 'note'

/**
 * The installed spool helper's subcommands whose first argument is the project folder its spool key
 * is read from (#2636): the helper reads that folder's git common dir, or resolves it with cd and
 * pwd, and writes only under its spool root, so the folder is never a place it writes. Each one is a
 * line of the helper's dispatch handing `"${1:-$PWD}"` on as that folder, and
 * tests/test-area-check-spool-key-only.sh holds this list to those lines and runs every one against
 * a throwaway checkout, red when one leaves a file there changed or new. Its other arguments (a
 * transcript, a stamp it writes) are judged as any script's are; a subcommand handed some other
 * folder (sweep-stamps, keep-ledgers, which take the review's temp folder) is not in the list.
 */
export const SPOOL_KEY_COMMANDS: readonly string[] = [
  'key', 'read-keys', 'path', 'archive-path', 'append', 'note', 'raw', 'pending', 'has-findings', 'archive',
  'clear', 'file-errors', 'file-muted', 'muted-summary', 'muted-stamp', 'muted-sent',
]

// Whether a run's first argument after the subcommand is only the project a spool key is read from.
const spoolKeyOnly = (r: ModKitRun, home: string | undefined): boolean =>
  installedSpool(r, home) && SPOOL_KEY_COMMANDS.includes(r.args[0]?.word ?? '')

/**
 * The one file a quoted pattern handed to a script file names (#2255), or undefined. mod-kit marks an
 * argument `quoted` when every pattern character in it is quoted or after a backslash and nothing in it
 * is expanded, so the shell matched it against no file and the script is handed its characters as
 * written: a probe's search text, a regex, a finding. It is judged as the one file those characters
 * name, as every other word a script is handed is (#1586), and as the design round guard reads it
 * (#1951); what a script then matches with it is its own choice, unread, as with a folder it is handed,
 * which is judged for the files it holds (#2321). Only a script file: a tool expands its own operands (#1815). Never a
 * group (`{a,b}`), which names several files, nor a pattern character before the last slash, where the
 * folder mod-kit gives is not the one the name sits in. Anything else stays a pattern.
 */
const quotedName = (r: ModKitRun, a: ModKitRun['args'][number]): string | undefined => {
  if (!a.quoted || !a.folder || r.tool) return undefined
  const cut = a.word.lastIndexOf('/')
  if (/[{}]/.test(a.word) || /[*?[\]]/.test(a.word.slice(0, Math.max(cut, 0)))) return undefined
  return `${a.folder.replace(/\/+$/, '')}/${a.word.slice(cut + 1)}`
}

/**
 * Every file a command writes that could add lines to a source or test file: a redirect, a copy or an
 * in place edit (`files`), an emptying (`changes` truncate), git writing a path (`byGit` write), a
 * script's arguments (`runs`), and a program's own targets (`unnamed`). A removal, a stamp, a new
 * folder and a mode change add no lines, so they are not judged. A folder handed to a script, or a copy
 * landing in a folder, is given here by its path like a file; the hook finds on the disk that it is a
 * folder and judges the files under it (#2321), since no answer here says so.
 * Nor are the words of a findings note (#2254), given `home`: see spoolNote; nor the project folder
 * the installed spool helper reads a key from (#2636): see SPOOL_KEY_COMMANDS. A quoted pattern handed to
 * a script file is judged as the one file its characters name (#2255): see quotedName. A word handed
 * to a script that mod-kit marks `unexpanded` holds no value, so it is never read as built while the
 * command runs: every $ in it is in single quotes or after a backslash (#1953), or one the shell leaves
 * as written, as in a double quoted regex "^foo.*bar$" (#2320). mod-kit names the file such a word
 * spells (#2402: "src/big.ts$"), which is judged as any path is; one also holding a pattern
 * character it names by no path, and that is not judged.
 */
export const shellTargets = (w: ModKitWrites, home?: string): ShellTarget[] => {
  const out: ShellTarget[] = []
  const seen = new Map<string, ShellTarget>()
  const add = (t: ShellTarget) => {
    const k = 'path' in t ? `p\n${t.path}` : `u\n${t.word}`
    const had = seen.get(k)
    // One path reached twice is judged by what both routes may do, so a merge only ever narrows the
    // exemption (#2426 lessons review): a path the command also writes itself is that write, not only a
    // word a script is handed (#2407); a path handed to two scripts keeps both, each to be read; and a
    // write reaching the whole folder keeps that reach.
    if (had) {
      if (!('path' in had) || !('path' in t)) return
      if (t.tree) had.tree = true
      if (!had.runs || !t.runs) delete had.runs
      else for (const r of t.runs) if (!had.runs.some(h => h.what === r.what && h.path === r.path && h.tool === r.tool)) had.runs.push(r)
      return
    }
    seen.set(k, t)
    out.push(t)
  }
  const named = (word: string, path: string | undefined, folder: string | undefined, why: string, tree?: true) => {
    if (path) return add({ word, path, ...(tree ? { tree } : {}) })
    if (!mayBeSource(word)) return
    add(folder ? { word, unread: `${word} is a pattern, matched only as it runs`, folder } : { word, unread: why })
  }
  for (const f of w.files) named(f.word, f.path, f.folder, `${f.word} is built as the command runs`, f.tree)
  for (const c of w.changes) if (c.does === 'truncate') named(c.word, c.path, c.folder, `${c.word} is built as the command runs`, c.tree)
  for (const g of w.byGit ?? []) {
    if (g.does !== 'write') continue
    // A path with no extension git may fill is a folder: everything under it can be put back.
    if (g.path && g.tree && literalExt(g.path) === undefined) add({ word: g.word, unread: `git writes ${g.word}, which reaches a whole folder` })
    else named(g.word, g.path, undefined, `git matches ${g.word} across folders`, g.tree)
  }
  for (const r of w.runs ?? []) {
    if (spoolNote(r, home)) continue
    const run: ShellRun = { what: r.what, ...(r.path ? { path: r.path } : {}), ...(r.tool ? { tool: true as const } : {}) }
    const keyOnly = spoolKeyOnly(r, home)
    for (const [i, a] of r.args.entries()) {
      if (keyOnly && i === 1) continue
      const literal = a.path ? undefined : quotedName(r, a)
      if (a.path) add({ word: a.word, path: a.path, runs: [run] })
      else if (literal) add({ word: a.word, path: literal })
      else if (a.folder) {
        if (mayBeSource(a.word)) add({ word: a.word, unread: `${a.word} is a pattern handed to ${r.what}`, folder: a.folder })
      } else if (mayBeSource(a.word) && !a.unexpanded) add({ word: a.word, unread: `${r.what} is handed ${a.word}, built as the command runs` })
    }
  }
  for (const u of w.unnamed) {
    const targets = (u.targets ?? []).filter(t => t.startsWith('/'))
    if (targets.length && targets.length === (u.targets ?? []).length) for (const t of targets) add({ word: t, path: t })
    else add({ word: u.words.join(' '), unread: `${u.what} writes files its words do not name`, ...(u.folder ? { folder: u.folder } : {}) })
  }
  return out
}

/**
 * Whether anything in a repository could hold a file (#2142): a fast growing file, or an open
 * structural issue at a held priority naming a file that the session does not work on. A write whose
 * file cannot be named passes only where this is false, since no file there could be held.
 */
export const couldHold = (f: { issues: readonly CachedIssue[]; own: readonly number[]; top: readonly string[]; bar?: Bar }): boolean => {
  const bar = f.bar ?? DEFAULT_BAR
  return f.top.length > 0 || f.issues.some(i => i.structural.length > 0 && i.refs.length > 0 && !f.own.includes(i.n) && bar.holdPriorities.includes(i.priority ?? 'p2'))
}

/**
 * A command's own key, so its unchanged resend after a decision runs and any other command is judged:
 * a full SHA-256 of its whole text, since a short hash lets another command sharing it pass unjudged
 * (#2142 lessons review: two commands differing in one number shared the 32 bit one first used).
 */
export const shellKey = async (command: string): Promise<string> => `shell:${await sha256(command)}`

/** The SHA-256 of a text as 64 hex digits, the one hash every key here is made with. */
const sha256 = async (text: string): Promise<string> => {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')
}

const GENERATED_PARTS = new Set(['node_modules', 'dist', 'build', 'out', '.next', 'vendor', '__generated__', 'generated', 'Generated'])
const MIGRATION_PARTS = new Set(['migrations', 'migration'])

/** Whether a path inside its checkout is a judged source file, a judged test file, or neither (decision 3). */
export const fileKind = (rel: string): 'source' | 'test' | null => {
  const parts = rel.split('/').filter(Boolean)
  const base = parts[parts.length - 1] ?? ''
  const ext = /\.([A-Za-z0-9]+)$/.exec(base)?.[1]?.toLowerCase()
  if (!ext || !SOURCE_EXTENSIONS.includes(ext)) return null
  if (parts.slice(0, -1).some(p => GENERATED_PARTS.has(p) || MIGRATION_PARTS.has(p))) return null
  if (/\.d\.[mc]?ts$/i.test(base) || /\.generated\./i.test(base) || /\.min\.(js|css)$/i.test(base)) return null
  // Configuration in a source language: tailwind.config.ts, eslint.config.js, .eslintrc.js.
  if (/(^|\.)config\.[mc]?[jt]s$/i.test(base) || /^\.[a-z]+rc\.[a-z]+$/i.test(base)) return null
  return isTestPath(rel) ? 'test' : 'source'
}

/** An issue's labels read as the area check needs them: its structural spellings, and its priority. */
export const labelFacts = (labels: readonly string[]): { structural: string[]; priority: string | null } => {
  const lower = labels.map(l => l.toLowerCase())
  const priority = lower.map(l => /^priority-(p[0-4])$/.exec(l)?.[1]).find(p => p !== undefined) ?? null
  return { structural: STRUCTURAL_LABELS.filter(s => lower.includes(s)), priority }
}

/** One open issue as the cache keeps it: its number, structural labels, priority and the paths it names. */
export type CachedIssue = { n: number; structural: string[]; priority: string | null; refs: string[] }
/** One issue in gh's list, its labels by name. */
export type IssueRow = { number: number; title: string; body: string; labels: string[] }
export type IssuesRead = { state: 'read' | 'truncated'; rows: IssueRow[] } | { state: 'unread'; why: string }

/** gh's open issue list read: UNREAD when it is not a list, TRUNCATED when it fills the limit. */
export const issuesRead = (stdout: string): IssuesRead => {
  const bad = { state: 'unread' as const, why: 'gh answered with something that is not an issue list' }
  let parsed: unknown
  try {
    parsed = JSON.parse(stdout)
  } catch {
    return bad
  }
  if (!Array.isArray(parsed)) return bad
  const rows: IssueRow[] = []
  for (const r of parsed as Record<string, unknown>[]) {
    if (!r || typeof r !== 'object' || typeof r.number !== 'number') return bad
    const labels = Array.isArray(r.labels) ? (r.labels as { name?: unknown }[]).map(l => String(l?.name ?? '')).filter(Boolean) : []
    rows.push({ number: r.number, title: typeof r.title === 'string' ? r.title : '', body: typeof r.body === 'string' ? r.body : '', labels })
  }
  return { state: rows.length >= ISSUE_LIMIT ? 'truncated' : 'read', rows }
}

/** The cache's issues: each row with the paths the shared reader found in it (none when it found none). */
export const toCached = (rows: readonly IssueRow[], refs: Readonly<Record<string, string[]>>): CachedIssue[] =>
  rows.map(r => ({ n: r.number, ...labelFacts(r.labels), refs: refs[String(r.number)] ?? [] }))

export type MatchHow = 'path' | 'suffix' | 'basename' | 'folder'
export type Match = { n: number; how: MatchHow; structural: string[]; priority: string | null }

const baseOf = (p: string) => p.slice(p.lastIndexOf('/') + 1)
const dirOf = (p: string) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '')
const indexes = new WeakMap<readonly string[], Map<string, string[]>>()
const indexOf = (tracked: readonly string[]): Map<string, string[]> => {
  let ix = indexes.get(tracked)
  if (ix) return ix
  ix = new Map()
  for (const p of tracked) {
    const b = baseOf(p)
    const at = ix.get(b)
    if (at) at.push(p)
    else ix.set(b, [p])
  }
  indexes.set(tracked, ix)
  return ix
}

/**
 * The open issues naming a file (decision 4): by its full repository relative path; by a partial
 * suffix on path segment boundaries when only one tracked file ends so; by a bare basename when only
 * one tracked file has it. The paths are the shared reader's, which reads each whole, so lib/foo.ts
 * never stands for lib/foo.tsx or otherlib/foo.ts (L1023). Then issues naming files in the same folder,
 * when that folder has at most `folderMax` issues naming its files. Every issue is matched, labelled or
 * not; `structural` tells them apart.
 */
export const issuesNaming = (rel: string, issues: readonly CachedIssue[], tracked: readonly string[], folderMax: number = FOLDER_MAX): Match[] => {
  const ix = indexOf(tracked)
  const resolved = new Map<string, string | null>()
  const resolve = (ref: string): string | null => {
    if (ref === rel) return rel
    const had = resolved.get(ref)
    if (had !== undefined) return had
    const cands = new Set((ix.get(baseOf(ref)) ?? []).filter(p => p === ref || p.endsWith('/' + ref)))
    if (baseOf(rel) === baseOf(ref) && (rel === ref || rel.endsWith('/' + ref))) cands.add(rel)
    const one = cands.size === 1 ? ([...cands][0] as string) : null
    resolved.set(ref, one)
    return one
  }
  const fact = (i: CachedIssue, how: MatchHow): Match => ({ n: i.n, how, structural: i.structural, priority: i.priority })
  const exact: Match[] = []
  const folder: CachedIssue[] = []
  const dir = dirOf(rel)
  for (const i of issues) {
    const own = i.refs.find(r => resolve(r) === rel)
    if (own !== undefined) exact.push(fact(i, own === rel ? 'path' : own.includes('/') ? 'suffix' : 'basename'))
    if (i.refs.some(r => {
      const p = resolve(r)
      return p !== null && dirOf(p) === dir
    })) folder.push(i)
  }
  if (folder.length > folderMax) return exact
  const named = new Set(exact.map(m => m.n))
  return [...exact, ...folder.filter(i => !named.has(i.n)).map(i => fact(i, 'folder'))]
}

/**
 * The files under a folder a write reaching all of it could add lines to that the area check could
 * hold (#2142 lessons review): each tracked source or test file below `folder` ('' for the whole
 * checkout) that is growing fast, that a structural issue names as `issuesNaming` resolves a name,
 * or that sits in a folder a structural issue names a file in. Each is then judged as its first edit
 * would be, so this only chooses which files are asked about, and errs toward asking.
 */
export const heldUnder = (folder: string, f: { tracked: readonly string[]; top: readonly string[]; issues: readonly CachedIssue[] }): string[] => {
  const prefix = folder.replace(/\/+$/, '')
  const ix = indexOf(f.tracked)
  const named = new Set<string>()
  for (const i of f.issues) {
    if (!i.structural.length) continue
    for (const r of i.refs) {
      const cands = (ix.get(baseOf(r)) ?? []).filter(p => p === r || p.endsWith('/' + r))
      if (cands.length === 1) named.add(cands[0] as string)
    }
  }
  const dirs = new Set([...named].map(dirOf))
  return f.tracked.filter(p => (prefix === '' || p.startsWith(`${prefix}/`)) && fileKind(p) !== null && (f.top.includes(p) || named.has(p) || dirs.has(dirOf(p))))
}

/** The issues a session's /goal names, as #N (decision 5). */
export const goalIssues = (condition: string): number[] => [...condition.matchAll(/#(\d+)\b/g)].map(m => Number(m[1]))

export type Growth = { net: number; fixes: number }

const renamed = (p: string): [string, string] | null => {
  const brace = /^(.*)\{(.*) => (.*)\}(.*)$/.exec(p)
  if (brace) {
    const [, pre = '', a = '', b = '', post = ''] = brace
    const tidy = (s: string) => s.replace(/\/\/+/g, '/').replace(/^\//, '')
    return [tidy(pre + a + post), tidy(pre + b + post)]
  }
  const whole = /^(.*) => (.*)$/.exec(p)
  return whole ? [whole[1] as string, whole[2] as string] : null
}

const FIX_TITLE = /\bfix(?:e[sd])?\b/i

/**
 * Growth over `git log --numstat -M --format=%x1e%s`, newest commit first: net lines per file, each
 * rename followed to the file's current name, binary rows skipped, and how many commits touching it
 * have a fix TITLE (rough, L801: about half of fix titles in one repo were features).
 */
export const parseNumstat = (text: string): Record<string, Growth> => {
  const growth: Record<string, Growth> = {}
  const alias: Record<string, string> = {}
  for (const rec of text.split('\x1e')) {
    if (!rec.trim()) continue
    const lines = rec.split('\n')
    const isFix = FIX_TITLE.test(lines[0] ?? '')
    const touched = new Set<string>()
    for (const line of lines.slice(1)) {
      const m = /^(\d+|-)\t(\d+|-)\t(.+)$/.exec(line)
      if (!m) continue
      const [, add = '-', del = '-', p = ''] = m
      const r = renamed(p)
      let at: string
      if (r) {
        at = alias[r[1]] ?? r[1]
        alias[r[0]] = at
      } else at = alias[p] ?? p
      if (add === '-' || del === '-') continue
      const g = (growth[at] ??= { net: 0, fixes: 0 })
      g.net += Number(add) - Number(del)
      if (isFix && !touched.has(at)) g.fixes += 1
      touched.add(at)
    }
  }
  return growth
}

export type FileGrowth = { net: number; size: number | null; fixes: number; rank: number | null }
export type Ranked = { top: string[]; facts: Record<string, FileGrowth> }

/**
 * The growth bar (decision 6): files of at least SIZE_MIN lines that grew by at least GROWTH_MIN net
 * lines in the window, ranked by growth; the first TOP_N cross it. Every file's facts are kept, its
 * rank null when it is not eligible, so the log carries the rough growth line for any file.
 */
export const rank = (growth: Readonly<Record<string, Growth>>, sizes: Readonly<Record<string, number>>, bar: Bar = DEFAULT_BAR): Ranked => {
  const eligible = Object.keys(growth)
    .filter(p => (sizes[p] ?? 0) >= bar.sizeMin && (growth[p]?.net ?? 0) >= bar.growthMin)
    .sort((a, b) => (growth[b]?.net ?? 0) - (growth[a]?.net ?? 0) || (a < b ? -1 : 1))
  const facts: Record<string, FileGrowth> = {}
  for (const [p, g] of Object.entries(growth)) facts[p] = { net: g.net, size: sizes[p] ?? null, fixes: g.fixes, rank: null }
  eligible.forEach((p, i) => {
    const f = facts[p]
    if (f) f.rank = i + 1
  })
  return { top: eligible.slice(0, bar.topN), facts }
}

/** The files whose size the bar needs: those that grew enough to be eligible. */
export const sizeCandidates = (growth: Readonly<Record<string, Growth>>, bar: Bar = DEFAULT_BAR): string[] =>
  Object.keys(growth).filter(p => (growth[p]?.net ?? 0) >= bar.growthMin).sort()

/** `git grep -c '' <rev> -- <paths>`: each file's line count, by its path. */
export const parseLineCounts = (text: string, rev: string): Record<string, number> => {
  const sizes: Record<string, number> = {}
  for (const line of text.split('\n')) {
    if (!line.startsWith(rev + ':')) continue
    const rest = line.slice(rev.length + 1)
    const cut = rest.lastIndexOf(':')
    const n = Number(rest.slice(cut + 1))
    if (cut > 0 && Number.isFinite(n)) sizes[rest.slice(0, cut)] = n
  }
  return sizes
}

/** The day a moment falls on, UTC, as the ranking key reads it. */
export const dayOf = (ms: number): string => new Date(ms).toISOString().slice(0, 10)

/** The ranking's key: the repository, its origin default head, the day and the rule version (L573, L40). */
export const rankingKey = (repo: string, sha: string, ms: number): string => `${repo} ${sha} ${dayOf(ms)} v${RULE_VERSION}`

export type Judged = { decision: 'would_hold' | 'quiet'; why: ('issues' | 'growth')[]; shown: number[]; excluded: number[] }

/**
 * would_hold when a structural issue at one of the bar's priorities names the file, the issues the
 * session works on (its branch's, its goal's) left out (decision 5), or when the file crosses the
 * growth bar. An issue with no priority label counts as p2, the scale's default, so a missing label
 * never lets a file through.
 */
export const judge = (f: { matches: readonly Match[]; own: readonly number[]; crosses: boolean; bar?: Bar }): Judged => {
  const bar = f.bar ?? DEFAULT_BAR
  const excluded = f.matches.filter(m => f.own.includes(m.n)).map(m => m.n)
  const shown = f.matches
    .filter(m => m.structural.length > 0 && !f.own.includes(m.n) && bar.holdPriorities.includes(m.priority ?? 'p2'))
    .map(m => m.n)
  const why: Judged['why'] = []
  if (shown.length) why.push('issues')
  if (f.crosses) why.push('growth')
  return { decision: why.length ? 'would_hold' : 'quiet', why, shown, excluded }
}

/**
 * The replay (#1508): a real repository's commits run through these rules, each commit standing in
 * for a session, as the calibration on #1506 was measured. A day's growth is that day's last commit.
 */
export type ReplayInput = {
  issues: CachedIssue[]
  tracked: string[]
  days: Record<string, { growth: Record<string, Growth>; sizes: Record<string, number> }>
  sessions: { id: string; day: string; own: number[]; files: string[] }[]
}
export type ReplaySession = { id: string; judged: number; held: number; holds: { path: string; why: Judged['why'] }[] }
export type ReplaySummary = { sessions: number; judgedSessions: number; withHold: number; holds: number; byIssues: number; byGrowth: number; fourOrMore: number; histogram: Record<string, number> }

export const replay = (input: ReplayInput): { sessions: ReplaySession[]; summary: ReplaySummary } => {
  const ranked = new Map<string, Ranked>()
  const rankOf = (day: string): Ranked => {
    let r = ranked.get(day)
    if (!r) {
      const d = input.days[day]
      r = d ? rank(d.growth, d.sizes) : { top: [], facts: {} }
      ranked.set(day, r)
    }
    return r
  }
  const sessions = input.sessions.map(s => {
    const judgedFiles = s.files.filter(p => fileKind(p) !== null)
    const top = rankOf(s.day).top
    const holds = judgedFiles.flatMap(p => {
      const j = judge({ matches: issuesNaming(p, input.issues, input.tracked), own: s.own, crosses: top.includes(p) })
      return j.decision === 'would_hold' ? [{ path: p, why: j.why }] : []
    })
    return { id: s.id, judged: judgedFiles.length, held: holds.length, holds }
  })
  const histogram: Record<string, number> = {}
  for (const s of sessions) histogram[String(s.held)] = (histogram[String(s.held)] ?? 0) + 1
  const all = sessions.flatMap(s => s.holds)
  return {
    sessions,
    summary: {
      sessions: sessions.length,
      judgedSessions: sessions.filter(s => s.judged > 0).length,
      withHold: sessions.filter(s => s.held > 0).length,
      holds: all.length,
      byIssues: all.filter(h => h.why.includes('issues')).length,
      byGrowth: all.filter(h => h.why.includes('growth')).length,
      fourOrMore: sessions.filter(s => s.held >= 4).length,
      histogram,
    },
  }
}


// ---- The hold (#1509): what a held edit shows, and what a decision must carry ----

/** The tool a held session decides with (decision 7), registered as `decide` by this mod. */
export const DECIDE_TOOL = 'mcp__area-check__decide'
/** AskUserQuestion's metadata source for the restructure question, `area-check:<call id>`. */
export const ASK_SOURCE = 'area-check'
/** Dan's three answers to the restructure question, in the order he reads them. */
export const ANSWERS = ['Restructure first', 'Proceed anyway', 'Fold in'] as const
export type Answer = (typeof ANSWERS)[number]
export const DECISIONS = ['proceed', 'fold', 'restructure'] as const
export type Decision = (typeof DECISIONS)[number]
const DAY_MS = 24 * 60 * 60_000
/** How long Dan's answer about a file stands, for the same issues, before he is asked again. */
export const ANSWER_MS = 7 * DAY_MS
/** An issue list no edit has read for this long is dropped from the store (#1509 comment). */
export const SWEEP_MS = 7 * DAY_MS
/** A proceed reason's least length and words: enough to say what the change does to the file. */
export const REASON_MIN = 24
export const REASON_WORDS = 4

/** One held edit, waiting on a decision under its call id, in the session's $.state. */
export type Held = {
  id: string
  tool: string
  repo: string
  main: string
  rel: string
  agent: string | null
  at: number
  why: Judged['why']
  shown: Match[]
  issues: { state: 'read' | 'truncated' } | { state: 'unread'; why: string }
  growth: (FileGrowth & { crosses: boolean }) | { unread: string }
  /** A Bash command whose file cannot be named (#2142): `rel` is its word, `key` the command's claim. */
  unread?: { why: string; key: string }
  // The branch and merge base the edit was held on (#1510), kept in its version 3 decision; absent in entries held before them.
  branch?: string | null
  mergeBase?: string | null
}

/** The held call as a sentence names it: a Bash command writing the file, or the edit tool to it. */
export const heldCall = (h: Held): string => (h.tool === 'Bash' ? `Bash command, which writes ${h.rel}` : `${h.tool} to ${h.rel}`)

/**
 * The restructure question about one file in one repository, in $.store so every session reads it
 * (L636, L330): waiting on Dan, with the held call it was asked for, or his answer and when.
 */
export type Question =
  | { state: 'pending'; at: number; issues: number[]; session: string; call: string; agent: string | null }
  | { state: 'answered'; answer: string; at: number; issues: number[] }

/**
 * The question's key: a SHA-256 of the repository and the held word, 73 characters whatever the word
 * (#2246). A held shell command's word can be its whole unreadable text, and Claude Code refuses a
 * store key over 256 characters, which left such a hold impossible to decide.
 */
export const questionKey = async (repo: string, rel: string): Promise<string> => `question:${await sha256(`${repo}\n${rel}`)}`

/** The store's own limit on a key, which it refuses past on get, set and delete (#2246). */
export const STORE_KEY_MAX = 256

/**
 * The key a question had before #2246, read so an answer Dan already gave still stands for its week,
 * and cleared with the call it waits on. Undefined where it would pass the store's limit, since no
 * question was ever kept there. Deleting this read is #2256, once a week has passed since install.
 */
export const legacyQuestionKey = (repo: string, rel: string): string | undefined => {
  const k = `question:${repo}\n${rel}`
  return k.length <= STORE_KEY_MAX ? k : undefined
}

// A reason that is a stock word, a template's slot or a mark standing alone says nothing (L675).
const PLACEHOLDER = /^(?:n\/?a|none|nothing|tbd|todo|fixme|reason|because|ok(?:ay)?|fine|yes|no|test|whatever|see above|not needed|no reason|small change|minor change|minor|trivial)$/i
const SLOT = /<[^>]*>|\{\{|\[\s*(?:reason|why)[^\]]*\]/i

/** Why a proceed reason is not one, or undefined when it says something. */
export const reasonProblem = (reason: unknown): string | undefined => {
  const ask = 'give "reason" as a sentence saying why this change does not add to the structural problem'
  if (typeof reason !== 'string') return `No reason was given: ${ask}.`
  const r = reason.trim()
  // A placeholder first, since one such as n/a does not start with a whole word either.
  if (PLACEHOLDER.test(r.replace(/[.!]+$/, '')) || SLOT.test(r)) return `"${r}" is a placeholder, not a reason: ${ask}.`
  if (!/^\p{L}+(?:[\s,.;:'’]|$)/u.test(r)) return `"${r}" does not start with a word, so it says nothing: ${ask}.`
  if (r.length < REASON_MIN || r.split(/\s+/).length < REASON_WORDS) return `"${r}" is too short to say what the change does to the file: ${ask}.`
  return undefined
}

const issueList = (h: Held) => h.shown.map(m => `#${m.n}`).join(', ')

/** Why a decision cannot be taken for this held edit, or undefined when it can. */
export const decideProblem = (input: { decision?: unknown; reason?: unknown; issue?: unknown }, h: Held): string | undefined => {
  const d = input.decision
  if (typeof d !== 'string' || !(DECISIONS as readonly string[]).includes(d)) return `"${String(d)}" is not a decision: give "decision" as proceed, fold or restructure.`
  if (d === 'proceed') return reasonProblem(input.reason)
  if (h.unread) return 'This command writes a file whose name cannot be read, so there is no file to fold a fix into or restructure: proceed with a reason, or make the change with Edit or Write, which the area check can judge.'
  if (d === 'fold') {
    if (!h.shown.length) return `${h.rel} was held for its growth alone, so no issue was shown to fold in: proceed with a reason, or restructure.`
    if (!h.shown.some(m => m.n === input.issue)) return `"${String(input.issue)}" is not an issue the hold showed: give "issue" as one of ${issueList(h)}, as a number.`
  }
  return undefined
}

const priorityOf = (m: Match) => m.priority ?? 'p2'
const growthLine = (h: Held): string | undefined => {
  const g = h.growth
  if ('unread' in g) return `Its growth could not be read (${g.unread}).`
  const size = g.size === null ? '' : `, about ${g.size} lines now`
  const fixes = g.fixes ? `, ${g.fixes} commit titles saying fix` : ''
  return `Rough: ${g.net >= 0 ? 'grew' : 'shrank'} ${Math.abs(g.net)} lines net in ${GROWTH_DAYS} days${size}${fixes}.`
}

/** The grey card's words (mod-kit draws it): the file, each issue shown with its priority, growth as rough. */
export const holdCard = (h: Held): { reason: string; safeWay: string; note?: string } => {
  if (h.unread) {
    return {
      reason: `This command writes a file whose name cannot be read before it runs (${h.unread.why}), and ${h.repo} has files the area check would hold.`,
      safeWay: 'Claude proceeds with a reason, or makes the change with Edit or Write, which the area check can judge.',
    }
  }
  const parts: string[] = []
  if (h.shown.length) parts.push(`${h.rel} has open structural issues: ${h.shown.map(m => `#${m.n} (${priorityOf(m)}, ${m.structural.join(', ')})`).join('; ')}.`)
  else if (h.why.includes('growth')) parts.push(`${h.rel} is among the fastest growing large files in ${h.repo}.`)
  if (h.issues.state === 'unread') parts.push(`Its open issues could not be read (${h.issues.why}), so its growth alone decided.`)
  const note = growthLine(h)
  return { reason: parts.join(' '), safeWay: 'Claude decides whether this edit goes ahead, folds a structural fix in, or restructures first.', ...(note ? { note } : {}) }
}

/** What the held session reads: the facts, and how to decide under this call's id. */
export const holdRefusal = (h: Held): string => {
  const c = holdCard(h)
  const facts = [c.reason, c.note].filter(Boolean).join(' ')
  const call = (rest: string) => `${DECIDE_TOOL} with {"call": "${h.id}", ${rest}}`
  const ways = [`${call('"decision": "proceed", "reason": "<why this change does not add to the problem>"')} when it does not`]
  if (h.unread) return `The area check held this ${heldCall(h)}. ${facts} Decide: call ${ways[0]}, or make the change with Edit or Write instead, which the area check can judge. Then send the Bash command again, unchanged.`
  if (h.shown.length) ways.push(`${call('"decision": "fold", "issue": <one of ' + issueList(h) + '>')} to fold that structural fix into this work`)
  ways.push(
    h.agent === null
      ? `${call('"decision": "restructure"')} to ask Dan whether to restructure first`
      : `${call('"decision": "restructure"')} when it should be restructured first, which hands the question to the main session to ask Dan; then stop and report that to it`,
  )
  if (h.tool === 'Bash') return `The area check held this ${heldCall(h)}. ${facts} Decide: call ${ways.join('; or ')}. Then send the Bash command again, unchanged.`
  return `The area check held this ${h.tool} to ${h.rel}. ${facts} Before editing it, decide: call ${ways.join('; or ')}. Then send the ${h.tool} again, unchanged.`
}

/** The restructure question as Dan reads it in the dialog; Fold in only where an issue was shown. */
export const restructureQuestion = (h: Held): { question: string; options: { label: Answer; description: string }[] } => {
  const facts = holdCard(h).reason
  const options: { label: Answer; description: string }[] = [
    { label: 'Restructure first', description: 'The structural fix is done before this work, and the file is released for it.' },
    { label: 'Proceed anyway', description: 'This work goes ahead on the file as it is.' },
  ]
  if (h.shown.length) options.push({ label: 'Fold in', description: `The structural fix for ${issueList(h)} is folded into this work.` })
  return { question: `Restructure ${h.rel} before this work? ${facts}`, options }
}

/** Asleep (decision 7): one note per issue shown, which bedtime posts into its Open questions; for growth alone, one for the morning report. */
export const sleepNotes = (h: Held): { kind: 'question'; repo: string; issue?: number; text: string; options: string[] }[] => {
  const q = restructureQuestion(h)
  const options = q.options.map(o => o.label)
  if (!h.shown.length) return [{ kind: 'question', repo: h.repo, text: q.question, options }]
  return h.shown.map(m => ({ kind: 'question', repo: h.repo, issue: m.n, text: q.question, options }))
}

const sameSet = (a: readonly number[], b: readonly number[]) => a.length === b.length && a.every(x => b.includes(x))

/** Whether Dan's recorded answer about a file still decides it: within its week, for the same issues. */
export const answerStands = (q: Question | undefined, issues: readonly number[], now: number): q is Extract<Question, { state: 'answered' }> =>
  !!q && q.state === 'answered' && typeof q.at === 'number' && now - q.at < ANSWER_MS && Array.isArray(q.issues) && sameSet(q.issues, issues)

/** The store keys to drop: issue lists unread for a week (or unreadable), and answers past their week. A pending question stays. */
export const sweepKeys = (entries: readonly [string, unknown][], now: number): string[] => {
  const at = (v: unknown) => (v && typeof v === 'object' && typeof (v as { at?: unknown }).at === 'number' ? (v as { at: number }).at : null)
  return entries
    .filter(([k, v]) => {
      const t = at(v)
      if (k.startsWith('issues:')) return t === null || now - t >= SWEEP_MS
      if (k.startsWith('question:')) return (v as { state?: unknown } | null)?.state === 'answered' && (t === null || now - t >= ANSWER_MS)
      return false
    })
    .map(([k]) => k)
}
