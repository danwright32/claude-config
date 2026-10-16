#!/usr/bin/env bash
# Tests for lib/sleep-queue.sh (claude-config#842): sleep mode's overnight queue and per issue claims.
#
# Nothing here reaches GitHub. HOME is a folder of this suite's own, the issue source is a stub that
# reads fixtures (and is asserted to have been called, L143), and a `gh` first on PATH fails the
# suite if anything calls it at all (L2). The claim race is real: several claimers are started at
# once against one issue and exactly one may own it.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/sleep-queue.sh"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:600}')"; fi; }
check_has(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected to contain '$2', got '${3:0:600}')"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected NOT to contain '$2', got '${3:0:600}')"; fi; }

if [ ! -f "$LIB" ]; then
  echo "FAIL: $LIB does not exist"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

export HOME="$WORK/home"
mkdir -p "$HOME/.claude/state/sleep" "$HOME/.claude/state/sessions"

# Any real gh is unreachable: a gh first on PATH records the call and fails.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/gh-called"
exit 97
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# The injected issue source, answering from fixture files and logging every call.
FX="$WORK/fx"; mkdir -p "$FX"
cat > "$WORK/source.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/source.log"
[ -f "$FX/fail-\$1" ] && { cat "$FX/fail-\$1" >&2; exit 1; }
[ -f "$FX/hang-\$1" ] && { date +%s > "$FX/hang.started"; echo \$\$ > "$FX/hang.pid"; exec sleep 30; }
case "\$1" in
  accounts) cat "$FX/accounts" ;;
  issues) cat "$FX/issues.json" ;;
  issue) cat "$FX/issue-\$3.json" ;;
  prs) cat "$FX/prs.json" ;;
  branches) cat "$FX/branches" ;;
  closer) cat "$FX/closer-\$3" ;;
  *) echo "the stub does not know \$1" >&2; exit 2 ;;
esac
EOF
chmod +x "$WORK/source.sh"
export SLEEP_QUEUE_SOURCE="$WORK/source.sh"

# Now is the real clock's, read once: file times (a damaged record's, a claim entry's) are the real
# clock's too, and the two must be compared on one clock.
NOW="$(date +%s)000"
export SLEEP_NOW_MS="$NOW"

# The repository the night works in: a clone of a local bare repository whose origin reads as a
# GitHub one, so its slug is danwright32/demo and a fetch still never leaves this folder.
git -c init.defaultBranch=main init -q --bare "$WORK/demo.git"
git -c init.defaultBranch=main init -q "$WORK/seed"
git -C "$WORK/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
git -C "$WORK/seed" push -q "$WORK/demo.git" HEAD:main
git clone -q "$WORK/demo.git" "$WORK/repo"
git -C "$WORK/repo" config remote.origin.url https://github.com/danwright32/demo.git
git -C "$WORK/repo" config url."$WORK/demo.git".insteadOf https://github.com/danwright32/demo.git
ROOT="$WORK/repo"

# This boot by sleep.sh's sleep_boot_of, the one shell rule, held to the mod's BOOT_FIXTURES and to
# the mod's own reading of the live sysctl by test-sleep-state.sh.
boot="$(bash -c '. "$1" && sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)"' _ "$DIR/lib/sleep.sh")"
[ -n "$boot" ] || boot=1
asleep(){ printf '{"v":1,"generation":"g1","since":%s,"until":%s,"night":"2026-10-07","bootTime":%s,"workers":[]}' "$((NOW - 1000))" "$((NOW + 3600000))" "$boot" > "$HOME/.claude/state/sleep/current.json"; }
awake(){ rm -f "$HOME/.claude/state/sleep/current.json"; }
session(){ # id lastSeen closedAt cwd request
  printf '{"v":1,"sessionId":"%s","cwd":"%s","repoRoot":null,"startedAt":1,"lastSeen":%s,"closedAt":%s,"transcriptPath":null,"edits":[],"extra":{"progress":{"request":"%s"}}}' \
    "$1" "${4:-$WORK}" "$2" "$3" "${5:-}" > "$HOME/.claude/state/sessions/$1.json"
}
issue(){ # number priority author [extra label]
  local labels='{"name":"bug"}'
  [ "$2" != - ] && labels="$labels,{\"name\":\"priority-$2\"}"
  [ -n "${4:-}" ] && labels="$labels,{\"name\":\"$4\"}"
  printf '{"number":%s,"title":"Issue %s","labels":[%s],"author":{"login":"%s"}}' "$1" "$1" "$labels" "$3"
}
claims_of(){ ls "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/$1" 2>/dev/null | tr '\n' ' '; }

printf 'danwright32\ndwright-pennie\n' > "$FX/accounts"
# Every issue a goal names, each read on its own as gh issue view reads it. Sleep mode works only the
# issues a goal names (#1242), so the queue never lists the repository's open issues; the stub still
# answers a list, so a queue that asked for one is caught below rather than failing for want of it.
fixtures(){
  issue 5 p2 danwright32 > "$FX/issue-5.json"
  issue 9 p0 danwright32 > "$FX/issue-9.json"
  issue 3 p1 dwright-pennie > "$FX/issue-3.json"
  issue 7 p3 danwright32 > "$FX/issue-7.json"
  issue 8 p4 danwright32 > "$FX/issue-8.json"
  issue 10 - danwright32 > "$FX/issue-10.json"
  issue 11 p1 danwright32 needs-dan > "$FX/issue-11.json"
  issue 12 p1 somebody-else > "$FX/issue-12.json"
  issue 13 p2 danwright32 > "$FX/issue-13.json"
  issue 14 p2 danwright32 > "$FX/issue-14.json"
  issue 15 p2 danwright32 > "$FX/issue-15.json"
  issue 16 p2 danwright32 > "$FX/issue-16.json"
}
fixtures
printf '[]' > "$FX/issues.json"
# The night's goal, in the order the claims below are made in.
GOAL=(9 3 11 12 5 13 14 15 16 7)
printf '[{"number":40,"title":"Fix the thing","body":"Closes #13","headRefName":"fix-thing"}]' > "$FX/prs.json"
# A date or a version in a branch name names no issue: 7 and 5 stay in the queue beside these.
printf 'main\nfix-14-thing\nrelease-2026-10-07\nv5-hotfix\nbump-1.5.7\n' > "$FX/branches"
mkdir -p "$HOME/.claude/state/sleep/unanswered"
printf 'danwright32/demo#15\n' > "$HOME/.claude/state/sleep/unanswered/g1"
# An open session on issue 16: its own checkout of the same repository, on a branch naming it.
git clone -q "$WORK/demo.git" "$WORK/other"
git -C "$WORK/other" config remote.origin.url git@github.com:danwright32/demo.git
git -C "$WORK/other" checkout -q -b work-16
session other-1 "$((NOW - 1000))" null "$WORK/other"
session s1 "$((NOW - 1000))" null
session s2 "$((NOW - 1000))" null

