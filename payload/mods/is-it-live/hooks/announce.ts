import type { IsItLiveAnnounceDone, IsItLiveAnnouncement } from '../types/index.d.ts'

// The announcement for agents a merged change owes (claude-config#3667). A change labelled as one
// agents must or can act on differently carries its whole post in its pull request, and Dan approved
// that exact wording before it merged (#3666). Once the change is live the post is saved as a Slack
// draft in the announcements channel for Dan to send himself: nothing is ever sent by a session
// (payload/CLAUDE.md, "Slack: drafts only"), and this mod never calls a Slack tool at all.
//
// What is owed is kept where every session finds it, the store, and outside the list of cards, which
// keeps the newest 50: one key per pull request and per fact, each written whole, since the store
// has no way to refuse a write made on a stale read.
//   announce:<owner/name>#<pr>       what is owed (IsItLiveAnnouncement)
//   announce-out:<owner/name>#<pr>   a card said its change is out, so it can be drafted now
//   announce-done:<owner/name>#<pr>  it was settled (IsItLiveAnnounceDone), never taken back
// So two sessions writing at once, or one writing twice, leave the same keys: an entry written again
// is the same entry, and nothing that writes what is owed can undo that it was settled. Two
// writes follow a read, both of the entry itself (announcing.ts): noteAnnouncement checks what is
// kept, then writes, and keepUnapproved writes the entry it was handed back with a why. An entry
// another session wrote between the read and the write can be replaced by one with a why, which the
// next card asks about again and mends. For noteAnnouncement that is an instant; for keepUnapproved
// it is as long as the check of the wording took, up to 30 seconds, since that check runs between.
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

// ---- the card's answer: the session saves the draft, once the change is out ----
// The mod never calls Slack. A card saying the change is out tells the session to save the post as a
// draft in the channel, with no thread, exactly as written. /no-ai-tells is NOT run on it, unlike the
// card's message for whoever asked: this wording is the one Dan approved, and a draft that differs
// from it is not counted (below). A card that says deploying, or could not confirm live, asks for
// nothing and settles nothing: the entry is still owed when a later card finds the change out.

/** The marker line either side of the wording in the card's answer, so its first and last lines are not in doubt. */
export const MARK = '-----'

/** `never` and `unasked` are threads.ts's own sentences, said with every instruction to save a Slack draft. */
export type Said = { never: string; unasked: string }

// The one instruction to save the draft, said by the card that finds the change out and again by the
// turn end's hold, so the two can never ask for different calls.
const saveOf = (a: IsItLiveAnnouncement, said: Said): string =>
  `Save it as a Slack draft for him to send himself, now, without asking Dan first: call slack_send_message_draft with channel_id "${a.channel}", no thread_ts, and message set to exactly the wording between the two ${MARK} lines below, every line and blank line as written. Do not run /no-ai-tells on it and do not change a word: the wording is already approved, and a draft that differs from it is not counted. ${said.unasked} ${said.never} The answer to that call says whether Slack kept the draft, and what to tell Dan.\n${MARK}\n${a.text}\n${MARK}`

/** What the card's answer tells the session of an announcement that can be drafted now. */
export const cardDraftOf = (a: IsItLiveAnnouncement, said: Said): string => `${nameOf(a)} owes an announcement for agents, whose wording Dan approved before it merged. ${saveOf(a, said)}`

/** What the card's answer says while the change is not out yet. */
export const cardWaitsOf = (a: { repo: string; pr: number }): string =>
  `${nameOf(a)} owes an announcement for agents, which is drafted only once its change is live: nothing is drafted now. Once you have confirmed it is live, call this again with deploy "live".`

/** What the card's answer says of an announcement the gate's reader could not tell enough about to draft; `row` is whether its row is pinned in the band. */
export const cardUndraftableOf = (a: IsItLiveAnnouncement, row: boolean): string =>
  `${nameOf(a)} owes an announcement for agents that cannot be drafted from this Mac: ${a.why ?? 'its channel or its wording was not read'}. Nothing is drafted. Tell Dan that, with the reason. ${
    row ? 'It stays listed in the band and in /live until he marks it sent or says it is not being announced.' : 'It stays listed in /live until it is settled.'
  }`

