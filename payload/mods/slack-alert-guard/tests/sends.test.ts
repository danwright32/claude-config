import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { stringsOf } from '../hooks/rules.ts'
import { importedNames, jsSpans, mayBringIn, pySpans, readingOf, sentAt, trace, type Reading } from '../hooks/sends.ts'
import { pythonText } from './mod-kit/hooks/code.ts'

// Which strings reach a Slack send (claude-config#2570): only those are Slack wording. Each case
// names a string sent and one that is not, in the same file, so a reading that sends everything,
// or nothing, fails.

const js = (text: string): Reading => readingOf(text, false, jsSpans(text))
const py = (text: string): Reading => readingOf(text, true, pySpans(pythonText(text)))
// Each string of a file, and the callee of the send it reaches ('' for none).
const reached = (r: Reading, seeds?: Map<string, { callee: string; line: number }>, fns?: Set<string>): Record<string, string> => {
  const t = trace(r, seeds, fns)
  const strings = r.python ? pythonText(r.text).filter(s => s.kind !== 'comment').map(s => ({ text: r.text.slice(s.from, s.to), start: s.from })) : stringsOf(r.text, false, true)
  return Object.fromEntries(strings.map(s => [s.text, sentAt(t, s.start)?.callee ?? '']))
}
// Two markers the fixtures share, built once. Other fixtures write markers whole, which is safe here:
// a test file is never read as a sender or held.
const WEBHOOK = ['process.env.SLACK', 'WEBHOOK_URL'].join('_')
const CHAT = ['chat', 'postMessage'].join('.')

test("a route that posts to Slack and answers 409: the Slack text is sent, the answer and the log line are not", async () => {
  const r = js(
    [
      `export async function POST(req: Request) {`,
      `  const body = await req.json()`,
      `  if (body.taken) {`,
      `    console.log('Slot already taken, refusing')`,
      `    return Response.json({ error: 'That slot is already booked' }, { status: 409 })`,
      `  }`,
      `  const text = \`Booking \${body.id} was made by \${body.who}\``,
      `  await fetch(${WEBHOOK}, { method: 'POST', body: JSON.stringify({ text }) })`,
      `  return Response.json({ ok: true })`,
      `}`,
    ].join('\n'),
  )
  const got = reached(r)
  expect(got['Booking ${body.id} was made by ${body.who}']).toBe('fetch')
  expect(got['That slot is already booked']).toBe('')
  expect(got['Slot already taken, refusing']).toBe('')
})

test('a web client built from the bot token sends what its post call carries, through a helper that builds the lines', async () => {
  const r = js(
    [
      `const slack = new WebClient(process.env.SLACK_BOT_TOKEN)`,
      `const linesFor = (n: number) => {`,
      `  const lines = ['Nightly digest']`,
      `  lines.push(\`\${n} bookings are late\`)`,
      `  return lines.join('\\n')`,
      `}`,
      `export const run = async (n: number) => {`,
      `  if (n < 0) throw new Error('A count below zero cannot be reported')`,
      `  await slack.${CHAT}({ channel: 'C1', text: linesFor(n) })`,
      `}`,
    ].join('\n'),
  )
  const got = reached(r)
  expect(got['Nightly digest']).toBe(`slack.${CHAT}`)
  expect(got['${n} bookings are late']).toBe(`slack.${CHAT}`)
  expect(got['A count below zero cannot be reported']).toBe('')
})

test('a local send helper is a send wherever it is called, and two locals of one name in different functions are told apart', async () => {
  const r = js(
    [
      `async function notify(text: string) { await fetch(${WEBHOOK}, { method: 'POST', body: JSON.stringify({ text }) }) }`,
      `export const a = async () => { const message = 'Deploy failed on production'; await notify(message) }`,
      `export const b = () => { const message = 'Request was not valid'; return new Response(message, { status: 400 }) }`,
    ].join('\n'),
  )
  const got = reached(r)
  expect(got['Deploy failed on production']).toBe('notify')
  expect(got['Request was not valid']).toBe('')
})

test('a file below a sender is followed by the names the sender sends: the sent constant reaches, its neighbour does not', async () => {
  const sender = js(`import { lateBooking, NOT_FOUND } from './copy'\nexport const run = () => sendSlackAlert(lateBooking('1'))\nexport const miss = () => new Response(NOT_FOUND)\n`)
  const up = trace(sender)
  expect(up.sends.map(s => s.callee)).toEqual(['sendSlackAlert'])
  const copy = js("export const lateBooking = (id: string) => `Booking ${id} is late`\nexport const NOT_FOUND = 'No booking has that id'\n")
  const got = reached(copy, up.names)
  expect(got['Booking ${id} is late']).toBe('sendSlackAlert')
  expect(got['No booking has that id']).toBe('')
})

