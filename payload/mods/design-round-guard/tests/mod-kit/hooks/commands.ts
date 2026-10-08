// The one reader of shell commands every mod uses (L613): each simple command a Bash call would
// run, as its words with quotes removed, judged in command position (L673). Lessons review findings
// on the guards built it up: a heredoc body is text, a here-string is not a heredoc, a heredoc that
// never ends is judged after all, the words that only run the next command are looked past, and
// only a | feeds one command what another prints (#724). Since #712 it also reads what each shell
// or interpreter runs as its program (program.ts) and judges inline code (code.ts), so a shell fed
// its script on standard input is read as the commands it runs, as a shell's -c always was.
import { codeVerdict, type CodeVerdict } from './code.ts'
import { SHELLS, execsOf, findRoots, kindOf, languageOf, readProgram, type Lang, type Program, type Script, type Stdin } from './program.ts'

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

// `quoted` when any of its delimiter was quoted or escaped, which stops the shell expanding $ and
// backticks in the body (#831).
type Heredoc = { at: number; body: string; quoted: boolean }

// A heredoc body is text, not commands, so it is dropped before anything else is read: left in, an
// apostrophe in it would open a quote that swallows the commands after it. Each body is kept with
// where its << stands in the text left, so a reader that judges what a heredoc feeds can have it
// (#698). <<- takes the leading tabs off its body, as the shell does. A heredoc that never ends is
// given as `unended` too, its body to the end of the text, since the shell still reads that body
// (and expands it, unless its delimiter was quoted) as well as its lines being read as commands here
// (#965). What the shell runs inside each body is read by readLine (#974), so the unended one says
// where its << stands too.
export const dropHeredocs = (cmd: string): { text: string; heredocs: Heredoc[]; unended?: Heredoc } => {
  const out: string[] = []
  const heredocs: Heredoc[] = []
  const open: { end: string; tabs: boolean; at: number; quoted: boolean }[] = []
  let body: string[] = []
  // The lines of the heredoc being read, as written, put back as commands if it never ends.
  let unended: string[] = []
  let offset = 0
  for (const line of cmd.split('\n')) {
    const h = open[0]
    if (h) {
      if (line.trim() === h.end) {
        heredocs.push({ at: h.at, body: body.join('\n'), quoted: h.quoted })
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
    for (const m of line.matchAll(OPENING)) {
      const quoted = m[2] !== undefined || m[3] !== undefined || m[0].includes('\\')
      open.push({ end: (m[2] ?? m[3] ?? m[4]) as string, tabs: m[1] === '-', at: offset + (m.index ?? 0), quoted })
    }
    offset += line.length + 1
  }
  const h = open[0]
  return { text: [...out, ...unended].join('\n'), heredocs, ...(h ? { unended: { at: h.at, body: body.join('\n'), quoted: h.quoted } } : {}) }
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

type Fed = { word: number; body: string; quoted: boolean; fd?: number; replaced?: true }[]

// Whether a word is a redirect onto standard input: an input redirect on descriptor 0 however it is
// written (none, 0, 00), never a process substitution, which is an argument.
const onStdin = (w: string): boolean => {
  if (w.startsWith('<(')) return false
  const m = INPUT_WORD.exec(w)
  return !!m && Number(m[1] || '0') === 0
}
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
    const mine = onStdin(w)
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
  if (name === 'echo') return { text: echoText(args) }
  if (name === 'printf') {
    const text = printfText(operandsOf(args.filter(a => a !== '--')))
    return text === undefined ? { unreadable: 'fed by what printf pipes into it' } : { text }
  }
  return { unreadable: `fed by what ${name} pipes into it` }
}

// The escapes printf's format and its %b, and echo, turn into the characters they stand for
// (lessons review of #761: they were left as written, so `printf 'a\nb' | sh` was one command). An
// escape not listed stays as written.
const ESCAPES = new Map([['n', '\n'], ['t', '\t'], ['r', '\r'], ['\\', '\\'], ['a', '\x07'], ['b', '\b'], ['f', '\f'], ['v', '\v'], ['e', '\x1b']])
const unescape = (s: string) => s.replace(/\\(.)/gs, (m, c: string) => ESCAPES.get(c) ?? m)
// echo's words after its flags, joined with a space, its escapes applied unless -E says not: sh and
// zsh apply them whatever the flags, so the reading that sees every line is the one taken.
const echoText = (args: readonly string[]): string => {
  let i = 0
  let raw = false
  for (; i < args.length && /^-[neE]+$/.test(args[i] as string); i++) if ((args[i] as string).includes('E')) raw = true
  const text = args.slice(i).join(' ')
  return raw ? text : unescape(text)
}
// What printf prints: its format with its escapes applied, each %s a value as written, each %b a
// value with its escapes applied, %% a %, the format used again while values remain. Any other
// directive (%d, %-10s) is a reading this does not reproduce, so it is none (undefined).
const printfText = (args: readonly string[]): string | undefined => {
  const format = args[0] ?? ''
  if (/%(?![sb%])/.test(format)) return undefined
  const values = args.slice(1)
  const takes = /%[sb]/.test(format)
  let out = ''
  let next = 0
  do {
    for (let i = 0; i < format.length; i++) {
      const c = format[i] as string
      const d = format[i + 1]
      if (c === '%' && d !== undefined) {
        i++
        out += d === '%' ? '%' : d === 's' ? (values[next++] ?? '') : unescape(values[next++] ?? '')
      } else if (c === '\\' && d !== undefined) {
        i++
        out += ESCAPES.get(d) ?? `\\${d}`
      } else out += c
    }
  } while (takes && next < values.length)
  return out
}

/**
 * One simple command: its words, the words of the command whose output a | feeds into it, and the
 * body of each heredoc that feeds it (#698), `word` being the place of its << word in `words`. For
 * a shell or an interpreter, what it runs (#712): the language of its inline code, its program (its
 * text, `stdin` when that came on standard input, or why it cannot be read), the script file it
 * runs instead, and what the program can do. `xargs` marks a command xargs runs, giving it
 * operands from its own input that no word names; `found` the folders find starts from, on a
 * command its -exec runs, whose {} this reader writes as one of them and stands for everything
 * under it. `substitution` marks a command the shell runs inside a command substitution (#974).
 */
export type Command = {
  words: string[]
  pipedFrom?: string[]
  heredocs?: Fed
  xargs?: true
  found?: string[]
  language?: Lang
  program?: Program
  script?: Script
  verdict?: CodeVerdict
  substitution?: true
}

/**
 * A command line as readLine reads it: each command, and in its place the commands of each
 * substitution the shell runs (`sub`), kept together so a reader that scopes what happens inside one
 * (the write reader: a cd inside one ends with it) can tell where it ends. `pipeline` flattens it.
 */
export type Line = (Command | { sub: Line })[]

// What feeds the commands of one read: the command a | feeds them from, what is on their standard
// input, and whether xargs runs them, each given to every command no | of its own feeds.
type Feed = { pipedFrom?: string[]; stdin?: Stdin; xargs?: boolean; found?: string[] }

// A command's output redirects that name a file, each with its target: `> f`, `>> f`, `>| f`,
// `&> f`, `2> f`, and a `>&` whose target is no descriptor. A descriptor copy (2>&1) names none.
const OWN_REDIRECT = /^(?:\d*>>?\|?|&>>?)$/
const ownRedirects = (words: readonly string[]): string[] => {
  const out: string[] = []
  for (let i = 1; i < words.length; i++) {
    const w = words[i] as string
    const target = words[i + 1]
    if (target === undefined) continue
    if (OWN_REDIRECT.test(w) || (/^\d*>&$/.test(w) && !/^(?:\d+|-)$/.test(target))) {
      out.push(w, target)
      i++
    }
  }
  return out
}

// One command, with what it runs. A shell whose script can be read is read as the commands it runs
// (a -c always was; since #712 a heredoc, a here-string, or what echo, printf or cat pipes in too),
// each reading what feeds the shell (#730: a heredoc or here-string feeding a -c), unless the shell
// reads its script there, when what they read is the rest of that script. What a find -exec runs
// is read after it, as a command of its own.
const emit = (words: string[], fed: Fed, feed: Feed, out: Line, opts: ReadOptions) => {
  const stdin = ownStdin(words, fed) ?? feed.stdin
  const kind = kindOf(words[0])
  const { program, script } = kind ? readProgram(words, stdin) : {}
  if (kind === 'shell' && program && 'text' in program) {
    const inner: Feed = program.stdin ? { stdin: { unreadable: 'fed the rest of the script the shell reads' } } : { pipedFrom: feed.pipedFrom, stdin }
    out.push(...readLine(program.text, opts, { ...inner, ...(feed.xargs ? { xargs: true } : {}), ...(feed.found ? { found: feed.found } : {}) }))
    // The shell's own output redirects send everything its script prints to a file, which the
    // script's commands never name (#760: `bash -c 'make' > build.log` wrote a build.log no reader
    // saw). They are given as a command of their own, the shell and those redirects, so every
    // reader of redirects sees the file.
    const own = ownRedirects(words)
    if (own.length) out.push({ words: [words[0] as string, ...own], ...(feed.xargs ? { xargs: true as const } : {}), ...(feed.found ? { found: feed.found } : {}) })
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
    ...(feed.found ? { found: feed.found } : {}),
    ...(language ? { language } : {}),
    ...(program ? { program } : {}),
    ...(script ? { script } : {}),
    ...(verdict ? { verdict } : {}),
  })
  // Its {} stands for each thing find finds, which this reader writes as the folder find starts
  // from, so the command carries those folders as `found`: what it changes at one of them is that
  // folder and everything under it (#760: `find src -exec rm {} \;` was read as removing src alone),
  // and a path it names itself is that path alone.
  const roots = findRoots(words)
  for (const inner of execsOf(words)) {
    const b = begins(inner, inner.map(() => -1))
    if (b.words.length) emit(b.words, [], { ...(b.xargs ? { xargs: true } : {}), found: roots }, out, opts)
  }
}

/**
 * Each simple command a Bash call would run, with what a pipe feeds it, the body of each heredoc
 * that feeds it, and what it runs, if anything, as `readLine` reads them, flattened: the commands of
 * each command substitution the shell runs (#974) come before the command they sit in, each marked
 * `substitution`. A heredoc inside a word ("$(cat <<'EOF' ... )") feeds the command inside the
 * substitution, never the one the word is in, and one that never ends has no body: its lines are
 * read as commands. `opts` asks for more than the commands that run (ReadOptions).
 */
export const pipeline = (cmd: string, opts: ReadOptions = {}): Command[] => flatten(readLine(cmd, opts))
const flatten = (line: Line, inside = false): Command[] => line.flatMap(c => ('sub' in c ? flatten(c.sub, true) : [inside ? { ...c, substitution: true as const } : c]))

/**
 * A command line read as its commands, each command substitution the shell runs in it given in its
 * place as the commands it runs (Line), read as a command line of its own, so one nested inside it
 * is read too (#974). The shell runs a substitution before the command it sits in: one in the
 * command's words (never inside single quotes, $'...' or a comment), and one in the body of a
 * heredoc feeding it whose delimiter is unquoted, a body that never ends included (#965). A
 * substitution reads what the line's own commands are fed from outside it. `outer` is what feeds
 * the commands of a shell's script, read as the commands it runs.
 */
export const readLine = (cmd: string, opts: ReadOptions = {}, outer: Feed = {}): Line => {
  const out: Line = []
  const { text, heredocs, unended } = dropHeredocs(cmd)
  const heredocAt = new Map(heredocs.map(h => [h.at, h]))
  const read = split(text)
  const begun = read.map(r => begins(r.words, r.starts))
  // Each substitution, by the command it sits in: the last one starting at or before it.
  const ran = new Map<number, string[]>()
  const place = (at: number, sub: string) => {
    let k = 0
    read.forEach((r, j) => {
      if ((r.starts[0] ?? 0) <= at) k = j
    })
    ran.set(k, [...(ran.get(k) ?? []), sub])
  }
  for (const s of substitutions(text, false)) place(s.at, s.text)
  for (const h of [...heredocs, ...(unended ? [unended] : [])]) if (!h.quoted) for (const s of substitutions(h.body, true)) place(h.at, s.text)
  const subFeed: Feed = { ...(outer.pipedFrom ? { pipedFrom: outer.pipedFrom } : {}), ...(outer.stdin ? { stdin: outer.stdin } : {}) }
  const runSubs = (k: number) => {
    for (const s of ran.get(k) ?? []) out.push({ sub: readLine(s, opts, subFeed) })
  }
  const fedOf = (b: Begun): Fed => {
    const fed: Fed = []
    // The last redirect onto standard input is what the command reads there, as in the shell: a
    // heredoc before it is replaced (#760, lessons review of #818).
    let lastStdin = -1
    b.words.forEach((w, n) => {
      if (onStdin(w)) lastStdin = n
    })
    b.words.forEach((w, n) => {
      const m = HEREDOC_WORD.exec(w)
      const at = b.starts[n] ?? -1
      const h = m && at >= 0 ? heredocAt.get(at + (m[1] as string).length) : undefined
      // A heredoc on another descriptor (3<<EOF) says which, so a reader of standard input can
      // tell it is not what the command reads there (#760).
      const fd = m && !onStdin(w) ? { fd: Number(m[1]) } : {}
      const replaced = m && onStdin(w) && n !== lastStdin ? { replaced: true as const } : {}
      if (h !== undefined) fed.push({ word: n, body: h.body, quoted: h.quoted, ...fd, ...replaced })
    })
    return fed
  }
  read.forEach((r, k) => {
    runSubs(k)
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
    if (outer.found) feed = { ...feed, found: outer.found }
    emit(b.words, fedOf(b), feed, out, opts)
  })
  return out
}

// Command substitutions (#965, #974). The shell runs the commands inside a $(...) or backticks
// before the command they sit in, and in a heredoc whose delimiter is not quoted, before the program
// fed that body starts: so `python3 - <<EOF` whose body held `$(cat rules.md >> ~/.claude/CLAUDE.md)`
// wrote lasting memory, and `echo $(git push)` pushed, while the reader, which drops a heredoc's
// body as text and kept a substitution inside the word it is in, gave neither.

// Where the ) closing a $( whose text starts at `from` stands, read as the shell reads that text: a
// quote, a backslash, a backtick or a comment holds a ) that closes nothing. -1 when none closes
// it, the text ending first. A case pattern's ) is taken for the close (`$(case x in a) ...)`): the
// text after it is not read as run.
const closing = (text: string, from: number): number => {
  let depth = 1
  for (let i = from; i < text.length; i++) {
    const c = text[i] as string
    if (c === '\\') i++
    else if (c === "'") {
      i = text.indexOf("'", i + 1)
      if (i < 0) return -1
    } else if (c === '"') {
      for (i++; i < text.length && text[i] !== '"'; i++) {
        if (text[i] === '\\') i++
        else if (text[i] === '`') i = tickEnd(text, i + 1)
        else if (text[i] === '$' && text[i + 1] === '(') i = closing(text, i + 2)
        if (i < 0) return -1
      }
      if (i >= text.length) return -1
    } else if (c === '`') {
      i = tickEnd(text, i + 1)
      if (i < 0) return -1
    } else if (c === '#' && commentAt(text, i, from)) {
      i = text.indexOf('\n', i)
      if (i < 0) return -1
    } else if (c === '(') depth++
    else if (c === ')' && --depth === 0) return i
  }
  return -1
}
// Where the backtick closing one whose text starts at `from` stands, -1 when none does.
const tickEnd = (text: string, from: number): number => {
  for (let i = from; i < text.length; i++) {
    if (text[i] === '\\') i++
    else if (text[i] === '`') return i
  }
  return -1
}
// A # begins a comment only where a word would begin.
const commentAt = (text: string, i: number, start = 0) => i === start || /[\s;&|()]/.test(text[i - 1] as string)

/**
 * Each command substitution the shell runs in `text`: its text and where its $ or backtick stands,
 * outermost only (each is read as a command line of its own, which reads any inside it). In a
 * heredoc's body (`body`) a quote is text and only a backslash before $, a backtick or a backslash
 * escapes it; elsewhere nothing inside single quotes, $'...' or a comment runs. A $(( closed by ))
 * is arithmetic, which runs only the substitutions inside it; one closed otherwise is a command. A
 * substitution never closed, its body ending early, is read to the end of the text, the side that
 * asks rather than passes. Inside backticks a backslash before $, a backtick or a backslash stands
 * for that character.
 */
export const substitutions = (text: string, body: boolean): { text: string; at: number }[] => {
  const out: { text: string; at: number }[] = []
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i] as string
    if (c === '\\') {
      i++
      continue
    }
    if (!body && !quoted) {
      if (c === "'" || (c === '$' && text[i + 1] === "'")) {
        // $'...' takes a backslash escape inside; '...' takes none.
        const ansi = c === '$'
        let j = ansi ? i + 2 : i + 1
        for (; j < text.length && text[j] !== "'"; j++) if (ansi && text[j] === '\\') j++
        i = j
        continue
      }
      if (c === '#' && commentAt(text, i)) {
        const nl = text.indexOf('\n', i)
        i = nl < 0 ? text.length : nl
        continue
      }
    }
    if (!body && c === '"') {
      quoted = !quoted
      continue
    }
    if (c === '$' && text[i + 1] === '(') {
      const inner = text[i + 2] === '(' ? closing(text, i + 3) : -1
      if (inner >= 0 && text[inner + 1] === ')') {
        const from = i + 3
        out.push(...substitutions(text.slice(from, inner), false).map(s => ({ text: s.text, at: from + s.at })))
        i = inner + 1
        continue
      }
      const end = closing(text, i + 2)
      out.push({ text: text.slice(i + 2, end < 0 ? text.length : end), at: i })
      i = end < 0 ? text.length : end
    } else if (c === '`') {
      const end = tickEnd(text, i + 1)
      out.push({ text: text.slice(i + 1, end < 0 ? text.length : end).replace(/\\([$`\\])/g, '$1'), at: i })
      i = end < 0 ? text.length : end
    }
  }
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
