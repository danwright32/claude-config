// Sleep mode phase 8 (#844): keeping an enrolled session working overnight, safely.
//
// The overnight driver is the scope modes mod's classic.Stop and classic.StopFailure handlers for a
// session the sleep record names in `workers`. Everything it decides is decided here, from recorded
// state only (#839): the driver's own counter file, this session's notes, the commits on tonight's
// sleep/ branches, the claim sleep-queue.sh holds (#842) and the usage reading. Never from the order
// of its own blocks or from what the model says it did, since after a compaction the model works
// ahead of its blocks and answers them "already complete".
//
// Nothing here touches the engine: register.ts reads, calls these, and carries out what they return.
//
// Every limit fails safe. A counter that cannot be read stops the driver rather than looping on a
// count it cannot keep; a progress reading that cannot be taken counts as no progress, so the
// breaker still trips; a usage reading missing for an hour finishes the current issue and stops.

const MIN = 60_000

/** The limits, each one place (L428). */
export const LIMITS = {
  /** Blocks in a row with no new commit, claim or note before the circuit breaker lets the session stop. */
  breakerBlocks: 3,
  /** Active minutes with no new commit, claim or note before the breaker trips. */
  breakerMs: 20 * MIN,
  /** Blocks one session may take in a night, whatever else holds. */
  nightCap: 120,
  /** Active time on one claim before it is parked. */
  stuckMs: 2 * 60 * MIN,
  /** Attempts an issue gets in a night: a claim past this is parked at once. */
  attempts: 2,
  /** The weekly usage percent at which work stops (Dan, 2026-10-07). */
  weeklyStop: 95,
  /** How long with no weekly reading before the session stops after its current issue. */
  unmeasuredMs: 60 * MIN,
  /** The waits after a rate limit or a server error, in minutes: then an hour each, all night (Dan, 2026-10-07). */
  waitsMin: [5, 10, 20, 40, 60] as readonly number[],
}

/** The errors worth waiting out: a usage limit, and the server being busy or failing (overloaded arrives as server_error, #839). */
const RETRY = new Set(['rate_limit', 'overloaded', 'server_error'])

/** The kinds of note that are not progress: the driver's own bookkeeping, written whatever the work did. */
const BOOKKEEPING = new Set(['heartbeat', 'wait', 'usage', 'stopped', 'start', 'woke', 'limit'])

/** One wait, from and until in ms, so active time can leave it out. */
export type Wait = { from: number; until: number }

/** The driver's own record for one session in one night: its loop counter (stop_hook_active is true from the second Stop on, #839). */
export type DriverRecord = {
  v: 1
  generation: string
  session: string
  /** When the driver first saw this session tonight. */
  since: number
  /** Blocks taken tonight. */
  blocks: number
  /** Blocks in a row with no progress. */
  idleBlocks: number
  /** When progress was last seen, or `since`. */
  progressAt: number
  /** What progress read as at the last Stop; null before any reading. */
  fingerprint: string | null
  /** Which wait comes next after a failure; back to 0 after a turn that ended well. */
  waitStep: number
  /** When the session is to be started again after a wait, or null. */
  resumeAt: number | null
  waits: Wait[]
  /** When a weekly reading was last seen. */
  weeklyAt: number | null
  /** Set once the usage went unmeasured: finish the issue in hand, claim nothing new. */
  finishing: boolean
  /** An issue the watchdog parked between Stops, said at the next one. */
  parked: string | null
  /** Why the driver let this session stop for the night; once set, it never blocks again. */
  stopped: string | null
}

export type DriverReading = { state: 'none' } | { state: 'ok'; record: DriverRecord } | { state: 'unreadable'; why: string }

const isNum = (x: unknown): x is number => typeof x === 'number' && Number.isFinite(x)

export const freshDriver = (generation: string, session: string, now: number): DriverRecord => ({
  v: 1, generation, session, since: now, blocks: 0, idleBlocks: 0, progressAt: now, fingerprint: null,
  waitStep: 0, resumeAt: null, waits: [], weeklyAt: null, finishing: false, parked: null, stopped: null,
})

