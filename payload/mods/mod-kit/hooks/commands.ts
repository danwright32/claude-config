// The one reader of shell commands every mod uses (L613): each simple command a Bash call would
// run, as its words with quotes removed, judged in command position (L673). Lessons review findings
// on the guards built it up: a heredoc body is text, a here-string is not a heredoc, a heredoc that
// never ends is judged after all, the words that only run the next command are looked past, and
// only a | feeds one command what another prints (#724). Since #712 it also reads what each shell
// or interpreter runs as its program (program.ts) and judges inline code (code.ts), so a shell fed
// its script on standard input is read as the commands it runs, as a shell's -c always was.
import { codeVerdict, type CodeVerdict } from './code.ts'
import { SHELLS, execsOf, kindOf, languageOf, readProgram, type Lang, type Program, type Script, type Stdin } from './program.ts'

export { SHELLS }
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/
// The reserved words that lead a command inside a compound one, looked past so the command is in
// command position (lessons review of #724: `then git commit` was a command named then); and the
// words that open and close a group whose body shares one standard input, as a subshell's does. A
// case's clauses share it too, its `case ... in` opening the group and `esac` closing it (#730).
const LEADS = new Set(['if', 'then', 'else', 'elif', 'while', 'until', 'do', '!', '{'])
const OPENS = new Set(['if', 'while', 'until', 'for', 'select', '{'])
const CLOSES = new Set(['fi', 'done', '}', 'esac'])

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
// `}`, `esac`) is fed nothing, and what follows a | after it is fed the group's output as that word.
// Each word's place in the text is kept in `starts`, so a heredoc's << word can be matched to the
// body dropped from under it (#698).
//
// A case (#730): `case WORD in` is a command of its own that opens a group its clauses share; each
// clause's pattern, up to its `)`, is no command (a `|` in it separates alternatives, never pipes),
// the commands after it run until `;;`, `;&` or `;;&`, and `esac` closes the group. Read as a
// subshell's close, a pattern's `)` took away the feed of the loop around it.
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
  // Each case open around the text being read: in a clause's pattern, or its commands.
  const cases: ('pattern' | 'body')[] = []
  const inPattern = () => cases[cases.length - 1] === 'pattern'
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
      if (first === 'esac') cases.pop()
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
  // `case WORD in`, past the words that lead a command, ends a case's header: a command of its own,
  // then the group its clauses share, read from its first pattern.
  const caseIn = (): boolean => {
    const k = words.length
    if (k < 3 || words[k - 1] !== 'in' || words[k - 3] !== 'case' || !words.slice(0, k - 3).every(w => LEADS.has(w))) return false
    endCmd()
    subshells.push(from)
    cases.push('pattern')
    return true
  }
  const closeCase = (at: number) => {
    cases.pop()
    subshells.pop()
    listed()
    cmds.push({ words: ['esac'], starts: [at] })
  }
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i] as string
    if (quote) {
      if (c === quote) quote = undefined
      else if (c === '\\' && quote === '"' && i + 1 < cmd.length) word += cmd[++i]
      else word += c
      continue
    }
    // A clause's pattern is no command: its words are dropped at the ) that ends it, and an esac
    // where a pattern would start closes the case, the character after it read as usual. A quote or
    // a backslash in a pattern is read as anywhere else.
    if (inPattern() && c !== '"' && c !== "'" && c !== '\\') {
      const separator = /[\s;&|()]/.test(c)
      if (!(separator && inWord && word === 'esac' && words.length === 0)) {
        if (c === ')') {
          word = ''
          inWord = false
          words = []
          starts = []
          cases[cases.length - 1] = 'body'
        } else if (separator) endWord()
        else {
          begin(i)
          word += c
        }
        continue
      }
      const at = start
      word = ''
      inWord = false
      closeCase(at)
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
      // ;; ;& and ;;& end a case clause: what follows is the next pattern.
      if (c === ';' && cases[cases.length - 1] === 'body' && (cmd[i + 1] === ';' || cmd[i + 1] === '&')) {
        i++
        if (cmd[i] === ';' && cmd[i + 1] === '&') i++
        cases[cases.length - 1] = 'pattern'
      }
    } else if (c === '\n') {
      endWord()
      if (!caseIn() && endCmd()) listed()
    } else if (c === ' ' || c === '\t') {
      endWord()
      caseIn()
    } else if (c === '<' && inWord && wordParens === 0 && !/^\d*<*$/.test(word)) {
      // An input redirect begins a word of its own however it is spaced (#730), as an output one
      // does (#654): cat<<EOF, python3 -<<EOF and cmd<file name the command, and the heredoc its
      // body. A descriptor number before it stays with it, and one inside a $( ) word stays there.
      endWord()
      begin(i)
      word += c
    } else {
      begin(i)
      word += c
    }
  }
  if (inPattern() && inWord && word === 'esac' && words.length === 0) {
    const at = start
    word = ''
    inWord = false
    closeCase(at)
  }
  endCmd()
  return cmds
}

