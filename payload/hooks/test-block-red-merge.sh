#!/usr/bin/env bash
#
# test-block-red-merge.sh: the merge gate, including the rule that a repo
# carrying the commit pinned merge tool must use it (PostRoll #711).
#
# Every case runs the real hook with a fake `gh` first on PATH, so what is
# tested is the hook's own reading of an answer rather than a rewrite of its
# logic living here (L52).

set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-red-merge.sh"
passed=0
failed=0

fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }

# A throwaway repo, optionally carrying the merge tool, and a fake gh whose
# answer this test chooses.
make_repo() {  # $1 = with-tool | without-tool | with-ci | with-ci-not-on-prs ; $2 = rollup json
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/repo/.git" "$dir/bin"
  if [ "$1" = "with-ci" ]; then
    mkdir -p "$dir/repo/.github/workflows"
    printf 'name: tests\non:\n  pull_request:\njobs:\n  t:\n    runs-on: ubuntu-latest\n' \
      > "$dir/repo/.github/workflows/tests.yml"
  fi
  if [ "$1" = "with-ci-not-on-prs" ]; then
    mkdir -p "$dir/repo/.github/workflows"
    printf 'name: nightly\non:\n  schedule:\n    - cron: "0 3 * * *"\njobs:\n  t:\n    runs-on: ubuntu-latest\n' \
      > "$dir/repo/.github/workflows/nightly.yml"
  fi
  if [ "$1" = "with-tool" ]; then
    mkdir -p "$dir/repo/tools"
    printf '#!/usr/bin/env python3\n' > "$dir/repo/tools/wait_for_checks.py"
  fi
  if [ "$1" = "with-npm-tool" ]; then
    mkdir -p "$dir/repo/.github/scripts"
    printf '#!/usr/bin/env bash\n' > "$dir/repo/.github/scripts/merge-pr.sh"
  fi
  cat > "$dir/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr view"*) cat <<'JSON'
$2
JSON
  ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  printf '%s' "$dir"
}

run_hook() {  # $1 = repo dir, $2 = command ; prints the hook's stdout
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | (cd "$1/repo" && PATH="$1/bin:$PATH" bash "$HOOK")
}

# The commit the rollup was read for. The gate now has to hand it to the merge, so it is a
# fixture value rather than an incidental one (#345).
HEAD_SHA='a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
GREEN='{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"SUCCESS"}],"headRefOid":"a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"}'
RED='{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"FAILURE"}],"headRefOid":"a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"}'
# Green, but gh did not say which commit it was green FOR. The gate cannot pin what it cannot
# read, and it must not merge unpinned in silence either (#345).
GREEN_NO_HEAD='{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"SUCCESS"}]}'
# A pull request with NO checks at all. GitHub answers this way for two very different reasons,
# and the gate has to tell them apart (claude-config#131).
NONE_CLEAN='{"number":7,"statusCheckRollup":[],"mergeable":"MERGEABLE"}'
NONE_CONFLICTING='{"number":7,"statusCheckRollup":[],"mergeable":"CONFLICTING"}'
NONE_UNKNOWN='{"number":7,"statusCheckRollup":[],"mergeable":"UNKNOWN"}'

# Matched with the shell's own builtins, WITHOUT a pipe, deliberately. A producer piped into a
# quiet grep is the short circuiting shape test-pipefail-shortcircuit.sh ratchets down: the reader
# leaves on its first match, the producer dies of SIGPIPE, and under `set -o pipefail` the pipeline
# reports a failure that never happened (L183).
#
# Converted HERE because this is the file new hook suites are started from, and a clone copies the
# pattern as first written: on 2026-08-31 test-changelog-tag.sh arrived carrying two of these,
# byte identical to this file, and turned main red. Converting the template is what stops it
# happening again, which is the class rather than the instance (L501, L30).
denied() { local re='"permissionDecision": *"deny"'; [[ "$1" =~ $re ]]; }

says() {  # $1 = the hook output, $2 = a LITERAL needle, matched case insensitively
  local prior found
  # `nocasematch` is a shell wide setting, so it is restored rather than switched off: leaving it
  # clear would be a silent change to any caller that had set it (L509).
  prior="$(shopt -p nocasematch)"
  shopt -s nocasematch
  # "$2" is quoted, so a needle is a literal here where `grep -qi` read it as a regex.
  [[ "$1" == *"$2"* ]] && found=0 || found=1
  eval "$prior"
  return "$found"
}

