import type { ModKitBandRow } from '../.claude-plugin/types/mod-kit/index.d.ts'
import type { ScopeModesHeld } from '../types/index.d.ts'

// Away and home (#621). While Dan is away nothing opens on the Mac and nothing takes focus: what
// needs him at the Mac is held, and on coming home each session shows what it held in one boxed
// card in the band, nothing opening until he presses its button (design round, 2026-10-04).

const base = (p: string) => p.replace(/\/+$/, '').split('/').pop() || p
const isFlag = (w: string) => w.startsWith('-')
// A link is named by where it goes, never by its query or fragment, which can carry a token (L741).
const shown = (target: string) => (/^[a-z][a-z0-9+.-]*:\/\//i.test(target) ? target.replace(/[?#].*$/, '') : base(target))

// The app a keystroke guard action names: TARGET_APP=<executable path> is the guard's own rule, and
// the reader drops assignments, so it is read from the command as written.
const targetApp = (raw: string): string | undefined => {
  const m = /\bTARGET_APP=("[^"]+"|'[^']+'|\S+)/.exec(raw)
  if (!m) return undefined
  const path = (m[1] as string).replace(/^["']|["']$/g, '')
  const app = /([^/]+)\.app\//.exec(path)
  return app ? (app[1] as string) : base(path)
}

// An AppleScript that only reads (the frontmost app's name, a window list) takes no focus.
const SCRIPT_ACTS = /\b(?:keystroke|key code|click|activate|frontmost to true|set frontmost|open location|reopen|launch|open)\b/i
const SCRIPT_TYPES = /\b(?:keystroke|key code|click)\b/i

/**
 * What a Bash call would do on the Mac that needs Dan there (open something, take focus, type or
 * click), as the line his held card names it by, or undefined when it needs nothing of the Mac.
 */
export const needsTheMac = (call: { raw: string; commands: string[][] }): string | undefined => {
  for (const words of call.commands) {
    const cmd = base(words[0] ?? '')
    const args = words.slice(1)
    if (cmd === 'open') {
      let app: string | undefined
      const targets: string[] = []
      for (let i = 0; i < args.length; i++) {
        const a = args[i] as string
        if (a === '-a' || a === '-b') app = args[++i]
        else if (!isFlag(a)) targets.push(shown(a))
      }
      const what = targets.length ? `Open ${targets.join(', ')}` : `Open ${app ?? 'an app'}`
      return app && targets.length ? `${what} in ${app}` : what
    }
    if (cmd === 'bbedit_tool' || cmd === 'bbedit') {
      const files = args.filter(a => !isFlag(a)).map(shown)
      return files.length ? `Open ${files.join(', ')} in BBEdit` : 'Open BBEdit'
    }
    if (cmd === 'osascript') {
      const script = args.filter(a => !isFlag(a)).join(' ')
      if (!SCRIPT_ACTS.test(script)) continue
      const app = targetApp(call.raw)
      if (SCRIPT_TYPES.test(script)) return app ? `Type into ${app}` : 'Type into an app'
      return app ? `Bring ${app} to the front` : 'Bring an app to the front'
    }
    if (cmd === 'cliclick' || cmd === 'peekaboo') {
      const app = targetApp(call.raw)
      return app ? `Click in ${app}` : `Click or type with ${cmd}`
    }
  }
  return undefined
}

/**
 * The held while away card (design round, 2026-10-04): boxed, an amber heading, one row per held
 * thing with its own button and a thin line between rows. Undefined when nothing was held, so a
 * session that held nothing shows no card.
 */
export const heldCard = (held: readonly ScopeModesHeld[]): ModKitBandRow | undefined => {
  if (!held.length) return undefined
  const lines: ModKitBandRow['lines'] = [[{ text: 'Held while you were away', color: 'warning' }]]
  held.forEach((h, i) => {
    if (i > 0) lines.push({ divider: true })
    lines.push([{ text: `${h.label} ` }, { button: `held-${h.id}`, label: h.label.startsWith('Open') ? 'Open' : 'Do it' }])
  })
  return { mod: 'scope-modes', id: 'held', slot: 'held', frame: { kind: 'box' }, lines }
}
