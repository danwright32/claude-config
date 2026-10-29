import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import { errorText } from './mod-kit/skew.ts'
import { currentText, inputTexts, type Current } from './mod-kit/inputs.ts'
import type { AskBeforeSaving, AskBeforeSavingApproval, AskBeforeSavingIndexCover, AskBeforeSavingQuestion } from '../types/index.d.ts'
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
  addsThis,
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
  editedFile,
  indexLineAdded,
  linksOnlyTo,
  memoryFileOf,
  shellAppended,
  lapseWait,
  lastingFiles,
  lastingMemory,
  madePermanent,
  mentioned,
  mentionsAny,
  patchNames,
  resolvePath,
  ruleOf,
  saveIdOf,
  saveKey,
  savesThis,
  stands,
  withoutPythonText,
  writesWhat,
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
const coversRef = { plugin: 'ask-before-saving', key: 'covers' } as const

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
// The calls the tool.check hook let through on an approval, For good or from the durable lesson picker
// (#867), by tool_use_id, with that approval: taken from $.state as the call passed, so a second
// matching call meanwhile is asked about, and read back by the tool.call hook above it in the same
// dispatch, to say what became of it and give it back when the write did not land (#1691).
const taken = new Map<string, AskBeforeSavingApproval>()
// The index lines let through on a saved memory file's For good (#1794), by tool_use_id, read back
// by the tool.call hook the same way, to say so and give the cover back when the write did not land.
const coverTaken = new Map<string, AskBeforeSavingIndexCover>()

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

let saves = 0
// An error as words: a call to another mod's noun that failed for a member its loaded copy lacks is
// said as the two mods out of step, never as the raw TypeError (#1299, mod-kit's hooks/skew.ts).
const message = (err: unknown) => errorText(err, 'ask-before-saving')

// Dan typed an answer instead of choosing one (#1145): nothing is recorded, and mod-kit's one
// wording, shared with the design round guard, tells him so in a toast and tells Claude to say so,
// answer what he said and ask the same question again. A mod-kit that cannot (one loaded before it
// had the member) is said, so Claude knows Dan was not told.
const typedSaid = async ($: EngineInterface, typed: string, parts: { still: string; again: string }): Promise<string> => {
  try {
    return await $.modkit.typedAnswer({ guard: 'Ask before saving', typed, ...parts })
  } catch (err) {
    return `Dan typed "${typed}" instead of choosing, so nothing is recorded, and ${parts.still}; mod-kit could not tell him so (${message(err)}). Tell him that in one line, answer what he said, then ${parts.again}.`
  }
}

