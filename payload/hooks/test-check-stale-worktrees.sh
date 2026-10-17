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

# What a worktree costs to inspect is paid only by one that could be removed (#1247). Asking git
# for its status walks the whole tree, so a worktree whose PR has not landed is settled by that
# alone and never asked. Counted through a git on PATH that logs each call, never timed (L224):
# the five whose PR landed are asked, and the four that did not (newer, open, gone, detached) are not.
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/shim"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$GIT_LOG"\nexec "%s" "$@"\n' "$REAL_GIT" >"$TMP/shim/git"
chmod +x "$TMP/shim/git"
export GIT_LOG="$TMP/git.log"; : >"$GIT_LOG"
OUT="$(PATH="$TMP/shim:$PATH" STALE_WT_GH="$TMP/bin/gh" bash "$SCRIPT" "$REPO" 2>&1)"
check "the shimmed run still judges every worktree" "2 of 9 agent worktree(s)" "$OUT"
check_eq "only the worktrees whose PR landed are asked for their status" 5 "$(grep -c 'status --porcelain' "$GIT_LOG" || true)"

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
MARKS="$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd -P)/claude-worktree-removing"
check_eq "a removal that finished leaves no progress marker behind" "" "$(ls "$MARKS" 2>/dev/null)"

# --- a removal cut off part way (L617) --------------------------------------
# A `git worktree remove` killed part way leaves a part deleted folder that git still lists, and
# what is left reads as uncommitted DELETIONS, so without a marker every later run keeps it for ever
# as a worktree somebody is working in. Measured 2026-10-16: killed 80ms in, 2412 of 3000 files were
# left and git status showed 588 " D" lines and nothing else. The marker is the check's own, written
# before each removal and cleared after it, so this fixture writes it the way the check does.
cut_off(){ # cut_off <name> <branch> <PR>: a landed worktree whose removal stopped part way
  add "$2" "$1"
  printf 'a\n' >"$WT/$1/a.txt"; printf 'b\n' >"$WT/$1/b.txt"
  G -C "$WT/$1" add a.txt b.txt; G -C "$WT/$1" commit -qm files
  merged "$2" "$WT/$1" HEAD "$3"
  mkdir -p "$MARKS"; printf '%s\n' "$REPO_REAL/.claude/worktrees/$1" >"$MARKS/$1"
  rm -f "$WT/$1/a.txt"
  age "$1"
}
cut_off agent-cut fix/500-cut 500
cut_off agent-cut-changed fix/501-cut 501
printf 'somebody wrote this since\n' >"$WT/agent-cut-changed/b.txt"
age agent-cut-changed
# A marker for a worktree git no longer lists is a removal that finished after all.
printf '%s\n' "$REPO_REAL/.claude/worktrees/agent-long-gone" >"$MARKS/agent-long-gone"

run "$REPO"
check "report mode names a removal that was cut off, with the command that finishes it" \
  "CUT OFF agent-cut [fix/500-cut]" "$OUT"
check_eq "and finishes nothing" yes "$([ -d "$WT/agent-cut" ] && echo yes || echo no)"
run --remove "$REPO"
check "a removal cut off with nothing but deletions in it is finished" "finished removing agent-cut [fix/500-cut]" "$OUT"
check_eq "its folder is gone" no "$([ -d "$WT/agent-cut" ] && echo yes || echo no)"
check_eq "and so is its marker" no "$([ -e "$MARKS/agent-cut" ] && echo yes || echo no)"
check_not "it is not also kept as holding uncommitted changes" "keeping agent-cut [" "$OUT"
check "one changed since the cut is not finished, and says so loudly" \
  "keeping agent-cut-changed [fix/501-cut]: an earlier removal of it was cut off part way, and something in it has changed since" "$OUT"
check_eq "its folder stays" yes "$([ -d "$WT/agent-cut-changed" ] && echo yes || echo no)"
check_eq "with the change in it" "somebody wrote this since" "$(cat "$WT/agent-cut-changed/b.txt")"
check_eq "a marker for a worktree git no longer lists is cleared" no "$([ -e "$MARKS/agent-long-gone" ] && echo yes || echo no)"
G -C "$REPO" worktree remove --force "$WT/agent-cut-changed" >/dev/null 2>&1; rm -f "$MARKS/agent-cut-changed"

