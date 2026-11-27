#!/usr/bin/env bash
# Tests for claim-issue.sh, the claim an orchestrating session posts on an issue before a builder
# starts on it (claude-config#3317).
#
# On 2026-11-19 two sessions, one on each Mac, built the same fix for #3285: a branch that exists
# only in a local worktree is invisible to the other Mac, and nothing on the issue said it was taken.
# The script does the three reads (claims on the issue, open pull requests built for it, remote
# branches naming its number) and posts the claim in one step, so the skill's rule is "dispatch only
# on exit 0". A pull request that only mentions the issue is a note, never a hold (section 3b).
# A claim names the session that made it, so two sessions on one Mac under one branch name are two
# claimants, and a branch or pull request under the claimed name is the caller's only when its own
# claim accounts for it (section 11, claude-config#3804).
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
    # GitHub stamps a comment with its own clock, which is not always this Mac's.
    stamp="$CLAIM_NOW"
    [ -e "$FAKE/stamp" ] && stamp="$(cat "$FAKE/stamp")"
    while IFS= read -r line; do
      case "$line" in "<!-- orchestrate-"*) echo "$stamp $line" >>"$dest" ;; esac
    done <"$body"
    # Another session's claim that reached GitHub a moment after this one.
    [ -e "$FAKE/late" ] && { cat "$FAKE/late" >>"$FAKE/markers"; rm -f "$FAKE/late"; }
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
# Which session is calling (claude-config#3804). Claude Code gives every command a session runs its
# id in CLAUDE_CODE_SESSION_ID, and a claim carries a short name made from it. SID and OSID are the
# short names of the two stand in ids below, written out and not computed here, so a change to how
# the short name is made (which would turn every live claim into a stranger's) fails this suite.
SESSION=11111111-2222-4333-8444-555555555555
OTHER_SESSION=99999999-8888-4777-8666-555555555555
SID=cf4c4732fd3b
OSID=89d07480e9d0
THIS_MAC=Daniels-MacBook-Pro-2
# marker <seconds ago> <claim|release> <branch> <host word>: one marker line as the stand in gh
# returns it. The host word is the Mac alone on a claim posted before claims named their session,
# and "<Mac>,session=<short name>" since.
marker() { echo "$((NOW - $1)) <!-- orchestrate-$2 branch=$3 host=$4 -->"; }
mine() { marker "$1" "$2" "${3:-$MINE}" "$THIS_MAC,session=$SID"; }     # this session's
theirs() { marker "$1" "$2" "${3:-$MINE}" "$THIS_MAC,session=$OSID"; }  # another session's, this Mac
unnamed() { marker "$1" "$2" "${3:-$MINE}" "${4:-$THIS_MAC}"; }         # no session recorded
case_n=0
new_case() { # a fresh fixture folder for each case
  case_n=$((case_n + 1))
  FAKE="$TMP/case$case_n"
  mkdir -p "$FAKE"
  : >"$FAKE/calls"
}
run() { # run <args...>   sets out and code
  out="$(PATH="$TMP/bin:$PATH" FAKE="$FAKE" CLAIM_NOW="$NOW" CLAIM_READBACK_WAIT=0 CLAIM_HOST="${HOST_OVERRIDE:-$THIS_MAC}" CLAUDE_CODE_SESSION_ID="${SESSION_OVERRIDE:-$SESSION}" bash "$SCRIPT" "$@" 2>&1)"
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
has "claim carries the marker a later check reads, naming the session that made it" "<!-- orchestrate-claim branch=$MINE host=$THIS_MAC,session=$SID -->" "$body"
lacks "claim never carries a session link" "claude.ai/code/session" "$body"
lacks "#3804 the claim never carries the session's own id, only the short name made from it" "$SESSION" "$body"
is "#3804 the sentence a person reads stays plain: the session is named in the marker alone" \
  "Claimed for building by an orchestrating session on the personal MacBook at 11:25 AM ET on 2026-11-19, on branch \`$MINE\`. Another session should not start on this issue while the claim stands. If the work is dropped or handed back unfinished, a release is posted here; a claim with no release stops counting after 24 hours." \
  "$(sed -n 1p "$FAKE/posted.1" 2>/dev/null)"
# Every version of this script before #3804 reads a marker only when it is exactly six words, the
# fifth starting host=. The session rides inside that word, so a Mac still on the earlier script
# reads the claim as another Mac's and holds; a seventh word would have hidden the claim from it.
is "#3804 the marker is still the six words an earlier version of the script reads" 1 \
  "$(awk 'NF == 5 && $1 == "<!--" && $2 == "orchestrate-claim" && $3 ~ /^branch=/ && $4 ~ /^host=/ && $5 == "-->"' "$FAKE/posted.1" 2>/dev/null | wc -l | tr -d ' ')"

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
mine 600 claim >"$FAKE/markers"
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
mine 600 claim >"$FAKE/markers" # what makes the pull request on our branch ours (section 11)
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
mine 600 claim >"$FAKE/markers" # what makes the remote branch of our name ours (section 11)
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
out="$(PATH="$TMP/badnode:$TMP/bin:$PATH" FAKE="$FAKE" CLAIM_NOW="$NOW" CLAIM_HOST="$THIS_MAC" CLAUDE_CODE_SESSION_ID="$SESSION" bash "$SCRIPT" claim "$REPO" 3317 "$MINE" 2>&1)"
code=$?
is "branch reader fails: exit 2" 2 "$code"
has "branch reader fails: says it could not check" "COULD NOT CHECK" "$out"
is "branch reader fails: nothing posted" 0 "$(posted_count)"

# ---- 5b. a tool that reads what gh returned failing is a failed read too (claude-config#3788) ----
# gh answering is half of a read: awk picks the live claims out of the issue's marker lines, sed its
# state, cut and cat the branch names, grep which of them name the issue. Each of these failing left
# its answer empty, and an empty answer read as nobody holding the issue.
# break_tool <tool> <case pattern> [<case pattern left working>]: a stand in for one tool, first on
# PATH for run_broken, that fails when its arguments match and is the real tool otherwise. With the
# file break_after_post in the case's folder it also works until the claim has been posted.
break_tool() {
  local real
  real="$(command -v "$1")"
  rm -rf "$TMP/broken"
  mkdir -p "$TMP/broken"
  cat >"$TMP/broken/$1" <<STUB
#!/bin/bash
if [ -e "\$FAKE/break_after_post" ] && [ ! -e "\$FAKE/posted.1" ]; then exec "$real" "\$@"; fi
case "\$*" in
  ${3:-__no_exception__}) ;;
  $2) echo "$1: simulated failure" >&2; exit 2 ;;
