#!/usr/bin/env bash
# Tests for check-stale-worktrees.sh.
#
# A fake gh on PATH stands in for GitHub, so these cannot reach the network or read a real
# repository (L2). The fake records every call, which is what lets the test assert that the closed
# issue list is read ONCE for the whole run rather than once per worktree: a hook that runs on
# every prompt cannot pay a network call per worktree, and a count of calls is the only thing that
# can say which it does (L3).
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
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ -n "${GH_FAIL:-}" ]; then echo "gh: simulated failure" >&2; exit 1; fi
cat "$GH_CLOSED"
STUB
chmod +x "$TMP/bin/gh"
export GH_CALLS="$TMP/calls.log"
export GH_CLOSED="$TMP/closed.txt"
printf '382\n399\n415\n' >"$GH_CLOSED"

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

# --- the four kinds of worktree, in one repository -------------------------
# All four together, because what has to hold is that each is judged on its OWN facts: a run
# holding only the stale one could not show that a dirty or open one is left alone.
mkdir -p "$REPO/.claude/worktrees"
G -C "$REPO" worktree add -q -b "fix/415-landed" "$REPO/.claude/worktrees/agent-landed" >/dev/null 2>&1
G -C "$REPO" worktree add -q -b "fix/9999-open" "$REPO/.claude/worktrees/agent-open" >/dev/null 2>&1
G -C "$REPO" worktree add -q -b "fix/382-dirty" "$REPO/.claude/worktrees/agent-dirty" >/dev/null 2>&1
G -C "$REPO" worktree add -q -b "tidy-up-no-number" "$REPO/.claude/worktrees/agent-nonum" >/dev/null 2>&1
# The dirty one names a CLOSED issue too, so this pins the ORDER of the two rules: uncommitted work
# has to win, or the one worktree somebody is standing in is the one offered for removal.
printf 'work in progress\n' >"$REPO/.claude/worktrees/agent-dirty/wip.txt"

run "$REPO"
check_eq "a repository holding a landed worktree exits 1" 1 "$RC"
check "the landed one is called stale, naming its issue" "STALE agent-landed" "$OUT"
# The path git reports, not the one the fixture built: on macOS /var is a symlink to /private/var
# and `rev-parse --show-toplevel` resolves it, so comparing against the unresolved path fails on a
# Mac and passes on the Linux runner, which is the pair that is hardest to read (L504).
REPO_REAL="$(cd "$REPO" && pwd -P)"
check "and carries the exact command that removes it" \
  "git -C $REPO_REAL worktree remove $REPO_REAL/.claude/worktrees/agent-landed" "$OUT"
check "a worktree whose issue is still open is kept" "keeping agent-open" "$OUT"
check "and says which issue it is waiting on" "issue #9999 is not closed" "$OUT"
check "a worktree with uncommitted work is kept even though its issue is closed" \
  "keeping agent-dirty" "$OUT"
check "and says that is why, in terms of what is in it" "uncommitted change(s)" "$OUT"
check_not "and it is never also offered for removal" "STALE agent-dirty" "$OUT"
check "a branch naming no issue is kept" "keeping agent-nonum" "$OUT"
check "and says the branch is what it could not read it from" "names no issue" "$OUT"
check "the summary counts the stale against the total" "1 of 4 agent worktree(s)" "$OUT"

# ONE call for the whole run. A hook that runs on every prompt cannot pay a network call per
# worktree, and nothing but a count of the calls can tell one from the other.
check_eq "the closed issues are read once for the whole run, not once per worktree" \
  1 "$(grep -c 'issue list' "$GH_CALLS" || true)"

# It REPORTS. Asserted as the worktrees still being there afterwards rather than as the absence of
# a remove command in the source, because what matters is the state it leaves (L3).
still=0
for d in landed open dirty nonum; do [ -d "$REPO/.claude/worktrees/agent-$d" ] && still=$((still + 1)); done
check_eq "it removes nothing, including the one it called stale" 4 "$still"

# --- a number that is a PREFIX of a closed one is not closed ---------------
# The closed list is matched line by line, and the cheap ways of doing that (a substring search, a
# grep with no anchors) would read issue 41 as closed because 415 is. Nothing but a fixture holding
# both can tell the two apart, and the claim otherwise lives in a comment, which enforces nothing
# (L407).
G -C "$REPO" worktree add -q -b "fix/41-prefix" "$REPO/.claude/worktrees/agent-prefix" >/dev/null 2>&1
run "$REPO"
check "an issue number that is only a prefix of a closed one is kept" "keeping agent-prefix" "$OUT"
check "and says that issue is not closed" "issue #41 is not closed" "$OUT"
check_not "and is never called stale" "STALE agent-prefix" "$OUT"
G -C "$REPO" worktree remove --force "$REPO/.claude/worktrees/agent-prefix" >/dev/null 2>&1

# --- GitHub unreadable is not a clean tree ---------------------------------
# The same repository, the same four worktrees, and the one thing changed is that the answer cannot
# be had. Reporting them as fine here is the failure this exit code exists to prevent (L98, L42).
GH_FAIL=1 run "$REPO"
check_eq "an unreadable closed issue list exits 2" 2 "$RC"
check "and says how many it therefore left unjudged" "4 worktree(s)" "$OUT"
check_not "and never calls any of them stale" "STALE" "$OUT"
unset GH_FAIL

# --- nothing closed yet ----------------------------------------------------
# An empty list is a legitimate answer from a repo that has closed nothing, and it must read as
# "none of these has landed" rather than as a failure.
: >"$GH_CLOSED"
run "$REPO"
check_eq "a repo that has closed nothing exits 0" 0 "$RC"
check_not "and calls nothing stale" "STALE" "$OUT"
check "while still saying what it kept and why" "keeping agent-landed" "$OUT"
printf '382\n399\n415\n' >"$GH_CLOSED"

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
