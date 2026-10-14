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

# The interpreter held in a SHELL VARIABLE (claude-config#584). PostRoll resolves its python
# into $PY and runs `$PY tools/wait_for_checks.py N --merge`; the first token was then `$PY`,
# no known interpreter, and #1416, #1418 and #1421 merged before their lessons reviews finished.
# A variable in command position is read as an interpreter, whichever way it is spelled.
for w in 'PY=$(. ./venv-python.sh; printf %s "$POSTROLL_PYTHON"); $PY tools/wait_for_checks.py 1421 --merge' \
         '$PY tools/wait_for_checks.py 7 --merge' \
         '${PY} tools/wait_for_checks.py 7 --merge' \
         '"$PY" tools/wait_for_checks.py 7 --merge' \
         '"${POSTROLL_PYTHON}" tools/wait_for_checks.py 7 --merge' \
         '$SHELL scripts/merge-when-green.sh 7'; do
  if mt_runs_merge "$w"; then pass; else fail "a merge run by an interpreter in a variable was not read as a merge: $w"; fi
done
eq "$(mt_pr_number 'PY=$(. ./venv-python.sh; printf %s "$POSTROLL_PYTHON"); $PY tools/wait_for_checks.py 1421 --merge')" \
  "1421" "the variable spelling names its pull request"
# A leading assignment whose value holds a space, a command substitution or a quoted string, is ONE
# word to the shell. Cut at its first space, `GH_TOKEN=$(gh auth token -u x) gh pr merge 7` left
# `auth token -u x) gh pr merge 7`, which merges nothing by its first word, so every merge gate
# stood down on the form a session uses to merge as one of Dan's accounts (found by the lessons
# review of #795).
for w in 'GH_TOKEN=$(gh auth token -u danwright32) gh pr merge 7 --squash' \
         'MSG="two words" gh pr merge 7 --squash' \
         "NOTE='a b c' gh pr merge 7" \
         'A=1 GH_TOKEN=$(gh auth token -u x) B="c d" gh pr merge 7' \
         'MSG="a \" b" gh pr merge 7' \
         'A=a\ b gh pr merge 7' \
         'GH_TOKEN=`gh auth token -u x` gh pr merge 7' \
         'X=${Y:-a b} gh pr merge 7'; do
  if mt_runs_merge "$w"; then pass; else fail "a merge after an assignment holding a space was not read as a merge: $w"; fi
done
mt_split_assignments 'PR_REVIEW_READ="ab12" GH_TOKEN=$(gh auth token -u x) gh pr merge 7'
eq "$MT_REST" "gh pr merge 7" "the command after assignments holding spaces"
eq "${MT_ASSIGNS%%$'\n'*}" "PR_REVIEW_READ=ab12" "an assignment's value with its quotes removed"
mt_split_assignments 'GH_TOKEN=`gh auth token -u x` X=${Y:-a b} gh pr merge 7'
eq "$MT_ASSIGNS" 'GH_TOKEN=`gh auth token -u x`'$'\n''X=${Y:-a b}'$'\n' "backtick and brace values kept as the shell sees them"
eq "$MT_REST" 'gh pr merge 7' "the merge after them"
# Nesting the shell allows: a substitution inside double quotes holding its own quotes and a
# space, and quotes inside a substitution inside quotes (lessons review of #795).
for w in 'X="$(a "b c")" gh pr merge 7' \
         'X="${Y:-"a b"}" gh pr merge 7' \
         "X=\"\$(printf '%s' 'p q')\" gh pr merge 7"; do
  if mt_runs_merge "$w"; then pass; else fail "a merge after a nested quoted assignment was not read as a merge: $w"; fi
done
mt_split_assignments 'X="$(a "b c")" gh pr merge 7'
eq "$MT_ASSIGNS" 'X=$(a "b c")'$'\n' "a nested value kept as the shell sees it, outer quotes removed"
eq "$MT_REST" 'gh pr merge 7' "and the merge after it"
# A separator INSIDE a substitution or quotes does not end the command (lessons review of #795):
# cut there, `GH_TOKEN=$(gh auth token -u x; true) gh pr merge 7` was two halves, neither a merge.
for w in 'GH_TOKEN=$(gh auth token -u x; true) gh pr merge 7' \
         'GH_TOKEN=$(gh auth token -u x || echo y) gh pr merge 7' \
         'MSG="a; b && c" gh pr merge 7'; do
  if mt_runs_merge "$w"; then pass; else fail "a merge after an assignment holding a separator was not read as a merge: $w"; fi
done
eq "$(mt_pr_number 'GH_TOKEN=$(gh auth token -u x; true) gh pr merge 7')" "7" "and it names its pull request"
# Parentheses that are not a substitution never hold the cut open: arithmetic, a stray or quoted
# bracket, a subshell inside a substitution, and a case pattern all leave the merge after && seen.
for w in 'echo $((1+2)) && gh pr merge 7' 'echo ) && gh pr merge 7' 'echo "(" && gh pr merge 7' \
         'x=$( (cd a; ls) ) && gh pr merge 7' 'case a in a) true ;; esac && gh pr merge 7' \
         "echo don't; gh pr merge 7" 'echo "unclosed && gh pr merge 7'; do
  if mt_runs_merge "$w"; then pass; else fail "a merge after a parenthesis that is not a substitution was not seen: $w"; fi
done
if mt_runs_merge 'echo "done; gh pr merge 7"'; then fail "a merge quoted after a separator inside an echo was read as a merge"; else pass; fi
# lib/shell-words.py, the reader behind the two functions above, directly: the reading both libraries
# share (#1040), the assignment split, and a refusal by exit code for anything else, so a typo in a
# caller is a failure, not an empty answer.
SW="$HOOK_DIR/lib/shell-words.py"
sw_texts() { python3 "$SW" read | tr '\036' '\n' | awk -F '\034' 'NF { print $2 }'; }
eq "$(printf '%s' 'a; b && c || d' | sw_texts)" "a"$'\n'" b "$'\n'" c "$'\n'" d" "shell-words cuts at each separator outside quotes"
eq "$(printf '%s' 'echo "a; b" && c' | sw_texts)" 'echo "a; b" '$'\n'' c' "and not inside them"
eq "$(printf '%s' 'A="x y" B=$(p q) cmd arg' | python3 "$SW" split)" "A=x y"$'\n'"B=\$(p q)"$'\n'$'\x1f'$'\n'"cmd arg" "shell-words splits leading assignments from the command"
printf 'x' | python3 "$SW" nonsense >/dev/null 2>&1; eq "$?" "64" "shell-words refuses an unknown mode"
# A reader that CRASHES must fall back to the plain reading, never answer "no merge" (L42, L490).
BROKEN_SW="$(mktemp "${TMPDIR:-/tmp}/broken-sw.XXXXXX")"
printf 'import sys\nsys.exit(3)\n' > "$BROKEN_SW"
# Both readers: the assignment split (MT_SHELL_WORDS) and the command reading the push library owns
# (PS_SHELL_WORDS, #1040). A reader that exits 3, the code that means "crude records follow", with no
# records at all must not read as a command running nothing.
saved_sw="$MT_SHELL_WORDS"; saved_ps="$PS_SHELL_WORDS"; MT_SHELL_WORDS="$BROKEN_SW"; PS_SHELL_WORDS="$BROKEN_SW"
if mt_runs_merge 'GH_TOKEN=x gh pr merge 7'; then pass; else fail "a crashed reader hid a merge after an assignment"; fi
if mt_runs_merge 'echo a; gh pr merge 7'; then pass; else fail "a crashed reader hid a merge after a separator"; fi
if ps_is_git_push 'echo a; git push'; then pass; else fail "a crashed reader hid a push after a separator"; fi
MT_SHELL_WORDS="$saved_sw"; PS_SHELL_WORDS="$saved_ps"; rm -f "$BROKEN_SW"
# rtk in front is the same merge, and its number and repository are read (lessons review of #795).
eq "$(mt_pr_number 'rtk gh pr merge 7 --repo a/b')" "7" "an rtk merge names its pull request"
eq "$(mt_repo_flag 'rtk gh pr merge 7 --repo a/b')" "a/b" "and its repository"
# The shell reading runs on every command that mentions a merge, so its cost must not grow faster
# than the text: the bash scan it replaced grew with the SQUARE of it, 13 s at 13 KB and 52 s at
# 26 KB (measured 2026-10-05), past every hook's timeout. Judged against a yardstick from this
# same run, never a fixed number of seconds (L224): doubling the text may at most roughly double
# the time, and the slack covers python's start up, which dominates both readings when linear.
now_s(){ python3 -c 'import time; print("%.3f" % time.time())'; }
half="$(python3 -c 'q = chr(92) + chr(34); print(("we should merge the " + q + "branch" + q + " after review; ") * 300)')"
big="$half$half"
[ "${#big}" -gt 25000 ] && pass || fail "the 26 KB fixture was not built (${#big} bytes)"
t0="$(now_s)"
mt_runs_merge "gh issue comment 5 --body \"$half\"" && fail "an issue body about a merge was read as a merge" || pass
t1="$(now_s)"
mt_runs_merge "gh issue comment 5 --body \"$big\"" && fail "an issue body about a merge was read as a merge" || pass
t2="$(now_s)"
if python3 -c 'import sys; a, b, c = map(float, sys.argv[1:]); sys.exit(0 if (c - b) <= 3 * (b - a) + 1.0 else 1)' "$t0" "$t1" "$t2"; then pass
else fail "reading grows faster than the text: 13 KB took $(python3 -c "print(round($t1 - $t0, 2))") s, 26 KB took $(python3 -c "print(round($t2 - $t1, 2))") s"; fi
mt_split_assignments 'echo "GH_TOKEN=x gh pr merge 7"'
eq "$MT_REST" 'echo "GH_TOKEN=x gh pr merge 7"' "a command with no leading assignment is left whole"
# The variable spelling still needs the flag: without --merge it only waits.
if mt_runs_merge '$PY tools/wait_for_checks.py 7'; then
  fail "the tool merely waiting for checks, run by a variable, was read as a merge"
