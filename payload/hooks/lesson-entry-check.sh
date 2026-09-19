#!/usr/bin/env bash
#
# lesson-entry-check.sh
# Claude Code PostToolUse(Edit|Write|MultiEdit) hook: check a lesson the moment it is WRITTEN,
# while the session that wrote it is still there to fix it (claude-config#374).
#
# A lesson entry written into LESSONS.md in the wrong shape is invisible from the moment it is
# saved: absent from LESSONS-INDEX.md, which loads into every session in every project, unreadable
# by `claude-sync lesson`, uncounted by the duplicate check and by the number minter. Nothing
# reported it. The only thing that noticed was the next sync, which can be days later, and by then
# the malformed entry had been holding the ENTIRE lessons file back from publishing, so every
# lesson written after it was stuck too.
#
# Measured 2026-09-11: L683 and L684, both written on this Mac, were each missing their bold
# marker, and neither had ever appeared in the index. The pull that finally reported them also
# reported that LESSONS.md was being held back, which had silently blocked the other unsent lesson
# edits sitting beside it. A second fault then surfaced only after the first was fixed, because the
# cap check cannot see an entry the format check rejects.
#
# IT COPIES NO PREDICATE. It runs `claude-sync lesson-faults`, which walks the same list the send
# walks, so the write time check and the gate cannot disagree about what a fault is (L41, L686). A
# fifth fault added to that list reaches this hook with nothing here to change.
#
# `lesson-faults` rather than `check-lessons` because it takes no lock. check-lessons can reach the
# band claim, which waits on the sync lock and then REFUSES, so on this path it would say nothing
# about the lesson precisely while the watcher was busy (L110).
#
# Speaks only about the lessons file the sync publishes, which is the one under the config root. A
# project's own notes named LESSONS.md are not governed by any of this.
#
# Env:
#   CLAUDE_HOME            the config root (default ~/.claude)
#   SYNC_CLONE_REGISTRY    where the clones of the tool on this Mac are recorded
#                          (default ~/.claude-sync-clones, written by the tool itself)

set -uo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLONE_REGISTRY="${SYNC_CLONE_REGISTRY:-$HOME/.claude-sync-clones}"

payload="$(cat 2>/dev/null || true)"

# THE READER THIS WHOLE CHECK RUNS THROUGH, asked first (claude-config#486, L490).
#
# Both halves of this hook are python3: the file the tool call wrote is read out of the payload
# with it, and the answer is emitted as JSON by it. With no python3 the target came back empty and
# the hook exited 0 in silence, so a lesson written into LESSONS.md was never checked. That is the
# same quiet as a lesson with nothing wrong in it, and that quiet is the whole reason this file
# exists: it is what let two malformed entries sit for days holding the lessons file back (L98).
#
# It speaks on stderr with exit 2 rather than through block(), because block() builds its JSON
# with the interpreter that is missing. PostToolUse feeds a non zero exit's stderr back to the
# model, which is the same place a block reason lands.
#
# Narrowed on the RAW payload, since nothing here can read which file was written: it must mention
# both the config root and the lessons file by name. That is strictly narrower than the real
# predicate (a path reaching the same file through a symlink does not match, and stays silent as
# it did before), and it never speaks about a project's own notes named LESSONS.md, which this
# hook is not about (L54, L324).
if ! command -v python3 >/dev/null 2>&1; then
  case "$payload" in
    *"$CLAUDE_HOME"*LESSONS.md*|*LESSONS.md*"$CLAUDE_HOME"*)
      {
        echo "LESSON CHECK DID NOT RUN: python3 is not on PATH, and lesson-entry-check.sh reads the written file out of the tool payload with it and runs claude-sync lesson-faults over the entry. Nothing has judged the lesson just written into $CLAUDE_HOME/LESSONS.md."
        echo "Until python3 is installed, a malformed or over length entry is invisible: absent from LESSONS-INDEX.md (which loads into every session in every project), unreadable by 'claude-sync lesson', uncounted by the duplicate check and by the number minter, and it holds the WHOLE lessons file back from the next send, so every lesson written after it is stuck too."
        echo "Check the entry by hand now, or install python3 and confirm with: claude-sync lesson-faults"
      } >&2
      exit 2 ;;
  esac
  exit 0
fi

