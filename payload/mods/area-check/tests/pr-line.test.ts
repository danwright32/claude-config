import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { READ_SCRIPT, ROTATE_BYTES, ROTATE_SCRIPT, SETTLE_MINUTES, rotationStamp } from '../hooks/prline.ts'
import { SWEEP_MS } from '../hooks/rules.ts'
import { APP, DIR, ERRORS, KIT, LOG, REASON, SLACK, T0, bash, decide, decidedLine, edit, ghLists, refusal, said, world, type R } from './world.ts'

// The area check line a pull request description carries (#1510): every file decided on the branch
// (and merge base) the pull request is made from has one line, `Area check: <file>: <decision>,
// <reason>`, checked on gh pr create, gh pr edit and gh pr merge. The decisions come from this Mac's
// log and the decision files its rotation keeps (#2143); a log that cannot be read is said, never read as none.

const A = 'Area check: src/a.ts: proceed, it only renames one local variable inside a function'
const B = 'Area check: src/b.ts: fold, Refs #41'
const seedAB = (w: ReturnType<typeof world>) => {
  w.ctl.seeded.push(
    decidedLine({ path: 'src/a.ts', decision: 'proceed', reason: 'it only renames one local variable inside a function' }),
    decidedLine({ path: 'src/b.ts', decision: 'fold', issue: 41 }),
  )
}
// The reads of the log (#2143), each as ran it: the words after the script, its folder first.
const readsOf = (w: ReturnType<typeof world>) => w.ran.filter(l => l.startsWith(`/bin/sh -c ${READ_SCRIPT} `))
const reads = (w: ReturnType<typeof world>) => readsOf(w).length
const ranBash = (w: ReturnType<typeof world>, command: string) => w.passed.includes(`Bash ${command}`)
const judgedApplied = (path: string, applied: string, extra: object = {}) =>
  JSON.stringify({ v: 2, kind: 'judged', at: '2026-10-22T15:00:00.000Z', session: 's0', agent: null, repo: 'dan/app', path, branch: '12-feature', mergeBase: 'mb123', decision: 'held', applied, ...extra })

test('a decision taken on the branch is asked for on gh pr create: refused with the exact line to paste, the command never run', KIT, async ($, on) => {
  const w = world($, on)
  await edit($ as never, w, SLACK)
  const d = await decide($ as never, { call: 'c1', decision: 'proceed', reason: REASON })
  expect(d.deny).toBe(undefined)
  expect(w.records().find(x => x.kind === 'decided')).toMatchObject({ v: 3, branch: '12-feature', mergeBase: 'mb123', path: 'src/lib/slack.ts', decision: 'proceed' })
  const cmd = 'gh pr create --title "Feature" --body "Adds the feature"'
  const why = refusal(await bash($ as never, w, cmd))
  expect(why).toContain('gh pr create')
  expect(why).toContain('12-feature')
  expect(why).toContain(`Area check: src/lib/slack.ts: proceed, ${REASON}`)
  expect(why).toContain("this Mac's log only")
  expect(ranBash(w, cmd)).toBe(false)
})

test('a description carrying every line passes, bulleted or with the file in backticks', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  // In single quotes, so the backticks are text; in double quotes the shell would run them (#2166).
  const cmd = `gh pr create --title T --body 'Summary\n\n- Area check: \`src/a.ts\`: proceed, it only renames one local variable inside a function\n* ${B}\n'`
  const r = await bash($ as never, w, cmd)
  expect(refusal(r)).toBe('')
  expect(ranBash(w, cmd)).toBe(true)
  // The control: the same description without its fold line is refused, so the pass above was a check.
  const short = refusal(await bash($ as never, w, `gh pr create --title T --body 'Summary\n\n- Area check: \`src/a.ts\`: proceed, it only renames one local variable inside a function\n'`, {}, 'b2'))
  expect(short).toContain(B)
})

