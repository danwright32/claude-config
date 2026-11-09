import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { SlackAlertApproval, SlackAlertPending } from '../types/index.d.ts'
import {
  APPROVE,
  CHANGE,
  GUARD,
  HEADER,
  REEXPORT_HOPS,
  SCAN_MS,
  SENDER_PREFILTER,
  SOURCE,
  agentRefusal,
  ciMessages,
  ciWorkflow,
  codeOf,
  editHalves,
  editedText,
  handsOn,
  heldText,
  importSpecs,
  inScope,
  isJs,
  isOwnRecord,
  isProseFile,
  languageOf,
  mayHandOn,
  mentionsStore,
  namePatterns,
  plainYamlValues,
  question,
  refersTo,
  refusal,
  removalKey,
  renderedProblem,
  shellKey,
  slackMarked,
  stringsOf,
  templateLines,
  testFile,
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

type Hold = { file: string; added: string[]; removed: string[]; keys: string[]; sender?: string; literal?: string[] }
type Verdict = { pass: true } | { own: true } | { unchecked: string } | { hold: Hold }
const PASS: Verdict = { pass: true }

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

type Lit = { text: string; literal: string[] }
// Every string a file's text holds, read as its language reads them, past any handed to a query
// builder call (#2364), with the placeholders JavaScript writes as text (#2361).
const literals = async ($: EngineInterface, path: string, lang: ReturnType<typeof languageOf>, text: string): Promise<Lit[]> => {
  if (!text) return []
  if (lang === 'python') {
    // mod-kit's spans are already the text between the quotes, prefix letters and quotes left out.
    const spans = await $.modkit.pythonText({ code: text })
    const query = new Set(stringsOf(text, true).filter(s => s.query).map(s => s.start))
    return spans.filter(s => (s.kind === 'string' || s.kind === 'formatted') && !query.has(s.from)).map(s => ({ text: text.slice(s.from, s.to), literal: [] }))
  }
  // A CI workflow posts only what a Slack step carries, never its names, needs or commands (#2371).
  if (lang === 'yaml' && ciWorkflow(path)) return ciMessages(text, path).map(t => ({ text: t, literal: [] }))
  const strings = stringsOf(text, lang !== 'c', lang === 'c' && isJs(path)).filter(s => !s.query)
  const yaml = lang === 'yaml' ? plainYamlValues(text).map(t => ({ text: t, literal: [] })) : []
  return [...strings.map(s => ({ text: s.text, literal: s.literal })), ...yaml]
}

// The keys of a change Dan has not yet approved; a store that cannot be read throws.
const unapproved = async ($: EngineInterface, keys: string[]): Promise<string[]> => {
  const out: string[] = []
  for (const k of keys) if ((await $.store.get(k)) === undefined) out.push(k)
  return out
}

// The most files the search reads for one template before it holds the call for Dan, naming no
// sender since it could not tell which file sends it (#2364).
const MOST_READ = 200

// posts: the file is in a repository, is no test, and posts to Slack by itself. maybe: the search
// could not tell whether a file sends the template (more files to read than it reads, or a send
// helper search that failed), so the edit is held for Dan to approve, never refused
// with nothing he can answer (#2364).
type Found = { sender: string } | { none: true } | { unchecked: string } | { posts: true } | { maybe: true }
const NONE = { none: true } as const
const POSTS = { posts: true } as const
const MAYBE = { maybe: true } as const

// A search ending early with its answer, thrown from a helper and caught at the search's foot.
class Ended {
  constructor(readonly found: Found) {}
}
const end = (found: Found): never => {
  throw new Ended(found)
}

/**
 * The file that sends the template at `path` to Slack (#2248): one in the same git repository that
 * carries a Slack marker and names the template's path or module (refersTo). git grep narrows the
 * repository to files holding the word slack or postMessage and a line naming the template in a form
 * a reference takes (namePatterns, #2371), so only those are read. When none does, the files that hand the template on are followed (#2286): a
 * JavaScript, TypeScript or python file with no Slack marker that names it on an import line and can
 * export it (handsOn). Those are searched for in turn, as the template was, up to REEXPORT_HOPS files
 * deep; a chain going further is could not check. A template is sent too by a file that uses it and
 * imports a Slack send helper (helperUser, #2361), as a copy or notice builder is. A test or a doc is never read as a sender or a
 * link (#2290, #2361). Every git call and read is bounded by `deadline`, and anything that cannot be
 * answered in time, or at all, is could not check, so the call is held rather than let through. More
 * than MOST_READ files to read is maybe: held for Dan to approve, naming no sender (#2364).
 *
 * A file in no repository, as a scratchpad script is, has nothing that sends it, so none, even when
 * it carries a Slack marker (#2287, #2361); so is a test (#2290). A file that does carry one (`marked`)
 * and is in a repository is posts, with no search.
 */
const findSender = async ($: EngineInterface, path: string, deadline: number, marked = false): Promise<Found> => {
  const late: Found = { unchecked: `the files that could send ${path} to Slack were not searched within ${SCAN_MS / 1000} seconds` }
  // Whole milliseconds, as process.run takes a timeout; under one left is none.
  const left = async () => Math.floor(deadline - (await $.clock.now()))
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
    // A test sends nothing (#2290); a file that posts by itself, once known to be in a repository,
    // needs no search for what sends it.
    if (testFile(templateRel)) return NONE
    if (marked) return POSTS
    // What git grep prints for `what`, case ignored; none is an empty string.
    const grep = async (what: string, args: string[]): Promise<string> => {
      const ms = await left()
      if (ms <= 0) end(late)
      const hits = await $.process.run(['git', '-C', top, 'grep', '-z', '-I', '-i', '--untracked', '--no-color', ...args], { timeoutMs: ms })
      if (hits.exitCode === 1) return ''
      if (hits.exitCode !== 0 || hits.isStdoutTruncated)
        end({ unchecked: `git grep for the files that ${what} failed (exit ${hits.exitCode}: ${hits.stderr.trim().split('\n')[0] || 'no message'})` })
      return hits.stdout
    }
    // Every file holding the word slack or postMessage, listed once for the whole search: a sender is
    // one of these that names a level, as a file holding both was before (#2371).
    const slackWords = new Set((await grep(`mention Slack beside ${path}`, ['-l', '-E', '-e', SENDER_PREFILTER, '--', '.'])).split('\u0000').filter(Boolean))
    /**
     * The files naming any of `level` in a form a reference takes (namePatterns), the template itself
     * left out, in the order git lists them. git lists each line holding one of the names, as fixed
     * strings; the shape is tested here on those lines alone, as `-e word --and -e shape` tested it
     * in git, which took seconds for a widely imported module's importers (#2462).
     */
    const naming = async (level: string[]): Promise<string[]> => {
      const name = namePatterns(level)
      const shape = new RegExp(name.shape, 'i')
      const out = new Set<string>()
      for (const line of (await grep(`name ${path} or hand it on`, ['-F', ...name.words.flatMap(w => ['-e', w]), '--', '.'])).split('\n')) {
        const cut = line.indexOf('\u0000')
        if (cut > 0 && shape.test(line.slice(cut + 1))) out.add(line.slice(0, cut))
      }
      return candidates([...out].filter(r => r !== templateRel))
    }
    // Every file read in this search, so a file listed at two levels is read once and counted once.
    const texts = new Map<string, string>()
    const budget = (rels: string[]) => {
      const reads = texts.size + rels.filter(r => !texts.has(r)).length
      if (reads > MOST_READ) end(MAYBE)
    }
    const textOf = async (rel: string, could: string): Promise<string> => {
      if ((await left()) <= 0) end(late)
      const known = texts.get(rel)
      if (known !== undefined) return known
      let text = ''
      try {
        text = String(await $.fs.read(`${top}/${rel}`))
      } catch (err) {
        end({ unchecked: `${top}/${rel}, which could ${could}, could not be read: ${message(err)}` })
      }
      texts.set(rel, text)
      return text
    }
    const sends = `send ${path} to Slack`
    const handsOnTo = `hand ${path} on to the file that sends it`
    // A test sends nothing and a prose file (a doc, a CLAUDE.md, a runbook) posts nothing, so neither is
    // read as a sender or a link (#2290, #2361, #2368). A file in a language the guard does not list as
    // code (a .vue, a .sql posting through pg_net) may still send, so only prose is ruled out.
    const candidates = (rels: string[]) => rels.filter(r => !testFile(r) && !isProseFile(r))
    /**
     * Of the files using the template (a copy builder, a notice builder), the first that imports a
     * Slack send helper, so sends its text through it (#2361): the helper is found by git grep for the
     * word slack or postMessage in the files whose path one of the user's imports names (importSpecs,
     * #2371), never by what their text holds, so a helper whose text never names its own module is
     * found and a common import (db, utils) lists no crowd; it is then read for a marker and a
     * reference from the user. A search that
     * fails, runs late, or would read more than MOST_READ files cannot tell, so it is maybe: held for
     * Dan to approve.
     */
    const helperUser = async (users: { rel: string; text: string }[]): Promise<string | undefined> => {
      const specs = [...new Set(users.flatMap(u => importSpecs(u.text)))]
      if (!specs.length) return undefined
      const ms = await left()
      if (ms <= 0) end(MAYBE)
      const hits = await $.process.run(['git', '-C', top, 'grep', '-l', '-z', '-I', '-i', '--untracked', '-E', '-e', SENDER_PREFILTER, '--', ...specs], { timeoutMs: ms })
      if (hits.exitCode === 1) return undefined
      if (hits.exitCode !== 0 || hits.isStdoutTruncated) end(MAYBE)
      const helpers = candidates(hits.stdout.split('\u0000').filter(r => r && r !== templateRel))
      if (texts.size + helpers.filter(h => !texts.has(h)).length > MOST_READ) end(MAYBE)
      for (const h of helpers) {
        if ((await left()) <= 0) end(MAYBE)
        let text = texts.get(h)
        if (text === undefined) {
          try {
            text = String(await $.fs.read(`${top}/${h}`))
          } catch {
            end(MAYBE)
          }
          texts.set(h, text as string)
        }
        if (!slackMarked(text as string)) continue
        const user = users.find(u => refersTo(u.rel, u.text, h))
        if (user !== undefined) return user.rel
      }
      return undefined
    }
    // The template, then each level of files handing the last level on, the template never again.
    const seen = new Set([templateRel])
    let level = [templateRel]
    for (let hop = 0; ; hop++) {
      // Only files naming the level in a form a reference takes, so a common short name lists no crowd (#2371).
      const named = await naming(level)
      const rels = named.filter(r => slackWords.has(r))
      budget(rels)
      for (const rel of rels) {
        // Only what a file runs can send: a comment naming the template beside a Slack webhook's name
        // posts nothing (Pivot, 2026-11-06, where it held ordinary code edits as alert wording).
        // refersTo leaves comments out itself.
        const text = await textOf(rel, sends)
        if (slackMarked(codeOf(rel, text)) && level.some(t => refersTo(rel, text, t))) return { sender: `${top}/${rel}` }
      }
      const links = named.filter(r => mayHandOn(r) && !seen.has(r))
      budget(links)
      const next: string[] = []
      const users: { rel: string; text: string }[] = []
      for (const rel of links) {
        // Judged by what it runs, as a sender is, so a comment neither hands the template on nor
        // stops a file that does from being followed.
        const text = await textOf(rel, handsOnTo)
        const code = codeOf(rel, text)
        if (slackMarked(code) || !level.some(t => refersTo(rel, text, t))) continue
        if (handsOn(rel, code)) next.push(rel)
        users.push({ rel, text })
      }
      const user = await helperUser(users)
      if (user !== undefined) return { sender: `${top}/${user}` }
      if (!next.length) return NONE
      if (hop === REEXPORT_HOPS)
        return {
          unchecked: `${path} is handed on through more than ${REEXPORT_HOPS} files before anything sends it, more than the guard follows (next: ${next.map(r => `${top}/${r}`).join(', ')})`,
        }
      for (const r of next) seen.add(r)
      level = next
    }
  } catch (err) {
    if (err instanceof Ended) return err.found
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
    const read = async (t: string): Promise<Lit[]> => (text ? templateLines(t).map(l => ({ text: l, literal: [] })) : await literals($, path, lang, t))
    const afterLits = await read(after)
    const wording = (lits: Lit[]) => wordingOf(lits.map(l => l.text))
    const { added, removed } = wordingChange(wording(await read(before)), wording(afterLits))
    if (!added.length && !removed.length) return PASS
    let hold: Hold
    if (added.length) {
      const fresh = [...new Set(added)]
      const open = await unapproved($, fresh.map(wordingKey))
      if (!open.length) return PASS
      const shown = fresh.filter(s => open.includes(wordingKey(s)))
      // The placeholders the code writes as text, which the message shown to Dan may carry (#2361).
      const literal = [...new Set(afterLits.filter(l => shown.includes(l.text)).flatMap(l => l.literal))]
      hold = { file: path, added: shown, removed, keys: open, ...(literal.length ? { literal } : {}) }
    } else {
      const keys = await unapproved($, [removalKey(path, removed)])
      if (!keys.length) return PASS
      hold = { file: path, added: [], removed, keys }
    }
    // Wording Dan has not approved: held when its file is in a git repository and is no test, and
    // either posts to Slack itself or another file in its repository sends it there.
    const found = await findSender($, path, (await $.clock.now()) + SCAN_MS, marked)
    if ('unchecked' in found) return found
    if ('posts' in found || 'maybe' in found) return { hold }
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
    const key = shellKey(command, w.files.flatMap(f => (f.path === undefined ? [] : [f.path])))
    for (const f of w.files) {
      if (f.path === undefined) continue
      if (isOwnRecord(f.path)) return { own: true }
      if (!(await $.fs.exists(f.path))) continue
      const text = String(await $.fs.read(f.path))
      const code = inScope(f.path, text)
      // A code file or a text template (#2248), in a git repository and no test: held when it posts to
      // Slack itself or another file in its repository sends it there.
      if (!code && !textTemplate(f.path)) continue
      const keys = await unapproved($, [key])
      if (!keys.length) return PASS
      deadline ??= (await $.clock.now()) + SCAN_MS
      const found = await findSender($, f.path, deadline, code && slackMarked(text))
      if ('unchecked' in found) return found
      if ('posts' in found || 'maybe' in found) return { hold: { file: f.path, added: [], removed: [], keys } }
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
  const { file, added, removed, keys, sender, literal } = v.hold
  if (id) {
    const waiting: SlackAlertPending = { id, tool, file, added, removed, keys, ...(sender ? { sender } : {}), ...(literal ? { literal } : {}), ...(agent ? { agent: true as const } : {}) }
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
      const problem = renderedProblem(ask.metadata?.rendered, waiting.added, waiting.literal ?? [])
      if (problem !== undefined) return { deny: problem }
      const rendered = String(ask.metadata?.rendered).trim()
      const q = question(waiting.file, rendered)
      const options = [
        { label: APPROVE, description: 'The wording is right. Only the edit to the file goes ahead.' },
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
