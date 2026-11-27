// A PR Dan himself chose to close unmerged (#3779). At about 1:38 PM ET on 2026-11-26 he picked
// "3.79.1 Close it unmerged (Recommended)" in a session's picker about claude-config's pull request
// 3749. An hour later winding down sent it back to be reopened and finished, leave_pr_open found "no
// recorded reason it will never merge" in his exact answer, and he was asked a second time.
//
// What counts as his own decision is only what a session cannot write for itself: the answer the
// dialog hands back to this mod's hook on AskUserQuestion, as sleep mode already reads his morning
// answers (settled.ts, #3018) and the lesson picker his approval (ask before saving, #867). A
// closing comment, words passed as dan_said and a call carrying its own answers are a session's to
// write, and never count.
//
// #917 kept a session's own picker from being read as his choice, "since which PR it was about and
// what the answer meant would be inferred". So nothing here is inferred. One decision is read, and
// only in these words:
// - the answer is one the picker offered and he picked, alone, in a picker that is no subagent's
//   (never typed, never a picker that closed by itself; a mod's own dialog reaches this hook the
//   same way and is read as the session's is), in words he could read whole (mod-kit's askFault,
//   as #3321 holds every recorded picker to);
// - its whole wording closes the pull request and says it is not merged ("Close it unmerged",
//   "Close PR 31 without merging"), so an answer that closes something else, or closes it later or
//   on a condition, is no decision, and "Leave it closed" and "Leave it open" stay the tool's own
//   answers and are never read from a session's picker (#917, #1033);
// - the words he read name exactly one pull request as a pull request ("pull request 3749",
//   "PR #31", "PR 31 in owner/name", its link): the answer when it names one, else the question;
// - any other number the question names with a # may be a pull request too (his question named
//   an issue that way, #3692), so his answer counts only once GitHub has said each is none. Until
//   then the PR is neither settled nor sent back to be reopened, and where one is a pull request,
//   which he meant is not on record and nothing is kept.
//
// What is recorded is the one record winding down already reads a closed PR against (LeftClosed,
// #1033), so one rule decides whether a PR is left as it is (leftByChoice) and a later answer of his
// to leave_pr_open replaces it. Pure, but for the caller's own state, repository and GitHub reads,
// handed in as closures the engine has spelled in place.
//
// A record nobody is told of can be wrong for hours before it settles anything, so it is said (the
// independent read of #3779): to the session and to Dan the moment it is made, withdrawn or cannot
// be made (notedSaid), and at every turn end while it stands (picksSaid). A later answer of his in a
// picker naming that pull request while it is still open, other than to close it unmerged,
// withdraws it, and one whose picker named a second pull request stays on the record marked not
// kept, with why, so the turn end that sends its pull request back says so every time.
import type { ScopeModesLeftAsIs, ScopeModesLeftClosed } from '../types/index.d.ts'
import { askFault } from './mod-kit/shown.ts'
import { pickerAnswered } from './morning.ts'
import { isLeftClosed, prLinks, prRefs, quoteOf, refSaid, type PrRef } from './winddown.ts'

// A picker's own numbering before an answer ("3.79.1 ", "2. "), and the mark of the recommended one.
const NUMBERED = /^\s*\d+(?:\.\d+)*[.)]?\s+/
const RECOMMENDED = /\s*\(recommended\)\s*$/i
// The whole of an answer that closes the pull request unmerged, and nothing else: "Close", then
// nothing, or the pull request itself (it, this one, the pull request, PR 31), then that it is not
// merged. Begins "Close" and says unmerged were two separate tests before the independent read of
// #3779, so "Close the issue and leave the PR unmerged for now" and "Close #3692 as not planned, do
// not merge PR 3749 yet", which both leave the pull request open, were read as closing it. An answer
// with any other word in it (another thing closed, "later", "for now", "once", "by mistake") could
// be read either way, so it is no decision: the pull request stays outstanding and he is asked.
const OWNER_NAME = String.raw`[\w.-]+\/[\w-]+(?:\.[\w-]+)*`
const THE_PR = String.raw`(?:it|this(?: one)?|(?:the|this|that) (?:pull request|PR)|(?:the )?(?:pull request|PR) ?(?:(?:${OWNER_NAME})?#)?\d+(?: in ${OWNER_NAME})?)`
const UNMERGED = String.raw`(?: unmerged| without merging(?: it)?|(?:,| and|, and) (?:do not|don.t|never) merge(?: it)?)`
const CLOSES_IT_UNMERGED = new RegExp(String.raw`^closed?(?: ${THE_PR})?${UNMERGED}[.!]?$`, 'i')

