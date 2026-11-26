#!/bin/bash
# Tests for tools/check-mods.sh, the gate that holds every mod in payload/mods to what Claude Code
# itself accepts (claude-config#606), on fixture mods: sections 1 to 7c. Then the other mod scans
# (10 to 13: the goal tracker's notifications, each mod's dependencies, nouns that wait, and tool
# calls left in flight), and last section 14, which holds the three mods suites together.
#
# The claude binary is a stub for every case here: a test must never start a real Claude Code (L2).
# The real tree is checked with the real binary in tests/test-mods.sh alone.
#
# One of the three suites tests/test-mods.sh was cut into by measured cost (claude-config#3622,
# L315), sharing the harness tests/mods-harness.sh, which says what each holds. A comment saying
# "above" or "below", or naming a case by its number, means in whichever of the three holds it.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
# The world every mods suite runs in (tests/mods-harness.sh, claude-config#3622). Without it there is
# no check-mods.sh to run and no stub to run it with, so the suite refuses, by the agreed line.
. "$DIR/mods-harness.sh" || {
  echo "FAIL: $(basename "$0"): tests/mods-harness.sh is missing or could not be read, so there is no world to run check-mods.sh in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
# 1. Every good mod passes, and the run names how many it checked (L98: a pass over nothing reads
#    the same as a pass over everything).
M1="$TMPROOT/m1"; mkmod "$M1" one; mkmod "$M1" two
runit "$M1"
[ "$code" -eq 0 ] && check "good mods pass" ok || check "good mods pass" "exit=$code out=$out"
case "$out" in *"2 mods checked"*) check "and the count is stated" ok ;; *) check "and the count is stated" "$out" ;; esac

# 2. A mod validate refuses fails the run, by name, with the engine's reason.
M2="$TMPROOT/m2"; mkmod "$M2" fine; mkmod "$M2" broken-mod
runit "$M2"
[ "$code" -eq 1 ] && check "a refused mod fails the run" ok || check "a refused mod fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'broken-mod' | grep -q 'bad event' \
  && check "naming the mod and the reason on one line" ok || check "naming the mod and the reason on one line" "$out"
grep -q "plugin validate $M2/fine" "$LOG" && check "and the other mod was still checked" ok \
  || check "and the other mod was still checked" "$(cat "$LOG")"

# 2a. #3285: a side pane hook the validator says hears only its own mod's panes, in a mod that opens
#     none, is never asked to draw: the manual steps pane drew empty that way (Dan, 2026-11-19).
M2P="$TMPROOT/m2p"; mkmod "$M2P" deafpane-mod; mkmod "$M2P" ownpane-mod; mkmod "$M2P" starpane-mod
runit "$M2P"
[ "$code" -eq 1 ] && check "#3285 a pane hook that can hear no pane fails the run" ok \
  || check "#3285 a pane hook that can hear no pane fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'deafpane-mod' | grep -F 'ui.render{component=Pane} (default matcher key: plugin)' | grep -q "plugin: '\*'" \
  && check "#3285 naming the mod, the hook and the matcher that fixes it" ok \
  || check "#3285 naming the mod, the hook and the matcher that fixes it" "$out"
printf '%s\n' "$out" | grep -q 'ownpane-mod ok' \
  && check "#3285 a pane hook naming no owner in a mod that opens its own pane passes" ok \
  || check "#3285 a pane hook naming no owner in a mod that opens its own pane passes" "$out"
printf '%s\n' "$out" | grep -q 'starpane-mod ok' \
  && check "#3285 a pane hook naming every owner passes though the mod opens no pane" ok \
  || check "#3285 a pane hook naming every owner passes though the mod opens no pane" "$out"
! printf '%s\n' "$out" | grep 'deafpane-mod' | grep -q 'AbovePrompt' \
  && check "#3285 a band hook keyed to its own mod is not taken for a pane hook" ok \
  || check "#3285 a band hook keyed to its own mod is not taken for a pane hook" "$out"

# 3. A mod with tests has them run; one with none is not asked to run any.
M3="$TMPROOT/m3"; mkmod "$M3" redtest-mod; printf 'x\n' > "$M3/redtest-mod/hooks/a.test.ts"; mkmod "$M3" untested
runit "$M3"
[ "$code" -eq 1 ] && check "a failing mod test fails the run" ok || check "a failing mod test fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'redtest-mod' | grep -q '1 fail' \
  && check "naming the mod and the test result" ok || check "naming the mod and the test result" "$out"
! grep -q "plugin test $M3/untested" "$LOG" && check "a mod with no tests is not run through the test runner" ok \
  || check "a mod with no tests is not run through the test runner" "$(cat "$LOG")"

# 3a. A refusal from the engine carries how busy the machine was (claude-config#1083, L356). On a
#     loaded Mac mods were reported as "the file did not load" and passed alone minutes later, and
#     nothing on the line said the machine was loaded. The figure is set through the shared reader's
#     seam (payload/hooks/lib/load-average.sh), so it is this case's number and not this Mac's.
LA_HIGH="$TMPROOT/loadavg-high"; printf '#!/bin/sh\necho 41.5\n' > "$LA_HIGH"; chmod +x "$LA_HIGH"
out="$(STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC_PASS" LOAD_AVERAGE_CMD="$LA_HIGH" LOAD_AVERAGE_CORES=8 bash "$CHECK" "$M3" 2>&1)"
printf '%s\n' "$out" | grep 'redtest-mod' | grep -q 'load average 41.5 on 8 cores, more than this machine has cores' \
  && check "#1083 a failing mod test carries the load average and says the machine was busier than its cores" ok \
  || check "#1083 a failing mod test carries the load average and says the machine was busier than its cores" "$out"
out="$(STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC_PASS" LOAD_AVERAGE_CMD="$LA_HIGH" LOAD_AVERAGE_CORES=8 bash "$CHECK" "$M2" 2>&1)"
printf '%s\n' "$out" | grep 'broken-mod' | grep -q 'load average 41.5 on 8 cores' \
  && check "#1083 a mod validate refuses carries the load average too" ok \
  || check "#1083 a mod validate refuses carries the load average too" "$out"
printf '%s\n' "$out" | grep ' ok ' | grep -q 'load average' \
  && check "#1083 while a mod that passed carries none" "$out" \
  || check "#1083 while a mod that passed carries none" ok

# 3c. A refused or failed mod's WHOLE engine output is kept where it can be read after the run, and
#     its failure line names the file (#1788, L297). The line itself carries three verdict lines at
#     most, and a failure seen once (the ones behind #1778) left nothing else to diagnose from.
#     The stub here prints twelve failing lines and a last line no reason filter keeps, so only the
#     kept file can hold all of it.
FAKE3C="$TMPROOT/claude-3c"
cat > "$FAKE3C" <<'STUB'
#!/bin/bash
[ "$1" = --version ] && { echo "2.1.291 (Claude Code)"; exit 0; }
case "$1 $2" in
  "plugin validate") case "$3" in *broken*) printf 'hooks: bad event\nValidation failed\nthe last validate line\n'; exit 1 ;; esac; echo 'Validation passed' ;;
  "plugin test") case "$3" in
      *redtest*) for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'case %s fail: expected %s\n' "$i" "$i"; done
        printf 'the very last line of the engine output\n'; exit 1 ;;
    esac; printf ' 1 pass\n 0 fail\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$FAKE3C"
run3c(){   # $1 = mods dir  $2 = kept output folder -> sets out and code
  out="$(CHECK_MODS_FAILURE_OUTPUT="$2" CLAUDE_BIN="$FAKE3C" TSC_BIN="$TSC_PASS" bash "$CHECK" "$1" 2>&1)"; code=$?
}
kept_path(){   # $1 = mod name -> the path its failure line names
  local k
  k="$(printf '%s\n' "$out" | sed -n "/check-mods: $1 /s/.*whole output kept in \(.*\.log\).*/\1/p")"
  printf '%s' "${k%%$'\n'*}"
}
M3C="$TMPROOT/m3c"; mkmod "$M3C" redtest-long; printf 'x\n' > "$M3C/redtest-long/hooks/a.test.ts"
mkmod "$M3C" broken-kept; mkmod "$M3C" fine
K3C="$TMPROOT/kept-3c"
run3c "$M3C" "$K3C"
[ "$code" -eq 1 ] && check "#1788 a failing mod still fails the run" ok || check "#1788 a failing mod still fails the run" "exit=$code out=$out"
p="$(kept_path redtest-long)"
case "$p" in
  "$K3C"/*) check "#1788 a failed mod test's line names where its whole output is kept" ok ;;
  *) check "#1788 a failed mod test's line names where its whole output is kept" "named '$p'; out=$out" ;;
esac
if [ -n "$p" ] && [ -f "$p" ]; then
  grep -q 'case 12 fail: expected 12' "$p" && grep -q 'the very last line of the engine output' "$p" \
    && check "#1788 and that file holds the whole output, past the three lines the line carries" ok \
    || check "#1788 and that file holds the whole output, past the three lines the line carries" "$(cat "$p")"
else
  check "#1788 and that file holds the whole output, past the three lines the line carries" "no file at '$p'"
fi
p="$(kept_path broken-kept)"
{ [ -n "$p" ] && [ -f "$p" ] && grep -q 'the last validate line' "$p"; } \
  && check "#1788 a mod validate refuses has its whole output kept too" ok \
  || check "#1788 a mod validate refuses has its whole output kept too" "named '$p'; out=$out"
n3c="$(find "$K3C" -type f | wc -l | tr -d ' ')"
[ "$n3c" = 2 ] && check "#1788 and the mod that passed kept nothing" ok \
  || check "#1788 and the mod that passed kept nothing" "$n3c files: $(ls "$K3C" 2>&1)"
# A run where every mod passes writes nothing at all, not even the folder.
K3P="$TMPROOT/kept-3c-pass"
run3c "$M1" "$K3P"
[ "$code" -eq 0 ] && [ ! -e "$K3P" ] && check "#1788 a passing run keeps nothing" ok \
  || check "#1788 a passing run keeps nothing" "exit=$code; $(ls -R "$K3P" 2>&1)"
# Old copies are kept by age PER MOD under a size cap, never the newest 20 overall (#2959, as #2895
# did for suites, L202): one noisy mod's failures evicted every other mod's only saved one. Here a
# noisy mod has 22 old copies, a quiet mod one older still, and an oversized copy is the oldest of
# all. The noisy mod keeps its newest 3, the quiet mod its only copy, the size cap takes the
# oversized one, and a file the record did not write is never touched.
K3R="$TMPROOT/kept-3c-prune"; mkdir -p "$K3R"
for i in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
  printf 'old\n' > "$K3R/202001${i}T000000Z-noisy-plugin-test.s$i.log"
done
printf 'only\n' > "$K3R/20200105T000000Z-quiet-plugin-test.s05.log"
head -c 21000000 /dev/zero > "$K3R/20190101T000000Z-huge-plugin-test.s01.log"
printf 'mine\n' > "$K3R/notes.txt"
M3R="$TMPROOT/m3r"; mkmod "$M3R" redtest-prune; printf 'x\n' > "$M3R/redtest-prune/hooks/a.test.ts"
run3c "$M3R" "$K3R"
p="$(kept_path redtest-prune)"
{ [ -n "$p" ] && [ -f "$p" ]; } && check "#1788 this run's copy is kept" ok \
  || check "#1788 this run's copy is kept" "named '$p': $(ls "$K3R")"
[ -f "$K3R/20200105T000000Z-quiet-plugin-test.s05.log" ] \
  && check "#2959 a quiet mod's only saved failure outlives a noisy mod's many" ok \
  || check "#2959 a quiet mod's only saved failure outlives a noisy mod's many" "$(ls "$K3R")"
nnoisy="$(find "$K3R" -name '*-noisy-plugin-test.*.log' -type f | wc -l | tr -d ' ')"
[ "$nnoisy" = 3 ] && [ -f "$K3R/20200131T000000Z-noisy-plugin-test.s31.log" ] && [ -f "$K3R/20200129T000000Z-noisy-plugin-test.s29.log" ] \
  && check "#2959 a noisy mod's old copies are pruned to its own newest 3" ok \
  || check "#2959 a noisy mod's old copies are pruned to its own newest 3" "$nnoisy: $(ls "$K3R")"
[ ! -e "$K3R/20190101T000000Z-huge-plugin-test.s01.log" ] \
  && check "#2959 the folder is held under its size cap, oldest first" ok \
  || check "#2959 the folder is held under its size cap, oldest first" "$(ls "$K3R")"
[ -f "$K3R/notes.txt" ] && check "#1788 and a file the record did not write is left alone" ok \
  || check "#1788 and a file the record did not write is left alone" "$(ls "$K3R")"
# check-mods.sh and the runner keep by the same three numbers, each written in its own file, so a
# change to one alone is caught here (the lessons review of 1029c9f).
policy_of(){ grep -E '^KEPT_OUTPUT_(MAX_DAYS|PER_LABEL|MAX_KB)=' "$1" | sort; }
mods_policy="$(policy_of "$CHECK")"; runner_policy="$(policy_of "$ROOT/payload/hooks/run-all-tests.sh")"
[ "$(printf '%s\n' "$mods_policy" | wc -l | tr -d ' ')" = 3 ] && [ "$mods_policy" = "$runner_policy" ] \
  && check "#2959 check-mods.sh keeps by the runner's three numbers" ok \
  || check "#2959 check-mods.sh keeps by the runner's three numbers" "check-mods: $mods_policy; runner: $runner_policy"
# A folder that cannot be written is said on the line, never a silent loss, and the mod still fails
# with its reason.
run3c "$M3R" "/dev/null/kept"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'redtest-prune' | grep 'case 1 fail' | grep -q 'whole output could not be kept' \
  && check "#1788 a folder that cannot be written is said on the failure line" ok \
  || check "#1788 a folder that cannot be written is said on the failure line" "exit=$code out=$out"
# Set empty, the record is off, and the line says so rather than naming nothing.
run3c "$M3R" ""
printf '%s\n' "$out" | grep 'redtest-prune' | grep -q 'whole output not kept: CHECK_MODS_FAILURE_OUTPUT is empty' \
  && check "#1788 set empty, nothing is kept and the line says so" ok \
  || check "#1788 set empty, nothing is kept and the line says so" "out=$out"

# 3b. Every mod ships its own tsconfig.json (Dan, 2026-10-04, after #638): one without it gets the
#     copy Claude Code generates, which the sync then sends up as a local edit.
M3B="$TMPROOT/m3b"; mkmod "$M3B" bare-mod; rm "$M3B/bare-mod/tsconfig.json"; mkmod "$M3B" dressed
runit "$M3B"
[ "$code" -eq 1 ] && check "a mod with no tsconfig.json fails the run" ok || check "a mod with no tsconfig.json fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'bare-mod' | grep -q 'tsconfig.json' \
  && check "naming the mod and the missing file" ok || check "naming the mod and the missing file" "$out"
grep -q "plugin validate $M3B/dressed" "$LOG" && check "and the other mod was still checked" ok \
  || check "and the other mod was still checked" "$(cat "$LOG")"

# 3b2. An engine.create stand-in returns what it builds uncast (#833). A cast to never on the
#     returned object passes any shape, so a stand-in short of a member, or with a parameter the
#     real one does not accept, type checked clean until a newer Claude Code checked the return.
#     Both spellings fail, by file and line; a cast anywhere else in the hook does not.
M3S="$TMPROOT/m3s"; mkmod "$M3S" cast-one-line; mkmod "$M3S" cast-multi-line; mkmod "$M3S" uncast
mkdir -p "$M3S/cast-one-line/tests" "$M3S/cast-multi-line/tests" "$M3S/uncast/tests"
cat > "$M3S/cast-one-line/tests/register.test.ts" <<'TS'
const kit = { name: 'k', register: (on: any) => {
  on('engine.create', async ($: any, e: any, next: any) => {
    const built = await next(e)
    return { ...built, modkit: { blocked: async () => undefined } } as never
  })
} }
TS
cat > "$M3S/cast-multi-line/tests/register.test.ts" <<'TS'
const kit = { name: 'k', register: (on: any) => {
  on('engine.create', async ($: any, e: any, next: any) => {
    const built = await next(e)
    return {
      ...built,
      modkit: { blocked: async () => { await built.state.set({ a: { b: 1 } }, [] as never) } },
    } as never
  })
} }
TS
cat > "$M3S/uncast/tests/register.test.ts" <<'TS'
const kit = { name: 'k', register: (on: any) => {
  on('engine.create', async ($: any, e: any, next: any) => {
    const built = await next(e)
    return {
      ...built,
      modkit: { blocked: async () => { await built.state.set({ a: { b: 1 } }, [] as never) } },
    }
  })
  on('tool.call', () => ({ result: 'ran' }) as never)
} }
TS
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" PATH=/usr/bin:/bin TSC_BIN="$TSC_PASS" bash "$CHECK" "$M3S" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a stand-in casting what engine.create returns fails the run, with no claude command" ok \
  || check "a stand-in casting what engine.create returns fails the run, with no claude command" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q 'cast-one-line/tests/register.test.ts:4:.*as never' \
  && check "naming the one line cast by file and line" ok || check "naming the one line cast by file and line" "$out"
printf '%s\n' "$out" | grep -q 'cast-multi-line/tests/register.test.ts:4:.*as never' \
  && check "and the cast closing an object over several lines, at its return" ok \
  || check "and the cast closing an object over several lines, at its return" "$out"
! printf '%s\n' "$out" | grep -q 'uncast/' && check "while an uncast return and casts elsewhere in a hook pass" ok \
  || check "while an uncast return and casts elsewhere in a hook pass" "$out"

# 3b3. A mod test that times its subject sets its own time limit (#1016). The test runner's default,
#     5,000 ms, is a fixed number, so a test timing a list against a yardstick from the same run
#     failed at it on a busy Mac with nothing broken (L224; measured 2026-10-09). Timing is performance.now, process.hrtime
#     or Date.now arithmetic, in the test or in a helper it calls, however deep. A test with a limit
#     of its own passes, whether written in place or in a named options object; one that times
#     nothing passes, and so does one whose comment merely names a clock.
M3T="$TMPROOT/m3t"; mkmod "$M3T" timed-bare; mkmod "$M3T" timed-direct; mkmod "$M3T" timed-room
mkdir -p "$M3T/timed-bare/tests" "$M3T/timed-direct/tests" "$M3T/timed-room/tests"
cat > "$M3T/timed-bare/tests/speed.test.ts" <<'TS'
import { expect, test } from 'claude-code/testing'
const withX = { plugins: [] }
test('a list names its sessions (no clock here)', withX, async ($, on) => {
  expect(1).toBe(1)
})
const timed = async (f: () => Promise<unknown>) => {
  const t = performance.now()
  await f()
  return performance.now() - t
}
test('a list is fast against the yardstick', withX, async ($, on) => {
  const yard = await timed(async () => {})
  expect(await timed(async () => {})).toBeLessThan(yard * 10)
})
describe('nested', () => {
  test("a nested list is fast too", async () => {
    expect(await timed(async () => {})).toBeLessThan(1)
  })
})
TS
cat > "$M3T/timed-direct/tests/clock.test.ts" <<'TS'
import { expect, test } from 'claude-code/testing'
const withX = { plugins: [] }
test(`a command is bounded and quick`, withX, async ($, on) => {
  const t = Date.now()
  const bounds = [{ timeoutMs: 3000 }]
  expect(bounds[0].timeoutMs).toBe(3000)
  expect(Date.now() - t).toBeLessThan(100)
})
test('a comment naming the clock is not timing', withX, async ($, on) => {
  // performance.now() would measure the machine here, so it is not used
  expect(Date.now()).toBeGreaterThan(0)
})
TS
cat > "$M3T/timed-room/tests/room.test.ts" <<'TS'
import { expect, test } from 'claude-code/testing'
const withX = { plugins: [] }
const slow = { ...withX, timeoutMs: 60_000 }
function timed(f: () => void) {
  const t = performance.now()
  f()
  return performance.now() - t
}
const sample = () => [timed(() => {}), timed(() => {})]
test('room in place', { ...withX, timeoutMs: 120_000 }, async ($, on) => {
  expect(sample()[0]).toBeLessThan(sample()[1] * 10)
})
test('room by name', slow, async ($, on) => {
  expect(sample()[0]).toBeLessThan(1)
})
TS
# #1577: a file taking `test` from mod-kit's tests/hang-ceiling.ts has the hang ceiling on every test
# without writing it, so a timing test there passes with no timeoutMs of its own.
mkmod "$M3T" timed-shared; mkdir -p "$M3T/timed-shared/tests"
cat > "$M3T/timed-shared/tests/shared.test.ts" <<'TS'
import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
test('a list timed under the shared hang ceiling', async ($, on) => {
  const t = performance.now()
  expect(performance.now() - t).toBeLessThan(1000)
})
TS
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" PATH=/usr/bin:/bin TSC_BIN="$TSC_PASS" bash "$CHECK" "$M3T" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod test timing its subject under the fixed default limit fails the run, with no claude command" ok \
  || check "a mod test timing its subject under the fixed default limit fails the run, with no claude command" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q "timed-bare/tests/speed.test.ts:11: test 'a list is fast against the yardstick'.*through timed" \
  && check "naming the file, line and test, and the helper that times" ok \
  || check "naming the file, line and test, and the helper that times" "$out"
printf '%s\n' "$out" | grep -q "timed-bare/tests/speed.test.ts:16: test 'a nested list is fast too'" \
  && check "a test nested in a describe is found too" ok || check "a test nested in a describe is found too" "$out"
printf '%s\n' "$out" | grep -q "timed-direct/tests/clock.test.ts:3: test 'a command is bounded and quick'.*through Date.now" \
  && check "Date.now arithmetic in the test itself counts, and a timeoutMs in its body is not its limit" ok \
  || check "Date.now arithmetic in the test itself counts, and a timeoutMs in its body is not its limit" "$out"
! printf '%s\n' "$out" | grep -q "no clock here" && check "a test before the timing helper's definition is not blamed for it" ok \
  || check "a test before the timing helper's definition is not blamed for it" "$out"
! printf '%s\n' "$out" | grep -q "a comment naming the clock" && check "a comment naming a clock, and Date.now with no arithmetic, are not timing" ok \
  || check "a comment naming a clock, and Date.now with no arithmetic, are not timing" "$out"
! printf '%s\n' "$out" | grep -q "timed-room" && check "a timing test with its own limit, in place or in a named options object, passes" ok \
  || check "a timing test with its own limit, in place or in a named options object, passes" "$out"
! printf '%s\n' "$out" | grep -q "timed-shared" && check "#1577: a timing test whose test comes from mod-kit's hang ceiling passes" ok \
  || check "#1577: a timing test whose test comes from mod-kit's hang ceiling passes" "$out"
[ "$(printf '%s\n' "$out" | grep 'times its subject' | grep -c 'hang-ceiling.ts')" -eq 3 ] && check "#1577: and each names mod-kit's shared hang ceiling as the remedy" ok \
  || check "#1577: and each names mod-kit's shared hang ceiling as the remedy" "$out"
[ "$(printf '%s\n' "$out" | grep -c 'times its subject')" -eq 3 ] && check "and exactly the three bare timing tests are named" ok \
  || check "and exactly the three bare timing tests are named" "$out"

# 3c. The tsconfig.json rule needs only the filesystem, so it holds where no claude command exists
#     (CI's Linux runner) instead of hiding behind UNMEASURED (lessons review of #645).
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" PATH=/usr/bin:/bin TSC_BIN="$TSC_PASS" bash "$CHECK" "$M3B" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "with no claude command, a mod missing tsconfig.json still fails" ok \
  || check "with no claude command, a mod missing tsconfig.json still fails" "exit=$code out=$out"

# 4. Generated types are never mistaken for the mod's own tests.
M4="$TMPROOT/m4"; mkmod "$M4" typed; mkdir -p "$M4/typed/.claude-plugin/types"; printf 'x\n' > "$M4/typed/.claude-plugin/types/x.test.ts"
runit "$M4"
! grep -q "plugin test" "$LOG" && check "test files under generated types are ignored" ok \
  || check "test files under generated types are ignored" "$(cat "$LOG")"
# The same fixture, with a test file of the mod's own beside it: now it IS run, so the silence above
# was the filter and not a fixture that could never trigger a run (L159).
printf 'x\n' > "$M4/typed/hooks/own.test.ts"
runit "$M4"
grep -q "plugin test $M4/typed" "$LOG" && check "while the mod's own test file in the same folder is run" ok \
  || check "while the mod's own test file in the same folder is run" "$(cat "$LOG")"

# 4b. A mod whose only tests are .test.tsx (UI tests that mount a component) is run too, not just
#     validated (#655); and a generated .test.tsx under types/ is still not the mod's own.
M4B="$TMPROOT/m4b"; mkmod "$M4B" uionly; printf 'x\n' > "$M4B/uionly/hooks/band.test.tsx"
mkmod "$M4B" typedtsx; mkdir -p "$M4B/typedtsx/.claude-plugin/types"; printf 'x\n' > "$M4B/typedtsx/.claude-plugin/types/x.test.tsx"
runit "$M4B"
grep -q "plugin test $M4B/uionly" "$LOG" && check "a mod with only .test.tsx files is run through the test runner" ok \
  || check "a mod with only .test.tsx files is run through the test runner" "$(cat "$LOG")"
! grep -q "plugin test $M4B/typedtsx" "$LOG" && check "a .test.tsx under generated types is ignored" ok \
  || check "a .test.tsx under generated types is ignored" "$(cat "$LOG")"

# 4c. Strict types (#758), against types from this repository alone (#953). Each mod is type checked
#     in a scratch copy beside the Claude Code types pinned in tools/typescript/claude-code-types and
#     a tsconfig naming its own dependencies, as its own tsconfig.json says, and errors fail the run
#     by name and count. The compiler is a stub (L2: no real tsc) that fails any mod whose folder
#     name holds "illtyped", and logs what it was handed.
TSC="$TMPROOT/tsc"; TSC_LOG="$TMPROOT/tsc-calls"
cat > "$TSC" <<'STUB'
#!/bin/bash
echo "$*" >> "$TSC_LOG"
t="$2/.claude-plugin/types"
# What each type root said where the compiler read it (#840), the types the tsconfig named, and
# which MCP list it was handed (#953).
for f in "$t"/*/index.d.ts; do [ -f "$f" ] && echo "DEP $(basename "$(dirname "$f")"): $(head -n 1 "$f")" >> "$TSC_LOG"; done
echo "TYPES $(basename "$2"): $(tr -d ' \n' < "$t/tsconfig.json" | sed -nE 's/.*"types":\[([^]]*)\].*/\1/p')" >> "$TSC_LOG"
echo "MCP $(basename "$2"): $(cksum < "$t/claude-code-mcp/index.d.ts")" >> "$TSC_LOG"
case "$2" in *crashing*) printf 'node:internal/modules/cjs/loader:1228\n  throw err;\nError: Cannot find module typescript\n'; exit 1 ;; esac
case "$2" in *illtyped*) printf 'hooks/register.tsx(3,1): error TS2339: no such thing\nhooks/register.tsx(9,1): error TS2604: not a component\n'; exit 2 ;; esac
# The fault #953 is about, as tsc gives it: a matcher naming the mod's own MCP tool fails (TS2322)
# while the MCP list it is checked against declares tools, but not that one.
case "$2" in *mcpwatcher*)
  m="$t/claude-code-mcp/index.d.ts"
  if grep -qE '^[[:space:]]*"?mcp__[A-Za-z0-9_-]+"?:' "$m" && ! grep -q 'mcp__fixture__x' "$m"; then
    printf "hooks/register.ts(4,21): error TS2322: Type '\"mcp__fixture__x\"' is not assignable to type '\"Bash\"'.\n"; exit 2
  fi ;;
