import { DECISIONS, type Decision } from './rules.ts'

// The area check line in a pull request description (#1510, plan phase 5.2). Every file the area
// check decided on a branch, at the merge base that branch had with the default branch, carries one
// line in the pull request made from it: `Area check: <file>: <decision>, <reason>`. Pure: register.ts
// reads the log with grep, the command through mod-kit's readers and GitHub for a merge; this says
// which decisions the branch holds, which lines the description lacks, and the words of a refusal.
//
// The match is by repository, branch and merge base, so a branch name used again later starts clean.
// A rebase moves the merge base, so decisions taken before it stop matching (a known gap, named in
// the README and the design record). Where either merge base could not be read, the branch alone
// decides, and the refusal says so.

/** One decision as the log keeps it: a `decided` record (version 3), or Dan's standing answer applied to a `judged` one. */
export type PrDecision = {
  repo: string
  path: string
  branch: string
  mergeBase: string | null
  decision: Decision
  reason?: string
  issue?: number
  by?: 'dan'
}

/** The two answers of Dan's that a `judged` record applies without asking, as the decision each stands for. */
const APPLIED: Readonly<Record<string, Decision>> = { 'Proceed anyway': 'proceed', 'Restructure first': 'restructure' }

const isObject = (x: unknown): x is Record<string, unknown> => typeof x === 'object' && x !== null && !Array.isArray(x)
const text = (x: unknown): x is string => typeof x === 'string' && x.length > 0
const baseOf = (x: unknown): string | null | undefined => (x === null ? null : typeof x === 'string' && x ? x : undefined)

/**
 * The decisions in the lines grep gave (each holding `"kind":"decided"` or `"applied":`), in log
 * order. A line that is not JSON, or a decision missing a field it must carry, is MALFORMED: skipped
 * and returned, so the caller can name it (never read as no decision). A `decided` record older
 * than version 3 carries no branch and is left out, not malformed; so is a record of another kind
 * the marks happened to match, and a judged record with no answer applied.
 */
export const readDecisions = (out: string): { decisions: PrDecision[]; malformed: string[] } => {
  const decisions: PrDecision[] = []
  const malformed: string[] = []
  for (const line of out.split('\n')) {
    if (!line.trim()) continue
    let r: unknown
    try {
      r = JSON.parse(line)
    } catch {
      malformed.push(line)
      continue
    }
    if (!isObject(r)) {
      malformed.push(line)
      continue
    }
    if (r.kind === 'decided') {
      if (typeof r.v !== 'number' || r.v < 3) continue
      const mergeBase = baseOf(r.mergeBase)
      const decision = DECISIONS.find(d => d === r.decision)
      if (!text(r.repo) || !text(r.path) || !text(r.branch) || mergeBase === undefined || !decision) {
        malformed.push(line)
        continue
      }
      if (decision === 'fold' && (typeof r.issue !== 'number' || !Number.isInteger(r.issue))) {
        malformed.push(line)
        continue
      }
      decisions.push({
        repo: r.repo, path: r.path, branch: r.branch, mergeBase, decision,
        ...(typeof r.reason === 'string' ? { reason: r.reason } : {}),
        ...(typeof r.issue === 'number' ? { issue: r.issue } : {}),
        ...(r.by === 'dan' ? { by: 'dan' as const } : {}),
      })
      continue
    }
    if (r.kind === 'judged' && r.applied !== undefined) {
      const decision = typeof r.applied === 'string' ? APPLIED[r.applied] : undefined
      // A judged record on a detached head has no branch, so no pull request is made from it.
      if (r.branch === null) continue
      const mergeBase = baseOf(r.mergeBase)
      if (!decision || !text(r.repo) || !text(r.path) || !text(r.branch) || mergeBase === undefined) {
        malformed.push(line)
        continue
      }
      decisions.push({ repo: r.repo, path: r.path, branch: r.branch, mergeBase, decision, by: 'dan' })
    }
  }
  return { decisions, malformed }
}

/** The decisions of one repository, any branch: what decides whether the pull request side is asked at all. */
export const inRepo = (decisions: readonly PrDecision[], repo: string): PrDecision[] =>
  decisions.filter(d => d.repo.toLowerCase() === repo.toLowerCase())

/** One file decided on the branch: every decision taken on it there, the latest last. */
export type BranchFile = { path: string; decisions: PrDecision[] }

/**
 * The files decided on this branch at this merge base, sorted by path. `loose` is true when a
 * decision matched by branch alone, because its merge base or the branch's could not be read.
 */
export const onBranch = (decisions: readonly PrDecision[], at: { repo: string; branch: string; mergeBase: string | null }): { files: BranchFile[]; loose: boolean } => {
  const byPath = new Map<string, PrDecision[]>()
  let loose = false
  for (const d of inRepo(decisions, at.repo)) {
    if (d.branch !== at.branch) continue
    if (d.mergeBase !== null && at.mergeBase !== null && d.mergeBase !== at.mergeBase) continue
    if (d.mergeBase === null || at.mergeBase === null) loose = true
    byPath.set(d.path, [...(byPath.get(d.path) ?? []), d])
  }
  const files = [...byPath.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([path, ds]) => ({ path, decisions: ds }))
  return { files, loose }
}

