// A scope mode command typed while a turn runs (#3136). The commands are registered `immediate`, so
// Claude Code runs one at once, but it prints the command's answer only when the turn ends (as late
// as the next morning, seen on 2026-11-11) and drops the notes the command leaves the model (its
// `context`): measured on Claude Code 2.1.325/326, whose mid turn run prints the command row and its
// output and nothing else. So, mid turn, this mod holds the notes itself and hands them to the model
// at the next thing it reads: the main conversation's next tool result, or the next prompt.
//
// The session /sleep runs in is a worker too, and nothing started its night: a command's notes start
// no turn even when idle (an idle /sleep sat until some other prompt arrived, 2026-10-19 and 10-26),
// and a turn whose Stop came before the sleep record was in place ended with no driver to keep it
// going (2026-11-16). So /sleep owes its own session a start: at once when no turn runs, else when
// the turn ends, unless the overnight driver decided one of its Stops for that night first.

export type MidTurn = {
  /** Whether a turn of the main conversation is under way: from turn.start to turn.complete. */
  live: boolean
  /** Notes for the model from commands run during a turn, not yet handed over. */
  notes: string[]
  /** The night (sleep record generation) whose start this session is owed once the turn ends. */
  owed?: string
}

export const midTurn = (): MidTurn => ({ live: false, notes: [] })

/** Back to no turn, nothing held: a session's start, as a reload's fresh module has it. */
export const resetMidTurn = (m: MidTurn) => {
  m.live = false
  m.notes = []
  m.owed = undefined
}

/**
 * A command's answer as Claude Code should get it: idle, unchanged, since its notes are recorded
 * then; mid turn, without them, held here instead so they are neither lost nor read twice.
 */
export const answerMidTurn = <R extends { context?: readonly string[] }>(m: MidTurn, r: R): R => {
  if (!m.live || !r.context?.length) return r
  m.notes.push(...r.context)
  const { context: _held, ...rest } = r
  return rest as R
}

/** The held notes, handed over once. */
export const takeNotes = (m: MidTurn): string[] => m.notes.splice(0)

/** /sleep began a night this session works: 'now' with no turn running, else owed at the turn's end. */
export const startNight = (m: MidTurn, generation: string): 'now' | 'owed' => {
  if (!m.live) return 'now'
  m.owed = generation
  return 'owed'
}

/**
 * The overnight driver decided a Stop of this session's night (kept it working or let it go): the
 * turn was the driver's, so no start is owed. It drives only the night now on record, the one /sleep
 * just placed.
 */
export const drivenStop = (m: MidTurn) => {
  m.owed = undefined
}

/** The main conversation's turn ended: the night whose start is owed now, taken once. */
export const turnEnded = (m: MidTurn): string | undefined => {
  m.live = false
  const owed = m.owed
  m.owed = undefined
  return owed
}

/**
 * What the toast says of a command answered mid turn, whose printed answer waits for the turn's end:
 * its first sentence, so Dan sees at once that it ran and what it did.
 */
export const midTurnToast = (text: string) => {
  const first = /^.*?[.!?](?=\s|$)/.exec(text.trim())?.[0] ?? text.trim()
  return `${first} Its full answer shows when this turn ends.`
}
