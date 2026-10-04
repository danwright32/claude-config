import type { PromptOrigin, Register } from 'claude-code'
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

// Only Dan's own messages: typed at the terminal, or sent from the phone through Remote Control.
// A peer session, a background task or a plugin is never an add-on.
const fromDan = (origin: PromptOrigin | undefined): boolean => origin?.kind === 'composer' || origin?.kind === 'bridge'

// Whether the main loop's last turn ended because Dan interrupted it, not yet answered by a message
// of his. Held for this session's process only: a hot reload of the mod forgets it, which costs at
// most one reply read as a plain message, the behaviour without the mod.
let interrupted = false

export const register: Register = on => {
  on('turn.complete', async ($, e, next) => {
    // A subagent's turn is not the session's (its agentId is set).
    if (e.agentId === undefined) interrupted = e.reason === 'aborted'
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    // /clear starts a new conversation in the same process: an interrupt before it means nothing after.
    interrupted = false
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (!fromDan(e.origin)) return next(e)
    const midTurn = e.turnId !== undefined
    // An interrupt is answered by Dan's next message, whatever it says; one typed into a running
    // turn is not that message (the interrupted turn is over by then, so a running turn is a newer one).
    const afterInterrupt = !midTurn && interrupted
    if (!midTurn) interrupted = false

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
