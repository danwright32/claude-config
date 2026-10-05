#!/bin/bash
# Tests for tools/check-mods.sh, the gate that holds every mod in payload/mods to what Claude Code
# itself accepts (claude-config#606). The mods load on both Macs, so a broken one is broken twice;
# this is where it is caught, before the push, rather than as a refusal line in a session.
#
# The claude binary is a stub for every case but the last: a test must never start a real Claude
# Code (L2). The last case runs the real tree with the real binary where there is one, and says
# UNMEASURED where there is not (CI's Linux runner), rather than passing (L411).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
CHECK="$ROOT/tools/check-mods.sh"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-mods.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

mkmod(){   # $1 = mods dir  $2 = name
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks"
  printf '{ "name": "%s", "version": "0.1.0", "description": "x" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
  printf '{ "modules": ["./register.ts"] }\n' > "$1/$2/hooks/hooks.json"
  printf 'export const register = () => {}\n' > "$1/$2/hooks/register.ts"
  printf '{ "extends": "./.claude-plugin/types/tsconfig.json" }\n' > "$1/$2/tsconfig.json"
}
# The stub: validate refuses any mod whose folder name contains "broken"; test fails any mod whose
# folder name contains "redtest"; every call is logged so a case can assert what was asked.
FAKE="$TMPROOT/claude"; LOG="$TMPROOT/calls"
cat > "$FAKE" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "plugin validate") case "$3" in *broken*) printf '  hooks: bad event\n\nValidation failed\n'; exit 1 ;; esac; echo 'Validation passed' ;;
  "plugin test") case "$3" in
      *redtest*) printf ' 0 pass\n 1 fail\n'; exit 1 ;;
      # Claude Code's own answer while its cached rollout switch is saved off (2.1.289, #740).
      *switchedoff*) printf 'hooks modules are turned off in this process: the rollout switch was saved off. Start `claude` once with network access, then run the tests again\n'; exit 1 ;;
      # A failure with no verdict line the reason filter keeps.
      *noverdict*) printf 'line one\nline two\nsomething odd happened\n'; exit 7 ;;
    esac; printf ' 1 pass\n 0 fail\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$FAKE"
runit(){   # $1 = mods dir -> sets out and code
  : > "$LOG"
  out="$(STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" bash "$CHECK" "$1" 2>&1)"; code=$?
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

# 3. A mod with tests has them run; one with none is not asked to run any.
M3="$TMPROOT/m3"; mkmod "$M3" redtest-mod; printf 'x\n' > "$M3/redtest-mod/hooks/a.test.ts"; mkmod "$M3" untested
runit "$M3"
[ "$code" -eq 1 ] && check "a failing mod test fails the run" ok || check "a failing mod test fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'redtest-mod' | grep -q '1 fail' \
  && check "naming the mod and the test result" ok || check "naming the mod and the test result" "$out"
! grep -q "plugin test $M3/untested" "$LOG" && check "a mod with no tests is not run through the test runner" ok \
  || check "a mod with no tests is not run through the test runner" "$(cat "$LOG")"

# 3b. Every mod ships its own tsconfig.json (Dan, 2026-10-04, after #638): one without it gets the
#     copy Claude Code generates, which the sync then sends up as a local edit.
M3B="$TMPROOT/m3b"; mkmod "$M3B" bare-mod; rm "$M3B/bare-mod/tsconfig.json"; mkmod "$M3B" dressed
runit "$M3B"
[ "$code" -eq 1 ] && check "a mod with no tsconfig.json fails the run" ok || check "a mod with no tsconfig.json fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'bare-mod' | grep -q 'tsconfig.json' \
  && check "naming the mod and the missing file" ok || check "naming the mod and the missing file" "$out"
grep -q "plugin validate $M3B/dressed" "$LOG" && check "and the other mod was still checked" ok \
  || check "and the other mod was still checked" "$(cat "$LOG")"

# 3c. The tsconfig.json rule needs only the filesystem, so it holds where no claude command exists
#     (CI's Linux runner) instead of hiding behind UNMEASURED (lessons review of #645).
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" PATH=/usr/bin:/bin bash "$CHECK" "$M3B" 2>&1)"; code=$?
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

# 5. A folder with no manifest is not a mod and is not counted.
M5="$TMPROOT/m5"; mkdir -p "$M5/notes"; printf 'x\n' > "$M5/notes/readme"; : > "$M5/.gitkeep"
runit "$M5"
[ "$code" -eq 0 ] && case "$out" in *"0 mods checked"*) true ;; *) false ;; esac \
  && check "an empty mods folder passes and says it checked none" ok \
  || check "an empty mods folder passes and says it checked none" "exit=$code out=$out"

