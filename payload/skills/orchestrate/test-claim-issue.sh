#!/usr/bin/env bash
# Tests for claim-issue.sh, the claim an orchestrating session posts on an issue before a builder
# starts on it (claude-config#3317).
#
# On 2026-11-19 two sessions, one on each Mac, built the same fix for #3285: a branch that exists
# only in a local worktree is invisible to the other Mac, and nothing on the issue said it was taken.
# The script does the three reads (claims on the issue, open pull requests naming it, remote branches
# naming its number) and posts the claim in one step, so the skill's rule is "dispatch only on exit 0".
#
# A stand in gh on PATH answers from fixtures this suite writes, so no test reaches GitHub or posts a
# comment on a real issue. The stand in returns what the real gh prints AFTER the script's --jq
# filter, which is the boundary these tests hold; the filters themselves were checked against the
# real repository (see the pull request).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CLAIM_ISSUE_SCRIPT:-$DIR/claim-issue.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '  output: %s\n' "$2"; return 0; }
has() { # has <description> <expected substring> <actual>
  if [[ "$3" == *"$2"* ]]; then ok; else bad "$1 (no '$2')" "$3"; fi
}
lacks() { # lacks <description> <forbidden substring> <actual>
  if [[ "$3" != *"$2"* ]]; then ok; else bad "$1 (holds '$2')" "$3"; fi
}
is() { # is <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi
}

# ---- the stand in gh ----
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers from the fixture folder $FAKE, and records every call in $FAKE/calls.
printf '%s\n' "$*" >>"$FAKE/calls"
case "$1 $2" in
  "issue view")
    [ -e "$FAKE/fail_issue" ] && { echo "gh: HTTP 502 simulated" >&2; exit 1; }
    [ -e "$FAKE/empty_issue" ] && exit 0
    echo "STATE $(cat "$FAKE/state" 2>/dev/null || echo OPEN)"
    cat "$FAKE/markers" 2>/dev/null
    # A lagging read path: what was posted shows from the read after the first one.
    [ -e "$FAKE/pending" ] && { cat "$FAKE/pending" >>"$FAKE/markers"; rm -f "$FAKE/pending"; }
    exit 0 ;;
  "pr list")
    [ -e "$FAKE/fail_pr" ] && { echo "gh: HTTP 502 simulated" >&2; exit 1; }
    cat "$FAKE/prs" 2>/dev/null
    exit 0 ;;
  "issue comment")
    [ -e "$FAKE/fail_post" ] && { echo "gh: could not post, simulated" >&2; exit 1; }
    dest="$FAKE/markers"
    [ -e "$FAKE/lag" ] && dest="$FAKE/pending"
    [ -e "$FAKE/drop" ] && dest=/dev/null
    body=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--body-file" ] && body="$2"
      shift
    done
    [ -n "$body" ] || { echo "stand in gh: no --body-file" >&2; exit 1; }
    k=1
    while [ -e "$FAKE/posted.$k" ]; do k=$((k + 1)); done
    cp "$body" "$FAKE/posted.$k"
    # Another session's claim that reached GitHub a moment before this one.
    [ -e "$FAKE/race" ] && { cat "$FAKE/race" >>"$FAKE/markers"; rm -f "$FAKE/race"; }
    while IFS= read -r line; do
      case "$line" in "<!-- orchestrate-"*) echo "$CLAIM_NOW $line" >>"$dest" ;; esac
    done <"$body"
    # A write that landed but answered with an error, as a timeout or a 5xx can.
    [ -e "$FAKE/landed_but_failed" ] && { echo "gh: HTTP 504 simulated" >&2; exit 1; }
    exit 0 ;;
esac
if [ "$1" = api ]; then
  [ -e "$FAKE/fail_branches" ] && { echo "gh: HTTP 502 simulated" >&2; exit 1; }
  cat "$FAKE/branches" 2>/dev/null
  exit 0
fi
echo "stand in gh: unexpected call: $*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"