/** The counter as stored. Anything but a whole record for this night and session is unreadable, never a fresh start (L105). */
export const readDriver = (text: string | null, generation: string, session: string): DriverReading => {
  if (text === null) return { state: 'none' }
  let j: unknown
  try {
    j = JSON.parse(text)
  } catch {
    return { state: 'unreadable', why: "the driver's counter is not JSON" }
  }
  const r = j as Partial<DriverRecord> | null
  if (!r || typeof r !== 'object' || r.v !== 1) return { state: 'unreadable', why: "the driver's counter has no version this reader knows" }
  if (r.generation !== generation || r.session !== session) return { state: 'unreadable', why: "the driver's counter belongs to another night or session" }
  const nums = [r.since, r.blocks, r.idleBlocks, r.progressAt, r.waitStep]
  if (!nums.every(isNum) || !Array.isArray(r.waits) || !(r.resumeAt === null || isNum(r.resumeAt)) || !(r.weeklyAt === null || isNum(r.weeklyAt))) {
    return { state: 'unreadable', why: "the driver's counter is missing a count" }
  }
  return { state: 'ok', record: r as DriverRecord }
}

/** Where the counter lives: one file per night and session, under the sleep folder (this Mac only). */
export const driverPath = (sleepDir: string, generation: string, session: string) =>
  `${sleepDir}/driver/${generation.replace(/[^\w.-]/g, '_')}/${session.replace(/[^\w.-]/g, '_')}.json`

/** Milliseconds of `waits` that fall inside [from, to]. */
export const waitedIn = (waits: Wait[], from: number, to: number) =>
  waits.reduce((sum, w) => sum + Math.max(0, Math.min(w.until, to) - Math.max(w.from, from)), 0)

/** Active time between two moments: waits on a limit do not count (M2, L737). */
export const activeMs = (waits: Wait[], from: number, to: number) => Math.max(0, to - from - waitedIn(waits, from, to))

/**
 * What progress reads as now: this session's own notes that are not bookkeeping, and the tips of
 * tonight's sleep/ branches. Either reading missing makes the whole reading null, which counts as no
 * progress (a breaker that trips on an unreadable reading stops; one that resets on it loops).
 */
export const progressOf = (notesText: string | null, self: string, refsText: string | null): string | null => {
  if (notesText === null || refsText === null) return null
  let notes = 0
  for (const line of notesText.split('\n')) {
    if (!line.trim()) continue
    try {
      const n = JSON.parse(line) as { by?: unknown; kind?: unknown; driver?: unknown }
      if (n.by === self && (n as { driver?: unknown }).driver !== true && typeof n.kind === 'string' && !BOOKKEEPING.has(n.kind)) notes++
    } catch {
      // A line that cannot be read is no progress of anybody's.
    }
  }
  const refs = refsText.split('\n').map(s => s.trim()).filter(Boolean).sort().join(',')
  return `notes=${notes};refs=${refs}`
}

/** Whether this session said it stopped (`stopped` note by it), the one way the model ends its own night. */
export const saidStopped = (notesText: string | null, self: string, since: number): boolean =>
  (notesText ?? '').split('\n').some(line => {
    try {
      const n = JSON.parse(line) as { by?: unknown; kind?: unknown; at?: unknown }
      return n.by === self && n.kind === 'stopped' && (!isNum(n.at) || n.at >= since)
    } catch {
      return false
    }
  })