esac
exec "$real" "\$@"
STUB
  chmod +x "$TMP/broken/$1"
}
run_broken() { # run_broken <args...>   as run, with the broken tool first on PATH
  out="$(PATH="$TMP/broken:$TMP/bin:$PATH" FAKE="$FAKE" CLAIM_NOW="$NOW" CLAIM_READBACK_WAIT=0 CLAIM_HOST="$THIS_MAC" CLAUDE_CODE_SESSION_ID="$SESSION" bash "$SCRIPT" "$@" 2>&1)"
  code=$?
}
could_not_check() { # could_not_check <description>   after a claim or a check
  is "#3788 $1: exit 2" 2 "$code"
  has "#3788 $1: says it could not check" "COULD NOT CHECK" "$out"
  has "#3788 $1: prints the tool's own error" "simulated failure" "$out"
  lacks "#3788 $1: never says free" "FREE" "$out"
  lacks "#3788 $1: never says claimed" "CLAIMED" "$out"
  lacks "#3788 $1: never says closed" "CLOSED" "$out"
  is "#3788 $1: nothing posted" 0 "$(posted_count)"
}
other_claim() { echo "$((NOW - 3600)) <!-- orchestrate-claim branch=fix/3317-other-try host=Dans-MacBook-Pro -->" >"$FAKE/markers"; }

# awk failing while another session holds a live claim: the claim cannot be seen, so nothing is known.
break_tool awk '*'
for mode in check claim; do
  new_case
  other_claim
  run_broken "$mode" "$REPO" 3317 "$MINE"
  could_not_check "the claims reader fails on a $mode of an issue another session holds"
done

# awk failing only on the read back: our claim is up and cannot be seen, so the release is named.
new_case
: >"$FAKE/break_after_post"
run_broken claim "$REPO" 3317 "$MINE"
is "#3788 the claims reader fails on the read back: exit 2" 2 "$code"
has "#3788 the claims reader fails on the read back: says it could not check" "COULD NOT CHECK" "$out"
has "#3788 the claims reader fails on the read back: names the release command" "claim-issue.sh release $REPO 3317 $MINE" "$out"
has "#3788 the claims reader fails on the read back: prints the tool's own error" "simulated failure" "$out"
lacks "#3788 the claims reader fails on the read back: never says claimed" "CLAIMED:" "$out"

# awk failing on a release: our claim cannot be seen, which is not the same as there being none.
new_case
mine 600 claim >"$FAKE/markers"
run_broken release "$REPO" 3317 "$MINE" "handed back unfinished"
is "#3788 the claims reader fails on a release: exit 2" 2 "$code"
has "#3788 the claims reader fails on a release: says it could not release" "COULD NOT RELEASE" "$out"
lacks "#3788 the claims reader fails on a release: never says there was nothing to release" "NOTHING TO RELEASE" "$out"
is "#3788 the claims reader fails on a release: nothing posted" 0 "$(posted_count)"

# sed failing on the issue's state: an unread state is not a closed issue.
break_tool sed '*STATE*'
new_case
run_broken claim "$REPO" 3317 "$MINE"
could_not_check "the state reader fails"

# cut failing on the pull requests' branches: a pull request that holds by its branch alone.
break_tool cut '*'
new_case
pr_row 4101 fix/3317-elsewhere "A title" "no reference" >"$FAKE/prs"
run_broken check "$REPO" 3317 "$MINE"
could_not_check "the pull request branch reader fails"

# cat failing on the remote branches the script saved (the stand in gh's own cat is left working).
break_tool cat '*/branches' '*/case[0-9]*/branches'
new_case
printf 'main\nfix/3317-someone-else\n' >"$FAKE/branches"
run_broken check "$REPO" 3317 "$MINE"
could_not_check "the remote branch reader fails"

# grep failing on which branches name the issue: an error is not the same as no match.
break_tool grep '*"-x -F"*'
new_case
printf 'main\nfix/3317-someone-else\n' >"$FAKE/branches"
run_broken check "$REPO" 3317 "$MINE"
could_not_check "the naming lookup fails"

# Each of those tools working, on the same fixtures, still gives the ordinary answers.
rm -rf "$TMP/broken"
new_case
printf 'main\nfix/3317-someone-else\n' >"$FAKE/branches"
run_broken check "$REPO" 3317 "$MINE"
is "#3788 no tool broken, a remote branch names it: exit 1" 1 "$code"
new_case
run_broken check "$REPO" 3317 "$MINE"
is "#3788 no tool broken, nothing holds it: exit 0" 0 "$code"
has "#3788 no tool broken, nothing holds it: says free" "FREE" "$out"

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
has "lost race: second post is a release" "<!-- orchestrate-release branch=$MINE host=$THIS_MAC,session=$SID -->" "$(cat "$FAKE/posted.2" 2>/dev/null)"

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
mine 600 claim >"$FAKE/markers"
run release "$REPO" 3317 "$MINE" "handed back at the context line"
is "release of our claim: exit 0" 0 "$code"
is "release of our claim: one comment posted" 1 "$(posted_count)"
rel="$(cat "$FAKE/posted.1" 2>/dev/null)"
has "release carries the marker" "<!-- orchestrate-release branch=$MINE host=$THIS_MAC,session=$SID -->" "$rel"
lacks "#3804 the release never carries the session's own id" "$SESSION" "$rel"
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

# ---- 11. two sessions on one Mac are two claimants (claude-config#3804) ----
# Until 2026-11-27 a claim was told from another session's by the Mac and the branch name alone, and
# branch names are written from the issue's title, so two sessions on one Mac reach the same name.
# Each case below was seen on the personal MacBook on 2026-11-26; the issue numbers, the branch name
# and the pull request number of the first are the real ones.

