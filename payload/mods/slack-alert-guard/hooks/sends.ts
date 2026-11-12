// Which strings a Slack send carries (claude-config#2570), pure. Dan, 2026-11-09, asked to approve
// three lines a command line report prints: "these aren't alerts that are going to fire into Slack,
// right? If not, I don't need you to ask me for approval." The guard held every new sentence in a
// file that posts to Slack, or that a Slack sender imports: a route's 409 answer, a log line, a step's
// error text. This file traces, in JavaScript, TypeScript and python, which strings reach the
// arguments of a Slack send call, so only those are held.
//
// A send call is one whose callee a Slack marker names (the chat API's post call, a send helper named
// for Slack), is called on a value built from a Slack marker (a web client made with the bot token),
// is a function whose own body holds a send, or is the nearest call holding a Slack marker in its
// arguments (a fetch to the webhook address). A string reaches a send when it stands in that call's
// arguments, or in the value of a name used there, followed through every name the value uses in
// turn: a variable, a constant, a function whose body builds the text, an array a line is pushed
// onto. Names are matched by spelling within the block that declares them, so two locals of one name
// in different functions are told apart; anything the reading cannot tell apart is counted as
// reaching the send, never left out. This file's own source holds no marker (rules.ts, MARKERS).
// A file that only names what it matches, as a gate naming the endpoints it refuses does, holds no
// send at all (rules.ts, sendMarks, #2662), so the pattern it matches by is never read as one.

import { MARKERS, type Range, sendMarks, tokenRanges } from './rules.ts'

/** The text spans of a file: its strings (formatted: a template literal or an f-string, whose fields are code) and its comments. */
export type Spans = { strings: (Range & { formatted?: boolean })[]; comments: Range[] }

/** A JavaScript or TypeScript file's spans, as rules.ts reads its strings; a template literal is formatted. */
export const jsSpans = (text: string): Spans => {
  const { strings, comments } = tokenRanges(text, false)
  return { strings: strings.map(s => ({ ...s, formatted: text[s.from - 1] === '`' })), comments }
}

/** A python file's spans, from mod-kit's python text reader. */
export const pySpans = (spans: { kind: string; from: number; to: number }[]): Spans => ({
  strings: spans.filter(s => s.kind !== 'comment').map(s => ({ from: s.from, to: s.to, formatted: s.kind === 'formatted' })),
  comments: spans.filter(s => s.kind === 'comment').map(s => ({ from: s.from, to: s.to })),
})

/** A send call: what it calls, and the line it is on (from 1). */
export type Send = { callee: string; line: number }

/**
 * A file read for its sends: its text, the same with comments blanked (code), and with string
 * insides blanked too (skel), a template's or f-string's fields kept, so a name is never read out
 * of a sentence. Every character stays where it was.
 */
export type Reading = { text: string; code: string; skel: string; python: boolean }

const KEYWORDS = new Set(
  [
    ...['if', 'for', 'while', 'switch', 'catch', 'return', 'function', 'typeof', 'instanceof', 'with', 'elif', 'and', 'or', 'not', 'in', 'is'],
    ...['lambda', 'yield', 'await', 'async', 'new', 'delete', 'void', 'const', 'let', 'var', 'def', 'class', 'import', 'from', 'export', 'as'],
    ...['else', 'try', 'finally', 'raise', 'throw', 'do', 'of', 'case', 'default', 'break', 'continue', 'pass', 'global', 'nonlocal'],
    ...['true', 'false', 'null', 'undefined', 'None', 'True', 'False', 'this', 'self', 'super'],
  ],
)
// Names that stand for the object a method is called on, which a callee may start with.
const OWNERS = new Set(['this', 'self', 'super'])

// The fields of a formatted string, as positions in the file: ${...} in a template literal, {...} in
// an f-string, never {{ or an escaped \${.
const fields = (text: string, s: Range, python: boolean): Range[] => {
  const out: Range[] = []
  let i = s.from
  while (i < s.to) {
    if (python && text[i] === '{' && text[i + 1] === '{') {
      i += 2
      continue
    }
    const opens = python ? text[i] === '{' : text[i] === '$' && text[i + 1] === '{' && text[i - 1] !== '\\'
    if (!opens) {
      i++
      continue
    }
    const from = i + (python ? 1 : 2)
    let depth = 1
    let j = from
    while (j < s.to) {
      if (text[j] === '{') depth++
      else if (text[j] === '}' && --depth === 0) break
      j++
    }
    out.push({ from, to: j })
    i = j + 1
  }
  return out
}

