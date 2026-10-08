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
[ -f "$FX/hang-\$1" ] && { echo \$\$ > "$FX/hang.pid"; exec sleep 30; }
case "\$1" in
  accounts) cat "$FX/accounts" ;;
  issues) cat "$FX/issues.json" ;;
  issue) cat "$FX/issue-\$3.json" ;;
  prs) cat "$FX/prs.json" ;;
  branches) cat "$FX/branches" ;;
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
{
  printf '['
  issue 5 p2 danwright32; printf ','
  issue 9 p0 danwright32; printf ','
  issue 3 p1 dwright-pennie; printf ','
  issue 7 p3 danwright32; printf ','
  issue 8 p4 danwright32; printf ','
  issue 10 - danwright32; printf ','
  issue 11 p1 danwright32 needs-dan; printf ','
  issue 12 p1 somebody-else; printf ','
  issue 13 p2 danwright32; printf ','
  issue 14 p2 danwright32; printf ','
  issue 15 p2 danwright32; printf ','
  issue 16 p2 danwright32
  printf ']'
} > "$FX/issues.json"
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

# ---- the queue ----
asleep
out="$(sleep_queue "$ROOT" s1)"; rc=$?
check_eq "the queue answers" 0 "$rc"
check_eq "the queue is p0 to p3 in priority order, nothing else" "9 3 5 7" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="next"{printf "%s ", $2}' | sed 's/ $//')"
check_has "p4 is left out" "$(printf 'skip\t8\tnot p0 to p3')" "$out"
check_has "an issue with no priority is left out" "$(printf 'skip\t10\tnot p0 to p3')" "$out"
check_has "needs-dan is left out" "$(printf 'skip\t11\tneeds Dan')" "$out"
check_has "another person's issue is left out, naming them" "$(printf 'skip\t12\topened by somebody-else')" "$out"
check_has "an issue an open pull request names is left out" "$(printf 'skip\t13\topen pull request #40 names it')" "$out"
check_has "an issue a branch names is left out" "$(printf 'skip\t14\tbranch fix-14-thing names it')" "$out"
check_has "an issue whose before bed question went unanswered is left out" "$(printf 'skip\t15\ta before bed question')" "$out"
check_has "an issue an open session is on is left out" "$(printf 'skip\t16\tan open session is working on it')" "$out"
check_eq "every issue lands in exactly one of next and skip" "12" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="next"||$1=="skip"{print $2}' | sort -u | wc -l | tr -d ' ')"
check_eq "and no issue twice" "12" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="next"||$1=="skip"' | wc -l | tr -d ' ')"
check_has "the source was asked for the issues with an explicit limit" "issues danwright32/demo 500" "$(cat "$WORK/source.log")"
check_has "and for the open pull requests with one" "prs danwright32/demo 500" "$(cat "$WORK/source.log")"

# The session on 16 closing frees the issue: the registry decides, read live.
session other-1 "$((NOW - 1000))" "$((NOW - 500))" "$WORK/other"
check_has "a closed session names nothing" "$(printf 'next\t16\t')" "$(sleep_queue "$ROOT" s1)"
session other-1 "$((NOW - 6 * 60000))" null "$WORK/other"
check_has "nor does one silent past five minutes" "$(printf 'next\t16\t')" "$(sleep_queue "$ROOT" s1)"
session other-1 "$((NOW - 1000))" null "$WORK/other" "carry on with #16 please"
git -C "$WORK/other" checkout -q -b unrelated
check_has "an open session whose request names the issue is on it too" "$(printf 'skip\t16\tan open session')" "$(sleep_queue "$ROOT" s1)"
rm -f "$HOME/.claude/state/sessions/other-1.json"

# A full page of issues is never read as every issue (L24).
out="$(SLEEP_QUEUE_LIMIT=12 sleep_queue "$ROOT" s1)"; rc=$?
check_eq "a page as long as the limit refuses" 3 "$rc"
check_has "and says why" "the whole limit of 12, so the queue would be a partial one" "$out"
check_not "and offers nothing" "$(printf 'next\t')" "$out"

