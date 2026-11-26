import type { EngineInterface } from 'claude-code'
import type { IsItLiveAnnounceDone, IsItLiveAnnouncement } from '../types/index.d.ts'
import {
  type Asked,
  type Claimed,
  type Judged,
  NO_WORDING,
  OWED,
  type Pressed,
  type Said,
  type Standing,
  type Unapproved,
  alreadySettledOf,
  announceLetGoOf,
  announceRow,
  askedOf,
  cardUnapprovedOf,
  claimArgv,
  claimedOf,
  draftUnapprovedOf,
  notCopiedOf,
  unapprovedOf,
  firstPromptOf,
  holdOf,
  listOf,
  startLineOf,
  cardDraftOf,
  cardUndraftableOf,
  cardUnreadOf,
  cardWaitsOf,
  doneKey,
  doneOf,
  draftOutcomeOf,
  draftable,
  entryFrom,
  entryOf,
  idOf,
  judgeArgv,
  judgedOf,
  labelsOf,
  notKeptOf,
  outKey,
  owedKey,
  pressUnreadOf,
  readerArgv,
  rowIdOf,
  settledOf,
  unpinnedOf,
  unreadOf,
  unsettledOf,
} from './announce.ts'
import { MOD, type State, isOut } from './card.ts'
import { errorText } from './mod-kit/skew.ts'
import { NEVER, UNASKED } from './threads.ts'

// The announcement for agents a merged change owes (#3667; announce.ts says why, and how it is kept
// so that two sessions writing at once cannot lose it). This file reads and writes the store and
// runs the hooks' command lines; register.ts calls it when a merge lands and when a card is made.
//
// Every function here that is handed $ is a function declaration, the one form the engine follows
// $ into past an import.

const msg = (err: unknown) => errorText(err, MOD)
const SAID: Said = { never: NEVER, unasked: UNASKED }

// Per session, in $.state: which announcements this session's own card asked a draft of, the holds
// already refused in this chain of turn ends, the line its first prompt still has to carry, and the
// announcements whose row this session pinned in its band.
const askedRef = { plugin: 'is-it-live', key: 'announceAsked' } as const
const refusedRef = { plugin: 'is-it-live', key: 'announceRefused' } as const
const lineRef = { plugin: 'is-it-live', key: 'announceLine' } as const
const pinnedRef = { plugin: 'is-it-live', key: 'announcePinned' } as const

// Every change to what this session asked for goes through here, so two at once both land.
async function changeAsked($: EngineInterface, change: (ids: string[]) => string[]): Promise<void> {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(askedRef)
    if ((await $.state.set(askedRef, change(held.value ?? []), { ifVersion: held.version })).isSet) return
  }
  throw new Error('the list of announcements this session asked a draft of kept changing under it')
}
// And every change to the rows it pinned. Its own copy of the loop above, not one function taking
// the reference: the engine reads a state reference where it is written, and refuses to load a
// module that hands $.state one it cannot read there.
async function changePinned($: EngineInterface, change: (ids: string[]) => string[]): Promise<void> {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(pinnedRef)
    if ((await $.state.set(pinnedRef, change(held.value ?? []), { ifVersion: held.version })).isSet) return
  }
  throw new Error('the list of announcements this session pinned a row for kept changing under it')
}

// ---- the row in the band (announce.ts says what it holds) ----

// Pins one announcement's row in this session's band and notes that it did, or answers why it could
// not. Pinning again replaces the row, so every caller may pin what is already there.
async function pinAnnouncement($: EngineInterface, a: IsItLiveAnnouncement): Promise<string | undefined> {
  try {
    await $.modkit.bandRow(announceRow(MOD, a) as never)
    const id = idOf(a.repo, a.pr)
    await changePinned($, ids => (ids.includes(id) ? ids : [...ids, id]))
    return undefined
  } catch (err) {
    return msg(err)
  }
}

// Takes a row down by its id, or answers why it could not. The row is forgotten only once it is down.
async function takeDown($: EngineInterface, row: string): Promise<string | undefined> {
  try {
    await $.modkit.clearBandRow({ mod: MOD, id: row })
    await changePinned($, ids => ids.filter(id => rowIdOf(id) !== row))
    return undefined
  } catch (err) {
    return msg(err)
  }
}

