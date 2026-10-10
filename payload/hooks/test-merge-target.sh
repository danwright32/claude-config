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
# lib/shell-words.py, the reader behind the two functions above, directly: its two modes, and a
# refusal by exit code for anything else, so a typo in a caller is a failure, not an empty answer.
SW="$HOOK_DIR/lib/shell-words.py"
eq "$(printf '%s' 'a; b && c || d' | python3 "$SW" segments)" "a"$'\n'" b "$'\n'" c "$'\n'" d" "shell-words cuts at each separator outside quotes"
eq "$(printf '%s' 'echo "a; b" && c' | python3 "$SW" segments)" 'echo "a; b" '$'\n'' c' "and not inside them"
eq "$(printf '%s' 'A="x y" B=$(p q) cmd arg' | python3 "$SW" split)" "A=x y"$'\n'"B=\$(p q)"$'\n'$'\x1f'$'\n'"cmd arg" "shell-words splits leading assignments from the command"
printf 'x' | python3 "$SW" nonsense >/dev/null 2>&1; eq "$?" "64" "shell-words refuses an unknown mode"
# A reader that CRASHES must fall back to the plain reading, never answer "no merge" (L42, L490).
BROKEN_SW="$(mktemp "${TMPDIR:-/tmp}/broken-sw.XXXXXX")"
printf 'import sys\nsys.exit(3)\n' > "$BROKEN_SW"
saved_sw="$MT_SHELL_WORDS"; MT_SHELL_WORDS="$BROKEN_SW"
if mt_runs_merge 'GH_TOKEN=x gh pr merge 7'; then pass; else fail "a crashed reader hid a merge after an assignment"; fi
if mt_runs_merge 'echo a; gh pr merge 7'; then pass; else fail "a crashed reader hid a merge after a separator"; fi
MT_SHELL_WORDS="$saved_sw"; rm -f "$BROKEN_SW"
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

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
