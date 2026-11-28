// Text a person approves in a picker (#3321): the one check of whether Dan would read what an
// AskUserQuestion call hands the dialog as it is written. His answer covers text because he read
// it, so a guard that records his answer first puts the whole call through askFault and refuses a
// picker that fails, before he is asked anything. Built for the lesson picker in #3295 and moved
// here unchanged, so every guard is held to the same character classes, the same length and height
// limits and the same hidden markup: the dialog cuts every question at the same place whichever
// guard asks it, so there is one set of limits and no looser one for a guard whose text is long.
// Pure. Kept here once and copied byte for byte into each mod that asks it
// (hooks/mod-kit/shown.ts, which tools/check-mod-shared-parts.sh holds to this one, and which
// fails a mod that reads a picker's answer without calling askFault), since a mod cannot import
// another mod's files. The words "rule", "check line" and "lessons file" below are the lesson
// picker's, whose measurements these comments record.

/**
 * A line of the lessons file without its indentation: the spaces and tabs at its two ends, and
 * nothing else. The language's own trim also takes a byte order mark, a no break space and the line
 * and paragraph separators, so a check line carrying one of those at an end compared equal to the
 * line Dan read (security review of #3245).
 */
export const unindented = (s: string): string => s.replace(/^[ \t]+/, '').replace(/[ \t]+$/, '')

// What Dan cannot see (#3295). His answer in a picker covers text because he read it, so the text a
// picker shows him, and the entry written under his answer, hold no character that is drawn as
// nothing, that moves or hides the text around it, or that reads as a plain space and is not one.
// A rule is prose and quotes real text, so unlike a check line it is not held to ASCII: every
// letter, mark and symbol of any alphabet stands. What is refused is a class, by Unicode's own
// properties, so a character nobody listed is still in it:
// - every control but the newline (Cc: the tab, the carriage return, the escape that starts a
//   terminal sequence, the C1 controls),
// - every format character (Cf: the zero width ones, the bidirectional controls, the tag block, the
//   soft hyphen, the byte order mark),
// - private use, surrogate halves and code points no character is assigned to (Co, Cs, Cn; a
//   character newer than the engine's Unicode tables reads as unassigned, and is refused),
// - every space but the plain one, and the line and paragraph separators (Zs, Zl, Zp),
// - whatever else is drawn as nothing by default (Default_Ignorable_Code_Point: the variation
//   selectors, the Hangul fillers, the combining grapheme joiner), and the blank braille pattern,
//   which no property covers.
// Claude Code's own dialog puts a replacement mark over most of the same class (read in 2.1.328 on
// 2026-11-19), which shows Dan that something is there and not what, while the text written is the
// character itself. The class is written as property escapes and one code point by number, so the
// source holds none of the characters it refuses.
const UNSEEN = new RegExp(String.raw`[^\P{C}\n]|[^\P{Z} ]|\p{Default_Ignorable_Code_Point}|` + String.fromCodePoint(0x2800), 'u')

const within = (p: number, ...ranges: [number, number][]) => ranges.some(([from, to]) => p >= from && p <= to)

/** A refused character in words, for the session that must find it and reword: the commonest by name, the rest by kind. */
const unseenName = (c: string): string => {
  const p = c.codePointAt(0) ?? 0
  const named: Record<number, string> = {
    0x09: 'a tab',
    0x0d: 'a carriage return',
    0x1b: 'the escape character, which starts a terminal escape sequence',
    0xa0: 'a no break space',
    0xad: 'a soft hyphen',
    0x200b: 'a zero width space',
    0x200c: 'a zero width non joiner',
    0x200d: 'a zero width joiner',
    0x2028: 'a line separator',
    0x2029: 'a paragraph separator',
    0xfeff: 'a byte order mark',
  }
  const name = named[p]
  if (name !== undefined) return name
  if (p === 0x61c || within(p, [0x200e, 0x200f], [0x202a, 0x202e], [0x2066, 0x2069])) return 'a bidirectional control'
  if (within(p, [0xe0000, 0xe007f])) return 'a tag character'
  if (within(p, [0xfe00, 0xfe0f], [0xe0100, 0xe01ef])) return 'a variation selector'
  if (/\p{Cc}/u.test(c)) return 'a control character'
  if (/\p{Cf}/u.test(c)) return 'a format character, which is drawn as nothing'
  if (/\p{Co}/u.test(c)) return 'a private use character'
  if (/\p{Cs}/u.test(c)) return 'half of a surrogate pair'
  if (/\p{Cn}/u.test(c)) return 'a code point no character is assigned to'
  if (/\p{Zs}/u.test(c)) return 'a space that is not the plain one'
  return 'a character drawn as nothing'
}

