#!/usr/bin/env bash
#
# test-merge-target.sh: lib/merge-target.sh, the four things a merge gate has to
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

echo "merge-target: a command, not its payload (claude-config#349)"

# The matcher used to test the whole command string for the phrase, with no command
# position check at all, so a command that merely CONTAINED it in its payload tripped
# a PreToolUse DENY. Hit twice on 2026-09-10, both times writing an issue body about
# merging: the whole command was refused, the heredoc never ran, and the failure
# surfaced one step later as a missing file rather than as the block that caused it.
#
# The correct matcher already existed in pr-merge-quiz.sh, a NON blocking hook, while
# the blocking gates shared the wrong one. That is the wrong way round: a false
# positive costs most where it denies.

# Command position, in every shape a real merge arrives in.
if mt_is_pr_merge "GH_TOKEN=abc $MERGE 42"; then pass; else fail "leading env assignments hid the merge"; fi
if mt_is_pr_merge "git fetch origin && $MERGE 42 --squash"; then pass; else fail "a merge in the second segment was missed"; fi
if mt_is_pr_merge "git fetch origin ; $MERGE 42"; then pass; else fail "a merge after a semicolon was missed"; fi
if mt_is_pr_merge "/opt/homebrew/bin/${MERGE} 42"; then pass; else fail "gh called by absolute path was missed"; fi

# Payload position. Each of these is a command that TALKS about merging and merges nothing.
if mt_is_pr_merge "echo \"$MERGE 42\""; then fail "an echo of the phrase was read as a merge"; else pass; fi
if mt_is_pr_merge "gh issue comment 5 --body \"then run $MERGE\""; then
  fail "an issue comment naming the phrase was read as a merge"; else pass; fi
if mt_is_pr_merge "grep -r \"$MERGE\" ."; then fail "a grep for the phrase was read as a merge"; else pass; fi
if mt_is_pr_merge "gh pr view 42 --json state"; then fail "gh pr view was read as a merge"; else pass; fi

# The incident itself: a heredoc writing prose about merging. Its body carries a
# semicolon, which is what a segment splitter cuts on, so the body has to be removed
# BEFORE the split rather than merely split carefully. Without the strip, the line
# after the semicolon starts a segment of its own.
heredoc_body="cat > docs/merge-notes.md <<'EOF'
The gate resolves the number; then $MERGE 7 --squash is what runs
EOF"
if mt_is_pr_merge "$heredoc_body"; then fail "a heredoc body mentioning the phrase was read as a merge"; else pass; fi

# A herestring is not a heredoc, and neither is an arithmetic shift. Stripping must not
# eat the rest of a command because it saw two angle brackets.
if mt_is_pr_merge "grep -q x <<< \"$MERGE\""; then fail "a herestring payload was read as a merge"; else pass; fi
if mt_is_pr_merge "echo \$((1 << 3)) && $MERGE 42"; then pass; else fail "an arithmetic shift swallowed the rest of the command"; fi

echo "merge-target: merges that do not say gh (claude-config#349)"

# A repo's own wrapper merges INTERNALLY, in a subprocess no hook can see. The quiz has
# to fire on it or it is silently dodged by using the project's recommended command.
#
# The BLOCKING gates deliberately must NOT: block-red-merge.sh tells somebody to run the
# wrapper, so firing on the wrapper would refuse the exact command it just recommended,
# and a refusal that can only be cleared by the thing it forbids is a deadlock (L109).
# So the two questions are two predicates over one tokeniser, not one predicate.
for w in "scripts/merge-when-green.sh 42" "./scripts/merge-when-green.sh 42" \
         "merge-when-green.sh 42" "bash .github/scripts/merge-pr.sh 680" "npm run merge -- 680"; do
  if mt_runs_merge "$w"; then pass; else fail "a merge wrapper was not read as a merge: $w"; fi
  if mt_is_pr_merge "$w"; then fail "a merge wrapper was read as a direct merge: $w"; else pass; fi
done

# Exactly `merge`, so the readiness check that merges nothing does not count.
if mt_runs_merge "npm run merge-ready -- 680"; then fail "the readiness check was read as a merge"; else pass; fi
if mt_runs_merge "echo \"use npm run merge -- 680\""; then fail "a mention of the npm script was read as a merge"; else pass; fi
if mt_runs_merge "ls merge-when-green.sh"; then fail "a wrapper named as an argument was read as a merge"; else pass; fi

# A direct merge is a merge under both questions.
if mt_runs_merge "$MERGE 42"; then pass; else fail "a direct merge was not read as a merge"; fi
if mt_runs_merge "echo \"$MERGE 42\""; then fail "an echo of the phrase was read as a merge"; else pass; fi
if mt_runs_merge ""; then fail "an empty command was read as a merge"; else pass; fi

echo "merge-target: which pull request"

