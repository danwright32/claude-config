#!/bin/bash
# The issue review's area check runner (claude-config#1511), hooks/lib/area-check-review.mjs, run
# end to end under real node, the real rotation script from payload/mods/area-check/hooks/prline.ts,
# the real issue-spool.sh and throwaway folders. Fixtures only: no check ever reads the real
# ~/.claude-area-check or the real spool. The pure counting is proved by the mod's own
# tests/weekly.test.ts; this suite proves the reading, the claim files and the spool note.
#   - The weekly line counts a fixture log, and still counts it once after a real rotation moved it
#     aside and after a real settle wrote the decision copies beside the archive.
#   - A missing log and an unreadable one are said, never counted as zero, and the line names no path.
#   - A line not yet due, in a project with no GitHub origin, reads nothing and says nothing.
#   - A file proceeded past in five sessions lands one note in a throwaway spool, a second review
#     within thirty days adds none, one after thirty days adds another, and a note that fails
#     releases its claim so the next review tries again.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so the area check runner could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-area-check-weekly.XXXXXX")"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
EXPECTED=17

cat >"$TMP/run.mjs" <<'JS'
import { spawnSync } from 'node:child_process'
import { mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, chmodSync, utimesSync, appendFileSync, statSync } from 'node:fs'
const [root, base] = process.argv.slice(2)
const { ROTATE_SCRIPT, MARKS, SETTLE_MINUTES, rotationStamp } = await import(`${root}/payload/mods/area-check/hooks/prline.ts`)
const RUNNER = `${root}/payload/hooks/lib/area-check-review.mjs`
const SPOOL = `${root}/payload/hooks/lib/issue-spool.sh`
const say = (name, ok, evidence) => console.log(ok ? `PASS\t${name}` : `FAIL\t${name}\t${String(evidence).replace(/\s+/g, ' ')}`)
const unmeasured = (name, why) => console.log(`UNMEASURED\t${name}\t${why}`)
let n = 0
let k = 0
const DAY = 24 * 60 * 60 * 1000
const T = Date.parse('2026-11-05T12:00:00.000Z')
const iso = (ms) => new Date(ms).toISOString()
let serial = 0
const rec = (o) => JSON.stringify({ ...o, n: serial++ })
const loaded = (s, at = T - DAY) => rec({ v: 1, kind: 'loaded', at: iso(at), session: s, cwd: '/w/app', rule: 3 })
const judged = (o = {}) => rec({ v: 2, kind: 'judged', at: iso(o.at ?? T - DAY), session: 's1', agent: null, repo: 'dan/app', path: 'src/a.ts', decision: o.decision ?? 'held', issues: { state: 'read', count: 2 }, matches: [], why: 'x' })
const decided = (s, at = T - DAY) => rec({ v: 3, kind: 'decided', at: iso(at), session: s, agent: null, repo: 'dan/app', branch: 'b', mergeBase: null, path: 'src/a.ts', call: `c${serial}`, decision: 'proceed', reason: 'r' })
const five = (at) => ['a', 'b', 'c', 'd', 'e'].map(s => decided(s, at))

const area = () => {
  const d = `${base}/a${k++}`
  mkdirSync(d, { recursive: true })
  return d
}
const project = (origin) => {
  const p = `${base}/p${k++}`
  mkdirSync(p, { recursive: true })
  spawnSync('git', ['init', '-q', p])
  if (origin) spawnSync('git', ['-C', p, 'remote', 'add', 'origin', origin])
  return p
}
const spoolDir = `${base}/spool`
const transcript = `${base}/t.jsonl`
writeFileSync(transcript, '')
const run = (d, p, now, lib = SPOOL, extraEnv = {}) => {
  const r = spawnSync('node', ['--experimental-strip-types', '--no-warnings', RUNNER, d, p, transcript, lib], {
    encoding: 'utf8',
    env: { ...process.env, CLAUDE_AREA_CHECK_NOW: String(now), CLAUDE_ISSUE_SPOOL_DIR: spoolDir, ...extraEnv },
  })
  let out = null
  try { out = JSON.parse(r.stdout) } catch {}
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, out }
}
const notesFor = (needle) => {
  let c = 0
  const walk = (d) => {
    if (!existsSync(d)) return
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const f = `${d}/${e.name}`
      if (e.isDirectory()) walk(f)
      else c += readFileSync(f, 'utf8').split(needle).length - 1
    }
  }
  walk(spoolDir)
  return c
}
const rotate = (d, stamp, max) => spawnSync('/bin/sh', ['-c', ROTATE_SCRIPT, 'area-check', d, stamp, String(max), String(SETTLE_MINUTES), ...MARKS], { encoding: 'utf8' })

