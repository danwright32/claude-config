import type { ModKitWrites } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { flagOf, ghApi, ghArgs, hasFlag, normRepo, type GhArgs } from './ghargs.ts'
import { DEPLOYERS, EDITORS, databaseRefusal, dbToolRefusal, operations, type Cmd } from './nobuild.ts'

// Sleep mode phase 3 (#834): what is refused while the Mac sleeps, judged by what a call DOES and
// by the repository it reaches, never by a phrase anywhere in it (L673). Dan's decision, 2026-10-06
// (plan-lite picker): "Everything not banned". Claude Code's own permission prompts are approved
// overnight in the enrolled sessions unless the call is on this list, and the list is refused
// outright in every session while asleep, whatever the classifier would say. The lessons audit
// recommended an allow list instead (L42, L615); Dan chose the ban list knowing an action it does
// not name is approved. So the list here is the plan's, item for item:
//
// - issue, label and milestone writes by gh or gh api; any other GitHub write (a comment, which
//   decision 3 needs on the issue being worked, a review, a close) only on the repository the
//   checkout is, everything gh does but a short list of known reads counting as a write, and one
//   whose repository cannot be resolved is refused (L75);
// - LESSONS.md written by any route in command position;
// - every write tool under mcp__claude_ai_*, mcp__claude-in-chrome__* and mcp__posthog__*, and
//   Supabase and psql writes;
// - git checkout or switch in a primary checkout (H7);
// - force pushes and branch deletes;
// - claude-sync pull and install.
//
// Pure but for the two questions only the disk can answer, asked through `Look`; an answer it
// cannot give is null, which refuses. A text match always has a way around it, so the wake check
// (wakecheck.ts) reads what really happened overnight.

/** The questions only the disk can answer. Null when it cannot be said, which refuses. */
export type Look = {
  /** The one GitHub repository a folder's remotes name, as owner/name in lower case. */
  repoOf: (dir: string) => Promise<string | null>
  /** Whether a folder is in a primary checkout (true) or a linked worktree (false). */
  isPrimary: (dir: string) => Promise<boolean | null>
}

/** One call as the mod reads it. `raw` is the Bash command as written; `ghRepo` the session's GH_REPO. */
export type OvernightCall = {
  tool: string
  input: Record<string, unknown>
  raw: string
  commands: Cmd[]
  writes: ModKitWrites
  cwd: string
  home: string
  ghRepo?: string
}

/** Never approved overnight, whatever else: a question for Dan and the plan approval (H8). */
export const NEVER_ASKED: ReadonlySet<string> = new Set(['AskUserQuestion', 'ExitPlanMode'])

const base = (p: string) => (p.replace(/\/+$/, '').split('/').pop() ?? '').toLowerCase()
const name = (w: string | undefined) => (w ?? '').split('/').pop() ?? ''
const isLessons = (p: string | undefined) => p !== undefined && base(p) === 'lessons.md'
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh'])

export { normRepo }

/** `git remote -v`'s answer as the one GitHub repository it names; null for none or more than one (a fork's upstream is where gh may send a call). */
export const repoFromRemotes = (text: string): string | null => {
  const found = new Set<string>()
  for (const line of text.split('\n')) {
    const url = line.split(/\s+/)[1]
    if (!url) continue
    const r = normRepo(url)
    found.add(r ?? `not github: ${url}`)
  }
  return found.size === 1 ? ([...found][0] as string).startsWith('not github') ? null : ([...found][0] as string) : null
}

/** `git rev-parse --path-format=absolute --git-dir --git-common-dir`'s answer: a primary checkout's two are the same. */
export const primaryFrom = (stdout: string): boolean | null => {
  const [dir, common] = stdout.trim().split('\n').map(l => l.trim())
  if (!dir || !common) return null
  return dir === common
}

