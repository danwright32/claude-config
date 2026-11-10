import type { EngineInterface, On } from 'claude-code'
import type { IsItLiveOwed, IsItLiveThread } from '../types/index.d.ts'
import { MOD } from './card.ts'
import { errorText } from './mod-kit/skew.ts'
import {
  DRAFT_OPTIONS,
  DRAFT_SOURCE,
  SAVE,
  SKIP,
  draftHoldOf,
  draftLetGoOf,
  draftOwedFrom,
  draftSaved,
  isSlackTool,
  owedThreads,
  saveLine,
  skipLine,
  sourceOf,
  threadKey,
  threadOfSource,
  threadsIn,
} from './threads.ts'

// The draft reply to the Slack thread a session started from (#2436; threads.ts says why). What
// this file keeps, per session in $.state: the threads, the step a merge last landed at, and each
// thread's step of its last draft or skip. register.ts calls markLanded when a merge lands and
// draftHold at its turn end, after the card's check has asked GitHub about the background merges.

const threadsRef = { plugin: 'is-it-live', key: 'threads' } as const
const stepRef = { plugin: 'is-it-live', key: 'step' } as const
const landedRef = { plugin: 'is-it-live', key: 'landed' } as const
const draftRefusedRef = { plugin: 'is-it-live', key: 'draftRefused' } as const
const promptsRef = { plugin: 'is-it-live', key: 'prompts' } as const

// #2578: whether a thread recorded now comes once the session is under way, given how many prompts
// Dan had typed before it: any merge landed, or more than `before` of them.
async function underWay($: EngineInterface, typed: number, before: number): Promise<boolean> {
  return typed > before || (await $.state.get(landedRef)).value !== undefined
}

const msg = (err: unknown) => errorText(err, MOD)

// Every function here that is handed $ is a function declaration, the one form the engine follows
// $ into past an import.

// The next step, taken once even when two hooks take one at the same moment.
async function nextStep($: EngineInterface): Promise<number> {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(stepRef)
    const n = (held.value ?? 0) + 1
    if ((await $.state.set(stepRef, n, { ifVersion: held.version })).isSet) return n
  }
  throw new Error('the step count kept changing under it')
}

// Every change to the threads goes through here, so two at once both land.
async function changeThreads($: EngineInterface, change: (ts: IsItLiveThread[]) => IsItLiveThread[]): Promise<void> {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(threadsRef)
    if ((await $.state.set(threadsRef, change(held.value ?? []), { ifVersion: held.version })).isSet) return
  }
  throw new Error('the thread list kept changing under it')
}

/** A merge of this session has landed: every thread's draft is owed from here. Two merges landing at
 * once can write their steps in either order, so the landed step only ever rises, or a draft settled
 * between them would count for the later merge too (lessons review of 25bcf07). */
export async function markLanded($: EngineInterface, related: Relation[] = []): Promise<void> {
  const n = await nextStep($)
  await relate($, related, n)
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(landedRef)
    if ((held.value ?? 0) >= n) return
    if ((await $.state.set(landedRef, n, { ifVersion: held.version })).isSet) return
  }
  throw new Error('the landed step kept changing under it')
}

/** #2578: a merge (`pr`, named as the hold names it) is for the thread pasted mid session that `key` names. */
export type Relation = { key: string; pr: string }

// A merge for a thread pasted mid session owes it a reply from step n; a later one only rises.
async function relate($: EngineInterface, related: Relation[], n: number): Promise<void> {
  if (!related.length) return
  await changeThreads($, ts =>
    ts.map(x => {
      const prs = related.filter(r => x.mid && r.key === threadKey(x)).map(r => r.pr)
      return prs.length ? { ...x, related: Math.max(x.related ?? 0, n), prs: [...new Set([...(x.prs ?? []), ...prs])] } : x
    }),
  )
}

/** #2578: the threads pasted mid session, which only a merge for them owes a reply. */
export async function pastedThreads($: EngineInterface): Promise<IsItLiveThread[]> {
  return ((await $.state.get(threadsRef)).value ?? []).filter(t => t.mid)
}

/** #2578: a card naming a thread pasted mid session as where its Slack draft goes makes its PR a merge for it. */
export async function relateCard($: EngineInterface, t: { channel: string; ts: string }, pr: string): Promise<void> {
  const key = threadKey(t)
  if (!(await pastedThreads($)).some(x => threadKey(x) === key)) return
  await relate($, [{ key, pr }], await nextStep($))
}

