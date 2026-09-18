#!/usr/bin/env bash
# Tests for milestone-candidates.sh.
#
# The helper exists because the end of turn issue review had no way to see that an
# idea already has siblings. It compared an idea against milestone TITLES alone, so
# ten issues about the same subject could sit in the holding pen and the eleventh
# still read as a standalone chore. Measured 2026-09-02: Ungrouped held 98 issues in
# claude-config, 157 in bidspoke and 102 in new-agent-onboarding.
#
# A fake gh on PATH stands in for GitHub, so these tests cannot reach the network or
# touch a real repository (L2). The fake records every call, which lets the tests
# assert what was ASKED for (the page size, the milestone filter) and not only what
# came back.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/milestone-candidates.sh"
SHARED="$DIR/catch-all.sh"
ENSURE="$DIR/ensure-milestone.sh"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then ok; else
    bad "$1"; echo "  expected to contain: $2"; echo "  actual: $3"
  fi
}
check_not() { # check_not <description> <forbidden-substring> <actual>
  if [[ "$3" != *"$2"* ]]; then ok; else
    bad "$1 (output should not contain '$2')"; echo "  actual: $3"
  fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- the fake gh -----------------------------------------------------------
# Two different calls have to be answered differently, so it branches on argv
# rather than on the presence of a flag. Each half can be failed on its own, which
# is what lets the two read failures be told apart.
mkdir -p "$TMP/bin" "$TMP/empty"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
  *milestones*)
    if [ -n "${GH_FAIL_MILESTONES:-}" ]; then
      echo "gh: simulated milestones API failure" >&2
      exit 1
    fi
    cat "$GH_MILESTONES"
    exit 0
    ;;
  *"issue list"*)
    if [ -n "${GH_FAIL_ISSUES:-}" ]; then
      echo "gh: simulated issue list failure" >&2
      exit 1
    fi
    cat "$GH_ISSUES"
    exit 0
    ;;
  *)
    :
    ;;
esac
echo "gh: fake received an unexpected call: $*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"

# A description that does NOT repeat its own title, because matching an idea to a
# feature by title alone is the gap this helper closes: "One store, one truth" says
# nothing about spools, and its description is the only place the subject appears.
cat >"$TMP/milestones.json" <<'JSON'
[
  { "number": 3, "title": "Onboarding revamp", "state": "open", "description": "" },
  { "number": 7, "title": "One store, one truth", "state": "open",
    "description": "The subagent findings spool becomes the single durable home for harvested findings.\nShips when nothing reads a second copy." },
  { "number": 2, "title": "Ungrouped", "state": "open",
    "description": "Standalone bugs and chores that belong to no feature." },
  { "number": 1, "title": "Retired pipeline", "state": "closed",
    "description": "Finished last quarter." }
]
JSON

