// The one reader of shell commands every mod uses (L613): each simple command a Bash call would
// run, as its words with quotes removed, judged in command position (L673). Lessons review findings
// on the guards built it up: a heredoc body is text, a here-string is not a heredoc, a heredoc that
// never ends is judged after all, the words that only run the next command are looked past, and
// only a | feeds one command what another prints (#724).

/** The shells whose -c script is read as the commands it runs; the write reader shares the list. */
export const SHELLS: ReadonlySet<string> = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh'])
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/
// The reserved words that lead a command inside a compound one, looked past so the command is in
// command position (lessons review of #724: `then git commit` was a command named then); and the
// words that open and close a group whose body shares one standard input, as a subshell's does.
const LEADS = new Set(['if', 'then', 'else', 'elif', 'while', 'until', 'do', '!', '{'])
const OPENS = new Set(['if', 'while', 'until', 'for', 'select', '{'])
const CLOSES = new Set(['fi', 'done', '}'])

// The words that only run the command after them (sudo cat .env is cat .env), each read by its own
// options, so a value is never taken for the command (#724: nice -n 10 gave a command named 10, and
// timeout, stdbuf and xargs hid the command from every guard). `values` take a value in the same
// word or the next (sudo -u dan, stdbuf -oL), `attached` only in the same word (xargs -i{}), `long`
// are the long options taking the next word unless written with =, `leading` the words before the
// command (timeout's duration), and `noRun` the options under which it runs nothing (command -v
// only prints where a command is). A Map, so a command named constructor is no runner (L738).
type Runner = { values?: string; attached?: string; long?: string[]; leading?: number; noRun?: string }
const TIMEOUT: Runner = { values: 'ks', long: ['--kill-after', '--signal'], leading: 1 }
const RUNNERS = new Map<string, Runner>([
  ['sudo', { values: 'CDghpRrTtUu', long: ['--chdir', '--chroot', '--close-from', '--command-timeout', '--group', '--host', '--other-user', '--prompt', '--role', '--type', '--user'] }],
  ['doas', { values: 'Cu' }],
  ['env', { values: 'CPSu', long: ['--chdir', '--split-string', '--unset'] }],
  ['command', { noRun: 'vV' }],
  ['exec', { values: 'a' }],
  ['nohup', {}],
  ['time', { values: 'fo', long: ['--format', '--output'] }],
  ['nice', { values: 'n', long: ['--adjustment'] }],
  ['timeout', TIMEOUT],
  ['gtimeout', TIMEOUT],
  ['stdbuf', { values: 'eio', long: ['--error', '--input', '--output'] }],
  ['xargs', { values: 'aEdIJLnPRSs', attached: 'eil', long: ['--arg-file', '--delimiter', '--max-args', '--max-chars', '--max-procs', '--process-slot-var'] }],
  ['caffeinate', { values: 'tw' }],
])

// Where the command a runner at `at` runs begins, past its options and their values, its leading
// words and any assignments; undefined when it runs none, so it is the command itself.
const runs = (words: string[], at: number, r: Runner): number | undefined => {
  let i = at + 1
  for (; i < words.length; i++) {
    const w = words[i] as string
    if (w === '--') {
      i++
      break
    }
    // env's lone - is its -i.
    if (w === '-') continue
    if (w.startsWith('--')) {
      if (!w.includes('=') && r.long?.includes(w)) i++
      continue
    }
    if (!w.startsWith('-')) break
    for (let j = 1; j < w.length; j++) {
      const letter = w[j] as string
      if (r.noRun?.includes(letter)) return undefined
      if (r.attached?.includes(letter)) break
      if (r.values?.includes(letter)) {
        if (j === w.length - 1) i++
        break
      }
    }
  }
  i += r.leading ?? 0
  while (ASSIGNMENT.test(words[i] ?? '')) i++
  return i < words.length ? i : undefined
}

