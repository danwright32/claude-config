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
[ "$1" = --version ] && { echo "${FAKE_CC_VERSION:-2.1.291} (Claude Code)"; exit 0; }
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
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" PATH=/usr/bin:/bin bash "$CHECK" "$M3S" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a stand-in casting what engine.create returns fails the run, with no claude command" ok \
  || check "a stand-in casting what engine.create returns fails the run, with no claude command" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q 'cast-one-line/tests/register.test.ts:4:.*as never' \
  && check "naming the one line cast by file and line" ok || check "naming the one line cast by file and line" "$out"
printf '%s\n' "$out" | grep -q 'cast-multi-line/tests/register.test.ts:4:.*as never' \
  && check "and the cast closing an object over several lines, at its return" ok \
  || check "and the cast closing an object over several lines, at its return" "$out"
! printf '%s\n' "$out" | grep -q 'uncast/' && check "while an uncast return and casts elsewhere in a hook pass" ok \
  || check "while an uncast return and casts elsewhere in a hook pass" "$out"

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

# 4c. Strict types (#758). Claude Code lays its declarations and the tsconfig a mod extends under
#     .claude-plugin/types once it has loaded the mod; with those and a TypeScript compiler, a mod is
#     type checked as its own tsconfig.json says, and errors fail the run by name and count. The
#     compiler is a stub that fails any mod whose folder name holds "illtyped" (L2: no real tsc).
TSC="$TMPROOT/tsc"; TSC_LOG="$TMPROOT/tsc-calls"
cat > "$TSC" <<'STUB'
#!/bin/bash
echo "$*" >> "$TSC_LOG"
# What a dependency's types said where the compiler read them (#840).
for f in "$2"/.claude-plugin/types/*/index.d.ts; do [ -f "$f" ] && echo "DEP $(basename "$(dirname "$f")"): $(cat "$f")" >> "$TSC_LOG"; done
# And the laid tsconfig it read, on one line (#951).
[ -f "$2/.claude-plugin/types/tsconfig.json" ] && echo "CONF $(basename "$2"): $(tr -d ' \n' < "$2/.claude-plugin/types/tsconfig.json")" >> "$TSC_LOG"
case "$2" in *crashing*) printf 'node:internal/modules/cjs/loader:1228\n  throw err;\nError: Cannot find module typescript\n'; exit 1 ;; esac
case "$2" in *illtyped*) printf 'hooks/register.tsx(3,1): error TS2339: no such thing\nhooks/register.tsx(9,1): error TS2604: not a component\n'; exit 2 ;; esac
# Every mod imports its own files as ./x.ts, which the tsconfig Claude Code lays does not allow, so
# real tsc refuses each one unless the check allows them itself (lessons review of #797).
case " $* " in *" --allowImportingTsExtensions "*) ;; *) printf "hooks/register.tsx(1,20): error TS5097: An import path can only end with a '.ts' extension when 'allowImportingTsExtensions' is enabled.\n"; exit 2 ;; esac
exit 0
STUB
chmod +x "$TSC"
laid(){ mkdir -p "$1/.claude-plugin/types"; printf '{}\n' > "$1/.claude-plugin/types/tsconfig.json"; }
M4C="$TMPROOT/m4c"; mkmod "$M4C" illtyped; laid "$M4C/illtyped"; mkmod "$M4C" welltyped; laid "$M4C/welltyped"; mkmod "$M4C" unlaid
: > "$TSC_LOG"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC" bash "$CHECK" "$M4C" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a mod failing a strict type check fails the run" ok || check "a mod failing a strict type check fails the run" "exit=$code out=$out"
printf '%s\n' "$out" | grep 'illtyped' | grep -q '2 errors' \
  && check "naming the mod and how many errors" ok || check "naming the mod and how many errors" "$out"
printf '%s\n' "$out" | grep 'welltyped ok' | grep -q 'types checked' \
  && check "a mod that type checks says its types were checked" ok || check "a mod that type checks says its types were checked" "$out"
printf '%s\n' "$out" | grep 'unlaid ok' | grep -q 'types not checked: Claude Code has not laid its types here' \
  && check "a mod with no laid types says so rather than claiming a check" ok || check "a mod with no laid types says so rather than claiming a check" "$out"
! grep -q "$M4C/unlaid" "$TSC_LOG" && check "and the compiler is not run on it" ok || check "and the compiler is not run on it" "$(cat "$TSC_LOG")"
# A compiler that fails without reporting any type error measured nothing, so it is said as that,
# never as "0 errors" (lessons review of #797, L11).
M4D="$TMPROOT/m4d"; mkmod "$M4D" crashing; laid "$M4D/crashing"
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

# 4d. The pinned compiler and the borrowed types (#803). Claude Code lays a mod's types only in the
#     copy it loads (~/.claude/mods/<mod>), which the mirror never carries, so a check of
#     payload/mods borrows them from there; a pinned compiler in tools/typescript is found with
#     no TSC_BIN; a mod whose errors were recorded passes while its count is at or under the
#     record; and every mod left unchecked is summed up as UNMEASURED with the install command.
M4E="$TMPROOT/m4e"; mkmod "$M4E" borrowed; mkmod "$M4E" illtyped-known; mkmod "$M4E" illtyped-new
TH="$TMPROOT/types-home"
for m in borrowed illtyped-known illtyped-new; do laid "$TH/mods/$m"; done
TSDIR="$TMPROOT/ts"; mkdir -p "$TSDIR/node_modules/.bin"; cp "$TSC" "$TSDIR/node_modules/.bin/tsc"
printf 'illtyped-known\thooks/register.tsx TS2339\t1\t#900\nilltyped-known\thooks/register.tsx TS2604\t1\t#900\n' > "$TSDIR/known-type-errors.tsv"
: > "$TSC_LOG"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH" CHECK_MODS_TS_DIR="$TSDIR" PATH=/usr/bin:/bin bash "$CHECK" "$M4E" 2>&1)"; code=$?
printf '%s\n' "$out" | grep 'borrowed ok' | grep -q 'types checked' \
  && check "a mod whose types were laid only in the installed copy is type checked with them" ok \
  || check "a mod whose types were laid only in the installed copy is type checked with them" "$out"
grep -q -- "-p .*borrowed" "$TSC_LOG" && check "by the pinned compiler, found with no TSC_BIN" ok || check "by the pinned compiler, found with no TSC_BIN" "$(cat "$TSC_LOG")"
printf '%s\n' "$out" | grep 'illtyped-known ok' | grep -q '2 known type errors (#900)' \
  && check "a mod at its recorded count of type errors passes, naming the count and the issue" ok \
  || check "a mod at its recorded count of type errors passes, naming the count and the issue" "$out"
printf '%s\n' "$out" | grep -q 'illtyped-new fails a strict type check (2 errors)' \
  && check "a mod with no record that fails the type check still fails" ok \
  || check "a mod with no record that fails the type check still fails" "$out"
[ "$code" -eq 1 ] && check "and fails the run" ok || check "and fails the run" "exit=$code"
# One recorded error fixed and a new one made: the count is the same, and the new one still fails.
printf 'illtyped-known\thooks/register.tsx TS2339\t1\t#900\nilltyped-known\thooks/register.tsx TS9999\t1\t#900\n' > "$TSDIR/known-type-errors.tsv"; rm -rf "${M4E:?}/illtyped-new"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH" CHECK_MODS_TS_DIR="$TSDIR" PATH=/usr/bin:/bin bash "$CHECK" "$M4E" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'illtyped-known' | grep -q 'type errors not in the record.*hooks/register.tsx TS2604 (1 found, 0 recorded)' \
  && check "an error not in the record fails though the count is unchanged, naming where and how many" ok \
  || check "an error not in the record fails though the count is unchanged, naming where and how many" "exit=$code out=$out"
printf 'illtyped-known\thooks/register.tsx TS2339\t3\t#900\nilltyped-known\thooks/register.tsx TS2604\t1\t#900\n' > "$TSDIR/known-type-errors.tsv"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH" CHECK_MODS_TS_DIR="$TSDIR" PATH=/usr/bin:/bin bash "$CHECK" "$M4E" 2>&1)"; code=$?
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep 'illtyped-known ok' | grep -q 'fewer than recorded' \
  && check "a mod under its record passes and says the record can come down" ok \
  || check "a mod under its record passes and says the record can come down" "exit=$code out=$out"
# A dependency's types are the copy under review, never the installed one the laid types copied
# (#840): a mod checked against its dependency's old contract fails a change made to both in one
# PR, and passes one that breaks it, until the next install. A dependency the folder does not hold
# keeps its laid types, and Claude Code's own are never touched.
M4G="$TMPROOT/m4g"; mkmod "$M4G" dependent; mkmod "$M4G" provider
mkdir -p "$M4G/provider/types"; printf 'export type P = "new"\n' > "$M4G/provider/types/index.d.ts"
TH4G="$TMPROOT/types-home-4g"; laid "$TH4G/mods/dependent"; laid "$TH4G/mods/provider"
# Laid as Claude Code lays them: each dependency's index.d.ts a symbolic link to the INSTALLED
# dependency's own types file, so a copy written through it would rewrite the installed mod, which the
# sync then pushes to main (it did, 2026-10-07, while #840 was built).
for dep in provider elsewhere claude-code; do
  mkdir -p "$TH4G/mods/dependent/.claude-plugin/types/$dep" "$TH4G/mods/$dep/types"
  printf 'export type P = "installed %s"\n' "$dep" > "$TH4G/mods/$dep/types/index.d.ts"
  ln -s "$TH4G/mods/$dep/types/index.d.ts" "$TH4G/mods/dependent/.claude-plugin/types/$dep/index.d.ts"
done
: > "$TSC_LOG"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH4G" CHECK_MODS_TS_DIR="$TSDIR" PATH=/usr/bin:/bin bash "$CHECK" "$M4G" 2>&1)"; code=$?
grep -q 'DEP provider: export type P = "new"' "$TSC_LOG" \
  && check "a dependency's types are read from the folder under review" ok || check "a dependency's types are read from the folder under review" "$(cat "$TSC_LOG")"
grep -q 'DEP elsewhere: export type P = "installed elsewhere"' "$TSC_LOG" && grep -q 'DEP claude-code: export type P = "installed claude-code"' "$TSC_LOG" \
  && check "one the folder does not hold, and Claude Code's own, keep their laid types" ok || check "one the folder does not hold, and Claude Code's own, keep their laid types" "$(cat "$TSC_LOG")"
[ "$(cat "$TH4G/mods/provider/types/index.d.ts")" = 'export type P = "installed provider"' ] && [ -L "$TH4G/mods/dependent/.claude-plugin/types/provider/index.d.ts" ] \
  && check "and the installed copy is never written, through the laid link or otherwise" ok \
  || check "and the installed copy is never written, through the laid link or otherwise" "$(cat "$TH4G/mods/provider/types/index.d.ts")"
# A dependency the change under review ADDS was never laid for the installed copy, so it is laid
# here from the folder, types and tsconfig entry both, or the mod fails on every use of it until the
# next install (#951). One the folder does not hold is left unlaid, never invented; one listed across
# lines is read too.
M4H="$TMPROOT/m4h"; mkmod "$M4H" adds-dep; mkmod "$M4H" provider
mkdir -p "$M4H/provider/types"; printf 'export type P = "new"\n' > "$M4H/provider/types/index.d.ts"
printf '{ "name": "adds-dep", "version": "0.1.0", "description": "x",\n  "dependencies": [\n    "provider",\n    "nowhere"\n  ]\n}\n' > "$M4H/adds-dep/.claude-plugin/plugin.json"
TH4H="$TMPROOT/types-home-4h"; laid "$TH4H/mods/adds-dep"; laid "$TH4H/mods/provider"
printf '{ "compilerOptions": { "types": ["claude-code"] } }\n' > "$TH4H/mods/adds-dep/.claude-plugin/types/tsconfig.json"
: > "$TSC_LOG"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH4H" CHECK_MODS_TS_DIR="$TSDIR" PATH="/usr/bin:/bin:$(dirname "$(command -v python3)")" bash "$CHECK" "$M4H" 2>&1)"; code=$?
grep -q 'DEP provider: export type P = "new"' "$TSC_LOG" \
  && check "a dependency the change adds is laid from the folder under review" ok || check "a dependency the change adds is laid from the folder under review" "$(cat "$TSC_LOG")"
grep -q 'CONF adds-dep: .*"types":\["claude-code","provider"\]' "$TSC_LOG" \
  && check "and named among the laid tsconfig's types" ok || check "and named among the laid tsconfig's types" "$(cat "$TSC_LOG")"
! grep -q 'DEP nowhere' "$TSC_LOG" && ! grep -q '"nowhere"' "$TSC_LOG" \
  && check "while one the folder does not hold is never invented" ok || check "while one the folder does not hold is never invented" "$(cat "$TSC_LOG")"
printf '%s\n' "$out" | grep 'adds-dep ok' | grep -q 'types checked' \
  && check "and the mod is type checked with it" ok || check "and the mod is type checked with it" "$out"
[ ! -d "$TH4H/mods/adds-dep/.claude-plugin/types/provider" ] && grep -q '\["claude-code"\]' "$TH4H/mods/adds-dep/.claude-plugin/types/tsconfig.json" \
  && check "and the installed copy's laid types are never written" ok || check "and the installed copy's laid types are never written" "$(ls "$TH4H/mods/adds-dep/.claude-plugin/types")"
# Lessons review of #964. A laid tsconfig with no types list includes every folder under its type
# roots, the new one too, so none is made: a list naming one dependency would stop the others being
# included. A dependency laid as a link to an installed file that is gone is never written through,
# which would create that file in the installed mod. And a mod with no dependencies needs no python3,
# so one missing does not leave its types unchecked.
M4J="$TMPROOT/m4j"; mkmod "$M4J" adds-dep; mkmod "$M4J" provider; mkmod "$M4J" linked; mkmod "$M4J" plain
mkdir -p "$M4J/provider/types"; printf 'export type P = "new"\n' > "$M4J/provider/types/index.d.ts"
printf '{ "name": "adds-dep", "version": "0.1.0", "description": "x", "dependencies": ["provider"] }\n' > "$M4J/adds-dep/.claude-plugin/plugin.json"
printf '{ "name": "linked", "version": "0.1.0", "description": "x", "dependencies": ["provider"] }\n' > "$M4J/linked/.claude-plugin/plugin.json"
TH4J="$TMPROOT/types-home-4j"; for m in adds-dep linked plain; do laid "$TH4J/mods/$m"; done
printf '{ "compilerOptions": { "typeRoots": ["."] } }\n' > "$TH4J/mods/adds-dep/.claude-plugin/types/tsconfig.json"
mkdir -p "$TH4J/mods/linked/.claude-plugin/types/provider" "$TH4J/mods/provider/types"
ln -s "$TH4J/mods/provider/types/index.d.ts" "$TH4J/mods/linked/.claude-plugin/types/provider/index.d.ts"
: > "$TSC_LOG"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH4J" CHECK_MODS_TS_DIR="$TSDIR" PATH="/usr/bin:/bin:$(dirname "$(command -v python3)")" bash "$CHECK" "$M4J" 2>&1)"; code=$?
grep -q 'CONF adds-dep: {"compilerOptions":{"typeRoots":\["."\]}}' "$TSC_LOG" && grep -q 'DEP provider: export type P = "new"' "$TSC_LOG" \
  && check "a laid tsconfig with no types list is given none, the dependency still laid" ok || check "a laid tsconfig with no types list is given none, the dependency still laid" "$(cat "$TSC_LOG")"
[ ! -e "$TH4J/mods/provider/types/index.d.ts" ] \
  && check "a dependency laid as a link to an installed file that is gone is never written through" ok \
  || check "a dependency laid as a link to an installed file that is gone is never written through" "$(cat "$TH4J/mods/provider/types/index.d.ts")"
out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH4J" CHECK_MODS_TS_DIR="$TSDIR" CHECK_MODS_PYTHON="$TMPROOT/no-such-python" PATH=/usr/bin:/bin bash "$CHECK" "$M4J" 2>&1)"; code=$?
printf '%s\n' "$out" | grep 'plain ok' | grep -q 'types checked' \
  && check "with no python3, a mod with no dependencies is still type checked" ok || check "with no python3, a mod with no dependencies is still type checked" "$out"
printf '%s\n' "$out" | grep 'adds-dep ok' | grep -q 'types not checked: .*no python3' \
  && check "while one with dependencies says its types were not checked, and why" ok || check "while one with dependencies says its types were not checked, and why" "$out"
# Types laid for the installed copy but no compiler: the cause named is the compiler, not the types.
out="$(STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH" CHECK_MODS_TS_DIR="$TMPROOT/no-ts" TSC_BIN="$TMPROOT/no-such-tsc" PATH=/usr/bin:/bin bash "$CHECK" "$M4E" 2>&1)"; code=$?
printf '%s\n' "$out" | grep 'borrowed ok' | grep -q 'types not checked: no TypeScript compiler' \
  && printf '%s\n' "$out" | grep -q 'UNMEASURED: .*not checked ([0-9]* no TypeScript compiler: ' \
  && check "with types to borrow but no compiler, the compiler is what is named" ok \
  || check "with types to borrow but no compiler, the compiler is what is named" "$out"
# Types laid but the scratch copy fails (here, a scratch folder that cannot be written): that is the
# cause named, never missing types.
# A user who can write anyway (root, in the Linux container) cannot be refused this way, so there it
# is said as unmeasured rather than read as a fault in the check (L411).
RO="$TMPROOT/ro-tmp"; mkdir -p "$RO"; chmod 500 "$RO"
if [ -w "$RO" ]; then
  echo "UNMEASURED: this user can write a mode 500 folder, so a scratch copy that fails cannot be staged here"
else
  out="$(TMPDIR="$RO" STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH" CHECK_MODS_TS_DIR="$TSDIR" TSC_BIN="$TSC" PATH=/usr/bin:/bin bash "$CHECK" "$M4E" 2>&1)"; code=$?
  printf '%s\n' "$out" | grep 'borrowed ok' | grep -q 'could not copy it to scratch' \
    && check "a mod whose scratch copy fails says so, not that no types were laid" ok \
    || check "a mod whose scratch copy fails says so, not that no types were laid" "$out"
  # Two causes in one run are each counted and named in the summary, never folded into the last.
  TH2="$TMPROOT/types-home-2"; laid "$TH2/mods/borrowed"
  out="$(TMPDIR="$RO" STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH2" CHECK_MODS_TS_DIR="$TSDIR" TSC_BIN="$TSC" PATH=/usr/bin:/bin bash "$CHECK" "$M4E" 2>&1)"; code=$?
  printf '%s\n' "$out" | grep 'UNMEASURED: 2 of 2' | grep 'could not be copied to scratch: borrowed' | grep -q 'no types laid: illtyped-known' \
    && check "the summary counts and names each cause" ok || check "the summary counts and names each cause" "$out"
fi
chmod 700 "$RO"
# Nothing laid anywhere and no compiler: one UNMEASURED summary naming how many and the install command.
rm -rf "$TSDIR/node_modules"
out="$(STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TMPROOT/no-types" CHECK_MODS_TS_DIR="$TSDIR" PATH=/usr/bin:/bin bash "$CHECK" "$M4E" 2>&1)"; code=$?
[ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -q "UNMEASURED: 2 of 2 mods' types were not checked" \
  && check "mods left unchecked are summed up as UNMEASURED, never a silent skip" ok \
  || check "mods left unchecked are summed up as UNMEASURED, never a silent skip" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q 'npm ci --prefix tools/typescript' \
  && check "with the command that installs the pinned compiler" ok || check "with the command that installs the pinned compiler" "$out"

# 4e. Which Claude Code the types came from (#833). The laid types describe the Claude Code build
#     that laid them, so the record of known errors is only comparable against the build it was
#     measured on. That build is recorded beside the record, and a run on another build names both,
#     so a difference reads as newer types and not as a regression in the mod. It still fails: a
#     real regression on the other build looks exactly the same (L42).
M4F="$TMPROOT/m4f"; mkmod "$M4F" verclean; mkmod "$M4F" illtyped-ver
TH4F="$TMPROOT/types-home-4f"; laid "$TH4F/mods/verclean"; laid "$TH4F/mods/illtyped-ver"
TS4F="$TMPROOT/ts-4f"; mkdir -p "$TS4F/node_modules/.bin"; cp "$TSC" "$TS4F/node_modules/.bin/tsc"
printf '2.1.291\n' > "$TS4F/claude-code-version"
run4f(){ out="$(STUB_LOG="$LOG" TSC_LOG="$TSC_LOG" CLAUDE_BIN="$FAKE" CHECK_MODS_TYPES_HOME="$TH4F" CHECK_MODS_TS_DIR="$TS4F" PATH=/usr/bin:/bin "$@" bash "$CHECK" "$M4F" 2>&1)"; code=$?; }
run4f env FAKE_CC_VERSION=2.1.291
printf '%s\n' "$out" | grep -q 'types came from Claude Code 2.1.291, the build the record was measured on' \
  && check "a run on the recorded Claude Code build says so" ok || check "a run on the recorded Claude Code build says so" "$out"
run4f env FAKE_CC_VERSION=2.1.300
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'illtyped-ver fails a strict type check' | grep -q 'Claude Code 2.1.300.*measured on 2.1.291' \
  && check "a type failure on another Claude Code build names both builds on the mod's line, and still fails" ok \
  || check "a type failure on another Claude Code build names both builds on the mod's line, and still fails" "exit=$code out=$out"
printf '%s\n' "$out" | grep -q 'types came from Claude Code 2.1.300, and the record .* was measured on 2.1.291' \
  && check "and the run ends naming the mismatch" ok || check "and the run ends naming the mismatch" "$out"
# A compiler that dies on the newer types is the likeliest failure of all on another build, so it
# names both builds too (review of #847).
mkmod "$M4F" crashing-ver; laid "$TH4F/mods/crashing-ver"
run4f env FAKE_CC_VERSION=2.1.300
printf '%s\n' "$out" | grep 'crashing-ver could not be type checked' | grep -q 'Claude Code 2.1.300.*measured on 2.1.291' \
  && check "a compiler that dies on another build's types names both builds" ok \
  || check "a compiler that dies on another build's types names both builds" "$out"
rm -rf "${M4F:?}/crashing-ver"
rm -f "$TS4F/claude-code-version"
run4f env FAKE_CC_VERSION=2.1.291
printf '%s\n' "$out" | grep -q 'names no Claude Code build' \
  && check "a record naming no build is said as that" ok || check "a record naming no build is said as that" "$out"
# The shipped record names a build, in the form claude --version prints it.
grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' "$ROOT/tools/typescript/claude-code-version" 2>/dev/null \
  && check "the shipped record names the Claude Code build its types were measured on" ok \
  || check "the shipped record names the Claude Code build its types were measured on" "$(cat "$ROOT/tools/typescript/claude-code-version" 2>&1)"

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
# CI is this case, and the strict type check is the part it never reaches, so it is named (#833).
printf '%s\n' "$out" | grep UNMEASURED | grep -q 'strict type check is UNMEASURED too' \
  && check "and names the strict type check as unmeasured as well" ok || check "and names the strict type check as unmeasured as well" "$out"

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
runbp(){ : > "$LOG"; out="$(STUB_LOG="$LOG" CLAUDE_BIN="${1:-$FAKE}" CHECK_MODS_BYPASS_KNOWN="$KNOWN7B" bash "$CHECK" "$M7B" 2>&1)"; code=$?; }
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
out="$(CLAUDE_BIN="$TMPROOT/no-such-claude" CHECK_MODS_BYPASS_KNOWN="$KNOWN7B" PATH=/usr/bin:/bin bash "$CHECK" "$M7B" 2>&1)"; code=$?
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
ROUTES7B=""
for ev in attribution.text 'classic.*' prompt.compose prompt.context prompt.section settings.read skill.prompt; do
  ROUTES7B="$ROUTES7B# e(\"$ev\",(n,o,t)=>t.to(o,\"append\"))
"
done
{ cat "$FAKE"; printf '%s' "$ROUTES7B"; } > "$TMPROOT/claude-same"; chmod +x "$TMPROOT/claude-same"
{ cat "$FAKE"; printf '%s' "$ROUTES7B"; printf '# e("prompt.attachment",(a,b,c)=>c.to(b,"append"))\n'; } > "$TMPROOT/claude-more"; chmod +x "$TMPROOT/claude-more"
runbp "$TMPROOT/claude-same"
[ "$code" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'routes past the user tier' && check "a build routing the listed events passes" ok \
  || check "a build routing the listed events passes" "exit=$code out=$out"
runbp "$TMPROOT/claude-more"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'not listed: prompt.attachment' && check "a build routing another event fails, naming it" ok \
  || check "a build routing another event fails, naming it" "exit=$code out=$out"
runbp "$FAKE"
printf '%s\n' "$out" | grep -q 'UNMEASURED: no security default route was found' && check "a build with no routes found is said as unmeasured" ok \
  || check "a build with no routes found is said as unmeasured" "$out"

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
  out="$(bash "$WAITS" "$M12W" 2>&1)"; code=$?
  [ "$code" -eq 1 ] && check "a noun that waits with no bound under 10 s fails the run" ok || check "a noun that waits with no bound under 10 s fails the run" "exit=$code out=$out"
  case "$out" in *"44 mods checked"*) check "and the count is stated" ok ;; *) check "and the count is stated" "$out" ;; esac
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
  for at in slow-process/hooks/register.ts:4 long-process-timeout/hooks/register.ts:5 awaited-not-deferred/hooks/register.ts:1 awaited-timer/hooks/register.ts:5; do
    printf '%s\n' "$out" | grep -F "$at" | grep -q 'process.run' \
      && check "a noun's own process.run with no timeout under 10 s is named at ${at%%/*}'s line (#802)" ok \
      || check "a noun's own process.run with no timeout under 10 s is named at ${at%%/*}'s line (#802)" "$out"
  done
  printf '%s\n' "$out" | grep -F 'model-call/hooks/register.ts:4' | grep -q 'model.complete' \
    && check "a noun's own model.complete with no timeoutMs under 10 s is named (#802)" ok || check "a noun's own model.complete with no timeoutMs under 10 s is named (#802)" "$out"
  for m in short-process process-in-hook shorthand-timeout model-timed timer-defers timer-inline-code; do
    ! printf '%s\n' "$out" | grep -q "$m/" && check "$m passes (#802)" ok || check "$m passes (#802)" "$out"
  done
  ! printf '%s\n' "$out" | grep -qF 'same-local-args/hooks/register.ts:2' \
    && check "a local helper is judged by its own calls, never a same-named one's (#895)" ok \
    || check "a local helper is judged by its own calls, never a same-named one's (#895)" "$out"
  for m in bounded commented outside-any-noun raced-short kept-unread same-local-calm out-of-scope-local param-shadows-top param-typed-return local-function-decl crlf-local unresolved-import multi-declarator same-name-variable same-name-parameter; do
    ! printf '%s\n' "$out" | grep -q "$m/" && check "$m passes" ok || check "$m passes" "$out"
  done
  # Cut down to the mods that pass, the run passes, so the failure above is theirs alone.
  for m in waits-in-map passed-to-listener called-back-later through-helper named-executor long-timer unrelated-timer on-noun-event asks-a-person lost-executor made-in-hook kept-in-variable kept-in-other-file raced-long slow-process long-process-timeout model-call same-local-waits same-local-args param-scope-ends shorthand-method awaited-not-deferred awaited-timer; do rm -rf "${M12W:?}/$m"; done
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
    echo "UNMEASURED: the noun wait checks (section 12) did not run: no TypeScript compiler that starts in $1. Install it with: npm ci --prefix tools/typescript"
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
  [ "$got" -eq 1 ] && ! grep -q '^UNMEASURED' "$TMPROOT/noun-waits-required.out" \
    && check "under CI a compiler that does not start ($ts) fails the noun wait checks, never UNMEASURED (#895)" ok \
    || check "under CI a compiler that does not start ($ts) fails the noun wait checks, never UNMEASURED (#895)" "failures=$got out=$(cat "$TMPROOT/noun-waits-required.out")"
  # Elsewhere the section is UNMEASURED, never a failure, and runs nothing. Run in this shell, never a
  # $(...) subshell, so a check it ran would move these very counters (lessons review of #896).
  before=$fail; ran=$pass
  noun_wait_section "$TMPROOT/$ts" > "$TMPROOT/noun-waits-unmeasured.out" 2>&1
  out="$(cat "$TMPROOT/noun-waits-unmeasured.out")"
  [ "$fail" -eq "$before" ] && [ "$pass" -eq "$ran" ] && printf '%s\n' "$out" | grep -q "^UNMEASURED: the noun wait checks .*npm ci --prefix tools/typescript" \
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
priv="$(grep -n -E 'from ts_source import .*\b_[A-Za-z]|ts_source\._[A-Za-z]' "$ROOT"/tools/*.sh "$ROOT"/tools/*.py "$ROOT"/tests/*.sh 2>/dev/null | grep -v "^$ROOT/tests/test-mods.sh:.*priv=")"
[ -z "$priv" ] && check "no scan imports a private helper of tools/lib/ts_source.py" ok \
  || check "no scan imports a private helper of tools/lib/ts_source.py" "$priv"
fc="$(python3 - "$ROOT/tools/lib" <<'PY'
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
# Every check this suite runs can be run directly, as its header says, so each is committed
# executable (the lessons review of #744: the noun wait check was committed 644 beside its 755
# siblings, which this suite's own `bash <check>` could never notice).
for t in "$CHECK" "$SHARED" "$DEPS" "$WAITS"; do
  [ -x "$t" ] && check "${t#"$ROOT"/} is executable" ok || check "${t#"$ROOT"/} is executable" "not executable"
done

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