# 11a. #3674, about 8:25 PM ET: `claim` under another session's branch name, that session's claim
# live and its pull request 3701 open on the branch, answered ALREADY CLAIMED, exit 0, which the
# skill reads as "start the builder". That claim, like every claim posted before this change, named
# no session.
SEEN=fix/3674-launch-order-near-zero-swap
staged_3674() { # staged_3674 <marker line>: the issue as it stood, under the given claim
  new_case
  echo "$1" >"$FAKE/markers"
  pr_row 3701 "$SEEN" "Launch order: swap the near zero pair" "Closes #3674" >"$FAKE/prs"
  printf 'main\n%s\n' "$SEEN" >"$FAKE/branches"
}
for mode in claim check; do
  staged_3674 "$(unnamed $((23 * 3600)) claim "$SEEN")" # posted the day before, and still live
  run "$mode" "$REPO" 3674 "$SEEN"
  is "#3804 $mode under a branch another session claimed with no session recorded: exit 1" 1 "$code"
  has "#3804 $mode under a branch another session claimed with no session recorded: says held" "HELD" "$out"
  lacks "#3804 $mode under a branch another session claimed with no session recorded: never already claimed" "ALREADY CLAIMED" "$out"
  has "#3804 $mode under a branch another session claimed with no session recorded: says the claim names no session" "with no session recorded" "$out"
  has "#3804 $mode under a branch another session claimed with no session recorded: names its open pull request" "pull request: #3701" "$out"
  has "#3804 $mode under a branch another session claimed with no session recorded: says the pull request is not this session's" "which no claim of this session's accounts for" "$out"
  has "#3804 $mode under a branch another session claimed with no session recorded: says how to take it over on purpose" "claim-issue.sh takeover $REPO 3674 $SEEN \"<reason>\", then claim again" "$out"
  lacks "#3804 $mode under a branch another session claimed with no session recorded: never offers a plain release as the way" "claim-issue.sh release $REPO 3674" "$out"
  is "#3804 $mode under a branch another session claimed with no session recorded: nothing posted" 0 "$(posted_count)"
done

# The same with the other session named in its claim, as every claim is from now on. Its claim is
# its own to release, so no way to take it over is offered.
for mode in claim check; do
  staged_3674 "$(theirs 3600 claim "$SEEN")"
  run "$mode" "$REPO" 3674 "$SEEN"
  is "#3804 $mode under another session's branch name on this Mac: exit 1" 1 "$code"
  has "#3804 $mode under another session's branch name on this Mac: says held" "HELD" "$out"
  lacks "#3804 $mode under another session's branch name on this Mac: never already claimed" "ALREADY CLAIMED" "$out"
  has "#3804 $mode under another session's branch name on this Mac: says another session on this Mac holds it" "claim: another session on the personal MacBook claimed it at 10:25 AM ET on 2026-11-19, branch $SEEN" "$out"
  has "#3804 $mode under another session's branch name on this Mac: names its open pull request" "pull request: #3701" "$out"
  lacks "#3804 $mode under another session's branch name on this Mac: offers no take over" "then claim again" "$out"
  is "#3804 $mode under another session's branch name on this Mac: nothing posted" 0 "$(posted_count)"
done

# Another session's claim with nothing pushed yet holds as well: the claim alone is enough.
new_case
theirs 3600 claim >"$FAKE/markers"
run claim "$REPO" 3317 "$MINE"
is "#3804 another session's claim on our branch name, nothing pushed: exit 1" 1 "$code"
lacks "#3804 another session's claim on our branch name, nothing pushed: never already claimed" "ALREADY CLAIMED" "$out"

# A claim from the other Mac that names no session is the other Mac's, and cannot be released from
# here, so no take over is offered.
new_case
unnamed 3600 claim "$MINE" Dans-MacBook-Pro >"$FAKE/markers"
run claim "$REPO" 3317 "$MINE"
is "#3804 the other Mac's claim with no session recorded: exit 1" 1 "$code"
lacks "#3804 the other Mac's claim with no session recorded: offers no take over" "then claim again" "$out"

# 11b. The calling session's own claim, with its pull request open and its branch pushed: ALREADY
# CLAIMED, from `claim` and from `check`, and both are said to be its own.
for mode in claim check; do
  staged_3674 "$(mine 3600 claim "$SEEN")"
  run "$mode" "$REPO" 3674 "$SEEN"
  is "#3804 $mode by the session that holds the claim: exit 0" 0 "$code"
  has "#3804 $mode by the session that holds the claim: says already claimed" "ALREADY CLAIMED" "$out"
  has "#3804 $mode by the session that holds the claim: says the claim is this session's" "this session's claim on branch $SEEN" "$out"
  has "#3804 $mode by the session that holds the claim: says the pull request is its own" "this session's own, by its claim on the issue: pull request #3701 ($SEEN)" "$out"
  has "#3804 $mode by the session that holds the claim: says the remote branch is its own" "this session's own, by its claim on the issue: remote branch $SEEN" "$out"
  is "#3804 $mode by the session that holds the claim: nothing posted" 0 "$(posted_count)"
done

# A session is the same session after a restart or a compaction: Claude Code gives it the same id
# (measured, see the script's header), so a second run of the script, which is a new process each
# time, finds the claim the first one posted.
new_case
run claim "$REPO" 3317 "$MINE"
has "#3804 first run: claimed" "CLAIMED:" "$out"
run claim "$REPO" 3317 "$MINE"
is "#3804 the same session, run again: exit 0" 0 "$code"
has "#3804 the same session, run again: says already claimed" "ALREADY CLAIMED" "$out"
is "#3804 the same session, run again: one comment posted in all" 1 "$(posted_count)"
SESSION_OVERRIDE="$OTHER_SESSION" run claim "$REPO" 3317 "$MINE"
is "#3804 another session, same Mac and same branch name, after it: exit 1" 1 "$code"
has "#3804 another session, same Mac and same branch name, after it: says held" "HELD" "$out"
is "#3804 another session, same Mac and same branch name, after it: still one comment posted" 1 "$(posted_count)"

# This session's own claim under another branch name holds too, and is said to be its own.
new_case
mine 600 claim fix/3317-first-name >"$FAKE/markers"
run claim "$REPO" 3317 "$MINE"
is "#3804 this session's claim under another branch name: exit 1" 1 "$code"
has "#3804 this session's claim under another branch name: says it is its own" "this session's own claim, under another branch name" "$out"