# --- a removal git refuses, and one that fails part way --------------------
# A refusal before anything is deleted leaves nothing to finish, so its marker goes (the case is
# staged with a git that refuses, under the locks below). A lock that is not a Claude agent's is
# never put to git at all: it keeps the worktree before any removal starts, so no marker is written.
# A failure PART WAY is different, measured 2026-10-16 with one unwritable folder: git
# deleted the worktree's own files and its registration, stopped at that folder, and left a plain
# folder git no longer lists. Clearing the marker there would leave it unexplained for ever, so the
# marker stays and every later run names it as a folder to delete by hand.
add fix/510-locked agent-locked; merged fix/510-locked "$WT/agent-locked" HEAD 510; age agent-locked
G -C "$REPO" worktree lock "$WT/agent-locked"
add fix/511-unwritable agent-unwritable
mkdir -p "$WT/agent-unwritable/z"; printf 'z\n' >"$WT/agent-unwritable/z/z.txt"
G -C "$WT/agent-unwritable" add z; G -C "$WT/agent-unwritable" commit -qm z
merged fix/511-unwritable "$WT/agent-unwritable" HEAD 511; age agent-unwritable
chmod 555 "$WT/agent-unwritable/z"
trap 'chmod -R u+w "$TMP" 2>/dev/null; kill "$BUSY" 2>/dev/null; rm -rf "$TMP"' EXIT
CAN_DENY=1
: >"$WT/agent-unwritable/z/probe" 2>/dev/null && { CAN_DENY=0; rm -f "$WT/agent-unwritable/z/probe"; }
run --remove "$REPO"
check "a worktree locked with no reason is kept before any removal is tried" "keeping agent-locked [fix/510-locked]: git has it locked, and not by a Claude agent (no reason given), so the lock is left alone" "$OUT"
check_eq "and leaves no marker" no "$([ -e "$MARKS/agent-locked" ] && echo yes || echo no)"
if [ "$CAN_DENY" -eq 1 ]; then
  check "a removal that fails part way is said" "keeping agent-unwritable [fix/511-unwritable]: git would not remove it" "$OUT"
  check_eq "and its marker stays, since part of it is gone" yes "$([ -e "$MARKS/agent-unwritable" ] && echo yes || echo no)"
  run --remove "$REPO"
  check "the next run names what git left as a plain folder to delete by hand" \
    "keeping agent-unwritable: an earlier removal of it stopped part way after git had already let go of it" "$OUT"
  check "with the command that deletes it" "rm -rf $REPO_REAL/.claude/worktrees/agent-unwritable" "$OUT"
  check_eq "and deletes nothing itself" yes "$([ -d "$WT/agent-unwritable" ] && echo yes || echo no)"
else
  echo "UNMEASURED: a folder made unwritable here can still be written (running as root?), so a removal failing part way cannot be staged"
fi
chmod -R u+w "$WT/agent-unwritable" 2>/dev/null; rm -rf "$WT/agent-unwritable"; rm -f "$MARKS/agent-unwritable"

# And when that plain folder is ALL that is left, git lists no worktree at all, which is the case
# the check answers "nothing here" to before it reads anything else. The marker has to be read
# first, or the one folder it exists to explain is never named.
if [ "$CAN_DENY" -eq 1 ]; then
  SOLO="$TMP/solo"; mkdir -p "$SOLO"; G -C "$SOLO" init -q -b main
  printf 'x\n' >"$SOLO/f.txt"; G -C "$SOLO" add f.txt; G -C "$SOLO" commit -qm base
  SOLO_WT="$SOLO/.claude/worktrees"; mkdir -p "$SOLO_WT"
  G -C "$SOLO" worktree add -q -b fix/520-solo "$SOLO_WT/agent-solo" >/dev/null 2>&1
  mkdir -p "$SOLO_WT/agent-solo/z"; printf 'z\n' >"$SOLO_WT/agent-solo/z/z.txt"
  G -C "$SOLO_WT/agent-solo" add z; G -C "$SOLO_WT/agent-solo" commit -qm z
  merged fix/520-solo "$SOLO_WT/agent-solo" HEAD 520
  find "$SOLO_WT/agent-solo" -exec touch -t 202601010000 {} + 2>/dev/null
  chmod 555 "$SOLO_WT/agent-solo/z"
  run --remove "$SOLO"
  check "a lone worktree whose removal fails part way is said" "keeping agent-solo [fix/520-solo]: git would not remove it" "$OUT"
  run --remove "$SOLO"
  check_eq "with no worktree left for git to list, the next run still has something to say" 1 "$RC"
  check "and names the plain folder left behind" "keeping agent-solo: an earlier removal of it stopped part way" "$OUT"
  chmod -R u+w "$SOLO_WT" 2>/dev/null
