// The program a shell or interpreter runs when it is not a script file (#702): code given inline,
// or read from standard input. Read from the words mod-kit's reader hands over, so this mod keeps
// no reader of its own (L613): a heredoc arrives as its `<<EOF` word with the body dropped, a
// here-string as one `<<<text` word, and a pipe as the words of the command it feeds from, which
// only the reader can tell from a list's ; or && (#724).
//
// The milestone audit found no build let `python3 - <<'EOF'` and `cat <<EOF | sh` write files,
// because the reader drops the body. A body the reader dropped cannot be judged, so it is said to
// be unreadable, as psql fed a heredoc already is; text the reader kept is handed back to be judged.

/** What a command runs as its program: the text, or why it cannot be read. */
export type Program = { text: string } | { unreadable: string }

/** The languages whose inline code no build judges (code.ts), and a shell, whose program is more commands. */
export type Lang = 'python' | 'node' | 'ruby' | 'perl' | 'osascript' | 'awk' | 'sed'
type Kind = Lang | 'shell' | 'deno'

const base = (p: string) => p.split('/').pop() ?? p
const kindOf = (w: string | undefined): Kind | undefined => {
  const n = base(w ?? '')
  if (['sh', 'bash', 'zsh', 'dash', 'ksh'].includes(n)) return 'shell'
  if (/^python(?:\d+(?:\.\d+)*)?$/.test(n)) return 'python'
  // bun takes node's flags for inline code.
  if (n === 'node' || n === 'nodejs' || n === 'bun') return 'node'
  if (n === 'gawk' || n === 'mawk' || n === 'nawk') return 'awk'
  if (n === 'gsed') return 'sed'
  if (['ruby', 'perl', 'osascript', 'deno', 'awk', 'sed'].includes(n)) return n as Kind
  return undefined
}

/** The language a command runs inline code in (deno runs JavaScript, as node does), or undefined. */
export const languageOf = (words: readonly string[]): Lang | undefined => {
  const k = kindOf(words[0])
  return k === 'deno' ? 'node' : k === 'shell' ? undefined : k
}

/** Whether a command is a shell, whose program is more commands. */
export const isShell = (words: readonly string[]): boolean => kindOf(words[0]) === 'shell'

// Each language's own single letter options, which is how its inline code is found (lessons
// review of #714 at fad450f: a pattern over the whole flag word read ruby's -rtime and perl's
// -Mfeature as -e). In a cluster such as `-lane`, letters are read left to right:
//   inline  gives code: the rest of the cluster, or the next word when the cluster ends with it
//   file    gives a file holding the program (awk -f, sed -f), which cannot be read here
//   value   takes a value: the rest of the cluster, or the next word
//   rest    takes only what is attached: the rest of the cluster (perl -i.bak, ruby -W2)
//   digits  takes only the digits attached (perl -l and -0, ruby -0), so -lane is -l -a -n -e
// Any other letter takes nothing. A shell's -c gives no value of its own: its program is the
// first word after the options, wherever c stands in the cluster.
type Grammar = { inline: string; file: string; value: string; rest: string; digits: string }
const GRAMMAR: Record<Exclude<Kind, 'deno'>, Grammar> = {
  shell: { inline: '', file: '', value: 'oO', rest: '', digits: '' },
  python: { inline: 'c', file: '', value: 'WXm', rest: '', digits: '' },
  node: { inline: 'ep', file: '', value: 'rC', rest: '', digits: '' },
  ruby: { inline: 'e', file: '', value: 'IrECF', rest: 'xKTWi', digits: '0' },
  perl: { inline: 'eE', file: '', value: 'IMm', rest: 'xidDCF', digits: 'l0' },
  osascript: { inline: 'e', file: '', value: 'ls', rest: '', digits: '' },
  awk: { inline: 'e', file: 'fE', value: 'vFil', rest: '', digits: '' },
  sed: { inline: 'e', file: 'f', value: 'l', rest: 'i', digits: '' },
}
// The long options that give code, a program file, or a value in the next word.
const LONG: Partial<Record<Kind, { inline?: string[]; file?: string[]; value?: string[] }>> = {
  node: { inline: ['--eval', '--print'], value: ['--require', '--import', '--loader', '--experimental-loader', '--conditions', '--input-type', '--env-file', '--title'] },
  python: { value: ['--check-hash-based-pycs'] },
  awk: { inline: ['--source'], file: ['--file', '--exec'], value: ['--assign', '--include', '--field-separator', '--load'] },
  sed: { inline: ['--expression'], file: ['--file'], value: ['--line-length'] },
  shell: { value: ['--rcfile', '--init-file'] },
}