# 11c. #3546: `claim` under a branch name that already existed on GitHub (another session's pushed,
# unfinished build, with no pull request and no live claim) answered CLAIMED. A branch or a pull
# request under the name being claimed is this session's only when its own claim accounts for it.
for mode in claim check; do
  new_case
  printf 'main\nfix/3546-pushed-by-another\n' >"$FAKE/branches"
  run "$mode" "$REPO" 3546 fix/3546-pushed-by-another
  is "#3804 $mode under a branch name already on GitHub, no claim: exit 1" 1 "$code"
  has "#3804 $mode under a branch name already on GitHub, no claim: says held" "HELD" "$out"
  has "#3804 $mode under a branch name already on GitHub, no claim: names the branch as not this session's" "remote branch: fix/3546-pushed-by-another (the branch name being claimed, which no claim of this session's accounts for)" "$out"
  is "#3804 $mode under a branch name already on GitHub, no claim: nothing posted" 0 "$(posted_count)"
done

# The same when the name carries no issue number: a name already on GitHub that this session did
# not make is not a name to start a builder on.
new_case
printf 'main\nfeat/claim-names-session\n' >"$FAKE/branches"
run claim "$REPO" 3317 feat/claim-names-session
is "#3804 a claimed name with no number, already on GitHub: exit 1" 1 "$code"
has "#3804 a claimed name with no number, already on GitHub: names the branch" "remote branch: feat/claim-names-session" "$out"

new_case
pr_row 4170 feat/claim-names-session "A title" "no reference" >"$FAKE/prs"
run claim "$REPO" 3317 feat/claim-names-session
is "#3804 an open pull request on the claimed name, no claim: exit 1" 1 "$code"
has "#3804 an open pull request on the claimed name, no claim: names it as not this session's" "pull request: #4170 (feat/claim-names-session) A title (the branch name being claimed, which no claim of this session's accounts for)" "$out"
is "#3804 an open pull request on the claimed name, no claim: nothing posted" 0 "$(posted_count)"

# Another session's claim on the name went stale, with its branch pushed: the stale claim no longer
# holds, and the branch it pushed still does.
new_case
theirs $((25 * 3600)) claim >"$FAKE/markers"
printf 'main\n%s\n' "$MINE" >"$FAKE/branches"
run claim "$REPO" 3317 "$MINE"
is "#3804 another session's stale claim and its pushed branch: exit 1" 1 "$code"
has "#3804 another session's stale claim and its pushed branch: the branch holds" "remote branch: $MINE (the branch name being claimed" "$out"
has "#3804 another session's stale claim and its pushed branch: the stale claim is printed" "stale claim" "$out"

# 11d. What accounts for a branch: this session's claim on that name, live or ended, when it was
# the one holding the issue. Its own stale claim, and its own released claim, still do.
new_case
mine $((25 * 3600)) claim >"$FAKE/markers"
printf 'main\n%s\n' "$MINE" >"$FAKE/branches"
pr_row 4171 "$MINE" "Ours" "Closes #3317" >"$FAKE/prs"
run claim "$REPO" 3317 "$MINE"
is "#3804 our own stale claim, our branch and pull request up: exit 0" 0 "$code"
has "#3804 our own stale claim, our branch and pull request up: a fresh claim is posted" "CLAIMED:" "$out"
is "#3804 our own stale claim, our branch and pull request up: one comment posted" 1 "$(posted_count)"

new_case
{ mine 7200 claim; mine 3600 release; } >"$FAKE/markers"
printf 'main\n%s\n' "$MINE" >"$FAKE/branches"
run claim "$REPO" 3317 "$MINE"
is "#3804 our own released claim, our branch still up: exit 0" 0 "$code"
has "#3804 our own released claim, our branch still up: claimed again" "CLAIMED:" "$out"

# An earlier session claimed and released the name before this session claimed it: the later claim
# is the one that accounts for the branch.
new_case
{ theirs 90000 claim; theirs 89000 release; mine 88000 claim; } >"$FAKE/markers"
printf 'main\n%s\n' "$MINE" >"$FAKE/branches"
run claim "$REPO" 3317 "$MINE"
is "#3804 an earlier session released the name before we claimed it: exit 0" 0 "$code"

# A claim that lost the race never held the issue, so it accounts for nothing: the winner's branch
# and pull request under the same name are still the winner's a day later, its claim gone stale.
new_case
{ theirs 90000 claim; mine 89999 claim; mine 89990 release; } >"$FAKE/markers"
printf 'main\n%s\n' "$MINE" >"$FAKE/branches"
pr_row 4172 "$MINE" "The winner's" "Closes #3317" >"$FAKE/prs"
run claim "$REPO" 3317 "$MINE"
is "#3804 the name's winner went stale, its pull request open: exit 1" 1 "$code"
has "#3804 the name's winner went stale, its pull request open: the pull request holds" "pull request: #4172" "$out"
is "#3804 the name's winner went stale, its pull request open: nothing posted" 0 "$(posted_count)"

# Losing the race to another session on this Mac under the same branch name: ours is released, by
# its session, and the winner's is left standing.
new_case
theirs 1 claim >"$FAKE/race"
run claim "$REPO" 3317 "$MINE"
is "#3804 lost race to a session on this Mac with the same branch name: exit 1" 1 "$code"
has "#3804 lost race to a session on this Mac with the same branch name: says held" "HELD" "$out"
is "#3804 lost race to a session on this Mac with the same branch name: our claim and its release posted" 2 "$(posted_count)"
has "#3804 lost race to a session on this Mac with the same branch name: the release names our session" "<!-- orchestrate-release branch=$MINE host=$THIS_MAC,session=$SID -->" "$(cat "$FAKE/posted.2" 2>/dev/null)"
SESSION_OVERRIDE="$OTHER_SESSION" run check "$REPO" 3317 "$MINE"
has "#3804 lost race to a session on this Mac with the same branch name: the winner still holds its claim" "ALREADY CLAIMED" "$out"

