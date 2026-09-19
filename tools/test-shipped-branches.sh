#!/usr/bin/env bash
#
# test-shipped-branches.sh: the tool that says which remote branches have already shipped.
#
# Why it exists (claude-config#358): this repo squashes on merge, so a merged branch is never an
# ancestor of the default branch and every local way of asking reports every branch as unmerged
# (L642). At the time of writing there were 48 of them. The cost is not the clutter: a branch
# holding real unfinished work sits in that list looking exactly like the 47 that shipped.
#
# Everything here runs against real git repositories in a temp directory. The one outside
# dependency, GitHub, is a stub `gh` first on PATH that answers from files this test writes and logs
# every call, so no case here can reach the real GitHub (L2) and a case that passes because the stub
# was never asked is caught (L143). The tool changes nothing, so there is no clock to inject.

set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/shipped-branches.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.shippedbranches.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
says() {  # says <description> <literal needle> <text>
  case "$3" in *"$2"*) ok ;; *) bad "$1 (wanted [$2] in: ${3:0:300})" ;; esac
}
lacks() {  # lacks <description> <literal needle> <text>
  case "$3" in *"$2"*) bad "$1 (did not want [$2])" ;; *) ok ;; esac
}

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# THE STUB GH, the same shape as the one in test-shipped-worktrees.sh. `gh pr list --head <branch>`
# prints $STUB/<branch>.json, or an empty list when there is none, which is what GitHub says about a
# branch with no pull request. A file called FAIL makes every call fail the way gh does offline.
STUB="$WORK/gh-answers"; mkdir -p "$STUB" "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/calls.log"
if [ -e "$STUB_DIR/FAIL" ]; then
  echo "error connecting to api.github.com" >&2
  exit 1
fi
head=""
while [ $# -gt 0 ]; do
  case "$1" in --head) head="$2"; shift ;; esac
  shift
done
f="$STUB_DIR/$(printf '%s' "$head" | sed 's#/#__#g').json"
if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
GH
chmod +x "$WORK/bin/gh"
export STUB_DIR="$STUB"
export PATH="$WORK/bin:$PATH"
answer() {  # answer <branch> <json>
  printf '%s\n' "$2" > "$STUB/$(printf '%s' "$1" | sed 's#/#__#g').json"
}

# A repo whose history holds one of each kind: a branch squashed onto main, a branch merged with
# its commits kept, and a branch nobody has landed.
BARE="$WORK/origin.git"
git init -q --bare -b main "$BARE"
R="$WORK/work"
git clone -q "$BARE" "$R" 2>/dev/null
git -C "$R" config user.email t@t.t
git -C "$R" config user.name t
printf 'one\n' > "$R/f.txt"
git_q "$R" add f.txt; git_q "$R" commit -qm "the first commit"
git_q "$R" push -q origin main

# 1. SQUASHED. The branch's own commit is not on main; a commit carrying its subject is.
git_q "$R" checkout -qb squashed-work
printf 'two\n' > "$R/f.txt"
git_q "$R" commit -qam "Teach the widget to count"
git_q "$R" push -q origin squashed-work
git_q "$R" checkout -q main
printf 'two\n' > "$R/f.txt"
git_q "$R" commit -qam "Teach the widget to count (#42)"
git_q "$R" push -q origin main

# 2. MERGED THE ORDINARY WAY. Its tip really is an ancestor of main.
git_q "$R" checkout -qb kept-history
printf 'three\n' > "$R/g.txt"
git_q "$R" add g.txt; git_q "$R" commit -qm "Add the other thing"
git_q "$R" push -q origin kept-history
git_q "$R" checkout -q main
git_q "$R" merge -q --no-ff -m "Merge the other thing" kept-history
git_q "$R" push -q origin main

# 3. NEVER LANDED. Nothing on main carries it.
git_q "$R" checkout -qb still-open
printf 'four\n' > "$R/h.txt"
git_q "$R" add h.txt; git_q "$R" commit -qm "Something nobody finished"
git_q "$R" push -q origin still-open
git_q "$R" checkout -q main

out="$(bash "$TOOL" "$R" 2>&1)"; rc=$?

echo "shipped-branches: reading a repo that squashes on merge"

