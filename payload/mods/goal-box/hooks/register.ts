import type { EngineInterface, Register } from 'claude-code'
import type { ModKitGoal } from '../.claude-plugin/types/mod-kit/index.d.ts'
import type { GoalBoxShown } from '../types/index.d.ts'
import { DESCRIPTION, MOD, NAME, SCHEMA, TOOL, askText, boxText, cardOf, decide, linkedIn, mergeHolds, readInput, type Holds, type Linked, type MergeFacts } from './box.ts'
import { askAnyAccount, type GhRun } from './mod-kit/ghaccounts.ts'
import { errorText } from './mod-kit/skew.ts'

// The Goal accomplished box (claude-config#1563). Two ways a session's work ends, one box for both:
//
// 1. A /goal met. Claude Code's own check of the goal runs as a Stop hook, and writes its verdict
//    into the transcript as a goal_status record. Measured on 2.1.310 on 2026-10-24 with a probe mod
//    in a headless session: a verdict of not met is the Stop chain's own block, and the record of a
//    verdict of met lands AFTER the Stop chain has returned and before turn.complete. So
//    turn.complete finds it, read through mod-kit's one goal reader, and sends the session one
//    prompt to show the box, once per met goal. No classic hook is used: Claude Code's built-in
//    security default sends every classic event past the tier mods load in (#875, #876).
// 2. No /goal: the session's own judgement that the work Dan asked for is finished. A judgement can
//    only be the model's, so it calls this mod's tool (a rule in a prompt alone is a hope, L27), and
//    the tool enforces what can be read: no box while an agent the session started is running, a
//    merge or a deploy is not confirmed (is it live's own record), or a pull request the session
//    touched is still open (GitHub, asked as each account), and at most one box per request (a
//    second needs a new message from Dan, mod-kit's one reader of his own words).
//
// The box is the tool's result: drawn as mod-kit's card, its heading in the success colour, and as
// text the shape of the SESSION REFLECTION box wherever the card is not drawn.

const interactiveRef = { plugin: 'goal-box', key: 'interactive' } as const
const promptsRef = { plugin: 'goal-box', key: 'prompts' } as const
const shownRef = { plugin: 'goal-box', key: 'shown' } as const
const askedRef = { plugin: 'goal-box', key: 'asked' } as const
// is it live's own record of this session's merges, read here; it may not be loaded at all.
const owedRef = { plugin: 'is-it-live', key: 'owed' } as const
const verdictsRef = { plugin: 'is-it-live', key: 'verdicts' } as const

const msg = (err: unknown) => (err instanceof Error ? err.message : String(err))
const debug = ($: EngineInterface, text: string) => void $.ui.log(`${MOD}: ${text}`, { to: 'debug' })

/** This session's transcript, from its own record in the session registry, or why it is not known. */
const transcriptNow = async ($: EngineInterface): Promise<{ path: string } | { why: string }> => {
  try {
    const list = await $.sessions.list()
    const me = [...list.open, ...list.closed].find(r => r.sessionId === list.selfId)
    if (me?.transcriptPath) return { path: me.transcriptPath }
    return { why: me?.transcriptUnread ?? "this session's transcript was not found in the session registry" }
  } catch (err) {
    return { why: errorText(err, MOD) }
  }
}

/** The goal mod-kit reads in this session's transcript; never throws, so a failure holds the box. */
const goalNow = async ($: EngineInterface): Promise<ModKitGoal> => {
  const t = await transcriptNow($)
  if ('why' in t) return { state: 'unreadable', why: t.why }
  const transcript = t.path
  try {
    return await $.modkit.goal({ transcript })
  } catch (err) {
    return { state: 'unreadable', why: errorText(err, MOD) }
  }
}

// Every pull request record in the transcript, one line per pull request: the time each was written
// blanked so the same pull request's records are one line, then sorted unique. grep exits 1 for none.
const PR_LINKS = 'set -o pipefail; grep -F -e "$1" -- "$2" | sed -E \'s/"timestamp":"[^"]*"/"timestamp":""/\' | sort -u'
const PR_MARK = '"type":"pr-link"'