/** What the card's answer says when whether the change owes an announcement could not be told at all. */
export const cardUnreadOf = (a: { repo: string; pr: number }, why: string): string =>
  `Whether ${nameOf(a)} owes an announcement for agents could not be told (${why}). If it was merged as a change to announce, call this card again once that can be read, so its draft is not missed.`

// ---- before any draft: is the wording kept the wording the pull request merged on? ----
// The post is read from the pull request's description, which an ordinary command can edit after
// the merge with no hook judging it. So before a draft is asked for, before one is counted, and
// before Copy hands the wording over, the wording kept is checked against the hash the pull request
// claimed at the merge gate. That is the hooks' one check (hooks/lib/announce-compare.js,
// `claimed`), which reads the record of approvals and never writes it; the dev update's "Draft it
// now" asks the same one. Anything but its word that the wording is approved drafts nothing.

/**
 * How that check is asked: its command line, the wording about to be drafted on standard input.
 * `withinMs` is for a caller cut off sooner than the check's own wait on the record (a press): how
 * long the check may wait, less than the caller's own limit, so the check answers first (L842).
 */
export const claimArgv = (home: string, repo: string, pr: number, withinMs?: number): string[] => [
  'node',
  `${home}/.claude/hooks/lib/announce-compare.js`,
  'claimed',
  '--repo',
  repo,
  '--pr',
  String(pr),
  ...(withinMs === undefined ? [] : ['--within-ms', String(withinMs)]),
]

/**
 * The check's answer: `approved`, `changed` (the pull request claimed other wording at the merge),
 * `unread` (no claim of that pull request's could be read, `why`), or `unchecked`: the check gave
 * no whole answer, which is never taken for approved.
 */
export type Claimed = { state: 'approved' } | { state: 'changed' } | { state: 'unread'; why: string } | { state: 'unchecked'; why: string }
export type Unapproved = Exclude<Claimed, { state: 'approved' }>

/** The check's answer, from what running it printed. */
export const claimedOf = (r: Ran): Claimed => {
  if (r.exitCode !== 0) return { state: 'unchecked', why: r.stderr.trim().split('\n').pop() || `the check exited ${r.exitCode}` }
  if (r.isStdoutTruncated) return { state: 'unchecked', why: 'its answer was cut short' }
  let o: Record<string, unknown> | null
  try {
    o = record(JSON.parse(r.stdout))
  } catch {
    return { state: 'unchecked', why: 'its answer was not JSON' }
  }
  if (o?.state === 'approved') return { state: 'approved' }
  if (o?.state === 'changed' && text(o.why) && o.why.trim()) return { state: 'changed' }
  if (o?.state === 'unread' && text(o.why) && o.why.trim()) return { state: 'unread', why: o.why.trim() }
  return { state: 'unchecked', why: SHAPE }
}

/** Why wording that is not known to be approved is not drafted, as one clause: also kept as the entry's why. */
export const unapprovedOf = (c: Unapproved): string => (c.state === 'changed' ? 'the wording in its pull request was changed after Dan approved it' : `Dan's approval of its wording could not be read (${c.why})`)

/** What the card's answer says of an announcement whose wording is not known to be the approved one; `row` is whether its row is pinned. */
export const cardUnapprovedOf = (a: { repo: string; pr: number }, c: Unapproved, row: boolean): string =>
  `${nameOf(a)} owes an announcement for agents, and it is not drafted: ${unapprovedOf(c)}. Nothing is drafted, and it is still owed. Tell Dan that, and that he must be asked again before any wording is drafted for it. Do not draft what the pull request's description holds now. ${
    row ? 'It stays listed in the band and in /live until it is drafted, he marks it sent or he says it is not being announced.' : 'It stays listed in /live until it is settled.'
  }`

