import type { EngineInterface, Hook, On } from 'claude-code'
import type { StepsPages } from '../types/index.d.ts'
import { nextStep } from './card.ts'
import { isStepsPage, pageRefusal, signsOf } from './page.ts'
import { TURN_TIMEOUT_MS, turnAt } from './turn.ts'
import { saysNoneNow } from './waiting.ts'
import { errorText } from './mod-kit/skew.ts'

// #1811: a page of steps for Dan published with the Artifact tool (Slate's "Regal changes for Marcia",
// 13 journey edits, 2026-10-27) was handed over with no steps card, and Dan had to ask for one twice.
// So a turn that publishes a page of steps (hooks/page.ts judges the page) does not end without the
// steps tool called in it, or Claude saying none of its steps are Dan's to do now. Refused at most
// once per chain of turn ends, so it can never trap a turn: the turn's own transcript shows the
// refusal (hooks/turn.ts reads this mod's marks), and where it cannot be read, `stop_hook_active`.
// A page published again while the card pinned for it still shows asks nothing, since pages are
// republished often (39 publishes of 6 pages in this Mac's transcripts, measured 2026-10-27).

const MOD = 'manual-steps'
const TOOL = 'mcp__manual-steps__steps'
const pagesRef = { plugin: 'manual-steps', key: 'pages' } as const
// The card register.tsx keeps, read here only to know whether it still shows unfinished steps.
const cardRef = { plugin: 'manual-steps', key: 'card' } as const
const NO_PAGES: StepsPages = { turn: [], isPinned: false, owed: [], covered: [] }
// What a page is published as: a page of HTML or Markdown, the only kinds a person reads steps on.
const PAGE_FILE = /\.(?:html?|md|markdown)$/i

const message = (err: unknown) => errorText(err, MOD)

// Read, change and write the pages with ifVersion, again on a miss, since two pages published at once
// must both land (assume it runs twice). Returns the pages as they were before the change that took.
// Each takes $ as a function declaration, the one form the engine follows $ into past an import.
async function changePages($: EngineInterface, fn: (pages: StepsPages) => StepsPages): Promise<StepsPages> {
  for (let attempt = 0; attempt < 10; attempt++) {
    const held = await $.state.get(pagesRef)
    const was = held.value ?? NO_PAGES
    const set = await $.state.set(pagesRef, fn(was), { ifVersion: held.version })
    if (set.isSet) return was
  }
  throw new Error('the pages published this turn changed under every one of 10 attempts to record one')
}

async function tryChange($: EngineInterface, what: string, fn: (pages: StepsPages) => StepsPages): Promise<void> {
  try {
    await changePages($, fn)
  } catch (err) {
    $.ui.log(`Manual steps could not record ${what}: ${message(err)}`)
  }
}

/** The steps tool answered without refusing: whatever it pinned covers the pages the last refusal named. */
export async function notePinned($: EngineInterface): Promise<void> {
  await tryChange($, 'that the steps tool was called', p => ({ ...p, isPinned: true, owed: [], covered: [...p.owed] }))
}

/** A main turn started: a page published in one that ended with no turn end (Esc) is not judged in this one. */
export async function clearTurnPages($: EngineInterface): Promise<void> {
  await tryChange($, 'that a new turn started', p => (p.turn.length || p.isPinned ? { ...p, turn: [], isPinned: false } : p))
}

// The page published from `path` judged, and kept for the turn's end when it gives Dan steps. One
// that cannot be read is said in the log and refuses nothing: refusing on a guess would send Claude
// to pin steps that may not be there (fail loud, not silent).
async function judgePage($: EngineInterface, path: string): Promise<void> {
  let where = path
  let page: string
  try {
    if (!path.startsWith('/')) where = `${(await $.session.cwd()).replace(/\/+$/, '')}/${path}`
    page = await $.fs.read(where)
  } catch (err) {
    $.ui.log(`Manual steps could not read the page published from ${where}, so whether it gives Dan steps was not judged: ${message(err)}`)
    return
  }
  if (!isStepsPage(signsOf(page))) return
  await tryChange($, `the page of steps published from ${where}, so the turn's end will not ask about it`, p => (p.turn.includes(where) ? p : { ...p, turn: [...p.turn, where] }))
}

