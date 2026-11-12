#!/usr/bin/env bash
# Tests for measure-hooks-path.sh, which lists every working tree under the folders it is given, says
# where core.hooksPath is set for each and to what, and asks the SHIPPING push-scope-notice.sh whether
# a push from there would be refused, for the main session and for an agent (claude-config#2098).
#
# It exists because the two measurements behind that gate (#2070, #2135) were made on the personal
# MacBook only, and the work MacBook installs its hooks with a different command, so whether the
# gate refuses anything there, and what a /dev/null hooksPath means wherever it is set, could only be
# answered by a tool that Mac can run (L177). A measuring tool that finds nothing must say so rather
# than print zero refusals (L98), so that refusal is checked first.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$DIR/measure-hooks-path.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says() { case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3': ${2:0:400}" ;; esac; }
row() { # row <output> <worktree path>: the one result line for that working tree
  printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$1 == p'
}

command -v git >/dev/null 2>&1 || { echo "test-measure-hooks-path: git is not on PATH, so nothing was verified." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "test-measure-hooks-path: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.measurehp.XXXXXXXX")" || T=""
case "${T%/}" in
  ''|/|"${HOME%/}") echo "test-measure-hooks-path: refusing to run: throwaway directory came back as '$T'." >&2; exit 2 ;;
esac
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"   # git names working trees by their real path (/var is /private/var)

# No global or system setting of the machine running the suite reaches a fixture.
: > "$T/gitconfig"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1

echo "measure hooks path: refusals first (claude-config#2098)"
out="$(bash "$M" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && check "pointed at nothing it refuses" ok || check "pointed at nothing it refuses" "exit $rc"
says "and says how to call it" "$out" "usage"

mkdir -p "$T/empty"
out="$(bash "$M" "$T/empty" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && check "a folder holding no repository is not a clean result" ok \
  || check "a folder holding no repository is not a clean result" "exit $rc"
says "and says it found none, rather than counting no refusals" "$out" "found no git repository"

out="$(bash "$M" "$T/no-such" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && check "a folder that does not exist refuses" ok || check "a folder that does not exist refuses" "exit $rc"
says "and names it" "$out" "$T/no-such"

echo "measure hooks path: every working tree, where the setting comes from, and the gate's verdicts"
R="$T/root"
mkrepo() { git init -q "$R/$1" && git -C "$R/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one; }
mkdir -p "$R"
mkrepo plain
mkrepo husky
git -C "$R/husky" config core.hooksPath .husky/_
: > "$R/husky/pnpm-lock.yaml"
mkdir -p "$R/husky/.husky/_"
printf '#!/bin/sh\nexit 0\n' > "$R/husky/.husky/_/pre-push"; chmod +x "$R/husky/.husky/_/pre-push"
# A linked worktree OUTSIDE the folder measured, which never ran the install: the Bidspoke shape,
# found through the repository's own worktree list rather than by walking the folder.
git -C "$R/husky" worktree add -q "$T/elsewhere/husky-wt" 2>/dev/null
mkrepo devnull
git -C "$R/devnull" config core.hooksPath /dev/null
mkrepo emptydir
mkdir -p "$R/emptydir/hooks"
git -C "$R/emptydir" config core.hooksPath hooks
mkdir -p "$R/deep/a/b"
git init -q "$R/deep/a/b/nested"
mkdir -p "$R/plain/node_modules/pkg"
git init -q "$R/plain/node_modules/pkg"

out="$(bash "$M" "$R" 2>"$T/err")"; rc=$?
[ "$rc" -eq 0 ] && check "a folder of repositories is measured" ok || check "a folder of repositories is measured" "exit $rc [$(head -c 300 "$T/err")]"

r="$(row "$out" "$R/plain")"
says "an unset hooksPath reads unset" "$r" $'\tunset\t'
says "and neither push is refused" "$r" $'main=pass\tagent=pass'

r="$(row "$out" "$R/husky")"
says "a hooks folder that is there reads as a folder" "$r" $'\tfolder\t'
says "and names the scope and value" "$r" $'\tlocal\t.husky/_\t'
says "and neither push is refused" "$r" $'main=pass\tagent=pass'

r="$(row "$out" "$T/elsewhere/husky-wt")"
says "a linked worktree outside the folder is found through the worktree list" "$r" "$T/elsewhere/husky-wt"
says "and its own missing folder reads missing" "$r" $'\tmissing\t'
says "and both pushes are refused, as the gate refuses them" "$r" $'main=refused\tagent=refused'

r="$(row "$out" "$R/devnull")"
says "/dev/null reads as something that is not a folder" "$r" $'\tnot a folder\t'
says "and the main session's push passes while an agent's is refused (#2135)" "$r" $'main=pass\tagent=refused'

r="$(row "$out" "$R/emptydir")"
says "an empty hooks folder is refused for an agent only" "$r" $'main=pass\tagent=refused'

r="$(row "$out" "$R/deep/a/b/nested")"
says "a repository a few folders down is found" "$r" "$R/deep/a/b/nested"
r="$(row "$out" "$R/plain/node_modules/pkg")"
[ -z "$r" ] && check "a repository inside node_modules is not a working tree anybody pushes from" ok \
  || check "a repository inside node_modules is not a working tree anybody pushes from" "listed: $r"

says "the totals count every working tree" "$out" "working trees: 6"
says "and how many set core.hooksPath" "$out" "setting core.hooksPath: 4"
says "and the main session's refusals" "$out" "main session pushes refused: 1"
says "and an agent's" "$out" "agent pushes refused: 3"
says "and every value that is not a folder, by scope, which is the /dev/null question" "$out" "not a folder: /dev/null (local) in 1"

echo "measure hooks path: a global setting is named as global"
printf '[core]\n\thooksPath = /dev/null\n' > "$T/gitconfig"
out="$(bash "$M" "$R/plain" 2>&1)"; rc=$?
r="$(row "$out" "$R/plain")"
says "a repository taking /dev/null from the global config says global" "$r" $'\tglobal\t/dev/null\t'
says "and the global value is printed at the top" "$out" "global core.hooksPath: /dev/null"
: > "$T/gitconfig"

echo "measure hooks path: a gate that errors is never read as a pass"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "$T/broken-gate.sh"
out="$(MEASURE_HOOKS_PATH_GATE="$T/broken-gate.sh" bash "$M" "$R/plain" 2>&1)"; rc=$?
r="$(row "$out" "$R/plain")"
says "an exit other than 0 or 2 reads as an error with its code" "$r" "main=error 1"
[ "$rc" -ne 0 ] && check "and the run exits non zero" ok || check "and the run exits non zero" "exit $rc"

echo "measure hooks path: it asks the shipping gate, never a copy of its rules (L107)"
grep -q 'push-scope-notice.sh' "$M" && check "it invokes the real gate" ok || check "it invokes the real gate" "no reference to it"
[ -f "$DIR/push-scope-notice.sh" ] && check "and that gate is there beside it" ok || check "and that gate is there beside it" "missing"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
