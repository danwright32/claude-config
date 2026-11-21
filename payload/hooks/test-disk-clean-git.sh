#!/usr/bin/env bash
# Tests for dc_git (lib/disk-clean-predicates.sh), the one way a disk-clean script runs git in a
# folder it is judging (claude-config#3328).
#
# git runs every command with the repository's own configuration, and a setting there can name a
# program git then starts. So a read only scan of a copied or planted repository could run a program
# nobody chose. Each case here builds a real repository whose own settings name MARKER programs (a
# marker appends its name to a log and exits, nothing else), runs the command the way the scripts
# wrote it before the fix and sees the marker run, which proves the fixture can catch it (L1, L248),
# then runs the same command through dc_git and sees that nothing ran and the answer is the same.
#
# It asks the git on this machine, never a stub: what a setting does is git's to say. Everything is
# inside the harness's throwaway directory, with no configuration read but the fixture's own.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
hasnt() { grep -qF -- "$2" <<< "$1" && echo "'$2' should not be in: $1" || echo ok; }

. "$DIR/lib/disk-clean-harness.sh" || { check "the harness is there to source" "could not source it"; finish; }
check "dc_git is defined by lib/disk-clean-predicates.sh" "$(declare -F dc_git >/dev/null && echo ok || echo "no such function")"
declare -F dc_git >/dev/null || finish
GIT="$(command -v git 2>/dev/null)" || GIT=""
[ -n "$GIT" ] || { check "git is on this machine, so the settings can be measured" "no git on the PATH"; finish; }
dc_setup || { check "the harness sets up" "dc_setup failed"; finish; }

# No configuration but a fixture's own: an empty home, no system file, and a global file this suite
# writes, which stands for the user's own choices in one case below.
H="$DC_HOME"
export HOME="$H" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$DC_ROOT/global.gitconfig"
: > "$GIT_CONFIG_GLOBAL"
LOG="$DC_ROOT/markers.log"; : > "$LOG"
F="$H/fx"; mkdir -p "$F"
ran() { dc_markers_ran "$LOG"; }
# Git must compare a file's contents again, which is when it runs a filter: a new time, the same
# bytes. <stamp> differs on each call so no earlier reading answers for this one (L480).
STAMP=0
restat() { STAMP=$((STAMP + 1)); touch -t "$(printf '2030010100%02d' "$STAMP")" "$@"; }
# The exit code and output of a command, as "code|output", stderr kept apart in $DC_ROOT/err.
ans() { local o; o="$("$@" 2> "$DC_ROOT/err" </dev/null)"; printf '%s|%s' "$?" "$o"; }

# ================================================================================================
# 1. A full clone: what each command ran before, and what it runs through dc_git
# ================================================================================================
dc_marker_repo "$GIT" "$F/clone" "$LOG" || check "the clone fixture was made" "dc_marker_repo failed"
C="$F/clone"
check "the fixture's own configuration names the marker programs" \
  "$(eq "$(git -C "$C" config --local --get-regexp '^(core\.fsmonitor|filter\.mark\.clean|gpg\.program)$' | wc -l | tr -d ' ')" 3)"
: > "$LOG"

restat "$C/a.txt"
bare="$(ans git -C "$C" --no-optional-locks status --porcelain --untracked-files=all)"
seen="$(ran)"
check "status, called bare as the scan did: the repository's fsmonitor program ran" "$(has "$seen" "fsmonitor")"
check "status, called bare: and its filter program ran" "$(has "$seen" "filter.clean")"
restat "$C/a.txt"
safe="$(ans dc_git "$C" --no-optional-locks status --porcelain --untracked-files=all)"
check "status through dc_git: no program the repository names ran" "$(eq "$(ran)" nothing)"
check "status through dc_git: a clean checkout is still clean, exit 0 and no line" "$(eq "$safe" "0|")"
check "status: the answer is the one the bare call gave" "$(eq "$safe" "$bare")"

printf 'more\n' >> "$C/a.txt"; printf 'n\n' > "$C/new.md"
bare="$(ans git -C "$C" --no-optional-locks status --porcelain --untracked-files=all)"; : > "$LOG"
safe="$(ans dc_git "$C" --no-optional-locks status --porcelain --untracked-files=all)"
check "status through dc_git: an uncommitted change and an untracked file are both reported" \
  "$(eq "$safe" "0| M a.txt"$'\n'"?? new.md")"
