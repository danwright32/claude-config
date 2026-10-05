// What no build makes of a database client's command line (#616, #702): the SQL it runs, read by
// its statements and the client's own commands, and what the client itself writes or runs.

// SQL with its string literals, quoted identifiers and comments blanked, so a word inside one
// ("status = 'delete'", "-- then drop it") is never read as a statement (#702). Each blank keeps
// the length it replaced, so a position in it is the same position in the SQL, where a client
// command's target is read. Whether a backslash escapes a quote depends on the dialect (MySQL and
// E'' strings: yes; a standard string: no), so the text is read both ways, and a reading whose
// quotes never close is said to be unbalanced (lessons review of #714).
const sqlCode = (sql: string, backslash: boolean): { code: string; balanced: boolean } => {
  let out = ''
  let balanced = true
  const blank = (from: number, to: number) => `x${' '.repeat(Math.max(0, to - from))}`
  for (let i = 0; i < sql.length; i++) {
    const c = sql[i] as string
    const dollar = c === '$' ? /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i)) : null
    if (c === "'" || c === '"' || c === '`') {
      const start = i
      let closed = false
      for (i++; i < sql.length; i++) {
        if (backslash && sql[i] === '\\') i++
        // A doubled quote inside is the quote itself.
        else if (sql[i] === c && sql[i + 1] === c) i++
        else if (sql[i] === c) {
          closed = true
          break
        }
      }
      if (!closed) balanced = false
      out += blank(start, Math.min(i, sql.length - 1))
    } else if (dollar) {
      const start = i
      const end = sql.indexOf(dollar[0], i + dollar[0].length)
      if (end < 0) balanced = false
      i = end < 0 ? sql.length - 1 : end + dollar[0].length - 1
      out += blank(start, i)
    } else if (c === '-' && sql[i + 1] === '-') {
      const start = i
      while (i + 1 < sql.length && sql[i + 1] !== '\n') i++
      out += ' '.repeat(i - start + 1)
    } else if (c === '/' && sql[i + 1] === '*') {
      const start = i
      const end = sql.indexOf('*/', i + 2)
      i = end < 0 ? sql.length - 1 : end + 1
      out += sql.slice(start, i + 1).replace(/[^\n]/g, ' ')
    } else out += c
  }
  return { code: out, balanced }
}

// SQL that changes data or schema: these anywhere in a statement (a data changing CTE included),
// and the rest only as the statement itself, so replace() or a column named cluster is a read.
const SQL_WRITE = /\b(?:insert|update|delete|drop|alter|truncate|create|grant|revoke|comment\s+on|refresh\s+materialized|merge\s+into|replace\s+into|select\b[^;]*\binto)\b/i
const SQL_WRITE_STATEMENT = /(?:^|;)\s*(?:replace|merge|upsert|copy|vacuum|reindex|cluster|call|do)\b/i
// The clients' own commands, which no statement keyword shows (lessons review of #714): psql's
// \copy <table> from (a query in brackets can only be copied to) and sqlite's .import load data;
// \i, \gexec, sqlite's .read and MySQL's source run SQL this guard cannot read; \!, .shell,
// .system, MySQL's system and pager, and \copy ... program run a shell.
const CLIENT_LOADS = /\\copy\s+(?!\()\S+(?:\s*\([^)]*\))?\s+from\b|(?:^|\n)\s*\.(?:import|restore)\b/i
const CLIENT_RUNS = /\\(?:i|ir|include|include_relative|gexec)\b|(?:^|\n)\s*\.read\b|(?:^|[;\n])\s*(?:source|\\\.)\s/i
const CLIENT_SHELL = /\\!|(?:^|\n)\s*\.(?:shell|system)\b|(?:^|[;\n])\s*(?:system|pager|\\P)\s+\S|\\copy\b[^\n]*?\b(?:from|to)\s+program\b/i
// The client commands that write a local file, each followed by its target (lessons review of #714
// at fad450f): psql's \o, \w and \g (to a file, or `|cmd`, a shell), \copy ... to <file>; sqlite's
// .output, .once, .backup and .save; MySQL's tee.
const CLIENT_TARGETS: { re: RegExp; last?: boolean }[] = [
  { re: /\\(?:o|out|w|write|gx?)\b[ \t]*/g },
  { re: /\\copy\b[^\n]*?\bto\s+/g },
  { re: /(?:^|\n)[ \t]*\.(?:output|once|backup|save)\b[ \t]*/g, last: true },
  { re: /(?:^|[;\n])[ \t]*(?:tee|\\T)[ \t]+/g },
]
const COPY_ENDS = new Set(['stdout', 'pstdout', 'stdin', 'pstdin'])

// The target a client command names at `at` in the SQL as written: a quoted word, a `|command`, or
// the word up to the next space; for sqlite's commands the last word on the line, past its options.
const targetAt = (sql: string, at: number, last: boolean): string | undefined => {
  const line = sql.slice(at).split('\n')[0] ?? ''
  const words = [...line.matchAll(/'([^']*)'|"([^"]*)"|(\|.*)|([^\s;]+)/g)].map(m => (m[1] ?? m[2] ?? m[3] ?? m[4]) as string)
  if (!last) return words[0]
  const plain = words.filter(w => !w.startsWith('-'))
  // sqlite's .once -x or -e opens the result in an app, which is no file this guard can judge.
  if (!plain.length && words.some(w => /^-[xe]$/.test(w))) return '|open'
  return plain[plain.length - 1]
}

