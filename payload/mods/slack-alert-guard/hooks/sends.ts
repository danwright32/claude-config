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

import { MARKERS, type Range, moduleSpecs, sendMarks, tokenRanges } from './rules.ts'

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

const lineOf = (text: string, at: number): number => {
  let n = 1
  for (let i = 0; i < at; i++) if (text[i] === '\n') n++
  return n
}

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
  return at => {
    let best: Range = whole
    for (const b of ranges) if (at >= b.from && at < b.to && b.to - b.from < best.to - best.from) best = b
    return best
  }
}

type Call = { callee: string; at: number; open: number; close: number }
type Fn = { name: string; body: Range }
const CALL = /(?<![\w$])([A-Za-z_$][\w$]*(?:\s*\??\.\s*[A-Za-z_$][\w$]*)*)\s*\(/g

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
      // A method's head, as `async notify(text) {` is: a call's shape with a body after it.
      const body = /^\s*(?::\s*[^{;=\n]+)?\{/.exec(r.skel.slice(close + 1))
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

/** Where a name is given a value (a declaration, an assignment, a destructuring, a function), with the value's span and the block it is seen in. */
type Def = { at: number; value: Range; scope: Range }
const defsOf = (r: Reading, name: string, blocks: Blocks, fns: Fn[]): Def[] => {
  const out: Def[] = []
  const s = r.skel
  const add = (at: number, from: number, to: number, scopeAt = at) => out.push({ at, value: { from, to }, scope: blocks(scopeAt) })
  // name = value, name += value, const name: T = value, self.name = value; never ==, =>, <= or !=.
  for (const m of s.matchAll(new RegExp(`${word(name)}\\s*(?::[^=\\n;,()]*)?(?:\\+|-|\\*|\\|\\||\\?\\?|&&)?=(?![=>])`, 'g'))) {
    const at = m.index ?? 0
    add(at, at + m[0].length, valueEnd(r, at + m[0].length))
  }
  // const { a, name } = value, const [a, name] = value, python a, name = value.
  const destructure = r.python
    ? new RegExp(`^[ \\t]*(?:[\\w.]+\\s*,\\s*)+${escape(name)}\\s*(?:,\\s*[\\w.]+\\s*)*=(?!=)|^[ \\t]*${escape(name)}\\s*(?:,\\s*[\\w.]+\\s*)+=(?!=)`, 'gm')
    : new RegExp(`\\b(?:const|let|var)\\s*[{[][^=;]*${word(name)}[^=;]*[}\\]]\\s*=(?![=>])`, 'g')
  for (const m of s.matchAll(destructure)) {
    const at = m.index ?? 0
    add(at, at + m[0].length, valueEnd(r, at + m[0].length))
  }
  // A function's body is its value, seen in the block around its head.
  for (const f of fns) if (f.name === name) add(f.body.from, f.body.from, f.body.to, Math.max(0, f.body.from - 1))
  return out
}

// Where a value is added to after it is made: name.push(...), name.append(...), name.x = ..., name[k] = ....
const changesOf = (r: Reading, name: string, within: Range): Range[] => {
  const out: Range[] = []
  const s = r.skel.slice(within.from, within.to)
  for (const m of s.matchAll(new RegExp(`${word(name)}\\s*\\??\\.\\s*[A-Za-z_$][\\w$]*\\s*\\(`, 'g'))) {
    const open = within.from + (m.index ?? 0) + m[0].length - 1
    out.push({ from: open + 1, to: closeOf(r.skel, open) })
  }
  for (const m of s.matchAll(new RegExp(`${word(name)}\\s*(?:\\.\\s*[\\w$]+|\\[[^\\]\\n]*\\])+\\s*(?:\\+|-|\\|\\||\\?\\?)?=(?![=>])`, 'g'))) {
    const from = within.from + (m.index ?? 0) + m[0].length
    out.push({ from, to: valueEnd(r, from) })
  }
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
  /** Every name the reached stretches use, with the send it reaches: what a file below this one is followed by. */
  names: Map<string, Send>
  /** The file's functions whose bodies send, so a call to one is a send. */
  fns: Set<string>
}

/**
 * What in a file reaches a Slack send: its own sends, `seeds` (names a file above it sends, so its
 * declarations of them are followed), and calls to `imported`, send functions it imports from a send
 * helper module.
 */
export const trace = (r: Reading, seeds: Map<string, Send> = new Map(), imported: Set<string> = new Set()): Traced => {
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
  const markers = markerPositions(r)
  const marked = new Set<string>()
  for (let grew = true; grew; ) {
    grew = false
    for (const name of distinct) {
      if (marked.has(name)) continue
      if (defsFor(name).some(d => markers.some(p => p >= d.value.from && p < d.value.to) || namesIn(r, d.value).some(u => marked.has(u.name)))) {
        marked.add(name)
        grew = true
      }
    }
  }

  const sending = new Set<Call>()
  const sendFns = new Set(imported)
  const last = (callee: string) => callee.split(/\??\./).pop() as string
  const head = (callee: string) => callee.split(/\??\./)[0] as string
  const sendCallee = (callee: string) => MARKERS.some(m => m.test(`${callee}(`)) || sendFns.has(callee) || sendFns.has(last(callee)) || marked.has(head(callee))
  // A marker, or a marked name used anywhere but where it is given its value.
  const points = [...markers, ...all.filter(n => marked.has(n.name) && !defsFor(n.name).some(d => d.at === n.at)).map(n => n.at)]
  const arrow = /^\s*(?:async\s*)?(?:\([^)]*\)|[\w$]+)\s*(?::[^=]*)?=>|^\s*(?:async\s+)?function\b|^\s*lambda\b/
  for (let grew = true; grew; ) {
    grew = false
    for (const c of calls)
      if (!sending.has(c) && sendCallee(c.callee)) {
        sending.add(c)
        grew = true
      }
    for (const p of points) {
      const c = nearestCall(r, calls, p)
      if (c && !sending.has(c)) {
        sending.add(c)
        grew = true
      }
    }
    // A function whose own body sends is a send: written as a function, or as an arrow given to a name.
    const holds = (b: Range) => [...sending].some(c => c.at >= b.from && c.at < b.to)
    for (const f of fns)
      if (!sendFns.has(f.name) && holds(f.body)) {
        sendFns.add(f.name)
        grew = true
      }
    for (const name of distinct)
      if (!sendFns.has(name) && defsFor(name).some(d => arrow.test(r.skel.slice(d.value.from, d.value.to)) && holds(d.value))) {
        sendFns.add(name)
        grew = true
      }
  }

  const send = (c: Call): Send => ({ callee: c.callee, line: lineOf(r.text, c.at) })
  const spans: Traced['spans'] = []
  const names = new Map<string, Send>()
  const done = new Set<string>()
  const todo: (Range & { send: Send })[] = [...sending].map(c => ({ from: c.open + 1, to: c.close, send: send(c) }))
  const follow = (name: string, at: number, s: Send) => {
    if (!names.has(name)) names.set(name, s)
    for (const d of defsFor(name)) {
      // A declaration counts where it can be seen from the use: its block holds the use. A name sent
      // from another file (at -1) is followed into every declaration of it.
      if (at >= 0 && !(at >= d.scope.from && at < d.scope.to)) continue
      const key = `${name}@${d.at}`
      if (done.has(key)) continue
      done.add(key)
      todo.push({ ...d.value, send: s })
      for (const ch of changesOf(r, name, d.scope)) todo.push({ ...ch, send: s })
    }
  }
  for (const [name, s] of seeds) follow(name, -1, s)
  while (todo.length) {
    const span = todo.pop() as Range & { send: Send }
    if (spans.some(v => v.from <= span.from && v.to >= span.to)) continue
    spans.push(span)
    for (const u of namesIn(r, span)) follow(u.name, u.at, span.send)
  }
  // A name renamed on import or export (import { A as B }, export { A as B }, import a as b) is known
  // to the file below by its first name.
  for (const m of r.skel.matchAll(/([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)/g)) {
    const s = names.get(m[2] as string)
    if (s && !names.has(m[1] as string)) names.set(m[1] as string, s)
  }
  return { sends: [...sending].map(send), spans, names, fns: sendFns }
}

/**
 * The names a file gives a whole module (import * as m, import m from, require, python import m),
 * each with the statement that names the module, for the caller to place.
 */
export const moduleBindings = (r: Reading): { name: string; statement: string }[] => {
  const out: { name: string; statement: string }[] = []
  const forms = r.python
    ? [/^[ \t]*import[ \t]+([\w.]+)(?:[ \t]+as[ \t]+(\w+))?/gm, /^[ \t]*from[ \t]+[\w.]+[ \t]+import[ \t]+(\w+)(?:[ \t]+as[ \t]+(\w+))?/gm]
    : [/\bimport\s+\*\s+as\s+([\w$]+)\s+from\s+["'][^"']+["']/g, /\bimport\s+([\w$]+)\s*(?:,\s*\{[^}]*\})?\s+from\s+["'][^"']+["']/g, /\b(?:const|let|var)\s+([\w$]+)\s*=\s*require\(\s*["'][^"']+["']\s*\)/g]
  for (const f of forms)
    for (const m of r.code.matchAll(f)) {
      const name = (m[2] ?? (m[1] as string).split('.')[0]) as string
      if (name !== 'type') out.push({ name, statement: m[0] })
    }
  return out
}

/** Whether a send reaches a whole module's name used whole (copy[key], render(copy)), rather than one of its names through it (copy.title). */
export const usedWhole = (r: Reading, t: Traced, name: string): boolean =>
  t.spans.some(s => [...r.skel.slice(s.from, s.to).matchAll(new RegExp(`${word(name)}(?!\\s*\\??\\.\\s*[A-Za-z_$])`, 'g'))].length > 0)

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

/**
 * The names a file's import and re-export statements bind or hand on (#2637): named, default and
 * whole module imports, a require or awaited import given to names, python's from and import lines.
 * A statement read too widely only adds names, which makes mayBringIn look more often, never less.
 * The names of a bare package ('react') are left out, in JavaScript and TypeScript: its text is in
 * no file of the repository the guard follows an import to (rules.ts, importTerms), and counting
 * them would run the search on every edit that calls a library once more.
 */
export const importedNames = (r: Reading): Set<string> => {
  const out = new Set<string>()
  const add = (clause: string) => {
    for (const m of clause.matchAll(/[A-Za-z_$][\w$]*/g)) if (!KEYWORDS.has(m[0]) && m[0] !== 'type') out.add(m[0])
  }
  const forms = r.python
    ? [/^[ \t]*from[ \t]+[\w.]+[ \t]+import[ \t]+(\([^)]*\)|[^\n]*)/gm, /^[ \t]*import[ \t]+([^\n]+)/gm]
    : [/(?<![\w$.])(?:import|export)\s+(?:type\s+)?([\w$\s,{}*]*?)\s*from(?=\s*["'`])/g, /(?<![\w$.])(?:const|let|var)\s+([\w$]+|\{[^}=]*\})\s*=\s*(?:await\s+)?(?:require|import)\s*\(/g]
  for (const f of forms)
    for (const m of r.skel.matchAll(f)) {
      // The module named, read from the code, since the skeleton blanks it. Anything but a quoted
      // bare package counts: a path, an alias, or a name worked out at run time.
      const named = r.python ? null : /^\s*(["'`])([^"'`\n]*)\1/.exec(r.code.slice((m.index ?? 0) + m[0].length))
      if (named && !(named[2] as string).startsWith('.') && !(named[2] as string).includes('/')) continue
      add(m[1] as string)
    }
  return out
}

/**
 * Whether an edit could bring another file's text to a Slack send that did not carry it before
 * (#2637), told from the edited file alone, before anything is searched: it imports a module it did
 * not, imports or hands on a name it did not, uses an imported name more often, or, in a file that
 * posts by itself, a send reaches a name it did not. An edit that only rewords a string, adds a
 * comment or changes code that touches no import brings nothing in, so no search is run for it.
 */
export const mayBringIn = (before: Reading, after: Reading): boolean => {
  const had = new Set(moduleSpecs(before.text))
  if (moduleSpecs(after.text).some(s => !had.has(s))) return true
  const uses = (r: Reading, name: string) => [...r.skel.matchAll(new RegExp(word(name), 'g'))].length
  const old = importedNames(before)
  for (const n of importedNames(after)) if (!old.has(n) || uses(after, n) > uses(before, n)) return true
  if (!markerPositions(after).length) return false
  const sent = trace(before).names
  return [...trace(after).names.keys()].some(n => !sent.has(n))
}