# No account of Dan's read means nothing can be judged his.
: > "$FX/accounts"
out="$(sleep_queue "$ROOT" s1)"; rc=$?
check_eq "no accounts refuses" 3 "$rc"
check_has "naming the cause" "no GitHub account of Dan's" "$out"
printf 'danwright32\ndwright-pennie\n' > "$FX/accounts"

# A source failure is a refusal that carries the source's words, never an empty queue (L215).
echo "HTTP 502 from api.github.com" > "$FX/fail-issues"
out="$(sleep_queue "$ROOT" s1)"; rc=$?
check_eq "a failed fetch refuses" 3 "$rc"
check_has "with what the source said" "HTTP 502 from api.github.com" "$out"
rm -f "$FX/fail-issues"

# A read from GitHub that hangs is stopped at its deadline and refuses the queue, saying so (L110).
touch "$FX/hang-prs"
t0=$(date +%s)
out="$(SLEEP_GH_TIMEOUT=2 sleep_queue "$ROOT" s1)"; rc=$?
t1=$(date +%s)
rm -f "$FX/hang-prs"
check_eq "a hung GitHub read refuses the queue" 3 "$rc"
check_has "saying it was stopped at its deadline" "took longer than 2s and was stopped" "$out"
check_eq "well inside the hang" yes "$([ $((t1 - t0)) -lt 20 ] && echo yes || echo "no, $((t1 - t0))s")"
hp="$(cat "$FX/hang.pid" 2>/dev/null)"
check_eq "the hung read really ran, and is stopped with it" "ran stopped" "$([ -n "$hp" ] && echo ran || echo never) $([ -n "$hp" ] && kill -0 "$hp" 2>/dev/null && echo running || echo stopped)"

# The real gh path (no injected source) with a stand-in gh that hangs: the very first call is
# stopped at the deadline and named as that, never read as no account seeing the repository.
mkdir -p "$WORK/hangbin"
printf '#!/bin/sh\necho $$ > "%s"\nexec sleep 30\n' "$WORK/hanggh.pid" > "$WORK/hangbin/gh"; chmod +x "$WORK/hangbin/gh"
t0=$(date +%s)
out="$(PATH="$WORK/hangbin:$PATH" SLEEP_QUEUE_SOURCE= SLEEP_GH_TIMEOUT=2 sleep_queue "$ROOT" s1)"; rc=$?
t1=$(date +%s)
check_eq "a hung gh refuses the queue" 3 "$rc"
check_has "named as GitHub not answering in time" "GitHub did not answer within 2s" "$out"
check_eq "within one deadline, not the hang" yes "$([ $((t1 - t0)) -lt 15 ] && echo yes || echo "no, $((t1 - t0))s")"
hp="$(cat "$WORK/hanggh.pid" 2>/dev/null)"
check_eq "the stand-in gh really ran, and is stopped" "ran stopped" "$([ -n "$hp" ] && echo ran || echo never) $([ -n "$hp" ] && kill -0 "$hp" 2>/dev/null && echo running || echo stopped)"

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

# Awake, there is no night to queue for.
awake
out="$(sleep_queue "$ROOT" s1)"; rc=$?
check_eq "awake, the queue refuses" 3 "$rc"
check_has "saying the Mac is not asleep" "not asleep" "$out"
asleep

