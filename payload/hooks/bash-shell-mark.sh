#!/usr/bin/env bash
# SessionStart: make every shell the Bash tool starts in this session record its own process id
# (claude-config#3561), so a process a command leaves running can be tied to the session whose
# command started it. lib/agent-leftovers.py reads the record; agent-leftovers-gate.sh says what it
# finds, at an agent's hand back and at its stop.
#
# WHY A RECORD AT ALL. Measured on the personal MacBook on 2026-11-25, in a subagent's own Bash
# calls (5 children of 2 calls): the Bash tool starts each command in a shell that leads its own
# process group and is a child of the Claude Code process, and a child that outlives the command
# keeps that group and is handed to launchd (parent 1), a plain `cmd &`, a `nohup` and a `( cmd & )`
# alike. So the group is the tie, and its number is the dead shell's process id. Nothing else names
# the session once the shell has gone:
#   - the environment carries CLAUDE_CODE_SESSION_ID, but ps cannot read the environment of the
#     programs macOS ships (0 of 5 readable: sleep, bash, zsh; a Homebrew python was readable),
#     and the 19 shells of 2026-11-24 were bash and zsh;
#   - the working folder is the project's, the same for every session in the repository;
#   - the command's own output file is inherited only by a child that redirects nothing.
# No variable in a Bash call's environment names the AGENT, so which agent's command it was is
# read from the agent's own transcript, by time (lib/agent-leftovers.py).
#
# HOW. Claude Code sources the session's env file before every Bash command, its subagents'
# included (gh-guard-path.sh, measured 2026-11-03), each line a statement of its own (the text after
# them begins a new list, read off a live shell's start line on 2026-11-25). The line this writes
# makes an empty file named for the shell's process id in the session's marker folder: one builtin
# redirection, no process started, nothing printed, and a failure (the folder gone) is silent and
# leaves the command to run (both measured in bash 3.2.57 and zsh 5.9). A file made again by a later
# shell with the same number takes the new time (measured: its modification time moves, its size
# stays 0).
#
# The folder is under TMPDIR, which macOS empties of what nobody has touched for about three and a
# half days, so nothing here needs sweeping; a marker that old belongs to no agent still running.
#
# A session that started before this hook was installed has no line and no folder, and the reader
# says of it that it cannot tell, never that nothing was left.
#
# THE SEAM FOR A TIME LIMIT RUNNER (claude-config#3578). A runner that puts what it starts in a
# process group of its own takes it out of the shell's group, where this record cannot follow. Such
# a runner makes the same empty file, named for the new group's id, in the folder
# `python3 hooks/lib/agent-leftovers.py dir "$CLAUDE_CODE_SESSION_ID"` prints, and the reader then
# ties that group as it ties a shell's.

set -uo pipefail

case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
payload="$(cat 2>/dev/null || true)"
# Cleaned by the shared reader (claude-config#1944); without the library it is read as it came.
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"

# Matched through payload_match, as every hook reading its raw payload is (#1885): a byte that is not
# UTF-8 earlier in the payload hides every word after it from =~ under a UTF-8 locale, so the C
# locale is tried as well.
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }

session=""
if payload_match "$payload" '"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'; then session="${BASH_REMATCH[1]}"; fi
[ -n "$session" ] || session="${CLAUDE_CODE_SESSION_ID:-}"

# The folder holding every session's marker folder: lib/agent-leftovers.py derives the same path
# (marks_root), and test-agent-leftovers.sh holds the two to one answer. Under a test suite it is
# never this Mac's real record.
root="${AGENT_LEFTOVERS_ROOT:-}"
if [ -z "$root" ]; then
  root="${TMPDIR:-/tmp}"; root="${root%/}/claude-shell-marks-$(id -u)"
  run="${CLAUDE_SUITE_RUN_ID:-}"; run="${run//[^A-Za-z0-9_-]/}"
  [ -z "$run" ] || root="$root-suite-$run"
fi
root="${root%/}"

unrecorded() {
  echo "Leftover process check: $1, so this session's Bash commands are not recorded, and what an agent leaves running cannot be told this session (claude-config#3561)."
  exit 0
}

# The id becomes a folder name and sits inside single quotes in a line every shell runs.
case "$session" in
  ''|*[!A-Za-z0-9_-]*) unrecorded "the session id handed to bash-shell-mark.sh is not a plain name" ;;
esac
[ "${#session}" -le 64 ] || unrecorded "the session id handed to bash-shell-mark.sh is longer than a folder name it will make"
case "$root" in
  /*) ;;
  *) unrecorded "the marker folder ($root) is not an absolute path" ;;
esac
case "$root" in
  *"'"*|*$'\n'*) unrecorded "the marker folder's path holds a quote or a line break" ;;
esac
[ -n "${CLAUDE_ENV_FILE:-}" ] || unrecorded "this session was given no CLAUDE_ENV_FILE"

dir="$root/$session"
( umask 077; mkdir -p "$dir" ) 2>/dev/null || unrecorded "the marker folder $dir could not be made"

line="{ : >| '$dir/'\$\$; } 2>/dev/null"
# SessionStart fires again at a resume, a clear and a compaction, and the env file is the same
# file: the line is written once.
if grep -qxF -- "$line" "$CLAUDE_ENV_FILE" 2>/dev/null; then exit 0; fi
printf '%s\n' "$line" >> "$CLAUDE_ENV_FILE" 2>/dev/null || unrecorded "this session's env file could not be written"
exit 0
