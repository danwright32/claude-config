import type { EngineInterface } from 'claude-code'
import type { IsItLiveAnnounceDone, IsItLiveAnnouncement } from '../types/index.d.ts'
import {
  type Asked,
  type Judged,
  OWED,
  type Said,
  type Standing,
  announceLetGoOf,
  askedOf,
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
  outKey,
  owedKey,
  readerArgv,
  unreadOf,
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
// already refused in this chain of turn ends, and the line its first prompt still has to carry.
const askedRef = { plugin: 'is-it-live', key: 'announceAsked' } as const
const refusedRef = { plugin: 'is-it-live', key: 'announceRefused' } as const
const lineRef = { plugin: 'is-it-live', key: 'announceLine' } as const

// Every change to what this session asked for goes through here, so two at once both land.
async function changeAsked($: EngineInterface, change: (ids: string[]) => string[]): Promise<void> {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(askedRef)
    if ((await $.state.set(askedRef, change(held.value ?? []), { ifVersion: held.version })).isSet) return
  }
  throw new Error('the list of announcements this session asked a draft of kept changing under it')
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
 * that reads is never replaced by one that does not, and that it was settled is another key, which
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
  const before = await announcementKept($, repo, pr)
  // Read again just before the write, so a session that kept a whole entry meanwhile keeps it.
  if (before.entry && before.entry.why === undefined) return asked
  // Nor is one written once it is settled: settled is never taken back, here or by any reader.
  if (before.done) return asked
  await $.store.set(owedKey(idOf(repo, pr)), entryFrom(repo, pr, asked, before.entry?.at ?? (await $.clock.now())))
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
    if (!draftable(entry)) return [cardUndraftableOf(entry)]
    // This session's card asked for the draft, so its turn end is held for it once (announcementHold).
    await changeAsked($, ids => (ids.includes(idOf(repo, pr)) ? ids : [...ids, idOf(repo, pr)]))
    return [cardDraftOf(entry, SAID)]
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
    for (const a of owed) judged.push({ a, j: await judge($, a, call.message, done) })
    // The draft is one message, so it is at most one announcement's: the first whose wording it holds.
    const saved = judged.find(x => x.j.state === 'saved')
    if (saved && saved.j.state === 'saved') await settle($, saved.a, 'drafted', saved.j.draftId)
    const said = (saved ? [saved] : judged).map(x => draftOutcomeOf(x.a, x.j, NEVER))
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

/** /live: what the repository, under each name it is kept by, still owes agents, to follow its cards. A list that cannot be read is said as that, never as nothing owed. */
export async function announcementList($: EngineInterface, names: readonly string[]): Promise<string> {
  try {
    return listOf(await standings($, names))
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
    const line = startLineOf(await standings($, [repo]))
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
      $.ui.toast(announceLetGoOf(untold))
      await $.state.set(refusedRef, { keys: before.keys, told: [...before.told, ...untold.map(keyOf)] })
    }
    return undefined
  }
  await $.state.set(refusedRef, { keys: [...before.keys, ...fresh.map(keyOf)], told: before.told })
  return holdOf(due, SAID)
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
