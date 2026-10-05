// The program a shell or interpreter runs when it is not a script file (#702): code given inline,
// or read from standard input. Read from the words mod-kit's reader hands over, so this mod keeps
// no reader of its own (L613): a heredoc arrives as its `<<EOF` word with the body dropped, a
// here-string as one `<<<text` word, and a pipe as a separator between two commands.
//
// The milestone audit found no build let `python3 - <<'EOF'` and `cat <<EOF | sh` write files,
// because the reader drops the body. A body the reader dropped cannot be judged, so it is said to
// be unreadable, as psql fed a heredoc already is; text the reader kept is handed back to be judged.

/** What a command runs as its program: the text, or why it cannot be read. */
export type Program = { text: string } | { unreadable: string }

type Kind = 'shell' | 'python' | 'node' | 'ruby' | 'perl' | 'osascript' | 'deno'

const base = (p: string) => p.split('/').pop() ?? p
const kindOf = (w: string | undefined): Kind | undefined => {
  const n = base(w ?? '')
  if (['sh', 'bash', 'zsh', 'dash', 'ksh'].includes(n)) return 'shell'
  if (/^python(?:\d+(?:\.\d+)*)?$/.test(n)) return 'python'
  // bun takes node's flags for inline code.
  if (n === 'node' || n === 'nodejs' || n === 'bun') return 'node'
  if (n === 'ruby' || n === 'perl' || n === 'osascript' || n === 'deno') return n
  return undefined
}

/** The interpreter a command names (`python3`, `node`), or undefined for a shell or anything else. */
export const interpreterOf = (words: readonly string[]): string | undefined => {
  const k = kindOf(words[0])
  return k && k !== 'shell' && k !== 'osascript' ? base(words[0] as string) : undefined
}

/** Whether a command is a shell, whose program is more commands. */
export const isShell = (words: readonly string[]): boolean => kindOf(words[0]) === 'shell'

// A flag that gives the program inline, as the next word: alone (`-c`) or in a cluster of single
// letter flags (`bash -lc`, `python3 -Bc`, `perl -ne`). mod-kit reads `bash -c` itself, so a shell
// reaches here only through a cluster, where -c may stand anywhere (`bash -ce`).
const INLINE: Record<Kind, RegExp> = {
  shell: /^-[A-Za-z]*c[A-Za-z]*$/,
  python: /^-[A-Za-z]*c$/,
  node: /^(?:-e|--eval|-p|--print)$/,
  ruby: /^-[A-Za-z]*e$/,
  perl: /^-[A-Za-z]*[eE]$/,
  osascript: /^-e$/,
  deno: /^$/,
}
const INLINE_ATTACHED = /^--(?:eval|print)=/
// Flags taking the next word as their value, so the value is never read as a script file.
const VALUE_FLAGS: Record<Kind, readonly string[]> = {
  shell: ['-o', '-O', '+o', '+O'],
  python: ['-W', '-X'],
  node: ['-r', '--require', '--import', '--loader', '--experimental-loader', '-C', '--conditions', '--input-type'],
  ruby: ['-I', '-r', '-E', '-C', '-F'],
  perl: ['-I', '-M', '-m'],
  osascript: ['-l', '-s'],
  deno: [],
}
// An output redirect as the reader splits it, its target in the same word or the next.
const REDIRECT = /^(?:\d*|&)>>?\|?(.*)$/
const isHeredoc = (w: string) => /^\d*<</.test(w) && !/^\d*<<</.test(w)

/** What feeds a command's standard input from the command before it, or undefined when nothing does. */
const piped = (prev: readonly string[] | undefined): Program | undefined => {
  if (!prev?.length) return undefined
  const name = base(prev[0] as string)
  const args = prev.slice(1)
  if (args.some(isHeredoc)) return { unreadable: 'fed by a heredoc' }
  if (name === 'echo' || name === 'printf') return { text: args.filter(a => !/^-[neE]+$/.test(a)).join(' ') }
  // cat of files feeds those files, as a script file is: nothing for this guard to read.
  if (name === 'cat' && args.some(a => !a.startsWith('-'))) return undefined
  return { unreadable: `fed by what ${name} pipes into it` }
}

const programOf = (words: readonly string[], prev: readonly string[] | undefined): Program | undefined => {
  const kind = kindOf(words[0])
  if (!kind) return undefined
  // deno runs inline code as `deno eval <code>`, and a script with `deno run`.
  if (kind === 'deno') return words[1] === 'eval' ? { text: words[2] ?? '' } : undefined
  let operand: string | undefined
  let fromStdin = false
  let fed: Program | undefined
  let fromFile = false
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
      fromFile = true
      if (/^\d*<$/.test(a)) i++
      continue
    }
    const r = REDIRECT.exec(a)
    if (r) {
      if (!r[1]) i++
      continue
    }
    // Everything after the script file is that script's own arguments.
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
    if (a.startsWith('-') || (kind === 'shell' && a.startsWith('+'))) {
      if (kind === 'python' && /^-[A-Za-z]*m$/.test(a)) return undefined
      if (INLINE[kind].test(a)) return { text: words[i + 1] ?? '' }
      if (kind === 'node' && INLINE_ATTACHED.test(a)) return { text: a.replace(INLINE_ATTACHED, '') }
      if (kind === 'shell' && /^-[A-Za-z]*s[A-Za-z]*$/.test(a)) fromStdin = true
      if (VALUE_FLAGS[kind].includes(a)) i++
      continue
    }
    operand = a
  }
  if (operand !== undefined && operand !== '-' && !fromStdin) return undefined
  if (fed) return fed
  if (fromFile) return undefined
  return piped(prev)
}

/**
 * Each command's program, by its place in the list a single read of a command line gave: the
 * command before a reader is what a pipe feeds it, so the list must be one read's, in order.
 */
export const programsOf = (commands: readonly (readonly string[])[]): (Program | undefined)[] =>
  commands.map((words, i) => programOf(words, i > 0 ? commands[i - 1] : undefined))
