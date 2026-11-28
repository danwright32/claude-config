// steps-phrase-count.ts: over this Mac's session records, how many turns the manual steps mod's
// end of turn check would hold for what claude-config#3842 added: each of its phrases, and a call
// the permission check refused with no step pinned after it. Judged by the mod's own code, never a
// copy beside it (L107): each record is read by the mod's own reader (the perl hooks/turn.ts runs
// at a turn's end, here over the whole record), each turn by its turnIn, which also says which
// calls were refused and whether the main conversation called the steps tool, and each phrase by
// hooks/waiting.ts's matcher.
//
//   node tools/steps-phrase-count.ts [--projects <folder>] [--days <n>] [--where]
//
// --projects is the folder Claude Code keeps session records in, one folder a project, each
// holding one .jsonl file a session (default ~/.claude/projects). --days counts the records last
// written in that many days (default 30). --where adds one line a counted turn: the record's file
// name and the number of the turn in it, and never a word of what was said, which is private
// (L155). It reads and prints, and writes no file. A folder under the home folder is printed from
// the tilde on, since the home folder's own path holds the Mac's user name.
//
// What is counted. A turn is the records of the main conversation under one prompt, in a session
// record of a project's own folder (a subagent's records are kept elsewhere and are not read). A
// turn kept in more than one record is counted once. For each phrase: the turns it is said in; of
// those, the turns no phrase the check already read is said in (the ones it newly brings to the
// check); and of those, the turns in which the main conversation made no call of the steps tool,
// which is the most it would newly hold. For a refused call: the turns holding one by the
// permission check, those a later call of the steps tool answers, those the one line answers, and
// the rest, left unanswered at the turn's end.
//
// What the count cannot see, said in the output too. For every figure: whether somebody was at
// the prompt (a run with nobody there is never held, and its turns are counted all the same);
// whether an unfinished step was already on a card Dan could see when a phrase was said; a turn of
// a long session older than the days asked for, when the record was written since; and whether
// what a turn left was a step for Dan, which only reading the turn says. So each phrase figure is
// the most it could be. The refused call figure is between two numbers, because a turn is judged
// once here, at its end, while the check judges at every turn end inside a turn (the end of turn
// reflection starts a turn again): a step pinned, or the one line said, only after a first turn
// end is counted as answered here, where the check would have held first. The low number is the
// turns left unanswered that the mod had not already held for another reason; the high one is
// every turn holding a refused call.
//
// The cross check. The refused call figures rest on one field of Claude Code's record,
// `toolDenialKind`, which nothing documents. Were a release to rename it or write it another way,
// the mod's reader would read no call as refused and these figures would read as a quiet month.
// So the last line counts refused calls a second way that does not use that field (L721): tool
// results of the main conversation that begin with the permission check's own "denied" sentence.
// It says how many there are and how many of them the mod's reader would not read as refused,
// which must be 0 of some. It also says the other direction, how many of the refused calls the
// reader did read have a result that does not begin with the sentence, so a change of the
// sentence is seen at once and not only when none is found at all, which the line says too.
//
// Exit codes, each distinct (L11): 0 counted, 2 bad arguments, 3 the folder could not be read,
// 4 perl could not be run.
import { spawnSync } from 'node:child_process'
import { readdirSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, normalize } from 'node:path'
import { turnIn, turnReadArgv } from '../payload/mods/manual-steps/hooks/turn.ts'
import { AFTER_REFUSAL, PHRASES, phraseIn, saysNoneNow, saysNothingFromRefusal } from '../payload/mods/manual-steps/hooks/waiting.ts'

/** The phrases the check read before #3842, which a new phrase adds nothing to when one is said. */
const EARLIER: readonly RegExp[] = PHRASES.filter(p => ![...AFTER_REFUSAL.values()].includes(p))

/** The reader's output for one record, cut into turns: a user record under another prompt begins one. */
export const turnsOf = (out: string): string[][] => {
  const turns: string[][] = []
  let now: string | null = null
  for (const line of out.split('\n')) {
    if (!line.trim()) continue
    const id = /^\{"type":"user"/.test(line) ? (/"promptId":"([^"]*)"/.exec(line)?.[1] ?? null) : null
    if (id !== null && id !== now) {
      now = id
      turns.push([])
    }
    turns.at(-1)?.push(line)
  }
  return turns
}

/** How far a phrase got in one turn: said; said where no earlier phrase was; and that with no steps tool call. */
type Reach = 'said' | 'fresh' | 'unpinned'
/** What one turn comes to. `refused`: none in it, answered by a later steps tool call, answered in words, or left to hold. */
export type Judged = { lines: number; at: string; refused: 'none' | 'pinned' | 'said' | 'held'; isOurs: boolean; phrases: Map<string, Reach> }

