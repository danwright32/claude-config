import type { EngineInterface, Register } from 'claude-code'
import type { Pickers, PickersOpen, PickersOutcome } from '../types/index.d.ts'
import { asksQuiet, bandLines, echoOf, proseAnswers, refusal } from './pickers.ts'
import type { Question } from './pickers.ts'

// Picker manners (#615), agreed with Dan on 2026-10-03 and drawn in the design rounds of
// 2026-10-04 (docs/mods-design.md, "Picker manners (#615)").
//
// - Every AskUserQuestion, hook driven ones included, is answered by this mod's tool.call hook:
//   the question goes into the band above the prompt (mod-kit's question slot, which takes the band
//   alone), and the hook waits for a press there. The prompt stays free throughout.
// - One question per call (CLAUDE.md): more are refused.
// - Typed text is always a message, never an answer: it withdraws the question as "Dan is explaining
//   first", and the message follows. Numbered prose ("1. yes") is the exception the spec names: it
//   is mapped onto the question and echoed back in one line per question. A question talked past is
//   asked again once, never more.
// - "no next issue" or "just give me the list" turns next issue pickers off for the session;
//   /pickers on brings them back.

const MOD = 'picker-manners'
const openRef = { plugin: 'picker-manners', key: 'open' } as const
const quietRef = { plugin: 'picker-manners', key: 'quiet' } as const
const talkedRef = { plugin: 'picker-manners', key: 'talkedPast' } as const

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
  await $.modkit.bandRow({ mod: MOD, id: 'question', slot: 'question', lines: bandLines(open.question, open.chosen) } as never)
}

const close = async ($: EngineInterface) => {
  await $.state.set(openRef, null)
  await $.modkit.clearBandRow({ mod: MOD, id: 'question' })
}

const message = (err: unknown) => String((err as Error)?.message ?? err)

export const register: Register = on => {
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
    const talked = (await $.state.get(talkedRef)).value ?? {}
    const why = refusal(questions, {
      quiet: (await $.state.get(quietRef)).value ?? false,
      source: (e.metadata as { source?: string } | undefined)?.source,
      talkedPast: q ? (talked[q.question] ?? 0) : 0,
    })
    if (why || !q) return { deny: why ?? 'Ask one question per call: Dan answers pickers one at a time.' }
    const id = (e as unknown as { tool_use_id?: string }).tool_use_id ?? `call-${++calls}`
    // An interrupted turn withdraws the question rather than leaving it in the band.
    next.signal?.addEventListener?.('abort', () => settle(id, { kind: 'withdrawn' }))
    let outcome: PickersOutcome
    try {
      await show($, { id, question: q, chosen: [] })
      outcome = await $.pickers.wait({ id })
    } finally {
      await close($).catch(err => $.ui.log(`Picker manners could not clear the question: ${message(err)}`, { to: 'debug' }))
    }
    const answered = (answer: string) => ({ result: { questions: e.questions, answers: { [q.question]: answer } } }) as never
    if (outcome.kind === 'answer') return answered(outcome.answer)
    if (outcome.kind === 'prose') {
      for (const line of echoOf([q], outcome.answers)) $.ui.log(line)
      return answered(outcome.answers.join(', '))
    }
    if (outcome.kind === 'withdrawn') return { deny: 'The question was withdrawn: the turn was interrupted.' }
    await $.state.set(talkedRef, { ...talked, [q.question]: (talked[q.question] ?? 0) + 1 })
    return {
      deny: 'Dan did not pick an answer: he is sending a message instead, which follows. Answer his message first. If this question is still unanswered after that, ask it again once; never more than once.',
    }
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

  // What Dan types. Only his own typing counts: a plugin's or a peer's prompt is no answer.
  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind !== 'composer') return next(e)
    if (asksQuiet(e.text) && !(await $.state.get(quietRef)).value) {
      await $.state.set(quietRef, true)
      $.ui.log('Next issue pickers are off for this session; /pickers on brings them back.')
    }
    const open = (await $.state.get(openRef)).value
    if (open) {
      const answers = proseAnswers(e.text, [open.question])
      settle(open.id, answers ? { kind: 'prose', answers } : { kind: 'message' })
    }
    return next(e)
  })

  on('command.run', { command: 'pickers' }, async ($, e) => {
    if (e.args.trim().toLowerCase() !== 'on') return { text: '/pickers on brings next issue pickers back; nothing else is understood.' }
    await $.state.set(quietRef, false)
    return { text: 'Next issue pickers are back on.' }
  })
}