# The file this tool call wrote. A payload that names none is nothing to do with a lessons file, so
# there is nothing to check and nothing to say. That is not the same as a check that ran and found
# nothing, and the difference only matters once a file IS named, which is where the reporting below
# is careful.
target="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
ti = d.get("tool_input") or {}
print(ti.get("file_path") or "")
' 2>/dev/null || true)"
[ -n "$target" ] || exit 0

# Compared as REAL paths on both sides, because a symlinked config root or a path written through
# one reaches the same file by a name that does not match (the same rule the clone walk follows).
real_of(){   # real_of <path> -> the path with its directory resolved, or the path unchanged
  local d b
  d="$(dirname "$1")"; b="$(basename "$1")"
  d="$(cd "$d" 2>/dev/null && pwd -P)" || { printf '%s' "$1"; return 0; }
  printf '%s/%s' "$d" "$b"
}
[ "$(real_of "$target")" = "$(real_of "$CLAUDE_HOME/LESSONS.md")" ] || exit 0

# Emit a block, with the reason JSON encoded rather than pasted, so a fault quoting a lesson's own
# text cannot break the payload.
block(){   # block <reason text>
  printf '%s' "$1" | python3 -c '
import json, sys
print(json.dumps({"decision": "block", "reason": sys.stdin.read()}, separators=(",", ":")))
' 2>/dev/null || true
  exit 0
}

# Which clone of the tool to ask. Read from the registry the tool maintains itself, never a path
# written down here: a clone appends itself the first time it takes the lock, so the list is
# derived from what has actually run (L41), and it is right on both Macs with nothing to configure.
sync=""
while IFS= read -r clone; do
  [ -n "$clone" ] || continue
  if [ -f "$clone/claude-sync" ]; then sync="$clone/claude-sync"; break; fi
done < "$CLONE_REGISTRY" 2>/dev/null

if [ -z "$sync" ]; then
  # NOT silence. A lesson that was not checked and a lesson with nothing wrong arrive as the same
  # quiet, and this file was opened because that quiet is what let two broken entries sit for days
  # (L98, L11).
  block "The lesson you just wrote into $CLAUDE_HOME/LESSONS.md could not be checked: no clone of claude-sync is recorded in $CLONE_REGISTRY, so nothing here could run 'claude-sync lesson-faults' against it. Until that is fixed a malformed or over length entry will be invisible until the next sync, which can be days away, and it holds the WHOLE lessons file back from publishing while it waits. Run 'claude-sync status' from a checkout of the config repo to register it, then check the entry by hand with 'claude-sync lesson-faults'."
fi

# SYNC_NO_NOTIFY, because a fault here is reported INTO the session that caused it and a desktop
# notification as well would be the same thing said twice, to somebody who is already looking at
# it. The tool notifies on a non interactive failure by design, which is right for the background
# sync job and wrong for a hook: run from a test suite it puts a real notification on the real
# screen, which is how this was found (L2).
out="$(CLAUDE_HOME="$CLAUDE_HOME" SYNC_NO_NOTIFY=1 "$sync" lesson-faults 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && exit 0

# A clone that does not KNOW this command has not judged anything, and saying the lesson is broken
# because the tool could not be asked is a claim this never measured (L11, L440). It happens by
# design rather than by accident: the clone this calls updates on its own schedule, so between the
# config reaching this Mac and that clone pulling, the command is genuinely absent. A migration
# applied before the code that needs it deploys has to leave the deployed code working (L640).
case "$out" in
  *"unknown command 'lesson-faults'"*)
    block "The lesson you just wrote into $CLAUDE_HOME/LESSONS.md could not be checked: the clone of claude-sync at $(dirname "$sync") does not have the 'lesson-faults' command yet, so nothing here could judge the entry. That clone updates on its own schedule, and this config reached this Mac first. Run 'claude-sync pull' from that clone, then check the entry with: $sync lesson-faults" ;;
esac

block "The lesson entry just written into $CLAUDE_HOME/LESSONS.md leaves the file unable to publish. Fix it now, in this session, rather than leaving it: until it is fixed the entry is absent from LESSONS-INDEX.md (which loads into every session in every project), unreadable by 'claude-sync lesson', uncounted by the duplicate check and by the number minter, and the WHOLE lessons file is held back from the next send, so every other lesson written since is stuck behind it too.

What claude-sync lesson-faults said:

$out

Fix the entry, then confirm with: $sync lesson-faults"
