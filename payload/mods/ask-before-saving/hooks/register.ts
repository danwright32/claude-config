import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { AskBeforeSavingQuestion } from '../types/index.d.ts'
import { ANSWERS, type Answer, MOD, addedText, bashTargets, display, lastingMemory, madePermanent, questionRow, resolvePath } from './rules.ts'

// Ask before saving (claude-config#618). Before a standing rule reaches lasting memory, by Write,
// Edit or Bash, Dan is asked in the band: For good, Just this session, or Not at all. Settled with
// Dan on 2026-10-03 (the spec) and 2026-10-04 (the question's shape, docs/mods-design.md).
//
// The write is refused at once rather than held open while Dan reads: a tool call hook waiting on a
// band press is cut at its 10 second budget, and the engine then runs the write as if the hook were
// absent (measured 2026-10-04 with `claude plugin test`). Holding it would fail open. So the call is
// refused, the question waits in the band with the prompt free, and For good replays the call
// exactly as Claude sent it, through every other mod's checks again.

const pendingRef = { plugin: 'ask-before-saving', key: 'pending' } as const
const rulesRef = { plugin: 'ask-before-saving', key: 'rules' } as const
const promptRef = { plugin: 'ask-before-saving', key: 'lastPrompt' } as const

// The one call each For good approved, by its exact arguments, so the replay passes and nothing
// else does. In memory: a reload between the press and the replay cannot happen (one handler).
const approved = new Set<string>()
const fingerprint = (tool: string, input: Record<string, unknown>) =>
  JSON.stringify([tool, Object.keys(input).sort().map(k => [k, input[k]])])

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

const show = async ($: EngineInterface, pending: AskBeforeSavingQuestion[]) => {
  const first = pending[0]
  if (first) await $.modkit.bandRow(questionRow(first) as never)
  else await $.modkit.clearBandRow({ mod: MOD, id: 'question' })
}

// A note Claude reads at its next step, never shown to Dan as typed. A note that cannot be added is
// a toast carrying the whole note and why, so Dan sees what Claude was not told.
const tell = async ($: EngineInterface, text: string) => {
  let why: string | undefined
  try {
    const r = (await $.session.append({ message: { type: 'user', content: [{ type: 'text', text }] } })) as { deny?: string }
    if (r && typeof r.deny === 'string') why = r.deny
  } catch (err) {
    why = String((err as Error)?.message ?? err)
  }
  if (why !== undefined) $.ui.toast(`Claude was not told: ${text} (${why})`, { timeoutMs: 10_000 })
}

const REFUSED =
  'Not saved yet. Dan is being asked in the band above the prompt whether this is a standing rule: For good, Just this session, or Not at all. ' +
  'His answer reaches you as a note, and For good saves it exactly as you wrote it here. Do not write it again.'

export const register: Register = on => {
  // Dan's latest message of his own, typed or from his phone, read for the words that already make
  // a rule permanent ("from now on", "always", "never", "remember").
  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind === 'composer' || e.origin.kind === 'bridge') await $.state.set(promptRef, e.text)
    return next(e)
  })

  for (const tool of ['Write', 'Edit', 'Bash'] as const) {
    on('tool.call', { tool }, async ($, e, next) => {
      const raw = e as unknown as Record<string, unknown>
      const input = argsOf(raw)
      if (approved.delete(fingerprint(tool, input))) return next(e)

      const home = (await $.env.get('HOME')) ?? ''
      const cwd = await $.session.cwd()
      const named =
        tool === 'Bash' ? bashTargets(await $.modkit.commands({ command: String(input.command ?? '') })) : [String(input.file_path ?? '')]
      const files = [...new Set(named.map(p => resolvePath(p, cwd, home)).filter(p => lastingMemory(p, home)))]
      if (!files.length) return next(e)
      const where = files.map(f => display(f, home)).join(', ')

      // Dan's own words made it permanent: saved without asking, and Claude says what it saved.
      if (madePermanent((await $.state.get(promptRef)).value)) {
        const r = await next(e)
        if (r.deny !== undefined || r.isError) return r
        return { ...r, context: [...(r.context ?? []), `Saved to ${where} without asking, because Dan's message made it a standing rule. Now say in one line what you saved and where.`] }
      }

      let text = String(input.command ?? '')
      if (tool === 'Edit') text = String(input.new_string ?? '')
      if (tool === 'Write') {
        // No file there yet: the whole content is what would be saved. One that exists and cannot be
        // read fails the hook, and the hook fails closed (below).
        const first = files[0] as string
        const old = (await $.fs.exists(first)) ? await $.fs.read(first) : undefined
        text = addedText(String(input.content ?? ''), old)
      }
      const q: AskBeforeSavingQuestion = { id: String(raw.tool_use_id ?? ''), tool, input, files: files.map(f => display(f, home)), text }
      try {
        const pending = await update($, pendingRef, p => [...(p ?? []), q])
        await show($, pending)
      } catch (err) {
        // Nobody can answer a question the band cannot show, so the save is refused, never let through.
        // Taken back out so it can never be answered later; if even that fails, the hook throws and
        // its catch refuses the write all the same.
        await update($, pendingRef, p => (p ?? []).filter(x => x.id !== q.id))
        const why = String((err as Error)?.message ?? err)
        $.ui.toast(`The question about saving to ${where} could not be shown: ${why}`)
        return { deny: `Not saved: the question asking Dan whether this is a standing rule could not be shown (${why}). Ask him in your reply instead.` }
      }
      return { deny: REFUSED }
    }).catch(($, e) => ({
      // A hook that throws is skipped and the write runs, so anything this hook cannot finish refuses.
      deny: `Not saved: Ask before saving could not check whether this writes lasting memory (${String(e.error?.message ?? 'it failed')}). Tell Dan what you meant to save instead.`,
    }))
  }

  for (const a of ANSWERS) {
    on('ui.press', { plugin: 'mod-kit', element: `${MOD}:${a.button}` }, async ($, e) => {
      await answer($, a.button)
      return { element: e.element }
    })
  }

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
    await $.state.set(rulesRef, [])
    await $.state.set(pendingRef, [])
    await $.state.set(promptRef, null)
    $.ui.invalidate('prompt.section')
    // At session end there is nobody left to tell, and a row left behind has no question under it:
    // a press then finds nothing pending and does nothing.
    await $.modkit.clearBandRow({ mod: MOD, id: 'question' }).catch(() => undefined)
    return next(e)
  })
}

const answer = async ($: EngineInterface, choice: Answer) => {
  let q: AskBeforeSavingQuestion | undefined
  const rest = await update($, pendingRef, p => {
    q = (p ?? [])[0]
    return (p ?? []).slice(1)
  })
  await show($, rest)
  if (!q) return
  const where = q.files.join(', ')

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
    failure = String((err as Error)?.message ?? err)
  } finally {
    // Consumed by the replay when it reached this mod; dropped here when another hook refused first.
    approved.delete(key)
  }
  if (failure !== undefined) {
    $.ui.toast(`Not saved to ${where}: ${failure}`)
    await tell($, `Dan answered For good, but it could not be saved to ${where}: ${failure}`)
    return
  }
  await tell($, `Dan answered For good: saved to ${where}.`)
}