// The rows this session pinned whose announcement is no longer owed (a draft was saved, Dan pressed
// Mark sent or Not announcing, here or in another session) are taken down. One that will not come
// down stays noted and is tried again at the next turn end or /live; a press on it says it is settled.
async function sweepRows($: EngineInterface): Promise<void> {
  const pinned = (await $.state.get(pinnedRef)).value ?? []
  if (!pinned.length) return
  const owed = (await announcementsOwed($)).map(a => idOf(a.repo, a.pr))
  for (const id of pinned) {
    if (owed.includes(id)) continue
    const why = await takeDown($, rowIdOf(id))
    if (why !== undefined) $.ui.log(`is-it-live: the row of a settled announcement for agents (${id}) could not be taken down: ${why}`, { to: 'debug' })
  }
}

/** What is kept for one pull request: its entry, and how it was settled, each absent where none reads. */
export async function announcementKept($: EngineInterface, repo: string, pr: number): Promise<{ entry?: IsItLiveAnnouncement; done?: IsItLiveAnnounceDone }> {
  const id = idOf(repo, pr)
  const entry = entryOf(await $.store.get(owedKey(id)))
  const done = doneOf(await $.store.get(doneKey(id)))
  return { ...(entry ? { entry } : {}), ...(done ? { done } : {}) }
}

/**
 * Whether GitHub should be asked about a merged pull request's announcement: not once it is settled,
 * and not while an entry that reads is kept. One kept with a why is asked for again, since what could
 * not be told then (a registry that would not read) may be told now.
 */
export async function announcementUnread($: EngineInterface, repo: string, pr: number): Promise<boolean> {
  const { entry, done } = await announcementKept($, repo, pr)
  return done === undefined && (entry === undefined || entry.why !== undefined)
}

/**
 * Keeps what a merged pull request owes, from GitHub's answer about its labels and description
 * (`read`, which register.ts asks as each account): the merge gate's reader is run on it, and an
 * answer of owed or unknown is written whole under the pull request's own key. Safe to run twice and
 * from two sessions at once: the same answer writes the same entry, first kept time aside, an entry
 * that reads is not replaced by one that does not (but for the instant said below, which the next
 * card mends), and that it was settled is another key, which
 * this never writes. What could not be told at all is said to Dan and handed back, never kept as
 * owed on a guess: the card asks again.
 */
export async function noteAnnouncement($: EngineInterface, repo: string, pr: number, read: { out: string } | { error: string }): Promise<Asked> {
  const labels = labelsOf(read)
  let asked: Asked
  if (labels.kind === 'none') asked = { kind: 'none' }
  else if (labels.kind === 'unread') asked = labels
  else {
    try {
      const r = await $.process.run(readerArgv((await $.env.get('HOME')) ?? '', repo), { stdin: labels.json, timeoutMs: 20_000 })
      asked = askedOf(r)
    } catch (err) {
      asked = { kind: 'unread', why: `the merge gate's reader could not be run: ${msg(err)}` }
    }
  }
  if (asked.kind === 'unread') $.ui.toast(unreadOf({ repo, pr }, asked.why))
  if (asked.kind !== 'owed' && asked.kind !== 'unknown') return asked
  // Read once the reader has answered, as near the write as the store allows (it has no way to
  // refuse a write made on a stale read): a whole entry another session kept while the reader ran is
  // kept. One written in the instant between this read and the write below can still be replaced by
  // an entry with a why, which the next card asks about again and mends.
  const at = await $.clock.now()
  const before = await announcementKept($, repo, pr)
  if (before.entry && before.entry.why === undefined) return asked
  // Nor is one written once it is settled: settled is never taken back, here or by any reader.
  if (before.done) return asked
  await $.store.set(owedKey(idOf(repo, pr)), entryFrom(repo, pr, asked, before.entry?.at ?? at))
  return asked
}

/** Every announcement kept and not settled, oldest first, whether or not its change is out yet. */
export async function announcementsOwed($: EngineInterface): Promise<IsItLiveAnnouncement[]> {
  const out: IsItLiveAnnouncement[] = []
  for (const k of await $.store.keys()) {
    if (!k.startsWith(OWED)) continue
    const entry = entryOf(await $.store.get(k))
    if (entry && doneOf(await $.store.get(doneKey(idOf(entry.repo, entry.pr)))) === undefined) out.push(entry)
  }
  return out.sort((a, b) => a.at - b.at)
}

