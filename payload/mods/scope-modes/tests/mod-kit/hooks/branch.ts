// The one reading of where a checkout stands (#978): its project's main working tree, which every
// worktree of it shares, the branch it is on, the project's default branch, and the issues the
// branch names. Two mods read some of this each its own way (scope-modes' winding down, the collision
// guard's judge prompt), and the design round guard of #978 would have been a third copy. This is the
// reader they share, the design round guard first, the other two moving onto it in their own change
// (L613).
import type { ModKitBranch } from '../types/index.d.ts'

/** The words that make a two digit number just after them a step of a plan, never an issue (#1475). */
const STEP_WORDS = new Set(['pr', 'phase', 'step', 'stage', 'part', 'slice', 'wave', 'batch', 'round', 'pass', 'milestone', 'p', 'v', 'version'])

/** A git command run in the checkout: its exit code and output, or a rejection when it could not run. */
export type Run = (argv: string[]) => Promise<{ exitCode: number; stdout: string; stderr: string }>

/**
 * The issues a branch names: each part of it, between a `/`, `-`, `_` or `.`, that is 2 to 6 digits
 * with at most one letter after them, `978-guard`, `fix/issue-41-and-52`, `961a-gh-reader` (a part of
 * #961). One digit is too often a version or a count to read as an issue. Digits inside a word are
 * not one (#1306): an agent worktree's branch, `worktree-agent-ad4e7831d26de84f8`, named #7831, #26
 * and #84 from its random hex id, so Dan's answers were kept under issues it never named, for every
 * later agent whose id held the same digits. A branch naming none is keyed by its own name.
 *
 * Nor is a step of a plan, a date or a version (#1475): a Bidspoke builder on
 * `connections-pr10-form-2338`, step 10 of #2338's plan, was refused every screen edit as #10, and
 * `pr-10` spelled with a hyphen still read so. So a number of two digits just after a step word
 * (`pr-10`, `phase-12`, `milestone-61`) is a step, a run of numbers joined by dots or led by a
 * single digit (`tsx-4.23.12`, `routes-2-1-299`) a version, and a year, month and day
 * (`guard-costs/2026-09-03`) a date. A step word before three digits or more is not a step:
 * `faster-pr-989-daily-guard-sweep` and `reprep-listing-phase-1880` each name their issue. An `i` or
 * `issue` glued to three digits or more is one (`i2968-dismissed-followup-render`), while a plan's
 * slice `i2` stays none. An issue number never starts with 0.
 *
 * This is the one reader of the issues a branch names: hooks and libraries outside the mods reach
 * it through hooks/lib/branch-issues.mjs, and hooks/test-branch-issue-reader.sh fails on any other.
 */
export const issuesOfBranch = (branch: string): number[] => {
  const parts = [...branch.matchAll(/([/_.-]*)([^/_.-]+)/g)].map(m => ({ sep: m[1] ?? '', text: m[2] ?? '' }))
  const text = (i: number) => parts[i]?.text ?? ''
  const bare = (i: number) => /^\d+$/.test(text(i))
  const not = new Set<number>()
  for (let i = 0; i + 2 < parts.length; i++) {
    const [y, m, d] = [text(i), text(i + 1), text(i + 2)]
    if (/^\d{4}$/.test(y) && /^(0[1-9]|1[0-2])$/.test(m) && /^(0[1-9]|[12]\d|3[01])$/.test(d)) [i, i + 1, i + 2].forEach(k => not.add(k))
  }
  for (let i = 0; i < parts.length; ) {
    let j = i
    while (bare(j) && bare(j + 1)) j++
    if (j > i && (parts.slice(i + 1, j + 1).some(p => p.sep.includes('.')) || text(i).length === 1)) for (let k = i; k <= j; k++) not.add(k)
    i = j + 1
  }
  return parts.flatMap((_, i) => {
    const n = /^(?:issue(?=\d)|i(?=\d{3}))?(\d{2,6})[a-z]?$/i.exec(text(i))?.[1]
    if (n === undefined || n.startsWith('0') || not.has(i)) return []
    if (n.length === 2 && i > 0 && STEP_WORDS.has(text(i - 1).toLowerCase())) return []
    return [Number(n)]
  })
}