esac
# Every mod imports its own files as ./x.ts, which the tsconfig Claude Code lays does not allow, so
# real tsc refuses each one unless the check allows them itself (lessons review of #797).
case " $* " in *" --allowImportingTsExtensions "*) ;; *) printf "hooks/register.tsx(1,20): error TS5097: An import path can only end with a '.ts' extension when 'allowImportingTsExtensions' is enabled.\n"; exit 2 ;; esac
exit 0
STUB
chmod +x "$TSC"
PINNED_MCP="$ROOT/tools/typescript/claude-code-types/claude-code-mcp/index.d.ts"
pinned_mcp_sum="$(cksum < "$PINNED_MCP" 2>/dev/null)"
# A types folder as Claude Code lays one, with an MCP list naming $2 (default none).
laid(){
  mkdir -p "$1/.claude-plugin/types/claude-code-mcp"
  printf '{ "compilerOptions": { "types": ["claude-code-mcp"] } }\n' > "$1/.claude-plugin/types/tsconfig.json"
  printf 'declare module "claude-code" {\n  interface McpToolInputs {\n    %s: {}\n  }\n}\n' "${2:-mcp__laid__only}" > "$1/.claude-plugin/types/claude-code-mcp/index.d.ts"
}
# A pinned types folder in a test's own TS dir, describing build $2.
pin(){
  local p="$1/claude-code-types"
  mkdir -p "$p/claude-code" "$p/claude-code-tools" "$p/claude-code-mcp"
  printf '// Written by Claude Code %s.\nexport {}\n' "$2" > "$p/claude-code/index.d.ts"
  printf 'export {}\n' > "$p/claude-code-tools/index.d.ts"
  printf 'export {}\n' > "$p/claude-code-mcp/index.d.ts"
  printf '{ "compilerOptions": { "types": ["claude-code", "claude-code-tools", "claude-code-mcp"] } }\n' > "$p/tsconfig.json"
}
M4C="$TMPROOT/m4c"; mkmod "$M4C" illtyped; mkmod "$M4C" welltyped; mkmod "$M4C" neverloaded
mkmod "$M4C" laidhere; laid "$M4C/laidhere"
: > "$TSC_LOG"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$M4C" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod failing a strict type check fails the run" ok || check "a mod failing a strict type check fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'illtyped' | grep -q '2 errors' \
  && check "naming the mod and how many errors" ok || check "naming the mod and how many errors" "$out"
printf '%s\n' "$out" | grep 'welltyped ok' | grep -q 'types checked' \
  && check "a mod that type checks says its types were checked" ok || check "a mod that type checks says its types were checked" "$out"
printf '%s\n' "$out" | grep 'neverloaded ok' | grep -q 'types checked' && grep -q -- "-p .*/neverloaded" "$TSC_LOG" \
  && check "a mod Claude Code never laid types for is type checked all the same, against the pinned types" ok \
  || check "a mod Claude Code never laid types for is type checked all the same, against the pinned types" "$out $(cat "$TSC_LOG")"
grep -qxF "MCP laidhere: $pinned_mcp_sum" "$TSC_LOG" && [ -n "$pinned_mcp_sum" ] \
  && check "types laid inside the folder under check are replaced by the pinned ones" ok \
  || check "types laid inside the folder under check are replaced by the pinned ones" "pinned=$pinned_mcp_sum $(cat "$TSC_LOG")"
grep -qxF 'TYPES welltyped: "claude-code","claude-code-tools","claude-code-mcp"' "$TSC_LOG" \
  && check "a mod with no dependencies is checked against Claude Code's three type roots alone" ok \
  || check "a mod with no dependencies is checked against Claude Code's three type roots alone" "$(cat "$TSC_LOG")"
printf '%s\n' "$out" | grep -q "type checked against the Claude Code [0-9.]* types pinned in" \
  && check "the run names the pinned build every mod was checked against" ok || check "the run names the pinned build every mod was checked against" "$out"
# A compiler that fails without reporting any type error measured nothing, so it is said as that,
# never as "0 errors" (lessons review of #797, L11).
M4D="$TMPROOT/m4d"; mkmod "$M4D" crashing
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$M4D" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'crashing' | grep -q 'could not be type checked: the compiler exited 1 without reporting a type error: .*Cannot find module typescript' \
  && check "a compiler that fails with no type error is named as such, and fails the run" ok \
  || check "a compiler that fails with no type error is named as such, and fails the run" "exit=$code out=$out"
! printf '%s\n' "$out" | grep -q '0 errors' && check "and never claims 0 errors" ok || check "and never claims 0 errors" "$out"
# No compiler anywhere: said per mod, and not a failure, since nothing was measured (L411).
out="$(STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TMPROOT/no-such-tsc" PATH=/usr/bin:/bin bash "$CHECK" "$M4C" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "with no compiler, the type check is skipped rather than failed" ok || check "with no compiler, the type check is skipped rather than failed" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'illtyped ok' | grep -q 'types not checked: no TypeScript compiler' \
  && check "and each mod says its types were not checked, and why" ok || check "and each mod says its types were not checked, and why" "$out"
printf '%s\n' "$out" | grep -q "UNMEASURED: 4 of 4 mods' types were not checked (4 no TypeScript compiler: " \
  && check "and the run sums them up as UNMEASURED, by cause" ok || check "and the run sums them up as UNMEASURED, by cause" "$out"
printf '%s\n' "$out" | grep -q 'npm ci --prefix tools/typescript' \
  && check "with the command that installs the pinned compiler" ok || check "with the command that installs the pinned compiler" "$out"

# 4c2. No compiler named and none installed in the checkout, as in every new worktree (#1496): the
#      check installs the pinned one itself, through tools/lib/pinned-compiler.sh (whose own suite is
#      tools/test-pinned-compiler.sh), and where it genuinely cannot, its UNMEASURED line says why.
#      npm is a stub (L2): it lays the stub compiler above as the package's tsc.
TSA_REPO="$TMPROOT/ts-auto"; TSA="$TSA_REPO/tools/typescript"; mkdir -p "$TSA"; pin "$TSA" 2.1.291
cp "$ROOT/tools/typescript/package.json" "$ROOT/tools/typescript/package-lock.json" "$TSA/"
git -C "$TSA_REPO" init -q
AUTO_NPM="$TMPROOT/npm-auto"
cat > "$AUTO_NPM" <<STUB
#!/bin/bash
prefix=""; prev=""
for a in "\$@"; do [ "\$prev" = --prefix ] && prefix="\$a"; prev="\$a"; done
mkdir -p "\$prefix/node_modules/.bin" "\$prefix/node_modules/typescript/bin"
cp "$TSC" "\$prefix/node_modules/typescript/bin/tsc"
ln -s ../typescript/bin/tsc "\$prefix/node_modules/.bin/tsc"
STUB
chmod +x "$AUTO_NPM"
M4CA="$TMPROOT/m4ca"; mkmod "$M4CA" welltyped
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TS_DIR="$TSA" PINNED_TS_NPM="$TMPROOT/no-such-npm" PATH=/usr/bin:/bin bash "$CHECK" "$M4CA" 2>&1)"; code=$?
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep 'UNMEASURED' | grep -q 'npm is not installed' \
  && check "where the pinned compiler cannot be installed, the UNMEASURED line says why (#1496)" ok \
  || check "where the pinned compiler cannot be installed, the UNMEASURED line says why (#1496)" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'welltyped ok' | grep -q 'types not checked: no TypeScript compiler.*npm is not installed' \
  && check "and so does the mod's own line (#1496)" ok || check "and so does the mod's own line (#1496)" "$out"
printf '%s\n' "$out" | grep 'UNMEASURED' | grep -q 'npm ci --prefix tools/typescript' \
  && check "still naming the command that installs it by hand (#1496)" ok || check "still naming the command that installs it by hand (#1496)" "$out"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TS_DIR="$TSA" PINNED_TS_NPM="$AUTO_NPM" PATH=/usr/bin:/bin bash "$CHECK" "$M4CA" 2>&1)"; code=$?
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -q '1 of 1 mods type checked against' && ! printf '%s\n' "$out" | grep -q 'UNMEASURED: 1 of 1' \
  && check "where it can, the check installs the pinned compiler and type checks every mod with it (#1496)" ok \
  || check "where it can, the check installs the pinned compiler and type checks every mod with it (#1496)" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q 'pinned TypeScript compiler was installed' \
  && check "and says it installed it (#1496)" ok || check "and says it installed it (#1496)" "$out"
# The noun wait check gets the compiler the same way, and says why the same way when it cannot.
M4CW="$TMPROOT/m4cw"; mkdir -p "$M4CW"
TSW_REPO="$TMPROOT/ts-auto-waits"; TSW="$TSW_REPO/tools/typescript"; mkdir -p "$TSW"
cp "$ROOT/tools/typescript/package.json" "$ROOT/tools/typescript/package-lock.json" "$TSW/"
git -C "$TSW_REPO" init -q
out="$(CHECK_MODS_TS_DIR="$TSW" PINNED_TS_NPM="$TMPROOT/no-such-npm" bash "$ROOT/tools/check-mod-noun-waits.sh" "$M4CW" 2>&1)"; code=$?
[ "$code" -eq 4 ] && printf '%s\n' "$out" | grep -q 'npm is not installed' \
  && check "the noun wait check says why the pinned compiler could not be installed (#1496)" ok \
  || check "the noun wait check says why the pinned compiler could not be installed (#1496)" "exit=$code out=$out"
out="$(CHECK_MODS_TS_DIR="$TSW" PINNED_TS_NPM="$AUTO_NPM" bash "$ROOT/tools/check-mod-noun-waits.sh" "$M4CW" 2>&1)"; code=$?
[ -x "$TSW/node_modules/.bin/tsc" ] && [ -f "$TSW/node_modules/.pinned-typescript-store" ] \
  && check "and installs it where it can (#1496)" ok || check "and installs it where it can (#1496)" "exit=$code out=$out"

# 4d. The pinned compiler (#803) and its record of known type errors, and each mod's dependencies,
#     whose contracts are read from the folder under review (#840), named by each dependency's own
#     plugin.json, never from an installed copy.
M4E="$TMPROOT/m4e"; mkmod "$M4E" plain; mkmod "$M4E" illtyped-known; mkmod "$M4E" illtyped-new
TSDIR="$TMPROOT/ts"; mkdir -p "$TSDIR/node_modules/.bin"; cp "$TSC" "$TSDIR/node_modules/.bin/tsc"; pin "$TSDIR" 2.1.291
printf 'illtyped-known\thooks/register.tsx TS2339\t1\t#900\nilltyped-known\thooks/register.tsx TS2604\t1\t#900\n' > "$TSDIR/known-type-errors.tsv"
run4e(){ out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TS_DIR="$TSDIR" PATH=/usr/bin:/bin "$@" bash "$CHECK" "$M4E" 2>&1)"; code=$?; }
: > "$TSC_LOG"
run4e
printf '%s\n' "$out" | grep 'plain ok' | grep -q 'types checked' && grep -q -- "-p .*plain" "$TSC_LOG" \
  && check "a mod is type checked by the pinned compiler, found with no TSC_BIN" ok \
  || check "a mod is type checked by the pinned compiler, found with no TSC_BIN" "$out $(cat "$TSC_LOG")"
printf '%s\n' "$out" | grep 'illtyped-known ok' | grep -q '2 known type errors (#900)' \
  && check "a mod at its recorded count of type errors passes, naming the count and the issue" ok \
  || check "a mod at its recorded count of type errors passes, naming the count and the issue" "$out"
printf '%s\n' "$out" | grep -q 'illtyped-new fails a strict type check (2 errors)' \
  && check "a mod with no record that fails the type check still fails" ok \
  || check "a mod with no record that fails the type check still fails" "$out"
[ "$code" -eq 1 ] && check "and fails the run" ok || check "and fails the run" "exit=$code"
# One recorded error fixed and a new one made: the count is the same, and the new one still fails.
printf 'illtyped-known\thooks/register.tsx TS2339\t1\t#900\nilltyped-known\thooks/register.tsx TS9999\t1\t#900\n' > "$TSDIR/known-type-errors.tsv"; rm -rf "${M4E:?}/illtyped-new"
run4e
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'illtyped-known' | grep -q 'type errors not in the record.*hooks/register.tsx TS2604 (1 found, 0 recorded)' \
  && check "an error not in the record fails though the count is unchanged, naming where and how many" ok \
  || check "an error not in the record fails though the count is unchanged, naming where and how many" "exit=$code out=$out"
printf 'illtyped-known\thooks/register.tsx TS2339\t3\t#900\nilltyped-known\thooks/register.tsx TS2604\t1\t#900\n' > "$TSDIR/known-type-errors.tsv"
run4e
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep 'illtyped-known ok' | grep -q 'fewer than recorded' \
  && check "a mod under its record passes and says the record can come down" ok \
  || check "a mod under its record passes and says the record can come down" "exit=$code out=$out"
# A dependency's contract is the copy under review, never an installed one (#840): checked against
# its dependency's old contract, a mod fails a change made to both in one PR, and passes one that
# breaks it. Which file is the contract is what the dependency's plugin.json names as "types"; one
# naming none adds nothing to `$` and is left out, as the engine leaves it out. Laid types already
# in the folder, a dependency's a symbolic link to an outside file as Claude Code lays it, are
# replaced in scratch and never written through: a copy through such a link once rewrote the
# installed mod, which the sync then pushed to main (2026-10-07, while #840 was built).
M4G="$TMPROOT/m4g"; mkmod "$M4G" dependent; mkmod "$M4G" provider; mkmod "$M4G" bare
printf '{ "name": "dependent", "version": "0.1.0", "description": "x", "dependencies": ["provider", "bare"] }\n' > "$M4G/dependent/.claude-plugin/plugin.json"
printf '{ "name": "provider", "version": "0.1.0", "description": "x", "types": "./types/index.d.ts" }\n' > "$M4G/provider/.claude-plugin/plugin.json"
mkdir -p "$M4G/provider/types"; printf 'export type P = "new"\n' > "$M4G/provider/types/index.d.ts"
OUTSIDE="$TMPROOT/installed-provider.d.ts"; printf 'export type P = "installed"\n' > "$OUTSIDE"
laid "$M4G/dependent"; mkdir -p "$M4G/dependent/.claude-plugin/types/provider"; ln -s "$OUTSIDE" "$M4G/dependent/.claude-plugin/types/provider/index.d.ts"
: > "$TSC_LOG"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$M4G" 2>&1)"; code=$?
grep -q 'DEP provider: export type P = "new"' "$TSC_LOG" \
  && check "a dependency's types are read from the folder under review" ok || check "a dependency's types are read from the folder under review" "$(cat "$TSC_LOG")"
grep -qxF 'TYPES dependent: "claude-code","claude-code-tools","claude-code-mcp","provider"' "$TSC_LOG" \
  && check "the tsconfig names each dependency that has a contract, and leaves out one that has none" ok \
  || check "the tsconfig names each dependency that has a contract, and leaves out one that has none" "$(cat "$TSC_LOG")"