test('only the files missing a line are listed, each with its line', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const why = refusal(await bash($ as never, w, `gh pr create --title T --body "${A}"`))
  expect(why).toContain(B)
  expect(why).not.toContain(A)
})

test('--body-file is read relative to the folder the command runs in, a cd before it followed', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  w.files[`${APP}/docs/body.md`] = `${A}\n${B}\n`
  const ok = 'cd docs && gh pr create --title T --body-file body.md'
  expect(refusal(await bash($ as never, w, ok))).toBe('')
  expect(ranBash(w, ok)).toBe(true)
  w.files[`${APP}/pr.md`] = `${A}\n`
  expect(refusal(await bash($ as never, w, 'gh pr create --title T -F pr.md', {}, 'b2'))).toContain(B)
})

test('a body file that cannot be read is refused by name, never read as a description without lines', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const missing = refusal(await bash($ as never, w, 'gh pr create --title T --body-file nowhere.md'))
  expect(missing).toContain(`${APP}/nowhere.md`)
  expect(missing).toContain('no such file')
  w.files[`${APP}/locked.md`] = `${A}\n${B}\n`
  w.ctl.unreadableFiles.push(`${APP}/locked.md`)
  const locked = refusal(await bash($ as never, w, 'gh pr create --title T -F locked.md', {}, 'b2'))
  expect(locked).toContain(`${APP}/locked.md`)
  expect(locked).toContain('permission denied')
})

test('--body-file - fed by a heredoc reads the heredoc; fed by a pipe it is standard input, which cannot be read', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const ok = `gh pr create --title T --body-file - <<'EOF'\n${A}\n${B}\nEOF`
  expect(refusal(await bash($ as never, w, ok))).toBe('')
  const short = refusal(await bash($ as never, w, `gh pr create --title T -F - <<'EOF'\n${A}\nEOF`, {}, 'b2'))
  expect(short).toContain(B)
  const piped = refusal(await bash($ as never, w, 'cat pr.md | gh pr create --title T -F -', {}, 'b3'))
  expect(piped).toContain('standard input')
})

test('a --body given as a substitution of a heredoc is read as its text', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const ok = `gh pr create --title T --body "$(cat <<'EOF'\nSummary\n\n${A}\n${B}\nEOF\n)"`
  expect(refusal(await bash($ as never, w, ok))).toBe('')
  const short = refusal(await bash($ as never, w, `gh pr create --title T --body "$(cat <<'EOF'\n${A}\nEOF\n)"`, {}, 'b2'))
  expect(short).toContain(B)
  // Spelled --body=... and -b, the word the reader derives still carries the flag, which is taken off.
  expect(refusal(await bash($ as never, w, `gh pr create --title T --body="$(cat <<'EOF'\n${A}\n${B}\nEOF\n)"`, {}, 'b3'))).toBe('')
  expect(refusal(await bash($ as never, w, `gh pr create --title T -b "$(cat <<'EOF'\n${A}\n${B}\nEOF\n)"`, {}, 'b4'))).toBe('')
  expect(refusal(await bash($ as never, w, `gh pr create --title T --body="$(cat <<'EOF'\n${A}\nEOF\n)"`, {}, 'b5'))).toContain(B)
})

test('a line given only in the title, or elsewhere in the command, is not a line of a description given as a substitution (#2166)', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  // A line counts only at the start of a line, so each sits on a line of its own outside the description.
  const titled = refusal(await bash($ as never, w, `gh pr create --title "Feature\n${B}" --body "$(cat <<'EOF'\n${A}\nEOF\n)"`))
  expect(titled).toContain('lacks the area check line for 1 file')
  expect(titled).toContain(B)
  const echoed = refusal(await bash($ as never, w, `cat <<'NOTE'\n${B}\nNOTE\ngh pr create --title T --body "$(cat <<'EOF'\n${A}\nEOF\n)"`, {}, 'b2'))
  expect(echoed).toContain(B)
})

