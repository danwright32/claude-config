import type { ModKitGh } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { LINKED, NUMBER, PULL, type LinkRepo, type Ran } from './adminmerge.ts'
import { LABEL_REFUSAL, SETS_LABEL } from './overnight.ts'

// Sleep mode (#3439): the one label a session may set on a pull request overnight. Labels and
// milestones on a pull request are banned overnight (overnight.ts). On 2026-11-21 that ban refused
// `gh pr create ... --label changelog/technical` in a project whose merge gate refuses any merge of
// a pull request without one changelog label, so the pull request was opened without it, went green
// in fourteen minutes and sat unmerged for ten and a half hours. A label is allowed overnight only
// when all of these hold, and refused everywhere else, as before:
//
// - the command is `gh pr create` naming the label with --label or -l, or `gh pr edit` naming it with
//   --add-label, and it names exactly one label (overnight.ts has by then refused a milestone, a
//   label removed and any flag neither command may carry, and held the write to the checkout's own
//   repository);
// - that repository's merge gate says it requires a label on its pull requests, and the label is one
//   the gate takes;
// - for `gh pr edit`, the command names one pull request by its number or its own link, and the
//   session's record of the pull requests it opened holds that repository and number.
//
// A label the gate says needs a sentence a manager reads (today changelog/visible) is allowed like
// the others: Dan's decision of 2026-11-22, by picker, "Also allow changelog/visible", knowing a
// session can then merge overnight a pull request whose changelog sentence he has not read. The gate
// still refuses the merge of a pull request carrying it whose description has no such sentence, so
// the session is told that as the label goes on (`note`, which register.ts puts on the call's
// result). Whether a label needs one is still the gate's answer, and an answer that does not say is
// one that could not be read.
//
// Which labels those are is the gate's answer, never a list here, so the two cannot drift: the gate
// (payload/hooks/require-changelog-tag.sh) keeps its rule in payload/hooks/lib/changelog-entry.js,
// and this asks that file's command line, `required-labels <owner/name>`. Which pull requests the
// session opened is the record winding down already keeps (`opened` in this mod's state, written
// from the link each `gh pr create` printed, by the session or any of its agents); GitHub's author
// would not do, since every session on the Mac opens pull requests as the same account.
//
// Whatever cannot be told is refused, saying why (L11, L98): a gate that cannot be run or whose
// answer cannot be read, a repository the gate cannot speak for, a label that cannot be read from
// the command, a pull request not named by number, and a record that cannot be read.
//
// Pure: the gate is asked through `Gate` and the record through `Opened`, which register.ts builds.
// A refusal here is overnight.ts's own for any label on a pull request (LABEL_REFUSAL), with why in
// brackets after it.

/** One label a merge gate takes, and whether it refuses it on a description carrying no sentence. */
export type GateLabel = { label: string; needsSentence: boolean }
/** A merge gate's answer about one repository: the labels it requires one of, none, or why it cannot be told. */
export type GateAnswer = { state: 'required'; labels: GateLabel[] } | { state: 'not-required' } | { state: 'unknown'; why: string }
export type Gate = (repo: string) => Promise<GateAnswer>

export type OpenedPr = { repo: string; number: number }
/** The pull requests this session opened, or why that could not be told. */
export type Opened = () => Promise<readonly OpenedPr[] | { why: string }>

const msg = (err: unknown) => (err instanceof Error ? err.message : String(err))
const record = (v: unknown): Record<string, unknown> | null => (v !== null && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null)

/** How the gate is asked: its own library's command line, in the hooks installed on this Mac. */
export const gateArgv = (home: string, repo: string): string[] => ['node', `${home}/.claude/hooks/lib/changelog-entry.js`, 'required-labels', repo]

const SHAPE = 'its answer was not one this reader knows'
/** The gate's answer, read from what running it printed. Anything but a whole answer is unknown, never "requires nothing". */
export const gateAnswerOf = (r: Ran): GateAnswer => {
  if (r.exitCode !== 0) return { state: 'unknown', why: r.stderr.trim().split('\n').pop() || `the gate exited ${r.exitCode}` }
  if (r.isStdoutTruncated) return { state: 'unknown', why: 'its answer was cut short' }
  let json: unknown
  try {
    json = JSON.parse(r.stdout)
  } catch {
    return { state: 'unknown', why: 'its answer was not JSON' }
  }
  const o = record(json)
  if (!o) return { state: 'unknown', why: SHAPE }
  if (o.state === 'unknown') return { state: 'unknown', why: typeof o.why === 'string' && o.why.trim() ? o.why.trim() : 'the gate gave no reason' }
  if (o.state === 'not-required') return { state: 'not-required' }
  if (o.state !== 'required' || !Array.isArray(o.labels) || !o.labels.length) return { state: 'unknown', why: SHAPE }
  const labels: GateLabel[] = []
  for (const l of o.labels) {
    const one = record(l)
    // A label holding a comma could never be named alone, since gh splits a label flag's value on them.
    if (!one || typeof one.label !== 'string' || !one.label || one.label.includes(',') || typeof one.needsSentence !== 'boolean') return { state: 'unknown', why: SHAPE }
    labels.push({ label: one.label, needsSentence: one.needsSentence })
  }
  return { state: 'required', labels }
}

