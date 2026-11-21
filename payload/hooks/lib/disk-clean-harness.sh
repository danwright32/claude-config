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
# carry, and reports on every send, a skills folder with no SKILL.md, and the folder is the skill's
# own (#1808). Its own suite is hooks/test-disk-clean-harness.sh.
#
# USE, in a suite:
#
#   . "$DIR/lib/disk-clean-harness.sh" || { ...refuse to run... }
#   dc_setup || exit 1                 # sets an EXIT trap running dc_cleanup when none is set
#   dc_stub du 'printf "12\t%s\n" "$2"'   # give a stub behaviour; "$@" is what it was called with
#   dc_run bash "$SCRIPT" --plan "$DC_HOME/plan.txt"
#   dc_stub find 'exit 1'              # stand in for a core tool on DC_STANDIN_CORE, for one case
#   dc_unstub find                     # and give the core tool back
#   dc_calls du                        # every recorded call to du, one per line, args %q quoted
#   dc_refusals                        # every write the guard refused (expect none)
#   dc_check_commands                  # the static command check, over the scripts present
#
# WHAT dc_run GUARANTEES the command it runs, and what it does not (L463):
#   PATH     exactly "$DC_STUBS:$DC_CORE". DC_STUBS holds one stub per name on DC_STUB_NAMES, and a
#            stand in for a core tool on DC_STANDIN_CORE only while a test has written one;
#            DC_CORE holds the tools on DC_CORE_TOOLS, linked from /bin or /usr/bin only, never
#            Homebrew, so both Macs and CI run the same binaries. Nothing else is reachable by name.
#   HOME     "$DC_HOME", and the working directory too, inside "$DC_ROOT", a directory this harness
#            made with mktemp under a temp folder. dc_run refuses (exit 97, running nothing) unless
#            dc_home_isolated says so, judged physically so a link out is refused.
#   TMPDIR   "$DC_ROOT/tmp", so a mktemp in the code under test lands inside the root too.
#   writes   rm rmdir mkdir touch mv cp ln chmod tee, sed -i and find -delete are wrappers that
#            refuse (exit 97, logged) any path whose physical location is outside DC_ROOT, and
#            refuse everything when DISK_CLEAN_TEST_ROOT does not name a valid root
#            (disk-clean-guard.sh). xargs and find -exec reach the same wrappers by PATH. Every call
#            to one is recorded in the call log as a stub's is, so dc_calls find counts the finds.
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
# DC_CORE_TOOLS) here, which is a reviewed change to this one file (L96). And one command is held
# to more than being a stub: git, which the check refuses anywhere but inside dc_git (DC_WRAPPED
# below, #3328), because git runs with the judged repository's own configuration and only that one
# helper turns the repository's program running settings off.
#
# REAL GIT. git is a stub in every dc_run, which says nothing of what a setting does. The suites
# that must know ask the git on this machine, on a repository dc_marker_repo builds whose own
# settings name marker programs: hooks/test-disk-clean-git.sh holds dc_git to each, and the "real
# git" cases of test-disk-remove.sh and skills/disk-clean/test-disk-clean-categories.sh run the
# remover and two judges on one, with a git stub that execs the real git.
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
# judge and derived-data-sweep are not system tools: they are what disk-remove.sh's two seams below
# stand for, a category's judge and hooks/derived-data-sweep.sh (#1805). pnpm is here for the one
# removal method that runs it, `pnpm store prune` (Dan, 2026-11-19, recorded on #3235: "Offer a
# prune row"): a suite gives the stand in its behaviour and reads back the arguments it was run
# with, and the real pnpm, which removes from a real store, is never reachable from code under test.
DC_STUB_NAMES="trash lsof du df docker git gh ps pgrep open pbcopy tmutil brew sudo xcodebuild osascript pnpm judge derived-data-sweep"
# Core tools a test may stand in for, for one case, with dc_stub, and give back with dc_unstub
# (#1907). Unlike a name on DC_STUB_NAMES no stand in exists until a test writes one, so the core
# tool runs by default: every category reads the disk with find, and only a stand in can produce the
# find that fails because a file went between two reads, a race no test can time. A stand in is
# test code in place of the guarded wrapper, so one that must still write calls "$DC_CORE/<tool>".
# Never on DC_STUB_NAMES too: the command check reads these calls as core.
DC_STANDIN_CORE="find"
# VAR=stub pairs: a variable the code under test calls a tool through, pointed at that stub.
#   DISK_CLEAN_TRASH               /usr/bin/trash, which ignores HOME and uses the real ~/.Trash
#   DISK_CLEAN_JUDGE               the category module disk-remove.sh runs as `<module> judge <path>`
#                                  (the category is in DISK_CLEAN_CATEGORY); a test that wants the
#                                  real module dispatch sets it empty with env
#   DISK_CLEAN_DERIVED_DATA_SWEEP  hooks/derived-data-sweep.sh, which needs perl, ps, plutil and
#                                  PlistBuddy; its own suite runs it for real
DC_SEAMS="DISK_CLEAN_TRASH=trash DISK_CLEAN_JUDGE=judge DISK_CLEAN_DERIVED_DATA_SWEEP=derived-data-sweep"
# A stand in for the ONE read `git -C <d> rev-parse --absolute-git-dir`, which dc_git_own_repo asks
# (lib/disk-clean-predicates.sh, #3235): a fragment a suite's git stub runs with d set to the -C
# folder, so every suite whose git is a stub answers that question one way. It prints the physical
# git folder git would answer from there, or fails as git does (exit 128), by what real git was
# measured to do on 2026-11-20: a .git folder, or a link to one, that holds a repository is printed
# resolved; a .git file is read for the gitdir it names (a worktree's or a submodule's), printed when
# that is one; a .git that holds no repository, and no .git, are not a repository. It never walks up
# to a parent, so a fixture must not sit inside a repository. test-disk-remove.sh runs it beside
# real git on each of those shapes and fails when the two differ (L404).
DC_GIT_DIR_STANDIN='g="$d/.git"
if [ -f "$g" ] && [ ! -L "$g" ]; then
  IFS= read -r g < "$g"
  case "$g" in "gitdir: /"*) g="${g#gitdir: }" ;; "gitdir: "?*) g="$d/${g#gitdir: }" ;; *) g="" ;; esac