test('a description whose substitution the command reader cannot work out is refused, saying why, even when its command holds every line (#2166)', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const cmd = `gh pr create --title T --body "$(printf '%s' '\n${A}\n${B}\n')"`
  const why = refusal(await bash($ as never, w, cmd))
  expect(why).toContain('could not work out the description')
  expect(why).toContain('--body-file')
  expect(ranBash(w, cmd)).toBe(false)
  const read = refusal(await bash($ as never, w, 'gh pr create --title T --body "$(cat pr.md)"', {}, 'b2'))
  expect(read).toContain('could not work out the description')
})

test('gh pr create with no body flag is refused while decisions stand, asking for --body or --body-file', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const why = refusal(await bash($ as never, w, 'gh pr create --title T --fill'))
  expect(why).toContain('--body or --body-file')
  expect(why).toContain(A)
  expect(why).toContain(B)
})

test('a missing log is refused naming it, never read as no decisions', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.log = 'missing'
  const why = refusal(await bash($ as never, w, 'gh pr create --title T --body x'))
  expect(why).toContain('~/.claude-area-check/log.jsonl')
  expect(why).toContain('No such file or directory')
  expect(why).toContain("this Mac's log only")
})

test('an unreadable log is refused naming it and why', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.log = 'unreadable'
  const why = refusal(await bash($ as never, w, 'gh pr edit 5 --body x'))
  expect(why).toContain('~/.claude-area-check/log.jsonl')
  expect(why).toContain('Permission denied')
})

test('a malformed log line is skipped and named in a refusal, and said in a dim line on a pass; an older decision without a branch is not malformed', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  w.ctl.seeded.push('{"v":3,"kind":"decided","repo":"dan/app","pa', JSON.stringify({ v: 2, kind: 'decided', repo: 'dan/app', path: 'src/old.ts', call: 'c9', decision: 'proceed', reason: 'an older record' }))
  const why = refusal(await bash($ as never, w, `gh pr create --title T --body "${A}"`))
  expect(why).toContain('1 line of the log')
  expect(why).toContain('{"v":3,"kind":"decided","repo":"dan/app","pa')
  expect(why).not.toContain('src/old.ts')
  const ok = `gh pr create --title T --body "${A}\n${B}"`
  expect(refusal(await bash($ as never, w, ok, {}, 'b2'))).toBe('')
  expect(w.logs.some(l => l.includes('1 line of its log') && l.includes(LOG.replace('/Users/dan', '~')))).toBe(true)
})

test('a decision taken on a detached head (branch null) is left out, never counted malformed', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  w.ctl.seeded.push(JSON.stringify({ v: 3, kind: 'decided', repo: 'dan/app', branch: null, mergeBase: 'mb123', path: 'src/detached.ts', call: 'c8', decision: 'proceed', reason: 'taken on a detached head' }))
  const why = refusal(await bash($ as never, w, `gh pr create --title T --body "${A}"`))
  expect(why).toContain('area check line')
  expect(why).not.toContain('line of the log')
  expect(why).not.toContain('src/detached.ts')
  expect(refusal(await bash($ as never, w, `gh pr create --title T --body "${A}\n${B}"`, {}, 'b2'))).toBe('')
  expect(w.logs.some(l => l.includes('line of its log'))).toBe(false)
})

test('a judged record of an older version (applied, no branch field) is skipped, never counted malformed; an unparseable line still is', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const older = JSON.parse(judgedApplied('src/older.ts', 'proceed'))
  delete older.branch
  w.ctl.seeded.push(JSON.stringify(older))
  const why = refusal(await bash($ as never, w, `gh pr create --title T --body "${A}"`))
  expect(why).toContain('area check line')
  expect(why).not.toContain('line of the log')
  expect(why).not.toContain('src/older.ts')
  expect(refusal(await bash($ as never, w, `gh pr create --title T --body "${A}\n${B}"`, {}, 'b2'))).toBe('')
  expect(w.logs.some(l => l.includes('line of its log'))).toBe(false)
  w.ctl.seeded.push('{"v":2,"kind":"judged","applied":"pro')
  expect(refusal(await bash($ as never, w, `gh pr create --title T --body "${A}"`, {}, 'b3'))).toContain('1 line of the log')
})

