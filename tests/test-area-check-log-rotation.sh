#!/bin/bash
# The area check's log rotation and its read of one branch's decisions (claude-config#2143), run
# against a REAL /bin/sh, awk, grep, mv and find on throwaway folders, with the scripts imported from
# payload/mods/area-check/hooks/prline.ts itself, never a copy. The mod's own tests run with no shell,
# so they answer for these scripts with a fake (tests/world.ts); this suite holds the scripts to what
# that fake assumes, so a script that misbehaves turns red here (L48, L58).
#   - The read finds a branch's decisions in the log, a settled decision file and a .rotating file,
#     a decision with more than 1 MiB of other decisions after it included, takes a line found in two
#     files once, matches the repository in any case and the branch exactly, and names a cut line.
#   - The read refuses with why when nothing exists or a file cannot be read, and reads the rotated
#     files when only the log is missing.
#   - The rotation moves a log over the bound aside whole and begins a new one, never below the bound,
#     and a rename that fails or a name already taken leaves the log where it was, byte for byte.
#   - The settling writes exactly the decision lines, keeps every byte of the rotated log in the
#     archive, leaves a log written in the last ten minutes alone, finishes a settle a crash cut short,
#     and refuses to put an archive over another.
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
  echo "FAIL: node is not installed, so the area check's log scripts could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-area-check-log-rotation.XXXXXX")"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
EXPECTED=22

cat >"$TMP/run.mjs" <<'JS'
import { spawnSync } from 'node:child_process'
import { mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, chmodSync, utimesSync, appendFileSync } from 'node:fs'
const [prlinePath, base] = process.argv.slice(2)
const P = await import(prlinePath)
const { READ_SCRIPT, ROTATE_SCRIPT, MARKS, SETTLE_MINUTES, readOf, repoNeedle, branchNeedle } = P
const say = (name, ok, evidence) => console.log(ok ? `PASS\t${name}` : `FAIL\t${name}\t${evidence}`)
const unmeasured = (name, why) => console.log(`UNMEASURED\t${name}\t${why}`)
let n = 0
let k = 0
const fresh = () => {
  const d = `${base}/h${k++}/.claude-area-check`
  mkdirSync(d, { recursive: true })
  return d
}
const sh = (script, args, env) => spawnSync('/bin/sh', ['-c', script, 'area-check', ...args], { encoding: 'utf8', ...(env ? { env } : {}) })
const read = (d, repo, branch) => sh(READ_SCRIPT, [d, repoNeedle(repo), branch === null ? '' : branchNeedle(branch), ...MARKS])
const rotate = (d, stamp, max, mins = SETTLE_MINUTES, env) => sh(ROTATE_SCRIPT, [d, stamp, String(max), String(mins), ...MARKS], env)
const dec = (o) => JSON.stringify({ v: 3, kind: 'decided', at: '2026-11-04T15:00:00.000Z', session: 's0', agent: null, repo: o.repo ?? 'dan/app', branch: o.branch ?? '12-feature', mergeBase: 'mb123', path: o.path, call: 'c0', decision: 'proceed', reason: o.reason ?? 'a reason' })
const loaded = (i) => JSON.stringify({ v: 1, kind: 'loaded', at: '2026-11-04T15:00:00.000Z', session: `s${i}`, cwd: '/w/app', rule: 2 })
const put = (file, lines) => writeFileSync(file, lines.map(l => l + '\n').join(''))
const paths = (r) => (r.decisions ?? []).map(x => x.path).sort().join(',')
const old = (file) => { const t = (Date.now() - (SETTLE_MINUTES + 5) * 60_000) / 1000; utimesSync(file, t, t) }
const isRoot = typeof process.getuid === 'function' && process.getuid() === 0

