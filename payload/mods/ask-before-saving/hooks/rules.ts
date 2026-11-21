// Ask before saving (claude-config#618): what counts as lasting memory, when Dan's own words already
// made a rule permanent, and what Claude is told to ask in Claude Code's own dialog (#777). Pure, so
// each rule is tested on its own.
import type { AskBeforeSavingApproval } from '../types/index.d.ts'
import { withinGrace } from './mod-kit/hold.ts'
import { shownFault, unindented, unseenIn } from './mod-kit/shown.ts'

// The check of text Dan approves in a picker (#3295) is mod-kit's since #3321, one implementation
// every guard that records a picker's answer is held to. It is handed on here under the names this
// mod's own files and tests read it by.
export { MAX_QUESTION, MAX_QUESTION_ROWS, QUESTION_COLUMNS, askFault, rowsAt, shownFault, unindented, unseenIn } from './mod-kit/shown.ts'

export const MOD = 'ask-before-saving'

// What a command writes, as mod-kit's contract spells it (types/index.d.ts there): plain data, since
// only plain data crosses between mods.
// `runs` is each script file a command runs with the files it is handed as arguments (#1586).
export type Writes = {
  files: { word: string; path?: string }[]
  unnamed: { what: string; words: string[]; inputs: string[]; targets?: string[] }[]
  runs?: { args: { word: string; path?: string }[] }[]
}

// The lasting memory the spec names: the memory folder, MEMORY.md, ~/.claude/CLAUDE.md, LESSONS.md,
// and a project's CLAUDE.md or AGENTS.md. By file name for the last four, so a project or the config
// repository's own payload copy is caught wherever it lives.
const NAMES = new Set(['MEMORY.md', 'CLAUDE.md', 'AGENTS.md', 'LESSONS.md'])

// A file in a temporary folder (a backup copy, a test fixture in the session's scratchpad) is loaded
// into no session, so it is no lasting memory whatever it is called, unless it is in a checkout
// there: a session started in a repository or worktree cloned under /tmp loads its CLAUDE.md or
// AGENTS.md (#726). Whether it is, `inCheckout` asks the disk ($.modkit.workingTree), only for a
// temporary file that would otherwise count; a disk that cannot answer fails the judgement.
const TEMP = /^(?:\/private)?\/(?:tmp|var\/folders)(?:\/|$)/
export type InCheckout = (abs: string) => Promise<boolean>

const lastingByName = (abs: string, home: string): boolean => {
  const name = abs.split('/').pop() ?? ''
  if (NAMES.has(name)) return true
  const projects = `${home.replace(/\/$/, '')}/.claude/projects/`
  if (!abs.startsWith(projects)) return false
  // <home>/.claude/projects/<project>/memory, or anything in it: a copy into the folder names it.
  const rest = abs.slice(projects.length).split('/')
  return rest.length >= 2 && rest[1] === 'memory'
}

export const lastingMemory = async (abs: string, home: string, inCheckout: InCheckout): Promise<boolean> =>
  lastingByName(abs, home) && (!TEMP.test(abs) || (await inCheckout(abs)))

/** A path as a tool would reach it: home spelled out, relative to cwd, dot segments gone. */
export const resolvePath = (p: string, cwd: string, home: string): string => {
  let s = p
  if (s === '~' || s.startsWith('~/')) s = home + s.slice(1)
  else if (s.startsWith('$HOME/') || s.startsWith('${HOME}/')) s = home + s.slice(s.indexOf('/'))
  if (!s.startsWith('/')) s = `${cwd.replace(/\/$/, '')}/${s}`
  const out: string[] = []
  for (const seg of s.split('/')) {
    if (seg === '' || seg === '.') continue
    if (seg === '..') out.pop()
    else out.push(seg)
  }
  return `/${out.join('/')}`
}

/** A path as Dan reads it: home as ~. */
export const display = (abs: string, home: string): string => {
  const h = home.replace(/\/$/, '')
  return abs === h ? '~' : abs.startsWith(`${h}/`) ? `~${abs.slice(h.length)}` : abs
}

// A target the words alone do not name: no path, or one the reader reached through a variable the
// command set or a command's output, never a path spelled out or under home by $HOME (#743).
const THROUGH = /[$`]/
const unread = (f: { word: string; path?: string }) => !f.path || THROUGH.test(f.word.replace(/^\$(?:HOME|\{HOME\})(?=\/|$)/, ''))

/**
 * The lasting memory among the files a command's words name (mod-kit's $.modkit.writes): judged by
 * path where the words name one, by file name where they do not (a path built from a variable),
 * which cannot be looked for on the disk, so one in a temporary folder counts too (asking is the
 * harmless side). A target the words cannot name (a variable, a command's output, a pattern), and
 * one the reader followed through a variable to no lasting memory, is judged like a write the words
 * do not name at all: by the lasting memory the command mentions anywhere, an assignment such as
 * `F=<path>` included (#743), read from `read.text` where given: the command with the sentences
 * its python programs hold taken out (#940). One that mentions none goes through
 * (docs/mods-design.md). The one exception: a target through a variable the command itself fixed
 * for certain, at the path the reader gave (certainPath, #1241), is judged by that path alone.
 * A file handed to a script file as its argument (mod-kit's `runs`, #1592) is judged as a file the
 * words name, as an Edit of it is, since what the script does with it cannot be read before it runs;
 * one found only that way is put in `read.handed`, so the refusal says it is handed to a script.
 */
export const lastingFiles = async (
  w: Writes,
  home: string,
  inCheckout: InCheckout,
  command: string,
  isSet: IsSet = ALWAYS_SET,
  read: MentionRead = {},
): Promise<string[]> => {
  const out: string[] = []
  const named: string[] = []
  const add = (s: string) => {
    if (!out.includes(s)) out.push(s)
  }
  let mentions: string[] | undefined
  const handed: string[] = []
  // The files the words name, then those handed to a script as its arguments (#1592), each judged alike.
  const words = [...w.files.map(f => ({ ...f, run: false })), ...(w.runs ?? []).flatMap(r => r.args.map(a => ({ ...a, run: true })))]
  for (const f of words) {
    const byName = !f.path && NAMES.has(f.word.split('/').pop() ?? '') && (await throughSettable(f.word, command, isSet))
    const hit = f.path ? (await lastingMemory(f.path, home, inCheckout)) && display(f.path, home) : byName && f.word
    if (hit) {
      if (f.run && !out.includes(hit)) handed.push(hit)
      add(hit)
      named.push(hit)
    }
    // A target through a variable that can hold no path, one only a fresh temporary file sets or
    // nothing sets at all, reaches no lasting memory, so what the command mentions is not read for it
    // (#830: an issue body written to `$(mktemp)` named a memory path). Nor does one through a
    // variable the command fixed for certain, which lands where its path says (#1241, certainPath).
    else if (unread(f) && !(f.path && certainPath(f.word, command, home) === f.path) && (await throughSettable(f.word, command, isSet)))
      for (const m of (mentions ??= await mentioned(read.text ?? command, home, inCheckout, isSet))) add(m)
  }
  if (read.guessed) for (const m of out) if (!named.includes(m) && !read.guessed.includes(m)) read.guessed.push(m)
  if (read.handed) for (const m of handed) if (!read.handed.includes(m)) read.handed.push(m)
  return out
}

/**
 * How a judgement reads what a command mentions (#940): `text`, the command with the sentences its
 * programs hold taken out (withoutPythonText), when not the command itself; and `guessed`, where the
 * files found only by what the command mentions are put, so the refusal can say that is what they
 * are and a misfire shows; and `handed`, where the files found only as a script's argument are put
 * (#1592), so the refusal says what it measured: that the file is handed to a script.
 */
export type MentionRead = { text?: string; guessed?: string[]; handed?: string[] }

/**
 * Whether a variable could hold a value when the command runs (#777). Each Bash call is a fresh
 * shell, so a variable reaches it only from Claude Code's environment, the shell profile, or the
 * command itself. Answered by the mod from $.env and the profile files; one that cannot say is
 * taken as set, the harmless side.
 */
export type IsSet = (name: string) => Promise<boolean>
const ALWAYS_SET: IsSet = async () => true

// A word or mention rooted at a variable other than HOME: `$NAME/...`.
const ROOTED = /^\$([A-Za-z_]\w*)/

// Variables a shell sets for itself, present in every fresh shell whatever the environment held
// (lessons review of #783: `$PWD/CLAUDE.md` was judged unset and saved unasked).
const SHELL_SET = new Set(['HOME', 'PWD', 'OLDPWD', 'TMPDIR', 'USER', 'LOGNAME', 'SHELL', 'PATH', 'HOSTNAME', 'HOST', 'PPID', 'SHLVL', 'ZDOTDIR', 'BASH', 'ZSH_NAME', 'MACHTYPE', 'OSTYPE'])

// A fresh temporary file or folder: mktemp with no template and no folder of its own, or -t and a
// prefix, which put it in the temporary folder. A template or -p names where it goes, which can be
// the memory folder, so it can hold a path like any other output (#830).
const FRESH_TEMP = /^\$\(mktemp(?:\s+-[dqu]+)*(?:\s+-t\s+[\w.-]+)?(?:\s+-[dqu]+)*\s*\)$/

/**
 * Whether the variable `name` can hold a path when `text` runs: set in the environment, or given a
 * value in the text that can be one. A value it is given is followed: a literal, a path under home
 * or a command's output can be anything, so it counts; another variable counts as that one does; a
 * fresh temporary file or folder (`$(mktemp)`, `$(mktemp -d)`, FRESH_TEMP) is loaded into no session,
 * so it does not. Any other use of the bare name (a loop, a read, a declare) counts. A variable named
 * nowhere and set nowhere expands to nothing in a fresh shell, so a path through it reaches no
 * lasting memory.
 */
export const settable = async (name: string, text: string, isSet: IsSet, seen: Set<string> = new Set()): Promise<boolean> => {
  if (SHELL_SET.has(name) || seen.has(name)) return true
  seen.add(name)
  if (await isSet(name)) return true
  const bare = new RegExp(`(^|[^$\\w{])${name}(?!\\w)`, 'gm')
  for (const m of text.matchAll(bare)) {
    const after = text.slice((m.index ?? 0) + m[0].length)
    // A command's output unquoted is read whole, to its closing bracket, so `$(mktemp -d)` is all of it.
    const given = /^=(?:"([^"]*)"|'([^']*)'|(\$\([^()]*\))|([^\s;&|]*))/.exec(after)
    if (!given) return true
    const value = given[1] ?? given[2] ?? given[3] ?? given[4] ?? ''
    if (FRESH_TEMP.test(value)) continue
    const root = /^\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))/.exec(value)
    if (!root) return true
    // One of the two spellings always matched; a match with neither could hold anything.
    const named = root[1] ?? root[2]
    if (named === undefined || (await settable(named, text, isSet, seen))) return true
  }
  return false
}

// A word through a variable is judged by whether that variable could hold a path; any other word is.
const throughSettable = async (word: string, text: string, isSet: IsSet): Promise<boolean> => {
  const named = ROOTED.exec(word)?.[1]
  return named === undefined || (await settable(named, text, isSet))
}

// A folder a variable can be fixed to for certain: absolute or under home by an unquoted ~/ (which an assignment
// expands), spelled only with characters the shell
// neither splits, globs nor expands, and never climbing out through `..`, which the disk reads
// through links and resolvePath does not.
const LITERAL = /^[\w.\/@%+,:~-]+$/
const plainFolder = (s: string) => LITERAL.test(s) && !s.split('/').includes('..')

// Variables the shell itself changes under a command without the command naming them: those every
// fresh shell sets, `$_` after each command, REPLY on a bare read, the clocks and counters, what a
// match or getopts leaves, and the arrays zsh ties to another.
const SHELL_CHANGES = new Set([
  ...SHELL_SET,
  ...['_', 'REPLY', 'RANDOM', 'SRANDOM', 'SECONDS', 'EPOCHSECONDS', 'EPOCHREALTIME', 'LINENO', 'OPTARG', 'OPTIND', 'MATCH', 'MBEGIN', 'MEND', 'match', 'mbegin', 'mend'],
  ...['BASH_REMATCH', 'PIPESTATUS', 'pipestatus', 'status', 'ERRNO', 'HISTCMD', 'BASHPID', 'COLUMNS', 'LINES', 'IFS', 'CDPATH', 'cdpath', 'path', 'fpath', 'argv', 'TTYIDLE'],
])

// A command that runs text as shell code, which can set any variable without naming it.
const RUNS_TEXT = /(?:^|[\s;&|(){}`])(?:eval|source|\.)(?=\s|$)/