/** The scope modes mod's noun (#841) as its contract has it; it may not be loaded at all. */
type ScopeModes = {
  isAsleep: () => Promise<boolean>
  sleepNote: (note: { kind: string } & Record<string, unknown>) => Promise<{ isNoted: boolean }>
}
// A save while the Mac is asleep (sleep mode, #841): noted for Dan's morning report through scope
// modes, which reads the one sleep record, and refused without asking him. Answers the refusal, or
// null while awake. Scope modes not loaded, or a check that fails, is awake: the save is asked about
// as usual, and a question while asleep is refused by scope modes itself.
const whileAsleep = async ($: EngineInterface, { files, guessed, handed }: Targets, rule: string): Promise<string | null> => {
  // The noun is spelled out at each call, as the engine requires.
  try {
    if (!(await ($ as unknown as { scopeModes: ScopeModes }).scopeModes.isAsleep())) return null
  } catch {
    return null
  }
  const where = files.join(', ')
  const head = `Not saved: ${writesWhat(files, guessed, handed)}, and Dan is asleep (sleep mode), so he is not asked tonight.`
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

// The files a call would save lasting memory to, and among them those taken only from what a Bash
// command mentions, since its words do not name the file it writes (#940), and those found only as a
// file handed to a script as its argument (#1592), each of which the refusal says.
type Targets = { files: string[]; guessed: string[]; handed: string[] }

// A Bash command as its mentions are read (#940): each python program in it that only writes files,
// found in the command as written, with the lasting memory its comments and sentences name taken out
// (withoutPythonText), so a script writing prose about CLAUDE.md to another file is not asked about.
// Only a program the shell cannot have changed, as mod-kit's reader says on each command
// (`asWritten`, #1171: this mod worked it out itself before): in any other the shell may have run
// what its text holds, and so in one a command substitution runs (#974), which was always read
// whole. A program that runs a process, or that cannot be found in the command as written, is read
// whole, as before, and so is every program where a mod-kit loaded before it said so gives no answer.
const mentionText = async ($: EngineInterface, command: string): Promise<string> => {
  let text = command
  for (const c of await $.modkit.pipeline({ command })) {
    const p = c.program
    if (!c.asWritten || c.language !== 'python' || c.verdict?.does !== 'write files' || !p || !('text' in p) || !p.text || !text.includes(p.text)) continue
    text = text.split(p.text).join(await withoutText($, p.text))
  }
  return text
}

// What mod-kit's write reader calls a patch it reads (git apply, git am, patch): its `what` for one.
const PATCH = 'a patch'

// A command's text as a patch it feeds is read (#1883): the body of each heredoc on standard input of
// the command mod-kit's write reader gave as that patch (`words`, matched to its own reading of the
// call), cut to the lines naming the files it changes (patchNames). Only a quoted heredoc, whose body
// the shell leaves exactly as written, so its lines are the patch; an unquoted one may gain a header
// once the shell expands it, and is read whole, as is a body naming no file, one replaced by a later
// redirect, and one that cannot be found as written in the text.
const patchHeredocsCut = async ($: EngineInterface, command: string, text: string, words: readonly string[]): Promise<string> => {
  if (!mentionsAny(text)) return text
  const same = (a: readonly string[]) => a.length === words.length && a.every((w, i) => w === words[i])
  let out = text
  for (const c of await $.modkit.pipeline({ command })) {
    if (!same(c.words)) continue
    for (const h of c.heredocs ?? []) {
      if (!h.quoted || h.fd !== undefined || h.replaced || !h.body || !out.includes(h.body)) continue
      const names = patchNames(h.body)
      if (names !== undefined) out = out.split(h.body).join(names)
    }
  }
  return out
}

// A python program with the lasting memory its sentences name taken out (#940), where it holds text
// read by mod-kit's one scanner (#1171). A mod-kit that cannot say (one loaded before it had the
// member, which a reload can leave, standing rule 5) leaves the program whole, so every memory file
// it names is asked about, the side that writes nothing unasked; said once in the transcript.
let toldNoScanner = false
const withoutText = async ($: EngineInterface, code: string): Promise<string> => {
  try {
    return withoutPythonText(code, await $.modkit.pythonText({ code }))
  } catch (err) {
    if (!toldNoScanner) {
      toldNoScanner = true
      $.ui.log(`Ask before saving could not ask mod-kit where a python program holds text (${message(err)}), so it read each program whole and asks about every memory file one names. A new session loads mod-kit again.`)
    }
    return code
  }
}

// Where a call would save lasting memory, as Dan reads it, or nothing when it saves none. A Bash
// call is read by mod-kit's one reader of what a command writes; a write its words do not name (a
// patch, an inline script) is judged by the lasting memory its text and any patch file it reads
// mention, and so is a target they cannot name, such as a variable (#743, lastingFiles); a mention
// through a variable nothing can set is none (#777), nor is one a python program only holds as text
// (#940, mentionText). An inline program whose text names every file it writes is judged by those
// files alone (#830). A file in a temporary folder counts inside a checkout there, found by mod-kit's
// one walk for it (#726). A file that exists and cannot be read, or a disk that cannot say whether a
// temporary file is in a checkout, fails the hook, and the hook fails closed.
const lastingTargets = async ($: EngineInterface, tool: string, input: Record<string, unknown>, { cwd, home }: Where): Promise<Targets> => {
  const inCheckout: InCheckout = async abs => (await $.modkit.workingTree({ path: abs })) !== null
  if (tool !== 'Bash') {
    const abs = resolvePath(String(input.file_path ?? ''), cwd, home)
    return { files: (await lastingMemory(abs, home, inCheckout)) ? [display(abs, home)] : [], guessed: [], handed: [] }
  }
  const command = String(input.command ?? '')
  const isSet = await isSetIn($, home)
  const w = await $.modkit.writes({ command, cwd, home })
  // Read only where the command mentions lasting memory at all, the one case it can change anything.
  const text = mentionsAny(command) ? await mentionText($, command) : command
  const guessed: string[] = []
  const handed: string[] = []
  const out = await lastingFiles(w, home, inCheckout, command, isSet, { text, guessed, handed })
  for (const u of w.unnamed) {
    // A program whose text names every file it writes is judged by those files, never by every path
    // its text quotes (#830: a heredoc editing a test file quoted a memory path as test data).
    if (u.targets) {
      for (const t of u.targets) if ((await lastingMemory(t, home, inCheckout)) && !out.includes(display(t, home))) out.push(display(t, home))
      continue
    }
    // A program the reader read is guessed at from its own text and arguments, a bare name placed in
    // the folder it runs in (#1155, mod-kit's `program` and `folder` since #1151): never from another
    // command's heredoc data in the same call, nor from the session's folder. Its text is read as
    // mentionText left it, so a sentence in a python program naming lasting memory stays text (#940).
    if (u.program !== undefined) {
      const own = text.includes(u.program) ? u.program : await withoutText($, u.program)
      const said = [own, ...u.words.filter(x => x !== u.program)].join('\n')
      for (const m of await mentioned(said, home, inCheckout, isSet, u.folder, command))
        if (!out.includes(m)) {
          out.push(m)
          guessed.push(m)
        }
      continue
    }
    // What the command mentions is a guess at the file; what a patch it reads names is what it writes.
    // A patch it reads from a device or a fifo is never opened (#1765), as a missing one never was:
    // the read waits for ever, and one fed on standard input is the heredoc, read in the command.
    // A patch is judged by the lines naming the files it changes (#1883, patchNames), in a patch
    // file and in a heredoc feeding the patch alike; one naming none is read whole, as before.
    const patch = u.what === PATCH
    for (const m of await mentioned(patch ? await patchHeredocsCut($, command, text, u.words) : text, home, inCheckout, isSet))
      if (!out.includes(m)) {
        out.push(m)
        guessed.push(m)
      }
    const read = await inputTexts({ exists: p => $.fs.exists(p), stat: (p, o) => $.fs.stat(p, o), read: p => $.fs.read(p) }, u.inputs)
    for (const t of read) for (const m of await mentioned(patch ? (patchNames(t) ?? t) : t, home, inCheckout, isSet)) if (!out.includes(m)) out.push(m)
  }
  return { files: out, guessed, handed }
}

// What would be saved, as the rule's text: a new file's whole text, the lines a rewrite adds, an
// Edit's new text, a Bash command as written. Claude reads it; Dan reads Claude's plain words.
const savedText = async ($: EngineInterface, tool: string, input: Record<string, unknown>, at: Where): Promise<string> => {
  if (tool === 'Edit') return String(input.new_string ?? '')
  if (tool !== 'Write') return String(input.command ?? '')
  // No file there yet: the whole content is what would be saved. One that exists and cannot be read
  // fails the hook, and the hook fails closed. One that is no ordinary file (/dev/stdin, a fifo) is
  // never opened (#1814): what it holds now is unknown, never empty, so the whole content is said,
  // with why its new lines could not be told.
  const abs = resolvePath(String(input.file_path ?? ''), at.cwd, at.home)
  const old = await textNow($, abs)
  if ('unreadable' in old)
    return `${addedText(String(input.content ?? ''), undefined)} (the whole of what it writes: ${display(abs, at.home)} could not be read before it, as ${old.unreadable}, so which lines are new could not be told)`
  return addedText(String(input.content ?? ''), 'text' in old ? old.text : undefined)
}

// What a file a call writes holds now, by mod-kit's one reader of it (#1814), which never opens a
// device or a fifo: a read of one waited for ever, so the call never ran.
const textNow = ($: EngineInterface, path: string): Promise<Current> =>
  currentText({ exists: p => $.fs.exists(p), stat: (p, o) => $.fs.stat(p, o), read: p => $.fs.read(p) }, path)

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
      const fits = savesThis(x, key)
      if (fits && !stands(x.until, now)) lapsed.push(x)
      else if (fits && !live) live = x
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
// `now` reads the file as it is, by mod-kit's currentText, handed in so the noun (#1483), which may
// not pass its engine to a helper, reads through its own. A lessons file that is no ordinary file (a
// fifo, a link to a device) is never opened (#1814), and what a call adds to it cannot be told, so
// it is asked about.
const lessonAddedBy = async (tool: string, input: Record<string, unknown>, at: Where, now: (file: string) => Promise<Current>): Promise<string | undefined> => {
  if (tool !== 'Edit' && tool !== 'Write') return undefined
  const file = lessonsFile(at.home)
  if (resolvePath(String(input.file_path ?? ''), at.cwd, at.home) !== file) return undefined
  // The file as it is now: an Edit's kept text is judged against it as well as a Write's content.
  const old = await now(file)
  if ('unreadable' in old) return undefined
  return lessonAddition(tool, input, 'text' in old ? old.text : undefined)
}
const lessonAdded = ($: EngineInterface, tool: string, input: Record<string, unknown>, at: Where): Promise<string | undefined> =>
  lessonAddedBy(tool, input, at, file => textNow($, file))

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
      const fits = addsThis(x, added)
      if (fits && !stands(x.until, now)) lapsed.push(x)
      else if (fits && !live) live = x
      else keep.push(x)
    }
    return keep
  })
  for (const x of lapsed) $.ui.toast(lapsedFor(x), { timeoutMs: 10_000 })
  return { live: live as AskBeforeSavingApproval | undefined, lapsed: lapsed[0] as AskBeforeSavingApproval | undefined }
}