holds() {  # $1 = the hook output, $2 = a LITERAL needle, matched case sensitively
  case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

echo "block-red-merge: the commit pinned rule (#711)"

# 1. The rule itself: a repo carrying the tool must merge through it.
dir=$(make_repo with-tool "$GREEN")
out=$(run_hook "$dir" "gh pr merge 7 --squash --delete-branch")
if denied "$out"; then pass; else
  fail "a plain gh pr merge was allowed in a repo that carries the pinned merge tool"
fi
# And the refusal has to say what to run instead, or it is a dead end.
if holds "$out" "wait_for_checks.py 7 --merge"; then pass; else
  fail "the refusal does not name the command to use instead: $out"
fi
rm -rf "$dir"

# 2. Green is not enough on its own. This is the whole point: the rollup can
#    read green for a commit that is no longer the head.
dir=$(make_repo with-tool "$GREEN")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then pass; else
  fail "a green rollup let a plain merge through in a repo with the tool"
fi
rm -rf "$dir"

# 3. The visible override for the one case where the tool cannot be used, under the tool rule's
#    OWN name. It used to share ALLOW_UNPINNED_MERGE with the commit pin, so bypassing the script
#    also dropped the pin and landed on the weakest merge available (#347).
dir=$(make_repo with-tool "$GREEN")
if denied "$(run_hook "$dir" "SKIP_MERGE_TOOL=1 gh pr merge 7 --squash --match-head-commit $HEAD_SHA")"; then
  fail "the tool rule's own override did not let a pinned merge through"
else pass; fi
rm -rf "$dir"

# 3b. And skipping the tool does NOT skip the pin. This is the whole of #347: one token switching
#     off two rules meant whoever bypassed the script silently lost a rule they never named.
dir=$(make_repo with-tool "$GREEN")
out=$(run_hook "$dir" "SKIP_MERGE_TOOL=1 gh pr merge 7 --squash")
if denied "$out"; then pass; else
  fail "skipping the repo tool also skipped the commit pin: $out"
fi
if holds "$out" "--match-head-commit $HEAD_SHA"; then pass; else
  fail "the refusal is not the pin rule's: $out"
fi
rm -rf "$dir"

# 3c. Each override answers only its OWN rule. The pin's override does not get you past the tool.
dir=$(make_repo with-tool "$GREEN")
out=$(run_hook "$dir" "ALLOW_UNPINNED_MERGE=1 gh pr merge 7 --squash")
if denied "$out"; then pass; else
  fail "the pin's override let a plain merge past the repo tool rule: $out"
fi
if holds "$out" "SKIP_MERGE_TOOL=1"; then pass; else
  fail "the tool refusal does not name its own override: $out"
fi
rm -rf "$dir"

# 3d. Both, for somebody who genuinely means both.
dir=$(make_repo with-tool "$GREEN")
if denied "$(run_hook "$dir" "SKIP_MERGE_TOOL=1 ALLOW_UNPINNED_MERGE=1 gh pr merge 7 --squash")"; then
  fail "naming both overrides did not let the merge through"
else pass; fi
rm -rf "$dir"

# 4. The control: a repo WITHOUT the tool still merges, PINNED to the commit
#    the gate just read. Before #345 this case asserted that a plain merge went
#    through, which is the behaviour that change reverses.
dir=$(make_repo without-tool "$GREEN")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")"; then
  fail "a green PR pinned to the judged commit was blocked"
else pass; fi
rm -rf "$dir"

# 5. And a red one there is still refused, so the old gate is intact.
dir=$(make_repo without-tool "$RED")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then pass; else
  fail "a red PR was allowed to merge"
fi
rm -rf "$dir"

# 6. Anything that is not a merge is none of this hook's business.
dir=$(make_repo with-tool "$GREEN")
if denied "$(run_hook "$dir" "gh pr view 7")"; then
  fail "the hook blocked a command that was not a merge"
else pass; fi
rm -rf "$dir"


# 6. The second pinned tool: a repo whose merge goes through its own shell
#    wrapper is held to the same rule, and the refusal names ITS command.
#    Without this, adding a tool to the table would be untested and the rule
#    would silently apply to one repo only.
dir=$(make_repo with-npm-tool "$GREEN")
out=$(run_hook "$dir" "gh pr merge 7 --squash --delete-branch")
if denied "$out"; then pass; else
  fail "a plain gh pr merge was allowed in a repo that carries a shell merge wrapper"
fi
if holds "$out" "npm run merge -- 7"; then pass; else
  fail "the refusal does not name the wrapper's own command: $out"
fi
# It must name the tool it found, not the other repo's, or the message sends
# somebody to a file that is not there.
if holds "$out" "wait_for_checks"; then
  fail "the refusal names the other repo's tool: $out"
else pass; fi
rm -rf "$dir"

# 7. The visible override works for the second tool too.
dir=$(make_repo with-npm-tool "$GREEN")
if denied "$(run_hook "$dir" "SKIP_MERGE_TOOL=1 gh pr merge 7 --squash --match-head-commit $HEAD_SHA")"; then
  fail "the visible override did not let the merge through for the shell wrapper"
else pass; fi
rm -rf "$dir"

# 8. And a red PR there is still refused by the ORIGINAL gate, reached through
#    the override, so the two rules do not answer for each other (L178).
dir=$(make_repo with-npm-tool "$RED")
if denied "$(run_hook "$dir" "SKIP_MERGE_TOOL=1 gh pr merge 7 --squash")"; then pass; else
  fail "a red PR was allowed through once the pinned-tool rule was overridden"
fi
rm -rf "$dir"

echo "block-red-merge: a directory holding more than one checkout (#346)"

# The gate resolves the directory the merge will run in, and when the session sits above the
# checkout it looks one level down. With TWO checkouts down there it used to take whichever the
# glob yielded first and answer about that repo's pull request #7. Now it refuses, and names them,
# because the generic "gh returned nothing" it would otherwise reach is a true sentence about a
# different fault and sends somebody to look at the wrong thing (L11, L521).
run_hook_above() {  # $1 = the directory ABOVE the checkouts, $2 = command
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | (cd "$1" && PATH="$1/bin:$PATH" bash "$HOOK")
}
dir=$(make_repo without-tool "$GREEN")
mkdir -p "$dir/other/.git"
out=$(run_hook_above "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if denied "$out"; then pass; else
  fail "a merge run above two checkouts was allowed, so the gate picked one of them: $out"
fi
if { holds "$out" "$dir/repo" && holds "$out" "$dir/other"; }; then pass; else
  fail "the refusal does not name both checkouts it was torn between: $out"
fi
rm -rf "$dir"

# The control: ONE checkout below the session directory still resolves, or this would have blocked
# every project shaped like PET, which is the shape the walk was written for (L159).
dir=$(make_repo without-tool "$GREEN")
if denied "$(run_hook_above "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")"; then
  fail "a merge run above a single checkout was blocked"
else pass; fi
rm -rf "$dir"

echo "block-red-merge: the merge is pinned to the commit that was judged (#345)"

# The rollup answers about the pull request, not about a commit, and it is read a moment BEFORE
# the merge runs. A push landing in that gap is merged unjudged, and afterwards it looks exactly
# like a merge that was judged, which is the failure the whole gate exists to prevent (L179).
# Until #345 the only repos protected were the two carrying their own pinned merge tool.
#
# gh pr merge already takes --match-head-commit, and GitHub refuses when the head has moved, so
# the gate requires the flag rather than needing a tool per repo.

# 1. A plain merge of a GREEN pull request is refused for carrying no pin.
dir=$(make_repo without-tool "$GREEN")
out=$(run_hook "$dir" "gh pr merge 7 --squash")
if denied "$out"; then pass; else
  fail "a green pull request was merged without pinning the commit its checks were read for: $out"
fi
# And the refusal hands over the command to run, or it is a dead end: the person is left
# knowing a flag exists and not which commit to give it (L406, L111).
if holds "$out" "--match-head-commit $HEAD_SHA"; then pass; else
  fail "the refusal does not name the command to run instead: $out"
fi
rm -rf "$dir"

# 2. Pinned to a DIFFERENT commit is worse than unpinned, not better: it hands GitHub a commit
#    nothing judged while reading as the careful route. Distinct cause, distinct message (L11).
dir=$(make_repo without-tool "$GREEN")
other=0000000000000000000000000000000000000000
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $other")
if denied "$out"; then pass; else
  fail "a merge pinned to a commit the gate never judged was allowed: $out"
fi
# It has to name BOTH, or the reader cannot see which of the two is the judged one.
if { holds "$out" "$HEAD_SHA" && holds "$out" "$other"; }; then pass; else
  fail "the refusal does not name both the judged commit and the one the command pinned: $out"
fi
rm -rf "$dir"

# 3. Green, but gh did not say WHICH commit it was green for. The gate cannot pin what it cannot
#    read, and merging unpinned in silence is the thing this rule exists to stop, so it fails
#    closed. Its own message, because "you did not pin it" would send somebody to add a flag whose
#    value nothing here can supply (L11, L109).
dir=$(make_repo without-tool "$GREEN_NO_HEAD")
out=$(run_hook "$dir" "gh pr merge 7 --squash")
if denied "$out"; then pass; else
  fail "a green rollup with no head commit in it was merged unpinned: $out"
fi
if says "$out" "head commit"; then pass; else
  fail "the refusal does not say the head commit could not be read: $out"
fi
if holds "$out" "--match-head-commit $HEAD_SHA"; then
  fail "it told the person to pin a commit it had just said it could not read: $out"
else pass; fi
rm -rf "$dir"

# 4. The visible override, under the name already used for exactly this: merging without a commit
#    pin. A second name for one idea is two vocabularies for one rule.
dir=$(make_repo without-tool "$GREEN")
if denied "$(run_hook "$dir" "ALLOW_UNPINNED_MERGE=1 gh pr merge 7 --squash")"; then
  fail "the visible override did not let an unpinned merge through"
else pass; fi
rm -rf "$dir"

# 5. A RED pull request is still refused BY THE GREEN GATE, in its own words. The new rule must not
#    answer for the old one: a red run reported as "you did not pin the commit" sends somebody to
#    add a flag and try again, and the second attempt is the merge this gate was built to stop
#    (L11, L178).
dir=$(make_repo without-tool "$RED")
out=$(run_hook "$dir" "gh pr merge 7 --squash")
if denied "$out"; then pass; else
  fail "a red pull request was allowed once the pin rule was added"
fi
if says "$out" "not green"; then pass; else
  fail "a red pull request was refused for the wrong reason: $out"
fi
rm -rf "$dir"

# 6. And a repo with no CI at all still merges plain. The pin protects a VERDICT, and there is no
#    verdict here to protect, so requiring it would block every repo without tests for a reason
#    that does not apply to them (L615, L324).
dir=$(make_repo without-tool "$NONE_CLEAN")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then
  fail "a repo with no CI at all was blocked for not pinning a commit nothing had judged"
else pass; fi
rm -rf "$dir"

echo "block-red-merge: a pull request with no checks at all (#131)"

# A conflicting branch has no merge commit for GitHub to build, so the workflow is never
# SCHEDULED and the rollup comes back empty. That is indistinguishable from a repo with no CI, and
# the gate used to allow both: it would merge a pull request whose tests never ran, which is the
# one thing it exists to prevent (L98).
dir=$(make_repo with-ci "$NONE_CONFLICTING")
out=$(run_hook "$dir" "gh pr merge 7 --squash")
if denied "$out"; then pass; else
  fail "a conflicting PR with no checks was allowed through: $out"
fi
if says "$out" "conflict"; then pass; else
  fail "the refusal does not say the branch conflicts, which is the one thing that explains it: $out"
fi
if { says "$out" "rebase" || says "$out" "merge the base"; }; then pass; else
  fail "the refusal does not say what to do about it: $out"
fi
rm -rf "$dir"

# The same empty rollup in a repo that HAS a workflow triggered by pull requests. Not a conflict,
# so something else stopped the run: a broken workflow file, Actions turned off, a queue that never
# started. Whatever it is, the tests did not run, and merging on that is merging blind.
dir=$(make_repo with-ci "$NONE_CLEAN")
out=$(run_hook "$dir" "gh pr merge 7 --squash")
if denied "$out"; then pass; else
  fail "a PR with no checks was allowed in a repo whose workflows run on pull requests: $out"
fi
if says "$out" "conflict"; then
  fail "it blamed a conflict when the branch merges cleanly: $out"
else pass; fi
rm -rf "$dir"

# And the case the old behaviour was written for, which must keep working: a repo with no CI at
# all has nothing that could be red, so an empty rollup is the honest answer and the merge goes
# through. Without this the fix above would just block every merge in every repo without tests.
dir=$(make_repo without-tool "$NONE_CLEAN")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then
  fail "a repo with no CI at all was blocked for having no checks"
else pass; fi
rm -rf "$dir"

# A repo whose only workflow does not run on pull requests is the same case: nothing was ever
# going to check this PR, so an empty rollup is expected rather than suspicious.
dir=$(make_repo with-ci-not-on-prs "$NONE_CLEAN")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then
  fail "a repo whose workflows never run on pull requests was blocked: it has no PR checks to wait for"
else pass; fi
rm -rf "$dir"

# GitHub answers UNKNOWN while it is still working out whether the branch merges. That is not
# evidence of a conflict, and it is not evidence of a clean branch either, so it must not be
# treated as either: the workflow question below still decides (L11).
dir=$(make_repo with-ci "$NONE_UNKNOWN")
out=$(run_hook "$dir" "gh pr merge 7 --squash")
if denied "$out"; then pass; else
  fail "an unknown mergeable state with no checks was allowed through: $out"
fi
if says "$out" "conflict"; then
  fail "it asserted a conflict GitHub had not confirmed: $out"
else pass; fi
rm -rf "$dir"

# The visible override still works here, or a genuine case with no other route becomes unmergeable.
dir=$(make_repo with-ci "$NONE_CONFLICTING")
if denied "$(run_hook "$dir" "ALLOW_RED_MERGE=1 gh pr merge 7 --squash")"; then
  fail "the visible override did not let a no-checks merge through"
else pass; fi
rm -rf "$dir"

echo "block-red-merge: repos the active gh account cannot see (nursedex, 2026-08-30)"

# A REAL git repo with a GitHub remote, so the hook has an identity to check the
# answer against. The repos above deliberately have none, which is why they
# exercise the no-remote path and why this needs its own builder.
#
# The fake gh is written by a plain heredoc, never one inside $(...): macOS
# ships bash 3.2, which mis-parses that and the whole suite fails to parse.
make_remote_repo() {  # $1 = owner/name ; $2 = which fake gh
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/repo" "$dir/bin"
  ( cd "$dir/repo" && git init -q && git remote add origin "https://github.com/$1.git" )

  # The real situation: the ACTIVE account answers 404 on this repo and returns
  # nothing, while a second logged-in account can see it. The hook read that
  # empty answer, could not tell it from a pull request that does not exist,
  # and refused every merge in the repo.
  #
  # The word "answers" is doing real work there. The #145 scan reads a run of
  # digits followed immediately by an s as a duration, which is how it catches a
  # stale timing left in a comment, and it cannot tell that spelling from a
  # status code written the same way. The prose moved rather than the rule:
  # loosening the rule would exempt every genuine duration too, and a guard that
  # is green on the sentence explaining it is no guard at all (L103).
  if [ "$2" = "second-account-green" ]; then
    cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "$*" in
  *"auth status"*)
    printf 'Logged in to github.com account danwright32 (keyring)\n'
    printf 'Logged in to github.com account nursedexapp (keyring)\n'
    ;;
  *"auth token -u nursedexapp"*) printf 'tok-nursedexapp\n' ;;
  *"auth token -u "*) printf 'tok-other\n' ;;
  *"pr view"*)
    if [ "${GH_TOKEN:-}" = "tok-nursedexapp" ]; then
      printf '%s\n' '{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"SUCCESS"}],"headRefOid":"a1b2c3d4e5f60718293a4b5c6d7e8f9012345678","url":"https://github.com/acme/widget/pull/7"}'
    fi
    ;;
