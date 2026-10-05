// Ask before saving (claude-config#618): what counts as lasting memory, when Dan's own words already
// made a rule permanent, and the question the band shows. Pure, so each rule is tested on its own.

export const MOD = 'ask-before-saving'

// The question and what a command writes, as mod-kit's contract spells them (types/index.d.ts
// there): plain data, since only plain data crosses between mods.
type Text = { text: string; color?: string; bold?: boolean; dim?: boolean; indent?: number; wrap?: true }
type Line = Text[] | { divider: true }
export type Question = {
  mod: string
  id: string
  chip: string
  question: string
  body: Line[]
  options: { button: string; label: string; description: string }[]
}
export type Writes = { files: { word: string; path?: string }[]; unnamed: { what: string; words: string[]; inputs: string[] }[] }

// The lasting memory the spec names: the memory folder, MEMORY.md, ~/.claude/CLAUDE.md, LESSONS.md,
// and a project's CLAUDE.md or AGENTS.md. By file name for the last four, so a project or the config
// repository's own payload copy is caught wherever it lives.
const NAMES = new Set(['MEMORY.md', 'CLAUDE.md', 'AGENTS.md', 'LESSONS.md'])

// A file in a temporary folder (a backup copy, a test fixture in the session's scratchpad) is loaded
// into no session, so it is no lasting memory whatever it is called.
const TEMP = /^(?:\/private)?\/(?:tmp|var\/folders)(?:\/|$)/

export const lastingMemory = (abs: string, home: string): boolean => {
  if (TEMP.test(abs)) return false
  const name = abs.split('/').pop() ?? ''
  if (NAMES.has(name)) return true
  const projects = `${home.replace(/\/$/, '')}/.claude/projects/`
  if (!abs.startsWith(projects)) return false
  // <home>/.claude/projects/<project>/memory, or anything in it: a copy into the folder names it.
  const rest = abs.slice(projects.length).split('/')
  return rest.length >= 2 && rest[1] === 'memory'
}

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

/**
 * The lasting memory among the files a command's words name (mod-kit's $.modkit.writes): judged by
 * path where the words name one, by file name where they do not (a path built from a variable).
 */
export const lastingFiles = (w: Writes, home: string): string[] => {
  const out: string[] = []
  for (const f of w.files) {
    const hit = f.path ? lastingMemory(f.path, home) && display(f.path, home) : !TEMP.test(f.word) && NAMES.has(f.word.split('/').pop() ?? '') && f.word
    if (hit && !out.includes(hit)) out.push(hit)
  }
  return out
}

// A lasting memory file named in a script's or a patch's text: a path ending in one of the names,
// or one through a project's memory folder.
const MENTION = /[~\w.\/$-]*\.claude\/projects\/[^\/\s'"]+\/memory(?:\/[^\s'"]*)?|(?:[~\w.\/$-]*\/)?(?:CLAUDE|AGENTS|MEMORY|LESSONS)\.md\b/g

/**
 * The lasting memory a write's text mentions, for the writes whose words name no file (a patch, an
 * inline script): each as written, home shown as ~, a diff's a/ or b/ taken off.
 */
export const mentioned = (text: string, home: string): string[] => {
  const out: string[] = []
  for (const m of text.match(MENTION) ?? []) {
    let p = m.replace(/^[ab]\//, '')
    if (p.startsWith('~/') || p.startsWith('$HOME/') || p.startsWith('${HOME}/')) p = resolvePath(p, '/', home)
    if (TEMP.test(p)) continue
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

/** The three answers, with the button id their press arrives under (before the save's own id). */
export const ANSWERS = [
  { button: 'for-good', label: 'For good' },
  { button: 'this-session', label: 'Just this session' },
  { button: 'not-at-all', label: 'Not at all' },
] as const
export type Answer = (typeof ANSWERS)[number]['button']

/** The band row a save's question is drawn as, under its own id. */
export const rowId = (id: string) => `question:${id}`

/**
 * The question in the band (docs/mods-design.md, Ask before saving), as mod-kit's question builder
 * takes it: the chip and the question, then the rule's exact text, wrapping at the band's edge, and
 * the file it would go to, set off by grey rules, then each answer with what it does under it. The
 * row and each button carry the save's id, so a press answers only the save it was drawn for (L243).
 */
export const questionOf = (q: { id: string; text: string; files: string[] }): Question => {
  const where = q.files.join(', ')
  const does: Record<Answer, string> = {
    'for-good': `Saved to ${where}`,
    'this-session': 'Kept until this session ends; nothing is written',
    'not-at-all': 'Nothing is saved',
  }
  return {
    mod: MOD,
    id: rowId(q.id),
    chip: 'Standing rule',
    question: 'Save this as a standing rule?',
    body: [{ divider: true }, ...q.text.split('\n').map((l): Line => [{ text: l, wrap: true }]), [{ text: where, dim: true }], { divider: true }],
    options: ANSWERS.map(a => ({ button: `${a.button}:${q.id}`, label: a.label, description: does[a.button] })),
  }
}
