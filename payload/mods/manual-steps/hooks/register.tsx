import { read } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { StepsCard } from '../types/index.d.ts'
import { cardFrom, cardLines, carriedNote, finish, nextStep, sent } from './card.ts'
import type { CardPart, StepsVerdict } from './card.ts'

// The manual steps card (#614), settled with Dan on 2026-10-03 (spec) and 2026-10-04 (design
// rounds, docs/mods-design.md "Manual steps"). Claude hands steps over through the `steps` tool,
// which refuses a step with no link or exact location and one Claude has not checked against the
// current state. The card is a side pane when the terminal is wide enough for a pane opened unasked
// (144 columns), else the steps row of the band, through mod-kit. Done sends "step N done"; Claude
// checks it took where it can and answers through `steps_done`. Unfinished steps are kept per
// project in $.store and held at the next session start there until Claude has re-checked them.

const MOD = 'manual-steps'
const PANE = 'steps'
const PANE_TITLE = 'Manual steps'
const TOOL = 'mcp__manual-steps__steps'
const VERDICT_TOOL = 'mcp__manual-steps__steps_done'
const AMBER = 'warning'

const cardRef = { plugin: 'manual-steps', key: 'card' } as const
const placeRef = { plugin: 'manual-steps', key: 'place' } as const

const message = (err: unknown) => String((err as Error)?.message ?? err)

// The project a card belongs to: the repository root, or the folder when there is none.
const projectKey = async ($: EngineInterface) => {
  const root = await $.session.root().catch(() => undefined)
  return `card:${root ?? (await $.session.cwd())}`
}

// Kept for the next session in this project: written whenever the card changes, removed once
// nothing is left to do. A failure here loses only the carry over, so it is said and the action
// stands (fail loud, not silent).
const persist = async ($: EngineInterface) => {
  const card = (await $.state.get(cardRef)).value ?? null
  try {
    const key = await projectKey($)
    if (card && nextStep(card) !== undefined) {
      const { isCarried: _carried, ...kept } = card
      await $.store.set(key, kept)
    } else await $.store.delete(key)
  } catch (err) {
    $.ui.toast(`The manual steps could not be saved for the next session: ${message(err)}.`)
  }
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

const clearBand = async ($: EngineInterface) => {
  try {
    await $.modkit.clearBandRow({ mod: MOD, id: 'steps' })
  } catch (err) {
    $.ui.log(`manual-steps: the steps card could not be taken out of the band: ${message(err)}`, { to: 'debug' })
  }
}

// A new card: the side pane when a pane opened unasked fits (Claude Code places one from 144
// columns), else the band. A pane that does not fit is closed rather than left waiting, so it can
// never appear later beside the same card in the band.
const placeNew = async ($: EngineInterface, card: StepsCard): Promise<string | undefined> => {
  const opened = await $.ui.open({ id: PANE, title: PANE_TITLE }).catch(() => ({ isPlaced: false as const, reason: 'no pane' }))
  if (opened.isPlaced) {
    await $.state.set(placeRef, 'pane')
    await clearBand($)
    return undefined
  }
  await $.ui.close({ id: PANE }).catch(() => undefined)
  await $.state.set(placeRef, 'band')
  return publishBand($, card)
}

// Takes the card away: out of the band and the pane.
const hide = async ($: EngineInterface) => {
  const place = (await $.state.get(placeRef)).value ?? null
  await $.state.set(placeRef, null)
  await clearBand($)
  if (place === 'pane') await $.ui.close({ id: PANE }).catch(() => undefined)
}

// After the card changed: the pane redraws itself from $.state; the band is published again.
const refresh = async ($: EngineInterface) => {
  const card = (await $.state.get(cardRef)).value ?? null
  if (!card || nextStep(card) === undefined) return hide($)
  if ((await $.state.get(placeRef)).value !== 'band') return
  const failed = await publishBand($, card)
  if (failed) $.ui.toast(`The steps card could not be updated: ${failed}.`)
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
    await change($, card => (card && card.steps[n]?.isSent ? { card: sent(card, n, false), out: undefined } : { card, out: undefined }))
    await refresh($)
    $.ui.toast(`Could not tell Claude step ${n + 1} is done: ${message(err)}. Press Done again.`)
  }
}

