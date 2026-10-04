import type { Cmd } from './nobuild.ts'

// Winding down (#616). Finished means the PR merged, the project's deploy step run and verified live,
// the worktree and branch cleaned, and the issue closed. Until then the turn end is refused. Fixing
// what blocks this issue's merge or deploy is allowed; starting new work is denied.

export type Refusal = { what: string }
type Unreadable = { unreadable: string }
const isUnreadable = (v: unknown): v is Unreadable => !!v && typeof v === 'object' && 'unreadable' in v

/** What the finish check read, each part its own reading so a failed read is said apart from a no. */
export type Reading = {
  branch: string
  /** Whether the branch is the repository's default branch, where no PR is expected. */
  isDefault: boolean
  pr: { number: number; state: 'OPEN' | 'MERGED' | 'CLOSED'; issues: { number: number; state: 'OPEN' | 'CLOSED' }[] } | null | Unreadable
  branchHere: boolean | Unreadable
  branchOnGitHub: boolean | Unreadable
  worktreeOnBranch: boolean | Unreadable
  /** How Claude confirmed the deploy live (or that the project has no deploy step); null until it has. */
  live: string | null
  dirty: boolean | Unreadable
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
  if (r.pr.state === 'OPEN') return [`PR #${r.pr.number} is not merged yet`]
  if (r.pr.state === 'CLOSED') return [`PR #${r.pr.number} was closed without merging; ask Dan what to do`]
  if (!r.live) out.push('the deploy has not been confirmed live')
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

/** The issue numbers a branch name carries (`scope-modes-616-621`, `feat/620-addon-notes`). */
export const issuesOfBranch = (branch: string): number[] => [...branch.matchAll(/(?:^|[^0-9])(\d{2,6})(?=$|[^0-9])/g)].map(m => Number(m[1]))

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
    const w = c.words
    if ((w[0] ?? '').split('/').pop() === 'gh' && w[1] === 'issue' && w[2] === 'develop') return { what: 'start a new branch' }
  }
  return undefined
}
