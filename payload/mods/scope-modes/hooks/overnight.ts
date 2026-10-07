import { deployWith, ghApiCall, graphqlDocument, operations, runnerScript, type Cmd } from './nobuild.ts'

// Sleep mode phase 7 (#843): what may merge and deploy overnight, per repository.
//
// One shared file, mods/sleep-repos.json in the payload (both Macs read it, and an answer one Mac
// writes reaches the other through the sync, as the account room's nicknames do), holds two lists:
// `mergeOnly`, repositories that may merge overnight but never deploy, and `mayDeploy`, those that
// may merge and run their own deploy step as in the daytime. A mergeOnly entry whose merge itself
// deploys (`mergeDeploys: true`), or whose file does not say (`unknown`, L72), is refused the merge too, leaving the
// green PR open for the morning (Dan's decision 6, 2026-10-06).
//
// Everything without an answer fails closed, no merge and no deploy for the night (L42): a file
// missing or unreadable, a repository on both lists or on neither, an entry GitHub does not know,
// a question at bedtime left unanswered, and a repository first met after sleep began. /sleep reads
// the file once and writes what it found into the sleep record (`repos`), so the night is judged by
// what was settled at bedtime, never by a later edit (an answer given late counts from the next
// night). A direct push to a default branch is refused in every repository.
//
// Pure: the shell is read by mod-kit's one reader and handed in, and the deploy tools are no build's
// own list (nobuild.ts), so a tool added there is refused here too (L613).

/**
 * One mergeOnly entry: `mergeDeploys` true when a merge itself deploys, `unknown` when the file does
 * not say. Only false lets a merge run overnight.
 */
export type RepoEntry = { repo: string; mergeDeploys: boolean | 'unknown' }
/** The shared file, as read. */
export type RepoLists = { mayDeploy: string[]; mergeOnly: RepoEntry[] }
/** A repository closed for the night, and why, for the refusal and the morning report. */
export type ClosedRepo = { repo: string; why: string }
/** What the sleep record carries for the night (`repos`): the lists as settled at bedtime. */
export type NightRepos = { mayDeploy: string[]; mergeOnly: RepoEntry[]; closed: ClosedRepo[]; listWhy?: string }

/** What a repository may do tonight. */
export type Policy = { kind: 'deploy'; repo: string } | { kind: 'merge-only'; repo: string; mergeDeploys: boolean | 'unknown' } | { kind: 'closed'; repo?: string; why: string }

export const REPO_LIST_FILE = 'mods/sleep-repos.json'
const SLUG = /^[\w.-]+\/[\w.-]+$/
const key = (repo: string) => repo.toLowerCase()

/** The shared file's text (null when there is none) as lists, or why it cannot be trusted at all. */
export const readRepoLists = (text: string | null): { lists: RepoLists } | { why: string } => {
  if (text === null) return { why: `${REPO_LIST_FILE} is missing` }
  let j: unknown
  try {
    j = JSON.parse(text)
  } catch {
    return { why: `${REPO_LIST_FILE} is not JSON` }
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) return { why: `${REPO_LIST_FILE} is not a record` }
  const r = j as Record<string, unknown>
  if (typeof r.v !== 'number' || !(r.v >= 1)) return { why: `${REPO_LIST_FILE} has no version this reader knows` }
  if (!Array.isArray(r.mayDeploy) || !Array.isArray(r.mergeOnly)) return { why: `${REPO_LIST_FILE} does not hold both lists` }
  const mayDeploy: string[] = []
  for (const e of r.mayDeploy) {
    if (typeof e !== 'string' || !SLUG.test(e)) return { why: `${REPO_LIST_FILE} has a mayDeploy entry that is not owner/name: ${JSON.stringify(e)}` }
    mayDeploy.push(e)
  }
  const mergeOnly: RepoEntry[] = []
  for (const e of r.mergeOnly) {
    const o = e as Record<string, unknown> | null
    if (!o || typeof o !== 'object' || typeof o.repo !== 'string' || !SLUG.test(o.repo)) return { why: `${REPO_LIST_FILE} has a mergeOnly entry with no owner/name: ${JSON.stringify(e)}` }
    if (o.mergeDeploys !== undefined && typeof o.mergeDeploys !== 'boolean') return { why: `${REPO_LIST_FILE} gives ${o.repo} a mergeDeploys that is not true or false` }
    // Unsaid is the strict answer: a merge is taken to deploy until the file says it does not (L72).
    mergeOnly.push({ repo: o.repo, mergeDeploys: o.mergeDeploys === undefined ? 'unknown' : o.mergeDeploys })
  }
  return { lists: { mayDeploy, mergeOnly } }
}