esac
SH
  fi

  if [ "$2" = "second-account-red" ]; then
    cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account nursedexapp (keyring)\n' ;;
  *"auth token -u "*) printf 'tok-nursedexapp\n' ;;
  *"pr view"*)
    if [ "${GH_TOKEN:-}" = "tok-nursedexapp" ]; then
      printf '%s\n' '{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"FAILURE"}],"headRefOid":"a1b2c3d4e5f60718293a4b5c6d7e8f9012345678","url":"https://github.com/acme/widget/pull/7"}'
    fi
    ;;
esac
SH
  fi

  # Every account answers, but about a DIFFERENT repo.
  if [ "$2" = "wrong-repo" ]; then
    cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*)
    printf '%s\n' '{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"SUCCESS"}],"url":"https://github.com/someone/else/pull/7"}'
    ;;
esac
SH
  fi

  chmod +x "$dir/bin/gh"
  printf '%s' "$dir"
}

dir=$(make_remote_repo acme/widget second-account-green)
GH_CALL_LOG="$dir/gh-calls.log"; export GH_CALL_LOG; : > "$GH_CALL_LOG"
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if denied "$out"; then
  fail "a green pull request was blocked because the ACTIVE account cannot see the repo: $out"
else pass; fi

# Dan runs concurrent sessions under different accounts. Switching the shared
# keyring's active account to read one repo would break whatever else is using
# it, so the token is scoped per call and the active account is never touched.
if grep -q "auth switch" "$GH_CALL_LOG"; then
  fail "the hook ran gh auth switch, which changes the shared active account"