/** What a draft call's answer carries, and what Dan is toasted, when a draft was made where such an announcement is owed. */
export const draftUnapprovedOf = (a: IsItLiveAnnouncement, c: Unapproved): { context: string; toast: string } => ({
  context: `A Slack draft was just made in channel ${a.channel}, and it is not counted as the announcement for agents for ${nameOf(a)}: ${unapprovedOf(c)}. The announcement is still owed. Tell Dan that, that he must be asked again before any wording is drafted for it, and that if the draft now waiting in that channel is this announcement he should not send it as it stands.`,
  toast: `A Slack draft in channel ${a.channel} is not counted as the announcement for agents for ${nameOf(a)}: ${unapprovedOf(c)}. It is still owed.`,
})

/** Copy pressed for wording that is not known to be the approved one: nothing is copied. */
export const notCopiedOf = (a: { repo: string; pr: number }, c: Unapproved): string => `Not copied: the wording kept for ${nameOf(a)} is not known to be the wording you approved (${unapprovedOf(c)}).`

// ---- the draft's own answer: saved only when Slack kept it and it is the approved wording ----
// Measured 2026-11-25 (claude-config#3664): a draft Slack kept is answered with a draft_id, and with
// a draft already waiting in the channel the tool answers "Draft created" with none and keeps
// nothing. Whether an answer is a kept draft, and whether the draft's words are the approved
// wording's, is the hooks' one judgement (hooks/lib/announce-compare.js, `draft`), never worked out
// here: this turns its answer into what the session and Dan are told.

/** How the one judgement of a draft is asked: its command line, {text, message, answer} as JSON on standard input. */
export const judgeArgv = (home: string): string[] => ['node', `${home}/.claude/hooks/lib/announce-compare.js`, 'draft']

/** The judgement of one draft, or why none could be made (`unjudged`), which is never taken for saved. */
export type Judged =
  | { state: 'saved'; draftId: string }
  | { state: 'differs'; why: string }
  | { state: 'not-kept'; why: string }
  | { state: 'error'; why: string }
  | { state: 'unjudged'; why: string }

/** The judgement, from what running its command line printed. Anything but a whole answer is unjudged. */
export const judgedOf = (r: Ran): Judged => {
  if (r.exitCode !== 0) return { state: 'unjudged', why: r.stderr.trim().split('\n').pop() || `the judgement exited ${r.exitCode}` }
  if (r.isStdoutTruncated) return { state: 'unjudged', why: 'its answer was cut short' }
  let o: Record<string, unknown> | null
  try {
    o = record(JSON.parse(r.stdout))
  } catch {
    return { state: 'unjudged', why: 'its answer was not JSON' }
  }
  // Saved is Slack's id for the draft and nothing less.
  if (o?.state === 'saved' && text(o.draftId) && o.draftId) return { state: 'saved', draftId: o.draftId }
  if ((o?.state === 'differs' || o?.state === 'not-kept' || o?.state === 'error') && text(o.why) && o.why.trim()) return { state: o.state, why: o.why.trim() }
  return { state: 'unjudged', why: SHAPE }
}

/**
 * What the draft call's answer carries for the session, and what Dan is toasted, for one judgement
 * of one announcement. `row` is whether its row is pinned in this session's band, so a button is
 * named only where it is there to press.
 */