# 11e. A claim with no session recorded, and the two words that meet it. Nothing says whose such a
# claim is, and the skill's Finish step runs `release` for every claim a session believes it posted,
# so a plain `release` never ends one: until the review of this change it did, and a session that
# had wrongly been told ALREADY CLAIMED (the #3674 case) would have ended the other session's live
# claim with its routine release and been recorded as the one that took it over. Taking one over is
# a separate word, `takeover`, run on purpose by the session that knows the claim is its own.
staged_3674 "$(unnamed 3600 claim "$SEEN")"
run release "$REPO" 3674 "$SEEN" "the item ended without closing its issue"
is "#3804 a plain release under a claim with no session recorded: exit 1" 1 "$code"
has "#3804 a plain release under a claim with no session recorded: says not released" "NOT RELEASED:" "$out"
has "#3804 a plain release under a claim with no session recorded: says the claim records no session" "records no session" "$out"
has "#3804 a plain release under a claim with no session recorded: says that claim still stands" "that claim still stands" "$out"
has "#3804 a plain release under a claim with no session recorded: names the command, only if the claim is its own" "only if that claim is this session's own, posted before claims named their session, run: claim-issue.sh takeover $REPO 3674 $SEEN \"<reason>\"" "$out"
is "#3804 a plain release under a claim with no session recorded: nothing posted" 0 "$(posted_count)"
# The claim it did not end still holds, for the caller and for any other session.
run claim "$REPO" 3674 "$SEEN"
is "#3804 a plain release under a claim with no session recorded, the claim after it: exit 1" 1 "$code"
has "#3804 a plain release under a claim with no session recorded, the claim after it: the claim still holds" "with no session recorded" "$out"
is "#3804 a plain release under a claim with no session recorded, the claim after it: nothing posted" 0 "$(posted_count)"
SESSION_OVERRIDE="$OTHER_SESSION" run check "$REPO" 3674 "$SEEN"
is "#3804 a plain release under a claim with no session recorded, another session after it: exit 1" 1 "$code"

# The take over, on purpose: `takeover`, then a claim.
staged_3674 "$(unnamed 3600 claim "$SEEN")"
run takeover "$REPO" 3674 "$SEEN" "taking over this session's own claim, posted before claims named their session"
is "#3804 take over: exit 0" 0 "$code"
has "#3804 take over: says taken over" "TAKEN OVER:" "$out"
has "#3804 take over: says the claim had no session recorded" "no session recorded" "$out"
has "#3804 take over: says the branch name passes to this session" "counts the branch and its pull request as its own" "$out"
is "#3804 take over: one comment posted" 1 "$(posted_count)"
rel="$(cat "$FAKE/posted.1" 2>/dev/null)"
has "#3804 take over: ends the claim in the words it was posted in" "<!-- orchestrate-release branch=$SEEN host=$THIS_MAC -->" "$rel"
has "#3804 take over: names the session that took it over" "<!-- orchestrate-release branch=$SEEN host=$THIS_MAC,session=$SID -->" "$rel"
has "#3804 take over: the comment gives the reason" "taking over this session's own claim" "$rel"
run claim "$REPO" 3674 "$SEEN"
is "#3804 take over, the claim after it: exit 0" 0 "$code"
has "#3804 take over, the claim after it: claimed" "CLAIMED:" "$out"
has "#3804 take over, the claim after it: the pull request is now this session's" "this session's own, by its claim on the issue: pull request #3701" "$out"
is "#3804 take over, the claim after it: the take over and the claim posted" 2 "$(posted_count)"
# Another session that did not take it over is still held, by the claim and by the pull request.
SESSION_OVERRIDE="$OTHER_SESSION" run claim "$REPO" 3674 "$SEEN"
is "#3804 take over, a third session afterwards: exit 1" 1 "$code"

# The same claim gone stale: it no longer holds, the pull request under its name still does, the
# way to take it over is still said, a plain release still leaves it alone, and the take over
# still works.
staged_3674 "$(unnamed $((25 * 3600)) claim "$SEEN")"
run claim "$REPO" 3674 "$SEEN"
is "#3804 a stale claim with no session recorded, its pull request open: exit 1" 1 "$code"
has "#3804 a stale claim with no session recorded, its pull request open: the pull request holds" "pull request: #3701" "$out"
has "#3804 a stale claim with no session recorded, its pull request open: says how to take it over" "claim-issue.sh takeover $REPO 3674 $SEEN \"<reason>\", then claim again" "$out"
run release "$REPO" 3674 "$SEEN" "the item ended without closing its issue"
is "#3804 a plain release under a stale claim with no session recorded: exit 1" 1 "$code"
is "#3804 a plain release under a stale claim with no session recorded: nothing posted" 0 "$(posted_count)"
run claim "$REPO" 3674 "$SEEN"
is "#3804 a plain release under a stale claim with no session recorded, the claim after it: still exit 1" 1 "$code"
run takeover "$REPO" 3674 "$SEEN" "taking over this session's own claim"
is "#3804 a stale claim with no session recorded, the take over: exit 0" 0 "$code"
run claim "$REPO" 3674 "$SEEN"
is "#3804 a stale claim with no session recorded, taken over: exit 0" 0 "$code"

# `takeover` ends a claim from this Mac with no session recorded and nothing else. Under a claim
# that names another session it posts nothing, and says only that session can release it.
new_case
theirs 600 claim >"$FAKE/markers"
run takeover "$REPO" 3317 "$MINE" "taking over"
is "#3804 take over under a claim that names another session: exit 1" 1 "$code"
has "#3804 take over under a claim that names another session: nothing to take over" "NOTHING TO TAKE OVER:" "$out"
has "#3804 take over under a claim that names another session: says only that session can release it" "another session on the personal MacBook holds a claim on that branch, and only that session can release it" "$out"
lacks "#3804 take over under a claim that names another session: never says taken over" "TAKEN OVER:" "$out"
is "#3804 take over under a claim that names another session: nothing posted" 0 "$(posted_count)"
SESSION_OVERRIDE="$OTHER_SESSION" run check "$REPO" 3317 "$MINE"
has "#3804 take over under a claim that names another session: that session still holds its claim" "ALREADY CLAIMED" "$out"

# Under the other Mac's claim with no session recorded: nothing, since it is the other Mac's.
new_case
unnamed 600 claim "$MINE" Dans-MacBook-Pro >"$FAKE/markers"
run takeover "$REPO" 3317 "$MINE" "taking over"
is "#3804 take over under the other Mac's claim with no session recorded: exit 1" 1 "$code"
is "#3804 take over under the other Mac's claim with no session recorded: nothing posted" 0 "$(posted_count)"
run release "$REPO" 3317 "$MINE" "dropped"
is "#3804 a plain release under the other Mac's claim with no session recorded: nothing posted" 0 "$(posted_count)"