else pass; fi

# The fallback has to have actually been taken, or a fake that answered on the
# first call would pass this identically and prove nothing (L159).
if grep -q "auth token -u" "$GH_CALL_LOG"; then pass; else
  fail "the hook never asked for a scoped token, so the fallback was not exercised"
fi
rm -rf "$dir"

# Reaching the answer by a new route must not change how the answer is READ.
dir=$(make_remote_repo acme/widget second-account-red)
GH_CALL_LOG="$dir/gh-calls.log"; export GH_CALL_LOG; : > "$GH_CALL_LOG"
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then pass; else
  fail "a FAILING check reached through the scoped-token fallback was allowed to merge"
fi
rm -rf "$dir"

# New strictness. An answer about ANOTHER repo used to be read as this pull
# request's verdict, and verifying one pull request's checks while merging a
# different one is the exact mistake this gate exists to stop.
dir=$(make_remote_repo acme/widget wrong-repo)
GH_CALL_LOG="$dir/gh-calls.log"; export GH_CALL_LOG; : > "$GH_CALL_LOG"
out=$(run_hook "$dir" "gh pr merge 7 --squash")
if denied "$out"; then pass; else
  fail "a green rollup about a DIFFERENT repo was accepted as this pull request's verdict"
fi
# Distinct causes get distinct messages: this must not read like "gh said nothing" (L11).
# `case`, not a pipeline into grep -q: a short circuiting consumer can kill the
# producer and report a failure that never happened (L183).
case "$out" in
  *someone/else*) pass ;;
  *) fail "the refusal does not name the repo it was actually told about: $out" ;;
esac
rm -rf "$dir"
unset GH_CALL_LOG

echo "block-red-merge: each check is judged by its NEWEST run on the head commit (#382)"

# The rollup lists EVERY run of a check on the head commit, not only the latest. On ovation PR 312
# "Closing keywords GitHub reads" failed on the original description and passed once it was edited,
# both on one head, and the gate refused the merge as not green, so the only way through was a new
# commit. A superseded run is not the verdict on that commit (L179).
#
# The shape is the real one: gh reports __typename, workflowName, name, status, conclusion and
# startedAt on a check run. Each pair below is written in BOTH orders, because on real pull requests
# (ovation 305, 310, 311, read 2026-09-17) the array put the newer run first as often as last, so a
# gate reading position would pass one order and fail the other.
#
# A refusal alone proves nothing here: a fixture gh cannot parse is refused too, as "gh returned
# nothing", which happened twice while these were written (L140). So each red case asserts the
# refusal is the green gate's own.
refused_red() { denied "$1" && holds "$1" "is not green: "; }
T1='2026-09-14T17:20:00Z'
T2='2026-09-14T17:28:36Z'
run_json() {  # $1 = workflow, $2 = name, $3 = status, $4 = conclusion, $5 = startedAt
  printf '{"__typename":"CheckRun","workflowName":"%s","name":"%s","status":"%s","conclusion":"%s","startedAt":"%s"}' \
    "$1" "$2" "$3" "$4" "$5"
}
rollup_of() {  # the runs, as arguments ; prints a rollup for PR 7 at HEAD_SHA
  local IFS=,
  printf '{"number":7,"statusCheckRollup":[%s],"headRefOid":"%s"}' "$*" "$HEAD_SHA"
}
SUITE_GREEN=$(run_json CI suite COMPLETED SUCCESS "$T1")
KW_OLD_FAIL=$(run_json "Pull request description" "Closing keywords GitHub reads" COMPLETED FAILURE "$T1")
KW_NEW_PASS=$(run_json "Pull request description" "Closing keywords GitHub reads" COMPLETED SUCCESS "$T2")
KW_OLD_PASS=$(run_json "Pull request description" "Closing keywords GitHub reads" COMPLETED SUCCESS "$T1")
KW_NEW_FAIL=$(run_json "Pull request description" "Closing keywords GitHub reads" COMPLETED FAILURE "$T2")

# 1. A failed run superseded by a pass on the same head is green, whichever order gh lists them in.
for order in "$KW_OLD_FAIL,$KW_NEW_PASS" "$KW_NEW_PASS,$KW_OLD_FAIL"; do
  dir=$(make_repo without-tool "$(rollup_of "$SUITE_GREEN" "$order")")
  out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
  if denied "$out"; then
    fail "a failed run superseded by a passing run of the same check was counted against the merge: $out"
  else pass; fi
  rm -rf "$dir"
done

# 2. The positive control in the same shape: a pass superseded by a FAILURE is red, in both orders,
#    and in the green gate's own words. Without this, the case above is satisfied by a gate that
#    stopped reading failures at all (L159).
for order in "$KW_OLD_PASS,$KW_NEW_FAIL" "$KW_NEW_FAIL,$KW_OLD_PASS"; do
  dir=$(make_repo without-tool "$(rollup_of "$SUITE_GREEN" "$order")")
  out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
  if refused_red "$out"; then pass; else
    fail "a check whose NEWEST run failed was allowed because an older run had passed: $out"
  fi
  if holds "$out" "Closing keywords GitHub reads=FAILURE"; then pass; else
    fail "the refusal does not name the check whose newest run failed: $out"
  fi
  rm -rf "$dir"
done

