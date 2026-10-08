// The one reading of where a checkout stands (#978): its project's main working tree, which every
// worktree of it shares, the branch it is on, the project's default branch, and the issues the
// branch names. Two mods read some of this each its own way (scope-modes' winding down, the collision
// guard's judge prompt), and the design round guard of #978 would have been a third copy. This is the
// reader they share, the design round guard first, the other two moving onto it in their own change
// (L613).
import type { ModKitBranch } from '../types/index.d.ts'

/** A git command run in the checkout: its exit code and output, or a rejection when it could not run. */
export type Run = (argv: string[]) => Promise<{ exitCode: number; stdout: string; stderr: string }>

/**
 * The issues a branch names: every run of 2 to 6 digits standing on its own, `978-guard`,
 * `fix/issue-41-and-52`. One digit is too often a version or a count to read as an issue. The
 * reading winding down has used since #702.
 */
export const issuesOfBranch = (branch: string): number[] => [...branch.matchAll(/(?:^|[^0-9])(\d{2,6})(?=$|[^0-9])/g)].map(m => Number(m[1]))

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
  const branch = b.stdout.trim()
  if (!branch) return { root, main, unreadable: 'a detached head names no branch' }
  const defaultBranch = h.exitCode === 0 && h.stdout.trim() ? h.stdout.trim().replace(/^origin\//, '') : null
  return { root, main, branch, defaultBranch, isDefault: isDefaultBranch(branch, defaultBranch), issues: issuesOfBranch(branch) }
}