// One shell assignment of a value the reader can see whole: quoted, or a word holding no quote,
// separator, substitution or escape.
const ASSIGNMENT = String.raw`([A-Za-z_]\w*)=("[^"]*"|'[^']*'|[^\s;&|<>()"'\x60\\]*)`
// A statement made only of assignments, ended by ; or a new line or &&, where the next runs in the
// same shell after it: never a | or a lone &, which put it in a subshell, nor a command it prefixes.
const ASSIGNS = new RegExp(String.raw`^[ \t]*(?<all>(?:${ASSIGNMENT}[ \t]+)*${ASSIGNMENT})[ \t]*(?:;|\n|&&)`)

/**
 * Where a write through a variable lands, when the command itself fixes that variable for certain
 * (#1241: `S=<scratchpad>/sf; cp payload/LESSONS.md $S/LESSONS.md` was refused as a write that may
 * reach lasting memory). Certain means the command opens with statements made only of assignments,
 * one of which gives the variable a plain absolute folder, or one under home by an unquoted ~/ (plainFolder), so nothing before it can
 * make it conditional; the variable is named nowhere else in the command, so nothing reassigns,
 * appends to, reads into, loops over, references or unsets it, and is read only whole (`$S`,
 * `${S}`, never `${S::=x}`); no text is run as shell code (eval, source, `.`); and it is no variable
 * the shell changes for itself. The word is the variable and a plain path under it. Undefined
 * whenever any of that does not hold, and the write is then judged as before, by everything the
 * command mentions. What it cannot see: a shell function from the profile, run by name, that sets
 * the same variable, as no reader of the words can.
 */
export const certainPath = (word: string, command: string, home: string): string | undefined => {
  const use = /^\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))(\/.*)?$/.exec(word)
  if (!use) return undefined
  const name = (use[1] ?? use[2]) as string
  const under = use[3] ?? ''
  if (SHELL_CHANGES.has(name) || RUNS_TEXT.test(command) || (under && !plainFolder(under))) return undefined
  let value: string | undefined
  let rest = command
  for (let s = ASSIGNS.exec(rest); s; s = ASSIGNS.exec(rest)) {
    for (const a of (s.groups?.all ?? '').matchAll(new RegExp(ASSIGNMENT, 'g'))) if (a[1] === name) value = a[2] as string
    rest = rest.slice(s[0].length)
  }
  if (value === undefined) return undefined
  // The shell expands a `~` only unquoted: a quoted one is a folder named ~ wherever the command
  // runs, which is no certain place.
  const quoted = /^["']/.test(value)
  if (quoted) value = value.slice(1, -1)
  if (!plainFolder(value) || !(value.startsWith('/') || (!quoted && value.startsWith('~/')))) return undefined
  const bare = command.match(new RegExp(`(^|[^$\\w{])${name}(?!\\w)`, 'gm')) ?? []
  if (bare.length !== 1 || command.split(`\${${name}`).length !== command.split(`\${${name}}`).length) return undefined
  return resolvePath(value + under, '/', home)
}