[ "$code" -eq 0 ] && check "and the mods pass" ok || check "and the mods pass" "exit=$code out=$out"
[ "$(cat "$OUTSIDE")" = 'export type P = "installed"' ] && [ -L "$M4G/dependent/.claude-plugin/types/provider/index.d.ts" ] \
  && check "and a laid link in the folder is never written through" ok \
  || check "and a laid link in the folder is never written through" "$(cat "$OUTSIDE")"
# A dependency this folder does not hold cannot be typed from the repository, so it fails by name.
M4H="$TMPROOT/m4h"; mkmod "$M4H" orphan
printf '{ "name": "orphan", "version": "0.1.0", "description": "x", "dependencies": ["elsewhere"] }\n' > "$M4H/orphan/.claude-plugin/plugin.json"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$M4H" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'orphan could not be type checked' | grep -q 'elsewhere' \
  && check "a dependency the folder does not hold fails the mod, naming it" ok \
  || check "a dependency the folder does not hold fails the mod, naming it" "exit=$code out=$out"
# A run leaves the checkout it read exactly as it found it, passing or failing, including when the
# folder handed to it holds links to mods rather than the mods (#2417): copied as a link, the scratch
# copy WAS the mod, so its types, tsconfig and dependency contracts were laid into the checkout as an
# untracked .claude-plugin/types/ that an unscoped stage would commit.
M4L="$TMPROOT/m4l-repo"; mkmod "$M4L" fine; mkmod "$M4L" illtyped; mkmod "$M4L" leaning
printf '{ "name": "leaning", "version": "0.1.0", "description": "x", "dependencies": ["fine"] }\n' > "$M4L/leaning/.claude-plugin/plugin.json"
printf '{ "name": "fine", "version": "0.1.0", "description": "x", "types": "./types/index.d.ts" }\n' > "$M4L/fine/.claude-plugin/plugin.json"
mkdir -p "$M4L/fine/types"; printf 'export type F = 1\n' > "$M4L/fine/types/index.d.ts"
git -C "$M4L" init -q && git -C "$M4L" add -A && git -C "$M4L" -c user.name=t -c user.email=t@t commit -q -m fixture
m4l_before="$(git -C "$M4L" status --porcelain --untracked-files=all 2>&1)"
m4l_left(){ local now; now="$(git -C "$M4L" status --porcelain --untracked-files=all 2>&1)"; [ "$now" = "$m4l_before" ] && echo ok || echo "git status was '$m4l_before' and is now '$now'"; }
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$M4L" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#2417: a failing run straight over the checkout fails" ok || check "#2417: a failing run straight over the checkout fails" "exit=$code out=$out"
check "#2417: and leaves git status as it found it" "$(m4l_left)"
M4LV="$TMPROOT/m4l-links"; mkdir -p "$M4LV"
ln -s "$M4L/fine" "$M4LV/fine"; ln -s "$M4L/leaning" "$M4LV/leaning"
: > "$TSC_LOG"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$M4LV" 2>&1)"; code=$?
[ "$code" -eq 0 ] && grep -qxF 'TYPES leaning: "claude-code","claude-code-tools","claude-code-mcp","fine"' "$TSC_LOG" \
  && check "#2417: a passing run over links to mods type checks them, dependency included" ok \
  || check "#2417: a passing run over links to mods type checks them, dependency included" "exit=$code out=$out $(cat "$TSC_LOG")"
check "#2417: and leaves git status as it found it" "$(m4l_left)"
ln -s "$M4L/illtyped" "$M4LV/illtyped"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$M4LV" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#2417: a failing run over links to mods fails" ok || check "#2417: a failing run over links to mods fails" "exit=$code out=$out"
check "#2417: and leaves git status as it found it" "$(m4l_left)"
# One mod's own folder is checked as that one mod, its dependencies read from the folder holding it
# (#3105). Handed payload/mods/<mod>, the run found no mod among the mod's own subfolders, said
# "0 mods checked" and exited 0, so a type check that checked nothing read as a pass.
: > "$TSC_LOG"
# The run names the folder as a resolved path, which collapses the doubled slash TMPDIR can leave.
M4L_AT="$(cd "$M4L" && pwd)"; M4H_AT="$(cd "$M4H" && pwd)"
runone(){ : > "$LOG"; out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$1" 2>&1)"; code=$?; }
runone "$M4L/leaning/"
[ "$code" -eq 0 ] && grep -qxF 'TYPES leaning: "claude-code","claude-code-tools","claude-code-mcp","fine"' "$TSC_LOG" \
  && printf '%s\n' "$out" | grep -q '^check-mods: leaning ok (types checked' \
  && check "#3105: one mod's own folder is checked, its dependency read beside it" ok \
  || check "#3105: one mod's own folder is checked, its dependency read beside it" "exit=$code out=$out $(cat "$TSC_LOG")"
[ "$(grep -c 'plugin validate' "$LOG")" = 1 ] && grep -q 'plugin validate .*/leaning$' "$LOG" \
  && printf '%s\n' "$out" | grep -qF "check-mods: 1 mod checked: leaning, its dependencies read from $M4L_AT" \
  && check "#3105: and only that mod, the count saying so" ok \
  || check "#3105: and only that mod, the count saying so" "out=$out calls=$(cat "$LOG")"
check "#3105: and leaves git status as it found it" "$(m4l_left)"
runone "$M4L/illtyped"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'illtyped fails a strict type check' \
  && check "#3105: one mod's own folder failing its type check fails the run" ok \
  || check "#3105: one mod's own folder failing its type check fails the run" "exit=$code out=$out"
runone "$M4H/orphan"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'orphan could not be type checked' | grep -qF "elsewhere, which is not in $M4H_AT" \
  && check "#3105: one mod whose dependency is not beside it fails, naming where it looked" ok \
  || check "#3105: one mod whose dependency is not beside it fails, naming where it looked" "exit=$code out=$out"
# The pinned types missing a file: no mod can be checked, and that is a fault in the checkout.
TSX="$TMPROOT/ts-broken"; pin "$TSX" 2.1.291; rm -f "$TSX/claude-code-types/claude-code-tools/index.d.ts"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" CHECK_MODS_TS_DIR="$TSX" bash "$CHECK" "$M4G" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'could not be type checked' | grep -q 'claude-code-tools/index.d.ts' \
  && check "pinned types missing a file fail, naming the file" ok \
  || check "pinned types missing a file fail, naming the file" "exit=$code out=$out"
# The scratch copy failing (here, a scratch folder that cannot be written) is the cause named.
# A user who can write anyway (root, in the Linux container) cannot be refused this way, so there it
# is said as unmeasured rather than read as a fault in the check (L411).
RO="$TMPROOT/ro-tmp"; mkdir -p "$RO"; chmod 500 "$RO"
if [ -w "$RO" ]; then
  echo "SUITE-PART-UNMEASURED this user can write a mode 500 folder, so a scratch copy that fails cannot be staged here"
else
  out="$(TMPDIR="$RO" STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" CHECK_MODS_TS_DIR="$TSDIR" PATH=/usr/bin:/bin bash "$CHECK" "$M4E" 2>&1)"; code=$?
  printf '%s\n' "$out" | grep 'plain ok' | grep -q 'could not copy it to scratch' \
    && printf '%s\n' "$out" | grep 'UNMEASURED: 2 of 2' | grep -q 'could not be copied to scratch: illtyped-known, plain)\.$' \
    && check "a mod whose scratch copy fails says so, and the summary counts it by cause" ok \
    || check "a mod whose scratch copy fails says so, and the summary counts it by cause" "$out"
fi
chmod 700 "$RO"

# 4e. The pinned types name the Claude Code build they came from, on their first line as the engine
#     writes it. A Mac running another build is told so, with the command that pins its types, and
#     nothing else changes: the verdict is the same on every build (#953). This replaces the record
#     of which build the types came from (#833), which the pinned types now carry themselves.
M4F="$TMPROOT/m4f"; mkmod "$M4F" verclean; mkmod "$M4F" illtyped-ver
TS4F="$TMPROOT/ts-4f"; mkdir -p "$TS4F/node_modules/.bin"; cp "$TSC" "$TS4F/node_modules/.bin/tsc"; pin "$TS4F" 2.1.291
run4f(){ out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TS_DIR="$TS4F" PATH=/usr/bin:/bin "$@" bash "$CHECK" "$M4F" 2>&1)"; code=$?; }
run4f env FAKE_CC_VERSION=2.1.291; same_out="$(printf '%s\n' "$out" | grep -v 'pinned type files are from')"; same_code=$code
printf '%s\n' "$out" | grep -q 'type checked against the Claude Code 2.1.291 types pinned in' && ! printf '%s\n' "$out" | grep -q 'pinned type files are from' \
  && check "a run on the pinned build names it, and says nothing more" ok || check "a run on the pinned build names it, and says nothing more" "$out"
run4f env FAKE_CC_VERSION=2.1.300
printf '%s\n' "$out" | grep 'pinned type files are from Claude Code 2.1.291' | grep 'not the 2.1.300 installed here' | grep -q 'refresh-claude-code-types.sh' \
  && check "a run on another build names both, with the command that pins the newer types" ok \
  || check "a run on another build names both, with the command that pins the newer types" "$out"
[ "$code" -eq "$same_code" ] && [ "$(printf '%s\n' "$out" | grep -v 'pinned type files are from')" = "$same_out" ] \
  && check "and every verdict is the same on either build" ok \
  || check "and every verdict is the same on either build" "exit $same_code then $code: $out"
# The pinned types this repository ships are held whole and clean by tools/test-refresh-claude-code-types.sh.

# 4f. The same tree gives the same verdict whatever is installed (#953). Each mod's types once came
#     from its installed copy, ~/.claude/mods/<mod>/.claude-plugin/types, whose MCP list is whatever
#     the session had connected when that copy last reloaded: manual-steps' matchers on its own tools
#     failed the check one hour and passed the next with no change to manual-steps (L461, L398).
#     The same folder is checked with that copy absent, listing the mod's own tool, and listing other
#     tools, and every verdict must be identical, and a pass.
M4I="$TMPROOT/m4i"; mkmod "$M4I" mcpwatcher; mkmod "$M4I" bystander
run4i(){   # $1 = a home folder
  : > "$TSC_LOG"
  out="$(HOME="$1" STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$M4I" 2>&1)"; code=$?
}
mkdir -p "$TMPROOT/home-absent"
laid "$TMPROOT/home-own/.claude/mods/mcpwatcher" mcp__fixture__x; laid "$TMPROOT/home-own/.claude/mods/bystander" mcp__fixture__x
laid "$TMPROOT/home-other/.claude/mods/mcpwatcher" mcp__other__y; laid "$TMPROOT/home-other/.claude/mods/bystander" mcp__other__y
verdicts=""
for h in home-absent home-own home-other; do
  run4i "$TMPROOT/$h"
  verdicts="$verdicts$h exit $code: $(printf '%s\n' "$out" | grep -v 'pinned type files are from' | paste -sd'|' -)
"
  [ "$code" -eq 0 ] && printf '%s\n' "$out" | grep 'mcpwatcher ok' | grep -q 'types checked' \
    && check "with the installed copy $h, a mod matching its own MCP tool passes the type check" ok \
    || check "with the installed copy $h, a mod matching its own MCP tool passes the type check" "exit=$code out=$out"
  grep -qxF "MCP mcpwatcher: $pinned_mcp_sum" "$TSC_LOG" \
    && check "with the installed copy $h, the compiler is handed the pinned MCP list" ok \
    || check "with the installed copy $h, the compiler is handed the pinned MCP list" "$(cat "$TSC_LOG")"
done
[ "$(printf '%s' "$verdicts" | sed 's/^[^ ]* //' | sort -u | wc -l | tr -d ' ')" = 1 ] \
  && check "and the verdict is identical with the installed copy absent, present, or listing other tools" ok \
  || check "and the verdict is identical with the installed copy absent, present, or listing other tools" "$verdicts"
# The same with the real compiler and the real pinned types, where the pinned compiler is installed
# (always on CI, #895): a mod whose tool.call matcher names its own MCP tool, as manual-steps' do.
REAL_TSC="$ROOT/tools/typescript/node_modules/.bin/tsc"
if [ ! -x "$REAL_TSC" ]; then
  echo "SUITE-PART-UNMEASURED the pinned compiler is not installed in this checkout (npm ci --prefix tools/typescript), so the real compiler's verdict was not compared across installed copies.$PINNED_WHY"
else
  M4J="$TMPROOT/m4j"; mkmod "$M4J" realmcp
  cat > "$M4J/realmcp/hooks/register.ts" <<'TS'
import type { Register } from 'claude-code'
export const register: Register = (on) => {
  on('tool.call', { tool: 'mcp__realmcp__ask' }, async ($, e, next) => next(e))
}
TS
  real=""
  for h in home-absent home-own home-other; do
    out="$(HOME="$TMPROOT/$h" CLAUDE_BIN="$FAKE" STUB_LOG="$LOG" TSC_BIN="$REAL_TSC" bash "$CHECK" "$M4J" 2>&1)"; code=$?
    real="$real$code $(printf '%s\n' "$out" | grep -v 'pinned type files are from' | paste -sd'|' -)
"
  done
  [ "$(printf '%s' "$real" | sort -u | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$real" | head -n 1 | grep -q '^0 .*realmcp ok (types checked)' \
    && check "the real compiler passes a mod matching its own MCP tool, with the same verdict whatever is installed" ok \
    || check "the real compiler passes a mod matching its own MCP tool, with the same verdict whatever is installed" "$real"
fi

# 5. A folder with no manifest is not a mod and is not counted.
M5="$TMPROOT/m5"; mkdir -p "$M5/notes"; printf 'x\n' > "$M5/notes/readme"; : > "$M5/.gitkeep"
# A run that checks no mod is not a pass (#3105, L98): it has its own exit code, says it checked
# nothing, and says how to check one mod.
runit "$M5"
[ "$code" -eq 5 ] && check "a folder holding no mod fails with its own exit code" ok \
  || check "a folder holding no mod fails with its own exit code" "exit=$code out=$out"
case "$out" in *"no mods in $M5, so nothing was checked"*) check "and says nothing was checked" ok ;; *) check "and says nothing was checked" "$out" ;; esac
case "$out" in *"hand it the mod's own folder"*"links to it and to each mod its plugin.json depends on"*) check "and says how to check one mod" ok ;; *) check "and says how to check one mod" "$out" ;; esac
[ ! -s "$LOG" ] && check "and asks claude nothing" ok || check "and asks claude nothing" "$(cat "$LOG")"

# 6. With no claude to ask, mods present is UNMEASURED: its own exit code, never a pass (L411, L490).
: > "$TSC_LOG"
out="$(TSC_LOG="$TSC_LOG" TSC_BIN="$TSC" CLAUDE_BIN="$TMPROOT/no-such-claude" bash "$CHECK" "$M1" 2>&1)"; code=$?
[ "$code" -eq 3 ] && check "no claude means exit 3, unmeasured" ok || check "no claude means exit 3, unmeasured" "exit=$code out=$out"
case "$out" in *UNMEASURED*) check "and says UNMEASURED" ok ;; *) check "and says UNMEASURED" "$out" ;; esac
# CI is this case. The strict type check needs only the pinned types and compiler, never Claude Code,
# so it runs there too (#953; before it, CI never reached it, #833), and its result is said.
grep -q -- "-p .*/one" "$TSC_LOG" && printf '%s\n' "$out" | grep -q '2 of 2 mods type checked against' \
  && check "and still type checks every mod" ok || check "and still type checks every mod" "$out $(cat "$TSC_LOG")"
M6="$TMPROOT/m6"; mkmod "$M6" illtyped-ci
out="$(TSC_LOG="$TSC_LOG" TSC_BIN="$TSC" CLAUDE_BIN="$TMPROOT/no-such-claude" bash "$CHECK" "$M6" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'illtyped-ci fails a strict type check' \
  && check "so with no claude a type error fails the run, rather than hiding behind UNMEASURED" ok \
  || check "so with no claude a type error fails the run, rather than hiding behind UNMEASURED" "exit=$code out=$out"

# 6b. Claude Code answering that hooks modules are switched off is machine state the suite cannot
#     set, so it is UNMEASURED with its own exit code and the engine's words, never a failure of
#     every mod with an empty reason (#740, L411, L11).
M6B="$TMPROOT/m6b"; mkmod "$M6B" switchedoff-a; printf 'x\n' > "$M6B/switchedoff-a/hooks/a.test.ts"
mkmod "$M6B" switchedoff-b; printf 'x\n' > "$M6B/switchedoff-b/hooks/a.test.ts"
runit "$M6B"
[ "$code" -eq 4 ] && check "mods switched off in Claude Code means exit 4, unmeasured" ok \
  || check "mods switched off in Claude Code means exit 4, unmeasured" "exit=$code out=$out"
case "$out" in *"failed claude plugin test"*) check "and no mod is reported as failing" "$out" ;; *) check "and no mod is reported as failing" ok ;; esac
printf '%s\n' "$out" | grep UNMEASURED | grep -q 'hooks modules are turned off in this process' \
  && check "and the engine's reason is carried on the UNMEASURED line" ok || check "and the engine's reason is carried on the UNMEASURED line" "$out"
# A definite failure beside it still outranks the unmeasured rest.
mkmod "$M6B" broken-too
runit "$M6B"
[ "$code" -eq 1 ] && check "a refused mod beside switched off ones still fails the run" ok \
  || check "a refused mod beside switched off ones still fails the run" "exit=$code out=$out"

# 6c. A failure carrying no verdict line names the exit code and the last lines of output, never an
#     empty reason (#740).
M6C="$TMPROOT/m6c"; mkmod "$M6C" noverdict-mod; printf 'x\n' > "$M6C/noverdict-mod/hooks/a.test.ts"
runit "$M6C"
[ "$code" -eq 1 ] && check "a test failure with no verdict line fails the run" ok || check "a test failure with no verdict line fails the run" "exit=$code out=$out"
line="$(printf '%s\n' "$out" | grep 'noverdict-mod failed')"
case "$line" in *"exit 7"*"something odd happened"*) check "naming the exit code and the last output" ok ;; *) check "naming the exit code and the last output" "$out" ;; esac

# 6d. Each Mac records the Claude Code build every mod last passed on, and a run on another build says
#     so in its first line, so a red with no commit to blame reads as Claude Code changing first
#     (#3297: 2.1.328 turned two secret guard tests red on 2026-11-18, and three builders each had
#     to prove it was not theirs). Written on a whole folder's pass alone: never on a failure, never
#     on an unmeasured run, never for one mod checked on its own.
REC="$TMPROOT/last-passed/mods-last-passed.tsv"
runrec(){   # $1 = mods dir, then env words -> sets out and code, with the record in REC
  local d="$1"; shift
  : > "$LOG"
  out="$(env CHECK_MODS_LAST_PASSED="$REC" STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC_PASS" "$@" bash "$CHECK" "$d" 2>&1)"; code=$?
}
rec_build(){ cut -f1 "$REC" 2>/dev/null; }
runrec "$M1" FAKE_CC_VERSION=2.1.300
[ "$code" -eq 0 ] && [ "$(rec_build)" = 2.1.300 ] && grep -qE '^2\.1\.300	[0-9]{4}-[0-9]{2}-[0-9]{2}$' "$REC" \
  && check "#3297 a whole folder's pass records the build and the date" ok \
  || check "#3297 a whole folder's pass records the build and the date" "exit=$code record: $(cat "$REC" 2>&1)"
case "$out" in *"Claude Code changed since"*) check "#3297 and with no record before it says nothing about a change" "$out" ;;
  *) check "#3297 and with no record before it says nothing about a change" ok ;; esac
runrec "$M1" FAKE_CC_VERSION=2.1.300
case "$out" in *"Claude Code changed since"*) check "#3297 a run on the build the mods last passed on says nothing about a change" "$out" ;;
  *) check "#3297 a run on the build the mods last passed on says nothing about a change" ok ;; esac
runrec "$M2" FAKE_CC_VERSION=2.1.301
first="$(printf '%s\n' "$out" | head -n 1)"
case "$first" in *"Claude Code changed since the mods last passed on this Mac"*"2.1.300"*"2.1.301 is installed now"*)
  check "#3297 a run on another build says so in its first line, naming both builds" ok ;;
  *) check "#3297 a run on another build says so in its first line, naming both builds" "first line: $first" ;; esac
[ "$code" -eq 1 ] && [ "$(rec_build)" = 2.1.300 ] \
  && check "#3297 a failing run leaves the record on the build that last passed" ok \
  || check "#3297 a failing run leaves the record on the build that last passed" "exit=$code record: $(cat "$REC" 2>&1)"
runrec "$M6B" FAKE_CC_VERSION=2.1.302
[ "$(rec_build)" = 2.1.300 ] && check "#3297 and so does a failure beside mods Claude Code switched off" ok \
  || check "#3297 and so does a failure beside mods Claude Code switched off" "exit=$code record: $(cat "$REC" 2>&1)"
M6D="$TMPROOT/m6d"; mkmod "$M6D" switchedoff-only; printf 'x\n' > "$M6D/switchedoff-only/hooks/a.test.ts"
runrec "$M6D" FAKE_CC_VERSION=2.1.302
[ "$code" -eq 4 ] && [ "$(rec_build)" = 2.1.300 ] && check "#3297 an unmeasured run records nothing" ok \
  || check "#3297 an unmeasured run records nothing" "exit=$code record: $(cat "$REC" 2>&1)"