/** One turn, as the mod's reader printed it, judged as the end of turn check judges it; null when it names no prompt. */
export const judge = (lines: readonly string[], at: string): { id: string; judged: Judged } | null => {
  // Which calls were refused and whether a step was pinned are turnIn's own answers, never a test
  // written again here (review of pull request 3854: the copy this tool kept differed from it).
  const turn = turnIn(lines.join('\n'))
  if (turn.promptId === null) return null
  // The plain sentence saying none of the steps are Dan's now answers every ask of the check.
  const isAnswered = saysNoneNow(turn.texts)
  const refused = turn.refusedMet === 0 ? 'none' : turn.refused === 0 ? 'pinned' : isAnswered || saysNothingFromRefusal(turn.texts) ? 'said' : 'held'
  const phrases = new Map<string, Reach>()
  if (!isAnswered) {
    const isEarlier = turn.texts.some(t => phraseIn(t, EARLIER) !== null)
    for (const [name, rx] of AFTER_REFUSAL) {
      if (turn.texts.some(t => phraseIn(t, [rx]) !== null)) phrases.set(name, isEarlier ? 'said' : turn.isPinned ? 'fresh' : 'unpinned')
    }
  }
  return { id: turn.promptId, judged: { lines: lines.length, at, refused, isOurs: turn.isOurs, phrases } }
}

/**
 * Take in one session record, as the mod's reader printed it; answers how many of its turns were
 * already taken in from another record. Claude Code keeps one session's record under two project
 * folders when the session changed folder (2 of the 8 records holding a refused call on the
 * personal MacBook, 2026-11-27), so a turn met again is a copy, and the copy holding more of the
 * turn is the one kept.
 */
export const takeRecord = (seen: Map<string, Judged>, file: string, out: string): number => {
  let copies = 0
  turnsOf(out).forEach((lines, k) => {
    const j = judge(lines, `${file} turn ${k + 1}`)
    if (!j) return
    const was = seen.get(j.id)
    if (was) copies++
    if (!was || j.judged.lines > was.lines) seen.set(j.id, j.judged)
  })
  return copies
}

// ---- The cross check: refused calls found without the field the mod reads ----

/**
 * What the result of a call the permission check refused begins with. Measured on 2026-11-27 over
 * the personal MacBook's session records of 30 days: all 22 results of the kind the mod reads
 * began with it, and no tool result of the conversation held it under another kind.
 */
export const DENIED_SENTENCE = 'Permission for this action was denied by the Claude Code auto mode classifier'

// What perl runs for the cross check: every line of the record holding the sentence, whole. Its
// own program, sharing nothing with the mod's reader, whose blind spot it exists to see.
const DENIED_READ = ['my ($s, $f) = @ARGV;', 'open(my $h, "<", $f) or die "$f: $!\\n";', 'while (my $l = <$h>) { print $l if index($l, $s) >= 0; }', 'close($h) or die "$f: $!\\n";'].join('\n')

const beginsDenied = (content: unknown): boolean => {
  if (typeof content === 'string') return content.startsWith(DENIED_SENTENCE)
  if (!Array.isArray(content)) return false
  const first = content.find(b => b && typeof b === 'object' && (b as { type?: unknown }).type === 'text') as { text?: unknown } | undefined
  return typeof first?.text === 'string' && first.text.startsWith(DENIED_SENTENCE)
}

/**
 * Whether this line of a session record is a tool result of the main conversation that begins
 * with the sentence, and the record's own id when it has one. Parsed, so how the record spaces or
 * names its other keys does not matter; a result that only quotes the sentence further in, a
 * prompt of Dan's that begins with it and a subagent's result are not it.
 */
export const deniedResult = (line: string): { id: string | null } | null => {
  let r: { type?: unknown; isSidechain?: unknown; uuid?: unknown; message?: { content?: unknown } }
  try {
    r = JSON.parse(line) as typeof r
  } catch {
    return null
  }
  if (!r || typeof r !== 'object' || r.type !== 'user' || r.isSidechain === true) return null
  const c = r.message?.content
  if (!Array.isArray(c)) return null
  const isDenied = c.some(b => b && typeof b === 'object' && (b as { type?: unknown }).type === 'tool_result' && beginsDenied((b as { content?: unknown }).content))
  return isDenied ? { id: typeof r.uuid === 'string' ? r.uuid : null } : null
}

/** One such result: the record it was found in, and whether the mod's reader reads it as a refused call. */
export type Denied = { file: string; isRead: boolean }

/**
 * Take in the lines of one session record that hold the sentence, beside what the mod's reader
 * printed for the same record. A result is read as a refused call when the reader kept its line
 * whole and turnIn counts that line, which are the mod's own two steps and no test of this tool's.
 * A result met again under its record id, in the copy of a session kept under a second folder, is
 * taken once.
 */
