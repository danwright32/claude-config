// The one reader of shell commands every mod uses (L613): each simple command a Bash call would
// run, as its words with quotes removed, judged in command position (L673). Lessons review findings
// on the guards built it up: a heredoc body is text, a here-string is not a heredoc, a heredoc that
// never ends is judged after all, and the words that only run the next command are looked past.

const RUNNERS = new Set(['sudo', 'env', 'command', 'exec', 'nohup', 'time', 'nice'])
const SHELLS = new Set(['sh', 'bash', 'zsh'])
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/

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

// Words, split on separators outside quotes. A quoted script spanning lines stays one word.
const split = (cmd: string): string[][] => {
  const cmds: string[][] = []
  let words: string[] = []
  let word = ''
  let inWord = false
  let quote: '"' | "'" | undefined
  // Parentheses opened inside a word ($(, <(, $((), whose closing ones belong to the word too.
  let wordParens = 0
  const endWord = () => {
    if (inWord) words.push(word)
    word = ''
    inWord = false
  }
  const endCmd = () => {
    endWord()
    if (words.length) cmds.push(words)
    words = []
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
      cmds.push([c])
    } else if (c === ';' || c === '|' || c === '&' || c === '\n') endCmd()
    else if (c === ' ' || c === '\t') endWord()
    else {
      word += c
      inWord = true
    }
  }
  endCmd()
  return cmds
}

// Past assignments and the words that only run the next command (sudo cat .env is cat .env). A
// runner with no command after it (a bare env) is the command itself.
const strip = (words: string[]): string[] => {
  let i = 0
  for (;;) {
    const w = words[i] ?? ''
    if (ASSIGNMENT.test(w)) i++
    else if (RUNNERS.has(w) && words.slice(i + 1).some(x => !x.startsWith('-') && !ASSIGNMENT.test(x))) {
      i++
      while ((words[i] ?? '').startsWith('-')) i++
    } else break
  }
  return words.slice(i)
}

export const commands = (cmd: string): string[][] => {
  const out: string[][] = []
  for (const raw of split(dropHeredocs(cmd))) {
    const words = strip(raw)
    if (words.length === 0) continue
    const name = (words[0] as string).split('/').pop() ?? ''
    const c = words.indexOf('-c')
    // A command run through a shell's -c is read as the commands it runs.
    if (SHELLS.has(name) && c > 0 && words[c + 1] !== undefined) {
      out.push(...commands(words[c + 1] as string))
      continue
    }
    out.push(words)
  }
  return out
}

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
