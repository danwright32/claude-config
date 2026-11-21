#!/usr/bin/env bash
#
# test-shipped-worktrees-git.sh: every git call shipped-worktrees.sh makes in a worktree it is
# judging runs with that worktree's program running settings off (claude-config#3355).
#
# git answers a question about a worktree with that worktree's own configuration, and a setting
# there can name a program git then starts. Each case builds a real repository whose own settings,
# and whose worktree's own config.worktree, name MARKER programs (a marker appends its name to a
# log and exits, nothing else), with the builders payload/hooks/test-judged-worktree.sh uses too
# (payload/hooks/lib/judged-worktree-fixture.sh). The call is first made bare, the way the tool
# wrote it before the fix, and the markers are seen to run, which proves the fixture can catch one
# (L1, L248); then the tool is run, report and --remove, and nothing runs.
#
# It asks the git on this machine, never a stub. GitHub is a stub gh first on PATH, as in
# test-shipped-worktrees.sh, which holds everything else about the tool.

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/shipped-worktrees.sh"
HOOKS="$(cd "$DIR/../payload/hooks" && pwd)"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
finish() {
  echo ""
  echo "passed: $pass, failed: $fail"
  echo "SUITE-RESULT passed=$pass failed=$fail"
  [ "$fail" -eq 0 ]
  exit $?
}
eq() { [ "$1" = "$2" ] && echo ok || echo "expected '$2', got '$1'"; }
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo "'$2' not in: $1"; }
row() { grep -E "^  $1 +\.claude/worktrees/$2( |$)" <<< "$3" || true; } # <verdict> <worktree> <report>

. "$HOOKS/lib/judged-worktree-fixture.sh" || { check "the fixture builders are there to source" "could not source payload/hooks/lib/judged-worktree-fixture.sh"; finish; }
jwf_begin || { check "the fixture sets up: git is on this machine and the harness makes its throwaway directory" "jwf_begin failed"; finish; }
command -v jq >/dev/null 2>&1 || { check "jq is here, which the tool needs to read what gh answers" "no jq on the PATH"; finish; }

# The stub gh: `gh pr list --head <branch> ...` prints the answer written for that branch, or an
# empty list, which is what GitHub says of a branch with no pull request.
mkdir -p "$DC_ROOT/bin" "$DC_ROOT/shim" "$DC_ROOT/gh-answers"
cat > "$DC_ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
head=""
while [ $# -gt 0 ]; do
  case "$1" in --head) head="$2"; shift ;; esac
  shift
done
f="$STUB_DIR/$(printf '%s' "$head" | sed 's#/#__#g').json"
if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
GH
chmod +x "$DC_ROOT/bin/gh"
export STUB_DIR="$DC_ROOT/gh-answers"
# A ps that knows no process, so a lock naming any pid was left by an agent that is gone, and a
# boot before every lock below (lib/agent-lock.sh).
printf '#!/bin/sh\nexit 1\n' > "$DC_ROOT/bin/ps"; chmod +x "$DC_ROOT/bin/ps"
export AGENT_LOCK_PS="$DC_ROOT/bin/ps" AGENT_LOCK_BOOT_EPOCH=1791590400   # Sat Oct 10 00:00:00 2026 UTC
export PATH="$DC_ROOT/bin:$PATH"

R="$F/primary"; WT="$R/.claude/worktrees"
E="$F/elsewhere"
mkrepo "$R" || check "the repository fixture was made" "mkrepo failed"
# The branch things merge into, which the tool reads from the remote's copy of the current branch.
_dc_rgit "$GIT" -C "$R" update-ref refs/remotes/origin/feat-real HEAD
shipped() { # <name> <PR>: a worktree whose branch's pull request merged at its HEAD
  mkwt "$R" "$1" || check "the worktree $1 was made" "mkwt failed"
  printf '[{"number":%s,"state":"MERGED","headRefOid":"%s"}]\n' "$2" "$(_dc_rgit "$GIT" -C "$WT/$1" rev-parse HEAD)" > "$STUB_DIR/fix__$1.json"
}
shipped plain 41; shipped refused 42; shipped equals 43; shipped lied 44
LOCK="claude agent refused (pid 5005 start Thu Oct 15 12:00:00 2026)"
_dc_rgit "$GIT" -C "$R" worktree lock --reason "$LOCK" "$WT/refused"
lockof() { git -C "$R" -c core.fsmonitor=false worktree list --porcelain | awk -v p="worktree $WT/$1" '$0 == p { f = 1; next } /^worktree / { f = 0 } f && /^locked/ { sub(/^locked ?/, ""); print }'; }
# A filter of the worktree's own whose name cannot be turned off for one call, which dc_git refuses.
_dc_rgit "$GIT" -C "$WT/equals" config --worktree 'filter.e=q.clean' "$(dc_marker "$R.markers" "$LOG" filter.equals cat)"
# A git that refuses one removal after its dead agent's lock was lifted, so the run reaches the
# status it asks for before putting the lock back, and that answers for ANOTHER repository when
# asked which one a second worktree belongs to, the moment before its removal.
dc_marker_repo "$GIT" "$E" "$LOG" || check "the other repository was made" "dc_marker_repo failed"
cat > "$DC_ROOT/shim/git" <<SHIM
#!/bin/sh
case " \$* " in
  *" worktree remove "*"/refused ") echo "fatal: simulated refusal" >&2; exit 128 ;;
  *"/lied "*" rev-parse --path-format=absolute --git-common-dir ") echo "$E/.git"; exit 0 ;;
