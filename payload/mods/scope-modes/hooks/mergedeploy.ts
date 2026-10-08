import { deployWith, hasFlag, operations, runnerScript, runsHelper, type Cmd } from './nobuild.ts'
import { resolveDir } from './overnight.ts'

// Sleep mode phase 7 (#843): what may merge and deploy overnight, per repository.
//
// One shared file, mods/sleep-repos.json in the payload (both Macs read it, and an answer one Mac
// writes reaches the other through the sync, as the account room's nicknames do), holds two lists:
// `mergeOnly`, repositories that may merge overnight but never deploy, and `mayDeploy`, those that
// may merge and run their own deploy step as in the daytime. A mergeOnly entry whose merge itself
// deploys (`mergeDeploys: true`), or whose file does not say (`unknown`, L72), is refused the merge too, leaving the
// green PR open for the morning (Dan's decision 6, 2026-10-06).
//
// A third, optional list, `waitOwners`, names GitHub owners every one of whose repositories waits
// overnight, no merge and no deploy, including ones no list names and ones made later (Dan,
// 2026-10-07: "Move ANYTHING in halo-lab-trypennie to the wait list automatically. Nothing in that
// account should merge overnight"). It matches the owner in any case and outranks both lists, so an
// entry under such an owner on either list is a conflict that waits (L42).
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
export type RepoLists = { mayDeploy: string[]; mergeOnly: RepoEntry[]; waitOwners: string[] }
/** A repository closed for the night, and why, for the refusal and the morning report. */
export type ClosedRepo = { repo: string; why: string }
/** What the sleep record carries for the night (`repos`): the lists as settled at bedtime. */
export type NightRepos = { mayDeploy: string[]; mergeOnly: RepoEntry[]; closed: ClosedRepo[]; waitOwners?: string[]; listWhy?: string }

/** What a repository may do tonight. */
export type Policy = { kind: 'deploy'; repo: string } | { kind: 'merge-only'; repo: string; mergeDeploys: boolean | 'unknown' } | { kind: 'closed'; repo?: string; why: string }

export const REPO_LIST_FILE = 'mods/sleep-repos.json'
const SLUG = /^[\w.-]+\/[\w.-]+$/
const OWNER = /^[\w.-]+$/
const key = (repo: string) => repo.toLowerCase()
/** The owner of `repo` when it is one of `owners`, in any case; else undefined. */
const waitingOwner = (owners: string[], repo: string): string | undefined => {
  const owner = key(repo.split('/')[0] ?? '')
  return owners.find(o => key(o) === owner)
}

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
  const waitOwners: string[] = []
  if (r.waitOwners !== undefined) {
    if (!Array.isArray(r.waitOwners)) return { why: `${REPO_LIST_FILE} has a waitOwners that is not a list` }
    for (const e of r.waitOwners) {
      if (typeof e !== 'string' || !OWNER.test(e)) return { why: `${REPO_LIST_FILE} has a waitOwners entry that is not an owner name: ${JSON.stringify(e)}` }
      waitOwners.push(e)
    }
  }
  return { lists: { mayDeploy, mergeOnly, waitOwners } }
}

/** Every repository the lists name, once each, for the bedtime check that GitHub knows them. */
export const listedRepos = (lists: RepoLists): string[] => {
  const seen = new Map<string, string>()
  for (const r of [...lists.mergeOnly.map(e => e.repo), ...lists.mayDeploy]) if (!seen.has(key(r))) seen.set(key(r), r)
  return [...seen.values()]
}

/** Whether the file decides a repository: on either list, or under an owner that waits. */
export const isListed = (lists: RepoLists, repo: string): boolean =>
  waitingOwner(lists.waitOwners, repo) !== undefined || listedRepos(lists).some(r => key(r) === key(repo))

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
    ...(read.lists.waitOwners.length ? { waitOwners: read.lists.waitOwners } : {}),
  }
}

const isNight = (n: unknown): n is NightRepos => {
  const o = n as NightRepos | null
  return (
    !!o &&
    typeof o === 'object' &&
    Array.isArray(o.mayDeploy) &&
    Array.isArray(o.mergeOnly) &&
    Array.isArray(o.closed) &&
    (o.waitOwners === undefined || (Array.isArray(o.waitOwners) && o.waitOwners.every(w => typeof w === 'string')))
  )
}

/**
 * What `repo` may do tonight, from the lists the sleep record carries. No lists (a record written
 * before this phase), a repository that could not be told, one under an owner that waits, and one
 * on neither list are all closed.
 */
export const policyOf = (night: unknown, repo: string | undefined): Policy => {
  if (!isNight(night)) return { kind: 'closed', ...(repo ? { repo } : {}), why: 'the sleep record carries no merge and deploy lists' }
  if (!repo) return { kind: 'closed', why: 'which repository this reaches could not be told' }
  if (night.listWhy) return { kind: 'closed', repo, why: night.listWhy }
  // Before either list: an owner that waits outranks any entry under it.
  const owner = waitingOwner(night.waitOwners ?? [], repo)
  if (owner) return { kind: 'closed', repo, why: `every repository owned by ${owner} waits overnight (waitOwners in ${REPO_LIST_FILE})` }
  const shut = night.closed.find(c => key(c.repo) === key(repo))
  if (shut) return { kind: 'closed', repo, why: shut.why }
  if (night.mayDeploy.some(r => key(r) === key(repo))) return { kind: 'deploy', repo }
  const m = night.mergeOnly.find(e => key(e.repo) === key(repo))
  if (m) return { kind: 'merge-only', repo, mergeDeploys: m.mergeDeploys }
  return { kind: 'closed', repo, why: `${repo} is on neither list in ${REPO_LIST_FILE}` }
}