export const readingOf = (text: string, python: boolean, spans: Spans): Reading => {
  const chars = text.split('')
  for (const c of spans.comments) for (let i = c.from; i < c.to && i < chars.length; i++) if (chars[i] !== '\n') chars[i] = ' '
  const code = chars.join('')
  for (const s of spans.strings) {
    const keep = s.formatted ? fields(text, s, python) : []
    for (let i = s.from; i < s.to && i < chars.length; i++) if (chars[i] !== '\n' && !keep.some(k => i >= k.from && i < k.to)) chars[i] = ' '
    // A quoted string inside a kept field is still a sentence, never names.
    for (const k of keep)
      for (const m of text.slice(k.from, k.to).matchAll(/"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'/g))
        for (let i = k.from + (m.index ?? 0) + 1; i < k.from + (m.index ?? 0) + m[0].length - 1; i++) chars[i] = ' '
  }
  return { text, code, skel: chars.join(''), python }
}

const OPEN: Record<string, true> = { '(': true, '[': true, '{': true }
const CLOSE: Record<string, true> = { ')': true, ']': true, '}': true }

/** Where the bracket opened at `at` closes in the skeleton, or the end of the text when it never does. */
const closeOf = (skel: string, at: number): number => {
  let depth = 0
  for (let i = at; i < skel.length; i++) {
    const c = skel[i] as string
    if (OPEN[c]) depth++
    else if (CLOSE[c] && --depth === 0) return i
  }
  return skel.length
}

/** The first index of a sorted list whose value is at least `v` (the list's length when none is). */
const atLeast = (sorted: readonly number[], v: number): number => {
  let lo = 0
  let hi = sorted.length
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    if ((sorted[mid] as number) < v) lo = mid + 1
    else hi = mid
  }
  return lo
}

/**
 * What a reading is searched by, worked out once for it (#2719): where each name stands as a whole
 * word, where a line ends, and where a destructuring can start. On 2026-11-10 every edit to a 5,488
 * line monitor route was held as not searched in time, because each name's declarations were found
 * by searching the whole file once per name, so the time grew with the square of the file. A name's
 * patterns are now tried only where the name stands, which finds exactly what the whole search did.
 */
type Index = {
  /** Each identifier, with every place it starts that no word character comes right before, in order. */
  words: Map<string, number[]>
  /** Where each line of the text starts after the first, for the line a send is on. */
  newlines: number[]
  /** Where a destructuring can start, in order (const or let or var and a bracket; in python every line start), and the first place each one's pattern can no longer reach. */
  starts: number[]
  reach: number[]
}
const indexes = new WeakMap<Reading, Index>()
const indexOf = (r: Reading): Index => {
  const known = indexes.get(r)
  if (known) return known
  const words = new Map<string, number[]>()
  for (const m of r.skel.matchAll(/[A-Za-z_$][\w$]*/g)) {
    const at = m.index ?? 0
    if (/[\w$]/.test(r.skel[at - 1] ?? '')) continue
    const list = words.get(m[0])
    if (list) list.push(at)
    else words.set(m[0], [at])
  }
  const newlines: number[] = []
  for (let i = r.text.indexOf('\n'); i >= 0; i = r.text.indexOf('\n', i + 1)) newlines.push(i)
  const starts: number[] = []
  const reach: number[] = []
  if (r.python) {
    // A line start, as the pattern's ^ reads one in multiline mode, and the end of the run of
    // characters its target list can be written in, past which it needs an equals sign.
    // A run that carries on over a line start ends where it ended for the line before.
    const lines = [0, ...[...r.skel.matchAll(/[\n\r\u2028\u2029]/g)].map(m => (m.index ?? 0) + 1)]
    let j = 0
    for (const i of lines) {
      if (j < i) j = i
      while (j < r.skel.length && /[\w.\s,]/.test(r.skel[j] as string)) j++
      starts.push(i)
      reach.push(j)
    }
  } else {
    // A pattern starting at a const, let or var reaches no further than the first = or ; after it.
    for (const m of r.skel.matchAll(/\b(?=(?:const|let|var)\s*[{[])/g)) {
      const at = m.index ?? 0
      const eq = r.skel.indexOf('=', at)
      const semi = r.skel.indexOf(';', at)
      starts.push(at)
      reach.push(Math.min(eq < 0 ? r.skel.length : eq, semi < 0 ? r.skel.length : semi))
    }
  }
  const index = { words, newlines, starts, reach }
  indexes.set(r, index)
  return index
}

const lineOf = (ix: Index, at: number): number => atLeast(ix.newlines, at) + 1

// The searching matchesAt has done (#2719): a whole text or slice searched counts its length, and
// each start tried counts one. The searches for names are where tracing a file grew with its square,
// so the count measures that work on any machine, however loaded.
let scanned = 0
/** The searching done so far: characters searched whole, plus starts tried (#2719). */
export const scanWork = (): number => scanned

/**
 * The matches a global search of `text` for `source` finds, as matchAll finds them, tried only at
 * `starts` (ascending), every place one can begin: a match starting inside the one before it is
 * passed over, as the global search passes it. With no starts the whole text is searched. Within
 * `inside`, the search is of that part alone, as a search of its slice is: a match running past its
 * end is tried again on the slice, which ends there.
 *
 * `tail`, for a pattern that is a whole word name then the rest: every start is already that name as
 * a whole word (`skip` long), so only the rest is tried, after it, by one sticky pattern made once,
 * rather than one pattern made for every name in the file. Every search is counted in `scanned`.
 */
const matchesAt = (
  text: string,
  source: string,
  flags: string,
  starts: readonly number[] | undefined,
  inside?: Range,
  tail?: { re: RegExp; skip: number },
): { at: number; end: number }[] => {
  const base = inside?.from ?? 0
  if (!starts) {
    const part = inside ? text.slice(inside.from, inside.to) : text
    scanned += part.length
    return [...part.matchAll(new RegExp(source, `${flags}g`))].map(m => ({ at: base + (m.index ?? 0), end: base + (m.index ?? 0) + m[0].length }))
  }
  if (!starts.length) return []
  const re = tail?.re ?? new RegExp(source, `${flags}y`)
  const skip = tail?.skip ?? 0
  const out: { at: number; end: number }[] = []
  let part: string | undefined
  let last = base
  for (const s of starts) {
    if (s < last) continue
    scanned++
    re.lastIndex = s + skip
    let end = re.exec(text) ? re.lastIndex : -1
    // The slice also differs at its start, where nothing comes before a match (a tail's caller has
    // already placed the name there as the slice reads it), and at its end, where nothing comes after
    // one, so a lookahead past an = there passes on the slice alone.
    if (inside && (end > inside.to || (!tail && s === inside.from) || text[inside.to - 1] === '=')) {
      part ??= text.slice(inside.from, inside.to)
      re.lastIndex = s + skip - inside.from
      end = re.exec(part) ? inside.from + re.lastIndex : -1
    }
    if (end < 0) continue
    out.push({ at: s, end })
    last = end
  }
  return out
}

// A name can be found only where it stands, so an identifier's patterns are tried there alone; any
// other name is searched for over the whole text, as before.
const IDENTIFIER = /^[A-Za-z_$][\w$]*$/
const wordsAt = (ix: Index, name: string): number[] | undefined => (IDENTIFIER.test(name) ? (ix.words.get(name) ?? []) : undefined)

/** Where the value starting at `from` ends: a semicolon, a comma or a closing bracket at its own depth, or a line ending that does not carry on. */
const valueEnd = (r: Reading, from: number): number => {
  const s = r.skel
  let depth = 0
  for (let i = from; i < s.length; i++) {
    const c = s[i] as string
    if (OPEN[c]) depth++
    else if (CLOSE[c]) {
      if (depth === 0) return i
      depth--
    } else if (depth === 0 && (c === ';' || c === ',')) return i
    else if (depth === 0 && c === '\n') {
      const before = s.slice(from, i).trimEnd()
      if (!before) continue
      const last = before[before.length - 1] as string
      const first = /\S/.exec(s.slice(i + 1))?.[0] ?? ''
      if (r.python ? last !== '\\' : !/[=+\-*/%&|,(?:[{>]/.test(last) && !/[.?:+\-*/%&|,=]/.test(first)) return i
    }
  }
  return s.length
}

// A python def's or class's body runs to the next line, not blank, indented no deeper than its head.
const pyBodyEnd = (skel: string, from: number, indent: number): number => {
  let i = skel.indexOf('\n', from)
  if (i < 0) return skel.length
  // The head can run over lines inside its brackets.
  const bracket = skel.indexOf('(', from)
  if (bracket >= 0 && bracket < i) {
    const after = skel.indexOf('\n', closeOf(skel, bracket))
    if (after < 0) return skel.length
    i = Math.max(i, after)
  }
  for (;;) {
    const next = skel.indexOf('\n', i + 1)
    const line = skel.slice(i + 1, next < 0 ? skel.length : next)
    if (line.trim() && (/^[ \t]*/.exec(line)?.[0].length ?? 0) <= indent) return i + 1
    if (next < 0) return skel.length
    i = next
  }
}

/** The block a position sits in: in python, the body of the def or class holding it; otherwise the innermost brace pair; the whole file at the top. */
type Blocks = (at: number) => Range
const blocksOf = (r: Reading): Blocks => {
  const whole = { from: 0, to: r.skel.length }
  const ranges: Range[] = []
  if (r.python) {
    for (const m of r.skel.matchAll(/^([ \t]*)(?:async[ \t]+)?(?:def|class)[ \t]+\w+/gm)) ranges.push({ from: m.index ?? 0, to: pyBodyEnd(r.skel, m.index ?? 0, (m[1] as string).length) })
  } else {
    for (let i = 0; i < r.skel.length; i++) if (r.skel[i] === '{') ranges.push({ from: i, to: closeOf(r.skel, i) + 1 })
  }
  // Each place asked about is worked out once, since a file's declarations ask about many (#2719).
  const seen = new Map<number, Range>()
  return at => {
    const known = seen.get(at)
    if (known) return known
    let best: Range = whole
    for (const b of ranges) if (at >= b.from && at < b.to && b.to - b.from < best.to - best.from) best = b
    seen.set(at, best)
    return best
  }
}

type Call = { callee: string; at: number; open: number; close: number }
type Fn = { name: string; body: Range }
const CALL = /(?<![\w$])([A-Za-z_$][\w$]*(?:\s*\??\.\s*[A-Za-z_$][\w$]*)*)\s*\(/g
const METHOD_BODY = /\s*(?::\s*[^{;=\n]+)?\{/y

/** Every call in a file, and every function written with a head that looks like one (def f(, function f(, a method's head), told apart. */
const callsOf = (r: Reading): { calls: Call[]; fns: Fn[] } => {
  const calls: Call[] = []
  const fns: Fn[] = []
  for (const m of r.skel.matchAll(CALL)) {
    const callee = (m[1] as string).replace(/\s+/g, '')
    const at = m.index ?? 0
    const open = at + m[0].length - 1
    const first = callee.split(/\??\./)[0] as string
    if (KEYWORDS.has(first) && !OWNERS.has(first)) continue
    const close = closeOf(r.skel, open)
    const before = r.skel.slice(Math.max(0, at - 24), at)
    if (/\bclass\s+$/.test(before)) continue
    if (r.python) {
      if (/\bdef\s+$/.test(before)) {
        const lineStart = r.skel.lastIndexOf('\n', at) + 1
        const indent = /^[ \t]*/.exec(r.skel.slice(lineStart, at))?.[0].length ?? 0
        fns.push({ name: callee, body: { from: close + 1, to: pyBodyEnd(r.skel, at, indent) } })
        continue
      }
    } else {
      if (/\bfunction\s*\*?\s*$/.test(before)) {
        const brace = r.skel.indexOf('{', close)
        if (brace >= 0) fns.push({ name: callee, body: { from: brace, to: closeOf(r.skel, brace) + 1 } })
        continue
      }
      // A method's head, as `async notify(text) {` is: a call's shape with a body after it. Read
      // where it stands rather than from a copy of the rest of the file, once for every call (#2719).
      METHOD_BODY.lastIndex = close + 1
      const body = METHOD_BODY.exec(r.skel)
      if (body && !callee.includes('.')) {
        const brace = close + body[0].length
        fns.push({ name: callee, body: { from: brace, to: closeOf(r.skel, brace) + 1 } })
        continue
      }
    }
    calls.push({ callee, at, open, close })
  }
  return { calls, fns }
}

const escape = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const word = (name: string) => `(?<![\\w$])${escape(name)}(?![\\w$])`
// What follows a name given a value (= += ||= and the like, never == => <= or !=), a name a method is
// called on, and a name whose member is set; each also made once as a sticky pattern, tried after a
// name already found standing as a whole word (matchesAt).
const ASSIGNED = `\\s*(?::[^=\\n;,()]*)?(?:\\+|-|\\*|\\|\\||\\?\\?|&&)?=(?![=>])`
const CALLED = `\\s*\\??\\.\\s*[A-Za-z_$][\\w$]*\\s*\\(`
const SET = `\\s*(?:\\.\\s*[\\w$]+|\\[[^\\]\\n]*\\])+\\s*(?:\\+|-|\\|\\||\\?\\?)?=(?![=>])`
const ASSIGNED_TAIL = new RegExp(ASSIGNED, 'y')
const CALLED_TAIL = new RegExp(CALLED, 'y')
const SET_TAIL = new RegExp(SET, 'y')

/** Where a name is given a value (a declaration, an assignment, a destructuring, a function), with the value's span and the block it is seen in. */
type Def = { at: number; value: Range; scope: Range }
const defsOf = (r: Reading, name: string, blocks: Blocks, fns: Fn[]): Def[] => {
  const out: Def[] = []
  const s = r.skel
  const ix = indexOf(r)
  const at = wordsAt(ix, name)
  const add =(at: number, from: number, to: number, scopeAt = at) => out.push({ at, value: { from, to }, scope: blocks(scopeAt) })
  // name = value, name += value, const name: T = value, self.name = value; never ==, =>, <= or !=.
  for (const m of matchesAt(s, `${word(name)}${ASSIGNED}`, '', at, undefined, { re: ASSIGNED_TAIL, skip: name.length })) add(m.at, m.end, valueEnd(r, m.end))
  // const { a, name } = value, const [a, name] = value, python a, name = value. One can start only
  // where a destructuring can (indexOf) and still reach a place the name stands.
  const destructure = r.python
    ? `^[ \\t]*(?:[\\w.]+\\s*,\\s*)+${escape(name)}\\s*(?:,\\s*[\\w.]+\\s*)*=(?!=)|^[ \\t]*${escape(name)}\\s*(?:,\\s*[\\w.]+\\s*)+=(?!=)`
    : `\\b(?:const|let|var)\\s*[{[][^=;]*${word(name)}[^=;]*[}\\]]\\s*=(?![=>])`
  let starts: number[] | undefined
  if (at) {
    const found = new Set<number>()
    for (const q of at) {
      // In python the name may open the line (start at most q); otherwise it follows the keyword.
      for (let i = atLeast(ix.starts, r.python ? q + 1 : q) - 1; i >= 0 && (ix.reach[i] as number) > q; i--) found.add(ix.starts[i] as number)
    }
    starts = [...found].sort((a, b) => a - b)
  }
  for (const m of matchesAt(s, destructure, r.python ? 'm' : '', starts)) add(m.at, m.end, valueEnd(r, m.end))
  // A function's body is its value, seen in the block around its head.
  for (const f of fns) if (f.name === name) add(f.body.from, f.body.from, f.body.to, Math.max(0, f.body.from - 1))
  return out
}

// Where a value is added to after it is made: name.push(...), name.append(...), name.x = ..., name[k] = ....
// Searched within `within` alone, as a search of its slice is, so a name standing first in it counts
// whatever comes before it in the file.
const changesOf = (r: Reading, name: string, within: Range): Range[] => {
  const out: Range[] = []
  const words = wordsAt(indexOf(r), name)
  let at: number[] | undefined
  if (words) {
    at = words.slice(atLeast(words, within.from), atLeast(words, within.to))
    // At the slice's start nothing comes before the name, so it stands there as a whole word
    // whatever the file has before it, when no word character follows it inside the slice.
    const after = within.from + name.length
    if (at[0] !== within.from && after < within.to && r.skel.startsWith(name, within.from) && !/[\w$]/.test(r.skel[after] ?? '')) at.unshift(within.from)
  }
  const tail = (re: RegExp) => ({ re, skip: name.length })
  for (const m of matchesAt(r.skel, `${word(name)}${CALLED}`, '', at, within, tail(CALLED_TAIL))) {
    const open = m.end - 1
    out.push({ from: open + 1, to: closeOf(r.skel, open) })
  }
  for (const m of matchesAt(r.skel, `${word(name)}${SET}`, '', at, within, tail(SET_TAIL))) out.push({ from: m.end, to: valueEnd(r, m.end) })
  return out
}

/** The names a stretch of the skeleton uses, each with where it stands. */
const namesIn = (r: Reading, span: Range): { name: string; at: number }[] => {
  const out: { name: string; at: number }[] = []
  for (const m of r.skel.slice(span.from, span.to).matchAll(/[A-Za-z_$][\w$]*/g)) {
    const at = span.from + (m.index ?? 0)
    if (/[\w$]/.test(r.skel[at - 1] ?? '')) continue
    if (!KEYWORDS.has(m[0]) || OWNERS.has(m[0])) out.push({ name: m[0], at })
  }
  return out
}

// Where a file's code names a Slack send: none in a file that only names what it matches (#2662).
const markerPositions = (r: Reading): number[] => sendMarks(r.python ? 'python' : 'js', r.code)

/**
 * The nearest call holding `at` in its arguments, never crossing a function or block body on the
 * way out: a marker inside a route handler that a framework call wraps does not make that whole
 * handler a send.
 */
const nearestCall = (r: Reading, calls: Call[], at: number): Call | undefined => {
  let best: Call | undefined
  for (const c of calls) if (at > c.open && at < c.close && (!best || c.open > best.open)) best = c
  if (!best) return undefined
  return /=>|\)\s*\{|\bfunction\b|\blambda\b|:\s*\n/.test(r.skel.slice(best.open, at)) ? undefined : best
}

export type Traced = {
  /** Every send call the file makes. */
  sends: Send[]
  /** The stretches whose strings reach a send, each with the send it reaches. */
  spans: (Range & { send: Send })[]
}

/** What in a file reaches a Slack send: its own sends, and the stretches whose strings they carry. */
export const trace = (r: Reading): Traced => {
  const { defsFor, changesFor, sendCalls, namesAt } = analysisOf(r)
  // Which calls send is worked out once for each text (#2796) and only read here.
  const { sending } = sendCalls()

  const ix = indexOf(r)
  const send = (c: Call): Send => ({ callee: c.callee, line: lineOf(ix, c.at) })
  const spans: Traced['spans'] = []
  const done = new Set<string>()
  const todo: (Range & { send: Send })[] = [...sending].map(c => ({ from: c.open + 1, to: c.close, send: send(c) }))
  const follow = (name: string, at: number, s: Send) => {
    for (const d of defsFor(name)) {
      // A declaration counts where it can be seen from the use: its block holds the use.
      if (!(at >= d.scope.from && at < d.scope.to)) continue
      const key = `${name}@${d.at}`
      if (done.has(key)) continue
      done.add(key)
      todo.push({ ...d.value, send: s })
      for (const ch of changesFor(name, d.scope)) todo.push({ ...ch, send: s })
    }
  }
  // Whether a stretch lies inside one already followed, asked of every stretch: the furthest end of
  // any followed stretch starting at or before it, kept in a tree by where each starts (#2719).
  const furthest = new Int32Array(r.skel.length + 3).fill(-1)
  const covered = (s: Range) => {
    let m = -1
    for (let i = Math.min(s.from + 1, furthest.length - 1); i > 0; i -= i & -i) m = Math.max(m, furthest[i] as number)
    return m >= s.to
  }
  const followed = (s: Range) => {
    for (let i = s.from + 1; i < furthest.length; i += i & -i) furthest[i] = Math.max(furthest[i] as number, s.to)
  }
  while (todo.length) {
    const span = todo.pop() as Range & { send: Send }
    if (covered(span)) continue
    spans.push(span)
    followed(span)
    for (const u of namesAt(span)) follow(u.name, u.at, span.send)
  }
  return { sends: [...sending].map(send), spans }
}

/**
 * Everything trace reads of a file, worked out once for each text (#2719), so a text traced again
 * reuses it. Kept for the last ANALYSED texts, by the text and its reading, so it is only ever
 * reused for the same file.
 */
type Analysis = {
  defsFor: (name: string) => Def[]
  changesFor: (name: string, within: Range) => Range[]
  /** The calls that send, in the order found. */
  sendCalls: () => { sending: ReadonlySet<Call> }
  /** The names a stretch of the skeleton uses, read once for each stretch (#2796). */
  namesAt: (span: Range) => { name: string; at: number }[]
}
const ANALYSED = 8
const analyses = new Map<string, { r: Reading; a: Analysis }>()
const analysisOf = (r: Reading): Analysis => {
  const key = `${r.python ? 'p' : 'j'}${r.text}`
  const known = analyses.get(key)
  if (known && known.r.skel === r.skel && known.r.code === r.code) {
    analyses.delete(key)
    analyses.set(key, known)
    return known.a
  }
  const a = analyse(r)
  analyses.delete(key)
  analyses.set(key, { r, a })
  if (analyses.size > ANALYSED) analyses.delete(analyses.keys().next().value as string)
  return a
}

const analyse = (r: Reading): Analysis => {
  const { calls, fns } = callsOf(r)
  const blocks = blocksOf(r)
  const all = namesIn(r, { from: 0, to: r.skel.length })
  const distinct = [...new Set(all.map(n => n.name))]
  const defCache = new Map<string, Def[]>()
  const defsFor = (name: string): Def[] => {
    let d = defCache.get(name)
    if (!d) defCache.set(name, (d = defsOf(r, name, blocks, fns)))
    return d
  }

  // Names whose value is built from a Slack marker: a webhook address, a client made with the bot token.
  // What each declaration's value holds is read once, however many times the names are gone over (#2719).
  const markers = markerPositions(r)
  const sortedMarkers = [...markers].sort((a, b) => a - b)
  const holdsMarker = (v: Range) => (sortedMarkers[atLeast(sortedMarkers, v.from)] ?? Infinity) < v.to
  const valueNames = new Map<Def, string[]>()
  const namesOfValue = (d: Def): string[] => {
    let n = valueNames.get(d)
    if (!n) valueNames.set(d, (n = namesIn(r, d.value).map(u => u.name)))
    return n
  }
  const marked = new Set<string>()
  for (let grew = true; grew; ) {
    grew = false
    for (const name of distinct) {
      if (marked.has(name)) continue
      if (defsFor(name).some(d => holdsMarker(d.value) || namesOfValue(d).some(u => marked.has(u)))) {
        marked.add(name)
        grew = true
      }
    }
  }

  // A marker, or a marked name used anywhere but where it is given its value.
  const points = [...markers, ...all.filter(n => marked.has(n.name) && !defsFor(n.name).some(d => d.at === n.at)).map(n => n.at)]
  const arrow = /^\s*(?:async\s*)?(?:\([^)]*\)|[\w$]+)\s*(?::[^=]*)?=>|^\s*(?:async\s+)?function\b|^\s*lambda\b/
  // Each declaration read once for whether its value is a function, and each point's call found once,
  // since neither changes while sends are added (#2719).
  const arrows = new Map<Def, boolean>()
  const isArrow = (d: Def): boolean => {
    let a = arrows.get(d)
    if (a === undefined) arrows.set(d, (a = arrow.test(r.skel.slice(d.value.from, d.value.to))))
    return a
  }
  const pointCalls = points.map(p => nearestCall(r, calls, p))
  // Where each name is added to within a block, once for each name and block.
  const changes = new Map<string, Range[]>()
  const changesFor = (name: string, within: Range): Range[] => {
    const key = `${name}@${within.from}:${within.to}`
    let c = changes.get(key)
    if (!c) changes.set(key, (c = changesOf(r, name, within)))
    return c
  }

  // Which calls send, grown until nothing more is found: a call to a Slack marker, a send function
  // or a marked name; a call holding a marker; a function whose own body sends, written as a function
  // or as an arrow given to a name. Worked out once for each text and kept (#2796): on 2026-11-11 the
  // same answer was worked out 82 times over, half of a 3.5 s check.
  let found: { sending: ReadonlySet<Call> } | undefined
  const sendCalls = () => {
    if (found) return found
    const sending = new Set<Call>()
    const sendFns = new Set<string>()
    const last = (callee: string) => callee.split(/\??\./).pop() as string
    const head = (callee: string) => callee.split(/\??\./)[0] as string
    const sendCallee = (callee: string) => MARKERS.some(m => m.test(`${callee}(`)) || sendFns.has(callee) || sendFns.has(last(callee)) || marked.has(head(callee))
    for (let grew = true; grew; ) {
      grew = false
      for (const c of calls)
        if (!sending.has(c) && sendCallee(c.callee)) {
          sending.add(c)
          grew = true
        }
      for (const c of pointCalls) {
        if (c && !sending.has(c)) {
          sending.add(c)
          grew = true
        }
      }
      const sendAts = [...sending].map(c => c.at).sort((a, b) => a - b)
      const holds = (b: Range) => (sendAts[atLeast(sendAts, b.from)] ?? Infinity) < b.to
      for (const f of fns)
        if (!sendFns.has(f.name) && holds(f.body)) {
          sendFns.add(f.name)
          grew = true
        }
      for (const name of distinct)
        if (!sendFns.has(name) && defsFor(name).some(d => isArrow(d) && holds(d.value))) {
          sendFns.add(name)
          grew = true
        }
    }
    found = { sending }
    return found
  }
  // A followed stretch's names, read once for each stretch, since the file as it was and as the edit
  // leaves it follow the same stretches of their sends' arguments and declarations (#2796).
  const spanNames = new Map<string, { name: string; at: number }[]>()
  const namesAt = (span: Range) => {
    const key = `${span.from}:${span.to}`
    let n = spanNames.get(key)
    if (!n) spanNames.set(key, (n = namesIn(r, span)))
    return n
  }
  return { defsFor, changesFor, sendCalls, namesAt }
}

/**
 * The python strings that are docstrings (#2574): a string standing alone as the first statement of
 * the module, or of a def's or class's body. It documents the code and is never sent anywhere, so it
 * is never message text, even where the guard cannot trace a file's sends.
 */
export const docstrings = (r: Reading, strings: Range[]): Set<number> => {
  const out = new Set<number>()
  if (!r.python) return out
  for (const s of strings) {
    let q = s.from
    while (q > 0 && s.from - q < 3 && /["']/.test(r.text[q - 1] ?? '')) q--
    while (q > 0 && s.from - q < 5 && /[rRuUbB]/.test(r.text[q - 1] ?? '')) q--
    // Alone on its statement: nothing but space after it to the line's end.
    const close = r.text.slice(s.to, s.to + 3).match(/^("""|'''|"|')/)?.[0].length ?? 0
    const end = r.code.indexOf('\n', s.to + close)
    if (r.code.slice(s.to + close, end < 0 ? r.code.length : end).trim()) continue
    const before = r.skel.slice(0, q).trimEnd()
    if (!before) {
      out.add(s.from)
      continue
    }
    if (!before.endsWith(':')) continue
    // The logical line the colon ends, read back past any bracket a signature spans.
    let depth = 0
    let i = before.length - 1
    for (; i >= 0; i--) {
      const c = before[i] as string
      if (CLOSE[c]) depth++
      else if (OPEN[c]) depth--
      else if (c === '\n' && depth <= 0) break
    }
    if (/^\s*(?:async\s+)?(?:def|class)\b/.test(before.slice(i + 1))) out.add(s.from)
  }
  return out
}

/** The send the string whose text starts at `start` reaches, if any. */
export const sentAt = (t: Traced, start: number): Send | undefined => t.spans.find(s => start >= s.from && start < s.to)?.send
