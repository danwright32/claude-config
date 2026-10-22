// The area check (claude-config#1506; phase 1, observe only, #1508): the facts about a file at the
// moment a session first edits it. Pure, so each rule is tested on its own, and so the replay of a
// real repository's history (tools/area-check-replay.ts) judges with exactly these rules (L107).
// Phase 1 only observes: these facts decide what is LOGGED, would_hold or quiet, never what is
// refused. The hold is turned on from a week of that log in #1509.
import { isTestPath } from './mod-kit/testfile.ts'

/** Bumped whenever a rule here changes what a file's facts are, so a cached ranking is never reused across it (L573). */
export const RULE_VERSION = 1
/** Claude Code's budget for a hook, measured at 10 s (docs/mods-design.md, standing rule 4). */
export const BUDGET_MS = 10_000
/** One deadline for the whole read of a file's facts, under 75% of the budget (L743). */
export const DEADLINE_MS = 7_000
/** How long a repository's open issues are reused before they are read again. */
export const ISSUES_TTL_MS = 60 * 60_000
/** How long a failed read is reused, so each edit does not pay for it again. */
export const UNREAD_TTL_MS = 10 * 60_000
/** The most open issues read in one list: a list this long may have been cut, so it is TRUNCATED. */
export const ISSUE_LIMIT = 1000
/** The growth window, in days. */
export const GROWTH_DAYS = 90
/** The growth bar (decision 6), provisional until #1509 calibrates it from the week's log. */
export const SIZE_MIN = 1500
export const GROWTH_MIN = 300
export const TOP_N = 10
/** Issues naming files in the same folder count when the folder has at most this many (decision 4). */
export const FOLDER_MAX = 5

/**
 * The structural label spellings, matched whole (L1023), measured 2026-10-22 across the 12 repo-digest
 * repositories and this one (L564): tech-debt in all 13, refactor in four, test-refactor in one.
 * Near spellings seen and deliberately left out, since Dan's decision 4 names tech-debt and refactor:
 * cleanup, consolidation, architecture, maintainability, hygiene, structure.
 */
export const STRUCTURAL_LABELS: readonly string[] = ['tech-debt', 'refactor', 'test-refactor']

/**
 * What counts as source (decision 3). test-match-open-issues-paths.sh holds every one of these to the
 * shared path reader's list, so an issue can always name such a file.
 */
