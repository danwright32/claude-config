import type { ModKitGh, ModKitWrites } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { DEPLOYERS, EDITORS, databaseRefusal, dbToolRefusal, flagOf, hasFlag, operations, type Cmd } from './nobuild.ts'

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
//   none of these three in a throwaway repository under the temp folder (#1124), below;
// - claude-sync send, sync, apply-only and install, and a pull from anywhere but the live sync clone
//   or with its environment changed. The live clone's pull is the config repository's deploy step
//   (#1106), judged against the night's lists by phase 7 (mergedeploy.ts), never here.
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

/**
 * One call as the mod reads it. `raw` is the Bash command as written; `ghRepo` the session's GH_REPO
 * as gh reads it (mod-kit's $.modkit.ghRepo, #961): absent when it is not set, null when it is set
 * but names no repository that can be read, which refuses every write that names none itself.
 */
export type OvernightCall = {
  tool: string
  input: Record<string, unknown>
  raw: string
  commands: Cmd[]
  writes: ModKitWrites
  cwd: string
  home: string
  ghRepo?: string | null
}

/** Never approved overnight, whatever else: a question for Dan and the plan approval (H8). */
export const NEVER_ASKED: ReadonlySet<string> = new Set(['AskUserQuestion', 'ExitPlanMode'])

const base = (p: string) => (p.replace(/\/+$/, '').split('/').pop() ?? '').toLowerCase()
const name = (w: string | undefined) => (w ?? '').split('/').pop() ?? ''
const isLessons = (p: string | undefined) => p !== undefined && base(p) === 'lessons.md'
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh'])

/** Reads one remote's address as its GitHub owner/name, or null: mod-kit's one reader, $.modkit.repo (#951). */
export type GithubOf = (remote: string) => Promise<string | null>

/**
 * `git remote -v`'s answer as the one GitHub repository it names, lower case; null for none or more
 * than one (a fork's upstream is where gh may send a call). Each address is read by `github`, never
 * here: a remote is read as git reads it, where owner/name alone is a local path (#951).
 */