# 6. With no claude to ask, mods present is UNMEASURED: its own exit code, never a pass (L411, L490).
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" bash "$CHECK" "$M1" 2>&1)"; code=$?
[ "$code" -eq 3 ] && check "no claude means exit 3, unmeasured" ok || check "no claude means exit 3, unmeasured" "exit=$code out=$out"
case "$out" in *UNMEASURED*) check "and says UNMEASURED" ok ;; *) check "and says UNMEASURED" "$out" ;; esac

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

# 7. A mods folder that does not exist is refused, not passed as empty.
out="$(CLAUDE_BIN="$FAKE" STUB_LOG="$LOG" bash "$CHECK" "$TMPROOT/not-there" 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a missing mods folder is refused" ok || check "a missing mods folder is refused" "exit=$code out=$out"

# 8. The real tree, with the real binary where this machine has one.
REAL_BIN="$(command -v claude 2>/dev/null || true)"
[ -n "$REAL_BIN" ] || { [ -x "$HOME/.local/bin/claude" ] && REAL_BIN="$HOME/.local/bin/claude"; }
if [ ! -d "$ROOT/payload/mods" ]; then
  # The folder is created by the sync the first time a Mac sends a mod, and never by hand: payload/
  # in a development checkout is overwritten by the live daemon (payload-write-gate.sh).
  echo "note: payload/mods does not exist yet (no Mac has sent a mod), so there is nothing to check."
  check "the real mods folder is absent, which is not a pass over mods" ok
else
  out="$(CLAUDE_BIN="${REAL_BIN:-$TMPROOT/no-such-claude}" bash "$CHECK" "$ROOT/payload/mods" 2>&1)"; code=$?
  if [ "$code" -eq 3 ]; then
    echo "note: no claude command on this machine, so the real mods are reported UNMEASURED rather than passed."
    check "the real mods could not be measured here" ok
  elif [ "$code" -eq 4 ]; then
    # Claude Code's cached rollout switch, which this suite cannot set (#740, L411).
    echo "note: Claude Code has hooks modules switched off on this machine, so the real mods are UNMEASURED rather than passed:"
    printf '%s\n' "$out" | grep UNMEASURED | sed 's/^/  /'
    check "the real mods could not be measured here" ok
  else
    [ "$code" -eq 0 ] && check "every mod in payload/mods passes Claude Code's own checks" ok \
      || check "every mod in payload/mods passes Claude Code's own checks" "exit=$code out=$out"
  fi
fi

# 9. What every mod shares lives once, in mod-kit: the shell command reader, the blocked card,
#    the band above the prompt, which Claude Code gives one drawing (#610), the drawing of a card
#    in a side pane (#690), and the retry of a refused message to another session (#688)
#    (L613: the component plus the scan that fails on the next hand rolled copy). Three guards each
#    read commands their own way before batch 2 of the mods milestone.
SHARED="$ROOT/tools/check-mod-shared-parts.sh"
M9="$TMPROOT/m9"
mkmodsrc(){   # $1 = mods dir  $2 = mod name  $3 = the hooks module's source
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks"
  printf '{ "name": "%s", "version": "0.1.0", "description": "t" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
  printf '%s\n' "$3" > "$1/$2/hooks/register.ts"
}
mkmodsrc "$M9" clean-mod "export const register = on => { on('tool.call', async (\$, e, next) => next(e)) }"
mkmodsrc "$M9" mod-kit "const parts = cmd.split(/&&|;/); if (c === '\"' || c === \"'\") q = c; on('ui.render', { component: 'ToolResult' }, h); on('ui.render', { component: 'AbovePrompt' }, band); <Text strikethrough={p.strikethrough}>{'\\u2502'}</Text>; if (sent.isDelivered) return sent; return why || 'no reason given'; if (name === 'tee') add(f); const hasGit = dir => built.fs.exists(\`\${dir}/.git\`); const P = /\\bchild_process\\b/"
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
[ -n "$remedy" ] && eval "$remedy"
out="$(bash "$SHARED" "$M9C" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "and running that cp passes the run again" ok || check "and running that cp passes the run again" "exit=$code out=$out"
printf 'x\n' > "$M9C/reads-real/tests/mod-kit/hooks/gone.ts"
out="$(bash "$SHARED" "$M9C" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q "reads-real's tests/mod-kit/hooks/gone.ts copies no file of mod-kit's" \
  && check "a copy of a file mod-kit does not have fails the run, named" ok || check "a copy of a file mod-kit does not have fails the run, named" "exit=$code out=$out"
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
mkmodsrc "$M9" own-heredoc "const m = /(?<!<)<<(?!<)-?\s*(\w+)/.exec(line)"
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

