// Is it live (claude-config#617): the card's state, its words, the message row and the /live list.
// Pure, so each rule is tested on its own. Looks settled with Dan on 2026-10-04 (docs/mods-design.md,
// Is it live); the spec agreed 2026-10-03.

import { NEVER } from './threads.ts'

export const MOD = 'is-it-live'

/** How Claude found the deploy: proved live, still running, failed, unreachable, or no deploy step. */
export const DEPLOYS = ['live', 'deploying', 'failed', 'unreachable', 'none'] as const
export type Deploy = (typeof DEPLOYS)[number]
export type State = 'live' | 'deploying' | 'unconfirmed' | 'no-deploy'

/** Who asked, when it was not Dan: an issue they reported, a pasted Slack thread, or a person Dan named. */
export const VIAS = ['issue', 'slack', 'named'] as const
export type Requester = { name: string; via: (typeof VIAS)[number]; issue?: number }

/**
 * Where the message's Slack draft goes (#2435), named as Slack's own draft tool names them: the
 * thread a Slack requester asked in (channel_id and thread_ts), or the person's user id for a DM.
 */
export type SlackTo = { channel_id?: string; thread_ts?: string; user_id?: string }

/** What Claude hands the card tool. */
export type CardInput = {
  repo: string
  pr: number
  deploy: Deploy
  /** How live was confirmed, or why it could not be. */
  checked?: string
  changed: string
  see: { link: string; clicks: string[] }
  requester?: Requester
  message?: string
  slack?: SlackTo
}

/** A card as kept: the input, the PR's own title and link as GitHub gave them, and when. */
export type Card = { repo: string; pr: number; title: string; url: string; state: State; at: number; requester?: Requester; message?: string; sentAt?: number; slack?: SlackTo; draftAsked?: string }

// A Record over the type, so a deploy added without a state fails to type check (L113).
const STATE: Record<Deploy, State> = { live: 'live', deploying: 'deploying', failed: 'unconfirmed', unreachable: 'unconfirmed', none: 'no-deploy' }
export const stateOf = (d: Deploy): State => STATE[d]

// Whether the change has reached the people who asked for it, so the message telling them it is
// live can be shown (#1335): live, or merged in a project with no deploy step, where merging is
// going live (Dan, 2026-10-19). Deploying and could not confirm live hold the message (Dan,
// 2026-10-19). A Record over the type, so a state added without a decision fails to type check.
const OUT: Record<State, boolean> = { live: true, 'no-deploy': true, deploying: false, unconfirmed: false }
export const isOut = (s: State): boolean => OUT[s]

// The state leads the title (design round): "Live:" green, "Merged, deploying:" grey, "Could not
// confirm live:" amber. The no deploy step title is the builder's, not yet settled.
const LEAD: Record<State, string> = {
  live: 'Live',
  deploying: 'Merged, deploying',
  unconfirmed: 'Could not confirm live',
  'no-deploy': 'Merged, no deploy step recorded',
}
export const titleOf = (s: State, title: string): string => `${LEAD[s]}: ${title}`

// The lead's colour: green when live, amber when live could not be confirmed (it waits on Dan to
// look), grey while it deploys. The no deploy step colour is the builder's, grey, not yet settled.
// A Record over the type, so a state added without a colour fails to type check.
const LEAD_COLOR: Record<State, string> = { live: 'success', deploying: 'gray', unconfirmed: 'warning', 'no-deploy': 'gray' }

const has = (o: Record<string, unknown>, k: string) => Object.prototype.hasOwnProperty.call(o, k)
const sentences = (s: string) => s.split(/(?<=[.!?])\s+/).filter(x => x.trim()).length
// Dan's voice has no dashes: an em or en dash, a hyphen standing alone between words, or two hyphens.
const DASH = new RegExp(`[${String.fromCharCode(0x2014)}${String.fromCharCode(0x2013)}]|\\s-\\s|--`)

