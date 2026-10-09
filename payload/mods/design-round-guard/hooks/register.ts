import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { DesignRoundPass, DesignRoundPending, DesignRoundRecord, DesignRoundSubject } from '../types/index.d.ts'
import {
  GUARD,
  HEADER,
  NOT_LOOK,
  SETTLED_NO,
  SETTLED_SOURCE,
  SETTLED_YES,
  SKIP_NO,
  SKIP_SOURCE,
  SKIP_YES,
  agentRefusal,
  callKey,
  cannotCheck,
  card,
  checked,
  dataOnlyChange,
  editedText,
  forged,
  isOwnRecord,
  isSwiftUI,
  judgedByText,
  listed,
  lookKindIn,
  notLookWhy,
  patternExtension,
  relTo,
  shapeKind,
  mentionedLookFiles,
  mentionsStore,
  pathsOf,
  READS_ONLY,
  textsOf,
  refusal,
  resolvePath,
  settledOptions,
  settledQuestion,
  skipOptions,
  skipQuestion,
  subjectsOf,
  unreadable,
  unsure,
} from './rules.ts'

// Design round guard (claude-config#978). Dan, 2026-10-08: "claude should never design something
// without my input. If we can make this something that can't be ignored rather than just a memory,
// that would be great". Settled with him in a picker interview the same day: every edit that changes
// how a screen looks waits for a settled design round on its issue, unless he has said to skip them.
//
// - What counts (rules.ts lookKindIn): style files, screen and component files, SwiftUI views, in every
//   project, written by the shell (mod-kit's one write reader) or by any tool carrying a file path,
//   a tool known only to read it excepted (rules.ts READS_ONLY). A test file passes. A file in no git
//   checkout is in no project (a design round's own switcher in the scratchpad) and passes.
// - Settled: Dan's Settled to "Is this design settled?", the design rounds skill's closing picker
//   (metadata.source design-settled). Skipped: his Skip them to "Skip design rounds for this issue?",
//   asked about a refused call (metadata.source design-round-guard:<its id>), as ask before saving
//   asks (#777). The guard words both questions and their answers itself, and reads his choice from
//   the dialog's own result; an answer the call carries, his own typed words, a dialog that closed
//   while he was away, a subagent's question and any file Claude writes record nothing, and a write
//   to the guard's own record is refused.
// - Kept in the mod's store (this Mac, every session) under the project's main working tree and the
//   issue its branch names, or the branch; a new issue starts at yes (rules.ts subjectsOf). Settled
//   is for the project of the refused call, or of a path the question names, never the session's
//   folder (#1010).
// - Since #1010: an edit whose one change is a component's data prop passes unasked (rules.ts
//   dataOnlyChange), and the skip question's third answer, Not a look change, lets one refused call
//   through when it is sent again unchanged (`pass:<rules.ts callKey>` in the store).
// - A subagent is refused like the main session and told to stop and report; only the main session
//   asks Dan. Which loop a call runs in is known only at tool.call, so a subagent's call is judged
//   there; the main session's at tool.check, beneath every mod's tool.call hook and after the
//   settings hooks, so Dan is never asked about a call another guard refuses (#707, #875).
// - Anything it cannot tell (the branch, the checkout, its own record) refuses, saying which.

const pendingRef = { plugin: 'design-round-guard', key: 'pending' } as const

// A subagent's calls the tool.call hook judged and let through, by tool_use_id: the tool.check hook
// beneath, which cannot see which loop a call runs in, does not judge them again.
const fromAgent = new Set<string>()

const message = (err: unknown) => String((err as Error)?.message ?? err)

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

type Where = { cwd: string; home: string }
const whereOf = async ($: EngineInterface): Promise<Where> => ({ cwd: await $.session.cwd(), home: (await $.env.get('HOME')) ?? '' })

// One file a call would write: its absolute path, or only the word naming it when the reader could
// not follow where that is; and the text it will hold, where the call carries it.
type Target = { path?: string; word: string; text?: string }

