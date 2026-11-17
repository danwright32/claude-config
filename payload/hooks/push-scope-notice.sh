#!/usr/bin/env bash
#
# push-scope-notice.sh
# Claude Code PreToolUse(Bash) hook: REFUSE a push no push gate can judge, because the push names a
# directory the shared resolver could not resolve (claude-config#552, refusing since #589).
#
# Since #532, ps_repo_dir refuses a directory the command names but that cannot be used (missing,
# not a repository, a variable it cannot expand) rather than judging the SESSION repository in its
# place, and every push gate exits 0 on that refusal. That is right for each gate, and it left the
# push unjudged. #552 made this hook SAY so, as context the model received, and let the push
# through; on 2026-09-29 an Ovation subagent pushed with `git -C "<worktree path>" push`, the quoted
# path did not resolve, and no global gate (tests, style, the lessons scan) checked the push. A gate
# that cannot find its target and then lets the command through fails open (L42, L320), so this now
# refuses with the reason, ONCE, here, rather than each of the thirteen gates refusing in its own
# words. It asks the same two library questions the gates ask (is this a push, which repository),
# so it cannot disagree with them about when they stood down.
#
# The remedy is in the refusal: spell the path so it resolves, or cd into the repository first.
# Nothing is wrong with the push itself, only with how it names where it runs.
#
# Since claude-config#1062 it refuses a second shape the gates stand down on: one command pushing
# from more than one repository. Every gate judges one repository per command and judged the first
# push's, so the rest went out unjudged. That refusal has its own sentence and remedy (run each
# repository's push on its own), because a resolved path is not the problem there (L11).
#
# Since claude-config#2070 it refuses a third: a push from a repository whose core.hooksPath names a
# folder that does not exist. git then runs none of the repository's own hooks and says nothing (a
# push exits 0 with no pre-push run, measured with a throwaway repository on 2026-11-02). Bidspoke
# sets core.hooksPath to .husky/_, which only `pnpm install` creates, so a worktree that never ran the
# install pushed PR #3199, a live migration, with no SQL suite, test gate or style gate. The refusal
# names the folder, the install that creates it (read from the lockfile at the top level, or the
# step in general words when there is none), and the main session's one command override,
# SKIP_HOOKS_PATH_CHECK=1. An agent gets no override, as it gets none for any other skip of the
# repository's hooks (no-verify-gate.sh, claude-config#1666). Something at the path that is not a
# folder (core.hooksPath=/dev/null) is hooks switched off on purpose and is left to git; a read of the
# setting that fails refuses, since a setting that cannot be read is not one that is fine.
# Measured on the personal MacBook on 2026-11-02: 5 repositories set core.hooksPath, across 8 working
# trees, and the folder was present in all 8, so no push there would have been refused by this.
# Bidspoke is on the work MacBook and was not measured.
#
# Since claude-config#2135, for an AGENT's push only, a location that exists but holds no hook git
# would run (/dev/null, an empty folder, a folder of samples) refuses too: an agent can set it
# itself, and the no-verify gate refuses only the config writes it can read. The main session's push
# is unchanged. Measured on the personal MacBook on 2026-11-03: the 5 repositories that set the key
# each point at a folder holding an executable pre-push, and none sets /dev/null (global and system
# unset), so no agent push there is refused by this.
#
# measure-hooks-path.sh, beside this file, asks this gate about every working tree under the folders
# it is given, so either Mac can measure itself (claude-config#2098). On the personal MacBook on
# 2026-11-12: 36 working trees, 7 setting core.hooksPath, every one a folder with a runnable hook,
# /dev/null set nowhere (global, system or local), no push refused. The work MacBook is still
# unmeasured, so whether /dev/null anywhere is hooks off on purpose remains unseen, and the main
# session's pass for it stands until it is.
#
# Since claude-config#3062 it refuses a push whose command first commits a merge of the default
# branch that is still in progress, `git commit --no-edit && git push`: before that commit exists no
# gate can tell main's lines from the branch's, and every one reads them all as the branch's own. The
# remedy is the same push as two commands, which the gates already set apart (ps_merged_apart).
# Since claude-config#3081 `git merge --continue && git push` is that command too: the library
# question this asks now reads a merge --continue as the commit it makes. Since claude-config#3091
# it reads either one written inside brackets too, `(git commit --no-edit) && git push`.
#
# Since claude-config#3092 it refuses a push whose command first runs a git rebase, cherry-pick,
# revert, am, merge of a named branch or pull: the commits those make do not exist when the gates
# run and no gate reads them, so they went out unjudged. The remedy is the same, two commands.
#
# Since claude-config#3098 it refuses a push whose command first moves the branch without making a
# commit (a git checkout or switch of another branch, a git reset to another commit, a rebase
# abandoned), or changes the index by a route other than git add and then commits (git stash pop,
# git apply --index, git rm, a path taken from another commit). The remedy is the same again.
#
# Since claude-config#3113 it refuses a push whose command first runs something that may write a
# file and then stages, commits and pushes it (cp, sed -i, a formatter, a script, git apply): the
# gates read the files as they stood before the command ran. The remedy is the write as a command
# of its own. Since claude-config#3112 it refuses a push that names a branch, tag or commit other
# than the branch checked out, when that holds commits neither this branch nor the remote has, or
# cannot be resolved before the command runs: the gates read the branch checked out and its files.
# The remedy is to push it from a checkout of it. A commit that names its own paths (#3111) is not
# refused: the library reads the paths, so the gates judge them.
set -uo pipefail

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
# shellcheck source=lib/push-scope.sh
{ . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && declare -F ps_parse_payload >/dev/null; } || {
  # A library this gate cannot load is not a push with nothing to check (claude-config#1900, L10):
  # with it missing nothing here can tell a push from any other command, so a command naming one
  # is refused, naming the file, and any other passes as it would have.
  payload="$(cat)"
  case "$payload" in *push*) ;; *) exit 0 ;; esac
  echo "BLOCKED: push-scope-notice.sh could not load $HOOK_DIR/lib/push-scope.sh, which reads whether this command pushes and what it carries, so this command could not be checked. A library this gate cannot load is not a push with nothing to check. Reinstall the hooks with claude-sync pull." >&2
  exit 2
}