/**
 * Why no build refuses the SQL a client runs, or undefined when it only reads. `harmless` says
 * which local files a client may write (the scratchpad, Claude's notes, the null device).
 */
export const sqlRefusal = (sql: string | undefined, client: string, harmless: (target: string) => boolean): string | undefined => {
  if (sql === undefined) return 'run SQL that could not be read'
  const readings = [sqlCode(sql, false), sqlCode(sql, true)]
  const codes = readings.map(r => r.code)
  if (codes.some(c => CLIENT_SHELL.test(c))) return `run a shell command through ${client}`
  for (const code of codes) {
    for (const { re, last } of CLIENT_TARGETS) {
      for (const m of code.matchAll(re)) {
        const target = targetAt(sql, (m.index ?? 0) + m[0].length, !!last)
        if (target === undefined || COPY_ENDS.has(target.toLowerCase())) continue
        if (target.startsWith('|')) return `run a shell command through ${client}`
        if (!harmless(target)) return `write to ${target.replace(/\/+$/, '').split('/').pop() || target}`
      }
    }
  }
  if (codes.some(c => CLIENT_LOADS.test(c) || SQL_WRITE.test(c) || SQL_WRITE_STATEMENT.test(c))) return 'change data with SQL'
  if (codes.some(c => CLIENT_RUNS.test(c))) return 'run SQL that could not be read'
  // Quotes that close under neither reading leave nothing that can be judged.
  if (!readings.some(r => r.balanced)) return 'run SQL that could not be read'
  return undefined
}

// Each client's command line, read by its own options: every piece of SQL it runs (psql runs every
// -c, sqlite every argument after the database), a script file it runs (psql -f, sqlite -init),
// which cannot be read, and a file its output goes to (psql -o and -L, MySQL --tee).
type Client = { sql: string[]; file: boolean; outputs: string[] }
type Options = { sql: string; file: string; output: string; value: string; longSql: string[]; longFile: string[]; longOutput: string[]; longValue: string[] }
const CLIENTS: Record<string, Options> = {
  psql: { sql: 'c', file: 'f', output: 'oL', value: 'dFhpPRTUv', longSql: ['--command'], longFile: ['--file'], longOutput: ['--output', '--log-file'], longValue: ['--dbname', '--host', '--port', '--username', '--set', '--variable', '--pset', '--field-separator', '--record-separator', '--table-attr'] },
  mysql: { sql: 'e', file: '', output: '', value: 'uhPDS', longSql: ['--execute'], longFile: [], longOutput: ['--tee'], longValue: ['--user', '--host', '--port', '--database', '--socket'] },
}
const readClient = (cmd: string, args: readonly string[]): Client => {
  const out: Client = { sql: [], file: false, outputs: [] }
  if (cmd === 'sqlite3') {
    const plain: string[] = []
    for (let i = 0; i < args.length; i++) {
      const a = args[i] as string
      if (a === '-cmd') out.sql.push(args[++i] ?? '')
      else if (a === '-init') {
        out.file = true
        i++
      } else if (['-separator', '-newline', '-nullvalue', '-vfs', '-maxsize', '-pagecache', '-lookaside', '-mmap', '-heap'].includes(a)) i++
      else if (!a.startsWith('-') && !a.startsWith('<')) plain.push(a)
    }
    // The first plain word is the database; every one after it is run.
    out.sql.push(...plain.slice(1))
    return out
  }
  const o = CLIENTS[cmd] as Options
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a.startsWith('--')) {
      const eq = a.indexOf('=')
      const name = eq < 0 ? a : a.slice(0, eq)
      const value = () => (eq < 0 ? (args[++i] ?? '') : a.slice(eq + 1))
      if (o.longSql.includes(name)) out.sql.push(value())
      else if (o.longFile.includes(name)) {
        out.file = true
        value()
      } else if (o.longOutput.includes(name)) out.outputs.push(value())
      else if (o.longValue.includes(name)) value()
      continue
    }
    if (!/^-[A-Za-z]/.test(a)) continue
    for (let j = 1; j < a.length; j++) {
      const letter = a[j] as string
      const rest = a.slice(j + 1)
      const value = () => rest || (args[++i] ?? '')
      if (o.sql.includes(letter)) out.sql.push(value())
      else if (o.file.includes(letter)) {
        out.file = true
        value()
      } else if (o.output.includes(letter)) out.outputs.push(value())
      else if (o.value.includes(letter)) value()
      else continue
      break
    }
  }
  return out
}

/** Why no build refuses a database client's command line, or undefined; undefined for any other command. */
export const clientRefusal = (cmd: string, args: readonly string[], harmless: (target: string) => boolean): string | undefined => {
  if (cmd !== 'psql' && cmd !== 'mysql' && cmd !== 'sqlite3') return undefined
  const c = readClient(cmd, args)
  // A script file it runs cannot be read, and with no SQL given it reads stdin, which cannot either.
  if (c.file || !c.sql.length) return 'run SQL that could not be read'
  const out = c.outputs.find(t => !harmless(t))
  if (out !== undefined) return `write to ${out.replace(/\/+$/, '').split('/').pop() || out}`
  for (const s of c.sql) {
    const why = sqlRefusal(s, cmd, harmless)
    if (why) return why
  }
  return undefined
}
