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

// The state leads the title (design round): "Live:" green, "Merged, deploying:" grey, "Could not
// confirm live:" amber. The no deploy step title is the builder's, not yet settled.
const LEAD: Record<State, string> = {
  live: 'Live',
  deploying: 'Merged, deploying',
  unconfirmed: 'Could not confirm live',
  'no-deploy': 'Merged, no deploy step recorded',
}
export const titleOf = (s: State, title: string): string => `${LEAD[s]}: ${title}`

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
    if (!(typeof i.message === 'string' && i.message.trim())) return `A message for ${r.name} is owed, in Dan's voice.`
    if (DASH.test(i.message)) return "The message must have no dashes (Dan's voice): use a comma, colon or a new sentence."
  } else if (has(i as unknown as Record<string, unknown>, 'message') && i.message) {
    return 'A message is only for someone other than Dan who asked: say who asked in requester, or leave the message out.'
  }
  return undefined
}

/** The card as text: what the model reads, and the transcript row until mod-kit can draw the card. */
export const cardText = (c: CardInput & { state: State; title: string; url: string }): string =>
  [
    titleOf(c.state, c.title),
    ...(c.state === 'unconfirmed' && c.checked ? [c.checked.trim()] : []),
    c.changed.trim(),
    `See it: ${c.see.link}`,
    ...c.see.clicks.map((k, n) => `${n + 1}. ${k.trim()}`),
  ].join('\n')

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
    ...(unsent.length ? ['', 'Not sent yet:', ...unsent.map(c => `- Message for ${c.requester?.name} (#${c.pr}): ${c.message}`)] : []),
  ].join('\n')
}