fi
G -C "$REPO" worktree unlock "$WT/agent-locked"; G -C "$REPO" worktree remove --force "$WT/agent-locked" >/dev/null 2>&1
G -C "$REPO" worktree prune

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

# --- a lock left by a Claude agent that is no longer running (#1282) --------
# Claude Code locks the worktree of a running agent with the reason
# "claude agent <name> (pid <pid> start <its start time>)", and git refuses to remove a locked
# worktree, so a lock outliving its agent kept a landed worktree for ever: on 2026-10-17 five of
# them, each locked for pid 95065, which died when the Mac went down the evening before. Which
# processes are running and when the machine booted are both injected (a fake ps reading a table,
# and a boot time), so nothing here depends on this machine's own processes, apart from the last
# case, which reads the real ps on purpose so the default lookup is proven too (L3, L411).
# Its own repository, so the counts the cases above assert are not disturbed.
LREPO="$TMP/locks"; mkdir -p "$LREPO"; G -C "$LREPO" init -q -b main
printf 'x\n' >"$LREPO/f.txt"; G -C "$LREPO" add f.txt; G -C "$LREPO" commit -qm base
LWT="$LREPO/.claude/worktrees"; mkdir -p "$LWT"
LREPO_REAL="$(cd "$LREPO" && pwd -P)"
ladd(){ # ladd <name> <branch> <PR> [lock reason]: a landed, clean, aged worktree, locked if given a reason
  G -C "$LREPO" worktree add -q -b "$2" "$LWT/$1" >/dev/null 2>&1
  merged "$2" "$LWT/$1" HEAD "$3"
  find "$LWT/$1" -exec touch -t 202601010000 {} + 2>/dev/null
  if [ -n "${4:-}" ]; then G -C "$LREPO" worktree lock --reason "$4" "$LWT/$1"; fi
}
lockof(){ # the lock git holds on one of these worktrees right now, or UNLOCKED
  git -C "$LREPO" worktree list --porcelain | awk -v p="worktree $LREPO_REAL/.claude/worktrees/$1" '
    $0 == p { f = 1; next } /^worktree / { f = 0 }
    f && /^locked/ { sub(/^locked ?/, ""); print; found = 1 }
    END { if (!found) print "UNLOCKED" }'
}
gone(){ [ -e "$LWT/$1" ] && echo no || echo yes; }

# The fake ps answers `ps -o lstart= -p <pid>` from a table of "pid<TAB>start", the way the real
# one does: the start on stdout and exit 0 for a running pid, nothing and exit 1 for one that is not.
cat >"$TMP/bin/ps" <<'STUB'
#!/usr/bin/env bash
pid=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && { pid="$2"; shift; }; shift; done
printf '%s\n' "$pid" >>"$PS_CALLS"
if [ -n "${PS_FAIL:-}" ]; then echo "ps: simulated failure" >&2; exit 2; fi
line="$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$PS_TABLE")"
[ -n "$line" ] || exit 1
printf '%s\n' "$line"
STUB
chmod +x "$TMP/bin/ps"
export PS_CALLS="$TMP/ps-calls.log" PS_TABLE="$TMP/ps-table.tsv"
printf '4002\tThu Oct 15 12:00:00 2026\n4003\tFri Oct 16 08:30:00 2026\n' >"$PS_TABLE"
BOOT=1791590400   # Sat Oct 10 00:00:00 2026 UTC; every start below is days either side, so no time zone moves one across it

# A git on PATH that, when told to, refuses one removal (so the lock it lifted has to be put back)
# and, for another, has a new agent take the lock between the first look and the unlock (so the
# unlock has to see the lock it judged is no longer the one there).
mkdir -p "$TMP/lshim"
cat >"$TMP/lshim/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*agent-lrefused*)
    if [ -n "\${SHIM_REFUSE:-}" ]; then echo "fatal: simulated refusal" >&2; exit 128; fi ;;
  *agent-lrace" status --porcelain"*)
    if [ -n "\${SHIM_RACE:-}" ]; then
      "$REAL_GIT" -C "$LREPO" worktree unlock "$LWT/agent-lrace"
      "$REAL_GIT" -C "$LREPO" worktree lock --reason "claude agent agent-lrace (pid 4010 start Sat Oct 17 09:00:00 2026)" "$LWT/agent-lrace"
    fi ;;