runrec "$M1/one" FAKE_CC_VERSION=2.1.303
[ "$code" -eq 0 ] && [ "$(rec_build)" = 2.1.300 ] && check "#3297 one mod passing on its own records nothing" ok \
  || check "#3297 one mod passing on its own records nothing" "exit=$code record: $(cat "$REC" 2>&1)"
runrec "$M1" FAKE_CC_VERSION=2.1.304 CHECK_MODS_LAST_PASSED=
[ "$code" -eq 0 ] && [ "$(rec_build)" = 2.1.300 ] && ! printf '%s\n' "$out" | grep -q 'Claude Code changed since' \
  && check "#3297 the record set empty is off: no note and nothing written" ok \
  || check "#3297 the record set empty is off: no note and nothing written" "exit=$code record: $(cat "$REC" 2>&1) out=$out"
runrec "$M1" FAKE_CC_VERSION=2.1.305
[ "$code" -eq 0 ] && [ "$(rec_build)" = 2.1.305 ] && check "#3297 the next whole pass moves the record to its build" ok \
  || check "#3297 the next whole pass moves the record to its build" "exit=$code record: $(cat "$REC" 2>&1)"
# The line about the pinned TYPES must not read as this one (#3297): it compares against the build
# the type files were made from, and so it is printed on nearly every run.
case "$out" in *"this Mac runs Claude Code"*) check "#3297 no line about the pinned types starts like a note about the installed build" "$out" ;;
  *) check "#3297 no line about the pinned types starts like a note about the installed build" ok ;; esac

# 6e. A caller that promises a claude (CHECK_MODS_REQUIRE_CLAUDE=1, set where the pull request checks
#     install one for the mods, #3297) gets a failure, exit 6, wherever the mods could not be checked
#     with it: a missing claude, or one that answers hooks modules are switched off. Unpromised, the
#     same runs stay UNMEASURED (cases 6 and 6b), since a Mac without it is not a broken check.
out="$(CHECK_MODS_REQUIRE_CLAUDE=1 TSC_BIN="$TSC_PASS" CLAUDE_BIN="$TMPROOT/no-such-claude" bash "$CHECK" "$M1" 2>&1)"; code=$?
[ "$code" -eq 6 ] && printf '%s\n' "$out" | grep -q 'CHECK_MODS_REQUIRE_CLAUDE' \
  && check "#3297 a promised claude that is not there fails, exit 6, naming the promise" ok \
  || check "#3297 a promised claude that is not there fails, exit 6, naming the promise" "exit=$code out=$out"
out="$(CHECK_MODS_REQUIRE_CLAUDE=1 TSC_LOG="$TSC_LOG" TSC_BIN="$TSC" CLAUDE_BIN="$TMPROOT/no-such-claude" bash "$CHECK" "$M6" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'illtyped-ci fails a strict type check' \
  && check "#3297 and a definite failure beside it still fails as itself, exit 1" ok \
  || check "#3297 and a definite failure beside it still fails as itself, exit 1" "exit=$code out=$out"
runit_req(){ : > "$LOG"; out="$(CHECK_MODS_REQUIRE_CLAUDE=1 STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC_PASS" bash "$CHECK" "$1" 2>&1)"; code=$?; }
runit_req "$M6D"
[ "$code" -eq 6 ] && printf '%s\n' "$out" | grep -q 'hooks modules are turned off' \
  && check "#3297 so does one that answers hooks modules are switched off, with its words" ok \
  || check "#3297 so does one that answers hooks modules are switched off, with its words" "exit=$code out=$out"
runit_req "$M1"
[ "$code" -eq 0 ] && check "#3297 and a promised claude that checks every mod passes as before" ok \
  || check "#3297 and a promised claude that checks every mod passes as before" "exit=$code out=$out"
runit_req "$M2"
[ "$code" -eq 1 ] && check "#3297 and a mod it refuses still fails as a mod, exit 1" ok \
  || check "#3297 and a mod it refuses still fails as a mod, exit 1" "exit=$code out=$out"

# 6f. The load test runs wherever a claude is given it, CI included (#3297): it used to stand down
#     whenever CI=true, before even looking. Given a claude through MODS_CLAUDE that is not there, it
#     fails; with none given and none on PATH it is UNMEASURED for that reason, never for CI.
LOADT="$ROOT/tests/test-mods-load-engine.sh"
out="$(env -u MODS_LOAD_CLAUDE -u MODS_LOAD_REAL_ENGINE MODS_CLAUDE="$TMPROOT/no-such-claude" CI=true bash "$LOADT" 2>&1)"; code=$?
[ "$code" -ne 0 ] && printf '%s\n' "$out" | grep -q "^FAIL: .*$TMPROOT/no-such-claude" \
  && check "#3297 the load test given a claude that is not there fails, naming it" ok \
  || check "#3297 the load test given a claude that is not there fails, naming it" "exit=$code out=$out"
out="$(env -u MODS_LOAD_CLAUDE -u MODS_LOAD_REAL_ENGINE -u MODS_CLAUDE CI=true PATH=/usr/bin:/bin HOME="$TMPROOT/no-home" bash "$LOADT" 2>&1)"; code=$?
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -q '^SUITE-PART-UNMEASURED .*no claude command' \
  && ! printf '%s\n' "$out" | grep -q 'running under CI' \
  && check "#3297 under CI with no claude it is unmeasured for want of claude, not for being CI" ok \
  || check "#3297 under CI with no claude it is unmeasured for want of claude, not for being CI" "exit=$code out=$out"

# 7. A mods folder that does not exist is refused, not passed as empty.
out="$(CLAUDE_BIN="$FAKE" STUB_LOG="$LOG" TSC_BIN="$TSC_PASS" bash "$CHECK" "$TMPROOT/not-there" 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a missing mods folder is refused" ok || check "a missing mods folder is refused" "exit=$code out=$out"

# 7b. A hook on an event Claude Code's built-in security default sends past the user tier is a hook
#     that never runs (#875): the run fails naming the mod and the event, unless the hook is listed
#     with the issue deciding it. Filesystem only, so it holds where there is no claude (CI).
M7B="$TMPROOT/m7b"; KNOWN7B="$TMPROOT/known7b.tsv"; : > "$KNOWN7B"
mkmod "$M7B" stops
printf "export const register = on => {\n  on('classic.Stop', async (\$, e, next) => next(e))\n}\n" > "$M7B/stops/hooks/register.ts"
mkmod "$M7B" sections
printf "export const register = on => {\n  on(\n    'prompt.section', { name: 'memory' }, async (\$, e, next) => next(e))\n}\n" > "$M7B/sections/hooks/register.ts"
# The control: an event that reaches a mod, a comment naming a bypassed one, a method of something
# else called on, and a bypassed one in a test file, none of which is a hook of the mod's.
mkmod "$M7B" checks
printf "// was on('classic.PreToolUse', ...)\nexport const register = on => {\n  on('tool.check', async (\$, e, next) => next(e))\n  emitter.on('classic.Stop', () => {})\n}\n" > "$M7B/checks/hooks/register.ts"
printf "on('classic.Stop', () => ({}))\n" > "$M7B/checks/hooks/register.test.ts"
# A string holding // (a URL) earlier on the same line must not hide the hook after it (lessons
# review of #879): only a line that is a comment is taken out.
mkmod "$M7B" urls
printf "export const register = on => {\n  const u = 'https://example.com'; on('classic.Notification', async (\$, e, next) => next(e))\n}\n" > "$M7B/urls/hooks/register.ts"
runbp(){   # $1 = claude command  $2 = the build it says it is (the stub's own default when empty)
  : > "$LOG"
  out="$(STUB_LOG="$LOG" FAKE_CC_VERSION="${2:-}" CLAUDE_BIN="${1:-$FAKE}" CHECK_MODS_BYPASS_KNOWN="$KNOWN7B" TSC_BIN="$TSC_PASS" bash "$CHECK" "$M7B" 2>&1)"; code=$?
}
runbp
[ "$code" -eq 1 ] && check "a mod hooking a bypassed event fails the run" ok || check "a mod hooking a bypassed event fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q 'stops hooks classic.Stop, which' && check "naming the mod and the classic event" ok || check "naming the mod and the classic event" "$out"
# Since #876 both Macs keep the security default out of first place with a managed settings file, so
# such a hook runs, but only while that file is there: the message says so, not that it never runs.
printf '%s\n' "$out" | grep 'stops hooks classic.Stop, which' | grep -q 'only while' \
  && printf '%s\n' "$out" | grep 'stops hooks classic.Stop, which' | grep -q 'managed-settings.json' \
  && ! printf '%s\n' "$out" | grep 'stops hooks classic.Stop, which' | grep -q 'never runs' \
  && check "saying it runs only while the managed settings file is in place" ok \
  || check "saying it runs only while the managed settings file is in place" "$out"
printf '%s\n' "$out" | grep -q 'sections hooks prompt.section, which' && check "and a prompt event registered across lines" ok || check "and a prompt event registered across lines" "$out"
printf '%s\n' "$out" | grep -q 'urls hooks classic.Notification, which' && check "and a hook after a URL on the same line" ok || check "and a hook after a URL on the same line" "$out"
! printf '%s\n' "$out" | grep -q 'checks hooks' && check "while tool.check, a comment, another object's on and a test file are not hooks" ok \
  || check "while tool.check, a comment, another object's on and a test file are not hooks" "$out"
# The same check where no claude command exists: still a definite failure, never UNMEASURED.
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" CHECK_MODS_BYPASS_KNOWN="$KNOWN7B" PATH=/usr/bin:/bin TSC_BIN="$TSC_PASS" bash "$CHECK" "$M7B" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "with no claude command, a hook on a bypassed event still fails" ok \
  || check "with no claude command, a hook on a bypassed event still fails" "exit=$code out=$out"
# Listed with the issue deciding it: the run passes.
printf '# mod\tevent\twhy\nstops\tclassic.Stop\t#1: no event can refuse a turn end\nsections\tprompt.section\t#1: prompt content is kept from mods\nurls\tclassic.Notification\t#1: no event carries it\n' > "$KNOWN7B"
runbp
[ "$code" -eq 0 ] && check "a bypassed hook listed with its issue passes" ok || check "a bypassed hook listed with its issue passes" "exit=$code out=$out"
# A listing for a hook the mod no longer has must come down, or it would excuse the next one.
printf 'checks\tclassic.PreToolUse\t#1: moved since\n' >> "$KNOWN7B"
runbp
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'checks no longer hooks classic.PreToolUse' \
  && check "a listing for a hook that is gone fails, naming it" ok || check "a listing for a hook that is gone fails, naming it" "exit=$code out=$out"
# A listing with no reason, or one that does not begin with its issue, is refused (L675).
printf 'stops\tclassic.Stop\nsections\tprompt.section\tbecause\n' > "$KNOWN7B"
runbp
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'line(s) 1,2 need a mod, an event and a reason' \
  && check "a listing without a reason beginning with its issue is refused" ok || check "a listing without a reason beginning with its issue is refused" "exit=$code out=$out"
