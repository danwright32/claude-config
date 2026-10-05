import type { EngineInterface, Register } from 'claude-code'
import type { Pickers, PickersOpen, PickersOutcome } from '../types/index.d.ts'
import { askOf, asksQuiet, bandEverywhere, echoOf, onAbort, passedOver, passesOver, proseAnswers, recordPass, refusal, refusalFor } from './pickers.ts'
import type { Passed, Question } from './pickers.ts'

// Picker manners (#615), agreed with Dan on 2026-10-03 and drawn in the design rounds of
// 2026-10-04 (docs/mods-design.md, "Picker manners (#615)").
//
// - The band question is off by default (#744): Claude Code's own dialog asks every question that
//   passes the refusals below. Turned on (userConfig bandQuestions), every AskUserQuestion, hook
//   driven ones included, is answered by this mod's tool.call hook: the question goes into the band
//   above the prompt through mod-kit's question builder, which draws one question at a time, and
//   the hook waits for a press there. The prompt stays free. Where no band can be drawn (a claude
//   -p or SDK run, Dan's phone or VS Code attached) Claude Code's own dialog asks instead, since it
//   is drawn on every surface (#703).
// - One question per call (CLAUDE.md): more are refused.
// - Typed text from Dan, at the Mac or from his phone, is always a message, never an answer: it
//   withdraws the question as "Dan is explaining first", and the message follows. Numbered prose
//   ("1. yes") is the exception the spec names: it is mapped onto the question and echoed back in
//   one line per question. A question of Claude's talked past or dismissed is asked again once,
//   never more; another mod's question ($.ui.ask) is its own business and never limited.
// - "no next issue" or "just give me the list" turns next issue pickers off for the session;
//   /pickers on brings them back.

const MOD = 'picker-manners'
const ID = 'question'
const openRef = { plugin: 'picker-manners', key: 'open' } as const
const quietRef = { plugin: 'picker-manners', key: 'quiet' } as const
const passedRef = { plugin: 'picker-manners', key: 'passed' } as const

// The waits in flight, by tool call. An outcome that arrives before its wait starts is kept until
// it does, so a press in the moment between the band drawing and the wait cannot be lost.
const waiters = new Map<string, (o: PickersOutcome) => void>()
const early = new Map<string, PickersOutcome>()
const settle = (id: string, o: PickersOutcome) => {
  const w = waiters.get(id)
  if (w) {
    waiters.delete(id)
    w(o)
  } else early.set(id, o)
}
let calls = 0

const show = async ($: EngineInterface, open: PickersOpen) => {
  await $.state.set(openRef, open)
  await $.modkit.question(askOf(open.question, open.chosen))
}

const close = async ($: EngineInterface) => {
  await $.state.set(openRef, null)
  await $.modkit.clearBandRow({ mod: MOD, id: ID })
}

const message = (err: unknown) => String((err as Error)?.message ?? err)

// Whether Dan can see this mod's question: mod-kit draws one question at a time, so another mod's
// may be in view while this one waits. One that cannot be asked is taken as in view, the usual case.
const inView = async ($: EngineInterface): Promise<boolean> => {
  try {
    const shown = await $.modkit.shownQuestion()
    return shown?.mod === MOD && shown.id === ID
  } catch (err) {
    $.ui.log(`Picker manners could not ask which question is in view, so it counts this one as seen: ${message(err)}`, { to: 'debug' })
    return true
  }
}

// The passes recorded this session; a value of another shape (an earlier build's) counts as none.
const passesOf = async ($: EngineInterface): Promise<Passed[]> => {
  const v = (await $.state.get(passedRef)).value
  return Array.isArray(v) ? v : []
}

const QUIET_NOTE = [
  '# Next issue pickers are off',
  'Dan turned off next issue pickers for this session. Offer next issues as a plain list, never as a picker, whatever any other rule says, until he runs /pickers on.',
].join('\n')