export const draftOutcomeOf = (a: IsItLiveAnnouncement, j: Judged, never: string, row: boolean): { context: string; toast: string } => {
  const name = nameOf(a)
  const where = `channel ${a.channel}`
  if (j.state === 'saved')
    return {
      context: `The announcement for agents for ${name} is saved as a Slack draft in ${where}, word for word the wording Dan approved (Slack's id for the draft is ${j.draftId}). Tell Dan it is a draft waiting in that channel for him to send, and that nothing was sent.`,
      toast: `Announcement for agents drafted in Slack: ${name}. It waits in your Drafts for you to send.`,
    }
  if (j.state === 'differs')
    return {
      context: `The draft in Slack differs from the approved wording of the announcement for agents for ${name}: ${j.why}. It is not counted as its draft, and the announcement is still owed. Tell Dan exactly that: the draft Slack now holds for ${where} is not the wording he approved, and he can put the approved wording in its place${row && a.text.trim() ? ` (Copy on ${THE_ROW} copies it)` : ''} or delete it so the approved wording can be drafted. Save no other draft there now: Slack keeps one per channel and would keep nothing. ${never}`,
      toast: `The draft in Slack differs from the approved wording of the announcement for agents for ${name}: ${j.why}. It is still owed.`,
    }
  if (j.state === 'not-kept')
    return {
      context: `No draft of the announcement for agents for ${name} was saved: ${j.why}. It is still owed. Tell Dan a draft is already waiting in ${where}, which Slack did not show, so whether it is this announcement is not known: if it is, he can send it${row ? ` and press Mark sent on ${THE_ROW}` : ''}, and if it is something else, this one can be drafted once that one is sent. Do not tell him to delete it, and never save the announcement to another channel instead. ${never}`,
      toast: `No Slack draft was saved for the announcement for agents for ${name}: a draft is already waiting in that channel. It is still owed.`,
    }
  if (j.state === 'error')
    return {
      context: `No draft of the announcement for agents for ${name} was saved: ${j.why}. It is still owed. Tell Dan that, with the reason. Never save it to another channel instead. ${never}`,
      toast: `No Slack draft was saved for the announcement for agents for ${name}: ${j.why}. It is still owed.`,
    }
  return {
    context: `Whether the draft just made in ${where} is the announcement for agents for ${name} could not be checked (${j.why}), so it is still owed. Tell Dan the draft there could not be compared with the wording he approved.`,
    toast: `A Slack draft in ${where} could not be checked against the approved announcement for agents for ${name} (${j.why}). It is still owed.`,
  }
}

// ---- said in every session until it is settled ----
// While an announcement is owed, /live lists it, every session started in that project says it in
// one line, and the turn end of the session whose card found it live is refused once, as the thread
// reply's hold is. One merged that no card has found live yet is listed and said too, as waiting,
// since the session that merged it may be gone.

/** Where one owed announcement stands: whether a card has said its change is live. */
export type Standing = { a: IsItLiveAnnouncement; out: boolean }

/** Where an owed announcement stands, as one clause after its pull request's name. */
export const standingOf = (s: Standing): string =>
  !s.out
    ? 'merged, and no card has said it is live yet, so nothing is drafted'
    : draftable(s.a)
      ? `not yet a Slack draft in channel ${s.a.channel}`
      : `cannot be drafted from this Mac (${s.a.why ?? 'its channel or its wording was not read'})`

