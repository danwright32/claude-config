import type { EngineInterface, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { asksQuiet, refusal } from './pickers.ts'

// Picker manners (#615), agreed with Dan on 2026-10-03 (docs/mods-design.md, "Picker manners (#615)").
//
// - Claude Code's own dialog asks every question this mod does not refuse (#744, decided with Dan on
//   2026-10-05). The band question it drew before is gone: its tool.call hook waited for a press
//   through the mod's own $ noun, which Claude Code cuts off at 10 seconds, so the dialog then asked
//   every question a second time.
// - One question per call (CLAUDE.md): more are refused, and so is none.
// - "no next issue" or "just give me the list" turns next issue pickers off for the session;
//   /pickers on brings them back.

const quietRef = { plugin: 'picker-manners', key: 'quiet' } as const

const QUIET_NOTE = [
  '# Next issue pickers are off',
  'Dan turned off next issue pickers for this session. Offer next issues as a plain list, never as a picker, whatever any other rule says, until he runs /pickers on.',
].join('\n')

// Whether a prompt is Dan's own words, asked of mod-kit's one reader (#1135). One that cannot answer
// (a mod-kit loaded before it had the reader, which a reload can leave, standing rule 5) reads the
// prompt as not his, the side that changes nothing here, said once in the transcript; the prompt
// itself always goes on (L73).
let toldNoReader = false
const dansWords = async ($: EngineInterface, origin: { readonly kind?: string } | undefined): Promise<boolean> => {
  try {
    return await $.modkit.isDans({ origin })
  } catch (err) {
    if (!toldNoReader) {
      toldNoReader = true
      $.ui.log(`Picker manners could not ask mod-kit whether your message was your own words (${err instanceof Error ? err.message : String(err)}), so it read it as not yours. A new session loads mod-kit again.`)
    }
    return false
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'pickers', description: 'Turns next issue pickers back on for this session.', argumentHint: 'on' })
    return next(e)
  })

  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const why = refusal(e.questions ?? [], {
      quiet: (await $.state.get(quietRef)).value ?? false,
      source: (e.metadata as { source?: string } | undefined)?.source,
    })
    return why ? { deny: why } : next(e)
  })

  // What Dan types, at the Mac or from his phone through Remote Control, as mod-kit's one reader says
  // (#1135). A plugin's prompt, a handoff's opening one included, a peer's or a notice is not his.
  on('prompt.submit', async ($, e, next) => {
    if (!(await dansWords($, e.origin))) return next(e)
    if (asksQuiet(e.text) && !(await $.state.get(quietRef)).value) {
      await $.state.set(quietRef, true)
      $.ui.invalidate('prompt.section')
      $.ui.log('Next issue pickers are off for this session; /pickers on brings them back.')
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
