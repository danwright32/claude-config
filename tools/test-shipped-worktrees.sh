#!/usr/bin/env bash
#
# test-shipped-worktrees.sh: the tool that finds agent worktrees whose pull request has merged,
# and removes them only when asked and only when every proof holds.
#
# Why it exists (claude-config#448): agent worktrees under .claude/worktrees/ were never removed
# after their branch shipped. On 2026-09-18 five sat in this checkout, each backing a pull request
# merged days earlier, costing disk on a Mac that has run out before and blurring which work is
# still live. The removal is the dangerous half, so most of this file is about what it must KEEP.
#
# Everything runs against real git repositories in a temp directory. The one outside dependency,
# GitHub, is a stub `gh` first on PATH that answers from files this test writes and logs every
# call, so a case that passes because the stub was never asked is caught (L143). The in use case
# starts a real process standing in a worktree, because the check it exercises is the real lsof.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/shipped-worktrees.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.shippedworktrees.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
WORK="$(cd "$WORK" && pwd -P)"
SQUATTER=""
cleanup() {
  [ -n "$SQUATTER" ] && kill "$SQUATTER" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
says() {  # says <description> <literal needle> <text>
  case "$3" in *"$2"*) ok ;; *) bad "$1 (wanted [$2] in: ${3:0:600})" ;; esac
}
lacks() {  # lacks <description> <literal needle> <text>
  case "$3" in *"$2"*) bad "$1 (did not want [$2])" ;; *) ok ;; esac
}
row() {  # row <verdict> <worktree name> <text>: the report line judging that worktree
  grep -E "^  $1 +\.claude/worktrees/$2( |$)" <<< "$3" || true
}
exists() { [ -d "$1" ]; }

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# THE STUB GH. `gh pr list --head <branch> ...` prints $STUB/<branch with / as __>.json, or an
# empty list when there is none, which is what GitHub says about a branch with no pull request.
# A file called FAIL makes every call fail the way gh does offline.
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
merged_at() {  # merged_at <branch> <number> <head oid>
  answer "$1" "[{\"number\":$2,\"state\":\"MERGED\",\"headRefOid\":\"$3\"}]"
}

# A repo with a bare origin, the primary checkout on main, and agent worktrees beside it where
# Claude Code puts them.
BARE="$WORK/origin.git"
git init -q --bare -b main "$BARE"
R="$WORK/primary"
git clone -q "$BARE" "$R" 2>/dev/null
git -C "$R" config user.email t@t.t
git -C "$R" config user.name t
printf '.claude/\n' > "$R/.gitignore"
printf 'one\n' > "$R/f.txt"
git_q "$R" add f.txt .gitignore; git_q "$R" commit -qm "the first commit"
git_q "$R" push -q origin main
git_q "$R" remote set-head origin main
WT="$R/.claude/worktrees"
mkdir -p "$WT"

agent() {  # agent <name> <branch>: a worktree with one commit of its own, pushed
  git_q "$R" worktree add -q -b "$2" "$WT/$1" main
  printf '%s\n' "$1" > "$WT/$1/$1.txt"
  git_q "$WT/$1" add "$1.txt"
  git_q "$WT/$1" commit -qm "work done in $1"
  git_q "$WT/$1" push -q -u origin "$2"
  git -C "$WT/$1" rev-parse HEAD
}

# 1. MERGED AND CLEAN, remote branch still there. Removable.
tip="$(agent done-kept fix/done-kept)"; merged_at fix/done-kept 11 "$tip"

# 2. MERGED AND CLEAN, and the remote branch was deleted after the merge and pruned here, which is
# what happens to every branch this repo merges. Its commits are on neither origin/main (the squash
# rewrote them) nor any remote branch, so the proof it is safe is that its tip IS the head the
# merged pull request recorded. Removable.
tip="$(agent done-deleted fix/done-deleted)"; merged_at fix/done-deleted 12 "$tip"
git -C "$BARE" update-ref -d refs/heads/fix/done-deleted
git_q "$R" fetch -q --prune origin
if git -C "$R" rev-parse --verify --quiet refs/remotes/origin/fix/done-deleted >/dev/null; then
  bad "the fixture did not remove the remote branch for done-deleted"
else ok; fi

# 3. MERGED BUT DIRTY: an untracked file nobody committed.
tip="$(agent dirty fix/dirty)"; merged_at fix/dirty 13 "$tip"
printf 'unsaved\n' > "$WT/dirty/notes.txt"

# 4. MERGED BUT WITH A COMMIT NOBODY PUSHED, made after the pull request merged.
tip="$(agent unpushed fix/unpushed)"; merged_at fix/unpushed 14 "$tip"
printf 'more\n' >> "$WT/unpushed/unpushed.txt"
git_q "$WT/unpushed" commit -qam "a commit that exists only here"

# 5. NOT MERGED: its pull request is still open. This is every running agent's worktree.
tip="$(agent open fix/open)"
answer fix/open "[{\"number\":15,\"state\":\"OPEN\",\"headRefOid\":\"$tip\"}]"

