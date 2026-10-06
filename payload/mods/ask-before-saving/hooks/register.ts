import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { AskBeforeSavingApproval, AskBeforeSavingQuestion } from '../types/index.d.ts'
import {
  APPROVAL_MS,
  FOR_GOOD,
  HEADER,
  type InCheckout,
  type IsSet,
  NOT_AT_ALL,
  THIS_SESSION,
  addedText,
  askInstruction,
  callShown,
  cannotCheck,
  dialogOptions,
  display,
  lapseWait,
  lastingFiles,
  lastingMemory,
  madePermanent,
  mentioned,
  resolvePath,
  ruleOf,
  saveIdOf,
  saveKey,
  stands,
} from './rules.ts'

// Ask before saving (claude-config#618). Before a standing rule reaches lasting memory, by Write,
// Edit or Bash, Dan decides: For good, Just this session, or Not at all. Settled with Dan on
// 2026-10-03 (the spec), 2026-10-04 (the question's shape) and 2026-10-05 (#777, below).
//
// Claude Code's own question dialog asks (#777, after #744 decided it for every question): the write
// is refused with an instruction to Claude to ask Dan with AskUserQuestion, naming the file and the
// rule in plain words, tied to the save by `metadata.source`. The mod reads Dan's answer from that
// dialog's own result, the one place it comes from him: For good approves the identical write once
// (#738), and Claude is told so in the same result, so the instruction to send the call again reaches
// the loop that asked and nobody else. The write is never held open while Dan reads: a hook waiting
// on him is cut at its 10 second budget and the write then runs as if the hook were absent.
//
// A subagent's write to lasting memory is refused and never asked about (#777): only the main session
// asks Dan. Its call ran in its own tree and conversation, so neither the question nor the call sent
// again belongs in the main session, where a For good once asked the main loop to run a subagent's
// edit in the wrong checkout. Claude Code's own background loops (the memory writer) carry an id no
// agent list names; their refusal is also told to the main session, which may save it itself.
//
// The question is refused for from classic.PreToolUse, which the engine raises beneath every mod's
// tool.call hook (#705): a write another guard or a settings hook refuses is refused before Dan is
// asked about it (#707). The skip for Dan's own permanent words stays a tool.call hook, the one place
// the saved result can be read, as does what Claude is told of a save sent again after For good.

const pendingRef = { plugin: 'ask-before-saving', key: 'pending' } as const
const rulesRef = { plugin: 'ask-before-saving', key: 'rules' } as const
const promptRef = { plugin: 'ask-before-saving', key: 'lastPrompt' } as const
const approvalsRef = { plugin: 'ask-before-saving', key: 'approvals' } as const

const TOOLS = new Set(['Write', 'Edit', 'Bash'])
const MINUTES = APPROVAL_MS / 60_000

// The saves Dan's own words made permanent, by what they write (saveKey): added by the tool.call
// hook and taken by the classic.PreToolUse hook beneath it as the call reaches it, so the call passes
// and nothing else does. In memory: both are one dispatch, which a reload cannot come between.
const approved = new Set<string>()
// A subagent's calls the tool.call hook judged and let through, by what they write: the classic hook
// beneath, which cannot see which loop a call runs in, never asks the main session about them. A main
// session call with the same key meanwhile is no hole: the key is everything the judgement reads, so
// it writes no lasting memory either. Counted per key, so one of two identical calls finishing never
// clears the other's mark while it is still on its way down (lessons review of #783).
const fromAgent = new Map<string, number>()
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