/** Every repository the lists name, once each, for the bedtime check that GitHub knows them. */
export const listedRepos = (lists: RepoLists): string[] => {
  const seen = new Map<string, string>()
  for (const r of [...lists.mergeOnly.map(e => e.repo), ...lists.mayDeploy]) if (!seen.has(key(r))) seen.set(key(r), r)
  return [...seen.values()]
}

/** Whether a repository is on either list. */
export const isListed = (lists: RepoLists, repo: string): boolean => listedRepos(lists).some(r => key(r) === key(repo))

/**
 * The night's lists as the sleep record carries them, from the file as read at bedtime, the
 * entries GitHub could not find, and the repositories closed for another reason (a question left
 * unanswered). A repository on both lists is closed, never given the looser one.
 */
export const nightRepos = (read: { lists: RepoLists } | { why: string }, closed: ClosedRepo[]): NightRepos => {
  if ('why' in read) return { mayDeploy: [], mergeOnly: [], closed, listWhy: read.why }
  const shut = new Map(closed.map(c => [key(c.repo), c]))
  const deploys = new Set(read.lists.mayDeploy.map(key))
  for (const e of read.lists.mergeOnly)
    if (deploys.has(key(e.repo)) && !shut.has(key(e.repo))) shut.set(key(e.repo), { repo: e.repo, why: `${e.repo} is on both lists in ${REPO_LIST_FILE}` })
  return {
    mayDeploy: read.lists.mayDeploy.filter(r => !shut.has(key(r))),
    mergeOnly: read.lists.mergeOnly.filter(e => !shut.has(key(e.repo))),
    closed: [...shut.values()],
  }
}

const isNight = (n: unknown): n is NightRepos => {
  const o = n as NightRepos | null
  return !!o && typeof o === 'object' && Array.isArray(o.mayDeploy) && Array.isArray(o.mergeOnly) && Array.isArray(o.closed)
}

/**
 * What `repo` may do tonight, from the lists the sleep record carries. No lists (a record written
 * before this phase), a repository that could not be told, and one on neither list are all closed.
 */
export const policyOf = (night: unknown, repo: string | undefined): Policy => {
  if (!isNight(night)) return { kind: 'closed', ...(repo ? { repo } : {}), why: 'the sleep record carries no merge and deploy lists' }
  if (!repo) return { kind: 'closed', why: 'which repository this reaches could not be told' }
  if (night.listWhy) return { kind: 'closed', repo, why: night.listWhy }
  const shut = night.closed.find(c => key(c.repo) === key(repo))
  if (shut) return { kind: 'closed', repo, why: shut.why }
  if (night.mayDeploy.some(r => key(r) === key(repo))) return { kind: 'deploy', repo }
  const m = night.mergeOnly.find(e => key(e.repo) === key(repo))
  if (m) return { kind: 'merge-only', repo, mergeDeploys: m.mergeDeploys }
  return { kind: 'closed', repo, why: `${repo} is on neither list in ${REPO_LIST_FILE}` }
}

/** One thing a command would do that this phase judges, and the repository it names, when it names one. */
export type Act = { kind: 'merge' | 'deploy' | 'push-default'; what: string; repo?: string }

/**
 * A package.json's scripts as the judge needs them: each script's body as the commands mod-kit's
 * reader finds in it, none (no file), or why they cannot be read.
 */
export type Scripts = Record<string, Cmd[]> | null | { unreadable: string }

/** What the judge knows about where a command runs: its default branch (or the usual names) and current branch. */
export type Where = { defaultBranch: string | null; currentBranch: string | null; scripts: Scripts }

const isFlag = (w: string) => w.startsWith('-') && w !== '-'
const name = (w: string | undefined) => (w ?? '').split('/').pop() ?? ''
const repoFlag = (words: string[]): string | undefined => {
  for (let i = 0; i < words.length; i++) {
    const w = words[i] as string
    if (w === '-R' || w === '--repo') return words[i + 1]
    if (w.startsWith('--repo=')) return w.slice('--repo='.length)
  }
  return undefined
}
const repoOfEndpoint = (endpoint: string | undefined) => /^\/?repos\/([\w.-]+\/[\w.-]+)\//.exec(endpoint ?? '')?.[1]
const MERGE_MUTATION = /^(?:mergePullRequest|enablePullRequestAutoMerge|mergeBranch)$/

// A deploy a package script's body runs, one level deep: each command mod-kit's reader found in
// it, and a script it runs by name judged by that name.
const bodyDeploys = (body: Cmd[]): string | undefined => {
  for (const c of body) {
    const d = deployWith(c.words)
    if (d) return d
  }
  return undefined
}

