import type { ModKitWrites } from '../.claude-plugin/types/mod-kit/index.d.ts'
import type { ScopeModesLeftAsIs, ScopeModesLeftBranch, ScopeModesLeftClosed, ScopeModesLeftOpen } from '../types/index.d.ts'
import { EDITORS, type Cmd } from './nobuild.ts'

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

/** Dan's own answer that a branch stays as it is (#1074): never deleted here, its worktree kept. */
export type LeftBranch = ScopeModesLeftBranch
/** Dan's choice about this branch, by repository (in any case) and branch name, or undefined. */
export const branchChoiceFor = (all: readonly LeftBranch[], repo: string, branch: string): LeftBranch | undefined =>
  all.find(d => d.branch === branch && d.repo.toLowerCase() === repo.toLowerCase())
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
  /**
   * The checkout was on this branch, which this session neither created, committed to nor pushed
   * (#1074): it is not the session's, so it has no PR or cleanup of the session's to finish.
   */
  inherited?: boolean
  /** Dan's choice to leave this branch as it is (#1074), when he made one; never inferred. */
  branchLeft?: LeftBranch
  branchHere: boolean | Unreadable
  branchOnGitHub: boolean | Unreadable
  worktreeOnBranch: boolean | Unreadable
  /**
   * The deploy as the is it live mod's newest card for this PR says (#687): its state; null when no
   * card has been made yet; unmeasured when the mod is not loaded. Never Claude's own report.
   */
  deploy: { state: DeployState } | null | Unmeasured | Unreadable
  /**
   * The files git status names uncommitted in the session's checkout that this session or one of its
   * agents wrote (#1051, #1108); empty when none.
   */
  dirty: string[] | Unreadable
  /**
   * The other files git status names there, which this session did not write (#1108): another
   * session's, a job's, or written by a route the mod cannot name. Never outstanding; said once, when
   * winding down finishes.
   */
  notMine?: string[]
}

// A path with its empty, `.` and `..` steps taken out, so two spellings of one file match.
const plain = (p: string): string => {
  const out: string[] = []
  for (const s of p.split('/')) {
    if (s === '' || s === '.') continue
    if (s === '..') out.pop()
    else out.push(s)
  }
  return `/${out.join('/')}`
}

/**
 * The files a call this session let through wrote (#1108), absolute: the file an editing tool names,
 * and for a Bash call what mod-kit's one write reader names (#712), its files, its other changes and
 * a program's named targets. A copy onto a name that may be a folder is given as both places it can
 * land: the name, and the source's own name inside it, with everything under that, never the whole
 * folder, which may hold another session's files (lessons review). A removal reaching a whole folder
 * is given again ending in `/`, standing for everything under it. A made folder writes no file. A
 * write the reader cannot name (a patch, a script, a path built from a variable) names nothing here.
 */
export const filesWritten = (call: { tool: string; input: Record<string, unknown>; writes: ModKitWrites }): string[] => {
  if (EDITORS.has(call.tool)) {
    const p = String(call.input.file_path ?? call.input.notebook_path ?? '')
    return p.startsWith('/') ? [plain(p)] : []
  }
  if (call.tool !== 'Bash') return []
  const out: string[] = []
  const add = (path: string | undefined, whole: boolean) => {
    if (!path?.startsWith('/')) return
    out.push(plain(path))
    if (whole) out.push(`${plain(path)}/`)
  }
  for (const f of call.writes.files) {
    add(f.path, !!f.tree)
    if (f.mayBeFolder && f.path) for (const s of f.sources ?? []) add(`${f.path}/${s.replace(/\/+$/, '').split('/').pop() ?? ''}`, true)
  }
  for (const c of call.writes.changes) if (c.does !== 'folder') add(c.path, !!c.tree)
  for (const u of call.writes.unnamed) for (const t of u.targets ?? []) add(t, false)
  return [...new Set(out)]
}

// A path as matched against another spelling of it (lessons review): macOS's default volume ignores
// case, and /var, /tmp and /etc are links into /private, so git's path and a tool's can differ in
// both. Read the same, a file this session wrote is never taken for another's; two files differing
// only in case on a volume that tells them apart are both counted, the side that only asks again.
const matchKey = (p: string) => p.toLowerCase().replace(/^\/private(?=\/(?:var|tmp|etc)\/)/, '')

/**
 * The uncommitted files git status names relative to `root`, split into this session's own (`written`
 * names it, or a folder holding it) and the rest (#1108).
 */
export const whoseFiles = (dirty: readonly string[], root: string, written: readonly string[]): { own: string[]; others: string[] } => {
  const files = new Set(written.filter(w => !w.endsWith('/')).map(matchKey))
  const trees = written.filter(w => w.endsWith('/')).map(matchKey)
  const own: string[] = []
  const others: string[] = []
  for (const f of dirty) {
    const p = matchKey(plain(`${root}/${f}`))
    ;(files.has(p) || trees.some(t => p.startsWith(t)) ? own : others).push(f)
  }
  return { own, others }
}

/**
 * The files `git status --porcelain` names, one per line: a rename's new name, and a name git
 * quoted for a space or an unusual byte without its quotes.
 */
