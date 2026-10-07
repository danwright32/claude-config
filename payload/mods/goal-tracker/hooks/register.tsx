import type { EngineInterface, Register } from 'claude-code'
import { baseName, firstWords, permissionFor, projectOf, rowsOf, type StateWord } from './goals.ts'
import { empty, FAIL_STREAK, fromTodos, isStepStatus, taskCreated, taskUpdated, type Progress, type StepStatus } from './progress.ts'

// Goal tracker (claude-config#612). Each session's task list, its goal text, its last activity and
// whether it waits on Dan go into the shared session registry, where the /goals pane (below)
// reads every open session's. A session waiting on Dan, for a question or a permission, sends one
// macOS notification naming the project, and an idle prompt with nothing being asked sends "What's
// next?": these replace the two settings hooks that notified before (Dan, 2026-10-04, pickers).

const ACTIVITY_WRITE_MS = 30_000
let progress: Progress | undefined
// When a write was last tried. Never yet: the first activity of a session is written at once.
let lastTried = Number.NEGATIVE_INFINITY

// A registry write that fails never breaks the tool call it rides on; Claude is told once, on
// the next result it reads, until a write lands again.
let toldUnwritten = false
// What Claude is told rides on the next result it reads; each note is kept until then, so a second
// never overwrites one still waiting (lessons review of 327a767).
const notices: string[] = []
let toldNoClock = false
const publish = async ($: EngineInterface, now: number) => {
  if (!progress) return
  // The throttle counts attempts, so a failing registry is not retried on every tool call.
  lastTried = now
  try {
    await $.sessions.setExtra({ key: 'progress', value: progress })
    toldUnwritten = false
  } catch (err) {
    if (!toldUnwritten) {
      toldUnwritten = true
      notices.push(`The goal tracker could not record this session's progress: ${err instanceof Error ? err.message : String(err)}. Other sessions and the goals pane will not see it.`)
    }
  }
}
const unknownStatus = (status: unknown) =>
  `The goal tracker did not record that step change: status ${JSON.stringify(status)} is not one of pending, in_progress, completed or deleted, so the session's progress is as it was.`
const withNotice = <R extends { context?: readonly string[] }>(result: R): R => {
  if (!notices.length) return result
  const said = notices.splice(0)
  return { ...result, context: [...(result.context ?? []), ...said] }
}

