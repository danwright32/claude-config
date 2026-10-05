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
const notify = async ($: EngineInterface, title: string, message: string, sound?: string) => {
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
const waitingOnYou = ($: EngineInterface, text: string) => notifySoon($, async () => `${await projectName($)} is waiting on you`, text)
// A clock that cannot be read stamps a goal or a request with the last activity's time instead.
const nowOr = ($: EngineInterface): Promise<number> => $.clock.now().catch(() => progress?.lastActivityAt ?? 0)

// What the session waits on Dan for, each kept apart so that one ending never erases another
// (#694): the open question, a save waiting in the band for his answer (#706), and the open
// permission prompt with the calls it may belong to. The pane shows the one asked latest.
type Waiting = NonNullable<Progress['waiting']>
let question: { id: string; mark: Waiting } | undefined
let saving: { id: string; mark: Waiting } | undefined
let permission: { calls: Set<string>; mark: Waiting } | undefined
const waitingNow = (): Waiting | undefined => {
  let latest: Waiting | undefined
  for (const m of [question?.mark, saving?.mark, permission?.mark]) if (m && (!latest || m.since > latest.since)) latest = m
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
// rejected. True when that took the permission mark off.
const callEnded = (id: string): boolean => {
  running.delete(id)
  if (!permission?.calls.delete(id) || permission.calls.size) return false
  permission = undefined
  return true
}

// Picker manners (#615) answers every AskUserQuestion in its own tool.call hook and never calls next.
// Hooks on one event nest by tier, then by load order, outermost first, so wherever picker manners
// sits above this mod, this mod's tool.call hook never sees the question (#694). The question is
// also seen where picker manners cannot pre-empt it: its own writes of the question it holds open
// (`picker-manners.open` in its contract), which reach every plugin's state.set hook wherever each
// sits, the question as it opens and null as it ends. Where both see one question (this mod above),
// the call's id, which picker manners keys the open question by, makes it one mark and one
// notification.
const PICKER_OPEN = { plugin: 'picker-manners', key: 'open' } as const
let toldUnreadableQuestion = false
// Another plugin's value is read, never trusted: the question's id and its text, or nothing.
const openQuestionOf = (value: unknown): { id: string; text: string } | undefined => {
  const o = value as { id?: unknown; question?: { question?: unknown } } | null
  return o && typeof o === 'object' && typeof o.id === 'string' && typeof o.question?.question === 'string' ? { id: o.id, text: o.question.question } : undefined
}
// A question is notified once Dan can see it (#706), whichever order the two mods run in. Picker
// manners' write of the question it holds open is it shown, and notified at once: picker manners
// writes it only after its own refusals and mod-kit's screen (the secret guard) have let it through.
// A question Claude Code shows itself is marked only once every refusing guard and settings hook has
// let it through (#732): from this mod's classic.PreToolUse hook, which the engine raises beneath
// every tool.call hook, never from its tool.call hook, which runs before the guards beneath it
// decide. A secret scan can take seconds, and a question it refuses must not put its text into a
// notification or the shared registry. It is then notified QUESTION_SHOWN_MS later if still open,
// since a refusal by Claude Code itself comes after the hooks.
const QUESTION_SHOWN_MS = 1_000
// The session's own questions this mod's tool.call hook has seen, by call, with their text, until
// the classic.PreToolUse hook marks them or the call ends. A subagent's are never held: the classic
// hook's input does not say whose a call is.
const asking = new Map<string, string>()
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
// A question in front of Dan: marked for the pane and notified, once per question. `shown` when
// picker manners has put it in front of him.
const questionOpened = async ($: EngineInterface, id: string, text: string, now: number, shown: boolean) => {
  if (question?.id === id) {
    if (shown) sendUnsent(id)
    return
  }
  question = { id, mark: { question: text, since: now, kind: 'question' } }
  if (progress) {
    progress = { ...withWaiting(progress), lastActivityAt: now }
    await publish($, now)
  }
  const send = () => waitingOnYou($, text)
  if (shown) return send()
  if (unsent) dropUnsent(unsent.id)
  // Sent only if that question is still the open one: one ended meanwhile never reached Dan.
  unsent = { id, send, timer: $.clock.after(QUESTION_SHOWN_MS, () => (question?.id === id ? sendUnsent(id) : dropUnsent(id))) }
}

// A save to lasting memory waiting in the band for Dan's answer (ask before saving, #618) is the
// session waiting on him, as a question is (#706): its write of the questions it holds
// (`ask-before-saving.pending`, the first one shown) reaches every plugin's state.set hook. Marked
// and notified once per question, in the band's own words, and cleared when none is left.
const SAVE_PENDING = { plugin: 'ask-before-saving', key: 'pending' } as const
const SAVE_QUESTION = 'Save this as a standing rule?'
let toldUnreadableSave = false
// Another plugin's value is read, never trusted: the first question's id, none left, or unreadable.
const firstSaveOf = (value: unknown): { id: string } | null | undefined => {
  if (!Array.isArray(value)) return undefined
  if (!value.length) return null
  const first = value[0] as { id?: unknown } | null
  return first && typeof first === 'object' && typeof first.id === 'string' ? { id: first.id } : undefined
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
  question = undefined
  saving = undefined
  permission = undefined
  if (unsent) dropUnsent(unsent.id)
  countedCalls.clear()
  toldUnreadableQuestion = false
  toldUnreadableSave = false
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
    if (isPerson && permission) {
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
    const what = permissionFor(e.tool_name, e.tool_input)
    const now = await nowOr($)
    permission = { calls: new Set(callsFor(e.tool_name, e.tool_input)), mark: { question: what, since: now, kind: 'permission' } }
    if (progress) {
      progress = withWaiting(progress)
      await publish($, now)
    }
    notifySoon($, async () => `${await projectName($)} needs a permission`, what, 'Glass')
    return next(e)
  })

  // The question picker manners holds open, seen whatever order the two mods run in (above). A write
  // that was refused or did not land, or a value that cannot be read, changes nothing.
  on('state.set', PICKER_OPEN, async ($, e, next) => {
    const r = await next(e)
    if ((r as { value?: { isSet?: boolean } }).value?.isSet !== true) return r
    const shown = openQuestionOf(e.value)
    if (shown) await questionOpened($, shown.id, shown.text, await nowOr($), true)
    else if (e.value === null) {
      if (question) {
        dropUnsent(question.id)
        question = undefined
        if (progress) {
          progress = withWaiting(progress)
          await publish($, await nowOr($))
        }
      }
    } else {
      // Each time in the debug log, and once a session in one dim line, the guards' note style: from
      // here on the questions picker manners shows go unmarked (lessons review of #696).
      $.ui.log("goal-tracker: picker manners' open question could not be read, so it is not marked or notified.", { to: 'debug' })
      if (!toldUnreadableQuestion) {
        toldUnreadableQuestion = true
        $.ui.log('The goal tracker could not read the question picker manners holds open, so a question it shows is not marked as waiting on you or notified.')
      }
    }
    return r
  })

  // A save waiting in the band for Dan's answer (above), read from ask before saving's writes.
  on('state.set', SAVE_PENDING, async ($, e, next) => {
    const r = await next(e)
    if ((r as { value?: { isSet?: boolean } }).value?.isSet !== true) return r
    const first = firstSaveOf(e.value)
    if (first === null) {
      if (saving) {
        saving = undefined
        if (progress) {
          progress = withWaiting(progress)
          await publish($, await nowOr($))
        }
      }
    } else if (first) {
      if (saving?.id !== first.id) {
        const now = await nowOr($)
        saving = { id: first.id, mark: { question: SAVE_QUESTION, since: now, kind: 'question' } }
        if (progress) {
          progress = withWaiting(progress)
          await publish($, now)
        }
        waitingOnYou($, SAVE_QUESTION)
      }
    } else {
      $.ui.log("goal-tracker: ask before saving's waiting question could not be read, so it is not marked or notified.", { to: 'debug' })
      if (!toldUnreadableSave) {
        toldUnreadableSave = true
        $.ui.log('The goal tracker could not read the save question ask before saving holds, so a save waiting on you is not marked or notified.')
      }
    }
    return r
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

  // "What's next?" only while nothing is being asked: an open question, a save waiting in the band or
  // a permission sent its own.
  on('classic.Notification', async ($, e, next) => {
    if (e.notification_type === 'idle_prompt' && !waitingNow()) notifySoon($, async () => 'Claude Code', "What's next?")
    return next(e)
  })

  // A question Claude Code shows itself, marked and notified only once everything beneath has let it
  // through (#732, above): every mod's tool.call hook has decided by now, and next(e) runs the
  // settings hooks, never the question.
  on('classic.PreToolUse', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const decided = await next(e)
    const id = String(e.tool_use_id)
    const text = asking.get(id)
    if (decided.deny !== undefined || text === undefined) return decided
    asking.delete(id)
    await questionOpened($, id, text, await nowOr($), false)
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
      const qs = (input.questions as { question?: string }[] | undefined) ?? []
      // Marked by the classic.PreToolUse hook below once the guards have let it through (#732).
      asking.set(id, qs[0]?.question ?? 'a question')
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
        asking.delete(id)
        dropUnsent(id)
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
