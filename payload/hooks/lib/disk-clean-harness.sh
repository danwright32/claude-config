#!/usr/bin/env bash
#
# disk-clean-harness.sh: the one place every disk-clean suite runs the code under test
# (claude-config#1804, phase 1 of the Disk cleanup skill milestone).
#
# The disk-clean tools remove files from a real Mac, so their tests must never be able to reach
# one. This file is sourced by every disk-clean suite and owns everything that makes that true, so
# no suite carries its own copy of it (L613, L621).
#
# WHERE IT LIVES, and why here. Sourced from payload/hooks/lib, where every suite can reach it by a
# fixed path: a suite beside disk-remove.sh as "$DIR/lib/disk-clean-harness.sh", and a suite in the
# skill's own folder as "$DIR/../../hooks/lib/disk-clean-harness.sh", the way the disk-full suite
# reaches lib/suite-deadline.sh. Not in payload/skills/disk-clean/tests/: claude-sync refuses to
# carry, and reports on every send, a skills folder with no SKILL.md, and the skill's SKILL.md is
# phase #1808. Its own suite is hooks/test-disk-clean-harness.sh.
#
# USE, in a suite:
#
#   . "$DIR/lib/disk-clean-harness.sh" || { ...refuse to run... }
#   dc_setup || exit 1                 # sets an EXIT trap running dc_cleanup when none is set
#   dc_stub du 'printf "12\t%s\n" "$2"'   # give a stub behaviour; "$@" is what it was called with
#   dc_run bash "$SCRIPT" --plan "$DC_HOME/plan.txt"
#   dc_calls du                        # every recorded call to du, one per line, args %q quoted
#   dc_refusals                        # every write the guard refused (expect none)
#   dc_check_commands                  # the static command check, over the scripts present
#
# WHAT dc_run GUARANTEES the command it runs, and what it does not (L463):
#   PATH     exactly "$DC_STUBS:$DC_CORE". DC_STUBS holds one stub per name on DC_STUB_NAMES;
#            DC_CORE holds the tools on DC_CORE_TOOLS, linked from /bin or /usr/bin only, never
#            Homebrew, so both Macs and CI run the same binaries. Nothing else is reachable by name.
#   HOME     "$DC_HOME", and the working directory too, inside "$DC_ROOT", a directory this harness
#            made with mktemp under a temp folder. dc_run refuses (exit 97, running nothing) unless
#            dc_home_isolated says so, judged physically so a link out is refused.
#   TMPDIR   "$DC_ROOT/tmp", so a mktemp in the code under test lands inside the root too.
#   writes   rm rmdir mkdir touch mv cp ln chmod tee, sed -i and find -delete are wrappers that
#            refuse (exit 97, logged) any path whose physical location is outside DC_ROOT, and
#            refuse everything when DISK_CLEAN_TEST_ROOT does not name a valid root
#            (disk-clean-guard.sh). xargs and find -exec reach the same wrappers by PATH.
#   seams    each VAR=stub on DC_SEAMS is exported as VAR="$DC_STUBS/stub". Code that must call a
#            tool by its full path (disk-remove.sh calls "${DISK_CLEAN_TRASH:-/usr/bin/trash}",
#            because a Homebrew `trash` can shadow Apple's) does it through a seam.
#   NOT covered: shell redirection (`> file`) and awk's own output files, which no wrapper can see,
#   and the kill and cd builtins. HOME, the working directory and TMPDIR are what bound those, and
#   the command check below refuses the ways around PATH that a script could write.
#
# THE COMMAND CHECK. dc_check_commands lists every command the disk-clean scripts call, read from
# their source (disk-clean-commands.py), and fails on any that is neither a builtin, a function
# they define, a core tool, a stub nor a seam. It reads whatever scripts are present under
# payload/skills/disk-clean (its suites, test-*.sh and tests/, excepted) and payload/hooks/lib/
# disk-remove.sh, follows what they source or run, and refuses the ways around a stub: a call by
# full path, through a variable that is not a seam, setting PATH, `command -p`, `env -i`, and a
# shell reading code from standard input. A new external command in a disk-clean script therefore
# fails the harness suite until its name is added to DC_STUB_NAMES (or, read only and harmless,
# DC_CORE_TOOLS) here, which is a reviewed change to this one file (L96).
#
# REAL TOOLS. No suite may run /usr/bin/trash for real except test-disk-clean-harness.sh: measured
# 2026-10-27, it moves into the REAL ~/.Trash whatever HOME says. lsof exits 1 for not open,
# missing and permission denied alike, so code under test must judge it by stderr too.
#
# bash 3.2 safe. Sourcing defines functions and constants and does nothing else.