// Notifications (Dan, 2026-10-04): one per waiting moment, naming the project. A question: "<project>
// is waiting on you", the question. A permission: "<project> needs a permission", what it is for,
// with the sound the settings hook it replaces made. "What's next?" only for an idle prompt with
// nothing being asked. One that cannot be sent is said once a session, in one dim line (the guards'
// note style), its reason also in the debug log; it never holds up or breaks what it rides on.
let startCwd = ''
let project: string | undefined
let toldNoNotify = false
// This session's project, from its own registry record (the one place its repository is worked out).
const projectName = async ($: EngineInterface): Promise<string> => {
  if (project) return project
  try {
    const l = await $.sessions.list()
    const self = [...l.open, ...l.closed].find(r => r.sessionId === l.selfId)
    if (self) return (project = projectOf(self))
  } catch {
    // The folder it started in names it instead.
  }
  return baseName(startCwd) || 'Claude Code'
}
/** The scope modes mod's noun (#841) as its contract has it; it may not be loaded at all. */
type ScopeModes = { isAsleep: () => Promise<boolean> }
// Whether the Mac is asleep (sleep mode, #841), asked of scope modes, which reads the one sleep
// record through its one predicate at every ask. Not loaded, it is awake; a check that fails also
// counts as awake, as a record that cannot be read does, so a page is sent rather than lost unseen.
const isAsleep = async ($: EngineInterface): Promise<boolean> => {
  try {
    return (await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.isAsleep()) === true
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err)
    // Only the noun itself missing (scope modes not loaded) goes unsaid, as the keystroke guard reads it.
    if (!(err instanceof TypeError && /scopeModes/.test(why)))
      $.ui.log(`goal-tracker: could not tell whether the Mac is asleep (${why}), so the notification is sent`, { to: 'debug' })
    return false
  }
}
const notify = async ($: EngineInterface, title: string, message: string, sound?: string) => {
  // Dan is asleep: nothing pages him (#841). The pane still shows what the session waits on.
  if (await isAsleep($)) {
    $.ui.log(`goal-tracker: the notification "${title}" was not sent: the Mac is asleep (sleep mode)`, { to: 'debug' })
    return
  }
  let why: string | undefined
  try {
    // A value starting with a dash would be read as an option, so it is led by a space (lessons review).
    const text = (v: string) => (v.startsWith('-') ? ` ${v}` : v)
    const r = await $.process.run(['terminal-notifier', '-title', text(title), '-message', text(message), ...(sound ? ['-sound', sound] : [])], { timeoutMs: 10_000 })
    if (r.exitCode !== 0) why = r.stderr.trim() || `terminal-notifier exited ${r.exitCode}`
  } catch (err) {
    why = err instanceof Error ? err.message : String(err)
  }
  if (why === undefined) return
  $.ui.log(`goal-tracker: could not send the notification "${title}": ${why}`, { to: 'debug' })
  if (!toldNoNotify) {
    toldNoNotify = true
    $.ui.log(`The goal tracker could not send a notification: ${why}.`)
  }
}
// Sent beside the call it announces, never awaited by it: a notifier that hangs never holds up a question.
const notifySoon = ($: EngineInterface, title: () => Promise<string>, message: string, sound?: string) => {
  void title()
    .then(t => notify($, t, message, sound))
    .catch(err => $.ui.log(`goal-tracker: could not send a notification: ${err instanceof Error ? err.message : String(err)}`, { to: 'debug' }))
}
// The first question's text of an AskUserQuestion input: the one reading both the question path and
// the permission path use.
const questionOf = (input: unknown): string => {
  const qs = (input as { questions?: { question?: unknown }[] } | null)?.questions
  const q = Array.isArray(qs) ? qs[0]?.question : undefined
  return typeof q === 'string' && q ? q : 'a question'
}
const waitingOnYou = ($: EngineInterface, text: string) => notifySoon($, async () => `${await projectName($)} is waiting on you`, text)
// A clock that cannot be read stamps a goal or a request with the last activity's time instead.
const nowOr = ($: EngineInterface): Promise<number> => $.clock.now().catch(() => progress?.lastActivityAt ?? 0)

// What the session waits on Dan for, each kept apart so that one ending never erases another
// (#694): the open question (ask before saving's included, asked in the same dialog since #777) and
// the open permission prompt with the calls it may belong to, and each question the tracker does not
// hold (a subagent's), by its own call. The pane shows the one asked latest.
type Waiting = NonNullable<Progress['waiting']>
let question: { id: string; mark: Waiting } | undefined
let permission: { calls: Set<string>; mark: Waiting } | undefined
// A question announced by its dialog's permission request alone, keyed by its call, apart from
// `permission`: a Bash prompt open beside it keeps its own mark and calls (#824, #694).
const unheldQuestions = new Map<string, Waiting>()
// The calls of this conversation's own questions while they run, which the question path marks and
// notifies; a permission request raised inside one of them is that question (#814).
const heldQuestions = new Set<string>()
// The question calls a permission request has already been matched to, until each returns.
const claimedQuestions = new Set<string>()
const waitingNow = (): Waiting | undefined => {
  let latest: Waiting | undefined
  for (const m of [question?.mark, permission?.mark, ...unheldQuestions.values()]) if (m && (!latest || m.since > latest.since)) latest = m
  return latest
}
const withWaiting = (p: Progress): Progress => {
  const w = waitingNow()
  if (w === p.waiting) return p
  const { waiting: _was, ...rest } = p
  return w ? { ...rest, waiting: w } : rest
}