esac
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$TMP/lshim/git"

lrun(){ : >"$PS_CALLS"; OUT="$(PATH="$TMP/lshim:$PATH" STALE_WT_GH="$TMP/bin/gh" AGENT_LOCK_PS="$TMP/bin/ps" AGENT_LOCK_BOOT_EPOCH="$BOOT" bash "$SCRIPT" "$@" "$LREPO" 2>&1)"; RC=$?; }

R_DEAD="claude agent agent-ldead (pid 4001 start Thu Oct 15 12:00:00 2026)"
R_LIVE="claude agent agent-llive (pid 4002 start Thu Oct 15 12:00:00 2026)"
R_REUSED="claude agent agent-lreused (pid 4003 start Thu Oct 15 12:00:00 2026)"
# ctime pads a one digit day with a second space, which a lock copied from it keeps.
R_PREBOOT="claude agent agent-lpreboot (pid 4004 start Mon Oct  5 12:00:00 2026)"
R_OTHER="kept on an external disk"
R_REFUSED="claude agent agent-lrefused (pid 4005 start Thu Oct 15 12:00:00 2026)"
R_RACE="claude agent agent-lrace (pid 4006 start Thu Oct 15 12:00:00 2026)"
ladd agent-ldead fix/601-dead 601 "$R_DEAD"
ladd agent-llive fix/602-live 602 "$R_LIVE"
ladd agent-lreused fix/603-reused 603 "$R_REUSED"
ladd agent-lpreboot fix/604-preboot 604 "$R_PREBOOT"
ladd agent-lother fix/605-other 605 "$R_OTHER"
ladd agent-lrefused fix/606-refused 606 "$R_REFUSED"
ladd agent-lrace fix/607-race 607 "$R_RACE"

# REPORT: a stale agent lock is no reason to keep a landed worktree, so it is called stale with the
# unlock in its commands; a live agent's lock keeps its worktree; and nothing is unlocked, since a
# mode that reads like an inspection must change nothing (L206).
lrun
check "report mode calls a landed worktree whose agent is gone stale" "STALE agent-ldead [fix/601-dead]" "$OUT"
check "and says the lock was left by an agent that is gone, naming the pid" "pid 4001 is no longer running" "$OUT"
check "and carries the command that lifts the lock" "git -C $LREPO_REAL worktree unlock $LREPO_REAL/.claude/worktrees/agent-ldead" "$OUT"
check "a live agent's lock keeps its worktree, naming the pid" "keeping agent-llive [fix/602-live]: a Claude agent that is still running holds its lock (pid 4002" "$OUT"
check_not "and the live one is never called stale" "STALE agent-llive" "$OUT"
check_not "nor is one whose lock is not a Claude agent's, which --remove would not take" "STALE agent-lother" "$OUT"
for n in ldead lreused lpreboot; do
  check_eq "report mode leaves the lock on agent-$n alone" "claude agent agent-$n" "$(lockof "agent-$n" | cut -d' ' -f1-3)"
done

# REMOVE with neither the processes nor the boot time readable: nothing can say a lock is stale,
# so every agent lock is kept, and says why, rather than read as gone (L10, L11).
PS_FAIL=1 BOOT=unknown lrun --remove
for n in ldead lreused lpreboot llive; do
  check "an unreadable process list keeps agent-$n, saying so" "keeping agent-$n" "$OUT"
  check_eq "with agent-$n still there" no "$(gone "agent-$n")"
done
check "and the reason given is that it could not be read, with what ps said" \
  "whether that agent is still running could not be read (pid 4001, and ps said: ps: simulated failure)" "$OUT"
check_eq "and the lock it could not judge is left exactly as it was" "$R_DEAD" "$(lockof agent-ldead)"

# REMOVE with only the processes unreadable: a lock whose agent started before the machine last
# booted is stale without asking ps at all, since no process survives a boot.
PS_FAIL=1 lrun --remove
check "an agent started before the last boot has its worktree removed although ps cannot be read" \
  "removed agent-lpreboot [fix/604-preboot]" "$OUT"