# The tools the code under test may run for real. Read only, or writing only through the guard.
# Every one must exist in /bin or /usr/bin on macOS and on the Ubuntu CI runner.
DC_CORE_TOOLS="bash sh cat grep egrep sed awk tr cut head tail sort uniq wc comm paste dirname basename env date mkdir mv rm rmdir ln touch cp chmod tee stat find xargs mktemp id ls readlink expr sleep uname hostname shasum"
# The writing tools among them, each reached through disk-clean-guard.sh. sed and find are guarded
# only for their writing forms (sed -i, find -delete).
DC_GUARDED_TOOLS="rm rmdir mkdir touch mv cp ln chmod tee sed find"
# The tools the code under test may call that a test must stand in for. Each gets a stub that
# records its call and refuses with exit 98 until a test gives it behaviour with dc_stub.
DC_STUB_NAMES="trash lsof du df docker git gh ps pgrep open pbcopy tmutil brew sudo xcodebuild osascript"
# VAR=stub pairs: a variable the code under test calls a tool through, pointed at that stub.
DC_SEAMS="DISK_CLEAN_TRASH=trash"
# Every root dc_setup makes is named so, and nothing else is accepted as one.
DC_ROOT_PREFIX="disk-clean-harness"
# Where a root may be, physically: the temp folders mktemp uses on macOS and Linux.
DC_TEMP_PARENTS="/tmp /private/tmp /var/folders /private/var/folders /var/tmp /private/var/tmp"

# This file's own folder by parameter expansion, never dirname, which a PATH without it breaks
# (claude-config#1104).
DC_LIB="${BASH_SOURCE[0]%/*}"; [ "$DC_LIB" != "${BASH_SOURCE[0]}" ] || DC_LIB=.
DC_LIB="$(CDPATH= cd -P "${DC_LIB:-/}" && pwd -P)"

# ---- the predicates: one copy, read by dc_run, the guard and the suites alike (L261) ----

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

# ---- setting up, running, stubbing ----

dc_setup() {
  local base t real
  base="${TMPDIR:-/tmp}"
  DC_ROOT="$(mktemp -d "${base%/}/$DC_ROOT_PREFIX.XXXXXXXX")" || { echo "dc_setup: mktemp failed under $base" >&2; DC_ROOT=""; return 1; }
  DC_ROOT="$(CDPATH= cd -P "$DC_ROOT" && pwd -P)"
  if ! dc_root_valid "$DC_ROOT"; then
    echo "dc_setup: refusing: the throwaway directory came back as $DC_ROOT, which is not one the harness accepts as a root" >&2
    DC_ROOT=""
    return 1
  fi
  DC_HOME="$DC_ROOT/home"; DC_STUBS="$DC_ROOT/stubs"; DC_CORE="$DC_ROOT/core"; DC_TMPDIR="$DC_ROOT/tmp"
  DC_CALLS="$DC_ROOT/calls.log"; DC_REFUSED="$DC_ROOT/refused.log"
  mkdir -p "$DC_HOME" "$DC_STUBS" "$DC_CORE" "$DC_TMPDIR" || return 1
  : > "$DC_CALLS"
  for t in $DC_CORE_TOOLS; do
    real=""
    [ -x "/bin/$t" ] && real="/bin/$t"
    [ -z "$real" ] && [ -x "/usr/bin/$t" ] && real="/usr/bin/$t"
    if [ -z "$real" ]; then
      echo "dc_setup: the core tool $t is in neither /bin nor /usr/bin on this machine, so the harness cannot be built" >&2
      return 1
    fi
    case " $DC_GUARDED_TOOLS " in
      *" $t "*) printf '#!/bin/bash\nexec /bin/bash %q %q %q "$@"\n' "$DC_LIB/disk-clean-guard.sh" "$t" "$real" > "$DC_CORE/$t"
                chmod +x "$DC_CORE/$t" ;;
      *) ln -s "$real" "$DC_CORE/$t" ;;
    esac
  done
  for t in $DC_STUB_NAMES; do dc_stub "$t" || return 1; done
  DC_PATH="$DC_STUBS:$DC_CORE"
  [ -n "$(trap -p EXIT)" ] || trap dc_cleanup EXIT
  return 0
}

dc_cleanup() {
  [ -n "${DC_ROOT:-}" ] || return 0
  dc_root_valid "$DC_ROOT" || return 0
  chmod -R u+rwx "$DC_ROOT" 2>/dev/null
  rm -rf "$DC_ROOT"
}

# Write the stub for <name>, recording every call and then running <body> with the call's
# arguments. With no body it refuses with exit 98, so a test that forgot to give it behaviour
# fails loudly rather than reading an empty success (L98).
dc_stub() { # <name> [<body>]
  local name="${1:-}" body
  case " $DC_STUB_NAMES " in
    *" $name "*) ;;
    *) echo "dc_stub: '$name' is not on DC_STUB_NAMES in $DC_LIB/disk-clean-harness.sh; add it there, where the command check reads it" >&2; return 2 ;;
  esac
  [ -n "${DC_STUBS:-}" ] && [ -d "$DC_STUBS" ] || { echo "dc_stub: dc_setup has not run" >&2; return 2; }
  if [ $# -ge 2 ]; then body="$2"; else
    body="echo \"disk-clean harness: $name is stubbed, and this test gave it no behaviour (dc_stub $name '<what it should do>')\" >&2; exit 98"
  fi
  {
    printf '#!/bin/bash\n'
    printf '{ printf %%s %q; [ $# -gt 0 ] && printf " %%q" "$@"; printf "\\n"; } >> %q\n' "$name" "$DC_CALLS"
    printf '%s\n' "$body"
  } > "$DC_STUBS/$name"
  chmod +x "$DC_STUBS/$name"
}

