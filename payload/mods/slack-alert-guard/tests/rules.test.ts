import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import {
  MARKERS,
  agentRefusal,
  ciMessages,
  ciWorkflow,
  codeOf,
  editedText,
  flowCommands,
  foreignNames,
  foreignUse,
  modelCandidates,
  modelInput,
  modelLiteral,
  modelOnlyDecls,
  modelReading,
  tokenRanges,
  heldText,
  inScope,
  isMessage,
  isOwnRecord,
  isSender,
  requestLanguage,
  sendMarks,
  isProse,
  isProseFile,
  literalsOf,
  mentionsStore,
  plainYamlValues,
  question,
  refusal,
  renderedProblem,
  slackMarked,
  stringsOf,
  testFile,
  wordingChange,
  wordingKey,
  wordingOf,
} from '../hooks/rules.ts'
import { readsAsSend } from './send-wording.ts'

// The Slack alert guard's pure rules (claude-config#2242). Dan, 2026-11-04: "anytime a slack alert
// is created, we need to have a design-rounds esque check on wording so I can approve the wording
// before it's created".

test('a file is in scope by a code or config extension, or a shebang when it has none', () => {
  for (const p of ['/w/a/alert.ts', '/w/a/x.tsx', '/w/a/x.mjs', '/w/a/notify.py', '/w/a/x.rb', '/w/a/x.go', '/w/a/x.sh', '/w/a/x.swift', '/w/a/x.json', '/w/a/x.yml', '/w/a/x.yaml']) expect(inScope(p, '')).toBe(true)
  expect(inScope('/w/a/bin/notify', '#!/bin/bash\necho hi\n')).toBe(true)
  expect(inScope('/w/a/bin/notify', 'plain words\n')).toBe(false)
  // Prose files post nothing themselves.
  for (const p of ['/w/a/README.md', '/w/a/notes.txt', '/w/a/x.css']) expect(inScope(p, '')).toBe(false)
})

test('a file posts to Slack by a webhook, the chat API, an SDK, or a send helper named for Slack', () => {
  expect(slackMarked('await fetch("https://hooks.slack.com/services/T/B/x", { body })')).toBe(true)
  expect(slackMarked('await client.chat.postMessage({ channel, text })')).toBe(true)
  expect(slackMarked("import { WebClient } from '@slack/web-api'")).toBe(true)
  expect(slackMarked('from slack_sdk import WebClient')).toBe(true)
  expect(slackMarked('client.chat_postMessage(channel=c, text=t)')).toBe(true)
  expect(slackMarked('const url = process.env.SLACK_WEBHOOK_URL')).toBe(true)
  expect(slackMarked('await sendSlackAlert(`Deploy ${id} failed`)')).toBe(true)
  expect(slackMarked('await notifySlack(msg)')).toBe(true)
  expect(slackMarked('slack.send(msg)')).toBe(true)
  // A test or caller that imports the helper, without calling it, still carries its wording.
  expect(slackMarked('import { sendSlackAlert } from "./alert"\nexpect(sent).toBe("Backup is late")')).toBe(true)
  expect(slackMarked('from alerts import send_slack_alert')).toBe(true)
  expect(slackMarked("const { notifySlack } = require('./slack')")).toBe(true)
  // The helper's name in a comment or a config key is not a post.
  expect(slackMarked('// notifySlack is off on weekends\nconst x = 1')).toBe(false)
  expect(slackMarked('notify_slack: true')).toBe(false)
  // A word about Slack is not a post to it, and neither is a function that only reads a marker.
  expect(slackMarked('// see the slack channel for context\nconst x = 1')).toBe(false)
  expect(slackMarked('export const slackMarked = (text: string) => true')).toBe(false)
  expect(slackMarked('console.log("Deploy failed")')).toBe(false)
})

// #2662 (Dan, 2026-11-10: "Recognise refusal code"): a gate that refuses Slack posts names the
// endpoints it refuses, in a pattern or a glob, and posts nothing.
const PATTERN = "MARKERS='chat[._](postmessage|schedulemessage)|hooks\\.slack\\.com|slack_webhook|slack_(send|schedule|post)_message'\n"
const GLOBS = 'refuse "$payload" \'*chat[._]postmessage*\' \'*hooks.slack.com*\' \'*slack_webhook*\'\n'
const PY_PATTERN = 'import re\nMARKER = re.compile(r"chat[._](postMessage|scheduleMessage)|hooks\\.slack\\.com|slack_webhook", re.I)\n'

test('code that names a Slack endpoint only to match or refuse it is not a sender: a pattern, a glob, a comment (#2662)', () => {
  // Each carries a marker, so each was a sender before; none is named or exempted anywhere.
  for (const t of [PATTERN, GLOBS, PY_PATTERN]) expect(slackMarked(t)).toBe(true)
  expect(isSender('hooks/gate.sh', `#!/bin/bash\n${PATTERN}${GLOBS}printf 'BLOCKED: this call was not checked.\\n' >&2\n`)).toBe(false)
  expect(isSender('hooks/gate', `#!/usr/bin/env bash\n${PATTERN}`)).toBe(false)
  // A gate's list of the programs it refuses is names it reads, in python never a program it runs.
  expect(isSender('hooks/gate.py', `${PY_PATTERN}SENDERS = {"curl", "wget", "http", "https"}\nJS_RUNS = re.compile(r"\\b(fetch|XMLHttpRequest|WebSocket)\\b")\n`)).toBe(false)
  expect(isSender('src/gate.ts', "export const refused = (cmd: string) => new RegExp('slack_webhook|hooks[.]slack[.]com', 'i').test(cmd)\n")).toBe(false)
  // The file being edited: a comment naming the endpoints it refuses is no send either.
  const commented = `#!/bin/bash\n# refuses curl aimed at chat.postMessage or hooks.slack.com\n${PATTERN}`
  expect(slackMarked(commented)).toBe(true)
  expect(isSender('hooks/gate.sh', commented, true)).toBe(false)
  expect(isSender('hooks/note.sh', '#!/bin/bash\n# the digest goes to $SLACK_WEBHOOK_URL from another job\nprintf "Noted\\n"\n', true)).toBe(false)
  expect(sendMarks('python', PY_PATTERN)).toEqual([])
  expect(sendMarks('shell', PATTERN + GLOBS)).toEqual([])
})

