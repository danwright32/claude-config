// area-check-named-rule.mjs <named.ts> <mod-kit writes.ts> <area check rules.ts> <checkout> <NAME> <file>:
// the area check's rule for one script it lets through by name, run on mod-kit's REAL reader of a
// command and real git, in a throwaway checkout holding the real script (the suite that asks made
// it, with origin/main at its first commit). <NAME> is what named.ts exports the script by, and
// <file> a file under payload/mods there, from the root.
//
// It lets through only that script at its path from the root of a checkout of its repository, handed
// one folder, in a command that gives it no setting and runs the script once, behind no runner, with
// nothing but a change of folder before it (one folder written from /, ./, ../ or ~, which is on
// the disk) and readers its output is piped into after it, with its texts as the checkout left the
// default branch with them.
// Every other shape, a changed text, a copy elsewhere, another repository, and everything chained
// with the run, another named script included, is still judged.
//
// One rule runs for every named script, and one thing in it differs by script: what an equals sign
// holds. Dan signed off on 2026-11-16 (#3093) that for tools/check-mods.sh an equals sign holds the
// run only where it may set a value for the script, so one in a reader of its output does not. Every
// other named script is held on any equals sign in the command, as when it was signed off (#3082).
// Which script is which is stated here by hand, never read from named.ts (L721), so the loosening
// reaching a script it was not signed off for turns that script's suite red.
//
// One line a check, PASS or FAIL with the evidence, for tests/area-check-named-reader.sh named_rule,
// which holds the count to the number its suite states. The checkout is left changed: run it last.
import { spawnSync } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, copyFileSync, statSync } from 'node:fs'
import { basename, dirname } from 'node:path'
const [namedPath, writesPath, rulesPath, repo, entry, file] = process.argv.slice(2)
const { NAMED, namedReaders, ...exported } = await import(namedPath)
const { commandWrites, pipelineIn } = await import(writesPath)
const { shellTargets } = await import(rulesPath)
const ME = exported[entry]
if (!ME || !NAMED.includes(ME)) throw new Error(`named.ts keeps no ${entry} among the scripts it lets through`)
const S = ME.script
const HOME = '/Users/dan'
const git = (...args) => spawnSync('git', ['-C', repo, '-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args], { encoding: 'utf8' })
// Asked as the area check asks mod-kit: with the commands that only set a value (#3093). `asks` is
// what the reader is asked for, so a reader that gives less can stand in.
const facts = (github, cwd, asks = { assignments: true }) => ({
  commands: async command => pipelineIn(command, cwd, HOME, asks),
  checkout: async path => {
    const r = spawnSync('git', ['-C', dirname(path), 'rev-parse', '--show-toplevel'], { encoding: 'utf8' })
    return r.status === 0 ? { root: r.stdout.trim(), github, defaultBranch: 'main' } : { unread: 'it is in no checkout' }
  },
  isFolder: async path => existsSync(path) && statSync(path).isDirectory(),
  git: async (root, args) => spawnSync('git', ['-C', root, ...args]).status ?? 2,
})
const say = (name, ok, evidence) => console.log(ok ? `PASS\t${name}` : `FAIL\t${name}\t${evidence}`)
// What the area check goes on to judge for a command, and what the rule decided for each named run.
const read = async (command, cwd = repo, github = ME.repo, asks) => {
  const r = await namedReaders(command, commandWrites(command, cwd, HOME), facts(github, cwd, asks))
  return { judged: shellTargets(r.writes, HOME).map(t => t.path ?? t.word), named: r.named }
}
const through = async (name, command, cwd) => {
  const r = await read(command, cwd)
  say(name, r.judged.length === 0 && r.named.length === 1 && r.named[0].passed === true, `${command} gave ${JSON.stringify(r)}`)
}
const judged = async (name, command, wants, why, github, asks) => {
  const r = await read(command, repo, github, asks)
  const ok = wants.every(w => r.judged.includes(w)) && r.named.every(n => !n.passed) && (why === undefined || r.named.some(n => (n.why ?? '').includes(why)))
  say(name, ok, `${command} gave ${JSON.stringify(r)}`)
}
const MODS = `${repo}/payload/mods`
const FILE = `${repo}/${file}`
const RUN = `bash ${S} payload/mods`
// The one script whose hold on an equals sign Dan loosened (#3093), by the name named.ts exports it by.
const LOOSENED = entry === 'CHECK_MODS'
// Why a command holding an equals sign is judged: for the loosened script the reason the rule gives
// for that equals sign, and for every other the hold on any equals sign in the command.
const ANY_EQUALS = 'the command sets a value (it holds an equals sign)'
const equals = why => (LOOSENED ? why : ANY_EQUALS)
// An equals sign that gives the script no setting: let through for the loosened script alone.
const inReader = async (what, command) => (LOOSENED ? through(`${what} let through`, command) : judged(`${what} judged`, command, [MODS], ANY_EQUALS))

await through('the run from the root of the checkout is let through, judging nothing', RUN)
await through('run directly, by its path from the root', `./${S} payload/mods`)
await through('by its whole path, its output piped to a reader', `bash ${repo}/${S} ${MODS} 2>&1 | tail -n 40`)
await through('from a folder inside the checkout', `cd ./payload && bash ../${S} mods`)

await judged('the same path in a clone of another repository is judged', RUN, [MODS], `never ${ME.repo}`, 'someone/else')
await judged('in a checkout of no GitHub repository it is judged', RUN, [MODS], 'no GitHub repository', null)
mkdirSync(dirname(`${repo}/copy/${S}`), { recursive: true })
copyFileSync(`${repo}/${S}`, `${repo}/copy/${S}`)
await judged('a copy elsewhere in the checkout is judged', `bash copy/${S} payload/mods`, [MODS], `not ${S} at the root`)
await judged('a script of that name in no checkout is judged', `bash /nowhere/${S} payload/mods`, [MODS], 'its checkout cannot be read')
await judged('handed two folders, both are judged', `bash ${S} payload/mods payload/hooks`, [MODS, `${repo}/payload/hooks`], 'more than the one folder')
// A reader that leaves out any of what #3093 added answers as one loaded before it, and says nothing
// of a setting or a runner. Here the real reader is not asked for the commands that only set a
// value, so the line the rule knows the reading of comes back short and no run is let through.
await judged('with a reader that leaves out the commands that only set a value, the plain run is judged', RUN, [MODS], 'does not say what a command is run with or behind (#3093)', ME.repo, {})
// A value set with no equals sign, by a command that runs first: only a change of folder may.
const BEFORE = 'runs in the same command'
// #3093: a setting the script, its shell or the programs it runs may read holds the run wherever the
// command gives it. For the loosened script the reason names it, never its value.
await judged('with a value set in front of it, it is judged', `TMPDIR=payload/mods bash ${S} payload/mods`, [MODS], equals('it is run with TMPDIR set'))
await judged('with a value given to it by env, it is judged', `env CLAUDE_BIN=/tmp/x bash ${S} payload/mods`, [MODS], equals('it is run with CLAUDE_BIN set'))
await judged("with the shell's startup file named, it is judged", `BASH_ENV=./env.sh bash ${S} payload/mods`, [MODS], equals('it is run with BASH_ENV set'))
await judged('with a name only the programs it runs may read, it is judged', `NODE_OPTIONS=--require=/tmp/x.js bash ${S} payload/mods`, [MODS], equals('it is run with NODE_OPTIONS set'))
await judged('with a value set in front of the change of folder before it, it is judged', `TMPDIR=mods cd ./payload && bash ../${S} mods`, [MODS], equals('the change of folder before it is run with TMPDIR set'))
await judged('after a value set on its own, it is judged', `TMPDIR=payload/mods; bash ${S} payload/mods`, [MODS], equals('the command sets TMPDIR on its own'))
await judged('after a value set on its own inside braces, it is judged', `{ PATH=/tmp/bin; bash ${S} payload/mods; }`, [MODS], equals('the command sets PATH on its own'))
await judged('with a value exported before it, it is judged', `export CLAUDE_BIN=/tmp/x; bash ${S} payload/mods`, [MODS], equals(`export ${BEFORE}`))
await judged('chained after a command holding an equals sign, it is judged', `git log --format=%s && bash ${S} payload/mods`, [MODS], equals(`git ${BEFORE}`))
await judged('handed its folder as the value of an option, it is judged', `bash ${S} --mods=payload/mods`, [MODS], equals('holds an equals sign in its words'))
await inReader('an option written with an equals sign on a reader of its output is', `bash ${S} payload/mods 2>&1 | tail --lines=40`)
await inReader('a pattern holding an equals sign, and a setting, on readers of its output are', `cd ./payload && bash ../${S} mods 2>&1 | grep -v "skip=" | LC_ALL=C sort`)
// #3093: a run behind a runner the reader looks past, or in a shell's own script, is judged whatever
// the runner is. `env -C copy` runs the copy under copy/, and `env -i`, `env -u` and sudo change the
// environment with no equals sign written. On main since #3022 each of these read as the plain run.
const BEHIND = 'which can change the folder or the environment it runs in'
await judged('behind env changing the folder, it is judged', `env -C copy bash ${S} payload/mods`, [MODS], `it is run behind env, ${BEHIND}`)
await judged('behind env clearing the environment, it is judged', `env -i bash ${S} payload/mods`, [MODS], `it is run behind env, ${BEHIND}`)
await judged('behind env unsetting a name, it is judged', `env -u TMPDIR bash ${S} payload/mods`, [MODS], `it is run behind env, ${BEHIND}`)
await judged('behind sudo, it is judged', `sudo bash ${S} payload/mods`, [MODS], `it is run behind sudo, ${BEHIND}`)
await judged('behind nice and timeout, it is judged', `nice -n 5 timeout 600 bash ${S} payload/mods`, [MODS], `it is run behind nice, timeout, ${BEHIND}`)
await judged("in a shell's own script, it is judged", `bash -c 'bash ${S} payload/mods'`, [MODS], `it is run behind bash, ${BEHIND}`)
// A change of folder before it is let through only where the folder the shell goes to can be shown:
// one folder written from /, ./, ../ or ~. A bare name is looked up along CDPATH first.
const NOT_PLAIN_CD = 'the change of folder before it is not a cd to one folder written from /, ./, ../ or ~'
await judged('after a change of folder by a bare name, it is judged', `cd payload && bash ../${S} mods`, [MODS], NOT_PLAIN_CD)
await judged('after a change of folder with an option, it is judged', `cd -P ./payload && bash ../${S} mods`, [MODS], NOT_PLAIN_CD)
await through('after a change of folder written from the root, it is let through', `cd ${repo}/payload && bash ../${S} mods`)
// A change of folder that fails leaves the shell where it was, and joined by `;` or `||` the script
// still runs, from there: the file one folder above the one the reader placed, which nobody
// compared, handed a folder written from the root. The reader does not say what joins two commands,
// so a change of folder must lead to a folder on the disk (lessons review at 2a15886).
const NOWHERE = 'the change of folder before it leads to no folder on the disk'
await judged('after a change of folder to no folder on the disk, joined by a semicolon, it is judged', `cd ./nowhere; bash ../${S} ${MODS}`, [MODS], NOWHERE)
await judged('run only if a change of folder to no folder on the disk fails, it is judged', `cd ./nowhere || bash ../${S} ${MODS}`, [MODS], NOWHERE)
// The reader works out where a change of folder ends from its text, collapsing `..`, and the shell
// refuses one written through a folder that is not there (bash and zsh, measured 2026-11-17). So a
// `..` after a named part holds the run, whether or not the folders are there, and a path that
// only starts with `..` is still followed (lessons review at 90dfc12).
const BACKS_OUT = 'the change of folder before it backs out of a folder it names'
await judged('after a change of folder written through a folder that is not there and back out, it is judged', `cd ./nowhere/../payload; bash ../${S} ${MODS}`, [MODS], BACKS_OUT)
await judged('after a change of folder written through a folder that is there and back out, it is judged', `cd ./payload/../payload && bash ../${S} mods`, [MODS], BACKS_OUT)
await through('after a change of folder that starts from the folder above, it is let through', `cd ../${basename(repo)}/payload && bash ../${S} mods`)
// Written after it, a command still runs before it the second time round a loop, or once a function is called.
await judged('in a loop that reads and exports a value after it, it is judged', `for i in 1 2; do bash ${S} payload/mods; read TMPDIR <<< payload/mods; export TMPDIR; done`, [MODS], BEFORE)
await judged('in a function called after a value is read and exported, it is judged', `f() { bash ${S} payload/mods; }; read TMPDIR <<< payload/mods; export TMPDIR; f`, [MODS], BEFORE)
await through('its output piped through two readers is let through', `cd ./payload && bash ../${S} mods 2>&1 | grep -v ok | tail -n 40`)
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
