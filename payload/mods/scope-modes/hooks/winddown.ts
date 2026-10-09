import type { ScopeModesLeftAsIs, ScopeModesLeftClosed, ScopeModesLeftOpen } from '../types/index.d.ts'
import type { Cmd } from './nobuild.ts'

// Winding down (#616). Finished means the PR merged, the is it live mod's card for it saying Live
// or no deploy step recorded (#687), the worktree and branch cleaned, and the issue closed. Until then the turn end is refused. Fixing
// what blocks this issue's merge or deploy is allowed; starting new work is denied. Asking Dan
// (AskUserQuestion) is never new work: winding down finalizes everything the session has open, so a
// PR needing his sign off is asked about and merged, never parked waiting on him (#856). The one
// exception is Dan's own answer to leave_pr_open: a PR he chose to leave open (#917), recorded
// against the commit the PR was on, is settled until it is pushed to again, and a PR closed without
// merging that he chose to leave closed (#1033) is settled while it stays closed.
//
// A closed PR is never settled without his answer, even where its work plainly merged in another PR
// (ovation#711, whose work merged as #716): GitHub records no link from a closed PR to the one that
// carried its work, a closing reference belongs to the issue rather than to either PR, and a squash
// merge leaves the closed PR's commits out of the base branch's history (L642), so nothing it gives
// says so reliably.

export type Refusal = { what: string }

/** Dan's own answer that a PR stays open (#917), recorded where he gave it, against its head commit. */
export type LeftOpen = ScopeModesLeftOpen
/** Dan's own answer that a PR closed without merging stays closed (#1033). */
export type LeftClosed = ScopeModesLeftClosed
/** Dan's own answer about one PR, open or closed. */
export type LeftAsIs = ScopeModesLeftAsIs

/** Whether an answer was about a PR closed without merging, told by its own field (#1033). */
export const isLeftClosed = (d: LeftAsIs): d is LeftClosed => 'closed' in d && d.closed === true

/** Dan's choice about this PR, by repository (in any case) and number, or undefined when he made none. */
export const choiceFor = (all: readonly LeftAsIs[], repo: string, number: number): LeftAsIs | undefined =>
  all.find(d => d.number === number && d.repo.toLowerCase() === repo.toLowerCase())
type Unreadable = { unreadable: string }
const isUnreadable = (v: unknown): v is Unreadable => !!v && typeof v === 'object' && 'unreadable' in v

/** What the finish check read, each part its own reading so a failed read is said apart from a no. */
export type Reading = {
  branch: string
  /** Whether the branch is the repository's default branch, where no PR is expected. */
  isDefault: boolean
  /** `head` is the commit the PR's branch is on now, as GitHub gave it; absent when it gave none. */
  pr: { number: number; state: 'OPEN' | 'MERGED' | 'CLOSED'; head?: string; issues: { number: number; state: 'OPEN' | 'CLOSED' }[] } | null | Unreadable
  /** Dan's choice to leave this PR open (#917) or closed (#1033), when he made one; never inferred. */
  choice?: LeftAsIs
  branchHere: boolean | Unreadable
  branchOnGitHub: boolean | Unreadable
  worktreeOnBranch: boolean | Unreadable
  /**
   * The deploy as the is it live mod's newest card for this PR says (#687): its state; null when no
   * card has been made yet; unmeasured when the mod is not loaded. Never Claude's own report.
   */
  deploy: { state: DeployState } | null | Unmeasured | Unreadable
  dirty: boolean | Unreadable
}

/** A card's state, as is it live keeps it (its contract's IsItLiveCard['state']). */
export type DeployState = 'live' | 'deploying' | 'unconfirmed' | 'no-deploy'
type Unmeasured = { unmeasured: string }
const isUnmeasured = (v: unknown): v is Unmeasured => !!v && typeof v === 'object' && 'unmeasured' in v

// What each card state leaves to do. A Record over the type, so a state added without a decision
// fails to type check (L113). Only Live and no deploy step recorded finish winding down.
const DEPLOY_LEFT: Record<DeployState, string | undefined> = {
  live: undefined,
  'no-deploy': undefined,
  deploying: 'the deploy is still running (is it live says Merged, deploying)',
  unconfirmed: 'is it live could not confirm the deploy live: find out why, and make the card again once it is',
}

