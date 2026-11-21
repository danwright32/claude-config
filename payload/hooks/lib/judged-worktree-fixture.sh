#!/usr/bin/env bash
#
# judged-worktree-fixture.sh: what the two suites that hold a worktree cleanup to claude-config#3355
# share, so neither keeps a copy: hooks/test-judged-worktree.sh (lib/judged-worktree.sh and
# hooks/check-stale-worktrees.sh) and tools/test-shipped-worktrees-git.sh
# (tools/shipped-worktrees.sh). Sourced by a suite, never run, and never by a script that ships.
#
# It builds real repositories whose own settings name MARKER programs, with the disk-clean
# harness's builders (lib/disk-clean-harness.sh: dc_marker_repo, dc_marker, dc_markers_ran), adds
# worktrees whose own config.worktree names one more, and reads a script's source for the git calls
# it makes. A marker appends its name to a log and exits, so a case that sees one run has harmed
# nothing.
#
# Sourcing defines functions and one constant, and sources the harness. A suite calls jwf_begin
# once before anything else here.

case "${BASH_SOURCE[0]}" in */*) JWF_LIB="${BASH_SOURCE[0]%/*}" ;; *) JWF_LIB=. ;; esac
JWF_LIB="$(CDPATH= cd -P "${JWF_LIB:-/}" && pwd -P)"
. "$JWF_LIB/disk-clean-harness.sh" || { echo "judged-worktree-fixture: lib/disk-clean-harness.sh is missing beside it" >&2; return 1; }
TAB=$'\t'

# The throwaway directory, the git and python3 on this machine, and no configuration but a
# fixture's own: an empty home, no system file and an empty global file. Sets GIT, PY (empty when
# there is no python3), LOG (the markers' log) and F (where fixtures go). Fails, saying why on
# stderr, when there is no git or the harness cannot set up.
jwf_begin() {
  GIT="$(command -v git 2>/dev/null)" || { echo "jwf_begin: no git on the PATH, so no setting can be measured" >&2; return 1; }
  PY="$(command -v python3 2>/dev/null)" || PY=""
  dc_setup || return 1
  export HOME="$DC_HOME" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$DC_ROOT/global.gitconfig"
  : > "$GIT_CONFIG_GLOBAL"
  LOG="$DC_ROOT/markers.log"; : > "$LOG"
  F="$DC_HOME/fx"; mkdir -p "$F"
  JWF_STAMP=0
}

# The markers that ran since the last asking, sorted on one line, or "nothing".
ran() { dc_markers_ran "$LOG"; }
there() { [ -e "$1" ] && echo there || echo gone; }
# Every file of the folders given an old time, a different one on each call. Old, because a sweep
# keeps a worktree changed in the last six hours; different, because git compares a file's contents
# again only when its time has moved, which is when it runs a filter, so no earlier reading may
# answer for this one (L480).
age() { JWF_STAMP=$((JWF_STAMP + 1)); find "$@" -exec touch -t "$(printf '2026010100%02d' "$JWF_STAMP")" {} + 2>/dev/null; }
# The exit code and output of a command, as "code|output", stderr kept apart in $DC_ROOT/err.
ans() { local o; o="$("$@" 2> "$DC_ROOT/err" </dev/null)"; printf '%s|%s' "$?" "$o"; }
# 1 when the repository <repo> still lists a worktree at <path>, 0 when it does not.
listed() { git -C "$1" -c core.fsmonitor=false worktree list --porcelain | grep -cxF "worktree $2" || true; }

# A repository whose own settings name the marker programs (dc_marker_repo: core.fsmonitor, the
# filter on *.txt, the post-index-change hook, on the branch feat-real), holding a second file
# whose filter only a worktree's own config.worktree names, with the folder where Claude Code puts
# agent worktrees.
mkrepo() { # <dir>
  dc_marker_repo "$GIT" "$1" "$LOG" || return 1
  printf '*.txt filter=mark\n*.md filter=wtonly\n' > "$1/.gitattributes"
  printf 'two\n' > "$1/b.md"
  _dc_rgit "$GIT" -C "$1" add -A >/dev/null && _dc_rgit "$GIT" -C "$1" commit -m more >/dev/null || return 1
  _dc_rgit "$GIT" -C "$1" config extensions.worktreeConfig true || return 1
  mkdir -p "$1/.claude/worktrees"
}
# A worktree of it under .claude/worktrees, on the branch fix/<name> with one commit of its own, as
# an agent's has, whose OWN configuration names a filter program the repository's does not.
mkwt() { # <repo> <name>
  local w="$1/.claude/worktrees/$2"
  _dc_rgit "$GIT" -C "$1" worktree add -b "fix/$2" "$w" >/dev/null || return 1
  _dc_rgit "$GIT" -C "$w" commit --allow-empty -m "work on $2" >/dev/null || return 1
  _dc_rgit "$GIT" -C "$w" config --worktree filter.wtonly.clean "$(dc_marker "$1.markers" "$LOG" wt.filter.clean cat)"
}
# Points the folder <worktree> at the worktree record <name> of the repository <other> (one made
# by dc_marker_repo), and that record back at the folder, then leaves in the folder exactly what
# <other> has committed: git asked in the folder now answers for <other>, and calls it clean.
swap() { # <worktree folder> <other repository> <record name>
  local rec="$2/.git/worktrees/$3"
  printf '%s\n' "$1/.git" > "$rec/gitdir" || return 1
  printf 'gitdir: %s\n' "$rec" > "$1/.git" || return 1
  rm -f "$1/b.md"; printf '*.txt filter=mark\n' > "$1/.gitattributes"
}

# ---- a script's source, read for its git calls ----
# By the disk-clean command reader (lib/disk-clean-commands.py), which finds every call of git by
# any route (plainly, in a $( ), through xargs or eval), on a line that runs or not. Told that git
# belongs inside dc_git, it lists each call written anywhere else.
_jwf_read() { # <script>
  "$PY" "$JWF_LIB/disk-clean-commands.py" --core "" --stubs "git" --seams "" --wrapped "git=dc_git" --roots "$JWF_LIB" -- "$1" 2>&1
}
# The lines of <script> that call git outside dc_git in any form but the ones <forms> allows (a
# grep -E pattern, counted once per call on the line), each as "line <n>: <the line>". Nothing when
# every plain call is an allowed one. It says so instead when the reader could not read the script
# or found fewer than five plain calls in it, which is a script it did not read.
plain_git() { # <script> <forms>
  local script="$1" forms="$2" out n k src
  out="$(_jwf_read "$script")"
  grep -q "could not be read" <<< "$out" && { echo "the reader could not read it: $(grep "could not be read" <<< "$out" | head -n 1)"; return; }
  [ "$(grep -c "^fail${TAB}git${TAB}.*${script##*/}:[0-9]*${TAB}" <<< "$out")" -ge 5 ] || { echo "the reader found fewer than 5 plain git calls in it, so it did not read it"; return; }
  while read -r k n; do
    [ -n "$n" ] || continue
    src="$(sed -n "${n}p" "$script")"
    [ "$(grep -oE "$forms" <<< "$src" | wc -l | tr -d ' ')" -eq "$k" ] || printf 'line %s: %s\n' "$n" "$(sed 's/^ *//' <<< "$src")"
  done <<< "$(awk -F'\t' -v f="${script##*/}" '$1 == "fail" && $2 == "git" { n = $3; sub(/.*:/, "", n); p = $3; sub(/:[0-9]+$/, "", p); sub(/.*\//, "", p); if (p == f) print n }' <<< "$out" | sort -n | uniq -c)"
}
# How many times <script> calls <name>, by the same reader, whatever kind the reader gives it: a
# function when the reader could follow the script to the library that defines it, and an unknown
# command when the script sources that library through a variable, which the reader cannot follow.
calls() { # <script> <name>
  _jwf_read "$1" | grep -c "^[a-z]*${TAB}$2${TAB}.*${1##*/}:[0-9]*${TAB}" || true
}
