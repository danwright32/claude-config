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

// Add-on notes (#620) owns the resume line that can open a reply ("+ add-on: ... and carrying on."):
// what it is and how it is read. It is asked through its noun, so the two mods read one line one way
// (#701). With add-on notes not loaded a reply has no such line. A noun of $ is only spelled at its
// call site, so absence is told by the call itself: reading resumeLine off a missing noun is a
// TypeError, while add-on notes failing is anything else, said once in the debug log when `say` is
// set (never from a drawing, which writes nothing).
type AddonNotesNoun = { resumeLine: (q: { text: string }) => Promise<{ line: string; rest: string } | null> }
let toldResume = false
const resumeOf = async ($: EngineInterface, text: string, say = false): Promise<{ line: string; rest: string } | null> => {
  try {
    return (await ($ as unknown as { addonNotes: AddonNotesNoun }).addonNotes.resumeLine({ text })) ?? null
  } catch (err) {
    if (say && !(err instanceof TypeError) && !toldResume) {
      toldResume = true
      $.ui.log(`simpler: add-on notes could not read a reply's opening line, so the button goes above it: ${why(err)}`, { to: 'debug' })
    }
    return null
  }
}

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

// The weekly count is claimed on this Mac before it is shown, so of two sessions starting together
// once the week is up, only one shows it (#701): each reads the last count's time before either can
// record the new one, and the store has no compare and set. The claim is a folder, which mkdir makes
// for exactly one caller; it is let go once the count is recorded. One older than CLAIM_STALE_MS was
// left by a session that died holding it, and is taken over (two sessions taking over the same dead
// claim in the same instant could both show the count, which is the cost of that rare case).
const CLAIM_STALE_MS = 10 * 60 * 1000
type WeekClaim = { kind: 'held'; release: () => Promise<void> } | { kind: 'taken' } | { kind: 'unclaimed'; why: string }
const claimWeek = async ($: EngineInterface, now: number): Promise<WeekClaim> => {
  try {
    const home = await $.env.get('HOME')
    if (!home) return { kind: 'unclaimed', why: 'HOME is not set' }
    const dir = `${home}/.claude/state/simpler`
    const lock = `${dir}/weekly.lock`
    const run = (argv: string[]) => $.process.run(argv, { timeoutMs: 10_000 })
    const release = async () => {
      await run(['rmdir', lock]).catch(() => undefined)
    }
    await run(['mkdir', '-p', dir])
    for (let tries = 0; tries < 2; tries++) {
      const made = await run(['mkdir', lock])
      if (made.exitCode === 0) return { kind: 'held', release }
      if (!/exists/i.test(made.stderr)) return { kind: 'unclaimed', why: made.stderr.trim() || `mkdir exited ${made.exitCode}` }
      const held = await $.fs.stat(lock).catch(() => null)
      // Another session holds it and is showing the count; or it went between the two, so try again.
      if (held && now - held.mtimeMs < CLAIM_STALE_MS) return { kind: 'taken' }
      if (held) await release()
    }
    return { kind: 'taken' }
  } catch (err) {
    return { kind: 'unclaimed', why: why(err) }
  }
}

// Once a week at a session start, one dim line naming which kinds of answer needed simplifying.
// A log that cannot be read is named and the week is not closed, so the next session tries again
// rather than the count silently skipping a week (L215).
const weekly = async ($: EngineInterface) => {
  const now = await $.clock.now()
  let claim: WeekClaim | undefined
  try {
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
      claim = await claimWeek($, now)
      if (claim.kind === 'taken') return
      if (claim.kind === 'unclaimed') {
        // Shown anyway: a count shown twice costs less than a week that is never shown.
        $.ui.log(`simpler: could not claim the weekly count, so another session starting now may show it too: ${claim.why}`, { to: 'debug' })
      }
      // Read again under the claim: a session that showed it before this one got the claim has
      // recorded it by now.
      const recorded = await $.store.get(REPORTED_AT)
      if (typeof recorded !== 'number' || now - recorded < REPORT_EVERY_MS) return
      since = recorded
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
  } finally {
    if (claim?.kind === 'held') await claim.release()
  }
}

