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
  case "$dirs" in *$'\n'?*) ;; *) hooks_folder_check "${dirs%%$'\n'*}"; exit 0 ;; esac
  printf 'PUSH REFUSED: this command pushes from more than one repository (%s), and every push gate (tests, style, scanners, docs and the rest) judges one repository per command, so the pushes after the first would go out with no gate having looked at them (claude-config#1062). Run each repository'"'"'s push as a command of its own.\n' \
    "$(printf '%s' "$dirs" | awk 'NF' | paste -sd ',' - | sed 's/,/, /g')" >&2
  exit 2
fi
[ "$rc" -eq 2 ] || exit 0

printf 'PUSH REFUSED: no push gate could judge this push (tests, style, scanners, docs and the rest would all stand down), because it names a directory they could not resolve, and they do not fall back to %s in its place (claude-config#532, #589). %s Push again with the path spelled so it resolves (spell it absolutely, with no variable, or cd into the repository first).\n' \
  "${cwd:-the session directory}" "$err" >&2
exit 2
