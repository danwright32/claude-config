import type { EngineInterface, Hook, Register } from 'claude-code'
import type { StepsCard, StepsPaneId } from '../types/index.d.ts'
import { cardFrom, cardLines, carriedNote, DROPPED_AFTER_MS, finish, fold, nextStep, paneColumns, sent } from './card.ts'
import type { StepsVerdict } from './card.ts'

// The manual steps card (#614), settled with Dan on 2026-10-03 (spec) and 2026-10-04 (design
// rounds, docs/mods-design.md "Manual steps"). Claude hands steps over through the `steps` tool,
// which refuses a step with no link or exact location and one Claude has not checked against the
// current state. The card is a side pane when the terminal is wide enough for a pane opened unasked
// (144 columns), else the steps row of the band, both drawn by mod-kit (the pane since #690). Done sends "step N done"; Claude
// checks it took where it can and answers through `steps_done`. Unfinished steps are kept per
// project in $.store and held at the next session start there until Claude has re-checked them.

const MOD = 'manual-steps'
// The pane /steps opens, and the one a new card tries unasked: never the same id, since Claude Code
// places an unasked pane from 110 columns rather than 144 once its id has been asked for (#708).
const ASKED_PANE = 'steps' satisfies StepsPaneId
const UNASKED_PANE = 'steps-card' satisfies StepsPaneId
const PANES: readonly StepsPaneId[] = [ASKED_PANE, UNASKED_PANE]
const PANE_TITLE = 'Manual steps'
const TOOL = 'mcp__manual-steps__steps'
const VERDICT_TOOL = 'mcp__manual-steps__steps_done'
const AMBER = 'warning'

const cardRef = { plugin: 'manual-steps', key: 'card' } as const
const placeRef = { plugin: 'manual-steps', key: 'place' } as const
const waitingRef = { plugin: 'manual-steps', key: 'waiting' } as const

const message = (err: unknown) => String((err as Error)?.message ?? err)
const isPane = (place: unknown): place is StepsPaneId => (PANES as readonly unknown[]).includes(place)

// The project a card belongs to: the repository's root, the main checkout's for a worktree, so a
// worktree session and the main checkout share one card; else the folder the session started in.
// `legacy` is where #614 kept it, the session's own folder, so a card a worktree session kept
// before #708 is still found. A repository that cannot be read throws to the caller, which says
// so: taken as no repository, a worktree's card would be kept under its own folder again.
const projectKeys = async ($: EngineInterface) => {
  const folder = (await $.session.root().catch(() => undefined)) ?? (await $.session.cwd())
  const repo = await $.session.repo()
  return { key: `card:${repo?.root ?? folder}`, legacy: `card:${folder}` }
}

// Kept for the next session in this project: written whenever the card changes, removed once
// nothing is left to do. Never with "sent", since the turn that would answer it does not reach the
// next session. A failure here loses only the carry over, so it is said and the action stands
// (fail loud, not silent).
const persist = async ($: EngineInterface) => {
  const card = (await $.state.get(cardRef)).value ?? null
  try {
    const { key } = await projectKeys($)
    if (card && nextStep(card) !== undefined) {
      const { isCarried: _carried, ...kept } = card
      await $.store.set(key, { ...kept, steps: kept.steps.map(({ isSent: _sent, ...s }) => s) })
    } else await $.store.delete(key)
  } catch (err) {
    $.ui.toast(`The manual steps could not be saved for the next session: ${message(err)}.`)
  }
}

// The steps kept for this project by an earlier session, with any #614 kept under the worktree's own
// folder moved to the repository root: on their own, or folded into the card already there, which
// Claude re-checks before anything shows. Written before the old entry is removed, so a failure
// between the two loses nothing, and the fold of a second run adds nothing.
const readKept = async ($: EngineInterface): Promise<StepsCard | undefined> => {
  const { key, legacy } = await projectKeys($)
  const kept = (await $.store.get(key)) as StepsCard | undefined
  if (legacy === key) return kept
  const old = (await $.store.get(legacy)) as StepsCard | undefined
  if (old === undefined) return kept
  const moved = kept === undefined ? old : fold(kept, old)
  await $.store.set(key, moved)
  await $.store.delete(legacy)
  return moved
}

