// What this Mac draws its power from, as `pmset -g batt` says it (#844), and what /sleep says and
// notifies when it will not start on it (#1545). Pure: register.ts runs pmset and the notifier.
// A reading pmset does not give is unknown, with why, and never guessed as either source (#844).

export type Power = { state: 'ac' } | { state: 'battery' } | { state: 'unknown'; why: string }

export const powerOf = (r: { exitCode: number; stdout: string; stderr: string }): Power => {
  if (r.exitCode !== 0) return { state: 'unknown', why: `whether this Mac is on battery could not be read (${r.stderr.trim() || `pmset exited ${r.exitCode}`})` }
  if (/'Battery Power'/.test(r.stdout)) return { state: 'battery' }
  if (!/'AC Power'/.test(r.stdout)) return { state: 'unknown', why: `pmset did not say what this Mac is drawing power from (${r.stdout.trim().split('\n')[0]?.slice(0, 120) ?? ''})` }
  return { state: 'ac' }
}

// Why /sleep does not start on this power: its reply, and the notification, which reaches Dan when
// the reply lands in a session he is not looking at (a /sleep typed while a turn ran is answered
// only once the turn ends). Null on mains.
export const sleepRefusal = (p: Power): { text: string; notice: string } | null => {
  if (p.state === 'ac') return null
  if (p.state === 'battery')
    return {
      text: 'Sleep mode did not start: this Mac is on battery power, and a night of work would drain it. Plug it in and run /sleep again.',
      notice: 'Sleep mode did not start: this Mac is on battery power. Plug it in and run /sleep again.',
    }
  return { text: `Sleep mode did not start: ${p.why}.`, notice: `Sleep mode did not start: ${p.why}. Check it is plugged in, then run /sleep again.` }
}