// ---- The read ----
{
  n++
  const d = fresh()
  mkdirSync(`${d}/rotated`)
  put(`${d}/rotated/a.decisions.jsonl`, [dec({ path: 'src/settled.ts' }), dec({ path: 'src/other.ts', branch: '13-other' })])
  put(`${d}/rotated/b.rotating`, [loaded(1), dec({ path: 'src/rotating.ts' })])
  put(`${d}/log.jsonl`, [loaded(2), dec({ path: 'src/current.ts', repo: 'Dan/App' }), dec({ path: 'src/elsewhere.ts', repo: 'dan/other' })])
  const out = read(d, 'dan/app', '12-feature')
  const r = readOf(out.stdout)
  say('the read finds the branch in a decision file, a .rotating file and the log, the repository in any case', out.status === 0 && paths(r) === 'src/current.ts,src/rotating.ts,src/settled.ts' && r.count === 4, `exit ${out.status} ${out.stderr} gave ${JSON.stringify(r)}`)
}
{
  n++
  const d = fresh()
  const filler = dec({ path: 'src/x.ts', branch: '13-other', reason: 'a decision on another branch' })
  const lines = [dec({ path: 'src/old.ts', reason: 'past the old window' })]
  for (let i = 0; i * (filler.length + 1) < 1.5 * 1_048_576; i++) lines.push(filler)
  put(`${d}/log.jsonl`, lines)
  const out = read(d, 'dan/app', '12-feature')
  const r = readOf(out.stdout)
  say('a decision with more than 1 MiB of other decisions after it is found', out.status === 0 && paths(r) === 'src/old.ts' && out.stdout.length < 4096, `exit ${out.status}, ${out.stdout.length} bytes, gave ${paths(r)}`)
}
{
  n++
  const d = fresh()
  mkdirSync(`${d}/rotated`)
  const line = dec({ path: 'src/twice.ts' })
  put(`${d}/rotated/a.decisions.jsonl`, [line])
  put(`${d}/rotated/a.rotating`, [loaded(1), line])
  put(`${d}/log.jsonl`, [loaded(2)])
  const r = readOf(read(d, 'dan/app', '12-feature').stdout)
  say('a line found in two files, as a crash mid settle leaves it, is read once', (r.decisions ?? []).length === 1 && paths(r) === 'src/twice.ts', JSON.stringify(r))
}
{
  n++
  const d = fresh()
  const cut = '{"v":3,"kind":"decided","repo":"dan/nowhere","pa'
  put(`${d}/log.jsonl`, [dec({ path: 'src/a.ts' }), cut])
  const r = readOf(read(d, 'dan/app', '12-feature').stdout)
  say('a decision line cut short is named, whatever repository it was in', JSON.stringify(r.malformed) === JSON.stringify([cut]) && paths(r) === 'src/a.ts', JSON.stringify(r))
}
{
  n++
  const d = fresh()
  put(`${d}/log.jsonl`, [dec({ path: 'src/dot.ts', branch: '1x2-feature' }), dec({ path: 'src/exact.ts', branch: '1.2-feature' })])
  const r = readOf(read(d, 'dan/app', '1.2-feature').stdout)
  say('the branch is matched exactly, never as a pattern', paths(r) === 'src/exact.ts', JSON.stringify(r))
}
{
  n++
  const d = fresh()
  const reason = 'a backslash \\ and a \\n stay as written'
  put(`${d}/log.jsonl`, [dec({ path: 'src/slash.ts', reason })])
  const r = readOf(read(d, 'dan/app', '12-feature').stdout)
  say('a line holding backslashes comes back byte for byte', r.decisions?.[0]?.reason === reason, JSON.stringify(r))
}
{
  n++
  const d = fresh()
  put(`${d}/log.jsonl`, [dec({ path: 'src/a.ts' }), dec({ path: 'src/b.ts', branch: '13-other' })])
  const out = read(d, 'dan/app', null)
  const r = readOf(out.stdout)
  say("with no branch the read gives the repository's count alone", out.status === 0 && r.count === 2 && (r.decisions ?? []).length === 0, `exit ${out.status} gave ${JSON.stringify(r)}`)
}
{
  n++
  const d = fresh()
  const out = read(d, 'dan/app', '12-feature')
  say('with no log and no rotated file the read fails, saying the log is missing', out.status === 2 && out.stderr.includes('log.jsonl: No such file or directory') && out.stdout === '', `exit ${out.status} stderr ${out.stderr} stdout ${out.stdout}`)
}
{
  n++
  const d = fresh()
  mkdirSync(`${d}/rotated`)
  put(`${d}/rotated/a.decisions.jsonl`, [dec({ path: 'src/settled.ts' })])
  const out = read(d, 'dan/app', '12-feature')
  say('with only the log missing the rotated files are read', out.status === 0 && paths(readOf(out.stdout)) === 'src/settled.ts', `exit ${out.status} ${out.stderr}`)
}
{
  n++
  const name = 'a rotated file that cannot be read fails the read, naming it and why'
  if (isRoot) unmeasured(name, 'running as root, which reads any file')
  else {
    const d = fresh()
    mkdirSync(`${d}/rotated`)
    put(`${d}/rotated/a.decisions.jsonl`, [dec({ path: 'src/settled.ts' })])
    put(`${d}/log.jsonl`, [dec({ path: 'src/current.ts' })])
    chmodSync(`${d}/rotated/a.decisions.jsonl`, 0o000)
    const out = read(d, 'dan/app', '12-feature')
    chmodSync(`${d}/rotated/a.decisions.jsonl`, 0o644)
    say(name, out.status === 2 && out.stderr.includes('rotated/a.decisions.jsonl: Permission denied') && out.stdout === '', `exit ${out.status} stderr ${out.stderr}`)
  }
}