/**
 * The first character of `s` Dan cannot see (the class above), or undefined when he can read all of
 * it: `at` is its place counted in characters from 1, `code` its code point, `what` its name or
 * kind, and `after` the visible text of its own line just before it, at most 24 characters, empty
 * at the start of a line.
 *
 * The spaces and tabs at the two ends of a line are the text's indentation and are not judged, as
 * around a check line (unindented): a wrapped rule is indented in the lessons file, by either. A tab
 * anywhere else is refused, since the dialog draws it as a space and the file would hold the tab.
 */
export const unseenIn = (s: string): { at: number; code: string; what: string; after: string } | undefined => {
  let start = 0
  for (const line of s.split('\n')) {
    const lead = /^[ \t]*/.exec(line)?.[0].length ?? 0
    const m = UNSEEN.exec(unindented(line))
    if (m) {
      const index = start + lead + m.index
      const code = (m[0].codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, '0')
      return { at: Array.from(s.slice(0, index)).length + 1, code: `U+${code}`, what: unseenName(m[0]), after: Array.from(line.slice(0, lead + m.index).replace(/^[ \t]+/, '')).slice(-24).join('') }
    }
    start += line.length + 1
  }
  return undefined
}

// Markup (#3295, security review). Claude Code's typings for plugins say of the AskUserQuestion
// dialog "Markdown on those three alone", the desktop, VS Code and mobile surfaces (read in 2.1.328
// on 2026-11-19, not seen drawn), and the terminal draws a model's question as plain text. So what
// a surface drawing markdown or HTML does not draw as its text is refused wherever the picker is
// drawn (L648), as a class and not by its spellings:
// - "<" before a letter, "!", "?" or "/": a tag, whose name and attribute text are not drawn, a
//   comment, a declaration, a processing instruction, a CDATA section, an autolink;
// - "]" before "(" or "[": an inline link or an image, whose address and title are not drawn, and a
//   reference link; and "]:", a link definition or a footnote, which is not drawn at all. Every
//   link, image and definition needs one of the three pairs, whatever its label, address or title holds;
// - a character reference ("&nbsp;", "&#8203;"), drawn as another character, which can be one of
//   the class unseenIn refuses.
// Not in the class, by choice: marks that restyle text and hide none of it (emphasis, a heading, a
// list, a quote, a table, a backslash before punctuation), and whatever a surface adds beyond
// markdown and HTML (mathematics between dollar signs, say), which was not read.
const HTML_TAG = /<[A-Za-z!?\/]/
const MD_LINK = /\][(\[]/
const MD_DEFINITION = /\]:/
const CHAR_REFERENCE = /&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);/
// The one link Claude Code's terminal dialog draws as its label alone (read in 2.1.328: a bracket
// pair before a parenthesis pair whose address starts file:///, in its own confirmations).
const FILE_LINK = /\]\(file:/i

/**
 * `s` with the text inside each code span replaced by filler of the same length, so a place in the
 * result is the same place in `s`; or `s` itself when it holds no span every reading agrees on.
 *
 * A surface that draws markdown draws the text of a code span as written, and the terminal draws
 * it plain with its backticks, so markup inside one hides nothing, and code is how a rule names a
 * tag, a placeholder or a call on an indexed value (measured 2026-11-19: of the 895 rules in the
 * lessons file, the one holding any of the class, L731, holds it in a code span). Spans are paired
 * as CommonMark pairs them, a run of backticks closed by the next run of the same length, and read
 * strictly, toward judging the text (L648), because a span this reads and a surface does not is a
 * way to hide words:
 * - within one line only, and when any run in the whole text has no partner on its own line no
 *   span is taken anywhere: a span a surface closes on a later line pairs the runs after it another way;
 * - none anywhere when a backslash stands before a backtick, which a surface reads as a plain backtick;
 * - a span holding "|" is not taken, since a table splits its row into cells at every "|" before
 *   any code span is made out.
 * A link definition is made out before any code span too, so "]:" is judged in the text as it
 * stands (markupIn), never here.
 */
const outsideCode = (s: string): string => {
  if (!s.includes('`') || s.includes('\\`')) return s
  const out: string[] = []
  for (const line of s.split('\n')) {
    const runs = [...line.matchAll(/`+/g)]
    let masked = ''
    let done = 0
    for (let i = 0; i < runs.length; i++) {
      const open = runs[i]
      const j = runs.findIndex((r, k) => k > i && r[0].length === open?.[0].length)
      const close = runs[j]
      if (open === undefined || close === undefined) return s
      const from = (open.index ?? 0) + open[0].length
      const to = close.index ?? 0
      const inside = line.slice(from, to)
      masked += line.slice(done, from) + (inside.includes('|') ? inside : 'x'.repeat(inside.length))
      done = to
      i = j
    }
    out.push(masked + line.slice(done))
  }
  return out.join('\n')
}

const CODE_STANDS = '. Code in backticks on one line is drawn as written, so quote it that way or reword it (a span holding "|" or "]:" is still judged, since a table or a link definition is made out before any code is)'

/**
 * The first markup in `s` that a surface drawing markdown or HTML would not draw as its text (the
 * class above), in words for the session that sent it, or undefined. Text inside a code span is
 * not judged (outsideCode), but for a link definition and a link to a file.
 */
const markupIn = (s: string): string | undefined => {
  const code = outsideCode(s)
  const kinds: [RegExp, string, string][] = [
    [HTML_TAG, code, `which a surface that draws HTML takes for a tag or a comment and does not draw${CODE_STANDS}`],
    [MD_LINK, code, `which a surface that draws markdown takes for a link, an image or a link definition and draws as less than its text${CODE_STANDS}`],
    [MD_DEFINITION, s, `which a surface that draws markdown takes for a link, an image or a link definition and draws as less than its text${CODE_STANDS}`],
    [CHAR_REFERENCE, code, `which a surface that draws markdown draws as another character${CODE_STANDS}`],
    [FILE_LINK, s, 'a link to a file, which the terminal dialog can draw as its label alone'],
  ]
  let first: { index: number; shown: string; why: string } | undefined
  for (const [re, text, why] of kinds) {
    const m = re.exec(text)
    if (!m || (first !== undefined && first.index <= m.index)) continue
    // A tag and a link are shown up to the next white space, the rest as they matched.
    const shown = re === HTML_TAG || re === MD_LINK ? (/^\S{1,30}/.exec(s.slice(m.index))?.[0] ?? m[0]) : s.slice(m.index, m.index + m[0].length)
    first = { index: m.index, shown, why }
  }
  if (first === undefined) return undefined
  return `it holds ${JSON.stringify(first.shown)} at character ${Array.from(s.slice(0, first.index)).length + 1}, ${first.why}`
}

/**
 * The longest text a picker of this mod's hands the dialog, in UTF-16 code units, the unit the
 * dialog cuts in. Dan answers for text he read, and Claude Code's dialog cuts a question at 2,000
 * of these and ends it with an ellipsis (read in 2.1.328 on 2026-11-19: the question is sliced to
 * 2,000 before it is drawn), so a rule or a check line past the cut was approved unread. The cap
 * sits under the cut with room for a surface that shows less. Measured the same day: the longest
 * rule in the lessons file was 565 and a check line is at most MAX_CHECK, and of the picker calls
 * in the transcripts this Mac kept, the longest lesson question of 9 was 753 and the longest memory
 * question of 177 was 462.
 */
export const MAX_QUESTION = 1500

/**
 * The width text above a picker's answers is wrapped at when its rows are counted (rowsAt): 80
 * columns, which is what Apple Terminal opens at (its Basic profile, this Mac's default on
 * 2026-11-19, sets no size of its own), less the 4 cells Claude Code's dialog keeps back from the
 * boxes it draws (read in 2.1.328: `columns - 4`). A wider window wraps less, so rows counted here
 * are the most a window of 80 columns or more draws.
 */
export const QUESTION_COLUMNS = 76

/**
 * The most rows the text above a picker's answers may take, wrapped at QUESTION_COLUMNS (security
 * review of #3295: a question was held to MAX_QUESTION and to no number of rows, so a rule, 1,200
 * newlines and then another sentence was asked and approved with the rule 1,200 rows above the
 * answers). Claude Code's dialog neither cuts nor scrolls a tall question (read in 2.1.328: the
 * row limit it is handed locks a least height and nothing more; not seen drawn), so whatever does
 * not fit the window is above its top edge.
 *
 * 20 is what MAX_QUESTION already allows running prose at that width (1,500 / 76 rounds up to
 * 20), so this takes nothing from a question the length cap let through as prose, and stops the
 * tall and thin one. It bounds how far above the answers a word can stand. It does not put the
 * whole question in view: with the dialog's own rows (about 16 with three answers, an estimate
 * from the dialog as drawn, not read row by row) a question at the cap fills a window of 36 rows,
 * and a window of 24 shows its last 8 or so.
 */
export const MAX_QUESTION_ROWS = 20

/**
 * The rows `s` takes in a window `columns` wide: one for each line, and one more each time a line
 * runs past the width, words kept whole where they fit. Counted toward more rows wherever a
 * terminal could differ (L648): a character outside ASCII takes two columns, as the widest do; a
 * tab takes eight; spaces are never dropped at a wrap; and a word that does not fit starts a row.
 */
export const rowsAt = (s: string, columns: number = QUESTION_COLUMNS): number => {
  let rows = 0
  for (const line of s.split('\n')) {
    rows++
    let col = 0
    for (const piece of line.split(/( +)/)) {
      let width = 0
      for (const c of piece) width += c === '\t' ? 8 : (c.codePointAt(0) ?? 0) > 0x7e ? 2 : 1
      // A word that does not fit beside what the row holds starts the next; spaces fill on.
      if (col > 0 && col + width > columns && !piece.startsWith(' ')) {
        rows++
        col = 0
      }
      const more = Math.max(0, Math.ceil((col + width) / columns) - 1)
      rows += more
      col = col + width - more * columns
    }
  }
  return rows
}

const tooTall = (rows: number): string =>
  `it takes ${rows} rows in a window ${QUESTION_COLUMNS} columns wide, and text is asked only up to ${MAX_QUESTION_ROWS} rows, so that no part of it is far above the answers`

const BLANK = /^[ \t]*$/

/**
 * Why Dan would not read text as it is written, in words for the session that sent it, or undefined
 * when he would (#3295). The one function every text a picker hands the dialog is judged by: the
 * rule, the question, and each field beside it (askFault). The first found of:
 * - a character he cannot see (unseenIn), named by its code point and its place;
 * - more than MAX_QUESTION code units, past which the dialog cuts;
 * - markup a surface other than the terminal hides or redraws (markupIn), in the text as it is
 *   sent and with its bold marks dropped, which is how a rule is stored, compared and written
 *   (ruleText): marks set inside "<!--" or between a link's two halves once let both be written whole;
 * - two blank lines one after the other, which push what stands above them away from the answers
 *   (one blank line between paragraphs is how a question is laid out);
 * - more than MAX_QUESTION_ROWS rows (rowsAt).
 * A place is counted in characters, which are code points, and a length in UTF-16 code units, each
 * under its own name.
 *
 * Measured 2026-11-19 over the 895 rules of the lessons file and the 186 picker calls in the
 * transcripts this Mac kept: none is refused.
 */
export const shownFault = (s: string): string | undefined => {
  const unseen = unseenIn(s)
  if (unseen) return `character ${unseen.at} of it is ${unseen.code}, ${unseen.what}, ${unseen.after ? `right after ${JSON.stringify(unseen.after)}` : 'at the start of its line'}`
  if (s.length > MAX_QUESTION) return `it is ${s.length} UTF-16 code units, and the dialog shows text whole only up to ${MAX_QUESTION}`
  const markup = markupIn(s)
  if (markup !== undefined) return markup
  const stored = s.replace(/\*\*/g, '')
  const unmarked = stored === s ? undefined : markupIn(stored)
  if (unmarked !== undefined) return `with its bold marks dropped, as it is stored, ${unmarked}`
  const lines = s.split('\n')
  const second = lines.findIndex((l, k) => k > 0 && BLANK.test(l) && BLANK.test(lines[k - 1] ?? 'x'))
  if (second !== -1) return `lines ${second} and ${second + 1} of it are both blank, and a run of blank lines pushes what stands above it away from the answers`
  const rows = rowsAt(s)
  return rows > MAX_QUESTION_ROWS ? tooTall(rows) : undefined
}

// The fields of an AskUserQuestion call that are never drawn: the engine's own, the metadata (its
// rule, its check line and its SHORT line have their own checks, and its source is for analytics alone), and
// answers already filled in, which are refused whatever they hold.
const NOT_DRAWN = new Set(['tool', 'tool_use_id', 'agentId', 'requestMeta', 'metadata', 'answers'])
// The fields of a question that are the dialog's own rows, the chip over it and the answers under
// it: judged like any text, and not counted with the rows above the answers.
const DIALOG_ROWS = new Set(['header', 'options', 'multiSelect'])

/**
 * Why a picker's call would not reach Dan as written, as what is at fault and why (shownFault), or
 * undefined. Every text the call hands the dialog is judged, in whatever field and however deep
 * (security review of #3295: a title, a description and a placeholder beside the question went to
 * the dialog unjudged), so it is given the call as the dialog will get it, with the mod's own
 * header and answers in place. The rows of everything above the answers are counted together, so
 * a description cannot add the rows a question may not take.
 *
 * `files` are the names the save is for. A file's own name is the mod's to show, in the question
 * and in the answers, so one that would itself be refused is set aside before the text around it
 * is judged, or its save could never be asked about at all (L665).
 */
export const askFault = (ask: Record<string, unknown>, files: readonly string[] = []): { what: string; fault: string } | undefined => {
  const odd = files.filter(f => f !== '' && shownFault(f) !== undefined)
  const aside = (text: string) => odd.reduce((t, f) => t.split(f).join('x'.repeat(f.length)), text)
  const texts = (v: unknown): string[] => (typeof v === 'string' ? [v] : Array.isArray(v) ? v.flatMap(texts) : typeof v === 'object' && v !== null ? Object.values(v).flatMap(texts) : [])
  const first: unknown = Array.isArray(ask.questions) ? ask.questions[0] : undefined
  const one = typeof first === 'object' && first !== null ? (first as Record<string, unknown>) : {}
  const question = typeof one.question === 'string' ? aside(one.question) : ''
  const fault = shownFault(question)
  if (fault !== undefined) return { what: 'The question', fault }
  let rows = rowsAt(question)
  const judged = (what: string, v: unknown, counted: boolean): { what: string; fault: string } | undefined => {
    for (const text of texts(v).map(aside)) {
      const why = shownFault(text)
      if (why !== undefined) return { what, fault: why }
      if (counted) rows += rowsAt(text)
    }
    return undefined
  }
  for (const [k, v] of Object.entries(one)) {
    const bad = k === 'question' ? undefined : judged(`Field ${JSON.stringify(k)} of the question`, v, !DIALOG_ROWS.has(k))
    if (bad !== undefined) return bad
  }
  for (const [k, v] of Object.entries(ask)) {
    const bad = NOT_DRAWN.has(k) ? undefined : judged(`Field ${JSON.stringify(k)}`, k === 'questions' && Array.isArray(v) ? v.slice(1) : v, true)
    if (bad !== undefined) return bad
  }
  return rows > MAX_QUESTION_ROWS ? { what: 'The question', fault: `with the other text sent beside it, ${tooTall(rows)}` } : undefined
}