// #939: whether a click on the button reaches this mod where it is drawn, asked of mod-kit, the one
// answer every mod shares. One that cannot be asked draws the typed way, which always works: a
// drawing writes nothing, so it is not said here.
type ClickSite = { surface: string; viewport?: { isFullscreen?: boolean } }
type ModKitClickable = { clickable: (site: ClickSite) => Promise<boolean> }
const clickable = async ($: EngineInterface, e: ClickSite) => {
  try {
    // Spelled as add-on notes' noun is above, so it type checks before Claude Code has laid mod-kit's
    // contract beside this mod (the dependency is new with #939).
    return await ($ as unknown as { modkit: ModKitClickable }).modkit.clickable(e)
  } catch {
    return false
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.state.set(PROJECT, folderName(e.cwd))
    if (e.isInteractive) {
      await weekly($)
      // What the button does, typed, where a click cannot land (#939).
      await $.command.register({ name: 'simpler', description: 'Ask for the latest long answer again in 2 to 3 plain sentences' })
    }
    return next(e)
  })

  on('command.run', { command: 'simpler' }, async $ => {
    if (!(await $.state.get(OFFER)).value) return { text: 'There is no long answer to make simpler right now.' }
    // Asked once this command has returned: a prompt cannot be sent from inside command.run, which
    // holds the turn. A refused ask is a toast, as a press's is.
    try {
      $.clock.after(0, () => {
        void press($).catch(err => $.ui.toast(`Simpler could not ask for the short version: ${why(err)}`))
      })
    } catch (err) {
      return { text: `Simpler could not ask for the short version: ${why(err)}` }
    }
    return { text: 'Asking for the short version.' }
  })

  // The latest answer decides: one that earns the button replaces the last, one that does not
  // takes it away, so it is only ever on the latest reply. A subagent's turn is not a reply to Dan.
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined) return r
    const j = e.reason === 'answer' ? judge(e.answer) : null
    // Matched on the answer under its resume line, if it opens with one: add-on notes, where it sits
    // above this mod, hands on only that part of the block (#701).
    const resume = j ? await resumeOf($, e.answer, true) : null
    const offer: SimplerOffer | null = j ? { head: replyHead(resume ? resume.rest : e.answer), kind: j.kind, reason: j.reason, words: j.words } : null
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
    // Typing /simpler is pressing the button (#939), never typing past it.
    const isPress = /^\/simpler\s*$/.test(e.text.trim())
    if (byDan && !isPress && (await $.state.get(OFFER)).value) await $.state.set(OFFER, null)
    return next(e)
  })

  // Drawn at the top of the answer it is about, on the reply's first block, with the reply itself
  // drawn by whatever sits beneath this mod (next), so another mod's drawing of the same block is
  // kept rather than replaced (#701). Hooks nest by tier and load order, which no mod chooses, so the
  // reply reads the same either way when it opens with add-on notes' resume line: the dim line, the
  // button under it, then the answer. Add-on notes above this mod has drawn the line and handed on
  // the rest; beneath it, the line is handed down alone for add-on notes to draw, then the rest.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (!e.props.isFirstOfReply) return next(e)
    const { value: offer } = await $.state.get(OFFER)
    if (!offer) return next(e)
    const resume = await resumeOf($, e.props.text)
    if (!sameReply(offer.head, resume ? resume.rest : e.props.text)) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    // Where a click cannot land (Apple Terminal, the main screen) a button would do nothing, so the
    // command that does the same is drawn in its place (#939).
    const button = (await clickable($, e)) ? (
      <Button key="simpler" label="Simpler" onPress={() => press($)} />
    ) : (
      <Text key="simpler-typed">
        <Text dimColor>type: </Text>/simpler
      </Text>
    )
    if (!resume) {
      return (
        <Box flexDirection="column">
          {button}
          {await next(e)}
        </Box>
      )
    }
    return (
      <Box flexDirection="column">
        {await next({ ...e, props: { ...e.props, text: resume.line } })}
        {button}
        {await next({ ...e, props: { ...e.props, text: resume.rest } })}
      </Box>
    )
  })
}

