import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { stringsOf } from '../hooks/rules.ts'
import { consoleArgs, jsSpans, pySpans, readingOf, sentAt, trace, type Reading } from '../hooks/sends.ts'
import { pythonText } from './mod-kit/hooks/code.ts'

// Which strings reach a Slack send (claude-config#2570): only those are Slack wording. Each case
// names a string sent and one that is not, in the same file, so a reading that sends everything,
// or nothing, fails.

const js = (text: string): Reading => readingOf(text, false, jsSpans(text))
const py = (text: string): Reading => readingOf(text, true, pySpans(pythonText(text)))
// Each string of a file, and the callee of the send it reaches ('' for none).
const reached = (r: Reading): Record<string, string> => {
  const t = trace(r)
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

test("a file's own send is traced: its function posting to a webhook is a send, a log line beside it is not", async () => {
  const helper = js(`export const postAlert = (text: string) => fetch(${WEBHOOK}, { method: 'POST', body: JSON.stringify({ text }) })\nexport const GET = async () => { console.log('cron started'); await postAlert('The nightly job is late') }\n`)
  expect(trace(helper).sends.map(s => s.callee)).toContain('fetch')
  const got = reached(helper)
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

test('a call to a function imported from another file is no send of the file calling it (#2719, #2850)', async () => {
  const text = "import { postAlert } from './post'\nexport const GET = async () => { console.log('cron started'); await postAlert('The nightly job is late') }\n"
  expect(reached(js(text))['The nightly job is late']).toBe('')
  expect(trace(js(text)).sends).toEqual([])
})

test('a string is a console log line only as a whole argument of console.log, info, warn, error or debug (#2907)', () => {
  // Each string, and whether consoleArgs reads it as a whole argument of a console call.
  const logs = (text: string): Record<string, boolean> => {
    const r = js(text)
    const at = consoleArgs(r, jsSpans(text).strings)
    return Object.fromEntries(stringsOf(text, false, true).map(s => [s.text, at.has(s.start)]))
  }
  expect(logs("p.catch((err) => console.error('[alert] report failed', err))\n")).toEqual({ '[alert] report failed': true })
  expect(logs("console.warn(\n  'slow',\n  ms,\n)\nconsole.debug(a, `took ${ms}`)\nconsole.info(f(a, b), 'after a call')\n")).toEqual({ slow: true, 'took ${ms}': true, 'after a call': true })
  expect(logs("console.log('part of ' + id)\nconsole.log(post('handed on'))\nconsole.log(post(hook, 'deeper', id))\nconsole.error({ msg: 'in an object' })\nlogger.error('another logger')\nconsole.table('a table')\n")).toEqual({
    'part of ': false,
    'handed on': false,
    deeper: false,
    'in an object': false,
    'another logger': false,
    'a table': false,
  })
  // A python file has no console.
  expect(consoleArgs(py("print('x')\n"), [])).toEqual(new Set())
})
