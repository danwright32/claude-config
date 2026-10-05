import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { AskBeforeSavingApproval, AskBeforeSavingQuestion } from '../types/index.d.ts'
import {
  ANSWERS,
  APPROVAL_MS,
  type Answer,
  type InCheckout,
  MOD,
  addedText,
  callShown,
  cannotCheck,
  display,
  lapseWait,
  lastingFiles,
  lastingMemory,
  madePermanent,
  mentioned,
  questionOf,
  resolvePath,
  rowId,
  saveKey,
  stands,
} from './rules.ts'

// Ask before saving (claude-config#618). Before a standing rule reaches lasting memory, by Write,
// Edit or Bash, Dan is asked in the band: For good, Just this session, or Not at all. Settled with
// Dan on 2026-10-03 (the spec) and 2026-10-04 (the question's shape, docs/mods-design.md).
//
// The write is refused at once rather than held open while Dan reads: a tool call hook waiting on a
// band press is cut at its 10 second budget, and the engine then runs the write as if the hook were
// absent (measured 2026-10-04 with `claude plugin test`). Holding it would fail open. So the call is
// refused, and the question waits in the band with the prompt free.
//
// For good approves that save and asks Claude to send the call again (#738); the call that writes
// the same thing goes through, once, through every other mod's checks, the settings hooks and the
// permission check again. The mod never makes the call itself: auto mode's classifier judges a call
// by the model request that produced it and refuses one no request asked for, so a call the mod
// replayed never saved there, and For good went round for ever. Claude's own call comes from a
// request the classifier can judge. It is one path in every permission mode, so nothing has to
// choose a path by the mode, or try one and fall back on the other's error text (L156).
//
// The question is asked from classic.PreToolUse, which the engine raises beneath every mod's
// tool.call hook (#705): a write the style check, the secret guard or no build refuses is refused
// before Dan is asked about it, whatever order the mods load in, so he is never asked to approve a
// save that cannot land. The skip for Dan's own permanent words stays a tool.call hook, the one
// place the saved result can be read, to tell Claude to say what it saved; so does what Dan is told
// of an approved save that then fails.

const pendingRef = { plugin: 'ask-before-saving', key: 'pending' } as const
const rulesRef = { plugin: 'ask-before-saving', key: 'rules' } as const
const promptRef = { plugin: 'ask-before-saving', key: 'lastPrompt' } as const
const approvalsRef = { plugin: 'ask-before-saving', key: 'approvals' } as const
const turnRef = { plugin: 'ask-before-saving', key: 'turn' } as const

const TOOLS = new Set(['Write', 'Edit', 'Bash'])
const MINUTES = APPROVAL_MS / 60_000

// The saves Dan's own words made permanent, by what they write (saveKey): added by the tool.call
// hook and taken by the classic.PreToolUse hook beneath it as the call reaches it, so the call passes
// and nothing else does. In memory: both are one dispatch, which a reload cannot come between.
const approved = new Set<string>()
// The calls the classic hook let through on a For good approval, by tool_use_id, with where each
// saves to: read back by the tool.call hook above it in the same dispatch, to say what became of it.
const reissued = new Map<string, string>()

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

let saves = 0
const message = (err: unknown) => String((err as Error)?.message ?? err)

type Where = { cwd: string; home: string }
const whereOf = async ($: EngineInterface): Promise<Where> => {
  const home = (await $.env.get('HOME')) ?? ''
  return { home, cwd: await $.session.cwd() }
}

// Where a call would save lasting memory, as Dan reads it, or nothing when it saves none. A Bash
// call is read by mod-kit's one reader of what a command writes; a write its words do not name (a
// patch, an inline script) is judged by the lasting memory its text and any patch file it reads
// mention, and so is a target they cannot name, such as a variable (#743, lastingFiles). A file
// in a temporary folder counts inside a checkout there, found by mod-kit's one
// walk for it (#726). A file that exists and cannot be read, or a disk that cannot say whether a
// temporary file is in a checkout, fails the hook, and the hook fails closed.
const lastingTargets = async ($: EngineInterface, tool: string, input: Record<string, unknown>, { cwd, home }: Where): Promise<string[]> => {
  const inCheckout: InCheckout = async abs => (await $.modkit.workingTree({ path: abs })) !== null
  if (tool !== 'Bash') {
    const abs = resolvePath(String(input.file_path ?? ''), cwd, home)
    return (await lastingMemory(abs, home, inCheckout)) ? [display(abs, home)] : []
  }
  const command = String(input.command ?? '')
  const w = await $.modkit.writes({ command, cwd, home })
  const out = await lastingFiles(w, home, inCheckout, command)
  for (const u of w.unnamed) {
    const texts = [command]
    for (const f of u.inputs) if (await $.fs.exists(f)) texts.push(await $.fs.read(f))
    for (const t of texts) for (const m of await mentioned(t, home, inCheckout)) if (!out.includes(m)) out.push(m)
  }
  return out
}