// Every file a call writes or removes, and whether it may write the guard's own record where its
// words do not say what it writes.
const targetsOf = async ($: EngineInterface, tool: string, input: Record<string, unknown>, at: Where): Promise<{ targets: Target[]; storeMentioned: boolean }> => {
  // Every tool but the shell names the files it writes by a path in its input (lessons review of
  // #991): Write, Edit, MultiEdit, NotebookEdit and any tool added later, a reading tool excepted.
  if (tool !== 'Bash') {
    if (READS_ONLY.has(tool)) return { targets: [], storeMentioned: false }
    // A Write's content is the whole file; any other tool's text is judged beside the file as it is.
    const text = tool === 'Write' ? String(input.content ?? '') : undefined
    return { targets: pathsOf(input).map(word => ({ path: resolvePath(word, at.cwd, at.home), word, ...(text === undefined ? {} : { text }) })), storeMentioned: false }
  }
  const command = String(input.command ?? '')
  const w = await $.modkit.writes({ command, cwd: at.cwd, home: at.home })
  const targets: Target[] = []
  for (const f of w.files) targets.push({ word: f.word, ...(f.path ? { path: f.path } : {}) })
  // A removal or an emptying changes the look as surely as a write; a stamp, a folder or a mode does not.
  for (const c of w.changes) if (c.does === 'remove' || c.does === 'truncate') targets.push({ word: c.word, ...(c.path ? { path: c.path } : {}) })
  for (const u of w.unnamed) {
    // A program whose text names every file it writes is judged by those files (#830).
    if (u.targets) {
      for (const t of u.targets) targets.push({ path: t, word: t })
      continue
    }
    // Otherwise what the command, and any patch or script file it reads, mentions is the guess.
    const texts = [command]
    for (const f of u.inputs) if (await $.fs.exists(f)) texts.push(await $.fs.read(f))
    for (const t of texts) for (const m of mentionedLookFiles(t)) targets.push({ path: resolvePath(m, at.cwd, at.home), word: m })
  }
  // A write the words do not name, or a destination the reader could not follow, may be the record
  // when the command names the plugin store at all: refused, failing closed as ask before saving does
  // for lasting memory (lessons review of #991).
  const unfollowed = w.unnamed.length > 0 || targets.some(t => !t.path)
  return { targets, storeMentioned: unfollowed && mentionsStore(command) }
}

// Whether a Swift file is a SwiftUI view: the text the call carries, beside the file as it is now.
// Text that cannot be had (a file the shell writes, a file that cannot be read) counts as one.
const swiftView = async ($: EngineInterface, t: Target, tool: string, input: Record<string, unknown>): Promise<boolean> => {
  const texts: string[] = []
  if (t.text !== undefined) texts.push(t.text)
  // The text an edit carries (Edit's, each of MultiEdit's), judged beside the file as it is now.
  const carried = tool === 'Bash' || t.text !== undefined ? [] : textsOf(input)
  texts.push(...carried)
  if (t.path && t.text === undefined) {
    if (!(await $.fs.exists(t.path).catch(() => false))) return !carried.length || isSwiftUI(texts.join('\n'))
    try {
      texts.push(await $.fs.read(t.path))
    } catch {
      return true
    }
  }
  return isSwiftUI(texts.join('\n'))
}

type Place = { main: string; repo: string; branch: string; isDefault: boolean; issues: readonly number[] }
// Where a checkout stands, by mod-kit's one reading of it (#978), and the project's name by its one
// reading of a repository (#951); why not, with the project where git named it.
const placeOf = async ($: EngineInterface, tree: string): Promise<Place | { why: string; main?: string; repo?: string }> => {
  const b = await $.modkit.branch({ path: tree })
  if (b === null) return { why: `${tree} is in no git checkout` }
  const main = b.main ?? tree
  const repo = (await $.modkit.repo({ root: main, remote: null })).name ?? main
  if ('unreadable' in b) return { why: b.unreadable, ...(b.main ? { main, repo } : {}) }
  return { main, repo, branch: b.branch, isDefault: b.isDefault, issues: b.issues }
}


