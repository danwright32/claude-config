import type { ModKitCommand, ModKitWrites } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { clientRefusal, sqlRefusal } from './sql.ts'

// No build (#616): what Claude may and may not do while it is on, as the spec agreed with Dan.
// Allowed: reading, research, tests and checks, read only queries, scratchpad notes, and all GitHub
// issue, milestone and label work. Refused: code edits outside the scratchpad, commits, branches,
// PRs, deploys and data changing SQL, including the routes around the refusal (shell redirects,
// heredocs, sed -i). Pure: the shell is read by mod-kit's one reader and handed in, each command
// with the program it runs and what that program can do, and the files the call changes from
// mod-kit's one write reader (#712), so this keeps no reader of its own (L613).
//
// It is a guard against the usual routes Claude takes, not a sealed box (Dan, 2026-10-04, #730):
// what it reads is what Claude reaches for, and a determined route around it (a script that writes
// what no word names) is not what it is for.

/** One simple command, as `$.modkit.pipeline` gives it, with `$.modkit.git`'s reading when it is git. */
export type Cmd = ModKitCommand & { git?: { sub?: string; args: string[] } }
/** What the refused call would have done, and, where there is one, how what no build allows can still be done. */
export type Refusal = { what: string; hint?: string }

// The session scratchpad Claude Code hands every session: /tmp/claude-<uid>/<project>/<session>/scratchpad.
const SCRATCH = /^(?:\/private)?\/tmp\/claude-\d+\/[^/]+\/[^/]+\/scratchpad(?:\/|$)/
export const inScratch = (p: string): boolean => !p.split('/').includes('..') && SCRATCH.test(p)
// Claude's own notes outside the project, which Claude Code itself directs it to write: the
// project's memory files and plan mode's plans, under the home folder's .claude (#702: the spec
// refuses code edits, and a memory note is none).
const NOTES = /^\/(?:Users|home)\/[^/]+\/\.claude\/(?:projects\/[^/]+\/memory|plans)\/[^/]/
const inNotes = (p: string): boolean => inScratch(p) || (!p.split('/').includes('..') && NOTES.test(p))

const base = (p: string) => p.replace(/\/+$/, '').split('/').pop() || p
const isFlag = (w: string) => w.startsWith('-') && w !== '-'
const name = (w: string | undefined) => (w ?? '').split('/').pop() ?? ''

// Where a redirect may point and change nothing: the null device, the terminal, another descriptor.
const SINKS = new Set(['/dev/null', '/dev/stdout', '/dev/stderr', '/dev/tty'])
const harmless = (target: string) => SINKS.has(target) || /^&?\d*-?$/.test(target) || inNotes(target)

const GIT_WRITES = new Set(['add', 'am', 'apply', 'checkout', 'cherry-pick', 'clean', 'clone', 'commit', 'filter-branch', 'init', 'merge', 'mv', 'notes', 'pull', 'push', 'rebase', 'replace', 'reset', 'restore', 'revert', 'rm', 'switch', 'update-ref'])
const BRANCH_WRITE_FLAGS = new Set(['-d', '-D', '-m', '-M', '-c', '-C', '-f', '-u', '--delete', '--move', '--copy', '--force', '--set-upstream-to', '--unset-upstream', '--edit-description'])
const BRANCH_LIST_FLAGS = new Set(['-l', '--list', '--merged', '--no-merged', '--contains', '--no-contains', '--points-at', '--format', '--sort'])

const gitRefusal = (g: { sub?: string; args: string[] }): boolean => {
  const sub = g.sub ?? ''
  const args = g.args
  if (GIT_WRITES.has(sub)) return true
  if (sub === 'branch' || sub === 'tag') {
    if (args.some(a => BRANCH_WRITE_FLAGS.has(a) || (sub === 'tag' && a === '-a'))) return true
    // A name with no listing flag creates one (`git branch feature`); `--merged main` only lists.
    return args.some(a => !isFlag(a)) && !args.some(a => BRANCH_LIST_FLAGS.has(a))
  }
  if (sub === 'stash') return !['list', 'show'].includes(args[0] ?? '')
  if (sub === 'worktree') return args[0] !== 'list'
  return false
}