// A heredoc's opening: exactly two <, so a here-string (<<<) is not taken for one, then its
// delimiter, quoted, escaped or bare. A line can open several, read one after another.
const OPENING = /(?<!<)<<(?!<)(-?)\s*(?:'([^']+)'|"([^"]+)"|\\?([A-Za-z_][A-Za-z0-9_]*))/g

type Heredoc = { at: number; body: string }

// A heredoc body is text, not commands, so it is dropped before anything else is read: left in, an
// apostrophe in it would open a quote that swallows the commands after it. Each body is kept with
// where its << stands in the text left, so a reader that judges what a heredoc feeds can have it
// (#698). <<- takes the leading tabs off its body, as the shell does.
const dropHeredocs = (cmd: string): { text: string; heredocs: Heredoc[] } => {
  const out: string[] = []
  const heredocs: Heredoc[] = []
  const open: { end: string; tabs: boolean; at: number }[] = []
  let body: string[] = []
  // The lines of the heredoc being read, as written, put back as commands if it never ends.
  let unended: string[] = []
  let offset = 0
  for (const line of cmd.split('\n')) {
    const h = open[0]
    if (h) {
      if (line.trim() === h.end) {
        heredocs.push({ at: h.at, body: body.join('\n') })
        open.shift()
        body = []
        unended = []
      } else {
        body.push(h.tabs ? line.replace(/^\t+/, '') : line)
        unended.push(line)
      }
      continue
    }
    out.push(line)
    for (const m of line.matchAll(OPENING)) open.push({ end: (m[2] ?? m[3] ?? m[4]) as string, tabs: m[1] === '-', at: offset + (m.index ?? 0) })
    offset += line.length + 1
  }
  return { text: [...out, ...unended].join('\n'), heredocs }
}