# 10. The goal tracker sends the permission, question and "What's next?" notifications itself (Dan,
#     2026-10-04, #612), so no settings hook may send one too: Dan would get every one twice. Read
#     from the hooks block the payload installs, never a copy of it.
HOOKS_JSON="$ROOT/payload/settings.hooks.json"
dupes="$(python3 - "$HOOKS_JSON" <<'PY' 2>&1
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
)"; code=$?
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
out="$(bash "$WAITS" "$M12W" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a noun that waits with no bound under 10 s fails the run" ok || check "a noun that waits with no bound under 10 s fails the run" "exit=$code out=$out"
case "$out" in *"13 mods checked"*) check "and the count is stated" ok ;; *) check "and the count is stated" "$out" ;; esac
for at in waits-in-map/hooks/register.ts:8 passed-to-listener/hooks/register.ts:4 called-back-later/hooks/register.ts:5 through-helper/hooks/register.ts:3 named-executor/hooks/register.ts:8 long-timer/hooks/register.ts:5 unrelated-timer/hooks/register.ts:5 on-noun-event/hooks/register.ts:7; do
  printf '%s\n' "$out" | grep -F "$at" | grep -q 'settled only by a later event' \
    && check "a wait settled only by a later event is named at ${at%%/*}'s line" ok \
    || check "a wait settled only by a later event is named at ${at%%/*}'s line" "$out"
done
printf '%s\n' "$out" | grep -F 'asks-a-person/hooks/register.ts:4' | grep -q 'waits on a person' \
  && check "a noun asking a person through \$.ui.ask is named" ok || check "a noun asking a person through \$.ui.ask is named" "$out"
printf '%s\n' "$out" | grep -F 'lost-executor/hooks/register.ts:4' | grep -q 'cannot be read' \
  && check "an executor that cannot be found is reported as unreadable, never passed" ok \
  || check "an executor that cannot be found is reported as unreadable, never passed" "$out"
for m in bounded commented outside-any-noun; do
  ! printf '%s\n' "$out" | grep -q "$m/" && check "$m passes" ok || check "$m passes" "$out"
done
# Cut down to the mods that pass, the run passes, so the failure above is theirs alone.
for m in waits-in-map passed-to-listener called-back-later through-helper named-executor long-timer unrelated-timer on-noun-event asks-a-person lost-executor; do rm -rf "${M12W:?}/$m"; done
out="$(bash "$WAITS" "$M12W" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "a noun bounded under 10 s, a comment and a wait outside any noun all pass" ok \
  || check "a noun bounded under 10 s, a comment and a wait outside any noun all pass" "exit=$code out=$out"
out="$(bash "$WAITS" "$TMPROOT/not-there" 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a missing mods folder is refused by the noun wait check" ok \
  || check "a missing mods folder is refused by the noun wait check" "exit=$code out=$out"
if [ -d "$ROOT/payload/mods" ]; then
  out="$(bash "$WAITS" "$ROOT/payload/mods" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "no mod in payload/mods has a noun that waits past 10 s" ok \
    || check "no mod in payload/mods has a noun that waits past 10 s" "exit=$code out=$out"
fi
# Every check this suite runs can be run directly, as its header says, so each is committed
# executable (the lessons review of #744: the noun wait check was committed 644 beside its 755
# siblings, which this suite's own `bash <check>` could never notice).
for t in "$CHECK" "$SHARED" "$DEPS" "$WAITS"; do
  [ -x "$t" ] && check "${t#"$ROOT"/} is executable" ok || check "${t#"$ROOT"/} is executable" "not executable"
done

# 13. The goal tracker reads ask before saving's waiting saves, `ask-before-saving.pending`, as a list
#     whose first entry has id: string (#706), and its own tests can only stand in for ask before
#     saving, so its reading is checked here against the contract ask before saving declares (L52).
#     Shown failing on a contract whose shape moved, then held on the real one. The contract is read
#     with a block's members at its own top level and comments taken out (#735), through the one
#     reader of source every mod scan shares. (Picker manners' open question was checked the same way
#     until #744 removed it, and the goal tracker's reading of it with it.)
TS_LIB="$ROOT/tools/lib"
save_contract(){   # $1 = ask before saving's types file -> prints what does not match, exits 1 when anything does not
  python3 - "$1" "$TS_LIB" <<'PY'
import re, sys
sys.path.insert(0, sys.argv[2])
from ts_source import block_after, top_members
try:
    text = open(sys.argv[1]).read()
except OSError as e:
    print(f"cannot read {sys.argv[1]}: {e}")
    sys.exit(1)
wrong = []
state = block_after(text, r"'ask-before-saving'\s*:\s*\{")
if state is None or not re.match(r"AskBeforeSavingQuestion\[\]$", top_members(state).get("pending", "")):
    wrong.append("PluginState 'ask-before-saving' does not declare pending: AskBeforeSavingQuestion[]")
body = block_after(text, r"export type AskBeforeSavingQuestion\s*=\s*\{")
if body is None:
    wrong.append("there is no AskBeforeSavingQuestion type")
elif top_members(body).get("id") != "string":
    wrong.append("AskBeforeSavingQuestion has no id: string")
print("; ".join(wrong))
sys.exit(1 if wrong else 0)
PY
}
ABS_TYPES="$ROOT/payload/mods/ask-before-saving/types/index.d.ts"
if [ ! -f "$ABS_TYPES" ]; then
  echo "note: ask before saving is not in payload/mods, so the goal tracker reads no waiting save of its and there is no contract to check."
  check "ask before saving is absent, which is not a pass over its contract" ok