/** One thing a command would do that this phase judges, and the repository it names, when it names one. */
export type Act = { kind: 'merge' | 'deploy' | 'push-default'; what: string; repo?: string | null }

/**
 * A package.json's scripts as the judge needs them: each script's body as the commands mod-kit's
 * reader finds in it, none (no file), or why they cannot be read.
 */
export type Scripts = Record<string, Cmd[]> | null | { unreadable: string }

/** What the judge knows about where a command runs: its default branch (or the usual names) and current branch. */
export type Where = { defaultBranch: string | null; currentBranch: string | null; scripts: Scripts }

const isFlag = (w: string) => w.startsWith('-') && w !== '-'
const name = (w: string | undefined) => (w ?? '').split('/').pop() ?? ''
// The merge helper hands its arguments to `gh pr merge`, so they are read as gh reads them, by
// mod-kit's one reader (L613, #961), asked once per command: the repository it names, undefined for
// none, null for one that cannot be read, or that no reading was given for.
const helperRepo = (c: Cmd): string | null | undefined => (!c.mergeHelper || c.mergeHelper.unreadable ? null : c.mergeHelper.named)
const MERGE_MUTATION = /^(?:mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest|mergeBranch)$/
// Mutations that write a branch directly, which can be the default branch: refused everywhere, as a push to it is.
const BRANCH_MUTATION = /^(?:createCommitOnBranch|updateRef|updateRefs|createRef|deleteRef)$/

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
  if (runsHelper(words)) out.push({ kind: 'merge', what: 'merge a PR with merge-when-ready.sh', repo: helperRepo(c) })
  if (c.git?.sub === 'push') {
    const p = pushToDefault(c.git.args, where)
    if (p) out.push({ kind: 'push-default', what: p })
  }
  if (cmd === 'gh') {
    // Read by mod-kit's one reading of gh's arguments (#834, #961), asked once per command: joined
    // and clustered flags, a PR link naming its repository, and a flag before the subcommand it
    // cannot read, which reaches a repository that cannot be told (null). A command it gave no
    // reading for cannot be read either.
    const a = c.gh ?? { sub: '', act: '', flags: [], positionals: [], named: null, unreadable: true }
    const { sub, act } = a
    const repo = a.unreadable ? null : a.named
    if (a.unreadable) out.push({ kind: 'merge', what: 'run a gh command whose flags cannot be read', repo: null })
    if (sub === 'pr' && act === 'merge') out.push({ kind: 'merge', what: `merge a PR${hasFlag(a, '--auto') ? ' (auto merge)' : ''}`, repo })
    if (sub === 'workflow' && act === 'run') out.push({ kind: 'deploy', what: 'run a workflow (gh workflow run)', repo })
    if (sub === 'api' && a.api) {
      const { method, endpoint, query: doc } = a.api
      // The repository its endpoint names as gh reaches it, else the one the command names; an
      // endpoint whose repository cannot be read is one that cannot be told (null), never the
      // command's or the checkout's (#961).
      const at = a.api.repo === undefined ? repo : a.api.repo
      if (endpoint === 'graphql') {
        const fields = doc === null ? null : operations(doc).filter(o => o.kind === 'mutation').flatMap(o => (o.spreads ? ['...'] : o.fields))
        if (fields === null) out.push({ kind: 'merge', what: 'call the GitHub API with a query that could not be read', repo: at })
        else {
          if (fields.some(f => f === '...' || MERGE_MUTATION.test(f))) out.push({ kind: 'merge', what: 'merge a PR through the GitHub API', repo: at })
          if (fields.some(f => BRANCH_MUTATION.test(f))) out.push({ kind: 'push-default', what: 'write a branch through the GitHub API, which can be the default branch', repo: at })
        }
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

/**
 * The folder each command runs in, as phase 3 (overnight.ts) and the #892 push hook follow it: the
 * session's folder, moved by each `cd` or `pushd` before it, kept apart inside a subshell, and by a
 * git command's own -C, each through phase 3's one resolver (`resolveDir`). Null where it cannot be
 * followed (a variable, a pattern, `cd -`, `popd`, or --git-dir and --work-tree, which name a
 * repository apart from any folder), which is a repository that cannot be told (L75).
 */
export const dirsOf = (commands: Cmd[], cwd: string, home: string): (string | null)[] => {
  let dir: string | null = cwd || null
  const stack: (string | null)[] = []
  const out: (string | null)[] = []
  for (const c of commands) {
    const cmd = name(c.words[0])
    if (cmd === '(') stack.push(dir)
    else if (cmd === ')') dir = stack.length ? (stack.pop() as string | null) : dir
    else if (cmd === 'cd' || cmd === 'pushd') dir = resolveDir(c.words.slice(1).find(a => !a.startsWith('-') || a === '-'), dir, home)
    else if (cmd === 'popd') dir = null
    if (cmd === 'git') {
      // git's own options, before its subcommand, as mod-kit's git reader reads them (each option
      // that takes a value, -c included, takes it): its -C moves the folder; --git-dir and
      // --work-tree name a repository apart from any folder; more than one -C is not followed.
      const globals = c.git ? c.words.slice(1, c.words.length - c.git.args.length - (c.git.sub === undefined ? 0 : 1)) : c.words.slice(1)
      let here: string | null = dir
      if (!c.git || globals.filter(w => w === '-C').length > 1 || globals.some(w => /^--(?:git-dir|work-tree)(?:=|$)/.test(w))) here = null
      else if (c.git.dir !== undefined) here = here === null ? null : resolveDir(c.git.dir, here, home)
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
      // A repository the command names but that cannot be read (null) is one that cannot be told.
      const repo = act.repo === null ? undefined : (act.repo ?? place.own)
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
