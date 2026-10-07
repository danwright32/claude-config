import type { EngineInterface, Register } from 'claude-code'
import { appNameOf, classify, judge, refusalText, type Refusal } from './keys.ts'

// Keystroke guard (claude-config#608). A Go ahead holds for its app until ten minutes pass with
// nothing sent to it (Dan, 2026-10-03). Kept in memory: a reload asks again, which errs toward
// asking.
const QUIET_MS = 10 * 60_000
const lastActive = new Map<string, number>()
const GUARD = 'Keystroke guard'

const pids = (stdout: string): number[] =>
  stdout
    .split('\n')
    .map(s => Number(s.trim()))
    .filter(n => Number.isInteger(n) && n > 0)

const run = async ($: EngineInterface, argv: string[]): Promise<string | undefined> => {
  try {
    const r = await $.process.run(argv, { timeoutMs: 10_000 })
    return r.exitCode === 0 ? r.stdout : r.exitCode === 1 && r.stderr === '' ? '' : undefined
  } catch {
    return undefined
  }
}

// What the Mac says, each fact from its own lookup.
const facts = async ($: EngineInterface, target: string) => {
  const exec = target.split('/').pop() ?? target
  const pathOf = async (pid: number) => ((await run($, ['ps', '-o', 'comm=', '-p', String(pid)])) ?? '').trim()
  // The target's pids by its full path, kept only where the process really IS that executable
  // (ps), not merely a command that mentions the path.
  const targetPids: number[] = []
  for (const p of pids((await run($, ['pgrep', '-f', target])) ?? '')) if ((await pathOf(p)) === target) targetPids.push(p)
  // Every process with the same executable name, at any path: the copies that must not be running.
  // Read from the full process list by the executable's whole name, never pgrep -x, which matches a
  // name macOS cuts to 16 characters and so never finds a second Adobe Lightroom Classic (lessons
  // review). A list that cannot be read is an unreadable front app's twin: refused below.
  const otherPids: number[] = []
  const all = await run($, ['ps', '-axo', 'pid=,comm='])
  if (all === undefined) return { targetPids, otherPids, frontmost: undefined, frontName: undefined }
  for (const line of all.split('\n')) {
    const m = /^\s*(\d+)\s+(.+)$/.exec(line)
    if (!m) continue
    const pid = Number(m[1])
    const path = (m[2] as string).trim()
    if (!targetPids.includes(pid) && path !== target && path.split('/').pop() === exec) otherPids.push(pid)
  }
  const front = await run($, [
    'osascript',
    '-e',
    'tell application "System Events" to get unix id of first application process whose frontmost is true',
  ])
  const frontmost = front === undefined ? undefined : pids(front)[0]
  const frontPath = frontmost === undefined ? '' : await pathOf(frontmost)
  return { targetPids, otherPids, frontmost, frontName: frontPath ? appNameOf(frontPath) : undefined }
}

// The heads up, in the standard question dialog with the chip "Taking over" (design round 2).
// A decline, a dismissal or a question nobody can answer refuses (L42).
const headsUp = async ($: EngineInterface, app: string, typing: boolean, named: boolean): Promise<Refusal | undefined> => {
  const now = await $.clock.now()
  const last = named ? lastActive.get(app) : undefined
  if (last !== undefined && now - last <= QUIET_MS) {
    lastActive.set(app, now)
    return undefined
  }
  const doing = typing ? `type into ${app}` : `bring ${app} to the front`
  let answer = ''
  try {
    answer = await $.ui.ask(`I'm about to ${doing}. Ready?`, { options: ['Go ahead', 'Not now'], header: 'Taking over' })
  } catch {
    return { reason: `The question about ${app} was dismissed.` }
  }
  if (answer !== 'Go ahead') return { reason: `You said not now to ${typing ? `typing into ${app}` : `bringing ${app} to the front`}.` }
  // A yes is remembered only for an app the guard could name: one for "an app" would cover every
  // app it cannot name (lessons review).
  if (named) lastActive.set(app, await $.clock.now())
  return undefined
}

/** The scope modes mod's noun (#621) as its contract has it; it may not be loaded at all. */
type ScopeModes = {
  hold: (input: { label: string; prompt: string }) => Promise<{ isHeld: boolean; card?: { guard: string; reason: string; safeWay: string }; deny?: string }>
}
type Held = { card?: { guard: string; reason: string; safeWay: string }; deny?: string }