const and = (xs: string[]): string => (xs.length <= 1 ? (xs[0] ?? '') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`)

/** /live: the announcements still owed, each with where it stands, or nothing when none is. */
export const listOf = (all: Standing[]): string => (all.length ? ['', '', 'Announcements for agents still owed:', ...all.map(s => `- ${nameOf(s.a)}: ${standingOf(s)}.`)].join('\n') : '')

/**
 * The one line a session start says of the announcements still owed in its project, or undefined
 * when none is. `rows` is whether every one that is live was pinned in the band just now, so the
 * line names a row and its buttons only where they are there.
 */
export const startLineOf = (all: Standing[], rows: boolean): string | undefined => {
  if (!all.length) return undefined
  const [one] = all
  if (all.length === 1 && one) {
    const where = !one.out ? 'is merged, and no card has said it is live yet' : draftable(one.a) ? 'is live and not yet a Slack draft' : `is live and ${standingOf(one)}`
    return `An announcement for agents is still owed in this project: ${nameOf(one.a)} ${where}. /live lists it${one.out && rows ? `, and its row in the band has ${buttonsOf(one.a)}` : ''}.`
  }
  const repos = [...new Set(all.map(s => s.a.repo))]
  const names = repos.length === 1 ? `${repos[0]} pull requests ${and(all.map(s => String(s.a.pr)))}` : and(all.map(s => nameOf(s.a)))
  return `${all.length} announcements for agents are still owed in this project: ${names}. /live says where each stands${all.some(s => s.out) && rows ? ', and each one that is live has its row in the band' : ''}.`
}

/** What the session's first prompt carries beside that line: how one is drafted, and that Dan is told. */
export const firstPromptOf = (line: string): string =>
  `${line} Tell Dan this in one line. If he asks for one to be drafted, call the is it live card for that pull request with deploy "live", once you have confirmed its change is live: the card's answer gives the channel and the exact wording.`

/** The turn end's refusal for the announcements this session's card found live and that are still not drafted. */
export const holdOf = (due: IsItLiveAnnouncement[], said: Said): string => due.map(a => `The announcement for agents for ${nameOf(a)} is not yet a Slack draft. ${saveOf(a, said)}`).join('\n\n')

/** What Dan is told, once, when a turn ends with them still not drafted; `rows` is whether each one's row is pinned in the band. */
export const announceLetGoOf = (due: IsItLiveAnnouncement[], rows: boolean): string =>
  `Is it live let the turn end with the announcement for agents for ${and(due.map(nameOf))} not yet a Slack draft. It is still owed, and ${rows ? 'stays in the band and in /live' : '/live lists it'}.`

// ---- the row in the band: how Dan settles one that needs no draft from here ----
// While an announcement is owed and a card has said its change is live, a row is pinned in the band
// above the prompt, with Copy, Mark sent and Not announcing. A press reaches this mod only as
// mod-kit's modkit.press, raised by a click on the button or by /press typed at the prompt: no tool
// a session can call marks one sent or not being announced.
//
// #3847: Not announcing settles only on a second press. One press settled it for every session and
// for good, three buttons along a row that is on screen for seconds, and Dan ended an announcement
// he had approved by a slip (2026-11-27). The first press now arms the button: its label becomes
// "Confirm: not announcing #<pull request>" and nothing is recorded. A second press while it is
// armed settles it. Mark sent keeps its one press, since recording that he posted it loses nothing.

/**
 * How long Not announcing stays armed after its first press, in the session's clock. Ten seconds:
 * long enough to read the sentence the first press is answered with, see the label change and press
 * again, with room for a busy Mac to redraw the band; short enough that a row he pressed by a slip
 * and looked away from is back to Not announcing before he next reaches for it. The sentence itself
 * stays up for the same time, so it is on screen exactly as long as it is true.
 */
export const ARMED_MS = 10_000

/** The label Not announcing carries while it is armed, naming the pull request it would settle. */
export const confirmLabelOf = (a: { pr: number }): string => `Confirm: not announcing #${a.pr}`

/** The band row's id for an announcement, from its id alone, so the session that did not pin it can still name it. */
export const rowIdOf = (id: string): string => `announce-${id.replace(/[^a-z0-9]+/g, '-')}`

type Part = { text: string; color?: string; bold?: boolean } | { button: string; label: string }
export type AnnounceRow = { mod: string; id: string; slot: 'message'; lines: Part[][] }
export const BUTTONS = ['copy', 'sent', 'none'] as const
export type Pressed = (typeof BUTTONS)[number]

// A button is named announce-<verb>-<the row's id past its own "announce-">, which the press hook
// for the message row's Copy and Mark sent (register.ts, `copy-` and `sent-`) never matches.
const buttonOf = (verb: Pressed, row: string): string => `announce-${verb}-${row.slice('announce-'.length)}`

/**
 * The row pinned in the band while an announcement is owed and its change is live: its heading in
 * the violet of the message row beside it, where it stands, then the three buttons. The wording
 * itself is not drawn, since Dan approved it already and a whole post would fill the band in every
 * session: Copy copies it, and is left out where no wording was read. `armed` is whether Not
 * announcing has had its first press (#3847): the same button, in the same place, under the label a
 * second press confirms.
 */
export const announceRow = (mod: string, a: IsItLiveAnnouncement, armed = false): AnnounceRow => {
  const id = rowIdOf(idOf(a.repo, a.pr))
  return {
    mod,
    id,
    slot: 'message',
    lines: [
      [{ text: 'Announcement for agents', color: 'magenta', bold: true }],
      [{ text: `${nameOf(a)}: ${standingOf({ a, out: true })}.` }],
      [...(a.text.trim() ? [{ button: buttonOf('copy', id), label: 'Copy' }] : []), { button: buttonOf('sent', id), label: 'Mark sent' }, { button: buttonOf('none', id), label: armed ? confirmLabelOf(a) : 'Not announcing' }],
    ],
  }
}

/** The button a press names and its row's id, or undefined for a press that is not one of these rows'. */
export const pressedOf = (mod: string, element: string): { verb: Pressed; row: string } | undefined => {
  const m = new RegExp(`^${mod}:announce-(${BUTTONS.join('|')})-(.+)$`).exec(element)
  return m ? { verb: m[1] as Pressed, row: `announce-${m[2]}` } : undefined
}

/** The buttons an announcement's row has, as the session start line names them. */
const buttonsOf = (a: IsItLiveAnnouncement): string => (a.text.trim() ? 'Copy, Mark sent and Not announcing' : 'Mark sent and Not announcing')

const THE_ROW = 'the "Announcement for agents" row in the band'

// Each sentence a press is answered with takes `stuck`: why the row could not be taken down, absent
// when it was, so none says a row came down that is still there.
const stuckOf = (stuck: string): string => `Its row could not be taken down (${stuck}).`

/** What Dan is told once a press settled an announcement. */
export const settledOf = (a: { repo: string; pr: number }, how: 'sent' | 'not-announcing', stuck?: string): string =>
  `${how === 'sent' ? `Marked sent: the announcement for agents for ${nameOf(a)}. It is no longer asked for.` : `Not announcing: the announcement for agents for ${nameOf(a)} is no longer asked for.`}${stuck === undefined ? '' : ` ${stuckOf(stuck)}`}`

/**
 * What Dan is told once the first press of Not announcing armed it (#3847): that nothing was
 * recorded, what the second press does, and what happens if there is none.
 */
export const armedOf = (a: { repo: string; pr: number }): string =>
  `Nothing is settled: the announcement for agents for ${nameOf(a)} is still owed. A second press, on ${confirmLabelOf(a)} within ${ARMED_MS / 1000} seconds, ends it for every session and cannot be undone. Left alone, the button goes back to Not announcing.`

/** A first press of Not announcing that could not arm it: the label a second press confirms is not on screen, so none counts. */
export const notArmedOf = (a: { repo: string; pr: number }, why: string): string =>
  `Nothing is settled: the announcement for agents for ${nameOf(a)} is still owed. Its button could not be changed to ${confirmLabelOf(a)} (${why}), so it is not armed and the next press starts over.`

/** A press on a row whose announcement was settled since it was pinned, by a draft or in another session. */
export const alreadySettledOf = (stuck?: string): string => `That announcement for agents is already settled${stuck === undefined ? ', so its row was taken down.' : `. ${stuckOf(stuck)}`}`

/** A press on a row no entry is kept for. */
export const notKeptOf = (stuck?: string): string =>
  stuck === undefined ? 'No announcement for agents is kept for that row, so it was taken down and nothing was recorded.' : `No announcement for agents is kept for that row, so nothing was recorded. ${stuckOf(stuck)}`
/** Copy pressed for an announcement whose wording was never read: its row draws no Copy, and a typed press is answered with this. */
export const NO_WORDING = 'Not copied: no wording was read for that announcement for agents.'

/** A press this mod could not look up at all. */
export const pressUnreadOf = (why: string): string => `Is it live could not read which announcement for agents that button is for (${why}), so nothing was recorded.`

/** A press whose record could not be written: `owed` is what reading it back gave, undefined when that could not be read either. */
export const unsettledOf = (a: { repo: string; pr: number }, why: string, owed: boolean | undefined): string =>
  `Is it live could not record that for the announcement for agents for ${nameOf(a)} (${why}). ${owed ? 'It is still listed in /live, and its row stays in the band.' : 'Whether it is still owed could not be read back: /live says.'}`

/** A row the band would not take: said where it happened. /live tries the pin again, so everywhere but in /live the sentence says so. */
export const unpinnedOf = (a: { repo: string; pr: number }, why: string, inLive = false): string =>
  `The announcement for agents for ${nameOf(a)} could not be pinned in the band (${why})${inLive ? '.' : '; /live lists it and tries to pin it again.'}`

/** What Dan is told when whether a merged change owes an announcement could not be told at all. */
export const unreadOf = (a: { repo: string; pr: number }, why: string): string =>
  `Is it live could not tell whether ${nameOf(a)} owes an announcement for agents (${why}). It is asked again when its card is made.`