// An output redirect as the reader splits it, its target in the same word or the next.
const REDIRECT = /^(?:\d*|&)>>?\|?(.*)$/
const isHeredoc = (w: string) => /^\d*<</.test(w) && !/^\d*<<</.test(w)

/** One command as mod-kit's reader hands it over: its words, and those of the command a | feeds it from. */
export type Read = { words: readonly string[]; pipedFrom?: readonly string[] }

/** What a pipe feeds a command's standard input from `feeder`, or undefined when no pipe does. */
const piped = (feeder: readonly string[] | undefined): Program | undefined => {
  if (!feeder?.length) return undefined
  // A subshell's output, which the reader hands over as its closing parenthesis.
  if (feeder[0] === ')') return { unreadable: 'fed by what a subshell pipes into it' }
  const name = base(feeder[0] as string)
  const args = feeder.slice(1)
  if (args.some(isHeredoc)) return { unreadable: 'fed by a heredoc' }
  if (name === 'echo' || name === 'printf') return { text: args.filter(a => !/^-[neE]+$/.test(a)).join(' ') }
  // cat of files feeds those files, as a script file is: nothing for this guard to read.
  if (name === 'cat' && args.some(a => !a.startsWith('-'))) return undefined
  return { unreadable: `fed by what ${name} pipes into it` }
}

// What a command runs as its program, or, where that is a file, which file: a script file named
// as its operand, or one its standard input is redirected from (#724: away never saw
// `osascript notify.scpt`, a script it cannot read).
type Reading = { program?: Program; file?: string }
const readProgram = (words: readonly string[], feeder: readonly string[] | undefined): Reading => {
  const kind = kindOf(words[0])
  if (!kind) return {}
  // deno runs inline code as `deno eval <code>`, and a script with `deno run`.
  if (kind === 'deno') return words[1] === 'eval' ? { program: { text: words[2] ?? '' } } : {}
  const g = GRAMMAR[kind]
  const long = LONG[kind] ?? {}
  // python and a shell run their first inline program, the words after it its arguments; every
  // other language runs every one given, so each is judged.
  const firstOnly = kind === 'python' || kind === 'shell'
  // awk and sed take their program as the first word that is no option, when no -e gave it.
  const programWord = kind === 'awk' || kind === 'sed'
  let operand: string | undefined
  let fromStdin = false
  let shellC = false
  let fed: Program | undefined
  let fromFile: string | undefined
  let programFile = false
  const inline: string[] = []
  const operands: string[] = []
  for (let i = 1; i < words.length; i++) {
    const a = words[i] as string
    if (/^\d*<<</.test(a)) {
      fed = { text: a.replace(/^\d*<<</, '') || (words[++i] ?? '') }
      continue
    }
    if (isHeredoc(a)) {
      fed = { unreadable: 'fed by a heredoc' }
      if (/^\d*<<-?$/.test(a)) i++
      continue
    }
    if (/^\d*</.test(a)) {
      fromFile = a.replace(/^\d*</, '') || (words[++i] ?? '')
      continue
    }
    const r = REDIRECT.exec(a)
    if (r) {
      if (!r[1]) i++
      continue
    }
    // Everything after the script file is that script's own arguments; awk and sed take files.
    if (operand !== undefined) {
      if (programWord) operands.push(a)
      continue
    }
    if (a === '-') {
      operand = a
      continue
    }
    if (a === '--') {
      // Past the end of the flags: a shell given -s reads its program from stdin, its words being
      // arguments; anything else names its script next.
      if (fromStdin) break
      continue
    }
    if (a.startsWith('--')) {
      const eq = a.indexOf('=')
      const name = eq < 0 ? a : a.slice(0, eq)
      const attached = eq < 0 ? undefined : a.slice(eq + 1)
      if (long.inline?.includes(name)) {
        const code = attached ?? words[++i] ?? ''
        if (firstOnly) return { program: { text: code } }
        inline.push(code)
      } else if (long.file?.includes(name)) {
        programFile = true
        if (attached === undefined) i++
      } else if (long.value?.includes(name) && attached === undefined) i++
      continue
    }
    if (a.startsWith('-') || (kind === 'shell' && a.startsWith('+'))) {
      for (let j = 1; j < a.length; j++) {
        const letter = a[j] as string
        const rest = a.slice(j + 1)
        if (kind === 'shell') {
          if (letter === 'c') shellC = true
          else if (letter === 's') fromStdin = true
          else if (g.value.includes(letter)) {
            if (!rest) i++
            break
          }
          continue
        }
        if (g.inline.includes(letter)) {
          // node's -e and -p take the next word, never what is attached, so -pe is -p then -e.
          const attachedCode = kind === 'node' && /^[ep]*$/.test(rest) ? '' : rest
          const code = attachedCode || (words[++i] ?? '')
          if (firstOnly) return { program: { text: code } }
          inline.push(code)
          break
        }
        if (g.file.includes(letter)) {
          programFile = true
          if (!rest) i++
          break
        }
        if (g.value.includes(letter)) {
          // python -m runs a module, which is no program here, as a script file is not.
          if (kind === 'python' && letter === 'm') return {}
          if (!rest) {
            // macOS sed -i takes its suffix as its own word, an empty one arriving as ''.
            i++
          }
          break
        }
        if (g.rest.includes(letter)) {
          if (kind === 'sed' && letter === 'i' && !rest && (words[i + 1] === '' || /^\./.test(words[i + 1] ?? ''))) i++
          break
        }
        if (g.digits.includes(letter)) {
          const digits = /^(?:x[0-9a-fA-F]*|[0-7]*)/.exec(rest)?.[0] ?? ''
          j += digits.length
        }
      }
      continue
    }
    operand = a
  }
  if (programFile) return { program: { unreadable: 'its program is in a file' } }
  // Inline code is the program; the words after it are its data files.
  if (inline.length) return { program: { text: inline.join('\n') } }
  if (kind === 'shell' && shellC) return operand !== undefined ? { program: { text: operand } } : {}
  if (programWord) return operand !== undefined ? { program: { text: operand } } : {}
  if (operand !== undefined && operand !== '-' && !fromStdin) return { file: operand }
  if (fed) return { program: fed }
  if (fromFile !== undefined) return { file: fromFile }
  const p = piped(feeder)
  return p ? { program: p } : {}
}
const programOf = (words: readonly string[], feeder: readonly string[] | undefined): Program | undefined => readProgram(words, feeder).program