test('a name that is used is still a sender, however the file also matches it (#2662)', () => {
  // An address, a setting read, a method called, a whole quoted name handed to a call, an SDK.
  expect(isSender('scripts/notify.sh', '#!/bin/bash\ncurl -s --data "Deploy failed" https://hooks.slack.com/services/T000/B000/XXXX\n')).toBe(true)
  expect(isSender('scripts/notify.sh', '#!/bin/bash\npost "$SLACK_WEBHOOK_URL" "Deploy failed"\n')).toBe(true)
  expect(isSender('jobs/late.py', 'client.chat_postMessage(channel=c, text="Backup is late")\n')).toBe(true)
  expect(isSender('skills/nudge.py', 'answer = call("chat.postMessage", {"channel": channel, "text": text})\n')).toBe(true)
  expect(isSender('src/alert.ts', "import { WebClient } from '@slack/web-api'\n")).toBe(true)
  expect(isSender('src/alert.ts', 'export const late = () => sendSlackAlert("Backup is late")\n')).toBe(true)
  // A script that refuses and also posts: the half that posts decides.
  expect(isSender('hooks/gate.sh', `#!/bin/bash\n${PATTERN}${GLOBS}curl -s --data "$1" "$SLACK_WEBHOOK_URL"\n`)).toBe(true)
  expect(isSender('hooks/gate.py', `${PY_PATTERN}client.chat_postMessage(channel=c, text=t)\n`)).toBe(true)
  // A bar that is code, a bracket alone, a setting piped on: none is a pattern.
  expect(isSender('src/alert.ts', 'const channel = opts.channel || SLACK_CHANNEL || fallback\n')).toBe(true)
  expect(isSender('src/alert.ts', 'const channel = (opts.channel||SLACK_CHANNEL)\n')).toBe(true)
  expect(isSender('src/alert.ts', 'const hook = read(SLACK_WEBHOOK)\n')).toBe(true)
  expect(isSender('scripts/notify.sh', '#!/bin/bash\nprintf "%s" "$1" | post $SLACK_WEBHOOK|tee log\n')).toBe(true)
  // A pattern with the address beside it, and a list of bare names, are held as before.
  expect(isSender('scripts/relay.sh', '#!/bin/bash\ncase "$1" in https://hooks.slack.com/*) relay "$1" ;; esac\n')).toBe(true)
  expect(isSender('src/gate.ts', "export const REFUSED = ['chat.postMessage', 'hooks.slack.com']\n")).toBe(true)
  // A marker in a comment still makes the edited file a sender when the file makes a request.
  expect(isSender('scripts/notify.sh', '#!/bin/bash\n# posts to $SLACK_WEBHOOK_URL\ncurl -s --data "Deploy failed" "$HOOK"\n', true)).toBe(true)
  expect(isSender('scripts/notify.sh', '#!/bin/bash\n# posts to $SLACK_WEBHOOK_URL\ncurl -s --data "Deploy failed" "$HOOK"\n')).toBe(false)
  expect(sendMarks('python', 'client.chat_postMessage(channel=c, text=t)\n')).toEqual([7])
})

test('a file that matches a Slack endpoint and then makes a request is still a sender, in each language read for one (#2662)', () => {
  const sh = (body: string) => isSender('scripts/relay.sh', `#!/bin/bash\ncase "$1" in *hooks.slack.com*) ${body} ;; esac\n`)
  expect(sh('printf "skipped\\n"')).toBe(false)
  for (const body of [
    'curl -s --data "Relay is down" "$1"',
    '/usr/bin/curl -s "$1"',
    'out="$(wget -q -O - "$1")"',
    'http POST "$1" text="Relay is down"',
    'exec 3<>/dev/tcp/relay.example/443',
    'ssh relay "post $1"',
    'python3 -c "import urllib.request; urllib.request.urlopen(\'$1\')"',
    'node -e "fetch(process.argv[1])" "$1"',
    // A helper named for Slack, called as a shell calls one, which no marker sees.
    'notify_slack "Relay is down"',
    './bin/post-to-slack.sh "Relay is down"',
  ])
    expect(sh(body)).toBe(true)
  const py = (body: string) => isSender('jobs/relay.py', `${PY_PATTERN}${body}\n`)
  expect(py('print("skipped")')).toBe(false)
  for (const body of ['import urllib.request', 'import os, subprocess', 'from requests import post', 'import http.client as h', 'os.system(cmd)', 'mod = __import__(name)', 'import slack_bolt_helpers'])
    expect(py(body)).toBe(true)
  const js = (body: string) => isSender('src/relay.ts', `const SLACK = new RegExp('slack_webhook|hooks[.]slack[.]com')\n${body}\n`)
  expect(js('export const is = (u: string) => SLACK.test(u)')).toBe(false)
  for (const body of [
    'export const relay = (u: string) => SLACK.test(u) && fetch(u, { method: "POST" })',
    "import axios from 'axios'",
    "const { execFile } = require('node:child_process')",
    'const ws = new WebSocket(u)',
    "await Bun.spawn(['curl', u])",
    "await $.process.run(['curl', u])",
  ])
    expect(js(body)).toBe(true)
})

