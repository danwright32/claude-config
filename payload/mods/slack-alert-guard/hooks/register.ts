import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { SlackAlertApproval, SlackAlertPending } from '../types/index.d.ts'
import {
  APPROVE,
  CHANGE,
  GUARD,
  HEADER,
  SCAN_MS,
  SENDER_PREFILTER,
  SOURCE,
  agentRefusal,
  editHalves,
  editedText,
  escapeRe,
  heldText,
  inScope,
  isOwnRecord,
  languageOf,
  literalsOf,
  mentionsStore,
  plainYamlValues,
  question,
  refersTo,
  refusal,
  removalKey,
  renderedProblem,
  searchTerm,
  shellKey,
  slackMarked,
  templateLines,
  textTemplate,
  wordingChange,
  wordingKey,
  wordingOf,
} from './rules.ts'
import { errorText } from './mod-kit/skew.ts'
import { neverThrows } from './mod-kit/hold.ts'

// The Slack alert guard (claude-config#2242), in a session. Dan, 2026-11-04: "anytime a slack alert
// is created, we need to have a design-rounds esque check on wording so I can approve the wording
// before it's created". An edit that changes the words a Slack posting file sends is refused until
// Dan has seen the message as Slack will post it and answered Approve wording in Claude Code's own
// dialog, which the guard words; his answer is kept by the exact wording (decision 3 in rules.ts).
// The rules are in rules.ts; this file reads files and the store, keeps the calls waiting on Dan,
// and asks him.

const pendingRef = { plugin: 'slack-alert-guard', key: 'pending' } as const

// A subagent's calls this guard judged and let through in its tool.call hook, so the tool.check
// beneath does not judge them again.
const fromAgent = new Set<string>()

const message = (err: unknown) => errorText(err, SOURCE)

const ownRecord =
  "Blocked: this would change the Slack alert guard's own record of the wording Dan approved, which only his answer to its question writes. Leave that file alone."
const cannotCheck = (why: string) =>
  `Blocked: the Slack alert guard could not check this call (${why}), so it is held rather than let through unchecked. Try it again; if it keeps failing, tell Dan what failed.`
// The catches' last word, built before anything can fail (#2039).
const HELD = cannotCheck('unknown failure')

type Hold = { file: string; added: string[]; removed: string[]; keys: string[]; sender?: string }
type Verdict = { pass: true } | { own: true } | { unchecked: string } | { hold: Hold }
const PASS: Verdict = { pass: true }

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

// Every string a file's text holds, read as its language reads them.
const literals = async ($: EngineInterface, lang: ReturnType<typeof languageOf>, text: string): Promise<string[]> => {
  if (!text) return []
  if (lang === 'python') {
    // mod-kit's spans are already the text between the quotes, prefix letters and quotes left out.
    const spans = await $.modkit.pythonText({ code: text })
    return spans.filter(s => s.kind === 'string' || s.kind === 'formatted').map(s => text.slice(s.from, s.to))
  }
  if (lang === 'yaml') return [...literalsOf(text, true), ...plainYamlValues(text)]
  return literalsOf(text, lang === 'hash')
}

// The keys of a change Dan has not yet approved; a store that cannot be read throws.
const unapproved = async ($: EngineInterface, keys: string[]): Promise<string[]> => {
  const out: string[] = []
  for (const k of keys) if ((await $.store.get(k)) === undefined) out.push(k)
  return out
}

// The most files the search reads for one template before it holds the call as could not check.
const MOST_READ = 200

type Found = { sender: string } | { none: true } | { unchecked: string }
const NONE: Found = { none: true }

/**
 * The file that sends the template at `path` to Slack (#2248): one in the same git repository that
 * carries a Slack marker and names the template's path or module (refersTo). git grep narrows the
 * repository to files holding both the template's name and the word slack or postMessage, so only
 * those are read. Every git call and read is bounded by `deadline`, and anything that cannot be
 * answered in time, or at all, is could not check, so the call is held rather than let through. A
 * file in no repository has nothing to search, so none.
 */