// Every operation and fragment a GraphQL document defines, each with its top level fields (in a
// mutation, the changes it makes) and whether it spreads a fragment there, whose fields this guard
// cannot see. Every one is judged, never only the first (lessons review of #714): a query first
// and a mutation after it is run by naming the mutation in operationName. Strings and comments are
// skipped, so a brace inside an argument's text is not read as structure.
type Operation = { kind: string; fields: string[]; spreads: boolean }
const operations = (doc: string): Operation[] => {
  const out: Operation[] = []
  let depth = 0
  let parens = 0
  let pending: string | undefined
  let op: Operation | undefined
  const ident = (i: number) => (/^[A-Za-z_][A-Za-z0-9_]*/.exec(doc.slice(i)) as RegExpExecArray)[0]
  for (let i = 0; i < doc.length; i++) {
    const c = doc[i] as string
    if (c === '"') {
      for (i++; i < doc.length && doc[i] !== '"'; i++) if (doc[i] === '\\') i++
    } else if (c === '#') {
      while (i < doc.length && doc[i] !== '\n') i++
    } else if (c === '{') {
      // A document's shorthand `{ ... }` is a query.
      if (depth === 0) out.push((op = { kind: pending ?? 'query', fields: [], spreads: false }))
      pending = undefined
      depth++
    } else if (c === '}') depth--
    else if (c === '(') parens++
    else if (c === ')') parens--
    else if (c === '.' && doc.startsWith('...', i)) {
      if (depth === 1 && op) op.spreads = true
      i += 2
      // The fragment's name, or `on Type`, belongs to the spread, never a field.
      const after = /^\s*(?:on\s+)?[A-Za-z_][A-Za-z0-9_]*/.exec(doc.slice(i + 1))
      if (after) i += after[0].length
    } else if (c === '@' && /[A-Za-z_]/.test(doc[i + 1] ?? '')) {
      i += ident(i + 1).length
    } else if (/[A-Za-z_]/.test(c)) {
      const word = ident(i)
      i += word.length - 1
      if (depth === 0 && parens === 0 && ['query', 'mutation', 'subscription', 'fragment'].includes(word)) pending = word
      // An alias (`a: createIssue`) names the field after it.
      else if (depth === 1 && parens === 0 && op && !/^\s*:/.test(doc.slice(i + 1))) op.fields.push(word)
    }
  }
  return out
}
// Issue, milestone and label work is all allowed, through GraphQL too; a pull request is not.
const ISSUE_WORK = (field: string) => /issue|label|milestone/i.test(field) && !/pullrequest/i.test(field)
const graphqlRefusal = (words: string[]): string | undefined => {
  let query: string | undefined
  let fromFile = false
  for (let i = 2; i < words.length; i++) {
    const w = words[i] as string
    if (w === '--input') return 'call the GitHub API with a query that could not be read'
    if (['-f', '-F', '--field', '--raw-field'].includes(w) && (words[i + 1] ?? '').startsWith('query=')) {
      query = (words[++i] as string).slice('query='.length)
      // -F and --field read a value starting with @ from that file; -f takes it as written.
      fromFile = (w === '-F' || w === '--field') && query.startsWith('@')
    }
  }
  // A query read from a file (`-F query=@q.graphql`), or none at all, cannot be judged.
  if (query === undefined || fromFile) return 'call the GitHub API with a query that could not be read'
  for (const op of operations(query)) {
    if (op.kind !== 'mutation') continue
    if (op.spreads || !op.fields.length) return 'call the GitHub API with a query that could not be read'
    const other = op.fields.find(f => !ISSUE_WORK(f))
    if (other) return `call the GitHub API to run ${other}`
  }
  return undefined
}