// The first save waiting is the one asked; the rest wait behind it, each asked once the one before
// is answered. One that cannot be shown is refused rather than left unanswerable, Claude told why.
const showFirst = async ($: EngineInterface) => {
  for (;;) {
    const first = ((await $.state.get(pendingRef)).value ?? [])[0]
    if (!first) return
    try {
      await $.modkit.question(questionOf(first) as never)
      return
    } catch (err) {
      await update($, pendingRef, p => (p ?? []).filter(x => x.id !== first.id))
      const where = first.files.join(', ')
      $.ui.toast(`The question about saving to ${where} could not be shown: ${message(err)}`)
      await tell($, `The question asking Dan whether to save this to ${where} could not be shown (${message(err)}), so nothing was saved. Ask him in your reply instead.`)
    }
  }
}

// A note Claude reads at its next step, never shown to Dan as typed. A note that cannot be added is
// a toast carrying the whole note and why, so Dan sees what Claude was not told.
const tell = async ($: EngineInterface, text: string) => {
  let why: string | undefined
  try {
    const r = (await $.session.append({ message: { type: 'user', content: [{ type: 'text', text }] } })) as { deny?: string }
    if (r && typeof r.deny === 'string') why = r.deny
  } catch (err) {
    why = message(err)
  }
  if (why !== undefined) $.ui.toast(`Claude was not told: ${text} (${why})`, { timeoutMs: 10_000 })
}

// A prompt of Claude's own: a turn once the session is idle, where a note would wait unread for
// Dan's next message. One that cannot be submitted is a toast carrying the whole prompt and why.
const ask = async ($: EngineInterface, text: string) => {
  let why: string | undefined
  try {
    const r = (await $.prompt.submit({ text })) as { drop?: string }
    if (r && typeof r.drop === 'string') why = r.drop
  } catch (err) {
    why = message(err)
  }
  if (why !== undefined) $.ui.toast(`Claude was not asked: ${text} (${why})`, { timeoutMs: 10_000 })
}

const lapsedFor = (where: string) => `The For good you gave for saving to ${where} lapsed after ${MINUTES} minutes unused, so it no longer lets that save through.`

// Every approval past its time is taken out and said, to Dan and to Claude (L523): one Claude never
// used must not stand open, and must not lapse in silence either.
const lapse = async ($: EngineInterface) => {
  const now = await $.clock.now()
  let gone: AskBeforeSavingApproval[] = []
  await update($, approvalsRef, a => {
    gone = (a ?? []).filter(x => !stands(x.until, now))
    return (a ?? []).filter(x => stands(x.until, now))
  })
  for (const x of gone) {
    const where = x.files.join(', ')
    $.ui.toast(lapsedFor(where), { timeoutMs: 10_000 })
    await tell($, `Dan's For good on saving this to ${where} lapsed after ${MINUTES} minutes unused: it no longer lets that save through, and sending it again asks him again.`)
  }
}
// Times the lapse, never throwing: a timer that cannot be set is said, and whatever comes after it
// (telling Claude, the next approval at a session start) still runs. The approval is then refused on
// its age where it is used, and said at session end, so only the announcement on time is lost.
const lapseAfter = ($: EngineInterface, ms: number, where: string) => {
  try {
    $.clock.after(Math.max(0, ms), () => void lapse($).catch(err => $.ui.toast(`Ask before saving could not take out an approval past its time: ${message(err)}`)))
  } catch (err) {
    $.ui.toast(`The ${MINUTES} minute limit on For good for saving to ${where} could not be timed (${message(err)}), so nothing will say when it lapses; it still lapses then.`, { timeoutMs: 10_000 })
  }
}

