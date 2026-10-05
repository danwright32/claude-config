import { interpreterOf, isShell, type Program } from './program.ts'

// No build (#616): what Claude may and may not do while it is on, as the spec agreed with Dan.
// Allowed: reading, research, tests and checks, read only queries, scratchpad notes, and all GitHub
// issue, milestone and label work. Refused: code edits outside the scratchpad, commits, branches,
// PRs, deploys and data changing SQL, including the routes around the refusal (shell redirects,
// heredocs, sed -i). Pure: the shell is read by mod-kit's one reader and handed in as words, each
// command's program (program.ts) read from those words.

/** One simple command, as `$.modkit.commands` splits it, with `$.modkit.git`'s reading when it is git and the program it runs when that is not a script file. */
export type Cmd = { words: string[]; git?: { sub?: string; args: string[] }; program?: Program }
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

// A GraphQL document's top level fields: in a mutation, the changes it makes. Strings are skipped,
// so a brace inside an argument's text is not read as structure.
const topFields = (doc: string): string[] => {
  const out: string[] = []
  let depth = 0
  let parens = 0
  for (let i = 0; i < doc.length; i++) {
    const c = doc[i] as string
    if (c === '"') {
      for (i++; i < doc.length && doc[i] !== '"'; i++) if (doc[i] === '\\') i++
    } else if (c === '#') {
      while (i < doc.length && doc[i] !== '\n') i++
    } else if (c === '{') depth++
    else if (c === '}') depth--
    else if (c === '(') parens++
    else if (c === ')') parens--
    else if (depth === 1 && parens === 0 && /[A-Za-z_]/.test(c)) {
      const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(doc.slice(i)) as RegExpExecArray
      i += m[0].length - 1
      // An alias (`a: createIssue`) names the field after it.
      if (!/^\s*:/.test(doc.slice(i + 1))) out.push(m[0])
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
  const doc = query.replace(/^(?:\s|#[^\n]*\n)*/, '')
  if (!/^mutation\b/.test(doc)) return undefined
  const changes = topFields(doc.slice(doc.indexOf('{')))
  if (!changes.length) return 'call the GitHub API with a query that could not be read'
  const other = changes.find(f => !ISSUE_WORK(f))
  return other ? `call the GitHub API to run ${other}` : undefined
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

// SQL with its string literals, quoted identifiers and comments blanked, so a word inside one
// ("status = 'delete'", "-- then drop it") is never read as a statement (#702).
const sqlCode = (sql: string): string => {
  let out = ''
  for (let i = 0; i < sql.length; i++) {
    const c = sql[i] as string
    const dollar = c === '$' ? /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i)) : null
    if (c === "'" || c === '"' || c === '`') {
      // A doubled quote inside is the quote itself.
      for (i++; i < sql.length; i++) if (sql[i] === c && sql[i + 1] !== c) break
      else if (sql[i] === c) i++
      out += ' x '
    } else if (dollar) {
      const end = sql.indexOf(dollar[0], i + dollar[0].length)
      i = end < 0 ? sql.length : end + dollar[0].length - 1
      out += ' x '
    } else if (c === '-' && sql[i + 1] === '-') {
      while (i < sql.length && sql[i] !== '\n') i++
      out += ' '
    } else if (c === '/' && sql[i + 1] === '*') {
      const end = sql.indexOf('*/', i + 2)
      i = end < 0 ? sql.length : end + 1
      out += ' '
    } else out += c
  }
  return out
}
// SQL that changes data or schema: these anywhere in a statement (a data changing CTE included),
// and the rest only as the statement itself, so replace() or a column named cluster is a read.
const SQL_WRITE = /\b(?:insert|update|delete|drop|alter|truncate|create|grant|revoke|comment\s+on|refresh\s+materialized|merge\s+into|replace\s+into|select\b[^;]*\binto)\b/i
const SQL_WRITE_STATEMENT = /(?:^|;)\s*(?:replace|merge|upsert|copy|vacuum|reindex|cluster|call|do)\b/i
// A query that cannot be read is refused too: it may be either.
const sqlRefusal = (sql: string | undefined): string | undefined => {
  if (sql === undefined) return 'run SQL that could not be read'
  const code = sqlCode(sql)
  return SQL_WRITE.test(code) || SQL_WRITE_STATEMENT.test(code) ? 'change data with SQL' : undefined
}
const valueAfter = (words: string[], flags: string[]): string | undefined => {
  for (let i = 0; i < words.length; i++) {
    const w = words[i] as string
    if (flags.includes(w)) return words[i + 1]
    for (const f of flags) if (f.startsWith('--') && w.startsWith(`${f}=`)) return w.slice(f.length + 1)
  }
  return undefined
}

// Inline code that writes files, for the interpreters Claude reaches for when a write is refused.
const INLINE_WRITE = /open\([^)]*['"][wax]\+?b?['"]|\.write_(?:text|bytes)\(|writeFile|appendFile|fs\.(?:write|rm|unlink|rename|copyFile)|File\.write|shutil\.(?:copy|move|rmtree)|os\.(?:remove|unlink|rename|replace)|unlinkSync|rmSync|renameSync|\bunlink\s*\(|open\s*\(\s*\w+\s*,\s*['"]\+?[>|]/

// The files a command writes or removes by its arguments.
const DEST_ONLY = new Set(['cp', 'ln', 'install', 'rsync', 'ditto'])
const ALL_ARGS = new Set(['mv', 'rm', 'rmdir', 'unlink', 'touch', 'mkdir', 'truncate', 'shred', 'tee'])
const FIRST_IS_MODE = new Set(['chmod', 'chown', 'chgrp'])
const IN_PLACE = new Set(['sed', 'gsed', 'perl', 'ruby'])

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

// gawk's in place edit (`-i inplace`): the files after its program, or every operand when -f or -e
// gave the program. An operand `var=value` is an assignment, not a file.
const AWK_VALUE_FLAGS = new Set(['-f', '-v', '-F', '-i', '-l', '-e', '-E', '--include', '--load', '--file', '--source', '--assign', '--field-separator'])
const awkInPlaceFiles = (args: string[]): string[] | undefined => {
  let inPlace = false
  let programGiven = false
  const operands: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    const attached = /^(?:-i|--include=)(.+)$/.exec(a)
    if (attached && /^inplace(?:\.awk)?$/.test(attached[1] as string)) inPlace = true
    else if (AWK_VALUE_FLAGS.has(a)) {
      if ((a === '-i' || a === '--include') && /^inplace(?:\.awk)?$/.test(args[i + 1] ?? '')) inPlace = true
      if (['-f', '-e', '-E', '--file', '--source'].includes(a)) programGiven = true
      i++
    } else if (!isFlag(a)) operands.push(a)
  }
  if (!inPlace) return undefined
  return (programGiven ? operands : operands.slice(1)).filter(o => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(o))
}

// curl's single letter flags that take a value, so a letter inside a value (`-HAccept: x`) is not
// read as a flag; and the ones whose value is a file curl writes.
const CURL_VALUE_LETTERS = new Set('AbcCdDeEFHKmoPQrtTuUwxXyYz'.split(''))
const CURL_WRITE_LETTERS = new Set(['o', 'D', 'c'])
const CURL_WRITE_LONG = new Set(['--output', '--dump-header', '--cookie-jar', '--trace', '--trace-ascii', '--etag-save', '--stderr'])
const curlRefusal = (args: string[], outside: (p: string[]) => string | undefined): string | undefined => {
  const targets: string[] = []
  let remoteName = false
  let outputDir: string | undefined
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a.startsWith('--')) {
      const [flag, value] = a.includes('=') ? [a.slice(0, a.indexOf('=')), a.slice(a.indexOf('=') + 1)] : [a, undefined]
      if (CURL_WRITE_LONG.has(flag as string)) targets.push(value ?? args[++i] ?? '')
      else if (flag === '--output-dir') outputDir = value ?? args[++i] ?? ''
      else if (flag === '--remote-name' || flag === '--remote-name-all') remoteName = true
      continue
    }
    if (!/^-[A-Za-z]/.test(a)) continue
    for (let j = 1; j < a.length; j++) {
      const letter = a[j] as string
      if (letter === 'O') remoteName = true
      if (!CURL_VALUE_LETTERS.has(letter)) continue
      const value = a.slice(j + 1) || (args[++i] ?? '')
      if (CURL_WRITE_LETTERS.has(letter)) targets.push(value)
      break
    }
  }
  const hit = outside(targets)
  if (hit !== undefined) return `write to ${base(hit)}`
  // -O names the file after the link, in the current folder unless --output-dir says otherwise.
  if (remoteName && (outputDir === undefined || !harmless(outputDir))) return 'write a file with curl'
  return undefined
}