/** Whether an answer is a decision to close a PR unmerged: its whole wording closes the pull request and says it is not merged. */
export const closesUnmerged = (label: string): boolean => CLOSES_IT_UNMERGED.test(label.replace(NUMBERED, '').replace(RECOMMENDED, '').replace(/\s+/g, ' ').trim())

// A number said to be a pull request: "pull request 3749", "PR 31", "PR #31", "PR o/r#31", and, in
// plain words, "PR 31 in o/r" (the independent read of #3779: without it a pull request in another
// repository was recorded as this one's). A bare #N is an issue as often as a PR and names none
// here, and neither does a number that goes on past a point (a picker's own "3.79").
const NAMED_AS_PR = new RegExp(String.raw`\b(?:pull request|PR)(?:\s+(?:([\w.-]+\/[\w.-]+)#|#)?|#)(\d+)\b(?!\.\d)(?:\s+in\s+(${OWNER_NAME}))?`, 'gi')

/**
 * The pull requests a text names as pull requests, in order, each once. A link names its own once
 * `linked` holds mod-kit's answer for it, the repository it is in (#1777).
 */
export const namedAsPr = (text: string, linked: ReadonlyMap<string, string | null> = new Map()): PrRef[] => {
  const found: { at: number; repo?: string; number: number }[] = []
  for (const m of text.matchAll(NAMED_AS_PR)) {
    const repo = m[1] ?? m[3]
    found.push({ at: m.index ?? 0, ...(repo ? { repo } : {}), number: Number(m[2]) })
  }
  let from = 0
  for (const { link, number } of prLinks(text)) {
    const at = text.indexOf(link, from)
    from = at + link.length
    const repo = linked.get(link)
    if (repo) found.push({ at, repo, number })
  }
  const out: PrRef[] = []
  for (const { repo, number } of found.sort((a, b) => a.at - b.at)) {
    if (out.some(r => r.number === number && (r.repo ?? '').toLowerCase() === (repo ?? '').toLowerCase())) continue
    out.push(repo ? { repo, number } : { number })
  }
  return out
}

/**
 * One decision of his to close a PR unmerged: the PR his words named, the answer he picked, and
 * the other numbers the question named with a #, which GitHub must say are no pull requests.
 */
export type CloseDecision = { pr: PrRef; answer: string; unless: PrRef[] }

type Result = { deny?: unknown; isError?: unknown; result?: unknown }
type Asked = { question: string; multiSelect?: unknown; options?: unknown }

/**
 * His own answers in one picker, each with its question. None for a subagent's picker, for one that
 * was refused, failed, closed by itself or came back unanswered, and for a call carrying its own
 * answers: only his choice in the dialog is his (as the lesson picker holds, #867).
 */
const hisAnswers = (input: Record<string, unknown>, r: Result): { q: Asked; given: unknown }[] => {
  if (input.agentId !== undefined || pickerAnswered(r) !== true) return []
  const filled = input.answers
  if (filled !== undefined && (typeof filled !== 'object' || filled === null || Object.keys(filled).length > 0)) return []
  const questions = input.questions
  if (!Array.isArray(questions)) return []
  const answers = ((r.result ?? {}) as { answers?: unknown }).answers
  if (!answers || typeof answers !== 'object') return []
  return (questions as (Asked | null)[]).flatMap(q => (q && typeof q === 'object' && typeof q.question === 'string' ? [{ q, given: (answers as Record<string, unknown>)[q.question] }] : []))
}

/**
 * His decisions to close a PR unmerged in one picker, from the call as it was made and what the
 * dialog handed back; empty for everything else. `linked` is mod-kit's answer for each pull request
 * link the picker holds.
 */