// Words, split on separators outside quotes. A quoted script spanning lines stays one word. Each
// command carries `from`, the place in the list of the command whose output a | feeds it (#724).
// Standard input is nothing at the top (a Bash call has none to give), the command before after a
// | or |&, and inside a subshell or an if, while, until, for or { } group whatever feeds the group,
// for every command in it, since each shares it; ;, &&, ||, & and a new line link no two commands,
// and a new line right after a | carries the pipe on. A group's closing word (`)`, `fi`, `done`,
// `}`) is fed nothing, and what follows a | after it is fed the group's output as that word.
// Each word's place in the text is kept in `starts`, so a heredoc's << word can be matched to the
// body dropped from under it (#698).
type Split = { words: string[]; starts: number[]; from?: number }
const split = (cmd: string): Split[] => {
  const cmds: Split[] = []
  let words: string[] = []
  let starts: number[] = []
  let word = ''
  let start = 0
  let inWord = false
  let quote: '"' | "'" | undefined
  // Parentheses opened inside a word ($(, <(, $((), whose closing ones belong to the word too.
  let wordParens = 0
  // What feeds the command being read, and what feeds each subshell open around it.
  let from: number | undefined
  const subshells: (number | undefined)[] = []
  const push = (w: string[], s: number[]) => cmds.push(from === undefined ? { words: w, starts: s } : { words: w, starts: s, from })
  const begin = (i: number) => {
    if (inWord) return
    inWord = true
    start = i
  }
  const endWord = () => {
    if (inWord) {
      words.push(word)
      starts.push(start)
    }
    word = ''
    inWord = false
  }
  // After a list separator a command reads what its subshell reads.
  const listed = () => {
    from = subshells[subshells.length - 1]
  }
  const endCmd = (): boolean => {
    endWord()
    const ended = words.length > 0
    const first = words[0] as string
    if (ended && CLOSES.has(first)) {
      subshells.pop()
      listed()
      cmds.push({ words, starts })
    } else if (ended) {
      push(words, starts)
      // Each opener among the reserved words it starts with opens a group (`do if`, `then {`), so
      // every closer is matched by its own opener.
      for (const w of words) {
        if (OPENS.has(w)) subshells.push(from)
        if (!LEADS.has(w)) break
      }
    }
    words = []
    starts = []
    return ended
  }
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i] as string
    if (quote) {
      if (c === quote) quote = undefined
      else if (c === '\\' && quote === '"' && i + 1 < cmd.length) word += cmd[++i]
      else word += c
      continue
    }
    if (c === '"' || c === "'") {
      quote = c
      begin(i)
    } else if (c === '>' || (c === '&' && cmd[i + 1] === '>')) {
      // An output redirect is its own word however it is spaced (#654): 2>&1, &>, >>, >| each one
      // word, a file descriptor number written before it included, so its & joins no two commands.
      let op = ''
      let at = i
      if (c === '>' && inWord && /^\d+$/.test(word)) {
        op = word
        at = start
        word = ''
        inWord = false
      } else endWord()
      if (c === '&') op += cmd[i++]
      op += '>'
      if (cmd[i + 1] === '>' || cmd[i + 1] === '|') op += cmd[++i]
      if (!op.startsWith('&') && cmd[i + 1] === '&') {
        op += cmd[++i]
        while (/[0-9-]/.test(cmd[i + 1] ?? '')) op += cmd[++i]
      }
      words.push(op)
      starts.push(at)
    } else if (c === '\\' && i + 1 < cmd.length) {
      begin(i)
      word += cmd[++i]
    } else if (c === '(' && inWord) {
      wordParens++
      word += c
    } else if (c === ')' && wordParens > 0) {
      wordParens--
      begin(i)
      word += c
    } else if (c === '(' || c === ')') {
      // A subshell's parenthesis is a command of its own (#700), so what runs inside it is read in
      // command position and a reader that follows a cd can tell where the subshell ends.
      endCmd()
      if (c === '(') {
        push([c], [i])
        subshells.push(from)
      } else {
        subshells.pop()
        cmds.push({ words: [c], starts: [i] })
        listed()
      }
    } else if (c === '|') {
      endCmd()
      if (cmd[i + 1] === '|') {
        i++
        listed()
      } else {
        // |& pipes standard error too.
        if (cmd[i + 1] === '&') i++
        from = cmds.length ? cmds.length - 1 : undefined
      }
    } else if (c === ';' || c === '&') {
      endCmd()
      listed()
    } else if (c === '\n') {
      if (endCmd()) listed()
    } else if (c === ' ' || c === '\t') endWord()
    else {
      begin(i)
      word += c
    }
  }
  endCmd()
  return cmds
}

// Where the command begins: past assignments, the reserved words that lead a command, and the
// words that only run the next command. A runner with no command after it (a bare env) is the
// command itself.
const begins = (words: string[]): number => {
  let i = 0
  for (;;) {
    const w = words[i] ?? ''
    if (ASSIGNMENT.test(w) || LEADS.has(w)) {
      i++
      continue
    }
    const runner = RUNNERS.get(w.split('/').pop() ?? '')
    const next = runner && runs(words, i, runner)
    if (next === undefined) break
    i = next
  }
  return i
}

// A shell's script given by -c, alone or in a cluster (bash -lc, zsh -ec, sh -ce, #698): the first
// word after its options, wherever the c stands, each o or O taking the next word as its value
// (bash -eo pipefail -c), as --rcfile and --init-file do; after -- or a lone -, the next word.
// Undefined without -c, or with nothing after it. A -c after a script file is that script's own.
const SHELL_LONG_VALUED = new Set(['--rcfile', '--init-file'])
const shellScript = (words: readonly string[]): string | undefined => {
  let c = false
  for (let i = 1; i < words.length; i++) {
    const w = words[i] as string
    if (w === '--' || w === '-') return c ? words[i + 1] : undefined
    if (w.startsWith('--')) {
      if (SHELL_LONG_VALUED.has(w)) i++
      continue
    }
    if (/^[-+][A-Za-z]+$/.test(w)) {
      if (w[0] === '-' && w.includes('c')) c = true
      i += (w.slice(1).match(/[oO]/g) ?? []).length
      continue
    }
    return c ? w : undefined
  }
  return undefined
}