// wget writes into the current folder unless told where: -O (the file, `-` the screen) or -P.
const wgetRefusal = (args: string[], outside: (p: string[]) => string | undefined): string | undefined => {
  let doc: string | undefined
  let prefix: string | undefined
  let spider = false
  const logs: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '--spider') spider = true
    else if (a.startsWith('--output-document')) doc = a.includes('=') ? a.slice(a.indexOf('=') + 1) : (args[++i] ?? '')
    else if (a.startsWith('--directory-prefix')) prefix = a.includes('=') ? a.slice(a.indexOf('=') + 1) : (args[++i] ?? '')
    else if (a.startsWith('--output-file') || a.startsWith('--append-output')) logs.push(a.includes('=') ? a.slice(a.indexOf('=') + 1) : (args[++i] ?? ''))
    else if (/^-[A-Za-z]/.test(a) && !a.startsWith('--')) {
      for (let j = 1; j < a.length; j++) {
        const letter = a[j] as string
        if (!'OPoaeiBtTwQUlARDXI'.includes(letter)) continue
        const value = a.slice(j + 1) || (args[++i] ?? '')
        if (letter === 'O') doc = value
        else if (letter === 'P') prefix = value
        else if (letter === 'o' || letter === 'a') logs.push(value)
        break
      }
    }
  }
  const hit = outside([...(doc !== undefined ? [doc] : []), ...logs])
  if (hit !== undefined) return `write to ${base(hit)}`
  if (spider || doc !== undefined || (prefix !== undefined && harmless(prefix))) return undefined
  return 'write a file with wget'
}