else pass; fi
# And a variable naming something that is not a merge tool is not a merge.
if mt_runs_merge '$PY tools/merge_report.py 7 --merge'; then
  fail "an unrelated script run by a variable was read as a merge"
else pass; fi

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
# The cd that decides is the last one before the MERGE, on any line, in the merge's own shell
# (claude-config#1017): a merge hook reads the command as typed, newlines and all, and the reader
# saw a cd on the first line only.
eq "$(mt_repo_dir $'echo checking\ncd '"$root/plain"$'\n'"$MERGE 7" "$root/deep/a/b")" "$root/plain" "a cd on a later line decides"
eq "$(mt_repo_dir $'cat > /dev/null <<\'EOF\'\nit\'s a note\nEOF\ncd '"$root/plain && $MERGE 7" "$root/deep/a/b")" "$root/plain" "a cd after a heredoc with an apostrophe decides"
eq "$(mt_repo_dir "cd $root/deep && git status; cd $root/plain && $MERGE 7" "$root/parent")" "$root/plain" "of two cds the last before the merge decides"
eq "$(mt_repo_dir "cd $root/plain && $MERGE 7 && cd $root/deep" "$root/parent")" "$root/plain" "a cd after the merge does not decide"
eq "$(mt_repo_dir "(cd $root/deep && git status); $MERGE 7" "$root/plain")" "$root/plain" "a cd in a subshell closed before the merge does not decide"

echo "merge-target: a command merging more than one pull request (#1062)"

# Every merge gate judges one pull request per command, the first, so the second merge in
# `cd A && gh pr merge 1; cd B && gh pr merge 2` landed unjudged. mt_merge_span_why says when a
# command's merges are aimed at more than one target, in the sentence every gate refuses with.
span() {  # $1 = command, $2 = session cwd, $3 = what
  local why
  if why="$(mt_merge_span_why "$1" "$2")" && [[ "$why" == *"more than one pull request"* ]]; then pass
  else fail "$3 (said [$why])"; fi
}
nospan() {  # $1 = command, $2 = session cwd, $3 = what
  local why
  if why="$(mt_merge_span_why "$1" "$2")"; then fail "$3 (said [$why])"
  else pass; fi
}
span "cd $root/plain && $MERGE 7; cd $root/deep && $MERGE 8" "$root/parent" "two merges in two repositories"
span "cd $root/plain && $MERGE 7 && (cd $root/deep && $MERGE 7)" "$root/parent" "the same number in two repositories is two pull requests"
span "$MERGE 7 --repo acme/one; $MERGE 7 --repo acme/two" "$root/plain" "two repositories named with --repo"
span "$MERGE 7 --squash; $MERGE 8 --squash" "$root/plain" "two pull requests in one repository"
span "cd $root/plain && ./scripts/merge-when-green.sh 7; cd $root/deep && $MERGE 8" "$root/parent" "a repo's own merge tool beside a direct merge elsewhere"
why="$(mt_merge_span_why "cd $root/plain && $MERGE 7; cd $root/deep && $MERGE 8" "$root/parent")"
if [[ "$why" == *"#7 in $root/plain"* && "$why" == *"#8 in $root/deep"* ]]; then pass
else fail "the sentence names each pull request and where (said [$why])"; fi
eq "$(mt_merge_targets "$MERGE 7 --repo acme/one; $MERGE 8 --repo acme/two; $MERGE 7 --repo acme/one --admin" "$root/plain")" \
  "acme/one"$'\t'"acme/one"$'\t'"7"$'\n'"acme/two"$'\t'"acme/two"$'\t'"8" \
  "mt_merge_targets names each distinct target's repository once, for a gate that applies to some"
eq "$(mt_merge_targets "$MERGE 7" "$root/plain")" "" "mt_merge_targets of one merge is nothing to compare"
# One pull request named two ways, by --repo and by the checkout it runs in, is ONE target: told
# apart by the repository GitHub names, not by how the command spelled it (lessons review of #1072).
gitrepo="$root/widget-checkout"
git init -q "$gitrepo" && git -C "$gitrepo" remote add origin https://github.com/acme/widget.git
nospan "$MERGE 7 --repo acme/widget; cd $gitrepo && $MERGE 7" "$root/plain" \
  "control: one pull request named by --repo and by a checkout of its repository is one target"
span "$MERGE 7 --repo acme/widget; cd $gitrepo && $MERGE 8" "$root/plain" \
  "and a different number in that checkout is a second pull request"
# With nothing to read the command (no lib/shell-words.py beside the library), the targets cannot be
# told, so a command whose plain cut shows two merges is refused by name rather than read as one
# merge (lessons review of #1072, L490): the wrapper route has no other reader check in front of it.
LONE_MT="$root/lone-mt"; mkdir -p "$LONE_MT"
cp "$HOOK_DIR/lib/merge-target.sh" "$HOOK_DIR/lib/push-scope.sh" "$LONE_MT/"
lone_why="$(bash -c '. "$1/merge-target.sh"; mt_merge_span_why "$2" "$3"' _ "$LONE_MT" \
  "cd $root/plain && ./scripts/merge-when-green.sh 7; cd $root/deep && ./scripts/merge-when-green.sh 8" "$root/parent")"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$lone_why" == *"shell-words.py"* ]]; then pass
else fail "with no reader, two wrapper merges are refused by name, not read as one (rc=$rc said [$lone_why])"; fi
lone_why="$(bash -c '. "$1/merge-target.sh"; mt_merge_span_why "$2" "$3"' _ "$LONE_MT" \
  "cd $root/plain && ./scripts/merge-when-green.sh 7" "$root/parent")"; rc=$?
if [ "$rc" -ne 0 ]; then pass; else fail "control: with no reader, one wrapper merge is not refused (said [$lone_why])"; fi
# A merge whose pull request number cannot be read is its own target, never folded into another merge
# of the same repository (merge time lessons review of #1072): two wrapper merges naming no number,
# or none readable, are two merges nobody can show are the same.
span "./scripts/merge-when-green.sh 7; ./scripts/merge-when-green.sh 8" "$root/plain" \
  "two merges through a repo's merge tool in one repository, numbers 7 and 8"
span "./scripts/merge-when-green.sh; ./scripts/merge-when-green.sh --timeout 900" "$root/plain" \
  "two merges through a repo's merge tool naming no number are two targets"
span "$MERGE --squash; ./scripts/merge-when-green.sh" "$root/plain" \
  "a direct merge and a merge tool, neither naming a number, are two targets"
nospan "./scripts/merge-when-green.sh 7 || ./scripts/merge-when-green.sh 7" "$root/plain" \
  "control: the merge tool repeated for the same readable number is one target"
nospan "cd $root/plain && $MERGE 7" "$root/parent" "control: one merge is one target"
nospan "$MERGE 7 --squash || $MERGE 7 --squash --admin" "$root/plain" "control: the same pull request twice is one target"
nospan "cd $root/plain && $MERGE 7; cd $root/plain && $MERGE 7 --admin" "$root/parent" "control: the same pull request from the same directory twice is one target"
nospan "echo \"cd $root/deep && $MERGE 8\"; $MERGE 7" "$root/plain" "control: a merge quoted in an echo is not a second merge"

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

echo "merge-target: the reader those two answers need (#475)"

# mt__merge_selector reads the merge's own arguments with python3, where mt_pr_number used to fall
# back to grep. On a machine with no python3 the number and the repository BOTH come back empty,
# and every gate then refuses while describing a pull request it could not find rather than a
# reader that is not installed: two causes with one message, and the remedy it names cannot clear
# it (L11, claude-config#475).
#
# The tools the library needs are linked into a bare directory, so nothing else on this machine's
# PATH can answer for python3. Same shape as the no claude case in test-ai-review-on-push.sh.
nopy_root=$(mktemp -d)
NOPY="$nopy_root/bin"; mkdir -p "$NOPY"
for t in bash sh git grep sed awk tr cat cut head dirname basename env uname mkdir mv rm; do
  p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -s "$p" "$NOPY/$t" 2>/dev/null
