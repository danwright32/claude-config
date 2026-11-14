import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { SlackAlertApproval, SlackAlertChoice, SlackAlertPending, SlackAlertSend } from '../types/index.d.ts'
import {
  APPROVE,
  CHANGE,
  GUARD,
  HEADER,
  MOST_READ,
  SCAN_MS,
  SOURCE,
  agentRefusal,
  blocked,
  cannotCheck,
  ciMessages,
  ciWorkflow,
  type Decl,
  type Foreign,
  type ModelReading,
  editHalves,
  editedText,
  foreignNames,
  foreignUse,
  heldText,
  hookFailed,
  inScope,
  isJs,
  isOwnRecord,
  isProseFile,
  languageOf,
  mentionsStore,
  modelCandidates,
  modelFed,
  modelLiteral,
  modelOnlyDecls,
  modelReading,
  outOfTime,
  patchFiles,
  patchPlacing,
  plainYamlValues,
  question,
  refusal,
  removalKey,
  renderedProblem,
  requestLanguage,
  shellKey,
  shellLogWording,
  isSender,
  stringsOf,
  testFile,
  tokenRanges,
  UNTRACED_EDIT,
  UNTRACED_LANGUAGE,
  UNTRACED_NONE,
  FILES_JQ,
  wordingChange,
  wordingKey,
  wordingOf,
  writesOwnRecord,
} from './rules.ts'
import { type Reading, type Traced, consoleArgs, docstrings, jsSpans, pySpans, readingOf, scanWork, sentAt, trace } from './sends.ts'
import { errorText, missingOf } from './mod-kit/skew.ts'
import { neverThrows } from './mod-kit/hold.ts'
import { type InputFs, inputTexts } from './mod-kit/inputs.ts'
import { CHOOSE_DESCRIPTION, CHOOSE_NAME, CHOOSE_SCHEMA, CHOOSE_TOOL, CHOSEN_PREFIX, MORNING_OPTIONS, asleepRefusal, carried, choicesOf, chosenKey, isOverdue, mergeOf, mergeRefusal, morningLines, morningQuestion, waitingNamed } from './night.ts'

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
// The catches' last word, built before anything can fail (#2039).
const HELD = cannotCheck('unknown failure')

// A held edit or shell write to a file that posts to Slack by itself (#2837); literal: the
// placeholders the added text writes as text (#2361); send: where the held text goes (#2586).
type Hold = { file: string; added: string[]; removed: string[]; keys: string[]; literal?: string[]; send?: SlackAlertSend }
// Could not check: git or a read failed for the file itself, so the call is held and told to try again.
// late: it failed by running out of time, so it is told as a timeout, not a refusal (#2792).
type Unchecked = { unchecked: string; late?: true }
type Verdict = { pass: true } | { own: true } | Unchecked | { hold: Hold } | { merge: string }
const PASS: Verdict = { pass: true }

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

// start: where the string's text starts in its file, or -1 where it has no one place (a YAML value,
// a CI step's message).
type Lit = { text: string; literal: string[]; start: number }

/** Both sides of an edit read and traced for their sends. */
type Sides = { rBefore: Reading; rAfter: Reading; tBefore: Traced; tAfter: Traced }
/**
 * The wording a send carries once an edit is made (#2529), each once, split by whether a send could
 * carry it before: `fresh`, none could; `both`, one could, which a model's instructions can also be
 * where the trace follows a model's answer into the send, so that text is judged by what only a model
 * reads (postable) before it counts. A file whose sends cannot be found on either side gives none.
 */