// ---- The rotation ----
{
  n++
  const d = fresh()
  put(`${d}/log.jsonl`, [loaded(1), dec({ path: 'src/a.ts' })])
  const before = readFileSync(`${d}/log.jsonl`, 'utf8')
  const out = rotate(d, 'st1', before.length)
  say('a log at the bound is never rotated', out.status === 0 && readFileSync(`${d}/log.jsonl`, 'utf8') === before && readdirSync(`${d}/rotated`).length === 0, `exit ${out.status} ${out.stderr} rotated ${readdirSync(`${d}/rotated`)}`)
}
{
  n++
  const d = fresh()
  put(`${d}/log.jsonl`, [loaded(1), dec({ path: 'src/a.ts' })])
  const before = readFileSync(`${d}/log.jsonl`, 'utf8')
  const out = rotate(d, 'st1', before.length - 1)
  const moved = existsSync(`${d}/rotated/st1.rotating`) ? readFileSync(`${d}/rotated/st1.rotating`, 'utf8') : null
  say('a log over the bound is moved aside whole and a new empty log begun', out.status === 0 && moved === before && readFileSync(`${d}/log.jsonl`, 'utf8') === '', `exit ${out.status} ${out.stderr} moved ${moved === before}`)
}
{
  n++
  const d = fresh()
  mkdirSync(`${d}/rotated`)
  put(`${d}/log.jsonl`, [loaded(1), dec({ path: 'src/a.ts' })])
  put(`${d}/rotated/st1.rotating`, [loaded(0)])
  const before = readFileSync(`${d}/log.jsonl`, 'utf8')
  const out = rotate(d, 'st1', 1)
  say('a rotated name already taken fails, the log and the taken file left as they were', out.status !== 0 && out.stderr.includes('already exists') && readFileSync(`${d}/log.jsonl`, 'utf8') === before && readFileSync(`${d}/rotated/st1.rotating`, 'utf8') === loaded(0) + '\n', `exit ${out.status} ${out.stderr}`)
}
{
  n++
  const name = 'a rename that fails leaves the log where it was, byte for byte, and says why'
  if (isRoot) unmeasured(name, 'running as root, which writes any folder')
  else {
    const d = fresh()
    mkdirSync(`${d}/rotated`)
    put(`${d}/log.jsonl`, [loaded(1), dec({ path: 'src/a.ts' })])
    const before = readFileSync(`${d}/log.jsonl`, 'utf8')
    chmodSync(`${d}/rotated`, 0o555)
    const out = rotate(d, 'st1', 1)
    chmodSync(`${d}/rotated`, 0o755)
    say(name, out.status !== 0 && out.stderr.trim() !== '' && readFileSync(`${d}/log.jsonl`, 'utf8') === before && readdirSync(`${d}/rotated`).length === 0, `exit ${out.status} stderr ${out.stderr}`)
  }
}

