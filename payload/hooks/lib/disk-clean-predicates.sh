#!/usr/bin/env bash
#
# disk-clean-predicates.sh: the one copy of the rules saying what a disk-clean test root is, and
# whether a path lies inside one (claude-config#1804, moved here by #1805), and of the two folder
# shapes under ~/.claude/state that disk-clean may offer (#3235, at the end of this file): a folder
# four levels under session-notes, and a task folder, three levels under, that is a git checkout
# holding its own repository.
#
# Sourced by the three things that must agree, so none keeps a copy of its own (L261):
#   lib/disk-clean-harness.sh  dc_run refuses to run unless HOME is isolated by these rules
#   lib/disk-clean-guard.sh    (through the harness) every guarded write is judged by dc_inside
#   lib/disk-remove.sh         in test mode it refuses unless dc_home_isolated says HOME is inside
#                              DISK_CLEAN_TEST_ROOT, and it reads paths physically with dc_resolve
# and, for the two session notes shapes, by a fourth: skills/disk-clean/scan-lib.sh, through which
# categories/claude-records.sh reads dc_notes_item, dc_notes_folder, dc_notes_checkout and
# dc_git_own_repo as disk-remove.sh does.
# They lived in the harness until disk-remove.sh needed them. The harness also holds dc_run and the
# command check, which run commands no disk-clean script may (an `exec "$@"`, python3 through a
# variable), so a script sourcing the whole harness would fail the command check it is held to.
#
# Commands it runs: id, readlink, git (only inside dc_git, the one way any disk-clean script runs
# it, #3328), and the builtins cd, pwd, printf and eval. bash 3.2 safe.
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

# ---- the two folder shapes under ~/.claude/state that disk-clean may offer (claude-config#3235) ----
# disk-remove.sh refuses everything under ~/.claude/state, with two exceptions Dan signed on
# 2026-11-19, recorded on #3235. The first ("Allow it") is a folder exactly four levels under
# session-notes (session-notes/<project>/<session>/<task>/<folder>), which is where the daily keep
# rules leave an ended session's folder of images or documents, an open session's bulky leftover
# ("Offer after 7 idle days") and a git checkout in a task folder. The second ("Offer when git says
# safe") is a task folder that is itself a git checkout holding its own repository, three levels
# under. The functions below are the whole of both shapes, read by disk-remove.sh (which lets them
# reach their judge) and by categories/claude-records.sh (which offers them), so a row is offered
# only where the remover takes it (L261).

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
# repository, which is dc_git_own_repo's to say. A task folder with no repository is a session's
# notes, and one that is a worktree or submodule belongs to a repository somewhere else, for which
# git run there would answer. Neither is ever let past disk-remove.sh's refusal of state.
dc_notes_checkout() { # <path> <home> <physical home>
  _dc_notes_real "$1" "$2" "$3" 3 "it is not a session's task folder (session-notes/<project>/<session>/<task>)" || return 1
  dc_git_own_repo "$1" || {
    DC_NOTES_WHY="it is a session's task folder and not a git checkout with a repository of its own ($DC_GIT_WHY)"; return 1; }
  return 0
}

