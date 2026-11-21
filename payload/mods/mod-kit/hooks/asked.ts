// A question a mod asks Dan itself, through its own dialog ($.ui.ask), counted before any limit is
// put on it (#3321; Dan, 2026-11-21: "Record, then decide"). Such a question reaches the same
// dialog a session's picker does and its answer is acted on, so it should be held to the one check
// of text a person approves in a picker (shown.ts). But none is in any session record, so how
// many that check would refuse could not be counted, and a guard is never switched on uncounted.
// So each is recorded here as it is asked: how long it is, how many rows it takes, how many
// answers it offers, which question of which mod it was, and whether the check would refuse it.
// Never a word of it: a question can name a repository, a branch or an issue's own text.
//
// Recording only. Nothing here holds a question back or refuses one: it is asked whatever the
// record says and whatever happens to the record. A record that cannot be kept is said once a
// session, since a count that silently holds nothing would read in two weeks as nothing asked.
//
// Where: one small file a question under ~/.claude/state/asked-questions, on this Mac only (the
// state folder is never synced), named by the moment it was asked. One file each, so two sessions
// asking at once never write over each other. At most ASKED_KEEP are kept, the oldest going first.
// Read with tools/asked-questions-count.ts, which prints counts and never a path's content.
//
// Kept here once and copied byte for byte into each mod that asks a question itself
// (hooks/mod-kit/asked.ts, beside its copy of shown.ts, which tools/check-mod-shared-parts.sh
// holds to these and which fails a mod that calls $.ui.ask any other way), since a mod cannot
// import another mod's files. The engine requires $ spelled in place at every call, so the caller
// hands its own clock, files and dialog, each a one line closure over its own $.

import { askFault, rowsAt } from './shown.ts'

/** The most records kept. At a few tens of questions a day this is months, far past the two weeks the count is for. */
export const ASKED_KEEP = 2000
/** The most removed in one pass, so a folder far past the bound is brought back over a few questions and one command stays short. */
const ASKED_PRUNE = 50

/** Where the records are kept, under the home folder given. */
export const askedDir = (home: string): string => `${home.replace(/\/+$/, '')}/.claude/state/asked-questions`

/** What $.ui.ask takes beside the question: the answers alone, or the answers with the chip over them. */
export type AskedOptions = readonly string[] | { options?: readonly string[]; header?: string; multiSelect?: true }

/** The caller's own clock, files and dialog. */
export type AskedIo = {
  now: () => Promise<number>
  /** The home folder ($.env.get('HOME')), or undefined when it is not set. */
  home: () => Promise<string | undefined>
  write: (path: string, text: string) => Promise<void>
  /** The names in a folder. */
  list: (dir: string) => Promise<readonly string[]>
  run: (argv: string[]) => Promise<{ exitCode: number; stderr: string }>
  /** The dialog itself: $.ui.ask. */
  ask: (question: string, options?: AskedOptions) => Promise<string>
  /** Where a record that could not be kept is said (the transcript's dim line). */
  said: (line: string) => void
}

/** One question as it is recorded: sizes and names, never text. */
export type Asked = {
  /** When it was asked, in ms. */
  at: number
  mod: string
  /** Which of the mod's questions it was, by the mod's own short name for it. */
  which: string
  /** The question's length in UTF-16 code units, the unit the dialog cuts in. */
  units: number
  /** The rows it takes in a window as wide as the check counts at (rowsAt). */
  rows: number
  /** How many answers it offers, and the longest one's length. */
  options: number
  longest: number
  /** The length of the chip over it, 0 when it has none. */
  header: number
  /** Whether the shared check would refuse the dialog as it is asked (askFault). */
  refused: boolean
}

const labelsOf = (options: AskedOptions | undefined): readonly string[] => (options === undefined ? [] : Array.isArray(options) ? options : ((options as { options?: readonly string[] }).options ?? []))
const headerOf = (options: AskedOptions | undefined): string => (options === undefined || Array.isArray(options) ? '' : ((options as { header?: string }).header ?? ''))

/** The record of one question: its sizes, and the shared check's verdict on the call as the dialog gets it. */
export const askedOf = (mod: string, which: string, question: string, options: AskedOptions | undefined, at: number): Asked => {
  const labels = labelsOf(options)
  const header = headerOf(options)
  // As the engine hands a mod's own dialog on (seen on Claude Code 2.1.330): the question, its
  // chip when it has one, and each answer with an empty description.
  const call = { questions: [{ question, ...(header ? { header } : {}), options: labels.map(label => ({ label, description: '' })), multiSelect: false }] }
  return { at, mod, which, units: question.length, rows: rowsAt(question), options: labels.length, longest: labels.reduce((most, l) => Math.max(most, l.length), 0), header: header.length, refused: askFault(call) !== undefined }
}

const msg = (err: unknown): string => (err instanceof Error ? err.message : String(err))
const RECORD = /^\d{13}-[a-z0-9]+\.json$/

/** Writes one question's record and keeps the folder to its bound. Why it could not, or undefined. Never throws. */
export const recordAsked = async (io: AskedIo, mod: string, which: string, question: string, options?: AskedOptions): Promise<string | undefined> => {
  try {
    const home = await io.home()
    if (!home) return 'HOME is not set, so there is nowhere to keep it'
    const dir = askedDir(home)
    const record = askedOf(mod, which, question, options, await io.now())
    const path = `${dir}/${String(record.at).padStart(13, '0')}-${Math.random().toString(36).slice(2, 10) || 'x'}.json`
    const text = `${JSON.stringify(record)}\n`
    try {
      await io.write(path, text)
    } catch {
      // Most often the folder is not there yet: made once, then the write is tried again and its
      // own failure is the one said.
      const made = await io.run(['mkdir', '-p', dir])
      if (made.exitCode !== 0) return `its folder could not be made (${made.stderr.trim() || `mkdir exited ${made.exitCode}`})`
      await io.write(path, text)
    }
    // The bound: names sort by the moment asked, so the first are the oldest. Only files this
    // wrote are counted or removed.
    const mine = (await io.list(dir)).filter(n => RECORD.test(n)).sort()
    const over = mine.slice(0, Math.min(Math.max(0, mine.length - ASKED_KEEP), ASKED_PRUNE))
    if (over.length) {
      const gone = await io.run(['rm', '-f', '--', ...over.map(n => `${dir}/${n}`)])
      if (gone.exitCode !== 0) return `it was kept, but the oldest records past ${ASKED_KEEP} could not be removed (${gone.stderr.trim() || `rm exited ${gone.exitCode}`})`
    }
    return undefined
  } catch (err) {
    return msg(err)
  }
}

// A record that cannot be kept is said once in a session, in each mod's own copy of this file.
let saidOnce = false
/** For tests: forget that a failure was said. */
export const resetAskedSaid = (): void => {
  saidOnce = false
}

/**
 * Asks a question through the mod's own dialog, recording its size first. The one way a mod calls
 * $.ui.ask (the scan holds every call to this line): the question is asked whatever the record
 * says and whether or not it could be kept, and the dialog's own answer or rejection is the
 * caller's, untouched.
 */
export const recordedAsk = async (io: AskedIo, mod: string, which: string, question: string, options?: AskedOptions): Promise<string> => {
  const why = await recordAsked(io, mod, which, question, options)
  if (why !== undefined && !saidOnce) {
    saidOnce = true
    try {
      io.said(`${mod} could not record the size of a question it asked (${why}), so the count of questions mods ask (claude-config#3321) misses it. The question is asked all the same. Said once a session.`)
    } catch {
      // Nowhere left to say it; the question is still asked.
    }
  }
  return io.ask(question, options)
}