# 3. The newest run still going is not green, even over an older pass. It has a start time, so it
#    sorts newest.
dir=$(make_repo without-tool "$(rollup_of "$SUITE_GREEN" "$KW_OLD_PASS" \
  "$(run_json "Pull request description" "Closing keywords GitHub reads" IN_PROGRESS "" "$T2")")")
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if refused_red "$out"; then pass; else
  fail "a check whose newest run is still in progress was read as green from an older pass: $out"
fi
if holds "$out" "Closing keywords GitHub reads=PENDING"; then pass; else
  fail "the refusal does not say the newest run is pending: $out"
fi
rm -rf "$dir"

# 4. A QUEUED run has not started, and gh writes its missing start time as the zero time, which
#    sorts OLDEST. Ordered naively, the older pass would answer for a run nobody has seen finish.
dir=$(make_repo without-tool "$(rollup_of "$SUITE_GREEN" "$KW_OLD_PASS" \
  "$(run_json "Pull request description" "Closing keywords GitHub reads" QUEUED "" "0001-01-01T00:00:00Z")")")
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if refused_red "$out"; then pass; else
  fail "a queued rerun with no start time was outranked by an older pass: $out"
fi
rm -rf "$dir"

# 5. Two workflows can each carry a job of the same name. Those are two checks, not two runs of one,
#    so a newer pass in one workflow must not answer for a failure in the other.
dir=$(make_repo without-tool "$(rollup_of \
  "$(run_json lint test COMPLETED FAILURE "$T1")" "$(run_json unit test COMPLETED SUCCESS "$T2")")")
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if refused_red "$out"; then pass; else
  fail "a failing job was hidden by a newer job of the same name in a DIFFERENT workflow: $out"
fi
rm -rf "$dir"

# 6. Runs that cannot be put in order say nothing about which is newest, so every run counts, as it
#    did before. A superseding pass nobody can date is not allowed to clear a failure.
dir=$(make_repo without-tool "$(rollup_of \
  '{"name":"tests","conclusion":"FAILURE"}' '{"name":"tests","conclusion":"SUCCESS"}')")
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if refused_red "$out"; then pass; else
  fail "an undated pass was taken as superseding an undated failure: $out"
fi
rm -rf "$dir"
#    And where only SOME runs are dated. Picking the newest of the dated ones would hide the undated
#    failure, which is the case the rule above exists for: when both are undated, taking every run
#    tied on "no date" happens to give the same answer, so that pair alone could not see it removed.
dated_pass=$(printf '{"name":"tests","conclusion":"SUCCESS","startedAt":"%s"}' "$T2")
dir=$(make_repo without-tool "$(rollup_of '{"name":"tests","conclusion":"FAILURE"}' "$dated_pass")")
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if refused_red "$out"; then pass; else
  fail "a dated pass was taken as superseding a failure nobody could date: $out"
fi
# Refused by the GREEN gate, not by a fixture gh could not parse, which is also a refusal (L140).
if holds "$out" "tests=FAILURE"; then pass; else
  fail "the undated failure was not the reason for the refusal: $out"
fi
rm -rf "$dir"

#    The zero time is gh's spelling of "no start time", so it is undated too, not the oldest date
#    there is. A finished failure carrying it must not be outranked by a dated pass.
zero_fail=$(run_json CI suite COMPLETED FAILURE "0001-01-01T00:00:00Z")
dir=$(make_repo without-tool "$(rollup_of "$zero_fail" "$(run_json CI suite COMPLETED SUCCESS "$T2")")")
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if refused_red "$out"; then pass; else
  fail "a failure whose start time was gh's zero time was treated as the oldest run: $out"
fi
rm -rf "$dir"

#    Two runs started in the same second cannot be told apart by their start, so both count, in
#    both orders, and a failure is never hidden behind a pass that merely sorted after it.
for order in "$(run_json CI suite COMPLETED FAILURE "$T2"),$(run_json CI suite COMPLETED SUCCESS "$T2")" \
             "$(run_json CI suite COMPLETED SUCCESS "$T2"),$(run_json CI suite COMPLETED FAILURE "$T2")"; do
  dir=$(make_repo without-tool "$(rollup_of "$order")")
  out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
  if refused_red "$out"; then pass; else
    fail "a failure started in the same second as a pass was hidden by it: $out"
  fi
  rm -rf "$dir"
done

# 6b. A run still going counts whenever it started. One that started BEFORE a pass finished is not
#     superseded by it (two events can each start a run of one check on one head, and the newest
#     start is not proof the older run will pass), so the check stays pending until it ends.
dir=$(make_repo without-tool "$(rollup_of \
  "$(run_json CI suite IN_PROGRESS "" "$T1")" "$(run_json CI suite COMPLETED SUCCESS "$T2")")")
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if refused_red "$out"; then pass; else
  fail "a run still in progress was hidden by a pass that started after it: $out"
fi
rm -rf "$dir"

# 7. A commit status (the older API) carries context and state, and gh dates it too. Its newest
#    report is the verdict in the same way.
#    The runs are built in variables first: escaped quotes inside a command substitution nested in
#    another one are parsed differently by different bash versions, and the fixture arrived as JSON
#    that would not parse, which the gate correctly refused for a reason unrelated to this case.
legacy_old=$(printf '{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE","startedAt":"%s"}' "$T1")
legacy_new=$(printf '{"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","startedAt":"%s"}' "$T2")
dir=$(make_repo without-tool "$(rollup_of "$legacy_old" "$legacy_new")")
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")
if denied "$out"; then
  fail "a commit status whose newest report passed was refused on an older one: $out"
else pass; fi
rm -rf "$dir"

echo "block-red-merge: the pin goes on the gh invocation, not after a pipe (#382)"

# The refusal used to build its suggestion as the whole command plus the flag, so a piped merge came
# back as `... 2>&1 | cat --match-head-commit <sha>`. Run as printed, the flag went to cat, the merge
# was not pinned, and the gate's own reading of the pin accepted it, so nothing said so.
reason_of() {  # $1 = hook output ; prints the refusal text with JSON escaping undone
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null
}
dir=$(make_repo without-tool "$GREEN")
while IFS= read -r line; do
  [ -n "$line" ] || continue
  given="${line%% => *}"
  expected="${line#* => }"
  expected="${expected//SHA/$HEAD_SHA}"
  out=$(reason_of "$(run_hook "$dir" "$given")")
  if holds "$out" "Run: $expected . "; then pass; else
    fail "the pinned suggestion for [$given] is not [$expected]: $out"
  fi