// Read, change and write the card with ifVersion, again on a miss, so a Done pressed twice before
// the redraw, or a press racing Claude's verdict, both land on the card as it is (assume it runs twice).
const change = async <T,>($: EngineInterface, fn: (card: StepsCard | null) => { card: StepsCard | null; out: T }): Promise<T> => {
  for (let attempt = 0; attempt < 10; attempt++) {
    const held = await $.state.get(cardRef)
    const r = fn(held.value ?? null)
    if (r.card === (held.value ?? null)) return r.out
    const set = await $.state.set(cardRef, r.card, { ifVersion: held.version })
    if (set.isSet) {
      await persist($)
      return r.out
    }
  }
  throw new Error('the steps card changed under every one of 10 attempts to update it')
}

/** Shows the card in the band; the reason when mod-kit refused it. */
const publishBand = async ($: EngineInterface, card: StepsCard): Promise<string | undefined> => {
  try {
    await $.modkit.bandRow({ mod: MOD, id: 'steps', slot: 'steps', frame: { kind: 'left-rule', color: AMBER }, lines: cardLines(card) as never })
    return undefined
  } catch (err) {
    $.ui.log(`manual-steps: the steps card could not be shown in the band: ${message(err)}`, { to: 'debug' })
    return message(err)
  }
}

/** Shows the card in the side pane `id`, drawn by mod-kit as the band draws it (#690); the reason when mod-kit refused it. */
const publishPane = async ($: EngineInterface, id: StepsPaneId, card: StepsCard): Promise<string | undefined> => {
  try {
    await $.modkit.pane({ mod: MOD, id, frame: { kind: 'left-rule', color: AMBER }, lines: cardLines(card) as never })
    return undefined
  } catch (err) {
    $.ui.log(`manual-steps: the steps card could not be shown in the pane: ${message(err)}`, { to: 'debug' })
    return message(err)
  }
}

const clearPane = async ($: EngineInterface, id: StepsPaneId) => {
  try {
    await $.modkit.clearPane({ mod: MOD, id })
  } catch (err) {
    $.ui.log(`manual-steps: the steps card could not be taken out of the pane: ${message(err)}`, { to: 'debug' })
  }
}

// The side pane `id` with the card in it, published before the pane opens so it never opens empty.
// True once placed, when it takes over from the band or the other pane. One Claude Code did not
// place is closed rather than left waiting, so it can never appear later beside the same card in
// the band, and one mod-kit refused to draw is not opened. Docked, it asks to be as wide as the
// card's lines (#708).
const openPane = async ($: EngineInterface, id: StepsPaneId, card: StepsCard): Promise<boolean> => {
  if (await publishPane($, id, card)) return false
  const opened = await $.ui
    .open({ id, title: PANE_TITLE, columns: paneColumns(card) })
    .catch(() => ({ isPlaced: false as const, reason: 'no pane' }))
  if (opened.isPlaced) {
    const was = (await $.state.get(placeRef)).value ?? null
    await $.state.set(placeRef, id)
    if (isPane(was) && was !== id) {
      await $.ui.close({ id: was }).catch(() => undefined)
      await clearPane($, was)
    }
    await clearBand($)
    return true
  }
  await $.ui.close({ id }).catch(() => undefined)
  await clearPane($, id)
  return false
}

const clearBand = async ($: EngineInterface) => {
  try {
    await $.modkit.clearBandRow({ mod: MOD, id: 'steps' })
  } catch (err) {
    $.ui.log(`manual-steps: the steps card could not be taken out of the band: ${message(err)}`, { to: 'debug' })
  }
}

