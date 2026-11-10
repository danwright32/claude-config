import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { SlackAlertApproval, SlackAlertPending } from '../types/index.d.ts'
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
  ciMessages,
  ciWorkflow,
  codeOf,
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
  slackMarked,
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
    return spans.filter(s => (s.kind === 'string' || s.kind === 'formatted') && !query.has(s.from)).map(s => ({ text: text.slice(s.from, s.to), literal: [], start: s.from }))
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
    let dir = path.slice(0, path.lastIndexOf('/')) || '/'
    while (dir !== '/' && !(await $.fs.exists(dir))) dir = dir.slice(0, dir.lastIndexOf('/')) || '/'
    const left = async () => Math.floor(deadline - (await $.clock.now()))
    let ms = await left()
    if (ms <= 0) return none
    const where = await $.process.run(['git', '-C', dir, 'rev-parse', '--show-toplevel', '--show-prefix'], { timeoutMs: ms })
    const [top = '', prefix = ''] = where.exitCode === 0 && !where.isStdoutTruncated ? where.stdout.split('\n') : []
    if (!top) return none
    const repo = { top, rel: `${prefix}${path.slice(dir === '/' ? 1 : dir.length + 1)}` }
    ms = await left()
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

// The keys of a change Dan has not yet approved; a store that cannot be read throws.
const unapproved = async ($: EngineInterface, keys: string[]): Promise<string[]> => {
  const out: string[] = []
  for (const k of keys) if ((await $.store.get(k)) === undefined) out.push(k)
  return out
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
      const rels = named.filter(r => markable.has(r))
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
      // A level handed on only to UI components settles here (Dan, 2026-11-09, #2519): a screen's
      // importers are other screens, and one that sent was found above. Any other file handing it
      // on means the whole level, components too, is followed as before.
      if (next.every(r => uiComponent(r))) return NONE
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
      return keys.length ? { file: path, added: [], removed, keys } : undefined
    }
    const change = wordingChange(wording(beforeLits), wording(afterLits))
    if (!(await holdOf(change))) return PASS
    // Wording Dan has not approved: held when its file is in a git repository and is no test, and
    // either posts to Slack itself or another file in its repository sends it there.
    const deadline = (await $.clock.now()) + SCAN_MS
    const found = await findSender($, path, deadline, marked)
    if ('unchecked' in found) return found
    if (!('posts' in found || 'maybe' in found || 'sender' in found)) return PASS
    // Of that wording, only what Slack can be sent: text only a model reads is left out (#2475), so a
    // model's instructions beside an alert are never held, nor shown to Dan as one.
    const [beforeKept, afterKept] = text
      ? [beforeLits, afterLits]
      : await postable($, path, lang, [{ text: before, lits: beforeLits, changed: change.removed }, { text: after, lits: afterLits, changed: change.added }], deadline)
    const hold = await holdOf(wordingChange(wording(beforeKept as Lit[]), wording(afterKept as Lit[])))
    if (!hold) return PASS
    return 'sender' in found ? { hold: { ...hold, sender: found.sender } } : { hold }
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