# 6. NO PULL REQUEST AT ALL: the stub answers with an empty list.
agent never fix/never >/dev/null

# 7. MERGED ONCE, AND A NEW PULL REQUEST FROM THE SAME BRANCH IS OPEN: the branch is live again.
tip="$(agent reopened fix/reopened)"
answer fix/reopened "[{\"number\":16,\"state\":\"MERGED\",\"headRefOid\":\"$tip\"},{\"number\":17,\"state\":\"OPEN\",\"headRefOid\":\"$tip\"}]"

# 8. MERGED AND CLEAN BUT LOCKED, which is how Claude Code marks the worktree of a running agent.
tip="$(agent locked fix/locked)"; merged_at fix/locked 18 "$tip"
git_q "$R" worktree lock --reason "claude agent test (pid 1)" "$WT/locked"

# 9. MERGED AND CLEAN BUT A PROCESS IS STANDING IN IT, the way another session's shell would.
tip="$(agent inuse fix/inuse)"; merged_at fix/inuse 19 "$tip"
mkdir -p "$WT/inuse/deeper"
( cd "$WT/inuse/deeper" && exec sleep 300 ) &
SQUATTER=$!
# The squatter really is standing there before anything is judged, or case 9 is about nothing
# (L159). lsof reports the resolved path, which is why WORK was resolved above.
seen=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if lsof -a -p "$SQUATTER" -d cwd -Fn 2>/dev/null | grep -q "^n$WT/inuse/deeper$"; then seen=1; break; fi
  perl -e 'select(undef, undef, undef, 0.1)'
done
if [ -n "$seen" ]; then ok; else bad "the fixture process never stood in the inuse worktree"; fi

# 10. DETACHED: no branch, so no pull request can prove anything about it.
git_q "$R" worktree add -q --detach "$WT/detached" main

# 11. VANISHED: git still records it, but its directory was deleted by hand.
agent vanished fix/vanished >/dev/null
rm -rf "$WT/vanished"

echo "shipped-worktrees: report mode judges every worktree and changes nothing"

out="$(bash "$TOOL" "$R" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok; else bad "report mode should exit 0, got $rc: ${out:0:600}"; fi

says "a merged clean worktree is removable" "REMOVABLE" "$(row REMOVABLE done-kept "$out")"
says "and it names the pull request that proves it" "#11" "$(row REMOVABLE done-kept "$out")"
says "a merged clean worktree whose remote branch is gone is removable too" "#12" \
  "$(row REMOVABLE done-deleted "$out")"

says "a dirty worktree is kept" "uncommitted" "$(row KEEP dirty "$out")"
says "a worktree with an unpushed commit is kept" "1 commit" "$(row KEEP unpushed "$out")"
says "a worktree whose pull request is open is kept" "no merged pull request" "$(row KEEP open "$out")"
says "a worktree with no pull request at all is kept" "no merged pull request" "$(row KEEP never "$out")"
says "a branch merged once and open again is kept" "#17 from this branch is still open" \
  "$(row KEEP reopened "$out")"
says "a locked worktree is kept and the lock is quoted" "claude agent test" "$(row KEEP locked "$out")"
says "a worktree a process is standing in is kept" "current directory of pid $SQUATTER" \
  "$(row KEEP inuse "$out")"
says "a detached worktree is kept" "no branch" "$(row KEEP detached "$out")"
says "a worktree whose directory is gone is kept, with the command that clears it" "worktree prune" \
  "$(row KEEP vanished "$out")"

# Exactly the two proven ones are removable, and every worktree got a row, or the checks above
# pass over a report that skipped some (L98).
n_removable="$(grep -cE '^  REMOVABLE ' <<< "$out" | tr -d ' ')"
n_keep="$(grep -cE '^  KEEP ' <<< "$out" | tr -d ' ')"
if [ "$n_removable" = 2 ]; then ok; else bad "expected 2 removable, got $n_removable"; fi
if [ "$n_keep" = 9 ]; then ok; else bad "expected 9 kept, got $n_keep"; fi
# The primary checkout is never a candidate.
lacks "the primary checkout is not judged" "  REMOVABLE  $R " "$out"

# GitHub was really asked about each branch, so a KEEP above is the stub's answer and not the
# stub going unasked (L143).
for b in fix/done-kept fix/open fix/never fix/inuse; do
  if grep -q -- "--head $b " "$STUB/calls.log"; then ok; else bad "gh was never asked about $b"; fi
done

# Report mode changed nothing: every worktree and every branch is where it was.
for n in done-kept done-deleted dirty unpushed open never reopened locked inuse; do
  if exists "$WT/$n"; then ok; else bad "report mode removed the worktree $n"; fi
done
if git -C "$R" rev-parse --verify --quiet refs/heads/fix/done-kept >/dev/null; then ok
else bad "report mode deleted a branch"; fi
says "report mode says how to remove" "--remove" "$out"
says "and says it changed nothing" "Nothing was changed" "$out"