export const closeDecisions = (input: Record<string, unknown>, r: Result, linked: ReadonlyMap<string, string | null> = new Map()): CloseDecision[] => {
  const mine = hisAnswers(input, r)
  // His answer covers the picker because he read it (#3321).
  if (!mine.length || askFault(input) !== undefined) return []
  const out: CloseDecision[] = []
  for (const { q, given } of mine) {
    if (q.multiSelect === true || !Array.isArray(q.options)) continue
    // One answer, and one the picker offered: words he typed are for Claude to read, never a pick.
    if (typeof given !== 'string' || !q.options.some(o => !!o && typeof o === 'object' && (o as { label?: unknown }).label === given)) continue
    if (!closesUnmerged(given)) continue
    const inAnswer = namedAsPr(given, linked)
    const named = inAnswer.length ? inAnswer : namedAsPr(q.question, linked)
    const pr = named[0]
    if (named.length !== 1 || !pr) continue
    out.push({ pr, answer: given, unless: inAnswer.length ? [] : prRefs(`${q.question}\n${given}`, pr, linked) })
  }
  return out
}

// No pull request: handed to prRefs as the one to leave out, so it leaves none out.
const NO_PR: PrRef = { number: 0 }

/**
 * Every pull request one answered picker of his names, question by question, with what he answered
 * there: by the words that name one as a pull request, by a bare #N, or by its link. Read wider
 * than a decision is, since all it can do is withdraw an earlier pick, and then he is asked.
 */
const answeredAbout = (input: Record<string, unknown>, r: Result, linked: ReadonlyMap<string, string | null>): { refs: PrRef[]; answer: string }[] =>
  hisAnswers(input, r).flatMap(({ q, given }) => {
    const answer = typeof given === 'string' ? given : Array.isArray(given) ? given.map(String).join(', ') : ''
    if (!answer) return []
    const text = `${q.question}\n${answer}`
    return [{ refs: [...namedAsPr(text, linked), ...prRefs(text, NO_PR, linked)], answer }]
  })

/** What is recorded from one decision, in the repository its PR is in. */
export const pickedClosed = (repo: string, d: CloseDecision): ScopeModesLeftClosed => ({
  repo,
  number: d.pr.number,
  closed: true,
  why: `Dan answered "${quoteOf(d.answer)}" in a picker naming it`,
  picked: true,
  ...(d.unless.length ? { unless: d.unless } : {}),
})

const msg = (err: unknown): string => (err instanceof Error ? err.message : String(err))
const samePr = (d: ScopeModesLeftAsIs, repo: string, number: number) => d.number === number && d.repo.toLowerCase() === repo.toLowerCase()

/** The caller's own repository, link reader, record of his answers and log. */
export type PickedIo = {
  /** owner/name of the session's repository, or undefined when it cannot be read. */
  slug: () => Promise<string | undefined>
  /** The pull requests this session opened, each by its repository and number. */
  opened: () => Promise<readonly { repo: string; number: number }[]>
  /** GitHub's state for a PR now (OPEN, CLOSED, MERGED), or why it could not be read. */
  state: (repo: string, number: number) => Promise<string | { unreadable: string }>
  /** mod-kit's reader of a github.com link ($.modkit.linkRepo). */
  linkRepo: (link: string) => Promise<string | null>
  /** The record of his answers with the version it is at, and a write that lands only on that version. */
  left: () => Promise<{ value?: ScopeModesLeftAsIs[] | null; version: number }>
  setLeft: (all: ScopeModesLeftAsIs[], ifVersion: number) => Promise<{ isSet: boolean }>
  log: (line: string) => void
}

/**
 * Changes the record of his answers as it stands at the moment of writing, and answers with it as
 * it stands after. Never a list read earlier written back whole: an answer of his recorded in
 * between, by another picker or by leave_pr_open, would be written over (the lessons review of
 * #3779). The write lands only on the version that was read, and is made again on a newer one
 * otherwise, so `change` can run more than once and decides only from the list it is handed;
 * undefined writes nothing.
 */
export const changeLeft = async (
  io: Pick<PickedIo, 'left' | 'setLeft'>,
  change: (all: readonly ScopeModesLeftAsIs[]) => ScopeModesLeftAsIs[] | undefined,
): Promise<readonly ScopeModesLeftAsIs[]> => {
  for (let attempt = 0; attempt < 10; attempt++) {
    const held = await io.left()
    const now = held.value ?? []
    const next = change(now)
    if (!next) return now
    if ((await io.setLeft(next, held.version)).isSet) return next
  }
  throw new Error('the record of his answers changed under every one of 10 attempts to write it')
}