# 241 and 242 share two or more words with the idea below. 240 shares none. 243
# shares exactly ONE, and a single shared word is the case the count must refuse:
# measured on 2026-09-02 against bidspoke, whose pen holds 82 open issues, one idea
# drew a single genuine sibling at three shared words and TEN false ones at one
# ("alert", "drop", "time", "call" are generic in that repo). Counting those would
# have reported eleven siblings and made a one sibling idea read as an obvious
# cluster, which is the number the "2 or more" rule depends on (L104, L147).
# One repo-wide read, so each issue carries the milestone the script partitions on.
# 241, 242, 243, 244 and 240 are loose (the pen). 900 and 901 sit in real milestones,
# which is where a duplicate hides and where the old pen-only read could not look.
# Bodies, because a title is written before the work is understood and is the one part
# of an issue that routinely does not name the subject (claude-config#424). 902 is the
# case: its title shares NOT ONE word with the idea below, and its body is about
# exactly that work. Every other body here is written to share little with it, so the
# spread the bar is computed from is a real one rather than a single pair.
cat >"$TMP/issues.json" <<'JSON'
[
  { "number": 241, "title": "Give the subagent findings spool a way to drain",
    "body": "The spool fills and nothing takes records out of it. A drain has to run on a schedule and report how many it removed.",
    "milestone": { "title": "Ungrouped" } },
  { "number": 242, "title": "Report whether a spooled finding is reachable by any review",
    "body": "A finding nobody can reach is indistinguishable from one nobody filed. Say which review would show each record.",
    "milestone": { "title": "Ungrouped" } },
  { "number": 243, "title": "Warn when a stale deploy alert fires twice",
    "body": "A deploy alert repeats on every poll once it has gone stale, and the repetition teaches people to dismiss the channel.",
    "milestone": { "title": "Ungrouped" } },
  { "number": 244, "title": "Match a spooled finding against open issues before offering it",
    "body": "Offering a finding that is already tracked wastes the only attention this queue gets. Compare before offering.",
    "milestone": { "title": "Ungrouped" } },
  { "number": 240, "title": "Give claude-sync a way to clean up old backups",
    "body": "Backup copies accumulate beside their files for ever. Remove the ones past three months and say how many went.",
    "milestone": { "title": "Ungrouped" } },
  { "number": 900, "title": "Mark and expire the stale findings in the subagent spool",
    "body": "A record whose owning session is plainly not coming back should expire rather than sit unowned for ever.",
    "milestone": { "title": "One store, one truth" } },
  { "number": 901, "title": "Rewrite the onboarding tour copy",
    "body": "The tour explains the interface rather than the domain, and it reads as though written for somebody who built it.",
    "milestone": { "title": "Onboarding revamp" } },
  { "number": 902, "title": "Refuse to send from a watch daemon older than the script on disk",
    "body": "The watcher keeps publishing a collapsed hooks block, which turns the shared repo red and stops both Macs receiving config. The guard that would have refused that block was never loaded by the running daemon, so the collapsed block goes up and turns the build red again.",
    "milestone": { "title": "One store, one truth" } }
]
JSON

printf '[]' >"$TMP/issues-empty.json"
printf 'not json at all' >"$TMP/garbage.json"

export GH_MILESTONES="$TMP/milestones.json"
export GH_ISSUES="$TMP/issues.json"
export GH_CALLS="$TMP/calls.log"

# run <args...> : runs the helper with the fake gh and leaves the result in OUT and
# the exit code in RC. Deliberately NOT `out="$(run ...)"`: that puts the exit code
# assignment inside a subshell, where every failure-path assertion silently reads
# the initial value instead (which is exactly how the first draft of this suite
# reported every exit code as 0 while claiming to test them).
OUT=""
RC=0
run() {
  : >"$GH_CALLS"
  OUT="$(PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

# --- the shared holding pen name ------------------------------------------
# Both scripts have to look in the SAME pen. If they drift, this helper reports
# "no siblings" while 82 of them sit in the pen the other script writes to, and
# nothing anywhere reports a problem (L41).
if [ -f "$SHARED" ]; then ok; else bad "the shared catch-all name should live at $SHARED"; fi

catch_all="$(bash -c "source '$SHARED' 2>/dev/null; printf '%s' \"\${CATCH_ALL:-}\"")"
if [ -n "$catch_all" ]; then ok; else bad "the shared file should define CATCH_ALL"; fi

if grep -q 'catch-all.sh' "$ENSURE" 2>/dev/null; then ok; else
  bad "ensure-milestone.sh should take the pen's name from catch-all.sh, not keep its own copy"
fi

# --- the scripts have to PARSE ---------------------------------------------
# Both of these embed python inside a single quoted shell string, so one apostrophe
# in a python comment closes the string and the file stops parsing. That happened
# while this suite was being written, and the symptom was not a syntax error: bash
# printed the parse error to stderr, ran the truncated file anyway, and every case
# failed as a "usage error", which points at the argument handling rather than at
# the real cause (L11). One cheap check per script names it directly.
for s in "$SCRIPT" "$ENSURE"; do
  if err="$(bash -n "$s" 2>&1)"; then ok; else
    bad "$(basename "$s") does not parse: $err"
  fi
done

