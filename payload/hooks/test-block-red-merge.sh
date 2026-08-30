#!/usr/bin/env bash
#
# test-block-red-merge.sh — the merge gate, including the rule that a repo
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

GREEN='{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"SUCCESS"}]}'
RED='{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"FAILURE"}]}'
# A pull request with NO checks at all. GitHub answers this way for two very different reasons,
# and the gate has to tell them apart (claude-config#131).
NONE_CLEAN='{"number":7,"statusCheckRollup":[],"mergeable":"MERGEABLE"}'
NONE_CONFLICTING='{"number":7,"statusCheckRollup":[],"mergeable":"CONFLICTING"}'
NONE_UNKNOWN='{"number":7,"statusCheckRollup":[],"mergeable":"UNKNOWN"}'

denied() { printf '%s' "$1" | grep -q '"permissionDecision": *"deny"'; }

echo "block-red-merge: the commit pinned rule (#711)"

# 1. The rule itself: a repo carrying the tool must merge through it.
dir=$(make_repo with-tool "$GREEN")
out=$(run_hook "$dir" "gh pr merge 7 --squash --delete-branch")
if denied "$out"; then pass; else
  fail "a plain gh pr merge was allowed in a repo that carries the pinned merge tool"
fi
# And the refusal has to say what to run instead, or it is a dead end.
if printf '%s' "$out" | grep -q "wait_for_checks.py 7 --merge"; then pass; else
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

# 3. The visible override, for the one case where the tool cannot be used.
dir=$(make_repo with-tool "$GREEN")
if denied "$(run_hook "$dir" "ALLOW_UNPINNED_MERGE=1 gh pr merge 7 --squash")"; then
  fail "the visible override did not let the merge through"
else pass; fi
rm -rf "$dir"

# 4. The control: a repo WITHOUT the tool still merges the old way, or this
#    rule would have quietly blocked every other project (L159).
dir=$(make_repo without-tool "$GREEN")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then
  fail "a green PR in a repo without the tool was blocked"
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
if printf '%s' "$out" | grep -q "npm run merge -- 7"; then pass; else
  fail "the refusal does not name the wrapper's own command: $out"
fi
# It must name the tool it found, not the other repo's, or the message sends
# somebody to a file that is not there.
if printf '%s' "$out" | grep -q "wait_for_checks"; then
  fail "the refusal names the other repo's tool: $out"
else pass; fi
rm -rf "$dir"

# 7. The visible override works for the second tool too.
dir=$(make_repo with-npm-tool "$GREEN")
if denied "$(run_hook "$dir" "ALLOW_UNPINNED_MERGE=1 gh pr merge 7 --squash")"; then
  fail "the visible override did not let the merge through for the shell wrapper"
else pass; fi
rm -rf "$dir"

# 8. And a red PR there is still refused by the ORIGINAL gate, reached through
#    the override, so the two rules do not answer for each other (L178).
dir=$(make_repo with-npm-tool "$RED")
if denied "$(run_hook "$dir" "ALLOW_UNPINNED_MERGE=1 gh pr merge 7 --squash")"; then pass; else
  fail "a red PR was allowed through once the pinned-tool rule was overridden"
fi
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
if printf '%s' "$out" | grep -qi 'conflict'; then pass; else
  fail "the refusal does not say the branch conflicts, which is the one thing that explains it: $out"
fi
if printf '%s' "$out" | grep -qi 'rebase\|merge the base'; then pass; else
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
if printf '%s' "$out" | grep -qi 'conflict'; then
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
if printf '%s' "$out" | grep -qi 'conflict'; then
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
      printf '%s\n' '{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"SUCCESS"}],"url":"https://github.com/acme/widget/pull/7"}'
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
      printf '%s\n' '{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"FAILURE"}],"url":"https://github.com/acme/widget/pull/7"}'
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
out=$(run_hook "$dir" "gh pr merge 7 --squash")
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

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
