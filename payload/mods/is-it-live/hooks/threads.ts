import type { IsItLiveThread } from '../types/index.d.ts'

// A draft reply to the Slack thread a session started from, after its last merge (claude-config#2436).
// Dan, 2026-11-07: "if anything you merged (including future merges) came from a slack thread, make
// sure to save a response as a draft to that thread", and "slack thread start = draft response saved.
// every time". Seen that day: a session began from Dan's thread with Geoff's answers, merged seven
// pull requests built from them, and saved no reply until Dan asked. Answering the issue's open
// question the same day, Dan chose one draft after the session's LAST merge from the thread, not one
// after each. A turn end cannot know a merge is the last, so drafts.ts holds it when a merge has
// landed since the thread's last draft and no merge of the session is still in flight.
//
// The mod never calls a Slack tool and never sends anything (payload/CLAUDE.md, "Slack: drafts only"):
// it tells the session to write the reply, run /no-ai-tells, show Dan, and save it with
// slack_send_message_draft in that same step. #2630, Dan, 2026-11-10: "Anytime you give me a message
// for someone, you should also just save it as a slack draft in the relevant thread." So there is no
// picker before the draft (there was one, Save as a draft or Skip this time, until then): a draft is
// already Dan's to send, change or delete. #2849, Dan, 2026-11-12: given more than one thread, a
// merge owes its reply in the one pasted most recently before its work began ("follow the most
// recent link"), so a draft in an earlier thread does not settle it (assignLandings). Pure: drafts.ts
// reads the prompt, the tool calls and the turn end (register.ts's Stop hook calls its draftHold),
// and keeps what this decides.

export type SlackThread = { channel: string; ts: string; link?: string }