if [ "$rc" = 0 ]; then ok; else bad "reading an ordinary repo should exit 0, got $rc"; fi
says "a squash merged branch is reported as shipped" "squashed-work" "$out"
says "and it names the commit that carries it" "(#42)" "$out"
says "a branch merged with its history kept is shipped too" "kept-history" "$out"
says "a branch nobody landed is reported as unmatched" "still-open" "$out"

# The two signals are different in strength and the output must say which one it used, because an
# ancestor is proof and a matching subject is a guess (L11).
says "it distinguishes the two signals" "subject" "$out"

# THE ONE THAT MATTERS. An unmatched branch is a thing to LOOK AT, never a thing to delete: a
# branch reworded at merge is a false negative, and deleting on a false negative destroys the one
# branch in the list that mattered (L5).
says "an unmatched branch is offered for a look, not for deletion" "look" "$out"
lacks "it never tells anybody to delete anything" "delete" "$out"

# It changes nothing. The branches it just judged are all still there.
for b in squashed-work kept-history still-open; do
  if git -C "$R" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1; then ok
  else bad "the tool removed the branch $b, and it must change nothing"; fi
done
# And the checkout is left on the branch it was found on, because a checkout can be shared.
if [ "$(git -C "$R" rev-parse --abbrev-ref HEAD)" = "main" ]; then ok
else bad "the tool moved the working tree off the branch it found it on"; fi

# The default branch is not one of the candidates: reporting main against itself is noise. The
# check is on a judged ROW, not on the name appearing anywhere, because the header and every
# verdict line name it legitimately and a blunter check would be about the prose.
rows_for_main="$(grep -E '^  (SHIPPED|UNMATCHED) +origin/main( |$)' <<< "$out" | wc -l | tr -d ' ')"
if [ "$rows_for_main" = 0 ]; then ok; else bad "the default branch was judged against itself"; fi
# And rows really are being produced, or the check above passes over an empty report (L98).
rows_total="$(grep -cE '^  (SHIPPED|UNMATCHED) ' <<< "$out" | tr -d ' ')"
if [ "$rows_total" = 3 ]; then ok; else bad "expected three judged branches, got $rows_total"; fi

echo "shipped-branches: it judges the remote, not a stale local copy of it"

# Found within an hour of shipping this tool, by trying to act on what it said. It enumerated
# refs/remotes/origin, which is this clone's REMEMBERED copy of the remote and is only as current
# as the last prune. On the real repo that copy held 50 branches while the remote held exactly one:
# every other branch had been deleted on the server long ago and nothing here had noticed. So the
# tool answered confidently, at length, about 49 branches that do not exist, and the first command
# anybody ran on the strength of it failed with "remote ref does not exist".
#
# A report about a list nobody verified against its source is the thing this tool was built to
# replace, so it now reads the remote when it can, and says so plainly when it cannot (L11, L175).

# A branch that was pushed, fetched, and then removed from the remote behind this clone's back.
git_q "$R" checkout -qb deleted-elsewhere
printf 'five\n' > "$R/i.txt"
git_q "$R" add i.txt; git_q "$R" commit -qm "Work that was later removed from the remote"
git_q "$R" push -q origin deleted-elsewhere
git_q "$R" checkout -q main
git_q "$R" fetch -q origin
git -C "$BARE" update-ref -d refs/heads/deleted-elsewhere
# The stale ref really is still here, or the case below is about nothing (L159).
check_stale="$(git -C "$R" for-each-ref --format='%(refname:short)' refs/remotes/origin/deleted-elsewhere)"
if [ -n "$check_stale" ]; then ok; else bad "the fixture did not leave a stale tracking ref behind"; fi

out_rm="$(bash "$TOOL" "$R" 2>&1)"
says "a branch gone from the remote is named as gone" "deleted-elsewhere" "$out_rm"
says "and it is called gone rather than judged as work" "GONE" "$out_rm"
says "and it says how to clear the stale copy" "prune" "$out_rm"
# It must NOT be reported as unfinished work, which is the reading that sent somebody to delete
# a branch that was not there.
if grep -qE '^  UNMATCHED +origin/deleted-elsewhere' <<< "$out_rm"; then
  bad "a branch that no longer exists was reported as work that never landed"