export const SOURCE_EXTENSIONS: readonly string[] = ['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'py', 'sh', 'swift', 'rb', 'go', 'rs', 'java', 'kt', 'kts', 'vue', 'svelte', 'php', 'cs', 'cpp', 'c', 'h', 'm', 'css', 'scss']

/** The edit tools, each by the input key carrying its file (decision 2); a shell write is never judged. */
const PATH_KEY: Readonly<Record<string, string>> = { Edit: 'file_path', Write: 'file_path', MultiEdit: 'file_path', NotebookEdit: 'notebook_path' }

/** The absolute path an edit tool's call writes, or null for any other tool or a path that is not absolute. */
export const editedPath = (tool: string, input: Record<string, unknown>): string | null => {
  const key = PATH_KEY[tool]
  const p = key ? input[key] : undefined
  return typeof p === 'string' && p.startsWith('/') ? p : null
}

const GENERATED_PARTS = new Set(['node_modules', 'dist', 'build', 'out', '.next', 'vendor', '__generated__', 'generated', 'Generated'])
const MIGRATION_PARTS = new Set(['migrations', 'migration'])

/** Whether a path inside its checkout is a judged source file, a judged test file, or neither (decision 3). */
export const fileKind = (rel: string): 'source' | 'test' | null => {
  const parts = rel.split('/').filter(Boolean)
  const base = parts[parts.length - 1] ?? ''
  const ext = /\.([A-Za-z0-9]+)$/.exec(base)?.[1]?.toLowerCase()
  if (!ext || !SOURCE_EXTENSIONS.includes(ext)) return null
  if (parts.slice(0, -1).some(p => GENERATED_PARTS.has(p) || MIGRATION_PARTS.has(p))) return null
  if (/\.d\.[mc]?ts$/i.test(base) || /\.generated\./i.test(base) || /\.min\.(js|css)$/i.test(base)) return null
  // Configuration in a source language: tailwind.config.ts, eslint.config.js, .eslintrc.js.
  if (/(^|\.)config\.[mc]?[jt]s$/i.test(base) || /^\.[a-z]+rc\.[a-z]+$/i.test(base)) return null
  return isTestPath(rel) ? 'test' : 'source'
}

/** An issue's labels read as the area check needs them: its structural spellings, and its priority. */
export const labelFacts = (labels: readonly string[]): { structural: string[]; priority: string | null } => {
  const lower = labels.map(l => l.toLowerCase())
  const priority = lower.map(l => /^priority-(p[0-4])$/.exec(l)?.[1]).find(p => p !== undefined) ?? null
  return { structural: STRUCTURAL_LABELS.filter(s => lower.includes(s)), priority }
}

/** One open issue as the cache keeps it: its number, structural labels, priority and the paths it names. */
export type CachedIssue = { n: number; structural: string[]; priority: string | null; refs: string[] }
/** One issue in gh's list, its labels by name. */
export type IssueRow = { number: number; title: string; body: string; labels: string[] }
export type IssuesRead = { state: 'read' | 'truncated'; rows: IssueRow[] } | { state: 'unread'; why: string }

/** gh's open issue list read: UNREAD when it is not a list, TRUNCATED when it fills the limit. */
export const issuesRead = (stdout: string): IssuesRead => {
  const bad = { state: 'unread' as const, why: 'gh answered with something that is not an issue list' }
  let parsed: unknown
  try {
    parsed = JSON.parse(stdout)
  } catch {
    return bad
  }
  if (!Array.isArray(parsed)) return bad
  const rows: IssueRow[] = []
  for (const r of parsed as Record<string, unknown>[]) {
    if (!r || typeof r !== 'object' || typeof r.number !== 'number') return bad
    const labels = Array.isArray(r.labels) ? (r.labels as { name?: unknown }[]).map(l => String(l?.name ?? '')).filter(Boolean) : []
    rows.push({ number: r.number, title: typeof r.title === 'string' ? r.title : '', body: typeof r.body === 'string' ? r.body : '', labels })
  }
  return { state: rows.length >= ISSUE_LIMIT ? 'truncated' : 'read', rows }
}

/** The cache's issues: each row with the paths the shared reader found in it (none when it found none). */
export const toCached = (rows: readonly IssueRow[], refs: Readonly<Record<string, string[]>>): CachedIssue[] =>
  rows.map(r => ({ n: r.number, ...labelFacts(r.labels), refs: refs[String(r.number)] ?? [] }))

export type MatchHow = 'path' | 'suffix' | 'basename' | 'folder'
export type Match = { n: number; how: MatchHow; structural: string[]; priority: string | null }

const baseOf = (p: string) => p.slice(p.lastIndexOf('/') + 1)
const dirOf = (p: string) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '')
const indexes = new WeakMap<readonly string[], Map<string, string[]>>()
const indexOf = (tracked: readonly string[]): Map<string, string[]> => {
  let ix = indexes.get(tracked)
  if (ix) return ix
  ix = new Map()
  for (const p of tracked) {
    const b = baseOf(p)
    const at = ix.get(b)
    if (at) at.push(p)
    else ix.set(b, [p])
  }
  indexes.set(tracked, ix)
  return ix
}

/**
 * The open issues naming a file (decision 4): by its full repository relative path; by a partial
 * suffix on path segment boundaries when only one tracked file ends so; by a bare basename when only
 * one tracked file has it. The paths are the shared reader's, which reads each whole, so lib/foo.ts
 * never stands for lib/foo.tsx or otherlib/foo.ts (L1023). Then issues naming files in the same folder,
 * when that folder has at most FOLDER_MAX issues naming its files. Every issue is matched, labelled or
 * not; `structural` tells them apart.
 */