# --- usage ----------------------------------------------------------------
run
check "no repo is a usage error" "Usage:" "$OUT"
check_eq "no repo exits 2" 2 "$RC"

run acme/widgets
check "a missing --like is a usage error" "Usage:" "$OUT"
check_eq "a missing --like exits 2" 2 "$RC"

# --- the open milestones, with their descriptions -------------------------
run acme/widgets --like "Mark or expire stale findings in the subagent spool"
normal="$OUT"
check_eq "a normal run exits 0" 0 "$RC"
check "it lists an open milestone" "OPEN-MILESTONE #7 One store, one truth" "$normal"
check "it prints the description, which is where the subject actually appears" \
  "single durable home for harvested findings" "$normal"
check "it collapses a multi line description onto one line" \
  "harvested findings. Ships when" "$normal"
check "a milestone with no description is still listed" \
  "OPEN-MILESTONE #3 Onboarding revamp" "$normal"
check "a milestone with no description says so rather than printing a blank line" \
  "(none recorded)" "$normal"
check_not "a CLOSED milestone is never offered, because no idea ships with a finished feature" \
  "Retired pipeline" "$normal"
check_not "the holding pen is not offered as a feature to match against" \
  "OPEN-MILESTONE #2 Ungrouped" "$normal"

# --- siblings already in the holding pen ----------------------------------
check "it finds a candidate that shares words with the idea" "CANDIDATE 3 #241" "$normal"
check "it finds the other candidate too" "CANDIDATE 2 #242" "$normal"
check_not "an unrelated issue in the pen is not reported at all" "#240" "$normal"
# Four: 241, 242 and 244 share two or more words, and 243 shares one. All four are
# CANDIDATES now, because the score ranks the shortlist and does not rule on which of
# them are related: it was wrong three times on the day it was written, always in the
# same direction, and each fix excluded the words that exposed it (claude-config#265).
check "it states how many it listed" \
  "CANDIDATE-COUNT 4 shown" "$normal"
# And it says outright that the number is not a count of related issues, because that
# is exactly what the old SIBLING-COUNT was read as, and it fed the 2 or more rule.
check "and says that number is not a count of related issues" \
  "NOT a count of related issues" "$normal"

# A single shared word is still LISTED, ranked below the rest. The caller may
# recognise a real relation the word overlap cannot see, and may reject one it liked.
check "a single shared word is listed as a candidate like any other" \
  "CANDIDATE 1 #243" "$normal"
check_not "and nothing is labelled a weak match any more" "WEAK-MATCH" "$normal"

# --- a duplicate hiding OUTSIDE the holding pen ---------------------------
# The helper answered "what should this be grouped with" and not "does this already
# exist", and the second question is the one that stops a duplicate being filed. It
# read only the pen, so an issue for the same work sitting in a real milestone was
# invisible however the overlap was scored. That is not hypothetical: on 2026-09-02
# it was run before filing, reported no siblings and seven weak matches, and the
# duplicate (#226, in another milestone) was in neither list. Filed as #264 and
# closed the same hour.
dup_lines=""
while IFS= read -r line; do
  case "$line" in "DUPLICATE-RISK "*) dup_lines="$dup_lines$line"$'\n' ;; esac
done <<<"$normal"
check "an issue for the same work in another milestone is reported" "DUPLICATE-RISK" "$normal"
check "the duplicate names its number" "#900" "$dup_lines"
# Asserted against the DUPLICATE-RISK line only. Against the whole output it passed
# before the feature existed, because that milestone is already named on an
# OPEN-MILESTONE line, so the check could not fail (L159).
check "and names the milestone it is already in, so the reader can go and look" \
  "[in: One store, one truth]" "$dup_lines"
check "the duplicate count is stated separately from the sibling count" "DUPLICATE-COUNT 1" "$normal"
check_not "an unrelated issue elsewhere is not called a duplicate" "#901" "$normal"
# A loose issue is a SIBLING, never also a duplicate risk: one number, one meaning.
check_not "a holding pen issue is not double counted as a duplicate" "#241" "$dup_lines"