# ---- claims ----
# Two, then eight, claimers at once on one issue: exactly one owner, one entry.
race(){ # issue count
  local i
  for i in $(seq 1 "$2"); do
    session "r$1-$i" "$((NOW - 1000))" null
    ( sleep_claim "$ROOT" "$1" "r$1-$i" > "$WORK/race-$1-$i" 2>&1; echo $? >> "$WORK/race-$1-$i" ) &
  done
  wait
  cat "$WORK"/race-"$1"-* | grep -c '^claimed' | tr -d ' '
}
check_eq "two claimers at once: exactly one owns it" 1 "$(race 21 2)"
check_eq "and one entry was made" "1 " "$(claims_of 21)"
check_eq "eight claimers at once: exactly one owns it" 1 "$(race 22 8)"
check_eq "and still one entry" "1 " "$(claims_of 22)"
check_eq "every loser says the issue is held" 7 "$(cat "$WORK"/race-22-* | grep -c "^not-claimed.*held" | tr -d ' ')"
# Racers sharing $$ and RANDOM state (forked subshells, here seeded alike) still make exactly one
# owner, and the one that says it won is the session its entry names: a shared temp name would let
# one racer link another's entry and believe the claim its own.
same_race(){ # issue count
  local i
  for i in $(seq 1 "$2"); do
    session "q$1-$i" "$((NOW - 1000))" null
    ( RANDOM=7; sleep_claim "$ROOT" "$1" "q$1-$i" > "$WORK/same-$1-$i" 2>&1 ) &
  done
  wait
}
for r in 51 52 53 54 55; do
  same_race "$r" 8
  won="$(grep -l '^claimed' "$WORK"/same-"$r"-* 2>/dev/null | wc -l | tr -d ' ')"
  check_eq "racers sharing RANDOM on #$r: exactly one says it won" 1 "$won"
  winner="$(grep -l '^claimed' "$WORK"/same-"$r"-* 2>/dev/null | sed 's#.*/same-##')"
  check_has "and #$r's entry names that racer" "\"session\": \"q$winner\"" "$(cat "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/$r/1" 2>/dev/null)"
done