/** The gate, asked by running its library through `run`; one that cannot be run is unknown, with why. */
export const gateOf = (run: (argv: string[]) => Promise<Ran>, home: string): Gate => async repo => {
  if (!home) return { state: 'unknown', why: 'this session has no HOME folder to find the merge gate under' }
  try {
    return gateAnswerOf(await run(gateArgv(home, repo)))
  } catch (err) {
    return { state: 'unknown', why: msg(err) }
  }
}

/** The session's record of the pull requests it opened, read through `get` (this mod's `opened` state); no record yet is none opened. */
export const openedFrom = (get: () => Promise<unknown>): Opened => async () => {
  let value: unknown
  try {
    value = await get()
  } catch (err) {
    return { why: msg(err) }
  }
  if (value === undefined || value === null) return []
  if (!Array.isArray(value)) return { why: 'the record of the PRs this session opened is not a list this reader knows' }
  const out: OpenedPr[] = []
  for (const v of value) {
    const o = record(v)
    if (!o || typeof o.repo !== 'string' || typeof o.number !== 'number') return { why: 'the record of the PRs this session opened is not a list this reader knows' }
    out.push({ repo: o.repo, number: o.number })
  }
  return out
}

const because = (why: string) => `${LABEL_REFUSAL} (${why})`
// A label as the refusal shows it: what was written, cut where it would bury the sentence.
const shown = (label: string) => (label.length > 60 ? `${label.slice(0, 60)}...` : label)

// The one PR a `gh pr edit` names, by number or by its own link in `repo`; null when it names none
// that way (no PR, a branch, more than one, a link to anything under the PR).
const editedPr = async (g: ModKitGh, repo: string, linkRepo: LinkRepo): Promise<number | null> => {
  const only = g.positionals.length === 1 ? (g.positionals[0] ?? '') : ''
  if (NUMBER.test(only)) return Number(only)
  const pull = only.startsWith(LINKED) ? PULL.exec(only) : null
  if (!pull) return null
  const linked = await linkRepo(only).catch(() => null)
  if (linked === null || linked.toLowerCase() !== repo.toLowerCase()) return null
  return [`${LINKED}${linked}/pull/${pull[1]}`, `${LINKED}${linked}/pull/${pull[1]}/`].includes(only) ? Number(pull[1]) : null
}

/**
 * What a session is told as it sets a label the gate takes only with a sentence in the description:
 * the merge is refused until that sentence is there. What the sentence must look like is the gate's
 * to say, in its own refusal, so it is not restated here.
 */
export const sentenceNote = (label: string, repo: string) =>
  `The merge gate of ${repo} refuses the merge of a PR labelled ${label} until its description carries the Changelog sentence a manager reads, so see that the description has it before merging.`

/**
 * Why a `gh pr create` or `gh pr edit` that sets a label is refused tonight in `repo` (the repository
 * the overnight write rule resolved it to), or undefined when it may run. The command has passed
 * overnight.ts: it carries no milestone, removes no label, and no flag its action may not carry.
 * `note` is handed `sentenceNote` when the call may run and its label needs a sentence, never on a
 * refusal.
 */
export const judgeRequiredLabel = async (g: ModKitGh, repo: string, gate: Gate, opened: Opened, linkRepo: LinkRepo, note?: (text: string) => void): Promise<string | undefined> => {
  const flags = SETS_LABEL[g.act]
  if (g.sub !== 'pr' || !flags) return LABEL_REFUSAL
  const values = g.flags.filter(f => flags.includes(f.name)).map(f => f.value)
  if (!values.length || values.some(v => typeof v !== 'string')) return because('the label it sets could not be read from the command')
  // gh takes several labels in one flag, split on commas, so each piece is a label of its own.
  const names = (values as string[]).flatMap(v => v.split(','))
  if (names.length !== 1) return because(`more than one label is named, and only the one label the merge gate of ${repo} requires may be set overnight`)
  const name = names[0] as string

  let answer: GateAnswer
  try {
    answer = await gate(repo)
  } catch (err) {
    answer = { state: 'unknown', why: msg(err) }
  }
  if (answer.state === 'unknown') return because(`whether the merge gate of ${repo} requires a label could not be told: ${answer.why}`)
  if (answer.state === 'not-required') return because(`the merge gate of ${repo} requires no label`)
  // The gate's own spelling, exactly: a label in another case or with a space is another label here.
  const label = answer.labels.find(l => l.label === name)
  if (!label) return because(`${shown(name)} is not a label the merge gate of ${repo} requires`)
  const allowed = () => {
    if (label.needsSentence) note?.(sentenceNote(label.label, repo))
    return undefined
  }
  if (g.act === 'create') return allowed()

  const pr = await editedPr(g, repo, linkRepo)
  if (pr === null) return because('the command names no one PR by its number, so whether this session opened it could not be told')
  let mine: readonly OpenedPr[] | { why: string }
  try {
    mine = await opened()
  } catch (err) {
    mine = { why: msg(err) }
  }
  if ('why' in mine) return because(`whether this session opened PR #${pr} could not be told: ${mine.why}`)
  if (!mine.some(o => o.repo.toLowerCase() === repo.toLowerCase() && o.number === pr)) return because(`PR #${pr} in ${repo} is not one this session opened`)
  return allowed()
}