if ! . "$LIB"; then
  echo "FAIL: $LIB could not be sourced"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# ---- no goal, no work (#1242) ----
# Dan, 2026-10-16: "Don't pick up random issues. If there's no goal set ... only work the goal." With
# no goal issues named, the queue and next offer nothing, say why, and ask GitHub nothing at all.
asleep
NO_GOAL="$(printf 'none\t-\tno goal issues were named: sleep mode works only the issues a goal names, never the other open issues')"
out="$(sleep_queue "$ROOT" s1)"; rc=$?
check_eq "with no goal issues the queue offers nothing" 1 "$rc"
check_eq "and says why" "$NO_GOAL" "$out"
out="$(sleep_next "$ROOT" s1)"; rc=$?
check_eq "with no goal issues next claims nothing" 1 "$rc"
check_eq "and says why, the one line" "$NO_GOAL" "$out"
check_eq "no claim was written" "" "$(ls -A "$HOME/.claude/state/sleep/claims" 2>/dev/null)"
out="$(bash "$LIB" next "$ROOT" s1)"; rc=$?
check_eq "run as a command with no goal issues, next claims nothing" 1 "$rc"
check_eq "the same line" "$NO_GOAL" "$out"
check_eq "and GitHub was asked nothing" "" "$(cat "$WORK/source.log" 2>/dev/null)"
# Awake, there is no night at all, which outranks having no goal: every awake call refuses alike.
awake
for fn in sleep_queue sleep_next; do
  out="$($fn "$ROOT" s1)"; rc=$?
  check_eq "awake with no goal issues, $fn refuses as every awake call does" 3 "$rc"
  check_has "saying the Mac is not asleep, not that there is no goal" "not asleep" "$out"
done
asleep

# ---- the queue ----
out="$(sleep_queue "$ROOT" s1 "${GOAL[@]}")"; rc=$?
check_eq "the queue answers" 0 "$rc"
check_eq "the queue is the goal's issues in the goal's order, nothing else" "9 3 5 7" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="next"{printf "%s ", $2}' | sed 's/ $//')"
check_not "an issue the goal does not name is never offered" "$(printf '\t8\t')" "$out"
check_has "needs-dan is left out" "$(printf 'skip\t11\tneeds Dan')" "$out"
check_has "another person's issue is left out, naming them" "$(printf 'skip\t12\topened by somebody-else')" "$out"
check_has "an issue an open pull request names is left out" "$(printf 'skip\t13\topen pull request #40 names it')" "$out"
check_has "an issue a branch names is left out" "$(printf 'skip\t14\tbranch fix-14-thing names it')" "$out"
check_has "an issue whose before bed question went unanswered is left out" "$(printf 'skip\t15\ta before bed question')" "$out"
check_has "an issue an open session is on is left out" "$(printf 'skip\t16\tan open session is working on it')" "$out"
check_eq "every goal issue lands in exactly one of next and skip" "10" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="next"||$1=="skip"{print $2}' | sort -u | wc -l | tr -d ' ')"
check_eq "and no issue twice" "10" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="next"||$1=="skip"' | wc -l | tr -d ' ')"
check_has "each goal issue was read on its own" "issue danwright32/demo 9" "$(cat "$WORK/source.log")"
check_not "the repository's open issues were never listed" "issues danwright32/demo" "$(cat "$WORK/source.log")"
check_has "and the open pull requests were read with an explicit limit" "prs danwright32/demo 500" "$(cat "$WORK/source.log")"

# The session on 16 closing frees the issue: the registry decides, read live.
session other-1 "$((NOW - 1000))" "$((NOW - 500))" "$WORK/other"
check_has "a closed session names nothing" "$(printf 'next\t16\t')" "$(sleep_queue "$ROOT" s1 "${GOAL[@]}")"
session other-1 "$((NOW - 6 * 60000))" null "$WORK/other"
check_has "nor does one silent past five minutes" "$(printf 'next\t16\t')" "$(sleep_queue "$ROOT" s1 "${GOAL[@]}")"
session other-1 "$((NOW - 1000))" null "$WORK/other" "carry on with #16 please"
git -C "$WORK/other" checkout -q -b unrelated
check_has "an open session whose request names the issue is on it too" "$(printf 'skip\t16\tan open session')" "$(sleep_queue "$ROOT" s1 "${GOAL[@]}")"
rm -f "$HOME/.claude/state/sessions/other-1.json"

# A full page of pull requests is never read as every one (L24).
out="$(SLEEP_QUEUE_LIMIT=1 sleep_queue "$ROOT" s1 "${GOAL[@]}")"; rc=$?
check_eq "a page as long as the limit refuses" 3 "$rc"
check_has "and says why" "the whole limit of 1, so one naming an issue could be missed" "$out"
check_not "and offers nothing" "$(printf 'next\t')" "$out"

# No account of Dan's read means nothing can be judged his.
: > "$FX/accounts"
out="$(sleep_queue "$ROOT" s1 "${GOAL[@]}")"; rc=$?
check_eq "no accounts refuses" 3 "$rc"
check_has "naming the cause" "no GitHub account of Dan's" "$out"
printf 'danwright32\ndwright-pennie\n' > "$FX/accounts"

# A source failure is a refusal that carries the source's words, never an empty queue (L215).
echo "HTTP 502 from api.github.com" > "$FX/fail-prs"
out="$(sleep_queue "$ROOT" s1 "${GOAL[@]}")"; rc=$?
check_eq "a failed fetch refuses" 3 "$rc"
check_has "with what the source said" "HTTP 502 from api.github.com" "$out"
rm -f "$FX/fail-prs"

