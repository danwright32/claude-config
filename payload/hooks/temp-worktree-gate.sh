#!/usr/bin/env bash
#
# temp-worktree-gate.sh
# Claude Code PreToolUse(Bash|EnterWorktree) hook: refuse a git worktree placed under a temp folder a
# restart empties (/tmp, /private/tmp, /var/folders, $TMPDIR), by `git worktree add`, `git worktree
# move` or EnterWorktree's path, naming the repository's .claude/worktrees/<name> instead
# (claude-config#2528).
#
# On 2026-11-09 a restart emptied /private/tmp and took an agent's worktree holding an uncommitted
# fix. #2490 told agents in the global rules and the briefs to put worktrees in the repository's
# .claude/worktrees/, and a rule that lives only in a prompt is a hope (L27), so this makes it hold.
#
# WHAT A TEMP WORKTREE IS is lib/temp-worktree.py's, over lib/shell-words.py, the one reading every
# gate uses: behind rtk, env, a cd or a `bash -c` string, with git's -C folders composed, absolute or
# relative. Words that only mention one (an echo, a commit message) are not one, and list, remove and
# prune pass. A repository that is itself in a temp folder loses nothing more by its worktree being
# there, so a worktree of one passes.
#
# WHO IS ASKED: everyone. A restart takes the main session's worktree as surely as an agent's.
#
# A call this cannot read (no python3, a library missing, a payload that is not a call, a path held
# in a variable, the reader crashing) is refused when it names a worktree add or move, and passes
# otherwise (L42, L490): a path nobody can know may be a temp one, and writing it literally costs one
# retry.
#
# Override, for one command and visible in it: ALLOW_TEMP_WORKTREE=1 <the same command>.

set -uo pipefail
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"

refuse() { printf 'REFUSED (temp-worktree-gate.sh): %s\n' "$1" >&2; exit 2; }

# The one degraded judgement, for every path that cannot read the call (L370).
refuse_unread() {   # $1 = the text to look in, $2 = why it could not be read
  case "$1" in *ALLOW_TEMP_WORKTREE=1*) exit 0 ;; esac
  case "$1" in
    *"worktree add"*|*"worktree move"*|*EnterWorktree*path*)
      refuse "this call places a git worktree, and $2, so whether it goes under a temp folder a restart empties cannot be told. Put worktrees in the repository's .claude/worktrees/ folder, with the path written literally (claude-config#2528). If this worktree really is throwaway, for this one command: ALLOW_TEMP_WORKTREE=1 <the same command>." ;;
  esac
  exit 0
}

{ . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && declare -F ps_read_payload >/dev/null; } || {
  payload="$(cat)"
  case "$payload" in *orktree*) ;; *) exit 0 ;; esac
  refuse_unread "$payload" "lib/push-scope.sh could not be loaded from $HOOK_DIR/lib; reinstall the hooks with claude-sync pull"
}

payload="$(ps_read_payload)"
# Nearly every call leaves here, before anything starts.
case "$payload" in *orktree*) ;; *) exit 0 ;; esac

unparsed() {
  ps_unparsed_refuse "$payload" temp-worktree-gate.sh ALLOW_TEMP_WORKTREE \
    "a git worktree placed under a temp folder a restart empties" '*worktree add*' '*worktree move*' '*EnterWorktree*path*'
}

if ps_reader_missing python3 || [ ! -f "$HOOK_DIR/lib/temp-worktree.py" ]; then
  refuse_unread "$(ps_payload_text "$payload")" "python3 (or lib/temp-worktree.py) is missing; install python3 or reinstall the hooks"
fi

case "$payload" in
  *'"EnterWorktree"'*)
    kind=enter
    ps_payload_unread "$payload" path && unparsed
    parsed="$(printf '%s' "$payload" | python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
ti = d.get("tool_input") or {}
cwd = d.get("cwd")
sys.stdout.write((ti.get("path") or "") + "\x1f" + (cwd if isinstance(cwd, str) else ""))
' 2>/dev/null)" || unparsed ;;
  *)
    kind=bash
    # jq where it is, python3 otherwise, as every gate reads a command (lib/push-scope.sh).
    parsed="$(ps_parse_payload "$payload" raw 2>/dev/null)" || unparsed
    case "${parsed%%$'\x1f'*}" in *worktree*) ;; *) exit 0 ;; esac
    ps_payload_unread "$payload" command && unparsed ;;
esac
value="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cwd" ] || cwd="$PWD"
[ -n "$value" ] || exit 0
look="$value"
if [ "$kind" = bash ]; then
  ps_has_override "$value" ALLOW_TEMP_WORKTREE && exit 0
else
  look="EnterWorktree path $value"
fi

said="$(printf '%s' "$value" | python3 "$HOOK_DIR/lib/temp-worktree.py" "$kind" "$cwd" 2>&1)"; rc=$?
# 10 is the reader's "nothing to refuse"; 3 is a call naming a worktree that it cannot read, and
# anything else a crash, judged by the words the call holds.
case "$rc" in
  10) exit 0 ;;
  0) refuse "$said" ;;
  3) refuse "this call places a git worktree, and $said. Put worktrees in the repository's .claude/worktrees/ folder (claude-config#2528). If this worktree really is throwaway, for this one command: ALLOW_TEMP_WORKTREE=1 <the same command>." ;;
  *) refuse_unread "$look" "lib/temp-worktree.py could not read it (exit $rc: ${said##*$'\n'})" ;;
esac