/** The script file an interpreter runs, named as its operand or redirected into it, or undefined. */
export const scriptFileOf = (words: readonly string[]): string | undefined => readProgram(words, undefined).file

/**
 * Each command's program. Only a | feeds a command what another prints: the command before it in
 * a list joined by ;, && or a new line feeds it nothing (#724: `cd repo && python3 --version` was
 * refused as a script fed by cd).
 */
export const programsOf = (commands: readonly Read[]): (Program | undefined)[] => commands.map(c => programOf(c.words, c.pipedFrom))

/**
 * The commands a `find -exec` (or `-execdir`, `-ok`, `-okdir`) runs, up to its `;` or `+`, once
 * for each folder find starts from (`.` when it names none), that folder standing for `{}`. The
 * tool call hook reads each as it reads a command of its own, git reading and program included,
 * so `find . -exec git checkout {} ;` and `-exec sh -c '...'` are judged (lessons review of #714).
 */
export const execsOf = (words: readonly string[]): string[][] => {
  if (base(words[0] ?? '') !== 'find') return []
  const args = words.slice(1)
  const firstExpr = args.findIndex(a => a.startsWith('-') || a === '(' || a === '!')
  const roots = firstExpr < 0 ? args : args.slice(0, firstExpr)
  const starts = roots.length ? roots : ['.']
  const out: string[][] = []
  for (let i = 0; i < args.length; i++) {
    if (!['-exec', '-execdir', '-ok', '-okdir'].includes(args[i] as string)) continue
    const end = args.findIndex((w, j) => j > i && (w === ';' || w === '+'))
    const inner = args.slice(i + 1, end < 0 ? args.length : end)
    // GNU find puts the path wherever {} stands in a word, not only where it stands alone.
    if (inner.length) for (const root of starts) out.push(inner.map(w => w.split('{}').join(root)))
    i = end < 0 ? args.length : end
  }
  return out
}