/** One of his own picks to close a PR unmerged, placed or waiting on GitHub or not kept. */
const isPicked = (x: ScopeModesLeftAsIs): x is ScopeModesLeftClosed => isLeftClosed(x) && x.picked === true

/**
 * What one answered picker changed on the record of his picks: those recorded, those an answer of
 * his withdrew (with that answer), and why one could not be recorded.
 */
export type Noted = { recorded: ScopeModesLeftClosed[]; withdrawn: { was: ScopeModesLeftClosed; answer: string }[]; failed: string[] }

/**
 * Records each decision of his in one answered picker, one answer per PR, a new one replacing
 * whatever he said about it before, and withdraws an earlier pick of his about a PR this picker
 * names, while that PR is still open, when his answer here is no decision to close it (he chose to
 * merge it after all, say).
 * Never throws, so his answer always reaches Claude: one that cannot be recorded is in `failed`,
 * for the session and Dan to be told, and the PR is then asked about as it was before this existed.
 *
 * A pull request his words name by number alone is placed by the pull requests this session
 * opened: the one opened under that number says which repository, two say nothing is on record,
 * and none leaves the session's own repository, where its branch's pull request is.
 */
export const notePicked = async (io: PickedIo, input: Record<string, unknown>, r: Result): Promise<Noted> => {
  const noted: Noted = { recorded: [], withdrawn: [], failed: [] }
  const fail = (line: string) => {
    io.log(line)
    noted.failed.push(line)
  }
  const questions = Array.isArray(input.questions) ? (input.questions as ({ question?: unknown; options?: unknown } | null)[]) : []
  const texts = questions.flatMap(q => [String(q?.question ?? ''), ...(Array.isArray(q?.options) ? q.options.map(o => String((o as { label?: unknown } | null)?.label ?? '')) : [])])
  const mayDecide = texts.some(closesUnmerged)
  try {
    // Nothing to look up for a picker with no decision in it, while no pick of his stands to be withdrawn.
    if (!mayDecide && !(hisAnswers(input, r).length && ((await io.left()).value ?? []).some(isPicked))) return noted
    const linked = new Map<string, string | null>()
    for (const text of texts) for (const { link } of prLinks(text)) if (!linked.has(link)) linked.set(link, await io.linkRepo(link))
    const found = mayDecide ? closeDecisions(input, r, linked) : []
    const about = answeredAbout(input, r, linked)
    // Each record is made before the list is touched, so nothing is waited on between reading it and writing it.
    const records: ScopeModesLeftClosed[] = []
    for (const d of found) {
      const could = `Dan's answer "${quoteOf(d.answer)}" about PR ${refSaid(d.pr)} could not be recorded`
      let repo = d.pr.repo
      if (!repo) {
        const mine = [...new Map((await io.opened()).filter(o => o.number === d.pr.number).map(o => [o.repo.toLowerCase(), o.repo])).values()]
        if (mine.length > 1) {
          fail(`${could}: this session opened a pull request numbered ${d.pr.number} in ${mine.join(' and in ')}, and his picker named no repository, so which one he chose to close is not on record. Winding down asks about that PR as if he had not answered`)
          continue
        }
        repo = mine[0] ?? (await io.slug())
      }
      if (!repo) {
        fail(`${could}: this session's repository could not be read, so which repository it is in is not known. Winding down asks about that PR as if he had not answered`)
        continue
      }
      records.push(pickedClosed(repo, d))
    }
    // An earlier pick of his that this picker names and does not make again is withdrawn while its
    // PR is still open: he changed his mind before it was closed. Closed, his pick has been carried
    // out, so a later picker that mentions it undoes nothing and never has him asked a second time;
    // reopening it is what makes it outstanding again. GitHub is asked only of such a pick, and
    // where it cannot say the pick is withdrawn, since asking him again is the harmless side (L648).
    const reversed: Noted['withdrawn'] = []
    for (const x of about.length ? ((await io.left()).value ?? []).filter(isPicked) : []) {
      if (records.some(rec => samePr(x, rec.repo, rec.number))) continue
      const by = about.find(a => a.refs.some(ref => ref.number === x.number && (!ref.repo || ref.repo.toLowerCase() === x.repo.toLowerCase())))
      if (by && (await io.state(x.repo, x.number)) !== 'CLOSED') reversed.push({ was: x, answer: by.answer })
    }
    if (!records.length && !reversed.length) return noted
    // Withdrawn only where it is still the pick GitHub was asked about, on the record as it stands when written.
    const still = (x: ScopeModesLeftAsIs, was: ScopeModesLeftClosed) => isPicked(x) && samePr(x, was.repo, was.number) && x.why === was.why
    let withdrawn: Noted['withdrawn'] = []
    await changeLeft(io, all => {
      withdrawn = reversed.filter(({ was }) => all.some(x => still(x, was)))
      if (!records.length && !withdrawn.length) return undefined
      const kept = all.filter(x => !withdrawn.some(({ was }) => still(x, was)))
      return records.reduce<ScopeModesLeftAsIs[]>((list, rec) => [...list.filter(x => !samePr(x, rec.repo, rec.number)), rec], kept)
    })
    noted.recorded = records
    noted.withdrawn = withdrawn
  } catch (err) {
    fail(
      mayDecide
        ? `Dan's answer to close a PR unmerged could not be recorded (${msg(err)}), so winding down asks about that PR as if he had not answered`
        : `A later answer of Dan's could not be read against his choice to close a PR unmerged (${msg(err)}), so that choice still stands on record: ask him before relying on it`,
    )
  }
  return noted
}

