// The command line entry of sleep mode's judgement of a merge past an approving review
// (claude-config#3534), for a caller that is not a mod and so cannot call it. Dan, 2026-11-24:
// "Respect sleep mode first". lib/merge-when-ready.sh runs this before the one bypass merge it
// sends itself, which no hook sees. Whether this Mac is asleep is the scope modes mod's readSleep
// (mods/scope-modes/hooks/sleep.ts), and whether tonight's lists allow an admin merge in a
// repository is its adminMergeNightRefusal (adminmerge.ts), the first thing its own judge of a
// typed `gh pr merge --admin` asks. Both stay in the mod's files and are written nowhere else; this
// only reads the record as the mod's sleepNow reads it (no file is no sleep, one that went between
// the look and the read is no sleep, any other failure to read is unreadable) and hands it over.
//
//   node --experimental-strip-types --no-warnings sleep-admin-merge.mjs \
//     <the sleep record> <owner/name> <now, ms since the epoch> \
//     <what `sysctl -n kern.boottime` printed> <what `sysctl -n kern.bootsessionuuid` printed>
//
// The last two may be empty (a machine with no such sysctl): with neither known, only the record's
// end decides, as readSleep says. Prints one JSON object:
//   {"verdict": "awake", "why": "none" | "expired" | "other-boot"}   sleep mode is off
//   {"verdict": "allowed"}                         asleep, and the lists allow an admin merge there
//   {"verdict": "refused", "why": <the mod's words>}       asleep, and they do not
//   {"verdict": "unreadable", "why": <the mod's words>}    the record cannot be read
//
// Exit codes, each distinct (L11): 0 judged, 2 its arguments could not be read (said on stderr,
// nothing printed). A caller that cannot run this, or reads none of the four verdicts, must not
// take that as sleep mode being off or as permission. Proved by section 34 of
// payload/hooks/test-merge-when-ready.sh.
import { existsSync, readFileSync } from 'node:fs'
import { adminMergeNightRefusal } from '../../mods/scope-modes/hooks/adminmerge.ts'
import { bootOf, bootSessionOf, readSleep } from '../../mods/scope-modes/hooks/sleep.ts'

const refuse = why => {
  process.stderr.write(`sleep-admin-merge: ${why}\n`)
  process.exit(2)
}
const say = answer => {
  process.stdout.write(`${JSON.stringify(answer)}\n`)
  process.exit(0)
}

const [record, repo, nowText, bootText = '', sessionText = ''] = process.argv.slice(2)
if (!record || !repo || nowText === undefined) refuse('it takes the sleep record, the repository and now in ms, then what sysctl printed for this boot')
if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) refuse(`the repository is not owner/name: ${repo}`)
if (!/^\d+$/.test(nowText)) refuse(`now is not a whole number of ms: ${nowText}`)

let text = null
if (existsSync(record)) {
  try {
    text = readFileSync(record, 'utf8')
  } catch (err) {
    // Moved aside between the look and the read (a wake elsewhere) is no record, not a broken one.
    if (existsSync(record)) say({ verdict: 'unreadable', why: `the sleep record could not be read (${err instanceof Error ? err.message : String(err)})` })
  }
}

const reading = readSleep(text, Number(nowText), { session: bootSessionOf(sessionText), time: bootOf(bootText) })
if (reading.state === 'unreadable') say({ verdict: 'unreadable', why: reading.why })
if (reading.state !== 'asleep') say({ verdict: 'awake', why: reading.state })
const no = adminMergeNightRefusal(reading.record.repos, repo)
say(no === undefined ? { verdict: 'allowed' } : { verdict: 'refused', why: no })
