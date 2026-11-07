import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import {
  MARKERS,
  REEXPORT_HOPS,
  SENDER_PREFILTER,
  agentRefusal,
  ciMessages,
  ciWorkflow,
  editedText,
  handsOn,
  heldText,
  importTerms,
  inScope,
  isMessage,
  isOwnRecord,
  isProse,
  linkPattern,
  literalsOf,
  mentionsStore,
  question,
  refersTo,
  refusal,
  renderedProblem,
  searchTerm,
  slackMarked,
  stringsOf,
  templateLines,
  termsPattern,
  testFile,
  textTemplate,
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

test("the guard's own record is recognised in the store, by name, and in a shell command", () => {
  expect(isOwnRecord('/Users/dan/.claude/plugins/store/slack-alert-guard_inline-ab12.json')).toBe(true)
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

// claude-config#2248: a template whose wording a different file sends to Slack.

test('a held template names the file that sends it, and says the template itself posts nothing', () => {
  expect(heldText('/w/a/templates/deploy.ts', ['Deploy failed on production'], [], '/w/a/notify.ts')).toBe(
    'This edit to /w/a/templates/deploy.ts, which /w/a/notify.ts sends to Slack, adds Slack message text Dan has not approved: "Deploy failed on production"',
  )
  const shell = heldText('/w/a/templates/deploy.ts', [], [], '/w/a/notify.ts')
  expect(shell).toContain('which /w/a/notify.ts sends to Slack')
  expect(shell).not.toContain('which posts to Slack')
  expect(refusal('t1', '/w/a/t.ts', ['Backup is late'], [], '/w/a/notify.ts')).toContain('/w/a/notify.ts sends to Slack')
  expect(agentRefusal('t1', '/w/a/t.ts', ['Backup is late'], [], '/w/a/notify.ts')).toContain('/w/a/notify.ts sends to Slack')
})

// claude-config#2361, #2364, #2290: hold only text a Slack send builds.

test('a test file is told by its name or a test folder, read from the repository root', () => {
  for (const p of ['lib/alert.test.ts', 'app/route.spec.tsx', 'lib/__tests__/alert.ts', 'tests/notify.py', 'test/notify.js', 'pkg/notify_test.go', 'app/test_notify.py', 'app/notify_test.py', 'lib/notify_spec.rb', 'spec/notify.rb', 'hooks/test-notify.sh', 'lib/__mocks__/slack.ts'])
    expect(testFile(p)).toBe(true)
  // A word holding "test" or "spec" is not a test.
  for (const p of ['lib/alert.ts', 'lib/latest.ts', 'app/contest.py', 'lib/attestation.ts', 'lib/special.ts', 'scripts/post-test-results.ts', 'lib/testing-copy.ts']) expect(testFile(p)).toBe(false)
})

test('docs are not text templates any more; a plain text template still is', () => {
  for (const p of ['/w/a/docs/runbook.md', '/w/a/README.markdown']) expect(textTemplate(p)).toBe(false)
  expect(textTemplate('/w/a/templates/backup.txt')).toBe(true)
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

test('a string passed to a query builder call is marked as a query, at any argument and inside a nested call', () => {
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

test('a sender that names a file without importing or reading it does not refer to it (Dan item 1)', () => {
  expect(refersTo('scripts/deploy.sh', 'git add package.json CHANGELOG.md\ngit commit -m release\n', 'package.json')).toBe(false)
  expect(refersTo('scripts/deploy.ts', 'const tracked = ["package.json", "lib/templates/deploy.ts"]\n', 'package.json')).toBe(false)
  expect(refersTo('scripts/deploy.ts', 'await run(`cp lib/templates/deploy.ts dist/`)\n', 'lib/templates/deploy.ts')).toBe(false)
  // Importing it, requiring it, or reading it still refers to it.
  expect(refersTo('scripts/deploy.ts', "const pkg = require('../package.json')\n", 'package.json')).toBe(true)
  expect(refersTo('scripts/deploy.sh', 'BODY=$(cat lib/templates/deploy.txt)\n', 'lib/templates/deploy.txt')).toBe(true)
  expect(refersTo('scripts/deploy.sh', 'BODY=$(< lib/templates/deploy.txt)\n', 'lib/templates/deploy.txt')).toBe(true)
  // A path built on one line and read on the next still refers (lessons review at 395e7be).
  expect(refersTo('lib/notify.ts', "const TPL = path.join(__dirname, 'templates', 'deploy.txt')\nconst body = readFileSync(TPL, 'utf8')\n", 'lib/templates/deploy.txt')).toBe(true)
  expect(refersTo('app/notify.py', 'TPL = os.path.join(BASE, "templates/backup.txt")\nbody = open(TPL).read()\n', 'app/templates/backup.txt')).toBe(true)
})

test('an ordinary array or string method is not a query builder call, so an alert inside one is still message text', () => {
  const ts = "items.filter(x => notify('Deploy failed on main'))\nconst s = parts.join(', and then retry')\nArray.from(rows, r => alert('Backup is late again'))\n"
  expect(stringsOf(ts, false, true).filter(s => s.query)).toEqual([])
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
  expect(wordingOf(ciMessages(wf))).toEqual(['Deploy of ${{ github.sha }} finished', 'Deploy failed on main', 'Release notes are ready'])
})

test('a sender naming a template only in a comment does not refer to it', () => {
  expect(refersTo('lib/notify.ts', '// the wording is in docs/runbook.txt\nconst x = 1\n', 'docs/runbook.txt')).toBe(false)
  expect(refersTo('app/notify.py', '# see templates/backup.txt\nx = 1\n', 'app/templates/backup.txt')).toBe(false)
  expect(refersTo('lib/notify.ts', 'const body = readFileSync("docs/runbook.txt", "utf8")\n', 'docs/runbook.txt')).toBe(true)
})

test('the modules a file imports give the words a search for its send helper looks for', () => {
  const ts = "import { postAlert } from '@/lib/notify/post'\nimport React from 'react'\nconst x = require('../slack/index.js')\nimport { miscCopy } from './outage-copy'\n"
  expect(importTerms(ts).sort()).toEqual(['outage-copy', 'post', 'slack'])
  expect(importTerms('from app.alerts.sender import post_alert\n').sort()).toContain('sender')
})

test('a sender names a template by a relative import, resolved against its own folder or the repository root', () => {
  const T = 'src/lib/templates/deploy.ts'
  expect(refersTo('src/lib/notify.ts', "import { deployFailed } from './templates/deploy'\n", T)).toBe(true)
  expect(refersTo('src/lib/notify.ts', "import { deployFailed } from './templates/deploy.js'\n", T)).toBe(true)
  expect(refersTo('src/jobs/notify.ts', "const t = require('../lib/templates/deploy')\n", T)).toBe(true)
  // A shell script runs from the root, so its relative path is read from there too.
  expect(refersTo('bin/notify.sh', 'MSG=$(cat ./src/lib/templates/deploy.ts)\n', T)).toBe(true)
  // The same name in another folder is another file.
  expect(refersTo('src/jobs/notify.ts', "import { deployFailed } from './templates/deploy'\n", T)).toBe(false)
  expect(refersTo('src/lib/notify.ts', "import { x } from './deploy'\n", T)).toBe(false)
})

test('a sender names a template by its path, a file name with its extension, an alias, or a python module', () => {
  const TXT = 'app/templates/backup.txt'
  expect(refersTo('app/notify.py', 'body = open("templates/backup.txt").read()\n', TXT)).toBe(true)
  expect(refersTo('app/notify.ts', "readFileSync(path.join(__dirname, 'templates', 'backup.txt'), 'utf8')\n", TXT)).toBe(true)
  expect(refersTo('app/notify.ts', 'readFileSync(`${__dirname}/templates/backup.txt`)\n', TXT)).toBe(true)
  expect(refersTo('web/notify.ts', "import { digest } from '@/lib/alerts/digest'\n", 'web/src/lib/alerts/digest.ts')).toBe(true)
  const PY = 'app/alerts/messages.py'
  expect(refersTo('app/notify.py', 'from app.alerts.messages import BACKUP_LATE\n', PY)).toBe(true)
  expect(refersTo('app/notify.py', 'from app.alerts import messages\n', PY)).toBe(true)
  expect(refersTo('app/alerts/notify.py', 'from . import messages\n', PY)).toBe(true)
  expect(refersTo('app/alerts/notify.py', 'from .messages import BACKUP_LATE\n', PY)).toBe(true)
  expect(refersTo('app/alerts/notify.py', 'import messages\n', PY)).toBe(true)
  // A package's own index is named by its folder.
  expect(refersTo('src/notify.ts', "import { late } from './alerts'\n", 'src/alerts/index.ts')).toBe(true)
  expect(refersTo('app/notify.py', 'from app import alerts\n', 'app/alerts/__init__.py')).toBe(true)
})

test('a word that only shares the template name is not a reference to it', () => {
  const PY = 'app/alerts/messages.py'
  expect(refersTo('app/notify.py', 'messages = []\nfor m in messages: print(m)\n', PY)).toBe(false)
  expect(refersTo('app/notify.ts', "import { messages } from '@slack/web-api'\n", 'app/alerts/messages.ts')).toBe(false)
  expect(refersTo('app/notify.ts', "const kind = 'messages'\n", 'app/alerts/messages.ts')).toBe(false)
  expect(refersTo('app/notify.ts', "fetch('/api/messages')\n", 'app/alerts/messages.ts')).toBe(false)
  // Another file of the same name with a different extension is another file.
  expect(refersTo('app/notify.py', 'open("templates/backup.json")\n', 'app/templates/backup.txt')).toBe(false)
})

test('a text template is read line by line, and the search term is the name a sender writes', () => {
  for (const p of ['/w/a/templates/backup.txt', '/w/a/t/alert.hbs', '/w/a/t/alert.j2', '/w/a/t/alert.mustache']) expect(textTemplate(p)).toBe(true)
  for (const p of ['/w/a/x.css', '/w/a/x.ts', '/w/a/Makefile']) expect(textTemplate(p)).toBe(false)
  expect(templateLines('Backup is late\n\n  on {host}  \n')).toEqual(['Backup is late', 'on {host}'])
  expect(searchTerm('src/lib/templates/deploy.ts')).toBe('deploy')
  expect(searchTerm('src/alerts/index.ts')).toBe('alerts')
  expect(searchTerm('app/alerts/__init__.py')).toBe('alerts')
})

// claude-config#2286: a template handed on through a file that imports and re-exports it.
test('a file hands a template on when it can export what it imports: a JS or TS export, or any python module', () => {
  for (const text of ["export * from './deploy'\n", "export { deployFailed } from './deploy'\n", "import t from './deploy'\nexport default t\n", "export{ t }\n", "module.exports = require('./deploy')\n", "exports.deployFailed = require('./deploy').deployFailed\n"])
    expect(handsOn('lib/messages.ts', text)).toBe(true)
  expect(handsOn('lib/messages.mjs', "export * from './deploy'\n")).toBe(true)
  expect(handsOn('app/templates/__init__.py', 'from .deploy import TEXT\n')).toBe(true)
  // A JS file that only uses what it imports cannot hand it to another file.
  expect(handsOn('lib/use.ts', "import { deployFailed } from './deploy'\nconsole.log(deployFailed('1'))\n")).toBe(false)
  expect(handsOn('lib/use.ts', "import { deployFailed } from './deploy'\nconst exporter = 1\nfoo.exports.x = 1\n")).toBe(false)
  // A shell script, a text file, or JSON hands nothing on.
  expect(handsOn('bin/run.sh', 'export DEPLOY=./deploy\n')).toBe(false)
  expect(handsOn('docs/notes.md', "export * from './deploy'\n")).toBe(false)
})

test('the re-export search finds the line that names the template, in a pattern macOS git grep reads', () => {
  const re = (rels: string[]) => new RegExp(linkPattern(rels), 'i')
  const one = re(['lib/templates/deploy.ts'])
  for (const line of ["export * from './deploy'", "const t = require('./deploy')", 'from .deploy import TEXT', 'import templates.deploy', "body = readFileSync('templates/deploy.ts')"]) expect(one.test(line)).toBe(true)
  expect(one.test('const deploy = 1')).toBe(false)
  expect(re(['jobs/templates/backup.txt']).test('body = open("templates/backup.txt").read()')).toBe(true)
  const two = re(['lib/templates/index.ts', 'lib/alpha.ts'])
  expect(two.test("export * from './templates'")).toBe(true)
  expect(two.test("export * from './alpha'")).toBe(true)
  // macOS git grep -E reads \b as matching nothing (measured), so neither pattern may use it.
  expect(linkPattern(['lib/a.ts', 'b.txt']).includes('\\b')).toBe(false)
  expect(termsPattern(['lib/templates/deploy.ts'])).toBe('deploy')
  expect(termsPattern(['lib/templates/index.ts', 'lib/alpha.ts'])).toBe('(templates|alpha)')
  expect(REEXPORT_HOPS).toBe(3)
})

test('the sender search keeps every file a Slack marker can match: each marker names slack or postMessage', () => {
  // The repository is searched for SENDER_PREFILTER before any file is read, so a marker that could
  // match text holding neither word would never see its file read.
  for (const m of MARKERS) expect(/slack|postmessage/i.test(m.source)).toBe(true)
  expect(SENDER_PREFILTER).toBe('slack|postmessage')
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
