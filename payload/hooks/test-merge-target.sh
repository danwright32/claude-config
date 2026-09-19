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

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

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

# A merge FOLLOWED by other commands is still a merge. The matcher piped the segment heads into
# `grep -q`, which leaves on the first match, so the writer still holding the later segments died of
# SIGPIPE and, under the pipefail every gate runs with, the whole answer became "not a merge" and
# both gates stepped aside (L183). Found 2026-09-17 while testing #382: `<merge> && echo merged` was
# let through by block-red-merge.sh on most runs. Many trailing segments make the writer reliably
# still busy when the reader leaves, so this fails every time rather than some of the time.
trailing=""
for _ in $(seq 1 400); do trailing="$trailing && echo x"; done
if mt_is_pr_merge "$MERGE 7 --squash$trailing"; then pass; else
  fail "a merge followed by other commands was not recognised, so every gate stepped aside"
fi
if mt_is_pr_merge "$MERGE 7 --squash && echo merged"; then pass; else
  fail "a merge followed by one echo was not recognised"
fi

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

# PET merges through its own commit pinned tool, run under a python interpreter, and
# that route was recognised by NOTHING: not the quiz, so it never fired in PET, and not
# the changelog gate, which block-red-merge makes the only route there by refusing the
# direct command (claude-config#351).
for w in "venv/bin/python tools/wait_for_checks.py 7 --merge" \
         "python3 tools/wait_for_checks.py 7 --merge" \
         ".venv/bin/python tools/wait_for_checks.py 7 --merge"; do
  if mt_runs_merge "$w"; then pass; else fail "PET's pinned tool was not read as a merge: $w"; fi
  if mt_is_pr_merge "$w"; then fail "PET's pinned tool was read as a direct merge: $w"; else pass; fi
done

# Without --merge the same tool only WAITS for the checks and merges nothing, so firing
# on it would quiz and gate every look at a pull request. The flag is the whole
# difference, which is why the segment is read rather than only its leading tokens.
if mt_runs_merge "venv/bin/python tools/wait_for_checks.py 7"; then
  fail "the tool merely waiting for checks was read as a merge"
else pass; fi
# And a mention of it is still only a mention.
if mt_runs_merge "echo \"run venv/bin/python tools/wait_for_checks.py 7 --merge\""; then
  fail "a mention of PET's tool was read as a merge"
else pass; fi

# Exactly `merge`, so the readiness check that merges nothing does not count.
if mt_runs_merge "npm run merge-ready -- 680"; then fail "the readiness check was read as a merge"; else pass; fi
if mt_runs_merge "echo \"use npm run merge -- 680\""; then fail "a mention of the npm script was read as a merge"; else pass; fi
if mt_runs_merge "ls merge-when-green.sh"; then fail "a wrapper named as an argument was read as a merge"; else pass; fi

# A direct merge is a merge under both questions.
if mt_runs_merge "$MERGE 42"; then pass; else fail "a direct merge was not read as a merge"; fi
if mt_runs_merge "echo \"$MERGE 42\""; then fail "an echo of the phrase was read as a merge"; else pass; fi
if mt_runs_merge ""; then fail "an empty command was read as a merge"; else pass; fi

echo "merge-target: the one declaration of a repo's own merge tool (claude-config#352)"

# The tools were named in TWO places that had to agree by hand: this library decided which
# commands count as a merge, block-red-merge.sh decided which repos must merge through
# their own tool, and the two lists overlapped without being identical. That is the exact
# shape of claude-config#351, where a tool sat in one list and not the other and a gate
# enforced nothing in the repo it was built for. One declaration, read by both (L41).

tools_root=$(mktemp -d)
mkdir -p "$tools_root/pet/tools" "$tools_root/onboarding/.github/scripts" \
         "$tools_root/green/scripts" "$tools_root/plain" "$tools_root/both/tools" \
         "$tools_root/both/.github/scripts"
: > "$tools_root/pet/tools/wait_for_checks.py"
: > "$tools_root/onboarding/.github/scripts/merge-pr.sh"
: > "$tools_root/green/scripts/merge-when-green.sh"
: > "$tools_root/both/tools/wait_for_checks.py"
: > "$tools_root/both/.github/scripts/merge-pr.sh"

eq "$(mt_pinned_tool "$tools_root/pet")" "tools/wait_for_checks.py" "PET's tool is found by its path"
eq "$(mt_pinned_tool "$tools_root/onboarding")" ".github/scripts/merge-pr.sh" "the shell tool is found by its path"
eq "$(mt_pinned_tool "$tools_root/plain")" "" "a repo with no tool has none"
# Order is preserved from the branch this replaced: where both exist, the python tool wins.
eq "$(mt_pinned_tool "$tools_root/both")" "tools/wait_for_checks.py" "the first declared tool wins"