// ---- The settling ----
const rotatingLines = [loaded(1), dec({ path: 'src/a.ts' }), JSON.stringify({ v: 2, kind: 'judged', repo: 'dan/app', branch: '12-feature', mergeBase: 'mb123', path: 'src/c.ts', decision: 'held', applied: 'Proceed anyway' }), loaded(2), dec({ path: 'src/b.ts', branch: '13-other' })]
const markedLines = rotatingLines.filter(l => MARKS.some(m => l.includes(m)))
{
  n++
  const d = fresh()
  mkdirSync(`${d}/rotated`)
  put(`${d}/rotated/st1.rotating`, rotatingLines)
  const before = readFileSync(`${d}/rotated/st1.rotating`, 'utf8')
  old(`${d}/rotated/st1.rotating`)
  put(`${d}/log.jsonl`, [loaded(3)])
  const out = rotate(d, 'st2', 1 << 30)
  const left = readdirSync(`${d}/rotated`).sort().join(',')
  const decisions = existsSync(`${d}/rotated/st1.decisions.jsonl`) ? readFileSync(`${d}/rotated/st1.decisions.jsonl`, 'utf8') : null
  const archive = existsSync(`${d}/rotated/st1.jsonl`) ? readFileSync(`${d}/rotated/st1.jsonl`, 'utf8') : null
  say('a rotated log past the settle time keeps every byte in the archive, its decision lines exactly in the decision file', out.status === 0 && left === 'st1.decisions.jsonl,st1.jsonl' && archive === before && decisions === markedLines.map(l => l + '\n').join(''), `exit ${out.status} ${out.stderr} left ${left}`)
}
{
  n++
  const d = fresh()
  mkdirSync(`${d}/rotated`)
  put(`${d}/rotated/st1.rotating`, rotatingLines)
  put(`${d}/log.jsonl`, [loaded(3)])
  const out = rotate(d, 'st2', 1 << 30)
  say('a rotated log written in the last ten minutes is left to settle later', out.status === 0 && readdirSync(`${d}/rotated`).join(',') === 'st1.rotating', `exit ${out.status} ${out.stderr} left ${readdirSync(`${d}/rotated`)}`)
}
{
  n++
  const d = fresh()
  mkdirSync(`${d}/rotated`)
  put(`${d}/rotated/st1.rotating`, rotatingLines)
  put(`${d}/rotated/st1.decisions.jsonl`, markedLines.slice(0, 1))
  old(`${d}/rotated/st1.rotating`)
  put(`${d}/log.jsonl`, [loaded(3)])
  const out = rotate(d, 'st2', 1 << 30)
  const decisions = readFileSync(`${d}/rotated/st1.decisions.jsonl`, 'utf8')
  say('a settle a crash cut short is finished, its decision file written whole again', out.status === 0 && decisions === markedLines.map(l => l + '\n').join('') && existsSync(`${d}/rotated/st1.jsonl`) && !existsSync(`${d}/rotated/st1.rotating`), `exit ${out.status} ${out.stderr} left ${readdirSync(`${d}/rotated`)}`)
}
{
  n++
  const d = fresh()
  mkdirSync(`${d}/rotated`)
  put(`${d}/rotated/st1.rotating`, rotatingLines)
  put(`${d}/rotated/st1.jsonl`, [loaded(0)])
  old(`${d}/rotated/st1.rotating`)
  put(`${d}/log.jsonl`, [loaded(3)])
  const out = rotate(d, 'st2', 1 << 30)
  say('an archive is never put over another: the settle fails, both left as they were', out.status !== 0 && out.stderr.includes('already exists') && readFileSync(`${d}/rotated/st1.jsonl`, 'utf8') === loaded(0) + '\n' && readFileSync(`${d}/rotated/st1.rotating`, 'utf8') === rotatingLines.map(l => l + '\n').join(''), `exit ${out.status} ${out.stderr}`)
}
{
  // The decision file is written before the rotated log becomes the archive, so a settle stopped
  // between the two renames leaves the .rotating file, which the read still reads. An mv on the PATH
  // refuses only the rename into the decision file, as a full disk or a crash there would.
  n++
  const d = fresh()
  mkdirSync(`${d}/rotated`)
  put(`${d}/rotated/st1.rotating`, rotatingLines)
  old(`${d}/rotated/st1.rotating`)
  put(`${d}/log.jsonl`, [loaded(3)])
  const shim = `${base}/shim${k}`
  mkdirSync(shim)
  writeFileSync(`${shim}/mv`, '#!/bin/sh\ncase "$2" in *.decisions.jsonl) echo "mv: refused by the test" >&2; exit 1;; esac\nexec /bin/mv "$@"\n')
  chmodSync(`${shim}/mv`, 0o755)
  const out = rotate(d, 'st2', 1 << 30, SETTLE_MINUTES, { ...process.env, PATH: `${shim}:${process.env.PATH}` })
  const r = readOf(read(d, 'dan/app', '12-feature').stdout)
  say('a settle stopped before its decision file is written leaves the rotated log, so every decision is still read', out.status !== 0 && existsSync(`${d}/rotated/st1.rotating`) && !existsSync(`${d}/rotated/st1.jsonl`) && paths(r) === 'src/a.ts,src/c.ts', `exit ${out.status} ${out.stderr} left ${readdirSync(`${d}/rotated`)} read ${JSON.stringify(r)}`)
}