check "and says the agent started before the machine last booted" "pid 4004 started Mon Oct 5 12:00:00 2026, before this machine last booted" "$OUT"
check_eq "its folder is gone" yes "$(gone agent-lpreboot)"
check_eq "and its branch is kept" 0 "$(G -C "$LREPO" rev-parse -q --verify fix/604-preboot >/dev/null; echo $?)"
check_eq "ps was never asked about the agent the boot already settled" 0 "$(grep -cx 4004 "$PS_CALLS" || true)"
check "while one started since the boot is kept, ps being unreadable" "keeping agent-ldead [fix/601-dead]: it is locked by a Claude agent" "$OUT"

# REMOVE, everything readable.
SHIM_REFUSE=1 SHIM_RACE=1 lrun --remove
check "a landed worktree whose agent's pid is no longer running is removed" "removed agent-ldead [fix/601-dead]" "$OUT"
check_eq "its folder is gone" yes "$(gone agent-ldead)"
check "one whose pid now belongs to a process started at another time is removed" "removed agent-lreused [fix/603-reused]" "$OUT"
check "and says the pid is a different process now" "pid 4003 is now a different process, started Fri Oct 16 08:30:00 2026" "$OUT"
check_eq "its folder is gone" yes "$(gone agent-lreused)"
check "a live agent's worktree is kept" "keeping agent-llive [fix/602-live]: a Claude agent that is still running holds its lock" "$OUT"
check_eq "and its lock is left exactly as it was" "$R_LIVE" "$(lockof agent-llive)"
check "a lock that is not a Claude agent's keeps its worktree, naming the lock" "keeping agent-lother [fix/605-other]: git has it locked, and not by a Claude agent (kept on an external disk), so the lock is left alone" "$OUT"
check_eq "and that lock is left exactly as it was" "$R_OTHER" "$(lockof agent-lother)"
check "a removal git refuses after the stale lock is lifted is said" "keeping agent-lrefused [fix/606-refused]: git would not remove it" "$OUT"
check_eq "and the lock is put back exactly as it was found" "$R_REFUSED" "$(lockof agent-lrefused)"
LMARKS="$(cd "$LREPO" && cd "$(git rev-parse --git-common-dir)" && pwd -P)/claude-worktree-removing"
check_eq "and a refusal, nothing having been deleted, leaves no marker" no "$([ -e "$LMARKS/agent-lrefused" ] && echo yes || echo no)"
check "a lock that changed hands while the run was looking is not lifted" "keeping agent-lrace [fix/607-race]: its lock changed while this run was looking at it" "$OUT"
check_eq "and the new holder's lock is left in place" "claude agent agent-lrace (pid 4010 start Sat Oct 17 09:00:00 2026)" "$(lockof agent-lrace)"
check "the summary counts the removals" "removed 2 of 6 agent worktree(s)" "$OUT"

# The REAL ps, and the real boot time, on a process this suite started: its lock, written the way
# Claude Code writes one (its start time as ps gives it under UTC), keeps its worktree, and the same
# pid with another start time does not.
(cd "$TMP" && exec sleep 120) &
LIVE=$!
trap 'kill "$LIVE" 2>/dev/null; chmod -R u+w "$TMP" 2>/dev/null; kill "$BUSY" 2>/dev/null; rm -rf "$TMP"' EXIT
LIVE_START="$(TZ=UTC ps -o lstart= -p "$LIVE" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
if [ -n "$LIVE_START" ]; then
  ladd agent-lreal fix/608-real 608 "claude agent agent-lreal (pid $LIVE start $LIVE_START)"
  ladd agent-lrealold fix/609-realold 609 "claude agent agent-lrealold (pid $LIVE start Thu Jan  1 00:00:00 2026)"
  : >"$PS_CALLS"
  OUT="$(STALE_WT_GH="$TMP/bin/gh" bash "$SCRIPT" --remove "$LREPO" 2>&1)"; RC=$?
  check "the real ps sees a running agent's lock, and keeps its worktree" "keeping agent-lreal [fix/608-real]: a Claude agent that is still running holds its lock (pid $LIVE" "$OUT"
  check_eq "with its lock in place" "claude agent agent-lreal (pid $LIVE start $LIVE_START)" "$(lockof agent-lreal)"
  check "and the same pid with another start time is not that agent, so its worktree goes" "removed agent-lrealold [fix/609-realold]" "$OUT"
else
  echo "UNMEASURED: ps here gave no start time for a process this suite started, so the real lookup cannot be tested"
fi
kill "$LIVE" 2>/dev/null

kill "$BUSY" 2>/dev/null
echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
