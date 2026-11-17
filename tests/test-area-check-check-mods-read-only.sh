#!/bin/bash
# The area check lets `bash tools/check-mods.sh <mods folder>` run without judging the folder, by name
# (payload/mods/area-check/hooks/named.ts CHECK_MODS, claude-config#3022, signed off by Dan,
# 2026-11-16), because the script's own text cannot be read to say it only reads that folder. That is
# a claim about the script and the libraries it sources, so this suite holds it there, against the
# real ones (L96, L58):
#   - CHECK_MODS.texts is the script and exactly the files it and its libraries source, so a library
#     added to the script, or one the list names that nothing sources, turns red here.
#   - The real script, run from a throwaway checkout over a fixture mods folder there, leaves the
#     checkout as it found it. With a compiler named, nothing in the checkout changes at all: every
#     file byte for byte, no new file, an ignored one included. With none named it installs the
#     pinned compiler as a new worktree's first run does, and then every file git tracks or would
#     track is still byte for byte the same, git status is the same, and everything new is under the
#     ignored tools/typescript/node_modules. Its copies go under the temporary folder and its failure
#     logs under the cache folder, both seen to be written, so the run did its work (L98, L288).
#   - Each of those checks is seen to fail (L1): a copy of the script changed to append to a tracked
#     file, to add a new file, or to plant an ignored one is caught.
#   - The rule itself, run on mod-kit's REAL reader of a command and real git
#     (tests/area-check-named-rule.mjs, shared with the suite of the other script let through by
#     name, #3082), lets through only that
#     script at its path from the root of a checkout of its repository, handed one folder, in a
#     command that gives it no setting and runs the script once, with nothing but a change of folder
#     before it and readers its output is piped into after it, with its texts
#     as the checkout left the default branch with them. Since #3093 an equals sign holds the run
#     only where it may set a value for the script, so one in a reader of its output does not, and
#     a run behind a runner (env, sudo, timeout, a shell's own script) or after a change of folder
#     that is not one folder written from /, ./, ../ or ~ is judged.
#     Every other shape, a changed text, a copy elsewhere, another repository, and everything chained
#     with the run, the other script let through by name included, is still judged.
# What it cannot prove, said so it is never claimed (L460): what the real claude command, the real
# compiler and each mod's own tests write when the script runs them. Here they are stand ins, since a
# suite never starts a real Claude or asks the registry. The area check does not judge them typed
# directly either (`claude plugin test <mod>`, tests/test-area-check-shell-reader.sh's blind spot).
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
finish(){
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so the area check's list could not be read"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# The temporary folder, the listings of a checkout, and the readers of the list and of the rule, which
# every suite proving a script let through by name shares (#3082).
. "$DIR/area-check-named-reader.sh" || {
  echo "FAIL: $(basename "$0"): tests/area-check-named-reader.sh is missing, so nothing was run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
named_tmp test-area-check-check-mods

# ---- The list, held to the texts ----
named_texts CHECK_MODS || finish
lines="$(named_fact LINES)"
[ "$SCRIPT" = tools/check-mods.sh ] && [ -f "$ROOT/$SCRIPT" ] && check "the named script is tools/check-mods.sh, and it is there" ok \
  || check "the named script is tools/check-mods.sh, and it is there" "named: $SCRIPT"
# Five source lines today: three in the script, one in each of two libraries. Fewer than that and the
# reading of them has gone blind, which would pass every check below it (L98).
[ "${lines:-0}" -ge 5 ] && check "the lines that source a file are found" ok || check "the lines that source a file are found" "found ${lines:-none}: $listed"
# It runs no program file: its perl is given on the command line, so a run found here is a text the
# list would need. The reading knows quoting (#3134), so a message quoting a run counts nothing.
[ "$(named_fact RUNS)" = 0 ] && check "and it runs no program file the list would have to name" ok || check "and it runs no program file the list would have to name" "$(named_fact RAN | paste -sd';' -)"
# Seven commands are named by a variable these texts never set, so each runs a program the environment
# or PATH names, never a text of the checkout: the compiler ($tsc, from TSC_BIN or PATH), claude three
# times ($bin, from CLAUDE_BIN or PATH), pinned-compiler.sh's two test hooks, and load-average.sh's
# $cmd (its argument or LOAD_AVERAGE_CMD). One more is a command nobody has looked at, so the count is
# exact (#3134).
byvalue="$(named_fact BYVALUE)"
[ "$(printf '%s\n' "$byvalue" | grep -c .)" = 7 ] && check "the commands named by a value no text sets are the seven known" ok \
  || check "the commands named by a value no text sets are the seven known" "$(printf '%s\n' "$byvalue" | paste -sd';' -)"
problems="$(named_fact PROBLEM)"
[ -z "$problems" ] && check "CHECK_MODS.texts is the script and exactly the files it and its libraries source" ok \
  || check "CHECK_MODS.texts is the script and exactly the files it and its libraries source" "$problems"

# ---- The real script over a throwaway checkout ----
mkmod(){   # $1 = mods dir  $2 = name
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks" "$1/$2/tests"
  printf '{ "name": "%s", "version": "0.1.0", "description": "x" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
  printf '{ "modules": ["./register.ts"] }\n' > "$1/$2/hooks/hooks.json"
  printf 'export const register = () => {}\n' > "$1/$2/hooks/register.ts"
  printf 'export {}\n' > "$1/$2/tests/a.test.ts"
  printf '{ "extends": "./.claude-plugin/types/tsconfig.json" }\n' > "$1/$2/tsconfig.json"
}
# The pin, the pinned types and the record of known type errors the script reads: every file under
# tools/typescript that git tracks or would track, so never the ignored node_modules there.
DATA="$(bash "$ROOT/payload/hooks/lib/repo-files.sh" "$ROOT" tools/typescript)" && [ -n "$DATA" ] \
  && check "the data the script reads under tools/typescript is listed" ok || check "the data the script reads under tools/typescript is listed" "repo-files.sh gave: $DATA"
# A checkout holding the real script and libraries at their paths, the data they read, the real
# ignore rules, and four mods: one fine, one leaning on it, one validate refuses, one whose tests fail.
# $2, when given, is a sed program changing the copy of the script, for the controls.
make_repo(){   # $1 = folder  $2 = sed program for the script, or empty
  local repo="$1" t f
  mkdir -p "$repo"
  for t in $TEXTS tools/sec-default-bypassed-hooks.tsv .gitignore $DATA; do
    mkdir -p "$repo/$(dirname "$t")"
    cp "$ROOT/$t" "$repo/$t" || return 1
  done
  if [ -n "${2:-}" ]; then
    sed "$2" "$repo/$SCRIPT" > "$repo/$SCRIPT.changed" && mv "$repo/$SCRIPT.changed" "$repo/$SCRIPT" || return 1
    cmp -s "$ROOT/$SCRIPT" "$repo/$SCRIPT" && return 1
  fi
  for f in fine leaning broken-mod redtest; do mkmod "$repo/payload/mods" "$f"; done
  printf '{ "name": "leaning", "version": "0.1.0", "description": "x", "dependencies": ["fine"] }\n' > "$repo/payload/mods/leaning/.claude-plugin/plugin.json"
  printf '{ "name": "fine", "version": "0.1.0", "description": "x", "types": "./types/index.d.ts" }\n' > "$repo/payload/mods/fine/.claude-plugin/plugin.json"
  mkdir -p "$repo/payload/mods/fine/types"; printf 'export type F = 1\n' > "$repo/payload/mods/fine/types/index.d.ts"
  git -C "$repo" init -q -b main >/dev/null 2>&1 || return 1
  git -C "$repo" add -A >/dev/null 2>&1 || return 1
  git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q -m fixture >/dev/null 2>&1 || return 1
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
}

CLAUDE="$TMP/claude"; CALLS="$TMP/claude-calls"
cat > "$CLAUDE" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
[ "$1" = --version ] && { echo "2.1.291 (Claude Code)"; exit 0; }
case "$1 $2" in
  "plugin validate") case "$3" in *broken*) printf '  hooks: bad event\n\nValidation failed\n'; exit 1 ;; esac; echo 'Validation passed' ;;
  "plugin test") case "$3" in *redtest*) printf ' 0 pass\n 1 fail\n'; exit 1 ;; esac; printf ' 1 pass\n 0 fail\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$CLAUDE"
