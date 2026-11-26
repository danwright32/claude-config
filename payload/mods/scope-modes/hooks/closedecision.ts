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
// - the answer is one the picker offered and he picked, alone, in the session's own picker (never a
//   subagent's, never typed, never a picker that closed by itself), in words he could read whole
//   (mod-kit's askFault, as #3321 holds every recorded picker to);
// - it begins "Close" and says unmerged, so "Leave it closed" and "Leave it open" stay the tool's
//   own answers and are never read from a session's picker (#917, #1033);
// - the words he read name exactly one pull request as a pull request ("pull request 3749",
//   "PR #31", its link): the answer when it names one, else the question;
// - any other number the question names with a # may be a pull request too (his question named
//   an issue that way, #3692), so his answer counts only once GitHub has said each is none. Until
//   then the PR is neither settled nor sent back to be reopened, and where one is a pull request,
//   which he meant is not on record and nothing is kept.
//
// What is recorded is the one record winding down already reads a closed PR against (LeftClosed,
// #1033), so one rule decides whether a PR is left as it is (leftByChoice) and a later answer of his
// to leave_pr_open replaces it. Pure, but for the caller's own state, repository and GitHub reads,
// handed in as closures the engine has spelled in place.
import type { ScopeModesLeftAsIs, ScopeModesLeftClosed } from '../types/index.d.ts'
import { askFault } from './mod-kit/shown.ts'
import { pickerAnswered } from './morning.ts'
import { isLeftClosed, prLinks, prRefs, quoteOf, refSaid, type PrRef } from './winddown.ts'