// gh: everything under issue and label is allowed but `issue develop`, which makes a branch.
const GH_READS: Record<string, Set<string>> = {
  pr: new Set(['view', 'list', 'status', 'checks', 'diff']),
  repo: new Set(['view', 'list']),
  release: new Set(['view', 'list', 'download']),
  workflow: new Set(['view', 'list']),
  run: new Set(['view', 'list', 'watch', 'download']),
  secret: new Set(['list']),
  variable: new Set(['list', 'get']),
}
const GH_API_VALUE_FLAGS = new Set(['-X', '--method', '-f', '-F', '--field', '--raw-field', '-H', '--header', '--input', '-q', '--jq', '-t', '--template', '--hostname', '--cache', '-p', '--preview'])
const GH_API_FIELD_FLAGS = new Set(['-f', '-F', '--field', '--raw-field', '--input'])
const ghRefusal = (words: string[]): string | undefined => {
  const [, sub = '', act = ''] = words
  if (sub === 'issue') return act === 'develop' ? 'run gh issue develop' : undefined
  if (sub === 'api') {
    let method = 'GET'
    let endpoint: string | undefined
    for (let i = 2; i < words.length; i++) {
      const w = words[i] as string
      if (GH_API_VALUE_FLAGS.has(w)) {
        if (w === '-X' || w === '--method') method = (words[i + 1] ?? 'GET').toUpperCase()
        else if (GH_API_FIELD_FLAGS.has(w) && method === 'GET') method = 'POST'
        i++
      } else if (!isFlag(w) && endpoint === undefined) endpoint = w
    }
    // GraphQL is always a POST, so a read is told from a change by the document it sends (#702).
    if (endpoint === 'graphql') return graphqlRefusal(words)
    if (method === 'GET') return undefined
    // Issue, milestone and label work is all allowed, through the API too.
    if (endpoint && /(?:^|\/)(?:issues|milestones|labels)(?:\/|$|\?)/.test(endpoint) && !/\/pulls(?:\/|$)/.test(endpoint)) return undefined
    return `call the GitHub API to change ${endpoint ?? 'something'}`
  }
  const reads = GH_READS[sub]
  if (reads && !reads.has(act)) return `run gh ${sub} ${act}`.trim()
  return undefined
}

// Deploy tools, each with the subcommands that only read or run locally.
const DEPLOYERS: Record<string, (args: string[]) => boolean> = {
  wrangler: a => !['dev', 'tail', 'whoami', 'login', 'logout', 'types', 'init', 'docs', '--version', '-v'].includes(a[0] ?? ''),
  vercel: a => !['dev', 'ls', 'list', 'logs', 'inspect', 'whoami', 'login', 'pull', 'env'].includes(a[0] ?? ''),
  netlify: a => ['deploy', 'build'].includes(a[0] ?? ''),
  firebase: a => a[0] === 'deploy',
  fly: a => a[0] === 'deploy',
  flyctl: a => a[0] === 'deploy',
  supabase: a => (a[0] === 'db' && ['push', 'reset'].includes(a[1] ?? '')) || (a[0] === 'functions' && a[1] === 'deploy') || (a[0] === 'migration' && a[1] === 'up') || (a[0] === 'secrets' && a[1] === 'set'),
  terraform: a => ['apply', 'destroy', 'import'].includes(a[0] ?? ''),
  pulumi: a => ['up', 'destroy'].includes(a[0] ?? ''),
  kubectl: a => ['apply', 'delete', 'rollout', 'scale', 'set', 'patch', 'replace', 'create'].includes(a[0] ?? ''),
  cdk: a => ['deploy', 'destroy'].includes(a[0] ?? ''),
  serverless: a => ['deploy', 'remove'].includes(a[0] ?? ''),
  sls: a => ['deploy', 'remove'].includes(a[0] ?? ''),
  eas: a => ['submit', 'update', 'build'].includes(a[0] ?? ''),
  'claude-sync': a => ['send', 'release', 'install'].includes(a[0] ?? ''),
}
const RUNNERS = new Set(['npm', 'pnpm', 'yarn', 'bun'])
const DEPLOY_SCRIPT = /^(?:deploy|release|publish)(?:[:\-_.].*)?$/i



// The code an interpreter runs, judged where the guard can read it, and refused where it cannot: a
// pipe hands over whatever the command before it prints (#702). mod-kit reads each command's
// program and judges it in its own language (#712), so a heredoc's body is judged too, and a shell
// whose script it can read reaches here as the commands it runs.
const UNREAD_HINT = 'Code passed inline (python3 -c, node -e) or in a heredoc is read and judged, so code that only reads can run that way.'
const programRefusal = (c: Cmd): Refusal | undefined => {
  const runner = name(c.words[0])
  const p = c.program
  if (p && 'unreadable' in p) return { what: `run a ${runner} script it cannot read (${p.unreadable})`, hint: UNREAD_HINT }
  const v = c.verdict
  if (!v) return undefined
  if (v.does === 'unreadable') return { what: `run code from ${runner} it cannot read (${v.seen})`, hint: UNREAD_HINT }
  return { what: `${v.does} from ${runner} (${v.seen})` }
}