test('a fold line needs Refs or Closes with the folded issue', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.seeded.push(decidedLine({ path: 'src/b.ts', decision: 'fold', issue: 41 }))
  expect(refusal(await bash($ as never, w, 'gh pr create --title T --body "Area check: src/b.ts: fold"'))).toContain(B)
  expect(refusal(await bash($ as never, w, 'gh pr create --title T --body "Area check: src/b.ts: fold, Refs #99"', {}, 'b2'))).toContain(B)
  expect(refusal(await bash($ as never, w, 'gh pr create --title T --body "Area check: src/b.ts: fold, Closes #41"', {}, 'b3'))).toBe('')
})

test("Dan's standing answers, applied without asking, count as decisions", KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.seeded.push(judgedApplied('src/c.ts', 'Proceed anyway'), judgedApplied('src/d.ts', 'Restructure first'))
  const why = refusal(await bash($ as never, w, 'gh pr create --title T --body x'))
  expect(why).toContain('Area check: src/c.ts: proceed, Dan chose Proceed anyway')
  expect(why).toContain('Area check: src/d.ts: restructure, Dan chose Restructure first')
})

test('gh pr edit without a body flag passes untouched, the log never read', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  w.ctl.prView = () => ({ exitCode: 0, stdout: JSON.stringify({ headRefName: '12-feature' }), stderr: '' })
  const cmd = 'gh pr edit 5 --add-label tech-debt'
  expect(refusal(await bash($ as never, w, cmd))).toBe('')
  expect(ranBash(w, cmd)).toBe(true)
  expect(reads(w)).toBe(0)
  // The control: the same pull request given a description without the lines is refused.
  expect(refusal(await bash($ as never, w, 'gh pr edit 5 --add-label tech-debt --body x', {}, 'b2'))).toContain(A)
})

test("gh pr edit by number reads the pull request's branch from GitHub", KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  w.ctl.prView = args => (args[0] === '5' ? { exitCode: 0, stdout: JSON.stringify({ headRefName: '12-feature' }), stderr: '' } : { exitCode: 0, stdout: JSON.stringify({ headRefName: '77-elsewhere' }), stderr: '' })
  expect(refusal(await bash($ as never, w, 'gh pr edit 5 --body x'))).toContain(A)
  expect(w.ran.some(l => l.startsWith('gh pr view 5') && l.includes('headRefName'))).toBe(true)
  expect(refusal(await bash($ as never, w, 'gh pr edit 6 --body x', {}, 'b2'))).toBe('')
})

test('gh pr merge checks the description on GitHub, through the merge helper too', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  let body = 'Just a summary'
  w.ctl.prView = () => ({ exitCode: 0, stdout: JSON.stringify({ body, headRefName: '12-feature' }), stderr: '' })
  const why = refusal(await bash($ as never, w, 'gh pr merge 5 --squash'))
  expect(why).toContain(A)
  expect(why).toContain('gh pr edit')
  expect(refusal(await bash($ as never, w, 'bash /Users/dan/.claude/hooks/lib/merge-when-ready.sh 5 --squash', {}, 'b2'))).toContain(B)
  body = `${A}\n${B}`
  expect(refusal(await bash($ as never, w, 'gh pr merge 5 --squash', {}, 'b3'))).toBe('')
})

test('gh pr merge whose description GitHub cannot give passes with one dim line', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const cmd = 'gh pr merge 5 --squash'
  expect(refusal(await bash($ as never, w, cmd))).toBe('')
  expect(ranBash(w, cmd)).toBe(true)
  expect(w.logs.some(l => l.includes('could not read') && l.includes('5'))).toBe(true)
})