export const porcelainFiles = (stdout: string): string[] =>
  stdout
    .split('\n')
    .filter(l => l.length > 3)
    .map(l => {
      const path = l.slice(3)
      const to = path.includes(' -> ') ? path.slice(path.lastIndexOf(' -> ') + 4) : path
      return to.startsWith('"') && to.endsWith('"') ? unquoted(to.slice(1, -1)) : to
    })

// What git quoted, read back (#1108 lessons review): a byte past ASCII as an octal escape of its
// UTF-8 (core.quotePath), and a quote, a backslash or a control character by its C escape. Read as
// written, a file the session wrote under such a name never matched the path it wrote.
const C_ESCAPES: Record<string, number> = { a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13, '"': 34, '\\': 92 }
// Read by code point, so a character git left raw (core.quotePath off) is never split in two.
const unquoted = (q: string): string => {
  const chars = [...q]
  const bytes: number[] = []
  for (let i = 0; i < chars.length; i++) {
    const c = chars[i] as string
    if (c !== '\\') {
      bytes.push(...new TextEncoder().encode(c))
      continue
    }
    const octal = chars.slice(i + 1, i + 4).join('')
    if (/^[0-7]{3}$/.test(octal)) {
      bytes.push(parseInt(octal, 8))
      i += 3
    } else {
      const next = chars[i + 1] ?? ''
      bytes.push(...(C_ESCAPES[next] !== undefined ? [C_ESCAPES[next] as number] : new TextEncoder().encode(next)))
      i += 1
    }
  }
  return new TextDecoder().decode(new Uint8Array(bytes))
}

// Files named in a sentence: at most five, then how many more.
const MAX_NAMED = 5
export const filesSaid = (files: readonly string[]) =>
  files.length <= MAX_NAMED ? files.join(', ') : `${files.slice(0, MAX_NAMED).join(', ')} and ${files.length - MAX_NAMED} more`