// How one pick of his is named: the PR, his answer quoted, and what it still waits on.
const pickSaid = (d: ScopeModesLeftClosed): string => {
  const also = (d.unless ?? []).map(refSaid)
  const waits = also.length ? `; not counted until GitHub says ${also.join(' and ')}, which that picker also named, ${also.length === 1 ? 'is no pull request' : 'are no pull requests'}` : ''
  return `PR #${d.number} in ${d.repo} (${d.why}${waits})`
}

/**
 * What the session and Dan are told the moment a picker of his changed the record: each pick
 * recorded, each withdrawn, and each that could not be recorded, one sentence apiece.
 */
export const notedSaid = (n: Noted): string[] => [
  ...n.recorded.map(
    d =>
      `Recorded as Dan's choice to close it unmerged: ${pickSaid(d)}. Winding down leaves it closed while it stays closed without merging, every turn end names it, and a later answer of his in a picker naming that pull request while it is still open, other than to close it unmerged, withdraws it.`,
  ),
  ...n.withdrawn.map(
    ({ was, answer }) =>
      `Withdrawn: Dan's choice to close PR #${was.number} in ${was.repo} unmerged (${was.why}) no longer stands, as he then answered "${quoteOf(answer)}" in a picker naming that pull request. Winding down waits on it until it is merged, or until he is asked about it again.`,
  ),
  ...n.failed.map(line => `${line}.`),
]

/**
 * What a turn end says of his picks on record, each PR named and his answer quoted, or no words
 * with none. Every one that stands is said, whether or not winding down is on and whether or not
 * its PR is closed yet, so a wrong record is in front of him before it settles anything. `quoted`
 * is true of one the turn end's own refusal already lists as left closed, which is not said twice;
 * one not kept is no choice of his to name, and is said with its PR where that is sent back.
 */
export const picksSaid = (all: readonly ScopeModesLeftAsIs[], quoted: (d: ScopeModesLeftClosed) => boolean = () => false): string => {
  const picks = all.filter((d): d is ScopeModesLeftClosed => isPicked(d) && !d.notKept && !quoted(d))
  if (!picks.length) return ''
  return `On record as Dan's choice to close unmerged: ${picks.map(pickSaid).join('; ')}. Winding down leaves ${picks.length === 1 ? 'it' : 'each'} closed while it stays closed without merging.`
}

/** PickedIo, and GitHub's answer for the first of `refs` that is a PR: undefined for none, or why it could not be read. */
export type PlaceIo = Pick<PickedIo, 'left' | 'setLeft' | 'log'> & {
  named: (repo: string, refs: readonly PrRef[], where: string) => Promise<PrRef | undefined | { unreadable: string }>
}