else ok; fi

# origin/HEAD is the symbolic pointer at the default branch, not a branch anybody wrote. It
# shortens to plain `origin`, so an exclusion written against the short name keeps it and it gets
# reported as a branch called origin that is gone from the remote, with a prune that would not
# clear it: a remedy for a thing that is not a problem (L11, L111).
lacks "the symbolic HEAD pointer is not reported as a branch" "  GONE       origin  " "$out_rm"
if grep -qE '^  (SHIPPED|UNMATCHED|GONE) +origin$' <<< "$out_rm"; then
  bad "origin/HEAD was listed as a branch in its own right"
else ok; fi

# The branches that ARE on the remote are still judged, so this has not turned into a tool that
# only ever reports staleness (L159).
says "a branch still on the remote is still judged" "still-open" "$out_rm"

# When the remote cannot be reached at all, it falls back to the remembered copy and SAYS that,
# rather than presenting a stale list as current (L98).
UNREACHABLE="$WORK/unreachable-clone"
cp -R "$R" "$UNREACHABLE"
git -C "$UNREACHABLE" remote set-url origin "$WORK/no-such-bare-repo.git"
out_un="$(bash "$TOOL" "$UNREACHABLE" 2>&1)"
says "an unreachable remote is said out loud" "could not be read" "$out_un"
says "and it names what it fell back to" "last fetch" "$out_un"
# It still produces a report rather than refusing, because a stale answer that says it is stale is
# more use than nothing when somebody is offline.
says "it still judges what it has" "still-open" "$out_un"

echo "shipped-branches: a merged pull request is proof, read before the subject guess"

# claude-config#459. A subject match is a guess, and it misses a branch whose title was reworded
# when it merged. GitHub's own record of a merged pull request from the branch is proof, so it is
# read between ancestry and the subject, through the one gh reading shipped-worktrees.sh uses.
P="$WORK/pr-work"; cp -R "$R" "$P"

# REWORDED. Its subject is on main nowhere, so only the pull request can say it shipped.
git_q "$P" checkout -qb reworded-at-merge
printf 'six\n' > "$P/j.txt"
git_q "$P" add j.txt; git_q "$P" commit -qm "A title somebody changed at merge"
git_q "$P" push -q origin reworded-at-merge
reworded_tip="$(git -C "$P" rev-parse HEAD)"
answer reworded-at-merge "[{\"number\":7,\"state\":\"MERGED\",\"headRefOid\":\"$reworded_tip\"}]"

# REUSED. A pull request merged from this branch at an EARLIER commit, and then more work was
# pushed to the same name. The merge proves the old tip shipped, not the new one.
git_q "$P" checkout -q main
git_q "$P" checkout -qb reused-name
printf 'seven\n' > "$P/k.txt"
git_q "$P" add k.txt; git_q "$P" commit -qm "The part that merged"
reused_old="$(git -C "$P" rev-parse HEAD)"
printf 'eight\n' > "$P/k.txt"
git_q "$P" commit -qam "Work pushed after the merge"
git_q "$P" push -q origin reused-name
answer reused-name "[{\"number\":8,\"state\":\"MERGED\",\"headRefOid\":\"$reused_old\"}]"

# OPEN. A pull request still open from the branch is not proof of anything shipping.
answer still-open '[{"number":9,"state":"OPEN","headRefOid":"0000000000000000000000000000000000000000"}]'
git_q "$P" checkout -q main
git_q "$P" fetch -q origin

rm -f "$STUB/calls.log"
out_pr="$(bash "$TOOL" "$P" 2>&1)"; rc_pr=$?
if [ "$rc_pr" = 0 ]; then ok; else bad "a run reading gh should exit 0, got $rc_pr"; fi
row_reworded="$(grep -E '^  (SHIPPED|UNMATCHED) +origin/reworded-at-merge( |$)' <<< "$out_pr" || true)"
says "a branch reworded at merge is shipped on its merged pull request" "SHIPPED" "$row_reworded"
says "and the row names the pull request as the proof" "pull request #7 merged" "$row_reworded"
# gh is asked about the branch by its own name, not the remote tracking name (L143).
if grep -qF -- "--head reworded-at-merge " "$STUB/calls.log" 2>/dev/null; then ok
else bad "gh was never asked about reworded-at-merge by its branch name"; fi

