import type { SessionSendResult } from 'claude-code'

// A message a mod sends another session, tried once more when it is refused (#688). Decided with
// Dan after the live check of #605 on 2026-10-04, where auto mode's classifier refused one. A throw
// is not tried again: it can come after the message landed, and a second copy would tell the other
// session twice (lessons review of #636). The scope modes mod and the collision guard each kept a
// copy of this until #688.
//
// It wraps the send in mod-kit's session.send hook rather than being a method on $.modkit: a
// method would send as mod-kit, and each receiver tells its own mod's messages apart by the
// sending plugin (origin), while a function cannot be handed to a method (only plain data crosses).

const MSG = (err: unknown) => String((err as Error)?.message ?? err)

/** The reason as a sentence can carry it: trimmed, no full stop of its own, never empty. */
export const tidy = (reason: string): string => reason.trim().replace(/\.$/, '') ||'no reason given'

/** One send, tried once more when refused; a throw ends it, answered as not delivered with its message. */
export const sendTwice = async (send: () => Promise<SessionSendResult>): Promise<SessionSendResult> => {
  let why = ''
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const sent = await send()
      if (sent.isDelivered) return sent
      why = sent.reason
    } catch (err) {
      why = MSG(err)
      break
    }
  }
  return { isDelivered: false, reason: tidy(why) }
}