# ---- git in a folder being judged (#3328) ----
#
# dc_git <folder> <git arguments...> is the ONE way a disk-clean script runs git, and the command
# check refuses a git call written anywhere else (lib/disk-clean-harness.sh, DC_WRAPPED).
#
# Why. git runs every command with the repository's own configuration, and a setting there can name
# a program git then starts. A repository copied into a session's notes, or a folder built to look
# like one, could so make a scan that promises to read only run a program nobody chose. git's own
# manual says as much (man git, SECURITY, git 2.51.1): "it is not safe to run Git commands in a
# .git directory (or the working tree that surrounds it) when that .git directory itself comes from
# an untrusted source. The commands in its config and hooks are executed in the usual way." It
# offers no switch that makes a repository safe, only a clean copy made with git clone --no-local,
# which cannot be asked what a working tree holds. So this turns off, for the one call, each
# setting MEASURED to start a program for a command disk-clean runs, and refuses any command that
# has not been measured. Measured 2026-11-20 on git 2.51.1 (Homebrew) and 2.54.0 (Apple), alike, by
# test-disk-clean-git.sh, which sees each program run with a bare call and not run through here.
#
#   what ran, called bare                              what turns it off (man git, man git-config)
#   core.fsmonitor: status, and the status inside      -c core.fsmonitor=false; a -c value "will
#     worktree remove                                    override values from configuration files"
#   hooks/post-index-change: worktree remove, whose    -c core.hooksPath=/dev/null, a folder that
#     status rewrites the index                          holds no hook
#   gpg.program: stash list, over a stash commit       -c log.showSignature=false
#     carrying a signature, with log.showSignature
#   remote.<name>.uploadpack: status and rev-list      --no-lazy-fetch ("Do not fetch missing
#     in a partial clone missing an object               objects from the promisor remote on demand")
#   filter.<name>.clean, .smudge, .process: status,    -c filter.<name>.clean= and the other two,
#     and worktree remove, when a file's contents        for each filter the repository's own
#     must be compared                                   configuration names (see below)
# and two more that nothing was measured running, kept because they cost nothing:
#   --no-pager                 core.pager and pager.<cmd> name a program, started only when output
#                              goes to a terminal, which a scan's never does
#   -c safe.bareRepository=explicit   the one setting man git-config gives for a repository of
#                              unknown origin: with it git works with no bare repository it merely
#                              finds at a folder, so a folder shaped like one is not answered for
#
# Filters have no single switch: each is named, and attributes say which files use which. So before
# a command that can compare file contents (status, worktree remove) this asks git which filter
# programs the repository's OWN configuration names (the local and worktree scopes of git config
# --show-scope, files it includes among them) and empties each for the call. The same is asked of
# every submodule checked out beneath, since status runs a status in each with that submodule's own
# configuration; a -c setting reaches those (measured). A filter from the user's own configuration
# (the global and system scopes, where git lfs install puts its own) is the user's choice and stays
# on. What an emptied filter changes: git compares the file as it lies, so a checkout whose
# repository filter would have altered a file is reported as git sees it without one, and one the
# repository marks required makes git fail, which every caller reads as unmeasured. Neither can
# turn uncommitted work into a clean answer.
#
# It refuses (exit 125, a line on stderr starting "dc_git: refused:", git never run):
#   a command not listed below, because another command brings other programs with it (fetch runs
#   an ssh command and credential helpers, diff and log -p run diff drivers) and none of those is
#   turned off here. Adding one means measuring it in test-disk-clean-git.sh first;
#   an option before the command other than --no-optional-locks, which could turn a setting back on;
#   stash list with anything after it, and status -v, which print a diff;
#   a filter whose name holds an equals sign, which -c cannot name (measured: it still ran), and a
#   submodule whose path git prints quoted, whose settings could therefore not be read.
# A failure of git's own is returned as git's exit code with git's words on stderr.
#
# Not covered: a program named by the USER's own configuration or environment, which is theirs;
# core.fsmonitor=true, git's built in watcher, which is turned off with the rest but was never
# started here to see; and a setting a later git adds. The environment is left as it is (see
# dc_git_own_repo).
DC_GIT_FIXED=(--no-pager --no-lazy-fetch -c core.fsmonitor=false -c core.hooksPath=/dev/null -c safe.bareRepository=explicit -c log.showSignature=false)
dc_git() { # <folder> <git arguments...>
  local d="${1:-}" a kind="" rest=0 off=() q=() qi=0 dir out scope key name line path named=$'\n'
  [ $# -ge 2 ] || { echo "dc_git: refused: it takes a folder and a git command" >&2; return 125; }
  shift
  for a in "$@"; do
    if [ -z "$kind" ]; then
      case "$a" in
        --no-optional-locks) ;;
        -*) echo "dc_git: refused: $a is not an option it passes to git before the command" >&2; return 125 ;;
        *) kind="$a" ;;
      esac
      continue
    fi
    rest=$((rest + 1))
    case "$kind" in
      remote|stash|worktree) [ "$rest" -eq 1 ] && kind="$kind $a" ;;
      "stash list") echo "dc_git: refused: stash list takes nothing after it here, since what follows is read as log options, and one that prints a diff runs the repository's diff programs" >&2; return 125 ;;
      status) case "$a" in -v|--verbose) echo "dc_git: refused: a status that prints a diff ($a) runs the repository's diff programs" >&2; return 125 ;; esac ;;
    esac
  done
  case "$kind" in
    rev-parse|symbolic-ref|rev-list|"remote get-url"|"stash list") ;;
    status|"worktree remove")
      q=("$d")
      while [ "$qi" -lt "${#q[@]}" ]; do
        dir="${q[$qi]}"; qi=$((qi + 1))
        [ "$qi" -le 100 ] || { echo "dc_git: refused: more than 100 submodules lie under $d, more than it reads the settings of" >&2; return 125; }
        out="$(git -C "$dir" "${DC_GIT_FIXED[@]}" config --show-scope --name-only --list </dev/null)" || return
        while IFS=$'\t' read -r scope key; do
          case "$scope" in system|global|command) continue ;; esac
          case "$key" in filter.*.clean|filter.*.smudge|filter.*.process) ;; *) continue ;; esac
          name="${key#filter.}"; name="${name%.*}"
          case "$name" in
            *=*) echo "dc_git: refused: this repository's own configuration names a filter program ($key) whose name holds an equals sign, which cannot be turned off for one call, so git was not run in $d" >&2; return 125 ;;
          esac
          case "$named" in *$'\n'"$name"$'\n'*) continue ;; esac
          named="$named$name"$'\n'
          off+=(-c "filter.$name.clean=" -c "filter.$name.smudge=" -c "filter.$name.process=")
        done <<< "$out"
        out="$(git -C "$dir" "${DC_GIT_FIXED[@]}" ls-files --stage </dev/null)" || return
        while IFS= read -r line; do
          case "$line" in "160000 "*) ;; *) continue ;; esac
          path="${line#*$'\t'}"
          case "$path" in
            '"'*) echo "dc_git: refused: $dir holds a submodule path it cannot read ($path), so that submodule's settings could not be turned off, and git was not run in $d" >&2; return 125 ;;
          esac
          [ -d "$dir/$path" ] && [ ! -L "$dir/$path" ] || continue
          [ -e "$dir/$path/.git" ] || [ -L "$dir/$path/.git" ] || continue
          q+=("$dir/$path")
        done <<< "$out"
      done ;;
    *) echo "dc_git: refused: 'git $kind' is not a command measured to run without the repository's own programs (lib/disk-clean-predicates.sh, #3328)" >&2; return 125 ;;
  esac
  git -C "$d" "${DC_GIT_FIXED[@]}" ${off[@]+"${off[@]}"} "$@"
}

