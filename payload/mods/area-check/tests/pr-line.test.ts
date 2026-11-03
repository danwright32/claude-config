import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { APP, KIT, LOG, REASON, SLACK, bash, decide, decidedLine, edit, refusal, said, world, type R } from './world.ts'

// The area check line a pull request description carries (#1510): every file decided on the branch
// (and merge base) the pull request is made from has one line, `Area check: <file>: <decision>,
// <reason>`, checked on gh pr create, gh pr edit and gh pr merge. The decisions come from this Mac's
// log, read with grep rather than whole; a log that cannot be read is said, never read as none.

const A = 'Area check: src/a.ts: proceed, it only renames one local variable inside a function'
const B = 'Area check: src/b.ts: fold, Refs #41'
const seedAB = (w: ReturnType<typeof world>) => {
  w.ctl.seeded.push(
    decidedLine({ path: 'src/a.ts', decision: 'proceed', reason: 'it only renames one local variable inside a function' }),
    decidedLine({ path: 'src/b.ts', decision: 'fold', issue: 41 }),
  )
}
const greps = (w: ReturnType<typeof world>) => w.ran.filter(l => l.startsWith('grep ')).length
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
  const cmd = `gh pr create --title T --body "Summary\n\n- Area check: \`src/a.ts\`: proceed, it only renames one local variable inside a function\n* ${B}\n"`
  const r = await bash($ as never, w, cmd)
  expect(refusal(r)).toBe('')
  expect(ranBash(w, cmd)).toBe(true)
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
  const cmd = 'gh pr edit 5 --add-label tech-debt'
  expect(refusal(await bash($ as never, w, cmd))).toBe('')
  expect(ranBash(w, cmd)).toBe(true)
  expect(greps(w)).toBe(0)
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
  expect(greps(w)).toBe(0)
})

test('a pull request command outside a checkout passes without reading the log', KIT, async ($, on) => {
  const w = world($, on)
  seedAB(w)
  const cmd = 'cd /tmp && gh pr create --title T --body x'
  expect(refusal(await bash($ as never, w, cmd))).toBe('')
  expect(greps(w)).toBe(0)
})

test('with no decisions on the branch the command passes without reading the body', KIT, async ($, on) => {
  const w = world($, on)
  const cmd = 'gh pr create --title T --body-file nowhere.md'
  expect(refusal(await bash($ as never, w, cmd))).toBe('')
  expect(ranBash(w, cmd)).toBe(true)
  expect(greps(w)).toBe(1)
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