// The line a call adds to `index` (#1794), read by every route this mod judges: a Write's content and
// an Edit's result against the index as it is now, and a shell command that only appends text it
// spells out (rules.ts shellAppended, by mod-kit's one reader of what it runs and writes) appended to
// it. Undefined for anything else, which is asked about. An index that exists and cannot be read fails
// the hook, and the hook fails closed; one that is no ordinary file (a fifo, a link to a device) is
// never opened (#1814), and what a call adds to it cannot be told, so it is asked about.
const indexLineOf = async ($: EngineInterface, tool: string, input: Record<string, unknown>, at: Where, index: string): Promise<string | undefined> => {
  const now = await textNow($, index)
  if ('unreadable' in now) return undefined
  const old = 'text' in now ? now.text : undefined
  if (tool === 'Write') return indexLineAdded(old, String(input.content ?? ''))
  if (tool === 'Edit') {
    const edited = editedFile(old, input)
    return edited === undefined ? undefined : indexLineAdded(old, edited)
  }
  const command = String(input.command ?? '')
  const appended = shellAppended(command, await $.modkit.pipeline({ command }), await $.modkit.writes({ command, cwd: at.cwd, home: at.home }), index)
  return appended === undefined ? undefined : indexLineAdded(old, (old ?? '') + appended)
}

