// The keystroke guard's rules, apart from the hooks (claude-config#608). Wording settled with Dan
// on 2026-10-03 (docs/mods-design.md).

export type Classified = { kind: 'input' | 'focus' | 'none'; target?: string; app?: string }
export type Refusal = { reason: string; safeWay?: string }

const MARKER = /\bTARGET_APP=(?:"([^"]+)"|'([^']+)'|(\S+))/

// Commands are judged in COMMAND POSITION only (L673). Matching the words anywhere refused a
// heredoc that merely wrote a file mentioning an osascript keystroke, on 2026-10-03, while this
// guard's own author was building the design rounds.
//
// A heredoc body is text, not commands, so it is dropped before anything else is read: left in, an
// apostrophe in it would open a quote that swallows the commands after it.
const dropHeredocs = (cmd: string): string => {
  const lines = cmd.split('\n')
  const out: string[] = []
  let end: string | undefined
  for (const line of lines) {
    if (end !== undefined) {
      if (line.trim() === end) end = undefined
      continue
    }
    out.push(line)
    const m = /<<-?\s*(?:'([^']+)'|"([^"]+)"|\\?([A-Za-z_][A-Za-z0-9_]*))/.exec(line)
    if (m) end = m[1] ?? m[2] ?? m[3]
  }
  return out.join('\n')
}

// Simple commands, split on separators outside quotes, each as its words with quotes removed. A
// quoted AppleScript spanning several lines stays one word, so a keystroke inside it is seen.
const simpleCommands = (cmd: string): string[][] => {
  const cmds: string[][] = []
  let words: string[] = []
  let word = ''
  let inWord = false
  let quote: '"' | "'" | undefined
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
    } else if (c === '\\' && i + 1 < cmd.length) {
      word += cmd[++i]
      inWord = true
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

const PREFIXES = new Set(['sudo', 'env', 'exec', 'time', 'nohup', 'command'])
const SHELLS = new Set(['sh', 'bash', 'zsh'])

const kindOf = (words: string[]): 'input' | 'focus' | 'none' => {
  let i = 0
  while (i < words.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i] ?? '') || PREFIXES.has(words[i] ?? ''))) i++
  const [head, ...args] = words.slice(i)
  if (head === undefined) return 'none'
  const name = head.split('/').pop() ?? head
  if (SHELLS.has(name)) {
    const c = args.indexOf('-c')
    return c >= 0 && args[c + 1] !== undefined ? classify(args[c + 1] as string).kind : 'none'
  }
  if (name === 'osascript') {
    // Only a script written out with -e is read; a script file runs unchecked (Dan, 2026-10-03).
    const script = args.filter((_, j) => args[j - 1] === '-e').join('\n')
    if (/\b(keystroke|key code|click)\b/.test(script)) return 'input'
    if (/\bactivate\b|\bset\s+frontmost\b/.test(script)) return 'focus'
    return 'none'
  }
  if (name === 'cliclick') return 'input'
  if (name === 'peekaboo' && /^(type|click|hotkey|press|scroll|drag|swipe|move)$/.test(args[0] ?? '')) return 'input'
  if (name === 'open' && args.includes('-a')) return 'focus'
  return 'none'
}

export const appNameOf = (path: string): string => {
  const m = /([^/]+)\.app(?:\/|$)/.exec(path)
  return m?.[1] ?? path.split('/').pop() ?? path
}

const focusApp = (cmd: string): string | undefined => {
  const open = /\bopen\s+(?:-\w+\s+)*-a\s+(?:"([^"]+)"|'([^']+)'|(\S+))/.exec(cmd)
  if (open) return open[1] ?? open[2] ?? open[3]
  const tell = /tell\s+application\s+"([^"]+)"\s+to\s+activate/.exec(cmd)
  if (tell) return tell[1]
  const proc = /process\s+"([^"]+)"/.exec(cmd)
  return proc?.[1]
}

export const classify = (cmd: string): Classified => {
  const kinds = simpleCommands(dropHeredocs(cmd)).map(kindOf)
  const kind = kinds.includes('input') ? 'input' : kinds.includes('focus') ? 'focus' : 'none'
  if (kind === 'none') return { kind }
  const m = MARKER.exec(cmd)
  const target = m ? (m[1] ?? m[2] ?? m[3]) : undefined
  return { kind, target, app: target ? appNameOf(target) : kind === 'focus' ? focusApp(cmd) : undefined }
}

// The verdict for synthetic input. Its sides come from different lookups: the target's pid from its
// executable path, and the frontmost pid from System Events asked what is in front, so a wrong
// lookup cannot agree with itself (L70, the 2026-08-04 Cmd+W).
export const judge = (f: {
  target: string | undefined
  targetPids: number[]
  otherPids: number[]
  frontmost: number | undefined
  frontName?: string
}): Refusal | undefined => {
  if (!f.target) {
    return { reason: "This doesn't say which app it types into.", safeWay: "Add TARGET_APP=<the app's executable path> to the command." }
  }
  const app = appNameOf(f.target)
  if (f.targetPids.length === 0) return { reason: `${app} isn't running.`, safeWay: 'Open it first, then type.' }
  if (f.targetPids.length > 1) {
    return { reason: `${app} is running twice from the same place, so the input could land in either.`, safeWay: 'Quit one first.' }
  }
  if (f.otherPids.length > 0) {
    return { reason: `Another copy of ${app} is running (pid ${f.otherPids.join(', ')}).`, safeWay: "Quit the one you're not using first." }
  }
  if (f.frontmost === undefined) {
    return { reason: "Couldn't tell which app is in front, so the input could land anywhere.", safeWay: 'Try again in a moment.' }
  }
  if (f.frontmost !== f.targetPids[0]) {
    return { reason: `${app} isn't the front app (${f.frontName ?? `pid ${f.frontmost}`} is).`, safeWay: 'Bring it forward first, then type.' }
  }
  return undefined
}

export const refusalText = (r: Refusal): string => `Blocked: ${r.reason}${r.safeWay ? ` ${r.safeWay}` : ''}`
