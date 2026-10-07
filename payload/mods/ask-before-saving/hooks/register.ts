import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { AskBeforeSavingApproval, AskBeforeSavingQuestion } from '../types/index.d.ts'
import {
  APPROVAL_MS,
  FOR_GOOD,
  HEADER,
  type InCheckout,
  LESSON_ADD,
  LESSON_HEADER,
  LESSON_PROJECT,
  LESSON_SKIP,
  LESSON_SOURCE,
  MAX_SHORT,
  MIN_RULE,
  addsLesson,
  lessonAddition,
  lessonOptions,
  lessonsFile,
  pressed,
  ruleText,
  untimed,
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
// The question is refused for from tool.check (#875), which the engine raises beneath every mod's
// tool.call hook (#705): a write another guard or a settings hook refuses is refused before Dan is
// asked about it (#707). The skip for Dan's own permanent words stays a tool.call hook, the one place
// the saved result can be read, as does what Claude is told of a save sent again after For good.

const pendingRef = { plugin: 'ask-before-saving', key: 'pending' } as const
const rulesRef = { plugin: 'ask-before-saving', key: 'rules' } as const
const promptRef = { plugin: 'ask-before-saving', key: 'lastPrompt' } as const
const approvalsRef = { plugin: 'ask-before-saving', key: 'approvals' } as const

const TOOL_NAMES = ['Write', 'Edit', 'Bash'] as const
const TOOLS: ReadonlySet<string> = new Set(TOOL_NAMES)
const MINUTES = APPROVAL_MS / 60_000

// The saves Dan's own words made permanent, by what they write (saveKey): added by the tool.call
// hook and taken by the tool.check hook beneath it as the call reaches it, so the call passes
// and nothing else does. In memory: both are one dispatch, which a reload cannot come between.
const approved = new Set<string>()
// A subagent's calls the tool.call hook judged and let through, by what they write: the tool.check hook
// beneath, which cannot see which loop a call runs in, never asks the main session about them. A main
// session call with the same key meanwhile is no hole: the key is everything the judgement reads, so
// it writes no lasting memory either. Counted per key, so one of two identical calls finishing never
// clears the other's mark while it is still on its way down (lessons review of #783).
const fromAgent = new Map<string, number>()
// The calls the tool.check hook let through on a For good approval, by tool_use_id, with where each
// saves to: read back by the tool.call hook above it in the same dispatch, to say what became of it.
const reissued = new Map<string, string>()
// The calls the tool.check hook let through on an approval from the durable lesson picker (#867), by
// tool_use_id, with that approval: taken from $.state as the call passed, so a second matching call
// meanwhile is asked about, and given back by the tool.call hook above when the write did not land.
const lessonUsed = new Map<string, AskBeforeSavingApproval>()

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

let saves = 0
const message = (err: unknown) => String((err as Error)?.message ?? err)

/** The scope modes mod's noun (#841) as its contract has it; it may not be loaded at all. */
type ScopeModes = {
  isAsleep: () => Promise<boolean>
  sleepNote: (note: { kind: string } & Record<string, unknown>) => Promise<{ isNoted: boolean }>
}
// A save while the Mac is asleep (sleep mode, #841): noted for Dan's morning report through scope
// modes, which reads the one sleep record, and refused without asking him. Answers the refusal, or
// null while awake. Scope modes not loaded, or a check that fails, is awake: the save is asked about
// as usual, and a question while asleep is refused by scope modes itself.
const whileAsleep = async ($: EngineInterface, files: string[], rule: string): Promise<string | null> => {
  // The noun is spelled out at each call, as the engine requires.
  try {
    if (!(await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.isAsleep())) return null
  } catch {
    return null
  }
  const where = files.join(', ')
  const head = `Not saved: this writes lasting memory (${where}), and Dan is asleep (sleep mode), so he is not asked tonight.`
  const tail = 'Do not write it any other way; carry on with the rest of the work.'
  try {
    const r = await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.sleepNote({ kind: 'save', files, rule })
    // Woken between the two reads: asked as usual.
    if (!r.isNoted) return null
    return `${head} The save is noted for his morning report, where he decides. ${tail}`
  } catch (err) {
    return `${head} It could not be noted for his morning report (${message(err)}), so put the rule and ${where} in your final message. ${tail}`
  }
}

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
// through a variable nothing can set is none (#777). An inline program whose text names every file it
// writes is judged by those files alone (#830). A file in a temporary folder counts inside a
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
    // A program whose text names every file it writes is judged by those files, never by every path
    // its text quotes (#830: a heredoc editing a test file quoted a memory path as test data).
    if (u.targets) {
      for (const t of u.targets) if ((await lastingMemory(t, home, inCheckout)) && !out.includes(display(t, home))) out.push(display(t, home))
      continue
    }
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
    ? `The ${pressed(x)} you gave for saving to ${where} lapsed after ${MINUTES} minutes: Claude sent the save, but it was refused before it was saved (${x.refused}), and it was not saved within that time.`
    : `The ${pressed(x)} you gave for saving to ${where} lapsed after ${MINUTES} minutes unused, so it no longer lets that save through.`
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
        ? `Dan's ${pressed(x)} on saving this to ${where} lapsed after ${MINUTES} minutes: the save you sent was refused before it was saved (${x.refused}), so nothing was saved, and sending it again asks him again.`
        : `Dan's ${pressed(x)} on saving this to ${where} lapsed after ${MINUTES} minutes unused: it no longer lets that save through, and sending it again asks him again.`,
    )
  }
}
// Times the lapse, never throwing: a timer that cannot be set is said. The approval is then refused
// on its age where it is used, and said at session end, so only the announcement on time is lost.
// Named by the approval itself, so the toast says the answer Dan pressed (lessons review of #869).
const lapseAfter = ($: EngineInterface, ms: number, x: AskBeforeSavingApproval) => {
  try {
    $.clock.after(Math.max(0, ms), () => void lapse($).catch(err => $.ui.toast(`Ask before saving could not take out an approval past its time: ${message(err)}`)))
  } catch (err) {
    $.ui.toast(untimed(x, message(err)), { timeoutMs: 10_000 })
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

// The text a call adds to the lessons file, when it is an Edit or Write to that file and all it does
// is add (#867); undefined for anything else. An Edit or Write writes its own file_path and nothing
// else, so the path is the whole judgement of where it saves, and it is judged before anything is
// read: a Bash call is never looked into here (second lessons review of #869, where a refused shell
// call's target reads failed and replaced the refusal that stopped it). A file that exists and cannot
// be read fails the hook, and the hook fails closed.
const lessonAdded = async ($: EngineInterface, tool: string, input: Record<string, unknown>, at: Where): Promise<string | undefined> => {
  if (tool !== 'Edit' && tool !== 'Write') return undefined
  const file = lessonsFile(at.home)
  if (resolvePath(String(input.file_path ?? ''), at.cwd, at.home) !== file) return undefined
  // The file as it is now: an Edit's kept text is judged against it as well as a Write's content.
  const old = (await $.fs.exists(file)) ? await $.fs.read(file) : undefined
  return lessonAddition(tool, input, old)
}

// The approval Dan gave in the durable lesson picker for the lesson this text adds, taken as the call
// that uses it arrives, and refused on its age there (L567); one past its time is taken out and said.
const takeLesson = async ($: EngineInterface, added: string) => {
  const now = await $.clock.now()
  let live: AskBeforeSavingApproval | undefined
  let lapsed: AskBeforeSavingApproval[] = []
  await update($, approvalsRef, a => {
    live = undefined
    lapsed = []
    const keep: AskBeforeSavingApproval[] = []
    for (const x of a ?? []) {
      const fits = x.lesson !== undefined && addsLesson(added, x.lesson)
      if (fits && !stands(x.until, now)) lapsed.push(x)
      else if (fits && !live) live = x
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
    ? `Dan's earlier ${pressed(x)} on this save lapsed after ${MINUTES} minutes; the save you sent before was refused (${x.refused}), so he has to be asked again.`
    : `Dan's earlier ${pressed(x)} on this save lapsed after ${MINUTES} minutes unused, so he has to be asked again.`

// What a subagent is told when its write would save lasting memory: refused, never asked (#777).
const agentRefusal = (where: string) =>
  `Not saved: this would write lasting memory (${where}), which only the main session may do, after asking Dan; a subagent never asks him. ` +
  `If this is not a save to memory (a test fixture, or a file whose text only mentions one), make the change with Edit or Write on the file itself. ` +
  `If it is a standing rule, put the rule and the file in your final report, and the main session will ask him.`

type AskInput = { questions?: { question?: unknown; header?: unknown; options?: unknown; multiSelect?: unknown }[]; answers?: unknown; metadata?: { source?: unknown; rule?: unknown } }
type AskResult = { answers?: Record<string, unknown>; questions?: { question?: unknown }[]; response?: unknown; afkTimeoutMs?: unknown }

export const register: Register = on => {
  // Dan's latest message of his own, typed or from his phone, read for the words that already make
  // a rule permanent. A peer session's or a plugin's message never counts.
  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind === 'composer' || e.origin.kind === 'bridge') await $.state.set(promptRef, e.text)
    return next(e)
  })

  // One hook over the three tools, matched as any one of them.
  on('tool.call', { tool: TOOL_NAMES }, async ($, e, next) => {
    const tool = e.tool
    const raw = e as unknown as Record<string, unknown>
    const id = String(raw.tool_use_id ?? '')
    const input = argsOf(raw)

    // A subagent's call (#777): judged here, where the loop is known, refused when it would save
    // lasting memory, and never asked about. One the tool.check hook beneath must let through.
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
    let lesson: AskBeforeSavingApproval | undefined
    try {
      r = await next(e)
    } finally {
      // Taken by the tool.check hook when the call reached it; dropped here when a guard refused first.
      if (key !== undefined) approved.delete(key)
      forGood = reissued.get(id)
      reissued.delete(id)
      lesson = lessonUsed.get(id)
      lessonUsed.delete(id)
    }
    // A lesson added on Dan's answer in the durable lesson picker (#867). One that did not land (an
    // Edit whose text was not found, a settings hook refusing it) gives the approval back for the rest
    // of its time, so the corrected call is not asked about either, and records why, so its lapse
    // never calls it unused; Dan, who pressed add believing it saved, is told it was not.
    if (lesson !== undefined) {
      const where = lesson.files.join(', ')
      if (r.deny === undefined && !r.isError) return { ...r, context: [...(r.context ?? []), `Added to ${where}, as Dan answered ${LESSON_ADD}.`] }
      const why = String(r.deny ?? r.text ?? 'the tool reported an error')
      const back: AskBeforeSavingApproval = { ...lesson, refused: why }
      $.ui.toast(`Not added to ${where}: ${why}`, { timeoutMs: 10_000 })
      if (!stands(back.until, await $.clock.now())) {
        $.ui.toast(lapsedFor(back), { timeoutMs: 10_000 })
        return r
      }
      await update($, approvalsRef, a => [...(a ?? []), back])
      // A refusal carries no context: Claude reads the refusal itself.
      if (r.deny !== undefined) return r
      return { ...r, context: [...(r.context ?? []), `Not added to ${where}. Dan's ${LESSON_ADD} still stands until it lapses: correct the call and send it again, and it is added without asking him.`] }
    }
    // A save Dan answered For good, sent again, refused before the tool.check hook could take its
    // approval (#764): by another guard's tool.call hook (a deny), or by a settings hook, which since
    // #875 decides before tool.check (an errored result). Dan is told now that it did not go through,
    // and the approval, which still stands for a later send, records why, so its lapse never calls it
    // unused. A call that reached tool.check took its approval, so one still standing was not reached.
    const refusedWhy = r.deny ?? (r.isError ? (r.text ?? 'the call was refused') : undefined)
    if (forGood === undefined && refusedWhy !== undefined && ((await $.state.get(approvalsRef)).value ?? []).length) {
      const at = await whereOf($)
      const k = saveKey(tool, input, at.cwd, at.home)
      // Typed through a cast: the assignment is inside a callback, which narrowing cannot see (lessons review of #806).
      let hit = undefined as AskBeforeSavingApproval | undefined
      // Reset at the top of the callback, as takeApproval does, in case update runs it again.
      await update($, approvalsRef, a => {
        hit = undefined
        return (a ?? []).map(x => (x.key === k ? (hit = { ...x, refused: refusedWhy }) : x))
      })
      if (hit) {
        $.ui.toast(`Not saved to ${hit.files.join(', ')}: ${refusedWhy}`, { timeoutMs: 10_000 })
        return r
      }
      // And a lesson Dan approved in the durable lesson picker, added by a call another guard refused
      // before the tool.check hook could take its approval (#867): said the same way.
      const added = await lessonAdded($, tool, input, at)
      if (added === undefined) return r
      const now = await $.clock.now()
      let fit = undefined as AskBeforeSavingApproval | undefined
      await update($, approvalsRef, a => {
        fit = undefined
        return (a ?? []).map(x => (!fit && x.lesson !== undefined && stands(x.until, now) && addsLesson(added, x.lesson) ? (fit = { ...x, refused: refusedWhy }) : x))
      })
      if (fit) $.ui.toast(`Not added to ${fit.files.join(', ')}: ${refusedWhy}`, { timeoutMs: 10_000 })
      return r
    }
    if (forGood !== undefined) {
      // Tested on r itself, so the result it spreads is known to be one that went through.
      if (r.deny === undefined && !r.isError) return { ...r, context: [...(r.context ?? []), `Saved to ${forGood}, as Dan answered For good.`] }
      // Claude reads the failure in the result; Dan, who answered For good, would otherwise not.
      $.ui.toast(`Not saved to ${forGood}: ${r.deny ?? r.text ?? 'the tool reported an error'}`, { timeoutMs: 10_000 })
      return r
    }
    if (!files.length || r.deny !== undefined || r.isError) return r
    return { ...r, context: [...(r.context ?? []), `Saved to ${files.join(', ')} without asking, because Dan's message made it a standing rule. Now say in one line what you saved and where.`] }
  }).catch(($, e, next) => ({ deny: cannotCheck(next.error) }))

  // Refused at tool.check (#875), which the engine raises inside tool.call once every mod's tool.call
  // hook and the settings PreToolUse hooks have passed the call on, so Claude is told to ask only
  // about a write every guard lets through. It was classic.PreToolUse, which never ran: Claude Code's
  // built-in security default sends every classic event past the user tier this mod loads in, for a
  // Team or Enterprise organization (a headless debug run, 2026-10-06), and the built-in's own
  // tool.check hook runs this tier first and keeps a refusal.
  on('tool.check', async ($, e, next) => {
    const tool = e.tool
    if (!TOOLS.has(tool)) return next(e)
    // A query ($.tool.check) carries no call id and runs nothing: no question waits on a save that is
    // only being looked at, and the real call is judged when it is made.
    if (e.tool_use_id === undefined) return next(e)
    const raw: Record<string, unknown> = { ...((e.input ?? {}) as Record<string, unknown>), tool, tool_use_id: e.tool_use_id }
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
    // A lesson Dan answered Add to LESSONS.md for in the durable lesson picker (#867), added by a call
    // that only adds it to the lessons file: on beneath like a For good save, never asked about again.
    const added = await lessonAdded($, tool, input, at)
    const lesson = added === undefined ? { live: undefined, lapsed: undefined } : await takeLesson($, added)
    if (lesson.live) {
      lessonUsed.set(String(raw.tool_use_id ?? ''), lesson.live)
      return next(e)
    }
    // The settings hooks beneath (the payload write gate among them) decide first, so Dan is never
    // asked about a save one of them refuses (#707). next(e) here runs those hooks, never the write.
    const decided = await next(e)
    if (decided.decision === 'deny') return decided

    // Dan is asleep (#841): he is not asked tonight. The save goes to his morning report instead,
    // and nothing waits on an answer.
    const asleep = await whileAsleep($, files, await savedText($, tool, input, at))
    if (asleep !== null) return { decision: 'deny', reason: asleep }

    const id = String(raw.tool_use_id ?? '') || `save-${++saves}`
    const q: AskBeforeSavingQuestion = { id, tool: tool as AskBeforeSavingQuestion['tool'], input, files, key }
    // One waiting question per save: the same save refused again replaces the one before.
    await update($, pendingRef, p => [...(p ?? []).filter(x => x.key !== key), q])
    const ask = askInstruction(id, files)
    const late = lapsed ?? lesson.lapsed
    return { decision: 'deny', reason: late ? `${lapsedNote(late)} ${ask}` : ask }
  }).catch(($, e, next) => ({ decision: 'deny', reason: cannotCheck(next.error) }))

  // Claude asks in Claude Code's own dialog (#777). A question tied to a waiting save is checked and
  // given the mod's own answers, and Dan's answer is read from the dialog's result.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const ask = e as unknown as AskInput & Record<string, unknown>
    // The durable lesson check's picker (#867): Dan's answer may approve the lesson's write. The mod
    // sets the picker's answers, so the label read back is one of its own, and an approval comes
    // only from the answer the dialog hands back: never from a call carrying its own, a rule the
    // question Dan reads does not state, his own typed words, or a dialog that closed while he was away.
    const lessonAsked = async () => {
      // A subagent never writes lasting memory (#777), so its picker approves nothing.
      if (e.agentId !== undefined) return next(e)
      const { home } = await whereOf($)
      const file = display(lessonsFile(home), home)
      const questions = Array.isArray(ask.questions) ? ask.questions : []
      const rule = typeof ask.metadata?.rule === 'string' ? ruleText(ask.metadata.rule) : ''
      if (rule.length < MIN_RULE)
        return { deny: `Put the whole rule, word for word as it will be added to ${file}, in metadata "rule" (at least ${MIN_RULE} characters), and state it in the question.` }
      if (questions.length !== 1 || typeof questions[0]?.question !== 'string')
        return { deny: `Ask one question about this lesson, stating the rule word for word as metadata "rule" carries it.` }
      const question = questions[0].question as string
      if (!ruleText(question).includes(rule)) return { deny: `The question must state the rule word for word as metadata "rule" carries it, so Dan approves the text that is added to ${file}.` }
      if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
        return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this lesson.' }

      const r = await next({ ...e, questions: [{ ...questions[0], header: LESSON_HEADER, options: lessonOptions(file), multiSelect: false }] } as typeof e)
      if (r.deny !== undefined || r.isError) return r
      const out = (r.result ?? {}) as AskResult
      const asked = typeof out.questions?.[0]?.question === 'string' ? (out.questions[0].question as string) : question
      const chosen = out.answers?.[asked] ?? out.answers?.[question]
      const say = (text: string) => ({ ...r, context: [...(r.context ?? []), text] })
      if (out.afkTimeoutMs !== undefined) return say(`Dan did not answer: the dialog closed by itself while he was away, so the lesson is not approved. Ask him again when he is back.`)
      if (chosen === LESSON_PROJECT) return say(`Dan answered ${LESSON_PROJECT}: do not add it to ${file}. Save it to this project's memory instead; that save is asked about as usual.`)
      if (chosen === LESSON_SKIP) return say(`Dan answered ${LESSON_SKIP}: nothing is saved.`)
      if (chosen !== LESSON_ADD)
        return say(`Dan did not choose ${LESSON_ADD}${typeof chosen === 'string' && chosen.trim() ? `, he answered in his own words: "${chosen}"` : ''}. The lesson is not approved; act on what he said.`)
      const made: AskBeforeSavingApproval = { id: `lesson-${++saves}`, key: `lesson:${rule}`, files: [file], until: (await $.clock.now()) + APPROVAL_MS, lesson: rule }
      await update($, approvalsRef, a => [...(a ?? []), made])
      lapseAfter($, APPROVAL_MS, made)
      return say(
        `Dan answered ${LESSON_ADD}. Add it now with one Edit to ${file}: old_string one or more whole lines of the file found once (a section heading, say), ` +
          `new_string that text, a newline and the entry, or the entry, a newline and that text. The entry is "- **L<number>." then the rule word for word as he approved it (bold and line wrapping are fine), ` +
          `then nothing but its provenance, (repo#N, YYYY-MM-DD), and one SHORT line, which with its "- L<number>. " is at most ${MAX_SHORT} characters, with no blank line inside it. That is saved without asking him again. Anything else written to that file is asked about as usual. If it is not added within ${MINUTES} minutes, this lapses.`,
      )
    }
    if (ask.metadata?.source === LESSON_SOURCE) {
      try {
        return await lessonAsked()
      } catch (err) {
        return { deny: `Ask before saving could not read Dan's answer about the lesson (${message(err)}), so nothing is approved. Ask him again.` }
      }
    }
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
      // Typed, or `??` gives the then q.key's own type, possibly undefined, to infer from.
      const key: string = q.key ?? (await whereOf($).then(at => saveKey(q.tool, q.input, at.cwd, at.home)))
      const made: AskBeforeSavingApproval = { id: q.id, key, files: q.files, until: now + APPROVAL_MS }
      await update($, approvalsRef, a => [...(a ?? []), made])
      lapseAfter($, APPROVAL_MS, made)
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
      for (const x of waiting) lapseAfter($, lapseWait(x.until, now), x)
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
          ? `The ${pressed(x)} you gave for saving to ${x.files.join(', ')} ended with the session: Claude sent the save, but it was refused before it was saved (${x.refused}), so nothing was saved.`
          : `The ${pressed(x)} you gave for saving to ${x.files.join(', ')} was never used before the session ended, so it no longer lets that save through.`,
        { timeoutMs: 10_000 },
      )
    return next(e)
  })
}