// A For good on one memory file, once its save lands, also covers the one line in its folder's index
// linking to it (#1794), until the approval itself would lapse. Answers what Claude is told of it, or
// nothing when the save was no memory file's, or more than one file's, which covers no line.
const coverFor = async ($: EngineInterface, used: AskBeforeSavingApproval): Promise<string | undefined> => {
  if (used.files.length !== 1) return undefined
  const { home } = await whereOf($)
  const file = memoryFileOf(resolvePath(used.files[0] ?? '', '/', home), home)
  if (!file) return undefined
  const made: AskBeforeSavingIndexCover = { ...file, files: used.files, until: used.until }
  await update($, coversRef, a => [...(a ?? []), made])
  return `The one line in ${display(file.index, home)} that links to ${file.name} may be added without asking him again until this For good lapses; any other change to that index is asked about.`
}

// The cover a saved memory file's For good gives this call (#1794), taken as the call passes: a write
// whose one target is the index of a cover that still stands, adding only the one line linking that
// cover's file. Covers past their time are dropped in silence, here and wherever the list is written:
// Dan never answered about the index, so there is nothing of his to say lapsed.
const takeCover = async ($: EngineInterface, tool: string, input: Record<string, unknown>, at: Where, { files, guessed, handed }: Targets): Promise<AskBeforeSavingIndexCover | undefined> => {
  if (files.length !== 1 || guessed.length || handed.length) return undefined
  const now = await $.clock.now()
  const standing = ((await $.state.get(coversRef)).value ?? []).filter(c => stands(c.until, now) && display(c.index, at.home) === files[0])
  const index = standing[0]?.index
  if (index === undefined) return undefined
  const line = await indexLineOf($, tool, input, at, index)
  if (line === undefined) return undefined
  let hit = undefined as AskBeforeSavingIndexCover | undefined
  await update($, coversRef, a => {
    hit = undefined
    return (a ?? []).filter(c => {
      if (!stands(c.until, now)) return false
      if (hit || c.index !== index || !linksOnlyTo(line, c.name)) return true
      hit = c
      return false
    })
  })
  return hit
}