const findSender = async ($: EngineInterface, path: string, deadline: number): Promise<Found> => {
  const late: Found = { unchecked: `the files that could send ${path} to Slack were not searched within ${SCAN_MS / 1000} seconds` }
  const left = async () => deadline - (await $.clock.now())
  try {
    // The nearest folder that exists, since a Write can create a file in a folder not yet made.
    let dir = path.slice(0, path.lastIndexOf('/')) || '/'
    while (dir !== '/' && !(await $.fs.exists(dir))) dir = dir.slice(0, dir.lastIndexOf('/')) || '/'
    let ms = await left()
    if (ms <= 0) return late
    const where = await $.process.run(['git', '-C', dir, 'rev-parse', '--show-toplevel', '--show-prefix'], { timeoutMs: ms })
    if (where.exitCode === 128 && /not a git repository/.test(where.stderr)) return NONE
    if (where.exitCode !== 0 || where.isStdoutTruncated)
      return { unchecked: `git could not name the repository ${path} is in (exit ${where.exitCode}: ${where.stderr.trim().split('\n')[0] || 'no message'})` }
    // git prints the repository's top folder, then the folder searched from below it, ending in a
    // slash, or an empty line at the top. The top is git's own spelling, symlinks resolved, so the
    // template is placed by that prefix rather than by cutting the top off its path.
    const [top = '', prefix = ''] = where.stdout.split('\n')
    if (!top) return { unchecked: `git named no repository for ${path}` }
    const templateRel = `${prefix}${path.slice(dir === '/' ? 1 : dir.length + 1)}`
    ms = await left()
    if (ms <= 0) return late
    const argv = ['git', '-C', top, 'grep', '-l', '-z', '-I', '-i', '--untracked', '--all-match', '-E', '-e', escapeRe(searchTerm(templateRel)), '-e', SENDER_PREFILTER, '--', '.']
    const hits = await $.process.run(argv, { timeoutMs: ms })
    if (hits.exitCode === 1) return NONE
    if (hits.exitCode !== 0 || hits.isStdoutTruncated)
      return { unchecked: `git grep for the files that send ${path} failed (exit ${hits.exitCode}: ${hits.stderr.trim().split('\n')[0] || 'no message'})` }
    const rels = hits.stdout.split('\u0000').filter(r => r && r !== templateRel)
    if (rels.length > MOST_READ) return { unchecked: `${rels.length} files could send ${path} to Slack, more than the ${MOST_READ} the guard reads` }
    for (const rel of rels) {
      if ((await left()) <= 0) return late
      const file = `${top}/${rel}`
      let text: string
      try {
        text = String(await $.fs.read(file))
      } catch (err) {
        return { unchecked: `${file}, which could send ${path} to Slack, could not be read: ${message(err)}` }
      }
      if (slackMarked(text) && refersTo(rel, text, templateRel)) return { sender: file }
    }
    return NONE
  } catch (err) {
    return { unchecked: `the files that could send ${path} to Slack could not be searched: ${message(err)}` }
  }
}

const judgeEdit = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<Verdict> => {
  const path = typeof input.file_path === 'string' ? input.file_path : ''
  if (!path) return PASS
  if (isOwnRecord(path)) return { own: true }
  let current = ''
  try {
    if (await $.fs.exists(path)) current = String(await $.fs.read(path))
  } catch (err) {
    return { unchecked: `${path} could not be read: ${message(err)}` }
  }
  const edited = editedText(current, tool, input)
  const halves = edited === undefined ? editHalves(tool, input) : undefined
  const before = halves ? halves.before : current
  const after = halves ? halves.after : (edited as string)
  // A code file is read for its strings, a text template line by line (#2248); any other file posts
  // nothing.
  const code = inScope(path, current || after)
  const text = !code && textTemplate(path)
  if (!code && !text) return PASS
  const marked = code && (slackMarked(current) || slackMarked(after))
  try {
    const lang = languageOf(path, current || after)
    const wording = async (t: string) => wordingOf(text ? templateLines(t) : await literals($, lang, t))
    const { added, removed } = wordingChange(await wording(before), await wording(after))
    if (!added.length && !removed.length) return PASS
    let hold: Hold
    if (added.length) {
      const fresh = [...new Set(added)]
      const open = await unapproved($, fresh.map(wordingKey))
      if (!open.length) return PASS
      hold = { file: path, added: fresh.filter(s => open.includes(wordingKey(s))), removed, keys: open }
    } else {
      const keys = await unapproved($, [removalKey(path, removed)])
      if (!keys.length) return PASS
      hold = { file: path, added: [], removed, keys }
    }
    if (marked) return { hold }
    // Wording Dan has not approved, in a file with no Slack marker of its own: held when another
    // file in its repository sends it to Slack.
    const found = await findSender($, path, (await $.clock.now()) + SCAN_MS)
    if ('unchecked' in found) return found
    return 'sender' in found ? { hold: { ...hold, sender: found.sender } } : PASS
  } catch (err) {
    return { unchecked: message(err) }
  }
}