export const repoFromRemotes = async (text: string, github: GithubOf): Promise<string | null> => {
  const found = new Set<string>()
  for (const line of text.split('\n')) {
    // `name<TAB>address (fetch)`: the address whole, spaces in a local path included.
    const url = (line.split('\t')[1] ?? '').replace(/ \((?:fetch|push)\)\s*$/, '').trim()
    if (!url) continue
    const r = await github(url)
    found.add(r === null ? `not github: ${url}` : r.toLowerCase())
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
export const resolveDir = (word: string | undefined, dir: string | null, home: string): string | null => {
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

// ---- the temp folder (#1124) ----

// A repository under the temp folder is a throwaway one a test or a check built, nobody's checkout:
// on 2026-10-13 sleep mode refused suites that build them, and an agent reworded its commands to
// get past it, which is the route around a rule that refuses on a word. So git there is judged by
// where its writes land: a branch switch, a branch delete or a force push to another temp path
// goes ahead, and the same reaching a real checkout or a remote stays refused. The temp folder is
// /tmp and macOS's per user one under /var/folders, as a path the line spells or a folder mktemp
// makes there. A symlink under it, or GIT_DIR in the session's own environment, is not followed:
// the wake check reads what really happened.
const TEMP = /^\/(?:private\/)?(?:tmp|var\/folders\/[^/]+\/[^/]+\/T)(?:\/|$)/
// Where a mktemp folder or $TMPDIR stands in a word: a folder of its own under a name at the root
// that nothing has, so that climbing out of it (`$T/../..`) leaves the temp folder, as it does on
// the disk, and anything that asks the disk about it finds nothing there. Only a folder below the
// mark is in the temp folder; the mark itself stands for the unknown folder above them all.
const MARK = '/.overnight-temp-folder'
const MARKED = /^\/\.overnight-temp-folder\/[^/]+/
export const inTemp = (p: string | null): boolean => p !== null && (TEMP.test(p) || MARKED.test(p))
// TMPDIR as the line spells it, for mktemp's template or a folder: trusted only while the line
// itself does not set it, since then it may be anywhere.
const TMPDIR_WORD = /^(?:\$TMPDIR|\$\{TMPDIR\}|\$\{TMPDIR:-\/tmp\/?\})(?:\/|$)/
const unquote = (w: string) => w.replace(/^(['"])(.*)\1$/, '$2')
// Whether a mktemp's arguments make its file or folder in the temp folder: every template and -p
// folder spelled there (or a template with no folder, which mktemp puts in TMPDIR), every flag one
// mktemp takes; anything else is not known to be there.
const MKTEMP_FLAGS = new Set(['-d', '-u', '-q', '--directory', '--dry-run', '--quiet'])
const mktempInTemp = (args: string, tmpdirTrusted: boolean): boolean => {
  const words = args.trim().split(/\s+/).filter(Boolean).map(unquote)
  // Anything the shell would expand, but TMPDIR as above, can put the template anywhere.
  const expands = (w: string) => /[$`()\\]/.test(tmpdirTrusted ? w.replace(TMPDIR_WORD, '') : w)
  const there = (w: string) => !expands(w) && !w.split('/').includes('..') && (TEMP.test(w) || (tmpdirTrusted && TMPDIR_WORD.test(w)))
  for (let i = 0; i < words.length; i++) {
    const w = words[i] as string
    if (expands(w)) return false
    if (MKTEMP_FLAGS.has(w) || /^-[duq]+$/.test(w) || w.startsWith('--suffix=')) continue
    if (w === '-t') { i++; continue }
    if (w === '-p' || w === '--tmpdir') {
      if (!there(words[++i] ?? '')) return false
      continue
    }
    if (w.startsWith('--tmpdir=')) {
      if (!there(w.slice('--tmpdir='.length))) return false
      continue
    }
    if (w.startsWith('-')) return false
    if (w.includes('/') ? !there(w) : !tmpdirTrusted) return false
  }
  return tmpdirTrusted || words.some(w => w.includes('/'))
}
const MKTEMP = /\$\(\s*mktemp\b([^)]*)\)/g
/**
 * How the words of one Bash call read a folder in the temp folder: `$(mktemp ...)` making one
 * there, a variable every assignment of which in the line is such a mktemp, and $TMPDIR while the
 * line does not set it, each put in a word as a path under MARK. A variable set any other way
 * anywhere in the line (a second assignment, a for or a read, ${T:-x}) is left as written, so the
 * folder cannot be resolved and whatever needed it is judged as before.
 */
export const tempWords = (raw: string): ((word: string) => string) => {
  const tmpdirTrusted = !/(?:^|[^\w$])TMPDIR=/.test(raw)
  const vars = new Set<string>()
  for (const m of raw.matchAll(/(?<![\w$])([A-Za-z_]\w*)=(?=["']?\$\(\s*mktemp\b)/g)) vars.add(m[1] as string)
  const fromMktemp = (at: number, name: string): boolean => {
    const rest = raw.slice(at + name.length + 1).replace(/^["']/, '')
    const m = /^\$\(\s*mktemp\b([^)]*)\)/.exec(rest)
    return m !== null && mktempInTemp(m[1] as string, tmpdirTrusted)
  }
  for (const name of [...vars]) {
    // Every place the line names it other than to expand it must be one of those assignments.
    for (const m of raw.matchAll(new RegExp(`(?<![\\w$])(?<!\\$\\{)${name}(?!\\w)`, 'g'))) {
      const at = m.index ?? 0
      if (raw[at + name.length] !== '=' || !fromMktemp(at, name)) {
        vars.delete(name)
        break
      }
    }
  }
  return (word: string) => {
    let w = word.replace(MKTEMP, (all, args: string) => (mktempInTemp(args, tmpdirTrusted) ? `${MARK}/mktemp` : all))
    if (tmpdirTrusted) w = w.replace(TMPDIR_WORD, m => (m.endsWith('/') ? `${MARK}/TMPDIR/` : `${MARK}/TMPDIR`))
    return w.replace(/\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)(?!\w)/g, (all, a?: string, b?: string) => (vars.has((a ?? b) as string) ? `${MARK}/${a ?? b}` : all))
  }
}
// git told to use another repository's git folder or work tree (a global option such as the git
// folder's, a config one, a second -C that git would add to the first, or GIT_DIR in the line) may
// run somewhere other than the folder it names with -C or a cd, so that folder being a temp one
// says nothing. Read from the words before the subcommand mod-kit's reading found, never from a
// list of git's options here: anything there but one -C and its folder counts.
const gitElsewhere = (words: readonly string[], g: NonNullable<Cmd['git']>, raw: string): boolean => {
  const globals = g.sub === undefined ? words.slice(1) : words.slice(1, words.length - g.args.length - 1)
  const plain = globals.length === 0 || (globals.length === 2 && globals[0] === '-C')
  return !plain || /(?:^|[^\w$])GIT_(?:DIR|WORK_TREE|COMMON_DIR)=/.test(raw)
}
// The repositories a push writes to, as git names them: the repository after its flags, and
// --repo. Each a temp path, as written or relative to the folder git runs in: a remote's name or a
// URL may be GitHub, and a push naming none goes to the branch's remote.
const PUSH_VALUED = new Set(['-o', '--push-option', '--receive-pack', '--exec', '--repo'])
const pushesToTemp = (args: readonly string[], where: string | null, home: string, expand: (w: string) => string): boolean => {
  const dests: string[] = []
  let positional = false
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a.startsWith('--repo=')) dests.push(a.slice('--repo='.length))
    else if (PUSH_VALUED.has(a)) {
      if (a === '--repo') dests.push(args[i + 1] ?? '')
      i++
    } else if (!a.startsWith('-') && !positional) {
      positional = true
      dests.push(a)
    }
  }
  if (!dests.length) return false
  return dests.every(d => {
    const p = expand(d.replace(/^file:\/\//, ''))
    if (!(p.startsWith('/') || p.startsWith('.'))) return false
    return inTemp(resolveDir(p, where, home))
  })
}

// Whether code that can run a process names git where a process would run it (#1124), rather than
// the word anywhere: on 2026-10-13 a python edit was refused for writing "Scanning git work" and
// "import subprocess" into a file. git runs from code when it starts a quoted string or a shell
// command inside one (`['git', ...]`, `'/usr/bin/git'`, `"cd x && git push"`, a backtick), or when
// a git subcommand or option follows it. Prose naming git with neither (a git repository, the
// .gitignore, --git-dir) runs nothing; prose that reads as a command ("then git push") still counts.
const GIT_SUBCOMMANDS: ReadonlySet<string> = new Set(['add', 'am', 'apply', 'archive', 'bisect', 'blame', 'branch', 'bundle', 'checkout', 'cherry-pick', 'clean', 'clone', 'commit', 'config', 'describe', 'diff', 'fetch', 'filter-branch', 'filter-repo', 'format-patch', 'fsck', 'gc', 'grep', 'init', 'log', 'ls-files', 'ls-remote', 'ls-tree', 'merge', 'mv', 'notes', 'pull', 'push', 'range-diff', 'rebase', 'reflog', 'remote', 'repack', 'replace', 'reset', 'restore', 'revert', 'rev-list', 'rev-parse', 'rm', 'shortlog', 'show', 'show-ref', 'sparse-checkout', 'stash', 'status', 'submodule', 'switch', 'tag', 'update-index', 'update-ref', 'worktree'])
export const runsGit = (text: string): boolean => {
  if (/(?:['"`]|;|&&|\|\||\||\$\(|\(|\n)[ \t]*(?:[\w.~/-]*\/)?git(?=[\s'"`;|&)]|$)/.test(text)) return true
  for (const m of text.matchAll(/(?<![\w.$/-])git[ \t]+(-[\w-]*|[a-z][\w-]*)/g)) {
    const next = m[1] as string
    if (next.startsWith('-') || GIT_SUBCOMMANDS.has(next)) return true
  }
  return false
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

// `temp` says how this call's words name a folder in the temp folder (tempWords), and `elsewhere`
// whether git was told to use another repository's git folder or work tree (#1124).
const gitRefusal = async (g: NonNullable<Cmd['git']>, dir: string | null, home: string, look: Look, temp: (w: string) => string, elsewhere: boolean): Promise<string | undefined> => {
  const sub = g.sub ?? ''
  const args = g.args
  if (GIT_PUTS_BACK.has(sub) && args.some(isLessons)) return 'write to LESSONS.md'
  // The folder git runs in, and whether it is a throwaway repository under the temp folder.
  const where = g.dir === undefined ? dir : resolveDir(temp(g.dir), dir, home)
  const throwaway = !elsewhere && inTemp(where)
  if (sub === 'push') {
    const why = pushRefusal(args)
    return why && (elsewhere || !pushesToTemp(args, where, home, temp)) ? why : undefined
  }
  if (sub === 'branch') {
    const short = shortFlags(args)
    return !throwaway && (args.some(a => spells(a, ['--delete'])) || short.includes('d') || short.includes('D')) ? 'delete a branch' : undefined
  }
  if (sub === 'update-ref' && args.includes('-d') && args.some(a => a.startsWith('refs/heads/'))) return throwaway ? undefined : 'delete a branch'
  if (sub === 'switch' || (sub === 'checkout' && checkoutMoves(args))) {
    if (throwaway) return undefined
    const primary = where === null ? null : await look.isPrimary(where)
    if (primary === null) return `run git ${sub} where it could not be told whether this is a primary checkout`
    return primary ? `run git ${sub} in a primary checkout` : undefined
  }
  return undefined
}

// ---- gh ----

// Every gh call is read by mod-kit's one reading of gh's arguments ($.modkit.gh, #961), once per
// command, as the command's `gh`.
// Overnight, gh is judged by two short lists, never a list of what it must not do, which would
// always be missing the next one (#834 reviews): what only reads, which goes ahead wherever it
// points, and the few writes overnight work needs, which go only to the checkout's own repository.
// Everything else gh does is refused, on any repository: being on the right repository is not
// enough for a write (repo delete, release, secret, a workflow run).
const GH_READ_ACTS = new Set(['view', 'list', 'status', 'diff', 'checks', 'watch'])
const GH_READ_SUBS = new Set(['search', 'help', 'version', 'completion', 'status'])
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
const COMMENT_ENDPOINT = /^repos\/[^/]+\/[^/]+\/(?:issues|pulls)\/\d+\/comments$/
const REPO_FLAGS = ['-R', '--repo', '--help', '-h']

// What gh is asked to do: refused outright, a write to judge by the repository it reaches, or a
// read (undefined). REST and GraphQL reach the same decision through the same outcomes. `a` is
// mod-kit's reading of the command (#961), asked once per command; with none, nothing it does or
// where it goes can be said.
type GhVerdict = { refuse: string } | { write: string | null | undefined } | undefined
const ghVerdict = (a: ModKitGh | undefined): GhVerdict => {
  if (!a) return { write: null }
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

const apiVerdict = (a: ModKitGh): GhVerdict => {
  // Another GitHub host is another place entirely, never this checkout's repository.
  const host = flagOf(a, '--hostname')
  if (host !== undefined && (typeof host !== 'string' || host.toLowerCase() !== 'github.com')) return { write: null }
  if (!a.api) return { write: null }
  const { method, endpoint, fields, query } = a.api
  const ep = (endpoint ?? '').replace(/^https:\/\/api\.github\.com\//, '').replace(/^\/+/, '').replace(/[?#].*$/, '')
  if (ep === 'graphql') {
    // A GraphQL document is always a POST: read it, and refuse one that cannot be read.
    if (query === null) return { refuse: 'call the GitHub API with a GraphQL document that could not be read' }
    for (const op of operations(query)) {
      if (op.kind !== 'mutation') continue
      if (op.spreads || !op.fields.length) return { refuse: 'call the GitHub API with a GraphQL document that could not be read' }
      if (op.fields.includes('deleteRef')) return { refuse: 'delete a branch' }
      return { refuse: `call the GitHub API to run ${op.fields.find(f => BANNED_MUTATIONS.has(f)) ?? op.fields[0]}` }
    }
    return undefined
  }
  if (method === 'GET') return undefined
  // The one API write overnight work needs: a comment on an issue or a PR of this repository, which
  // is the one its endpoint names as gh reaches it (mod-kit's reading: gh's placeholders for the
  // current repository name none, so the checkout decides; a spelling gh does not send to repos/,
  // or one placeholder beside a name, cannot be read).
  if (COMMENT_ENDPOINT.test(ep) && method === 'POST') return { write: a.api.repo }
  if (/(?:^|\/)(?:issues|labels|milestones)(?:\/|$)/.test(ep)) return { refuse: 'change issues, labels or milestones through the GitHub API' }
  if (/\/git\/refs\/heads\//.test(ep)) {
    if (method === 'DELETE') return { refuse: 'delete a branch' }
    if (fields.some(f => /^force=(?:true|1)$/i.test(f))) return { refuse: 'force push' }
  }
  return { refuse: `call the GitHub API to ${method} ${ep || 'an endpoint it does not name'}` }
}

// Whether a gh call in this command line reaches gh some way its words do not show. mod-kit's
// reader looks past the runners that change nothing about where gh goes (env, command, nohup,
// time, sudo, timeout, a shell's -c), so a gh they run is judged by its own words like any other.
// What it cannot show is refused: any GH_ variable or GitHub token set (it changes the repository,
// host, account or config gh uses), a gh that xargs feeds its operands to, and eval or source
// naming gh, which run text nobody reads. Read with mod-kit's reader only, never a quote reader of
// our own (tools/check-mod-shared-parts.sh); the variable check reads the line as written, so a
// quoted message that spells an assignment is refused too, which fails closed.
const wrapped = (call: OvernightCall): boolean => {
  // Anywhere in the line, quotes included, so `env -S 'GH_REPO=x gh ...'` is seen too.
  if (/\b(?:GH_\w+|GITHUB_TOKEN|GITHUB_ENTERPRISE_TOKEN)=/.test(call.raw)) return true
  if (call.commands.some(c => name(c.words[0]) === 'gh' && c.xargs)) return true
  // A file sourced in the same line can set any of those without the line showing it, and so can
  // a string env -S splits into a command.
  if (call.commands.some(c => ['source', '.'].includes(name(c.words[0])))) return true
  if (/(?:^|[\s;&|(])env\s+(?:\S+\s+)*?(?:-S|--split-string)\b/.test(call.raw)) return true
  return call.commands.some(c => ['eval', 'source', '.'].includes(name(c.words[0])) && c.words.slice(1).some(w => /\bgh\b/.test(w)))
}

const UNRESOLVED = 'write to GitHub where the repository it reaches could not be resolved'
// A GitHub write goes only to the repository the checkout it runs in is. `target` is the one the
// call names (undefined: none, so gh takes GH_REPO, else the checkout's; null: none can be said).
const writeRefusal = async (target: string | null | undefined, dir: string | null, call: OvernightCall, look: Look): Promise<string | undefined> => {
  // GH_REPO set inline in the command reaches gh past every word the reader gives.
  if (wrapped(call)) return UNRESOLVED
  if (target === null) return UNRESOLVED
  const here = dir === null ? null : await look.repoOf(dir)
  const to = target === undefined ? (call.ghRepo !== undefined ? call.ghRepo : here) : target
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

// Whether the word after a gh named as an argument makes it a gh call: a gh subcommand, or a flag
// (`-R o/r`), as a wrapper passes it on. A search term or a path (`grep gh README.md`, `ls gh`)
// runs nothing. A user's own gh alias in that place is not seen; the wake check is the backstop.
const GH_SUBCOMMANDS: ReadonlySet<string> = new Set(['alias', 'api', 'attestation', 'auth', 'browse', 'cache', 'co', 'codespace', 'completion', 'config', 'extension', 'gist', 'gpg-key', 'issue', 'label', 'org', 'pr', 'project', 'release', 'repo', 'ruleset', 'run', 'search', 'secret', 'ssh-key', 'status', 'variable', 'workflow'])
const runsGh = (next: string | undefined): boolean => next !== undefined && (next.startsWith('-') || GH_SUBCOMMANDS.has(next))
// The commands that name a program without running it: printing its name, or finding where it is.
const NAMES_ONLY: ReadonlySet<string> = new Set(['echo', 'printf', 'which', 'type', 'whereis', 'man', 'brew'])

// ---- claude-sync ----

/**
 * The claude-sync a command runs, by its own name or as a shell's script: the script as written
 * and its subcommand; undefined when it runs none. Shared with phase 7 (mergedeploy.ts), which
 * judges the pull as a deploy of the repository the clone it runs from is (#1106). A shell's own
 * options before its script (`bash -x`, `zsh -o pipefail`, `--`) are read past, an option known to
 * take a value with its value. A claude-sync the shell names anywhere else (after an option this
 * does not know, which may take a value, or a script of its own) is `unread`: where it runs, and
 * whether it runs at all, cannot be said, so phase 3 refuses it whatever its subcommand.
 */
export const syncCall = (words: readonly string[]): { script: string; sub: string | undefined; unread?: true } | undefined => {
  if (name(words[0]) === 'claude-sync') return { script: words[0] as string, sub: words[1] }
  if (!SHELLS.has(name(words[0]))) return undefined
  let i = 1
  while (i < words.length && /^[-+]/.test(words[i] as string)) {
    const w = words[i] as string
    i += SHELL_VALUED.has(w) ? 2 : 1
    if (w === '--') break
  }
  if (name(words[i]) === 'claude-sync') return { script: words[i] as string, sub: words[i + 1] }
  const j = words.findIndex((w, k) => k > 0 && name(w) === 'claude-sync')
  return j < 0 ? undefined : { script: words[j] as string, sub: words[j + 1], unread: true }
}
// A shell's options that take the next word as their value: bash's and zsh's set options by name,
// bash's startup file, zsh's emulation.
const SHELL_VALUED: ReadonlySet<string> = new Set(['-o', '+o', '-O', '+O', '--rcfile', '--init-file', '--emulate'])
// Every claude-sync write but a pull: each changes the shared repository or this Mac's schedule.
const SYNC_REFUSED = (sub: string | undefined) => sub !== undefined && (sub === 'sync' || sub === 'send' || sub === 'apply-only' || sub.startsWith('install'))
// The environment a pull runs with, changed where the words do not show it: an assignment (the
// reader takes it off the words, and claude-sync reads SYNC_REPO and CLAUDE_HOME among others), env
// with a flag, sudo, or a file sourced in the line. Read on the line as written, quotes included,
// which fails closed.
const ENV_CHANGED = /(?:^|[\s;&|(`])(?:[A-Za-z_]\w*=|env\s+-|sudo\b)/
/**
 * Why a claude-sync pull is refused overnight, or undefined for the live sync clone's own, which is
 * the config repository's deploy step and left to phase 7 (#1106). Any other copy installs whatever
 * it holds (a development checkout's feature branch), and a bare name is whichever copy PATH finds.
 */
const pullRefusal = (script: string, dir: string | null, call: OvernightCall): string | undefined => {
  if (ENV_CHANGED.test(call.raw) || call.commands.some(c => ['source', '.'].includes(name(c.words[0]))))
    return 'run claude-sync pull with its environment changed, so what it installs cannot be told'
  const at = script.includes('/') ? resolveDir(script, dir, call.home) : null
  return at === `${call.home}/claude-config-sync/claude-sync` ? undefined : 'run claude-sync pull from a copy other than the live sync clone, ~/claude-config-sync'
}

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
  // A Bash call whose command cannot be read is refused, never approved as an empty one.
  if (!call.raw.trim()) return 'run a Bash call with no command'

  // LESSONS.md by what the call changes on the disk, as mod-kit's write reader finds it.
  const w = call.writes
  if (w.files.some(f => isLessons(f.path ?? f.word)) || w.changes.some(c => isLessons(c.path ?? c.word))) return 'write to LESSONS.md'
  if (w.unnamed.some(u => [...u.words, ...u.inputs, ...(u.targets ?? []), ...(u.into ? [u.into] : [])].some(isLessons))) return 'write to LESSONS.md'

  // Each command in order, in the folder it runs in: a cd moves it, a subshell keeps its own.
  // gh run where this reader reads no gh command at all (eval, a string it cannot open): neither
  // the call nor where it goes can be read, so it is refused (#834 review).
  if (!call.commands.some(c => name(c.words[0]) === 'gh') && wrapped(call) && /\bgh\b/.test(call.raw)) return UNRESOLVED
  let dir: string | null = call.cwd
  const stack: (string | null)[] = []
  const temp = tempWords(call.raw)
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
      const to = words.slice(1).find(a => !a.startsWith('-') || a === '-')
      dir = resolveDir(to === undefined ? to : temp(to), dir, call.home)
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
    if (c.verdict?.does === 'run a process' && c.program && 'text' in c.program && (/\b(?:gh|psql|mysql|mariadb|supabase|claude-sync)\b/.test(c.program.text) || runsGit(c.program.text)))
      return 'run code that runs gh, git or a database client, which cannot be judged'
    // gh as a word of any other command, outside quotes: a wrapper the reader does not look past
    // (setsid, stdbuf, chronic, one nobody has written yet) runs it, so it is refused whatever the
    // wrapper is called (#834 review of 46f07ff). Only the commands that name a program without
    // running it are let through; a command missing from that list fails closed.
    if (cmd !== 'gh' && !NAMES_ONLY.has(cmd) && !(cmd === 'command' && /^-[vV]$/.test(words[1] ?? '')) && words.slice(1).some((w, i) => (w === 'gh' || w.endsWith('/bin/gh')) && runsGh(words[i + 2]))) return UNRESOLVED
    if (c.git) {
      const why = await gitRefusal(c.git, dir, call.home, look, temp, gitElsewhere(c.words, c.git, call.raw))
      if (why) return why
      continue
    }
    if (cmd === 'gh') {
      const v = ghVerdict(c.gh)
      if (v && 'refuse' in v) return v.refuse
      if (v && 'write' in v) {
        const why = await writeRefusal(v.write, dir, call, look)
        if (why) return why
      }
      continue
    }
    const sync = syncCall(words)
    if (sync?.unread) return 'run claude-sync through a shell whose options or script could not be read'
    if (sync?.sub === 'pull') {
      const why = pullRefusal(sync.script, dir, call)
      if (why) return why
    } else if (sync && SYNC_REFUSED(sync.sub)) return `run claude-sync ${sync.sub}`
    if (cmd === 'supabase' && DEPLOYERS.supabase?.(words.slice(1))) return 'change a database with supabase'
    // The one list of database clients no build reads too (L370), sqlite3 included.
    const sql = databaseRefusal({ ...c, words })
    if (sql) return sql.what
  }
  return undefined
}