// The approval for this save, taken as the call that uses it arrives, refused on its age there too
// (L567): a timer a reload dropped never said it lapsed. A lapsed one is taken out and said.
const takeApproval = async ($: EngineInterface, key: string) => {
  const now = await $.clock.now()
  let live: AskBeforeSavingApproval | undefined
  let lapsed: AskBeforeSavingApproval[] = []
  await update($, approvalsRef, a => {
    live = undefined
    lapsed = []
    const keep: AskBeforeSavingApproval[] = []
    for (const x of a ?? []) {
      if (x.key === key && !stands(x.until, now)) lapsed.push(x)
      else if (x.key === key && !live) live = x
      else keep.push(x)
    }
    return keep
  })
  for (const x of lapsed) $.ui.toast(lapsedFor(x.files.join(', ')), { timeoutMs: 10_000 })
  return { live: live as AskBeforeSavingApproval | undefined, lapsed: lapsed.length > 0 }
}

const REFUSED =
  'Not saved yet. Dan is being asked in the band above the prompt whether this is a standing rule: For good, Just this session, or Not at all. ' +
  'His answer reaches you as a note or a message; on For good you are asked to send this same call again, and that saves it. Until then, do not write it again.'
const LAPSED = `Dan's earlier For good on this save lapsed after ${MINUTES} minutes unused, so he is being asked again.`