// The pages published since the last turn end, taken as the turn ends: the turn's own are cleared,
// and when the steps tool was called the card it pinned covers them from now on.
async function takePages($: EngineInterface): Promise<StepsPages> {
  try {
    return await changePages($, p => ({ turn: [], isPinned: false, owed: [], covered: p.isPinned ? [...new Set([...p.covered, ...p.turn])] : p.covered }))
  } catch (err) {
    $.ui.log(`Manual steps could not read the pages published this turn, so none was checked for a steps card: ${message(err)}`)
    return NO_PAGES
  }
}

/** The page check's hook on each publish: only one that went through, of a page, is judged. */
export function registerPages(on: On, isInteractive: () => boolean): void {
  // Passed down first, so every guard beneath still judges the call; an asset upload, a read and a
  // list publish no page.
  on('tool.call', { tool: 'Artifact' }, async ($, e, next) => {
    const done = await next(e)
    if (!isInteractive() || done.deny !== undefined || done.isError === true) return done
    const input = e as unknown as { action?: unknown; file_path?: unknown; asset?: unknown }
    const action = input.action ?? 'publish'
    if (action !== 'publish' || input.asset === true || typeof input.file_path !== 'string' || !PAGE_FILE.test(input.file_path)) return done
    await judgePage($, input.file_path)
    return done
  })
}

type Stop = Hook<'classic.Stop'>

/**
 * The turn's end as the hooks beneath answer it, with the page refusal added when a page of steps was
 * published this turn and nothing answered it. The engine takes one `classic.Stop` hook per mod, so
 * register.tsx's hook, which judges a step left in prose, starts from this answer.
 */
export async function pagesAtStop($: Parameters<Stop>[0], e: Parameters<Stop>[1], next: Parameters<Stop>[2], isInteractive: boolean): Promise<Awaited<ReturnType<Stop>>> {
  const r = await next(e)
  if (!isInteractive) return r
  const pages = await takePages($)
  if (pages.isPinned || !pages.turn.length) return r
  let shown: boolean
  try {
    const held = (await $.state.get(cardRef)).value ?? null
    shown = held !== null && !held.isCarried && nextStep(held) !== undefined
  } catch (err) {
    // Unread, it is not taken as no card: refusing on a guess could ask for a card already there.
    $.ui.log(`Manual steps could not read the steps card, so a page of steps published this turn was not checked: ${message(err)}`)
    return r
  }
  const unanswered = pages.turn.filter(p => !(shown && pages.covered.includes(p)))
  if (!unanswered.length) return r
  // Read only when a page is unanswered, which most turn ends never reach.
  const turn = await turnAt(typeof e.transcript_path === 'string' ? e.transcript_path : '', argv => $.process.run(argv, { timeoutMs: TURN_TIMEOUT_MS }))
  if (turn.state === 'unreadable') $.ui.log(`Manual steps could not read this turn from its transcript, so only its last message was read for a page of steps answered in words: ${turn.why}`)
  const isTurnRead = turn.state === 'read' && turn.promptId !== null
  if (isTurnRead ? turn.isOurs : e.stop_hook_active) return r
  const last = typeof e.last_assistant_message === 'string' ? [e.last_assistant_message] : []
  if (saysNoneNow([...(turn.state === 'read' ? turn.texts : []), ...last])) return r
  await tryChange($, 'the pages the refusal named, so the next card will not cover them', p => ({ ...p, owed: unanswered }))
  const ours = pageRefusal(unanswered, TOOL)
  return { ...r, block: r.block ? `${r.block}\n\n${ours}` : ours }
}