fi
if [ -n "$g" ] && [ -f "$g/HEAD" ] && { [ -f "$g/commondir" ] || { [ -d "$g/objects" ] && [ -d "$g/refs" ]; }; }; then
  (CDPATH= cd -P "$g" && pwd -P); exit $?
fi
echo "fatal: not a git repository (or any of the parent directories): .git" >&2; exit 128'
# What every suite's git stub runs FIRST (#3328). A disk-clean script reaches git only through
# dc_git (lib/disk-clean-predicates.sh), which writes its call as
#   git -C <folder> <the settings that turn the repository's programs off> <the command>
# and, before a status or a worktree remove, asks git two questions of its own: which filter
# programs the repository's configuration names, and which submodules it holds. This fragment sets d
# to the -C folder, drops the settings dc_git adds, so a stub's own case reads the command as the
# script wrote it, and answers those two questions as a fixture with no filter and no submodule
# does (nothing, exit 0). It drops the two bare options by name, so a bare option dc_git gains
# later reaches the stub's own case and fails there, loudly. A `-c name=value` pair it drops
# whatever it names, so a `-c` setting dc_git gains later is not seen here: what catches that one
# is test-disk-clean-git.sh, which holds DC_GIT_FIXED to the exact list measured.
# Whether the settings do turn the programs off is never a stub's to say: test-disk-clean-git.sh
# and the "real git" cases of the other suites ask the git on this machine.
DC_GIT_HELPER_STANDIN='d=""; if [ "$1" = -C ]; then d="$2"; shift 2; fi
while [ $# -gt 0 ]; do case "$1" in -c) shift 2 ;; --no-pager|--no-lazy-fetch) shift ;; *) break ;; esac; done
case "${1:-} ${2:-}" in "config --show-scope"|"ls-files --stage") exit 0 ;; esac'
# name=function pairs: a command the scripts may run only from inside that one function, which the
# command check refuses anywhere else (#3328). git runs with the judged repository's own
# configuration, and a setting there can name a program, so every call goes through dc_git, which
# turns those settings off; a bare git call in a script is how the next one would forget.
DC_WRAPPED="git=dc_git"

# This file's own folder by parameter expansion, never dirname, which a PATH without it breaks
# (claude-config#1104).
DC_LIB="${BASH_SOURCE[0]%/*}"; [ "$DC_LIB" != "${BASH_SOURCE[0]}" ] || DC_LIB=.
DC_LIB="$(CDPATH= cd -P "${DC_LIB:-/}" && pwd -P)"