test('decisions in another repository, on another branch, or on a reused branch with another merge base are not asked for', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.seeded.push(
    decidedLine({ path: 'src/a.ts', decision: 'proceed', reason: 'another repository entirely here', repo: 'dan/other' }),
    decidedLine({ path: 'src/a.ts', decision: 'proceed', reason: 'another branch entirely here', branch: '13-other' }),
    decidedLine({ path: 'src/a.ts', decision: 'proceed', reason: 'an older use of the branch', mergeBase: 'mbOLD' }),
  )
  const cmd = 'gh pr create --title T --body x'
  expect(refusal(await bash($ as never, w, cmd))).toBe('')
  expect(ranBash(w, cmd)).toBe(true)
  // The control: one decision on this repository, branch and merge base is asked for, and only it.
  w.ctl.seeded.push(decidedLine({ path: 'src/e.ts', decision: 'proceed', reason: 'this branch at this merge base' }))
  const why = refusal(await bash($ as never, w, cmd, {}, 'b2'))
  expect(why).toContain('Area check: src/e.ts: proceed, this branch at this merge base')
  expect(why).not.toContain('src/a.ts')
})

test('a merge base that cannot be read matches by branch alone, and the refusal says so', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.bases = {}
  w.ctl.seeded.push(decidedLine({ path: 'src/a.ts', decision: 'proceed', reason: 'an older use of the branch', mergeBase: 'mbOLD' }))
  const why = refusal(await bash($ as never, w, 'gh pr create --title T --body x'))
  expect(why).toContain('Area check: src/a.ts: proceed, an older use of the branch')
  expect(why).toContain('branch alone')
})

test('--head names the branch: another branch passes, an owner prefix is taken off', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const other = 'gh pr create --title T --head 99-other --body x'
  expect(refusal(await bash($ as never, w, other))).toBe('')
  expect(ranBash(w, other)).toBe(true)
  w.ctl.bases = { HEAD: 'mb123', '12-feature': 'mb123' }
  expect(refusal(await bash($ as never, w, 'gh pr create --title T --head dan:12-feature --body x', {}, 'b2'))).toContain(A)
})

test('nothing but gh pr create, edit and merge is refused, and none of them reads the log', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const commands = ['gh issue create --title x --body y', 'git push', 'gh pr view 5', 'gh pr comment 5 --body x', 'gh pr list', "echo 'gh pr create'", 'gh pr merge 5 --disable-auto']
  for (const [i, cmd] of commands.entries()) {
    const r: R = await bash($ as never, w, cmd, {}, `b${i}`)
    expect(refusal(r)).toBe('')
    expect(ranBash(w, cmd)).toBe(true)
  }
  expect(reads(w)).toBe(0)
  // The controls: gh pr create is refused in the same world, and gh pr merge --auto is a merge, checked.
  expect(refusal(await bash($ as never, w, 'gh pr create --title T --body x', {}, 'c1'))).toContain(A)
  w.ctl.prView = () => ({ exitCode: 0, stdout: JSON.stringify({ body: 'Just a summary', headRefName: '12-feature' }), stderr: '' })
  expect(refusal(await bash($ as never, w, 'gh pr merge 5 --auto --squash', {}, 'c2'))).toContain(B)
})

test('a pull request command outside a checkout passes without reading the log', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const cmd = 'cd /tmp && gh pr create --title T --body x'
  expect(refusal(await bash($ as never, w, cmd))).toBe('')
  expect(reads(w)).toBe(0)
  // The control: the same command in the checkout is refused.
  expect(refusal(await bash($ as never, w, 'gh pr create --title T --body x', {}, 'b2'))).toContain(A)
})

test('with no decisions on the branch the command passes without reading the body', KIT, async ($, on) => {
  const w = world($, on)
  const cmd = 'gh pr create --title T --body-file nowhere.md'
  expect(refusal(await bash($ as never, w, cmd))).toBe('')
  expect(ranBash(w, cmd)).toBe(true)
  expect(reads(w)).toBe(1)
})

