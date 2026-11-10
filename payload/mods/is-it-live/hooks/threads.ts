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
// already Dan's to send, change or delete. Pure: drafts.ts reads the prompt, the tool calls and the
// turn end (register.ts's Stop hook calls its draftHold), and keeps what this decides.

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
type Pasted = SlackThread & { mid?: true; prs?: string[]; card?: { pr: string; name: string; message: string } }

// The opening of a hold: a thread the session started from is owed a reply after every merge, one
// pasted once it was under way only after a merge for it, which is named so the reply covers only it.
const owedOf = (t: Pasted) =>
  t.mid
    ? `A pull request for ${nameOfThread(t)}, pasted in this session, has merged since its last draft reply (${(t.prs ?? []).join(', ')}). Before ending the turn: write a short reply in Dan's voice saying what merged for it and is live, and nothing about other merges`
    : `This session started from ${nameOfThread(t)}, and a pull request has merged since its last draft reply. Before ending the turn: write a short reply in Dan's voice saying what merged and is live`

// Said after the save, whichever reply it was.
const TOLD = 'Then tell Dan it is a draft waiting in that thread and that nothing was sent.'

/** Why a turn end is held, naming every thread owed a draft reply. A thread a card asked a draft of
 * its message for is owed that message, the one Dan was shown, never a second reply (#2630). */
export const draftHoldOf = (owed: Pasted[]): string =>
  owed
    .map(t =>
      t.card
        ? `The message for ${t.card.name} on the is it live card for ${t.card.pr} is owed as a Slack draft reply in ${nameOfThread(t)}, and no draft of it is saved since. Before ending the turn, save it now, without asking Dan first: call ${saveWith(t)}, with message set to exactly "${t.card.message}", word for word. ${UNASKED} ${TOLD} ${NEVER} ${EXISTS}`
        : `${owedOf(t)}, run /no-ai-tells on it, show it to Dan in your reply, and in that same step, without asking Dan first, save that exact text with ${saveWith(t)}. ${UNASKED} ${TOLD} ${NEVER} ${EXISTS}`,
    )
    .join('\n\n')

/** What is said when a turn ends while a draft is still owed, the turn end having been held once in this chain. */
export const draftLetGoOf = (owed: SlackThread[]): string => `No Slack draft reply saved to ${owed.map(nameOfThread).join(', ')}: the turn ended without one.`

/** The step a thread's draft is owed from: the latest merge for it when pasted mid session (#2578), else the latest merge. */
export const draftOwedFrom = (t: IsItLiveThread, landed: number | undefined): number | undefined => (t.mid ? t.related : landed)

/** The threads owed a draft: those whose last draft or skip came before the latest merge they are owed for. */
export const owedThreads = (threads: IsItLiveThread[], landed: number | undefined): IsItLiveThread[] =>
  threads.filter(t => {
    const from = draftOwedFrom(t, landed)
    return from !== undefined && (t.settled ?? -Infinity) < from
  })
