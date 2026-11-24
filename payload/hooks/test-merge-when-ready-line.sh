#!/usr/bin/env bash
# Tests for lib/merge-when-ready.sh, sections 27 to 30 of what was one suite, test-merge-when-ready.sh:
# a conflict confined to README.md's mods table rows, merging as an account that can merge, what
# one look costs while it waits in line, and a waiting run leaving GitHub to the run holding it.
#
# test-merge-when-ready.sh ran past run-all-tests.sh's 1,200 second wall limit on GitHub's runners
# on 2026-11-24 (exit 124), which stopped the config sync between the two Macs: one piece held
# against a fixed deadline had grown to most of it (L315). Its sections are now six suites, each
# dealt to a part by its own measured cost (claude-config#3572): test-merge-when-ready.sh (its
# documentation checks and sections 1 to 10), -heads (11 to 21), -turn (22 to 26b), -line (27 to
# 30), -untested (31 to 33) and -bypass (the bypass merge and sleep mode). Every check is as it was,
# and each section keeps its number, so "section N" in a comment names the section of that number
# in whichever of the six holds it.
#
# The world they run in (the fake gh, the injected clock and sleep, the stub gates and review
# checker, the checkout, the counters and the result line) is lib/merge-when-ready-harness.sh, the
# one place every one of them takes it from. Nothing reaches the network or a real pull request (L2).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/merge-when-ready-harness.sh" || {
  echo "FAIL: $(basename "$0"): lib/merge-when-ready-harness.sh is missing, so there is no world to run the helper in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
mwr_harness_build
# Section 30 waits on its simulated runs with hang_wait (lib/hang-wait.sh), as section 20 does.
. "$DIR/lib/hang-wait.sh"