eq "$(mt_pr_number "$MERGE 7 --squash")" "7" "number before the flags"
eq "$(mt_pr_number "$MERGE --squash --delete-branch 1186")" "1186" "number after the flags"
eq "$(mt_pr_number "cd /tmp/x && $MERGE 42 --squash")" "42" "number behind a cd"
# No number means gh resolves it from the current branch, which is what the
# merge itself would do. Empty is the correct answer, not a failure.
eq "$(mt_pr_number "$MERGE --squash")" "" "no number named"

# The same command-versus-payload distinction, because the number reader scanned the
# whole string too: a heredoc naming a different pull request would be read in
# preference to the one actually being merged, and afterwards the gate's verdict about
# the wrong pull request is indistinguishable from one about the right one (L70).
pr_note="cat > docs/merge-notes.md <<'EOF'
one day this will run $MERGE 999 --squash
EOF
$MERGE 7 --squash"
eq "$(mt_pr_number "$pr_note")" "7" "the number comes from the command, not from a heredoc"

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

echo "merge-target: the checkout under a project directory (#344)"

# The walk that finds a checkout from a directory is the SAME question the issue
# review's duplicate check has to answer before it can ask gh anything, and that
# check had an assumption of its own instead: it ran gh in the project directory
# and gave up when that directory was not a checkout, which in PET it never is,
# so the check had never once run there (claude-config#344). One named predicate
# rather than a second copy of the walk, and the executed mode below is how a
# caller that cannot source bash reaches it.
eq "$(mt_checkout_dir "$root/plain")" "$root/plain" "the directory is itself the checkout"
eq "$(mt_checkout_dir "$root/parent")" "$root/parent/pet" "the checkout is one level down"
eq "$(mt_checkout_dir "$root/deep/a/b")" "$root/deep" "the checkout is above the directory"

# No checkout anywhere: the directory itself, unchanged. The caller still gets
# something it can run in, and the refusal stays where the caller can report it
# in its own words rather than being turned into a wrong answer here.
mkdir -p "$root/bare"
eq "$(mt_checkout_dir "$root/bare")" "$root/bare" "no checkout anywhere leaves the directory alone"

# TWO checkouts under one directory: refuse to guess. The old walk returned whichever the glob
# yielded first, which is a lookup answering ANY where it needs exactly ONE (L521), and addressing
# something by its position measures whatever happens to occupy that position (L237). It matters
# because the issue review now resolves its repository this way: the wrong answer is not an odd
# place to look, it is another project's issue numbers stamped onto this project's findings, and
# match-open-issues.py is built on a wrong "already #N" being worse than none (claude-config#346).
mkdir -p "$root/two/alpha/.git" "$root/two/beta/.git"
eq "$(mt_checkout_dir "$root/two")" "$root/two" "two sibling checkouts resolve to neither"

# And the candidates are readable, so a caller refusing can NAME what it found rather than
# reporting the generic "nothing answered" that would otherwise stand in for this (L11).
eq "$(mt_checkout_candidates "$root/two" | sort | tr '\n' ' ')" "$root/two/alpha $root/two/beta " \
  "both candidates are listed"
# One candidate is still one: the list is not a way of re-introducing the guess.
eq "$(mt_checkout_candidates "$root/parent")" "$root/parent/pet" "a single candidate is listed alone"
eq "$(mt_checkout_candidates "$root/bare")" "" "no candidates where there is no checkout"

# The ancestor walk still WINS over the ambiguity, because a directory inside a checkout is not
# ambiguous at all: it belongs to the checkout above it whatever its children look like.
mkdir -p "$root/deep/two/alpha/.git" "$root/deep/two/beta/.git"
eq "$(mt_checkout_dir "$root/deep/two")" "$root/deep" "a directory inside a checkout is not ambiguous"

# The executed mode. One implementation with two callers, because the other
# caller is Python: a second copy of this walk in another language is two rules
# that drift silently, each passing its own suite (L263, L370).
eq "$(bash "$HOOK_DIR/lib/merge-target.sh" checkout-dir "$root/parent")" "$root/parent/pet" \
  "the executed mode answers what the function answers"
eq "$(bash "$HOOK_DIR/lib/merge-target.sh" checkout-candidates "$root/two" | sort | tr '\n' ' ')" \
  "$root/two/alpha $root/two/beta " "the candidates are reachable from the executed mode too"

# And SOURCING stays inert. Both merge gates source this file, and a dispatch
# that ran on the way in would run with whatever positional arguments the gate
# happened to be holding.
sourced_noise="$(bash -c '. "$1" checkout-dir /tmp; :' _ "$HOOK_DIR/lib/merge-target.sh" 2>&1)"
eq "$sourced_noise" "" "sourcing the file prints nothing and runs nothing"

# An argument it cannot serve is refused, never answered with the default scope:
# a run about the wrong thing looks exactly like a run about the right one (L320).
if bash "$HOOK_DIR/lib/merge-target.sh" nonsense "$root/parent" >/dev/null 2>&1; then
  fail "an unknown subcommand was accepted"
else pass; fi

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