test("what a file reaches is read by mod-kit's file reader, so a program or module it only names in a string or pattern starts nothing (#2710)", () => {
  const py = (body: string) => isSender('hooks/gate.py', `${PY_PATTERN}${body}\n`)
  for (const body of [
    'HELP = "run: import subprocess, then os.system(cmd)"',
    "RUNS = re.compile(r'\\b(subprocess|pty|multiprocessing)\\b')",
    '"""\nimport urllib.request\n"""',
  ])
    expect(py(body)).toBe(false)
  // The control: the same file that does import one, or posts through a subprocess, still is one.
  expect(py('import subprocess\nsubprocess.run(["curl", "-d", text, url])')).toBe(true)
  expect(py('HELP = "import subprocess"\nimport subprocess')).toBe(true)
  const js = (body: string) => isSender('src/gate.ts', `const SLACK = new RegExp('slack_webhook|hooks[.]slack[.]com')\n${body}\n`)
  for (const body of ["const HINT = 'call fetch(u) or require(\"child_process\") yourself'", 'const RUNS = /\\b(child_process|fetch\\(|axios)/', 'const T = `import axios from "axios"`'])
    expect(js(body)).toBe(false)
  expect(js("const { exec } = require('child_process')")).toBe(true)
  // A shell script's inline python or node sits in quotes, so its text is read whole, as before.
  expect(isSender('scripts/relay.sh', `#!/bin/bash\ncase "$1" in *hooks.slack.com*) python3 -c "import subprocess" ;; esac\n`)).toBe(true)
})

test('only shell, python, JavaScript and TypeScript are read for a pattern: in any other language a marker is a sender, as before (#2662)', () => {
  expect(requestLanguage('hooks/gate.sh', '')).toBe('shell')
  expect(requestLanguage('hooks/gate', '#!/usr/bin/env python3\n')).toBe('python')
  expect(requestLanguage('hooks/gate', '#!/bin/zsh\n')).toBe('shell')
  expect(requestLanguage('src/gate.mts', '')).toBe('js')
  for (const p of ['lib/gate.rb', 'cmd/gate.go', '.github/workflows/gate.yml', 'config/gate.json', 'bin/gate']) {
    expect(requestLanguage(p, '#!/usr/bin/env ruby\n')).toBe(undefined)
    expect(isSender(p, "PATTERN = 'slack_webhook|hooks[.]slack[.]com'\n")).toBe(true)
  }
})

test('string literals are read past comments, in every quote a C-like or hash-comment language uses', () => {
  const ts = 'const a = "Deploy failed" // "not this one"\n/* "nor this" */\nconst b = `Job ${id} is stuck`\nconst c = \'It\\\'s down\'\n'
  expect(literalsOf(ts, false)).toEqual(['Deploy failed', 'Job ${id} is stuck', "It's down"])
  const sh = '#!/bin/bash\n# "a comment"\ncurl -d "{\\"text\\": \\"Backup failed on $HOST\\"}" "$URL"\n'
  expect(literalsOf(sh, true)).toEqual(['{"text": "Backup failed on $HOST"}', '$URL'])
  // A URL in a string is read as the string, never as a comment opening.
  expect(literalsOf('x("https://hooks.slack.com/a")', false)).toEqual(['https://hooks.slack.com/a'])
})

test('prose is text a person reads: two words or a word beside a filled in value, never a key, a path or a URL', () => {
  for (const s of ['Deploy failed', 'Job ${id} is stuck', '${n} failed', 'Backup failed on $HOST', 'Rate limit hit for {org}', 'Disk is full.']) expect(isProse(s)).toBe(true)
  for (const s of ['error', 'POST', 'application/json', 'https://hooks.slack.com/services/x', '${a}${b}', 'p-4 text-sm', '', '   ', '#alerts']) expect(isProse(s)).toBe(false)
  expect(wordingOf(['Deploy failed', 'POST', 'Deploy failed', 'x'])).toEqual(['Deploy failed', 'Deploy failed'])
})

test('a wording change is what was added and what was removed, counted, so a moved line is no change', () => {
  expect(wordingChange(['A b', 'C d'], ['C d', 'A b'])).toEqual({ added: [], removed: [] })
  expect(wordingChange(['Deploy failed'], ['Deploy failed on prod'])).toEqual({ added: ['Deploy failed on prod'], removed: ['Deploy failed'] })
  expect(wordingChange(['A b', 'A b'], ['A b'])).toEqual({ added: [], removed: ['A b'] })
  expect(wordingChange([], ['New alert text'])).toEqual({ added: ['New alert text'], removed: [] })
})

test('an approval is keyed to the exact wording, never to the file it sits in', () => {
  expect(wordingKey('Deploy failed')).toBe(wordingKey('Deploy failed'))
  expect(wordingKey('Deploy failed')).not.toBe(wordingKey('Deploy failed.'))
  expect(wordingKey('Deploy failed').startsWith('wording:')).toBe(true)
})

test('the text an edit leaves is read from the file as it is', () => {
  expect(editedText('a X b', 'Edit', { old_string: 'X', new_string: 'Y' })).toBe('a Y b')
  expect(editedText('a X b', 'Edit', { old_string: 'Z', new_string: 'Y' })).toBeUndefined()
  expect(editedText('a X X', 'Edit', { old_string: 'X', new_string: 'Y', replace_all: true })).toBe('a Y Y')
  expect(editedText('', 'Write', { content: 'new' })).toBe('new')
  expect(editedText('a b', 'MultiEdit', { edits: [{ old_string: 'a', new_string: 'c' }, { old_string: 'b', new_string: 'd' }] })).toBe('c d')
})