const counted = 'loaded in 2 sessions; 2 first writes judged, 2 held; decided 1 proceed, 0 fold, 0 restructure'
{
  n++
  const d = area()
  writeFileSync(`${d}/log.jsonl`, [loaded('s1'), loaded('s2'), judged(), judged(), decided('s1')].join('\n') + '\n')
  const p = project(null)
  const r = run(d, p, T)
  say('a due line counts the log', r.status === 0 && r.out?.line?.includes(counted) && r.out.said.length === 0 && r.out.now === T, JSON.stringify(r))

  n++
  const st = rotate(d, rotationStamp(T - 2 * DAY, 's1'), 10)
  const rotated = readdirSync(`${d}/rotated`)
  const r2 = run(d, p, T)
  say('after a real rotation moved the log aside it is still counted', st.status === 0 && rotated.some(f => f.endsWith('.rotating')) && r2.out?.line === r.out?.line, `${st.stderr} ${rotated} ${JSON.stringify(r2)}`)

  n++
  for (const f of readdirSync(`${d}/rotated`)) utimesSync(`${d}/rotated/${f}`, new Date(T - DAY), new Date(Date.now() - 60 * 60 * 1000))
  const st2 = rotate(d, rotationStamp(T, 's2'), 10)
  const settled = readdirSync(`${d}/rotated`)
  const r3 = run(d, p, T)
  say('after a real settle wrote the decision copies, nothing is counted twice', st2.status === 0 && settled.some(f => f.endsWith('.decisions.jsonl')) && r3.out?.line === r.out?.line, `${st2.stderr} ${settled} ${JSON.stringify(r3)}`)

  n++
  const r4 = run(d, p, T + 9 * DAY)
  say('an archive rotated before the week is not read into the week', r4.out?.line?.includes('no load record in 7 days'), JSON.stringify(r4))
}
{
  n++
  const d = area()
  writeFileSync(`${d}/weekly-line.stamp`, String(T - DAY))
  writeFileSync(`${d}/log.jsonl`, loaded('s1') + '\n')
  const r = run(d, project(null), T)
  say('a line not due in a project with no GitHub origin says nothing', r.status === 0 && r.out?.line === null && r.out.said.length === 0, JSON.stringify(r))

  n++
  const r2 = run(d, project(null), T + 7 * DAY)
  say('seven days after the stamp the line is due again', r2.out?.line?.includes('Area check, this Mac'), JSON.stringify(r2))
}
{
  n++
  const d = area()
  const r = run(d, project(null), T)
  say('a missing log is said as never started, not as zeros', r.status === 0 && r.out?.line?.includes('the log does not exist'), JSON.stringify(r))

  n++
  writeFileSync(`${d}/log.jsonl`, loaded('s1') + '\n')
  chmodSync(`${d}/log.jsonl`, 0)
  let readable = true
  try { readFileSync(`${d}/log.jsonl`) } catch { readable = false }
  if (readable) {
    unmeasured('an unreadable log is said', 'this user can read a file with no permissions (root?), so the unreadable state cannot be made here')
  } else {
    const r2 = run(d, project(null), T)
    say('an unreadable log is said with its code and no path', r2.status === 0 && r2.out?.line?.includes('could not be read (EACCES)') && !r2.out.line.includes(base), JSON.stringify(r2))
  }
  n++
  if (readable) {
    unmeasured('an unreadable log is said when the line is not due', 'this user can read a file with no permissions')
  } else {
    writeFileSync(`${d}/weekly-line.stamp`, String(T - DAY))
    const r3 = run(d, project('https://github.com/dan/app'), T)
    say('an unreadable log is said when the line is not due, so the escalation is never silently skipped', r3.out?.line === null && r3.out.said.length === 1 && r3.out.said[0].includes('(EACCES)'), JSON.stringify(r3))
  }
  chmodSync(`${d}/log.jsonl`, 0o644)
}
{
  const d = area()
  const p = project('https://github.com/Dan/App.git')
  writeFileSync(`${d}/weekly-line.stamp`, String(T - DAY))
  writeFileSync(`${d}/log.jsonl`, [loaded('s1'), judged(), ...five(T - DAY)].join('\n') + '\n')
  const before = notesFor('src/a.ts')

  n++
  const r = run(d, p, T)
  const claims = existsSync(`${d}/escalated`) ? readdirSync(`${d}/escalated`) : []
  say('five sessions proceeding past one file land one note in the spool and one claim', r.status === 0 && notesFor('src/a.ts') === before + 1 && claims.length === 1 && r.out?.line === null, `${JSON.stringify(r)} claims=${claims}`)

  n++
  const pending = spawnSync('bash', [SPOOL, 'pending', p, transcript], { encoding: 'utf8', env: { ...process.env, CLAUDE_ISSUE_SPOOL_DIR: spoolDir } })
  say('the note is pending in this project\'s review', pending.stdout.includes('src/a.ts') && pending.stdout.includes('5 sessions'), pending.stdout + pending.stderr)

  n++
  run(d, p, T + DAY)
  say('a second review within thirty days adds no note', notesFor('src/a.ts') === before + 1, notesFor('src/a.ts'))

  n++
  appendFileSync(`${d}/log.jsonl`, [judged({ at: T + 29 * DAY }), ...five(T + 29 * DAY)].join('\n') + '\n')
  const r3 = run(d, p, T + 30 * DAY)
  say('thirty days after the claim the file is escalated again', r3.status === 0 && notesFor('src/a.ts') === before + 2 && readdirSync(`${d}/escalated`).length === 1, `${JSON.stringify(r3)} ${readdirSync(`${d}/escalated`)}`)

  n++
  say('the weekly line never names the escalated file', !(r3.out?.line ?? '').includes('src/a.ts'), r3.out?.line)
}
{
  const d = area()
  const p = project('git@github.com:dan/app.git')
  writeFileSync(`${d}/weekly-line.stamp`, String(T - DAY))
  writeFileSync(`${d}/log.jsonl`, [loaded('s1'), judged(), ...five(T - DAY)].map(l => l.replace('"src/a.ts"', '"src/b.ts"')).join('\n') + '\n')
  writeFileSync(`${base}/failing-spool.sh`, 'exit 1\n')
  const before = notesFor('src/b.ts')

  n++
  const r = run(d, p, T, `${base}/failing-spool.sh`)
  const claims = existsSync(`${d}/escalated`) ? readdirSync(`${d}/escalated`) : []
  say('a note that fails is said, by count only, and releases its claim', r.status === 0 && claims.length === 0 && r.out?.said?.length === 1 && r.out.said[0].includes('1 escalation') && !r.out.said[0].includes('src/b.ts'), `${JSON.stringify(r)} claims=${claims}`)

  n++
  run(d, p, T + 60 * 1000)
  say('the next review escalates the released file', notesFor('src/b.ts') === before + 1, notesFor('src/b.ts'))
}
{
  n++
  const r = run(area(), project(null), 'soon')
  say('a clock that is not a number refuses, never reads the real time', r.status !== 0 && r.out === null, JSON.stringify(r))
}
console.log(`DONE\t${n}`)
JS

out="$(node --experimental-strip-types --no-warnings "$TMP/run.mjs" "$ROOT" "$TMP" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "the runner checks ran under node" "exit=$rc out=$out"
else
  seen=0
  while IFS=$'\t' read -r verdict name evidence; do
    case "$verdict" in
      PASS) seen=$((seen + 1)); check "$name" ok ;;
      FAIL) seen=$((seen + 1)); check "$name" "$evidence" ;;
      UNMEASURED) seen=$((seen + 1)); echo "SUITE-PART-UNMEASURED $name: $evidence" ;;
    esac
  done <<<"$out"
  done_line="$(printf '%s\n' "$out" | grep -c "^DONE	$EXPECTED\$")"
  # Judged by the count run against the count expected, so a check that never ran is a failure (L288).
  [ "$seen" -eq "$EXPECTED" ] && [ "$done_line" -eq 1 ] && check "all $EXPECTED checks ran" ok || check "all $EXPECTED checks ran" "$seen ran: $out"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