# Under this session's own claim, which names it: nothing to take over, and the claim stands.
new_case
mine 600 claim >"$FAKE/markers"
run takeover "$REPO" 3317 "$MINE" "taking over"
is "#3804 take over under this session's own named claim: exit 1" 1 "$code"
has "#3804 take over under this session's own named claim: says release is the word for it" "this session's own claim on that branch names it and still stands: release ends it" "$out"
is "#3804 take over under this session's own named claim: nothing posted" 0 "$(posted_count)"
run claim "$REPO" 3317 "$MINE"
has "#3804 take over under this session's own named claim: the claim still stands" "ALREADY CLAIMED" "$out"

# With no claim at all, and with a claim under another branch name: nothing.
new_case
run takeover "$REPO" 3317 "$MINE" "taking over"
is "#3804 take over with no claim on the issue: exit 1" 1 "$code"
is "#3804 take over with no claim on the issue: nothing posted" 0 "$(posted_count)"
new_case
unnamed 600 claim fix/3317-another-name >"$FAKE/markers"
run takeover "$REPO" 3317 "$MINE" "taking over"
is "#3804 take over names one branch, and a claim under another is left alone: exit 1" 1 "$code"
is "#3804 take over names one branch, and a claim under another is left alone: nothing posted" 0 "$(posted_count)"

# A take over needs a reason, a readable session and a read that worked, like a release.
new_case
unnamed 600 claim >"$FAKE/markers"
run takeover "$REPO" 3317 "$MINE"
is "#3804 take over with no reason: exit 2" 2 "$code"
is "#3804 take over with no reason: gh never called" "" "$(cat "$FAKE/calls")"
new_case
unnamed 600 claim >"$FAKE/markers"
: >"$FAKE/fail_issue"
run takeover "$REPO" 3317 "$MINE" "taking over"
is "#3804 take over when the read fails: exit 2" 2 "$code"
has "#3804 take over when the read fails: says it could not take over" "COULD NOT TAKE OVER" "$out"
is "#3804 take over when the read fails: nothing posted" 0 "$(posted_count)"
new_case
unnamed 600 claim >"$FAKE/markers"
: >"$FAKE/fail_post"
run takeover "$REPO" 3317 "$MINE" "taking over"
is "#3804 take over when the post fails: exit 2" 2 "$code"
has "#3804 take over when the post fails: says the claim still stands" "COULD NOT TAKE OVER: the take over was not posted" "$out"
lacks "#3804 take over when the post fails: never says taken over" "TAKEN OVER:" "$out"

# This session's own claim beside a stale claim with no session recorded, both on one branch name
# (it claimed once that one stopped counting). A plain release ends its own and leaves the other
# standing, and says so; until the review of this change it ended both.
new_case
{ unnamed $((25 * 3600)) claim; mine 600 claim; } >"$FAKE/markers"
run release "$REPO" 3317 "$MINE" "dropped"
is "#3804 a plain release of our claim beside one with no session recorded: exit 0" 0 "$code"
has "#3804 a plain release of our claim beside one with no session recorded: says released" "RELEASED:" "$out"
has "#3804 a plain release of our claim beside one with no session recorded: says the other still stands" "a claim on that branch that records no session still stands" "$out"
rel="$(cat "$FAKE/posted.1" 2>/dev/null)"
has "#3804 a plain release of our claim beside one with no session recorded: ends our claim" "<!-- orchestrate-release branch=$MINE host=$THIS_MAC,session=$SID -->" "$rel"
lacks "#3804 a plain release of our claim beside one with no session recorded: never ends the other" "<!-- orchestrate-release branch=$MINE host=$THIS_MAC -->" "$rel"
# A take over there ends both, since the line that names this session is this session's release
# as well, and it says so. The branch name was this session's already.
new_case
{ unnamed $((25 * 3600)) claim; mine 600 claim; } >"$FAKE/markers"
run takeover "$REPO" 3317 "$MINE" "taking over"
is "#3804 take over beside our own claim on the same branch: exit 0" 0 "$code"
has "#3804 take over beside our own claim on the same branch: says our own claim ended with it" "this session's own claim on that branch ended with it" "$out"
has "#3804 take over beside our own claim on the same branch: says the name was ours already" "The branch name was this session's already" "$out"
run check "$REPO" 3317 "$MINE"
has "#3804 take over beside our own claim on the same branch: nothing is left standing" "FREE" "$out"

# Taking over a claim that never held the issue passes no branch name, and the answer says so
# rather than promising the branch.
new_case
{ theirs 9000 claim fix/3317-other-name; unnamed 8000 claim; theirs 7000 release fix/3317-other-name; } >"$FAKE/markers"
run takeover "$REPO" 3317 "$MINE" "taking over"
is "#3804 take over of a claim that never held the issue: exit 0" 0 "$code"
has "#3804 take over of a claim that never held the issue: says taken over" "TAKEN OVER:" "$out"
has "#3804 take over of a claim that never held the issue: says the branch name was not that claim's" "The branch name was not that claim's to pass on" "$out"
lacks "#3804 take over of a claim that never held the issue: never promises the branch" "counts the branch and its pull request as its own" "$out"

# A claim with no session recorded that an earlier version of the script released is not taken
# over by a later release: there is nothing left to release, and the branch stays not ours.
new_case
{ unnamed 7200 claim; unnamed 3600 release; } >"$FAKE/markers"
printf 'main\n%s\n' "$MINE" >"$FAKE/branches"
run release "$REPO" 3317 "$MINE" "dropped"
has "#3804 a released claim with no session recorded: nothing to release" "NOTHING TO RELEASE" "$out"
is "#3804 a released claim with no session recorded: nothing posted" 0 "$(posted_count)"
run claim "$REPO" 3317 "$MINE"
is "#3804 a released claim with no session recorded, its branch still up: exit 1" 1 "$code"

# Only a release that ended the claim takes it over. This session's release of its own claim, one
# that lost the race to a claim with no session recorded, takes over nothing: a day later that
# claim's branch is still not ours.
new_case
{ unnamed 90000 claim; mine 89999 claim; mine 89990 release; } >"$FAKE/markers"
printf 'main\n%s\n' "$MINE" >"$FAKE/branches"
run claim "$REPO" 3317 "$MINE"
is "#3804 our release of our own claim beside a claim with no session recorded: exit 1" 1 "$code"
has "#3804 our release of our own claim beside a claim with no session recorded: its branch holds" "remote branch: $MINE (the branch name being claimed" "$out"