# The list against the build's own routes: a stub holding the same seven passes, one holding another
# fails naming it, and one holding none is said as unmeasured rather than passed.
printf 'stops\tclassic.Stop\t#1: x\nsections\tprompt.section\t#1: x\nurls\tclassic.Notification\t#1: x\n' > "$KNOWN7B"
routes_of(){ local ev; for ev in "$@"; do printf '# e("%s",(n,o,t)=>t.to(o,"append"))\n' "$ev"; done; }
# The routes the security default writes in its other shapes (#3697), as 2.1.332 writes them: a
# matcher before the handler, a handler that refuses or routes (every call reaches the tier beneath
# never), and one that routes or passes on (some calls). The builds installed on the personal
# MacBook on 2026-11-25, 2.1.330 to 2.1.332, each route all of them, so the list holds them from its
# earliest build and every stub below carries them.
other_shapes(){
  cat <<'EOF'
# e("session.append",{door:"attachment"},(n,o,t)=>t.to(o,"append")),e("session.append",{door:"hook-context"},(n,o,t)=>t.to(o,"append"))
# e("session.append",{door:"compaction"},(n,o,t)=>t.to(o,"append"))
# e("session.append",{door:"tool-message"},(n,o,t)=>Be(o)?t.to(o,"append"):t(o))
# e("session.append",{door:"note"},(n,o,t)=>t.origin.tier==="prepend"||t.origin.tier==="append"?t.to(o,"append"):t(o))
# e("telemetry.log",{to:"collector"},(n,o,t)=>t.to(o,"append"))
# e("session.identity",(n,o,t)=>t.origin.tier==="user"?se(t.origin.plugin):t.to(o,"append")).catch((n,o,t)=>t.origin.tier==="user"?se(t.origin.plugin):t.to(o,"append"))
# e("fs.stat",{resolve:!0},(n,o,t)=>t.origin.tier==="prepend"&&t.origin.plugin===n.plugin.name?t.to(o,"append"):t(o))
# e("fs.list",(n,o,t)=>t.origin.tier==="prepend"&&t.origin.plugin===n.plugin.name?t.to(o,"append"):t(o))
# e("ui.log",(n,o,t)=>t.origin.tier==="prepend"||t.origin.tier==="append"?t.to(o,"append"):t(o))
# e("env.get",(n,o,t)=>t.origin.tier==="prepend"||t.origin.tier==="append"?t.to(o,"append"):t(o))
# e("wasm.compile",(n,o,t)=>t.origin.tier==="prepend"||t.origin.tier==="append"?t.to(o,"append"):t(o))
# e("tool.describe",(n,o,t)=>N(o,t)),e("agent.offer",(n,o,t)=>N(o,t))
EOF
}
SEVEN7B=(attribution.text 'classic.*' prompt.compose prompt.context prompt.section settings.read skill.prompt)
{ cat "$FAKE"; routes_of "${SEVEN7B[@]}"; other_shapes; } > "$TMPROOT/claude-same"; chmod +x "$TMPROOT/claude-same"
{ cat "$FAKE"; routes_of "${SEVEN7B[@]}" prompt.attachment; other_shapes; } > "$TMPROOT/claude-more"; chmod +x "$TMPROOT/claude-more"
runbp "$TMPROOT/claude-same" 2.1.296
[ "$code" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'routes past the user tier' && check "a build routing the listed events passes" ok \
  || check "a build routing the listed events passes" "exit=$code out=$out"
runbp "$TMPROOT/claude-more" 2.1.296
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'not listed: prompt.attachment' && check "a build routing another event fails, naming it" ok \
  || check "a build routing another event fails, naming it" "exit=$code out=$out"
runbp "$FAKE"
printf '%s\n' "$out" | grep -q 'UNMEASURED: no security default route was found' && check "a build with no routes found is said as unmeasured" ok \
  || check "a build with no routes found is said as unmeasured" "$out"
# 2.1.299 also routes prompt.attachment and session.compact past the user tier (#1185), and builds
# before it do not, so the routes a build is held to depend on the build: each Mac and CI runs its
# own, and neither goes red for the other's. 2.1.296 is the last build measured without them.
{ cat "$FAKE"; routes_of "${SEVEN7B[@]}" prompt.attachment session.compact; other_shapes; } > "$TMPROOT/claude-nine"; chmod +x "$TMPROOT/claude-nine"
runbp "$TMPROOT/claude-nine" 2.1.299
[ "$code" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'routes past the user tier' && check "2.1.299 routing prompt.attachment and session.compact as well passes" ok \
  || check "2.1.299 routing prompt.attachment and session.compact as well passes" "exit=$code out=$out"
runbp "$TMPROOT/claude-same" 2.1.299
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'listed, no longer routed: prompt.attachment session.compact' \
  && check "a 2.1.299 that no longer routes them fails, naming both" ok || check "a 2.1.299 that no longer routes them fails, naming both" "exit=$code out=$out"
runbp "$TMPROOT/claude-nine" 2.1.296
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'not listed: prompt.attachment session.compact' \
  && printf '%s\n' "$out" | grep 'routes past the user tier' | grep -q '2\.1\.296' \
  && check "a build older than the list says routing them fails, naming the build" ok \
  || check "a build older than the list says routing them fails, naming the build" "exit=$code out=$out"
# 2.1.331 also routes session.info and session.redact (#3508), measured on the builds installed on the
# personal MacBook on 2026-11-23: 2.1.327 to 2.1.330 route the nine above and 2.1.331 these eleven.
{ cat "$FAKE"; routes_of "${SEVEN7B[@]}" prompt.attachment session.compact session.info session.redact; other_shapes; } > "$TMPROOT/claude-eleven"; chmod +x "$TMPROOT/claude-eleven"
runbp "$TMPROOT/claude-eleven" 2.1.331
[ "$code" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'routes past the user tier' && check "2.1.331 routing session.info and session.redact as well passes" ok \
  || check "2.1.331 routing session.info and session.redact as well passes" "exit=$code out=$out"
runbp "$TMPROOT/claude-nine" 2.1.331
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'listed, no longer routed: session.info session.redact' \
  && check "a 2.1.331 that no longer routes session.info and session.redact fails, naming both" ok \
  || check "a 2.1.331 that no longer routes session.info and session.redact fails, naming both" "exit=$code out=$out"
runbp "$TMPROOT/claude-nine" 2.1.330
[ "$code" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'routes past the user tier' && check "2.1.330 routing the nine passes" ok \
  || check "2.1.330 routing the nine passes" "exit=$code out=$out"
runbp "$TMPROOT/claude-eleven" 2.1.330
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'not listed: session.info session.redact' \
  && printf '%s\n' "$out" | grep 'routes past the user tier' | grep -q '2\.1\.330' \
  && check "a 2.1.330 routing session.info and session.redact fails, naming the build and both" ok \
  || check "a 2.1.330 routing session.info and session.redact fails, naming the build and both" "exit=$code out=$out"
# A later build is held to everything listed, so the next build that adds or drops a route fails on
# whichever Mac installs it first.
runbp "$TMPROOT/claude-eleven" 2.1.400
[ "$code" -eq 0 ] && check "a later build routing the same eleven passes" ok || check "a later build routing the same eleven passes" "exit=$code out=$out"
runbp "$TMPROOT/claude-nine" 2.1.400
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'listed, no longer routed: session.info session.redact' \
  && check "a later build routing only the nine fails, naming the two it lacks" ok \
  || check "a later build routing only the nine fails, naming the two it lacks" "exit=$code out=$out"
# A build whose version cannot be read is held to every route listed, and that is said.
runbp "$TMPROOT/claude-eleven" unknown
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -q 'could not read which Claude Code build' \
  && check "a build whose version cannot be read is held to every listed route, and says so" ok \
  || check "a build whose version cannot be read is held to every listed route, and says so" "exit=$code out=$out"
runbp "$TMPROOT/claude-same" unknown
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'listed, no longer routed: prompt.attachment session.compact session.info session.redact' \
  && check "and fails when it routes fewer" ok || check "and fails when it routes fewer" "exit=$code out=$out"

# 7c. Whatever build a Mac runs, and on CI with none, a hook on either route 2.1.299 added fails
#     unless listed (#1185): the file check uses every listed route, so a hook that dies on the newer
#     build is caught on a Mac still running the older one.
M7C="$TMPROOT/m7c"; KNOWN7C="$TMPROOT/known7c.tsv"; : > "$KNOWN7C"
mkmod "$M7C" compacts
printf "export const register = on => {\n  on('session.compact', async (\$, e, next) => next(e))\n  on('prompt.attachment', async (\$, e, next) => next(e))\n}\n" > "$M7C/compacts/hooks/register.ts"
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" CHECK_MODS_BYPASS_KNOWN="$KNOWN7C" PATH=/usr/bin:/bin TSC_BIN="$TSC_PASS" bash "$CHECK" "$M7C" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'compacts hooks session.compact, which' \
  && printf '%s\n' "$out" | grep -q 'compacts hooks prompt.attachment, which' \
  && check "with no claude command, hooks on session.compact and prompt.attachment fail" ok \
  || check "with no claude command, hooks on session.compact and prompt.attachment fail" "exit=$code out=$out"
out="$(STUB_LOG="$LOG" FAKE_CC_VERSION=2.1.296 CLAUDE_BIN="$TMPROOT/claude-same" CHECK_MODS_BYPASS_KNOWN="$KNOWN7C" TSC_BIN="$TSC_PASS" bash "$CHECK" "$M7C" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'compacts hooks session.compact, which' \
  && check "and on a Mac still running a build before 2.1.299" ok || check "and on a Mac still running a build before 2.1.299" "exit=$code out=$out"
# The same for the two routes 2.1.331 added (#3508): a hook on either fails with no claude command and
# on a Mac still running 2.1.330, the last build measured without them.
M7D="$TMPROOT/m7d"; KNOWN7D="$TMPROOT/known7d.tsv"; : > "$KNOWN7D"
mkmod "$M7D" redacts
printf "export const register = on => {\n  on('session.info', async (\$, e, next) => next(e))\n  on('session.redact', async (\$, e, next) => next(e))\n}\n" > "$M7D/redacts/hooks/register.ts"
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" CHECK_MODS_BYPASS_KNOWN="$KNOWN7D" PATH=/usr/bin:/bin TSC_BIN="$TSC_PASS" bash "$CHECK" "$M7D" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'redacts hooks session.info, which' \
  && printf '%s\n' "$out" | grep -q 'redacts hooks session.redact, which' \
  && check "with no claude command, hooks on session.info and session.redact fail" ok \
  || check "with no claude command, hooks on session.info and session.redact fail" "exit=$code out=$out"
out="$(STUB_LOG="$LOG" FAKE_CC_VERSION=2.1.330 CLAUDE_BIN="$TMPROOT/claude-nine" CHECK_MODS_BYPASS_KNOWN="$KNOWN7D" TSC_BIN="$TSC_PASS" bash "$CHECK" "$M7D" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'redacts hooks session.info, which' \
  && printf '%s\n' "$out" | grep -q 'redacts hooks session.redact, which' \
  && ! printf '%s\n' "$out" | grep -q 'routes past the user tier' \
  && check "and on a Mac still running 2.1.330" ok || check "and on a Mac still running 2.1.330" "exit=$code out=$out"

# 7e. The routes written in the other shapes (#3697). The security default also sends past the user
#     tier session.append rows from three doors and telemetry.log rows for the collector, each with a
#     matcher before its handler, and session.identity, whose handler refuses a user tier caller and
#     routes every other; and, for some calls only, session.append's tool-message and note doors and
#     a few engine reads. A hook on any of them is a hook that does not run (for every call, or for
#     some), and a build that adds or drops one is said like any other route.
M7E="$TMPROOT/m7e"; KNOWN7E="$TMPROOT/known7e.tsv"; : > "$KNOWN7E"
mkmod "$M7E" doors
printf "export const register = on => {\n  on('session.append', { door: 'hook-context' }, async (\$, e, next) => next(e))\n  on('session.append', { door: 'tool-result' }, async (\$, e, next) => next(e))\n  on('telemetry.log', async (\$, e, next) => next(e))\n  on('session.identity', async (\$, e, next) => next(e))\n}\n" > "$M7E/doors/hooks/register.ts"
mkmod "$M7E" alldoors
printf "export const register = on => {\n  on('session.append', async (\$, e, next) => next(e))\n}\n" > "$M7E/alldoors/hooks/register.ts"
mkmod "$M7E" notes
printf "export const register = on => {\n  on('session.append', { door: \"note\" }, async (\$, e, next) => next(e))\n  on('telemetry.log', { to: 'anthropic' }, async (\$, e, next) => next(e))\n}\n" > "$M7E/notes/hooks/register.ts"
run7e(){   # $1 = claude command  $2 = the build it says it is
  : > "$LOG"
  out="$(STUB_LOG="$LOG" FAKE_CC_VERSION="${2:-}" CLAUDE_BIN="$1" CHECK_MODS_BYPASS_KNOWN="$KNOWN7E" TSC_BIN="$TSC_PASS" bash "$CHECK" "$M7E" 2>&1)"; code=$?
}
run7e "$TMPROOT/no-such-claude"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'doors hooks session.append{door=hook-context}, which' \
  && check "a hook on the hook-context door fails, naming the door" ok || check "a hook on the hook-context door fails, naming the door" "exit=$code out=$out"
! printf '%s\n' "$out" | grep -q 'door=tool-result' && check "while the tool-result door, which reaches a mod, is not named" ok \
  || check "while the tool-result door, which reaches a mod, is not named" "$out"
printf '%s\n' "$out" | grep -q 'doors hooks telemetry.log, which' && check "a hook on telemetry.log with no matcher fails, since it hears the collector's rows too" ok \
  || check "a hook on telemetry.log with no matcher fails, since it hears the collector's rows too" "$out"
printf '%s\n' "$out" | grep -q 'doors hooks session.identity, which' && check "a hook on session.identity fails" ok \
  || check "a hook on session.identity fails" "$out"
printf '%s\n' "$out" | grep 'alldoors hooks session.append, which' | grep -q 'session.append{door=compaction}' \
  && check "a hook on every door fails, naming the doors it is passed over on" ok \
  || check "a hook on every door fails, naming the doors it is passed over on" "$out"
printf '%s\n' "$out" | grep 'notes hooks session.append{door=note}, which' | grep -q 'some of its calls' \
  && check "a hook on the note door fails as passed over for some of its calls" ok \
  || check "a hook on the note door fails as passed over for some of its calls" "$out"
! printf '%s\n' "$out" | grep -q 'notes hooks telemetry.log' && check "while telemetry.log rows for another sink are not named" ok \
  || check "while telemetry.log rows for another sink are not named" "$out"
# Listed with the issue deciding it, keyed by the door: the run passes.
printf 'doors\tsession.append{door=hook-context}\t#1: x\ndoors\ttelemetry.log\t#1: x\ndoors\tsession.identity\t#1: x\nalldoors\tsession.append\t#1: x\nnotes\tsession.append{door=note}\t#1: x\n' > "$KNOWN7E"
run7e "$TMPROOT/no-such-claude"
! printf '%s\n' "$out" | grep -q ' hooks .*, which' && ! printf '%s\n' "$out" | grep -q 'no longer hooks' \
  && check "hooks on those routes listed by door pass the hook check" ok || check "hooks on those routes listed by door pass the hook check" "exit=$code out=$out"
# The build's own routes, read in every shape: a stub writing them all passes on 2.1.332 and 2.1.330.
run7e "$TMPROOT/claude-eleven" 2.1.332
[ "$code" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'routes past the user tier' && ! printf '%s\n' "$out" | grep -q 'documentation names' \
  && check "a 2.1.332 writing every route in every shape passes" ok || check "a 2.1.332 writing every route in every shape passes" "exit=$code out=$out"
run7e "$TMPROOT/claude-nine" 2.1.330
[ "$code" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'routes past the user tier' \
  && check "a 2.1.330 writing the nine and the other shapes passes" ok || check "a 2.1.330 writing the nine and the other shapes passes" "exit=$code out=$out"
# A new route in the matcher shape, which the plain reading leaves out, is said as not listed.
{ cat "$TMPROOT/claude-eleven"; printf '# e("session.append",{door:"queue"},(n,o,t)=>t.to(o,"append"))\n'; } > "$TMPROOT/claude-queue"; chmod +x "$TMPROOT/claude-queue"
run7e "$TMPROOT/claude-queue" 2.1.332
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'not listed: session.append{door=queue}' \
  && check "a build routing another door fails, naming it" ok || check "a build routing another door fails, naming it" "exit=$code out=$out"
# A listed route in the matcher shape the build no longer writes is said, and the documentation's
# naming it is said on a line of its own.
{ cat "$FAKE"; routes_of "${SEVEN7B[@]}" prompt.attachment session.compact session.info session.redact; other_shapes | grep -v 'telemetry.log'; } > "$TMPROOT/claude-notel"; chmod +x "$TMPROOT/claude-notel"
run7e "$TMPROOT/claude-notel" 2.1.332
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'listed, no longer routed: telemetry.log{to=collector}' \
  && check "a build no longer routing telemetry.log for the collector fails, naming it" ok \
  || check "a build no longer routing telemetry.log for the collector fails, naming it" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q '^check-mods: the documentation names telemetry.log as a route' \
  && check "and the documentation's naming it is said on a line of its own" ok \
  || check "and the documentation's naming it is said on a line of its own" "$out"
# session.identity written with other names, a handler refusing or routing, is still every call.
{ cat "$FAKE"; routes_of "${SEVEN7B[@]}" prompt.attachment session.compact session.info session.redact; other_shapes | grep -v 'session.identity'
  printf '# x("session.identity",(a,b,c)=>c.origin.tier==="user"?Q(c.origin.plugin):c.to(b,"append"))\n'; } > "$TMPROOT/claude-names"; chmod +x "$TMPROOT/claude-names"
run7e "$TMPROOT/claude-names" 2.1.332
[ "$code" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'routes past the user tier' \
  && check "session.identity written with other names is still read as every call" ok \
  || check "session.identity written with other names is still read as every call" "exit=$code out=$out"
# A door that stops passing its calls on, routed for every call, moves list: both lists say so.
{ cat "$FAKE"; routes_of "${SEVEN7B[@]}" prompt.attachment session.compact session.info session.redact; other_shapes | grep -v 'tool-message'
  printf '# e("session.append",{door:"tool-message"},(n,o,t)=>t.to(o,"append"))\n'; } > "$TMPROOT/claude-moved"; chmod +x "$TMPROOT/claude-moved"
run7e "$TMPROOT/claude-moved" 2.1.332
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'routes past the user tier:' | grep -q 'not listed: session.append{door=tool-message}' \
  && printf '%s\n' "$out" | grep 'for some of their calls' | grep -q 'listed, no longer routed: session.append{door=tool-message}' \
  && check "a door moving from some calls to every call is said by both lists" ok \
  || check "a door moving from some calls to every call is said by both lists" "exit=$code out=$out"
# A handler that routes or hands the tier beneath to another function routes only some calls.
{ cat "$TMPROOT/claude-eleven"; printf '# e("agent.spawn",(n,o,t)=>o.x?t.to(o,"append"):N(o,t))\n'; } > "$TMPROOT/claude-passes"; chmod +x "$TMPROOT/claude-passes"
run7e "$TMPROOT/claude-passes" 2.1.332
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'for some of their calls' | grep -q 'not listed: agent.spawn' \
  && check "a handler handing the tier beneath on is read as some calls" ok \
  || check "a handler handing the tier beneath on is read as some calls" "exit=$code out=$out"

# 10. The goal tracker sends the permission, question and "What's next?" notifications itself (Dan,
#     2026-10-04, #612), so no settings hook may send one too: Dan would get every one twice. Read
#     from the hooks block the payload installs, never a copy of it.
HOOKS_JSON="$ROOT/payload/settings.hooks.json"
IFS= read -r -d '' dupes_prog <<'PY' || true
import json, sys
d = json.load(open(sys.argv[1]))
hooks = d.get("hooks", d)
found = []
for event in ("PermissionRequest", "Notification"):
    for group in hooks.get(event) or []:
        for h in group.get("hooks") or []:
            if "terminal-notifier" in str(h.get("command", "")):
                found.append(f"{event} ({group.get('matcher', '')!r})")
print(" ".join(found))
PY
dupes="$(python3 -c "$dupes_prog" "$HOOKS_JSON" </dev/null 2>&1)"; code=$?
[ "$code" -eq 0 ] && [ -z "$dupes" ] && check "no settings hook sends a notification the goal tracker sends" ok \
  || check "no settings hook sends a notification the goal tracker sends" "exit=$code found=$dupes"
grep -q 'terminal-notifier' "$ROOT/payload/mods/goal-tracker/hooks/register.tsx" \
  && check "and the goal tracker is what sends them" ok || check "and the goal tracker is what sends them" "no terminal-notifier call in goal-tracker"

# 11. Every dependency a mod's plugin.json lists is one its hooks use (#694: the job watcher listed
#     mod-kit and never used it): a noun the dependency's contract declares reached, or its name.
DEPS="$ROOT/tools/check-mod-dependencies.sh"
M11="$TMPROOT/m11"
mkdepmod(){   # $1 = mods dir  $2 = name  $3 = dependencies as a JSON list  $4 = the hooks module's source
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks"
  printf '{ "name": "%s", "version": "0.1.0", "description": "t", "dependencies": %s }\n' "$2" "$3" > "$1/$2/.claude-plugin/plugin.json"
  printf '%s\n' "$4" > "$1/$2/hooks/register.ts"
}
mkdepmod "$M11" kit '[]' "export const register = () => {}"
mkdir -p "$M11/kit/types"
printf '{ "name": "kit", "version": "0.1.0", "description": "t", "types": "./types/index.d.ts" }\n' > "$M11/kit/.claude-plugin/plugin.json"
printf 'export type Kit = { go: () => Promise<void> }\ndeclare module "claude-code" {\n  interface EngineInterface {\n    kit: Kit\n  }\n}\n' > "$M11/kit/types/index.d.ts"
mkdepmod "$M11" by-noun '["kit"]' "export const register = on => { on('tool.call', async (\$, e, next) => { await \$.kit.go(); return next(e) }) }"
mkdepmod "$M11" by-name '["kit"]' "export const register = on => { on('ui.press', { plugin: 'kit' }, async (\$, e, next) => next(e)) }"
out="$(bash "$DEPS" "$M11" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a dependency reached by its noun or named passes" ok || check "a dependency reached by its noun or named passes" "exit=$code out=$out"
case "$out" in *"3 mods checked"*) check "and the count is stated" ok ;; *) check "and the count is stated" "$out" ;; esac
# A mod that lists it and never uses it; its own test file reaching the noun does not count.
mkdepmod "$M11" lazy '["kit"]' "export const register = on => { on('tool.call', async (\$, e, next) => next(e)) }"
printf "import { test } from 'claude-code/testing'\n// \$.kit.go() in a stand in\n" > "$M11/lazy/hooks/a.test.ts"
out="$(bash "$DEPS" "$M11" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a dependency the mod never uses fails the run" ok || check "a dependency the mod never uses fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'lazy lists kit' | grep -q 'lazy/.claude-plugin/plugin.json' \
  && check "naming the mod, the dependency and the file to change" ok || check "naming the mod, the dependency and the file to change" "$out"
! printf '%s\n' "$out" | grep -qE '(by-noun|by-name) lists' \
  && check "and the mods that use it are not named" ok || check "and the mods that use it are not named" "$out"
rm -rf "$M11/lazy"
mkdepmod "$M11" orphan '["not-a-mod"]' "export const register = () => {}"
out="$(bash "$DEPS" "$M11" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'orphan lists not-a-mod under dependencies, which is no mod' \
  && check "a dependency that is no mod in the folder is reported, never passed" ok \
  || check "a dependency that is no mod in the folder is reported, never passed" "exit=$code out=$out"
rm -rf "$M11/orphan"
# A dependency whose contract cannot be read is said as such, never scored as declaring no noun,
# which would accuse a mod that reaches one.
M11B="$TMPROOT/m11b"
mkdepmod "$M11B" kit '[]' "export const register = () => {}"
printf '{ "name": "kit", "version": "0.1.0", "description": "t", "types": "./types/missing.d.ts" }\n' > "$M11B/kit/.claude-plugin/plugin.json"
mkdepmod "$M11B" by-noun '["kit"]' "export const register = on => { on('tool.call', async (\$, e, next) => { await \$.kit.go(); return next(e) }) }"
out="$(bash "$DEPS" "$M11B" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'by-noun lists kit under dependencies, whose contract ./types/missing.d.ts cannot be read' \
  && ! printf '%s\n' "$out" | grep -q 'never uses it' \
  && check "a dependency whose contract cannot be read is reported as unreadable, never as unused" ok \
  || check "a dependency whose contract cannot be read is reported as unreadable, never as unused" "exit=$code out=$out"
# The lessons review of #696: what counts as use is code, wherever the mod keeps it, read against
# the whole contract.
M11C="$TMPROOT/m11c"
mkdepmod "$M11C" kit '[]' "export const register = () => {}"
mkdir -p "$M11C/kit/types"
printf '{ "name": "kit", "version": "0.1.0", "description": "t", "types": "./types/index.d.ts" }\n' > "$M11C/kit/.claude-plugin/plugin.json"
printf 'declare module "claude-code" {\n  interface EngineInterface {\n    kitInfo: { version: string; nested: { deep: boolean } }\n    kit: { go: () => Promise<void> }\n  }\n}\n' > "$M11C/kit/types/index.d.ts"
# A noun declared after a member with an inline object type is still one of the contract's.
mkdepmod "$M11C" late-noun '["kit"]' "export const register = on => { on('tool.call', async (\$, e, next) => { await \$.kit.go(); return next(e) }) }"
# Code outside hooks/ that the hooks module imports is the mod's code too.
mkdepmod "$M11C" elsewhere '["kit"]' "import { go } from '../lib/go.ts'
export const register = on => { on('tool.call', async (\$, e, next) => { await go(\$); return next(e) }) }"
mkdir -p "$M11C/elsewhere/lib"
printf 'export const go = async ($) => { await $.kit.go() }\n' > "$M11C/elsewhere/lib/go.ts"
out="$(bash "$DEPS" "$M11C" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a noun after an inline object type, and a use outside hooks/, both count" ok \
  || check "a noun after an inline object type, and a use outside hooks/, both count" "exit=$code out=$out"
# A comment mentioning the noun or the name is not a use.
mkdepmod "$M11C" commented '["kit"]' "// \$.kit.go() is how this would be called, and { plugin: 'kit' } how a press would be matched
/* 'kit' and \$.kit.go() in a block comment */
export const register = on => { on('tool.call', async (\$, e, next) => next(e)) } // 'kit'"
# A mod listing a dependency with no source at all is reported, never passed or accused.
mkdepmod "$M11C" sourceless '["kit"]' ""
rm -f "$M11C/sourceless/hooks/register.ts"
out="$(bash "$DEPS" "$M11C" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'commented lists kit under dependencies but never uses it' \
  && check "a dependency only a comment mentions fails the run" ok || check "a dependency only a comment mentions fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q 'sourceless lists kit under dependencies, but no source file of sourceless was found' \
  && check "a mod with no source is reported as such" ok || check "a mod with no source is reported as such" "$out"
! printf '%s\n' "$out" | grep -qE '(late-noun|elsewhere) lists' \
  && check "and the mods whose code uses it are not named" ok || check "and the mods whose code uses it are not named" "$out"
# #735: a regex literal and JSX text are read as what they are. A regex holding // or /* was taken
# for a comment and hid the code after it, so a use there read as none; JSX text's // dropped the
# rest of its line, and its apostrophe opened a quote that took in a comment, whose noun then
# counted as a use.
M11D="$TMPROOT/m11d"
mkdepmod "$M11D" kit '[]' "export const register = () => {}"
mkdir -p "$M11D/kit/types"
printf '{ "name": "kit", "version": "0.1.0", "description": "t", "types": "./types/index.d.ts" }\n' > "$M11D/kit/.claude-plugin/plugin.json"
printf 'declare module "claude-code" {\n  interface EngineInterface {\n    kit: { go: () => Promise<void> }\n  }\n}\n' > "$M11D/kit/types/index.d.ts"
mkdepmod "$M11D" after-regex '["kit"]' "const SLASHES = /\\/\\//g; export const register = on => { on('tool.call', async (\$, e, next) => { await \$.kit.go(); return next(e) }) }"
mkdepmod "$M11D" after-regex-star '["kit"]' "const STARS = /\\/*/
export const register = on => { on('tool.call', async (\$, e, next) => { await \$.kit.go(); return next(e) }) }"
mkdepmod "$M11D" jsx-slashes '["kit"]' "export const register = () => {}"
printf '%s\n' "export const View = () => <Text>see https://example.com</Text>; export const go = async (\$) => { await \$.kit.go() }" > "$M11D/jsx-slashes/hooks/view.tsx"
mkdepmod "$M11D" jsx-apostrophe '["kit"]' "export const register = () => {}"
printf '%s\n' "export const View = () => <Text>Dan's card</Text> // \$.kit.go() would draw it" > "$M11D/jsx-apostrophe/hooks/view.tsx"
out="$(bash "$DEPS" "$M11D" 2>&1)"; code=$?
for m in after-regex after-regex-star jsx-slashes; do
  ! printf '%s\n' "$out" | grep -q "$m lists" && check "a use after $m is read as a use" ok || check "a use after $m is read as a use" "exit=$code out=$out"
done
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'jsx-apostrophe lists kit under dependencies but never uses it' \
  && check "a noun in a comment after JSX text holding an apostrophe is no use" ok \
  || check "a noun in a comment after JSX text holding an apostrophe is no use" "exit=$code out=$out"
out="$(bash "$DEPS" "$TMPROOT/not-there" 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a missing mods folder is refused by the dependency check" ok \
  || check "a missing mods folder is refused by the dependency check" "exit=$code out=$out"
if [ -d "$ROOT/payload/mods" ]; then
  out="$(bash "$DEPS" "$ROOT/payload/mods" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "every mod in payload/mods uses each dependency it lists" ok \
    || check "every mod in payload/mods uses each dependency it lists" "exit=$code out=$out"
fi

# 12. No mod's own $ noun waits on a person, or on anything else with no bound under 10 seconds
#     (#744). Claude Code cuts a noun call off at 10 s ("did not answer within 10000ms", measured
#     live on 2026-10-05, 2.1.289), and `claude plugin test` does not, so a noun that waits on a
#     press passes every test of its own and fails in a session: picker manners' $.pickers.wait
#     asked every question twice that way. Each fixture is one form of that reason, never one named
#     case (L362).
WAITS="$ROOT/tools/check-mod-noun-waits.sh"
# The checks below need the TypeScript compiler pinned in tools/typescript, which the noun wait check
# resolves every call with (#895) and refuses without (exit 4). A machine where it does not start
# (not installed, or a Mac's native build copied to Linux) reports them UNMEASURED with the install
# command, as check-mods.sh does for its type check, rather than failing (L411); under CI=true, where
# the workflow installs it, one that does not start is a failure.
noun_wait_checks(){
  M12W="$TMPROOT/m12w"
  mknounmod(){   # $1 = mods dir  $2 = name  $3 = the noun its contract declares; the hooks module's source on stdin
    mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks" "$1/$2/types"
    printf '{ "name": "%s", "version": "0.1.0", "description": "t", "types": "./types/index.d.ts" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
    printf 'declare module "claude-code" {\n  interface EngineInterface {\n    %s: Record<string, (input?: unknown) => Promise<unknown>>\n  }\n}\n' "$3" > "$1/$2/types/index.d.ts"
    cat > "$1/$2/hooks/register.ts"
  }
  # The shape picker manners had: the noun's promise is settled by a press, through a map of waiters.
  mknounmod "$M12W" waits-in-map pickers <<'TS'
const waiters = new Map<string, (o: string) => void>()
const early = new Map<string, string>()
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const pickers = {
      wait: ({ id }) =>
        new Promise<string>(resolve => {
          const got = early.get(id)
          if (got) resolve(got)
          else waiters.set(id, resolve)
        }),
    }
    return { ...built, pickers }
  })
  on('ui.press', async ($, e, next) => {
    waiters.get(e.element)?.('pressed')
    return next(e)
  })
}
TS
  # Handed to something that calls it later, kept in a variable, or reached through a helper.
  mknounmod "$M12W" passed-to-listener presses <<'TS'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, presses: { next: () => new Promise(resolve => built.events.once('press', resolve)) } }
  })
}
TS
  mknounmod "$M12W" called-back-later gate <<'TS'