/** The main working tree `git worktree list --porcelain` names first; null when it names none. */
export const mainOf = (porcelain: string): string | null => /^worktree (.+)$/m.exec(porcelain)?.[1]?.trim() || null

/**
 * Whether a branch is the project's default: the one origin/HEAD names, or, since origin/HEAD is
 * often never set locally, main or master when it names none.
 */
export const isDefaultBranch = (branch: string, defaultBranch: string | null): boolean => (defaultBranch ? branch === defaultBranch : ['main', 'master'].includes(branch))

const said = (r: { exitCode: number; stderr: string }) => r.stderr.trim().split('\n')[0] || `git exited ${r.exitCode}`

const tryRun = async (run: Run, argv: string[]) => {
  try {
    return await run(argv)
  } catch (err) {
    return { exitCode: -1, stdout: '', stderr: String((err as Error)?.message ?? err) }
  }
}

/**
 * Where the checkout an absolute path sits in stands, as `$.modkit.branch` answers: the checkout
 * found by `walk` (the kit's one walk for a `.git` entry), then read by `readBranch`. A walk that
 * finds none is null, and git is asked nothing.
 */
export const branchAt = async (path: string, walk: (path: string) => Promise<string | null | undefined>, run: Run): Promise<ModKitBranch | null> => {
  const root = await walk(path)
  // Undefined and null alike: no checkout never reaches git as `git -C null` (#985 review).
  if (root == null) return null
  return readBranch(root, run)
}

/**
 * The branch a rebase in progress is rebasing, or '' when none is (#1210). A rebase leaves the head
 * detached, and a reader keyed on the branch then refused work in a worktree whose branch named its
 * issue. git records the branch in its rebase notes under the checkout's git folder: rebase-merge
 * for an interactive or merge rebase, rebase-apply for the rest. Asked only when the head is
 * detached, so a checkout on a branch costs nothing more. Notes that cannot be read, or that name
 * no branch, are no rebase, and the head stays unreadable rather than guessed.
 */
const rebasing = async (root: string, run: Run): Promise<string> => {
  const where = await tryRun(run, ['git', '-C', root, 'rev-parse', '--git-path', 'rebase-merge/head-name', '--git-path', 'rebase-apply/head-name'])
  if (where.exitCode !== 0) return ''
  for (const p of where.stdout.split('\n').map(l => l.trim()).filter(Boolean)) {
    const file = p.startsWith('/') ? p : `${root.replace(/\/$/, '')}/${p}`
    const read = await tryRun(run, ['cat', file])
    const name = read.exitCode === 0 ? read.stdout.trim() : ''
    if (name.startsWith('refs/heads/')) return name.slice('refs/heads/'.length)
  }
  return ''
}

/**
 * Where the checkout at `root` stands, asked of git (three reads at once, so the whole answer is
 * bounded by the slowest one). A branch git cannot read, a detached head, or a main working tree
 * git does not name is `unreadable`, saying which, never a guess: a reader deciding what an edit
 * may do must not decide on one. A default branch that cannot be read is none, and main or master
 * is taken as it.
 */
export const readBranch = async (root: string, run: Run): Promise<ModKitBranch> => {
  const [b, w, h] = await Promise.all([
    tryRun(run, ['git', '-C', root, 'branch', '--show-current']),
    tryRun(run, ['git', '-C', root, 'worktree', 'list', '--porcelain']),
    tryRun(run, ['git', '-C', root, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD']),
  ])
  const main = w.exitCode === 0 ? mainOf(w.stdout) : null
  if (main === null) return { root, main: null, unreadable: w.exitCode === 0 ? 'git named no main working tree' : `git could not list its worktrees: ${said(w)}` }
  if (b.exitCode !== 0) return { root, main, unreadable: `git could not read the branch: ${said(b)}` }
  const branch = b.stdout.trim() || (await rebasing(root, run))
  if (!branch) return { root, main, unreadable: 'a detached head names no branch' }
  const defaultBranch = h.exitCode === 0 && h.stdout.trim() ? h.stdout.trim().replace(/^origin\//, '') : null
  return { root, main, branch, defaultBranch, isDefault: isDefaultBranch(branch, defaultBranch), issues: issuesOfBranch(branch) }
}
