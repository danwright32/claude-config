import type { EngineInterface, Register } from 'claude-code'
import { classify, judge } from './keys.ts'

// Keystroke guard (claude-config#608). A heads up answered yes holds for its app until ten minutes
// pass with no input action for it. Kept in memory: a reload asks again, which errs toward asking.
const QUIET_MS = 10 * 60_000
const lastActive = new Map<string, number>()

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
  // The target's pids, by its full path, kept only where the process really IS that executable
  // (ps), not merely a command that mentions the path.
  const byPath = pids((await run($, ['pgrep', '-f', target])) ?? '')
  const pathOf = async (pid: number) => ((await run($, ['ps', '-o', 'comm=', '-p', String(pid)])) ?? '').trim()
  const targetPids: number[] = []
  for (const p of byPath) if ((await pathOf(p)) === target) targetPids.push(p)
  // Every process with the same executable name, at any path: the copies that must not be running.
  const sameName = pids((await run($, ['pgrep', '-x', exec])) ?? '')
  const otherPids: number[] = []
  for (const p of sameName) if (!targetPids.includes(p) && (await pathOf(p)) !== target) otherPids.push(p)
  const front = await run($, [
    'osascript',
    '-e',
    'tell application "System Events" to get unix id of first application process whose frontmost is true',
  ])
  const frontmost = front === undefined ? undefined : pids(front)[0]
  return { targetPids, otherPids, frontmost }
}

// The heads up: asked once per app, held while input keeps coming. A decline, a dismissal or a
// question nobody can answer is a refusal (L42).
const headsUp = async ($: EngineInterface, app: string, verb: string): Promise<string | undefined> => {
  const now = await $.clock.now()
  const last = lastActive.get(app)
  if (last !== undefined && now - last <= QUIET_MS) {
    lastActive.set(app, now)
    return undefined
  }
  let answer = ''
  try {
    answer = await $.ui.ask(`About to ${verb} ${app}, ready?`, ['Ready', 'Not now'])
  } catch {
    return `keystroke-guard: refused, because the heads up about ${app} was dismissed. Ask Dan when he is ready, then try again.`
  }
  if (answer !== 'Ready') return `keystroke-guard: refused, because Dan answered "${answer}" to the heads up about ${app}.`
  lastActive.set(app, await $.clock.now())
  return undefined
}

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const c = classify(e.command)
    if (c.kind === 'none') return next(e)

    if (c.kind === 'input') {
      const verdict = c.target ? judge({ target: c.target, ...(await facts($, c.target)) }) : judge({ target: undefined, targetPids: [], otherPids: [], frontmost: undefined })
      if (verdict) {
        await $.ui.toast('keystroke-guard: refused synthetic input')
        return { deny: verdict }
      }
    }

    const app = c.app ?? 'an app'
    const refused = await headsUp($, app, c.kind === 'input' ? 'type into' : 'bring forward')
    if (refused) return { deny: refused }
    return next(e)
  })
}
