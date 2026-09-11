#!/usr/bin/env bash
#
# test-shipped-branches.sh: the tool that says which remote branches have already shipped.
#
# Why it exists (claude-config#358): this repo squashes on merge, so a merged branch is never an
# ancestor of the default branch and every local way of asking reports every branch as unmerged
# (L642). At the time of writing there were 48 of them. The cost is not the clutter: a branch
# holding real unfinished work sits in that list looking exactly like the 47 that shipped.
#
# Everything here runs against real git repositories in a temp directory. The tool touches no
# network and changes nothing, so there is nothing to stub and no clock to inject.

set -uo pipefail

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
