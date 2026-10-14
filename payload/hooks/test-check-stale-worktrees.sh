#!/usr/bin/env bash
# Tests for check-stale-worktrees.sh.
#
# A fake gh on PATH stands in for GitHub, so these cannot reach the network or read a real
# repository (L2). The fake records every call, which is what lets the test assert that the merged
# PR list is read ONCE for the whole run rather than once per worktree: a hook that runs on every
# prompt cannot pay a network call per worktree, and a count of calls is the only thing that can
# say which it does (L3).
#
# Every git call carries an identity, because a machine may have none configured and git then
# REFUSES to commit rather than defaulting, which fails on a fresh runner and nowhere else (L435).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/check-stale-worktrees.sh"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ # check <what> <expected substring> <actual>
  if [[ "$3" == *"$2"* ]]; then ok; else
    bad "$1"; echo "  expected to contain: $2"; echo "  actual: $3"
  fi
}
check_not(){ # check_not <what> <forbidden substring> <actual>
  if [[ "$3" != *"$2"* ]]; then ok; else bad "$1 (should not contain '$2')"; echo "  actual: $3"; fi
}
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi }

G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# --- the fake gh -----------------------------------------------------------
# It answers the merged pull request list, which is the one question the check asks.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ -n "${GH_FAIL:-}" ]; then echo "gh: simulated failure" >&2; exit 1; fi
cat "$GH_MERGED"
STUB
chmod +x "$TMP/bin/gh"
export GH_CALLS="$TMP/calls.log"
export GH_MERGED="$TMP/merged.tsv"
: >"$GH_MERGED"