test('the message Dan is shown must be the real one: every variable filled, every added word in it', () => {
  const added = ['Deploy ${id} failed on ${env}']
  expect(renderedProblem('Deploy 4182 failed on production', added)).toBeUndefined()
  // Whitespace and line breaks are read as one space.
  expect(renderedProblem('Deploy  4182\nfailed on   production', added)).toBeUndefined()
  expect(renderedProblem(undefined, added)).toContain('rendered')
  expect(renderedProblem('   ', added)).toContain('rendered')
  expect(renderedProblem('Deploy ${id} failed on production', added)).toContain('${')
  expect(renderedProblem('Deploy {id} failed', ['Deploy {id} failed'])).toContain('{id}')
  expect(renderedProblem('Deploy 4182 failed', added)).toContain('failed on')
  // A shell call names no strings, so only the placeholders are read.
  expect(renderedProblem('Backup finished on db-1', [])).toBeUndefined()
})

// claude-config#2371, Dan's item 5: Dan is shown the message, never the source that builds it.
const NESTED = 'export const note = (db: string, late: boolean, hours: number) => `Backup of ${db} ${late ? `is ${hours} hours late` : "finished"}`\n'

test('a nested template literal is read whole, its inner wording read too, and the message asks only for words a message holds (Dan item 5)', () => {
  const texts = stringsOf(NESTED, false, true).map(s => s.text)
  // The outer template is one string, its value filled in by the inner one; the inner one is wording of its own.
  expect(texts).toContain('Backup of ${db} ${late ? `is ${hours} hours late` : "finished"}')
  expect(texts).toContain('is ${hours} hours late')
  const added = wordingOf(texts)
  expect(added).toContain('is ${hours} hours late')
  expect(renderedProblem('Backup of orders is 3 hours late', added)).toBeUndefined()
  // What it does ask for is a word of the message, never a piece of the code.
  const missing = renderedProblem('Backup of orders is 3 late', added) ?? ''
  expect(missing).toContain('hours late')
  expect(missing).not.toContain('${late')
  expect(renderedProblem('Orders is 3 hours late', added)).toContain('Backup of')
  // A template whose substitution never closes is read as before, never lost.
  expect(stringsOf('const m = `Disk is ${full`\n', false, true).map(s => s.text)).toEqual(['Disk is ${full'])
})

// A reusable alert workflow whose github-script step posts to Slack, building its text by concatenation.
const SCRIPT_WORKFLOW = [
  'on: workflow_call',
  'jobs:',
  '  alert:',
  '    runs-on: ubuntu-latest',
  '    steps:',
  '      - name: Tell the team the backup failed',
  '        uses: actions/github-script@v7',
  '        env:',
  '          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}',
  '        with:',
  '          script: |',
  "            const text = 'Nightly backup of ' + process.env.DB + ' failed on ' + context.ref",
  "            await fetch(process.env.SLACK_WEBHOOK_URL, { method: 'POST', body: JSON.stringify({ text }) })",
  '',
].join('\n')

test("a workflow's script step that posts to Slack is read as JavaScript: each piece of a concatenation is wording, and the code around it never is (Dan item 5)", () => {
  const ci = wordingOf(ciMessages(SCRIPT_WORKFLOW, '.github/workflows/alert.yml'))
  expect(ci).toEqual(['Nightly backup of ', ' failed on '])
  expect(renderedProblem('Nightly backup of orders failed on refs/heads/main', ci)).toBeUndefined()
  // A script step that posts nothing to Slack is a step like any other.
  expect(ciMessages(SCRIPT_WORKFLOW.replace(/SLACK_WEBHOOK_URL/g, 'DEPLOY_HOOK'), '.github/workflows/alert.yml')).toEqual([])
  // Outside a CI workflow (a composite action), a script block's lines are code, never plain values.
  const values = plainYamlValues(SCRIPT_WORKFLOW)
  expect(values.some(v => v.includes('const text'))).toBe(false)
  expect(values.some(v => v.includes('await fetch'))).toBe(false)
  expect(values).toContain('Tell the team the backup failed')
})

test("the guard's own record is recognised in the store, by name, and in a shell command", () => {
  expect(isOwnRecord(`${'/Users'}/dan/.claude/plugins/store/slack-alert-guard_inline-ab12.json`)).toBe(true)
  expect(isOwnRecord('/x/slack-alert-guard_inline.json')).toBe(true)
  expect(isOwnRecord('/w/a/slack-alert-guard/hooks/rules.ts')).toBe(false)
  expect(mentionsStore('cat > ~/.claude/plugins/store/x.json')).toBe(true)
  expect(mentionsStore('echo hi')).toBe(false)
})

test('a held edit names the wording it adds or takes away; a held shell command says its wording cannot be read', () => {
  expect(heldText('/w/a/alert.ts', ['Deploy failed on production'], [])).toBe('This edit to /w/a/alert.ts adds Slack message text Dan has not approved: "Deploy failed on production"')
  expect(heldText('/w/a/alert.ts', [], ['Deploy failed'])).toBe('This edit to /w/a/alert.ts takes Slack message text away: "Deploy failed"')
  const shell = heldText('/w/a/alert.ts', [], [])
  expect(shell).toContain('shell command')
  expect(shell).toContain('/w/a/alert.ts')
  expect(shell).not.toContain('takes Slack message text away')
  for (const r of [refusal('t1', '/w/a/alert.ts', [], []), agentRefusal('t1', '/w/a/alert.ts', [], [])]) {
    expect(r.startsWith('Blocked: this shell command')).toBe(true)
    expect(r).not.toContain('text away')
  }
  expect(refusal('t1', '/w/a/alert.ts', ['Deploy failed on production'], []).startsWith('Blocked: this edit to /w/a/alert.ts adds')).toBe(true)
})

// claude-config#2361, #2364, #2290: hold only text a Slack send builds.