// What Dan's answers about a checkout are kept under: the one reading the judge and his Settled for a
// named project share, so a project is never read one way to hold an edit and another to settle it
// (#1010). With `issue`, that issue in the project, which git names even on a detached head.
const subjectsIn = async ($: EngineInterface, tree: string, issue?: number): Promise<{ subjects: DesignRoundSubject[] } | { why: string }> => {
  const place = await placeOf($, tree)
  if (issue !== undefined) {
    if (place.main === undefined || place.repo === undefined) return { why: 'why' in place ? place.why : 'no project named' }
    return { subjects: subjectsOf({ main: place.main, repo: place.repo, session: '', issue }) }
  }
  if ('why' in place) return { why: place.why }
  return { subjects: subjectsOf({ ...place, session: await $.session.id() }) }
}

const recordOf = (v: unknown): DesignRoundRecord | undefined => {
  const r = v as Partial<DesignRoundRecord> | undefined
  return r && (r.kind === 'settled' || r.kind === 'skipped') && typeof r.label === 'string' ? (r as DesignRoundRecord) : undefined
}

// Dan's Not a look change for this very call (#1010). A store that cannot be read here is read again
// by the judgement that follows, which refuses saying so.
const passKey = (key: string) => `pass:${key}`
// The key a call is known by: its tool and input, in the folder it runs in, in this session.
const keyOf = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<string> =>
  callKey(tool, input, { cwd: await $.session.cwd(), session: await $.session.id() })
const passed = async ($: EngineInterface, key: string): Promise<boolean> => {
  try {
    return ((await $.store.get(passKey(key))) as Partial<DesignRoundPass> | undefined)?.kind === 'not-look'
  } catch {
    return false
  }
}

// Whether an edit to a React screen file changes nothing on screen, judged from the file as it is and
// the text the call leaves (rules.ts dataOnlyChange). A shell write, a new file, a file that cannot be
// read and a call naming more than one file are never judged so, and are asked about.
const dataOnly = async ($: EngineInterface, path: string, tool: string, input: Record<string, unknown>): Promise<boolean> => {
  if (tool === 'Bash' || !judgedByText(path) || pathsOf(input).length !== 1) return false
  let before: string
  try {
    if (!(await $.fs.exists(path))) return false
    before = await $.fs.read(path)
  } catch {
    return false
  }
  const after = editedText(before, tool, input)
  return after !== undefined && dataOnlyChange(before, after)
}

type Verdict =
  | { pass: true }
  | { forged: string }
  | { unsure: string[]; why: string }
  | { unreadable: { files: string[]; subjects: DesignRoundSubject[]; why: string } }
  | { missing: { files: string[]; subjects: DesignRoundSubject[]; trees: string[] } }