// While Dan is away (#621) the action is held for the held card he sees on coming home, rather than
// asked about in the band, which his phone cannot show, so the turn would wait on nobody. The
// engine needs the noun called in place, so the scope modes mod not being loaded (which is home)
// arrives as a TypeError naming the noun; any other failure, a TypeError from inside a loaded mod
// included, is a refusal: whether a question can be answered at all is unknown (L42).
const holdWhileAway = async ($: EngineInterface, label: string, prompt: string): Promise<{ held: Held } | 'home' | { failed: string }> => {
  try {
    const r = await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.hold({ label, prompt })
    return r?.isHeld === true ? { held: { card: r.card, deny: r.deny } } : 'home'
  } catch (err) {
    const why = String((err as Error)?.message ?? err)
    if (err instanceof TypeError && /scopeModes/.test(why)) return 'home'
    return { failed: why }
  }
}

export const register: Register = on => {
  // Asked at tool.check (#875), which the engine raises inside tool.call once every mod's tool.call
  // hook and the settings PreToolUse hooks have passed the call on, and before the mode settles an
  // ask: an action no build, winding down, the secret guard or a settings hook refuses is refused
  // before Dan is asked, whichever order the mods load in (#707), and next(e) here runs no command,
  // only the verdict beneath. It was classic.PreToolUse, which never ran: Claude Code's built-in
  // security default sends every classic event past the user tier this mod loads in, for a Team or
  // Enterprise organization. A headless debug run on 2026-10-06 logged that on every Bash call, and
  // a command this guard refuses ran. The built-in's own tool.check hook runs this tier first and
  // keeps a refusal.
  on('tool.check', { tool: 'Bash' }, async ($, e, next) => {
    const decided = await next(e)
    if (decided.decision === 'deny') return decided
    // A query ($.tool.check) carries no call id and runs nothing; the real call is judged when it is
    // made, so Dan is never asked about a command that is only being looked at.
    if (e.tool_use_id === undefined) return decided
    const command = String((e.input as { command?: unknown } | null)?.command ?? '')
    const c = classify(await $.modkit.commands({ command }), command)
    if (c.kind === 'none') return decided
    const typing = c.kind === 'input'
    const app = c.app ?? 'an app'
    const toolUseId = e.tool_use_id
    const action = typing ? `typing into ${app}` : `bringing ${app} to the front`

    // The toast says what was judged: the action by default, or whatever failed before it could be
    // (L11, #732).
    const refuse = async (r: Refusal, toast = `Blocked ${action}.`) => {
      await $.modkit.blocked({ toolUseId, guard: GUARD, reason: r.reason, safeWay: r.safeWay })
      await $.ui.toast(toast)
      return { decision: 'deny' as const, reason: refusalText(r) }
    }

    // Held as scope modes words its own held actions, so the two read the same (L605).
    const away = await holdWhileAway($, typing ? `Type into ${app}` : `Bring ${app} to the front`, `Do it now. What was held: ${command}`)
    if (away !== 'home') {
      if ('failed' in away) {
        const reason = `Couldn't tell whether you are away (${away.failed}), so this was stopped.`
        return refuse({ reason, safeWay: 'Try again in a moment.' }, `Couldn't tell whether you are away, so ${action} was stopped.`)
      }
      if (away.held.card) await $.modkit.blocked({ toolUseId, ...away.held.card })
      return { decision: 'deny' as const, reason: away.held.deny ?? 'Held: Dan is away from the Mac, so this waits for him to come back.' }
    }

    if (typing) {
      const verdict = c.target
        ? judge({ target: c.target, ...(await facts($, c.target)) })
        : judge({ target: undefined, targetPids: [], otherPids: [], frontmost: undefined })
      if (verdict) return refuse(verdict)
    }

    const declined = await headsUp($, app, typing, c.app !== undefined)
    if (declined) return refuse(declined)
    return decided
  }).catch(($, e, next) => ({
    // A hook that fails is skipped and the verdict beneath stands, which would let the keystroke
    // through unchecked, so a failure here refuses (L42). Nothing has run yet at tool.check.
    decision: 'deny' as const,
    reason: `Blocked: the keystroke guard could not check this command (${next.error?.message ?? next.error?.kind ?? 'unknown failure'}), so it did not run. Try it again; if it fails the same way, tell Dan.`,
  }))
}