test('a test file is told by its name or a test folder, read from the repository root', () => {
  for (const p of ['lib/alert.test.ts', 'app/route.spec.tsx', 'lib/__tests__/alert.ts', 'tests/notify.py', 'test/notify.js', 'pkg/notify_test.go', 'app/test_notify.py', 'app/notify_test.py', 'lib/notify_spec.rb', 'spec/notify.rb', 'hooks/test-notify.sh', 'lib/__mocks__/slack.ts'])
    expect(testFile(p)).toBe(true)
  // A node test script, as a work repository runs its tests (#2509): test-*.ts and its JavaScript
  // and TSX forms, beside the .test. and .spec. files of every one of them.
  for (const p of ['scripts/test-copy.ts', 'scripts/test-copy.tsx', 'scripts/test-copy.js', 'scripts/test-copy.jsx', 'scripts/test-copy.mjs', 'scripts/test-copy.cjs', 'lib/copy.test.js', 'lib/copy.spec.mjs'])
    expect(testFile(p)).toBe(true)
  // A word holding "test" or "spec" is not a test.
  for (const p of ['lib/alert.ts', 'lib/latest.ts', 'app/contest.py', 'lib/attestation.ts', 'lib/special.ts', 'scripts/post-test-results.ts', 'lib/testing-copy.ts', 'scripts/testflight-notify.ts', 'scripts/tester.ts', 'lib/test-copy.md']) expect(testFile(p)).toBe(false)
})

test('a database select list or a code template is not message text; a sentence beside them still is', () => {
  for (const s of ['id, starts_at, buckets!bookings_bucket_id_fkey!inner(code)', 'id, name', '*, owner:profiles(id, full_name)', 'id, created_at, status'])
    expect(isMessage(s)).toBe(false)
  const worker = 'export default {\n  async fetch(request, env) {\n    const body = await request.text();\n    return new Response(body);\n  }\n}\n'
  expect(isMessage(worker)).toBe(false)
  expect(isMessage('const run = (x) => x + 1;')).toBe(false)
  for (const s of ['Deploy failed, rolling back', 'Booking ${id} failed', 'Payment for ${name} is late, retrying', 'The function failed (exit 1)', 'Deploy failed; retry in five minutes'])
    expect(isMessage(s)).toBe(true)
  expect(wordingOf(['id, starts_at', 'Deploy failed on production'])).toEqual(['Deploy failed on production'])
})

test('a string passed to a query builder call is marked as a query, at any argument of it, and a sql tagged template too', () => {
  const ts =
    'const { data } = await db.from("bookings").select("id, starts_at, buckets!fk!inner(code)").eq("status", "Payment failed today").order("starts_at", { ascending: true })\nawait notify(`Booking ${id} failed`)\nconst q = sql`SELECT id FROM bookings WHERE status = ${s}`\n'
  const strings = stringsOf(ts, false, true)
  // .from( is left out of the query calls (an array method shares it); its table name is one word, never prose.
  expect(strings.filter(s => !s.query).map(s => s.text)).toEqual(['bookings', 'Booking ${id} failed'])
  expect(strings.filter(s => s.query).map(s => s.text)).toContain('Payment failed today')
  expect(strings.filter(s => s.query).map(s => s.text)).toContain('SELECT id FROM bookings WHERE status = ${s}')
  // literalsOf still reads every string, as before.
  expect(literalsOf(ts, false)).toContain('Payment failed today')
})

test('a placeholder JavaScript writes as text, in single or double quotes or escaped in a template, is told apart from one filled at run time', () => {
  const ts = "const a = 'Run with ${name} set'\nconst b = `Hello ${user}`\nconst c = `Use \\${HOME} here`\n"
  const s = stringsOf(ts, false, true)
  expect(s.map(x => x.literal)).toEqual([['${name}'], [], ['${HOME}']])
  // Outside JavaScript no placeholder is read as literal text.
  expect(stringsOf('msg = "Run with ${name} set"\n', true, false).map(x => x.literal)).toEqual([[]])
})

test('an approval may carry a placeholder the code writes as text, and still not one filled at run time', () => {
  const added = ['Run the job with ${name} set']
  expect(renderedProblem('Run the job with ${name} set', added, ['${name}'])).toBeUndefined()
  expect(renderedProblem('Run the job with ${name} set', added)).toContain('${name}')
  expect(renderedProblem('Run the job with ${other} set', added, ['${name}'])).toContain('${other}')
})

test('an ordinary array or string method is not a query builder call, so an alert inside one is still message text', () => {
  const ts = "items.filter(x => notify('Deploy failed on main'))\nconst s = parts.join(', and then retry')\nArray.from(rows, r => alert('Backup is late again'))\n"
  expect(stringsOf(ts, false, true).filter(s => s.query)).toEqual([])
  // Only a direct argument counts: a call nested inside a query builder call is read as usual.
  const nested = "rows.where(r => notify('Deploy failed on main')).order('starts_at', { ascending: true })\n"
  expect(stringsOf(nested, false, true).map(s => [s.text, s.query])).toEqual([['Deploy failed on main', false], ['starts_at', true]])
})

test('a SQL statement or fragment is not message text, and a sentence that opens with a SQL word still is (Dan item 2)', () => {
  for (const s of [
    "SELECT id, starts_at FROM bookings WHERE status = 'late'",
    'select b.id, count(*) from bookings b group by b.id',
    'insert into bookings (id, status) values ($1, $2)',
    'update bookings set status = $1 where id = $2',
    'delete from bookings where id = $1',
    'with late as (select id from bookings) select * from late',
    "where status = 'late' and paid is false",
    'create index bookings_status on bookings (status)',
  ])
    expect(isMessage(s)).toBe(false)
  for (const s of ['Select a plan from the list', 'Update the deploy settings before Friday', 'Deploy failed from main', 'Order by Friday or we miss the window', 'Delete the old branch when the deploy is done'])
    expect(isMessage(s)).toBe(true)
})