TSC="$TMP/tsc"; TSC_CALLS="$TMP/tsc-calls"
printf '#!/bin/bash\necho "$*" >> "%s"\nexit 0\n' "$TSC_CALLS" > "$TSC"; chmod +x "$TSC"
# npm, standing in: it lays the stand in compiler as the package's tsc, as an install would.
NPM="$TMP/npm"
cat > "$NPM" <<STUB
#!/bin/bash
prefix=""; prev=""
for a in "\$@"; do [ "\$prev" = --prefix ] && prefix="\$a"; prev="\$a"; done
mkdir -p "\$prefix/node_modules/.bin" "\$prefix/node_modules/typescript/bin"
cp "$TSC" "\$prefix/node_modules/typescript/bin/tsc"
ln -s ../typescript/bin/tsc "\$prefix/node_modules/.bin/tsc"
STUB
chmod +x "$NPM"
mkdir -p "$TMP/home" "$TMP/tmp"
KEPT="$TMP/home/.cache/claude-config/mod-test-failures"
# The script as the area check lets it through: `bash tools/check-mods.sh payload/mods` from the root
# of the checkout. Only the stand ins, and a home and temporary folder of its own, are set around it.
run_check(){   # $1 = checkout  rest = more of the environment -> sets out and code
  local repo="$1"; shift
  : > "$CALLS"; : > "$TSC_CALLS"
  out="$(cd "$repo" && env -u CHECK_MODS_FAILURE_OUTPUT -u CHECK_MODS_TS_DIR -u CHECK_MODS_BYPASS_KNOWN -u TSC_BIN -u XDG_CACHE_HOME \
    HOME="$TMP/home" TMPDIR="$TMP/tmp" STUB_LOG="$CALLS" CLAUDE_BIN="$CLAUDE" PINNED_TS_OFFLINE=1 "$@" bash tools/check-mods.sh payload/mods 2>&1)"; code=$?
}