payload="$(ps_read_payload)"
parsed="$(ps_parse_payload "$payload" segmented)" \
  || ps_unparsed_refuse "$payload" push-scope-notice.sh - "a push" '*push*'
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
ps_is_git_push "$cmd" || exit 0

# Every hook git runs, by the file name it looks for (githooks(5)), so a folder holding none of them
# runs nothing (claude-config#2135).
GIT_HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push pre-receive update proc-receive post-receive post-update reference-transaction push-to-checkout pre-auto-gc post-rewrite sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change"

# The repository's OWN hooks, the third thing that judges a push (claude-config#2070). Returns when
# they can run; refuses otherwise. git resolves core.hooksPath itself (rev-parse --git-path hooks
# answers relative to the directory it is asked in, expands a tilde, and reads a linked worktree
# against its own top level), so the folder checked is the one git will look in, never a guess.
hooks_folder_check() {   # $1 = the one repository directory the push runs in
  local d="$1" hp grc where top fix
  [ -n "$d" ] || return 0
  hp="$(git -C "$d" config --get core.hooksPath 2>/dev/null)"; grc=$?
  [ "$grc" -eq 1 ] && return 0   # not set: git's own .git/hooks, which always exists to look in
  # Asked at the top level, so a push from a subdirectory names the folder the way git resolves it
  # for the hooks, which run there.
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)"; [ -n "$top" ] || top="$d"
  if [ "$grc" -eq 0 ]; then
    where="$(git -C "$top" rev-parse --git-path hooks 2>/dev/null)" || grc=$?
  fi
  if [ "$grc" -ne 0 ] || [ -z "$where" ]; then
    printf 'PUSH REFUSED: this hook could not read where the git hooks of %s live (reading core.hooksPath exited %s), so it cannot tell whether the repository'"'"'s own pre-push hook would run, and a push it cannot read is not one whose hooks are fine (claude-config#2070). Run git -C %s config --get core.hooksPath to see why, and push again once it reads.\n' \
      "$d" "$grc" "$d" >&2
    exit 2
  fi
  case "$where" in /*) ;; *) where="$top/$where" ;; esac
  # For the main session, anything at the path is left to git: a file such as /dev/null is hooks
  # switched off on purpose, a person's own choice. For an AGENT it is not (claude-config#2135): an
  # agent may have set it itself, through a config write the no-verify gate refuses or an edit of the
  # config file no Bash gate sees, so a location holding no hook git would run refuses an agent's
  # push. A hook git runs is an executable file named after one.
  if [ -e "$where" ]; then
    case "$payload" in *'"agent_id"'*) ;; *) return 0 ;; esac
    if [ -d "$where" ]; then
      local h
      for h in $GIT_HOOK_NAMES; do
        [ -f "$where/$h" ] && [ -x "$where/$h" ] && return 0
      done
    fi
    printf 'PUSH REFUSED: this repository'"'"'s git hooks are read from %s (core.hooksPath %s), which holds no hook git would run, so this push would run none of the repository'"'"'s own hooks (pre-push and the checks it starts). An agent may not push with the hooks switched off, and may not change where git reads them from (claude-config#2135). If the repository has a hook install script, run it in %s and push again; otherwise hand back and say so, and the main session pushes.\n' \
      "$where" "$hp" "$top" >&2
    exit 2
  fi
  if [ -f "$top/pnpm-lock.yaml" ]; then fix="pnpm install"
  elif [ -f "$top/yarn.lock" ]; then fix="yarn install"
  elif [ -f "$top/bun.lockb" ] || [ -f "$top/bun.lock" ]; then fix="bun install"
  elif [ -f "$top/package-lock.json" ]; then fix="npm install"
  else fix=""; fi
  if [ -n "$fix" ]; then fix="run $fix in $top, which creates it"
  else fix="run the repository's install, the step that creates that folder, in $top"; fi
  case "$payload" in
    *'"agent_id"'*)
      printf 'PUSH REFUSED: the hooks folder this repository'"'"'s git hooks live in, %s (core.hooksPath %s), does not exist, so git would run none of its own hooks for this push (pre-push and the checks it starts) and say nothing (claude-config#2070). To fix it, %s, then push again. The one command override is not available to an agent, as no skip of the repository'"'"'s hooks is (claude-config#1666): if the install cannot run, hand back and say so.\n' \
        "$where" "$hp" "$fix" >&2
      exit 2 ;;
  esac
  ps_has_override "$cmd" SKIP_HOOKS_PATH_CHECK && return 0
  printf 'PUSH REFUSED: the hooks folder this repository'"'"'s git hooks live in, %s (core.hooksPath %s), does not exist, so git would run none of its own hooks for this push (pre-push and the checks it starts) and say nothing (claude-config#2070). To fix it, %s, then push again. To push without them this once, put SKIP_HOOKS_PATH_CHECK=1 in front of the push.\n' \
    "$where" "$hp" "$fix" >&2
  exit 2
}

# A merge of the default branch still in progress, concluded by this command before it pushes, with
# a git commit (claude-config#3062) or a git merge --continue (#3081). The merge commit does not
# exist yet, so every gate reads the commit this command is about to make against the branch's last
# commit, and judges every line main brought in as the branch's own; run as two commands, the merge
# is committed when the push is judged and the gates set it apart (ps_merged_apart). The rule and
# why it is a refusal rather than a second reading live
# with the question, ps_pending_merge_of_default in lib/push-scope.sh. The gates still run beside this
# hook and may report main's lines, so the refusal says not to edit them. No override: the remedy is
# one more command, and every gate would judge the same lines wrongly under one.
pending_merge_check() {   # $1 = the one repository directory the push runs in
  local def
  def="$(ps_pending_merge_of_default "$cmd" "$1")" || return 0
  printf 'PUSH REFUSED: this command concludes a merge of %s that is still in progress and pushes in the same breath. The merge commit does not exist yet when the push gates run, so every gate (tests, style, deferrals, scanners and the rest) reads the commit this command is about to make as this branch'"'"'s own work and judges every line %s brought in as if this branch wrote it (claude-config#3062). A finding another gate reports for this command may be a line %s already holds: do not edit it. Run everything before the push (the git add, and the git commit or git merge --continue) as a command of its own, then push as a command of its own, and the gates will set the merge apart.\n' \
    "$def" "$def" "$def" >&2
  exit 2
}

# A route question below that could not be asked is not one answered no (L1033, claude-config#1900).
# Each answers 0 with a route or 1 with none. Any other exit (127 when the library beside this hook
# is an older one that lacks the function) used to read as none, and the command went through with
# nothing said. Found by the lessons review of #3098.
unasked() {   # $1 = the library question  $2 = its exit code
  printf 'PUSH REFUSED: push-scope-notice.sh could not ask whether this command changes what it pushes before it pushes: %s exited %s (127 means %s does not hold it, a library older than this hook). A question that could not be asked is not one answered no. Reinstall the hooks with claude-sync pull, then push again.\n' \
    "$1" "$2" "$HOOK_DIR/lib/push-scope.sh" >&2
  exit 2
}

# A git command before the push that puts commits on the branch by a route no gate reads: a rebase,
# cherry-pick, revert, am, merge of a named branch or pull (claude-config#3092). What it will make
# is nowhere a gate can read before the command runs, so every gate judges the range as it stands
# and the new commits go out unjudged; run as two commands they are in the range when the push is
# judged. Which commands, what was measured and why this refuses rather than reads live with the
# question, ps_unread_commit_route in lib/push-scope.sh. No override, as for the pending merge: the
# remedy is one more command.
unread_route_check() {
  local route rc
  route="$(ps_unread_commit_route "$cmd" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] && return 0
  [ "$rc" -eq 0 ] || unasked ps_unread_commit_route "$rc"
  printf 'PUSH REFUSED: this command runs %s before it pushes. What that puts on the branch (the commits it makes, or the changes it stages for a commit later in the command) does not exist yet when the push gates run, so no gate (tests, style, deferrals, scanners and the rest) can read it, and it would be pushed with none of them having judged it (claude-config#3092). Run everything before the push as a command of its own, then push as a command of its own, and the gates will read what it made.\n' \
    "$route" >&2
  exit 2
}

# A git command before the push that makes no commit and still changes what the push sends
# (claude-config#3098). One kind MOVES the branch: a checkout or switch of another branch, a reset
# to another commit, a sequence abandoned back to where it began. The push then sends commits that
# were never in the range a gate read, or leaves out ones that were. The other kind changes the
# INDEX by a route other than git add (a stash put back, a patch applied with --index, a path taken
# from another commit, a git rm) ahead of a commit: the gates fold that pending commit in from the
# index as it was before the command ran. Which spellings, what was measured and what is let
# through live with the question, ps_unread_move_or_stage in lib/push-scope.sh. Each kind has its
# own sentence and remedy (L11). No override, as for the routes above: the remedy is one more
# command.
unread_move_check() {
  local found kind route rc
  found="$(ps_unread_move_or_stage "$cmd" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] && return 0
  [ "$rc" -eq 0 ] || unasked ps_unread_move_or_stage "$rc"
  kind="${found%% *}"; route="${found#* }"
  if [ "$kind" = move ]; then
    printf 'PUSH REFUSED: this command runs %s before it pushes. That can put the branch on commits it was not on when the push gates ran, or take it off ones it was on, so what the push would send is not what the push gates read (tests, style, deferrals, scanners and the rest), and it would go out with none of them having judged it (claude-config#3098). Run everything before the push as a command of its own, then push as a command of its own, and the gates will read the branch where it then stands.\n' \
      "$route" >&2
  else
    printf 'PUSH REFUSED: this command runs %s, then commits and pushes. What that puts into the index or takes out of it is not in the index when the push gates run, so the commit this command makes would not hold what the gates read for it (tests, style, deferrals, scanners and the rest), and it would be pushed with none of them having judged it (claude-config#3098). Run everything before the commit as a command of its own, then commit and push, and the gates will read what is staged.\n' \
      "$route" >&2
  fi
  exit 2
}

# Something before the staging step of a command that stages, commits and pushes, which may write a
# file (claude-config#3113). The gates read the working files as they stand before the command
# runs, so what it writes is staged, committed and pushed unread. Which commands are let stand (the
# ones measured to change no file) and the order that counts live with the question, ps_unread_write
# in lib/push-scope.sh. No override, as for the routes above: the remedy is one more command.
unread_write_check() {
  local found rc
  found="$(ps_unread_write "$cmd" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] && return 0
  [ "$rc" -eq 0 ] || unasked ps_unread_write "$rc"
  printf 'PUSH REFUSED: this command runs %s, then stages, commits and pushes. The push gates (tests, style, deferrals, scanners and the rest) read the files as they stand before the command runs, so anything that step writes would be staged, committed and pushed with none of them having read it (claude-config#3113). Run everything before the git add (or before the commit, when the commit takes the files itself) as a command of its own, then add, commit and push, and the gates will read the files as they then stand.\n' \
    "$found" >&2
  exit 2
}

# A push that names something other than the branch checked out (claude-config#3112). What it names
# is read first: HEAD, the branch checked out, anything in its history or already on the remote, a
# name this command makes where HEAD is, and a deletion are all what the gates judged. What is left
# has its own sentence and remedy for each cause (L11): a source holding commits the gates did not
# read, one that cannot be resolved before the command runs, and one the command makes or moves
# first. The rule and what was measured live with the question, ps_unread_push_source in
# lib/push-scope.sh. No override: the remedy is to push it from where the gates can read it.
unread_source_check() {   # $1 = the one repository directory the push runs in
  local found kind src rc where
  found="$(ps_unread_push_source "$cmd" "$1" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] && return 0
  [ "$rc" -eq 0 ] || unasked ps_unread_push_source "$rc"
  kind="${found%% *}"; src="${found#* }"
  case "$kind" in
    other)
      case "$src" in
        --*)
          printf 'PUSH REFUSED: this command pushes with %s, which sends a branch or tag other than the branch checked out here, holding commits that neither this branch nor the remote has. The push gates (tests, style, deferrals, scanners and the rest) read the branch checked out and its files, so those commits would be pushed with none of them having judged them (claude-config#3112). Push each branch from a checkout of it, as a command of its own, and the gates will read it.\n' \
            "$src" >&2
          exit 2 ;;
      esac
      # Where the branch is checked out, when it is: the push from there is the whole remedy. One
      # pass that reads to the end, never an early exit that would leave git writing to nobody.
      where="$(git -C "$1" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/${src#refs/heads/}" '
        /^worktree / { w = substr($0, 10) }
        $1 == "branch" && $2 == b && !found { print w; found = 1 }')" || where=""
      if [ -n "$where" ]; then
        where="It is checked out in $where: run the push there (cd into it, or git -C $where push), as a command of its own, and the gates will read it."
      else
        where="Check it out as a command of its own (git checkout $src), then push as a command of its own, and the gates will read it."
      fi
      printf 'PUSH REFUSED: this command pushes %s, which is not the branch checked out here and holds commits that neither this branch nor the remote has. The push gates (tests, style, deferrals, scanners and the rest) read the branch checked out and its files, so those commits would be pushed with none of them having judged them (claude-config#3112). %s\n' \
        "$src" "$where" >&2 ;;
    moved)
      printf 'PUSH REFUSED: this command pushes %s after a command that makes or moves it, or after a commit, so where it will stand when the push runs is not known when the push gates run, and they cannot tell whether it is what they read (claude-config#3112). Run everything before the push as a command of its own, then push as a command of its own.\n' \
        "$src" >&2 ;;
    *)
      printf 'PUSH REFUSED: this command pushes %s, which cannot be resolved to a commit before the command runs (a variable, a pattern, or a name that is no branch, tag or commit here), so the push gates cannot tell whether it is the branch they read (claude-config#3112). Name what is pushed outright: HEAD for the branch checked out, or the branch by its own name. If a command works the name out, run that as a command of its own, then push naming it.\n' \
        "$src" >&2 ;;
  esac
  exit 2
}

# Asked through ps_repo_dirs, the list ps_repo_dir is built on, so the two causes of a gate standing
# down get their own sentence and their own remedy (L11, L111): a directory that could not be
# resolved (exit 2), or pushes into MORE THAN ONE repository (claude-config#1062), each of which
# resolved, where every gate judges one repository per command and would judge only the first.
# One capture: on exit 0 it holds the directories and nothing else, on exit 2 the sentence saying why.
out="$(ps_repo_dirs "$cmd" "$cwd" 2>&1; printf '\035%s' "$?")"
rc="${out##*$'\035'}"; out="${out%$'\035'*}"
dirs="$out"; err="$out"
# rc 1 (no repository named and none at the session directory) is a push git itself will refuse, and
# a single repository is a push the gates do judge.
if [ "$rc" -eq 0 ]; then
  case "$dirs" in *$'\n'?*) ;; *) hooks_folder_check "${dirs%%$'\n'*}"; pending_merge_check "${dirs%%$'\n'*}"; unread_route_check; unread_move_check; unread_write_check; unread_source_check "${dirs%%$'\n'*}"; exit 0 ;; esac
  printf 'PUSH REFUSED: this command pushes from more than one repository (%s), and every push gate (tests, style, scanners, docs and the rest) judges one repository per command, so the pushes after the first would go out with no gate having looked at them (claude-config#1062). Run each repository'"'"'s push as a command of its own.\n' \
    "$(printf '%s' "$dirs" | awk 'NF' | paste -sd ',' - | sed 's/,/, /g')" >&2
  exit 2
fi
[ "$rc" -eq 2 ] || exit 0

printf 'PUSH REFUSED: no push gate could judge this push (tests, style, scanners, docs and the rest would all stand down), because it names a directory they could not resolve, and they do not fall back to %s in its place (claude-config#532, #589). %s Push again with the path spelled so it resolves (spell it absolutely, with no variable, or cd into the repository first).\n' \
  "${cwd:-the session directory}" "$err" >&2
exit 2
