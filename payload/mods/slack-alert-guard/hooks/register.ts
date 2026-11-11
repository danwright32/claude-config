import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { SlackAlertApproval, SlackAlertChoice, SlackAlertPending } from '../types/index.d.ts'
import {
  APPROVE,
  CHANGE,
  GUARD,
  HEADER,
  MARKER_PREFILTER,
  MOST_READ,
  PATHSPEC_BYTES,
  REEXPORT_HOPS,
  SCAN_MS,
  SENDER_PREFILTER,
  SOURCE,
  agentRefusal,
  blocked,
  ciMessages,
  ciWorkflow,
  codeOf,
  copyModule,
  type Decl,
  type Foreign,
  type ModelReading,
  editHalves,
  editedText,
  foreignNames,
  foreignUse,
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
  modelCandidates,
  modelLiteral,
  modelOnlyDecls,
  modelReading,
  namePatterns,
  plainYamlValues,
  question,
  refersTo,
  refusal,
  removalKey,
  renderedProblem,
  shellKey,
  isSender,
  stringsOf,
  templateLines,
  testFile,
  uiComponent,
  textTemplate,
  tokenRanges,
  wordingChange,
  wordingKey,
  wordingOf,
} from './rules.ts'
import { type Reading, type Send, type Traced, docstrings, importedNames, jsSpans, mayBringIn, moduleBindings, pySpans, readingOf, sentAt, trace, usedWhole } from './sends.ts'
import { errorText, missingOf } from './mod-kit/skew.ts'
import { neverThrows } from './mod-kit/hold.ts'
import { CHOOSE_DESCRIPTION, CHOOSE_NAME, CHOOSE_SCHEMA, CHOOSE_TOOL, CHOSEN_PREFIX, MORNING_OPTIONS, asleepRefusal, carried, choicesOf, chosenKey, isOverdue, mergeOf, mergeRefusal, morningLines, morningQuestion } from './night.ts'

// The Slack alert guard (claude-config#2242), in a session. Dan, 2026-11-04: "anytime a slack alert
// is created, we need to have a design-rounds esque check on wording so I can approve the wording
// before it's created". An edit that changes the words a Slack posting file sends is refused until
// Dan has seen the message as Slack will post it and answered Approve wording in Claude Code's own
// dialog, which the guard words; his answer is kept by the exact wording (decision 3 in rules.ts).
// The rules are in rules.ts; this file reads files and the store, keeps the calls waiting on Dan,
// and asks him.

const pendingRef = { plugin: 'slack-alert-guard', key: 'pending' } as const
// The expired choices this session has named to Dan (#2628), so each is said once per session.
const toldRef = { plugin: 'slack-alert-guard', key: 'told' } as const

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

// from (#2637): for wording the edit adds none of and brings to a send, the files that hold it.
type Hold = { file: string; added: string[]; removed: string[]; keys: string[]; sender?: string; literal?: string[]; from?: string }
type Verdict = { pass: true } | { own: true } | { unchecked: string } | { hold: Hold } | { merge: string }
const PASS: Verdict = { pass: true }

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

// start: where the string's text starts in its file, or -1 where it has no one place (a YAML value,
// a CI step's message).
type Lit = { text: string; literal: string[]; start: number }
// Every string a file's text holds, read as its language reads them, past any handed to a query
// builder call (#2364), with the placeholders JavaScript writes as text (#2361).
const literals = async ($: EngineInterface, path: string, lang: ReturnType<typeof languageOf>, text: string): Promise<Lit[]> => {
  if (!text) return []
  if (lang === 'python') {
    // mod-kit's spans are already the text between the quotes, prefix letters and quotes left out.
    const spans = await $.modkit.pythonText({ code: text })
    const query = new Set(stringsOf(text, true).filter(s => s.query).map(s => s.start))
    // A docstring documents the code and is sent nowhere (#2574).
    const strings = spans.filter(s => s.kind === 'string' || s.kind === 'formatted')
    const docs = docstrings(readingOf(text, true, pySpans(spans)), strings)
    return strings.filter(s => !query.has(s.from) && !docs.has(s.from)).map(s => ({ text: text.slice(s.from, s.to), literal: [], start: s.from }))
  }
  // A CI workflow posts only what a Slack step carries, never its names, needs or commands (#2371).
  if (lang === 'yaml' && ciWorkflow(path)) return ciMessages(text, path).map(t => ({ text: t, literal: [], start: -1 }))
  const strings = stringsOf(text, lang !== 'c', lang === 'c' && isJs(path)).filter(s => !s.query)
  const yaml = lang === 'yaml' ? plainYamlValues(text).map(t => ({ text: t, literal: [], start: -1 })) : []
  return [...strings.map(s => ({ text: s.text, literal: s.literal, start: s.start })), ...yaml]
}

/**
 * The strings of each side of an edit that Slack can be sent, those only a model reads left out
 * (#2475): a JavaScript, TypeScript or python file's changed strings are judged by the declarations
 * holding them (rules.ts, modelOnlyDecls), and a declaration another file can import counts as read
 * only by a model only once every other file naming it has been read within the deadline. Anything
 * that cannot be read in time, or at all, leaves the string counted, so it is held as before.
 */
type Side = { text: string; lits: Lit[]; changed: string[] }
const postable = async ($: EngineInterface, path: string, lang: ReturnType<typeof languageOf>, sides: Side[], deadline: number): Promise<Lit[][]> => {
  const python = lang === 'python'
  if (!python && !(lang === 'c' && isJs(path))) return sides.map(s => s.lits)
  const readings: ModelReading[] = []
  for (const s of sides) {
    let ranges = tokenRanges(s.text, false)
    if (python) {
      const spans = s.text ? await $.modkit.pythonText({ code: s.text }) : []
      ranges = { strings: spans.filter(x => x.kind !== 'comment'), comments: spans.filter(x => x.kind === 'comment') }
    }
    readings.push(modelReading(s.text, python, ranges))
  }
  const candidates = sides.map((s, i) => {
    const changed = new Set(s.changed)
    return modelCandidates(readings[i] as ModelReading, s.lits.filter(l => l.start >= 0 && changed.has(l.text)).map(l => l.start))
  })
  const names = [...new Set(candidates.flatMap((c, i) => foreignNames(readings[i] as ModelReading, c)))]
  const foreign = await foreignUses($, path, names, deadline)
  return sides.map((s, i) => {
    const r = readings[i] as ModelReading
    const only = modelOnlyDecls(r, candidates[i] as Decl[], foreign)
    return s.lits.filter(l => l.start < 0 || !modelLiteral(r, only, l.start))
  })
}

/**
 * How the other files of `path`'s repository use each of `names` (#2475): one git grep for the files
 * naming any of them as a whole word, then a read of each, tests and docs left out since they send
 * nothing. A name missing from the answer counts as wording: a repository that cannot be named, a
 * search that fails, is cut short or runs late, more files than MOST_READ, or a file that cannot be read.
 */
const foreignUses = async ($: EngineInterface, path: string, names: string[], deadline: number): Promise<Foreign> => {
  const none: Foreign = new Map()
  if (!names.length) return none
  try {
    // The repository, placed as findSender places it: from the nearest folder that exists, by git's
    // own spelling of its top and the prefix below it.
    const repo = await placed($, path, deadline)
    if (!repo) return none
    const ms = Math.floor(deadline - (await $.clock.now()))
    if (ms <= 0) return none
    const hits = await $.process.run(['git', '-C', repo.top, 'grep', '-l', '-z', '-I', '-w', '-F', '--untracked', '--no-color', ...names.flatMap(n => ['-e', n]), '--', '.'], { timeoutMs: ms })
    if ((hits.exitCode !== 0 && hits.exitCode !== 1) || hits.isStdoutTruncated) return none
    const rels = hits.stdout.split('\u0000').filter(r => r && r !== repo.rel && !testFile(r) && !isProseFile(r))
    if (rels.length > MOST_READ) return none
    const found: Foreign = new Map(names.map(n => [n, { ok: true, model: false }]))
    for (const rel of rels) {
      if ((await $.clock.now()) >= deadline) return none
      const text = String(await $.fs.read(`${repo.top}/${rel}`))
      for (const [n, v] of found) {
        if (!v.ok) continue
        const u = foreignUse(rel, text, n)
        found.set(n, { ok: u.ok, model: v.model || u.model })
      }
    }
    return found
  } catch (err) {
    $.ui.log(`slack-alert-guard: the uses of ${names.join(', ')} could not be read, so they count as wording: ${message(err)}`, { to: 'debug' })
    return none
  }
}