const routedWording = ({ tBefore, tAfter }: Sides, before: Lit[], after: Lit[]): { fresh: string[]; both: string[] } => {
  if (!tBefore.sends.length && !tAfter.sends.length) return { fresh: [], both: [] }
  const sentIn = (t: Traced, lits: Lit[]) => new Set(lits.filter(l => l.start >= 0 && sentAt(t, l.start)).map(l => l.text))
  const was = sentIn(tBefore, before)
  const now = wordingOf([...sentIn(tAfter, after)])
  return { fresh: now.filter(s => !was.has(s)), both: now.filter(s => was.has(s)) }
}
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
/** A JavaScript, TypeScript or python file's text read for what only a model reads. */
const modelReadingOf = async ($: EngineInterface, text: string, python: boolean): Promise<ModelReading> => {
  let ranges = tokenRanges(text, false)
  if (python) {
    const spans = text ? await $.modkit.pythonText({ code: text }) : []
    ranges = { strings: spans.filter(x => x.kind !== 'comment'), comments: spans.filter(x => x.kind === 'comment') }
  }
  return modelReading(text, python, ranges)
}
const postable = async ($: EngineInterface, path: string, lang: ReturnType<typeof languageOf>, sides: Side[], deadline: number): Promise<Lit[][]> => {
  const python = lang === 'python'
  if (!python && !(lang === 'c' && isJs(path))) return sides.map(s => s.lits)
  const readings: ModelReading[] = []
  for (const s of sides) readings.push(await modelReadingOf($, s.text, python))
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
    // The repository, placed from the nearest folder that exists, by git's
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
// choice is never an approval, so awake it is held as before. Given the `file` the wording goes in, a
// choice letting it through there holds merges in that file's repository too (#2833).
const unapproved = async ($: EngineInterface, keys: string[], file?: string): Promise<string[]> => {
  const out: string[] = []
  for (const k of keys) if ((await $.store.get(k)) === undefined) out.push(k)
  const chosen: string[] = []
  for (const k of out) {
    const c = (await $.store.get(chosenKey(k))) as SlackAlertChoice | undefined
    if (c && c.expired === undefined) chosen.push(k)
  }
  if (!chosen.length || !(await isAsleep($))) return out
  if (file !== undefined) await placeChoices($, chosen, file)
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
 * The GitHub repository a file is in (#2833), as owner/name in lower case: the origin of the checkout
 * holding it, read from the nearest folder that exists, so a worktree removed since is read through
 * the checkout it was under, which has the same origin. null when git or the origin cannot say.
 */
const repoOf = async ($: EngineInterface, path: string): Promise<string | null> => {
  try {
    const where = await placed($, path, (await $.clock.now()) + SCAN_MS)
    if (!where) return null
    const r = await $.process.run(['git', '-C', where.top, 'remote', 'get-url', 'origin'], { timeoutMs: SCAN_MS })
    if (r.exitCode !== 0 || r.isStdoutTruncated) return null
    return (await $.modkit.repo({ root: where.top, remote: r.stdout.trim() })).github?.toLowerCase() ?? null
  } catch (err) {
    $.ui.log(`slack-alert-guard: the repository ${path} is in could not be read, so a choice made there holds merges in every repository: ${message(err)}`, { to: 'debug' })
    return null
  }
}

/**
 * The repositories a choice holds merges in (#2833), and the files whose repository could not be
 * read, read again here: a choice made before #2833 is read from its file.
 */
const choiceRepos = async ($: EngineInterface, c: SlackAlertChoice): Promise<{ repos: string[]; unread: string[] }> => {
  const repos: string[] = []
  const unread: string[] = []
  for (const p of c.places ?? [{ file: c.file, repo: null }]) {
    const r = p.repo ?? (await repoOf($, p.file))
    if (r) repos.push(r)
    else unread.push(p.file)
  }
  return { repos, unread }
}

/**
 * The choices this session may put to Dan (#2833): its own, and any other only where this session
 * works in a repository the choice was made in, so another project's wording is never asked about
 * beside work it has nothing to do with. A choice whose repository cannot be read is asked anywhere,
 * as before, so it is never left unasked; a session whose own repository cannot be read asks only
 * its own. The session's repository is read only when some choice is not its own.
 */
const askedHere = async ($: EngineInterface, all: readonly SlackAlertChoice[], self: string): Promise<SlackAlertChoice[]> => {
  const out: SlackAlertChoice[] = []
  let here: string | null | undefined
  for (const c of all) {
    if (c.session === self) {
      out.push(c)
      continue
    }
    const { repos, unread } = await choiceRepos($, c)
    if (unread.length) {
      out.push(c)
      continue
    }
    // A path inside the folder, since repoOf asks git from the folder holding the path it is given.
    if (here === undefined) here = await repoOf($, `${(await $.session.cwd()).replace(/\/+$/, '')}/.`)
    if (here !== null && repos.includes(here)) out.push(c)
  }
  return out
}

/**
 * Asleep, wording a choice lets through in a file is held against merges there too (#2833): the
 * file and its repository are added to each such choice's places, so a pull request in another
 * repository carrying it is still held.
 */
const placeChoices = async ($: EngineInterface, chosen: string[], file: string): Promise<void> => {
  const done = new Set<string>()
  for (const k of chosen) {
    const c = (await $.store.get(chosenKey(k))) as SlackAlertChoice | undefined
    if (!c || done.has(c.id)) continue
    done.add(c.id)
    const places = c.places ?? [{ file: c.file, repo: await repoOf($, c.file) }]
    if (places.some(p => p.file === file)) continue
    const next = [...places, { file, repo: await repoOf($, file) }]
    for (const key of await chosenKeysOf($, c.id)) await $.store.set(key, { ...((await $.store.get(key)) as SlackAlertChoice), places: next } satisfies SlackAlertChoice)
  }
}

/**
 * A merge carrying wording chosen overnight (#2628): while any choice waits on Dan, each pull request
 * a command merges is read with gh pr diff, and one whose added lines carry a choice is refused, so
 * nothing posts it before he approves it. Only in the repositories the choice holds (#2833): one
 * made in another repository lets the merge through, and one whose repository cannot be read holds
 * it wherever it is. A merge that cannot be read, a diff gh cannot give, or a pull request whose
 * repository gh cannot say, is held as could not check; a diff gh did not give within its time is
 * held as a timeout (#2792). With no choice waiting, no command is read.
 *
 * A diff gh cannot give (#2973) holds the merge only over the choices that hold its repository: none
 * there, and it passes. A diff gh cuts short is read again file by file, only the files that can carry
 * wording (diffInParts). One that cannot be read either way is held as could not check, naming each
 * choice it waits on, the session that made it and where it is approved.
 */
const judgeMerge = async ($: EngineInterface, command: string): Promise<Verdict> => {
  const waiting = await choices($)
  if (!waiting.length) return PASS
  const cwd = await $.session.cwd()
  const home = (await $.env.get('HOME')) ?? ''
  const self = await $.session.id()
  // The choices named, with who asks Dan about each, by askedHere as the merge refusal's are.
  const named = async (cs: SlackAlertChoice[], prRepo: string | null): Promise<string> => {
    const mine = new Set((await askedHere($, cs, self)).map(x => x.id))
    const away: Record<string, string> = {}
    for (const x of cs) if (!mine.has(x.id)) away[x.id] = (await choiceRepos($, x)).repos[0] ?? prRepo ?? ''
    return waitingNamed(cs, mine, away)
  }
  const waits = 'while Slack alert wording chosen overnight waits on Dan'
  const unreadable = async (): Promise<Verdict> => ({ unchecked: `a merge whose pull request cannot be read, ${waits}: ${await named(waiting, null)}` })
  for (const c of await $.modkit.pipeline({ command, cwd, home })) {
    const m = mergeOf(((await $.modkit.gh({ words: c.words })) ?? (await $.modkit.mergeHelper(c))) as Parameters<typeof mergeOf>[0])
    if (m === undefined) continue
    if ('unreadable' in m) return unreadable()
    const folder = c.folder ?? cwd
    const repoArgs = m.repo ? ['-R', m.repo] : []
    // The pull request's repository: the one the command names, else the one gh reads it in, asked
    // only when it is needed.
    let prRepo = typeof m.repo === 'string' ? m.repo.toLowerCase() : undefined
    const repoOfPr = async (): Promise<string | null> => {
      if (prRepo !== undefined) return prRepo
      const v = await $.process.run(['gh', 'pr', 'view', ...m.selector, '--json', 'url', '--jq', '.url'], { timeoutMs: SCAN_MS, cwd: folder })
      const link = v.exitCode === 0 && !v.isStdoutTruncated ? await $.modkit.linkRepo({ link: v.stdout.trim() }) : null
      if (!link) return null
      prRepo = link.toLowerCase()
      return prRepo
    }
    const argv = ['gh', 'pr', 'diff', ...m.selector, ...repoArgs]
    const asked = await $.clock.now()
    const r = await $.process.run(argv, { timeoutMs: SCAN_MS, cwd: folder })
    // A gh that failed once its whole time was spent was killed at its timeout (#2792).
    if (r.exitCode !== 0 && (await $.clock.now()) - asked >= SCAN_MS)
      return { unchecked: `gh did not give the pull request's diff within ${SCAN_MS / 1000} seconds, ${waits}`, late: true }
    let diff = r.stdout
    if (r.exitCode !== 0 || r.isStdoutTruncated) {
      const why = `gh could not give the pull request's diff (exit ${r.exitCode}: ${r.stderr.trim().split('\n')[0] || 'cut short'})`
      const repo = await repoOfPr()
      if (repo === null) return { unchecked: `${why}, nor say which repository it is in, ${waits}: ${await named(waiting, null)}` }
      // Only a choice holding this repository, or whose own repository cannot be read, holds it.
      const bearing: SlackAlertChoice[] = []
      for (const x of waiting) {
        const { repos, unread } = await choiceRepos($, x)
        if (unread.length || repos.includes(repo)) bearing.push(x)
      }
      if (!bearing.length) continue
      const parts = r.exitCode === 0 ? await diffInParts($, m.selector, repoArgs, folder) : { unread: 'it was not read again' }
      if ('unread' in parts) return { unchecked: `${why}, and ${parts.unread}, ${waits}: ${await named(bearing, repo)}`, ...('late' in parts && parts.late ? { late: true as const } : {}) }
      diff = parts.text
    }
    const carrying = carried(diff, waiting)
    if (!carrying.length) continue
    const held: SlackAlertChoice[] = []
    const unreadFiles: string[] = []
    for (const x of carrying) {
      const { repos, unread } = await choiceRepos($, x)
      if (unread.length) {
        held.push(x)
        unreadFiles.push(...unread)
        continue
      }
      const repo = await repoOfPr()
      if (repo === null) return unreadable()
      if (repos.includes(repo)) held.push(x)
    }
    if (!held.length) continue
    // A choice this session may not ask about (askedHere, #2833) is said to be asked in its own
    // repository, never put to Dan from here.
    const mine = new Set((await askedHere($, held, self)).map(x => x.id))
    const away: Record<string, string> = {}
    for (const x of held) if (!mine.has(x.id)) away[x.id] = prRepo ?? (await choiceRepos($, x)).repos[0] ?? ''
    return { merge: mergeRefusal(held, unreadFiles, away) }
  }
  return PASS
}

/**
 * A pull request's diff read file by file (#2973), for one whose whole diff gh cut short (a work
 * repository's, 7.6 MB of pictures embedded in settled design files): GitHub's list of its files, the
 * patch given only for a file that can carry wording (WORDING_PATH, picked out by gh's own jq, so the
 * pictures are never sent), joined for carried(). Unread, with why, when the list is cut short too,
 * holds fewer files than the pull request changes (GitHub lists at most 3,000), or gives no patch for
 * a file that could carry wording (GitHub leaves one out past its own size limit); late when gh was
 * killed at its timeout (#2792).
 */
const diffInParts = async ($: EngineInterface, selector: string[], repoArgs: string[], folder: string): Promise<{ text: string } | { unread: string; late?: true }> => {
  const ran = async (argv: string[]) => {
    const asked = await $.clock.now()
    const r = await $.process.run(argv, { timeoutMs: SCAN_MS, cwd: folder })
    return { r, late: r.exitCode !== 0 && (await $.clock.now()) - asked >= SCAN_MS }
  }
  const firstLine = (r: { exitCode: number; stderr: string }, short: string) => `exit ${r.exitCode}: ${r.stderr.trim().split('\n')[0] || short}`
  const v = await ran(['gh', 'pr', 'view', ...selector, ...repoArgs, '--json', 'url,changedFiles', '--jq', '"\\(.changedFiles) \\(.url)"'])
  if (v.late) return { unread: `gh did not say which files it changes within ${SCAN_MS / 1000} seconds`, late: true }
  const said = v.r.exitCode === 0 && !v.r.isStdoutTruncated ? /^(\d+) (\S+)$/.exec(v.r.stdout.trim()) : null
  const link = said?.[2] ?? ''
  const repo = said ? await $.modkit.linkRepo({ link }) : null
  const number = /\/pull\/(\d+)/.exec(link)?.[1]
  if (!said || !repo || !number) return { unread: `gh could not say which files it changes (${firstLine(v.r, v.r.stdout.trim().slice(0, 80) || 'nothing said')})` }
  const f = await ran(['gh', 'api', `repos/${repo}/pulls/${number}/files?per_page=100`, '--paginate', '--jq', FILES_JQ])
  if (f.late) return { unread: `GitHub did not list its files within ${SCAN_MS / 1000} seconds`, late: true }
  if (f.r.exitCode !== 0 || f.r.isStdoutTruncated) return { unread: `GitHub's list of its files could not be read either (${firstLine(f.r, 'cut short')})` }
  const files: [string, string | null | false][] = []
  for (const line of f.r.stdout.split('\n')) {
    if (!line.trim()) continue
    let row: unknown
    try {
      row = JSON.parse(line)
    } catch {
      row = undefined
    }
    if (!Array.isArray(row) || typeof row[0] !== 'string' || !(typeof row[1] === 'string' || row[1] === null || row[1] === false)) return { unread: `GitHub's list of its files could not be read (${line.slice(0, 80)})` }
    files.push([row[0], row[1]])
  }
  if (files.length !== Number(said[1])) return { unread: `GitHub listed ${files.length} of the ${said[1]} files it changes` }
  const blind = files.filter(([, p]) => p === null).map(([n]) => n)
  if (blind.length) return { unread: `GitHub gives no diff for ${blind.join(', ')}, which could carry wording` }
  return { text: files.flatMap(([, p]) => (typeof p === 'string' ? [p] : [])).join('\n') }
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

/** A file read for its sends (sends.ts), python through mod-kit's reader. */
const readFor = async ($: EngineInterface, t: string, py: boolean): Promise<Reading> => readingOf(t, py, py ? pySpans(t ? await $.modkit.pythonText({ code: t }) : []) : jsSpans(t))

/**
 * Where a file stands in git: its repository's top as git spells it, symlinks resolved, and its path
 * below that; none when it is in no repository; or why git could not say. Read from the nearest
 * folder that exists, since a Write can create a file in a folder not yet made.
 */
type Where = { top: string; rel: string } | { none: true } | Unchecked
const whereIs = async ($: EngineInterface, path: string, deadline: number): Promise<Where> => {
  let dir = path.slice(0, path.lastIndexOf('/')) || '/'
  while (dir !== '/' && !(await $.fs.exists(dir))) dir = dir.slice(0, dir.lastIndexOf('/')) || '/'
  const ms = Math.floor(deadline - (await $.clock.now()))
  if (ms <= 0) return { unchecked: `git was not asked which repository ${path} is in within ${SCAN_MS / 1000} seconds`, late: true }
  const where = await $.process.run(['git', '-C', dir, 'rev-parse', '--show-toplevel', '--show-prefix'], { timeoutMs: ms })
  if (where.exitCode === 128 && /not a git repository/.test(where.stderr)) return { none: true }
  // A git that failed once its whole time was spent was killed at its timeout (#2792).
  if (where.exitCode !== 0 && (await $.clock.now()) >= deadline)
    return { unchecked: `git did not name the repository ${path} is in within ${SCAN_MS / 1000} seconds`, late: true }
  if (where.exitCode !== 0 || where.isStdoutTruncated)
    return { unchecked: `git could not name the repository ${path} is in (exit ${where.exitCode}: ${where.stderr.trim().split('\n')[0] || 'no message'})` }
  // git prints the top, then the folder asked from below it, ending in a slash, or an empty line at the top.
  const [top = '', prefix = ''] = where.stdout.split('\n')
  if (!top) return { unchecked: `git named no repository for ${path}` }
  return { top, rel: `${prefix}${path.slice(dir === '/' ? 1 : dir.length + 1)}` }
}

/** The repository a path is in, as git spells its top, and the path below it; undefined when git names none in time. */
const placed = async ($: EngineInterface, path: string, deadline: number): Promise<{ top: string; rel: string } | undefined> => {
  const w = await whereIs($, path, deadline)
  return 'top' in w ? w : undefined
}

/**
 * Whether a file carrying a Slack marker of its own posts (#2837): it does when it is in a git
 * repository and is no test. A file in no repository, as a scratchpad script is, has nothing that
 * runs it as an alert (#2287), and a test sends nothing (#2290). git failing to say is could not
 * check, never a pass.
 */
const postsItself = async ($: EngineInterface, path: string): Promise<{ posts: true } | { none: true } | Unchecked> => {
  const w = await whereIs($, path, (await $.clock.now()) + SCAN_MS)
  if (!('top' in w)) return w
  return testFile(w.rel) ? { none: true } : { posts: true }
}

/**
 * The guard holds only a file that posts to Slack by itself (#2837; Dan, 2026-11-12: "I'd much
 * rather an alert get posted to slack that I didn't approve than deal with stopping every 2 seconds
 * to approve wording that nobody will ever see"): one whose own code carries a Slack marker
 * (rules.ts isSender), before or after the edit. What other files import, read, name or send of a
 * file is never a reason to stop, so nothing else in the repository is searched.
 */
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
  if (!inScope(path, current || after)) return PASS
  if (!isSender(path, current, true) && !isSender(path, after, true)) return PASS
  return ownWording($, { path, current, edited, before, after })
}

/** The verdict on the wording an edit changes in a file that posts to Slack by itself. */
type EditOf = { path: string; current: string; edited: string | undefined; before: string; after: string }
const ownWording = async ($: EngineInterface, { path, current, edited, before, after }: EditOf): Promise<Verdict> => {
  try {
    const lang = languageOf(path, current || after)
    const afterLits = await literals($, path, lang, after)
    const beforeLits = await literals($, path, lang, before)
    const wording = (lits: Lit[]) => wordingOf(lits.map(l => l.text))
    // The hold for a change, or none when it changes no wording Dan has not approved.
    const holdOf = async ({ added, removed }: { added: string[]; removed: string[] }): Promise<Hold | undefined> => {
      if (added.length) {
        const fresh = [...new Set(added)]
        const open = await unapproved($, fresh.map(wordingKey), path)
        if (!open.length) return undefined
        const shown = fresh.filter(s => open.includes(wordingKey(s)))
        // The placeholders the code writes as text, which the message shown to Dan may carry (#2361).
        const literal = [...new Set(afterLits.filter(l => shown.includes(l.text)).flatMap(l => l.literal))]
        return { file: path, added: shown, removed, keys: open, ...(literal.length ? { literal } : {}) }
      }
      if (!removed.length) return undefined
      // No file given (#2833): a removal's key names its file, so a chosen removal only ever lets
      // through an edit to that same file, never one in another repository.
      const keys = await unapproved($, [removalKey(path, removed)])
      if (!keys.length) return undefined
      // Text origin does not hold was never live, so taking it away takes nothing Dan approved (#2628).
      origin ??= await onOrigin($, path, t => literals($, path, lang, t))
      if (origin && removed.every(s => !origin?.has(s))) return undefined
      return { file: path, added: [], removed, keys }
    }
    let origin: Set<string> | undefined
    const change = wordingChange(wording(beforeLits), wording(afterLits))
    const python = lang === 'python'
    const traceSides = async (): Promise<Sides> => {
      const [rBefore, rAfter] = [await readFor($, before, python), await readFor($, after, python)]
      const was = scanWork()
      const [tBefore, tAfter] = [trace(rBefore), trace(rAfter)]
      // The searching tracing did (#2719), where a test reads it: its cost on any machine, however loaded.
      $.ui.log(`slack-alert-guard: traced ${path}: searched ${scanWork() - was}`, { to: 'debug' })
      return { rBefore, rAfter, tBefore, tAfter }
    }
    // A file whose sends are followed (an edit that applies, in JavaScript, TypeScript or python) is
    // traced on both sides before anything else, for the text an edit newly hands a send (#2529).
    const traced = edited !== undefined && requestLanguage(path, current || after) !== 'shell' && (python || (lang === 'c' && isJs(path))) ? await traceSides() : undefined
    // Text the file already held that the edit newly hands one of its sends, changing no words
    // (#2529): a model's instructions, or a line only a log printed, now posted. Counted as wording
    // the edit adds, so Slack never posts text Dan never saw as a message. Text another file holds,
    // brought in by a new import, is not read: a file whose own code sends nothing is never a reason
    // to stop (#2837).
    const routedTo = async ({ fresh, both }: { fresh: string[]; both: string[] }): Promise<string[]> => {
      if (!both.length) return fresh
      // Text a send could carry before only through a model's answer, the model's own instructions
      // among it, is routed when only a model read it before and more than a model reads it now.
      const fedModel = await modelReadingOf($, before, python)
      const fed = both.filter(s => beforeLits.some(l => l.text === s && l.start >= 0 && modelFed(fedModel, l.start)))
      if (!fed.length) return fresh
      const [keptBefore, keptAfter] = await postable($, path, lang, [{ text: before, lits: beforeLits, changed: fed }, { text: after, lits: afterLits, changed: fed }], (await $.clock.now()) + SCAN_MS)
      const [wasSent, isSent] = [new Set((keptBefore as Lit[]).map(l => l.text)), new Set((keptAfter as Lit[]).map(l => l.text))]
      return [...fresh, ...fed.filter(s => !wasSent.has(s) && isSent.has(s))]
    }
    const routed = traced ? (await routedTo(routedWording(traced, beforeLits, afterLits))).filter(s => !change.added.includes(s)) : []
    if (!(await holdOf(change)) && !(routed.length && (await holdOf({ added: routed, removed: [] })))) return PASS
    // In a repository and no test, as a file posting by itself must be.
    const place = await postsItself($, path)
    if (!('posts' in place)) return 'unchecked' in place ? place : PASS
    const deadline = (await $.clock.now()) + SCAN_MS
    // The hold for `part` of the change, of it only what Slack can be sent: text only a model reads
    // is left out (#2475), so a model's instructions beside an alert are never held, nor shown to Dan
    // as one. Routed text is in the file on both sides, so it is no change of words; it is kept where
    // the edit leaves it sendable by more than a model.
    type Part = { added: string[]; removed: string[] }
    // `sendOf` says where the held text goes, from the hold itself (#2586).
    const holdFor = async (part: Part, sendOf: (hold: Hold) => SlackAlertSend): Promise<Verdict> => {
      const [beforeKept, afterKept] = await postable($, path, lang, [{ text: before, lits: beforeLits, changed: part.removed }, { text: after, lits: afterLits, changed: part.added }], deadline)
      const kept = wordingChange(wording(beforeKept as Lit[]), wording(afterKept as Lit[]))
      const sendable = new Set((afterKept as Lit[]).map(l => l.text))
      const moved = routed.filter(s => part.added.includes(s) && !kept.added.includes(s) && sendable.has(s))
      const hold = await holdOf({ added: [...kept.added.filter(s => part.added.includes(s)), ...moved], removed: kept.removed.filter(s => part.removed.includes(s)) })
      return hold ? { hold: { ...hold, send: sendOf(hold) } } : PASS
    }
    const untraced = (why: string) => (): SlackAlertSend => ({ untraced: why })
    // A file whose sends cannot be traced (a workflow, a shell script, any language but JavaScript,
    // TypeScript and python, an edit that does not apply) is held for all the wording it changes,
    // except, in a shell script, wording only a log line prints (below).
    if (edited === undefined) return holdFor(change, untraced(UNTRACED_EDIT))
    // In a shell script, wording that only a log reads is left out (#2792): a string every place of
    // which is an argument of an echo or printf sent to the error stream and nowhere else. The script
    // is read as its commands by mod-kit's reader, the one reader of shell there is (#712), and
    // rules.ts shellLogWording judges those.
    if (requestLanguage(path, current || after) === 'shell') {
      const logOnly = async (text: string, lits: Lit[]) => shellLogWording(await $.modkit.pipeline({ command: text }), lits.map(l => l.text))
      const [logBefore, logAfter] = [await logOnly(before, beforeLits), await logOnly(after, afterLits)]
      const sent: Part = { added: change.added.filter(s => !logAfter.has(s)), removed: change.removed.filter(s => !logBefore.has(s)) }
      return sent.added.length || sent.removed.length ? holdFor(sent, untraced(UNTRACED_LANGUAGE)) : PASS
    }
    if (!traced) return holdFor(change, untraced(UNTRACED_LANGUAGE))
    const { rBefore, rAfter, tBefore, tAfter } = traced
    // Wording only a console call logs is left out (#2907), wherever the call stands: a string every
    // place of which is a whole argument of console.log, info, warn, error or debug. Routed text
    // reaches a send, so it is never only logged.
    const consoleOnly = (r: Reading, lits: Lit[]): Set<string> => {
      const at = consoleArgs(r, jsSpans(r.text).strings)
      const out = new Set(lits.filter(l => at.has(l.start)).map(l => l.text))
      for (const l of lits) if (!at.has(l.start)) out.delete(l.text)
      return out
    }
    const [logBefore, logAfter] = [consoleOnly(rBefore, beforeLits), consoleOnly(rAfter, afterLits)]
    const sent: Part = { added: [...change.added.filter(s => !logAfter.has(s)), ...routed], removed: change.removed.filter(s => !logBefore.has(s)) }
    if (!sent.added.length && !sent.removed.length) return PASS
    // A file that posts to Slack by a send the guard cannot find is held for all of it but the
    // console log lines above.
    if (!tBefore.sends.length && !tAfter.sends.length) return holdFor(sent, untraced(UNTRACED_NONE))
    // Only wording one of its own sends carries is held (#2570): a log line, an error or a route's
    // answer beside the alert passes.
    const here: Part = {
      added: sent.added.filter(s => afterLits.some(l => l.text === s && l.start >= 0 && sentAt(tAfter, l.start))),
      removed: sent.removed.filter(s => beforeLits.some(l => l.text === s && l.start >= 0 && sentAt(tBefore, l.start))),
    }
    // The sends the held text reaches, each once: added text in the file as the edit leaves it, text
    // taken away in the file as it was.
    const reached = (hold: Hold): SlackAlertSend => {
      const [texts, lits, t] = hold.added.length ? [hold.added, afterLits, tAfter] : [hold.removed, beforeLits, tBefore]
      const sends = new Map<string, { callee: string; line: number }>()
      for (const l of lits) {
        const s = texts.includes(l.text) && l.start >= 0 ? sentAt(t, l.start) : undefined
        if (s) sends.set(`${s.line}:${s.callee}`, { callee: s.callee, line: s.line })
      }
      return { sends: [...sends.values()].sort((a, b) => a.line - b.line) }
    }
    return here.added.length || here.removed.length ? holdFor(here, reached) : PASS
  } catch (err) {
    return { unchecked: message(err) }
  }
}

/**
 * What a shell write puts in a file, as near as can be told before it runs (#2773): a copy of one file
 * puts that file's text there, read only when the guard reads that file as code (a code file, or a
 * script with no extension), so a copy of a video or a key is never read (#2830); anything else is
 * guessed from the command's lines after its first, where a heredoc's body is, which is empty for a
 * one line command.
 */
const writtenBy = async ($: EngineInterface, f: { sources?: string[] }, command: string): Promise<string> => {
  const [source] = f.sources ?? []
  if (f.sources?.length === 1 && source !== undefined && inScope(source, '#!')) {
    if ((await $.fs.exists(source)) && (await $.fs.stat(source)).kind === 'file') return String(await $.fs.read(source))
    return ''
  }
  const cut = command.indexOf('\n')
  return cut < 0 ? '' : command.slice(cut + 1)
}

/** Whether a shell write lands in a folder (#2773): a copy of a folder's contents, a folder already there, or a copy of a folder to a new name. */
const isFolder = async ($: EngineInterface, f: { path?: string; sources?: string[]; tree?: true }, exists: boolean): Promise<boolean> => {
  if (f.tree) return true
  if (exists) return (await $.fs.stat(f.path as string)).kind === 'dir'
  for (const s of f.sources ?? []) if ((await $.fs.exists(s)) && (await $.fs.stat(s)).kind === 'dir') return true
  return false
}

type ShellCommand = Awaited<ReturnType<EngineInterface['modkit']['pipeline']>>[number]
type Unnamed = Awaited<ReturnType<EngineInterface['modkit']['writes']>>['unnamed'][number]

/**
 * The text of each patch a patch command applies (#2971): the files it names, read by mod-kit's one
 * input reader, which never opens a device or a fifo; else what its standard input is, a heredoc's
 * body or the files a cat pipes in. Could not check for a patch the guard cannot read before it runs:
 * a named one that is not a file, a heredoc whose $ or backticks the shell fills in, or anything else
 * on standard input.
 */
const patchTexts = async ($: EngineInterface, u: Unnamed, cmd: ShellCommand, folder: string): Promise<{ texts: string[] } | Unchecked> => {
  const fs: InputFs = { exists: p => $.fs.exists(p), stat: (p, o) => $.fs.stat(p, o), read: async p => String(await $.fs.read(p)) }
  const readAll = async (paths: string[]): Promise<{ texts: string[] } | Unchecked> => {
    const texts: string[] = []
    for (const p of paths) {
      const [t] = await inputTexts(fs, [p])
      if (t === undefined) return { unchecked: `the patch ${p} is not a file the guard can read before it runs` }
      texts.push(t)
    }
    return { texts }
  }
  if (u.inputs.length) return readAll(u.inputs)
  const doc = cmd.heredocs?.find(h => h.fd === undefined && !h.replaced)
  if (doc) {
    if (!doc.quoted && /[$`]/.test(doc.body)) return { unchecked: 'the patch is a heredoc whose $ and backticks the shell fills in, so what it applies cannot be read before it runs' }
    return { texts: [doc.body] }
  }
  const from = cmd.pipedFrom ?? []
  if (from[0] === 'cat' && from.length > 1 && from.slice(1).every(a => !a.startsWith('-'))) return readAll(from.slice(1).map(a => (a.startsWith('/') ? a : `${folder}/${a}`)))
  return { unchecked: 'what the patch is given on standard input cannot be read before it runs' }
}

/**
 * A patch a shell command applies with git apply, git am or patch (#2971), judged file by file as an
 * Edit to that file is (judgeEdit): each hunk replaces its lines before with its lines after, and a
 * file the patch makes is a Write of its lines. So rewording an alert in a file that posts to Slack is
 * held as the same Edit would be, and a patch to a file that sends nothing passes. A file the patch
 * removes is a removal, as rm is, and passes. Names are placed as the command places them: git from
 * the top of its checkout, patch from where it runs, each with its -p and directory; patch with no -p
 * strips git's a/ and b/ when both sides carry them. Could not check for a patch that cannot be read
 * as a diff, and for a file it changes that is not there to read, since the names may be placed wrong.
 */
const judgePatch = async ($: EngineInterface, u: Unnamed, commands: ShellCommand[], cwd: string): Promise<Verdict> => {
  const cmd = commands.find(c => JSON.stringify(c.words) === JSON.stringify(u.words))
  if (!cmd) return { unchecked: `the patch command ${u.words.join(' ')} could not be found among the commands it runs` }
  if (cmd.folder === null) return { unchecked: `the folder ${u.words.join(' ')} runs in cannot be followed` }
  const folder = cmd.folder ?? cwd
  const g = await $.modkit.git({ words: cmd.words })
  const isGit = !!g && (g.sub === 'apply' || g.sub === 'am')
  const placing = patchPlacing(isGit ? g.args : cmd.words.slice(1), isGit)
  const got = await patchTexts($, u, cmd, folder)
  if ('unchecked' in got) return got
  let base = folder
  if (isGit) {
    const dir = g.dir === undefined ? folder : g.dir.startsWith('/') ? g.dir : `${folder}/${g.dir}`
    const w = await whereIs($, `${dir}/.`, (await $.clock.now()) + SCAN_MS)
    if ('unchecked' in w) return w
    base = 'top' in w ? w.top : dir
  }
  if (placing.into) base = placing.into.startsWith('/') ? placing.into : `${base}/${placing.into}`
  for (const text of got.texts) {
    const files = patchFiles(text)
    if (!files) return { unchecked: `a patch ${u.words.join(' ')} applies could not be read as a diff` }
    for (const f of files) {
      if (f.to === null) continue
      const gitNamed = f.to.startsWith('b/') && (f.from === null || f.from.startsWith('a/'))
      const strip = placing.strip ?? (isGit || gitNamed ? 1 : 0)
      const rel = placing.target ?? f.to.split('/').slice(strip).join('/')
      const path = rel.startsWith('/') ? rel : `${placing.target ? folder : base}/${rel}`
      if (!rel || !inScope(path, '#!')) continue
      let v: Verdict
      if (f.from === null && !placing.target) v = await judgeEdit($, 'Write', { file_path: path, content: `${f.hunks.map(h => h.after).join('\n')}\n` })
      else {
        if (!(await $.fs.exists(path))) return { unchecked: `${path}, a file the patch changes, is not there to read` }
        v = await judgeEdit($, 'MultiEdit', { file_path: path, edits: f.hunks.map(h => ({ old_string: h.before, new_string: h.after })) })
      }
      if (!('pass' in v)) return v
    }
  }
  return PASS
}

/**
 * A shell write is held only when a file it writes posts to Slack by itself (#2837): its own code
 * carries a Slack marker, as it is or with what the command puts there. A copy into a folder, and a
 * write into a file another file imports, reads or sends, passes.
 */
const judgeShell = async ($: EngineInterface, input: Record<string, unknown>): Promise<Verdict> => {
  const command = typeof input.command === 'string' ? input.command : ''
  if (!command) return PASS
  try {
    const cwd = await $.session.cwd()
    const home = (await $.env.get('HOME')) ?? ''
    const w = await $.modkit.writes({ command, cwd, home })
    // Only a command that can write the guard's own record is refused (#2904), never one that
    // only lists, searches or reads the store.
    if (writesOwnRecord(w, home, mentionsStore(command))) return { own: true }
    const merging = await judgeMerge($, command)
    if (!('pass' in merging)) return merging
    // A patch writes files its words do not name, so it is read for what it changes (#2971).
    const patches = w.unnamed.filter(u => u.what === 'a patch')
    const commands = patches.length ? await $.modkit.pipeline({ command, cwd, home }) : []
    for (const u of patches) {
      const v = await judgePatch($, u, commands, cwd)
      if (!('pass' in v)) return v
    }
    const key = shellKey(command, w.files.flatMap(f => (f.path === undefined ? [] : [f.path])))
    for (const f of w.files) {
      if (f.path === undefined) continue
      const exists = await $.fs.exists(f.path)
      if (await isFolder($, f, exists)) continue
      // Only a file the guard reads as code: a code file, or a script with no extension.
      if (!inScope(f.path, '#!')) continue
      const written = await writtenBy($, f, command)
      const text = exists ? String(await $.fs.read(f.path)) : written
      if (!inScope(f.path, text || written)) continue
      if (!isSender(f.path, text, true) && !isSender(f.path, written, true)) continue
      const place = await postsItself($, f.path)
      if ('unchecked' in place) return place
      if ('none' in place) continue
      const keys = await unapproved($, [key])
      if (!keys.length) return PASS
      return { hold: { file: f.path, added: [], removed: [], keys } }
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
  if ('unchecked' in v && v.late) {
    await drawCard($, id, 'The Slack alert guard ran out of time checking this call, so it did not run.', `${v.unchecked}. Claude sends it again in about a minute.`)
    return outOfTime(v.unchecked)
  }
  if ('unchecked' in v) {
    await drawCard($, id, 'The Slack alert guard could not check this call, so it is held.', v.unchecked)
    return cannotCheck(v.unchecked)
  }
  if ('merge' in v) {
    await drawCard($, id, 'This pull request carries Slack alert wording chosen overnight that you have not approved.', 'It merges once you approve the wording.')
    return v.merge
  }
  const { file, added, removed, keys, literal, send } = v.hold
  // Asleep, wording an edit changes is chosen by the session itself and kept for Dan's morning
  // (#2628); a shell command's wording cannot be read before it runs, so it is held as before.
  const choosing = id !== '' && (added.length > 0 || removed.length > 0) && (await isAsleep($))
  if (id) {
    const waiting: SlackAlertPending = { id, tool, file, added, removed, keys, ...(literal ? { literal } : {}), ...(agent ? { agent: true as const } : {}), ...(send ? { send } : {}) }
    await update($, pendingRef, p => [...(p ?? []).filter(x => x.id !== id), waiting])
    const safeWay = choosing ? 'You are asleep: Claude chooses the wording and asks you in the morning.' : agent ? 'The main session asks you about it.' : 'Claude shows you the message as Slack will post it and asks you to approve the wording.'
    await drawCard($, id, `${heldText(file, added, removed, send)}.`, safeWay)
  }
  if (choosing) return asleepRefusal(blocked(file, added, removed, send), id)
  return agent ? agentRefusal(id, file, added, removed, send) : refusal(id, file, added, removed, send)
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
    // Once next was called the guard had judged the call and passed it on (#2948): a failure after
    // that is a hook's beneath it, a hooks worker another hook wedged included, so what the call
    // settled to is replayed and the failure is said by the hook that failed, never as this guard
    // having been unable to check it (#2039, as the secret guard and ask before saving do).
  }).catch(($, e, next) => next.called ? next(e) : neverThrows(() => ({ deny: hookFailed(next.error, message(next.error)) }), () => ({ deny: HELD }), { deny: HELD }))

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
    // No replay here, unlike the tool.call hook above (#2948): a call this hook holds is first asked of
    // the checks beneath, so it has called next too, and replaying what they settled to could let a
    // held call through. So any failure beneath it, a call it passed included, is said as this
    // guard's and the call is held, as the design round guard's tool.check does. Telling the two
    // apart needs a catch form tools/check-mod-shared-parts.sh does not yet accept.
  }).catch(($, e, next) => neverThrows(() => ({ decision: 'deny' as const, reason: hookFailed(next.error, message(next.error)) }), () => ({ decision: 'deny' as const, reason: HELD }), { decision: 'deny' as const, reason: HELD }))

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
  // Wording this session chose overnight is handed to whichever session Dan writes in next in the
  // repository it was made in (#2628, #2833), so a choice never goes unasked because the session that
  // made it ended.
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
        deny: `Dan is awake, so he approves this wording himself rather than a choice being made for him: ${waiting.agent ? agentRefusal(call, waiting.file, waiting.added, waiting.removed, waiting.send) : refusal(call, waiting.file, waiting.added, waiting.removed, waiting.send)}`,
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
      places: [{ file: waiting.file, repo: await repoOf($, waiting.file) }],
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
  // once that one ended, by a session working in the repository it was made in (#2833); one past its
  // time is marked expired, said once in each such session, and stays held.
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
      const self = await $.session.id()
      const mine = await askedHere($, all, self)
      const lines = morningLines(mine, self, told)
      const fresh = mine.filter(c => c.expired !== undefined && !told.includes(c.id)).map(c => c.id)
      if (fresh.length) await $.state.set(toldRef, [...told, ...fresh])
      return lines.length ? { ...r, context: [...(r.context ?? []), ...lines] } : r
    } catch (err) {
      // Never read as nothing waiting: Claude is told, so Dan hears that a choice may be unasked.
      const line = `The Slack alert guard could not read the wording chosen overnight (${message(err)}), so any choice waiting on Dan is not listed here: tell him in one line. Pull requests carrying it still cannot merge.`
      return { ...r, context: [...(r.context ?? []), line] }
    }
  })
}
