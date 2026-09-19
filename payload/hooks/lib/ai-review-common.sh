#!/usr/bin/env bash
#
# ai-review-common.sh: what the two halves of the advisory AI review share (claude-config#433).
#
# Sourced, never executed. ai-review-on-push.sh STARTS a review after a push and ai-review-nudge.sh
# SHOWS it on a later prompt, and the two meet only through files in one state directory. Everything
# that decides whether they meet lives here once: where that directory is, how a repository is keyed,
# how long a review may take, and how the hook payload is read. Two copies of "which repository is
# this" would drift, and the drift is silent in the worst direction: a review written under one key
# and looked for under another is never shown, which reads exactly like a review that found nothing
# (L98, L613).
#
# The state lives under $HOME, never in the project (the brief's rule): a review is about a push,
# not part of the tree it reviewed, and a file in the project would be swept up by the next add.
#
# Environment:
#   AI_REVIEW_STATE_DIR         where reviews are kept (default $HOME/.claude/state/ai-review)
#   AI_REVIEW_DEADLINE_SECONDS  how long one review may run before it is recorded as unfinished
#                               (default 240; the test sets it to one second to drive the expiry)

AR_STATE_DIR="${AI_REVIEW_STATE_DIR:-$HOME/.claude/state/ai-review}"
AR_DEADLINE="${AI_REVIEW_DEADLINE_SECONDS:-240}"
case "$AR_DEADLINE" in ''|*[!0-9]*) AR_DEADLINE=240 ;; esac

# A finished review's name is <repo key>-<head sha>.txt, and while it runs the same name carries
# .pending on the end. The key is a hash of the repository's ORIGIN URL, so every checkout and
# worktree of one repository shares one key and a review started from a worktree is shown to a
# session sitting in the main checkout. A repository with no origin falls back to its top level
# path, which keys it as itself and nothing else.
#
# cksum rather than shasum, deliberately: the nudge runs on every prompt and shasum is a perl
# program that costs about 12 ms to start (measured 2026-09-18), while cksum is a C tool at about
# 2 ms with the same output on macOS and Linux (the POSIX CRC). A dozen repositories cannot collide
# on a 32 bit checksum in any way that matters here, and the two hooks share this one function so
# they can never disagree about a key.
ar_repo_key() {   # $1 = a directory inside the repository -> decimal checksum, or return 1
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)"
  if [ -z "$url" ]; then
    url="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$url" ] || return 1
    url="path:$url"
  fi
  printf '%s' "$url" | cksum | cut -d ' ' -f1
}

# The fields of a hook payload these hooks read, in one line separated by the unit separator:
#   cwd, session_id, tool_response.exit_code, tool_response.interrupted
# A field that is not there is empty. tool_response is an object for the Bash tool and may be a
# string for others, so a string is treated as carrying neither field rather than erroring.
ar_payload_fields() {   # $1 = payload JSON
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -j '
      ((.tool_response // {}) | if type == "object" then . else {} end) as $r
      | (.cwd // "") + "" + (.session_id // "") + ""
        + (($r.exit_code // "") | tostring) + "" + (($r.interrupted // "") | tostring)
    ' 2>/dev/null && return 0
  fi
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
r = d.get("tool_response")
if not isinstance(r, dict):
    r = {}
def s(v):
    return "" if v is None else str(v)
sys.stdout.write("\x1f".join([s(d.get("cwd")), s(d.get("session_id")), s(r.get("exit_code")), s(r.get("interrupted"))]))
' 2>/dev/null
}
