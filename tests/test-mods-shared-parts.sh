#!/bin/bash
# Tests for what every mod shares (section 9 of the mods suites): each part that lives once, in
# mod-kit, held there by tools/check-mod-shared-parts.sh, which fails a mod keeping its own copy, run
# on fixture mods and then on the real tree. The claude binary is the harness's stub throughout: a
# test must never start a real Claude Code (L2).
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
# 9. What every mod shares lives once, in mod-kit: the shell command reader, the blocked card,
#    the band above the prompt, which Claude Code gives one drawing (#610), the drawing of a card
#    in a side pane (#690), and the retry of a refused message to another session (#688)
#    (L613: the component plus the scan that fails on the next hand rolled copy). Three guards each
#    read commands their own way before batch 2 of the mods milestone.
M9="$TMPROOT/m9"
mkmodsrc(){   # $1 = mods dir  $2 = mod name  $3 = the hooks module's source
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks"
  printf '{ "name": "%s", "version": "0.1.0", "description": "t" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
  printf '%s\n' "$3" > "$1/$2/hooks/register.ts"
}
mkmodsrc "$M9" clean-mod "export const register = on => { on('tool.call', async (\$, e, next) => next(e)) }"
mkmodsrc "$M9" mod-kit "const parts = cmd.split(/&&|;/); if (c === '\"' || c === \"'\") q = c; on('ui.render', { component: 'ToolResult' }, h); on('ui.render', { component: 'AbovePrompt' }, band); <Text strikethrough={p.strikethrough}>{'\\u2502'}</Text>; if (sent.isDelivered) return sent; return why || 'no reason given'; if (name === 'tee') add(f); const hasGit = dir => built.fs.exists(\`\${dir}/.git\`); const P = /\\bchild_process\\b/; const b = await run(['git', '-C', root, 'branch', '--show-current'])"
# A mod that sends once and reports a refusal is what every sender looks like after #688, so it passes.
# A pane drawn its own way (the goals pane: a live list read at each draw, not a card) is not a copy.
mkmodsrc "$M9" clean-live-pane "on('ui.render', { component: 'Pane', requestId: 'goals' }, (\$, e) => <Text dimColor>{row.sentence}</Text>)"
mkmodsrc "$M9" clean-sender "const sent = await \$.session.send({ to: { sessionId }, text }); if (!sent.isDelivered) failed.push(sent.reason)"
# A comment may name what mod-kit draws, in quotes too: a comment draws nothing (#698). A line
# starting with * counts as a comment only inside one (#732).
mkmodsrc "$M9" clean-comment "// mod-kit alone hooks 'AbovePrompt' and draws each 'ToolResult' card
/* the band is mod-kit's 'AbovePrompt' hook */
/**
 * its \"ToolResult\" row is the boxed card
 */
export const register = on => { on('tool.call', async (\$, e, next) => next(e)) }"
out="$(bash "$SHARED" "$M9" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "mod-kit itself may hold the shared parts, and a clean mod passes" ok \
  || check "mod-kit itself may hold the shared parts, and a clean mod passes" "exit=$code out=$out"