// The keys of a change Dan has not yet approved; a store that cannot be read throws. While he is
// asleep, wording a session chose overnight and that has not expired goes through too (#2628): a
// choice is never an approval, so awake it is held as before.
const unapproved = async ($: EngineInterface, keys: string[]): Promise<string[]> => {
  const out: string[] = []
  for (const k of keys) if ((await $.store.get(k)) === undefined) out.push(k)
  const chosen: string[] = []
  for (const k of out) {
    const c = (await $.store.get(chosenKey(k))) as SlackAlertChoice | undefined
    if (c && c.expired === undefined) chosen.push(k)
  }
  if (!chosen.length || !(await isAsleep($))) return out
  return out.filter(k => !chosen.includes(k))
}

// Scope modes, called in place (#2628). Not loaded, or a sleep record it cannot read, is awake: the
// guard then holds as it always has, never the looser way.
type SleepModes = { isAsleep: () => Promise<boolean>; sleepNote: (note: { kind: string } & Record<string, unknown>) => Promise<{ isNoted: boolean }> }
const isAsleep = async ($: EngineInterface): Promise<boolean> => {
  try {
    return (await ($ as unknown as { scopeModes: SleepModes }).scopeModes.isAsleep()) === true
  } catch (err) {
    if (missingOf(err)?.noun !== 'scopeModes') $.ui.log(`slack-alert-guard: whether sleep mode is on could not be read, so it is taken as off: ${message(err)}`, { to: 'debug' })
    return false
  }
}

// Every choice made overnight, one per chosen call (#2628).
const choices = async ($: EngineInterface): Promise<SlackAlertChoice[]> => {
  const records: SlackAlertChoice[] = []
  for (const k of await $.store.keys()) if (k.startsWith(CHOSEN_PREFIX)) records.push((await $.store.get(k)) as SlackAlertChoice)
  return choicesOf(records.filter(r => r && typeof r.id === 'string'))
}
const chosenKeysOf = async ($: EngineInterface, id: string): Promise<string[]> => {
  const out: string[] = []
  for (const k of await $.store.keys()) if (k.startsWith(CHOSEN_PREFIX) && ((await $.store.get(k)) as SlackAlertChoice | undefined)?.id === id) out.push(k)
  return out
}

/**
 * A merge carrying wording chosen overnight (#2628): while any choice waits on Dan, each pull request
 * a command merges is read with gh pr diff, and one whose added lines carry a choice is refused, so
 * nothing posts it before he approves it. A merge that cannot be read, or a diff gh cannot give, is
 * held as could not check. With no choice waiting, no command is read.
 */
const judgeMerge = async ($: EngineInterface, command: string): Promise<Verdict> => {
  const waiting = await choices($)
  if (!waiting.length) return PASS
  const cwd = await $.session.cwd()
  const home = (await $.env.get('HOME')) ?? ''
  for (const c of await $.modkit.pipeline({ command, cwd, home })) {
    const m = mergeOf(((await $.modkit.gh({ words: c.words })) ?? (await $.modkit.mergeHelper(c))) as Parameters<typeof mergeOf>[0])
    if (m === undefined) continue
    if ('unreadable' in m) return { unchecked: 'a merge whose pull request cannot be read, while Slack alert wording chosen overnight waits on Dan' }
    const argv = ['gh', 'pr', 'diff', ...m.selector, ...(m.repo ? ['-R', m.repo] : [])]
    const r = await $.process.run(argv, { timeoutMs: SCAN_MS, cwd: c.folder ?? cwd })
    if (r.exitCode !== 0 || r.isStdoutTruncated)
      return { unchecked: `gh could not give the pull request's diff (exit ${r.exitCode}: ${r.stderr.trim().split('\n')[0] || 'cut short'}), while Slack alert wording chosen overnight waits on Dan` }
    const held = carried(r.stdout, waiting)
    if (held.length) return { merge: mergeRefusal(held) }
  }
  return PASS
}

/**
 * The wording a removal takes away that the file holds on origin (#2628): text that exists only in a
 * local commit is nothing Dan approved or anything posts, so taking it away passes in any mode. Read
 * with the same reader as the edit, from `git show origin/<default branch>:<path>`, the default branch
 * as mod-kit's one branch reader names it; a file origin lacks holds none; undefined when git or the
 * reader cannot say, which holds as before.
 */
const onOrigin = async ($: EngineInterface, path: string, read: (t: string) => Promise<{ text: string }[]>): Promise<Set<string> | undefined> => {
  const where = await placed($, path, (await $.clock.now()) + SCAN_MS)
  if (!where) return undefined
  const b = await $.modkit.branch({ path: where.top })
  if (!b || 'unreadable' in b || !b.defaultBranch) return undefined
  const r = await $.process.run(['git', '-C', where.top, 'show', `origin/${b.defaultBranch}:${where.rel}`], { timeoutMs: SCAN_MS })
  if (r.exitCode === 128 && /exists on disk, but not in|does not exist in/.test(r.stderr)) return new Set()
  if (r.exitCode !== 0 || r.isStdoutTruncated) return undefined
  return new Set((await read(r.stdout)).map(l => l.text))
}

// How much of a command's output $.process.run keeps, in MiB: the first 4194304 bytes, the rest
// dropped and the result marked isStdoutTruncated (read from Claude Code 2.1.319's own runner).
const STDOUT_KEPT_MIB = 4

/** Repository paths in their order, as groups whose `:(literal)` pathspecs come to at most PATHSPEC_BYTES each. */
const pathspecGroups = (rels: string[]): string[][] => {
  const groups: string[][] = []
  let group: string[] = []
  let bytes = 0
  for (const r of rels) {
    const size = new TextEncoder().encode(r).length + ':(literal)'.length + 1
    if (group.length && bytes + size > PATHSPEC_BYTES) {
      groups.push(group)
      group = []
      bytes = 0
    }
    group.push(r)
    bytes += size
  }
  if (group.length) groups.push(group)
  return groups
}

