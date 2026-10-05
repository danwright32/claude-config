import type { EngineInterface, Register } from 'claude-code'
import type { AutoSessionNameRecord as Rec } from '../types/index.d.ts'
import { cleanName, hasExchange, namePrompt, renameOutcome } from './name.ts'

// Auto session name (claude-config#635), behaviour agreed with Dan on 2026-10-04: ten minutes after
// an interactive session starts (or after its first exchange, when nothing was asked by then) it is
// named once, by one Haiku call, unless it already has a name. Silent on success; a failure is one
// dim line and exactly one retry at the next idle point.
//
// Every fact lives in $.state, never in a module variable, because a hot reload of this mod fires
// session.start again in a fresh module and must neither name twice nor restart the ten minutes.

const MOD = 'auto-session-name'
const WAIT_MS = 10 * 60_000
const HAIKU_MS = 30_000
// An attempt holds a claim so a second caller (a reload's timer, a turn ending) stands down. A claim
// older than this belongs to an attempt a reload cut off, and is taken over.
const CLAIM_MS = 3 * 60_000
// While an attempt waits on /rename, which waits for the session to go idle and so can outlast the
// claim by the rest of a long turn, it renews its claim this often, well inside CLAIM_MS (#701).
const RENEW_MS = CLAIM_MS / 3
const WHO = 'Auto session name'

// An engine refusal arrives led by '<plugin>: $.noun.verb: '; the reason is what follows.
const errText = (err: unknown) => (err instanceof Error ? err.message : String(err)).replace(/^[\w-]+: \$\.[\w.]+: /, '')

// The one reader and the one writer of the record. A record about another session id (a /clear
// started a new one) reads as none. Writes are compare and set on the version, retried, so two
// hooks changing the record at once cannot lose either change (assume it runs twice).
const read = async ($: EngineInterface): Promise<{ rec: Rec | null; version: number }> => {
  const [held, id] = await Promise.all([$.state.get({ plugin: 'auto-session-name', key: 'record' }), $.session.id()])
  const rec = held.value ?? null
  return { rec: rec && rec.sessionId === id ? rec : null, version: held.version }
}

const update = async ($: EngineInterface, change: (cur: Rec | null) => Rec | undefined): Promise<Rec | null> => {
  for (let i = 0; i < 5; i++) {
    const { rec, version } = await read($)
    const next = change(rec ? { ...rec } : null)
    if (next === undefined) return rec
    const r = await $.state.set({ plugin: 'auto-session-name', key: 'record' }, next, { ifVersion: version })
    if (r.isSet) return next
  }
  throw new Error('the record kept changing underneath five writes in a row')
}

const fresh = (sessionId: string, now: number, isInteractive: boolean | null, knownTitle = ''): Rec => ({
  sessionId,
  startedAt: now,
  isInteractive,
  outcome: 'waiting',
  failures: 0,
  isDue: false,
  knownTitle,
  isRenamedByHand: false,
  pendingTitle: null,
  madeName: null,
  claim: null,
})

// A failed attempt: one dim line saying why, then either one retry at the next idle point or none.
const fail = async ($: EngineInterface, why: string, mine: (cur: Rec | null) => boolean) => {
  let owned = false
  const rec = await update($, cur => {
    // Only the attempt still holding the claim records a failure: one whose claim went stale and
    // was taken over leaves the record to the attempt that took it.
    owned = mine(cur)
    if (!cur || !owned) return undefined
    const failures = cur.failures + 1
    return { ...cur, failures, claim: null, outcome: failures >= 2 ? 'gave-up' : 'waiting' }
  })
  if (!owned) return
  // Only a recorded failure books the retry, so with no record (a /clear gave the session a new id)
  // the line promises none.
  if (rec?.outcome === 'waiting') $.ui.log(`${WHO} couldn't name this session: ${why}. It will try once more when the session is next idle.`)
  else $.ui.log(`${WHO} couldn't name this session: ${why}. It won't try again, so /rename names it.`)
}

// Work started off a hook (the ten minute timer, a turn's end) has nobody awaiting it, so a throw
// there would vanish as an unhandled rejection. The record is left waiting, so the next idle point
// does try again, and the line says so; a store that stays broken is said once, not every turn.
let toldBackground = false
const inBackground = ($: EngineInterface, work: () => Promise<unknown>) =>
  work().catch(err => {
    if (toldBackground) return
    toldBackground = true
    $.ui.log(`${WHO} couldn't name this session: ${errText(err)}. It will try again when the session is next idle.`)
  })