// find: -delete removes what it finds under its starting folders, -exec runs a command on each
// (judged with each starting folder standing for `{}`), and -fprint and its kin write a file.
const FIND_FILE_ACTIONS = new Set(['-fprint', '-fprint0', '-fprintf', '-fls'])
const findRefusal = (args: string[], outside: (p: string[]) => string | undefined): string | undefined => {
  const firstExpr = args.findIndex(a => a.startsWith('-') || a === '(' || a === '!')
  const roots = firstExpr < 0 ? args : args.slice(0, firstExpr)
  const starts = roots.length ? roots : ['.']
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '-delete' && outside(starts) !== undefined) return 'delete files with find'
    if (FIND_FILE_ACTIONS.has(a)) {
      const hit = outside([args[i + 1] ?? ''])
      if (hit !== undefined) return `write to ${base(hit)}`
    }
    if (['-exec', '-execdir', '-ok', '-okdir'].includes(a)) {
      const end = args.findIndex((w, j) => j > i && (w === ';' || w === '+'))
      const inner = args.slice(i + 1, end < 0 ? args.length : end)
      for (const root of starts) {
        const why = commandRefusal({ words: inner.map(w => (w === '{}' ? root : w)) })
        if (why) return why.what
      }
      i = end < 0 ? args.length : end
    }
  }
  return undefined
}

const fileRefusal = (words: string[]): string | undefined => {
  const cmd = name(words[0])
  const args = words.slice(1)
  const plain = args.filter(a => !isFlag(a) && !REDIRECT.test(a) && !a.startsWith('<'))
  const outside = (paths: string[]) => paths.find(p => !harmless(p))
  if (IN_PLACE.has(cmd)) {
    const files = inPlaceFiles(args, cmd)
    const hit = files && outside(files)
    if (hit !== undefined) return `edit ${base(hit)}`
  }
  if (cmd === 'awk' || cmd === 'gawk') {
    const files = awkInPlaceFiles(args)
    const hit = files && outside(files)
    if (hit !== undefined) return `edit ${base(hit)}`
  }
  if (cmd === 'curl') return curlRefusal(args, outside)
  if (cmd === 'wget') return wgetRefusal(args, outside)
  if (cmd === 'find') return findRefusal(args, outside)
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
  return undefined
}

// The code an interpreter runs, judged where the guard can read it, and refused where it cannot: a
// heredoc's body never reaches mod-kit's reader, and a pipe hands over whatever the command before
// it prints (#702).
const UNREAD_HINT = 'Code passed inline (python3 -c, node -e) is read and judged, so code that only reads can run that way.'
const programRefusal = (c: Cmd): Refusal | undefined => {
  const p = c.program
  if (!p) return undefined
  const runner = interpreterOf(c.words) ?? (isShell(c.words) ? name(c.words[0]) : undefined)
  if (!runner) return undefined
  if ('unreadable' in p) return { what: `run a ${runner} script it cannot read (${p.unreadable})`, hint: UNREAD_HINT }
  // A shell's program is more commands, which the tool call hook reads and hands in beside it.
  if (interpreterOf(c.words) && INLINE_WRITE.test(p.text)) return { what: `write files from ${runner}` }
  return undefined
}

const commandRefusal = (c: Cmd): Refusal | undefined => {
  let words = c.words
  // npx and bunx only fetch and run the tool named after them.
  while (['npx', 'bunx'].includes(name(words[0]))) words = words.slice(1).filter((w, i) => i > 0 || !isFlag(w))
  const why = (what: string | undefined): Refusal | undefined => (what === undefined ? undefined : { what })
  for (const t of redirectTargets(words)) if (!harmless(t)) return why(`write to ${base(t)}`)
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
  // Without -c, psql reads its SQL from a file or stdin (a heredoc body never reaches the reader).
  if (cmd === 'psql') return why(sqlRefusal(valueAfter(words, ['-c', '--command'])))
  if (cmd === 'mysql') return why(sqlRefusal(valueAfter(words, ['-e', '--execute'])))
  if (cmd === 'sqlite3') {
    const plainArgs = words.slice(1).filter(w => !isFlag(w) && !w.startsWith('<'))
    return why(sqlRefusal(plainArgs[1]))
  }
  return programRefusal({ ...c, words }) ?? why(fileRefusal(words))
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
    return inNotes(path) ? undefined : { what: `edit ${base(path)}` }
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
    if (why) return why
  }
  return undefined
}