test('a CI workflow is read for the text a Slack step posts, never its names, needs, descriptions or plain run commands (Dan item 1)', () => {
  const wf = [
    'name: Deploy the site',
    'on:',
    '  workflow_dispatch:',
    '    inputs:',
    '      environment:',
    '        description: The environment to deploy to',
    'jobs:',
    '  build:',
    '    name: Build the site',
    '    steps:',
    '      - name: Install dependencies',
    '        run: npm ci && npm run build',
    '  notify:',
    '    needs: [ build, test ]',
    '    steps:',
    '      - name: Post to Slack',
    '        uses: slackapi/slack-github-action@v1',
    '        with:',
    '          payload: |',
    '            {"text": "Deploy of ${{ github.sha }} finished"}',
    '        env:',
    '          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}',
    '      - name: Page on failure',
    "        run: curl -X POST --data '{\"text\":\"Deploy failed on main\"}' \"$SLACK_WEBHOOK_URL\"",
    '      - name: Summary',
    '        env:',
    '          MESSAGE: Release notes are ready',
    '',
  ].join('\n')
  expect(ciWorkflow('.github/workflows/deploy.yml')).toBe(true)
  expect(ciWorkflow('config/locales/en.yml')).toBe(false)
  expect(wordingOf(ciMessages(wf, '.github/workflows/deploy.yml'))).toEqual(['Deploy of ${{ github.sha }} finished', 'Deploy failed on main', 'Release notes are ready'])
})

// A GitLab pipeline whose script lists post to Slack (#2401): each list item is one shell command.
const GITLAB_PIPELINE = [
  'stages: [deploy]',
  'deploy:',
  '  stage: deploy',
  '  before_script:',
  '    - echo "Preparing the release"',
  '  script:',
  '    - npm ci',
  '    - echo "Deploying the site now"',
  "    - curl -X POST --data '{\"text\":\"Deploy failed on main\"}' \"$SLACK_WEBHOOK_URL\"",
  "    - 'curl -X POST --data ''{\"text\":\"Backup of orders is late\"}'' \"$SLACK_WEBHOOK_URL\"'",
  '    # the summary goes out last',
  '    - >',
  "      curl -X POST -H 'Content-type: application/json'",
  "      --data '{\"text\":\"Nightly sync finished\"}' \"$SLACK_WEBHOOK_URL\"",
  '  after_script:',
  "  - \"curl -X POST --data '{\\\"text\\\":\\\"Cleanup ran on main\\\"}' $SLACK_WEBHOOK_URL\"",
  '',
].join('\n')

test('a GitLab script list is read as one run block: when an item posts to Slack, every item of the shell it runs in shows its strings (#2401, #2416)', () => {
  expect(ciWorkflow('.gitlab-ci.yml')).toBe(true)
  // before_script and script run in one shell, so both are read; after_script runs in its own.
  expect(wordingOf(ciMessages(GITLAB_PIPELINE, '.gitlab-ci.yml'))).toEqual([
    'Preparing the release',
    'Deploying the site now',
    'Deploy failed on main',
    'Backup of orders is late',
    'Nightly sync finished',
    'Cleanup ran on main',
  ])
  // A pipeline whose script lists post nothing to Slack holds nothing.
  expect(ciMessages(GITLAB_PIPELINE.replace(/SLACK_WEBHOOK_URL/g, 'DEPLOY_HOOK'), '.gitlab-ci.yml')).toEqual([])
  // A Bitbucket step's script list is read the same way.
  const bitbucket = [
    'pipelines:',
    '  default:',
    '    - step:',
    '        name: Deploy',
    '        script:',
    '          - echo "Starting the deploy"',
    "          - curl -X POST --data '{\"text\":\"Deploy of main is stuck\"}' \"$SLACK_WEBHOOK_URL\"",
    '',
  ].join('\n')
  expect(ciWorkflow('bitbucket-pipelines.yml')).toBe(true)
  expect(wordingOf(ciMessages(bitbucket, 'bitbucket-pipelines.yml'))).toEqual(['Starting the deploy', 'Deploy of main is stuck'])
})

// #2416: the shapes #2401 left unread. Each one hides a Slack message that a GitHub run block shows.
test('a message set in one GitLab script item and posted by a later item is shown, and a job that posts nothing still holds nothing (#2416)', () => {
  const wf = [
    'deploy:',
    '  before_script:',
    '    - export WHERE="the production cluster"',
    '  script:',
    '    - export MSG="Deploy failed on main"',
    '    - curl -X POST --data "{\\"text\\":\\"$MSG\\"}" "$SLACK_WEBHOOK_URL"',
    'test:',
    '  script:',
    '    - echo "Running the unit tests"',
    '',
  ].join('\n')
  const ci = wordingOf(ciMessages(wf, '.gitlab-ci.yml'))
  expect(ci).toContain('Deploy failed on main')
  expect(ci).toContain('the production cluster')
  expect(ci).not.toContain('Running the unit tests')
})

test('a GitLab flow list of commands is read as shell, on one line or several (#2416)', () => {
  const wf = [
    'notify:',
    '  script: [\'export MSG="Backup of orders is late"\', \'curl -X POST --data \'\'{"text":"Nightly sync finished"}\'\' "$SLACK_WEBHOOK_URL"\']',
    '  after_script: [',
    '    "curl -X POST --data \'{\\"text\\":\\"Cleanup ran on main\\"}\' $SLACK_WEBHOOK_URL",',
    '  ]',
    'quiet:',
    '  script: ["echo \\"Running the unit tests\\""]',
    '',
  ].join('\n')
  const ci = wordingOf(ciMessages(wf, '.gitlab-ci.yml'))
  expect(ci).toContain('Backup of orders is late')
  expect(ci).toContain('Nightly sync finished')
  expect(ci).toContain('Cleanup ran on main')
  expect(ci).not.toContain('Running the unit tests')
})