// Why a pick is not kept as his choice: its picker named a second pull request.
const notKeptWhy = (other: PrRef) => `its picker also named ${refSaid(other)}, which is a PR too, so which one he chose to close is not on record`
const sameRef = (a: PrRef, b: PrRef | undefined) => !!b && a.number === b.number && (a.repo ?? '').toLowerCase() === (b.repo ?? '').toLowerCase()
/**
 * Whether a record is still the answer GitHub was asked about: about that PR, naming the same
 * other numbers, which is all GitHub's answer was about. An answer recorded since that names other
 * numbers, or none, or is about another PR, is not, and what GitHub said is never applied to it.
 */
const sameWaiting = (x: ScopeModesLeftAsIs, was: ScopeModesLeftClosed): boolean => {
  if (!isLeftClosed(x) || !samePr(x, was.repo, was.number)) return false
  const [now, then] = [x.unless ?? [], was.unless ?? []]
  return now.length === then.length && now.every((ref, i) => sameRef(ref, then[i]))
}

/**
 * His answers with each picked one placed: one whose picker named another number stands once
 * GitHub has said that number is no pull request, and is then kept without it; it is dropped, and
 * logged, where that number is a pull request, since which he meant is not on record; and it waits,
 * unchanged, with why in `unread`, while GitHub cannot say. `only` narrows which are placed.
 *
 * GitHub is asked first, and what it said is then applied to the record as it stands at the moment
 * of writing (changeLeft), only to an answer that is still the one GitHub was asked about. So
 * an answer of his recorded while GitHub was being asked is kept as he gave it: it is in `choices`,
 * and one of those naming another number waits for the next placing, with `unread` saying GitHub
 * has not been asked about it yet.
 */
export const placePicked = async (
  io: PlaceIo,
  only: (d: ScopeModesLeftClosed) => boolean = () => true,
): Promise<{ choices: ScopeModesLeftAsIs[]; unread: Map<ScopeModesLeftAsIs, string> }> => {
  const all: readonly ScopeModesLeftAsIs[] = (await io.left()).value ?? []
  // What GitHub said of each waiting answer, by the answer as it was read.
  const stands: ScopeModesLeftClosed[] = []
  const dropped: { was: ScopeModesLeftClosed; other: PrRef }[] = []
  const unreadable: { was: ScopeModesLeftClosed; why: string }[] = []
  for (const d of all) {
    if (!isLeftClosed(d) || !d.unless?.length || !only(d)) continue
    const other = await io.named(d.repo, d.unless, `the picker Dan answered about PR #${d.number}`)
    if (other && 'unreadable' in other) unreadable.push({ was: d, why: other.unreadable })
    else if (other) dropped.push({ was: d, other })
    else stands.push(d)
  }
  let gone: typeof dropped = []
  const choices =
    stands.length || dropped.length
      ? await changeLeft(io, fresh => {
          gone = []
          let changed = false
          const next = fresh.flatMap((x): ScopeModesLeftAsIs[] => {
            if (isLeftClosed(x) && stands.some(was => sameWaiting(x, was))) {
              changed = true
              return [{ repo: x.repo, number: x.number, closed: true, why: x.why, ...(x.picked ? { picked: true as const } : {}) }]
            }
            const drop = dropped.find(({ was }) => sameWaiting(x, was))
            if (!drop || !isLeftClosed(x)) return [x]
            changed = true
            gone.push(drop)
            // Kept on the record, marked, so every turn end that sends its PR back says why (not only this one).
            return [{ repo: x.repo, number: x.number, closed: true, why: x.why, picked: true as const, notKept: notKeptWhy(drop.other) }]
          })
          return changed ? next : undefined
        })
      : all
  // Said once, of what the write that landed took out, however many times it was tried.
  for (const { was, other } of gone) io.log(`Dan's answer about PR #${was.number} in ${was.repo} is not kept: ${notKeptWhy(other)}`)
  const unread = new Map<ScopeModesLeftAsIs, string>()
  for (const x of choices) {
    if (!isLeftClosed(x) || !x.unless?.length || !only(x)) continue
    // One recorded while GitHub was being asked has not been asked about, and is said to be so.
    const notAsked = `whether ${x.unless.map(refSaid).join(' and ')}, named in the picker Dan answered about PR #${x.number}, is a PR: GitHub has not been asked yet, as that answer was recorded while it was being asked about an earlier one`
    unread.set(x, unreadable.find(({ was }) => sameWaiting(x, was))?.why ?? notAsked)
  }
  return { choices: [...choices], unread }
}