/** Whether a card has said this announcement's change is out. */
export async function announcementOut($: EngineInterface, a: { repo: string; pr: number }): Promise<boolean> {
  return (await $.store.get(outKey(idOf(a.repo, a.pr)))) !== undefined
}

// Whether the wording kept for an announcement is the wording its pull request merged on, by the
// hooks' one check (announce.ts says why it is asked). A check that could not be run is unchecked,
// never approved.
async function claimed($: EngineInterface, a: IsItLiveAnnouncement): Promise<Claimed> {
  try {
    return claimedOf(await $.process.run(claimArgv((await $.env.get('HOME')) ?? '', a.repo, a.pr), { stdin: a.text, timeoutMs: 30_000 }))
  } catch (err) {
    return { state: 'unchecked', why: `the check could not be run: ${msg(err)}` }
  }
}

// The same check, asked from a press. Claude Code cuts a press off at 10 seconds whatever it is
// waiting on (#744), so the check gets 6 of them here, leaving the rest for the store reads before
// it and the copy after. One that does not answer in time is unchecked: Copy then copies nothing and
// says why, writes nothing, and the next press asks again. The check reads one file on this Mac, so
// it answers in well under a second unless the Mac is starved.
async function claimedAtPress($: EngineInterface, a: IsItLiveAnnouncement): Promise<Claimed> {
  try {
    return claimedOf(await $.process.run(claimArgv((await $.env.get('HOME')) ?? '', a.repo, a.pr), { stdin: a.text, timeoutMs: 6_000 }))
  } catch (err) {
    return { state: 'unchecked', why: `the check could not be run: ${msg(err)}` }
  }
}

// An entry whose wording is not known to be the approved one is kept as one that cannot be drafted,
// with why: /live, the row and each session start then say that, no draft is asked for or counted,
// and, as with any entry kept with a why, the next card reads the pull request again, so wording put
// back to what Dan approved is found.
async function keepUnapproved($: EngineInterface, a: IsItLiveAnnouncement, c: Unapproved): Promise<IsItLiveAnnouncement> {
  const kept: IsItLiveAnnouncement = { ...a, why: unapprovedOf(c) }
  await $.store.set(owedKey(idOf(a.repo, a.pr)), kept)
  return kept
}

// Settled, under its own key: written once and never taken back. Two sessions settling at once both
// write that it is settled, and the later way of settling is the one kept.
async function settle($: EngineInterface, a: { repo: string; pr: number }, how: IsItLiveAnnounceDone['how'], draftId?: string): Promise<void> {
  await $.store.set(doneKey(idOf(a.repo, a.pr)), { how, at: await $.clock.now(), ...(draftId ? { draftId } : {}) } satisfies IsItLiveAnnounceDone)
}

/**
 * What a card's answer says of the announcement its pull request owes, once register.ts has asked
 * about it (`asked`, absent where what is kept was enough). Nothing for a change that owes none or
 * whose announcement is settled, so `drafted` is never asked for again and a second card cannot make
 * a duplicate. A card saying the change is out records that under the pull request's own key and
 * asks for the draft; any other card asks for nothing and settles nothing.
 */
export async function announcementAtCard($: EngineInterface, repo: string, pr: number, state: State, asked: Asked | undefined): Promise<string[]> {
  try {
    const { entry, done } = await announcementKept($, repo, pr)
    if (done) return []
    if (!entry) return asked?.kind === 'unread' ? [cardUnreadOf({ repo, pr }, asked.why)] : []
    if (!isOut(state)) return [cardWaitsOf(entry)]
    if (!(await announcementOut($, entry))) await $.store.set(outKey(idOf(repo, pr)), { at: await $.clock.now() })
    // A draft is asked for only where the wording kept is the wording the pull request merged on.
    let kept = entry
    let refused: Unapproved | undefined
    if (draftable(entry)) {
      const c = await claimed($, entry)
      if (c.state !== 'approved') {
        refused = c
        kept = await keepUnapproved($, entry, c)
      }
    }
    // Owed and out: its row is pinned, so Mark sent and Not announcing are at hand from now on.
    const unpinned = await pinAnnouncement($, kept)
    const notes = unpinned === undefined ? [] : [unpinnedOf(kept, unpinned)]
    if (refused) return [cardUnapprovedOf(kept, refused, unpinned === undefined), ...notes]
    if (!draftable(kept)) return [cardUndraftableOf(kept, unpinned === undefined), ...notes]
    // This session's card asked for the draft, so its turn end is held for it once (announcementHold).
    await changeAsked($, ids => (ids.includes(idOf(repo, pr)) ? ids : [...ids, idOf(repo, pr)]))
    return [cardDraftOf(kept, SAID), ...notes]
  } catch (err) {
    return [cardUnreadOf({ repo, pr }, `what is kept for it could not be read or written: ${msg(err)}`)]
  }
}