// The calls running now, by id, with their arguments. A permission prompt names its call only by tool
// and input, never by id, so it is matched to one of these; matching on the tool and the prompt's
// "what for" text let any other Bash call with no description, which reads "a Bash command" too,
// clear it early (#694).
const running = new Map<string, { tool: string; args: Record<string, unknown> }>()
let unnamed = 0
const argsOf = ({ tool: _t, tool_use_id: _id, agentId: _a, consent: _c, ...args }: Record<string, unknown>) => args
const sameArgs = (args: Record<string, unknown>, asked: unknown): boolean => {
  if (!asked || typeof asked !== 'object') return false
  const named = asked as Record<string, unknown>
  const shared = Object.keys(named).filter(k => k in args)
  return shared.length > 0 && shared.every(k => JSON.stringify(args[k]) === JSON.stringify(named[k]))
}
// The running call of the prompt's tool whose arguments it names; else (a hook beneath rewrote the
// call) every running call of its tool, and the prompt stands until each of them has returned.
const callsFor = (tool: string, asked: unknown): string[] => {
  const ofTool = [...running].filter(([, c]) => c.tool === tool)
  const named = ofTool.filter(([, c]) => sameArgs(c.args, asked))
  return (named.length ? named : ofTool).map(([id]) => id)
}
// A prompt raised inside a call has been answered, either way, once that call has returned or
// rejected. True when that took a mark off: an unheld question's, or the permission's.
const callEnded = (id: string): boolean => {
  running.delete(id)
  claimedQuestions.delete(id)
  const hadQuestion = unheldQuestions.delete(id)
  if (!permission?.calls.delete(id) || permission.calls.size) return hadQuestion
  permission = undefined
  return true
}

// Every question is asked by Claude Code's own dialog (picker manners only refuses some, #744), so a
// question is notified once Dan can see it (#706): marked only once every refusing guard and settings
// hook has let it through (#732), from this mod's tool.check hook (#875), which the engine raises
// beneath every tool.call hook, never from its tool.call hook, which runs before the guards beneath it
// decide. A secret scan can take seconds, and a question it refuses must not put its text into a
// notification or the shared registry. It is then notified QUESTION_SHOWN_MS later if still open,
// since a refusal by Claude Code itself comes after the hooks.
const QUESTION_SHOWN_MS = 1_000
// The session's own questions this mod's tool.call hook has seen, by call, with their text, until
// the tool.check hook marks them or the call ends. A subagent's are never held, so the tool.check
// hook, which keys on the call alone, never marks one.
const asking = new Map<string, string>()
// The one spelling of its key, for the hook that holds a question and the one that marks it (lessons
// review of #737): the call's id, which the engine gives every call and lets no mod strip.
const askKey = (e: unknown) => String((e as { tool_use_id?: unknown }).tool_use_id ?? '')
let unsent: { id: string; send: () => void; timer: { cancel: () => void } } | undefined
const sendUnsent = (id: string) => {
  if (unsent?.id !== id) return
  const u = unsent
  unsent = undefined
  u.timer.cancel()
  u.send()
}
const dropUnsent = (id: string) => {
  if (unsent?.id !== id) return
  unsent.timer.cancel()
  unsent = undefined
}
// A question in front of Dan: marked for the pane and notified, once per question.
const questionOpened = async ($: EngineInterface, id: string, text: string, now: number) => {
  if (question?.id === id) return
  question = { id, mark: { question: text, since: now, kind: 'question' } }
  if (progress) {
    progress = { ...withWaiting(progress), lastActivityAt: now }
    await publish($, now)
  }
  const send = () => waitingOnYou($, text)
  if (unsent) dropUnsent(unsent.id)
  // Sent only if that question is still the open one: one ended meanwhile never reached Dan.
  unsent = { id, send, timer: $.clock.after(QUESTION_SHOWN_MS, () => (question?.id === id ? sendUnsent(id) : dropUnsent(id))) }
}

// The /goals pane (claude-config#612, docs/mods-design.md "Goals pane", settled 2026-10-04): every
// open session on this Mac, in any project, two lines each. Project and goal on top; beneath, the
// state word in its own colour and one dim sentence. A live pane: it follows the sessions as they
// move and closes itself when Dan next sends a message.

const PANE = 'goals'
// Other sessions write their records on their own schedule, so the pane reads the registry again
// on this cadence while it is open.
const FOLLOW_MS = 5_000