// posts: the file is in a repository, is no test, and posts to Slack by itself. maybe: the search
// could not tell whether a file sends the template (more files to read than it reads, or a send
// helper search that failed), so the edit is held for Dan to approve, never refused
// with nothing he can answer (#2364).
//
// senders (#2570): every file found sending the template, at the nearest level that has one, or at
// each level the caller's `settle` asks the search to go on past. complete: the search reached every
// file that hands the template on; otherwise it stopped (too many files, too late, too deep) with
// these found so far.
/** A file that sends the template: the files it reaches the template through, nearest it first, the template left out, and for one sending through a send helper it imports, that helper. */
type Sender = { rel: string; chain: string[]; helper?: string }
type Senders = { senders: Sender[]; top: string; texts: Map<string, string>; complete: boolean }
// none: nothing sends the file. With `rel` (#2720), the file is in a repository and no test, its
// path below the top is `rel`, and the search found no sender; `unused` when no file but a test
// imports it at all, so whether anything will send it cannot be told yet.
type Found = Senders | { none: true; rel?: string; unused?: boolean } | { unchecked: string } | { posts: true } | { maybe: true }
/** Whether the senders found so far settle the question, so the search may stop (#2570). */
type Settle = (senders: Sender[], top: string, texts: Map<string, string>, template: string) => Promise<boolean>
const firstSender = (f: Senders): string => `${f.top}/${(f.senders[0] as Sender).rel}`
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
 * repository to files that could carry a marker (MARKER_PREFILTER) and hold a line naming the template
 * in a form a reference takes (namePatterns, #2371), so only those are read. When none does, the files that hand the template on are followed (#2286): a
 * JavaScript, TypeScript or python file with no Slack marker that names it on an import line and can
 * export it (handsOn). Those are searched for in turn, as the template was, up to REEXPORT_HOPS files
 * deep; a chain going further is could not check. A level handed on only to UI components
 * (uiComponent) is none there, never followed past them (Dan, 2026-11-09, #2519). A template is sent too by a file that uses it and
 * imports a Slack send helper (helperUser, #2361), as a copy or notice builder is. A test or a doc is never read as a sender or a
 * link (#2290, #2361). Every git call and read is bounded by `deadline`, and anything that cannot be
 * answered in time, or at all, is could not check, so the call is held rather than let through. More
 * than MOST_READ files to read is maybe: held for Dan to approve, naming no sender (#2364).
 *
 * A file in no repository, as a scratchpad script is, has nothing that sends it, so none, even when
 * it carries a Slack marker (#2287, #2361); so is a test (#2290). A file that does carry one (`marked`)
 * and is in a repository is posts, with no search.
 *
 * `self` (#2637) is the file's own text as an edit leaves it, given when the question is what the
 * edit brings to a send from the files it imports: the file is then counted among its own senders
 * when it posts by itself or through a send helper it imports, before the files that send it.
 */
const findSender = async ($: EngineInterface, path: string, deadline: number, marked = false, settle?: Settle, self?: string): Promise<Found> => {
  const late: Found = { unchecked: `the files that could send ${path} to Slack were not searched within ${SCAN_MS / 1000} seconds` }
  // The senders found so far, and what the search returns when it stops with them in hand.
  const found: Sender[] = []
  let top = ''
  const texts = new Map<string, string>()
  const withFound = (complete: boolean, otherwise: Found): Found => (found.length ? { senders: found, top, texts, complete } : otherwise)
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
    const [named = '', prefix = ''] = where.stdout.split('\n')
    if (!named) return { unchecked: `git named no repository for ${path}` }
    top = named
    const templateRel = `${prefix}${path.slice(dir === '/' ? 1 : dir.length + 1)}`
    // A test sends nothing (#2290); a file that posts by itself, once known to be in a repository,
    // needs no search for what sends it.
    if (testFile(templateRel)) return NONE
    if (marked && !settle) return POSTS
    // What git grep prints for `what`, case ignored; none is an empty string.
    const grep = async (what: string, args: string[]): Promise<string> => {
      const ms = await left()
      if (ms <= 0) end(late)
      const hits = await $.process.run(['git', '-C', top, 'grep', '-z', '-I', '-i', '--untracked', '--no-color', ...args], { timeoutMs: ms })
      if (hits.exitCode === 1) return ''
      if (hits.exitCode !== 0)
        end({ unchecked: `git grep for the files that ${what} failed (exit ${hits.exitCode}: ${hits.stderr.trim().split('\n')[0] || 'no message'})` })
      // Cut short is not git failing: said as "exit 0: no message" it hid which listing ran long, and
      // read the same from a session still running an older copy of this search (2026-11-09).
      if (hits.isStdoutTruncated) end({ unchecked: `git grep listing the names of the files that ${what} printed more than the ${STDOUT_KEPT_MIB} MiB Claude Code keeps of a command's output, so it could not be read whole` })
      return hits.stdout
    }
    // A test sends nothing and a prose file (a doc, a CLAUDE.md, a runbook) posts nothing, so neither is
    // read as a sender or a link (#2290, #2361, #2368). A file in a language the guard does not list as
    // code (a .vue, a .sql posting through pg_net) may still send, so only prose is ruled out.
    const candidates = (rels: string[]) => rels.filter(r => !testFile(r) && !isProseFile(r))
    // Every file that could carry a Slack marker, listed once for the whole search: a sender is one of
    // these that names a level (#2371). A file that only mentions Slack is not one (MARKER_PREFILTER).
    // The files holding the word slack or postMessage are listed first, as git finds those fast, and
    // only they are searched for a marker, which over all of a large work repository took a second where this takes 0.6.
    const slackWords = candidates((await grep(`mention Slack beside ${path}`, ['-l', '-E', '-e', SENDER_PREFILTER, '--', '.'])).split('\u0000').filter(Boolean))
    const markable = new Set<string>()
    for (const group of pathspecGroups(slackWords))
      for (const r of (await grep(`could post to Slack beside ${path}`, ['-l', '-E', '-e', MARKER_PREFILTER, '--', ...group.map(r => `:(literal)${r}`)])).split('\u0000')) if (r) markable.add(r)
    /**
     * The files naming any of `level` in a form a reference takes (namePatterns), the template itself
     * left out, in the order git lists them. git first lists only the names of the files holding one
     * of the names as a whole word, and of those the search keeps the ones it can use: a file that
     * could send (markable) or hand the template on (mayHandOn), no test or prose. Only their lines
     * are listed, as fixed strings, and the shape is tested here on those lines alone, as `-e word
     * --and -e shape` tested it in git, which took seconds for a widely imported module's importers
     * (#2462). Listing every line naming a word in the whole repository (#2481) ran to 9.9 MB in a
     * work repository, past the 4 MiB $.process.run keeps, so a widely imported file's edit was held as could
     * not check. The kept files go to git by name in groups of at most PATHSPEC_BYTES; a group whose
     * lines still come back cut short is listed again in halves, and a single file whose lines alone
     * do is read whole and its lines tested here, so a listing too long is never read as no reference.
     */
    const naming = async (level: string[]): Promise<string[]> => {
      const name = namePatterns(level)
      const shape = new RegExp(name.shape, 'i')
      const what = `name ${path} or hand it on`
      // -w: every shape has the name between characters that cannot be part of one, so a file holding
      // it only inside a longer word (db in feedback) is never listed, which keeps a common short name's
      // listing small.
      const words = ['-F', '-w', ...name.words.flatMap(w => ['-e', w])]
      const listed = candidates((await grep(what, ['-l', ...words, '--', '.'])).split('\u0000').filter(Boolean)).filter(r => r !== templateRel && (markable.has(r) || mayHandOn(r)))
      const out = new Set<string>()
      const lines = async (group: string[]): Promise<void> => {
        const ms = await left()
        if (ms <= 0) end(late)
        const hits = await $.process.run(['git', '-C', top, 'grep', '-z', '-I', '-i', '--untracked', '--no-color', ...words, '--', ...group.map(r => `:(literal)${r}`)], { timeoutMs: ms })
        if (hits.exitCode === 1) return
        if (hits.exitCode !== 0) end({ unchecked: `git grep for the files that ${what} failed (exit ${hits.exitCode}: ${hits.stderr.trim().split('\n')[0] || 'no message'})` })
        if (!hits.isStdoutTruncated) {
          for (const line of hits.stdout.split('\n')) {
            const cut = line.indexOf('\u0000')
            if (cut > 0 && shape.test(line.slice(cut + 1))) out.add(line.slice(0, cut))
          }
          return
        }
        const half = Math.ceil(group.length / 2)
        if (half < group.length) {
          await lines(group.slice(0, half))
          await lines(group.slice(half))
          return
        }
        const rel = group[0] as string
        if ((await textOf(rel, what)).split('\n').some(line => shape.test(line))) out.add(rel)
      }
      for (const group of pathspecGroups(listed)) await lines(group)
      return listed.filter(r => out.has(r))
    }
    // Every file read in this search (texts), so a file listed at two levels is read once and counted once.
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
    const helperUser = async (users: { rel: string; text: string }[]): Promise<{ user: string; helper: string }[]> => {
      const specs = [...new Set(users.flatMap(u => importSpecs(u.text)))]
      if (!specs.length) return []
      const ms = await left()
      if (ms <= 0) end(MAYBE)
      const hits = await $.process.run(['git', '-C', top, 'grep', '-l', '-z', '-I', '-i', '--untracked', '-E', '-e', SENDER_PREFILTER, '--', ...specs], { timeoutMs: ms })
      if (hits.exitCode === 1) return []
      if (hits.exitCode !== 0 || hits.isStdoutTruncated) end(MAYBE)
      const helpers = candidates(hits.stdout.split('\u0000').filter(r => r && r !== templateRel))
      const pairs: { user: string; helper: string }[] = []
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
        if (!isSender(h, text as string, true)) continue
        for (const u of users) if (refersTo(u.rel, u.text, h)) pairs.push({ user: u.rel, helper: h })
      }
      return pairs
    }
    // The template, then each level of files handing the last level on, the template never again.
    const seen = new Set([templateRel])
    let level = [templateRel]
    // Each file handing the template on, and the file of the level before it that it names, so a
    // sender's way down to the template can be followed (#2570).
    const parent = new Map<string, string>()
    const chainOf = (rel: string): string[] => {
      const out: string[] = []
      for (let r: string | undefined = rel; r !== undefined && r !== templateRel; r = parent.get(r)) out.push(r)
      return out
    }
    // Senders found: the search stops, unless the caller's trace of them settles nothing and asks
    // it to go on (#2570).
    const stops = async (more: Sender[]): Promise<boolean> => {
      if (!more.length) return false
      found.push(...more)
      return !settle || (await settle(more, top, texts, templateRel))
    }
    // The file itself as the edit leaves it, when what is judged is what it brings to a send from
    // the files it imports (#2637): it posts by itself, or through a send helper it imports, as a
    // file using a template does. It is read as that text from here on, never from the disk.
    if (self !== undefined) {
      texts.set(templateRel, self)
      const own: Sender[] = isSender(templateRel, self)
        ? [{ rel: templateRel, chain: [] }]
        : (await helperUser([{ rel: templateRel, text: self }])).map(p => ({ rel: templateRel, chain: [], helper: p.helper }))
      if (await stops(own)) return { senders: found, top, texts, complete: true }
    }
    for (let hop = 0; ; hop++) {
      // Only files naming the level in a form a reference takes, so a common short name lists no crowd (#2371).
      const named = await naming(level)
      const rels = named.filter(r => markable.has(r))
      budget(rels)
      const atLevel: Sender[] = []
      for (const rel of rels) {
        // Only what a file runs can send: a comment naming the template beside a Slack webhook's name
        // posts nothing (Pivot, 2026-11-06, where it held ordinary code edits as alert wording).
        // refersTo leaves comments out itself.
        const text = await textOf(rel, sends)
        const via = isSender(rel, text) ? level.find(t => refersTo(rel, text, t)) : undefined
        if (via !== undefined) atLevel.push({ rel, chain: chainOf(via) })
      }
      if (await stops(atLevel)) return { senders: found, top, texts, complete: true }
      const links = named.filter(r => mayHandOn(r) && !seen.has(r))
      budget(links)
      const next: string[] = []
      const users: { rel: string; text: string }[] = []
      for (const rel of links) {
        // Judged by what it runs, as a sender is, so a comment neither hands the template on nor
        // stops a file that does from being followed.
        const text = await textOf(rel, handsOnTo)
        const code = codeOf(rel, text)
        const via = isSender(rel, text) ? undefined : level.find(t => refersTo(rel, text, t))
        if (via === undefined) continue
        parent.set(rel, via)
        if (handsOn(rel, code)) next.push(rel)
        users.push({ rel, text })
      }
      const helped = (await helperUser(users)).map(p => ({ rel: p.user, chain: chainOf(parent.get(p.user) as string), helper: p.helper }))
      if (await stops(helped)) return { senders: found, top, texts, complete: true }
      // A level handed on only to UI components settles here (Dan, 2026-11-09, #2519): a screen's
      // importers are other screens, and one that sent was found above. Any other file handing it
      // on means the whole level, components too, is followed as before.
      if (next.every(r => uiComponent(r))) return withFound(true, { none: true, rel: templateRel, unused: hop === 0 && !users.length })
      if (hop === REEXPORT_HOPS)
        return withFound(false, {
          unchecked: `${path} is handed on through more than ${REEXPORT_HOPS} files before anything sends it, more than the guard follows (next: ${next.map(r => `${top}/${r}`).join(', ')})`,
        })
      for (const r of next) seen.add(r)
      level = next
    }
  } catch (err) {
    if (err instanceof Ended) return withFound(false, err.found)
    return withFound(false, { unchecked: `the files that could send ${path} to Slack could not be searched: ${message(err)}` })
  }
}

/** A file read for its sends (sends.ts), python through mod-kit's reader. */
const readFor = async ($: EngineInterface, t: string, py: boolean): Promise<Reading> => readingOf(t, py, py ? pySpans(t ? await $.modkit.pythonText({ code: t }) : []) : jsSpans(t))
/** One of a search's files read for its sends, or undefined for one in a language the guard does not trace. */
const readingAt = async ($: EngineInterface, texts: Map<string, string>, rel: string): Promise<Reading | undefined> => {
  const t = texts.get(rel)
  const py = rel.endsWith('.py')
  return t === undefined || !(py || isJs(rel)) ? undefined : readFor($, t, py)
}
// Whether `upper` takes the file below it as a whole module and sends it whole (copy[key]), past
// what following names can see.
const takesWhole = (upperRel: string, r: Reading, t: Traced, lowerRel: string): boolean => moduleBindings(r).some(b => refersTo(upperRel, b.statement, lowerRel) && usedWhole(r, t, b.name))

/**
 * The names a sender sends, followed down through every file it reaches `template` by, as they
 * arrive at that file (#2570), or undefined where the way cannot be traced: a sender, its send
 * helper or a file on the way in a language the guard does not trace, a sender whose send it cannot
 * find, or a file the one above it takes whole.
 */
const sentInto = async ($: EngineInterface, s: Sender, texts: Map<string, string>, template: string): Promise<Map<string, Send> | undefined> => {
  const sr = await readingAt($, texts, s.rel)
  const helper = s.helper === undefined ? undefined : await readingAt($, texts, s.helper)
  if (!sr || (s.helper !== undefined && !helper)) return undefined
  let upper = { rel: s.rel, r: sr, t: trace(sr, new Map(), helper ? trace(helper).fns : new Set<string>()) }
  if (!upper.t.sends.length) return undefined
  let names = upper.t.names
  for (const rel of [...s.chain, template]) {
    if (takesWhole(upper.rel, upper.r, upper.t, rel)) return undefined
    if (rel === template) break
    const r = await readingAt($, texts, rel)
    if (!r) return undefined
    const t = trace(r, names)
    names = new Map([...t.names, ...names])
    upper = { rel, r, t }
  }
  return names
}

/** The repository a path is in, as git spells its top, and the path below it; undefined when git names none in time. */
const placed = async ($: EngineInterface, path: string, deadline: number): Promise<{ top: string; rel: string } | undefined> => {
  // From the nearest folder that exists, since a Write can create a file in a folder not yet made.
  let dir = path.slice(0, path.lastIndexOf('/')) || '/'
  while (dir !== '/' && !(await $.fs.exists(dir))) dir = dir.slice(0, dir.lastIndexOf('/')) || '/'
  const ms = Math.floor(deadline - (await $.clock.now()))
  if (ms <= 0) return undefined
  const where = await $.process.run(['git', '-C', dir, 'rev-parse', '--show-toplevel', '--show-prefix'], { timeoutMs: ms })
  const [top = '', prefix = ''] = where.exitCode === 0 && !where.isStdoutTruncated ? where.stdout.split('\n') : []
  return top ? { top, rel: `${prefix}${path.slice(dir === '/' ? 1 : dir.length + 1)}` } : undefined
}

/**
 * What an edit brings to a Slack send from the files the edited one imports (#2637). On 2026-11-10
 * a new copy module of four alert messages was written while nothing sent it, so it passed; the
 * edits that made a monitor route import it and post it added no text of their own, so they passed
 * too. A new file nothing sends still passes, since nothing can post it and most new files never
 * will be posted, unless it is a module of message copy, whose wording is held as it is written
 * (#2720, ownWording). The edit that makes a send reach it is what is judged, whenever it comes: once
 * the edit's own wording has passed, each sender through the edited file (the file itself when it
 * posts or uses a send helper, then every file that sends it) is traced as the edit leaves the file
 * and as it was, down through the files it imports, and wording a send reaches only afterwards,
 * which Dan has not approved, is held. So wording a sender already sent, older than the guard, is
 * not asked about again, and a name imported for a 404 answer is held only when a send takes it.
 *
 * Only JavaScript, TypeScript and python are traced. A sender or module that cannot be traced
 * counts every string of the files it imports, on both sides, so there it is a newly imported file
 * that is held; so does a search for senders that stopped short. Anything that cannot be read or
 * listed in time, and names newly handed on through more files than the guard follows, is could
 * not check.
 */
const broughtIn = async ($: EngineInterface, path: string, before: string, after: string, deadline: number): Promise<Verdict> => {
  const lang = languageOf(path, after)
  const python = lang === 'python'
  if (!python && !(lang === 'c' && isJs(path))) return PASS
  const [rBefore, rAfter] = [await readFor($, before, python), await readFor($, after, python)]
  if (!mayBringIn(rBefore, rAfter)) return PASS
  let top = ''
  const left = async () => Math.floor(deadline - (await $.clock.now()))
  const late = (): never => end({ unchecked: `what this edit to ${path} brings to a Slack send was not searched within ${SCAN_MS / 1000} seconds` })
  // Each imported file, read once: its strings, and its reading where its sends can be traced. A
  // file that holds no message text the guard reads (a JSON file, a stylesheet) is null.
  type Mod = { path: string; text: string; lang: ReturnType<typeof languageOf>; lits: Lit[]; r?: Reading }
  const mods = new Map<string, Mod | null>()
  const moduleOf = async (rel: string): Promise<Mod | null> => {
    const known = mods.get(rel)
    if (known !== undefined) return known
    if ((await left()) <= 0) late()
    if (mods.size >= MOST_READ) end({ unchecked: `this edit to ${path} reaches more than ${MOST_READ} imported files, more than the guard reads` })
    const p = `${top}/${rel}`
    let mod: Mod | null = null
    if (await $.fs.exists(p)) {
      let text = ''
      try {
        text = String(await $.fs.read(p))
      } catch (err) {
        end({ unchecked: `${p}, which this edit to ${path} may bring to a Slack send, could not be read: ${message(err)}` })
      }
      const template = textTemplate(p)
      if (template || inScope(p, text)) {
        const l = languageOf(p, text)
        const traced = !template && (l === 'python' || (l === 'c' && isJs(p)))
        const lits = template ? templateLines(text).map(t => ({ text: t, literal: [], start: -1 })) : await literals($, p, l, text)
        mod = { path: p, text, lang: l, lits, ...(traced ? { r: await readFor($, text, l === 'python') } : {}) }
      }
    }
    mods.set(rel, mod)
    return mod
  }
  // The files a file's text imports, found by the paths its imports name, as a send helper is (#2371).
  const lists = new Map<string, string[]>()
  const importsOf = async (rel: string, text: string): Promise<string[]> => {
    const key = `${rel}\u0000${text}`
    const known = lists.get(key)
    if (known) return known
    const specs = importSpecs(text)
    let rels: string[] = []
    if (specs.length) {
      const ms = await left()
      if (ms <= 0) late()
      const out = await $.process.run(['git', '-C', top, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', ...specs], { timeoutMs: ms })
      if (out.exitCode !== 0 || out.isStdoutTruncated)
        end({ unchecked: `git could not list the files ${top}/${rel} imports (exit ${out.exitCode}: ${out.stderr.trim().split('\n')[0] || 'no message'})` })
      rels = [...new Set(out.stdout.split('\u0000'))].filter(r => r && r !== rel && !testFile(r) && !isProseFile(r) && refersTo(rel, text, r))
    }
    lists.set(key, rels)
    return rels
  }
  // sent: by imported file, its wording a send reaches. cut: by file, the names still handed on
  // where the guard stops following.
  type Reached = { sent: Map<string, Set<string>>; cut: Map<string, Set<string>> }
  const put = (m: Map<string, Set<string>>, k: string, vs: string[]) => {
    const s = m.get(k) ?? new Set<string>()
    for (const v of vs) s.add(v)
    m.set(k, s)
  }
  /**
   * The wording a send reaches in the files `text` imports, followed by the names sent (`names`,
   * with `t` the trace of `text` itself) down through each file that hands one on, up to
   * REEXPORT_HOPS files deep. With no trace (`t` undefined) every string of the files `text` names
   * counts and nothing is followed further, as for a file one above takes whole or one in a language
   * the guard does not trace.
   */
  const reach = async (rel: string, text: string, r: Reading, t: Traced | undefined, names: Map<string, Send>): Promise<Reached> => {
    const out: Reached = { sent: new Map(), cut: new Map() }
    type At = { rel: string; text: string; r: Reading; t?: Traced; names: Map<string, Send>; way: string[] }
    const todo: At[] = [{ rel, text, r, ...(t ? { t } : {}), names, way: [rel] }]
    while (todo.length) {
      const x = todo.shift() as At
      for (const m of await importsOf(x.rel, x.text)) {
        if (x.way.includes(m)) continue
        const mod = await moduleOf(m)
        if (!mod) continue
        const tm = x.t && mod.r && !takesWhole(x.rel, x.r, x.t, m) ? trace(mod.r, x.names) : undefined
        put(out.sent, m, wordingOf(mod.lits.filter(l => !tm || (l.start >= 0 && sentAt(tm, l.start))).map(l => l.text)))
        if (!tm || !mod.r) continue
        // Followed on only where a name a send carries is one this file imports or hands on.
        const on = new Map([...tm.names, ...x.names])
        const bound = importedNames(mod.r)
        const flows = [...on.keys()].filter(n => bound.has(n))
        if (mod.r.python ? /^[ \t]*from[ \t]+[\w.]+[ \t]+import[ \t]+\*/m.test(mod.r.skel) : /(?<![\w$.])export\s*\*/.test(mod.r.skel)) flows.push('*')
        if (!flows.length) continue
        if (x.way.length > REEXPORT_HOPS) put(out.cut, m, flows)
        else todo.push({ rel: m, text: mod.text, r: mod.r, t: tm, names: on, way: [...x.way, m] })
      }
    }
    return out
  }
  // The hold for what a send reaches after the edit and did not before, of it only what Dan has not
  // approved and Slack can be sent (text only a model reads left out, #2475).
  const freshOf = async (now: Reached, was: Reached | undefined): Promise<Hold | undefined> => {
    for (const [m, names] of now.cut)
      if ([...names].some(n => !was?.cut.get(m)?.has(n)))
        end({ unchecked: `this edit to ${path} hands what a Slack send carries on through more than ${REEXPORT_HOPS} files below it, more than the guard follows (next: ${top}/${m})` })
    const added: string[] = []
    const literal: string[] = []
    const from: string[] = []
    for (const [m, strings] of now.sent) {
      const fresh = [...strings].filter(s => !was?.sent.get(m)?.has(s))
      if (!fresh.length) continue
      const open = await unapproved($, fresh.map(wordingKey))
      const shown = fresh.filter(s => open.includes(wordingKey(s)))
      if (!shown.length) continue
      const mod = mods.get(m) as Mod
      const [kept = []] = await postable($, mod.path, mod.lang, [{ text: mod.text, lits: mod.lits, changed: shown }], deadline)
      const postableText = new Set(wordingOf(kept.map(l => l.text)))
      for (const s of shown) {
        if (!postableText.has(s) || added.includes(s)) continue
        added.push(s)
        literal.push(...mod.lits.filter(l => l.text === s).flatMap(l => l.literal))
        if (!from.includes(mod.path)) from.push(mod.path)
      }
    }
    return added.length ? { file: path, added, removed: [], keys: added.map(wordingKey), from: from.join(', '), ...(literal.length ? { literal: [...new Set(literal)] } : {}) } : undefined
  }
  const failed = (err: unknown): Verdict => ({ unchecked: err instanceof Ended && 'unchecked' in err.found ? err.found.unchecked : message(err) })
  let verdict: Verdict | undefined
  const settle: Settle = async (senders, repo, texts, template) => {
    top = repo
    try {
      for (const s of senders) {
        let now: Reached
        let was: Reached | undefined
        if (s.rel === template) {
          // The edited file sends by itself, or through its send helper: what its own sends reach.
          const helper = s.helper === undefined ? undefined : await readingAt($, texts, s.helper)
          const traced = s.helper === undefined || helper !== undefined
          const fns = helper ? trace(helper).fns : new Set<string>()
          const side = async (text: string, r: Reading): Promise<Reached> => {
            const t = traced ? trace(r, new Map(), fns) : undefined
            return reach(template, text, r, t?.sends.length ? t : undefined, t?.names ?? new Map())
          }
          now = await side(after, rAfter)
          // Whether it was a sender before the edit: it carried a marker, or imported the helper.
          if (s.helper === undefined ? isSender(template, before) : refersTo(template, before, s.helper)) was = await side(before, rBefore)
        } else {
          const door = await sentInto($, s, texts, template)
          const side = async (text: string, r: Reading): Promise<Reached> => {
            if (!door) return reach(template, text, r, undefined, new Map())
            const t = trace(r, door)
            return reach(template, text, r, t, new Map([...t.names, ...door]))
          }
          now = await side(after, rAfter)
          if (before) was = await side(before, rBefore)
        }
        const hold = await freshOf(now, was)
        if (hold) {
          verdict = { hold: s.rel === template ? hold : { ...hold, sender: `${top}/${s.rel}` } }
          return true
        }
      }
      return false
    } catch (err) {
      verdict = failed(err)
      return true
    }
  }
  const found = await findSender($, path, deadline, false, settle, after)
  if (verdict) return verdict
  if ('unchecked' in found) return found
  if ('none' in found || ('senders' in found && found.complete)) return PASS
  // The search for senders stopped short (too many files, too late, too deep), so one further on
  // may send anything this file imports: every string of a newly imported file is held, as the rest
  // of an edit is when its own search stops short.
  // A search that ran out of time says so (#2719): git given what was left of it, or none, was read
  // as "git could not name the repository" and as git "aborted: still running after 12ms".
  const lateNow = async (): Promise<Verdict | undefined> => ((await left()) <= 0 ? { unchecked: `what this edit to ${path} brings to a Slack send was not searched within ${SCAN_MS / 1000} seconds` } : undefined)
  try {
    const at = await placed($, path, deadline)
    if (!at) return (await lateNow()) ?? { unchecked: `git could not name the repository ${path} is in, so what this edit brings to a Slack send could not be told` }
    top = at.top
    const hold = await freshOf(await reach(at.rel, after, rAfter, undefined, new Map()), before ? await reach(at.rel, before, rBefore, undefined, new Map()) : undefined)
    if (!hold) return PASS
    return { hold: 'senders' in found ? { ...hold, sender: firstSender(found) } : hold }
  } catch (err) {
    return (err instanceof Ended ? undefined : await lateNow()) ?? failed(err)
  }
}

const judgeEdit = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<Verdict> => {
  const path = typeof input.file_path === 'string' ? input.file_path : ''
  if (!path) return PASS
  if (isOwnRecord(path)) return { own: true }
  let current = ''
  let started = 0
  try {
    started = await $.clock.now()
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
  const own = await ownWording($, { path, current, edited, before, after, code, text })
  // The edit's own wording passed: it is still judged for the wording it brings to a send from the
  // files it imports (#2637), inside the one search time the whole call has. An edit that does not
  // apply leaves the file as it was, so brings nothing.
  if (!('pass' in own) || !code || edited === undefined) return own
  try {
    return await broughtIn($, path, before, after, started + SCAN_MS)
  } catch (err) {
    return { unchecked: message(err) }
  }
}

/** The verdict on the wording an edit changes in its own file. */
type EditOf = { path: string; current: string; edited: string | undefined; before: string; after: string; code: boolean; text: boolean }
const ownWording = async ($: EngineInterface, { path, current, edited, before, after, code, text }: EditOf): Promise<Verdict> => {
  const marked = code && (isSender(path, current, true) || isSender(path, after, true))
  try {
    const lang = languageOf(path, current || after)
    const read = async (t: string): Promise<Lit[]> => (text ? templateLines(t).map(l => ({ text: l, literal: [], start: -1 })) : await literals($, path, lang, t))
    const afterLits = await read(after)
    const beforeLits = await read(before)
    const wording = (lits: Lit[]) => wordingOf(lits.map(l => l.text))
    // The hold for a change, or none when it changes no wording Dan has not approved.
    const holdOf = async ({ added, removed }: { added: string[]; removed: string[] }): Promise<Hold | undefined> => {
      if (added.length) {
        const fresh = [...new Set(added)]
        const open = await unapproved($, fresh.map(wordingKey))
        if (!open.length) return undefined
        const shown = fresh.filter(s => open.includes(wordingKey(s)))
        // The placeholders the code writes as text, which the message shown to Dan may carry (#2361).
        const literal = [...new Set(afterLits.filter(l => shown.includes(l.text)).flatMap(l => l.literal))]
        return { file: path, added: shown, removed, keys: open, ...(literal.length ? { literal } : {}) }
      }
      if (!removed.length) return undefined
      const keys = await unapproved($, [removalKey(path, removed)])
      if (!keys.length) return undefined
      // Text origin does not hold was never live, so taking it away takes nothing Dan approved (#2628).
      origin ??= await onOrigin($, path, read)
      if (origin && removed.every(s => !origin?.has(s))) return undefined
      return { file: path, added: [], removed, keys }
    }
    let origin: Set<string> | undefined
    const change = wordingChange(wording(beforeLits), wording(afterLits))
    if (!(await holdOf(change))) return PASS
    const deadline = (await $.clock.now()) + SCAN_MS
    // The hold for `part` of the change, of it only what Slack can be sent: text only a model reads
    // is left out (#2475), so a model's instructions beside an alert are never held, nor shown to Dan
    // as one.
    type Part = { added: string[]; removed: string[] }
    const holdFor = async (part: Part, sender?: string): Promise<Verdict> => {
      const [beforeKept, afterKept] = text
        ? [beforeLits, afterLits]
        : await postable($, path, lang, [{ text: before, lits: beforeLits, changed: part.removed }, { text: after, lits: afterLits, changed: part.added }], deadline)
      const kept = wordingChange(wording(beforeKept as Lit[]), wording(afterKept as Lit[]))
      const hold = await holdOf({ added: kept.added.filter(s => part.added.includes(s)), removed: kept.removed.filter(s => part.removed.includes(s)) })
      if (!hold) return PASS
      return { hold: sender ? { ...hold, sender } : hold }
    }
    const python = lang === 'python'
    // Wording added to a module of message copy that no file uses yet (#2720): held as it is
    // written, since it is there to be sent, rather than only once a later edit wires it to a send
    // and is blamed for it. Only where the file is in a repository and no test and no file but a
    // test imports it, so its sends cannot be traced yet. A module something already uses is judged
    // by what that use sends, as before: a sender's by what it sends (#2570), a screen's or a route
    // that posts nothing by nothing (#2519). Text taken away from a file nothing uses changes no
    // message.
    const copyHold = async (found: Found, added: string[]): Promise<Verdict> => {
      if (!('none' in found) || !found.unused || found.rel === undefined || !added.length) return PASS
      if (!copyModule(found.rel, after)) return PASS
      return holdFor({ added, removed: [] })
    }
    // Wording Dan has not approved, in a file whose sends cannot be traced (a text template, a
    // workflow, a shell script, an edit that does not apply): held when its file is in a git
    // repository and is no test, and either posts to Slack itself or another file in its repository
    // sends it there, or it is a module of message copy no file uses yet (#2720).
    if (text || edited === undefined || !(python || (lang === 'c' && isJs(path)))) {
      const found = await findSender($, path, deadline, marked)
      if ('unchecked' in found) return found
      if (!('posts' in found || 'maybe' in found || 'senders' in found)) return copyHold(found, change.added)
      return holdFor(change, 'senders' in found ? firstSender(found) : undefined)
    }
    // Only wording a Slack send carries is held (#2570): each changed string is traced to the send it
    // reaches, in this file, then from each file that sends this one.
    const [rBefore, rAfter] = [await readFor($, before, python), await readFor($, after, python)]
    const sentIn = (tBefore: Traced, tAfter: Traced, part: Part): Part => ({
      added: part.added.filter(s => afterLits.some(l => l.text === s && l.start >= 0 && sentAt(tAfter, l.start))),
      removed: part.removed.filter(s => beforeLits.some(l => l.text === s && l.start >= 0 && sentAt(tBefore, l.start))),
    })
    const [tBefore, tAfter] = [trace(rBefore), trace(rAfter)]
    // A file that posts to Slack by a send the guard cannot find is held as before.
    if (marked && !tBefore.sends.length && !tAfter.sends.length) {
      const found = await findSender($, path, deadline, true)
      if ('unchecked' in found) return found
      return 'posts' in found ? holdFor(change) : PASS
    }
    const here = sentIn(tBefore, tAfter, change)
    if (here.added.length || here.removed.length) {
      // In a repository and no test, as a file posting by itself must be.
      const found = await findSender($, path, deadline, true)
      if ('unchecked' in found) return found
      if (!('posts' in found)) return PASS
      const held = await holdFor(here)
      if (!('pass' in held)) return held
    }
    const rest: Part = { added: change.added.filter(s => !here.added.includes(s)), removed: change.removed.filter(s => !here.removed.includes(s)) }
    if (!rest.added.length && !rest.removed.length) return PASS
    // The rest of the change, judged by the files that send this one: each is traced, and the names
    // it sends followed down through every file it reaches this one by. A sender, or a file on its way
    // down, the guard cannot trace holds the change as before, naming it.
    let verdict: { held: Verdict } | { untraced: string } | undefined
    const settle: Settle = async (senders, top, texts, template) => {
      for (const s of senders) {
        const names = await sentInto($, s, texts, template)
        if (!names) return ((verdict = { untraced: `${top}/${s.rel}` }), true)
        const sent = sentIn(trace(rBefore, names), trace(rAfter, names), rest)
        if (!sent.added.length && !sent.removed.length) continue
        // Only wording Dan has not approved settles the search. Once he has approved what this
        // sender sends, a sender further along may still send the rest of the change, so the search
        // goes on: stopping here let that rest through unasked on the call sent again (#2637).
        const held = await holdFor(sent, `${top}/${s.rel}`)
        if (!('pass' in held)) return ((verdict = { held }), true)
      }
      return false
    }
    const found = await findSender($, path, deadline, false, settle)
    if (verdict && 'untraced' in verdict) return holdFor(rest, verdict.untraced)
    if (verdict) return verdict.held
    if ('unchecked' in found) return found
    // A search that stopped short (too many files, too late, too deep) cannot rule out a sender further
    // on, so the rest is held as before.
    if ('maybe' in found) return holdFor(rest)
    if ('senders' in found && !found.complete) return holdFor(rest, firstSender(found))
    return copyHold(found, rest.added)
  } catch (err) {
    return { unchecked: message(err) }
  }
}

const judgeShell = async ($: EngineInterface, input: Record<string, unknown>): Promise<Verdict> => {
  const command = typeof input.command === 'string' ? input.command : ''
  if (!command) return PASS
  if (mentionsStore(command)) return { own: true }
  try {
    const merging = await judgeMerge($, command)
    if (!('pass' in merging)) return merging
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
      const found = await findSender($, f.path, deadline, code && isSender(f.path, text, true))
      if ('unchecked' in found) return found
      if ('posts' in found || 'maybe' in found) return { hold: { file: f.path, added: [], removed: [], keys } }
      if ('senders' in found) return { hold: { file: f.path, added: [], removed: [], keys, sender: firstSender(found) } }
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
  if ('merge' in v) {
    await drawCard($, id, 'This pull request carries Slack alert wording chosen overnight that you have not approved.', 'It merges once you approve the wording.')
    return v.merge
  }
  const { file, added, removed, keys, sender, literal, from } = v.hold
  // Asleep, wording an edit changes is chosen by the session itself and kept for Dan's morning
  // (#2628); a shell command's wording cannot be read before it runs, so it is held as before.
  const choosing = id !== '' && (added.length > 0 || removed.length > 0) && (await isAsleep($))
  if (id) {
    const waiting: SlackAlertPending = { id, tool, file, added, removed, keys, ...(sender ? { sender } : {}), ...(literal ? { literal } : {}), ...(from ? { from } : {}), ...(agent ? { agent: true as const } : {}) }
    await update($, pendingRef, p => [...(p ?? []).filter(x => x.id !== id), waiting])
    const safeWay = choosing ? 'You are asleep: Claude chooses the wording and asks you in the morning.' : agent ? 'The main session asks you about it.' : 'Claude shows you the message as Slack will post it and asks you to approve the wording.'
    await drawCard($, id, `${heldText(file, added, removed, sender, from)}.`, safeWay)
  }
  if (choosing) return asleepRefusal(blocked(file, added, removed, sender, from), id)
  return agent ? agentRefusal(id, file, added, removed, sender, from) : refusal(id, file, added, removed, sender, from)
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

    // Wording chosen overnight, put to Dan in the morning (#2628): only his Approve wording records an
    // approval; anything else leaves the choice held and asked again.
    const morning = async (id: string) => {
      const keys = await chosenKeysOf($, id)
      const c = (await choices($)).find(x => x.id === id)
      if (!c || !keys.length) return { deny: `No Slack alert wording chosen overnight waits under ${id}: it was answered already.` }
      if (await isAsleep($)) return { deny: 'Dan is asleep (sleep mode), so the wording chosen overnight is put to him in the morning, not now.' }
      if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
        return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this.' }
      const q = morningQuestion(c)
      const r = await next({ ...e, questions: [{ question: q, header: HEADER, options: MORNING_OPTIONS, multiSelect: false }] } as typeof e)
      if (r.deny !== undefined || r.isError) return r
      const out = (r.result ?? {}) as AskResult
      const shown = typeof out.questions?.[0]?.question === 'string' ? (out.questions[0].question as string) : q
      const still = `the wording chosen overnight for ${c.file} stays held, and no pull request carrying it can merge`
      if (out.afkTimeoutMs !== undefined) return say(r, `Dan did not answer: the dialog closed by itself while he was away, so nothing is recorded and ${still}. It is put to him again at his next message.`)
      const chosen = out.answers?.[shown] ?? out.answers?.[q]
      if (typeof chosen !== 'string' || !chosen.trim()) return say(r, `Dan gave no answer, so nothing is recorded and ${still}. It is put to him again at his next message.`)
      if (chosen === CHANGE) return say(r, `Dan answered ${CHANGE}: nothing is recorded, and ${still}. Ask him what it should say, change it in ${c.file}, and show him the new message, which is asked about as any new wording is.`)
      if (chosen !== APPROVE) {
        const again = 'put the wording chosen overnight to him again'
        try {
          return say(r, await $.modkit.typedAnswer({ guard: GUARD, typed: chosen, still, again }))
        } catch (err) {
          return say(r, `Dan typed "${chosen}" instead of choosing, so nothing is recorded, and ${still}; mod-kit could not tell him so (${message(err)}). Tell him that in one line, answer what he said, then ${again}.`)
        }
      }
      try {
        const now = await $.clock.now()
        const text = c.added.length ? c.added : c.removed
        for (const k of c.keys) await $.store.set(k, { at: now, file: c.file, text, rendered: c.rendered } satisfies SlackAlertApproval)
        for (const k of keys) await $.store.delete(k)
      } catch (err) {
        return say(r, `Dan answered ${APPROVE}, but it could not be recorded (${message(err)}), so ${still}. Tell him, and ask again.`)
      }
      return say(r, `Dan answered ${APPROVE}: the wording chosen overnight for ${c.file} is recorded as approved, and a pull request carrying it may merge.`)
    }

    const decide = async () => {
      if (e.agentId !== undefined) return { deny: 'Only the main session asks Dan about Slack alert wording. Stop and report to the main session that this waits on him.' }
      const id = source.slice(SOURCE.length + 1)
      if (id.startsWith(CHOSEN_PREFIX)) return morning(id.slice(CHOSEN_PREFIX.length))
      const waiting = ((await $.state.get(pendingRef)).value ?? []).find(x => x.id === id)
      if (!waiting) return { deny: `No Slack alert edit is waiting under ${id}: it was answered already, or the session ended. Make the edit again, and you will be told how to ask.` }
      if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
        return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this.' }
      const problem = renderedProblem(ask.metadata?.rendered, waiting.added, waiting.literal ?? [])
      if (problem !== undefined) return { deny: problem }
      const rendered = String(ask.metadata?.rendered).trim()
      const q = question(waiting.file, rendered, waiting.from)
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
  // Wording this session chose overnight is handed to whichever session Dan writes in next (#2628),
  // so a choice never goes unasked because the session that made it ended.
  on('session.end', async ($, e, next) => {
    await $.state.set(pendingRef, [])
    try {
      const self = await $.session.id()
      for (const k of await $.store.keys()) {
        if (!k.startsWith(CHOSEN_PREFIX)) continue
        const c = (await $.store.get(k)) as SlackAlertChoice | undefined
        if (c?.session === self) await $.store.set(k, { ...c, session: null } satisfies SlackAlertChoice)
      }
    } catch (err) {
      $.ui.log(`slack-alert-guard: the wording this session chose overnight could not be handed on: ${message(err)}`, { to: 'debug' })
    }
    return next(e)
  })

  on('session.start', async ($, e, next) => {
    await $.tool.register({ name: CHOOSE_NAME, description: CHOOSE_DESCRIPTION, inputSchema: CHOOSE_SCHEMA, isDeferred: false })
    return next(e)
  })

  // Held wording chosen while Dan is asleep (#2628), by the session or agent it was held for: recorded
  // apart from his approvals, never as one, and noted for the night's report. Answered here and never
  // passed down, so the guards beneath are asked through mod-kit's screen first.
  on('tool.call', { tool: CHOOSE_TOOL }, async ($, e) => {
    const refused = await $.modkit.screen(e as never)
    if (refused) return refused
    const { tool_use_id: _i, agentId, consent: _c, tool: _t, ...input } = e as unknown as Record<string, unknown>
    const call = String(input.call ?? '')
    const waiting = ((await $.state.get(pendingRef)).value ?? []).find(x => x.id === call)
    if (!waiting || (waiting.agent === true) !== (agentId !== undefined) || (!waiting.added.length && !waiting.removed.length))
      return { deny: `No Slack alert edit of yours is held under ${call}: it was chosen or answered already, or never held. Send the edit, and if it is held you are told what to do.` }
    if (!(await isAsleep($)))
      return {
        deny: `Dan is awake, so he approves this wording himself rather than a choice being made for him: ${waiting.agent ? agentRefusal(call, waiting.file, waiting.added, waiting.removed, waiting.sender, waiting.from) : refusal(call, waiting.file, waiting.added, waiting.removed, waiting.sender, waiting.from)}`,
      }
    const problem = renderedProblem(input.rendered, waiting.added, waiting.literal ?? [])
    if (problem !== undefined) return { deny: problem.replace('Give metadata "rendered"', 'Give "rendered"') }
    const rendered = String(input.rendered).trim()
    const choice: SlackAlertChoice = {
      id: call,
      at: await $.clock.now(),
      file: waiting.file,
      added: waiting.added,
      removed: waiting.removed,
      keys: waiting.keys,
      rendered,
      session: await $.session.id(),
      ...(waiting.sender ? { sender: waiting.sender } : {}),
      ...(waiting.from ? { from: waiting.from } : {}),
    }
    for (const k of waiting.keys) await $.store.set(chosenKey(k), choice)
    await update($, pendingRef, p => (p ?? []).filter(x => x.id !== call))
    let noted = ''
    try {
      const n = await ($ as unknown as { scopeModes: SleepModes }).scopeModes.sleepNote({ kind: 'wording', text: `Slack alert wording chosen overnight for ${waiting.file}, not yet approved, put to Dan in the morning by the Slack alert guard: ${rendered}` })
      if (!n.isNoted) noted = ' Sleep mode did not take the note for the night report, so the report will not list it; the morning question still comes.'
    } catch (err) {
      noted = ` The note for the night report could not be written (${message(err)}); the morning question still comes.`
    }
    const resend = `Send the ${waiting.tool} call to ${waiting.file} again now, unchanged.`
    return { result: `Recorded as this session's choice, not approved: Dan is asked in the morning whether to keep it, and no pull request carrying it can merge until he approves it. ${resend}${noted}` }
  }).catch(($, e, next) => neverThrows(() => ({ deny: `The Slack alert guard could not record the choice (${message(next.error)}), so the edit stays held.` }), () => ({ deny: HELD }), { deny: HELD }))

  // In the morning (#2628): each choice waiting on Dan is put to him by the session that made it, or
  // by any session once that one ended; one past its time is marked expired, said once in every
  // session, and stays held.
  on('prompt.submit', async ($, e, next) => {
    const r = await next(e)
    if (r.drop !== undefined) return r
    try {
      if (await isAsleep($)) return r
      const all = await choices($)
      if (!all.length) return r
      const now = await $.clock.now()
      for (const c of all.filter(x => isOverdue(x, now))) {
        for (const k of await chosenKeysOf($, c.id)) await $.store.set(k, { ...((await $.store.get(k)) as SlackAlertChoice), expired: now } satisfies SlackAlertChoice)
        c.expired = now
      }
      const told = (await $.state.get(toldRef)).value ?? []
      const lines = morningLines(all, await $.session.id(), told)
      const fresh = all.filter(c => c.expired !== undefined && !told.includes(c.id)).map(c => c.id)
      if (fresh.length) await $.state.set(toldRef, [...told, ...fresh])
      return lines.length ? { ...r, context: [...(r.context ?? []), ...lines] } : r
    } catch (err) {
      // Never read as nothing waiting: Claude is told, so Dan hears that a choice may be unasked.
      const line = `The Slack alert guard could not read the wording chosen overnight (${message(err)}), so any choice waiting on Dan is not listed here: tell him in one line. Pull requests carrying it still cannot merge.`
      return { ...r, context: [...(r.context ?? []), line] }
    }
  })
}
