#!/usr/bin/env bash
# Tests for find-existing.sh, the look orchestrate's intake takes for an open issue or pull request
# that already covers an item from Slack (claude-config#3555), and for the item mode of
# hooks/lib/match-open-issues.py it runs, the one matcher the end of turn review also uses.
#
# A stand in gh on PATH answers from fixtures/open-issues.json and fixtures/open-prs.json: real
# entries recorded from danwright32/claude-config with `gh issue list` and `gh pr list` on
# 2026-11-26 (six open issues and four open pull requests of the 178 and 44 open that night), with
# only their session link lines taken out and local scratch paths replaced by <scratchpad>. No test
# reaches GitHub.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/find-existing.sh"
export FX="$DIR/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /' | awk 'NR <= 30'; return 0; }
has() { if [[ "$3" == *"$2"* ]]; then ok; else bad "$1 (no '$2')" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok; else bad "$1 (holds '$2')" "$3"; fi; }
is() { if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

# ---- the stand in gh ----
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMP_CALLS"
case "$1 $2" in
  "issue list")
    [ -n "${GH_DISABLED:-}" ] && { echo "the 'danwright32/claude-config' repository has disabled issues" >&2; exit 1; }
    [ -n "${GH_FAIL_ISSUES:-}" ] && { echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1; }
    [ -n "${GH_GARBLED:-}" ] && { echo "<html>rate limited</html>"; exit 0; }
    cat "$FX/open-issues.json"; exit 0 ;;
  "pr list")
    [ -n "${GH_FAIL_PRS:-}" ] && { echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1; }
    cat "$FX/open-prs.json"; exit 0 ;;
esac
echo "stand in gh: unexpected call: $*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"
export TMP_CALLS="$TMP/calls"

REPO=danwright32/claude-config
look() { # look <item text> [repo]   -> sets out and rc
  out="$(printf '%s\n' "$1" | PATH="$TMP/bin:$PATH" bash "$HELPER" "${2:-$REPO}" 2>&1)"
  rc=$?
}

# ---- a clear match on an issue ----
look "From Slack: orchestrate should look for an existing issue or pull request before it works a Slack item, so the same alert is not built twice"
is "an issue that covers the item: exit 0" 0 "$rc"
has "an issue that covers the item is named with its kind and title" "issue #3555: Check for an existing issue or pull request before orchestrate works a Slack item" "$out"
has "and the output says these may already cover it" "MAY ALREADY BE COVERED" "$out"

# ---- a clear match on a pull request that names no issue ----
look "Slack: the merge helper log reuses a run and does not say which suite parts went untested"
is "a pull request that covers the item: exit 0" 0 "$rc"
has "a pull request that covers the item is named with its kind" "pull request #3708: Name a reused run's untested suite parts in the merge helper's log" "$out"
has "and it says the pull request names no issue" "#3708: Name a reused run's untested suite parts in the merge helper's log  (names no issue)" "$out"

# ---- a pull request that names an issue ----
look "Alert thread: the rtk hook rewrites a prefixed grep into rtk grep, which prints help and exits 0"
is "a pull request naming an issue: exit 0" 0 "$rc"
has "the pull request is named" "pull request #3653:" "$out"
has "and the issue it closes is given beside it" "(closes #3639)" "$out"
has "and the issue itself is named as well" "issue #3639:" "$out"

# ---- no match: nothing printed, exit 0 ----
look "The invoice email footer shows last year's date in the customer's receipt"
is "no match: exit 0" 0 "$rc"
is "no match prints nothing at all" "" "$out"

# ---- a near miss that must NOT match ----
# Shares the subject area (free space, a warning) with #3608, which is about standing a projected
# fall down once a drop stops; this item is about a different machine and a different fault.
look "Slack alert: free space on the backup drive was low this morning, the photo import failed"
is "a near miss: exit 0" 0 "$rc"
lacks "a near miss is not offered as covered" "#3608" "$out"
is "a near miss prints nothing" "" "$out"

# ---- one look reads both lists, by the repository it was given, under a stated limit ----
: >"$TMP_CALLS"
look "anything at all about the widget"
calls="$(cat "$TMP_CALLS")"
has "the open issues are read for the repository given" "issue list --repo $REPO --state open" "$calls"
has "the open pull requests are read for the repository given" "pr list --repo $REPO --state open" "$calls"
has "the read carries the limit it states" "--limit 1000" "$calls"

# ---- past the limit it says what it did not read ----
look "anything at all about the widget"
out_lim="$(printf 'anything at all about the widget\n' | PATH="$TMP/bin:$PATH" CLAUDE_ITEM_MATCH_LIMIT=6 bash "$HELPER" "$REPO" 2>&1)"
has "a list that filled the limit says older ones were not compared" "READ ONLY THE NEWEST 6 open issues" "$out_lim"
lacks "a list under the limit says nothing of the kind" "READ ONLY" "$out"