const pressCopy = async ($: EngineInterface, surface: string | undefined) => {
  const card = (await $.state.get(cardRef)).value ?? null
  const i = card ? nextStep(card) : undefined
  const value = card && i !== undefined ? card.steps[i]?.value : undefined
  if (i === undefined || !value) return
  try {
    const r = await $.ui.copy({ text: value, surface: surface as never })
    $.ui.toast(r.isCopied ? `Copied the value for step ${i + 1}.` : `Could not copy the value for step ${i + 1} (${r.reason}).`)
  } catch (err) {
    $.ui.toast(`Could not copy the value for step ${i + 1} (${message(err)}).`)
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
    // and pinned them again (the context note below asks for that).
    try {
      const kept = (await $.store.get(await projectKey($))) as StepsCard | undefined
      if (kept && Array.isArray(kept.steps) && nextStep(kept) !== undefined) {
        await $.state.set(cardRef, { ...kept, isCarried: true })
        await $.state.set(placeRef, null)
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

  on('tool.call', { tool: TOOL }, async ($, e) => {
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
    const input = e as unknown as { step?: unknown; checked?: unknown }
    const out = await change($, card => {
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
    await pressCopy($, e.surface)
    return { element: e.element }
  })

  on('command.run', { command: 'steps' }, async $ => {
    const card = (await $.state.get(cardRef)).value ?? null
    if (!card || nextStep(card) === undefined) return { text: 'No manual steps are pinned for this project.' }
    // Asked, so the pane is placed at any width.
    const opened = await $.ui.open({ id: PANE, title: PANE_TITLE }).catch(() => ({ isPlaced: false as const, reason: 'no pane' }))
    if (opened.isPlaced) {
      await $.state.set(placeRef, 'pane')
      await clearBand($)
      return { text: 'The steps card is open.' }
    }
    await $.ui.close({ id: PANE }).catch(() => undefined)
    await $.state.set(placeRef, 'band')
    const failed = await publishBand($, card)
    return { text: failed ? `The steps card could not be shown: ${failed}.` : 'The steps card is in the band above the prompt.' }
  })

  // Dan closing the pane does not finish the steps: the card stays pinned, in the band.
  on('ui.close', { id: PANE }, async ($, e, next) => {
    const r = await next(e)
    if (e.origin.kind !== 'person') return r
    const card = (await $.state.get(cardRef)).value ?? null
    if (card && !card.isCarried && nextStep(card) !== undefined) {
      await $.state.set(placeRef, 'band')
      const failed = await publishBand($, card)
      if (failed) $.ui.toast(`The steps card could not be moved to the band: ${failed}.`)
    } else await $.state.set(placeRef, null)
    return r
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const card = (await read($, cardRef)) ?? null
    if (!card) return <Text dimColor>No manual steps are pinned for this project.</Text>
    const lines = cardLines(card)
    const part = (p: CardPart, i: number) => {
      const drawn =
        'button' in p ? (
          <Button key={p.button} label={p.label} onPress={press => (p.button === 'done' ? pressDone($) : pressCopy($, press.surface))} />
        ) : (
          <Text key={String(i)} color={p.color} bold={p.bold} dimColor={p.dim} strikethrough={p.strikethrough} wrap="truncate-end">
            {p.text}
          </Text>
        )
      return 'indent' in p && p.indent ? (
        <Box key={`indent:${i}`} paddingLeft={p.indent}>
          {drawn}
        </Box>
      ) : (
        drawn
      )
    }
    // The amber rule down the card's left edge, one mark per line, as mod-kit draws it in the band.
    return (
      <Box flexDirection="row">
        <Box key="rule" flexDirection="column">
          {lines.map((_, n) => (
            <Text key={String(n)} color={AMBER}>
              {'│'}
            </Text>
          ))}
        </Box>
        <Box flexDirection="column" paddingLeft={1} flexGrow={1}>
          {lines.map((l, n) => (
            <Box key={String(n)} flexDirection="row">
              {l.map(part)}
            </Box>
          ))}
        </Box>
      </Box>
    )
  })
}