let release: (() => void) | undefined
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, gate: { open: () => new Promise<void>(r => { release = () => r() }) } }
  })
}
TS
  mknounmod "$M12W" through-helper helped <<'TS'
const waiters = new Map<string, (v: string) => void>()
const waitFor = (id: string): Promise<string> =>
  new Promise(resolve => {
    waiters.set(id, resolve)
  })
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, helped: { wait: ({ id }) => waitFor(id) } }
  })
}
TS
  # A timer bounds the wait only when it settles the promise, and only under the 10 s limit measured
  # on 2026-10-05.
  mknounmod "$M12W" long-timer pause <<'TS'
const WAIT_MS = 15 * 1_000
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, pause: { long: () => new Promise(r => built.clock.after(WAIT_MS, () => r('done'))) } }
  })
}
TS
  mknounmod "$M12W" unrelated-timer beat <<'TS'
const waiters = new Map()
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, beat: { wait: ({ id }) => new Promise(resolve => { waiters.set(id, resolve); built.clock.after(1_000, () => built.ui.log('still waiting')) }) } }
  })
}
TS
  # A person, asked through Claude Code's own dialog, has no bound either.
  mknounmod "$M12W" asks-a-person confirm <<'TS'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, confirm: { ready: async () => (await built.ui.ask('Ready?', ['Yes', 'No'])) === 'Yes' } }
  })
}
TS
  # A noun answered by a hook on its own event (as mod-kit's screen is) is that noun's code too.
  mknounmod "$M12W" on-noun-event relay <<'TS'
const pending: ((v: string) => void)[] = []
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, relay: { get: async () => 'fallback' } }
  })
  on('relay.get', async ($, e) => ({ value: await new Promise<string>(r => pending.push(r)) }))
}
TS
  # An executor named rather than written in place is read where it is defined; one that cannot be
  # found is reported as unreadable, never passed.
  mknounmod "$M12W" named-executor parked <<'TS'
const parked: ((v: string) => void)[] = []
function park(resolve: (v: string) => void) {
  parked.push(resolve)
}
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, parked: { wait: () => new Promise(park) } }
  })
}
TS
  mknounmod "$M12W" lost-executor lost <<'TS'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, lost: { wait: () => new Promise(fromSomewhereElse) } }
  })
}
TS
  # A promise made outside a noun's code (in another hook), kept in a map or a variable, and returned
  # by a noun later is that noun's wait too (#756): it is named where it is made.
  mknounmod "$M12W" made-in-hook held <<'TS'
const held = new Map<string, Promise<string>>()
const waiters = new Map<string, (v: string) => void>()
export const register = on => {
  on('session.start', async ($, e, next) => {
    held.set('start', new Promise(resolve => waiters.set('start', resolve)))
    return next(e)
  })
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, held: { wait: ({ id }) => held.get(id) } }
  })
}
TS
  mknounmod "$M12W" kept-in-variable ready <<'TS'
let release: (() => void) | undefined
let ready: Promise<void> = Promise.resolve()
export const register = on => {
  on('session.start', async ($, e, next) => {
    ready = new Promise<void>(r => { release = r })
    return next(e)
  })
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, ready: { wait: () => ready } }
  })
}
TS
  # A race bounds a wait only when the timer it races settles under 10 s (the limit measured on 2026-10-05).
  mknounmod "$M12W" raced-long slow <<'TS'
const waiters = new Map()
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, slow: { wait: ({ id }) => Promise.race([new Promise(resolve => waiters.set(id, resolve)), sleep(15_000)]) } }
  })
}
TS
  # What must pass: a wait a timer under 10 s settles, one settled at once, a comment or a string
  # naming the forbidden shape, and a wait outside every noun's code, which is not this check's to
  # judge (the job watcher gives up a look after ten minutes, from a timer, never from a noun). The
  # 10 s is the limit measured on 2026-10-05.
  mknounmod "$M12W" bounded short <<'TS'
const waiters = new Map()
const ANSWER_MS = 5_000
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return {
      ...built,
      short: {
        wait: ({ id }) =>
          new Promise(resolve => {
            waiters.set(id, resolve)
            built.clock.after(ANSWER_MS, () => resolve('timed out'))
          }),
        nap: () => new Promise(r => setTimeout(r, 50)),
        now: () => new Promise(r => r(Date.now())),
      },
    }
  })
}
TS
  mknounmod "$M12W" commented quiet <<'TS'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    // new Promise(r => waiters.set(id, r)) would wait on a press; built.ui.ask('Ready?') on a person.
    return { ...built, quiet: { say: async () => 'new Promise(r => waiters.set(id, r)) and built.ui.ask(question)' } }
  })
}
TS
  mknounmod "$M12W" outside-any-noun quick <<'TS'
const waiters = new Map()
const later = (id: string) => new Promise(resolve => waiters.set(id, resolve))
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, quick: { now: async () => Date.now() } }
  })
  on('session.start', async ($, e, next) => {
    void later('start')
    return next(e)
  })
}
TS
  # A race against a timer made in another executor, a helper's or one written in place, bounds the
  # wait, for a promise made in place and for one made in another hook (#756). A promise another hook
  # keeps that no noun reads is not this check's to judge.
  mknounmod "$M12W" raced-short race <<'TS'
const waiters = new Map()
const held = new Map()
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))
export const register = on => {
  on('session.start', async ($, e, next) => {
    held.set('start', new Promise(resolve => waiters.set('start', resolve)))
    return next(e)
  })
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return {
      ...built,
      race: {
        wait: ({ id }) => Promise.race([new Promise(resolve => waiters.set(id, resolve)), sleep(5_000)]),
        held: ({ id }) => Promise.race([held.get(id), new Promise(r => built.clock.after(3_000, () => r('late')))]),
      },
    }
  })
}
TS
  mknounmod "$M12W" kept-unread calm <<'TS'
let parked: Promise<void> = Promise.resolve()
const waiters: (() => void)[] = []
export const register = on => {
  on('session.start', async ($, e, next) => {
    parked = new Promise<void>(r => waiters.push(r))
    return next(e)
  })
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, calm: { now: async () => Date.now() } }
  })
}
TS
  # A noun's own slow engine calls count too (#802): the 10 s is not paused while a noun's $ calls
  # run (measured live on 2026-10-05 for #756: a noun whose only wait was `process.run` of `sleep 13`
  # was cut at 10,003 ms). process.run waits up to its timeoutMs, 30 s when none is given, and
  # model.complete has no bound under 10 s at all.
  mknounmod "$M12W" slow-process shell <<'TS'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, shell: { run: async () => (await built.process.run(['/bin/sleep', '13'])).exitCode } }
  })
}
TS
  mknounmod "$M12W" long-process-timeout fetcher <<'TS'
const RUN_MS = 30 * 1_000
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, fetcher: { get: () => built.process.run(['curl', 'x'], { cwd: '/', timeoutMs: RUN_MS }) } }
  })
}
TS
  mknounmod "$M12W" model-call namer <<'TS'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, namer: { name: () => built.model.complete({ model: 'haiku', prompt: 'x', maxTokens: 10 }) } }
  })
}
TS
  mknounmod "$M12W" model-timed quicknamer <<'TS'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, quicknamer: { name: () => built.model.complete({ model: 'haiku', prompt: 'x', maxTokens: 10, timeoutMs: 5_000 }) } }
  })
}
TS
  mknounmod "$M12W" short-process quickshell <<'TS'
const QUICK_MS = 5_000
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, quickshell: { run: () => built.process.run(['true'], { timeoutMs: QUICK_MS }) } }
  })
}
TS
  mknounmod "$M12W" shorthand-timeout tersely <<'TS'
const timeoutMs = 5_000
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, tersely: { run: () => built.process.run(['true'], { cwd: '/', timeoutMs }) } }
  })
}
TS
  # A string constant the reader blanks, then comment lines, then the timeout constant (#1254). The
  # value of a constant is read on its own line only: when the space after `=` could cross newlines,
  # the blanked string's value ran on through the comments into the next line, swallowed NOTIFY_MS
  # as that value, and the noun's timeoutMs was reported as one whose value cannot be read (found on
  # #1245, goal-tracker's NOTIFY_MS, and worked around there by reordering the lines).
  mknounmod "$M12W" string-then-comments notifier <<'TS'
const ASLEEP = 'asleep'
// a comment between the two constants
// and another
const NOTIFY_MS = 5_000
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, notifier: { send: () => built.process.run(['true'], { timeoutMs: NOTIFY_MS }), state: () => ASLEEP } }
  })
}
TS
  mknounmod "$M12W" process-in-hook hooked <<'TS'
export const register = on => {
  on('session.start', async ($, e, next) => {
    await $.process.run(['/bin/sleep', '13'])
    return next(e)
  })
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, hooked: { now: async () => Date.now() } }
  })
}
TS
  # A called helper is resolved by scope, as the language does: the nearest enclosing declaration of
  # its name, then the module's top level, never the first declaration of that name anywhere in the
  # file (#895). Two functions each keep a local `pause`, and only one of them waits. The noun calling
  # the one that does not wait is not accused, though the waiting `pause` is declared first ...
  mknounmod "$M12W" same-local-calm brisk <<'TS'
const waiters = new Map()
function patient(id: string) {
  const pause = () => new Promise(resolve => waiters.set(id, resolve))
  return pause()
}
function hasty() {
  const pause = () => Promise.resolve('now')
  return pause()
}
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, brisk: { go: () => hasty() } }
  })
}
TS
  # ... and the noun calling the one that does wait is, though the quiet `pause` is declared first.
  mknounmod "$M12W" same-local-waits slow <<'TS'
const waiters = new Map()
function hasty() {
  const pause = () => Promise.resolve('now')
  return pause()
}
function patient(id: string) {
  const pause = () => new Promise(resolve => waiters.set(id, resolve))
  return pause()
}
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, slow: { go: ({ id }) => patient(id) } }
  })
}
TS
  # A name declared only in a block that does not enclose the call reaches nothing there (here the
  # call is to a parameter), never that other function's local (#895, lessons review).
  mknounmod "$M12W" out-of-scope-local handed <<'TS'
const waiters = new Map()
function patient(id: string) {
  const pause = () => new Promise(resolve => waiters.set(id, resolve))
  return pause()
}
function hasty(pause: () => Promise<string>) {
  return pause()
}
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, handed: { go: () => hasty(() => Promise.resolve('now')) } }
  })
}
TS
  # A parameter shadows a top-level helper of its name, in a function and in an arrow alike, so a call
  # to it reaches nothing in the mod (#895, lessons review).
  mknounmod "$M12W" param-shadows-top shadowed <<'TS'
const waiters = new Map()
const wait = () => new Promise(resolve => waiters.set('x', resolve))
function hasty(wait: () => Promise<string>) {
  return wait()
}
const brief = (wait: () => Promise<string>): Promise<string> => wait()
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, shadowed: { go: () => hasty(() => Promise.resolve('now')), also: () => brief(() => Promise.resolve('now')) } }
  })
}
TS
  # An arrow's expression body ends with its line, as the language reads code with no semicolons, so its
  # parameter shadows nothing past it: the noun's own call of the waiting helper is still named.
  mknounmod "$M12W" param-scope-ends ends <<'TS'
const waiters = new Map()
const wait = () => new Promise(resolve => waiters.set('x', resolve))
const brief = (wait: () => Promise<string>): Promise<string> => wait()
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, ends: { go: () => wait() } }
  })
}
TS
  # A parameter shadows a helper however its function's return type is written, a type literal or one
  # inside angle brackets included (#895, lessons review).
  mknounmod "$M12W" param-typed-return typedret <<'TS'
const waiters = new Map()
const wait = () => new Promise(resolve => waiters.set('x', resolve))
function hasty(wait: () => Promise<string>): { result: Promise<string> } {
  return { result: wait() }
}
const brief = (wait: () => Promise<string>): Promise<{ a: string }> => wait().then(a => ({ a }))
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, typedret: { go: () => hasty(() => Promise.resolve('now')), also: () => brief(() => Promise.resolve('now')) } }
  })
}
TS
  # A local function's own declaration is not a call of it, so its parameter list is never read as the
  # arguments of one (#895, lessons review).
  mknounmod "$M12W" local-function-decl declared <<'TS'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    function wait(ms: number) {
      return new Promise(r => setTimeout(r, ms))
    }
    return { ...built, declared: { go: () => wait(1_000) } }
  })
}
TS
  # Two same-named local helpers are each judged by the calls that reach that one, never by the other's:
  # the short call bounds its own helper and the long one is named at its own (#895, lessons review).
  mknounmod "$M12W" same-local-args timed <<'TS'
function quick() {
  const wait = (ms: number) => new Promise(r => setTimeout(r, ms))
  return wait(1_000)
}
function slow() {
  const wait = (ms: number) => new Promise(r => setTimeout(r, ms))
  return wait(20_000)
}
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, timed: { quick: () => quick(), slow: () => slow() } }
  })
}
TS
  # A file saved with CRLF line endings and a byte order mark is resolved at the same positions the
  # compiler reports, so its same-named locals are told apart as in any other file (#895).
  mknounmod "$M12W" crlf-local crlfed <<'TS'
const waiters = new Map()
function patient(id: string) {
  const pause = () => new Promise(resolve => waiters.set(id, resolve))
  return pause()
}
function hasty() {
  const pause = () => Promise.resolve('now')
  return pause()
}
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, crlfed: { go: () => hasty() } }
  })
}
TS
  python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); open(p, "w", newline="").write("\ufeff" + t.replace("\n", "\r\n"))' "$M12W/crlf-local/hooks/register.ts"
  # A call the checker resolves to nothing in the mod (an import of a file that does not exist, or a
  # bare global) reaches no function of the mod, and never crashes the resolver (#895).
  mknounmod "$M12W" unresolved-import loose <<'TS'
import { gone } from './missing.ts'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, loose: { go: () => gone(), also: () => undefined } }
  })
}
TS
  # A race member named by a constant declared beside another in one statement is read as the timer
  # it holds (#895, lessons review).
  mknounmod "$M12W" multi-declarator paired <<'TS'
const waiters = new Map()
const quick = 1, held = new Promise(r => setTimeout(r, 1_000))
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, paired: { wait: ({ id }) => Promise.race([new Promise(resolve => waiters.set(id, resolve)), held]) } }
  })
}
TS
  # A noun method given as a shorthand property (`{ wait }`) is the function of that name, followed
  # like a call (#895, lessons review).
  mknounmod "$M12W" shorthand-method short <<'TS'
const waiters = new Map()
function wait({ id }: { id: string }) {
  return new Promise(resolve => waiters.set(id, resolve))
}
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, short: { wait } }
  })
}
TS
  # A promise kept in a variable is linked to a noun's read of that same variable as the compiler
  # resolves it, never to a read of another variable sharing its name (#915). Two functions each hold
  # a local `expired`, and only the one outside every noun's code waits; the noun reads its own.
  mknounmod "$M12W" same-name-variable roster <<'TS'
const waiters = new Map()
function watch(id: string) {
  const expired = new Promise(resolve => waiters.set(id, resolve))
  return expired
}
export const register = on => {
  on('session.start', async ($, e, next) => {
    void watch('start')
    return next(e)
  })
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return {
      ...built,
      roster: {
        list: async () => {
          const expired = new Promise(resolve => resolve(['a']))
          return expired
        },
      },
    }
  })
}
TS
  # A parameter is its own variable too: one function's parameter keeping a waiting promise is not a
  # noun's parameter of the same name (#915).
  mknounmod "$M12W" same-name-parameter shelf <<'TS'
const waiters = new Map()
function keep(store: Map<string, Promise<string>>) {
  store.set('x', new Promise(resolve => waiters.set('x', resolve)))
}
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, shelf: { get: (store: Map<string, string>) => store.get('x') } }
  })
}
TS
  # ... and one kept in another file of the mod and imported by the noun is still that noun's read.
  mknounmod "$M12W" kept-in-other-file later <<'TS'
import { pending } from './store.ts'
export const register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, later: { wait: ({ id }) => pending.get(id) } }
  })
}
TS
  cat > "$M12W/kept-in-other-file/hooks/store.ts" <<'TS'
export const pending = new Map<string, Promise<string>>()
const waiters = new Map<string, (v: string) => void>()
export const keep = (id: string) => {
  pending.set(id, new Promise(resolve => waiters.set(id, resolve)))
}
TS
  # #939: work a noun's hook hands to a timer runs after the noun answered (measured live on
  # 2026-10-08, 2.1.294: 13 s of process.run started on $.clock.after(0, ...) from a noun hook finished
  # whole), so neither what the timer's arguments say nor what they call is the noun's code. The same
  # helper awaited in the hook itself is.
  mknounmod "$M12W" timer-defers timed <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
export const register = on => {
  on('timed.press', ($, e, next) => {
    $.clock.after(0, () => {
      void slow($)
    })
    return { value: true }
  })
}
TS
  mknounmod "$M12W" timer-inline-code timedinline <<'TS'
export const register = on => {
  on('timedinline.press', ($, e, next) => {
    setTimeout(() => {
      void $.process.run(['/bin/sleep', '13'])
    }, 0)
    return { value: true }
  })
}
TS
  # A timer inside a promise the noun waits on is not after the noun: the noun answers only when
  # the timer's work settles it (lessons review of #952).
  mknounmod "$M12W" awaited-timer awaitedtimer <<'TS'
export const register = on => {
  on('awaitedtimer.press', async ($, e, next) => {
    await new Promise(resolve => {
      setTimeout(async () => {
        await $.process.run(['/bin/sleep', '13'])
        resolve(true)
      }, 0)
    })
    return { value: true }
  })
}
TS
  mknounmod "$M12W" awaited-not-deferred awaited <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
export const register = on => {
  on('awaited.press', async ($, e, next) => {
    await slow($)
    $.clock.after(0, () => undefined)
    return { value: true }
  })
}
TS
  # #2299: a mod's helper that starts the timer itself (picker manners' offTheDialog($, () => work()))
  # defers the callback a noun hands it, just as the timer written in place does. The helper is known
  # by what it does, never by its name: each mention of the parameter is in a timer's callback, as
  # that callback itself, inside a function written there, or handed to a function that only makes
  # one. The noun must hand it a function written in place, since anything else runs at the call.
  mknounmod "$M12W" helper-defers deferhelper <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const later = ($, work: () => Promise<unknown>) => $.clock.after(0, work)
export const register = on => {
  on('deferhelper.press', ($, e, next) => {
    later($, () => slow($))
    return { value: true }
  })
}
TS
  mknounmod "$M12W" helper-defers-wrapped deferwrapped <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const reporting = ($, work: () => Promise<unknown>) => () => void work().catch(err => $.ui.log(String(err)))
export const offPath = ($, work: () => Promise<unknown>) => $.clock.after(0, reporting($, work))
export const register = on => {
  on('deferwrapped.press', ($, e, next) => {
    offPath($, () => slow($))
    return { value: true }
  })
}
TS
  mknounmod "$M12W" helper-defers-in-callback defercallback <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
function soon(work: () => Promise<unknown>) {
  setTimeout(() => {
    void work()
  }, 0)
}
export const register = on => {
  on('defercallback.press', ($, e, next) => {
    soon(async () => {
      await slow($)
    })
    return { value: true }
  })
}
TS
  # Each of these runs the noun's callback before the noun answers, so it stays refused: a helper that
  # also calls it in place, one that arms its timer with a call that runs it at once, a value worked
  # out at the call rather than a function, a helper inside a promise the noun waits on, and a helper
  # whose own timer sits inside the promise it hands back.
  mknounmod "$M12W" helper-runs-inline runsinline <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const now = ($, work: () => Promise<unknown>) => {
  void work()
  $.clock.after(0, () => undefined)
}
export const register = on => {
  on('runsinline.press', ($, e, next) => {
    now($, () => slow($))
    return { value: true }
  })
}
TS
  mknounmod "$M12W" helper-arms-with-call armscall <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const run = (work: () => Promise<unknown>) => {
  void work()
  return () => undefined
}
const later = ($, work: () => Promise<unknown>) => $.clock.after(0, run(work))
export const register = on => {
  on('armscall.press', ($, e, next) => {
    later($, () => slow($))
    return { value: true }
  })
}
TS
  mknounmod "$M12W" helper-given-value givenvalue <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const later = ($, work) => $.clock.after(0, work)
export const register = on => {
  on('givenvalue.press', ($, e, next) => {
    later($, slow($))
    return { value: true }
  })
}
TS
  mknounmod "$M12W" helper-in-held-promise heldhelper <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const later = ($, work: () => unknown) => $.clock.after(0, work)
export const register = on => {
  on('heldhelper.press', async ($, e, next) => {
    await new Promise(r => later($, () => slow($).then(r)))
    return { value: true }
  })
}
TS
  mknounmod "$M12W" helper-timer-in-promise timerpromise <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const settles = ($, work: () => Promise<unknown>) =>
  new Promise(r => {
    $.clock.after(0, () => {
      void work().then(r)
    })
  })