export const issuesNaming = (rel: string, issues: readonly CachedIssue[], tracked: readonly string[]): Match[] => {
  const ix = indexOf(tracked)
  const resolved = new Map<string, string | null>()
  const resolve = (ref: string): string | null => {
    if (ref === rel) return rel
    const had = resolved.get(ref)
    if (had !== undefined) return had
    const cands = new Set((ix.get(baseOf(ref)) ?? []).filter(p => p === ref || p.endsWith('/' + ref)))
    if (baseOf(rel) === baseOf(ref) && (rel === ref || rel.endsWith('/' + ref))) cands.add(rel)
    const one = cands.size === 1 ? ([...cands][0] as string) : null
    resolved.set(ref, one)
    return one
  }
  const fact = (i: CachedIssue, how: MatchHow): Match => ({ n: i.n, how, structural: i.structural, priority: i.priority })
  const exact: Match[] = []
  const folder: CachedIssue[] = []
  const dir = dirOf(rel)
  for (const i of issues) {
    const own = i.refs.find(r => resolve(r) === rel)
    if (own !== undefined) exact.push(fact(i, own === rel ? 'path' : own.includes('/') ? 'suffix' : 'basename'))
    if (i.refs.some(r => {
      const p = resolve(r)
      return p !== null && dirOf(p) === dir
    })) folder.push(i)
  }
  if (folder.length > FOLDER_MAX) return exact
  const named = new Set(exact.map(m => m.n))
  return [...exact, ...folder.filter(i => !named.has(i.n)).map(i => fact(i, 'folder'))]
}