echo "shipped-worktrees: gh that cannot be read is a refusal, never a verdict"

# Unreadable is neither merged nor not merged. Reading it as not merged keeps everything and says
# nothing is wrong; reading it as merged removes live work (L98, L320).
touch "$STUB/FAIL"
out_gh="$(bash "$TOOL" --remove "$R" 2>&1)"; rc_gh=$?
rm -f "$STUB/FAIL"
if [ "$rc_gh" != 0 ] && [ "$rc_gh" != 1 ]; then ok
else bad "an unreadable gh should refuse with its own exit code, got $rc_gh"; fi
says "the refusal says GitHub could not be read" "could not read" "$out_gh"
says "and passes on what gh said" "error connecting" "$out_gh"
lacks "no worktree is judged removable on an unreadable gh" "REMOVABLE" "$out_gh"
lacks "and none is removed" "REMOVED" "$out_gh"
if exists "$WT/done-kept"; then ok; else bad "an unreadable gh still removed a worktree"; fi

# gh answering with something that is not a list of pull requests is unreadable too.
answer fix/done-kept 'not json at all'
out_junk="$(bash "$TOOL" "$R" 2>&1)"; rc_junk=$?
merged_at fix/done-kept 11 "$(git -C "$WT/done-kept" rev-parse HEAD)"
if [ "$rc_junk" != 0 ]; then ok; else bad "an unparseable gh answer should be refused"; fi
says "an unparseable answer is refused the same way" "could not read" "$out_junk"

echo "shipped-worktrees: --remove removes only what is proven, and names each one"

out_rm="$(bash "$TOOL" --remove "$R" 2>&1)"; rc_rm=$?
if [ "$rc_rm" = 0 ]; then ok; else bad "--remove should exit 0, got $rc_rm: ${out_rm:0:600}"; fi
says "the removal of done-kept is named" "REMOVED" "$(row REMOVED done-kept "$out_rm")"
says "the removal of done-deleted is named" "REMOVED" "$(row REMOVED done-deleted "$out_rm")"
if exists "$WT/done-kept"; then bad "done-kept was not removed"; else ok; fi
if exists "$WT/done-deleted"; then bad "done-deleted was not removed"; else ok; fi
# Their local branches go with them, since their pull requests merged.
for b in fix/done-kept fix/done-deleted; do
  if git -C "$R" rev-parse --verify --quiet "refs/heads/$b" >/dev/null; then
    bad "the local branch $b outlived its removed worktree"
  else ok; fi
done
# Every other worktree and its branch is untouched.
for n in dirty unpushed open never reopened locked inuse; do
  if exists "$WT/$n"; then ok; else bad "--remove removed $n, which was not proven safe"; fi
  if git -C "$R" rev-parse --verify --quiet "refs/heads/fix/$n" >/dev/null; then ok
  else bad "--remove deleted the branch fix/$n"; fi
done
if exists "$WT/detached"; then ok; else bad "--remove removed the detached worktree"; fi
# The dirty worktree's unsaved file is still there.
if [ -f "$WT/dirty/notes.txt" ]; then ok; else bad "the dirty worktree lost its untracked file"; fi
# Remote branches are never touched.
if git -C "$BARE" rev-parse --verify --quiet refs/heads/fix/done-kept >/dev/null; then ok
else bad "--remove deleted a remote branch"; fi
# The primary checkout is where it was, on the branch it was on.
if [ "$(git -C "$R" rev-parse --abbrev-ref HEAD)" = "main" ]; then ok
else bad "--remove moved the primary checkout off main"; fi

# The squatter leaves; now the same worktree is removable, which proves case 9 was kept for the
# process and not for something else about it.
kill "$SQUATTER" 2>/dev/null; wait "$SQUATTER" 2>/dev/null; SQUATTER=""
out_after="$(bash "$TOOL" "$R" 2>&1)"
says "with nobody standing in it the same worktree is removable" "#19" "$(row REMOVABLE inuse "$out_after")"

echo "shipped-worktrees: what it refuses"

notrepo="$WORK/not-a-repo"; mkdir -p "$notrepo"
out_nr="$(bash "$TOOL" "$notrepo" 2>&1)"; rc_nr=$?
if [ "$rc_nr" = 2 ]; then ok; else bad "a directory that is not a checkout should exit 2, got $rc_nr"; fi
says "the refusal names what it was given" "not-a-repo" "$out_nr"

out_flag="$(bash "$TOOL" --delete-everything "$R" 2>&1)"; rc_flag=$?
if [ "$rc_flag" = 2 ]; then ok; else bad "an unknown flag should exit 2, got $rc_flag"; fi

# Run from INSIDE a worktree, it still judges the whole checkout rather than a worktree's view of
# it, and the worktree it was run from is kept because the tool itself is standing in it.
out_in="$(cd "$WT/open" && bash "$TOOL" 2>&1)"
says "run from a worktree it still finds the others" ".claude/worktrees/dirty" "$out_in"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