export const takeDenied = (found: Map<string, Denied>, file: string, lines: string, readerOut: string): void => {
  const kept = new Set(readerOut.split('\n'))
  // A record too long to keep whole is printed cut down, under the record's own id (#3860).
  const cutDown = new Set([...kept].flatMap(line => (line.includes(CUT_DOWN) && turnIn(line).refusedMet === 1 ? [uuidOf(line)] : [])))
  lines.split('\n').forEach((line, n) => {
    if (!line.trim()) return
    const d = deniedResult(line)
    if (!d) return
    const key = d.id ?? `${file} line ${n}`
    if (!found.has(key)) found.set(key, { file, isRead: (kept.has(line) && turnIn(line).refusedMet === 1) || (d.id !== null && cutDown.has(d.id)) })
  })
}

/** How the mod's reader marks a refused call's record it cut down to its top level fields. */
const CUT_DOWN = '"isCutDown":true'
const uuidOf = (line: string): string | null => {
  try {
    const id = (JSON.parse(line) as { uuid?: unknown }).uuid
    return typeof id === 'string' ? id : null
  } catch {
    return null
  }
}

/**
 * The other direction, so the cross check cannot go blind unseen: each refused call the mod's
 * reader did read in this record (a line turnIn counts by itself), and whether its result begins
 * with the sentence. A release that words the refusal another way shows here at once, where the
 * first direction would only empty out as the older records age past the days counted.
 */
export const takeRead = (read: Map<string, boolean>, file: string, readerOut: string): void => {
  readerOut.split('\n').forEach((line, n) => {
    // A record the reader cut down no longer holds its result, so it cannot be checked here.
    if (!line.includes('toolDenialKind') || line.includes(CUT_DOWN) || turnIn(line).refusedMet !== 1) return
    let id: unknown
    try {
      id = (JSON.parse(line) as { uuid?: unknown }).uuid
    } catch {
      return
    }
    const key = typeof id === 'string' ? id : `${file} line ${n}`
    if (!read.has(key)) read.set(key, deniedResult(line) !== null)
  })
}

/** The cross check's line, from the results found by the sentence and the refused calls the reader read. */
export const crossCheck = (found: ReadonlyMap<string, Denied>, read: ReadonlyMap<string, boolean>): string => {
  const sentence = 'the permission check\'s "denied" sentence'
  if (found.size === 0)
    return `cross check: no tool result of the main conversation begins with ${sentence}, so this line checked nothing${read.size ? `, though the check read ${read.size} refused calls: the sentence has changed` : ''}.`
  const unread = [...found.values()].filter(d => !d.isRead).length
  const strangers = [...read.values()].filter(begins => !begins).length
  return (
    `cross check: ${found.size} tool results of the main conversation begin with ${sentence}; ${unread} of them the check would not read as a refused call${unread ? ', so the refused call figures above are too low' : ''}.` +
    ` Of the ${read.size} refused calls the check did read, ${strangers} have a result that does not begin with it${strangers ? ', so the sentence no longer covers every refusal and this line misses some' : ''}.`
  )
}

type PhraseRow = { said: number; fresh: number; unpinned: number; where: string[] }
export type Count = {
  turns: number
  phrases: Map<string, PhraseRow>
  /** Turns holding a call the permission check refused; answered by a later steps tool call; answered in words; left unanswered at the turn's end; of those, already held by this mod for another reason. */
  refused: { turns: number; pinned: number; said: number; held: number; alreadyHeld: number; where: string[] }
  /** Turns a new phrase would hold that a refused call would hold too. */
  both: number
}

/** The count over every turn taken in. */
export const countOf = (seen: ReadonlyMap<string, Judged>): Count => {
  const count: Count = {
    turns: seen.size,
    phrases: new Map([...AFTER_REFUSAL.keys()].map(name => [name, { said: 0, fresh: 0, unpinned: 0, where: [] }])),
    refused: { turns: 0, pinned: 0, said: 0, held: 0, alreadyHeld: 0, where: [] },
    both: 0,
  }
  for (const j of seen.values()) {
    if (j.refused !== 'none') {
      count.refused.turns++
      count.refused[j.refused]++
      if (j.refused === 'held') {
        if (j.isOurs) count.refused.alreadyHeld++
        count.refused.where.push(j.at)
      }
    }
    for (const [name, reach] of j.phrases) {
      const row = count.phrases.get(name) as PhraseRow
      row.said++
      if (reach === 'said') continue
      row.fresh++
      if (reach === 'fresh') continue
      row.unpinned++
      row.where.push(j.at)
    }
    if (j.refused === 'held' && [...j.phrases.values()].includes('unpinned')) count.both++
  }
  return count
}