/** The claim this session holds, from `sleep-queue.sh claims`: one JSON line per issue claimed tonight. */
export type Claim = { repo: string; issue: number; attempts: number; since: number }
export type ClaimReading = { state: 'none' } | { state: 'held'; claim: Claim } | { state: 'unknown'; why: string }
export const heldClaim = (claimsText: string, self: string): ClaimReading => {
  let held: Claim | null = null
  for (const line of claimsText.split('\n')) {
    if (!line.trim()) continue
    let c: { repo?: unknown; issue?: unknown; attempts?: unknown; entries?: unknown }
    try {
      c = JSON.parse(line)
    } catch {
      return { state: 'unknown', why: 'a line of the claims could not be read' }
    }
    const es = Array.isArray(c.entries) ? (c.entries as { kind?: unknown; session?: unknown; at?: unknown }[]) : []
    const last = es[es.length - 1]
    if (last?.kind === 'claim' && last.session === self && typeof c.repo === 'string' && isNum(c.issue)) {
      // Two held at once would be a fault in the queue; the newest is the one being worked.
      const since = isNum(last.at) ? last.at : 0
      if (!held || since >= held.since) held = { repo: c.repo, issue: c.issue, attempts: isNum(c.attempts) ? c.attempts : 1, since }
    }
  }
  return held ? { state: 'held', claim: held } : { state: 'none' }
}

/** A note for the night's report, as sleep_note writes it (the writer adds v, generation). */
export type Note = Record<string, unknown> & { kind: string }

/** A claim the driver ends through sleep-queue.sh, which writes the matching note itself (one writer, #844). */
export type Release = { issue: number; state: 'parked' | 'failed'; why: string }

export type StopDecision =
  | { kind: 'block'; reason: string; record: DriverRecord; notes: Note[]; release?: Release }
  | { kind: 'stop'; record: DriverRecord | null; notes: Note[]; release?: Release; why: string }

export type StopInput = {
  now: number
  self: string
  generation: string
  /** The session's repository as owner/name, for notes not tied to a claim. */
  repo: string | null
  driver: DriverReading
  fingerprint: string | null
  notesText: string | null
  weekly: number | null
  claim: ClaimReading
  /** The rules every block carries, so they survive compaction. */
  rules: string
}

const pct = (n: number) => `${Math.round(n * 10) / 10}%`
const mins = (ms: number) => `${Math.round(ms / MIN)} minutes`

/**
 * One Stop of an enrolled session while the Mac sleeps. Blocks to keep it working, or lets it stop
 * with a note saying why. The order is the order of what matters most: an unreadable counter, the
 * weekly limit, the night's cap, the breaker, the stuck claim, the unmeasured usage.
 */
