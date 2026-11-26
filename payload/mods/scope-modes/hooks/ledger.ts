import { callKey, gaveNoVerdict } from './refusals.ts'

// The ledger of calls auto mode's safety check refused with a verdict (#3560). Until this, a refusal
// was recorded only while asleep, for the morning report, and whether a refused step was done again by
// the same agent, a sibling or the session that dispatched them rested on each of them following the
// rule. Measured on the personal MacBook on 2026-11-26 over the sessions of the 15 days before: 21
// verdict refusals (14 in main sessions, 7 in subagents), none sent again by anyone in its session
// tree, and 980 refusals the check gave no verdict on, 854 of them sent again by the same session or
// agent as "One unchanged resend after no verdict" allows. So the two are told apart here and nowhere
// else leans on memory.
//
// A refusal WITH a verdict is written, awake or asleep, one small file per refusal, under
// ~/.claude/state/safety-refusals/<session id>/. It holds who was refused, the tool, the check's own
// reason, when, and a hash of the call. Never the call: a command or a file's text is not kept.
//
// A refusal the check gave NO verdict on is never written, so nothing here can hold its one resend.
// Which it was is the one predicate the morning report already folds by (refusals.ts gaveNoVerdict).
//
// A later call by anyone in the session, whose hash is one in the ledger, is held before it runs.
// The session that dispatched a refused agent is told once, at the next thing it reads.
//
// What this process recorded is held in memory and decides first: a file that could not be written
// costs only the hold after a restart. The files are what a resumed session reads back.

/** One refusal with a verdict. `agent` is the subagent refused, null when it was the session itself. */
export type Refused = { at: number; when: string; agent: string | null; tool: string; reason: string; call: string; toolUseId: string; told?: number }

/** The few file steps the ledger takes, so it reads the same against the engine and against a test's files. */
export type LedgerIo = {
  exists: (path: string) => Promise<boolean>
  list: (dir: string) => Promise<readonly string[]>
  read: (path: string) => Promise<string>
  write: (path: string, text: string) => Promise<void>
  mkdir: (dir: string) => Promise<void>
}

/** Where a session's ledger is kept, on this Mac only. A session id that is no plain name has none. */
export const ledgerDir = (home: string, session: string): string | null =>
  /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(session) ? `${home.replace(/\/+$/, '')}/.claude/state/safety-refusals/${session}` : null

const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map(b => b.toString(16).padStart(2, '0')).join('')
const sha = async (text: string) => hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))

/** Which call this is, as the ledger keeps it: a hash of the tool and its own arguments (refusals.ts callKey). */
export const callHash = (tool: string, args: Record<string, unknown>): Promise<string> => sha(callKey(tool, args))

/** Whether a refusal is written: every one but those the check gave no verdict on. */
export const isVerdict = (reason: string): boolean => !gaveNoVerdict(reason)

// What runs even while the ledger cannot be read. Read, Grep and Glob: the check is never asked about
// them (Claude Code's own refusal says reading files and searching code need no classifier, and none
// of the 1,001 refusals measured was of one), so they can never be in the ledger. TaskStop: Dan's
// decision of 2026-10-22 (#1495) that a stop whose check errored is let through, since refusing it
// only keeps a job running. A TaskStop the check itself refused with a verdict is still held by its
// hash, like any other call.
const NEVER_JUDGED: ReadonlySet<string> = new Set(['Read', 'Grep', 'Glob', 'TaskStop'])

const HASH = /^[0-9a-f]{64}$/
const text = (v: unknown): v is string => typeof v === 'string'
/** A ledger file's entry, or why it is not one. */
export const parseEntry = (raw: string): Refused | { bad: string } => {
  let v: unknown
  try {
    v = JSON.parse(raw)
  } catch {
    return { bad: 'it is not JSON' }
  }
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return { bad: 'it is not a record' }
  const r = v as Record<string, unknown>
  if (typeof r.at !== 'number' || !Number.isFinite(r.at)) return { bad: 'it has no time' }
  if (!text(r.call) || !HASH.test(r.call)) return { bad: 'it has no hash of the call' }
  if (!text(r.tool) || !text(r.reason) || !text(r.when) || !text(r.toolUseId)) return { bad: 'it lacks the tool, the reason, the time in ET or the call id' }
  if (r.agent !== null && !text(r.agent)) return { bad: 'its agent is neither a name nor null' }
  if (r.told !== undefined && typeof r.told !== 'number') return { bad: 'its told time is not a number' }
  return { at: r.at, when: r.when, agent: r.agent, tool: r.tool, reason: r.reason, call: r.call, toolUseId: r.toolUseId, ...(r.told !== undefined ? { told: r.told } : {}) }
}

const fileOf = async (e: Refused) => `${/^[A-Za-z0-9_-]{1,120}$/.test(e.toolUseId) ? e.toolUseId : (await sha(`${e.at}:${e.call}:${e.toolUseId}`)).slice(0, 32)}.json`

type Session = { dir: string; entries: Refused[]; calls: Set<string>; read: boolean; unreadable: string | null }

/** What the ledger says of one call about to run. */
export type Held = { kind: 'clear' } | { kind: 'refused'; entries: Refused[] } | { kind: 'unreadable'; dir: string; why: string }

const message = (err: unknown) => (err instanceof Error ? err.message : String(err))