done
# The fixture's own premise, asserted rather than assumed: a bare directory that still reaches a
# python3 would make every case below pass for the wrong reason (L159).
if PATH="$NOPY" "$NOPY/bash" -c 'command -v python3 >/dev/null 2>&1'; then
  fail "the bare directory still reaches a python3, so nothing here measures its absence"
else pass; fi

nopy() {  # $1 = a library function, $2.. = its arguments, run with no python3 on PATH
  PATH="$NOPY" "$NOPY/bash" -c '. "$1"; shift; "$@"' _ "$HOOK_DIR/lib/merge-target.sh" "$@" 2>&1
}

# The fault itself, stated rather than reasoned about: without python3 the shared reader answers
# nothing at all, so a named pull request and a named repository are both invisible.
eq "$(nopy mt__merge_selector "$MERGE 26 --repo danwright32/backstage --squash")" "" \
  "with no python3 the shared reader answers nothing"
eq "$(nopy mt_pr_number "$MERGE 26 --squash")" "" "so the number the command names is invisible"
eq "$(nopy mt_repo_flag "$MERGE 26 --repo danwright32/backstage --squash")" "" \
  "and so is the repository it names"

# Which is why the gates ask this, and say it by name.
if nopy mt_reader_missing >/dev/null 2>&1; then pass; else
  fail "with no python3 on PATH the library does not report its reader as missing"; fi
if mt_reader_missing; then
  fail "python3 is on PATH in this suite and the library still reports its reader as missing"
else pass; fi
# The cd in force for the merge is read by lib/shell-words.py (#1017). With python3 present but that
# file gone, ps_cd_target answers nothing and mt_repo_dir would judge the merge in the session
# directory, so the reader counts as missing then too (lessons review of #1056, L490).
if ( PS_SHELL_WORDS="$nopy_root/no-such-shell-words.py"; mt_reader_missing ); then pass; else
  fail "with lib/shell-words.py missing the library does not report its reader as missing"; fi
case "$( PS_SHELL_WORDS="$nopy_root/no-such-shell-words.py"; mt_reader_absent_why )" in
  *shell-words.py*) pass ;;
  *) fail "the sentence about an absent shell-words.py does not name it" ;;
esac

# The sentence every gate says it with, one vocabulary rather than one wording per gate (L613).
# It has to NAME the interpreter, or it is the message this issue exists to replace.
reader_why="$(mt_reader_absent_why)"
case "$reader_why" in
  *python3*) pass ;;
  *) fail "the sentence about the absent reader does not name it: $reader_why" ;;
esac
# And name a remedy that changes the state somebody is stuck in (L111): installing the reader,
# never naming a repository, which was never the fault here.
case "$reader_why" in
  *"on PATH"*) pass ;;
  *) fail "the sentence about the absent reader names no remedy: $reader_why" ;;
esac

# A wrapper route reads its number with the SHELL, so python3's absence changes nothing there and
# no gate has cause to refuse it. Without this the refusal above would be about a reader that run
# never needed (L324).
eq "$(nopy mt_pr_number "npm run merge -- 680")" "680" "a wrapper still names its number with no python3"
if nopy mt_is_pr_merge "npm run merge -- 680"; then
  fail "a wrapper route was read as the direct merge, which is what the refusal keys on"
else pass; fi

echo "merge-target: a merge through the GitHub API (claude-config#1181)"

# THE SHARED TABLE. The overnight judge in the scope-modes mod and these gates are two recognisers of
# one question, in two languages, so they share a table rather than code: every row is held here to
# the gates' answer (`gates` where the two differ on purpose, else `merge`), and mergedeploy.test.ts
# holds the mod to `merge` on the same rows. A route one of them learns and the other does not fails
# a suite (L450). Each row is one line of JSON inside the TypeScript file.
NO_GH="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "no gh in this case" >&2\nexit 1\n' > "$NO_GH/gh"; chmod +x "$NO_GH/gh"
API_CASES="$HOOK_DIR/../mods/scope-modes/tests/api-merge-cases.ts"
api_rows="$(python3 - "$API_CASES" <<'PY' 2>&1
import json, re, sys
for line in open(sys.argv[1]):
    s = line.strip()
    if not s.startswith('{"command"'):
        continue
    row = json.loads(s.rstrip(","))
    want = row.get("gates", row["merge"])
    # The repository the row says the merge is about (#1186): "-" for a row naming none, "!" for one
    # that cannot be told, which every gate must refuse, else owner/name.
    repo = "-" if "repo" not in row else ("!" if row["repo"] is None else row["repo"])
    print(("yes" if want else "no") + "\x1f" + repo + "\x1f" + row["command"])
PY
)"
n_rows="$(printf '%s\n' "$api_rows" | grep -c $'\x1f')"
# The control: a table that read as empty would agree with any recogniser at all (L98).
if [ "$n_rows" -ge 20 ]; then pass; else fail "#1181 the shared table read as $n_rows rows from $API_CASES: $api_rows"; fi
while IFS= read -r row; do
  [ -n "$row" ] || continue
  want="${row%%$'\x1f'*}"; row="${row#*$'\x1f'}"; want_repo="${row%%$'\x1f'*}"; c="${row#*$'\x1f'}"
  # No gh reaches GitHub from here: a GraphQL row's node is never resolved by a question of merge or not.
  got=no; PATH="$NO_GH:$PATH" mt_runs_merge "$c" </dev/null && got=yes
  eq "$got" "$want" "#1181 the gates' recogniser on the shared table row: $c"
  # Every route in the table is a DIRECT merge, so the blocking gates' question answers the same.
  got=no; PATH="$NO_GH:$PATH" mt_is_pr_merge "$c" </dev/null && got=yes
  eq "$got" "$want" "#1181 the direct merge question on the shared table row: $c"
  # The repository the merge is about, where the row names one (#1186): the one the gates read, or a
  # refusal for one that cannot be told, never the checkout's pull request read in its place (L75).
  case "$want_repo" in
    -) ;;
    !)
      got=judged; PATH="$NO_GH:$PATH" mt_api_merge_untold "$c" </dev/null && got=refused
      eq "$got" "refused" "#1186 a merge naming a repository that cannot be told is refused: $c" ;;
    *)
      got=refused; PATH="$NO_GH:$PATH" mt_api_merge_untold "$c" </dev/null || got=judged
      eq "$got" "judged" "#1186 a merge naming its repository is judged, not refused: $c"
      got="$(PATH="$NO_GH:$PATH" mt_repo_flag "$c" </dev/null | tr '[:upper:]' '[:lower:]')"
      eq "$got" "$want_repo" "#1186 the repository the gates read on the shared table row: $c" ;;
  esac
done <<< "$api_rows"

# rtk in front, which rtk-rewrite.sh writes in front of every gh command, is the same merge here (the
# table leaves wrappers out; its header says why).
if mt_is_pr_merge "rtk gh api -X PUT repos/acme/widget/pulls/7/merge"; then pass; else fail "#1181 rtk in front hid a REST merge"; fi

# gh's flags written in front of the subcommand (#1186): gh hands them to the subcommand, so the
# number, the repository and the pin are read from there as from anywhere else in the merge.
eq "$(mt_pr_number "gh -R acme/widget pr merge 9 --squash")" "9" "#1186 the number of a merge with -R in front"
eq "$(mt_pr_number "gh -R acme/widget pr -R acme/widget merge 9")" "9" "#1186 and with -R between pr and merge"
eq "$(mt_repo_flag "gh --repo acme/widget pr merge https://github.com/acme/other/pull/4")" "acme/other" "#1186 a link still wins over a repository flag in front"
eq "$(mt_pr_number "gh --repo acme/widget pr merge https://github.com/acme/other/pull/4")" "4" "#1186 and names the number"
mt_api_merge_untold "gh -R acme/widget pr merge 9 --match-head-commit abc123" || :
eq "$MT_API_PIN" "abc123" "#1186 the pin of a merge with -R in front"
mt_api_merge_untold "gh --match-head-commit=abc123 pr merge 9" || :
eq "$MT_API_PIN" "abc123" "#1186 a pin written in front of the subcommand pins the merge too"
# gh takes the LAST repository flag it is given (measured on gh 2.89.0: `-R a -R b` reads b, and so
# does `-R b` after the action with `-R a` in front), so the gates read the last one too.
eq "$(mt_repo_flag "gh pr merge 7 -R acme/other -R acme/widget")" "acme/widget" "#1186 the last repository flag is the one gh reads"
# A repository flag in front of `api` that names its own host keeps that host once, never with
# --hostname's added again in front of it (lessons review of #1186).
eq "$(mt_repo_flag "gh -R ghe.example.com/o/r api --hostname ghe.example.com -X PUT 'repos/{owner}/{repo}/pulls/7/merge'")" "ghe.example.com/o/r" "#1186 a host the repository flag names is not doubled by --hostname"
eq "$(mt_repo_flag "gh -R o/r api --hostname ghe.example.com -X PUT 'repos/{owner}/{repo}/pulls/7/merge'")" "ghe.example.com/o/r" "#1186 and --hostname still names the host of an owner/name flag"
# Short flags clustered as gh reads them (pflag): the one taking a value takes the rest of the word or
# the next word, so a body is never the number and a repository in a cluster is still read.
eq "$(mt_pr_number "gh pr merge -sb 42")" "" "#1186 a body given in a cluster is not the pull request"
eq "$(mt_repo_flag "gh pr merge 7 -dsR acme/widget")" "acme/widget" "#1186 a repository given in a cluster is read"
# An empty repository flag is no repository to gh, which then reads the checkout's (measured on gh
# 2.89.0: `gh --repo= pr view 1184` answered for the folder's repository), so it is judged as one with none.
eq "$(mt_repo_flag "gh --repo= pr merge 7")" "" "#1186 an empty repository flag names none, as gh reads it"
if mt_api_merge_untold "gh -R '' pr merge 7"; then fail "#1186 an empty repository flag, which gh reads as none, was refused: $MT_API_WHY"; else pass; fi