# True when the folder <path> is a git checkout holding its OWN repository: asked in that folder,
# the git folder git answers from is the folder's own .git. Otherwise it fails and sets DC_GIT_WHY.
#
# Asked of git, never of the filesystem. What is being decided is which repository the questions
# asked next (is anything uncommitted, stashed, missing from its remote) will be answered for, and
# only git knows: in a worktree or a submodule .git is a file naming a repository somewhere else,
# git follows a .git that is a link to wherever it leads, and a .git folder that holds no repository
# is passed over for whichever one lies above it. Measured on real git, 2026-11-20: a full clone
# prints its own .git, resolved; a worktree <repository>/.git/worktrees/<name>; a submodule
# <superproject>/.git/modules/<name>; a .git link the folder the link names; and a folder whose
# .git is empty, or holds only a HEAD, fails with exit 128 when nothing above it is a repository.
# So one comparison refuses every one of those. A bare repository printed itself then; asked
# through dc_git (#3328), which has git work with no bare repository it merely finds, it fails with
# exit 128 like a folder that holds none, and is refused the same.
#
# The environment is left as it is on purpose. With GIT_DIR naming another repository, git answers
# for that one here and in every later call the judge makes, so this refuses, which is the truth
# about those calls. Clearing it for this one read would pass a folder git is not answering for.
dc_git_own_repo() { # <path>
  local t="${1%/}" phys g rc
  DC_GIT_WHY=""
  phys="$(dc_resolve "$t")" || { DC_GIT_WHY="where it lies could not be read"; return 1; }
  g="$(dc_git "$t" rev-parse --absolute-git-dir 2>/dev/null </dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { DC_GIT_WHY="git names no repository for it (git exit $rc)"; return 1; }
  [ "$g" = "$phys/.git" ] && return 0
  DC_GIT_WHY="git answers there for a repository that lies outside it ($g): it is a worktree or submodule of a repository elsewhere, or its .git is a link to one"
  return 1
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
