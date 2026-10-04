// The keystroke guard's rules, apart from the hooks (claude-config#608). Wording settled with Dan
// on 2026-10-03 (docs/mods-design.md).

export type Classified = { kind: 'input' | 'focus' | 'none'; target?: string; app?: string }
export type Refusal = { reason: string; safeWay?: string }

const MARKER = /\bTARGET_APP=(?:"([^"]+)"|'([^']+)'|(\S+))/

// Commands are judged in COMMAND POSITION only (L673): the first version matched the words anywhere
// and refused a heredoc that merely wrote a file mentioning an osascript keystroke, on 2026-10-03.
// The command itself is read by mod-kit's one shared reader ($.modkit.commands): heredoc bodies
// dropped, sudo and env looked past, bash -c read as what it runs. This judges what it hands back.
const kindOf = (words: string[]): 'input' | 'focus' | 'none' => {
  const [head, ...args] = words
  if (head === undefined) return 'none'
  const name = head.split('/').pop() ?? head
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

// cmds is what the shared reader made of the command; raw is the command as written, which still
// carries the TARGET_APP marker and the app a focus stealer names.
export const classify = (cmds: string[][], raw: string): Classified => {
  const kinds = cmds.map(kindOf)
  const kind = kinds.includes('input') ? 'input' : kinds.includes('focus') ? 'focus' : 'none'
  if (kind === 'none') return { kind }
  const m = MARKER.exec(raw)
  const target = m ? (m[1] ?? m[2] ?? m[3]) : undefined
  return { kind, target, app: target ? appNameOf(target) : kind === 'focus' ? focusApp(raw) : undefined }
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
