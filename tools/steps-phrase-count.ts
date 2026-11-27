// steps-phrase-count.ts: over this Mac's session records, how many turns the manual steps mod's
// end of turn check would hold for what claude-config#3842 added: each of its phrases, and a call
// the permission check refused with no step pinned after it. Judged by the mod's own code, never a
// copy beside it (L107): each record is read by the mod's own reader (the perl hooks/turn.ts runs
// at a turn's end, here over the whole record), each turn by its turnIn, and each phrase by
// hooks/waiting.ts's matcher.
//
//   node tools/steps-phrase-count.ts [--projects <folder>] [--days <n>] [--where]
//
// --projects is the folder Claude Code keeps session records in, one folder a project, each
// holding one .jsonl file a session (default ~/.claude/projects). --days counts the records last
// written in that many days (default 30). --where adds one line a counted turn: the record's file
// name and the number of the turn in it, and never a word of what was said, which is private
// (L155). It reads and prints, and writes no file.
//
// What is counted. A turn is the records of the main conversation under one prompt, in a session
// record of a project's own folder (a subagent's records are kept elsewhere and are not read). A
// turn kept in more than one record is counted once. For each phrase: the turns it is said in; of
// those, the turns no phrase the check already read is said in (the ones it newly brings to the
// check); and of those, the turns holding no call of the steps tool, which is the most it would
// newly hold. For a refused call: the turns holding one by the permission check, those a later
// call of the steps tool answers, and the rest, which the check would hold once each.
//
// What the count cannot see, said in the output too: whether somebody was at the prompt (a run
// with nobody there is never held, and its turns are counted all the same); whether an unfinished
// step was already on a card Dan could see when a phrase was said; a turn of a long session older
// than the days asked for, when the record was written since; and whether what a turn left was a
// step for Dan, which only reading the turn says. So every figure is the most it could be.
//
// Exit codes, each distinct (L11): 0 counted, 2 bad arguments, 3 the folder could not be read,
// 4 perl could not be run.
import { spawnSync } from 'node:child_process'
import { readdirSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { REFUSED_KIND, STEPS_TOOL, turnIn, turnReadArgv } from '../payload/mods/manual-steps/hooks/turn.ts'
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
  const turn = turnIn(lines.join('\n'))
  if (turn.promptId === null) return null
  // A call the permission check refused, as the reader keeps it: the record whole, read as turnIn reads it.
  const refusals = lines.filter(l => {
    try {
      const r = JSON.parse(l) as { type?: unknown; toolDenialKind?: unknown; isSidechain?: unknown }
      return r.type === 'user' && r.toolDenialKind === REFUSED_KIND && r.isSidechain !== true
    } catch {
      return false
    }
  }).length
  // The plain sentence saying none of the steps are Dan's now answers every ask of the check.
  const isAnswered = saysNoneNow(turn.texts)
  const refused = refusals === 0 ? 'none' : turn.refused === 0 ? 'pinned' : isAnswered || saysNothingFromRefusal(turn.texts) ? 'said' : 'held'
  const phrases = new Map<string, Reach>()
  if (!isAnswered) {
    const isEarlier = turn.texts.some(t => phraseIn(t, EARLIER) !== null)
    const isPinned = lines.some(l => l.includes('"isPinning":true') || l.includes(`"name":"${STEPS_TOOL}"`))
    for (const [name, rx] of AFTER_REFUSAL) {
      if (turn.texts.some(t => phraseIn(t, [rx]) !== null)) phrases.set(name, isEarlier ? 'said' : isPinned ? 'fresh' : 'unpinned')
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

type PhraseRow = { said: number; fresh: number; unpinned: number; where: string[] }
export type Count = {
  turns: number
  phrases: Map<string, PhraseRow>
  /** Turns holding a call the permission check refused; answered by a later steps tool call; answered in words; left to hold; of those, already held by this mod for another reason. */
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
        if (r.error || r.status !== 0) {
          unread++
          continue
        }
        files++
        copies += takeRecord(seen, name, r.stdout)
      }
    }
  } catch (err) {
    console.error(`steps-phrase-count: ${projects} could not be read (${err instanceof Error ? err.message : String(err)}), so nothing was counted.`)
    return 3
  }
  const count = countOf(seen)
  console.log(`steps-phrase-count: ${files} session records last written in ${days} days read in ${projects}${unread ? `, ${unread} more could not be read` : ''}; ${count.turns} turns of the main conversation, ${copies} more kept in a second record and counted once.`)
  console.log('Every figure is the most it could be: a run with nobody at the prompt is never held and is counted all the same, and the card as it stood is not in the record.')
  console.log('Each phrase: turns it is said in; of those, turns no earlier phrase is said in; of those, turns with no call of the steps tool (the most it would newly hold).')
  for (const [name, row] of count.phrases) {
    console.log(`phrase "${name}": said in ${row.said}; newly read in ${row.fresh}; would newly hold at most ${row.unpinned}.`)
    if (where) for (const w of row.where) console.log(`  ${w}`)
  }
  const f = count.refused
  console.log(`a call the permission check refused: in ${f.turns} turns; answered by a steps tool call after it in ${f.pinned}; answered in words in ${f.said}; would be held once each: ${f.held}, of which ${f.alreadyHeld} the check had already held for another reason and ${count.both} a new phrase would hold too.`)
  if (where) for (const w of f.where) console.log(`  ${w}`)
  console.log('Whether what a counted turn left was a step for Dan is not in the count: only reading the turn says.')
  return 0
}

if (process.argv[1] !== undefined && import.meta.url.endsWith(process.argv[1].replace(/^.*\//, ''))) process.exit(main())