const HEREDOC_WORD = /^(\d*)<<(?!<)/

/**
 * One simple command: its words, the words of the command whose output a | feeds into it, and the
 * body of each heredoc that feeds it (#698), `word` being the place of its << word in `words`.
 */
export type Command = { words: string[]; pipedFrom?: string[]; heredocs?: { word: number; body: string }[] }

/**
 * Each simple command a Bash call would run, with what a pipe feeds it and the body of each heredoc
 * that feeds it, if anything. A heredoc inside a word ("$(cat <<'EOF' ... )") feeds no command
 * here, and one that never ends has no body: its lines are read as commands.
 */
export const pipeline = (cmd: string, opts: ReadOptions = {}): Command[] => {
  const out: Command[] = []
  const { text, heredocs } = dropHeredocs(cmd)
  const bodyAt = new Map(heredocs.map(h => [h.at, h.body]))
  const read = split(text)
  const begun = read.map(r => begins(r.words))
  const stripped = read.map((r, k) => r.words.slice(begun[k]))
  read.forEach((r, k) => {
    const words = stripped[k] as string[]
    if (words.length === 0) {
      // A command that only sets variables runs nothing, so it is no command, unless the reader
      // asked for it (#743): then it is given as its assignments.
      const sets = r.words.filter(w => ASSIGNMENT.test(w))
      if (opts.assignments && sets.length) out.push({ words: sets })
      return
    }
    const starts = r.starts.slice(begun[k])
    // The command feeding it, named past its own runner as every command is.
    const feeder = r.from === undefined ? undefined : stripped[r.from]?.length ? stripped[r.from] : read[r.from]?.words
    const name = (words[0] as string).split('/').pop() ?? ''
    // A command run through a shell's -c is read as the commands it runs, each that no | of its own
    // feeds reading what feeds the shell.
    const script = SHELLS.has(name) ? shellScript(words) : undefined
    if (script !== undefined) {
      for (const inner of pipeline(script, opts)) out.push(inner.pipedFrom || !feeder || inner.words[0] === ')' ? inner : { ...inner, pipedFrom: feeder })
      return
    }
    const fed: { word: number; body: string }[] = []
    words.forEach((w, n) => {
      const m = HEREDOC_WORD.exec(w)
      const body = m ? bodyAt.get((starts[n] as number) + (m[1] as string).length) : undefined
      if (body !== undefined) fed.push({ word: n, body })
    })
    out.push({ words, ...(feeder ? { pipedFrom: feeder } : {}), ...(fed.length ? { heredocs: fed } : {}) })
  })
  return out
}

/**
 * What a reader asks for beyond the commands that run: `assignments` gives a command that only sets
 * variables (`F=path;`) as its assignments, for a reader that follows a variable to its value (#743).
 */
export type ReadOptions = { assignments?: boolean }

/** Each simple command a Bash call would run, as its words. */
export const commands = (cmd: string, opts: ReadOptions = {}): string[][] => pipeline(cmd, opts).map(c => c.words)

// A git command's subcommand, after git's own global options, and the folder -C points it at. The
// one reading of a git command every mod uses (the style check's commit, the collision guard's
// checkout), so neither keeps its own.
const GIT_GLOBAL_WITH_VALUE = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace'])
export type GitCommand = { sub: string | undefined; args: string[]; dir: string | undefined }
export const git = (words: string[]): GitCommand | undefined => {
  if ((words[0] ?? '').split('/').pop() !== 'git') return undefined
  let dir: string | undefined
  for (let i = 1; i < words.length; i++) {
    const w = words[i] as string
    if (GIT_GLOBAL_WITH_VALUE.has(w)) {
      if (w === '-C') dir = words[i + 1]
      i++
    } else if (!w.startsWith('-')) return { sub: w, args: words.slice(i + 1), dir }
  }
  return { sub: undefined, args: [], dir }
}