/** The tools that answer for uncommitted work while winding down, as the finish check and refusal name them. */
export const CLEANUP_TOOL = 'mcp__scope-modes__open_cleanup_branch'
export const LEAVE_BRANCH_TOOL = 'mcp__scope-modes__leave_branch'
const uncommitted = (files: readonly string[]) =>
  `there are uncommitted changes (${filesSaid(files)}): commit them on a branch Dan agrees to (${CLEANUP_TOOL}), or ask him whether to leave them (${LEAVE_BRANCH_TOOL})`

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
    // A branch that is not the session's (#1074) is read as the default branch is: only its
    // uncommitted work can be the session's.
    if (!r.isDefault && !r.inherited) return [`there is no PR for ${r.branch} yet`]
    if (isUnreadable(r.dirty)) unread('whether anything is uncommitted', r.dirty)
    else {
      // Dan's answer to leave the branch as it is settles the files he was asked about, never one
      // changed since (#1074), as his answer about a PR never covers commits he was not asked about.
      const asked = r.branchLeft?.files ?? []
      const left = r.dirty.filter(f => !asked.includes(f))
      if (left.length) out.push(uncommitted(left))
    }
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
  // Dan's answer to leave the branch as it is (#1074) keeps it here and any worktree on it, which can
  // stand under another session; the branch on GitHub holds no checkout, so it is still cleaned.
  const keptHere = !!r.branchLeft
  // Each check, and whether it is of this checkout, which his answer keeps.
  const checks: [string, boolean | Unreadable, string, boolean][] = [
    [`whether ${r.branch} is gone here`, r.branchHere, `the branch ${r.branch} still exists here`, true],
    [`whether ${r.branch} is gone from GitHub`, r.branchOnGitHub, `the branch ${r.branch} still exists on GitHub`, false],
    [`whether a worktree is still on ${r.branch}`, r.worktreeOnBranch, `a worktree is still on ${r.branch}`, true],
  ]
  for (const [question, v, still, local] of checks) {
    if (local && keptHere) continue
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

/**
 * Whether Dan's answer to leave this branch as it is (#1074) settled anything in this reading: less is
 * outstanding with it than without it. Only then is the branch said to be left as it is by his choice.
 */
export const settledByBranchChoice = (r: Reading): boolean => !!r.branchLeft && outstanding({ ...r, branchLeft: undefined }).length > outstanding(r).length

const ISSUE_REF = /(?:#|\bissue\s+)(\d+)\b/gi

/**
 * What winding down refuses as new work, in the words its refusal says it with. The acknowledgement
 * of turning it on (#1055) lists these same words, so it says what this guard refuses.
 */
export const NEW_WORK = { nextIssue: 'start the next issue', branch: 'start a new branch', agent: 'dispatch an agent for another issue' } as const
const agentFor = (n: number) => NEW_WORK.agent.replace('another issue', `issue #${n}`)
/** What finishing one PR means, as winding down's note and its acknowledgement (#1055) both say it. */
export const FINISHED = 'merged, its deploy live, its worktree and branch cleaned and its issues closed'

// A git command's value for a flag, given as the next word or after `=` (`-c x`, `--create=x`).
const valueOf = (args: readonly string[], flags: readonly string[]): string | undefined => {
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (flags.includes(a)) return args[i + 1]
    const eq = flags.find(f => f.startsWith('--') && a.startsWith(`${f}=`))
    if (eq) return a.slice(eq.length + 1)
  }
  return undefined
}

/**
 * The branch a git command starts, when it starts one: its name where the words give it, and whether
 * the checkout moves onto it (checkout and switch), which carries the uncommitted changes there.
 */
export const newBranchOf = (c: Cmd): { name: string | undefined; moves: boolean } | undefined => {
  const g = c.git
  const args = g?.args ?? []
  if (g?.sub === 'checkout' && args.some(a => a === '-b' || a === '-B' || a === '--orphan')) return { name: valueOf(args, ['-b', '-B', '--orphan']), moves: true }
  if (g?.sub === 'switch' && args.some(a => ['-c', '-C', '--create', '--force-create', '--orphan'].includes(a) || /^--(force-)?create=/.test(a)))
    return { name: valueOf(args, ['-c', '-C', '--create', '--force-create', '--orphan']), moves: true }
  if (g?.sub === 'worktree' && args[0] === 'add') return { name: valueOf(args, ['-b', '-B']), moves: false }
  if (g?.sub === 'branch' && args.length > 0 && !args[0]?.startsWith('-')) return { name: args[0], moves: false }
  return undefined
}

// git push's options that take a value as the next word, so it is never read as the remote.
const PUSH_VALUES = ['-o', '--push-option', '--repo', '--receive-pack', '--exec']

/**
 * The branches a call makes the session's own (#1074): one it creates, one it pushes by name (a
 * refspec's destination), and `current` for a commit or a push naming none, which is of the branch
 * checked out where it runs. A deletion and a tag name no branch.
 */
export const branchesTouched = (commands: readonly Cmd[]): { named: string[]; current: boolean } => {
  const named: string[] = []
  let current = false
  for (const c of commands) {
    const started = newBranchOf(c)
    if (started?.name) named.push(started.name)
    const g = c.git
    if (g?.sub === 'commit') current = true
    if (g?.sub !== 'push') continue
    const args = g.args
    if (args.some(a => a === '-d' || a === '--delete' || a === '--tags' || a === '--mirror' || a === '--all')) continue
    const words: string[] = []
    for (let i = 0; i < args.length; i++) {
      const a = args[i] as string
      if (PUSH_VALUES.includes(a)) i++
      else if (!a.startsWith('-')) words.push(a)
    }
    // The first word is the remote; the rest are refspecs.
    const specs = words.slice(1)
    if (!specs.length) current = true
    for (const spec of specs) {
      const s = spec.replace(/^\+/, '')
      const src = s.includes(':') ? s.slice(0, s.indexOf(':')) : s
      const dst = (s.includes(':') ? s.slice(s.indexOf(':') + 1) : s).replace(/^refs\/heads\//, '')
      // An empty source deletes the branch; a tag is no branch.
      if (s.includes(':') && !src) continue
      if (dst.startsWith('refs/')) continue
      if (dst === 'HEAD') current = true
      else if (dst) named.push(dst)
    }
  }
  return { named, current }
}

/**
 * Why winding down refuses this call as new work, or undefined. Only the starts of new work are
 * refused; everything this issue's merge, deploy and cleanup need goes through. `cleanBranches` are
 * the branches Dan agreed to as cleanup (#1051) whose files cover what is uncommitted now: starting
 * one by checkout or switch, which carry those changes onto it, is not new work. A refused start of a
 * named branch says which, so the refusal can say why his answer did not cover it.
 */
export const newWork = (call: {
  tool: string
  input: Record<string, unknown>
  commands: Cmd[]
  issues: readonly number[]
  cleanBranches?: readonly string[]
}): (Refusal & { branch?: string }) | undefined => {
  const { tool, input } = call
  if (tool === 'Skill' && String(input.skill ?? '').replace(/^.*:/, '') === 'next-issue') return { what: NEW_WORK.nextIssue }
  if (tool === 'EnterWorktree') return { what: NEW_WORK.branch }
  if (tool === 'Agent' || tool === 'Task') {
    const prompt = String(input.prompt ?? '')
    for (const m of prompt.matchAll(ISSUE_REF)) {
      const n = Number(m[1])
      if (!call.issues.includes(n)) return { what: agentFor(n) }
    }
    return undefined
  }
  if (tool !== 'Bash') return undefined
  for (const c of call.commands) {
    const started = newBranchOf(c)
    if (started) {
      if (started.moves && started.name && call.cleanBranches?.includes(started.name)) continue
      return { what: NEW_WORK.branch, ...(started.name ? { branch: started.name } : {}) }
    }
    // gh read by mod-kit's one reader (#961), past its global flags (`gh -R o/x issue develop 7`).
    if (c.gh?.sub === 'issue' && c.gh.act === 'develop') return { what: NEW_WORK.branch }
    // A flag before the subcommand the reader cannot place could hide `issue develop`, so it is refused.
    if (c.gh?.unreadable) return { what: 'run a gh command whose flags cannot be read' }
  }
  return undefined
}