# merge-when-green.sh is a merge ROUTE without being a PINNED tool. The quiz has to fire on
# it, and block-red-merge must NOT insist on it, because it makes no commit pin promise.
# One declaration carrying both facts is the whole point: two lists is what let them drift.
eq "$(mt_pinned_tool "$tools_root/green")" "" "a wrapper that is not commit pinned is not insisted on"
if mt_runs_merge "./scripts/merge-when-green.sh 42"; then pass; else
  fail "the unpinned wrapper stopped counting as a merge"; fi

# The invocation the refusal tells somebody to run has to be RUNNABLE, so it carries the
# pull request number. A remedy nobody can run is a refusal nothing can clear (L109, L406).
eq "$(mt_pinned_how "$tools_root/pet" 7)" "venv/bin/python tools/wait_for_checks.py 7 --merge" \
  "PET's tool is quoted with its number"
eq "$(mt_pinned_how "$tools_root/onboarding" 680)" "npm run merge -- 680" \
  "the npm route is quoted with its number"
# With no number known, a placeholder rather than an empty slot, so the sentence still reads.
eq "$(mt_pinned_how "$tools_root/pet" "")" "venv/bin/python tools/wait_for_checks.py <pr> --merge" \
  "an unknown number is a visible placeholder"

# Every declared tool must be a route the matcher recognises, or the declaration says one
# thing and the matcher another, which is the drift this replaced (L58, L263). Derived from
# the declaration rather than listed again here, so a tool added later is covered by this
# check without anybody remembering to extend it.
while IFS= read -r decl_path; do
  [ -n "$decl_path" ] || continue
  if mt_runs_merge "$(mt_pinned_how_for "$decl_path" 7)"; then pass; else
    fail "a declared tool is not recognised as a merge: $decl_path"; fi
done < <(mt_declared_tool_paths)
# And the declaration is not empty, because a loop over nothing passes every assertion in it
# at once (L98).
if [ "$(mt_declared_tool_paths | grep -c .)" -ge 3 ]; then pass; else
  fail "the tool declaration came back with fewer than the three known tools"; fi

rm -rf "$tools_root"

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

# A wrapper takes the pull request number as its first positional argument, and reading
# it is better than inferring one from the current branch: after a merge the branch is
# the thing most likely to have moved (claude-config#351).
eq "$(mt_pr_number "venv/bin/python tools/wait_for_checks.py 7 --merge")" "7" "PET's tool names its number"
eq "$(mt_pr_number "npm run merge -- 680")" "680" "the npm route names its number"
eq "$(mt_pr_number "bash .github/scripts/merge-pr.sh 680")" "680" "the shell wrapper names its number"
eq "$(mt_pr_number "./scripts/merge-when-green.sh 42")" "42" "the green wrapper names its number"
# A flag's own value is not a positional argument, so it is not the pull request.
eq "$(mt_pr_number "./scripts/merge-when-green.sh --timeout 900 42")" "42" "a flag value is not read as the number"
# No number named at all stays empty, so gh resolves it from the branch, which is what
# the merge itself would do. Empty is the correct answer here, not a failure.
eq "$(mt_pr_number "./scripts/merge-when-green.sh")" "" "a wrapper naming no number answers empty"
# The direct form still wins where both could be read.
eq "$(mt_pr_number "$MERGE 7 --squash")" "7" "the direct command still names its own number"

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

# A cd that does not LEAD the command still decides where the merge runs (claude-config#463). The
# gate used to honour only a leading cd, so a merge written after an assignment was judged in the
# session's own folder, found no such pull request there, and was refused. The cd is read by the
# push library's reader (ps_cd_target), not a second parser here (L613).
eq "$(mt_repo_dir "H=\$(gh pr view 7 --json url) ; cd $root/plain && $MERGE 7" "$root/parent")" "$root/plain" "a cd after an assignment wins"
eq "$(mt_repo_dir "(cd $root/plain && $MERGE 7)" "$root/parent")" "$root/plain" "a cd inside a subshell wins"
# A relative cd is relative to the session's directory, which is where the command runs, not to
# wherever the hook process happens to be standing.
eq "$(cd / && mt_repo_dir "cd ../plain && $MERGE 7" "$root/deep")" "$root/deep/../plain" "a relative cd resolves against the session cwd"
# Words inside a quoted string are not a cd.
eq "$(mt_repo_dir "echo \"cd $root/plain\" && $MERGE 7" "$root/deep/a/b")" "$root/deep" "a quoted cd is not a cd"

echo "merge-target: the repository a merge names with --repo (#463)"

