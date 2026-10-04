// No build (#616): what Claude may and may not do while it is on, as the spec agreed with Dan.
// Allowed: reading, research, tests and checks, read only queries, scratchpad notes, and all GitHub
// issue, milestone and label work. Refused: code edits outside the scratchpad, commits, branches,
// PRs, deploys and data changing SQL, including the routes around the refusal (shell redirects,
// heredocs, sed -i). Pure: the shell is read by mod-kit's one reader and handed in as words.

/** One simple command, as `$.modkit.commands` splits it, with `$.modkit.git`'s reading when it is git. */
export type Cmd = { words: string[]; git?: { sub?: string; args: string[] } }
export type Refusal = { what: string }

// The session scratchpad Claude Code hands every session: /tmp/claude-<uid>/<project>/<session>/scratchpad.
const SCRATCH = /^(?:\/private)?\/tmp\/claude-\d+\/[^/]+\/[^/]+\/scratchpad(?:\/|$)/
export const inScratch = (p: string): boolean => !p.split('/').includes('..') && SCRATCH.test(p)

const base = (p: string) => p.replace(/\/+$/, '').split('/').pop() || p
const isFlag = (w: string) => w.startsWith('-') && w !== '-'
const name = (w: string | undefined) => (w ?? '').split('/').pop() ?? ''

// Where a redirect may point and change nothing: the null device, the terminal, another descriptor.
const SINKS = new Set(['/dev/null', '/dev/stdout', '/dev/stderr', '/dev/tty'])
const harmless = (target: string) => SINKS.has(target) || /^&?\d*-?$/.test(target) || inScratch(target)

const REDIRECT = /^(?:\d*|&)>>?\|?(.*)$/
// Every file a command's redirects write to. A redirect with nothing after it is a descriptor copy
// (`2>&1` arrives as `2>` with the `&1` split off), which writes no file.
const redirectTargets = (words: string[]): string[] => {
  const out: string[] = []
  for (let i = 0; i < words.length; i++) {
    const m = REDIRECT.exec(words[i] as string)
    if (!m) continue
    const attached = m[1] as string
    if (attached) out.push(attached)
    else if (i + 1 < words.length) out.push(words[++i] as string)
  }
  return out
}

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

// SQL that changes data or schema. A query that cannot be read is refused too: it may be either.
const SQL_WRITE = /\b(?:insert|update|delete|drop|alter|truncate|create|grant|revoke|merge|upsert|replace|copy|vacuum|reindex|cluster|call|comment\s+on|refresh\s+materialized|select\b[^;]*\binto)\b/i
const sqlRefusal = (sql: string | undefined): string | undefined => (sql === undefined ? 'run SQL that could not be read' : SQL_WRITE.test(sql) ? 'change data with SQL' : undefined)
const valueAfter = (words: string[], flags: string[]): string | undefined => {
  for (let i = 0; i < words.length; i++) {
    const w = words[i] as string
    if (flags.includes(w)) return words[i + 1]
    for (const f of flags) if (f.startsWith('--') && w.startsWith(`${f}=`)) return w.slice(f.length + 1)
  }
  return undefined
}

// Inline code that writes files, for the interpreters Claude reaches for when a write is refused.
const INLINE = new Set(['python', 'python3', 'node', 'ruby', 'perl', 'bun', 'deno'])
const INLINE_WRITE = /open\([^)]*['"][wax]\+?b?['"]|\.write_(?:text|bytes)\(|writeFile|appendFile|fs\.(?:write|rm|unlink|rename|copyFile)|File\.write|shutil\.(?:copy|move|rmtree)|os\.(?:remove|unlink|rename|replace)|unlinkSync|rmSync|renameSync/

// The files a command writes or removes by its arguments.
const DEST_ONLY = new Set(['cp', 'ln', 'install', 'rsync', 'ditto'])
const ALL_ARGS = new Set(['mv', 'rm', 'rmdir', 'unlink', 'touch', 'mkdir', 'truncate', 'shred', 'tee'])
const FIRST_IS_MODE = new Set(['chmod', 'chown', 'chgrp'])

const inPlaceFiles = (args: string[], cmdName: string): string[] | undefined => {
  const inPlace = args.some(a => a.startsWith('--in-place') || (/^-[A-Za-z]+/.test(a) && !a.startsWith('--') && /^-[A-Za-z]*i/.test(a)))
  if (!inPlace) return undefined
  // The script is the first non-flag word unless -e (or perl's -e) gave it; -e and -f take a value.
  const out: string[] = []
  let scripted = false
  let skippedScript = false
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '-e' || a === '-f' || a === '--expression' || a === '--file') {
      scripted = true
      i++
      continue
    }
    if (isFlag(a)) continue
    // macOS sed -i takes a suffix as its own word; an empty one arrives as ''.
    if (a === '' && cmdName.endsWith('sed')) continue
    if (!scripted && !skippedScript) {
      skippedScript = true
      continue
    }
    out.push(a)
  }
  return out
}