# --- a duplicate whose TITLE says nothing (claude-config#424) --------------
# Both lists above are computed from TITLES alone, and a title is the one part of an
# issue written before the work is understood. On 2026-09-17 that let #421 be filed
# over #420: the same root cause, established in #420s body, and their titles share
# the single word "send", so it was listed as a weak sibling and dismissed as one.
#
# Measured over the 120 issues in this repo on 2026-09-17, a raw count of shared words
# over bodies separates NOTHING: the median unrelated pair already shares 13, and the
# known duplicate shares 40, which is only the 99th percentile. So the signal is the
# PROPORTION shared (intersection over union), and the bar is computed from the spread
# of this ideas own row rather than from a constant, because a constant is exactly what
# claude-config#265 showed cannot travel between repos, each of which has its own
# generic vocabulary. At median plus three standard deviations it reported 1.14 rows
# per idea, was silent for 31 of the 120, and still caught every one of the four known
# related pairs (421 to 420, 394 to 390, 413 to 409, 340 to 336). At 3.5 it lost 421.
run acme/widgets --like "Stop one Mac publishing a collapsed hooks block that turns the shared repo red"
close_lines=""
while IFS= read -r line; do
  case "$line" in "CLOSE-MATCH "*) close_lines="$close_lines$line"$'\n' ;; esac
done <<<"$OUT"
# The read has to ASK for the bodies, or every line below is scored on titles again
# while reading exactly as though it were not (L3).
check "the issue read asks for the body, not only the title" "body" "$(cat "$GH_CALLS")"
check "an issue whose body is about this work is reported" "CLOSE-MATCH" "$OUT"
check "and it is the one whose title shares nothing with the idea" "#902" "$close_lines"
# Against the CLOSE-MATCH lines only. #902 sits in a milestone named on an
# OPEN-MILESTONE line, so a check over the whole output could not fail (L159).
check "the close match says where it already sits" "[in: One store, one truth]" "$close_lines"
# The shared words are shown because this RANKS and rules on nothing: the reader has to
# be able to dismiss a coincidence, and a bare score cannot be argued with
# (claude-config#265).
check "and shows what it shares, so a coincidence can be dismissed" "[shares: " "$close_lines"
check "the close match count is stated on its own" "CLOSE-MATCH-COUNT 1" "$OUT"
check_not "an unrelated issue elsewhere is not a close match" "#901" "$close_lines"
check_not "and neither is an unrelated loose one" "#243" "$close_lines"

# THE OTHER ANSWER, or a check that only ever fires is indistinguishable from one that
# fires on everything (L159, L104). An idea sharing nothing with this backlog has to
# come back with none, and say so rather than printing nothing at all (L98).
run acme/widgets --like "Choose a typeface for the printed quarterly accounts booklet"
check "an idea with nothing like it reports no close match" "CLOSE-MATCH-COUNT 0" "$OUT"
check_not "and lists none" "CLOSE-MATCH " "$OUT"

# Tracker vocabulary is generic in EVERY repo, so two of it is still a coincidence.
# Measured 2026-09-02 on this repo: an idea titled "Group the open issues already
# sitting in the Ungrouped holding pen" drew two siblings at two shared words, and
# neither was about grouping. They shared "issue", "open" and "already", which say
# nothing in a backlog of issues. Raising the threshold would have lost real matches,
# so the words themselves are excluded instead.
#
# This needs its OWN run with a tracker heavy title. Asserted against the run above
# it was satisfied by a fixture where the case could not arise, since that idea
# shares no word at all with #244, so it passed while proving nothing (L159).
run acme/widgets --like "Group the open issues already sitting in the Ungrouped holding pen"
# Tracker vocabulary ("issue", "open", "already") is excluded before scoring, so an
# overlap made only of it produces no candidate at all. That exclusion stays: it keeps
# noise out of the SHORTLIST, which is what the score is for now.
check_not "an overlap made only of tracker words produces no candidate" "#244" "$OUT"
check "and the shortlist is empty rather than merely unranked" "CANDIDATE-COUNT 0 shown" "$OUT"

