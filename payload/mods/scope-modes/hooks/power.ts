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

// ---- The overnight watch (#1545) ----
// While sleep mode is on, the minute's tick reads the power again, and a change of source is
// notified once: onto battery, and back onto mains. Each change is recorded, numbered, in the
// night's own folder (register.ts), so a run of minutes on battery, a second session ticking the
// same minute, or a session started again, finds it recorded and says nothing more. /sleep starts
// only on mains, so a night with no change recorded is on mains.

export type Source = 'ac' | 'battery'

// The source last recorded tonight, from the change files' names and contents: the highest number
// wins. A name that is not a number is not a change; a content that is neither source is unknown,
// said, never guessed.
export const lastSource = (changes: { name: string; text: string }[]): { last: Source; n: number } | { unknown: string } => {
  let best: { name: string; text: string; n: number } | null = null
  for (const c of changes) {
    if (!/^\d+$/.test(c.name)) continue
    const n = Number(c.name)
    if (!best || n > best.n) best = { ...c, n }
  }
  if (!best) return { last: 'ac', n: 0 }
  const t = best.text.trim()
  if (t === 'ac' || t === 'battery') return { last: t, n: best.n }
  return { unknown: `the power change recorded as ${best.name} reads ${JSON.stringify(t.slice(0, 40))}, which is neither source` }
}

// The change to record and notify, or null: an unknown reading changes nothing (it is said in the
// debug log by the caller), and neither does the source already recorded.
export const powerChange = (last: Source, now: Power): { to: Source; notice: string } | null => {
  if (now.state === 'unknown' || now.state === last) return null
  return now.state === 'battery'
    ? { to: 'battery', notice: 'This Mac went onto battery power while sleep mode is on, so the night of work will drain it. Plug it back in.' }
    : { to: 'ac', notice: 'This Mac is plugged in again, so sleep mode carries on with the night on mains power.' }
}