# gh takes the repository from --repo or -R before anything about the directory, so a gate that
# asks gh about the directory instead is asking about a different repository whenever the two
# differ (claude-config#463, measured merging danwright32/backstage#26 from an Ovation session).
eq "$(mt_repo_flag "$MERGE 26 --repo danwright32/backstage --squash")" "danwright32/backstage" "--repo x/y"
eq "$(mt_repo_flag "$MERGE 26 --repo=danwright32/backstage --squash")" "danwright32/backstage" "--repo=x/y"
eq "$(mt_repo_flag "$MERGE 26 -R danwright32/backstage")" "danwright32/backstage" "-R x/y"
eq "$(mt_repo_flag "$MERGE 26 -Rdanwright32/backstage")" "danwright32/backstage" "-Rx/y"
eq "$(mt_repo_flag "$MERGE 26 --repo \"danwright32/backstage\"")" "danwright32/backstage" "a quoted value"
# The forms gh also accepts for the same repository are one repository, not three.
eq "$(mt_repo_flag "$MERGE 26 --repo github.com/danwright32/backstage")" "danwright32/backstage" "a host prefix"
eq "$(mt_repo_flag "$MERGE 26 --repo https://github.com/danwright32/backstage.git")" "danwright32/backstage" "a URL"
# Only the MERGE's own flag counts: a --repo on an earlier gh pr view is about that view.
eq "$(mt_repo_flag "H=\$(gh pr view 26 --repo someone/else) ; $MERGE 26 --squash")" "" "another command's --repo is not the merge's"
eq "$(mt_repo_flag "gh pr view 26 --repo someone/else && $MERGE 26 -R danwright32/backstage")" "danwright32/backstage" "the merge's own -R after another command's --repo"
# And none at all is empty, so the caller falls back to the directory.
eq "$(mt_repo_flag "$MERGE 26 --squash")" "" "no flag answers empty"
eq "$(mt_repo_flag "echo \"$MERGE 26 --repo a/b\"")" "" "a merge quoted inside an echo names no repository"

echo "merge-target: a pull request given as a link (#470)"

# gh accepts the pull request as a URL, and takes BOTH the repository and the number from it.
# Measured 2026-09-19: gh pr view https://github.com/cli/cli/pull/1 --repo danwright32/claude-config
# answered about cli/cli#1, so the link wins over the flag rather than the other way round. A gate
# reading only a bare number saw neither, asked gh about the session's folder and refused a pull
# request that was there all along (claude-config#470).
eq "$(mt_pr_number "$MERGE https://github.com/danwright32/backstage/pull/26 --squash")" "26" "a link names its number"
eq "$(mt_repo_flag "$MERGE https://github.com/danwright32/backstage/pull/26 --squash")" "danwright32/backstage" "a link names its repository"
# A link copied from a pull request's own tabs carries a path after the number.
eq "$(mt_pr_number "$MERGE https://github.com/danwright32/backstage/pull/26/files")" "26" "a link with a trailing path names its number"
eq "$(mt_repo_flag "$MERGE https://github.com/danwright32/backstage/pull/26/files")" "danwright32/backstage" "a link with a trailing path names its repository"
eq "$(mt_pr_number "$MERGE https://github.com/danwright32/backstage/pull/26/")" "26" "a trailing slash names its number"
# The link wins over a --repo beside it, because that is what gh does with the two together.
eq "$(mt_repo_flag "$MERGE https://github.com/danwright32/backstage/pull/26 --repo someone/else")" "danwright32/backstage" "a link beats a --repo beside it"
# And a link is still a command, not a payload: one quoted inside an echo names nothing.
eq "$(mt_pr_number "echo \"$MERGE https://github.com/a/b/pull/9\"")" "" "a link quoted inside an echo names no number"
eq "$(mt_repo_flag "echo \"$MERGE https://github.com/a/b/pull/9\"")" "" "a link quoted inside an echo names no repository"
# A host other than github.com is kept whole, so it can never compare equal to a github remote.
eq "$(mt_repo_flag "$MERGE https://git.example.com/a/b/pull/9")" "git.example.com/a/b" "another host is kept whole"

echo "merge-target: where a gate looked for the pull request (#470)"

# One vocabulary for every gate that has to say where it looked, so a pull request looked for in
# the wrong repository reads the same whichever gate reports it (L11, L605). block-red-merge.sh
# wrote these sentences inline; a second gate needing them is a second copy that drifts (L613).
eq "$(mt_searched_repo "other/repo" "acme/widget" "/tmp/x")" "other/repo" "the command's own repository is what was searched"
eq "$(mt_searched_repo "" "acme/widget" "/tmp/x")" "acme/widget" "with no repository named, the directory's"
eq "$(mt_searched_repo "" "" "/tmp/x")" "the repository gh resolves from /tmp/x" "with neither, gh's own resolution"
if [ -n "$(mt_searched_why "other/repo" "acme/widget" "/tmp/x")" ]; then pass; else
  fail "the reason the named repository was searched is empty"; fi
case "$(mt_searched_why "" "acme/widget" "/tmp/x")" in
  *"/tmp/x"*) pass ;;
  *) fail "the reason the directory's repository was searched does not name the directory" ;;
esac
eq "$(mt_pr_label "26")" "pull request #26" "a numbered pull request"
eq "$(mt_pr_label "")" "pull request for the current branch" "no number named"

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