NOW=1795105539 # 2026-11-19 16:25:39 UTC, 11:25 AM ET
REPO=danwright32/claude-config
MINE=fix/3317-claim-before-building
case_n=0
new_case() { # a fresh fixture folder for each case
  case_n=$((case_n + 1))
  FAKE="$TMP/case$case_n"
  mkdir -p "$FAKE"
  : >"$FAKE/calls"
}
run() { # run <args...>   sets out and code
  out="$(PATH="$TMP/bin:$PATH" FAKE="$FAKE" CLAIM_NOW="$NOW" CLAIM_READBACK_WAIT=0 CLAIM_HOST="${HOST_OVERRIDE:-Daniels-MacBook-Pro-2}" bash "$SCRIPT" "$@" 2>&1)"
  code=$?
}
posted_count() { local n=0 f; for f in "$FAKE"/posted.*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }

[ -x "$SCRIPT" ] && ok || bad "claim-issue.sh exists and is executable" "$SCRIPT"

# ---- 1. nobody holds it: the claim is posted and says where, when and which branch ----
new_case
echo "fix/9999-other-thing" >"$FAKE/branches"
printf '4000\tfix/4000-unrelated\tSomething else\tCloses #4000\n' >"$FAKE/prs"
run claim "$REPO" 3317 "$MINE"
is "free issue: exit 0" 0 "$code"
has "free issue: says it is claimed" "CLAIMED" "$out"
is "free issue: one comment posted" 1 "$(posted_count)"
body="$(cat "$FAKE/posted.1" 2>/dev/null)"
has "claim names the Mac as Dan names it" "the personal MacBook" "$body"
has "claim gives the time in ET" "11:25 AM ET on 2026-11-19" "$body"
has "claim names the branch" "$MINE" "$body"
has "claim carries the marker a later check reads" "<!-- orchestrate-claim branch=$MINE host=Daniels-MacBook-Pro-2 -->" "$body"
lacks "claim never carries a session link" "claude.ai/code/session" "$body"

# The work MacBook is named as Dan names it too.
new_case
HOST_OVERRIDE=Dans-MacBook-Pro run claim "$REPO" 3317 "$MINE"
has "work Mac claim names the work MacBook" "the work MacBook" "$(cat "$FAKE/posted.1" 2>/dev/null)"

# ---- 2. a claim by another session: not started, and it says who holds it ----
new_case
echo "$((NOW - 3600)) <!-- orchestrate-claim branch=fix/3317-other-try host=Dans-MacBook-Pro -->" >"$FAKE/markers"
run claim "$REPO" 3317 "$MINE"
is "claimed elsewhere: exit 1" 1 "$code"
has "claimed elsewhere: says held" "HELD" "$out"
has "claimed elsewhere: names the Mac holding it" "the work MacBook" "$out"
has "claimed elsewhere: names the holder's branch" "fix/3317-other-try" "$out"
has "claimed elsewhere: gives the claim time in ET" "10:25 AM ET on 2026-11-19" "$out"
is "claimed elsewhere: nothing posted" 0 "$(posted_count)"

# A released claim no longer holds the issue.
new_case
{
  echo "$((NOW - 7200)) <!-- orchestrate-claim branch=fix/3317-other-try host=Dans-MacBook-Pro -->"
  echo "$((NOW - 3600)) <!-- orchestrate-release branch=fix/3317-other-try host=Dans-MacBook-Pro -->"
} >"$FAKE/markers"
run claim "$REPO" 3317 "$MINE"
is "released claim: exit 0" 0 "$code"
is "released claim: our claim posted" 1 "$(posted_count)"

# A claim past the stale window with no release does not block, and is reported.
new_case
echo "$((NOW - 25 * 3600)) <!-- orchestrate-claim branch=fix/3317-old-try host=Dans-MacBook-Pro -->" >"$FAKE/markers"
run claim "$REPO" 3317 "$MINE"
is "stale claim: exit 0" 0 "$code"
has "stale claim: reported as stale" "stale" "$out"
has "stale claim: names the stale branch" "fix/3317-old-try" "$out"