export const decideStop = (i: StopInput): StopDecision => {
  const { now, self } = i
  if (i.driver.state === 'unreadable') {
    const why = `${i.driver.why}, so the driver cannot count its blocks and stopped rather than loop`
    return { kind: 'stop', record: null, why, notes: [{ kind: 'stopped', text: why }] }
  }
  const d: DriverRecord = i.driver.state === 'ok' ? { ...i.driver.record, waits: [...i.driver.record.waits] } : freshDriver(i.generation, self, now)
  if (d.stopped) return { kind: 'stop', record: d, why: d.stopped, notes: [] }
  // A turn that ended (rather than failed) starts the waits over.
  d.waitStep = 0
  d.resumeAt = null
  if (i.weekly !== null) d.weeklyAt = now
  const progressed = i.fingerprint !== null && i.fingerprint !== d.fingerprint
  if (progressed) {
    d.fingerprint = i.fingerprint
    d.idleBlocks = 0
    d.progressAt = now
  }
  const claim = i.claim.state === 'held' ? i.claim.claim : null
  const where = claim ? { repo: claim.repo, issue: claim.issue } : i.repo ? { repo: i.repo } : {}
  const stop = (why: string, release?: Release, extra: Note[] = []): StopDecision => {
    d.stopped = why
    // A stop with no claim to end still leaves a failed note when it is a fault, so it shows in the report.
    return { kind: 'stop', record: d, why, ...(release ? { release } : {}), notes: [...extra, { kind: 'stopped', ...where, text: why }] }
  }

  if (saidStopped(i.notesText, self, d.since)) return stop('the session said it stopped (its stopped note)')

  if (i.weekly !== null && i.weekly >= LIMITS.weeklyStop) {
    const why = `the weekly limit is at ${pct(i.weekly)}, past the ${LIMITS.weeklyStop}% the night stops at`
    return stop(why, claim ? { issue: claim.issue, state: 'parked', why } : undefined)
  }
  if (d.blocks >= LIMITS.nightCap) {
    const why = `this session reached the night's cap of ${LIMITS.nightCap} blocks`
    return stop(why, claim ? { issue: claim.issue, state: 'failed', why } : undefined, claim ? [] : [{ kind: 'failed', ...where, text: why }])
  }
  if (i.claim.state === 'unknown') {
    // Whose claim is whose cannot be read, so nothing can be parked or judged stuck: stop, said.
    return stop(`the claims could not be read (${i.claim.why})`, undefined, [{ kind: 'failed', ...where, text: `the claims could not be read (${i.claim.why})` }])
  }
  const idleMs = activeMs(d.waits, d.progressAt, now)
  const idle = progressed ? 0 : d.idleBlocks
  if (idle >= LIMITS.breakerBlocks || idleMs >= LIMITS.breakerMs) {
    const why = `circuit breaker: ${idle >= LIMITS.breakerBlocks ? `${idle} blocks in a row` : `${mins(idleMs)} of active time`} with no new commit, claim or note`
    return stop(why, claim ? { issue: claim.issue, state: 'failed', why } : undefined, claim ? [] : [{ kind: 'failed', ...where, text: why }])
  }

  let release: Release | undefined
  let told = ''
  if (claim && claim.attempts > LIMITS.attempts) {
    release = { issue: claim.issue, state: 'parked', why: `attempt ${claim.attempts}: an issue is parked after ${LIMITS.attempts} attempts in a night` }
  } else if (claim && activeMs(d.waits, claim.since, now) >= LIMITS.stuckMs) {
    release = { issue: claim.issue, state: 'parked', why: `${mins(activeMs(d.waits, claim.since, now))} of active work on it, past the ${LIMITS.stuckMs / MIN / 60} hours an issue gets` }
  }
  if (release) told = `The driver parked #${release.issue} (${release.why}); its claim is ended, so leave it and claim the next issue. `
  if (d.parked) {
    told += `${d.parked} `
    d.parked = null
  }

  const measuredAt = d.weeklyAt ?? d.since
  if (d.finishing || now - measuredAt >= LIMITS.unmeasuredMs) {
    const first = !d.finishing
    d.finishing = true
    const why = `the weekly usage has had no reading for ${mins(now - measuredAt)}, so the night stops after the issue in hand (unmeasured)`
    const unmeasured: Note[] = first ? [{ kind: 'finding', ...where, text: why }] : []
    if (!claim || release) return stop(why, release, unmeasured)
    d.blocks++
    if (!progressed) d.idleBlocks++
    return {
      kind: 'block', record: d, notes: [...unmeasured, { kind: 'heartbeat', ...where }],
      reason: `${told}Finish #${claim.issue} and release it, then claim nothing new: ${why}. ${i.rules}`,
    }
  }

  d.blocks++
  if (!progressed) d.idleBlocks++
  const status = claim && !release ? `You hold #${claim.issue} in ${claim.repo} (attempt ${claim.attempts}): carry on with it. ` : 'You hold no issue: claim the next one. '
  return { kind: 'block', record: d, ...(release ? { release } : {}), notes: [{ kind: 'heartbeat', ...where }], reason: `${told}${status}${i.rules}` }
}

export type FailureDecision =
  | { kind: 'wait'; record: DriverRecord; minutes: number; notes: Note[] }
  | { kind: 'stop'; record: DriverRecord | null; why: string; notes: Note[] }

/**
 * A turn that ended on an API error (classic.StopFailure). It carries no reset time and calls an
 * overloaded server server_error (#839), so a usage limit and a busy server are both waited out:
 * 5, 10, 20, 40 minutes, then an hour between tries, all night, each wait noted (Dan, 2026-10-07).
 * Anything else (sign in, billing, a refused request) is noted and the session stops (H2, L365).
 */
