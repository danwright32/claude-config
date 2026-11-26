// The command line entry of the one check of text a person approves in a picker
// (claude-config#3321): askFault in payload/mods/mod-kit/hooks/shown.ts, for a caller that is not
// a mod and so cannot call it. Dan, 2026-11-21: "One check, called". lib/db-apply-approval.py runs
// this for the database apply approval and the test project approval, which are Python; the check
// itself, its limits and its character classes stay in mod-kit's file and are written nowhere else.
//
//   node --experimental-strip-types --no-warnings picker-check.mjs < {"asks": [<a picker's input>, ...]}
//
// Prints one JSON object, {"faults": [<one per picker, in the order sent>]}: null when Dan would
// read the picker as written, else {"what": ..., "fault": ...} as askFault words it. Each picker
// is an AskUserQuestion call's input, as the dialog got it.
//
// With "sizes": true beside the asks it also prints "sizes", one per picker in the order sent
// (claude-config#3583): {"rows", "units", "large", "maxRows", "maxUnits", "columns"}, the rows and
// UTF-16 code units of the question's own text as mod-kit counts them (rowsAt), mod-kit's limits,
// and whether the text is past either limit. A gate that must choose between a question showing
// every line and a shorter one asks this rather than counting rows itself (lib/lesson-merge.py).
// The counting and the limits stay mod-kit's: no number is written here.
//
// Exit codes, each distinct (L11): 0 judged, 2 the input could not be read (said on stderr, and
// nothing is printed, so a caller never takes an unreadable run for a pass). A caller that cannot
// run this at all, or reads no verdict for a picker, must not take that picker as read.
// Proved by payload/hooks/test-db-approval-picker-check.sh.
import { readFileSync } from 'node:fs'
import { askFault, rowsAt, MAX_QUESTION, MAX_QUESTION_ROWS, QUESTION_COLUMNS } from '../../mods/mod-kit/hooks/shown.ts'

const refuse = why => {
  process.stderr.write(`picker-check: ${why}\n`)
  process.exit(2)
}

let input
try {
  input = JSON.parse(readFileSync(0, 'utf8'))
} catch (err) {
  refuse(`its input is not JSON (${err instanceof Error ? err.message : String(err)})`)
}
const asks = typeof input === 'object' && input !== null && !Array.isArray(input) ? input.asks : undefined
if (!Array.isArray(asks)) refuse('its input is not an object holding a list named asks')
if (asks.some(a => typeof a !== 'object' || a === null || Array.isArray(a))) refuse("one of its asks is not a picker's input, which is an object")

const sizeOf = ask => {
  const first = Array.isArray(ask.questions) ? ask.questions[0] : undefined
  const text = typeof first === 'object' && first !== null && typeof first.question === 'string' ? first.question : ''
  const rows = rowsAt(text)
  return { rows, units: text.length, large: text.length > MAX_QUESTION || rows > MAX_QUESTION_ROWS, maxRows: MAX_QUESTION_ROWS, maxUnits: MAX_QUESTION, columns: QUESTION_COLUMNS }
}
const out = { faults: asks.map(a => askFault(a) ?? null) }
if (input.sizes === true) out.sizes = asks.map(sizeOf)
process.stdout.write(`${JSON.stringify(out)}\n`)
