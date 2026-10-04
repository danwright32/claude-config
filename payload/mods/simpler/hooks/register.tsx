import type { EngineInterface, Register } from 'claude-code'
import type { SimplerOffer } from '../types/index.d.ts'
import { REPORT_EVERY_MS, judge, pressAt, pressKey, replyHead, requestText, sameReply, weeklyLine } from './simpler.ts'

// The Simpler button (claude-config#619, settled in docs/mods-design.md). After an answer over the
// length threshold or heavy in technical terms, a Simpler button sits at the top of that answer,
// drawn into Claude's reply; it goes once Dan types. Pressing it asks, as Dan, for the same answer
// in 2 to 3 plain sentences with any open decision restated and one example from his project, the
// long version left above. Each press is logged with the kind of answer it followed, and once a
// week a session start names which kinds needed simplifying, so the cause can be fixed on purpose
// rather than the answers changing by themselves.

const OFFER = { plugin: 'simpler', key: 'offer' } as const
const PROJECT = { plugin: 'simpler', key: 'project' } as const
const REPORTED_AT = 'reportedAt'
const DAY = 24 * 60 * 60 * 1000

const why = (err: unknown): string => (err instanceof Error ? err.message : String(err)).slice(0, 200)
const folderName = (path: string): string | null => path.replace(/\/+$/, '').split('/').pop() || null

const press = async ($: EngineInterface) => {
  // Read now, never the value the drawing captured, so a press after Dan typed does nothing.
  const { value: offer } = await $.state.get(OFFER)
  if (!offer) return
  // The button goes the moment it is pressed, so the press reads as taken.
  await $.state.set(OFFER, null)

  const at = await $.clock.now()
  try {
    await $.store.set(pressKey(at, Math.random().toString(36).slice(2, 8)), { at, kind: offer.kind, reason: offer.reason, words: offer.words })
  } catch (err) {
    // The request is still worth sending; the count is what is lost, so say that (L11).
    $.ui.log(`Simpler couldn't record this press, so the weekly count will miss it: ${why(err)}`)
  }

  const { value: project } = await $.state.get(PROJECT)
  let refused: string | undefined
  try {
    const r = await $.prompt.submit({ text: requestText(project ?? undefined), asUser: true })
    if (r.drop !== undefined) refused = r.drop
  } catch (err) {
    refused = why(err)
  }
  if (refused !== undefined) {
    // Nothing was asked, so the button comes back for another try, and the toast says why (L12).
    await $.state.set(OFFER, offer)
    $.ui.toast(`Simpler could not ask for the short version: ${refused}`)
  }
}

// Once a week at a session start, one dim line naming which kinds of answer needed simplifying.
// A log that cannot be read is named and the week is not closed, so the next session tries again
// rather than the count silently skipping a week (L215).
const weekly = async ($: EngineInterface) => {
  const now = await $.clock.now()
  let kinds: string[]
  let since: number
  try {
    const reportedAt = await $.store.get(REPORTED_AT)
    if (typeof reportedAt !== 'number') {
      // The first session with this mod starts the first week; there is nothing to count yet.
      await $.store.set(REPORTED_AT, now)
      return
    }
    if (now - reportedAt < REPORT_EVERY_MS) return
    since = reportedAt
    kinds = []
    for (const key of await $.store.keys()) {
      const at = pressAt(key)
      if (at === undefined || at <= since || at > now) continue
      const v = (await $.store.get(key)) as { kind?: unknown } | undefined
      kinds.push(typeof v?.kind === 'string' ? v.kind : 'unrecorded answer')
    }
  } catch (err) {
    $.ui.log(`Simpler couldn't read its press log, so this week's count is not shown: ${why(err)}`)
    return
  }
  $.ui.log(weeklyLine(kinds, Math.round((now - since) / DAY)))
  try {
    await $.store.set(REPORTED_AT, now)
  } catch (err) {
    // Shown, but not closed: the next session repeats it rather than losing a week.
    $.ui.log(`simpler: could not record that the weekly count was shown: ${why(err)}`, { to: 'debug' })
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.state.set(PROJECT, folderName(e.cwd))
    if (e.isInteractive) await weekly($)
    return next(e)
  })

  // The latest answer decides: one that earns the button replaces the last, one that does not
  // takes it away, so it is only ever on the latest reply. A subagent's turn is not a reply to Dan.
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined) return r
    const j = e.reason === 'answer' ? judge(e.answer) : null
    const offer: SimplerOffer | null = j ? { head: replyHead(e.answer), kind: j.kind, reason: j.reason, words: j.words } : null
    await $.state.set(OFFER, offer)
    return r
  })

  // Gone once Dan types: the first edit of the prompt box, or a message he sends from elsewhere.
  on('prompt.edit', async ($, e, next) => {
    if ((await $.state.get(OFFER)).value) await $.state.set(OFFER, null)
    return next(e)
  })
  on('prompt.submit', async ($, e, next) => {
    const byDan = e.origin.kind === 'composer' || e.origin.kind === 'bridge'
    if (byDan && (await $.state.get(OFFER)).value) await $.state.set(OFFER, null)
    return next(e)
  })

  // Drawn at the top of the answer it is about, on the reply's first block. The reply is drawn as
  // Markdown with its text as a prop (children leave it empty), which is the form proved clickable
  // in Dan's terminal on 2026-10-04 (#619).
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (!e.props.isFirstOfReply) return next(e)
    const { value: offer } = await $.state.get(OFFER)
    if (!offer || !sameReply(offer.head, e.props.text)) return next(e)
    const { Box, Button, Markdown } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        <Button key="simpler" label="Simpler" onPress={() => press($)} />
        <Markdown text={e.props.text} />
      </Box>
    )
  })
}

