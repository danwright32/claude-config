// Design round guard (claude-config#978): which files change how a screen looks, what an issue or
// branch is keyed by, and every sentence Claude and Dan read. Pure, so each rule is tested on its own.
import type { DesignRoundSubject } from '../types/index.d.ts'

export const GUARD = 'Design round guard'
/** The dialog's header chip; Claude Code takes at most 12 characters. */
export const HEADER = 'Design round'
/** `metadata.source` of the skip question, followed by `:<the refused call's id>`. */
export const SKIP_SOURCE = 'design-round-guard'
/** `metadata.source` of the design rounds skill's closing question (payload/skills/design-rounds/SKILL.md). */
export const SETTLED_SOURCE = 'design-settled'
// The two questions in the plan Dan approved on the issue, and the answers the guard sets on them.
export const SKIP_QUESTION = 'Skip design rounds for this issue?'
export const SETTLED_QUESTION = 'Is this design settled?'
export const SKIP_YES = 'Skip them'
export const SKIP_NO = 'Run /design-rounds'
export const SETTLED_YES = 'Settled'
export const SETTLED_NO = 'Not yet'
/** The skip question's third answer (#1010): this one refused edit changes nothing on screen. */
export const NOT_LOOK = 'Not a look change'

/**
 * The version of what this guard and the design rounds skill agree a question carries (#1057): its
 * metadata and what each key means. The skill is read fresh at every use and the guard only when a
 * session starts or the mod reloads, so the two can differ in a running session. The skill states
 * its version in `<!-- design-round-guard contract: N -->` and asks every question to carry it as
 * metadata `contract`; a guard meeting a newer one says it is older than the steps Claude read. Raise
 * both together whenever a question's metadata changes meaning (tests/test-mod-skill-contracts.sh
 * fails while they differ).
 * 1: #1046, Settled answering for what the refused call it names (`call`) waits on.
 * 2: #1138, the skip question carrying `onScreen`, the plain sentence Dan reads first.
 */
export const CONTRACT = 2
/** The skill this guard enforces, as installed under ~/.claude/skills. */
export const SKILL = 'design-rounds'

/** The contract a skill's text states (`<!-- design-round-guard contract: N -->`), or undefined for one stating none. */
export const contractOf = (text: string): number | undefined => {
  const m = /<!--\s*design-round-guard contract:\s*(\d+)\s*-->/.exec(text)
  return m ? Number(m[1]) : undefined
}

/** What Claude reads when the steps it followed are newer than the guard this session loaded (#1057). */
export const predates = (theirs: number): string =>
  `Blocked: this session's design round guard predates the design rounds steps you read (they follow version ${theirs} of its questions, it knows version ${CONTRACT}), so it would misread this answer and nothing was asked or recorded. ` +
  `Tell Dan, and start a new session, which loads the current guard; asking again here gets the same answer.`

// The plan's list (Dan, 2026-10-08): style files (CSS and its preprocessors, the Tailwind config,
// design tokens), screen and component files (.tsx, .jsx, .vue, .svelte, .html), and SwiftUI views.
// A logic only file in one of these shapes sometimes counts, which the plan accepts: Dan says skip.
const STYLE = new Set(['css', 'scss', 'sass', 'less', 'styl', 'pcss'])
const SCREEN = new Set(['tsx', 'jsx', 'vue', 'svelte', 'html', 'htm'])
const TAILWIND = /^tailwind\.config\.(js|cjs|mjs|ts|cts|mts)$/
const TOKENS = /^(design[-_.]?)?tokens(\.[\w-]+)*\.(json|jsonc|js|cjs|mjs|ts|css|scss)$|\.tokens\.json$/

export type LookKind = 'style' | 'screen' | 'tailwind' | 'tokens' | 'swift'

/**
 * Whether a path is a test file, by the usual markers (Dan, 2026-10-08, on seeing the guard: "On,
 * but let tests through"): a `.test.` or `.spec.` part in its name, or a `__tests__`, `tests` or
 * `test` folder above it; and for Swift, a test target's folder ending `Tests` or a name ending
 * `Tests.swift`. A name merely holding "test" (latest.tsx, contest.css) is no test.
 */
export const isTestPath = (path: string): boolean => {
  const parts = path.split('/').filter(Boolean)
  const base = parts.pop() ?? ''
  if (/\.(test|spec)\./i.test(base)) return true
  if (parts.some(p => p === '__tests__' || p === 'tests' || p === 'test')) return true
  if (/\.swift$/i.test(base)) return /Tests\.swift$/.test(base) || parts.some(p => /Tests$/.test(p))
  return false
}

// The session's scratchpad (#1191), as Claude Code hands every session one:
// <temp>/claude-<uid>/<project>/<session id>/scratchpad, where <temp> is CLAUDE_CODE_TMPDIR when it is
// set and /tmp otherwise (Claude Code's own default), each also in the /private spelling macOS gives
// /tmp and /var. Known by the session's own id, as `$.session.id()` gives it, and only under that
// temp folder: a folder shaped like it anywhere else, a checkout included, is any folder, since the
// session's id is no secret from Claude (lessons review of #1191). Another session's scratchpad, and
// a project folder merely called scratchpad, are not this one.
const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
/** The temp folders the session's scratchpad may be under, from Claude Code's CLAUDE_CODE_TMPDIR (#1191). */
export const tempRoots = (tmpdir: string | undefined): string[] => {
  const t = tmpdir?.trim().replace(/\/+$/, '')
  const root = t && t.startsWith('/') && !/(^|\/)\.\.?(\/|$)/.test(t) ? t : '/tmp'
  return /^\/(tmp|var)(\/|$)/.test(root) ? [root, `/private${root}`] : [root]
}
const scratchpadAt = (session: string, roots: readonly string[]): string =>
  `(?:${roots.map(esc).join('|')})/claude-\\d+/[^/\\n]+/${esc(session)}/scratchpad`

/**
 * Whether an absolute path is in the session's scratchpad, where a design round's working files go
 * (#1191): a file for choosing a design with, never a screen of the product.
 */
export const inScratchpad = (path: string, session: string, roots: readonly string[]): boolean =>
  session !== '' && roots.length > 0 && !/(^|\/)\.\.(\/|$)/.test(path) && new RegExp(`^${scratchpadAt(session, roots)}(?:/|$)`).test(path)

/** Whether a command's text names the session's scratchpad anywhere, quoted or not (#1191). */
export const namesScratchpad = (text: string, session: string, roots: readonly string[]): boolean =>
  session !== '' && roots.length > 0 && new RegExp(`(?<![^\\s'"=(:])${scratchpadAt(session, roots)}(?![\\w.-])`).test(text)