done <<'CASES'
gh pr merge 7 --squash --delete-branch 2>&1 | cat => gh pr merge 7 --squash --delete-branch --match-head-commit SHA 2>&1 | cat
gh pr merge 7 --squash && echo merged => gh pr merge 7 --squash --match-head-commit SHA && echo merged
gh pr merge 7 --squash; echo done => gh pr merge 7 --squash --match-head-commit SHA; echo done
echo start && gh pr merge 7 --squash | tail -1 => echo start && gh pr merge 7 --squash --match-head-commit SHA | tail -1
gh pr merge 7 --squash => gh pr merge 7 --squash --match-head-commit SHA
gh pr merge 7 --squash --body "a | b; c" | cat => gh pr merge 7 --squash --body "a | b; c" --match-head-commit SHA | cat
CASES

# And the suggestion's own mistake is refused when somebody runs it: a pin after the pipe is handed
# to cat, so the merge is unpinned, and the gate reading the flag anywhere in the line is what let
# that through in silence. The pin counts only on the gh invocation itself.
out=$(run_hook "$dir" "gh pr merge 7 --squash 2>&1 | cat --match-head-commit $HEAD_SHA")
if denied "$out"; then pass; else
  fail "a pin handed to the command after the pipe was accepted as pinning the merge: $out"
fi
out=$(run_hook "$dir" "gh pr merge 7 --squash && echo --match-head-commit $HEAD_SHA")
if denied "$out"; then pass; else
  fail "a pin written into a later command was accepted as pinning the merge: $out"
fi
# The control: the same pipe with the pin where it belongs still merges (L159).
out=$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA 2>&1 | cat")
if denied "$out"; then
  fail "a piped merge pinned on the gh invocation was refused: $out"
else pass; fi
rm -rf "$dir"

# A command that merely TALKS about merging is not a merge. This gate is a PreToolUse
# DENY, so a false positive refuses the WHOLE command and nothing in it runs: on
# 2026-09-10 a heredoc writing an issue body about merge tooling was refused with a
# message about pinning a commit that no command was trying to merge, and the file the
# next step expected was simply not there (claude-config#349).
#
# lib/merge-target.sh has the matcher's own cases. These are here because a correct
# predicate is worth nothing until the gate actually CALLS it (L3).
#
# Assembled from $MERGE rather than written out, so the payload of the command that
# WRITES this file does not itself trip the gate.
MERGE_CMD="gh pr me""rge"
dir=$(make_repo without-tool "$RED")
note="cat > docs/merge-notes.md <<'EOF'
The gate resolves the number; then $MERGE_CMD 7 --squash is what runs
EOF"
out=$(run_hook "$dir" "$note")
if denied "$out"; then fail "a heredoc about merging was refused as a merge: $out"; else pass; fi
out=$(run_hook "$dir" "gh issue comment 5 --body \"then run $MERGE_CMD\"")
if denied "$out"; then fail "an issue comment about merging was refused as a merge: $out"; else pass; fi
# The positive control in the SAME fixture: without it, the two above are satisfied by a
# gate that has stopped refusing anything at all (L159). This rollup is RED, so a real
# merge here must be denied.
out=$(run_hook "$dir" "$MERGE_CMD 7 --squash")
if denied "$out"; then pass; else fail "a red pull request merged, so the cases above prove nothing: $out"; fi
rm -rf "$dir"

# And the wrapper stays OUT of this gate's question. Where a repo carries its own commit
# pinned tool this gate NAMES that tool as the route to take, so firing on it would refuse
# the very command it had just recommended, which is a refusal nothing can clear (L109).
dir=$(make_repo with-tool "$GREEN")
out=$(run_hook "$dir" "venv/bin/python tools/wait_for_checks.py 7 --merge")
if denied "$out"; then fail "the gate refused PET's own pinned tool: $out"; else pass; fi
rm -rf "$dir"
dir=$(make_repo with-npm-tool "$GREEN")
out=$(run_hook "$dir" "npm run merge -- 7")
if denied "$out"; then fail "the gate refused the merge route it tells people to use: $out"; else pass; fi
rm -rf "$dir"

# The gate must hold NO list of its own. It kept one, testing for each tool's file by
# hand, while lib/merge-target.sh kept a second list for a different question, and the two
# had to agree by hand. That is what claude-config#351 was, so the guard is on the
# duplication rather than on any one tool (L41, L30).
#
# A source scan, because behaviour cannot see this: both copies agreeing is exactly what
# the passing tests looked like right up to the day they stopped.
own_list=$(grep -nE '^[^#]*\[ -f "(tools|\.github|scripts)/' "$(dirname "$HOOK")/block-red-merge.sh" || true)
if [ -n "$own_list" ]; then
  fail "the gate tests for a merge tool's file itself instead of asking the declaration: $own_list"
else pass; fi
# And it really does consult the shared declaration, so the check above is not satisfied by
# a gate that simply stopped looking for tools at all (L98).
if grep -q 'mt_pinned_tool' "$(dirname "$HOOK")/block-red-merge.sh"; then pass; else
  fail "the gate does not read the shared tool declaration"; fi

echo "block-red-merge: the repository the merge names, not the session's folder (#463)"

# Measured 2026-09-19 from a session started in Ovation, merging danwright32/backstage#26 with both
# checks passed: `--repo danwright32/backstage` was refused as "gh pr view returned nothing", and so
# was a cd written after an assignment, because the gate asked gh about the session's own folder,
# which has no pull request 26. A refusal on a green pull request that names the override teaches
# reaching for the override (L36), and "I could not find it" is not "I could not confirm it is
# green" (L11).
#
# The fake gh resolves a repository the way the real one does: --repo or -R first, then the remote
# of the directory it runs in. It answers a pull request only for a repository with a file under
# prs/, and a contents probe only for a path under remote/, with a 404 otherwise.
make_two_repos() {  # prints a fixture dir holding repo/ (acme/widget) and other/ (other/repo)
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/repo" "$dir/other" "$dir/bin" "$dir/prs" "$dir/remote"
  ( cd "$dir/repo" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
  ( cd "$dir/other" && git init -q && git remote add origin "https://github.com/other/repo.git" )
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
repo="" prev=""
for a in "$@"; do
  case "$prev" in --repo|-R) repo="$a" ;; esac
  case "$a" in --repo=*) repo="${a#--repo=}" ;; esac
  prev="$a"
