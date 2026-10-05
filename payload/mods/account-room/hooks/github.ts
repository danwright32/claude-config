// The readings repository's requests and answers, pure (#750, decided with Dan on 2026-10-05: a
// private repository rather than iCloud Drive, whose upload backlog left figures late however
// rarely a file was written; not a gist, which anyone with its link can read). The calls
// themselves are made in register.tsx, through $.process.run and `gh api`, so a test answers each
// one and none can reach GitHub (L2).
//
// The answers are the ones measured against the real repository on 2026-10-05 (L52): a refusal is
// exit 1 with "gh: <message> (HTTP <status>)" on stderr; no login is exit 4 naming `gh auth login`;
// a missing file, a missing folder, a repository with no commit and a repository this account
// cannot see are all 404; a write with no sha over a file that exists is 422; a stale sha is 409.

/** What GitHub answered, or why it did not; `status` is the HTTP status of a refusal gh named. */
export type Answer<T> = { ok: true; value: T } | { ok: false; status?: number; why: string }

const short = (s: string) => (s.length > 160 ? `${s.slice(0, 160)}...` : s)

/**
 * A repository named as owner/name, which is all a contents path may carry: an owner of letters,
 * digits and hyphens, and a name that is not only dots, so a setting can never walk the path up.
 */
export const isRepoName = (s: string): boolean => /^[A-Za-z0-9-]+\/(?!\.+$)[A-Za-z0-9_.-]+$/.test(s)
export const notRepoName = (s: string): string => `the readingsRepo setting "${s}" is not a repository's owner/name`

/** The contents API path for one file or folder of the repository. */
export const contentsPath = (repo: string, path: string): string => `repos/${repo}/contents/${path.split('/').map(encodeURIComponent).join('/')}`

/** Text as the contents API carries it: base64 over its UTF-8 bytes. */
export const toBase64 = (text: string): string => {
  const bytes = new TextEncoder().encode(text)
  let bin = ''
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(bin)
}
/** The contents API's base64, which GitHub wraps over lines, back to text. */
export const fromBase64 = (b64: string): string => new TextDecoder().decode(Uint8Array.from(atob(b64.replace(/\s/g, '')), c => c.charCodeAt(0)))

/**
 * One `gh api` run read as an answer: its JSON on success, else why, in gh's own words as one line
 * (what was measured, never a guess at the cause, L11), with the HTTP status gh named. A run that
 * could not start or finish comes as the error it threw.
 */
export const answerOf = (r: { exitCode: number; stdout: string; stderr: string } | { thrown: string }): Answer<unknown> => {
  if ('thrown' in r) return { ok: false, why: `gh could not be run: ${short(r.thrown)}` }
  if (r.exitCode === 0) {
    try {
      return { ok: true, value: JSON.parse(r.stdout) as unknown }
    } catch {
      return { ok: false, why: 'GitHub answered with something that is not JSON' }
    }
  }
  if (r.exitCode === 4 || /gh auth login/.test(r.stderr)) return { ok: false, why: 'gh is not logged in to GitHub (gh auth login)' }
  const said = r.stderr.replace(/\s+/g, ' ').trim().replace(/^gh: /, '')
  const status = /\(HTTP (\d{3})\)$/.exec(said)?.[1]
  return { ok: false, ...(status ? { status: Number(status) } : {}), why: `gh api failed: ${short(said) || `exit ${r.exitCode}`}` }
}

/**
 * A 404 for the repository: GitHub gives the same answer for one that does not exist and one this
 * account cannot see, so the sentence names both, and the account gh used, which is what to fix.
 */
export const unseenWhy = (repo: string, user: Answer<unknown>): string => {
  const login = user.ok ? (user.value as { login?: unknown })?.login : undefined
  return `${repo} was not found, or ${typeof login === 'string' && login ? `gh's account ${login}` : 'the account gh is logged in to'} cannot see it`
}

/** A folder's entries as the contents API lists them. */
export const entriesOf = (value: unknown): Answer<{ name: string; type: string }[]> => {
  if (!Array.isArray(value)) return { ok: false, why: 'GitHub answered the readings folder with something that is not a folder' }
  return { ok: true, value: value.flatMap(e => (e && typeof e.name === 'string' && typeof e.type === 'string' ? [{ name: e.name as string, type: e.type as string }] : [])) }
}

export type RepoFile = { text: string; sha: string }

/** One file's text and sha as the contents API answers it. */
export const fileOf = (value: unknown, path: string): Answer<RepoFile> => {
  const o = value as { type?: unknown; encoding?: unknown; content?: unknown; sha?: unknown }
  if (!o || o.type !== 'file' || o.encoding !== 'base64' || typeof o.content !== 'string' || typeof o.sha !== 'string') return { ok: false, why: `GitHub answered ${path} with something that is not a file` }
  try {
    return { ok: true, value: { text: fromBase64(o.content), sha: o.sha } }
  } catch (err) {
    return { ok: false, why: `GitHub's copy of ${path} could not be decoded: ${String((err as Error)?.message ?? err)}` }
  }
}

/** A write's body: the whole file, over the sha it was read at, or none for a new file. */
export const putBody = (text: string, sha: string | undefined, commit: string): string => JSON.stringify({ message: commit, content: toBase64(text), ...(sha ? { sha } : {}) })

/** The sha a write left, or undefined when GitHub took it without naming one. */
export const shaAfterPut = (value: unknown): string | undefined => {
  const sha = (value as { content?: { sha?: unknown } })?.content?.sha
  return typeof sha === 'string' ? sha : undefined
}