# THE FAILURE PATH (#1186): a repository flag gh cannot read as [HOST/]OWNER/REPO, or one with no
# value at all, is refused with a sentence naming it, never judged as the checkout's pull request.
# gh itself refuses such a command (`expected the "[HOST/]OWNER/REPO" format, got "nonsense"`), so
# the refusal stops nothing that could have merged.
if mt_api_merge_untold "gh -R nonsense pr merge 7"; then
  case "$MT_API_WHY" in
    *'"nonsense"'*"owner/name"*) pass ;;
    *) fail "#1186 the refusal of an unreadable repository flag does not name it and say what gh takes: $MT_API_WHY" ;;
  esac
else fail "#1186 a merge naming the repository nonsense was judged as some pull request"; fi
eq "$(mt_repo_flag "gh -R nonsense pr merge 7")" "" "#1186 and names no repository a gate could ask about"
eq "$MT_API_ROUTE" "untold" "#1186 its route is one that cannot be told"
for c in "gh -R acme/widget/ pr merge 7" "gh -R a//b pr merge 7" "gh pr merge 7 --repo"; do
  if mt_api_merge_untold "$c"; then pass; else fail "#1186 an unreadable repository flag was judged [$c]"; fi
done
if mt_api_merge_untold "gh pr merge 7 --squash -R"; then
  case "$MT_API_WHY" in *"no value"*) pass ;; *) fail "#1186 a repository flag with no value was refused without saying so: $MT_API_WHY" ;; esac
else fail "#1186 a repository flag with no value was judged"; fi
# A spelling gh reads as an address is left to gh, as before: refusing it would stop a real merge.
if mt_api_merge_untold "gh -R https://github.com/acme/widget pr merge 7"; then fail "#1186 an address gh reads was refused: $MT_API_WHY"; else pass; fi

# The reading behind the table's wrapper rows (lib/shell-words.py past_runners): each runner's options
# and settings are passed over, and env -S, whose command is a string split at run time, is left as
# a command named env rather than guessed at.
eq "$(mt_command_segments 'env -i -u GH_HOST -C /tmp GH_TOKEN="a b" gh pr merge 7')" "gh pr merge 7" "#1181 env's options and settings are passed over"
eq "$(mt_command_segments 'sudo --user=dan -g staff -- gh pr merge 7')" "gh pr merge 7" "#1181 sudo's options are passed over"
eq "$(mt_command_segments 'env -S "gh pr merge 7"')" 'env -S "gh pr merge 7"' "#1181 env -S is left as it stands"
eq "$(mt_command_segments 'sudo')" "sudo" "#1181 a runner with nothing after it is itself"
# A setting env gives the merge is the merge's own, so the lessons review's read key can ride on it.
eq "$(mt_presented_read_key 'env PR_REVIEW_READ=ab12 gh pr merge 7' mt_runs_merge)" "ab12" "#1181 a read key env sets is presented by the merge"
eq "$(mt_pr_number "sudo env GH_TOKEN=x rtk gh pr merge 9 --match-head-commit abc")" "9" "#1181 and the number behind every runner is read"

# WHICH pull request a REST merge names, and in which repository: its endpoint's, in every spelling.
eq "$(mt_pr_number "gh api -X PUT repos/acme/widget/pulls/7/merge")" "7" "#1181 a REST merge names its number"
eq "$(mt_repo_flag "gh api -X PUT repos/acme/widget/pulls/7/merge")" "acme/widget" "#1181 and its repository"
eq "$(mt_repo_flag "gh api --method=PUT https://api.github.com/repos/acme/widget/pulls/7/merge")" "acme/widget" "#1181 a full address names the same repository"
eq "$(mt_pr_number "gh api -X put /repos/acme/widget/pulls/12/merge -f merge_method=squash")" "12" "#1181 a leading slash and a lower case method"
# gh's own placeholders name the directory's repository, which gh fills in: none is named here, so
# the gates read the checkout's, as they do for a gh pr merge with no --repo.
eq "$(mt_repo_flag "gh api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'")" "" "#1181 placeholders name no repository of their own"
eq "$(mt_pr_number "gh api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'")" "7" "#1181 and still name the number"
# A read of the same pull request BEFORE the merge is never taken for it (L75).
eq "$(mt_pr_number "gh api repos/acme/other/pulls/9 --jq .mergeable && $MERGE 7 --repo acme/widget")" "7" "#1181 a gh api read before a merge is not the merge"
eq "$(mt_repo_flag "gh api repos/acme/other/pulls/9 --jq .mergeable && $MERGE 7 --repo acme/widget")" "acme/widget" "#1181 nor its repository"

# A GraphQL merge names a NODE, which GitHub resolves. A fake gh answers the lookup, logging each
# call, so the cases can say how often GitHub was asked.
NODE_DIR="$(mktemp -d)"
cat > "$NODE_DIR/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NODE_LOG"
case "$*" in
  "auth status"*) [ -n "${NODE_ACCOUNTS:-}" ] && for a in $NODE_ACCOUNTS; do printf '  Logged in to github.com account %s (keyring)\n' "$a"; done; exit 0 ;;
  "auth token"*) printf 'tok-%s\n' "$4"; exit 0 ;;
  "api graphql"*)
    if [ -n "${NODE_FAIL:-}" ]; then printf '%s\n' "$NODE_FAIL" >&2; exit 1; fi
    printf '%s\n' "${NODE_ANSWER:-}" ;;
esac
GH
chmod +x "$NODE_DIR/gh"
PR_NODE='{"data":{"node":{"__typename":"PullRequest","number":42,"repository":{"nameWithOwner":"acme/widget"}}}}'
GQL="gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\", expectedHeadOid: \"a1b2c3\"}) { clientMutationId } }'"
GQL_VAR="gh api graphql -f query='mutation(\$id: ID!, \$sha: GitObjectID) { mergePullRequest(input: {pullRequestId: \$id, expectedHeadOid: \$sha}) { clientMutationId } }' -f id=PR_kwDOA1 -f sha=d4e5f6"
node_q() {  # $1 = answer, $2 = failure, $3.. = a function and its arguments ; prints the function's output
  local a="$1" f="$2"; shift 2
  ( export PATH="$NODE_DIR:$PATH" NODE_LOG="$NODE_DIR/log" NODE_ANSWER="$a" NODE_FAIL="$f"; "$@" )
}
eq "$(node_q "$PR_NODE" "" mt_pr_number "$GQL")" "42" "#1181 a GraphQL merge's number is its node's, as GitHub says"
eq "$(node_q "$PR_NODE" "" mt_repo_flag "$GQL")" "acme/widget" "#1181 and so is its repository"
eq "$(node_q "$PR_NODE" "" mt_pr_number "$GQL_VAR")" "42" "#1181 a node passed as a -f variable is read too"
grep -q 'id=PR_kwDOA1' "$NODE_DIR/log" && pass || fail "#1181 the lookup did not ask about the node the mutation names: $(cat "$NODE_DIR/log")"