check "status: and that is what the bare call reported" "$(eq "$safe" "$bare")"
check "status through dc_git: nothing ran for a dirty checkout either" "$(eq "$(ran)" nothing)"
rm -f "$C/new.md"; _dc_rgit "$GIT" -C "$C" checkout -q -- a.txt
# One commit on another branch that no remote has, which is what the rev-list question counts.
_dc_rgit "$GIT" -C "$C" checkout -q -b side; _dc_rgit "$GIT" -C "$C" commit -q --allow-empty -m side; _dc_rgit "$GIT" -C "$C" checkout -q feat-real
: > "$LOG"

for q in "symbolic-ref --short -q HEAD" "rev-parse HEAD" "remote get-url origin" "rev-parse --absolute-git-dir" \
  "rev-list --count --branches --tags --not --remotes HEAD" "stash list"; do
  # shellcheck disable=SC2086
  bare="$(ans git -C "$C" $q)"; : > "$LOG"
  # shellcheck disable=SC2086
  safe="$(ans dc_git "$C" $q)"
  check "$q through dc_git answers as the bare call does" "$(eq "$safe" "$bare")"
  check "$q through dc_git: nothing ran" "$(eq "$(ran)" nothing)"
  check "$q: and the answer is a real one (exit 0)" "$(eq "${safe%%|*}" 0)"
done
check "the branch, the remote and the count are the fixture's" \
  "$(eq "$(dc_git "$C" symbolic-ref --short -q HEAD)|$(dc_git "$C" remote get-url origin)|$(dc_git "$C" rev-list --count --branches --tags --not --remotes HEAD)" "feat-real|https://github.com/dan/repo.git|1")"
check "and with that side branch gone the count is none" \
  "$(_dc_rgit "$GIT" -C "$C" branch -q -D side; eq "$(dc_git "$C" rev-list --count --branches --tags --not --remotes HEAD)" 0)"

# ================================================================================================
# 2. stash list over a stash whose commit carries a signature: gpg.program
# ================================================================================================
dc_marker_signed_stash "$GIT" "$C" || check "the signed stash fixture was made" "dc_marker_signed_stash failed"
: > "$LOG"
bare="$(ans git -C "$C" stash list)"
check "stash list, called bare: the repository's gpg program ran" "$(has "$(ran)" "gpg.program")"
safe="$(ans dc_git "$C" stash list)"
check "stash list through dc_git: nothing ran" "$(eq "$(ran)" nothing)"
check "stash list through dc_git: the stash is still listed" "$(has "$safe" "0|stash@{0}: ")"
check "stash list through dc_git: exactly one stash" "$(eq "$(printf '%s\n' "${safe#*|}" | grep -c '^stash@')" 1)"

# ================================================================================================
# 3. A worktree, removed as the remover removes one: the post-index-change hook too
# ================================================================================================
dc_marker_repo "$GIT" "$F/main" "$LOG" || check "the worktree fixture was made" "dc_marker_repo failed"
_dc_rgit "$GIT" -C "$F/main" worktree add "$F/wt-bare" -b side-a >/dev/null
_dc_rgit "$GIT" -C "$F/main" worktree add "$F/wt-safe" -b side-b >/dev/null
_dc_rgit "$GIT" -C "$F/main" worktree add "$F/wt-dirty" -b side-c >/dev/null
check "the worktrees were made" "$([ -f "$F/wt-bare/.git" ] && [ -f "$F/wt-safe/.git" ] && [ -f "$F/wt-dirty/.git" ] && echo ok || echo "git did not make them")"
restat "$F/wt-bare/a.txt" "$F/wt-safe/a.txt" "$F/wt-dirty/a.txt"; : > "$LOG"
bare="$(ans git -C "$F/wt-bare" worktree remove "$F/wt-bare")"
seen="$(ran)"
check "worktree remove, called bare as the remover did: fsmonitor ran" "$(has "$seen" "fsmonitor")"
check "worktree remove, called bare: the filter ran" "$(has "$seen" "filter.clean")"
check "worktree remove, called bare: the post-index-change hook ran" "$(has "$seen" "hook.post-index-change")"
safe="$(ans dc_git "$F/wt-safe" worktree remove "$F/wt-safe")"
check "worktree remove through dc_git: nothing ran" "$(eq "$(ran)" nothing)"
check "worktree remove through dc_git: git removed the clean worktree" "$(eq "${safe%%|*}|$([ -e "$F/wt-safe" ] && echo there || echo gone)" "0|gone")"
check "worktree remove: as the bare call removed its own" "$(eq "${bare%%|*}|$([ -e "$F/wt-bare" ] && echo there || echo gone)" "0|gone")"
printf 'unsaved\n' > "$F/wt-dirty/notes.md"
safe="$(ans dc_git "$F/wt-dirty" worktree remove "$F/wt-dirty")"
check "worktree remove through dc_git: git still refuses a worktree with an untracked file" \
  "$(eq "${safe%%|*}|$([ -f "$F/wt-dirty/notes.md" ] && echo there || echo gone)" "128|there")"
