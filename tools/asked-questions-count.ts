// asked-questions-count.ts: what the records of questions mods ask Dan through their own dialog
// say, per mod and question (claude-config#3321; Dan, 2026-11-21: "Record, then decide"). Each
// record is written by payload/mods/mod-kit/hooks/asked.ts as the question is asked, and holds
// sizes and names only, never a word of the question. This reads them for the decision the issue
// left for two weeks on: whether those questions should be held to the shared check of text a
// person approves in a picker (shown.ts), as a session's pickers are.
//
//   node tools/asked-questions-count.ts [--dir <folder>] [--since <YYYY-MM-DD>]
//
// --dir is the folder of records (default the one asked.ts writes, ~/.claude/state/asked-questions,
// on this Mac only). --since counts only what was asked on or after that day (UTC).
//
// Printed: how many were recorded and over which days, how many records could not be read; then
// one line a mod's question, in the order of mod and question, with how many were asked, the
// longest and the 95th percentile (nearest rank) of its length in UTF-16 units and of the rows it
// takes, and how many the check would refuse; then the whole.
//
// Exit codes, each distinct (L11): 0 read (a folder not made yet is no question asked, and says
// so), 2 bad arguments, 3 the folder could not be read.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { askedDir, type Asked } from '../payload/mods/mod-kit/hooks/asked.ts'

const RECORD = /^\d{13}-[a-z0-9]+\.json$/
const DAY = /^\d{4}-\d{2}-\d{2}$/

type Sizes = Pick<Asked, 'at' | 'mod' | 'which' | 'units' | 'rows' | 'refused'>

/** One record's sizes, or undefined when any field is not what asked.ts writes (L50). */
export const sizesOf = (text: string): Sizes | undefined => {
  let v: unknown
  try {
    v = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof v !== 'object' || v === null) return undefined
  const r = v as Record<string, unknown>
  const whole = (n: unknown): n is number => typeof n === 'number' && Number.isInteger(n) && n >= 0
  // A moment past the last one a Date can hold would make the day it is printed as throw.
  if (!whole(r.at) || r.at > 8.64e15 || !whole(r.units) || !whole(r.rows)) return undefined
  if (typeof r.mod !== 'string' || !r.mod || typeof r.which !== 'string' || !r.which || typeof r.refused !== 'boolean') return undefined
  return { at: r.at, mod: r.mod, which: r.which, units: r.units, rows: r.rows, refused: r.refused }
}

/** The 95th percentile by nearest rank, of a list holding at least one number. */
export const p95 = (values: readonly number[]): number => {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.max(0, Math.ceil(0.95 * sorted.length) - 1)]
}

const dayOf = (ms: number): string => new Date(ms).toISOString().slice(0, 10)

/** The lines printed for the records given. */
export const summary = (records: readonly Sizes[], unreadable: number): string[] => {
  const lines: string[] = []
  const skipped = unreadable ? ` (${unreadable} record${unreadable === 1 ? '' : 's'} could not be read and ${unreadable === 1 ? 'is' : 'are'} left out)` : ''
  if (!records.length) return [`0 questions recorded${skipped}.`]
  const ats = records.map(r => r.at)
  lines.push(`${records.length} question${records.length === 1 ? '' : 's'} recorded from ${dayOf(Math.min(...ats))} to ${dayOf(Math.max(...ats))}${skipped}.`)
  const groups = new Map<string, Sizes[]>()
  for (const r of records) {
    const key = `${r.mod} ${r.which}`
    groups.set(key, [...(groups.get(key) ?? []), r])
  }
  for (const key of [...groups.keys()].sort()) {
    const g = groups.get(key) as Sizes[]
    const units = g.map(r => r.units)
    const rows = g.map(r => r.rows)
    lines.push(`${key}: ${g.length} asked; units longest ${Math.max(...units)}, 95th percentile ${p95(units)}; rows longest ${Math.max(...rows)}, 95th percentile ${p95(rows)}; the check would refuse ${g.filter(r => r.refused).length}.`)
  }
  lines.push(`In all: ${records.length} asked, the check would refuse ${records.filter(r => r.refused).length}.`)
  return lines
}

const main = (): number => {
  const args = process.argv.slice(2)
  let dir = askedDir(process.env.HOME || homedir())
  let since: number | undefined
  for (let i = 0; i < args.length; i++) {
    const a = args[i]
    if (a === '--dir' && args[i + 1] !== undefined) dir = args[++i]
    else if (a === '--since' && args[i + 1] !== undefined) {
      const day = args[++i]
      const ms = DAY.test(day) ? Date.parse(`${day}T00:00:00Z`) : Number.NaN
      if (Number.isNaN(ms)) {
        console.error(`--since takes a day written as YYYY-MM-DD, not "${day}". Nothing was counted.`)
        return 2
      }
      since = ms
    } else {
      console.error(`"${a}" is not understood. Use --dir <folder> and --since <YYYY-MM-DD>. Nothing was counted.`)
      return 2
    }
  }
  let names: string[]
  try {
    if (!statSync(dir, { throwIfNoEntry: false })) {
      console.log(`No question has been recorded on this Mac: ${dir} is not there.`)
      return 0
    }
    names = readdirSync(dir)
  } catch (err) {
    console.error(`${dir} could not be read (${err instanceof Error ? err.message : String(err)}), so nothing was counted.`)
    return 3
  }
  const records: Sizes[] = []
  let unreadable = 0
  for (const name of names.filter(n => RECORD.test(n)).sort()) {
    let text: string
    try {
      text = readFileSync(join(dir, name), 'utf8')
    } catch {
      unreadable++
      continue
    }
    const r = sizesOf(text)
    if (!r) unreadable++
    else if (since === undefined || r.at >= since) records.push(r)
  }
  for (const line of summary(records, unreadable)) console.log(line)
  return 0
}

if (process.argv[1] !== undefined && import.meta.url.endsWith(process.argv[1].replace(/^.*\//, ''))) process.exit(main())