// What Claude reads when the approval for the call it sent has lapsed (#764: never "unused" for one
// it sent that another guard refused).
const lapsedNote = (x: AskBeforeSavingApproval) =>
  x.refused !== undefined
    ? `Dan's earlier ${pressed(x)} on this save lapsed after ${MINUTES} minutes; the save you sent before was refused (${x.refused}), so he has to be asked again.`
    : `Dan's earlier ${pressed(x)} on this save lapsed after ${MINUTES} minutes unused, so he has to be asked again.`

// What a subagent is told when its write would save lasting memory: refused, never asked (#777).
const agentRefusal = ({ files, guessed, handed }: Targets) =>
  (guessed.length || handed.length
    ? `Not saved: ${writesWhat(files, guessed, handed)}. Only the main session may write it, after asking Dan; a subagent never asks him. `
    : `Not saved: this would write lasting memory (${files.join(', ')}), which only the main session may do, after asking Dan; a subagent never asks him. `) +
  `If this is not a save to memory (a test fixture, or a file whose text only mentions one), make the change with Edit or Write on the file itself. ` +
  `If it is a standing rule, put the rule and the file in your final report, and the main session will ask him.`

type AskInput = { questions?: { question?: unknown; header?: unknown; options?: unknown; multiSelect?: unknown }[]; answers?: unknown; metadata?: { source?: unknown; rule?: unknown } }
type AskResult = { answers?: Record<string, unknown>; questions?: { question?: unknown }[]; response?: unknown; afkTimeoutMs?: unknown }

// Whether a prompt is Dan's own words, asked of mod-kit's one reader (#1135). One that cannot answer
// (a mod-kit loaded before it had the reader, which a reload can leave, standing rule 5) reads the
// prompt as not his, the side that changes nothing here, said once in the transcript; the prompt
// itself always goes on (L73).
let toldNoReader = false
const dansWords = async ($: EngineInterface, origin: { readonly kind?: string } | undefined): Promise<boolean> => {
  try {
    return await $.modkit.isDans({ origin })
  } catch (err) {
    if (!toldNoReader) {
      toldNoReader = true
      $.ui.log(`Ask before saving could not ask mod-kit whether your message was your own words (${message(err)}), so it read it as not yours. A new session loads mod-kit again.`)
    }
    return false
  }
}

