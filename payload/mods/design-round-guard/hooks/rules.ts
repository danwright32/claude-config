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
 * name (`open(app/page.tsx`) is not part of it; a folder holding one (`x(1)`) is.
 */
export const mentionedLookFiles = (text: string): string[] => {
  const out: string[] = []
  for (const m of text.matchAll(/[\w./~@+*[\]()-]+\.[A-Za-z]+\b/g)) {
    let word = m[0].replace(/^(?:[\w$.]+\()+/, '').replace(/^[.]+(?=[^./])/, '')
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
  return out
}

/**
 * Whether a name the write reader could not follow may still be a look changing file, its extension
 * being a pattern the shell can expand to one (`page.ts[x]`, `site.c?s`, `x.{css,md}`) (#1010).
 */
export const patternExtension = (word: string): boolean => {
  const base = word.split('/').pop() ?? ''
  const dot = base.lastIndexOf('.')
  return dot >= 0 && /[*?[\]{}]/.test(base.slice(dot + 1))
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

/** What the main session reads when a look changing edit is refused: the files, and the two ways on (plan point 3). */
export const refusal = (id: string, files: readonly string[], subjects: readonly DesignRoundSubject[]): string => {
  const f = listed(files)
  const s = named(subjects)
  return (
    `Blocked: ${f} changes how the screen looks, and ${s} has no design round Dan has settled, nor his word to skip one. Dan decides the look, so take one of these two ways on and no other. ` +
    `1. Start /design-rounds; once Dan answers ${SETTLED_YES} to its closing question, "${SETTLED_QUESTION}", asked with metadata {"source": "${SETTLED_SOURCE}", "call": "${id}"}, look changing edits on ${s} go through. ` +
    `2. Ask Dan one AskUserQuestion, with metadata {"source": "${SKIP_SOURCE}:${id}"} and the question "${SKIP_QUESTION}"; the guard words the question and its answers itself, and only his own choice of ${SKIP_YES} lets look changing edits on ${s} go ahead without a round, or his ${NOT_LOOK}, when nothing on screen changes, lets this one edit through. ` +
    `Do not change ${f} any other way.`
  )
}

/** What a check with no call id reads ($.tool.check): the call would be refused, and making it says how to go on. */
export const checked = (files: readonly string[], subjects: readonly DesignRoundSubject[]): string =>
  `Blocked: ${listed(files)} changes how the screen looks, and ${named(subjects)} has no design round Dan has settled, nor his word to skip one. ` +
  `Making the call itself is refused with the two ways on: /design-rounds, or asking Dan "${SKIP_QUESTION}".`

/** What a subagent reads: refused like the main session, never asking Dan itself (plan point 2). */
export const agentRefusal = (files: readonly string[], subjects: readonly DesignRoundSubject[], id: string): string => {
  const f = listed(files)
  return (
    `Blocked: ${f} changes how the screen looks, and ${named(subjects)} has no design round Dan has settled, nor his word to skip one. A subagent never asks Dan. ` +
    `Stop this change and report it to the main session as waiting on Dan, with this line word for word: "${SKIP_SOURCE}:${id}". ` +
    `The main session starts /design-rounds or asks Dan "${SKIP_QUESTION}", and once he answers, the change can be made again. Do not change ${f} any other way.`
  )
}

/** The card Dan sees for a refused look changing edit, drawn by mod-kit as every guard's is. */
export const card = (files: readonly string[], subjects: readonly DesignRoundSubject[]) => ({
  reason: `${listed(files)} changes how the screen looks, and ${named(subjects)} has no settled design round.`,
  safeWay: `Claude starts /design-rounds, or asks you whether to skip them for this issue, or whether this edit changes the look at all.`,
})

/** Failing closed when the issue or branch cannot be told (#978: "saying so"). */
export const unsure = (files: readonly string[], why: string): string =>
  `Blocked: ${listed(files)} changes how the screen looks, and the design round guard could not tell which issue or branch it belongs to (${why}), so it cannot tell whether Dan settled its design or skipped design rounds for it. ` +
  `Check out the issue's branch (a detached head names none) and try again, or ask Dan.`

/** Failing closed when the record of Dan's answers cannot be read: never read as no answer, nor as one. */
export const unreadable = (files: readonly string[], subjects: readonly DesignRoundSubject[], why: string): string =>
  `Blocked: ${listed(files)} changes how the screen looks, and the design round guard's record of Dan's answers could not be read (${why}), so it cannot tell whether he settled a design round for ${named(subjects)}. Try again; if it keeps failing, tell Dan.`

/** A write to the guard's own record: only Dan's answers may write it. */
export const forged = (path: string): string =>
  `Blocked: this would change the design round guard's own record (${path}), which only Dan's answers to its two questions may write. ` +
  `To go on, start /design-rounds, or ask Dan "${SKIP_QUESTION}" as the guard says when it refuses a look changing edit.`

export const cannotCheck = (why: string): string => `Blocked: the design round guard could not check this call (${why}), so it was stopped. Try again; if it keeps failing, tell Dan.`

/** The skip question as Dan reads it: the plan's words, then what it is about. */
export const skipQuestion = (files: readonly string[], subjects: readonly DesignRoundSubject[]): string =>
  `${SKIP_QUESTION} Claude wants to change how ${listed(files)} looks, on ${named(subjects)}, with no design round settled.`

export const skipOptions = (subjects: readonly DesignRoundSubject[]) => [
  { label: SKIP_YES, description: `Edits that change the look go ahead on ${named(subjects)} without a design round; the next issue asks again` },
  { label: SKIP_NO, description: 'Nothing that changes the look is edited until you settle a design round' },
  { label: NOT_LOOK, description: 'Nothing on screen changes, so only this edit goes ahead, recorded as your word; the next one is asked about again' },
]

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