// On the state word only (colour round): waiting on you and stalled amber, failed red, working blue,
// done green, as the engine's theme names them. A deliberate exception to standing rule 1.
const COLOUR: Record<StateWord, string> = {
  'waiting on you': 'warning',
  failed: 'error',
  stalled: 'warning',
  working: 'suggestion',
  done: 'success',
}

let isOpen = false
let follow: { cancel: () => void } | undefined
const stopFollowing = () => {
  follow?.cancel()
  follow = undefined
  isOpen = false
}

const open = async ($: EngineInterface): Promise<string | undefined> => {
  const r = await $.ui.open({ id: PANE, title: 'Goals' })
  isOpen = true
  follow?.cancel()
  follow = $.clock.every(FOLLOW_MS, () => $.ui.invalidate('ui.render'))
  return r.isPlaced ? undefined : `The goals pane is open but not shown: ${r.reason}.`
}

// The module has one session.start and one prompt.submit hook (in register below), which call these.
const paneStart = async ($: EngineInterface) => {
  stopFollowing()
  await $.command.register({ name: 'goals', description: "Every open session's goal and progress" })
}

// Dan's own words: typed at the terminal, sent from his phone through Remote Control, or a handoff's
// opening prompt, which the handoff mod submits as his when he presses its Use button (#706). The
// one rule for every place this module asks whether a prompt is Dan's.
type Origin = { kind: string; name?: string; asUser?: boolean }
const isDans = (origin: Origin): boolean =>
  origin.kind === 'composer' || origin.kind === 'bridge' || (origin.kind === 'plugin' && origin.name === 'handoff' && origin.asUser === true)

// Closed by Dan's next message (picker): a slash command, /goals itself included, is not one.
const paneOnPrompt = async ($: EngineInterface, e: { text: string; origin: Origin }) => {
  if (isOpen && isDans(e.origin) && !e.text.trim().startsWith('/')) {
    stopFollowing()
    // A close that fails never holds up Dan's message (L73); it is said in the debug log.
    try {
      await $.ui.close({ id: PANE })
    } catch (err) {
      $.ui.log(`goal-tracker: could not close the goals pane: ${err instanceof Error ? err.message : String(err)}`, { to: 'debug' })
    }
  }
}

// Failed, decided with Dan (2026-10-04, after the review of #634): three tool calls in a row failed
// or refused, nothing succeeding between; the next success clears it.
let streak = 0
// The failure is recorded as its first line, cut to a short length: the registry is shared with
// every session on this Mac, so a tool's whole output never goes into it (L657, lessons review).
const FAILED_MAX = 200
const oneLine = (text: string): string => {
  const first = text.split('\n').map(l => l.trim()).find(Boolean) ?? 'it failed'
  return first.length > FAILED_MAX ? `${first.slice(0, FAILED_MAX - 3)}...` : first
}
const failureOf = (r: { deny?: unknown; isError?: boolean; text?: unknown }): string | undefined =>
  r.deny ? oneLine(String(r.deny)) : r.isError ? oneLine(String(r.text ?? 'it failed')) : undefined
const counted = (p: Progress, why: string | undefined): Progress => {
  if (why === undefined) {
    streak = 0
    const { failed: _cleared, ...rest } = p
    return rest
  }
  streak += 1
  return streak >= FAIL_STREAK ? { ...p, failed: why } : p
}
// A call another mod refused without calling next (the collision guard, ask before saving, picker
// manners above this one) never reaches this module's tool.call hook, but its result's row does,
// whatever order the mods run in (#706). So the rows count too, all but those of the calls the hook
// already counted, by tool_use_id; taken out as each row comes, and capped meanwhile.
const countedCalls = new Set<string>()
const COUNTED_MAX = 200
const noteCounted = (id: unknown) => {
  if (typeof id !== 'string') return
  countedCalls.add(id)
  for (const old of countedCalls) {
    if (countedCalls.size <= COUNTED_MAX) break
    countedCalls.delete(old)
  }
}
// A tool result's text as the model reads it: a string, or its text blocks.
const resultText = (content: unknown): string =>
  typeof content === 'string'
    ? content
    : Array.isArray(content)
      ? content.map(b => ((b as { type?: string }).type === 'text' ? String((b as { text?: unknown }).text ?? '') : '')).join('\n')
      : ''

