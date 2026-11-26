#!/usr/bin/env bash
# Tests for old-pull-requests.py, the rows /next-issue shows ahead of its ranked issues
# (claude-config#3614).
#
# While a session is alive its pull request is looked after; once it ends, nothing looks at one it
# left open, and /next-issue ranked open issues only. The helper lists the signed in account's open
# pull requests in the session's repository, keeps those older than 3 days, and gives each a state
# derived from what gh returns: conflicting, checks red, approved and waiting, draft, or waiting.
#
# Pure: gh is a fake that prints recorded answers, so nothing reaches GitHub. The two fixtures are
# real answers of `gh pr list --author @me --state open` in danwright32/claude-config, measured on
# 2026-11-26 about a minute apart (41 rows each after one fresh row was left out; each check trimmed
# to the four fields the helper reads). The first read is what GitHub gives before it has worked out
# mergeability (UNKNOWN on 37 of the 41 rows, two of the three old ones among them); the second is
# after, with none UNKNOWN. Cases needing a shape no open pull
# request had that day (draft, approved, changes requested, a commit status, a cancelled check) are
# that measured #3487 row with the one field changed, and say so.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/old-pull-requests.py"
SKILL="$DIR/SKILL.md"
FIRST="$DIR/fixtures/open-prs-measured-2026-11-26-first-read.json"
SECOND="$DIR/fixtures/open-prs-measured-2026-11-26-second-read.json"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
same(){ if [ "$2" = "$3" ]; then check "$1" ok; else check "$1" "expected [$2], got [$3]"; fi; }
has(){ case "$3" in *"$2"*) check "$1" ok ;; *) check "$1" "no [$2] in [$3]" ;; esac; }
lacks(){ case "$3" in *"$2"*) check "$1" "unexpected [$2] in [$3]" ;; *) check "$1" ok ;; esac; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/old-pull-requests-test.XXXXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# The fake gh: records each call's arguments, prints the answer it is given, and exits as told.
FAKE="$SCRATCH/gh"
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_CALLS"
if [ -n "${FAKE_GH_STDERR:-}" ]; then printf '%s\n' "$FAKE_GH_STDERR" >&2; fi
if [ -n "${FAKE_GH_OUT:-}" ]; then cat "$FAKE_GH_OUT"; fi
if [ -n "${FAKE_GH_SLEEP:-}" ]; then exec sleep "$FAKE_GH_SLEEP"; fi
exit "${FAKE_GH_EXIT:-0}"
SH
chmod +x "$FAKE"
CALLS="$SCRATCH/calls"

