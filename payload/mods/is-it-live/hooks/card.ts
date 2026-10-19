// Is it live (claude-config#617): the card's state, its words, the message row and the /live list.
// Pure, so each rule is tested on its own. Looks settled with Dan on 2026-10-04 (docs/mods-design.md,
// Is it live); the spec agreed 2026-10-03.

export const MOD = 'is-it-live'

/** How Claude found the deploy: proved live, still running, failed, unreachable, or no deploy step. */
export const DEPLOYS = ['live', 'deploying', 'failed', 'unreachable', 'none'] as const
export type Deploy = (typeof DEPLOYS)[number]
export type State = 'live' | 'deploying' | 'unconfirmed' | 'no-deploy'

/** Who asked, when it was not Dan: an issue they reported, a pasted Slack thread, or a person Dan named. */
export const VIAS = ['issue', 'slack', 'named'] as const
export type Requester = { name: string; via: (typeof VIAS)[number]; issue?: number }

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
}

/** A card as kept: the input, the PR's own title and link as GitHub gave them, and when. */
export type Card = { repo: string; pr: number; title: string; url: string; state: State; at: number; requester?: Requester; message?: string; sentAt?: number }

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

/** Why the card cannot be made from this input, or undefined when it can. Each field named. */
export const reasonToRefuse = (i: CardInput): string | undefined => {
  if (typeof i.repo !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(i.repo)) return 'repo must be owner/name, as GitHub spells it.'
  if (!Number.isInteger(i.pr) || i.pr <= 0) return 'pr must be the pull request number.'
  if (!DEPLOYS.includes(i.deploy)) return `deploy must be one of ${DEPLOYS.join(', ')}.`
  if (i.deploy !== 'none' && i.deploy !== 'deploying' && !(typeof i.checked === 'string' && i.checked.trim()))
    return i.deploy === 'live' ? 'live needs checked: how it was checked that the change is live.' : 'checked must say why live could not be confirmed.'
  const n = typeof i.changed === 'string' ? sentences(i.changed) : 0
  if (n < 2 || n > 3) return `changed must say what changed in 2 to 3 sentences (it has ${n}).`
  if (!i.see || typeof i.see.link !== 'string' || !/^https?:\/\//.test(i.see.link)) return 'see.link must be the direct link to where the change shows.'
  if (!Array.isArray(i.see.clicks) || !i.see.clicks.every(c => typeof c === 'string' && c.trim())) return 'see.clicks must be the exact clicks, one per entry.'
  const r = i.requester
  if (r !== undefined) {
    if (!r || typeof r.name !== 'string' || !r.name.trim()) return 'requester.name must say who asked.'
    if (!VIAS.includes(r.via)) return `requester.via must be one of ${VIAS.join(', ')}.`
    if (/^dan$/i.test(r.name.trim())) return 'No message when Dan asked: leave requester out.'
    if (r.via === 'issue' && !(Number.isInteger(r.issue) && (r.issue as number) > 0)) return 'requester.issue must be the issue number when they asked in an issue.'
    // The message tells them it is live, so only a call saying the change is out owes it; an
    // earlier call may pass it, and it is held until then (#1335).
    const given = typeof i.message === 'string' && i.message.trim()
    if (!given && isOut(stateOf(i.deploy))) return `A message for ${r.name} is owed, in Dan's voice.`
    if (given && DASH.test(i.message as string)) return "The message must have no dashes (Dan's voice): use a comma, colon or a new sentence."
  } else if (has(i as unknown as Record<string, unknown>, 'message') && i.message) {
    return 'A message is only for someone other than Dan who asked: say who asked in requester, or leave the message out.'
  }
  return undefined
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