test("the check's own failure lets the command through with one dim line, kept in the error file", KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  w.ctl.branchThrows = true
  const cmd = 'gh pr create --title T --body x'
  const r = await bash($ as never, w, cmd)
  expect(refusal(r)).toBe('')
  expect(ranBash(w, cmd)).toBe(true)
  expect(w.logs.some(l => l.includes('pull request'))).toBe(true)
  expect(w.records('/Users/dan/.claude-area-check/errors.jsonl').length).toBe(1)
  expect(said(r)).not.toContain('Area check:')
})

test('a decision with more than 1 MiB of other decisions after it is still asked for (#2143)', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.seeded.push(decidedLine({ path: 'src/old.ts', decision: 'proceed', reason: 'the oldest decision, past the old window' }))
  const filler = decidedLine({ path: 'src/x.ts', decision: 'proceed', reason: 'a decision on another branch', branch: '13-other' })
  for (let i = 0; i <= (1_048_576 * 1.5) / filler.length; i++) w.ctl.seeded.push(filler)
  seedAB(w)
  const why = refusal(await bash($ as never, w, 'gh pr create --title T --body x'))
  expect(why).toContain('Area check: src/old.ts: proceed, the oldest decision, past the old window')
  expect(why).toContain(A)
  expect(why).toContain(B)
  expect(why).not.toContain('could not')
})

test('a log read the engine cuts short is refused naming it, never read as the decisions it kept', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  w.ctl.logTruncated = true
  const why = refusal(await bash($ as never, w, `gh pr create --title T --body "${A}\n${B}"`))
  expect(why).toContain('~/.claude-area-check/log.jsonl')
  expect(why).toContain('more than could be read whole')
})

// ---- The rotated log (#2143) ----

const LINE_A = decidedLine({ path: 'src/a.ts', decision: 'proceed', reason: 'it only renames one local variable inside a function' })
const LINE_B = decidedLine({ path: 'src/b.ts', decision: 'fold', issue: 41 })

test('decisions in a settled decision file and in a log still settling are asked for, beside those in the log', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.rotated['st1.decisions.jsonl'] = [LINE_A]
  w.ctl.rotated['st2.rotating'] = [LINE_B]
  w.ctl.seeded.push(decidedLine({ path: 'src/c.ts', decision: 'proceed', reason: 'taken since the rotation' }))
  const why = refusal(await bash($ as never, w, 'gh pr create --title T --body x'))
  expect(why).toContain(A)
  expect(why).toContain(B)
  expect(why).toContain('Area check: src/c.ts: proceed, taken since the rotation')
})

test('a rotated file the read cannot open is refused naming it, never read as no decisions', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  w.ctl.rotated['st1.decisions.jsonl'] = [LINE_A]
  w.ctl.rotatedUnreadable = 'st1.decisions.jsonl'
  const why = refusal(await bash($ as never, w, `gh pr create --title T --body "${A}\n${B}"`))
  expect(why).toContain(`${DIR}/rotated/st1.decisions.jsonl: Permission denied`)
  expect(why).toContain('could not read its log')
})

test('gh pr merge reads how many decisions name the repository first, so with none it never asks GitHub', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.seeded.push(decidedLine({ path: 'src/a.ts', decision: 'proceed', reason: 'elsewhere', repo: 'dan/other' }))
  w.ctl.prView = () => ({ exitCode: 0, stdout: JSON.stringify({ body: '', headRefName: '12-feature' }), stderr: '' })
  expect(refusal(await bash($ as never, w, 'gh pr merge 5 --squash'))).toBe('')
  expect(w.ran.some(l => l.startsWith('gh pr view'))).toBe(false)
  expect(readsOf(w).length).toBe(1)
  expect(readsOf(w)[0]).not.toContain('"branch":')
})