/** What is still to do before winding down is finished, in the order it is done; empty when finished. */
export const outstanding = (r: Reading): string[] => {
  const out: string[] = []
  const unread = (what: string, v: Unreadable) => out.push(`${what} could not be read (${v.unreadable})`)
  if (isUnreadable(r.pr)) {
    unread('the PR', r.pr)
    return out
  }
  if (r.pr === null) {
    if (!r.isDefault) return [`there is no PR for ${r.branch} yet`]
    if (isUnreadable(r.dirty)) unread('whether anything is uncommitted', r.dirty)
    else if (r.dirty) out.push('there are uncommitted changes')
    return out
  }
  if (r.pr.state === 'OPEN') {
    // An answer about the PR while it was closed says nothing about it open (#1033).
    const d = r.choice && !isLeftClosed(r.choice) ? r.choice : undefined
    // Nobody decided: #856's default, an open PR is outstanding until merged.
    if (!d) return [`PR #${r.pr.number} is not merged yet`]
    if (settledByDan(r)) return []
    if (!r.pr.head) return [`PR #${r.pr.number}'s latest commit could not be read, so Dan's choice to leave it open cannot be matched to it`]
    // His answer was about the commits he was asked about, never ones pushed since.
    return [`PR #${r.pr.number} has new commits since Dan chose to leave it open: merge it, or ask him again (mcp__scope-modes__leave_pr_open)`]
  }
  if (r.pr.state === 'CLOSED') {
    if (settledByDan(r)) return []
    // His answer to leave it open was about an open PR, so it settles nothing once closed.
    return [`PR #${r.pr.number} was closed without merging: ask Dan whether to leave it closed (mcp__scope-modes__leave_pr_open)`]
  }
  const d = r.deploy
  if (d === null) out.push(`PR #${r.pr.number} has no is it live card yet: check the deploy and make the card (mcp__is-it-live__card)`)
  else if (isUnmeasured(d)) out.push(`the deploy is unmeasured: ${d.unmeasured}`)
  else if (isUnreadable(d)) unread('the deploy verdict', d)
  else {
    // A state outside the four is a contract the mods disagree on: never read as finished (L42).
    const left = Object.prototype.hasOwnProperty.call(DEPLOY_LEFT, d.state) ? DEPLOY_LEFT[d.state] : `is it live answered a state wind down does not know (${String(d.state)})`
    if (left) out.push(left)
  }
  const checks: [string, boolean | Unreadable, string][] = [
    [`whether ${r.branch} is gone here`, r.branchHere, `the branch ${r.branch} still exists here`],
    [`whether ${r.branch} is gone from GitHub`, r.branchOnGitHub, `the branch ${r.branch} still exists on GitHub`],
    [`whether a worktree is still on ${r.branch}`, r.worktreeOnBranch, `a worktree is still on ${r.branch}`],
  ]
  for (const [question, v, still] of checks) {
    if (isUnreadable(v)) unread(question, v)
    else if (v) out.push(still)
  }
  for (const i of r.pr.issues) if (i.state !== 'CLOSED') out.push(`issue #${i.number} is still open`)
  return out
}

/**
 * Whether this reading is a PR left as it is on Dan's own choice: still open, chosen at the commit it
 * is on now (#917), or closed without merging, chosen while closed (#1033).
 */
export function settledByDan(r: Reading): boolean {
  const pr = r.pr
  const d = r.choice
  if (!pr || isUnreadable(pr) || !d) return false
  if (isLeftClosed(d)) return pr.state === 'CLOSED'
  return pr.state === 'OPEN' && !!pr.head && pr.head === d.head
}

const ISSUE_REF = /(?:#|\bissue\s+)(\d+)\b/gi

/**
 * Why winding down refuses this call as new work, or undefined. Only the starts of new work are
 * refused; everything this issue's merge, deploy and cleanup need goes through.
 */
export const newWork = (call: { tool: string; input: Record<string, unknown>; commands: Cmd[]; issues: readonly number[] }): Refusal | undefined => {
  const { tool, input } = call
  if (tool === 'Skill' && String(input.skill ?? '').replace(/^.*:/, '') === 'next-issue') return { what: 'start the next issue' }
  if (tool === 'EnterWorktree') return { what: 'start a new branch' }
  if (tool === 'Agent' || tool === 'Task') {
    const prompt = String(input.prompt ?? '')
    for (const m of prompt.matchAll(ISSUE_REF)) {
      const n = Number(m[1])
      if (!call.issues.includes(n)) return { what: `dispatch an agent for issue #${n}` }
    }
    return undefined
  }
  if (tool !== 'Bash') return undefined
  for (const c of call.commands) {
    const g = c.git
    const args = g?.args ?? []
    if (g?.sub === 'checkout' && args.some(a => a === '-b' || a === '-B' || a === '--orphan')) return { what: 'start a new branch' }
    if (g?.sub === 'switch' && args.some(a => a === '-c' || a === '-C' || a === '--create' || a === '--force-create' || a === '--orphan')) return { what: 'start a new branch' }
    if (g?.sub === 'worktree' && args[0] === 'add') return { what: 'start a new branch' }
    if (g?.sub === 'branch' && args.length > 0 && !args[0]?.startsWith('-')) return { what: 'start a new branch' }
    // gh read by mod-kit's one reader (#961), past its global flags (`gh -R o/x issue develop 7`).
    if (c.gh?.sub === 'issue' && c.gh.act === 'develop') return { what: 'start a new branch' }
    // A flag before the subcommand the reader cannot place could hide `issue develop`, so it is refused.
    if (c.gh?.unreadable) return { what: 'run a gh command whose flags cannot be read' }
  }
  return undefined
}
