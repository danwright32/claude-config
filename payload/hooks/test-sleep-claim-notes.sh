#!/usr/bin/env bash
# Tests that a claim and its end reach the night's report (claude-config#844): lib/sleep-queue.sh is
# the one writer of a claim and of its end, so it is the one writer of the matching notes too. The
# report (lib/sleep-report.py, #835) flags a claim with no done, parked or failed note as ended
# unexpectedly, so a claim released as done or parked must never read that way, and one given back
# must say it was given back.
#
# Nothing here reaches GitHub: HOME is this suite's own folder, and a `gh` first on PATH answers the
# wake render's lists with nothing, logging every call (L2, L143).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/sleep-queue.sh"
PY="$DIR/lib/sleep-report.py"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:600}')"; fi; }
has(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (wanted '$2' in: ${3:0:1500})"; fi; }
lacks(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (did not want '$2' in: ${3:0:1500})"; fi; }

export HOME="$WORK/home"
SLEEPDIR="$HOME/.claude/state/sleep"
mkdir -p "$SLEEPDIR" "$HOME/.claude/state/sessions" "$WORK/bin"
# GitHub, standing in: issue 21 closed tonight, and nothing else.
cat > "$WORK/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/gh-called"
if [ "\$1 \$2" = "issue list" ]; then cat "$WORK/closed.json"; else echo '[]'; fi
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

NOW="$(date +%s)000"
export SLEEP_NOW_MS="$NOW"
printf '[{"number":21,"title":"Issue 21","closedAt":"%s","stateReason":"COMPLETED"}]' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/closed.json"
export SLEEP_REPORT_NOW_MS="$NOW"

git -c init.defaultBranch=main init -q "$WORK/repo"
git -C "$WORK/repo" config remote.origin.url https://github.com/danwright32/demo.git
ROOT="$WORK/repo"

boot="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')"
[ -n "$boot" ] || boot=1
printf '{"v":1,"generation":"g1","since":%s,"until":%s,"night":"2026-10-07","bootTime":%s,"report":"%s/report.md","startedBy":{"sessionId":"s1","cwd":"%s"},"workers":["s1"],"placeBefore":"home"}' \
  "$((NOW - 1000))" "$((NOW + 3600000))" "$boot" "$WORK" "$ROOT" > "$SLEEPDIR/current.json"
printf '{"v":1,"sessionId":"s1","cwd":"%s","repoRoot":null,"startedAt":1,"lastSeen":%s,"closedAt":null,"transcriptPath":null,"edits":[]}' "$ROOT" "$NOW" > "$HOME/.claude/state/sessions/s1.json"

if ! . "$LIB"; then
  echo "FAIL: $LIB could not be sourced"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
notes(){ cat "$SLEEPDIR/notes/g1.jsonl" 2>/dev/null; }
final(){ python3 "$PY" render --record "$SLEEPDIR/current.json" --final >/dev/null 2>&1; cat "$WORK/report.md" 2>/dev/null; }

# ---- a claim writes a claim note, naming the repo, issue and attempt ----
out="$(sleep_claim "$ROOT" 21 s1 2>&1)"
has "issue 21 is claimed" "$(printf 'claimed\t21\tattempts=1')" "$out"
has "the claim is noted with its repo and issue" '"kind":"claim","by":"s1","repo":"danwright32/demo","issue":21,"attempts":1' "$(notes)"

# ---- claimed then released done: done in the report, never ended unexpectedly ----
out="$(sleep_release "$ROOT" 21 s1 done "merged as PR #4" 2>&1)"
has "issue 21 is released done" "$(printf 'released\t21\tdone')" "$out"
has "the end is noted as done, with the reason as its text" '"kind":"done","by":"s1","repo":"danwright32/demo","issue":21,"text":"merged as PR #4"' "$(notes)"

# ---- claimed then parked: parked in the report ----
sleep_claim "$ROOT" 22 s1 >/dev/null 2>&1
sleep_release "$ROOT" 22 s1 parked "two hours with no way through" >/dev/null 2>&1
# ---- claimed then failed ----
sleep_claim "$ROOT" 23 s1 >/dev/null 2>&1
sleep_release "$ROOT" 23 s1 failed "the build tool is missing" >/dev/null 2>&1
# ---- claimed then given back: said as given back, not as ended unexpectedly ----
sleep_claim "$ROOT" 24 s1 >/dev/null 2>&1
sleep_release "$ROOT" 24 s1 free "the network dropped" >/dev/null 2>&1
# ---- claimed and never ended: the one that IS flagged, so the flag is proved able to fire ----
sleep_claim "$ROOT" 25 s1 >/dev/null 2>&1

# ---- notes landing out of order (concurrent writers): judged by when each was written, L751 ----
# #30 was claimed, given back, then claimed again and never ended, but the give back landed last.
rec="$SLEEPDIR/current.json"
sleep_note "{\"kind\":\"claim\",\"by\":\"s1\",\"repo\":\"danwright32/demo\",\"issue\":30,\"attempts\":1,\"at\":$((NOW - 3000))}" "$rec" >/dev/null 2>&1
sleep_note "{\"kind\":\"claim\",\"by\":\"s1\",\"repo\":\"danwright32/demo\",\"issue\":30,\"attempts\":2,\"at\":$((NOW - 1000))}" "$rec" >/dev/null 2>&1
sleep_note "{\"kind\":\"released\",\"by\":\"s1\",\"repo\":\"danwright32/demo\",\"issue\":30,\"state\":\"free\",\"at\":$((NOW - 2000))}" "$rec" >/dev/null 2>&1

r="$(final)"
lacks "a give back that came before a later claim is not the end of that claim" "danwright32/demo#30 was given back" "$r"
has "the later claim of #30, never ended, is flagged" "danwright32/demo#30, claimed by s1" "$r"
has "the wake report renders" "# Sleep report" "$r"
has "the done claim shows under Done, as GitHub has it" "danwright32/demo issue #21 Issue 21, closed" "$r"
lacks "the done claim is never ended unexpectedly" "danwright32/demo#21, claimed" "$r"
has "the parked claim shows as parked" "Parked danwright32/demo#22: two hours with no way through" "$r"
lacks "the parked claim is never ended unexpectedly" "danwright32/demo#22, claimed" "$r"
has "the failed claim shows as failed" "Failed danwright32/demo#23: the build tool is missing" "$r"
lacks "the failed claim is never ended unexpectedly" "danwright32/demo#23, claimed" "$r"
has "the claim given back says so" "danwright32/demo#24 was given back" "$r"
lacks "the claim given back is never ended unexpectedly" "danwright32/demo#24, claimed" "$r"
has "a claim never ended is still flagged" "danwright32/demo#25, claimed by s1" "$r"
lacks "released is a kind the report knows, never under Other notes" "released from" "$r"

# ---- a release that does not happen writes no note ----
before="$(notes | wc -l | tr -d ' ')"
sleep_release "$ROOT" 21 s1 done "again" >/dev/null 2>&1
check_eq "an end refused (the claim already ended) writes no note" "$before" "$(notes | wc -l | tr -d ' ')"

# ---- a note that cannot be written is said, and the claim still stands (it is the record) ----
chmod 400 "$SLEEPDIR/notes/g1.jsonl"
if [ -w "$SLEEPDIR/notes/g1.jsonl" ]; then
  # Root ignores the mode, so the case cannot be set up here: said, never read as a pass or a fail (L411).
  chmod 600 "$SLEEPDIR/notes/g1.jsonl"
  echo "UNMEASURED: a notes file that cannot be written could not be made here (running as root?), so the lost note case was not run"
else
  out="$(sleep_claim "$ROOT" 26 s1 2>&1)"; rc=$?
  chmod 600 "$SLEEPDIR/notes/g1.jsonl"
  check_eq "the claim still succeeds when its note cannot be written" 0 "$rc"
  has "the lost note is said" "the night's note of this claim could not be written" "$out"
fi

[ -s "$WORK/gh-called" ] || { fail=$((fail + 1)); echo "FAIL: the wake render never asked the gh stand-in, so the report was never checked as at wake"; }

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