OUT=""; RC=0
run(){ : >"$GH_CALLS"; OUT="$(STALE_WT_GH="$TMP/bin/gh" bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }

# --- a directory that is not a repository ----------------------------------
# Refusing, rather than reporting nothing to remove: the two are indistinguishable to a reader and
# only one of them is true (L98).
mkdir -p "$TMP/notarepo"
run "$TMP/notarepo"
check_eq "a directory outside any repository exits 2" 2 "$RC"
check "and says why it could not judge" "not inside a git repository" "$OUT"

# --- a repository with no agent worktrees ----------------------------------
# The ordinary case in every project but this one, and a real answer rather than a refusal.
REPO="$TMP/repo"; mkdir -p "$REPO"; G -C "$REPO" init -q -b main
printf 'x\n' >"$REPO/f.txt"; G -C "$REPO" add f.txt; G -C "$REPO" commit -qm base
run "$REPO"
check_eq "a repository with no worktree directory exits 0" 0 "$RC"
check_eq "and says nothing at all" "" "$OUT"
check_eq "and asks GitHub nothing, so it costs nothing in the common case" "" "$(cat "$GH_CALLS")"

# --- every kind of worktree, in one repository -----------------------------
# All together, because what has to hold is that each is judged on its OWN facts: a run holding
# only the landed one could not show that a dirty, busy or newer one is left alone.
WT="$REPO/.claude/worktrees"; mkdir -p "$WT"
REPO_REAL="$(cd "$REPO" && pwd -P)"
merged(){ printf '%s\t%s\t%s\n' "$1" "$(G -C "$2" rev-parse "${3:-HEAD}")" "$4" >>"$GH_MERGED"; }
add(){ G -C "$REPO" worktree add -q -b "$1" "$WT/$2" >/dev/null 2>&1; }
# Files written by the fixture are seconds old, and a worktree changed recently is kept, so every
# one is aged except the one whose recency is the point (the same check, with nothing faked).
age(){ find "$WT/$1" -exec touch -t 202601010000 {} + 2>/dev/null; }

add fix/415-landed agent-landed; merged fix/415-landed "$WT/agent-landed" HEAD 415
# Pushed to again after this worktree's last commit, from somewhere else: the PR's last commit is
# one this worktree never had, and every commit it does have was in the PR.
add fix/416-contained agent-contained
G -C "$WT/agent-contained" commit -q --allow-empty -m "pushed later from elsewhere"
merged fix/416-contained "$WT/agent-contained" HEAD 416
G -C "$WT/agent-contained" reset -q --hard HEAD~1
add fix/417-newer agent-newer; merged fix/417-newer "$WT/agent-newer" HEAD 417
G -C "$WT/agent-newer" commit -q --allow-empty -m "after the merge"
add fix/9999-open agent-open
add fix/382-dirty agent-dirty; merged fix/382-dirty "$WT/agent-dirty" HEAD 382
add fix/418-recent agent-recent; merged fix/418-recent "$WT/agent-recent" HEAD 418
add fix/419-busy agent-busy; merged fix/419-busy "$WT/agent-busy" HEAD 419
add fix/420-gone agent-gone
printf 'fix/420-gone\t1111111111111111111111111111111111111111\t420\n' >>"$GH_MERGED"
G -C "$REPO" worktree add -q --detach "$WT/agent-detached" >/dev/null 2>&1
for d in landed contained newer open dirty busy gone detached; do age "agent-$d"; done
# The dirty one's PR merged too, so this pins the ORDER of the rules: uncommitted work has to win,
# or the one worktree somebody is standing in is the one removed.
printf 'work in progress\n' >"$WT/agent-dirty/wip.txt"
(cd "$WT/agent-busy" && exec sleep 120) &
BUSY=$!
trap 'kill "$BUSY" 2>/dev/null; rm -rf "$TMP"' EXIT

# Whether anything running can be seen inside a folder depends on lsof or /proc, which this suite
# cannot install. Without either, the busy case is UNMEASURED rather than passed (L411).
CAN_SEE_USE=0
{ command -v lsof >/dev/null 2>&1 || [ -d /proc/self/cwd ]; } && CAN_SEE_USE=1

# REPORT, the default: it names what has landed and removes nothing.
run "$REPO"
check_eq "a repository holding landed worktrees exits 1" 1 "$RC"
check "a worktree at its merged PR's last commit is called stale, naming the PR" "STALE agent-landed [fix/415-landed]: PR #415 merged" "$OUT"
check "and carries the exact command that removes it" \
  "git -C $REPO_REAL worktree remove $REPO_REAL/.claude/worktrees/agent-landed" "$OUT"
check "a worktree its PR went past is stale too, every commit of it having merged" "STALE agent-contained" "$OUT"
check "a worktree with commits its PR never held is kept" "keeping agent-newer [fix/417-newer]: it has commits PR #417 never held" "$OUT"
check "a worktree with no merged PR is kept" "keeping agent-open [fix/9999-open]: no merged PR has this branch" "$OUT"
check "a worktree with uncommitted work is kept although its PR merged" "keeping agent-dirty" "$OUT"
check "and says that is why, in terms of what is in it" "uncommitted change(s)" "$OUT"
check "a worktree changed in the last six hours is kept although its PR merged" "keeping agent-recent [fix/418-recent]: something in it changed in the last 360 minutes" "$OUT"
check "a PR merged at a commit this repository lacks is kept, as unconfirmed" "keeping agent-gone [fix/420-gone]: PR #420 merged at a commit this repository does not have" "$OUT"
check "a worktree on no branch is kept" "keeping agent-detached" "$OUT"
check "the summary counts the landed against the total" "2 of 9 agent worktree(s)" "$OUT"
if [ "$CAN_SEE_USE" -eq 1 ]; then
  check "a worktree something is running in is kept although its PR merged" "keeping agent-busy [fix/419-busy]: a running process is working in it" "$OUT"
else
  echo "UNMEASURED: neither lsof nor /proc here, so whether a busy worktree is seen cannot be tested"
fi
check_eq "the merged PRs are read once for the whole run, not once per worktree" \
  1 "$(grep -c 'pr list' "$GH_CALLS" || true)"
check_eq "it removes nothing without --remove, including the ones it called stale" 9 "$(ls "$WT" | wc -l | tr -d ' ')"

# REMOVE, with no time left: nothing is removed, and it says the rest wait for the next run.
: >"$GH_CALLS"
OUT="$(STALE_WT_GH="$TMP/bin/gh" STALE_WT_BUDGET_SECS=0 bash "$SCRIPT" --remove "$REPO" 2>&1)"; RC=$?
check_eq "a run out of time removes nothing" 9 "$(ls "$WT" | wc -l | tr -d ' ')"
check "and says the landed ones are left for the next run" "2 landed worktree(s) left for the next run" "$OUT"

# REMOVE: the two landed ones go, every other one stays, and each branch is kept.
run --remove "$REPO"
check_eq "a run that removed worktrees exits 1, so what it did is said" 1 "$RC"
check "the landed worktree is removed, and says why" "removed agent-landed [fix/415-landed]: PR #415 merged" "$OUT"
check "the one its PR went past is removed" "removed agent-contained" "$OUT"
check_eq "its folder is gone" "no" "$([ -e "$WT/agent-landed" ] && echo yes || echo no)"
check_eq "and git no longer lists it" 0 "$(git -C "$REPO" worktree list --porcelain | grep -c 'agent-landed' || true)"
check_eq "its branch is kept, so its commits can be had back" 0 "$(G -C "$REPO" rev-parse -q --verify fix/415-landed >/dev/null; echo $?)"
remaining=0
for d in newer open dirty recent busy gone detached; do [ -d "$WT/agent-$d" ] && remaining=$((remaining + 1)); done
check_eq "every worktree it kept is still there" 7 "$remaining"
check_eq "and the dirty one still holds its work" "work in progress" "$(cat "$WT/agent-dirty/wip.txt")"
check "the summary says how many were removed" "removed 2 of 9 agent worktree(s)" "$OUT"

# --- a number that is a PREFIX of a merged branch is not merged -------------
add fix/41 agent-prefix; age agent-prefix
run "$REPO"
check "a branch that is only a prefix of a merged one is kept" "keeping agent-prefix [fix/41]: no merged PR has this branch" "$OUT"
G -C "$REPO" worktree remove --force "$WT/agent-prefix" >/dev/null 2>&1

# --- GitHub unreadable is not a clean tree ---------------------------------
# The same repository, and the one thing changed is that the answer cannot be had. Reporting them
# as fine here, or removing anything, is the failure this exit code exists to prevent (L98, L42).
add fix/421-later agent-later; merged fix/421-later "$WT/agent-later" HEAD 421; age agent-later
GH_FAIL=1 run --remove "$REPO"
check_eq "an unreadable merged PR list exits 2" 2 "$RC"
check "and says how many it therefore left unjudged" "8 worktree(s)" "$OUT"
check_eq "and removes nothing" "yes" "$([ -d "$WT/agent-later" ] && echo yes || echo no)"

# --- nothing merged yet ----------------------------------------------------
: >"$GH_MERGED"
run --remove "$REPO"
check_eq "a repo that has merged nothing exits 0" 0 "$RC"
check_not "and removes nothing" "removed" "$OUT"
check "while still saying what it kept and why" "keeping agent-later [fix/421-later]: no merged PR has this branch" "$OUT"

kill "$BUSY" 2>/dev/null
echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