# ---- deadlines ----
# A hang check gives its stand-in a 2s deadline (a setting, not measured), and on a busy machine the
# stand-in may not even have started by then: it is stopped before it can say it ran, and the check
# reads that as never ran (#950). So each hang check names the file its stand-in writes on starting,
# SLEEP_DEADLINE_FROM, and the deadline counts from that file appearing: the check measures the
# deadline, not the scheduler (L290). Each stand-in records when it started, then its pid, then
# only waits.
hang_stub(){ # path prefix: a stand-in writing prefix.started and prefix.pid, then hanging
  printf '#!/bin/sh\ndate +%%s > "%s.started"\necho $$ > "%s.pid"\nexec sleep 30\n' "$2" "$2" > "$1"
  chmod +x "$1"
}
ran_and_stopped(){ # prefix: whether its stand-in wrote its pid, and whether that process is gone
  local hp
  hp="$(cat "$1.pid" 2>/dev/null)"
  printf '%s %s\n' "$([ -n "$hp" ] && echo ran || echo never)" "$([ -n "$hp" ] && kill -0 "$hp" 2>/dev/null && echo running || echo stopped)"
}
inside_hang(){ # prefix end: yes when end came well before the stand-in's 30s hang, counted from its start
  local s
  s="$(cat "$1.started" 2>/dev/null)"
  [ -n "$s" ] || { echo "no, it never started"; return; }
  [ $(($2 - s)) -lt 15 ] && echo yes || echo "no, $(($2 - s))s after it started"
}
# A stand-in that takes 2s to say it started (its own sleep, not measured), as one on a loaded
# machine does.
printf '#!/bin/sh\nsleep 2\ndate +%%s > "%s.started"\necho $$ > "%s.pid"\nexec sleep 30\n' "$WORK/slow" "$WORK/slow" > "$WORK/bin/slow-start"
chmod +x "$WORK/bin/slow-start"
# The control (L1): counted from launch, a 1s deadline (set here, not measured) stops it before it
# can say it ran, which is the flake. And the seam is off unless a test sets it.
out="$(_sq_deadline 1 "$WORK/bin/slow-start" 2>&1)"; rc=$?
check_eq "counted from launch, a deadline shorter than the start stops the stand-in" 142 "$rc"
check_eq "before it ever says it ran" "never stopped" "$(ran_and_stopped "$WORK/slow")"
# Counted from the start it reports, the same deadline lets it run, then stops it.
rm -f "$WORK/slow.pid" "$WORK/slow.started"
out="$(SLEEP_DEADLINE_FROM="$WORK/slow.pid" _sq_deadline 1 "$WORK/bin/slow-start" 2>&1)"; rc=$?
t1=$(date +%s)
check_eq "counted from the reported start, it is still stopped at its deadline" 142 "$rc"
check_has "saying so" "took longer than 1s and was stopped" "$out"
check_eq "after it ran, and it is stopped" "ran stopped" "$(ran_and_stopped "$WORK/slow")"
check_eq "well inside its hang" yes "$(inside_hang "$WORK/slow" "$t1")"
# A command that finishes without ever writing the file is not held for it.
t0=$(date +%s)
out="$(SLEEP_DEADLINE_FROM="$WORK/never-written" _sq_deadline 30 sh -c 'exit 5' 2>&1)"; rc=$?
t1=$(date +%s)
check_eq "a command ending before it writes the file keeps its own exit" 5 "$rc"
check_eq "and is not held for the file" yes "$([ $((t1 - t0)) -lt 10 ] && echo yes || echo "no, $((t1 - t0))s")"
# One that hangs and never writes it still meets a deadline, armed once the wait for the start ends
# (SLEEP_DEADLINE_FROM_WAIT, 20s unless set, a setting and not measured), and says why it counted
# from then (L110, L11).
out="$(SLEEP_DEADLINE_FROM="$WORK/never-written" SLEEP_DEADLINE_FROM_WAIT=1 _sq_deadline 1 sleep 30 2>&1)"; rc=$?
check_eq "a hang that never says it started is still stopped" 142 "$rc"
check_has "saying it never said it had started" "never said it had started within 1s" "$out"

# A read from GitHub that hangs is stopped at its deadline and refuses the queue, saying so (L110).
touch "$FX/hang-prs"
out="$(SLEEP_DEADLINE_FROM="$FX/hang.pid" SLEEP_GH_TIMEOUT=2 sleep_queue "$ROOT" s1 "${GOAL[@]}")"; rc=$?
t1=$(date +%s)
rm -f "$FX/hang-prs"
check_eq "a hung GitHub read refuses the queue" 3 "$rc"
check_has "saying it was stopped at its deadline" "took longer than 2s and was stopped" "$out"
check_eq "well inside the hang" yes "$(inside_hang "$FX/hang" "$t1")"
check_eq "the hung read really ran, and is stopped with it" "ran stopped" "$(ran_and_stopped "$FX/hang")"

# The real gh path (no injected source) with a stand-in gh that hangs: the very first call is
# stopped at the deadline and named as that, never read as no account seeing the repository.
mkdir -p "$WORK/hangbin"
hang_stub "$WORK/hangbin/gh" "$WORK/hanggh"
out="$(PATH="$WORK/hangbin:$PATH" SLEEP_QUEUE_SOURCE= SLEEP_DEADLINE_FROM="$WORK/hanggh.pid" SLEEP_GH_TIMEOUT=2 sleep_queue "$ROOT" s1 "${GOAL[@]}")"; rc=$?
t1=$(date +%s)
check_eq "a hung gh refuses the queue" 3 "$rc"
check_has "named as GitHub not answering in time" "GitHub did not answer within 2s" "$out"
check_eq "within one deadline, not the hang" yes "$(inside_hang "$WORK/hanggh" "$t1")"
check_eq "the stand-in gh really ran, and is stopped" "ran stopped" "$(ran_and_stopped "$WORK/hanggh")"

# The goal's issues, in the goal's order, still judged by every exclusion but priority.
printf '{"number":12,"title":"Theirs","labels":[],"author":{"login":"somebody-else"},"state":"OPEN"}' > "$FX/issue-12.json"
printf '{"number":8,"title":"Low","labels":[{"name":"priority-p4"}],"author":{"login":"danwright32"},"state":"OPEN"}' > "$FX/issue-8.json"
printf '{"number":3,"title":"Three","labels":[],"author":{"login":"danwright32"},"state":"CLOSED"}' > "$FX/issue-3.json"
printf '{"number":5,"title":"Five","labels":[],"author":{"login":"danwright32"},"state":"OPEN"}' > "$FX/issue-5.json"
out="$(sleep_queue "$ROOT" s1 8 12 3 5)"
check_eq "the goal's issues come in the goal's order, any priority" "8 5" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="next"{printf "%s ", $2}' | sed 's/ $//')"
check_has "a goal issue opened by somebody else is still left out" "$(printf 'skip\t12\topened by somebody-else')" "$out"
check_has "a closed goal issue is left out" "$(printf 'skip\t3\tclosed')" "$out"
# One goal issue that cannot be read is a skip line with the reason; the rest are still worked.
out="$(sleep_queue "$ROOT" s1 8 77 5)"; rc=$?
check_eq "a goal issue that cannot be read does not refuse the queue" 0 "$rc"
check_eq "the readable goal issues are still queued" "8 5" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="next"{printf "%s ", $2}' | sed 's/ $//')"
check_has "and the unreadable one is a skip line saying why" "$(printf 'skip\t77\tthe goal issue #77 could not be read from GitHub')" "$out"
# An issue with no priority label is queued when a goal names it: a goal is Dan's word on what to work.
fixtures
check_eq "a goal issue of p4, or of no priority, is queued too" "10 8" "$(sleep_queue "$ROOT" s1 10 8 | awk -F'\t' '$1=="next"{printf "%s ", $2}' | sed 's/ $//')"