test('a renamed import is followed by the name the file below gives it', async () => {
  const sender = js(`import { lateBooking as late } from './copy'\nexport const run = () => sendSlackAlert(late('1'))\n`)
  expect(reached(js("export const lateBooking = (id: string) => `Booking ${id} is late`\n"), trace(sender).names)['Booking ${id} is late']).toBe('sendSlackAlert')
})

test('calls to send functions imported from a helper module are sends', async () => {
  const helper = js(`export const postAlert = (text: string) => fetch(${WEBHOOK}, { method: 'POST', body: JSON.stringify({ text }) })\n`)
  expect([...trace(helper).fns]).toContain('postAlert')
  const user = js("import { postAlert } from './post'\nexport const GET = async () => { console.log('cron started'); await postAlert('The nightly job is late') }\n")
  const got = reached(user, new Map(), trace(helper).fns)
  expect(got['The nightly job is late']).toBe('postAlert')
  expect(got['cron started']).toBe('')
})

test('python: the text a webhook post carries is sent; a printed report line, an error and a docstring are not', async () => {
  const r = py(
    [
      `import os, requests`,
      `URL = os.environ["SLACK_WEBHOOK_URL"]`,
      ``,
      `def report(rows):`,
      `    """Print the rows and post the late ones."""`,
      `    print(f"{len(rows)} rows read")`,
      `    if not rows:`,
      `        raise ValueError("No rows came back from the warehouse")`,
      `    text = f"{len(rows)} bookings are late"`,
      `    requests.post(URL, json={"text": text})`,
    ].join('\n'),
  )
  const got = reached(r)
  expect(got['{len(rows)} bookings are late']).toBe('requests.post')
  expect(got['{len(rows)} rows read']).toBe('')
  expect(got['No rows came back from the warehouse']).toBe('')
  expect(got['Print the rows and post the late ones.']).toBe('')
})

test('a marker in a route handler a framework call wraps does not make the whole handler a send', async () => {
  const r = js(
    [
      `app.post('/book', async (req, res) => {`,
      `  const url = ${WEBHOOK}`,
      `  if (req.body.taken) return res.status(409).json({ error: 'That slot is already booked' })`,
      `  await fetch(url, { method: 'POST', body: JSON.stringify({ text: 'A slot was booked' }) })`,
      `})`,
    ].join('\n'),
  )
  const got = reached(r)
  expect(got['A slot was booked']).toBe('fetch')
  expect(got['That slot is already booked']).toBe('')
})

// claude-config#2637: which edits could bring another file's text to a send, told from the edited
// file alone. Each case pairs an edit that could with one beside it that could not, so a reading
// that always looks, or never does, fails.
const ROUTE = [`import { lateBooking, NOT_FOUND } from './booking-copy'`, `import { postAlert } from '@/lib/notify/post'`, `export const run = (id: string) => postAlert(lateBooking(id))`, `export const miss = () => new Response(NOT_FOUND, { status: 404 })`, ``].join('\n')

test('the names a file imports or hands on are read from its import, re-export and require statements, and python import lines (#2637)', () => {
  const names = importedNames(js(`import dflt, { a, b as c, type T } from './x'\nimport * as ns from './y'\nexport { d as e } from './z'\nconst { f, g } = require('./w')\nconst h = await import('./v')\nimport React, { useState } from 'react'\nconst fs = require('fs')\nconst late = require(pick())\nexport const local = 1\n`))
  for (const n of ['dflt', 'a', 'b', 'c', 'T', 'ns', 'd', 'e', 'f', 'g', 'h', 'late']) expect(names.has(n)).toBe(true)
  for (const n of ['local', 'React', 'useState', 'fs', 'import', 'from', 'as', 'type', 'export', 'require']) expect(names.has(n)).toBe(false)
  const python = importedNames(py('from app.copy import (\n    late_booking,\n    not_found as missing,\n)\nimport app.alerts.sender as sender\nLOCAL = 1\n'))
  for (const n of ['late_booking', 'not_found', 'missing', 'sender']) expect(python.has(n)).toBe(true)
  expect(python.has('LOCAL')).toBe(false)
})

