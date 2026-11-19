#!/usr/bin/env bash
#
# disk-clean-predicates.sh: the one copy of the rules saying what a disk-clean test root is, and
# whether a path lies inside one (claude-config#1804, moved here by #1805), and of the one folder
# shape under ~/.claude/state that disk-clean may offer (#3235, at the end of this file).
#
# Sourced by the three things that must agree, so none keeps a copy of its own (L261):
#   lib/disk-clean-harness.sh  dc_run refuses to run unless HOME is isolated by these rules
#   lib/disk-clean-guard.sh    (through the harness) every guarded write is judged by dc_inside
#   lib/disk-remove.sh         in test mode it refuses unless dc_home_isolated says HOME is inside
#                              DISK_CLEAN_TEST_ROOT, and it reads paths physically with dc_resolve
# and, for the session notes folder shape, by a fourth: skills/disk-clean/scan-lib.sh, through which
# categories/claude-records.sh reads dc_notes_shape and dc_notes_folder as disk-remove.sh does.
# They lived in the harness until disk-remove.sh needed them. The harness also holds dc_run and the
# command check, which run commands no disk-clean script may (an `exec "$@"`, python3 through a
# variable), so a script sourcing the whole harness would fail the command check it is held to.
#
# Commands it runs: id, readlink, and the builtins cd, pwd, printf and eval. bash 3.2 safe.
# Sourcing defines constants and functions and does nothing else.

# Every root dc_setup makes is named so, and nothing else is accepted as one.
DC_ROOT_PREFIX="disk-clean-harness"
# Where a root may be, physically: the temp folders mktemp uses on macOS and Linux.
DC_TEMP_PARENTS="/tmp /private/tmp /var/folders /private/var/folders /var/tmp /private/var/tmp"

# The real home directory, from the user database, never from HOME, which is what is in question.
dc_real_home() {
  local u h
  u="$(id -un 2>/dev/null)" || return 1
  case "$u" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  h="$(eval "printf '%s' ~$u")"
  case "$h" in /*) ;; *) return 1 ;; esac
  if [ -d "$h" ]; then (CDPATH= cd -P "$h" 2>/dev/null && pwd -P) || printf '%s\n' "$h"; else printf '%s\n' "$h"; fi
}

# The rules for a root, with the real home and the temp folders passed in so a suite can ask each
# rule of a stand in rather than build a root inside the real home to prove it refused.
_dc_root_valid_against() { # <root> <real home> <temp parents>
  local r home="$2" parent ok=""
  case "$1" in /*) ;; *) return 1 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  r="$(CDPATH= cd -P "$1" 2>/dev/null && pwd -P)" || return 1
  case "${r##*/}" in "$DC_ROOT_PREFIX".?*) ;; *) return 1 ;; esac
  for parent in $3; do
    case "$r" in "$parent"/*) ok=1; break ;; esac
  done
  [ -n "$ok" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  case "${home%/}/" in "$r"/*) return 1 ;; esac
  case "$r/" in "${home%/}"/*) return 1 ;; esac
  return 0
}

# True when <root> is a directory this harness could have made: named by its template, under a
# temp folder, physically, and neither holding nor inside the real home.
dc_root_valid() { # <root>
  local home
  home="$(dc_real_home)" || return 1
  _dc_root_valid_against "${1:-}" "$home" "$DC_TEMP_PARENTS"
}

# True when <home> is, physically, strictly inside a valid <root>.
dc_home_isolated() { # <home> <root>
  local h r
  dc_root_valid "${2:-}" || return 1
  [ -n "${1:-}" ] && [ -d "$1" ] || return 1
  h="$(CDPATH= cd -P "$1" 2>/dev/null && pwd -P)" || return 1
  r="$(CDPATH= cd -P "$2" 2>/dev/null && pwd -P)" || return 1
  case "$h" in "$r"/*) return 0 ;; esac
  return 1
}

# The physical form of <path>: its existing ancestors resolved with cd -P, the rest appended. Fails,
# rather than guessing, on a . or .. in the part that does not exist yet and on a dangling link.
dc_resolve() { # <path>
  local p="$1" dir rest base
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while :; do case "$p" in /) break ;; */) p="${p%/}" ;; *) break ;; esac; done
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    (CDPATH= cd -P "$p" 2>/dev/null && pwd -P)
    return
  fi
  base="${p##*/}"; dir="${p%/*}"; [ -n "$dir" ] || dir=/
  case "$base" in ''|.|..) return 1 ;; esac
  rest="$base"
  while [ ! -d "$dir" ]; do
    [ -L "$dir" ] && return 1
    base="${dir##*/}"
    case "$base" in ''|.|..) return 1 ;; esac
    rest="$base/$rest"; dir="${dir%/*}"; [ -n "$dir" ] || dir=/
  done
  dir="$(CDPATH= cd -P "$dir" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "${dir%/}" "$rest"
}