// A new card: in the pane already showing one, else the side pane when a pane opened unasked fits
// (Claude Code places one from 144 columns), else the band. A pane mod-kit will not draw the new
// card in is closed, so it cannot go on showing the old one beside the band.
const placeNew = async ($: EngineInterface, card: StepsCard): Promise<string | undefined> => {
  const place = (await $.state.get(placeRef)).value ?? null
  if (isPane(place)) {
    if (!(await publishPane($, place, card))) return undefined
    await leavePane($)
  }
  if (await openPane($, UNASKED_PANE, card)) return undefined
  await $.state.set(placeRef, 'band')
  return publishBand($, card)
}

// Out of whichever pane holds the card, as it goes to the band, so it never shows in both.
const leavePane = async ($: EngineInterface) => {
  const place = (await $.state.get(placeRef)).value ?? null
  if (!isPane(place)) return
  await $.state.set(placeRef, null)
  await $.ui.close({ id: place }).catch(() => undefined)
  await clearPane($, place)
}

// Takes the card away: out of the band and the pane.
const hide = async ($: EngineInterface) => {
  const place = (await $.state.get(placeRef)).value ?? null
  await $.state.set(placeRef, null)
  await clearBand($)
  if (isPane(place)) await $.ui.close({ id: place }).catch(() => undefined)
  for (const id of PANES) await clearPane($, id)
}

// After the card changed: published again wherever it is shown.
const refresh = async ($: EngineInterface) => {
  const card = (await $.state.get(cardRef)).value ?? null
  if (!card || nextStep(card) === undefined) return hide($)
  const place = (await $.state.get(placeRef)).value ?? null
  if (place === null) return
  const failed = isPane(place) ? await publishPane($, place, card) : await publishBand($, card)
  if (failed) $.ui.toast(`The steps card could not be updated: ${failed}.`)
}

// Step `n` (0 based) open again with its Done, when it is still waiting on Claude. True when it was.
const unsend = ($: EngineInterface, n: number) =>
  change($, card => (card && card.steps[n]?.isSent ? { card: sent(card, n, false), out: true } : { card, out: false }))

// Done back on step `n` (0 based) when Claude never said whether it took, and the toast saying so.
// One wording whichever way it was found (#708, #734).
const giveDoneBack = async ($: EngineInterface, n: number) => {
  if (!(await unsend($, n))) return
  await refresh($)
  $.ui.toast(`Claude did not say whether step ${n + 1} took. Press Done to ask again.`)
}

// #734: a "step N done" prompt queued behind a running turn and then dropped (Esc drops the queue),
// or one a prompt hook refused, starts no turn, so the turn.complete guard below never arms and
// the step would stay sent for the session. So once no main turn has run for DROPPED_AFTER_MS with
// the step still sent and its turn never started, Done comes back. Armed at the press and again at
// each main turn's end; only the latest arming may act, so the one armed at the press cannot fire
// seconds after the turn it waited behind ended, while the settings hooks still run.
let runningTurn: string | null = null
let armed = 0
let fallback: { cancel: () => void } | undefined
const armFallback = ($: EngineInterface) => {
  const mine = ++armed
  fallback?.cancel()
  try {
    fallback = $.clock.after(DROPPED_AFTER_MS, () => {
      void giveBackDropped($, mine).catch(err => $.ui.log(`manual-steps: could not bring back a Done whose prompt was dropped: ${message(err)}`, { to: 'debug' }))
    })
  } catch (err) {
    $.ui.log(`manual-steps: could not arm the fallback that brings back a Done whose prompt was dropped: ${message(err)}`, { to: 'debug' })
  }
}
const giveBackDropped = async ($: EngineInterface, mine: number) => {
  if (mine !== armed || runningTurn !== null) return
  const card = (await $.state.get(cardRef)).value ?? null
  const i = card ? card.steps.findIndex(s => s.isSent) : -1
  if (i < 0) return
  // Its turn started: the end of that turn decides, below.
  if ((await $.state.get(waitingRef)).value?.step === i + 1) return
  await giveDoneBack($, i)
}