const haikuWhy = (r: { reason?: string; status?: number }) => {
  if (r.reason === 'aborted') return `Haiku did not answer within ${HAIKU_MS / 1000} seconds`
  if (r.reason === 'empty-reply') return "Haiku's reply was empty"
  if (r.reason === 'api-error') return `Haiku returned an error${r.status ? ` (${r.status})` : ''}`
  return `Haiku did not answer (${r.reason ?? 'no reason given'})`
}

// Each attempt's own claim id: two attempts started at the same instant (a reload's timer and the
// first one both due) must still tell their claims apart, which a time alone cannot.
let attempts = 0

const attempt = async ($: EngineInterface): Promise<void> => {
  const now = await $.clock.now()
  const id = `${now}.${++attempts}.${Math.random().toString(36).slice(2, 8)}`
  const mine = (cur: Rec | null) => cur?.claim?.id === id
  const claimed = await update($, cur => {
    if (!cur || cur.isInteractive !== true || cur.outcome !== 'waiting') return undefined
    // Due by the record's own start as well as by the timer's mark, so a write that failed at the
    // ten minute mark still leaves every later idle point able to name it, as its line promised (#701).
    if (!cur.isDue && now - cur.startedAt < WAIT_MS) return undefined
    if (cur.claim && now - cur.claim.at < CLAIM_MS) return undefined
    if (cur.isRenamedByHand || cur.knownTitle) return { ...cur, isDue: true, outcome: 'left', claim: null }
    return { ...cur, isDue: true, claim: { id, at: now } }
  })
  if (!claimed || claimed.outcome !== 'waiting' || !mine(claimed)) return
  const release = () => update($, cur => (cur && mine(cur) ? { ...cur, claim: null } : undefined))

  // A name an earlier attempt made and recorded, before a reload cut it off, is used as it is:
  // Haiku is asked at most once for a session (#635 spec item 5, #701).
  let name = claimed.madeName ?? ''
  if (!name) {
    let messages
    try {
      messages = await $.session.messages()
    } catch (err) {
      return fail($, `the conversation could not be read (${errText(err)})`, mine)
    }
    // Nothing asked and answered yet: the first exchange's end tries again, and this is no failure.
    if (!hasExchange(messages)) {
      await release()
      return
    }

    let reply: string
    try {
      const r = await $.model.complete({ model: 'haiku', prompt: namePrompt(messages), maxTokens: 60, effort: 'low', timeoutMs: HAIKU_MS })
      if (!r.isAnswered) return fail($, haikuWhy(r as { reason?: string; status?: number }), mine)
      reply = r.text
    } catch (err) {
      return fail($, `the call to Haiku was refused (${errText(err)})`, mine)
    }
    const cleaned = cleanName(reply)
    if ('refused' in cleaned) return fail($, cleaned.refused === 'empty' ? "Haiku's reply was empty" : "Haiku's reply was too long to be a name", mine)
    name = cleaned.name
  }

  // Checked again at naming time: a rename Dan made while Haiku was answering wins. The name is kept
  // on the record, so an attempt that takes over from this one uses it rather than asking again.
  const made = name
  const still = await update($, cur => {
    if (!cur || !mine(cur)) return undefined
    if (cur.isRenamedByHand || cur.knownTitle) return { ...cur, outcome: 'left', claim: null }
    // Unchanged: no write, so a busy record cannot fail a check that changes nothing.
    return cur.madeName === made ? undefined : { ...cur, madeName: made }
  })
  if (!still || still.outcome !== 'waiting' || !mine(still)) return

  // First route: the built-in /rename, queued by the engine until the session is idle. Its answer
  // is read by the shape of its success text. A refusal, or an answer that says nothing, falls back
  // to returning sessionTitle on Dan's next message, which first checks whether the name took.
  // /rename waits for the session to go idle, so when the ten minute mark fell mid turn it waits out
  // the rest of that turn, which can be long past CLAIM_MS. While this attempt is alive it keeps its
  // claim fresh, so the turn's end finds it held and starts no second attempt (#701). A reload drops
  // this timer with the attempt, and only then does the claim go stale and get taken over.
  const renew = $.clock.every(RENEW_MS, () => {
    void $.clock
      .now()
      .then(at => update($, cur => (cur && mine(cur) ? { ...cur, claim: { id, at } } : undefined)))
      .catch(err => $.ui.log(`${MOD}: could not keep the naming claim fresh (${errText(err)})`, { to: 'debug' }))
  })
  let outcome: 'set' | 'refused' | 'unknown'
  let detail = ''
  try {
    const res = await $.command.run({ command: 'rename', args: name })
    outcome = renameOutcome(res.text)
    detail = res.text ?? '(no text)'
  } catch (err) {
    outcome = 'refused'
    detail = errText(err)
  } finally {
    renew.cancel()
  }
  // Only while this attempt still holds the claim: /rename waits for the session to go idle, and a
  // newer attempt may have taken over in the meantime.
  await update($, cur => (cur && mine(cur) ? { ...cur, outcome: 'named', claim: null, pendingTitle: outcome === 'set' ? null : name } : undefined))
  $.ui.log(`${MOD}: /rename answered ${outcome} (${detail}); ${outcome === 'set' ? 'named' : 'will set sessionTitle on the next message'}`, { to: 'debug' })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    toldBackground = false
    const result = await next(e)
    const [id, now] = await Promise.all([$.session.id(), $.clock.now()])
    const rec = await update($, cur => (cur ? { ...cur, isInteractive: e.isInteractive } : fresh(id, now, e.isInteractive)))
    // Interactive sessions only: a claude -p run or an SDK host is never named.
    if (rec?.isInteractive === true && rec.outcome === 'waiting') {
      const left = Math.max(0, rec.startedAt + WAIT_MS - now)
      $.clock.after(left, () => {
        void inBackground($, () => update($, cur => (cur && !cur.isDue ? { ...cur, isDue: true } : undefined)).then(() => attempt($)))
      })
    }
    return result
  })

  // A resumed session can arrive with a name already; recorded whichever start hook runs first.
  on('classic.SessionStart', async ($, e, next) => {
    const result = await next(e)
    const title = (e.session_title ?? '').trim()
    if (title) {
      const [id, now] = await Promise.all([$.session.id(), $.clock.now()])
      await update($, cur => (cur ? { ...cur, knownTitle: title } : fresh(id, now, null, title)))
    }
    return result
  })

  // Each message Dan sends carries the session's current name: the only way a mod can read it. It
  // also delivers the fallback route's name when /rename did not confirm it took.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    const result = await next(e)
    if (e.source === 'sdk') return result
    const title = (e.session_title ?? '').trim()
    let apply: string | null = null
    await update($, cur => {
      apply = null
      if (!cur) return undefined
      const n: Rec = { ...cur, knownTitle: title }
      if (cur.pendingTitle) {
        if (!title) apply = cur.pendingTitle
        n.pendingTitle = null
      } else if (title && cur.outcome === 'waiting' && cur.claim === null) {
        n.outcome = 'left'
      }
      return n
    })
    if (apply) {
      $.ui.log(`${MOD}: named by sessionTitle on this message`, { to: 'debug' })
      return { ...result, sessionTitle: apply }
    }
    return result
  })

  // A rename Dan runs himself always wins, and stops any name this mod has waiting. This mod's own
  // $.command.run never reaches this hook (the engine skips the calling one); the origin check is
  // there in case that ever changes.
  on('command.run', { command: 'rename' }, async ($, e, next) => {
    // Only a rename that took is Dan naming the session: one refused (an empty name, a teammate
    // session) or one that threw leaves it to this mod.
    let took = false
    try {
      const result = await next(e)
      took = renameOutcome((result as { text?: string }).text) !== 'refused'
      return result
    } finally {
      const origin = e.origin as { kind: string; name?: string } | undefined
      if (took && !(origin?.kind === 'plugin' && origin.name === MOD)) {
        // Bookkeeping only: a failed write must never change what Dan's own /rename answers.
        try {
          await update($, cur => (cur ? { ...cur, isRenamedByHand: true, pendingTitle: null, outcome: cur.outcome === 'waiting' ? 'left' : cur.outcome } : undefined))
        } catch (err) {
          $.ui.log(`${MOD}: could not record Dan's /rename (${errText(err)})`, { to: 'debug' })
        }
      }
    }
  })

  // The end of a main turn is the idle point: the first exchange when the ten minutes found nothing
  // asked, and the one retry after a failure. Run off the hook, so /rename is never asked from
  // inside a hook the turn is waiting on. A subagent's turn is not the session's.
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (!e.agentId) $.clock.after(0, () => void inBackground($, () => attempt($)))
    return result
  })
}
