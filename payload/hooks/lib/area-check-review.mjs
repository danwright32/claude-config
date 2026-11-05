// The area check's part of the issue review (claude-config#1511): the weekly line, and a note for
// each file of this repository that sessions keep proceeding past. Run by feature-issue-review.sh
// once its cooldown has passed, before the spool is read, so a note made here shows in that review.
//
//   node --experimental-strip-types --no-warnings area-check-review.mjs <area dir> <project> <transcript> <spool lib>
//
// Prints one JSON object: {"now": <ms>, "line": <the weekly line, or null when not due>, "said":
// [<sentences about what could not be done>]}. The review writes `now` into the stamp only once
// the reason carrying the line was delivered. The clock is CLAUDE_AREA_CHECK_NOW (ms) when set, so
// tests never wait (L524); one that is not a number refuses rather than reading the real time.
// What is counted and what escalates is decided by payload/mods/area-check/hooks/weekly.ts; this
// only reads files and writes claims. Proved by tests/test-area-check-weekly.sh.
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { githubRepo } from '../../mods/mod-kit/hooks/repo.ts'
import {
  ESCALATED,
  ESCALATE_WINDOW_MS,
  LINE_EVERY_MS,
  STAMP,
  claimStale,
  escalationKey,
  escalationNote,
  escalations,
  lineDue,
  parseLines,
  weeklyLine,
  windowFiles,
} from '../../mods/area-check/hooks/weekly.ts'

const [dir, proj, transcript, spoolLib] = process.argv.slice(2)
if (!dir || !proj || !spoolLib) {
  process.stderr.write('area-check-review: needs <area dir> <project> <transcript> <spool lib>\n')
  process.exit(2)
}
const given = process.env.CLAUDE_AREA_CHECK_NOW
const now = given === undefined || given === '' ? Date.now() : Number(given)
if (!Number.isFinite(now)) {
  process.stderr.write(`area-check-review: CLAUDE_AREA_CHECK_NOW is not a time in milliseconds: ${given}\n`)
  process.exit(2)
}

const codeOf = e => (e && typeof e === 'object' && 'code' in e && e.code ? String(e.code) : 'unknown error')
const textOr = (file, missing) => {
  try {
    return readFileSync(file, 'utf8')
  } catch (e) {
    if (codeOf(e) === 'ENOENT') return missing
    throw e
  }
}

let stamp = null
try {
  stamp = textOr(`${dir}/${STAMP}`, null)
} catch {
  stamp = null // an unreadable stamp makes the line due: one extra line, never silence
}
const due = lineDue(stamp, now)

// The repository this review files into: only its own files are ever escalated here.
const remote = spawnSync('git', ['-C', proj, 'remote', 'get-url', 'origin'], { encoding: 'utf8' })
const repo = remote.status === 0 ? githubRepo(remote.stdout.trim()) : null

const said = []
if (!due && !repo) {
  process.stdout.write(`${JSON.stringify({ now, line: null, said })}\n`)
  process.exit(0)
}

// The log and the rotated files the window needs. A rotation or a settle can rename a file between
// the listing and its read, so a file gone mid read makes the listing again, at most twice more.
const since = now - Math.max(due ? LINE_EVERY_MS : 0, repo ? ESCALATE_WINDOW_MS : 0)
const readLog = () => {
  for (let attempt = 0; attempt < 3; attempt++) {
    let names
    try {
      names = readdirSync(`${dir}/rotated`)
    } catch (e) {
      if (codeOf(e) !== 'ENOENT') return { state: 'unreadable', code: codeOf(e) }
      names = []
    }
    const texts = []
    let log
    try {
      log = textOr(`${dir}/log.jsonl`, null)
    } catch (e) {
      return { state: 'unreadable', code: codeOf(e) }
    }
    if (log === null && names.length === 0) return { state: 'missing' }
    if (log !== null) texts.push(log)
    let moved = false
    for (const name of windowFiles(names, since)) {
      try {
        texts.push(readFileSync(`${dir}/rotated/${name}`, 'utf8'))
      } catch (e) {
        if (codeOf(e) !== 'ENOENT') return { state: 'unreadable', code: codeOf(e) }
        moved = true
        break
      }
    }
    if (!moved) return { state: 'read', texts }
  }
  return { state: 'unreadable', code: 'its rotated files kept moving while being read' }
}
const log = readLog()

let line = null
if (due) {
  let errors
  try {
    const t = textOr(`${dir}/errors.jsonl`, null)
    errors = t === null ? { state: 'missing' } : { state: 'read', texts: [t] }
  } catch (e) {
    errors = { state: 'unreadable', code: codeOf(e) }
  }
  line = weeklyLine(log, errors, now)
}

// One claim file per escalated file, created exclusively, so two reviews at once make one note. A
// claim thirty days old is renamed aside first, and only one rename of it can win.
const claim = path => {
  try {
    writeFileSync(path, JSON.stringify({ at: now }), { flag: 'wx' })
    return true
  } catch (e) {
    if (codeOf(e) !== 'EEXIST') throw e
  }
  if (!claimStale(textOr(path, '{}'), now)) return false
  const aside = `${path}.stale.${process.pid}`
  try {
    renameSync(path, aside)
  } catch (e) {
    if (codeOf(e) === 'ENOENT') return false
    throw e
  }
  unlinkSync(aside)
  try {
    writeFileSync(path, JSON.stringify({ at: now }), { flag: 'wx' })
    return true
  } catch (e) {
    if (codeOf(e) === 'EEXIST') return false
    throw e
  }
}

// When the line is due it already says the log could not be read; otherwise this is the only place.
if (repo && !due && log.state === 'unreadable') {
  said.push(`The area check could not look for files sessions keep proceeding past: its log could not be read (${log.code}).`)
}
if (repo && log.state === 'read') {
  const found = escalations(parseLines(log.texts).records, repo, now)
  let failed = 0
  let why = ''
  for (const e of found) {
    const path = `${dir}/${ESCALATED}/${createHash('sha1').update(escalationKey(e)).digest('hex')}`
    try {
      mkdirSync(`${dir}/${ESCALATED}`, { recursive: true })
      if (!claim(path)) continue
    } catch (err) {
      failed++
      why = `its claim could not be written, ${codeOf(err)}`
      continue
    }
    const r = spawnSync('bash', [spoolLib, 'note', proj, escalationNote(e), 'area check', transcript ?? ''], { encoding: 'utf8' })
    if (r.status !== 0) {
      try {
        unlinkSync(path)
      } catch {}
      failed++
      why = r.error ? `the spool could not be run, ${codeOf(r.error)}` : `the spool note exited ${r.status}`
    }
  }
  if (failed > 0) {
    said.push(`The area check could not record ${failed === 1 ? '1 escalation note' : `${failed} escalation notes`} for this repository's review (${why}), so it tries again at the next review.`)
  }
}

process.stdout.write(`${JSON.stringify({ now, line, said })}\n`)