// ---- The whole cycle ----
{
  n++
  const d = fresh()
  const lines = [loaded(1), dec({ path: 'src/first.ts' }), loaded(2), dec({ path: 'src/b.ts', branch: '13-other' })]
  put(`${d}/log.jsonl`, lines)
  const a = rotate(d, 'st1', 10)
  appendFileSync(`${d}/log.jsonl`, dec({ path: 'src/second.ts' }) + '\n')
  old(`${d}/rotated/st1.rotating`)
  const b = rotate(d, 'st2', 1 << 30)
  const r = readOf(read(d, 'dan/app', '12-feature').stdout)
  const archived = readFileSync(`${d}/rotated/st1.jsonl`, 'utf8').split('\n').filter(Boolean).length + readFileSync(`${d}/log.jsonl`, 'utf8').split('\n').filter(Boolean).length
  say('after a rotation and a settle every decision is still read, and every line is kept', a.status === 0 && b.status === 0 && paths(r) === 'src/first.ts,src/second.ts' && archived === lines.length + 1, `exits ${a.status} ${b.status} ${a.stderr}${b.stderr} gave ${paths(r)}, ${archived} lines kept`)
}
{
  n++
  const r = readOf('line {"v":3}\n')
  say('output that ends before the count is refused, never read as decisions', 'why' in r, JSON.stringify(r))
}
{
  n++
  const r = readOf('something else\nrepo 1\n')
  say('output holding a line the read never prints is refused', 'why' in r, JSON.stringify(r))
}
console.log(`DONE\t${n}`)
JS

out="$(node --experimental-strip-types --no-warnings "$TMP/run.mjs" "$ROOT/payload/mods/area-check/hooks/prline.ts" "$TMP" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "the log scripts ran under node" "exit=$rc out=$out"
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