export const register: Register = (on, options) => {
  // Off by default (#744, decided with Dan on 2026-10-05): the wait for a press below ran on the
  // hook's 10 second budget in a live session, so Claude Code's own dialog then asked the question
  // again. Off, every question that passes the refusals goes to that dialog, which asks once.
  const bandQuestions = options?.bandQuestions === true

  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const pickers: Pickers = {
      wait: ({ id }) =>
        new Promise<PickersOutcome>(resolve => {
          const got = early.get(id)
          if (got) {
            early.delete(id)
            resolve(got)
          } else waiters.set(id, resolve)
        }),
    }
    return { ...built, pickers }
  })

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'pickers', description: 'Turns next issue pickers back on for this session.', argumentHint: 'on' })
    return next(e)
  })

  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const questions = (e.questions ?? []) as unknown as Question[]
    const q = questions[0]
    // Claude's own question: the engine raised it. Another mod's $.ui.ask names that mod (#703).
    const isClaudes = next.origin.plugin === 'engine'
    const passed = await passesOf($)
    const why = refusal(questions, {
      quiet: (await $.state.get(quietRef)).value ?? false,
      source: (e.metadata as { source?: string } | undefined)?.source,
      talkedPast: q && isClaudes ? passedOver(q, passed) : 0,
    })
    if (why || !q) return { deny: why ?? 'Ask one question per call: Dan answers pickers one at a time.' }
    if (!bandQuestions) return next(e)
    const surfaces = await $.session.surfaces().catch((err: unknown) => {
      $.ui.log(`Picker manners could not read where the session draws, so Claude Code's own dialog asks: ${message(err)}`, { to: 'debug' })
      return null
    })
    if (!bandEverywhere(surfaces)) return next(e)
    // Answered here from now on and never passed down, so the guards beneath (the secret guard) are
    // asked through mod-kit's screen before the question is drawn or kept (#707).
    const refused = await $.modkit.screen(e)
    if (refused) return refused
    const id = (e as unknown as { tool_use_id?: string }).tool_use_id ?? `call-${++calls}`
    // An interrupted turn withdraws the question rather than leaving it in the band.
    onAbort(next.signal, () => settle(id, { kind: 'withdrawn' }))
    let outcome: PickersOutcome
    let seen = true
    try {
      await show($, { id, question: q, chosen: [] })
      outcome = await $.pickers.wait({ id })
      // Asked before the question leaves the band, so it says whether it was in view as it ended.
      if (passesOver(outcome)) seen = await inView($)
    } finally {
      await close($).catch(err => $.ui.log(`Picker manners could not clear the question: ${message(err)}`, { to: 'debug' }))
    }
    const answered = (answer: string) => ({ result: { questions: e.questions, answers: { [q.question]: answer } } }) as never
    if (outcome.kind === 'answer') return answered(outcome.answer)
    if (outcome.kind === 'prose') {
      for (const line of echoOf([q], outcome.answers)) $.ui.log(line)
      return answered(outcome.answers.join(', '))
    }
    let passes = 0
    if (isClaudes && seen && passesOver(outcome)) {
      // Never thrown: a hook that throws is skipped, and Claude Code's own picker would then ask the
      // question Dan just passed over. Unrecorded, it may be asked again, as the debug log says.
      try {
        const now = recordPass(q, await passesOf($))
        await $.state.set(passedRef, now)
        passes = passedOver(q, now)
      } catch (err) {
        $.ui.log(`Picker manners could not record that Dan passed over this question, so it may be asked again: ${message(err)}`, { to: 'debug' })
      }
    }
    return { deny: refusalFor(outcome, passes) ?? 'The question ended without an answer.' }
  })

  on('ui.press', { plugin: 'mod-kit' }, async ($, e, next) => {
    if (!e.element.startsWith(`${MOD}:`)) return next(e)
    const open = (await $.state.get(openRef)).value
    if (!open) return { element: e.element }
    const button = e.element.slice(MOD.length + 1)
    if (button === 'submit') {
      if (!open.chosen.length) {
        $.ui.toast('Nothing is chosen yet.')
        return { element: e.element }
      }
      settle(open.id, { kind: 'answer', answer: open.question.options.map(o => o.label).filter(l => open.chosen.includes(l)).join(', ') })
      return { element: e.element }
    }
    const option = open.question.options[Number(button.replace(/^opt/, '')) - 1]
    if (!option) return { element: e.element }
    if (!open.question.multiSelect) {
      settle(open.id, { kind: 'answer', answer: option.label })
      return { element: e.element }
    }
    const chosen = open.chosen.includes(option.label) ? open.chosen.filter(l => l !== option.label) : [...open.chosen, option.label]
    await show($, { ...open, chosen })
    return { element: e.element }
  })

  // What Dan types, at the Mac or from his phone through Remote Control (#703: the band is not drawn
  // on the phone, so his messages there are the only way he can answer or dismiss). A plugin's or a
  // peer's prompt is no answer.
  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind !== 'composer' && e.origin.kind !== 'bridge') return next(e)
    if (asksQuiet(e.text) && !(await $.state.get(quietRef)).value) {
      await $.state.set(quietRef, true)
      $.ui.invalidate('prompt.section')
      $.ui.log('Next issue pickers are off for this session; /pickers on brings them back.')
    }
    const open = (await $.state.get(openRef)).value
    if (open) {
      // Numbered prose answers only the question Dan can see: with another mod's in view, "1. yes"
      // is meant for that one.
      const answers = proseAnswers(e.text, [open.question])
      settle(open.id, answers && (await inView($)) ? { kind: 'prose', answers } : { kind: 'message' })
    }
    return next(e)
  })

  // Claude reads this for as long as next issue pickers are off, so an offer it would make from
  // CLAUDE.md's issue loop rule, which carries no next-issue tag for the refusal to see, is a plain
  // list too (spec #615 point 4: this overrides the loop rule for that session only). The section is
  // assembled afresh for every request, so a compaction keeps it.
  on('prompt.section', { name: 'memory' }, async ($, e, next) => {
    const r = await next(e)
    if (!(await $.state.get(quietRef)).value) return r
    return { text: r.text ? `${r.text}\n\n${QUIET_NOTE}` : QUIET_NOTE }
  })

  on('command.run', { command: 'pickers' }, async ($, e) => {
    if (e.args.trim().toLowerCase() !== 'on') return { text: '/pickers on brings next issue pickers back; nothing else is understood.' }
    await $.state.set(quietRef, false)
    $.ui.invalidate('prompt.section')
    return { text: 'Next issue pickers are back on.' }
  })
}