/** The ledgers of the sessions this load of the mod has met, each read from its files once. */
export const makeLedger = () => {
  const sessions = new Map<string, Session>()
  const of = (dir: string): Session => {
    let s = sessions.get(dir)
    if (!s) sessions.set(dir, (s = { dir, entries: [], calls: new Set(), read: false, unreadable: null }))
    return s
  }
  const keep = (s: Session, e: Refused) => {
    if (s.entries.some(x => x.toolUseId === e.toolUseId && x.call === e.call && x.at === e.at)) return
    s.entries.push(e)
    s.calls.add(e.call)
  }
  // Read once, and again at each call for as long as it cannot be read, so a ledger mended is found
  // mended. A folder that is not there holds nothing: a session nothing was refused in has none.
  const load = async (io: LedgerIo, s: Session) => {
    if (s.read) return
    try {
      if (!(await io.exists(s.dir))) {
        s.read = true
        s.unreadable = null
        return
      }
      const found: Refused[] = []
      for (const name of await io.list(s.dir)) {
        if (!name.endsWith('.json')) continue
        const e = parseEntry(await io.read(`${s.dir}/${name}`))
        if ('bad' in e) throw new Error(`${name} is not a ledger entry (${e.bad})`)
        found.push(e)
      }
      for (const e of found) keep(s, e)
      s.read = true
      s.unreadable = null
    } catch (err) {
      s.unreadable = message(err)
    }
  }
  return {
    /**
     * Writes one refusal with a verdict: into memory first, which this process holds by whatever the
     * disk does, then its file. Throws when the file could not be written, so the caller can say so.
     */
    record: async (io: LedgerIo, dir: string, e: Refused) => {
      const s = of(dir)
      keep(s, e)
      await io.mkdir(dir)
      await io.write(`${dir}/${await fileOf(e)}`, `${JSON.stringify(e)}\n`)
    },
    /**
     * Whether a call may run as far as the ledger goes. `hash` is asked for only when the ledger
     * holds something, so a session nothing was refused in pays for no hashing.
     */
    check: async (io: LedgerIo, dir: string, tool: string, hash: () => Promise<string>): Promise<Held> => {
      const s = of(dir)
      await load(io, s)
      if (s.calls.size) {
        const h = await hash()
        if (s.calls.has(h)) return { kind: 'refused', entries: s.entries.filter(e => e.call === h) }
      }
      if (s.unreadable !== null && !NEVER_JUDGED.has(tool)) return { kind: 'unreadable', dir: s.dir, why: s.unreadable }
      return { kind: 'clear' }
    },
    /**
     * The refusals of subagents the session has not been told of yet, oldest first: those this
     * process recorded, and those a resumed session read back at its first call. From memory alone.
     */
    untold: (dir: string): Refused[] => (sessions.get(dir)?.entries ?? []).filter(e => e.agent !== null && e.told === undefined).sort((a, b) => a.at - b.at),
    /**
     * Marks refusals told, in memory first, so each is said once in this process whatever the disk
     * does, then in its file, so a resumed session does not say it again. Throws when a file could
     * not be written.
     */
    markTold: async (io: LedgerIo, dir: string, entries: readonly Refused[], at: number) => {
      for (const e of entries) e.told = at
      for (const e of entries) await io.write(`${dir}/${await fileOf(e)}`, `${JSON.stringify(e)}\n`)
    },
  }
}

export type Ledger = ReturnType<typeof makeLedger>

const who = (agent: string | null) => (agent === null ? 'this session' : `agent ${agent}`)
const because = (reason: string) => (reason.trim() ? `its reason: ${reason.trim()}` : 'it gave no reason this mod could read')

/** What the session that dispatched a refused agent is told, once for each refusal. */
export const tellText = (entries: readonly Refused[]): string =>
  [
    `Auto mode's safety check refused ${entries.length === 1 ? 'a call' : `${entries.length} calls`} by ${entries.length === 1 ? 'an agent of this session' : 'agents of this session'}, with a verdict:`,
    ...entries.map(e => `${who(e.agent)}, ${e.tool}, at ${e.when} (${because(e.reason)})`),
    'A refusal with a verdict is final for the whole session: never send that call yourself, never hand it to another agent, and never reach the same end another way. The same call sent again by anyone in this session is held. Tell Dan what was refused when you next report to him.',
  ].join('\n')

/**
 * What a held call is answered with: what was refused, by whom, and that the way on is to report it.
 * `caller` is the agent sending the call now, undefined for the session itself.
 */
export const holdText = (entries: readonly Refused[], tool: string, caller: string | undefined, asleep: boolean): string => {
  const first = [...entries].sort((a, b) => a.at - b.at)[0] as Refused
  const whose = first.agent === null ? (caller === undefined ? 'when this session sent it' : 'when the session that dispatched you sent it') : first.agent === caller ? 'when you sent it' : `when ${who(first.agent)} sent it`
  const next =
    caller !== undefined
      ? 'Stop work on the step that needs it and hand back, quoting this refusal in your report.'
      : asleep
        ? 'Dan is asleep, so ask nothing: leave it for his morning, and go on only with work that does not need it.'
        : 'Tell Dan what was refused and why, and leave the decision to him.'
  return (
    `Held: this is the same ${tool} call that auto mode's safety check refused with a verdict at ${first.when}, ${whose} (${because(first.reason)}). ` +
    'A refusal with a verdict is final for everyone in this session, so the call was not run and the check was not asked again. ' +
    `${next} Never send it again, in pieces, through another tool or by another agent. Nothing in this session lifts this hold, a yes from Dan included: until he says how one is lifted (claude-config#3560), a step he wants done he does himself.`
  )
}

/** What a call is answered with while the ledger is there and cannot be read. */
export const unreadableText = (dir: string, why: string, caller: string | undefined): string =>
  `Held: this session's ledger of calls the safety check refused (${dir}) could not be read (${why}), so no call can be shown not to repeat one of them. ` +
  'Only Read, Grep, Glob and TaskStop run until it can be read again; it is tried afresh at every call. ' +
  (caller !== undefined ? 'Hand back and quote this refusal in your report.' : 'Tell Dan, who can mend or remove that folder; never remove it yourself.')