# The control: the same library with the link swapped for a copy must let several claimers own one
# issue, or the race above proves nothing about the link (L1).
CTRL="$WORK/control"; mkdir -p "$CTRL"
cp "$DIR/lib/sleep.sh" "$DIR/lib/sleep-queue.py" "$CTRL/"
awk '{ if (index($0, "if err=\"$(ln \"$tmp\"")) sub("[(]ln ", "(cp "); print }' "$LIB" > "$CTRL/sleep-queue.sh"
check_eq "the control swapped the link for a copy" 1 "$(grep -c 'if err="$(cp "$tmp"' "$CTRL/sleep-queue.sh" | tr -d ' ')"
owners="$( . "$CTRL/sleep-queue.sh" && race 41 8 )"
check_eq "without the link, eight claimers at once make more than one owner" yes "$([ "${owners:-0}" -gt 1 ] && echo yes || echo "no, $owners")"

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
check_has "the queue leaves a held issue out for everyone else" "$(printf 'skip\t9\tclaim held')" "$(sleep_queue "$ROOT" s2)"
check_has "but its holder still sees it, to carry on" "$(printf 'next\t9\tp0\tattempts=1\tmine')" "$(sleep_queue "$ROOT" s1)"

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
out="$(sleep_queue "$ROOT" s2)"; rc=$?
check_eq "a registry record changed just now that cannot be read refuses the queue" 3 "$rc"
check_has "naming the record, since it may be a live session's" "cannot be read (s4.json)" "$out"
touch -t 202001010000 "$HOME/.claude/state/sessions/s4.json"
out="$(sleep_queue "$ROOT" s2)"; rc=$?
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
check_has "the queue leaves a parked issue out, with why" "$(printf 'skip\t9\tclaim ended: parked: two hours with no progress')" "$(sleep_queue "$ROOT" s1)"
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
check_has "a dead worker's issue is carried on despite its pull request" "$(printf 'next\t13\t')" "$(sleep_queue "$ROOT" s2)"
printf '{"kind":"free","session":"ghost2","at":2}' > "$c13/2"
check_has "one its holder released on purpose is judged afresh, and its pull request keeps it out" "$(printf 'skip\t13\topen pull request #40 names it')" "$(sleep_queue "$ROOT" s2)"
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
out="$(sleep_queue "$ROOT" s2)"; rc=$?
check_eq "and the queue refuses" 3 "$rc"
mv "$WORK/sessions-aside" "$HOME/.claude/state/sessions"

# ---- next: queue, claim, worktree ----
rm -rf "$HOME/.claude/state/sleep/claims"
# A claim refused outright stops next with that refusal, never read as an issue someone holds.
mkdir -p "$HOME/.claude/state/sleep/claims/g1/danwright32__demo"
chmod 555 "$HOME/.claude/state/sleep/claims/g1/danwright32__demo"
out="$(sleep_next "$ROOT" s1)"; rc=$?
chmod 755 "$HOME/.claude/state/sleep/claims/g1/danwright32__demo"
check_eq "next stops on a refused claim" 3 "$rc"
check_has "with the refusal itself" "$(printf 'refused\t-\tthe claim folder')" "$out"
check_not "never saying nothing is left" "nothing left" "$out"
out="$(sleep_next "$ROOT" s1)"; rc=$?
check_eq "next claims something" 0 "$rc"
check_has "the first issue in the queue" "$(printf 'claimed\t9\tattempts=1\tworktree=%s/.claude/worktrees/sleep-9' "$ROOT")" "$out"
check_eq "in a worktree of its own, on its own branch" "sleep/9" "$(git -C "$ROOT/.claude/worktrees/sleep-9" branch --show-current 2>&1)"
check_eq "the primary checkout is left on its branch" "main" "$(git -C "$ROOT" branch --show-current)"
out="$(sleep_next "$ROOT" s2)"
check_has "a second worker gets the next issue" "$(printf 'claimed\t3\t')" "$out"
# A fetch that fails just now gives the issue back for a later pass, never ends it for the night.
mv "$WORK/demo.git" "$WORK/demo.git.aside"
session s9 "$((NOW - 1000))" null
out="$(sleep_next "$ROOT" s9)"; rc=$?
mv "$WORK/demo.git.aside" "$WORK/demo.git"
check_eq "with no fetch possible, nothing is started" 1 "$rc"
check_has "the issue is given back, saying so" "$(printf 'skip\t5\tclaimed but could not start (given back for a later pass): git fetch')" "$out"
check_has "its claim ends unstarted" '"kind": "unstarted"' "$(cat "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/5/2" 2>/dev/null)"
check_has "so a later pass claims it again, with no attempt spent" "$(printf 'next\t5\tp2\tattempts=0\tfree')" "$(sleep_queue "$ROOT" s9)"
# A claim lost between the queue and the claim is said on a skip line, never dropped.
out="$( sleep_claim(){ printf 'not-claimed\t%s\theld: session zz holds it\n' "$2"; return 1; }; sleep_next "$ROOT" s9 )"
check_has "a claim lost after the queue is a skip line with its reason" "$(printf 'skip\t5\tnot claimed: held: session zz holds it')" "$out"
# A repository whose git folder lives elsewhere still gets its worktree beside its checkout.
git clone -q --separate-git-dir "$WORK/sep.git" "$WORK/demo.git" "$WORK/seprepo"
check_eq "a separate git folder puts the worktree beside the checkout" "$WORK/seprepo/.claude/worktrees/sleep-31" "$(sleep_worktree "$WORK/seprepo" 31 2>&1)"
# A fetch that hangs is stopped at its deadline and gives the issue back (L110). The remote is an
# ssh one whose ssh is a script that only waits, so nothing leaves this machine.
git clone -q "$WORK/demo.git" "$WORK/hangrepo"
git -C "$WORK/hangrepo" config remote.origin.url git@github.com:danwright32/demo.git
printf '#!/bin/sh\necho $$ > "%s"\nexec sleep 30\n' "$WORK/hang.pid" > "$WORK/bin/hang-ssh"; chmod +x "$WORK/bin/hang-ssh"
t0=$(date +%s)
out="$(GIT_SSH_COMMAND="$WORK/bin/hang-ssh" SLEEP_FETCH_TIMEOUT=2 sleep_worktree "$WORK/hangrepo" 33 2>&1)"; rc=$?
t1=$(date +%s)
check_eq "a hung fetch gives the issue back" 2 "$rc"
check_has "saying it was stopped at its deadline" "took longer than 2s and was stopped" "$out"
check_eq "and returns well inside the hang" yes "$([ $((t1 - t0)) -lt 20 ] && echo yes || echo "no, $((t1 - t0))s")"
hp="$(cat "$WORK/hang.pid" 2>/dev/null)"
check_eq "the hung fetch's ssh really ran" yes "$([ -n "$hp" ] && echo yes || echo no)"
check_eq "and is stopped with it, not left running" no "$([ -n "$hp" ] && kill -0 "$hp" 2>/dev/null && echo yes || echo no)"
git init -q --bare "$WORK/bare.git"
out="$(sleep_worktree "$WORK/bare.git" 32 2>&1)"; rc=$?
check_eq "a bare repository is refused for good" 1 "$rc"
check_has "saying why" "is a bare repository" "$out"
out="$(sleep_next "$ROOT" s1)"
check_has "next for a holder carries on with its own issue" "$(printf 'claimed\t9\tattempts=1')" "$out"
check_has "in the worktree it already has" "worktree=$ROOT/.claude/worktrees/sleep-9" "$out"
# The holder of 9 dies: its branch is tonight's own work, which the next session carries on.
git -C "$WORK/repo/.claude/worktrees/sleep-9" push -q origin sleep/9
printf 'main\nfix-14-thing\nsleep/9\n' > "$FX/branches"
session s1 "$((NOW - 1000))" "$((NOW - 10))"
session s5 "$((NOW - 1000))" null
out="$(sleep_next "$ROOT" s5)"
check_has "a dead session's issue is taken over despite its own branch" "$(printf 'claimed\t9\tattempts=2')" "$out"
check_has "in the worktree the dead session left" "worktree=$ROOT/.claude/worktrees/sleep-9" "$out"
# Something else sitting where the worktree goes is never adopted (L421), and the claim ends failed.
mkdir -p "$ROOT/.claude/worktrees/sleep-5"; echo stranger > "$ROOT/.claude/worktrees/sleep-5/file"
session s6 "$((NOW - 1000))" null
# The worktree's reason never goes through a temp file, so nothing is left in the temp folder.
mkdir -p "$WORK/tmp6"
out="$(TMPDIR="$WORK/tmp6" sleep_next "$ROOT" s6)"
check_eq "next leaves no temp file for a worktree's failure" "" "$(ls -A "$WORK/tmp6")"
check_has "a folder that is not this issue's worktree is refused" "is not a worktree of" "$out"
check_has "the claim is ended as failed, never left held" '"kind": "failed"' "$(cat "$HOME/.claude/state/sleep/claims/g1/danwright32__demo/5/4" 2>/dev/null)"
check_has "and next goes on to the issue after it" "$(printf 'claimed\t16\t')" "$out"
first="${out%%$'\n'*}"
check_eq "its one result line comes first" claimed "${first%%$'\t'*}"
check_has "the issue it could not start follows as a skip line" "$(printf 'skip\t5\tclaimed but could not start (ended for tonight):')" "$out"
session s7 "$((NOW - 1000))" null
check_has "the last one goes to the next worker" "$(printf 'claimed\t7\t')" "$(sleep_next "$ROOT" s7)"
session s8 "$((NOW - 1000))" null
out="$(sleep_next "$ROOT" s8)"; rc=$?
check_eq "with nothing left, next says none" 1 "$rc"
check_has "plainly" "none" "$out"

# ---- the report's read of every claim (phase 4, #835) ----
out="$(sleep_claims_json)"
check_has "every claim of the night as one JSON line" '"repo": "danwright32/demo", "issue": 9, "attempts": 2' "$out"
check_has "with its history" '"kind": "failed"' "$out"

# ---- run as a command ----
out="$(bash "$LIB" queue "$ROOT" s7)"; rc=$?
check_eq "run as a command, the queue answers" 0 "$rc"
check_has "the same lines" "$(printf 'skip\t9\t')" "$out"
check_eq "an unknown command is refused" 2 "$(bash "$LIB" frobnicate >/dev/null 2>&1; echo $?)"
# The judgments alone: sleep-queue.py refuses a queue it was not given every input for.
out="$(python3 "$DIR/lib/sleep-queue.py" queue repo=danwright32/demo)"; rc=$?
check_eq "sleep-queue.py refuses a queue missing an input" 3 "$rc"
check_has "naming it" "was not given limit" "$out"

# ---- the seams fired, and nothing reached GitHub ----
check_eq "the stub source was the one asked" yes "$([ -s "$WORK/source.log" ] && echo yes || echo no)"
check_eq "gh itself was never called" "" "$(cat "$WORK/gh-called" 2>/dev/null)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