export const register: Register = on => {
  // Dan's latest message of his own, typed or from his phone, read for the words that already make
  // a rule permanent. A peer session's or a plugin's message never counts.
  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind === 'composer' || e.origin.kind === 'bridge') await $.state.set(promptRef, e.text)
    return next(e)
  })

  // Dan's own words made it permanent: saved without asking, through every other mod's checks, and
  // Claude says what it saved. And a save Dan answered For good, sent again by Claude: what became of
  // it is said here, the one place its result can be read.
  for (const tool of TOOLS) {
    on('tool.call', { tool }, async ($, e, next) => {
      const raw = e as unknown as Record<string, unknown>
      const id = String(raw.tool_use_id ?? '')
      const input = argsOf(raw)
      let key: string | undefined
      let files: string[] = []
      if (madePermanent((await $.state.get(promptRef)).value)) {
        const at = await whereOf($)
        files = await lastingTargets($, tool, input, at)
        if (files.length) approved.add((key = saveKey(tool, input, at.cwd, at.home)))
      }
      let r: Awaited<ReturnType<typeof next>>
      let forGood: string | undefined
      try {
        r = await next(e)
      } finally {
        // Taken by the classic hook when the call reached it; dropped here when a guard refused first.
        if (key !== undefined) approved.delete(key)
        forGood = reissued.get(id)
        reissued.delete(id)
      }
      if (forGood !== undefined) {
        const why = r.deny ?? (r.isError ? (r.text ?? 'the tool reported an error') : undefined)
        if (why === undefined) return { ...r, context: [...(r.context ?? []), `Saved to ${forGood}, as Dan answered For good.`] }
        // Claude reads the failure in the result; Dan, who pressed For good, would otherwise not.
        $.ui.toast(`Not saved to ${forGood}: ${why}`, { timeoutMs: 10_000 })
        return r
      }
      if (!files.length || r.deny !== undefined || r.isError) return r
      return { ...r, context: [...(r.context ?? []), `Saved to ${files.join(', ')} without asking, because Dan's message made it a standing rule. Now say in one line what you saved and where.`] }
    }).catch(($, e, next) => ({ deny: cannotCheck(next.error) }))
  }

  // Asked here, beneath every mod's tool.call hook and after the settings hooks beneath this one, so
  // only a write every guard lets through is asked about.
  on('classic.PreToolUse', async ($, e, next) => {
    const tool = String(e.tool)
    if (!TOOLS.has(tool)) return next(e)
    const raw = e as unknown as Record<string, unknown>
    const input = argsOf(raw)
    const at = await whereOf($)
    const key = saveKey(tool, input, at.cwd, at.home)
    if (approved.delete(key)) return next(e)
    const files = await lastingTargets($, tool, input, at)
    if (!files.length) return next(e)
    // A save Dan answered For good, sent again: on to the settings hooks and the permission check
    // beneath (the auto mode classifier among them), never asked about again.
    const { live, lapsed } = await takeApproval($, key)
    if (live) {
      reissued.set(String(raw.tool_use_id ?? ''), live.files.join(', '))
      return next(e)
    }
    const refused = lapsed ? `${LAPSED} ${REFUSED}` : REFUSED
    // The settings hooks beneath (the payload write gate among them) decide first, so Dan is never
    // asked about a save one of them refuses (#707). next(e) here runs those hooks, never the write.
    const decided = await next(e)
    if (decided.deny !== undefined) return decided

    let text = String(input.command ?? '')
    if (tool === 'Edit') text = String(input.new_string ?? '')
    if (tool === 'Write') {
      // No file there yet: the whole content is what would be saved. One that exists and cannot be
      // read fails the hook, and the hook fails closed (below).
      const abs = resolvePath(String(input.file_path ?? ''), at.cwd, at.home)
      const old = (await $.fs.exists(abs)) ? await $.fs.read(abs) : undefined
      text = addedText(String(input.content ?? ''), old)
    }
    const q: AskBeforeSavingQuestion = { id: String(raw.tool_use_id ?? '') || `save-${++saves}`, tool: tool as AskBeforeSavingQuestion['tool'], input, files, text, key }
    const pending = await update($, pendingRef, p => [...(p ?? []), q])
    if (pending.length > 1) return { deny: refused }
    try {
      await $.modkit.question(questionOf(q) as never)
    } catch (err) {
      // Nobody can answer a question the band cannot show, so the save is refused, never let through.
      // Taken back out so it can never be answered later; if even that fails, the hook throws and
      // its catch refuses the write all the same.
      await update($, pendingRef, p => (p ?? []).filter(x => x.id !== q.id))
      const where = files.join(', ')
      $.ui.toast(`The question about saving to ${where} could not be shown: ${message(err)}`)
      // A save queued behind this one meanwhile is now at the front, and nothing else would show it.
      await showFirst($)
      return { deny: `Not saved: the question asking Dan whether this is a standing rule could not be shown (${message(err)}). Ask him in your reply instead.` }
    }
    return { deny: refused }
  }).catch(($, e, next) => ({ deny: cannotCheck(next.error) }))

  // A press carries the answer and the save it was drawn for: "<answer>:<save id>".
  on('ui.press', { plugin: 'mod-kit' }, async ($, e, next) => {
    if (!e.element.startsWith(`${MOD}:`)) return next(e)
    const [choice, ...id] = e.element.slice(MOD.length + 1).split(':')
    const known = ANSWERS.find(a => a.button === choice)
    if (known) await answer($, known.button, id.join(':'))
    return { element: e.element }
  })

  // Whether Claude is working on the main loop, so For good reaches it the way it will read: a note
  // at its next step while it works, a prompt of its own once it is idle (#738). In $.state, so a
  // reload in the middle of a turn still knows it runs. A subagent's run raises no turn.start.
  on('turn.start', async ($, e, next) => {
    await $.state.set(turnRef, e.turnId)
    return next(e)
  })
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined) return r
    await $.state.set(turnRef, null)
    // A note added while the turn's last answer was being written is read by nobody, so a save it
    // asked for that has not come is asked for again as a prompt, once, now that the turn is over.
    let unread: AskBeforeSavingApproval[] = []
    await update($, approvalsRef, a => {
      unread = (a ?? []).filter(x => x.told === 'note')
      return (a ?? []).map(x => (x.told === 'note' ? { ...x, told: 'prompt' as const } : x))
    })
    // Not awaited, so this hook never waits on the turn the prompt starts; ask says its own failure.
    for (const x of unread) void ask($, x.text)
    return r
  })

  // A reload drops the module's timers, never its approvals: each one waiting is timed again. And no
  // turn is running as a session starts, whatever a process that stopped mid-turn left marked: a
  // note would wait unread, where a prompt runs (a reload in the middle of a turn costs only that
  // the prompt waits for the turn to end).
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    await $.state.set(turnRef, null)
    const waiting = (await $.state.get(approvalsRef)).value ?? []
    if (waiting.length) {
      const now = await $.clock.now()
      for (const x of waiting) lapseAfter($, lapseWait(x.until, now), x.files.join(', '))
    }
    return r
  })

  // The rules Dan gave for this session only ride the system prompt's memory section, which is
  // assembled afresh for every request, so a compaction of the conversation keeps them.
  on('prompt.section', { name: 'memory' }, async ($, e, next) => {
    const r = await next(e)
    const rules = (await $.state.get(rulesRef)).value ?? []
    if (!rules.length) return r
    const section = ['# Rules for this session only', 'Dan gave these for this session only. Follow them until the session ends, and never save them to memory.', ...rules.map(x => `- ${x.replace(/\n/g, '\n  ')}`)].join('\n')
    return { text: r.text ? `${r.text}\n\n${section}` : section }
  })

  // Dropped at session end, a /clear included: nothing of this session's answers outlives it.
  on('session.end', async ($, e, next) => {
    const shown = ((await $.state.get(pendingRef)).value ?? [])[0]
    const unused = (await $.state.get(approvalsRef)).value ?? []
    await $.state.set(rulesRef, [])
    await $.state.set(pendingRef, [])
    await $.state.set(promptRef, null)
    await $.state.set(approvalsRef, [])
    await $.state.set(turnRef, null)
    $.ui.invalidate('prompt.section')
    // At session end there is nobody left to tell, and a row left behind has no question under it:
    // a press then finds nothing pending and does nothing.
    if (shown) await $.modkit.clearBandRow({ mod: MOD, id: rowId(shown.id) }).catch(() => undefined)
    // Dan pressed For good believing it saved; one Claude never sent again is said, not dropped quietly.
    for (const x of unused) $.ui.toast(`The For good you gave for saving to ${x.files.join(', ')} was never used before the session ended, so it no longer lets that save through.`, { timeoutMs: 10_000 })
    return next(e)
  })
}