# The stronger match has to come first, or a caller reading only the top line
# reads the weakest evidence it has.
#
# Read with a loop rather than `grep | head`, because head exits as soon as it has
# its line and kills the producer, which under pipefail turns a passing check into a
# failure that never happened (L183).
top=""
while IFS= read -r line; do
  case "$line" in
    "CANDIDATE "*) top="$line"; break ;;
  esac
done <<<"$normal"
check "the strongest match is ranked first" "#241" "$top"

# --- the platform limit, not just the query -------------------------------
# gh issue list defaults to 30. The pen held 82 open issues in one real repo, so a
# default page would silently hide most of them and the count would be a fiction.
calls="$(cat "$GH_CALLS")"
check_not "the read is NOT narrowed to the holding pen, which is what hid a duplicate" \
  "--milestone" "$calls"
# Each field asserted on its own rather than as one pinned list, because adding a field
# is a normal change and a pinned list turns it into a failure about the wrong thing
# (L103). What has to hold is that BOTH are asked for: the milestone tells loose work
# from filed work, and the body is where a subject that the title never names lives.
check "it asks for each issue's milestone, so it can tell loose work from filed work" \
  "milestone" "${calls#*--json}"
check "and for each body, which is where a title that names nothing is caught" \
  "body" "${calls#*--json}"
limit=""
[[ "$calls" =~ --limit[[:space:]]+([0-9]+) ]] && limit="${BASH_REMATCH[1]}"
if [[ -n "$limit" && "$limit" -ge 100 ]]; then ok; else
  bad "it should ask for at least 100 issues (gh defaults to 30, the real pen held 82 open), got '${limit:-none}'"
fi

# --- a capped read is announced, never passed off as the whole backlog ----
# `gh issue list --limit N` returns N and says nothing when more exist, so the
# duplicate check would silently scan a subset and report "no duplicate found" about
# a backlog it never saw. Measured 2026-09-02: bidspoke had 270 open issues against a
# limit of 300, so this was 30 issues from firing in silence (L24, L227). A false
# warning when the count lands exactly on the limit is the safe direction and is
# deliberate.
cat >"$TMP/issues-three.json" <<'JSON'
[
  { "number": 1, "title": "First loose item about spool draining", "milestone": { "title": "Ungrouped" } },
  { "number": 2, "title": "Second loose item about spool draining", "milestone": { "title": "Ungrouped" } },
  { "number": 3, "title": "Third loose item about spool draining", "milestone": { "title": "Ungrouped" } }
]
JSON
GH_ISSUES="$TMP/issues-three.json" run acme/widgets --like "spool draining" --limit 3
GH_ISSUES="$TMP/issues.json"
check "a read that came back at the limit says so" "READ-TRUNCATED" "$OUT"
check "and says how many it saw, so the gap is measurable" "3" "$OUT"
check_eq "a truncated read is still a successful read, not an error" 0 "$RC"

GH_ISSUES="$TMP/issues-three.json" run acme/widgets --like "spool draining" --limit 50
GH_ISSUES="$TMP/issues.json"
check_not "a read comfortably under the limit says nothing about truncation" "READ-TRUNCATED" "$OUT"

# --- nothing matched, read fine -------------------------------------------
GH_ISSUES="$TMP/issues-empty.json" run acme/widgets --like "Onboarding revamp copy tweaks"
GH_ISSUES="$TMP/issues.json"
check "an empty pen still reports its count explicitly" "CANDIDATE-COUNT 0 shown" "$OUT"
check_eq "milestones present but no siblings is still a successful read" 0 "$RC"

