import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { AskBeforeSavingQuestion } from '../types/index.d.ts'
import { ANSWERS, type Answer, MOD, addedText, display, lastingFiles, lastingMemory, madePermanent, mentioned, questionOf, resolvePath, rowId } from './rules.ts'

// Ask before saving (claude-config#618). Before a standing rule reaches lasting memory, by Write,
// Edit or Bash, Dan is asked in the band: For good, Just this session, or Not at all. Settled with
// Dan on 2026-10-03 (the spec) and 2026-10-04 (the question's shape, docs/mods-design.md).
//
// The write is refused at once rather than held open while Dan reads: a tool call hook waiting on a
// band press is cut at its 10 second budget, and the engine then runs the write as if the hook were
// absent (measured 2026-10-04 with `claude plugin test`). Holding it would fail open. So the call is
// refused, the question waits in the band with the prompt free, and For good replays the call
// exactly as Claude sent it, through every other mod's checks again.
//
// The question is asked from classic.PreToolUse, which the engine raises beneath every mod's
// tool.call hook (#705): a write the style check, the secret guard or no build refuses is refused
// before Dan is asked about it, whatever order the mods load in, so he is never asked to approve a
// save that cannot land. The skip for Dan's own permanent words stays a tool.call hook, the one
// place the saved result can be read, to tell Claude to say what it saved.

const pendingRef = { plugin: 'ask-before-saving', key: 'pending' } as const
const rulesRef = { plugin: 'ask-before-saving', key: 'rules' } as const
const promptRef = { plugin: 'ask-before-saving', key: 'lastPrompt' } as const

const TOOLS = new Set(['Write', 'Edit', 'Bash'])

// The calls let through without asking, by their exact arguments: one For good approved, or one Dan's
// own words made permanent. Taken by the classic.PreToolUse hook as the call reaches it, so the call
// passes and nothing else does. In memory: a reload between the two cannot happen (one dispatch).
const approved = new Set<string>()
const fingerprint = (tool: string, input: Record<string, unknown>) =>
  JSON.stringify([tool, Object.keys(input).sort().map(k => [k, input[k]])])

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

let saves = 0
const message = (err: unknown) => String((err as Error)?.message ?? err)

