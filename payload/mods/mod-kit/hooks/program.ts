// The program a shell or interpreter runs (#702, moved here from scope-modes in #712 so it is read
// once, by the one reader, L613): code given inline, a script file, or what its standard input
// gives it. The reader (commands.ts) works out what feeds each command's standard input, a heredoc's
// body, a here-string, a file, or the command a | feeds it from, and hands it in as `stdin`; this
// reads each language's own options to find which of those is the program.

/** The languages whose inline code is judged (code.ts). */
export type Lang = 'python' | 'node' | 'ruby' | 'perl' | 'osascript' | 'awk' | 'sed'
/** A command's program: its text (`stdin` when it came on standard input), or why it cannot be read. */
export type Program = { text: string; stdin?: true } | { unreadable: string }
/** A file a command runs as its program, named as its operand, or fed on standard input. */
export type Script = { files: string[]; stdin?: true }
/** What a command's standard input holds: text, something that cannot be read, or files. */
export type Stdin = { text: string } | { unreadable: string } | { files: string[] }

type Kind = Lang | 'shell' | 'deno'

/** The shells whose script is read as the commands it runs. */
export const SHELLS: ReadonlySet<string> = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh'])

const base = (p: string) => p.split('/').pop() ?? p
// A versioned name is the interpreter too (#712 from #726: python3.12, /usr/local/bin/python3.11,
// node20 and perl5.34 ran inline code unread, an exact name list knowing none of them).
const VERSION = '(?:\\d+(?:\\.\\d+)*)?'
const NAMES: [RegExp, Kind][] = [
  [new RegExp(`^python${VERSION}$`), 'python'],
  [new RegExp(`^(?:node|nodejs)${VERSION}$`), 'node'],
  // bun takes node's flags for inline code.
  [/^bun$/, 'node'],
  [new RegExp(`^ruby${VERSION}$`), 'ruby'],
  [new RegExp(`^perl${VERSION}$`), 'perl'],
  [/^osascript$/, 'osascript'],
  [/^(?:awk|gawk|mawk|nawk)$/, 'awk'],
  [/^g?sed$/, 'sed'],
  [/^deno$/, 'deno'],
]
export const kindOf = (w: string | undefined): Kind | undefined => {
  const n = base(w ?? '')
  if (SHELLS.has(n)) return 'shell'
  return NAMES.find(([re]) => re.test(n))?.[1]
}

/** The language a command runs inline code in (deno runs JavaScript, as node does), or undefined. */
export const languageOf = (kind: Kind | undefined): Lang | undefined => (kind === 'deno' ? 'node' : kind === 'shell' ? undefined : kind)

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

// A redirect as the reader splits it, its target in the same word or the next: output, input, a
// heredoc (its delimiter next when spaced), a here-string. What feeds standard input is read by the
// reader, so here each is only stepped over.
const OUTPUT = /^(?:\d*|&)>>?\|?&?(.*)$/
const INPUT = /^\d*(?:<<<|<<-?|<)(.*)$/

/** What a command runs as its program or script file, by its language's options, given what its standard input holds. */
export type Reading = { program?: Program; script?: Script }
export const readProgram = (words: readonly string[], stdin: Stdin | undefined): Reading => {
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
  // The files holding the program (awk -f, sed -f), which cannot be read here.
  const programFiles: string[] = []
  const inline: string[] = []
  for (let i = 1; i < words.length; i++) {
    const a = words[i] as string
    const input = INPUT.exec(a)
    if (input && !a.startsWith('<(')) {
      if (!input[1]) i++
      continue
    }
    const out = OUTPUT.exec(a)
    if (out) {
      if (!out[1]) i++
      continue
    }
    // Everything after the script file is that script's own arguments; awk and sed take files.
    if (operand !== undefined) continue
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
        programFiles.push(attached ?? words[++i] ?? '')
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
          programFiles.push(rest || (words[++i] ?? ''))
          break
        }
        if (g.value.includes(letter)) {
          // python -m runs a module, which is no program here, as a script file is not.
          if (kind === 'python' && letter === 'm') return {}
          // macOS sed -i takes its suffix as its own word, an empty one arriving as ''.
          if (!rest) i++
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
  if (programFiles.length) return { program: { unreadable: 'its program is in a file' }, script: { files: programFiles } }
  // Inline code is the program; the words after it are its data files.
  if (inline.length) return { program: { text: inline.join('\n') } }
  if (kind === 'shell' && shellC) return operand !== undefined ? { program: { text: operand } } : {}
  if (programWord) return operand !== undefined ? { program: { text: operand } } : {}
  if (operand !== undefined && operand !== '-' && !fromStdin) return { script: { files: [operand] } }
  // What standard input holds is the program: a heredoc's body, text, a file, or what cannot be read.
  if (!stdin) return {}
  if ('text' in stdin) return { program: { text: stdin.text, stdin: true } }
  if ('files' in stdin) return { script: { files: stdin.files, stdin: true } }
  return { program: { unreadable: stdin.unreadable } }
}

/** The folders a find starts from, which its -exec's {} is written as: `.` when it names none. */
export const findRoots = (words: readonly string[]): string[] => {
  if (base(words[0] ?? '') !== 'find') return []
  const args = words.slice(1)
  const firstExpr = args.findIndex(a => a.startsWith('-') || a === '(' || a === '!')
  const roots = firstExpr < 0 ? args : args.slice(0, firstExpr)
  return roots.length ? roots : ['.']
}
/**
 * The commands a `find -exec` (or `-execdir`, `-ok`, `-okdir`) runs, up to its `;` or `+`, once for
 * each folder find starts from (`.` when it names none), that folder standing for `{}`. The reader
 * reads each as a command of its own, so its runners are looked past and its program read (lessons
 * review of #714; #730: a wrapper in front of it hid the command).
 */
export const execsOf = (words: readonly string[]): string[][] => {
  if (base(words[0] ?? '') !== 'find') return []
  const args = words.slice(1)
  const starts = findRoots(words)
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
