#!/usr/bin/env bash
# Tests for lib/judged-worktree.sh, and for every git call check-stale-worktrees.sh makes in a
# worktree it is judging (claude-config#3355). tools/test-shipped-worktrees-git.sh holds
# tools/shipped-worktrees.sh to the same, with the same fixture builders
# (lib/judged-worktree-fixture.sh).
#
# git answers a question about a worktree with that worktree's own configuration, and a setting
# there can name a program git then starts. So a sweep that only decides whether a worktree's work
# has landed could run a program nobody chose. Each case here builds a real repository whose own
# settings, and whose worktree's own config.worktree, name MARKER programs (a marker appends its
# name to a log and exits, nothing else). The call is first made the way the tools wrote it before
# the fix and the markers are seen to run, which proves the fixture can catch one (L1, L248); then
# it is made the way they write it now, and nothing runs and git's answer is the same.
#
# It asks the git on this machine, never a stub: what a setting does is git's to say. Everything is
# inside the disk-clean harness's throwaway directory, with no configuration read but the
# fixture's own.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/check-stale-worktrees.sh"

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

. "$DIR/lib/judged-worktree-fixture.sh" || { check "the fixture builders are there to source" "could not source lib/judged-worktree-fixture.sh"; finish; }
jwf_begin || { check "the fixture sets up: git is on this machine and the harness makes its throwaway directory" "jwf_begin failed"; finish; }

# ================================================================================================
# 1. A status, as both tools ask for one
# ================================================================================================
R="$F/repo"; WT="$R/.claude/worktrees"
mkrepo "$R" || check "the repository fixture was made" "mkrepo failed"
for n in s-bare s-safe r-bare r-top r-safe r-dirty f-bare f-safe g-bare g-safe nogit x-bare x-main x-safe planted; do
  mkwt "$R" "$n" || check "the worktree $n was made" "mkwt failed"
done
check "the worktrees were made, each with a configuration of its own" \
  "$(eq "$(git -C "$WT/s-bare" -c core.fsmonitor=false config --worktree --get-regexp '^filter\.wtonly\.clean$' | wc -l | tr -d ' ')|$(there "$WT/planted/.git")" "1|there")"

age "$WT/s-bare"; : > "$LOG"
bare="$(ans git -C "$WT/s-bare" status --porcelain --untracked-files=all)"
seen="$(ran)"
check "status in a worktree, called bare as both tools did: the repository's fsmonitor program ran" "$(has "$seen" "fsmonitor ")"
check "status, called bare: the repository's filter program ran" "$(has " $seen" " filter.clean ")"
check "status, called bare: the filter only the worktree's own configuration names ran" "$(has "$seen" "wt.filter.clean ")"
check "status, called bare: the post-index-change hook ran" "$(has "$seen" "hook.post-index-change ")"
age "$WT/s-safe"; : > "$LOG"
safe="$(ans dc_git "$WT/s-safe" status --porcelain --untracked-files=all)"
check "status through dc_git, as the tools ask now: no program the worktree names ran" "$(eq "$(ran)" nothing)"
check "status through dc_git: a clean worktree is still clean, exit 0 and no line" "$(eq "$safe" "0|")"
check "status: the answer is the one the bare call gave" "$(eq "$safe" "$bare")"
age "$WT/s-safe"
safe="$(ans dc_git "$WT/s-safe" status --porcelain)"
check "status --porcelain alone, as the finisher asks: clean, and nothing ran" "$(eq "$safe|$(ran)" "0||nothing")"
rm -f "$WT/s-safe/b.md"; printf 'n\n' > "$WT/s-safe/new.md"; age "$WT/s-safe"
safe="$(ans dc_git "$WT/s-safe" status --porcelain --untracked-files=all)"
check "status through dc_git: a deleted file and an untracked one are both reported" "$(eq "$safe" "0| D b.md"$'\n'"?? new.md")"
check "status through dc_git: and nothing ran for a worktree with changes either" "$(eq "$(ran)" nothing)"