async function settle($: EngineInterface, t: { channel: string; ts: string }): Promise<void> {
  const step = await nextStep($)
  await changeThreads($, ts => ts.map(x => (threadKey(x) === threadKey(t) ? (({ prs: _done, ...rest }) => ({ ...rest, settled: step }))(x) : x)))
}

async function recorded($: EngineInterface, t: { channel: string; ts: string }): Promise<IsItLiveThread | undefined> {
  return ((await $.state.get(threadsRef)).value ?? []).find(x => threadKey(x) === threadKey(t))
}

// Whether a merge of this session is still in flight: a merge the helper makes in the background,
// which GitHub has not yet said merged or closed (the card's own record of it), whose task the job
// watcher still lists as running. A helper that ended without merging is no longer in flight. With
// no job list to read, or no task named, a wait still open is taken as in flight, so the draft is
// asked for after it settles rather than before the last merge.
async function inFlight($: EngineInterface, owed: IsItLiveOwed[]): Promise<boolean> {
  const waits = owed.filter(o => o.how === 'waiting')
  if (!waits.length) return false
  let running: Set<unknown>
  try {
    // The noun is called in place, as the engine requires, never held in a variable. A job watcher
    // not loaded throws here too, and is read as a list that cannot be read.
    const list: unknown = await ($ as unknown as { jobs: { list: () => Promise<unknown> } }).jobs.list()
    if (!Array.isArray(list)) throw new Error(`the job watcher answered ${list === null ? 'null' : typeof list}, not a list`)
    running = new Set(list.map(j => (j as { id?: unknown }).id))
  } catch (err) {
    $.ui.log(`is-it-live: could not read the job list, so a merge still waiting counts as in flight: ${msg(err)}`, { to: 'debug' })
    return true
  }
  return waits.some(w => w.task === undefined || running.has(w.task))
}

/**
 * The hold a turn end carries for threads owed a draft, or undefined. Held once per thread and
 * merge in a chain of turn ends, as the card's hold is, so a draft that cannot be saved never traps
 * the turn: the next end in the chain goes ahead, said.
 */
export async function draftHold($: EngineInterface, e: { stop_hook_active?: boolean }, owed: IsItLiveOwed[]): Promise<string | undefined> {
  const due = owedThreads((await $.state.get(threadsRef)).value ?? [], (await $.state.get(landedRef)).value)
  if (!due.length || (await inFlight($, owed))) return undefined
  const landed = (await $.state.get(landedRef)).value
  const keyOf = (t: IsItLiveThread) => `${threadKey(t)}@${draftOwedFrom(t, landed)}`
  const held = (await $.state.get(draftRefusedRef)).value
  const before = e.stop_hook_active && held ? held : { keys: [], told: [] }
  const fresh = due.filter(t => !before.keys.includes(keyOf(t)))
  if (!fresh.length) {
    const untold = due.filter(t => !before.told.includes(keyOf(t)))
    if (untold.length) {
      $.ui.toast(draftLetGoOf(untold))
      await $.state.set(draftRefusedRef, { keys: before.keys, told: [...before.told, ...untold.map(keyOf)] })
    }
    return undefined
  }
  await $.state.set(draftRefusedRef, { keys: [...before.keys, ...fresh.map(keyOf)], told: before.told })
  return draftHoldOf(due)
}

type AskInput = { questions?: { question?: unknown }[]; metadata?: { source?: unknown } }
type AskResult = { answers?: Record<string, unknown>; questions?: { question?: unknown }[]; afkTimeoutMs?: unknown }