# Our own live claim: nothing new posted.
new_case
echo "$((NOW - 600)) <!-- orchestrate-claim branch=$MINE host=Daniels-MacBook-Pro-2 -->" >"$FAKE/markers"
run claim "$REPO" 3317 "$MINE"
is "own claim: exit 0" 0 "$code"
has "own claim: says already claimed" "ALREADY CLAIMED" "$out"
is "own claim: nothing posted" 0 "$(posted_count)"

# The same branch name claimed from the other Mac is someone else's.
new_case
echo "$((NOW - 600)) <!-- orchestrate-claim branch=$MINE host=Dans-MacBook-Pro -->" >"$FAKE/markers"
run claim "$REPO" 3317 "$MINE"
is "same branch from the other Mac: exit 1" 1 "$code"

# ---- 3. an open pull request naming the issue ----
new_case
printf '4100\tfix/steps-pane\tFix the pane\tCloses #3317 and more\n' >"$FAKE/prs"
run claim "$REPO" 3317 "$MINE"
is "open PR naming it: exit 1" 1 "$code"
has "open PR naming it: names the pull request" "#4100" "$out"
is "open PR naming it: nothing posted" 0 "$(posted_count)"

new_case
printf '4101\tfix/3317-elsewhere\tA title\tno reference\n' >"$FAKE/prs"
run claim "$REPO" 3317 "$MINE"
is "open PR whose branch names the number: exit 1" 1 "$code"

new_case
printf '4102\tfix/33170-other\tTouches #33170\tRefs #33171\n%s\t%s\t%s\t%s\n' 4103 "$MINE" "Ours" "Closes #3317" >"$FAKE/prs"
run claim "$REPO" 3317 "$MINE"
is "a longer number and our own branch's PR do not block: exit 0" 0 "$code"

# ---- 4. a remote branch naming its number ----
new_case
printf 'main\nfix/3317-someone-else\n' >"$FAKE/branches"
run claim "$REPO" 3317 "$MINE"
is "remote branch naming it: exit 1" 1 "$code"
has "remote branch naming it: names the branch" "fix/3317-someone-else" "$out"
is "remote branch naming it: nothing posted" 0 "$(posted_count)"

new_case
printf 'main\nfix/13317-x\nfix/33171-y\n%s\n' "$MINE" >"$FAKE/branches"
run claim "$REPO" 3317 "$MINE"
is "longer numbers and our own branch do not block: exit 0" 0 "$code"

# ---- 5. gh failing must never read as nobody holds it ----
for which in fail_issue fail_pr fail_branches empty_issue; do
  new_case
  : >"$FAKE/$which"
  run claim "$REPO" 3317 "$MINE"
  is "$which: exit 2" 2 "$code"
  has "$which: says it could not check" "COULD NOT CHECK" "$out"
  lacks "$which: never says free" "CLAIMED" "$out"
  is "$which: nothing posted" 0 "$(posted_count)"
done

# The shared branch reader failing (node missing or broken) is a read that failed too.
new_case
mkdir -p "$TMP/badnode"
printf '#!/usr/bin/env bash\necho "node: simulated failure" >&2\nexit 1\n' >"$TMP/badnode/node"
chmod +x "$TMP/badnode/node"
echo "fix/3317-someone-else" >"$FAKE/branches"
out="$(PATH="$TMP/badnode:$TMP/bin:$PATH" FAKE="$FAKE" CLAIM_NOW="$NOW" CLAIM_HOST=Daniels-MacBook-Pro-2 bash "$SCRIPT" claim "$REPO" 3317 "$MINE" 2>&1)"
code=$?
is "branch reader fails: exit 2" 2 "$code"
has "branch reader fails: says it could not check" "COULD NOT CHECK" "$out"
is "branch reader fails: nothing posted" 0 "$(posted_count)"

# The post itself failing: the claim's state is unknown, so the release command is named.
new_case
: >"$FAKE/fail_post"
run claim "$REPO" 3317 "$MINE"
is "post fails: exit 2" 2 "$code"
lacks "post fails: never says claimed" "CLAIMED:" "$out"
has "post fails: says a claim may still have landed" "may still have landed" "$out"
has "post fails: names the release command" "claim-issue.sh release $REPO 3317 $MINE" "$out"