const linkedNow = async ($: EngineInterface): Promise<Linked[] | { why: string }> => {
  const t = await transcriptNow($)
  if ('why' in t) return t
  const transcript = t.path
  try {
    const r = await $.process.run(['bash', '-c', PR_LINKS, 'prlinks', PR_MARK, transcript], { timeoutMs: 10_000 })
    if (r.exitCode === 1 && !r.stderr.trim()) return []
    if (r.exitCode !== 0) return { why: r.stderr.trim() || `grep exited ${r.exitCode}` }
    return linkedIn(r.stdout)
  } catch (err) {
    return { why: msg(err) }
  }
}

const ghLine = (r: GhRun) => r.stderr.trim().split('\n')[0] || `gh exited ${r.exitCode}`
const notFound = (r: GhRun) => /Could not resolve to a Repository/i.test(r.stderr)

/** The pull requests this session touched that GitHub says are still open, or why it could not say. */
const openHolds = async ($: EngineInterface): Promise<Holds> => {
  const linked = await linkedNow($)
  if (!Array.isArray(linked)) return [`the pull requests this session touched could not be read (${linked.why}), so whether one is still open is not known`]
  const byRepo = new Map<string, number[]>()
  for (const l of linked) byRepo.set(l.repo, [...(byRepo.get(l.repo) ?? []), l.pr])
  const gh = (argv: string[], env?: Record<string, string>, stdin?: string) =>
    $.process.run(argv, { timeoutMs: 20_000, ...(env ? { env } : {}), ...(stdin !== undefined ? { stdin } : {}) })
  const out: Holds = []
  for (const [repo, prs] of byRepo) {
    const named = prs.map(n => `#${n}`).join(', ')
    let open: number[]
    try {
      // As each account gh is logged in to: Dan's work repositories are visible only to his work account.
      const r = await askAnyAccount(gh, ['pr', 'list', '--repo', repo, '--state', 'open', '--json', 'number', '--limit', '1000'], notFound)
      if (!('stdout' in r)) {
        out.push(`could not ask GitHub whether ${repo}'s pull requests ${named} are still open (${ghLine(r.failures.find(f => !notFound(f)) ?? (r.failures[0] as GhRun))})`)
        continue
      }
      const list = JSON.parse(r.stdout) as unknown
      if (!Array.isArray(list)) throw new Error('gh answered something that is not a list')
      open = list.map(x => (x as { number?: unknown }).number).filter((n): n is number => typeof n === 'number')
    } catch (err) {
      out.push(`could not ask GitHub whether ${repo}'s pull requests ${named} are still open (${msg(err)})`)
      continue
    }
    for (const n of prs) if (open.includes(n)) out.push(`${repo}#${n} is still open: merge it, or close it if it is not part of this work`)
  }
  return out
}

/** The agents the session started that are still working. One a plugin started is not the request's. */
const agentHolds = async ($: EngineInterface): Promise<Holds> => {
  try {
    const agents = await $.agent.list()
    return agents
      .filter(a => (a.status === 'running' || a.status === 'pending' || a.status === 'waiting') && a.spawnedBy === undefined)
      .map(a => `the agent "${a.description || a.name || a.id}" is still ${a.status}`)
  } catch (err) {
    return [`the session's agents could not be listed (${msg(err)}), so whether one is still working is not known`]
  }
}

const mergeHoldsNow = async ($: EngineInterface): Promise<Holds> => {
  const facts: MergeFacts = {
    owed: ((await $.state.get(owedRef)).value ?? []) as MergeFacts['owed'],
    verdicts: ((await $.state.get(verdictsRef)).value ?? {}) as MergeFacts['verdicts'],
  }
  return mergeHolds(facts)
}

/**
 * Records the box as shown unless a box with this key, or any box since Dan's last message, already
 * was: read, judged and written with the version read, again on a miss, so two calls at once show one.
 */
const claim = async ($: EngineInterface, entry: GoalBoxShown): Promise<boolean> => {
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(shownRef)
    const list = held.value ?? []
    const last = list[list.length - 1]
    if (list.some(s => s.key === entry.key) || (entry.kind === 'request' && last !== undefined && entry.prompts <= last.prompts)) return false
    if ((await $.state.set(shownRef, [...list, entry], { ifVersion: held.version })).isSet) return true
  }
  return false
}

