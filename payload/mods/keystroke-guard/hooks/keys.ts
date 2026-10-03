// The keystroke guard's rules, apart from the hooks (claude-config#608).

export type Classified = { kind: 'input' | 'focus' | 'none'; target?: string; app?: string }

const MARKER = /\bTARGET_APP=(?:"([^"]+)"|'([^']+)'|(\S+))/

// Synthetic input: a keystroke, key code or click sent through System Events, cliclick, or Peekaboo.
const INPUT: readonly RegExp[] = [
  /\bosascript\b[\s\S]*\b(keystroke|key code|click)\b/,
  /\bcliclick\b/,
  /\bpeekaboo\s+(type|click|hotkey|press|scroll|drag|swipe|move)\b/,
]

// Focus stealers: bring an app forward without typing into it.
const FOCUS: readonly RegExp[] = [/\bopen\s+(?:-\w+\s+)*-a\s/, /\bactivate\b/, /\bset\s+frontmost\b/]

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
  const m = MARKER.exec(cmd)
  const target = m ? (m[1] ?? m[2] ?? m[3]) : undefined
  if (INPUT.some(re => re.test(cmd))) return { kind: 'input', target, app: target ? appNameOf(target) : undefined }
  if (FOCUS.some(re => re.test(cmd))) return { kind: 'focus', target, app: target ? appNameOf(target) : focusApp(cmd) }
  return { kind: 'none' }
}

const HOW =
  'Declare the target by its executable path in the command (TARGET_APP=/Applications/X.app/Contents/MacOS/X), bring it forward in a separate command first, then send the input.'

// The verdict for synthetic input. Its two sides come from two different lookups: the target's pid
// from its executable path, and the frontmost pid from System Events asked about whatever is in
// front, so a wrong lookup cannot agree with itself (L70, the 2026-08-04 Cmd+W).
export const judge = (f: {
  target: string | undefined
  targetPids: number[]
  otherPids: number[]
  frontmost: number | undefined
}): string | undefined => {
  if (!f.target) return `keystroke-guard: refused, because the command does not say which app it types into. ${HOW}`
  const app = appNameOf(f.target)
  if (f.targetPids.length === 0) return `keystroke-guard: refused, because ${f.target} is not running. ${HOW}`
  if (f.targetPids.length > 1) {
    return `keystroke-guard: refused, because more than one process runs ${f.target} (${f.targetPids.join(', ')}), so which one receives the input cannot be told. Quit the copies you are not targeting.`
  }
  if (f.otherPids.length > 0) {
    return `keystroke-guard: refused, because another copy of ${app} is running at a different path (pid ${f.otherPids.join(', ')}). Quit the copy you are not targeting so only ${f.target} remains.`
  }
  if (f.frontmost === undefined) {
    return `keystroke-guard: refused, because the frontmost app could not be read, and input sent blind can land anywhere.`
  }
  if (f.frontmost !== f.targetPids[0]) {
    return `keystroke-guard: refused, because ${app} (pid ${f.targetPids[0]}) is not the frontmost app (pid ${f.frontmost} is). ${HOW}`
  }
  return undefined
}
