// Ask before saving (claude-config#618): what counts as lasting memory, when Dan's own words already
// made a rule permanent, and what Claude is told to ask in Claude Code's own dialog (#777). Pure, so
// each rule is tested on its own.
import type { AskBeforeSavingApproval } from '../types/index.d.ts'

export const MOD = 'ask-before-saving'

// What a command writes, as mod-kit's contract spells it (types/index.d.ts there): plain data, since
// only plain data crosses between mods.
export type Writes = { files: { word: string; path?: string }[]; unnamed: { what: string; words: string[]; inputs: string[]; targets?: string[] }[] }

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
 * `F=<path>` included (#743). One that mentions none goes through (docs/mods-design.md).
 */
export const lastingFiles = async (w: Writes, home: string, inCheckout: InCheckout, command: string, isSet: IsSet = ALWAYS_SET): Promise<string[]> => {
  const out: string[] = []
  const add = (s: string) => {
    if (!out.includes(s)) out.push(s)
  }
  let mentions: string[] | undefined
  for (const f of w.files) {
    const byName = !f.path && NAMES.has(f.word.split('/').pop() ?? '') && (await throughSettable(f.word, command, isSet))
    const hit = f.path ? (await lastingMemory(f.path, home, inCheckout)) && display(f.path, home) : byName && f.word
    if (hit) add(hit)
    // A target through a variable that can hold no path, one only a fresh temporary file sets or
    // nothing sets at all, reaches no lasting memory, so what the command mentions is not read for it
    // (#830: an issue body written to `$(mktemp)` named a memory path).
    else if (unread(f) && (await throughSettable(f.word, command, isSet))) for (const m of (mentions ??= await mentioned(command, home, inCheckout, isSet))) add(m)
  }
  return out
}

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

// A lasting memory file named in a script's or a patch's text: a path ending in one of the names,
// or one through a project's memory folder, ending where the shell ends a word (#743: the ; after
// `F=<memory folder>/MEMORY.md;` was shown as part of the file).
const MENTION = /[~\w.\/$-]*\.claude\/projects\/[^\/\s'";&|()<>`]+\/memory(?:\/[^\s'";&|()<>`]*)?|(?:[~\w.\/$-]*\/)?(?:CLAUDE|AGENTS|MEMORY|LESSONS)\.md\b/g

/**
 * The lasting memory a write's text mentions, for the writes whose words name no file (a patch, an
 * inline script): each as written, home shown as ~, a diff's a/ or b/ taken off, an absolute path
 * judged where it lands. One in a temporary folder counts inside a checkout there, or when it is
 * built from a variable and so cannot be looked for.
 */
export const mentioned = async (text: string, home: string, inCheckout: InCheckout, isSet: IsSet = ALWAYS_SET): Promise<string[]> => {
  const out: string[] = []
  for (const m of text.match(MENTION) ?? []) {
    if (!(await throughSettable(m, text, isSet))) continue
    let p = m.replace(/^[ab]\//, '')
    if (p.startsWith('/') || p.startsWith('~/') || p.startsWith('$HOME/') || p.startsWith('${HOME}/')) p = resolvePath(p, '/', home)
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

// The durable lesson check's picker (#867). payload/hooks/durable-lesson-check.sh tells Claude to ask
// with this `metadata.source` and the rule in `metadata.rule`; its suite holds the two to these names.
// Dan's "Add to LESSONS.md", read from the dialog's own result, approves the write that adds that rule
// to the lessons file, so he is not asked For good about it a second time (Dan, 2026-10-06: "The
// confirmation that I want to add the durable lesson should be enough to indicate that I want to add
// it forever."). Nothing Claude writes approves it: the mod sets the answers, refuses a call carrying
// its own, and reads only the answer the dialog hands back.
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

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/**
 * The text a write to the lessons file adds, when all it does is add: an Edit whose new text keeps
 * the text it replaces, or a Write whose content is the old file with one block inserted in one place
 * (lessons review of #869: a Write judged by whether each old line survived anywhere let a dropped
 * duplicate or a reordering count as adding). Anything that also removes or rewrites (replace_all
 * included) is no lesson being added, and gets undefined.
 */
export const lessonAddition = (tool: string, input: Record<string, unknown>, old: string | undefined): string | undefined => {
  if (tool === 'Edit') {
    const from = String(input.old_string ?? '')
    const to = String(input.new_string ?? '')
    if (input.replace_all === true || !from || !to.includes(from)) return undefined
    return to.replace(from, '')
  }
  if (tool !== 'Write') return undefined
  const content = String(input.content ?? '')
  if (old === undefined) return content
  if (content.length < old.length) return undefined
  // What the two share at the start, then at the end, never counting a character twice: the old
  // file must be exactly those two pieces, so the rest of the new one is a single inserted block.
  let head = 0
  while (head < old.length && old[head] === content[head]) head++
  let tail = 0
  while (tail < old.length - head && old[old.length - 1 - tail] === content[content.length - 1 - tail]) tail++
  return head + tail === old.length ? content.slice(head, content.length - tail) : undefined
}

/**
 * Whether the added text is exactly that one lesson (lessons review of #869: anything else written
 * beside the rule reached every session unseen by Dan): one new entry, `- **L<n>.` then the rule as
 * he approved it (bold and wrapping aside), then at most its provenance (repo#N, then a date), then at most
 * one SHORT line whose index line, `- L<n>. <short>`, is within the index's cap. Blank lines around it
 * are the file's spacing.
 */
export const addsLesson = (added: string, rule: string): boolean => {
  const lines = added.replace(/^\s*\n/, '').replace(/\s+$/, '').split('\n')
  const shortAt = lines.findIndex(l => /^\s*SHORT:/.test(l))
  if (shortAt !== -1 && (shortAt !== lines.length - 1 || shortAt === 0)) return false
  const body = ruleText((shortAt === -1 ? lines : lines.slice(0, shortAt)).join('\n'))
  // Provenance is its shape and nothing more, one or more `repo#N` (owner qualified or not) and an
  // optional date (lessons reviews of #869: any text in parentheses let a sentence Dan never read
  // ride along, and `owner/repo#N` is a provenance too).
  const ref = String.raw`(?:[\w.-]+\/)?[\w.-]+#\d+`
  const provenance = String.raw`(?: \(${ref}(?:, ${ref})*(?:, \d{4}-\d{2}-\d{2})?\))?`
  const m = new RegExp(`^- L(\\d+)\\. ${escapeRe(ruleText(rule))}${provenance}$`).exec(body)
  if (!m) return false
  if (shortAt === -1) return true
  // Counted as the index renders it, `- L<n>. <short>` (third lessons review of #869).
  return `- L${m[1]}. ${(lines[shortAt] ?? '').replace(/^\s*SHORT:\s*/, '')}`.length <= MAX_SHORT
}

/**
 * What Claude is told when a save to lasting memory is refused: ask Dan in Claude Code's own dialog,
 * naming the file and stating the rule in plain words (#777, Dan: "I don't really know what it's
 * asking"), and on For good send the same call again.
 */
export const askInstruction = (id: string, files: string[]): string => {
  const where = files.join(', ')
  return (
    `Not saved yet: this writes lasting memory (${where}), so Dan decides first. ` +
    `Ask him now with AskUserQuestion: one question, with metadata {"source": "${sourceOf(id)}"}, that names ${where} and states the rule in one plain sentence, never the command or the raw text, ` +
    `such as "Save to ${files[0]} for good: <the rule>?", with the options ${FOR_GOOD}, ${THIS_SESSION} and ${NOT_AT_ALL}. ` +
    `If he answers ${FOR_GOOD}, send this same call again unchanged and it is saved. Until he answers, do not write it any other way.`
  )
}

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