# True when <path>, and every link it ends in, lies physically strictly inside <root>.
dc_inside() { # <path> <root>
  local p="$1" rr r t depth=0
  rr="$(CDPATH= cd -P "$2" 2>/dev/null && pwd -P)" || return 1
  while :; do
    r="$(dc_resolve "$p")" || return 1
    case "$r" in "$rr"/*) ;; *) return 1 ;; esac
    [ -L "$r" ] || return 0
    depth=$((depth + 1)); [ "$depth" -le 16 ] || return 1
    t="$(readlink "$r")" || return 1
    case "$t" in /*) p="$t" ;; *) p="${r%/*}/$t" ;; esac
  done
}

# ---- the one folder shape under ~/.claude/state that disk-clean may offer (claude-config#3235) ----
# disk-remove.sh refuses everything under ~/.claude/state, with one exception Dan signed on
# 2026-11-19, recorded on #3235: "Allow it". The exception is a folder exactly four levels under
# session-notes (session-notes/<project>/<session>/<task>/<folder>), which is where the daily keep
# rules leave an ended session's folder of images or documents, an open session's bulky leftover
# ("Offer after 7 idle days") and a git checkout in a task folder. A second, on the same day ("Offer
# when git says safe"), is a task folder that is itself a git checkout, three levels under. The
# functions below are the whole of both shapes, read by disk-remove.sh (which lets them reach their
# judge) and by categories/claude-records.sh (which offers them), so a row is offered only where the
# remover takes it (L261).

# True when <path>, as text, is exactly four levels under <home>/.claude/state/session-notes: no
# level empty, none of them . or .., and no control character anywhere in it. It reads no disk, so
# a link is not its to see; dc_notes_folder is. A trailing slash is refused, never trimmed here.
dc_notes_shape() { _dc_notes_levels "$1" "$2" 4; } # <path> <home>

# The second shape (Dan, 2026-11-19, recorded on #3235: "Offer when git says safe"): a task folder,
# exactly three levels under session-notes (session-notes/<project>/<session>/<task>), which the
# daily keep rules keep whole when it is itself a git checkout. As text it is read as the first
# shape is; dc_notes_checkout is what holds it to being a checkout.
dc_notes_task_shape() { _dc_notes_levels "$1" "$2" 3; } # <path> <home>

# True when <path>, as text, is exactly <levels> (3 or 4) levels under <home>/.claude/state/
# session-notes, by the rules dc_notes_shape states. The one reading of both shapes.
_dc_notes_levels() { # <path> <home> <levels: 3 or 4>
  local rest
  case "$1" in "$2/.claude/state/session-notes/"?*) ;; *) return 1 ;; esac
  rest="${1#"$2/.claude/state/session-notes/"}"
  case "$rest" in *[[:cntrl:]]*) return 1 ;; esac
  case "/$rest/" in *//*|*/./*|*/../*) return 1 ;; esac
  # In a case pattern * crosses a slash, so a level too many is refused before the count is taken.
  case "$3:$rest" in
    4:*/*/*/*/*|3:*/*/*/*) return 1 ;;
    4:*/*/*/*|3:*/*/*) return 0 ;;
  esac
  return 1
}

# True when <path> is, on disk, a real folder of the four level shape reached by its own path: not
# a link, and no link at any level above it, so what it names is where it lies. Otherwise it fails
# and sets DC_NOTES_WHY to why. <home> is HOME as set and <physical home> the same folder resolved,
# so a path written either way is read alike.
dc_notes_folder() { # <path> <home> <physical home>
  _dc_notes_real "$1" "$2" "$3" 4 "it is not a folder in a session's task folder (session-notes/<project>/<session>/<task>/<folder>)"
}

# True when <path> is, on disk, a real task folder (the three level shape, by its own path, as
# dc_notes_folder reads the four level one) that is itself a git checkout holding its own
# repository: a real .git FOLDER at its top. A task folder with no .git is a session's notes, and
# one whose .git is a file or a link is a worktree or submodule of a repository somewhere else, for
# which git run there would answer. Neither is ever let past disk-remove.sh's refusal of state.
dc_notes_checkout() { # <path> <home> <physical home>
  _dc_notes_real "$1" "$2" "$3" 3 "it is not a session's task folder (session-notes/<project>/<session>/<task>)" || return 1
  [ -d "${1%/}/.git" ] && [ ! -L "${1%/}/.git" ] || {
    DC_NOTES_WHY="it is a session's task folder and not a git checkout with a repository of its own (no .git folder at its top)"; return 1; }
  return 0
}

# True when <path> is one of the two things under session-notes that may reach a judge: a real
# folder of the four level shape, or a real task folder that is a git checkout. Which is asked is
# decided by how many levels the path has, so a task folder is never read as the looser shape.
# What disk-remove.sh holds an item to, and what categories/claude-records.sh offers (L261).
dc_notes_item() { # <path> <home> <physical home>
  local norm="${1%/}"
  case "$norm" in "$2"/*) norm="$3/${norm#"$2"/}" ;; esac
  if dc_notes_task_shape "$norm" "$3"; then dc_notes_checkout "$@"; else dc_notes_folder "$@"; fi
}

_dc_notes_real() { # <path> <home> <physical home> <levels> <why, when it is not of that shape>
  local t="${1%/}" norm phys
  DC_NOTES_WHY=""
  norm="$t"
  case "$norm" in "$2"/*) norm="$3/${norm#"$2"/}" ;; esac
  _dc_notes_levels "$norm" "$3" "$4" || { DC_NOTES_WHY="$5"; return 1; }
  [ ! -L "$t" ] || { DC_NOTES_WHY="it is a symbolic link"; return 1; }
  phys="$(dc_resolve "$t")" || { DC_NOTES_WHY="where it lies could not be read"; return 1; }
  [ "$phys" = "$norm" ] || { DC_NOTES_WHY="its path passes through a symbolic link, so it lies somewhere else ($phys)"; return 1; }
  [ -d "$t" ] || { DC_NOTES_WHY="it is not a folder"; return 1; }
  return 0
}
