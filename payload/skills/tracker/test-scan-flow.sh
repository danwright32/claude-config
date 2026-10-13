#!/usr/bin/env bash
# Tests for the commands behind /tracker --scan (claude-config#1032, milestone "Tracker scan for
# git work"): scan, set-authors, ignore-repo, unignore-repo, authors-found, reconcile, snapshot and
# scan-cells. None of them reaches the web app; the ones that write the sheet are tested in
# test-tracker.sh.
#
# Every run happens on a COPY of the skill in a throwaway directory, with HOME pointed at another
# one, so no command can read or write the real config.local.json, scan-state.local.json or home
# directory (L2). Every repository is built here with pinned author and committer dates, and every
# scan is given its reference "now" with --now, so no assertion depends on the day it runs (L130).
# The scan JSON the reconcile is tested on comes from scan.sh run over those repositories, never
# written by hand, so it has the shape the reconcile will really meet (L48).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then ok; else
    bad "$1"; echo "  expected to contain: $2"; echo "  actual: $3"
  fi
}
check_not() { # check_not <description> <forbidden-substring> <actual>
  if [[ "$3" != *"$2"* ]]; then ok; else bad "$1 (output should not contain '$2')"; fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- a world with no access to the real one -----------------------------------
export HOME="$TMP/home"
mkdir -p "$HOME"
REAL_HOME="$(cd "$HOME" && pwd -P)"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export TRACKER_SNAPSHOT_DIR="$TMP/snapshots"

SK="$TMP/skill"
mkdir -p "$SK"
cp "$DIR/tracker.sh" "$DIR/tracker_lib.py" "$DIR/scan.sh" "$DIR/SKILL.md" "$DIR/config.example.json" "$DIR/apps-script.gs" "$SK/"
CONFIG="$SK/config.local.json"
STATE="$SK/scan-state.local.json"

run(){ # run <args...>; sets OUT (stdout and stderr) and RC
  ERR=""
  OUT="$(bash "$SK/tracker.sh" "$@" 2>&1)"
  RC=$?
}
runo(){ # runo <args...>; sets OUT to stdout only, ERR to stderr, and RC
  OUT="$(bash "$SK/tracker.sh" "$@" 2> "$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}
# jq <json> <python expression over d>: one field, as compact JSON, or JSON-UNREADABLE with the start
# of what came back, so a crash is never read as an empty field.
jq(){ python3 -c 'import json,sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    print("JSON-UNREADABLE: %r" % sys.argv[1][:300]); sys.exit(0)
print(json.dumps(eval(sys.argv[2]), separators=(",",":"), sort_keys=True))' "$1" "$2" 2>&1; }
refuses(){ # refuses <description> <expected words> ; judges the last run
  if [ "$RC" -ne 0 ]; then ok; else bad "$1: exits non zero (got $RC)"; fi
  check "$1: says why" "$2" "$OUT${ERR:-}"
}
fingerprint(){ python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null || echo absent; }
mode_of(){ python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1" 2>&1; }

# The reference now every scan is given: 2026-06-15 12:00 UTC.
NOW="$(python3 -c 'import calendar; print(calendar.timegm((2026, 6, 15, 12, 0, 0)))')"
DAY=86400
commit(){ # commit <repo dir> <days from NOW> <author name> <author email> <subject>
  local when=$((NOW + $2 * DAY))
  GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL="$4" GIT_COMMITTER_NAME="$3" GIT_COMMITTER_EMAIL="$4" \
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
    git -C "$1" commit -q --allow-empty -m "$5"
}
newrepo(){ # newrepo <dir> [remote url]
  mkdir -p "$1" && git -C "$1" init -q
  if [ -n "${2:-}" ]; then git -C "$1" remote add origin "$2"; fi
}
ME_NAME="Dan Wright"
ME_EMAIL="dan@example.com"

# --- the repositories -----------------------------------------------------------
ROOT="$TMP/root"
mkdir -p "$ROOT"
REAL_ROOT="$(cd "$ROOT" && pwd -P)"
newrepo "$ROOT/alpha" "https://github.com/example/alpha.git"
commit "$ROOT/alpha" -200 "$ME_NAME" "$ME_EMAIL" "start alpha"
commit "$ROOT/alpha" -3 "$ME_NAME" "$ME_EMAIL" "alpha login flow"
newrepo "$ROOT/beta" "git@github.com:example/beta.git"
commit "$ROOT/beta" -300 "$ME_NAME" "$ME_EMAIL" "old beta work"
newrepo "$ROOT/gamma" "https://github.com/example/gamma"
commit "$ROOT/gamma" -2 "$ME_NAME" "$ME_EMAIL" "gamma first commit"
newrepo "$ROOT/delta" "https://github.com/example/delta"
commit "$ROOT/delta" -2 "Stranger" "stranger@example.org" "not mine"
newrepo "$ROOT/dup" "https://github.com/example/dup"
commit "$ROOT/dup" -1 "$ME_NAME" "$ME_EMAIL" "dup work"
newrepo "$ROOT/twin-one" "https://github.com/example/twin"
commit "$ROOT/twin-one" -1 "$ME_NAME" "$ME_EMAIL" "twin work here"
newrepo "$ROOT/twin-two" "git@github.com:example/twin.git"
commit "$ROOT/twin-two" -1 "$ME_NAME" "$ME_EMAIL" "twin work there"
newrepo "$ROOT/localonly"
commit "$ROOT/localonly" -1 "$ME_NAME" "$ME_EMAIL" "local only work"
newrepo "$ROOT/botty" "https://github.com/example/botty"
commit "$ROOT/botty" -1 "dependabot[bot]" "49699333+dependabot[bot]@users.noreply.github.com" "bump"

# An invented token, only ever written through a variable: a token key followed by its value as
# literal text is what claude-sync's secret scan refuses to send.
KEEP_TOKEN="keep_this_token_value_0123456789_abcdef"
write_config(){ # write_config <json object>
  python3 -c 'import json,sys; json.dump(json.loads(sys.argv[2]), open(sys.argv[1],"w"))' "$CONFIG" "$1"
}

# --- scan: the config's roots, authors and window, and the ignore list, reach scan.sh ----------
rm -f "$CONFIG" "$STATE"
runo scan --now "$NOW"
check_eq "scan with no config.local.json runs scan.sh on its defaults" 0 "$RC"
check_eq "and searches HOME, scan.sh's own default" "[\"$REAL_HOME\"]" "$(jq "$OUT" 'd["roots_searched"]')"
check_eq "and has no authors, so nothing is counted as yours" '[]' "$(jq "$OUT" 'd["authors"]')"
check_eq "and the default window is scan.sh's 30 days" '30' "$(jq "$OUT" 'd["window_days"]')"

write_config "{\"url\":\"<paste the web app /exec URL here>\",\"token\":\"<set by tracker.sh new-token>\",\"scan_roots\":[\"$ROOT\"],\"authors\":[\"$ME_EMAIL\"],\"scan_window_days\":10}"
runo scan --now "$NOW"
check_eq "scan with roots, authors and a window in config.local.json succeeds, though the web app is not set up" 0 "$RC"
check_eq "and searches the configured root" "[\"$REAL_ROOT\"]" "$(jq "$OUT" 'd["roots_searched"]')"
check_eq "and passes the configured authors" "[\"$ME_EMAIL\"]" "$(jq "$OUT" 'd["authors"]')"
check_eq "and the configured window" '10' "$(jq "$OUT" 'd["window_days"]')"
check_eq "so your commits in the window are counted (alpha has one in the last 10 days)" '1' \
  "$(jq "$OUT" '[r["window_commit_count"] for r in d["repos"] if r["path"].endswith("/alpha")][0]')"

# A root written with a leading ~ means HOME, as Dan would write it.
mkdir -p "$HOME/code"
newrepo "$HOME/code/homerepo" "https://github.com/example/homerepo"
commit "$HOME/code/homerepo" -1 "$ME_NAME" "$ME_EMAIL" "home work"
write_config '{"scan_roots":["~/code"],"authors":["dan@example.com"]}'
runo scan --now "$NOW"
check_eq "a root written ~/code is HOME/code" "[\"$REAL_HOME/code\"]" "$(jq "$OUT" 'd["roots_searched"]')"
rm -rf "$HOME/code"

# The ignore list lives in scan-state.local.json, written by ignore-repo, never by hand.
write_config "{\"url\":\"https://script.google.com/macros/s/FAKE/exec\",\"token\":\"$KEEP_TOKEN\",\"scan_roots\":[\"$ROOT\"],\"authors\":[\"$ME_EMAIL\"]}"
config_before="$(fingerprint "$CONFIG")"
run ignore-repo "$ROOT/delta"
check_eq "ignore-repo succeeds" 0 "$RC"
check_eq "and writes scan-state.local.json, holding the resolved path" "[\"$REAL_ROOT/delta\"]" "$(jq "$(cat "$STATE")" 'd["ignored"]')"
check_eq "and never touches config.local.json, which holds the token" "$config_before" "$(fingerprint "$CONFIG")"
check_eq "and the state file is readable by its owner only" "600" "$(mode_of "$STATE")"
run ignore-repo "$ROOT/delta"
check_eq "ignoring it again keeps one entry" "[\"$REAL_ROOT/delta\"]" "$(jq "$(cat "$STATE")" 'd["ignored"]')"
runo scan --now "$NOW"
check_eq "scan leaves out an ignored repository" "[\"$REAL_ROOT/delta\"]" "$(jq "$OUT" 'd["ignored"]')"
check_eq "and it is not among the repos" '0' "$(jq "$OUT" 'len([r for r in d["repos"] if r["path"].endswith("/delta")])')"
run unignore-repo "$ROOT/delta"
check_eq "unignore-repo succeeds" 0 "$RC"
check_eq "and takes it off the list" '[]' "$(jq "$(cat "$STATE")" 'd["ignored"]')"
run unignore-repo "$ROOT/never-ignored"
refuses "unignore-repo of a path that is not ignored" "is not ignored"
# A repository deleted since it was ignored is still taken off the list by the path it was ignored
# under, though that path no longer resolves on its own.
mkdir -p "$TMP/gone/repo"
run ignore-repo "$TMP/gone/repo"
rm -rf "$TMP/gone"
run unignore-repo "$TMP/gone/repo"
check_eq "unignore-repo of a repository deleted since it was ignored succeeds" 0 "$RC"
check_eq "and the list is empty again" '[]' "$(jq "$(cat "$STATE")" 'd["ignored"]')"
printf '{ not json' > "$STATE"
run ignore-repo "$ROOT/delta"
refuses "ignore-repo over an unreadable scan-state.local.json" "could not be read"
check_eq "and leaves that file as it was" "{ not json" "$(cat "$STATE")"
run scan --now "$NOW"
refuses "scan with an unreadable scan-state.local.json, never scanning as if nothing were ignored" "scan-state.local.json"
rm -f "$STATE"
run ignore-repo
refuses "ignore-repo with no path" "usage"

# Wrong shapes are refused by name, never quietly dropped (L320).
for case in 'authors written as one string|{"authors":"dan@example.com"}|authors' \
            'an author that is blank|{"authors":["  "]}|authors' \
            'a window written as text|{"scan_window_days":"30"}|scan_window_days' \
            'a window of zero days|{"scan_window_days":0}|scan_window_days' \
            'a window of true|{"scan_window_days":true}|scan_window_days' \
            'an empty root|{"scan_roots":[""]}|scan_roots' \
            'roots written as one string|{"scan_roots":"/tmp"}|scan_roots'; do
  IFS='|' read -r what json key <<< "$case"
  write_config "$json"
  run scan --now "$NOW"
  refuses "scan with $what" "$key"
done
printf '{ not json' > "$CONFIG"
run scan --now "$NOW"
refuses "scan with an unreadable config.local.json" "could not be read"

# --- set-authors: persisted into config.local.json, every other value kept -------------------
write_config "{\"url\":\"https://script.google.com/macros/s/FAKE/exec\",\"token\":\"$KEEP_TOKEN\"}"
run set-authors "[\"$ME_EMAIL\",\"Dan Wright\"]"
check_eq "set-authors succeeds" 0 "$RC"
check_eq "and saves the authors" "[\"$ME_EMAIL\",\"Dan Wright\"]" "$(jq "$(cat "$CONFIG")" 'd["authors"]')"
check_eq "and keeps the url and the token exactly" '["https://script.google.com/macros/s/FAKE/exec",true]' \
  "$(jq "$(cat "$CONFIG")" '[d["url"], d["token"] == "keep_this_token_value_0123456789_abcdef"]')"
check_not "and never prints the token" "keep_this_token_value" "$OUT"
check_eq "and the file is readable by its owner only" "600" "$(mode_of "$CONFIG")"
for bad in '[]' '"dan@example.com"' '[1]' '["  "]' '{not json'; do
  before="$(fingerprint "$CONFIG")"
  run set-authors "$bad"
  refuses "set-authors $bad" "authors"
  check_eq "set-authors $bad: leaves config.local.json as it was" "$before" "$(fingerprint "$CONFIG")"
done
printf '{ not json' > "$CONFIG"
run set-authors "[\"$ME_EMAIL\"]"
refuses "set-authors over an unreadable config.local.json" "could not be read"
check_eq "and leaves that file as it was" "{ not json" "$(cat "$CONFIG")"
rm -f "$CONFIG"
run set-authors "[\"$ME_EMAIL\"]"
check_eq "set-authors with no config.local.json makes one from the example" 0 "$RC"
check_eq "holding the authors and the example's placeholders, so the append path still refuses until setup" \
  "[[\"$ME_EMAIL\"],\"<paste the web app /exec URL here>\"]" "$(jq "$(cat "$CONFIG")" '[d["authors"], d["url"]]')"
# A run killed between the write and the rename leaves config.local.json as it was.
write_config "{\"url\":\"https://script.google.com/macros/s/FAKE/exec\",\"token\":\"$KEEP_TOKEN\"}"
before="$(fingerprint "$CONFIG")"
TRACKER_TEST_STOP_BEFORE_RENAME=1 run set-authors "[\"$ME_EMAIL\"]"
if [ "$RC" -ne 0 ]; then ok; else bad "set-authors stopped before its rename reports failure (got $RC)"; fi
check_eq "and leaves config.local.json as it was" "$before" "$(fingerprint "$CONFIG")"
rm -f "$SK"/.writing.*.local.json

# --- authors-found: the identities a first run asks about --------------------------------------
write_config "{\"scan_roots\":[\"$ROOT\"]}"
bash "$SK/tracker.sh" scan --now "$NOW" > "$TMP/scan-noauthors.json" 2> "$TMP/err"
runo authors-found "$TMP/scan-noauthors.json"
check_eq "authors-found lists each identity in the window once, most commits first, bots left out" \
  "[[\"$ME_EMAIL\",\"$ME_NAME\",6,6],[\"stranger@example.org\",\"Stranger\",1,1]]" \
  "$(jq "$OUT" '[[a["email"], a["name"], a["commits"], a["repos"]] for a in d]')"
run authors-found "$TMP/nowhere.json"
refuses "authors-found of a file that is not there" "nowhere.json"

# --- reconcile: four buckets driven by both sides, and questions that are never guessed --------
write_config "{\"scan_roots\":[\"$ROOT\"],\"authors\":[\"$ME_EMAIL\"]}"
bash "$SK/tracker.sh" scan --now "$NOW" > "$TMP/scan.json" 2> "$TMP/err"
check_eq "the scan the reconcile is tested on succeeded" '"repos_found"' "$(jq "$(cat "$TMP/scan.json")" 'd["outcome"]')"
# The sheet as the connector returns it: a range from A1 and rows that stop at their last
# non-empty cell, so they are ragged, and an empty row in the middle.
python3 - "$TMP" <<'PY'
import json, os, sys
tmp = sys.argv[1]
H = ["Project Name", "Date Started", "Date Completed", "Problem/Goal", "My Actions",
     "Outcome/Results", "When to Check Results", "Skills Used", "Link", "Notes"]
values = [H,
  ["Alpha", "2025-11-27", "", "Goal A", "Did A", "Out A", "", "TypeScript", "https://github.com/example/alpha"],
  ["Beta", "2025-08-19", "", "Goal B", "Did B", "Out B", "", "Python", "https://github.com/example/beta/"],
  ["PET", "2026-01-01", "", "Track enrollment", "Sheets work", "", "", "Python", "https://docs.google.com/spreadsheets/d/abc/edit"],
  ["Elsewhere", "2026-02-01", "", "Goal E", "", "", "", "", "https://github.com/example/elsewhere"],
  ["Dup one", "2026-03-01", "", "", "", "", "", "", "https://github.com/example/dup"],
  ["Dup two", "2026-03-02", "", "", "", "", "", "", "github.com/example/dup"],
  [],
  ["Twin", "2026-04-01", "", "", "", "", "", "", "https://github.com/example/twin"],
  ["Ragged"],
  ["Wiki", "", "", "", "", "", "", "", "internal wiki page"]]
json.dump({"range": "Sheet1!A1:J11", "majorDimension": "ROWS", "values": values}, open(os.path.join(tmp, "sheet.json"), "w"))
json.dump(values, open(os.path.join(tmp, "sheet-bare.json"), "w"))
json.dump({"range": "Sheet1!A2:J10", "values": values[1:]}, open(os.path.join(tmp, "sheet-offset.json"), "w"))
json.dump({"values": [[h for h in H if h != "Link"]] + values[1:]}, open(os.path.join(tmp, "sheet-nolink.json"), "w"))
json.dump({"values": [H[:-1] + ["link"]] + values[1:]}, open(os.path.join(tmp, "sheet-twolinks.json"), "w"))
PY
runo reconcile "$TMP/scan.json" "$TMP/sheet.json"
check_eq "reconcile succeeds" 0 "$RC"
R="$OUT"
check_eq "matched: Alpha has your commits in the window, so it is an update, found at its sheet row" '[["Alpha",2,"update"]]' \
  "$(jq "$R" '[[m["project_name"], m["row_number"], m["status"]] for m in d["matched"] if m["status"] == "update"]')"
check_eq "matched: Beta, an ssh address in the scan and a trailing slash in the sheet, has no new work, so it is current" '[["Beta",3,"current"]]' \
  "$(jq "$R" '[[m["project_name"], m["row_number"], m["status"]] for m in d["matched"] if m["status"] == "current"]')"
check_eq "and a match carries the row as it is, padded where the connector stopped early, and the window's subjects" \
  '[["Alpha","2025-11-27",""],["alpha login flow"]]' \
  "$(jq "$R" '[[d["matched"][0]["row"]["Project Name"], d["matched"][0]["row"]["Date Started"], d["matched"][0]["row"]["Notes"]], d["matched"][0]["repo"]["window_subjects"]]')"
check_eq "tracked but not on this Mac: reported with a reason, never updated" \
  '[["PET",4,"no repository on this Mac has its Link"],["Elsewhere",5,"no repository on this Mac has its Link"],["Ragged",10,"it has no Link"],["Wiki",11,"its Link is not a repository address"]]' \
  "$(jq "$R" '[[t["project_name"], t["row_number"], t["reason"]] for t in d["tracked_not_here"]]')"
check_eq "new here: gamma, untracked with your commits" '["github.com/example/gamma"]' "$(jq "$R" '[n["normalized_url"] for n in d["new_here"]]')"
check_eq "no commits under your identity: delta, and the bot's repository" '["github.com/example/botty","github.com/example/delta"]' \
  "$(jq "$R" 'sorted(n["normalized_url"] for n in d["no_commits_by_you"])')"
check_eq "a Link two rows hold is a question naming both rows, never an update" '[[6,7]]' \
  "$(jq "$R" '[q["rows"] for q in d["questions"] if q["normalized_url"] == "github.com/example/dup"]')"
check_eq "two clones of one repository are a question naming both, never two projects" '[2]' \
  "$(jq "$R" '[len(q["paths"]) for q in d["questions"] if q["normalized_url"] == "github.com/example/twin"]')"
check_eq "and the row they share is in that question, not in tracked but not here" '[[9]]' \
  "$(jq "$R" '[q["rows"] for q in d["questions"] if q["normalized_url"] == "github.com/example/twin"]')"
check_eq "a repository with your commits and no hosted remote is a question, since no Link can ever match it" '1' \
  "$(jq "$R" 'len([q for q in d["questions"] if q["normalized_url"] is None and q["paths"][0].endswith("/localonly")])')"
# Every non empty row lands in exactly one place, and so does every repository (L582).
check_eq "every non empty sheet row is accounted for exactly once, the empty row 8 skipped" '[2,3,4,5,6,7,9,10,11]' \
  "$(jq "$R" 'sorted([m["row_number"] for m in d["matched"]] + [t["row_number"] for t in d["tracked_not_here"]] + [r for q in d["questions"] for r in q["rows"]])')"
check_eq "and every repository the scan found exactly once" "$(jq "$(cat "$TMP/scan.json")" 'sorted(r["path"] for r in d["repos"])')" \
  "$(jq "$R" 'sorted([m["repo"]["path"] for m in d["matched"]] + [n["path"] for n in d["new_here"]] + [n["path"] for n in d["no_commits_by_you"]] + [p for q in d["questions"] for p in q["paths"]])')"
runo reconcile "$TMP/scan.json" "$TMP/sheet-bare.json"
check_eq "reconcile takes the connector's values as a bare list of rows too" "$(jq "$R" 'd["matched"]')" "$(jq "$OUT" 'd["matched"]')"

run reconcile "$TMP/scan-noauthors.json" "$TMP/sheet.json"
refuses "reconcile of a scan with no authors" "set-authors"
run reconcile "$TMP/scan.json" "$TMP/sheet-offset.json"
refuses "reconcile of a sheet read from anywhere but A1, which would number every row wrong" "A1"
run reconcile "$TMP/scan.json" "$TMP/sheet-nolink.json"
refuses "reconcile of a sheet with no Link column" "Link"
run reconcile "$TMP/scan.json" "$TMP/sheet-twolinks.json"
refuses "reconcile of a sheet with two Link columns" "more than one"
printf '{ not json' > "$TMP/broken.json"
run reconcile "$TMP/scan.json" "$TMP/broken.json"
refuses "reconcile of a sheet that is not JSON" "broken.json"
run reconcile "$TMP/broken.json" "$TMP/sheet.json"
refuses "reconcile of a scan that is not JSON" "broken.json"
run reconcile "$TMP/scan.json"
refuses "reconcile with one argument" "usage"

# --- snapshot: a dated local copy of the sheet as read, outside the synced ~/.claude ------------
runo snapshot "$TMP/sheet.json"
check_eq "snapshot succeeds" 0 "$RC"
SNAP="$OUT"
check "and prints the path it wrote, under the snapshot folder" "$TMP/snapshots/sheet-" "$SNAP"
check_eq "holding exactly the sheet that was read" "$(fingerprint "$TMP/sheet.json")" "$(fingerprint "$SNAP")"
check_eq "readable by its owner only" "600" "$(mode_of "$SNAP")"
runo snapshot "$TMP/sheet.json"
if [ -n "$OUT" ] && [ "$OUT" != "$SNAP" ] && [ -f "$SNAP" ]; then ok; else bad "a second snapshot in the same second is a new file, never over the first (got '$OUT')"; fi
run snapshot "$TMP/broken.json"
refuses "snapshot of a sheet that is not JSON" "broken.json"
TRACKER_SNAPSHOT_DIR="$HOME/.claude/skills/tracker/snapshots" run snapshot "$TMP/sheet.json"
refuses "snapshot into the synced ~/.claude, where a copy of the sheet would travel" ".claude"
check_eq "and writes nothing there" "absent" "$( [ -e "$HOME/.claude" ] && echo present || echo absent)"
# The default folder is outside ~/.claude.
( unset TRACKER_SNAPSHOT_DIR; bash "$SK/tracker.sh" snapshot "$TMP/sheet.json" ) > "$TMP/default-snap" 2>&1
check "with no folder set, the snapshot lands in ~/.claude-tracker-snapshots" "$HOME/.claude-tracker-snapshots/sheet-" "$(cat "$TMP/default-snap")"

# --- scan-cells: the rules every synthesized row obeys before it is shown ----------------------
ROW='{"Project Name":"Alpha","Date Started":"2025-11-27","Date Completed":"2026-05-01","My Actions":"Did A","Link":"https://github.com/example/alpha"}'
# The dashes are made by chr(), so this file holds none (the style gate would refuse it).
CELLS="$(python3 -c 'import json; em, en, hy = chr(0x2014), chr(0x2013), chr(45)
print(json.dumps({"My Actions": "Built login " + em + " then tests | shipped",
  "Outcome/Results": "Shipped 2026 " + en + " 2027 " + hy + " and self" + hy + "aware",
  "Link": "https://github.com/example/alpha", "When to Check Results": {"date": "2026-11-01"}}))')"
runo scan-cells "$ROW" "$CELLS"
check_eq "scan-cells succeeds" 0 "$RC"
check_eq "and turns em and en dashes, pipes and spaced hyphens into commas, keeping a hyphen inside a word, the Link and a date" \
  '{"Link":"https://github.com/example/alpha","My Actions":"Built login, then tests, shipped","Outcome/Results":"Shipped 2026, 2027, and self-aware","When to Check Results":{"date":"2026-11-01"}}' \
  "$(jq "$OUT" 'd')"
runo scan-cells "$ROW" '{"Date Started":{"date":"2026-01-01"}}'
refuses "scan-cells changing a Date Started that is already set" "Date Started"
runo scan-cells "$ROW" '{"Date Completed":""}'
refuses "scan-cells clearing a Date Completed that is already set" "Date Completed"
runo scan-cells "$ROW" '{"Link":"https://github.com/example/other"}'
refuses "scan-cells changing the Link the row is found by" "Link"
runo scan-cells '{"Project Name":"Gamma"}' '{"Date Started":{"date":"2026-06-13"},"Date Completed":""}'
check_eq "scan-cells for a new row sets Date Started and leaves Date Completed empty" '{"Date Completed":"","Date Started":{"date":"2026-06-13"}}' "$(jq "$OUT" 'd')"
runo scan-cells "$ROW" '{"date completed":{"date":"2026-06-01"}}'
check_eq "scan-cells may change a set Date Completed to another date, matching the header in any case" '{"date completed":{"date":"2026-06-01"}}' "$(jq "$OUT" 'd')"
runo scan-cells "$ROW" '{}'
refuses "scan-cells with no cells" "cells"
runo scan-cells "$ROW" '[1]'
refuses "scan-cells with cells that are not an object" "cells"
runo scan-cells "$ROW"
refuses "scan-cells with one argument" "usage"

# --- SKILL.md documents the flow these commands serve ----------------------------------------
# Judged inside its own section, whitespace collapsed (L278), each answered yes or no (L445).
flow="$(python3 - "$DIR/SKILL.md" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
body = next((b.partition("\n")[2] for b in re.split(r"(?m)^## ", text)[1:] if b.startswith("Scanning git work")), None)
if body is None:
    print("section: MISSING"); sys.exit(0)
body = " ".join(body.split())
for want in ("tracker.sh scan", "tracker.sh set-authors", "tracker.sh authors-found", "tracker.sh reconcile",
             "tracker.sh snapshot", "tracker.sh scan-cells", "tracker.sh ignore-repo", "tracker.sh unignore-repo",
             "tracker.sh sheet-id", "tracker.sh update --preview", "tracker.sh append", "never by Drive name",
             "more than one", "stop at the first failure", "scan-state.local.json"):
    print("%s: %s" % (want, "yes" if want in body else "MISSING"))
PY
)"
check_not "SKILL.md's Scanning git work section names every command and rule of the flow" "MISSING" "$flow"
check "and the section exists" "tracker.sh reconcile: yes" "$flow"
check_eq "and its Usage block lists /tracker --scan" "1" "$(grep -c '^/tracker --scan' "$DIR/SKILL.md")"

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