export function registerDrafts(on: On): void {
  // A thread Dan links to in his own words is where the session started (mod-kit's isDans: only
  // what he types, never a notification or another plugin's prompt), when in his first prompt and
  // before any merge; one linked later is recorded as pasted mid session (#2578). His prompts are
  // counted as far as the second, so isDans is asked of no later prompt without a link.
  on('prompt.submit', async ($, e, next) => {
    const r = await next(e)
    if (r.drop !== undefined) return r
    try {
      const found = threadsIn(String(e.text ?? ''))
      const typed = (await $.state.get(promptsRef)).value ?? 0
      if (!found.length && typed >= 2) return r
      if (!(await $.modkit.isDans({ origin: e.origin }))) return r
      if (typed < 2) await $.state.set(promptsRef, typed + 1)
      if (!found.length) return r
      const mid = (await underWay($, typed, 0)) ? { mid: true as const } : {}
      const at = await $.clock.now()
      await changeThreads($, ts => [...ts, ...found.filter(t => !ts.some(x => threadKey(x) === threadKey(t))).map(t => ({ ...t, from: 'link' as const, at, ...mid }))])
    } catch (err) {
      $.ui.log(`is-it-live: could not record the Slack thread Dan linked to: ${msg(err)}`, { to: 'debug' })
    }
    return r
  })

  // Passed down first, so every guard beneath still judges the call; only one that went through counts.
  on('tool.call', async ($, e, next) => {
    const tool = String(e.tool)
    const reads = isSlackTool(tool, 'slack_read_thread')
    if (!reads && !isSlackTool(tool, 'slack_send_message_draft')) return next(e)
    const input = e as unknown as { channel_id?: unknown; message_ts?: unknown; thread_ts?: unknown }
    const done = await next(e)
    try {
      if (reads) {
        // The thread the main session reads when it has none is its starting point; a later one,
        // or one a subagent reads, is research. Read once the session is under way (after Dan's
        // second prompt, or a merge), it is recorded as pasted mid session (#2578).
        if (e.agentId !== undefined || done.deny !== undefined || done.isError === true) return done
        if (typeof input.channel_id !== 'string' || typeof input.message_ts !== 'string') return done
        const t = { channel: input.channel_id, ts: input.message_ts }
        const mid = (await underWay($, (await $.state.get(promptsRef)).value ?? 0, 1)) ? { mid: true as const } : {}
        const at = await $.clock.now()
        await changeThreads($, ts => (ts.length ? ts : [{ ...t, from: 'read', at, ...mid }]))
        return done
      }
      // A draft saved to a recorded thread, by anyone in the session, settles it.
      if (typeof input.channel_id !== 'string' || typeof input.thread_ts !== 'string' || !draftSaved(done)) return done
      const t = { channel: input.channel_id, ts: input.thread_ts }
      if (await recorded($, t)) await settle($, t)
    } catch (err) {
      $.ui.log(`is-it-live: could not record a Slack thread call: ${msg(err)}`, { to: 'debug' })
    }
    return done
  })

  // Dan's answer about a draft reply, in Claude Code's own dialog: the session writes the question
  // (the reply, shown to him), this mod words the answers, and reads his choice from the dialog's
  // own result, the one place it comes from him.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const ask = e as unknown as AskInput
    const source = ask.metadata?.source
    if (typeof source !== 'string' || !source.startsWith(`${DRAFT_SOURCE}:`)) return next(e)
    if (e.agentId !== undefined) return { deny: 'Only the main session asks Dan about a Slack draft reply. Stop and report to the main session that the reply waits on him.' }
    const named = threadOfSource(source)
    const t = named ? await recorded($, named) : undefined
    if (!t) return { deny: `No Slack thread this session started from is named by ${source}. Pass the source the turn end's hold named.` }
    const question = typeof ask.questions?.[0]?.question === 'string' && ask.questions[0].question.trim() ? ask.questions[0].question : `Save a draft reply to ${t.link ?? 'the thread'}?`
    const r = await next({ ...e, questions: [{ question, header: 'Slack draft', options: DRAFT_OPTIONS, multiSelect: false }] } as typeof e)
    if (r.deny !== undefined || r.isError) return r
    const say = (text: string) => ({ ...r, context: [...(r.context ?? []), text] })
    const out = (r.result ?? {}) as AskResult
    if (out.afkTimeoutMs !== undefined) return say('Dan did not answer: the dialog closed by itself while he was away, so nothing is recorded and the draft reply is still owed. Ask him again when he is back.')
    const shown = typeof out.questions?.[0]?.question === 'string' ? (out.questions[0].question as string) : question
    const chosen = out.answers?.[shown] ?? out.answers?.[question]
    if (chosen === SAVE) return say(saveLine(t))
    if (chosen === SKIP) {
      await settle($, t)
      return say(skipLine(t))
    }
    if (typeof chosen !== 'string' || !chosen.trim()) return say('Dan gave no answer, so nothing is recorded and the draft reply is still owed. Ask him again.')
    const parts = { still: 'the draft reply is still owed', again: `ask him again with metadata {"source": "${sourceOf(t)}"}` }
    try {
      return say(await $.modkit.typedAnswer({ guard: 'Is it live', typed: chosen, ...parts }))
    } catch (err) {
      return say(`Dan typed "${chosen}" instead of choosing, so nothing is recorded, and ${parts.still}; mod-kit could not tell him so (${msg(err)}). Tell him that in one line, answer what he said, then ${parts.again}.`)
    }
  })
}