test('gh pr merge with decisions in the repository asks GitHub for the branch, then reads that branch', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  w.ctl.prView = () => ({ exitCode: 0, stdout: JSON.stringify({ body: 'Just a summary', headRefName: '12-feature' }), stderr: '' })
  expect(refusal(await bash($ as never, w, 'gh pr merge 5 --squash'))).toContain(A)
  const at = (p: (l: string) => boolean) => w.ran.findIndex(p)
  const count = at(l => l.startsWith(`/bin/sh -c ${READ_SCRIPT} `) && !l.includes('"branch":'))
  const github = at(l => l.startsWith('gh pr view 5'))
  const branch = at(l => l.startsWith(`/bin/sh -c ${READ_SCRIPT} `) && l.includes('"branch":"12-feature"'))
  expect(count).toBeGreaterThan(-1)
  expect(github).toBeGreaterThan(count)
  expect(branch).toBeGreaterThan(github)
})

test('one Bash call reads each repository and branch once, however many pull request commands it holds', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const cmd = `gh pr create --title T --body "${A}\n${B}" && gh pr edit 12-feature --body "${A}\n${B}"`
  expect(refusal(await bash($ as never, w, cmd))).toBe('')
  expect(readsOf(w).length).toBe(1)
})

const start = async ($: unknown, w: ReturnType<typeof world>) => {
  await ($ as { session: { start: (e: never) => Promise<unknown> } }).session.start({ cwd: APP, surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
}
const rotations = (w: ReturnType<typeof world>) => w.ran.filter(l => l.startsWith(`/bin/sh -c ${ROTATE_SCRIPT} `))

test('a session start runs the rotation with its folder, stamp, bound and settle time, after writing its loaded record', KIT, async ($, on) => {
  const w = world($, on)
  await start($, w)
  const r = rotations(w)
  expect(r.length).toBe(1)
  expect((r[0] as string).endsWith(` ${DIR} ${rotationStamp(T0, 's1')} ${ROTATE_BYTES} ${SETTLE_MINUTES} "kind":"decided" "applied":`)).toBe(true)
  const loaded = w.ran.findIndex(l => !l.includes(ROTATE_SCRIPT) && l.endsWith(LOG))
  expect(loaded).toBeGreaterThan(-1)
  expect(w.ran.indexOf(r[0] as string)).toBeGreaterThan(loaded)
})

test('a rotation that fails is kept in the error file and said once, and the sweep and the warm still run', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.rotateFails = 'mv: rename log.jsonl: Operation not permitted'
  w.store['issues:dan/old'] = { at: T0 - SWEEP_MS, state: 'read', count: 0, issues: [] }
  await start($, w)
  const errors = w.records(ERRORS)
  expect(errors.length).toBe(1)
  expect(String(errors[0]?.error)).toContain('Operation not permitted')
  expect(w.logs.some(l => l.includes('could not rotate its log') && l.includes('nothing was lost'))).toBe(true)
  expect(w.store['issues:dan/old']).toBeUndefined()
  expect(ghLists(w)).toBe(1)
})

test('after a session start rotates a log over its bound, every decision in it is still asked for', KIT, async ($, on) => {
  const w = world($, on)
  w.ctl.seeded.push(decidedLine({ path: 'src/old.ts', decision: 'proceed', reason: 'the oldest decision' }))
  const filler = decidedLine({ path: 'src/x.ts', decision: 'proceed', reason: 'a decision on another branch', branch: '13-other' })
  for (let i = 0; i <= ROTATE_BYTES / filler.length; i++) w.ctl.seeded.push(filler)
  seedAB(w)
  await start($, w)
  expect(Object.keys(w.ctl.rotated)).toEqual([`${rotationStamp(T0, 's1')}.rotating`])
  expect(w.ctl.seeded.length).toBe(0)
  const why = refusal(await bash($ as never, w, 'gh pr create --title T --body x'))
  expect(why).toContain('Area check: src/old.ts: proceed, the oldest decision')
  expect(why).toContain(A)
  expect(why).toContain(B)
})
