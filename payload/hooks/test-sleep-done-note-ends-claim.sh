#!/usr/bin/env bash
# Tests that a done note ends the claim it names (claude-config#3330). On the night of 2026-11-18 a
# session noted seven finished issues done with sleep_note and never released their claims, so the
# overnight watchdog went on timing finished work and parked it. A done note naming an issue now
# ends that session's own claim on it as done, in the same step, writing no second note. A claim
# another session holds, one already ended, or a note of any other kind is left exactly as it was.
#
# Nothing here reaches GitHub: HOME is this suite's own folder, and a `gh` first on PATH logs every
# call and answers nothing (L2, L143).
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
has(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (wanted '$2' in: ${3:0:1500})"; fi; }

export HOME="$WORK/home"
SLEEPDIR="$HOME/.claude/state/sleep"
mkdir -p "$SLEEPDIR" "$HOME/.claude/state/sessions" "$WORK/bin"
cat > "$WORK/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/gh-called"
echo '[]'
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
unset CLAUDE_CODE_SESSION_ID
# The record sleep_note judges by, this suite's own, never one the session running it was given.
export CLAUDE_SLEEP_RECORD="$SLEEPDIR/current.json"

NOW="$(date +%s)000"
export SLEEP_NOW_MS="$NOW"

git -c init.defaultBranch=main init -q "$WORK/repo"
git -C "$WORK/repo" config remote.origin.url https://github.com/danwright32/demo.git
ROOT="$WORK/repo"

boot="$(bash -c '. "$1" && sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)"' _ "$DIR/lib/sleep.sh")"
[ -n "$boot" ] || boot=1
printf '{"v":1,"generation":"g1","since":%s,"until":%s,"night":"2026-11-18","bootTime":%s,"report":"%s/report.md","startedBy":{"sessionId":"s1","cwd":"%s"},"workers":["s1","s2"],"placeBefore":"home"}' \
  "$((NOW - 1000))" "$((NOW + 3600000))" "$boot" "$WORK" "$ROOT" > "$SLEEPDIR/current.json"
for s in s1 s2; do
  printf '{"v":1,"sessionId":"%s","cwd":"%s","repoRoot":null,"startedAt":1,"lastSeen":%s,"closedAt":null,"transcriptPath":null,"edits":[]}' "$s" "$ROOT" "$NOW" > "$HOME/.claude/state/sessions/$s.json"
done

if ! . "$LIB"; then
  echo "FAIL: $LIB could not be sourced"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
CLAIMS="$SLEEPDIR/claims/g1/danwright32__demo"
# The newest entry of an issue's claim, as KIND SESSION, the state the watchdog and the queue read.
last(){ python3 -c 'import json, os, sys
d = sys.argv[1]
ns = sorted(int(n) for n in os.listdir(d) if n.isdigit())
e = json.load(open(os.path.join(d, str(ns[-1]))))
print("%s %s %d" % (e.get("kind"), e.get("session"), len(ns)))' "$CLAIMS/$1"; }
# How many notes of a kind name an issue.
count(){ python3 -c 'import json, sys
n = 0
for line in open(sys.argv[1]):
    try:
        x = json.loads(line)
    except ValueError:
        continue
    n += x.get("kind") == sys.argv[2] and x.get("issue") == int(sys.argv[3])
print(n)' "$SLEEPDIR/notes/g1.jsonl" "$1" "$2"; }

# ---- a done note by the session holding the claim ends it as done, with no second note ----
sleep_claim "$ROOT" 31 s1 >/dev/null 2>&1
check_eq "issue 31 is claimed by s1" "claim s1 1" "$(last 31)"
out="$(sleep_note '{"kind":"done","by":"s1","repo":"danwright32/demo","issue":31,"pr":5,"text":"merged"}' 2>"$WORK/err")"
check_eq "the done note is written (exit 0)" "0" "$?"
check_eq "sleep_note still prints nothing on stdout" "" "$out"
check_eq "the done note ended the claim as done" "done s1 2" "$(last 31)"
check_eq "exactly one done note names issue 31" "1" "$(count done 31)"
has "the session is told its claim is ended" "the claim on #31 is ended as done" "$(cat "$WORK/err")"

# ---- run twice: a second done note leaves the ended claim as it is ----
sleep_note '{"kind":"done","by":"s1","repo":"danwright32/demo","issue":31,"pr":6,"text":"follow up"}' 2>/dev/null
check_eq "a second done note adds no entry" "done s1 2" "$(last 31)"

# ---- the session's own id, when the note names nobody, as the note writer stamps it ----
sleep_claim "$ROOT" 32 s1 >/dev/null 2>&1
CLAUDE_CODE_SESSION_ID=s1 sleep_note '{"kind":"done","repo":"danwright32/demo","issue":32,"pr":7,"text":"merged"}' 2>/dev/null
check_eq "a done note naming nobody is read as the writing session's" "done s1 2" "$(last 32)"

# ---- the repository as GitHub shows it, in any case, names the same claim ----
sleep_claim "$ROOT" 33 s1 >/dev/null 2>&1
sleep_note '{"kind":"done","by":"s1","repo":"DanWright32/Demo","issue":33,"pr":8,"text":"merged"}' 2>/dev/null
check_eq "a repository named in other case ends the same claim" "done s1 2" "$(last 33)"

# ---- another session's done note never ends s1's claim ----
sleep_claim "$ROOT" 34 s1 >/dev/null 2>&1
sleep_note '{"kind":"done","by":"s2","repo":"danwright32/demo","issue":34,"pr":9,"text":"merged"}' 2>"$WORK/err"
check_eq "another session's done note leaves the claim held" "claim s1 1" "$(last 34)"
check_eq "and says nothing about a claim it does not hold" "" "$(cat "$WORK/err")"

# ---- a progress note, or a done note naming only a pull request, ends nothing ----
sleep_note '{"kind":"progress","by":"s1","repo":"danwright32/demo","issue":34,"text":"tests pass"}' 2>/dev/null
check_eq "a progress note leaves the claim held" "claim s1 1" "$(last 34)"
sleep_note '{"kind":"done","by":"s1","repo":"danwright32/demo","pr":10,"text":"merged"}' 2>"$WORK/err"
check_eq "a done note naming no issue leaves the claim held" "claim s1 1" "$(last 34)"
check_eq "and says nothing" "" "$(cat "$WORK/err")"
sleep_note '{"kind":"done","by":"s1","repo":"danwright32/other","issue":34,"pr":10,"text":"merged"}' 2>/dev/null
check_eq "a done note for another repository leaves the claim held" "claim s1 1" "$(last 34)"

# ---- a claim the watchdog already parked stays parked: the report reads the done over it ----
sleep_claim "$ROOT" 35 s1 >/dev/null 2>&1
SLEEP_NOTE_BY_DRIVER=1 sleep_release "$ROOT" 35 s1 parked "120 minutes of active work on it" >/dev/null 2>&1
rm -f "$WORK/gh-called"
sleep_note '{"kind":"done","by":"s1","repo":"danwright32/demo","issue":35,"pr":11,"text":"merged"}' 2>/dev/null
check_eq "the done note was still written" "1" "$(count done 35)"
check_eq "the park stands in the claim" "parked s1 2" "$(last 35)"
check_eq "and GitHub was not asked: a done note ends a claim offline" "no" "$([ -e "$WORK/gh-called" ] && echo yes || echo no)"

# ---- the release the rules name still ends a claim with exactly one done note ----
sleep_claim "$ROOT" 36 s1 >/dev/null 2>&1
out="$(sleep_release "$ROOT" 36 s1 done "merged as PR #12" 2>&1)"
has "release done still releases" "$(printf 'released\t36\tdone')" "$out"
check_eq "the release's own done note ends nothing more" "done s1 2" "$(last 36)"
check_eq "exactly one done note names issue 36" "1" "$(count done 36)"

# ---- a note not written ends nothing ----
sleep_claim "$ROOT" 37 s1 >/dev/null 2>&1
sleep_note '{"kind":"done","by":"s1","repo":"danwright32/demo","issue":37,"text":"merged","pr":"x"}' 2>/dev/null
check_eq "a refused done note exits 1" "1" "$?"
check_eq "and leaves the claim held" "claim s1 1" "$(last 37)"

# ---- a reader that crashes is a fault said as one, never read as a note naming nothing ----
printf 'import sys\nsys.exit(1)\n' > "$WORK/crash.py"
out="$(_SQ_PY="$WORK/crash.py" sleep_done_noted '{"kind":"done","by":"s1","repo":"danwright32/demo","issue":37,"pr":13}')"
check_eq "a crashed reader is refused (exit 3)" "3" "$?"
has "and says the note could not be read" "the done note could not be read" "$out"
check_eq "and the claim is left held" "claim s1 1" "$(last 37)"

# ---- a claim that could not be ended is said, with what to run ----
sleep_note '{"kind":"done","by":"s 1","repo":"danwright32/demo","issue":37,"pr":14,"text":"merged"}' 2>"$WORK/err"
has "a claim the queue refused to end is said on stderr" "end it with sleep-queue.sh release" "$(cat "$WORK/err")"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