/** The line a decision asks for, exactly as it may be pasted. */
export const lineFor = (d: PrDecision): string => {
  const head = `Area check: ${d.path}: ${d.decision}`
  if (d.decision === 'fold') return `${head}, Refs #${String(d.issue)}`
  if (d.by === 'dan') return d.decision === 'restructure' ? `${head}, Dan chose Restructure first` : `${head}, Dan chose Proceed anyway`
  return d.reason ? `${head}, ${d.reason.trim().split('\n')[0]}` : head
}

// A line in a description: an optional bullet, the file in backticks or not, the decision, the rest.
const LINE = /^[ \t]*(?:[-*][ \t]+)?Area check:[ \t]*`?([^`\n]+?)`?:[ \t]*(proceed|fold|restructure)\b(.*)$/gim
const FOLD_REF = /\b(?:Refs|Closes)[ \t]+#(\d+)\b/gi

/** The area check lines a description carries, each file with the decisions and the rest of its lines. */
export const linesIn = (body: string): { path: string; decision: Decision; rest: string }[] =>
  [...body.matchAll(LINE)].map(m => ({ path: (m[1] as string).trim(), decision: (m[2] as string).toLowerCase() as Decision, rest: m[3] as string }))

/**
 * The files whose line the description lacks. A file's line names any decision taken on it on the
 * branch; a fold line must also carry `Refs #N` or `Closes #N` for an issue folded into that file.
 */
export const missingFrom = (files: readonly BranchFile[], body: string): BranchFile[] => {
  const lines = linesIn(body)
  return files.filter(f => !lines.some(l => {
    if (l.path !== f.path || !f.decisions.some(d => d.decision === l.decision)) return false
    if (l.decision !== 'fold') return true
    const folded = new Set(f.decisions.filter(d => d.decision === 'fold').map(d => d.issue))
    return [...l.rest.matchAll(FOLD_REF)].some(m => folded.has(Number(m[1])))
  }))
}

/** The line to paste for each file: the latest decision taken on it. */
export const linesToPaste = (files: readonly BranchFile[]): string[] => files.map(f => lineFor(f.decisions[f.decisions.length - 1] as PrDecision))

// ---- The words ----

export const LOG_SHOWN = '~/.claude-area-check/log.jsonl'
const THIS_MAC = `It read this Mac's log only (${LOG_SHOWN}), so a file decided on another Mac is not asked for.`
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`
const shorten = (s: string) => (s.length > 120 ? `${s.slice(0, 117)}...` : s)

/** The sentence naming the log lines skipped, for a refusal. */
export const malformedNote = (malformed: readonly string[]): string =>
  malformed.length === 0
    ? ''
    : `${plural(malformed.length, 'line of the log', 'lines of the log')} could not be read and ${malformed.length === 1 ? 'was' : 'were'} skipped, the first: ${shorten(malformed[0] as string)}`

/** The dim line naming the log lines skipped, on a command let through. */
export const malformedDim = (malformed: readonly string[]): string =>
  `The area check skipped ${plural(malformed.length, 'line of its log', 'lines of its log')} (${LOG_SHOWN}) it could not read, the first: ${shorten(malformed[0] as string)}`

export type Refusing = {
  /** What is refused, as the command names it: `gh pr create`, `gh pr edit`, `gh pr merge`. */
  verb: string
  branch: string
  files: readonly BranchFile[]
  loose: boolean
  malformed: readonly string[]
}

const tail = (r: Refusing) =>
  [
    r.loose ? 'A merge base could not be read, so these decisions were matched by branch alone.' : '',
    THIS_MAC,
    malformedNote(r.malformed),
  ].filter(Boolean)

/** The description lacks lines: every line to paste, and where to put them for this command. */
export const missingRefusal = (r: Refusing & { where: 'command' | 'github'; selector?: string }): string => {
  const n = plural(r.files.length, 'file', 'files')
  const how = r.where === 'github'
    ? `Add each line below to the pull request's description on GitHub (gh pr edit${r.selector ? ` ${r.selector}` : ''} --body-file <a file holding the whole description>), then merge again:`
    : 'Add each line below to the description, then run the command again:'
  return [`The area check refused this ${r.verb}: the description lacks the area check line for ${n} decided on branch ${r.branch}. ${how}`, ...linesToPaste(r.files), ...tail(r)].join('\n')
}

/** gh pr create with no description given: ask for --body or --body-file, carrying the lines. */
export const noBodyRefusal = (r: Refusing): string =>
  [`The area check refused this ${r.verb}: it gives no description to check, and ${plural(r.files.length, 'file was', 'files were')} decided on branch ${r.branch}. Give the description with --body or --body-file, carrying each line below:`, ...linesToPaste(r.files), ...tail(r)].join('\n')

/** The description file could not be read: named, never read as a description without lines. */
export const bodyUnreadableRefusal = (verb: string, file: string, why: string): string =>
  file === 'standard input'
    ? `The area check refused this ${verb}: its description comes from standard input (${why}), which the area check cannot read, and files were decided on this branch. Give it with --body, with --body-file and a file, or with --body-file - fed by a heredoc.`
    : `The area check refused this ${verb}: it could not read the description file ${file} (${why}), and files were decided on this branch. Check the path, or give the description with --body.`

/** The log could not be read: named, with why and the way back, never read as no decisions. */
export const logUnreadableRefusal = (verb: string, why: string): string =>
  `The area check refused this ${verb}: it could not read its log ${LOG_SHOWN} (${why}), so it cannot tell which files were decided on this branch. It reads this Mac's log only. If the log was deleted, a new session writes it again (and reads as no decisions); if it cannot be read, make it readable to you again. Then run the command again.`
