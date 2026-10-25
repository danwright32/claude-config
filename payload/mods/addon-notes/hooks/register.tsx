import type { EngineInterface, Register } from 'claude-code'
import type { AddonNotes } from '../types/index.d.ts'
import { ADD_ON_CONTEXT, AMENDMENT_CONTEXT, TOAST, isAddOnNote, isAmendment, resumeLine } from './classify.ts'

// Add-on notes (claude-config#620).
//
// 1. A message starting with + typed while Claude works is an add-on: Claude Code already delivers
//    it into the running turn without stopping it, so the mod only tells the model how to treat it
//    (context beside the prompt) and acknowledges it with a toast once it has entered.
// 2. After Dan interrupts a turn (Esc), a short reply that adds scope ("also...", "and...",
//    "include...", "sorry keep going") tells the model to resume the interrupted step with the
//    addition, keep the agreed scope, and open with the agreed one line resume note, which this mod
//    draws dim. Anything else after an interrupt is left exactly as typed.
//
// The words Dan typed always reach the model unchanged; only context is added.

// Whether the main loop's last turn ended because Dan interrupted it, not yet answered by a message
// of his. Once held in the module, where a hot reload forgot it and his reply was read as a plain
// message; in $.state since #1703, which the engine holds for the session across a reload, as every
// session fact of a mod now is. One that cannot be read is read as no interrupt, the side that
// changes nothing (the reply goes on exactly as typed), and one that cannot be written is logged.
const interruptedRef = { plugin: 'addon-notes', key: 'interrupted' } as const
// This module holds the latest it recorded too, which decides while it holds one, so a record that
// cannot be written (logged) neither loses an interrupt nor leaves an answered one standing here
// (push review of PR for #1703); a fresh module after a reload reads $.state alone.
let interruptedHere: boolean | undefined
const wasInterrupted = async ($: EngineInterface): Promise<boolean> => {
  if (interruptedHere !== undefined) return interruptedHere
  try {
    return (await $.state.get(interruptedRef)).value === true
  } catch (err) {
    $.ui.log(`addon-notes: could not read whether the last turn was interrupted, so the reply is taken as typed: ${err instanceof Error ? err.message : String(err)}`, { to: 'debug' })
    return false
  }
}
const setInterrupted = async ($: EngineInterface, value: boolean) => {
  interruptedHere = value
  try {
    await $.state.set(interruptedRef, value)
  } catch (err) {
    $.ui.log(`addon-notes: could not record whether the last turn was interrupted: ${err instanceof Error ? err.message : String(err)}`, { to: 'debug' })
  }
}

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
      $.ui.log(`Add-on notes could not ask mod-kit whether your message was your own words (${err instanceof Error ? err.message : String(err)}), so it read it as not yours. A new session loads mod-kit again.`)
    }
    return false
  }
}

export const register: Register = on => {
  // The resume line is read for other mods here, by the rule this mod draws it by, so a mod that
  // redraws the same reply block (Simpler, #701) reads it one way with this one.
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const addonNotes: AddonNotes = {
      resumeLine: async ({ text }) => {
        if (typeof text !== 'string') throw new Error(`addon-notes: text must be the block's text, not ${JSON.stringify(text)}`)
        return resumeLine(text) ?? null
      },
    }
    return { ...built, addonNotes }
  })

  // A reload's fresh module holds nothing of its own (#1703): the interrupt is read from $.state.
  on('session.start', async ($, e, next) => {
    interruptedHere = undefined
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    // A subagent's turn is not the session's (its agentId is set).
    if (e.agentId === undefined) await setInterrupted($, e.reason === 'aborted')
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    // /clear starts a new conversation in the same process: an interrupt before it means nothing after.
    await setInterrupted($, false)
    return next(e)
  })

  // Only Dan's own messages, as mod-kit's one reader says (#1135): typed at the terminal, or sent
  // from the phone through Remote Control. A peer session, a background task or a plugin, a
  // handoff's opening prompt included, is never an add-on.
  on('prompt.submit', async ($, e, next) => {
    if (!(await dansWords($, e.origin))) return next(e)
    const midTurn = e.turnId !== undefined
    // An interrupt is answered by Dan's next message, whatever it says; one typed into a running
    // turn is not that message (the interrupted turn is over by then, so a running turn is a newer one).
    const afterInterrupt = !midTurn && (await wasInterrupted($))
    if (!midTurn && afterInterrupt) await setInterrupted($, false)

    if (afterInterrupt && isAmendment(e.text)) {
      return next({ ...e, context: [...(e.context ?? []), AMENDMENT_CONTEXT] })
    }
    if (midTurn && isAddOnNote(e.text)) {
      const r = await next({ ...e, context: [...(e.context ?? []), ADD_ON_CONTEXT] })
      // Acknowledged only once the note entered; a refusal beneath is shown by Claude Code itself.
      if (r.drop === undefined) $.ui.toast(TOAST)
      return r
    }
    return next(e)
  })

  // The resume line opening a reply, drawn as one dim grey line, the rest left to Claude Code.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (!e.props.isFirstOfReply) return next(e)
    const found = resumeLine(e.props.text)
    if (!found) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const line = <Text dimColor>{found.line}</Text>
    if (!found.rest) return line
    return (
      <Box flexDirection="column">
        {line}
        {await next({ ...e, props: { ...e.props, text: found.rest } })}
      </Box>
    )
  })
}
