import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { DesignRoundPending, DesignRoundRecord, DesignRoundSubject } from '../types/index.d.ts'
import {
  GUARD,
  HEADER,
  SETTLED_NO,
  SETTLED_SOURCE,
  SETTLED_YES,
  SKIP_NO,
  SKIP_SOURCE,
  SKIP_YES,
  agentRefusal,
  cannotCheck,
  card,
  checked,
  forged,
  isOwnRecord,
  isSwiftUI,
  listed,
  lookKindIn,
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
//   issue its branch names, or the branch; a new issue starts at yes (rules.ts subjectsOf).
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


const recordOf = (v: unknown): DesignRoundRecord | undefined => {
  const r = v as Partial<DesignRoundRecord> | undefined
  return r && (r.kind === 'settled' || r.kind === 'skipped') && typeof r.label === 'string' ? (r as DesignRoundRecord) : undefined
}

type Verdict =
  | { pass: true }
  | { forged: string }
  | { unsure: string[]; why: string }
  | { unreadable: { files: string[]; subjects: DesignRoundSubject[]; why: string } }
  | { missing: { files: string[]; subjects: DesignRoundSubject[] } }

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

  // The look changing files, each with the checkout it is in; a file in none is in no project.
  const byTree = new Map<string, string[]>()
  const unsureFiles: string[] = []
  let why = ''
  for (const t of targets) {
    const kind = shapeKind(t.path ?? t.word)
    if (kind === null) continue
    if (!t.path) {
      unsureFiles.push(t.word)
      why ||= `where the command writes ${t.word} could not be followed`
      continue
    }
    if (kind === 'swift' && !(await swiftView($, t, tool, input))) continue
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
    const files = byTree.get(tree) ?? []
    if (!files.includes(t.path)) files.push(t.path)
    byTree.set(tree, files)
  }
  if (!byTree.size && !unsureFiles.length) return { pass: true }

  const missingFiles: string[] = []
  const missing: DesignRoundSubject[] = []
  let session: string | undefined
  for (const [tree, paths] of byTree) {
    const shown = paths.map(p => relTo(p, tree))
    const place = await placeOf($, tree)
    if ('why' in place) {
      unsureFiles.push(...shown)
      why ||= place.why
      continue
    }
    session ??= await $.session.id()
    const subjects = subjectsOf({ ...place, session })
    const lacking: DesignRoundSubject[] = []
    try {
      for (const s of subjects) if (!recordOf(await $.store.get(s.key))) lacking.push(s)
    } catch (err) {
      return { unreadable: { files: shown, subjects, why: message(err) } }
    }
    if (!lacking.length) continue
    missingFiles.push(...shown)
    for (const s of lacking) if (!missing.some(m => m.key === s.key)) missing.push(s)
  }
  if (unsureFiles.length) return { unsure: unsureFiles, why }
  if (missing.length) return { missing: { files: missingFiles, subjects: missing } }
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
const refuse = async ($: EngineInterface, v: Exclude<Verdict, { pass: true }>, call: { id: string; tool: string; agent: boolean }): Promise<string> => {
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
  const { files, subjects } = v.missing
  const waiting: DesignRoundPending = { id: call.id, tool: call.tool, files, subjects, ...(call.agent ? { agent: true as const } : {}) }
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

type AskInput = { questions?: { question?: unknown }[]; answers?: unknown; metadata?: { source?: unknown; issue?: unknown }; agentId?: string }
type AskResult = { answers?: Record<string, unknown>; questions?: { question?: unknown }[]; afkTimeoutMs?: unknown }

export const register: Register = on => {
  // A subagent's call, judged where its loop is known: refused like the main session's, and told to
  // stop and report rather than ask Dan. One it lets through is not judged again beneath.
  on('tool.call', async ($, e, next) => {
    if (e.agentId === undefined || e.tool === 'AskUserQuestion') return next(e)
    const raw = e as unknown as Record<string, unknown>
    const id = String(raw.tool_use_id ?? '')
    const v = await judge($, e.tool, argsOf(raw))
    if (!('pass' in v)) return { deny: await refuse($, v, { id, tool: e.tool, agent: true }) }
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
    const v = await judge($, e.tool, (e.input ?? {}) as Record<string, unknown>)
    if ('pass' in v) return next(e)
    const decided = await next(e)
    if (decided.decision === 'deny') return decided
    // A check asked with no call id ($.tool.check) runs nothing: it is answered as the call would be,
    // with no card drawn and nothing left waiting on Dan (lessons review of #991).
    if (e.tool_use_id === undefined) return { decision: 'deny', reason: previewed(v) }
    return { decision: 'deny', reason: await refuse($, v, { id: e.tool_use_id, tool: e.tool, agent: false }) }
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

    const decide = async () => {
      if (e.agentId !== undefined) return { deny: 'Only the main session asks Dan about design rounds. Stop and report to the main session that this waits on him.' }
      const questions = Array.isArray(ask.questions) ? ask.questions : []

      if (isSkip) {
        const id = source.slice(SKIP_SOURCE.length + 1)
        const waiting = ((await $.state.get(pendingRef)).value ?? []).find(x => x.id === id)
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
        if (chosen === SKIP_NO) return say(r, `Dan answered ${SKIP_NO}: start /design-rounds now. Nothing that changes the look is edited on ${s} until he answers ${SETTLED_YES} to its closing question.`)
        if (chosen !== SKIP_YES) return say(r, `Dan answered in his own words instead of choosing: "${chosen}". Nothing is recorded, so edits that change the look on ${s} stay blocked. Act on what he said.`)
        const kept = await record(open, 'skipped')
        if (kept.why !== undefined) return say(r, partly(SKIP_YES, kept))
        await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
        const again = waiting.agent
          ? 'The refused change was a subagent\'s: tell that agent, or a new one, to make it again.'
          : `Send the ${waiting.tool} call to ${listed(waiting.files)} again now, unchanged.`
        return say(r, `Dan answered ${SKIP_YES}: edits that change the look go ahead on ${s} without a design round, until the next issue. ${again}`)
      }

      // The design rounds skill's closing question: settled for this session's issue or branch, or
      // for the issue the question names, which Dan reads in it.
      const named = ask.metadata?.issue
      if (named !== undefined && !(typeof named === 'number' && Number.isInteger(named) && named > 0)) return { deny: `"${String(named)}" is not an issue number: give metadata "issue" as a number, or leave it out to settle the design for this branch's issue.` }
      if (questions.length !== 1) return { deny: 'Ask Dan one question: "Is this design settled?".' }
      if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
        return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this.' }
      const cwd = await $.session.cwd()
      const tree = await $.modkit.workingTree({ path: cwd })
      if (tree === null) return { deny: `This session is not in a git checkout (${cwd}), so there is no project to settle the design for. Ask from the project's checkout.` }
      let subjects: DesignRoundSubject[]
      const place = await placeOf($, tree)
      if (typeof named === 'number') {
        // The issue named needs only the project, which git names even on a detached head.
        if (place.main === undefined || place.repo === undefined) return { deny: `The design round guard could not tell which project this is (${'why' in place ? place.why : 'no project named'}), so nothing was asked. Try again.` }
        subjects = subjectsOf({ main: place.main, repo: place.repo, session: '', issue: named })
      } else {
        if ('why' in place) return { deny: `The design round guard could not tell which issue or branch this design is for (${place.why}), so nothing was asked. Give metadata "issue" with the issue number, or check out its branch.` }
        subjects = subjectsOf({ ...place, session: await $.session.id() })
      }
      const s = listed(subjects.map(x => x.label))
      const { r, chosen, none } = await asked(settledQuestion(subjects), settledOptions(subjects))
      if (chosen === undefined) return none ? say(r, none) : r
      if (chosen === SETTLED_NO) return say(r, `Dan answered ${SETTLED_NO}: nothing is recorded. Keep going with design rounds.`)
      if (chosen !== SETTLED_YES) return say(r, `Dan answered in his own words instead of choosing: "${chosen}". Nothing is recorded; act on what he said.`)
      const kept = await record(subjects, 'settled')
      if (kept.why !== undefined) return say(r, partly(SETTLED_YES, kept))
      return say(r, `Dan answered ${SETTLED_YES}: the design is recorded as settled for ${s}, and edits that change the look go ahead there. Now write the settled design file the design rounds skill describes.`)
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