// env -S (or --split-string) gives env a command line it splits into words itself (#730): the
// string, and the place after it, or undefined when env has none.
const envSplit = (words: readonly string[], at: number): { value: string; next: number } | undefined => {
  for (let i = at + 1; i < words.length; i++) {
    const a = words[i] as string
    if (a === '--' || (!a.startsWith('-') && a !== '-')) return undefined
    if (a.startsWith('--split-string=')) return { value: a.slice('--split-string='.length), next: i + 1 }
    if (a === '--split-string') return { value: words[i + 1] ?? '', next: i + 2 }
    if (a.startsWith('--')) {
      if (a === '--chdir' || a === '--unset') i++
      continue
    }
    for (let j = 1; j < a.length; j++) {
      const letter = a[j] as string
      if (letter === 'S') return a.slice(j + 1) ? { value: a.slice(j + 1), next: i + 1 } : { value: words[i + 1] ?? '', next: i + 2 }
      if ('CPu'.includes(letter)) {
        if (j === a.length - 1) i++
        break
      }
    }
  }
  return undefined
}

// Where the command begins: past assignments, the reserved words that lead a command, and the
// words that only run the next command. A runner with no command after it (a bare env) is the
// command itself. env -S's string is split into the words it runs, which carry no place in the
// text; and a command xargs runs is marked, since xargs gives it operands from its own input.
type Begun = { words: string[]; starts: number[]; xargs: boolean }
const begins = (words: string[], starts: number[]): Begun => {
  let w = words
  let s = starts
  let xargs = false
  let i = 0
  for (;;) {
    const word = w[i] ?? ''
    if (ASSIGNMENT.test(word) || LEADS.has(word)) {
      i++
      continue
    }
    const name = word.split('/').pop() ?? ''
    const runner = RUNNERS.get(name)
    if (!runner) break
    const env = name === 'env' ? envSplit(w, i) : undefined
    if (env) {
      const inner = split(env.value).flatMap(x => x.words)
      w = [...inner, ...w.slice(env.next)]
      s = [...inner.map(() => -1), ...s.slice(env.next)]
      i = 0
      continue
    }
    const next = runs(w, i, runner)
    if (next === undefined) break
    if (name === 'xargs') xargs = true
    i = next
  }
  return { words: w.slice(i), starts: s.slice(i), xargs }
}

const HEREDOC_WORD = /^(\d*)<<(?!<)/
const OUTPUT_WORD = /^(?:\d*|&)>>?\|?&?(.*)$/
const INPUT_WORD = /^(\d*)(<<<|<<-?|<)(.*)$/
const base = (p: string) => p.split('/').pop() ?? p
const CLOSERS = new Set([')', ...CLOSES])

type Fed = { word: number; body: string }[]

// What a command's own redirects put on its standard input, the last one winning as in the shell:
// a heredoc's body (or, when the reader has none, a heredoc it cannot read), a here-string's text, a
// file. Another descriptor's (3<file) is not standard input.
const ownStdin = (words: readonly string[], fed: Fed): Stdin | undefined => {
  let s: Stdin | undefined
  for (let i = 0; i < words.length; i++) {
    const w = words[i] as string
    const m = INPUT_WORD.exec(w)
    if (!m || w.startsWith('<(')) continue
    const at = i
    const mine = m[1] === '' || m[1] === '0'
    const op = m[2] as string
    const rest = m[3] as string
    if (op === '<<<') {
      const text = rest || (words[++i] ?? '')
      if (mine) s = { text }
    } else if (op.startsWith('<<')) {
      if (!rest) i++
      const body = fed.find(f => f.word === at)?.body
      if (mine) s = body !== undefined ? { text: body } : { unreadable: 'fed by a heredoc' }
    } else {
      const file = rest || (words[++i] ?? '')
      if (mine && file && !file.startsWith('&')) s = { files: [file] }
    }
  }
  return s
}

// A command's words past its options and redirects: what cat reads.
const operandsOf = (args: readonly string[]): string[] => {
  const out: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    const o = OUTPUT_WORD.exec(a)
    const n = a.startsWith('<(') ? null : INPUT_WORD.exec(a)
    if (o || n) {
      if (!(o ? o[1] : n?.[3])) i++
      continue
    }
    if (a.startsWith('-') && a !== '-') continue
    out.push(a)
  }
  return out
}

// What a command puts on the standard input of the one a | feeds: cat of files feeds those files,
// and cat of a heredoc its body (#730: `cat script.scpt | osascript` was read as feeding nothing);
// echo and printf their words; a group's output, or anything else, what cannot be read.
const piped = (feeder: readonly string[], fed: Fed): Stdin => {
  if (CLOSERS.has(feeder[0] as string)) return { unreadable: 'fed by what a group of commands pipes into it' }
  const name = base(feeder[0] as string)
  const args = feeder.slice(1)
  if (name === 'cat') {
    const files = operandsOf(args)
    if (files.length) return { files }
    return ownStdin(feeder, fed) ?? { unreadable: 'fed by what cat pipes into it' }
  }
  if (args.some(a => HEREDOC_WORD.test(a))) return { unreadable: 'fed by a heredoc' }
  if (name === 'echo' || name === 'printf') return { text: args.filter(a => !/^-[neE]+$/.test(a)).join(' ') }
  return { unreadable: `fed by what ${name} pipes into it` }
}