/**
 * Every reason the card cannot be made from this input, each field named, so one refusal lists all
 * of them (#2374): a card took five refused calls in a row when each call named only the first.
 */
export const problemsWith = (i: CardInput): string[] => {
  const out: string[] = []
  if (typeof i.repo !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(i.repo)) out.push('repo must be owner/name, as GitHub spells it.')
  if (!Number.isInteger(i.pr) || i.pr <= 0) out.push('pr must be the pull request number.')
  const deployOk = DEPLOYS.includes(i.deploy)
  if (!deployOk) out.push(`deploy must be one of ${DEPLOYS.join(', ')}.`)
  else if (i.deploy !== 'none' && i.deploy !== 'deploying' && !(typeof i.checked === 'string' && i.checked.trim()))
    out.push(i.deploy === 'live' ? 'live needs checked: how it was checked that the change is live.' : 'checked must say why live could not be confirmed.')
  const n = typeof i.changed === 'string' ? sentences(i.changed) : 0
  if (n < 2 || n > 3) out.push(`changed must say what changed in 2 to 3 sentences (it has ${n}).`)
  if (!i.see || typeof i.see.link !== 'string' || !/^https?:\/\//.test(i.see.link)) out.push('see.link must be the direct link to where the change shows.')
  if (!i.see || !Array.isArray(i.see.clicks) || !i.see.clicks.every(c => typeof c === 'string' && c.trim())) out.push('see.clicks must be the exact clicks, one per entry.')
  const r = i.requester
  if (r !== undefined) {
    const named = Boolean(r) && typeof r.name === 'string' && Boolean(r.name.trim())
    if (!named) out.push('requester.name must say who asked.')
    const viaOk = Boolean(r) && VIAS.includes(r.via)
    if (!viaOk) out.push(`requester.via must be one of ${VIAS.join(', ')}.`)
    if (named && /^dan$/i.test(r.name.trim())) out.push('No message when Dan asked: leave requester out.')
    if (viaOk && r.via === 'issue' && !(Number.isInteger(r.issue) && (r.issue as number) > 0)) out.push('requester.issue must be the issue number when they asked in an issue.')
    // The message tells them it is live, so only a call saying the change is out owes it; an
    // earlier call may pass it, and it is held until then (#1335).
    const given = typeof i.message === 'string' && i.message.trim()
    if (named && deployOk && !given && isOut(stateOf(i.deploy))) out.push(`A message for ${r.name} is owed, in Dan's voice.`)
    if (given && DASH.test(i.message as string)) out.push("The message must have no dashes (Dan's voice): use a comma, colon or a new sentence.")
  } else if (has(i as unknown as Record<string, unknown>, 'message') && i.message) {
    out.push('A message is only for someone other than Dan who asked: say who asked in requester, or leave the message out.')
  }
  // Where the message's Slack draft goes (#2435): only beside someone who asked, and only in the
  // shapes Slack's draft tool takes, so a draft is never aimed at a guess.
  const s = i.slack
  if (s !== undefined && s !== null) {
    if (r === undefined) out.push('slack is only for the person a message is for: say who asked in requester, or leave slack out.')
    if (s.channel_id !== undefined && !(typeof s.channel_id === 'string' && /^[A-Z][A-Z0-9]{2,}$/.test(s.channel_id)))
      out.push('slack.channel_id must be the Slack channel id from the thread link (C0123ABCD), never its name.')
    if (s.thread_ts !== undefined && !(typeof s.thread_ts === 'string' && /^\d{10}\.\d{6}$/.test(s.thread_ts)))
      out.push("slack.thread_ts must be the thread's parent message time (1730900000.123456), from the link.")
    if (s.thread_ts !== undefined && s.channel_id === undefined) out.push('slack.thread_ts needs slack.channel_id, the channel the thread is in.')
    if (s.user_id !== undefined && !(typeof s.user_id === 'string' && /^[UW][A-Z0-9]{2,}$/.test(s.user_id)))
      out.push('slack.user_id must be the Slack user id (U0123ABCD), as slack_search_users gives it.')
  }
  return out
}

/** Why the card cannot be made from this input, all problems in one sentence list, or undefined when it can. */
export const reasonToRefuse = (i: CardInput): string | undefined => {
  const all = problemsWith(i)
  return all.length ? all.join(' ') : undefined
}

type Run = { text: string; color?: string; bold?: boolean }
type Shown = CardInput & { state: State; title: string; url: string }

/**
 * Whether a card's message goes in the band now (#1335): it tells whoever asked that the change is
 * live, so it is held, never shown with Copy and Mark sent, until a card for that PR says the
 * change is out (isOut); deploying and could not confirm live hold it, and a sent one is done.
 */
export const pinnable = (c: { state: State; requester?: Requester; message?: string; sentAt?: number }): boolean =>
  isOut(c.state) && Boolean(c.requester && c.message) && c.sentAt === undefined

/**
 * The card as mod-kit's boxed card draws it (#663): the state leading the title in its colour, then
 * why live could not be confirmed, what changed, the link and the clicks. Plain data for $.modkit.card.
 */
export const cardOf = (c: Shown): { title: Run[]; lines: Run[][] } => ({
  title: [{ text: `${LEAD[c.state]}:`, color: LEAD_COLOR[c.state], bold: true }, { text: ` ${c.title}` }],
  lines: [
    ...(c.state === 'unconfirmed' && c.checked ? [[{ text: c.checked.trim() }]] : []),
    [{ text: c.changed.trim() }],
    [{ text: 'See it: ' }, { text: c.see.link }],
    ...c.see.clicks.map((k, n) => [{ text: `${n + 1}. ${k.trim()}` }]),
    ...(!isOut(c.state) && c.requester ? [[{ text: `Message for ${c.requester.name} waits until this is live.` }]] : []),
  ],
})

/** The card as text, from the same lines: what the model reads, and the row after a reload. */
export const cardText = (c: Shown): string => {
  const { title, lines } = cardOf(c)
  return [title, ...lines].map(l => l.map(r => r.text).join('')).join('\n')
}

/** A key a band button id can hold. */
export const buttonId = (repo: string, pr: number): string => `${repo.replace(/[^A-Za-z0-9]+/g, '-')}-${pr}`

type Part = { text: string; color?: string; bold?: boolean } | { button: string; label: string }
export type MessageRow = { mod: string; id: string; slot: 'message'; lines: Part[][] }

/**
 * The message for whoever asked, pinned in the band until Mark sent (design round): its heading
 * "Message for Kris" in violet (not amber beside the steps card, not blue, which reads as a link),
 * the message, then Copy and Mark sent.
 */
export const messageRow = (c: { repo: string; pr: number; requester: Requester; message: string }): MessageRow => {
  const id = buttonId(c.repo, c.pr)
  return {
    mod: MOD,
    id,
    slot: 'message',
    lines: [
      [{ text: `Message for ${c.requester.name}`, color: 'magenta', bold: true }],
      ...c.message.split('\n').map(l => [{ text: l }]),
      [
        { button: `copy-${id}`, label: 'Copy' },
        { button: `sent-${id}`, label: 'Mark sent' },
      ],
    ],
  }
}

// ---- #2435: the message is also saved as a Slack draft, never sent ----
// Dan, 2026-11-07: "anytime you have a message for someone you should save it in a draft in slack
// as well". A Slack requester gets a draft reply in the thread they asked in; a person named or an
// issue reporter gets a draft DM (the issue's open question, answered from those words). The mod
// never calls Slack (payload/CLAUDE.md, "Slack: drafts only"): the card's answer tells the session
// to save the draft, once the card says the change is out (pinnable), with the card's text word for
// word. Slack keeps one attached draft per channel and refuses another with attached_draft_exists,
// and has no tool to change or delete one, so a later draft to the same place replaces the earlier
// only by Dan deleting it in Slack, which the answer says.

/** Where a message's draft goes, as a key two cards can share, or undefined when it is not known. */
export const draftKeyOf = (r: Requester, s: SlackTo | undefined): string | undefined => {
  if (r.via === 'slack') return s?.channel_id && s.thread_ts ? `thread:${s.channel_id}:${s.thread_ts}` : undefined
  return s?.user_id ? `dm:${s.user_id}` : undefined
}

export type DraftAsk = {
  requester: Requester
  message: string
  slack?: SlackTo
  /** An earlier card that asked for a draft to the same place: its PR, and whether it was this card with this message. */
  earlier?: { pr: number; same: boolean }
}

const EXISTS =
  "If Slack answers attached_draft_exists, another draft for that channel is already in Dan's Drafts (Slack keeps one per channel and offers no tool to change it): tell him to delete it in Slack, then save this one again. Never save the message to another channel, or send it, instead."

/** What the card's answer tells the session about the message's Slack draft. */
export const draftLineOf = (d: DraftAsk): string => {
  const { name } = d.requester
  const s = d.slack
  const words = `with message set to exactly the message on this card, word for word. Run /no-ai-tells on it first; if that changes a word, call this card again with the new message before saving, so the draft is the text Dan saw. ${NEVER}`
  let how: string
  let where: string
  if (d.requester.via === 'slack') {
    if (!(s?.channel_id && s.thread_ts))
      return `No Slack thread was given for the message for ${name}, which is owed as a Slack draft reply in the thread ${name} asked in. Find that thread (the link Dan pasted names its channel id and its parent message time) and save it with slack_send_message_draft with that channel_id and thread_ts, ${words} If the thread cannot be found, save nothing and tell Dan the message for ${name} has no Slack draft because its thread is not known. Pass slack.channel_id and slack.thread_ts on the next card for this thread. ${EXISTS}`
    how = `slack_send_message_draft with channel_id "${s.channel_id}" and thread_ts "${s.thread_ts}"`
    where = 'in that thread'
  } else {
    where = `in a DM to ${name}`
    if (!s?.user_id)
      return `The message for ${name} is owed as a Slack draft ${where}. Find ${name}'s Slack user id with slack_search_users, then save it with slack_send_message_draft with that user id as channel_id (Slack takes a user id as the DM's channel), ${words} If no Slack user is clearly ${name}, save nothing and tell Dan the message for ${name} has no Slack draft because ${name} could not be found in Slack. ${EXISTS}`
    how = `slack_send_message_draft with channel_id "${s.user_id}" (Slack takes a user id as the DM's channel)`
  }
  const lead = d.earlier
    ? d.earlier.same
      ? `A Slack draft of this message was already asked for on an earlier card for #${d.earlier.pr}: save it only if it is not saved yet. `
      : `An earlier card (#${d.earlier.pr}) already asked for a draft ${where}, and Slack keeps one per channel, so this draft replaces that one. `
    : ''
  return `${lead}Save the message for ${name} as a Slack draft ${where} for Dan to send himself: call ${how}, ${words} Then tell Dan it is a draft waiting ${where} and that nothing was sent. ${EXISTS}`
}

/** /live: the project's recent cards, newest first, then every message not yet marked sent. */
export const liveList = (cards: readonly Card[]): string => {
  if (!cards.length) return 'No merged changes have a card in this project yet.'
  const sorted = [...cards].sort((a, b) => b.at - a.at)
  const unsent = sorted.filter(c => c.requester && c.message && c.sentAt === undefined)
  return [
    ...sorted.map(c => `- ${titleOf(c.state, c.title)} (#${c.pr})`),
    // A message held until its change is live is listed without its words (#1335).
    ...(unsent.length
      ? ['', 'Not sent yet:', ...unsent.map(c => (isOut(c.state) ? `- Message for ${c.requester?.name} (#${c.pr}): ${c.message}` : `- Message for ${c.requester?.name} waits until #${c.pr} is live.`))]
      : []),
  ].join('\n')
}