# mt_api_merge_untold: the question every gate asks before mt_pr_number. Each route, and the pin.
untold() {  # $1 = answer, $2 = failure, $3 = command ; prints "rc|route|pin|why"
  ( export PATH="$NODE_DIR:$PATH" NODE_LOG="$NODE_DIR/log" NODE_ANSWER="$1" NODE_FAIL="$2"
    mt_api_merge_untold "$3"; rc=$?; printf '%s|%s|%s|%s' "$rc" "$MT_API_ROUTE" "$MT_API_PIN" "$MT_API_WHY" )
}
eq "$(untold "" "" "gh api -X PUT repos/acme/widget/pulls/7/merge -f sha=a1b2c3")" "1|rest|a1b2c3|" "#1181 a REST merge is told, with the sha it pins"
eq "$(untold "$PR_NODE" "" "$GQL")" "1|graphql|a1b2c3|" "#1181 a GraphQL merge whose node resolves is told, with its expectedHeadOid"
eq "$(untold "$PR_NODE" "" "$GQL_VAR")" "1|graphql|d4e5f6|" "#1181 and a pin passed as a variable"
eq "$(untold "" "" "$MERGE 7 --squash")" "1|pr||" "#1181 gh pr merge is the direct route, never untold"
eq "$(untold "" "" "gh api repos/acme/widget/pulls/7/merge")" "1|||" "#1181 a GET of the merge endpoint is no merge"
eq "$(untold "" "" "ls")" "1|||" "#1181 nor is anything else"

# THE FAILURE PATHS: a merge whose pull request cannot be named is refused, never let through and
# never judged as the current branch's pull request (L75, L42).
got="$(untold "" "gh: Could not resolve to a node with the global id of 'PR_kwDOA1'" "$GQL")"
case "$got" in 0\|graphql\|*"PR_kwDOA1"*"no logged-in account can see"*) pass ;; *) fail "#1181 a node GitHub cannot resolve is not refused by name: $got" ;; esac
eq "$(node_q "" "gh: Could not resolve to a node with the global id of 'PR_kwDOA1'" mt_pr_number "$GQL")" "" "#1181 and names no number, so nothing reads the current branch's instead"
got="$(untold '{"data":{"node":{"__typename":"Issue"}}}' "" "$GQL")"
case "$got" in 0\|*"is a node of type Issue, not a pull request"*) pass ;; *) fail "#1181 a node that is an issue is not refused as one: $got" ;; esac
got="$(untold "" "error connecting to api.github.com" "$GQL")"
case "$got" in 0\|*"error connecting to api.github.com"*) pass ;; *) fail "#1181 a lookup that could not reach GitHub does not say what gh said: $got" ;; esac
# Asked as every logged-in account in turn, as mt_pr_view asks, and never with the shared one switched.
: > "$NODE_DIR/log"
( export PATH="$NODE_DIR:$PATH" NODE_LOG="$NODE_DIR/log" NODE_FAIL="gh: Could not resolve to a node with the global id of 'PR_kwDOA1'" NODE_ACCOUNTS="first second"; mt_api_merge_untold "$GQL" ) >/dev/null
eq "$(grep -c '^api graphql' "$NODE_DIR/log")" "3" "#1181 a node not found is asked of the active account and each other logged-in one"
if grep -q 'auth switch' "$NODE_DIR/log"; then fail "#1181 the lookup switched the shared gh account"; else pass; fi
got="$(untold "" "" "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \$id}) { clientMutationId } }'")"
case "$got" in 0\|untold\|*"pull request id it names cannot be read"*) pass ;; *) fail "#1181 a node id nothing passes is not refused: $got" ;; esac
got="$(untold "" "" "gh api graphql -f query='mutation { a: mergePullRequest(input: {pullRequestId: \"PR_1\"}) { clientMutationId } b: mergePullRequest(input: {pullRequestId: \"PR_2\"}) { clientMutationId } }'")"
case "$got" in 0\|untold\|*"more than one pull request"*) pass ;; *) fail "#1181 two merges in one mutation are not refused: $got" ;; esac
got="$(untold "" "" "gh api graphql -F query=@merge.graphql")"
case "$got" in 0\|untold\|*"@merge.graphql"*) pass ;; *) fail "#1181 a document read from a file is not refused by name: $got" ;; esac
got="$(untold "" "" "gh api -X PUT 'repos/{owner}/widget/pulls/7/merge'")"
case "$got" in 0\|untold\|*"repos/{owner}/widget/pulls/7/merge"*) pass ;; *) fail "#1181 an endpoint whose repository cannot be told is not refused: $got" ;; esac

# Resolved ONCE per gate: the gate asks mt_api_merge_untold in its own shell, and the number and the
# repository it reads afterwards, each in a subshell, take the remembered answer.
: > "$NODE_DIR/log"
got="$( export PATH="$NODE_DIR:$PATH" NODE_LOG="$NODE_DIR/log" NODE_ANSWER="$PR_NODE"
  mt_api_merge_untold "$GQL"; printf '%s|%s' "$(mt_pr_number "$GQL")" "$(mt_repo_flag "$GQL")" )"
eq "$got" "42|acme/widget" "#1181 the remembered answer is the one GitHub gave"
eq "$(grep -c '^api graphql' "$NODE_DIR/log")" "1" "#1181 one gate asks GitHub about the node once"
rm -rf "$NODE_DIR"

# With no python3, a gh api call naming a merge cannot be told from a read, so it is answered as a
# merge and every gate refuses by naming the reader, rather than letting it through as nothing (L490).
if nopy mt_is_pr_merge "gh api -X PUT repos/acme/widget/pulls/7/merge" >/dev/null; then pass; else
  fail "#1181 with no python3 an API merge read as no merge at all"; fi
if nopy mt_is_pr_merge "gh api repos/acme/widget/issues/7" >/dev/null; then
  fail "#1181 with no python3 a gh api call naming no merge was read as one"; else pass; fi
# And the reader is the selector file too: without it the merge's own words cannot be read.
if ( MT_SELECTOR="$nopy_root/no-such-selector.py"; mt_reader_missing ); then pass; else
  fail "#1181 with lib/merge-selector.py missing the library does not report its reader as missing"; fi
case "$( MT_SELECTOR="$nopy_root/no-such-selector.py"; mt_reader_absent_why )" in
  *merge-selector.py*) pass ;;
  *) fail "#1181 the sentence about an absent merge-selector.py does not name it" ;;
esac

# EVERY MERGE GATE asks it. A gate that judges a merge by mt_pr_number without asking first would judge
# an API merge it cannot name as the current branch's pull request, so each one is listed from the
# hooks block, not by hand (L96), and must call mt_api_merge_untold before its first mt_pr_number.
SETTINGS_FILE="$HOOK_DIR/../settings.hooks.json"
[ -f "$SETTINGS_FILE" ] || SETTINGS_FILE="$HOOK_DIR/../settings.json"
merge_gates="$(jq -r '.hooks.PreToolUse[]? | select((.matcher // "") | test("(^|[|])Bash($|[|])")) | .hooks[]? | .command' "$SETTINGS_FILE" 2>/dev/null \
  | sed 's#.*/##' | sort -u | while IFS= read -r h; do
      [ -f "$HOOK_DIR/$h" ] && grep -Eq 'mt_runs_merge|mt_is_pr_merge' "$HOOK_DIR/$h" && printf '%s\n' "$h"
    done)"
case "$merge_gates" in *block-red-merge.sh*) pass ;; *) fail "#1181 control: the hooks block lists no block-red-merge.sh as a merge gate: [$merge_gates]" ;; esac
while IFS= read -r h; do
  [ -n "$h" ] || continue
  ask="$(grep -n 'mt_api_merge_untold "\$command"' "$HOOK_DIR/$h" | awk -F: 'NR == 1 { print $1 }')"
  first="$(grep -n 'mt_pr_number "\$command"' "$HOOK_DIR/$h" | awk -F: 'NR == 1 { print $1 }')"
  if [ -n "$ask" ] && { [ -z "$first" ] || [ "$ask" -lt "$first" ]; }; then pass; else
    fail "#1181 $h judges a merge without asking mt_api_merge_untold before its first mt_pr_number"; fi
done <<< "$merge_gates"
# And none of them is registered behind an `if` filter: Claude Code then runs it only for commands the
# filter names, and `Bash(gh pr merge*)` kept block-red-merge.sh and the changelog gate from ever
# seeing an API merge, or the changelog gate a repo's own merge tool, whatever their recogniser said.
behind_if="$(jq -r '.hooks.PreToolUse[]? | select((.matcher // "") | test("(^|[|])Bash($|[|])")) | .hooks[]? | select(.if != null) | .command' "$SETTINGS_FILE" 2>/dev/null \
  | sed 's#.*/##' | sort -u)"
filtered=""
while IFS= read -r h; do
  [ -n "$h" ] || continue
  case $'\n'"$merge_gates"$'\n' in *$'\n'"$h"$'\n'*) filtered+="$h " ;; esac
done <<< "$behind_if"
eq "$filtered" "" "#1181 no merge gate is registered behind an if filter narrower than its recogniser"
rm -rf "$NO_GH"

rm -rf "$nopy_root"

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