// The judgement every call gets, the main session's and a subagent's alike.
const judge = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<Verdict> => {
  // Only the shell, and a tool carrying a file path it may write, can change a file at all.
  if (tool !== 'Bash' && (READS_ONLY.has(tool) || !pathsOf(input).length)) return { pass: true }
  const at = await whereOf($)
  const { targets, storeMentioned } = await targetsOf($, tool, input, at)
  // By its path, or by its name where the reader could not follow the folder (lessons review of #991).
  const own = targets.find(t => isOwnRecord(t.path ?? t.word))
  if (own) return { forged: own.path ?? own.word }
  if (storeMentioned) return { forged: 'the plugin store, which this command names' }
  // This very call, which Dan answered changes nothing on screen (#1010).
  if (await passed($, await keyOf($, tool, input))) return { pass: true }

  // The look changing files, each with the checkout it is in; a file in none is in no project.
  const byTree = new Map<string, string[]>()
  const unsureFiles: string[] = []
  let why = ''
  for (const t of targets) {
    const kind = shapeKind(t.path ?? t.word)
    if (kind === null) {
      // A name whose extension is a pattern (`page.ts[x]`) may be expanded to a look changing file.
      if (!t.path && patternExtension(t.word)) {
        unsureFiles.push(t.word)
        why ||= `where the command writes ${t.word} could not be followed, and its name is a pattern that may name a look changing file`
        continue
      }
      // A destination the reader could not follow, spelled with no look changing name, may still be
      // one when the command names a look changing file anywhere: held, as ask before saving holds
      // lasting memory (lessons review of #991). A command naming none runs.
      const named = !t.path && tool === 'Bash' ? mentionedLookFiles(String(input.command ?? '')) : []
      if (named.length) {
        unsureFiles.push(t.word)
        why ||= `where the command writes ${t.word} could not be followed, and the command names ${listed(named)}`
      }
      continue
    }
    if (!t.path) {
      unsureFiles.push(t.word)
      why ||= `where the command writes ${t.word} could not be followed`
      continue
    }
    let tree: string | null
    try {
      tree = await $.modkit.workingTree({ path: t.path })
    } catch (err) {
      unsureFiles.push(t.path)
      why ||= `the disk could not say which checkout ${t.path} is in: ${message(err)}`
      continue
    }
    if (tree === null) continue
    // A test of a screen passes (Dan, 2026-10-08: "On, but let tests through"), judged by the path
    // inside its project, so a folder named tests above the checkout lets nothing through.
    if (lookKindIn(t.path, tree) === null) continue
    // Only now is a Swift file read for SwiftUI, so a test is never read, nor held when it cannot be
    // (lessons review of #991).
    if (kind === 'swift' && !(await swiftView($, t, tool, input))) continue
    // An edit whose one change is a component's data prop changes nothing on screen (#1010).
    if (await dataOnly($, t.path, tool, input)) continue
    const files = byTree.get(tree) ?? []
    if (!files.includes(t.path)) files.push(t.path)
    byTree.set(tree, files)
  }
  if (!byTree.size && !unsureFiles.length) return { pass: true }

  const missingFiles: string[] = []
  const missing: DesignRoundSubject[] = []
  const missingTrees: string[] = []
  for (const [tree, paths] of byTree) {
    const shown = paths.map(p => relTo(p, tree))
    const at = await subjectsIn($, tree)
    if ('why' in at) {
      unsureFiles.push(...shown)
      why ||= at.why
      continue
    }
    const { subjects } = at
    const lacking: DesignRoundSubject[] = []
    try {
      for (const s of subjects) if (!recordOf(await $.store.get(s.key))) lacking.push(s)
    } catch (err) {
      return { unreadable: { files: shown, subjects, why: message(err) } }
    }
    if (!lacking.length) continue
    missingFiles.push(...shown)
    missingTrees.push(tree)
    for (const s of lacking) if (!missing.some(m => m.key === s.key)) missing.push(s)
  }
  if (unsureFiles.length) return { unsure: unsureFiles, why }
  if (missing.length) return { missing: { files: missingFiles, subjects: missing, trees: missingTrees } }
  return { pass: true }
}

// The grey card Dan sees, drawn by mod-kit as every guard's is. One that cannot be drawn does not
// change the refusal, which Claude reads whatever happens to the card.
const drawCard = async ($: EngineInterface, toolUseId: string, reason: string, safeWay: string) => {
  try {
    await $.modkit.blocked({ toolUseId, guard: GUARD, reason, safeWay })
  } catch (err) {
    $.ui.log(`design-round-guard: the card could not be drawn: ${message(err)}`, { to: 'debug' })
  }
}

// What a refused call is told, and the card drawn for it; a missing round is kept waiting on Dan.
const refuse = async ($: EngineInterface, v: Exclude<Verdict, { pass: true }>, call: { id: string; tool: string; agent: boolean; key: string }): Promise<string> => {
  if ('forged' in v) {
    await drawCard($, call.id, "This would change the design round guard's own record.", 'Only your answers to its two questions write it.')
    return forged(v.forged)
  }
  if ('unsure' in v) {
    await drawCard($, call.id, `${listed(v.unsure)} changes how the screen looks, and the design round guard could not tell which issue or branch it belongs to.`, 'Claude checks out the issue branch, or asks you.')
    return unsure(v.unsure, v.why)
  }
  if ('unreadable' in v) {
    const u = v.unreadable
    await drawCard($, call.id, `${listed(u.files)} changes how the screen looks, and the design round guard could not read its record of your answers.`, 'Claude tries again, or tells you.')
    return unreadable(u.files, u.subjects, u.why)
  }
  const { files, subjects, trees } = v.missing
  const waiting: DesignRoundPending = { id: call.id, tool: call.tool, files, subjects, trees, key: call.key, ...(call.agent ? { agent: true as const } : {}) }
  await update($, pendingRef, p => [...(p ?? []).filter(x => x.id !== call.id), waiting])
  const c = card(files, subjects)
  await drawCard($, call.id, c.reason, c.safeWay)
  return call.agent ? agentRefusal(files, subjects, call.id) : refusal(call.id, files, subjects)
}