case "$out" in *"5 mods checked"*) check "and the count is stated" ok ;; *) check "and the count is stated" "$out" ;; esac
case "$out" in *clean-comment*) check "a comment naming the band or a result row is not taken for a copy" "$out" ;; *) check "a comment naming the band or a result row is not taken for a copy" ok ;; esac
# #712 moved the last known exceptions (the collision guard's and no build's write readers, the
# collision guard's walk for a checkout) onto mod-kit, so either mod keeping a copy now fails the
# run like any other, never named as an exception again (L373: the exception's premise is spent).
M9X="$TMPROOT/m9x"
mkmodsrc "$M9X" collision-guard "switch (name) { case 'tee': add(f) }
const hasGit = dir => \$.fs.stat(\`\${dir === '/' ? '' : dir}/.git\`)"
mkmodsrc "$M9X" scope-modes "const ALL_ARGS = new Set(['mv', 'rm', 'tee'])
const PROCESS = /\\bsubprocess\\b/"
out="$(bash "$SHARED" "$M9X" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "after #712 the collision guard or no build keeping its own reader fails the run" ok \
  || check "after #712 the collision guard or no build keeping its own reader fails the run" "exit=$code out=$out"
case "$out" in *'known exception'*) check "and is never named as a known exception" "$out" ;; *) check "and is never named as a known exception" ok ;; esac
for want in 'collision-guard keeps its own write-reader' 'collision-guard keeps its own working-tree' 'scope-modes keeps its own write-reader' 'scope-modes keeps its own program-reader'; do
  case "$out" in *"$want"*) check "and names: $want" ok ;; *) check "and names: $want" "$out" ;; esac
done
printf '%s\n' "$out" | grep 'scope-modes keeps its own program-reader' | grep -q 'modkit.pipeline(' \
  && check "and points a mod judging code its own way at what modkit.pipeline gives" ok || check "and points a mod judging code its own way at what modkit.pipeline gives" "$out"
# #3171: mod-kit's file reader (hooks/reaches.ts, #2710) lost its last user when the Slack alert
# guard was retired (#3169) and was deleted, so the remedy must not send a mod to a file that is gone.
printf '%s\n' "$out" | grep 'scope-modes keeps its own program-reader' | grep -q -e 'reaches\.ts' -e 'fileReach' \
  && check "and never points a mod at the deleted file reader" "$out" || check "and never points a mod at the deleted file reader" ok
# #939: a button must work where it is drawn. A mod-kit button's press reaches its mod through
# modkit.press, which a click and a typed /press both raise, so a mod hooking ui.press for one is
# reached by a click alone and fails the run. A mod drawing its own Button must ask
# $.modkit.clickable in that file, or it shows a button a click may not reach (Apple Terminal).
M9PRESS="$TMPROOT/m9press"
mkmodsrc "$M9PRESS" mod-kit "export const register = on => { on('ui.press', { plugin: 'mod-kit' }, h) }"
mkmodsrc "$M9PRESS" presses-single "export const register = on => { on('ui.press', { plugin: 'mod-kit', element: 'presses-single:go' }, h) }"
mkmodsrc "$M9PRESS" presses-double "export const register = on => { on(\"ui.press\", { plugin: \"mod-kit\" }, h) }"
# Written across lines, or filtered through a constant: the engine takes either (lessons review of #957).
mkmodsrc "$M9PRESS" presses-multiline "export const register = on => {
  on('ui.press', {
    plugin: 'mod-kit',
    element: 'presses-multiline:go',
  }, h)
}"
mkmodsrc "$M9PRESS" presses-split-call "export const register = on => {
  on(
    'ui.press',
    { plugin: 'mod-kit' },
    h,
  )
}"
mkmodsrc "$M9PRESS" presses-constant "const KIT = { plugin: 'mod-kit' } as const
export const register = on => { on('ui.press', KIT, h) }"
mkmodsrc "$M9PRESS" own-button-unasked "export const draw = (\$, e, Button) => <Button key=\"go\" label=\"Go\" onPress={go} />"
mkmodsrc "$M9PRESS" own-button-asked "export const draw = async (\$, e, Button, Text) => ((await \$.modkit.clickable(e)) ? <Button key=\"go\" label=\"Go\" onPress={go} /> : <Text>type: /go</Text>)"
mkmodsrc "$M9PRESS" own-button-cast "export const draw = async (\$, e, Button) => ((await (\$ as unknown as K).modkit.clickable(e)) ? <Button key=\"go\" label=\"Go\" onPress={go} /> : null)"
mkmodsrc "$M9PRESS" own-press "export const register = on => { on('modkit.press', h); on('ui.press', { plugin: 'own-press' }, mine) }"
mkmodsrc "$M9PRESS" press-in-comment "// a mod used to hook 'ui.press' for mod-kit's buttons; <Button> is drawn by mod-kit
export const register = on => { on('modkit.press', h) }"
out="$(bash "$SHARED" "$M9PRESS" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#939: hooking ui.press for mod-kit's buttons, or an unasked Button, fails the run" ok \
  || check "#939: hooking ui.press for mod-kit's buttons, or an unasked Button, fails the run" "exit=$code out=$out"
for want in 'presses-single hooks ui.press' 'presses-double hooks ui.press' 'presses-multiline hooks ui.press' 'presses-split-call hooks ui.press' 'presses-constant hooks ui.press' 'own-button-unasked draws its own Button'; do
  case "$out" in *"$want"*) check "and names: $want" ok ;; *) check "and names: $want" "$out" ;; esac
done
printf '%s\n' "$out" | grep 'presses-single hooks ui.press' | grep -q "on('modkit.press'" \
  && check "and points a mod at modkit.press" ok || check "and points a mod at modkit.press" "$out"
for clean in own-button-asked own-button-cast own-press press-in-comment; do
  case "$out" in *"check-mod-shared-parts: $clean"*) check "#939: $clean passes" "$out" ;; *) check "#939: $clean passes" ok ;; esac
done
# #712, #730: a mod's tests may read with mod-kit's own readers, through a copy under tests/mod-kit
# (a test cannot import another mod's files), held byte for byte to mod-kit's (L422). A copy that
# differs fails, naming the cp that brings it back; running that cp passes (L406); a copy of a file
# mod-kit does not have fails too.
M9C="$TMPROOT/m9c"
mkmodsrc "$M9C" mod-kit "export const reader = 1"
mkdir -p "$M9C/mod-kit/types"; printf 'export type T = 1\n' > "$M9C/mod-kit/types/index.d.ts"
mkmodsrc "$M9C" reads-real "export const register = () => {}"
mkdir -p "$M9C/reads-real/tests/mod-kit/hooks" "$M9C/reads-real/tests/mod-kit/types"
cp "$M9C/mod-kit/hooks/register.ts" "$M9C/reads-real/tests/mod-kit/hooks/register.ts"
cp "$M9C/mod-kit/types/index.d.ts" "$M9C/reads-real/tests/mod-kit/types/index.d.ts"
out="$(bash "$SHARED" "$M9C" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a mod's tests reading with a copy of mod-kit's own reader pass while it matches" ok \
  || check "a mod's tests reading with a copy of mod-kit's own reader pass while it matches" "exit=$code out=$out"
printf 'export const reader = 2\n' > "$M9C/mod-kit/hooks/register.ts"
out="$(bash "$SHARED" "$M9C" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a copy that no longer matches mod-kit's fails the run" ok || check "a copy that no longer matches mod-kit's fails the run" "exit=$code out=$out"
remedy="$(printf '%s\n' "$out" | grep "reads-real's tests/mod-kit/hooks/register.ts differs" | sed 's/.*: \(cp .*\)$/\1/')"
case "$remedy" in cp*) check "and names the cp that brings it back" ok ;; *) check "and names the cp that brings it back" "$out" ;; esac
# In a subshell, here and for #1281's remedy below: text the checker printed, run in this shell,
# could set any of this suite's variables, so the Slack drafts gate stopped being sure where ROOT
# points and refused the whole suite at its ts_source step (#2654). A cp needs nothing from this shell.
[ -n "$remedy" ] && ( eval "$remedy" )
out="$(bash "$SHARED" "$M9C" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "and running that cp passes the run again" ok || check "and running that cp passes the run again" "exit=$code out=$out"
printf 'x\n' > "$M9C/reads-real/tests/mod-kit/hooks/gone.ts"
out="$(bash "$SHARED" "$M9C" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q "reads-real's tests/mod-kit/hooks/gone.ts copies no file of mod-kit's" \
  && check "a copy of a file mod-kit does not have fails the run, named" ok || check "a copy of a file mod-kit does not have fails the run, named" "exit=$code out=$out"
# #1484: Claude Code's core stands in for a guard's tests once, in mod-kit's tests/core.ts. Five
# tests each raised the tool.check chain themselves, so when 2.1.307's test kit began raising it too,
# four of them judged every call twice. A test raising it its own way fails the run, naming the copy
# to use; a test asking the chain as a query, a comment naming it, and mod-kit itself pass.
M9K="$TMPROOT/m9k"
mkmodsrc "$M9K" mod-kit "export const reader = 1"
mkdir -p "$M9K/mod-kit/tests"
printf 'export const standInCore = (engine, on) => async e => engine.tool.check({ tool: e.tool, input: e })\n' > "$M9K/mod-kit/tests/core.ts"
mkmodsrc "$M9K" own-core "export const register = () => {}"
mkdir -p "$M9K/own-core/tests"
printf "import { test } from 'claude-code/testing'\nconst world = (engine, on) => {\n  on('tool.call', async (\$, e) => { const v = await engine.tool.check({ tool: e.tool, input: e } as never) })\n}\n" > "$M9K/own-core/tests/register.test.tsx"
mkmodsrc "$M9K" shared-core "export const register = () => {}"
mkdir -p "$M9K/shared-core/tests/mod-kit/tests"
cp "$M9K/mod-kit/tests/core.ts" "$M9K/shared-core/tests/mod-kit/tests/core.ts"
printf "import { standInCore } from './mod-kit/tests/core.ts'\n// the stand-in used to call engine.tool.check( itself\n  // and so did engine.tool.check( here\nconst q = await \$.tool.check({ tool: 'Bash', input: {} } as never)\n" > "$M9K/shared-core/tests/register.test.ts"
out="$(bash "$SHARED" "$M9K" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#1484: a test raising the tool.check chain its own way fails the run" ok \
  || check "#1484: a test raising the tool.check chain its own way fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'own-core' | grep 'tests/register.test.tsx:3' | grep -q 'standInCore' \
  && check "#1484: naming the file and line, and pointing at mod-kit's standInCore" ok \
  || check "#1484: naming the file and line, and pointing at mod-kit's standInCore" "$out"
case "$out" in *"check-mod-shared-parts: shared-core"*|*"check-mod-shared-parts: mod-kit"*) check "#1484: a query, a comment and mod-kit's own stand-in pass" "$out" ;; *) check "#1484: a query, a comment and mod-kit's own stand-in pass" ok ;; esac
# #1577: the runner gives every test 5,000 ms of wall clock unless told otherwise, and has no file
# wide or global setting, so a test file taking `test` from 'claude-code/testing' itself is judged
# by how busy the Mac is (twenty copies of mod-kit's tests under load failed 20 of 20 on
# 2026-10-23, nothing broken). Every test file takes it from mod-kit's tests/hang-ceiling.ts, whose
# limit only a hang reaches; mod-kit's own tests included, and in any spelling of the import: on
# its own line, across lines, renamed, or the whole module. Types alone, a comment, and the shared
# file itself pass.
M9T7="$TMPROOT/m9t7"
mkmodsrc "$M9T7" mod-kit "export const reader = 1"
mkdir -p "$M9T7/mod-kit/tests"
printf "import { test as kitTest } from 'claude-code/testing'\nexport const test = (n, b) => kitTest(n, { timeoutMs: 120000 }, b)\n" > "$M9T7/mod-kit/tests/hang-ceiling.ts"
printf "import { expect, test } from 'claude-code/testing'\n" > "$M9T7/mod-kit/tests/own.test.ts"
printf "import { expect } from 'claude-code/testing'\nimport { test } from './hang-ceiling.ts'\n" > "$M9T7/mod-kit/tests/kit-shared.test.ts"
mkmodsrc "$M9T7" plain "export const register = () => {}"
mkdir -p "$M9T7/plain/tests"
printf "import { expect, mock, test } from 'claude-code/testing'\n" > "$M9T7/plain/tests/register.test.ts"
mkmodsrc "$M9T7" spread "export const register = () => {}"
mkdir -p "$M9T7/spread/tests"
printf "import type { Engine } from 'claude-code/testing'\nimport {\n  expect,\n  test,\n} from 'claude-code/testing'\n" > "$M9T7/spread/tests/a.test.tsx"
printf "import { describe, test as t } from \"claude-code/testing\"\n" > "$M9T7/spread/tests/b.test.ts"
printf "import * as kit from 'claude-code/testing'\n" > "$M9T7/spread/tests/c.test.ts"
mkmodsrc "$M9T7" shared "export const register = () => {}"
mkdir -p "$M9T7/shared/tests/mod-kit/tests"
cp "$M9T7/mod-kit/tests/hang-ceiling.ts" "$M9T7/shared/tests/mod-kit/tests/hang-ceiling.ts"
printf "import type { Engine } from 'claude-code/testing'\nimport { expect, mock } from 'claude-code/testing'\n// it used to import { test } from 'claude-code/testing'\n/* and import { expect, test } from 'claude-code/testing' */\nimport { test } from './mod-kit/tests/hang-ceiling.ts'\nimport { latest } from './contest.ts'\n" > "$M9T7/shared/tests/register.test.ts"
out="$(bash "$SHARED" "$M9T7" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#1577: a test file taking test from claude-code/testing itself fails the run" ok \
  || check "#1577: a test file taking test from claude-code/testing itself fails the run" "exit=$code out=$out"
for at in "plain's tests/register.test.ts:1" "spread's tests/a.test.tsx:2" "spread's tests/b.test.ts:1" "spread's tests/c.test.ts:1" "mod-kit's tests/own.test.ts:1"; do
  printf '%s\n' "$out" | grep -F "$at" | grep -q 'hang-ceiling.ts' \
    && check "#1577: $at is named, pointing at mod-kit's tests/hang-ceiling.ts" ok \
    || check "#1577: $at is named, pointing at mod-kit's tests/hang-ceiling.ts" "$out"
done
printf '%s\n' "$out" | grep -F "plain's tests/register.test.ts:1" | grep -qF "cp \"$M9T7/mod-kit/tests/hang-ceiling.ts\" \"$M9T7/plain/tests/mod-kit/tests/hang-ceiling.ts\"" \
  && check "#1577: and names the cp that brings the shared file in" ok || check "#1577: and names the cp that brings the shared file in" "$out"
case "$out" in *"shared's tests"*|*"kit-shared"*|*"hang-ceiling.ts:"*) check "#1577: types alone, a comment, the shared file and its users pass" "$out" ;; *) check "#1577: types alone, a comment, the shared file and its users pass" ok ;; esac
rm -f "$M9T7/mod-kit/tests/own.test.ts" "$M9T7/plain/tests/register.test.ts" "$M9T7/spread/tests/"*.ts*
out="$(bash "$SHARED" "$M9T7" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "#1577: with every test file on the shared test, the run passes" ok \
  || check "#1577: with every test file on the shared test, the run passes" "exit=$code out=$out"
# The shared file holds the hang ceiling the real tests run under, and nothing else sets a lower one.
HC="$ROOT/payload/mods/mod-kit/tests/hang-ceiling.ts"
grep -qE '^export const HANG_MS = 120_000$' "$HC" 2>/dev/null \
  && check "#1577: mod-kit's tests/hang-ceiling.ts sets two minutes, which only a hang reaches" ok \
  || check "#1577: mod-kit's tests/hang-ceiling.ts sets two minutes, which only a hang reaches" "$(grep -n 'HANG_MS =' "$HC" 2>&1)"

# #1778: a stand-in that never answers outlived its test by the engine's five second linger and
# finished inside a later one, which failed the job watcher's tests at random under load. Each comes
# from the hang ceiling's never(), which every test ends as it ends, so a hand rolled promise that
# never settles, in any mod's tests or mod-kit's own, fails the run, pointing at never().
M9NV="$TMPROOT/m9nv"
mkmodsrc "$M9NV" mod-kit "export const reader = 1"
mkdir -p "$M9NV/mod-kit/tests"
cp "$HC" "$M9NV/mod-kit/tests/hang-ceiling.ts"
printf "import { test } from './hang-ceiling.ts'\nconst wait = () => new Promise<void>(() => {})\n" > "$M9NV/mod-kit/tests/kit.test.ts"
mkmodsrc "$M9NV" rolls "export const register = () => {}"
mkdir -p "$M9NV/rolls/tests/mod-kit/tests"
cp "$HC" "$M9NV/rolls/tests/mod-kit/tests/hang-ceiling.ts"
printf "import { test } from './mod-kit/tests/hang-ceiling.ts'\non('tool.call', () => new Promise<never>(() => undefined) as never)\nconst q = () => new Promise( () => undefined )\n" > "$M9NV/rolls/tests/register.test.ts"
mkmodsrc "$M9NV" asks "export const register = () => {}"
mkdir -p "$M9NV/asks/tests/mod-kit/tests"
cp "$HC" "$M9NV/asks/tests/mod-kit/tests/hang-ceiling.ts"
printf "import { never, test } from './mod-kit/tests/hang-ceiling.ts'\non('tool.call', () => never() as never)\nconst held = new Promise<void>(r => (release = r))\n" > "$M9NV/asks/tests/register.test.ts"
out="$(bash "$SHARED" "$M9NV" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#1778: a hand rolled promise that never settles in a mod's tests fails the run" ok \
  || check "#1778: a hand rolled promise that never settles in a mod's tests fails the run" "exit=$code out=$out"
for at in "rolls's tests/register.test.ts:2" "rolls's tests/register.test.ts:3" "mod-kit's tests/kit.test.ts:2"; do
  printf '%s\n' "$out" | grep -F "$at" | grep -q 'never()' \
    && check "#1778: $at is named, pointing at the hang ceiling's never()" ok \
    || check "#1778: $at is named, pointing at the hang ceiling's never()" "$out"
done
case "$out" in *"asks's"*|*"hang-ceiling.ts:"*) check "#1778: never() itself, a promise the test settles, and the shared file pass" "$out" ;; *) check "#1778: never() itself, a promise the test settles, and the shared file pass" ok ;; esac
rm -f "$M9NV/mod-kit/tests/kit.test.ts" "$M9NV/rolls/tests/register.test.ts"
out="$(bash "$SHARED" "$M9NV" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "#1778: with every stand-in from never(), the run passes" ok \
  || check "#1778: with every stand-in from never(), the run passes" "exit=$code out=$out"
# And the shared file ends what each test held, waiting for the calls handed to it, as the test ends.
grep -qE 'return await body\(\$, on\)' "$HC" 2>/dev/null && grep -qE '^    await endHeld\(\)$' "$HC" 2>/dev/null \
  && check "#1778: mod-kit's tests/hang-ceiling.ts ends what every test held as that test ends" ok \
  || check "#1778: mod-kit's tests/hang-ceiling.ts ends what every test held as that test ends" "$(grep -n 'endHeld' "$HC" 2>&1)"

# #1789: Claude Code's test runner gives every hook 10,000 ms of REAL time, the test clock never
# moving it, and cuts a held stand-in off there (measured on 2026-10-26: 10,014 to 10,028 ms,
# "exceeded 10000ms budget"), so a mod test that waits on real time is judged by how busy the Mac
# is (L290). Time a
# mod observes is moved on the test clock; a real timer past a small floor in any mod's tests, or
# mod-kit's own, fails the run, by file and line, naming the test clock and the condition instead.
M9RT="$TMPROOT/m9rt"
mkmodsrc "$M9RT" mod-kit "export const reader = 1"
mkdir -p "$M9RT/mod-kit/tests"
cp "$HC" "$M9RT/mod-kit/tests/hang-ceiling.ts"
printf "import { test } from './hang-ceiling.ts'\nawait new Promise<void>(r => setTimeout(r, 12_000))\n" > "$M9RT/mod-kit/tests/kit.test.ts"
mkmodsrc "$M9RT" waits "export const register = () => {}"
mkdir -p "$M9RT/waits/tests/mod-kit/tests"
cp "$HC" "$M9RT/waits/tests/mod-kit/tests/hang-ceiling.ts"
cat > "$M9RT/waits/tests/register.test.ts" <<'TS'
import { test } from './mod-kit/tests/hang-ceiling.ts'
const within = <T,>(p: Promise<T>, ms = 2000) => Promise.race([p, new Promise<never>((_, no) => setTimeout(() => no(new Error('late')), ms))])
await Bun.sleep(500)
const tick = setInterval(() => {
  poll()
}, 5_000)
import { setTimeout as wait } from 'node:timers/promises'
Atomics.wait(cell, 0, 0, 100)
TS
mkdir -p "$M9RT/waits/tests/ui"
printf "const t = window.setTimeout(done, 250)\n" > "$M9RT/waits/tests/ui/pane.test.tsx"
mkmodsrc "$M9RT" quick "export const register = () => {}"
mkdir -p "$M9RT/quick/tests/mod-kit/tests"
cp "$HC" "$M9RT/quick/tests/mod-kit/tests/hang-ceiling.ts"
cat > "$M9RT/quick/tests/register.test.ts" <<'TS'
import { test } from './mod-kit/tests/hang-ceiling.ts'
// it used to wait with setTimeout(r, 12_000), and /* setInterval(f, 5_000) */ before that
declare function setTimeout(run: () => void, ms: number): number
await new Promise<void>(r => setTimeout(r, 0))
await new Promise<void>(r => setTimeout(r))
await new Promise<void>(r => setTimeout(r, 50))
const loop = 'until curl -sf http://x; do sleep 30; setTimeout(9000); done'
await clock.advance(21 * MIN)
await $.clock.sleep(5_000)
TS
out="$(bash "$SHARED" "$M9RT" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#1789: a mod test waiting on real time fails the run" ok \
  || check "#1789: a mod test waiting on real time fails the run" "exit=$code out=$out"
for at in "waits's tests/register.test.ts:2" "waits's tests/register.test.ts:3" "waits's tests/register.test.ts:4" "waits's tests/register.test.ts:7" "waits's tests/register.test.ts:8" "waits's tests/ui/pane.test.tsx:1" "mod-kit's tests/kit.test.ts:2"; do
  printf '%s\n' "$out" | grep -F "$at" | grep -q 'mock.clock' \
    && check "#1789: $at is named, pointing at the test clock" ok \
    || check "#1789: $at is named, pointing at the test clock" "$out"
done
printf '%s\n' "$out" | grep -F "waits's tests/register.test.ts:4" | grep -qF '5_000 ms' \
  && check "#1789: a delay written past the line of the call is read" ok \
  || check "#1789: a delay written past the line of the call is read" "$out"
case "$out" in *"quick's"*|*"waits's tests/register.test.ts:5"*|*"waits's tests/register.test.ts:6"*) check "#1789: a yield under the floor, a declaration, comments, strings and the test clock pass" "$out" ;; *) check "#1789: a yield under the floor, a declaration, comments, strings and the test clock pass" ok ;; esac
rm -f "$M9RT/mod-kit/tests/kit.test.ts" "$M9RT/waits/tests/register.test.ts" "$M9RT/waits/tests/ui/pane.test.tsx"
out="$(bash "$SHARED" "$M9RT" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "#1789: with no real wait in any mod test, the run passes" ok \
  || check "#1789: with no real wait in any mod test, the run passes" "exit=$code out=$out"
# #698: the band and result row were caught in one literal form on one line; a probe of 11 hand
# rolled forms caught 3. The engine takes an unfiltered ui.render hook that tests e.component, and a
# filter however it is spelled, so each form a mod could write is caught, with the remedy for it.
M9F="$TMPROOT/m9f"
mkmodsrc "$M9F" form-unfiltered-band "on('ui.render', (\$, e, next) => (e.component === 'AbovePrompt' ? draw(\$, e) : next(e)))"
mkmodsrc "$M9F" form-unfiltered-card "on('ui.render', (\$, e, next) => { if (e.component !== 'ToolResult') return next(e); return draw(\$, e) })"
mkmodsrc "$M9F" form-shorthand-band "const component = 'AbovePrompt' as const
export const register = on => { on('ui.render', { component }, draw) }"
mkmodsrc "$M9F" form-constant-card "const ROW = 'ToolResult'
export const register = on => { on('ui.render', { component: ROW }, draw) }"
mkmodsrc "$M9F" form-spaced-band "on('ui.render', { component : 'AbovePrompt' }, draw)"
mkmodsrc "$M9F" form-quoted-key-card "on('ui.render', { 'component': 'ToolResult' }, draw)"
mkmodsrc "$M9F" form-quoted-key-band "on('ui.render', { \"component\": \"AbovePrompt\" }, draw)"
mkmodsrc "$M9F" form-backtick-band "on('ui.render', { component: \`AbovePrompt\` }, draw)"
mkmodsrc "$M9F" form-next-line-card "on('ui.render', {
  component:
    'ToolResult',
}, draw)"
mkmodsrc "$M9F" form-switch-band "on('ui.render', (\$, e, next) => { switch (e.component) { case 'AbovePrompt': return draw(\$, e); default: return next(e) } })"
mkmodsrc "$M9F" form-list-card "const MINE = ['ToolResult', 'Pane']
export const register = on => { on('ui.render', (\$, e, next) => (MINE.includes(e.component) ? draw(\$, e) : next(e))) }"
out="$(bash "$SHARED" "$M9F" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "every hand rolled form of a band or result row hook fails the run" ok \
  || check "every hand rolled form of a band or result row hook fails the run" "exit=$code out=$out"
for m in form-unfiltered-band form-shorthand-band form-spaced-band form-quoted-key-band form-backtick-band form-switch-band; do
  printf '%s\n' "$out" | grep "$m " | grep -q 'modkit.bandRow(' && check "and names $m, pointing it at modkit.bandRow" ok \
    || check "and names $m, pointing it at modkit.bandRow" "$out"
done
for m in form-unfiltered-card form-constant-card form-quoted-key-card form-next-line-card form-list-card; do
  printf '%s\n' "$out" | grep "$m " | grep -q 'modkit.card(' && check "and names $m, pointing it at modkit.card" ok \
    || check "and names $m, pointing it at modkit.card" "$out"
done
# The line named is the one holding the component, so a value on the next line is found where it is.
printf '%s\n' "$out" | grep -q 'form-next-line-card keeps its own card at /hooks/register.ts:3:' \
  && check "and names the line the value stands on" ok || check "and names the line the value stands on" "$out"
mkmodsrc "$M9" own-reader "const words = command.split(/&&|\|\||;/).map(s => s.trim())"
mkmodsrc "$M9" own-quotes "for (const c of cmd) { if (c === '\"' || c === \"'\") quote = c }"
# The two brackets are written apart, so this planted reader is not itself a line holding a hand
# written marker reader for payload/hooks/test-hand-rolled-heredoc-marker.sh (claude-config#2080).
_H='<''<'
mkmodsrc "$M9" own-heredoc "const m = /(?<!<)$_H(?!<)-?\s*(\w+)/.exec(line)"
mkmodsrc "$M9" own-card "on('ui.render', { component: 'ToolResult' }, (\$, e, next) => next(e))"
mkmodsrc "$M9" own-git "const GLOBAL = new Set(['-C', '-c', '--git-dir', '--work-tree'])"
mkmodsrc "$M9" own-band "on('ui.render', { component: 'AbovePrompt' }, (\$, e, next) => next(e))"
mkmodsrc "$M9" own-band-dq "on(\"ui.render\", { component: \"AbovePrompt\" }, h)"
mkmodsrc "$M9" own-card-dq "on(\"ui.render\", { component: \"ToolResult\" }, h)"
mkmodsrc "$M9" own-pane "<Text key={String(i)} color={p.color} dimColor={p.dim} strikethrough={p.strikethrough}>{p.text}</Text>"
mkmodsrc "$M9" own-rule "<Text key={String(n)} color={AMBER}>{'\\u2502'}</Text>"
mkmodsrc "$M9" own-rule-literal "<Text color={AMBER}>{'│'}</Text>"
mkmodsrc "$M9" own-retry "for (let attempt = 0; attempt < 2; attempt++) { const sent = await \$.session.send(m); if (sent.isDelivered) return undefined }"
mkmodsrc "$M9" own-reason "return why.trim().replace(/\\.\$/, '') || 'no reason given'"
# #705: ask before saving kept its own reader of which files a command writes, and it disagreed
# with the collision guard's and no build's.
mkmodsrc "$M9" own-writes "if (name === 'tee') out.push(...args.filter(w => !w.startsWith('-')))"
mkmodsrc "$M9" own-writes-dq "const ALL = new Set([\"mv\", \"tee\"])"
# #726: a mod finding the checkout a path sits in by its own walk for a .git entry.
mkmodsrc "$M9" own-tree "for (let d = path; d !== '/'; d = parent(d)) if (await \$.fs.exists(d + '/.git')) return d"
out="$(bash "$SHARED" "$M9" 2>&1)"; code=$?
printf '%s\n' "$out" | grep 'own-tree ' | grep -q 'modkit.workingTree(' \
  && check "and points a mod with its own working tree walk at modkit.workingTree" ok || check "and points a mod with its own working tree walk at modkit.workingTree" "$out"
[ "$code" -eq 1 ] && check "a mod with its own copy of a shared part fails the run" ok \
  || check "a mod with its own copy of a shared part fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'own-writes ' | grep -q 'modkit.writes(' \
  && check "and points a mod with its own write reader at modkit.writes" ok || check "and points a mod with its own write reader at modkit.writes" "$out"
for m in own-reader own-quotes own-heredoc own-card own-card-dq own-git own-band own-band-dq own-pane own-rule own-rule-literal own-retry own-reason own-writes own-writes-dq; do
  case "$out" in *"$m"*) check "and names $m" ok ;; *) check "and names $m" "$out" ;; esac
done
# A mod drawing its own result row is pointed at the card any tool result can use (#663).
printf '%s\n' "$out" | grep 'own-card ' | grep -q 'modkit.card(' \
  && check "and points a mod's own result row at modkit.card" ok || check "and points a mod's own result row at modkit.card" "$out"
case "$out" in *clean-live-pane*) check "a pane drawn its own way, not as a card, is not taken for a copy" "$out" ;; *) check "a pane drawn its own way, not as a card, is not taken for a copy" ok ;; esac
case "$out" in *clean-sender*) check "a mod sending once and reporting the refusal is not taken for a copy" "$out" ;; *) check "a mod sending once and reporting the refusal is not taken for a copy" ok ;; esac
printf '%s\n' "$out" | grep 'own-pane ' | grep -q 'modkit.pane(' \
  && check "and points a mod's own pane at modkit.pane" ok || check "and points a mod's own pane at modkit.pane" "$out"
printf '%s\n' "$out" | grep 'own-retry ' | grep -q 'session.send' \
  && check "and tells a mod with its own retry that mod-kit retries every send" ok || check "and tells a mod with its own retry that mod-kit retries every send" "$out"
# The screen (#707): a mod that answers a tool call itself keeps the call from every guard beneath
# it, so it must ask mod-kit's screen first. One answering with a result that never asks fails and is
# named; one that asks passes, and so does one that only passes a result on from next.
M9S="$TMPROOT/m9s"
mkmodsrc "$M9S" asks-first "on('tool.call', { tool: 'mcp__x__pin' }, async (\$, e) => { const refused = await \$.modkit.screen(e); if (refused) return refused; return { result: 'Pinned.' } })"
mkmodsrc "$M9S" passes-on "on('tool.call', async (\$, e, next) => { const r = await next(e); return { ...r, context: ['noted'] } })"
mkmodsrc "$M9S" answers-unscreened "on('tool.call', { tool: 'mcp__x__save' }, async (\$, e) => {
  await \$.fs.write('/tmp/x', String(e.prompt))
  return {
    result: 'Saved.',
  }
})"
out="$(bash "$SHARED" "$M9S" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod answering a tool call without asking the screen fails the run" ok \
  || check "a mod answering a tool call without asking the screen fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'answers-unscreened ' | grep -q 'modkit.screen(e)' \
  && check "and is named, pointed at \$.modkit.screen" ok || check "and is named, pointed at \$.modkit.screen" "$out"
case "$out" in *asks-first*|*passes-on*) check "a mod that asks first, or passes on next's result, is not named" "$out" ;; *) check "a mod that asks first, or passes on next's result, is not named" ok ;; esac
# #732: each answering tool.call hook asks the screen itself (L135). A screen in one hook does not
# cover another beside it, a screen named only in a comment asks nothing, and a hook whose body is
# a named function is read where that function is defined.
M9P="$TMPROOT/m9p"
mkmodsrc "$M9P" one-of-two "export const register = on => {
  on('tool.call', { tool: 'mcp__x__pin' }, async (\$, e) => {
    const refused = await \$.modkit.screen(e)
    if (refused) return refused
    return { result: 'Pinned.' }
  })
  on('tool.call', { tool: 'mcp__x__done' }, async (\$, e) => {
    return { result: 'Done.' }
  })
}"
mkmodsrc "$M9P" both-screened "export const register = on => {
  on('tool.call', { tool: 'mcp__x__pin' }, async (\$, e) => {
    const refused = await \$.modkit.screen(e)
    return refused ?? { result: 'Pinned.' }
  })
  on(\"tool.call\", { tool: 'mcp__x__done' }, async (\$, e) => {
    const refused = await \$.modkit.screen(e)
    return refused ?? { result: 'Done.' }
  })
}"
mkmodsrc "$M9P" screen-in-a-comment "export const register = on => {
  // \$.modkit.screen(e) is asked by the hook beside this one
  on('tool.call', { tool: 'mcp__x__done' }, async (\$, e) => ({ result: 'Done.' }))
}"
mkmodsrc "$M9P" named-unscreened "const answer = async (\$, e) => {
  return { result: 'Saved.' }
}
export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }"
mkmodsrc "$M9P" named-screened "async function answer(\$, e) {
  const refused = await \$.modkit.screen(e)
  if (refused) return refused
  return { result: 'Saved.' }
}
export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }"
# A return type holding braces is the signature, never the body (lessons review of #737).
mkmodsrc "$M9P" named-typed-screened "async function answer(\$, e): Promise<{ result: string } | { deny: string }> {
  const refused = await \$.modkit.screen(e)
  return refused ?? { result: 'Saved.' }
}
export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }"
mkmodsrc "$M9P" named-literal-type-screened "function answer(\$, e): { result: string } {
  \$.modkit.screen(e)
  return { result: 'Saved.' }
}
export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }"
# #739: an arrow whose body is an expression is read to the end of its statement with every bracket
# in it whole: a parenthesised body last in its file, one going on past its bracket, and a call
# spread over lines. Each answers without asking, so each is named, never as a hook not found.
mkmodsrc "$M9P" named-expression-last "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => ({ result: 'Saved.' })"
mkmodsrc "$M9P" named-expression-goes-on "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => (await check(e)) ?? { result: 'Saved.' }"
mkmodsrc "$M9P" named-call-across-lines "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => done({
  result: 'Saved.',
})"
# Each way the body can end (lessons review of #739): the file's very end with no line break after
# it, a ;, the close of a bracket around it, and a bracket that never closes, which is not known.
mkmodsrc "$M9P" named-expression-at-eof ""
printf '%s' "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => ({ result: 'Saved.' })" > "$M9P/named-expression-at-eof/hooks/register.ts"
mkmodsrc "$M9P" named-expression-semicolon "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => ({ result: 'Saved.' }); const other = async (\$, e) => \$.modkit.screen(e)"
mkmodsrc "$M9P" named-expression-in-block "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
function wrap() { const answer = async (\$, e) => ({ result: 'Saved.' }) } const other = async (\$, e) => \$.modkit.screen(e)"
mkmodsrc "$M9P" named-expression-unclosed "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => ({ result: 'Saved.' }"
# A line break ends the body only where the statement does: one going on with an operator at the end
# of a line or the start of the next is read on, and one ending in a string is not.
mkmodsrc "$M9P" named-ternary-across-lines "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => (await check(e))
  ? undefined
  : { result: 'Saved.' }"
mkmodsrc "$M9P" named-then-chain "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => check(e)
  .then(() => ({ result: 'Saved.' }))"
mkmodsrc "$M9P" named-operator-at-line-end "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) =>
  (await check(e)) ??
  { result: 'Saved.' }"
mkmodsrc "$M9P" named-string-at-line-end "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => ({ result: 'Saved.' }) && 'done'
const other = async (\$, e) => \$.modkit.screen(e)"
mkmodsrc "$M9P" clean-string-body "export const register = on => { on('tool.call', { tool: 'mcp__x__save' }, answer) }
const answer = async (\$, e) => 'Saved.'
const other = async (\$, e) => ({ result: 'Other.' })"
out="$(bash "$SHARED" "$M9P" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod with an answering hook that never asks the screen fails, beside one that does" ok \
  || check "a mod with an answering hook that never asks the screen fails, beside one that does" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'one-of-two ' | grep 'modkit.screen(e)' | grep -q '/hooks/register.ts:7' \
  && check "and names the unscreened hook by its line, not the screened one beside it" ok \
  || check "and names the unscreened hook by its line, not the screened one beside it" "$out"
for m in screen-in-a-comment named-unscreened; do
  printf '%s\n' "$out" | grep "$m " | grep -q 'modkit.screen(e)' && check "and names $m" ok || check "and names $m" "$out"
done
case "$out" in *both-screened*|*named-screened*|*named-typed-screened*|*named-literal-type-screened*) check "a mod whose every answering hook asks, a named one with a typed return included, is not named" "$out" ;; *) check "a mod whose every answering hook asks, a named one with a typed return included, is not named" ok ;; esac
for m in named-expression-last named-expression-goes-on named-call-across-lines named-expression-at-eof named-expression-semicolon named-expression-in-block named-ternary-across-lines named-then-chain named-operator-at-line-end named-string-at-line-end; do
  printf '%s\n' "$out" | grep -q "$m answers a tool call itself in its tool.call hook at /hooks/register.ts:1 but never asks" \
    && check "and reads $m's expression body whole, naming it" ok || check "and reads $m's expression body whole, naming it" "$out"
done
printf '%s\n' "$out" | grep -q "named-expression-unclosed's tool.call hook at /hooks/register.ts:1 answers through a named function that cannot be found" \
  && check "and a body whose bracket never closes is said to be unknown, never passed" ok || check "and a body whose bracket never closes is said to be unknown, never passed" "$out"
case "$out" in *clean-string-body*) check "a string body is the body, never the line after it" "$out" ;; *) check "a string body is the body, never the line after it" ok ;; esac
# #732 (lessons review of #731): a walk for a checkout is caught however its .git entry is spelled,
# joined, bare or inside a longer path, and a name that merely starts with .git is not one.
M9G="$TMPROOT/m9g"
mkmodsrc "$M9G" clean-git-words "const ignore = path.join(root, '.gitignore'); const wf = '.github/workflows'; const url = 'https://github.com/x/y.git'"
out="$(bash "$SHARED" "$M9G" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a name that merely starts with .git, or a repository address, is not a walk" ok \
  || check "a name that merely starts with .git, or a repository address, is not a walk" "exit=$code out=$out"
mkmodsrc "$M9G" tree-joined "if (await \$.fs.exists(path.join(dir, '.git'))) return dir"
mkmodsrc "$M9G" tree-bare "const MARKER = '.git'"
mkmodsrc "$M9G" tree-template "const head = await \$.fs.read(\`\${d}/.git/HEAD\`)"
out="$(bash "$SHARED" "$M9G" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a walk for a checkout spelled any way fails the run" ok || check "a walk for a checkout spelled any way fails the run" "exit=$code out=$out"
for m in tree-joined tree-bare tree-template; do
  printf '%s\n' "$out" | grep "$m " | grep -q 'modkit.workingTree(' && check "and names $m, pointing it at modkit.workingTree" ok \
    || check "and names $m, pointing it at modkit.workingTree" "$out"
done
case "$out" in *clean-git-words*) check "and the names that merely start with .git still pass" "$out" ;; *) check "and the names that merely start with .git still pass" ok ;; esac
# #951: reading a session's repository from its origin by hand, as four mods did before mod-kit's
# one reader. Each copy as it stood fails the run, pointed at $.modkit.repo; a mod asking the kit,
# or merely naming an address, passes.
M9R="$TMPROOT/m9r"
mkmodsrc "$M9R" clean-asks-kit 'const { github } = await $.modkit.repo({ root: r.root, remote: r.remote }); const url = "https://github.com/x/y.git"'
mkmodsrc "$M9R" remote-regex 'const m = /github\.com[:/]([\w.-]+\/[\w.-]+?)(?:\.git)?\/?$/.exec(remote ?? "")'
mkmodsrc "$M9R" remote-last-part 'let name = lastPart((repo.remote ?? "").trim(), /[/:]/).replace(/\.git$/i, "")'
mkmodsrc "$M9R" remote-strip 'let t = s.trim().replace(/\.git$/, "").replace(/\/+$/, "")'
out="$(bash "$SHARED" "$M9R" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a hand rolled reading of a remote fails the run" ok || check "a hand rolled reading of a remote fails the run" "exit=$code out=$out"
for m in remote-regex remote-last-part remote-strip; do
  printf '%s\n' "$out" | grep "$m keeps its own remote-reader" | grep -q 'modkit.repo(' && check "and names $m, pointing it at modkit.repo" ok \
    || check "and names $m, pointing it at modkit.repo" "$out"
done
case "$out" in *clean-asks-kit*) check "a mod asking the kit, or naming an address, passes" "$out" ;; *) check "a mod asking the kit, or naming an address, passes" ok ;; esac
# #980: reading where a checkout stands by hand (its branch, its default branch, the issues a branch
# names), as scope-modes and the collision guard did before mod-kit's one reader. Each copy as it
# stood fails the run, pointed at $.modkit.branch; a mod asking the kit, or asking git which
# worktrees hold a branch (a different question), passes.
M9B="$TMPROOT/m9b"
mkmodsrc "$M9B" clean-asks-branch 'const b = await $.modkit.branch({ path: cwd }); const wt = await run($, ["git", "-C", root, "worktree", "list", "--porcelain"])'
mkmodsrc "$M9B" branch-show-current 'const b = await run($, ["git", "-C", cwd, "branch", "--show-current"])'
mkmodsrc "$M9B" branch-origin-head 'const head = await run($, ["git", "-C", dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])'
mkmodsrc "$M9B" branch-abbrev-ref 'const r = await run($, ["git", "rev-parse", "--abbrev-ref", "HEAD"])'
mkmodsrc "$M9B" branch-issues 'export const issuesOfBranch = b => [...b.matchAll(/(?:^|[^0-9])(\d{2,6})(?=$|[^0-9])/g)].map(m => Number(m[1]))'
# #1306: a copy of the reading as it now stands, by the parts of the branch name, fails the same way.
mkmodsrc "$M9B" branch-issue-parts 'export const issuesOfBranch = b => b.split(/[/_.-]+/).map(p => /^(\d{2,6})[a-z]?$/i.exec(p)?.[1]).filter(Boolean).map(Number)'
# #3333: git rebase and git am take --show-current-patch, which prints the patch a stopped move is on
# and reads no branch, so a mod naming only that option passes; --show-current at a line's end, as a
# template string split over lines leaves it, is still a branch read by hand.
mkmodsrc "$M9B" clean-names-patch-option 'const looking = flags.has("--show-current-patch") || words.includes(`--show-current-patch`)'
mkmodsrc "$M9B" branch-show-current-end $'const cmd = `git branch --show-current\n`'
out="$(bash "$SHARED" "$M9B" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a hand rolled reading of where a checkout stands fails the run" ok || check "a hand rolled reading of where a checkout stands fails the run" "exit=$code out=$out"
case "$out" in *clean-names-patch-option*) check "#3333 a mod naming only git's --show-current-patch is not taken for a branch read by hand" "$out" ;; *) check "#3333 a mod naming only git's --show-current-patch is not taken for a branch read by hand" ok ;; esac
for m in branch-show-current branch-show-current-end branch-origin-head branch-abbrev-ref branch-issues branch-issue-parts; do
  printf '%s\n' "$out" | grep "$m keeps its own branch-reader" | grep -q 'modkit.branch(' && check "and names $m, pointing it at modkit.branch" ok \
    || check "and names $m, pointing it at modkit.branch" "$out"
done
case "$out" in *clean-asks-branch*) check "a mod asking the kit for its branch, or git for its worktrees, passes" "$out" ;; *) check "a mod asking the kit for its branch, or git for its worktrees, passes" ok ;; esac
# #961 moved scope-modes' gh argument reader into mod-kit, so its copy in hooks/ghargs.ts fails the
# run like any other, never named as a known exception again (L373: the exception's premise is spent).
M9E="$TMPROOT/m9e"
mkmodsrc "$M9E" scope-modes 'export const register = on => {}'
printf '%s\n' 'export const normRepo = s => s.trim().replace(/\.git$/, "")' > "$M9E/scope-modes/hooks/ghargs.ts"
out="$(bash "$SHARED" "$M9E" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "after #961 scope-modes keeping its gh argument reader's address parsing fails the run" ok \
  || check "after #961 scope-modes keeping its gh argument reader's address parsing fails the run" "exit=$code out=$out"
case "$out" in *'known exception'*) check "and is never named as a known exception" "$out" ;; *) check "and is never named as a known exception" ok ;; esac
printf '%s\n' "$out" | grep 'scope-modes keeps its own remote-reader at /hooks/ghargs.ts:1' | grep -q 'modkit.ghRepo(' \
  && check "named by its own file and line, and pointed at modkit.ghRepo" ok || check "named by its own file and line, and pointed at modkit.ghRepo" "$out"
# #961: reading a github.com link's repository by hand, as is it live and scope-modes did four ways
# (no end, an end, a case, a search through gh's output). Each fails the run, pointed at
# $.modkit.linkRepo; a mod asking the kit, or taking api.github.com off an endpoint, passes.
M9L="$TMPROOT/m9l"
mkmodsrc "$M9L" clean-asks-link 'const repo = await $.modkit.linkRepo({ link: url }); const ep = e.replace(/^https:\/\/api\.github\.com\//, "")'
mkmodsrc "$M9L" link-open 'const repoOfUrl = url => /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/\d+/.exec(url ?? "")?.[1]'
mkmodsrc "$M9L" link-anchored 'const repoOfLink = url => /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/\d+$/i.exec(url ?? "")?.[1]'
mkmodsrc "$M9L" link-class 'const LINK = /^(?:https?:\/\/)?(?:www\.)?github\.com\/[^/]+\/[^/]+/i'
out="$(bash "$SHARED" "$M9L" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a hand rolled reading of a github.com link fails the run" ok || check "a hand rolled reading of a github.com link fails the run" "exit=$code out=$out"
for m in link-open link-anchored link-class; do
  printf '%s\n' "$out" | grep "$m keeps its own link-reader" | grep -q 'modkit.linkRepo(' && check "and names $m, pointing it at modkit.linkRepo" ok \
    || check "and names $m, pointing it at modkit.linkRepo" "$out"
done
case "$out" in *clean-asks-link*) check "a mod asking the kit, or taking api.github.com off an endpoint, passes" "$out" ;; *) check "a mod asking the kit, or taking api.github.com off an endpoint, passes" ok ;; esac
# #1251: finding the merge helper by its file's name, as scope-modes (nobuild.ts) and is it live
# (merges.ts) each did with the same pattern. Each shape fails the run, pointed at
# $.modkit.mergeHelper; a mod asking the kit, or naming the helper only in what it says, passes.
M9H="$TMPROOT/m9-merge-helper"
mkmodsrc "$M9H" clean-asks-helper "const h = await \$.modkit.mergeHelper(c); const what = 'merge a PR with merge-when-ready.sh'; say(\`merge-when-ready.sh is merging #\${n}\`)"
mkmodsrc "$M9H" helper-regex 'const HELPER = /(?:^|\/)merge-when-ready\.sh$/'
mkmodsrc "$M9H" helper-unescaped 'const runs = words.some(w => /merge-when-ready.sh/.test(w))'
mkmodsrc "$M9H" helper-ends "const at = words.findIndex(w => w.endsWith('/merge-when-ready.sh'))"
mkmodsrc "$M9H" helper-equal 'if (base(w) === "merge-when-ready.sh") return true'
out="$(bash "$SHARED" "$M9H" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod finding the merge helper by its own match on the name fails the run" ok || check "a mod finding the merge helper by its own match on the name fails the run" "exit=$code out=$out"
for m in helper-regex helper-unescaped helper-ends helper-equal; do
  printf '%s\n' "$out" | grep "$m keeps its own merge-helper" | grep -q 'modkit.mergeHelper(' && check "and names $m, pointing it at modkit.mergeHelper" ok \
    || check "and names $m, pointing it at modkit.mergeHelper" "$out"
done
case "$out" in *clean-asks-helper*) check "a mod asking the kit, or naming the helper in what it says, passes" "$out" ;; *) check "a mod asking the kit, or naming the helper in what it says, passes" ok ;; esac
# #1252: reading a transcript's goal_status records by hand, as scope-modes' bedtime.ts did before
# the reader moved into mod-kit. Each shape fails the run, pointed at $.modkit.goal; a mod asking
# the kit, or naming the record only in what it says, passes.
M9G2="$TMPROOT/m9-goal-reader"
mkmodsrc "$M9G2" clean-asks-goal "const g = await \$.modkit.goal({ transcript }); log('no goal_status record was found')"
mkmodsrc "$M9G2" goal-type-check "if (!a || a.type !== 'goal_status') continue"
mkmodsrc "$M9G2" goal-mark "export const GOAL_MARK = '\"type\":\"goal_status\"'"
mkmodsrc "$M9G2" goal-template 'const hits = lines.filter(l => l.includes(`goal_status`))'
out="$(bash "$SHARED" "$M9G2" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod reading a transcript's /goal records itself fails the run" ok || check "a mod reading a transcript's /goal records itself fails the run" "exit=$code out=$out"
for m in goal-type-check goal-mark goal-template; do
  printf '%s\n' "$out" | grep "$m keeps its own goal-reader" | grep -q 'modkit.goal(' && check "and names $m, pointing it at modkit.goal" ok \
    || check "and names $m, pointing it at modkit.goal" "$out"
done
case "$out" in *clean-asks-goal*) check "a mod asking the kit for a /goal, or naming the record in what it says, passes" "$out" ;; *) check "a mod asking the kit for a /goal, or naming the record in what it says, passes" ok ;; esac
# #1135: whether a prompt is Dan's words, read by hand from its origin, as five mods did two ways
# (two of them also counting a handoff's opening prompt). Each shape fails the run, pointed at
# $.modkit.isDans; a mod asking the kit passes, and so does one asking only whether a message came
# from the phone, which is another question.
M9D="$TMPROOT/m9d"
mkmodsrc "$M9D" clean-asks-dans "const dans = await \$.modkit.isDans({ origin: e.origin }); const fromPhone = e.origin.kind === 'bridge'"
mkmodsrc "$M9D" dans-skips "if (e.origin.kind !== 'composer' && e.origin.kind !== 'bridge') return next(e)"
mkmodsrc "$M9D" dans-handoff "const isDans = o => o.kind === 'composer' || o.kind === 'bridge' || (o.kind === 'plugin' && o.name === 'handoff' && o.asUser === true)"
mkmodsrc "$M9D" dans-double "const fromDan = origin => origin?.kind === \"composer\" || origin?.kind === \"bridge\""
out="$(bash "$SHARED" "$M9D" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a hand rolled reading of whether a prompt is Dan's words fails the run" ok || check "a hand rolled reading of whether a prompt is Dan's words fails the run" "exit=$code out=$out"
for m in dans-skips dans-handoff dans-double; do
  printf '%s\n' "$out" | grep "$m keeps its own dans-words" | grep -q 'modkit.isDans(' && check "and names $m, pointing it at modkit.isDans" ok \
    || check "and names $m, pointing it at modkit.isDans" "$out"
done
case "$out" in *clean-asks-dans*) check "a mod asking the kit, or asking only whether a message came from the phone, passes" "$out" ;; *) check "a mod asking the kit, or asking only whether a message came from the phone, passes" ok ;; esac
# #1145: telling Dan or Claude that his typed answer was not recorded, in a mod's own words, as the
# design round guard did in #1138 beside ask before saving's other wording. Each fails the run,
# pointed at $.modkit.typedAnswer; a mod asking the kit passes.
M9T="$TMPROOT/m9t"
mkmodsrc "$M9T" clean-asks-typed "const text = await \$.modkit.typedAnswer({ guard: 'X', typed, still: 'nothing was saved', again: 'ask him again' })"
mkmodsrc "$M9T" typed-toast "export const TYPED_TOAST = 'X: your typed answer was not recorded, because only choosing one of the answers counts.'"
mkmodsrc "$M9T" typed-claude "const said = \`Tell him in one line that his typed answer was not recorded; then ask again.\`"
out="$(bash "$SHARED" "$M9T" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod saying a typed answer was not recorded in its own words fails the run" ok || check "a mod saying a typed answer was not recorded in its own words fails the run" "exit=$code out=$out"
for m in typed-toast typed-claude; do
  printf '%s\n' "$out" | grep "$m keeps its own typed-answer" | grep -q 'modkit.typedAnswer(' && check "and names $m, pointing it at modkit.typedAnswer" ok \
    || check "and names $m, pointing it at modkit.typedAnswer" "$out"
done
case "$out" in *clean-asks-typed*) check "a mod asking the kit to say a typed answer was not recorded passes" "$out" ;; *) check "a mod asking the kit to say a typed answer was not recorded passes" ok ;; esac
# #1171: ask before saving scanned a python program's comments and strings itself, the same code as
# mod-kit's (#1165), a triple quote and an f prefix read by hand. Each shape fails the run, pointed at
# $.modkit.pythonText; a mod asking the kit, or one naming a quote in a comment, passes.
M9Y="$TMPROOT/m9y"
mkmodsrc "$M9Y" clean-asks-text "const spans = await \$.modkit.pythonText({ code }) // a ''' block or an f'' string is the kit's to read"
mkmodsrc "$M9Y" text-repeat "const q = code.startsWith(ch.repeat(3), i) ? ch.repeat(3) : ch"
mkmodsrc "$M9Y" text-triple "if (code.startsWith('\"\"\"', i) || code.startsWith(\"'''\", i)) j += 3"
mkmodsrc "$M9Y" text-prefix "const formatted = /[fFtT]/.test(prefix)"
out="$(bash "$SHARED" "$M9Y" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod scanning python's strings and comments itself fails the run" ok || check "a mod scanning python's strings and comments itself fails the run" "exit=$code out=$out"
for m in text-repeat text-triple text-prefix; do
  printf '%s\n' "$out" | grep "$m keeps its own python-text" | grep -q 'modkit.pythonText(' && check "and names $m, pointing it at modkit.pythonText" ok \
    || check "and names $m, pointing it at modkit.pythonText" "$out"
done
case "$out" in *clean-asks-text*) check "a mod asking the kit where python holds text passes" "$out" ;; *) check "a mod asking the kit where python holds text passes" ok ;; esac
# #2150: auto session name stripped the engine's "<mod>: $.noun.member: " prefix from its notices
# itself, and every other mod showed it to Dan. mod-kit's errorText now says such a failure in words,
# so a mod reading the prefix by hand fails the run, pointed at errorText; a mod asking errorText,
# or reading an abandoned command's "$.process.run(x) aborted" as /sleep does, passes.
M9P="$TMPROOT/m9p"
mkmodsrc "$M9P" clean-asks-words 'const said = errorText(err, MOD)'
mkmodsrc "$M9P" clean-reads-aborted 'const ENGINE_REFUSAL = /\$\.[A-Za-z]+\.[A-Za-z]+(?:\([^)]*\))? aborted/'
mkmodsrc "$M9P" prefix-strip 'const errText = (err: unknown) => errorText(err, MOD).replace(/^[\w-]+: \$\.[\w.]+: /, "")'
mkmodsrc "$M9P" prefix-match 'const refused = /^scope-modes: \$\.fs\.read: /.test(message)'
out="$(bash "$SHARED" "$M9P" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod reading the engine prefix off an error by hand fails the run" ok || check "a mod reading the engine prefix off an error by hand fails the run" "exit=$code out=$out"
for m in prefix-strip prefix-match; do
  printf '%s\n' "$out" | grep "$m keeps its own engine-prefix" | grep -q 'errorText(err, mod)' && check "and names $m, pointing it at errorText" ok \
    || check "and names $m, pointing it at errorText" "$out"
done
case "$out" in *clean-asks-words*|*clean-reads-aborted*) check "a mod asking errorText, or reading an abandoned command, passes" "$out" ;; *) check "a mod asking errorText, or reading an abandoned command, passes" ok ;; esac
# #2467: the design round guard read a TypeScript string to its closing quote itself, and a since
# retired guard a YAML flow list and its '' escape, while mod-kit's command reader reads shell only. Both
# now read with quotedEnd, yamlScalar and yamlFlowList from the copy of mod-kit's hooks/quoted.ts, so a
# mod undoing YAML's '' by hand, matching a single quoted scalar with a pattern, or walking a string to
# the quote it opened with fails the run, pointed at that copy. A mod asking the copy passes, and so
# does the design round guard's emptying of '' and "" in a prop value, which reads no string.
M9Q="$TMPROOT/m9-quoted-reader"
mkmodsrc "$M9Q" clean-asks-quoted "const items = yamlFlowList(text); const e = quotedEnd(text, i, 'code'); const empty = (v: string) => v.replace(/''|\"\"/g, 'x')"
mkmodsrc "$M9Q" quoted-escape "if (s.startsWith(\"'\") && s.endsWith(\"'\")) return s.slice(1, -1).replace(/''/g, \"'\")"
mkmodsrc "$M9Q" quoted-token "const FLOW = /\"(?:\\\\[\\s\\S]|[^\"\\\\])*\"?|'(?:''|[^'])*'?|#[^\\n]*/y"
mkmodsrc "$M9Q" quoted-walk "for (let j = i + 1; j < n; j++) { if (text[j] === '\\\\') j++; else if (text[j] === q) return j }"
out="$(bash "$SHARED" "$M9Q" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#2467: a mod reading a quoted string or a YAML flow list by hand fails the run" ok || check "#2467: a mod reading a quoted string or a YAML flow list by hand fails the run" "exit=$code out=$out"
for m in quoted-escape quoted-token quoted-walk; do
  printf '%s\n' "$out" | grep "$m keeps its own quoted-reader" | grep -q 'hooks/mod-kit/quoted.ts' && check "#2467: and names $m, pointing it at the copy of hooks/quoted.ts" ok \
    || check "#2467: and names $m, pointing it at the copy of hooks/quoted.ts" "$out"
done
case "$out" in *clean-asks-quoted*) check "#2467: a mod asking the copy of hooks/quoted.ts passes" "$out" ;; *) check "#2467: a mod asking the copy of hooks/quoted.ts passes" ok ;; esac
# #2992: scope modes and a since retired guard each read a patch's names, strip level, folder and hunks
# their own way, and each got a case the other got right wrong. Both read with the copy of mod-kit's
# hooks/patch.ts now, so a mod reading git's diff line, a +++ header, a hunk header or a binary patch
# by hand fails the run, pointed at that copy (the spellings each copy used). A mod asking the copy
# passes, and so does ask before saving's cut of the lines that might name a file, another question.
M9D="$TMPROOT/m9-patch-reader"
mkmodsrc "$M9D" clean-asks-patch "const files = patchFiles(text); const paths = patchedPaths(g.args, true, text); const NAMES_A_FILE = /^[ \\t]*(?:diff |--- |\\+\\+\\+ |Index: )/"
mkmodsrc "$M9D" patch-git-line "const d = /^diff --git (.+)\$/.exec(line)"
mkmodsrc "$M9D" patch-header "if (line.startsWith('--- ') && (lines[i + 1] ?? '').startsWith('+++ ')) file = line"
mkmodsrc "$M9D" patch-hunk "const h = /^@@ -\\d+(?:,(\\d+))? \\+\\d+(?:,(\\d+))? @@/.exec(line)"
mkmodsrc "$M9D" patch-binary "if (/^GIT binary patch\$/.test(line)) return undefined"
out="$(bash "$SHARED" "$M9D" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#2992: a mod reading a patch by hand fails the run" ok || check "#2992: a mod reading a patch by hand fails the run" "exit=$code out=$out"
for m in patch-git-line patch-header patch-hunk patch-binary; do
  printf '%s\n' "$out" | grep "$m keeps its own patch-reader" | grep -q 'hooks/mod-kit/patch.ts' && check "#2992: and names $m, pointing it at the copy of hooks/patch.ts" ok \
    || check "#2992: and names $m, pointing it at the copy of hooks/patch.ts" "$out"
done
case "$out" in *clean-asks-patch*) check "#2992: a mod asking the copy of hooks/patch.ts, or cutting a patch to the lines that might name a file, passes" "$out" ;; *) check "#2992: a mod asking the copy of hooks/patch.ts, or cutting a patch to the lines that might name a file, passes" ok ;; esac
# #3022: the design round guard read a script's bare mktemp and its own folder by the BASH_SOURCE
# idiom itself, and the area check could not read either. Both read with the copy of mod-kit's
# hooks/scriptvars.ts now, so a mod matching a bare mktemp substitution or the idiom by hand fails
# the run, pointed at that copy. A mod asking the copy passes.
M9V="$TMPROOT/m9-script-vars"
mkmodsrc "$M9V" clean-asks-vars "const t = tempWord(text, word); const own = ownFolderPath(text, path); const rest = withoutOwnFolder(text)"
mkmodsrc "$M9V" vars-mktemp "const FRESH = /^\\\$\\(mktemp(?: -d)?\\)\$/"
mkmodsrc "$M9V" vars-own-folder "const IDIOM = /dirname \"\\\$\\{BASH_SOURCE/"
out="$(bash "$SHARED" "$M9V" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#3022: a mod reading a script's own variables by hand fails the run" ok || check "#3022: a mod reading a script's own variables by hand fails the run" "exit=$code out=$out"
for m in vars-mktemp vars-own-folder; do
  printf '%s\n' "$out" | grep "$m keeps its own script-vars" | grep -q 'hooks/mod-kit/scriptvars.ts' && check "#3022: and names $m, pointing it at the copy of hooks/scriptvars.ts" ok \
    || check "#3022: and names $m, pointing it at the copy of hooks/scriptvars.ts" "$out"
done
case "$out" in *clean-asks-vars*) check "#3022: a mod asking the copy of hooks/scriptvars.ts passes" "$out" ;; *) check "#3022: a mod asking the copy of hooks/scriptvars.ts passes" ok ;; esac
# #3190: eight mods took the keys Claude Code carries beside a call's own arguments off by hand, in
# twelve places, so a key the engine adds had to be learned by every copy. They read with toolArgs from the
# copy of mod-kit's hooks/toolargs.ts now, so a mod naming those keys itself, in a destructure or a
# list of them, fails the run, pointed at that copy. A mod asking the copy, or reading one key alone
# (whether a call came from a subagent), passes.
M9K="$TMPROOT/m9-engine-keys"
mkmodsrc "$M9K" clean-asks-args "const args = toolArgs(input); const id = String(input.tool_use_id ?? ''); if (e.agentId !== undefined) return next(e)"
mkmodsrc "$M9K" keys-destructure "const { tool: _t, tool_use_id: _id, agentId: _a, consent: _c, ...args } = input"
mkmodsrc "$M9K" keys-kept "const { tool: _t, tool_use_id: toolUseId, agentId: _a, consent: _c, ...raw } = e as unknown as Record<string, unknown>"
mkmodsrc "$M9K" keys-list "const CALL_KEYS = new Set(['tool', 'tool_use_id', 'agentId', 'consent'])"
out="$(bash "$SHARED" "$M9K" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#3190: a mod taking the engine's keys off a call by hand fails the run" ok || check "#3190: a mod taking the engine's keys off a call by hand fails the run" "exit=$code out=$out"
for m in keys-destructure keys-kept keys-list; do
  printf '%s\n' "$out" | grep "$m keeps its own engine-keys" | grep -q 'hooks/mod-kit/toolargs.ts' && check "#3190: and names $m, pointing it at the copy of hooks/toolargs.ts" ok \
    || check "#3190: and names $m, pointing it at the copy of hooks/toolargs.ts" "$out"
done
case "$out" in *clean-asks-args*) check "#3190: a mod asking the copy of hooks/toolargs.ts, or reading one key alone, passes" "$out" ;; *) check "#3190: a mod asking the copy of hooks/toolargs.ts, or reading one key alone, passes" ok ;; esac
# #3321: a mod that reads the answers Claude Code's question dialog hands back acts on what Dan
# chose, and his answer covers only text he could read, so it first judges the call with askFault
# from the copy of mod-kit's hooks/shown.ts. A mod reading the answers without it fails the run,
# however its hook is laid out, and so does one that imports the check and never calls it. A mod
# that calls it, one that hooks the dialog and reads no answer, and one that only names the dialog
# in a comment pass.
M9P="$TMPROOT/m9-picker-answers"
mkmodsrc "$M9P" clean-judges-picker "import { askFault } from './mod-kit/shown.ts'; on('tool.call', { tool: 'AskUserQuestion' }, async (\$, e, next) => { if (askFault(e) !== undefined) return { deny: 'unread' }; const r = await next(e); return keep(r.result?.answers) })"
mkmodsrc "$M9P" clean-reads-no-answer "on('tool.check', { tool: 'AskUserQuestion' }, async (\$, e, next) => { opened(e); return next(e) })"
mkmodsrc "$M9P" clean-comment-only "// An AskUserQuestion picker is not this mod's.
const answers = form.answers"
mkmodsrc "$M9P" answers-in-hook "on('tool.call', { tool: 'AskUserQuestion' }, async (\$, e, next) => { const r = await next(e); return keep(r.result?.answers) })"
mkmodsrc "$M9P" answers-any-call "on('tool.call', async (\$, e, next) => { const r = await next(e); if (e.tool === 'AskUserQuestion') note(r.result.answers); return r })"
mkmodsrc "$M9P" answers-imported-not-called "import { askFault } from './mod-kit/shown.ts'; const DIALOG = 'AskUserQuestion'; const chosen = out.answers?.[asked]"
out="$(bash "$SHARED" "$M9P" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#3321: a mod reading a picker's answers without the shared check fails the run" ok || check "#3321: a mod reading a picker's answers without the shared check fails the run" "exit=$code out=$out"
for m in answers-in-hook answers-any-call answers-imported-not-called; do
  printf '%s\n' "$out" | grep "$m reads the answers of an AskUserQuestion picker" | grep -q 'hooks/mod-kit/shown.ts' && check "#3321: and names $m, pointing it at the copy of hooks/shown.ts" ok \
    || check "#3321: and names $m, pointing it at the copy of hooks/shown.ts" "$out"
done
case "$out" in *clean-judges-picker*|*clean-reads-no-answer*|*clean-comment-only*) check "#3321: a mod that judges the call first, reads no answer, or names the dialog only in a comment passes" "$out" ;; *) check "#3321: a mod that judges the call first, reads no answer, or names the dialog only in a comment passes" ok ;; esac
# #3321: a question a mod asks Dan itself, through its own dialog, is recorded by its size and kept
# as the mod's own while it is open, and both happen in one place: recordedAsk in the copy of
# mod-kit's hooks/asked.ts, which is handed the dialog as its `ask:` member. A mod calling the dialog
# any other way fails the run, pointed at that copy, and so does one that calls the recorder but
# is not among the recorder's OWN_ASKERS, keeps no state of its own for it, or is not read by picker
# manners. Picker manners reading a mod the recorder does not name fails too. A mod asking through
# the recorder and named everywhere, one that names the dialog only in a comment, and one with no
# dialog pass.
M9A="$TMPROOT/m9-own-dialog"
ASKS_RIGHT="import { type AskedIo, recordedAsk } from './mod-kit/asked.ts'; const ref = { plugin: 'NAME', key: 'asking' } as const; const io: AskedIo = { ask: (question, options) => \$.ui.ask(question, options), own: { read: () => \$.state.get(ref), write: (v, ifVersion) => \$.state.set(ref, v, { ifVersion }) } }; const a = await recordedAsk(io, 'NAME', 'which', q, ['Yes', 'No'])"
mkmodsrc "$M9A" mod-kit "export const register = on => {}"
printf '%s\n' "export const OWN_ASKERS = ['clean-asks-recorded', 'asks-unread-by-manners'] as const" > "$M9A/mod-kit/hooks/asked.ts"
mkmodsrc "$M9A" clean-asks-recorded "${ASKS_RIGHT//NAME/clean-asks-recorded}"
mkmodsrc "$M9A" clean-comment-ask "// \$.ui.ask(question) is how a mod asks, and this one asks nothing.
export const register = on => {}"
mkmodsrc "$M9A" clean-no-dialog "export const register = on => { on('tool.call', async (\$, e, next) => next(e)) }"
mkmodsrc "$M9A" asks-direct "const a = await \$.ui.ask('Ready?', ['Yes', 'No'])"
mkmodsrc "$M9A" asks-built "const a = await built.ui.ask('Ready?', ['Yes', 'No'])"
mkmodsrc "$M9A" asks-member-no-recorder "const io = { ask: (question, options) => \$.ui.ask(question, options) }; const a = await io.ask('Ready?')"
mkmodsrc "$M9A" asks-unnamed "${ASKS_RIGHT//NAME/asks-unnamed}"
mkmodsrc "$M9A" asks-unread-by-manners "${ASKS_RIGHT//NAME/asks-unread-by-manners}"
mkmodsrc "$M9A" asks-no-state "import { type AskedIo, recordedAsk } from './mod-kit/asked.ts'; const io: AskedIo = { ask: (question, options) => \$.ui.ask(question, options) }; const a = await recordedAsk(io, 'asks-no-state', 'which', q)"
mkmodsrc "$M9A" picker-manners "const reads = [() => \$.state.get({ plugin: 'clean-asks-recorded', key: 'asking' } as never), () => \$.state.get({ plugin: 'gone-mod', key: 'asking' } as never)]"
for m in clean-asks-recorded asks-unnamed asks-unread-by-manners asks-no-state; do mkdir -p "$M9A/$m/hooks/mod-kit"; cp "$M9A/mod-kit/hooks/asked.ts" "$M9A/$m/hooks/mod-kit/asked.ts"; done
out="$(bash "$SHARED" "$M9A" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#3321: a mod asking through its own dialog past the recorder fails the run" ok || check "#3321: a mod asking through its own dialog past the recorder fails the run" "exit=$code out=$out"
for m in asks-direct asks-built asks-member-no-recorder; do
  printf '%s\n' "$out" | grep "$m asks Dan through its own dialog" | grep -q 'hooks/mod-kit/asked.ts' && check "#3321: and names $m, pointing it at the copy of hooks/asked.ts" ok \
    || check "#3321: and names $m, pointing it at the copy of hooks/asked.ts" "$out"
done
printf '%s\n' "$out" | grep -q "asks-unnamed asks through the recorder and is not among OWN_ASKERS" && check "#3321: a mod asking through the recorder that the recorder does not name is said" ok || check "#3321: a mod asking through the recorder that the recorder does not name is said" "$out"
printf '%s\n' "$out" | grep -q "asks-unread-by-manners asks through the recorder and picker manners never reads its state" && check "#3321: a mod picker manners does not read is said" ok || check "#3321: a mod picker manners does not read is said" "$out"
printf '%s\n' "$out" | grep -q "asks-no-state asks through the recorder and keeps no state of its own" && check "#3321: a mod with no state of its own for its dialogs is said" ok || check "#3321: a mod with no state of its own for its dialogs is said" "$out"
printf '%s\n' "$out" | grep -q "picker-manners reads gone-mod's state for its own dialogs, and the recorder names no such mod" && check "#3321: picker manners reading a mod the recorder does not name is said" ok || check "#3321: picker manners reading a mod the recorder does not name is said" "$out"
case "$out" in *clean-asks-recorded*|*clean-comment-ask*|*clean-no-dialog*) check "#3321: a mod asking through the recorder and named everywhere, or with no dialog, passes" "$out" ;; *) check "#3321: a mod asking through the recorder and named everywhere, or with no dialog, passes" ok ;; esac
# #1765: three guards read each file a command reads by hand, looping over the write reader's inputs,
# and one meeting /dev/stdin or a fifo waited for ever, so the call never ran. Each hand rolled loop
# fails the run, pointed at inputTexts in the copy of mod-kit's hooks/inputs.ts; a mod handing the
# inputs to it, or reading only their names, passes.
M9I="$TMPROOT/m9-input-reader"
mkmodsrc "$M9I" clean-asks-inputs "const texts = await inputTexts({ exists: p => \$.fs.exists(p), stat: (p, o) => \$.fs.stat(p, o), read: p => \$.fs.read(p) }, u.inputs); const named = [...u.words, ...u.inputs].some(isLessons)"
mkmodsrc "$M9I" inputs-one-line "for (const f of u.inputs) if (await \$.fs.exists(f)) texts.push(await \$.fs.read(f))"
mkmodsrc "$M9I" inputs-block "for (const f of w.unnamed[0]?.inputs) {"
out="$(bash "$SHARED" "$M9I" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#1765: a mod reading a command's inputs by hand fails the run" ok || check "#1765: a mod reading a command's inputs by hand fails the run" "exit=$code out=$out"
for m in inputs-one-line inputs-block; do
  printf '%s\n' "$out" | grep "$m keeps its own input-reader" | grep -q 'inputTexts' && check "#1765: and names $m, pointing it at inputTexts" ok \
    || check "#1765: and names $m, pointing it at inputTexts" "$out"
done
case "$out" in *clean-asks-inputs*) check "#1765: a mod handing a command's inputs to inputTexts, or reading only their names, passes" "$out" ;; *) check "#1765: a mod handing a command's inputs to inputTexts, or reading only their names, passes" ok ;; esac
# #2039: a guard's registration catch is its last word on a call, and one that throws leaves the call
# unheld. Each catch answers straight through neverThrows from the copy of mod-kit's hooks/hold.ts,
# on its one line. Only the replay of a call already passed on may sit outside it, written
# next.called ? next(e) : neverThrows(...), since that call has run and the tool's own failure must
# reach Claude; a bare catch, one answering before next outside neverThrows, or one whose replay
# is not that exact form fails the run, pointed at that copy. A promise's own catch (err, never $) passes.
M9HOLD="$TMPROOT/m9-hold"
mkmodsrc "$M9HOLD" clean-holds "const h = async (\$, e, next) => next(e); on('tool.call', h).catch((\$, e, next) => neverThrows(() => withinGrace(next.budget, () => h(\$, e, next), () => ({ deny: 'late' })), () => ({ deny: 'x' }), { deny: 'y' })); on('tool.check', h).catch((\$, e, next) => next.called ? next(e) : neverThrows(() => withinGrace(next.budget, () => h(\$, e, next), () => ({ deny: 'late' })), () => ({ deny: 'x' }), { deny: 'y' })); on('tool.call', h).catch((\$, e, next) => neverThrows(() => ({ deny: 'x' }), () => ({ deny: 'x' }), { deny: 'y' })); void work().catch(err => log(err))"
mkmodsrc "$M9HOLD" hold-bare "const h = async (\$, e, next) => next(e); on('tool.call', h).catch((\$, e, next) => ({ deny: \`could not check (\${next.error})\` }))"
mkmodsrc "$M9HOLD" hold-async "const h = async (\$, e, next) => next(e); on('tool.check', h).catch(async (\$, e, next) => ({ decision: 'deny', reason: 'x' }))"
mkmodsrc "$M9HOLD" hold-replay "const h = async (\$, e, next) => next(e); on('tool.call', h).catch((\$, e, next) => next.called ? next(e) : ({ deny: 'x' }))"
out="$(bash "$SHARED" "$M9HOLD" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#2039: a guard's catch not answering through neverThrows fails the run" ok || check "#2039: a guard's catch not answering through neverThrows fails the run" "exit=$code out=$out"
for m in hold-bare hold-async hold-replay; do
  printf '%s\n' "$out" | grep "$m keeps its own catch" | grep -q 'hooks/mod-kit/hold.ts' && check "#2039: and names $m, pointing it at hooks/mod-kit/hold.ts" ok \
    || check "#2039: and names $m, pointing it at hooks/mod-kit/hold.ts" "$out"
done
case "$out" in *clean-holds*) check "#2039: a catch answering through neverThrows, and a promise's own catch, pass" "$out" ;; *) check "#2039: a catch answering through neverThrows, and a promise's own catch, pass" ok ;; esac
# #2039: a catch that judges the call once more runs the hook's whole judgement in its own 1,000 ms
# grace (the engine's next.budget, read 2026-11-05), and one cut at the grace lets the call run. So the rerun starts only through withinGrace,
# which holds the call when too little of the grace is left; a rerun straight inside neverThrows, sync
# or async, fails the run, pointed at withinGrace. A catch answering only a refusal (above) passes.
M9GRACE="$TMPROOT/m9-grace"
mkmodsrc "$M9GRACE" grace-rerun "const h = async (\$, e, next) => next(e); on('tool.call', h).catch((\$, e, next) => neverThrows(() => h(\$, e, next), () => ({ deny: 'x' }), { deny: 'y' }))"
mkmodsrc "$M9GRACE" grace-rerun-async "const h = async (\$, e, next) => next(e); on('tool.check', h).catch((\$, e, next) => next.called ? next(e) : neverThrows(async () => h(\$, e, next), () => ({ deny: 'x' }), { deny: 'y' }))"
out="$(bash "$SHARED" "$M9GRACE" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#2039: a catch rerunning its hook outside withinGrace fails the run" ok || check "#2039: a catch rerunning its hook outside withinGrace fails the run" "exit=$code out=$out"
for m in grace-rerun grace-rerun-async; do
  printf '%s\n' "$out" | grep "$m reruns its hook" | grep -q 'withinGrace(next.budget' && check "#2039: and names $m, pointing it at withinGrace" ok \
    || check "#2039: and names $m, pointing it at withinGrace" "$out"
done
# #3655: hold.ts now builds the whole catch of a tool hook (cutCall, cutCheck, cutOwn, each on
# neverThrows), and a catch answering straight through one of them passes, but only where the name
# IS the kit's: imported under its own name from ./mod-kit/hold.ts. A function of the mod's own
# with that name, another import renamed to it, or the name from another file is a mod's own catch
# and fails as one. A rerun handed over as `work` with no check of the grace fails as the bare
# rerun does.
M9CUT="$TMPROOT/m9-cut"
mkmodsrc "$M9CUT" clean-cuts "import { cutCall, cutCheck, cutOwn, withinGrace } from './mod-kit/hold.ts'
const h = async (\$, e, next) => next(e)
on('tool.call', h).catch((\$, e, next) => cutCall('the mod', e, next))
on('tool.check', h).catch((\$, e, next) => cutCheck('the mod', next, { work: () => withinGrace(next.budget, () => h(\$, e, next), () => ({ decision: 'deny', reason: 'late' })) }))
on('tool.call', { tool: 'mine' }, h).catch(async (\$, e, next) => cutOwn('the mod', next, {
  held: () => ({ deny: 'x' }),
}))"
mkmodsrc "$M9CUT" cut-local "const cutCall = () => undefined
const h = async (\$, e, next) => next(e); on('tool.call', h).catch((\$, e, next) => cutCall('the mod', e, next))"
mkmodsrc "$M9CUT" cut-renamed "import { withinGrace as cutCheck } from './mod-kit/hold.ts'
const h = async (\$, e, next) => next(e); on('tool.check', h).catch((\$, e, next) => cutCheck('the mod', next))"
mkmodsrc "$M9CUT" cut-elsewhere "import { cutOwn } from './mine.ts'
const h = async (\$, e, next) => next(e); on('tool.call', h).catch((\$, e, next) => cutOwn('the mod', next))"
mkmodsrc "$M9CUT" cut-rerun "import { cutCall } from './mod-kit/hold.ts'
const h = async (\$, e, next) => next(e); on('tool.call', h).catch((\$, e, next) => cutCall('the mod', e, next, { work: () => h(\$, e, next) }))"
mkmodsrc "$M9CUT" cut-rerun-async "import { cutCheck } from './mod-kit/hold.ts'
const h = async (\$, e, next) => next(e); on('tool.check', h).catch((\$, e, next) => cutCheck('the mod', next, {
  work: async () => h(\$, e, next),
}))"
out="$(bash "$SHARED" "$M9CUT" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#3655: a catch through a cut name that is not the kit's fails the run" ok || check "#3655: a catch through a cut name that is not the kit's fails the run" "exit=$code out=$out"
for m in cut-local cut-renamed cut-elsewhere; do
  printf '%s\n' "$out" | grep "$m keeps its own catch" | grep -q "does not import, under that name, from ./mod-kit/hold.ts" && check "#3655: and names $m, saying the name is not imported from the kit's copy" ok \
    || check "#3655: and names $m, saying the name is not imported from the kit's copy" "$out"
done
for m in cut-rerun cut-rerun-async; do
  printf '%s\n' "$out" | grep "$m reruns its hook" | grep -q 'withinGrace(next.budget' && check "#3655: a rerun handed to a shared catch as work fails in $m, pointed at withinGrace" ok \
    || check "#3655: a rerun handed to a shared catch as work fails in $m, pointed at withinGrace" "$out"
  printf '%s\n' "$out" | grep -q "$m keeps its own catch" && check "#3655: and $m's catch itself, the kit's, is not called its own" "$out" \
    || check "#3655: and $m's catch itself, the kit's, is not called its own" ok
done
case "$out" in *clean-cuts*) check "#3655: catches answering through the kit's cutCall, cutCheck and cutOwn pass" "$out" ;; *) check "#3655: catches answering through the kit's cutCall, cutCheck and cutOwn pass" ok ;; esac
# #1205: the status bar and the account room each followed a /login with their own copy of the
# reading and its half minute wait. A mod hooking the login command itself fails the run, pointed at
# modkit.login; a mod hooking the event mod-kit raises passes.
M9L="$TMPROOT/m9l"
mkmodsrc "$M9L" clean-follows-login "on('modkit.login', async (\$, e, next) => (await follow(e.account), next(e)))"
mkmodsrc "$M9L" login-own "on('command.run', { command: 'login' }, async (\$, e, next) => next(e))"
mkmodsrc "$M9L" login-own-dq 'on("command.run", { command: "login" }, async ($, e, next) => next(e))'
out="$(bash "$SHARED" "$M9L" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod following /login itself fails the run" ok || check "a mod following /login itself fails the run" "exit=$code out=$out"
for m in login-own login-own-dq; do
  printf '%s\n' "$out" | grep "$m keeps its own login-follower" | grep -q 'modkit.login' && check "and names $m, pointing it at modkit.login" ok \
    || check "and names $m, pointing it at modkit.login" "$out"
done
case "$out" in *clean-follows-login*) check "a mod hooking the login mod-kit raises passes" "$out" ;; *) check "a mod hooking the login mod-kit raises passes" ok ;; esac
# Lessons review of #1205: the status bar and the account room also each read the login file at
# their session's start. A mod naming the file as a path fails, pointed at modkit.account; one asking
# the kit, or only naming the file in what it says, passes.
M9LF="$TMPROOT/m9-login-file"
mkmodsrc "$M9LF" clean-asks-account "const a = await \$.modkit.account(); log('~/.claude.json could not be read')"
mkmodsrc "$M9LF" file-own "const text = await \$.fs.read(\`\${home}/.claude.json\`)"
mkmodsrc "$M9LF" file-own-sq "const path = home + '/.claude.json'"
mkmodsrc "$M9LF" file-own-join "const path = join(home, '.claude.json')"
mkmodsrc "$M9LF" file-own-resolve 'const path = path.resolve(home, ".claude.json")'
out="$(bash "$SHARED" "$M9LF" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod reading the login file itself fails the run" ok || check "a mod reading the login file itself fails the run" "exit=$code out=$out"
for m in file-own file-own-sq file-own-join file-own-resolve; do
  printf '%s\n' "$out" | grep "$m keeps its own login-file" | grep -q 'modkit.account' && check "and names $m, pointing it at modkit.account" ok \
    || check "and names $m, pointing it at modkit.account" "$out"
done
case "$out" in *clean-asks-account*) check "a mod asking the kit for the account passes" "$out" ;; *) check "a mod asking the kit for the account passes" ok ;; esac
# #1281: a mod loaded before a mod it depends on keeps that mod's older members, so a call to a member
# added since throws a TypeError at the call site. The one reader of that failure is mod-kit's
# hooks/skew.ts, and it cannot be a member of mod-kit's noun (it is needed exactly when mod-kit's
# loaded copy is the older one), so a mod reading such a failure keeps a copy of it at
# hooks/mod-kit/skew.ts, byte for byte, and imports it, and no mod reads a TypeError by hand.
M9K="$TMPROOT/m9-skew"
mkmodsrc "$M9K" mod-kit "export const reader = 1"
printf 'export const missingOf = (err: unknown) => (err instanceof TypeError ? {} : null)\n' > "$M9K/mod-kit/hooks/skew.ts"
mkdepmod(){   # $1 = mod name  $2 = the hooks module's source; depends on mod-kit, with a copy of its reader
  mkmodsrc "$M9K" "$1" "$2"
  printf '{ "name": "%s", "version": "0.1.0", "description": "t", "dependencies": ["mod-kit"] }\n' "$1" > "$M9K/$1/.claude-plugin/plugin.json"
  mkdir -p "$M9K/$1/hooks/mod-kit"
  cp "$M9K/mod-kit/hooks/skew.ts" "$M9K/$1/hooks/mod-kit/skew.ts"
}
mkdepmod clean-reads-missing "import { missingOf } from './mod-kit/skew.ts'
const home = (err: unknown) => missingOf(err)?.kind === 'noun'"
mkdepmod typeerror-own "import { errorText } from './mod-kit/skew.ts'
const home = (err: unknown) => err instanceof TypeError && /scopeModes/.test(errorText(err, 'x'))"
mkdepmod unimported "export const register = () => {}"
mkmodsrc "$M9K" clean-depends-on-nothing "export const register = () => {}"
out="$(bash "$SHARED" "$M9K" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "#1281: a mod reading a missing noun or member its own way fails the run" ok || check "#1281: a mod reading a missing noun or member its own way fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep "typeerror-own keeps its own missing-reader at /hooks/register.ts:2" | grep -q 'missingOf(err)' \
  && check "#1281: and names the TypeError read by hand, pointing it at the copy's missingOf" ok || check "#1281: and names the TypeError read by hand, pointing it at the copy's missingOf" "$out"
printf '%s\n' "$out" | grep -q "unimported keeps hooks/mod-kit/skew.ts but no hooks file imports it" \
  && check "#1281: a copy no hooks file imports fails, named" ok || check "#1281: a copy no hooks file imports fails, named" "$out"
case "$out" in *clean-reads-missing*|*clean-depends-on-nothing*) check "#1281: a mod using the copy, and a mod depending on nothing, pass, the copy's own TypeError read not taken for a hand rolled one" "$out" ;; *) check "#1281: a mod using the copy, and a mod depending on nothing, pass, the copy's own TypeError read not taken for a hand rolled one" ok ;; esac
rm -rf "$M9K/typeerror-own" "$M9K/unimported"
out="$(bash "$SHARED" "$M9K" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "#1281: with those gone the run passes" ok || check "#1281: with those gone the run passes" "exit=$code out=$out"
printf 'export const missingOf = () => null\n' > "$M9K/mod-kit/hooks/skew.ts"
out="$(bash "$SHARED" "$M9K" 2>&1)"; code=$?
remedy="$(printf '%s\n' "$out" | grep "clean-reads-missing's hooks/mod-kit/skew.ts differs" | sed 's/.*: \(cp .*\)$/\1/')"
[ "$code" -eq 1 ] && case "$remedy" in cp*) true ;; *) false ;; esac \
  && check "#1281: a copy that no longer matches mod-kit's reader fails, naming the cp that brings it back" ok || check "#1281: a copy that no longer matches mod-kit's reader fails, naming the cp that brings it back" "exit=$code out=$out"
[ -n "$remedy" ] && ( eval "$remedy" )
out="$(bash "$SHARED" "$M9K" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "#1281: and running that cp passes the run again" ok || check "#1281: and running that cp passes the run again" "exit=$code out=$out"
printf 'export const x = 1\n' > "$M9K/clean-reads-missing/hooks/mod-kit/gone.ts"
out="$(bash "$SHARED" "$M9K" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q "clean-reads-missing's hooks/mod-kit/gone.ts copies no file of mod-kit's hooks" \
  && check "#1281: a file under hooks/mod-kit that mod-kit's hooks do not have fails the run, named" ok || check "#1281: a file under hooks/mod-kit that mod-kit's hooks do not have fails the run, named" "exit=$code out=$out"
# #1281: the reader names the mod a noun belongs to, its name in camel case but for the nouns its
# PROVIDERS map names. Every noun a mod's own contract declares must come out as that mod's folder,
# so a noun added under another name fails here rather than naming a mod that does not exist (L96).
nouns_named_right(){   # $1 = mods dir -> prints each noun the reader would name wrongly
  python3 - "$1" <<'PY'
import re, sys, pathlib
mods = pathlib.Path(sys.argv[1])
src = (mods / 'mod-kit/hooks/skew.ts').read_text()
m = re.search(r'PROVIDERS[^=]*=\s*\{([^}]*)\}', src)
table = dict(re.findall(r"(\w+):\s*'([^']+)'", m.group(1))) if m else {}
for t in sorted(mods.glob('*/types/index.d.ts')):
    body = re.search(r'interface EngineInterface\s*\{([^}]*)\}', t.read_text())
    if not body:
        continue
    for noun in re.findall(r'^\s*(\w+)\s*:', body.group(1), re.M):
        named = table.get(noun) or re.sub(r'[A-Z]', lambda c: '-' + c.group(0).lower(), noun)
        if named != t.parent.parent.name:
            print(f'{noun} is {t.parent.parent.name}, read as {named}')
PY
}
M9N="$TMPROOT/m9-nouns"
mkdir -p "$M9N/mod-kit/hooks" "$M9N/job-watcher/types" "$M9N/odd-name/types"
printf "export const PROVIDERS = { modkit: 'mod-kit', jobs: 'job-watcher' }\n" > "$M9N/mod-kit/hooks/skew.ts"
printf 'declare module "claude-code" {\n  interface EngineInterface {\n    jobs: Jobs\n  }\n}\n' > "$M9N/job-watcher/types/index.d.ts"
printf 'declare module "claude-code" {\n  interface EngineInterface {\n    renamed: Renamed\n  }\n}\n' > "$M9N/odd-name/types/index.d.ts"
case "$(nouns_named_right "$M9N")" in
  'renamed is odd-name, read as renamed') check "#1281: a noun the reader would name as no mod is caught, and a mapped one is not" ok ;;
  *) check "#1281: a noun the reader would name as no mod is caught, and a mapped one is not" "$(nouns_named_right "$M9N")" ;;
esac
if [ -d "$ROOT/payload/mods" ]; then
  wrong="$(nouns_named_right "$ROOT/payload/mods")"
  [ -z "$wrong" ] && check "#1281: every noun a mod in payload/mods declares is read as that mod" ok || check "#1281: every noun a mod in payload/mods declares is read as that mod" "$wrong"
fi
# #732 (lessons review of #731): comments are taken out and what is left on the line is read, so
# code after a block comment, or on a line starting with * as a continuation, is checked, and a
# string holding // is code.
M9C="$TMPROOT/m9c"
mkmodsrc "$M9C" after-block-comment "/* the band */ on('ui.render', { component: 'AbovePrompt' }, draw)"
mkmodsrc "$M9C" star-continuation "const area = width
  * height; on('ui.render', { component: 'ToolResult' }, draw)"
# #733: a generator method is code that starts with * too.
mkmodsrc "$M9C" star-generator "class Rows {
  *rows() { yield on('ui.render', { component: 'AbovePrompt' }, draw) }
}"
mkmodsrc "$M9C" slashes-in-a-string "const note = 'see // here'; on('ui.render', { component: 'AbovePrompt' }, draw)"
out="$(bash "$SHARED" "$M9C" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "code beside a comment on its line fails the run" ok || check "code beside a comment on its line fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q 'after-block-comment keeps its own band at /hooks/register.ts:1:' \
  && check "and code after a block comment is read" ok || check "and code after a block comment is read" "$out"
printf '%s\n' "$out" | grep -q 'star-continuation keeps its own card at /hooks/register.ts:2:' \
  && check "and a line starting with * as a continuation is read" ok || check "and a line starting with * as a continuation is read" "$out"
printf '%s\n' "$out" | grep -q 'star-generator keeps its own band at /hooks/register.ts:2:' \
  && check "and a generator method's line, starting with *, is read" ok || check "and a generator method's line, starting with *, is read" "$out"
printf '%s\n' "$out" | grep -q 'slashes-in-a-string keeps its own band' \
  && check "and a string holding // is code, not a comment" ok || check "and a string holding // is code, not a comment" "$out"
out="$(bash "$SHARED" "$TMPROOT/not-there" 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a missing mods folder is refused by the shared parts check too" ok \
  || check "a missing mods folder is refused by the shared parts check too" "exit=$code out=$out"
if [ -d "$ROOT/payload/mods" ]; then
  out="$(bash "$SHARED" "$ROOT/payload/mods" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "no mod in payload/mods keeps its own copy of a shared part" ok \
    || check "no mod in payload/mods keeps its own copy of a shared part" "exit=$code out=$out"
fi

mods_harness_result