export const register = on => {
  on('timerpromise.press', async ($, e, next) => {
    await settles($, () => slow($))
    return { value: true }
  })
}
TS
  # #2333: only the function a noun's timer is handed runs later: a function written in place, or the
  # one a mod function that only makes a function hands back. Everything else in the timer's arguments
  # is worked out as the timer is set, before the noun answers, so it is the noun's own code: a call
  # given as the callback, a call that runs its argument at once, the delay, and a function written
  # in place and handed to a function making helper (picker manners' designRound.answered as it was).
  mknounmod "$M12W" timer-given-call timergivencall <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
export const register = on => {
  on('timergivencall.press', ($, e, next) => {
    $.clock.after(0, slow($))
    return { value: true }
  })
}
TS
  mknounmod "$M12W" timer-runs-at-once timerrunsnow <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const run = (work: () => unknown) => {
  void work()
  return () => undefined
}
export const register = on => {
  on('timerrunsnow.press', ($, e, next) => {
    $.clock.after(0, run(() => slow($)))
    return { value: true }
  })
}
TS
  mknounmod "$M12W" timer-delay-call timerdelay <<'TS'
const pause = ($) => {
  void $.process.run(['/bin/sleep', '13'])
  return 0
}
export const register = on => {
  on('timerdelay.press', ($, e, next) => {
    setTimeout(() => undefined, pause($))
    return { value: true }
  })
}
TS
  mknounmod "$M12W" timer-maker-given-inline timermakerinline <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const reporting = ($, work: () => Promise<unknown>) => () => void work().catch(err => $.ui.log(String(err)))
export const register = on => {
  on('timermakerinline.press', ($, e, next) => {
    $.clock.after(0, reporting($, () => slow($)))
    return { value: true }
  })
}
TS
  # What a function making helper hands the timer is the deferred function itself, so its body is not
  # the noun's code when nothing the noun writes is worked out at the call.
  mknounmod "$M12W" timer-maker-defers timermaker <<'TS'
const slow = async ($) => (await $.process.run(['/bin/sleep', '13'])).exitCode
const later = ($) => () => void slow($)
export const register = on => {
  on('timermaker.press', ($, e, next) => {
    $.clock.after(0, later($))
    return { value: true }
  })
}
TS
  out="$(bash "$WAITS" "$M12W" 2>&1)"; code=$?
  [ "$code" -eq 1 ] && check "a noun that waits with no bound under 10 s fails the run" ok || check "a noun that waits with no bound under 10 s fails the run" "exit=$code out=$out"
  case "$out" in *"58 mods checked"*) check "and the count is stated" ok ;; *) check "and the count is stated" "$out" ;; esac
  for at in waits-in-map/hooks/register.ts:8 passed-to-listener/hooks/register.ts:4 called-back-later/hooks/register.ts:5 through-helper/hooks/register.ts:3 named-executor/hooks/register.ts:8 long-timer/hooks/register.ts:5 unrelated-timer/hooks/register.ts:5 on-noun-event/hooks/register.ts:7 made-in-hook/hooks/register.ts:5 kept-in-variable/hooks/register.ts:5 raced-long/hooks/register.ts:6 same-local-waits/hooks/register.ts:7 same-local-args/hooks/register.ts:6 param-scope-ends/hooks/register.ts:2 shorthand-method/hooks/register.ts:3; do
    printf '%s\n' "$out" | grep -F "$at" | grep -q 'settled only by a later event' \
      && check "a wait settled only by a later event is named at ${at%%/*}'s line" ok \
      || check "a wait settled only by a later event is named at ${at%%/*}'s line" "$out"
  done
  printf '%s\n' "$out" | grep -F 'asks-a-person/hooks/register.ts:4' | grep -q 'waits on a person' \
    && check "a noun asking a person through \$.ui.ask is named" ok || check "a noun asking a person through \$.ui.ask is named" "$out"
  printf '%s\n' "$out" | grep -F 'lost-executor/hooks/register.ts:4' | grep -q 'cannot be read' \
    && check "an executor that cannot be found is reported as unreadable, never passed" ok \
    || check "an executor that cannot be found is reported as unreadable, never passed" "$out"
  for at in made-in-hook/hooks/register.ts:5 kept-in-variable/hooks/register.ts:5 kept-in-other-file/hooks/store.ts:4; do
    printf '%s\n' "$out" | grep -F "$at" | grep -q 'which a noun returns' \
      && check "a promise made outside the noun's code is named as one a noun returns at ${at%%/*}'s line" ok \
      || check "a promise made outside the noun's code is named as one a noun returns at ${at%%/*}'s line" "$out"
  done
  for at in slow-process/hooks/register.ts:4 long-process-timeout/hooks/register.ts:5 awaited-not-deferred/hooks/register.ts:1 awaited-timer/hooks/register.ts:5 helper-runs-inline/hooks/register.ts:1 helper-arms-with-call/hooks/register.ts:1 helper-given-value/hooks/register.ts:1 helper-in-held-promise/hooks/register.ts:1 helper-timer-in-promise/hooks/register.ts:1 timer-given-call/hooks/register.ts:1 timer-runs-at-once/hooks/register.ts:1 timer-delay-call/hooks/register.ts:2 timer-maker-given-inline/hooks/register.ts:1; do
    printf '%s\n' "$out" | grep -F "$at" | grep -q 'process.run' \
      && check "a noun's own process.run with no timeout under 10 s is named at ${at%%/*}'s line (#802)" ok \
      || check "a noun's own process.run with no timeout under 10 s is named at ${at%%/*}'s line (#802)" "$out"
  done
  printf '%s\n' "$out" | grep -F 'model-call/hooks/register.ts:4' | grep -q 'model.complete' \
    && check "a noun's own model.complete with no timeoutMs under 10 s is named (#802)" ok || check "a noun's own model.complete with no timeoutMs under 10 s is named (#802)" "$out"
  for m in short-process process-in-hook shorthand-timeout string-then-comments model-timed timer-defers timer-inline-code helper-defers helper-defers-wrapped helper-defers-in-callback timer-maker-defers; do
    ! printf '%s\n' "$out" | grep -q "$m/" && check "$m passes (#802)" ok || check "$m passes (#802)" "$out"
  done
  ! printf '%s\n' "$out" | grep -qF 'same-local-args/hooks/register.ts:2' \
    && check "a local helper is judged by its own calls, never a same-named one's (#895)" ok \
    || check "a local helper is judged by its own calls, never a same-named one's (#895)" "$out"
  for m in bounded commented outside-any-noun raced-short kept-unread same-local-calm out-of-scope-local param-shadows-top param-typed-return local-function-decl crlf-local unresolved-import multi-declarator same-name-variable same-name-parameter; do
    ! printf '%s\n' "$out" | grep -q "$m/" && check "$m passes" ok || check "$m passes" "$out"
  done
  # Cut down to the mods that pass, the run passes, so the failure above is theirs alone.
  for m in waits-in-map passed-to-listener called-back-later through-helper named-executor long-timer unrelated-timer on-noun-event asks-a-person lost-executor made-in-hook kept-in-variable kept-in-other-file raced-long slow-process long-process-timeout model-call same-local-waits same-local-args param-scope-ends shorthand-method awaited-not-deferred awaited-timer helper-runs-inline helper-arms-with-call helper-given-value helper-in-held-promise helper-timer-in-promise timer-given-call timer-runs-at-once timer-delay-call timer-maker-given-inline; do rm -rf "${M12W:?}/$m"; done
  out="$(bash "$WAITS" "$M12W" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "a noun bounded under 10 s, a comment and a wait outside any noun all pass" ok \
    || check "a noun bounded under 10 s, a comment and a wait outside any noun all pass" "exit=$code out=$out"
  # A mods folder named relative to where the check runs is resolved too: the compiler's project is
  # written in a folder of its own, so each file is handed to it by its absolute path (#895).
  out="$(cd "$(dirname "$M12W")" && bash "$WAITS" "$(basename "$M12W")" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "a mods folder given by a relative path is checked the same (#895)" ok \
    || check "a mods folder given by a relative path is checked the same (#895)" "exit=$code out=$out"
  out="$(cd "$ROOT" && CHECK_MODS_TS_DIR=tools/typescript bash "$WAITS" "$M12W" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "a compiler folder given by a relative path is loaded (#895)" ok \
    || check "a compiler folder given by a relative path is loaded (#895)" "exit=$code out=$out"
  out="$(bash "$WAITS" "$TMPROOT/not-there" 2>&1)"; code=$?
  [ "$code" -eq 2 ] && check "a missing mods folder is refused by the noun wait check" ok \
    || check "a missing mods folder is refused by the noun wait check" "exit=$code out=$out"
  # Calls are resolved by the pinned TypeScript compiler (#895), so without it nothing is checked and
  # the run refuses by name rather than passing over nothing resolved (L490).
  out="$(CHECK_MODS_TS_DIR="$TMPROOT/no-typescript" bash "$WAITS" "$M12W" 2>&1)"; code=$?
  [ "$code" -eq 4 ] && printf '%s\n' "$out" | grep -q 'pinned TypeScript compiler cannot be loaded' \
    && check "a missing TypeScript compiler is refused by name by the noun wait check (#895)" ok \
    || check "a missing TypeScript compiler is refused by name by the noun wait check (#895)" "exit=$code out=$out"
  if [ -d "$ROOT/payload/mods" ]; then
    out="$(bash "$WAITS" "$ROOT/payload/mods" 2>&1)"; code=$?
    [ "$code" -eq 0 ] && check "no mod in payload/mods has a noun that waits past 10 s" ok \
      || check "no mod in payload/mods has a noun that waits past 10 s" "exit=$code out=$out"
  fi
}
# Whether the compiler in $1 STARTS, judged by running the resolver once on a one line fixture,
# never by its folder existing: TypeScript 7 is a native binary, so a Mac's install copied to Linux
# (tests/run-on-linux.sh copies the checkout) is there and cannot run (lessons review of #896).
ts_starts(){   # $1 = the folder the pinned TypeScript compiler is looked for in
  mkdir -p "$TMPROOT/ts-probe"
  printf 'const probe = () => 1\nprobe()\n' > "$TMPROOT/ts-probe/probe.ts"
  printf '{"mods":[{"files":["%s"]}]}' "$TMPROOT/ts-probe/probe.ts" \
    | node "$ROOT/tools/lib/ts-resolve.mjs" "$1" > "$TMPROOT/ts-probe/out.json" 2> "$TMPROOT/ts-probe/err.txt" \
    && grep -q '"call"' "$TMPROOT/ts-probe/out.json"
}
noun_wait_section(){   # $1 = the folder the pinned TypeScript compiler is looked for in; $2 = "required" where it must start
  if ts_starts "$1"; then
    CHECK_MODS_TS_DIR="$1" noun_wait_checks
  elif [ "${2:-}" = required ]; then
    # CI installs the compiler, so one that does not start there is a broken step, never a machine
    # that has not installed it, and every check below would otherwise go quietly unmeasured.
    check "the pinned TypeScript compiler starts where CI runs the noun wait checks (#895)" "it did not start from $1: $(tail -1 "$TMPROOT/ts-probe/err.txt" 2>/dev/null)"
  else
    echo "SUITE-PART-UNMEASURED the noun wait checks (section 12) did not run: no TypeScript compiler that starts in $1. Install it with: npm ci --prefix tools/typescript.$([ "$1" = "$ROOT/tools/typescript" ] && printf '%s' "$PINNED_WHY")"
  fi
}
# A stand-in compiler that is installed but exits non zero as it loads, as a Mac's copy does on Linux.
mkdir -p "$TMPROOT/broken-typescript/node_modules/typescript/dist/api/sync"
printf 'process.exit(3)\n' > "$TMPROOT/broken-typescript/node_modules/typescript/dist/api/sync/api.js"
for ts in no-typescript-here broken-typescript; do
  # Where it is required, a compiler missing or not starting is one failure, never UNMEASURED.
  # Counted here and then taken back, since the failure is the fixture's.
  before=$fail
  noun_wait_section "$TMPROOT/$ts" required > "$TMPROOT/noun-waits-required.out" 2>&1
  got=$((fail - before)); fail=$before
  [ "$got" -eq 1 ] && ! grep -q '^SUITE-PART-UNMEASURED' "$TMPROOT/noun-waits-required.out" \
    && check "under CI a compiler that does not start ($ts) fails the noun wait checks, never UNMEASURED (#895)" ok \
    || check "under CI a compiler that does not start ($ts) fails the noun wait checks, never UNMEASURED (#895)" "failures=$got out=$(cat "$TMPROOT/noun-waits-required.out")"
  # Elsewhere the section is UNMEASURED, never a failure, and runs nothing. Run in this shell, never a
  # $(...) subshell, so a check it ran would move these very counters (lessons review of #896).
  before=$fail; ran=$pass
  noun_wait_section "$TMPROOT/$ts" > "$TMPROOT/noun-waits-unmeasured.out" 2>&1
  out="$(cat "$TMPROOT/noun-waits-unmeasured.out")"
  [ "$fail" -eq "$before" ] && [ "$pass" -eq "$ran" ] && printf '%s\n' "$out" | grep -q "^SUITE-PART-UNMEASURED the noun wait checks .*npm ci --prefix tools/typescript" \
    && ! printf '%s\n' "$out" | grep -q "^FAIL" \
    && check "with a compiler that does not start ($ts) the noun wait checks are UNMEASURED, never failed (#895)" ok \
    || check "with a compiler that does not start ($ts) the noun wait checks are UNMEASURED, never failed (#895)" "$out"
done
# ... and with one that starts they run, here, counted like any other check. Required under CI,
# where the workflow installs it.
TS_FOR_WAITS="${CHECK_MODS_TS_DIR:-$ROOT/tools/typescript}"
ran=$pass
noun_wait_section "$TS_FOR_WAITS" $([ "${CI:-}" = true ] && echo required)
if ts_starts "$TS_FOR_WAITS"; then
  [ "$pass" -gt "$ran" ] && check "with a TypeScript compiler that starts the noun wait checks run (#895)" ok \
    || check "with a TypeScript compiler that starts the noun wait checks run (#895)" "none ran"
fi
# Each mod scan depends on the shared source reader only through names it documents as public, never
# a private _helper whose signature can move under it (#756: #739 changed _definition's while #744's
# branch was open, and the resulting TypeError surfaced only after a rebase).
priv="$(grep -n -E 'from ts_source import .*\b_[A-Za-z]|ts_source\._[A-Za-z]' "$ROOT"/tools/*.sh "$ROOT"/tools/*.py "$ROOT"/tests/*.sh 2>/dev/null | grep -v "^$ROOT/tests/test-mods-fixtures.sh:.*priv=")"
[ -z "$priv" ] && check "no scan imports a private helper of tools/lib/ts_source.py" ok \
  || check "no scan imports a private helper of tools/lib/ts_source.py" "$priv"
fc="$(python3 -B - "$ROOT/tools/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from ts_source import code_only, function_code, function_span, kinds
text = "// const helper = 1\nconst helper = (a: number) => { return a + 1 }\nfunction other() { return 2 }\n"
code, k = code_only(text), kinds(text)
span = function_span(code, "helper", k)
print(function_code(code, "helper", k) == code[span[0]:span[1]], code[span[0]:span[1]].startswith("const helper"), function_code(code, "other", k), function_span(code, "missing", k))
PY
)"
[ "$fc" = "True True function other() { return 2 } None" ] \
  && check "ts_source's public function_code and function_span read a function's code and where it lies" ok \
  || check "ts_source's public function_code and function_span read a function's code and where it lies" "$fc"
# 13. No mod test sends a tool call and leaves it in flight with a bare `void` (#1297). The test can
#     end while the call is still on its way through the hooks beneath the mod, and on a loaded Mac
#     it lands after the test's own hooks are gone: job-watcher's file failed that way when four full
#     runs overlapped, on "no implementation for tool.call", a rejection nothing handled. Wait on the
#     call reaching wherever the test holds it instead, as job-watcher's sendHanging does (L290).
abandoned_calls(){   # $1 = mods dir -> each offending line, as file:line:text
  grep -rn -E 'void \$\.tool\.call\(' "$1" --include='*.test.ts' --include='*.test.tsx' 2>/dev/null | grep -v '/\.claude-plugin/types/' || true
}
M13="$TMPROOT/m13"
mkdir -p "$M13/leaves/tests"
printf "test('x', async (\$) => {\n  void \$.tool.call({ tool: 'Bash' } as never)\n})\n" > "$M13/leaves/tests/a.test.ts"
got="$(abandoned_calls "$M13")"
[ -n "$got" ] && check "a mod test that leaves a tool call in flight with a bare void is found (#1297)" ok \
  || check "a mod test that leaves a tool call in flight with a bare void is found (#1297)" "nothing found in $M13"
# A settled design's fixture is what the mod's tests draw (claude-config#1729). A mod's test runs
# apart from the repository and loads only code, so it cannot read docs/design/<name>.fixture.json:
# the mod keeps tests/<name>.fixture.ts beside its tests, that file's bytes behind `export default `,
# and here every such copy is held byte for byte to the one the settled design draws, so the
# design's wording and the mod's cannot drift apart. Zero copies found is a failure, never a clean
# pass: the goal box keeps one (L98).
if [ -d "$ROOT/payload/mods" ] && [ -d "$ROOT/docs/design" ]; then
  fx_n=0; fx_bad=""
  while IFS= read -r fx; do
    [ -n "$fx" ] || continue
    fx_n=$((fx_n + 1))
    src="$ROOT/docs/design/$(basename "$fx" .ts).json"
    { printf 'export default '; cat "$src"; } > "$TMPROOT/design-fixture-wanted.ts"
    cmp -s "$TMPROOT/design-fixture-wanted.ts" "$fx" || fx_bad="$fx_bad ${fx#"$ROOT"/}"
  done <<FIXTURES
$(find "$ROOT/payload/mods" -path '*/tests/*.fixture.ts' -not -path '*/node_modules/*' 2>/dev/null | while IFS= read -r f; do [ -f "$ROOT/docs/design/$(basename "$f" .ts).json" ] && printf '%s\n' "$f"; done)
FIXTURES
  [ "$fx_n" -ge 1 ] && [ -z "$fx_bad" ] \
    && check "#1729 every mod's copy of a settled design's fixture matches the design's ($fx_n)" ok \
    || check "#1729 every mod's copy of a settled design's fixture matches the design's ($fx_n)" "found $fx_n, and these differ from docs/design:${fx_bad:- none}. Each is the design's fixture behind 'export default ': rewrite it from docs/design, or settle the change in a design round"
fi

if [ -d "$ROOT/payload/mods" ]; then
  got="$(abandoned_calls "$ROOT/payload/mods")"
  [ -z "$got" ] && check "no mod test in payload/mods leaves a tool call in flight with a bare void (#1297)" ok \
    || check "no mod test in payload/mods leaves a tool call in flight with a bare void (#1297)" "$got"
fi
# Every check this suite runs can be run directly, as its header says, so each is committed
# executable (the lessons review of #744: the noun wait check was committed 644 beside its 755
# siblings, which this suite's own `bash <check>` could never notice).
for t in "$CHECK" "$SHARED" "$DEPS" "$WAITS"; do
  [ -x "$t" ] && check "${t#"$ROOT"/} is executable" ok || check "${t#"$ROOT"/} is executable" "not executable"
done

# 15. The real tree is checked in parts (#3622): one run of check-mods.sh over every mod read 490 and
#     667 s on a runner on 2026-11-25, so each part suite hands it the names of the mods dealt to it. Named mods
#     are checked as every mod is, and no other; the record of the build the mods last passed on is
#     written only when one run's parts, together, passed every mod in the folder on one build.
M15="$TMPROOT/m15"; mkmod "$M15" alpha; mkmod "$M15" beta; mkmod "$M15" gamma
printf 'x\n' > "$M15/alpha/hooks/a.test.ts"; printf 'x\n' > "$M15/gamma/hooks/a.test.ts"
REC15="$TMPROOT/last-passed-15/mods-last-passed.tsv"
runpart(){   # env words, then --, then check-mods.sh's arguments -> sets out and code, record in REC15
  local e=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  : > "$LOG"
  out="$(env CHECK_MODS_LAST_PASSED="$REC15" STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC_PASS" ${e[@]+"${e[@]}"} bash "$CHECK" "$@" 2>&1)"; code=$?
}
rec15(){ cut -f1 "$REC15" 2>/dev/null; }
runpart FAKE_CC_VERSION=2.1.400 -- "$M15" alpha gamma
[ "$code" -eq 0 ] && grep -q "plugin validate $M15/alpha" "$LOG" && grep -q "plugin test $M15/alpha" "$LOG" \
  && grep -q "plugin validate $M15/gamma" "$LOG" && grep -q "plugin test $M15/gamma" "$LOG" \
  && ! grep -q "$M15/beta" "$LOG" \
  && check "#3622 mods named after the folder are validated and tested, and no other mod is" ok \
  || check "#3622 mods named after the folder are validated and tested, and no other mod is" "exit=$code calls: $(tr '\n' ';' < "$LOG") out=$out"
printf '%s\n' "$out" | grep -q '^check-mods: 2 of 3 mods checked in .*: alpha, gamma$' \
  && check "#3622 and the run says how many of the folder's mods it checked, by name" ok \
  || check "#3622 and the run says how many of the folder's mods it checked, by name" "$out"