const answer = async ($: EngineInterface, choice: Answer, id: string) => {
  let q: AskBeforeSavingQuestion | undefined
  await update($, pendingRef, p => {
    q = (p ?? []).find(x => x.id === id)
    return (p ?? []).filter(x => x.id !== id)
  })
  // Already answered (a second press), or gone at session end: nothing to do.
  if (!q) return
  const where = q.files.join(', ')
  // Taken out of the queue already, so Dan's answer is carried through whatever the band does: a
  // question left drawn is said, never allowed to lose the answer.
  try {
    await $.modkit.clearBandRow({ mod: MOD, id: rowId(q.id) })
  } catch (err) {
    $.ui.toast(`The question about saving to ${where} could not be taken out of the band: ${message(err)}`)
  }
  await showFirst($)

  if (choice === 'not-at-all') {
    await tell($, `Dan answered Not at all to saving this to ${where}: nothing was saved. Do not save it.`)
    return
  }
  if (choice === 'this-session') {
    const text = q.text
    await update($, rulesRef, r => [...(r ?? []), text])
    $.ui.invalidate('prompt.section')
    await tell($, `Dan answered Just this session to saving this to ${where}: nothing was written. It is in your system prompt as a rule for this session only.`)
    return
  }
  // For good (#738): approved by what it saves (the key taken where Dan was asked, so the file he was
  // shown), for a while, and Claude asked to send the call again, given whole, since the call may not
  // be Claude's own (the memory writer's, a subagent's) or may have been compacted away.
  const save = q
  let approval: AskBeforeSavingApproval | undefined
  try {
    const key = save.key ?? (await whereOf($).then(at => saveKey(save.tool, save.input, at.cwd, at.home)))
    const now = await $.clock.now()
    const running = (await $.state.get(turnRef)).value != null
    const text =
      `Dan answered For good to saving this to ${where}. Send the same ${save.tool} call again now, unchanged, and it is saved without asking him again: ` +
      `${callShown(save.tool, save.input)}. If it is not sent within ${MINUTES} minutes, this lapses.`
    const made: AskBeforeSavingApproval = { id: save.id, key, files: save.files, until: now + APPROVAL_MS, told: running ? 'note' : 'prompt', text }
    await update($, approvalsRef, a => [...(a ?? []), made])
    approval = made
  } catch (err) {
    // Nothing recorded the approval, so nothing would let the save through: said, never lost.
    $.ui.toast(`For good on saving to ${where} could not be recorded (${message(err)}), so nothing was saved.`, { timeoutMs: 10_000 })
    await tell($, `Dan answered For good to saving this to ${where}, but it could not be recorded (${message(err)}), so nothing was saved. Ask him in your reply instead.`)
    return
  }
  // Recorded: from here a failure is said by what failed (the timer, the note, the prompt), never as
  // an approval that was not recorded, and none of them stops Claude being asked.
  lapseAfter($, APPROVAL_MS, where)
  if (approval.told === 'note') await tell($, approval.text)
  else await ask($, approval.text)
}