const DEFAULTS = ['main', 'master']
const strip = (ref: string) => ref.replace(/^\+/, '').replace(/^refs\/heads\//, '')

// A push reaching the default branch: a refspec whose destination is it, every branch at once, or
// no refspec at all from the default branch itself (push.default sends the current branch).
const pushToDefault = (args: string[], where: Where): string | undefined => {
  const defaults = where.defaultBranch ? [where.defaultBranch] : DEFAULTS
  const isDefault = (b: string | null) => b !== null && defaults.includes(b)
  if (args.some(a => a === '--all' || a === '--mirror' || a === '--branches')) return 'push every branch, the default one included'
  // Flags taking a value, so the value is not read as the remote or a refspec.
  const valued = new Set(['-o', '--push-option', '--repo', '--receive-pack', '--exec'])
  const ops: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (valued.has(a)) i++
    else if (!isFlag(a)) ops.push(a)
  }
  const refspecs = ops.slice(1)
  if (!refspecs.length) {
    if (where.currentBranch === null) return 'push from a branch that could not be read'
    return isDefault(where.currentBranch) ? `push ${where.currentBranch} straight to GitHub` : undefined
  }
  for (const spec of refspecs) {
    const [src, dst] = spec.includes(':') ? (spec.split(':') as [string, string]) : [spec, spec]
    const target = strip(dst === '' ? src : dst)
    const resolved = target === 'HEAD' ? where.currentBranch : target
    if (resolved === null) return 'push from a branch that could not be read'
    if (isDefault(resolved)) return `push ${resolved} straight to GitHub`
  }
  return undefined
}

/** What one command would do that this phase judges: merge a PR, deploy, or push to the default branch. */
export const actsOf = (c: Cmd, where: Where): Act[] => {
  const out: Act[] = []
  const words = c.words
  const cmd = name(words[0])
  // The merge helper merges by gh inside a script the reader never sees, so it is a merge by its name.
  if (words.some(w => /(?:^|\/)merge-when-ready\.sh$/.test(w))) out.push({ kind: 'merge', what: 'merge a PR with merge-when-ready.sh', repo: repoFlag(words) })
  if (c.git?.sub === 'push') {
    const p = pushToDefault(c.git.args, where)
    if (p) out.push({ kind: 'push-default', what: p })
  }
  if (cmd === 'gh') {
    const [, sub = '', act = ''] = words
    const repo = repoFlag(words)
    if (sub === 'pr' && act === 'merge') out.push({ kind: 'merge', what: `merge a PR${words.includes('--auto') ? ' (auto merge)' : ''}`, repo })
    if (sub === 'workflow' && act === 'run') out.push({ kind: 'deploy', what: 'run a workflow (gh workflow run)', repo })
    if (sub === 'api') {
      const { method, endpoint } = ghApiCall(words)
      const at = repoOfEndpoint(endpoint) ?? repo
      if (endpoint === 'graphql') {
        const doc = graphqlDocument(words)
        const fields = doc === null ? null : operations(doc).filter(o => o.kind === 'mutation').flatMap(o => (o.spreads ? ['...'] : o.fields))
        if (fields === null) out.push({ kind: 'merge', what: 'call the GitHub API with a query that could not be read', repo: at })
        else if (fields.some(f => f === '...' || MERGE_MUTATION.test(f))) out.push({ kind: 'merge', what: 'merge a PR through the GitHub API', repo: at })
      } else if (method !== 'GET' && endpoint) {
        if (/\/pulls\/\d+\/merge\/?$/.test(endpoint) || /\/merges\/?$/.test(endpoint)) out.push({ kind: 'merge', what: `merge through the GitHub API (${endpoint})`, repo: at })
        if (/\/dispatches\/?$/.test(endpoint)) out.push({ kind: 'deploy', what: `start a workflow through the GitHub API (${endpoint})`, repo: at })
        const ref = /\/git\/refs\/heads\/(.+?)\/?$/.exec(endpoint)?.[1]
        const defaults = where.defaultBranch ? [where.defaultBranch] : DEFAULTS
        if (ref && defaults.includes(ref)) out.push({ kind: 'push-default', what: `move ${ref} through the GitHub API`, repo: at })
      }
    }
  }
  const deploys = deployWith(words)
  if (deploys) out.push({ kind: 'deploy', what: deploys })
  else {
    const script = runnerScript(words)
    if (script) {
      const s = where.scripts
      if (s && 'unreadable' in s) out.push({ kind: 'deploy', what: `run the ${script} script, whose body could not be read (${s.unreadable})` })
      else if (s && Object.prototype.hasOwnProperty.call(s, script)) {
        const inner = bodyDeploys(s[script] as Cmd[])
        if (inner) out.push({ kind: 'deploy', what: `run the ${script} script, which would ${inner}` })
      }
    }
  }
  return out
}