// Whether a variable can reach a Bash call's fresh shell without the command naming it (#777): set
// in Claude Code's environment, which every shell it starts inherits, or in a shell profile. Asked
// only for a variable a mention of lasting memory is built from. $.env.get takes literal names alone,
// so the environment is asked through printenv (exit 0: set, exit 1: unset). A printenv that cannot
// run or fails, or a profile that exists and cannot be read, fails the hook, which fails closed.
const PROFILES = ['.zshenv', '.zprofile', '.zshrc', '.bash_profile', '.bashrc', '.profile']
const isSetIn = async ($: EngineInterface, home: string): Promise<IsSet> => {
  let profiles: string | undefined
  return async name => {
    // Exit 0 is set and exit 1 is unset; any other answer is printenv failing, which must refuse the
    // save rather than read as unset (lessons review of #783).
    const env = await $.process.run(['/usr/bin/printenv', name], { timeoutMs: 5000 })
    if (env.exitCode === 0) return true
    if (env.exitCode !== 1) throw new Error(`printenv ${name} failed with exit ${env.exitCode}: ${env.stderr.trim() || 'no message'}`)
    if (profiles === undefined) {
      const texts: string[] = []
      for (const p of PROFILES) {
        const path = `${home.replace(/\/$/, '')}/${p}`
        if (await $.fs.exists(path)) texts.push(await $.fs.read(path))
      }
      profiles = texts.join('\n')
    }
    return new RegExp(`(^|[^$\\w])${name}=`, 'm').test(profiles)
  }
}

// Where a call would save lasting memory, as Dan reads it, or nothing when it saves none. A Bash
// call is read by mod-kit's one reader of what a command writes; a write its words do not name (a
// patch, an inline script) is judged by the lasting memory its text and any patch file it reads
// mention, and so is a target they cannot name, such as a variable (#743, lastingFiles); a mention
// through a variable nothing can set is none (#777). A file in a temporary folder counts inside a
// checkout there, found by mod-kit's one walk for it (#726). A file that exists and cannot be read,
// or a disk that cannot say whether a temporary file is in a checkout, fails the hook, and the hook
// fails closed.
const lastingTargets = async ($: EngineInterface, tool: string, input: Record<string, unknown>, { cwd, home }: Where): Promise<string[]> => {
  const inCheckout: InCheckout = async abs => (await $.modkit.workingTree({ path: abs })) !== null
  if (tool !== 'Bash') {
    const abs = resolvePath(String(input.file_path ?? ''), cwd, home)
    return (await lastingMemory(abs, home, inCheckout)) ? [display(abs, home)] : []
  }
  const command = String(input.command ?? '')
  const isSet = await isSetIn($, home)
  const w = await $.modkit.writes({ command, cwd, home })
  const out = await lastingFiles(w, home, inCheckout, command, isSet)
  for (const u of w.unnamed) {
    const texts = [command]
    for (const f of u.inputs) if (await $.fs.exists(f)) texts.push(await $.fs.read(f))
    for (const t of texts) for (const m of await mentioned(t, home, inCheckout, isSet)) if (!out.includes(m)) out.push(m)
  }
  return out
}

// What would be saved, as the rule's text: a new file's whole text, the lines a rewrite adds, an
// Edit's new text, a Bash command as written. Claude reads it; Dan reads Claude's plain words.
const savedText = async ($: EngineInterface, tool: string, input: Record<string, unknown>, at: Where): Promise<string> => {
  if (tool === 'Edit') return String(input.new_string ?? '')
  if (tool !== 'Write') return String(input.command ?? '')
  // No file there yet: the whole content is what would be saved. One that exists and cannot be read
  // fails the hook, and the hook fails closed.
  const abs = resolvePath(String(input.file_path ?? ''), at.cwd, at.home)
  const old = (await $.fs.exists(abs)) ? await $.fs.read(abs) : undefined
  return addedText(String(input.content ?? ''), old)
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

// What Dan reads when an approval lapses: unused, or sent and refused by another guard before it
// was saved, which is never called unused (#764, L11).
const lapsedFor = (x: AskBeforeSavingApproval) => {
  const where = x.files.join(', ')
  return x.refused !== undefined
    ? `The For good you gave for saving to ${where} lapsed after ${MINUTES} minutes: Claude sent the save, but it was refused before it was saved (${x.refused}), and it was not sent again in time.`
    : `The For good you gave for saving to ${where} lapsed after ${MINUTES} minutes unused, so it no longer lets that save through.`
}

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
    $.ui.toast(lapsedFor(x), { timeoutMs: 10_000 })
    await tell(
      $,
      x.refused !== undefined
        ? `Dan's For good on saving this to ${where} lapsed after ${MINUTES} minutes: the save you sent was refused before it was saved (${x.refused}), so nothing was saved, and sending it again asks him again.`
        : `Dan's For good on saving this to ${where} lapsed after ${MINUTES} minutes unused: it no longer lets that save through, and sending it again asks him again.`,
    )
  }
}
// Times the lapse, never throwing: a timer that cannot be set is said. The approval is then refused
// on its age where it is used, and said at session end, so only the announcement on time is lost.
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
  for (const x of lapsed) $.ui.toast(lapsedFor(x), { timeoutMs: 10_000 })
  return { live: live as AskBeforeSavingApproval | undefined, lapsed: lapsed[0] as AskBeforeSavingApproval | undefined }
}

