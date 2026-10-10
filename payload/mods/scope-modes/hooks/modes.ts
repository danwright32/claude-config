import type { ScopeModesPlace, ScopeModesScope } from '../types/index.d.ts'
import { FINISHED, NEW_WORK } from './winddown.ts'

// What each mode does, as one definition (#1055). The acknowledgement Claude opens its reply with
// when Dan switches a mode, and the note each prompt carries while the mode is on, are both built
// from it, so what Dan is told a mode does cannot drift from what Claude is told to do (L41).
// Winding down's refusals are the words its own guard refuses with (NEW_WORK in winddown.ts), and
// what it finishes is the list its note gives (FINISHED), so its acknowledgement follows them.
//
// Each part is a phrase after "I will" and "I will not", in words that read the same whoever says
// them: Claude to Dan in the acknowledgement, and the mod to Claude in the note.
export type Mode = ScopeModesScope | ScopeModesPlace
export type ModeDef = {
  /** The mode's name as the band and the commands say it. */
  name: string
  /** What Claude does now. */
  will: string
  /** What Claude does not do now, which the mode refuses or holds. */
  willNot: string
  /** How the mode ends, when it says more than a switch back. */
  ends?: string
}

// "a, b or c": the phrases of a list, as a sentence carries them.
const orList = (parts: readonly string[]): string => (parts.length < 2 ? (parts[0] ?? '') : `${parts.slice(0, -1).join(', ')} or ${parts[parts.length - 1]}`)

export const MODE_DEF: Record<Mode, ModeDef> = {
  'NO BUILD': {
    name: 'No build',
    will: 'read, research, run tests and checks, write scratchpad notes, and do GitHub issue, milestone and label work',
    willNot: 'edit anything outside the scratchpad, commit, make a branch or a PR, deploy, or change data',
    ends: 'Building waits for a yes to Switch to build, and /build turns it off.',
  },
  'WINDING DOWN': {
    name: 'Winding down',
    will: `finish every PR this session opened, each ${FINISHED}, asking with a picker when a decision is needed`,
    willNot: orList(Object.values(NEW_WORK)),
    ends: 'It ends by itself once every merge is live, and /build ends it sooner.',
  },
  away: {
    name: 'Away',
    will: 'deliver results as a private claude.ai page, readable on the phone',
    willNot: 'open anything on the Mac or take focus: whatever needs the Mac is held until home',
  },
  home: {
    name: 'Home',
    will: 'deliver results on the Mac as CLAUDE.md says (HTML in Chrome, drafts in BBEdit, images and PDFs in Preview)',
    willNot: 'run anything held while away until its button in the held card is pressed',
  },
}

/** What the mode does, in two or three sentences: what Claude will do, will not do, and how it ends. */
export const modeDoes = (mode: Mode): string => {
  const d = MODE_DEF[mode]
  return `I will ${d.will}. I will not ${d.willNot}.${d.ends ? ` ${d.ends}` : ''}`
}

/** The words Claude is told to open its reply with, around the acknowledgement itself. */
export const ACK_LEAD = 'Open your reply with one short acknowledgement of the switch, in these words:'
const ackOf = (said: string) => `${ACK_LEAD} "${said}"`

/**
 * The acknowledgement when a mode turns on: its name, what it now does, and the mode it replaced,
 * when one was on. `first` is the opening sentence where it says more than the name (away and home
 * say how many sessions were told).
 */
export const ackOn = (mode: Mode, opts: { replaced?: Mode | null; first?: string } = {}): string => {
  const replaced = opts.replaced && opts.replaced !== mode ? ` It replaces ${MODE_DEF[opts.replaced].name.toLowerCase()}.` : ''
  return ackOf(`${opts.first ?? `${MODE_DEF[mode].name} is on.`}${replaced} ${modeDoes(mode)}`)
}

/** The acknowledgement when a scope mode turns off: what it no longer does. */
export const ackOff = (mode: ScopeModesScope): string => {
  const d = MODE_DEF[mode]
  return ackOf(`${d.name} is off. I build as usual again, and ${d.name.toLowerCase()} no longer stops me: I may ${d.willNot} once more.`)
}
