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

# 9. What every mod shares lives once, in mod-kit: the shell command reader and the blocked card
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
mkmodsrc "$M9" mod-kit "const parts = cmd.split(/&&|;/); if (c === '\"' || c === \"'\") q = c; on('ui.render', { component: 'ToolResult' }, h)"
out="$(bash "$SHARED" "$M9" 2>&1)"; code=$?
[ "$code" -eq 0 ] && check "mod-kit itself may hold the shared parts, and a clean mod passes" ok \
  || check "mod-kit itself may hold the shared parts, and a clean mod passes" "exit=$code out=$out"
case "$out" in *"2 mods checked"*) check "and the count is stated" ok ;; *) check "and the count is stated" "$out" ;; esac
mkmodsrc "$M9" own-reader "const words = command.split(/&&|\|\||;/).map(s => s.trim())"
mkmodsrc "$M9" own-quotes "for (const c of cmd) { if (c === '\"' || c === \"'\") quote = c }"
mkmodsrc "$M9" own-heredoc "const m = /(?<!<)<<(?!<)-?\s*(\w+)/.exec(line)"
mkmodsrc "$M9" own-card "on('ui.render', { component: 'ToolResult' }, (\$, e, next) => next(e))"
mkmodsrc "$M9" own-git "const GLOBAL = new Set(['-C', '-c', '--git-dir', '--work-tree'])"
out="$(bash "$SHARED" "$M9" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod with its own copy of a shared part fails the run" ok \
  || check "a mod with its own copy of a shared part fails the run" "exit=$code out=$out"
for m in own-reader own-quotes own-heredoc own-card own-git; do
  case "$out" in *"$m"*) check "and names $m" ok ;; *) check "and names $m" "$out" ;; esac
done
out="$(bash "$SHARED" "$TMPROOT/not-there" 2>&1)"; code=$?
[ "$code" -eq 2 ] && check "a missing mods folder is refused by the shared parts check too" ok \
  || check "a missing mods folder is refused by the shared parts check too" "exit=$code out=$out"
if [ -d "$ROOT/payload/mods" ]; then
  out="$(bash "$SHARED" "$ROOT/payload/mods" 2>&1)"; code=$?
  [ "$code" -eq 0 ] && check "no mod in payload/mods keeps its own copy of a shared part" ok \
    || check "no mod in payload/mods keeps its own copy of a shared part" "exit=$code out=$out"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