const judgeShell = async ($: EngineInterface, input: Record<string, unknown>): Promise<Verdict> => {
  const command = typeof input.command === 'string' ? input.command : ''
  if (!command) return PASS
  if (mentionsStore(command)) return { own: true }
  try {
    const cwd = await $.session.cwd()
    const home = (await $.env.get('HOME')) ?? ''
    const w = await $.modkit.writes({ command, cwd, home })
    // One search deadline for the whole call, set when the first search starts.
    let deadline: number | undefined
    for (const f of w.files) {
      if (f.path === undefined) continue
      if (isOwnRecord(f.path)) return { own: true }
      if (!(await $.fs.exists(f.path))) continue
      const text = String(await $.fs.read(f.path))
      const code = inScope(f.path, text)
      if (code && slackMarked(text)) {
        const keys = await unapproved($, [shellKey(cwd, command)])
        return keys.length ? { hold: { file: f.path, added: [], removed: [], keys } } : PASS
      }
      // A code file with no Slack marker, or a text template (#2248): held when another file in its
      // repository sends it to Slack.
      if (!code && !textTemplate(f.path)) continue
      const keys = await unapproved($, [shellKey(cwd, command)])
      if (!keys.length) return PASS
      deadline ??= (await $.clock.now()) + SCAN_MS
      const found = await findSender($, f.path, deadline)
      if ('unchecked' in found) return found
      if ('sender' in found) return { hold: { file: f.path, added: [], removed: [], keys, sender: found.sender } }
    }
    return PASS
  } catch (err) {
    return { unchecked: message(err) }
  }
}

const judge = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<Verdict> => {
  if (tool === 'Write' || tool === 'Edit' || tool === 'MultiEdit') return judgeEdit($, tool, input)
  if (tool === 'Bash') return judgeShell($, input)
  return PASS
}

// The grey card Dan sees, drawn by mod-kit as every guard's is. One that cannot be drawn does not
// change the refusal, which Claude reads whatever happens to the card.
const drawCard = async ($: EngineInterface, toolUseId: string, reason: string, safeWay?: string) => {
  if (!toolUseId) return
  try {
    await $.modkit.blocked({ toolUseId, guard: GUARD, reason, ...(safeWay ? { safeWay } : {}) })
  } catch (err) {
    $.ui.log(`slack-alert-guard: the card could not be drawn: ${message(err)}`, { to: 'debug' })
  }
}

// What a refused call is told, and the card drawn for it; a held call is kept waiting on Dan. A
// call with no id names nothing to wait under, so nothing is kept and no card is drawn.
const refuse = async ($: EngineInterface, v: Exclude<Verdict, { pass: true }>, id: string, tool: string, agent: boolean): Promise<string> => {
  if ('own' in v) {
    await drawCard($, id, "This would change the Slack alert guard's own record.", 'Only your answer to its question writes it.')
    return ownRecord
  }
  if ('unchecked' in v) {
    await drawCard($, id, 'The Slack alert guard could not check this call, so it is held.', v.unchecked)
    return cannotCheck(v.unchecked)
  }
  const { file, added, removed, keys, sender } = v.hold
  if (id) {
    const waiting: SlackAlertPending = { id, tool, file, added, removed, keys, ...(sender ? { sender } : {}), ...(agent ? { agent: true as const } : {}) }
    await update($, pendingRef, p => [...(p ?? []).filter(x => x.id !== id), waiting])
    await drawCard($, id, `${heldText(file, added, removed, sender)}.`, agent ? 'The main session asks you about it.' : 'Claude shows you the message as Slack will post it and asks you to approve the wording.')
  }
  return agent ? agentRefusal(id, file, added, removed, sender) : refusal(id, file, added, removed, sender)
}

type AskInput = { questions?: unknown[]; answers?: unknown; metadata?: Record<string, unknown> }
type AskResult = { questions?: { question?: unknown }[]; answers?: Record<string, string>; afkTimeoutMs?: number }

