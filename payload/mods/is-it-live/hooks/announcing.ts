import type { EngineInterface } from 'claude-code'
import type { IsItLiveAnnounceDone, IsItLiveAnnouncement } from '../types/index.d.ts'
import { type Asked, askedOf, doneKey, doneOf, entryFrom, entryOf, idOf, labelsOf, owedKey, readerArgv, unreadOf } from './announce.ts'
import { MOD } from './card.ts'
import { errorText } from './mod-kit/skew.ts'

// The announcement for agents a merged change owes (#3667; announce.ts says why, and how it is kept
// so that two sessions writing at once cannot lose it). This file reads and writes the store and
// runs the hooks' command lines; register.ts calls it when a merge lands and when a card is made.
//
// Every function here that is handed $ is a function declaration, the one form the engine follows
// $ into past an import.

const msg = (err: unknown) => errorText(err, MOD)

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
  await $.store.set(owedKey(idOf(repo, pr)), entryFrom(repo, pr, asked, before.entry?.at ?? (await $.clock.now())))
  return asked
}