type Called = { deny?: unknown; isError?: unknown; text?: unknown; result?: unknown; context?: readonly string[] }
const answerText = (o: Called): string => (typeof o.text === 'string' ? o.text : typeof o.result === 'string' ? o.result : JSON.stringify(o.result ?? ''))

// One draft against one announcement, by the hooks' one judgement.
async function judge($: EngineInterface, a: IsItLiveAnnouncement, message: unknown, done: Called): Promise<Judged> {
  try {
    const stdin = JSON.stringify({ text: a.text, message, answer: { text: answerText(done), isError: done.isError === true } })
    return judgedOf(await $.process.run(judgeArgv((await $.env.get('HOME')) ?? ''), { stdin, timeoutMs: 20_000 }))
  } catch (err) {
    return { state: 'unjudged', why: `the judgement could not be run: ${msg(err)}` }
  }
}

/**
 * A Slack draft to a channel with no thread went through the guards beneath (drafts.ts hands it
 * here): judged as the draft of each announcement that channel is still owed. One Slack kept that
 * holds an announcement's approved wording settles that announcement as drafted. Anything else
 * leaves every one owed and is said, to the session in the call's answer and to Dan on the spot,
 * never passed off as saved. A draft to a channel that is owed nothing, and a call a guard refused,
 * are not this mod's and are handed back untouched.
 */
export async function announcementDrafted<T extends Called>($: EngineInterface, call: { channel: string; message: unknown }, done: T): Promise<T> {
  if (done.deny !== undefined) return done
  try {
    const owed = (await announcementsOwed($)).filter(a => draftable(a) && a.channel === call.channel)
    if (!owed.length) return done
    const judged: { a: IsItLiveAnnouncement; j: Judged }[] = []
    const unapproved: { context: string; toast: string }[] = []
    for (const a of owed) {
      // A draft is compared only with wording known to be what the pull request merged on: wording
      // changed since, or whose approval cannot be read, is no approved wording to count a draft by.
      const c = await claimed($, a)
      if (c.state === 'approved') {
        judged.push({ a, j: await judge($, a, call.message, done) })
        continue
      }
      const kept = await keepUnapproved($, a, c)
      if (await announcementOut($, kept)) await pinAnnouncement($, kept)
      unapproved.push(draftUnapprovedOf(kept, c))
    }
    // The draft is one message, so it is at most one announcement's: the first whose wording it holds.
    const saved = judged.find(x => x.j.state === 'saved')
    const said: { context: string; toast: string }[] = []
    if (saved && saved.j.state === 'saved') {
      await settle($, saved.a, 'drafted', saved.j.draftId)
      // Drafted, so its row comes down. One that will not is tried again at the next turn end or /live.
      const stuck = await takeDown($, rowIdOf(idOf(saved.a.repo, saved.a.pr)))
      if (stuck !== undefined) $.ui.log(`is-it-live: the row of the announcement for agents just drafted could not be taken down: ${stuck}`, { to: 'debug' })
      said.push(draftOutcomeOf(saved.a, saved.j, NEVER, false))
    } else {
      // Still owed: what Dan is told names its row's buttons only where the row is in this session's
      // band, which is where its change is out and the band took the row (pinned again here, so a
      // session that never carded it has it too).
      for (const x of judged) said.push(draftOutcomeOf(x.a, x.j, NEVER, (await announcementOut($, x.a)) && (await pinAnnouncement($, x.a)) === undefined))
    }
    said.push(...unapproved)
    for (const s of said) $.ui.toast(s.toast)
    return { ...done, context: [...(done.context ?? []), ...said.map(s => s.context)] }
  } catch (err) {
    // Said, never swallowed: a draft nobody could check against what is owed has settled nothing.
    const why = `Is it live could not check the Slack draft in channel ${call.channel} against the announcements for agents still owed (${msg(err)}), so none was settled by it.`
    $.ui.toast(why)
    return { ...done, context: [...(done.context ?? []), `${why} Tell Dan that.`] }
  }
}