export const register: Register = on => {
  // The noun (#1483): whether a call carries a live, unspent approval Dan gave for exactly what it
  // writes, For good by what it saves (savesThis) or in the durable lesson picker by the lesson it
  // adds (addsThis), matched as the tool.check hook below matches a call sent again. It only looks:
  // the approval is taken there, as the call passes, so it is spent once whoever asked. No build asks
  // it before letting the one Edit of ~/.claude/LESSONS.md through. The engine refuses handing
  // `built` to a helper, so everything is read here with its own calls.
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const askBeforeSaving: AskBeforeSaving = {
      isApproved: async ({ tool, input }) => {
        const home = (await built.env.get('HOME')) ?? ''
        const at: Where = { home, cwd: await built.session.cwd() }
        const key = saveKey(tool, input, at.cwd, at.home)
        const added = await lessonAddedBy(tool, input, at, file =>
          currentText({ exists: p => built.fs.exists(p), stat: (p, o) => built.fs.stat(p, o), read: p => built.fs.read(p) }, file),
        )
        const now = await built.clock.now()
        const approvals = (await built.state.get(approvalsRef)).value ?? []
        return { isApproved: approvals.some(x => stands(x.until, now) && (savesThis(x, key) || addsThis(x, added))) }
      },
    }
    return { ...built, askBeforeSaving }
  })

  // Dan's latest message of his own, typed or from his phone as mod-kit's one reader says (#1135),
  // read for the words that already make a rule permanent. A peer session's or a plugin's message,
  // a handoff's opening prompt included, never counts.
  on('prompt.submit', async ($, e, next) => {
    if (await dansWords($, e.origin)) {
      // Noting his words never holds up his message (L73): a note that cannot be made is said, and
      // words in it that make a rule permanent then do not skip the question.
      try {
        await $.state.set(promptRef, e.text)
      } catch (err) {
        $.ui.log(`Ask before saving could not note your message (${message(err)}), so words in it that make a rule permanent will not skip the question.`)
      }
    }
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
      const targets = await lastingTargets($, tool, input, at)
      if (targets.files.length) {
        const where = targets.files.join(', ')
        const listed = (await $.agent.list()).some(a => a.id === e.agentId)
        // Claude Code's own background loop (the memory writer): the main session decides with Dan.
        if (!listed)
          await tell(
            $,
            `A background loop of Claude Code's (the memory writer, or another agent no list names) tried to save to ${where} and was refused, so nothing was saved. ` +
              `What it would have saved: ${await savedText($, tool, input, at)}. If it is worth keeping, save it yourself, and you will be told how to ask Dan first.`,
          )
        return { deny: agentRefusal(targets) }
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
      files = (await lastingTargets($, tool, input, at)).files
      if (files.length) approved.add((key = saveKey(tool, input, at.cwd, at.home)))
    }
    let r: Awaited<ReturnType<typeof next>>
    let used: AskBeforeSavingApproval | undefined
    let covered: AskBeforeSavingIndexCover | undefined
    try {
      r = await next(e)
    } finally {
      // Taken by the tool.check hook when the call reached it; dropped here when a guard refused first.
      if (key !== undefined) approved.delete(key)
      used = taken.get(id)
      taken.delete(id)
      covered = coverTaken.get(id)
      coverTaken.delete(id)
    }
    // A save sent on an approval, For good or Dan's Add to LESSONS.md in the durable lesson picker
    // (#867). The approval is spent only once the write lands (#1691, L30): one that did not (an Edit
    // whose text was not found or whose file was not read yet, a guard or settings hook beneath
    // refusing it) gives it back for the rest of its time, so the call sent again is not asked about,
    // and records why, so its lapse never calls it unused; Dan, who answered believing it saved, is
    // told it was not. A shell command that ran and failed may have written part of what it does, so
    // its approval is spent: running it again would write that part twice.
    if (used !== undefined) {
      const where = used.files.join(', ')
      const lesson = used.lesson !== undefined
      if (r.deny === undefined && !r.isError) {
        const saved = `${lesson ? 'Added' : 'Saved'} to ${where}, as Dan answered ${pressed(used)}.`
        const cover = lesson ? undefined : await coverFor($, used)
        return { ...r, context: [...(r.context ?? []), cover ? `${saved} ${cover}` : saved] }
      }
      const why = String(r.deny ?? r.text ?? 'the tool reported an error')
      const not = lesson ? 'Not added' : 'Not saved'
      $.ui.toast(`${not} to ${where}: ${why}`, { timeoutMs: 10_000 })
      if (tool === 'Bash' && r.deny === undefined) return r
      const back: AskBeforeSavingApproval = { ...used, refused: why }
      if (!stands(back.until, await $.clock.now())) {
        $.ui.toast(lapsedFor(back), { timeoutMs: 10_000 })
        return r
      }
      await update($, approvalsRef, a => [...(a ?? []), back])
      // A refusal carries no context: Claude reads the refusal itself.
      if (r.deny !== undefined) return r
      const again = lesson ? 'correct the call and send it again, and it is added' : 'send the same call again once what failed is put right, and it is saved'
      return { ...r, context: [...(r.context ?? []), `${not} to ${where}. Dan's ${pressed(used)} still stands until it lapses: ${again} without asking him.`] }
    }
    // The index line a saved memory file's For good covered (#1794), spent once it lands. One that did
    // not land gives its cover back for the rest of the approval's time, as the approval itself is
    // given back, but a shell command that ran and failed may have appended part of it, so it is spent.
    if (covered !== undefined) {
      const index = display(covered.index, (await whereOf($)).home)
      if (r.deny === undefined && !r.isError)
        return { ...r, context: [...(r.context ?? []), `Added the line linking ${covered.name} to ${index}, under Dan's For good on saving ${covered.files.join(', ')}.`] }
      if ((tool === 'Bash' && r.deny === undefined) || !stands(covered.until, await $.clock.now())) return r
      const back = covered
      await update($, coversRef, a => [...(a ?? []), back])
      return r
    }
    // A save Dan answered For good, sent again, refused before the tool.check hook could take its
    // approval (#764): by another guard's tool.call hook (a deny), or by a settings hook, which since
    // #875 decides before tool.check (an errored result). Dan is told now that it did not go through,
    // and the approval, which still stands for a later send, records why, so its lapse never calls it
    // unused. A call that reached tool.check took its approval, so one still standing was not reached.
    const refusedWhy = r.deny ?? (r.isError ? (r.text ?? 'the call was refused') : undefined)
    if (refusedWhy !== undefined && ((await $.state.get(approvalsRef)).value ?? []).length) {
      const at = await whereOf($)
      const k = saveKey(tool, input, at.cwd, at.home)
      // Typed through a cast: the assignment is inside a callback, which narrowing cannot see (lessons review of #806).
      let hit = undefined as AskBeforeSavingApproval | undefined
      // Reset at the top of the callback, as takeApproval does, in case update runs it again.
      await update($, approvalsRef, a => {
        hit = undefined
        return (a ?? []).map(x => (savesThis(x, k) ? (hit = { ...x, refused: refusedWhy }) : x))
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
        return (a ?? []).map(x => (!fit && stands(x.until, now) && addsThis(x, added) ? (fit = { ...x, refused: refusedWhy }) : x))
      })
      if (fit) $.ui.toast(`Not added to ${fit.files.join(', ')}: ${refusedWhy}`, { timeoutMs: 10_000 })
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
    const targets = await lastingTargets($, tool, input, at)
    const { files } = targets
    if (!files.length) return next(e)
    // A save Dan answered For good, sent again: on to the settings hooks and the permission check
    // beneath (the auto mode classifier among them), never asked about again.
    const { live, lapsed } = await takeApproval($, key)
    if (live) {
      taken.set(String(raw.tool_use_id ?? ''), live)
      return next(e)
    }
    // A lesson Dan answered Add to LESSONS.md for in the durable lesson picker (#867), added by a call
    // that only adds it to the lessons file: on beneath like a For good save, never asked about again.
    const added = await lessonAdded($, tool, input, at)
    const lesson = added === undefined ? { live: undefined, lapsed: undefined } : await takeLesson($, added)
    if (lesson.live) {
      taken.set(String(raw.tool_use_id ?? ''), lesson.live)
      return next(e)
    }
    // The one index line a saved memory file's For good covers (#1794): on beneath the same way.
    const cover = await takeCover($, tool, input, at, targets)
    if (cover) {
      coverTaken.set(String(raw.tool_use_id ?? ''), cover)
      return next(e)
    }
    // The settings hooks beneath (the payload write gate among them) decide first, so Dan is never
    // asked about a save one of them refuses (#707). next(e) here runs those hooks, never the write.
    const decided = await next(e)
    if (decided.decision === 'deny') return decided

    // Dan is asleep (#841): he is not asked tonight. The save goes to his morning report instead,
    // and nothing waits on an answer.
    const asleep = await whileAsleep($, targets, await savedText($, tool, input, at))
    if (asleep !== null) return { decision: 'deny', reason: asleep }

    const id = String(raw.tool_use_id ?? '') || `save-${++saves}`
    const q: AskBeforeSavingQuestion = { id, tool: tool as AskBeforeSavingQuestion['tool'], input, files, key }
    // One waiting question per save: the same save refused again replaces the one before.
    await update($, pendingRef, p => [...(p ?? []).filter(x => x.key !== key), q])
    const ask = askInstruction(id, files, targets.guessed, targets.handed)
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
      if (typeof chosen === 'string' && chosen.trim() && chosen !== LESSON_ADD)
        return say(await typedSaid($, chosen, { still: 'the lesson is not approved', again: 'ask him the same question again, with the same metadata and the rule as it then stands' }))
      if (chosen !== LESSON_ADD) return say(`Dan did not choose ${LESSON_ADD}, and gave no answer, so the lesson is not approved. Ask him again, or leave it.`)
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

      // A typed answer is no answer of his to this save (#1145): the save stays waiting on the same
      // question, which Claude is told to ask again.
      if (chosen !== NOT_AT_ALL && chosen !== THIS_SESSION && chosen !== FOR_GOOD)
        return say(await typedSaid($, chosen, { still: `nothing was saved to ${where}`, again: 'ask him the same question again, with the same metadata' }))

      // Answered: the waiting question is taken out, whatever the answer.
      await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
      if (chosen === NOT_AT_ALL) return say(`Dan answered Not at all to saving this to ${where}: nothing was saved. Do not save it.`)
      if (chosen === THIS_SESSION) {
        const rule = ruleOf(question, q.files)
        await update($, rulesRef, x => [...(x ?? []), rule])
        $.ui.invalidate('prompt.section')
        return say(`Dan answered Just this session to saving this to ${where}: nothing was written. It is in your system prompt as a rule for this session only.`)
      }
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
    await $.state.set(coversRef, [])
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