echo "merge-target: mt_pr_view asks for the other accounts only when the active one cannot answer (claude-config#1014)"
# `gh auth status` checks every logged in account's token with a request each (3 on the personal
# MacBook, measured 2026-10-09), and merge-when-ready.sh reads the pull request every minute, so
# listing the accounts before the active one has even been tried spent them on every look.
ghstub="$(mktemp -d "${TMPDIR:-/tmp}/mt-ghstub.XXXXXX")"
cat > "$ghstub/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_TOKEN:-active}" "$*" >> "$MT_GH_LOG"
case "$*" in
  "auth status"*) printf 'Logged in to github.com account other1 (keyring)\n' ;;
  "auth token -u other1") printf 'tok-other1\n' ;;
  "pr view"*)
    if [ -z "${GH_TOKEN:-}" ] && [ -e "$MT_GH_ACTIVE_FAILS" ]; then echo "GraphQL: Could not resolve to a Repository with the name 'acme/widget'. (repository)" >&2; exit 1; fi
    printf '{"number":7,"state":"OPEN","url":"https://github.com/acme/widget/pull/7"}\n' ;;
  *) exit 3 ;;
esac
EOS
chmod +x "$ghstub/gh"
export MT_GH_LOG="$ghstub/log" MT_GH_ACTIVE_FAILS="$ghstub/active-fails"
: > "$MT_GH_LOG"
got="$(PATH="$ghstub:$PATH" mt_pr_view 7 "number,state,url" acme/widget acme/widget)"
eq "$(printf '%s' "$got" | jq -r '.found')" "true" "the active account's answer is used"
eq "$(grep -c 'pr view' "$MT_GH_LOG")" "1" "the stub gh was asked for the pull request once"
eq "$(grep -c 'auth status' "$MT_GH_LOG")" "0" "and the other accounts are never listed when the active one answers"
: > "$MT_GH_LOG"; : > "$MT_GH_ACTIVE_FAILS"
got="$(PATH="$ghstub:$PATH" mt_pr_view 7 "number,state,url" acme/widget acme/widget)"
eq "$(printf '%s' "$got" | jq -r '.found, .account' | tr '\n' ' ')" "true other1 " "when the active account cannot see it, another account's answer is used"
eq "$(grep -c 'auth status' "$MT_GH_LOG")" "1" "and the accounts are listed once, after the active one failed"
eq "$(grep -c '^tok-other1|pr view' "$MT_GH_LOG")" "1" "and the pull request is asked again with that account's token"
# Under set -u, as merge-when-ready.sh runs it, with no other account to try: a clean "not found",
# never a shell error about an empty list (L486).
cat > "$ghstub/gh-none" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  "auth status"*) exit 1 ;;
  *) echo "GraphQL: Could not resolve to a Repository with the name 'acme/widget'. (repository)" >&2; exit 1 ;;
esac
EOS
mkdir -p "$ghstub/none"; mv "$ghstub/gh-none" "$ghstub/none/gh"; chmod +x "$ghstub/none/gh"
got="$(set -u; PATH="$ghstub/none:$PATH" mt_pr_view 7 "number,state,url" acme/widget acme/widget 2>&1)"
eq "$(printf '%s' "$got" | jq -r '.found, .notFound' 2>/dev/null | tr '\n' ' ')" "false true " "under set -u with no other account, it answers not found rather than failing"
rm -rf "$ghstub"

echo "merge-target: mt_pr_view asks other accounts only when the answer can mean the repository is hidden (claude-config#1173)"
# "no pull requests found for branch" and "Could not resolve to a PullRequest" are answers GitHub
# can only give about a repository the account CAN see, so no other account can change them, and
# asking each one cost about 2 s per read (8 samples, 2026-10-13). "Could not resolve to a
# Repository" and a 404 are what a repository only another account can see looks like (measured
# 2026-08-30 on nursedexapp/nursedex), so those still go on to the other accounts. The active
# account's error text below is gh's own, captured from the real gh on 2026-10-13.
ghstub="$(mktemp -d "${TMPDIR:-/tmp}/mt-ghstub.XXXXXX")"
cat > "$ghstub/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_TOKEN:-active}" "$*" >> "$MT_GH_LOG"
case "$*" in
  "auth status"*) printf 'Logged in to github.com account other1 (keyring)\n' ;;
  "auth token -u other1") printf 'tok-other1\n' ;;
  "pr view"*)
    if [ -z "${GH_TOKEN:-}" ]; then cat "$MT_GH_ACTIVE_ERR" >&2; exit 1; fi
    if [ -s "$MT_GH_OTHER_ERR" ]; then cat "$MT_GH_OTHER_ERR" >&2; exit 1; fi
    printf '{"number":7,"state":"OPEN","url":"https://github.com/acme/widget/pull/7"}\n' ;;
  *) exit 3 ;;
esac
EOS
chmod +x "$ghstub/gh"
export MT_GH_LOG="$ghstub/log" MT_GH_ACTIVE_ERR="$ghstub/active-err" MT_GH_OTHER_ERR="$ghstub/other-err"
# One row per answer: the active account's error, then whether the other accounts are asked.
while IFS='|' read -r want_others active_err; do
  : > "$MT_GH_LOG"; : > "$MT_GH_OTHER_ERR"
  printf '%s\n' "$active_err" > "$MT_GH_ACTIVE_ERR"
  got="$(PATH="$ghstub:$PATH" mt_pr_view "" "number,state,url" acme/widget "")"
  asked="$(grep -c 'auth status' "$MT_GH_LOG")"
  if [ "$want_others" = final ]; then
    eq "$asked" "0" "[$active_err] is final: the other accounts are not listed"
    eq "$(grep -c '^tok-' "$MT_GH_LOG")" "0" "[$active_err] is final: no other account's token asks again"
    eq "$(printf '%s' "$got" | jq -r '[.found, .notFound, .error, .wrongRepo] | map(tostring) | join(" ")')" "false true  " "[$active_err] answers not found, with no error"
  else
    eq "$asked" "1" "[$active_err] can mean the repository is hidden: the other accounts are listed"
    eq "$(printf '%s' "$got" | jq -r '.found, .account' | tr '\n' ' ')" "true other1 " "[$active_err] and the account that can see it answers"
  fi
done <<'ROWS'
final|no pull requests found for branch "fix/1173-no-pr-yet"
final|GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)
others|GraphQL: Could not resolve to a Repository with the name 'acme/widget'. (repository)
others|gh: Not Found (HTTP 404)
others|Post "https://api.github.com/graphql": dial tcp: lookup api.github.com: no such host
ROWS
# Failure paths. The active account cannot see the repository and the other account's read fails in
# transit: not found must not be claimed, because nobody who could see the repository answered.
: > "$MT_GH_LOG"
printf '%s\n' "GraphQL: Could not resolve to a Repository with the name 'acme/widget'. (repository)" > "$MT_GH_ACTIVE_ERR"
printf '%s\n' 'Post "https://api.github.com/graphql": read: connection reset by peer' > "$MT_GH_OTHER_ERR"
got="$(PATH="$ghstub:$PATH" mt_pr_view "" "number,state,url" acme/widget "")"
eq "$(printf '%s' "$got" | jq -r '[.found, .notFound] | map(tostring) | join(" ")')" "false false" "a hidden repository whose other account then fails is not reported as not found"
eq "$(printf '%s' "$got" | jq -r '.error')" 'Post "https://api.github.com/graphql": read: connection reset by peer' "and it carries the other account's error"
# And the other way round: the active account's transport failure is never final, and another
# account's "no pull requests found" ends the walk there, still not claiming not found, because the
# active account's failure is unexplained.
: > "$MT_GH_LOG"
printf '%s\n' 'Post "https://api.github.com/graphql": read: connection reset by peer' > "$MT_GH_ACTIVE_ERR"
printf '%s\n' 'no pull requests found for branch "fix/1173-no-pr-yet"' > "$MT_GH_OTHER_ERR"
got="$(PATH="$ghstub:$PATH" mt_pr_view "" "number,state,url" acme/widget "")"
eq "$(printf '%s' "$got" | jq -r '[.found, .notFound] | map(tostring) | join(" ")')" "false false" "an unexplained failure from the active account still keeps not found from being claimed"
rm -rf "$ghstub"

echo "merge-target: mt_gh_transient tells a GitHub that did not answer from one that refused (claude-config#1061)"

# Worth asking again: the transport failed, or GitHub's own server did. The first two are the
# errors measured on 2026-10-09 reading the compare, word for word as gh printed them.
for e in \
  'Get "https://api.github.com/repos/a/b/compare/main...x": net/http: TLS handshake timeout' \
  'Get "https://api.github.com/repos/a/b/compare/main...x": read tcp 10.0.0.2:51234->140.82.112.6:443: read: connection reset by peer' \
  'Post "https://api.github.com/graphql": dial tcp: lookup api.github.com: no such host' \
  'read tcp 10.0.0.2:51234->140.82.112.6:443: i/o timeout' \
  'Post "https://api.github.com/graphql": EOF' \
  'HTTP 502: Bad Gateway (https://api.github.com/graphql)' \
  'gh: Server Error (HTTP 500)' \
  'HTTP 503: Service Unavailable' \
  'GraphQL: Something went wrong while executing your query. Please include `ABCD:1234` when reporting this issue.'; do
  if mt_gh_transient "$e"; then pass; else fail "a transport or server failure was not worth asking again: $e"; fi