# ---- the predicates: one copy, read by dc_run, the guard, disk-remove.sh and the suites (L261) ----
# DC_ROOT_PREFIX, DC_TEMP_PARENTS, dc_real_home, dc_root_valid, dc_home_isolated, dc_resolve and
# dc_inside live in disk-clean-predicates.sh, which disk-remove.sh sources too.
. "$DC_LIB/disk-clean-predicates.sh" || { echo "disk-clean-harness: disk-clean-predicates.sh is missing beside it" >&2; return 1; }

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
  # Read in a substitution, which bash 3.2.57 answers with the caller's trap (measured 2026-10-27).
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
  case " $DC_STUB_NAMES $DC_STANDIN_CORE " in
    *" $name "*) ;;
    *) echo "dc_stub: '$name' is not on DC_STUB_NAMES or DC_STANDIN_CORE in $DC_LIB/disk-clean-harness.sh; add it there, where the command check reads it" >&2; return 2 ;;
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

# Give back what dc_stub replaced: a core tool on DC_STANDIN_CORE runs again, and a name on
# DC_STUB_NAMES gets back the stub that refuses, never the real tool.
dc_unstub() { # <name>
  local name="${1:-}"
  [ -n "${DC_STUBS:-}" ] && [ -d "$DC_STUBS" ] || { echo "dc_unstub: dc_setup has not run" >&2; return 2; }
  case " $DC_STANDIN_CORE " in *" $name "*) rm -f "$DC_STUBS/$name"; return ;; esac
  case " $DC_STUB_NAMES " in *" $name "*) dc_stub "$name"; return ;; esac
  echo "dc_unstub: '$name' is not on DC_STUB_NAMES or DC_STANDIN_CORE in $DC_LIB/disk-clean-harness.sh" >&2
  return 2
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

# ---- real repositories whose own settings name a program (#3328) ----
# For the suites that ask the git on this machine whether a disk-clean git call runs a program the
# judged repository names. Every program is a marker: it appends its name to a log and exits, so a
# case that sees one run has harmed nothing. A suite gives <git> as the real git's full path, since
# on a dc_run PATH git is a stub.

# Writes the marker <name> into <folder> and prints its path. It appends <name> to <log>, runs
# <then> when one is given (cat, for a filter, which must hand its input back) and exits 0.
dc_marker() { # <folder> <log> <name> [<then>]
  mkdir -p "$1" || return 1
  printf '#!/bin/sh\necho %s >> %q\n%s\nexit 0\n' "$3" "$2" "${4:-:}" > "$1/$3" || return 1
  chmod +x "$1/$3" || return 1
  printf '%s\n' "$1/$3"
}

# git for BUILDING a fixture: it reads no configuration but the fixture's own, and says nothing on
# stderr. Building runs the fixture's markers too, so a case empties the log before it measures.
_dc_rgit() { # <git> <git arguments...>
  local git="$1"
  shift
  HOME="$DC_HOME" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$git" -c user.email=t@example.invalid -c user.name=t \
    -c commit.gpgsign=false -c init.defaultBranch=main -c protocol.file.allow=always "$@" </dev/null 2>/dev/null
}

# Writes into the configuration of the repository whose git folder is <git folder> every setting
# measured to make a git command disk-clean runs start a program (2026-11-20, git 2.51.1 from
# Homebrew and Apple's 2.54.0, alike), each naming a marker in <markers folder>, its name led by
# <prefix> when one is given:
#   core.fsmonitor                 status runs it, and so does the status inside worktree remove
#   filter.mark.clean and .smudge  run when git must compare the contents of a file whose
#                                  attributes say filter=mark, which a changed time is enough for
#   hooks/post-index-change        run when a status rewrites the index, as worktree remove's does
#   gpg.program, log.showSignature stash list runs it over a stash commit that carries a signature
dc_marker_settings() { # <git> <git folder> <markers folder> <log> [<prefix>]
  local git="$1" gd="$2" m="$3" log="$4" p="${5:-}" hook
  _dc_rgit "$git" config -f "$gd/config" core.fsmonitor "$(dc_marker "$m" "$log" "${p}fsmonitor")" || return 1
  _dc_rgit "$git" config -f "$gd/config" filter.mark.clean "$(dc_marker "$m" "$log" "${p}filter.clean" cat)" || return 1
  _dc_rgit "$git" config -f "$gd/config" filter.mark.smudge "$(dc_marker "$m" "$log" "${p}filter.smudge" cat)" || return 1
  _dc_rgit "$git" config -f "$gd/config" gpg.program "$(dc_marker "$m" "$log" "${p}gpg.program")" || return 1
  _dc_rgit "$git" config -f "$gd/config" log.showSignature true || return 1
  hook="$(dc_marker "$m" "$log" "${p}hook.post-index-change")" || return 1
  mkdir -p "$gd/hooks" && cp "$hook" "$gd/hooks/post-index-change"
}