// What a check with no call id is told: the refusal the call would meet, with no id to ask Dan under.
const previewed = (v: Exclude<Verdict, { pass: true }>): string => {
  if ('forged' in v) return forged(v.forged)
  if ('unsure' in v) return unsure(v.unsure, v.why)
  if ('unreadable' in v) return unreadable(v.unreadable.files, v.unreadable.subjects, v.unreadable.why)
  return checked(v.missing.files, v.missing.subjects)
}

// A refused call waiting on Dan, by its id: the one lookup the skip question and the settled question
// naming a call share, so both answer for the project the refused call is in (#1010).
const waitingOf = async ($: EngineInterface, id: string): Promise<DesignRoundPending | undefined> => ((await $.state.get(pendingRef)).value ?? []).find(x => x.id === id)

const NAME_PROJECT =
  'No refused edit is waiting, and the design round guard never takes the project from the folder this session runs in, so nothing was asked. ' +
  'Give metadata "path" with the absolute path of a folder or file in the checkout of the project this design is for (and "issue" when its branch names none), or "call" with the id a refusal named.'

// What the settled question records for (#1010, where Dan's Settled landed on the session's folder,
// Slate, while the refused edit was on trypennie): the refused call it names; else the path it names;
// else the refused calls waiting in this session, when they all wait on the same answer. Never the
// session's folder. `from` is each waiting call the answer is about.
type Found = { subjects: DesignRoundSubject[]; from: DesignRoundPending[] } | { deny: string }
const settledFor = async ($: EngineInterface, issue: number | undefined, call: unknown, path: unknown): Promise<Found> => {
  const inTrees = async (trees: readonly string[], from: DesignRoundPending[]): Promise<Found> => {
    const subjects: DesignRoundSubject[] = []
    for (const tree of trees) {
      const at = await subjectsIn($, tree, issue)
      if ('why' in at)
        return {
          deny:
            issue === undefined
              ? `The design round guard could not tell which issue or branch this design is for (${at.why}), so nothing was asked. Give metadata "issue" with the issue number, or check out its branch.`
              : `The design round guard could not tell which project this is (${at.why}), so nothing was asked. Try again.`,
        }
      for (const x of at.subjects) if (!subjects.some(y => y.key === x.key)) subjects.push(x)
    }
    return { subjects, from }
  }
  if (call !== undefined) {
    if (typeof call !== 'string' || !call) return { deny: `"${String(call)}" names no refused call: give metadata "call" as the id the refusal named, or leave it out.` }
    const w = await waitingOf($, call)
    if (!w) return { deny: `No look changing edit is waiting under ${call}: it was answered already, or the session ended. Give metadata "path" with the project's folder instead.` }
    return issue === undefined ? { subjects: w.subjects, from: [w] } : inTrees(w.trees, [w])
  }
  if (path !== undefined) {
    const home = (await $.env.get('HOME')) ?? ''
    if (typeof path !== 'string' || !(path.startsWith('/') || (home && path.startsWith('~/')))) return { deny: NAME_PROJECT }
    const abs = resolvePath(path, '/', home)
    let tree: string | null
    try {
      tree = await $.modkit.workingTree({ path: abs })
    } catch (err) {
      return { deny: `The design round guard could not tell which checkout ${abs} is in (${message(err)}), so nothing was asked. Try again.` }
    }
    if (tree === null) return { deny: `${abs} is in no git checkout, so there is no project to settle the design for. Give metadata "path" with a folder or file in the project's checkout.` }
    return inTrees([tree], [])
  }
  const open: DesignRoundPending[] = []
  for (const w of (await $.state.get(pendingRef)).value ?? []) {
    let lacking = false
    for (const x of w.subjects) if (!recordOf(await $.store.get(x.key))) lacking = true
    if (lacking) open.push(w)
  }
  const first = open[0]
  if (!first) return { deny: NAME_PROJECT }
  const sig = (w: DesignRoundPending) => w.subjects.map(x => x.key).sort().join('\n')
  if (open.some(w => sig(w) !== sig(first)))
    return { deny: `Refused edits are waiting on different answers (${open.map(w => `${w.id}: ${listed(w.subjects.map(x => x.label))}`).join('; ')}), so nothing was asked. Give metadata "call" with the id of the one this design is for.` }
  return issue === undefined ? { subjects: first.subjects, from: open } : inTrees(first.trees, open)
}

