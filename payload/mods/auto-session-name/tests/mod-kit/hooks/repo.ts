// The one reading of a session's repository (#951): four mods read the origin remote by hand, and
// the copies drifted (one took any host ending in github.com, one read a .git folder's path as a
// GitHub repository, none took a port). Two questions are asked of it, kept apart because they
// differ (L342):
//   githubRepo  which GitHub repository the origin is, as owner/name: GitHub only, and a remote
//               that is a local path is none, even one spelled owner/name.
//   repoName    what the repository is called: the origin's last part on any host, else the
//               checkout folder, a worktree under .claude/worktrees naming its parent.
// A gh command's own repository argument (owner/name alone is a repository there) is a third
// question, read by scope-modes' gh reader.

/** A remote address as git reads it: its host, lower case (null for a local path), and its path's parts, with .git off the last. */
type Address = { host: string | null; parts: string[] }

const SCHEME = /^([a-z][a-z0-9+.-]*):\/\/(.*)$/i
const GITHUB = 'github.com'
const NAME_PART = /^[\w.-]+$/
const WORKTREES = '/.claude/worktrees/'

const partsOf = (path: string): string[] => {
  const parts = path.split('/').filter(Boolean)
  // A checkout's own .git folder is named by the folder holding it.
  if (parts[parts.length - 1]?.toLowerCase() === '.git') parts.pop()
  const last = parts.length - 1
  if (last >= 0) parts[last] = (parts[last] as string).replace(/\.git$/i, '')
  return parts.filter(Boolean)
}

// Git's own reading (git help clone, GIT URLS): a scheme and ://, else the scp form, which has a
// colon before any slash (`git@host:o/r.git`, `host:o/r`), else a local path.
const addressOf = (remote: string): Address | null => {
  const t = remote.trim()
  if (!t) return null
  const url = SCHEME.exec(t)
  if (url) {
    const rest = url[2] as string
    if ((url[1] as string).toLowerCase() === 'file') return { host: null, parts: partsOf(rest) }
    const slash = rest.indexOf('/')
    const authority = slash < 0 ? rest : rest.slice(0, slash)
    // user@ and :port off.
    const host = authority.replace(/^.*@/, '').replace(/:\d*$/, '').toLowerCase()
    return { host: host || null, parts: partsOf(slash < 0 ? '' : rest.slice(slash)) }
  }
  const colon = t.indexOf(':')
  const slash = t.indexOf('/')
  if (colon > 0 && (slash < 0 || colon < slash)) {
    const host = t.slice(0, colon).replace(/^.*@/, '').toLowerCase()
    return { host: host || null, parts: partsOf(t.slice(colon + 1)) }
  }
  return { host: null, parts: partsOf(t) }
}

/** The GitHub repository a remote address names, as owner/name in the case written; null for another host, a local path, or no address. */
export const githubRepo = (remote: string | null | undefined): string | null => {
  const a = addressOf(remote ?? '')
  if (!a || a.host === null || a.host.replace(/^www\./, '') !== GITHUB) return null
  if (a.parts.length !== 2 || a.parts.some(p => !NAME_PART.test(p))) return null
  return a.parts.join('/')
}

/** The folder a checkout is known by: its own, or for a worktree under .claude/worktrees its parent's. */
const checkoutName = (root: string): string => {
  const r = root.replace(/\/+$/, '')
  const at = `${r}/`.indexOf(WORKTREES)
  const folder = at >= 0 ? r.slice(0, at) : r
  return folder.split('/').pop() ?? ''
}

/** What a repository is called: the last part of its origin on any host, else its checkout folder's name; null when neither names one. */
export const repoName = (repo: { root?: string | null; remote: string | null | undefined }): string | null =>
  addressOf(repo.remote ?? '')?.parts.pop() || checkoutName(repo.root ?? '') || null