REPO="$TMP/repo"
make_repo "$REPO" "" && [ -z "$(status "$REPO")" ] && check "the throwaway checkout is made, clean, with the real script in it" ok \
  || check "the throwaway checkout is made, clean, with the real script in it" "status: $(status "$REPO")"
cmp -s "$ROOT/$SCRIPT" "$REPO/$SCRIPT" && check "and its script is the real one, byte for byte" ok || check "and its script is the real one, byte for byte" "the copy differs"

# 1. A compiler named: nothing in the checkout changes at all.
whole_before="$(whole "$REPO")"; status_before="$(status "$REPO")"
run_check "$REPO" TSC_BIN="$TSC"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'broken-mod' | grep -q 'bad event' && printf '%s\n' "$out" | grep -q 'redtest' \
  && check "the run did its work: it failed the two mods that fail, by name" ok \
  || check "the run did its work: it failed the two mods that fail, by name" "exit=$code out=$out"
[ "$(grep -c "^plugin validate payload/mods/" "$CALLS")" -eq 4 ] && check "it asked claude about each of the four mods in the checkout" ok \
  || check "it asked claude about each of the four mods in the checkout" "$(cat "$CALLS")"
[ "$(grep -c -- "^-p $TMP/tmp/check-mods\.[A-Za-z0-9]*/" "$TSC_CALLS")" -eq 4 ] && check "it type checked each in a copy under the temporary folder, outside the checkout" ok \
  || check "it type checked each in a copy under the temporary folder, outside the checkout" "$(cat "$TSC_CALLS")"
[ -n "$(ls -A "$KEPT" 2>/dev/null)" ] && check "it kept the failed mods' output under the cache folder, outside the checkout" ok \
  || check "it kept the failed mods' output under the cache folder, outside the checkout" "nothing under $KEPT; out=$out"
whole_after="$(whole "$REPO")"
[ "$whole_after" = "$whole_before" ] && check "with a compiler named, every path in the checkout is byte for byte as it was, and none is new" ok \
  || check "with a compiler named, every path in the checkout is byte for byte as it was, and none is new" "$(changed "$whole_before" "$whole_after")"
[ "$(status "$REPO")" = "$status_before" ] && check "and git status is as it was" ok || check "and git status is as it was" "now: $(status "$REPO")"

# 2. No compiler named, as in a new worktree: the pinned one is installed, into ignored folders only.
tracked_before="$(tracked "$REPO")"
run_check "$REPO" PINNED_TS_NPM="$NPM"
printf '%s\n' "$out" | grep -q 'pinned TypeScript compiler was installed' && [ -x "$REPO/tools/typescript/node_modules/.bin/tsc" ] \
  && check "with no compiler named, the run installs the pinned one into the checkout's tools/typescript/node_modules" ok \
  || check "with no compiler named, the run installs the pinned one into the checkout's tools/typescript/node_modules" "exit=$code out=$out"