# ================================================================================================
# 2. jw_remove: worktree remove with the worktree's settings off
# ================================================================================================
. "$DIR/lib/judged-worktree.sh" 2>/dev/null
check "jw_remove is defined by lib/judged-worktree.sh" "$(declare -F jw_remove >/dev/null && echo ok || echo "no such function")"
if declare -F jw_remove >/dev/null; then
  age "$WT/r-bare"; : > "$LOG"
  bare="$(ans git -C "$R" worktree remove "$WT/r-bare")"
  seen="$(ran)"
  check "worktree remove, called bare from the repository as both tools did: fsmonitor ran" "$(has "$seen" "fsmonitor ")"
  check "worktree remove, called bare: the repository's filter ran" "$(has " $seen" " filter.clean ")"
  check "worktree remove, called bare: the worktree's own filter ran" "$(has "$seen" "wt.filter.clean ")"
  check "worktree remove, called bare: the post-index-change hook ran" "$(has "$seen" "hook.post-index-change ")"
  check "worktree remove, called bare: it removed the clean worktree" "$(eq "${bare%%|*}|$(there "$WT/r-bare")" "0|gone")"
  # Why git is run in the worktree: given the repository's folder, dc_git reads the main checkout's
  # settings, and the filter only the worktree names is not among them.
  age "$WT/r-top"; : > "$LOG"
  top="$(ans dc_git "$R" worktree remove "$WT/r-top")"
  check "worktree remove through dc_git run in the REPOSITORY's folder: the worktree's own filter still ran" "$(eq "$(ran)" "wt.filter.clean ")"
  age "$WT/r-safe"; : > "$LOG"
  safe="$(ans jw_remove "$R" "$WT/r-safe")"
  check "jw_remove: no program the repository or the worktree names ran" "$(eq "$(ran)" nothing)"
  check "jw_remove: git removed the clean worktree" "$(eq "${safe%%|*}|$(there "$WT/r-safe")|$(listed "$R" "$WT/r-safe")" "0|gone|0")"
  printf 'unsaved\n' > "$WT/r-dirty/notes.md"; age "$WT/r-dirty"; : > "$LOG"
  safe="$(ans jw_remove "$R" "$WT/r-dirty")"
  check "jw_remove: git still refuses a worktree with an untracked file" "$(eq "${safe%%|*}|$(cat "$WT/r-dirty/notes.md" 2>/dev/null)" "128|unsaved")"
  check "jw_remove: and says why, as git does" "$(has "$(cat "$DC_ROOT/err")" "contains modified or untracked files")"
  check "jw_remove: nothing ran for the refused one" "$(eq "$(ran)" nothing)"

  # --force, which the finisher of a removal cut off part way passes: git asks for no status.
  printf 'x\n' > "$WT/f-bare/left.md"; printf 'x\n' > "$WT/f-safe/left.md"; age "$WT/f-bare" "$WT/f-safe"; : > "$LOG"
  bare="$(ans git -C "$R" worktree remove --force "$WT/f-bare")"
  check "worktree remove --force, called bare: nothing ran, since git asks for no status" "$(eq "$(ran)" nothing)"
  safe="$(ans jw_remove "$R" "$WT/f-safe" --force)"
  check "jw_remove --force: nothing ran" "$(eq "$(ran)" nothing)"
  check "jw_remove --force: it removed the worktree, as the bare call removed its own" \
    "$(eq "${safe%%|*}|$(there "$WT/f-safe")|${bare%%|*}|$(there "$WT/f-bare")" "0|gone|0|gone")"

  # A worktree whose folder is gone: git only drops its record.
  rm -rf "$WT/g-bare" "$WT/g-safe"; : > "$LOG"
  bare="$(ans git -C "$R" worktree remove "$WT/g-bare")"
  check "worktree remove of a folder that is gone, called bare: nothing ran" "$(eq "$(ran)" nothing)"
  safe="$(ans jw_remove "$R" "$WT/g-safe")"
  check "jw_remove of a folder that is gone: nothing ran" "$(eq "$(ran)" nothing)"
  check "jw_remove of a folder that is gone: git drops its record, as the bare call did" \
    "$(eq "${safe%%|*}|$(listed "$R" "$WT/g-safe")|${bare%%|*}|$(listed "$R" "$WT/g-bare")" "0|0|0|0")"

  # A folder whose .git is gone: git answers there for the repository around it, and refuses.
  rm -f "$WT/nogit/.git"; : > "$LOG"
  safe="$(ans jw_remove "$R" "$WT/nogit")"
  check "jw_remove of a worktree whose .git is gone: git refuses it, and the folder stays" "$(eq "${safe%%|*}|$(there "$WT/nogit/a.txt")" "128|there")"
  check "jw_remove of a worktree whose .git is gone: in git's own words" "$(has "$(cat "$DC_ROOT/err")" "validation failed")"
  check "jw_remove of a worktree whose .git is gone: nothing ran" "$(eq "$(ran)" nothing)"

  # A folder git lists for this repository whose .git now names ANOTHER repository's worktree
  # record. Run in that folder, git removes it through the other repository; asked from the listing
  # repository, as both tools asked before, git refuses. jw_remove must refuse too.
  O="$F/other"
  dc_marker_repo "$GIT" "$O" "$LOG" || check "the second repository was made" "dc_marker_repo failed"
  for n in o1 o2 o3; do _dc_rgit "$GIT" -C "$O" worktree add -b "side-$n" "$F/other-$n" >/dev/null; done
  swap "$WT/x-bare" "$O" other-o1; swap "$WT/x-main" "$O" other-o2; swap "$WT/x-safe" "$O" other-o3
  check "the swapped folders answer for the other repository" \
    "$(eq "$(dc_git "$WT/x-safe" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" "$O/.git")"
  age "$WT/x-bare" "$WT/x-main" "$WT/x-safe"; : > "$LOG"
  bare="$(ans dc_git "$WT/x-bare" worktree remove "$WT/x-bare")"
  check "worktree remove run in a folder that answers for another repository, with no check: git removes it through that one" \
    "$(eq "${bare%%|*}|$(there "$WT/x-bare")|$(listed "$R" "$WT/x-bare")" "0|gone|1")"
  bare="$(ans git -C "$R" -c core.fsmonitor=false worktree remove "$WT/x-main")"
  check "the same asked from the listing repository, as the tools did before: git refuses, and the folder stays" \
    "$(eq "${bare%%|*}|$(there "$WT/x-main")" "128|there")"
  : > "$LOG"
  safe="$(ans jw_remove "$R" "$WT/x-safe")"
  check "jw_remove of a folder that answers for another repository: refused, and the folder stays" "$(eq "${safe%%|*}|$(there "$WT/x-safe/a.txt")" "125|there")"
  check "jw_remove: the refusal says which repository answers there" "$(has "$(cat "$DC_ROOT/err")" "jw_remove: refused: in $WT/x-safe git answers for another repository ($O/.git)")"
  check "jw_remove: nothing ran for it" "$(eq "$(ran)" nothing)"
  # A whole repository planted at the path.
  rm -f "$WT/planted/.git"; _dc_rgit "$GIT" init "$WT/planted" >/dev/null; : > "$LOG"
  safe="$(ans jw_remove "$R" "$WT/planted")"
  check "jw_remove of a folder holding a repository of its own: refused, and the folder stays" "$(eq "${safe%%|*}|$(there "$WT/planted/a.txt")" "125|there")"
  check "jw_remove: nothing ran for that one" "$(eq "$(ran)" nothing)"

  # What it refuses before git is asked anything.
  refused() { # <words of the reason> <jw_remove arguments...>
    local want="$1" got
    shift
    got="$(ans jw_remove "$@")"
    check "jw_remove $* is refused with exit 125" "$(eq "${got%%|*}" 125)"
    check "jw_remove $*: the refusal says why" "$(has "$(cat "$DC_ROOT/err")" "jw_remove: refused: $want")"
  }
  refused "it takes the repository's folder, the worktree and at most --force" "$R"
  refused "it takes the repository's folder, the worktree and at most --force" "$R" "$WT/r-dirty" --force extra
  refused "it takes the repository's folder, the worktree and at most --force" "" "$WT/r-dirty"
  refused "-f is not an option it passes to worktree remove" "$R" "$WT/r-dirty" -f
  refused ".claude/worktrees/r-dirty is not an absolute path" "$R" ".claude/worktrees/r-dirty"
  check "and none of those removed anything" "$(eq "$(cat "$WT/r-dirty/notes.md" 2>/dev/null)|$(ran)" "unsaved|nothing")"

  # A status that fails says why, once, on one line.
  printf 'not an index\n' > "$R/.git/worktrees/r-dirty/index"
  why="$(jw_status_why "$WT/r-dirty" --untracked-files=all)"
  check "jw_status_why: a status git cannot give comes back with git's reason" "$(has "$why" "index")"
  check "jw_status_why: on one line" "$(eq "$(printf '%s\n' "$why" | wc -l | tr -d ' ')" 1)"
  check "jw_status_why: and says nothing of a status that works" "$(eq "$(jw_status_why "$WT/x-safe")" "")"

  # One helper and one list of settings: the library runs git nowhere but through dc_git.
  if [ -n "$PY" ]; then
    scan="$(_jwf_read "$DIR/lib/judged-worktree.sh")"
    check "lib/judged-worktree.sh, and the library it sources, call git nowhere but inside dc_git" "$(eq "$(grep "^fail${TAB}git${TAB}" <<< "$scan" | cut -f 3,4)" "")"
    check "and the reader did read it, finding its calls of dc_git and the git calls inside dc_git" \
      "$(eq "$([ "$(grep -c "^function${TAB}dc_git${TAB}.*judged-worktree\.sh:" <<< "$scan")" -ge 3 ] && echo read)|$([ "$(grep -c "^stub${TAB}git${TAB}.*disk-clean-predicates\.sh:" <<< "$scan")" -ge 3 ] && echo followed)" "read|followed")"
    check "and read every line of it as bash" "$(eq "$(grep "could not be read" <<< "$scan" | cut -f 3,4)" "")"
  else
    check "python3 is here, so the library's source can be read for its git calls" "no python3 on the PATH"
  fi
  check "the settings are written once, in lib/disk-clean-predicates.sh" \
    "$(eq "$(grep -l 'DC_GIT_FIXED=' "$DIR"/lib/*.sh | sed 's|.*/||' | tr '\n' ' ')" "disk-clean-predicates.sh ")"
fi

# ================================================================================================
# 3. check-stale-worktrees.sh: a whole run, report and --remove, over worktrees whose settings
#    name programs
# ================================================================================================
mkdir -p "$DC_ROOT/bin" "$DC_ROOT/shim"
cat > "$DC_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" --state open "*|*" --state closed "*) exit 0 ;;
  *) cat "$GH_MERGED" ;;
esac
STUB
chmod +x "$DC_ROOT/bin/gh"
export GH_MERGED="$DC_ROOT/merged.tsv"; : > "$GH_MERGED"
# The Mac's own sleep record and session registry are never read (#2943).
export CLAUDE_SLEEP_RECORD="$DC_ROOT/sleep/current.json" CLAUDE_SESSION_REGISTRY_DIR="$DC_ROOT/sessions"
# A git that refuses one removal, so the run reaches the status it asks for after a refusal.
printf '#!/bin/sh\ncase " $* " in *" worktree remove "*"/refused ") echo "fatal: simulated refusal" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' "$GIT" > "$DC_ROOT/shim/git"
chmod +x "$DC_ROOT/shim/git"

T="$F/sweep"; TW="$T/.claude/worktrees"; MARKS="$T/.git/claude-worktree-removing"
mkrepo "$T" || check "the sweep's repository was made" "mkrepo failed"
landed() { # <name> <PR>: a worktree whose branch's PR merged at its HEAD
  mkwt "$T" "$1" || check "the worktree $1 was made" "mkwt failed"
  printf 'fix/%s\t%s\t%s\n' "$1" "$(_dc_rgit "$GIT" -C "$TW/$1" rev-parse HEAD)" "$2" >> "$GH_MERGED"
}
landed landed 601; landed refused 602; landed cut 603; landed cut-unread 604; landed equals 605; landed elsewhere 606
# Two removals an earlier run started and never finished: one with nothing but a deletion in it, and
# one changed since whose status git can no longer give.
mkdir -p "$MARKS"
printf '%s\n' "$TW/cut" > "$MARKS/cut"; rm -f "$TW/cut/b.md"
printf '%s\n' "$TW/cut-unread" > "$MARKS/cut-unread"; printf 'somebody wrote this since\n' > "$TW/cut-unread/a.txt"
printf 'not an index\n' > "$T/.git/worktrees/cut-unread/index"
# A filter of the worktree's own whose name cannot be turned off for one call, which dc_git refuses.
_dc_rgit "$GIT" -C "$TW/equals" config --worktree 'filter.e=q.clean' "$(dc_marker "$T.markers" "$LOG" filter.equals cat)"
# A folder git lists here that answers for another repository, and is clean there.
E="$F/elsewhere"
dc_marker_repo "$GIT" "$E" "$LOG" || check "the repository the swapped worktree answers for was made" "dc_marker_repo failed"
_dc_rgit "$GIT" -C "$E" worktree add -b side "$F/elsewhere-wt" >/dev/null
swap "$TW/elsewhere" "$E" elsewhere-wt
srun() { OUT="$(STALE_WT_GH="$DC_ROOT/bin/gh" bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }
all=("$TW/landed" "$TW/refused" "$TW/cut" "$TW/cut-unread" "$TW/equals" "$TW/elsewhere")

age "${all[@]}"; : > "$LOG"
git -C "$TW/landed" status --porcelain --untracked-files=all >/dev/null 2>&1
seen="$(ran)"
check "the sweep's fixture: a bare status in a landed worktree runs the repository's and the worktree's programs" \
  "$(eq "$seen" "filter.clean fsmonitor hook.post-index-change wt.filter.clean ")"

age "${all[@]}"; : > "$LOG"
srun "$T"
seen="$(ran)"
check "the report: no program any judged worktree names ran" "$(eq "$seen" nothing)"
check "the report: the landed worktree is still named, with why" "$(has "$OUT" "STALE landed [fix/landed]: PR #601 merged")"
check "the report: and so is the second one" "$(has "$OUT" "STALE refused [fix/refused]: PR #602 merged")"
check "the report: a removal cut off part way is named" "$(has "$OUT" "CUT OFF cut [fix/cut]")"
check "the report: a worktree with a filter that cannot be turned off is kept, since its status was not asked for" \
  "$(has "$OUT" "keeping equals [fix/equals]: git could not read its status, so whether anything in it is uncommitted cannot be told")"
check "the report: and says it was dc_git that refused, and why" "$(has "$OUT" "dc_git: refused: this repository's own configuration names a filter program (filter.e=q.clean)")"
check "the report: it exits 1, having something to say" "$(eq "$RC" 1)"
check "the report: it removed nothing" "$(eq "$(there "$TW/landed")$(there "$TW/cut")" "therethere")"

age "${all[@]}"; : > "$LOG"
OUT="$(PATH="$DC_ROOT/shim:$PATH" STALE_WT_GH="$DC_ROOT/bin/gh" bash "$SCRIPT" --remove "$T" 2>&1)"; RC=$?
seen="$(ran)"
check "--remove: no program any judged worktree names ran, through the status, the removal, the finisher and the refusal" "$(eq "$seen" nothing)"
check "--remove: the landed worktree is removed" "$(eq "$(has "$OUT" "removed landed [fix/landed]: PR #601 merged")|$(there "$TW/landed")|$(listed "$T" "$TW/landed")" "ok|gone|0")"
check "--remove: the removal cut off with nothing but a deletion in it is finished" \
  "$(eq "$(has "$OUT" "finished removing cut [fix/cut]")|$(there "$TW/cut")|$(there "$MARKS/cut")" "ok|gone|gone")"
check "--remove: a cut off removal whose status git cannot give is kept, never forced" \
  "$(has "$OUT" "keeping cut-unread [fix/cut-unread]: an earlier removal of it was cut off part way, and git could not read its status now")"
check "--remove: with what somebody wrote in it since" "$(eq "$(cat "$TW/cut-unread/a.txt" 2>/dev/null)" "somebody wrote this since")"
check "--remove: and its marker stays, for the run that can read it" "$(eq "$(there "$MARKS/cut-unread")" there)"
check "--remove: a removal git refuses is said in git's words" "$(has "$OUT" "keeping refused [fix/refused]: git would not remove it: fatal: simulated refusal")"
check "--remove: the refused worktree is whole, and its marker is cleared" "$(eq "$(there "$TW/refused/a.txt")|$(there "$MARKS/refused")" "there|gone")"
check "--remove: a folder that answers for another repository is not removed, and the run says its removal was not tried" \
  "$(has "$OUT" "keeping elsewhere [fix/elsewhere]: its removal was not tried: jw_remove: refused: in $TW/elsewhere git answers for another repository")"
check "--remove: that folder is whole, and its marker is cleared" "$(eq "$(there "$TW/elsewhere/a.txt")|$(there "$MARKS/elsewhere")" "there|gone")"
check "--remove: the worktree whose status was not asked for is kept" "$(eq "$(there "$TW/equals/a.txt")" there)"

# ================================================================================================
# 4. check-stale-worktrees.sh's source: every git call it makes in a worktree goes through dc_git
#    or jw_remove
# ================================================================================================
# Each call of git written outside dc_git must be git run in the REPOSITORY, about its own records:
# one of these forms and no other. A status or a worktree remove is on the list in no form, since
# either runs in a worktree whatever folder it names.
STALE_FORMS='git -C "\$(top|REPO)" (rev-parse|worktree (list|lock|unlock)|remote|reflog|log|merge-base|rev-list) |cd "\$top" && cd "\$\(git rev-parse --git-common-dir '
if [ -n "$PY" ]; then
  check "check-stale-worktrees.sh runs plain git only in the repository, about its own records" "$(eq "$(plain_git "$SCRIPT" "$STALE_FORMS")" "")"
  check "and asks for a worktree's status through dc_git, in each of the three places it asks" "$(eq "$(calls "$SCRIPT" dc_git)" 3)"
  check "and removes a worktree through jw_remove, in both places it removes one" "$(eq "$(calls "$SCRIPT" jw_remove)" 2)"
  # The reading can fail: a copy with one status written bare again is caught, by its line.
  sed 's/dc_git "\$p" status --porcelain --untracked-files=all/git -C "$p" status --porcelain --untracked-files=all/' "$SCRIPT" > "$DC_ROOT/check-stale-worktrees.sh"
  check "and a copy with one status written bare again is caught" "$(has "$(plain_git "$DC_ROOT/check-stale-worktrees.sh" "$STALE_FORMS")" 'git -C "$p" status --porcelain --untracked-files=all')"
  sed 's/jw_remove "\$top" "\$p" 2>&1)"; rrc=/git -C "$top" worktree remove "$p" 2>\&1)"; rrc=/' "$SCRIPT" > "$DC_ROOT/check-stale-worktrees.sh"
  check "and so is a copy with the removal written bare again, though it names the repository" "$(has "$(plain_git "$DC_ROOT/check-stale-worktrees.sh" "$STALE_FORMS")" 'git -C "$top" worktree remove "$p"')"
else
  check "python3 is here, so the script's source can be read for its git calls" "no python3 on the PATH"
fi

finish
