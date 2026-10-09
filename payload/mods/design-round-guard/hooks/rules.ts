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

/** The look changing files a command's text names, for a write its words do not name (an inline script, a patch). */
export const mentionedLookFiles = (text: string): string[] => {
  const out: string[] = []
  for (const m of text.matchAll(/[\w./~@+*-]+\.[A-Za-z]+\b/g)) {
    const word = m[0].replace(/^[.]+(?=[^./])/, '')
    if (shapeKind(word) !== null && !out.includes(word)) out.push(word)
  }
  return out
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
    `1. Start /design-rounds; once Dan answers ${SETTLED_YES} to its closing question, "${SETTLED_QUESTION}", look changing edits on ${s} go through. ` +
    `2. Ask Dan one AskUserQuestion, with metadata {"source": "${SKIP_SOURCE}:${id}"} and the question "${SKIP_QUESTION}"; the guard words the question and its answers itself, and only his own choice of ${SKIP_YES} lets look changing edits on ${s} go ahead without a round. ` +
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
  safeWay: `Claude starts /design-rounds, or asks you whether to skip them for this issue.`,
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
]

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