// Where each owed announcement stands, oldest first; given repository names, only theirs (GitHub's
// names are one name in any case).
async function standings($: EngineInterface, names?: readonly string[]): Promise<Standing[]> {
  const wanted = names?.map(n => n.toLowerCase())
  const out: Standing[] = []
  for (const a of await announcementsOwed($)) {
    if (wanted && !wanted.includes(a.repo.toLowerCase())) continue
    out.push({ a, out: await announcementOut($, a) })
  }
  return out
}

/**
 * /live: what the repository, under each name it is kept by, still owes agents, to follow its cards.
 * A list that cannot be read is said as that, never as nothing owed. Each one whose change is out is
 * pinned in the band again, as /live pins each message not yet sent, and the rows of those settled
 * since come down.
 */
export async function announcementList($: EngineInterface, names: readonly string[]): Promise<string> {
  try {
    const all = await standings($, names)
    const unpinned: string[] = []
    for (const s of all) {
      if (!s.out) continue
      const why = await pinAnnouncement($, s.a)
      if (why !== undefined) unpinned.push(unpinnedOf(s.a, why, true))
    }
    await sweepRows($)
    return listOf(all) + unpinned.map(u => `\n\n${u}`).join('')
  } catch (err) {
    return `\n\nThe announcements for agents this project still owes could not be read (${msg(err)}).`
  }
}

// A session start in a project that still owes an announcement says it in one line: to Dan now, and
// to the session with its first prompt, since a session start carries nothing to the model. Asked
// of the store first, so a session in a project owing nothing reads no repository at all. The
// project is the session folder's GitHub repository by its remote's name, as mod-kit reads it.
// Called from register.ts's session.start, the one hook this mod may register on that event.
export async function announcementsAtStart($: EngineInterface): Promise<void> {
  try {
    if (!(await announcementsOwed($)).length) return
    const here = await $.session.repo()
    const repo = here ? (await $.modkit.repo({ root: here.root, remote: here.remote })).github : null
    if (!repo) return
    const all = await standings($, [repo])
    // Each one whose change is out gets its row, so the line below names a row only where one is.
    let rows = true
    for (const s of all) {
      if (!s.out) continue
      const why = await pinAnnouncement($, s.a)
      if (why === undefined) continue
      rows = false
      $.ui.toast(unpinnedOf(s.a, why))
    }
    const line = startLineOf(all, rows)
    if (!line) return
    await $.state.set(lineRef, firstPromptOf(line))
    $.ui.toast(line)
  } catch (err) {
    $.ui.toast(`Is it live could not read whether this project still owes an announcement for agents: ${msg(err)}`)
  }
}

/**
 * The hold a turn end carries for the announcements this session's own card found live and asked a
 * draft of, while they are still not drafted, or undefined. Held once per announcement in a chain
 * of turn ends, as the thread reply's hold is, so a draft that cannot be saved never traps the turn:
 * the next end in the chain goes ahead, said. A session that only heard of one holds nothing.
 */
export async function announcementHold($: EngineInterface, e: { stop_hook_active?: boolean }): Promise<string | undefined> {
  // First the rows of those settled since the last turn end come down, whoever settled them.
  await sweepRows($)
  const asked = (await $.state.get(askedRef)).value ?? []
  if (!asked.length) return undefined
  const due = (await announcementsOwed($)).filter(a => draftable(a) && asked.includes(idOf(a.repo, a.pr)))
  // One settled since, by a draft or by Dan, is asked of no later turn end.
  if (due.length !== asked.length) await changeAsked($, ids => ids.filter(id => due.some(a => idOf(a.repo, a.pr) === id)))
  if (!due.length) return undefined
  const keyOf = (a: IsItLiveAnnouncement) => idOf(a.repo, a.pr)
  const held = (await $.state.get(refusedRef)).value
  const before = e.stop_hook_active && held ? held : { keys: [], told: [] }
  const fresh = due.filter(a => !before.keys.includes(keyOf(a)))
  if (!fresh.length) {
    const untold = due.filter(a => !before.told.includes(keyOf(a)))
    if (untold.length) {
      // Said to stay in the band only where each one's row is there now: pinned again to be sure.
      let rows = true
      for (const a of untold) if ((await pinAnnouncement($, a)) !== undefined) rows = false
      $.ui.toast(announceLetGoOf(untold, rows))
      await $.state.set(refusedRef, { keys: before.keys, told: [...before.told, ...untold.map(keyOf)] })
    }
    return undefined
  }
  await $.state.set(refusedRef, { keys: [...before.keys, ...fresh.map(keyOf)], told: before.told })
  return holdOf(due, SAID)
}