const fileRefusal = (words: string[]): string | undefined => {
  const cmd = name(words[0])
  const args = words.slice(1)
  const plain = args.filter(a => !isFlag(a) && !REDIRECT.test(a) && !a.startsWith('<'))
  const outside = (paths: string[]) => paths.find(p => !harmless(p))
  if (cmd === 'sed' || cmd === 'gsed' || cmd === 'perl') {
    const files = inPlaceFiles(args, cmd)
    const hit = files && outside(files)
    if (hit !== undefined) return `edit ${base(hit)}`
  }
  if (DEST_ONLY.has(cmd) && plain.length >= 2) {
    const hit = outside([plain[plain.length - 1] as string])
    if (hit !== undefined) return `write to ${base(hit)}`
  }
  if (ALL_ARGS.has(cmd)) {
    const hit = outside(plain)
    if (hit !== undefined) return `write to ${base(hit)}`
  }
  if (FIRST_IS_MODE.has(cmd)) {
    const hit = outside(plain.slice(1))
    if (hit !== undefined) return `write to ${base(hit)}`
  }
  if (cmd === 'dd') {
    const of = args.find(a => a.startsWith('of='))
    if (of && !harmless(of.slice(3))) return `write to ${base(of.slice(3))}`
  }
  if (cmd === 'patch') return 'apply a patch'
  if (INLINE.has(cmd)) {
    const code = valueAfter(words, ['-c', '-e', '--eval'])
    if (code !== undefined && INLINE_WRITE.test(code)) return `write files from ${cmd}`
  }
  return undefined
}

const commandRefusal = (c: Cmd): string | undefined => {
  let words = c.words
  // npx and bunx only fetch and run the tool named after them.
  while (['npx', 'bunx'].includes(name(words[0]))) words = words.slice(1).filter((w, i) => i > 0 || !isFlag(w))
  for (const t of redirectTargets(words)) if (!harmless(t)) return `write to ${base(t)}`
  const cmd = name(words[0])
  if (c.git && gitRefusal(c.git)) return `run git ${c.git.sub}`
  if (cmd === 'gh') return ghRefusal(words)
  const deployer = DEPLOYERS[cmd]
  if (deployer && deployer(words.slice(1))) return `deploy with ${cmd}`
  if (RUNNERS.has(cmd)) {
    const script = words[1] === 'run' || words[1] === 'run-script' ? words[2] : words[1]
    if (words[1] === 'publish' || (script && DEPLOY_SCRIPT.test(script))) return `run ${words.slice(0, words[1] === 'run' ? 3 : 2).join(' ')}`
  }
  if (cmd === 'make' && words.slice(1).some(w => DEPLOY_SCRIPT.test(w))) return `run make ${words.slice(1).find(w => DEPLOY_SCRIPT.test(w))}`
  // Without -c, psql reads its SQL from a file or stdin (a heredoc body never reaches the reader).
  if (cmd === 'psql') return sqlRefusal(valueAfter(words, ['-c', '--command']))
  if (cmd === 'mysql') return sqlRefusal(valueAfter(words, ['-e', '--execute']))
  if (cmd === 'sqlite3') {
    const plainArgs = words.slice(1).filter(w => !isFlag(w) && !w.startsWith('<'))
    return sqlRefusal(plainArgs[1])
  }
  return fileRefusal(words)
}

const SQL_TOOL = /__(?:execute_sql|run_sql|query)$/
const DB_WRITE_TOOL = /__(apply_migration|deploy_edge_function|create_branch|delete_branch|merge_branch|reset_branch|rebase_branch|create_project|pause_project|restore_project)$/
const EDITORS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])

/**
 * Why no build refuses this call, as the action it would have taken ("edit app.ts", "run git
 * commit"), or undefined when no build allows it.
 */
export const noBuildRefusal = (call: { tool: string; input: Record<string, unknown>; commands: Cmd[] }): Refusal | undefined => {
  const { tool, input } = call
  if (EDITORS.has(tool)) {
    const path = String(input.file_path ?? input.notebook_path ?? '')
    return inScratch(path) ? undefined : { what: `edit ${base(path)}` }
  }
  if (tool === 'EnterWorktree') return { what: 'enter a new worktree' }
  if (tool === 'Skill' && String(input.skill ?? '').replace(/^.*:/, '') === 'db-apply') return { what: 'run the db-apply skill' }
  const dbWrite = DB_WRITE_TOOL.exec(tool)
  if (tool.startsWith('mcp__') && dbWrite) return { what: dbWrite[1] as string }
  if (tool.startsWith('mcp__') && SQL_TOOL.test(tool)) {
    const sql = input.query ?? input.sql
    const why = sqlRefusal(typeof sql === 'string' ? sql : undefined)
    return why ? { what: why } : undefined
  }
  if (tool !== 'Bash') return undefined
  for (const c of call.commands) {
    const why = commandRefusal(c)
    if (why) return { what: why }
  }
  return undefined
}