done
# Believed the first time: GitHub answered, and the answer was no. Unknown is never retried (L35).
for e in \
  'gh: Not Found (HTTP 404)' \
  'GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)' \
  'HTTP 401: Bad credentials (https://api.github.com/graphql)' \
  'GraphQL: Pull request is not mergeable (mergePullRequest)' \
  'gh: Validation Failed (HTTP 422)' \
  'gh printed nothing' \
  ''; do
  if mt_gh_transient "$e"; then fail "an answer GitHub gave was treated as worth asking again: [$e]"; else pass; fi
done

echo "merge-target: mt_unfinished_runs reads every page of a commit's workflow runs (claude-config#1087)"
# gh api --paginate prints one object per page, so an unfinished run on the second page must still
# be seen, and an answer that is not the list is not an empty one.
ghstub="$(mktemp -d "${TMPDIR:-/tmp}/mt-ghstub.XXXXXX")"
cat > "$ghstub/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MT_GH_LOG"
case "$MT_RUNS_MODE" in
  pages) printf '%s\n' '{"total_count":2,"workflow_runs":[{"name":"Fast","status":"completed"}]}' '{"total_count":2,"workflow_runs":[{"name":"CI","status":"pending"}]}' ;;
  done) printf '%s\n' '{"total_count":1,"workflow_runs":[{"name":"CI","status":"completed"}]}' ;;
  junk) printf '%s\n' '{"message":"Not Found"}' ;;
  empty) ;;
  reset) echo 'read tcp 10.0.0.2:1->140.82.112.6:443: read: connection reset by peer' >&2; exit 1 ;;
  forbidden) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
esac
EOS
chmod +x "$ghstub/gh"
export MT_GH_LOG="$ghstub/log"
for mode in pages done junk empty reset forbidden; do
  : > "$MT_GH_LOG"
  MT_RUNS_MODE="$mode" PATH="$ghstub:$PATH" mt_unfinished_runs acme/widget abc123 ""; rc=$?
  case "$mode" in
    pages) eq "$rc|$MT_RUNS_PENDING" "0|CI (pending)" "an unfinished run on the second page is seen" ;;
    done) eq "$rc|$MT_RUNS_PENDING" "0|" "every run finished reads as nothing pending" ;;
    junk) eq "$rc" "1" "an answer that is not a list of runs is a failed read, not an empty list" ;;
    empty) eq "$rc" "1" "no answer at all is a failed read, not an empty list" ;;
    reset) eq "$rc" "2" "a reset connection is a transient failure" ;;
    forbidden) eq "$rc|$MT_RUNS_ERR" "1|gh: Resource not accessible by integration (HTTP 403)" "a refusal is believed, with GitHub's words" ;;
  esac
done
: > "$MT_GH_LOG"
eq "$(MT_RUNS_MODE=done PATH="$ghstub:$PATH" mt_unfinished_runs acme/widget abc123 "" ; cat "$MT_GH_LOG")" "api repos/acme/widget/actions/runs?head_sha=abc123&per_page=100 --paginate" "asked about that commit, every page"

echo "merge-target: mt_remote_path says what gh said, so a dropped connection can be asked again (claude-config#1096)"
# It printed only present, absent or unknown, so a caller could not tell a dropped connection from a
# refusal and refused on the first. Now it is a reader: 0 answered, 2 transient, 1 anything else.
cat > "$ghstub/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MT_GH_LOG"
case "$MT_PATH_MODE" in
  present) echo '{}' ;;
  absent) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  timeout) echo 'Get "https://api.github.com/repos/acme/widget/contents/x": net/http: TLS handshake timeout' >&2; exit 1 ;;
  forbidden) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
  silent) exit 1 ;;
  chatty) { echo; echo 'gh: Resource not accessible by integration (HTTP 403)'; awk 'BEGIN { for (i = 1; i <= 20000; i++) print "more detail " i }'; } >&2; exit 1 ;;
esac
EOS
chmod +x "$ghstub/gh"
for mode in present absent timeout forbidden silent chatty; do
  MT_PATH_MODE="$mode" PATH="$ghstub:$PATH" mt_remote_path acme/widget tools/x ""; rc=$?
  case "$mode" in
    present) eq "$rc|$MT_REMOTE_STATE|$MT_REMOTE_ERR" "0|present|" "a path that is there is present" ;;
    absent) eq "$rc|$MT_REMOTE_STATE" "0|absent" "gh's own 404 is an answer: absent" ;;
    timeout) eq "$rc|$MT_REMOTE_STATE" "2|unknown" "a timeout is unknown and worth asking again" ;;
    forbidden) eq "$rc|$MT_REMOTE_STATE|$MT_REMOTE_ERR" "1|unknown|gh: Resource not accessible by integration (HTTP 403)" "a refusal is unknown, believed at once, with GitHub's words" ;;
    silent) eq "$rc|$MT_REMOTE_STATE|$MT_REMOTE_ERR" "1|unknown|gh exited 1" "a failure gh says nothing about is unknown and not asked again" ;;
    # Its first non blank line, read from an error text far past a pipe buffer: the reader keeps
    # that line and reads on to the end rather than leaving at it (claude-config#1042, L183).
    chatty) eq "$rc|$MT_REMOTE_STATE|$MT_REMOTE_ERR" "1|unknown|gh: Resource not accessible by integration (HTTP 403)" "a long error is reported by its first non blank line" ;;
  esac
done
rm -rf "$ghstub"

echo "merge-target: mt_retry_read asks again only on a transient failure, inside its deadline (claude-config#1081)"
tries_left=0; calls=0
flaky(){ calls=$((calls + 1)); if [ "$tries_left" -gt 0 ]; then tries_left=$((tries_left - 1)); return 2; fi; return 0; }
refused(){ calls=$((calls + 1)); return 1; }
slept=""; fake_sleep(){ slept="$slept $1"; }
tries_left=1; calls=0; slept=""
mt_retry_read 3 5 fake_sleep "" "" flaky; eq "$?|$calls|$slept" "0|2| 5" "a read failing once is asked again after one wait, then answers"
tries_left=9; calls=0; slept=""
mt_retry_read 3 5 fake_sleep "" "" flaky; eq "$?|$calls|$slept" "2|3| 5 5" "a read that keeps failing is tried three times in all, then reported failed"
calls=0; slept=""
mt_retry_read 3 5 fake_sleep "" "" refused; eq "$?|$calls|$slept" "1|1|" "a refusal is believed the first time"
tries_left=9; calls=0; slept=""
mt_retry_read 3 5 fake_sleep "$SECONDS" "" flaky; eq "$?|$calls|$slept" "2|1|" "no retry is made whose wait would end past the deadline"