# Awake, there is no night to queue for.
awake
out="$(sleep_queue "$ROOT" s1 "${GOAL[@]}")"; rc=$?
check_eq "awake, the queue refuses" 3 "$rc"
check_has "saying the Mac is not asleep" "not asleep" "$out"
asleep

# ---- claims ----
# Two, then eight, claimers at once on one issue: exactly one owner, one entry. Started together is
# not the same as clashing: a scheduler that runs each claimer to the end before the next starts
# gives one owner even with no link at all (CI did, #944). So every race holds its claimers at the
# claim's barrier seam, SLEEP_CLAIM_BARRIER, until all of them have judged the issue free, and only
# then lets any write: the clash happens on every run, and met says it did.
barrier(){ # issue count: a barrier folder of this suite's own, for that many claimers
  local b="$WORK/barrier-$1"
  rm -rf "$b"; mkdir -p "$b"; printf '%s\n' "$2" > "$b/parties"
  printf '%s\n' "$b"
}
met(){ # issue: how many claimers reached the barrier, and whether any waited out its deadline
  local b="$WORK/barrier-$1"
  printf '%s %s\n' "$(ls "$b" | grep -c '^arrived\.' | tr -d ' ')" "$([ -e "$b/timed-out" ] && echo timed-out || echo in-time)"
}
race(){ # issue count
  local i b
  b="$(barrier "$1" "$2")"
  for i in $(seq 1 "$2"); do
    session "r$1-$i" "$((NOW - 1000))" null
    ( SLEEP_CLAIM_BARRIER="$b" sleep_claim "$ROOT" "$1" "r$1-$i" > "$WORK/race-$1-$i" 2>&1; echo $? >> "$WORK/race-$1-$i" ) &
  done
  wait
  cat "$WORK"/race-"$1"-* | grep -c '^claimed' | tr -d ' '
}
check_eq "two claimers at once: exactly one owns it" 1 "$(race 21 2)"
check_eq "both judged it free before either wrote" "2 in-time" "$(met 21)"
check_eq "and one entry was made" "1 " "$(claims_of 21)"
check_eq "eight claimers at once: exactly one owns it" 1 "$(race 22 8)"
check_eq "all eight judged it free before any wrote" "8 in-time" "$(met 22)"
check_eq "and still one entry" "1 " "$(claims_of 22)"
check_eq "every loser says the issue is held" 7 "$(cat "$WORK"/race-22-* | grep -c "^not-claimed.*held" | tr -d ' ')"
# Racers sharing $$ and RANDOM state (forked subshells, here seeded alike) still make exactly one
# owner, and the one that says it won is the session its entry names: a shared temp name would let
# one racer link another's entry and believe the claim its own.
same_race(){ # issue count
  local i b
  b="$(barrier "$1" "$2")"
  for i in $(seq 1 "$2"); do
    session "q$1-$i" "$((NOW - 1000))" null
    ( RANDOM=7; SLEEP_CLAIM_BARRIER="$b" sleep_claim "$ROOT" "$1" "q$1-$i" > "$WORK/same-$1-$i" 2>&1 ) &
  done
  wait
}
for r in 51 52 53 54 55; do
  same_race "$r" 8
  check_eq "racers sharing RANDOM on #$r all judged it free before any wrote" "8 in-time" "$(met "$r")"
  won="$(grep -l '^claimed' "$WORK"/same-"$r"-* 2>/dev/null | wc -l | tr -d ' ')"
  check_eq "racers sharing RANDOM on #$r: exactly one says it won" 1 "$won"
  winner="$(grep -l '^claimed' "$WORK"/same-"$r"-* 2>/dev/null | sed 's#.*/same-##')"
  check_has "and #$r's entry names that racer" "\"session\": \"q$winner\"" "$(cat "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/$r/1" 2>/dev/null)"
done