# run <answer file or empty> <gh exit> [helper args...]: sets out (stdout), err (stderr), code.
run(){
  local answer="$1" ghexit="$2"; shift 2
  : > "$CALLS"
  OLD_PRS_GH="$FAKE" FAKE_GH_CALLS="$CALLS" FAKE_GH_OUT="$answer" FAKE_GH_EXIT="$ghexit" \
    python3 "$HELPER" "$@" > "$SCRATCH/out" 2> "$SCRATCH/err"
  code=$?
  out="$(cat "$SCRATCH/out")"; err="$(cat "$SCRATCH/err")"
}
rows(){ printf '%s\n' "$out" | grep '^OLD PR #' | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//'; }
row(){ printf '%s\n' "$out" | grep "^OLD PR #$1 " ; }

# A variant of the measured #3487 row, with one field changed: variant <name> <python expression on p>.
variant(){
  python3 -I -c '
import json, sys
rows = [p for p in json.load(open(sys.argv[1])) if p["number"] == 3487]
p = rows[0]
exec(sys.argv[2])
json.dump([p], open(sys.argv[3], "w"))
' "$SECOND" "$2" "$SCRATCH/$1.json"
  printf '%s' "$SCRATCH/$1.json"
}

NOW=2026-11-26T07:00:00Z

# --- The measured second read: three of the 41 are older than 3 days, oldest first --------------
run "$SECOND" 0 --now "$NOW"
same "the measured list is read without error" 0 "$code"
same "only the pull requests older than 3 days are listed, oldest first" "#3487 #3489 #3490" "$(rows)"
has "a conflicting pull request says so (measured #3489, mergeable CONFLICTING)" "conflicting" "$(row 3489)"
has "a pull request with green checks and no review is waiting (measured #3487)" "waiting" "$(row 3487)"
lacks "a waiting pull request is not called conflicting" "conflicting" "$(row 3487)"
has "a row carries its age in days" "3 days" "$(row 3490)"
has "a row carries its title" "Design round guard: a probe written into a script's text" "$(row 3490)"
has "a row offers Finish this" "Finish this" "$out"
has "the count line says how many of the open pull requests are old" "3 of 41" "$out"
same "the helper says nothing on stderr when it succeeds" "" "$err"

# One gh call, for the signed in account's open pull requests in the repository it runs in: never
# a --repo, so it cannot read another repository, and never a second call.
same "gh is called exactly once" 1 "$(grep -c . "$CALLS")"
has "the call lists open pull requests by the signed in account" "pr list --author @me --state open" "$(cat "$CALLS")"
has "the call passes its limit" "--limit 200" "$(cat "$CALLS")"
lacks "the call names no repository, so it reads only the one it runs in" "--repo" "$(cat "$CALLS")"
lacks "the call names no repository by -R either" " -R " "$(cat "$CALLS")"

# --- The measured first read: GitHub had not worked out mergeability, which is not "no conflict" -
run "$FIRST" 0 --now "$NOW"
same "the first read lists the same three" "#3487 #3489 #3490" "$(rows)"
has "a pull request GitHub has not checked for conflicts says so (measured UNKNOWN)" "not yet checked for conflicts" "$(row 3489)"
lacks "an unchecked pull request is not called conflicting" "conflicting" "$(row 3487)"

# --- Checks red, measured: #3532 has a failed check, #3519 is conflicting with a failed check ------
run "$SECOND" 0 --now 2026-11-28T00:00:00Z
has "a failed check run is checks red (measured #3532)" "checks red" "$(row 3532)"
lacks "a failed check run is not called conflicting (measured #3532)" "conflicting" "$(row 3532)"
has "conflicting and red together name both (measured #3519)" "conflicting, checks red" "$(row 3519)"
lacks "green checks are not red (measured #3490)" "checks red" "$(row 3490)"

# --- The 3 day edge on both sides, from #3490's own createdAt (2026-11-23T06:53:13Z) ------------
run "$SECOND" 0 --now 2026-11-26T06:53:14Z
has "one second past 3 days is listed" "#3490" "$(rows)"
run "$SECOND" 0 --now 2026-11-26T06:53:13Z
lacks "exactly 3 days is not older than 3 days" "#3490" "$(rows)"
run "$SECOND" 0 --now 2026-11-26T06:53:12Z
lacks "one second short of 3 days is not listed" "#3490" "$(rows)"
same "one second short of 3 days still lists the older two" "#3487 #3489" "$(rows)"

# --- Nothing old, nothing open: nothing printed and exit 0, so the skill shows only issues -------
run "$SECOND" 0 --now 2026-11-24T00:00:00Z
same "open pull requests none older than 3 days exit 0" 0 "$code"
same "open pull requests none older than 3 days print nothing" "" "$out$err"
printf '[]\n' > "$SCRATCH/none.json"
run "$SCRATCH/none.json" 0 --now "$NOW"
same "no open pull requests exit 0" 0 "$code"
same "no open pull requests print nothing" "" "$out$err"

# --- States with no measured example that day: #3487 with one field changed ----------------------
run "$(variant draft 'p["isDraft"] = True')" 0 --now "$NOW"
has "a draft says draft (#3487 with isDraft true)" "draft" "$(row 3487)"
run "$(variant approved 'p["reviewDecision"] = "APPROVED"')" 0 --now "$NOW"
has "an approved pull request with nothing in its way is approved and waiting" "approved and waiting" "$(row 3487)"
run "$(variant approved_red 'p["reviewDecision"] = "APPROVED"; p["statusCheckRollup"][1]["conclusion"] = "FAILURE"')" 0 --now "$NOW"
has "approved with a red check names the red check" "checks red" "$(row 3487)"
lacks "approved with a red check is not called waiting" "approved and waiting" "$(row 3487)"
run "$(variant changes 'p["reviewDecision"] = "CHANGES_REQUESTED"')" 0 --now "$NOW"
has "changes requested says so" "changes requested" "$(row 3487)"
run "$(variant status_error 'p["statusCheckRollup"].append({"__typename": "StatusContext", "context": "ci", "state": "ERROR"})')" 0 --now "$NOW"
has "a commit status in error is checks red" "checks red" "$(row 3487)"
run "$(variant cancelled 'p["statusCheckRollup"][0]["conclusion"] = "CANCELLED"')" 0 --now "$NOW"
has "a cancelled check is checks red" "checks red" "$(row 3487)"
run "$(variant running 'p["statusCheckRollup"][0]["status"] = "IN_PROGRESS"; p["statusCheckRollup"][0]["conclusion"] = ""')" 0 --now "$NOW"
lacks "a check still running is not red" "checks red" "$(row 3487)"
run "$(variant nochecks 'p["statusCheckRollup"] = None')" 0 --now "$NOW"
same "a pull request with no checks at all is read" 0 "$code"
has "a pull request with no checks at all is waiting" "waiting" "$(row 3487)"

# --- gh failed or answered something unreadable: an error, never an empty list read as none ------
FAKE_GH_STDERR='failed to run git: fatal: not a git repository (or any of the parent directories): .git' \
  run "" 1 --now "$NOW"
same "gh failing exits 2" 2 "$code"
same "gh failing prints no rows" "" "$out"
has "gh failing says the pull requests could not be listed" "could not list" "$err"
has "gh failing passes on gh's own words (measured outside a checkout)" "not a git repository" "$err"
printf 'not json' > "$SCRATCH/bad.json"
run "$SCRATCH/bad.json" 0 --now "$NOW"
same "an answer that is not JSON exits 2" 2 "$code"
has "an answer that is not JSON is named as such" "not JSON" "$err"
: > "$SCRATCH/empty.json"
run "$SCRATCH/empty.json" 0 --now "$NOW"
same "an empty answer with exit 0 exits 2, never none" 2 "$code"
has "an empty answer is named as such" "empty" "$err"
printf '{"number": 1}' > "$SCRATCH/object.json"
run "$SCRATCH/object.json" 0 --now "$NOW"
same "an answer that is not a list exits 2" 2 "$code"
has "an answer that is not a list is named as such" "not a list" "$err"
run "$(variant nodate 'del p["createdAt"]')" 0 --now "$NOW"
same "a row with no createdAt exits 2" 2 "$code"
has "a row with no createdAt names the field" "createdAt" "$err"
same "a row with no createdAt prints no rows" "" "$out"
OLD_PRS_GH="$SCRATCH/no-such-gh" python3 "$HELPER" --now "$NOW" > "$SCRATCH/out" 2> "$SCRATCH/err"; code=$?
same "gh that cannot be run exits 2" 2 "$code"
has "gh that cannot be run says so" "could not run gh" "$(cat "$SCRATCH/err")"
: > "$CALLS"
OLD_PRS_GH="$FAKE" FAKE_GH_CALLS="$CALLS" FAKE_GH_SLEEP=20 OLD_PRS_GH_TIMEOUT=1 \
  python3 "$HELPER" --now "$NOW" > "$SCRATCH/out" 2> "$SCRATCH/err"; code=$?
same "gh that does not answer in time exits 2" 2 "$code"
has "gh that does not answer in time says how long it waited" "did not answer within 1 second" "$(cat "$SCRATCH/err")"
run "$SECOND" 0 --now not-a-date
same "a --now that is not a date exits 2" 2 "$code"
has "a --now that is not a date is named" "--now" "$err"

# --- More rows than the limit: the list gh gives is newest first, so the cut drops the OLDEST ------
python3 -I -c '
import json, sys
base = [p for p in json.load(open(sys.argv[1])) if p["number"] == 3487][0]
for count, name in ((200, "full"), (199, "under")):
    json.dump([dict(base, number=1000 + i) for i in range(count)], open(sys.argv[2] + "/" + name + ".json", "w"))
' "$SECOND" "$SCRATCH"
run "$SCRATCH/full.json" 0 --now "$NOW"
same "a list as long as its limit exits 3" 3 "$code"
has "a cut off list says to raise the limit" "--limit" "$err"
same "a cut off list prints no rows" "" "$out"
run "$SCRATCH/under.json" 0 --now "$NOW"
same "a list one short of its limit is read" 0 "$code"
same "a list one short of its limit lists every old row" 199 "$(printf '%s\n' "$out" | grep -c '^OLD PR #')"
run "$SCRATCH/full.json" 0 --now "$NOW" --limit 300
same "a raised limit reads the 200" 0 "$code"
has "a raised limit is passed to gh" "--limit 300" "$(cat "$CALLS")"

# --- The skill runs the helper and shows its rows ahead of the ranked issues ---------------------
# Asserted with grep, so a failure names the missing text rather than printing the whole skill (L445).
in_skill(){ if grep -qF -- "$2" "$SKILL"; then check "$1" ok; else check "$1" "no [$2] in SKILL.md"; fi; }
in_skill "the skill runs the helper" "old-pull-requests.py"
helper_at="$(grep -n -m 1 'old-pull-requests.py' "$SKILL" | cut -d: -f1)"
rank_at="$(grep -n -m 1 'rank-next-issues.py --limit' "$SKILL" | cut -d: -f1)"
if [ -n "$helper_at" ] && [ -n "$rank_at" ] && [ "$helper_at" -lt "$rank_at" ]; then
  check "the skill runs the helper before it ranks the issues" ok
else
  check "the skill runs the helper before it ranks the issues" "helper at line [$helper_at], ranking at [$rank_at]"
fi
in_skill "the skill offers Finish this" "Finish this"
in_skill "the skill says an exit 2 is not having none" "never as having none"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