const pressDone = async ($: EngineInterface) => {
  const n = await change($, card => {
    const i = card ? nextStep(card) : undefined
    if (!card || i === undefined || card.steps[i]?.isSent) return { card, out: undefined }
    return { card: sent(card, i, true), out: i }
  })
  if (n === undefined) return
  await refresh($)
  try {
    await $.prompt.submit({ text: `step ${n + 1} done`, asUser: true })
  } catch (err) {
    await unsend($, n)
    await refresh($)
    $.ui.toast(`Could not tell Claude step ${n + 1} is done: ${message(err)}. Press Done again.`)
    return
  }
  armFallback($)
}

// What each Copy on the open step copies, and what its toast calls it.
const COPIES = { value: 'value', url: 'link' } as const

const pressCopy = async ($: EngineInterface, field: keyof typeof COPIES, surface: string | undefined) => {
  const card = (await $.state.get(cardRef)).value ?? null
  const i = card ? nextStep(card) : undefined
  const text = card && i !== undefined ? card.steps[i]?.[field] : undefined
  if (i === undefined || !text) return
  const what = COPIES[field]
  try {
    const r = await $.ui.copy({ text, surface: surface as never })
    $.ui.toast(r.isCopied ? `Copied the ${what} for step ${i + 1}.` : `Could not copy the ${what} for step ${i + 1} (${r.reason}).`)
  } catch (err) {
    $.ui.toast(`Could not copy the ${what} for step ${i + 1} (${message(err)}).`)
  }
}

/** The scope modes mod's noun (#621) as its contract has it; it may not be loaded at all. */
type ScopeModes = { hold: (input: { label: string; prompt: string }) => Promise<{ isHeld: boolean }> }

// Whether the card was held because Dan is away. The engine needs the noun called in place, so its
// absence (the scope modes mod not loaded, which is home) arrives as a TypeError, as the status
// bar reads the job watcher's. One that is loaded and fails to answer is said, and the card is
// shown, since a card shown while away costs less than steps nobody sees.
const holdWhileAway = async ($: EngineInterface, card: StepsCard): Promise<boolean> => {
  try {
    const r = await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.hold({
      label: card.heading,
      prompt: `Pin the manual steps for "${card.heading}" again with the manual-steps steps tool: check each against the current state first.`,
    })
    return r?.isHeld === true
  } catch (err) {
    const isAbsent = err instanceof TypeError && /undefined|not a function|null/.test(message(err))
    if (!isAbsent) $.ui.log(`Manual steps could not ask whether Dan is away, so the card is shown: ${message(err)}`)
    return false
  }
}

const left = (card: StepsCard) => {
  const n = nextStep(card)
  return n === undefined ? 'every step is finished' : `step ${n + 1} of ${card.steps.length} is next`
}

