// Ask before saving (claude-config#618): what counts as lasting memory, when Dan's own words already
// made a rule permanent, and the question the band shows. Pure, so each rule is tested on its own.

export const MOD = 'ask-before-saving'

// The band row, as mod-kit's contract spells it (types/index.d.ts there): plain data, since only
// plain data crosses between mods.
type Text = { text: string; color?: string; bold?: boolean; dim?: boolean; indent?: number }
type Button = { button: string; label: string; hotkey?: string }
type Line = (Text | Button)[] | { divider: true }
export type QuestionRow = { mod: string; id: string; slot: 'question'; lines: Line[] }

// The lasting memory the spec names: the memory folder, MEMORY.md, ~/.claude/CLAUDE.md, LESSONS.md,
// and a project's CLAUDE.md or AGENTS.md. By file name for the last four, so a project or the config
// repository's own payload copy is caught wherever it lives.
const NAMES = new Set(['MEMORY.md', 'CLAUDE.md', 'AGENTS.md', 'LESSONS.md'])

export const lastingMemory = (abs: string, home: string): boolean => {
  const name = abs.split('/').pop() ?? ''
  if (NAMES.has(name)) return true
  const projects = `${home.replace(/\/$/, '')}/.claude/projects/`
  if (!abs.startsWith(projects)) return false
  // <home>/.claude/projects/<project>/memory/<anything>
  const rest = abs.slice(projects.length).split('/')
  return rest.length >= 3 && rest[1] === 'memory'
}

/** A path as the shell or a tool would reach it: home spelled out, relative to cwd, dot segments gone. */
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

// The words the spec says make a rule permanent in Dan's own message, as whole words.
const PERMANENT = /\b(from now on|always|never|remember)\b/i
export const madePermanent = (prompt: string | null | undefined): boolean => typeof prompt === 'string' && PERMANENT.test(prompt)

// A redirect writes its target: >, >>, >|, with a descriptor (1>, 2>>) or &> before it, the target
// attached or as the next word. A descriptor target (&1) or /dev/null writes no file.
const REDIRECT = /^(?:\d*|&)(>>|>\||>)(.*)$/
const notAFile = (t: string) => t === '' || t.startsWith('&') || t === '/dev/null'

/**
 * The files a Bash call would write, from the simple commands mod-kit's reader gives (each its words
 * with quotes removed): redirects, tee, cp and mv's destination, and sed or perl editing in place.
 */
export const bashTargets = (cmds: string[][]): string[] => {
  const out: string[] = []
  for (const words of cmds) {
    for (let i = 0; i < words.length; i++) {
      const m = REDIRECT.exec(words[i] as string)
      if (!m) continue
      const t = m[2] !== '' ? (m[2] as string) : (words[++i] ?? '')
      if (!notAFile(t)) out.push(t)
    }
    const name = (words[0] ?? '').split('/').pop()
    const args = words.slice(1).filter(w => !REDIRECT.test(w))
    if (name === 'tee') out.push(...args.filter(w => !w.startsWith('-')))
    if (name === 'cp' || name === 'mv') {
      const plain = args.filter(w => !w.startsWith('-'))
      if (plain.length >= 2) out.push(plain[plain.length - 1] as string)
    }
    // In place: sed -i (with or without a suffix), perl -i or -pi. The last word is the file edited.
    const inPlace = name === 'sed' ? args.some(w => /^-i/.test(w) || w === '--in-place') : name === 'perl' ? args.some(w => /^-[a-z]*i/.test(w)) : false
    if (inPlace && args.length) out.push(args[args.length - 1] as string)
  }
  return out
}

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

/** Lines of at most `width` characters, broken between words; a word longer than a line is cut. */
export const wrap = (text: string, width: number): string[] => {
  const out: string[] = []
  for (const para of text.split('\n')) {
    let line = ''
    for (let word of para.split(/\s+/).filter(Boolean)) {
      while (word.length > width) {
        if (line) out.push(line)
        line = ''
        out.push(word.slice(0, width))
        word = word.slice(width)
      }
      if (!word) continue
      if (!line) line = word
      else if (line.length + 1 + word.length <= width) line += ` ${word}`
      else {
        out.push(line)
        line = word
      }
    }
    out.push(line)
  }
  return out
}

// The band truncates a line at its edge, so the rule is wrapped before it is published, since a row
// is published before any band width is known. 76 columns is a choice, not a measurement: a band
// narrower than that still cuts the line (mod-kit has no wrapping text run yet).
export const WIDTH = 76

/** The three answers, with the button id their press arrives under. */
export const ANSWERS = [
  { button: 'for-good', label: 'For good', hotkey: '1' },
  { button: 'this-session', label: 'Just this session', hotkey: '2' },
  { button: 'not-at-all', label: 'Not at all', hotkey: '3' },
] as const
export type Answer = (typeof ANSWERS)[number]['button']

/**
 * The question in the band (docs/mods-design.md, Ask before saving): the chip and the question on
 * one amber line, then the rule's exact text and the file it would go to, set off by grey rules,
 * then each answer on its own line with what it does indented under it (picker manners' layout).
 */
export const questionRow = (q: { id: string; text: string; files: string[] }): QuestionRow => {
  const where = q.files.join(', ')
  const does: Record<Answer, string> = {
    'for-good': `Saved to ${where}`,
    'this-session': 'Kept until this session ends; nothing is written',
    'not-at-all': 'Nothing is saved',
  }
  return {
    mod: MOD,
    id: 'question',
    slot: 'question',
    lines: [
      [
        { text: 'Standing rule', color: 'warning', bold: true },
        { text: '  Save this as a standing rule?', color: 'warning' },
      ],
      { divider: true },
      ...wrap(q.text, WIDTH).map(l => [{ text: l }]),
      [{ text: where, dim: true }],
      { divider: true },
      ...ANSWERS.flatMap(a => [[{ button: a.button, label: a.label, hotkey: a.hotkey }], [{ text: does[a.button], dim: true, indent: 4 }]]),
    ],
  }
}