test("a GitLab flow list is read as YAML reads one: a quoted item's commas and brackets are its own, a quote opens only at an item's start, and a comment ends its line (#2416)", () => {
  const lines = [
    `  script: [ 'echo "Backup, of [orders] is late"', # the backup check`,
    `    echo don't, "say \\"hi\\" now", echo a#b,`,
    `    {text: [1, 2]}, 'it''s' ]`,
    'after: x',
  ]
  const raw = (lines[0] as string).slice((lines[0] as string).indexOf('['))
  expect(flowCommands(lines, 0, raw)).toEqual(['echo "Backup, of [orders] is late"', "echo don't", 'say "hi" now', 'echo a#b', '{text: [1, 2]}', "it's"])
  // A list that never closes keeps every item it read.
  expect(flowCommands(['  script: ["a", b'], 0, '["a", b')).toEqual(['a', 'b'])
})

test('a GitLab script written as one block or one string is shell, while a GitHub script block stays JavaScript (#2416)', () => {
  const wf = [
    'notify:',
    '  script: |',
    '    export MSG="Deploy of main is stuck"',
    '    curl -X POST --data \'{"text":"Backup of orders is late"}\' "$SLACK_WEBHOOK_URL"',
    'page:',
    '  script: "curl -X POST --data \'{\\"text\\":\\"Nightly sync finished\\"}\' $SLACK_WEBHOOK_URL"',
    '',
  ].join('\n')
  const ci = wordingOf(ciMessages(wf, '.gitlab-ci.yml'))
  expect(ci).toContain('Deploy of main is stuck')
  expect(ci).toContain('Backup of orders is late')
  expect(ci).toContain('Nightly sync finished')
  // A GitHub workflow's script block is github-script's JavaScript, read as it always was.
  expect(wordingOf(ciMessages(SCRIPT_WORKFLOW, '.github/workflows/alert.yml'))).toEqual(['Nightly backup of ', ' failed on '])
})

test("a Bitbucket step's after-script list is read like its script list (#2416)", () => {
  const bitbucket = [
    'pipelines:',
    '  default:',
    '    - step:',
    '        name: Deploy',
    '        script:',
    '          - npm ci',
    '        after-script:',
    "          - curl -X POST --data '{\"text\":\"Deploy of main is stuck\"}' \"$SLACK_WEBHOOK_URL\"",
    '',
  ].join('\n')
  expect(wordingOf(ciMessages(bitbucket, 'bitbucket-pipelines.yml'))).toEqual(['Deploy of main is stuck'])
})

// claude-config#2284. Dan, 2026-11-05, rejecting "Post this Slack message from ...?" twice: "You
// should never be posting a Slack message for me".
test('the send detector is seen to fire on wording that asks to post or send, and not on wording that says nothing is sent', () => {
  for (const s of ['Post this Slack message from /w/a/alert.ts?', 'post it', 'Send this alert?', 'This will be posted to #alerts', 'Approve and send', 'Sent to Slack'])
    expect(readsAsSend(s)).toBe(true)
  for (const s of ['Approve the wording of this alert? Approving sends nothing.', 'Hold the edit, and say what it should say instead.']) expect(readsAsSend(s)).toBe(false)
})

test('the question approves the wording of an automated alert in the named file, says approving sends nothing, and never asks to post', () => {
  const q = question('/w/a/alert.ts', 'Deploy 4182 failed on production')
  const [lead] = q.split('\n\n')
  expect(readsAsSend(lead ?? '')).toBe(false)
  expect(/^\s*post\b/i.test(q)).toBe(false)
  expect(lead).toContain('/w/a/alert.ts')
  expect(lead).toMatch(/approve/i)
  expect(lead).toContain('wording')
  expect(lead).toContain('automated')
  expect(lead).toContain('sends nothing')
  expect(q.endsWith('\n\nDeploy 4182 failed on production')).toBe(true)
})
// #2368's line reader and #2361's comment blanking were one rule written twice; codeOf is now the
// tokenizer, and this holds the behaviours #2368's test of the line reader asserted.
test('codeOf leaves comments out and keeps code, strings, and code after a closed block comment', () => {
  const ts = codeOf('a.ts', '// notify.ts\nrun(id)\n/* notify.ts */\n/**\n * notify.ts\n */\n/* x */ run(id)\n')
  expect(ts).not.toContain('notify.ts')
  expect(ts.match(/run\(id\)/g)?.length).toBe(2)
  const yml = codeOf('a.yml', '# notify.ts\nsteps:\n  - run: go\n')
  expect(yml).not.toContain('notify.ts')
  expect(yml).toContain('steps:\n  - run: go\n')
  const job = codeOf('job', '#!/bin/sh\n# notify.ts\ncurl x\n')
  expect(job).not.toContain('notify.ts')
  expect(job).toContain('curl x\n')
  expect(codeOf('a.json', '{"a": "#b"}\n')).toBe('{"a": "#b"}\n')
  expect(codeOf('a.ts', 'send("see // notify.ts")\n')).toContain('"see // notify.ts"')
})

// #2475: which strings only a model reads. `model` gives, for each string of a file, whether it is one.
const model = (text: string, python: boolean, foreign = new Map<string, { ok: boolean; model: boolean }>()) => {
  const ranges = tokenRanges(text, python)
  const r = modelReading(text, python, ranges)
  const starts = ranges.strings.map(s => s.from)
  const cands = modelCandidates(r, starts)
  const only = modelOnlyDecls(r, cands, foreign)
  return Object.fromEntries(ranges.strings.map(s => [text.slice(s.from, s.to), modelLiteral(r, only, s.from)]))
}