# --- nothing found, and nothing found EXCEPT a close match -----------------
# The early refusal says the repo has no feature milestone and nothing in the pen
# shares words with this idea, and it exits before the report. It had no test at all
# in either direction, and a close match is precisely a reason the idea may already be
# filed, so refusing over it would be false in the case that matters most (L11).
cat >"$TMP/milestones-pen-only.json" <<'JSON'
[
  { "number": 2, "title": "Ungrouped", "state": "open",
    "description": "Standalone bugs and chores that belong to no feature." }
]
JSON
GH_MILESTONES="$TMP/milestones-pen-only.json"
run acme/widgets --like "Choose a typeface for the printed quarterly accounts booklet"
check "with no feature milestone and nothing alike, it says so" "NO-CANDIDATES" "$OUT"
check_eq "and exits 1, so a caller can branch on it" 1 "$RC"
# The other answer, which is the branch this needed adding: same repo, same absence of
# milestones and of any shared title word, and an idea whose subject is sitting in a
# body. Refusing here would hide the one line worth reading.
run acme/widgets --like "Stop one Mac publishing a collapsed hooks block that turns the shared repo red"
check_not "a close match is never refused as nothing found" "NO-CANDIDATES" "$OUT"
check "and it is reported" "CLOSE-MATCH" "$OUT"
check_eq "and that is a successful read" 0 "$RC"
GH_MILESTONES="$TMP/milestones.json"

# --- the read FAILING is not the same as finding nothing ------------------
# Both halves can fail, and each has to say which one did, or the message for one
# answers for the other and the wrong thing gets investigated (L11).
GH_FAIL_MILESTONES=1 run acme/widgets --like "anything at all"
milestone_msg="$OUT"
check_eq "an unreadable milestone list exits 6" 6 "$RC"
check "it names the milestone list as the thing it could not read" "milestone" "$milestone_msg"
check_not "an unreadable milestone list never prints a sibling count" "SIBLING-COUNT" "$milestone_msg"
check_not "an unreadable milestone list never reads as nothing found" "NO-CANDIDATES" "$milestone_msg"

GH_FAIL_ISSUES=1 run acme/widgets --like "anything at all"
issues_msg="$OUT"
check_eq "an unreadable holding pen exits 6" 6 "$RC"
check "it names the holding pen as the thing it could not read" "$catch_all" "$issues_msg"
check_not "an unreadable holding pen never prints a sibling count" "SIBLING-COUNT" "$issues_msg"

# The two failures must not share one message, or the count is right and the
# diagnosis sends you to the wrong half.
if [[ "$milestone_msg" != "$issues_msg" ]]; then ok; else
  bad "the two read failures print the same message, so neither says which half failed"
fi

# --- gh missing entirely --------------------------------------------------
# The PATH still has to carry the tools the script legitimately uses, so it cannot
# simply be emptied. It also cannot be "the usual directories minus one", which is
# what the first version did: on this Mac gh sits in the homebrew prefix so
# /usr/bin:/bin happened to be gh free, and in CI gh is installed in /usr/bin, so
# the case ran with gh present and asserted nothing. Build the PATH out of named
# symlinks instead, so what is absent is a property of the fixture rather than of
# the machine (L322).
mkdir -p "$TMP/nogh"
for t in bash dirname cat tr grep awk sed python3 mktemp rm; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$TMP/nogh/$t"
done
NOGH_PATH="$TMP/nogh"
if PATH="$NOGH_PATH" command -v gh >/dev/null 2>&1; then
  bad "the no-gh fixture still finds gh on PATH, so this case would prove nothing"
else
  ok
  OUT="$(PATH="$NOGH_PATH" bash "$SCRIPT" acme/widgets --like "x" 2>&1)"
  RC=$?
  check_eq "no gh on PATH exits 6" 6 "$RC"
  check "no gh on PATH says so rather than reporting an empty backlog" "gh" "$OUT"
  check_not "no gh on PATH never reads as nothing found" "SIBLING-COUNT" "$OUT"
fi

# --- an unparseable response is a read failure, not an empty one ----------
GH_MILESTONES="$TMP/garbage.json" run acme/widgets --like "x"
GH_MILESTONES="$TMP/milestones.json"
check_eq "an unparseable milestone list exits 6" 6 "$RC"
check_not "an unparseable milestone list never prints a sibling count" "SIBLING-COUNT" "$OUT"

echo
echo "passed: $pass, failed: $fail"
# The one machine readable score line every suite in this repo ends with, so
# run-all-tests.sh reads the score rather than guessing which line holds it.
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
