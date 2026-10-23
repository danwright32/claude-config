// A mod's way onto the one polling policy for asking GitHub the same question until the answer
// changes, hooks/lib/gh-poll.sh (#1482): the wait that grows while nothing changes, the pause on a
// rate limit answer, and the session's looks a minute shared with every other loop in the session
// (the merge helpers its agents run among them). A mod cannot source a shell library, so it runs the
// library as a command and reads its one line; the rules stay in the library alone (L370), and
// hooks/test-gh-poll.sh holds the command to the lines read here.
//
// Pure: the caller hands in how to run a command, spelled with its own `$` in place, since a mod
// cannot hand `$` on. Kept here and copied byte for byte into each mod that uses it
// (hooks/mod-kit/ghpoll.ts, which tools/check-mod-shared-parts.sh holds to this one). Every reader
// throws on an answer it cannot read, never reading it as a yes or a no; what a failure means is the
// caller's to say.

export type PollRun = (argv: string[], env?: Record<string, string>) => Promise<{ exitCode: number; stdout: string; stderr: string }>
/** How to reach the library: the runner, its path, and the session whose budget a look spends. */
export type Poll = { run: PollRun; lib: string; session: string }
export type Take = { take: true } | { take: false; why: 'pause' | 'cap'; waitMs: number; said: string }

/** The installed library, under the home folder, where the sync puts the hooks. */
export const pollLib = (home: string): string => `${home}/.claude/hooks/lib/gh-poll.sh`

const secs = (ms: number) => String(Math.floor(ms / 1000))

const ask = async (p: Poll, args: string[]): Promise<string> => {
  const r = await p.run(['bash', p.lib, ...args], { CLAUDE_CODE_SESSION_ID: p.session })
  if (r.exitCode !== 0) throw new Error(r.stderr.trim() || `gh-poll.sh exited ${r.exitCode}`)
  return r.stdout.replace(/\n$/, '')
}

/** Take one look for the session at `nowMs`, or be told to wait, why and for how long. */
export const takeLook = async (p: Poll, nowMs: number): Promise<Take> => {
  const out = await ask(p, ['take', secs(nowMs)])
  if (out === 'ok') return { take: true }
  const [w, why, s, ...said] = out.split('\t')
  if (w === 'wait' && (why === 'pause' || why === 'cap') && s !== undefined && /^\d+$/.test(s)) {
    return { take: false, why, waitMs: Number(s) * 1000, said: said.join('\t') }
  }
  throw new Error(`gh-poll.sh answered a look with "${out}"`)
}

/** Hand over a failed read's error text: a rate limit answer pauses the session's looks. */
export const failedLook = async (p: Poll, nowMs: number, text: string): Promise<{ paused: true; waitMs: number; said: string } | { paused: false }> => {
  const out = await ask(p, ['failed', secs(nowMs), text])
  if (out === 'other') return { paused: false }
  const [w, s, ...said] = out.split('\t')
  if (w === 'paused' && s !== undefined && /^\d+$/.test(s)) return { paused: true, waitMs: Number(s) * 1000, said: said.join('\t') }
  throw new Error(`gh-poll.sh answered a failed read with "${out}"`)
}

/** A read was answered: the next rate limit pause starts again at its first wait. */
export const answeredLook = async (p: Poll): Promise<void> => {
  const out = await ask(p, ['answered'])
  if (out !== 'ok') throw new Error(`gh-poll.sh answered an answered read with "${out}"`)
}

/**
 * The next wait between looks: grown from `waitMs` when the look saw no change, the base when it did,
 * between the caller's own base and ceiling when it names them, else the policy's.
 */
export const nextWaitMs = async (p: Poll, waitMs: number, changed: boolean, bounds?: { baseMs: number; maxMs: number }): Promise<number> => {
  const out = await ask(p, ['next', secs(waitMs), changed ? '1' : '0', ...(bounds ? [secs(bounds.baseMs), secs(bounds.maxMs)] : [])])
  if (!/^\d+$/.test(out)) throw new Error(`gh-poll.sh answered the next wait with "${out}"`)
  return Number(out) * 1000
}
