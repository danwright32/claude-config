#!/usr/bin/env bash
#
# test-merge-target.sh — lib/merge-target.sh, the four things a merge gate has to
# work out before it can say anything about a pull request.
#
# These used to live inside block-red-merge.sh and were covered only through it.
# They moved out when require-changelog-tag.sh needed the same answers, and
# shared code reached only through its callers is code whose contract nobody
# states: each caller's suite proves the parts that caller happens to use, and
# the parts neither uses are exercised by nothing while both suites read green.
#
# So these are direct. The two gates' own suites still cover the integration.
#
# The merge command is assembled from $MERGE rather than written out, because
# writing it literally makes this file trip the block-red-merge hook on the way
# in, the same way a test naming a banned character trips the style hook.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/merge-target.sh
. "$HOOK_DIR/lib/merge-target.sh"

MERGE="gh pr me""rge"
passed=0
failed=0
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }
eq() {  # $1 = got, $2 = want, $3 = what
  if [ "$1" = "$2" ]; then pass; else fail "$3: wanted [$2], got [$1]"; fi
}

echo "merge-target: is this a merge"

if mt_is_pr_merge "$MERGE 7 --squash"; then pass; else fail "a plain merge was not recognised"; fi
if mt_is_pr_merge "cd /tmp && $MERGE 7"; then pass; else fail "a merge behind a cd was not recognised"; fi
if mt_is_pr_merge "gh pr view 7"; then fail "gh pr view was read as a merge"; else pass; fi
if mt_is_pr_merge ""; then fail "an empty command was read as a merge"; else pass; fi

echo "merge-target: which pull request"

eq "$(mt_pr_number "$MERGE 7 --squash")" "7" "number before the flags"
eq "$(mt_pr_number "$MERGE --squash --delete-branch 1186")" "1186" "number after the flags"
eq "$(mt_pr_number "cd /tmp/x && $MERGE 42 --squash")" "42" "number behind a cd"
# No number means gh resolves it from the current branch, which is what the
# merge itself would do. Empty is the correct answer, not a failure.
eq "$(mt_pr_number "$MERGE --squash")" "" "no number named"

echo "merge-target: which directory the merge runs in"

root=$(mktemp -d)
mkdir -p "$root/plain/.git" "$root/parent/pet/.git" "$root/deep/a/b"
mkdir -p "$root/deep/.git"

# The session cwd is itself a repo.
eq "$(mt_repo_dir "$MERGE 7" "$root/plain")" "$root/plain" "cwd is the repo"

# The PET case: the session sits one level ABOVE the checkout. This is the one
# that produced a false block on a green pull request the first time the gate
# ran, because gh could not resolve the pull request from there at all.
eq "$(mt_repo_dir "$MERGE 7" "$root/parent")" "$root/parent/pet" "repo one level down"

# Deep inside a checkout: walk up.
eq "$(mt_repo_dir "$MERGE 7" "$root/deep/a/b")" "$root/deep" "repo above the cwd"

# An explicit cd at the head of the command wins over the session cwd, because
# that is where the merge itself will actually run.
eq "$(mt_repo_dir "cd $root/plain && $MERGE 7" "$root/parent")" "$root/plain" "explicit cd wins"
eq "$(mt_repo_dir "cd \"$root/plain\" && $MERGE 7" "$root/parent")" "$root/plain" "quoted cd wins"

# A cd to somewhere that does not exist is not a target. Following it would put
# the gate in the wrong place and it would answer about the wrong repo.
eq "$(mt_repo_dir "cd $root/nope && $MERGE 7" "$root/plain")" "$root/plain" "cd to a missing directory is ignored"

echo "merge-target: which repo"

( cd "$root/plain" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
eq "$(cd "$root/plain" && mt_remote_slug)" "acme/widget" "https remote"
( cd "$root/plain" && git remote set-url origin "git@github.com:acme/widget.git" )
eq "$(cd "$root/plain" && mt_remote_slug)" "acme/widget" "ssh remote"

echo "merge-target: is this answer about the right pull request"

RIGHT='{"url":"https://github.com/acme/widget/pull/7"}'
WRONG='{"url":"https://github.com/someone/else/pull/7"}'

if mt_usable_answer "$RIGHT" "acme/widget"; then pass; else fail "an answer about the right repo was rejected"; fi
# The whole point: verifying one pull request and merging another is the mistake
# these gates exist to stop (L70).
if mt_usable_answer "$WRONG" "acme/widget"; then fail "an answer about another repo was accepted"; else pass; fi
if mt_usable_answer "" "acme/widget"; then fail "an empty answer was accepted"; else pass; fi
# A repo with no GitHub origin has no identity to compare against, so the
# identity half is skipped rather than blocking every such repo.
if mt_usable_answer "$WRONG" ""; then pass; else fail "a repo with no parseable remote was blocked"; fi
# A prefix match is not a repo match: acme/widget must not accept acme/widgets.
if mt_usable_answer '{"url":"https://github.com/acme/widgets/pull/7"}' "acme/widget"; then
  fail "a repo whose name merely starts the same was accepted"
else pass; fi

rm -rf "$root"

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