[ ! -e "$REC15" ] && check "#3622 named mods passing, with no round, record nothing" ok \
  || check "#3622 named mods passing, with no round, record nothing" "record: $(cat "$REC15" 2>&1)"
runpart FAKE_CC_VERSION=2.1.400 -- "$M15" alpha delta
[ "$code" -eq 2 ] && printf '%s\n' "$out" | grep -q "delta" && ! grep -q 'plugin' "$LOG" \
  && check "#3622 a name that is not a mod in the folder is refused, exit 2, naming it, and nothing is checked" ok \
  || check "#3622 a name that is not a mod in the folder is refused, exit 2, naming it, and nothing is checked" "exit=$code calls: $(tr '\n' ';' < "$LOG") out=$out"
runpart FAKE_CC_VERSION=2.1.400 -- "$M15" alpha alpha
[ "$code" -eq 2 ] && ! grep -q 'plugin' "$LOG" \
  && check "#3622 a mod named twice is refused, exit 2" ok \
  || check "#3622 a mod named twice is refused, exit 2" "exit=$code out=$out"
runpart FAKE_CC_VERSION=2.1.400 CHECK_MODS_ROUND=r1 -- "$M15"
[ "$code" -eq 2 ] && ! grep -q 'plugin' "$LOG" \
  && check "#3622 a round given with no mods named is refused, exit 2: a whole folder records by itself" ok \
  || check "#3622 a round given with no mods named is refused, exit 2: a whole folder records by itself" "exit=$code out=$out"
runpart FAKE_CC_VERSION=2.1.400 CHECK_MODS_ROUND=../r1 -- "$M15" alpha
[ "$code" -eq 2 ] && ! grep -q 'plugin' "$LOG" \
  && check "#3622 a round whose name could leave its folder is refused, exit 2" ok \
  || check "#3622 a round whose name could leave its folder is refused, exit 2" "exit=$code out=$out"
# A round: the first part's pass records nothing, the last one's records the build.
runpart FAKE_CC_VERSION=2.1.400 CHECK_MODS_ROUND=r1 -- "$M15" alpha gamma
[ "$code" -eq 0 ] && [ ! -e "$REC15" ] \
  && check "#3622 the first part of a round passing records nothing" ok \
  || check "#3622 the first part of a round passing records nothing" "exit=$code record: $(cat "$REC15" 2>&1) out=$out"
runpart FAKE_CC_VERSION=2.1.400 CHECK_MODS_ROUND=r1 -- "$M15" beta
[ "$code" -eq 0 ] && [ "$(rec15)" = 2.1.400 ] && grep -qE '^2\.1\.400	[0-9]{4}-[0-9]{2}-[0-9]{2}$' "$REC15" \
  && check "#3622 the part completing the round records the build, as a whole folder's pass does" ok \
  || check "#3622 the part completing the round records the build, as a whole folder's pass does" "exit=$code record: $(cat "$REC15" 2>&1) out=$out"
[ ! -e "$REC15.rounds/r1" ] && check "#3622 and the round is removed once it has recorded" ok \
  || check "#3622 and the round is removed once it has recorded" "$(ls -la "$REC15.rounds/r1" 2>&1)"
# A failing part leaves the round short, however the others pass.
runpart FAKE_CC_VERSION=2.1.401 CHECK_MODS_ROUND=r2 -- "$M15" alpha
M15F="$TMPROOT/m15f"; mkmod "$M15F" alpha; mkmod "$M15F" broken-beta
runpart FAKE_CC_VERSION=2.1.401 CHECK_MODS_ROUND=r3 -- "$M15F" broken-beta
runpart FAKE_CC_VERSION=2.1.401 CHECK_MODS_ROUND=r3 -- "$M15F" alpha
[ "$code" -eq 0 ] && [ "$(rec15)" = 2.1.400 ] \
  && check "#3622 a round with a failing part records nothing, though every other part passed" ok \
  || check "#3622 a round with a failing part records nothing, though every other part passed" "exit=$code record: $(cat "$REC15" 2>&1)"
# Parts of one round on two builds are not one pass.
runpart FAKE_CC_VERSION=2.1.402 CHECK_MODS_ROUND=r4 -- "$M15" alpha gamma
runpart FAKE_CC_VERSION=2.1.403 CHECK_MODS_ROUND=r4 -- "$M15" beta
[ "$(rec15)" = 2.1.400 ] && check "#3622 a round whose parts passed on two builds records nothing" ok \
  || check "#3622 a round whose parts passed on two builds records nothing" "record: $(cat "$REC15" 2>&1)"
# A part killed while writing leaves a file not yet moved into place, which counts for nothing.
mkdir -p "$REC15.rounds/r5"
printf '2.1.404\tbeta\n' > "$REC15.rounds/r5/part.XXXXXX.tmp"
runpart FAKE_CC_VERSION=2.1.404 CHECK_MODS_ROUND=r5 -- "$M15" alpha gamma
[ "$code" -eq 0 ] && [ "$(rec15)" = 2.1.400 ] \
  && check "#3622 a part killed before its file was in place counts for nothing" ok \
  || check "#3622 a part killed before its file was in place counts for nothing" "exit=$code record: $(cat "$REC15" 2>&1)"
# Two parts finishing at the same moment: whichever reads last sees both, so the round records. Run
# five times, each a round of its own.
race_bad=""
for i in 1 2 3 4 5; do
  rm -f "$REC15"
  env CHECK_MODS_LAST_PASSED="$REC15" STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC_PASS" FAKE_CC_VERSION=2.1.405 CHECK_MODS_ROUND="race$i" bash "$CHECK" "$M15" alpha gamma > /dev/null 2>&1 &
  ra=$!
  env CHECK_MODS_LAST_PASSED="$REC15" STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC_PASS" FAKE_CC_VERSION=2.1.405 CHECK_MODS_ROUND="race$i" bash "$CHECK" "$M15" beta > /dev/null 2>&1 &
  rb=$!
  wait "$ra"; wait "$rb"
  [ "$(rec15)" = 2.1.405 ] || race_bad="$race_bad race$i: $(cat "$REC15" 2>&1)"
done
[ -z "$race_bad" ] && check "#3622 two parts of a round finishing together record it, five times out of five" ok \
  || check "#3622 two parts of a round finishing together record it, five times out of five" "$race_bad"
# A round left by a run that never finished is removed after a day by the next part to write one.
mkdir -p "$REC15.rounds/old"; touch -t 202001010000 "$REC15.rounds/old"
runpart FAKE_CC_VERSION=2.1.406 CHECK_MODS_ROUND=r6 -- "$M15" alpha
[ ! -e "$REC15.rounds/old" ] && [ -e "$REC15.rounds/r6" ] \
  && check "#3622 a round older than a day is removed by the next part to write one, and the new one kept" ok \
  || check "#3622 a round older than a day is removed by the next part to write one, and the new one kept" "$(ls "$REC15.rounds" 2>&1)"
# With the record off, a round writes nothing anywhere.
runpart FAKE_CC_VERSION=2.1.407 CHECK_MODS_ROUND=r7 CHECK_MODS_LAST_PASSED= -- "$M15" alpha gamma
[ "$code" -eq 0 ] && [ ! -e "$REC15.rounds/r7" ] \
  && check "#3622 with the record set empty a round writes nothing" ok \
  || check "#3622 with the record set empty a round writes nothing" "exit=$code $(ls -a "$REC15.rounds" 2>&1)"

# The deal (mods_real_deal, tests/mods-harness.sh): every mod read from disk, in exactly one part,
# longest first to the part with least so far, a mod the seconds file does not name counting as 5.
DEAL_T="$TMPROOT/deal-seconds.tsv"
printf '# mod\tseconds\nalpha\t50\nbeta\t20\ngamma\t18\n' > "$DEAL_T"
M15D="$TMPROOT/m15d"; mkmod "$M15D" alpha; mkmod "$M15D" beta; mkmod "$M15D" gamma; mkmod "$M15D" newcomer
mkdir -p "$M15D/not-a-mod"
deal="$(mods_real_deal 3 "$M15D" "$DEAL_T" 2>&1)"; deal_rc=$?
want="$(printf '1\talpha\n2\tbeta\n3\tgamma\n3\tnewcomer')"
[ "$deal_rc" -eq 0 ] && [ "$deal" = "$want" ] \
  && check "#3622 the deal puts every mod in one part, by its seconds, a mod with none at 5" ok \
  || check "#3622 the deal puts every mod in one part, by its seconds, a mod with none at 5" "exit=$deal_rc got: $(printf '%s' "$deal" | tr '\n\t' ';,')"
[ "$(mods_real_deal 3 "$M15D" "$DEAL_T")" = "$deal" ] \
  && check "#3622 and it deals the same way every time" ok || check "#3622 and it deals the same way every time" "differs"
deal="$(mods_real_deal 3 "$M15D" "$TMPROOT/no-such-seconds.tsv" 2>&1)"; deal_rc=$?
[ "$deal_rc" -ne 0 ] && printf '%s\n' "$deal" | grep -q 'no-such-seconds.tsv' \
  && check "#3622 a missing seconds file is refused, naming it, rather than dealt by guess" ok \
  || check "#3622 a missing seconds file is refused, naming it, rather than dealt by guess" "exit=$deal_rc out=$deal"
# The real seconds file names no mod that is gone, so every figure in it is one a part pays.
stale="$(awk -F'\t' '!/^#/ && NF >= 2 { print $1 }' "$DIR/mods-real-tree-seconds.tsv" 2>/dev/null | while IFS= read -r m; do
    [ -f "$ROOT/payload/mods/$m/.claude-plugin/plugin.json" ] || printf '%s ' "$m"; done)"
[ -f "$DIR/mods-real-tree-seconds.tsv" ] && [ -z "$stale" ] \
  && check "#3622 tests/mods-real-tree-seconds.tsv names only mods in payload/mods" ok \
  || check "#3622 tests/mods-real-tree-seconds.tsv names only mods in payload/mods" "missing or naming gone mods: ${stale:-(file missing)}"
# A part dealt no mod says so, UNMEASURED, and never hands check-mods.sh no names, which would check
# the whole folder as a pass of this part. mods_real_part_names (the harness) is what a real tree part
# asks for its names, and refuses when the deal gave it none. A part of the fixture folder dealt into
# more parts than it has mods is empty.
ep_out="$(mods_real_part_names 5 5 "$M15D" "$DEAL_T" 2>&1)"; ep_rc=$?
[ "$ep_rc" -ne 0 ] && [ "$ep_out" = "SUITE-PART-UNMEASURED the real mods of part 5 of 5, because the deal gave this part no mod, so it has nothing to check" ] \
  && check "#3622 a part dealt no mod says UNMEASURED and names no mod" ok \
  || check "#3622 a part dealt no mod says UNMEASURED and names no mod" "exit=$ep_rc out=$ep_out"
ep_out="$(mods_real_part_names 3 3 "$M15D" "$DEAL_T" 2>&1)"; ep_rc=$?
[ "$ep_rc" -eq 0 ] && [ "$ep_out" = "$(printf 'gamma\nnewcomer')" ] \
  && check "#3622 and a part dealt mods names each of them" ok \
  || check "#3622 and a part dealt mods names each of them" "exit=$ep_rc out=$ep_out"
grep -v '^[[:space:]]*#' "$DIR/mods-real-tree.sh" 2>/dev/null | grep -q 'mods_real_part_names ' \
  && check "#3622 the real tree part takes its names from mods_real_part_names" ok \
  || check "#3622 the real tree part takes its names from mods_real_part_names" "not found in tests/mods-real-tree.sh"

# 14. The suites tests/test-mods.sh was cut into are still the checks of one suite (#3622). A piece
#     is known by its code sourcing tests/mods-harness.sh, never by a list kept here (L96), so a piece
#     added later is held to all of this the day it is written.
mods_pieces(){   # -> every shell file in tests/ and tools/ whose code sources the harness, one per line
  grep -l -E '^[[:space:]]*(\.|source)[[:space:]].*mods-harness\.sh' "$ROOT"/tests/*.sh "$ROOT"/tools/*.sh 2>/dev/null | LC_ALL=C sort
}
pieces="$(mods_pieces)"
# Each is a tests/test-*.sh, so run-all-tests.sh, which runs every test-*.sh it finds and nothing
# else, runs it in CI. A piece named any other way would never run, and its checks would be gone with
# nothing red.
np=0; np_bad=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  np=$((np + 1))
  case "$p" in "$ROOT"/tests/test-*.sh) ;; *) np_bad="$np_bad ${p#"$ROOT"/}" ;; esac
done <<< "$pieces"
[ -z "$np_bad" ] && printf '%s\n' "$pieces" | grep -qxF "$ROOT/tests/test-mods.sh" \
  && printf '%s\n' "$pieces" | grep -qxF "$ROOT/tests/test-mods-fixtures.sh" \
  && check "#3622 every file sourcing tests/mods-harness.sh is a tests/test-*.sh suite, so run-all-tests.sh runs it" ok \
  || check "#3622 every file sourcing tests/mods-harness.sh is a tests/test-*.sh suite, so run-all-tests.sh runs it" "found $np: $(printf '%s\n' "$pieces" | sed "s|^$ROOT/||" | tr '\n' ' '); not a tests/test-*.sh:${np_bad:- none}"
# Each numbered section is held by one piece alone, so no check runs twice and the cost of each is
# counted once.
dup="$(while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -E '^# [0-9]+[a-z0-9]*\. ' "$p" | LC_ALL=C sort -u
  done <<< "$pieces" | LC_ALL=C sort | uniq -d)"
[ -z "$dup" ] && check "#3622 no numbered section of the mods suites is held by two pieces" ok \
  || check "#3622 no numbered section of the mods suites is held by two pieces" "in two pieces: $dup"
# Each refuses to run, by the agreed line, when the harness is missing: a draft piece of an earlier
# split went on without a helper it no longer defined and hung for hours. Each is run from a copy in a
# checkout of its own holding the deadline library and no harness.
NH="$TMPROOT/no-harness"; mkdir -p "$NH/tests" "$NH/payload/hooks"
ln -s "$ROOT/payload/hooks/lib" "$NH/payload/hooks/lib"
nh_bad=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  cp "$p" "$NH/tests/"
  nh_out="$(bash "$NH/tests/$(basename "$p")" 2>&1)"; nh_rc=$?
  { [ "$nh_rc" -ne 0 ] && [ "$(printf '%s\n' "$nh_out" | tail -n 1)" = "SUITE-RESULT passed=0 failed=1" ] \
      && printf '%s\n' "$nh_out" | grep -q 'mods-harness.sh is missing'; } \
    || nh_bad="$nh_bad ${p#"$ROOT"/} (exit $nh_rc: $(printf '%s\n' "$nh_out" | tail -n 2 | tr '\n' ' '))"
done <<< "$pieces"
[ -n "$pieces" ] && [ -z "$nh_bad" ] \
  && check "#3622 each piece refuses to run, SUITE-RESULT failed=1, when tests/mods-harness.sh is missing" ok \
  || check "#3622 each piece refuses to run, SUITE-RESULT failed=1, when tests/mods-harness.sh is missing" "${nh_bad:- no piece found}"
# Only tests/mods-real-tree.sh, which the real tree parts source, can reach the real claude (L2). The
# variable holding it is found there and named in no piece's code, nor the harness's, and every
# check-mods.sh run in them names its claude in CLAUDE_BIN, so none falls back to the claude on PATH.
# The name is built here, so this check's own code does not hold it.
rbn="REAL""_BIN"; rb_bad=""; cb_bad=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  grep -v '^[[:space:]]*#' "$p" | grep -q -w "$rbn" && rb_bad="$rb_bad ${p#"$ROOT"/}"
  cb="$(grep -n -E 'bash[[:space:]]+"?(\$CHECK|\$\{CHECK\}|[^[:space:]]*check-mods\.sh)' "$p" | grep -v -E '^[0-9]+:[[:space:]]*#' | grep -v 'CLAUDE_BIN=')"
  [ -z "$cb" ] || cb_bad="$cb_bad ${p#"$ROOT"/}: $cb"
done <<< "$(printf '%s\n%s\n' "$DIR/mods-harness.sh" "$pieces")"
grep -v '^[[:space:]]*#' "$DIR/mods-real-tree.sh" 2>/dev/null | grep -q -w "$rbn" || rb_bad="$rb_bad (and tests/mods-real-tree.sh, its one home, does not hold it)"
[ -n "$pieces" ] && [ -z "$rb_bad" ] \
  && check "#3622 only tests/mods-real-tree.sh holds the claude the real tree is checked with" ok \
  || check "#3622 only tests/mods-real-tree.sh holds the claude the real tree is checked with" "its name is in the code of:${rb_bad:- no piece found}"
[ -n "$pieces" ] && [ -z "$cb_bad" ] \
  && check "#3622 every check-mods.sh run in a piece or the harness names its claude in CLAUDE_BIN" ok \
  || check "#3622 every check-mods.sh run in a piece or the harness names its claude in CLAUDE_BIN" "${cb_bad:- no piece found}"
# The real tree parts are known by their code sourcing tests/mods-real-tree.sh, and between them they
# are parts 1 to MODS_REAL_TREE_PARTS, each once: a part missing would leave its mods unchecked with
# nothing red, and the round it belongs to would never record.
real_parts="$(grep -l -E '^[[:space:]]*(\.|source)[[:space:]].*mods-real-tree\.sh' "$ROOT"/tests/test-*.sh 2>/dev/null | LC_ALL=C sort)"
rp_n="$(sed -n 's/^MODS_REAL_TREE_PARTS=\([0-9][0-9]*\)$/\1/p' "$DIR/mods-real-tree.sh" 2>/dev/null)"
rp_got="$(while IFS= read -r p; do [ -n "$p" ] || continue
    sed -n 's/^[[:space:]]*mods_real_tree_part \([0-9][0-9]*\) "\$MODS_REAL_TREE_PARTS"$/\1/p' "$p"; done <<< "$real_parts" | LC_ALL=C sort -n | paste -sd' ' -)"
rp_want="$( [ -n "$rp_n" ] && seq 1 "$rp_n" | paste -sd' ' -)"
[ -n "$rp_n" ] && [ "$rp_got" = "$rp_want" ] && [ "$(printf '%s\n' "$real_parts" | grep -c .)" -eq "$rp_n" ] \
  && printf '%s\n' "$real_parts" | grep -qxF "$ROOT/tests/test-mods.sh" \
  && check "#3622 the real tree parts are parts 1 to MODS_REAL_TREE_PARTS, each in one suite, test-mods.sh among them" ok \
  || check "#3622 the real tree parts are parts 1 to MODS_REAL_TREE_PARTS, each in one suite, test-mods.sh among them" "parts: ${rp_n:-not found}; suites: $(printf '%s\n' "$real_parts" | sed "s|^$ROOT/||" | tr '\n' ' '); parts they run: $rp_got"
# With no claude anywhere, the real tree piece says so, UNMEASURED, and never records the mods
# passing (L411): a machine without Claude Code must never read as one where every mod passed. Run
# with no claude on PATH, none promised and a home with none, its records kept in this run's scratch.
# A folder on PATH holding a claude is stood in for by a folder of links to everything else in it,
# since node, git or python3 may sit beside it (Homebrew's bin). The only check it may record is the
# real mods' type check, which needs no claude; the pass it must never record is the one case 8
# records where there is a claude, and as CI's own run of test-mods.sh shows, it does there.
if [ -d "$ROOT/payload/mods" ]; then
  nc_path=""; nc_n=0
  IFS=: read -r -a nc_dirs <<< "$PATH"
  for d in "${nc_dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -e "$d/claude" ]; then
      nc_n=$((nc_n + 1)); mkdir -p "$TMPROOT/no-claude-path/$nc_n"
      ln -s "$d"/* "$TMPROOT/no-claude-path/$nc_n/" 2>/dev/null
      rm -f "$TMPROOT/no-claude-path/$nc_n/claude"
      d="$TMPROOT/no-claude-path/$nc_n"
    fi
    nc_path="${nc_path:+$nc_path:}$d"
  done
  mkdir -p "$TMPROOT/no-claude-home"
  nc_bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    : > "$TMPROOT/no-claude-names"
    nc_out="$(env -u MODS_CLAUDE -u CHECK_MODS_REQUIRE_CLAUDE PATH="$nc_path" HOME="$TMPROOT/no-claude-home" \
      CHECK_MODS_FAILURE_OUTPUT="$TMPROOT/no-claude-kept" CHECK_MODS_LAST_PASSED="" MODS_HARNESS_NAMES="$TMPROOT/no-claude-names" \
      bash "$p" 2>&1)"; nc_rc=$?
    nc_other="$(grep -v -x -F "but every real mod's types were checked, with no claude" "$TMPROOT/no-claude-names")"
    { [ "$nc_rc" -eq 0 ] && printf '%s\n' "$nc_out" | grep -q "^SUITE-PART-UNMEASURED the real mods .*against Claude Code's own checks" \
        && [ -z "$nc_other" ]; } \
      || nc_bad="$nc_bad ${p#"$ROOT"/}: exit=$nc_rc checks recorded: $(tr '\n' ';' < "$TMPROOT/no-claude-names") out=$nc_out"
  done <<< "$real_parts"
  [ -n "$real_parts" ] && [ -z "$nc_bad" ] \
    && check "#3622 with no claude anywhere each real tree part says UNMEASURED and never records the mods passing" ok \
    || check "#3622 with no claude anywhere each real tree part says UNMEASURED and never records the mods passing" "${nc_bad:- no real tree part found}"
fi

mods_harness_result