# The control: the same library with the link swapped for a write that never refuses must let
# several claimers own one issue, or the race above proves nothing about the link (L1). Held at the
# barrier, every claimer has judged the issue free before any writes, so all eight own it.
#
# The swap is not cp (#1054). A cp may create a destination it finds absent EXCLUSIVELY (GNU's does,
# O_EXCL after its own look), which is a link of its own: of eight released together, one could look,
# find the name free, and be refused by another's create, so CI saw 7 owners with all 8 met at the
# barrier. A Mac's cp never opens that way, which is why it passed on every Mac. The overwrite below
# is bash's own `>|`, which opens O_CREAT|O_TRUNC on every platform and so cannot refuse, and any
# refusal it did make is recorded and named, so a short count says why instead of only how many.
CTRL="$WORK/control"; mkdir -p "$CTRL"
CTRL_REFUSALS="$WORK/control-refusals"
cp "$DIR/lib/sleep.sh" "$DIR/lib/sleep-queue.py" "$CTRL/"
awk '{ if (index($0, "if err=\"$(ln \"$tmp\"")) sub("[(]ln ", "(_ctrl_overwrite "); print }' "$LIB" > "$CTRL/sleep-queue.sh"
cat >> "$CTRL/sleep-queue.sh" <<'EOF'
_ctrl_overwrite(){ local e; e="$( { cat "$1" >| "$2"; } 2>&1 )" && return 0; printf '%s\n' "${e:-the overwrite failed and said nothing}" >> "$CTRL_REFUSALS"; return 1; }
EOF
check_eq "the control swapped the link for an overwrite" 1 "$(grep -c 'if err="$(_ctrl_overwrite "$tmp"' "$CTRL/sleep-queue.sh" | tr -d ' ')"
owners="$( . "$CTRL/sleep-queue.sh" && race 41 8 )"
check_eq "without the link, every one of eight claimers at once owns it" 8 "$owners"
check_eq "the control's overwrite refused none of them" "" "$(cat "$CTRL_REFUSALS" 2>/dev/null)"
check_eq "the control's claimers all met at the barrier too" "8 in-time" "$(met 41)"

# The barrier is a test's alone: it acts only on a folder holding a parties file, which only a test
# writes, so a night with the variable set to anything else never waits (#944).
mkdir -p "$WORK/not-a-barrier"
session s0 "$((NOW - 1000))" null
t0=$(date +%s)
out="$(SLEEP_CLAIM_BARRIER="$WORK/not-a-barrier" sleep_claim "$ROOT" 42 s0)"
t1=$(date +%s)
check_has "a folder with no parties file is no barrier, and the claim goes ahead" "$(printf 'claimed\t42\t')" "$out"
check_eq "without waiting" yes "$([ $((t1 - t0)) -lt 5 ] && echo yes || echo "no, $((t1 - t0))s")"
check_eq "and nothing is written into that folder" "" "$(ls -A "$WORK/not-a-barrier")"
b="$(barrier 43 x)"
out="$(SLEEP_CLAIM_BARRIER="$b" sleep_claim "$ROOT" 43 s0)"
check_has "nor is one whose parties file holds no count" "$(printf 'claimed\t43\t')" "$out"
check_eq "and it records no arrival" "0 in-time" "$(met 43)"
# A claimer waiting for parties that never come carries on at the barrier's deadline (L110) and
# leaves a mark the race's met check fails on, so a broken barrier is a red, never a hang.
b="$(barrier 44 2)"; printf '1\n' > "$b/deadline"
t0=$(date +%s)
out="$(SLEEP_CLAIM_BARRIER="$b" sleep_claim "$ROOT" 44 s0)"
t1=$(date +%s)
check_has "a barrier short of parties lets its claimer go at the deadline" "$(printf 'claimed\t44\t')" "$out"
check_eq "within a few seconds of it" yes "$([ $((t1 - t0)) -lt 10 ] && echo yes || echo "no, $((t1 - t0))s")"
check_eq "and says it timed out" "1 timed-out" "$(met 44)"

out="$(sleep_claim "$ROOT" 9 s1)"; rc=$?
check_eq "a free issue is claimed" 0 "$rc"
check_has "as the first attempt" "$(printf 'claimed\t9\tattempts=1')" "$out"
out="$(sleep_claim "$ROOT" 9 s1)"; rc=$?
check_eq "claiming your own claim again holds it" 0 "$rc"
check_has "without counting another attempt" "attempts=1" "$out"
check_eq "and writes nothing" "1 " "$(claims_of 9)"
out="$(sleep_claim "$ROOT" 9 s2)"; rc=$?
check_eq "another live session cannot take it" 1 "$rc"
check_has "and is told who holds it" "session s1 holds it" "$out"
check_has "the queue leaves a held issue out for everyone else" "$(printf 'skip\t9\tclaim held')" "$(sleep_queue "$ROOT" s2 "${GOAL[@]}")"
check_has "but its holder still sees it, to carry on" "$(printf 'next\t9\tp0\tattempts=1\tmine')" "$(sleep_queue "$ROOT" s1 "${GOAL[@]}")"

# A claim whose session died is free, and taking it over is an attempt of its own (L27, L409).
session s1 "$((NOW - 1000))" "$((NOW - 100))"
out="$(sleep_claim "$ROOT" 9 s2)"; rc=$?
check_eq "a claim of a session that ended is taken over" 0 "$rc"
check_has "counted as the second attempt" "attempts=2" "$out"
check_eq "as a new entry beside the old" "1 2 " "$(claims_of 9)"
session s1 "$((NOW - 1000))" null
check_eq "the first holder coming back cannot take it back" 1 "$(sleep_claim "$ROOT" 9 s1 >/dev/null; echo $?)"

session s3 "$((NOW - 6 * 60000))" null
sleep_claim "$ROOT" 23 s3 >/dev/null
out="$(sleep_claim "$ROOT" 23 s2)"
check_has "a session silent past five minutes has gone too" "taken over" "$out"
check_has "and is named" "claimed" "$out"
sleep_claim "$ROOT" 24 ghost >/dev/null 2>&1
check_has "a claim by a session the registry never saw is free" "claimed" "$(session ghost 0 null; rm "$HOME/.claude/state/sessions/ghost.json"; sleep_claim "$ROOT" 24 s2)"

# A record that cannot be read is never read as no session (L215): the claim stays held.
session s4 "$((NOW - 1000))" null
sleep_claim "$ROOT" 25 s4 >/dev/null
printf '{"v":1,' > "$HOME/.claude/state/sessions/s4.json"
out="$(sleep_claim "$ROOT" 25 s2)"; rc=$?
check_eq "an owner whose record cannot be read keeps the claim" 1 "$rc"
check_has "and the reason is said" "cannot be read" "$out"
out="$(sleep_queue "$ROOT" s2 "${GOAL[@]}")"; rc=$?
check_eq "a registry record changed just now that cannot be read refuses the queue" 3 "$rc"
check_has "naming the record, since it may be a live session's" "cannot be read (s4.json)" "$out"
touch -t 202001010000 "$HOME/.claude/state/sessions/s4.json"
out="$(sleep_queue "$ROOT" s2 "${GOAL[@]}")"; rc=$?
check_eq "an old damaged record is no live session's, and the queue goes on" 0 "$rc"
session s4 "$((NOW - 1000))" null

# A claimer killed after writing its entry but before linking it leaves a stray temp file, which
# blocks nobody.
mkdir -p "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/26"
printf '{"kind":"claim","session":"dead"}' > "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/26/.tmp.dead"
check_has "a claimer killed mid claim blocks nobody" "$(printf 'claimed\t26\tattempts=1')" "$(sleep_claim "$ROOT" 26 s2)"
# Its leftover is cleared once it is ten minutes old; a fresh one may be a live writer's.
printf x > "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/26/.tmp.old"
touch -t 202001010000 "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/26/.tmp.old"
sleep_claim "$ROOT" 26 s2 >/dev/null
check_eq "a temp file ten minutes old is cleared by the next claim" no "$([ -e "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/26/.tmp.old" ] && echo yes || echo no)"
check_eq "a fresh one is left" yes "$([ -e "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/26/.tmp.dead" ] && echo yes || echo no)"
# An entry written without its start time falls back to the file's own time (L409).
printf '{"kind":"claim","session":"s4"}' > "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/26/2"
touch -t 202610071200 "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/26/2"
check_has "a claim with no start time is dated by its file" "holds it since $(( $(date -j -f %Y%m%d%H%M%S 20261007120000 +%s) * 1000 ))" "$(sleep_claim "$ROOT" 26 s1)"

# Releasing: only the holder, and done, parked and failed end the issue for the night.
out="$(sleep_release "$ROOT" 9 s1 done)"; rc=$?
check_eq "only the holder may release" 1 "$rc"
check_has "and the refusal says whose it is" "session s2 holds it" "$out"
out="$(sleep_release "$ROOT" 9 s2 parked "two hours with no progress")"; rc=$?
check_eq "the holder parks it" 0 "$rc"
check_has "the queue leaves a parked issue out, with why" "$(printf 'skip\t9\tclaim ended: parked: two hours with no progress')" "$(sleep_queue "$ROOT" s1 "${GOAL[@]}")"
check_eq "nobody can claim a parked issue" 1 "$(sleep_claim "$ROOT" 9 s1 >/dev/null; echo $?)"
check_eq "a release with a state nobody knows is refused" 2 "$(sleep_release "$ROOT" 26 s2 maybe >/dev/null 2>&1; echo $?)"
check_eq "nor may a caller end a claim unstarted, which would erase an attempt" 2 "$(sleep_release "$ROOT" 26 s2 unstarted >/dev/null 2>&1; echo $?)"
sleep_claim "$ROOT" 27 s2 >/dev/null
sleep_release "$ROOT" 27 s2 free >/dev/null
out="$(sleep_claim "$ROOT" 27 s1)"
check_has "a released issue can be claimed again, as another attempt" "$(printf 'claimed\t27\tattempts=2')" "$out"

# Tonight's claim exempts an issue from its pull request only while its work is to be carried on.
c13="$HOME/.claude/state/sleep/claims/g1/danwright32__demo/13"; mkdir -p "$c13"
printf '{"kind":"claim","session":"ghost2","at":1}' > "$c13/1"
check_has "a dead worker's issue is carried on despite its pull request" "$(printf 'next\t13\t')" "$(sleep_queue "$ROOT" s2 "${GOAL[@]}")"
printf '{"kind":"free","session":"ghost2","at":2}' > "$c13/2"
check_has "one its holder released on purpose is judged afresh, and its pull request keeps it out" "$(printf 'skip\t13\topen pull request #40 names it')" "$(sleep_queue "$ROOT" s2 "${GOAL[@]}")"
rm -rf "$c13"

# A claim that cannot be written is said as that, never as a lost race (L11).
mkdir -p "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/29"
chmod 555 "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/29"
out="$(sleep_claim "$ROOT" 29 s2)"; rc=$?
chmod 755 "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/29"
check_eq "a claim folder that cannot be written refuses" 3 "$rc"
check_has "saying the entry could not be written" "could not be written" "$out"
check_not "never as another session writing first" "another session" "$out"

# One reading of an origin: a trailing slash names the same repository on both sides.
git -C "$ROOT" config remote.origin.url https://github.com/danwright32/demo/
check_has "an origin ending in a slash is the same repository" "$(printf 'claimed\t30\t')" "$(sleep_claim "$ROOT" 30 s2)"
check_eq "and the python reader agrees" "danwright32/demo" "$(python3 "$DIR/lib/sleep-queue.py" slug https://github.com/danwright32/demo/)"
check_eq "a slug that would climb out of the claims folder is no slug" 1 "$(python3 "$DIR/lib/sleep-queue.py" slug https://github.com/danwright32/.. >/dev/null; echo $?)"
git -C "$ROOT" config remote.origin.url https://github.com/danwright32/demo.git

# Not asleep: no claim is made, and nothing is written.
awake
out="$(sleep_claim "$ROOT" 28 s1)"; rc=$?
check_eq "awake, a claim is refused" 3 "$rc"
check_eq "and leaves nothing behind" "" "$(claims_of 28)"
asleep

# The registry missing altogether recovers nothing (fail closed).
mv "$HOME/.claude/state/sessions" "$WORK/sessions-aside"
out="$(sleep_claim "$ROOT" 27 s2)"; rc=$?
check_eq "with no registry a live looking claim is left alone" 1 "$rc"
check_has "saying the registry could not be read" "session registry" "$out"
out="$(sleep_queue "$ROOT" s2 "${GOAL[@]}")"; rc=$?
check_eq "and the queue refuses" 3 "$rc"
mv "$WORK/sessions-aside" "$HOME/.claude/state/sessions"

# ---- next: queue, claim, worktree ----
rm -rf "$HOME/.claude/state/sleep/claims"
# A claim refused outright stops next with that refusal, never read as an issue someone holds.
mkdir -p "$HOME/.claude/state/sleep/claims/g1/danwright32__demo"
chmod 555 "$HOME/.claude/state/sleep/claims/g1/danwright32__demo"
out="$(sleep_next "$ROOT" s1 "${GOAL[@]}")"; rc=$?
chmod 755 "$HOME/.claude/state/sleep/claims/g1/danwright32__demo"
check_eq "next stops on a refused claim" 3 "$rc"
check_has "with the refusal itself" "$(printf 'refused\t-\tthe claim folder')" "$out"
check_not "never saying nothing is left" "nothing left" "$out"
out="$(sleep_next "$ROOT" s1 "${GOAL[@]}")"; rc=$?
check_eq "next claims something" 0 "$rc"
check_has "the first issue in the queue" "$(printf 'claimed\t9\tattempts=1\tworktree=%s/.claude/worktrees/sleep-9' "$ROOT")" "$out"
check_eq "in a worktree of its own, on its own branch" "sleep/9" "$(git -C "$ROOT/.claude/worktrees/sleep-9" branch --show-current 2>&1)"
check_eq "the primary checkout is left on its branch" "main" "$(git -C "$ROOT" branch --show-current)"
out="$(sleep_next "$ROOT" s2 "${GOAL[@]}")"
check_has "a second worker gets the next issue" "$(printf 'claimed\t3\t')" "$out"
# A fetch that fails just now gives the issue back for a later pass, never ends it for the night.
mv "$WORK/demo.git" "$WORK/demo.git.aside"
session s9 "$((NOW - 1000))" null
out="$(sleep_next "$ROOT" s9 "${GOAL[@]}")"; rc=$?
mv "$WORK/demo.git.aside" "$WORK/demo.git"
check_eq "with no fetch possible, nothing is started" 1 "$rc"
check_has "the issue is given back, saying so" "$(printf 'skip\t5\tclaimed but could not start (given back for a later pass): git fetch')" "$out"
check_has "its claim ends unstarted" '"kind": "unstarted"' "$(cat "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/5/2" 2>/dev/null)"
check_has "so a later pass claims it again, with no attempt spent" "$(printf 'next\t5\tp2\tattempts=0\tfree')" "$(sleep_queue "$ROOT" s9 "${GOAL[@]}")"
# A claim lost between the queue and the claim is said on a skip line, never dropped.
out="$( sleep_claim(){ printf 'not-claimed\t%s\theld: session zz holds it\n' "$2"; return 1; }; sleep_next "$ROOT" s9 "${GOAL[@]}" )"
check_has "a claim lost after the queue is a skip line with its reason" "$(printf 'skip\t5\tnot claimed: held: session zz holds it')" "$out"
# A repository whose git folder lives elsewhere still gets its worktree beside its checkout.
git clone -q --separate-git-dir "$WORK/sep.git" "$WORK/demo.git" "$WORK/seprepo"
check_eq "a separate git folder puts the worktree beside the checkout" "$WORK/seprepo/.claude/worktrees/sleep-31" "$(sleep_worktree "$WORK/seprepo" 31 2>&1)"
# A fetch that hangs is stopped at its deadline and gives the issue back (L110). The remote is an
# ssh one whose ssh is a script that only waits, so nothing leaves this machine.
git clone -q "$WORK/demo.git" "$WORK/hangrepo"
git -C "$WORK/hangrepo" config remote.origin.url git@github.com:danwright32/demo.git
hang_stub "$WORK/bin/hang-ssh" "$WORK/hang"
# Its deadline counts from the ssh saying it started, as the hang checks above do (#950).
out="$(GIT_SSH_COMMAND="$WORK/bin/hang-ssh" SLEEP_DEADLINE_FROM="$WORK/hang.pid" SLEEP_FETCH_TIMEOUT=2 sleep_worktree "$WORK/hangrepo" 33 2>&1)"; rc=$?
t1=$(date +%s)
check_eq "a hung fetch gives the issue back" 2 "$rc"
check_has "saying it was stopped at its deadline" "took longer than 2s and was stopped" "$out"
check_eq "and returns well inside the hang" yes "$(inside_hang "$WORK/hang" "$t1")"
ras="$(ran_and_stopped "$WORK/hang")"
check_eq "the hung fetch's ssh really ran" ran "${ras% *}"
check_eq "and is stopped with it, not left running" stopped "${ras#* }"
git init -q --bare "$WORK/bare.git"
out="$(sleep_worktree "$WORK/bare.git" 32 2>&1)"; rc=$?
check_eq "a bare repository is refused for good" 1 "$rc"
check_has "saying why" "is a bare repository" "$out"
out="$(sleep_next "$ROOT" s1 "${GOAL[@]}")"
check_has "next for a holder carries on with its own issue" "$(printf 'claimed\t9\tattempts=1')" "$out"
check_has "in the worktree it already has" "worktree=$ROOT/.claude/worktrees/sleep-9" "$out"
# The holder of 9 dies: its branch is tonight's own work, which the next session carries on.
git -C "$WORK/repo/.claude/worktrees/sleep-9" push -q origin sleep/9
printf 'main\nfix-14-thing\nsleep/9\n' > "$FX/branches"
session s1 "$((NOW - 1000))" "$((NOW - 10))"
session s5 "$((NOW - 1000))" null
out="$(sleep_next "$ROOT" s5 "${GOAL[@]}")"
check_has "a dead session's issue is taken over despite its own branch" "$(printf 'claimed\t9\tattempts=2')" "$out"
check_has "in the worktree the dead session left" "worktree=$ROOT/.claude/worktrees/sleep-9" "$out"
# Something else sitting where the worktree goes is never adopted (L421), and the claim ends failed.
mkdir -p "$ROOT/.claude/worktrees/sleep-5"; echo stranger > "$ROOT/.claude/worktrees/sleep-5/file"
session s6 "$((NOW - 1000))" null
# The worktree's reason never goes through a temp file, so nothing is left in the temp folder.
mkdir -p "$WORK/tmp6"
out="$(TMPDIR="$WORK/tmp6" sleep_next "$ROOT" s6 "${GOAL[@]}")"
check_eq "next leaves no temp file for a worktree's failure" "" "$(ls -A "$WORK/tmp6")"
check_has "a folder that is not this issue's worktree is refused" "is not a worktree of" "$out"
check_has "the claim is ended as failed, never left held" '"kind": "failed"' "$(cat "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/5/4" 2>/dev/null)"
check_has "and next goes on to the issue after it" "$(printf 'claimed\t16\t')" "$out"
first="${out%%$'\n'*}"
check_eq "its one result line comes first" claimed "${first%%$'\t'*}"
check_has "the issue it could not start follows as a skip line" "$(printf 'skip\t5\tclaimed but could not start (ended for tonight):')" "$out"
session s7 "$((NOW - 1000))" null
check_has "the last one goes to the next worker" "$(printf 'claimed\t7\t')" "$(sleep_next "$ROOT" s7 "${GOAL[@]}")"
session s8 "$((NOW - 1000))" null
out="$(sleep_next "$ROOT" s8 "${GOAL[@]}")"; rc=$?
check_eq "with nothing left, next says none" 1 "$rc"
check_has "plainly" "none" "$out"

# ---- the claim's work, whoever did it (#1119) ----
# The overnight driver's circuit breaker counts a new commit as progress. On 2026-10-12 it ended
# #1106 as failed while a subagent of the claiming session was committing in the claim's own
# worktree on a branch of its own, so the reading is the claim's branch and the commits made in
# its reserved worktree on any branch, read from git, never from who made the commit. Switching
# branches there makes no commit, so it is no progress (lessons review of 162acef).
session s10 "$((NOW - 1000))" null
sleep_claim "$ROOT" 41 s10 >/dev/null
out="$(sleep_work "$ROOT" 41)"; rc=$?
check_eq "with no branch and no worktree yet, the work reads as nothing, not as unreadable" 0 "$rc"
check_eq "both readings empty" "$(printf 'branch\t\nworktree\t')" "$out"
wt41="$(sleep_worktree "$ROOT" 41 2>&1)"
before="$(sleep_work "$ROOT" 41)"
check_has "the claim's branch is read" "$(printf 'branch\t%s' "$(git -C "$ROOT" rev-parse refs/heads/sleep/41)")" "$before"
check_has "and the commits made in the worktree, none yet" "$(printf 'worktree\t0')" "$before"
check_eq "a caller under set -e gets that reading too, never stopped at a count of none" 0 "$(bash -c 'set -e; . "$1"; sleep_work "$2" 41 >/dev/null; echo $?' _ "$LIB" "$ROOT" 2>/dev/null)"
# A subagent switches the reserved worktree to a branch of its own and commits there.
git -C "$wt41" switch -q -c fix/41-by-a-subagent
git -C "$wt41" -c user.email=sub@t -c user.name=sub commit -q --allow-empty -m "the subagent's work"
after="$(sleep_work "$ROOT" 41)"
check_not "a commit in the reserved worktree on another branch is the claim's work" "$before" "$after"
check_has "read as one commit made in that worktree" "$(printf 'worktree\t1')" "$after"
# Switching back to the claim's branch, which already exists, makes no commit and is no progress.
git -C "$wt41" switch -q sleep/41
check_eq "a branch switch in the reserved worktree is no progress" "$after" "$(sleep_work "$ROOT" 41)"
# A commit on the claim's branch made from anywhere else is its work too.
git -C "$ROOT" -c user.email=x@t -c user.name=x commit-tree -m elsewhere "$(git -C "$ROOT" rev-parse 'HEAD^{tree}')" -p "$(git -C "$ROOT" rev-parse refs/heads/sleep/41)" > "$WORK/c41"
git -C "$ROOT" update-ref refs/heads/sleep/41 "$(cat "$WORK/c41")"
check_has "a commit on the claim's branch from anywhere is read" "$(printf 'branch\t%s' "$(cat "$WORK/c41")")" "$(sleep_work "$ROOT" 41)"
# From inside the reserved worktree the same claim reads the same.
check_eq "asked from the reserved worktree, the reading is the same" "$(sleep_work "$ROOT" 41)" "$(sleep_work "$wt41" 41)"
# Something at the reserved path that is not this repository's worktree is nobody's work: git
# would otherwise walk up from it to the primary checkout and read that.
out="$(sleep_work "$ROOT" 5)"
check_eq "a stranger folder at the reserved path is not read as the primary checkout" "$(printf 'branch\t\nworktree\t')" "$out"
out="$(sleep_work "$WORK/no-such-folder" 41)"; rc=$?
check_eq "a folder that is no checkout is refused" 3 "$rc"
check_has "saying so" "$(printf 'refused\t-\t')" "$out"
check_eq "an issue that is no number is refused" 3 "$(sleep_work "$ROOT" 4x >/dev/null; echo $?)"
out="$(bash "$LIB" work "$ROOT" 41)"; rc=$?
check_eq "run as a command, the work reading answers" 0 "$rc"
check_has "the same reading" "$(printf 'worktree\t1')" "$out"

# ---- done after the driver ended a claim (#1119) ----
# The breaker ends the claim as failed while the work goes on; when GitHub then shows the issue
# closed by a merged pull request, the holder's release of done lands over that end, so the
# report shows the issue done rather than failed. Only then, and only for the session that held it.
sleep_claim "$ROOT" 42 s10 >/dev/null
SLEEP_NOTE_BY_DRIVER=1 sleep_release "$ROOT" 42 s10 failed "circuit breaker: 22 minutes of active time with no new commit, claim or note" >/dev/null
printf '1111\n' > "$FX/closer-42"
out="$(sleep_release "$ROOT" 42 s10 done "merged PR #1111")"; rc=$?
check_eq "done lands over the breaker's failed once a merged pull request closed the issue" 0 "$rc"
check_eq "said as released" "$(printf 'released\t42\tdone')" "$out"
check_has "GitHub was asked which pull request closed it" "closer danwright32/demo 42" "$(cat "$WORK/source.log")"
last42="$(cat "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/42/3" 2>/dev/null)"
check_has "the claim's newest entry is done" '"kind": "done"' "$last42"
check_has "naming the pull request and the end it replaced" "closed by merged PR #1111 after it was ended failed" "$last42"
check_has "the end it replaced stays in the history" '"kind": "failed"' "$(cat "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/42/2" 2>/dev/null)"
check_eq "done is the end: a second done is refused" 1 "$(sleep_release "$ROOT" 42 s10 done >/dev/null; echo $?)"
# Not closed by a merged pull request: the end stands.
sleep_claim "$ROOT" 43 s10 >/dev/null
sleep_release "$ROOT" 43 s10 failed "circuit breaker: 3 blocks in a row" >/dev/null
: > "$FX/closer-43"
out="$(sleep_release "$ROOT" 43 s10 done)"; rc=$?
check_eq "with no merged pull request closing it, done does not replace failed" 1 "$rc"
check_has "saying why" "is not closed by a merged pull request" "$out"
check_eq "and nothing is written" "1 2 " "$(claims_of 43)"
# GitHub that cannot be read refuses, never reads as not closed.
printf 'HTTP 502\n' > "$FX/fail-closer"
out="$(sleep_release "$ROOT" 43 s10 done)"; rc=$?
rm -f "$FX/fail-closer"
check_eq "a failed read of GitHub refuses" 3 "$rc"
check_has "with the source's reason" "HTTP 502" "$out"
# Another session's ended claim is not this one's to call done, even when it was merged.
printf '1112\n' > "$FX/closer-43"
out="$(sleep_release "$ROOT" 43 s2 done)"; rc=$?
check_eq "another session cannot mark someone else's ended claim done" 1 "$rc"
check_eq "and nothing is written for it" "1 2 " "$(claims_of 43)"
# Only an end the driver can make over live work is replaced: one given back stays given back.
sleep_claim "$ROOT" 44 s10 >/dev/null
sleep_release "$ROOT" 44 s10 free >/dev/null
printf '1113\n' > "$FX/closer-44"
check_eq "a claim given back free is not marked done" 1 "$(sleep_release "$ROOT" 44 s10 done >/dev/null; echo $?)"
# Parked by the driver while a subagent finished it is the same case as failed.
sleep_claim "$ROOT" 45 s10 >/dev/null
SLEEP_NOTE_BY_DRIVER=1 sleep_release "$ROOT" 45 s10 parked "held for 2 hours of active time" >/dev/null
printf '1114\n' > "$FX/closer-45"
check_eq "done lands over a park too once a merged pull request closed it" 0 "$(sleep_release "$ROOT" 45 s10 done >/dev/null; echo $?)"
# Any end but done over an ended claim is still refused.
check_eq "failed over failed is refused" 1 "$(sleep_release "$ROOT" 43 s10 failed again >/dev/null; echo $?)"

# ---- the report's read of every claim (phase 4, #835) ----
out="$(sleep_claims_json)"
check_has "every claim of the night as one JSON line" '"repo": "danwright32/demo", "issue": 9, "attempts": 2' "$out"
check_has "with its history" '"kind": "failed"' "$out"

# ---- run as a command ----
out="$(bash "$LIB" queue "$ROOT" s7 "${GOAL[@]}")"; rc=$?
check_eq "run as a command, the queue answers" 0 "$rc"
check_has "the same lines" "$(printf 'skip\t9\t')" "$out"
check_eq "an unknown command is refused" 2 "$(bash "$LIB" frobnicate >/dev/null 2>&1; echo $?)"
# The judgments alone: sleep-queue.py refuses a queue it was not given every input for.
out="$(python3 "$DIR/lib/sleep-queue.py" queue repo=danwright32/demo)"; rc=$?
check_eq "sleep-queue.py refuses a queue missing an input" 3 "$rc"
check_has "naming it" "was not given limit" "$out"
# And one given every input but no goal issues, so no caller can reach the old open issues queue.
printf '[%s]' "$(issue 9 p0 danwright32)" > "$WORK/all-open.json"
out="$(python3 "$DIR/lib/sleep-queue.py" queue repo=danwright32/demo limit=500 "issues=$WORK/all-open.json" "prs=$FX/prs.json" "branches=$FX/branches" "accounts=$FX/accounts" "unanswered=$WORK/none" "claims=$WORK/none" "registry=$HOME/.claude/state/sessions" "now=$NOW" self=s1 goal=)"; rc=$?
check_eq "sleep-queue.py refuses a queue with no goal issues" 3 "$rc"
check_has "saying sleep mode works only a goal's issues" "no goal issues were named" "$out"
check_not "and never offers an open issue" "$(printf 'next\t9')" "$out"

# ---- the seams fired, and nothing reached GitHub ----
check_eq "the stub source was the one asked" yes "$([ -s "$WORK/source.log" ] && echo yes || echo no)"
check_eq "gh itself was never called" "" "$(cat "$WORK/gh-called" 2>/dev/null)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