/** How long a bedtime question waits for Dan before its repository is closed for the night. */
export const QUESTION_MS = 10 * 60_000
/** A merge there does not itself deploy: merge overnight, never deploy. */
export const MERGE_NO_DEPLOY = 'Merge, never deploy'
/** A merge there deploys, or Dan is not sure: the green PR waits for the morning, and nothing deploys. */
export const HOLD_MERGES = 'Hold merges, never deploy'
export const MAY_DEPLOY = 'Allowed to deploy'
export const REPO_ANSWERS = [MERGE_NO_DEPLOY, HOLD_MERGES, MAY_DEPLOY] as const

/** The bedtime question about a repository on neither list. */
export const repoQuestion = (repo: string) =>
  `Choose "${MERGE_NO_DEPLOY}" only if a merge there does not itself deploy. Overnight in ${repo}, what may Claude do?`

/** A marker file's text (the preparing marker, the answers lock): who holds it, since when, and its own nonce. */
export type Marker = { owner: string; at: number; nonce: string }
export const markerText = (m: Marker) => JSON.stringify(m)
export const readMarker = (text: string): Marker | { unreadable: string } => {
  let j: unknown
  try {
    j = JSON.parse(text)
  } catch {
    return { unreadable: 'it is not JSON' }
  }
  const m = j as Partial<Marker> | null
  if (!m || typeof m.owner !== 'string' || typeof m.at !== 'number' || !Number.isFinite(m.at) || typeof m.nonce !== 'string') return { unreadable: 'it names no owner, time and nonce' }
  return { owner: m.owner, at: m.at, nonce: m.nonce }
}

/** The shared file as installed with the rest of the payload on both Macs. */
export const repoListPath = (home: string) => `${home.replace(/\/+$/, '')}/.claude/${REPO_LIST_FILE}`

/** owner/name from an origin remote, ssh or https, or undefined. */
export const slugOf = (remote: string | undefined | null) => /github\.com[:/]([\w.-]+\/[\w.-]+?)(?:\.git)?\/?$/.exec((remote ?? '').trim())?.[1]

/** The shared file with one bedtime answer added, or why it cannot be. */
export const addAnswer = (text: string | null, repo: string, answer: string): { text: string } | { why: string } => {
  if (!(REPO_ANSWERS as readonly string[]).includes(answer)) return { why: `the answer was none of the choices ("${answer}")` }
  const read = readRepoLists(text)
  if ('why' in read) return read
  if (isListed(read.lists, repo)) return { why: `${repo} is already listed` }
  const j = JSON.parse(text as string) as Record<string, unknown> & { mergeOnly: unknown[]; mayDeploy: unknown[] }
  if (answer === MERGE_NO_DEPLOY) j.mergeOnly.push({ repo, mergeDeploys: false })
  else if (answer === HOLD_MERGES) j.mergeOnly.push({ repo, mergeDeploys: true })
  else j.mayDeploy.push(repo)
  return { text: `${JSON.stringify(j, null, 2)}\n` }
}

/** A package.json's scripts from its text, each body as written (null when there is no file); the caller reads each body with mod-kit's reader. */
export const scriptsOf = (text: string | null): Record<string, string> | null | { unreadable: string } => {
  if (text === null) return null
  try {
    const s = (JSON.parse(text) as { scripts?: unknown }).scripts
    if (s === undefined) return {}
    if (!s || typeof s !== 'object' || Array.isArray(s)) return { unreadable: 'its scripts are not a record' }
    return Object.fromEntries(Object.entries(s).filter(([, v]) => typeof v === 'string')) as Record<string, string>
  } catch {
    return { unreadable: 'package.json is not JSON' }
  }
}

/** Where a command runs and what is read there: its default and current branch, its origin's owner/name, and its package scripts. */
export type Place = Where & { own: string | undefined }