esac
exec "$GIT" "\$@"
SHIM
chmod +x "$DC_ROOT/shim/git"
all=("$WT/plain" "$WT/refused" "$WT/equals" "$WT/lied")

# ================================================================================================
# 1. The report, and --remove, over worktrees whose settings name programs
# ================================================================================================
age "${all[@]}"; : > "$LOG"
git -C "$WT/plain" status --porcelain --untracked-files=all >/dev/null 2>&1
check "the fixture: a bare status in a shipped worktree, as the tool asked for one, runs the repository's and the worktree's programs" \
  "$(eq "$(ran)" "filter.clean fsmonitor hook.post-index-change wt.filter.clean ")"

age "${all[@]}"; : > "$LOG"
out="$(bash "$TOOL" "$R" 2>&1)"; rc=$?
check "the report: no program any judged worktree names ran" "$(eq "$(ran)" nothing)"
check "the report: the shipped worktree is still found removable" "$(has "$(row REMOVABLE plain "$out")" "pull request #41 merged, clean, nothing unpushed")"
check "the report: and so is the one whose lock a gone agent left" "$(has "$(row REMOVABLE refused "$out")" "#42")"
check "the report: a worktree with a filter that cannot be turned off is kept, since its status was not asked for" \
  "$(has "$(row KEEP equals "$out")" "its status could not be read (dc_git: refused: this repository's own configuration names a filter program (filter.e=q.clean)")"
check "the report: it exits 0 and changed nothing" "$(eq "$rc|$(there "$WT/plain")|$(lockof refused)" "0|there|$LOCK")"

age "${all[@]}"; : > "$LOG"
out="$(PATH="$DC_ROOT/shim:$PATH" bash "$TOOL" --remove "$R" 2>&1)"; rc=$?
check "--remove: no program any judged worktree names ran, through the status, the second look, the removal and the refusal" "$(eq "$(ran)" nothing)"
check "--remove: the shipped worktree and its local branch are removed" \
  "$(eq "$(has "$(row REMOVED plain "$out")" "worktree and local branch removed")|$(there "$WT/plain")|$(listed "$R" "$WT/plain")" "ok|gone|0")"
check "--remove: a removal git refuses is said in git's words" "$(has "$(row "NOT DONE" refused "$out")" "git refused: fatal: simulated refusal")"
check "--remove: the refused worktree is whole, and its lock is put back as it was found" "$(eq "$(there "$WT/refused/a.txt")|$(lockof refused)" "there|$LOCK")"
check "--remove: a folder that answers for another repository the moment before its removal is not removed, and the run says its removal was not tried" \
  "$(has "$(row "NOT DONE" lied "$out")" "its removal was not tried: jw_remove: refused: in $WT/lied git answers for another repository ($E/.git)")"
check "--remove: that folder is whole" "$(eq "$(there "$WT/lied/a.txt")" there)"
check "--remove: the worktree whose status was not asked for is kept" "$(eq "$(there "$WT/equals/a.txt")" there)"
check "--remove: it exits 1, two removals not having happened" "$(eq "$rc" 1)"

# ================================================================================================
# 2. Which commits are pushed, in a repository that says a missing commit can be fetched, with a
#    program as the fetcher
# ================================================================================================
L="$F/lazy"; LW="$L/.claude/worktrees"
mkrepo "$L" || check "the partial clone fixture was made" "mkrepo failed"
_dc_rgit "$GIT" -C "$L" update-ref refs/remotes/origin/feat-real HEAD
mkwt "$L" far || check "its worktree was made" "mkwt failed"
# The commit its HEAD names is the one missing. git fetches a missing commit a command NAMES; one
# it only walks to, a parent, it fails on without fetching (measured 2026-11-21, git 2.51.1).
gone="$(_dc_rgit "$GIT" -C "$LW/far" rev-parse HEAD)"
_dc_rgit "$GIT" -C "$L" config core.repositoryformatversion 1
_dc_rgit "$GIT" -C "$L" config extensions.partialClone origin
_dc_rgit "$GIT" -C "$L" config remote.origin.promisor true
_dc_rgit "$GIT" init --bare "$F/lazy-origin" >/dev/null
_dc_rgit "$GIT" -C "$L" config remote.origin.url "$F/lazy-origin"
_dc_rgit "$GIT" -C "$L" config remote.origin.uploadpack "$(dc_marker "$L.markers" "$LOG" remote.uploadpack)"
rm -f "$L/.git/objects/${gone:0:2}/${gone:2}"
check "the fixture lacks the commit its worktree's HEAD names" "$([ -n "$gone" ] && [ ! -e "$L/.git/objects/${gone:0:2}/${gone:2}" ] && echo ok || echo "the commit is still there")"
: > "$LOG"
git -C "$LW/far" rev-list --count HEAD --not origin/feat-real >/dev/null 2>&1 </dev/null
check "the fixture: the bare rev-list the tool asked with runs the repository's fetch program" "$(has "$(ran)" "remote.uploadpack")"
age "$LW/far"; : > "$LOG"
out="$(bash "$TOOL" "$L" 2>&1)"; rc=$?
check "a worktree missing a commit: no program ran, so nothing was fetched" "$(eq "$(ran)" nothing)"
check "a worktree missing a commit: it is kept, since which of its commits are pushed could not be read" \
  "$(has "$(row KEEP far "$out")" "which of its commits are pushed could not be read")"
check "a worktree missing a commit: and neither could its status, which says why" "$(has "$(row KEEP far "$out")" "its status could not be read (")"

# ================================================================================================
# 3. The tool's source: every git call it makes in a worktree goes through dc_git or jw_remove
# ================================================================================================
# Each call of git written outside dc_git must be git run in the REPOSITORY, about its own records:
# one of these forms and no other. A status, a rev-list or a worktree remove is on the list in no
# form.
SHIPPED_FORMS='git -C "\$(repo|primary)" (rev-parse|worktree (list|lock|unlock)|cat-file|branch) '
if [ -n "$PY" ]; then
  check "shipped-worktrees.sh runs plain git only in the repository, about its own records" "$(eq "$(plain_git "$TOOL" "$SHIPPED_FORMS")" "")"
  check "and asks about a worktree through dc_git, in each of the three places it asks" "$(eq "$(calls "$TOOL" dc_git)" 3)"
  check "and removes a worktree through jw_remove, in the one place it removes one" "$(eq "$(calls "$TOOL" jw_remove)" 1)"
  # The reading can fail: a copy with one call written bare again is caught, by its line.
  sed 's/dc_git "\$1" status --porcelain --untracked-files=all/git -C "$1" status --porcelain --untracked-files=all/' "$TOOL" > "$DC_ROOT/shipped-worktrees.sh"
  check "and a copy with the status written bare again is caught" "$(has "$(plain_git "$DC_ROOT/shipped-worktrees.sh" "$SHIPPED_FORMS")" 'git -C "$1" status --porcelain --untracked-files=all')"
  sed 's/jw_remove "\$primary" "\$real" 2>&1)"; rrc=/git -C "$primary" worktree remove "$real" 2>\&1)"; rrc=/' "$TOOL" > "$DC_ROOT/shipped-worktrees.sh"
  check "and so is a copy with the removal written bare again, though it names the repository" "$(has "$(plain_git "$DC_ROOT/shipped-worktrees.sh" "$SHIPPED_FORMS")" 'git -C "$primary" worktree remove "$real"')"
  sed 's/dc_git "\$real" rev-list --count/git -C "$real" rev-list --count/' "$TOOL" > "$DC_ROOT/shipped-worktrees.sh"
  check "and a copy with the rev-list written bare again" "$(has "$(plain_git "$DC_ROOT/shipped-worktrees.sh" "$SHIPPED_FORMS")" 'git -C "$real" rev-list --count')"
else
  check "python3 is here, so the tool's source can be read for its git calls" "no python3 on the PATH"
fi

finish