done
[ -n "$repo" ] || repo=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^https://github.com/##; s#[.]git$##')
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*)
    if [ -n "${GH_OFFLINE:-}" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
    f="$FIXTURE/prs/$(printf '%s' "$repo" | tr / _)"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    echo "GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)" >&2
    exit 1 ;;
  "api "*)
    if [ -n "${GH_API_BROKEN:-}" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
    for a in "$@"; do
      case "$a" in repos/*)
        if [ -e "$FIXTURE/remote/$a" ]; then echo '{}'; exit 0; fi
        echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      esac
    done
    exit 1 ;;
esac
SH
  chmod +x "$dir/bin/gh"
  printf '%s' "$dir"
}
pr_json() {  # $1 = owner/name, $2 = SUCCESS | FAILURE | none
  if [ "$2" = none ]; then
    printf '{"number":7,"statusCheckRollup":[],"mergeable":"MERGEABLE","url":"https://github.com/%s/pull/7","headRefOid":"%s"}' "$1" "$HEAD_SHA"
  else
    printf '{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"%s"}],"url":"https://github.com/%s/pull/7","headRefOid":"%s"}' "$2" "$1" "$HEAD_SHA"
  fi
}
two_repos() {  # $1 = other/repo's verdict ; sets dir, FIXTURE and GH_CALL_LOG
  dir=$(make_two_repos)
  FIXTURE="$dir"; GH_CALL_LOG="$dir/gh-calls.log"; export FIXTURE GH_CALL_LOG; : > "$GH_CALL_LOG"
  pr_json other/repo "$1" > "$dir/prs/other_repo"
}
asked_about() {  # $1 = a literal the gh call log must hold
  case "$(cat "$GH_CALL_LOG")" in *"$1"*) return 0 ;; *) return 1 ;; esac
}
PIN="--squash --match-head-commit $HEAD_SHA"

# The issue's own case: --repo naming a repository other than the folder the session sits in.
for form in "--repo other/repo" "-R other/repo" "--repo=other/repo"; do
  two_repos SUCCESS
  out=$(run_hook "$dir" "gh pr merge 7 $form $PIN")
  if denied "$out"; then fail "a green pull request named by [$form] was refused: $out"; else pass; fi
  # And it was allowed because gh was asked about other/repo, not because something else let it by.
  if asked_about "pr view 7 --repo other/repo"; then pass; else
    fail "[$form] did not make the gate ask gh about other/repo: $(cat "$GH_CALL_LOG")"
  fi
  rm -rf "$dir"
done

# Never loosened: a red pull request in the named repository is still refused, in the green gate's
# own words, so the refusal is about its checks and not about failing to find it.
two_repos FAILURE
out=$(run_hook "$dir" "gh pr merge 7 --repo other/repo $PIN")
if denied "$out" && holds "$out" "is not green: tests=FAILURE"; then pass; else
  fail "a red pull request named by --repo was not refused as red: $out"
fi
rm -rf "$dir"

# A cd that does not lead the command: after an assignment, and a relative one.
two_repos SUCCESS
out=$(run_hook "$dir" "H=\$(echo 7) ; cd $dir/other && gh pr merge 7 $PIN")
if denied "$out"; then fail "a green merge behind a cd after an assignment was refused: $out"; else pass; fi
out=$(run_hook "$dir" "cd ../other && gh pr merge 7 $PIN")
if denied "$out"; then fail "a green merge behind a relative cd was refused: $out"; else pass; fi
rm -rf "$dir"

# NOT FOUND is its own refusal, naming the repository that was searched, and it is not the "could
# not confirm it is green" sentence, which sends somebody to the override (L11, L36).
two_repos SUCCESS
out=$(run_hook "$dir" "gh pr merge 7 --repo nobody/there $PIN")
if denied "$out"; then pass; else fail "a pull request that does not exist was allowed to merge: $out"; fi
if says "$out" "no pull request #7 was found in nobody/there"; then pass; else
  fail "the not found refusal does not say so, naming the repository searched: $out"
fi
if holds "$out" "Cannot verify CI" || holds "$out" "ALLOW_RED_MERGE"; then
  fail "the not found refusal reads as an unconfirmed verdict or offers the override: $out"
else pass; fi
# The same from the folder, with no --repo: it names the folder's repository.
out=$(run_hook "$dir" "gh pr merge 7 $PIN")
if denied "$out" && says "$out" "no pull request #7 was found in acme/widget"; then pass; else
  fail "the not found refusal from the session folder does not name acme/widget: $out"
fi
rm -rf "$dir"

# gh FAILING is not gh finding nothing: that stays "could not verify", naming where it looked.
two_repos SUCCESS
out=$(GH_OFFLINE=1 run_hook "$dir" "gh pr merge 7 --repo other/repo $PIN")
if denied "$out" && holds "$out" "Cannot verify CI" && holds "$out" "other/repo"; then pass; else
  fail "gh failing to answer was not refused as unverifiable, naming the repository: $out"
fi
if says "$out" "was found in"; then fail "a gh failure was reported as the pull request not existing: $out"; else pass; fi
rm -rf "$dir"

# A repository named by --repo is not the folder the gate stands in, so the folder's files say
# nothing about it. A merge tool the NAMED repository carries still has to be used, read from that
# repository, or naming it would be a way round the tool rule.
two_repos SUCCESS
mkdir -p "$dir/remote/repos/other/repo/contents/tools"
: > "$dir/remote/repos/other/repo/contents/tools/wait_for_checks.py"
out=$(run_hook "$dir" "gh pr merge 7 --repo other/repo $PIN")
if denied "$out" && holds "$out" "wait_for_checks.py 7 --merge"; then pass; else
  fail "a merge named by --repo skipped that repository's own merge tool: $out"
fi
rm -rf "$dir"
# And the folder's OWN tool does not stand in for the named repository's.
two_repos SUCCESS
mkdir -p "$dir/repo/tools"; : > "$dir/repo/tools/wait_for_checks.py"
out=$(run_hook "$dir" "gh pr merge 7 --repo other/repo $PIN")
if denied "$out"; then fail "the session folder's merge tool was demanded for another repository: $out"; else pass; fi
rm -rf "$dir"
# When the gate cannot tell whether the named repository carries a tool, it refuses in its own words.
two_repos SUCCESS
out=$(GH_API_BROKEN=1 run_hook "$dir" "gh pr merge 7 --repo other/repo $PIN")
if denied "$out" && says "$out" "could not tell whether other/repo"; then pass; else
  fail "an unreadable tool probe did not refuse in its own words: $out"
fi
rm -rf "$dir"

# No checks at all in the named repository: its workflows are read from it, not from the folder.
two_repos none
out=$(run_hook "$dir" "gh pr merge 7 --repo other/repo --squash")
if denied "$out"; then fail "a named repository with no workflows was blocked for having no checks: $out"; else pass; fi
mkdir -p "$dir/remote/repos/other/repo/contents/.github"
: > "$dir/remote/repos/other/repo/contents/.github/workflows"
out=$(run_hook "$dir" "gh pr merge 7 --repo other/repo --squash")
if denied "$out" && holds "$out" "other/repo"; then pass; else
  fail "a named repository that has workflows was merged with no checks: $out"
fi
rm -rf "$dir"
unset FIXTURE GH_CALL_LOG

echo "block-red-merge: the reader the shared library needs (#475)"

# Which pull request and which repository the merge names are read with python3 in
# lib/merge-target.sh. Where that reader is absent BOTH come back empty, so this gate asked gh
# about whatever pull request the current branch resolves to and merged this one on that answer.
# It has to refuse, and refuse BY NAME: "no pull request was found" is a true sentence about a
# different fault, and it sends somebody to name a repository that was never the problem (L11).
#
# The tools the hook needs, its fake gh included, are linked into a bare directory so nothing
# else on this machine's PATH can answer for python3.
nopython_bin() {  # $1 = a fixture dir holding bin/gh ; prints a bin directory with no python3
  local out="$1/nopython" t p
  mkdir -p "$out"
  for t in bash sh git jq grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm; do
    p="$(command -v "$t" 2>/dev/null)"
    [ -n "$p" ] && [ "$p" != "$1/bin/$t" ] && ln -s "$p" "$out/$t" 2>/dev/null
  done
  ln -s "$1/bin/gh" "$out/gh" 2>/dev/null
  printf '%s' "$out"
}

# GREEN, deliberately: the strong form. This is the fixture the gate LETS THROUGH when it can
# read the command, so a refusal here can only be the missing reader's doing (L159).
dir=$(make_repo without-tool "$GREEN")
nopy="$(nopython_bin "$dir")"
if PATH="$nopy" bash -c 'command -v python3 >/dev/null 2>&1'; then
  fail "the bare directory still reaches a python3, so this case measures nothing"
else pass; fi
out=$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
  "$(printf '%s' "gh pr merge 7 --squash --match-head-commit $HEAD_SHA" \
     | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
  "$(printf '%s' "$dir/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
  | (cd "$dir/repo" && PATH="$nopy" bash "$HOOK"))
if denied "$out"; then pass; else
  fail "with no python3 the gate merged a pull request it could not identify: $out"; fi
if says "$out" "python3"; then pass; else
  fail "the refusal does not name the reader that is missing: $out"; fi
# And it must not read as a pull request nobody could find, which is the message this replaces.
if says "$out" "was found in"; then
  fail "the missing reader was reported as the pull request not existing: $out"; else pass; fi
# The control, same fixture and same command with python3 on PATH: it merges. So the refusal
# above is the reader's absence rather than a fixture that refuses everything (L159).
if denied "$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")"; then
  fail "the control case refused a green pinned merge, so the case above proves nothing"
else pass; fi
rm -rf "$dir"

echo "block-red-merge: the reader the PAYLOAD needs (#480)"

# The command this gate judges is read out of the hook payload, which is JSON. That read used to be
# a bare jq, one line above the `command -v gh` that names gh: with no jq the command came back
# EMPTY, mt_is_pr_merge answered no, and the gate exited 0 on every merge with nothing said. An
# absent reader is the one failure that looks exactly like a clean run (L490, L42, L98).
#
# Everything past that read is jq's too: gh's answer about the checks arrives as JSON and the
# refusal itself is built with jq. So jq's absence is refused whether or not python3 is there.
bin_without() {  # $1 = a fixture dir holding bin/gh, $2.. = the tools to leave OUT
  local out="$1/without-$2" t p drop
  mkdir -p "$out"
  for t in bash sh git jq python3 grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm; do
    drop=0
    for p in "${@:2}"; do [ "$t" = "$p" ] && drop=1; done
    [ "$drop" = 1 ] && continue
    p="$(command -v "$t" 2>/dev/null)"
    [ -n "$p" ] && [ "$p" != "$1/bin/$t" ] && ln -s "$p" "$out/$t" 2>/dev/null
  done
  ln -s "$1/bin/gh" "$out/gh" 2>/dev/null
  printf '%s' "$out"
}

NOREAD_OUT=""; NOREAD_RC=0
run_hook_on() {  # $1 = repo dir, $2 = bin dir, $3 = command ; stdout and stderr together, with rc
  NOREAD_OUT="$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$3" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | (cd "$1/repo" && PATH="$2" bash "$HOOK" 2>&1))"
  NOREAD_RC=$?
}

# GREEN, deliberately: the fixture this gate LETS THROUGH when it can read the command, so a
# refusal here can only be the missing reader's doing (L159).
dir=$(make_repo without-tool "$GREEN")
noread="$(bin_without "$dir" jq python3)"
if PATH="$noread" bash -c 'command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1'; then
  fail "the bare directory still reaches a jq or a python3, so these cases measure nothing"
else pass; fi

run_hook_on "$dir" "$noread" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA"
if [ "$NOREAD_RC" -eq 2 ]; then pass; else
  fail "with no payload reader at all the gate allowed the merge (rc=$NOREAD_RC): $NOREAD_OUT"; fi
if says "$NOREAD_OUT" "jq"; then pass; else
  fail "the refusal does not name jq, which is one of the two readers that is missing: $NOREAD_OUT"; fi
if says "$NOREAD_OUT" "python3"; then pass; else
  fail "the refusal does not name python3, the other reader it would have accepted: $NOREAD_OUT"; fi

# A command that cannot be a merge is not refused, however bare the PATH is. Without this the gate
# would refuse every Bash call on such a machine, which is a gate nobody keeps (L36, L54).
run_hook_on "$dir" "$noread" "ls -la"
if [ "$NOREAD_RC" -eq 0 ] && [ -z "$NOREAD_OUT" ]; then pass; else
  fail "an ordinary command was refused because the payload could not be read (rc=$NOREAD_RC): $NOREAD_OUT"; fi

# The documented override still works, or the refusal is one nothing in the session can clear
# (L109). It is read off the payload text, because the command itself cannot be parsed here.
run_hook_on "$dir" "$noread" "ALLOW_RED_MERGE=1 gh pr merge 7 --squash"
if [ "$NOREAD_RC" -eq 0 ] && [ -z "$NOREAD_OUT" ]; then pass; else
  fail "the visible override did not clear the unreadable payload refusal (rc=$NOREAD_RC): $NOREAD_OUT"; fi

# jq alone missing, python3 present: the command IS readable, so the gate knows this is a merge,
# and it must still refuse, because nothing left on the machine can tell a green rollup from a red
# one. This is the half that a python3 shaped fix would have left passing silently.
nojq="$(bin_without "$dir" jq)"
if PATH="$nojq" bash -c 'command -v jq >/dev/null 2>&1'; then
  fail "the bare directory still reaches a jq, so this case measures nothing"
else pass; fi
if PATH="$nojq" bash -c 'command -v python3 >/dev/null 2>&1'; then pass; else
  fail "the bare directory has no python3 either, so this case cannot separate the two"; fi
run_hook_on "$dir" "$nojq" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA"
if [ "$NOREAD_RC" -eq 2 ]; then pass; else
  fail "with no jq the gate allowed the merge (rc=$NOREAD_RC): $NOREAD_OUT"; fi
if says "$NOREAD_OUT" "jq"; then pass; else
  fail "the refusal does not name jq: $NOREAD_OUT"; fi

# The control, the same fixture and the same command with both readers on PATH: it merges. So
# every refusal above is the reader's absence rather than a fixture that refuses everything (L159).
if denied "$(run_hook "$dir" "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")"; then
  fail "the control case refused a green pinned merge, so the cases above prove nothing"
else pass; fi
rm -rf "$dir"

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