const STEP_SCHEMA = {
  type: 'object',
  properties: {
    title: { type: 'string', description: 'What to do, in a few words.' },
    url: { type: 'string', description: 'The direct https:// link to the page the step is done on.' },
    location: { type: 'string', description: 'Only where there is no page: the exact app, screen and section.' },
    clicks: { type: 'string', description: 'The exact click path on that page.' },
    value: { type: 'string', description: 'A value to paste, given a Copy button.' },
    checked: {
      type: 'string',
      enum: ['already-done', 'not-done', 'cannot-check'],
      description: 'What you found when you checked this step against the current state before handing it over.',
    },
  },
  required: ['title', 'checked'],
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // Steps are for a person at the prompt; a -p run or the SDK has nobody to do them.
    if (!e.isInteractive) return next(e)
    await $.tool.register({
      name: 'steps',
      description:
        'Pin manual steps for Dan as a card he works through, instead of listing them in your reply. Check every step against the current state first (the hand-off rule). Each step needs its direct link, or where there is no page its exact location, plus the exact clicks and any value to paste. Pinning replaces the card. When Dan presses Done you receive "step N done": check it took where you can and call steps_done.',
      inputSchema: {
        type: 'object',
        properties: { heading: { type: 'string', description: 'What the steps are for, in a few words.' }, steps: { type: 'array', items: STEP_SCHEMA, minItems: 1 } },
        required: ['heading', 'steps'],
      },
    })
    await $.tool.register({
      name: 'steps_done',
      description:
        'Record whether a pinned manual step took, after Dan pressed Done ("step N done") or said he did it: checked when you verified it, per-you when it cannot be checked, not-done when you checked and it did not take (the step opens again).',
      inputSchema: {
        type: 'object',
        properties: { step: { type: 'integer', minimum: 1 }, checked: { type: 'string', enum: ['checked', 'per-you', 'not-done'] } },
        required: ['step', 'checked'],
      },
    })
    await $.command.register({ name: 'steps', description: 'Show the manual steps card again' })
    // Carried over from an earlier session here: held, not shown, until Claude has re-checked them
    // and pinned them again (the context note below asks for that). Only at a session's own start:
    // a reload of the mod runs this again with $.state kept, and the card already in it is the one
    // Dan is working through, not one to hold (#708).
    try {
      const held = await $.state.get(cardRef)
      if (held.version === 0) {
        const kept = await readKept($)
        if (kept && Array.isArray(kept.steps) && nextStep(kept) !== undefined) {
          const set = await $.state.set(cardRef, { ...kept, isCarried: true }, { ifVersion: 0 })
          if (set.isSet) await $.state.set(placeRef, null)
        }
      }
    } catch (err) {
      $.ui.log(`Manual steps could not read the steps kept from an earlier session: ${message(err)}`)
    }
    return next(e)
  })

  on('prompt.context', async ($, e, next) => {
    const card = (await $.state.get(cardRef)).value ?? null
    if (!card?.isCarried) return next(e)
    return next({ ...e, blocks: [...e.blocks, { name: 'manualSteps', text: carriedNote(card) }] })
  })

  // The turn "step N done" started, noted so its end can be judged. A turn already running when
  // Done was pressed is not it: the prompt waits behind that turn.
  on('turn.start', async ($, e, next) => {
    const r = await next(e)
    // Only the main loop raises turn.start; a subagent's run raises none.
    runningTurn = e.turnId
    const n = /^step (\d+) done$/.exec(e.text.trim())?.[1]
    const card = (await $.state.get(cardRef)).value ?? null
    if (n !== undefined && card?.steps[Number(n) - 1]?.isSent) await $.state.set(waitingRef, { turnId: e.turnId, step: Number(n) })
    return r
  })

  // That turn ended, answered, interrupted or failed, with the step still waiting on Claude: its
  // Done comes back and a toast says why, so a Done is never stuck on "sent" (#708). A verdict
  // Claude gives later still lands, since a step need not be waiting to take one.
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined) return r
    runningTurn = null
    const waiting = (await $.state.get(waitingRef)).value ?? null
    if (!waiting || waiting.turnId !== e.turnId) {
      // A step still sent whose turn has not started may be queued behind this one, or dropped
      // with it: the fallback above waits from now (#734).
      if ((await $.state.get(cardRef)).value?.steps.some(s => s.isSent)) armFallback($)
      return r
    }
    await $.state.set(waitingRef, null)
    await giveDoneBack($, waiting.step - 1)
    return r
  })

  // Both tools are answered here and never passed down, so the guards beneath (the secret guard) are
  // asked through mod-kit's screen before a value is drawn with Copy or kept (#707).
  on('tool.call', { tool: TOOL }, async ($, e) => {
    const refused = await $.modkit.screen(e)
    if (refused) return refused
    const made = cardFrom(e)
    if ('refusal' in made) return { deny: made.refusal }
    const card = made.card
    if (nextStep(card) === undefined) {
      await change($, () => ({ card: null, out: undefined }))
      await hide($)
      const n = card.steps.length
      return { result: `${n === 1 ? 'The one step was' : `All ${n} steps were`} already done, so nothing was pinned.` }
    }
    // While Dan is away (#621) the steps are held for the held card he sees on coming home, not
    // shown on the Mac; kept in the store all the same. Pressing the held row asks Claude to check
    // them again and pin them.
    const held = await holdWhileAway($, card)
    if (held) {
      await change($, () => ({ card: { ...card, isCarried: true }, out: undefined }))
      await hide($)
      return { result: `Dan is away, so "${card.heading}" was held for when he is home rather than shown.` }
    }
    await change($, () => ({ card, out: undefined }))
    const failed = await placeNew($, card)
    if (failed) return { result: `The steps card could not be shown: ${failed}. Give Dan the steps in your reply instead.` }
    return { result: `Pinned "${card.heading}": ${left(card)}.` }
  })

  on('tool.call', { tool: VERDICT_TOOL }, async ($, e) => {
    const refused = await $.modkit.screen(e)
    if (refused) return refused
    const input = e as unknown as { step?: unknown; checked?: unknown }
    const out = await change<ReturnType<typeof finish>>($, card => {
      if (!card || card.isCarried) return { card, out: { refusal: 'No steps are pinned; pin them with the steps tool first.' } }
      const r = finish(card, Number(input.step), input.checked as StepsVerdict)
      return 'refusal' in r ? { card, out: r } : { card: r.card, out: r }
    })
    if ('refusal' in out) return { deny: out.refusal }
    const done = nextStep(out.card) === undefined
    if (done) await change($, () => ({ card: null, out: undefined }))
    await refresh($)
    return { result: done ? 'Every step is finished, so the card is gone.' : `Step ${String(input.step)} recorded; ${left(out.card)}.` }
  })

  on('ui.press', { plugin: 'mod-kit', element: 'manual-steps:done' }, async ($, e) => {
    await pressDone($)
    return { element: e.element }
  })
  on('ui.press', { plugin: 'mod-kit', element: 'manual-steps:copy' }, async ($, e) => {
    await pressCopy($, 'value', e.surface)
    return { element: e.element }
  })
  // Claude Code draws no hyperlinks on Apple Terminal, where a long link is text cut at the edge,
  // so this is what takes the whole address there (#708).
  on('ui.press', { plugin: 'mod-kit', element: 'manual-steps:copy-link' }, async ($, e) => {
    await pressCopy($, 'url', e.surface)
    return { element: e.element }
  })

  on('command.run', { command: 'steps' }, async $ => {
    const card = (await $.state.get(cardRef)).value ?? null
    if (!card || nextStep(card) === undefined) return { text: 'No manual steps are pinned for this project.' }
    // Asked, so the pane is placed at any width; under its own id, so asking does not lower the
    // width a later card opened unasked needs.
    if (await openPane($, ASKED_PANE, card)) return { text: 'The steps card is open.' }
    await leavePane($)
    await $.state.set(placeRef, 'band')
    const failed = await publishBand($, card)
    return { text: failed ? `The steps card could not be shown: ${failed}.` : 'The steps card is in the band above the prompt.' }
  })

  // Dan closing either pane does not finish the steps: the card stays pinned, in the band. One hook
  // answering for every id in PANES, so a pane id added there cannot be left without it.
  on('ui.close', closedByHand)
}

const closedByHand: Hook<'ui.close'> = async ($, e, next) => {
  const r = await next(e)
  if (e.origin.kind !== 'person' || !isPane(e.id)) return r
  await clearPane($, e.id)
  const card = (await $.state.get(cardRef)).value ?? null
  if (card && !card.isCarried && nextStep(card) !== undefined) {
    await $.state.set(placeRef, 'band')
    const failed = await publishBand($, card)
    if (failed) $.ui.toast(`The steps card could not be moved to the band: ${failed}.`)
  } else await $.state.set(placeRef, null)
  return r
}