check "worktree remove through dc_git: and says why, as git does" "$(has "$(cat "$DC_ROOT/err")" "contains modified or untracked files")"
check "worktree remove through dc_git: nothing ran for the refused one" "$(eq "$(ran)" nothing)"
restat "$F/wt-dirty/a.txt"; rm -f "$F/wt-dirty/notes.md"
safe="$(ans dc_git "$F/wt-dirty" --no-optional-locks status --porcelain --untracked-files=all)"
check "status through dc_git in a worktree: clean, and nothing ran" "$(eq "$safe|$(ran)" "0||nothing")"

# ================================================================================================
# 4. A submodule whose OWN configuration names the programs
# ================================================================================================
dc_marker_repo "$GIT" "$F/inner" "$LOG" || check "the inner fixture was made" "dc_marker_repo failed"
_dc_rgit "$GIT" init "$F/outer" >/dev/null; printf 'x\n' > "$F/outer/f"
_dc_rgit "$GIT" -C "$F/outer" add -A >/dev/null; _dc_rgit "$GIT" -C "$F/outer" commit -m seed >/dev/null
_dc_rgit "$GIT" -C "$F/outer" submodule add "$F/inner" sub >/dev/null
_dc_rgit "$GIT" -C "$F/outer" commit -m sub >/dev/null
SG="$F/outer/.git/modules/sub"
check "the submodule was made, its repository inside the outer one's" "$([ -f "$SG/HEAD" ] && [ -f "$F/outer/sub/a.txt" ] && echo ok || echo "git did not make it")"
dc_marker_settings "$GIT" "$SG" "$F/outer.markers" "$LOG" sub. || check "the submodule's settings were written" "dc_marker_settings failed"
restat "$F/outer/sub/a.txt"; : > "$LOG"
bare="$(ans git -C "$F/outer" --no-optional-locks status --porcelain --untracked-files=all)"
seen="$(ran)"
check "status over a submodule, called bare: the SUBMODULE's fsmonitor program ran" "$(has "$seen" "sub.fsmonitor")"
check "status over a submodule, called bare: and its filter program ran" "$(has "$seen" "sub.filter.clean")"
restat "$F/outer/sub/a.txt"
safe="$(ans dc_git "$F/outer" --no-optional-locks status --porcelain --untracked-files=all)"
check "status over a submodule through dc_git: nothing the submodule names ran" "$(eq "$(ran)" nothing)"
check "status over a submodule: clean, as the bare call said" "$(eq "$safe|$bare" "0||0|")"
printf 'edit\n' >> "$F/outer/sub/a.txt"
safe="$(ans dc_git "$F/outer" --no-optional-locks status --porcelain --untracked-files=all)"
check "status through dc_git: uncommitted work inside a submodule is still reported" "$(eq "$safe" "0| M sub")"
check "status through dc_git: and nothing ran to find it" "$(eq "$(ran)" nothing)"

