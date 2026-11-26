import type { IsItLiveAnnounceDone, IsItLiveAnnouncement } from '../types/index.d.ts'

// The announcement for agents a merged change owes (claude-config#3667). A change labelled as one
// agents must or can act on differently carries its whole post in its pull request, and Dan approved
// that exact wording before it merged (#3666). Once the change is live the post is saved as a Slack
// draft in the announcements channel for Dan to send himself: nothing is ever sent by a session
// (payload/CLAUDE.md, "Slack: drafts only"), and this mod never calls a Slack tool at all.
//
// What is owed is kept where every session finds it, the store, and outside the list of cards, which
// keeps the newest 50: one key per pull request and per fact, each written whole and never read,
// changed and written back, since the store has no way to refuse a write made on a stale read.
//   announce:<owner/name>#<pr>       what is owed (IsItLiveAnnouncement)
//   announce-out:<owner/name>#<pr>   a card said its change is out, so it can be drafted now
//   announce-done:<owner/name>#<pr>  it was settled (IsItLiveAnnounceDone), never taken back
// So two sessions writing at once, or one writing twice, leave the same keys: an entry written again
// is the same entry, and nothing that writes what is owed can undo that it was settled.
//
// Which changes owe one, where it goes and its exact wording are the merge gate's answer
// (hooks/lib/changelog-entry.js, `announcement <owner/name>`), never worked out here. Pure:
// announcing.ts reads the store, runs the command lines and keeps what this decides.

const fold = (repo: string) => repo.toLowerCase()

/** An announcement's id: its repository in lowercase (GitHub's names are one name in any case) and its pull request. */
export const idOf = (repo: string, pr: number): string => `${fold(repo)}#${pr}`

export const OWED = 'announce:'
export const OUT = 'announce-out:'
export const DONE = 'announce-done:'
export const owedKey = (id: string): string => `${OWED}${id}`
export const outKey = (id: string): string => `${OUT}${id}`
export const doneKey = (id: string): string => `${DONE}${id}`

/** How a pull request is named to Dan and the session: a number always carries its noun. */
export const nameOf = (a: { repo: string; pr: number }): string => `${a.repo} pull request ${a.pr}`

const record = (v: unknown): Record<string, unknown> | null => (v !== null && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null)
const text = (v: unknown): v is string => typeof v === 'string'

/** An entry as kept, or undefined for anything else under its key: a value read from the store is never trusted to be whole. */
export const entryOf = (v: unknown): IsItLiveAnnouncement | undefined => {
  const o = record(v)
  if (!o || !text(o.repo) || !Number.isInteger(o.pr) || !text(o.channel) || !text(o.text) || !text(o.normalized) || !text(o.hash) || typeof o.at !== 'number') return undefined
  if (o.why !== undefined && !text(o.why)) return undefined
  return { repo: o.repo, pr: o.pr as number, channel: o.channel, text: o.text, normalized: o.normalized, hash: o.hash, at: o.at, ...(text(o.why) ? { why: o.why } : {}) }
}

/** How an announcement was settled, as kept, or undefined for anything else under its key. */
export const doneOf = (v: unknown): IsItLiveAnnounceDone | undefined => {
  const o = record(v)
  if (!o || (o.how !== 'drafted' && o.how !== 'sent' && o.how !== 'not-announcing') || typeof o.at !== 'number') return undefined
  return { how: o.how, at: o.at, ...(text(o.draftId) ? { draftId: o.draftId } : {}) }
}

/** Whether an entry can be drafted from this Mac: the gate's reader gave its channel and its wording. */
export const draftable = (a: IsItLiveAnnouncement): boolean => a.why === undefined && a.channel !== '' && a.text.trim() !== ''

/** What running a command line gave. */
export type Ran = { exitCode: number; stdout: string; stderr: string; isStdoutTruncated?: boolean }

