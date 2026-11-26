#!/usr/bin/env bash
# Tests for claim-issue.sh, the claim an orchestrating session posts on an issue before a builder
# starts on it (claude-config#3317).
#
# On 2026-11-19 two sessions, one on each Mac, built the same fix for #3285: a branch that exists
# only in a local worktree is invisible to the other Mac, and nothing on the issue said it was taken.
# The script does the three reads (claims on the issue, open pull requests built for it, remote
# branches naming its number) and posts the claim in one step, so the skill's rule is "dispatch only
# on exit 0". A pull request that only mentions the issue is a note, never a hold (section 3b).
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

# ---- 3b. a pull request that only mentions the issue does not hold it (claude-config#3788) ----
# On 2026-11-26 three priority p1 issues could not be started: #3576 was held by pull request 3570
# (built for #3319), #3578 by 3734 and 3693 (built for #3561 and #3600) and #3602 by 3713 (built
# for #3620). Each only mentioned the issue. The head, the title, the built for line and the
# mentioning sentence of each row are those pull requests' own, read from GitHub on 2026-11-26.
pr_row() { printf '%s\t%s\t%s\t%s\n' "$@"; } # pr_row <number> <head> <title> <body>
seen_prs() {
  pr_row 3570 fix/3319-browser-ipv6-check \
    "Network check: refuse the helper browser's reachability probe so a browser run can end clean (#3319)" \
    "Main now holds pull request 3593, which reads a run as \`unmeasured\` when the Mac did not write every sandbox report the check asked for (#3576). Closes #3319"
  pr_row 3734 feat/3561-warning-names-orphan-process \
    "Low space warning: name a long running process with no parent (#3561)" \
    "Part of #3561. Left: the time limit runner for an agent's generated commands (#3578), and the agent rules' sentence requiring it, which waits on that runner."
  pr_row 3693 fix/3600-python-i-warnings-dash \
    "Read input run after -i, a PYTHONWARNINGS module and a dash named script in the Slack drafts gate (#3600)" \
    "The time limit wrapper for a suite run was refused the same way (claude-config#3578), so the suites ran plainly. Closes #3600"
  pr_row 3713 fix/3620-typed-escaped-substitution \
    "Stop the design round guard holding an escaped substitution typed whole on a command line" \
    "The script text case 3611 fixed still passes (in the first \`#3620\` test, and the #3602 tests are unchanged but for the lines that pinned the typed whole case as held). Closes #3620"
}

new_case
seen_prs >"$FAKE/prs"
run claim "$REPO" 3578 fix/3578-time-limit-runner
is "#3788 a pull request that mentions the issue in passing: exit 0" 0 "$code"
has "#3788 mentioned in passing: the issue is claimed" "CLAIMED" "$out"
lacks "#3788 mentioned in passing: never says held" "HELD" "$out"
is "#3788 mentioned in passing: the claim is posted" 1 "$(posted_count)"
has "#3788 mentioned in passing: a note names the first pull request" "mentioned, not held: pull request #3734" "$out"
has "#3788 mentioned in passing: a note names the second, which wrote the repository's name before the number" "mentioned, not held: pull request #3693" "$out"
lacks "#3788 mentioned in passing: a pull request that never names the issue is not printed" "#3570" "$out"

for seen in 3576:3570 3602:3713; do
  new_case
  seen_prs >"$FAKE/prs"
  run check "$REPO" "${seen%%:*}" "fix/${seen%%:*}-mine"
  is "#3788 #${seen%%:*} mentioned by ${seen##*:}: check exits 0" 0 "$code"
  has "#3788 #${seen%%:*} mentioned by ${seen##*:}: check says free" "FREE" "$out"
  has "#3788 #${seen%%:*} mentioned by ${seen##*:}: the note names it" "mentioned, not held: pull request #${seen##*:}" "$out"
done

# The same four pull requests still hold the issues they are built for, by each route alone: the
# branch's number is taken out of each row here, so only the title or the body is left to hold.
unnumbered() { seen_prs | awk -F '\t' -v OFS='\t' '{ $2 = "feat/no-number-" NR; print }'; }
for built in 3319:3570 3561:3734 3600:3693 3620:3713; do
  new_case
  unnumbered >"$FAKE/prs"
  run claim "$REPO" "${built%%:*}" "fix/${built%%:*}-mine"
  is "#3788 #${built%%:*} is what ${built##*:} is built for: exit 1" 1 "$code"
  has "#3788 #${built%%:*} is what ${built##*:} is built for: says held" "HELD" "$out"
  has "#3788 #${built%%:*} is what ${built##*:} is built for: names it as the holder" "pull request: #${built##*:}" "$out"
  lacks "#3788 #${built%%:*} is what ${built##*:} is built for: the holder is not also a note" "mentioned, not held" "$out"
  is "#3788 #${built%%:*} is what ${built##*:} is built for: nothing posted" 0 "$(posted_count)"
done