const join = (base: string, p: string) => {
  const parts = (p.startsWith('/') ? p : `${base}/${p}`).split('/')
  const out: string[] = []
  for (const part of parts) {
    if (part === '' || part === '.') continue
    if (part === '..') out.pop()
    else out.push(part)
  }
  return `/${out.join('/')}`
}
// A path word this can follow: spelled out, or under ~; anything a shell would expand otherwise
// (a variable, a pattern, a substitution) is a place it cannot see.
const literal = (w: string | undefined, home: string): string | null => {
  if (w === undefined || w === '' || /[$`*?[\]{}()]/.test(w)) return null
  if (w === '~' || w.startsWith('~/')) return home ? `${home}${w.slice(1)}` : null
  if (w.startsWith('~')) return null
  return w
}

/**
 * The folder each command runs in, as the #892 push hook resolves it: the session's folder, moved by
 * each `cd` or `pushd` before it, and by a git command's own -C. Null where it cannot be followed (a
 * variable, a pattern, `popd`, a bare `cd`, or --git-dir and --work-tree, which name a repository
 * apart from any folder), and from then on, which is a repository that cannot be told (L75).
 */
export const dirsOf = (commands: Cmd[], cwd: string, home: string): (string | null)[] => {
  let dir: string | null = cwd || null
  const out: (string | null)[] = []
  for (const c of commands) {
    const cmd = name(c.words[0])
    if (cmd === 'cd' || cmd === 'pushd') {
      const to = c.words.slice(1).filter(w => !isFlag(w))[0]
      const lit = literal(to, home)
      dir = dir !== null && lit !== null ? join(dir, lit) : null
      out.push(dir)
      continue
    }
    if (cmd === 'popd') {
      dir = null
      out.push(dir)
      continue
    }
    if (cmd === 'git') {
      let here = dir
      for (let i = 1; i < c.words.length; i++) {
        const w = c.words[i] as string
        if (w === '-C') {
          const lit = literal(c.words[++i], home)
          here = here !== null && lit !== null ? join(here, lit) : null
        } else if (/^--(?:git-dir|work-tree)(?:=|$)/.test(w)) here = null
        else if (!w.startsWith('-')) break
      }
      out.push(here)
      continue
    }
    out.push(dir)
  }
  return out
}

/** What a call needs read before it can be judged: whether it pushes or calls gh, or runs a package script. */
export const needsOf = (commands: Cmd[]) => ({
  branch: commands.some(c => c.git?.sub === 'push' || name(c.words[0]) === 'gh'),
  scripts: commands.some(c => runnerScript(c.words) !== undefined),
})

/**
 * The first act in a call tonight's lists refuse, with the refusal Claude reads. The repository is
 * the one a command names (--repo, a repos/ endpoint), else the one in the folder it runs in
 * (`places`, one per command, null where the folder could not be followed or read, which is a
 * repository that cannot be told, closed, L75).
 */
export const judgeNight = (night: unknown, commands: Cmd[], places: (Place | null)[]): { deny: string; what: string; repo?: string; why: string } | undefined => {
  const unseen: Place = { defaultBranch: null, currentBranch: null, scripts: { unreadable: 'the folder it runs in could not be followed' }, own: undefined }
  for (let i = 0; i < commands.length; i++) {
    const c = commands[i] as Cmd
    const place = places[i] ?? unseen
    for (const act of actsOf(c, place)) {
      const repo = act.repo ?? place.own
      const why = refusalOf(act, policyOf(night, repo))
      if (why)
        return {
          what: act.what,
          ...(repo ? { repo } : {}),
          why,
          deny: `Blocked overnight: this would ${act.what}, and ${why}. Leave the green PR open and write a note for the morning report saying what is waiting and why; carry on with other work.`,
        }
    }
  }
  return undefined
}

/** Every repository closed tonight, as one sentence for /sleep's answer, or empty. */
export const closedSentence = (night: NightRepos): string => {
  if (night.listWhy) return ` Merging and deploying are off for every repository tonight: ${night.listWhy}.`
  if (!night.closed.length) return ''
  return ` No merge and no deploy tonight in ${night.closed.map(c => `${c.repo} (${c.why})`).join('; ')}.`
}

/** Whether tonight's policy refuses an act, and the sentence saying why. */
export const refusalOf = (act: Act, policy: Policy): string | undefined => {
  if (act.kind === 'push-default') return 'a direct push to a default branch is never made overnight; push a branch and open a PR'
  if (policy.kind === 'closed') return `${policy.why}, so tonight it neither merges nor deploys`
  if (act.kind === 'deploy' && policy.kind === 'merge-only') return `${policy.repo} may merge overnight but never deploy`
  if (act.kind === 'merge' && policy.kind === 'merge-only' && policy.mergeDeploys === true) return `a merge in ${policy.repo} deploys, so it is never merged overnight`
  if (act.kind === 'merge' && policy.kind === 'merge-only' && policy.mergeDeploys !== false)
    return `whether a merge in ${policy.repo} deploys is not recorded in ${REPO_LIST_FILE}, so it is never merged overnight`
  return undefined
}
