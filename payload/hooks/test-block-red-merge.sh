#!/usr/bin/env bash
#
# test-block-red-merge.sh: the merge gate, including the rule that a repo
# carrying the commit pinned merge tool must use it (PostRoll #711).
#
# Every case runs the real hook with a fake `gh` first on PATH, so what is
# tested is the hook's own reading of an answer rather than a rewrite of its
# logic living here (L52).

set -uo pipefail

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

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