// Where a call would save lasting memory, as Dan reads it, or nothing when it saves none. A Bash
// call is read by mod-kit's one reader of what a command writes; a write its words do not name (a
// patch, an inline script) is judged by the lasting memory its text and any patch file it reads
// mention. A file that exists and cannot be read fails the hook, and the hook fails closed.
const lastingTargets = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<string[]> => {
  const home = (await $.env.get('HOME')) ?? ''
  const cwd = await $.session.cwd()
  if (tool !== 'Bash') {
    const abs = resolvePath(String(input.file_path ?? ''), cwd, home)
    return lastingMemory(abs, home) ? [display(abs, home)] : []
  }
  const command = String(input.command ?? '')
  const w = await $.modkit.writes({ command, cwd, home })
  const out = lastingFiles(w, home)
  for (const u of w.unnamed) {
    const texts = [command]
    for (const f of u.inputs) if (await $.fs.exists(f)) texts.push(await $.fs.read(f))
    for (const m of texts.flatMap(t => mentioned(t, home))) if (!out.includes(m)) out.push(m)
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

const REFUSED =
  'Not saved yet. Dan is being asked in the band above the prompt whether this is a standing rule: For good, Just this session, or Not at all. ' +
  'His answer reaches you as a note, and For good saves it exactly as you wrote it here. Do not write it again.'

const cannotCheck = (why: string | undefined) =>
  `Not saved: Ask before saving could not check whether this writes lasting memory (${why ?? 'it failed'}). Tell Dan what you meant to save instead.`

export const register: Register = on => {
  // Dan's latest message of his own, typed or from his phone, read for the words that already make
  // a rule permanent. A peer session's or a plugin's message never counts.
  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind === 'composer' || e.origin.kind === 'bridge') await $.state.set(promptRef, e.text)
    return next(e)
  })

  // Dan's own words made it permanent: saved without asking, through every other mod's checks, and
  // Claude says what it saved.
  for (const tool of TOOLS) {
    on('tool.call', { tool }, async ($, e, next) => {
      const input = argsOf(e as unknown as Record<string, unknown>)
      const key = fingerprint(tool, input)
      // A For good replay: the classic.PreToolUse hook takes its approval.
      if (approved.has(key)) return next(e)
      if (!madePermanent((await $.state.get(promptRef)).value)) return next(e)
      const files = await lastingTargets($, tool, input)
      if (!files.length) return next(e)
      approved.add(key)
      let r: Awaited<ReturnType<typeof next>>
      try {
        r = await next(e)
      } finally {
        // Taken by the classic hook when the call reached it; dropped here when a guard refused first.
        approved.delete(key)
      }
      if (r.deny !== undefined || r.isError) return r
      return { ...r, context: [...(r.context ?? []), `Saved to ${files.join(', ')} without asking, because Dan's message made it a standing rule. Now say in one line what you saved and where.`] }
    }).catch(($, e) => ({ deny: cannotCheck(e.error?.message) }))
  }

  // Asked here, beneath every mod's tool.call hook and after the settings hooks beneath this one, so
  // only a write every guard lets through is asked about.
  on('classic.PreToolUse', async ($, e, next) => {
    const tool = String(e.tool)
    if (!TOOLS.has(tool)) return next(e)
    const raw = e as unknown as Record<string, unknown>
    const input = argsOf(raw)
    if (approved.delete(fingerprint(tool, input))) return next(e)
    const files = await lastingTargets($, tool, input)
    if (!files.length) return next(e)
    // The settings hooks beneath (the payload write gate among them) decide first, so Dan is never
    // asked about a save one of them refuses (#707). next(e) here runs those hooks, never the write.
    const decided = await next(e)
    if (decided.deny !== undefined) return decided

    let text = String(input.command ?? '')
    if (tool === 'Edit') text = String(input.new_string ?? '')
    if (tool === 'Write') {
      // No file there yet: the whole content is what would be saved. One that exists and cannot be
      // read fails the hook, and the hook fails closed (below).
      const abs = resolvePath(String(input.file_path ?? ''), await $.session.cwd(), (await $.env.get('HOME')) ?? '')
      const old = (await $.fs.exists(abs)) ? await $.fs.read(abs) : undefined
      text = addedText(String(input.content ?? ''), old)
    }
    const q: AskBeforeSavingQuestion = { id: String(raw.tool_use_id ?? '') || `save-${++saves}`, tool: tool as AskBeforeSavingQuestion['tool'], input, files, text }
    const pending = await update($, pendingRef, p => [...(p ?? []), q])
    if (pending.length > 1) return { deny: REFUSED }
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
    return { deny: REFUSED }
  }).catch(($, e) => ({ deny: cannotCheck(e.error?.message) }))

  // A press carries the answer and the save it was drawn for: "<answer>:<save id>".
  on('ui.press', { plugin: 'mod-kit' }, async ($, e, next) => {
    if (!e.element.startsWith(`${MOD}:`)) return next(e)
    const [choice, ...id] = e.element.slice(MOD.length + 1).split(':')
    const known = ANSWERS.find(a => a.button === choice)
    if (known) await answer($, known.button, id.join(':'))
    return { element: e.element }
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
    await $.state.set(rulesRef, [])
    await $.state.set(pendingRef, [])
    await $.state.set(promptRef, null)
    $.ui.invalidate('prompt.section')
    // At session end there is nobody left to tell, and a row left behind has no question under it:
    // a press then finds nothing pending and does nothing.
    if (shown) await $.modkit.clearBandRow({ mod: MOD, id: rowId(shown.id) }).catch(() => undefined)
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
  // For good: the call exactly as Claude sent it, approved once, through every other mod again.
  const key = fingerprint(q.tool, q.input)
  approved.add(key)
  let failure: string | undefined
  try {
    const r = (await $.tool.call({ tool: q.tool, ...q.input, consent: `The user pressed "For good" on the question whether to save this to ${where}.` } as never)) as {
      deny?: string
      isError?: boolean
      text?: string
    }
    if (r.deny !== undefined) failure = r.deny
    else if (r.isError) failure = r.text ?? 'the tool reported an error'
  } catch (err) {
    failure = message(err)
  } finally {
    // Taken by the replay when it reached the classic hook; dropped here when another hook refused first.
    approved.delete(key)
  }
  if (failure !== undefined) {
    $.ui.toast(`Not saved to ${where}: ${failure}`)
    await tell($, `Dan answered For good, but it could not be saved to ${where}: ${failure}`)
    return
  }
  await tell($, `Dan answered For good: saved to ${where}.`)
}