/** The issues a session's /goal names, as #N (decision 5). */
export const goalIssues = (condition: string): number[] => [...condition.matchAll(/#(\d+)\b/g)].map(m => Number(m[1]))

export type Growth = { net: number; fixes: number }

const renamed = (p: string): [string, string] | null => {
  const brace = /^(.*)\{(.*) => (.*)\}(.*)$/.exec(p)
  if (brace) {
    const [, pre = '', a = '', b = '', post = ''] = brace
    const tidy = (s: string) => s.replace(/\/\/+/g, '/').replace(/^\//, '')
    return [tidy(pre + a + post), tidy(pre + b + post)]
  }
  const whole = /^(.*) => (.*)$/.exec(p)
  return whole ? [whole[1] as string, whole[2] as string] : null
}

const FIX_TITLE = /\bfix(?:e[sd])?\b/i

/**
 * Growth over `git log --numstat -M --format=%x1e%s`, newest commit first: net lines per file, each
 * rename followed to the file's current name, binary rows skipped, and how many commits touching it
 * have a fix TITLE (rough, L801: about half of fix titles in one repo were features).
 */
export const parseNumstat = (text: string): Record<string, Growth> => {
  const growth: Record<string, Growth> = {}
  const alias: Record<string, string> = {}
  for (const rec of text.split('\x1e')) {
    if (!rec.trim()) continue
    const lines = rec.split('\n')
    const isFix = FIX_TITLE.test(lines[0] ?? '')
    const touched = new Set<string>()
    for (const line of lines.slice(1)) {
      const m = /^(\d+|-)\t(\d+|-)\t(.+)$/.exec(line)
      if (!m) continue
      const [, add = '-', del = '-', p = ''] = m
      const r = renamed(p)
      let at: string
      if (r) {
        at = alias[r[1]] ?? r[1]
        alias[r[0]] = at
      } else at = alias[p] ?? p
      if (add === '-' || del === '-') continue
      const g = (growth[at] ??= { net: 0, fixes: 0 })
      g.net += Number(add) - Number(del)
      if (isFix && !touched.has(at)) g.fixes += 1
      touched.add(at)
    }
  }
  return growth
}

export type FileGrowth = { net: number; size: number | null; fixes: number; rank: number | null }
export type Ranked = { top: string[]; facts: Record<string, FileGrowth> }

/**
 * The growth bar (decision 6): files of at least SIZE_MIN lines that grew by at least GROWTH_MIN net
 * lines in the window, ranked by growth; the first TOP_N cross it. Every file's facts are kept, its
 * rank null when it is not eligible, so the log carries the rough growth line for any file.
 */
export const rank = (growth: Readonly<Record<string, Growth>>, sizes: Readonly<Record<string, number>>): Ranked => {
  const eligible = Object.keys(growth)
    .filter(p => (sizes[p] ?? 0) >= SIZE_MIN && (growth[p]?.net ?? 0) >= GROWTH_MIN)
    .sort((a, b) => (growth[b]?.net ?? 0) - (growth[a]?.net ?? 0) || (a < b ? -1 : 1))
  const facts: Record<string, FileGrowth> = {}
  for (const [p, g] of Object.entries(growth)) facts[p] = { net: g.net, size: sizes[p] ?? null, fixes: g.fixes, rank: null }
  eligible.forEach((p, i) => {
    const f = facts[p]
    if (f) f.rank = i + 1
  })
  return { top: eligible.slice(0, TOP_N), facts }
}

/** The files whose size the bar needs: those that grew enough to be eligible. */
export const sizeCandidates = (growth: Readonly<Record<string, Growth>>): string[] =>
  Object.keys(growth).filter(p => (growth[p]?.net ?? 0) >= GROWTH_MIN).sort()

/** `git grep -c '' <rev> -- <paths>`: each file's line count, by its path. */
export const parseLineCounts = (text: string, rev: string): Record<string, number> => {
  const sizes: Record<string, number> = {}
  for (const line of text.split('\n')) {
    if (!line.startsWith(rev + ':')) continue
    const rest = line.slice(rev.length + 1)
    const cut = rest.lastIndexOf(':')
    const n = Number(rest.slice(cut + 1))
    if (cut > 0 && Number.isFinite(n)) sizes[rest.slice(0, cut)] = n
  }
  return sizes
}

/** The day a moment falls on, UTC, as the ranking key reads it. */
export const dayOf = (ms: number): string => new Date(ms).toISOString().slice(0, 10)

/** The ranking's key: the repository, its origin default head, the day and the rule version (L573, L40). */
export const rankingKey = (repo: string, sha: string, ms: number): string => `${repo} ${sha} ${dayOf(ms)} v${RULE_VERSION}`

export type Judged = { decision: 'would_hold' | 'quiet'; why: ('issues' | 'growth')[]; shown: number[]; excluded: number[] }

/**
 * What phase 1 logs: would_hold when a structural issue names the file, the issues the session works
 * on (its branch's, its goal's) left out (decision 5), or when the file crosses the growth bar.
 */
export const judge = (f: { matches: readonly Match[]; own: readonly number[]; crosses: boolean }): Judged => {
  const excluded = f.matches.filter(m => f.own.includes(m.n)).map(m => m.n)
  const shown = f.matches.filter(m => m.structural.length > 0 && !f.own.includes(m.n)).map(m => m.n)
  const why: Judged['why'] = []
  if (shown.length) why.push('issues')
  if (f.crosses) why.push('growth')
  return { decision: why.length ? 'would_hold' : 'quiet', why, shown, excluded }
}

/**
 * The replay (#1508): a real repository's commits run through these rules, each commit standing in
 * for a session, as the calibration on #1506 was measured. A day's growth is that day's last commit.
 */
export type ReplayInput = {
  issues: CachedIssue[]
  tracked: string[]
  days: Record<string, { growth: Record<string, Growth>; sizes: Record<string, number> }>
  sessions: { id: string; day: string; own: number[]; files: string[] }[]
}
export type ReplaySession = { id: string; judged: number; held: number; holds: { path: string; why: Judged['why'] }[] }
export type ReplaySummary = { sessions: number; judgedSessions: number; withHold: number; holds: number; byIssues: number; byGrowth: number; fourOrMore: number; histogram: Record<string, number> }

export const replay = (input: ReplayInput): { sessions: ReplaySession[]; summary: ReplaySummary } => {
  const ranked = new Map<string, Ranked>()
  const rankOf = (day: string): Ranked => {
    let r = ranked.get(day)
    if (!r) {
      const d = input.days[day]
      r = d ? rank(d.growth, d.sizes) : { top: [], facts: {} }
      ranked.set(day, r)
    }
    return r
  }
  const sessions = input.sessions.map(s => {
    const judgedFiles = s.files.filter(p => fileKind(p) !== null)
    const top = rankOf(s.day).top
    const holds = judgedFiles.flatMap(p => {
      const j = judge({ matches: issuesNaming(p, input.issues, input.tracked), own: s.own, crosses: top.includes(p) })
      return j.decision === 'would_hold' ? [{ path: p, why: j.why }] : []
    })
    return { id: s.id, judged: judgedFiles.length, held: holds.length, holds }
  })
  const histogram: Record<string, number> = {}
  for (const s of sessions) histogram[String(s.held)] = (histogram[String(s.held)] ?? 0) + 1
  const all = sessions.flatMap(s => s.holds)
  return {
    sessions,
    summary: {
      sessions: sessions.length,
      judgedSessions: sessions.filter(s => s.judged > 0).length,
      withHold: sessions.filter(s => s.held > 0).length,
      holds: all.length,
      byIssues: all.filter(h => h.why.includes('issues')).length,
      byGrowth: all.filter(h => h.why.includes('growth')).length,
      fourOrMore: sessions.filter(s => s.held >= 4).length,
      histogram,
    },
  }
}