// Whether the text just before a name's `/` adds the name onto a folder held in a variable (#1194):
// an f-string's or a template's brace (`f"{root}/app/page.tsx"`) or a string added onto one
// (`root + "/app/page.tsx"`). The shell's `${R}/screen.css` is not: its folder is R's value, read by
// shellBraces (lessons review).
const addedOnto = (head: string): boolean => (/\}$/.test(head) && !SHELL_BRACE.test(head)) || /\+\s*[rRbBuUfF]{0,2}['"]$/.test(head)
const SHELL_BRACE = /\$\{([A-Za-z_]\w*)\}$/

/**
 * Whether every place a text spells a name that looks absolute (`/app/page.tsx`, as mentionedLookFiles
 * reads `f"{root}/app/page.tsx"` and `root + "/app/page.tsx"`) adds it onto a folder held in a
 * variable (#1194), so it is a name in that folder, never one at the disk's root, which is in no
 * checkout and was never held. A name spelled anywhere as it is, from the root, is not.
 */
export const addedOntoFolder = (text: string, name: string): boolean => {
  if (!name.startsWith('/')) return false
  let seen = false
  for (let i = text.indexOf(name); i >= 0; i = text.indexOf(name, i + 1)) {
    if (/[\w./~@+*[\]()-]/.test(text[i - 1] ?? '') || /[\w.-]/.test(text[i + name.length] ?? '')) continue
    seen = true
    if (!addedOnto(text.slice(Math.max(0, i - 64), i))) return false
  }
  return seen
}

/**
 * The shell variables a name that looks absolute follows in braces (`${APP}/booker.css`, which
 * mentionedLookFiles reads as `/booker.css`), where every place the text spells the name follows one
 * (lessons review of #1194): each is the shell's `$APP/booker.css`, which lands where the command
 * sets the variable (shellVarPath), never a joined name. Undefined where any place does not.
 */
export const shellBraces = (text: string, name: string): string[] | undefined => {
  if (!name.startsWith('/')) return undefined
  const vars: string[] = []
  for (let i = text.indexOf(name); i >= 0; i = text.indexOf(name, i + 1)) {
    if (/[\w./~@+*[\]()-]/.test(text[i - 1] ?? '') || /[\w.-]/.test(text[i + name.length] ?? '')) continue
    const v = SHELL_BRACE.exec(text.slice(Math.max(0, i - 64), i))?.[1]
    if (v === undefined) return undefined
    if (!vars.includes(v)) vars.push(v)
  }
  return vars.length ? vars : undefined
}

/**
 * Whether every place a text spells a name that looks absolute follows a variable of any kind, the
 * shell's braces, an f-string's or a `+ "` (lessons review of #1194). Such a name is in a folder the
 * guard cannot read, never at the disk's root, so where neither shellBraces nor addedOntoFolder takes
 * it whole it is read in the program's folder, and not as a joined name.
 */
export const afterVariable = (text: string, name: string): boolean => {
  if (!name.startsWith('/')) return false
  let seen = false
  for (let i = text.indexOf(name); i >= 0; i = text.indexOf(name, i + 1)) {
    if (/[\w./~@+*[\]()-]/.test(text[i - 1] ?? '') || /[\w.-]/.test(text[i + name.length] ?? '')) continue
    seen = true
    const head = text.slice(Math.max(0, i - 64), i)
    if (!SHELL_BRACE.test(head) && !addedOnto(head)) return false
  }
  return seen
}

/**
 * Whether every place a text spells a relative name joins it onto a folder held elsewhere, never
 * opening it as written (#1191, lessons review): `os.path.join(d, 'screen.css')` or `path.join(d,
 * 'screen.css')` (no call inside the join before it), pathlib's `d / 'screen.css'`, or (#1194) a
 * string or an f-string adding it onto a folder in a variable (`d + "/screen.css"`,
 * `f"{d}/screen.css"`). A name opened
 * as it is (`open('index.html')`), in a list, or anywhere else is not, and nor is a name the text
 * never spells. Nor is the shell's `$R/screen.css` (mentionedLookFiles reads it as `R/screen.css`),
 * whose folder is the variable's value, read by shellVarPath instead (lessons review of #1191: read
 * as joined, its disk check looked for a project folder named after the variable).
 */
export const joinedOnly = (text: string, name: string): boolean => {
  if (!name) return false
  let seen = false
  for (let i = text.indexOf(name); i >= 0; i = text.indexOf(name, i + 1)) {
    const before = text[i - 1] ?? ''
    const after = text[i + name.length] ?? ''
    if (before === '/' && !/[\w.-]/.test(after)) {
      const head = text.slice(Math.max(0, i - 65), i - 1)
      // After the shell's braces the folder is the variable's value, never a join (lessons review).
      if (SHELL_BRACE.test(head)) return false
      if (addedOnto(head)) {
        seen = true
        continue
      }
    }
    // Only the name as a whole word: not a longer name holding it (`app/screen.css`, `screen.css.map`).
    if (/[\w./~@+*[\]()-]/.test(before) || /[\w.-]/.test(after)) continue
    seen = true
    const line = text.slice(text.lastIndexOf('\n', i - 1) + 1, i)
    if (!/['"]$/.test(line)) return false
    const head = line.slice(0, -1)
    if (/\/\s*$/.test(head) && !/\/\/\s*$/.test(head)) continue
    if (/\b(?:join|joinpath|resolve)\([^()]*,\s*$/.test(head)) continue
    return false
  }
  return seen
}

/**
 * Where a name the shell spells through a variable (`$R/screen.css`, which mentionedLookFiles reads
 * as `R/screen.css`) lands, from `command`'s own assignment of that variable (#1191, lessons review):
 * its value joined with the rest of the name, when every place `text` spells the name follows a `$`
 * and the command sets the variable once, or always to the same value, to a literal (bare, or in
 * quotes with no `$` or backtick in it). Undefined otherwise, as for a variable set nowhere in the
 * command, which the caller reads as it reads any name. The value may be relative, for the caller to
 * place.
 */
export const shellVarPath = (command: string, text: string, name: string): string | undefined => {
  const slash = name.indexOf('/')
  const v = name.slice(0, slash)
  if (slash <= 0 || !/^[A-Za-z_]\w*$/.test(v)) return undefined
  let seen = false
  for (let i = text.indexOf(name); i >= 0; i = text.indexOf(name, i + 1)) {
    if (/[\w./~@+*[\]()-]/.test(text[i - 1] ?? '') || /[\w.-]/.test(text[i + name.length] ?? '')) continue
    if (text[i - 1] !== '$') return undefined
    seen = true
  }
  if (!seen) return undefined
  const values = new Set<string>()
  for (const m of command.matchAll(new RegExp(`(?:^|[\\s;&|(])${v}=(?:'([^']*)'|"([^"$\`\\\\]*)"|([^\\s;&|()'"$\`\\\\]*))`, 'g'))) values.add(m[1] ?? m[2] ?? m[3] ?? '')
  // A value built another way (`R="$X/y"`, `R=$(pwd)`) is set too, and cannot be read.
  if (new RegExp(`(?:^|[\\s;&|(])${v}=["]?[$\`]`).test(command)) return undefined
  const [value] = [...values]
  if (values.size !== 1 || !value) return undefined
  return `${value.replace(/\/+$/, '')}/${name.slice(slash + 1)}`
}

/** A path as it stands inside the checkout at `root`; the path itself when it is not under it. */
export const relTo = (path: string, root: string): string => (path.startsWith(root + '/') ? path.slice(root.length + 1) : path)

/**
 * What kind of look changing file a path in the checkout at `root` is, or null for one that is not,
 * a test file included, its test markers read inside the checkout only (lessons review of #991). The
 * guard's own decision; a Swift file still needs its text read (isSwiftUI).
 */
export const lookKindIn = (path: string, root: string): LookKind | null => (isTestPath(relTo(path, root)) ? null : shapeKind(path))

/**
 * The kind of look changing file a path's shape is, before asking whether it is a test: the guard
 * asks that of the path inside its project (`isTestPath` on the part below the checkout), so a
 * project checked out under a folder named tests is not let through whole (lessons review of #991).
 */
export const shapeKind = (path: string): LookKind | null => {
  const base = (path.split('/').pop() ?? '').toLowerCase()
  if (TAILWIND.test(base)) return 'tailwind'
  if (TOKENS.test(base)) return 'tokens'
  const dot = base.lastIndexOf('.')
  if (dot <= 0) return null
  const ext = base.slice(dot + 1)
  if (STYLE.has(ext)) return 'style'
  if (SCREEN.has(ext)) return 'screen'
  if (ext === 'swift') return 'swift'
  return null
}

/**
 * The built in tools that take a file path only to read it, each never writing there: Read, Grep,
 * Glob and LS read; NotebookRead reads a notebook; LSP asks about code; Artifact publishes a local
 * page (its read action saves into its own scratch folder, named by out_dir, not a path); ArtifactData
 * reads a local JSON file. Every other tool carrying a file path is judged as writing it (lessons
 * review of #991), so a writing tool added later, MultiEdit and NotebookEdit among those today, is
 * held by default rather than missed.
 */
export const READS_ONLY: ReadonlySet<string> = new Set(['Read', 'Grep', 'Glob', 'LS', 'NotebookRead', 'LSP', 'Artifact', 'ArtifactData'])

/** The file paths a tool's input carries: every top level string, or list of strings, under a key ending path or paths (file_path, notebook_path, path, file_paths). */
export const pathsOf = (input: Record<string, unknown>): string[] => {
  const out: string[] = []
  for (const [k, v] of Object.entries(input)) {
    if (!/paths?$/i.test(k)) continue
    for (const x of Array.isArray(v) ? v : [v]) if (typeof x === 'string' && x.trim() && !out.includes(x)) out.push(x)
  }
  return out
}

/** The text a call says it puts in a file, where its input carries any: content, new_string, each edit's new_string, a notebook cell's new_source. */
export const textsOf = (input: Record<string, unknown>): string[] => {
  const out: string[] = []
  for (const k of ['content', 'new_string', 'new_source']) if (typeof input[k] === 'string') out.push(input[k] as string)
  if (Array.isArray(input.edits)) for (const e of input.edits) if (e && typeof (e as { new_string?: unknown }).new_string === 'string') out.push((e as { new_string: string }).new_string)
  return out
}

/** Whether Swift source is a SwiftUI view: it imports SwiftUI, or declares a view or its body. */
export const isSwiftUI = (text: string): boolean => /\bimport\s+SwiftUI\b/.test(text) || /\bsome\s+View\b/.test(text) || /:\s*View\s*\{/.test(text)

/**
 * The look changing files a command's text names, for a write its words do not name (an inline
 * script, a patch). A Next.js dynamic segment or route group (`[SO_ID]`, `(shop)`) is part of the
 * name (#1010): read as where the name starts, `src/app/booking/[SO_ID]/page.tsx` was `/page.tsx`, a
 * file at the top of the disk in no project, and passed. A call's own name and parenthesis before a
 * name (`open(app/page.tsx`) may not be part of it, and a folder holding one (`x(1)`) is, so both
 * readings are given.
 */
export const mentionedLookFiles = (text: string): string[] => {
  const out: string[] = []
  for (const m of text.matchAll(/[\w./~@+*[\]()-]+\.[A-Za-z]+\b/g)) {
    // `open(app/page.tsx` is a call around a name and `x(1)/page.tsx` a folder holding parentheses,
    // and the spelling cannot tell them apart, so both readings are kept and either holds. Only an
    // absolute name after a call's parenthesis is that name alone (lessons review of #1010).
    const raw = m[0]
    const call = raw.replace(/^(?:[\w$.]+\()+/, '')
    for (let word of call === raw || /^[/~$]/.test(call) ? [call] : [call, raw]) {
      word = word.replace(/^[.]+(?=[^./])/, '')
      // A ) closing nothing in the name closes the call around it (`open(app/page.tsx).read`).
      let depth = 0
      for (let i = 0; i < word.length; i++) {
        if (word[i] === '(') depth++
        else if (word[i] === ')' && --depth < 0) {
          word = word.slice(0, i)
          break
        }
      }
      if (shapeKind(word) !== null && !out.includes(word)) out.push(word)
    }
  }
  return out
}

/**
 * Whether a word's file name (its last part) is one the shell would expand as a pattern, as against
 * one built from a variable or a command's output: a `*`, `?`, bracket or brace, or a group, zsh's
 * `(a|b)` or bash's extglob `@(a|b)`. A name in brackets alone (`(shop)`, `x(1)`) is a name. Its
 * folder may be anything, a variable included (`$D/[t]okens.json`): that only leaves the folder
 * unknown (lessons review of #1015).
 */
export const isPattern = (word: string): boolean => {
  const base = word.split('/').pop() ?? ''
  return (/[*?[\]{}]/.test(base) || isGroupPattern(base)) && !/[$`]/.test(base)
}

/**
 * Whether a word holds a pattern group, zsh's `(a|b)` or bash's extglob `@(a|b)`, which mod-kit's
 * write reader takes for a name and gives a path: the shell may expand it all the same (#1015).
 */
export const isGroupPattern = (word: string): boolean => /\([^()]*\|[^()]*\)|[@!+*?]\(/.test(word)

// Every look changing name (shapeKind) as a pattern, in lower case, the case shapeKind reads a name
// in: each listed extension, each Tailwind config, and the design tokens names. TOKENS' run of
// `.part`s is written as `*`, a little wider than the rule, so a pattern is never let through that
// the rule would hold.
const LOOK_NAMES: readonly string[] = [
  ...[...STYLE, ...SCREEN, 'swift'].map(x => `*.${x}`),
  ...['js', 'cjs', 'mjs', 'ts', 'cts', 'mts'].map(x => `tailwind.config.${x}`),
  ...['', 'design', 'design-', 'design_', 'design.'].flatMap(p =>
    ['json', 'jsonc', 'js', 'cjs', 'mjs', 'ts', 'css', 'scss'].flatMap(x => [`${p}tokens.${x}`, `${p}tokens.*.${x}`]),
  ),
  '*.tokens.json',
]

// One place in a pattern: a character, `?` (any one), `*` (any run, the empty one included) or a
// bracket expression (one of a set, or of none of it when negated).
type Atom = { star: true } | { one: (c: string) => boolean }
// Brace expansion multiplies a name; past this many spellings it is not worth reading, and is held.
const MAX_SPELLINGS = 256

// A name's brace expansions, as bash makes them: the first `{a,b}` holding a comma at its own depth
// becomes each of its parts, then the rest in turn; a brace holding no comma is literal. A sequence
// (`{a..z}`, `{1..9}`) is read as `*`, which matches everything it could spell. Null past
// MAX_SPELLINGS.
const spellings = (name: string): string[] | null => {
  let depth = 0
  let open = -1
  const commas: number[] = []
  for (let i = 0; i < name.length; i++) {
    const c = name[i]
    if (c === '\\') i++
    else if (c === '{') {
      if (depth++ === 0) {
        open = i
        commas.length = 0
      }
    } else if (c === '}' && depth > 0) {
      if (--depth === 0) {
        const body = name.slice(open + 1, i)
        const rest = name.slice(i + 1)
        const head = name.slice(0, open)
        let parts: string[] | null = null
        if (commas.length) parts = [...commas.map((at, k) => name.slice(k ? (commas[k - 1] as number) + 1 : open + 1, at)), name.slice((commas[commas.length - 1] as number) + 1, i)]
        else if (/^(-?\d+|[A-Za-z])\.\.(-?\d+|[A-Za-z])(\.\.-?\d+)?$/.test(body)) parts = ['*']
        if (!parts) continue
        const out: string[] = []
        const tails = spellings(rest)
        if (!tails) return null
        for (const part of parts) {
          const heads = spellings(head + part)
          if (!heads) return null
          for (const h of heads) for (const t of tails) out.push(h + t)
          if (out.length > MAX_SPELLINGS) return null
        }
        return out
      }
    } else if (c === ',' && depth === 1) commas.push(i)
  }
  return [name]
}

// One spelling as atoms; null for a pattern no rule here reads. A pattern matches a name's characters
// as they are, case and all; a look changing name (`caseless`) matches any case, since shapeKind reads
// a name in lower case, and the Mac's disk takes a name in capitals for the same file.
const atomsOf = (spelling: string, caseless = false): Atom[] | null => {
  const out: Atom[] = []
  const fold = (c: string) => (caseless ? [c.toLowerCase()] : [c])
  for (let i = 0; i < spelling.length; i++) {
    const c = spelling[i] as string
    if (c === '(' || c === ')' || c === '|') return null
    if (c === '\\') {
      const lit = spelling[++i] ?? '\\'
      out.push({ one: x => fold(x).includes(lit) })
    } else if (c === '*') {
      if (!('star' in (out[out.length - 1] ?? {}))) out.push({ star: true })
    } else if (c === '?') out.push({ one: () => true })
    else if (c === '[') {
      // `]` first in the set is one of it; a set never closed is a literal `[`, as bash reads it.
      let j = i + 1
      const negated = spelling[j] === '!' || spelling[j] === '^'
      if (negated) j++
      if (spelling[j] === ']') j++
      const end = spelling.indexOf(']', j)
      if (end < 0) {
        out.push({ one: x => fold(x).includes('[') })
        continue
      }
      const body = spelling.slice(negated ? i + 2 : i + 1, end)
      // A POSIX class (`[:alpha:]`) is read as any one character: wider than the class, never narrower.
      const any = /\[:[a-z]+:\]/.test(body)
      const ranges: [string, string][] = []
      for (let k = 0; k < body.length; k++) {
        const lo = body[k] as string
        if (body[k + 1] === '-' && k + 2 < body.length) {
          ranges.push([lo, body[k + 2] as string])
          k += 2
        } else ranges.push([lo, lo])
      }
      const inSet = (x: string) => any || ranges.some(([lo, hi]) => x >= lo && x <= hi)
      out.push({ one: x => fold(x).some(y => inSet(y) !== negated) })
      i = end
    } else out.push({ one: x => fold(x).includes(c) })
  }
  return out
}

// Every character a file name can hold that tells patterns apart: printable ASCII, and one beyond it.
const ALPHABET = [...Array.from({ length: 0x7e - 0x20 + 1 }, (_, k) => String.fromCharCode(0x20 + k)).filter(c => c !== '/'), 'é']

// Whether two patterns share a name: a walk over both at once, where a `*` matches nothing or takes
// one character from the other side, and two single places agree on some character.
const overlap = (a: readonly Atom[], b: readonly Atom[]): boolean => {
  const seen = new Map<number, boolean>()
  const walk = (i: number, j: number): boolean => {
    const key = i * (b.length + 1) + j
    const had = seen.get(key)
    if (had !== undefined) return had
    seen.set(key, false)
    const x = a[i]
    const y = b[j]
    let r = false
    if (!x && !y) r = true
    else if (x && 'star' in x && walk(i + 1, j)) r = true
    else if (y && 'star' in y && walk(i, j + 1)) r = true
    else if (x && y) {
      if ('star' in x) r = walk(i, j + 1)
      else if ('star' in y) r = walk(i + 1, j)
      else r = ALPHABET.some(c => x.one(c) && y.one(c)) && walk(i + 1, j + 1)
    }
    seen.set(key, r)
    return r
  }
  return walk(0, 0)
}

const LOOK_ATOMS = LOOK_NAMES.map(n => atomsOf(n, true) as Atom[])

/**
 * Whether a file name the shell expands as a pattern may name a look changing file (#1015): `look`
 * when some name it can expand to is one (`[t]ailwind.config.ts`, `app/[t]okens.json`, `page.ts[x]`,
 * `out.*`, `build/*`), `not` when its literal parts rule every one out (`run-*.log`, `x.{md,txt}`,
 * `x.[!c]ss`), and `unread` for one no rule here reads (a group, as bash's extglob and zsh's
 * alternation and qualifiers write it, or a brace expansion past MAX_SPELLINGS spellings). Only the
 * last part of a path is read: a pattern in a folder is followed by the caller, or not at all. Since
 * #1010 only a pattern in the extension was judged, so a pattern in the rest of the name passed.
 */
export const patternMayBeLook = (word: string): 'look' | 'not' | 'unread' => {
  const base = word.split('/').pop() ?? ''
  const all = spellings(base)
  if (!all) return 'unread'
  let may = false
  for (const s of all) {
    const atoms = atomsOf(s)
    if (!atoms) return 'unread'
    if (!may && LOOK_ATOMS.some(l => overlap(atoms, l))) may = true
  }
  return may ? 'look' : 'not'
}

/**
 * The text a call leaves in a file it edits, from the file as it is: a Write's content, an Edit's
 * (one match, or every match with replace_all, as Edit itself requires), MultiEdit's edits in turn.
 * Undefined for an edit that would not apply and for any other tool, which is never judged by it.
 */
export const editedText = (before: string, tool: string, input: Record<string, unknown>): string | undefined => {
  const apply = (text: string, edit: unknown): string | undefined => {
    const e = (edit ?? {}) as Record<string, unknown>
    if (typeof e.old_string !== 'string' || typeof e.new_string !== 'string' || !e.old_string) return undefined
    const parts = text.split(e.old_string)
    if (parts.length < 2 || (parts.length > 2 && e.replace_all !== true)) return undefined
    return parts.join(e.new_string)
  }
  if (tool === 'Write') return typeof input.content === 'string' ? input.content : undefined
  if (tool === 'Edit') return apply(before, input)
  if (tool !== 'MultiEdit' || !Array.isArray(input.edits) || !input.edits.length) return undefined
  let text: string | undefined = before
  for (const e of input.edits) if ((text = apply(text, e)) === undefined) return undefined
  return text
}

// The most pairs of lines changedRuns compares; past it a change is one run, judged whole.
const RUNS_MAX_CELLS = 4_000_000
// The most runs judged one by one, each a read of the whole text (a mod hook's a JSX parse); past it
// a change is one run, judged whole, since a hold costs Dan one answer (lessons review of #1158).
// Undoing a session's own edits is a handful of runs, never dozens.
const RUNS_MAX = 24

/**
 * The texts a change from `before` to `after` passes through when it is made one run of changed lines
 * at a time, each as [before, after] (#1158): the shape a git checkout or restore has when it puts back
 * several edits at once, each of which was an edit of its own. A line diff (longest common subsequence)
 * between the lines both texts do not share at their start and end; past RUNS_MAX_CELLS or RUNS_MAX, the whole
 * change is one run. No runs for equal texts.
 */
export const changedRuns = (before: string, after: string): [string, string][] => {
  if (before === after) return []
  const a = before.split(/(?<=\n)/)
  const b = after.split(/(?<=\n)/)
  let p = 0
  while (p < a.length && p < b.length && a[p] === b[p]) p++
  let s = 0
  while (s < a.length - p && s < b.length - p && a[a.length - 1 - s] === b[b.length - 1 - s]) s++
  const n = a.length - p - s
  const m = b.length - p - s
  if ((n + 1) * (m + 1) > RUNS_MAX_CELLS) return [[before, after]]
  // lcs[i * (m + 1) + j]: the longest common run of lines from a[p + i] and b[p + j] on.
  const lcs = new Uint32Array((n + 1) * (m + 1))
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      lcs[i * (m + 1) + j] = a[p + i] === b[p + j] ? (lcs[(i + 1) * (m + 1) + j + 1] as number) + 1 : Math.max(lcs[(i + 1) * (m + 1) + j] as number, lcs[i * (m + 1) + j + 1] as number)
  // Each run as [where it starts in a, how many lines of a it replaces, the lines of b it puts there].
  const runs: [number, number, string[]][] = []
  let open: [number, number, string[]] | undefined
  let i = 0
  let j = 0
  while (i < n || j < m) {
    if (i < n && j < m && a[p + i] === b[p + j]) {
      open = undefined
      i++
      j++
      continue
    }
    if (!open) runs.push((open = [p + i, 0, []]))
    if (j < m && (i === n || (lcs[i * (m + 1) + j + 1] as number) >= (lcs[(i + 1) * (m + 1) + j] as number))) open[2].push(b[p + j++] as string)
    else {
      open[1]++
      i++
    }
  }
  if (runs.length > RUNS_MAX) return [[before, after]]
  // Made from the last run back, so each earlier run's place in the text is unmoved.
  const steps: [string, string][] = []
  const text = [...a]
  for (const [at, count, lines] of runs.reverse()) {
    const was = text.join('')
    text.splice(at, count, ...lines)
    steps.push([was, text.join('')])
  }
  return steps
}

/** The screen files whose edits are judged by their text (dataOnlyChange): React's .tsx and .jsx. */
export const judgedByText = (path: string): boolean => /\.(tsx|jsx)$/i.test(path)

// A prop whose name can carry a look or what is shown, read anywhere in the name and in any case
// (`containerClassName`, `maxWidth`, `defaultOpen`), so a near miss holds rather than passes. A hold
// costs Dan one answer; a pass is a look he never saw. Plus a boolean's prefix, read by its case.
const LOOK_WORD = /class|style|css|^sx$|^tw$|colou?r|variant|size|theme|tone|intent|appearance|kind|layout|mode|compact|dense|emphasis|open|show|hide|hidden|visible|disabled|checked|selected|active|expand|collapse|loading|width|height|icon|image|img|src|alt|title|label|text|value|placeholder|children|content|heading|caption|message|align|justify|gap|pad|margin|radius|round|shadow|font|weight|border|^bg|background|fill|stroke|opacity|position|order|span|grid|flex|display|render|^as$|tag|component|^id$/i
const LOOK_PROP = { test: (name: string) => LOOK_WORD.test(name) || /^(is|has|should|with|can)[A-Z]/.test(name) }
// An expression that only carries data along: names, property access, calls, ?? || && ! and ?:, with
// no literal but the empty string, so nothing in it can be text shown on screen or a class.
const PLUMBING = /^[\w$.?!|&(),:\s[\]]+$/

/**
 * Whether changing a React screen file's text from `before` to `after` changes nothing on screen, by
 * a rule narrow enough to be sure (#1010). Dan's edit, `xbc={xbc}` to `xbc={leadXbc ?? ''}`, which
 * booking code a page hands its calendar, is the shape: the one difference lies inside the value of
 * one prop on a component (a capitalised tag), the prop's name does not name a look or what is shown,
 * and both values only carry data along. A changed className, style, look naming prop, literal, JSX,
 * copy, import, or anything outside one prop's value is not judged here, so it is asked about.
 */
export const dataOnlyChange = (before: string, after: string): boolean => {
  if (before === after) return false
  const max = Math.min(before.length, after.length)
  let p = 0
  while (p < max && before[p] === after[p]) p++
  let s = 0
  while (s < max - p && before[before.length - 1 - s] === after[after.length - 1 - s]) s++
  // The braces around the change: the nearest { before it and the nearest } after it, the same brace
  // in both texts. A value holding a brace fails PLUMBING below, so these enclose the change only.
  const open = before.lastIndexOf('{', p - 1)
  if (open < 0) return false
  const closeB = before.indexOf('}', p)
  const closeA = after.indexOf('}', p)
  if (closeB < before.length - s || closeA < after.length - s || before.length - closeB !== after.length - closeA) return false
  const empty = (v: string) => v.replace(/''|""/g, 'x')
  const values = [before.slice(open + 1, closeB), after.slice(open + 1, closeA)].map(empty)
  if (!values.every(v => PLUMBING.test(v) && !/(^|[^\w$])\d/.test(v) && !/\b(true|false)\b/.test(v))) return false
  // The prop, and the component it is on.
  const head = before.slice(0, open)
  const prop = /\s([A-Za-z_][A-Za-z0-9_]*)=$/.exec(head)
  if (!prop || LOOK_PROP.test(prop[1] as string)) return false
  const lt = head.lastIndexOf('<')
  const tag = head.slice(lt, head.length - (prop[0] as string).length).replace(/=>/g, '')
  return lt >= 0 && /^<[A-Z][\w.]*(\s|$)/.test(tag) && !tag.includes('>')
}

/**
 * Whether a file, by its path inside its checkout, is one of a Claude Code mod's own hook files that
 * draws through JSX (`mods/<mod>/hooks/<file>.tsx` or `.jsx`), which modHookLogicOnly judges (#1138).
 */
export const isModHook = (rel: string): boolean => /(^|\/)mods\/[^/]+\/hooks\/[^/]+\.(tsx|jsx)$/i.test(rel)

/**
 * The plugin.json that makes a mod hook file's folder a Claude Code mod: an app's own hooks folder
 * under a folder named mods has none, and is judged as any screen file (lessons review of #1138).
 */
export const modManifestOf = (path: string): string => `${path.slice(0, path.lastIndexOf('/hooks/'))}/.claude-plugin/plugin.json`

type Span = readonly [number, number]

/**
 * Where a TSX file's JSX elements and comments lie, as [start, end) offsets, or null for text this
 * reader cannot follow (an unclosed element, string or comment, or a closing tag naming another
 * element), which the caller holds rather than passes. A small reader of the code around the JSX:
 * strings, template literals, regular expressions, comments and a generic arrow's type parameters
 * (`<T,>(`, `<E extends X>(`, mod-kit's drawCard) are skipped, and a `<` opens an element only where
 * an expression may start (after `(`, `,`, `=`, `=>`, `?`, `:`, `&&`, `return` and the like), so
 * `Promise<X>` and `a < b` are never read as one. `strings` is what each string, template literal
 * part and regular expression holds, its quotes and the template's `${` and `}` aside (#1275). With
 * `jsx` false, for a `.ts` file, which holds none, a `<` opens nothing, so a generic arrow may be
 * written with no comma (`<T>(`, as status bar's and scope modes' hook files do).
 */
export const sourceSpans = (text: string, jsx_ = true): { jsx: Span[]; comments: Span[]; strings: Span[] } | null => {
  const jsx: Span[] = []
  const comments: Span[] = []
  const strings: Span[] = []
  const n = text.length
  const unread = new Error('unread')
  const id = (c: string | undefined) => c !== undefined && /[\w$]/.test(c)
  const space = (c: string | undefined) => c !== undefined && /\s/.test(c)
  // A quote opening a TypeScript string or a JSX attribute's value. This reads source text, not a
  // shell command, so mod-kit's command reader ($.modkit.commands) is no use here.
  const stringQuote = (c: string | undefined): c is string => c !== undefined && /^["']$/.test(c)
  const EXPR_WORDS = new Set(['return', 'yield', 'case', 'default', 'await', 'typeof', 'void', 'in', 'of', 'delete', 'throw', 'else', 'do'])
  const quoted = (i: number): number => {
    const q = text[i]
    for (let j = i + 1; j < n; j++) {
      if (text[j] === '\\') j++
      else if (text[j] === q) {
        strings.push([i + 1, j])
        return j + 1
      } else if (text[j] === '\n') throw unread
    }
    throw unread
  }
  const template = (i: number): number => {
    let from = i + 1
    for (let j = i + 1; j < n; j++) {
      if (text[j] === '\\') j++
      else if (text[j] === '`') {
        strings.push([from, j])
        return j + 1
      } else if (text[j] === '$' && text[j + 1] === '{') {
        strings.push([from, j])
        j = code(j + 2, true)
        from = j + 1
      }
    }
    throw unread
  }
  const regex = (i: number): number => {
    let set = false
    for (let j = i + 1; j < n; j++) {
      const c = text[j]
      if (c === '\\') j++
      else if (c === '\n') throw unread
      else if (set) set = c !== ']'
      else if (c === '[') set = true
      else if (c === '/') {
        strings.push([i + 1, j])
        j++
        while (j < n && /[a-z]/i.test(text[j] as string)) j++
        return j
      }
    }
    throw unread
  }
  // An element from its `<` to just past its end; nested elements and expressions read in turn.
  const element = (i: number): number => {
    let j = i + 1
    let name = ''
    if (text[j] === '>') j++
    else {
      const m = /^[A-Za-z_$][\w$.:-]*/.exec(text.slice(j, j + 200))
      if (!m) throw unread
      name = m[0]
      j += name.length
      for (;;) {
        while (space(text[j])) j++
        if (j >= n) throw unread
        if (text[j] === '/' && text[j + 1] === '>') return j + 2
        if (text[j] === '>') {
          j++
          break
        }
        if (text[j] === '{') {
          j = code(j + 1, true) + 1
          continue
        }
        const a = /^[A-Za-z_$][\w$:-]*/.exec(text.slice(j, j + 200))
        if (!a) throw unread
        j += a[0].length
        let k = j
        while (space(text[k])) k++
        if (text[k] !== '=') continue
        k++
        while (space(text[k])) k++
        const c = text[k]
        if (stringQuote(c)) {
          const e = text.indexOf(c, k + 1)
          if (e < 0) throw unread
          strings.push([k + 1, e])
          j = e + 1
        } else if (c === '{') j = code(k + 1, true) + 1
        else if (c === '<') j = element(k)
        else throw unread
      }
    }
    for (;;) {
      if (j >= n) throw unread
      if (text[j] === '<' && text[j + 1] === '/') {
        const e = text.indexOf('>', j)
        if (e < 0 || text.slice(j + 2, e).trim() !== name) throw unread
        return e + 1
      }
      if (text[j] === '<') j = element(j)
      else if (text[j] === '{') j = code(j + 1, true) + 1
      else j++
    }
  }
  // Code from `i`: to the `}` closing an expression when `nested` (its offset), else to the end.
  const code = (i: number, nested: boolean): number => {
    let depth = 0
    let prev = ''
    let word = ''
    const starts = () => prev === '' || '([{,;:=!&|?>'.includes(prev) || (prev === 'a' && EXPR_WORDS.has(word))
    while (i < n) {
      const c = text[i] as string
      if (c === '/' && text[i + 1] === '/') {
        const e = text.indexOf('\n', i)
        const end = e < 0 ? n : e
        comments.push([i, end])
        i = end
      } else if (c === '/' && text[i + 1] === '*') {
        const e = text.indexOf('*/', i + 2)
        if (e < 0) throw unread
        comments.push([i, e + 2])
        i = e + 2
      } else if (space(c)) i++
      else if (stringQuote(c)) {
        i = quoted(i)
        prev = c
      } else if (c === '`') {
        i = template(i)
        prev = c
      } else if (c === '/' && starts()) {
        i = regex(i)
        prev = ')'
      } else if (jsx_ && c === '<' && starts() && /^<\s*[A-Za-z_$][\w$]*\s*(,|=|extends\b)/.test(text.slice(i, i + 200))) {
        // A generic arrow's type parameters (`<T,>(`, `<E extends X>(`, `<T = X>(`), which no
        // element can open with: skipped to their closing `>`, nested ones counted.
        let depth = 0
        let j = i
        for (; j < n; j++) {
          if (text[j] === '<') depth++
          else if (text[j] === '>' && text[j - 1] !== '=' && --depth === 0) break
        }
        if (j >= n) throw unread
        i = j + 1
        prev = 'a'
        word = ''
      } else if (jsx_ && c === '<' && starts() && /[A-Za-z>]/.test(text[i + 1] ?? '')) {
        const s = i
        i = element(i)
        jsx.push([s, i])
        prev = ')'
      } else if (id(c)) {
        let j = i
        while (j < n && id(text[j])) j++
        word = text.slice(i, j)
        prev = 'a'
        i = j
      } else {
        if (c === '{') depth++
        else if (c === '}') {
          if (depth === 0) {
            if (nested) return i
            throw unread
          }
          depth--
        }
        prev = c
        word = ''
        i++
      }
    }
    if (nested) throw unread
    return n
  }
  try {
    code(0, false)
    return { jsx, comments, strings }
  } catch (err) {
    if (err === unread) return null
    throw err
  }
}

// The words a mod's drawing is spelled in outside its JSX: Ink's Text and Box props, mod-kit's frames,
// rows and panes, and the colours. Read on each part of a camelCase name (`dimColor`, `paddingX`), so
// a line naming any of them is held, as a hold costs Dan one answer and a pass a look he never saw.
const MOD_LOOK_WORDS = new Set(
  'color colour bold dim italic underline strikethrough inverse border frame box rule width height padding margin gap wrap truncate align justify flex style theme row rows column columns pane band card panel button render draw amber gray grey red green blue yellow cyan magenta violet white black orange purple pink ansi hex rgb hsl chalk cols icon glyph'.split(
    ' ',
  ),
)
// A colour or a terminal style spelled with no word at all: a hex colour (`'#ff0000'`), an ANSI
// escape (`\x1b[31m`, `\u001b`, `\u{1b}`, `\033`, `\e[`), or an rgb() or hsl() colour (lessons review).
const MOD_LOOK_LITERAL = /#[0-9a-f]{3,8}\b|\\x1b|\\u001b|\\u\{1b\}|\\033|\\e\[|\b(rgb|hsl)a?\(/i

/**
 * Where two texts differ: `at`, the offset both share up to, and the end of the changed part in each,
 * exclusive. Where one only adds to the other or takes from it, the change is moved as early as it
 * reads the same, to the start of a line where it can be (#1248), so whole lines added above a line
 * are never read as reaching into it, as `const a = 1` added above `const b` would otherwise be.
 */
export const changedSpan = (before: string, after: string): { at: number; before: number; after: number } => {
  const max = Math.min(before.length, after.length)
  let p = 0
  while (p < max && before[p] === after[p]) p++
  let s = 0
  while (s < max - p && before[before.length - 1 - s] === after[after.length - 1 - s]) s++
  if (p + s < max) return { at: p, before: before.length - s, after: after.length - s }
  const long = after.length > before.length ? after : before
  const d = long.length - max
  while (p > 0 && long[p - 1] !== '\n' && long[p - 1] === long[p + d - 1]) p--
  return { at: p, before: before.length > max ? p + d : p, after: after.length > max ? p + d : p }
}

/**
 * Whether changing a mod's hook file (isModHook) from `before` to `after` changes only logic, by what
 * the file draws (#1138): every line the change touches (changedSpan, ending where the change ends,
 * never on the unchanged line after it, #1248), in both texts, lies outside every JSX element
 * and, its comments aside, names no word a mod's drawing is spelled in (MOD_LOOK_WORDS) and spells no
 * colour or terminal style (MOD_LOOK_LITERAL). A text the reader cannot follow (sourceSpans) is never
 * judged so. A size held in a constant whose name says nothing of it (`const MAX = 40`) is a gap this
 * reading leaves, as a mod's `.ts` files, never held, leave every one.
 */
export const modHookLogicOnly = (before: string, after: string): boolean => {
  if (before === after) return false
  const span = changedSpan(before, after)
  for (const [text, end] of [
    [before, span.before],
    [after, span.after],
  ] as const) {
    const spans = sourceSpans(text)
    if (!spans) return false
    // The lines the change touches in this text, ending where it ends, never on the unchanged line
    // after them (#1248). Where it only adds to the other text, none, so all this text is asked is
    // whether an element spans the place the lines go.
    const from = text.lastIndexOf('\n', span.at - 1) + 1
    const nl = end === span.at ? from : text[end - 1] === '\n' ? end - 1 : text.indexOf('\n', end)
    const to = nl < 0 ? text.length : nl
    if (spans.jsx.some(([a, b]) => a < to && from < b)) return false
    let shown = ''
    for (let i = from; i < to; i++) if (!spans.comments.some(([a, b]) => a <= i && i < b)) shown += text[i]
    if (MOD_LOOK_LITERAL.test(shown)) return false
    for (const w of shown.match(/[A-Za-z]+/g) ?? [])
      for (const part of w.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(' ')) if (MOD_LOOK_WORDS.has(part)) return false
  }
  return true
}

/**
 * Whether a file, by its path inside its checkout, is one of a Claude Code mod's own hook files in
 * plain TypeScript (`mods/<mod>/hooks/<file>.ts`, `.mts` or `.cts`, never a `.d.ts`), which
 * drawsChange judges (#1275). As for isModHook, only a folder whose plugin.json makes it a mod counts.
 */
export const isModHookTs = (rel: string): boolean => /(^|\/)mods\/[^/]+\/hooks\/[^/]+\.(ts|mts|cts)$/i.test(rel) && !/\.d\.[mc]?ts$/i.test(rel)

/** One of a mod's hook files, by its name in the mod's hooks folder, and its text. */
export type ModFile = { name: string; text: string }

// The keys that make an object one of mod-kit's text runs, beside `text` (ModKitRun, ModKitBandText).
const RUN_LOOKS = new Set(['color', 'bold', 'dim', 'italic', 'underline', 'strikethrough', 'inverse', 'indent', 'wrap', 'whole', 'href', 'dimColor', 'backgroundColor'])
// What draws a mod's lines, with what it is handed: mod-kit's band row, pane and boxed card, a blocked
// action's grey card, and a pane's size and title as Claude Code opens it.
const DRAW_CALL = /\$\s*\.\s*(?:modkit\s*\.\s*(?:bandRow|pane|card|blocked)|ui\s*\.\s*open)\s*\(/g
const DECL = /^(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?(?:async\s+)?(const|let|var|function\s*\*?|class|type|interface|enum)\s+([A-Za-z_$][\w$]*)/
const IMPORT = /^import\s+(type\s+)?([\s\S]*?)\s+from\s+['"]\.\/([^'"/]+)['"]/

type Statement = { from: number; to: number; name?: string; isType: boolean }
// A function in a mod hook file (#1296): where it is, its parameters' names by position (a
// destructured one holding several), the name it is bound to, and for one with no name, what it is
// handed to: the callback a method of `xs` calls (`xs.map(x => ...)`) takes its values from `xs`.
type Fn = { from: number; to: number; body: number; params: string[][]; name?: string; receiver?: { at: number; name: string } | Span; returns?: Span[] }
// A local binding (`const c = ...`, a loop's `const t of ts`), its whole declaration, and the
// function it belongs to (an index into fns).
type Local = { name: string; span: Span; owner: number }
type ModRead = {
  name: string
  // Each statement at the file's top level, and the files and names its imports from the mod name.
  statements: Statement[]
  imports: Map<string, { file: string; name: string }>
  // What the file draws by itself: each drawing call, JSX element, and function building a text run.
  units: Span[]
  code: (s: Span) => string
  refs: (s: Span) => string[]
  isTop: (name: string) => boolean
  // #1296: each name used in a part with where it is, those inside a call the part makes aside when
  // `cut` (the part's own drawing call's parenthesis, `own`, excepted); the functions and locals;
  // where each name is called; and a call's arguments by position.
  refsAt: (s: Span, cut: boolean, own?: number) => { name: string; at: number; call: boolean }[]
  fns: Fn[]
  locals: Local[]
  calls: Map<string, number[]>
  args: (at: number) => Span[] | null
  ownParen: (u: Span) => number | undefined
  // What function k returns: its expression body, or each of its own `return`s' values.
  returns: (k: number) => Span[]
  cutCode: (s: Span) => string
}

// One mod hook file as drawsChange reads it, or null for one its reader cannot follow.
const readMod = (f: ModFile): ModRead | null => {
  const text = f.text
  const spans = sourceSpans(text, /\.(tsx|jsx)$/i.test(f.name))
  if (!spans) return null
  const n = text.length
  // 1 for a comment, 2 for what a string holds, so code is read with neither.
  const mask = new Uint8Array(n)
  for (const [a, b] of spans.comments) mask.fill(1, a, b)
  for (const [a, b] of spans.strings) mask.fill(2, a, b)
  let blank = ''
  for (let i = 0; i < n; i++) blank += mask[i] ? (text[i] === '\n' ? '\n' : ' ') : text[i]
  // Where each bracket closes, and each line's depth at its start, read with strings and comments blanked.
  const close = new Map<number, number>()
  const open: number[] = []
  const starts: number[] = []
  // The last character of code before here, so a line going on with an expression the line before
  // left open (`export const X =` then `'warning'` at the left edge) is never a statement of its own.
  // A `>` leaves one open only as an arrow's `=>`: one closing a generic (`Array<Row>`) ends the
  // statement; nor does a non-null assertion's `!`, or `++` and `--` (lessons review).
  let last = ''
  for (let i = 0; i < n; i++) {
    if ((i === 0 || blank[i - 1] === '\n') && open.length === 0 && /\S/.test(blank[i] ?? ''))
      if (!/(?:[=,([{?:|&*/.]|=>|(?:^|[^+])\+|(?:^|[^-])-)$/.test(last) && !/^[?:.|&+\-*/,)\]}=]/.test(blank[i] ?? '')) starts.push(i)
    const c = blank[i]
    if (c !== undefined && /\S/.test(c)) last = last.slice(-1) + c
    if (c === '(' || c === '[' || c === '{') open.push(i)
    else if (c === ')' || c === ']' || c === '}') {
      const o = open.pop()
      if (o !== undefined) close.set(o, i)
    }
  }
  if (open.length) return null
  const statements: Statement[] = starts.map((from, k) => {
    const to = starts[k + 1] ?? n
    const m = DECL.exec(blank.slice(from, from + 300))
    return m ? { from, to, name: m[2], isType: m[1] === 'type' || m[1] === 'interface' } : { from, to, isType: false }
  })
  const imports = new Map<string, { file: string; name: string }>()
  for (const s of statements) {
    const m = IMPORT.exec(text.slice(s.from, s.to))
    if (!m || m[1]) continue
    const file = m[3] as string
    const clause = (m[2] as string).trim()
    const ns = /\*\s*as\s+([A-Za-z_$][\w$]*)/.exec(clause)
    if (ns) imports.set(ns[1] as string, { file, name: '*' })
    const named = /\{([^}]*)\}/.exec(clause)
    for (const part of named ? (named[1] as string).split(',') : []) {
      const p = /^\s*([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?\s*$/.exec(part)
      if (p && p[1] !== 'type') imports.set((p[2] ?? p[1]) as string, { file, name: p[1] as string })
    }
  }
  const statementAt = (i: number) => statements.find(s => s.from <= i && i < s.to)
  // Every function body in braces: an arrow's (`=> {`) and a function's (`function f(...) {`).
  const bodies: Span[] = []
  for (const [o, c] of close) {
    if (blank[o] !== '{') continue
    if (/=>\s*$/.test(blank.slice(Math.max(0, o - 40), o))) bodies.push([o, c + 1])
  }
  for (const m of blank.matchAll(/\bfunction\b\s*\*?\s*[\w$]*\s*\(/g)) {
    const paren = (m.index as number) + m[0].length - 1
    const end = close.get(paren)
    const brace = end === undefined ? -1 : blank.indexOf('{', end)
    const shut = close.get(brace)
    if (shut !== undefined) bodies.push([brace, shut + 1])
  }
  // A text run (`text` with a look), a divider or a button: mod-kit's line data, wherever it is built.
  const isRun = (o: number): boolean => {
    const end = close.get(o) ?? o
    const keys = new Set<string>()
    let expectKey = true
    for (let i = o + 1; i < end; ) {
      const c = blank[i] as string
      if (c === '(' || c === '[' || c === '{') {
        i = (close.get(i) ?? i) + 1
        expectKey = false
      } else if (c === ',') {
        expectKey = true
        i++
      } else if (/\s/.test(c)) i++
      else if (expectKey && blank.startsWith('...', i)) {
        expectKey = false
        i += 3
      } else {
        const m = expectKey ? /^[A-Za-z_$][\w$]*/.exec(blank.slice(i, i + 64)) : null
        if (m) {
          let j = i + m[0].length
          while (/\s/.test(blank[j] ?? '')) j++
          if (blank[j] === ':' || blank[j] === ',' || j >= end) keys.add(m[0])
          i += m[0].length
        } else i++
        expectKey = false
      }
    }
    return (keys.has('text') && [...keys].some(k => RUN_LOOKS.has(k))) || keys.has('divider') || (keys.has('button') && keys.has('label'))
  }
  const units: Span[] = [...spans.jsx]
  // What an element does when pressed or typed in (`onPress={...}`, `onSubmit`) is no part of how it
  // looks, so the names an event handler uses are not followed from the element.
  const handlers: Span[] = []
  for (const [a, b] of spans.jsx)
    for (const m of blank.slice(a, b).matchAll(/\bon[A-Z][\w$]*\s*=\s*\{/g)) {
      const o = a + (m.index as number) + m[0].length - 1
      const c = close.get(o)
      if (c !== undefined) handlers.push([o, c + 1])
    }
  for (const m of blank.matchAll(DRAW_CALL)) {
    const paren = (m.index as number) + m[0].length - 1
    const end = close.get(paren)
    if (end !== undefined) units.push([m.index as number, end + 1])
  }
  // A run is drawn with the function that builds it: the innermost one around it, or its whole
  // statement where that function is the statement's own (cardLines), so its name and helpers count.
  for (const [o] of close) {
    if (blank[o] !== '{' || !isRun(o)) continue
    const s = statementAt(o)
    if (!s || s.isType) continue
    const around = bodies.filter(([a, b]) => a < o && o < b && s.from <= a && b <= s.to).sort((x, y) => y[0] - x[0])
    const inner = around[0]
    units.push(inner && around.length > 1 ? inner : [s.from, s.to])
  }
  const code = ([a, b]: Span): string => {
    let out = ''
    for (let i = a; i < b; i++) {
      if (mask[i] === 1) continue
      const c = text[i] as string
      if (mask[i] !== 2 && /\s/.test(c)) {
        if (out && !out.endsWith(' ')) out += ' '
      } else out += c
    }
    return out.trim()
  }
  const refs = ([a, b]: Span): string[] => {
    const out = new Set<string>()
    for (const m of blank.slice(a, b).matchAll(/[A-Za-z_$][\w$]*/g)) {
      const at = a + (m.index as number)
      const before = blank[at - 1] ?? ''
      if (/[\w$]/.test(before) || (before === '.' && blank.slice(at - 3, at) !== '...')) continue
      if (handlers.some(([x, y]) => x <= at && at < y)) continue
      out.add(m[0])
    }
    return [...out]
  }
  const tops = new Set(statements.filter(s => s.name !== undefined && !s.isType).map(s => s.name as string))

  // #1296: what follows a value through a function's parameters and its local bindings.
  const openAt = new Map<number, number>()
  for (const [o, c] of close) openAt.set(c, o)
  const pairs = [...close].sort((x, y) => x[0] - y[0])
  const isSpace = (i: number) => /\s/.test(blank[i] ?? '')
  const isWord = (i: number) => /[\w$]/.test(blank[i] ?? '')
  const skipBack = (i: number) => {
    while (i >= 0 && isSpace(i)) i--
    return i
  }
  const skipOn = (i: number) => {
    while (i < n && isSpace(i)) i++
    return i
  }
  // The word ending at i, inclusive.
  const wordBack = (i: number) => {
    let k = i
    while (k >= 0 && isWord(k)) k--
    return blank.slice(k + 1, i + 1)
  }
  // Where an expression from i ends: at a `,`, `;` or closing bracket of its own depth, or a line end
  // the code does not go on past, by the rule the file's statements are cut by.
  const exprEnd = (i: number): number => {
    for (let j = i; j < n; j++) {
      if (mask[j]) continue
      const c = blank[j] as string
      if (c === '(' || c === '[' || c === '{') j = close.get(j) ?? n
      else if (c === ')' || c === ']' || c === '}' || c === ',' || c === ';') return j
      else if (c === '\n') {
        const p = skipBack(j - 1)
        const q = skipOn(j)
        if (p < i || q >= n) return j
        if (/(?:[=,([{?:|&*/.]|=>|(?:^|[^+])\+|(?:^|[^-])-)$/.test(blank.slice(Math.max(i, p - 1), p + 1)) || /^[?:.|&+\-*/,)\]}=]/.test(blank[q] as string)) continue
        return j
      }
    }
    return n
  }
  // The names each parameter or pattern in [a, b) binds, by position: one for a plain name, every name
  // a destructured one binds, its type and default aside.
  const namesIn = (a: number, b: number): string[][] => {
    const out: string[][] = []
    const one = (x: number, y: number) => {
      let s = skipOn(x)
      if (blank.startsWith('...', s)) s += 3
      if (blank[s] === '{' || blank[s] === '[') {
        const names: string[] = []
        for (const m of blank.slice(s + 1, close.get(s) ?? s).matchAll(/([A-Za-z_$][\w$]*)\s*(:?)/g)) if (!m[2]) names.push(m[1] as string)
        out.push(names)
        return
      }
      const m = /^[A-Za-z_$][\w$]*/.exec(blank.slice(s, y))
      out.push(m ? [m[0]] : [])
    }
    let from = a
    let angle = 0
    for (let j = a; j < b; j++) {
      const c = blank[j]
      if (c === '(' || c === '[' || c === '{') j = close.get(j) ?? j
      else if (c === '<') angle++
      else if (c === '>' && angle > 0 && blank[j - 1] !== '=') angle--
      else if (c === ',' && angle === 0) {
        one(from, j)
        from = j + 1
      }
    }
    if (blank.slice(from, b).trim()) one(from, b)
    return out
  }
  // The `)` closing an arrow's parameters, back over a return type (`): Promise<X> =>`).
  const returnTypeParen = (arrow: number): number | undefined => {
    let depth = 0
    for (let k = arrow - 1; k >= 0 && arrow - k < 300; k--) {
      const c = blank[k] as string
      if (c === ')' || c === ']' || c === '}') k = openAt.get(k) ?? k
      else if (c === '>' && blank[k - 1] !== '=') depth++
      else if (c === '<') depth--
      else if (depth === 0 && c === ':') {
        const p = skipBack(k - 1)
        return blank[p] === ')' ? p : undefined
      } else if (depth === 0 && /[=(,{;]/.test(c)) return undefined
    }
    return undefined
  }
  // The name a function is bound to (`const drawCard = async (`), from where its parameters start.
  const nameBefore = (i: number): string | undefined =>
    /(?:^|[^\w$.])(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=;]*)?=\s*(?:async\s*)?(?:function\b\s*\*?\s*)?(?:<[^()]*>\s*)?$/.exec(blank.slice(Math.max(0, i - 300), i))?.[1]
  // What a function with no name is handed to: the `xs` of `xs.map(` or `[...].map(`, or the function
  // a callback is handed to, which decides its values.
  const receiverOf = (start: number): Fn['receiver'] => {
    const p = skipBack(start - 1)
    if (blank[p] !== '(' && blank[p] !== ',') return undefined
    let o: number | undefined
    for (const [x, c] of pairs) {
      if (x >= start) break
      if (c >= start && blank[x] === '(') o = x
    }
    if (o === undefined) return undefined
    const q = skipBack(o - 1)
    const before = blank.slice(Math.max(0, q - 300), q + 1)
    const chain = /([A-Za-z_$][\w$]*)((?:\s*\??\.\s*[A-Za-z_$][\w$]*)*)$/.exec(before)
    if (chain) {
      const at = q + 1 - chain[0].length
      if (!isWord(at - 1) && blank[at - 1] !== '.') return { at, name: chain[1] as string }
    }
    const bracket = /[\])]((?:\s*\??\.\s*[A-Za-z_$][\w$]*)+)$/.exec(before)
    if (bracket) {
      const c = q - bracket[0].length + 1
      const x = openAt.get(c)
      if (x !== undefined) return [x, c + 1]
    }
    return undefined
  }
  const fns: Fn[] = []
  for (const m of blank.matchAll(/=>/g)) {
    const arrow = m.index as number
    let j: number | undefined = skipBack(arrow - 1)
    let params: string[][] | undefined
    let start = j
    if (blank[j] !== ')' && isWord(j)) {
      const id = wordBack(j)
      const before = skipBack(j - id.length)
      // A lone parameter (`x =>`, `async x =>`), never the end of a return type (`): A | B =>`).
      if (before < 0 || /[(,=[{;?]/.test(blank[before] as string) || ['async', 'return'].includes(wordBack(before))) {
        params = [[id]]
        start = j - id.length + 1
      } else j = returnTypeParen(arrow)
    } else if (blank[j] !== ')') j = returnTypeParen(arrow)
    if (params === undefined) {
      const o = j === undefined ? undefined : openAt.get(j)
      if (j === undefined || o === undefined) continue
      params = namesIn(o + 1, j)
      start = o
    }
    let head = start
    const p = skipBack(head - 1)
    if (wordBack(p) === 'async') head = p - 4
    const b = skipOn(arrow + 2)
    const to = blank[b] === '{' ? (close.get(b) ?? n - 1) + 1 : exprEnd(b)
    const name = nameBefore(start)
    fns.push({ from: start, to, body: b, params, ...(name ? { name } : { receiver: receiverOf(head) }) })
  }
  for (const m of blank.matchAll(/\bfunction\b\s*\*?\s*([\w$]*)\s*\(/g)) {
    const paren = (m.index as number) + m[0].length - 1
    const end = close.get(paren)
    const brace = end === undefined ? -1 : blank.indexOf('{', end)
    const shut = close.get(brace)
    if (end === undefined || shut === undefined) continue
    const name = m[1] || nameBefore(m.index as number)
    fns.push({ from: m.index as number, to: shut + 1, body: brace, params: namesIn(paren + 1, end), ...(name ? { name } : { receiver: receiverOf(m.index as number) }) })
  }
  // The innermost function holding i, as an index into fns, or -1 at the top level; `not` excepted.
  const fnAt = (i: number, not = -1): number => {
    let best = -1
    fns.forEach((g, k) => {
      if (k !== not && g.from <= i && i < g.to && (best < 0 || g.from >= (fns[best] as Fn).from)) best = k
    })
    return best
  }
  const locals: Local[] = []
  for (const m of blank.matchAll(/(?:^|[^\w$.])(const|let|var)\s+/g)) {
    const kw = (m.index as number) + m[0].indexOf(m[1] as string)
    const owner = fnAt(kw)
    if (owner < 0) continue
    let p = kw + (m[0].length - m[0].indexOf(m[1] as string))
    let names: string[]
    if (blank[p] === '{' || blank[p] === '[') {
      const c = close.get(p) ?? p
      names = namesIn(p, c + 1)[0] ?? []
      p = c + 1
    } else {
      const id = /^[A-Za-z_$][\w$]*/.exec(blank.slice(p, p + 100))
      if (!id) continue
      names = [id[0]]
      p += id[0].length
    }
    // Its value: after `=`, `of` or `in`, past a type on the same line, never the next line's `=`.
    const v = /^[ \t]*(?::[^=;\n]*?)?[ \t]*(=(?![=>])|\bof\b|\bin\b)/.exec(blank.slice(p, p + 300))
    const end = exprEnd(v ? p + v[0].length : p)
    for (const name of names) locals.push({ name, span: [kw, end], owner })
    // A `let` assigned again later in its function is followed to each value it is given.
    if (m[1] !== 'let') continue
    const f = fns[owner] as Fn
    for (const name of names)
      for (const a of blank.slice(f.from, f.to).matchAll(new RegExp(`(?:^|[^\\w$.])(${name.replace(/\$/g, '\\$')})\\s*[-+*/|&?]*=(?![=>])`, 'g'))) {
        const at = f.from + (a.index as number) + a[0].indexOf(name)
        if (at > end) locals.push({ name, span: [at, exprEnd(f.from + (a.index as number) + a[0].length)], owner })
      }
  }
  // A function declared by name inside another is one of that function's locals.
  fns.forEach((g, k) => {
    if (!g.name || !/^function\b/.test(blank.slice(g.from, g.from + 8))) return
    const owner = fnAt(g.from, k)
    if (owner >= 0) locals.push({ name: g.name, span: [g.from, g.to], owner })
  })
  const NOT_CALLS = new Set(['if', 'for', 'while', 'switch', 'catch', 'return', 'typeof', 'await', 'yield', 'in', 'of', 'case', 'do', 'else', 'void', 'delete', 'throw', 'function', 'async'])
  // Whether a `(` opens a call's arguments, not a grouping, a condition or a function's parameters.
  const isCall = (o: number): boolean => {
    const p = skipBack(o - 1)
    const c = blank[p] ?? ''
    if (c === ')' || c === ']') return true
    if (c === '.') return blank[p - 1] === '?'
    if (c === '>') return blank[p - 1] !== '='
    return isWord(p) && !NOT_CALLS.has(wordBack(p))
  }
  // Where each name is called: its offset and its call's `(`. A function's own declaration is no call.
  const calls = new Map<string, number[]>()
  for (const m of blank.matchAll(/[A-Za-z_$][\w$]*/g)) {
    const at = m.index as number
    if (isWord(at - 1) || (blank[at - 1] === '.' && blank.slice(at - 3, at) !== '...')) continue
    const o = skipOn(at + m[0].length)
    if (blank[o] !== '(' || wordBack(skipBack(at - 1)) === 'function') continue
    calls.set(m[0], [...(calls.get(m[0]) ?? []), o])
  }
  // A call's arguments, by position, from its `(`.
  const args = (o: number): Span[] | null => {
    const c = close.get(o)
    if (c === undefined) return null
    const out: Span[] = []
    let from = o + 1
    for (let j = o + 1; j <= c; j++) {
      const ch = blank[j]
      if (j < c && (ch === '(' || ch === '[' || ch === '{')) j = close.get(j) ?? j
      else if (ch === ',' || j === c) {
        const a = skipOn(from)
        let e = j
        while (e > a && isSpace(e - 1)) e--
        if (e > a) out.push([a, e])
        from = j + 1
      }
    }
    return out
  }
  const drawParen = new RegExp(DRAW_CALL.source, 'y')
  const ownParen = (u: Span): number | undefined => {
    drawParen.lastIndex = u[0]
    const m = drawParen.exec(blank)
    return m ? u[0] + m[0].length - 1 : undefined
  }
  // Where in [a, b) a value is only tested, never itself the value: a ternary's condition, each
  // operand of `&&` but the last, an operand holding a comparison or led by `!` or `typeof` (#1296).
  // A test decides which value is drawn, as logic does, so what it names is not followed.
  const testsIn = (a: number, b: number, own?: number): Span[] => {
    const out: Span[] = []
    // The depth-0 places in [x, y) where `at(j)` holds, a group's inside skipped.
    const scan = (x: number, y: number, at: (j: number) => number): [number, number][] => {
      const hits: [number, number][] = []
      for (let j = x; j < y; j++) {
        if (mask[j]) continue
        const c = blank[j]
        if (c === '(' || c === '[' || c === '{') {
          j = close.get(j) ?? j
          continue
        }
        const len = at(j)
        if (len > 0) {
          hits.push([j, len])
          j += len - 1
        }
      }
      return hits
    }
    const op = (s: string) => (j: number) => (blank.startsWith(s, j) ? s.length : 0)
    const ternary = (j: number) => (blank[j] === '?' && blank[j + 1] !== '.' && blank[j + 1] !== '?' && blank[j - 1] !== '?' ? 1 : 0)
    const COMPARE = /^(?:===|!==|==|!=|<=|>=|instanceof\b|in\b)/
    const compares = (j: number) => {
      const m = COMPARE.exec(blank.slice(j, j + 12))
      if (m && (/[\w$]/.test(m[0]) ? !isWord(j - 1) : true)) return m[0].length
      const c = blank[j]
      // A lone `<` or `>`, not an arrow's `=>`, a shift, or a generic's bracket after a name.
      if ((c === '<' || c === '>') && blank[j - 1] !== '=' && blank[j + 1] !== c && blank[j - 1] !== c && blank[j + 1] !== '=' && /\s/.test(blank[j - 1] ?? '') && /\s/.test(blank[j + 1] ?? '')) return 1
      return 0
    }
    const groups = (x: number, y: number) => {
      for (let j = x; j < y; j++) {
        if (mask[j]) continue
        const c = blank[j]
        if (c === '(' || c === '[' || c === '{') {
          const e = close.get(j) ?? j
          if (c !== '(' || !isCall(j) || j === own) level(j + 1, e, c === '{')
          j = e
        }
      }
    }
    const operand = (x: number, y: number) => {
      const lead = blank.slice(x, y).trimStart()
      if (lead.startsWith('!') || /^typeof\b/.test(lead) || scan(x, y, compares).length) out.push([x, y])
      else groups(x, y)
    }
    const ands = (x: number, y: number) => {
      let s = x
      for (const [j, len] of scan(x, y, op('&&'))) {
        out.push([s, j])
        s = j + len
      }
      operand(s, y)
    }
    const value = (x: number, y: number) => {
      let s = x
      for (const [j, len] of scan(x, y, k => op('||')(k) || op('??')(k))) {
        ands(s, j)
        s = j + len
      }
      ands(s, y)
    }
    const segment = (x0: number, y: number, braces: boolean) => {
      let x = x0
      // An object's key is no part of its value.
      const key = braces ? /^\s*(?:[A-Za-z_$][\w$]*|\[[^\]]*\])\s*:(?!:)/.exec(blank.slice(x, y)) : null
      if (key) x += key[0].length
      const q = scan(x, y, ternary)[0]
      if (!q) {
        value(x, y)
        return
      }
      // Its `:`, nested ternaries counted.
      let depth = 0
      let colon = -1
      for (const [j] of scan(q[0] + 1, y, k => ternary(k) || (blank[k] === ':' ? 1 : 0))) {
        if (blank[j] === '?') depth++
        else if (depth === 0) {
          colon = j
          break
        } else depth--
      }
      out.push([x, q[0]])
      if (colon < 0) {
        value(q[0] + 1, y)
        return
      }
      segment(q[0] + 1, colon, false)
      segment(colon + 1, y, false)
    }
    const level = (x: number, y: number, braces: boolean) => {
      let s = x
      for (const [j] of scan(x, y, k => (blank[k] === ',' || blank[k] === ';' ? 1 : 0))) {
        segment(s, j, braces)
        s = j + 1
      }
      segment(s, y, braces)
    }
    level(a, b, false)
    return out
  }
  // What a followed value treats as data or a test, each region's inside: a call's arguments (the
  // part's own drawing call's aside) and every test position.
  const cutIn = (a: number, b: number, own?: number): Span[] => {
    const out: Span[] = []
    for (const [o, c] of pairs) if (o >= a && o < b && o !== own && blank[o] === '(' && isCall(o)) out.push([o, c])
    out.push(...testsIn(a, b, own).map(([x, y]): Span => [x - 1, y]))
    // What a drawing call is handed to say which surface it draws, never how (a blocked card's
    // `toolUseId`, a band row's `mod`, `id` and `slot`, a pane's `id`): not followed.
    const shut = own === undefined ? undefined : close.get(own)
    if (own !== undefined && shut !== undefined)
      for (const m of blank.slice(own, shut).matchAll(/([{,]\s*)(toolUseId|id|mod|slot)\b\s*(:?)/g)) {
        const at = own + (m.index as number) + (m[1] as string).length
        if (!m[3]) out.push([at - 1, at + (m[2] as string).length])
        else {
          const v = at + m[0].length - (m[1] as string).length
          out.push([v - 1, exprEnd(v)])
        }
      }
    return out
  }
  // A followed value's code with what it treats as data or a test taken out, as `<cut>`, so a change to
  // which data a value is made from is no change to what is drawn (#1296).
  const cutCode = ([a, b]: Span): string => {
    const regions = cutIn(a, b).sort((x, y) => x[0] - y[0])
    let out = ''
    let i = a
    for (const [x, y] of regions) {
      if (y <= i || x + 1 >= y) continue
      if (x + 1 > i) out += code([i, x + 1])
      out += '<cut>'
      i = y
    }
    return out + (i < b ? code([i, b]) : '')
  }
  const refsAt = ([a, b]: Span, cut: boolean, own?: number): { name: string; at: number; call: boolean }[] => {
    const inCalls: Span[] = cut ? cutIn(a, b, own) : []
    const out: { name: string; at: number; call: boolean }[] = []
    for (const m of blank.slice(a, b).matchAll(/[A-Za-z_$][\w$]*/g)) {
      const at = a + (m.index as number)
      const before = blank[at - 1] ?? ''
      if (/[\w$]/.test(before) || (before === '.' && blank.slice(at - 3, at) !== '...')) continue
      if (handlers.some(([x, y]) => x <= at && at < y)) continue
      if (inCalls.some(([x, y]) => x < at && at < y)) continue
      // An object's key (`{ title: r }`) names no binding.
      const after = skipOn(at + m[0].length)
      if (blank[after] === ':' && blank[after + 1] !== ':' && /[{,]/.test(blank[skipBack(at - 1)] ?? '')) continue
      // In a followed value, what a method is called on (`args.find(...)`, `words.slice(1)`) is data
      // being worked on, which file or command a sentence names, not its look (#1296).
      // A name only typeof reads (in a type, or a test) is never the value.
      if (cut && wordBack(skipBack(at - 1)) === 'typeof') continue
      if (cut) {
        const chain = /^(?:\s*\??\.\s*[A-Za-z_$][\w$]*)+\s*(?:\?\.\s*)?\(/.exec(blank.slice(at + m[0].length, at + m[0].length + 200))
        if (chain) continue
      }
      out.push({ name: m[0], at, call: blank[after] === "(" })
    }
    return out
  }
  const returns = (k: number): Span[] => {
    const g = fns[k] as Fn
    if (g.returns) return g.returns
    if (blank[g.body] !== '{') g.returns = [[g.body, g.to]]
    else {
      g.returns = []
      for (const m of blank.slice(g.body, g.to).matchAll(/(?:^|[^\w$.])return\b/g)) {
        const at = g.body + (m.index as number) + m[0].length
        if (fnAt(at) !== k) continue
        // A bare `return` gives nothing; its value starts on the same line.
        const v = at + (/^[ \t]*/.exec(blank.slice(at, at + 200)) as RegExpExecArray)[0].length
        if (blank[v] === '\n' || blank[v] === ';' || blank[v] === '}') continue
        const end = exprEnd(v)
        if (end > v) g.returns.push([v, end])
      }
    }
    return g.returns
  }
  return { name: f.name, statements, imports, units, code, refs, isTop: x => tops.has(x), refsAt, fns, locals, calls, args, ownParen, returns, cutCode }
}

/**
 * What in the mod hook file `name` decides what its mod draws (#1275), each part as its code with
 * comments taken out and spacing made one space (strings kept whole), or null where any of the mod's
 * files cannot be read. The parts: each drawing call there (DRAW_CALL) and JSX element; each function
 * building one of mod-kit's text runs, dividers or buttons (cardLines, finishedLine), whole where it
 * is a top level one; and every top level declaration any part, in this file or another of the mod's,
 * names, through the imports between them, and in turn what each of those names. A type draws nothing.
 * Since #1296 a value reaching a part through a local or a parameter is followed too: a local's
 * declaration, a parameter's argument at each call of its function in the mod's files (a guard's
 * blocked card sentence handed to its drawCard), the values a function returns where a followed value
 * calls it, and the `xs` a callback's `xs.map(x => ...)` takes its values from; each compared with
 * what it treats as data or a test taken out (cutCode). Not followed, as no part of the look: what a
 * call it makes is handed, what a value is only tested for, what a method is called on, a called
 * function's or line builder's own parameters, and which surface a drawing call names (toolUseId).
 */
export const drawnParts = (files: readonly ModFile[], name: string): string[] | null => {
  const read = new Map<string, ModRead>()
  for (const f of files) {
    const r = readMod(f)
    if (!r) return null
    read.set(f.name, r)
  }
  const drawn = new Set<string>()
  const queue: [string, string][] = []
  // The file an import names, as TypeScript finds it: as written, then with `.js` read as `.ts`,
  // then with `.ts` or `.tsx` added (lessons review).
  const fileOf = (spec: string): ModRead | undefined => [spec, spec.replace(/\.(m|c)?js$/, '.$1ts'), `${spec}.ts`, `${spec}.tsx`].map(x => read.get(x)).find(Boolean)
  const reach = (file: string, x: string) => {
    const r = read.get(file)
    if (!r) return
    if (r.isTop(x)) {
      const key = `${file}\n${x}`
      if (!drawn.has(key)) {
        drawn.add(key)
        queue.push([file, x])
      }
      return
    }
    const via = r.imports.get(x)
    const g = via ? fileOf(via.file) : undefined
    if (!via || !g) return
    if (via.name !== '*') {
      reach(g.name, via.name)
      return
    }
    for (const s of g.statements) if (s.name !== undefined && !s.isType) reach(g.name, s.name)
  }
  // #1296: a value reaching what draws through a local or a parameter. A local's whole declaration is
  // drawn, and a parameter's argument at each call of its function, in the mod's files; what those
  // name is followed in turn, where it is not handed into a call they make (the call's function is
  // followed, its arguments are data: the files a card names are not its look).
  const extra = new Map<string, Map<string, Span>>()
  // Each followed value, and for one a called function returns (`inputs`), that function: its own
  // parameters are its inputs, data its callers hand it, so they are not followed back to them.
  const spans: [string, Span, number | undefined][] = []
  const queued = new Set<string>()
  const addSpan = (file: string, s: Span, inputs?: number) => {
    const m = extra.get(file) ?? new Map<string, Span>()
    m.set(`${s[0]}:${s[1]}`, s)
    extra.set(file, m)
    const key = `${file}\n${s[0]}:${s[1]}\n${inputs ?? ''}`
    if (queued.has(key)) return
    queued.add(key)
    spans.push([file, s, inputs])
  }
  const flowed = new Set<string>()
  const flow = (file: string, k: number, i: number) => {
    const key = `${file}\n${k}\n${i}`
    if (flowed.has(key)) return
    flowed.add(key)
    const r = read.get(file) as ModRead
    const f = r.fns[k] as Fn
    if (f.receiver) {
      if (Array.isArray(f.receiver)) addSpan(file, f.receiver as Span)
      else {
        const { name: x, at } = f.receiver as { at: number; name: string }
        reach(file, x)
        bind(file, x, at)
      }
      return
    }
    if (!f.name) return
    // Its calls: inside the function holding it, or, for one at the top level, anywhere in its file
    // and in each of the mod's files importing it.
    let outer = -1
    r.fns.forEach((g, j) => {
      if (j !== k && g.from <= f.from && f.to <= g.to && (outer < 0 || g.from >= (r.fns[outer] as Fn).from)) outer = j
    })
    const o = r.fns[outer]
    const sites: [ModRead, number][] = (r.calls.get(f.name) ?? []).filter(p => !o || (o.from <= p && p < o.to)).map(p => [r, p])
    if (!o)
      for (const g of read.values())
        for (const [alias, via] of g.imports) if (via.name === f.name && fileOf(via.file) === r) for (const p of g.calls.get(alias) ?? []) sites.push([g, p])
    for (const [g, p] of sites) {
      const a = g.args(p) ?? []
      const spread = a.findIndex(s => g.code(s).startsWith('...'))
      a.forEach((s, j) => {
        if (j === i || (spread >= 0 && spread <= i && j >= spread)) addSpan(g.name, s)
      })
    }
  }
  // The functions around offset `at`, innermost first.
  const around = (r: ModRead, at: number) =>
    r.fns
      .map((f, k) => [f, k] as const)
      .filter(([f]) => f.from <= at && at < f.to)
      .sort((a, b) => b[0].from - a[0].from)
  const returned = new Set<string>()
  const returnsOf = (file: string, k: number) => {
    const key = `${file}\n${k}`
    if (returned.has(key)) return
    returned.add(key)
    for (const s of (read.get(file) as ModRead).returns(k)) addSpan(file, s, k)
  }
  // A function a followed value calls gives it what it returns, not its whole body: a refusal's
  // reader (`blockedCommand`) gives the words it returns, never the matching that chose them. True
  // where `x` called at `at` is such a function, a local one, one at the top level, or one imported.
  const callee = (file: string, x: string, at: number): boolean => {
    const r = read.get(file) as ModRead
    for (const [f, k] of around(r, at)) {
      const own = r.locals.filter(l => l.owner === k && l.name === x)
      if (own.length) {
        const g = r.fns.findIndex(h => h.name === x && own.some(l => l.span[0] <= h.from && h.to <= l.span[1]))
        if (g < 0) return false
        returnsOf(file, g)
        return true
      }
      if (f.params.some(p => p.includes(x))) return false
    }
    const top = (g: ModRead, name: string): boolean => {
      const s = g.statements.find(s => s.name === name && !s.isType)
      const k = s ? g.fns.findIndex(h => h.name === name && s.from <= h.from && h.to <= s.to) : -1
      if (k < 0) return false
      returnsOf(g.name, k)
      return true
    }
    if (r.isTop(x)) return top(r, x)
    const via = r.imports.get(x)
    const g = via && via.name !== '*' ? fileOf(via.file) : undefined
    return via !== undefined && g !== undefined && top(g, via.name)
  }
  const bind = (file: string, x: string, at: number, inputs?: number) => {
    if (x === '$') return
    const r = read.get(file) as ModRead
    const within = inputs === undefined ? undefined : r.fns[inputs]
    for (const [f, k] of around(r, at)) {
      const own = r.locals.filter(l => l.owner === k && l.name === x)
      if (own.length) {
        // A local of the called function carries on as one of its values.
        for (const l of own) addSpan(file, l.span, within && within.from <= l.span[0] && l.span[1] <= within.to ? inputs : undefined)
        return
      }
      const i = f.params.findIndex(p => p.includes(x))
      if (i >= 0) {
        if (k !== inputs) flow(file, k, i)
        return
      }
    }
  }
  for (const r of read.values())
    for (const u of r.units) {
      for (const x of r.refs(u)) reach(r.name, x)
      const own = r.ownParen(u)
      // A line builder (a unit that is a function, whole) is drawn with its own words; what it is
      // handed is the data it shows, so its parameters are its inputs, as a called function's are.
      const builder = own === undefined && !r.code(u).startsWith('<') ? r.fns.findIndex(f => (u[0] <= f.from && f.to <= u[1]) || f.body === u[0]) : -1
      for (const { name: x, at } of r.refsAt(u, true, own)) bind(r.name, x, at, builder < 0 ? undefined : builder)
    }
  while (queue.length || spans.length) {
    const next = spans.pop()
    if (next) {
      const [file, s, inputs] = next
      const r = read.get(file) as ModRead
      for (const { name: x, at, call } of r.refsAt(s, true)) {
        if (call && callee(file, x, at)) continue
        reach(file, x)
        bind(file, x, at, inputs)
      }
      continue
    }
    const [file, x] = queue.pop() as [string, string]
    const r = read.get(file) as ModRead
    for (const s of r.statements) if (s.name === x && !s.isType) for (const y of r.refs([s.from, s.to])) reach(file, y)
  }
  const r = read.get(name)
  if (!r) return []
  const parts = new Map(r.units.map(u => [`${u[0]}:${u[1]}`, u]))
  for (const s of r.statements) if (s.name !== undefined && drawn.has(`${name}\n${s.name}`)) parts.set(`${s.from}:${s.to}`, [s.from, s.to])
  const followed = new Map(extra.get(name) ?? [])
  for (const key of parts.keys()) followed.delete(key)
  return [...[...parts.values()].map(u => r.code(u)), ...[...followed.values()].map(s => r.cutCode(s))].sort()
}

/**
 * Whether changing the mod hook file `name` from `before` to `after` (undefined for a file not there)
 * changes what its mod draws (#1275), read beside the mod's other hook files in `files`: whether
 * drawnParts differ. A file any of them cannot be read in is held, never passed.
 */
export const drawsChange = (files: readonly ModFile[], name: string, before: string | undefined, after: string | undefined): boolean => {
  const others = files.filter(f => f.name !== name)
  const at = (text: string | undefined) => drawnParts(text === undefined ? others : [...others, { name, text }], name)
  const was = at(before)
  const now = at(after)
  if (!was || !now) return true
  return was.length !== now.length || was.some((p, i) => p !== now[i])
}

/** A call written out whole, in a fixed order: its tool, every key of its input, its folder and session. */
export const callText = (tool: string, input: Record<string, unknown>, at: { cwd: string; session: string }): string => {
  const canon = (v: unknown): unknown =>
    Array.isArray(v) ? v.map(canon) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map(k => [k, canon((v as Record<string, unknown>)[k])])) : v
  return JSON.stringify([tool, canon(input), at.cwd, at.session])
}

/**
 * What a refused call is known by, so the same call sent again is recognised when Dan has answered
 * Not a look change for it: the tool and every key of its input, in a fixed order, with the folder it
 * runs in and the session, hashed (cyrb53). The folder because a shell command's relative path names
 * another file elsewhere; the session so his word about one edit does not stand for ever (lessons
 * review of #1010). The hash only finds the record: the record keeps callText, and a call is let
 * through only when its own text is that text, since the call's input is Claude's to write.
 */
export const callKey = (tool: string, input: Record<string, unknown>, at: { cwd: string; session: string }): string => {
  const text = callText(tool, input, at)
  let h1 = 0xdeadbeef
  let h2 = 0x41c6ce57
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i)
    h1 = Math.imul(h1 ^ c, 2654435761)
    h2 = Math.imul(h2 ^ c, 1597334677)
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909)
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909)
  return `${tool}:${(4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16)}:${text.length}`
}

/** Whether a path is this mod's own store file, which only Dan's answers may write: in the plugin store, or by its name wherever its folder could not be followed. */
export const isOwnRecord = (path: string): boolean => /\/plugins\/store\/design-round-guard[_.]/.test(path) || /(^|\/)design-round-guard_[^/]*$/.test(path)

/** A command naming the plugin store at all, judged where its words do not name what it writes. */
export const mentionsStore = (text: string): boolean => /plugins\/store/.test(text)

/**
 * What a settled round or a skip is kept under (#978, plan point 5): the project's main working
 * tree, so every worktree of it shares one, then the issue the branch names, each one when it names
 * several, or the branch when it names none. The default branch names no issue and every later issue
 * may be built on it, so a record there holds for this session only (the stricter reading where the
 * plan is silent). `issue` is one the settled question names itself, whatever the branch. Where the
 * checkout stands is mod-kit's one reading of it (`$.modkit.branch`), and `repo` the project's name
 * as `$.modkit.repo` gives it.
 */
export const subjectsOf = (at: { main: string; repo: string; session: string } & ({ issue: number } | { branch: string; isDefault: boolean; issues: readonly number[] })): DesignRoundSubject[] => {
  const issue = (n: number): DesignRoundSubject => ({ key: `record:${at.main}|issue:${n}`, label: `issue #${n} in ${at.repo}` })
  if ('issue' in at) return [issue(at.issue)]
  if (at.isDefault) return [{ key: `record:${at.main}|branch:${at.branch}|session:${at.session}`, label: `${at.branch} in ${at.repo}, for this session` }]
  if (at.issues.length) return at.issues.map(issue)
  return [{ key: `record:${at.main}|branch:${at.branch}`, label: `branch ${at.branch} in ${at.repo}` }]
}

export const listed = (xs: readonly string[]): string => (xs.length <= 1 ? (xs[0] ?? '') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`)
const named = (subjects: readonly DesignRoundSubject[]) => listed(subjects.map(s => s.label))

// A refusal holds the change it refused, never the file (#1158): told "Do not change <file> any other
// way", a session that had made an edit the guard let through could not undo it, so the edit stayed.
// That an undo is judged by its lines is said only where it is: every file a React one (judgedByText)
// or a mod's TypeScript hook file (isModHookTs, #1275); a stylesheet is judged whole however it is put
// back (lessons review of #1158).
const leaveIt = (files: readonly string[]) =>
  `Do not make this change to ${listed(files)} any other way` +
  (files.every(f => judgedByText(f) || isModHookTs(f)) ? '; undoing an earlier edit of your own is judged by the lines it changes, as an edit is.' : '.')

// What a refusal says of a git checkout or restore whose lines could not be measured (#1158), each
// as unreadPutBack gives it, so the session is told why the whole file was judged.
const unreadSaid = (unread: readonly string[]) => (unread.length ? `${unread.join(' ')} ` : '')

/** One file a git checkout or restore puts back that could not be read, and why (#1158). */
export const unreadPutBack = (file: string, why: string): string =>
  `The design round guard could not read what git puts back in ${file} (${why}), so it judged the whole file as a look change rather than the lines it changes.`

/**
 * Where a design round's own files go (#1191), said wherever an edit is held: a round's files held
 * in the project sent Claude to /design-rounds, which it was already running, so every way on led
 * back to the refusal.
 */
export const ROUND_FILES = `A design round's own working files (its builder, stylesheet, spec and switcher) go in this session's scratchpad, which the guard never holds: if this is one, write it there, naming it by its full path or after a cd there.`

/** What the main session reads when a look changing edit is refused: the files, and the two ways on (plan point 3). */
export const refusal = (id: string, files: readonly string[], subjects: readonly DesignRoundSubject[], unread: readonly string[] = []): string => {
  const f = listed(files)
  const s = named(subjects)
  return (
    `Blocked: ${f} changes how the screen looks, and ${s} has no design round Dan has settled, nor his word to skip one. Dan decides the look, so take one of these two ways on and no other. ` +
    `1. Start /design-rounds; once Dan answers ${SETTLED_YES} to its closing question, "${SETTLED_QUESTION}", asked with metadata {"source": "${SETTLED_SOURCE}", "call": "${id}", "contract": ${CONTRACT}}, look changing edits on ${s} go through. ` +
    `2. Ask Dan one AskUserQuestion, with metadata {"source": "${SKIP_SOURCE}:${id}", "onScreen": "${ON_SCREEN_HINT}", "contract": ${CONTRACT}} and the question "${SKIP_QUESTION}"; the guard words the question and its answers itself, leading with your sentence and naming the file after it, and only his own choice of ${SKIP_YES} lets look changing edits on ${s} go ahead without a round, or his ${NOT_LOOK}, when nothing on screen changes, lets this one edit through. ` +
    unreadSaid(unread) +
    `${ROUND_FILES} ` +
    leaveIt(files)
  )
}

/** What a check with no call id reads ($.tool.check): the call would be refused, and making it says how to go on. */
export const checked = (files: readonly string[], subjects: readonly DesignRoundSubject[], unread: readonly string[] = []): string =>
  `Blocked: ${listed(files)} changes how the screen looks, and ${named(subjects)} has no design round Dan has settled, nor his word to skip one. ` +
  unreadSaid(unread) +
  `Making the call itself is refused with the two ways on: /design-rounds, or asking Dan "${SKIP_QUESTION}". ${ROUND_FILES}`

/** What a subagent reads: refused like the main session, never asking Dan itself (plan point 2). */
export const agentRefusal = (files: readonly string[], subjects: readonly DesignRoundSubject[], id: string, unread: readonly string[] = []): string => {
  const f = listed(files)
  return (
    `Blocked: ${f} changes how the screen looks, and ${named(subjects)} has no design round Dan has settled, nor his word to skip one. A subagent never asks Dan. ` +
    unreadSaid(unread) +
    `Stop this change and report it to the main session as waiting on Dan, with this line word for word: "${SKIP_SOURCE}:${id}", and one plain sentence saying what on screen the change alters (which control or area, on which screen), or that nothing visible changes, which the main session's question to Dan leads with. ` +
    `The main session starts /design-rounds or asks Dan "${SKIP_QUESTION}", and once he answers, the change can be made again. ` +
    `${ROUND_FILES} ` +
    leaveIt(files)
  )
}

// The card Dan sees leads in plain words and names the file after (#1145; Dan, 2026-10-13: "I don't
// know what the file name means"). It is drawn when the call is refused, before the session has said
// what changes on screen, and a result row already drawn is not drawn again, so the plain sentence
// itself comes in the question that follows (#1138), and the card says that it will.
const CARD_LEAD = 'Claude wants to make an edit that may change how something looks on screen'

/** The card Dan sees for a refused look changing edit, drawn by mod-kit as every guard's is. */
export const card = (files: readonly string[], subjects: readonly DesignRoundSubject[]) => ({
  reason: `${CARD_LEAD}, for ${named(subjects)}, which has no settled design round. The file is ${listed(files)}.`,
  safeWay: `Claude tells you in plain words what would change, then starts /design-rounds or asks whether to skip them for this issue, or whether this edit changes the look at all.`,
})

/** The card when the issue or branch cannot be told. */
export const unsureCard = (files: readonly string[]) => ({
  reason: `${CARD_LEAD}, and the design round guard could not tell which issue or branch it belongs to. The file is ${listed(files)}.`,
  safeWay: 'Claude checks out the issue branch, or asks you.',
})

/** The card when the record of Dan's answers cannot be read. */
export const unreadableCard = (files: readonly string[]) => ({
  reason: `${CARD_LEAD}, and the design round guard could not read its record of your answers. The file is ${listed(files)}.`,
  safeWay: 'Claude tries again, or tells you.',
})

/** Failing closed when the issue or branch cannot be told (#978: "saying so"). */
export const unsure = (files: readonly string[], why: string): string =>
  `Blocked: ${listed(files)} changes how the screen looks, and the design round guard could not tell which issue or branch it belongs to (${why}), so it cannot tell whether Dan settled its design or skipped design rounds for it. ` +
  `Check out the issue's branch (a detached head names none) and try again, or ask Dan. ${ROUND_FILES}`

/** Failing closed when the record of Dan's answers cannot be read: never read as no answer, nor as one. */
export const unreadable = (files: readonly string[], subjects: readonly DesignRoundSubject[], why: string): string =>
  `Blocked: ${listed(files)} changes how the screen looks, and the design round guard's record of Dan's answers could not be read (${why}), so it cannot tell whether he settled a design round for ${named(subjects)}. Try again; if it keeps failing, tell Dan. ${ROUND_FILES}`

/** A write to the guard's own record: only Dan's answers may write it. */
export const forged = (path: string): string =>
  `Blocked: this would change the design round guard's own record (${path}), which only Dan's answers to its two questions may write. ` +
  `To go on, start /design-rounds, or ask Dan "${SKIP_QUESTION}" as the guard says when it refuses a look changing edit.`

export const cannotCheck = (why: string): string => `Blocked: the design round guard could not check this call (${why}), so it was stopped. Try again; if it keeps failing, tell Dan.`

/**
 * What became of a shell write the guard judged once it ran (#1296): a change to a mod's .ts hook file
 * that made it draw, put back with what the command wrote kept first (`undone`, where it is kept), or
 * not put back, and why: no copy could be kept (`unkept`), the file changed again after the command
 * wrote it (`changed`, where the copy is), putting it back failed (`failed`), or the file could not be
 * read after the command (`unread`). Only `undone` ever says the change was undone.
 */
export type ShellOutcome =
  | { file: string; undone: string }
  | { file: string; unkept: string }
  | { file: string; changed: string }
  | { file: string; failed: string; kept: string }
  | { file: string; unread: string }
export const shellOutcome = (o: ShellOutcome): string => {
  const notUndone = `The command ran and changed what the mod draws in ${o.file}, and that change was NOT undone:`
  if ('undone' in o) return `The command ran, and its change to ${o.file} was undone: it changed what the mod draws on screen. What the command wrote there is kept at ${o.undone}.`
  if ('unkept' in o) return `${notUndone} the design round guard could not keep a copy of what the command wrote (${o.unkept}), so it left the file as the command left it.`
  if ('changed' in o) return `${notUndone} the file changed again after the command wrote it, so putting the earlier text back would lose that later change. What the command wrote is kept at ${o.changed}.`
  if ('failed' in o) return `${notUndone} putting the earlier text back failed (${o.failed}). The file still holds what the command wrote, also kept at ${o.kept}.`
  return `The command ran, and the design round guard could not read ${o.file} after it (${o.unread}), so whether it changed what the mod draws is unknown; the file was left as the command left it.`
}
/** A check after a shell write that itself failed (#1296): the command ran, and nothing was undone. */
export const shellUnchecked = (why: string): string =>
  `The command ran, but the design round guard could not check afterwards whether it changed what a mod draws (${why}), so nothing was undone. Check the mod's hook files the command wrote, and tell Dan.`

/** What the skip question's `onScreen` asks for, as the refusal shows Claude it (#1138). */
export const ON_SCREEN_HINT = '<one plain sentence for Dan: what on screen this edit changes, which control or area on which screen, or that nothing visible changes>'
/** The longest `onScreen` the question leads with: one sentence, which the dialog shows whole. */
export const ON_SCREEN_MAX = 300

/**
 * Why the session's sentence for the skip question cannot lead it, or undefined when it can (#1138).
 * Dan, 2026-10-13: "I don't know what the file name means or what this change will do". So the
 * question never falls back to the file: no sentence, or one naming a file, is refused and nothing is
 * asked.
 */
export const onScreenProblem = (onScreen: unknown, files: readonly string[]): string | undefined => {
  const ask = `Give metadata "onScreen" as one plain sentence for Dan saying what on screen this edit changes (which control or area, on which screen, as "The Save button on the invoice screen turns blue"), or that nothing visible changes and what the edit does instead.`
  if (typeof onScreen !== 'string' || !onScreen.trim()) return `Nothing was asked: the question leads with what Dan will see change, and a file name tells him nothing. ${ask}`
  const text = onScreen.trim()
  if (text.length > ON_SCREEN_MAX) return `Nothing was asked: "onScreen" is ${text.length} characters, and the question leads with it, so keep it to one sentence of at most ${ON_SCREEN_MAX}. ${ask}`
  const bases = files.map(f => (f.split('/').pop() ?? '').toLowerCase()).filter(Boolean)
  const lower = text.toLowerCase()
  const named = [...mentionedLookFiles(text), ...bases.filter(b => lower.includes(b))]
  if (named.length) return `Nothing was asked: "onScreen" names a file (${listed([...new Set(named)])}), which tells Dan nothing; the guard names the file itself, after your sentence. ${ask}`
  return undefined
}

/** The skip question as Dan reads it (#1138): what changes on screen in the session's words, then the plan's question, then the issue and the file. */
export const skipQuestion = (onScreen: string, files: readonly string[], subjects: readonly DesignRoundSubject[]): string => {
  const said = onScreen.trim()
  const lead = /[.!?]$/.test(said) ? said : `${said}.`
  return `${lead} ${SKIP_QUESTION} This is for ${named(subjects)}; the file is ${listed(files)}.`
}

export const skipOptions = (subjects: readonly DesignRoundSubject[]) => [
  { label: SKIP_YES, description: `Edits that change the look go ahead on ${named(subjects)} without a design round; the next issue asks again` },
  { label: SKIP_NO, description: 'Nothing that changes the look is edited until you settle a design round' },
  { label: NOT_LOOK, description: 'Nothing on screen changes, so only this edit goes ahead, recorded as your word; the next one is asked about again' },
]

// Dan typed an answer instead of choosing one (#1138): said to him and to Claude in mod-kit's one
// wording ($.modkit.typedAnswer, #1145), given what stays as it was and how to ask again.
/** The skip question's: the refused edit and the issue stay held, and the same question is asked again. */
export const skipTyped = (files: readonly string[], subjects: readonly DesignRoundSubject[]) => ({
  still: `the edit to ${listed(files)} stays held, as do edits that change the look on ${named(subjects)}`,
  again: 'ask him the same question again, with the same metadata',
})
/** The settled question's: nothing is settled, and it is asked again. */
export const settledTyped = () => ({ still: 'nothing is settled', again: `ask him "${SETTLED_QUESTION}" again, with the same metadata` })

/** Dan's Not a look change, kept with the refused call (#1010): what it let through, and why. */
export const notLookWhy = (files: readonly string[]): string =>
  `Dan answered "${NOT_LOOK}" to "${SKIP_QUESTION}": this edit to ${listed(files)} changes nothing on screen, so it went ahead with no design round.`

/** The design rounds skill's closing question as Dan reads it. */
export const settledQuestion = (subjects: readonly DesignRoundSubject[]): string =>
  `${SETTLED_QUESTION} ${SETTLED_YES} lets edits that change the look go ahead on ${named(subjects)}.`

export const settledOptions = (subjects: readonly DesignRoundSubject[]) => [
  { label: SETTLED_YES, description: `Recorded for ${named(subjects)}; edits that change the look go ahead` },
  { label: SETTLED_NO, description: 'Keep going with design rounds; nothing is recorded' },
]

/** Resolves a path as the shell would read it, from the folder the call runs in. */
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
  return '/' + out.join('/')
}