# A held issue still prints the pull requests that only mention it, under the one that holds it.
new_case
{ pr_row 4120 fix/steps-pane "Fix the pane" "Closes #3317"; pr_row 4121 fix/other "Another" "See #3317 for the measurement."; } >"$FAKE/prs"
run claim "$REPO" 3317 "$MINE"
is "#3788 one holds and one mentions: exit 1" 1 "$code"
has "#3788 one holds and one mentions: the holder is named" "pull request: #4120" "$out"
has "#3788 one holds and one mentions: the mention is a note" "mentioned, not held: pull request #4121" "$out"

# Each word that means built for, alone in a body with no number in the title or the branch. "Refs"
# is the repository's own word for a pull request built for an issue it will not close: 9 lines in
# the 300 pull requests merged before 2026-11-26, each naming the issue its branch names (#3500's
# sentences are the two used here). A colon, capitals and the repository written out all count.
holds_body() { # holds_body <description> <body>
  new_case
  pr_row 4130 feat/no-number "A title" "$2" >"$FAKE/prs"
  run check "$REPO" 3317 "$MINE"
  is "#3788 built for, by its body: $1: exit 1" 1 "$code"
  has "#3788 built for, by its body: $1: names the pull request" "pull request: #4130" "$out"
}
for word in close closes closed fix fixes fixed resolve resolves resolved Closes CLOSES "Part of" "part of" Refs; do
  holds_body "$word" "Some lines first. $word #3317"
done
holds_body "a keyword and a colon" "Closes: #3317"
holds_body "the keyword mid sentence" "This closes #3317, and the suite is unchanged."
holds_body "the repository written out in full" "Closes danwright32/claude-config#3317."
holds_body "the repository's name alone" "Part of claude-config#3317."
holds_body "It refs" "Because that point is open, this does not close issue #3475. It refs #3317."
holds_body "a mention first and the built for line after it" "Follows #3317's design. Part of #3317."

new_case
pr_row 4131 feat/no-number "Fix the pane (#3317)" "no reference" >"$FAKE/prs"
run check "$REPO" 3317 "$MINE"
is "#3788 built for, by its title: exit 1" 1 "$code"
has "#3788 built for, by its title: names the pull request" "pull request: #4131" "$out"

# What does not mean built for: each is a note, never a hold. The sentences are shapes read from
# the repository's own pull requests (the first three from #3489, #3776 and #3209).
notes_body() { # notes_body <description> <body>
  new_case
  pr_row 4140 feat/no-number "A title" "$2" >"$FAKE/prs"
  run check "$REPO" 3317 "$MINE"
  is "#3788 only a mention: $1: exit 0" 0 "$code"
  has "#3788 only a mention: $1: says free" "FREE" "$out"
  has "#3788 only a mention: $1: the note names the pull request" "mentioned, not held: pull request #4140 (feat/no-number)" "$out"
}
notes_body "a fix for" "A small fix for #3317 inside the existing helper reading."
notes_body "the keyword after the number" "The cost: the hole #3317 closed is open again."
notes_body "follow up to" "Follow up to #3317 (pull request #3199)."
notes_body "stacked on" "This branch is stacked on #3317, which changes the same part."
notes_body "a keyword inside a longer word" "It prefixes #3317 with the name."
notes_body "a keyword before another issue only" "Closes #4000. See #3317."
notes_body "another repository's issue of the same number" "Closes other/tool#3317."
notes_body "a fork's issue of the same number" "Closes someone/claude-config#3317."

# A longer number is neither a hold nor a note.
new_case
pr_row 4150 feat/no-number "Touches #33170" "Closes #33171 and part of #33172." >"$FAKE/prs"
run check "$REPO" 3317 "$MINE"
is "#3788 a longer number after a keyword: exit 0" 0 "$code"
lacks "#3788 a longer number after a keyword: no note either" "#4150" "$out"

# The pull request read failing beside a pull request that only mentions the issue is still a
# failed read: the note must never stand in for the answer.
new_case
seen_prs >"$FAKE/prs"
: >"$FAKE/fail_pr"
run claim "$REPO" 3578 fix/3578-time-limit-runner
is "#3788 the pull request read fails: exit 2" 2 "$code"
has "#3788 the pull request read fails: says it could not check" "COULD NOT CHECK" "$out"
lacks "#3788 the pull request read fails: never says claimed" "CLAIMED" "$out"
is "#3788 the pull request read fails: nothing posted" 0 "$(posted_count)"

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

# A lost race prints the pull requests that only mention the issue too (claude-config#3788).
new_case
echo "$((NOW - 1)) <!-- orchestrate-claim branch=fix/3317-racer host=Dans-MacBook-Pro -->" >"$FAKE/race"
pr_row 4160 fix/other "Another" "See #3317 for the measurement." >"$FAKE/prs"
run claim "$REPO" 3317 "$MINE"
is "#3788 lost race beside a mention: exit 1" 1 "$code"
has "#3788 lost race beside a mention: the note is printed" "mentioned, not held: pull request #4160" "$out"

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