row_reused="$(grep -E '^  (SHIPPED|UNMATCHED) +origin/reused-name( |$)' <<< "$out_pr" || true)"
says "a branch with work pushed after its merge is not proven shipped" "UNMATCHED" "$row_reused"
says "and the row says the merge was of an earlier commit" "earlier commit" "$row_reused"

row_open="$(grep -E '^  (SHIPPED|UNMATCHED) +origin/still-open( |$)' <<< "$out_pr" || true)"
says "a branch with only an open pull request is not shipped" "UNMATCHED" "$row_open"
says "and the row names the open pull request" "#9" "$row_open"

# The subject guess still answers where GitHub has no pull request, and still says it is a guess.
row_sq="$(grep -E '^  (SHIPPED|UNMATCHED) +origin/squashed-work( |$)' <<< "$out_pr" || true)"
says "a branch with no pull request still ships on a subject match" "subject match" "$row_sq"
says "the report says what merged means" "gh" "$(sed -n 1,3p <<< "$out_pr")"

echo "shipped-branches: gh that cannot be read is said, and the guess is labelled as one"

# Unreadable is neither merged nor unmerged (L98). This tool changes nothing, so it may still
# report, but it must say GitHub was not read and must not dress the fallback up as an answer.
touch "$STUB/FAIL"
rm -f "$STUB/calls.log"
out_ng="$(bash "$TOOL" "$P" 2>&1)"; rc_ng=$?
rm -f "$STUB/FAIL"
if [ "$rc_ng" = 0 ]; then ok; else bad "an unreadable gh should still report, exit 0, got $rc_ng"; fi
says "an unreadable GitHub is said out loud" "GitHub could not be read" "$out_ng"
says "and it passes on what gh said" "error connecting" "$out_ng"
row_ng_sq="$(grep -E '^  (SHIPPED|UNMATCHED) +origin/squashed-work( |$)' <<< "$out_ng" || true)"
says "the subject guess still answers when gh cannot" "subject match" "$row_ng_sq"
row_ng_rw="$(grep -E '^  (SHIPPED|UNMATCHED) +origin/reworded-at-merge( |$)' <<< "$out_ng" || true)"
says "a branch gh could have proven falls back to the guess" "UNMATCHED" "$row_ng_rw"
says "and its row says GitHub was not read, rather than calling it unmerged" "GitHub not read" "$row_ng_rw"
lacks "unreadable is never reported as no merged pull request" "no merged pull request" "$out_ng"
# One failure is enough to know: asking again per branch pays an offline timeout each time.
ng_calls="$( { wc -l < "$STUB/calls.log"; } 2>/dev/null | tr -d ' ')"
if [ "$ng_calls" = 1 ]; then ok; else bad "gh was asked ${ng_calls:-0} times after it had already failed"; fi

echo "shipped-branches: what it refuses"

# A target it cannot use is refused rather than silently answered about somewhere else (L320).
notrepo="$WORK/not-a-repo"; mkdir -p "$notrepo"
out_nr="$(bash "$TOOL" "$notrepo" 2>&1)"; rc_nr=$?
if [ "$rc_nr" != 0 ]; then ok; else bad "a directory that is not a checkout should be refused"; fi
says "the refusal says what it was given" "not-a-repo" "$out_nr"

# A repo with NO branches besides the default must say so rather than print an empty report that
# reads as everything being clean (L98).
EMPTY_BARE="$WORK/empty.git"; git init -q --bare -b main "$EMPTY_BARE"
E="$WORK/empty-work"; git clone -q "$EMPTY_BARE" "$E" 2>/dev/null
git -C "$E" config user.email t@t.t; git -C "$E" config user.name t
printf 'x\n' > "$E/f.txt"; git_q "$E" add f.txt; git_q "$E" commit -qm "only commit"; git_q "$E" push -q origin main
out_e="$(bash "$TOOL" "$E" 2>&1)"
says "a repo with nothing to judge says so" "no branches" "$out_e"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