# ================================================================================================
# 5. A repository that says a missing object can be fetched, with a program as the fetcher
# ================================================================================================
dc_marker_repo "$GIT" "$F/lazy" "$LOG" || check "the partial clone fixture was made" "dc_marker_repo failed"
L="$F/lazy"
tree="$(git -C "$L" -c core.fsmonitor=false rev-parse 'HEAD^{tree}')"
_dc_rgit "$GIT" -C "$L" config core.repositoryformatversion 1
_dc_rgit "$GIT" -C "$L" config extensions.partialClone origin
_dc_rgit "$GIT" -C "$L" config remote.origin.promisor true
_dc_rgit "$GIT" init --bare "$F/lazy-origin" >/dev/null
_dc_rgit "$GIT" -C "$L" config remote.origin.url "$F/lazy-origin"
_dc_rgit "$GIT" -C "$L" config remote.origin.uploadpack "$(dc_marker "$F/lazy.markers" "$LOG" remote.uploadpack)"
rm -f "$L/.git/objects/${tree:0:2}/${tree:2}" "$L/.git/index"
check "the fixture lacks its tree object" "$([ -n "$tree" ] && [ ! -e "$L/.git/objects/${tree:0:2}/${tree:2}" ] && echo ok || echo "the tree is still there")"
: > "$LOG"
bare="$(ans git -C "$L" --no-optional-locks status --porcelain --untracked-files=all)"
check "status in a partial clone, called bare: the repository's fetch program ran" "$(has "$(ran)" "remote.uploadpack")"
safe="$(ans dc_git "$L" --no-optional-locks status --porcelain --untracked-files=all)"
check "status in a partial clone through dc_git: nothing ran, so nothing was fetched" "$(eq "$(ran)" nothing)"
check "status in a partial clone through dc_git: git fails, which a caller reads as unmeasured, never as clean" \
  "$([ "${safe%%|*}" -ne 0 ] && echo ok || echo "exit ${safe%%|*}: ${safe#*|}")"
bare="$(ans git -C "$L" rev-list --count --objects HEAD)"
check "rev-list over the missing object, called bare: the fetch program ran" "$(has "$(ran)" "remote.uploadpack")"
safe="$(ans dc_git "$L" rev-list --count --objects HEAD)"
check "rev-list through dc_git: nothing ran, and git fails" "$(eq "$(ran)|$([ "${safe%%|*}" -ne 0 ] && echo failed || echo "exit 0")" "nothing|failed")"

# ================================================================================================
# 6. Filters: the repository's are turned off by name, the user's own are left on, and a name
#    that cannot be turned off for one call is refused
# ================================================================================================
dc_marker_repo "$GIT" "$F/filters" "$LOG" || check "the filters fixture was made" "dc_marker_repo failed"
T="$F/filters"; M="$F/filters.markers"
printf '*.txt filter=mark\n*.dot filter=a.b\n*.inc filter=inc\n*.wt filter=wt\n*.own filter=own\n*.bin filter=proc\n' > "$T/.gitattributes"
for f in b.dot c.inc d.wt e.own f.bin; do printf 'x\n' > "$T/$f"; done
_dc_rgit "$GIT" -C "$T" -c core.fsmonitor=false add -A >/dev/null; _dc_rgit "$GIT" -C "$T" -c core.fsmonitor=false commit -m more >/dev/null
_dc_rgit "$GIT" -C "$T" config filter.a.b.clean "$(dc_marker "$M" "$LOG" filter.dotted cat)"
_dc_rgit "$GIT" -C "$T" config filter.proc.process "$(dc_marker "$M" "$LOG" filter.process)"
_dc_rgit "$GIT" -C "$T" config extensions.worktreeConfig true
_dc_rgit "$GIT" -C "$T" config --worktree filter.wt.clean "$(dc_marker "$M" "$LOG" filter.worktree-scope cat)"
printf '[include]\n\tpath = extra\n' >> "$T/.git/config"
printf '[filter "inc"]\n\tclean = %s\n' "$(dc_marker "$M" "$LOG" filter.included cat)" > "$T/.git/extra"
_dc_rgit "$GIT" config -f "$GIT_CONFIG_GLOBAL" filter.own.clean "$(dc_marker "$M" "$LOG" user.own.filter cat)"
all=("$T/a.txt" "$T/b.dot" "$T/c.inc" "$T/d.wt" "$T/e.own" "$T/f.bin")
restat "${all[@]}"; : > "$LOG"
bare="$(ans git -C "$T" --no-optional-locks status --porcelain --untracked-files=all)"
seen="$(ran)"
for n in filter.clean filter.dotted filter.process filter.worktree-scope filter.included; do
  check "filters, called bare: $n ran" "$(has "$seen" "$n ")"
done
restat "${all[@]}"
safe="$(ans dc_git "$T" --no-optional-locks status --porcelain --untracked-files=all)"
seen="$(ran)"
check "filters through dc_git: only the user's own filter ran, from the user's own configuration" "$(eq "$seen" "user.own.filter ")"
check "filters through dc_git: a clean checkout is still clean" "$(eq "$safe" "0|")"
# A filter the repository marks required cannot be skipped: git fails, and a caller reads unmeasured.
_dc_rgit "$GIT" -C "$T" config filter.mark.required true
restat "${all[@]}"; : > "$LOG"
safe="$(ans dc_git "$T" --no-optional-locks status --porcelain --untracked-files=all)"
check "a required filter of the repository's: git fails with it off, never reads the file as clean" \
  "$([ "${safe%%|*}" -ne 0 ] && echo ok || echo "exit 0: ${safe#*|}")"
check "a required filter: and it did not run" "$(hasnt "$(ran)" "filter.clean")"
_dc_rgit "$GIT" -C "$T" config --unset filter.mark.required
# A name holding an equals sign: git's -c reads the name only as far as the sign, so this one
# setting cannot be turned off for one call (measured 2026-11-20: it still ran). The process filter
# goes first: a marker is no filter process, so a bare git stops at its file and reads no further.
_dc_rgit "$GIT" -C "$T" config --unset filter.proc.process
_dc_rgit "$GIT" -C "$T" config 'filter.e=q.clean' "$(dc_marker "$M" "$LOG" filter.equals cat)"
printf '*.eq filter=e=q\n' >> "$T/.gitattributes"; printf 'x\n' > "$T/g.eq"
_dc_rgit "$GIT" -C "$T" -c core.fsmonitor=false add -A >/dev/null; _dc_rgit "$GIT" -C "$T" -c core.fsmonitor=false commit -m eq >/dev/null
check "the fixture holds a committed file whose attributes name that filter" \
  "$(eq "$(git -C "$T" -c core.fsmonitor=false ls-files g.eq)|$(git -C "$T" -c core.fsmonitor=false check-attr filter g.eq)|$(git -C "$T" -c core.fsmonitor=false status --porcelain)" "g.eq|g.eq: filter: e=q|")"
restat "${all[@]}" "$T/g.eq"; : > "$LOG"
bare="$(ans git -C "$T" --no-optional-locks status --porcelain --untracked-files=all)"
check "a filter named with an equals sign, called bare: it ran" "$(has "$(ran)" "filter.equals")"
restat "${all[@]}" "$T/g.eq"
safe="$(ans dc_git "$T" --no-optional-locks status --porcelain --untracked-files=all)"
check "a filter named with an equals sign: dc_git refuses rather than run git with it on" \
  "$(eq "${safe%%|*}|${safe#*|}" "125|")"
check "and says which setting it could not turn off" "$(has "$(cat "$DC_ROOT/err")" "dc_git: refused: this repository's own configuration names a filter program (filter.e=q.clean)")"
check "and nothing ran, the user's own filter included, because git was never asked" "$(eq "$(ran)" nothing)"

# ================================================================================================
# 7. What dc_git will not run: a command, or an option, nobody has measured
# ================================================================================================
: > "$LOG"
refused() { # <words of the reason> <dc_git arguments...>
  local want="$1" out rc
  shift
  out="$(dc_git "$@" 2>&1 </dev/null)"; rc=$?
  [ "$rc" -eq 125 ] || { echo "exit $rc: $out"; return; }
  has "$out" "$want"
}
for q in "fetch origin" "remote update" "remote show origin" "stash pop" "stash" "worktree add $F/x" "diff --quiet" "log -p" "config --list" "gc"; do
  # shellcheck disable=SC2086
  check "dc_git refuses 'git $q', which is not a command measured to run without the repository's programs" "$(refused "dc_git: refused: " "$C" $q)"
done
check "dc_git refuses stash list with anything after it, which would be log options" "$(refused "takes nothing after it" "$C" stash list -p)"
check "dc_git refuses a status asked to print a diff" "$(refused "prints a diff" "$C" status -v)"
# -v has other spellings (a cluster, a second v, a shortened long name), so status takes only the
# two options it was measured with and no list of the spellings to refuse is kept.
for q in "-vv" "-sv" "-vs" "--verb" "--verbose" "--short" "--porcelain -v"; do
  # shellcheck disable=SC2086
  check "dc_git refuses 'git status $q': status takes only the options it was measured with" "$(refused "is not an option status was measured with" "$C" status $q)"
done
check "dc_git still runs the status the scan asks, with both its options" "$(eq "$(ans dc_git "$C" --no-optional-locks status --porcelain --untracked-files=all)" "0|")"
check "dc_git refuses a setting of the caller's before the command, which could turn one back on" "$(refused "is not an option it passes" "$C" -c core.fsmonitor=true status)"
check "dc_git refuses a call with no command" "$(refused "dc_git: " "$C")"
# An empty folder name: git -C "" stays where the caller stands, so a judged folder whose name was
# lost would be answered for by whatever repository the caller happens to be in.
check "dc_git refuses an empty folder name, which git would read as the directory the caller stands in" "$(cd "$C" && refused "names no folder" "" --no-optional-locks status --porcelain)"
check "dc_git refuses an empty folder name for a command that reads no settings too" "$(cd "$C" && refused "names no folder" "" rev-parse HEAD)"
check "dc_git: no refused call ran git, so nothing ran" "$(eq "$(ran)" nothing)"
check "dc_git: and the fixture kept its stash, which a stash pop would have taken" "$(eq "$(dc_git "$C" stash list | grep -c '^stash@')" 1)"
# A folder that is no repository, and one that is not there, fail as git fails.
mkdir -p "$F/plain"
check "dc_git in a folder that is no repository fails as git does" "$(eq "$(ans dc_git "$F/plain" rev-parse --absolute-git-dir)" "128|")"
check "dc_git status in a folder that is no repository fails as git does" "$(eq "$(ans dc_git "$F/plain" --no-optional-locks status --porcelain)" "128|")"
check "dc_git in a folder that is not there fails" "$([ "$(ans dc_git "$F/absent" rev-parse HEAD)" != "0|" ] && echo ok || echo "exit 0")"
# A bare repository git merely finds at the folder is not answered for (safe.bareRepository).
_dc_rgit "$GIT" init --bare "$F/bare" >/dev/null
check "a bare repository at the folder: bare git answers for it" "$(eq "$(ans git -C "$F/bare" rev-parse --absolute-git-dir)" "0|$(cd -P "$F/bare" && pwd -P)")"
check "a bare repository at the folder: dc_git has git answer for none" "$(eq "$(ans dc_git "$F/bare" rev-parse --absolute-git-dir)" "128|")"
# A submodule path git has to quote cannot be read back, so its settings cannot be: refused.
_dc_rgit "$GIT" init "$F/odd" >/dev/null; printf 'x\n' > "$F/odd/f"
_dc_rgit "$GIT" -C "$F/odd" add -A >/dev/null; _dc_rgit "$GIT" -C "$F/odd" commit -m seed >/dev/null
_dc_rgit "$GIT" -C "$F/odd" update-index --add --cacheinfo "160000,$(_dc_rgit "$GIT" -C "$F/odd" rev-parse HEAD),$(printf 'sub\tx')"
check "the fixture's index holds a submodule at a path git prints quoted" \
  "$(eq "$(git -C "$F/odd" ls-files --stage | grep -c '^160000 .*"sub\\tx"$')" 1)"
check "a submodule whose path git must quote: dc_git refuses the status" "$(refused "a submodule path it cannot read" "$F/odd" --no-optional-locks status --porcelain)"

# ================================================================================================
# 8. The settings dc_git passes are the ones this suite measured, and they are passed as git reads them
# ================================================================================================
check "the settings are the six measured: no pager, no fetch on demand, no fsmonitor, no hooks, no bare repository merely found, no signature check" \
  "$(eq "${DC_GIT_FIXED[*]}" "--no-pager --no-lazy-fetch -c core.fsmonitor=false -c core.hooksPath=/dev/null -c safe.bareRepository=explicit -c log.showSignature=false")"
# The stand in every stubbed suite's git stub starts with drops exactly those, so a stub reads the
# command as the script wrote it, and answers dc_git's own two questions with nothing.
dc_stub git "$DC_GIT_HELPER_STANDIN"'
printf "%s|%s\n" "$d" "$*"'
PREDICATES="$DIR/lib/disk-clean-predicates.sh"
via_stub() { dc_run bash -c '. "$1"; shift; dc_git "$@"' _ "$PREDICATES" "$@" 2>&1; }
check "the stand in: a stub sees the folder and the command as the script wrote them" \
  "$(eq "$(via_stub "$H/w x" symbolic-ref --short -q HEAD)" "$H/w x|symbolic-ref --short -q HEAD")"
check "the stand in: optional locks off stays part of the command a stub sees" \
  "$(eq "$(via_stub "$H/w" --no-optional-locks status --porcelain)" "$H/w|--no-optional-locks status --porcelain")"
check "the stand in: dc_git's own two questions are answered with nothing, so a status makes three git calls" \
  "$(eq "$(dc_calls git | grep -c "$(printf '%q' "$H/w") ")" 3)"
check "and each of the three carried every setting" \
  "$(eq "$(dc_calls git | grep -F -- "$(printf '%q' "$H/w") " | grep -cF -- " --no-pager --no-lazy-fetch -c core.fsmonitor=false -c core.hooksPath=/dev/null -c safe.bareRepository=explicit -c log.showSignature=false ")" 3)"

finish