# Taking over a claim that itself never held the issue (it was posted under another session's live
# claim) gives the name to nobody, and must not stop the name passing later: this session's next
# claim on it holds the issue, so the branch its builder then pushes is its own.
new_case
{
  theirs 9000 claim fix/3317-other-name
  unnamed 8000 claim
  theirs 7000 release fix/3317-other-name
  unnamed 6000 release
  mine 6000 release
  mine 5000 claim
} >"$FAKE/markers"
printf 'main\n%s\n' "$MINE" >"$FAKE/branches"
run claim "$REPO" 3317 "$MINE"
is "#3804 a claim after taking over one that never held the issue: exit 0" 0 "$code"
has "#3804 a claim after taking over one that never held the issue: already claimed" "ALREADY CLAIMED" "$out"
has "#3804 a claim after taking over one that never held the issue: the branch is its own" "this session's own, by its claim on the issue: remote branch $MINE" "$out"

# A release never ends another session's claim, and says whose it is.
new_case
theirs 600 claim >"$FAKE/markers"
run release "$REPO" 3317 "$MINE" "dropped"
is "#3804 release under another session's claim: exit 0" 0 "$code"
has "#3804 release under another session's claim: nothing to release" "NOTHING TO RELEASE" "$out"
has "#3804 release under another session's claim: says another session holds one" "another session on the personal MacBook holds a claim on that branch" "$out"
is "#3804 release under another session's claim: nothing posted" 0 "$(posted_count)"

# 11f. A session id that cannot be read: the script stops before it reads or posts anything. It
# never claims as nobody, and never reads another's claim as its own.
no_session() { # no_session <description> <args...>   after a run with the id missing or unusable
  local what="$1"
  shift
  is "#3804 $what: exit 2" 2 "$code"
  has "#3804 $what: says the session's id could not be read" "this session's id could not be read" "$out"
  lacks "#3804 $what: never says claimed" "CLAIMED" "$out"
  lacks "#3804 $what: never says free" "FREE" "$out"
  lacks "#3804 $what: never says released" "RELEASED:" "$out"
  is "#3804 $what: gh never called" "" "$(cat "$FAKE/calls")"
  is "#3804 $what: nothing posted" 0 "$(posted_count)"
}
run_without() { # run_without <args...>   as run, with no CLAUDE_CODE_SESSION_ID at all
  out="$(PATH="$TMP/bin:$PATH" FAKE="$FAKE" CLAIM_NOW="$NOW" CLAIM_READBACK_WAIT=0 CLAIM_HOST="$THIS_MAC" env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" "$@" 2>&1)"
  code=$?
}
for mode in claim check; do
  new_case
  unnamed 600 claim >"$FAKE/markers" # a claim it must not take for its own
  run_without "$mode" "$REPO" 3317 "$MINE"
  no_session "no session id, $mode"
  has "#3804 no session id, $mode: says it could not check" "COULD NOT CHECK" "$out"
  has "#3804 no session id, $mode: names what was missing" "CLAUDE_CODE_SESSION_ID is not set" "$out"
done
new_case
mine 600 claim >"$FAKE/markers"
run_without release "$REPO" 3317 "$MINE" "dropped"
no_session "no session id, release"
has "#3804 no session id, release: says it could not release" "COULD NOT RELEASE" "$out"
new_case
unnamed 600 claim >"$FAKE/markers"
run_without takeover "$REPO" 3317 "$MINE" "taking over"
no_session "no session id, take over"
has "#3804 no session id, take over: says it could not take over" "COULD NOT TAKE OVER" "$out"

for odd in "x" "not an id" "; rm -rf /"; do
  new_case
  SESSION_OVERRIDE="$odd" run claim "$REPO" 3317 "$MINE"
  no_session "a session id that is not one ('$odd')"
  has "#3804 a session id that is not one ('$odd'): says so" "does not hold a session id" "$out"
done

# The tool that makes the short name failing is an id that could not be read too: its empty answer
# must never become a name every session shares.
break_tool shasum '*'
new_case
run_broken claim "$REPO" 3317 "$MINE"
no_session "the short name cannot be made"
has "#3804 the short name cannot be made: prints the tool's own error" "simulated failure" "$out"
rm -rf "$TMP/broken"

# ---- 12. a claim posted again takes the place of its latest post (review of #3804, F1) ----
# A session whose claim went stale with no release posts it again. Until the review of this change
# the new claim kept the place in the list of the stale one, so it read as posted first when another
# session's claim had landed a moment before it, and both sessions were told CLAIMED, exit 0.

# 12a. Seen from the session posting again: the other session's claim landed first, so ours loses,
# is released, and the winner keeps the issue.
new_case
mine $((25 * 3600)) claim >"$FAKE/markers"
theirs 1 claim >"$FAKE/race"
run claim "$REPO" 3317 "$MINE"
is "F1 a claim posted again over its own stale one, another session's landing first: exit 1" 1 "$code"
has "F1 a claim posted again over its own stale one, another session's landing first: says held" "HELD: another session claimed" "$out"
lacks "F1 a claim posted again over its own stale one, another session's landing first: never claimed" "CLAIMED:" "$out"
is "F1 a claim posted again over its own stale one, another session's landing first: our claim and its release posted" 2 "$(posted_count)"
has "F1 a claim posted again over its own stale one, another session's landing first: the second post is our release" "<!-- orchestrate-release branch=$MINE host=$THIS_MAC,session=$SID -->" "$(cat "$FAKE/posted.2" 2>/dev/null)"
SESSION_OVERRIDE="$OTHER_SESSION" run check "$REPO" 3317 "$MINE"
is "F1 a claim posted again over its own stale one, another session's landing first: the winner, exit 0" 0 "$code"
has "F1 a claim posted again over its own stale one, another session's landing first: the winner still holds its claim" "ALREADY CLAIMED" "$out"
# The second half: the winner's builder pushes the branch and opens its pull request. Both are the
# winner's own, so it is not held by them, and the session that lost is.
printf 'main\n%s\n' "$MINE" >"$FAKE/branches"
pr_row 4173 "$MINE" "The winner's" "Closes #3317" >"$FAKE/prs"
SESSION_OVERRIDE="$OTHER_SESSION" run claim "$REPO" 3317 "$MINE"
is "F1 the winner, its branch and pull request up: exit 0" 0 "$code"
has "F1 the winner, its branch and pull request up: already claimed" "ALREADY CLAIMED" "$out"
has "F1 the winner, its branch and pull request up: the branch is its own" "this session's own, by its claim on the issue: remote branch $MINE" "$out"
has "F1 the winner, its branch and pull request up: the pull request is its own" "this session's own, by its claim on the issue: pull request #4173" "$out"
run claim "$REPO" 3317 "$MINE"
is "F1 the session that lost, the winner's branch up: exit 1" 1 "$code"
has "F1 the session that lost, the winner's branch up: the branch is not its own" "remote branch: $MINE (the branch name being claimed" "$out"