dc_calls() { # [<name>]
  [ -f "${DC_CALLS:-}" ] || return 0
  if [ $# -eq 0 ]; then cat "$DC_CALLS"; else awk -v n="$1" '$1 == n' "$DC_CALLS"; fi
}

dc_refusals() {
  [ -f "${DC_REFUSED:-}" ] && cat "$DC_REFUSED"
  return 0
}

# Run <command> in the isolated environment. A command, not a shell function: it is exec'd.
dc_run() { # <command> [<args>...]
  if [ -z "${DC_ROOT:-}" ]; then
    echo "dc_run: refusing to run '${1:-}': dc_setup has not run, so there is no throwaway HOME" >&2
    return 97
  fi
  if ! dc_home_isolated "${DC_HOME:-}" "$DC_ROOT"; then
    echo "dc_run: refusing to run '${1:-}': HOME would be '${DC_HOME:-}', which is not inside the harness's own throwaway directory $DC_ROOT" >&2
    return 97
  fi
  (
    CDPATH= cd -P "$DC_HOME" || exit 97
    unset BASH_ENV ENV CDPATH
    HOME="$DC_HOME"; PATH="$DC_PATH"; TMPDIR="$DC_TMPDIR"; DISK_CLEAN_TEST_ROOT="$DC_ROOT"
    export HOME PATH TMPDIR DISK_CLEAN_TEST_ROOT
    for _dc_seam in $DC_SEAMS; do export "${_dc_seam%%=*}=$DC_STUBS/${_dc_seam#*=}"; done
    exec "$@"
  )
}

# ---- the command check ----

# The repository the default scope is read from: three folders above this one in a checkout.
_dc_repo() {
  if [ -n "${DC_REPO:-}" ]; then printf '%s\n' "$DC_REPO"; else (CDPATH= cd -P "$DC_LIB/../../.." 2>/dev/null && pwd -P); fi
}

# The disk-clean scripts present, one per line: every file under payload/skills/disk-clean except
# its suites (test-*.sh), anything under a tests folder, and markdown, HTML and JSON, plus
# payload/hooks/lib/disk-remove.sh. Read from disk, so a script written today is in it today.
# Fails (exit 1, saying why) when the repository cannot be read, which is not the same answer as a
# repository holding no disk-clean scripts yet (L11).
dc_scope_files() {
  local repo found
  repo="$(_dc_repo)" || { echo "dc_scope_files: could not find the repository above $DC_LIB" >&2; return 1; }
  if [ ! -d "$repo/payload/hooks" ]; then
    echo "dc_scope_files: could not read $repo as this repository: it has no payload/hooks folder" >&2
    return 1
  fi
  if [ -d "$repo/payload/skills/disk-clean" ]; then
    found="$(find "$repo/payload/skills/disk-clean" -type f \
      ! -path '*/tests/*' ! -name 'test-*.sh' ! -name '*.md' ! -name '*.html' ! -name '*.json' -print)" || {
      echo "dc_scope_files: could not list every file under $repo/payload/skills/disk-clean" >&2
      return 1
    }
    [ -n "$found" ] && printf '%s\n' "$found" | sort
  fi
  [ -f "$repo/payload/hooks/lib/disk-remove.sh" ] && printf '%s\n' "$repo/payload/hooks/lib/disk-remove.sh"
  return 0
}

# Lists every command the named files (default: dc_scope_files) call, one per line as
# kind<TAB>name<TAB>file:line<TAB>detail, kind one of builtin function core stub seam follow fail.
# Exit 0 none failed, 1 at least one did, 2 it could not run, 3 there was nothing to read.
dc_check_commands() { # [<file>...]
  local py repo d roots=""
  py="$(command -v python3 2>/dev/null)" || { echo "dc_check_commands: python3 is not on PATH, so no script could be read" >&2; return 2; }
  if [ $# -eq 0 ]; then
    local f files=() scope
    scope="$(dc_scope_files)" || { echo "dc_check_commands: could not tell which disk-clean scripts are present, so nothing was listed"; return 2; }
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<< "$scope"
    if [ "${#files[@]}" -eq 0 ]; then
      echo "dc_check_commands: no disk-clean scripts are present under $(_dc_repo) yet, so nothing was listed"
      return 3
    fi
    set -- "${files[@]}"
  fi
  repo="$(_dc_repo)"
  for d in "$repo/payload/hooks/lib" "$repo/payload/hooks"; do [ -d "$d" ] && roots="$roots${roots:+
}$d"; done
  if [ -d "$repo/payload/skills/disk-clean" ]; then
    while IFS= read -r d; do roots="$roots${roots:+
}$d"; done <<< "$(find "$repo/payload/skills/disk-clean" -type d)"
  fi
  "$py" "$DC_LIB/disk-clean-commands.py" --core "$DC_CORE_TOOLS" --stubs "$DC_STUB_NAMES" \
    --seams "$DC_SEAMS" --roots "$roots" -- "$@"
}