export const decideFailure = (i: { now: number; self: string; generation: string; repo: string | null; driver: DriverReading; error: string; message: string; weekly: number | null }): FailureDecision => {
  const where = i.repo ? { repo: i.repo } : {}
  const said = i.message.replace(/\s+/g, ' ').trim().slice(0, 200)
  if (i.driver.state === 'unreadable') {
    const why = `${i.driver.why}, so after the ${i.error} error the driver stopped rather than retry on a count it cannot keep`
    return { kind: 'stop', record: null, why, notes: [{ kind: 'stopped', ...where, text: why }] }
  }
  const d: DriverRecord = i.driver.state === 'ok' ? { ...i.driver.record, waits: [...i.driver.record.waits] } : freshDriver(i.generation, i.self, i.now)
  if (d.stopped) return { kind: 'stop', record: d, why: d.stopped, notes: [] }
  if (i.weekly !== null) d.weeklyAt = i.now
  const stop = (why: string, failed: boolean): FailureDecision => {
    d.stopped = why
    return { kind: 'stop', record: d, why, notes: [...(failed ? [{ kind: 'failed', ...where, text: why }] : []), { kind: 'stopped', ...where, text: why }] }
  }
  if (i.weekly !== null && i.weekly >= LIMITS.weeklyStop) return stop(`the weekly limit is at ${pct(i.weekly)}, past the ${LIMITS.weeklyStop}% the night stops at`, false)
  if (!RETRY.has(i.error)) return stop(`the API answered ${i.error}${said ? ` (${said})` : ''}, which waiting does not cure`, true)
  const minutes = LIMITS.waitsMin[Math.min(d.waitStep, LIMITS.waitsMin.length - 1)] as number
  d.waitStep++
  d.resumeAt = i.now + minutes * MIN
  d.waits.push({ from: i.now, until: d.resumeAt })
  return { kind: 'wait', record: d, minutes, notes: [{ kind: 'wait', ...where, minutes, error: i.error, ...(said ? { text: said } : {}) }] }
}

/** Whether a wait is over and the session is due to be started again. */
export const resumeDue = (d: DriverRecord, now: number) => !d.stopped && d.resumeAt !== null && now >= d.resumeAt

/** What the session is told when it is started again after a wait. */
export const RESUME = 'Sleep mode: the wait after the API error is over. Carry on with the overnight work where it stopped, checking the claim and the branch before redoing anything.'

/**
 * The overnight rules, carried in every block so they survive compaction (#844). `self` and `root`
 * fill in the commands; nothing here names a phase that is not built.
 */
export const overnightRules = (self: string, root: string) =>
  [
    'Overnight rules (sleep mode): Dan is asleep and asks nothing tonight.',
    `Claim work with \`bash ~/.claude/hooks/lib/sleep-queue.sh next ${root} ${self}\`; it prints the issue and a worktree of its own: work only there, never switch branches in the primary checkout.`,
    'If it prints attempts=3 or more, release that issue as parked at once and claim the next.',
    'Work it test first, open a pull request, and follow the repository\'s own merge rules.',
    `When it is finished, or cannot be, end the claim with \`bash ~/.claude/hooks/lib/sleep-queue.sh release ${root} <issue> ${self} done|parked|failed "<why>"\` (it writes the note for the report), then claim the next.`,
    'Write anything for Dan with sleep_note from ~/.claude/hooks/lib/sleep.sh: a question (kind question), a proposed issue (kind issue), a lesson (kind lesson), or anything noticed (kind finding). Never file issues or ask him.',
    `When \`next\` prints none, write \`sleep_note '{"kind":"stopped","by":"${self}","text":"nothing left to claim"}'\` and stop.`,
    'What is done is judged from commits and notes, never from what you say, so commit and note as you go.',
  ].join(' ')