// A message link: the workspace's slack.com host, the channel, and p followed by the message time
// without its point. A link to a reply in a thread carries the parent's time as thread_ts.
const LINK = /https:\/\/[a-z0-9-]+\.slack\.com\/archives\/([A-Z0-9]+)\/p(\d{10})(\d{6})(\?[^\s<>|)"']*)?/g

/** The Slack threads a text links to, once each: the channel and the thread's parent message time. */
export const threadsIn = (text: string): SlackThread[] => {
  const out: SlackThread[] = []
  for (const m of text.matchAll(LINK)) {
    const parent = /[?&]thread_ts=(\d{10}\.\d{6})/.exec(m[4] ?? '')?.[1]
    const t = { channel: m[1] as string, ts: parent ?? `${m[2]}.${m[3]}`, link: m[0] }
    if (!out.some(o => threadKey(o) === threadKey(t))) out.push(t)
  }
  return out
}

export const threadKey = (t: Pick<SlackThread, 'channel' | 'ts'>) => `${t.channel}:${t.ts}`

/** #2578: whether any of these texts (a pull request's, an issue's) links the thread. */
export const linksThread = (texts: string[], t: Pick<SlackThread, 'channel' | 'ts'>): boolean => texts.some(x => threadsIn(x).some(o => threadKey(o) === threadKey(t)))

/**
 * Whether a tool is the Slack tool `name` under any server: Claude Code calls it
 * mcp__<server>__<name>, and the server differs by connector (hooks/lib/slack-write-tools.txt).
 */
export const isSlackTool = (tool: string, name: string): boolean => tool.startsWith('mcp__') && tool.endsWith(`__${name}`) && tool.length > `mcp____${name}`.length

// The errors Slack's draft tool names (its own description lists them), and a JSON answer saying it
// did not work. One that says so in a result not marked as an error is no saved draft either.
const DRAFT_ERROR = /"ok"\s*:\s*false|\b(?:attached_draft_exists|channel_not_found|not_in_channel|failed_to_create_draft)\b/

/** Whether a draft call's answer says Slack saved it: not refused, not an error, and naming none of Slack's errors. */
export const draftSaved = (o: { text?: unknown; result?: unknown; isError?: unknown; deny?: unknown }): boolean => {
  if (o.deny !== undefined || o.isError === true) return false
  const text = typeof o.text === 'string' ? o.text : typeof o.result === 'string' ? o.result : JSON.stringify(o.result ?? '')
  return !DRAFT_ERROR.test(text)
}

/** How a thread is named to Dan and the session: the link he pasted, else its channel and time. */
export const nameOfThread = (t: SlackThread) => t.link ?? `the Slack thread in channel ${t.channel} at ${t.ts}`

const saveWith = (t: SlackThread) => `slack_send_message_draft with channel_id "${t.channel}" and thread_ts "${t.ts}"`
/** Said with every instruction to save a Slack draft, here and on the card (card.ts, #2435). */
export const NEVER = 'Never call slack_send_message or slack_schedule_message.'
const EXISTS = "If Slack answers attached_draft_exists, an earlier draft for that channel is already in Dan's Drafts: Slack keeps one per channel, so tell him to edit or delete it, then save this one again."

/** #2630: said with every instruction to save a message for someone as a Slack draft, here and on the card (card.ts). */
export const UNASKED = 'Never ask him with AskUserQuestion whether to save it: a draft is his to send, change or delete, so it is saved as soon as it is shown.'

/**
 * A thread as the hold names it: recorded mid session (#2578) with the merges for it since its last
 * draft, or the one the session started from; and the message a card asked a draft of for it, still
 * unsaved (#2630).
 */
type Pasted = SlackThread & { mid?: true; prs?: string[]; related?: number; settled?: number; card?: { pr: string; name: string; message: string } }

// The opening of a hold: a thread the session started from is owed a reply after its merges, one
// pasted once it was under way only after a merge for it, which is named so the reply covers only it:
// one whose pull request links it (#2578), or one whose work began after it was the latest link (#2849).
const owedOf = (t: Pasted) =>
  !t.mid
    ? `This session started from ${nameOfThread(t)}, and a pull request has merged since its last draft reply. Before ending the turn: write a short reply in Dan's voice saying what merged and is live`
    : `${byLink(t) ? `${nameOfThread(t)} is the latest Slack thread pasted in this session before work began on a pull request that has merged since its last draft reply` : `A pull request for ${nameOfThread(t)}, pasted in this session, has merged since its last draft reply`} (${(t.prs ?? []).join(', ')}). Before ending the turn: write a short reply in Dan's voice saying what merged for it and is live, and nothing about other merges`

// Said after the save, whichever reply it was.
const TOLD = 'Then tell Dan it is a draft waiting in that thread and that nothing was sent.'

// #2653: said with a reply owed by the most recent link (#2849), the one no pull request asked for:
// how the session says, once, that its merges have nothing to do with the thread. Since #2849 that
// clears the merges already landed too, since that is when a session learns a merge is unrelated.
const unrelatedOf = (t: SlackThread, tool: string) =>
  `If the merges this reply is owed for, and this session's later ones, have nothing to do with ${nameOfThread(t)}, say so once by calling ${tool} (load it with ToolSearch, query "select:${tool}"), and no reply is then asked for them.`

/** Why a turn end is held, naming every thread owed a draft reply. A thread a card asked a draft of
 * its message for is owed that message, the one Dan was shown, never a second reply (#2630).
 * `unrelatedTool` is the tool a session calls to say its later merges are unrelated (#2653). */
export const draftHoldOf = (owed: Pasted[], unrelatedTool: string): string =>
  owed
    .map(t =>
      t.card
        ? `The message for ${t.card.name} on the is it live card for ${t.card.pr} is owed as a Slack draft reply in ${nameOfThread(t)}, and no draft of it is saved since. Before ending the turn, save it now, without asking Dan first: call ${saveWith(t)}, with message set to exactly "${t.card.message}", word for word. ${UNASKED} ${TOLD} ${NEVER} ${EXISTS}`
        : `${owedOf(t)}, run /no-ai-tells on it, show it to Dan in your reply, and in that same step, without asking Dan first, save that exact text with ${saveWith(t)}. ${UNASKED} ${TOLD} ${NEVER} ${EXISTS}${byLink(t) ? ` ${unrelatedOf(t, unrelatedTool)}` : ''}`,
    )
    .join('\n\n')

/** What is said when a turn ends while a draft is still owed, the turn end having been held once in this chain. */
export const draftLetGoOf = (owed: SlackThread[]): string => `No Slack draft reply saved to ${owed.map(nameOfThread).join(', ')}: the turn ended without one.`

/**
 * #2653: the session said its merges are unrelated to the threads it was given. Kept in session
 * state, so a new session from the same thread is asked again. `landed` is no longer written or read
 * (#2849): what was said now covers the merges already landed as well as later ones.
 */
export type Unrelated = { landed?: number }

/**
 * #2849: a merge as it lands: its name as the hold names it, the keys of the recorded threads its
 * pull request or an issue it closes links, and when GitHub says the pull request opened (ms since
 * the epoch), where that was read.
 */
export type Landing = { pr: string; links?: string[]; opened?: number }

// #2849: the threads a merge owes the session's reply by the most recent link, Dan's choice on
// 2026-11-12: the thread pasted most recently before the work on it began. The mod cannot see work
// begin, so it reads the time the pull request opened, after which no link pasted is the one the
// work came from (a merge in flight while Dan pastes the next alert stays with its own thread). Where
// GitHub gave no such time, every thread recorded by the time the merge landed counts, so the latest
// is chosen. A pull request opened before any link was pasted (one made earlier and merged in this
// session) owes the threads the session started from, as it did before. Threads recorded in one
// prompt share a step, so links pasted together are owed together.
const mostRecent = (ts: IsItLiveThread[], opened: number | undefined): IsItLiveThread[] => {
  const before = opened === undefined ? ts : ts.filter(t => t.at <= opened)
  const pool = before.length ? before : ts.filter(t => !t.mid)
  const top = Math.max(...pool.map(t => t.step ?? 0))
  return pool.filter(t => (t.step ?? 0) === top)
}

const owing = (t: IsItLiveThread, field: 'related' | 'defaulted', n: number, pr: string): IsItLiveThread => ({ ...t, [field]: Math.max(t[field] ?? 0, n), prs: [...new Set([...(t.prs ?? []), pr])] })

/**
 * #2849: the threads after merges landed at step `n`. A merge whose pull request links threads
 * recorded mid session owes each of them (#2578), and one linking threads the session started from
 * owes those; one linking none, in a session started from a thread, owes the most recent thread.
 * With no thread to start from and none linked, a merge owes no reply, as before.
 */
export const assignLandings = (ts: IsItLiveThread[], landings: Landing[], n: number): IsItLiveThread[] => {
  let out = ts
  for (const l of landings) {
    const linked = out.filter(t => (l.links ?? []).includes(threadKey(t)))
    const defaults = linked.length ? linked.filter(t => !t.mid) : out.some(t => !t.mid) ? mostRecent(out, l.opened) : []
    const keys = (xs: IsItLiveThread[]) => new Set(xs.map(threadKey))
    const mids = keys(linked.filter(t => t.mid))
    const owed = keys(defaults)
    out = out.map(t => (mids.has(threadKey(t)) ? owing(t, 'related', n, l.pr) : owed.has(threadKey(t)) ? owing(t, 'defaulted', n, l.pr) : t))
  }
  return out
}

const latest = (...xs: (number | undefined)[]): number | undefined => {
  const known = xs.filter((x): x is number => x !== undefined)
  return known.length ? Math.max(...known) : undefined
}

/**
 * The step a thread's draft is owed from: the latest merge whose pull request links it when pasted
 * mid session (#2578), and the latest merge owing it the session's reply (#2849) until the session
 * says its merges are unrelated (#2653). That reply includes one a pull request's link to a thread
 * the session started from asks for, which saying so cleared before #2849 too, so it still does.
 * A card asking a draft of its message in a thread the session
 * started from (#2630) owes it from the latest merge whatever was said, as a card for a thread
 * pasted mid session does through `related`.
 */
export const draftOwedFrom = (t: IsItLiveThread, landed: number | undefined, unrelated?: Unrelated): number | undefined =>
  latest(t.related, t.card !== undefined && !t.mid ? landed : undefined, unrelated === undefined ? t.defaulted : undefined)

/** The threads owed a draft: those whose last draft came before the latest merge they are owed for. */
export const owedThreads = (threads: IsItLiveThread[], landed: number | undefined, unrelated?: Unrelated): IsItLiveThread[] =>
  threads.filter(t => {
    const from = draftOwedFrom(t, landed, unrelated)
    return from !== undefined && (t.settled ?? -Infinity) < from
  })

/** #2849: whether a thread owed a draft is owed only the session's reply by the most recent link, which the unrelated_merges tool clears. */
const byLink = (t: Pasted) => t.card === undefined && (t.related ?? -Infinity) <= (t.settled ?? -Infinity)
