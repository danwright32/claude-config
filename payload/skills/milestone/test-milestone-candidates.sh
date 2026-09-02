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
cat >"$TMP/issues.json" <<'JSON'
[
  { "number": 241, "title": "Give the subagent findings spool a way to drain" },
  { "number": 242, "title": "Report whether a spooled finding is reachable by any review" },
  { "number": 243, "title": "Warn when a stale deploy alert fires twice" },
  { "number": 244, "title": "Match an open issue against the issues already filed" },
  { "number": 240, "title": "Give claude-sync a way to clean up old backups" }
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
check "it finds a sibling that shares words with the idea" "SIBLING 3 #241" "$normal"
check "it finds the other sibling too" "SIBLING 2 #242" "$normal"
check_not "an unrelated issue in the pen is not reported at all" "#240" "$normal"
check "it states the sibling count, so the caller does not have to count lines" \
  "SIBLING-COUNT 2" "$normal"

# One shared word is a coincidence, not a cluster. It is still SHOWN, because the
# caller may recognise a real relation the word overlap cannot, but it must not be
# counted, or the number the "2 or more" rule reads is inflated by generic
# vocabulary and every idea looks like a cluster.
check "a single shared word is reported as a weak match, not a sibling" \
  "WEAK-MATCH 1 #243" "$normal"
check_not "a weak match is not also printed as a sibling" "SIBLING 1 #243" "$normal"
check "the weak matches are counted separately" "WEAK-COUNT 1" "$normal"

# Tracker vocabulary is generic in EVERY repo, so two of it is still a coincidence.
# Measured 2026-09-02 on this repo: an idea titled "Group the open issues already
# sitting in the Ungrouped holding pen" drew two siblings at two shared words, and
# neither was about grouping. They shared "issue", "open" and "already", which say
# nothing in a backlog of issues. Raising the threshold would have lost real matches,
# so the words themselves are excluded instead.
check_not "two shared tracker words is not a sibling" "#244" "$normal"

# The stronger match has to come first, or a caller reading only the top line
# reads the weakest evidence it has.
#
# Read with a loop rather than `grep | head`, because head exits as soon as it has
# its line and kills the producer, which under pipefail turns a passing check into a
# failure that never happened (L183).
top=""
while IFS= read -r line; do
  case "$line" in
    "SIBLING "*) top="$line"; break ;;
  esac
done <<<"$normal"
check "the strongest match is ranked first" "#241" "$top"

# --- the platform limit, not just the query -------------------------------
# gh issue list defaults to 30. The pen held 82 open issues in one real repo, so a
# default page would silently hide most of them and the count would be a fiction.
calls="$(cat "$GH_CALLS")"
check "it asks for the holding pen by the shared name" "--milestone $catch_all" "$calls"
limit=""
[[ "$calls" =~ --limit[[:space:]]+([0-9]+) ]] && limit="${BASH_REMATCH[1]}"
if [[ -n "$limit" && "$limit" -ge 100 ]]; then ok; else
  bad "it should ask for at least 100 issues (gh defaults to 30, the real pen held 82 open), got '${limit:-none}'"
fi

# --- nothing matched, read fine -------------------------------------------
GH_ISSUES="$TMP/issues-empty.json" run acme/widgets --like "Onboarding revamp copy tweaks"
GH_ISSUES="$TMP/issues.json"
check "an empty pen still reports its count explicitly" "SIBLING-COUNT 0" "$OUT"
check_eq "milestones present but no siblings is still a successful read" 0 "$RC"

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
