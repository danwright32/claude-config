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
  const otherPids: number[] = []
  for (const p of pids((await run($, ['pgrep', '-x', exec])) ?? '')) if (!targetPids.includes(p) && (await pathOf(p)) !== target) otherPids.push(p)
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

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const c = classify(e.command)
    if (c.kind === 'none') return next(e)
    const typing = c.kind === 'input'
    const app = c.app ?? 'an app'

    const refuse = async (r: Refusal) => {
      $.modkit.blocked({ toolUseId: String(e.tool_use_id ?? ''), guard: GUARD, reason: r.reason, safeWay: r.safeWay })
      await $.ui.toast(typing ? `Blocked typing into ${app}.` : `Blocked bringing ${app} to the front.`)
      return { deny: refusalText(r) }
    }

    if (typing) {
      const verdict = c.target
        ? judge({ target: c.target, ...(await facts($, c.target)) })
        : judge({ target: undefined, targetPids: [], otherPids: [], frontmost: undefined })
      if (verdict) return refuse(verdict)
    }

    const declined = await headsUp($, app, typing, c.app !== undefined)
    if (declined) return refuse(declined)
    return next(e)
  })
}