export const register: Register = on => {
  // A subagent's call, judged where its loop is known: refused like the main session's, and told to
  // stop and report rather than ask Dan. One it lets through is not judged again beneath.
  on('tool.call', async ($, e, next) => {
    if (e.agentId === undefined || e.tool === 'AskUserQuestion') return next(e)
    const raw = e as unknown as Record<string, unknown>
    const id = String(raw.tool_use_id ?? '')
    const v = await judge($, e.tool, argsOf(raw))
    if (!('pass' in v)) return { deny: await refuse($, v, id, e.tool, true) }
    if (!id) return next(e)
    fromAgent.add(id)
    try {
      return await next(e)
    } finally {
      fromAgent.delete(id)
    }
  }).catch(($, e, next) => neverThrows(() => ({ deny: cannotCheck(message(next.error)) }), () => ({ deny: HELD }), { deny: HELD }))

  // The main session's call, judged beneath every mod's tool.call hook. One that is refused goes to
  // the settings hooks first, so a call one of them refuses is refused in its words and never turned
  // into a question for Dan.
  on('tool.check', async ($, e, next) => {
    if (e.tool_use_id !== undefined && fromAgent.has(e.tool_use_id)) return next(e)
    const v = await judge($, e.tool, (e.input ?? {}) as Record<string, unknown>)
    if ('pass' in v) return next(e)
    const decided = await next(e)
    if (decided.decision === 'deny') return decided
    return { decision: 'deny', reason: await refuse($, v, e.tool_use_id ?? '', e.tool, false) }
  }).catch(($, e, next) => neverThrows(() => ({ decision: 'deny' as const, reason: cannotCheck(message(next.error)) }), () => ({ decision: 'deny' as const, reason: HELD }), { decision: 'deny' as const, reason: HELD }))

  // Dan's question, asked in Claude Code's own dialog. The guard words the question and its answers,
  // and reads his choice from the dialog's own result, the one place it comes from him.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const ask = e as unknown as AskInput
    const source = ask.metadata?.source
    if (typeof source !== 'string' || !source.startsWith(`${SOURCE}:`)) return next(e)
    const say = (r: Awaited<ReturnType<typeof next>>, text: string) => (r.deny !== undefined ? r : { ...r, context: [...(r.context ?? []), text] })

    const decide = async () => {
      if (e.agentId !== undefined) return { deny: 'Only the main session asks Dan about Slack alert wording. Stop and report to the main session that this waits on him.' }
      const id = source.slice(SOURCE.length + 1)
      const waiting = ((await $.state.get(pendingRef)).value ?? []).find(x => x.id === id)
      if (!waiting) return { deny: `No Slack alert edit is waiting under ${id}: it was answered already, or the session ended. Make the edit again, and you will be told how to ask.` }
      if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
        return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this.' }
      const problem = renderedProblem(ask.metadata?.rendered, waiting.added)
      if (problem !== undefined) return { deny: problem }
      const rendered = String(ask.metadata?.rendered).trim()
      const q = question(waiting.file, rendered)
      const options = [
        { label: APPROVE, description: 'Post this wording. The edit goes ahead.' },
        { label: CHANGE, description: 'Hold the edit, and say what it should say instead.' },
      ]
      const r = await next({ ...e, questions: [{ question: q, header: HEADER, options, multiSelect: false }] } as typeof e)
      if (r.deny !== undefined || r.isError) return r
      const out = (r.result ?? {}) as AskResult
      const shown = typeof out.questions?.[0]?.question === 'string' ? (out.questions[0].question as string) : q
      if (out.afkTimeoutMs !== undefined) return say(r, 'Dan did not answer: the dialog closed by itself while he was away, so nothing is recorded and the edit stays held. Ask him again when he is back.')
      const chosen = out.answers?.[shown] ?? out.answers?.[q]
      if (typeof chosen !== 'string' || !chosen.trim()) return say(r, 'Dan gave no answer, so nothing is recorded and the edit stays held. Ask him again, or leave it.')
      if (chosen === CHANGE)
        return say(r, `Dan answered ${CHANGE}: nothing is recorded, and the edit to ${waiting.file} stays held. Ask him what it should say, change the wording, and show him the new message.`)
      if (chosen !== APPROVE) {
        const still = `the edit to ${waiting.file} stays held`
        const again = 'show him the message as Slack will post it and ask again'
        try {
          return say(r, await $.modkit.typedAnswer({ guard: GUARD, typed: chosen, still, again }))
        } catch (err) {
          return say(r, `Dan typed "${chosen}" instead of choosing, so nothing is recorded, and ${still}; mod-kit could not tell him so (${message(err)}). Tell him that in one line, answer what he said, then ${again}.`)
        }
      }
      try {
        const now = await $.clock.now()
        const text = waiting.added.length ? waiting.added : waiting.removed
        for (const k of waiting.keys) await $.store.set(k, { at: now, file: waiting.file, text, rendered } satisfies SlackAlertApproval)
      } catch (err) {
        return say(r, `Dan answered ${APPROVE}, but it could not be recorded (${message(err)}), so the edit to ${waiting.file} stays held. Tell him, and ask again.`)
      }
      await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
      const resend = waiting.agent
        ? "The held change was a subagent's: tell that agent, or a new one, to make it again, unchanged."
        : `Send the ${waiting.tool} call to ${waiting.file} again now, unchanged.`
      return say(r, `Dan answered ${APPROVE}: the wording is recorded as approved. ${resend}`)
    }
    try {
      return await decide()
    } catch (err) {
      return { deny: `The Slack alert guard could not read Dan's answer (${message(err)}), so nothing is recorded. Ask him again.` }
    }
  })

  // Dropped at session end, a /clear included: a held call waits on Dan only in its own session.
  on('session.end', async ($, e, next) => {
    await $.state.set(pendingRef, [])
    return next(e)
  })
}
