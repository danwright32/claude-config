// area-check-named-rule.mjs <named.ts> <mod-kit writes.ts> <area check rules.ts> <checkout> <NAME> <file>:
// the area check's rule for one script it lets through by name, run on mod-kit's REAL reader of a
// command and real git, in a throwaway checkout holding the real script (the suite that asks made
// it, with origin/main at its first commit). <NAME> is what named.ts exports the script by, and
// <file> a file under payload/mods there, from the root.
//
// It lets through only that script at its path from the root of a checkout of its repository, handed
// one folder, in a command that sets no value and runs the script once, with nothing but a change of
// folder before it and readers its output is piped into after it, with its texts as the checkout
// left the default branch with them. Every other shape, a changed text, a copy elsewhere, another
// repository, and everything chained with the run, another named script included, is still judged.
//
// One line a check, PASS or FAIL with the evidence, for tests/area-check-named-reader.sh named_rule,
// which holds the count to the number its suite states. The checkout is left changed: run it last.
import { spawnSync } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, copyFileSync, statSync } from 'node:fs'
import { dirname } from 'node:path'
const [namedPath, writesPath, rulesPath, repo, entry, file] = process.argv.slice(2)
const { NAMED, namedReaders, ...exported } = await import(namedPath)
const { commandWrites, pipelineIn } = await import(writesPath)
const { shellTargets } = await import(rulesPath)
const ME = exported[entry]
if (!ME || !NAMED.includes(ME)) throw new Error(`named.ts keeps no ${entry} among the scripts it lets through`)
const S = ME.script
const HOME = '/Users/dan'
const git = (...args) => spawnSync('git', ['-C', repo, '-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args], { encoding: 'utf8' })
const facts = (github, cwd) => ({
  commands: async command => pipelineIn(command, cwd, HOME),
  checkout: async path => {
    const r = spawnSync('git', ['-C', dirname(path), 'rev-parse', '--show-toplevel'], { encoding: 'utf8' })
    return r.status === 0 ? { root: r.stdout.trim(), github, defaultBranch: 'main' } : { unread: 'it is in no checkout' }
  },
  isFolder: async path => existsSync(path) && statSync(path).isDirectory(),
  git: async (root, args) => spawnSync('git', ['-C', root, ...args]).status ?? 2,
})
const say = (name, ok, evidence) => console.log(ok ? `PASS\t${name}` : `FAIL\t${name}\t${evidence}`)
// What the area check goes on to judge for a command, and what the rule decided for each named run.
const read = async (command, cwd = repo, github = ME.repo) => {
  const r = await namedReaders(command, commandWrites(command, cwd, HOME), facts(github, cwd))
  return { judged: shellTargets(r.writes, HOME).map(t => t.path ?? t.word), named: r.named }
}
const through = async (name, command, cwd) => {
  const r = await read(command, cwd)
  say(name, r.judged.length === 0 && r.named.length === 1 && r.named[0].passed === true, `${command} gave ${JSON.stringify(r)}`)
}
const judged = async (name, command, wants, why, github) => {
  const r = await read(command, repo, github)
  const ok = wants.every(w => r.judged.includes(w)) && r.named.every(n => !n.passed) && (why === undefined || r.named.some(n => (n.why ?? '').includes(why)))
  say(name, ok, `${command} gave ${JSON.stringify(r)}`)
}
const MODS = `${repo}/payload/mods`
const FILE = `${repo}/${file}`
const RUN = `bash ${S} payload/mods`

await through('the run from the root of the checkout is let through, judging nothing', RUN)
await through('run directly, by its path from the root', `./${S} payload/mods`)
await through('by its whole path, its output piped to a reader', `bash ${repo}/${S} ${MODS} 2>&1 | tail -n 40`)
await through('from a folder inside the checkout', `cd payload && bash ../${S} mods`)

await judged('the same path in a clone of another repository is judged', RUN, [MODS], `never ${ME.repo}`, 'someone/else')
await judged('in a checkout of no GitHub repository it is judged', RUN, [MODS], 'no GitHub repository', null)
mkdirSync(dirname(`${repo}/copy/${S}`), { recursive: true })
copyFileSync(`${repo}/${S}`, `${repo}/copy/${S}`)
await judged('a copy elsewhere in the checkout is judged', `bash copy/${S} payload/mods`, [MODS], `not ${S} at the root`)
await judged('a script of that name in no checkout is judged', `bash /nowhere/${S} payload/mods`, [MODS], 'its checkout cannot be read')
await judged('handed two folders, both are judged', `bash ${S} payload/mods payload/hooks`, [MODS, `${repo}/payload/hooks`], 'more than the one folder')
await judged('with a value set in front of it, it is judged', `TMPDIR=payload/mods bash ${S} payload/mods`, [MODS], 'sets a value')
await judged('with a value exported before it, it is judged', `export CLAUDE_BIN=/tmp/x; bash ${S} payload/mods`, [MODS], 'sets a value')
// A value set with no equals sign, by a command that runs first: only a change of folder may.
const BEFORE = 'runs in the same command'
// Written after it, a command still runs before it the second time round a loop, or once a function is called.
await judged('in a loop that reads and exports a value after it, it is judged', `for i in 1 2; do bash ${S} payload/mods; read TMPDIR <<< payload/mods; export TMPDIR; done`, [MODS], BEFORE)
await judged('in a function called after a value is read and exported, it is judged', `f() { bash ${S} payload/mods; }; read TMPDIR <<< payload/mods; export TMPDIR; f`, [MODS], BEFORE)
await through('its output piped through two readers is let through', `cd payload && bash ../${S} mods 2>&1 | grep -v ok | tail -n 40`)
await judged('after a value read and exported, it is judged', `read TMPDIR <<< payload/mods; export TMPDIR; bash ${S} payload/mods`, [MODS], BEFORE)
await judged('after a value printed into a variable and exported, it is judged', `printf -v TMPDIR %s payload/mods; export TMPDIR; bash ${S} payload/mods`, [MODS], BEFORE)
await judged('after a sourced file, it is judged', `. ./env.sh; bash ${S} payload/mods`, [MODS], BEFORE)
await judged('inside a loop that names a variable, it is judged', `for TMPDIR in payload/mods; do export TMPDIR; bash ${S} payload/mods; done`, [MODS], BEFORE)
await judged('run twice with a value exported between, both are judged', `bash ${S} payload/mods; export TMPDIR; bash ${S} payload/mods`, [MODS], 'run more than once')
await judged('run by another shell, it is judged', `sh ${S} payload/mods`, [MODS])
await judged('handed a file, the file is judged', `bash ${S} ${file}`, [FILE], 'is no folder on the disk')
await judged('handed a name built as the command runs, it is judged', `bash ${S} "$MODS"`, ['$MODS'], 'cannot be read as the one folder')
await judged('handed a pattern, it is judged', `bash ${S} payload/*`, ['payload/*'], 'cannot be read as the one folder')
{
  const r = await read(`${RUN} > ${file}`)
  say('its output sent into a file under the folder still judges that file', r.judged.length === 1 && r.judged[0] === FILE && r.named[0].passed === true, JSON.stringify(r))
}
{
  const r = await read(`${RUN} && sed -i '' 's/a/b/' ${file}`)
  say('chained with an edit, the edit and the folder are both judged', r.judged.includes(FILE) && r.judged.includes(MODS) && !r.named[0].passed, JSON.stringify(r))
}
{
  const r = await read(`${RUN} && bash copy/${S} payload/mods`)
  say('another script handed the same folder in the same command keeps the folder judged', r.judged.includes(MODS) && r.named.every(n => !n.passed), JSON.stringify(r))
}
// Each script is let through for itself alone: chained with another named one, both are judged, since
// each is another command to the other.
for (const other of NAMED.filter(n => n !== ME)) {
  const r = await read(`${RUN} && bash ${other.script} payload/mods`)
  say(`chained with ${other.script}, which is let through by name too, both are judged`, r.judged.includes(MODS) && r.named.length === 2 && r.named.every(n => (n.why ?? '').includes(BEFORE)), JSON.stringify(r))
}

// A changed text is not the text the suite proved: an edit not committed, one committed on the
// branch, and an edit to each other text; back as it was, the run is let through again.
const CHANGED = 'has changed since this checkout left origin/main'
appendFileSync(`${repo}/${S}`, '# changed\n')
await judged('the script edited and not committed is judged', RUN, [MODS], CHANGED)
git('commit', '-q', '-a', '-m', 'change the script')
await judged('the script changed in a commit on the branch is judged', RUN, [MODS], CHANGED)
git('checkout', '-q', 'origin/main', '--', S)
git('commit', '-q', '-a', '-m', 'put the script back')
await through('the script put back as the default branch has it is let through again', RUN)
for (const text of ME.texts.slice(1)) {
  appendFileSync(`${repo}/${text}`, '# changed\n')
  await judged(`${text} edited is judged`, RUN, [MODS], CHANGED)
  git('checkout', '-q', '--', text)
}
await through('every other text put back, the run is let through again', RUN)
git('update-ref', '-d', 'refs/remotes/origin/main')
await judged('with no origin/main to compare with, it is judged', RUN, [MODS], 'git could not compare its text')
