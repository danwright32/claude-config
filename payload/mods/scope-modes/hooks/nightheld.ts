import { MODE_DEF } from './modes.ts'
import { overnightData } from './overnightdata.ts'

// #1284: while asleep, nothing is handed to Dan, in any session. Dan, 2026-10-17: "some sessions
// give me something to do immediately (like this image popped up within minutes of me entering
// sleep mode) and some wait until the morning." Every prompt used to tell a sleeping session to
// deliver as when he is away, a private claude.ai page at once, and only the Artifact tool's open
// action was held, so any session whose turn ended overnight published there and then.
//
// Now a call that hands him a result is held in every session while asleep (a rule only in the
// prompt is a hope, L27), kept in that session, and when sleep mode ends, however it ends, the
// session is asked to deliver it, where he is then: every session reports at the same moment.
// Only the decisions live here; register.ts holds the calls and asks for them at wake.

const base = (p: string) => p.replace(/\/+$/, '').split('/').pop() || p
// A link is named by where it goes, never by its query or fragment, which can carry a token (L741).
const shown = (url: string) => url.replace(/[?#].*$/, '')
// The Claude Docs connector's tools that make or change a doc Dan reads (its name carries the
// connector's prefix, which differs by how it is attached).
const DOC_WRITE = /Claude_Docs__(?:create|batch|update)$/

/** What a call hands Dan, as its held row reads, or undefined when it hands him nothing. */
export const deliveryOf = (tool: string, input: Record<string, unknown>): string | undefined => {
  if (tool === 'Artifact') {
    const action = input.action ?? 'publish'
    if (action === 'open') return `Open ${typeof input.url === 'string' ? shown(input.url) : 'the page'}`
    // An asset upload stores a file the page refers to; it shows Dan nothing by itself.
    if (action !== 'publish' || input.asset === true) return undefined
    return `Publish ${typeof input.file_path === 'string' ? base(input.file_path) : 'a page'}`
  }
  if (DOC_WRITE.test(tool)) return 'Publish a Claude doc'
  return undefined
}

/** How a held delivery is refused: the grey card and the reason Claude reads. */
export const heldUntilWake = (label: string): { card: { guard: string; reason: string; safeWay: string }; deny: string } => ({
  card: { guard: 'Asleep', reason: `Held for the morning: ${label}.`, safeWay: 'Claude delivers it when you wake.' },
  deny: `Held until Dan wakes: sleep mode is on, so nothing is published or opened for him tonight, and "${label}" did not run. Keep what it would have shown as it is and carry on; when sleep mode ends this session is asked to deliver it, where Dan is then. Do not publish it another way.`,
})

/**
 * How what needs Dan at the Mac (a dialog, typing into an app) is refused while he sleeps: it waits
 * in the held card for the morning, as away holds it, but Claude is never told to publish a page in
 * its place, which away's refusal says and which would hand him a result overnight.
 */
export const heldAsleep = (label: string): { card: { guard: string; reason: string; safeWay: string }; deny: string } => ({
  card: { guard: 'Asleep', reason: `Held for the morning: ${label}.`, safeWay: 'It waits in the held card until you are up.' },
  deny: `Held: Dan is asleep, so "${label}" waits in the held card for the morning. Leave it, say in your final message what is waiting on him, and carry on; publish nothing in its place.`,
})

/** What every prompt says about delivering while asleep, in place of away's "deliver as a page now". */
export const ASLEEP_DELIVERY = `Dan is asleep, so hand him nothing tonight: publish no page and open nothing for him to read. Keep what you would deliver in a file, say in your final message where it is, and carry on; when sleep mode ends, this session is asked to deliver what it held, where he is then. Do not ${MODE_DEF.away.willNot}.`

/** One call held while asleep: its row, and the call as it was made, to be made again at wake. */
export type HeldDelivery = { label: string; call: string }
/** A merge, deploy or push the night's lists refused in this session (#1285): put to Dan at wake. */
export type HeldMerge = HeldDelivery & { why: string }

/** A morning this session put to Dan (#1383): its night's generation (null when not known) and the held calls it carried. */
export type PutMorning = { generation: string | null; calls: string[] }

/**
 * Whether the morning about to be put is one this session already put (#1383): the same night, or
 * with the night already cleared, carrying no call the put one did not. A copy of the mod with fresh
 * memory reads the night and the held calls from $.state, where a mark that failed can leave them.
 */
export const alreadyPut = (put: PutMorning | null, night: { generation: string | null } | null, held: readonly HeldDelivery[]): boolean => {
  if (!put || !held.every(h => put.calls.includes(h.call))) return false
  return night === null || night.generation === put.generation
}

/** What a session is told at wake about what it held: empty when it held nothing. */
export const heldAtWake = (held: readonly HeldDelivery[]): string => {
  if (!held.length) return ''
  const n = held.length === 1 ? 'one thing' : `${held.length} things`
  return [
    `While Dan slept, this session held ${n} it would have handed him: ${held.map(h => h.label).join('; ')}. Deliver each now, where he is now (at home on the Mac as CLAUDE.md says, away as a private claude.ai page), making again the call held, as the block below gives it; anything since replaced by a newer copy is delivered once, as the newer copy.`,
    overnightData({ holds: 'the calls this session made overnight that were held until Dan woke', offer: 'delivered to Dan as each call was made; none is offered through a picker', lines: held.map(h => h.call) }),
  ].join('\n')
}