else
  M13="$TMPROOT/m13"; mkdir -p "$M13"
  sed 's/^  id: string$/  callId: string/' "$ABS_TYPES" > "$M13/moved.d.ts"
  grep -q '^  callId: string$' "$M13/moved.d.ts" || check "the moved fixture was made" "sed did not change the contract"
  out="$(save_contract "$M13/moved.d.ts" 2>&1)"; code=$?
  [ "$code" -eq 1 ] && case "$out" in *"AskBeforeSavingQuestion has no id: string"*) true ;; *) false ;; esac \
    && check "an ask before saving contract whose question id moved fails the goal tracker's reading" ok \
    || check "an ask before saving contract whose question id moved fails the goal tracker's reading" "exit=$code out=$out"
  # A member with an inline object type ahead of pending does not hide it (lessons review of #709).
  sed "s/'ask-before-saving': { pending:/'ask-before-saving': { meta: { at: number }; pending:/" "$ABS_TYPES" > "$M13/nested.d.ts"
  grep -q 'meta: { at: number }; pending:' "$M13/nested.d.ts" || check "the nested fixture was made" "sed did not change the contract"
  out="$(save_contract "$M13/nested.d.ts" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "an inline object type ahead of pending still finds pending" ok \
    || check "an inline object type ahead of pending still finds pending" "exit=$code out=$out"
  # Members separated by commas, as TypeScript allows, with a generic's comma among them, are read
  # the same as ones on lines of their own (lessons review of #737).
  printf '%s\n' "export type AskBeforeSavingQuestion = { id: string, input: Record<string, unknown>, files: string[] }" \
    "declare module 'claude-code' { interface PluginState { 'ask-before-saving': { pending: AskBeforeSavingQuestion[], rules: string[] } } }" > "$M13/commas.d.ts"
  out="$(save_contract "$M13/commas.d.ts" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "a contract whose members are separated by commas is read the same" ok \
    || check "a contract whose members are separated by commas is read the same" "exit=$code out=$out"
  # #735: a member counts only at the block's own top level, never nested in another member's type
  # or standing in a comment.
  perl -pe 's/^  id: string$/  callId: string\n  meta: {\n    id: string\n  }/' "$ABS_TYPES" > "$M13/nested-id.d.ts"
  perl -pe 's/^  id: string$/  \/*\n  id: string\n  *\/\n  callId: string/' "$ABS_TYPES" > "$M13/commented-id.d.ts"
  perl -pe "s/'ask-before-saving': \{ pending:/'ask-before-saving': { \/* pending: AskBeforeSavingQuestion[] *\/ waiting:/" "$ABS_TYPES" > "$M13/commented-pending.d.ts"
  for f in nested-id commented-id commented-pending; do
    cmp -s "$ABS_TYPES" "$M13/$f.d.ts" && check "the $f fixture was made" "perl did not change the contract"
  done
  for f in nested-id:'AskBeforeSavingQuestion has no id: string' commented-id:'AskBeforeSavingQuestion has no id: string' commented-pending:'does not declare pending: AskBeforeSavingQuestion[]'; do
    out="$(save_contract "$M13/${f%%:*}.d.ts" 2>&1)"; code=$?
    [ "$code" -eq 1 ] && case "$out" in *"${f#*:}"*) true ;; *) false ;; esac \
      && check "an ask before saving contract with only ${f%%:*} fails the goal tracker's reading" ok \
      || check "an ask before saving contract with only ${f%%:*} fails the goal tracker's reading" "exit=$code out=$out"
  done
  out="$(save_contract "$ABS_TYPES" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "ask before saving's contract declares the waiting saves as the goal tracker reads them" ok \
    || check "ask before saving's contract declares the waiting saves as the goal tracker reads them" "exit=$code out=$out"
  grep -q "SAVE_PENDING = { plugin: 'ask-before-saving', key: 'pending' }" "$ROOT/payload/mods/goal-tracker/hooks/register.tsx" \
    && check "and the goal tracker watches that key" ok || check "and the goal tracker watches that key" "no SAVE_PENDING for ask-before-saving pending in goal-tracker"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
