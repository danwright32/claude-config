import { askAnyAccount, type GhRun, type GhRunner } from './ghaccounts.ts'

// Whether GitHub says a pull request merged (#1991): the one check is it live's turn end and the goal
// box both make of a merge the helper makes in the background. Each kept its own copy, and is it
// live's went stale three ways the goal box's did not (#1818): it asked as the active gh account
// alone, in the folder the helper ran in (a worktree that may since be gone), and refused a merge
// that happened before the helper run started (the helper run again after the merge). So it is asked
// here, once: as each account gh is logged in to (askAnyAccount), by the repository where one was
// read (in the folder only where none was), and a merge GitHub confirms counts whatever its time.
// What makes it this pull request is the answer itself: its number, and its link naming that number
// and that repository (L179, L237).
//
// Pure: the caller hands in how to run a command and read a github.com link, spelled with its own `$`
// in place, since a mod cannot hand `$` on. Kept here and copied byte for byte into each mod that
// uses it (hooks/mod-kit/prmerged.ts, beside its copy of ghaccounts.ts), which
// tools/check-mod-shared-parts.sh holds to this one.

/** What GitHub is asked about the pull request: the fields this reads. */
export const VIEW_FIELDS = 'number,state,mergedAt,url'

/** The pull request asked about: its number, and its repository where one was read, else the folder gh resolves it in. */
export type PrAsked = { pr: number; repo?: string; cwd?: string }

/**
 * What GitHub said: merged in that repository at that time; still open; closed unmerged; the number
 * no pull request there (an issue, or nothing); or not proven either way, with why.
 */
export type PrAnswer =
  | { kind: 'merged'; repo: string; url: string; at: number }
  | { kind: 'open'; repo: string }
  | { kind: 'closed'; repo: string }
  | { kind: 'not a pr' }
  | { kind: 'unproven'; why: string }

/** How the caller runs a command: in a folder, with environment of its own (an account's token). */
export type PrRunner = (argv: string[], init: { cwd?: string; env?: Record<string, string> }) => Promise<GhRun>

export type PrReaders = {
  run: PrRunner
  /** The repository a github.com link names, owner/name, or null for a link naming none (mod-kit's linkRepo). */
  linkRepo: (link: string) => Promise<string | null>
  /** An error as words; the caller's own, so a member mod-kit's loaded copy lacks is said as that (skew.ts). */
  describe?: (err: unknown) => string
}

/**
 * gh's own words for a number that is no pull request in the repository asked (measured on a lesson
 * sweep issue, #1943). The repository answered, so no other account would say otherwise.
 */
export const isNotAPr = (error: string): boolean => /Could not resolve to a PullRequest/i.test(error)
const unseen = (r: GhRun) => /Could not resolve to a Repository/i.test(r.stderr)
const lineOf = (r: GhRun) => r.stderr.trim().split('\n')[0] || r.stdout.trim().split('\n')[0] || `gh exited ${r.exitCode}`
const fold = (repo: string) => repo.toLowerCase()
const said = (err: unknown) => (err && typeof err === 'object' && 'message' in err ? String((err as { message: unknown }).message) : String(err))

export const askPr = async (readers: PrReaders, o: PrAsked): Promise<PrAnswer> => {
  const describe = readers.describe ?? said
  // By its repository wherever one was read, so a folder removed since is never asked in.
  const cwd = o.repo ? undefined : o.cwd
  const gh: GhRunner = (argv, env) => readers.run(argv, { ...(cwd ? { cwd } : {}), ...(env ? { env } : {}) })
  let asked: { stdout: string } | { failures: GhRun[] }
  try {
    asked = await askAnyAccount(gh, ['pr', 'view', String(o.pr), ...(o.repo ? ['--repo', o.repo] : []), '--json', VIEW_FIELDS], r => !isNotAPr(r.stderr))
  } catch (err) {
    return { kind: 'unproven', why: `GitHub could not be asked: ${describe(err)}` }
  }
  if (!('stdout' in asked)) {
    if (asked.failures.some(f => isNotAPr(f.stderr))) return { kind: 'not a pr' }
    // The account that could see the repository says more than one that could not.
    return { kind: 'unproven', why: `GitHub could not be asked: ${lineOf(asked.failures.find(f => !unseen(f)) ?? (asked.failures[0] as GhRun))}` }
  }
  let v: { number?: unknown; state?: unknown; mergedAt?: unknown; url?: unknown }
  try {
    v = JSON.parse(asked.stdout)
  } catch {
    return { kind: 'unproven', why: "GitHub's answer could not be read" }
  }
  if (!v || typeof v !== 'object') return { kind: 'unproven', why: "GitHub's answer could not be read" }
  if (v.number !== o.pr) return { kind: 'unproven', why: `GitHub answered for #${String(v.number)}` }
  if (typeof v.url !== 'string' || /\/pull\/(\d+)\/?$/.exec(v.url)?.[1] !== String(o.pr)) return { kind: 'unproven', why: `GitHub's link ${JSON.stringify(v.url)} is not #${o.pr}'s` }
  let repo: string | null
  try {
    repo = await readers.linkRepo(v.url)
  } catch (err) {
    return { kind: 'unproven', why: `GitHub's link ${v.url} could not be read (${describe(err)})` }
  }
  if (!repo) return { kind: 'unproven', why: `GitHub's link ${v.url} names no repository` }
  if (o.repo && fold(repo) !== fold(o.repo)) return { kind: 'unproven', why: `GitHub answered for ${repo}#${o.pr}` }
  if (v.state === 'OPEN') return { kind: 'open', repo }
  if (v.state === 'CLOSED') return { kind: 'closed', repo }
  if (v.state !== 'MERGED') return { kind: 'unproven', why: `GitHub answered state ${JSON.stringify(v.state)}` }
  const at = typeof v.mergedAt === 'string' ? Date.parse(v.mergedAt) : NaN
  if (Number.isNaN(at)) return { kind: 'unproven', why: 'GitHub gave no time for the merge' }
  return { kind: 'merged', repo, url: v.url, at }
}