// The announcement a row is for, with how it was settled when it was: found among every entry kept,
// settled or not, by the row's id. Two repositories whose names differ only in punctuation share a
// row id, as they share the message row's (card.ts, buttonId), so one still owed is taken first.
async function announcementOfRow($: EngineInterface, row: string): Promise<{ entry: IsItLiveAnnouncement; done?: IsItLiveAnnounceDone } | undefined> {
  let settled: { entry: IsItLiveAnnouncement; done: IsItLiveAnnounceDone } | undefined
  for (const k of await $.store.keys()) {
    if (!k.startsWith(OWED)) continue
    const entry = entryOf(await $.store.get(k))
    if (!entry || rowIdOf(idOf(entry.repo, entry.pr)) !== row) continue
    const done = doneOf(await $.store.get(doneKey(idOf(entry.repo, entry.pr))))
    if (!done) return { entry }
    settled ??= { entry, done }
  }
  return settled
}

/**
 * A press of Copy, Mark sent or Not announcing on an announcement's row, as mod-kit raised it: a
 * click on the button, or /press typed at the prompt. This is the only place `sent` and
 * `not-announcing` are ever written, so nothing a session can call settles an announcement that way.
 * Copy copies the approved wording and settles nothing. Every outcome is said to Dan, and a press
 * that could not be recorded leaves the row up for another.
 */
export async function announcementPressed($: EngineInterface, p: { verb: Pressed; row: string }, surface: unknown): Promise<void> {
  let found: { entry: IsItLiveAnnouncement; done?: IsItLiveAnnounceDone } | undefined
  try {
    found = await announcementOfRow($, p.row)
  } catch (err) {
    $.ui.toast(pressUnreadOf(msg(err)))
    return
  }
  // Settled since the row was pinned, or no longer kept: nothing is written over what is settled.
  if (!found || found.done) {
    const stuck = await takeDown($, p.row)
    $.ui.toast(found ? alreadySettledOf(stuck) : notKeptOf(stuck))
    return
  }
  const a = found.entry
  if (p.verb === 'copy') {
    if (!a.text.trim()) {
      $.ui.toast(NO_WORDING)
      return
    }
    // Copy hands over only the wording the pull request merged on, as a draft would.
    const c = await claimedAtPress($, a)
    if (c.state !== 'approved') {
      $.ui.toast(notCopiedOf(a, c))
      return
    }
    try {
      const r = await $.ui.copy({ text: a.text, surface: surface as never })
      if (!r.isCopied) $.ui.toast(`Not copied: ${r.reason}`)
    } catch (err) {
      $.ui.toast(`Not copied: ${msg(err)}`)
    }
    return
  }
  const how = p.verb === 'sent' ? 'sent' : 'not-announcing'
  try {
    await settle($, a, how)
  } catch (err) {
    // Read back, so what Dan is told is what the store holds, not what the failed write intended.
    let owed: boolean | undefined
    try {
      owed = (await announcementKept($, a.repo, a.pr)).done === undefined
    } catch {
      owed = undefined
    }
    // Settled all the same means another write settled it, perhaps another way: said as that.
    $.ui.toast(owed === false ? alreadySettledOf(await takeDown($, p.row)) : unsettledOf(a, msg(err), owed))
    return
  }
  $.ui.toast(settledOf(a, how, await takeDown($, p.row)))
}

/**
 * The session's first prompt carries the line its start said to Dan, once: `r` is what the prompt
 * came to beneath, handed back with the line added to its context. Called from the one
 * prompt.submit hook this mod may register (drafts.ts), since the engine takes one per event.
 */
export async function withAnnouncementLine<T extends { context?: readonly string[] }>($: EngineInterface, r: T): Promise<T> {
  try {
    const line = (await $.state.get(lineRef)).value
    if (!line) return r
    await $.state.set(lineRef, '')
    return { ...r, context: [...(r.context ?? []), line] }
  } catch (err) {
    $.ui.log(`is-it-live: could not hand the session the line about announcements still owed: ${msg(err)}`, { to: 'debug' })
    return r
  }
}