# 12b. Seen from the other session: its claim landed first, and the claim posted again over a stale
# one a moment after it. The earlier post wins. Until the fix this session released and the one
# posting again won, when this read came after its post, and both won when it came before.
new_case
theirs $((25 * 3600)) claim >"$FAKE/markers"
theirs 0 claim >"$FAKE/late"
run claim "$REPO" 3317 "$MINE"
is "F1 our claim landing before another session's posted again over its stale one: exit 0" 0 "$code"
has "F1 our claim landing before another session's posted again over its stale one: claimed" "CLAIMED:" "$out"
is "F1 our claim landing before another session's posted again over its stale one: only the claim posted" 1 "$(posted_count)"

# 12c. The same race with GitHub's clock a little behind this Mac's (the gap is the one this
# fixture sets below, not measured). By this Mac's clock the earlier claim is stale, so it is
# posted again; by the times GitHub stamps, the new post is still inside the stale window of the
# old one. The place must not depend on that: a session posts again only once it has judged its
# earlier claim over, and the other session's claim still landed first.
new_case
mine $((24 * 3600 + 10)) claim >"$FAKE/markers"
theirs 21 claim >"$FAKE/race"
echo "$((NOW - 20))" >"$FAKE/stamp"
run claim "$REPO" 3317 "$MINE"
is "F1 posted again with GitHub's clock behind, another session's landing first: exit 1" 1 "$code"
lacks "F1 posted again with GitHub's clock behind, another session's landing first: never claimed" "CLAIMED:" "$out"
is "F1 posted again with GitHub's clock behind, another session's landing first: our claim and its release posted" 2 "$(posted_count)"

# 12d. Nobody racing: a claim posted again over its own stale one is still claimed (section 11d has
# the same with its branch and pull request up).
new_case
mine $((25 * 3600)) claim >"$FAKE/markers"
run claim "$REPO" 3317 "$MINE"
is "F1 a claim posted again over its own stale one, nobody racing: exit 0" 0 "$code"
has "F1 a claim posted again over its own stale one, nobody racing: claimed" "CLAIMED:" "$out"

# ---- 13. a session part that is not 12 hex digits names no session (review of #3804, F6) ----
# A host word is a Mac's name alone, or a Mac's name, ",session=" and exactly 12 lower case hex
# digits. Anything else is read whole as a Mac nobody is. Each word below is a near miss built from
# this session's own short name, so a reader that took the first 12 digits, or matched without
# anchoring or without minding case, would read the claim as this session's own or as one of this
# Mac's, and the release as ending this session's claim.
SID_CAPS="$(printf '%s' "$SID" | tr 'a-f' 'A-F')"
odd_words=(
  "$THIS_MAC,session=${SID}0"
  "$THIS_MAC,session=${SID:0:11}"
  "$THIS_MAC,session=$SID,session=$OSID"
  "$THIS_MAC,session=$OSID,session=$SID"
  ",session=$SID"
  "$THIS_MAC,session=$SID_CAPS"
  "$THIS_MAC,session="
  "$THIS_MAC,x,session=$SID"
)
odd_names=(
  "13 hex digits"
  "11 hex digits"
  "two session parts, ours first"
  "two session parts, ours last"
  "an empty Mac name"
  "capital hex"
  "an empty session"
  "a comma in the Mac name"
)
[ "$SID_CAPS" != "$SID" ] && ok || bad "F6 the capital form of the short name differs from it" "$SID_CAPS"
i=0
while [ "$i" -lt "${#odd_words[@]}" ]; do
  word="${odd_words[$i]}"
  what="F6 a session part that is ${odd_names[$i]}"
  i=$((i + 1))

  # As a claim: it holds, as a Mac nobody here is, and is never this session's own.
  new_case
  marker 600 claim "$MINE" "$word" >"$FAKE/markers"
  run claim "$REPO" 3317 "$MINE"
  is "$what, claim under it: exit 1" 1 "$code"
  has "$what, claim under it: says held" "HELD" "$out"
  lacks "$what, claim under it: never already claimed" "ALREADY CLAIMED" "$out"
  has "$what, claim under it: read whole, as a Mac nobody is" "claim: the Mac named $word claimed it at" "$out"
  lacks "$what, claim under it: offers no take over" "then claim again" "$out"
  is "$what, claim under it: nothing posted" 0 "$(posted_count)"

  # As a claim: neither a release nor a take over from this session ends it.
  run release "$REPO" 3317 "$MINE" "dropped"
  is "$what, release under it: exit 0" 0 "$code"
  has "$what, release under it: nothing to release" "NOTHING TO RELEASE" "$out"
  lacks "$what, release under it: not read as a session on this Mac" "another session on" "$out"
  is "$what, release under it: nothing posted" 0 "$(posted_count)"
  run takeover "$REPO" 3317 "$MINE" "taking over"
  is "$what, take over under it: exit 1" 1 "$code"
  is "$what, take over under it: nothing posted" 0 "$(posted_count)"

  # As a release: it does not end this session's claim, which still stands.
  new_case
  { mine 600 claim; marker 300 release "$MINE" "$word"; } >"$FAKE/markers"
  run claim "$REPO" 3317 "$MINE"
  is "$what, as a release beside our claim: exit 0" 0 "$code"
  has "$what, as a release beside our claim: our claim still stands" "ALREADY CLAIMED" "$out"
  is "$what, as a release beside our claim: nothing posted" 0 "$(posted_count)"
  # Nor a claim from this Mac with no session recorded, which still holds.
  new_case
  { unnamed 600 claim; marker 300 release "$MINE" "$word"; } >"$FAKE/markers"
  run check "$REPO" 3317 "$MINE"
  is "$what, as a release beside a claim with no session recorded: exit 1" 1 "$code"
  has "$what, as a release beside a claim with no session recorded: that claim still holds" "with no session recorded" "$out"
done

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