# Makes a real repository at <dir>: one commit on the branch feat-real holding a.txt, which its
# attributes give filter=mark, an origin remote on GitHub that nothing here contacts, and
# dc_marker_settings in its own configuration, the markers in <dir>.markers beside it so none is a
# file in it. It sets no times: a case ages what its floor needs.
dc_marker_repo() { # <git> <dir> <log>
  local git="$1" d="$2" log="$3"
  _dc_rgit "$git" init "$d" >/dev/null || return 1
  _dc_rgit "$git" -C "$d" checkout -b feat-real >/dev/null
  printf '*.txt filter=mark\n' > "$d/.gitattributes" || return 1
  printf 'one\n' > "$d/a.txt"
  _dc_rgit "$git" -C "$d" add -A >/dev/null && _dc_rgit "$git" -C "$d" commit -m seed >/dev/null || return 1
  _dc_rgit "$git" -C "$d" remote add origin https://github.com/dan/repo.git || return 1
  dc_marker_settings "$git" "$d/.git" "$d.markers" "$log"
}

# Leaves the repository at <dir> holding one stash whose commit carries a signature header, with
# its working tree as it was. That header is what makes stash list reach gpg.program.
dc_marker_signed_stash() { # <git> <dir>
  local git="$1" d="$2" s n
  printf 'changed\n' >> "$d/a.txt" || return 1
  _dc_rgit "$git" -C "$d" stash >/dev/null || return 1
  s="$(_dc_rgit "$git" -C "$d" rev-parse refs/stash)" || return 1
  mkdir -p "$d.markers" || return 1
  _dc_rgit "$git" -C "$d" cat-file commit "$s" | awk '!x && /^$/ { print "gpgsig -----BEGIN PGP SIGNATURE-----"; print " "; print " abc"; print " -----END PGP SIGNATURE-----"; x = 1 } { print }' > "$d.markers/stash.commit"
  n="$(_dc_rgit "$git" -C "$d" hash-object -t commit -w "$d.markers/stash.commit")" || return 1
  _dc_rgit "$git" -C "$d" stash drop >/dev/null || return 1
  _dc_rgit "$git" -C "$d" stash store -m signed "$n"
}

# The names of the markers that ran, sorted, one line, and "nothing" when none did; then the log is
# emptied, so the next reading is of the next command alone.
dc_markers_ran() { # <log>
  local out=""
  [ -s "$1" ] && out="$(sort -u "$1" | tr '\n' ' ')"
  : > "$1"
  printf '%s\n' "${out:-nothing}"
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

# Lists every command the named files (default: dc_scope_files) call, one per line on stdout as
# kind<TAB>name<TAB>file:line<TAB>detail, kind one of builtin function core stub seam follow fail.
# Anything else it has to say goes to stderr. Exit 0 none failed, 1 at least one did, 2 it could
# not run, 3 there was nothing to read.
dc_check_commands() { # [<file>...]
  local py repo d roots=""
  py="$(command -v python3 2>/dev/null)" || { echo "dc_check_commands: python3 is not on PATH, so no script could be read" >&2; return 2; }
  if [ $# -eq 0 ]; then
    local f files=() scope
    scope="$(dc_scope_files)" || { echo "dc_check_commands: could not tell which disk-clean scripts are present, so nothing was listed" >&2; return 2; }
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<< "$scope"
    if [ "${#files[@]}" -eq 0 ]; then
      echo "dc_check_commands: no disk-clean scripts are present under $(_dc_repo) yet, so nothing was listed" >&2
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
    --seams "$DC_SEAMS" --wrapped "$DC_WRAPPED" --roots "$roots" -- "$@"
}