// A picker's own numbering before an answer ("3.79.1 ", "2. "), and the mark of the recommended one.
const NUMBERED = /^\s*\d+(?:\.\d+)*[.)]?\s+/
const RECOMMENDED = /\s*\(recommended\)\s*$/i
const SAYS_UNMERGED = /\bunmerged\b|\bwithout merging\b|\b(?:not|never|don't) merg(?:e|ed|ing)\b/i

/** Whether an answer is a decision to close a PR unmerged: it begins "Close" and says unmerged. */
export const closesUnmerged = (label: string): boolean => {
  const said = label.replace(NUMBERED, '').replace(RECOMMENDED, '')
  return /^closed?\b/i.test(said) && SAYS_UNMERGED.test(said)
}

// A number said to be a pull request: "pull request 3749", "PR 31", "PR #31", "PR o/r#31". A bare
// #N is an issue as often as a PR and names none here, and neither does a number that goes on past
// a point (a picker's own "3.79").
const NAMED_AS_PR = /\b(?:pull request|PR)(?:\s+(?:([\w.-]+\/[\w.-]+)#|#)?|#)(\d+)\b(?!\.\d)/gi

/**
 * The pull requests a text names as pull requests, in order, each once. A link names its own once
 * `linked` holds mod-kit's answer for it, the repository it is in (#1777).
 */
export const namedAsPr = (text: string, linked: ReadonlyMap<string, string | null> = new Map()): PrRef[] => {
  const found: { at: number; repo?: string; number: number }[] = []
  for (const m of text.matchAll(NAMED_AS_PR)) found.push({ at: m.index ?? 0, ...(m[1] ? { repo: m[1] } : {}), number: Number(m[2]) })
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

/**
 * His decisions to close a PR unmerged in one picker, from the call as it was made and what the
 * dialog handed back; empty for everything else. `linked` is mod-kit's answer for each pull request
 * link the picker holds.
 */
export const closeDecisions = (input: Record<string, unknown>, r: { deny?: unknown; isError?: unknown; result?: unknown }, linked: ReadonlyMap<string, string | null> = new Map()): CloseDecision[] => {
  // A subagent's picker, and one that was refused, failed, closed by itself or came back unanswered.
  if (input.agentId !== undefined || pickerAnswered(r) !== true) return []
  // A call carrying its own answers: only his choice in the dialog is his (as the lesson picker holds, #867).
  const filled = input.answers
  if (filled !== undefined && (typeof filled !== 'object' || filled === null || Object.keys(filled).length > 0)) return []
  const questions = input.questions
  if (!Array.isArray(questions)) return []
  const answers = ((r.result ?? {}) as { answers?: unknown }).answers
  if (!answers || typeof answers !== 'object') return []
  // His answer covers the picker because he read it (#3321).
  if (askFault(input) !== undefined) return []
  const out: CloseDecision[] = []
  for (const q of questions as ({ question?: unknown; multiSelect?: unknown; options?: unknown } | null)[]) {
    if (!q || typeof q !== 'object' || q.multiSelect === true || typeof q.question !== 'string' || !Array.isArray(q.options)) continue
    // One answer, and one the picker offered: words he typed are for Claude to read, never a pick.
    const given = (answers as Record<string, unknown>)[q.question]
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

/**
 * Records each decision of his in one answered picker, one answer per PR, a new one replacing
 * whatever he said about it before. Never throws, so his answer always reaches Claude: one that
 * cannot be recorded is logged, and the PR is then asked about as it was before this existed.
 */
export const notePicked = async (io: PickedIo, input: Record<string, unknown>, r: { deny?: unknown; isError?: unknown; result?: unknown }): Promise<void> => {
  try {
    // Nothing to look up for a picker with no decision in it, read once without its links.
    const questions = Array.isArray(input.questions) ? (input.questions as ({ question?: unknown; options?: unknown } | null)[]) : []
    const texts = questions.flatMap(q => [String(q?.question ?? ''), ...(Array.isArray(q?.options) ? q.options.map(o => String((o as { label?: unknown } | null)?.label ?? '')) : [])])
    if (!texts.some(closesUnmerged)) return
    const linked = new Map<string, string | null>()
    for (const text of texts) for (const { link } of prLinks(text)) if (!linked.has(link)) linked.set(link, await io.linkRepo(link))
    const found = closeDecisions(input, r, linked)
    if (!found.length) return
    // Each record is made before the list is touched, so nothing is waited on between reading it and writing it.
    const records: ScopeModesLeftClosed[] = []
    for (const d of found) {
      const repo = d.pr.repo ?? (await io.slug())
      if (!repo) {
        io.log(`Dan's answer "${quoteOf(d.answer)}" about PR ${refSaid(d.pr)} could not be recorded: this session's repository could not be read, so which repository it is in is not known. Winding down asks about that PR as if he had not answered`)
        continue
      }
      records.push(pickedClosed(repo, d))
    }
    if (records.length) await changeLeft(io, all =>records.reduce<ScopeModesLeftAsIs[]>((kept, rec) => [...kept.filter(x => !samePr(x, rec.repo, rec.number)), rec], [...all]))
  } catch (err) {
    io.log(`Dan's answer to close a PR unmerged could not be recorded (${msg(err)}), so winding down asks about that PR as if he had not answered`)
  }
}

/** PickedIo, and GitHub's answer for the first of `refs` that is a PR: undefined for none, or why it could not be read. */
export type PlaceIo = Pick<PickedIo, 'left' | 'setLeft' | 'log'> & {
  named: (repo: string, refs: readonly PrRef[], where: string) => Promise<PrRef | undefined | { unreadable: string }>
}

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
            if (!drop) return [x]
            changed = true
            gone.push(drop)
            return []
          })
          return changed ? next : undefined
        })
      : all
  // Said once, of what the write that landed took out, however many times it was tried.
  for (const { was, other } of gone) io.log(`Dan's answer about PR #${was.number} in ${was.repo} is not kept: its picker also named ${refSaid(other)}, which is a PR too, so which one he chose to close is not on record`)
  const unread = new Map<ScopeModesLeftAsIs, string>()
  for (const x of choices) {
    if (!isLeftClosed(x) || !x.unless?.length || !only(x)) continue
    // One recorded while GitHub was being asked has not been asked about, and is said to be so.
    const notAsked = `whether ${x.unless.map(refSaid).join(' and ')}, named in the picker Dan answered about PR #${x.number}, is a PR: GitHub has not been asked yet, as that answer was recorded while it was being asked about an earlier one`
    unread.set(x, unreadable.find(({ was }) => sameWaiting(x, was))?.why ?? notAsked)
  }
  return { choices: [...choices], unread }
}