/** How the merge gate's reader is asked what a merged pull request owes: its own command line, in the hooks installed on this Mac, the pull request as JSON on standard input. */
export const readerArgv = (home: string, repo: string): string[] => ['node', `${home}/.claude/hooks/lib/changelog-entry.js`, 'announcement', repo]

/**
 * What a merged pull request owes, as far as it could be told: `none` (it carries no announce label,
 * so nothing is owed and nothing is ever asked about it), `owed` with where and what, `unknown` (it
 * is labelled as one to announce and the reader could not tell the rest, `why`), or `unread`: whether
 * it owes anything could not be told at all, which is never taken for owing nothing.
 */
export type Asked =
  | { kind: 'none' }
  | { kind: 'owed'; channel: string; text: string; normalized: string; hash: string }
  | { kind: 'unknown'; why: string; text: string; normalized: string; hash: string }
  | { kind: 'unread'; why: string }

/**
 * What GitHub's answer to `gh pr view --json labels,body` holds for the reader: the answer itself, to
 * hand on as it came, or `none` for a pull request carrying no label at all, which cannot carry the
 * one that owes an announcement (so the reader is not run for it), or why it could not be read.
 */
export const labelsOf = (read: { out: string } | { error: string }): { kind: 'ask'; json: string } | { kind: 'none' } | { kind: 'unread'; why: string } => {
  if ('error' in read) return { kind: 'unread', why: `GitHub could not be asked for its labels: ${read.error}` }
  let o: Record<string, unknown> | null
  try {
    o = record(JSON.parse(read.out))
  } catch {
    o = null
  }
  if (!o || !Array.isArray(o.labels)) return { kind: 'unread', why: "GitHub's answer named no list of labels" }
  return o.labels.length ? { kind: 'ask', json: read.out } : { kind: 'none' }
}

const SHAPE = 'its answer was not one this reader knows'
/** The reader's answer, from what running it printed. Anything but a whole answer is unread, never "owes nothing". */
export const askedOf = (r: Ran): Asked => {
  const failed = (why: string): Asked => ({ kind: 'unread', why: `the merge gate's reader failed: ${why}` })
  if (r.exitCode !== 0) return failed(r.stderr.trim().split('\n').pop() || `it exited ${r.exitCode}`)
  if (r.isStdoutTruncated) return failed('its answer was cut short')
  let o: Record<string, unknown> | null
  try {
    o = record(JSON.parse(r.stdout))
  } catch {
    return failed('its answer was not JSON')
  }
  if (!o || !text(o.channel) || !text(o.text) || !text(o.normalized) || !text(o.hash) || !text(o.why)) return failed(SHAPE)
  if (o.state === 'none') return { kind: 'none' }
  const words = { text: o.text, normalized: o.normalized, hash: o.hash }
  if (o.state === 'unknown') return { kind: 'unknown', why: o.why.trim() || 'the reader gave no reason', ...words }
  // Owed is a channel, a post and its hash, all three: an answer missing one could not be drafted or compared.
  if (o.state !== 'owed' || !o.channel || !o.text.trim() || !o.hash) return failed(SHAPE)
  return { kind: 'owed', channel: o.channel, ...words }
}

/** The entry to keep for an answer that owes one, first kept at `at`. */
export const entryFrom = (repo: string, pr: number, a: Extract<Asked, { kind: 'owed' | 'unknown' }>, at: number): IsItLiveAnnouncement => ({
  repo,
  pr,
  channel: a.kind === 'owed' ? a.channel : '',
  text: a.text,
  normalized: a.normalized,
  hash: a.hash,
  at,
  ...(a.kind === 'unknown' ? { why: a.why } : {}),
})

/** What Dan is told when whether a merged change owes an announcement could not be told at all. */
export const unreadOf = (a: { repo: string; pr: number }, why: string): string =>
  `Is it live could not tell whether ${nameOf(a)} owes an announcement for agents (${why}). It is asked again when its card is made.`
