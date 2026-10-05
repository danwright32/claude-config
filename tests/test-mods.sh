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
  "plugin test") case "$3" in *redtest*) printf ' 0 pass\n 1 fail\n'; exit 1 ;; esac; printf ' 1 pass\n 0 fail\n' ;;
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
mkmodsrc "$M9" mod-kit "const parts = cmd.split(/&&|;/); if (c === '\"' || c === \"'\") q = c; on('ui.render', { component: 'ToolResult' }, h); on('ui.render', { component: 'AbovePrompt' }, band); <Text strikethrough={p.strikethrough}>{'\\u2502'}</Text>; if (sent.isDelivered) return sent; return why || 'no reason given'; if (name === 'tee') add(f)"
# A mod that sends once and reports a refusal is what every sender looks like after #688, so it passes.
# A pane drawn its own way (the goals pane: a live list read at each draw, not a card) is not a copy.
mkmodsrc "$M9" clean-live-pane "on('ui.render', { component: 'Pane', requestId: 'goals' }, (\$, e) => <Text dimColor>{row.sentence}</Text>)"
mkmodsrc "$M9" clean-sender "const sent = await \$.session.send({ to: { sessionId }, text }); if (!sent.isDelivered) failed.push(sent.reason)"
# The two mods still holding their own write reader until #712 moves them are named as exceptions,
# on every run, rather than failing it or passing in silence (L129, L523).
mkmodsrc "$M9" collision-guard "switch (name) { case 'tee': add(f) }"
out="$(bash "$SHARED" "$M9" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "mod-kit itself may hold the shared parts, and a clean mod passes" ok \
  || check "mod-kit itself may hold the shared parts, and a clean mod passes" "exit=$code out=$out"
case "$out" in *"5 mods checked"*) check "and the count is stated" ok ;; *) check "and the count is stated" "$out" ;; esac
printf '%s\n' "$out" | grep 'collision-guard' | grep -q '#712' \
  && check "a known exception to the write reader is named on every run, with the issue that ends it" ok \
  || check "a known exception to the write reader is named on every run, with the issue that ends it" "$out"
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
out="$(bash "$SHARED" "$M9" 2>&1)"; code=$?
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
out="$(bash "$DEPS" "$TMPROOT/not-there" 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a missing mods folder is refused by the dependency check" ok \
  || check "a missing mods folder is refused by the dependency check" "exit=$code out=$out"
if [ -d "$ROOT/payload/mods" ]; then
  out="$(bash "$DEPS" "$ROOT/payload/mods" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "every mod in payload/mods uses each dependency it lists" ok \
    || check "every mod in payload/mods uses each dependency it lists" "exit=$code out=$out"
fi

# 12. The goal tracker reads picker manners' open question, `picker-manners.open`, as { id: string,
#     question: { question: string } } (#694), and its own tests can only stand in for picker manners,
#     so its reading is checked here against the contract picker manners declares (lessons review of
#     #696, L52). Shown failing on a contract whose shape moved, then held on the real one.
picker_contract(){   # $1 = picker manners' types file -> prints what does not match, exits 1 when anything does not
  python3 - "$1" <<'PY'
import re, sys
try:
    text = open(sys.argv[1]).read()
except OSError as e:
    print(f"cannot read {sys.argv[1]}: {e}")
    sys.exit(1)
def block_after(pattern, top_only):
    """The body of the brace block that pattern opens, to its own closing brace; with top_only, what
    is nested in it blanked. None when there is no such block or it never closes."""
    m = re.search(pattern, text)
    if not m:
        return None
    depth, out = 1, []
    for c in text[m.end():]:
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return "".join(out)
        out.append(c if depth == 1 or not top_only or c == "\n" else " ")
    return None
wrong = []
state = block_after(r"'picker-manners'\s*:\s*\{", True)
if state is None or not re.search(r"\bopen\s*:\s*PickersOpen\s*\|\s*null", state):
    wrong.append("PluginState 'picker-manners' does not declare open: PickersOpen | null")
body = block_after(r"export type PickersOpen\s*=\s*\{", False)
if body is None:
    wrong.append("there is no PickersOpen type")
else:
    if not re.search(r"^\s*id\s*:\s*string\b", body, re.M):
        wrong.append("PickersOpen has no id: string")
    if not re.search(r"^\s*question\s*:\s*\{\s*question\s*:\s*string\b", body, re.M):
        wrong.append("PickersOpen has no question: { question: string }")
print("; ".join(wrong))
sys.exit(1 if wrong else 0)
PY
}
PM_TYPES="$ROOT/payload/mods/picker-manners/types/index.d.ts"
if [ ! -f "$PM_TYPES" ]; then
  echo "note: picker manners is not in payload/mods, so the goal tracker reads no open question of its and there is no contract to check."
  check "picker manners is absent, which is not a pass over its contract" ok
else
  M12="$TMPROOT/m12"; mkdir -p "$M12"
  sed 's/^  id: string$/  callId: string/' "$PM_TYPES" > "$M12/moved.d.ts"
  out="$(picker_contract "$M12/moved.d.ts" 2>&1)"; code=$?
  [ "$code" -eq 1 ] && case "$out" in *"PickersOpen has no id: string"*) true ;; *) false ;; esac \
    && check "a picker manners contract whose open question moved fails the goal tracker's reading" ok \
    || check "a picker manners contract whose open question moved fails the goal tracker's reading" "exit=$code out=$out"
  # A member with an inline object type ahead of open does not hide it (lessons review of #709).
  sed "s/'picker-manners': { open:/'picker-manners': { meta: { at: number }; open:/" "$PM_TYPES" > "$M12/nested.d.ts"
  grep -q 'meta: { at: number }; open:' "$M12/nested.d.ts" || check "the nested fixture was made" "sed did not change the contract"
  out="$(picker_contract "$M12/nested.d.ts" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "an inline object type ahead of open still finds open" ok \
    || check "an inline object type ahead of open still finds open" "exit=$code out=$out"
  out="$(picker_contract "$PM_TYPES" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "picker manners' contract declares the open question as the goal tracker reads it" ok \
    || check "picker manners' contract declares the open question as the goal tracker reads it" "exit=$code out=$out"
  grep -q "PICKER_OPEN = { plugin: 'picker-manners', key: 'open' }" "$ROOT/payload/mods/goal-tracker/hooks/register.tsx" \
    && check "and the goal tracker watches that key" ok || check "and the goal tracker watches that key" "no PICKER_OPEN for picker-manners open in goal-tracker"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