/**
 * One simple command: its words, the words of the command whose output a | feeds into it, and the
 * body of each heredoc that feeds it (#698), `word` being the place of its << word in `words`. For
 * a shell or an interpreter, what it runs (#712): the language of its inline code, its program (its
 * text, `stdin` when that came on standard input, or why it cannot be read), the script file it
 * runs instead, and what the program can do. `xargs` marks a command xargs runs, giving it
 * operands from its own input that no word names.
 */
export type Command = {
  words: string[]
  pipedFrom?: string[]
  heredocs?: Fed
  xargs?: true
  language?: Lang
  program?: Program
  script?: Script
  verdict?: CodeVerdict
}

// What feeds the commands of one read: the command a | feeds them from, what is on their standard
// input, and whether xargs runs them, each given to every command no | of its own feeds.
type Feed = { pipedFrom?: string[]; stdin?: Stdin; xargs?: boolean }

// One command, with what it runs. A shell whose script can be read is read as the commands it runs
// (a -c always was; since #712 a heredoc, a here-string, or what echo, printf or cat pipes in too),
// each reading what feeds the shell (#730: a heredoc or here-string feeding a -c), unless the shell
// reads its script there, when what they read is the rest of that script. What a find -exec runs
// is read after it, as a command of its own.
const emit = (words: string[], fed: Fed, feed: Feed, out: Command[], opts: ReadOptions) => {
  const stdin = ownStdin(words, fed) ?? feed.stdin
  const kind = kindOf(words[0])
  const { program, script } = kind ? readProgram(words, stdin) : {}
  if (kind === 'shell' && program && 'text' in program) {
    const inner: Feed = program.stdin ? { stdin: { unreadable: 'fed the rest of the script the shell reads' } } : { pipedFrom: feed.pipedFrom, stdin }
    out.push(...pipeline(program.text, opts, feed.xargs ? { ...inner, xargs: true } : inner))
    return
  }
  // The language is said only where there is a program or script in it to read.
  const language = program || script ? languageOf(kind) : undefined
  const verdict = language && program && 'text' in program ? codeVerdict(language, program.text) : undefined
  out.push({
    words,
    ...(feed.pipedFrom ? { pipedFrom: feed.pipedFrom } : {}),
    ...(fed.length ? { heredocs: fed } : {}),
    ...(feed.xargs ? { xargs: true as const } : {}),
    ...(language ? { language } : {}),
    ...(program ? { program } : {}),
    ...(script ? { script } : {}),
    ...(verdict ? { verdict } : {}),
  })
  for (const inner of execsOf(words)) {
    const b = begins(inner, inner.map(() => -1))
    if (b.words.length) emit(b.words, [], b.xargs ? { xargs: true } : {}, out, opts)
  }
}

/**
 * Each simple command a Bash call would run, with what a pipe feeds it, the body of each heredoc
 * that feeds it, and what it runs, if anything. A heredoc inside a word ("$(cat <<'EOF' ... )")
 * feeds no command here, and one that never ends has no body: its lines are read as commands.
 * `opts` asks for more than the commands that run (ReadOptions); `outer` is what feeds the commands
 * of a shell's script, read as the commands it runs.
 */
export const pipeline = (cmd: string, opts: ReadOptions = {}, outer: Feed = {}): Command[] => {
  const out: Command[] = []
  const { text, heredocs } = dropHeredocs(cmd)
  const bodyAt = new Map(heredocs.map(h => [h.at, h.body]))
  const read = split(text)
  const begun = read.map(r => begins(r.words, r.starts))
  const fedOf = (b: Begun): Fed => {
    const fed: Fed = []
    b.words.forEach((w, n) => {
      const m = HEREDOC_WORD.exec(w)
      const at = b.starts[n] ?? -1
      const body = m && at >= 0 ? bodyAt.get(at + (m[1] as string).length) : undefined
      if (body !== undefined) fed.push({ word: n, body })
    })
    return fed
  }
  read.forEach((r, k) => {
    const b = begun[k] as Begun
    if (b.words.length === 0) {
      // A command that only sets variables runs nothing, so it is no command, unless the reader
      // asked for it (#743): then it is given as its assignments.
      const sets = r.words.filter(w => ASSIGNMENT.test(w))
      if (opts.assignments && sets.length) out.push({ words: sets })
      return
    }
    let feed: Feed = {}
    if (r.from !== undefined) {
      // The command feeding it, named past its own runner as every command is.
      const f = begun[r.from] as Begun
      const feeder = f.words.length ? f.words : (read[r.from] as Split).words
      feed = { pipedFrom: feeder, stdin: piped(feeder, fedOf(f)) }
    } else if (!CLOSERS.has(b.words[0] as string)) feed = { pipedFrom: outer.pipedFrom, stdin: outer.stdin }
    if (b.xargs || outer.xargs) feed = { ...feed, xargs: true }
    emit(b.words, fedOf(b), feed, out, opts)
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