[ "$(grep -c -- "^-p $TMP/tmp/check-mods\.[A-Za-z0-9]*/" "$TSC_CALLS")" -eq 4 ] && check "and type checks each mod with it" ok || check "and type checks each mod with it" "$(cat "$TSC_CALLS")"
tracked_after="$(tracked "$REPO")"
[ "$tracked_after" = "$tracked_before" ] && check "every file git tracks or would track is byte for byte as it was, and none is new" ok \
  || check "every file git tracks or would track is byte for byte as it was, and none is new" "$(changed "$tracked_before" "$tracked_after")"
[ "$(status "$REPO")" = "$status_before" ] && check "git status is as it was" ok || check "git status is as it was" "now: $(status "$REPO")"
whole_now="$(whole "$REPO")"
installed="$(differing "$whole_before" "$whole_now" | grep -c '^> [^ ]* \./tools/typescript/node_modules\(/\| \|$\)')"
[ "$installed" -ge 2 ] && check "the listing sees what the install put in the checkout" ok || check "the listing sees what the install put in the checkout" "$installed new paths under tools/typescript/node_modules"
new="$(differing "$whole_before" "$whole_now" | grep -v '^> [^ ]* \./tools/typescript/node_modules\(/\| \|$\)' | sed -n '1,6p' | paste -sd';' -)"
[ -z "$new" ] && check "and everything new in the checkout is under the ignored tools/typescript/node_modules" ok \
  || check "and everything new in the checkout is under the ignored tools/typescript/node_modules" "$new"
git -C "$REPO" check-ignore -q tools/typescript/node_modules && check "which the repository's own ignore rules cover" ok \
  || check "which the repository's own ignore rules cover" "tools/typescript/node_modules is not ignored in the checkout"

# 3. The controls (L1): a script that writes into the checkout is caught by each check above.
control(){   # $1 = name  $2 = sed program  $3 = whole | tracked  $4 = what the difference must name
  local repo="$TMP/control-$1" before after seen
  make_repo "$repo" "$2" || { check "control $1: a changed copy of the script is made" "the script did not change, or the checkout could not be made"; return; }
  if [ "$3" = whole ]; then before="$(whole "$repo")"; else before="$(tracked "$repo")"; fi
  run_check "$repo" TSC_BIN="$TSC"
  if [ "$3" = whole ]; then after="$(whole "$repo")"; else after="$(tracked "$repo")"; fi
  seen="$(changed "$before" "$after")"
  case "$seen" in *"$4"*) check "control $1 is caught, naming $4" ok ;; *) check "control $1 is caught, naming $4" "the listing showed: ${seen:-no difference}; out=$out" ;; esac
}
AFTER_DIR='/^dir="\${dir%\/}"$/a\'
control "appending to a tracked file" "$AFTER_DIR
printf '// x\\\\n' >> \"\$dir/fine/hooks/register.ts\"
" tracked "payload/mods/fine/hooks/register.ts"
[ -n "$(status "$TMP/control-appending to a tracked file")" ] && check "and git status shows it" ok || check "and git status shows it" "git status is empty"
control "adding a new file" "$AFTER_DIR
: > \"\$dir/fine/hooks/new.ts\"
" tracked "payload/mods/fine/hooks/new.ts"
[ -n "$(status "$TMP/control-adding a new file")" ] && check "and git status shows it" ok || check "and git status shows it" "git status is empty"
control "planting an ignored file" "$AFTER_DIR
mkdir -p tools/typescript/node_modules; : > tools/typescript/node_modules/planted
" whole "tools/typescript/node_modules/planted"

# ---- The rule, on the real reader and real git ----
# How many checks must run is set here, not measured: 56 of the run's shape and its text (31 before
# #3093, 19 of settings, runners and changes of folder it added, one of a reader that says less
# than the rule asks, two of a change of folder that leads nowhere, and three of one written with
# `..`), one for each of the four libraries, and one for the other script let through by name.
named_rule CHECK_MODS "$REPO" payload/mods/fine/hooks/register.ts 61

finish
