#!/usr/bin/env bash
#
# disk-clean-predicates.sh: the one copy of the rules saying what a disk-clean test root is, and
# whether a path lies inside one (claude-config#1804, moved here by #1805).
#
# Sourced by the three things that must agree, so none keeps a copy of its own (L261):
#   lib/disk-clean-harness.sh  dc_run refuses to run unless HOME is isolated by these rules
#   lib/disk-clean-guard.sh    (through the harness) every guarded write is judged by dc_inside
#   lib/disk-remove.sh         in test mode it refuses unless dc_home_isolated says HOME is inside
#                              DISK_CLEAN_TEST_ROOT, and it reads paths physically with dc_resolve
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
