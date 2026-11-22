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
  /** The mod's own state for its open dialogs: $.state.get and $.state.set of { plugin: <the mod>, key: 'asking' }. */
  own: OwnState
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
  /** The length of the chip the mod gave it, 0 when it gave none and the engine shows its own (ENGINE_CHIP). */
  header: number
  /** Whether the shared check would refuse the dialog as it is asked (askFault). */
  refused: boolean
}

/**
 * The chip the engine puts over a mod's own dialog that gives none (seen on Claude Code 2.1.330,
 * in scope modes' suite, whose closing case fails if the engine's word changes).
 */
export const ENGINE_CHIP = 'Plugin'

const labelsOf = (options: AskedOptions | undefined): readonly string[] => (options === undefined ? [] : Array.isArray(options) ? options : ((options as { options?: readonly string[] }).options ?? []))
const headerOf = (options: AskedOptions | undefined): string => (options === undefined || Array.isArray(options) ? '' : ((options as { header?: string }).header ?? ''))
/** The chip as the dialog shows it: the mod's own, or the engine's when it gave none. */
const chipOf = (options: AskedOptions | undefined): string => headerOf(options) || ENGINE_CHIP

/** The record of one question: its sizes, and the shared check's verdict on the call as the dialog gets it. */
export const askedOf = (mod: string, which: string, question: string, options: AskedOptions | undefined, at: number): Asked => {
  const labels = labelsOf(options)
  // As the engine hands a mod's own dialog on (seen on Claude Code 2.1.330): the question, its
  // chip (the engine's own when the mod gave none), and each answer with an empty description.
  const call = { questions: [{ question, header: chipOf(options), options: labels.map(label => ({ label, description: '' })), multiSelect: false }] }
  return { at, mod, which, units: question.length, rows: rowsAt(question), options: labels.length, longest: labels.reduce((most, l) => Math.max(most, l.length), 0), header: headerOf(options).length, refused: askFault(call) !== undefined }
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

// A dialog a mod raises itself, told apart from a session's picker (#3321). The engine hands a
// mod's own dialog to every hook on AskUserQuestion with nothing on it saying a mod raised it
// (seen on Claude Code 2.1.330: tool, questions and a tool_use_id), and $.ui.ask takes no
// metadata. So the asking mod says so itself, before it asks: it keeps the dialog, as one string,
// in its own $.state (the key `asking`) for as long as the dialog is open. A hook that must not
// treat a mod's own question as a session's (picker manners, which refuses a session's unreadable
// picker about an issue) reads that state and compares the call it was handed.
//
// Why a session cannot fake it: $.state is written by its owner alone (the engine's own rule,
// measured in picker manners' suite), the mod writes this key nowhere but here, around its own
// dialog, and a session has only tools, none of which writes a mod's state. The entry is the
// whole dialog, so a session's picker asked while a mod's dialog is open is the mod's own only if
// it is that very dialog, word for word, with nothing beside it. The words are kept in the
// session's memory only, for as long as the dialog is open; nothing of them is written to a file.
//
// An entry a reload leaves behind (the mod replaced while its dialog was open) stays for the
// session and covers that one dialog's exact words only.

/**
 * The mods that ask through their own dialog and keep it in their own $.state while it is open.
 * The engine requires a state's plugin and key spelled as literals where it is read, so a reader
 * (picker manners) spells one read a mod named here, and tools/check-mod-shared-parts.sh fails a
 * mod that calls the recorder and is not named, and a reader that misses one.
 */
export const OWN_ASKERS = ['scope-modes', 'keystroke-guard'] as const
/** The key each of them keeps its open dialogs under. */
export const OWN_KEY = 'asking'

/** A mod's own $.state value for its open dialogs: read with its version, written only at that version. */
export type OwnState = {
  read: () => Promise<{ value?: readonly string[] | undefined; version: number }>
  write: (value: string[], ifVersion: number) => Promise<{ isSet: boolean }>
}

/**
 * A dialog as one string, as the engine will hand it on: its question, its chip (the engine's own
 * when the mod gives none), its answers and whether several may be chosen. What the engine changes
 * beyond that is not mirrored (it pads fewer than two answers with its own), so such a dialog
 * matches no call and is taken for a session's picker, the side that keeps every check on it.
 */
export const dialogOf = (question: string, options?: AskedOptions): string =>
  JSON.stringify([question, chipOf(options), labelsOf(options), options !== undefined && !Array.isArray(options) && (options as { multiSelect?: true }).multiSelect === true])

const onlyKeys = (o: object, allowed: readonly string[]): boolean => Object.keys(o).every(k => allowed.includes(k))

/**
 * The same string read from an AskUserQuestion call as a hook is handed it, or undefined for a
 * call shaped as no mod's own dialog is: more or fewer than one question, an answer with a
 * description, or any field a mod's own dialog never carries (metadata, a preview, a title).
 * Anything unexpected reads as a session's picker, the side that keeps every check on it.
 */
export const dialogOfCall = (call: Record<string, unknown>): string | undefined => {
  if (!onlyKeys(call, ['tool', 'tool_use_id', 'questions']) || !Array.isArray(call.questions) || call.questions.length !== 1) return undefined
  const q = call.questions[0] as Record<string, unknown> | null
  if (typeof q !== 'object' || q === null || !onlyKeys(q, ['question', 'header', 'options', 'multiSelect'])) return undefined
  if (typeof q.question !== 'string' || (q.header !== undefined && typeof q.header !== 'string') || !Array.isArray(q.options)) return undefined
  if (q.multiSelect !== undefined && typeof q.multiSelect !== 'boolean') return undefined
  const labels: string[] = []
  for (const o of q.options as unknown[]) {
    const option = o as Record<string, unknown> | null
    if (typeof option !== 'object' || option === null || !onlyKeys(option, ['label', 'description']) || typeof option.label !== 'string') return undefined
    if (option.description !== undefined && option.description !== '') return undefined
    labels.push(option.label)
  }
  return JSON.stringify([q.question, q.header ?? '', labels, q.multiSelect === true])
}

/** Whether a call is a dialog a mod has open that it raised itself: `asking` is that mod's state as read, whatever it holds. */
export const isOwnDialog = (asking: unknown, call: Record<string, unknown>): boolean => {
  if (!Array.isArray(asking)) return false
  const dialog = dialogOfCall(call)
  return dialog !== undefined && asking.some(kept => kept === dialog)
}

/** The kept dialogs with one more: two of the same open at once are kept twice. */
export const withDialog = (kept: readonly string[], dialog: string): string[] => [...kept, dialog]

/** The kept dialogs with one entry for that dialog taken out; one never kept changes nothing. */
export const withoutDialog = (kept: readonly string[], dialog: string): string[] => {
  const at = kept.indexOf(dialog)
  return at < 0 ? [...kept] : [...kept.slice(0, at), ...kept.slice(at + 1)]
}

// Read, change and write with ifVersion, again on a miss, so two dialogs opened or closed at once
// never lose each other's entry (assume it runs twice).
const changeOwn = async (own: OwnState, fn: (kept: readonly string[]) => string[]): Promise<void> => {
  for (let attempt = 0; attempt < 10; attempt++) {
    const kept = await own.read()
    const r = await own.write(fn(Array.isArray(kept.value) ? kept.value.filter(x => typeof x === 'string') : []), kept.version)
    if (r.isSet) return
  }
  throw new Error('its open dialogs changed under every one of 10 attempts to update them')
}

// A record that cannot be kept, and a dialog that could not be said to be the mod's own, are each
// said once in a session, in each mod's own copy of this file.
let saidOnce = false
let saidOwnOnce = false
/** For tests: forget that a failure was said. */
export const resetAskedSaid = (): void => {
  saidOnce = false
  saidOwnOnce = false
}

/**
 * Asks a question through the mod's own dialog, recording its size first and keeping the dialog in
 * the mod's own state for as long as it is open. The one way a mod calls $.ui.ask (the scan holds
 * every call to this line): the question is asked whatever the record says, whether or not it
 * could be kept and whether or not the dialog could be said to be the mod's own, and the dialog's
 * own answer or rejection is the caller's, untouched.
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
  const dialog = dialogOf(question, options)
  let isOwnSaid = false
  try {
    await changeOwn(io.own, kept => withDialog(kept, dialog))
    isOwnSaid = true
  } catch (err) {
    if (!saidOwnOnce) {
      saidOwnOnce = true
      try {
        io.said(`${mod} could not say a question it asked is its own (${msg(err)}), so until it can, one of its questions that names an issue and fails the reading limits is refused by picker manners rather than asked. Said once a session.`)
      } catch {
        // Nowhere left to say it; the question is still asked.
      }
    }
  }
  try {
    return await io.ask(question, options)
  } finally {
    // Taken back on every way out. One that cannot be leaves an entry that covers this dialog's
    // exact words only, for the rest of the session.
    if (isOwnSaid) await changeOwn(io.own, kept => withoutDialog(kept, dialog)).catch(() => undefined)
  }
}