/** Marks a met goal as asked about; false when it already was, or its box already shown. */
const markAsked = async ($: EngineInterface, id: string): Promise<boolean> => {
  if (((await $.state.get(shownRef)).value ?? []).some(s => s.key === `goal:${id}`)) return false
  for (let i = 0; i < 10; i++) {
    const held = await $.state.get(askedRef)
    const list = held.value ?? []
    if (list.includes(id)) return false
    if ((await $.state.set(askedRef, [...list, id], { ifVersion: held.version })).isSet) return true
  }
  return false
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.state.set(interactiveRef, e.isInteractive === true)
    // Only where somebody is at the prompt to see it; offered in full, not behind a search, so the
    // session knows when to call it.
    if (e.isInteractive) await $.tool.register({ name: NAME, description: DESCRIPTION, inputSchema: SCHEMA, isDeferred: false })
    return next(e)
  })

  // Dan asking for something: what lets a second box be shown in one session.
  on('prompt.submit', async ($, e, next) => {
    const r = await next(e)
    if (r.drop !== undefined) return r
    let isDans = false
    try {
      isDans = await $.modkit.isDans({ origin: e.origin })
    } catch (err) {
      debug($, `could not ask mod-kit whether a message was Dan's own words (${errorText(err, MOD)}), so it was not counted as a new request`)
    }
    if (isDans) {
      for (let i = 0; i < 10; i++) {
        const held = await $.state.get(promptsRef)
        if ((await $.state.set(promptsRef, (held.value ?? 0) + 1, { ifVersion: held.version })).isSet) break
      }
    }
    return r
  })

  // Answered here and never passed down, so the guards beneath (the secret guard) are asked through
  // mod-kit's screen first (#707).
  on('tool.call', { tool: TOOL }, async ($, e) => {
    const refused = await $.modkit.screen(e)
    if (refused) return refused
    if (e.agentId !== undefined) return { deny: 'No box: only the main conversation shows the Goal accomplished box, once the work Dan asked for is finished.' }
    const { tool: _t, tool_use_id: toolUseId, agentId: _a, consent: _c, ...raw } = e as unknown as Record<string, unknown>
    const input = readInput(raw)
    if ('refusal' in input) return { deny: `No box: ${input.refusal}.` }
    const goal = await goalNow($)
    const holds = [...(await agentHolds($)), ...(await mergeHoldsNow($)), ...(await openHolds($))]
    const shown = (await $.state.get(shownRef)).value ?? []
    const prompts = (await $.state.get(promptsRef)).value ?? 0
    const d = decide({ goal, input, shown, prompts, holds })
    if ('refuse' in d) return { deny: `No box yet: ${d.refuse.join('; ')}.` }
    const entry: GoalBoxShown = { key: d.show.key, kind: d.show.kind, at: await $.clock.now(), prompts }
    if (!(await claim($, entry))) return { deny: 'No box yet: the box was already shown for this request; it shows again only once Dan has asked for something new.' }
    const text = boxText(d.show.goal, input.shipped)
    try {
      await $.modkit.card(cardOf(String(toolUseId), d.show.goal, input.shipped))
    } catch (err) {
      // The text below is the box where the card is not drawn: still shown, never lost.
      debug($, `the card could not be drawn (${errorText(err, MOD)}), so the box is shown as text`)
    }
    return { result: text, text, context: ['The Goal accomplished box is shown to Dan above. Do not repeat it in your reply.'] }
  })

  // The met record lands after the Stop hooks, so once the turn has ended the session is sent one
  // prompt of its own to show the box. The main loop's own end only, never an interrupt.
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined || e.reason !== 'answer') return r
    if ((await $.state.get(interactiveRef)).value !== true) return r
    const goal = await goalNow($)
    if (goal.state !== 'none' || !goal.met) return r
    if (!(await markAsked($, goal.met.id))) return r
    try {
      await $.prompt.submit({ text: askText(goal.met.condition) })
    } catch (err) {
      $.ui.log(`The goal "${goal.met.condition}" was met, but the Goal accomplished box could not be asked for (${msg(err)}).`)
    }
    return r
  })
}