# ---- gh failing: a distinct message and a non zero exit, never an empty result ----
out="$(printf 'the rtk hook rewrites a prefixed grep\n' | PATH="$TMP/bin:$PATH" GH_FAIL_ISSUES=1 bash "$HELPER" "$REPO" 2>&1)"; rc=$?
is "gh failing on the issues exits 2" 2 "$rc"
has "gh failing on the issues says it could not look, and why" "COULD NOT LOOK: gh could not read the open issues of $REPO: HTTP 502" "$out"
out="$(printf 'the rtk hook rewrites a prefixed grep\n' | PATH="$TMP/bin:$PATH" GH_FAIL_PRS=1 bash "$HELPER" "$REPO" 2>&1)"; rc=$?
is "gh failing on the pull requests exits 2" 2 "$rc"
has "gh failing on the pull requests says which list it could not read" "COULD NOT LOOK: gh could not read the open pull requests of $REPO" "$out"
lacks "and no partial match list is offered as the answer" "MAY ALREADY BE COVERED" "$out"
out="$(printf 'the rtk hook rewrites a prefixed grep\n' | PATH="$TMP/bin:$PATH" GH_GARBLED=1 bash "$HELPER" "$REPO" 2>&1)"; rc=$?
is "output gh gave that is not a list exits 2" 2 "$rc"
has "output gh gave that is not a list says so" "COULD NOT LOOK: gh answered with something that is not the list of open issues" "$out"

# ---- no issue tracker, and a folder that is not a repository ----
out="$(printf 'the rtk hook rewrites a prefixed grep\n' | PATH="$TMP/bin:$PATH" GH_DISABLED=1 bash "$HELPER" "$REPO" 2>&1)"; rc=$?
is "a repository with issues turned off exits 2" 2 "$rc"
has "a repository with issues turned off says it has no issue tracker" "COULD NOT LOOK: $REPO has its issue tracker turned off" "$out"
mkdir -p "$TMP/not-a-repo"
out="$(printf 'the rtk hook rewrites a prefixed grep\n' | PATH="$TMP/bin:$PATH" GIT_CEILING_DIRECTORIES="$TMP" bash "$HELPER" "$TMP/not-a-repo" 2>&1)"; rc=$?
is "a folder that is not a repository exits 2" 2 "$rc"
has "a folder that is not a repository says so" "is not inside a git repository, so there is no issue tracker to read" "$out"

# ---- a folder that IS a repository is read through gh in that checkout ----
mkdir -p "$TMP/a-repo/sub"
git -C "$TMP/a-repo" init -q 2>/dev/null
: >"$TMP_CALLS"
out="$(printf 'Alert thread: the rtk hook rewrites a prefixed grep into rtk grep, which prints help and exits 0\n' | PATH="$TMP/bin:$PATH" bash "$HELPER" "$TMP/a-repo/sub" 2>&1)"; rc=$?
is "a folder inside a repository: exit 0" 0 "$rc"
has "a folder inside a repository is matched" "pull request #3653:" "$out"
lacks "a folder is read through its checkout, not as owner/repo" "--repo" "$(cat "$TMP_CALLS")"

# ---- a matcher that crashes, or is missing, is never read as nothing covering the item ----
printf 'raise RuntimeError("simulated crash")\n' >"$TMP/crash.py"
out="$(printf 'the rtk hook rewrites a prefixed grep\n' | PATH="$TMP/bin:$PATH" FIND_EXISTING_MATCHER="$TMP/crash.py" bash "$HELPER" "$REPO" 2>&1)"; rc=$?
is "a matcher that crashes exits 2" 2 "$rc"
has "a matcher that crashes says it could not look" "COULD NOT LOOK: the matcher stopped with exit 1" "$out"
out="$(printf 'the rtk hook rewrites a prefixed grep\n' | PATH="$TMP/bin:$PATH" FIND_EXISTING_MATCHER="$TMP/no-such.py" bash "$HELPER" "$REPO" 2>&1)"; rc=$?
is "a missing matcher exits 2" 2 "$rc"
has "a missing matcher says so" "COULD NOT LOOK: the matcher hooks/lib/match-open-issues.py is not beside this skill" "$out"
# A read limit that is not a number falls back to the default rather than crashing at import, which
# would take the end of turn review down with it.
out="$(printf 'FINDING (a, b): widget/cache.py keeps a stale entry\n' | PATH="$TMP/bin:$PATH" CLAUDE_ITEM_MATCH_LIMIT=lots python3 "$DIR/../../hooks/lib/match-open-issues.py" "$TMP/not-a-repo" 2>&1)"; rc=$?
is "a limit that is not a number leaves the review mode running" 0 "$rc"
lacks "and the review mode does not crash on it" "Traceback" "$out"

# ---- the call itself ----
out="$(printf '' | PATH="$TMP/bin:$PATH" bash "$HELPER" "$REPO" 2>&1)"; rc=$?
is "an empty item exits 2" 2 "$rc"
has "an empty item says there was nothing to match" "COULD NOT LOOK: no item text" "$out"
out="$(printf 'x\n' | PATH="$TMP/bin:$PATH" bash "$HELPER" 2>&1)"; rc=$?
is "no repository given exits 2" 2 "$rc"

echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