// A folder a cd names, resolved against the one before it; null when the shell would decide it
// (a variable, a glob, `cd -`), so whatever needs it is refused.
const resolve = (word: string | undefined, dir: string | null, home: string): string | null => {
  if (word === undefined) return home
  if (word === '-' || /[$`*?[\]{}]/.test(word)) return null
  let p = word === '~' ? home : word.startsWith('~/') ? `${home}${word.slice(1)}` : word
  if (!p.startsWith('/')) {
    if (dir === null) return null
    p = `${dir}/${p}`
  }
  const out: string[] = []
  for (const s of p.split('/')) {
    if (!s || s === '.') continue
    if (s === '..') out.pop()
    else out.push(s)
  }
  return `/${out.join('/')}`
}

// ---- git ----

const shortFlags = (args: readonly string[]) => args.filter(a => /^-[A-Za-z]+$/.test(a)).join('')
// git takes any unambiguous prefix of a long option (`--forc` is --force), so a long flag counts as
// one of these when it could be read as it: the whole name, or a prefix of four characters or more.
const spells = (arg: string, options: readonly string[]): boolean => {
  if (!arg.startsWith('--')) return false
  const name = arg.split('=')[0] as string
  return options.some(o => o === name || (name.length >= 4 && o.startsWith(name)))
}
const FORCES = ['--force', '--force-with-lease', '--force-if-includes', '--mirror']
const DELETES = ['--delete', '--prune']
const pushRefusal = (args: readonly string[]): string | undefined => {
  const short = shortFlags(args)
  if (args.some(a => spells(a, FORCES)) || short.includes('f')) return 'force push'
  if (args.some(a => spells(a, DELETES)) || short.includes('d')) return 'delete a branch'
  for (const a of args) {
    if (a.startsWith('-')) continue
    // A plus leading either side of a refspec forces it, as git reads one, or fails closed where it does not.
    if (a.split(':').some(side => side.startsWith('+'))) return 'force push'
    if (a.startsWith(':')) return 'delete a branch'
  }
  return undefined
}
// A checkout that moves the whole tree: anything but putting named files back after `--`.
const checkoutMoves = (args: readonly string[]): boolean => {
  const dd = args.indexOf('--')
  if (dd < 0) return true
  const paths = args.slice(dd + 1)
  return paths.length === 0 || paths.some(p => p === '.' || p === ':/' || p.endsWith('/'))
}
const GIT_PUTS_BACK = new Set(['checkout', 'restore', 'rm', 'mv', 'apply', 'am'])

const gitRefusal = async (g: NonNullable<Cmd['git']>, dir: string | null, home: string, look: Look): Promise<string | undefined> => {
  const sub = g.sub ?? ''
  const args = g.args
  if (GIT_PUTS_BACK.has(sub) && args.some(isLessons)) return 'write to LESSONS.md'
  if (sub === 'push') return pushRefusal(args)
  if (sub === 'branch') {
    const short = shortFlags(args)
    return args.some(a => spells(a, ['--delete'])) || short.includes('d') || short.includes('D') ? 'delete a branch' : undefined
  }
  if (sub === 'update-ref' && args.includes('-d') && args.some(a => a.startsWith('refs/heads/'))) return 'delete a branch'
  if (sub === 'switch' || (sub === 'checkout' && checkoutMoves(args))) {
    const where = g.dir === undefined ? dir : resolve(g.dir, dir, home)
    const primary = where === null ? null : await look.isPrimary(where)
    if (primary === null) return `run git ${sub} where it could not be told whether this is a primary checkout`
    return primary ? `run git ${sub} in a primary checkout` : undefined
  }
  return undefined
}

// ---- gh ----

// Every gh call is read by ghargs.ts, the one reading of gh's arguments here.
// Overnight, gh is judged by two short lists, never a list of what it must not do, which would
// always be missing the next one (#834 reviews): what only reads, which goes ahead wherever it
// points, and the few writes overnight work needs, which go only to the checkout's own repository.
// Everything else gh does is refused, on any repository: being on the right repository is not
// enough for a write (repo delete, release, secret, a workflow run).
const GH_READ_ACTS = new Set(['view', 'list', 'status', 'diff', 'checks', 'watch'])
const GH_READ_SUBS = new Set(['search', 'help', 'version', 'completion'])
// The writes overnight work needs, each a subcommand and action and the only flags it may carry
// beyond -R or --repo: a comment on the issue being worked (decision 3), opening, readying and
// merging its PR (phase 7 judges merges further), and changing that PR's title or body. Nothing is
// filed overnight, so no issue is created, and no merge skips its checks (--admin); one left to
// land once its checks pass (--auto) still waits on them.
const BODY = ['-t', '--title', '-b', '--body', '-F', '--body-file']
const GH_WRITES: Record<string, string[]> = {
  'issue comment': ['-b', '--body', '-F', '--body-file'],
  'pr comment': ['-b', '--body', '-F', '--body-file'],
  'pr create': [...BODY, '-B', '--base', '-H', '--head', '-d', '--draft', '-f', '--fill', '--fill-first', '--fill-verbose'],
  'pr edit': BODY,
  'pr ready': [],
  'pr merge': ['-s', '--squash', '-m', '--merge', '-r', '--rebase', '-t', '--subject', '-b', '--body', '-F', '--body-file', '--match-head-commit', '--auto'],
}
// GraphQL mutations that are issue, label and milestone writes, named in the refusal as such; every
// mutation is refused overnight, each by its exact name.
const BANNED_MUTATIONS = new Set(['createIssue', 'updateIssue', 'closeIssue', 'reopenIssue', 'deleteIssue', 'transferIssue', 'pinIssue', 'unpinIssue', 'createLinkedBranch', 'addSubIssue', 'removeSubIssue', 'reprioritizeSubIssue', 'updateIssueComment', 'deleteIssueComment', 'addLabelsToLabelable', 'removeLabelsFromLabelable', 'clearLabelsFromLabelable', 'createLabel', 'updateLabel', 'deleteLabel'])
const LABELS_ON_PR: Record<string, string[]> = {
  edit: ['--add-label', '--remove-label', '--milestone', '-m', '--remove-milestone'],
  create: ['--label', '-l', '--milestone', '-m'],
}
const COMMENT_ENDPOINT = /^repos\/([^/]+)\/([^/]+)\/(?:issues|pulls)\/\d+\/comments$/
const PLACEHOLDER = /^(?:\{owner\}|:owner|\{repo\}|:repo)$/
const REPO_FLAGS = ['-R', '--repo', '--help', '-h']

// What gh is asked to do: refused outright, a write to judge by the repository it reaches, or a
// read (undefined). REST and GraphQL reach the same decision through the same outcomes.
type GhVerdict = { refuse: string } | { write: string | null | undefined } | undefined
const ghVerdict = (words: readonly string[]): GhVerdict => {
  const a = ghArgs(words)
  const { sub, act } = a
  // An unknown flag before the subcommand, or between it and its action: what the call does cannot
  // be read, so it reaches a repository that cannot be resolved.
  if (a.unreadable) return { write: null }
  if (sub === 'api') return apiVerdict(a)
  // gh with no subcommand only prints its help or version.
  if (GH_READ_SUBS.has(sub) || GH_READ_ACTS.has(act) || !sub) return undefined
  // Changing or removing a comment is not posting one (decision 3 needs only that).
  if (act === 'comment' && hasFlag(a, '--delete-last', '--edit-last')) return { refuse: 'edit or delete a comment' }
  if (sub === 'pr') {
    const labels = LABELS_ON_PR[act]
    if (labels && hasFlag(a, ...labels)) return { refuse: 'set labels or a milestone on a PR' }
    if ((act === 'merge' || act === 'close') && hasFlag(a, '-d', '--delete-branch')) return { refuse: 'delete a branch' }
  }
  const key = `${sub} ${act}`
  if (!Object.prototype.hasOwnProperty.call(GH_WRITES, key)) return { refuse: `run gh ${key}`.trim() }
  const allowed = GH_WRITES[key] as string[]
  const other = a.flags.find(f => !allowed.includes(f.name) && !REPO_FLAGS.includes(f.name))
  if (other) return { refuse: `run gh ${key} with ${other.name}` }
  return { write: a.named }
}

const apiVerdict = (a: GhArgs): GhVerdict => {
  // Another GitHub host is another place entirely, never this checkout's repository.
  const host = flagOf(a, '--hostname')
  if (host !== undefined && (typeof host !== 'string' || host.toLowerCase() !== 'github.com')) return { write: null }
  const { method, endpoint, fields, input } = ghApi(a)
  const ep = (endpoint ?? '').replace(/^https:\/\/api\.github\.com\//, '').replace(/^\/+/, '').replace(/[?#].*$/, '')
  if (ep === 'graphql') {
    // A GraphQL document is always a POST: read it, and refuse one that cannot be read.
    const q = a.flags.filter(f => ['-f', '-F', '--field', '--raw-field'].includes(f.name) && typeof f.value === 'string' && f.value.startsWith('query=')).pop()
    const query = q ? (q.value as string).slice('query='.length) : undefined
    const fromFile = input || (q !== undefined && (q.name === '-F' || q.name === '--field') && (query ?? '').startsWith('@'))
    if (fromFile || query === undefined) return { refuse: 'call the GitHub API with a GraphQL document that could not be read' }
    for (const op of operations(query)) {
      if (op.kind !== 'mutation') continue
      if (op.spreads || !op.fields.length) return { refuse: 'call the GitHub API with a GraphQL document that could not be read' }
      if (op.fields.includes('deleteRef')) return { refuse: 'delete a branch' }
      return { refuse: `call the GitHub API to run ${op.fields.find(f => BANNED_MUTATIONS.has(f)) ?? op.fields[0]}` }
    }
    return undefined
  }
  if (method === 'GET') return undefined
  // The one API write overnight work needs: a comment on an issue or a PR of this repository.
  const c = COMMENT_ENDPOINT.exec(ep)
  if (c && method === 'POST') return { write: PLACEHOLDER.test(c[1] as string) || PLACEHOLDER.test(c[2] as string) ? undefined : normRepo(`${c[1]}/${c[2]}`) }
  if (/(?:^|\/)(?:issues|labels|milestones)(?:\/|$)/.test(ep)) return { refuse: 'change issues, labels or milestones through the GitHub API' }
  if (/\/git\/refs\/heads\//.test(ep)) {
    if (method === 'DELETE') return { refuse: 'delete a branch' }
    if (fields.some(f => /^force=(?:true|1)$/i.test(f))) return { refuse: 'force push' }
  }
  return { refuse: `call the GitHub API to ${method} ${ep || 'an endpoint it does not name'}` }
}

// Whether a gh call in this command line reaches gh some way other than the words this reader
// gives: a GH_ variable set anywhere (it changes the repository, host or account), or gh run
// through a wrapper (env, command, nohup, xargs, a shell's -c, eval, time, sudo and the like), seen
// as more gh commands read than stand in command position in the line itself (#834 review).
// Only text in command position is judged: what quotes hold (a --body) and a heredoc's body are
// blanked first, so a comment that mentions `env gh` is still a comment. A gh a shell's -c runs
// sits inside quotes, so it is blanked here too, and is caught by the count below instead.
// gh in command position: after a separator, any shell keywords that lead a command (if, then,
// do, else, elif, while, until, !) and any assignments (a GH_ one is refused above), as the shell
// and mod-kit's reader both place it (#834 review of 98a40f1).
const GH_DIRECT = /(?:^|[;&|(){}\n])(?:\s*(?:if|then|do|else|elif|while|until|!)(?=\s))*\s*(?:[A-Za-z_]\w*=\S*\s+)*gh(?=\s|$)/g
const GH_WRAPPED = /(?:^|[\s;&|(])(?:env|command(?!\s+-[vV]\b)|nohup|xargs|time|sudo|exec|nice|timeout|caffeinate)\s(?:[^;&|\n]*\s)?gh(?=\s|$)/
const unquoted = (raw: string): string => {
  const body = raw.replace(/(<<-?\s*(['"]?)(\w+)\2[^\n]*\n)[\s\S]*?\n\s*\3[ \t]*(?=\n|$)/g, '$1')
  let out = ''
  let q: string | null = null
  for (let i = 0; i < body.length; i++) {
    const ch = body[i] as string
    if (q) {
      if (q === '"' && ch === '\\') i++
      else if (ch === q) {
        q = null
        out += ch
      }
      continue
    }
    if (ch === '\\') {
      out += ' '
      i++
      continue
    }
    if (ch === '"' || ch === "'") q = ch
    out += ch
  }
  return out
}
const wrapped = (call: OvernightCall): boolean => {
  const bare = unquoted(call.raw)
  // Any GH_ variable set changes what gh does (its repository, host, account or config), as do
  // gh's own config and token variables under other names.
  if (/\b(?:GH_\w+|GITHUB_TOKEN|GITHUB_ENTERPRISE_TOKEN)=/.test(bare)) return true
  if (GH_WRAPPED.test(bare)) return true
  // eval and source run text the reader does not open; one that names gh anywhere is a gh call
  // nobody can read.
  if (call.commands.some(c => ['eval', 'source', '.'].includes(name(c.words[0])) && c.words.slice(1).some(w => /\bgh\b/.test(w)))) return true
  const read = call.commands.filter(c => name(c.words[0]) === 'gh').length
  return read > (bare.match(GH_DIRECT) ?? []).length
}

const UNRESOLVED ='write to GitHub where the repository it reaches could not be resolved'
// A GitHub write goes only to the repository the checkout it runs in is. `target` is the one the
// call names (undefined: none, so gh takes GH_REPO, else the checkout's; null: none can be said).
const writeRefusal = async (target: string | null | undefined, dir: string | null, call: OvernightCall, look: Look): Promise<string | undefined> => {
  // GH_REPO set inline in the command reaches gh past every word the reader gives.
  if (wrapped(call)) return UNRESOLVED
  if (target === null) return UNRESOLVED
  const here = dir === null ? null : await look.repoOf(dir)
  const to = target === undefined ? (call.ghRepo ? normRepo(call.ghRepo) : here) : target
  if (!to || !here) return UNRESOLVED
  return to === here ? undefined : `write to ${to} from a checkout of ${here}`
}

// ---- MCP tools ----

const LISTED = ['mcp__claude_ai_', 'mcp__claude-in-chrome__', 'mcp__posthog__']
const READS = new Set(['get', 'list', 'search', 'read', 'fetch', 'find', 'lookup', 'query', 'view', 'describe'])
const WRITES = new Set(['create', 'update', 'delete', 'remove', 'send', 'post', 'add', 'set', 'edit', 'write', 'upload', 'apply', 'deploy', 'merge', 'reset', 'rebase', 'restore', 'pause', 'save', 'schedule', 'respond', 'complete', 'propose', 'start', 'execute', 'exec', 'run', 'insert', 'publish', 'batch', 'move', 'cancel', 'clear', 'submit', 'upsert', 'patch', 'put', 'invite', 'archive', 'enable', 'disable', 'authenticate', 'navigate', 'click', 'type', 'press', 'fill', 'select', 'drag', 'drop', 'close', 'install', 'register', 'assign', 'share', 'approve', 'reject'])
// A listed server's tool reads only when its own name says it reads and nothing in it says it writes.
const mcpWrites = (tool: string): boolean => {
  const own = tool.slice(tool.lastIndexOf('__') + 2)
  const words = own.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean)
  return !words.some(w => READS.has(w)) || words.some(w => WRITES.has(w))
}

// The commands that name a program without running it: printing its name, or finding where it is.
const NAMES_ONLY: ReadonlySet<string> = new Set(['echo', 'printf', 'which', 'type', 'whereis', 'man', 'brew'])
const SYNC_REFUSED = (sub: string | undefined) => sub !== undefined && (sub === 'pull' || sub === 'sync' || sub === 'apply-only' || sub.startsWith('install'))

/**
 * What the call would have done, when it is on the overnight list ("run gh issue create", "force
 * push"), or undefined when it is not. A question only the disk can answer that comes back null
 * refuses the call.
 */
export const overnightRefusal = async (call: OvernightCall, look: Look): Promise<string | undefined> => {
  const { tool, input } = call
  if (EDITORS.has(tool)) return isLessons(String(input.file_path ?? input.notebook_path ?? '')) ? 'write to LESSONS.md' : undefined
  const db = dbToolRefusal(tool, input)
  if (db && db !== 'reads') return db.what
  if (db === 'reads') return undefined
  if (LISTED.some(p => tool.startsWith(p))) return mcpWrites(tool) ? `use ${tool}` : undefined
  if (tool !== 'Bash') return undefined

  // LESSONS.md by what the call changes on the disk, as mod-kit's write reader finds it.
  const w = call.writes
  if (w.files.some(f => isLessons(f.path ?? f.word)) || w.changes.some(c => isLessons(c.path ?? c.word))) return 'write to LESSONS.md'
  if (w.unnamed.some(u => [...u.words, ...u.inputs, ...(u.targets ?? []), ...(u.into ? [u.into] : [])].some(isLessons))) return 'write to LESSONS.md'

  // Each command in order, in the folder it runs in: a cd moves it, a subshell keeps its own.
  // gh run where this reader reads no gh command at all (eval, a string it cannot open): neither
  // the call nor where it goes can be read, so it is refused (#834 review).
  if (!call.commands.some(c => name(c.words[0]) === 'gh') && wrapped(call) && /\bgh\b/.test(call.raw)) return UNRESOLVED
  // The words that stand outside quotes and heredocs, so gh named in a message is never a gh call.
  const unquotedWords = new Set(unquoted(call.raw).split(/[\s;&|(){}<>]+/).filter(Boolean))
  let dir: string | null = call.cwd
  const stack: (string | null)[] = []
  for (const c of call.commands) {
    let words = c.words
    while (['npx', 'bunx'].includes(name(words[0]))) words = words.slice(1).filter((x, i) => i > 0 || !x.startsWith('-'))
    const cmd = name(words[0])
    if (cmd === '(') {
      stack.push(dir)
      continue
    }
    if (cmd === ')') {
      dir = stack.length ? (stack.pop() as string | null) : dir
      continue
    }
    if (cmd === 'cd' || cmd === 'pushd') {
      dir = resolve(words.slice(1).find(a => !a.startsWith('-') || a === '-'), dir, call.home)
      continue
    }
    if (cmd === 'popd') {
      dir = null
      continue
    }
    if (c.program && 'text' in c.program && c.verdict && /lessons\.md/i.test(c.program.text)) return 'write to LESSONS.md'
    // Code whose effects the reader cannot see fails closed (#834 review of 46f07ff): a program it
    // cannot read at all, and one that runs a process naming gh, git, a database client or
    // claude-sync, which would reach what the list bans past every rule above.
    if (c.program && 'unreadable' in c.program) return 'run code this reader cannot read'
    if (c.verdict?.does === 'unreadable') return 'run code this reader cannot read'
    if (c.verdict?.does === 'run a process' && c.program && 'text' in c.program && /\b(?:gh|git|psql|mysql|mariadb|supabase|claude-sync)\b/.test(c.program.text))
      return 'run code that runs gh, git or a database client, which cannot be judged'
    // gh as a word of any other command, outside quotes: a wrapper the reader does not look past
    // (setsid, stdbuf, chronic, one nobody has written yet) runs it, so it is refused whatever the
    // wrapper is called (#834 review of 46f07ff). Only the commands that name a program without
    // running it are let through; a command missing from that list fails closed.
    if (cmd !== 'gh' && !NAMES_ONLY.has(cmd) && !(cmd === 'command' && /^-[vV]$/.test(words[1] ?? '')) && words.slice(1).some(w => (w === 'gh' || w.endsWith('/bin/gh')) && unquotedWords.has(w))) return UNRESOLVED
    if (c.git) {
      const why = await gitRefusal(c.git, dir, call.home, look)
      if (why) return why
      continue
    }
    if (cmd === 'gh') {
      const v = ghVerdict(words)
      if (v && 'refuse' in v) return v.refuse
      if (v && 'write' in v) {
        const why = await writeRefusal(v.write, dir, call, look)
        if (why) return why
      }
      continue
    }
    const syncSub = cmd === 'claude-sync' ? words[1] : SHELLS.has(cmd) && name(words[1]) === 'claude-sync' ? words[2] : undefined
    if (SYNC_REFUSED(syncSub)) return `run claude-sync ${syncSub}`
    if (cmd === 'supabase' && DEPLOYERS.supabase?.(words.slice(1))) return 'change a database with supabase'
    // The one list of database clients no build reads too (L370), sqlite3 included.
    const sql = databaseRefusal({ ...c, words })
    if (sql) return sql.what
  }
  return undefined
}