# A post that answered with an error but landed is found on reading back, and holds.
new_case
: >"$FAKE/landed_but_failed"
run claim "$REPO" 3317 "$MINE"
is "post errored but landed: exit 0" 0 "$code"
has "post errored but landed: says claimed" "CLAIMED:" "$out"

# A read path that lags the write: the claim shows on the second read back.
new_case
: >"$FAKE/lag"
run claim "$REPO" 3317 "$MINE"
is "lagging read back: exit 0" 0 "$code"
has "lagging read back: says claimed" "CLAIMED:" "$out"
is "lagging read back: one comment posted" 1 "$(posted_count)"

# A claim that never shows on reading back: not started, and the release command named.
new_case
: >"$FAKE/drop"
run claim "$REPO" 3317 "$MINE"
is "claim never seen: exit 2" 2 "$code"
has "claim never seen: says it could not be seen" "could not be seen on reading it back 3 times" "$out"
has "claim never seen: names the release command" "claim-issue.sh release $REPO 3317 $MINE" "$out"

# ---- 6. two sessions racing: the earlier claim wins and ours is released ----
new_case
echo "$((NOW - 1)) <!-- orchestrate-claim branch=fix/3317-racer host=Dans-MacBook-Pro -->" >"$FAKE/race"
run claim "$REPO" 3317 "$MINE"
is "lost race: exit 1" 1 "$code"
has "lost race: names the winner" "fix/3317-racer" "$out"
is "lost race: our claim and its release posted" 2 "$(posted_count)"
has "lost race: second post is a release" "<!-- orchestrate-release branch=$MINE host=Daniels-MacBook-Pro-2 -->" "$(cat "$FAKE/posted.2" 2>/dev/null)"

# ---- 7. a closed issue is not started ----
new_case
echo CLOSED >"$FAKE/state"
run claim "$REPO" 3317 "$MINE"
is "closed issue: exit 1" 1 "$code"
has "closed issue: says closed" "CLOSED" "$out"
is "closed issue: nothing posted" 0 "$(posted_count)"

# ---- 8. check posts nothing ----
new_case
run check "$REPO" 3317 "$MINE"
is "check on a free issue: exit 0" 0 "$code"
has "check on a free issue: says free" "FREE" "$out"
is "check: nothing posted" 0 "$(posted_count)"

# ---- 9. release ----
new_case
echo "$((NOW - 600)) <!-- orchestrate-claim branch=$MINE host=Daniels-MacBook-Pro-2 -->" >"$FAKE/markers"
run release "$REPO" 3317 "$MINE" "handed back at the context line"
is "release of our claim: exit 0" 0 "$code"
is "release of our claim: one comment posted" 1 "$(posted_count)"
rel="$(cat "$FAKE/posted.1" 2>/dev/null)"
has "release carries the marker" "<!-- orchestrate-release branch=$MINE host=Daniels-MacBook-Pro-2 -->" "$rel"
has "release gives the reason" "handed back at the context line" "$rel"
has "release gives the time in ET" "11:25 AM ET on 2026-11-19" "$rel"
lacks "release never carries a session link" "claude.ai/code/session" "$rel"

new_case
run release "$REPO" 3317 "$MINE" "dropped"
is "release with no claim of ours: exit 0" 0 "$code"
is "release with no claim of ours: nothing posted" 0 "$(posted_count)"

new_case
: >"$FAKE/fail_issue"
run release "$REPO" 3317 "$MINE" "dropped"
is "release when the read fails: exit 2" 2 "$code"
has "release when the read fails: says the claim still stands" "COULD NOT RELEASE" "$out"
lacks "release when the read fails: never says nothing was claimed" "nothing was claimed" "$out"

# ---- 10. bad arguments call nothing ----
new_case
run claim "$REPO" 33x7 "$MINE"
is "a bad issue number: exit 2" 2 "$code"
is "a bad issue number: gh never called" "" "$(cat "$FAKE/calls")"
new_case
run claim "$REPO" 3317 "has space"
is "a bad branch name: exit 2" 2 "$code"
new_case
run release "$REPO" 3317 "$MINE"
is "a release with no reason: exit 2" 2 "$code"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