test('an edit could bring text to a send when it imports a new module or name, or uses an imported name more; rewording a string, a comment or other code could not (#2637)', () => {
  const was = js(ROUTE)
  const could = (text: string) => mayBringIn(was, js(text))
  // A new module, the same file name in another folder, a new name from a module already imported, and one more use.
  expect(could(`import { quietPage } from './quiet-feed-copy'\n${ROUTE}`)).toBe(true)
  expect(could(ROUTE.replace(`'./booking-copy'`, `'../other/booking-copy'`))).toBe(true)
  expect(could(ROUTE.replace('lateBooking, NOT_FOUND', 'lateBooking, NOT_FOUND, earlyBooking'))).toBe(true)
  expect(could(ROUTE.replace('postAlert(lateBooking(id))', 'postAlert(id ? lateBooking(id) : NOT_FOUND)'))).toBe(true)
  expect(mayBringIn(js(''), was)).toBe(true)
  // The same file, a reworded string, a comment naming an import, a new local, and an import taken away.
  expect(could(ROUTE)).toBe(false)
  expect(could(ROUTE.replace('status: 404', 'status: 410'))).toBe(false)
  expect(could(`// lateBooking and NOT_FOUND come from ./booking-copy\n${ROUTE}`)).toBe(false)
  expect(could(`${ROUTE}export const tries = 3\n`)).toBe(false)
  expect(could(ROUTE.replace('export const miss = () => new Response(NOT_FOUND, { status: 404 })\n', ''))).toBe(false)
})

test('in a file that posts by itself, a send reaching a name it did not could bring text in, with no import touched; the same name logged could not (#2637)', () => {
  const own = (body: string) => js([`import { lateBooking } from './booking-copy'`, `export const run = (id: string) => {`, `  const line = lateBooking(id)`, `  const note = 'ran'`, body, `}`].join('\n'))
  const posts = (what: string) => `  return fetch(${WEBHOOK}, { method: 'POST', body: JSON.stringify({ text: ${what} }) })`
  expect(mayBringIn(own(posts('note')), own(posts('note + line')))).toBe(true)
  expect(mayBringIn(own('  console.log(note)'), own(posts('line')))).toBe(true)
  expect(mayBringIn(own(posts('note')), own(`  console.log(line)\n${posts('note')}`))).toBe(false)
})

// #2719: a name's declarations are found only where the name stands, and what a file holds apart
// from what it is asked to follow is worked out once for its text. Each case here is one the search
// over the whole file found, so a narrower search that missed it would fail.
test('declarations are found where the name stands: a destructuring, a python target list after a bare line, never a longer word holding the name (#2719)', async () => {
  const r = js(
    [
      `const build = () => ({ text: 'The queue has stopped moving', channel: '#ops' })`,
      `const textual = 'A longer word is not the name'`,
      `export const run = () => {`,
      `  const { text, channel } = build()`,
      `  console.log('built', channel, textual)`,
      `  return sendSlackAlert(text)`,
      `}`,
    ].join('\n'),
  )
  const got = reached(r)
  expect(got['The queue has stopped moving']).toBe('sendSlackAlert')
  expect(got['A longer word is not the name']).toBe('')
  expect(got.built).toBe('')
  const p = py(
    [
      `import os, requests`,
      `URL = os.environ["SLACK_WEBHOOK_URL"]`,
      `def report():`,
      `    pass`,
      `    text, head = "The nightly load is late", "Nightly"`,
      `    print("report ran")`,
      `    requests.post(URL, json={"text": text})`,
    ].join('\n'),
  )
  const sent = reached(p)
  expect(sent['The nightly load is late']).toBe('requests.post')
  expect(sent['report ran']).toBe('')
})

test('tracing a text again with other send functions or names starts from the text alone: nothing asked of one trace carries into the next (#2719)', async () => {
  const text = "import { postAlert } from './post'\nexport const GET = async () => { console.log('cron started'); await postAlert('The nightly job is late') }\n"
  const imported = reached(js(text), new Map(), new Set(['postAlert']))
  expect(imported['The nightly job is late']).toBe('postAlert')
  // The same text, read again as a later step reads it: postAlert is no send of its own.
  const bare = reached(js(text))
  expect(bare['The nightly job is late']).toBe('')
  expect(trace(js(text)).sends).toEqual([])
  expect(reached(js(text), new Map(), new Set(['postAlert']))).toEqual(imported)
})