echo "merge-target: the push library's reading, not one of its own (claude-config#1040)"
# This file read commands with its own pair, a bash heredoc stripper then a python segment cutter,
# beside the reader lib/push-scope.sh uses, and two readers of one command drift (L613, L370): the
# stripper had a blind spot the push reader did not, and neither knew what the other did with a
# comment, a pipe or a substitution. It reads ps__read's records now, so the answers below are the
# ones it gave before the switch, measured on main on 2026-10-12, except where a line says it is a
# deliberate change and why.
#   answer  = "<is a gh merge> <merges by any route> pr=<number> repo=<--repo or link>"
corpus_answer() {
  local a=n b=n
  mt_is_pr_merge "$1" && a=y
  mt_runs_merge "$1" && b=y
  printf '%s %s pr=%s repo=%s' "$a" "$b" "$(mt_pr_number "$1")" "$(mt_repo_flag "$1")"
}
same() {  # same <answer> <command>
  eq "$(corpus_answer "$2")" "$1" "#1040 the same answer after the switch: $(printf '%s' "$2" | tr '\n' '~')"
}
same "y y pr=7 repo=" "$MERGE 7 --squash"
same "y y pr=7 repo=" "cd /tmp && $MERGE 7"
same "n n pr= repo=" "gh pr view 7"
same "y y pr=42 repo=" "GH_TOKEN=abc $MERGE 42"
same "y y pr=7 repo=" "GH_TOKEN=\$(gh auth token -u x; true) $MERGE 7"
same "y y pr=7 repo=acme/widget" "GH_TOKEN=\"\$(gh auth token -u x)\" $MERGE 7 --repo acme/widget"
same "y y pr=42 repo=" "git fetch origin ; $MERGE 42"
same "y y pr=42 repo=" "/opt/homebrew/bin/$MERGE 42"
same "n n pr= repo=" "echo \"$MERGE 7\""
same "n n pr= repo=" "echo '$MERGE 7; done'"
same "n n pr= repo=" "cat <<EOF"$'\n'"$MERGE 7"$'\n'"EOF"
same "y y pr=8 repo=" "cat <<'EOF'"$'\n'"don't; $MERGE 7"$'\n'"EOF"$'\n'"$MERGE 8"
same "n n pr= repo=" "gh issue create --body \"run $MERGE 5 later\""
same "y y pr=123 repo=cli/cli" "$MERGE https://github.com/cli/cli/pull/123 --squash"
same "y y pr=7 repo=danwright32/claude-config" "$MERGE 7 --repo danwright32/claude-config --squash --delete-branch"
same "y y pr=7 repo=" "$MERGE --match-head-commit abc123 7"
same "y y pr=9 repo=" "$MERGE --body 42 9"
same "n y pr=680 repo=" "npm run merge -- 680"
same "n n pr= repo=" "npm run merge-ready 680"
same "n y pr=77 repo=" "venv/bin/python tools/wait_for_checks.py 77 --merge"
same "n n pr= repo=" "python3 tools/wait_for_checks.py 77"
same "n y pr=12 repo=" "\$PY tools/wait_for_checks.py 12 --merge"
same "n y pr=31 repo=" "./scripts/merge-when-green.sh 31"
same "y y pr=7 repo=" "$MERGE 7 && echo merged"
same "y y pr=7 repo=" "$MERGE 7 | tee log"
same "y y pr=7 repo=" "(cd /tmp && $MERGE 7)"
same "y y pr=7 repo=" "echo hi # ; $MERGE 7"
same "n n pr= repo=" "# $MERGE 7"
same "y y pr=7 repo=" "$MERGE 7; $MERGE 8"
same "y y pr=1 repo=" "cd /a && $MERGE 1; cd /b && $MERGE 2"
same "y y pr=7 repo=" "PR_REVIEW_READ=abcdef $MERGE 7"
same "y y pr=4 repo=" "echo \$'it\\'s'; $MERGE 4"
same "n n pr= repo=" "git commit -m \"merge the thing\" && git push"
same "y y pr=7 repo=" "echo don't; $MERGE 7"
eq "$(mt_presented_read_key "PR_REVIEW_READ=abcdef $MERGE 7" mt_runs_merge)" "abcdef" "#1040 the read key in front of a merge is still read"
eq "$(mt_presented_read_key "PR_REVIEW_READ=abcdef echo; $MERGE 7" mt_runs_merge)" "" "#1040 and one in front of another command is still not"
# Deliberate changes, each the shell's own reading, which the bash cut got wrong:
#   a merge the shell runs after a pipe, inside a subshell or inside a command substitution was not
#   seen at all, so no merge gate judged it;
same "y y pr=7 repo=" "echo x | $MERGE 7"
same "y y pr=7 repo=" "($MERGE 7)"
same "y y pr=7 repo=" "X=\$($MERGE 7)"
#   a merge behind a reserved word (then, do, {, !, time) or behind rtk was read by its first three
#   whitespace words, `then gh pr`, so it was no merge to any merge gate (the next section);
same "y y pr=9 repo=" "rtk $MERGE 9 --squash"
same "y y pr=7 repo=" "if true; then $MERGE 7; fi"
same "y y pr=7 repo=" "{ $MERGE 7; }"
#   and a command that runs no merge names no pull request: the number used to be read from the
#   whole command when no command was a merge, which with no heredoc stripper left would read a
#   number out of a heredoc body (this line, unchanged from main, is that guard).
same "n n pr= repo=" "cat <<EOF"$'\n'"$MERGE 7"$'\n'"EOF"$'\n'"echo merged"

echo "merge-target: a merge in every command position the shell has (claude-config#1040)"
# The merge head reader took the first three whitespace words of each command, so the words that only
# open or continue a compound command (then, do, else, {, !, time) or rtk in front stood where gh
# should, and the merge walked past every merge gate. It now reads each command from its command
# name on, past those words and any leading assignments, from the one reading (ps__read).
for w in "if true; then $MERGE 7 --squash; fi" \
         "if true; then"$'\n'"  $MERGE 7 --squash"$'\n'"fi" \
         "{ $MERGE 7 --squash; }" \
         "( $MERGE 7 --squash )" \
         "while false; do $MERGE 7; done" \
         "! $MERGE 7" \
         "time $MERGE 7" \
         "rtk $MERGE 7 --squash" \
         "/usr/local/bin/rtk $MERGE 7" \
         "GH_TOKEN=abc $MERGE 7" \
         "if true; then GH_TOKEN=\$(gh auth token -u x) $MERGE 7; fi" \
         "{ X=\"a b\" rtk $MERGE 7; }"; do
  if mt_is_pr_merge "$w" && mt_runs_merge "$w"; then pass; else fail "#1040 a merge in command position was not read as a merge: $w"; fi
  eq "$(mt_pr_number "$w")" "7" "#1040 and it names its pull request: $(printf '%s' "$w" | tr '\n' '~')"
done
for w in "if true; then npm run merge -- 7; fi" "{ ./scripts/merge-when-green.sh 7; }" "then \$PY tools/wait_for_checks.py 7 --merge"; do
  if mt_runs_merge "$w"; then pass; else fail "#1040 a merge tool behind a reserved word was not read as a merge: $w"; fi
done
eq "$(mt_repo_flag "if true; then $MERGE 7 --repo acme/widget; fi")" "acme/widget" "#1040 the repository a merge behind then names"
eq "$(mt_presented_read_key "if true; then PR_REVIEW_READ=abc123 $MERGE 7; fi" mt_runs_merge)" "abc123" "#1040 a read key in front of a merge behind then"
# And words that only look like these stay arguments: a reserved word is one only where a command starts.
for w in "echo then $MERGE 7" "echo { $MERGE 7 }" "echo rtk $MERGE 7" "git commit -m \"then $MERGE 7\""; do
  if mt_runs_merge "$w"; then fail "#1040 a merge named in an argument was read as a merge: $w"; else pass; fi
done
# The same cost as before: a merge behind then is one reading, and no assignment split of its own.
CNT="$(mktemp -d "${TMPDIR:-/tmp}/mt-count.XXXXXXXX")"
mkdir -p "$CNT/bin"
printf '#!/bin/bash\nprintf "start\\n" >> "%s/log"\nexec "%s" "$@"\n' "$CNT" "$(command -v python3)" > "$CNT/bin/python3"
chmod +x "$CNT/bin/python3"
PATH="$CNT/bin:$PATH" bash -c '. "$1"; mt_runs_merge "$2"; mt_presented_read_key "$2" mt_runs_merge' _ "$HOOK_DIR/lib/merge-target.sh" "if true; then GH_TOKEN=x PR_REVIEW_READ=abc $MERGE 7; fi" >/dev/null
n="$( [ -f "$CNT/log" ] && wc -l < "$CNT/log" | tr -d ' ' || printf 0)"
eq "$n" "1" "#1040 a merge behind then and two assignments is read with one python start"
rm -rf "$CNT"

# One reading per command, counted in python3 starts rather than seconds (L224): the questions a
# merge gate asks of one merge, in one shell, start the reader once and the merge's own argument
# reader once per question that needs it (mt_pr_number, mt_repo_flag). Six on main.
CNT="$(mktemp -d "${TMPDIR:-/tmp}/mt-count.XXXXXXXX")"
mkdir -p "$CNT/bin"
printf '#!/bin/bash\nprintf "start\\n" >> "%s/log"\nexec "%s" "$@"\n' "$CNT" "$(command -v python3)" > "$CNT/bin/python3"
chmod +x "$CNT/bin/python3"
got="$(PATH="$CNT/bin:$PATH" bash -c '. "$1"; mt_is_pr_merge "$2" && mt_runs_merge "$2" && printf "%s|%s" "$(mt_pr_number "$2")" "$(mt_repo_flag "$2")"' _ "$HOOK_DIR/lib/merge-target.sh" "$MERGE 7 --repo acme/widget --squash")"
eq "$got" "7|acme/widget" "#1040 the counted questions are answered right"
n="$( [ -f "$CNT/log" ] && wc -l < "$CNT/log" | tr -d ' ' || printf 0)"
if [ "$n" -le 3 ] && [ "$n" -ge 1 ]; then pass; else fail "#1040 four questions of one merge started python $n times, wanted 1 to 3"; fi
rm -rf "$CNT"

# And no second reader can come back: this file never asks lib/shell-words.py for a reading of its
# own, only for the assignment split the push library has no use for, and the segment cutter it used
# is gone from the reader (L613: the component and the guard in one change).
own="$(grep -nE 'SHELL_WORDS"?[[:space:]]+(read|commands|words|gitdir|segments)' "$HOOK_DIR/lib/merge-target.sh")"
eq "$own" "" "#1040 merge-target.sh reads no command with a reader of its own"
eq "$(grep -c 'strip_heredocs' "$HOOK_DIR/lib/merge-target.sh")" "0" "#1040 and strips no heredoc of its own"
printf 'a; b' | python3 "$HOOK_DIR/lib/shell-words.py" segments >/dev/null 2>&1
eq "$?" "64" "#1040 the segment cutter is gone from the reader"

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