// A lasting memory file named in a script's or a patch's text: a path ending in one of the names,
// or one through a project's memory folder, ending where the shell ends a word (#743: the ; after
// `F=<memory folder>/MEMORY.md;` was shown as part of the file).
const MENTION = /[~\w.\/$-]*\.claude\/projects\/[^\/\s'";&|()<>`]+\/memory(?:\/[^\s'";&|()<>`]*)?|(?:[~\w.\/$-]*\/)?(?:CLAUDE|AGENTS|MEMORY|LESSONS)\.md\b/g

// The lines of a patch that name a file it changes (#1883): a diff command line (`diff --git a/x
// b/x` among them), the --- and +++ of a unified diff, the *** of a context diff, an Index: line, and
// git's rename and copy lines. Any indent is allowed, since GNU patch takes an indented diff. A line
// of the patch's content that happens to start the same way is kept too, the side that asks.
const NAMES_A_FILE = /^[ \t]*(?:diff |--- |\+\+\+ |\*\*\* |Index: |rename (?:from|to) |copy (?:from|to) )/
// A mail git am reads whose body is encoded: quoted-printable can wrap a header's path across lines
// and base64 hides it whole, so no header can be trusted to be all there is.
const ENCODED = /^Content-Transfer-Encoding:[ \t]*(?!(?:7bit|8bit|binary)[ \t]*$)\S/im

/**
 * A patch's text cut to the lines that name the files it changes (#1883), for `mentioned` to judge:
 * a git apply changing five code files was refused as a save to LESSONS.md, which the patch named
 * only in a changed line of another file. Those lines are read as the whole text was, so a file a
 * header names is found exactly as before. Undefined when the text has no such line (a normal diff,
 * an ed script) or is an encoded mail: then nothing says which files it changes, and the whole text
 * is read, as before. mod-kit's patchedPaths (hooks/patch.ts, #2992) reads a patch's paths for another question (what
 * a call changed, honouring -p); this one answers what a patch might write, so it keeps every line
 * that could name a file, for patch as well as git (L342).
 */
export const patchNames = (text: string): string | undefined => {
  if (ENCODED.test(text)) return undefined
  const names = text.split(/\r?\n/).filter(l => NAMES_A_FILE.test(l))
  return names.length ? names.join('\n') : undefined
}

/** Whether a text mentions any lasting memory at all, read as `mentioned` reads it. */
export const mentionsAny = (text: string): boolean => text.search(MENTION) !== -1

// The quotes a path can end at in python code. Which ending quote closes a path, a string of its own
// or one inside python held as text and run (an exec's), and which only ends a quoted sentence, is
// quotedPath's to say (#3082). A backtick is no quote in python: one closing a mention is markdown in
// a sentence, or a shell substitution held as text, which a program that runs no process only writes.
const CLOSES = new Set(["'", '"'])

// Where a path starts: at the root, at home, or at a variable.
const PATH_START = /^(?:\/|~\/|\$)/

// Whether a quote ending a mention inside text closes a path (#3082): it is the closing quote of the
// string holding the mention (a string of its own), or the same quote opened a stretch inside that
// string which is the mention itself or starts where a path starts (code held as text, an exec's or a
// shell line's). A quote that only ends a quoted sentence inside a longer string, as in
// `{"C": "could move to LESSONS.md"}` held in a ''' string, closes no path: what the program writes
// is decided by where it writes, never by a file its text names in a sentence.
const quotedPath = (code: string, at: number, end: number, span: PythonText): boolean => {
  const q = code[end] ?? ''
  if (!CLOSES.has(q)) return false
  if (end === span.to) return true
  const open = code.lastIndexOf(q, at - 1)
  return open >= span.from && (open === at - 1 || PATH_START.test(code.slice(open + 1, end)))
}

/**
 * Where a python program holds text, as mod-kit's one scanner of its comments and strings gives it
 * ($.modkit.pythonText, #1171): plain data, since only plain data crosses between mods. `formatted`
 * is an f-string or a t-string, whose braces hold code.
 */
export type PythonText = { kind: 'comment' | 'string' | 'formatted'; from: number; to: number }

/**
 * A python program's text with each mention of lasting memory that sits in text, not code, blanked
 * (#940: a heredoc writing a test script was asked about as a save to the global CLAUDE.md, which a
 * comment it added named in a sentence). A mention is text when it is in a comment, or in a plain
 * string that goes on past it; one a quote closes is a path (a string of its own, or one inside code
 * held as text, such as an exec's or a shell line's, quotedPath), and one in an f-string is code. A
 * quote that only ends a quoted sentence inside a longer string closes no path (#3082). `spans` is
 * where the program holds text, read by mod-kit (#1171: this mod scanned it itself before). Only the
 * mention's characters change, so the program can be put back where it was read. It reads the text,
 * not what the program does with it: a path cut out of a longer string at run time is not seen.
 */
export const withoutPythonText = (code: string, spans: readonly PythonText[]): string => {
  const text = spans.filter(s => s.kind !== 'formatted')
  return code.replace(MENTION, (m: string, at: number) => {
    const end = at + m.length
    const span = text.find(s => at >= s.from && end <= s.to)
    return span && !quotedPath(code, at, end, span) ? ' '.repeat(m.length) : m
  })
}

/**
 * The lasting memory a write's text mentions, for the writes whose words name no file (a patch, an
 * inline script): each as written, home shown as ~, a diff's a/ or b/ taken off, an absolute path
 * judged where it lands. One in a temporary folder counts inside a checkout there, or when it is
 * built from a variable and so cannot be looked for. `folder`, where known, places a bare name (the
 * folder a program runs in, #1155); `command` is where a variable's assignment is looked for, the
 * whole command when only a part of it is read.
 */
export const mentioned = async (text: string, home: string, inCheckout: InCheckout, isSet: IsSet = ALWAYS_SET, folder?: string, command: string = text): Promise<string[]> => {
  const out: string[] = []
  for (const m of text.match(MENTION) ?? []) {
    // Whether a variable can be set is read from the whole command, where its assignment is (#1155).
    if (!(await throughSettable(m, command, isSet))) continue
    let p = m.replace(/^[ab]\//, '')
    if (p.startsWith('/') || p.startsWith('~/') || p.startsWith('$HOME/') || p.startsWith('${HOME}/')) p = resolvePath(p, '/', home)
    // A bare name a program writes lands in the folder it runs in, where that is known (#1155).
    else if (folder !== undefined && !p.includes('$')) p = resolvePath(p, folder, home)
    if (TEMP.test(p) && !p.includes('$') && !(await inCheckout(p))) continue
    const shown = p.startsWith('/') ? display(p, home) : p
    if (!out.includes(shown)) out.push(shown)
  }
  return out
}

// The spec's words that make a rule permanent in Dan's own message, as an instruction aimed at
// Claude: "from now on" anywhere, "always" or "never" leading the message, a sentence, a line or
// what a colon introduces (after an opening word such as "ok", "also" or "and", and "please", "you
// should" or "you must"), or after "please", "you should" or "you must" anywhere; and "remember" as
// a request in the same places, followed by that, to, this, a colon or a comma ("please remember
// to", "Remember: ..."). Read anywhere, "never mind the screenshots" and "it always fails" skipped
// the question (#705), and "Remember when we shipped it?" did too; "and", "but", "so", "should" and
// "must" inside a sentence lead narrative ("It ran and never finished", "that should never take
// this long", #726), so they count only as the sentence's opening word.
const FROM_NOW_ON = /\bfrom now on\b/i
const OPENER = String.raw`(?:(?:ok(?:ay)?|yes|yeah|yep|no|thanks|thank you|right|sure|great|good|cool|also|and|but|so|then|oh|hey)\b[,\s]\s*)*`
const ASKED = String.raw`(?:please|you should|you must)\s+`
const LEAD = String.raw`(?:(?:^|[.!?:\n]\s*)${OPENER}(?:${ASKED})?|\b${ASKED})`
const ALWAYS_NEVER = new RegExp(`${LEAD}(?:always|never)\\b(?!\\s+mind\\b)`, 'i')
const REMEMBER = new RegExp(`${LEAD}remember(?:\\s+(?:that|to|this)\\b|\\s*[:,])`, 'i')
// Words that limit it to the moment, which win: saving without asking is the harm, asking is not.
const JUST_NOW = /\b(?:for now|for today|today|tonight|this time|just this once|this session|for this session|right now)\b/i

export const madePermanent = (prompt: string | null | undefined): boolean =>
  typeof prompt === 'string' && !JUST_NOW.test(prompt) && (FROM_NOW_ON.test(prompt) || ALWAYS_NEVER.test(prompt) || REMEMBER.test(prompt))

/**
 * The text a Write would save: the whole of a new file, or the lines a rewrite adds. A rewrite that
 * adds no line shows its whole text rather than nothing, so the question never shows an empty rule.
 */
export const addedText = (content: string, old: string | undefined): string => {
  const trim = (s: string) => s.replace(/\n+$/, '')
  if (old === undefined) return trim(content)
  const had = new Set(old.split('\n'))
  const added = content.split('\n').filter(l => l.trim() !== '' && !had.has(l))
  return added.length ? added.join('\n') : trim(content)
}

/**
 * What Claude reads when the hook could not finish, from the failure the engine hands its catch
 * handler. Built from whatever arrives, so the refusal can never itself throw: a hook that throws
 * is skipped, and the save would go through unasked (lessons review of #731).
 */
export const cannotCheck = (failure: { message?: string } | undefined): string =>
  `Not saved: Ask before saving could not check whether this writes lasting memory (${failure?.message || 'it failed'}). Tell Dan what you meant to save instead.`

/** The engine's own words for a hook out of time, for a catch that had too little grace left (#2039). */
export const OUT_OF_TIME = { message: 'it ran out of time' }

/**
 * How each of the mod's catches judges the call once more (#2026, #2039). The engine gives a catch
 * 1,000 ms of its own time, and a catch cut there lets the call run unjudged, so the rerun starts
 * only through withinGrace, while half that grace is left; otherwise the call is held, `held` shaping
 * the refusal for the hook it answers. `budget` is the catch's next.budget, handed in so a test can
 * set it (L524).
 */
export const rerunInGrace = <R>(budget: { readonly remainingMs: number }, rerun: () => R | Promise<R>, held: (reason: string) => R): R | Promise<R> =>
  withinGrace(budget, rerun, () => held(cannotCheck(OUT_OF_TIME)))

/**
 * What a save writes, as the key For good approves it by (#738): a Write's file and content, an
 * Edit's file and change, a Bash call's command and the folder its relative targets resolve in.
 * Claude sends an approved call again from a request of its own, wording a Bash call's description
 * afresh and perhaps giving a path whole where it gave it relative, so the key leaves out everything
 * but what lands on the disk: the same file and text by any spelling is the save Dan approved, and
 * any other text, or the same words reaching another file, is not.
 */
export const saveKey = (tool: string, input: Record<string, unknown>, cwd: string, home: string): string => {
  if (tool === 'Bash') return JSON.stringify([tool, cwd, String(input.command ?? '')])
  const file = resolvePath(String(input.file_path ?? ''), cwd, home)
  if (tool === 'Edit') return JSON.stringify([tool, file, String(input.old_string ?? ''), String(input.new_string ?? ''), input.replace_all === true])
  return JSON.stringify([tool, file, String(input.content ?? '')])
}

/**
 * The call Claude is asked to send again, as JSON of the arguments that make the save, spelled as
 * the call carried them: Claude may not have the call in front of it (the memory writer's or a
 * subagent's, or one a compaction took out), so it is given whole.
 */
export const callShown = (tool: string, input: Record<string, unknown>): string => {
  if (tool === 'Bash') return JSON.stringify({ command: input.command })
  if (tool === 'Edit')
    return JSON.stringify({ file_path: input.file_path, old_string: input.old_string, new_string: input.new_string, ...(input.replace_all === true ? { replace_all: true } : {}) })
  return JSON.stringify({ file_path: input.file_path, content: input.content })
}

/**
 * How long an approval stands for Claude to send the save again (#738), from Dan's press, so one
 * nobody used does not stand open (L523). A chosen number, the issue's own, not a measurement: a
 * tool call running longer than this before Claude's next step lets it lapse, and what that costs
 * is one more question.
 */
export const APPROVAL_MS = 10 * 60_000

/**
 * Whether an approval still stands at `now`. Its time is read back from storage, and one that is
 * not a number (a damaged record, one of another shape) compares false against every clock, so read
 * plainly it would stand for ever and let its save through unasked (L50): it stands for nothing.
 */
export const stands = (until: unknown, now: number): boolean => typeof until === 'number' && Number.isFinite(until) && until > now

/**
 * Whether an approval is the one Dan gave For good for this save: matched by what it saves (saveKey),
 * the key of the call sent again. A lesson approval's key is never a save's, so it never matches here.
 */
export const savesThis = (x: AskBeforeSavingApproval, key: string): boolean => x.key === key

/**
 * Whether an approval is the one Dan gave in the durable lesson picker for the lesson this text adds
 * (#867): `added` is what lessonAddition read the call as adding to the lessons file, undefined when
 * the call is not one that only adds an entry, which no lesson approval matches. The entry may carry
 * the check line this approval holds (#3245), and carries the SHORT line it holds and no other
 * (#3320), each read back from storage as addsLesson reads it.
 */
export const addsThis = (x: AskBeforeSavingApproval, added: string | undefined): boolean => x.lesson !== undefined && added !== undefined && addsLesson(added, x.lesson, x.check, x.short)

/**
 * The wait before an approval lapses, as $.clock.after takes it: what is left of its time, and none
 * for one that no longer stands, never a wait that is not a non-negative number, which $.clock.after
 * refuses by throwing (measured 2026-10-05 with `claude plugin test`: NaN, -1 and Infinity all throw).
 */
export const lapseWait = (until: unknown, now: number): number => (stands(until, now) ? (until as number) - now : 0)

/** The three answers, as Dan reads them in Claude Code's dialog (#777). */
export const FOR_GOOD = 'For good'
export const THIS_SESSION = 'Just this session'
export const NOT_AT_ALL = 'Not at all'

/** The header chip the dialog shows over the question (at most 12 characters). */
export const HEADER = 'Memory rule'

/**
 * The answers the dialog offers, each with what it does. The mod sets them on Claude's call itself,
 * so the label read back is always one of these three, whatever Claude wrote.
 */
export const dialogOptions = (files: string[]) => [
  { label: FOR_GOOD, description: `Saved to ${files.join(', ')}` },
  { label: THIS_SESSION, description: 'Followed until this session ends; nothing is written' },
  { label: NOT_AT_ALL, description: 'Nothing is saved' },
]

/** The AskUserQuestion `metadata.source` that ties a question to the save it is about. */
export const sourceOf = (id: string) => `${MOD}:${id}`
export const saveIdOf = (source: unknown): string | undefined => {
  if (typeof source !== 'string' || !source.startsWith(`${MOD}:`)) return undefined
  return source.slice(MOD.length + 1) || undefined
}

// A question asked before the save (#3293). The save id is handed out only in the refusal of the
// save itself, so a session that asked Dan "save this to memory?" first had an answer that could
// approve nothing: the save was refused and he was asked the identical question again (twice in
// one session on 2026-11-19). Matching such an answer to a later save was ruled unsafe, since it
// could approve a save he did not mean, so the question is refused before he is asked instead.
// Recognised narrowly, by the mod's own answers: a question that names lasting memory (a file, as
// `mentioned` reads one, or the word) and offers For good or Just this session. Counted over this
// Mac's session records on 2026-11-21 before it refused anything: 4 of 1,651 pickers with no save id
// took that shape, each followed by the refused save and the same question with the id; a question
// that only names a memory file (35) or says save and memory (10) was as often something else, a
// choice of route or a question about a file's contents, so neither is refused. Another guard's
// picker (a source of its own) and a subagent's are never this mod's to refuse.
const SAVE_ANSWERS = new Set([FOR_GOOD, THIS_SESSION].map(x => x.toLowerCase()))
export const asksBeforeTheSave = (ask: { questions?: unknown; metadata?: unknown }): boolean => {
  const source = typeof ask.metadata === 'object' && ask.metadata !== null ? (ask.metadata as { source?: unknown }).source : undefined
  if (source !== undefined && (typeof source !== 'string' || !source.startsWith(MOD) || saveIdOf(source) !== undefined)) return false
  const questions = Array.isArray(ask.questions) ? (ask.questions as { question?: unknown; options?: unknown }[]) : []
  return questions.some(q => {
    const text = typeof q?.question === 'string' ? q.question : ''
    const offers = Array.isArray(q?.options) ? (q.options as { label?: unknown }[]) : []
    return (mentionsAny(text) || /\bmemory\b/i.test(text)) && offers.some(o => typeof o?.label === 'string' && SAVE_ANSWERS.has(o.label.trim().toLowerCase()))
  })
}

/** What Claude is told to do instead (#3293): in the refusal of the early question, and in the memory section. */
export const SEND_FIRST = 'send the save itself first'
export const askedBeforeSave =
  `Not asked: this question is about saving to lasting memory and carries no save id in metadata "source", so Dan's answer could approve nothing, and he would be asked the same question again once the save was refused. ` +
  `Do not ask yet: ${SEND_FIRST} (the Write, Edit or Bash call that writes it). It is refused with the one question to ask him and the metadata "source" that ties his answer to it, and then you ask him once. ` +
  `A question that is not about saving to memory offers neither ${FOR_GOOD} nor ${THIS_SESSION}.`
export const sendFirstNote =
  `Before asking Dan whether to save something to lasting memory (the memory folder, MEMORY.md, CLAUDE.md, AGENTS.md or LESSONS.md), ${SEND_FIRST}. ` +
  `It is refused with the one question to ask him and the metadata "source" that ties his answer to it. A question asked before the save approves nothing, so he would be asked it twice.`

// The durable lesson check's picker (#867). payload/hooks/durable-lesson-check.sh tells Claude to ask
// with this `metadata.source` and the rule in `metadata.rule`; its suite holds the two to these names.
// Dan's "Add to LESSONS.md", read from the dialog's own result, approves the write that adds that rule
// to the lessons file, so he is not asked For good about it a second time (Dan, 2026-10-06: "The
// confirmation that I want to add the durable lesson should be enough to indicate that I want to add
// it forever."). Nothing Claude writes approves it: the mod sets the answers, refuses a call carrying
// its own, and reads only the answer the dialog hands back. Since #3245 the picker may also carry the
// lesson's check line in `metadata.check`, shown to Dan on a line of its own, and the same answer
// then covers that one line on that one lesson (Dan, 2026-11-19: "Yes, cover the check line").
// Since #3320 it carries the entry's SHORT line the same way, in `metadata.short`: the line the
// index carries into every session is one he read, and the entry is held to it.
export const LESSON_SOURCE = 'durable-lesson'
export const LESSON_ADD = 'Add to LESSONS.md'
export const LESSON_PROJECT = 'Project memory instead'
export const LESSON_SKIP = 'Skip'
export const LESSON_HEADER = 'Lesson'
/** The lessons file the picker approves a write to, as a tool reaches it. */
export const lessonsFile = (home: string): string => `${home.replace(/\/$/, '')}/.claude/LESSONS.md`

/** The answer Dan gave that made an approval, as he pressed it: For good, or the lesson picker's add. */
export const pressed = (x: AskBeforeSavingApproval): string => (x.lesson !== undefined ? LESSON_ADD : FOR_GOOD)

/**
 * What Dan reads when an approval's lapse cannot be timed, naming the answer he pressed (lessons
 * review of #869: it said For good for a lesson approval too).
 */
export const untimed = (x: AskBeforeSavingApproval, why: string): string =>
  `The ${APPROVAL_MS / 60_000} minute limit on ${pressed(x)} for saving to ${x.files.join(', ')} could not be timed (${why}), so nothing will say when it lapses; it still lapses then.`

export const lessonOptions = (file: string) => [
  { label: LESSON_ADD, description: `Added to ${file}, with no second question` },
  { label: LESSON_PROJECT, description: "Kept in this project's memory, not the lessons file" },
  { label: LESSON_SKIP, description: 'Nothing is saved' },
]

/**
 * A rule as text, the way it is compared: the lessons file sets a rule in bold and wraps it, so the
 * bold marks go and every run of white space is one space.
 */
export const ruleText = (s: string): string => s.replace(/\*\*/g, '').replace(/\s+/g, ' ').trim()

/**
 * The shortest rule an approval is taken for. A rule of a word or two is contained in almost any
 * entry, so it would approve writes Dan never saw; a lesson's rule is a sentence or two.
 */
export const MIN_RULE = 40

/**
 * The longest index line an approved entry's SHORT line may render as, `- L<n>. <short>`: the
 * index's own cap, ENTRY_CAP in hooks/test-rule-file-budget.sh, which hooks/test-durable-lesson-check.sh
 * holds this to, so the short form is a short form and nothing more.
 */
export const MAX_SHORT = 160

/**
 * The key the durable lesson picker's metadata carries the lesson's check line under (#3245).
 * hooks/test-durable-lesson-check.sh holds the hook's instruction to this name.
 */
export const LESSON_CHECK_KEY = 'check'

/**
 * The longest check line an approval holds, in characters, so the line Dan reads in the picker is one
 * he can read whole (security review of #3245: the line had no limit). Measured 2026-11-19: the one
 * check line the lessons file held (L865) was 185 characters, and a CHECK naming three files at the
 * longest path the config held (89 characters) is 288. hooks/test-durable-lesson-check.sh holds the
 * hook's instruction to this number.
 */
export const MAX_CHECK = 300

/**
 * Why text is no check line, in words for the session that sent it, or the line itself. The one
 * reading checkLine and the picker's refusal both take, so the refusal names what the rule refused.
 */
export const readCheckLine = (s: unknown): { line: string } | { fault: string } => {
  if (typeof s !== 'string') return { fault: 'it is not text' }
  const line = unindented(s)
  if (/[\n\r]/.test(line)) return { fault: 'it is more than one line' }
  // The class is closed, not a list of what is refused: space to tilde, written as those two
  // characters so the source holds no escape to mistype. It is judged before the length, so a
  // length is only ever given of ASCII, where a character and a UTF-16 code unit are the same
  // count, and so is the place of the first character outside it (security review of #3295).
  const odd = /[^ -~]/u.exec(line)
  if (odd) {
    const code = (odd[0].codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, '0')
    return { fault: `character ${odd.index + 1} of it is U+${code}, and a check line is plain ASCII letters, digits, punctuation and spaces, with no tab, since Dan approves only text he can see` }
  }
  if (line.length > MAX_CHECK) return { fault: `it is ${line.length} characters, and a check line is at most ${MAX_CHECK}` }
  if (/^CHECK: *[^ ].*\((?:full|partial)\)$/.test(line) || /^NO CHECK: *[^ ]+(?: +[^ ]+){2,}$/.test(line)) return { line }
  return { fault: 'it is in neither shape' }
}

/**
 * A lesson's check line as an approval holds it (#3245): the one line saying which check holds the
 * rule, `CHECK: <path> (full)` or `(partial)`, or that none can, `NO CHECK: <why>` in three words or
 * more. Text reading as one comes back without the file's indentation. Anything else is undefined:
 * other text, text of more than one line, a line over MAX_CHECK characters, a line holding any
 * character outside printable ASCII (space to tilde, so no tab, no control, nothing zero width,
 * bidirectional or from the tag block, and no letter that only looks like a Latin one), and a
 * value that is not text, which a record read back from storage can be (L50). Dan's answer covers
 * the line because he read it, so it holds only characters he can see and is short enough to read
 * (security review of #3245: only some controls were refused, and a run of tag characters behind
 * the visible words was approved and written with them).
 *
 * It asks whether the text is a check line at all, so that nothing else can be approved as one. The
 * lessons file's own reading (claude-sync lesson_check_records) differs both ways. It is narrower
 * over a CHECK line, since it also holds each path's characters. It is wider in two places, where
 * the picker refuses a line the file takes, and the session is told why and can reword it: a NO
 * CHECK reason holding a character outside ASCII, and a line over MAX_CHECK characters (the file
 * has no limit). Since #3294 the file's reader, like the picker, refuses a tab, a carriage return
 * or another control character inside the line, and a line running on to the next one: its record
 * of a line once split at a tab, so it judged only the part before it. Every other line the file
 * takes reads as one here.
 */
export const checkLine = (s: unknown): string | undefined => {
  const read = readCheckLine(s)
  return 'line' in read ? read.line : undefined
}

/**
 * The key the durable lesson picker's metadata carries the entry's SHORT line under (#3320).
 * hooks/test-durable-lesson-check.sh holds the hook's instruction to this name.
 */
export const LESSON_SHORT_KEY = 'short'

/**
 * The length of text as the lessons index cap counts a line: its bytes in UTF-8. The cap is applied
 * by awk's length (hooks/lib/lesson-index-cap.sh), which on these Macs counts bytes (measured
 * 2026-11-20 by the independent review of #3320: one accented letter, one emoji and one plain
 * letter count 7). The mod counted UTF-16 code units, so a SHORT line of 151 accented letters
 * passed the picker and the entry and was then refused by the send, which holds the whole lessons
 * file back. Bytes are never fewer than code units, so nothing counted here is let through that
 * was refused before, and where an awk counts characters this only refuses a little early. A half
 * of a surrogate pair standing alone counts 3, as the replacement character written for it does.
 */
export const indexLength = (s: string): number => {
  let n = 0
  for (const ch of s) {
    const c = ch.codePointAt(0) ?? 0
    n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4
  }
  return n
}

/**
 * Whether a line reads as a SHORT line to somebody reading it drawn (independent review of #3320):
 * "SHORT:" at its start once the marks a markdown surface draws instead of showing are set aside,
 * a quote's ">", a list item's "-", "*", "+" or number, bold, italic, code and heading marks. The
 * picker and the entry counted only a line starting "SHORT:" itself, so "**SHORT: x**",
 * "- SHORT: x" and "> SHORT: x" stood in a question beside the one line his answer covers.
 */
export const readsAsShort = (line: string): boolean => /^[\s>*_~`#+-]*(?:\d+[.)])?[\s>*_~`#+-]*SHORT\s*:/.test(line)

/**
 * The longest text a SHORT line the picker shows may hold after its "SHORT: ", in bytes (indexLength),
 * the unit the index cap and addsLesson count the index line in: what MAX_SHORT leaves once the index line's own
 * start, "- L<number>. ", is taken off at a number of four digits. The picker is asked before the
 * lesson has a number (`claude-sync next-lesson` reserves the one it prints, and it is asked for
 * only once Dan has approved), so the length is held where it can first be judged, against the
 * longest number in use, and an approved SHORT line then fits whichever number it gets (L667).
 * Measured 2026-11-20: numbers are minted from 501 on the work MacBook and from 1001 on the
 * personal one (lesson-bands/, the highest in the file L1037), and five digits start at 10,000,
 * where addsLesson's own count of the whole index line still refuses a line too long. Of the 737
 * SHORT lines in the lessons file, 698 are within this and 39 are 1 to 3 over, each under a number
 * of one or three digits. hooks/test-durable-lesson-check.sh holds the hook's instruction to this
 * number.
 */
export const MAX_SHORT_TEXT = MAX_SHORT - '- L1000. '.length

/**
 * Why text is no SHORT line, in words for the session that sent it, or the line itself, without the
 * file's indentation. The one reading shortLine and the picker's refusal both take.
 *
 * A SHORT line is "SHORT: " and its text, on one line. It is prose, as a rule is, so it is not held
 * to ASCII as a check line is: it is judged by shownFault, the one function every text a picker
 * shows is judged by, with no second copy of the character and markup checks here. Measured
 * 2026-11-20 over the 737 SHORT lines of the lessons file: all are in this shape, and shownFault
 * refuses one, L731's, which names two placeholders in angle brackets outside backticks.
 */
export const readShortLine = (s: unknown): { line: string } | { fault: string } => {
  if (typeof s !== 'string') return { fault: 'it is not text' }
  const line = unindented(s)
  if (line.includes('\n')) return { fault: 'it is more than one line' }
  const fault = shownFault(line)
  if (fault !== undefined) return { fault }
  const m = /^SHORT: ([^ ].*)$/.exec(line)
  if (!m) return { fault: 'it is not in the shape "SHORT: <the rule in one line>", the word SHORT in capitals, a colon, one space and the text' }
  const text = m[1] ?? ''
  if (indexLength(text) > MAX_SHORT_TEXT)
    return {
      fault: `its text is ${indexLength(text)} bytes, the unit the lessons index counts a line in (a character outside ASCII is two to four), and a SHORT line's text is at most ${MAX_SHORT_TEXT}, so that its index line, "- L<number>. " and the text, fits the ${MAX_SHORT} the lessons index holds under a lesson number of up to four digits`,
    }
  return { line }
}

/**
 * A lesson's SHORT line as an approval holds it (#3320): the one line the lessons index renders for
 * the lesson, and so the line a session loads when the lesson is in the core. Text reading as one
 * (readShortLine) comes back without the file's indentation. Anything else is undefined: other
 * text, text of more than one line, a line Dan could not read as written, one too long for the
 * index line, and a value that is not text, which a record read back from storage can be (L50).
 */
export const shortLine = (s: unknown): string | undefined => {
  const read = readShortLine(s)
  return 'line' in read ? read.line : undefined
}

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/**
 * The entry an inserted block carries, when the block is one entry in its fixed shape: blank lines,
 * then lines starting at `- **L<n>.` with no blank line among them, then blank lines. Anything else
 * is undefined. Whether the entry is the approved rule is addsLesson's question.
 */
const entryBlock = (block: string): string | undefined => {
  const m = /^\n*(- \*\*L\d+\.[\s\S]*?\S)\n*$/.exec(block)
  return m && !m[1]?.includes('\n\n') ? m[1] : undefined
}

/**
 * The entry a write to the lessons file adds, under one fail-safe rule rather than a list of shapes
 * refused (the lessons reviews of #869 found a new shape each round: an entry split around kept text,
 * spliced mid line, beside a removal): the file it leaves must be the file as it is now with exactly
 * the entry block inserted at one line boundary (before the end, the block ends at a line end too),
 * and since the independent review of #3320 that boundary must be an entry boundary of the file
 * (boundaryFault), never a place inside another entry. `file` is the lessons file as it is now.
 * Anything else is undefined, and no lesson approval covers it.
 * - A Write leaves its content.
 * - An Edit (never replace_all) whose old text is found exactly once leaves the file with that text
 *   replaced, judged by the same rule. It was once judged by the shape of its two texts instead, which
 *   refused old text cut as whole lines WITH their newline, the shape Claude sent for L1030, so Dan's
 *   Add to LESSONS.md lapsed unused and he was asked For good about it again (#1691).
 */
export const lessonAddition = (tool: string, input: Record<string, unknown>, file: string | undefined): string | undefined => {
  const placed = lessonPlaced(tool, input, file)
  return placed === undefined || placed.misplaced !== undefined ? undefined : placed.entry
}

/**
 * The one entry a write adds to the lessons file, as lessonAddition reads it, and, where the place
 * it is put is not an entry boundary of the file, where it would land instead (`misplaced`,
 * boundaryFault). lessonAddition takes only an entry with no `misplaced`; the words are for the
 * refusal, so the session can put the same entry in a sound place. A Write of a file that is not
 * there yet holds nothing the entry could be put inside.
 */
export const lessonPlaced = (tool: string, input: Record<string, unknown>, file: string | undefined): { entry: string; misplaced?: string } | undefined => {
  if (tool === 'Edit') {
    const edited = editedFile(file, input)
    return file === undefined || edited === undefined ? undefined : insertedEntry(file, edited)
  }
  if (tool !== 'Write') return undefined
  const content = String(input.content ?? '')
  if (file === undefined) {
    const entry = entryBlock(content)
    return entry === undefined ? undefined : { entry }
  }
  return insertedEntry(file, content)
}

// The two lines that can only begin something else in the lessons file, as its own reader takes
// them (claude-sync lesson_entries_render): an entry's first line and a section heading. An entry
// owns every line from its first down to the next of either, blank lines and all.
const ENTRY_START = /^- \*\*L[0-9]+\./
const SECTION_START = /^## /
const quoted = (line: string): string => {
  const text = line.trim()
  return JSON.stringify(text.length > 60 ? `${text.slice(0, 60)}...` : text)
}

/**
 * Where an entry inserted at `at`, a line boundary of the lessons file `file`, would land when that
 * is not an entry boundary, in words for the session that sent it; undefined at a boundary.
 *
 * The independent review of #3320: the approved Edit could put its entry inside another entry. The
 * file's reader gives an entry every line down to the next entry or section heading, so a lesson
 * approved with no SHORT line, written just above an existing entry's SHORT line, took that line
 * as its own in the index, and the entry it was cut out of lost it. Two things make a boundary:
 * - after the entry, the next line that is not blank is another entry's first line or a section
 *   heading, or there is none. Any other line would be read as the new entry's: a SHORT line, a
 *   check line, the rest of a wrapped rule, text that is nobody's.
 * - before it stands an entry, which the first condition has shown to be whole, or a section
 *   heading with nothing but blank lines between. Above the first section, or under text that is no
 *   entry's, the new entry would belong to no section or sit under words nobody approved it beside.
 */
export const boundaryFault = (file: string, at: number): string | undefined => {
  const above = file.slice(0, at).split('\n')
  // The entry or the section heading that stands over the place, whichever is nearer, and whether
  // any text lies between a heading and the place.
  let over: string | undefined
  let between: string | undefined
  for (let i = above.length - 1; i >= 0 && over === undefined; i--) {
    const l = above[i] ?? ''
    if (ENTRY_START.test(l) || SECTION_START.test(l)) over = l
    else if (!INDEX_BLANK.test(l)) between ??= l
  }
  const owner = over !== undefined && ENTRY_START.test(over) ? /^- \*\*(L[0-9]+)\./.exec(over)?.[1] : undefined
  const next = file
    .slice(at)
    .split('\n')
    .find(l => !INDEX_BLANK.test(l))
  if (next !== undefined && !ENTRY_START.test(next) && !SECTION_START.test(next))
    return owner !== undefined
      ? `inside ${owner}'s entry: the line after it, ${quoted(next)}, is ${owner}'s, and the lessons index would read it as the new entry's`
      : `above a line that starts no entry and no section, ${quoted(next)}, which the lessons index would read as part of the new entry`
  if (over === undefined) return "above the file's first section heading, where it would belong to no section"
  if (owner === undefined && between !== undefined) return `under text that is no entry's, ${quoted(between)}, and not under a section heading or after an entry`
  return undefined
}

/**
 * The entries of a lessons file, each as the lines its own reader gives it (claude-sync
 * lesson_entries_render): from its first line down to the line before the next entry or section
 * heading, the blank lines at its end dropped. Its rule, its check line and its SHORT line are all
 * among them, and so is anything else written there, which that reader scans as the entry's.
 */
export const lessonEntries = (file: string): string[] => lessonLayout(file).entries.map(e => e.text)

/**
 * A lessons file as its own reader walks it (claude-sync lesson_entries_render), in the one walk
 * every reading here is made from (L370): its section headings in order, each as the text after
 * "## ", which is what the reader names that section's index file from, and its entries, each with
 * its number, its lines (lessonEntries) and the heading it stands under, undefined above the first
 * one, where the reader files it under no section's name (its split rendering calls that
 * "Unsectioned"). No suite yet runs that reader beside this walk over one fixture, as
 * tests/test-lesson-index-line-shown.sh does for an entry's index line.
 */
export const lessonLayout = (file: string): { heads: string[]; entries: { n: string; text: string; under: string | undefined }[] } => {
  const heads: string[] = []
  const entries: { n: string; text: string; under: string | undefined }[] = []
  let cur: string[] | undefined
  let under: string | undefined
  const close = () => {
    if (cur === undefined) return
    while (cur.length > 1 && INDEX_BLANK.test(cur[cur.length - 1] ?? '')) cur.pop()
    entries.push({ n: /^- \*\*(L[0-9]+)\./.exec(cur[0] ?? '')?.[1] ?? 'L?', text: cur.join('\n'), under })
    cur = undefined
  }
  for (const l of file.split('\n')) {
    if (ENTRY_START.test(l)) {
      close()
      cur = [l]
    } else if (SECTION_START.test(l)) {
      close()
      under = l.slice(3)
      heads.push(under)
    } else cur?.push(l)
  }
  close()
  return { heads, entries }
}

/**
 * What an Edit or Write leaves in a file that holds `file` now (undefined when it is not there or
 * could not be read). A Write leaves its content. An Edit is read as replacing its old text
 * wherever that stands, which is every place a replace_all reaches and the one place any other
 * Edit can; with no old text, or no file, it is read as leaving its new text alone.
 */
export const leftBy = (tool: string, input: Record<string, unknown>, file: string | undefined): string => {
  if (tool === 'Write') return String(input.content ?? '')
  const from = String(input.old_string ?? '')
  const to = String(input.new_string ?? '')
  return file === undefined || !from ? to : file.split(from).join(to)
}

/**
 * The lesson entries an Edit or Write leaves in the lessons file that were not in it before, word
 * for word, each by its number: the entries it adds and the ones it changes, in a rule, a check
 * line, a SHORT line or any other line that is the entry's. `file` is the lessons file as it is now,
 * undefined when it is not there or could not be read, and the write is then judged as if every
 * entry it holds were new. Nothing else a write does to the file counts here: taking an entry out,
 * moving one whole, a section heading, text above the first section. The first three are read by
 * lessonFacts, below, which the For good question about such a write is held to (#3343 route 2).
 *
 * The independent review of #3320: the For good picker approves a save by its key and holds
 * nothing of what the question says, so an entry could reach the index under a question of the
 * session's own wording, with a SHORT line Dan never read. An entry's lines are approved in the
 * lesson picker and nowhere else, and this is what tells such a write from any other.
 */
export const entriesTouched = (tool: string, input: Record<string, unknown>, file: string | undefined): string[] => {
  if (tool !== 'Edit' && tool !== 'Write') return []
  const before = new Map<string, number>()
  for (const e of lessonEntries(file ?? '')) before.set(e, (before.get(e) ?? 0) + 1)
  const touched: string[] = []
  for (const e of lessonLayout(leftBy(tool, input, file)).entries) {
    const left = before.get(e.text) ?? 0
    if (left > 0) before.set(e.text, left - 1)
    else touched.push(e.n)
  }
  return touched
}

/**
 * What an Edit or Write does to the lessons file without changing one word of an entry (#3343 route
 * 2), which entriesTouched does not count and the For good question is held to (Dan, 2026-11-20:
 * "For good, held to facts"):
 * - `removed`, the numbers of the entries it takes out whole. A rule leaves every session, and
 *   `claude-sync lesson` fails for its number.
 * - `moved`, the entries it leaves word for word under another section heading than they stood
 *   under, with both headings (undefined above the first one, where an entry belongs to no
 *   section). The index is one generated file a section, so the entry's line moves to another
 *   file. A section is its heading's text, as its index file is: two headings of the same words
 *   are one section here.
 * - `gone` and `arrived`, the section headings it takes out and adds, a heading whose words
 *   change being one of each. The index file is named from the heading and CLAUDE.md imports it by
 *   that name.
 * - `renamed`, those of `gone` and `arrived` that are one section under a new name: every entry
 *   that stood under the old heading and is still in the file stands under the new one, and
 *   nothing else does. Those entries are not `moved`: they stay together, in the one file the
 *   rename renames. Any other entry whose heading changes is, an entry under a heading added above
 *   it or left by a heading taken out among them.
 * - `unread`, set by the caller when the file could not be read, with why: nothing else is known.
 *
 * Entries are paired by their whole text, as entriesTouched pairs them, so an entry changed in any
 * word reads here as taken out, and there as added. A write that adds or changes an entry is the
 * lesson picker's and is never asked For good, so these are read only for a write that touches none.
 * Not counted, since nothing leaves an index, changes file or renames one: text that is no entry's
 * and no heading (above the first section, or between a heading and its first entry), blank lines,
 * entries or whole sections put in another order.
 */
export type LessonFacts = {
  removed: string[]
  moved: { entry: string; from: string | undefined; to: string | undefined }[]
  gone: string[]
  arrived: string[]
  renamed: { from: string; to: string }[]
  unread?: string
}
export const NO_FACTS: LessonFacts = { removed: [], moved: [], gone: [], arrived: [], renamed: [] }

// `a` less `b`, each member as often as it is in `a` beyond `b`, in `a`'s order.
const less = (a: readonly string[], b: readonly string[]): string[] => {
  const left = new Map<string, number>()
  for (const x of b) left.set(x, (left.get(x) ?? 0) + 1)
  return a.filter(x => {
    const n = left.get(x) ?? 0
    if (n > 0) left.set(x, n - 1)
    return n === 0
  })
}

export const lessonFacts = (tool: string, input: Record<string, unknown>, file: string | undefined): LessonFacts => {
  if (tool !== 'Edit' && tool !== 'Write') return NO_FACTS
  const was = lessonLayout(file ?? '')
  const is = lessonLayout(leftBy(tool, input, file))
  // Each entry the write leaves, paired with one of the same words in the file as it is: the one
  // under the same heading when there is one, so an entry that stays is never read as moved.
  const pool = new Map<string, (string | undefined)[]>()
  for (const e of was.entries) pool.set(e.text, [...(pool.get(e.text) ?? []), e.under])
  const pairs: { entry: string; from: string | undefined; to: string | undefined }[] = []
  for (const e of is.entries) {
    const left = pool.get(e.text)
    if (!left?.length) continue
    const k = left.indexOf(e.under)
    pairs.push({ entry: e.n, from: left.splice(k === -1 ? 0 : k, 1)[0], to: e.under })
  }
  // What is left unpaired was taken out, each number once.
  const removed: string[] = []
  for (const e of was.entries) {
    const left = pool.get(e.text)
    if (!left?.length) continue
    left.pop()
    if (!removed.includes(e.n)) removed.push(e.n)
  }
  const gone = less(was.heads, is.heads)
  const arrived = less(is.heads, was.heads)
  const renamed: { from: string; to: string }[] = []
  for (const from of new Set(gone))
    for (const to of new Set(arrived))
      if (!is.heads.includes(from) && !was.heads.includes(to) && pairs.some(p => p.from === from) && pairs.every(p => (p.from === from) === (p.to === to))) renamed.push({ from, to })
  const carried = (p: { from: string | undefined; to: string | undefined }) => renamed.some(r => r.from === p.from && r.to === p.to)
  const moved: LessonFacts['moved'] = []
  for (const p of pairs) if (p.from !== p.to && !carried(p) && !moved.some(m => m.entry === p.entry && m.from === p.from && m.to === p.to)) moved.push(p)
  return { removed, moved, gone, arrived, renamed }
}

// A heading as it is named: the text after "## " less the white space at its ends, in double
// quotes, so that one heading's words inside a longer heading's are not taken for it.
const headingNamed = (h: string): string => `"${h.trim()}"`

/**
 * What a question must hold to name `facts`, each once: the number of each entry taken out or
 * moved, as written (L174), and each heading taken out or added, in double quotes as it is written
 * after "## ". A renamed heading is both its old name and its new one.
 */
export const factNames = (facts: LessonFacts): string[] => [...new Set([...facts.removed, ...facts.moved.map(m => m.entry), ...[...facts.gone, ...facts.arrived].map(headingNamed)])]

/**
 * Those of factNames that `text` does not hold. A number counts only as a whole token: not inside a
 * longer number (L17 in L174) or a word (XL17, L17th, L17_old), and in its own case. A heading
 * counts only between double quotes, in its own case, word for word. `text` is the question Dan
 * read, or his own message; none names nothing.
 */
export const unnamed = (facts: LessonFacts, text: string | null | undefined): string[] => {
  const t = text ?? ''
  // The name is matched as it is written, never as a pattern (lessons review at c258904): the
  // fallback number of an entry line that could not be numbered, "L?", read as a pattern makes its
  // letter optional and is found in any text holding two marks side by side.
  return factNames(facts).filter(name => (name.startsWith('"') ? !t.includes(name) : !new RegExp(`(?<![A-Za-z0-9_])${escapeRe(name)}(?![A-Za-z0-9_])`).test(t)))
}

/**
 * Whether `text` covers a write that does `facts` to the lessons file: it names every one of them
 * (unnamed), and what the write takes out could be read at all. A write that does none of them is
 * covered by any text, and by none.
 */
export const coversFacts = (facts: LessonFacts, text: string | null | undefined): boolean => facts.unread === undefined && unnamed(facts, text).length === 0

const sectionSaid = (h: string | undefined): string => (h === undefined ? 'no section (the place above the first section heading)' : headingNamed(h))

/**
 * `facts` in words, as what a write does, to follow "this Edit" or "it"; empty when it does none.
 * Entries that move together are said together, and a renamed heading as renamed.
 */
export const factsSaid = (facts: LessonFacts): string => {
  const parts: string[] = []
  if (facts.removed.length) parts.push(`takes out ${facts.removed.join(', ')} whole`)
  const ways: { from: string | undefined; to: string | undefined; entries: string[] }[] = []
  for (const m of facts.moved) {
    const way = ways.find(w => w.from === m.from && w.to === m.to)
    if (way) way.entries.push(m.entry)
    else ways.push({ from: m.from, to: m.to, entries: [m.entry] })
  }
  for (const w of ways) parts.push(`moves ${w.entries.join(', ')} from ${sectionSaid(w.from)} to ${sectionSaid(w.to)}`)
  for (const r of facts.renamed) parts.push(`renames the section heading ${headingNamed(r.from)} to ${headingNamed(r.to)}`)
  for (const h of less(facts.gone, facts.renamed.map(r => r.from))) parts.push(`takes out the section heading ${headingNamed(h)}`)
  for (const h of less(facts.arrived, facts.renamed.map(r => r.to))) parts.push(`adds the section heading ${headingNamed(h)}`)
  return parts.join('; ')
}

// How a fact is named, said in one wording where the save is refused (factsAsk) and where a
// question that names too little is (heldToFacts).
const HOW_NAMED = `Name each entry by its number as it is written here (a number inside a longer number or a word does not count) and each heading in double quotes, word for word as it is written here, in a plain sentence that says what happens to it. If they do not all fit one question, make the change in smaller Edits, each asked about by itself`

/**
 * What the refusal of a save adds to its instruction to ask Dan (askInstruction) when the save
 * does `facts` to the lessons file: what it does, and that the question must name each, so the
 * question can be asked right the first time. Empty when it does none.
 */
export const factsAsk = (tool: string, facts: LessonFacts): string => {
  const said = factsSaid(facts)
  return said ? `This ${tool} ${said}, and the question must name each of those (${factNames(facts).join(', ')}), or it is refused before he is asked. ${HOW_NAMED}. ` : ''
}

/**
 * What Claude is told when its For good question about a write to the lessons file does not name
 * everything the write takes out, moves or renames (#3343 route 2), in the shape of the lesson
 * picker's refusal of a question that does not state the rule: what the question must hold, and
 * why. `missing` are the names it lacks (unnamed).
 */
export const heldToFacts = (file: string, tool: string, facts: LessonFacts, missing: readonly string[]): string =>
  `The question must name what this ${tool} does to ${file}, so Dan decides on the entries and headings themselves: it ${factsSaid(facts)}. ` +
  `It does not name ${missing.join(', ')}. ${HOW_NAMED}. Ask again with the same metadata.`

/**
 * What Claude is told when a write to the lessons file that adds or changes no entry cannot be held
 * to what it takes out, because the file could not be read (L345: what cannot be read is not taken
 * for nothing removed). It is refused, and no question waits on it.
 */
export const cannotHold = (file: string, tool: string, why: string): string =>
  `Not saved, and Dan is not asked For good about it: ${file} could not be read before this ${tool} (${why}), so which entries and headings it would take out cannot be told, ` +
  `and a For good question about that file is asked only when it can be held to what the write takes out. Once ${file} is an ordinary file that can be read, send the save again.`

/**
 * The first heading a question would have to name that Dan could not read as it is written
 * (shownFault, the one judgement of every text a picker shows him), with why, and whether the
 * write adds it. The question naming it would be refused for holding it (askFault), and one that
 * left it out for not naming it, so the save is refused once, in words that say so (L665).
 */
export const unshownName = (facts: LessonFacts): { name: string; fault: string; arriving: boolean } | undefined => {
  for (const h of [...facts.arrived, ...facts.gone]) {
    const name = headingNamed(h)
    const fault = shownFault(name)
    if (fault !== undefined) return { name, fault, arriving: facts.arrived.includes(h) }
  }
  return undefined
}

/** What Claude is told of a save whose question would have to name such a heading (unshownName). */
export const cannotName = (file: string, unshown: { name: string; fault: string; arriving: boolean }): string =>
  `Not saved, and Dan is not asked For good about it: the question would have to name the section heading ${unshown.name}, and he could not read that name as it is written: ${unshown.fault}. ` +
  (unshown.arriving
    ? `Give the new heading a name he can read, and send the save again.`
    : `A heading already in ${file} that cannot be shown to him cannot be asked about here. Tell Dan in one line, naming where the heading stands: he can change it himself.`)

/**
 * What a refused save says first when a For good of Dan's stands for the same call and does not
 * cover it: the question he answered did not name what the call does to the lessons file as it
 * stands now. `missing` are the names that question lacks.
 */
export const notCovered = (file: string, missing: readonly string[]): string =>
  `Dan's For good on this save does not cover it as ${file} stands now: the question he answered did not name ${missing.join(', ')}.`

// Why an entry is approved in the lesson picker and nowhere else, and how Claude asks there: said in
// one wording by the refusal of an Edit or Write (pickerOnly) and of a shell command (byShellOnly).
const ENTRY_REACH = `an entry's rule, check line and SHORT line reach every session, so he approves it only in the lesson picker, where he reads each of them word for word`
const PICKER_ASK = `ask him in the lesson picker, as the durable lesson check words it: one AskUserQuestion with metadata "source": "${LESSON_SOURCE}", the rule word for word in "rule", its check line in "${LESSON_CHECK_KEY}" and its SHORT line in "${LESSON_SHORT_KEY}", then add the entry with the one Edit his answer describes`

/**
 * What Claude is told when an Edit or Write would add or change a lesson entry with no answer of
 * Dan's in the lesson picker covering it (independent review of #3320). It is refused, and he is
 * not asked For good: that picker shows him a question of the session's own wording, and an entry's
 * rule, check line and SHORT line are approved only where he reads each word for word. `misplaced`
 * is where a single added entry would land when that is no entry boundary (boundaryFault).
 */
export const pickerOnly = (file: string, tool: string, touched: readonly string[], misplaced: string | undefined): string =>
  `Not saved, and Dan is not asked For good about it. This ${tool} adds or changes a lesson entry in ${file} (${touched.join(', ')}), and ${ENTRY_REACH}. ` +
  (misplaced !== undefined
    ? `It would put the entry ${misplaced}. Add it whole at an entry boundary: straight after another entry's last line or under a section heading, with another entry's first line, a section heading or the end of the file as the next line that is not blank. `
    : '') +
  `If he answered ${LESSON_ADD} for this lesson in the last ${APPROVAL_MS / 60_000} minutes, send one Edit that adds exactly the entry that answer described, at an entry boundary. ` +
  `Otherwise ${PICKER_ASK}. ` +
  `To change an entry that is already there, ask him the same way for the entry as it should read, take the old one out (a removal is asked about as usual), and add the new one.`

/**
 * Whether the installed lessons file is among a shell command's lasting memory (register.ts
 * lastingTargets, each file as Dan reads it), whichever way the command was found to write it
 * (#3343): named by its words, handed to a script, or mentioned by its path beside a write the
 * words do not name. Only that file by its path counts. A checkout's `payload/LESSONS.md` does not,
 * nor does a LESSONS.md the reader could place nowhere (`$S/LESSONS.md` through a variable only a
 * command's output or a condition sets, a bare name in a patch's prose): each may be a scratch copy
 * or a checkout's, and is asked about as before.
 */
export const lessonsByShell = (files: readonly string[], home: string): boolean => files.includes(display(lessonsFile(home), home))

/**
 * What Claude is told when a shell command writes, or may write, the installed lessons file (#3343).
 * It is refused, no question waits on it and no approval covers it: the mod reads which files a
 * command writes, never what it writes to them, so it cannot hold an entry to what Dan read, and a
 * For good there approved an entry under a question of the session's own wording. The Edit route is
 * named, where a write is read: an entry goes to the lesson picker (pickerOnly) and anything else is
 * asked about as before. `file` is the installed lessons file as Dan reads it; `how` says when it
 * was found only by a mention (`guessed`) or only as a script's argument (`handed`), so the refusal
 * claims only what was measured (L11) and says how a command that only reads the file is sent;
 * `others` is the rest of the lasting memory the command writes. A command whose words show it only
 * reads the file never gets here.
 */
export const byShellOnly = (file: string, how: { guessed?: boolean; handed?: boolean }, others: readonly string[]): string =>
  `Not run, and Dan is not asked For good about it: ${writesWhat([file], how.guessed ? [file] : [], how.handed ? [file] : [])}. ` +
  `What a shell command does to a lesson entry cannot be read before it runs, and ${ENTRY_REACH}. ` +
  `Make the change to ${file} with Edit or Write instead, which are read before they run: one that adds or changes an entry is covered by his answer in the lesson picker and by nothing else, and one that touches no entry is asked about as usual. ` +
  `For an entry, ${PICKER_ASK}. ` +
  (how.guessed || how.handed
    ? `If this command only reads or quotes ${file}, send it so that nothing it writes is left unread: feed a script the file on standard input (< ${file}) or hand it a copy, and keep every other write to a file the command's own words name. `
    : '') +
  (others.length ? `Its other lasting memory (${others.join(', ')}) is judged when sent in a command that leaves ${file} alone. ` : '') +
  `A command whose words show that it only reads ${file} (cat, grep, wc, claude-sync lesson) is not refused.`

/**
 * The file an Edit leaves: `file` with its old text replaced, when that text is found exactly once
 * (never replace_all, never empty old text, never a file that is not there). Anything else is
 * undefined, and is judged as no addition at all.
 */
export const editedFile = (file: string | undefined, input: Record<string, unknown>): string | undefined => {
  const from = String(input.old_string ?? '')
  if (file === undefined || input.replace_all === true || !from) return undefined
  const at = file.indexOf(from)
  if (at === -1 || file.indexOf(from, at + 1) !== -1) return undefined
  return file.slice(0, at) + String(input.new_string ?? '') + file.slice(at + from.length)
}

// The entry block `content` is `file` with, inserted at one line boundary, or undefined. Where the
// same text can be read as inserted at more than one boundary, the first that is an entry boundary
// of the file is the one taken; where none is, the entry comes back with where it would land.
const insertedEntry = (file: string, content: string): { entry: string; misplaced?: string } | undefined => {
  const size = content.length - file.length
  if (size <= 0) return undefined
  // What the two share at the start and at the end, measured once: the block can sit only at a line
  // boundary b with b <= head and b >= file.length - tail, where both sides match by construction
  // (sixth lessons review of #869: comparing the whole file at every boundary cost lines x size).
  let head = 0
  while (head < file.length && file[head] === content[head]) head++
  let tail = 0
  while (tail < file.length && file[file.length - 1 - tail] === content[content.length - 1 - tail]) tail++
  const lo = file.length - tail
  if (lo > head) return undefined
  const next = (from: number) => (from === 0 || file[from - 1] === '\n' ? from : file.indexOf('\n', from) === -1 ? file.length + 1 : file.indexOf('\n', from) + 1)
  let first: { entry: string; misplaced: string } | undefined
  for (let b = next(lo); b <= head; b = next(b + 1)) {
    const block = content.slice(b, b + size)
    if (b !== file.length && !block.endsWith('\n')) continue
    const entry = entryBlock(block)
    if (entry === undefined) continue
    const misplaced = boundaryFault(file, b)
    if (misplaced === undefined) return { entry }
    first ??= { entry, misplaced }
  }
  return first
}

// A blank line as the lessons file's own reader takes one (claude-sync lesson_entries_render, awk's
// [[:space:]]): nothing, or spaces, tabs and the other ASCII white space alone.
const INDEX_BLANK = /^[ \t\v\f\r]*$/

/**
 * Whether an entry's lines, those above its check line, set the whole rule in bold and nothing
 * else: "- **", then `numbered` (the number and the rule, "L753. <rule>"), then "**" at once, and no
 * bold mark after that. `lines` hold no blank line.
 *
 * This is the one shape of an entry with no SHORT line that the mod takes (independent review of
 * #3320), chosen so the index line is not in doubt and no second copy of the generator's reading is
 * kept here. The generator (claude-sync lesson_entries_render) renders what stands between the
 * entry's opening "- **" and the first "**" after it, its lines joined and each run of white space
 * folded to one space. In this shape that text is the rule whichever way it is read: the first
 * closing mark is the only one, and it stands right after the rule's last character. A bold closed
 * early, opened late, opened twice or closed over the provenance is another shape and is refused,
 * whatever the generator would make of it. White space is folded as awk folds it, the ASCII kinds
 * only, so a space of another kind in the span is no match for the space in the rule.
 */
export const wholeRuleInBold = (lines: readonly string[], numbered: string): boolean => {
  const marked = lines
    .map(l => l.replace(/^[ \t\v\f\r]+/, ''))
    .join(' ')
    .replace(/[ \t\v\f\r]+/g, ' ')
  const open = '- **'
  if (!marked.startsWith(open)) return false
  const close = marked.indexOf('**', open.length)
  return close !== -1 && marked.slice(open.length, close) === numbered && marked.indexOf('**', close + 2) === -1
}

/**
 * Whether the added text is exactly that one lesson (lessons review of #869: anything else written
 * beside the rule reached every session unseen by Dan): one new entry, `- **L<n>.` then the rule as
 * he approved it (bold and wrapping aside), then at most its provenance (repo#N, then a date), then at most
 * one SHORT line whose index line, `- L<n>. <short>`, is within the index's cap. Blank lines around it
 * are the file's spacing.
 *
 * `check` is the check line Dan read in the picker beside the rule, when it showed him one (#3245;
 * Dan, 2026-11-19: "Yes, cover the check line"). The entry may then carry that one line, equal to it
 * but for the file's indentation (unindented), in one place: straight after the rule and its
 * provenance, which is just before the SHORT line, or last when the entry has none. That is the
 * place hooks/durable-lesson-check.sh tells the session to write it, and one the lessons file's own
 * reader reads (claude-sync lesson_entries_render scans every line of the entry after its first, so
 * it also reads a line after the SHORT line, which no approval covers). Every other line is still
 * read as the rule's, so another check line, a second one, one in another place, or the same line
 * under another rule fails the comparison below and is asked about. With no `check`, or one that is
 * no check line (checkLine), the entry takes no check line at all.
 *
 * The entry's line is compared as the entry holds it (security review of #3245). The lines above are
 * split from the entry with its end trimmed of all white space, which also takes a byte order mark
 * or a no break space behind the last line, so the line is read from a copy trimmed of spaces, tabs
 * and newlines only. And the rule's bold must close above the check line: where it never closes,
 * the index joins every following line of the entry into the rule it renders, the check line too.
 *
 * No line of the entry holds a character Dan cannot see (#3295, unseenIn), and neither does the
 * rule the approval holds, which is read back from storage (L50). The comparison below folds every
 * run of white space into one space, so a tab, a no break space or a line separator in the entry
 * once read as the space he saw in the rule.
 *
 * `short` is the SHORT line Dan read in the picker, when it showed him one (#3320). The SHORT line
 * is what the index carries into every session, and it was once shown nowhere and compared with
 * nothing, so under an approval for one rule an entry went through whose SHORT line said something
 * else. The entry's SHORT line is now that line, equal to it but for the file's indentation, read
 * from the same copy of the entry the check line is, and it stays the entry's last line. With no
 * `short`, or one that is no SHORT line (shortLine), the entry takes no SHORT line at all, so one
 * added after an approval that showed none is asked about. And where he read one, an entry
 * without it is not the entry he read. Whether a lesson needs one is settled before he is asked:
 * the picker refuses a rule too long for the index line that brings no SHORT line (register.ts).
 *
 * With no SHORT line the index renders the entry's BOLD SPAN as the lesson's line, and nothing held
 * that span to the rule (independent review of #3320): under an approval for "Never ask Dan before
 * any save that he has already refused in this session, ..." an entry went through whose bold closed
 * after "Never ask Dan before any save", and that was the line every session loaded. Such an entry
 * is now taken only in one shape (wholeRuleInBold): the whole rule in bold, and nothing else.
 * Where he read a SHORT line the index renders that line, and where the bold closes is the file's
 * layout, as it was. tests/test-lesson-index-line-shown.sh runs the real generator over the entries
 * this function approves and holds what it renders to the text he was shown.
 */
export const addsLesson = (added: string, rule: string, check?: unknown, short?: unknown): boolean => {
  if (unseenIn(added) !== undefined || unseenIn(rule) !== undefined) return false
  const lines = added.replace(/^\s*\n/, '').replace(/\s+$/, '').split('\n')
  // No line of the entry is blank, a line of spaces included: the index stops reading a wrapped
  // rule at one, so the lines after it would be in the entry and out of the line it renders.
  if (lines.some(l => INDEX_BLANK.test(l))) return false
  const shortAt = lines.findIndex(l => /^\s*SHORT:/.test(l))
  if (shortAt !== -1 && (shortAt !== lines.length - 1 || shortAt === 0)) return false
  // No other line of the entry reads as a SHORT line once its markdown is drawn (independent review
  // of #3320): in bold, in a list or in a quote it would stand in the file beside the one he read.
  if (lines.some((l, i) => i !== shortAt && readsAsShort(l))) return false
  const approved = checkLine(check)
  const end = shortAt === -1 ? lines.length : shortAt
  const raw = added.replace(/^\s*\n/, '').replace(/[ \t\n]+$/, '').split('\n')
  const shownShort = shortLine(short)
  const written = shortAt === -1 || raw.length !== lines.length ? undefined : unindented(raw[shortAt] ?? '')
  if (shortAt === -1 ? shownShort !== undefined : shownShort === undefined || written !== shownShort) return false
  const checked = approved !== undefined && end > 1 && raw.length === lines.length && unindented(raw[end - 1] ?? '') === approved
  if (checked && !/^- \*\*L\d+\.[\s\S]*\*\*/.test(lines.slice(0, end - 1).join('\n'))) return false
  const body = ruleText(lines.slice(0, checked ? end - 1 : end).join('\n'))
  // Provenance is its shape and nothing more, one or more `repo#N` (owner qualified or not) and an
  // optional date (lessons reviews of #869: any text in parentheses let a sentence Dan never read
  // ride along, and `owner/repo#N` is a provenance too).
  const ref = String.raw`(?:[\w.-]+\/)?[\w.-]+#\d+`
  const provenance = String.raw`(?: \(${ref}(?:, ${ref})*(?:, \d{4}-\d{2}-\d{2})?\))?`
  const m = new RegExp(`^- L(\\d+)\\. ${escapeRe(ruleText(rule))}${provenance}$`).exec(body)
  if (!m) return false
  if (shortAt === -1 && !wholeRuleInBold(lines.slice(0, checked ? end - 1 : end), `L${m[1]}. ${ruleText(rule)}`)) return false
  // Counted as the index renders it, `- L<n>. <short>` (third lessons review of #869), or, with no
  // SHORT line, `- L<n>. <rule>`: an entry the index cannot hold is refused by the send, which holds
  // the whole lessons file back (sixth lessons review of #869).
  const shown = shortAt === -1 ? ruleText(rule) : (lines[shortAt] ?? '').replace(/^\s*SHORT:\s*/, '')
  return indexLength(`- L${m[1]}. ${shown}`) <= MAX_SHORT
}

// One For good on a memory file also covers the one line in its folder's index linking to it (#1794,
// Dan, 2026-10-26: "didn't I already give permission to save this? how is this different than the
// last one?"). Everything below judges that line strictly, the side that asks: anything it cannot
// read as exactly that one line added, and nothing else changed, is asked about as before.

/**
 * The index a For good on this memory file carries its line for, and the name that line links to: a
 * file directly in a project's memory folder (<home>/.claude/projects/<project>/memory/<name>), never
 * the index itself, nor one in a folder below it, which the index would link by a longer path.
 */
export const memoryFileOf = (abs: string, home: string): { index: string; name: string } | undefined => {
  const projects = `${home.replace(/\/$/, '')}/.claude/projects/`
  if (!abs.startsWith(projects)) return undefined
  const [project, memory, name, ...below] = abs.slice(projects.length).split('/')
  if (!project || memory !== 'memory' || !name || name === 'MEMORY.md' || below.length) return undefined
  return { index: `${projects}${project}/memory/MEMORY.md`, name }
}

/**
 * The one line a write to an index adds, when the index it leaves is the index as it is now with
 * exactly one line of text inserted at a line boundary and nothing else changed: no second line, no
 * blank line, no existing line changed, taken out or spliced into. An index with no newline after its
 * last line may get one before the new line. No index yet (undefined or empty) takes the line alone.
 * Anything else is undefined, and is asked about.
 */
export const indexLineAdded = (old: string | undefined, next: string): string | undefined => {
  const was = old ?? ''
  // The line, when `s` is one line of text with at most its newline after it.
  const one = (s: string): string | undefined => {
    const line = s.endsWith('\n') ? s.slice(0, -1) : s
    return line.trim() && !line.includes('\n') ? line : undefined
  }
  if (was === '') return one(next)
  if (!was.endsWith('\n') && next.startsWith(`${was}\n`)) return one(next.slice(was.length + 1))
  const size = next.length - was.length
  if (size < 2) return undefined
  // What the two share at the start and at the end, as insertedEntry measures it: the line can sit
  // only at a boundary b with b <= head and b >= was.length - tail, where both sides match.
  let head = 0
  while (head < was.length && was[head] === next[head]) head++
  let tail = 0
  while (tail < was.length && was[was.length - 1 - tail] === next[next.length - 1 - tail]) tail++
  for (let b = Math.max(0, was.length - tail); b <= head; b++) {
    if (b !== 0 && was[b - 1] !== '\n') continue
    const block = next.slice(b, b + size)
    const line = block.endsWith('\n') ? one(block) : undefined
    if (line !== undefined) return line
  }
  return undefined
}

// A markdown link, and the target it names.
const LINK = /\[[^\]\n]*\]\(([^()\s]*)\)/g

/** Whether an index line's one markdown link is to `name`, by its name alone (`./` before it allowed). */
export const linksOnlyTo = (line: string, name: string): boolean => {
  const targets = [...line.matchAll(LINK)].map(m => m[1])
  return targets.length === 1 && (targets[0] === name || targets[0] === `./${name}`)
}

/** One simple command as mod-kit's `pipeline` reads it, the parts of it judged here. */
export type ShellCommand = {
  words: string[]
  heredocs?: { word: number; body: string; quoted: boolean; fd?: number; replaced?: true }[]
  pipedFrom?: string[]
  substitution?: true
}
/** What mod-kit's `writes` reads a command as changing, the parts of it judged here. */
export type IndexWrites = {
  files: { word: string; path?: string; edits?: true }[]
  unnamed: unknown[]
  runs?: unknown[]
  changes?: unknown[]
  byGit?: unknown[]
}

// Text neither the shell nor echo or printf can change, wherever it is quoted: no variable, command,
// escape or second line.
const UNCHANGED = /^[^\\$`\n]+$/

/**
 * The text a shell command appends to `index`, when it is one command that only appends text it
 * spells out: `echo '<text>'`, `printf '%s\n' '<text>'`, `printf '<text>\n'` (no % in it), or `cat`
 * fed a heredoc (its body as written: quoted, or holding no $, backtick or backslash), with `>>`
 * into the index and no other redirect, pipe or command beside it, writing nothing else, by mod-kit's
 * one reader of what a command writes and runs. echo's and printf's text must be quoted whole in the
 * command, single or double, so the shell neither splits it nor reads its brackets as a pattern.
 * One plain read of the index may follow it (#2216, readBack). Anything else is undefined, and is
 * asked about. `command` is the command as written, `cmds` and `w` mod-kit's reading of it, `home`
 * the home folder a read's `~/` names.
 */
export const shellAppended = (command: string, cmds: readonly ShellCommand[], w: IndexWrites, index: string, home: string): string | undefined => {
  if (cmds.length === 1) return appendAlone(command, cmds, w, index)
  const read = cmds.length === 2 ? readBack(command, index, home) : undefined
  const second = cmds[1]
  if (!read || !second || Object.keys(second).some(k => !READ_KEYS.has(k)) || JSON.stringify(second.words) !== JSON.stringify(read.words)) return undefined
  return appendAlone(read.append, cmds.slice(0, 1), w, index)
}

// The one read an append of the index line may be followed by (#2216): `tail` or `head` with at most
// a line count (`-n 3`, `-n3`, `-3`), `cat` alone, or `wc` with at most one of -l, -w, -c, -m, of the
// index named plainly: its absolute path, bare or quoted whole, or `~/` and the rest bare. Matched on
// the command as written, at its very end, after a ; && or new line, so nothing leads it (no runner,
// assignment, negation, group or exec) and nothing follows it (no redirect, pipe or second file);
// its file holds no $, backtick, backslash, glob, space or `..`. mod-kit's reading must then see
// exactly the append and this one command, with these words and nothing else read of it.
const READ_BACK = /(?:;|&&|\n)[ \t]*((?:tail|head)(?:[ \t]+(?:-n[ \t]*\d+|-\d+))?|cat|wc(?:[ \t]+-[lwcm])?)[ \t]+('[A-Za-z0-9_./-]+'|"[A-Za-z0-9_./-]+"|~?[A-Za-z0-9_./-]+)[ \t]*$/
// What mod-kit's reading may give of that read beyond its words: which words were quoted, its folder.
const READ_KEYS = new Set(['words', 'literal', 'folder'])

/**
 * The read at the end of `command` that may follow an append of the index line (READ_BACK), as the
 * words mod-kit reads it with, and the command before it; undefined when its end is no such read of
 * `index`, or what is before it ends in another operator.
 */
export const readBack = (command: string, index: string, home: string): { append: string; words: string[] } | undefined => {
  const m = READ_BACK.exec(command)
  if (!m || m[1] === undefined || m[2] === undefined) return undefined
  const append = command.slice(0, m.index)
  if (!append.trim() || /[;&|]\s*$/.test(append)) return undefined
  const word = m[2]
  const file = /^['"]/.test(word) ? word.slice(1, -1) : word
  // `~` is the home folder only bare, at the start; quoted it names a folder called ~.
  const path = word.startsWith('~/') ? home + file.slice(1) : file
  if (!path.startsWith('/') || /(?:^|\/)\.\.(?:\/|$)/.test(path) || resolvePath(path, '/', home) !== index) return undefined
  return { append, words: [...m[1].split(/[ \t]+/), file] }
}

const appendAlone = (command: string, cmds: readonly ShellCommand[], w: IndexWrites, index: string): string | undefined => {
  const into = w.files[0]
  if (cmds.length !== 1 || w.files.length !== 1 || into?.path !== index || into.edits || w.unnamed.length || w.runs?.length || w.changes?.length || w.byGit?.length) return undefined
  const c = cmds[0]
  if (!c || c.substitution || c.pipedFrom) return undefined
  const at = c.words.indexOf('>>')
  if (at === -1 || c.words.lastIndexOf('>>') !== at || c.words[at + 1] !== into.word) return undefined
  const rest = [...c.words.slice(0, at), ...c.words.slice(at + 2)]
  const docs = c.heredocs ?? []
  const quoted = (s: string) => (!s.includes("'") && command.includes(`'${s}'`)) || (!s.includes('"') && command.includes(`"${s}"`))
  const spelled = (s: string | undefined) => (s !== undefined && UNCHANGED.test(s) && quoted(s) ? `${s}\n` : undefined)
  if (rest[0] === 'echo' && rest.length === 2 && !docs.length) return spelled(rest[1])
  if (rest[0] === 'printf' && rest.length === 3 && !docs.length && rest[1] === '%s\\n' && quoted(rest[1])) return spelled(rest[2])
  if (rest[0] === 'printf' && rest.length === 2 && !docs.length) {
    const format = rest[1] ?? ''
    const text = format.slice(0, -2)
    return format.endsWith('\\n') && !text.includes('%') && quoted(format) && UNCHANGED.test(text) ? `${text}\n` : undefined
  }
  const doc = docs[0]
  if (rest[0] !== 'cat' || rest.length !== 2 || docs.length !== 1 || !doc) return undefined
  const word = rest[1] ?? ''
  if (!word.startsWith('<<') || word.startsWith('<<<') || word.startsWith('<<-') || c.words[doc.word] !== word || (doc.fd ?? 0) !== 0 || doc.replaced) return undefined
  return doc.quoted || !/[\\$`]/.test(doc.body) ? `${doc.body}\n` : undefined
}

/**
 * What a refused save writes, as every refusal says it: the files, and for those taken from what the
 * command mentions because its words do not name the file it writes, that this is so (#940), so a
 * misfire shows as one. A message may claim only what its check measured (L11).
 */
export const writesWhat = (files: string[], guessed: string[] = [], handed: string[] = []): string => {
  // A file handed to a script as its argument (#1592) is said as that, never as a file it writes:
  // what the script does with it cannot be read before it runs.
  if (handed.length) {
    const rest = files.filter(f => !handed.includes(f))
    const toScript = `lasting memory (${handed.join(', ')}) to a script, which may write it`
    return rest.length ? `${writesWhat(rest, guessed)}, and it hands ${toScript}` : `this hands ${toScript}`
  }
  const named = files.filter(f => !guessed.includes(f))
  const maybe = guessed.join(', ')
  if (!guessed.length) return `this writes lasting memory (${files.join(', ')})`
  // A file the words name beside one taken from a mention: each said as what it is (lessons review of #963).
  if (named.length) return `this writes lasting memory (${named.join(', ')}) and may write ${maybe}: its words do not name every file it writes, and they mention ${maybe}`
  return `this may write lasting memory (${maybe}): its words do not name the file it writes, and they mention ${maybe}`
}

/**
 * What Claude is told when a save to lasting memory is refused: ask Dan in Claude Code's own dialog,
 * naming the file and stating the rule in plain words (#777, Dan: "I don't really know what it's
 * asking"), and on For good send the same call again. `held` is what else the question must name,
 * as a sentence of its own (factsAsk, for a write that takes an entry out of the lessons file,
 * moves one or changes a heading); none for any other save.
 */
export const askInstruction = (id: string, files: string[], guessed: string[] = [], handed: string[] = [], held: string = ''): string => {
  const where = files.join(', ')
  return (
    `Not saved yet: ${writesWhat(files, guessed, handed)}, so Dan decides first. ` +
    (guessed.length ? `If it only quotes ${guessed.join(', ')} as text and writes another file, make the change with Edit or Write on that file instead. ` : '') +
    `Ask him now with AskUserQuestion: one question, with metadata {"source": "${sourceOf(id)}"}, that names ${where} and states the rule in one plain sentence, never the command or the raw text, ` +
    `such as "Save to ${files[0]} for good: <the rule>?", with the options ${FOR_GOOD}, ${THIS_SESSION} and ${NOT_AT_ALL}. ` +
    held +
    `If he answers ${FOR_GOOD}, send this same call again unchanged and it is saved. Until he answers, do not write it any other way.`
  )
}

/**
 * What Claude is told first when a shell command writes to a memory index whose one line a For good
 * covers, but is not read as one that only appends text it spells out (#2181): the refusal alone read
 * as though Dan had approved nothing. It names the forms shellAppended reads, and says a read of the
 * file goes in a call of its own. `covers` are the memory files whose line may be added, `index` the
 * index as Dan reads it. It claims only what was measured: the command was not read as such an append.
 */
export const notAnAppendNote = (covers: readonly { name: string; files: readonly string[] }[], index: string): string =>
  `This command was not read as one that only appends the line linking ${covers.map(c => c.name).join(' or ')} to ${index}, ` +
  `which Dan's For good on saving ${covers.flatMap(c => c.files).join(', ')} lets through without asking him, so it was not let through. ` +
  `To add just that line, send the append as a command of its own, with nothing before or after it: ` +
  `printf '%s\\n' '<the line>' >> ${index}, echo '<the line>' >> ${index}, or cat >> ${index} fed a quoted heredoc, or add it with Edit; ` +
  `read the file back in a separate call. Only if it has to do more than add that line:`

/**
 * The rule Dan kept for this session only, from the question Claude asked: the plain words after the
 * file it names, without the question mark; the whole question when the file does not lead it.
 */
export const ruleOf = (question: string, files: string[]): string => {
  const q = question.trim().replace(/\?+$/, '').trim()
  for (const f of files) {
    const at = q.indexOf(f)
    if (at < 0) continue
    const rest = q.slice(at + f.length).replace(/^[^:]*:\s*/, '').trim()
    if (rest && rest !== q.slice(at + f.length).trim()) return rest
  }
  return q
}