// What a call changes on the disk, from mod-kit's write reader (#712): a file content goes into, a
// file removed, stamped, emptied, made or changed in mode, each allowed only where it changes
// nothing (a sink) or is Claude's own notes; and a write whose files no word names, allowed only
// when it lands in the notes. A script file run on standard input is allowed, as one named as an
// operand is: running scripts is how tests and checks run.
const CHANGED: Record<ModKitWrites['changes'][number]['does'], string> = { remove: 'remove', touch: 'write to', truncate: 'write to', folder: 'make the folder', mode: 'change the mode of' }
const writesRefusal = (w: ModKitWrites): Refusal | undefined => {
  for (const f of w.files) {
    const p = f.path ?? f.word
    if (!harmless(p)) return { what: `${f.edits ? 'edit' : 'write to'} ${base(p)}` }
  }
  for (const c of w.changes) {
    const p = c.path ?? c.word
    if (!harmless(p)) return { what: `${CHANGED[c.does]} ${base(p)}` }
  }
  for (const u of w.unnamed) {
    if (u.script || (u.into !== undefined && harmless(u.into))) continue
    return { what: u.what === 'a patch' ? 'apply a patch' : `change files its words do not name (${u.what})` }
  }
  return undefined
}

const DB_CLIENTS = new Set(['psql', 'mysql', 'mariadb', 'sqlite3'])
const commandRefusal = (c: Cmd): Refusal | undefined => {
  let words = c.words
  // npx and bunx only fetch and run the tool named after them.
  while (['npx', 'bunx'].includes(name(words[0]))) words = words.slice(1).filter((w, i) => i > 0 || !isFlag(w))
  const why = (what: string | undefined): Refusal | undefined => (what === undefined ? undefined : { what })
  const cmd = name(words[0])
  if (c.git && gitRefusal(c.git)) return why(`run git ${c.git.sub}`)
  if (cmd === 'gh') return why(ghRefusal(words))
  const deployer = DEPLOYERS[cmd]
  if (deployer && deployer(words.slice(1))) return why(`deploy with ${cmd}`)
  if (RUNNERS.has(cmd)) {
    const script = words[1] === 'run' || words[1] === 'run-script' ? words[2] : words[1]
    if (words[1] === 'publish' || (script && DEPLOY_SCRIPT.test(script))) return why(`run ${words.slice(0, words[1] === 'run' ? 3 : 2).join(' ')}`)
  }
  if (cmd === 'make' && words.slice(1).some(w => DEPLOY_SCRIPT.test(w))) return why(`run make ${words.slice(1).find(w => DEPLOY_SCRIPT.test(w))}`)
  // A database client by every piece of SQL it runs and what it writes itself (sql.ts), MariaDB's
  // own name for its client included (#730). Without SQL given, it reads a file or stdin, which
  // cannot be read.
  if (DB_CLIENTS.has(cmd)) return why(clientRefusal(cmd, words.slice(1), harmless))
  return programRefusal({ ...c, words })
}

const SQL_TOOL = /__(?:execute_sql|run_sql|query)$/
const DB_WRITE_TOOL = /__(apply_migration|deploy_edge_function|create_branch|delete_branch|merge_branch|reset_branch|rebase_branch|create_project|pause_project|restore_project)$/
const EDITORS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])

/**
 * Why no build refuses this call, as the action it would have taken ("edit app.ts", "run git
 * commit"), or undefined when no build allows it.
 */
export const noBuildRefusal = (call: { tool: string; input: Record<string, unknown>; commands: Cmd[]; writes: ModKitWrites }): Refusal | undefined => {
  const { tool, input } = call
  if (EDITORS.has(tool)) {
    const path = String(input.file_path ?? input.notebook_path ?? '')
    return inNotes(path) ? undefined : { what: `edit ${base(path)}` }
  }
  if (tool === 'EnterWorktree') return { what: 'enter a new worktree' }
  if (tool === 'Skill' && String(input.skill ?? '').replace(/^.*:/, '') === 'db-apply') return { what: 'run the db-apply skill' }
  const dbWrite = DB_WRITE_TOOL.exec(tool)
  if (tool.startsWith('mcp__') && dbWrite) return { what: dbWrite[1] as string }
  if (tool.startsWith('mcp__') && SQL_TOOL.test(tool)) {
    const sql = input.query ?? input.sql
    const why = sqlRefusal(typeof sql === 'string' ? sql : undefined, 'the SQL tool', harmless)
    return why ? { what: why } : undefined
  }
  if (tool !== 'Bash') return undefined
  for (const c of call.commands) {
    const why = commandRefusal(c)
    if (why) return why
  }
  return writesRefusal(call.writes)
}