// What Claude reads when the approval for the call it sent has lapsed (#764: never "unused" for one
// it sent that another guard refused).
const lapsedNote = (x: AskBeforeSavingApproval) =>
  x.refused !== undefined
    ? `Dan's earlier For good on this save lapsed after ${MINUTES} minutes; the save you sent before was refused (${x.refused}), so he has to be asked again.`
    : `Dan's earlier For good on this save lapsed after ${MINUTES} minutes unused, so he has to be asked again.`

// What a subagent is told when its write would save lasting memory: refused, never asked (#777).
const agentRefusal = (where: string) =>
  `Not saved: this would write lasting memory (${where}), which only the main session may do, after asking Dan; a subagent never asks him. ` +
  `If this is not a save to memory (a test fixture, or a file whose text only mentions one), make the change with Edit or Write on the file itself. ` +
  `If it is a standing rule, put the rule and the file in your final report, and the main session will ask him.`

type AskInput = { questions?: { question?: unknown; header?: unknown; options?: unknown; multiSelect?: unknown }[]; answers?: unknown; metadata?: { source?: unknown } }
type AskResult = { answers?: Record<string, unknown>; questions?: { question?: unknown }[]; response?: unknown; afkTimeoutMs?: unknown }

export const register: Register = on => {
  // Dan's latest message of his own, typed or from his phone, read for the words that already make
  // a rule permanent. A peer session's or a plugin's message never counts.
  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind === 'composer' || e.origin.kind === 'bridge') await $.state.set(promptRef, e.text)
    return next(e)
  })

  for (const tool of TOOLS) {
    on('tool.call', { tool }, async ($, e, next) => {
      const raw = e as unknown as Record<string, unknown>
      const id = String(raw.tool_use_id ?? '')
      const input = argsOf(raw)

      // A subagent's call (#777): judged here, where the loop is known, refused when it would save
      // lasting memory, and never asked about. One the classic hook beneath must let through.
      if (e.agentId !== undefined) {
        const at = await whereOf($)
        const files = await lastingTargets($, tool, input, at)
        if (files.length) {
          const where = files.join(', ')
          const listed = (await $.agent.list()).some(a => a.id === e.agentId)
          // Claude Code's own background loop (the memory writer): the main session decides with Dan.
          if (!listed)
            await tell(
              $,
              `A background loop of Claude Code's (the memory writer, or another agent no list names) tried to save to ${where} and was refused, so nothing was saved. ` +
                `What it would have saved: ${await savedText($, tool, input, at)}. If it is worth keeping, save it yourself, and you will be told how to ask Dan first.`,
            )
          return { deny: agentRefusal(where) }
        }
        const key = saveKey(tool, input, at.cwd, at.home)
        fromAgent.set(key, (fromAgent.get(key) ?? 0) + 1)
        try {
          return await next(e)
        } finally {
          const left = (fromAgent.get(key) ?? 1) - 1
          if (left > 0) fromAgent.set(key, left)
          else fromAgent.delete(key)
        }
      }

      // Dan's own words made it permanent: saved without asking, through every other mod's checks, and
      // Claude says what it saved. And a save Dan answered For good, sent again: what became of it is
      // said here, the one place its result can be read.
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
      // A save Dan answered For good, sent again, refused by another guard before the classic hook
      // could take its approval (#764): Dan is told now that it did not go through, and the approval,
      // which still stands for a later send, records why, so its lapse never calls it unused.
      if (forGood === undefined && r.deny !== undefined && ((await $.state.get(approvalsRef)).value ?? []).length) {
        const at = await whereOf($)
        const k = saveKey(tool, input, at.cwd, at.home)
        // Typed through a cast: the assignment is inside a callback, which narrowing cannot see (lessons review of #806).
        let hit = undefined as AskBeforeSavingApproval | undefined
        await update($, approvalsRef, a => (a ?? []).map(x => (x.key === k ? (hit = { ...x, refused: String(r.deny) }) : x)))
        if (hit) $.ui.toast(`Not saved to ${hit.files.join(', ')}: ${r.deny}`, { timeoutMs: 10_000 })
        return r
      }
      if (forGood !== undefined) {
        const why = r.deny ?? (r.isError ? (r.text ?? 'the tool reported an error') : undefined)
        if (why === undefined) return { ...r, context: [...(r.context ?? []), `Saved to ${forGood}, as Dan answered For good.`] }
        // Claude reads the failure in the result; Dan, who answered For good, would otherwise not.
        $.ui.toast(`Not saved to ${forGood}: ${why}`, { timeoutMs: 10_000 })
        return r
      }
      if (!files.length || r.deny !== undefined || r.isError) return r
      return { ...r, context: [...(r.context ?? []), `Saved to ${files.join(', ')} without asking, because Dan's message made it a standing rule. Now say in one line what you saved and where.`] }
    }).catch(($, e, next) => ({ deny: cannotCheck(next.error) }))
  }

  // Refused here, beneath every mod's tool.call hook and after the settings hooks beneath this one, so
  // Claude is told to ask only about a write every guard lets through.
  on('classic.PreToolUse', async ($, e, next) => {
    const tool = String(e.tool)
    if (!TOOLS.has(tool)) return next(e)
    const raw = e as unknown as Record<string, unknown>
    const input = argsOf(raw)
    const at = await whereOf($)
    const key = saveKey(tool, input, at.cwd, at.home)
    if (approved.delete(key) || fromAgent.has(key)) return next(e)
    const files = await lastingTargets($, tool, input, at)
    if (!files.length) return next(e)
    // A save Dan answered For good, sent again: on to the settings hooks and the permission check
    // beneath (the auto mode classifier among them), never asked about again.
    const { live, lapsed } = await takeApproval($, key)
    if (live) {
      reissued.set(String(raw.tool_use_id ?? ''), live.files.join(', '))
      return next(e)
    }
    // The settings hooks beneath (the payload write gate among them) decide first, so Dan is never
    // asked about a save one of them refuses (#707). next(e) here runs those hooks, never the write.
    const decided = await next(e)
    if (decided.deny !== undefined) return decided

    const id = String(raw.tool_use_id ?? '') || `save-${++saves}`
    const q: AskBeforeSavingQuestion = { id, tool: tool as AskBeforeSavingQuestion['tool'], input, files, key }
    // One waiting question per save: the same save refused again replaces the one before.
    await update($, pendingRef, p => [...(p ?? []).filter(x => x.key !== key), q])
    const ask = askInstruction(id, files)
    return { deny: lapsed ? `${lapsedNote(lapsed)} ${ask}` : ask }
  }).catch(($, e, next) => ({ deny: cannotCheck(next.error) }))

  // Claude asks in Claude Code's own dialog (#777). A question tied to a waiting save is checked and
  // given the mod's own answers, and Dan's answer is read from the dialog's result.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const ask = e as unknown as AskInput & Record<string, unknown>
    const id = saveIdOf(ask.metadata?.source)
    // A question about no save is Claude Code's alone, its failures included (lessons review of #783:
    // a catch over the whole hook reported them as a save whose answer could not be read).
    if (id === undefined) return next(e)
    const answered = async () => {
      if (e.agentId !== undefined) return { deny: 'Only the main session asks Dan about saving to lasting memory. Put the rule and the file in your final report instead.' }
      const q = ((await $.state.get(pendingRef)).value ?? []).find(x => x.id === id)
      if (!q) return { deny: `No save is waiting under ${id}: it was answered already, or the session ended. Send the save again, and you will be told how to ask.` }
      const where = q.files.join(', ')
      const questions = Array.isArray(ask.questions) ? ask.questions : []
      if (questions.length !== 1 || typeof questions[0]?.question !== 'string')
        return { deny: `Ask one question about this save, naming ${where} and stating the rule in one plain sentence.` }
      const question = questions[0].question as string
      const missing = q.files.filter(f => !question.includes(f))
      if (missing.length) return { deny: `The question must name the file the rule would go to (${missing.join(', ')}) and state the rule in one plain sentence, such as "Save to ${q.files[0]} for good: <the rule>?".` }
      // An answer only Dan's dialog may give: one the call already carries is refused, never read.
      if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
        return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this save.' }

      const r = await next({ ...e, questions: [{ ...questions[0], header: HEADER, options: dialogOptions(q.files), multiSelect: false }] } as typeof e)
      if (r.deny !== undefined || r.isError) return r
      const out = (r.result ?? {}) as AskResult
      const asked = typeof out.questions?.[0]?.question === 'string' ? (out.questions[0].question as string) : question
      const chosen = out.answers?.[asked] ?? out.answers?.[question]
      const say = (text: string) => ({ ...r, context: [...(r.context ?? []), text] })
      // The dialog resolved itself while Dan was away: no answer of his, so the save waits to be asked again.
      if (out.afkTimeoutMs !== undefined) return say(`Dan did not answer: the dialog closed by itself while he was away, so nothing was saved. Ask him again about saving to ${where} when he is back.`)
      if (typeof chosen !== 'string' || !chosen.trim()) return say(`Dan gave no answer about saving to ${where}, so nothing was saved. Ask him again, or leave it.`)

      // Answered: the waiting question is taken out, whatever the answer.
      await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
      if (chosen === NOT_AT_ALL) return say(`Dan answered Not at all to saving this to ${where}: nothing was saved. Do not save it.`)
      if (chosen === THIS_SESSION) {
        const rule = ruleOf(question, q.files)
        await update($, rulesRef, x => [...(x ?? []), rule])
        $.ui.invalidate('prompt.section')
        return say(`Dan answered Just this session to saving this to ${where}: nothing was written. It is in your system prompt as a rule for this session only.`)
      }
      if (chosen !== FOR_GOOD)
        return say(`Dan answered in his own words instead of choosing: "${chosen}". Nothing was saved. Act on what he said; sending the save again asks him again.`)

      // For good (#738): approved by what it saves (the key taken where the save was refused, so the
      // file named), for a while, and Claude told, in this result, to send the call again, given whole
      // since a compaction may take the call out of its context.
      const now = await $.clock.now()
      const key = q.key ?? (await whereOf($).then(at => saveKey(q.tool, q.input, at.cwd, at.home)))
      const made: AskBeforeSavingApproval = { id: q.id, key, files: q.files, until: now + APPROVAL_MS }
      await update($, approvalsRef, a => [...(a ?? []), made])
      lapseAfter($, APPROVAL_MS, where)
      return say(
        `Dan answered For good to saving this to ${where}. Send the same ${q.tool} call again now, unchanged, and it is saved without asking him again: ` +
          `${callShown(q.tool, q.input)}. If it is not sent within ${MINUTES} minutes, this lapses.`,
      )
    }
    try {
      return await answered()
    } catch (err) {
      return { deny: `Not saved: Ask before saving could not read Dan's answer (${message(err)}). Ask him again.` }
    }
  })

  // A reload drops the module's timers, never its approvals: each one waiting is timed again.
  on('session.start', async ($, e, next) => {
    const r = await next(e)
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
    const unused = (await $.state.get(approvalsRef)).value ?? []
    await $.state.set(rulesRef, [])
    await $.state.set(pendingRef, [])
    await $.state.set(promptRef, null)
    await $.state.set(approvalsRef, [])
    $.ui.invalidate('prompt.section')
    // Dan answered For good believing it saved; one Claude never sent again is said, not dropped quietly.
    // One Claude sent that another guard refused was used, and says why it was not saved (#764, L11).
    for (const x of unused)
      $.ui.toast(
        x.refused !== undefined
          ? `The For good you gave for saving to ${x.files.join(', ')} ended with the session: Claude sent the save, but it was refused before it was saved (${x.refused}), and it was not sent again.`
          : `The For good you gave for saving to ${x.files.join(', ')} was never used before the session ended, so it no longer lets that save through.`,
        { timeoutMs: 10_000 },
      )
    return next(e)
  })
}
