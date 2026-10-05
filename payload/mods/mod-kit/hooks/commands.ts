// The one reader of shell commands every mod uses (L613): each simple command a Bash call would
// run, as its words with quotes removed, judged in command position (L673). Lessons review findings
// on the guards built it up: a heredoc body is text, a here-string is not a heredoc, a heredoc that
// never ends is judged after all, the words that only run the next command are looked past, and
// only a | feeds one command what another prints (#724).

const SHELLS = new Set(['sh', 'bash', 'zsh'])
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/

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

// A heredoc body is text, not commands, so it is dropped before anything else is read: left in, an
// apostrophe in it would open a quote that swallows the commands after it.
const dropHeredocs = (cmd: string): string => {
  const out: string[] = []
  let end: string | undefined
  let body: string[] = []
  for (const line of cmd.split('\n')) {
    if (end !== undefined) {
      if (line.trim() === end) {
        end = undefined
        body = []
      } else body.push(line)
      continue
    }
    out.push(line)
    // Exactly two <, so a here-string (<<<) is not taken for a heredoc.
    const m = /(?<!<)<<(?!<)-?\s*(?:'([^']+)'|"([^"]+)"|\\?([A-Za-z_][A-Za-z0-9_]*))/.exec(line)
    if (m) end = m[1] ?? m[2] ?? m[3]
  }
  return [...out, ...body].join('\n')
}

// Words, split on separators outside quotes. A quoted script spanning lines stays one word. Each
// command carries `from`, the place in the list of the command whose output a | feeds it (#724).
// Standard input is nothing at the top (a Bash call has none to give), the command before after a
// | or |&, and inside a subshell whatever feeds the subshell, for every command in it, since each
// shares it; ;, &&, ||, & and a new line link no two commands, and a new line right after a |
// carries the pipe on.
type Split = { words: string[]; from?: number }
const split = (cmd: string): Split[] => {
  const cmds: Split[] = []
  let words: string[] = []
  let word = ''
  let inWord = false
  let quote: '"' | "'" | undefined
  // Parentheses opened inside a word ($(, <(, $((), whose closing ones belong to the word too.
  let wordParens = 0
  // What feeds the command being read, and what feeds each subshell open around it.
  let from: number | undefined
  const subshells: (number | undefined)[] = []
  const push = (w: string[]) => cmds.push(from === undefined ? { words: w } : { words: w, from })
  const endWord = () => {
    if (inWord) words.push(word)
    word = ''
    inWord = false
  }
  const endCmd = (): boolean => {
    endWord()
    const ended = words.length > 0
    if (ended) push(words)
    words = []
    return ended
  }
  // After a list separator a command reads what its subshell reads.
  const listed = () => {
    from = subshells[subshells.length - 1]
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
      inWord = true
    } else if (c === '>' || (c === '&' && cmd[i + 1] === '>')) {
      // An output redirect is its own word however it is spaced (#654): 2>&1, &>, >>, >| each one
      // word, a file descriptor number written before it included, so its & joins no two commands.
      let op = ''
      if (c === '>' && inWord && /^\d+$/.test(word)) {
        op = word
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
    } else if (c === '\\' && i + 1 < cmd.length) {
      word += cmd[++i]
      inWord = true
    } else if (c === '(' && inWord) {
      wordParens++
      word += c
    } else if (c === ')' && wordParens > 0) {
      wordParens--
      word += c
      inWord = true
    } else if (c === '(' || c === ')') {
      // A subshell's parenthesis is a command of its own (#700), so what runs inside it is read in
      // command position and a reader that follows a cd can tell where the subshell ends.
      endCmd()
      if (c === '(') {
        push([c])
        subshells.push(from)
      } else {
        subshells.pop()
        cmds.push({ words: [c] })
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
      word += c
      inWord = true
    }
  }
  endCmd()
  return cmds
}

// Past assignments and the words that only run the next command. A runner with no command after it
// (a bare env) is the command itself.
const strip = (words: string[]): string[] => {
  let i = 0
  for (;;) {
    const w = words[i] ?? ''
    if (ASSIGNMENT.test(w)) {
      i++
      continue
    }
    const runner = RUNNERS.get(w.split('/').pop() ?? '')
    const next = runner && runs(words, i, runner)
    if (next === undefined) break
    i = next
  }
  return words.slice(i)
}

/** One simple command: its words, and the words of the command whose output a | feeds into it. */
export type Command = { words: string[]; pipedFrom?: string[] }

/** Each simple command a Bash call would run, with what a pipe feeds it, if anything. */
export const pipeline = (cmd: string): Command[] => {
  const out: Command[] = []
  const read = split(dropHeredocs(cmd))
  const stripped = read.map(r => strip(r.words))
  read.forEach((r, k) => {
    const words = stripped[k] as string[]
    if (words.length === 0) return
    // The command feeding it, named past its own runner as every command is.
    const feeder = r.from === undefined ? undefined : stripped[r.from]?.length ? stripped[r.from] : read[r.from]?.words
    const name = (words[0] as string).split('/').pop() ?? ''
    const c = words.indexOf('-c')
    // A command run through a shell's -c is read as the commands it runs, each that no | of its own
    // feeds reading what feeds the shell.
    if (SHELLS.has(name) && c > 0 && words[c + 1] !== undefined) {
      for (const inner of pipeline(words[c + 1] as string)) out.push(inner.pipedFrom || !feeder || inner.words[0] === ')' ? inner : { ...inner, pipedFrom: feeder })
      return
    }
    out.push(feeder ? { words, pipedFrom: feeder } : { words })
  })
  return out
}

/** Each simple command a Bash call would run, as its words. */
export const commands = (cmd: string): string[][] => pipeline(cmd).map(c => c.words)

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