# =================================================================================================
# 27. A conflict confined to README.md's mods table rows is merged here (claude-config#1867). On
#     2026-10-28 #1819, #1835 (twice), #1850 and #1852 each stopped on GitHub's refusal to update,
#     because two pull requests had touched one mod's row, and each cost about an hour by hand. Now,
#     when GitHub refuses, the helper merges the base into the branch in a throwaway clone of its
#     own, and pushes that merge (never forced) only when README.md is the one file in conflict and
#     every conflicted line is a row of its mods table that lib/readme-rows-merge.py resolves. Any
#     other case stops exactly as before, naming the conflicted files, with the branch untouched,
#     the session's checkout untouched and nothing left behind.
#
#     Each fixture is a real bare repository standing in for acme/widget (the checkout's origin is
#     pointed at it through insteadOf), with main and feat/x each holding one edit of README.md.
#     The table is in the shape README.md has had since #2108: an HTML table whose every cell is a
#     markdown paragraph on lines of its own, so an edit changes only the lines it touches.
# =================================================================================================
RR="$(cd "$WORKDIR" && pwd -P)/rr"; mkdir -p "$RR"
RR_TMP="$RR/tmp"
RR_PY="$RR/crash-bin"; mkdir -p "$RR_PY"
printf '#!/usr/bin/env bash\necho "Traceback (most recent call last): simulated crash" >&2\nexit 1\n' > "$RR_PY/python3"; chmod +x "$RR_PY/python3"
rr_readme(){ cat <<'EOF'
# widget

Shared prose that both sides may edit.

## Mods

<table>
<thead>
<tr><th>Mod</th><th>What it does</th><th>Issue</th></tr>
</thead>
<tbody>
<tr><td>

`alpha`

</td><td>

Does the first thing.

</td><td>

#10

</td></tr>
<tr><td>

`beta`

</td><td>

Does the second thing.

</td><td>

#20

</td></tr>
<tr><td>

`gamma`

</td><td>

Does the third thing.

</td><td>

#30

</td></tr>
</tbody>
</table>

## After

More prose.
EOF
}
# rr_sub <file> <old line> <new line>: replace the line equal to <old line> (awk -v reads a \n in
# <new line> as a line break, so one line can become several).
rr_sub(){ awk -v o="$2" -v n="$3" '{ if ($0 == o) print n; else print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
# rr_cells <key>: the row of mod <key> in the README on standard input, its cells' lines joined by
# spaces and its cells by " | ". Read with awk, not the resolver's own parser (L721).
rr_cells(){ awk -v k="\`$1\`" '
  $0 == "<tr><td>" { inrow = 1; n = 0; cell = ""; next }
  inrow && ($0 == "</td><td>" || $0 == "</td></tr>") {
    c[++n] = cell; cell = ""
    if ($0 == "</td></tr>") { if (c[1] == k) { s = c[1]; for (i = 2; i <= n; i++) s = s " | " c[i]; print s }; inrow = 0 }
    next
  }
  inrow && $0 != "" { cell = (cell == "" ? $0 : cell " " $0) }'; }
A0='Does the first thing.'
B0='Does the second thing.'
C0='Does the third thing.'
# rr_fixture <name> <main's edit> <the branch's edit> [<an edit to the base>]: each edit is run in
# the work tree.
rr_fixture(){
  RB="$RR/$1.git"; RW="$RR/$1-work"; RS="$RR/$1-session"; RR_CONF="$RR/$1.gitconfig"
  git init -q --bare "$RB"
  git init -q "$RW"
  rr_readme > "$RW/README.md"; printf 'one\ntwo\n' > "$RW/other.txt"
  [ -z "${4:-}" ] || (cd "$RW" && eval "$4")
  git -C "$RW" add README.md other.txt; git -C "$RW" commit -qm base
  git -C "$RW" branch -q feat/x
  (cd "$RW" && eval "$2"); git -C "$RW" commit -qam "main's edit"
  git -C "$RW" checkout -q feat/x
  (cd "$RW" && eval "$3"); git -C "$RW" commit -qam "the branch's edit"
  git -C "$RW" push -q "$RB" main feat/x
  git clone -q "$RB" "$RS"
  git -C "$RS" remote set-url origin https://github.com/acme/widget.git
  printf '[include]\n\tpath = %s\n[url "%s"]\n\tinsteadOf = https://github.com/acme/widget.git\n' "$GIT_CONFIG_GLOBAL" "$RB" > "$RR_CONF"
  RR_HEAD="$(git -C "$RB" rev-parse feat/x)"; RR_MAIN="$(git -C "$RB" rev-parse main)"
  RR_SESSION="$(git -C "$RS" rev-parse HEAD)"
  fresh "$RR_HEAD" 1 "$GREEN"
  : > "$ST/update-fails"
  # Once a merge is pushed, GitHub shows the pushed head, green and up to date.
  local step="h=\$(git -C '$RB' rev-parse feat/x); [ \"\$h\" = \"\$(cat \"\$ST/head\")\" ] || { printf '%s' \"\$h\" > \"\$ST/head\"; printf 0 > \"\$ST/behind\"; printf '%s' '$GREEN' > \"\$ST/rollup\"; }"
  printf '%s\n' "$step" "$step" "$step" "$step" > "$ST/on-sleep"
  rm -rf "$RR_TMP"; mkdir -p "$RR_TMP"
}
rr_run(){ (cd "$RS" && TMPDIR="$RR_TMP" GIT_CONFIG_GLOBAL="$RR_CONF" CLAUDE_CODE_BRIDGE_SESSION_ID=session_rr1867 bash "$HELPER" "$@" 2>&1); }
rr_tip(){ git -C "$RB" rev-parse feat/x; }
rr_left(){ find "$RR_TMP" -mindepth 1 -maxdepth 1 -name 'mwr-readme*' | wc -l | tr -d ' '; }
rr_session_same(){ [ "$(git -C "$RS" rev-parse HEAD)" = "$RR_SESSION" ] && [ -z "$(git -C "$RS" status --porcelain)" ] && echo same || echo changed; }
rr_row(){ git -C "$RB" show "feat/x:README.md" | rr_cells "$1"; }
# The edits each case is built from.
MAIN_ROWS="rr_sub README.md '$A0' 'Does the first thing. Main sentence.'; rr_sub README.md '$C0' 'Does the third thing, from main.'"
BRANCH_ROWS="rr_sub README.md '$A0' 'Branch sentence. Does the first thing.'; rr_sub README.md '$B0' 'Does the second thing, from the branch.'"

# Both sides edited one mod's prose, and each edited a row the other left alone: resolved, pushed,
# and then waited on and merged as after any update.
rr_fixture prose "$MAIN_ROWS" "$BRANCH_ROWS"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a conflict confined to mods table rows is resolved and the pull request merges" "0" "$rc"
check "#1867 saying it merged the base into the branch here" "merged main into it here" "$out"
check_eq "#1867 the branch holds a new head" "moved" "$([ "$(rr_tip)" != "$RR_HEAD" ] && echo moved || echo same)"
check_eq "#1867 a merge of the head it judged and the base, so nothing was rewritten" "$RR_HEAD $RR_MAIN" "$(git -C "$RB" log -1 --format=%P feat/x)"
check_eq "#1867 both sentences are in the row both sides edited" '`alpha` | Branch sentence. Does the first thing. Main sentence. | #10' "$(rr_row alpha)"
check_eq "#1867 a row only the branch changed takes the branch's change" '`beta` | Does the second thing, from the branch. | #20' "$(rr_row beta)"
check_eq "#1867 a row only main changed takes main's change" '`gamma` | Does the third thing, from main. | #30' "$(rr_row gamma)"
check_eq "#2108 the merged row is written back in the table's shape" "$(rr_readme | sed -n '/^<table>$/,/^<\/table>$/p' | wc -l | tr -d ' ')" "$(git -C "$RB" show feat/x:README.md | sed -n '/^<table>$/,/^<\/table>$/p' | wc -l | tr -d ' ')"
check_eq "#1867 no conflict marker reaches the branch" "0" "$(git -C "$RB" show feat/x:README.md | grep -c -E '^(<{7}|>{7}|={7})')"
rr_msg="$(git -C "$RB" log -1 --format=%B feat/x)"
check "#1867 the merge commit says what it resolved" "README.md" "$rr_msg"
check_eq "#1867 and ends with the session line" "Claude-Session: https://claude.ai/code/session_rr1867" "$(printf '%s\n' "$rr_msg" | sed '/^$/d' | tail -1)"
check_eq "#1867 the merge is pinned to the pushed head" "1" "$(count gh-calls "pr merge 7 --repo acme/widget --squash --match-head-commit $(rr_tip)")"
check_eq "#1867 the throwaway clone is removed" "0" "$(rr_left)"
check_eq "#1867 the session's checkout is untouched" "same" "$(rr_session_same)"

# Each side added a different issue number to one row: the union.
rr_fixture union "rr_sub README.md '#10' '#10, #11'" "rr_sub README.md '#10' '#10, #12'"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 two issue numbers added to one row resolve" "0" "$rc"
check_eq "#1867 into the union of the issue list" '`alpha` | Does the first thing. | #10, #11, #12' "$(rr_row alpha)"

# The shape real rows have (L48): a description on several lines with a pipe inside a code span,
# and an Issue cell that is not a tidy list ("#607 to #609, #605" began mod-kit's on 2026-10-29).
# Main edits the first line of the description and the branch the last, which git merges by
# itself, and both add an issue number, which it cannot: the row resolves, and the description
# keeps the lines both sides wrote rather than being wrapped afresh.
RD1='Reads the first line,'; RD2='then `a | b` in the middle,'; RD3='and the last line.'
RBASE="rr_sub README.md '$A0' '$RD1\n$RD2\n$RD3'; rr_sub README.md '#10' '#5 to #7, #3, #10'"
rr_fixture real "rr_sub README.md '$RD1' 'Main reads the first line,'; rr_sub README.md '#5 to #7, #3, #10' '#5 to #7, #3, #10, #11'" "rr_sub README.md '$RD3' 'and the last line, says the branch.'; rr_sub README.md '#5 to #7, #3, #10' '#5 to #7, #3, #10, #12'" "$RBASE"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a row of the real shape resolves" "0" "$rc"
check_eq "#1867 keeping the code span's pipe, both edits and both issue numbers" '`alpha` | Main reads the first line, then `a | b` in the middle, and the last line, says the branch. | #5 to #7, #3, #10, #11, #12' "$(rr_row alpha)"
check_eq "#2108 the description keeps its three lines" "1 1 1" "$(git -C "$RB" show feat/x:README.md | grep -c -x -F 'Main reads the first line,') $(git -C "$RB" show feat/x:README.md | grep -c -x -F "$RD2") $(git -C "$RB" show feat/x:README.md | grep -c -x -F 'and the last line, says the branch.')"

# A conflict in another file as well: stops as before, naming both, with nothing pushed.
rr_fixture otherfile "$MAIN_ROWS; printf 'main\ntwo\n' > other.txt" "$BRANCH_ROWS; printf 'branch\ntwo\n' > other.txt"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a conflict in another file as well stops" "1" "$rc"
check "#1867 for a person, as before" "resolve it by hand" "$out"
check "#1867 naming the other file" "other.txt" "$out"
check "#1867 and README.md" "README.md" "$out"
check_eq "#1867 nothing was pushed" "$RR_HEAD" "$(rr_tip)"
check_eq "#1867 nothing was merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#1867 the throwaway clone is removed after a stop" "0" "$(rr_left)"
check_eq "#1867 the session's checkout is untouched after a stop" "same" "$(rr_session_same)"

# A hunk in README.md outside the table: stops.
rr_fixture prosehunk "$MAIN_ROWS; rr_sub README.md 'Shared prose that both sides may edit.' 'Prose main rewrote.'" "$BRANCH_ROWS; rr_sub README.md 'Shared prose that both sides may edit.' 'Prose the branch rewrote.'"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a README.md conflict outside the mods table stops" "1" "$rc"
check "#1867 saying it is not only mods table rows" "not only rows of its mods table" "$out"
check_eq "#1867 nothing was pushed for it" "$RR_HEAD" "$(rr_tip)"

# Both sides changed the same words differently: the word merge still conflicts, so it stops.
rr_fixture words "rr_sub README.md '$A0' 'Does the main thing.'" "rr_sub README.md '$A0' 'Does the branch thing.'"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a word merge that still conflicts stops" "1" "$rc"
check "#1867 naming the row" "alpha" "$out"
check_eq "#1867 nothing was pushed for a word conflict" "$RR_HEAD" "$(rr_tip)"

# A row whose cell count one side changed: the structure check refuses it (L631).
rr_fixture cells "rr_sub README.md '#10' 'extra\n\n</td><td>\n\n#10'" "rr_sub README.md '#10' '#10, #11'"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a row whose cells changed in number stops" "1" "$rc"
check "#1867 saying its number of cells changed" "number of cells changed" "$out"
check_eq "#1867 nothing was pushed for it either" "$RR_HEAD" "$(rr_tip)"

# The resolver crashing (exit 1, as any uncaught error does) is read as unread, never as handled.
rr_fixture crash "$MAIN_ROWS" "$BRANCH_ROWS"
out="$(PATH="$RR_PY:$PATH" rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a resolver that crashes stops it" "1" "$rc"
check "#1867 saying the resolver could not read it" "could not read the conflict" "$out"
check_eq "#1867 nothing was pushed after a crash" "$RR_HEAD" "$(rr_tip)"
check_eq "#1867 and the throwaway clone is removed after a crash" "0" "$(rr_left)"

# GitHub refused, but the merge has no conflict here: GitHub's reason is something else, for a person.
rr_fixture clean "rr_sub README.md '$C0' 'Does the third thing, from main.'" "rr_sub README.md '$A0' 'Branch sentence. Does the first thing.'"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a refusal with no conflict here stops" "1" "$rc"
check "#1867 saying the merge had no conflict here" "no conflict" "$out"
check_eq "#1867 and pushes nothing" "$RR_HEAD" "$(rr_tip)"

# The branch moved past the head the helper judged: it resolves nothing it has not judged.
rr_fixture moved "$MAIN_ROWS" "$BRANCH_ROWS"
git -C "$RW" commit -q --allow-empty -m "a later push"; git -C "$RW" push -q "$RB" feat/x
rr_moved="$(rr_tip)"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a branch that moved past the judged head stops" "1" "$rc"
check "#1867 saying the branch moved" "not the head" "$out"
check_eq "#1867 and leaves the branch where it was" "$rr_moved" "$(rr_tip)"

# A fork's branch is not pushed to.
rr_fixture fork "$MAIN_ROWS" "$BRANCH_ROWS"
printf 'true' > "$ST/cross"; printf 'someone' > "$ST/fork-owner"
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 a fork's pull request stops as before" "1" "$rc"
check "#1867 saying its branch is in a fork" "fork" "$out"
check_eq "#1867 with its branch untouched" "$RR_HEAD" "$(rr_tip)"

# An origin whose address carries a credential is not the repository's plain address, so it is
# refused before any fetch, and git's errors, which repeat the address, are never printed.
rr_fixture token "$MAIN_ROWS" "$BRANCH_ROWS"
git -C "$RS" remote set-url origin https://x-access-token:s3cr3t-stand-in@github.com/acme/widget.git
out="$(rr_run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1867 an origin carrying a credential stops as before" "1" "$rc"
check "#1867 saying the origin is not the repository" "origin is not acme/widget" "$out"
check_not "#1867 and never printing the credential" "s3cr3t-stand-in" "$out"
check_eq "#1867 nothing was pushed through it" "$RR_HEAD" "$(rr_tip)"

# The resolver's own exit codes (L1033): 0 resolved, 10 not a case it handles, 2 could not read.
RR_LIB="$DIR/lib/readme-rows-merge.py"
rr_merge_in(){ # rr_merge_in <fixture>: the fixture's branch as first pushed, with main merged into it, conflicted
  # Cloned from the work tree, whose feat/x is the branch before any merge the helper pushed.
  local d="$RR/$1-direct"; git clone -q "$RR/$1-work" "$d"; git -C "$d" checkout -q feat/x
  git -C "$d" merge -q origin/main >/dev/null 2>&1; printf '%s' "$d"
}
d="$(rr_merge_in union)"; python3 "$RR_LIB" "$d" >/dev/null 2>&1; rc=$?
check_eq "#1867 the resolver exits 0 when it resolved" "0" "$rc"
check_eq "#1867 and writes the resolved row" '`alpha` | Does the first thing. | #10, #11, #12' "$(rr_cells alpha < "$d/README.md")"
d="$(rr_merge_in words)"; before="$(cat "$d/README.md")"; python3 "$RR_LIB" "$d" >/dev/null 2>&1; rc=$?
check_eq "#1867 the resolver exits 10 for a case it does not handle" "10" "$rc"
check_eq "#1867 and writes nothing then" "$before" "$(cat "$d/README.md")"
python3 "$RR_LIB" "$RR/union-session" >/dev/null 2>&1; rc=$?
check_eq "#1867 the resolver exits 2 when README.md is not in conflict there" "2" "$rc"

# =================================================================================================
# 28. It merges as an account that can merge (claude-config#2629). On 2026-11-10 a run against a
#     repository owned by a second personal account waited 7m 30s, then stopped on GitHub's
#     "does not have the correct permissions to execute MergePullRequest": the active account could
#     read the pull request, so it was the one the merge ran as, and it could only read. The fake gh
#     answers each call as the account its token names, and refuses a merge from READ or TRIAGE.
# =================================================================================================
# Two accounts, the active one able only to read: the one with write merges, and the run says so.
fresh "$OLD" 0 "$GREEN"; printf 'reader\nwriter\n' > "$ST/accounts"; printf READ > "$ST/perm-reader"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2629 a read only active account beside one with write still merges" "0" "$rc"
check_eq "#2629 merged as the account with write" "writer" "$(cat "$ST/merge-as" 2>/dev/null)"
check "#2629 saying which account it merges as and why" "Merging as writer: it has WRITE on acme/widget, and reader (the active account) has READ." "$out"
check "#2629 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"

# The same, behind its base: the update, a write too, is made as the account that can merge, and the
# permissions are read once in the run, not at every look.
fresh "$OLD" 1 "$GREEN"; printf 'reader\nwriter\n' > "$ST/accounts"; printf READ > "$ST/perm-reader"
printf '%s\n' "$NEW" > "$ST/next-heads"; printf '%s' "$GREEN" > "$ST/rollup-after-update"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2629 behind its base, it updates and merges" "0" "$rc"
check_eq "#2629 each account's permission read once in the run" "reader writer" "$(paste -sd ' ' - < "$ST/perm-asked")"
check_eq "#2629 and merged as the account with write" "writer" "$(cat "$ST/merge-as" 2>/dev/null)"

# No account can merge: it stops at its first look, naming each account and its permission, before
# any update, wait or merge.
fresh "$OLD" 1 "$PENDING"; printf 'reader\ntriager\n' > "$ST/accounts"; printf READ > "$ST/perm-reader"; printf TRIAGE > "$ST/perm-triager"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2629 no account able to merge stops, needing a person" "1" "$rc"
check "#2629 naming each account and its permission" "reader (the active account) has READ; triager has TRIAGE" "$out"
check "#2629 saying nothing was merged" "Stopped: no signed in gh account can merge in acme/widget" "$out"
check "#2629 and what would let it" "gh auth login" "$out"
check_eq "#2629 before any update, wait or merge" "0 0 0" "$(count gh-calls 'pr update-branch') $(count sleeps .) $(count gh-calls 'pr merge')"

# Already merged, with the branch to delete and no account able to: the branch is left, said as that
# (stop 4), never as nothing merged.
fresh "$OLD" 0 "$GREEN"; : > "$ST/merged"; printf 'reader\n' > "$ST/accounts"; printf READ > "$ST/perm-reader"
out="$(run 7 --repo acme/widget --squash --delete-branch)"; rc=$?
check_eq "#2629 already merged, a branch no account can delete is left (stop 4)" "4" "$rc"
check "#2629 saying it is merged and the branch was left" "is already merged (head ${OLD:0:7}), and its branch was left in place." "$out"
check_not "#2629 never that nothing was merged" "Nothing was merged" "$out"
check_eq "#2629 and the branch was not deleted" "0" "$(count gh-calls 'DELETE')"
# A fork's branch is never deleted here, so a merged fork pull request needs no account that can merge.
fresh "$OLD" 0 "$GREEN"; : > "$ST/merged"; printf true > "$ST/cross"; printf 'reader\n' > "$ST/accounts"; printf READ > "$ST/perm-reader"
out="$(run 7 --repo acme/widget --squash --delete-branch)"; rc=$?
check_eq "#2629 a merged fork pull request still finishes with a read only account" "0" "$rc"
check "#2629 saying its branch is in a fork" "is in a fork" "$out"
check_eq "#2629 with no permission read" "0" "$(count perm-asked .)"

# A permission read that fails is said as that, never as no permission, and another account that
# can merge still does.
fresh "$OLD" 0 "$GREEN"; printf 'reader\nwriter\n' > "$ST/accounts"; printf 'gh: Forbidden (HTTP 403)' > "$ST/perm-reader-down"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2629 a permission read that fails for the active account still merges as the other" "0" "$rc"
check_eq "#2629 as the other" "writer" "$(cat "$ST/merge-as" 2>/dev/null)"
check "#2629 saying the active account's permission could not be read" "reader (the active account): could not read its permission on acme/widget (gh: Forbidden (HTTP 403)" "$out"

# Every read failing: it stops, naming each failure, and merges nothing.
fresh "$OLD" 0 "$GREEN"; printf 'reader\nwriter\n' > "$ST/accounts"
printf 'gh: Forbidden (HTTP 403)' > "$ST/perm-reader-down"; printf 'gh: Forbidden (HTTP 403)' > "$ST/perm-writer-down"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2629 no permission readable stops" "1" "$rc"
check "#2629 saying it could not confirm, never that no account can merge" "Stopped: could not confirm any signed in gh account can merge in acme/widget" "$out"
check_not "#2629 so not claiming what it never read" "no signed in gh account can merge" "$out"
check "#2629 naming the first account's failed read" "reader (the active account): could not read its permission" "$out"
check "#2629 and the second's" "writer: could not read its permission" "$out"
check_eq "#2629 and nothing merged" "0" "$(count gh-calls 'pr merge')"

# A read that fails once in transit is asked again, as every read here is.
fresh "$OLD" 0 "$GREEN"; printf 'read tcp: connection reset by peer\n' > "$ST/perm-active-fails"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2629 a permission read that fails once in transit still merges" "0" "$rc"
check_eq "#2629 asked twice" "2" "$(count perm-asked .)"

# Control: one account, with write, merges as before, asking for its permission once and never
# listing the accounts, which costs gh a request per account.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2629 control: the active account with write merges" "0" "$rc"
check_eq "#2629 control: as the active account" "active" "$(cat "$ST/merge-as" 2>/dev/null)"
check_eq "#2629 control: its permission read once" "1" "$(count perm-asked .)"
check_eq "#2629 control: the accounts never listed" "0" "$(count gh-calls '^auth status')"
check "#2629 control: saying which account and why" "Merging as the active gh account: it has WRITE on acme/widget." "$out"

# =================================================================================================
# 29. What one look costs while it waits in line (claude-config#2694). On 2026-11-10 about 15 helpers
#     waited at once on the personal MacBook, each looking about once a minute, while sessions there
#     ran slow, and one look in a line of four started about 87 programs (29 sed, 16 cat, 12 jq), most
#     of them a sed per field of every ticket in the line, so the cost grew with the line. Every common
#     program is wrapped here to count what the helper itself starts; a fake's own programs are not
#     counted (the bash wrapper takes the wrappers off the path for it), the fake's start is. One look
#     is the difference between a run of 12 looks and one of 4, over 8, behind six live runs. The
#     ceiling is a setting chosen from the measure on 2026-11-10 (109 a look here on the code before,
#     about 22 after, the same behind 3 runs or 14), not a measured limit.
# =================================================================================================
PC_WRAP="$WORKDIR/pc-wrap"; PC_LOG="$WORKDIR/pc-spawns"; PC_BASH="$(command -v bash)"; mkdir -p "$PC_WRAP"
for t in jq cat sed grep egrep mkdir date mv rm head tail awk git perl python3 mktemp wc tr cut sort uniq ls find stat touch ps sysctl dirname basename seq env sleep id hostname tee cp chmod ln readlink expr pgrep shasum xargs rmdir od; do
  real="$(command -v "$t" 2>/dev/null)" || continue
  case "$real" in /*) ;; *) continue ;; esac
  printf '#!/bin/bash\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$t" "$PC_LOG" "$real" > "$PC_WRAP/$t"
done
printf '#!/bin/bash\nprintf "bash\\n" >> "%s"\nw="%s:"; PATH="${PATH#"$w"}"\nexec "%s" "$@"\n' "$PC_LOG" "$PC_WRAP" "$(command -v bash)" > "$PC_WRAP/bash"
chmod +x "$PC_WRAP"/*
# pc_line <looks>: one run behind six live runs, who all leave after <looks> sleeps; sets out, rc,
# pc_n (the programs it started) and pc_sleeps.
pc_line(){
  local p
  fresh "$OLD" 0 "$GREEN"
  for p in 101 102 103 104 105 106; do "$BIN/take-turn" acme/widget "$p"; done
  for _ in $(seq 2 "$1"); do printf ':\n' >> "$ST/on-sleep"; done
  for p in 101 102 103 104 105 106; do leave "$p"; printf '; '; done >> "$ST/on-sleep"; printf '\n' >> "$ST/on-sleep"
  : > "$PC_LOG"
  # The helper itself is started by the real bash, so the wrappers stay on its path.
  out="$(cd "$REPO" && PATH="$PC_WRAP:$PATH" MWR_TURN_HOLD_SECONDS=100000 "$PC_BASH" "$HELPER" 7 --squash 2>&1)"; rc=$?
  pc_n="$(wc -l < "$PC_LOG" | tr -d ' ')"; pc_sleeps="$(wc -l < "$ST/sleeps" | tr -d ' ')"
}
pc_line 4; pc4="$pc_n"; sl4="$pc_sleeps"
check_eq "#2694 the run of 4 looks in line merged" "0" "$rc"
check "#2694 after waiting its 4 looks in line" "after waiting 2m 00s for it" "$out"
pc_line 12; pc12="$pc_n"; sl12="$pc_sleeps"
check_eq "#2694 the run of 12 looks in line merged" "0" "$rc"
check "#2694 after waiting its 12 looks in line" "after waiting 6m 00s for it" "$out"
check_eq "#2694 the two runs differ by 8 looks, one sleep each" "8" "$(( sl12 - sl4 ))"
check_eq "#2694 the count saw the helper start programs at all" "yes" "$( [ "${pc4:-0}" -gt 50 ] && echo yes || echo no)"
per_look=$(( (pc12 - pc4) / 8 ))
check_eq "#2694 one look in a line of seven starts at most 40 programs (it started $per_look)" "yes" "$( [ "$per_look" -le 40 ] && echo yes || echo no)"

# =================================================================================================
# 30. A run waiting for its turn leaves GitHub to the run holding it (claude-config#2715). On
#     2026-11-10 one session's 102 merge logs held 2,845 waits on the session's cap of looks a minute
#     (GH_POLL_PER_MINUTE): 2,594 by helpers waiting in line, and 251 by the helper holding the turn,
#     with a median of 8 helpers in line behind it, and the holder went a median of 120s between looks
#     across those waits. A run in line learns its turn from the queue on this Mac, so it reads GitHub
#     only every MWR_LINE_LOOK_SECONDS (600) to see its own pull request is still open, never because
#     the line moved, and each of those looks leaves one of the minute's looks free for the holder.
# =================================================================================================
# One run behind three, each leaving in turn (at 5m, 15m and 30m): it says the line as it moves,
# reads GitHub only at its first look and every ten minutes, and takes the turn the moment it is its.
fresh "$OLD" 0 "$GREEN"
for p in 9 10 11; do "$BIN/take-turn" acme/widget "$p"; done
step="c=\$(cat \"\$ST/clock\"); [ \"\$c\" -lt 1000300 ] || { $(leave 9); }; [ \"\$c\" -lt 1000900 ] || { $(leave 10); }; [ \"\$c\" -lt 1001800 ] || { $(leave 11); }"
for _ in $(seq 1 80); do printf '%s\n' "$step" >> "$ST/on-sleep"; done
out="$(MWR_POLL_SECONDS=60 MWR_POLL_MAX_SECONDS=180 MWR_LINE_SECONDS=3600 MWR_TURN_HOLD_SECONDS=100000 run 7 --squash)"; rc=$?
check_eq "#2715 a run in a moving line still merges" "0" "$rc"
check "#2715 taking the turn the moment it passes, from the queue on disk" "after waiting 30m 00s for it" "$out"
check "#2715 saying the line as it moved, without reading GitHub for it" "which #10 holds (2 ahead of it in line)" "$out"
check "#2715 and again when it moved on" "which #11 holds (1 ahead of it in line)" "$out"
check_eq "#2715 reading GitHub in line only at its first look and every ten minutes" "1000000 1000600 1001200" "$(awk '$1 < 1001800' "$ST/view-times" | tr '\n' ' ' | sed 's/ $//')"
check "#2715 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"

# A run not yet in line leaves the holder the last of the minute's looks too (claude-config#2749):
# with #9's live run holding the turn and three of the minute's four looks taken, its first read
# waits until a look is a minute old (#9 leaves while it waits, so it then merges).
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
for _ in 1 2 3; do CLAUDE_CODE_SESSION_ID=mwr-suite bash -c ". '$DIR/lib/gh-poll.sh' && ghp_take 1000000" >/dev/null 2>&1; done
printf '%s\n' "$(leave 9)" > "$ST/on-sleep"
out="$(GH_POLL_PER_MINUTE=4 run 7 --squash)"; rc=$?
check_eq "#2749 a run not yet in line still merges" "0" "$rc"
check "#2749 it leaves the holder the minute's last look, naming it" "and #9 holds the turn to merge in acme/widget, so a run not yet in line behind it leaves it the last of the minute's looks" "$out"
check_eq "#2749 its first read waits until a look is a minute old" "1000060" "$(head -1 "$ST/view-times")"
# Control: a holder whose run is no longer running holds nothing back. Its place is passed over, and
# the run takes the minute's last look and the turn at once.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9 99999999 "Thu Jan  1 00:00:00 1970"
for _ in 1 2 3; do CLAUDE_CODE_SESSION_ID=mwr-suite bash -c ". '$DIR/lib/gh-poll.sh' && ghp_take 1000000" >/dev/null 2>&1; done
out="$(GH_POLL_PER_MINUTE=4 run 7 --squash)"; rc=$?
check_eq "#2749 control: a dead holder's line still merges" "0" "$rc"
check_eq "#2749 control: its first read is not held back" "1000000" "$(head -1 "$ST/view-times")"
check_not "#2749 control: and it leaves no look to the dead run" "so a run not yet in line" "$out"
check "#2749 control: saying the dead run's place was passed over" "#9's place in line was passed over" "$out"

# Several helpers in line at once, each a real run of this helper, on one injected clock that moves
# only once every run is asleep, to the earliest time any of them wakes: a run's work between its
# sleeps takes no time on the clock, as it takes next to none on a real one. Only one run is ever
# awake at a time, and runs due at the same moment wake in the order listed (both orders, below), so
# what the runs do depends on the clock alone and never on how the machine schedules them
# (claude-config#2745, L290). #7 holds the turn, its
# checks running the whole 30 minutes, with eight runs in line behind it and the session's own cap of
# four looks a minute. The line moves twice, as the first two in line are stopped at 10 and 20
# minutes. Fixture settings, not measured, but eight, the median of the 2026-11-10 logs.
SIM_DIR="$WORKDIR/sim"; SIMBIN="$WORKDIR/simbin"; mkdir -p "$SIMBIN"
cat > "$SIMBIN/gh" <<EOS
#!/usr/bin/env bash
case "\$*" in "pr view "*) c=""; read -r c < "\$ST/clock"; printf '%s %s\n' "\$c" "\$3" >> "\$ST/sim-views" ;; esac
exec "$BIN/gh" "\$@"
EOS
chmod +x "$SIMBIN/gh"
# The sleep each run in the simulation is given: it marks when it wakes and waits, in real time, for
# the clock to reach it. A run told to quit, and every run once the simulation ends, is stopped as a
# person would stop it. Whether it was woken or stopped is read only AFTER its mark is gone
# (claude-config#2745): the simulation writes the stop before it takes the mark away, so that read
# always sees it. Read before, as it was, a run that looked for the stop just before it was written
# and for its mark just after it went took the stop for a wake, and went on at the last time on the
# clock while the others were being stopped: in CI on 2026-11-11, and in 7 of 10 copies run at once
# here, a run in line then found the holder's place gone and took the turn.
sim_sleep(){ (
  set +e +u
  { [ -e "$SIM_DIR/stop" ] || [ -e "$SIM_DIR/$SIM_ME.quit" ]; } && { kill -TERM "$$"; exit 0; }
  c=""; read -r c < "$ST/clock"
  printf '%s' "$(( c + $1 ))" > "$SIM_DIR/$SIM_ME.tmp" && mv -f "$SIM_DIR/$SIM_ME.tmp" "$SIM_DIR/$SIM_ME.wake"
  while [ -e "$SIM_DIR/$SIM_ME.wake" ]; do sleep 0.01; done
  { [ -e "$SIM_DIR/stop" ] || [ -e "$SIM_DIR/$SIM_ME.quit" ]; } && { kill -TERM "$$"; exit 0; }
  exit 0
) }
export -f sim_sleep
export SIM_DIR
# Each run is given the defaults (a base look of 60s growing to 180s, four looks a minute: settings,
# not measured), and a line budget the simulation never reaches, since its line stands still between
# the two runs that leave it. The runs are this shell's children, kept in SIM_PIDS and reaped by
# sim_run's wait once it has stopped them; nothing is printed between their start and that wait, so
# whatever a run says goes to its own file, and what the simulation itself says to SIM_DIR/said.
SIM_PIDS=""
sim_start(){ # sim_start <pr>: starts a run, then waits until it first sleeps
  ( export MWR_POLL_SECONDS=60 MWR_POLL_MAX_SECONDS=180 GH_POLL_PER_MINUTE=4 MWR_LINE_SECONDS=100000
    cd "$REPO" && SIM_ME="$1" MWR_SLEEP=sim_sleep PATH="$SIMBIN:$PATH" bash "$HELPER" "$1" --squash > "$SIM_DIR/$1.out" 2>&1
    echo "$?" > "$SIM_DIR/$1.rc" ) &
  SIM_PIDS="$SIM_PIDS $!"
  hang_wait "[ -e '$SIM_DIR/$1.wake' ] || [ -e '$SIM_DIR/$1.rc' ]" 0.01 || echo "run $1 never slept" >> "$SIM_DIR/said"
}
# sim_asleep <pr>...: every run still going is asleep, and sim_min is the earliest any of them wakes
# (empty once every run has ended).
sim_asleep(){
  local m w; sim_min=""
  for m in "$@"; do
    [ -e "$SIM_DIR/$m.rc" ] && continue
    [ -e "$SIM_DIR/$m.wake" ] || return 1
    w=""; read -r w < "$SIM_DIR/$m.wake"
    { [ -z "$sim_min" ] || [ "$w" -lt "$sim_min" ]; } && sim_min="$w"
  done
  return 0
}
# sim_run <seconds> <pr>...: runs them all until the clock reaches the seconds given, then stops and
# reaps them. SIM_QUIT lists <pr>@<seconds in>: that run is stopped once the clock would pass that
# time, leaving the line.
sim_run(){
  local t0 end m w q quit p; t0="$(cat "$ST/clock")"; end=$(( t0 + $1 )); shift
  while :; do
    hang_wait "sim_asleep $*" 0.01 || { echo "the runs never all slept at $(cat "$ST/clock")" >> "$SIM_DIR/said"; break; }
    [ -n "$sim_min" ] && [ "$sim_min" -lt "$end" ] || break
    quit=""
    for q in ${SIM_QUIT:-}; do
      [ -e "$SIM_DIR/${q%@*}.quit" ] || [ "$sim_min" -lt $(( t0 + ${q#*@} )) ] || { quit="${q%@*}"; break; }
    done
    if [ -n "$quit" ]; then
      : > "$SIM_DIR/$quit.quit"; rm -f "$SIM_DIR/$quit.wake"; continue
    fi
    printf '%s' "$sim_min" > "$ST/clock"
    # The runs due now wake ONE at a time, in the order they are listed, each left to run until it
    # sleeps again or ends before the next is woken (claude-config#2745). Woken together, as they
    # were, the order they reached the session's looks and the queue was the machine's scheduling,
    # not the clock: at a minute where the holder and runs not yet in line all woke, whichever ran
    # first took the minute's looks. sim_case below runs both orders, the holder first and last.
    for m in "$@"; do
      [ -e "$SIM_DIR/$m.wake" ] || continue
      w=""; read -r w < "$SIM_DIR/$m.wake"
      [ "$w" -gt "$sim_min" ] && continue
      rm -f "$SIM_DIR/$m.wake"
      hang_wait "[ -e '$SIM_DIR/$m.wake' ] || [ -e '$SIM_DIR/$m.rc' ]" 0.01 || { echo "run $m never slept again at $sim_min" >> "$SIM_DIR/said"; break 2; }
    done
  done
  : > "$SIM_DIR/stop"; rm -f "$SIM_DIR"/*.wake
  for p in $SIM_PIDS; do wait "$p"; done
  SIM_PIDS=""
}
# sim_case <how they wake> <pr>...: one simulation, with the runs due at the same moment woken in the
# order given. It runs twice: the holder woken first, and the holder woken LAST, behind runs whose
# first look comes before they know they are in line (claude-config#2749). Woken last, the helper of
# #2740 made the holder wait on the cap once, at 60s (measured 2026-11-11): each of those first looks
# took one of the minute's four, and none was left for it.
LINE_PRS="21 22 23 24 25 26 27 28"
sim_case(){
  local how="$1" sim_out holder holder_looks holder_gaps line_looks p; shift
  fresh "$OLD" 0 "$PENDING"; rm -rf "$SIM_DIR"; mkdir -p "$SIM_DIR"
  sim_start 7
  for p in $LINE_PRS; do sim_start "$p"; done
  SIM_QUIT="21@600 22@1200" sim_run 1800 "$@"
  sim_out="$(cat "$SIM_DIR/said" 2>/dev/null)"
  holder="$(cat "$SIM_DIR/7.out")"
  holder_looks="$(awk '$2 == 7 { print $1 }' "$ST/sim-views")"
  holder_gaps="$(printf '%s\n' "$holder_looks" | awk 'NR > 1 { print $1 - p } { p = $1 }' | sort -n | tr '\n' ' ' | sed 's/ $//')"
  line_looks="$(awk '$2 != 7' "$ST/sim-views" | wc -l | tr -d ' ')"
  echo "#2715 measured, $how: the holder's gaps between looks (s): $holder_gaps; its waits on the session's cap: $(grep -c 'to look at GitHub again' <<<"$holder"); reads by the 8 in line: $line_looks"
  check_eq "#2715 $how: the simulation ran its whole 30 minutes" "" "$sim_out"
  check "#2715 $how: the holder held the turn" "Took the turn to merge in acme/widget" "$holder"
  check_eq "#2715 $how: every run in line took a place behind it" "8" "$(grep -l 'waiting for its turn to merge in acme/widget, which #7 holds' "$SIM_DIR"/2?.out | wc -l | tr -d ' ')"
  check_not "#2715 $how: the holder never waited on the session's cap with eight runs in line behind it" "to look at GitHub again" "$holder"
  check "#2749 $how: a run not yet in line waited rather than take the holder's last look of a minute" "and #7 holds the turn to merge in acme/widget, so a run not yet in line behind it leaves it the last of the minute's looks (GH_POLL_PER_MINUTE)." "$(cat "$SIM_DIR"/2?.out)"
  # Woken last, the runs in line due with the holder (three of them, at 12m) look before it and fit
  # in the three looks they may take, so none waits (measured 2026-11-11); woken first, the third
  # finds the holder's look taken and waits. Either way the runs not yet in line wait, checked above.
  [ "$how" = "holder woken last" ] || check "#2715 $how: while a run in line waited rather than take the last look of a minute" "a run waiting for its turn leaves the last of the minute's looks (GH_POLL_PER_MINUTE) to the runs holding one" "$(cat "$SIM_DIR"/2?.out)"
  check_eq "#2715 $how: the holder looked the whole 30 minutes, at least once every three minutes" "yes" "$( [ "$(printf '%s\n' "$holder_looks" | grep -c .)" -ge 10 ] && echo yes || echo no)"
  check_eq "#2715 $how: the holder looked at its own pace, never more than its 180s ceiling apart" "yes" "$( [ "$(printf '%s\n' "$holder_looks" | awk 'NR > 1 && $1 - p > 180 { bad = 1 } { p = $1 } END { print bad + 0 }')" = 0 ] && echo yes || echo no)"
  check_eq "#2715 $how: the eight in line read GitHub at most once each every ten minutes (8 x 4 looks in 30 minutes)" "yes" "$( [ "$line_looks" -le 32 ] && echo yes || echo no)"
  check_eq "#2715 $how: no run in line merged out of its turn" "0" "$(count gh-calls 'pr merge')"
  check_eq "#2715 $how: every run in line was still waiting for its turn when the simulation ended" "" "$(for p in $LINE_PRS; do grep -q "It is #$p's turn\|Took the turn" "$SIM_DIR/$p.out" && printf '%s ' "$p"; done)"
}
# shellcheck disable=SC2086
sim_case "holder woken first" 7 $LINE_PRS
# shellcheck disable=SC2086
sim_case "holder woken last" $LINE_PRS 7

echo
mwr_harness_result