type AskInput = { questions?: { question?: unknown }[]; answers?: unknown; metadata?: { source?: unknown; issue?: unknown; call?: unknown; path?: unknown }; agentId?: string }
type AskResult = { answers?: Record<string, unknown>; questions?: { question?: unknown }[]; afkTimeoutMs?: unknown }

export const register: Register = on => {
  // A subagent's call, judged where its loop is known: refused like the main session's, and told to
  // stop and report rather than ask Dan. One it lets through is not judged again beneath.
  on('tool.call', async ($, e, next) => {
    if (e.agentId === undefined || e.tool === 'AskUserQuestion') return next(e)
    const raw = e as unknown as Record<string, unknown>
    const id = String(raw.tool_use_id ?? '')
    const input = argsOf(raw)
    const v = await judge($, e.tool, input)
    // An empty id names no call to wait under: refused as a check with no id is (lessons review of #991).
    if (!('pass' in v)) return { deny: id ? await refuse($, v, { id, tool: e.tool, agent: true, key: await keyOf($, e.tool, input) }) : previewed(v) }
    // An empty id names no one call, so it is never marked: any other call carrying it would skip its
    // judgement (lessons review of #991). Such a call is judged again beneath, the same way.
    if (!id) return next(e)
    fromAgent.add(id)
    try {
      return await next(e)
    } finally {
      fromAgent.delete(id)
    }
  }).catch(($, e, next) => ({ deny: cannotCheck(message(next.error)) }))

  // The main session's call, judged beneath every mod's tool.call hook. A call that passes goes on
  // untouched; one that is refused goes to the settings hooks first, so a call one of them refuses is
  // refused in its words and never turned into a question for Dan.
  on('tool.check', async ($, e, next) => {
    if (e.tool_use_id !== undefined && fromAgent.has(e.tool_use_id)) return next(e)
    const input = (e.input ?? {}) as Record<string, unknown>
    const v = await judge($, e.tool, input)
    if ('pass' in v) return next(e)
    const decided = await next(e)
    if (decided.decision === 'deny') return decided
    // A check asked with no call id ($.tool.check) runs nothing: it is answered as the call would be,
    // with no card drawn and nothing left waiting on Dan (lessons review of #991).
    if (!e.tool_use_id) return { decision: 'deny', reason: previewed(v) }
    return { decision: 'deny', reason: await refuse($, v, { id: e.tool_use_id, tool: e.tool, agent: false, key: await keyOf($, e.tool, input) }) }
  }).catch(($, e, next) => ({ decision: 'deny', reason: cannotCheck(message(next.error)) }))

  // Dan's two questions, asked in Claude Code's own dialog. The guard words each question and its
  // answers, and reads his choice from the dialog's own result, the one place it comes from him.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const ask = e as unknown as AskInput
    const source = ask.metadata?.source
    if (typeof source !== 'string') return next(e)
    const isSkip = source.startsWith(`${SKIP_SOURCE}:`)
    if (!isSkip && source !== SETTLED_SOURCE) return next(e)

    // Asked of Dan with the guard's own question and answers; his choice read back, or why there is none.
    const asked = async (question: string, options: { label: string; description: string }[]): Promise<{ r: Awaited<ReturnType<typeof next>>; chosen?: string; none?: string }> => {
      const r = await next({ ...e, questions: [{ question, header: HEADER, options, multiSelect: false }] } as typeof e)
      if (r.deny !== undefined || r.isError) return { r, none: '' }
      const out = (r.result ?? {}) as AskResult
      const shown = typeof out.questions?.[0]?.question === 'string' ? (out.questions[0].question as string) : question
      if (out.afkTimeoutMs !== undefined) return { r, none: 'Dan did not answer: the dialog closed by itself while he was away, so nothing is recorded. Ask him again when he is back.' }
      const chosen = out.answers?.[shown] ?? out.answers?.[question]
      if (typeof chosen !== 'string' || !chosen.trim()) return { r, none: 'Dan gave no answer, so nothing is recorded. Ask him again, or leave it.' }
      return { r, chosen }
    }
    // What Claude is told beside Dan's answer, in the dialog's own result; a refusal carries none.
    const say = (r: Awaited<ReturnType<typeof next>>, text: string) => (r.deny !== undefined ? r : { ...r, context: [...(r.context ?? []), text] })
    // Dan's answer kept for each subject, one at a time: what was kept, and, when a write failed,
    // what was not and why, so a branch naming two issues is never told neither was kept when one
    // was (lessons review of #991).
    const record = async (subjects: readonly DesignRoundSubject[], kind: DesignRoundRecord['kind']): Promise<{ done: DesignRoundSubject[]; left: DesignRoundSubject[]; why?: string }> => {
      const done: DesignRoundSubject[] = []
      try {
        const now = await $.clock.now()
        for (const s of subjects) {
          await $.store.set(s.key, { kind, at: now, label: s.label } satisfies DesignRoundRecord)
          done.push(s)
        }
        return { done, left: [] }
      } catch (err) {
        return { done, left: subjects.filter(s => !done.includes(s)), why: message(err) }
      }
    }
    // What Claude is told when a write failed: what was recorded, if anything, and what stays blocked.
    const partly = (answer: string, kept: { done: DesignRoundSubject[]; left: DesignRoundSubject[]; why?: string }) => {
      const left = listed(kept.left.map(x => x.label))
      const head = kept.done.length
        ? `Dan answered ${answer}; it was recorded for ${listed(kept.done.map(x => x.label))}, but not for ${left} (${kept.why})`
        : `Dan answered ${answer}, but it could not be recorded (${kept.why})`
      return `${head}, so edits that change the look on ${left} stay blocked. Tell him, and ask again.`
    }

    // What Claude is told to do with a refused call once Dan's answer lets it through.
    const again = (w: DesignRoundPending) =>
      w.agent ? 'The refused change was a subagent\'s: tell that agent, or a new one, to make it again, unchanged.' : `Send the ${w.tool} call to ${listed(w.files)} again now, unchanged.`

    const decide = async () => {
      if (e.agentId !== undefined) return { deny: 'Only the main session asks Dan about design rounds. Stop and report to the main session that this waits on him.' }
      const questions = Array.isArray(ask.questions) ? ask.questions : []

      if (isSkip) {
        const id = source.slice(SKIP_SOURCE.length + 1)
        const waiting = await waitingOf($, id)
        if (!waiting) return { deny: `No look changing edit is waiting under ${id}: it was answered already, or the session ended. Make the edit again, and you will be told how to ask.` }
        if (questions.length !== 1) return { deny: 'Ask Dan one question: "Skip design rounds for this issue?".' }
        if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
          return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this.' }
        // Only what still has no answer of his is asked about and recorded: a subject he has since
        // settled keeps its settlement, never overwritten by a skip (lessons review of #991).
        const open: DesignRoundSubject[] = []
        for (const x of waiting.subjects) if (!recordOf(await $.store.get(x.key))) open.push(x)
        if (!open.length) {
          await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
          return { deny: `Nothing to ask: ${listed(waiting.subjects.map(x => x.label))} already has his answer, so the edit goes through. Make it again.` }
        }
        const s = listed(open.map(x => x.label))
        const { r, chosen, none } = await asked(skipQuestion(waiting.files, open), skipOptions(open))
        if (chosen === undefined) return none ? say(r, none) : r
        // The call stays waiting until his Skip them is recorded, so an answer in his own words, a
        // Run /design-rounds he changes his mind on, or a record that failed can be asked about again
        // (lessons review of #991).
        if (chosen === SKIP_NO) return say(r, `Dan answered ${SKIP_NO}: start /design-rounds now, and ask its closing question with metadata {"source": "${SETTLED_SOURCE}", "call": "${id}"}. Nothing that changes the look is edited on ${s} until he answers ${SETTLED_YES} to it.`)
        if (chosen === NOT_LOOK) {
          // His word that this one call changes nothing on screen, kept with why (#1010): the same
          // call sent again goes through, and nothing is recorded for the issue.
          try {
            const pass: DesignRoundPass = { kind: 'not-look', at: await $.clock.now(), tool: waiting.tool, files: waiting.files, subjects: open.map(x => x.label), why: notLookWhy(waiting.files) }
            await $.store.set(passKey(waiting.key), pass)
          } catch (err) {
            return say(r, `Dan answered ${NOT_LOOK}, but it could not be recorded (${message(err)}), so the edit to ${listed(waiting.files)} stays blocked. Tell him, and ask again.`)
          }
          await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
          return say(r, `Dan answered ${NOT_LOOK}: this one edit to ${listed(waiting.files)} goes ahead, recorded as his word that it changes nothing on screen. ${again(waiting)} Any other edit that changes the look on ${s} is still held.`)
        }
        if (chosen !== SKIP_YES) return say(r, `Dan answered in his own words instead of choosing: "${chosen}". Nothing is recorded, so edits that change the look on ${s} stay blocked. Act on what he said.`)
        const kept = await record(open, 'skipped')
        if (kept.why !== undefined) return say(r, partly(SKIP_YES, kept))
        await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
        return say(r, `Dan answered ${SKIP_YES}: edits that change the look go ahead on ${s} without a design round, until the next issue. ${again(waiting)}`)
      }

      // The design rounds skill's closing question: settled for the project of the refused call it
      // names, of the refused calls waiting, or of the path it names, and for the issue it names
      // there, which Dan reads in it. Never for the session's own folder (#1010).
      const named = ask.metadata?.issue
      if (named !== undefined && !(typeof named === 'number' && Number.isInteger(named) && named > 0)) return { deny: `"${String(named)}" is not an issue number: give metadata "issue" as a number, or leave it out to settle the design for its branch's issue.` }
      if (questions.length !== 1) return { deny: 'Ask Dan one question: "Is this design settled?".' }
      if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
        return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this.' }
      const found = await settledFor($, typeof named === 'number' ? named : undefined, ask.metadata?.call, ask.metadata?.path)
      if ('deny' in found) return { deny: found.deny }
      const { subjects, from } = found
      const s = listed(subjects.map(x => x.label))
      const { r, chosen, none } = await asked(settledQuestion(subjects), settledOptions(subjects))
      if (chosen === undefined) return none ? say(r, none) : r
      if (chosen === SETTLED_NO) return say(r, `Dan answered ${SETTLED_NO}: nothing is recorded. Keep going with design rounds.`)
      if (chosen !== SETTLED_YES) return say(r, `Dan answered in his own words instead of choosing: "${chosen}". Nothing is recorded; act on what he said.`)
      const kept = await record(subjects, 'settled')
      if (kept.why !== undefined) return say(r, partly(SETTLED_YES, kept))
      // Each refused call his answer covers in full can be sent again. It stays on the waiting list,
      // where a skip question about it is told it already has his answer.
      const done = new Set(kept.done.map(x => x.key))
      const resend = from.filter(w => w.subjects.every(y => done.has(y.key))).map(again)
      return say(r, `Dan answered ${SETTLED_YES}: the design is recorded as settled for ${s}, and edits that change the look go ahead there. Now write the settled design file the design rounds skill describes.${resend.length ? ` ${resend.join(' ')}` : ''}`)
    }
    try {
      return await decide()
    } catch (err) {
      return { deny: `The design round guard could not read Dan's answer (${message(err)}), so nothing is recorded. Ask him again.` }
    }
  })

  // Dropped at session end, a /clear included: a refused call waits on Dan only in its own session.
  on('session.end', async ($, e, next) => {
    await $.state.set(pendingRef, [])
    return next(e)
  })
}