// A call still running is the session working (#706): a test suite or build over ten minutes was
// shown as stalled, since activity was written only once a call returned. While any call runs, its
// activity is written each minute.
const STILL_WORKING_MS = 60_000
let beat: { cancel: () => void } | undefined
const stillWorking = async ($: EngineInterface) => {
  if (!running.size) return
  let now: number
  try {
    now = await $.clock.now()
  } catch {
    // The clock's failure is said on the next call's result; nothing is written without a time.
    return
  }
  // Read after the clock (lessons review of #725): a /clear meanwhile may have begun again with
  // nothing to write onto, and a record holding only a time is no progress at all.
  if (!progress) return
  progress = { ...progress, lastActivityAt: now }
  await publish($, now)
}

// Everything the module keeps belongs to one conversation: a session start, and a /clear, which ends
// the conversation while the process goes on under a new session id with no session.start (#706),
// begin again rather than carry the last one's request, steps, goal, failures or waiting marks. The
// calls running are left alone: they are calls in flight, and each takes itself off as it ends.
const beginAgain = async ($: EngineInterface) => {
  // A clock that cannot be read leaves progress to begin on the first tool call that can read it.
  progress = await $.clock.now().then(empty, () => undefined)
  lastTried = Number.NEGATIVE_INFINITY
  streak = 0
  notices.length = 0
  toldUnwritten = false
  toldNoClock = false
  toldNoNotify = false
  project = undefined
  // heldQuestions and claimedQuestions describe calls still in flight, as `running` does, so a
  // /clear leaves them to each call's own end (lessons review of PR 816). All but one: a question
  // whose notification the /clear drops unsent is still on screen, and nothing else would tell Dan
  // of it (#824). It stops being held, so its dialog's request announces it; and when that request
  // has already come, it is marked and notified here, as a question the tracker does not hold.
  if (unsent) {
    const id = unsent.id
    const mark = question?.id === id ? question.mark : undefined
    dropUnsent(id)
    heldQuestions.delete(id)
    if (mark && claimedQuestions.has(id)) {
      unheldQuestions.set(id, mark)
      waitingOnYou($, mark.question)
    }
  }
  question = undefined
  permission = undefined
  // A question's request matched to no call belongs to the conversation that ended; one whose call
  // still runs is in flight, and comes off when that call ends (lessons review of PR 825).
  for (const id of [...unheldQuestions.keys()]) if (!running.has(id)) unheldQuestions.delete(id)
  countedCalls.clear()
  if (progress) progress = withWaiting(progress)
}