/** `text` with the home folder's path, as given and as node tidies it, written as a tilde. */
export const fromTilde = (text: string, home: string = homedir()): string => {
  let out = text
  for (const h of new Set([home, normalize(home)])) {
    const bare = h.replace(/\/+$/, '')
    if (bare) out = out.split(bare).join('~')
  }
  return out
}

const main = (): number => {
  const args = process.argv.slice(2)
  let projects = join(homedir(), '.claude', 'projects')
  let days = 30
  let where = false
  const usage = 'Usage: node tools/steps-phrase-count.ts [--projects <folder>] [--days <n>] [--where]'
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--where') where = true
    else if (args[i] === '--projects' && args[i + 1] !== undefined) projects = args[++i] as string
    else if (args[i] === '--days' && /^[1-9]\d{0,3}$/.test(args[i + 1] ?? '')) days = Number(args[++i])
    else {
      console.error(`steps-phrase-count: "${args[i]}" is not understood. ${usage}`)
      return 2
    }
  }
  const since = Date.now() - days * 86_400_000
  const seen = new Map<string, Judged>()
  const denied = new Map<string, Denied>()
  const read = new Map<string, boolean>()
  let files = 0
  let unread = 0
  let copies = 0
  try {
    for (const project of readdirSync(projects).sort()) {
      const dir = join(projects, project)
      if (!statSync(dir).isDirectory()) continue
      for (const name of readdirSync(dir).sort()) {
        if (!name.endsWith('.jsonl')) continue
        const path = join(dir, name)
        const stat = statSync(path)
        if (stat.mtimeMs < since) continue
        // The mod's own reader, over the whole record: one byte more than it holds.
        const [cmd, ...argv] = turnReadArgv(path, stat.size + 1)
        const r = spawnSync(cmd as string, argv, { encoding: 'utf8', maxBuffer: 2 ** 31 - 1 })
        if (r.error && (r.error as { code?: string }).code === 'ENOENT') {
          console.error('steps-phrase-count: perl could not be run, so no session record was read.')
          return 4
        }
        // The cross check's own read of the same record. A record only one of the two could read
        // is counted as not read, so the two are never compared over different records.
        const d = r.error || r.status !== 0 ? null : spawnSync('perl', ['-e', DENIED_READ, '--', DENIED_SENTENCE, path], { encoding: 'utf8', maxBuffer: 2 ** 31 - 1 })
        if (!d || d.error || d.status !== 0) {
          unread++
          continue
        }
        files++
        copies += takeRecord(seen, name, r.stdout)
        takeDenied(denied, name, d.stdout, r.stdout)
        takeRead(read, name, r.stdout)
      }
    }
  } catch (err) {
    console.error(fromTilde(`steps-phrase-count: ${projects} could not be read (${err instanceof Error ? err.message : String(err)}), so nothing was counted.`))
    return 3
  }
  const count = countOf(seen)
  console.log(`steps-phrase-count: ${files} session records last written in ${days} days read in ${fromTilde(projects)}${unread ? `, ${unread} more could not be read` : ''}; ${count.turns} turns of the main conversation, ${copies} more kept in a second record and counted once.`)
  console.log(
    'Each phrase figure is the most it could be, and the refused call figure is between two numbers: a turn is judged once here, at its end, while the check judges at every turn end inside it, so a step pinned or the one line said only after a first turn end counts as answered here though the check would have held first. A run with nobody at the prompt is never held and is counted all the same, and the card as it stood is not in the record.',
  )
  console.log('Each phrase: turns it is said in; of those, turns no earlier phrase is said in; of those, turns in which the main conversation made no call of the steps tool (the most it would newly hold).')
  for (const [name, row] of count.phrases) {
    console.log(`phrase "${name}": said in ${row.said}; newly read in ${row.fresh}; would newly hold at most ${row.unpinned}.`)
    if (where) for (const w of row.where) console.log(`  ${w}`)
  }
  const f = count.refused
  console.log(
    `a call the permission check refused: in ${f.turns} turns; answered by a steps tool call after it in ${f.pinned}; answered in words in ${f.said}; left unanswered at the turn's end in ${f.held}, of which ${f.alreadyHeld} the check had already held for another reason and ${count.both} a new phrase would hold too; would be held once each: between ${f.held - f.alreadyHeld} and ${f.turns}.`,
  )
  if (where) for (const w of f.where) console.log(`  ${w}`)
  console.log('Whether what a counted turn left was a step for Dan is not in the count: only reading the turn says.')
  console.log(crossCheck(denied, read))
  if (where) for (const file of new Set([...denied.values()].filter(d => !d.isRead).map(d => d.file))) console.log(`  ${file}`)
  return 0
}

if (process.argv[1] !== undefined && import.meta.url.endsWith(process.argv[1].replace(/^.*\//, ''))) process.exit(main())