test('a model key, a python keyword argument, or a message content beside its role is a model input; a variable named system is not (#2475)', () => {
  const at = (code: string, word = 'P') => modelInput(code, code.lastIndexOf(word))
  expect(at('create({ model: m, system: P })')).toBe(true)
  expect(at('create({\n  system: copy.P,\n})')).toBe(true)
  expect(at('create(model=m, system=P)')).toBe(true)
  expect(at('{ instructions: P }')).toBe(true)
  expect(at('messages: [{ role: "user", content: P }]')).toBe(true)
  expect(at('{"content": P, "role": "system"}')).toBe(true)
  expect(at('const system = P')).toBe(false)
  expect(at('postMessage({ channel: c, text: P })')).toBe(false)
  expect(at('{ content: P }')).toBe(false)
  expect(at('{ system: wrap(P) }')).toBe(false)
})

test('a prompt constant used only as a model input, or built into one, is read only by a model; an alert beside it, an unused constant and a posted one are not (#2475)', () => {
  const js = [
    'const BASE = `You are the nightly editor.',
    '',
    'Keep it plain.`',
    "const SYSTEM = [BASE, 'Never use a dash.'].join('\\n')",
    'const UNUSED = `Nobody reads this sentence yet.`',
    'const POSTED = `Deploy failed on production.`',
    'const run = async () => {',
    "  await client.messages.create({ system: SYSTEM, messages: [{ role: 'user', content: 'Edit the draft below.' }] })",
    "  await slack.chat.postMessage({ text: POSTED })",
    "  await slack.chat.postMessage({ text: 'The digest is ready.' })",
    '}',
    '',
  ].join('\n')
  const seen = model(js, false)
  expect(seen['You are the nightly editor.\n\nKeep it plain.']).toBe(true)
  expect(seen['Never use a dash.']).toBe(true)
  expect(seen['Edit the draft below.']).toBe(true)
  expect(seen['Nobody reads this sentence yet.']).toBe(false)
  expect(seen['Deploy failed on production.']).toBe(false)
  expect(seen['The digest is ready.']).toBe(false)
})

test('an exported prompt counts as read only by a model only once other files are known to use it no other way; a renamed export never does (#2475)', () => {
  const js = 'export const PROMPT = `Edit the draft plainly.`\nexport const go = () => client.messages.create({ system: PROMPT })\n'
  const ranges = tokenRanges(js, false)
  const r = modelReading(js, false, ranges)
  const cands = modelCandidates(r, ranges.strings.map(s => s.from))
  expect(foreignNames(r, cands)).toContain('PROMPT')
  expect(model(js, false)['Edit the draft plainly.']).toBe(false)
  expect(model(js, false, new Map([['PROMPT', { ok: true, model: false }]]))['Edit the draft plainly.']).toBe(true)
  expect(model(js, false, new Map([['PROMPT', { ok: false, model: false }]]))['Edit the draft plainly.']).toBe(false)
  const renamed = 'const PROMPT = `Edit the draft plainly.`\nexport { PROMPT as P }\nexport const go = () => client.messages.create({ system: PROMPT })\n'
  expect(model(renamed, false, new Map([['PROMPT', { ok: true, model: false }]]))['Edit the draft plainly.']).toBe(false)
})

test('python: a module level prompt handed to a keyword argument is read only by a model; a posted string is not (#2475)', () => {
  const py = [
    '_PROMPT = """You are the nightly editor.',
    'Keep it plain."""',
    '',
    'def run(draft):',
    '    res = client.messages.create(model="m", system=_PROMPT, messages=[{"role": "user", "content": draft}])',
    '    slack.chat_postMessage(channel="C1", text="The digest is ready.")',
    '',
  ].join('\n')
  const seen = model(py, true)
  expect(Object.entries(seen).some(([k, v]) => k.includes('You are the nightly editor.') && v)).toBe(true)
  expect(seen['The digest is ready.']).toBe(false)
})

test('another file using a prompt: an import by its own name is no use, a model input is, and anything else is not ok (#2475)', () => {
  expect(foreignUse('a/run.ts', "import {\n  type X,\n  PROMPT,\n} from './editor'\nexport const go = () => c.create({ system: PROMPT })\n", 'PROMPT')).toEqual({ ok: true, model: true })
  expect(foreignUse('a/index.ts', "export { PROMPT } from './editor'\n", 'PROMPT')).toEqual({ ok: true, model: false })
  expect(foreignUse('a/run.ts', "import { PROMPT as P } from './editor'\n", 'PROMPT')).toEqual({ ok: false, model: false })
  expect(foreignUse('a/job.ts', "import { PROMPT } from './editor'\nslack.chat.postMessage({ text: PROMPT })\n", 'PROMPT')).toEqual({ ok: false, model: false })
  expect(foreignUse('a/run.py', 'from app.editor import (\n    other,\n    PROMPT,\n)\nclient.messages.create(system=PROMPT)\n', 'PROMPT')).toEqual({ ok: true, model: true })
  expect(foreignUse('a/run.py', 'from app.editor import PROMPT as P\n', 'PROMPT')).toEqual({ ok: false, model: false })
  // A name only in a comment is no use at all.
  expect(foreignUse('a/run.ts', '// PROMPT is the editor prompt\n', 'PROMPT')).toEqual({ ok: true, model: false })
})

test('only prose files are ruled out as senders', () => {
  for (const p of ['CLAUDE.md', 'docs/runbook.markdown', 'a.mdx', 'a.rst', 'a.adoc', 'notes.txt']) expect(isProseFile(p)).toBe(true)
  for (const p of ['a.ts', 'a.vue', 'a.sql', 'a.toml', 'a.yml', 'Makefile']) expect(isProseFile(p)).toBe(false)
})