export const register: Register = on => {
  // Everything the module keeps belongs to one session: a later start in the same process begins
  // again rather than reading the last one's (lessons review of #634).
  on('session.start', async ($, e, next) => {
    // A clock that cannot be read never stops the pane and /goals being set up.
    await beginAgain($)
    startCwd = e.cwd
    beat?.cancel()
    beat = $.clock.every(STILL_WORKING_MS, () => stillWorking($))
    await paneStart($)
    return next(e)
  })

  // A /clear: the next conversation in this process starts its progress afresh (#706). Nothing is
  // written here: the registry closes this session's record now, and the next tool call writes the
  // new conversation's progress at once.
  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') await beginAgain($)
    return next(e)
  })

  on('command.run', { command: 'goals' }, async $ => {
    const said = await open($)
    return said ? { text: said } : {}
  })

  on('ui.close', { id: PANE }, async ($, e, next) => {
    stopFollowing()
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    let list
    try {
      list = await $.sessions.list()
    } catch (err) {
      // A registry that cannot be read is said, never drawn as no sessions (L10).
      return (
        <Box flexDirection="column">
          <Text dimColor>
            {`Session records could not be read: ${err instanceof Error ? err.message : String(err)}.`}
          </Text>
        </Box>
      )
    }
    let now: number
    try {
      now = await $.clock.now()
    } catch (err) {
      // A clock that cannot be read is said too, never a pane that fails to draw.
      return (
        <Box flexDirection="column">
          <Text dimColor>{`The goals pane could not read the clock: ${err instanceof Error ? err.message : String(err)}.`}</Text>
        </Box>
      )
    }
    const rows = rowsOf(list.open, now)
    const unreadable = list.unreadable.length
    return (
      <Box flexDirection="column">
        {rows.length === 0 ? <Text dimColor>No open session has recorded its progress.</Text> : null}
        {rows.map((r, i) => (
          <Box key={`session-${r.sessionId}`} flexDirection="column" marginTop={i ? 1 : 0}>
            <Text>{r.goal ? `${r.project}  ${r.goal}` : r.project}</Text>
            <Text>
              {'  '}
              <Text color={COLOUR[r.state]}>
                {r.state}
              </Text>
              <Text dimColor>
                {r.sentence}
              </Text>
            </Text>
          </Box>
        ))}
        {unreadable ? (
          <Box marginTop={rows.length ? 1 : 0}>
            <Text dimColor>
              {`${unreadable} session ${unreadable === 1 ? 'record' : 'records'} could not be read.`}
            </Text>
          </Box>
        ) : null}
      </Box>
    )
  })

  // The goal text (Dan, 2026-10-04, picker): the /goal condition while one is set, else the first
  // request cut to a few words. No model call.
  on('command.run', { command: 'goal' }, async ($, e, next) => {
    const result = await next(e)
    const args = e.args.trim()
    if (!args || !progress) return result
    if (args === 'clear') {
      const { goal: _cleared, ...rest } = progress
      progress = rest
    } else progress = { ...progress, goal: args }
    await publish($, await nowOr($))
    return result
  })

  // Dan's first message is the goal text until a /goal is set; a slash command is not a request.
  on('prompt.submit', async ($, e, next) => {
    await paneOnPrompt($, e)
    const result = await next(e)
    const isPerson = isDans(e.origin)
    const text = e.text.trim()
    // Dan sending a message is never a session waiting on his permission: a mark whose call could
    // not be matched as it returned is cleared here at the latest (lessons review of f0a8ff9).
    // A question's request matched to no call (none was running of its tool) is cleared here too.
    let stale = false
    if (isPerson) for (const id of [...unheldQuestions.keys()]) if (!running.has(id)) stale = unheldQuestions.delete(id) || stale
    if (isPerson && (permission || stale)) {
      permission = undefined
      const before = progress
      if (progress) progress = withWaiting(progress)
      if (progress !== before) await publish($, await nowOr($))
    }
    if (isPerson && progress && progress.request === undefined && text && !text.startsWith('/')) {
      progress = { ...progress, request: firstWords(text) }
      await publish($, await nowOr($))
    }
    return result
  })

  // A permission prompt is the session waiting on Dan, as a question is (spec item 4): marked for the
  // pane until the call it belongs to returns, and notified.
  on('classic.PermissionRequest', async ($, e, next) => {
    // Claude Code raises a permission request for its own question dialog. That request is the
    // question, never a second thing waiting on Dan (#814: Dan got "is waiting on you" and "needs a
    // permission: AskUserQuestion" for every question). A question the tracker holds (this
    // conversation's, marked and notified by its own path) sends nothing more. One it does not hold
    // (a subagent's, lessons review of PR 816) is announced by this request alone, so it is marked
    // and notified here, once, as the question it is.
    const isQuestion = e.tool_name === 'AskUserQuestion'
    // Matched by the call it was raised inside, never by the question's text (lessons review of PR
    // 816): a subagent asking what this conversation asks is still its own question.
    const calls = callsFor(e.tool_name, e.tool_input)
    let own: string | undefined
    if (isQuestion) {
      // Each request belongs to one question's call: the first running one it matches that no
      // request has claimed yet, so two identical questions (a subagent's beside this
      // conversation's) are told apart by the order they asked in (lessons review of PR 816).
      own = calls.find(id => !claimedQuestions.has(id))
      // Every running question it matches already claimed: a request raised again for a dialog
      // already announced (a re-prompt), never a second question (lessons review of PR 816).
      if (own === undefined && calls.length > 0) return next(e)
      if (own !== undefined) {
        claimedQuestions.add(own)
        if (heldQuestions.has(own)) return next(e)
      }
    }
    const what = isQuestion ? questionOf(e.tool_input) : permissionFor(e.tool_name, e.tool_input)
    const now = await nowOr($)
    const mark: Waiting = { question: what, since: now, kind: isQuestion ? 'question' : 'permission' }
    // A question's mark is its own call's, never the permission slot (#824); one matched to no
    // running call is keyed apart too, and Dan's next message clears it.
    if (isQuestion) unheldQuestions.set(own ?? `request-${++unnamed}`, mark)
    else permission = { calls: new Set(calls), mark }
    if (progress) {
      progress = withWaiting(progress)
      await publish($, now)
    }
    if (isQuestion) waitingOnYou($, what)
    else notifySoon($, async () => `${await projectName($)} needs a permission`, what, 'Glass')
    return next(e)
  })

  // Each tool result's row, counted toward failed unless this module's tool.call hook already
  // counted its call (above). A subagent's rows are its own, as its calls are.
  on('session.append', { door: 'tool-result' }, async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)
    let changed = false
    for (const b of e.message.content) {
      const block = b as { type?: string; tool_use_id?: unknown; content?: unknown; is_error?: boolean }
      if (block.type !== 'tool_result' || typeof block.tool_use_id !== 'string' || countedCalls.delete(block.tool_use_id)) continue
      progress ??= withWaiting(empty(await nowOr($)))
      const before = progress.failed
      progress = counted(progress, block.is_error ? oneLine(resultText(block.content) || 'it failed') : undefined)
      if (progress.failed !== before) changed = true
    }
    if (changed) await publish($, await nowOr($))
    return next(e)
  })

  // "What's next?" only while nothing is being asked: an open question (ask before saving's included)
  // or a permission sent its own.
  on('classic.Notification', async ($, e, next) => {
    if (e.notification_type === 'idle_prompt' && !waitingNow()) notifySoon($, async () => 'Claude Code', "What's next?")
    return next(e)
  })

  // A question Claude Code shows itself, marked and notified only once everything beneath has let it
  // through (#732, above): every mod's tool.call hook and the settings PreToolUse hooks have decided
  // by the time the engine raises tool.check, and next(e) runs only the verdict beneath, never the
  // question. It was classic.PreToolUse, which never ran (#875): Claude Code's built-in security
  // default sends every classic event past the user tier this mod loads in, for a Team or Enterprise
  // organization (a headless debug run, 2026-10-06). A query ($.tool.check) carries no call id, so
  // it matches no question asked.
  on('tool.check', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const decided = await next(e)
    const key = askKey(e)
    const text = asking.get(key)
    if (decided.decision === 'deny' || text === undefined) return decided
    asking.delete(key)
    await questionOpened($, key, text, await nowOr($))
    return decided
  })

  on('tool.call', async ($, e, next) => {
    const input = e as unknown as Record<string, unknown>
    // Recorded before anything else, so a permission prompt raised inside it is matched to it (#694).
    const id = typeof input.tool_use_id === 'string' ? input.tool_use_id : `call-${++unnamed}`
    running.set(id, { tool: e.tool, args: argsOf(input) })
    // A clock that cannot be read leaves this call untracked, never broken; Claude is told once,
    // until the clock reads again (lessons review of c4ae14f).
    let now: number
    try {
      now = await $.clock.now()
      toldNoClock = false
    } catch (err) {
      if (!toldNoClock) {
        toldNoClock = true
        notices.push(`The goal tracker could not read the clock (${err instanceof Error ? err.message : String(err)}), so this session's progress is not being recorded.`)
      }
      try {
        return withNotice(await next(e))
      } finally {
        // An answered prompt's mark still comes off, written with no new time.
        if (callEnded(id) && progress) {
          progress = withWaiting(progress)
          await publish($, lastTried)
        }
      }
    }
    progress ??= withWaiting(empty(now))
    // A subagent keeps its own list, which is not the session's goal; its work still counts as
    // the session being active, and its failures are its own (lessons review of #634).
    const fromSubagent = Boolean((e as { agentId?: string }).agentId)

    if (e.tool === 'AskUserQuestion' && !fromSubagent) {
      // Marked by the tool.check hook below once the guards have let it through (#732).
      const key = askKey(e)
      asking.set(key, questionOf(input))
      heldQuestions.add(id)
      // A question that throws or is refused counts toward failed, as any call does. What follows
      // the question can never throw over its result or error, and a notice its write raises rides
      // on this result (lessons review of #634).
      const settle = async (why: string | undefined) => {
        let after = now
        try {
          after = await $.clock.now()
        } catch {
          // The time the question was asked stands in for a clock that cannot be read.
        }
        // Only the question's own mark comes off: a permission prompt still open stands (#694). One
        // that ended before it was notified never reached Dan, and is not notified now (#706).
        asking.delete(key)
        heldQuestions.delete(id)
        dropUnsent(key)
        question = undefined
        callEnded(id)
        progress = { ...counted(withWaiting(progress ?? empty(now)), why), lastActivityAt: after }
        noteCounted(input.tool_use_id)
        await publish($, after)
      }
      let result
      try {
        result = await next(e)
      } catch (err) {
        await settle(err instanceof Error ? err.message : String(err))
        throw err
      }
      await settle(failureOf(result))
      return withNotice(result)
    }

    let result
    try {
      result = await next(e)
    } catch (err) {
      // A call that rejects (an interrupt does) has ended too, so a prompt raised inside it is over.
      if (callEnded(id) && progress) {
        progress = withWaiting(progress)
        await publish($, now)
      }
      throw err
    }
    // What follows the call is stamped with when it returned, never when it began: a call that ran
    // twelve minutes left the session reading stalled after it returned (#706).
    const at = await $.clock.now().catch(() => now)
    const waitingBefore = progress.waiting
    if (callEnded(id)) progress = withWaiting(progress)
    const before = progress
    const why = failureOf(result)

    if (fromSubagent || why !== undefined) {
      progress = { ...(fromSubagent ? progress : counted(progress, why)), lastActivityAt: at }
      if (!fromSubagent) noteCounted(input.tool_use_id)
    } else {
      progress = counted(progress, undefined)
      noteCounted(input.tool_use_id)
      if (e.tool === 'TodoWrite') {
        const todos = Array.isArray(input.todos) ? (input.todos as { content: string; status: unknown; activeForm: string }[]) : []
        const odd = todos.find(t => !isStepStatus(t?.status))
        // A list carrying a status the tracker cannot count is not stored at all, and Claude is told.
        if (odd) {
          notices.push(unknownStatus(odd.status))
          progress = { ...progress, lastActivityAt: at }
        } else progress = fromTodos(progress, todos as { content: string; status: StepStatus; activeForm: string }[], at)
      } else if (e.tool === 'ProposeGoal' && typeof input.condition === 'string' && input.condition.trim()) {
        // A goal Claude proposed is the goal once the call succeeds (set, or approved by Dan).
        progress = { ...progress, goal: input.condition.trim(), lastActivityAt: at }
      } else if (e.tool === 'TaskCreate') {
        const task = (result.result as { task?: { id?: string; subject?: string } } | undefined)?.task
        // A result with no task id cannot be followed, but the call is still activity.
        progress = task?.id
          ? taskCreated(progress, { id: task.id, subject: task.subject ?? String(input.subject ?? ''), activeForm: input.activeForm as string | undefined }, at)
          : { ...progress, lastActivityAt: at }
      } else if (e.tool === 'TaskUpdate') {
        const status = input.status
        // An update carrying a status the tracker cannot count is not stored at all, and Claude is told.
        if (status !== undefined && status !== 'deleted' && !isStepStatus(status)) {
          notices.push(unknownStatus(status))
          progress = { ...progress, lastActivityAt: at }
        } else progress = taskUpdated(progress, input as { taskId: string; status?: StepStatus | 'deleted'; subject?: string; activeForm?: string }, at)
      } else {
        progress = { ...progress, lastActivityAt: at }
      }
    }

    // A change to the list or to failed is written at once; plain activity at most every thirty seconds.
    if (progress.steps !== before.steps || progress.failed !== before.failed || progress.goal !== before.goal || progress.waiting !== waitingBefore || at - lastTried >= ACTIVITY_WRITE_MS) await publish($, at)
    return withNotice(result)
  })
}
